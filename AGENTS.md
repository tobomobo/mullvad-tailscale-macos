# AGENTS.md

This repository exists to keep Tailscale working on macOS while Mullvad's PF-based kill switch is enabled.

If you are an agent making changes here, optimize for safety first. This repo modifies firewall configuration, can touch launchd state, and makes security-sensitive claims.

## Purpose

- Install a PF anchor that allows Tailscale's tailnet ranges through Mullvad's kill switch.
- Detect the active Tailscale `utun` interface dynamically instead of assuming `utun0`.
- Manage an optional `tailscaled` LaunchDaemon through code, not copy-pasted plist snippets.
- Verify both configuration state and optional live connectivity checks.

## Files That Matter

- `install.sh`
  Renders the anchor for the active interface, validates staged PF changes, and applies rollback-safe updates.
- `uninstall.sh`
  Removes the managed anchor block and installed anchor file safely.
- `verify.sh`
  Verifies exact `pf.conf` lines, interface targeting, daemon state, and optional active checks.
- `lib/common.sh`
  Shared source of truth for interface detection, exact-line matching, rollback behavior, and LaunchDaemon helpers.
- `install-tailscaled-daemon.sh`
  Installs the managed LaunchDaemon using `launchctl bootstrap`.
- `uninstall-tailscaled-daemon.sh`
  Removes the managed LaunchDaemon.
- `etc/pf.anchors/tailscale`
  Template, not a fixed installed anchor.
- `tests/run.sh`
  Stubbed smoke tests for core safety and behavior.
- `README.md`
  Must stay aligned with code and should not overclaim what is guaranteed.

## Non-Negotiable Invariants

- Never hard-code `utun0` in new behavior.
- Keep `--interface` override support whenever interface detection is relevant.
- Use exact-line matching for the managed `pf.conf` block.
- Validate rendered anchor files before installing them.
- Validate staged `pf.conf` content before reloading PF.
- Restore the original `pf.conf` automatically if `pfctl -f` fails.
- Treat active leak/connectivity checks as verification, not as proof of universal safety.
- Keep direct MagicDNS checks separate from macOS system-resolver checks; `/etc/hosts`, `dscacheutil`, and resolver precedence can make them disagree.
- Keep docs honest: say "should" or "expected to" unless the code actually proves it.
- If you change install, uninstall, verify, or shared helper behavior, update `tests/run.sh`.

## Safe Workflow

1. Read `README.md`, `lib/common.sh`, and the script you plan to touch.
2. Prefer changing shared behavior in `lib/common.sh` instead of duplicating logic.
3. Keep the anchor-management path deterministic:
   - detect interface
   - render template
   - validate render
   - stage `pf.conf`
   - validate staged `pf.conf`
   - apply with rollback
4. Keep LaunchDaemon management inside the repo scripts.
5. Update docs when user-facing behavior changes.
6. Run local checks before finishing.

## Required Checks Before You Finish

Run these after relevant changes:

```bash
bash -n install.sh
bash -n uninstall.sh
bash -n verify.sh
bash -n install-tailscaled-daemon.sh
bash -n uninstall-tailscaled-daemon.sh
bash -n lib/common.sh
bash tests/run.sh
```

If you changed only docs, note that the smoke tests were not rerun if you choose to skip them.

## Things To Avoid

- Do not claim the repo has performed a live-system security audit unless one was actually done.
- Do not introduce substring-based `grep tailscale` logic for managed `pf.conf` lines.
- Do not add ad hoc plist instructions to the README if the repo can manage that flow in code.
- Do not remove rollback protection.
- Do not silently broaden the PF exception beyond Tailscale's CGNAT and IPv6 ULA ranges.
- Do not run destructive live PF or launchd changes on a user's machine without clear intent.

## Review Checklist

- Does the change preserve interface correctness when Tailscale is not `utun0`?
- Does it keep `pf.conf` edits exact and reversible?
- Does it preserve or improve test coverage?
- Does the README still match the actual scripts?
- Does any DNS or MagicDNS check account for `/etc/hosts`, `dscacheutil`, and resolver precedence under Mullvad?
- Are security statements precise and evidence-based?

## Reality Check

`tests/run.sh` is a stubbed smoke suite. It is useful, but it does not replace live macOS validation of `pfctl`, `launchctl`, Mullvad, and Tailscale.
