# CLAUDE.md

Use this file as the fast path for Claude-style coding agents working in this repository.

## Start Here

Read these first:

1. `AGENTS.md`
2. `README.md`
3. `lib/common.sh`

`AGENTS.md` contains the repo-wide invariants. Follow it unless the user explicitly asks for a different direction.

## What Success Looks Like

A good change in this repo usually does all of the following:

- keeps Tailscale interface handling dynamic
- keeps PF edits exact, validated, and rollback-safe
- keeps LaunchDaemon management inside the provided scripts
- keeps verification realistic about what is checked vs. what is merely expected
- keeps direct MagicDNS checks separate from macOS system-resolver checks
- updates docs and tests when behavior changes

## Claude-Specific Guidance

- Prefer making one coherent change through the shared helper layer instead of scattering shell logic across scripts.
- If a behavior belongs in more than one script, put it in `lib/common.sh`.
- If you change user-visible behavior, update `README.md` in the same pass.
- If you change safety-sensitive behavior, add or update a smoke test in `tests/run.sh`.
- When reviewing, prioritize bugs, regressions, security posture, and doc drift over style.

## Commands

Syntax:

```bash
bash -n install.sh
bash -n uninstall.sh
bash -n verify.sh
bash -n install-tailscaled-daemon.sh
bash -n uninstall-tailscaled-daemon.sh
bash -n lib/common.sh
```

Smoke tests:

```bash
bash tests/run.sh
```

## High-Risk Areas

- `pf.conf` mutation
- `pfctl -f` reload behavior
- detection of the active Tailscale `utun` interface
- LaunchDaemon install and unload flows
- any security or DNS leak wording in the docs
- any MagicDNS validation that forgets about `/etc/hosts`, `dscacheutil`, or resolver precedence

## Keep The Docs Honest

Do not write stronger claims than the code and tests support.

Preferred language:

- "should not create a DNS leak"
- "expected to be leak-safe"
- "verified by active checks"

Avoid language like:

- "guaranteed safe"
- "proven secure"
- "fully audited"

unless the repo has actually earned those statements.
