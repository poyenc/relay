#!/usr/bin/env bash
# state.json helpers. All writes are atomic (unique temp + mv) and serialized
# per run dir with flock, so the launcher and the supervisor daemon can update
# state.json concurrently without clobbering each other or racing on a shared
# temp file.
_relay_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Run a jq program that transforms state.json in place, holding an exclusive
# lock on <rd>/.state.lock for the whole read-modify-write so concurrent callers
# serialize. Writes through a unique temp (mktemp) then atomically renames.
# Usage: _relay_state_apply <rd> <jq-prog> [jq-args...]
_relay_state_apply() {
  local rd="$1"; shift
  local prog="$1"; shift
  (
    flock 9 || exit 1
    local tmp; tmp="$(mktemp "$rd/state.json.XXXXXX")"
    if jq "$@" "$prog" "$rd/state.json" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$rd/state.json"
    else
      rm -f "$tmp"
      return 1
    fi
  ) 9>"$rd/.state.lock"
}

relay_state_init() {
  local rd="$1" rotate="$2" maxgen="$3" maxrt="$4" maxcost="$5" pid="$6"
  local tmp
  (
    flock 9 || exit 1
    tmp="$(mktemp "$rd/state.json.XXXXXX")"
    jq -n \
      --argjson rotate "$rotate" \
      --argjson maxgen "${maxgen:-null}" \
      --argjson maxrt "${maxrt:-null}" \
      --argjson maxcost "${maxcost:-null}" \
      --argjson pid "$pid" \
      --arg run_id "$(basename "$rd")" \
      --arg ts "$(_relay_now)" \
      '{run_id: $run_id, generation: 1, supervisor_pid: $pid,
        policy: {rotate_at_pct: $rotate, max_gen: $maxgen,
                 max_runtime_s: $maxrt, max_cost_usd: $maxcost},
        rotation_pending: false, pending_marker: null,
        rotations: [], started_at: $ts}' \
      > "$tmp" && mv "$tmp" "$rd/state.json" || { rm -f "$tmp"; exit 1; }
  ) 9>"$rd/.state.lock"
}

relay_state_get() { jq -r "$2" "$1/state.json"; }

relay_state_set() {
  local rd="$1" assign="$2"
  _relay_state_apply "$rd" "$assign"
}

relay_state_add_rotation() {
  local rd="$1" gen="$2" pct="$3"
  _relay_state_apply "$rd" \
    '.rotations += [{gen: $gen, at_pct: $pct, ts: $ts}]' \
    --argjson gen "$gen" --argjson pct "$pct" --arg ts "$(_relay_now)"
}
