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
# team-handoff coverage: roster gate, per-seat files in the gen dir, respawn section
assert_contains "$out" "ROSTER FIRST" "roster gate present"
assert_contains "$out" "/tmp/run/gen-3/handoff-<seat>.md" "per-teammate path in gen dir"
assert_contains "$out" "Respawn the team" "respawn section required for teams"
finish
