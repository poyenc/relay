#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/telemetry.sh

rd="$(mktemp -d)"
cp tests/fixtures/statusline.json "$rd/statusline.json"

# fresh statusline -> 72
assert_eq "$(relay_pct_from_statusline "$rd")" "72" "statusline pct floored"

# stale statusline -> empty
touch -d '2000-01-01' "$rd/statusline.json"
assert_eq "$(relay_pct_from_statusline "$rd")" "" "stale statusline ignored"

# transcript fallback -> 33 (67172/200000), sidechain ignored
assert_eq "$(relay_pct_from_transcript tests/fixtures/transcript.jsonl)" "33" "transcript pct"

# combined: stale tee -> falls back to transcript
assert_eq "$(relay_context_pct "$rd" tests/fixtures/transcript.jsonl)" "33" "combined falls back"

# combined: fresh tee -> uses tee
cp tests/fixtures/statusline.json "$rd/statusline.json"
assert_eq "$(relay_context_pct "$rd" tests/fixtures/transcript.jsonl)" "72" "combined prefers tee"

finish
