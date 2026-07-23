# Pane-scoped teardown + graceful /exit + retention Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all relay teardown pane-scoped (never `kill-session`): claude gets a graceful `/exit` before force-kill, liveness is judged by relay's own pane, `relay --stop` routes through the supervisor via an IPC marker, and ended run dirs persist for 7 days instead of being deleted immediately.

**Architecture:** A single `graceful_teardown <gen> <tag>` helper (grace pause → capture pane.log → `remain-on-exit on` → send `/exit` → poll `#{pane_dead}` up to a timeout) is called by both rotation (`actuate_rotation`, before `respawn-pane -k`) and stop (`stop_run`, before `kill-pane`). All tmux operations target relay's launched pane (`.tmux_pane`, session fallback for legacy runs). `monitor_lifecycle` watches pane existence (`pane_gone`) instead of the session. `relay --stop` drops a `stop-run.json` marker the supervisor acts on. The EXIT-trap `rm -rf` is removed; `relay_prune_dead` deletes ended runs only after 7 days.

**Tech Stack:** Bash (`set -euo pipefail`), jq, tmux; the repo's `tests/assert.sh` micro-framework via `tests/run-all.sh`.

## Global Constraints

- Target platform: Linux, Bash. Keep `set -euo pipefail` in `bin/relay-supervisor.sh`; `set -uo pipefail` in tests and `bin/relay`.
- `kill-session` and `kill-server` must NOT appear anywhere in `bin/` or `lib/` after this work. Teardown uses `kill-pane` (stop) or `respawn-pane -k` (rotation) on relay's pane only.
- Pane target resolution, verbatim: `pane="$(relay_state_get "$RUN_DIR" '.tmux_pane // ""')"; target="${pane:-$sess}"` (session fallback only for legacy runs with no recorded pane).
- New flag defaults, exact: `--rotate-grace` = `2s` (env `RELAY_ROTATE_GRACE`, default `2`), `--exit-timeout` = `5s` (env `RELAY_EXIT_TIMEOUT`, default `5`). Duration syntax parsed ONLY by the existing `relay_parse_duration`. These are distinct from `--rotation-timeout` (120s, unchanged).
- State JSON via `relay_state_get` / `relay_state_set` (jq). Timestamps via existing `_relay_now()` (ISO-8601 UTC) for `stopped_at`.
- Retention: ended run dirs persist; `relay_prune_dead` deletes a dir only when its supervisor PID is NOT live AND it ended > 7 days ago (7 days = 604800 s). "Ended-at" = `stopped_at` if present, else `state.json` mtime.
- Log tokens, exact and unchanged where they exist: `STOPPED reason=<r>`, `TEARDOWN_EXIT_CLEAN`, `TEARDOWN_EXIT_TIMEOUT`, `TEARDOWN_WARN`. New stop reasons: `pane_gone`, `user_stop`.
- Stop marker filename: `stop-run.json` (MUST differ from the Stop-hook's `stop-request.json`).
- Run the full suite with `bash tests/run-all.sh` (expects `ALL GREEN`).

---

### Task 1: fake-tmux support for panes + graceful exit

The test double must model pane liveness (`#{pane_dead}`) and pane existence so later tasks can exercise teardown and pane-scoped liveness deterministically. This is scaffolding every later test depends on, so it lands first.

**Files:**
- Modify: `tests/fake-tmux.sh` (currently 11 lines)

**Interfaces:**
- Consumes: env `FAKE_TMUX_LOG`, `FAKE_HAS_SESSION`, `FAKE_TMUX_PANE` (existing).
- Produces: new env knobs `FAKE_PANE_DEAD` (default `1` = process exited, so the `/exit` poll returns immediately in tests) and `FAKE_PANE_MISSING` (default `0` = pane exists; `1` = `list-panes` shows nothing, i.e. pane gone). `list-panes -F '#{pane_dead}'` prints `$FAKE_PANE_DEAD`; a bare/existence `list-panes` prints one pane line unless `FAKE_PANE_MISSING=1`.

- [ ] **Step 1: Write the fake-tmux behavior (no separate test; it is exercised by Task 2+)**

Replace the whole `case` in `tests/fake-tmux.sh` with:
```bash
#!/usr/bin/env bash
# Test double for tmux: logs its argv (one line per call) to $FAKE_TMUX_LOG.
# has-session exits per $FAKE_HAS_SESSION (default 1=alive).
# list-panes models pane liveness/existence for teardown + lifecycle tests:
#   FAKE_PANE_MISSING=1 -> pane gone (no output; mimics a closed pane)
#   FAKE_PANE_DEAD (default 1) -> value of #{pane_dead} for a present pane
# Everything else exits 0.
printf '%s\n' "$*" >> "${FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  has-session) [ "${FAKE_HAS_SESSION:-1}" = "1" ] && exit 0 || exit 1 ;;
  # new-session -P -F '#{pane_id}' prints the launched pane id on stdout
  new-session) case " $* " in *" -P "*) echo "${FAKE_TMUX_PANE:-%0}" ;; esac; exit 0 ;;
  list-panes)
    [ "${FAKE_PANE_MISSING:-0}" = "1" ] && exit 0   # pane gone: print nothing
    # -F '#{pane_dead}' -> liveness; any other -F / bare -> a present-pane line
    case " $* " in
      *"#{pane_dead}"*) printf '%s\n' "${FAKE_PANE_DEAD:-1}" ;;
      *) printf '%%0\n' ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
```

- [ ] **Step 2: Sanity-check the double directly**

Run:
```bash
FAKE_PANE_DEAD=1 bash tests/fake-tmux.sh list-panes -t %7 -F '#{pane_dead}'
FAKE_PANE_MISSING=1 bash tests/fake-tmux.sh list-panes -t %7 -F '#{pane_dead}'; echo "missing-exit=$?"
bash tests/fake-tmux.sh list-panes -t %7
```
Expected: first prints `1`; second prints nothing (exit 0); third prints `%0`.

- [ ] **Step 3: Run the full suite (must stay green — no supervisor changes yet)**

Run: `bash tests/run-all.sh`
Expected: `ALL GREEN` (the new `list-panes` arm is not yet exercised by supervisor code).

- [ ] **Step 4: Commit**

```bash
git add tests/fake-tmux.sh
git commit -m "test: fake-tmux models pane liveness and existence"
```

---

### Task 2: graceful_teardown helper + wire into rotation

Add the pane-scoped `graceful_teardown` and call it from `actuate_rotation` before `respawn-pane -k`. This covers BOTH rotation entry points (normal gate and direct-rotate timeout) because both go through `actuate_rotation`. Stop is Task 3.

**Files:**
- Modify: `bin/relay-supervisor.sh` — env defaults (after line 12), new helper (before `stop_run` at line 100), `actuate_rotation` (lines 126-130)
- Modify: `bin/relay` — env threading (line 48)
- Modify: `lib/cli.sh` — flags (after line 38), header comment (line 60), defaults (after line 70), parse cases (after line 96)
- Modify: `tests/test_actuation.sh` — section 1/2 assertions (lines 22-43)
- Modify: `tests/test_cli.sh` — default + full-parse + usage assertions

**Interfaces:**
- Consumes: `.tmux_pane`, `.tmux_session`, existing `log`, `relay_state_get`; env `RELAY_ROTATE_GRACE`/`RELAY_EXIT_TIMEOUT`; `relay_parse_duration` (in `lib/cli.sh`).
- Produces: `graceful_teardown <gen> <tag>` (pane-scoped: grace → capture → remain-on-exit → /exit → poll #{pane_dead}); flags `--rotate-grace`/`--exit-timeout`; parse vars `RELAY_OPT_ROTATE_GRACE`/`RELAY_OPT_EXIT_TIMEOUT`.

- [ ] **Step 1: Add CLI flags (failing test first)**

In `tests/test_cli.sh`, add after line 22 (the `default marker`/rotation-timeout defaults block near line 21):
```bash
assert_eq "$RELAY_OPT_ROTATE_GRACE" "2" "default rotate-grace 2"
assert_eq "$RELAY_OPT_EXIT_TIMEOUT" "5" "default exit-timeout 5"
```
Extend the full-parse invocation (the `relay_parse_args --rotate-at 45 ...` line, ~29-30) to include `--rotate-grace 3s --exit-timeout 8s` before the `--`, and add after its assertions (~line 41):
```bash
assert_eq "$RELAY_OPT_ROTATE_GRACE" "3" "rotate-grace duration -> seconds"
assert_eq "$RELAY_OPT_EXIT_TIMEOUT" "8" "exit-timeout duration -> seconds"
```
Add error cases after the existing rotation-timeout error block (~line 70):
```bash
if relay_parse_args --rotate-grace; then assert_eq bad ok "rotate-grace needs value"; else assert_ok "rotate-grace missing value rejected"; fi
if relay_parse_args --exit-timeout bogus; then assert_eq bad ok "exit-timeout rejects garbage"; else assert_ok "exit-timeout invalid duration rejected"; fi
```
Add usage assertions after the rotation-timeout usage check (~line 96 area):
```bash
assert_contains "$u" "--rotate-grace" "usage: rotate-grace"
assert_contains "$u" "--exit-timeout" "usage: exit-timeout"
```

- [ ] **Step 2: Run the CLI test to verify it fails**

Run: `bash tests/test_cli.sh`
Expected: FAIL — `RELAY_OPT_ROTATE_GRACE` unset, usage missing the flags.

- [ ] **Step 3: Add the flags to `lib/cli.sh`**

Add usage lines after line 38 (`--rotation-timeout ...` block, before `--switch`):
```bash
  --rotate-grace <dur>   Pause before teardown so the outgoing agent's final
                         message stays readable (default 2s).
  --exit-timeout <dur>   Wait for a clean /exit before force-killing (default 5s).
```
Update the header comment (line 60) to append the two vars:
```bash
#   RELAY_OPT_ROTATE_AT / MAX_GEN / MAX_RUNTIME_S / MAX_COST / ROTATION_TIMEOUT
#   RELAY_OPT_ROTATE_GRACE / EXIT_TIMEOUT / AUTO_CONTINUE
```
Add defaults after line 70 (`RELAY_OPT_ROTATION_TIMEOUT="120"` region):
```bash
  RELAY_OPT_ROTATE_GRACE="2"
  RELAY_OPT_EXIT_TIMEOUT="5"
```
Add parse cases after the `--rotation-timeout` case (~line 96), mirroring it:
```bash
      --rotate-grace)
        [ $# -ge 2 ] || { RELAY_PARSE_ERR="--rotate-grace requires a value"; return 1; }
        dur="$(relay_parse_duration "$2")" || { RELAY_PARSE_ERR="invalid --rotate-grace: $2"; return 1; }
        RELAY_OPT_ROTATE_GRACE="$dur"; saw_launch_flag=1; shift 2 ;;
      --exit-timeout)
        [ $# -ge 2 ] || { RELAY_PARSE_ERR="--exit-timeout requires a value"; return 1; }
        dur="$(relay_parse_duration "$2")" || { RELAY_PARSE_ERR="invalid --exit-timeout: $2"; return 1; }
        RELAY_OPT_EXIT_TIMEOUT="$dur"; saw_launch_flag=1; shift 2 ;;
```

- [ ] **Step 4: Verify the CLI test passes**

Run: `bash tests/test_cli.sh`
Expected: PASS.

- [ ] **Step 5: Thread env in `bin/relay`**

Replace line 48:
```bash
  RELAY_ROTATION_TIMEOUT="$RELAY_OPT_ROTATION_TIMEOUT" RELAY_TMUX="$RELAY_TMUX" \
    RELAY_ROTATE_GRACE="$RELAY_OPT_ROTATE_GRACE" RELAY_EXIT_TIMEOUT="$RELAY_OPT_EXIT_TIMEOUT" \
```
(keep the continuation line that follows: `"$RELAY_SUPERVISOR_BIN" --run-dir "$rd" ...`)

- [ ] **Step 6: Add env defaults in the supervisor**

In `bin/relay-supervisor.sh`, after line 12 (`: "${RELAY_NUDGE_DELAY:=2}"`):
```bash
# Graceful-teardown knobs (threaded in by bin/relay). GRACE: seconds to let the
# outgoing generation's final message finish rendering before /exit. EXIT_TIMEOUT:
# seconds to wait for a clean /exit (poll #{pane_dead}) before force-killing.
: "${RELAY_ROTATE_GRACE:=2}"
: "${RELAY_EXIT_TIMEOUT:=5}"
```

- [ ] **Step 7: Rewrite the actuation test for graceful rotation (failing first)**

In `tests/test_actuation.sh`, replace the section-1 run+asserts (lines 22-30) to also assert the teardown sequence, and set `RELAY_ROTATE_GRACE=0` so tests don't sleep:
```bash
FAKE_TMUX_LOG="$log" RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd" --once
assert_eq "$(relay_state_get "$rd" '.generation')" "2" "gen bumped after actuated rotation"
assert_eq "$(relay_state_get "$rd" '.rotation_pending')" "false" "pending cleared"
assert_contains "$(cat "$log")" "send-keys -t %7 /exit Enter" "graceful /exit sent to the launched pane"
assert_contains "$(cat "$log")" "capture-pane -p -t %7" "pane captured before teardown"
assert_contains "$(cat "$log")" "respawn-pane -k -t %7" "respawn-pane targets the launched pane"
assert_contains "$(cat "$log")" "RELAY_HANDOFF_PATH=$rd/gen-1/handoff.md" "next-gen handoff env passed"
assert_contains "$(cat "$log")" "RELAY_RUN_DIR=$rd" "run dir env re-exported"
assert_contains "$(cat "$log")" "claude --plugin-dir /x" "launch cmd reused on respawn"
assert_contains "$(cat "$log")" "send-keys -t %7 Continue from the handoff above." "auto-continue nudge sent to the launched pane"
assert_file_exists "$rd/gen-1/pane.log" "pane output persisted to gen dir"
```
Update section 2's run line (line 39) to add `RELAY_ROTATE_GRACE=0`, and its asserts (lines 42-43):
```bash
FAKE_TMUX_LOG="$log2" RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd2" --once
# no .tmux_pane seeded -> falls back to the session target (legacy runs)
assert_contains "$(cat "$log2")" "respawn-pane -k -t relay-test" "respawn falls back to session when no pane stored"
assert_contains "$(cat "$log2")" "send-keys -t relay-test /exit Enter" "graceful /exit still sent"
assert_eq "$(grep -c 'Continue from the handoff' "$log2")" "0" "no nudge when auto-continue off"
```

- [ ] **Step 8: Run the actuation test to verify it fails**

Run: `bash tests/test_actuation.sh`
Expected: FAIL — no `/exit`, `capture-pane`, or `pane.log` yet.

- [ ] **Step 9: Add `graceful_teardown` and call it in `actuate_rotation`**

In `bin/relay-supervisor.sh`, insert before `stop_run` (line 100, before its comment):
```bash
# Ask the live claude in the hosted pane to /exit so it runs its own shutdown
# path (SessionEnd hook, transcript flush, no orphaned Bash-tool children) before
# the caller force-kills. Pane-scoped: targets relay's launched pane, never the
# session, so a user split/window is untouched. Sequence: grace pause (final
# message stays readable) -> capture pane to a log -> remain-on-exit=on (dead pane
# lingers so we can detect the exit) -> /exit -> poll #{pane_dead} up to
# RELAY_EXIT_TIMEOUT. Leaves the dead-or-dying pane for the caller to respawn
# (rotation) or kill-pane (stop). No-op if the pane is already gone. Logs which path ran.
graceful_teardown() {  # <gen> <tag>
  local gen="$1" tag="$2" sess pane target i
  sess="$(relay_state_get "$RUN_DIR" '.tmux_session // ""')"
  [ -n "$sess" ] || return 0
  pane="$(relay_state_get "$RUN_DIR" '.tmux_pane // ""')"
  target="${pane:-$sess}"
  [ "$RELAY_ROTATE_GRACE" = "0" ] || sleep "$RELAY_ROTATE_GRACE"
  mkdir -p "$RUN_DIR/gen-$gen"
  "$RELAY_TMUX" capture-pane -p -t "$target" > "$RUN_DIR/gen-$gen/pane.log" 2>/dev/null \
    || log "TEARDOWN_WARN capture_failed target=$target tag=$tag"
  "$RELAY_TMUX" set-option -p -t "$target" remain-on-exit on 2>/dev/null || true
  "$RELAY_TMUX" send-keys -t "$target" "/exit" Enter 2>/dev/null || true
  for i in $(seq 1 "$RELAY_EXIT_TIMEOUT"); do
    if [ "$("$RELAY_TMUX" list-panes -t "$target" -F '#{pane_dead}' 2>/dev/null | head -n1)" = "1" ]; then
      log "TEARDOWN_EXIT_CLEAN gen=$gen tag=$tag"; return 0
    fi
    sleep 1
  done
  log "TEARDOWN_EXIT_TIMEOUT gen=$gen tag=$tag force=1"
}
```
In `actuate_rotation`, insert the teardown call immediately before the `respawn-pane -k` line (line 126), and restore `remain-on-exit off` after the respawn block. Replace lines 126-130 with:
```bash
  graceful_teardown "$from_gen" "rotate"
  # respawn-pane -k relaunches the next gen; -k force-kills if /exit hung.
  "$RELAY_TMUX" respawn-pane -k -t "$target" \
    -e "RELAY_RUN_DIR=$RUN_DIR" \
    -e "RELAY_STATE=$RUN_DIR/statusline.json" \
    -e "RELAY_HANDOFF_PATH=$handoff" \
    "$cmd" 2>/dev/null || log "ACTUATE_WARN respawn_failed target=$target"
  # Restore default so a future manual exit collapses the pane as usual.
  "$RELAY_TMUX" set-option -p -t "$target" remain-on-exit off 2>/dev/null || true
```

- [ ] **Step 10: Run actuation + CLI + full suite**

Run: `bash tests/test_actuation.sh && bash tests/test_cli.sh && bash tests/run-all.sh`
Expected: actuation PASS, cli PASS, `ALL GREEN`. (Sections 3-6 of test_actuation still assert `kill-session`/`session_seen`; they are rewritten in Task 3. If they fail here, STOP and note it — they are the next task's responsibility, but the suite must be green before committing. Sequence Task 3's test edits together: if section-3+ break, complete Task 3 before the green-bar commit. See Task 3.)

Note: Steps 9-10 leave `test_actuation.sh` sections 3-6 (stop/liveness) still on the old `kill-session`/`session_gone` behavior, which is unchanged so far — they still pass. Only sections 1-2 (rotation) changed here. Confirm `ALL GREEN`.

- [ ] **Step 11: Add the /exit-timeout (force-kill) coverage (failing first)**

Every other test sets `FAKE_PANE_DEAD=1` so `/exit` looks instant and only the
clean path runs. This step exercises the branch where `/exit` HANGS: the poll
must time out (`TEARDOWN_EXIT_TIMEOUT`) and the caller must still respawn (the
`-k` force-kill fallback). Append a new section to `tests/test_actuation.sh`
after section 2 (before section 3):
```bash
# ---------- 2b. /exit hangs -> poll times out, force-kill via respawn still fires ----------
rdt="$(mktemp -d)"; mkdir -p "$rdt/gen-1"
relay_state_init "$rdt" 60 "" "" "" $$
seed_live "$rdt" true
relay_state_set "$rdt" '.tmux_pane="%7" | .rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70 | .handoff_settled=true'
: > "$rdt/gen-1/handoff.ready"
logt="$rdt/tmux.log"; : > "$logt"
# FAKE_PANE_DEAD=0 -> pane never reports dead -> poll exhausts RELAY_EXIT_TIMEOUT
FAKE_TMUX_LOG="$logt" FAKE_PANE_DEAD=0 RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 RELAY_ROTATE_GRACE=0 RELAY_EXIT_TIMEOUT=1 \
  bash bin/relay-supervisor.sh --run-dir "$rdt" --once
assert_contains "$(cat "$rdt/supervisor.log")" "TEARDOWN_EXIT_TIMEOUT" "hung /exit logs timeout"
assert_contains "$(cat "$logt")" "respawn-pane -k -t %7" "force-kill respawn still fires after timeout"
assert_eq "$(relay_state_get "$rdt" '.generation')" "2" "rotation completes despite hung /exit"
```

- [ ] **Step 12: Run actuation to verify the new section fails, then passes**

Run: `bash tests/test_actuation.sh`
Expected: with the Step 9 code already in place, this section PASSES (the poll loop
+ `TEARDOWN_EXIT_TIMEOUT` log + respawn fallback already exist). If it FAILS,
the poll/timeout logic is wrong — fix `graceful_teardown` before committing. Then
`bash tests/run-all.sh` → `ALL GREEN`.

- [ ] **Step 13: Commit**

```bash
git add bin/relay-supervisor.sh bin/relay lib/cli.sh tests/test_actuation.sh tests/test_cli.sh
git commit -m "feat: graceful /exit teardown before rotation respawn; add --rotate-grace/--exit-timeout"
```

---

### Task 3: pane-scoped stop + liveness (kill-pane, pane_gone)

Convert `stop_run` to graceful teardown + `kill-pane` (no `kill-session`), write `status`/`stopped_at`, and switch `monitor_lifecycle` to pane existence.

**Files:**
- Modify: `bin/relay-supervisor.sh` — `stop_run` (lines 100-107), `monitor_lifecycle` (lines 200-216)
- Modify: `tests/test_actuation.sh` — sections 3, 4, 5, 6 (lines 45-99)

**Interfaces:**
- Consumes: `graceful_teardown` (Task 2), `.tmux_pane`, `_relay_now` is NOT available here (state.sh helper, but supervisor sources state.sh — confirm; use `date +%s` for `stopped_at` epoch to match `pending_since` style).
- Produces: `stop_run` writes `.status="stopped"` + `.stopped_at=<epoch>`, teardown + `kill-pane`; `monitor_lifecycle` uses `pane_seen`/`pane_gone`.

- [ ] **Step 1: Rewrite stop + liveness tests (failing first)**

In `tests/test_actuation.sh`:

Update `seed_live` (line 11) to also seed a pane and use pane_seen:
```bash
seed_live() {  # <rd> <auto_continue>
  relay_state_set "$1" ".tmux_session=\"relay-test\" | .tmux_pane=\"%7\" | .launch_cmd=\"claude --plugin-dir /x\" | .auto_continue=$2 | .pane_seen=true"
}
```
(Section 1 sets `.tmux_pane="%7"` separately at line 18 — that is now redundant but harmless; leave it.)

Replace section 3 asserts (lines 54-58):
```bash
assert_eq "$(relay_state_get "$rd3" '.generation')" "1" "gen NOT bumped when cap hit"
assert_eq "$(relay_state_get "$rd3" '.status')" "stopped" "run marked stopped on cap"
assert_contains "$(cat "$rd3/supervisor.log")" "STOPPED reason=cap:gen" "cap STOP logged"
assert_contains "$(cat "$log3")" "kill-pane -t %7" "pane killed on cap stop"
assert_eq "$(grep -c 'kill-session' "$log3")" "0" "never kill-session"
assert_eq "$(grep -c 'respawn-pane' "$log3")" "0" "no respawn when cap hit"
```
Add `RELAY_ROTATE_GRACE=0` to the section-3 run line (line 52) and section-3b run line (line 68).

Replace section 4 (lines 73-81) — liveness now keys on pane existence:
```bash
# ---------- 4. liveness: pane gone + seen before -> STOPPED ----------
rd4="$(mktemp -d)"
relay_state_init "$rd4" 60 "" "" "" $$
seed_live "$rd4" true    # sets pane_seen=true
log4="$rd4/tmux.log"; : > "$log4"
FAKE_TMUX_LOG="$log4" FAKE_PANE_MISSING=1 RELAY_TMUX="$FAKE" RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd4" --once
assert_eq "$(relay_state_get "$rd4" '.status')" "stopped" "pane-gone detected -> stopped"
assert_contains "$(cat "$rd4/supervisor.log")" "STOPPED reason=pane_gone" "pane-gone STOP logged"
```

Replace section 5 (lines 83-90) — pane never seen:
```bash
# ---------- 5. liveness: pane never came up -> do NOT stop ----------
rd5="$(mktemp -d)"
relay_state_init "$rd5" 60 "" "" "" $$
relay_state_set "$rd5" '.tmux_session="relay-test" | .tmux_pane="%7"'   # configured but pane_seen not set
log5="$rd5/tmux.log"; : > "$log5"
FAKE_TMUX_LOG="$log5" FAKE_PANE_MISSING=1 RELAY_TMUX="$FAKE" \
  bash bin/relay-supervisor.sh --run-dir "$rd5" --once
assert_eq "$(relay_state_get "$rd5" '.status // "none"')" "none" "no stop before pane first seen"
```

Replace section 6 (lines 92-99) — latch pane_seen:
```bash
# ---------- 6. liveness latches pane_seen when alive ----------
rd6="$(mktemp -d)"
relay_state_init "$rd6" 60 "" "" "" $$
relay_state_set "$rd6" '.tmux_session="relay-test" | .tmux_pane="%7"'
log6="$rd6/tmux.log"; : > "$log6"
FAKE_TMUX_LOG="$log6" FAKE_PANE_MISSING=0 RELAY_TMUX="$FAKE" \
  bash bin/relay-supervisor.sh --run-dir "$rd6" --once
assert_eq "$(relay_state_get "$rd6" '.pane_seen')" "true" "pane_seen latched when alive"

# ---------- 7. dead-but-present pane (our own teardown) is NOT a stop ----------
rd7="$(mktemp -d)"
relay_state_init "$rd7" 60 "" "" "" $$
seed_live "$rd7" true
log7="$rd7/tmux.log"; : > "$log7"
FAKE_TMUX_LOG="$log7" FAKE_PANE_MISSING=0 FAKE_PANE_DEAD=1 RELAY_TMUX="$FAKE" \
  bash bin/relay-supervisor.sh --run-dir "$rd7" --once
assert_eq "$(relay_state_get "$rd7" '.status // "none"')" "none" "dead-but-present pane does NOT trigger stop"
```

- [ ] **Step 2: Run the actuation test to verify it fails**

Run: `bash tests/test_actuation.sh`
Expected: FAIL — stop still uses `kill-session`; liveness still keys on session.

- [ ] **Step 3: Rewrite `stop_run` (pane-scoped, graceful, persist state)**

Replace lines 98-107:
```bash
# Stop the run: graceful /exit teardown, then kill-pane (pane-scoped, never the
# session). Persist status/stopped_at so the dir survives for post-mortem; the
# loop exits after this. relay_prune_dead reaps the dir after 7 days.
stop_run() {  # <reason>
  local pane sess target gen
  sess="$(relay_state_get "$RUN_DIR" '.tmux_session // ""')"
  pane="$(relay_state_get "$RUN_DIR" '.tmux_pane // ""')"
  target="${pane:-$sess}"
  gen="$(relay_state_get "$RUN_DIR" '.generation')"
  graceful_teardown "$gen" "stop"
  relay_state_set "$RUN_DIR" ".status=\"stopped\" | .stopped_at=$(date +%s)"
  log "STOPPED reason=$1"
  # kill-pane reaps the (now dead) pane; if it was the last pane the session
  # self-collapses. Never kill-session - a user's other panes/windows survive.
  [ -n "$target" ] && "$RELAY_TMUX" kill-pane -t "$target" 2>/dev/null || true
  STOP_NOW=1
}
```

- [ ] **Step 4: Rewrite `monitor_lifecycle` (pane existence)**

Replace lines 200-216:
```bash
# Lifecycle monitor: once relay's pane has been seen alive, its DISAPPEARANCE
# (pane no longer exists) means the user closed it - stop the run. A dead-but-
# present pane (#{pane_dead}=1, left by our own graceful /exit mid-teardown) is
# NOT "user quit" and is ignored here. Pane-scoped so a user's other panes are
# irrelevant to relay's liveness.
monitor_lifecycle() {
  local sess pane target seen
  sess="$(relay_state_get "$RUN_DIR" '.tmux_session // ""')"
  [ -n "$sess" ] || return 0
  pane="$(relay_state_get "$RUN_DIR" '.tmux_pane // ""')"
  target="${pane:-$sess}"
  # Pane present at all? (bare list-panes lists present panes, dead or alive.)
  if [ -n "$("$RELAY_TMUX" list-panes -t "$target" -F '#{pane_id}' 2>/dev/null)" ]; then
    seen="$(relay_state_get "$RUN_DIR" '.pane_seen // false')"
    [ "$seen" = "true" ] || relay_state_set "$RUN_DIR" '.pane_seen=true'
    return 0
  fi
  # pane absent
  if [ "$(relay_state_get "$RUN_DIR" '.pane_seen // false')" = "true" ]; then
    stop_run "pane_gone"
  fi
}
```

- [ ] **Step 5: Run actuation + full suite**

Run: `bash tests/test_actuation.sh && bash tests/run-all.sh`
Expected: actuation PASS; `ALL GREEN`. (`test_subcommands.sh` still asserts `kill-session` for `--stop` — that is Task 4. If it fails here, proceed to Task 4 and land them together; do NOT commit a red bar. If green, commit now.)

- [ ] **Step 6: Verify no kill-session remains in the supervisor**

Run: `grep -n "kill-session\|session_seen\|session_gone" bin/relay-supervisor.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add bin/relay-supervisor.sh tests/test_actuation.sh
git commit -m "feat: pane-scoped stop (kill-pane) and pane-existence liveness; persist stopped state"
```

---

### Task 4: relay --stop via IPC marker

`relay --stop` drops a `stop-run.json` marker instead of `kill-session`+SIGTERM; the supervisor acts on it via graceful `stop_run`; `--stop` polls for confirmation with a `kill-pane` fallback.

**Files:**
- Modify: `bin/relay-supervisor.sh` — `iterate` (lines 218-223): add a stop-marker check
- Modify: `lib/subcommands.sh` — `relay_cmd_stop` (lines 99-112)
- Modify: `tests/test_subcommands.sh` — stop test (lines 58-64): CLI fallback path
- Modify: `tests/test_actuation.sh` — add section 8: supervisor consumes the marker (happy path)

**Interfaces:**
- Consumes: `stop_run` (Task 3); state `.tmux_pane`, `.supervisor_pid`, `.status`.
- Produces: `stop-run.json` marker protocol; supervisor `handle_stop_marker`; `relay_cmd_stop` confirmation-poll + fallback.

- [ ] **Step 1: Rewrite the stop subcommand test (failing first)**

In `tests/test_subcommands.sh`, the seeded runs have no live pane to poll, so `relay_cmd_stop` will fall back after its poll window. Set a short fallback and assert the marker + fallback. Replace lines 58-64:
```bash
# --- stop: drops the stop-run marker, signals + reaps via fallback ---
stoplog="$TMPDIR/stop-tmux.log"; : > "$stoplog"
# short confirm window so the test's fallback fires fast (no live supervisor to
# consume the marker here). RELAY_STOP_CONFIRM_S caps the poll.
FAKE_TMUX_LOG="$stoplog" RELAY_STOP_CONFIRM_S=1 relay_cmd_stop run-2026-bbbb >/dev/null 2>&1
assert_file_exists "$live2_rd/stop-run.json" "stop marker written"
assert_eq "$(grep -c 'kill-session' "$stoplog")" "0" "stop never kill-session"
assert_contains "$(cat "$stoplog")" "kill-pane" "stop fallback reaps the pane"
# supervisor (LIVE2) should have been signalled dead by the fallback
sleep 0.3
if kill -0 "$LIVE2" 2>/dev/null; then assert_eq alive dead "stop should kill supervisor"; else assert_ok "supervisor terminated by stop"; fi
```

- [ ] **Step 2: Run the subcommands test to verify it fails**

Run: `bash tests/test_subcommands.sh`
Expected: FAIL — no `stop-run.json`, still logs `kill-session`.

- [ ] **Step 3: Add stop-marker handling in the supervisor**

In `bin/relay-supervisor.sh`, add a handler function (place it just before `iterate`, ~line 218):
```bash
# relay --stop drops a stop-run marker; act on it with the one graceful stop path.
handle_stop_marker() {
  [ -f "$RUN_DIR/stop-run.json" ] || return 0
  rm -f "$RUN_DIR/stop-run.json"
  stop_run "user_stop"
}
```
Add it as the FIRST stage in `iterate` (so a stop request wins over a pending rotation):
```bash
iterate() {
  handle_stop_marker    || log "ITERATE_ERROR stage=handle_stop_marker rc=$?"
  handle_stop_request   || log "ITERATE_ERROR stage=handle_stop_request rc=$?"
  handle_pending_rotation || log "ITERATE_ERROR stage=handle_pending_rotation rc=$?"
  monitor_lifecycle     || log "ITERATE_ERROR stage=monitor_lifecycle rc=$?"
  return 0
}
```

- [ ] **Step 4: Rewrite `relay_cmd_stop` (IPC + confirm poll + fallback)**

Replace `relay_cmd_stop` (lines 99-112) in `lib/subcommands.sh`:
```bash
relay_cmd_stop() {  # <id-or-prefix>
  local rd sess pane target pid i confirm
  rd="$(relay_resolve_run_id "$1")" || return 1
  sess="$(relay_state_get "$rd" '.tmux_session')"
  pane="$(relay_state_get "$rd" '.tmux_pane // ""')"
  target="${pane:-$sess}"
  pid="$(relay_state_get "$rd" '.supervisor_pid')"
  # Ask the supervisor to stop gracefully (it runs /exit teardown + kill-pane).
  # Marker mirrors the Stop-hook IPC; atomic tmp+mv.
  printf '{"reason":"user_stop"}' > "$rd/stop-run.json.tmp" 2>/dev/null \
    && mv "$rd/stop-run.json.tmp" "$rd/stop-run.json" 2>/dev/null || true
  # Poll for confirmation (status=stopped). Bounded so --stop never hangs.
  confirm=0
  for i in $(seq 1 "${RELAY_STOP_CONFIRM_S:-10}"); do
    [ "$(relay_state_get "$rd" '.status // "")" = "stopped" ] && { confirm=1; break; }
    sleep 1
  done
  if [ "$confirm" != "1" ]; then
    # Supervisor didn't confirm (wedged/dead). Reap the pane ourselves and signal
    # the pid. Never kill-session - only relay's pane.
    [ -n "$target" ] && "$RELAY_TMUX" kill-pane -t "$target" 2>/dev/null || true
    if [ -n "$pid" ] && [ "$pid" != "null" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  fi
  echo "relay: stopped $(basename "$rd")."
}
```

- [ ] **Step 5: Add the supervisor-side happy-path test (marker consumed → graceful stop)**

Step 1's subcommands test only covers the CLI fallback (no live supervisor). This
step covers the PRIMARY flow — the supervisor picks up `stop-run.json` and runs the
one graceful stop path — at the supervisor level via `--once`. Append to
`tests/test_actuation.sh` after section 7:
```bash
# ---------- 8. stop-run marker -> supervisor runs graceful stop (kill-pane) ----------
rds="$(mktemp -d)"; mkdir -p "$rds/gen-1"
relay_state_init "$rds" 60 "" "" "" $$
seed_live "$rds" true
printf '{"reason":"user_stop"}' > "$rds/stop-run.json"
logs="$rds/tmux.log"; : > "$logs"
FAKE_TMUX_LOG="$logs" RELAY_TMUX="$FAKE" RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rds" --once
assert_eq "$(relay_state_get "$rds" '.status')" "stopped" "marker -> run stopped"
assert_contains "$(cat "$rds/supervisor.log")" "STOPPED reason=user_stop" "user_stop logged"
assert_contains "$(cat "$logs")" "send-keys -t %7 /exit Enter" "graceful /exit on stop"
assert_contains "$(cat "$logs")" "kill-pane -t %7" "stop reaps relay's pane"
assert_eq "$(grep -c 'kill-session' "$logs")" "0" "stop never kill-session"
assert_file_absent "$rds/stop-run.json" "marker consumed"
assert_file_exists "$rds/state.json" "run dir persists after stop (not deleted)"
```

- [ ] **Step 6: Run actuation + subcommands + full suite**

Run: `bash tests/test_actuation.sh && bash tests/test_subcommands.sh && bash tests/run-all.sh`
Expected: PASS; `ALL GREEN`.

- [ ] **Step 7: Verify no kill-session anywhere in bin/lib**

Run: `grep -rn "kill-session\|kill-server" bin/ lib/`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add bin/relay-supervisor.sh lib/subcommands.sh tests/test_subcommands.sh tests/test_actuation.sh
git commit -m "feat: relay --stop routes through supervisor via stop-run marker (no kill-session)"
```

---

### Task 5: run-dir retention (no EXIT rm, age-based prune)

Remove the immediate delete; persist ended dirs; prune only after 7 days.

**Files:**
- Modify: `bin/relay-supervisor.sh` — EXIT trap (line 227)
- Modify: `lib/rundir.sh` — `relay_prune_dead` (lines 44-55)
- Modify: `tests/test_rundir.sh` — prune assertions (lines 22-39)

**Interfaces:**
- Consumes: `relay_pid_is_supervisor` (existing), `.stopped_at` (Task 3), `state.json` mtime.
- Produces: age-based `relay_prune_dead` (7-day retention); supervisor no longer deletes its run dir on exit.

- [ ] **Step 1: Rewrite the rundir prune test (failing first)**

In `tests/test_rundir.sh`, replace the dead-run seeding + prune assertions (lines 22-39) to distinguish recent-ended from stale-ended:
```bash
echo "{\"supervisor_pid\": $LIVE, \"generation\": 2}" > "$rd/state.json"
# recently-ended run (stopped 1h ago): must SURVIVE prune
recent="$(relay_root)/run-20200101-recent"; mkdir -p "$recent"
echo "{\"supervisor_pid\": 999999, \"generation\": 1, \"status\": \"stopped\", \"stopped_at\": $(( $(date +%s) - 3600 ))}" > "$recent/state.json"
# stale-ended run (stopped 8 days ago): must be PRUNED
stale="$(relay_root)/run-20200101-stale"; mkdir -p "$stale"
echo "{\"supervisor_pid\": 999999, \"generation\": 1, \"status\": \"stopped\", \"stopped_at\": $(( $(date +%s) - 8*86400 ))}" > "$stale/state.json"

live="$(relay_list_live)"
assert_contains "$live" "$rd" "live run listed"
assert_eq "$(printf '%s' "$live" | grep -c "$recent")" "0" "ended run not listed as live"

# PID-recycling guard (unchanged)
imposter="$(relay_root)/run-20200101-imposter"; mkdir -p "$imposter"
echo "{\"supervisor_pid\": $IMP, \"generation\": 1}" > "$imposter/state.json"
assert_eq "$(relay_list_live | grep -c "$imposter")" "0" "recycled-PID imposter not listed"

relay_prune_dead
assert_file_exists "$rd" "live run survives prune"
assert_file_exists "$recent" "recently-ended run survives prune (< 7 days)"
assert_file_absent "$stale" "stale-ended run pruned (> 7 days)"
```

- [ ] **Step 2: Run the rundir test to verify it fails**

Run: `bash tests/test_rundir.sh`
Expected: FAIL — current prune deletes both `recent` and `stale` (any dead PID).

- [ ] **Step 3: Make `relay_prune_dead` age-based**

Replace `relay_prune_dead` (lines 44-55) in `lib/rundir.sh`:
```bash
# Prune ended run dirs, but only when stale (> 7 days since they ended). A run is
# "ended" when its supervisor PID is not live; "ended-at" is .stopped_at if
# present, else the state.json mtime. Live runs are never pruned. This keeps
# recent runs on disk for post-mortem (handoff, pane.log, supervisor.log).
relay_prune_dead() {
  local root; root="$(relay_root)"; local d pid ended now age
  local ttl=604800   # 7 days in seconds
  [ -d "$root" ] || return 0
  now="$(date +%s)"
  for d in "$root"/*; do
    [ -d "$d" ] || continue
    if [ -f "$d/state.json" ]; then
      pid="$(jq -r '.supervisor_pid // empty' "$d/state.json" 2>/dev/null)"
      if [ -n "$pid" ] && relay_pid_is_supervisor "$pid" "$d"; then continue; fi
      ended="$(jq -r '.stopped_at // empty' "$d/state.json" 2>/dev/null)"
      [ -n "$ended" ] || ended="$(stat -c %Y "$d/state.json" 2>/dev/null || echo 0)"
    else
      ended="$(stat -c %Y "$d" 2>/dev/null || echo 0)"
    fi
    age=$(( now - ended ))
    [ "$age" -ge "$ttl" ] && rm -rf "$d"
  done
}
```

- [ ] **Step 4: Remove the EXIT-trap delete in the supervisor**

In `bin/relay-supervisor.sh`, replace line 227:
```bash
# Run dir is NOT deleted on exit - ended runs persist for post-mortem and are
# reaped by relay_prune_dead after 7 days (see lib/rundir.sh).
```
(Delete the `trap 'rm -rf "$RUN_DIR"' EXIT` line entirely; replace with the comment above, or just remove it.)

- [ ] **Step 5: Run rundir + full suite**

Run: `bash tests/test_rundir.sh && bash tests/run-all.sh`
Expected: PASS; `ALL GREEN`.

Note: `test_subcommands.sh` line 51 asserts `dead run pruned by list`. With age-based prune, its `dead_rd` (seeded via `mk_run cccc 999999 2`, no `stopped_at`) is pruned only if its `state.json` mtime is > 7 days old — which it is NOT (just created). This assertion will now FAIL. Fix it in this task: change `test_subcommands.sh` line 51 to assert the dead run still EXISTS but is not listed, OR seed it with an old `stopped_at`. Use the latter — in `mk_run` for the dead run, after creation set an old stopped_at:

- [ ] **Step 6: Fix test_subcommands dead-run expectation**

In `tests/test_subcommands.sh`, after the `dead_rd="$(mk_run cccc 999999 2)"` line (line 32), add:
```bash
# age the dead run past the 7-day retention so list's prune reaps it
jq '.status="stopped" | .stopped_at=(now - 8*86400 | floor)' "$dead_rd/state.json" \
  > "$dead_rd/state.json.tmp" && mv "$dead_rd/state.json.tmp" "$dead_rd/state.json"
```
(Existing assertion at line 51 `assert_file_absent "$dead_rd" "dead run pruned by list"` now holds.)

- [ ] **Step 7: Run subcommands + full suite again**

Run: `bash tests/test_subcommands.sh && bash tests/run-all.sh`
Expected: PASS; `ALL GREEN`.

- [ ] **Step 8: Commit**

```bash
git add bin/relay-supervisor.sh lib/rundir.sh tests/test_rundir.sh tests/test_subcommands.sh
git commit -m "feat: persist ended run dirs, prune only after 7 days"
```

---

### Task 6: docs + manual verification harnesses

Update README for the new flags and always-pane-scoped teardown; bring over the two manual harnesses adapted to current main.

**Files:**
- Modify: `README.md` — flags table + "How it works" bullet
- Create: `tests/manual/stub-teardown.sh`, `tests/manual/real-rotation.sh` (adapted from `feature/graceful-exit-teardown`)

**Interfaces:**
- Consumes: nothing (docs + manual scripts, not in run-all.sh).
- Produces: nothing.

- [ ] **Step 1: Locate the README references**

Run: `grep -n "rotation-timeout\|How it works\|rotate, and drives\|marker" README.md`
Expected: the flags table and the supervisor "How it works" bullet.

- [ ] **Step 2: Add flag rows to the README table**

After the `--rotation-timeout` row, add:
```markdown
| `--rotate-grace <dur>` | `2s` | Pause before teardown so the outgoing agent's final message stays readable. |
| `--exit-timeout <dur>` | `5s` | Wait for a clean `/exit` before force-killing the pane. |
```

- [ ] **Step 3: Update the "How it works" supervisor bullet**

Replace the supervisor bullet describing the cycle with:
```markdown
- A **supervisor** daemon owns the run: it reads context %, decides when to
  rotate, and drives the handoff → settle → graceful-exit → relaunch cycle.
  Teardown is always **pane-scoped**: it sends `/exit` so Claude runs its own
  shutdown (SessionEnd hook, transcript flush), waits up to `--exit-timeout`,
  then replaces the pane (rotation) or kills just that pane (stop) — never the
  tmux session, so your other panes/windows are untouched. Ended runs persist
  under `/tmp/relay-<user>/` for 7 days for post-mortem.
```

- [ ] **Step 4: Bring over the manual harnesses**

Run (copies the branch versions, then adapt):
```bash
git show feature/graceful-exit-teardown:tests/manual/stub-teardown.sh > tests/manual/stub-teardown.sh
git show feature/graceful-exit-teardown:tests/manual/real-rotation.sh > tests/manual/real-rotation.sh
chmod +x tests/manual/stub-teardown.sh tests/manual/real-rotation.sh
```
Then edit each so any `handoff_stop_seen` seed becomes `handoff_settled`, any `RELAY_MARKER_TIMEOUT` becomes `RELAY_ROTATION_TIMEOUT`, any `kill-session` expectation becomes `kill-pane`, and any `session_gone`/`session_seen` becomes `pane_gone`/`pane_seen`. Verify by reading each file after copy:
```bash
grep -n "handoff_stop_seen\|MARKER_TIMEOUT\|kill-session\|session_gone\|session_seen" tests/manual/*.sh
```
Expected after edits: no output.

- [ ] **Step 5: Verify docs have no stale flag names**

Run: `grep -n "marker-timeout\|kill-session" README.md`
Expected: no output.

- [ ] **Step 6: Run the full suite (manual harnesses are not in it; must stay green)**

Run: `bash tests/run-all.sh`
Expected: `ALL GREEN`.

- [ ] **Step 7: Commit**

```bash
git add README.md tests/manual/stub-teardown.sh tests/manual/real-rotation.sh
git commit -m "docs: document pane-scoped graceful teardown; add manual verification harnesses"
```

---

### Task 7: REQUIRED real-session verification gate (pre-merge)

The unit tests run against a fake tmux — they prove command emission and state
transitions, NOT real behavior. Four things only a real run can prove:
`remain-on-exit` actually lingers a pane; killing the last pane collapses the
session; a real claude `/exit` is honored within `--exit-timeout`; and — the
whole point of this change — **multi-pane safety** (a user split in relay's
window survives rotation and stop). This gate is NOT optional; do not merge on
unit-green alone. It spends real tokens (a couple of trivial prompts).

**Files:** none (verification only; may add findings as follow-up commits).

- [ ] **Step 1: Launch a real detached run**

```bash
RELAY_NO_ATTACH=1 bash bin/relay --rotate-at 1 --rotate-grace 1s --exit-timeout 8s
```
Record the run dir (`ls -dt /tmp/relay-$(id -un)/* | head -1`) and session name.
Confirm `state.json` has `tmux_pane` set and the pane is alive.

- [ ] **Step 2: Multi-pane safety — user splits relay's window**

Split relay's pane so the user has a second pane in the same window:
```bash
tmux split-window -t "<relay_pane>" -P -F '#{pane_id}' 'sleep 600'
```
Record the user pane id.

- [ ] **Step 3: Drive a rotation, verify only relay's pane is touched**

Send a real prompt to relay's pane (accept any permission prompts, or launch
claude with `--permission-mode acceptEdits` via `-- --permission-mode acceptEdits`).
Watch the supervisor log for `ROTATED` / `TEARDOWN_EXIT_CLEAN` and state
`generation=2`. Then assert:
- relay's pane id is unchanged (respawned in place), `pane_dead=0` (fresh claude)
- the USER's split pane still exists and is untouched (`pane_dead=0`)
- `gen-1/pane.log` was written
Expected: rotation completes; user pane survives.

- [ ] **Step 4: Stop the run, verify pane-scoped teardown**

```bash
bash bin/relay --stop <run_id>
```
Assert:
- relay's pane is gone (reaped), `status=stopped` + `stopped_at` in state.json
- the USER's split pane STILL exists and the session is STILL alive (because the
  user's pane remains) — `kill-session` would have destroyed it
- the run dir still exists on disk (NOT deleted)
Then clean up the user's pane manually: `tmux kill-pane -t "<user_pane>"`.

- [ ] **Step 5: Report findings**

Write a short verification report (what passed, any real-behavior surprises the
fake couldn't catch) to `.superpowers/sdd/task-7-verification.md`. If Step 3 or 4
revealed a real bug, fix it (new commit) and re-verify before declaring the gate
passed. Only when all four real-behavior properties hold is the branch
merge-ready.

---

## Notes for the implementer

- **Line numbers** are from `main` @ 52900be at plan-writing time; if an earlier task shifted them, match on the quoted code.
- **`--once` mode**: every supervisor test runs one `iterate`. `graceful_teardown`'s `/exit` poll must go dead within one invocation — the fake-tmux `FAKE_PANE_DEAD=1` default makes it return immediately. Always set `RELAY_ROTATE_GRACE=0` in supervisor tests so they don't sleep.
- **`pipefail` + `head` in the poll**: `list-panes ... | head -n1` can SIGPIPE `list-panes`; it sits inside `[ ... ]` so it won't trip `-e`, but if a reviewer flags it, the safe form is to capture `list-panes` into a var first, then `head`. Acceptable as-is (matches the merged `handle_pending_rotation` poll style).
- **`date +%s` vs `_relay_now`**: use `date +%s` (epoch) for `stopped_at` so prune arithmetic is integer math; `_relay_now` is ISO-8601 and used for human-facing `started_at`. Do not mix.
- **Green bar between tasks**: Tasks 2→3 and 4→5 have test files that span the boundary (`test_actuation.sh` stop sections, `test_subcommands.sh` prune). Each task's steps rewrite the tests it owns; the suite must be `ALL GREEN` before each commit. If a boundary test breaks mid-task, finish the owning task before committing.
- **No kill-session**: after Task 4, `grep -rn "kill-session\|kill-server" bin/ lib/` must be empty. This is a hard gate.
- **Timeout-branch coverage**: Task 2 section 2b is the ONLY test of the hung-`/exit` force-kill path (`FAKE_PANE_DEAD=0` + `RELAY_EXIT_TIMEOUT=1`). Do not drop it — every other test uses the instant-dead default and would never exercise the timeout fallback.
- **--stop coverage is split on purpose**: Task 4's subcommands test covers the CLI *fallback* (no live supervisor); Task 4 section 8 in test_actuation covers the *happy path* (supervisor consumes the marker). Both are needed — one alone leaves half the flow untested.
- **Task 7 is a required gate, not optional docs polish.** The unit suite cannot prove real-tmux behavior (remain-on-exit lingering, last-pane collapse, real `/exit` honored, multi-pane safety). Merging on unit-green alone would ship the multi-pane fix unverified — the exact thing this change exists to guarantee.
