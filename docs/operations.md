# Operations

[Back to the quick start](../README.md) · [Troubleshooting](troubleshooting.md) · [Security model](../SECURITY.md)

This page covers component-level operation. Most users only need the default lifecycle below.

## Default Lifecycle

Install or repair everything required by the PF workaround:

```bash
sudo bash install.sh
```

The command:

1. detects the `utun` interface carrying Tailscale's own address;
2. renders and validates the four interface-scoped PF rules;
3. installs the exact managed block in `/etc/pf.conf`;
4. reloads PF through the Mullvad-preserving transaction when needed;
5. verifies the live rules and anchor order; and
6. installs or updates the automatic PF watcher.

Check the resulting configuration and live state:

```bash
sudo bash verify.sh
```

Remove the default installation:

```bash
sudo bash uninstall.sh
```

`uninstall.sh` removes the watcher, the managed `/etc/pf.conf` block, and the installed Tailscale anchor. It does not remove separately installed optional components.

## Script Reference

| Script | Purpose |
| --- | --- |
| `install.sh` | Default install and repair: PF policy plus watcher |
| `uninstall.sh` | Remove the default PF policy and watcher |
| `verify.sh` | Check configuration, ownership, service state, and optional live connectivity |
| `refresh-anchor.sh` | Re-detect the interface and repair the live PF attachment now |
| `install-pf-watcher.sh` | Install or repair only the automatic watcher |
| `uninstall-pf-watcher.sh` | Remove only the automatic watcher |
| `install-tailscaled-daemon.sh` | Optionally manage a detected `tailscaled` binary as a system LaunchDaemon |
| `uninstall-tailscaled-daemon.sh` | Remove only the repo-managed `tailscaled` LaunchDaemon |
| `install-tailnet-resolver.sh` | Optionally route one `*.ts.net` tailnet domain to MagicDNS |
| `uninstall-tailnet-resolver.sh` | Remove one repo-managed tailnet resolver override |

Run `bash <script> --help` for its exact options.

## Interface Override

Automatic detection matches the output of `tailscale ip` to the current macOS interfaces. If Tailscale cannot be started before installation, you can supply a known interface:

```bash
sudo bash install.sh --interface utun3
```

Do not make that a permanent assumption. The `utun` number can change, and the watcher normally handles that by detecting the current interface again.

## Automatic PF Watcher

`install.sh` installs the watcher automatically. The watcher:

- checks about every two minutes;
- also runs when macOS rewrites resolver files;
- updates the anchor if Tailscale moved to another `utun`; and
- restores the main-ruleset call if another PF reload detached it.

It is a periodic launchd job, not a continuously running process. `state = not running` is normal between successful runs when the job is loaded and its last exit code is `0`.

Repair only this component:

```bash
sudo bash install-pf-watcher.sh
```

Run it immediately with interactive output:

```bash
sudo bash refresh-anchor.sh
```

Remove only the watcher:

```bash
sudo bash uninstall-pf-watcher.sh
```

The watcher keeps routine output in `/dev/null` to avoid accumulating tailnet metadata in log files.

## Optional `tailscaled` LaunchDaemon

You do not need this component if Tailscale is already managed by its app, Homebrew services, or another known mechanism.

To have a detected CLI-installed `tailscaled` binary start at boot before user login:

```bash
sudo bash install-tailscaled-daemon.sh
tailscale up
```

The installer copies the executable to a root-owned protected path, installs a marked LaunchDaemon plist, discards routine output, and requires launchd to confirm that the job loaded.

If an unmarked plist already exists, the script refuses to replace it. Inspect the existing service first. Adopt it only when you know it is safe:

```bash
sudo bash install-tailscaled-daemon.sh --replace-existing
```

Remove only the repo-managed service:

```bash
sudo bash uninstall-tailscaled-daemon.sh
```

The uninstaller refuses to remove an unmarked service or executable.

## Optional Tailnet Resolver

Install this only when direct MagicDNS works but normal macOS applications cannot resolve names in your tailnet domain:

```bash
sudo bash install-tailnet-resolver.sh \
  --tailnet-domain your-tailnet.ts.net
```

It creates `/etc/resolver/your-tailnet.ts.net` with Tailscale's `100.100.100.100` nameserver. The override is domain-scoped and keeps peer address assignment dynamic; it is preferable to per-host `/etc/hosts` entries.

Verify the optional component:

```bash
sudo bash verify.sh \
  --tailnet-domain your-tailnet.ts.net \
  --magicdns-name <peer>.your-tailnet.ts.net
```

Remove it:

```bash
sudo bash uninstall-tailnet-resolver.sh \
  --tailnet-domain your-tailnet.ts.net
```

See [Troubleshooting](troubleshooting.md#magicdns-works-directly-but-macos-apps-fail) before installing it.

## Active Verification

The default verifier checks configuration and local service state. Add a peer and hostname to test more of the live path:

```bash
sudo bash verify.sh \
  --tailnet-target <peer> \
  --magicdns-name <peer>.your-tailnet.ts.net
```

With a target, the verifier distinguishes:

- tailnet reachability via TSMP; and
- direct DISCO path establishment versus DERP relay fallback.

A reachable peer using DERP is reported as working with a warning, not as a failed PF installation.

## After macOS, Mullvad, or Tailscale Updates

Run:

```bash
sudo bash install.sh
sudo bash verify.sh
```

This is the supported repair path if an update removed the managed `/etc/pf.conf` lines, changed the active interface, or detached the runtime anchor call.

The scripts create timestamped backups before replacing managed configuration. They also refuse to overwrite privileged anchor, plist, watcher-payload, or resolver files that they cannot recognize as repo-managed.

## PF Reloads

The default operations sometimes need a full PF reload. The transaction checks protected main-ruleset calls, snapshots Mullvad's active rules, applies the staged configuration, verifies the result, and restores the previous file and runtime state on failure.

This protects reloads performed by this repository. It cannot make unrelated third-party `pfctl -f` commands safe. See [Security model](../SECURITY.md#full-pf-transactions-preserve-mullvad) for the exact boundary.
