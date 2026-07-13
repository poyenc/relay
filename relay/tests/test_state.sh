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
