#!/bin/bash

TAILSCALE_ANCHOR_NAME="${TAILSCALE_ANCHOR_NAME:-tailscale}"
ANCHOR_FILE="${ANCHOR_FILE:-/etc/pf.anchors/tailscale}"
PF_CONF="${PF_CONF:-/etc/pf.conf}"
ANCHOR_TEMPLATE="${ANCHOR_TEMPLATE:-$SCRIPT_DIR/etc/pf.anchors/tailscale}"

PFCTL_BIN="${PFCTL_BIN:-pfctl}"
IFCONFIG_BIN="${IFCONFIG_BIN:-ifconfig}"
TAILSCALE_BIN="${TAILSCALE_BIN:-tailscale}"
MULLVAD_BIN="${MULLVAD_BIN:-mullvad}"
PGREP_BIN="${PGREP_BIN:-pgrep}"
CURL_BIN="${CURL_BIN:-curl}"
DIG_BIN="${DIG_BIN:-dig}"
DSCACHEUTIL_BIN="${DSCACHEUTIL_BIN:-dscacheutil}"
SCUTIL_BIN="${SCUTIL_BIN:-scutil}"
KILLALL_BIN="${KILLALL_BIN:-killall}"
LAUNCHCTL_BIN="${LAUNCHCTL_BIN:-launchctl}"
PLUTIL_BIN="${PLUTIL_BIN:-plutil}"
CHOWN_BIN="${CHOWN_BIN:-chown}"
CHMOD_BIN="${CHMOD_BIN:-chmod}"
STAT_BIN="${STAT_BIN:-stat}"
CP_BIN="${CP_BIN:-cp}"
RM_BIN="${RM_BIN:-rm}"
CMP_BIN="${CMP_BIN:-cmp}"
DATE_BIN="${DATE_BIN:-date}"
MKDIR_BIN="${MKDIR_BIN:-mkdir}"
FIND_BIN="${FIND_BIN:-find}"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"
RESOLVER_DIR="${RESOLVER_DIR:-/etc/resolver}"

TAILSCALED_DAEMON_LABEL="${TAILSCALED_DAEMON_LABEL:-com.tailscale.tailscaled}"
TAILSCALED_DAEMON_PLIST="${TAILSCALED_DAEMON_PLIST:-/Library/LaunchDaemons/com.tailscale.tailscaled.plist}"
TAILSCALED_MANAGED_BIN="${TAILSCALED_MANAGED_BIN:-/Library/PrivilegedHelperTools/mullvad-tailscale-macos.tailscaled}"
TAILSCALED_STDOUT_PATH="${TAILSCALED_STDOUT_PATH:-/dev/null}"
TAILSCALED_STDERR_PATH="${TAILSCALED_STDERR_PATH:-/dev/null}"
LEGACY_TAILSCALED_STDOUT_PATH="${LEGACY_TAILSCALED_STDOUT_PATH:-/var/log/tailscaled.log}"
LEGACY_TAILSCALED_STDERR_PATH="${LEGACY_TAILSCALED_STDERR_PATH:-/var/log/tailscaled.err}"

PF_WATCHER_LABEL="${PF_WATCHER_LABEL:-com.mullvad-tailscale-macos.pf-watcher}"
PF_WATCHER_PLIST="${PF_WATCHER_PLIST:-/Library/LaunchDaemons/com.mullvad-tailscale-macos.pf-watcher.plist}"
PF_WATCHER_INSTALL_DIR="${PF_WATCHER_INSTALL_DIR:-/Library/Application Support/mullvad-tailscale-macos}"
PF_WATCHER_SCRIPT="${PF_WATCHER_SCRIPT:-$PF_WATCHER_INSTALL_DIR/refresh-anchor.sh}"
PF_WATCHER_LOG="${PF_WATCHER_LOG:-/dev/null}"
LEGACY_PF_WATCHER_LOG="${LEGACY_PF_WATCHER_LOG:-/var/log/mullvad-tailscale-pf-watcher.log}"
PF_WATCHER_INTERVAL="${PF_WATCHER_INTERVAL:-120}"
PF_WATCHER_MARKER_FILE="${PF_WATCHER_MARKER_FILE:-$PF_WATCHER_INSTALL_DIR/.managed-by-mullvad-tailscale-macos}"

TAILSCALE_IPV4_RANGE="100.64.0.0/10"
TAILSCALE_IPV6_RANGE="fd7a:115c:a1e0::/48"
TAILSCALE_MAGICDNS_SERVER="${TAILSCALE_MAGICDNS_SERVER:-100.100.100.100}"
MULLVAD_ANCHOR_NAME="${MULLVAD_ANCHOR_NAME:-mullvad}"

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

timestamp() {
  "$DATE_BIN" +%Y%m%d%H%M%S
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

validate_nameserver_ip() {
  local nameserver="$1"

  [[ -n "$nameserver" ]] || return 1
  [[ "$nameserver" =~ ^[0-9A-Fa-f:.]+$ ]]
}

has_exact_line() {
  local file="$1"
  local line="$2"

  [[ -f "$file" ]] && grep -Fqx -- "$line" "$file"
}

count_exact_line() {
  local file="$1"
  local line="$2"

  [[ -f "$file" ]] || {
    echo 0
    return 0
  }

  grep -Fxc -- "$line" "$file" || true
}

extract_ip_lines() {
  awk '
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || /^[0-9A-Fa-f:]+$/ {
      if (!seen[$0]++) {
        print $0
      }
    }
  '
}

join_lines() {
  local data="$1"
  local separator="${2:-, }"

  awk -v separator="$separator" '
    NF {
      output = output ? output separator $0 : $0
    }
    END {
      print output
    }
  ' <<<"$data"
}

list_has_common_line() {
  local first="$1"
  local second="$2"
  local line

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    grep -Fqx -- "$line" <<<"$second" && return 0
  done <<<"$first"

  return 1
}

direct_magicdns_lookup() {
  local hostname="$1"

  { "$DIG_BIN" +short @"$TAILSCALE_MAGICDNS_SERVER" "$hostname" 2>/dev/null || true; } | extract_ip_lines
}

system_resolver_lookup() {
  local hostname="$1"

  { "$DSCACHEUTIL_BIN" -q host -a name "$hostname" 2>/dev/null || true; } | awk '
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

system_dns_servers() {
  "$SCUTIL_BIN" --dns 2>/dev/null | awk '
    /nameserver\[[0-9]+\]/ {
      ip = $NF
      if (ip ~ /^[0-9A-Fa-f:.]+$/ && !seen[ip]++) {
        print ip
      }
    }
  '
}

dns_server_is_mullvad_blocker() {
  local ip="$1"

  [[ "$ip" =~ $MULLVAD_BLOCKER_DNS_REGEX ]]
}

mullvad_blocker_dns_in_use() {
  local ip

  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    if dns_server_is_mullvad_blocker "$ip"; then
      echo "$ip"
    fi
  done < <(system_dns_servers)

  return 0
}

detect_tailscale_interface() {
  if [[ -n "${TAILSCALE_INTERFACE:-}" ]]; then
    [[ "$TAILSCALE_INTERFACE" =~ ^utun[0-9]+$ ]] || return 1
    echo "$TAILSCALE_INTERFACE"
    return 0
  fi

  local iface
  local config
  local tailscale_ipv4
  local tailscale_ipv6

  tailscale_ipv4="$("$TAILSCALE_BIN" ip -4 2>/dev/null | awk 'NF { print $1; exit }')"
  tailscale_ipv6="$("$TAILSCALE_BIN" ip -6 2>/dev/null | awk 'NF { print $1; exit }')"

  [[ "$tailscale_ipv4" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || tailscale_ipv4=""
  [[ "$tailscale_ipv6" =~ ^fd7a:115c:a1e0: ]] || tailscale_ipv6=""
  [[ -n "$tailscale_ipv4" || -n "$tailscale_ipv6" ]] || return 1

  for iface in $("$IFCONFIG_BIN" -l 2>/dev/null || true); do
    [[ "$iface" == utun* ]] || continue

    config="$("$IFCONFIG_BIN" "$iface" 2>/dev/null || true)"
    if [[ -n "$tailscale_ipv4" ]] && awk -v ip="$tailscale_ipv4" '$1 == "inet" && $2 == ip { found=1 } END { exit !found }' <<<"$config"; then
      echo "$iface"
      return 0
    fi
    if [[ -n "$tailscale_ipv6" ]] && awk -v ip="$tailscale_ipv6" '$1 == "inet6" { sub(/%.*/, "", $2); if ($2 == ip) found=1 } END { exit !found }' <<<"$config"; then
      echo "$iface"
      return 0
    fi
  done

  return 1
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

  normalized="$(sed -E 's/ flags S\/SA no state$/ no state/' <<<"$rules" | awk 'NF { print }')"
  expected="$(expected_anchor_rules "$interface")" || return 1
  [[ "$normalized" == "$expected" ]]
}

anchor_file_managed_by_repo() {
  local file="$1"
  local interface

  [[ -f "$file" ]] || return 1
  interface="$(anchor_interface_from_file "$file" 2>/dev/null || true)"
  [[ -n "$interface" ]] || return 1

  if has_exact_line "$file" "$MANAGED_FILE_COMMENT"; then
    anchor_policy_file_is_exact "$file" "$interface"
    return
  fi

  # Legacy releases lacked the marker. Accept only the exact known narrow policy
  # so existing repo installs can be migrated without adopting arbitrary files.
  anchor_policy_file_is_exact "$file" "$interface"
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

  if [[ "$comment_count" == "1" ]]; then
    awk -v comment="$ANCHOR_COMMENT" -v anchor="$ANCHOR_LINE" -v load="$LOAD_LINE" '
      $0 == comment { state=1; next }
      state == 1 && $0 == anchor { state=2; next }
      state == 2 && $0 == load { found=1; state=0; next }
      state { state=0 }
      END { exit !found }
    ' "$file"
  else
    awk -v anchor="$ANCHOR_LINE" -v load="$LOAD_LINE" '
      $0 == anchor { state=1; next }
      state == 1 && $0 == load { found=1; state=0; next }
      state { state=0 }
      END { exit !found }
    ' "$file"
  fi
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

  ! "$CMP_BIN" -s "$first" "$second"
}

backup_file() {
  local file="$1"
  local backup_path="${file}.bak.$(timestamp)"

  "$CP_BIN" "$file" "$backup_path"
  echo "$backup_path"
}

install_root_owned_file() {
  local source_file="$1"
  local destination_file="$2"
  local file_mode="${3:-644}"

  "$CP_BIN" "$source_file" "$destination_file"
  "$CHOWN_BIN" root:wheel "$destination_file"
  "$CHMOD_BIN" "$file_mode" "$destination_file"
}

install_root_owned_dir() {
  local dir="$1"
  local dir_mode="${2:-755}"

  "$MKDIR_BIN" -p "$dir"
  "$CHOWN_BIN" root:wheel "$dir"
  "$CHMOD_BIN" "$dir_mode" "$dir"
}

validate_anchor_file() {
  local file="$1"

  "$PFCTL_BIN" -n -a "$TAILSCALE_ANCHOR_NAME" -f "$file" >/dev/null 2>&1
}

validate_anchor_policy_file() {
  local file="$1"
  local interface="$2"

  anchor_policy_file_is_exact "$file" "$interface" && validate_anchor_file "$file"
}

validate_pf_conf() {
  local file="$1"

  "$PFCTL_BIN" -n -f "$file" >/dev/null 2>&1
}

load_runtime_anchor() {
  local file="$1"

  "$PFCTL_BIN" -a "$TAILSCALE_ANCHOR_NAME" -f "$file" >/dev/null 2>&1
}

pf_list_anchors() {
  local output

  output="$("$PFCTL_BIN" -s Anchors 2>/dev/null)" || return 1
  awk 'NF { print $1 }' <<<"$output"
}

pf_anchor_is_attached() {
  local anchor="$1"
  local anchors

  if [[ $# -ge 2 ]]; then
    anchors="$2"
  else
    anchors="$(pf_list_anchors)" || return 1
  fi
  grep -Fqx -- "$anchor" <<<"$anchors"
}

pf_anchor_list_contains_all() {
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

  "$PFCTL_BIN" -a "$anchor" -sr 2>/dev/null
}

pf_is_enabled() {
  "$PFCTL_BIN" -s info 2>/dev/null | grep -Eq '^Status:[[:space:]]+Enabled([[:space:]]|$)'
}

pf_anchor_precedes() {
  local first="$1"
  local second="$2"
  local rules

  rules="$("$PFCTL_BIN" -sr 2>/dev/null)" || return 1
  awk -v first="\"$first\"" -v second="\"$second\"" '
    $1 == "anchor" && $2 == first && !first_line { first_line=NR }
    $1 == "anchor" && $2 == second && !second_line { second_line=NR }
    END { exit !(first_line && second_line && first_line < second_line) }
  ' <<<"$rules"
}

file_is_root_owned_and_not_writable() {
  local file="$1"
  local metadata
  local owner
  local mode
  local numeric_mode

  metadata="$("$STAT_BIN" -f '%u %Lp' "$file" 2>/dev/null)" || return 1
  read -r owner mode <<<"$metadata"
  [[ "$owner" == "0" && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
  numeric_mode=$((8#$mode))
  (( (numeric_mode & 022) == 0 ))
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
  "$MULLVAD_BIN" status 2>/dev/null
}

mullvad_lockdown_status() {
  "$MULLVAD_BIN" lockdown-mode get 2>/dev/null
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
  local anchors
  local rules

  mullvad_protection_is_expected || return 0
  anchors="$(pf_list_anchors)" || return 1
  pf_anchor_is_attached "$MULLVAD_ANCHOR_NAME" "$anchors" || return 1
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
  local anchors_before="$2"
  local preserve_mullvad="$3"
  local mullvad_rules_before="$4"
  local rollback_conf
  local anchors_after

  rollback_conf="$(make_temp_file pf-rollback-conf)"
  "$CP_BIN" "$previous_conf" "$PF_CONF"
  if [[ "$preserve_mullvad" -eq 1 ]]; then
    append_runtime_mullvad_anchor "$previous_conf" "$rollback_conf"
  else
    "$CP_BIN" "$previous_conf" "$rollback_conf"
  fi

  if ! validate_pf_conf "$rollback_conf" || ! reload_pf_conf "$rollback_conf"; then
    "$RM_BIN" -f "$rollback_conf"
    return 1
  fi

  anchors_after="$(pf_list_anchors 2>/dev/null || true)"
  if ! pf_anchor_list_contains_all "$anchors_before" "$anchors_after"; then
    "$RM_BIN" -f "$rollback_conf"
    return 1
  fi

  if [[ "$preserve_mullvad" -eq 1 ]] && \
    [[ "$(pf_anchor_rules "$MULLVAD_ANCHOR_NAME" 2>/dev/null || true)" != "$mullvad_rules_before" ]]; then
    "$RM_BIN" -f "$rollback_conf"
    return 1
  fi

  "$RM_BIN" -f "$rollback_conf"
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

  "$PFCTL_BIN" -f "$file" >/dev/null 2>&1
}

apply_pf_conf_update() {
  local new_conf="$1"
  local backup_path
  local runtime_conf
  local anchors_before
  local mullvad_rules_before=""
  local mullvad_rules_after=""
  local preserve_mullvad=0
  local active_anchor
  local anchors_after
  local postcheck_failed=0

  anchors_before="$(pf_list_anchors)" || {
    echo "Unable to inspect active PF anchors; refusing a full ruleset reload." >&2
    return 1
  }

  while IFS= read -r active_anchor; do
    [[ -n "$active_anchor" ]] || continue
    if [[ "$active_anchor" != "$MULLVAD_ANCHOR_NAME" && "$active_anchor" != "$TAILSCALE_ANCHOR_NAME" ]] && \
      ! pf_conf_covers_anchor "$new_conf" "$active_anchor"; then
      echo "Active PF anchor '$active_anchor' is not represented in the staged config; refusing to flush an unknown dynamic attachment." >&2
      return 1
    fi
  done <<<"$anchors_before"

  if pf_anchor_is_attached "$MULLVAD_ANCHOR_NAME" "$anchors_before"; then
    preserve_mullvad=1
    mullvad_rules_before="$(pf_anchor_rules "$MULLVAD_ANCHOR_NAME")" || {
      echo "Unable to snapshot Mullvad's active PF rules; refusing a full ruleset reload." >&2
      return 1
    }
    if mullvad_protection_is_expected && [[ -z "$mullvad_rules_before" ]]; then
      echo "Mullvad reports active protection, but its attached PF anchor is empty. Refusing to reload PF." >&2
      return 1
    fi
  elif mullvad_protection_is_expected; then
    echo "Mullvad reports an active connection or lockdown mode, but its PF anchor is not attached. Refusing to reload PF." >&2
    return 1
  fi

  runtime_conf="$(make_temp_file pf-runtime-conf)"
  if [[ "$preserve_mullvad" -eq 1 ]]; then
    append_runtime_mullvad_anchor "$new_conf" "$runtime_conf"
    validate_pf_conf "$runtime_conf" || {
      "$RM_BIN" -f "$runtime_conf"
      echo "Runtime PF config with Mullvad preservation failed validation." >&2
      return 1
    }
  else
    "$CP_BIN" "$new_conf" "$runtime_conf"
  fi

  backup_path="$(backup_file "$PF_CONF")"
  "$CP_BIN" "$new_conf" "$PF_CONF"

  if ! reload_pf_conf "$runtime_conf"; then
    if ! restore_pf_conf_and_runtime "$backup_path" "$anchors_before" "$preserve_mullvad" "$mullvad_rules_before"; then
      "$RM_BIN" -f "$runtime_conf"
      echo "CRITICAL: the PF reload failed and the previous runtime ruleset could not be re-established. Disconnect this Mac from untrusted networks and reapply Mullvad immediately." >&2
      return 1
    fi
    "$RM_BIN" -f "$runtime_conf"
    echo "Reload failed; restored the previous file and runtime PF ruleset." >&2
    return 1
  fi

  anchors_after="$(pf_list_anchors 2>/dev/null || true)"
  if ! pf_anchor_list_contains_all "$anchors_before" "$anchors_after" "$TAILSCALE_ANCHOR_NAME"; then
    postcheck_failed=1
  fi

  if [[ "$preserve_mullvad" -eq 1 ]]; then
    mullvad_rules_after="$(pf_anchor_rules "$MULLVAD_ANCHOR_NAME" 2>/dev/null || true)"
    if ! pf_anchor_is_attached "$MULLVAD_ANCHOR_NAME" "$anchors_after" || [[ "$mullvad_rules_after" != "$mullvad_rules_before" ]]; then
      postcheck_failed=1
    fi
  fi

  if [[ "$postcheck_failed" -eq 1 ]]; then
    echo "A protected PF attachment or Mullvad's rules changed during reload; restoring the previous configuration." >&2
    if ! restore_pf_conf_and_runtime "$backup_path" "$anchors_before" "$preserve_mullvad" "$mullvad_rules_before"; then
      "$RM_BIN" -f "$runtime_conf"
      echo "CRITICAL: failed to restore the previous PF runtime ruleset. Disconnect this Mac from untrusted networks and reapply Mullvad immediately." >&2
      return 1
    fi
    "$RM_BIN" -f "$runtime_conf"
    return 1
  fi

  "$RM_BIN" -f "$runtime_conf"
  echo "$backup_path"
}

flush_runtime_anchor() {
  "$PFCTL_BIN" -a "$TAILSCALE_ANCHOR_NAME" -F rules >/dev/null 2>&1
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
    <string>${TAILSCALED_STDOUT_PATH}</string>
    <key>StandardErrorPath</key>
    <string>${TAILSCALED_STDERR_PATH}</string>
</dict>
</plist>
EOF
}

validate_plist() {
  local file="$1"

  "$PLUTIL_BIN" -lint "$file" >/dev/null 2>&1
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
    <string>${PF_WATCHER_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${PF_WATCHER_LOG}</string>
</dict>
</plist>
EOF
}

plist_managed_by_repo() {
  local file="$1"

  has_exact_line "$file" "$MANAGED_PLIST_COMMENT"
}

legacy_pf_watcher_plist_managed_by_repo() {
  local file="$1"

  [[ -f "$file" ]] || return 1
  grep -Fq "<string>${PF_WATCHER_LABEL}</string>" "$file" && \
    grep -Fq "<string>${PF_WATCHER_SCRIPT}</string>" "$file"
}

pf_watcher_payload_managed_by_repo() {
  [[ -f "$PF_WATCHER_MARKER_FILE" ]] && has_exact_line "$PF_WATCHER_MARKER_FILE" "$PF_WATCHER_MARKER_CONTENT"
}

legacy_pf_watcher_payload_managed_by_repo() {
  local path

  [[ -f "$PF_WATCHER_INSTALL_DIR/refresh-anchor.sh" ]] || return 1
  [[ -f "$PF_WATCHER_INSTALL_DIR/lib/common.sh" ]] || return 1
  [[ -f "$PF_WATCHER_INSTALL_DIR/etc/pf.anchors/tailscale" ]] || return 1

  while IFS= read -r path; do
    case "$path" in
      "$PF_WATCHER_INSTALL_DIR/refresh-anchor.sh"|\
      "$PF_WATCHER_INSTALL_DIR/lib"|\
      "$PF_WATCHER_INSTALL_DIR/lib/common.sh"|\
      "$PF_WATCHER_INSTALL_DIR/etc"|\
      "$PF_WATCHER_INSTALL_DIR/etc/pf.anchors"|\
      "$PF_WATCHER_INSTALL_DIR/etc/pf.anchors/tailscale")
        ;;
      *)
        return 1
        ;;
    esac
  done < <("$FIND_BIN" "$PF_WATCHER_INSTALL_DIR" -mindepth 1 -maxdepth 4 -print 2>/dev/null)
}

launchd_service_target() {
  echo "system/$1"
}

launchd_loaded() {
  "$LAUNCHCTL_BIN" print "system/$1" >/dev/null 2>&1
}

bootout_launchd() {
  local label="$1"

  if launchd_loaded "$label"; then
    "$LAUNCHCTL_BIN" bootout "system/$label" >/dev/null 2>&1
  fi
}

bootstrap_launchd() {
  local plist="$1"
  local label="$2"

  "$LAUNCHCTL_BIN" bootstrap system "$plist" >/dev/null 2>&1
  "$LAUNCHCTL_BIN" kickstart -k "system/$label" >/dev/null 2>&1
}

launchdaemon_service_target() {
  launchd_service_target "$TAILSCALED_DAEMON_LABEL"
}

launchdaemon_loaded() {
  launchd_loaded "$TAILSCALED_DAEMON_LABEL"
}

bootout_launchdaemon() {
  bootout_launchd "$TAILSCALED_DAEMON_LABEL"
}

bootstrap_launchdaemon() {
  bootstrap_launchd "$TAILSCALED_DAEMON_PLIST" "$TAILSCALED_DAEMON_LABEL"
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

  "$DSCACHEUTIL_BIN" -flushcache >/dev/null 2>&1 || rc=1
  "$KILLALL_BIN" -HUP mDNSResponder >/dev/null 2>&1 || rc=1

  return "$rc"
}
