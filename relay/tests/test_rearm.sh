#!/usr/bin/env bash
# Regression for the "dead-air" window: if a rotate block was missed (hook timed
# out), the next idle Stop while rotation_pending must re-deliver the instruction
# instead of returning {} and waiting for marker_timeout.
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/state.sh

mk() {  # -> rd, pending on gen-1, no marker yet
  local rd; rd="$(mktemp -d)"; mkdir -p "$rd/gen-1"
  relay_state_init "$rd" 60 "" "" "" $$
  printf '{"context_window":{"used_percentage":80}}' > "$rd/statusline.json"
  relay_state_set "$rd" ".rotation_pending=true | .pending_marker=\"gen-1/handoff.ready\" | .pending_since=$(date +%s) | .pending_pct=80"
  printf '%s' "$rd"
}

# --- 1. idle Stop while pending, no marker -> RE-ARM (re-emit block) ---
rd="$(mk)"
since_before="$(relay_state_get "$rd" '.pending_since')"
printf '{"hook_event_name":"Stop","transcript_path":"/none","stop_hook_active":false}' > "$rd/stop-request.json"
bash bin/relay-supervisor.sh --run-dir "$rd" --once
assert_contains "$(cat "$rd/stop-response.json")" '"decision":"block"' "re-armed with block"
assert_contains "$(cat "$rd/supervisor.log")" "ROTATE_REARM" "re-arm logged"
# pending_since must NOT be reset (marker_timeout backstop must still fire from original)
assert_eq "$(relay_state_get "$rd" '.pending_since')" "$since_before" "pending_since preserved on re-arm"

# --- 2. loop safety: stop_hook_active=true while pending -> {} (never re-block) ---
rd2="$(mk)"
printf '{"hook_event_name":"Stop","transcript_path":"/none","stop_hook_active":true}' > "$rd2/stop-request.json"
bash bin/relay-supervisor.sh --run-dir "$rd2" --once
assert_eq "$(cat "$rd2/stop-response.json")" "{}" "no re-block when stop_hook_active"

# --- 3. marker already present -> handle_stop_request stays out of the way ({}),
#         and handle_pending_rotation performs the rotation ---
rd3="$(mk)"
: > "$rd3/gen-1/handoff.ready"
printf '{"hook_event_name":"Stop","transcript_path":"/none","stop_hook_active":false}' > "$rd3/stop-request.json"
bash bin/relay-supervisor.sh --run-dir "$rd3" --once
assert_eq "$(cat "$rd3/stop-response.json")" "{}" "no re-arm once marker present"
assert_eq "$(relay_state_get "$rd3" '.generation')" "2" "rotation still completes"

finish
