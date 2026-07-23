#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib/rundir.sh"
source "$HERE/lib/state.sh"
source "$HERE/lib/telemetry.sh"
source "$HERE/lib/policy.sh"
source "$HERE/lib/handoff_instruction.sh"

: "${RELAY_ROTATION_TIMEOUT:=120}"
: "${RELAY_TMUX:=tmux}"
: "${RELAY_NUDGE_DELAY:=2}"
# Graceful-teardown knobs (threaded in by bin/relay). GRACE: seconds to let the
# outgoing generation's final message finish rendering before /exit. EXIT_TIMEOUT:
# seconds to wait for a clean /exit (poll #{pane_dead}) before force-killing.
: "${RELAY_ROTATE_GRACE:=2}"
: "${RELAY_EXIT_TIMEOUT:=5}"
RUN_DIR=""; ONCE=0
while [ $# -gt 0 ]; do case "$1" in
  --run-dir) RUN_DIR="$2"; shift 2;;
  --once) ONCE=1; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done
[ -n "$RUN_DIR" ] || { echo "--run-dir required" >&2; exit 2; }

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$RUN_DIR/supervisor.log"; }

handle_stop_request() {
  [ -f "$RUN_DIR/stop-request.json" ] || return 0
  local payload tp sha pct decision gen marker cap
  payload="$(cat "$RUN_DIR/stop-request.json")"
  if ! printf '%s' "$payload" | jq empty 2>/dev/null; then
    log "STOP_REQUEST_INVALID reason=malformed_json"
    rm -f "$RUN_DIR/stop-request.json"
    return 0
  fi
  tp="$(printf '%s' "$payload" | jq -r '.transcript_path // ""')"
  sha="$(printf '%s' "$payload" | jq -r '.stop_hook_active // false')"

  # Re-arm: if a rotation is already pending but the handoff marker hasn't appeared,
  # a fresh idle Stop means the earlier block was missed (hook timed out). Re-deliver
  # the instruction now instead of returning {} and waiting out rotation_timeout -
  # closes the dead-air window. Loop-safety: never re-block when stop_hook_active.
  if [ "$(relay_state_get "$RUN_DIR" '.rotation_pending')" = "true" ]; then
    marker="$(relay_state_get "$RUN_DIR" '.pending_marker')"
    if [ "$sha" != "true" ] && [ ! -f "$RUN_DIR/$marker" ]; then
      gen="${marker#gen-}"; gen="${gen%/*}"
      relay_handoff_instruction "$RUN_DIR/gen-$gen/handoff.md" "$RUN_DIR/$marker" \
        | jq -Rsc '{decision:"block", reason: .}' > "$RUN_DIR/stop-response.json.tmp"
      mv "$RUN_DIR/stop-response.json.tmp" "$RUN_DIR/stop-response.json"
      log "ROTATE_REARM gen=$gen"
    else
      # Marker present means the handoff is written and this is the FIRST idle Stop
      # after it - the "post-handoff stop". Record that the outgoing generation has
      # settled so handle_pending_rotation tears down now (final message rendered),
      # not the instant the marker file appeared mid-turn.
      [ -f "$RUN_DIR/$marker" ] && relay_state_set "$RUN_DIR" '.handoff_settled=true'
      printf '{}' > "$RUN_DIR/stop-response.json.tmp"
      mv "$RUN_DIR/stop-response.json.tmp" "$RUN_DIR/stop-response.json"
    fi
    rm -f "$RUN_DIR/stop-request.json"
    return 0
  fi

  pct="$(relay_context_pct "$RUN_DIR" "$tp")"
  decision="$(relay_should_rotate "$RUN_DIR" "$pct" "$sha")"
  if [ "$decision" = "rotate" ]; then
    # Final generation: if rotating would breach a cap there is no next generation
    # to consume a handoff, so skip the handoff request entirely and stop the run.
    cap="$(relay_cap_hit "$RUN_DIR" "$(_run_elapsed_s)" "$(relay_cost_from_statusline "$RUN_DIR")")"
    if [ "$cap" != "none" ]; then
      printf '{}' > "$RUN_DIR/stop-response.json.tmp"
      mv "$RUN_DIR/stop-response.json.tmp" "$RUN_DIR/stop-response.json"
      rm -f "$RUN_DIR/stop-request.json"
      stop_run "cap:$cap"
      return 0
    fi
    gen="$(relay_state_get "$RUN_DIR" '.generation')"
    marker="gen-$gen/handoff.ready"
    mkdir -p "$RUN_DIR/gen-$gen"
    relay_state_set "$RUN_DIR" \
      ".rotation_pending=true | .pending_marker=\"$marker\" | .pending_since=$(date +%s) | .pending_pct=${pct:-0} | .handoff_settled=false"
    relay_handoff_instruction "$RUN_DIR/gen-$gen/handoff.md" "$RUN_DIR/$marker" \
      | jq -Rsc '{decision:"block", reason: .}' > "$RUN_DIR/stop-response.json.tmp"
    mv "$RUN_DIR/stop-response.json.tmp" "$RUN_DIR/stop-response.json"
    log "ROTATE_REQUESTED gen=$gen pct=${pct:-NA}"
  else
    printf '{}' > "$RUN_DIR/stop-response.json.tmp"
    mv "$RUN_DIR/stop-response.json.tmp" "$RUN_DIR/stop-response.json"
  fi
  rm -f "$RUN_DIR/stop-request.json"
}

# Elapsed wall-clock seconds since the run started (for runtime caps).
_run_elapsed_s() {
  local started epoch now
  started="$(relay_state_get "$RUN_DIR" '.started_at // ""')"
  [ -n "$started" ] || { echo 0; return; }
  epoch="$(date -d "$started" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"; echo $(( now - epoch ))
}

# Ask the live claude in the hosted pane to /exit so it runs its own shutdown
# path (SessionEnd hook, transcript flush, no orphaned Bash-tool children) before
# the caller force-kills. Pane-scoped: targets relay's launched pane, never the
# session, so a user split/window is untouched. Sequence: grace pause (final
# message stays readable) -> capture pane to a log -> remain-on-exit=on (dead pane
# lingers so we can detect the exit) -> /exit -> poll #{pane_dead} up to
# RELAY_EXIT_TIMEOUT. Leaves the dead-or-dying pane for the caller to respawn
# (rotation) or kill-pane (stop). No-op if the pane is already gone. Logs which path ran.
graceful_teardown() {  # <gen> <tag>
  local gen="$1" tag="$2" sess pane target i
  sess="$(relay_state_get "$RUN_DIR" '.tmux_session // ""')"
  [ -n "$sess" ] || return 0
  pane="$(relay_state_get "$RUN_DIR" '.tmux_pane // ""')"
  target="${pane:-$sess}"
  [ "$RELAY_ROTATE_GRACE" = "0" ] || sleep "$RELAY_ROTATE_GRACE"
  mkdir -p "$RUN_DIR/gen-$gen"
  "$RELAY_TMUX" capture-pane -p -t "$target" > "$RUN_DIR/gen-$gen/pane.log" 2>/dev/null \
    || log "TEARDOWN_WARN capture_failed target=$target tag=$tag"
  "$RELAY_TMUX" set-option -p -t "$target" remain-on-exit on 2>/dev/null || true
  "$RELAY_TMUX" send-keys -t "$target" "/exit" Enter 2>/dev/null || true
  for i in $(seq 1 "$RELAY_EXIT_TIMEOUT"); do
    if [ "$("$RELAY_TMUX" list-panes -t "$target" -F '#{pane_dead}' 2>/dev/null | head -n1)" = "1" ]; then
      log "TEARDOWN_EXIT_CLEAN gen=$gen tag=$tag"; return 0
    fi
    sleep 1
  done
  log "TEARDOWN_EXIT_TIMEOUT gen=$gen tag=$tag force=1"
}

# Stop the run: graceful /exit teardown, then kill-pane (pane-scoped, never the
# session). Persist status/stopped_at so the dir survives for post-mortem; the
# loop exits after this. relay_prune_dead reaps the dir after 7 days.
stop_run() {  # <reason>
  local pane sess target gen
  sess="$(relay_state_get "$RUN_DIR" '.tmux_session // ""')"
  pane="$(relay_state_get "$RUN_DIR" '.tmux_pane // ""')"
  target="${pane:-$sess}"
  gen="$(relay_state_get "$RUN_DIR" '.generation')"
  graceful_teardown "$gen" "stop"
  relay_state_set "$RUN_DIR" ".status=\"stopped\" | .stopped_at=$(date +%s)"
  log "STOPPED reason=$1"
  # kill-pane reaps the (now dead) pane; if it was the last pane the session
  # self-collapses. Never kill-session - a user's other panes/windows survive.
  [ -n "$target" ] && "$RELAY_TMUX" kill-pane -t "$target" 2>/dev/null || true
  STOP_NOW=1
}

# Replace the live claude process in place with a fresh generation (user stays
# attached). respawn-pane -k re-runs the launch cmd with next-gen env; kill-server
# is never used (shared per-user server). No-op when no tmux session is configured
# (Plan-1 state-transition mode).
actuate_rotation() {  # <from_gen> <handoff_md>
  local from_gen="$1" handoff="$2" sess pane target cmd auto
  sess="$(relay_state_get "$RUN_DIR" '.tmux_session // ""')"
  [ -n "$sess" ] || return 0
  # Target the exact pane relay launched into, not the session's active pane -
  # otherwise a user-created split/window steals the respawn. Fall back to the
  # session for runs predating pane capture.
  pane="$(relay_state_get "$RUN_DIR" '.tmux_pane // ""')"
  target="${pane:-$sess}"
  cmd="$(relay_state_get "$RUN_DIR" '.launch_cmd // ""')"
  # NOTE: jq's `//` treats false as empty, so a plain `.auto_continue // true`
  # would turn an explicit false into true. Null-check explicitly.
  auto="$(relay_state_get "$RUN_DIR" 'if .auto_continue == null then true else .auto_continue end')"
  graceful_teardown "$from_gen" "rotate"
  # respawn-pane -k relaunches the next gen; -k force-kills if /exit hung.
  "$RELAY_TMUX" respawn-pane -k -t "$target" \
    -e "RELAY_RUN_DIR=$RUN_DIR" \
    -e "RELAY_STATE=$RUN_DIR/statusline.json" \
    -e "RELAY_HANDOFF_PATH=$handoff" \
    "$cmd" 2>/dev/null || log "ACTUATE_WARN respawn_failed target=$target"
  # Restore default so a future manual exit collapses the pane as usual.
  "$RELAY_TMUX" set-option -p -t "$target" remain-on-exit off 2>/dev/null || true
  if [ "$auto" = "true" ]; then
    # Give the fresh claude a moment to boot before typing into it. Synchronous
    # (not backgrounded) so it is deterministic; a brief pause at a rare rotation
    # edge is harmless. RELAY_NUDGE_DELAY=0 in tests.
    [ "$RELAY_NUDGE_DELAY" = "0" ] || sleep "$RELAY_NUDGE_DELAY"
    "$RELAY_TMUX" send-keys -t "$target" "Continue from the handoff above." Enter 2>/dev/null || true
  fi
}

handle_pending_rotation() {
  [ "$(relay_state_get "$RUN_DIR" '.rotation_pending')" = "true" ] || return 0
  local marker gen since now age pct cap settled
  marker="$(relay_state_get "$RUN_DIR" '.pending_marker')"
  # Wait for BOTH the handoff marker AND the outgoing generation to settle (the
  # post-handoff Stop). The marker says "handoff written" (created mid-turn); the
  # settled flag says "turn complete, final message rendered". Acting on the marker
  # alone would kill the pane before its final message finished printing.
  settled="$(relay_state_get "$RUN_DIR" '.handoff_settled // false')"
  if [ -f "$RUN_DIR/$marker" ] && [ "$settled" = "true" ]; then
    gen="$(relay_state_get "$RUN_DIR" '.generation')"
    pct="$(relay_state_get "$RUN_DIR" '.pending_pct')"
    # Caps are evaluated at the rotation edge: if the NEXT generation would breach
    # a cap, stop instead of relaunching.
    cap="$(relay_cap_hit "$RUN_DIR" "$(_run_elapsed_s)" "$(relay_cost_from_statusline "$RUN_DIR")")"
    if [ "$cap" != "none" ]; then
      rm -f "$RUN_DIR/$marker"
      stop_run "cap:$cap"
      return 0
    fi
    relay_state_add_rotation "$RUN_DIR" "$gen" "${pct:-0}"
    # next gen: point SessionStart at THIS gen's handoff
    relay_state_set "$RUN_DIR" \
      ".generation=$((gen+1)) | .rotation_pending=false | .pending_marker=null | .next_handoff=\"$RUN_DIR/gen-$gen/handoff.md\""
    mkdir -p "$RUN_DIR/gen-$((gen+1))"
    rm -f "$RUN_DIR/$marker"
    log "ROTATED from_gen=$gen to_gen=$((gen+1)) handoff=$RUN_DIR/gen-$gen/handoff.md"
    actuate_rotation "$gen" "$RUN_DIR/gen-$gen/handoff.md"
  else
    since="$(relay_state_get "$RUN_DIR" '.pending_since // 0')"
    now="$(date +%s)"; age=$(( now - since ))
    if [ "$age" -ge "$RELAY_ROTATION_TIMEOUT" ]; then
      if [ -f "$RUN_DIR/$marker" ]; then
        # Handoff exists but the post-handoff Stop never arrived (flaky hook). Do
        # NOT waste a valid handoff - rotate directly, same as the normal gate.
        gen="$(relay_state_get "$RUN_DIR" '.generation')"
        pct="$(relay_state_get "$RUN_DIR" '.pending_pct')"
        cap="$(relay_cap_hit "$RUN_DIR" "$(_run_elapsed_s)" "$(relay_cost_from_statusline "$RUN_DIR")")"
        if [ "$cap" != "none" ]; then
          rm -f "$RUN_DIR/$marker"
          stop_run "cap:$cap"
          return 0
        fi
        relay_state_add_rotation "$RUN_DIR" "$gen" "${pct:-0}"
        relay_state_set "$RUN_DIR" \
          ".generation=$((gen+1)) | .rotation_pending=false | .pending_marker=null | .next_handoff=\"$RUN_DIR/gen-$gen/handoff.md\""
        mkdir -p "$RUN_DIR/gen-$((gen+1))"
        rm -f "$RUN_DIR/$marker"
        log "ROTATE_STOP_TIMEOUT from_gen=$gen to_gen=$((gen+1)) age=${age}s force=1"
        actuate_rotation "$gen" "$RUN_DIR/gen-$gen/handoff.md"
      else
        # No handoff was ever produced - give up this attempt. Non-terminal: the
        # run keeps living and can rotate again on a later Stop.
        relay_state_set "$RUN_DIR" '.rotation_pending=false | .pending_marker=null'
        log "ROTATE_FAILED reason=rotation_timeout age=${age}s"
      fi
    fi
  fi
}

# Lifecycle monitor: once relay's pane has been seen alive, its DISAPPEARANCE
# (pane no longer exists) means the user closed it - stop the run. A dead-but-
# present pane (#{pane_dead}=1, left by our own graceful /exit mid-teardown) is
# NOT "user quit" and is ignored here. Pane-scoped so a user's other panes are
# irrelevant to relay's liveness.
monitor_lifecycle() {
  local sess pane target seen
  sess="$(relay_state_get "$RUN_DIR" '.tmux_session // ""')"
  [ -n "$sess" ] || return 0
  pane="$(relay_state_get "$RUN_DIR" '.tmux_pane // ""')"
  target="${pane:-$sess}"
  # Pane present at all? (bare list-panes lists present panes, dead or alive.)
  if [ -n "$("$RELAY_TMUX" list-panes -t "$target" -F '#{pane_id}' 2>/dev/null)" ]; then
    seen="$(relay_state_get "$RUN_DIR" '.pane_seen // false')"
    [ "$seen" = "true" ] || relay_state_set "$RUN_DIR" '.pane_seen=true'
    return 0
  fi
  # pane absent
  if [ "$(relay_state_get "$RUN_DIR" '.pane_seen // false')" = "true" ]; then
    stop_run "pane_gone"
  fi
}

# relay --stop drops a stop-run marker; act on it with the one graceful stop path.
handle_stop_marker() {
  [ -f "$RUN_DIR/stop-run.json" ] || return 0
  rm -f "$RUN_DIR/stop-run.json"
  stop_run "user_stop"
}

iterate() {
  handle_stop_marker    || log "ITERATE_ERROR stage=handle_stop_marker rc=$?"
  handle_stop_request   || log "ITERATE_ERROR stage=handle_stop_request rc=$?"
  handle_pending_rotation || log "ITERATE_ERROR stage=handle_pending_rotation rc=$?"
  monitor_lifecycle     || log "ITERATE_ERROR stage=monitor_lifecycle rc=$?"
  return 0
}

STOP_NOW=0
if [ "$ONCE" -eq 1 ]; then iterate; exit 0; fi
trap 'rm -rf "$RUN_DIR"' EXIT
while true; do iterate; [ "$STOP_NOW" -eq 1 ] && break; sleep 0.2; done
