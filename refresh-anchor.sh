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
the anchor with the same validation used by install.sh, then reloads only the
runtime anchor; it does not modify /etc/pf.conf.

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

if [[ "$installed_interface" == "$interface" && -f "$ANCHOR_FILE" ]] && anchor_runtime_rules_are_exact "$runtime_rules" "$interface"; then
  log_routine "Anchor already targets $interface and is loaded; nothing to do."
  exit 0
fi

tmp_anchor="$(make_temp_file tailscale-anchor)"
old_anchor="$(make_temp_file old-tailscale-anchor)"
anchor_existed=0
trap 'rm -f "$tmp_anchor" "$old_anchor"' EXIT

if [[ -f "$ANCHOR_FILE" ]]; then
  "$CP_BIN" "$ANCHOR_FILE" "$old_anchor"
  anchor_existed=1
fi

render_anchor_template "$ANCHOR_TEMPLATE" "$tmp_anchor" "$interface"
validate_anchor_policy_file "$tmp_anchor" "$interface" || die "Rendered anchor file is not the exact narrow policy or has syntax errors for $interface."

install_root_owned_file "$tmp_anchor" "$ANCHOR_FILE"
if ! load_runtime_anchor "$ANCHOR_FILE"; then
  if [[ "$anchor_existed" -eq 1 ]]; then
    install_root_owned_file "$old_anchor" "$ANCHOR_FILE"
  else
    "$RM_BIN" -f "$ANCHOR_FILE"
  fi
  die "Failed to reload the runtime anchor for $interface; restored the previous anchor file."
fi

runtime_rules="$(pf_anchor_rules "$TAILSCALE_ANCHOR_NAME" 2>/dev/null || true)"
if ! anchor_runtime_rules_are_exact "$runtime_rules" "$interface"; then
  if [[ "$anchor_existed" -eq 1 ]]; then
    install_root_owned_file "$old_anchor" "$ANCHOR_FILE"
    load_runtime_anchor "$ANCHOR_FILE" || die "CRITICAL: runtime verification failed and the previous anchor could not be restored."
  else
    "$RM_BIN" -f "$ANCHOR_FILE"
    flush_runtime_anchor || true
  fi
  die "Reloaded runtime anchor did not exactly match the expected four-rule policy; restored the previous anchor."
fi

echo "Reattached the PF anchor to $interface."
