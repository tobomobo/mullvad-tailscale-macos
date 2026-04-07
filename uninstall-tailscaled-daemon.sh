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

echo "Stopping $TAILSCALED_DAEMON_LABEL if it is loaded ..."
bootout_launchdaemon || true

if [[ -f "$TAILSCALED_DAEMON_PLIST" ]]; then
  echo "Removing $TAILSCALED_DAEMON_PLIST ..."
  "$RM_BIN" "$TAILSCALED_DAEMON_PLIST"
else
  echo "LaunchDaemon plist not found, skipping."
fi

echo ""
echo "Done. The managed tailscaled LaunchDaemon has been removed."
