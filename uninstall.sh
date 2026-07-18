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

if [[ -f "$ANCHOR_FILE" ]]; then
  anchor_file_managed_by_repo "$ANCHOR_FILE" || die "$ANCHOR_FILE exists but is not a recognized repo-managed anchor. Refusing to remove or detach it."
fi

echo "Removing the automatic PF watcher ..."
/bin/bash "$SCRIPT_DIR/uninstall-pf-watcher.sh"
echo ""

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
  "$RM_BIN" "$ANCHOR_FILE"
else
  echo "Anchor file $ANCHOR_FILE not found, skipping."
fi

echo ""
echo "Done. Tailscale anchor has been removed."
