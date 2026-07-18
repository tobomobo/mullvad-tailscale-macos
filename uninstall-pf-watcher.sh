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

if [[ -f "$PF_WATCHER_PLIST" ]] && ! plist_managed_by_repo "$PF_WATCHER_PLIST" && \
  ! legacy_pf_watcher_plist_managed_by_repo "$PF_WATCHER_PLIST"; then
  die "$PF_WATCHER_PLIST is not recognized as repo-managed. Refusing to stop or remove it."
fi

if [[ -d "$PF_WATCHER_INSTALL_DIR" ]] && ! pf_watcher_payload_managed_by_repo && \
  ! legacy_pf_watcher_payload_managed_by_repo; then
  die "$PF_WATCHER_INSTALL_DIR is not recognized as a repo-managed payload. Refusing to remove it."
fi

echo "Stopping $PF_WATCHER_LABEL if it is loaded ..."
bootout_launchd "$PF_WATCHER_LABEL" || true

if [[ -f "$PF_WATCHER_PLIST" ]]; then
  echo "Removing $PF_WATCHER_PLIST ..."
  "$RM_BIN" "$PF_WATCHER_PLIST"
else
  echo "LaunchDaemon plist not found, skipping."
fi

if [[ -n "$PF_WATCHER_INSTALL_DIR" && -d "$PF_WATCHER_INSTALL_DIR" ]]; then
  echo "Removing $PF_WATCHER_INSTALL_DIR ..."
  "$RM_BIN" -rf "$PF_WATCHER_INSTALL_DIR"
else
  echo "Watcher payload directory not found, skipping."
fi

echo ""
echo "Done. The pf-watcher LaunchDaemon has been removed."
