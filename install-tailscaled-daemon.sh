#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo bash install-tailscaled-daemon.sh

Installs or updates a system LaunchDaemon for tailscaled using the detected
tailscaled binary path and the modern launchctl bootstrap workflow.
EOF
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
fi

require_root

tailscaled_bin="$(detect_tailscaled_binary)" || die "Cannot find tailscaled in PATH. Install Tailscale first or set TAILSCALED_BIN."
tmp_plist="$(make_temp_file tailscaled-launchdaemon)"
trap 'rm -f "$tmp_plist"' EXIT

write_launchdaemon_plist "$tmp_plist" "$tailscaled_bin"
validate_plist "$tmp_plist" || die "Generated LaunchDaemon plist is invalid."

echo "Installing LaunchDaemon to $TAILSCALED_DAEMON_PLIST ..."
install_root_owned_file "$tmp_plist" "$TAILSCALED_DAEMON_PLIST"

echo "Bootstrapping $TAILSCALED_DAEMON_LABEL ..."
bootout_launchdaemon || true
bootstrap_launchdaemon || die "Failed to bootstrap $TAILSCALED_DAEMON_LABEL."

echo ""
echo "Done. tailscaled will now start at boot via launchd."
echo "Authenticate with: tailscale up"
