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

# --- final generation: rotate decision that breaches a cap -> STOP, no handoff ---
rd4="$(mktemp -d)"; mkdir -p "$rd4/gen-1"; relay_state_init "$rd4" 60 1 "" "" $$  # max_gen=1
printf '{"context_window":{"used_percentage":80}}' > "$rd4/statusline.json"
printf '{"hook_event_name":"Stop","transcript_path":"/none","stop_hook_active":false}' > "$rd4/stop-request.json"
bash bin/relay-supervisor.sh --run-dir "$rd4" --once
assert_eq "$(cat "$rd4/stop-response.json")" "{}" "final gen -> no handoff block"
assert_eq "$(relay_state_get "$rd4" '.rotation_pending')" "false" "no pending set on final gen"
assert_file_absent "$rd4/gen-1/handoff.ready" "no handoff marker requested"
assert_eq "$(relay_state_get "$rd4" '.status')" "stopped" "run stopped at cap"
assert_contains "$(cat "$rd4/supervisor.log")" "STOPPED reason=cap:gen" "cap STOP logged"

# --- marker timeout -> ROTATE_FAILED ---
rd3="$(mktemp -d)"; mkdir -p "$rd3/gen-1"; relay_state_init "$rd3" 60 "" "" "" $$
relay_state_set "$rd3" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0'
RELAY_ROTATION_TIMEOUT=1 bash bin/relay-supervisor.sh --run-dir "$rd3" --once
assert_eq "$(relay_state_get "$rd3" '.rotation_pending')" "false" "timeout clears pending"
assert_contains "$(cat "$rd3/supervisor.log")" "ROTATE_FAILED" "failure logged"

finish
