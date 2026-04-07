#!/bin/bash
set -euo pipefail

# Install PF anchor to allow Tailscale traffic alongside Mullvad VPN.
# Must be run with sudo.

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run with sudo." >&2
  exit 1
fi

ANCHOR_FILE="/etc/pf.anchors/tailscale"
PF_CONF="/etc/pf.conf"
ANCHOR_LINE='anchor "tailscale"'
LOAD_LINE='load anchor "tailscale" from "/etc/pf.anchors/tailscale"'

# --- Install the anchor rules file ---

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ANCHOR="$SCRIPT_DIR/etc/pf.anchors/tailscale"

if [[ ! -f "$SOURCE_ANCHOR" ]]; then
  echo "Error: Cannot find anchor rules at $SOURCE_ANCHOR" >&2
  exit 1
fi

echo "Installing anchor rules to $ANCHOR_FILE ..."
cp "$SOURCE_ANCHOR" "$ANCHOR_FILE"
chown root:wheel "$ANCHOR_FILE"
chmod 644 "$ANCHOR_FILE"

# --- Validate the anchor file syntax ---

if ! pfctl -n -f "$ANCHOR_FILE" 2>/dev/null; then
  echo "Error: Anchor file has syntax errors." >&2
  exit 1
fi

# --- Add anchor to pf.conf (idempotent) ---

if grep -qF "$ANCHOR_LINE" "$PF_CONF"; then
  echo "Anchor reference already present in $PF_CONF, skipping."
else
  echo "Backing up $PF_CONF to ${PF_CONF}.bak.$(date +%Y%m%d%H%M%S) ..."
  cp "$PF_CONF" "${PF_CONF}.bak.$(date +%Y%m%d%H%M%S)"

  echo "Adding anchor to $PF_CONF ..."
  printf '\n# Tailscale anchor — allow CGNAT range through Mullvad kill switch\n%s\n%s\n' \
    "$ANCHOR_LINE" "$LOAD_LINE" >> "$PF_CONF"
fi

# --- Load the rules ---

echo "Loading PF rules ..."
pfctl -f "$PF_CONF" 2>/dev/null

echo ""
echo "Done. Verifying anchor is loaded:"
pfctl -a tailscale -sr 2>/dev/null

echo ""
echo "Tailscale traffic should now pass through Mullvad's kill switch."
