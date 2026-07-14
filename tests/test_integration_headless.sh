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
# NOTE: RELAY_MARKER_TIMEOUT raised from the 120s default. In this environment
# the spawned headless `claude -p` session is slowed considerably by a global
# rtk PreToolUse hook that intercepts/requires approval for many Bash calls,
# pushing real end-to-end handoff-writing time past 120s (observed ~215s).
# 280s gives enough margin without masking a genuinely broken rotation.
RELAY_MARKER_TIMEOUT=280 bash bin/relay-supervisor.sh --run-dir "$rd" &
sup=$!
trap 'kill $sup 2>/dev/null; wait $sup 2>/dev/null' EXIT

# run claude headless with the plugin + env; it should be told to rotate,
# write handoff.md to gen-1, and create handoff.ready
RELAY_RUN_DIR="$rd" RELAY_STATE="$rd/statusline.json" \
  claude -p "Reply with the single word: ready." \
  --plugin-dir "$PWD" \
  --permission-mode acceptEdits \
  --add-dir "$rd" >/dev/null 2>&1

# give the supervisor a moment to observe the marker
for _ in $(seq 1 25); do
  [ "$(relay_state_get "$rd" '.generation')" = "2" ] && break; sleep 0.2
done

assert_file_exists "$rd/gen-1/handoff.md" "claude wrote the handoff"
assert_eq "$(relay_state_get "$rd" '.generation')" "2" "supervisor recorded rotation"
assert_eq "$(relay_state_get "$rd" '.rotations | length')" "1" "one rotation logged"
assert_contains "$(cat "$rd/supervisor.log")" "ROTATED" "ROTATED logged"

finish
