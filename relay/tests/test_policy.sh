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
