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

# discovery: seed a live run (a real process carrying --run-dir "$rd" in its argv,
# so relay_pid_is_supervisor matches it) + a dead run (bogus pid).
# redirect helpers' stdio so they don't hold the test's stdout pipe open
bash tests/fake-supervisor.sh --run-dir "$rd" >/dev/null 2>&1 &
LIVE=$!
sleep 60 >/dev/null 2>&1 & IMP=$!
trap 'kill "$LIVE" "$IMP" 2>/dev/null' EXIT
echo "{\"supervisor_pid\": $LIVE, \"generation\": 2}" > "$rd/state.json"
dead="$(relay_root)/run-20200101-dead01"; mkdir -p "$dead"
echo '{"supervisor_pid": 999999, "generation": 1}' > "$dead/state.json"

live="$(relay_list_live)"
assert_contains "$live" "$rd" "live run listed"
assert_eq "$(printf '%s' "$live" | grep -c "$dead")" "0" "dead run not listed"

# PID-recycling guard: a live process whose argv does NOT carry this run dir must
# NOT count as the supervisor (kill -0 alone would wrongly report it live).
imposter="$(relay_root)/run-20200101-imposter"; mkdir -p "$imposter"
echo "{\"supervisor_pid\": $IMP, \"generation\": 1}" > "$imposter/state.json"
assert_eq "$(relay_list_live | grep -c "$imposter")" "0" "recycled-PID imposter not listed"

relay_prune_dead
assert_file_absent "$dead" "dead run pruned"
assert_file_absent "$imposter" "imposter run pruned (argv mismatch)"
assert_file_exists "$rd" "live run survives prune"

finish
