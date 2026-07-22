#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/exit-node-proxy.sh"

usage() {
  cat <<EOF
Usage: bash uninstall-exit-node-proxy.sh

Logs out and removes the optional per-user userspace Tailscale SOCKS proxy.
Run without sudo. No PF configuration is changed.
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
fi

exit_proxy_require_user
exit_proxy_validate_paths

if [[ -e "$EXIT_NODE_PROXY_PLIST" ]] && ! exit_proxy_plist_is_managed; then
  exit_proxy_die "$EXIT_NODE_PROXY_PLIST is not recognized as repo-managed; refusing to stop or remove it."
fi
if [[ -e "$EXIT_NODE_PROXY_STATE_DIR" ]] && ! exit_proxy_state_is_managed; then
  exit_proxy_die "$EXIT_NODE_PROXY_STATE_DIR is not recognized as repo-managed; refusing to remove it."
fi

if exit_proxy_launchagent_loaded; then
  if ! exit_proxy_tailcli logout >/dev/null 2>&1; then
    exit_proxy_warn "Could not log out the dedicated node. Remove the stale device from the Tailscale admin console if it remains listed."
  fi
fi

exit_proxy_bootout || exit_proxy_die "Failed to unload the proxy LaunchAgent; no managed files were removed."

if [[ -f "$EXIT_NODE_PROXY_PLIST" ]]; then
  "$RM_BIN" -f "$EXIT_NODE_PROXY_PLIST"
fi
if [[ -d "$EXIT_NODE_PROXY_STATE_DIR" ]]; then
  "$RM_BIN" -rf "$EXIT_NODE_PROXY_STATE_DIR"
fi

echo "Experimental exit-node proxy removed. No PF configuration was changed."
echo "Check the Tailscale admin console if the dedicated node could not be logged out."
