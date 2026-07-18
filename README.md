# Mullvad + Tailscale on macOS

Keep the standalone Mullvad app and standalone Tailscale working together while Mullvad's PF-based kill switch is enabled.

> **Default:** once Mullvad and Tailscale are running, install the fix with `sudo bash install.sh` and check it with `sudo bash verify.sh`.

## What This Repo Does

Mullvad can block Tailscale traffic on macOS. This repo installs a narrow PF exception for Tailscale's IPv4 and IPv6 tailnet ranges on Tailscale's current `utun` interface.

The default installer also adds a watcher that repairs the interface binding after network or service changes. It does not disable Mullvad's kill switch or allow general traffic around the VPN.

Use this repo when you want:

- the normal Mullvad macOS app with lockdown mode enabled;
- the normal Tailscale client; and
- both to remain usable at the same time.

This is not needed for Tailscale's Mullvad exit-node add-on.

## Install

First, make sure both apps are installed and Tailscale is connected. Mullvad must use its default DNS because its content-blocker DNS addresses overlap Tailscale's address range.

```bash
mullvad lockdown-mode set on
mullvad dns set default
mullvad connect
tailscale up
```

Then run the one default install command:

```bash
sudo bash install.sh
```

It installs or repairs the PF policy and its automatic watcher. Re-running it is safe and is the normal repair path.

## Verify

```bash
sudo bash verify.sh
```

A healthy installation ends with `0 failed`. Warnings about skipped active checks are expected unless you provide a peer or MagicDNS name.

For an end-to-end check:

```bash
sudo bash verify.sh \
  --tailnet-target <peer> \
  --magicdns-name <peer>.your-tailnet.ts.net
```

## Optional Components

The default path needs only `install.sh`. Use the other scripts when you want a specific component or repair:

| Need | Command |
| --- | --- |
| Keep a CLI-installed `tailscaled` running at boot | `sudo bash install-tailscaled-daemon.sh` |
| Override failed interface detection | `sudo bash install.sh --interface utun3` |
| Repair only the automatic watcher | `sudo bash install-pf-watcher.sh` |
| Refresh the active interface now | `sudo bash refresh-anchor.sh` |
| Fix MagicDNS for normal macOS apps | `sudo bash install-tailnet-resolver.sh --tailnet-domain your-tailnet.ts.net` |

Each install script has a matching uninstall script. The component scripts refuse to replace unrecognized privileged files unless an explicit adoption option is available.

## If Something Fails

Start with `sudo bash verify.sh`, then use the matching guide:

| Symptom | Next step |
| --- | --- |
| Tailscale interface cannot be detected | Start Tailscale, then rerun `sudo bash install.sh` |
| PF anchor is missing, detached, or in the wrong order | Rerun `sudo bash install.sh` |
| Watcher shows `state = not running` | Check whether it is loaded and last exited with code `0`; it is a periodic job, not a continuously running daemon |
| `tailscale ping` works but apps cannot resolve `*.ts.net` | Follow the [DNS troubleshooting guide](docs/troubleshooting.md#magicdns-works-directly-but-macos-apps-fail) |
| A peer is reachable only through DERP | Follow the [direct-connection checks](docs/troubleshooting.md#the-peer-is-reachable-but-uses-derp) |
| Mullvad content blockers stop DNS | Use Mullvad's default DNS; see [the address-range collision](docs/troubleshooting.md#mullvad-content-blockers-break-dns) |

## Uninstall

```bash
sudo bash uninstall.sh
```

This removes the watcher and the managed PF policy. Optional components such as the repo-managed `tailscaled` daemon or tailnet resolver have their own uninstall scripts.

## Documentation

- [Operations](docs/operations.md) — every script, optional components, maintenance, and removal
- [Troubleshooting](docs/troubleshooting.md) — PF, launchd, MagicDNS, content blockers, and DERP
- [Security model](SECURITY.md) — trust boundaries, rollback behavior, limitations, and product tradeoffs
- `bash <script> --help` — exact command-line options

## Security Boundary

The exception remains pinned to Tailscale's detected interface and only covers `100.64.0.0/10` and `fd7a:115c:a1e0::/48`. The scripts validate staged changes, preserve Mullvad's active anchor during necessary PF reloads, and roll back failed updates.

That is a constrained compatibility policy, not proof against every leak or future macOS, Mullvad, or Tailscale change. Read [SECURITY.md](SECURITY.md) before relying on it for a high-risk threat model.

## License

[Unlicense](LICENSE) — public domain.
