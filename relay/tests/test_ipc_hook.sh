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
