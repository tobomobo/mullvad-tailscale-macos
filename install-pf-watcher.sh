#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo bash install-pf-watcher.sh [--replace-existing]

Installs a LaunchDaemon that re-detects Tailscale's active utun interface and
reattaches the PF anchor if it moved. It re-checks periodically (about every
two minutes, which is what guarantees recovery) and also when the DNS resolver
configuration changes. This keeps the anchor's interface binding correct across
Tailscale restarts without widening the PF exception to all interfaces.

Run install.sh first; the watcher only reattaches the anchor, it does not add
the anchor lines to /etc/pf.conf. If another PF reload detached that existing
call, the watcher restores it through the rollback-safe reload path. Use
--replace-existing only after checking an unrecognized existing plist or
payload directory.
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

for required in refresh-anchor.sh lib/common.sh etc/pf.anchors/tailscale; do
  [[ -f "$SCRIPT_DIR/$required" ]] || die "Missing required file: $SCRIPT_DIR/$required"
done

if [[ "$REPLACE_EXISTING" -ne 1 ]]; then
  if [[ -f "$PF_WATCHER_PLIST" ]] && ! plist_managed_by_repo "$PF_WATCHER_PLIST"; then
    die "$PF_WATCHER_PLIST exists but is not recognized as repo-managed. Refusing to overwrite it; inspect it and rerun with --replace-existing to adopt it."
  fi
  if [[ -d "$PF_WATCHER_INSTALL_DIR" ]] && ! pf_watcher_payload_managed_by_repo; then
    die "$PF_WATCHER_INSTALL_DIR exists but is not recognized as a repo-managed payload. Refusing to overwrite it; inspect it and rerun with --replace-existing to adopt it."
  fi
fi

echo "Installing watcher payload to $PF_WATCHER_INSTALL_DIR ..."
# root runs refresh-anchor.sh and sources lib/common.sh from this directory on a
# timer, so lock it down to root:wheel even if the parent (or a pre-existing
# directory) had looser permissions, rather than relying on the umask.
install_root_owned_dir "$PF_WATCHER_INSTALL_DIR"
install_root_owned_dir "$PF_WATCHER_INSTALL_DIR/lib"
install_root_owned_dir "$PF_WATCHER_INSTALL_DIR/etc"
install_root_owned_dir "$PF_WATCHER_INSTALL_DIR/etc/pf.anchors"
install_root_owned_file "$SCRIPT_DIR/refresh-anchor.sh" "$PF_WATCHER_INSTALL_DIR/refresh-anchor.sh" 755
install_root_owned_file "$SCRIPT_DIR/lib/common.sh" "$PF_WATCHER_INSTALL_DIR/lib/common.sh" 644
install_root_owned_file "$SCRIPT_DIR/etc/pf.anchors/tailscale" "$PF_WATCHER_INSTALL_DIR/etc/pf.anchors/tailscale" 644
tmp_marker="$(make_temp_file pf-watcher-marker)"
printf '%s\n' "$PF_WATCHER_MARKER_CONTENT" > "$tmp_marker"
install_root_owned_file "$tmp_marker" "$PF_WATCHER_MARKER_FILE" 644

tmp_plist="$(make_temp_file pf-watcher-launchdaemon)"
trap 'rm -f "$tmp_plist" "$tmp_marker"' EXIT

write_pf_watcher_plist "$tmp_plist" "$PF_WATCHER_SCRIPT"
validate_plist "$tmp_plist" || die "Generated LaunchDaemon plist is invalid."

echo "Installing LaunchDaemon to $PF_WATCHER_PLIST ..."
install_root_owned_file "$tmp_plist" "$PF_WATCHER_PLIST"

echo "Bootstrapping $PF_WATCHER_LABEL ..."
bootout_launchd "$PF_WATCHER_LABEL" || true
bootstrap_launchd "$PF_WATCHER_PLIST" "$PF_WATCHER_LABEL" || die "Failed to bootstrap $PF_WATCHER_LABEL."

echo ""
echo "Done. The pf-watcher will reattach the anchor to Tailscale's current interface"
echo "(it re-checks about every two minutes and on DNS resolver changes)."
echo "Verified loaded service: system/$PF_WATCHER_LABEL"
echo "Routine output is discarded to avoid persistent tailnet metadata logs."
