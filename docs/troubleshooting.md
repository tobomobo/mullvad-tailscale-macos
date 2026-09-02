# Troubleshooting

[Back to the quick start](../README.md) · [Operations](operations.md) · [Security model](../SECURITY.md)

Start every diagnosis with:

```bash
sudo bash verify.sh
```

Fix failures before warnings. Warnings about omitted active targets are expected unless you supplied those targets.

## The Tailscale Interface Cannot Be Detected

The installer identifies the `utun` that carries the address returned by
`tailscale ip`. The watcher can also identify a sole `utun` carrying
Tailscale's IPv6 ULA prefix when launchd cannot find the CLI; it still requires
active Mullvad PF protection before changing PF. If more than one `utun`
carries that prefix, the scripts exit with an error instead of guessing; check
for a second Tailscale backend or pass `--interface`. When the CLI is
unavailable and PF carries no Mullvad anchor, the watcher exits `0` and leaves
the anchor unchanged. Confirm Tailscale is connected:

```bash
tailscale status
tailscale ip -4
tailscale ip -6
```

Then rerun:

```bash
sudo bash install.sh
```

For a one-off install with a known interface:

```bash
sudo bash install.sh --interface utun3
```

The watcher will detect later interface changes automatically.

## The Anchor Is Missing, Detached, or Ordered After Mullvad

Use the normal repair command:

```bash
sudo bash install.sh
```

The installer repairs a missing anchor file, restores the exact managed `/etc/pf.conf` block, and ensures Tailscale's quick exception is evaluated before Mullvad's anchor.

Manual inspection:

```bash
sudo pfctl -a tailscale -sr
sudo pfctl -sr | grep -E 'anchor "(tailscale|mullvad)"'
sudo pfctl -s info
```

`pfctl -a tailscale -sr` shows rules loaded under the anchor name. It does not prove that the main PF ruleset calls that anchor. The `pfctl -sr` output is the relevant attachment and ordering check.

macOS may also print `No ALTQ support in kernel`; that message is unrelated to this policy.

## The Watcher Says `state = not running`

That can be healthy. The watcher is launched periodically, performs one refresh, and exits. It is not meant to stay running.

Inspect it with:

```bash
sudo launchctl print system/com.mullvad-tailscale-macos.pf-watcher
```

Look for:

- the expected plist path;
- `run interval = 120 seconds`;
- a successful `last exit code = 0`; and
- the watcher label being present in the system domain.

Repair and trigger it manually:

```bash
sudo bash install-pf-watcher.sh
sudo bash refresh-anchor.sh
```

The default verifier checks whether the job is loaded, not whether it happens to be executing at that instant.

## `tailscaled` Does Not Appear To Be Running

Check both launchd and the process list:

```bash
sudo launchctl print system/com.tailscale.tailscaled
pgrep -alf tailscaled
tailscale status
```

If launchd reports `state = running` and the process is present, the daemon is loaded even if the Tailscale client still needs authentication or `tailscale up`.

Only install this repo's optional daemon if another known mechanism is not already managing it:

```bash
sudo bash install-tailscaled-daemon.sh
tailscale up
```

An unmarked existing plist is reported as a warning because this repository does not claim ownership of it. Loaded and running is still a valid state.

## MagicDNS Works Directly but macOS Apps Fail

Direct MagicDNS and the macOS system resolver are different tests:

```bash
dig +short @100.100.100.100 <peer>.your-tailnet.ts.net
dscacheutil -q host -a name <peer>.your-tailnet.ts.net
grep -nF '<peer>.your-tailnet.ts.net' /etc/hosts
scutil --dns
```

Interpret the result:

- direct `dig` works but `dscacheutil` is empty: macOS is not using the expected resolver path;
- they return different addresses: another resolver or local override is winning;
- `/etc/hosts` contains the name: an app can appear to work while bypassing MagicDNS;
- both return the Tailscale address: DNS is probably not the remaining failure.

If direct MagicDNS works but the system resolver does not, install the domain-scoped override:

```bash
sudo bash install-tailnet-resolver.sh \
  --tailnet-domain your-tailnet.ts.net
```

Then verify both paths:

```bash
sudo bash verify.sh \
  --tailnet-domain your-tailnet.ts.net \
  --magicdns-name <peer>.your-tailnet.ts.net
```

Do not use a plain `/etc/resolver` entry for Mullvad's public encrypted DNS endpoints; those endpoints are intended for DoH or DoT. Do not add static per-peer `/etc/hosts` entries as the normal repo workflow.

## Mullvad Content Blockers Break DNS

Mullvad's in-app blocker settings select DNS addresses from `100.64.0.1` through `100.64.0.63`. Those addresses are inside Tailscale's shared `100.64.0.0/10` range, so they collide while Tailscale is active.

Use Mullvad's non-blocking default DNS:

```bash
mullvad dns set default
```

Confirm the active resolver and route if needed:

```bash
scutil --dns | grep nameserver
route -n get 100.64.0.1
```

The PF exception cannot resolve this address ownership collision. If DNS filtering is required, configure a non-overlapping DoH/DoT service or a blocking upstream resolver through Tailscale.

## The Peer Is Reachable but Uses DERP

MagicDNS maps a name to a Tailscale address; it does not choose whether packets travel directly or through a DERP relay.

Run both checks:

```bash
tailscale ping --tsmp <peer>
tailscale ping <peer>
```

If the first succeeds and the second reports DERP, the tailnet and PF exception are working. The remaining issue is direct-path establishment, which can depend on NAT, local firewall behavior, peer availability, and network policy.

The verifier expresses this distinction as a pass for reachability plus a warning for the missing direct path:

```bash
sudo bash verify.sh --tailnet-target <peer>
```

## Same Wi-Fi Does Not Bypass the Need for This Policy

Traffic to a peer's LAN address, such as `192.168.x.x`, may use Mullvad's local-network allowance. Traffic to the peer's MagicDNS name or Tailscale address still uses Tailscale addressing and therefore still needs the PF exception.

## Problems After an OS or App Update

Updates can change the active `utun`, reload PF, or remove persistent managed lines. Repair and recheck:

```bash
sudo bash install.sh
sudo bash verify.sh \
  --tailnet-target <peer> \
  --magicdns-name <peer>.your-tailnet.ts.net
```

The installer is designed to be rerun and repairs the managed state instead of requiring a manual reinstall sequence.

## A Runtime PF Anchor Blocks the Reload

`install.sh`, `uninstall.sh`, and the watcher's repair path replace the whole main PF ruleset with `pfctl -f`. Before doing so they refuse if the live ruleset calls an anchor that the staged `pf.conf` does not mention, because the reload would silently drop it:

```
Active main PF anchor call 'com.apple.internet-sharing' is not represented in the staged config; refusing to flush it.
```

macOS inserts `com.apple.internet-sharing` at runtime for Internet Sharing and for the shared (NAT) networking that VM and container apps use, including Parallels Desktop, Docker Desktop, OrbStack, and UTM. It lives only in the live ruleset while that service runs; Apple's stock `pf.conf` warns about exactly these dynamic anchors. Nothing is broken and nothing was changed: the refusal leaves the previous configuration in place.

Check what is attached:

```bash
sudo pfctl -sr | grep anchor
```

Quit the VM or container apps (a suspended VM is not enough; the app's networking service must exit), or turn off Internet Sharing in System Settings, confirm the anchor is gone, and rerun the script. Reopening the apps afterwards is fine: routine watcher runs reload only the Tailscale anchor and never touch the main ruleset. The full reload is needed only on install, uninstall, and when another PF reload has detached the Tailscale call.

For an anchor from another firewall or VPN product, stop that product or add its anchor call to `/etc/pf.conf` so the staged configuration keeps it.

## Multiple Tailscale Backends Are Active

Do not run the Homebrew `tailscaled` daemon and a Tailscale macOS app network extension at the same time. They can use different identities and `utun` interfaces, while the CLI, browser traffic, and PF rules each follow a different backend or route.

Check for both backends:

```bash
pgrep -alf 'tailscaled|io.tailscale|IPNExtension'
tailscale version --daemon
```

Choose either the CLI daemon or the macOS app, stop or remove the other one, and rerun `sudo bash install.sh`. The installer and watcher refuse this ambiguous state, and `verify.sh` reports it as a failure even when `--interface` is supplied.

Disable or remove app extensions through System Settings or the owning app. Do not disable System Integrity Protection or manually delete files under `/Library/SystemExtensions`.

## Useful Diagnostic Bundle

These commands are read-only except for the final network requests:

```bash
sudo bash verify.sh
tailscale status
tailscale ip -4
tailscale ip -6
mullvad status
mullvad lockdown-mode get
sudo pfctl -sr
sudo pfctl -a tailscale -sr
sudo launchctl print system/com.mullvad-tailscale-macos.pf-watcher
curl https://am.i.mullvad.net/connected
```

Redact tailnet names, peer names, Tailscale IPs, device identifiers, and account information before sharing output.
