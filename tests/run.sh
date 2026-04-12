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
  printf '%s\n' "${PFCTL_ANCHOR_RULES:-}"
  exit 0
fi

if [[ "${PFCTL_FAIL_RELOAD:-0}" == "1" && "${1:-}" == "-f" && "${2:-}" == "$PF_CONF" ]]; then
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
exit 0
EOF

  cat > "$bin_dir/plutil" <<'EOF'
#!/bin/bash
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

  cat > "$bin_dir/killall" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TEST_LOG_DIR/killall.calls"
exit "${KILLALL_EXIT:-0}"
EOF

  cat > "$bin_dir/tailscale" <<'EOF'
#!/bin/bash
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
  PGREP_BIN="$bin_dir/pgrep" \
  CURL_BIN="$bin_dir/curl" \
  DIG_BIN="$bin_dir/dig" \
  DSCACHEUTIL_BIN="$bin_dir/dscacheutil" \
  KILLALL_BIN="$bin_dir/killall" \
  HOSTS_FILE="$workspace/hosts" \
  TAILSCALE_BIN="$bin_dir/tailscale" \
  TAILSCALED_DAEMON_PLIST="$workspace/com.tailscale.tailscaled.plist" \
  bash "$ROOT_DIR/verify.sh" "$@"
}

run_daemon_install_env() {
  local workspace="$1"
  shift

  local bin_dir="$workspace/bin"
  TEST_LOG_DIR="$workspace/logs" \
  SKIP_ROOT_CHECK=1 \
  TAILSCALED_BIN="/opt/test/bin/tailscaled" \
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

new_workspace() {
  local name="$1"
  local workspace="$TEST_TMP/$name"

  mkdir -p "$workspace/bin" "$workspace/ifconfig" "$workspace/logs" "$workspace/pf.anchors"
  : > "$workspace/logs/pfctl.calls"
  : > "$workspace/logs/launchctl.calls"
  : > "$workspace/logs/dscacheutil.calls"
  : > "$workspace/logs/killall.calls"
  : > "$workspace/hosts"
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

  assert_file_contains "$workspace/com.tailscale.tailscaled.plist" "/opt/test/bin/tailscaled"
  assert_file_contains "$workspace/logs/launchctl.calls" "bootstrap system $workspace/com.tailscale.tailscaled.plist"
  assert_file_contains "$workspace/logs/launchctl.calls" "kickstart -k system/com.tailscale.tailscaled"
  pass "daemon installer writes a plist and bootstraps it with launchctl"
}

test_daemon_uninstaller_boots_out_and_removes_plist() {
  local workspace
  workspace="$(new_workspace daemon-uninstall)"

  touch "$workspace/com.tailscale.tailscaled.plist"
  LAUNCHCTL_PRINT_EXIT=0 run_daemon_uninstall_env "$workspace"

  assert_file_contains "$workspace/logs/launchctl.calls" "print system/com.tailscale.tailscaled"
  assert_file_contains "$workspace/logs/launchctl.calls" "bootout system/com.tailscale.tailscaled"
  [[ ! -f "$workspace/com.tailscale.tailscaled.plist" ]] || fail "Expected LaunchDaemon plist to be removed"
  pass "daemon uninstaller unloads and removes the plist"
}

test_install_detects_interface_and_writes_anchor
test_install_repairs_partial_anchor_block
test_install_rolls_back_failed_pf_reload
test_uninstall_removes_anchor_block_and_file
test_verify_rejects_partial_pf_conf
test_verify_supports_active_checks
test_verify_accepts_derp_fallback_as_reachable
test_verify_rejects_system_resolver_mismatch
test_verify_rejects_missing_system_resolution
test_verify_warns_on_hosts_override
test_verify_warns_when_tailnet_resolver_override_is_missing
test_resolver_installer_writes_file_and_flushes_dns
test_resolver_installer_refuses_unmanaged_existing_file
test_resolver_installer_propagates_flush_failures
test_resolver_uninstaller_removes_file_and_flushes_dns
test_resolver_uninstaller_refuses_unmanaged_existing_file
test_daemon_installer_bootstraps_launchdaemon
test_daemon_uninstaller_boots_out_and_removes_plist

echo ""
echo "All tests passed ($PASS_COUNT checks)."
