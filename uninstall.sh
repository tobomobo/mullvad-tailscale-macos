#!/bin/bash
set -euo pipefail

# Remove the Tailscale PF anchor and restore pf.conf.
# Must be run with sudo.

if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run with sudo." >&2
  exit 1
fi

ANCHOR_FILE="/etc/pf.anchors/tailscale"
PF_CONF="/etc/pf.conf"

# --- Remove anchor from pf.conf ---

if grep -qF 'anchor "tailscale"' "$PF_CONF"; then
  echo "Backing up $PF_CONF to ${PF_CONF}.bak.$(date +%Y%m%d%H%M%S) ..."
  cp "$PF_CONF" "${PF_CONF}.bak.$(date +%Y%m%d%H%M%S)"

  echo "Removing Tailscale anchor lines from $PF_CONF ..."
  sed -i '' '/# Tailscale anchor/d' "$PF_CONF"
  sed -i '' '/anchor "tailscale"/d' "$PF_CONF"
  sed -i '' '\|load anchor "tailscale"|d' "$PF_CONF"
else
  echo "No Tailscale anchor found in $PF_CONF, skipping."
fi

# --- Remove anchor file ---

if [[ -f "$ANCHOR_FILE" ]]; then
  echo "Removing $ANCHOR_FILE ..."
  rm "$ANCHOR_FILE"
else
  echo "Anchor file $ANCHOR_FILE not found, skipping."
fi

# --- Reload PF ---

echo "Reloading PF rules ..."
pfctl -f "$PF_CONF" 2>/dev/null

echo ""
echo "Done. Tailscale anchor has been removed."
