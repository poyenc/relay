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
    echo "relay: (nested tmux - switching client to $sess)" >&2
    "$RELAY_TMUX" switch-client -t "$sess"
  else
    "$RELAY_TMUX" attach-session -t "$sess"
  fi
}

RELAY_TEE_SENTINEL="# >>> relay statusline tee >>>"

# Insert a one-time, no-op-safe tee into the user's statusline command file so it
# writes the raw statusline JSON to $RELAY_STATE. Transparent when RELAY_STATE is
# unset (plain claude). Idempotent; backs up the original to <file>.relay-bak.
relay_cmd_install_statusline() {  # <statusline-file>
  local f="$1"
  [ -f "$f" ] || { echo "relay: no such file: $f" >&2; return 1; }
  if grep -qF "$RELAY_TEE_SENTINEL" "$f"; then
    echo "relay: tee already installed in $f"; return 0
  fi
  cp -p "$f" "$f.relay-bak"

  local tmp; tmp="$(mktemp)"
  local first; first="$(head -1 "$f")"
  {
    if printf '%s' "$first" | grep -q '^#!'; then
      printf '%s\n' "$first"
      _relay_tee_block
      tail -n +2 "$f"
    else
      _relay_tee_block
      cat "$f"
    fi
  } > "$tmp"
  # preserve mode
  chmod "$(stat -c '%a' "$f")" "$tmp"
  mv "$tmp" "$f"
  echo "relay: statusline tee installed in $f (backup: $f.relay-bak)"
}

# The injected block: capture stdin to a temp file, atomically tee to $RELAY_STATE
# if set, then re-feed the BYTE-IDENTICAL stdin (via `exec <file`, not a here-string -
# `$(cat)`+`<<<` would mangle trailing newlines) so the user's script is unaffected.
_relay_tee_block() {
  cat <<'TEE'
# >>> relay statusline tee >>>
if [ -n "${RELAY_STATE:-}" ]; then
  _relay_tmp="$(mktemp)"
  cat > "$_relay_tmp"
  cp "$_relay_tmp" "$RELAY_STATE.tmp" 2>/dev/null && mv "$RELAY_STATE.tmp" "$RELAY_STATE" 2>/dev/null
  exec < "$_relay_tmp"
  rm -f "$_relay_tmp"
fi
# <<< relay tee end <<<
TEE
}

relay_cmd_stop() {  # <id-or-prefix>
  local rd sess pane target pid i confirm grace etimeout window
  rd="$(relay_resolve_run_id "$1")" || return 1
  sess="$(relay_state_get "$rd" '.tmux_session')"
  pane="$(relay_state_get "$rd" '.tmux_pane // ""')"
  target="${pane:-$sess}"
  pid="$(relay_state_get "$rd" '.supervisor_pid')"
  # Ask the supervisor to stop gracefully (it runs /exit teardown + kill-pane).
  # Marker mirrors the Stop-hook IPC; atomic tmp+mv.
  printf '{"reason":"user_stop"}' > "$rd/stop-run.json.tmp" 2>/dev/null \
    && mv "$rd/stop-run.json.tmp" "$rd/stop-run.json" 2>/dev/null || true
  # Poll for confirmation (status=stopped). If RELAY_STOP_CONFIRM_S is explicitly
  # set, honor it verbatim (override for tests / power users). Otherwise size the
  # window to the run's teardown budget (grace + exit-timeout + margin), so a run
  # launched with large --rotate-grace/--exit-timeout is not force-killed before
  # graceful_teardown finishes. Bounded either way so --stop never hangs.
  if [ -n "${RELAY_STOP_CONFIRM_S:-}" ]; then
    window="$RELAY_STOP_CONFIRM_S"
  else
    grace="$(relay_state_get "$rd" '.rotate_grace // 2')"
    etimeout="$(relay_state_get "$rd" '.exit_timeout // 5')"
    window=$(( grace + etimeout + 5 ))
  fi
  confirm=0
  for i in $(seq 1 "$window"); do
    [ "$(relay_state_get "$rd" '.status // ""')" = "stopped" ] && { confirm=1; break; }
    sleep 1
  done
  if [ "$confirm" != "1" ]; then
    # Supervisor didn't confirm (wedged/dead). Reap the pane ourselves and signal
    # the pid. Never kill-session - only relay's pane.
    [ -n "$target" ] && "$RELAY_TMUX" kill-pane -t "$target" 2>/dev/null || true
    if [ -n "$pid" ] && [ "$pid" != "null" ] && [ "$pid" -gt 0 ] 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  fi
  echo "relay: stopped $(basename "$rd")."
}
