#!/usr/bin/env bash
# Deterministic per-stage gate for the graceful-teardown work. Drives the REAL
# supervisor against REAL tmux, but hosts a STUB process in the pane instead of
# claude - so it exercises the exact teardown code paths (/exit via send-keys,
# remain-on-exit, #{pane_dead} poll, respawn-pane / kill-pane) without the
# flaky claude rotation trigger.
#
# The stub models claude's response to a typed "/exit":
#   honor  -> a reader that exits when it receives a line (claude that obeys /exit)
#   ignore -> `sleep 600` that never reads stdin  (claude that hangs; force-kill path)
#
# Usage: bash tests/manual/stub-teardown.sh [honor|ignore]   (default honor)
#
# Exercises a single rotation actuation by seeding state and running the
# supervisor with --once, then asserts on supervisor.log + pane state.
set -uo pipefail
cd "$(dirname "$0")/../.."
source lib/state.sh
source tests/assert.sh
command -v tmux >/dev/null || { echo "SKIP: no tmux"; exit 0; }

MODE="${1:-honor}"
RELAY_TMUX="${RELAY_TMUX:-tmux}"

rd="$(mktemp -d)"; mkdir -p "$rd/gen-1"
relay_state_init "$rd" 60 "" "" "" $$
S="relay-stub-$$"

# Pick the stub launch command per mode.
case "$MODE" in
  honor)  gen1_cmd='read -r _ <&0; exit 0' ;;   # exits on first typed line (/exit)
  ignore) gen1_cmd='exec sleep 600' ;;          # never reads stdin -> must be force-killed
  *) echo "usage: $0 [honor|ignore]"; exit 2 ;;
esac

# The next generation's launch cmd (what respawn-pane runs). A distinct marker so
# we can prove the pane process was actually swapped.
next_cmd='exec -a relay_gen2_stub sleep 600'

tmux new-session -d -s "$S" "bash -c '$gen1_cmd'"
relay_state_set "$rd" \
  ".tmux_session=\"$S\" | .launch_cmd=\"$next_cmd\" | .auto_continue=false | .pane_seen=true | .generation=1 | .rotation_pending=true | .pending_marker=\"gen-1/handoff.ready\" | .pending_since=0 | .pending_pct=70 | .handoff_settled=true"
: > "$rd/gen-1/handoff.ready"
printf 'stub handoff for gen-1\n' > "$rd/gen-1/handoff.md"

echo ">> mode=$MODE session=$S"
echo ">> BEFORE pane: $(tmux list-panes -t "$S" -F '#{pane_start_command}' 2>/dev/null)"

cleanup() { tmux kill-pane -t "$S" 2>/dev/null || true; rm -rf "$rd"; }
trap cleanup EXIT

# Run one supervisor iteration: it should actuate the rotation (teardown + respawn).
RELAY_TMUX="$RELAY_TMUX" RELAY_ROTATE_GRACE=0 RELAY_EXIT_TIMEOUT=5 RELAY_NUDGE_DELAY=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd" --once

echo ">> supervisor.log:"; sed 's/^/     /' "$rd/supervisor.log" 2>/dev/null
echo ">> AFTER pane: $(tmux list-panes -t "$S" -F '#{pane_start_command}' 2>/dev/null)"

# Common assertions: rotation completed, next gen launched, session survived.
assert_eq "$(relay_state_get "$rd" '.generation')" "2" "generation bumped to 2"
assert_ok "$(tmux has-session -t "$S" 2>/dev/null && echo alive)" "session still alive after rotation"
after="$(tmux list-panes -t "$S" -F '#{pane_start_command}' 2>/dev/null)"
case "$after" in *relay_gen2_stub*) assert_ok "pane swapped to gen-2 cmd" ;; *) assert_eq "$after" "relay_gen2_stub" "pane swapped to gen-2 cmd" ;; esac

# Mode-specific: which teardown path did the log record?
if [ "$MODE" = "honor" ]; then
  assert_contains "$(cat "$rd/supervisor.log")" "TEARDOWN_EXIT_CLEAN" "honor -> clean /exit path"
else
  assert_contains "$(cat "$rd/supervisor.log")" "TEARDOWN_EXIT_TIMEOUT" "ignore -> force-kill path"
fi

finish
