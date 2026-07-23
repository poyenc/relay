#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/state.sh

rd="$(mktemp -d)"
relay_state_init "$rd" 60 "" "" "" 0

# Fire N concurrent distinct field writes; with a shared temp + no lock these
# collide (0-byte / invalid JSON / lost fields). With flock+unique-temp all land.
N=40
for i in $(seq 1 "$N"); do
  relay_state_set "$rd" ".k$i=$i" &
done
wait

# a) file is still valid, non-empty JSON
assert_eq "$(jq -e . "$rd/state.json" >/dev/null 2>&1 && echo ok)" "ok" "state.json remains valid JSON after concurrent writes"
assert_eq "$([ -s "$rd/state.json" ] && echo nonempty)" "nonempty" "state.json never truncated to 0 bytes"

# b) no lost updates: every field landed
missing=0
for i in $(seq 1 "$N"); do
  [ "$(jq -r ".k$i // \"MISSING\"" "$rd/state.json")" = "$i" ] || missing=$((missing+1))
done
assert_eq "$missing" "0" "all $N concurrent field writes persisted (no lost updates)"

# c) no leftover temp files (unique temps are named state.json.XXXXXX; the real
# file is exactly state.json, so any state.json.<suffix> sibling is a leftover)
assert_eq "$(ls "$rd"/state.json.* 2>/dev/null | wc -l | tr -d ' ')" "0" "no leftover temp files"

finish
