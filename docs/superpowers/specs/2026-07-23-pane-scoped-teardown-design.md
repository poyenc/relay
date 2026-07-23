# Pane-scoped teardown + graceful /exit + run-dir retention

**Date:** 2026-07-23
**Status:** Design approved, pending spec review
**Base:** `main` @ 52900be (after rotation-gate cleanup)

## Problem

relay hosts claude in a tmux pane and rotates it (respawn) or stops it. Two
problems on current `main`:

1. **Hard-kill teardown.** Rotation (`respawn-pane -k`) and stop (`kill-session`)
   kill claude's process without letting it shut down — no SessionEnd hook, no
   transcript flush, possible orphaned Bash-tool children.

2. **Session-scoped teardown contradicts the pane-only principle.** Recent fixes
   (`df9a3fc` pin rotation to the launched pane, `b91303f` scrub RELAY_* from
   session scope) established that relay supervises ONLY its own pane — the user
   may have other panes/windows in the same tmux session. But teardown and
   liveness still operate session-wide:
   - `stop_run` and `relay --stop` call `kill-session` → destroys the user's
     other panes/windows too.
   - `monitor_lifecycle` watches `has-session` → if the user has a second window,
     claude can exit (relay's pane gone) but the session lives on, so relay never
     detects the stop and never cleans up. Latent bug.

Also: run dirs are deleted the instant a run ends (EXIT trap `rm -rf`, plus
`relay_prune_dead` on next launch/list), so post-mortem artifacts (handoff,
supervisor log) are lost.

## Goal

One coherent teardown model, entirely pane-scoped:

- relay only ever ends/replaces its OWN pane (`.tmux_pane`), never the session.
  `kill-session` is removed from the codebase.
- claude gets a graceful `/exit` (its own shutdown path) before any force-kill.
- liveness is judged by relay's pane, not the session.
- ended run dirs persist for post-mortem, pruned only when 7 days stale.

Non-goals: non-blocking teardown state machine (see §Blocking); changing the
rotation gate (`handoff_settled` / `--rotation-timeout`) logic; multi-pane relay
runs (relay still hosts exactly one pane).

## Design

### 1. Pane-scoped principle

Every operation that ends or replaces claude targets relay's pane
`target="${pane:-$sess}"` (pane id from `.tmux_pane`, session fallback only for
legacy runs predating pane capture). `kill-session` is deleted from both
`bin/relay-supervisor.sh` and `lib/subcommands.sh`.

tmux fact (verified): killing the last pane of a session destroys the session
automatically. So `kill-pane` on relay's pane does the right thing in every
topology — collapses the session when relay's pane is the only one, leaves the
user's other panes/windows intact otherwise.

### 2. graceful_teardown helper

Shared by rotation and stop. All tmux calls target `target` (relay's pane).

```
graceful_teardown <gen> <tag>:
  target = .tmux_pane or .tmux_session (legacy fallback)
  pane exists? no -> return (already gone)
  sleep RELAY_ROTATE_GRACE                 # let final message stay readable
  capture-pane -p > gen-<gen>/pane.log     # persist outgoing output
  set-option -p remain-on-exit on          # dead pane lingers (so we can detect exit)
  send-keys "/exit" Enter                   # claude runs its own shutdown
  poll #{pane_dead} up to RELAY_EXIT_TIMEOUT:
     dead in time  -> log TEARDOWN_EXIT_CLEAN, return
     timed out     -> log TEARDOWN_EXIT_TIMEOUT (caller force-kills)
```

The caller finishes, differing only in the last step:

- **Rotation** (`actuate_rotation`): `respawn-pane -k -t target` (relaunches next
  gen; `-k` also force-kills a hung `/exit`), then `set-option -p remain-on-exit
  off` to restore normal behavior for the fresh generation.
- **Stop** (`stop_run`): `kill-pane -t target` (reaps the dead pane; if it was the
  last pane the session self-collapses; also force-kills a hung `/exit`). No
  `remain-on-exit` restore — the pane is going away.

`respawn-pane -k` / `kill-pane` double as the force-kill fallback, so there is no
separate kill step and no `kill-session` anywhere.

`graceful_teardown` is called from all THREE teardown sites on current main:
- `actuate_rotation` (normal gate rotation)
- `actuate_rotation` when invoked from the direct-rotate timeout path in
  `handle_pending_rotation` (the `ROTATE_STOP_TIMEOUT` branch) — teardown runs
  inside `actuate_rotation`, so this is covered automatically by wiring it there.
- `stop_run` (caps, `pane_gone`, and `relay --stop`)

### 2a. relay --stop routes through the supervisor (IPC), never kills directly

Today `relay --stop` reaches into tmux itself (`kill-session`) and SIGTERMs the
supervisor — a bare SIGTERM terminates the process and skips `stop_run`, so
`/exit` never runs. To make `--stop` graceful with ONE teardown path, the CLI
stops touching tmux and instead asks the supervisor to stop:

- `relay_cmd_stop` writes a stop marker file (e.g. `stop-run.json`, atomically
  via tmp+mv) into the run dir — mirroring how `hooks/stop-hook.sh` delivers
  `stop-request.json`. It does NOT call `kill-session` or `kill-pane`, and does
  NOT SIGTERM the supervisor on the happy path.
- The supervisor's loop notices the marker each tick (a small
  `handle_stop_marker` check, or folded into `iterate`) and calls
  `stop_run "user_stop"` → `graceful_teardown` → `kill-pane` → write
  `status`/`stopped_at` → `STOP_NOW=1` → exit. Single owner of the pane's
  lifecycle.
- `relay --stop` then polls briefly for confirmation (pane gone or
  `status=stopped`), up to ~`grace + exit_timeout + margin`. On confirmation it
  prints "stopped"; if it times out (supervisor wedged/dead), it falls back to a
  direct `kill-pane` on the recorded `.tmux_pane` and, if needed, SIGTERM the
  pid — so `--stop` can never hang forever and always leaves the pane gone.

This keeps `--stop` honest (returns only once actually stopped) while removing
`kill-session` from the CLI entirely; on the happy path the CLI touches no tmux
at all.

The stop marker must distinguish "stop this run" from the Stop-hook's
`stop-request.json` (which means "claude went idle, decide rotate/continue") — a
separate filename avoids overloading that path.

### 3. Liveness: pane-scoped monitor_lifecycle

`monitor_lifecycle` judges the run by relay's PANE, not the session.

- Run is "over" only when relay's pane no longer EXISTS (user closed it / it was
  reaped). A dead-but-present pane (`pane_dead=1`, left by our own graceful
  `/exit` mid-teardown) is NOT "user exited" — it is our teardown in progress.
  This avoids racing our own teardown (which deliberately creates a dead-present
  pane) and prevents a double-fire between `monitor_lifecycle` and
  `handle_pending_rotation`.
- Latch `pane_seen=true` once the pane is first observed alive (mirrors current
  `session_seen`). When a previously-seen pane no longer exists → `stop_run
  "pane_gone"`.
- Decision confirmed: if the user manually closes relay's pane while their own
  split keeps the session alive, relay stops the run (pane-gone = user quit
  claude; nothing left to supervise).

Pane existence test: `tmux list-panes` filtered for the pane id (present at all),
distinct from `#{pane_dead}` (present but process exited).

### 4. Run-dir retention

Ended run dirs persist; pruned only when 7 days stale.

- **Remove the EXIT-trap `rm -rf "$RUN_DIR"`** in `bin/relay-supervisor.sh`.
- On stop, `stop_run` writes `status="stopped"` and `stopped_at=<epoch>` to
  `state.json` before exiting (dir left intact).
- **`relay_prune_dead` becomes age-based:** delete a dir only if its supervisor
  PID is NOT live AND it has been ended > 7 days. "Ended-at" = `stopped_at` if
  present, else `state.json` mtime (covers crashed/killed supervisors with no
  clean stop). Live runs (supervisor PID alive) are never pruned.
- **`--list` UX unchanged:** `relay_list_live` already filters to runs with a live
  supervisor PID, so persisted ended dirs do not appear as live.

### 5. CLI & flags

Two new launch flags, duration syntax via existing `relay_parse_duration`,
threaded through `bin/relay` into the supervisor env:

| Flag | Env | Default | Meaning |
| --- | --- | --- | --- |
| `--rotate-grace <dur>` | `RELAY_ROTATE_GRACE` | `2s` | Pause before teardown so the outgoing agent's final message stays readable. |
| `--exit-timeout <dur>` | `RELAY_EXIT_TIMEOUT` | `5s` | Wait for a clean `/exit` (poll `#{pane_dead}`) before force-killing the pane. |

These are distinct from the existing `--rotation-timeout` (120s). The three knobs
map to three sequential phases of a rotation:

- `--rotation-timeout` — how long to wait for claude to WRITE the handoff and
  settle (marker + post-handoff Stop). Expiry → give up the rotation
  (non-terminal).
- `--rotate-grace` — a courtesy pause so the human can READ the final message.
- `--exit-timeout` — how long to wait for claude to EXIT after `/exit`. Expiry →
  force-kill.

### Blocking

`graceful_teardown` runs `sleep grace` + the `#{pane_dead}` poll synchronously
inside the supervisor's 0.2s tick loop, so the supervisor is unresponsive for up
to ~(grace + exit_timeout) ≈ 7s during a teardown. Accepted as-is: teardown is a
rare, terminal-ish moment; a few seconds of unresponsiveness there is harmless,
and a non-blocking `tearing_down` state machine adds real complexity for little
benefit (YAGNI). Low defaults (2s / 5s) bound the stall.

## Affected code

- `bin/relay-supervisor.sh`
  - add `RELAY_ROTATE_GRACE` / `RELAY_EXIT_TIMEOUT` env defaults
  - add `graceful_teardown <gen> <tag>` (pane-scoped)
  - `actuate_rotation`: call `graceful_teardown` before `respawn-pane -k`; restore
    `remain-on-exit off` after
  - `stop_run`: write `status`/`stopped_at`; call `graceful_teardown`; replace
    `kill-session` with `kill-pane` on the pane
  - add `handle_stop_marker` (or fold into `iterate`): detect the `stop-run.json`
    marker from `relay --stop` and call `stop_run "user_stop"`
  - `monitor_lifecycle`: judge by pane existence (`pane_seen` latch, `pane_gone`
    stop) instead of `has-session`/`session_seen`
  - remove the EXIT-trap `rm -rf "$RUN_DIR"`
- `lib/subcommands.sh`
  - `relay_cmd_stop`: drop the stop marker (atomic tmp+mv), poll for confirmation
    (pane gone / `status=stopped`) up to `grace+exit_timeout+margin`, fall back to
    direct `kill-pane` + SIGTERM only on timeout. Do NOT `kill-session`.
- `lib/rundir.sh`
  - `relay_prune_dead`: age-based (7-day) deletion using `stopped_at`/mtime
- `lib/cli.sh`
  - `--rotate-grace` / `--exit-timeout` parsing, defaults, usage, header comment
- `bin/relay`
  - thread `RELAY_ROTATE_GRACE` / `RELAY_EXIT_TIMEOUT` into supervisor env
- `tests/fake-tmux.sh`
  - add `list-panes -F '#{pane_dead}'` support (`FAKE_PANE_DEAD`, default 1) and
    pane-existence support so teardown/liveness can be exercised
- Tests
  - `test_actuation.sh`: teardown sends `/exit` to the pane, captures pane.log,
    respawns; rotation still targets the pinned pane
  - `test_supervisor_loop.sh` / new: stop path writes `status`/`stopped_at`, run
    dir NOT deleted, `kill-pane` (not `kill-session`), pane.log written
  - `test_rundir.sh`: `relay_prune_dead` keeps < 7-day ended dirs, deletes older;
    never deletes live runs
  - liveness: `pane_gone` stop; dead-but-present pane does NOT trigger stop
  - `test_cli.sh`: `--rotate-grace` / `--exit-timeout` parsing (valid, missing,
    invalid)
  - two manual harnesses adapted from `feature/graceful-exit-teardown`
    (`tests/manual/stub-teardown.sh`, `real-rotation.sh`) for real-tmux
    verification

## Testing strategy

- Teardown sequence (fake tmux): grace → capture → remain-on-exit → `/exit` →
  poll → respawn/kill-pane; assert pane.log written, correct log tokens.
- No `kill-session` anywhere: grep the tree; assert stop uses `kill-pane`.
- `relay --stop` via IPC: writes the stop marker; supervisor picks it up and runs
  graceful teardown; `--stop` confirms `status=stopped` / pane gone; fallback
  `kill-pane` fires only when the supervisor doesn't confirm in time.
- Multi-pane safety (manual/real): user split survives rotation and stop; only
  relay's pane is affected.
- Liveness: pane-gone → `stop_run "pane_gone"`; dead-but-present pane (mid-exit)
  → NOT a stop.
- Retention: ended dir persists with `status=stopped` + `stopped_at`; `--list`
  omits it; prune keeps < 7d, deletes > 7d, never touches live runs.
- CLI: `--rotate-grace 3s` → 3; `--exit-timeout` missing value / garbage → error.
- Full suite (`tests/run-all.sh`) green, including the real-`claude`
  `test_integration_headless.sh`.

## Relationship to existing work

Supersedes the teardown parts of `feature/graceful-exit-teardown` (commits
`dc853ad`, `c90c469`, `1b0c9ea`) — reuses the `/exit` + `#{pane_dead}` poll +
pane-capture ideas but re-grafts them onto current `main`'s pane-scoped model,
extends them to `kill-pane` (never `kill-session`), pane-scoped liveness, and
run-dir retention. The gate commit (`c7f2180`) was already superseded by the
merged rotation-gate cleanup.
