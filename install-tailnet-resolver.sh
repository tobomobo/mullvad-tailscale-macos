#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

TAILNET_DOMAIN=""

usage() {
  cat <<EOF
Usage: sudo bash install-tailnet-resolver.sh --tailnet-domain your-tailnet.ts.net

Installs or updates a macOS /etc/resolver override for a tailnet domain. This is
optional and only needed when Mullvad's DNS path prevents normal macOS apps from
resolving MagicDNS names reliably.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tailnet-domain)
      [[ $# -ge 2 ]] || die "--tailnet-domain requires a value."
      TAILNET_DOMAIN="$2"
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
validate_tailnet_domain "$TAILNET_DOMAIN" || die "Invalid --tailnet-domain value: $TAILNET_DOMAIN"

resolver_file="$(resolver_file_for_domain "$TAILNET_DOMAIN")"
tmp_resolver="$(make_temp_file tailnet-resolver)"
trap 'rm -f "$tmp_resolver"' EXIT

write_tailnet_resolver_file "$tmp_resolver" "$TAILNET_DOMAIN"
resolver_file_managed_by_repo "$tmp_resolver" || die "Generated resolver file is invalid."
resolver_file_has_nameserver "$tmp_resolver" || die "Generated resolver file is invalid."

echo "Ensuring $RESOLVER_DIR exists ..."
"$MKDIR_BIN" -p "$RESOLVER_DIR"

if [[ -f "$resolver_file" ]]; then
  if ! resolver_file_managed_by_repo "$resolver_file"; then
    die "Resolver file $resolver_file already exists and is not managed by this repo. Inspect it manually before replacing it."
  fi

  if file_differs "$resolver_file" "$tmp_resolver"; then
    backup_path="$(backup_file "$resolver_file")"
    echo "Backed up $resolver_file to $backup_path"

    echo "Installing resolver override to $resolver_file ..."
    install_root_owned_file "$tmp_resolver" "$resolver_file" 644
  else
    echo "Resolver override already matches $TAILNET_DOMAIN -> $TAILSCALE_MAGICDNS_SERVER"
  fi
else
  echo "Installing resolver override to $resolver_file ..."
  install_root_owned_file "$tmp_resolver" "$resolver_file" 644
fi

echo "Flushing macOS DNS caches ..."
flush_dns_caches || die "Failed to flush macOS DNS caches."

echo ""
echo "Done. ${TAILNET_DOMAIN} now resolves through ${TAILSCALE_MAGICDNS_SERVER} for macOS apps."
