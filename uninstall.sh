#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo bash uninstall.sh

Removes the automatic PF watcher, the managed PF anchor block from pf.conf, and
the installed anchor file. A full PF reload preserves and rechecks Mullvad's
active anchor.
EOF
}

parse_help_only "$@"

require_root

if [[ -f "$ANCHOR_FILE" ]]; then
  anchor_file_managed_by_repo "$ANCHOR_FILE" || die "$ANCHOR_FILE exists but is not a recognized repo-managed anchor. Refusing to remove or detach it."
fi

# Preflight the watcher removal before touching PF. The watcher is removed last
# so a refused PF reload leaves everything in place; this check keeps the
# reverse failure (PF removed, unrecognized watcher left loaded) from happening.
if [[ -f "$PF_WATCHER_PLIST" ]] && ! plist_managed_by_repo "$PF_WATCHER_PLIST"; then
  die "$PF_WATCHER_PLIST is not recognized as repo-managed. Run uninstall-pf-watcher.sh for the manual removal steps, then rerun uninstall.sh."
fi
if [[ -d "$PF_WATCHER_INSTALL_DIR" ]] && ! pf_watcher_payload_managed_by_repo; then
  die "$PF_WATCHER_INSTALL_DIR is not recognized as a repo-managed payload. Run uninstall-pf-watcher.sh for the manual removal steps, then rerun uninstall.sh."
fi

tmp_pf_conf="$(make_temp_file pf-conf)"
trap 'rm -f "$tmp_pf_conf"' EXIT

remove_anchor_block "$PF_CONF" "$tmp_pf_conf"

if file_differs "$PF_CONF" "$tmp_pf_conf"; then
  validate_pf_conf "$tmp_pf_conf" || die "Updated pf.conf failed validation."
  echo "Removing managed anchor block from $PF_CONF ..."
  backup_path="$(apply_pf_conf_update "$tmp_pf_conf")" || die "Failed to reload PF after updating $PF_CONF. Original config was restored."
  echo "Backed up $PF_CONF to $backup_path"
else
  echo "Managed anchor block is already absent from $PF_CONF."
  flush_runtime_anchor || true
fi

if [[ -f "$ANCHOR_FILE" ]]; then
  echo "Removing $ANCHOR_FILE ..."
  rm "$ANCHOR_FILE"
else
  echo "Anchor file $ANCHOR_FILE not found, skipping."
fi

# Last, so a refused PF reload above leaves the exception and its watcher
# both in place rather than an unwatched exception.
echo ""
echo "Removing the automatic PF watcher ..."
/bin/bash "$SCRIPT_DIR/uninstall-pf-watcher.sh"

echo ""
echo "Done. Tailscale anchor has been removed."
