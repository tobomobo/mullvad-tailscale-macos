#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo bash uninstall-tailscaled-daemon.sh

Removes the system LaunchDaemon installed by install-tailscaled-daemon.sh.
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

require_root

if [[ -f "$TAILSCALED_DAEMON_PLIST" ]] && ! plist_managed_by_repo "$TAILSCALED_DAEMON_PLIST"; then
  die "$TAILSCALED_DAEMON_PLIST is not marked as managed by this repo. Refusing to stop or remove it."
fi

if [[ ! -f "$TAILSCALED_DAEMON_PLIST" && -e "$TAILSCALED_MANAGED_BIN" ]]; then
  die "$TAILSCALED_MANAGED_BIN exists without a repo-managed plist. Refusing to remove it automatically."
fi

echo "Stopping $TAILSCALED_DAEMON_LABEL if it is loaded ..."
bootout_launchdaemon || true

if [[ -f "$TAILSCALED_DAEMON_PLIST" ]]; then
  echo "Removing $TAILSCALED_DAEMON_PLIST ..."
  "$RM_BIN" "$TAILSCALED_DAEMON_PLIST"
else
  echo "LaunchDaemon plist not found, skipping."
fi

if [[ -f "$TAILSCALED_MANAGED_BIN" ]]; then
  echo "Removing $TAILSCALED_MANAGED_BIN ..."
  "$RM_BIN" "$TAILSCALED_MANAGED_BIN"
fi

echo ""
echo "Done. The managed tailscaled LaunchDaemon has been removed."
