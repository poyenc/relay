# Rotation-gate cleanup: unified timeout + clearer naming

**Date:** 2026-07-23
**Status:** Design approved, pending spec review
**Scope:** Rotation-gate teardown timing only. Does NOT include the graceful
`/exit` teardown work (branch `feature/graceful-exit-teardown` commits 1/3/4);
those land separately, later.

## Problem

The rotation gate on `feature/graceful-exit-teardown` (commit `c7f2180`) waits for
two sequential events before tearing down the outgoing generation:

1. the handoff marker file `gen-N/handoff.ready` appears (written mid-turn as
   Claude's last tool action), then
2. the first idle Stop hook fires after that (turn fully complete, final message
   rendered).

Both waits are backstopped by a single timer, `RELAY_MARKER_TIMEOUT` (default
120s, exposed as `--marker-timeout <s>`), measured from one `pending_since`
timestamp set when the rotation is requested.

Three things are suboptimal:

- **Misleading name.** `--marker-timeout` / `RELAY_MARKER_TIMEOUT` names only the
  first of the two phases it actually bounds. The user cannot tell it also governs
  the Stop wait.
- **Inconsistent syntax.** `--marker-timeout` takes raw integer seconds while the
  sibling flags `--rotate-grace` / `--exit-timeout` accept duration syntax
  (`10s`, `2m`) via `relay_parse_duration`.
- **Overloaded state flag with two writers.** The "turn done" flag
  `handoff_stop_seen` is set `true` in two places: the genuine post-handoff Stop,
  and the timeout branch (which force-sets it, then relies on the *next* loop
  iteration to actually rotate). The name describes the mechanism (a Stop was
  seen), not the meaning (the outgoing turn has settled), and the double-writer
  makes the flag's truth ambiguous.

## Goal

Give the user one clearly-named, duration-syntax timeout for the whole rotation
gate, and tighten the internal state so the "turn settled" signal has a single
writer and the timeout acts directly instead of round-tripping through state.

Non-goals: adding a second timeout knob; changing the two-phase correctness logic;
capping consecutive rotation failures; touching the graceful `/exit` teardown.

## Design

### 1. Unified, renamed timeout

Collapse the user-facing surface to a single timeout covering the entire
"rotation requested → ready to tear down" window. This is a pure rename +
syntax change; the timer already works this way (one `pending_since` origin).

| Before | After |
| --- | --- |
| env `RELAY_MARKER_TIMEOUT` (default `120`) | env `RELAY_ROTATION_TIMEOUT` (default `120`) |
| flag `--marker-timeout <s>` (raw seconds) | flag `--rotation-timeout <dur>` (duration syntax) |
| `RELAY_OPT_MARKER_TIMEOUT` | `RELAY_OPT_ROTATION_TIMEOUT` |

- `--rotation-timeout` parses via the existing `relay_parse_duration`, matching
  `--rotate-grace` / `--exit-timeout`.
- Default remains 120s. Help text: "How long to wait for the outgoing generation
  to hand off and settle before giving up on a rotation."
- `bin/relay` threads `RELAY_ROTATION_TIMEOUT` into the supervisor env alongside
  the other knobs.

### 2. Rename the state flag

`handoff_stop_seen` → `handoff_settled`.

Meaning: the handoff has been written **and** the outgoing generation has gone
idle after writing it (safe to tear down). Read site becomes self-explanatory:

```bash
if [ -f "$RUN_DIR/$marker" ] && [ "$settled" = "true" ]; then
```
"if the handoff marker exists and the handoff has settled → rotate."

After this change `handoff_settled` has exactly one setter that means `true`: the
genuine post-handoff Stop in `handle_stop_request`. It is initialized `false` when
the rotation is requested. The timeout branch no longer writes it (see §3).

### 3. Timeout expiry rotates directly (smart backstop, simplified)

When `RELAY_ROTATION_TIMEOUT` expires (age from `pending_since`):

- **Marker file present** → a complete handoff is on disk; only the Stop signal is
  missing (flaky hook). **Rotate directly** in the timeout branch — the same
  actuation the normal gate would do (bump generation, `actuate_rotation`). Log
  `ROTATE_STOP_TIMEOUT`. Do not waste a valid handoff.
- **No marker file** → Claude never produced a handoff. **Give up**: set
  `rotation_pending=false | pending_marker=null`, log `ROTATE_FAILED`.

The give-up path is **non-terminal**: it does not call `stop_run`, does not touch
tmux, does not bump generation. The tmux session stays alive at the same
generation and is re-eligible to rotate on the next idle Stop (a fresh
`relay_should_rotate` evaluation). No cap on consecutive failures — a persistent
no-handoff condition retries each Stop rather than ending the run.

Difference from current code: today the marker-present timeout path force-sets
`handoff_stop_seen=true` and defers the actual rotation to the next loop
iteration. The clean version performs the rotation directly in the timeout branch,
removing the second writer of the flag and the extra state hop.

## Affected code

- `bin/relay-supervisor.sh`
  - env default rename `RELAY_MARKER_TIMEOUT` → `RELAY_ROTATION_TIMEOUT`
  - `handle_stop_request`: init `handoff_settled=false` on request; set
    `handoff_settled=true` on the post-handoff Stop
  - `handle_pending_rotation`: read `handoff_settled`; gate on
    `marker exists AND handoff_settled`; timeout branch rotates directly (marker
    present) or gives up (no marker)
- `lib/cli.sh`
  - flag `--marker-timeout` → `--rotation-timeout` with `relay_parse_duration`
  - `RELAY_OPT_MARKER_TIMEOUT` → `RELAY_OPT_ROTATION_TIMEOUT`, help + header
    comment updated
- `bin/relay`
  - thread `RELAY_ROTATION_TIMEOUT` into supervisor env
- Tests
  - `tests/test_cli.sh`: `--rotation-timeout` parsing (valid duration, missing
    value, invalid duration); update the default/parse/usage assertions that
    currently reference `--marker-timeout` / `RELAY_OPT_MARKER_TIMEOUT`
  - `tests/test_supervisor_loop.sh`: gate still requires both marker and settled;
    rotation after post-handoff Stop; the existing `RELAY_MARKER_TIMEOUT=1`
    override (line ~51) becomes `RELAY_ROTATION_TIMEOUT=1`
  - `tests/test_integration_headless.sh`: the `RELAY_MARKER_TIMEOUT=280` override
    (line ~20) becomes `RELAY_ROTATION_TIMEOUT=280`
  - `tests/test_actuation.sh`: the four rotation-pending seeds (currently only
    `rotation_pending | pending_marker | pending_since | pending_pct`) must add
    `handoff_settled=true`, or the new gate will block their rotations
  - new/updated: timeout with marker present → rotates directly; timeout with no
    marker → `ROTATE_FAILED`, session survives and can rotate again

## Testing strategy

- **Gate correctness:** marker present but not settled → no rotation; settled →
  rotation actuates, generation bumps.
- **Direct-rotate backstop:** marker present, no Stop, age ≥ timeout → generation
  bumps, `ROTATE_STOP_TIMEOUT` logged, no dependence on a second iteration.
- **Give-up non-terminal:** no marker, age ≥ timeout → `ROTATE_FAILED`,
  `rotation_pending=false`, status NOT stopped, session still present; a
  subsequent Stop re-requests a rotation.
- **CLI:** `--rotation-timeout 90s` parses to 90; `--rotation-timeout` with no
  value errors; `--rotation-timeout bogus` errors.
- Full suite (`tests/run-all.sh`) green.

## Relationship to existing commits

This supersedes commit `c7f2180` ("gate rotation teardown on the post-handoff Stop
hook") — same correctness, cleaner names and direct timeout rotation. It is
implemented fresh on `main`, not cherry-picked. Commits 1/3/4 (graceful `/exit`
teardown) are independent and out of scope here.
