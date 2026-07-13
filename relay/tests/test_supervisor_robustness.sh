#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/state.sh

# --- --once mode: malformed stop-request.json must not crash or nuke run dir ---
rd="$(mktemp -d)"
relay_state_init "$rd" 60 "" "" "" $$
printf 'NOT JSON AT ALL' > "$rd/stop-request.json"

bash bin/relay-supervisor.sh --run-dir "$rd" --once
rc=$?
assert_eq "$rc" "0" "supervisor --once survives malformed stop-request"
assert_file_exists "$rd/state.json" "run dir/state.json survives malformed request"
assert_file_absent "$rd/stop-request.json" "malformed request consumed, not left to wedge loop"

# --- loop mode: daemon must survive a bad request and keep running ---
rd2="$(mktemp -d)"
relay_state_init "$rd2" 60 "" "" "" $$
printf 'NOT JSON AT ALL' > "$rd2/stop-request.json"

bash bin/relay-supervisor.sh --run-dir "$rd2" &
pid=$!
sleep 1

assert_file_exists "$rd2/state.json" "run dir survives in daemon/loop mode"
if kill -0 "$pid" 2>/dev/null; then
  _A_PASS=$((_A_PASS+1))
else
  _A_FAIL=$((_A_FAIL+1)); echo "FAIL: daemon process died after malformed request"
fi

kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

finish
