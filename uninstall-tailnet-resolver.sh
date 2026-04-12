#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

TAILNET_DOMAIN=""

usage() {
  cat <<EOF
Usage: sudo bash uninstall-tailnet-resolver.sh --tailnet-domain your-tailnet.ts.net

Removes the macOS /etc/resolver override installed by install-tailnet-resolver.sh.
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

if [[ -f "$resolver_file" ]]; then
  resolver_file_managed_by_repo "$resolver_file" || die "Resolver override $resolver_file exists but is not managed by this repo. Refusing to remove it."
  backup_path="$(backup_file "$resolver_file")"
  echo "Backed up $resolver_file to $backup_path"
  echo "Removing resolver override $resolver_file ..."
  "$RM_BIN" "$resolver_file"
else
  echo "Resolver override $resolver_file not found, skipping."
fi

echo "Flushing macOS DNS caches ..."
flush_dns_caches || die "Failed to flush macOS DNS caches."

echo ""
echo "Done. ${TAILNET_DOMAIN} will no longer be forced through a resolver override."
