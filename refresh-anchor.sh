#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

# Routine "nothing changed" status lines would otherwise be appended to the
# pf-watcher log on every poll (the daemon re-checks about every two minutes),
# growing it without bound. Only print them on an interactive terminal;
# actionable output (reattachment, errors via die) is always shown.
log_routine() {
  if [[ -t 1 ]]; then
    echo "$@"
  fi
}

usage() {
  cat <<EOF
Usage: sudo bash refresh-anchor.sh [--interface utunX]

Re-detects Tailscale's active utun interface and reattaches the PF anchor to it
if the interface changed (or the anchor is not currently loaded). It re-renders
the anchor with the same validation used by install.sh. It normally reloads only
the runtime anchor. If the main PF ruleset no longer calls Tailscale before
Mullvad, it safely reloads the existing managed pf.conf without changing its
persistent content.

This is what the pf-watcher LaunchDaemon runs on network changes. It is safe to
run repeatedly and is a no-op when the anchor already targets the active
interface.
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

interface="$(detect_tailscale_interface)" || {
  log_routine "No active Tailscale utun interface detected; leaving the anchor unchanged."
  exit 0
}

installed_interface=""
if [[ -f "$ANCHOR_FILE" ]]; then
  anchor_file_managed_by_repo "$ANCHOR_FILE" || die "$ANCHOR_FILE exists but is not a recognized repo-managed anchor. Refusing to overwrite it."
  installed_interface="$(anchor_interface_from_file "$ANCHOR_FILE" 2>/dev/null || true)"
fi

runtime_rules="$("$PFCTL_BIN" -a "$TAILSCALE_ANCHOR_NAME" -sr 2>/dev/null || true)"
mullvad_pf_protection_is_consistent || die "Mullvad reports active protection, but its PF anchor is missing or empty. Refusing to attach the Tailscale exception."
main_anchor_call_safe=0
if tailscale_main_anchor_call_is_safe; then
  main_anchor_call_safe=1
elif ! managed_anchor_block_is_exact "$PF_CONF"; then
  die "The main PF ruleset does not safely call Tailscale, and $PF_CONF does not contain the exact managed anchor block. Run install.sh to repair it."
fi

if [[ "$installed_interface" == "$interface" && -f "$ANCHOR_FILE" && "$main_anchor_call_safe" -eq 1 ]] && anchor_runtime_rules_are_exact "$runtime_rules" "$interface"; then
  log_routine "Anchor already targets $interface and is loaded; nothing to do."
  exit 0
fi

tmp_anchor="$(make_temp_file tailscale-anchor)"
old_anchor="$(make_temp_file old-tailscale-anchor)"
tmp_pf_conf="$(make_temp_file pf-conf)"
anchor_existed=0
pf_conf_reloaded=0
trap 'rm -f "$tmp_anchor" "$old_anchor" "$tmp_pf_conf"' EXIT

if [[ -f "$ANCHOR_FILE" ]]; then
  "$CP_BIN" "$ANCHOR_FILE" "$old_anchor"
  anchor_existed=1
fi

render_anchor_template "$ANCHOR_TEMPLATE" "$tmp_anchor" "$interface"
validate_anchor_policy_file "$tmp_anchor" "$interface" || die "Rendered anchor file is not the exact narrow policy or has syntax errors for $interface."

install_root_owned_file "$tmp_anchor" "$ANCHOR_FILE"
if [[ "$main_anchor_call_safe" -eq 0 ]]; then
  "$CP_BIN" "$PF_CONF" "$tmp_pf_conf"
  validate_pf_conf "$tmp_pf_conf" || {
    if [[ "$anchor_existed" -eq 1 ]]; then
      install_root_owned_file "$old_anchor" "$ANCHOR_FILE"
    else
      "$RM_BIN" -f "$ANCHOR_FILE"
    fi
    die "Existing managed pf.conf failed validation; restored the previous anchor file."
  }
  echo "Restoring the missing or misordered Tailscale call in the main PF ruleset ..."
  pf_conf_reloaded=1
  if ! backup_path="$(apply_pf_conf_update "$tmp_pf_conf")"; then
    if [[ "$anchor_existed" -eq 1 ]]; then
      install_root_owned_file "$old_anchor" "$ANCHOR_FILE"
    else
      "$RM_BIN" -f "$ANCHOR_FILE"
    fi
    die "Failed to restore the active Tailscale anchor call safely; restored the previous anchor file and PF configuration."
  fi
elif ! load_runtime_anchor "$ANCHOR_FILE"; then
  if [[ "$anchor_existed" -eq 1 ]]; then
    install_root_owned_file "$old_anchor" "$ANCHOR_FILE"
  else
    "$RM_BIN" -f "$ANCHOR_FILE"
  fi
  die "Failed to reload the runtime anchor for $interface; restored the previous anchor file."
fi

runtime_rules="$(pf_anchor_rules "$TAILSCALE_ANCHOR_NAME" 2>/dev/null || true)"
runtime_policy_exact=0
main_anchor_call_safe=0
if anchor_runtime_rules_are_exact "$runtime_rules" "$interface"; then
  runtime_policy_exact=1
else
  print_anchor_runtime_mismatch "$runtime_rules" "$interface"
fi
if tailscale_main_anchor_call_is_safe; then
  main_anchor_call_safe=1
else
  echo "The main PF ruleset still does not call Tailscale before Mullvad." >&2
fi
if [[ "$runtime_policy_exact" -ne 1 || "$main_anchor_call_safe" -ne 1 ]]; then
  if [[ "$anchor_existed" -eq 1 ]]; then
    install_root_owned_file "$old_anchor" "$ANCHOR_FILE"
  else
    "$RM_BIN" -f "$ANCHOR_FILE"
  fi
  if [[ "$pf_conf_reloaded" -eq 1 ]]; then
    apply_pf_conf_update "$backup_path" >/dev/null || die "CRITICAL: verification failed and the previous PF configuration could not be restored."
  elif [[ "$anchor_existed" -eq 1 ]]; then
    load_runtime_anchor "$ANCHOR_FILE" || die "CRITICAL: runtime verification failed and the previous anchor could not be restored."
  else
    flush_runtime_anchor || true
  fi
  die "The refreshed runtime policy or main PF anchor call failed verification; restored the previous configuration."
fi

echo "Reattached the PF anchor to $interface and verified its main-ruleset call."
