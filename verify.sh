#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0
TAILNET_TARGET=""
MAGICDNS_NAME=""
CHECK_MULLVAD=1

usage() {
  cat <<EOF
Usage: bash verify.sh [--interface utunX] [--tailnet-target host] [--magicdns-name name.ts.net] [--no-mullvad-check]

Performs configuration checks plus optional active validation:
  --tailnet-target  Run 'tailscale ping --c 1 --timeout 5s' against a tailnet peer.
  --magicdns-name   Resolve a MagicDNS name directly via 100.100.100.100.
  --no-mullvad-check Skip the curl check against https://am.i.mullvad.net/connected.
EOF
}

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN=$((WARN + 1)); }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interface)
      [[ $# -ge 2 ]] || die "--interface requires a value."
      TAILSCALE_INTERFACE="$2"
      shift 2
      ;;
    --tailnet-target)
      [[ $# -ge 2 ]] || die "--tailnet-target requires a value."
      TAILNET_TARGET="$2"
      shift 2
      ;;
    --magicdns-name)
      [[ $# -ge 2 ]] || die "--magicdns-name requires a value."
      MAGICDNS_NAME="$2"
      shift 2
      ;;
    --no-mullvad-check)
      CHECK_MULLVAD=0
      shift
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

echo "=== Tailscale + Mullvad PF Anchor Verification ==="
echo ""

echo "1. Anchor file"
if [[ -f "$ANCHOR_FILE" ]]; then
  pass "$ANCHOR_FILE exists"
  installed_interface="$(anchor_interface_from_file "$ANCHOR_FILE")"
  if [[ -n "$installed_interface" ]]; then
    pass "Installed anchor targets $installed_interface"
  else
    fail "Unable to determine interface from $ANCHOR_FILE"
  fi
else
  fail "$ANCHOR_FILE not found - run install.sh"
  installed_interface=""
fi

echo "2. pf.conf configuration"
if has_exact_line "$PF_CONF" "$ANCHOR_LINE"; then
  pass "Anchor reference present in $PF_CONF"
else
  fail "Exact anchor reference missing from $PF_CONF - run install.sh"
fi

if has_exact_line "$PF_CONF" "$LOAD_LINE"; then
  pass "Load directive present in $PF_CONF"
else
  fail "Exact load directive missing from $PF_CONF - run install.sh"
fi

echo "3. Tailscale interface"
active_interface="$(detect_tailscale_interface || true)"
if [[ -n "$active_interface" ]]; then
  pass "Detected active Tailscale interface: $active_interface"
  if [[ -n "$installed_interface" && "$installed_interface" == "$active_interface" ]]; then
    pass "Installed anchor interface matches the active Tailscale interface"
  elif [[ -n "$installed_interface" ]]; then
    fail "Installed anchor targets $installed_interface but Tailscale is using $active_interface"
  fi
else
  warn "Could not auto-detect an active Tailscale utun interface"
fi

echo "4. PF runtime state"
if [[ $EUID -ne 0 ]]; then
  warn "Not running as root - skipping PF runtime checks (re-run with sudo)"
else
  anchor_rules="$("$PFCTL_BIN" -a "$TAILSCALE_ANCHOR_NAME" -sr 2>/dev/null || true)"
  if [[ -n "$anchor_rules" ]]; then
    pass "Anchor is loaded in PF"
    if grep -q "$TAILSCALE_IPV4_RANGE" <<<"$anchor_rules"; then
      pass "IPv4 CGNAT rules present"
    else
      fail "IPv4 CGNAT rules missing from the loaded anchor"
    fi
    if grep -q "$TAILSCALE_IPV6_RANGE" <<<"$anchor_rules"; then
      pass "IPv6 ULA rules present"
    else
      fail "IPv6 ULA rules missing from the loaded anchor"
    fi
    if [[ -n "$installed_interface" ]] && grep -q "on $installed_interface " <<<"$anchor_rules"; then
      pass "Loaded anchor rules target the installed interface"
    elif [[ -n "$installed_interface" ]]; then
      fail "Loaded anchor rules do not target the installed interface"
    fi
  else
    fail "Anchor is not loaded in PF - try: sudo pfctl -f $PF_CONF"
  fi
fi

echo "5. Daemon state"
if "$PGREP_BIN" -q tailscaled 2>/dev/null; then
  pass "tailscaled is running"
else
  warn "tailscaled is not running"
fi

if "$PGREP_BIN" -qf "mullvad-daemon" 2>/dev/null; then
  pass "mullvad-daemon is running"
else
  warn "mullvad-daemon is not running"
fi

if [[ -f "$TAILSCALED_DAEMON_PLIST" ]]; then
  pass "Managed tailscaled LaunchDaemon plist exists"
else
  warn "Managed tailscaled LaunchDaemon plist not found"
fi

echo "6. Active checks"
if [[ -n "$TAILNET_TARGET" ]]; then
  if "$TAILSCALE_BIN" ping --c 1 --timeout 5s "$TAILNET_TARGET" >/dev/null 2>&1; then
    pass "tailscale ping succeeded for $TAILNET_TARGET"
  else
    fail "tailscale ping failed for $TAILNET_TARGET"
  fi
else
  warn "No --tailnet-target provided; skipping active tailnet connectivity check"
fi

if [[ -n "$MAGICDNS_NAME" ]]; then
  if [[ -n "$("$DIG_BIN" +short @100.100.100.100 "$MAGICDNS_NAME" 2>/dev/null)" ]]; then
    pass "MagicDNS resolved $MAGICDNS_NAME via 100.100.100.100"
  else
    fail "MagicDNS lookup failed for $MAGICDNS_NAME"
  fi
else
  warn "No --magicdns-name provided; skipping MagicDNS resolution check"
fi

if [[ "$CHECK_MULLVAD" -eq 1 ]]; then
  mullvad_check="$("$CURL_BIN" -fsS https://am.i.mullvad.net/connected 2>/dev/null || true)"
  if grep -qi "not connected to Mullvad" <<<"$mullvad_check"; then
    fail "Mullvad connection check reported traffic outside the Mullvad tunnel"
  elif grep -qi "connected to Mullvad" <<<"$mullvad_check"; then
    pass "Mullvad connection check reported a Mullvad tunnel"
  elif [[ -n "$mullvad_check" ]]; then
    warn "Mullvad connection check returned an unexpected response"
  else
    warn "Unable to reach https://am.i.mullvad.net/connected"
  fi
else
  warn "Skipped Mullvad connection check by request"
fi

echo ""
echo "=== Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${WARN} warnings${NC} ==="

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}Some checks failed. Review install.sh, verify.sh, or your local VPN state before proceeding.${NC}"
  exit 1
fi
