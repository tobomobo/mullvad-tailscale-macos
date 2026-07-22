#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/exit-node-proxy.sh"

usage() {
  cat <<EOF
Usage: bash install-exit-node-proxy.sh --exit-node <name-or-id> [--port 1055]

Installs an experimental per-user SOCKS5 transport backed by a separate
userspace Tailscale node. The selected exit node must be advertised and
approved in the authenticated tailnet. Run without sudo.

The SOCKS listener is exposed only after authentication and a point-in-time
online exit-node check. Runtime route loss can still fall back to ordinary
system egress, so Mullvad must remain connected with Lockdown mode enabled.
EOF
}

EXIT_NODE=""
SOCKS_PORT=1055

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exit-node)
      [[ $# -ge 2 ]] || exit_proxy_die "--exit-node requires a value."
      EXIT_NODE="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || exit_proxy_die "--port requires a value."
      SOCKS_PORT="$2"
      shift 2
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
exit_proxy_validate_selector "$EXIT_NODE" || exit_proxy_die "Use an explicit advertised exit-node name, IP, or stable ID; auto:any is intentionally not accepted."
exit_proxy_validate_port "$SOCKS_PORT" || exit_proxy_die "SOCKS port must be an unprivileged port from 1024 through 65535."
exit_proxy_require_mullvad

TAILSCALED_BIN="$(exit_proxy_find_binary "$TAILSCALED_BIN")" || exit_proxy_die "Cannot find an executable tailscaled binary."
TAILSCALE_BIN="$(exit_proxy_find_binary "$TAILSCALE_BIN")" || exit_proxy_die "Cannot find an executable tailscale CLI."

if [[ -e "$EXIT_NODE_PROXY_PLIST" ]] && ! exit_proxy_plist_is_managed; then
  exit_proxy_die "$EXIT_NODE_PROXY_PLIST exists but is not recognized as repo-managed."
fi
if [[ -e "$EXIT_NODE_PROXY_STATE_DIR" ]] && ! exit_proxy_state_is_managed; then
  exit_proxy_die "$EXIT_NODE_PROXY_STATE_DIR exists but is not recognized as repo-managed."
fi

exit_proxy_prepare_state_dir
tmp_plist="$(mktemp "${TMPDIR:-/tmp}/exit-node-proxy-plist.XXXXXX")"
safe_plist="$(mktemp "${TMPDIR:-/tmp}/exit-node-proxy-safe-plist.XXXXXX")"
trap 'rm -f "$tmp_plist" "$safe_plist"' EXIT

restore_no_listener_or_die() {
  if ! exit_proxy_bootout; then
    exit_proxy_die "Safety rollback could not stop the SOCKS LaunchAgent. Disable it with launchctl before using the proxy again."
  fi
  exit_proxy_install_plist "$safe_plist"
  if ! exit_proxy_bootstrap; then
    exit_proxy_die "The SOCKS listener was stopped and the no-listener plist restored, but the safe LaunchAgent could not be restarted."
  fi
}

# Authenticate and select the exit node before exposing a SOCKS listener.
exit_proxy_write_plist "$safe_plist" "$TAILSCALED_BIN" "$SOCKS_PORT" 0
"$PLUTIL_BIN" -lint "$safe_plist" >/dev/null 2>&1 || exit_proxy_die "Generated authentication LaunchAgent is invalid."
exit_proxy_bootout || exit_proxy_die "Failed to unload the existing proxy LaunchAgent; no plist was replaced."
exit_proxy_install_plist "$safe_plist"
exit_proxy_bootstrap || exit_proxy_die "Failed to bootstrap $(exit_proxy_service_target)."
exit_proxy_wait_for_localapi || exit_proxy_die "The dedicated userspace tailscaled LocalAPI did not become ready."

local_hostname="$(hostname -s 2>/dev/null || echo mac)"
local_hostname="$(sed -E 's/[^A-Za-z0-9-]+/-/g; s/^-+//; s/-+$//' <<<"$local_hostname")"
[[ -n "$local_hostname" ]] || local_hostname="mac"
proxy_hostname="${local_hostname:0:42}-app-egress"

echo "Authenticating the dedicated Tailscale node and selecting '$EXIT_NODE' ..."
exit_proxy_tailcli up \
  --reset \
  --accept-dns=true \
  --accept-routes=false \
  --advertise-connector=false \
  --advertise-exit-node=false \
  --advertise-routes= \
  --exit-node="$EXIT_NODE" \
  --exit-node-allow-lan-access=false \
  --hostname="$proxy_hostname" \
  --report-posture=false \
  --shields-up=true \
  --ssh=false

status_json="$(exit_proxy_tailcli status --json)" || exit_proxy_die "Unable to read the dedicated Tailscale status."
if ! exit_proxy_status_is_ready "$status_json"; then
  exit_proxy_die "The dedicated node is not Running with an online exit node. The SOCKS listener remains disabled; check authentication, tailnet approval, ACLs, key expiry, and exit-node availability."
fi
stable_exit_node_id="$(exit_proxy_json_value "$status_json" ExitNodeStatus.ID)"
exit_proxy_write_config "$SOCKS_PORT" "$EXIT_NODE" "$stable_exit_node_id" "$proxy_hostname"

exit_proxy_write_plist "$tmp_plist" "$TAILSCALED_BIN" "$SOCKS_PORT" 1
"$PLUTIL_BIN" -lint "$tmp_plist" >/dev/null 2>&1 || exit_proxy_die "Generated proxy LaunchAgent is invalid."
exit_proxy_bootout || exit_proxy_die "Failed to unload the authentication LaunchAgent; the SOCKS listener was not installed."
exit_proxy_install_plist "$tmp_plist"
if ! exit_proxy_bootstrap; then
  restore_no_listener_or_die
  exit_proxy_die "Failed to start the SOCKS listener; restored the no-listener LaunchAgent."
fi
if ! exit_proxy_wait_for_localapi; then
  restore_no_listener_or_die
  exit_proxy_die "The proxy restarted but its dedicated LocalAPI did not become ready; restored the no-listener LaunchAgent."
fi

final_status_json="$(exit_proxy_tailcli status --json 2>/dev/null || true)"
final_exit_node_id="$(exit_proxy_json_value "$final_status_json" ExitNodeStatus.ID || true)"
if ! exit_proxy_status_is_ready "$final_status_json" || [[ "$final_exit_node_id" != "$stable_exit_node_id" ]]; then
  restore_no_listener_or_die
  exit_proxy_die "The selected exit node was not ready after the listener restart; restored the no-listener LaunchAgent."
fi

echo ""
echo "Experimental exit-node proxy installed."
echo "  SOCKS5: 127.0.0.1:$SOCKS_PORT"
echo "  Exit node: $EXIT_NODE ($stable_exit_node_id)"
echo "  Verify: bash verify-exit-node-proxy.sh"
echo ""
echo "Keep Mullvad connected with Lockdown mode enabled. This transport may fall back to ordinary Mullvad egress if the Tailscale exit route disappears; it is not exit-node fail-closed."
