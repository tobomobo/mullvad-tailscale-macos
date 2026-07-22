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
TAILNET_DOMAIN=""
MAGICDNS_NAME=""
CHECK_MULLVAD=1

usage() {
  cat <<EOF
Usage: bash verify.sh [--interface utunX] [--tailnet-target host] [--tailnet-domain domain.ts.net] [--magicdns-name name.ts.net] [--no-mullvad-check]

Performs configuration checks plus optional active validation:
  --tailnet-target  Run a TSMP reachability check plus a DISCO direct-path probe against a tailnet peer.
  --tailnet-domain Validate an optional /etc/resolver override for a tailnet domain.
  --magicdns-name   Validate direct MagicDNS plus macOS hostname resolution for a MagicDNS name.
  --no-mullvad-check Skip the curl check against https://am.i.mullvad.net/connected.
EOF
}

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARN=$((WARN + 1)); }

print_magicdns_followups() {
  local hostname="$1"
  local suggested_tailnet_domain=""

  if [[ "$hostname" == *.* ]]; then
    suggested_tailnet_domain="${hostname#*.}"
  fi

  echo "      Follow up: grep -nF '$hostname' $HOSTS_FILE"
  echo "      Follow up: dscacheutil -q host -a name $hostname"
  echo "      Follow up: dig +short @$TAILSCALE_MAGICDNS_SERVER $hostname"
  echo "      Follow up: scutil --dns"
  if [[ -n "$suggested_tailnet_domain" && "$suggested_tailnet_domain" != "$hostname" ]] && validate_tailnet_domain "$suggested_tailnet_domain"; then
    echo "      Optional: sudo bash install-tailnet-resolver.sh --tailnet-domain $suggested_tailnet_domain"
  fi
}

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
    --tailnet-domain)
      [[ $# -ge 2 ]] || die "--tailnet-domain requires a value."
      TAILNET_DOMAIN="$2"
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
    if anchor_file_managed_by_repo "$ANCHOR_FILE"; then
      pass "Anchor file has a recognized ownership marker and the exact four-rule policy"
    else
      fail "$ANCHOR_FILE is unmarked or contains rules outside the exact managed policy"
    fi
    if file_is_root_owned_and_not_writable "$ANCHOR_FILE"; then
      pass "Anchor file is a regular root-owned file with no ACL or group/other write access"
    else
      anchor_metadata="$(file_owner_and_mode "$ANCHOR_FILE" || true)"
      if [[ "$anchor_metadata" =~ ^([0-9]+)[[:space:]]+([0-7]{3,4})$ ]]; then
        fail "$ANCHOR_FILE is not a safe regular file ($STAT_BIN reported target owner UID ${BASH_REMATCH[1]}, mode ${BASH_REMATCH[2]}; expected a non-symlink with UID 0, no ACL, and no group/other write bits)"
      else
        fail "$ANCHOR_FILE ownership and permissions could not be read with $STAT_BIN"
      fi
    fi
  else
    fail "Unable to determine interface from $ANCHOR_FILE"
  fi
else
  fail "$ANCHOR_FILE not found - run install.sh"
  installed_interface=""
fi

echo "2. pf.conf configuration"
if managed_anchor_block_is_exact "$PF_CONF"; then
  pass "Exact, single managed anchor block is present in $PF_CONF"
else
  fail "Managed anchor block is missing, duplicated, or not contiguous in $PF_CONF - run install.sh"
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
if ! running_as_root; then
  warn "Not running as root - skipping PF runtime checks (re-run with sudo)"
else
  if pf_is_enabled; then
    pass "PF is enabled"
  else
    fail "PF is not enabled"
  fi

  if main_anchor_calls="$(pf_main_anchor_calls)"; then
    if pf_main_anchor_is_called "$TAILSCALE_ANCHOR_NAME" "$main_anchor_calls"; then
      pass "The main PF ruleset calls the Tailscale anchor"
    else
      fail "The Tailscale ruleset is loaded but the main PF ruleset does not call it"
    fi
    if pf_main_anchor_is_called "$MULLVAD_ANCHOR_NAME" "$main_anchor_calls"; then
      pass "The main PF ruleset calls the Mullvad anchor"
      mullvad_anchor_rules="$(pf_anchor_rules "$MULLVAD_ANCHOR_NAME" 2>/dev/null || true)"
      if [[ -n "$mullvad_anchor_rules" ]]; then
        pass "Mullvad anchor contains active firewall rules"
      else
        fail "The called Mullvad anchor contains no active firewall rules"
      fi
    else
      fail "The main PF ruleset does not call the Mullvad anchor; lockdown cannot be established from PF state"
    fi
  else
    fail "Unable to inspect main PF anchor calls"
  fi

  anchor_rules="$(pf_anchor_rules "$TAILSCALE_ANCHOR_NAME" 2>/dev/null || true)"
  if [[ -n "$installed_interface" ]] && anchor_runtime_rules_are_exact "$anchor_rules" "$installed_interface"; then
    pass "Runtime Tailscale anchor exactly matches the expected four-rule policy"
  else
    fail "Runtime Tailscale anchor is missing, broadened, duplicated, or targets the wrong interface"
    if [[ -n "$installed_interface" ]]; then
      print_anchor_runtime_mismatch "$anchor_rules" "$installed_interface"
    fi
  fi

  if [[ -n "${main_anchor_calls:-}" ]] && pf_anchor_precedes "$TAILSCALE_ANCHOR_NAME" "$MULLVAD_ANCHOR_NAME" "$main_anchor_calls"; then
    pass "Tailscale's quick exception is evaluated before Mullvad's anchor"
  else
    fail "Unable to establish that the Tailscale anchor precedes Mullvad's blocking anchor"
  fi
fi

echo "5. Daemon state"
tailscaled_running=0
if "$PGREP_BIN" -q tailscaled 2>/dev/null; then
  tailscaled_running=1
  pass "tailscaled is running"
else
  warn "tailscaled is not running"
fi

if "$PGREP_BIN" -qf "mullvad-daemon" 2>/dev/null; then
  pass "mullvad-daemon is running"
else
  warn "mullvad-daemon is not running"
fi

mullvad_status_output="$(mullvad_status 2>/dev/null || true)"
if [[ -n "$mullvad_status_output" ]] && mullvad_status_is_connected "$mullvad_status_output"; then
  pass "Mullvad reports an active VPN connection"
elif [[ -n "$mullvad_status_output" ]]; then
  fail "Mullvad does not report an active VPN connection"
else
  fail "Unable to query Mullvad connection status"
fi

mullvad_lockdown_output="$(mullvad_lockdown_status 2>/dev/null || true)"
if [[ -n "$mullvad_lockdown_output" ]] && mullvad_lockdown_is_enabled "$mullvad_lockdown_output"; then
  pass "Mullvad lockdown mode is enabled"
elif [[ -n "$mullvad_lockdown_output" ]]; then
  fail "Mullvad lockdown mode is not enabled; this repository's documented configuration requires it (enable it with: mullvad lockdown-mode set on)"
else
  fail "Unable to query Mullvad lockdown mode"
fi

if [[ -f "$TAILSCALED_DAEMON_PLIST" ]]; then
  if plist_managed_by_repo "$TAILSCALED_DAEMON_PLIST"; then
    pass "Repo-managed tailscaled LaunchDaemon plist exists"
    if launchdaemon_loaded; then
      pass "Repo-managed tailscaled LaunchDaemon is loaded"
    else
      fail "Repo-managed tailscaled LaunchDaemon is not loaded (inspect with: sudo launchctl print $(launchdaemon_service_target))"
    fi
    if plist_uses_program "$TAILSCALED_DAEMON_PLIST" "$TAILSCALED_MANAGED_BIN" && \
      [[ -x "$TAILSCALED_MANAGED_BIN" ]] && file_is_root_owned_and_not_writable "$TAILSCALED_MANAGED_BIN"; then
      pass "tailscaled LaunchDaemon uses a protected root-owned binary copy"
    else
      fail "tailscaled LaunchDaemon does not use the expected protected binary"
    fi
    if plist_discards_standard_streams "$TAILSCALED_DAEMON_PLIST"; then
      pass "tailscaled LaunchDaemon does not persist stdout/stderr metadata logs"
    else
      fail "tailscaled LaunchDaemon persists stdout/stderr; reinstall it to use the secure logging default"
    fi
  else
    warn "$TAILSCALED_DAEMON_PLIST exists but is not marked as managed by this repo"
    if launchdaemon_loaded; then
      pass "The unmarked tailscaled LaunchDaemon is loaded"
    else
      warn "The unmarked tailscaled LaunchDaemon is not loaded (inspect it before adopting it with install-tailscaled-daemon.sh --replace-existing)"
    fi
  fi
elif [[ "$tailscaled_running" -eq 1 ]]; then
  pass "No repo-managed tailscaled LaunchDaemon plist found; tailscaled appears to be managed elsewhere"
else
  warn "Managed tailscaled LaunchDaemon plist not found"
fi

if [[ -f "$PF_WATCHER_PLIST" ]]; then
  if plist_managed_by_repo "$PF_WATCHER_PLIST" && pf_watcher_payload_managed_by_repo; then
    pass "PF watcher plist and payload have repo ownership markers"
  elif legacy_pf_watcher_plist_managed_by_repo "$PF_WATCHER_PLIST" && legacy_pf_watcher_payload_managed_by_repo; then
    warn "PF watcher is a recognized legacy install without ownership markers; rerun install-pf-watcher.sh to migrate it"
  else
    fail "PF watcher plist or payload is not recognized as repo-managed"
  fi
  if plist_discards_standard_streams "$PF_WATCHER_PLIST"; then
    pass "PF watcher does not persist stdout/stderr metadata logs"
  else
    fail "PF watcher persists stdout/stderr; reinstall it to use the secure logging default"
  fi
  if launchd_loaded "$PF_WATCHER_LABEL"; then
    pass "PF watcher LaunchDaemon is loaded"
  else
    fail "PF watcher LaunchDaemon is not loaded (reinstall it and inspect launchctl errors)"
  fi
fi

echo "6. Mullvad content-blocker DNS"
if command -v "$SCUTIL_BIN" >/dev/null 2>&1; then
  blocker_dns="$(mullvad_blocker_dns_in_use)"
  if [[ -n "$blocker_dns" ]]; then
    if [[ -n "$active_interface" ]]; then
      warn "System DNS uses a Mullvad content-blocker address ($(join_lines "$blocker_dns")) inside Tailscale's $TAILSCALE_IPV4_RANGE range; Tailscale owns that range while it is up, so content-blocker DNS is expected to fail. See README: 'Mullvad DNS Content Blockers'."
    else
      warn "System DNS uses a Mullvad content-blocker address ($(join_lines "$blocker_dns")) inside $TAILSCALE_IPV4_RANGE; this collides with Tailscale's range whenever Tailscale is running. See README: 'Mullvad DNS Content Blockers'."
    fi
  else
    pass "No Mullvad content-blocker DNS collision detected (no 100.64.0.1-63 content-blocker resolver configured)"
  fi
else
  warn "scutil not found; skipping Mullvad content-blocker DNS collision check"
fi

echo "7. Active checks"
if [[ -n "$TAILNET_DOMAIN" ]]; then
  if validate_tailnet_domain "$TAILNET_DOMAIN"; then
    resolver_file="$(resolver_file_for_domain "$TAILNET_DOMAIN")"
    if [[ -f "$resolver_file" ]]; then
      if resolver_file_managed_by_repo "$resolver_file"; then
        pass "Repo-managed resolver override file exists for $TAILNET_DOMAIN at $resolver_file"
        if resolver_file_has_nameserver "$resolver_file" "$TAILSCALE_MAGICDNS_SERVER"; then
          pass "Resolver override points $TAILNET_DOMAIN at $TAILSCALE_MAGICDNS_SERVER"
        else
          fail "Resolver override for $TAILNET_DOMAIN does not point at $TAILSCALE_MAGICDNS_SERVER"
        fi
      else
        warn "Resolver file exists for $TAILNET_DOMAIN at $resolver_file, but it is not managed by this repo"
      fi
    else
      warn "No repo-managed resolver override file found for $TAILNET_DOMAIN at $resolver_file"
    fi
  else
    fail "Invalid --tailnet-domain value: $TAILNET_DOMAIN"
  fi
fi

if [[ -n "$TAILNET_TARGET" ]]; then
  if tsmp_output="$("$TAILSCALE_BIN" ping --tsmp --c 1 --timeout 5s "$TAILNET_TARGET" 2>&1)"; then
    pass "TSMP ping succeeded for $TAILNET_TARGET"
  else
    fail "TSMP ping failed for $TAILNET_TARGET"
  fi

  if disco_output="$("$TAILSCALE_BIN" ping --c 3 --timeout 5s "$TAILNET_TARGET" 2>&1)"; then
    pass "Direct or peer-routed DISCO path established for $TAILNET_TARGET"
  elif grep -qi "direct connection not established" <<<"$disco_output" || grep -qi "via DERP" <<<"$disco_output"; then
    warn "Tailnet reachability works, but no direct DISCO path was established for $TAILNET_TARGET; Tailscale is falling back to DERP"
  else
    warn "Unable to confirm a direct DISCO path for $TAILNET_TARGET"
  fi
else
  warn "No --tailnet-target provided; skipping active tailnet connectivity check"
fi

if [[ -n "$MAGICDNS_NAME" ]]; then
  if [[ -n "$TAILNET_DOMAIN" && "$MAGICDNS_NAME" != *."$TAILNET_DOMAIN" && "$MAGICDNS_NAME" != "$TAILNET_DOMAIN" ]]; then
    warn "$MAGICDNS_NAME does not end with the requested tailnet domain $TAILNET_DOMAIN"
  fi

  direct_magicdns_ips="$(direct_magicdns_lookup "$MAGICDNS_NAME")"

  if [[ -n "$direct_magicdns_ips" ]]; then
    pass "Direct MagicDNS lookup resolved $MAGICDNS_NAME via $TAILSCALE_MAGICDNS_SERVER ($(join_lines "$direct_magicdns_ips"))"
  else
    fail "Direct MagicDNS lookup failed for $MAGICDNS_NAME"
    print_magicdns_followups "$MAGICDNS_NAME"
  fi

  hosts_override_ips="$(hosts_file_lookup "$MAGICDNS_NAME")"
  if [[ -n "$hosts_override_ips" ]]; then
    warn "$HOSTS_FILE contains a static override for $MAGICDNS_NAME ($(join_lines "$hosts_override_ips")); app-level access may work even if MagicDNS is misconfigured"
  fi

  if command -v "$DSCACHEUTIL_BIN" >/dev/null 2>&1; then
    system_resolver_ips="$(system_resolver_lookup "$MAGICDNS_NAME")"
    if [[ -n "$system_resolver_ips" ]]; then
      if [[ -n "$direct_magicdns_ips" ]] && list_has_common_line "$direct_magicdns_ips" "$system_resolver_ips"; then
        pass "macOS system resolver returned an expected Tailscale address for $MAGICDNS_NAME ($(join_lines "$system_resolver_ips"))"
      elif [[ -n "$direct_magicdns_ips" ]]; then
        fail "macOS system resolver returned $(join_lines "$system_resolver_ips") for $MAGICDNS_NAME, which does not match direct MagicDNS ($(join_lines "$direct_magicdns_ips"))"
        print_magicdns_followups "$MAGICDNS_NAME"
      else
        warn "macOS system resolver returned $(join_lines "$system_resolver_ips") for $MAGICDNS_NAME"
      fi
    elif [[ -n "$direct_magicdns_ips" ]]; then
      fail "macOS system resolver did not return an address for $MAGICDNS_NAME, even though direct MagicDNS resolved it"
      print_magicdns_followups "$MAGICDNS_NAME"
    else
      warn "macOS system resolver did not return an address for $MAGICDNS_NAME"
    fi
  else
    warn "dscacheutil not found; skipping macOS system resolver validation for $MAGICDNS_NAME"
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
echo "=== Results: ${PASS} passed, ${FAIL} failed, ${WARN} warnings ==="

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}Some checks failed. Review install.sh, verify.sh, or your local VPN state before proceeding.${NC}"
  exit 1
fi
