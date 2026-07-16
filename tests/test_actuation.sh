#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/state.sh

FAKE="$PWD/tests/fake-tmux.sh"; chmod +x "$FAKE"

# helper: set launch metadata the supervisor needs to actuate a rotation
seed_live() {  # <rd> <auto_continue>
  relay_state_set "$1" ".tmux_session=\"relay-test\" | .launch_cmd=\"claude --plugin-dir /x\" | .auto_continue=$2 | .session_seen=true"
}

# ---------- 1. rotation actuates: respawn-pane + send-keys nudge ----------
rd="$(mktemp -d)"; mkdir -p "$rd/gen-1"
relay_state_init "$rd" 60 "" "" "" $$
seed_live "$rd" true
relay_state_set "$rd" '.tmux_pane="%7"'   # rotation must target this pane, not the session
relay_state_set "$rd" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70'
: > "$rd/gen-1/handoff.ready"
log="$rd/tmux.log"; : > "$log"
FAKE_TMUX_LOG="$log" RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd" --once
assert_eq "$(relay_state_get "$rd" '.generation')" "2" "gen bumped after actuated rotation"
assert_eq "$(relay_state_get "$rd" '.rotation_pending')" "false" "pending cleared"
assert_contains "$(cat "$log")" "respawn-pane -k -t %7" "respawn-pane targets the launched pane"
assert_contains "$(cat "$log")" "RELAY_HANDOFF_PATH=$rd/gen-1/handoff.md" "next-gen handoff env passed"
assert_contains "$(cat "$log")" "RELAY_RUN_DIR=$rd" "run dir env re-exported"
assert_contains "$(cat "$log")" "claude --plugin-dir /x" "launch cmd reused on respawn"
assert_contains "$(cat "$log")" "send-keys -t %7" "auto-continue nudge sent to the launched pane"

# ---------- 2. --no-auto-continue -> no nudge ----------
rd2="$(mktemp -d)"; mkdir -p "$rd2/gen-1"
relay_state_init "$rd2" 60 "" "" "" $$
seed_live "$rd2" false
relay_state_set "$rd2" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70'
: > "$rd2/gen-1/handoff.ready"
log2="$rd2/tmux.log"; : > "$log2"
FAKE_TMUX_LOG="$log2" RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd2" --once
# no .tmux_pane seeded -> falls back to the session target (legacy runs)
assert_contains "$(cat "$log2")" "respawn-pane -k -t relay-test" "respawn falls back to session when no pane stored"
assert_eq "$(grep -c 'send-keys' "$log2")" "0" "no nudge when auto-continue off"

# ---------- 3. cap hit at rotation edge -> STOPPED, session killed, no bump ----------
rd3="$(mktemp -d)"; mkdir -p "$rd3/gen-1"
relay_state_init "$rd3" 60 1 "" "" $$        # max_gen=1: next gen 2 exceeds cap
seed_live "$rd3" true
relay_state_set "$rd3" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70'
: > "$rd3/gen-1/handoff.ready"
log3="$rd3/tmux.log"; : > "$log3"
FAKE_TMUX_LOG="$log3" RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd3" --once
assert_eq "$(relay_state_get "$rd3" '.generation')" "1" "gen NOT bumped when cap hit"
assert_eq "$(relay_state_get "$rd3" '.status')" "stopped" "run marked stopped on cap"
assert_contains "$(cat "$rd3/supervisor.log")" "STOPPED reason=cap:gen" "cap STOP logged"
assert_contains "$(cat "$log3")" "kill-session -t relay-test" "session killed on cap stop"
assert_eq "$(grep -c 'respawn-pane' "$log3")" "0" "no respawn when cap hit"

# ---------- 3b. cost cap at rotation edge -> STOPPED (reads statusline cost) ----------
rd3b="$(mktemp -d)"; mkdir -p "$rd3b/gen-1"
relay_state_init "$rd3b" 60 "" "" 1.0 $$        # max_cost=1.0
seed_live "$rd3b" true
printf '{"context_window":{"used_percentage":70},"cost":{"total_cost_usd":2.50}}' > "$rd3b/statusline.json"
relay_state_set "$rd3b" '.rotation_pending=true | .pending_marker="gen-1/handoff.ready" | .pending_since=0 | .pending_pct=70'
: > "$rd3b/gen-1/handoff.ready"
log3b="$rd3b/tmux.log"; : > "$log3b"
FAKE_TMUX_LOG="$log3b" RELAY_TMUX="$FAKE" RELAY_NUDGE_DELAY=0 \
  bash bin/relay-supervisor.sh --run-dir "$rd3b" --once
assert_eq "$(relay_state_get "$rd3b" '.generation')" "1" "gen NOT bumped when cost cap hit"
assert_contains "$(cat "$rd3b/supervisor.log")" "STOPPED reason=cap:cost" "cost cap STOP logged"

# ---------- 4. liveness: session gone + seen before + not pending -> STOPPED ----------
rd4="$(mktemp -d)"
relay_state_init "$rd4" 60 "" "" "" $$
seed_live "$rd4" true    # sets session_seen=true
log4="$rd4/tmux.log"; : > "$log4"
FAKE_TMUX_LOG="$log4" FAKE_HAS_SESSION=0 RELAY_TMUX="$FAKE" \
  bash bin/relay-supervisor.sh --run-dir "$rd4" --once
assert_eq "$(relay_state_get "$rd4" '.status')" "stopped" "user-exit detected -> stopped"
assert_contains "$(cat "$rd4/supervisor.log")" "STOPPED reason=session_gone" "session-gone STOP logged"

# ---------- 5. liveness: session never came up -> do NOT stop ----------
rd5="$(mktemp -d)"
relay_state_init "$rd5" 60 "" "" "" $$
relay_state_set "$rd5" '.tmux_session="relay-test"'   # configured but session_seen not set
log5="$rd5/tmux.log"; : > "$log5"
FAKE_TMUX_LOG="$log5" FAKE_HAS_SESSION=0 RELAY_TMUX="$FAKE" \
  bash bin/relay-supervisor.sh --run-dir "$rd5" --once
assert_eq "$(relay_state_get "$rd5" '.status // "none"')" "none" "no stop before session first seen"

# ---------- 6. liveness latches session_seen when alive ----------
rd6="$(mktemp -d)"
relay_state_init "$rd6" 60 "" "" "" $$
relay_state_set "$rd6" '.tmux_session="relay-test"'
log6="$rd6/tmux.log"; : > "$log6"
FAKE_TMUX_LOG="$log6" FAKE_HAS_SESSION=1 RELAY_TMUX="$FAKE" \
  bash bin/relay-supervisor.sh --run-dir "$rd6" --once
assert_eq "$(relay_state_get "$rd6" '.session_seen')" "true" "session_seen latched when alive"

finish
