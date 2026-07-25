# Operations

[Back to the quick start](../README.md) · [Troubleshooting](troubleshooting.md) · [Security model](../SECURITY.md)

This page covers component-level operation. Most users only need the default lifecycle below.

## Default Lifecycle

`sudo bash install.sh` -> `sudo bash verify.sh` -> `sudo bash uninstall.sh`, as
described in the [quick start](../README.md#install). Beyond what the README
covers, `install.sh` performs these steps in order:

1. detects the `utun` interface carrying Tailscale's own address;
2. renders and validates the four interface-scoped PF rules;
3. installs the exact managed block in `/etc/pf.conf`;
4. reloads PF through the Mullvad-preserving transaction when needed;
5. verifies the live rules and anchor order; and
6. installs or updates the automatic PF watcher.

`uninstall.sh` removes the watcher, the managed `/etc/pf.conf` block, and the
installed Tailscale anchor. It does not remove separately installed optional
components; each has its own uninstall script.

Run `bash <script> --help` for any script's exact options.

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

Passing `--tailnet-target` and `--magicdns-name` (see the
[README](../README.md#verify)) makes the verifier distinguish:

- tailnet reachability via TSMP; and
- direct DISCO path establishment versus DERP relay fallback.

A reachable peer using DERP is reported as working with a warning, not as a
failed PF installation.

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
