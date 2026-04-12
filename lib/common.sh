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
DSCACHEUTIL_BIN="${DSCACHEUTIL_BIN:-dscacheutil}"
KILLALL_BIN="${KILLALL_BIN:-killall}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
PLUTIL_BIN="${PLUTIL_BIN:-plutil}"
CHOWN_BIN="${CHOWN_BIN:-chown}"
CHMOD_BIN="${CHMOD_BIN:-chmod}"
CP_BIN="${CP_BIN:-cp}"
RM_BIN="${RM_BIN:-rm}"
CMP_BIN="${CMP_BIN:-cmp}"
DATE_BIN="${DATE_BIN:-date}"
MKDIR_BIN="${MKDIR_BIN:-mkdir}"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
RESOLVER_DIR="${RESOLVER_DIR:-/etc/resolver}"

TAILSCALED_DAEMON_LABEL="${TAILSCALED_DAEMON_LABEL:-com.tailscale.tailscaled}"
TAILSCALED_DAEMON_PLIST="${TAILSCALED_DAEMON_PLIST:-/Library/LaunchDaemons/com.tailscale.tailscaled.plist}"
TAILSCALED_STDOUT_PATH="${TAILSCALED_STDOUT_PATH:-/var/log/tailscaled.log}"
TAILSCALED_STDERR_PATH="${TAILSCALED_STDERR_PATH:-/var/log/tailscaled.err}"

TAILSCALE_IPV4_RANGE="100.64.0.0/10"
TAILSCALE_IPV6_RANGE="fd7a:115c:a1e0::/48"
TAILSCALE_MAGICDNS_SERVER="${TAILSCALE_MAGICDNS_SERVER:-100.100.100.100}"
TAILNET_RESOLVER_COMMENT="# Managed by install-tailnet-resolver.sh"
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

validate_tailnet_domain() {
  local domain="$1"

  [[ -n "$domain" ]] || return 1
  [[ "$domain" != .* ]] || return 1
  [[ "$domain" != *. ]] || return 1
  [[ "$domain" != *..* ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$domain" == *.ts.net ]]
}

validate_nameserver_ip() {
  local nameserver="$1"

  [[ -n "$nameserver" ]] || return 1
  [[ "$nameserver" =~ ^[0-9A-Fa-f:.]+$ ]]
}

has_exact_line() {
  local file="$1"
  local line="$2"

  [[ -f "$file" ]] && grep -Fqx -- "$line" "$file"
}

extract_ip_lines() {
  awk '
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || /^[0-9A-Fa-f:]+$/ {
      if (!seen[$0]++) {
        print $0
      }
    }
  '
}

join_lines() {
  local data="$1"
  local separator="${2:-, }"

  awk -v separator="$separator" '
    NF {
      output = output ? output separator $0 : $0
    }
    END {
      print output
    }
  ' <<<"$data"
}

list_has_common_line() {
  local first="$1"
  local second="$2"
  local line

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    grep -Fqx -- "$line" <<<"$second" && return 0
  done <<<"$first"

  return 1
}

direct_magicdns_lookup() {
  local hostname="$1"

  { "$DIG_BIN" +short @"$TAILSCALE_MAGICDNS_SERVER" "$hostname" 2>/dev/null || true; } | extract_ip_lines
}

system_resolver_lookup() {
  local hostname="$1"

  { "$DSCACHEUTIL_BIN" -q host -a name "$hostname" 2>/dev/null || true; } | awk '
    /^ip_address: / {
      if (!seen[$2]++) {
        print $2
      }
    }
  '
}

hosts_file_lookup() {
  local hostname="$1"
  local file="${2:-$HOSTS_FILE}"

  [[ -f "$file" ]] || return 0

  awk -v hostname="$hostname" '
    /^[[:space:]]*#/ || NF < 2 { next }
    {
      ip = $1
      if (ip !~ /^[0-9A-Fa-f:.]+$/) {
        next
      }

      for (i = 2; i <= NF; i++) {
        if ($i == hostname && !seen[ip]++) {
          print ip
        }
      }
    }
  ' "$file" 2>/dev/null || true
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
  local file_mode="${3:-644}"

  "$CP_BIN" "$source_file" "$destination_file"
  "$CHOWN_BIN" root:wheel "$destination_file"
  "$CHMOD_BIN" "$file_mode" "$destination_file"
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

resolver_file_for_domain() {
  local domain="$1"

  echo "${RESOLVER_DIR}/${domain}"
}

write_tailnet_resolver_file() {
  local destination_file="$1"
  local domain="$2"

  cat > "$destination_file" <<EOF
${TAILNET_RESOLVER_COMMENT}
# Routes ${domain} lookups to Tailscale MagicDNS.
nameserver ${TAILSCALE_MAGICDNS_SERVER}
EOF
}

resolver_file_has_nameserver() {
  local file="$1"
  local nameserver="${2:-$TAILSCALE_MAGICDNS_SERVER}"

  has_exact_line "$file" "nameserver $nameserver"
}

resolver_file_managed_by_repo() {
  local file="$1"

  has_exact_line "$file" "$TAILNET_RESOLVER_COMMENT"
}

flush_dns_caches() {
  local rc=0

  "$DSCACHEUTIL_BIN" -flushcache >/dev/null 2>&1 || rc=1
  "$KILLALL_BIN" -HUP mDNSResponder >/dev/null 2>&1 || rc=1

  return "$rc"
}
