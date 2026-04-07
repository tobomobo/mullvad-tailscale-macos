# Running Mullvad VPN and Tailscale simultaneously on macOS

Mullvad's PF-based kill switch can block Tailscale traffic on macOS. This repo fixes that by installing a persistent PF anchor that explicitly allows Tailscale's tailnet ranges on Tailscale's active `utun` interface before Mullvad's blocking rules evaluate the packet.

This repo is for the "standalone Mullvad app + standalone Tailscale" setup. It is not a wrapper around Tailscale's Mullvad exit-node add-on.

For the deeper security model, DNS/leak discussion, and product tradeoffs, see [SECURITY.md](SECURITY.md).

## Who This Is For

Use this repo if all of the following are true:

- you want to keep using the normal Mullvad app on macOS
- you also want Tailscale running at the same time
- you want to keep Mullvad app features such as DAITA or multihop available
- you do not want to replace your setup with Tailscale-managed Mullvad exit nodes

## Quick Start

Install both tools:

```bash
brew install mullvad-vpn
brew install tailscale
```

If you want `tailscaled` to start at boot regardless of user login:

```bash
sudo bash install-tailscaled-daemon.sh
tailscale up
```

If you already manage `tailscaled` some other way, keep doing that. The PF fix only needs Tailscale to be running.

Connect Mullvad and enable the settings this repo assumes:

```bash
mullvad account login <ACCOUNT_NUMBER>
mullvad relay set location <COUNTRY> <CITY>   # e.g. ch zrh
mullvad lockdown-mode set on
mullvad dns set default
mullvad connect
```

Install the PF fix:

```bash
sudo bash install.sh
```

If Tailscale is not running yet and the script cannot auto-detect its active interface:

```bash
sudo bash install.sh --interface utun3
```

Verify:

```bash
sudo bash verify.sh
```

For active end-to-end checks:

```bash
sudo bash verify.sh --tailnet-target <peer> --magicdns-name <peer>.ts.net
```

## What The Scripts Do

- `install.sh`
  Detects Tailscale's active `utun` interface, renders the anchor, validates staged PF changes, and applies rollback-safe updates to `pf.conf`.
- `uninstall.sh`
  Removes the managed anchor block, reloads PF when needed, and deletes the installed anchor file.
- `install-tailscaled-daemon.sh`
  Installs a system LaunchDaemon for `tailscaled` using `launchctl bootstrap`.
- `uninstall-tailscaled-daemon.sh`
  Removes the repo-managed `tailscaled` LaunchDaemon.
- `verify.sh`
  Checks exact `pf.conf` lines, interface targeting, PF runtime state, daemon state, and optional active connectivity checks.

## Why Not Just Use The Tailscale Mullvad Add-On?

Because it solves a different problem.

As of April 7, 2026, Tailscale documents [Mullvad exit nodes](https://tailscale.com/kb/1258/mullvad-exit-nodes/) as a beta feature that requires purchasing a separate add-on through the Tailscale admin console. That path gives you Mullvad-backed exit nodes inside Tailscale, which is useful if you want tailnet-managed exit routing.

This repo exists for people who intentionally want to keep the standalone Mullvad app:

- you may already have a Mullvad subscription and want to keep using it
- Tailscale's own Mullvad docs note that Tailscale manages Mullvad accounts on the user's behalf and knows which Mullvad accounts belong to which Tailscale users, which is a different privacy model from using Mullvad directly
- [Mullvad](https://mullvad.net/en/pricing) supports privacy-friendly payment methods such as cash and Monero, and Mullvad also announced support for [Bitcoin via Lightning](https://mullvad.net/en/blog/lightning-payments); by contrast, Tailscale's documented [self-serve paid checkout](https://tailscale.com/kb/1251/pricing-faq) uses a credit card, though Tailscale also documents other billing paths such as invoicing for some plans
- the [Mullvad app](https://mullvad.net/en/help/using-mullvad-vpn-app/) offers app-level features such as [DAITA](https://mullvad.net/en/blog/defense-against-ai-guided-traffic-analysis-daita-now-available-on-linux-and-macos) and multihop; Tailscale's Mullvad integration is an exit-node product, not the Mullvad desktop app

So the short version is:

- if you want Tailscale-managed Mullvad exit nodes, use the Tailscale add-on
- if you want the normal Mullvad app and the normal Tailscale client to coexist on macOS, use this repo

## Verification

Quick config check:

```bash
sudo bash verify.sh
```

Useful manual checks:

```bash
sudo pfctl -a tailscale -sr
sudo pfctl -sr | grep 'anchor "tailscale"'
tailscale ping <hostname>
dig +short @100.100.100.100 <hostname>.ts.net
curl https://am.i.mullvad.net/connected
```

## Same Wi-Fi, MagicDNS, and Direct Connections

If two devices are on the same Wi-Fi:

- connecting by LAN IP such as `192.168.x.x` is usually already allowed by Mullvad's local-network rules
- connecting by MagicDNS (`*.ts.net`) or a Tailscale IP (`100.x` / `fd7a:`) still uses Tailscale addressing, so this PF anchor is still needed

MagicDNS only resolves the name to the peer's Tailscale address. It does not decide whether Tailscale will use a direct local peer path or a DERP relay.

So a result like this:

- `dig @100.100.100.100` returns the correct `100.x` address
- `tailscale ping` succeeds
- Mullvad still reports connected
- but `tailscale ping` says `via DERP`

means the PF fix is working and MagicDNS is working. The remaining issue is direct-path establishment between the two Tailscale peers, not the firewall exception or DNS resolution.

## Maintenance

After major macOS updates, confirm that both managed lines still exist in `/etc/pf.conf`:

```bash
grep -Fx 'anchor "tailscale"' /etc/pf.conf
grep -Fx 'load anchor "tailscale" from "/etc/pf.anchors/tailscale"' /etc/pf.conf
```

If either line is missing:

```bash
sudo bash install.sh
```

If you want the full rationale for why this approach should be safe, where it can still fail, and how it compares to the Tailscale add-on, read [SECURITY.md](SECURITY.md).

## File Overview

| File | Purpose |
|------|---------|
| `install.sh` | Installs the PF anchor with interface detection and rollback-safe PF updates |
| `uninstall.sh` | Removes the managed PF anchor block and installed anchor file |
| `install-tailscaled-daemon.sh` | Installs a system LaunchDaemon for `tailscaled` |
| `uninstall-tailscaled-daemon.sh` | Removes the repo-managed `tailscaled` LaunchDaemon |
| `etc/pf.anchors/tailscale` | Template used to render interface-specific PF anchor rules |
| `lib/common.sh` | Shared helpers for PF and LaunchDaemon management |
| `verify.sh` | Verifies configuration and optional active checks |
| `tests/run.sh` | Stubbed smoke tests for install, uninstall, verify, rollback, and LaunchDaemon management |
| `SECURITY.md` | Security model, tradeoffs, and product comparison notes |

## License

[Unlicense](LICENSE) - public domain.
