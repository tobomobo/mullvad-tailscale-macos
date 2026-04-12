# SECURITY.md

This document describes the security model and tradeoffs of this workaround. It is not a claim that the repo has undergone a formal security audit.

## What This Repo Changes

This repo installs a PF anchor and adds the following two managed lines to `/etc/pf.conf`:

```text
anchor "tailscale"
load anchor "tailscale" from "/etc/pf.anchors/tailscale"
```

The installed anchor then allows only Tailscale's tailnet ranges on Tailscale's active `utun` interface:

```text
pass out quick on <tailscale-utun> inet from any to 100.64.0.0/10 no state
pass in quick on <tailscale-utun> inet from 100.64.0.0/10 to any no state
pass out quick on <tailscale-utun> inet6 from any to fd7a:115c:a1e0::/48 no state
pass in quick on <tailscale-utun> inet6 from fd7a:115c:a1e0::/48 to any no state
```

That is intentionally narrow:

- only the active Tailscale tunnel interface is allowed
- only Tailscale's CGNAT and IPv6 ULA ranges are allowed
- the rules are `quick`, so matching traffic stops before later Mullvad block rules
- the rules use `no state`, so they do not interfere with Mullvad's own stateful tracking

## Why Split Tunneling Does Not Solve This

Mullvad's split tunneling on macOS works through Network Extension content-filter behavior. `tailscaled` runs as a root-managed system daemon, and root processes are the important edge case here.

This repo therefore fixes the problem at the PF layer instead of assuming app-level split tunneling will exempt `tailscaled`.

## Why This Should Not Create A DNS Leak

The anchor only allows traffic to Tailscale's own address ranges on Tailscale's interface. It does not open arbitrary destinations, and it does not change Mullvad DNS settings.

Magic DNS queries to `100.100.100.100` are expected to stay on Tailscale's tunnel path, which is why this approach should be leak-safe in normal operation.

That said, "should be leak-safe" is the right level of confidence here. You should still verify your own machine after installation:

```bash
sudo bash verify.sh --tailnet-target <peer> --magicdns-name <peer>.ts.net
curl https://am.i.mullvad.net/connected
```

## Direct MagicDNS Is Not The Same As macOS Hostname Resolution

A direct query to `100.100.100.100` proves that MagicDNS is reachable on the tailnet path. It does not prove that macOS apps are using that same resolver path.

In practice, app-level hostname resolution can still be changed by:

- `/etc/hosts`
- `/etc/resolver/*`
- the active resolver order shown by `scutil --dns`
- a local DNS proxy or VPN-managed resolver path

That means a result like this is possible:

- `dig +short @100.100.100.100 host.ts.net` returns the correct Tailscale IP
- but `dscacheutil -q host -a name host.ts.net` returns nothing or a different IP
- or an app works only because `/etc/hosts` contains a static override

When you are validating hostname access on macOS, check both layers:

```bash
dig +short @100.100.100.100 <peer>.ts.net
dscacheutil -q host -a name <peer>.ts.net
grep -nF '<peer>.ts.net' /etc/hosts
scutil --dns
```

Before editing resolver files, back them up:

```bash
sudo cp /etc/hosts /etc/hosts.bak.$(date +%Y%m%d%H%M%S)
sudo mkdir -p /etc/resolver
sudo cp -R /etc/resolver /etc/resolver.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true
```

After changing `/etc/hosts` or `/etc/resolver/*`, flush caches:

```bash
sudo dscacheutil -flushcache
sudo killall -HUP mDNSResponder
```

## MagicDNS, Same-LAN Peers, And DERP

MagicDNS resolves peer names to Tailscale addresses, not LAN addresses. That means a same-Wi-Fi connection to `host.ts.net` still depends on Tailscale traffic being allowed by PF.

This repo fixes that PF-layer problem, but it does not force Tailscale to use a direct local path. Once Tailscale traffic is allowed, path selection is still up to Tailscale. Depending on local network conditions, Tailscale may use:

- a direct local peer path
- or a DERP relay

So a result like this:

- direct MagicDNS resolves correctly
- `tailscale ping` succeeds
- Mullvad remains connected
- but the ping goes `via DERP`

means the workaround is functioning, but direct peer discovery or UDP reachability is still failing for some other reason. In other words:

- direct MagicDNS worked
- the PF exception worked
- the remaining problem is direct Tailscale path establishment

If app-level hostname access is still failing in that scenario, inspect macOS resolver precedence before concluding that "DNS worked."

This is also why the repo's active verifier should treat "TSMP reachability works, but DISCO direct path failed" as a warning rather than a hard failure. A DERP fallback means tailnet connectivity still works; it does not mean the PF fix failed.

## Failure Modes And Limits

This repo reduces risk, but it does not remove all operational risk.

Things that can still go wrong:

- Tailscale is not running when `install.sh` executes, so interface auto-detection fails
- macOS reassigns Tailscale to a different `utun` interface later
- a major macOS update resets `/etc/pf.conf`
- live PF behavior on a given host differs from the stubbed smoke tests in this repo

The repo tries to reduce those risks by:

- supporting `--interface utunX`
- validating rendered anchor files before install
- validating staged `pf.conf` before reload
- restoring the previous `pf.conf` automatically if PF rejects the new config
- providing `verify.sh` for both config checks and optional active checks

## Why This Repo Uses Standalone Mullvad Instead Of The Tailscale Mullvad Add-On

Because the two approaches have different goals.

As of April 7, 2026:

- Tailscale documents [Mullvad exit nodes](https://tailscale.com/kb/1258/mullvad-exit-nodes/) as a beta feature
- Tailscale documents the Mullvad integration as a separately purchased add-on
- Tailscale documents that, when you use Mullvad with Tailscale, Tailscale generates and manages Mullvad accounts on users' behalf and knows which Mullvad accounts belong to which Tailscale users
- Tailscale documents [self-serve paid checkout with credit-card billing](https://tailscale.com/kb/1251/pricing-faq), while also documenting invoice-based options for some plans via sales/support workflows
- Mullvad documents [privacy-oriented direct payment options](https://mullvad.net/en/pricing) including cash and Monero, and Mullvad separately announced support for [Bitcoin Lightning payments](https://mullvad.net/en/blog/lightning-payments)
- Mullvad documents [DAITA and multihop](https://mullvad.net/en/help/using-mullvad-vpn-app/) as features of the Mullvad app itself

For this repo, that leads to a simple tradeoff:

- use the Tailscale Mullvad add-on if you want tailnet-managed Mullvad exit nodes
- use this repo if you want to keep the standalone Mullvad app, keep using an existing Mullvad subscription/payment model, and keep Mullvad app features such as DAITA or multihop available

Important nuance:

The statement about DAITA and multihop is an inference from product design and vendor documentation, not a claim that Tailscale explicitly says "these features are unavailable" in the add-on. Tailscale's Mullvad integration is an exit-node feature, while Mullvad documents DAITA and multihop in the Mullvad app and app guides.

## Validation Checklist

After installation:

```bash
sudo bash verify.sh
sudo bash verify.sh --tailnet-target <peer> --magicdns-name <peer>.ts.net
sudo pfctl -a tailscale -sr
sudo pfctl -sr | grep 'anchor "tailscale"'
dig +short @100.100.100.100 <peer>.ts.net
dscacheutil -q host -a name <peer>.ts.net
curl https://am.i.mullvad.net/connected
```

After a major macOS upgrade:

```bash
grep -Fx 'anchor "tailscale"' /etc/pf.conf
grep -Fx 'load anchor "tailscale" from "/etc/pf.anchors/tailscale"' /etc/pf.conf
```

## Reporting A Security Problem In This Repo

If you find a bug that could widen the PF exception, break rollback safety, or create misleading security claims in the docs, open an issue with as much detail as you can safely share. Redact unrelated local addressing, hostnames, and nonessential firewall rules before posting logs or `pf.conf` snippets.
