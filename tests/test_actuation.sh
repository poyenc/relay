#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/state.sh

FAKE="$PWD/tests/fake-tmux.sh"; chmod +x "$FAKE"

# helper: set launch metadata the supervisor needs to actuate a rotation
seed_live() {  # <rd> <auto_continue>
  relay_state_set "$1" ".tmux_session=\"relay-test\" | .tmux_pane=\"%7\" | .launch_cmd=\"claude --plugin-dir /x\" | .auto_continue=$2 | .pane_seen=true"
}

# ---------- 1. rotation actuates: respawn-pane + send-keys nudge ----------
rd="$(mktemp -d)"; mkdir -p "$rd/gen-1"
relay_state_init "$rd" 60 "" "" "" $$
seed_live "$rd" true
relay_state_set "$rd" '.tmux_pane="%7"'   # rotation must target this pane, not the session
relay_state_set "$rd" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70 | .handoff_settled=true'
: > "$rd/gen-1/handoff.ready"
log="$rd/tmux.log"; : > "$log"
FAKE_TMUX_LOG="$log" RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd" --once
assert_eq "$(relay_state_get "$rd" '.generation')" "2" "gen bumped after actuated rotation"
assert_eq "$(relay_state_get "$rd" '.rotation_pending')" "false" "pending cleared"
assert_contains "$(cat "$log")" "send-keys -t %7 /exit Enter" "graceful /exit sent to the launched pane"
assert_contains "$(cat "$log")" "capture-pane -p -t %7" "pane captured before teardown"
assert_contains "$(cat "$log")" "respawn-pane -k -t %7" "respawn-pane targets the launched pane"
assert_contains "$(cat "$log")" "RELAY_HANDOFF_PATH=$rd/gen-1/handoff.md" "next-gen handoff env passed"
assert_contains "$(cat "$log")" "RELAY_RUN_DIR=$rd" "run dir env re-exported"
assert_contains "$(cat "$log")" "claude --plugin-dir /x" "launch cmd reused on respawn"
assert_contains "$(cat "$log")" "send-keys -t %7 Continue from the handoff above." "auto-continue nudge sent to the launched pane"
assert_file_exists "$rd/gen-1/pane.log" "pane output persisted to gen dir"

# ---------- 2. --no-auto-continue -> no nudge ----------
rd2="$(mktemp -d)"; mkdir -p "$rd2/gen-1"
relay_state_init "$rd2" 60 "" "" "" $$
seed_live "$rd2" false
relay_state_set "$rd2" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70 | .handoff_settled=true'
: > "$rd2/gen-1/handoff.ready"
log2="$rd2/tmux.log"; : > "$log2"
FAKE_TMUX_LOG="$log2" RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd2" --once
assert_contains "$(cat "$log2")" "respawn-pane -k -t %7" "respawn targets the launched pane"
assert_contains "$(cat "$log2")" "send-keys -t %7 /exit Enter" "graceful /exit sent to pane"
assert_eq "$(grep -c 'Continue from the handoff' "$log2")" "0" "no nudge when auto-continue off"

# ---------- 2c. legacy run with no .tmux_pane -> teardown/respawn fall back to session ----------
rdlg="$(mktemp -d)"; mkdir -p "$rdlg/gen-1"
relay_state_init "$rdlg" 60 "" "" "" $$
# seed_live sets .tmux_pane="%7"; delete it to model a run predating pane capture
relay_state_set "$rdlg" '.tmux_session="relay-test" | .launch_cmd="claude --plugin-dir /x" | .auto_continue=true | .pane_seen=true'
relay_state_set "$rdlg" '.tmux_pane=null | .rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70 | .handoff_settled=true'
: > "$rdlg/gen-1/handoff.ready"
loglg="$rdlg/tmux.log"; : > "$loglg"
FAKE_TMUX_LOG="$loglg" RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rdlg" --once
assert_contains "$(cat "$loglg")" "respawn-pane -k -t relay-test" "no pane -> respawn falls back to session"
assert_contains "$(cat "$loglg")" "send-keys -t relay-test /exit Enter" "no pane -> /exit falls back to session"

# ---------- 2b. /exit hangs -> poll times out, force-kill via respawn still fires ----------
rdt="$(mktemp -d)"; mkdir -p "$rdt/gen-1"
relay_state_init "$rdt" 60 "" "" "" $$
seed_live "$rdt" true
relay_state_set "$rdt" '.tmux_pane="%7" | .rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70 | .handoff_settled=true'
: > "$rdt/gen-1/handoff.ready"
logt="$rdt/tmux.log"; : > "$logt"
# FAKE_PANE_DEAD=0 -> pane never reports dead -> poll exhausts RELAY_EXIT_TIMEOUT
FAKE_TMUX_LOG="$logt" FAKE_PANE_DEAD=0 RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 RELAY_ROTATE_GRACE=0 RELAY_EXIT_TIMEOUT=1 \
  bash bin/relay-supervisor.sh --run-dir "$rdt" --once
assert_contains "$(cat "$rdt/supervisor.log")" "TEARDOWN_EXIT_TIMEOUT" "hung /exit logs timeout"
assert_contains "$(cat "$logt")" "respawn-pane -k -t %7" "force-kill respawn still fires after timeout"
assert_eq "$(relay_state_get "$rdt" '.generation')" "2" "rotation completes despite hung /exit"

# ---------- 3. cap hit at rotation edge -> STOPPED, session killed, no bump ----------
rd3="$(mktemp -d)"; mkdir -p "$rd3/gen-1"
relay_state_init "$rd3" 60 1 "" "" $$        # max_gen=1: next gen 2 exceeds cap
seed_live "$rd3" true
relay_state_set "$rd3" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70 | .handoff_settled=true'
: > "$rd3/gen-1/handoff.ready"
log3="$rd3/tmux.log"; : > "$log3"
FAKE_TMUX_LOG="$log3" RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd3" --once
assert_eq "$(relay_state_get "$rd3" '.generation')" "1" "gen NOT bumped when cap hit"
assert_eq "$(relay_state_get "$rd3" '.status')" "stopped" "run marked stopped on cap"
assert_eq "$(relay_state_get "$rd3" '.stopped_at // 0 | . > 0')" "true" "stopped_at recorded on cap stop"
assert_contains "$(cat "$rd3/supervisor.log")" "STOPPED reason=cap:gen" "cap STOP logged"
assert_contains "$(cat "$log3")" "kill-pane -t %7" "pane killed on cap stop"
assert_eq "$(grep -c 'kill-session' "$log3")" "0" "never kill-session"
assert_eq "$(grep -c 'respawn-pane' "$log3")" "0" "no respawn when cap hit"

# ---------- 3b. cost cap at rotation edge -> STOPPED (reads statusline cost) ----------
rd3b="$(mktemp -d)"; mkdir -p "$rd3b/gen-1"
relay_state_init "$rd3b" 60 "" "" 1.0 $$        # max_cost=1.0
seed_live "$rd3b" true
printf '{"context_window":{"used_percentage":70},"cost":{"total_cost_usd":2.50}}' > "$rd3b/statusline.json"
relay_state_set "$rd3b" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70 | .handoff_settled=true'
: > "$rd3b/gen-1/handoff.ready"
log3b="$rd3b/tmux.log"; : > "$log3b"
FAKE_TMUX_LOG="$log3b" RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd3b" --once
assert_eq "$(relay_state_get "$rd3b" '.generation')" "1" "gen NOT bumped when cost cap hit"
assert_contains "$(cat "$rd3b/supervisor.log")" "STOPPED reason=cap:cost" "cost cap STOP logged"

# ---------- 4. liveness: pane gone + seen before -> STOPPED ----------
rd4="$(mktemp -d)"
relay_state_init "$rd4" 60 "" "" "" $$
seed_live "$rd4" true    # sets pane_seen=true
log4="$rd4/tmux.log"; : > "$log4"
FAKE_TMUX_LOG="$log4" FAKE_PANE_MISSING=1 RELAY_TMUX="$FAKE" RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd4" --once
assert_eq "$(relay_state_get "$rd4" '.status')" "stopped" "pane-gone detected -> stopped"
assert_contains "$(cat "$rd4/supervisor.log")" "STOPPED reason=pane_gone" "pane-gone STOP logged"

# ---------- 5. liveness: pane never came up -> do NOT stop ----------
rd5="$(mktemp -d)"
relay_state_init "$rd5" 60 "" "" "" $$
relay_state_set "$rd5" '.tmux_session="relay-test" | .tmux_pane="%7"'   # configured but pane_seen not set
log5="$rd5/tmux.log"; : > "$log5"
FAKE_TMUX_LOG="$log5" FAKE_PANE_MISSING=1 RELAY_TMUX="$FAKE" \
  bash bin/relay-supervisor.sh --run-dir "$rd5" --once
assert_eq "$(relay_state_get "$rd5" '.status // "none"')" "none" "no stop before pane first seen"

# ---------- 6. liveness latches pane_seen when alive ----------
rd6="$(mktemp -d)"
relay_state_init "$rd6" 60 "" "" "" $$
relay_state_set "$rd6" '.tmux_session="relay-test" | .tmux_pane="%7"'
log6="$rd6/tmux.log"; : > "$log6"
FAKE_TMUX_LOG="$log6" FAKE_PANE_MISSING=0 RELAY_TMUX="$FAKE" \
  bash bin/relay-supervisor.sh --run-dir "$rd6" --once
assert_eq "$(relay_state_get "$rd6" '.pane_seen')" "true" "pane_seen latched when alive"

# ---------- 7. dead-but-present pane (our own teardown) is NOT a stop ----------
rd7="$(mktemp -d)"
relay_state_init "$rd7" 60 "" "" "" $$
seed_live "$rd7" true
log7="$rd7/tmux.log"; : > "$log7"
FAKE_TMUX_LOG="$log7" FAKE_PANE_MISSING=0 FAKE_PANE_DEAD=1 RELAY_TMUX="$FAKE" \
  bash bin/relay-supervisor.sh --run-dir "$rd7" --once
assert_eq "$(relay_state_get "$rd7" '.status // "none"')" "none" "dead-but-present pane does NOT trigger stop"

# ---------- 8. stop-run marker -> supervisor runs graceful stop (kill-pane) ----------
rds="$(mktemp -d)"; mkdir -p "$rds/gen-1"
relay_state_init "$rds" 60 "" "" "" $$
seed_live "$rds" true
printf '{"reason":"user_stop"}' > "$rds/stop-run.json"
logs="$rds/tmux.log"; : > "$logs"
FAKE_TMUX_LOG="$logs" RELAY_TMUX="$FAKE" RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rds" --once
assert_eq "$(relay_state_get "$rds" '.status')" "stopped" "marker -> run stopped"
assert_contains "$(cat "$rds/supervisor.log")" "STOPPED reason=user_stop" "user_stop logged"
assert_contains "$(cat "$logs")" "send-keys -t %7 /exit Enter" "graceful /exit on stop"
assert_contains "$(cat "$logs")" "kill-pane -t %7" "stop reaps relay's pane"
assert_eq "$(grep -c 'kill-session' "$logs")" "0" "stop never kill-session"
assert_file_absent "$rds/stop-run.json" "marker consumed"
assert_file_exists "$rds/state.json" "run dir persists after stop (not deleted)"

# ---------- 8b. iterate short-circuits after a stop (no double-stop in one tick) ----------
# stop marker present AND pane missing: without the STOP_NOW short-circuit in
# iterate, monitor_lifecycle would re-enter stop_run as pane_gone after the
# user_stop, logging a second STOPPED line. Assert exactly one STOP.
rdss="$(mktemp -d)"; mkdir -p "$rdss/gen-1"
relay_state_init "$rdss" 60 "" "" "" $$
seed_live "$rdss" true
printf '{"reason":"user_stop"}' > "$rdss/stop-run.json"
logss="$rdss/tmux.log"; : > "$logss"
FAKE_TMUX_LOG="$logss" FAKE_PANE_MISSING=1 RELAY_TMUX="$FAKE" RELAY_ROTATE_GRACE=0 \
  bash bin/relay-supervisor.sh --run-dir "$rdss" --once
assert_contains "$(cat "$rdss/supervisor.log")" "STOPPED reason=user_stop" "user_stop logged"
assert_eq "$(grep -c 'STOPPED reason=' "$rdss/supervisor.log")" "1" "exactly one STOP (no pane_gone double-fire)"

finish
