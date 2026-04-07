#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo bash install.sh [--interface utunX]

Installs or updates the PF anchor that lets Tailscale traffic pass alongside
Mullvad's PF-based kill switch. By default the script auto-detects the active
Tailscale utun interface from the current ifconfig output.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interface)
      [[ $# -ge 2 ]] || die "--interface requires a value."
      TAILSCALE_INTERFACE="$2"
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

require_root

if [[ ! -f "$ANCHOR_TEMPLATE" ]]; then
  die "Cannot find anchor template at $ANCHOR_TEMPLATE"
fi

interface="$(detect_tailscale_interface)" || die "Unable to detect Tailscale's utun interface. Start Tailscale first or rerun with --interface utunX."
tmp_anchor="$(make_temp_file tailscale-anchor)"
tmp_pf_conf="$(make_temp_file pf-conf)"
trap 'rm -f "$tmp_anchor" "$tmp_pf_conf"' EXIT

render_anchor_template "$ANCHOR_TEMPLATE" "$tmp_anchor" "$interface"
validate_anchor_file "$tmp_anchor" || die "Rendered anchor file has syntax errors."

echo "Installing anchor rules for $interface to $ANCHOR_FILE ..."
install_root_owned_file "$tmp_anchor" "$ANCHOR_FILE"

ensure_anchor_block "$PF_CONF" "$tmp_pf_conf"

if file_differs "$PF_CONF" "$tmp_pf_conf"; then
  validate_pf_conf "$tmp_pf_conf" || die "Updated pf.conf failed validation."
  echo "Applying PF config update ..."
  backup_path="$(apply_pf_conf_update "$tmp_pf_conf")" || die "Failed to reload PF after updating $PF_CONF. Original config was restored."
  echo "Backed up $PF_CONF to $backup_path"
else
  echo "pf.conf already contains the exact anchor block. Refreshing runtime anchor only ..."
  load_runtime_anchor "$ANCHOR_FILE" || die "Failed to refresh runtime anchor rules."
fi

echo ""
echo "Done. Verifying anchor is loaded:"
"$PFCTL_BIN" -a "$TAILSCALE_ANCHOR_NAME" -sr 2>/dev/null || true

echo ""
echo "Tailscale traffic should now pass through Mullvad's kill switch on $interface."
