#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib/rundir.sh"
source "$HERE/lib/state.sh"
source "$HERE/lib/telemetry.sh"
source "$HERE/lib/policy.sh"
source "$HERE/lib/handoff_instruction.sh"

: "${RELAY_MARKER_TIMEOUT:=120}"
: "${RELAY_TMUX:=tmux}"
: "${RELAY_NUDGE_DELAY:=2}"
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
  local payload tp sha pct decision gen marker
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
  # the instruction now instead of returning {} and waiting out marker_timeout —
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
      printf '{}' > "$RUN_DIR/stop-response.json.tmp"
      mv "$RUN_DIR/stop-response.json.tmp" "$RUN_DIR/stop-response.json"
    fi
    rm -f "$RUN_DIR/stop-request.json"
    return 0
  fi

  pct="$(relay_context_pct "$RUN_DIR" "$tp")"
  decision="$(relay_should_rotate "$RUN_DIR" "$pct" "$sha")"
  if [ "$decision" = "rotate" ]; then
    gen="$(relay_state_get "$RUN_DIR" '.generation')"
    marker="gen-$gen/handoff.ready"
    mkdir -p "$RUN_DIR/gen-$gen"
    relay_state_set "$RUN_DIR" \
      ".rotation_pending=true | .pending_marker=\"$marker\" | .pending_since=$(date +%s) | .pending_pct=${pct:-0}"
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

# Stop the run: kill the tmux session (session-scoped only) and mark stopped.
# The EXIT trap deletes the run dir; the loop exits after this.
stop_run() {  # <reason>
  local sess
  sess="$(relay_state_get "$RUN_DIR" '.tmux_session // ""')"
  relay_state_set "$RUN_DIR" '.status="stopped"'
  log "STOPPED reason=$1"
  [ -n "$sess" ] && "$RELAY_TMUX" kill-session -t "$sess" 2>/dev/null || true
  STOP_NOW=1
}

# Replace the live claude process in place with a fresh generation (user stays
# attached). respawn-pane -k re-runs the launch cmd with next-gen env; kill-server
# is never used (shared per-user server). No-op when no tmux session is configured
# (Plan-1 state-transition mode).
actuate_rotation() {  # <from_gen> <handoff_md>
  local from_gen="$1" handoff="$2" sess cmd auto
  sess="$(relay_state_get "$RUN_DIR" '.tmux_session // ""')"
  [ -n "$sess" ] || return 0
  cmd="$(relay_state_get "$RUN_DIR" '.launch_cmd // ""')"
  # NOTE: jq's `//` treats false as empty, so a plain `.auto_continue // true`
  # would turn an explicit false into true. Null-check explicitly.
  auto="$(relay_state_get "$RUN_DIR" 'if .auto_continue == null then true else .auto_continue end')"
  "$RELAY_TMUX" respawn-pane -k -t "$sess" \
    -e "RELAY_RUN_DIR=$RUN_DIR" \
    -e "RELAY_STATE=$RUN_DIR/statusline.json" \
    -e "RELAY_HANDOFF_PATH=$handoff" \
    "$cmd" 2>/dev/null || log "ACTUATE_WARN respawn_failed sess=$sess"
  if [ "$auto" = "true" ]; then
    # Give the fresh claude a moment to boot before typing into it. Synchronous
    # (not backgrounded) so it is deterministic; a brief pause at a rare rotation
    # edge is harmless. RELAY_NUDGE_DELAY=0 in tests.
    [ "$RELAY_NUDGE_DELAY" = "0" ] || sleep "$RELAY_NUDGE_DELAY"
    "$RELAY_TMUX" send-keys -t "$sess" "Continue from the handoff above." Enter 2>/dev/null || true
  fi
}

handle_pending_rotation() {
  [ "$(relay_state_get "$RUN_DIR" '.rotation_pending')" = "true" ] || return 0
  local marker gen since now age pct cap
  marker="$(relay_state_get "$RUN_DIR" '.pending_marker')"
  if [ -f "$RUN_DIR/$marker" ]; then
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
    if [ "$age" -ge "$RELAY_MARKER_TIMEOUT" ]; then
      relay_state_set "$RUN_DIR" '.rotation_pending=false | .pending_marker=null'
      log "ROTATE_FAILED reason=marker_timeout age=${age}s"
    fi
  fi
}

# Lifecycle monitor: once the hosted session has been seen alive, its disappearance
# means the user exited (or it crashed) — stop the run. rotation_pending deaths are
# not possible here since respawn-pane keeps the session alive across a rotation.
monitor_lifecycle() {
  local sess seen
  sess="$(relay_state_get "$RUN_DIR" '.tmux_session // ""')"
  [ -n "$sess" ] || return 0
  if "$RELAY_TMUX" has-session -t "$sess" 2>/dev/null; then
    seen="$(relay_state_get "$RUN_DIR" '.session_seen // false')"
    [ "$seen" = "true" ] || relay_state_set "$RUN_DIR" '.session_seen=true'
    return 0
  fi
  # session absent
  if [ "$(relay_state_get "$RUN_DIR" '.session_seen // false')" = "true" ]; then
    stop_run "session_gone"
  fi
}

iterate() {
  handle_stop_request || log "ITERATE_ERROR stage=handle_stop_request rc=$?"
  handle_pending_rotation || log "ITERATE_ERROR stage=handle_pending_rotation rc=$?"
  monitor_lifecycle || log "ITERATE_ERROR stage=monitor_lifecycle rc=$?"
  return 0
}

STOP_NOW=0
if [ "$ONCE" -eq 1 ]; then iterate; exit 0; fi
trap 'rm -rf "$RUN_DIR"' EXIT
while true; do iterate; [ "$STOP_NOW" -eq 1 ] && break; sleep 0.2; done
