#!/usr/bin/env bash
# Context-% telemetry: statusline tee (authoritative) then transcript fallback.
: "${RELAY_STALE_S:=90}"
: "${RELAY_CTX_WINDOW:=200000}"

_relay_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

relay_pct_from_statusline() {
  local f="$1/statusline.json"
  [ -f "$f" ] || return 0
  local now age pct
  now="$(date +%s)"; age=$(( now - $(_relay_mtime "$f") ))
  [ "$age" -le "$RELAY_STALE_S" ] || return 0
  pct="$(jq -r '.context_window.used_percentage // empty' "$f" 2>/dev/null)"
  [ -n "$pct" ] || return 0
  printf '%s\n' "${pct%.*}"   # floor to int
}

relay_pct_from_transcript() {
  local tp="$1"
  [ -f "$tp" ] || return 0
  local tokens
  tokens="$(jq -s '
    [ .[] | select(.type=="assistant")
          | select(.isSidechain != true)
          | select(.message.usage != null) ] | last
    | if . == null then empty
      else (.message.usage.input_tokens // 0)
         + (.message.usage.cache_creation_input_tokens // 0)
         + (.message.usage.cache_read_input_tokens // 0)
      end' "$tp" 2>/dev/null)"
  [ -n "$tokens" ] || return 0
  printf '%s\n' "$(( tokens * 100 / RELAY_CTX_WINDOW ))"
}

# Cumulative cost in USD from the statusline tee (.cost.total_cost_usd), for
# --max-cost. Echoes 0 when unavailable. Cost only grows, so staleness is benign.
relay_cost_from_statusline() {
  local f="$1/statusline.json" cost
  [ -f "$f" ] || { echo 0; return 0; }
  cost="$(jq -r '.cost.total_cost_usd // 0' "$f" 2>/dev/null)"
  [ -n "$cost" ] || cost=0
  printf '%s\n' "$cost"
}

relay_context_pct() {
  local rd="$1" tp="$2" pct
  pct="$(relay_pct_from_statusline "$rd")"
  [ -n "$pct" ] && { printf '%s\n' "$pct"; return 0; }
  relay_pct_from_transcript "$tp"
}
