# Running Mullvad VPN and Tailscale simultaneously on macOS

Mullvad's PF-based kill switch can block Tailscale traffic on macOS. This repo fixes that by installing a persistent PF anchor that explicitly allows Tailscale's tailnet ranges on Tailscale's active `utun` interface before Mullvad's blocking rules evaluate the packet.

On some Macs, Mullvad also leaves normal app-level DNS on the wrong path for MagicDNS names. For that case, this repo now includes an optional domain-scoped `/etc/resolver/<tailnet>.ts.net` helper too.

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

The optional daemon installer copies `tailscaled` to a root-owned path before
launchd executes it, marks the plist as repo-managed, and discards stdout/stderr
by default rather than accumulating tailnet metadata in world-readable logs. It
also requires `launchctl` to confirm that the installed job is loaded. If
the standard plist already exists without the repo marker, the installer refuses
to replace it. For a known older install from this repo, inspect the plist and
then migrate it explicitly:

```bash
sudo bash install-tailscaled-daemon.sh --replace-existing
```

That adoption also makes the legacy `/var/log/tailscaled.log` and
`/var/log/tailscaled.err` files root-only if they exist. They are no longer
written by the new plist; inspect and remove them later if you do not need the
old diagnostics.

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

That one command installs or repairs the PF policy and installs or updates its
automatic watcher. The component scripts remain available for targeted repair
and removal.

The installer accepts PF's harmless runtime reordering of those four independent
rules, but still rejects missing, duplicated, or additional rules. If runtime
verification fails, it prints both the expected policy and the rules PF actually
reported before rolling back. An existing managed `pf.conf` block with a missing
anchor file is repaired automatically on the next successful install. The
installer also checks the active main PF ruleset: if the Tailscale rules are
loaded but no main-ruleset call reaches them, it restores that call before
reporting success.

If Tailscale is not running yet and the script cannot auto-detect its active interface:

```bash
sudo bash install.sh --interface utun3
```

If tailnet hostnames still do not resolve reliably under Mullvad even though Tailscale itself is reachable, install the optional domain-scoped resolver override:

```bash
sudo bash install-tailnet-resolver.sh --tailnet-domain your-tailnet.ts.net
```

That writes `/etc/resolver/your-tailnet.ts.net` pointing at Tailscale MagicDNS. It is system-wide for all local users and is cleaner than adding per-host `/etc/hosts` entries.

Verify:

```bash
sudo bash verify.sh
```

For active end-to-end checks:

```bash
sudo bash verify.sh --tailnet-target <peer> --magicdns-name <peer>.your-tailnet.ts.net
```

When `--tailnet-target` is provided, `verify.sh` now checks two different things:

- Tailscale reachability over the tailnet
- whether Tailscale could also establish a direct DISCO path instead of falling back to DERP

So "peer reachable, but via DERP" is treated as a working tailnet connection with a warning about direct-path establishment, not as a failed install.

## What The Scripts Do

- `install.sh`
  Gets Tailscale's exact self IP from `tailscale ip`, finds the `utun` carrying that address, renders the anchor, validates staged PF changes, applies a fail-closed PF transaction that preserves and rechecks Mullvad's live anchor, and installs or updates the automatic watcher.
- `uninstall.sh`
  Removes the automatic watcher and managed anchor block, reloads PF when needed, and deletes the installed anchor file.
- `install-tailscaled-daemon.sh`
  Installs a marked system LaunchDaemon using a protected root-owned copy of `tailscaled` and `launchctl bootstrap`.
- `uninstall-tailscaled-daemon.sh`
  Removes the repo-managed `tailscaled` LaunchDaemon.
- `install-pf-watcher.sh`
  Installs a LaunchDaemon that reattaches the PF anchor to Tailscale's current `utun` interface when it changes or when another PF reload detaches its main-ruleset call.
- `uninstall-pf-watcher.sh`
  Removes the pf-watcher LaunchDaemon and its installed payload.
- `refresh-anchor.sh`
  Re-renders and reloads the anchor for the active interface; runnable manually and used by the watcher.
- `install-tailnet-resolver.sh`
  Installs an optional domain-scoped `/etc/resolver/<tailnet>.ts.net` override that points macOS apps at Tailscale MagicDNS.
- `uninstall-tailnet-resolver.sh`
  Removes the optional resolver override.
- `verify.sh`
  Checks the exact four-rule policy, PF enablement, active main-ruleset anchor calls and ordering, Mullvad connection/lockdown state, interface identity, launchd job state and ownership, optional resolver state, and optional active connectivity.

## PF Reload Safety

macOS warns that `pfctl -f` can flush rules dynamically attached to the main
ruleset. Mullvad attaches its `mullvad` anchor that way, so a plain full reload
can silently remove lockdown enforcement.

When `install.sh`, `uninstall.sh`, or the watcher repair path must reload the
main PF ruleset, the scripts:

1. inspect every anchor call in the active main ruleset and refuse to flush an unknown dynamic call;
2. snapshot Mullvad's active anchor rules;
3. add a runtime-only `anchor "mullvad"` call after the Tailscale exception in the staged transaction;
4. apply the validated PF transaction;
5. verify that all protected main-ruleset calls remain and Mullvad's rules are byte-for-byte identical; and
6. restore and recheck both the previous file and runtime ruleset if the load or post-check fails.

The runtime-only Mullvad line is deliberately not written to `/etc/pf.conf`;
Mullvad remains responsible for its own policy lifecycle. This protects reloads
performed by this repo. It cannot make unrelated third-party `pfctl -f` commands
safe.

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
sudo pfctl -s info
mullvad lockdown-mode get
tailscale ping --tsmp <hostname>
tailscale ping <hostname>
dig +short @100.100.100.100 <hostname>.your-tailnet.ts.net
dscacheutil -q host -a name <hostname>.your-tailnet.ts.net
curl https://am.i.mullvad.net/connected
```

`pfctl -a tailscale -sr` proves that rules are loaded into the named ruleset;
it does not prove the main ruleset calls them. Likewise, `pfctl -s Anchors` is
only an inventory of loaded anchor names. The `pfctl -sr` call line is the
relevant attachment check.

When checking hostname resolution on macOS, treat those commands differently:

- `dig +short @100.100.100.100 <hostname>.your-tailnet.ts.net` tests direct MagicDNS reachability
- `dscacheutil -q host -a name <hostname>.your-tailnet.ts.net` tests the macOS system resolver path that apps such as `curl` normally use

If those disagree, fix the resolver path before assuming the PF workaround is broken.

## Optional Tailnet Resolver Override

For many macOS setups, the PF anchor is enough by itself. Some Mullvad setups still leave macOS apps on the wrong DNS path for tailnet names, even though:

- `tailscale ping --tsmp <peer>` works
- `dig +short @100.100.100.100 <peer>.your-tailnet.ts.net` returns the correct Tailscale IP
- app-level hostname access still fails under Mullvad

That is the case this optional script is for:

```bash
sudo bash install-tailnet-resolver.sh --tailnet-domain your-tailnet.ts.net
```

It installs a single file:

```text
/etc/resolver/your-tailnet.ts.net
```

with:

```text
nameserver 100.100.100.100
```

That is domain-scoped, not per-host hardcoding. It keeps IP assignment dynamic and usually works better than adding static `/etc/hosts` entries.

The helper installs it as a root-owned but readable file, so non-admin users can inspect it even though an admin is still required to create or change it.

To remove it later:

```bash
sudo bash uninstall-tailnet-resolver.sh --tailnet-domain your-tailnet.ts.net
```

To verify that optional resolver override after installation:

```bash
sudo bash verify.sh --tailnet-domain your-tailnet.ts.net --magicdns-name <peer>.your-tailnet.ts.net
```

## Mullvad DNS Content Blockers

Mullvad's in-app content blockers (ads, trackers, malware, and so on) do not work while Tailscale is running, and this is not something the PF anchor can fix.

When you enable a content blocker, the Mullvad app points your in-tunnel DNS at an address in `100.64.0.x` (a bitmask: ads=1, trackers=2, malware=4, adult=8, gambling=16, social=32, so for example `100.64.0.1`, `100.64.0.3`, `100.64.0.7`). That address sits inside Tailscale's `100.64.0.0/10` CGNAT range. Tailscale claims that range while it is up, so those DNS queries collide with Tailscale and stop resolving.

Mullvad's default DNS is `10.64.0.1`, which is in a different range, so `mullvad dns set default` keeps working. That is why the rest of this setup is expected to work only with Mullvad's default DNS.

You can confirm the collision on your own machine:

```bash
scutil --dns | grep nameserver   # is a 100.64.0.x resolver configured?
route -n get 100.64.0.1          # which interface owns it?
```

`verify.sh` also warns if it sees a `100.64.0.x` system resolver.

If you want content blocking alongside Tailscale, use a path that does not live in the CGNAT range:

- Mullvad's public encrypted-DNS blockers, configured as DoH/DoT (not as a plain `/etc/resolver` nameserver): `194.242.2.3` (ads + trackers), `194.242.2.4` (+ malware), `194.242.2.9` (all categories). These are normal public addresses reached through the Mullvad tunnel, so they do not overlap Tailscale's range.
- Or do the blocking at the Tailscale DNS layer instead, for example a blocking upstream resolver such as NextDNS set as a global nameserver in the Tailscale admin console. That keeps DNS on `100.100.100.100`, which already coexists with this setup.

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

means the PF fix is working and direct MagicDNS is working. The remaining issue is likely direct-path establishment between the two Tailscale peers, not the PF exception itself.

That conclusion only holds when the macOS system resolver also returns the expected Tailscale address. Direct `dig @100.100.100.100` alone does not prove that apps are using the same resolver path.

## Hostname Resolution Troubleshooting

If `tailscale ping --tsmp <peer>` works but app access to `https://<peer>.your-tailnet.ts.net` does not, compare the direct MagicDNS answer with the macOS system resolver:

```bash
dig +short @100.100.100.100 <peer>.your-tailnet.ts.net
dscacheutil -q host -a name <peer>.your-tailnet.ts.net
grep -nF '<peer>.your-tailnet.ts.net' /etc/hosts
scutil --dns
```

Interpret the results like this:

- direct MagicDNS resolves, but `dscacheutil` is empty:
  macOS is not using the expected resolver path for that hostname
- direct MagicDNS resolves, but `dscacheutil` returns a different IP:
  a local override or a different resolver path is winning
- `/etc/hosts` contains the hostname:
  app-level access may work because of a static override, even if MagicDNS is broken or bypassed
- direct MagicDNS is correct, but macOS apps still fail:
  install the optional resolver override for `your-tailnet.ts.net` instead of adding more `/etc/hosts` entries

Before editing local resolver files, back them up:

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

One practical note from real-world testing on macOS: a plain `dig <peer>.your-tailnet.ts.net` can disagree with the system resolver path that `curl` uses. If `curl https://<peer>.your-tailnet.ts.net` works but plain `dig` does not, prefer the `dscacheutil` and app-level result when diagnosing split DNS.

## Keeping The Anchor Attached When Tailscale's Interface Changes

The anchor is intentionally bound to Tailscale's active `utun` interface, which keeps the PF exception scoped to the tunnel. macOS can hand Tailscale a different `utun` number when it stops and restarts, which leaves the anchor pinned to the old interface until it is re-rendered.

The default `sudo bash install.sh` command installs the watcher automatically.
The component commands remain useful for targeted operations:

- Re-run `sudo bash install.sh` after a restart. It re-detects the interface and reattaches the anchor.
- Keep `tailscaled` always running (`sudo bash install-tailscaled-daemon.sh`), which reduces how often the interface changes, though it does not guarantee the number survives every reboot, update, or crash.
- Reinstall or repair only the watcher:

```bash
sudo bash install-pf-watcher.sh
```

The watcher LaunchDaemon runs `refresh-anchor.sh`. It re-checks Tailscale's interface periodically (about every two minutes) and also immediately when macOS rewrites its DNS resolver files. The periodic re-check is what actually guarantees recovery, since a Tailscale restart does not always change a watched file; expect reattachment within roughly the poll interval rather than instantly. When Tailscale has moved to a new `utun`, `refresh-anchor.sh` re-renders the anchor for that interface, validates it, and reloads the runtime anchor. If the rules remain loaded but the main PF ruleset no longer calls them, it safely reloads the unchanged managed configuration through the same Mullvad-preserving transaction. It keeps the narrow interface binding rather than removing it, so it does not widen the PF exception to other interfaces.

The watcher plist and payload carry ownership markers. Install and uninstall
refuse unrecognized files instead of overwriting or recursively deleting them.
Known legacy watcher payloads from this repo are migrated on reinstall. Routine
watcher output goes to `/dev/null`; run `sudo bash refresh-anchor.sh` manually
when interactive diagnostics are needed.

The watcher does not edit the persistent contents of `/etc/pf.conf`; the
`anchor` and `load anchor` lines still come from `install.sh`. It can reload
that already-managed configuration to repair a detached runtime call. Remove it
with:

```bash
sudo bash uninstall-pf-watcher.sh
```

You can also run a one-off reattach yourself:

```bash
sudo bash refresh-anchor.sh
```

## Maintenance

After major macOS updates, confirm that both managed lines still exist in `/etc/pf.conf`.

On at least one confirmed machine, upgrading to macOS `26.4.1` removed the repo-managed `tailscale` anchor lines from `/etc/pf.conf`. The observed symptom was:

- `tailscale ping` still worked
- but app traffic such as `ssh <peer>` or `https://<peer>.your-tailnet.ts.net` timed out while Mullvad was on

Check for the managed lines with:

```bash
grep -Fx 'anchor "tailscale"' /etc/pf.conf
grep -Fx 'load anchor "tailscale" from "/etc/pf.anchors/tailscale"' /etc/pf.conf
```

If either line is missing:

```bash
sudo bash install.sh
```

That re-renders the anchor for the current Tailscale interface and restores the managed `pf.conf` block.

If you want a quick post-upgrade sanity check after reinstalling, run:

```bash
sudo bash verify.sh --tailnet-target <peer> --magicdns-name <peer>.your-tailnet.ts.net
```

If you want the full rationale for why this approach should be safe, where it can still fail, and how it compares to the Tailscale add-on, read [SECURITY.md](SECURITY.md).

## License

[Unlicense](LICENSE) - public domain.
