#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo bash install-tailscaled-daemon.sh [--replace-existing]

Installs or updates a system LaunchDaemon for tailscaled using the detected
tailscaled binary path and the modern launchctl bootstrap workflow. The daemon
runs a root-owned copy of the binary. Use --replace-existing only after checking
that an unmarked plist or managed-binary path is safe to adopt.
EOF
}

REPLACE_EXISTING=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --replace-existing)
      REPLACE_EXISTING=1
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

require_root

ADOPTING_UNMARKED=0

if [[ -f "$TAILSCALED_DAEMON_PLIST" ]] && ! plist_managed_by_repo "$TAILSCALED_DAEMON_PLIST" && [[ "$REPLACE_EXISTING" -ne 1 ]]; then
  die "$TAILSCALED_DAEMON_PLIST exists but is not marked as managed by this repo. Refusing to overwrite it; inspect it and rerun with --replace-existing to adopt it."
fi
if [[ -f "$TAILSCALED_DAEMON_PLIST" ]] && ! plist_managed_by_repo "$TAILSCALED_DAEMON_PLIST"; then
  ADOPTING_UNMARKED=1
fi

if [[ -e "$TAILSCALED_MANAGED_BIN" && ! -f "$TAILSCALED_DAEMON_PLIST" && "$REPLACE_EXISTING" -ne 1 ]]; then
  die "$TAILSCALED_MANAGED_BIN already exists without a repo-managed plist. Refusing to overwrite it."
fi
if [[ -e "$TAILSCALED_MANAGED_BIN" && ! -f "$TAILSCALED_MANAGED_BIN" ]]; then
  die "$TAILSCALED_MANAGED_BIN exists but is not a regular file. Refusing to use it as a privileged executable."
fi

tailscaled_bin="$(detect_tailscaled_binary)" || die "Cannot find tailscaled in PATH. Install Tailscale first or set TAILSCALED_BIN."
[[ -f "$tailscaled_bin" && -x "$tailscaled_bin" ]] || die "Detected tailscaled binary is not a regular executable file: $tailscaled_bin"
tmp_plist="$(make_temp_file tailscaled-launchdaemon)"
trap 'rm -f "$tmp_plist"' EXIT

install_root_owned_dir "${TAILSCALED_MANAGED_BIN%/*}"
if [[ "$tailscaled_bin" != "$TAILSCALED_MANAGED_BIN" ]] || file_differs "$tailscaled_bin" "$TAILSCALED_MANAGED_BIN"; then
  echo "Installing root-owned tailscaled binary to $TAILSCALED_MANAGED_BIN ..."
  install_root_owned_file "$tailscaled_bin" "$TAILSCALED_MANAGED_BIN" 755
fi
"$CHOWN_BIN" root:wheel "$TAILSCALED_MANAGED_BIN"
"$CHMOD_BIN" 755 "$TAILSCALED_MANAGED_BIN"

write_launchdaemon_plist "$tmp_plist" "$TAILSCALED_MANAGED_BIN"
validate_plist "$tmp_plist" || die "Generated LaunchDaemon plist is invalid."

echo "Installing LaunchDaemon to $TAILSCALED_DAEMON_PLIST ..."
install_root_owned_file "$tmp_plist" "$TAILSCALED_DAEMON_PLIST"

echo "Bootstrapping $TAILSCALED_DAEMON_LABEL ..."
bootout_launchdaemon || true
bootstrap_launchdaemon || die "Failed to bootstrap $TAILSCALED_DAEMON_LABEL."

if [[ "$ADOPTING_UNMARKED" -eq 1 ]]; then
  for legacy_log in "$LEGACY_TAILSCALED_STDOUT_PATH" "$LEGACY_TAILSCALED_STDERR_PATH"; do
    if [[ -f "$legacy_log" ]]; then
      "$CHOWN_BIN" root:wheel "$legacy_log"
      "$CHMOD_BIN" 600 "$legacy_log"
    fi
  done
fi

echo ""
echo "Done. tailscaled will now start at boot via launchd."
echo "Verified loaded service: $(launchdaemon_service_target)"
echo "Standard output and error are discarded by default to avoid persistent tailnet metadata logs."
echo "Authenticate with: tailscale up"
