#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
source "$HERE/lib/rundir.sh"
source "$HERE/lib/state.sh"
source "$HERE/lib/telemetry.sh"
source "$HERE/lib/policy.sh"
source "$HERE/lib/handoff_instruction.sh"

: "${RELAY_MARKER_TIMEOUT:=120}"
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

handle_pending_rotation() {
  [ "$(relay_state_get "$RUN_DIR" '.rotation_pending')" = "true" ] || return 0
  local marker gen since now age pct
  marker="$(relay_state_get "$RUN_DIR" '.pending_marker')"
  if [ -f "$RUN_DIR/$marker" ]; then
    gen="$(relay_state_get "$RUN_DIR" '.generation')"
    pct="$(relay_state_get "$RUN_DIR" '.pending_pct')"
    relay_state_add_rotation "$RUN_DIR" "$gen" "${pct:-0}"
    # next gen: point SessionStart at THIS gen's handoff
    relay_state_set "$RUN_DIR" \
      ".generation=$((gen+1)) | .rotation_pending=false | .pending_marker=null | .next_handoff=\"$RUN_DIR/gen-$gen/handoff.md\""
    mkdir -p "$RUN_DIR/gen-$((gen+1))"
    rm -f "$RUN_DIR/$marker"
    log "ROTATED from_gen=$gen to_gen=$((gen+1)) handoff=$RUN_DIR/gen-$gen/handoff.md"
  else
    since="$(relay_state_get "$RUN_DIR" '.pending_since // 0')"
    now="$(date +%s)"; age=$(( now - since ))
    if [ "$age" -ge "$RELAY_MARKER_TIMEOUT" ]; then
      relay_state_set "$RUN_DIR" '.rotation_pending=false | .pending_marker=null'
      log "ROTATE_FAILED reason=marker_timeout age=${age}s"
    fi
  fi
}

iterate() {
  handle_stop_request || log "ITERATE_ERROR stage=handle_stop_request rc=$?"
  handle_pending_rotation || log "ITERATE_ERROR stage=handle_pending_rotation rc=$?"
  return 0
}

if [ "$ONCE" -eq 1 ]; then iterate; exit 0; fi
trap 'rm -rf "$RUN_DIR"' EXIT
while true; do iterate; sleep 0.2; done
