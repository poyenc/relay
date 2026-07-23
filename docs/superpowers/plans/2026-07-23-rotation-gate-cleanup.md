# Rotation-gate cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce the post-handoff Stop gate on rotation teardown with a single clearly-named, duration-syntax timeout (`--rotation-timeout` / `RELAY_ROTATION_TIMEOUT`) and a single-writer `handoff_settled` state flag, where timeout expiry rotates directly if a handoff exists or gives up non-terminally otherwise.

**Architecture:** The supervisor's `handle_pending_rotation` currently tears down the moment the handoff marker file appears — but that file is written mid-turn, cutting off the final message. This plan adds a second required signal, `handoff_settled` (set true only on the first idle Stop after the marker exists), so teardown waits for `marker exists AND handoff_settled`. The existing `RELAY_MARKER_TIMEOUT` is renamed `RELAY_ROTATION_TIMEOUT` (a single backstop from `pending_since`); on expiry it rotates directly when the marker is present (flaky Stop, don't waste a valid handoff) or clears pending and logs `ROTATE_FAILED` when it isn't (non-terminal — the run keeps living and can rotate on a later Stop).

**Tech Stack:** Bash, jq, tmux; the repo's own `tests/assert.sh` micro-framework run via `tests/run-all.sh`.

## Global Constraints

- Target platform: Linux, Bash (`set -euo pipefail` in `bin/relay-supervisor.sh`; `set -uo pipefail` in tests).
- Timeout default: `120` seconds, unchanged, everywhere it appears.
- Duration syntax parsed only by the existing `relay_parse_duration` (accepts `Ns`, `Nm`, `Nh`, `Nd`, or bare `N` seconds; returns nonzero on invalid).
- State is JSON in `<run_dir>/state.json`, read via `relay_state_get` and written via `relay_state_set` (jq expressions).
- Naming, copied verbatim: env `RELAY_ROTATION_TIMEOUT`; flag `--rotation-timeout`; parse var `RELAY_OPT_ROTATION_TIMEOUT`; state flag `handoff_settled`; failure log token `ROTATE_FAILED`; forced-rotate log token `ROTATE_STOP_TIMEOUT`.
- No new CLI flag beyond the rename; no second timeout knob; no cap on consecutive rotation failures.
- Run the full suite with `bash tests/run-all.sh` (expects `ALL GREEN`).

---

### Task 1: Rename the timeout — CLI flag, env var, and threading

Pure rename with a syntax upgrade: `--marker-timeout <s>` (raw seconds) becomes `--rotation-timeout <dur>` (duration syntax), the parse var and env var are renamed, and `bin/relay` threads the new env name. No gate/behavior change yet — the supervisor's timeout branch keeps working because we rename its env default in the same task.

**Files:**
- Modify: `lib/cli.sh` — usage text (line 38), header comment (line 60), default (line 70), parse case (lines 94-96)
- Modify: `bin/relay` — env threading (line 48)
- Modify: `bin/relay-supervisor.sh` — env default (line 10), timeout read (line 161)
- Modify: `tests/test_cli.sh` — default assertion (line 21), full-parse invocation + assertion (lines 30, 38), usage assertion (line 96)
- Modify: `tests/test_supervisor_loop.sh` — env override (line 51)
- Modify: `tests/test_integration_headless.sh` — env override (line 20) and its NOTE comment (lines 15-18)

**Interfaces:**
- Consumes: existing `relay_parse_duration` (in `lib/cli.sh`), which converts `90s`→`90`, `2m`→`120`, bare `200`→`200`, and returns nonzero on garbage.
- Produces: `RELAY_OPT_ROTATION_TIMEOUT` (parse var, default `"120"`); `--rotation-timeout <dur>` CLI flag; `RELAY_ROTATION_TIMEOUT` env var read by the supervisor.

- [ ] **Step 1: Update the CLI tests to the new name/syntax (failing first)**

In `tests/test_cli.sh`, replace line 21:
```bash
assert_eq "$RELAY_OPT_ROTATION_TIMEOUT" "120" "default rotation-timeout 120"
```

Replace the invocation at lines 29-30:
```bash
relay_parse_args --rotate-at 45 --max-gen 5 --max-runtime 90m --max-cost 12.50 \
  --no-auto-continue --rotation-timeout 90s -- --model opus -p "hello world"
```

Replace the assertion at line 38:
```bash
assert_eq "$RELAY_OPT_ROTATION_TIMEOUT" "90" "rotation-timeout duration -> seconds"
```

Replace the usage assertion at line 96:
```bash
assert_contains "$u" "--rotation-timeout" "usage: rotation-timeout"
```

Add three error-case assertions immediately after line 70 (`launch-flag + subcommand rejected`):
```bash
if relay_parse_args --rotation-timeout; then assert_eq bad ok "rotation-timeout needs value"; else assert_ok "rotation-timeout missing value rejected"; fi
if relay_parse_args --rotation-timeout bogus; then assert_eq bad ok "rotation-timeout rejects garbage"; else assert_ok "rotation-timeout invalid duration rejected"; fi
relay_parse_args --rotation-timeout 2m
assert_eq "$RELAY_OPT_ROTATION_TIMEOUT" "120" "rotation-timeout 2m -> 120s"
```

- [ ] **Step 2: Run the CLI test to verify it fails**

Run: `bash tests/test_cli.sh`
Expected: FAIL lines referencing `RELAY_OPT_ROTATION_TIMEOUT` (empty/unset) and missing `--rotation-timeout` in usage.

- [ ] **Step 3: Rename in `lib/cli.sh`**

Replace the usage line (line 38):
```bash
  --rotation-timeout <dur> Wait for the outgoing generation to hand off and
                         settle before giving up on a rotation (default 120s).
```

Replace the header-comment line (line 60):
```bash
#   RELAY_OPT_ROTATE_AT / MAX_GEN / MAX_RUNTIME_S / MAX_COST / ROTATION_TIMEOUT / AUTO_CONTINUE
```

Replace the default (line 70):
```bash
  RELAY_OPT_ROTATION_TIMEOUT="120"
```

Replace the parse case (lines 94-96) — now uses `relay_parse_duration`:
```bash
      --rotation-timeout)
        [ $# -ge 2 ] || { RELAY_PARSE_ERR="--rotation-timeout requires a value"; return 1; }
        dur="$(relay_parse_duration "$2")" || { RELAY_PARSE_ERR="invalid --rotation-timeout: $2"; return 1; }
        RELAY_OPT_ROTATION_TIMEOUT="$dur"; saw_launch_flag=1; shift 2 ;;
```

- [ ] **Step 4: Thread the new env name in `bin/relay`**

Replace line 48:
```bash
  RELAY_ROTATION_TIMEOUT="$RELAY_OPT_ROTATION_TIMEOUT" RELAY_TMUX="$RELAY_TMUX" \
```

- [ ] **Step 5: Rename env in `bin/relay-supervisor.sh`**

Replace line 10:
```bash
: "${RELAY_ROTATION_TIMEOUT:=120}"
```

Replace line 161 (the timeout comparison):
```bash
    if [ "$age" -ge "$RELAY_ROTATION_TIMEOUT" ]; then
```

- [ ] **Step 6: Update the two supervisor/integration test overrides**

In `tests/test_supervisor_loop.sh`, replace line 51:
```bash
RELAY_ROTATION_TIMEOUT=1 bash bin/relay-supervisor.sh --run-dir "$rd3" --once
```

In `tests/test_integration_headless.sh`, replace the NOTE + override (lines 15-20):
```bash
# NOTE: RELAY_ROTATION_TIMEOUT raised from the 120s default. In this environment
# the spawned headless `claude -p` session is slowed considerably by a global
# rtk PreToolUse hook that intercepts/requires approval for many Bash calls,
# pushing real end-to-end handoff-writing time past 120s (observed ~215s).
# 280s gives enough margin without masking a genuinely broken rotation.
RELAY_ROTATION_TIMEOUT=280 bash bin/relay-supervisor.sh --run-dir "$rd" &
```

- [ ] **Step 7: Run the CLI test to verify it passes**

Run: `bash tests/test_cli.sh`
Expected: PASS (`--- N passed, 0 failed ---`).

- [ ] **Step 8: Run the full suite (rename must not break the still-marker-only gate)**

Run: `bash tests/run-all.sh`
Expected: `ALL GREEN`. (The gate is still marker-only at this point; `test_supervisor_loop.sh` iteration-2 rotates on the marker alone, which is fine until Task 2.)

- [ ] **Step 9: Commit**

```bash
git add lib/cli.sh bin/relay bin/relay-supervisor.sh tests/test_cli.sh tests/test_supervisor_loop.sh tests/test_integration_headless.sh
git commit -m "refactor: rename --marker-timeout to --rotation-timeout with duration syntax"
```

---

### Task 2: Add the `handoff_settled` gate and direct-rotate/give-up timeout

Introduce the second required signal. `handle_stop_request` initializes `handoff_settled=false` when a rotation is requested and sets it `true` on the first idle Stop seen while the marker exists. `handle_pending_rotation` gates teardown on `marker exists AND handoff_settled`; on timeout it rotates directly when the marker is present (logging `ROTATE_STOP_TIMEOUT`) or clears pending and logs `ROTATE_FAILED` when it isn't. Tests updated to drive the two-step (marker, then Stop) sequence and both timeout paths.

**Files:**
- Modify: `bin/relay-supervisor.sh` — `handle_stop_request` re-arm `else` branch (lines 47-50), rotation-request state write (lines 71-72), `handle_pending_rotation` locals + gate (lines 137-139) and timeout branch (lines 158-165)
- Modify: `tests/test_supervisor_loop.sh` — iteration 2/3 gate sequence (lines 21-27), give-up timeout block (lines 48-53); add a marker-present timeout block
- Modify: `tests/test_actuation.sh` — the four rotation-pending seeds must add `handoff_settled=true` (lines 19, 36, 49, 65)

**Interfaces:**
- Consumes: `RELAY_ROTATION_TIMEOUT` (from Task 1); state fields `rotation_pending`, `pending_marker`, `pending_since`, `pending_pct`, `generation`; helpers `relay_state_get/set`, `relay_state_add_rotation`, `relay_cap_hit`, `_run_elapsed_s`, `relay_cost_from_statusline`, `actuate_rotation`, `stop_run`.
- Produces: state flag `handoff_settled` (bool); log tokens `ROTATE_STOP_TIMEOUT` (forced rotate) and existing `ROTATE_FAILED` (give up).

- [ ] **Step 1: Rewrite the supervisor-loop gate tests (failing first)**

In `tests/test_supervisor_loop.sh`, replace lines 21-27 (iteration 2) with a two-step gate:
```bash
# --- iteration 2: marker appears mid-turn but NO post-handoff Stop yet ->
#     must NOT tear down (final message may still be rendering) ---
: > "$rd/gen-1/handoff.ready"
bash bin/relay-supervisor.sh --run-dir "$rd" --once
assert_eq "$(relay_state_get "$rd" '.generation')" "1" "no bump before post-handoff stop"
assert_eq "$(relay_state_get "$rd" '.rotation_pending')" "true" "still pending pre-stop"

# --- iteration 3: post-handoff Stop arrives -> handoff_settled set, then rotate ---
printf '{"hook_event_name":"Stop","transcript_path":"/none","stop_hook_active":false}' > "$rd/stop-request.json"
bash bin/relay-supervisor.sh --run-dir "$rd" --once
assert_eq "$(relay_state_get "$rd" '.generation')" "2" "generation bumped after post-handoff stop"
assert_eq "$(relay_state_get "$rd" '.rotation_pending')" "false" "pending cleared"
assert_eq "$(relay_state_get "$rd" '.rotations | length')" "1" "rotation recorded"
assert_file_absent "$rd/gen-1/handoff.ready" "marker consumed"
```

Replace the give-up block (lines 48-53) with both timeout paths:
```bash
# --- timeout, marker present but never settled -> rotate directly ---
rd3="$(mktemp -d)"; mkdir -p "$rd3/gen-1"; relay_state_init "$rd3" 60 "" "" "" $$
: > "$rd3/gen-1/handoff.ready"
relay_state_set "$rd3" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70 | .handoff_settled=false'
RELAY_ROTATION_TIMEOUT=1 bash bin/relay-supervisor.sh --run-dir "$rd3" --once
assert_eq "$(relay_state_get "$rd3" '.generation')" "2" "marker-present timeout rotates directly"
assert_eq "$(relay_state_get "$rd3" '.rotation_pending')" "false" "pending cleared after forced rotate"
assert_contains "$(cat "$rd3/supervisor.log")" "ROTATE_STOP_TIMEOUT" "forced-rotate logged"

# --- timeout, no marker -> ROTATE_FAILED, non-terminal (run survives) ---
rd5="$(mktemp -d)"; mkdir -p "$rd5/gen-1"; relay_state_init "$rd5" 60 "" "" "" $$
relay_state_set "$rd5" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .handoff_settled=false'
RELAY_ROTATION_TIMEOUT=1 bash bin/relay-supervisor.sh --run-dir "$rd5" --once
assert_eq "$(relay_state_get "$rd5" '.rotation_pending')" "false" "timeout clears pending"
assert_eq "$(relay_state_get "$rd5" '.generation')" "1" "no bump when no handoff exists"
assert_eq "$(relay_state_get "$rd5" '.status // "none"')" "none" "give-up is non-terminal (not stopped)"
assert_contains "$(cat "$rd5/supervisor.log")" "ROTATE_FAILED" "failure logged"
```

- [ ] **Step 2: Run the supervisor-loop test to verify it fails**

Run: `bash tests/test_supervisor_loop.sh`
Expected: FAIL — iteration 2 currently bumps to generation 2 (want 1); `ROTATE_STOP_TIMEOUT` absent from the log.

- [ ] **Step 3: Set `handoff_settled` in `handle_stop_request`**

In `bin/relay-supervisor.sh`, replace the re-arm `else` branch (lines 47-50):
```bash
    else
      # Marker present means the handoff is written and this is the FIRST idle Stop
      # after it - the "post-handoff stop". Record that the outgoing generation has
      # settled so handle_pending_rotation tears down now (final message rendered),
      # not the instant the marker file appeared mid-turn.
      [ -f "$RUN_DIR/$marker" ] && relay_state_set "$RUN_DIR" '.handoff_settled=true'
      printf '{}' > "$RUN_DIR/stop-response.json.tmp"
      mv "$RUN_DIR/stop-response.json.tmp" "$RUN_DIR/stop-response.json"
    fi
```

Replace the rotation-request state write (lines 71-72) to initialize the flag:
```bash
    relay_state_set "$RUN_DIR" \
      ".rotation_pending=true | .pending_marker=\"$marker\" | .pending_since=$(date +%s) | .pending_pct=${pct:-0} | .handoff_settled=false"
```

- [ ] **Step 4: Gate teardown and rewrite the timeout branch in `handle_pending_rotation`**

Replace the locals + gate opener (lines 137-139):
```bash
  local marker gen since now age pct cap settled
  marker="$(relay_state_get "$RUN_DIR" '.pending_marker')"
  # Wait for BOTH the handoff marker AND the outgoing generation to settle (the
  # post-handoff Stop). The marker says "handoff written" (created mid-turn); the
  # settled flag says "turn complete, final message rendered". Acting on the marker
  # alone would kill the pane before its final message finished printing.
  settled="$(relay_state_get "$RUN_DIR" '.handoff_settled // false')"
  if [ -f "$RUN_DIR/$marker" ] && [ "$settled" = "true" ]; then
```

Replace the timeout `else` branch (lines 158-165) with direct-rotate / give-up:
```bash
  else
    since="$(relay_state_get "$RUN_DIR" '.pending_since // 0')"
    now="$(date +%s)"; age=$(( now - since ))
    if [ "$age" -ge "$RELAY_ROTATION_TIMEOUT" ]; then
      if [ -f "$RUN_DIR/$marker" ]; then
        # Handoff exists but the post-handoff Stop never arrived (flaky hook). Do
        # NOT waste a valid handoff - rotate directly, same as the normal gate.
        gen="$(relay_state_get "$RUN_DIR" '.generation')"
        pct="$(relay_state_get "$RUN_DIR" '.pending_pct')"
        cap="$(relay_cap_hit "$RUN_DIR" "$(_run_elapsed_s)" "$(relay_cost_from_statusline "$RUN_DIR")")"
        if [ "$cap" != "none" ]; then
          rm -f "$RUN_DIR/$marker"
          stop_run "cap:$cap"
          return 0
        fi
        relay_state_add_rotation "$RUN_DIR" "$gen" "${pct:-0}"
        relay_state_set "$RUN_DIR" \
          ".generation=$((gen+1)) | .rotation_pending=false | .pending_marker=null | .next_handoff=\"$RUN_DIR/gen-$gen/handoff.md\""
        mkdir -p "$RUN_DIR/gen-$((gen+1))"
        rm -f "$RUN_DIR/$marker"
        log "ROTATE_STOP_TIMEOUT from_gen=$gen to_gen=$((gen+1)) age=${age}s force=1"
        actuate_rotation "$gen" "$RUN_DIR/gen-$gen/handoff.md"
      else
        # No handoff was ever produced - give up this attempt. Non-terminal: the
        # run keeps living and can rotate again on a later Stop.
        relay_state_set "$RUN_DIR" '.rotation_pending=false | .pending_marker=null'
        log "ROTATE_FAILED reason=rotation_timeout age=${age}s"
      fi
    fi
  fi
```

- [ ] **Step 5: Run the supervisor-loop test to verify it passes**

Run: `bash tests/test_supervisor_loop.sh`
Expected: PASS.

- [ ] **Step 6: Fix the actuation seeds to set `handoff_settled`**

In `tests/test_actuation.sh`, the four rotation-pending seeds currently read:
```bash
relay_state_set "$rd" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70'
```
Append ` | .handoff_settled=true` to each of the four (lines 19, 36, 49, 65 — one per test block for `$rd`, `$rd2`, `$rd3`, `$rd3b`). Example for the first:
```bash
relay_state_set "$rd" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70 | .handoff_settled=true'
```

- [ ] **Step 7: Run the actuation test to verify it passes**

Run: `bash tests/test_actuation.sh`
Expected: PASS (rotations actuate because the gate now sees `handoff_settled=true`).

- [ ] **Step 8: Run the full suite**

Run: `bash tests/run-all.sh`
Expected: `ALL GREEN`.

- [ ] **Step 9: Commit**

```bash
git add bin/relay-supervisor.sh tests/test_supervisor_loop.sh tests/test_actuation.sh
git commit -m "feat: gate rotation teardown on post-handoff settle; direct-rotate on timeout"
```

---

### Task 3: Documentation

Reflect the new flag and always-gated teardown flow in the README table and "How it works" section.

**Files:**
- Modify: `README.md` — "How it works" supervisor bullet; launch-flags table row

**Interfaces:**
- Consumes: nothing (docs only).
- Produces: nothing.

- [ ] **Step 1: Locate the current marker-timeout doc references**

Run: `grep -n "marker-timeout\|handoff →\|rotate, and drives" README.md`
Expected: the "How it works" supervisor bullet and the flags-table row that mention the old flag / cycle.

- [ ] **Step 2: Update the flags table row**

In `README.md`, replace the `--marker-timeout` table row with:
```markdown
| `--rotation-timeout <dur>` | `120s` | Wait for the outgoing generation to hand off and settle (its post-handoff Stop) before giving up on a rotation. On timeout, a written handoff still rotates; otherwise the attempt is abandoned and retried on the next Stop. |
```

- [ ] **Step 3: Update the "How it works" supervisor bullet**

In `README.md`, replace the supervisor bullet describing the cycle with:
```markdown
- A **supervisor** daemon owns the run: it reads context %, decides when to
  rotate, and drives the handoff → settle → relaunch → inject cycle. Teardown
  waits for both the handoff marker and the outgoing generation's post-handoff
  Stop (so its final message finishes rendering) before replacing the pane,
  backstopped by `--rotation-timeout`.
```

- [ ] **Step 4: Verify the old flag name is gone from docs**

Run: `grep -n "marker-timeout\|MARKER_TIMEOUT" README.md`
Expected: no output (empty).

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: document --rotation-timeout and the settle-gated teardown"
```

---

## Notes for the implementer

- **Line numbers** are from `main` at plan-writing time; if an earlier task shifted them, match on the quoted code instead.
- **`ONCE` mode**: every supervisor test runs `--once` (single `iterate`), so a "rotate next iteration" design would need two invocations. This plan rotates *directly* in the timeout branch precisely so the marker-present timeout test passes in a single `--once` call — do not reintroduce a deferred/next-iteration force.
- **Why `handoff_settled` also checks the marker at set time** (`[ -f "$RUN_DIR/$marker" ] && ...`): the flag must only latch true once a real handoff exists; a stray idle Stop before the handoff is written must not pre-settle the gate.
- **Full green bar** on `main` before Task 1 is `ALL GREEN`; keep it there after every task.
