#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo bash install.sh [--interface utunX]

Installs or updates the PF anchor that lets Tailscale traffic pass alongside
Mullvad's PF-based kill switch. By default the script auto-detects the active
Tailscale utun interface by matching the output of tailscale ip to the current ifconfig
output. Full PF reloads preserve and recheck Mullvad's active anchor.
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
old_anchor="$(make_temp_file old-tailscale-anchor)"
anchor_existed=0
pf_conf_changed=0
trap 'rm -f "$tmp_anchor" "$tmp_pf_conf" "$old_anchor"' EXIT

restore_previous_anchor_file() {
  if [[ "$anchor_existed" -eq 1 ]]; then
    install_root_owned_file "$old_anchor" "$ANCHOR_FILE"
  else
    "$RM_BIN" -f "$ANCHOR_FILE"
  fi
}

if [[ -f "$ANCHOR_FILE" ]]; then
  anchor_file_managed_by_repo "$ANCHOR_FILE" || die "$ANCHOR_FILE exists but is not a recognized repo-managed anchor. Refusing to overwrite it."
  "$CP_BIN" "$ANCHOR_FILE" "$old_anchor"
  anchor_existed=1
elif managed_anchor_block_is_exact "$PF_CONF"; then
  echo "Repairing missing $ANCHOR_FILE referenced by the existing managed pf.conf block ..."
fi

render_anchor_template "$ANCHOR_TEMPLATE" "$tmp_anchor" "$interface"
validate_anchor_policy_file "$tmp_anchor" "$interface" || die "Rendered anchor file is not the exact narrow Tailscale policy or has syntax errors."
mullvad_pf_protection_is_consistent || die "Mullvad reports active protection, but its PF anchor is missing or empty. Refusing to attach the Tailscale exception."
lockdown_status="$(mullvad_lockdown_status 2>/dev/null || true)"
if [[ -n "$lockdown_status" ]] && ! mullvad_lockdown_is_enabled "$lockdown_status"; then
  echo "Warning: Mullvad lockdown mode is not enabled; installation can continue, but verify.sh will fail until you run: mullvad lockdown-mode set on" >&2
fi

echo "Installing anchor rules for $interface to $ANCHOR_FILE ..."
install_root_owned_file "$tmp_anchor" "$ANCHOR_FILE"

ensure_anchor_block "$PF_CONF" "$tmp_pf_conf"

if file_differs "$PF_CONF" "$tmp_pf_conf"; then
  if ! validate_pf_conf "$tmp_pf_conf"; then
    restore_previous_anchor_file
    die "Updated pf.conf failed validation; restored the previous anchor file."
  fi
  pf_conf_changed=1
  echo "Applying PF config update ..."
  if ! backup_path="$(apply_pf_conf_update "$tmp_pf_conf")"; then
    restore_previous_anchor_file
    die "Failed to reload PF safely after updating $PF_CONF. Original configuration and anchor were restored."
  fi
  echo "Backed up $PF_CONF to $backup_path"
else
  echo "pf.conf already contains the exact anchor block. Refreshing runtime anchor only ..."
  if ! load_runtime_anchor "$ANCHOR_FILE"; then
    restore_previous_anchor_file
    die "Failed to refresh runtime anchor rules; restored the previous anchor file."
  fi
fi

runtime_rules="$(pf_anchor_rules "$TAILSCALE_ANCHOR_NAME" 2>/dev/null || true)"
if ! anchor_runtime_rules_are_exact "$runtime_rules" "$interface"; then
  print_anchor_runtime_mismatch "$runtime_rules" "$interface"
  restore_previous_anchor_file
  if [[ "$pf_conf_changed" -eq 1 ]]; then
    apply_pf_conf_update "$backup_path" >/dev/null || die "CRITICAL: runtime anchor verification failed and the previous PF configuration could not be restored."
  elif [[ "$anchor_existed" -eq 1 ]]; then
    load_runtime_anchor "$ANCHOR_FILE" || die "CRITICAL: runtime anchor verification failed and the previous runtime anchor could not be restored."
  else
    flush_runtime_anchor || true
  fi
  die "Loaded runtime anchor did not exactly match the expected four-rule policy; restored the previous configuration."
fi

echo ""
echo "Done. Verifying anchor is loaded:"
"$PFCTL_BIN" -a "$TAILSCALE_ANCHOR_NAME" -sr 2>/dev/null || true

echo ""
echo "Installed the interface-scoped Tailscale PF exception on $interface."
echo "Run sudo bash verify.sh while Mullvad is connected to validate the combined live state."
