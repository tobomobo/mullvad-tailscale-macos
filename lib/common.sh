#!/bin/bash

TAILSCALE_ANCHOR_NAME="${TAILSCALE_ANCHOR_NAME:-tailscale}"
ANCHOR_FILE="${ANCHOR_FILE:-/etc/pf.anchors/tailscale}"
PF_CONF="${PF_CONF:-/etc/pf.conf}"
ANCHOR_TEMPLATE="${ANCHOR_TEMPLATE:-$SCRIPT_DIR/etc/pf.anchors/tailscale}"

PFCTL_BIN="${PFCTL_BIN:-pfctl}"
IFCONFIG_BIN="${IFCONFIG_BIN:-ifconfig}"
TAILSCALE_BIN="${TAILSCALE_BIN:-tailscale}"
PGREP_BIN="${PGREP_BIN:-pgrep}"
CURL_BIN="${CURL_BIN:-curl}"
DIG_BIN="${DIG_BIN:-dig}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
PLUTIL_BIN="${PLUTIL_BIN:-plutil}"
CHOWN_BIN="${CHOWN_BIN:-chown}"
CHMOD_BIN="${CHMOD_BIN:-chmod}"
CP_BIN="${CP_BIN:-cp}"
RM_BIN="${RM_BIN:-rm}"
CMP_BIN="${CMP_BIN:-cmp}"
DATE_BIN="${DATE_BIN:-date}"

TAILSCALED_DAEMON_LABEL="${TAILSCALED_DAEMON_LABEL:-com.tailscale.tailscaled}"
TAILSCALED_DAEMON_PLIST="${TAILSCALED_DAEMON_PLIST:-/Library/LaunchDaemons/com.tailscale.tailscaled.plist}"
TAILSCALED_STDOUT_PATH="${TAILSCALED_STDOUT_PATH:-/var/log/tailscaled.log}"
TAILSCALED_STDERR_PATH="${TAILSCALED_STDERR_PATH:-/var/log/tailscaled.err}"

TAILSCALE_IPV4_RANGE="100.64.0.0/10"
TAILSCALE_IPV6_RANGE="fd7a:115c:a1e0::/48"
ANCHOR_COMMENT="# Tailscale anchor - allow tailnet traffic through Mullvad kill switch"
ANCHOR_LINE="anchor \"$TAILSCALE_ANCHOR_NAME\""
LOAD_LINE="load anchor \"$TAILSCALE_ANCHOR_NAME\" from \"$ANCHOR_FILE\""

die() {
  echo "Error: $*" >&2
  exit 1
}

require_root() {
  if [[ "${SKIP_ROOT_CHECK:-0}" == "1" ]]; then
    return 0
  fi

  if [[ $EUID -ne 0 ]]; then
    die "This script must be run with sudo."
  fi
}

timestamp() {
  "$DATE_BIN" +%Y%m%d%H%M%S
}

make_temp_file() {
  mktemp "${TMPDIR:-/tmp}/$1.XXXXXX"
}

has_exact_line() {
  local file="$1"
  local line="$2"

  [[ -f "$file" ]] && grep -Fqx -- "$line" "$file"
}

detect_tailscale_interface() {
  if [[ -n "${TAILSCALE_INTERFACE:-}" ]]; then
    echo "$TAILSCALE_INTERFACE"
    return 0
  fi

  local iface
  local config

  for iface in $("$IFCONFIG_BIN" -l 2>/dev/null || true); do
    [[ "$iface" == utun* ]] || continue

    config="$("$IFCONFIG_BIN" "$iface" 2>/dev/null || true)"
    if grep -Eq 'inet 100\.' <<<"$config" || grep -Eq 'inet6 fd7a:115c:a1e0:' <<<"$config"; then
      echo "$iface"
      return 0
    fi
  done

  return 1
}

anchor_interface_from_file() {
  local file="$1"

  awk '/^pass out quick on / {print $5; exit}' "$file"
}

render_anchor_template() {
  local template="$1"
  local destination="$2"
  local interface="$3"

  sed "s/__TAILSCALE_INTERFACE__/$interface/g" "$template" > "$destination"
}

ensure_anchor_block() {
  local source_file="$1"
  local destination_file="$2"

  if has_exact_line "$source_file" "$ANCHOR_LINE" && has_exact_line "$source_file" "$LOAD_LINE"; then
    "$CP_BIN" "$source_file" "$destination_file"
    return 0
  fi

  awk \
    -v comment="$ANCHOR_COMMENT" \
    -v anchor="$ANCHOR_LINE" \
    -v load="$LOAD_LINE" \
    '
      $0 != comment && $0 != anchor && $0 != load { print }
      END {
        print ""
        print comment
        print anchor
        print load
      }
    ' "$source_file" > "$destination_file"
}

remove_anchor_block() {
  local source_file="$1"
  local destination_file="$2"

  awk \
    -v comment="$ANCHOR_COMMENT" \
    -v anchor="$ANCHOR_LINE" \
    -v load="$LOAD_LINE" \
    '
      $0 != comment && $0 != anchor && $0 != load { print }
    ' "$source_file" > "$destination_file"
}

file_differs() {
  local first="$1"
  local second="$2"

  ! "$CMP_BIN" -s "$first" "$second"
}

backup_file() {
  local file="$1"
  local backup_path="${file}.bak.$(timestamp)"

  "$CP_BIN" "$file" "$backup_path"
  echo "$backup_path"
}

install_root_owned_file() {
  local source_file="$1"
  local destination_file="$2"

  "$CP_BIN" "$source_file" "$destination_file"
  "$CHOWN_BIN" root:wheel "$destination_file"
  "$CHMOD_BIN" 644 "$destination_file"
}

validate_anchor_file() {
  local file="$1"

  "$PFCTL_BIN" -n -a "$TAILSCALE_ANCHOR_NAME" -f "$file" >/dev/null 2>&1
}

validate_pf_conf() {
  local file="$1"

  "$PFCTL_BIN" -n -f "$file" >/dev/null 2>&1
}

load_runtime_anchor() {
  local file="$1"

  "$PFCTL_BIN" -a "$TAILSCALE_ANCHOR_NAME" -f "$file" >/dev/null 2>&1
}

reload_pf_conf() {
  local file="$1"

  "$PFCTL_BIN" -f "$file" >/dev/null 2>&1
}

apply_pf_conf_update() {
  local new_conf="$1"
  local backup_path

  backup_path="$(backup_file "$PF_CONF")"
  "$CP_BIN" "$new_conf" "$PF_CONF"

  if reload_pf_conf "$PF_CONF"; then
    echo "$backup_path"
    return 0
  fi

  echo "Reload failed, restoring $backup_path ..." >&2
  "$CP_BIN" "$backup_path" "$PF_CONF"
  reload_pf_conf "$PF_CONF" >/dev/null 2>&1 || true
  return 1
}

flush_runtime_anchor() {
  "$PFCTL_BIN" -a "$TAILSCALE_ANCHOR_NAME" -F rules >/dev/null 2>&1
}

detect_tailscaled_binary() {
  if [[ -n "${TAILSCALED_BIN:-}" ]]; then
    echo "$TAILSCALED_BIN"
    return 0
  fi

  command -v tailscaled 2>/dev/null || return 1
}

write_launchdaemon_plist() {
  local destination_file="$1"
  local tailscaled_bin="$2"

  cat > "$destination_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${TAILSCALED_DAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${tailscaled_bin}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${TAILSCALED_STDOUT_PATH}</string>
    <key>StandardErrorPath</key>
    <string>${TAILSCALED_STDERR_PATH}</string>
</dict>
</plist>
EOF
}

validate_plist() {
  local file="$1"

  "$PLUTIL_BIN" -lint "$file" >/dev/null 2>&1
}

launchdaemon_service_target() {
  echo "system/${TAILSCALED_DAEMON_LABEL}"
}

launchdaemon_loaded() {
  "$LAUNCHCTL_BIN" print "$(launchdaemon_service_target)" >/dev/null 2>&1
}

bootout_launchdaemon() {
  if launchdaemon_loaded; then
    "$LAUNCHCTL_BIN" bootout "$(launchdaemon_service_target)" >/dev/null 2>&1
  fi
}

bootstrap_launchdaemon() {
  "$LAUNCHCTL_BIN" bootstrap system "$TAILSCALED_DAEMON_PLIST" >/dev/null 2>&1
  "$LAUNCHCTL_BIN" kickstart -k "$(launchdaemon_service_target)" >/dev/null 2>&1
}
