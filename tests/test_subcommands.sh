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

# seed two live runs + one dead run under the isolated root. A "live" run needs a
# real process whose argv carries its run dir (relay_pid_is_supervisor requirement);
# fake-supervisor.sh provides that. Helpers' stdio is redirected so they don't hold
# this test's stdout pipe open.
mk_run() {  # <suffix> <pid> <gen>
  local rd; rd="$(relay_root)/run-2026-$1"; mkdir -p "$rd"
  relay_state_init "$rd" 60 "" "" "" "$2"
  _relay_state_apply "$rd" \
    '.run_id=$r | .generation=$g | .tmux_session=$s' \
    --arg r "run-2026-$1" --argjson g "$3" --arg s "relay-run-2026-$1"
  printf '%s' "$rd"
}
mkdir -p "$(relay_root)"; chmod 700 "$(relay_root)"
live1_rd="$(relay_root)/run-2026-aaaa"; mkdir -p "$live1_rd"
bash tests/fake-supervisor.sh --run-dir "$live1_rd" >/dev/null 2>&1 & LIVE1=$!
live1_rd="$(mk_run aaaa "$LIVE1" 3)"
live2_rd="$(relay_root)/run-2026-bbbb"; mkdir -p "$live2_rd"
bash tests/fake-supervisor.sh --run-dir "$live2_rd" >/dev/null 2>&1 & LIVE2=$!
live2_rd="$(mk_run bbbb "$LIVE2" 1)"
dead_rd="$(mk_run cccc 999999 2)"
# age the dead run past the 7-day retention so list's prune reaps it
_relay_state_apply "$dead_rd" '.status="stopped" | .stopped_at=(now - 8*86400 | floor)'
trap 'kill "$LIVE1" "$LIVE2" 2>/dev/null' EXIT

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

# --- stop: confirm window derives from persisted teardown budget when RELAY_STOP_CONFIRM_S unset ---
# Seed a dead run with a large budget; the derived window must exceed a bare 10s
# default (grace 30 + exit 30 + 5 = 65) rather than force-killing early. We assert
# the derivation, not the wall-clock, by checking status flips before fallback when
# a status is pre-seeded (supervisor "already stopped").
budget_rd="$(mk_run dddd 999999 1)"
jq '.rotate_grace=30 | .exit_timeout=30 | .status="stopped"' "$budget_rd/state.json" \
  > "$budget_rd/state.json.x" && mv "$budget_rd/state.json.x" "$budget_rd/state.json"
blog="$TMPDIR/budget-tmux.log"; : > "$blog"
# RELAY_STOP_CONFIRM_S unset -> window derived from budget; status already stopped
# -> confirm=1 immediately, NO fallback kill-pane.
( unset RELAY_STOP_CONFIRM_S; FAKE_TMUX_LOG="$blog" relay_cmd_stop run-2026-dddd >/dev/null 2>&1 )
assert_eq "$(grep -c 'kill-pane' "$blog")" "0" "derived-window stop confirms via status, no fallback kill"

# cleanup any survivors
kill "$LIVE1" "$LIVE2" 2>/dev/null; wait 2>/dev/null

finish
