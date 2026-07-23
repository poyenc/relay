#!/usr/bin/env bash
# Manual/interactive real-rotation harness. Unlike test_integration_headless.sh
# (which uses `claude -p` and never enters tmux), this launches the full `relay`
# stack with an INTERACTIVE claude hosted in a detached tmux pane, then drives a
# rotation with send-keys - the only way to exercise the tmux teardown path
# (/exit, remain-on-exit, respawn-pane / kill-pane).
#
# It spends real tokens (one trivial prompt per rotation). Run it by hand, not in
# run-all.sh.
#
# Usage: bash tests/manual/real-rotation.sh [timeout_s]
#   timeout_s: how long to wait for the rotation to complete (default 300).
#
# Exit 0 + "ROTATION OK" on success; nonzero + diagnostics on failure.
set -uo pipefail
cd "$(dirname "$0")/../.."
HERE="$PWD"
source lib/state.sh
source lib/rundir.sh

command -v claude >/dev/null || { echo "SKIP: no claude CLI"; exit 0; }
command -v tmux   >/dev/null || { echo "SKIP: no tmux"; exit 0; }

TIMEOUT="${1:-300}"
RELAY_TMUX="${RELAY_TMUX:-tmux}"

# Launch: rotate at 1% so the first idle turn rotates; --no-auto-continue so the
# next generation waits (no second paid turn) and the rotation edge is observable.
# RELAY_NO_ATTACH keeps our terminal free; the session runs detached.
# --rotation-timeout generous: the rtk PreToolUse hook slows real handoff writing.
echo ">> launching relay (rotate-at 1, no-auto-continue, detached)..."
launch_out="$(RELAY_NO_ATTACH=1 \
  bash bin/relay --rotate-at 1 --no-auto-continue --rotation-timeout 300 \
  -- --dangerously-skip-permissions 2>&1)"
printf '%s\n' "$launch_out" | sed 's/^/   relay: /'

# Pull the exact run_id from the launch banner ("run <id> started").
run_id="$(printf '%s\n' "$launch_out" | sed -n 's/.*run \([0-9a-zA-Z-]*\) started.*/\1/p' | head -n1)"
[ -n "$run_id" ] || { echo "FAIL: could not parse run_id from launch output"; exit 1; }
rd="$(relay_root)/$run_id"
[ -d "$rd" ] || { echo "FAIL: run dir $rd not found"; exit 1; }
sess="$(relay_state_get "$rd" '.tmux_session')"
echo ">> run dir: $rd"
echo ">> session: $sess"

SNAP="/tmp/relay-diag-$(basename "$rd")"
cleanup() {
  echo ">> snapshotting run dir to $SNAP (before supervisor rm -rf)"
  cp -a "$rd" "$SNAP" 2>/dev/null || true
  echo ">> cleanup"
  "$RELAY_TMUX" kill-pane -t "$sess" 2>/dev/null || true
  local pid; pid="$(relay_state_get "$rd" '.supervisor_pid' 2>/dev/null)"
  [ -n "$pid" ] && [ "$pid" != "null" ] && kill "$pid" 2>/dev/null || true
  echo ">> snapshot contents:"; ls -R "$SNAP" 2>/dev/null | sed 's/^/     /'
}
trap cleanup EXIT

# Wait for the pane to boot, then send a trivial prompt so claude produces one
# turn, goes idle -> Stop hook fires -> supervisor requests a handoff -> rotation.
echo ">> waiting 8s for claude to boot..."
sleep 8
echo ">> sending prompt..."
"$RELAY_TMUX" send-keys -t "$sess" "Reply with exactly: ready" Enter 2>/dev/null || {
  echo "FAIL: send-keys failed (pane gone?)"; exit 1; }

# Poll for the TEARDOWN log line (emitted inside graceful_teardown, i.e. AFTER the
# /exit teardown ran) rather than just generation==2. generation is bumped BEFORE
# actuate_rotation runs, so gating on it would let us snapshot/kill mid-teardown
# and miss the very behavior under test.
echo ">> polling for teardown+rotation, up to ${TIMEOUT}s..."
deadline=$(( $(date +%s) + TIMEOUT ))
gen=1; teardown=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  gen="$(relay_state_get "$rd" '.generation' 2>/dev/null || echo 1)"
  teardown="$(grep -oE 'TEARDOWN_EXIT_(CLEAN|TIMEOUT)' "$rd/supervisor.log" 2>/dev/null | head -n1)"
  [ "$gen" = "2" ] && [ -n "$teardown" ] && break
  [ "$(relay_state_get "$rd" '.status // "live"' 2>/dev/null)" = "stopped" ] && {
    echo "!! run stopped before rotation"; break; }
  sleep 2
done

echo "======================================================================"
echo ">> generation: $gen"
echo ">> teardown:   ${teardown:-<none observed>}"
echo ">> supervisor.log:"; sed 's/^/     /' "$rd/supervisor.log" 2>/dev/null || echo "  (none)"
echo ">> gen dirs:"; ls -la "$rd"/gen-* 2>/dev/null | sed 's/^/     /'
[ -f "$rd/gen-1/handoff.md" ] && echo ">> handoff.md: PRESENT ($(wc -l < "$rd/gen-1/handoff.md") lines)" || echo ">> handoff.md: MISSING"
[ -f "$rd/gen-1/pane.log" ] && echo ">> pane.log: PRESENT" || echo ">> pane.log: MISSING"
echo "======================================================================"

if [ "$gen" = "2" ] && [ -n "$teardown" ]; then
  echo "ROTATION OK ($teardown)"
  exit 0
else
  echo "ROTATION FAILED (gen=$gen teardown=${teardown:-none})"
  exit 1
fi
