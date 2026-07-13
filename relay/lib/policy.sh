#!/usr/bin/env bash
# Policy decisions. Threshold at each turn; caps at rotation edge.
relay_should_rotate() {
  local rd="$1" pct="$2" sha="$3"
  [ -n "$pct" ] || { echo continue; return; }
  [ "$sha" = "true" ] && { echo continue; return; }
  [ "$(relay_state_get "$rd" '.rotation_pending')" = "true" ] && { echo continue; return; }
  local thr; thr="$(relay_state_get "$rd" '.policy.rotate_at_pct')"
  if [ "$pct" -ge "$thr" ]; then echo rotate; else echo continue; fi
}

relay_cap_hit() {
  local rd="$1" runtime="$2" cost="$3"
  local maxgen maxrt maxcost gen next
  maxgen="$(relay_state_get "$rd" '.policy.max_gen')"
  maxrt="$(relay_state_get "$rd" '.policy.max_runtime_s')"
  maxcost="$(relay_state_get "$rd" '.policy.max_cost_usd')"
  gen="$(relay_state_get "$rd" '.generation')"; next=$(( gen + 1 ))
  if [ "$maxgen" != "null" ] && [ "$next" -gt "$maxgen" ]; then echo gen; return; fi
  if [ "$maxrt" != "null" ] && [ "$runtime" -ge "$maxrt" ]; then echo runtime; return; fi
  if [ "$maxcost" != "null" ] && awk "BEGIN{exit !($cost >= $maxcost)}"; then echo cost; return; fi
  echo none
}
