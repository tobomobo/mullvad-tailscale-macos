#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/exit-node-proxy.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'
PASS=0
FAIL=0
WARN=0
ACTIVE_CHECK=1

usage() {
  cat <<EOF
Usage: bash verify-exit-node-proxy.sh [--no-active-check]

Verifies the optional per-user userspace Tailscale SOCKS transport. The active
check compares ordinary Mullvad egress with a socks5h request through the
selected tailnet exit node.
EOF
}

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN=$((WARN + 1)); }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-active-check)
      ACTIVE_CHECK=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

exit_proxy_require_user
exit_proxy_validate_paths

echo "=== Experimental Exit-Node Proxy Verification ==="
echo ""

echo "1. Managed per-user state"
if exit_proxy_state_is_managed; then
  pass "Private state directory is repo-managed"
  if [[ "$(exit_proxy_file_mode "$EXIT_NODE_PROXY_STATE_DIR" || true)" == "700" ]]; then
    pass "State directory mode is 700"
  else
    fail "State directory must have mode 700"
  fi
  if exit_proxy_path_has_no_acl "$EXIT_NODE_PROXY_STATE_DIR"; then
    pass "State directory has no inherited ACL entries"
  else
    fail "State directory has ACL entries or its ACL metadata cannot be read"
  fi
else
  fail "Managed state directory not found at $EXIT_NODE_PROXY_STATE_DIR"
fi

if exit_proxy_config_is_managed; then
  pass "Proxy configuration is repo-managed"
  if [[ "$(exit_proxy_file_mode "$EXIT_NODE_PROXY_CONFIG" || true)" == "600" ]]; then
    pass "Proxy configuration mode is 600"
  else
    fail "Proxy configuration must have mode 600"
  fi
  if exit_proxy_path_has_no_acl "$EXIT_NODE_PROXY_CONFIG"; then
    pass "Proxy configuration has no inherited ACL entries"
  else
    fail "Proxy configuration has ACL entries or its ACL metadata cannot be read"
  fi
else
  fail "Managed proxy configuration not found at $EXIT_NODE_PROXY_CONFIG"
fi

if exit_proxy_plist_is_managed; then
  pass "LaunchAgent is repo-managed"
  if [[ "$(exit_proxy_file_mode "$EXIT_NODE_PROXY_PLIST" || true)" == "600" ]]; then
    pass "LaunchAgent mode is 600"
  else
    fail "LaunchAgent must have mode 600"
  fi
  if exit_proxy_path_has_no_acl "$EXIT_NODE_PROXY_PLIST"; then
    pass "LaunchAgent has no inherited ACL entries"
  else
    fail "LaunchAgent has ACL entries or its ACL metadata cannot be read"
  fi
else
  fail "Managed LaunchAgent not found at $EXIT_NODE_PROXY_PLIST"
fi

echo "2. Mullvad safety prerequisite"
if exit_proxy_mullvad_connected; then
  pass "Mullvad reports connected"
else
  fail "Mullvad is not connected"
fi
if exit_proxy_mullvad_lockdown; then
  pass "Mullvad Lockdown mode is enabled"
else
  fail "Mullvad Lockdown mode is not enabled"
fi

echo "3. Dedicated Tailscale node"
if exit_proxy_launchagent_loaded; then
  pass "Per-user LaunchAgent is loaded"
else
  fail "Per-user LaunchAgent is not loaded"
fi

status_json="$(exit_proxy_tailcli status --json 2>/dev/null || true)"
stored_exit_id="$(exit_proxy_config_value stable_exit_node_id 2>/dev/null || true)"
port="$(exit_proxy_config_value port 2>/dev/null || true)"
if [[ -n "$status_json" ]]; then
  backend="$(exit_proxy_json_value "$status_json" BackendState || true)"
  tun="$(exit_proxy_json_value "$status_json" TUN || true)"
  exit_id="$(exit_proxy_json_value "$status_json" ExitNodeStatus.ID || true)"
  exit_online="$(exit_proxy_json_value "$status_json" ExitNodeStatus.Online || true)"
  self_expired="$(exit_proxy_json_value "$status_json" Self.Expired || echo false)"

  [[ "$backend" == "Running" ]] && pass "Dedicated Tailscale backend is Running" || fail "Dedicated Tailscale backend is '$backend', not Running"
  [[ "$tun" == "false" ]] && pass "Dedicated node uses userspace networking without a TUN interface" || fail "Dedicated node unexpectedly reports TUN=$tun"
  [[ -n "$stored_exit_id" && "$exit_id" == "$stored_exit_id" ]] && pass "Selected exit node matches stored stable ID $stored_exit_id" || fail "Selected exit node does not match the stored stable ID"
  [[ "$exit_online" == "true" ]] && pass "Selected exit node is currently online" || fail "Selected exit node is not currently online"
  [[ "$self_expired" != "true" ]] && pass "Dedicated node key is not reported expired" || fail "Dedicated node key is expired"
else
  fail "Unable to query the dedicated Tailscale LocalAPI"
fi

echo "4. Loopback listener"
if exit_proxy_validate_port "$port" && grep -Fq -- "--socks5-server=127.0.0.1:$port" "$EXIT_NODE_PROXY_PLIST" 2>/dev/null; then
  pass "LaunchAgent pins SOCKS5 to literal 127.0.0.1:$port"
else
  fail "LaunchAgent does not contain the expected loopback-only SOCKS listener"
fi

listener_output=""
if exit_proxy_validate_port "$port"; then
  listener_output="$($LSOF_BIN -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
fi
if grep -Fq -- "127.0.0.1:$port" <<<"$listener_output"; then
  pass "SOCKS listener is active on IPv4 loopback"
else
  fail "No active SOCKS listener found on 127.0.0.1:$port"
fi
if grep -Eq "(\*|\[::\]|\[::1\]):${port}([[:space:]]|$)" <<<"$listener_output"; then
  fail "A SOCKS listener for port $port is exposed beyond literal IPv4 loopback"
else
  pass "No wildcard or IPv6 listener detected for SOCKS port $port"
fi

echo "5. Active egress check"
if [[ "$ACTIVE_CHECK" -eq 1 ]] && exit_proxy_validate_port "$port"; then
  direct_ip="$($CURL_BIN --fail --silent --show-error --max-time 10 https://am.i.mullvad.net/ip 2>/dev/null || true)"
  proxied_ip="$($CURL_BIN --fail --silent --show-error --max-time 15 --proxy "socks5h://127.0.0.1:$port" https://am.i.mullvad.net/ip 2>/dev/null || true)"
  if [[ -n "$direct_ip" ]]; then
    pass "Ordinary egress check returned $direct_ip"
  else
    fail "Ordinary Mullvad egress check failed"
  fi
  if [[ -n "$proxied_ip" ]]; then
    pass "socks5h egress check returned $proxied_ip"
  else
    fail "socks5h egress through the selected exit node failed"
  fi
  if [[ -n "$direct_ip" && -n "$proxied_ip" && "$direct_ip" == "$proxied_ip" ]]; then
    warn "Direct and proxied public IPs are identical; this does not prove an exit-node route"
  fi
else
  warn "Active public-egress comparison skipped"
fi

echo ""
echo "Summary: $PASS passed, $FAIL failed, $WARN warnings"
echo "Point-in-time success does not make this exit-node fail-closed; keep Mullvad connected and Lockdown enabled."
[[ "$FAIL" -eq 0 ]]
