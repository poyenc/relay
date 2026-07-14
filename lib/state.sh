#!/usr/bin/env bash
# state.json helpers. All writes are atomic (tmp + mv).
_relay_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

relay_state_init() {
  local rd="$1" rotate="$2" maxgen="$3" maxrt="$4" maxcost="$5" pid="$6"
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
    > "$rd/state.json.tmp" && mv "$rd/state.json.tmp" "$rd/state.json"
}

relay_state_get() { jq -r "$2" "$1/state.json"; }

relay_state_set() {
  local rd="$1" assign="$2"
  jq "$assign" "$rd/state.json" > "$rd/state.json.tmp" \
    && mv "$rd/state.json.tmp" "$rd/state.json"
}

relay_state_add_rotation() {
  local rd="$1" gen="$2" pct="$3"
  jq --argjson gen "$gen" --argjson pct "$pct" --arg ts "$(_relay_now)" \
    '.rotations += [{gen: $gen, at_pct: $pct, ts: $ts}]' \
    "$rd/state.json" > "$rd/state.json.tmp" && mv "$rd/state.json.tmp" "$rd/state.json"
}
