#!/usr/bin/env bash
# Real-tmux teardown tests (NO claude, NO tokens). Drives the REAL supervisor
# against a REAL tmux server, hosting a stub process in the pane, to prove the
# behaviors the fake-tmux unit tests cannot: remain-on-exit lingering, the
# #{pane_dead} poll, kill-pane reaping, multi-pane safety (a user's split pane
# survives relay's teardown), and last-pane session collapse.
#
# Skips cleanly where tmux is unavailable. Uses a private tmux socket so it can
# never touch the user's real sessions.
set -uo pipefail
cd "$(dirname "$0")/.."
source lib/state.sh
source tests/assert.sh

command -v tmux >/dev/null || { echo "SKIP: no tmux"; echo "--- 0 passed, 0 failed ---"; exit 0; }

# Private tmux server (own socket) so this test is fully isolated from any real
# sessions and from other runs. Everything targets this socket via $TM.
SOCK="$(mktemp -u /tmp/relay-test-tmux.XXXXXX)"
TM=(tmux -S "$SOCK")
RELAY_TMUX_BIN="$(command -v tmux)"
# A wrapper so the supervisor uses our private socket too.
TMWRAP="$(mktemp)"; chmod +x "$TMWRAP"
cat > "$TMWRAP" <<EOF
#!/usr/bin/env bash
exec "$RELAY_TMUX_BIN" -S "$SOCK" "\$@"
EOF

cleanup() {
  "${TM[@]}" kill-server 2>/dev/null || true
  rm -f "$TMWRAP" "$SOCK" 2>/dev/null || true
  [ -n "${rd1:-}" ] && rm -rf "$rd1" 2>/dev/null || true
  [ -n "${rd2:-}" ] && rm -rf "$rd2" 2>/dev/null || true
  [ -n "${rd3:-}" ] && rm -rf "$rd3" 2>/dev/null || true
  [ -n "${rd4:-}" ] && rm -rf "$rd4" 2>/dev/null || true
}
trap cleanup EXIT

# ---------- 1. rotation, /exit honored -> clean teardown + real respawn ----------
rd1="$(mktemp -d)"; mkdir -p "$rd1/gen-1"
relay_state_init "$rd1" 60 "" "" "" $$
S1="relay-t1-$$"
# gen-1 stub exits on the first typed line (models claude honoring /exit)
pane1="$("${TM[@]}" new-session -d -s "$S1" -P -F '#{pane_id}' "bash -c 'read -r _ <&0; exit 0'")"
relay_state_set "$rd1" \
  ".tmux_session=\"$S1\" | .tmux_pane=\"$pane1\" | .launch_cmd=\"exec -a relay_gen2_stub sleep 600\" | .auto_continue=false | .pane_seen=true | .rotation_pending=true | .pending_marker=\"gen-1/handoff.ready\" | .pending_since=0 | .pending_pct=70 | .handoff_settled=true"
: > "$rd1/gen-1/handoff.ready"; printf 'h\n' > "$rd1/gen-1/handoff.md"
RELAY_TMUX="$TMWRAP" RELAY_ROTATE_GRACE=0 RELAY_EXIT_TIMEOUT=5 RELAY_NUDGE_DELAY=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd1" --once
assert_eq "$(relay_state_get "$rd1" '.generation')" "2" "rotation bumped generation (real tmux)"
assert_contains "$(cat "$rd1/supervisor.log")" "TEARDOWN_EXIT_CLEAN" "honored /exit -> clean teardown"
"${TM[@]}" has-session -t "$S1" 2>/dev/null && s1_alive=1 || s1_alive=0
assert_eq "$s1_alive" "1" "session survives rotation"
assert_contains "$("${TM[@]}" list-panes -t "$S1" -F '#{pane_start_command}' 2>/dev/null)" "relay_gen2_stub" "pane really respawned to gen-2 cmd"
assert_file_exists "$rd1/gen-1/pane.log" "pane captured to pane.log (real tmux)"

# ---------- 2. rotation, /exit ignored -> poll times out, force-kill respawns ----------
rd2="$(mktemp -d)"; mkdir -p "$rd2/gen-1"
relay_state_init "$rd2" 60 "" "" "" $$
S2="relay-t2-$$"
# gen-1 stub never reads stdin -> /exit ignored -> must be force-killed by respawn -k
pane2="$("${TM[@]}" new-session -d -s "$S2" -P -F '#{pane_id}' "bash -c 'exec sleep 600'")"
relay_state_set "$rd2" \
  ".tmux_session=\"$S2\" | .tmux_pane=\"$pane2\" | .launch_cmd=\"exec -a relay_gen2_stub sleep 600\" | .auto_continue=false | .pane_seen=true | .rotation_pending=true | .pending_marker=\"gen-1/handoff.ready\" | .pending_since=0 | .pending_pct=70 | .handoff_settled=true"
: > "$rd2/gen-1/handoff.ready"; printf 'h\n' > "$rd2/gen-1/handoff.md"
RELAY_TMUX="$TMWRAP" RELAY_ROTATE_GRACE=0 RELAY_EXIT_TIMEOUT=2 RELAY_NUDGE_DELAY=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd2" --once
assert_contains "$(cat "$rd2/supervisor.log")" "TEARDOWN_EXIT_TIMEOUT" "hung /exit -> timeout path"
assert_eq "$(relay_state_get "$rd2" '.generation')" "2" "force-kill respawn still rotated"
assert_contains "$("${TM[@]}" list-panes -t "$S2" -F '#{pane_start_command}' 2>/dev/null)" "relay_gen2_stub" "pane respawned after force-kill"

# ---------- 3. MULTI-PANE SAFETY: stop kills relay's pane, user's split survives ----------
rd3="$(mktemp -d)"; mkdir -p "$rd3/gen-1"
relay_state_init "$rd3" 60 "" "" "" $$
S3="relay-t3-$$"
relaypane="$("${TM[@]}" new-session -d -s "$S3" -P -F '#{pane_id}' "bash -c 'read -r _ <&0; exit 0'")"
# user splits their OWN pane into relay's window (long-lived; must NOT be touched)
userpane="$("${TM[@]}" split-window -t "$relaypane" -P -F '#{pane_id}' 'sleep 600')"
relay_state_set "$rd3" \
  ".tmux_session=\"$S3\" | .tmux_pane=\"$relaypane\" | .pane_seen=true"
printf '{"reason":"user_stop"}' > "$rd3/stop-run.json"
RELAY_TMUX="$TMWRAP" RELAY_ROTATE_GRACE=0 RELAY_EXIT_TIMEOUT=5 \
  bash bin/relay-supervisor.sh --run-dir "$rd3" --once
assert_eq "$(relay_state_get "$rd3" '.status')" "stopped" "user_stop -> stopped"
assert_contains "$(cat "$rd3/supervisor.log")" "STOPPED reason=user_stop" "user_stop logged"
# relay's pane must be gone, the user's pane must remain, session still alive.
panes_after="$("${TM[@]}" list-panes -t "$S3" -F '#{pane_id}' 2>/dev/null)"
assert_eq "$(printf '%s' "$panes_after" | grep -c -- "$relaypane")" "0" "relay pane reaped by stop"
assert_eq "$(printf '%s' "$panes_after" | grep -c -- "$userpane")" "1" "USER pane survived stop (multi-pane safety)"
"${TM[@]}" has-session -t "$S3" 2>/dev/null && s3_alive=1 || s3_alive=0
assert_eq "$s3_alive" "1" "session alive via user's pane (no kill-session)"

# ---------- 4. LAST-PANE COLLAPSE: stop with only relay's pane -> session gone ----------
rd4="$(mktemp -d)"; mkdir -p "$rd4/gen-1"
relay_state_init "$rd4" 60 "" "" "" $$
S4="relay-t4-$$"
onlypane="$("${TM[@]}" new-session -d -s "$S4" -P -F '#{pane_id}' "bash -c 'read -r _ <&0; exit 0'")"
relay_state_set "$rd4" \
  ".tmux_session=\"$S4\" | .tmux_pane=\"$onlypane\" | .pane_seen=true"
printf '{"reason":"user_stop"}' > "$rd4/stop-run.json"
RELAY_TMUX="$TMWRAP" RELAY_ROTATE_GRACE=0 RELAY_EXIT_TIMEOUT=5 \
  bash bin/relay-supervisor.sh --run-dir "$rd4" --once
"${TM[@]}" has-session -t "$S4" 2>/dev/null && s4_alive=1 || s4_alive=0
assert_eq "$s4_alive" "0" "last-pane stop collapses the session (kill-pane on sole pane)"
assert_file_exists "$rd4/state.json" "run dir persists after stop (retention)"

finish
