#!/bin/bash

# Shared helpers for the optional, per-user userspace Tailscale SOCKS proxy.
# Keep this separate from common.sh: this component must never need root or PF.

EXIT_NODE_PROXY_LABEL="${EXIT_NODE_PROXY_LABEL:-com.mullvad-tailscale-macos.exit-node-proxy}"
EXIT_NODE_PROXY_STATE_DIR="${EXIT_NODE_PROXY_STATE_DIR:-$HOME/Library/Application Support/mullvad-tailscale/exit-node-proxy}"
EXIT_NODE_PROXY_PLIST="${EXIT_NODE_PROXY_PLIST:-$HOME/Library/LaunchAgents/${EXIT_NODE_PROXY_LABEL}.plist}"
EXIT_NODE_PROXY_SOCKET="${EXIT_NODE_PROXY_SOCKET:-$EXIT_NODE_PROXY_STATE_DIR/ts.sock}"
EXIT_NODE_PROXY_STATE_FILE="${EXIT_NODE_PROXY_STATE_FILE:-$EXIT_NODE_PROXY_STATE_DIR/tailscaled.state}"
EXIT_NODE_PROXY_CONFIG="${EXIT_NODE_PROXY_CONFIG:-$EXIT_NODE_PROXY_STATE_DIR/config}"
EXIT_NODE_PROXY_MARKER="${EXIT_NODE_PROXY_MARKER:-$EXIT_NODE_PROXY_STATE_DIR/.managed-by-mullvad-tailscale-macos}"
EXIT_NODE_PROXY_MARKER_CONTENT="Managed by mullvad-tailscale-macos exit-node-proxy"
EXIT_NODE_PROXY_PLIST_MARKER="<!-- Managed by mullvad-tailscale-macos exit-node-proxy -->"

TAILSCALE_BIN="${TAILSCALE_BIN:-tailscale}"
TAILSCALED_BIN="${TAILSCALED_BIN:-tailscaled}"
MULLVAD_BIN="${MULLVAD_BIN:-mullvad}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
PLUTIL_BIN="${PLUTIL_BIN:-/usr/bin/plutil}"
CURL_BIN="${CURL_BIN:-curl}"
LSOF_BIN="${LSOF_BIN:-/usr/sbin/lsof}"
STAT_BIN="${STAT_BIN:-/usr/bin/stat}"
LS_BIN="${LS_BIN:-/bin/ls}"
CHMOD_BIN="${CHMOD_BIN:-/bin/chmod}"
CP_BIN="${CP_BIN:-cp}"
RM_BIN="${RM_BIN:-rm}"
MKDIR_BIN="${MKDIR_BIN:-mkdir}"
SLEEP_BIN="${SLEEP_BIN:-sleep}"

exit_proxy_die() {
  echo "Error: $*" >&2
  exit 1
}

exit_proxy_warn() {
  echo "Warning: $*" >&2
}

exit_proxy_require_user() {
  if [[ "${SKIP_USER_CHECK:-0}" == "1" ]]; then
    return 0
  fi
  [[ $EUID -ne 0 ]] || exit_proxy_die "Run this per-user component without sudo."
}

exit_proxy_validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1024 && port <= 65535 ))
}

exit_proxy_validate_selector() {
  local selector="$1"
  [[ -n "$selector" && "$selector" != "auto:any" && "$selector" =~ ^[A-Za-z0-9._:-]+$ ]]
}

exit_proxy_validate_paths() {
  [[ "$EXIT_NODE_PROXY_STATE_DIR" == /* ]] || exit_proxy_die "State directory must be an absolute path."
  [[ "$EXIT_NODE_PROXY_STATE_DIR" != "/" && "$EXIT_NODE_PROXY_STATE_DIR" != "$HOME" ]] || exit_proxy_die "Refusing unsafe state directory: $EXIT_NODE_PROXY_STATE_DIR"
  [[ "${EXIT_NODE_PROXY_STATE_DIR##*/}" == "exit-node-proxy" ]] || exit_proxy_die "State directory must end in /exit-node-proxy."
  [[ "$EXIT_NODE_PROXY_SOCKET" == "$EXIT_NODE_PROXY_STATE_DIR/"* ]] || exit_proxy_die "The dedicated socket must remain inside the private state directory."
  [[ "$EXIT_NODE_PROXY_STATE_FILE" == "$EXIT_NODE_PROXY_STATE_DIR/"* ]] || exit_proxy_die "The state file must remain inside the private state directory."
  [[ "$EXIT_NODE_PROXY_CONFIG" == "$EXIT_NODE_PROXY_STATE_DIR/"* ]] || exit_proxy_die "The configuration must remain inside the private state directory."
  [[ "$EXIT_NODE_PROXY_MARKER" == "$EXIT_NODE_PROXY_STATE_DIR/"* ]] || exit_proxy_die "The ownership marker must remain inside the private state directory."
  [[ "$EXIT_NODE_PROXY_SOCKET" != "/var/run/tailscaled.socket" ]] || exit_proxy_die "Refusing to use Tailscale's primary socket."
  if [[ "${SKIP_SOCKET_LENGTH_CHECK:-0}" != "1" ]]; then
    (( ${#EXIT_NODE_PROXY_SOCKET} < 100 )) || exit_proxy_die "Dedicated socket path is too long for macOS: $EXIT_NODE_PROXY_SOCKET"
  fi
  [[ "$EXIT_NODE_PROXY_PLIST" == /* ]] || exit_proxy_die "LaunchAgent path must be absolute."
}

exit_proxy_find_binary() {
  local candidate="$1"
  local resolved

  if [[ "$candidate" == */* ]]; then
    resolved="$candidate"
  else
    resolved="$(command -v "$candidate" 2>/dev/null || true)"
  fi
  [[ -n "$resolved" && "$resolved" == /* && -f "$resolved" && -x "$resolved" ]] || return 1
  echo "$resolved"
}

exit_proxy_tailcli() {
  [[ -n "$EXIT_NODE_PROXY_SOCKET" && "$EXIT_NODE_PROXY_SOCKET" != "/var/run/tailscaled.socket" ]] || {
    echo "Refusing to call Tailscale without the dedicated proxy socket." >&2
    return 1
  }
  "$TAILSCALE_BIN" --socket="$EXIT_NODE_PROXY_SOCKET" "$@"
}

exit_proxy_mullvad_connected() {
  "$MULLVAD_BIN" status 2>/dev/null | grep -Eq '^Connected([[:space:]]|$)'
}

exit_proxy_mullvad_lockdown() {
  "$MULLVAD_BIN" lockdown-mode get 2>/dev/null | grep -Eqi '(lockdown|block traffic).*(:|is)[[:space:]]*(on|enabled)([[:space:]]|$)'
}

exit_proxy_require_mullvad() {
  exit_proxy_mullvad_connected || exit_proxy_die "Mullvad must be connected before configuring this proxy."
  exit_proxy_mullvad_lockdown || exit_proxy_die "Mullvad Lockdown mode must be enabled before configuring this proxy."
}

exit_proxy_state_is_managed() {
  [[ -d "$EXIT_NODE_PROXY_STATE_DIR" && ! -L "$EXIT_NODE_PROXY_STATE_DIR" && -f "$EXIT_NODE_PROXY_MARKER" && ! -L "$EXIT_NODE_PROXY_MARKER" ]] &&
    [[ "$(exit_proxy_file_uid "$EXIT_NODE_PROXY_STATE_DIR" || true)" == "$(id -u)" ]] &&
    [[ "$(exit_proxy_file_uid "$EXIT_NODE_PROXY_MARKER" || true)" == "$(id -u)" ]] &&
    grep -Fqx -- "$EXIT_NODE_PROXY_MARKER_CONTENT" "$EXIT_NODE_PROXY_MARKER"
}

exit_proxy_plist_is_managed() {
  [[ -f "$EXIT_NODE_PROXY_PLIST" && ! -L "$EXIT_NODE_PROXY_PLIST" ]] &&
    [[ "$(exit_proxy_file_uid "$EXIT_NODE_PROXY_PLIST" || true)" == "$(id -u)" ]] &&
    grep -Fqx -- "$EXIT_NODE_PROXY_PLIST_MARKER" "$EXIT_NODE_PROXY_PLIST"
}

exit_proxy_harden_path() {
  local path="$1"
  local mode="$2"

  "$CHMOD_BIN" -N "$path" 2>/dev/null || exit_proxy_die "Cannot remove inherited ACLs from $path."
  "$CHMOD_BIN" "$mode" "$path"
}

exit_proxy_prepare_state_dir() {
  if [[ -e "$EXIT_NODE_PROXY_STATE_DIR" ]] && ! exit_proxy_state_is_managed; then
    exit_proxy_die "$EXIT_NODE_PROXY_STATE_DIR exists but is not recognized as repo-managed."
  fi
  "$MKDIR_BIN" -p "$EXIT_NODE_PROXY_STATE_DIR"
  exit_proxy_harden_path "$EXIT_NODE_PROXY_STATE_DIR" 700
  if [[ -e "$EXIT_NODE_PROXY_STATE_FILE" || -L "$EXIT_NODE_PROXY_STATE_FILE" ]]; then
    [[ -f "$EXIT_NODE_PROXY_STATE_FILE" && ! -L "$EXIT_NODE_PROXY_STATE_FILE" ]] || exit_proxy_die "Refusing unsafe Tailscale state artifact: $EXIT_NODE_PROXY_STATE_FILE"
    [[ "$(exit_proxy_file_uid "$EXIT_NODE_PROXY_STATE_FILE" || true)" == "$(id -u)" ]] || exit_proxy_die "The Tailscale state file is not owned by the current user."
  fi
  [[ ! -L "$EXIT_NODE_PROXY_SOCKET" ]] || exit_proxy_die "Refusing a symbolic link at the dedicated socket path."
  printf '%s\n' "$EXIT_NODE_PROXY_MARKER_CONTENT" > "$EXIT_NODE_PROXY_MARKER"
  exit_proxy_harden_path "$EXIT_NODE_PROXY_MARKER" 600
}

exit_proxy_service_target() {
  echo "gui/$(id -u)/$EXIT_NODE_PROXY_LABEL"
}

exit_proxy_launchagent_loaded() {
  "$LAUNCHCTL_BIN" print "$(exit_proxy_service_target)" >/dev/null 2>&1
}

exit_proxy_bootout() {
  if exit_proxy_launchagent_loaded; then
    "$LAUNCHCTL_BIN" bootout "$(exit_proxy_service_target)" >/dev/null 2>&1
  fi
}

exit_proxy_bootstrap() {
  "$LAUNCHCTL_BIN" bootstrap "gui/$(id -u)" "$EXIT_NODE_PROXY_PLIST" >/dev/null || return 1
  "$LAUNCHCTL_BIN" kickstart -k "$(exit_proxy_service_target)" >/dev/null || return 1
  exit_proxy_launchagent_loaded
}

exit_proxy_xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' <<<"$1"
}

exit_proxy_write_plist() {
  local destination="$1"
  local tailscaled_bin="$2"
  local port="$3"
  local expose_socks="$4"
  local escaped_bin
  local escaped_state_dir
  local escaped_state_file
  local escaped_socket

  escaped_bin="$(exit_proxy_xml_escape "$tailscaled_bin")"
  escaped_state_dir="$(exit_proxy_xml_escape "$EXIT_NODE_PROXY_STATE_DIR")"
  escaped_state_file="$(exit_proxy_xml_escape "$EXIT_NODE_PROXY_STATE_FILE")"
  escaped_socket="$(exit_proxy_xml_escape "$EXIT_NODE_PROXY_SOCKET")"

  cat > "$destination" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
${EXIT_NODE_PROXY_PLIST_MARKER}
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${EXIT_NODE_PROXY_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${escaped_bin}</string>
        <string>--tun=userspace-networking</string>
        <string>--statedir=${escaped_state_dir}</string>
        <string>--state=${escaped_state_file}</string>
        <string>--socket=${escaped_socket}</string>
        <string>--port=0</string>
        <string>--no-logs-no-support</string>
EOF
  if [[ "$expose_socks" == "1" ]]; then
    printf '        <string>--socks5-server=127.0.0.1:%s</string>\n' "$port" >> "$destination"
  fi
  cat >> "$destination" <<EOF
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>Umask</key>
    <integer>63</integer>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF
}

exit_proxy_install_plist() {
  local source="$1"
  local plist_dir="${EXIT_NODE_PROXY_PLIST%/*}"

  if [[ -e "$EXIT_NODE_PROXY_PLIST" ]] && ! exit_proxy_plist_is_managed; then
    exit_proxy_die "$EXIT_NODE_PROXY_PLIST exists but is not recognized as repo-managed."
  fi
  "$MKDIR_BIN" -p "$plist_dir"
  "$CP_BIN" "$source" "$EXIT_NODE_PROXY_PLIST"
  exit_proxy_harden_path "$EXIT_NODE_PROXY_PLIST" 600
}

exit_proxy_wait_for_localapi() {
  local attempt
  for attempt in {1..50}; do
    if exit_proxy_tailcli status --json >/dev/null 2>&1; then
      return 0
    fi
    "$SLEEP_BIN" 0.1
  done
  return 1
}

exit_proxy_json_value() {
  local json="$1"
  local keypath="$2"
  "$PLUTIL_BIN" -extract "$keypath" raw -o - - 2>/dev/null <<<"$json"
}

exit_proxy_status_is_ready() {
  local json="$1"
  local backend
  local tun
  local exit_id
  local online
  local expired

  backend="$(exit_proxy_json_value "$json" BackendState || true)"
  tun="$(exit_proxy_json_value "$json" TUN || true)"
  exit_id="$(exit_proxy_json_value "$json" ExitNodeStatus.ID || true)"
  online="$(exit_proxy_json_value "$json" ExitNodeStatus.Online || true)"
  expired="$(exit_proxy_json_value "$json" Self.Expired || echo false)"

  [[ "$backend" == "Running" && "$tun" == "false" && -n "$exit_id" && "$online" == "true" && "$expired" != "true" ]]
}

exit_proxy_write_config() {
  local port="$1"
  local requested_exit_node="$2"
  local stable_exit_node_id="$3"
  local hostname="$4"

  if [[ -e "$EXIT_NODE_PROXY_CONFIG" || -L "$EXIT_NODE_PROXY_CONFIG" ]] && ! exit_proxy_config_is_managed; then
    exit_proxy_die "$EXIT_NODE_PROXY_CONFIG exists but is not recognized as repo-managed."
  fi

  cat > "$EXIT_NODE_PROXY_CONFIG" <<EOF
${EXIT_NODE_PROXY_MARKER_CONTENT}
port=${port}
requested_exit_node=${requested_exit_node}
stable_exit_node_id=${stable_exit_node_id}
hostname=${hostname}
EOF
  exit_proxy_harden_path "$EXIT_NODE_PROXY_CONFIG" 600
}

exit_proxy_config_value() {
  local key="$1"
  [[ -f "$EXIT_NODE_PROXY_CONFIG" ]] || return 1
  awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }' "$EXIT_NODE_PROXY_CONFIG"
}

exit_proxy_config_is_managed() {
  [[ -f "$EXIT_NODE_PROXY_CONFIG" && ! -L "$EXIT_NODE_PROXY_CONFIG" ]] &&
    [[ "$(exit_proxy_file_uid "$EXIT_NODE_PROXY_CONFIG" || true)" == "$(id -u)" ]] &&
    grep -Fqx -- "$EXIT_NODE_PROXY_MARKER_CONTENT" "$EXIT_NODE_PROXY_CONFIG"
}

exit_proxy_file_mode() {
  "$STAT_BIN" -f '%Lp' "$1" 2>/dev/null
}

exit_proxy_file_uid() {
  "$STAT_BIN" -f '%u' "$1" 2>/dev/null
}

exit_proxy_path_has_no_acl() {
  local output
  output="$("$LS_BIN" -lde "$1" 2>/dev/null)" || return 1
  ! grep -Eq '^[[:space:]]+[0-9]+:' <<<"$output"
}
