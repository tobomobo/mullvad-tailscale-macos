#!/bin/bash

TAILSCALE_ANCHOR_NAME="tailscale"
ANCHOR_FILE="${ANCHOR_FILE:-/etc/pf.anchors/tailscale}"
PF_CONF="${PF_CONF:-/etc/pf.conf}"
ANCHOR_TEMPLATE="$SCRIPT_DIR/etc/pf.anchors/tailscale"

# Every other tool is resolved through PATH. These two are pinned to their
# absolute macOS paths because a PATH-shadowed chmod or stat would silently
# defeat the ACL stripping and permission checks on privileged files.
CHMOD_BIN="${CHMOD_BIN:-/bin/chmod}"
STAT_BIN="${STAT_BIN:-/usr/bin/stat}"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
RESOLVER_DIR="${RESOLVER_DIR:-/etc/resolver}"

TAILSCALED_DAEMON_LABEL="com.tailscale.tailscaled"
TAILSCALED_DAEMON_PLIST="${TAILSCALED_DAEMON_PLIST:-/Library/LaunchDaemons/com.tailscale.tailscaled.plist}"
TAILSCALED_MANAGED_BIN="${TAILSCALED_MANAGED_BIN:-/Library/PrivilegedHelperTools/mullvad-tailscale-macos.tailscaled}"
# Routine daemon output is discarded so the tailnet leaves no metadata trail on
# disk; verify.sh asserts both plists still point at /dev/null.
MANAGED_DAEMON_LOG="/dev/null"

PF_WATCHER_LABEL="com.mullvad-tailscale-macos.pf-watcher"
PF_WATCHER_PLIST="${PF_WATCHER_PLIST:-/Library/LaunchDaemons/com.mullvad-tailscale-macos.pf-watcher.plist}"
PF_WATCHER_INSTALL_DIR="${PF_WATCHER_INSTALL_DIR:-/Library/Application Support/mullvad-tailscale-macos}"
PF_WATCHER_SCRIPT="$PF_WATCHER_INSTALL_DIR/refresh-anchor.sh"
PF_WATCHER_INTERVAL=120
PF_WATCHER_MARKER_FILE="$PF_WATCHER_INSTALL_DIR/.managed-by-mullvad-tailscale-macos"

TAILSCALE_IPV4_RANGE="100.64.0.0/10"
TAILSCALE_IPV6_RANGE="fd7a:115c:a1e0::/48"
TAILSCALE_MAGICDNS_SERVER="100.100.100.100"
MULLVAD_ANCHOR_NAME="mullvad"

# Mullvad's in-app content blockers point system DNS at 100.64.0.<bitmask>
# (ads=1, trackers=2, malware=4, adult=8, gambling=16, social=32; max 63), which
# sits inside Tailscale's 100.64.0.0/10 range, so the two collide while Tailscale
# is up. Matches 100.64.0.1 through 100.64.0.63.
MULLVAD_BLOCKER_DNS_REGEX="^100\\.64\\.0\\.([1-9]|[1-5][0-9]|6[0-3])\$"
TAILNET_RESOLVER_COMMENT="# Managed by install-tailnet-resolver.sh"
MANAGED_FILE_COMMENT="# Managed by mullvad-tailscale-macos"
MANAGED_PLIST_COMMENT="<!-- Managed by mullvad-tailscale-macos -->"
PF_WATCHER_MARKER_CONTENT="Managed by mullvad-tailscale-macos pf-watcher"
ANCHOR_COMMENT="# Tailscale anchor - allow tailnet traffic through Mullvad kill switch"
ANCHOR_LINE="anchor \"$TAILSCALE_ANCHOR_NAME\""
LOAD_LINE="load anchor \"$TAILSCALE_ANCHOR_NAME\" from \"$ANCHOR_FILE\""

die() {
  echo "Error: $*" >&2
  exit 1
}

# Error detail that must survive launchd. The pf-watcher LaunchDaemon discards
# stderr, so when stderr is not a terminal the message is also written to the
# unified log. Messages name anchors and interfaces, never tailnet addresses.
report_error() {
  echo "$*" >&2
  if [[ ! -t 2 ]]; then
    logger -t mullvad-tailscale-macos -- "mullvad-tailscale-macos: $*" 2>/dev/null || true
  fi
}

# For scripts whose only option is --help. Calls the caller's usage().
parse_help_only() {
  if [[ $# -gt 0 ]]; then
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
      usage
      exit 0
    fi
    usage >&2
    exit 1
  fi
}

require_root() {
  if [[ "${SKIP_ROOT_CHECK:-0}" == "1" ]]; then
    return 0
  fi

  if [[ $EUID -ne 0 ]]; then
    die "This script must be run with sudo."
  fi
}

running_as_root() {
  [[ $EUID -eq 0 || "${SKIP_ROOT_CHECK:-0}" == "1" ]]
}

make_temp_file() {
  mktemp "${TMPDIR:-/tmp}/$1.XXXXXX"
}

validate_tailnet_domain() {
  local domain="$1"

  [[ -n "$domain" ]] || return 1
  [[ "$domain" != .* ]] || return 1
  [[ "$domain" != *. ]] || return 1
  [[ "$domain" != *..* ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  [[ "$domain" == *.ts.net ]]
}

has_exact_line() {
  local file="$1"
  local line="$2"

  [[ -f "$file" ]] && grep -Fqx -- "$line" "$file"
}

count_exact_line() {
  local count

  # grep -c exits 1 while still printing "0", and exits 2 on a missing file.
  count="$(grep -Fxc -- "$2" "$1" 2>/dev/null)" || count=0
  echo "$count"
}

join_lines() {
  local separator="${2:-, }"

  awk -v sep="$separator" 'NF { out = out ? out sep $0 : $0 } END { print out }' <<<"$1"
}

list_has_common_line() {
  local first="$1"
  local second="$2"

  grep -Fxq -f <(grep -v '^$' <<<"$first") <<<"$second"
}

direct_magicdns_lookup() {
  local hostname="$1"

  { dig +short @"$TAILSCALE_MAGICDNS_SERVER" "$hostname" 2>/dev/null || true; } | awk '
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || /^[0-9A-Fa-f:]+$/ {
      if (!seen[$0]++) {
        print $0
      }
    }
  '
}

system_resolver_lookup() {
  local hostname="$1"

  { dscacheutil -q host -a name "$hostname" 2>/dev/null || true; } | awk '
    /^ip_address: / {
      if (!seen[$2]++) {
        print $2
      }
    }
  '
}

hosts_file_lookup() {
  local hostname="$1"
  local file="${2:-$HOSTS_FILE}"

  [[ -f "$file" ]] || return 0

  awk -v hostname="$hostname" '
    /^[[:space:]]*#/ || NF < 2 { next }
    {
      ip = $1
      if (ip !~ /^[0-9A-Fa-f:.]+$/) {
        next
      }

      for (i = 2; i <= NF; i++) {
        if ($i == hostname && !seen[ip]++) {
          print ip
        }
      }
    }
  ' "$file" 2>/dev/null || true
}

mullvad_blocker_dns_in_use() {
  scutil --dns 2>/dev/null | awk '
    /nameserver\[[0-9]+\]/ {
      ip = $NF
      if (ip ~ /^[0-9A-Fa-f:.]+$/ && !seen[ip]++) {
        print ip
      }
    }
  ' | grep -E "$MULLVAD_BLOCKER_DNS_REGEX" || true
}

tailscale_backends_are_ambiguous() {
  pgrep -q tailscaled 2>/dev/null &&
    pgrep -qf 'io\.tailscale\.ipn\.macsys\.network-extension|IPNExtension' 2>/dev/null
}

# Exit codes: 1 = no interface found, 2 = two Tailscale backends are running,
# 3 = several utuns carry the Tailscale ULA prefix. Callers report 2 and 3
# loudly instead of treating them like "Tailscale is not running".
detect_tailscale_interface() {
  tailscale_backends_are_ambiguous && return 2

  if [[ -n "${TAILSCALE_INTERFACE:-}" ]]; then
    [[ "$TAILSCALE_INTERFACE" =~ ^utun[0-9]+$ ]] || return 1
    echo "$TAILSCALE_INTERFACE"
    return 0
  fi

  local iface
  local config
  local detected_interface=""
  local tailscale_ipv4
  local tailscale_ipv6

  tailscale_ipv4="$(tailscale ip -4 2>/dev/null | awk 'NF { print $1; exit }' || true)"
  tailscale_ipv6="$(tailscale ip -6 2>/dev/null | awk 'NF { print $1; exit }' || true)"

  [[ "$tailscale_ipv4" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || tailscale_ipv4=""
  [[ "$tailscale_ipv6" =~ ^fd7a:115c:a1e0: ]] || tailscale_ipv6=""

  for iface in $(ifconfig -l 2>/dev/null || true); do
    [[ "$iface" == utun* ]] || continue

    config="$(ifconfig "$iface" 2>/dev/null || true)"
    if [[ -n "$tailscale_ipv4" ]] && awk -v ip="$tailscale_ipv4" '$1 == "inet" && $2 == ip { found=1 } END { exit !found }' <<<"$config"; then
      echo "$iface"
      return 0
    fi
    if [[ -n "$tailscale_ipv6" ]] && awk -v ip="$tailscale_ipv6" '$1 == "inet6" { sub(/%.*/, "", $2); if ($2 == ip) found=1 } END { exit !found }' <<<"$config"; then
      echo "$iface"
      return 0
    fi
    if [[ -z "$tailscale_ipv4" && -z "$tailscale_ipv6" ]] && \
      awk '$1 == "inet6" { sub(/%.*/, "", $2); if ($2 ~ /^fd7a:115c:a1e0:/) found=1 } END { exit !found }' <<<"$config"; then
      [[ -z "$detected_interface" ]] || return 3
      detected_interface="$iface"
    fi
  done

  [[ -n "$detected_interface" ]] || return 1
  echo "$detected_interface"
}

anchor_interface_from_file() {
  local file="$1"

  awk '/^pass out quick on / {print $5; exit}' "$file"
}

expected_anchor_rules() {
  local interface="$1"

  [[ "$interface" =~ ^utun[0-9]+$ ]] || return 1
  cat <<EOF
pass out quick on $interface inet from any to $TAILSCALE_IPV4_RANGE no state
pass in quick on $interface inet from $TAILSCALE_IPV4_RANGE to any no state
pass out quick on $interface inet6 from any to $TAILSCALE_IPV6_RANGE no state
pass in quick on $interface inet6 from $TAILSCALE_IPV6_RANGE to any no state
EOF
}

anchor_policy_file_is_exact() {
  local file="$1"
  local interface="$2"
  local actual
  local expected

  [[ -f "$file" ]] || return 1
  actual="$(awk 'NF && $1 != "#" { print }' "$file")"
  expected="$(expected_anchor_rules "$interface")" || return 1
  [[ "$actual" == "$expected" ]]
}

anchor_runtime_rules_are_exact() {
  local rules="$1"
  local interface="$2"
  local normalized
  local expected
  local expected_rule

  normalized="$(sed -E 's/ flags S\/SA no state$/ no state/' <<<"$rules" | awk 'NF { print }')"
  expected="$(expected_anchor_rules "$interface")" || return 1

  # PF's optimizer can reorder independent rules when it loads an anchor. The
  # security contract is the exact four-rule set, not the template's display
  # order: require four lines and exactly one occurrence of every expected rule.
  [[ "$(awk 'NF { count++ } END { print count + 0 }' <<<"$normalized")" == "4" ]] || return 1
  while IFS= read -r expected_rule; do
    [[ "$(grep -Fxc -- "$expected_rule" <<<"$normalized" || true)" == "1" ]] || return 1
  done <<<"$expected"
}

print_anchor_runtime_mismatch() {
  local rules="$1"
  local interface="$2"

  echo "Expected exactly these four rules (their runtime order may differ):" >&2
  expected_anchor_rules "$interface" | sed 's/^/  /' >&2
  echo "PF reported:" >&2
  if [[ -n "$rules" ]]; then
    sed 's/^/  /' <<<"$rules" >&2
  else
    echo "  <no rules>" >&2
  fi
}

anchor_file_managed_by_repo() {
  local file="$1"

  # The ownership marker is advisory: adoption is decided purely by the file
  # containing the exact known narrow policy and nothing else.
  [[ -f "$file" ]] || return 1
  anchor_policy_file_is_exact "$file" "$(anchor_interface_from_file "$file" 2>/dev/null || true)"
}

render_anchor_template() {
  local template="$1"
  local destination="$2"
  local interface="$3"

  sed "s/__TAILSCALE_INTERFACE__/$interface/g" "$template" > "$destination"
}

ensure_anchor_block() {
  local source_file="$1"
  local destination_file="$2"

  awk \
    -v comment="$ANCHOR_COMMENT" \
    -v anchor="$ANCHOR_LINE" \
    -v load="$LOAD_LINE" \
    '
      $0 != comment && $0 != anchor && $0 != load { lines[++count] = $0 }
      END {
        while (count > 0 && lines[count] == "") count--
        for (i = 1; i <= count; i++) print lines[i]
        print ""
        print comment
        print anchor
        print load
      }
    ' "$source_file" > "$destination_file"
}

managed_anchor_block_is_exact() {
  local file="$1"
  local comment_count

  [[ "$(count_exact_line "$file" "$ANCHOR_LINE")" == "1" ]] || return 1
  [[ "$(count_exact_line "$file" "$LOAD_LINE")" == "1" ]] || return 1
  comment_count="$(count_exact_line "$file" "$ANCHOR_COMMENT")"
  [[ "$comment_count" == "0" || "$comment_count" == "1" ]] || return 1

  # The managed lines must be contiguous, and must follow the comment when one
  # is present.
  awk -v want_comment="$comment_count" \
    -v comment="$ANCHOR_COMMENT" -v anchor="$ANCHOR_LINE" -v load="$LOAD_LINE" '
      want_comment && $0 == comment { state=1; next }
      $0 == anchor && (!want_comment || state == 1) { state=2; next }
      state == 2 && $0 == load { found=1; state=0; next }
      state { state=0 }
      END { exit !found }
    ' "$file"
}

remove_anchor_block() {
  local source_file="$1"
  local destination_file="$2"

  awk \
    -v comment="$ANCHOR_COMMENT" \
    -v anchor="$ANCHOR_LINE" \
    -v load="$LOAD_LINE" \
    '
      $0 != comment && $0 != anchor && $0 != load { print }
    ' "$source_file" > "$destination_file"
}

file_differs() {
  local first="$1"
  local second="$2"

  ! cmp -s "$first" "$second"
}

backup_file() {
  local file="$1"
  local backup_path="${file}.bak.$(date +%Y%m%d%H%M%S)"

  cp "$file" "$backup_path" || return 1
  echo "$backup_path"
}

install_root_owned_file() {
  local source_file="$1"
  local destination_file="$2"
  local file_mode="${3:-644}"

  cp "$source_file" "$destination_file"
  chown root:wheel "$destination_file"
  "$CHMOD_BIN" -N "$destination_file"
  "$CHMOD_BIN" "$file_mode" "$destination_file"
}

install_root_owned_dir() {
  local dir="$1"
  local dir_mode="${2:-755}"

  mkdir -p "$dir"
  chown root:wheel "$dir"
  "$CHMOD_BIN" "$dir_mode" "$dir"
}

validate_anchor_policy_file() {
  local file="$1"
  local interface="$2"

  anchor_policy_file_is_exact "$file" "$interface" && \
    pfctl -n -a "$TAILSCALE_ANCHOR_NAME" -f "$file" >/dev/null 2>&1
}

validate_pf_conf() {
  local file="$1"

  pfctl -n -f "$file" >/dev/null 2>&1
}

load_runtime_anchor() {
  local file="$1"

  pfctl -a "$TAILSCALE_ANCHOR_NAME" -f "$file" >/dev/null 2>&1
}

pf_main_anchor_calls() {
  local rules

  rules="$(pfctl -sr 2>/dev/null)" || return 1
  awk '$1 == "anchor" {
    name=$2
    gsub(/^"|"$/, "", name)
    print name
  }' <<<"$rules"
}

pf_main_anchor_is_called() {
  local anchor="$1"
  local anchor_calls="$2"

  grep -Fqx -- "$anchor" <<<"$anchor_calls"
}

pf_anchor_call_list_contains_all() {
  local expected="$1"
  local actual="$2"
  local ignored_anchor="${3:-}"
  local anchor

  while IFS= read -r anchor; do
    [[ -n "$anchor" && "$anchor" != "$ignored_anchor" ]] || continue
    grep -Fqx -- "$anchor" <<<"$actual" || return 1
  done <<<"$expected"
}

pf_anchor_rules() {
  local anchor="$1"

  pfctl -a "$anchor" -sr 2>/dev/null
}

pf_is_enabled() {
  pfctl -s info 2>/dev/null | grep -Eq '^Status:[[:space:]]+Enabled([[:space:]]|$)'
}

pf_anchor_precedes() {
  local first="$1"
  local second="$2"
  local anchor_calls="$3"

  awk -v first="$first" -v second="$second" '
    $0 == first && !first_line { first_line=NR }
    $0 == second && !second_line { second_line=NR }
    END { exit !(first_line && second_line && first_line < second_line) }
  ' <<<"$anchor_calls"
}

tailscale_main_anchor_call_is_safe() {
  local anchor_calls

  anchor_calls="$(pf_main_anchor_calls)" || return 1
  pf_main_anchor_is_called "$TAILSCALE_ANCHOR_NAME" "$anchor_calls" || return 1
  if pf_main_anchor_is_called "$MULLVAD_ANCHOR_NAME" "$anchor_calls"; then
    pf_anchor_precedes "$TAILSCALE_ANCHOR_NAME" "$MULLVAD_ANCHOR_NAME" "$anchor_calls"
  fi
}

file_owner_and_mode() {
  local file="$1"

  "$STAT_BIN" -L -f '%u %Lp' "$file" 2>/dev/null
}

file_has_no_extended_acl() {
  local file="$1"
  local acl_listing

  acl_listing="$(/bin/ls -lde "$file" 2>/dev/null)" || return 1
  ! grep -Eq '^[[:space:]]*[0-9]+:' <<<"$acl_listing"
}

file_is_root_owned_and_not_writable() {
  local file="$1"
  local metadata
  local owner
  local mode
  local numeric_mode

  [[ -f "$file" && ! -L "$file" ]] || return 1
  metadata="$(file_owner_and_mode "$file")" || return 1
  read -r owner mode <<<"$metadata"
  [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  numeric_mode=$((8#$mode))
  (( (numeric_mode & 022) == 0 )) || return 1
  file_has_no_extended_acl "$file"
}

plist_uses_program() {
  local file="$1"
  local program="$2"

  grep -Fq "<string>${program}</string>" "$file"
}

plist_discards_standard_streams() {
  local file="$1"

  [[ "$(grep -Ec '^[[:space:]]*<string>/dev/null</string>$' "$file" 2>/dev/null || true)" == "2" ]]
}

mullvad_status() {
  mullvad status 2>/dev/null
}

mullvad_lockdown_status() {
  mullvad lockdown-mode get 2>/dev/null
}

mullvad_status_is_connected() {
  local status="${1:-}"

  grep -Eq '^Connected([[:space:]]|$)' <<<"$status"
}

mullvad_lockdown_is_enabled() {
  local status="${1:-}"

  grep -Eqi '(lockdown|block traffic).*(:|is)[[:space:]]*(on|enabled)([[:space:]]|$)' <<<"$status"
}

mullvad_protection_is_expected() {
  local status
  local lockdown

  status="$(mullvad_status)" || return 1
  lockdown="$(mullvad_lockdown_status)" || return 1
  mullvad_status_is_connected "$status" || mullvad_lockdown_is_enabled "$lockdown"
}

mullvad_pf_protection_is_consistent() {
  local anchor_calls
  local rules

  if ! mullvad_protection_is_expected && command -v mullvad >/dev/null 2>&1; then
    return 0
  fi
  anchor_calls="$(pf_main_anchor_calls)" || return 1
  pf_main_anchor_is_called "$MULLVAD_ANCHOR_NAME" "$anchor_calls" || return 1
  rules="$(pf_anchor_rules "$MULLVAD_ANCHOR_NAME")" || return 1
  [[ -n "$rules" ]]
}

append_runtime_mullvad_anchor() {
  local source_file="$1"
  local destination_file="$2"
  local mullvad_line="anchor \"$MULLVAD_ANCHOR_NAME\""

  awk -v line="$mullvad_line" '$0 != line { print }' "$source_file" > "$destination_file"
  printf '\n# Runtime-only preservation of Mullvad during this ruleset transaction.\n%s\n' "$mullvad_line" >> "$destination_file"
}

restore_pf_conf_and_runtime() {
  local previous_conf="$1"
  local anchor_calls_before="$2"
  local preserve_mullvad="$3"
  local mullvad_rules_before="$4"
  local rollback_conf
  local anchor_calls_after

  rollback_conf="$(make_temp_file pf-rollback-conf)"
  cp "$previous_conf" "$PF_CONF"
  if [[ "$preserve_mullvad" -eq 1 ]]; then
    append_runtime_mullvad_anchor "$previous_conf" "$rollback_conf"
  else
    cp "$previous_conf" "$rollback_conf"
  fi

  if ! validate_pf_conf "$rollback_conf" || ! reload_pf_conf "$rollback_conf"; then
    rm -f "$rollback_conf"
    return 1
  fi

  anchor_calls_after="$(pf_main_anchor_calls 2>/dev/null || true)"
  if ! pf_anchor_call_list_contains_all "$anchor_calls_before" "$anchor_calls_after"; then
    rm -f "$rollback_conf"
    return 1
  fi

  if [[ "$preserve_mullvad" -eq 1 ]] && \
    [[ "$(pf_anchor_rules "$MULLVAD_ANCHOR_NAME" 2>/dev/null || true)" != "$mullvad_rules_before" ]]; then
    rm -f "$rollback_conf"
    return 1
  fi

  rm -f "$rollback_conf"
}

# Human-readable hint for a runtime-only main-ruleset anchor call that blocks a
# full reload. macOS inserts com.apple.internet-sharing for Internet Sharing and
# for the shared (NAT) networking used by VM and container apps; the anchor
# exists only while that service runs and is never written to /etc/pf.conf.
explain_runtime_anchor() {
  local anchor="$1"

  case "$anchor" in
    com.apple.internet-sharing|com.apple.internet-sharing/*)
      echo "macOS attaches '$anchor' at runtime for Internet Sharing and for apps that use macOS shared (NAT) networking, for example Parallels Desktop, Docker Desktop, OrbStack, or UTM. Quit those apps or turn off Internet Sharing, confirm with 'sudo pfctl -sr | grep anchor' that the anchor is gone, then rerun this script. Reopening the apps afterwards is fine. See docs/troubleshooting.md#a-runtime-pf-anchor-blocks-the-reload."
      ;;
    *)
      echo "'$anchor' was attached to the live ruleset by software this repo does not recognize, possibly a firewall or VPN. This script only knows the anchor's name, not what it protects. Do not stop a security product while on an untrusted network; check that product's documentation for its supported persistent PF setup before retrying. See docs/troubleshooting.md#a-runtime-pf-anchor-blocks-the-reload."
      ;;
  esac
}

pf_conf_covers_anchor() {
  local file="$1"
  local target="$2"

  awk -v target="$target" '
    $1 == "anchor" {
      name=$2
      gsub(/^"|"$/, "", name)
      wildcard=(name ~ /\/\*$/)
      sub(/\/\*$/, "", name)
      if (name == target || (wildcard && index(target, name "/") == 1)) found=1
    }
    END { exit !found }
  ' "$file"
}

reload_pf_conf() {
  local file="$1"

  pfctl -f "$file" >/dev/null 2>&1
}

apply_pf_conf_update() {
  local new_conf="$1"
  local backup_path
  local runtime_conf
  local anchor_calls_before
  local mullvad_rules_before=""
  local mullvad_rules_after=""
  local preserve_mullvad=0
  local active_anchor
  local anchor_calls_after
  local postcheck_failed=0

  anchor_calls_before="$(pf_main_anchor_calls)" || {
    echo "Unable to inspect active main PF anchor calls; refusing a full ruleset reload." >&2
    return 1
  }

  while IFS= read -r active_anchor; do
    [[ -n "$active_anchor" ]] || continue
    if [[ "$active_anchor" != "$MULLVAD_ANCHOR_NAME" && "$active_anchor" != "$TAILSCALE_ANCHOR_NAME" ]] && \
      ! pf_conf_covers_anchor "$new_conf" "$active_anchor"; then
      report_error "Active main PF anchor call '$active_anchor' is not represented in the staged config; refusing to flush it."
      report_error "$(explain_runtime_anchor "$active_anchor")"
      return 1
    fi
  done <<<"$anchor_calls_before"

  if pf_main_anchor_is_called "$MULLVAD_ANCHOR_NAME" "$anchor_calls_before"; then
    preserve_mullvad=1
    mullvad_rules_before="$(pf_anchor_rules "$MULLVAD_ANCHOR_NAME")" || {
      echo "Unable to snapshot Mullvad's active PF rules; refusing a full ruleset reload." >&2
      return 1
    }
    if mullvad_protection_is_expected && [[ -z "$mullvad_rules_before" ]]; then
      echo "Mullvad reports active protection, but its called PF anchor is empty. Refusing to reload PF." >&2
      return 1
    fi
  elif mullvad_protection_is_expected; then
    echo "Mullvad reports an active connection or lockdown mode, but the main PF ruleset does not call its anchor. Refusing to reload PF." >&2
    return 1
  fi

  runtime_conf="$(make_temp_file pf-runtime-conf)"
  if [[ "$preserve_mullvad" -eq 1 ]]; then
    append_runtime_mullvad_anchor "$new_conf" "$runtime_conf"
    validate_pf_conf "$runtime_conf" || {
      rm -f "$runtime_conf"
      echo "Runtime PF config with Mullvad preservation failed validation." >&2
      return 1
    }
  else
    # Callers run this function inside command substitution, where set -e does
    # not apply, so every copy before the reload is checked explicitly. An
    # unchecked failure here would hand pfctl an empty runtime file.
    cp "$new_conf" "$runtime_conf" || {
      rm -f "$runtime_conf"
      report_error "Unable to stage the runtime PF config; PF was not reloaded."
      return 1
    }
  fi

  backup_path="$(backup_file "$PF_CONF")" || {
    rm -f "$runtime_conf"
    report_error "Unable to back up $PF_CONF; PF was not reloaded and the file is unchanged."
    return 1
  }
  if ! cp "$new_conf" "$PF_CONF"; then
    rm -f "$runtime_conf"
    if cp "$backup_path" "$PF_CONF"; then
      report_error "Unable to write $PF_CONF; PF was not reloaded and the previous file was restored from $backup_path."
    else
      report_error "CRITICAL: unable to write $PF_CONF and unable to restore it from $backup_path; PF was not reloaded. Restore the file by hand before the next reboot."
    fi
    return 1
  fi

  if ! reload_pf_conf "$runtime_conf"; then
    if ! restore_pf_conf_and_runtime "$backup_path" "$anchor_calls_before" "$preserve_mullvad" "$mullvad_rules_before"; then
      rm -f "$runtime_conf"
      echo "CRITICAL: the PF reload failed and the previous runtime ruleset could not be re-established. Disconnect this Mac from untrusted networks and reapply Mullvad immediately." >&2
      return 1
    fi
    rm -f "$runtime_conf"
    echo "Reload failed; restored the previous file and runtime PF ruleset." >&2
    return 1
  fi

  anchor_calls_after="$(pf_main_anchor_calls 2>/dev/null || true)"
  if ! pf_anchor_call_list_contains_all "$anchor_calls_before" "$anchor_calls_after" "$TAILSCALE_ANCHOR_NAME"; then
    postcheck_failed=1
  fi

  if [[ "$preserve_mullvad" -eq 1 ]]; then
    mullvad_rules_after="$(pf_anchor_rules "$MULLVAD_ANCHOR_NAME" 2>/dev/null || true)"
    if ! pf_main_anchor_is_called "$MULLVAD_ANCHOR_NAME" "$anchor_calls_after" || [[ "$mullvad_rules_after" != "$mullvad_rules_before" ]]; then
      postcheck_failed=1
    fi
  fi

  if [[ "$postcheck_failed" -eq 1 ]]; then
    echo "A protected main PF anchor call or Mullvad's rules changed during reload; restoring the previous configuration." >&2
    if ! restore_pf_conf_and_runtime "$backup_path" "$anchor_calls_before" "$preserve_mullvad" "$mullvad_rules_before"; then
      rm -f "$runtime_conf"
      echo "CRITICAL: failed to restore the previous PF runtime ruleset. Disconnect this Mac from untrusted networks and reapply Mullvad immediately." >&2
      return 1
    fi
    rm -f "$runtime_conf"
    return 1
  fi

  rm -f "$runtime_conf"
  echo "$backup_path"
}

flush_runtime_anchor() {
  pfctl -a "$TAILSCALE_ANCHOR_NAME" -F rules >/dev/null 2>&1
}

detect_tailscaled_binary() {
  if [[ -n "${TAILSCALED_BIN:-}" ]]; then
    echo "$TAILSCALED_BIN"
    return 0
  fi

  command -v tailscaled 2>/dev/null || return 1
}

write_launchdaemon_plist() {
  local destination_file="$1"
  local tailscaled_bin="$2"

  cat > "$destination_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
${MANAGED_PLIST_COMMENT}
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${TAILSCALED_DAEMON_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${tailscaled_bin}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${MANAGED_DAEMON_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${MANAGED_DAEMON_LOG}</string>
</dict>
</plist>
EOF
}

validate_plist() {
  local file="$1"

  plutil -lint "$file" >/dev/null 2>&1
}

write_pf_watcher_plist() {
  local destination_file="$1"
  local script_path="$2"

  cat > "$destination_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
${MANAGED_PLIST_COMMENT}
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PF_WATCHER_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${script_path}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>${PF_WATCHER_INTERVAL}</integer>
    <key>WatchPaths</key>
    <array>
        <string>/etc/resolv.conf</string>
        <string>/var/run/resolv.conf</string>
    </array>
    <key>StandardOutPath</key>
    <string>${MANAGED_DAEMON_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${MANAGED_DAEMON_LOG}</string>
</dict>
</plist>
EOF
}

plist_managed_by_repo() {
  local file="$1"

  has_exact_line "$file" "$MANAGED_PLIST_COMMENT"
}

pf_watcher_payload_managed_by_repo() {
  has_exact_line "$PF_WATCHER_MARKER_FILE" "$PF_WATCHER_MARKER_CONTENT"
}

launchd_loaded() {
  launchctl print "system/$1" >/dev/null 2>&1
}

bootout_launchd() {
  local label="$1"

  if launchd_loaded "$label"; then
    launchctl bootout "system/$label" >/dev/null 2>&1
  fi
}

bootstrap_launchd() {
  local plist="$1"
  local label="$2"

  # Keep launchctl's stderr visible during an interactive install. Suppressing
  # it previously reduced a failed bootstrap to an unactionable generic error.
  launchctl bootstrap system "$plist" >/dev/null || return 1
  launchctl kickstart -k "system/$label" >/dev/null || return 1
  launchd_loaded "$label"
}

resolver_file_for_domain() {
  local domain="$1"

  echo "${RESOLVER_DIR}/${domain}"
}

write_tailnet_resolver_file() {
  local destination_file="$1"
  local domain="$2"

  cat > "$destination_file" <<EOF
${TAILNET_RESOLVER_COMMENT}
# Routes ${domain} lookups to Tailscale MagicDNS.
nameserver ${TAILSCALE_MAGICDNS_SERVER}
EOF
}

resolver_file_has_nameserver() {
  local file="$1"
  local nameserver="${2:-$TAILSCALE_MAGICDNS_SERVER}"

  has_exact_line "$file" "nameserver $nameserver"
}

resolver_file_managed_by_repo() {
  local file="$1"

  has_exact_line "$file" "$TAILNET_RESOLVER_COMMENT"
}

flush_dns_caches() {
  local rc=0

  dscacheutil -flushcache >/dev/null 2>&1 || rc=1
  killall -HUP mDNSResponder >/dev/null 2>&1 || rc=1

  return "$rc"
}
