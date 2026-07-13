#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/rundir.sh

export TMPDIR; TMPDIR="$(mktemp -d)"   # isolate from real /tmp/relay

# create
rd="$(relay_create_rundir)"
assert_file_exists "$rd" "rundir created"
mode="$(stat -c '%a' "$(relay_root)")"
assert_eq "$mode" "700" "root is mode 700"

# discovery: seed a live + a dead run
echo "{\"supervisor_pid\": $$, \"generation\": 2}" > "$rd/state.json"
dead="$(relay_root)/run-20200101-dead01"; mkdir -p "$dead"
echo '{"supervisor_pid": 999999, "generation": 1}' > "$dead/state.json"

live="$(relay_list_live)"
assert_contains "$live" "$rd" "live run listed"
assert_eq "$(printf '%s' "$live" | grep -c "$dead")" "0" "dead run not listed"

relay_prune_dead
assert_file_absent "$dead" "dead run pruned"
assert_file_exists "$rd" "live run survives prune"

finish
