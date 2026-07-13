#!/usr/bin/env bash
# relay subcommands: --list / --attach / --stop / --status / --install-statusline.
# Depends on lib/rundir.sh, lib/state.sh (sourced by bin/relay). RELAY_TMUX overridable.
: "${RELAY_TMUX:=tmux}"

# Resolve a (possibly abbreviated) run_id to its run dir among LIVE runs only.
# Echoes the run dir on a unique match; returns nonzero (message on stderr) otherwise.
relay_resolve_run_id() {  # <id-or-prefix>
  local want="$1" line d id matches=() root
  root="$(relay_root)"
  while IFS=$'\t' read -r d _pid _gen; do
    [ -n "$d" ] || continue
    id="$(basename "$d")"
    case "$id" in "$want"*) matches+=("$d") ;; esac
  done < <(relay_list_live)
  case "${#matches[@]}" in
    1) printf '%s\n' "${matches[0]}" ;;
    0) echo "relay: no live run matches '$want'" >&2; return 1 ;;
    *) echo "relay: '$want' is ambiguous (${#matches[@]} matches); use a longer prefix" >&2; return 1 ;;
  esac
}

relay_cmd_list() {
  relay_prune_dead
  local any=0 d pid gen id
  while IFS=$'\t' read -r d pid gen; do
    [ -n "$d" ] || continue
    if [ "$any" -eq 0 ]; then printf '%-26s %-8s %s\n' "RUN_ID" "PID" "GEN"; any=1; fi
    id="$(basename "$d")"
    printf '%-26s %-8s %s\n' "$id" "$pid" "$gen"
  done < <(relay_list_live)
  [ "$any" -eq 1 ] || echo "relay: no live runs."
}

relay_cmd_status() {  # <id-or-prefix>
  local rd; rd="$(relay_resolve_run_id "$1")" || return 1
  jq . "$rd/state.json"
}

relay_cmd_attach() {  # <id-or-prefix>
  local rd sess; rd="$(relay_resolve_run_id "$1")" || return 1
  sess="$(relay_state_get "$rd" '.tmux_session')"
  if [ -n "${TMUX:-}" ]; then
    echo "relay: (nested tmux — switching client to $sess)" >&2
    "$RELAY_TMUX" switch-client -t "$sess"
  else
    "$RELAY_TMUX" attach-session -t "$sess"
  fi
}

relay_cmd_stop() {  # <id-or-prefix>
  local rd sess pid; rd="$(relay_resolve_run_id "$1")" || return 1
  sess="$(relay_state_get "$rd" '.tmux_session')"
  pid="$(relay_state_get "$rd" '.supervisor_pid')"
  # kill the hosted session (session-scoped only; kill-server is banned)
  [ -n "$sess" ] && "$RELAY_TMUX" kill-session -t "$sess" 2>/dev/null || true
  # signal the supervisor to terminate; its EXIT trap deletes the run dir
  if [ -n "$pid" ] && [ "$pid" != "null" ]; then
    kill "$pid" 2>/dev/null || true
  fi
  echo "relay: stopped $(basename "$rd")."
}
