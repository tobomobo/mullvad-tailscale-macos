#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo bash uninstall-pf-watcher.sh

Removes the pf-watcher LaunchDaemon and its installed payload. This does not
touch the PF anchor itself or /etc/pf.conf; use uninstall.sh for that.
EOF
}

parse_help_only "$@"

require_root

# Installs predating the ownership markers are not recognized, and there is no
# adoption flag on the removal path, so name the manual steps instead of leaving
# the operator with no way to finish an uninstall.
MANUAL_REMOVAL_HINT="If this is an install from an earlier revision of this repo, inspect it, then remove it by hand and rerun uninstall.sh:
  sudo launchctl bootout system/$PF_WATCHER_LABEL
  sudo rm -f '$PF_WATCHER_PLIST'
  sudo rm -rf '$PF_WATCHER_INSTALL_DIR'"

if [[ -f "$PF_WATCHER_PLIST" ]] && ! plist_managed_by_repo "$PF_WATCHER_PLIST"; then
  die "$PF_WATCHER_PLIST is not recognized as repo-managed. Refusing to stop or remove it.
$MANUAL_REMOVAL_HINT"
fi

if [[ -d "$PF_WATCHER_INSTALL_DIR" ]] && ! pf_watcher_payload_managed_by_repo; then
  die "$PF_WATCHER_INSTALL_DIR is not recognized as a repo-managed payload. Refusing to remove it.
$MANUAL_REMOVAL_HINT"
fi

echo "Stopping $PF_WATCHER_LABEL if it is loaded ..."
bootout_launchd "$PF_WATCHER_LABEL" || true

if [[ -f "$PF_WATCHER_PLIST" ]]; then
  echo "Removing $PF_WATCHER_PLIST ..."
  rm "$PF_WATCHER_PLIST"
else
  echo "LaunchDaemon plist not found, skipping."
fi

if [[ -n "$PF_WATCHER_INSTALL_DIR" && -d "$PF_WATCHER_INSTALL_DIR" ]]; then
  echo "Removing $PF_WATCHER_INSTALL_DIR ..."
  rm -rf "$PF_WATCHER_INSTALL_DIR"
else
  echo "Watcher payload directory not found, skipping."
fi

echo ""
echo "Done. The pf-watcher LaunchDaemon has been removed."
