#!/bin/bash
set -euo pipefail

# Verify the Tailscale PF anchor is correctly installed and working.
# Run with sudo for full output.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; ((WARN++)); }

echo "=== Tailscale + Mullvad PF Anchor Verification ==="
echo ""

# --- 1. Check anchor file exists ---
echo "1. Anchor file"
if [[ -f /etc/pf.anchors/tailscale ]]; then
  pass "/etc/pf.anchors/tailscale exists"
else
  fail "/etc/pf.anchors/tailscale not found — run install.sh"
fi

# --- 2. Check pf.conf references ---
echo "2. pf.conf configuration"
if grep -qF 'anchor "tailscale"' /etc/pf.conf 2>/dev/null; then
  pass "Anchor reference present in /etc/pf.conf"
else
  fail "Anchor reference missing from /etc/pf.conf — run install.sh"
fi

if grep -qF 'load anchor "tailscale"' /etc/pf.conf 2>/dev/null; then
  pass "Load directive present in /etc/pf.conf"
else
  fail "Load directive missing from /etc/pf.conf — run install.sh"
fi

# --- 3. Check anchor is loaded in PF (requires root) ---
echo "3. PF runtime state"
if [[ $EUID -ne 0 ]]; then
  warn "Not running as root — skipping PF runtime checks (re-run with sudo)"
else
  ANCHOR_RULES=$(pfctl -a tailscale -sr 2>/dev/null || true)
  if [[ -n "$ANCHOR_RULES" ]]; then
    pass "Anchor is loaded in PF"
    if echo "$ANCHOR_RULES" | grep -q "100.64.0.0/10"; then
      pass "IPv4 CGNAT rules present"
    else
      fail "IPv4 CGNAT rules missing from loaded anchor"
    fi
    if echo "$ANCHOR_RULES" | grep -q "fd7a:115c:a1e0::/48"; then
      pass "IPv6 ULA rules present"
    else
      fail "IPv6 ULA rules missing from loaded anchor"
    fi
  else
    fail "Anchor is not loaded in PF — try: sudo pfctl -f /etc/pf.conf"
  fi
fi

# --- 4. Check Tailscale interface ---
echo "4. Tailscale interface"
if ifconfig utun0 >/dev/null 2>&1; then
  pass "utun0 interface exists"
  if ifconfig utun0 2>/dev/null | grep -q "100\."; then
    pass "utun0 has a CGNAT-range address (likely Tailscale)"
  else
    warn "utun0 exists but has no CGNAT address — may not be Tailscale"
  fi
else
  warn "utun0 interface not found — Tailscale may not be running, or may be using a different interface"
fi

# --- 5. Check Tailscale is running ---
echo "5. Tailscale daemon"
if pgrep -q tailscaled 2>/dev/null; then
  pass "tailscaled is running"
else
  warn "tailscaled is not running"
fi

# --- 6. Check Mullvad is running ---
echo "6. Mullvad daemon"
if pgrep -qf "mullvad-daemon" 2>/dev/null; then
  pass "mullvad-daemon is running"
else
  warn "mullvad-daemon is not running"
fi

# --- Summary ---
echo ""
echo "=== Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${WARN} warnings${NC} ==="

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}Some checks failed. Run sudo bash install.sh to fix.${NC}"
  exit 1
fi
