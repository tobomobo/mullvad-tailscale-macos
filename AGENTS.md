# Agent Guide

This is a narrowly maintained compatibility workaround for keeping Tailscale
usable on macOS while Mullvad's PF-based kill switch is enabled. Keep it
minimal: add behavior only for observed compatibility, safety, or reliability
problems—not speculative expansion.

Agents are expected to handle implementation, review, tests, and documentation.
Human testing is welcome, especially for live macOS behavior.

## Start Here

Before changing code, read:

1. `README.md`
2. The relevant guide in `docs/`
3. `SECURITY.md` for firewall, DNS, privilege, or security-claim changes
4. `lib/common.sh` and the script being changed
5. `lib/exit-node-proxy.sh` for optional exit-node proxy changes

Inspect repo-owned command definitions before running them.

## Safety Boundaries

- Ask before every live `sudo` command or operation that changes PF, launchd,
  Mullvad, Tailscale, or `/etc/resolver`. Also follow the active coding
  harness's approval and sandbox rules.
- Never describe stubbed tests or point-in-time connectivity checks as a live
  system security audit or universal proof of safety.
- Keep security claims evidence-based. Prefer "should" or "expected to" unless
  the code and executed checks establish something stronger.

## Non-Negotiable Invariants

- Detect Tailscale's active `utun` dynamically; never hard-code `utun0`. Keep
  `--interface` override support wherever detection matters.
- Keep the PF exception limited to Tailscale's CGNAT and IPv6 ULA ranges on the
  detected interface.
- Match the managed `pf.conf` lines exactly.
- Validate rendered anchors and staged `pf.conf` content before installation or
  reload.
- Preserve rollback: if `pfctl -f` or its post-check fails, restore the previous
  file and runtime ruleset.
- Keep the anchor workflow deterministic: detect, render, validate, stage,
  validate, apply, and verify.
- Keep LaunchDaemon management in repo scripts rather than ad hoc plist
  instructions.
- Route every optional proxy `tailscale` command through its dedicated LocalAPI
  socket; never let it mutate the primary client.
- Do not describe the optional proxy as exit-node fail-closed: userspace dialing
  can fall back to ordinary Mullvad egress.
- Keep direct MagicDNS checks separate from macOS system-resolver checks;
  `/etc/hosts`, `dscacheutil`, and resolver precedence can make them disagree.
- Keep resolver overrides domain-scoped under
  `/etc/resolver/<tailnet>.ts.net`; do not make per-host `/etc/hosts` entries
  part of the repo workflow.

## Making Changes

- Put shared PF and default-lifecycle behavior in `lib/common.sh`; keep shared
  optional proxy behavior in `lib/exit-node-proxy.sh`.
- Update `tests/run.sh` when install, uninstall, verification, or shared-helper
  behavior changes.
- Update the concise README path or focused guide when user-facing behavior
  changes.
- In reviews, prioritize correctness, regressions, security boundaries, and
  documentation drift over style.

## Quality Gates

After code changes, run:

```bash
bash -n ./*.sh ./lib/*.sh ./tests/*.sh
bash tests/run.sh
```

The smoke suite stubs system commands. It does not replace live macOS
validation of PF, launchd, Mullvad, Tailscale, or DNS behavior.

For docs-only changes, verify links and referenced paths; the shell checks may
be skipped if the final report says so.
