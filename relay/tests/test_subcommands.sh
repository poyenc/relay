#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/state.sh
source lib/rundir.sh
source lib/subcommands.sh

FAKE="$PWD/tests/fake-tmux.sh"; chmod +x "$FAKE"
export RELAY_TMUX="$FAKE"
export TMPDIR; TMPDIR="$(mktemp -d)"    # isolate run root

# seed two live runs + one dead run under the isolated root
mk_run() {  # <suffix> <pid> <gen>
  local rd; rd="$(relay_root)/run-2026-$1"; mkdir -p "$rd"
  relay_state_init "$rd" 60 "" "" "" "$2"
  jq --arg r "run-2026-$1" --argjson g "$3" --arg s "relay-run-2026-$1" \
     '.run_id=$r | .generation=$g | .tmux_session=$s' \
     "$rd/state.json" > "$rd/state.json.tmp" && mv "$rd/state.json.tmp" "$rd/state.json"
  printf '%s' "$rd"
}
mkdir -p "$(relay_root)"; chmod 700 "$(relay_root)"
sleep 30 & LIVE1=$!; live1_rd="$(mk_run aaaa "$LIVE1" 3)"
sleep 30 & LIVE2=$!; live2_rd="$(mk_run bbbb "$LIVE2" 1)"
dead_rd="$(mk_run cccc 999999 2)"

# --- resolver: unique prefix match ---
assert_eq "$(relay_resolve_run_id run-2026-aa)" "$live1_rd" "unique prefix resolves"
assert_eq "$(relay_resolve_run_id run-2026-aaaa)" "$live1_rd" "full id resolves"

# --- resolver: ambiguous prefix fails ---
if relay_resolve_run_id run-2026 >/dev/null 2>&1; then assert_eq bad ok "ambiguous should fail"; else assert_ok "ambiguous prefix rejected"; fi
# --- resolver: no match fails ---
if relay_resolve_run_id nope >/dev/null 2>&1; then assert_eq bad ok "no-match should fail"; else assert_ok "no match rejected"; fi
# --- resolver ignores dead runs ---
if relay_resolve_run_id run-2026-cccc >/dev/null 2>&1; then assert_eq bad ok "dead run should not resolve"; else assert_ok "dead run not resolvable"; fi

# --- list: shows both live, not the dead one; prunes dead ---
out="$(relay_cmd_list)"
assert_contains "$out" "run-2026-aaaa" "list shows live1"
assert_contains "$out" "run-2026-bbbb" "list shows live2"
assert_eq "$(printf '%s' "$out" | grep -c 'run-2026-cccc')" "0" "list hides dead"
assert_file_absent "$dead_rd" "dead run pruned by list"

# --- status: prints state of a run by prefix ---
out="$(relay_cmd_status run-2026-aa)"
assert_contains "$out" "run-2026-aaaa" "status shows id"
assert_contains "$out" "3" "status shows generation"

# --- stop: kills session, signals supervisor ---
stoplog="$TMPDIR/stop-tmux.log"; : > "$stoplog"
FAKE_TMUX_LOG="$stoplog" relay_cmd_stop run-2026-bbbb >/dev/null 2>&1
assert_contains "$(cat "$stoplog")" "kill-session -t relay-run-2026-bbbb" "stop kills the session"
# supervisor (LIVE2) should have been signalled dead
sleep 0.3
if kill -0 "$LIVE2" 2>/dev/null; then assert_eq alive dead "stop should kill supervisor"; else assert_ok "supervisor terminated by stop"; fi

# cleanup any survivors
kill "$LIVE1" "$LIVE2" 2>/dev/null; wait 2>/dev/null

finish
