#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mullvad-tailscale-tests.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

PASS_COUNT=0
ANCHOR_COMMENT="# Tailscale anchor - allow tailnet traffic through Mullvad kill switch"

pass() {
  echo "[PASS] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "[FAIL] $1" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"

  grep -Fq -- "$pattern" "$file" || fail "Expected '$pattern' in $file"
}

assert_file_not_contains() {
  local file="$1"
  local pattern="$2"

  if grep -Fq -- "$pattern" "$file"; then
    fail "Did not expect '$pattern' in $file"
  fi
}

assert_count() {
  local file="$1"
  local pattern="$2"
  local expected="$3"
  local actual

  actual="$(grep -Fxc -- "$pattern" "$file" || true)"
  [[ "$actual" == "$expected" ]] || fail "Expected '$pattern' to appear $expected times in $file, got $actual"
}

assert_exit_code() {
  local expected="$1"
  local actual="$2"
  [[ "$expected" == "$actual" ]] || fail "Expected exit code $expected, got $actual"
}

setup_fake_commands() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"

  cat > "$bin_dir/pfctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_LOG_DIR/pfctl.calls"

if [[ "${1:-}" == "-a" && "${2:-}" == "tailscale" && "${3:-}" == "-sr" ]]; then
  if [[ -n "${PFCTL_ANCHOR_RULES+x}" ]] && ! grep -Eq '^-a tailscale -f ' "$TEST_LOG_DIR/pfctl.calls"; then
    printf '%s\n' "$PFCTL_ANCHOR_RULES"
  elif [[ -f "$ANCHOR_FILE" ]]; then
    # Match macOS PF's observed optimizer order: independent outbound rules are
    # printed before inbound rules, regardless of their template order.
    awk '
      NF && $1 != "#" {
        if ($2 == "out") outgoing[++out_count] = $0
        else if ($2 == "in") incoming[++in_count] = $0
      }
      END {
        for (i = 1; i <= out_count; i++) print outgoing[i]
        for (i = 1; i <= in_count; i++) print incoming[i]
      }
    ' "$ANCHOR_FILE"
  fi
  exit 0
fi

if [[ "${1:-}" == "-a" && "${2:-}" == "mullvad" && "${3:-}" == "-sr" ]]; then
  reload_count="$(grep -Ec '^-f ' "$TEST_LOG_DIR/pfctl.calls" || true)"
  if { [[ "${PFCTL_DROP_MULLVAD_AFTER_RELOAD:-0}" == "1" && "$reload_count" -ge 1 ]]; } || \
    { [[ "${PFCTL_DROP_MULLVAD_ON_FIRST_RELOAD:-0}" == "1" && "$reload_count" == "1" ]]; }; then
    exit 0
  fi
  printf '%s\n' "${PFCTL_MULLVAD_RULES-block drop all}"
  exit 0
fi

if [[ "${1:-}" == "-s" && "${2:-}" == "Anchors" ]]; then
  if [[ "${PFCTL_FAIL_INSPECTION:-0}" == "1" ]]; then
    exit 1
  fi
  reload_count="$(grep -Ec '^-f ' "$TEST_LOG_DIR/pfctl.calls" || true)"
  if { [[ "${PFCTL_DROP_MULLVAD_AFTER_RELOAD:-0}" == "1" && "$reload_count" -ge 1 ]]; } || \
    { [[ "${PFCTL_DROP_MULLVAD_ON_FIRST_RELOAD:-0}" == "1" && "$reload_count" == "1" ]]; }; then
    printf '%s\n' "tailscale"
  elif [[ -n "${PFCTL_ANCHORS+x}" ]]; then
    printf '%b\n' "$PFCTL_ANCHORS"
  else
    printf '%b\n' "tailscale\nmullvad"
  fi
  exit 0
fi

if [[ "${1:-}" == "-s" && "${2:-}" == "info" ]]; then
  printf '%s\n' "${PFCTL_INFO:-Status: Enabled for 0 days}"
  exit 0
fi

if [[ "${1:-}" == "-sr" ]]; then
  printf '%b\n' "${PFCTL_MAIN_RULES:-anchor \"tailscale\" all\nanchor \"mullvad\" all}"
  exit 0
fi

if [[ "${1:-}" == "-f" ]]; then
  cp "$2" "$TEST_LOG_DIR/last-reloaded.conf"
  if [[ "${PFCTL_FAIL_RELOAD:-0}" == "1" ]]; then
    exit 1
  fi
fi

if [[ "${PFCTL_FAIL_ANCHOR_LOAD:-0}" == "1" && "${1:-}" == "-a" && "${3:-}" == "-f" ]]; then
  exit 1
fi

exit 0
EOF

  cat > "$bin_dir/ifconfig" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "-l" ]]; then
  printf '%s\n' "${IFCONFIG_LIST:-lo0}"
  exit 0
fi

fixture="${IFCONFIG_FIXTURES_DIR}/${1:-missing}"
if [[ -f "$fixture" ]]; then
  cat "$fixture"
  exit 0
fi

exit 1
EOF

  cat > "$bin_dir/chown" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat > "$bin_dir/chmod" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_LOG_DIR/chmod.calls"
exit 0
EOF

  cat > "$bin_dir/plutil" <<'EOF'
#!/bin/bash
exit 0
EOF

  cat > "$bin_dir/stat" <<'EOF'
#!/bin/bash
printf '%s\n' "0 755"
exit 0
EOF

  cat > "$bin_dir/launchctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_LOG_DIR/launchctl.calls"

if [[ "${1:-}" == "print" ]]; then
  exit "${LAUNCHCTL_PRINT_EXIT:-1}"
fi

exit 0
EOF

  cat > "$bin_dir/pgrep" <<'EOF'
#!/bin/bash
case "$*" in
  *tailscaled*)
    exit "${PGREP_TAILSCALED_EXIT:-1}"
    ;;
  *mullvad-daemon*)
    exit "${PGREP_MULLVAD_EXIT:-1}"
    ;;
  *)
    exit 1
    ;;
esac
EOF

  cat > "$bin_dir/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "${CURL_OUTPUT:-}"
exit "${CURL_EXIT:-0}"
EOF

  cat > "$bin_dir/dig" <<'EOF'
#!/bin/bash
printf '%s\n' "${DIG_OUTPUT:-}"
exit 0
EOF

  cat > "$bin_dir/dscacheutil" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_LOG_DIR/dscacheutil.calls"
printf '%s\n' "${DSCACHEUTIL_OUTPUT:-}"
exit "${DSCACHEUTIL_EXIT:-0}"
EOF

  cat > "$bin_dir/scutil" <<'EOF'
#!/bin/bash
printf '%s\n' "${SCUTIL_OUTPUT:-}"
exit "${SCUTIL_EXIT:-0}"
EOF

  cat > "$bin_dir/killall" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_LOG_DIR/killall.calls"
exit "${KILLALL_EXIT:-0}"
EOF

  cat > "$bin_dir/tailscale" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "ip" && "${2:-}" == "-4" ]]; then
  printf '%s\n' "${TAILSCALE_IPV4:-100.82.1.2}"
  exit "${TAILSCALE_IP_EXIT:-0}"
fi

if [[ "${1:-}" == "ip" && "${2:-}" == "-6" ]]; then
  printf '%s\n' "${TAILSCALE_IPV6:-fd7a:115c:a1e0::5252:102}"
  exit "${TAILSCALE_IP_EXIT:-0}"
fi

if [[ "${1:-}" == "ping" ]]; then
  if [[ " $* " == *" --tsmp "* ]]; then
    printf '%s\n' "${TAILSCALE_TSMP_OUTPUT:-}"
    exit "${TAILSCALE_TSMP_EXIT:-0}"
  fi

  printf '%s\n' "${TAILSCALE_DISCO_OUTPUT:-}"
  exit "${TAILSCALE_DISCO_EXIT:-0}"
fi

exit 0
EOF

  cat > "$bin_dir/mullvad" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == "status" ]]; then
  printf '%s\n' "${MULLVAD_STATUS:-Connected to test relay}"
  exit "${MULLVAD_EXIT:-0}"
fi
if [[ "${1:-}" == "lockdown-mode" && "${2:-}" == "get" ]]; then
  printf '%s\n' "${MULLVAD_LOCKDOWN:-Block traffic when VPN is disconnected: on}"
  exit "${MULLVAD_EXIT:-0}"
fi
exit 1
EOF

  chmod +x "$bin_dir"/*
}

run_install_env() {
  local workspace="$1"
  shift

  local bin_dir="$workspace/bin"
  TEST_LOG_DIR="$workspace/logs" \
  IFCONFIG_FIXTURES_DIR="$workspace/ifconfig" \
  SKIP_ROOT_CHECK=1 \
  PF_CONF="$workspace/pf.conf" \
  ANCHOR_FILE="$workspace/pf.anchors/tailscale" \
  PFCTL_BIN="$bin_dir/pfctl" \
  IFCONFIG_BIN="$bin_dir/ifconfig" \
  TAILSCALE_BIN="$bin_dir/tailscale" \
  MULLVAD_BIN="$bin_dir/mullvad" \
  CHOWN_BIN="$bin_dir/chown" \
  CHMOD_BIN="$bin_dir/chmod" \
  bash "$ROOT_DIR/install.sh" "$@"
}

run_uninstall_env() {
  local workspace="$1"
  shift

  local bin_dir="$workspace/bin"
  TEST_LOG_DIR="$workspace/logs" \
  SKIP_ROOT_CHECK=1 \
  PF_CONF="$workspace/pf.conf" \
  ANCHOR_FILE="$workspace/pf.anchors/tailscale" \
  PFCTL_BIN="$bin_dir/pfctl" \
  MULLVAD_BIN="$bin_dir/mullvad" \
  bash "$ROOT_DIR/uninstall.sh" "$@"
}

run_verify_env() {
  local workspace="$1"
  shift

  local bin_dir="$workspace/bin"
  TEST_LOG_DIR="$workspace/logs" \
  IFCONFIG_FIXTURES_DIR="$workspace/ifconfig" \
  SKIP_ROOT_CHECK=1 \
  PF_CONF="$workspace/pf.conf" \
  ANCHOR_FILE="$workspace/pf.anchors/tailscale" \
  RESOLVER_DIR="$workspace/resolver" \
  PFCTL_BIN="$bin_dir/pfctl" \
  IFCONFIG_BIN="$bin_dir/ifconfig" \
  MULLVAD_BIN="$bin_dir/mullvad" \
  PGREP_BIN="$bin_dir/pgrep" \
  CURL_BIN="$bin_dir/curl" \
  DIG_BIN="$bin_dir/dig" \
  DSCACHEUTIL_BIN="$bin_dir/dscacheutil" \
  SCUTIL_BIN="$bin_dir/scutil" \
  KILLALL_BIN="$bin_dir/killall" \
  HOSTS_FILE="$workspace/hosts" \
  TAILSCALE_BIN="$bin_dir/tailscale" \
  STAT_BIN="$bin_dir/stat" \
  TAILSCALED_DAEMON_PLIST="$workspace/com.tailscale.tailscaled.plist" \
  TAILSCALED_MANAGED_BIN="$workspace/managed-tailscaled" \
  PF_WATCHER_INSTALL_DIR="$workspace/watcher" \
  PF_WATCHER_PLIST="$workspace/com.mullvad-tailscale-macos.pf-watcher.plist" \
  bash "$ROOT_DIR/verify.sh" "$@"
}

run_daemon_install_env() {
  local workspace="$1"
  shift

  local bin_dir="$workspace/bin"
  TEST_LOG_DIR="$workspace/logs" \
  SKIP_ROOT_CHECK=1 \
  TAILSCALED_BIN="$workspace/source-tailscaled" \
  TAILSCALED_MANAGED_BIN="$workspace/managed-tailscaled" \
  TAILSCALED_DAEMON_PLIST="$workspace/com.tailscale.tailscaled.plist" \
  PLUTIL_BIN="$bin_dir/plutil" \
  LAUNCHCTL_BIN="$bin_dir/launchctl" \
  CHOWN_BIN="$bin_dir/chown" \
  CHMOD_BIN="$bin_dir/chmod" \
  bash "$ROOT_DIR/install-tailscaled-daemon.sh" "$@"
}

run_daemon_uninstall_env() {
  local workspace="$1"
  shift

  local bin_dir="$workspace/bin"
  TEST_LOG_DIR="$workspace/logs" \
  SKIP_ROOT_CHECK=1 \
  TAILSCALED_DAEMON_PLIST="$workspace/com.tailscale.tailscaled.plist" \
  TAILSCALED_MANAGED_BIN="$workspace/managed-tailscaled" \
  LAUNCHCTL_BIN="$bin_dir/launchctl" \
  bash "$ROOT_DIR/uninstall-tailscaled-daemon.sh" "$@"
}

run_resolver_install_env() {
  local workspace="$1"
  shift

  local bin_dir="$workspace/bin"
  TEST_LOG_DIR="$workspace/logs" \
  SKIP_ROOT_CHECK=1 \
  RESOLVER_DIR="$workspace/resolver" \
  DSCACHEUTIL_BIN="$bin_dir/dscacheutil" \
  KILLALL_BIN="$bin_dir/killall" \
  CHOWN_BIN="$bin_dir/chown" \
  CHMOD_BIN="$bin_dir/chmod" \
  CP_BIN="cp" \
  bash "$ROOT_DIR/install-tailnet-resolver.sh" "$@"
}

run_resolver_uninstall_env() {
  local workspace="$1"
  shift

  local bin_dir="$workspace/bin"
  TEST_LOG_DIR="$workspace/logs" \
  SKIP_ROOT_CHECK=1 \
  RESOLVER_DIR="$workspace/resolver" \
  DSCACHEUTIL_BIN="$bin_dir/dscacheutil" \
  KILLALL_BIN="$bin_dir/killall" \
  CP_BIN="cp" \
  bash "$ROOT_DIR/uninstall-tailnet-resolver.sh" "$@"
}

run_pf_watcher_install_env() {
  local workspace="$1"
  shift

  local bin_dir="$workspace/bin"
  TEST_LOG_DIR="$workspace/logs" \
  SKIP_ROOT_CHECK=1 \
  PF_WATCHER_INSTALL_DIR="$workspace/watcher" \
  PF_WATCHER_PLIST="$workspace/com.mullvad-tailscale-macos.pf-watcher.plist" \
  PF_WATCHER_LOG="/dev/null" \
  PLUTIL_BIN="$bin_dir/plutil" \
  LAUNCHCTL_BIN="$bin_dir/launchctl" \
  CHOWN_BIN="$bin_dir/chown" \
  CHMOD_BIN="$bin_dir/chmod" \
  CP_BIN="cp" \
  bash "$ROOT_DIR/install-pf-watcher.sh" "$@"
}

run_pf_watcher_uninstall_env() {
  local workspace="$1"
  shift

  local bin_dir="$workspace/bin"
  TEST_LOG_DIR="$workspace/logs" \
  SKIP_ROOT_CHECK=1 \
  PF_WATCHER_INSTALL_DIR="$workspace/watcher" \
  PF_WATCHER_PLIST="$workspace/com.mullvad-tailscale-macos.pf-watcher.plist" \
  LAUNCHCTL_BIN="$bin_dir/launchctl" \
  RM_BIN="rm" \
  bash "$ROOT_DIR/uninstall-pf-watcher.sh" "$@"
}

run_refresh_env() {
  local workspace="$1"
  shift

  local bin_dir="$workspace/bin"
  TEST_LOG_DIR="$workspace/logs" \
  IFCONFIG_FIXTURES_DIR="$workspace/ifconfig" \
  SKIP_ROOT_CHECK=1 \
  ANCHOR_FILE="$workspace/pf.anchors/tailscale" \
  PFCTL_BIN="$bin_dir/pfctl" \
  IFCONFIG_BIN="$bin_dir/ifconfig" \
  TAILSCALE_BIN="$bin_dir/tailscale" \
  MULLVAD_BIN="$bin_dir/mullvad" \
  CHOWN_BIN="$bin_dir/chown" \
  CHMOD_BIN="$bin_dir/chmod" \
  CP_BIN="cp" \
  bash "$ROOT_DIR/refresh-anchor.sh" "$@"
}

new_workspace() {
  local name="$1"
  local workspace="$TEST_TMP/$name"

  mkdir -p "$workspace/bin" "$workspace/ifconfig" "$workspace/logs" "$workspace/pf.anchors"
  : > "$workspace/logs/pfctl.calls"
  : > "$workspace/logs/launchctl.calls"
  : > "$workspace/logs/dscacheutil.calls"
  : > "$workspace/logs/killall.calls"
  : > "$workspace/hosts"
  printf '#!/bin/bash\nexit 0\n' > "$workspace/source-tailscaled"
  chmod +x "$workspace/source-tailscaled"
  mkdir -p "$workspace/resolver"
  setup_fake_commands "$workspace/bin"
  echo "$workspace"
}

test_install_detects_interface_and_writes_anchor() {
  local workspace
  workspace="$(new_workspace install-detect)"

  cat > "$workspace/pf.conf" <<'EOF'
set skip on lo0
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  IFCONFIG_LIST="lo0 utun7" run_install_env "$workspace"

  assert_file_contains "$workspace/pf.anchors/tailscale" "pass out quick on utun7 inet from any to 100.64.0.0/10 no state"
  assert_file_contains "$workspace/pf.conf" 'anchor "tailscale"'
  assert_file_contains "$workspace/pf.conf" "load anchor \"tailscale\" from \"$workspace/pf.anchors/tailscale\""
  pass "install detects the active Tailscale interface"
}

test_install_repairs_partial_anchor_block() {
  local workspace
  workspace="$(new_workspace install-repair)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  run_install_env "$workspace" --interface utun9

  assert_count "$workspace/pf.conf" 'anchor "tailscale"' 1
  assert_count "$workspace/pf.conf" "load anchor \"tailscale\" from \"$workspace/pf.anchors/tailscale\"" 1
  assert_file_contains "$workspace/pf.anchors/tailscale" "pass out quick on utun9 inet from any to 100.64.0.0/10 no state"
  pass "install repairs a partial pf.conf block without duplicating lines"
}

test_install_repairs_missing_anchor_and_accepts_pf_optimizer_order() {
  local workspace
  local output
  workspace="$(new_workspace install-repair-missing-anchor)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
$ANCHOR_COMMENT
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  output="$(IFCONFIG_LIST="lo0 utun7" run_install_env "$workspace")"

  grep -Fq "Repairing missing $workspace/pf.anchors/tailscale" <<<"$output" || \
    fail "Expected install to report repair of the missing managed anchor"
  [[ -f "$workspace/pf.anchors/tailscale" ]] || fail "Expected install to recreate the missing anchor file"
  assert_file_contains "$workspace/pf.anchors/tailscale" "pass out quick on utun7 inet from any to 100.64.0.0/10 no state"
  pass "install accepts PF optimizer rule order and repairs a missing managed anchor"
}

test_install_rolls_back_failed_pf_reload() {
  local workspace
  workspace="$(new_workspace install-rollback)"

  cat > "$workspace/pf.conf" <<'EOF'
set skip on lo0
EOF

  PFCTL_FAIL_RELOAD=1 run_install_env "$workspace" --interface utun4 >/dev/null 2>&1 && fail "install should have failed when pfctl reload fails"

  assert_count "$workspace/pf.conf" 'set skip on lo0' 1
  assert_file_not_contains "$workspace/pf.conf" 'anchor "tailscale"'
  pass "install restores the original pf.conf when reload fails"
}

test_uninstall_removes_anchor_block_and_file() {
  local workspace
  workspace="$(new_workspace uninstall)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
$ANCHOR_COMMENT
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun5 inet from any to 100.64.0.0/10 no state
pass in quick on utun5 inet from 100.64.0.0/10 to any no state
pass out quick on utun5 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun5 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  run_uninstall_env "$workspace"

  assert_file_not_contains "$workspace/pf.conf" 'anchor "tailscale"'
  [[ ! -f "$workspace/pf.anchors/tailscale" ]] || fail "Expected anchor file to be removed"
  pass "uninstall removes the managed anchor block and anchor file"
}

test_verify_rejects_partial_pf_conf() {
  local workspace
  workspace="$(new_workspace verify-partial)"

  cat > "$workspace/pf.conf" <<EOF
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  IFCONFIG_LIST="lo0 utun7" run_verify_env "$workspace" >/dev/null 2>&1 && fail "verify should fail when the anchor line is missing"
  pass "verify is not fooled by a load-only pf.conf"
}

test_verify_supports_active_checks() {
  local workspace
  workspace="$(new_workspace verify-active)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  touch "$workspace/com.tailscale.tailscaled.plist"
  cat > "$workspace/resolver/bear-skate.ts.net" <<'EOF'
# Managed by install-tailnet-resolver.sh
# Routes bear-skate.ts.net lookups to Tailscale MagicDNS.
nameserver 100.100.100.100
EOF

  IFCONFIG_LIST="lo0 utun7" \
  PGREP_TAILSCALED_EXIT=0 \
  PGREP_MULLVAD_EXIT=0 \
  CURL_OUTPUT="You are connected to Mullvad" \
  DIG_OUTPUT="100.110.111.112" \
  DSCACHEUTIL_OUTPUT="name: peer.bear-skate.ts.net
ip_address: 100.110.111.112" \
  TAILSCALE_TSMP_EXIT=0 \
  TAILSCALE_DISCO_EXIT=0 \
  run_verify_env "$workspace" --tailnet-target peer --tailnet-domain bear-skate.ts.net --magicdns-name peer.bear-skate.ts.net

  pass "verify supports active tailnet, resolver override, MagicDNS, and Mullvad checks"
}

test_verify_accepts_derp_fallback_as_reachable() {
  local workspace
  workspace="$(new_workspace verify-derp)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  touch "$workspace/com.tailscale.tailscaled.plist"
  cat > "$workspace/resolver/bear-skate.ts.net" <<'EOF'
# Managed by install-tailnet-resolver.sh
# Routes bear-skate.ts.net lookups to Tailscale MagicDNS.
nameserver 100.100.100.100
EOF

  IFCONFIG_LIST="lo0 utun7" \
  PGREP_TAILSCALED_EXIT=0 \
  PGREP_MULLVAD_EXIT=0 \
  CURL_OUTPUT="You are connected to Mullvad" \
  DIG_OUTPUT="100.110.111.112" \
  DSCACHEUTIL_OUTPUT="name: peer.bear-skate.ts.net
ip_address: 100.110.111.112" \
  TAILSCALE_TSMP_EXIT=0 \
  TAILSCALE_DISCO_EXIT=1 \
  TAILSCALE_DISCO_OUTPUT="pong from peer (100.110.111.112) via DERP(fra) in 40ms
direct connection not established" \
  run_verify_env "$workspace" --tailnet-target peer --tailnet-domain bear-skate.ts.net --magicdns-name peer.bear-skate.ts.net

  pass "verify treats DERP fallback as reachable and reports direct-path failure as a warning"
}

test_verify_rejects_system_resolver_mismatch() {
  local workspace
  workspace="$(new_workspace verify-dns-mismatch)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  touch "$workspace/com.tailscale.tailscaled.plist"

  IFCONFIG_LIST="lo0 utun7" \
  PGREP_TAILSCALED_EXIT=0 \
  PGREP_MULLVAD_EXIT=0 \
  CURL_OUTPUT="You are connected to Mullvad" \
  DIG_OUTPUT="100.110.111.112" \
  DSCACHEUTIL_OUTPUT="name: peer.ts.net
ip_address: 100.120.121.122" \
  TAILSCALE_TSMP_EXIT=0 \
  TAILSCALE_DISCO_EXIT=0 \
  run_verify_env "$workspace" --tailnet-target peer --magicdns-name peer.ts.net >/dev/null 2>&1 && fail "verify should fail when the macOS resolver disagrees with direct MagicDNS"

  pass "verify rejects mismatched macOS hostname resolution"
}

test_verify_rejects_missing_system_resolution() {
  local workspace
  workspace="$(new_workspace verify-dns-missing)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  touch "$workspace/com.tailscale.tailscaled.plist"

  IFCONFIG_LIST="lo0 utun7" \
  PGREP_TAILSCALED_EXIT=0 \
  PGREP_MULLVAD_EXIT=0 \
  CURL_OUTPUT="You are connected to Mullvad" \
  DIG_OUTPUT="100.110.111.112" \
  DSCACHEUTIL_OUTPUT="" \
  TAILSCALE_TSMP_EXIT=0 \
  TAILSCALE_DISCO_EXIT=0 \
  run_verify_env "$workspace" --tailnet-target peer --magicdns-name peer.ts.net >/dev/null 2>&1 && fail "verify should fail when direct MagicDNS works but the macOS resolver returns nothing"

  pass "verify rejects missing macOS hostname resolution when MagicDNS resolves directly"
}

test_verify_warns_on_hosts_override() {
  local workspace
  workspace="$(new_workspace verify-hosts-override)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  cat > "$workspace/hosts" <<'EOF'
100.110.111.112 peer.ts.net
EOF

  touch "$workspace/com.tailscale.tailscaled.plist"

  output="$(
    IFCONFIG_LIST="lo0 utun7" \
    PGREP_TAILSCALED_EXIT=0 \
    PGREP_MULLVAD_EXIT=0 \
    CURL_OUTPUT="You are connected to Mullvad" \
    DIG_OUTPUT="100.110.111.112" \
    DSCACHEUTIL_OUTPUT="name: peer.ts.net
ip_address: 100.110.111.112" \
    TAILSCALE_TSMP_EXIT=0 \
    TAILSCALE_DISCO_EXIT=0 \
    run_verify_env "$workspace" --tailnet-target peer --magicdns-name peer.ts.net
  )"

  grep -Fq "[WARN]" <<<"$output" || fail "Expected a warning when the hostname is statically overridden in hosts"
  grep -Fq "static override for peer.ts.net" <<<"$output" || fail "Expected hosts override warning output"
  pass "verify warns when /etc/hosts masks MagicDNS"
}

test_verify_accepts_externally_managed_tailscaled() {
  local workspace
  workspace="$(new_workspace verify-external-tailscaled)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  output="$(
    IFCONFIG_LIST="lo0 utun7" \
    PGREP_TAILSCALED_EXIT=0 \
    PGREP_MULLVAD_EXIT=0 \
    CURL_OUTPUT="You are connected to Mullvad" \
    run_verify_env "$workspace"
  )"

  grep -Fq "tailscaled appears to be managed elsewhere" <<<"$output" || fail "Expected verify to accept externally managed tailscaled"
  assert_file_not_contains <(printf '%s' "$output") "Managed tailscaled LaunchDaemon plist not found"
  pass "verify accepts tailscaled managed outside the repo"
}

test_verify_followups_only_suggest_resolver_for_tailnet_domains() {
  local workspace
  workspace="$(new_workspace verify-followups-domain)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  touch "$workspace/com.tailscale.tailscaled.plist"

  output="$(
    IFCONFIG_LIST="lo0 utun7" \
    PGREP_TAILSCALED_EXIT=0 \
    PGREP_MULLVAD_EXIT=0 \
    CURL_OUTPUT="You are connected to Mullvad" \
    DIG_OUTPUT="" \
    DSCACHEUTIL_OUTPUT="" \
    run_verify_env "$workspace" --magicdns-name peer.example.com || true
  )"

  grep -Fq "Follow up: scutil --dns" <<<"$output" || fail "Expected standard MagicDNS follow-up hints"
  if grep -Fq "install-tailnet-resolver.sh" <<<"$output"; then
    fail "Did not expect resolver installer hint for a non-tailnet domain"
  fi
  pass "verify only suggests the resolver helper for tailnet domains"
}

test_verify_warns_when_tailnet_resolver_override_is_missing() {
  local workspace
  workspace="$(new_workspace verify-missing-resolver)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  touch "$workspace/com.tailscale.tailscaled.plist"

  output="$(
    IFCONFIG_LIST="lo0 utun7" \
    PGREP_TAILSCALED_EXIT=0 \
    PGREP_MULLVAD_EXIT=0 \
    run_verify_env "$workspace" --tailnet-domain bear-skate.ts.net
  )"

  grep -Fq "No repo-managed resolver override file found for bear-skate.ts.net" <<<"$output" || fail "Expected a warning when the requested resolver override is missing"
  pass "verify warns when an optional requested tailnet resolver override is missing"
}

test_verify_warns_on_mullvad_content_blocker_dns() {
  local workspace
  workspace="$(new_workspace verify-blocker-dns)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  touch "$workspace/com.tailscale.tailscaled.plist"

  output="$(
    IFCONFIG_LIST="lo0 utun7" \
    PGREP_TAILSCALED_EXIT=0 \
    PGREP_MULLVAD_EXIT=0 \
    CURL_OUTPUT="You are connected to Mullvad" \
    SCUTIL_OUTPUT="  nameserver[0] : 100.64.0.3" \
    run_verify_env "$workspace"
  )"

  grep -Fq "content-blocker address (100.64.0.3)" <<<"$output" || fail "Expected a Mullvad content-blocker DNS warning naming 100.64.0.3"
  pass "verify warns when system DNS is a Mullvad content-blocker address in Tailscale's range"
}

test_verify_ignores_non_blocker_dns() {
  local workspace
  workspace="$(new_workspace verify-default-dns)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  touch "$workspace/com.tailscale.tailscaled.plist"

  output="$(
    IFCONFIG_LIST="lo0 utun7" \
    PGREP_TAILSCALED_EXIT=0 \
    PGREP_MULLVAD_EXIT=0 \
    CURL_OUTPUT="You are connected to Mullvad" \
    SCUTIL_OUTPUT="  nameserver[0] : 10.64.0.1" \
    run_verify_env "$workspace"
  )"

  grep -Fq "No Mullvad content-blocker DNS collision detected" <<<"$output" || fail "Expected the no-collision pass for Mullvad default DNS"
  if grep -Fq "content-blocker address" <<<"$output"; then
    fail "Did not expect a content-blocker warning for Mullvad default DNS 10.64.0.1"
  fi
  pass "verify does not warn for Mullvad default DNS (10.64.0.1)"
}

test_blocker_dns_classifier_boundaries() {
  local out
  if ! out="$(
    ROOT_DIR="$ROOT_DIR" bash -c '
      source "$ROOT_DIR/lib/common.sh"
      rc=0
      for ip in 100.64.0.1 100.64.0.3 100.64.0.7 100.64.0.10 100.64.0.63; do
        dns_server_is_mullvad_blocker "$ip" || { echo "should-accept $ip"; rc=1; }
      done
      for ip in 100.64.0.0 100.64.0.64 100.64.0.255 10.64.0.1 100.100.100.100 192.168.0.1; do
        dns_server_is_mullvad_blocker "$ip" && { echo "should-reject $ip"; rc=1; }
      done
      exit $rc
    ' 2>&1
  )"; then
    fail "Blocker DNS classifier misclassified: $out"
  fi
  pass "Mullvad content-blocker DNS classifier accepts 100.64.0.1-63 and rejects everything else"
}

test_resolver_installer_writes_file_and_flushes_dns() {
  local workspace
  workspace="$(new_workspace resolver-install)"

  run_resolver_install_env "$workspace" --tailnet-domain bear-skate.ts.net

  assert_file_contains "$workspace/resolver/bear-skate.ts.net" "# Managed by install-tailnet-resolver.sh"
  assert_file_contains "$workspace/resolver/bear-skate.ts.net" "nameserver 100.100.100.100"
  assert_file_contains "$workspace/logs/dscacheutil.calls" "-flushcache"
  assert_file_contains "$workspace/logs/killall.calls" "-HUP mDNSResponder"
  pass "resolver installer writes a domain-scoped MagicDNS override and flushes DNS"
}

test_resolver_installer_refuses_unmanaged_existing_file() {
  local workspace
  workspace="$(new_workspace resolver-install-unmanaged)"

  cat > "$workspace/resolver/bear-skate.ts.net" <<'EOF'
nameserver 9.9.9.9
EOF

  run_resolver_install_env "$workspace" --tailnet-domain bear-skate.ts.net >/dev/null 2>&1 && fail "resolver installer should refuse to overwrite an unmanaged existing file"

  pass "resolver installer refuses to overwrite an unmanaged resolver file"
}

test_resolver_installer_propagates_flush_failures() {
  local workspace
  workspace="$(new_workspace resolver-install-flush-fail)"

  DSCACHEUTIL_EXIT=1 run_resolver_install_env "$workspace" --tailnet-domain bear-skate.ts.net >/dev/null 2>&1 && fail "resolver installer should fail when DNS cache flush fails"
  pass "resolver installer fails if DNS cache flush fails"
}

test_resolver_uninstaller_removes_file_and_flushes_dns() {
  local workspace
  workspace="$(new_workspace resolver-uninstall)"

  cat > "$workspace/resolver/bear-skate.ts.net" <<'EOF'
# Managed by install-tailnet-resolver.sh
# Routes bear-skate.ts.net lookups to Tailscale MagicDNS.
nameserver 100.100.100.100
EOF

  run_resolver_uninstall_env "$workspace" --tailnet-domain bear-skate.ts.net

  [[ ! -f "$workspace/resolver/bear-skate.ts.net" ]] || fail "Expected resolver override to be removed"
  assert_file_contains "$workspace/logs/dscacheutil.calls" "-flushcache"
  assert_file_contains "$workspace/logs/killall.calls" "-HUP mDNSResponder"
  pass "resolver uninstaller removes the override and flushes DNS"
}

test_resolver_uninstaller_refuses_unmanaged_existing_file() {
  local workspace
  workspace="$(new_workspace resolver-uninstall-unmanaged)"

  cat > "$workspace/resolver/bear-skate.ts.net" <<'EOF'
nameserver 9.9.9.9
EOF

  run_resolver_uninstall_env "$workspace" --tailnet-domain bear-skate.ts.net >/dev/null 2>&1 && fail "resolver uninstaller should refuse to remove an unmanaged file"

  pass "resolver uninstaller refuses to remove an unmanaged resolver file"
}

test_daemon_installer_bootstraps_launchdaemon() {
  local workspace
  workspace="$(new_workspace daemon-install)"

  run_daemon_install_env "$workspace"

  assert_file_contains "$workspace/com.tailscale.tailscaled.plist" "<!-- Managed by mullvad-tailscale-macos -->"
  assert_file_contains "$workspace/com.tailscale.tailscaled.plist" "$workspace/managed-tailscaled"
  assert_count "$workspace/com.tailscale.tailscaled.plist" "    <string>/dev/null</string>" 2
  [[ -x "$workspace/managed-tailscaled" ]] || fail "Expected a protected managed tailscaled copy"
  assert_file_contains "$workspace/logs/chmod.calls" "755 $workspace/managed-tailscaled"
  assert_file_contains "$workspace/logs/launchctl.calls" "bootstrap system $workspace/com.tailscale.tailscaled.plist"
  assert_file_contains "$workspace/logs/launchctl.calls" "kickstart -k system/com.tailscale.tailscaled"
  pass "daemon installer copies a protected binary, suppresses persistent logs, marks the plist, and bootstraps it"
}

test_daemon_uninstaller_boots_out_and_removes_plist() {
  local workspace
  workspace="$(new_workspace daemon-uninstall)"

  run_daemon_install_env "$workspace" >/dev/null
  LAUNCHCTL_PRINT_EXIT=0 run_daemon_uninstall_env "$workspace"

  assert_file_contains "$workspace/logs/launchctl.calls" "print system/com.tailscale.tailscaled"
  assert_file_contains "$workspace/logs/launchctl.calls" "bootout system/com.tailscale.tailscaled"
  [[ ! -f "$workspace/com.tailscale.tailscaled.plist" ]] || fail "Expected LaunchDaemon plist to be removed"
  [[ ! -f "$workspace/managed-tailscaled" ]] || fail "Expected managed tailscaled binary to be removed"
  pass "daemon uninstaller unloads and removes only marked daemon artifacts"
}

test_pf_watcher_installer_installs_payload_and_bootstraps() {
  local workspace
  workspace="$(new_workspace pf-watcher-install)"

  run_pf_watcher_install_env "$workspace"

  assert_file_contains "$workspace/watcher/refresh-anchor.sh" "Reattached the PF anchor"
  [[ -f "$workspace/watcher/lib/common.sh" ]] || fail "Expected lib/common.sh in the watcher payload"
  assert_file_contains "$workspace/watcher/etc/pf.anchors/tailscale" "__TAILSCALE_INTERFACE__"
  assert_file_contains "$workspace/watcher/.managed-by-mullvad-tailscale-macos" "Managed by mullvad-tailscale-macos pf-watcher"
  assert_file_contains "$workspace/com.mullvad-tailscale-macos.pf-watcher.plist" "com.mullvad-tailscale-macos.pf-watcher"
  assert_file_contains "$workspace/com.mullvad-tailscale-macos.pf-watcher.plist" "<!-- Managed by mullvad-tailscale-macos -->"
  assert_count "$workspace/com.mullvad-tailscale-macos.pf-watcher.plist" "    <string>/dev/null</string>" 2
  assert_file_contains "$workspace/com.mullvad-tailscale-macos.pf-watcher.plist" "$workspace/watcher/refresh-anchor.sh"
  assert_file_contains "$workspace/com.mullvad-tailscale-macos.pf-watcher.plist" "/var/run/resolv.conf"
  grep -Fxq "755 $workspace/watcher" "$workspace/logs/chmod.calls" || fail "Expected the payload dir itself to be chmod 755 (root runs scripts from it on a timer)"
  assert_file_contains "$workspace/logs/launchctl.calls" "bootstrap system $workspace/com.mullvad-tailscale-macos.pf-watcher.plist"
  assert_file_contains "$workspace/logs/launchctl.calls" "kickstart -k system/com.mullvad-tailscale-macos.pf-watcher"
  pass "pf-watcher installer installs the payload, writes the plist, and bootstraps it"
}

test_pf_watcher_uninstaller_boots_out_and_removes() {
  local workspace
  workspace="$(new_workspace pf-watcher-uninstall)"

  run_pf_watcher_install_env "$workspace" >/dev/null

  LAUNCHCTL_PRINT_EXIT=0 run_pf_watcher_uninstall_env "$workspace"

  assert_file_contains "$workspace/logs/launchctl.calls" "bootout system/com.mullvad-tailscale-macos.pf-watcher"
  [[ ! -f "$workspace/com.mullvad-tailscale-macos.pf-watcher.plist" ]] || fail "Expected the pf-watcher plist to be removed"
  [[ ! -d "$workspace/watcher" ]] || fail "Expected the watcher payload directory to be removed"
  pass "pf-watcher uninstaller unloads, removes the plist, and removes the payload"
}

test_refresh_reattaches_anchor_on_interface_change() {
  local workspace
  workspace="$(new_workspace refresh-change)"

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun5 inet from any to 100.64.0.0/10 no state
pass in quick on utun5 inet from 100.64.0.0/10 to any no state
pass out quick on utun5 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun5 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun9" <<'EOF'
utun9: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  IFCONFIG_LIST="lo0 utun9" \
  PFCTL_ANCHOR_RULES="pass out quick on utun5 inet from any to 100.64.0.0/10 no state" \
  run_refresh_env "$workspace"

  assert_file_contains "$workspace/pf.anchors/tailscale" "pass out quick on utun9 inet from any to 100.64.0.0/10 no state"
  assert_file_not_contains "$workspace/pf.anchors/tailscale" "on utun5 "
  assert_file_contains "$workspace/logs/pfctl.calls" "-a tailscale -f $workspace/pf.anchors/tailscale"
  pass "refresh reattaches the anchor when Tailscale's interface changes"
}

test_refresh_noop_when_interface_unchanged() {
  local workspace
  workspace="$(new_workspace refresh-noop)"

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  output="$(
    IFCONFIG_LIST="lo0 utun7" \
    PFCTL_ANCHOR_RULES="pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state" \
    run_refresh_env "$workspace"
  )"

  [[ -z "$output" ]] || fail "Expected refresh to stay quiet on a no-op poll (non-interactive), got: $output"
  assert_file_not_contains "$workspace/logs/pfctl.calls" "-f $workspace/pf.anchors/tailscale"
  pass "refresh is a quiet no-op when the anchor already targets the active interface"
}

test_refresh_reattaches_when_runtime_anchor_empty() {
  local workspace
  workspace="$(new_workspace refresh-runtime-empty)"

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  # Interface still matches the anchor file, but the runtime anchor is empty
  # (the post-reboot / post-`pfctl -f` case). Refresh must reattach, not no-op.
  output="$(
    IFCONFIG_LIST="lo0 utun7" \
    PFCTL_ANCHOR_RULES="" \
    run_refresh_env "$workspace"
  )"

  grep -Fq "Reattached the PF anchor to utun7" <<<"$output" || fail "Expected refresh to reattach when the runtime anchor is empty"
  assert_file_contains "$workspace/logs/pfctl.calls" "-a tailscale -f $workspace/pf.anchors/tailscale"
  pass "refresh reattaches when the interface matches but the runtime anchor is empty"
}

test_refresh_fails_when_runtime_reload_fails() {
  local workspace
  workspace="$(new_workspace refresh-load-fail)"

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun5 inet from any to 100.64.0.0/10 no state
pass in quick on utun5 inet from 100.64.0.0/10 to any no state
pass out quick on utun5 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun5 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  cat > "$workspace/ifconfig/utun9" <<'EOF'
utun9: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  IFCONFIG_LIST="lo0 utun9" \
  PFCTL_FAIL_ANCHOR_LOAD=1 \
  run_refresh_env "$workspace" >/dev/null 2>&1 && fail "refresh should fail when reloading the runtime anchor fails"

  pass "refresh fails loudly when reloading the runtime anchor fails"
}

test_install_preserves_live_mullvad_anchor_during_reload() {
  local workspace
  workspace="$(new_workspace install-preserve-mullvad)"

  cat > "$workspace/pf.conf" <<'EOF'
set skip on lo0
EOF
  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  IFCONFIG_LIST="lo0 utun7" run_install_env "$workspace" >/dev/null

  assert_file_contains "$workspace/logs/last-reloaded.conf" 'anchor "tailscale"'
  assert_file_contains "$workspace/logs/last-reloaded.conf" 'anchor "mullvad"'
  assert_file_not_contains "$workspace/pf.conf" 'anchor "mullvad"'
  pass "full PF reload preserves Mullvad through a runtime-only anchor attachment"
}

test_install_rolls_back_if_mullvad_changes_after_reload() {
  local workspace
  local reload_count
  workspace="$(new_workspace install-mullvad-postcheck)"

  cat > "$workspace/pf.conf" <<'EOF'
set skip on lo0
EOF

  PFCTL_DROP_MULLVAD_ON_FIRST_RELOAD=1 run_install_env "$workspace" --interface utun7 >/dev/null 2>&1 && \
    fail "install should fail when Mullvad disappears during the PF transaction"

  assert_file_contains "$workspace/pf.conf" "set skip on lo0"
  assert_file_not_contains "$workspace/pf.conf" 'anchor "tailscale"'
  [[ ! -f "$workspace/pf.anchors/tailscale" ]] || fail "Expected failed install to remove its newly created anchor"
  reload_count="$(grep -Ec '^-f ' "$workspace/logs/pfctl.calls" || true)"
  [[ "$reload_count" == "2" ]] || fail "Expected one attempted update and one rollback reload, got $reload_count"
  assert_file_contains "$workspace/logs/last-reloaded.conf" 'anchor "mullvad"'
  pass "install restores disk and runtime PF state when the Mullvad post-check fails"
}

test_install_refuses_when_mullvad_expected_without_anchor() {
  local workspace
  workspace="$(new_workspace install-mullvad-missing)"

  cat > "$workspace/pf.conf" <<'EOF'
set skip on lo0
EOF

  PFCTL_ANCHORS="" run_install_env "$workspace" --interface utun7 >/dev/null 2>&1 && \
    fail "install should refuse a reload when Mullvad reports protection but has no PF anchor"

  assert_file_not_contains "$workspace/pf.conf" 'anchor "tailscale"'
  [[ ! -f "$workspace/pf.anchors/tailscale" ]] || fail "Expected refused install to restore the anchor path"
  pass "install refuses to reload an already inconsistent Mullvad protection state"
}

test_uninstall_refuses_when_expected_mullvad_anchor_is_empty() {
  local workspace
  workspace="$(new_workspace uninstall-mullvad-empty)"

  cat > "$workspace/pf.conf" <<EOF
set skip on lo0
$ANCHOR_COMMENT
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF

  PFCTL_MULLVAD_RULES="" run_uninstall_env "$workspace" >/dev/null 2>&1 && \
    fail "uninstall should refuse a full reload when active Mullvad protection has an empty anchor"

  assert_file_contains "$workspace/pf.conf" 'anchor "tailscale"'
  [[ -f "$workspace/pf.anchors/tailscale" ]] || fail "Expected refused uninstall to preserve the anchor file"
  pass "shared PF updates refuse an empty Mullvad anchor while protection is expected"
}

test_install_refuses_unknown_dynamic_anchor() {
  local workspace
  workspace="$(new_workspace install-unknown-anchor)"

  cat > "$workspace/pf.conf" <<'EOF'
set skip on lo0
EOF

  PFCTL_ANCHORS="tailscale
mullvad
other-vpn" run_install_env "$workspace" --interface utun7 >/dev/null 2>&1 && \
    fail "install should refuse to flush an unknown dynamic anchor"

  assert_file_not_contains "$workspace/pf.conf" 'anchor "tailscale"'
  pass "install refuses to flush unknown dynamic PF attachments"
}

test_interface_detection_uses_exact_tailscale_identity() {
  local workspace
  workspace="$(new_workspace interface-identity)"

  cat > "$workspace/pf.conf" <<'EOF'
set skip on lo0
EOF
  cat > "$workspace/ifconfig/utun4" <<'EOF'
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.1.2.3 --> 100.1.2.3 netmask 0xffffffff
EOF
  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  IFCONFIG_LIST="lo0 utun4 utun7" run_install_env "$workspace" >/dev/null
  assert_file_contains "$workspace/pf.anchors/tailscale" " on utun7 "
  assert_file_not_contains "$workspace/pf.anchors/tailscale" " on utun4 "
  pass "interface detection ignores unrelated 100.x tunnels and matches tailscale ip exactly"
}

test_install_refuses_unmanaged_anchor_file() {
  local workspace
  workspace="$(new_workspace install-unmanaged-anchor)"

  cat > "$workspace/pf.conf" <<'EOF'
set skip on lo0
EOF
  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass quick all
EOF

  run_install_env "$workspace" --interface utun7 >/dev/null 2>&1 && fail "install should refuse an unmanaged anchor file"
  assert_file_contains "$workspace/pf.anchors/tailscale" "pass quick all"
  pass "install refuses to overwrite an unmanaged anchor artifact"
}

test_verify_rejects_broadened_runtime_anchor() {
  local workspace
  workspace="$(new_workspace verify-broad-runtime)"

  cat > "$workspace/pf.conf" <<EOF
anchor "tailscale"
load anchor "tailscale" from "$workspace/pf.anchors/tailscale"
EOF
  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF
  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  IFCONFIG_LIST="lo0 utun7" \
  PFCTL_ANCHOR_RULES="pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
pass quick all" \
  run_verify_env "$workspace" >/dev/null 2>&1 && fail "verify should reject extra broad runtime rules"

  pass "verify rejects a broadened runtime anchor even when all expected rules are present"
}

test_daemon_scripts_refuse_unmarked_plist() {
  local workspace
  workspace="$(new_workspace daemon-unmarked)"

  printf '%s\n' '<plist><dict><string>foreign daemon</string></dict></plist>' > "$workspace/com.tailscale.tailscaled.plist"

  run_daemon_install_env "$workspace" >/dev/null 2>&1 && fail "daemon installer should refuse an unmarked plist"
  run_daemon_uninstall_env "$workspace" >/dev/null 2>&1 && fail "daemon uninstaller should refuse an unmarked plist"
  assert_file_contains "$workspace/com.tailscale.tailscaled.plist" "foreign daemon"
  [[ ! -s "$workspace/logs/launchctl.calls" ]] || fail "Unmarked daemon must not be stopped or bootstrapped"
  pass "daemon scripts refuse to modify unmarked launchd artifacts"
}

test_watcher_scripts_refuse_unrecognized_artifacts() {
  local workspace
  workspace="$(new_workspace watcher-unmarked)"

  mkdir -p "$workspace/watcher"
  printf '%s\n' "foreign payload" > "$workspace/watcher/foreign"
  printf '%s\n' '<plist><dict><string>foreign watcher</string></dict></plist>' > "$workspace/com.mullvad-tailscale-macos.pf-watcher.plist"

  run_pf_watcher_install_env "$workspace" >/dev/null 2>&1 && fail "watcher installer should refuse unrecognized artifacts"
  run_pf_watcher_uninstall_env "$workspace" >/dev/null 2>&1 && fail "watcher uninstaller should refuse unrecognized artifacts"
  assert_file_contains "$workspace/watcher/foreign" "foreign payload"
  pass "watcher scripts refuse to overwrite or delete unrecognized artifacts"
}

test_refresh_refuses_when_mullvad_protection_is_missing() {
  local workspace
  workspace="$(new_workspace refresh-mullvad-missing)"

  cat > "$workspace/pf.anchors/tailscale" <<'EOF'
pass out quick on utun7 inet from any to 100.64.0.0/10 no state
pass in quick on utun7 inet from 100.64.0.0/10 to any no state
pass out quick on utun7 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun7 inet6 from fd7a:115c:a1e0::/48 to any no state
EOF
  cat > "$workspace/ifconfig/utun7" <<'EOF'
utun7: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1280
	inet 100.82.1.2 --> 100.82.1.2 netmask 0xffffffff
EOF

  IFCONFIG_LIST="lo0 utun7" PFCTL_ANCHORS="tailscale" run_refresh_env "$workspace" >/dev/null 2>&1 && \
    fail "refresh should refuse to attach Tailscale while expected Mullvad protection is absent"
  assert_file_not_contains "$workspace/logs/pfctl.calls" "-a tailscale -f $workspace/pf.anchors/tailscale"
  pass "refresh refuses to attach the exception when Mullvad protection is inconsistent"
}

test_install_detects_interface_and_writes_anchor
test_install_repairs_partial_anchor_block
test_install_repairs_missing_anchor_and_accepts_pf_optimizer_order
test_install_rolls_back_failed_pf_reload
test_install_preserves_live_mullvad_anchor_during_reload
test_install_rolls_back_if_mullvad_changes_after_reload
test_install_refuses_when_mullvad_expected_without_anchor
test_uninstall_refuses_when_expected_mullvad_anchor_is_empty
test_install_refuses_unknown_dynamic_anchor
test_interface_detection_uses_exact_tailscale_identity
test_install_refuses_unmanaged_anchor_file
test_uninstall_removes_anchor_block_and_file
test_verify_rejects_partial_pf_conf
test_verify_rejects_broadened_runtime_anchor
test_verify_supports_active_checks
test_verify_accepts_derp_fallback_as_reachable
test_verify_rejects_system_resolver_mismatch
test_verify_rejects_missing_system_resolution
test_verify_warns_on_hosts_override
test_verify_accepts_externally_managed_tailscaled
test_verify_followups_only_suggest_resolver_for_tailnet_domains
test_verify_warns_when_tailnet_resolver_override_is_missing
test_verify_warns_on_mullvad_content_blocker_dns
test_verify_ignores_non_blocker_dns
test_blocker_dns_classifier_boundaries
test_resolver_installer_writes_file_and_flushes_dns
test_resolver_installer_refuses_unmanaged_existing_file
test_resolver_installer_propagates_flush_failures
test_resolver_uninstaller_removes_file_and_flushes_dns
test_resolver_uninstaller_refuses_unmanaged_existing_file
test_daemon_installer_bootstraps_launchdaemon
test_daemon_uninstaller_boots_out_and_removes_plist
test_daemon_scripts_refuse_unmarked_plist
test_pf_watcher_installer_installs_payload_and_bootstraps
test_pf_watcher_uninstaller_boots_out_and_removes
test_watcher_scripts_refuse_unrecognized_artifacts
test_refresh_reattaches_anchor_on_interface_change
test_refresh_noop_when_interface_unchanged
test_refresh_reattaches_when_runtime_anchor_empty
test_refresh_fails_when_runtime_reload_fails
test_refresh_refuses_when_mullvad_protection_is_missing

echo ""
echo "All tests passed ($PASS_COUNT checks)."
