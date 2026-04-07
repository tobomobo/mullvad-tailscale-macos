# Running Mullvad VPN and Tailscale simultaneously on macOS

Mullvad's kill switch silently drops Tailscale traffic on macOS. This repo contains a fix: a persistent PF anchor that whitelists Tailscale's CGNAT range before Mullvad's firewall rules evaluate it.

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

We add a **PF anchor** — a named sub-ruleset — that explicitly passes Tailscale traffic on `utun0` (Tailscale's tunnel interface) before Mullvad's rules get a chance to drop it.

### What is a PF anchor?

PF anchors are named collections of rules that can be loaded from files and referenced from the main `pf.conf`. They provide modular rule management: the main config delegates to the anchor, and the anchor's rules are evaluated inline at the point of reference.

The `quick` keyword on our rules means "if this rule matches, stop evaluating — don't fall through to Mullvad's block rules."

### Why this survives Mullvad reconnects

Mullvad injects its PF rules dynamically at runtime using `pfctl`. It does **not** flush the base ruleset loaded from `/etc/pf.conf`. Our anchor is part of the base ruleset, so it persists across Mullvad connects, disconnects, and reconnects.

### Why this doesn't cause DNS leaks

Mullvad's PF rules restrict DNS (port 53) to only pass through Mullvad's tunnel interface to Mullvad's DNS server (typically `10.64.0.1` on `utun9`). Our anchor only passes traffic on `utun0` (Tailscale's interface) to the CGNAT range. It does not touch port 53 rules, does not modify Mullvad's DNS configuration, and does not allow arbitrary DNS traffic to leak outside the VPN tunnel.

Magic DNS queries to `100.100.100.100` are resolved by Tailscale's local DNS proxy and travel over the Tailscale tunnel — they never leave `utun0`.

## Installation

```bash
git clone https://github.com/tobomobo/mullvad-tailscale-macos.git
cd mullvad-tailscale-macos
sudo bash install.sh
```

The install script is idempotent — running it multiple times is safe.

### What it does

1. Copies `etc/pf.anchors/tailscale` to `/etc/pf.anchors/tailscale`.
2. Backs up `/etc/pf.conf` to `/etc/pf.conf.bak.<timestamp>`.
3. Appends the anchor reference and load directive to `/etc/pf.conf` (if not already present).
4. Reloads PF with `pfctl -f /etc/pf.conf`.

### The anchor rules

```
pass out quick on utun0 inet from any to 100.64.0.0/10 no state
pass in quick on utun0 inet from 100.64.0.0/10 to any no state
pass out quick on utun0 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun0 inet6 from fd7a:115c:a1e0::/48 to any no state
```

- `utun0` — Tailscale's tunnel interface on macOS.
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

This removes the anchor file, strips the anchor lines from `pf.conf` (after backing it up), and reloads PF.

## Verification

After installing, verify with these commands:

### Quick check

```bash
sudo bash verify.sh
```

This checks the anchor file, pf.conf references, PF runtime state, interface assignment, and whether both daemons are running.

### Manual checks

**Confirm the anchor is loaded:**

```bash
sudo pfctl -a tailscale -sr
```

Expected output:

```
pass out quick on utun0 inet from any to 100.64.0.0/10 no state
pass in quick on utun0 inet from 100.64.0.0/10 to any no state
pass out quick on utun0 inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on utun0 inet6 from fd7a:115c:a1e0::/48 to any no state
```

**Confirm the anchor appears in the main ruleset:**

```bash
sudo pfctl -sr | grep tailscale
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

**Confirm no DNS leak:**

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
grep tailscale /etc/pf.conf

# If not, re-run the installer
sudo bash install.sh
```

Minor/security updates generally do not touch `pf.conf`.

### Tailscale updates

Updating Tailscale (via `brew upgrade tailscale` or the Mac App Store) does **not** affect PF configuration. No action needed.

### Mullvad updates

Mullvad injects its PF rules dynamically and does not modify `/etc/pf.conf`. Updates to Mullvad do not affect the anchor. No action needed.

### Interface name changes

This fix assumes Tailscale uses `utun0`. If macOS assigns a different `utun` interface to Tailscale (uncommon but possible if other VPNs claim `utun0` first), you'll need to update the interface name in `/etc/pf.anchors/tailscale`.

To check which interface Tailscale is using:

```bash
ifconfig | grep -A 2 utun
# or
tailscale status --json | grep -i tun
```

## File overview

| File | Purpose |
|------|---------|
| `install.sh` | Idempotent installer — copies anchor, patches pf.conf, reloads PF |
| `uninstall.sh` | Removes anchor and pf.conf modifications, reloads PF |
| `etc/pf.anchors/tailscale` | PF anchor rules allowing Tailscale CGNAT traffic on utun0 |
| `verify.sh` | Checks that the anchor is correctly installed and loaded |

## License

[Unlicense](LICENSE) — public domain.
