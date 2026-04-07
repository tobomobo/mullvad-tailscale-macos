# Running Mullvad VPN and Tailscale simultaneously on macOS

Mullvad's kill switch silently drops Tailscale traffic on macOS. This repo contains a fix: a persistent PF anchor that whitelists Tailscale's CGNAT range before Mullvad's firewall rules evaluate it.

## Prerequisites

Both tools are installed via Homebrew and managed from the CLI — no GUI apps.

```bash
brew install mullvad-vpn
brew install tailscale
```

### Mullvad

Mullvad's cask (`mullvad-vpn`) installs a system daemon that starts automatically at boot — no additional configuration needed for autostart.

```bash
mullvad account login <ACCOUNT_NUMBER>
mullvad relay set location <COUNTRY> <CITY>   # e.g. ch zrh
mullvad connect
```

Mullvad settings this fix assumes:

```bash
mullvad lockdown-mode set on        # "Always require VPN" — enables the PF kill switch
mullvad dns set default              # Use Mullvad's DNS (no custom DNS that could leak)
```

### Tailscale

Homebrew's `tailscale` formula only installs the binaries. If you want `tailscaled` to run at boot regardless of user login, this repo now includes a LaunchDaemon installer that detects the current `tailscaled` binary path and uses the modern `launchctl bootstrap` workflow.

**Install the LaunchDaemon:**

```bash
sudo bash install-tailscaled-daemon.sh
```

**Authenticate the node:**

```bash
tailscale up
```

This runs `tailscaled` as root via launchd with `RunAtLoad` and `KeepAlive`. The generated LaunchDaemon writes logs to `/var/log/tailscaled.log` and `/var/log/tailscaled.err`.

If you already manage `tailscaled` some other way, you can skip this step. The PF anchor fix only requires that Tailscale be running and authenticated.

Why not `brew services start tailscale`? Brew services installs a LaunchAgent under the current user, which only runs when that user is logged in. A LaunchDaemon in `/Library/LaunchDaemons/` runs at boot regardless of who, if anyone, is logged in.

**Optional — set an operator user:**

```bash
sudo tailscale set --operator=<USERNAME>
```

This lets a non-admin user run `tailscale status`, `tailscale ping`, and other Tailscale commands without `sudo`.

With both VPNs active, Tailscale traffic is blocked until the PF anchor below is installed.

## The problem

Mullvad implements its kill switch using macOS PF (Packet Filter). When connected (or when "Always require VPN" is enabled), Mullvad dynamically injects PF rules that:

1. **Block all traffic** by default.
2. **Whitelist RFC1918 private ranges** — `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` — so LAN access continues to work.
3. **Allow traffic through the Mullvad tunnel interface** (typically `utun9`) to Mullvad's servers.

Tailscale uses the **CGNAT range** `100.64.0.0/10` for its overlay network. This range is *not* RFC1918. It falls outside every range Mullvad whitelists, so Mullvad's PF rules silently drop all Tailscale traffic — including Magic DNS (`100.100.100.100`, which is inside `100.64.0.0/10`).

You'll see this as:

- `tailscale ping <host>` timing out
- SSH to Tailscale hosts hanging
- Magic DNS not resolving `*.ts.net` names
- `tailscale status` showing peers as active but unreachable

## Why split tunneling doesn't fix this

Mullvad's split tunneling on macOS works by applying socket-level filters (Network Extension content filters) to exempt specific apps from the tunnel. However, `tailscaled` runs as **root** (it's a system daemon managed by launchd). macOS does not allow Network Extension content filters to apply to processes running as root — this is a platform limitation, not a Mullvad bug.

So even if you add Tailscale to Mullvad's split tunneling list, it has no effect. The `tailscaled` process remains subject to PF rules, and its traffic gets dropped.

## The fix

We add a **PF anchor** — a named sub-ruleset — that explicitly passes Tailscale traffic on Tailscale's active `utun` interface before Mullvad's rules get a chance to drop it.

### What is a PF anchor?

PF anchors are named collections of rules that can be loaded from files and referenced from the main `pf.conf`. They provide modular rule management: the main config delegates to the anchor, and the anchor's rules are evaluated inline at the point of reference.

The `quick` keyword on our rules means "if this rule matches, stop evaluating — don't fall through to Mullvad's block rules."

### Why this survives Mullvad reconnects

Mullvad injects its PF rules dynamically at runtime using `pfctl`. It does **not** flush the base ruleset loaded from `/etc/pf.conf`. Our anchor is part of the base ruleset, so it persists across Mullvad connects, disconnects, and reconnects.

### Why this should not create a DNS leak

Mullvad's PF rules restrict DNS (port 53) to only pass through Mullvad's tunnel interface to Mullvad's DNS server. Our anchor only passes traffic on Tailscale's active `utun` interface to Tailscale's CGNAT and IPv6 ULA ranges. It does not open arbitrary destinations, does not change Mullvad's DNS configuration, and does not alter browser or app-level DNS settings.

Magic DNS queries to `100.100.100.100` are resolved by Tailscale's local DNS proxy and travel over the Tailscale tunnel. That is why this PF exception is expected to be leak-safe, but you should still verify your own system state with Mullvad's connection check after installation.

## Installation

```bash
git clone https://github.com/tobomobo/mullvad-tailscale-macos.git
cd mullvad-tailscale-macos
sudo bash install.sh
```

The install script auto-detects Tailscale's active `utun` interface. If Tailscale is not running yet, pass the interface explicitly:

```bash
sudo bash install.sh --interface utun3
```

The install script is designed to be idempotent: it repairs partial anchor blocks, refreshes the runtime anchor when `pf.conf` is already correct, validates staged changes before reload, and restores the original `pf.conf` if PF rejects the update.

### What it does

1. Detects Tailscale's active `utun` interface, or uses `--interface`.
2. Renders `etc/pf.anchors/tailscale` for that interface and installs it to `/etc/pf.anchors/tailscale`.
3. Repairs the exact anchor block in `/etc/pf.conf` if either line is missing.
4. Validates the staged `pf.conf` before reloading PF.
5. Backs up `/etc/pf.conf` to `/etc/pf.conf.bak.<timestamp>`.
6. Reloads PF only when `pf.conf` changed; otherwise it refreshes just the runtime anchor.
7. Restores the original `pf.conf` automatically if PF rejects the new config.

### The anchor rules

```text
pass out quick on <tailscale-utun> inet from any to 100.64.0.0/10 no state
pass in quick on <tailscale-utun> inet from 100.64.0.0/10 to any no state
pass out quick on <tailscale-utun> inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on <tailscale-utun> inet6 from fd7a:115c:a1e0::/48 to any no state
```

- `<tailscale-utun>` — Tailscale's active tunnel interface on macOS.
- `100.64.0.0/10` — the CGNAT range used by Tailscale for IPv4.
- `fd7a:115c:a1e0::/48` — Tailscale's IPv6 ULA range.
- `quick` — match immediately, skip remaining rules.
- `no state` — don't create state table entries (avoids interference with Mullvad's state tracking).

### The pf.conf addition

```
anchor "tailscale"
load anchor "tailscale" from "/etc/pf.anchors/tailscale"
```

## Uninstallation

```bash
sudo bash uninstall.sh
```

This removes the anchor file, strips the anchor lines from `pf.conf` (after backing it up), and reloads PF when the managed block was present.

If you used the repo-managed Tailscale LaunchDaemon, remove that separately:

```bash
sudo bash uninstall-tailscaled-daemon.sh
```

## Verification

After installing, verify with these commands:

### Quick check

```bash
sudo bash verify.sh
```

This checks the anchor file, exact `pf.conf` references, PF runtime state, interface assignment, the daemon state for both tools, and the presence of the repo-managed LaunchDaemon plist.

To run active end-to-end checks as well:

```bash
sudo bash verify.sh --tailnet-target <peer> --magicdns-name <peer>.ts.net
```

That adds:

- `tailscale ping --c 1 --timeout 5s <peer>`
- a direct MagicDNS lookup via `100.100.100.100`
- a Mullvad tunnel check using `curl https://am.i.mullvad.net/connected`

### Manual checks

**Confirm the anchor is loaded:**

```bash
sudo pfctl -a tailscale -sr
```

Expected output:

```text
pass out quick on <tailscale-utun> inet from any to 100.64.0.0/10 no state
pass in quick on <tailscale-utun> inet from 100.64.0.0/10 to any no state
pass out quick on <tailscale-utun> inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on <tailscale-utun> inet6 from fd7a:115c:a1e0::/48 to any no state
```

**Confirm the anchor appears in the main ruleset:**

```bash
sudo pfctl -sr | grep 'anchor "tailscale"'
```

Expected output:

```
anchor "tailscale" all
```

**Test Tailscale connectivity:**

```bash
tailscale ping <hostname>
dig +short @100.100.100.100 <hostname>.ts.net
curl https://am.i.mullvad.net/connected
```

**Confirm no obvious leak:**

```bash
dig +short whoami.akamai.net
```

Or visit [Mullvad's DNS leak test](https://mullvad.net/en/check).

## Maintenance

### macOS updates

Major macOS updates (e.g., Ventura → Sonoma) can **reset `/etc/pf.conf`** to the system default, which removes the anchor lines. The anchor file at `/etc/pf.anchors/tailscale` is typically preserved.

**After a major macOS update**, if Tailscale stops working alongside Mullvad:

```bash
# Check if the anchor lines are still present
grep -Fx 'anchor "tailscale"' /etc/pf.conf
grep -Fx 'load anchor "tailscale" from "/etc/pf.anchors/tailscale"' /etc/pf.conf

# If not, re-run the installer
sudo bash install.sh
```

Minor/security updates generally do not touch `pf.conf`.

### Tailscale updates

Updating Tailscale (via `brew upgrade tailscale` or the Mac App Store) does **not** affect PF configuration. No action needed.

### Mullvad updates

Mullvad injects its PF rules dynamically and does not modify `/etc/pf.conf`. Updates to Mullvad do not affect the anchor. No action needed.

### Interface name changes

This fix no longer assumes `utun0`, but it still depends on targeting the correct active Tailscale `utun` interface. If Tailscale is not running when you install, the script cannot auto-detect the interface and you must pass `--interface`.

To check which interface Tailscale is using:

```bash
ifconfig | grep -A 2 utun
# or
tailscale status --json | grep -i tun
```

## File overview

| File | Purpose |
|------|---------|
| `install.sh` | Detects the active Tailscale interface, renders the anchor, validates PF changes, and reloads or refreshes PF safely |
| `uninstall.sh` | Removes the managed anchor block, reloads PF with rollback protection, and deletes the installed anchor file |
| `install-tailscaled-daemon.sh` | Installs a system LaunchDaemon for `tailscaled` using `launchctl bootstrap` |
| `uninstall-tailscaled-daemon.sh` | Removes the repo-managed `tailscaled` LaunchDaemon |
| `etc/pf.anchors/tailscale` | Template used to render interface-specific PF anchor rules |
| `lib/common.sh` | Shared helpers for interface detection, exact-line matching, rollback-safe PF updates, and LaunchDaemon management |
| `verify.sh` | Checks configuration plus optional active Tailscale, MagicDNS, and Mullvad connectivity |
| `tests/run.sh` | Local smoke tests for install, uninstall, verify, rollback, and LaunchDaemon management |

## License

[Unlicense](LICENSE) — public domain.
