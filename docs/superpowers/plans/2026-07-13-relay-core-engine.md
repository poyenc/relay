# relay Core Rotation Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the agent-agnostic core + Claude adapter that decides when to rotate a Claude Code session and drives the handoff/marker cycle — provable headlessly with `claude -p`, before any tmux UX.

**Architecture:** A supervisor daemon owns run state and a poll loop. A bundled Claude plugin (`--plugin-dir`) contributes a Stop hook (delegates the rotate decision to the supervisor via file-based request/response rendezvous) and a SessionStart hook (injects the prior generation's handoff). Telemetry comes from a statusline tee (authoritative %) with transcript parsing as fallback. This plan is Plan 1 of 2; Plan 2 adds the tmux wrapper, auto-attach, kill/relaunch, and subcommands.

**Tech Stack:** bash, jq, `claude` CLI (`--plugin-dir`, `-p`). No compiled binary. Tests are plain bash scripts with a tiny assert helper (no `bats` on this box).

## Global Constraints

- Language/deps: bash + jq only. Confirmed present: `jq`, `tmux 3.4`, OpenBSD `nc` at `/usr/bin`. Python3 available but avoid unless a step says otherwise.
- **IPC is file-based**, NOT unix-socket-daemon: OpenBSD netcat has no server/exec mode. Request/response via atomically-written files in the run dir. (Spec §12 permits alternative local transports.)
- Run-dir root: `${TMPDIR:-/tmp}/relay-$(id -u)/`, parent mode `700`. Run dirs created via `mktemp -d "<root>/run-$(date +%Y%m%d)-XXXXXX"`.
- Env vars exported into the agent process: `RELAY_RUN_DIR`, `RELAY_STATE` (=`$RELAY_RUN_DIR/statusline.json`), `RELAY_HANDOFF_PATH` (prior gen's handoff.md, set per generation). Hooks no-op (exit 0) when `RELAY_RUN_DIR` is unset/absent.
- Default rotate threshold: **60%**. Marker timeout default: **120s**. Telemetry staleness threshold: **90s**. Context window default: **200000** (env `RELAY_CTX_WINDOW` overrides).
- All hooks must exit 0 in the no-supervisor case so plain `claude` and unsupervised runs are unaffected.
- Every code file starts with `#!/usr/bin/env bash` and `set -euo pipefail` (except hook scripts, which use `set -uo pipefail` — they must never hard-fail the turn).
- Repo root for all paths below: `/home/AMD/poyechen/workspace/repo/supervised-claude/`. Plan-relative paths are under `relay/`.

---

## File Structure

```
relay/
├── .claude-plugin/plugin.json        # plugin manifest
├── hooks/
│   ├── hooks.json                    # registers Stop + SessionStart
│   ├── stop-hook.sh                  # Stop delegate (file IPC client)
│   └── session-start-hook.sh         # inject prior handoff
├── lib/
│   ├── rundir.sh                     # run-dir root, create, discover, prune
│   ├── state.sh                      # state.json read/write (jq)
│   ├── telemetry.sh                  # context % (tee primary, transcript fallback)
│   ├── policy.sh                     # threshold decision
│   └── handoff_instruction.sh        # emit two-tier rotate instruction text
├── bin/
│   └── relay-supervisor.sh           # daemon main loop
└── tests/
    ├── assert.sh                     # tiny test helper
    ├── fixtures/                     # sample statusline.json, transcript.jsonl
    ├── test_rundir.sh
    ├── test_state.sh
    ├── test_telemetry.sh
    ├── test_policy.sh
    ├── test_ipc_hook.sh
    ├── test_supervisor_loop.sh
    └── test_integration_headless.sh
```

---

## Task 0: Spikes — verify the four risky assumptions

**Purpose:** These gate the whole design (spec §15). Do them first; if any fails, STOP and report — the wiring changes. Not TDD; each is a verify-and-record step.

**Files:**
- Create: `relay/tests/spikes/` (throwaway scripts + captured output)

- [ ] **Step 1: Spike env propagation to hooks** (the linchpin)

Create `relay/tests/spikes/spike-env/.claude-plugin/plugin.json`:
```json
{ "name": "relay-spike", "description": "env spike", "version": "0.0.1" }
```
Create `relay/tests/spikes/spike-env/hooks/hooks.json`:
```json
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command",
  "command": "bash \"${CLAUDE_PLUGIN_ROOT}/dump-env.sh\"" } ] } ] } }
```
Create `relay/tests/spikes/spike-env/dump-env.sh`:
```bash
#!/usr/bin/env bash
cat > /dev/null   # drain stdin
printf 'RELAY_RUN_DIR=%s\nRELAY_STATE=%s\nCLAUDE_PLUGIN_ROOT=%s\n' \
  "${RELAY_RUN_DIR:-UNSET}" "${RELAY_STATE:-UNSET}" "${CLAUDE_PLUGIN_ROOT:-UNSET}" \
  > /tmp/relay-spike-env.txt
exit 0
```

- [ ] **Step 2: Run the env spike**

Run:
```bash
chmod +x relay/tests/spikes/spike-env/dump-env.sh
rm -f /tmp/relay-spike-env.txt
RELAY_RUN_DIR=/tmp/relay-spike-run RELAY_STATE=/tmp/relay-spike-run/statusline.json \
  claude -p "say hi" --plugin-dir relay/tests/spikes/spike-env >/dev/null 2>&1
cat /tmp/relay-spike-env.txt
```
Expected: `RELAY_RUN_DIR=/tmp/relay-spike-run` and `RELAY_STATE=...` (NOT `UNSET`). `CLAUDE_PLUGIN_ROOT` is an absolute path.
**If `RELAY_RUN_DIR=UNSET`:** env does NOT propagate to hooks → STOP and report. Fallback (spec §14) is to bake run_id into the plugin at launch or derive from `cwd`; that changes Tasks 5–7.

- [ ] **Step 3: Spike SessionStart stdout injection**

Reuse the probe approach. Create `relay/tests/spikes/spike-ss/.claude-plugin/plugin.json` (name `relay-ss`), and `relay/tests/spikes/spike-ss/hooks/hooks.json`:
```json
{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command",
  "command": "printf 'RELAY_INJECT_MARKER_9F3: the secret word is kumquat\\n'" } ] } ] } }
```
Run:
```bash
claude -p "What secret word were you told at session start? Answer in one word." \
  --plugin-dir relay/tests/spikes/spike-ss 2>/dev/null
```
Expected: the reply contains `kumquat` → SessionStart stdout reaches the model in `-p` mode.
**Record** whether it also works interactively (deferred to Plan 2 smoke; note it).

- [ ] **Step 4: Record nc + Stop-allow findings (already known)**

Write `relay/tests/spikes/FINDINGS.md` capturing: (a) OpenBSD nc has no server mode → file-IPC chosen; (b) env propagation result from Step 2; (c) SessionStart injection result from Step 3; (d) Stop-allow-does-not-exit-interactive is deferred to Plan 2 (headless `-p` exits regardless, so Plan 1 does not depend on it).

- [ ] **Step 5: Commit**

```bash
git add relay/tests/spikes
git commit -m "spike: verify env propagation, SessionStart injection, IPC transport"
```

---

## Task 1: Test helper + run-dir management

**Files:**
- Create: `relay/tests/assert.sh`, `relay/lib/rundir.sh`, `relay/tests/test_rundir.sh`

**Interfaces:**
- Produces (`lib/rundir.sh`, sourced):
  - `relay_root()` → echoes `${TMPDIR:-/tmp}/relay-$(id -u)`
  - `relay_create_rundir()` → mkdir root (mode 700), `mktemp -d` a run dir, echoes its path
  - `relay_list_live()` → echoes one line per live run: `<run_dir>\t<pid>\t<generation>` (pid alive via `kill -0`)
  - `relay_prune_dead()` → `rm -rf` run dirs whose `state.json.supervisor_pid` is not alive
- Produces (`tests/assert.sh`, sourced): `assert_eq <actual> <expected> <msg>`, `assert_contains <haystack> <needle> <msg>`, `assert_file_exists <path> <msg>`, `assert_ok`/`assert_fail`, and `finish` (prints PASS/FAIL count, exits nonzero on any fail).

- [ ] **Step 1: Write the assert helper**

Create `relay/tests/assert.sh`:
```bash
#!/usr/bin/env bash
# Tiny assert helper. Source this; call finish at end.
_A_PASS=0; _A_FAIL=0
assert_eq() { if [ "$1" = "$2" ]; then _A_PASS=$((_A_PASS+1));
  else _A_FAIL=$((_A_FAIL+1)); echo "FAIL: $3 (got='$1' want='$2')"; fi; }
assert_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then _A_PASS=$((_A_PASS+1));
  else _A_FAIL=$((_A_FAIL+1)); echo "FAIL: $3 (missing '$2' in '$1')"; fi; }
assert_file_exists() { if [ -e "$1" ]; then _A_PASS=$((_A_PASS+1));
  else _A_FAIL=$((_A_FAIL+1)); echo "FAIL: $2 (no file $1)"; fi; }
assert_file_absent() { if [ ! -e "$1" ]; then _A_PASS=$((_A_PASS+1));
  else _A_FAIL=$((_A_FAIL+1)); echo "FAIL: $2 (file exists $1)"; fi; }
finish() { echo "--- $_A_PASS passed, $_A_FAIL failed ---"; [ "$_A_FAIL" -eq 0 ]; }
```

- [ ] **Step 2: Write the failing test for rundir**

Create `relay/tests/test_rundir.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/rundir.sh

export TMPDIR; TMPDIR="$(mktemp -d)"   # isolate from real /tmp/relay

# create
rd="$(relay_create_rundir)"
assert_file_exists "$rd" "rundir created"
mode="$(stat -c '%a' "$(relay_root)")"
assert_eq "$mode" "700" "root is mode 700"

# discovery: seed a live + a dead run
echo "{\"supervisor_pid\": $$, \"generation\": 2}" > "$rd/state.json"
dead="$(relay_root)/run-20200101-dead01"; mkdir -p "$dead"
echo '{"supervisor_pid": 999999, "generation": 1}' > "$dead/state.json"

live="$(relay_list_live)"
assert_contains "$live" "$rd" "live run listed"
assert_eq "$(printf '%s' "$live" | grep -c "$dead")" "0" "dead run not listed"

relay_prune_dead
assert_file_absent "$dead" "dead run pruned"
assert_file_exists "$rd" "live run survives prune"

finish
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bash relay/tests/test_rundir.sh`
Expected: FAIL — `lib/rundir.sh` does not exist (source error) or functions undefined.

- [ ] **Step 4: Implement rundir.sh**

Create `relay/lib/rundir.sh`:
```bash
#!/usr/bin/env bash
# Run-directory lifecycle: root, create, discover live, prune dead.
relay_root() { printf '%s/relay-%s' "${TMPDIR:-/tmp}" "$(id -u)"; }

relay_create_rundir() {
  local root; root="$(relay_root)"
  mkdir -p "$root"; chmod 700 "$root"
  mktemp -d "$root/run-$(date +%Y%m%d)-XXXXXX"
}

relay_list_live() {
  local root; root="$(relay_root)"; local d pid gen
  [ -d "$root" ] || return 0
  for d in "$root"/run-*; do
    [ -f "$d/state.json" ] || continue
    pid="$(jq -r '.supervisor_pid // empty' "$d/state.json" 2>/dev/null)"
    [ -n "$pid" ] || continue
    if kill -0 "$pid" 2>/dev/null; then
      gen="$(jq -r '.generation // 0' "$d/state.json" 2>/dev/null)"
      printf '%s\t%s\t%s\n' "$d" "$pid" "$gen"
    fi
  done
}

relay_prune_dead() {
  local root; root="$(relay_root)"; local d pid
  [ -d "$root" ] || return 0
  for d in "$root"/run-*; do
    [ -d "$d" ] || continue
    if [ -f "$d/state.json" ]; then
      pid="$(jq -r '.supervisor_pid // empty' "$d/state.json" 2>/dev/null)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
    fi
    rm -rf "$d"
  done
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash relay/tests/test_rundir.sh`
Expected: `--- N passed, 0 failed ---` and exit 0.

- [ ] **Step 6: Commit**

```bash
git add relay/tests/assert.sh relay/lib/rundir.sh relay/tests/test_rundir.sh
git commit -m "feat: run-dir create, live-discovery, and dead-prune"
```

---

## Task 2: state.json read/write

**Files:**
- Create: `relay/lib/state.sh`, `relay/tests/test_state.sh`

**Interfaces:**
- Consumes: none.
- Produces (`lib/state.sh`, sourced):
  - `relay_state_init <run_dir> <rotate_at> <max_gen> <max_runtime_s> <max_cost> <supervisor_pid>` → writes initial `state.json` (generation=1, rotation_pending=false, pending_marker=null, rotations=[], started_at=ISO8601). Empty caps passed as empty string → JSON null.
  - `relay_state_get <run_dir> <jq_filter>` → echoes a field (e.g. `.generation`)
  - `relay_state_set <run_dir> <jq_assignment>` → applies a jq assignment atomically (e.g. `.rotation_pending=true`)
  - `relay_state_add_rotation <run_dir> <gen> <at_pct>` → appends `{gen,at_pct,ts}` to `.rotations`

- [ ] **Step 1: Write the failing test**

Create `relay/tests/test_state.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/state.sh

rd="$(mktemp -d)"
relay_state_init "$rd" 60 "" "" "" 4242
assert_file_exists "$rd/state.json" "state.json written"
assert_eq "$(relay_state_get "$rd" '.generation')" "1" "gen starts at 1"
assert_eq "$(relay_state_get "$rd" '.policy.rotate_at_pct')" "60" "threshold stored"
assert_eq "$(relay_state_get "$rd" '.policy.max_gen')" "null" "empty cap -> null"
assert_eq "$(relay_state_get "$rd" '.rotation_pending')" "false" "not pending initially"
assert_eq "$(relay_state_get "$rd" '.supervisor_pid')" "4242" "pid stored"

relay_state_set "$rd" '.rotation_pending=true | .generation=2'
assert_eq "$(relay_state_get "$rd" '.rotation_pending')" "true" "pending set"
assert_eq "$(relay_state_get "$rd" '.generation')" "2" "gen bumped"

relay_state_add_rotation "$rd" 1 61
assert_eq "$(relay_state_get "$rd" '.rotations | length')" "1" "rotation recorded"
assert_eq "$(relay_state_get "$rd" '.rotations[0].at_pct')" "61" "rotation pct"

finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash relay/tests/test_state.sh`
Expected: FAIL — `lib/state.sh` missing.

- [ ] **Step 3: Implement state.sh**

Create `relay/lib/state.sh`:
```bash
#!/usr/bin/env bash
# state.json helpers. All writes are atomic (tmp + mv).
_relay_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

relay_state_init() {
  local rd="$1" rotate="$2" maxgen="$3" maxrt="$4" maxcost="$5" pid="$6"
  jq -n \
    --argjson rotate "$rotate" \
    --argjson maxgen "${maxgen:-null}" \
    --argjson maxrt "${maxrt:-null}" \
    --argjson maxcost "${maxcost:-null}" \
    --argjson pid "$pid" \
    --arg ts "$(_relay_now)" \
    '{run_id: ($ts), generation: 1, supervisor_pid: $pid,
      policy: {rotate_at_pct: $rotate, max_gen: $maxgen,
               max_runtime_s: $maxrt, max_cost_usd: $maxcost},
      rotation_pending: false, pending_marker: null,
      rotations: [], started_at: $ts}' \
    > "$rd/state.json.tmp" && mv "$rd/state.json.tmp" "$rd/state.json"
}

relay_state_get() { jq -r "$2" "$1/state.json"; }

relay_state_set() {
  local rd="$1" assign="$2"
  jq "$assign" "$rd/state.json" > "$rd/state.json.tmp" \
    && mv "$rd/state.json.tmp" "$rd/state.json"
}

relay_state_add_rotation() {
  local rd="$1" gen="$2" pct="$3"
  jq --argjson gen "$gen" --argjson pct "$pct" --arg ts "$(_relay_now)" \
    '.rotations += [{gen: $gen, at_pct: $pct, ts: $ts}]' \
    "$rd/state.json" > "$rd/state.json.tmp" && mv "$rd/state.json.tmp" "$rd/state.json"
}
```
Note: empty-string caps become the literal `null` via `${maxgen:-null}` since `--argjson x null` is valid JSON null.

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash relay/tests/test_state.sh`
Expected: `--- N passed, 0 failed ---`.

- [ ] **Step 5: Commit**

```bash
git add relay/lib/state.sh relay/tests/test_state.sh
git commit -m "feat: atomic state.json read/write helpers"
```

---

## Task 3: Telemetry — context % (tee primary, transcript fallback)

**Files:**
- Create: `relay/lib/telemetry.sh`, `relay/tests/test_telemetry.sh`, `relay/tests/fixtures/statusline.json`, `relay/tests/fixtures/transcript.jsonl`

**Interfaces:**
- Consumes: none.
- Produces (`lib/telemetry.sh`, sourced):
  - `relay_pct_from_statusline <run_dir>` → echoes integer % if `$run_dir/statusline.json` exists AND fresh (mtime within `RELAY_STALE_S`, default 90); else echoes empty.
  - `relay_pct_from_transcript <transcript_path>` → echoes integer % from last main-thread assistant `usage` / `RELAY_CTX_WINDOW` (default 200000); empty if none.
  - `relay_context_pct <run_dir> <transcript_path>` → statusline first, transcript fallback; echoes integer or empty.

- [ ] **Step 1: Create fixtures**

Create `relay/tests/fixtures/statusline.json`:
```json
{"context_window":{"used_percentage":72.4},"cost":{"total_cost_usd":1.23}}
```
Create `relay/tests/fixtures/transcript.jsonl` (main-thread assistant usage summing to 67172 of 200000 = 33%; includes a sidechain line that must be ignored):
```
{"type":"assistant","isSidechain":true,"message":{"model":"claude-opus-4-8","usage":{"input_tokens":2,"cache_creation_input_tokens":190000,"cache_read_input_tokens":0}}}
{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":2,"cache_creation_input_tokens":67077,"cache_read_input_tokens":0}}}
{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":2,"cache_creation_input_tokens":93,"cache_read_input_tokens":67077}}}
```

- [ ] **Step 2: Write the failing test**

Create `relay/tests/test_telemetry.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/telemetry.sh

rd="$(mktemp -d)"
cp tests/fixtures/statusline.json "$rd/statusline.json"

# fresh statusline -> 72
assert_eq "$(relay_pct_from_statusline "$rd")" "72" "statusline pct floored"

# stale statusline -> empty
touch -d '2000-01-01' "$rd/statusline.json"
assert_eq "$(relay_pct_from_statusline "$rd")" "" "stale statusline ignored"

# transcript fallback -> 33 (67172/200000), sidechain ignored
assert_eq "$(relay_pct_from_transcript tests/fixtures/transcript.jsonl)" "33" "transcript pct"

# combined: stale tee -> falls back to transcript
assert_eq "$(relay_context_pct "$rd" tests/fixtures/transcript.jsonl)" "33" "combined falls back"

# combined: fresh tee -> uses tee
cp tests/fixtures/statusline.json "$rd/statusline.json"
assert_eq "$(relay_context_pct "$rd" tests/fixtures/transcript.jsonl)" "72" "combined prefers tee"

finish
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bash relay/tests/test_telemetry.sh`
Expected: FAIL — `lib/telemetry.sh` missing.

- [ ] **Step 4: Implement telemetry.sh**

Create `relay/lib/telemetry.sh`:
```bash
#!/usr/bin/env bash
# Context-% telemetry: statusline tee (authoritative) then transcript fallback.
: "${RELAY_STALE_S:=90}"
: "${RELAY_CTX_WINDOW:=200000}"

_relay_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

relay_pct_from_statusline() {
  local f="$1/statusline.json"
  [ -f "$f" ] || return 0
  local now age pct
  now="$(date +%s)"; age=$(( now - $(_relay_mtime "$f") ))
  [ "$age" -le "$RELAY_STALE_S" ] || return 0
  pct="$(jq -r '.context_window.used_percentage // empty' "$f" 2>/dev/null)"
  [ -n "$pct" ] || return 0
  printf '%s\n' "${pct%.*}"   # floor to int
}

relay_pct_from_transcript() {
  local tp="$1"
  [ -f "$tp" ] || return 0
  local tokens
  tokens="$(jq -s '
    [ .[] | select(.type=="assistant")
          | select(.isSidechain != true)
          | select(.message.usage != null) ] | last
    | if . == null then empty
      else (.message.usage.input_tokens // 0)
         + (.message.usage.cache_creation_input_tokens // 0)
         + (.message.usage.cache_read_input_tokens // 0)
      end' "$tp" 2>/dev/null)"
  [ -n "$tokens" ] || return 0
  printf '%s\n' "$(( tokens * 100 / RELAY_CTX_WINDOW ))"
}

relay_context_pct() {
  local rd="$1" tp="$2" pct
  pct="$(relay_pct_from_statusline "$rd")"
  [ -n "$pct" ] && { printf '%s\n' "$pct"; return 0; }
  relay_pct_from_transcript "$tp"
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash relay/tests/test_telemetry.sh`
Expected: `--- N passed, 0 failed ---`.

- [ ] **Step 6: Commit**

```bash
git add relay/lib/telemetry.sh relay/tests/test_telemetry.sh relay/tests/fixtures
git commit -m "feat: context-% telemetry with tee-primary, transcript-fallback"
```

---

## Task 4: Policy — threshold decision

**Files:**
- Create: `relay/lib/policy.sh`, `relay/tests/test_policy.sh`

**Interfaces:**
- Consumes: `lib/state.sh` (`relay_state_get`).
- Produces (`lib/policy.sh`, sourced):
  - `relay_should_rotate <run_dir> <pct> <stop_hook_active>` → echoes `rotate` or `continue`. Rules: `continue` if pct empty, if `stop_hook_active`=="true", if already `rotation_pending`, or if `pct < rotate_at_pct`; else `rotate`.
  - `relay_cap_hit <run_dir> <runtime_s> <cost_usd>` → echoes `gen`|`runtime`|`cost`|`none`. Checks next generation against `max_gen`, elapsed vs `max_runtime_s`, cost vs `max_cost_usd`. (Caps evaluated at rotation edge, not per-turn.)

- [ ] **Step 1: Write the failing test**

Create `relay/tests/test_policy.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/state.sh
source lib/policy.sh

rd="$(mktemp -d)"
relay_state_init "$rd" 60 "" "" "" $$

assert_eq "$(relay_should_rotate "$rd" 59 false)" "continue" "below threshold"
assert_eq "$(relay_should_rotate "$rd" 60 false)" "rotate"   "at threshold"
assert_eq "$(relay_should_rotate "$rd" 85 false)" "rotate"   "above threshold"
assert_eq "$(relay_should_rotate "$rd" ""  false)" "continue" "empty pct is safe"
assert_eq "$(relay_should_rotate "$rd" 85 true)"  "continue" "stop_hook_active blocks"

relay_state_set "$rd" '.rotation_pending=true'
assert_eq "$(relay_should_rotate "$rd" 85 false)" "continue" "already pending"
relay_state_set "$rd" '.rotation_pending=false'

# caps: none configured
assert_eq "$(relay_cap_hit "$rd" 100 0.5)" "none" "no caps -> none"
# max_gen=2, current gen=1 -> next gen=2 is NOT over 2 -> none; gen=2 -> next=3 > 2 -> gen
relay_state_set "$rd" '.policy.max_gen=2'
assert_eq "$(relay_cap_hit "$rd" 0 0)" "none" "gen 1 next 2 within cap"
relay_state_set "$rd" '.generation=2'
assert_eq "$(relay_cap_hit "$rd" 0 0)" "gen" "gen cap hit"
# runtime
relay_state_set "$rd" '.policy.max_gen=null | .policy.max_runtime_s=50'
assert_eq "$(relay_cap_hit "$rd" 60 0)" "runtime" "runtime cap hit"
assert_eq "$(relay_cap_hit "$rd" 40 0)" "none" "runtime within"
# cost
relay_state_set "$rd" '.policy.max_runtime_s=null | .policy.max_cost_usd=1.0'
assert_eq "$(relay_cap_hit "$rd" 0 1.5)" "cost" "cost cap hit"
assert_eq "$(relay_cap_hit "$rd" 0 0.5)" "none" "cost within"

finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash relay/tests/test_policy.sh`
Expected: FAIL — `lib/policy.sh` missing.

- [ ] **Step 3: Implement policy.sh**

Create `relay/lib/policy.sh`:
```bash
#!/usr/bin/env bash
# Policy decisions. Threshold at each turn; caps at rotation edge.
relay_should_rotate() {
  local rd="$1" pct="$2" sha="$3"
  [ -n "$pct" ] || { echo continue; return; }
  [ "$sha" = "true" ] && { echo continue; return; }
  [ "$(relay_state_get "$rd" '.rotation_pending')" = "true" ] && { echo continue; return; }
  local thr; thr="$(relay_state_get "$rd" '.policy.rotate_at_pct')"
  if [ "$pct" -ge "$thr" ]; then echo rotate; else echo continue; fi
}

relay_cap_hit() {
  local rd="$1" runtime="$2" cost="$3"
  local maxgen maxrt maxcost gen next
  maxgen="$(relay_state_get "$rd" '.policy.max_gen')"
  maxrt="$(relay_state_get "$rd" '.policy.max_runtime_s')"
  maxcost="$(relay_state_get "$rd" '.policy.max_cost_usd')"
  gen="$(relay_state_get "$rd" '.generation')"; next=$(( gen + 1 ))
  if [ "$maxgen" != "null" ] && [ "$next" -gt "$maxgen" ]; then echo gen; return; fi
  if [ "$maxrt" != "null" ] && [ "$runtime" -ge "$maxrt" ]; then echo runtime; return; fi
  if [ "$maxcost" != "null" ] && awk "BEGIN{exit !($cost >= $maxcost)}"; then echo cost; return; fi
  echo none
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash relay/tests/test_policy.sh`
Expected: `--- N passed, 0 failed ---`.

- [ ] **Step 5: Commit**

```bash
git add relay/lib/policy.sh relay/tests/test_policy.sh
git commit -m "feat: rotation threshold + cap policy decisions"
```

---

## Task 5: Handoff instruction text (two-tier)

**Files:**
- Create: `relay/lib/handoff_instruction.sh`, `relay/tests/test_handoff_instruction.sh`

**Interfaces:**
- Consumes: none.
- Produces (`lib/handoff_instruction.sh`, sourced):
  - `relay_handoff_instruction <handoff_md_path> <marker_path>` → echoes the full two-tier rotate instruction (spec §10), with the two paths interpolated. Must mention: PREFERRED handoff-skill path with the two overrides; FALLBACK two-pass + regenerate-and-replace; and creating the marker as the final action.

- [ ] **Step 1: Write the failing test**

Create `relay/tests/test_handoff_instruction.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/handoff_instruction.sh

out="$(relay_handoff_instruction /tmp/run/gen-3/handoff.md /tmp/run/gen-3/handoff.ready)"
assert_contains "$out" "/tmp/run/gen-3/handoff.md" "handoff path present"
assert_contains "$out" "/tmp/run/gen-3/handoff.ready" "marker path present"
assert_contains "$out" "handoff skill" "PREFERRED tier mentions skill"
assert_contains "$out" "REGENERATE" "FALLBACK regenerate-and-replace present"
assert_contains "$out" "final action" "marker-as-final-action present"
finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash relay/tests/test_handoff_instruction.sh`
Expected: FAIL — `lib/handoff_instruction.sh` missing.

- [ ] **Step 3: Implement handoff_instruction.sh**

Create `relay/lib/handoff_instruction.sh`:
```bash
#!/usr/bin/env bash
# Emits the two-tier rotate instruction sent as the Stop hook's block reason.
relay_handoff_instruction() {
  local hp="$1" mp="$2"
  cat <<EOF
ROTATION REQUESTED — you are about to be replaced by a fresh session with empty context.
Write a COMPLETE handoff to $hp so your successor can continue with zero prior memory.

PREFERRED: if you have a handoff skill available, invoke it now, with two overrides:
  - Save to $hp (NOT the temp-dir default).
  - Skip the "paste-prompt for the user" step; instead create the marker below.

FALLBACK: if you do NOT have a handoff skill, write $hp yourself. It is a --resume,
not a summary. Two passes:
  Pass 1 (WHAT): objective and what "done" looks like; task list (done/doing/todo);
    key files, branch, and build/test/run commands — BY REFERENCE, do not paste contents.
  Pass 2 (HOW): operating rules WITH their why; decisions and rationale; dead ends and
    gotchas (what NOT to retry); the workflow to resume if one is in use.
  REGENERATE-AND-REPLACE: the prior handoff is already in your context. Do NOT fold it in
    verbatim. Carry forward only what is still true and serves the REMAINING work; collapse
    completed tasks to one line; drop settled decisions and foreclosed dead ends; re-audit
    the reference list so it does not grow each cycle. Keep the Goal section stable.

As your FINAL action, create the empty marker file $mp . Do nothing else — do not continue the task.
EOF
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash relay/tests/test_handoff_instruction.sh`
Expected: `--- N passed, 0 failed ---`.

- [ ] **Step 5: Commit**

```bash
git add relay/lib/handoff_instruction.sh relay/tests/test_handoff_instruction.sh
git commit -m "feat: two-tier handoff rotate instruction"
```

---

## Task 6: The plugin — manifest + Stop hook + SessionStart hook

**Files:**
- Create: `relay/.claude-plugin/plugin.json`, `relay/hooks/hooks.json`, `relay/hooks/stop-hook.sh`, `relay/hooks/session-start-hook.sh`, `relay/tests/test_ipc_hook.sh`

**Interfaces:**
- Consumes: run-dir env (`RELAY_RUN_DIR`, `RELAY_HANDOFF_PATH`).
- Produces:
  - `stop-hook.sh`: reads Stop payload on stdin; if `RELAY_RUN_DIR` unset/absent → exit 0. Else: `rm -f` stale `stop-response.json`; atomically write payload to `stop-request.json`; poll for `stop-response.json` up to 5s; if response is `{}` or timeout → exit 0 (empty stdout); else print response JSON verbatim, exit 0.
  - `session-start-hook.sh`: if `RELAY_HANDOFF_PATH` set and file exists → print a one-line framing header + the handoff file to stdout; else exit 0.
  - File-IPC contract with supervisor (Task 7): request at `$RELAY_RUN_DIR/stop-request.json`, response at `$RELAY_RUN_DIR/stop-response.json`.

- [ ] **Step 1: Write the failing test (hook IPC client behavior, no real claude)**

Create `relay/tests/test_ipc_hook.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh

# no supervisor env -> no-op, exit 0, no output
out="$(unset RELAY_RUN_DIR; printf '{}' | bash hooks/stop-hook.sh)"; rc=$?
assert_eq "$rc" "0" "no-op exit 0"
assert_eq "$out" "" "no-op empty stdout"

# with run dir: simulate supervisor answering {} (continue)
rd="$(mktemp -d)"
( sleep 0.3; printf '{}' > "$rd/stop-response.json" ) &
out="$(RELAY_RUN_DIR="$rd" printf '{"hook_event_name":"Stop","transcript_path":"/x"}' | RELAY_RUN_DIR="$rd" bash hooks/stop-hook.sh)"
assert_eq "$out" "" "continue -> empty stdout"
assert_file_exists "$rd/stop-request.json" "request was written"
wait

# with run dir: supervisor answers a block decision
rd2="$(mktemp -d)"
( sleep 0.3; printf '{"decision":"block","reason":"ROTATE"}' > "$rd2/stop-response.json" ) &
out="$(RELAY_RUN_DIR="$rd2" bash -c 'printf "{\"hook_event_name\":\"Stop\"}" | bash hooks/stop-hook.sh')"
assert_contains "$out" '"decision":"block"' "block relayed to stdout"
assert_contains "$out" "ROTATE" "reason relayed"
wait

# session-start injection
rd3="$(mktemp -d)"; mkdir -p "$rd3/gen-1"; echo "PRIOR HANDOFF BODY" > "$rd3/gen-1/handoff.md"
out="$(RELAY_HANDOFF_PATH="$rd3/gen-1/handoff.md" bash hooks/session-start-hook.sh)"
assert_contains "$out" "PRIOR HANDOFF BODY" "handoff injected"
# no handoff -> empty
out="$(unset RELAY_HANDOFF_PATH; bash hooks/session-start-hook.sh)"
assert_eq "$out" "" "no handoff -> empty"

finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash relay/tests/test_ipc_hook.sh`
Expected: FAIL — hook scripts missing.

- [ ] **Step 3: Implement the plugin manifest and hooks.json**

Create `relay/.claude-plugin/plugin.json`:
```json
{
  "name": "relay",
  "description": "relay session-rotation adapter: Stop + SessionStart hooks that delegate rotation to the relay supervisor",
  "version": "0.1.0"
}
```
Create `relay/hooks/hooks.json`:
```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
        "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.sh\"",
        "async": false } ] }
    ],
    "SessionStart": [
      { "matcher": "startup|resume",
        "hooks": [ { "type": "command",
          "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/session-start-hook.sh\"",
          "async": false } ] }
    ]
  }
}
```

- [ ] **Step 4: Implement stop-hook.sh**

Create `relay/hooks/stop-hook.sh`:
```bash
#!/usr/bin/env bash
# Stop hook: delegate rotate/continue decision to the relay supervisor via file IPC.
# Must NEVER hard-fail the turn: always exit 0.
set -uo pipefail
payload="$(cat)"
rd="${RELAY_RUN_DIR:-}"
[ -n "$rd" ] && [ -d "$rd" ] || exit 0

rm -f "$rd/stop-response.json" 2>/dev/null
printf '%s' "$payload" > "$rd/stop-request.json.tmp" 2>/dev/null || exit 0
mv "$rd/stop-request.json.tmp" "$rd/stop-request.json" 2>/dev/null || exit 0

# poll up to 5s (50 * 0.1)
for _ in $(seq 1 50); do
  if [ -f "$rd/stop-response.json" ]; then
    resp="$(cat "$rd/stop-response.json" 2>/dev/null)"
    rm -f "$rd/stop-response.json" 2>/dev/null
    [ -z "$resp" ] || [ "$resp" = "{}" ] && exit 0
    printf '%s\n' "$resp"
    exit 0
  fi
  sleep 0.1
done
exit 0   # timeout -> no-op (supervisor absent/hung)
```

- [ ] **Step 5: Implement session-start-hook.sh**

Create `relay/hooks/session-start-hook.sh`:
```bash
#!/usr/bin/env bash
# SessionStart hook: inject prior generation's handoff (stdout reaches the model).
set -uo pipefail
hp="${RELAY_HANDOFF_PATH:-}"
[ -n "$hp" ] && [ -f "$hp" ] || exit 0
printf '# Fresh session continuing prior work. Read the handoff below fully; read any files it references on demand as the work needs them.\n\n'
cat "$hp"
exit 0
```

- [ ] **Step 6: Make hooks executable and run tests**

Run:
```bash
chmod +x relay/hooks/stop-hook.sh relay/hooks/session-start-hook.sh
bash relay/tests/test_ipc_hook.sh
```
Expected: `--- N passed, 0 failed ---`.

- [ ] **Step 7: Commit**

```bash
git add relay/.claude-plugin/plugin.json relay/hooks relay/tests/test_ipc_hook.sh
git commit -m "feat: relay plugin — Stop delegate + SessionStart injector (file IPC)"
```

---

## Task 7: Supervisor daemon — the poll loop

**Files:**
- Create: `relay/bin/relay-supervisor.sh`, `relay/tests/test_supervisor_loop.sh`

**Interfaces:**
- Consumes: `lib/rundir.sh`, `lib/state.sh`, `lib/telemetry.sh`, `lib/policy.sh`, `lib/handoff_instruction.sh`; the file-IPC contract from Task 6.
- Produces:
  - `relay-supervisor.sh --run-dir <rd> [--once]` : one iteration (`--once`, for tests) or loop. Each iteration:
    1. If `stop-request.json` exists: read it; `pct=relay_context_pct`; `decision=relay_should_rotate`; if rotate → `relay_state_set rotation_pending=true, pending_marker="gen-<N>/handoff.ready"`, set `RELAY_HANDOFF_TARGET`, write `stop-response.json` = block-with-instruction (via `relay_handoff_instruction`); else write `{}`. Remove `stop-request.json`.
    2. If `rotation_pending`: if `<rd>/<pending_marker>` exists → `relay_state_add_rotation`, bump generation, clear pending, set next-gen `RELAY_HANDOFF_PATH` pointer in `state.json.next_handoff`, `rm` marker, emit `ROTATED` log line. Else if pending age > `RELAY_MARKER_TIMEOUT` (default 120) → clear pending, log `ROTATE_FAILED`.
  - Writes `supervisor.log` lines: `TS EVENT detail`.
  - Note: actual process kill/relaunch is Plan 2. In Plan 1, "rotation" is proven by state transition + marker handling + next-gen handoff pointer.

- [ ] **Step 1: Write the failing test (drive --once transitions)**

Create `relay/tests/test_supervisor_loop.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/state.sh

rd="$(mktemp -d)"; mkdir -p "$rd/gen-1"
relay_state_init "$rd" 60 "" "" "" $$
# force telemetry via fresh statusline at 80%
printf '{"context_window":{"used_percentage":80}}' > "$rd/statusline.json"

# --- iteration 1: a Stop request at 80% -> should decide rotate ---
printf '{"hook_event_name":"Stop","transcript_path":"/none","stop_hook_active":false}' > "$rd/stop-request.json"
bash bin/relay-supervisor.sh --run-dir "$rd" --once
assert_file_exists "$rd/stop-response.json" "response written"
assert_contains "$(cat "$rd/stop-response.json")" '"decision":"block"' "decided rotate"
assert_eq "$(relay_state_get "$rd" '.rotation_pending')" "true" "pending set"
assert_eq "$(relay_state_get "$rd" '.pending_marker')" "gen-1/handoff.ready" "marker path recorded"
assert_file_absent "$rd/stop-request.json" "request consumed"

# --- iteration 2: marker appears -> rotation recorded, generation bumped ---
: > "$rd/gen-1/handoff.ready"
bash bin/relay-supervisor.sh --run-dir "$rd" --once
assert_eq "$(relay_state_get "$rd" '.generation')" "2" "generation bumped"
assert_eq "$(relay_state_get "$rd" '.rotation_pending')" "false" "pending cleared"
assert_eq "$(relay_state_get "$rd" '.rotations | length')" "1" "rotation recorded"
assert_file_absent "$rd/gen-1/handoff.ready" "marker consumed"

# --- continue case: below threshold -> {} ---
rd2="$(mktemp -d)"; relay_state_init "$rd2" 60 "" "" "" $$
printf '{"context_window":{"used_percentage":40}}' > "$rd2/statusline.json"
printf '{"hook_event_name":"Stop","transcript_path":"/none","stop_hook_active":false}' > "$rd2/stop-request.json"
bash bin/relay-supervisor.sh --run-dir "$rd2" --once
assert_eq "$(cat "$rd2/stop-response.json")" "{}" "below threshold -> continue"
assert_eq "$(relay_state_get "$rd2" '.rotation_pending')" "false" "no pending"

# --- marker timeout -> ROTATE_FAILED ---
rd3="$(mktemp -d)"; mkdir -p "$rd3/gen-1"; relay_state_init "$rd3" 60 "" "" "" $$
relay_state_set "$rd3" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0'
RELAY_MARKER_TIMEOUT=1 bash bin/relay-supervisor.sh --run-dir "$rd3" --once
assert_eq "$(relay_state_get "$rd3" '.rotation_pending')" "false" "timeout clears pending"
assert_contains "$(cat "$rd3/supervisor.log")" "ROTATE_FAILED" "failure logged"

finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash relay/tests/test_supervisor_loop.sh`
Expected: FAIL — `bin/relay-supervisor.sh` missing.

- [ ] **Step 3: Implement relay-supervisor.sh**

Create `relay/bin/relay-supervisor.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib/rundir.sh"
source "$HERE/lib/state.sh"
source "$HERE/lib/telemetry.sh"
source "$HERE/lib/policy.sh"
source "$HERE/lib/handoff_instruction.sh"

: "${RELAY_MARKER_TIMEOUT:=120}"
RUN_DIR=""; ONCE=0
while [ $# -gt 0 ]; do case "$1" in
  --run-dir) RUN_DIR="$2"; shift 2;;
  --once) ONCE=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$RUN_DIR" ] || { echo "--run-dir required" >&2; exit 2; }

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$RUN_DIR/supervisor.log"; }

handle_stop_request() {
  [ -f "$RUN_DIR/stop-request.json" ] || return 0
  local payload tp sha pct decision gen marker
  payload="$(cat "$RUN_DIR/stop-request.json")"
  tp="$(printf '%s' "$payload" | jq -r '.transcript_path // ""')"
  sha="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false')"
  pct="$(relay_context_pct "$RUN_DIR" "$tp")"
  decision="$(relay_should_rotate "$RUN_DIR" "$pct" "$sha")"
  if [ "$decision" = "rotate" ]; then
    gen="$(relay_state_get "$RUN_DIR" '.generation')"
    marker="gen-$gen/handoff.ready"
    mkdir -p "$RUN_DIR/gen-$gen"
    relay_state_set "$RUN_DIR" \
      ".rotation_pending=true | .pending_marker=\"$marker\" | .pending_since=$(date +%s) | .pending_pct=${pct:-0}"
    relay_handoff_instruction "$RUN_DIR/gen-$gen/handoff.md" "$RUN_DIR/$marker" \
      | jq -Rs '{decision:"block", reason: .}' > "$RUN_DIR/stop-response.json.tmp"
    mv "$RUN_DIR/stop-response.json.tmp" "$RUN_DIR/stop-response.json"
    log "ROTATE_REQUESTED gen=$gen pct=${pct:-NA}"
  else
    printf '{}' > "$RUN_DIR/stop-response.json.tmp"
    mv "$RUN_DIR/stop-response.json.tmp" "$RUN_DIR/stop-response.json"
  fi
  rm -f "$RUN_DIR/stop-request.json"
}

handle_pending_rotation() {
  [ "$(relay_state_get "$RUN_DIR" '.rotation_pending')" = "true" ] || return 0
  local marker gen since now age pct
  marker="$(relay_state_get "$RUN_DIR" '.pending_marker')"
  if [ -f "$RUN_DIR/$marker" ]; then
    gen="$(relay_state_get "$RUN_DIR" '.generation')"
    pct="$(relay_state_get "$RUN_DIR" '.pending_pct')"
    relay_state_add_rotation "$RUN_DIR" "$gen" "${pct:-0}"
    # next gen: point SessionStart at THIS gen's handoff
    relay_state_set "$RUN_DIR" \
      ".generation=$((gen+1)) | .rotation_pending=false | .pending_marker=null | .next_handoff=\"$RUN_DIR/gen-$gen/handoff.md\""
    mkdir -p "$RUN_DIR/gen-$((gen+1))"
    rm -f "$RUN_DIR/$marker"
    log "ROTATED from_gen=$gen to_gen=$((gen+1)) handoff=$RUN_DIR/gen-$gen/handoff.md"
  else
    since="$(relay_state_get "$RUN_DIR" '.pending_since // 0')"
    now="$(date +%s)"; age=$(( now - since ))
    if [ "$age" -ge "$RELAY_MARKER_TIMEOUT" ]; then
      relay_state_set "$RUN_DIR" '.rotation_pending=false | .pending_marker=null'
      log "ROTATE_FAILED reason=marker_timeout age=${age}s"
    fi
  fi
}

iterate() { handle_stop_request; handle_pending_rotation; }

if [ "$ONCE" -eq 1 ]; then iterate; exit 0; fi
trap 'rm -rf "$RUN_DIR"' EXIT
while true; do iterate; sleep 0.2; done
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash relay/tests/test_supervisor_loop.sh`
Expected: `--- N passed, 0 failed ---`.

- [ ] **Step 5: Commit**

```bash
git add relay/bin/relay-supervisor.sh relay/tests/test_supervisor_loop.sh
git commit -m "feat: supervisor poll loop — decision, marker handling, timeout"
```

---

## Task 8: Headless end-to-end integration (real `claude -p`)

**Files:**
- Create: `relay/tests/test_integration_headless.sh`

**Interfaces:**
- Consumes: the whole stack. Proves: real `claude` loads the plugin via `--plugin-dir`, the Stop hook reaches the supervisor, a forced-low threshold triggers a rotate decision, Claude writes the handoff + marker, and the supervisor records the rotation.

- [ ] **Step 1: Write the integration test**

Create `relay/tests/test_integration_headless.sh`:
```bash
#!/usr/bin/env bash
# Requires a working `claude` CLI. Skips if absent.
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
command -v claude >/dev/null || { echo "SKIP: no claude CLI"; exit 0; }
source lib/state.sh

rd="$(mktemp -d)"; mkdir -p "$rd/gen-1"
relay_state_init "$rd" 1 "" "" "" $$          # threshold 1% -> always rotate
# fresh statusline at 50% so telemetry is unambiguous and >= 1
printf '{"context_window":{"used_percentage":50}}' > "$rd/statusline.json"

# run supervisor in background
bash bin/relay-supervisor.sh --run-dir "$rd" &
sup=$!
trap 'kill $sup 2>/dev/null; wait $sup 2>/dev/null' EXIT

# run claude headless with the plugin + env; it should be told to rotate,
# write handoff.md to gen-1, and create handoff.ready
RELAY_RUN_DIR="$rd" RELAY_STATE="$rd/statusline.json" \
  claude -p "Reply with the single word: ready." \
  --plugin-dir "$PWD" \
  --permission-mode acceptEdits >/dev/null 2>&1

# give the supervisor a moment to observe the marker
for _ in $(seq 1 25); do
  [ "$(relay_state_get "$rd" '.generation')" = "2" ] && break; sleep 0.2
done

assert_file_exists "$rd/gen-1/handoff.md" "claude wrote the handoff"
assert_eq "$(relay_state_get "$rd" '.generation')" "2" "supervisor recorded rotation"
assert_eq "$(relay_state_get "$rd" '.rotations | length')" "1" "one rotation logged"
assert_contains "$(cat "$rd/supervisor.log")" "ROTATED" "ROTATED logged"

finish
```

- [ ] **Step 2: Run the integration test**

Run: `bash relay/tests/test_integration_headless.sh`
Expected: `--- N passed, 0 failed ---` (or `SKIP` if no `claude`).
If the handoff isn't written: inspect `cat "$rd/supervisor.log"` and the Task 0 env spike — the most likely cause is env not reaching the hook.

- [ ] **Step 3: Commit**

```bash
git add relay/tests/test_integration_headless.sh
git commit -m "test: headless end-to-end rotation with real claude -p"
```

---

## Task 9: Test runner + README pointer

**Files:**
- Create: `relay/tests/run-all.sh`
- Modify: none (no README unless one exists — do not create docs unprompted beyond this runner).

**Interfaces:**
- Produces: `relay/tests/run-all.sh` runs every `test_*.sh`, prints a summary, exits nonzero on any failure.

- [ ] **Step 1: Write the runner**

Create `relay/tests/run-all.sh`:
```bash
#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
fail=0
for t in test_*.sh; do
  echo "== $t =="
  if bash "$t"; then :; else fail=1; echo "  ^ FAILED"; fi
done
[ "$fail" -eq 0 ] && echo "ALL GREEN" || echo "SOME FAILED"
exit "$fail"
```

- [ ] **Step 2: Run all unit tests (integration auto-skips if no claude)**

Run: `bash relay/tests/run-all.sh`
Expected: `ALL GREEN`, exit 0.

- [ ] **Step 3: Commit**

```bash
git add relay/tests/run-all.sh
git commit -m "test: aggregate test runner"
```

---

## Self-Review

**1. Spec coverage:**
- §2 why-external → Task 0 spikes + whole design. ✓
- §3 decisions → threshold 60 (Task 4/plan defaults), tee+fallback telemetry (Task 3), two-tier handoff no-skill-dependency (Task 5), zero-install `--plugin-dir` (Task 6/8), adapter seam (file structure: core `lib/`+`bin/` vs adapter `hooks/`). ✓
- §7 telemetry (tee primary, transcript fallback, sidechain filter, window default) → Task 3. ✓
- §8 state machine (decision at Stop; rotation_pending source of truth; loop-safety via stop_hook_active; ROTATE_FAILED) → Tasks 4,7. Kill/relaunch + `kill-server` ban → **Plan 2** (noted). ✓
- §9 marker protocol (per-gen dirs, await-specific-marker, rm after honored) → Task 7. ✓
- §10 handoff (two-tier, regenerate-and-replace, SessionStart injection, on-demand refs) → Tasks 5,6. ✓
- §11 run dir (mktemp -d, mode 700, delete-on-exit trap, startup prune) → Tasks 1,7. ✓
- §12 IPC → file-based (documented deviation; nc has no server mode) → Task 6,7. ✓
- §13 CLI + subcommands → **Plan 2** (this plan builds the engine the CLI drives). Discovery/prune primitives → Task 1. ✓
- §14 error handling (hook no-op on absent/hung supervisor via 5s poll timeout; marker timeout; nested tmux; kill-race flag) → Tasks 6,7; tmux/kill-race → Plan 2. ✓
- §15 spikes → Task 0. ✓
- §16 tests → Tiers 2 (unit Tasks 1–7) + 3 (headless Task 8); Tier 4 interactive → Plan 2. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every test step shows real assertions. ✓

**3. Type/name consistency:** `relay_state_get/set/init/add_rotation`, `relay_context_pct`, `relay_should_rotate`, `relay_cap_hit`, `relay_handoff_instruction`, `relay_create_rundir/list_live/prune_dead`, `RELAY_RUN_DIR/STATE/HANDOFF_PATH/CTX_WINDOW/STALE_S/MARKER_TIMEOUT` — used identically across tasks. Marker path form `gen-<N>/handoff.ready` consistent in Tasks 6,7. IPC filenames `stop-request.json`/`stop-response.json` consistent Tasks 6,7. ✓

**Deferred to Plan 2 (interactive tmux wrapper):** `relay` CLI + `--` arg split, tmux session hosting, auto-attach, kill/relaunch of a live process, auto-continue `send-keys`, `--attach/--stop/--status/--list`, nested-tmux guard, statusline tee one-time install, exit-vs-rotation lifecycle monitor on a live process, Tier-4 interactive smoke.
