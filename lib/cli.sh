#!/usr/bin/env bash
# relay CLI argument parsing. Sourceable + test-friendly: sets globals, never exits.
# relay_parse_args returns 0 on success; nonzero + sets RELAY_PARSE_ERR on failure.

# Parse a duration (e.g. 30s, 90m, 8h, 2d, or a bare integer of seconds) to seconds.
# Echoes the seconds on success; returns nonzero (echoes nothing) on bad input.
relay_parse_duration() {
  local d="$1" num unit
  case "$d" in
    *[0-9]s) num="${d%s}"; unit=1 ;;
    *[0-9]m) num="${d%m}"; unit=60 ;;
    *[0-9]h) num="${d%h}"; unit=3600 ;;
    *[0-9]d) num="${d%d}"; unit=86400 ;;
    *[0-9]) num="$d"; unit=1 ;;
    *) return 1 ;;
  esac
  case "$num" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$(( num * unit ))"
}

# Emit the usage/help text. Lists every relay flag and subcommand.
relay_usage() {
  cat <<'EOF'
Usage: relay [relay flags] -- [claude args passed verbatim]

Run Claude Code as a long-lived, self-rotating session. relay hosts claude in
tmux, auto-attaches you, and rotates to a fresh session (with an injected
handoff) when context crosses the threshold.

Launch flags:
  --rotate-at <pct>      Rotate when context >= this % (default 60).
  --max-gen <n>          Cap: stop after N generations.
  --max-runtime <dur>    Cap: stop after wall-clock (e.g. 30s, 90m, 8h, 2d).
  --max-cost <usd>       Cap: stop after cumulative cost (API-cost mode only).
  --no-auto-continue     Load handoff and wait (default auto-continues).
  --rotation-timeout <dur> Wait for the outgoing generation to hand off and
                         settle before giving up on a rotation (default 120s).
  --switch               When nested in tmux (e.g. byobu), switch the client to
                         the new session on launch. Default: stay put and print
                         the attach command (keeps your current window view).

Subcommands (each takes an explicit <run_id>, prefix-matchable):
  --list                 Table of live runs (the only discovery command).
  --attach <run_id>      Attach to a run.
  --stop <run_id>        Stop a run (deletes its run dir on teardown).
  --status <run_id>      Print a run's state.json.
  --install-statusline <file>
                         Install the statusline tee into your statusline file.

  -h, --help             Show this help and exit.

Bare `relay` = --rotate-at 60, no caps, auto-continue on.
EOF
}

# Parse relay's own argv. Populates:
#   RELAY_MODE : launch | list | attach | stop | status | install-statusline
#   RELAY_ARG_ID : run_id (attach/stop/status) or file path (install-statusline)
#   RELAY_OPT_ROTATE_AT / MAX_GEN / MAX_RUNTIME_S / MAX_COST / ROTATION_TIMEOUT / AUTO_CONTINUE
#   RELAY_CLAUDE_ARGS : array of args after `--`, passed verbatim to claude
# On error: returns nonzero and sets RELAY_PARSE_ERR.
relay_parse_args() {
  RELAY_MODE="launch"
  RELAY_ARG_ID=""
  RELAY_OPT_ROTATE_AT="60"
  RELAY_OPT_MAX_GEN=""
  RELAY_OPT_MAX_RUNTIME_S=""
  RELAY_OPT_MAX_COST=""
  RELAY_OPT_ROTATION_TIMEOUT="120"
  RELAY_OPT_AUTO_CONTINUE="1"
  RELAY_OPT_SWITCH="0"
  RELAY_CLAUDE_ARGS=()
  RELAY_PARSE_ERR=""
  local saw_launch_flag=0 saw_subcommand=0 dur

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) RELAY_MODE="help"; return 0 ;;
      --) shift; RELAY_CLAUDE_ARGS=("$@"); break ;;
      --rotate-at)
        [ $# -ge 2 ] || { RELAY_PARSE_ERR="--rotate-at requires a value"; return 1; }
        RELAY_OPT_ROTATE_AT="$2"; saw_launch_flag=1; shift 2 ;;
      --max-gen)
        [ $# -ge 2 ] || { RELAY_PARSE_ERR="--max-gen requires a value"; return 1; }
        RELAY_OPT_MAX_GEN="$2"; saw_launch_flag=1; shift 2 ;;
      --max-runtime)
        [ $# -ge 2 ] || { RELAY_PARSE_ERR="--max-runtime requires a value"; return 1; }
        dur="$(relay_parse_duration "$2")" || { RELAY_PARSE_ERR="invalid --max-runtime: $2"; return 1; }
        RELAY_OPT_MAX_RUNTIME_S="$dur"; saw_launch_flag=1; shift 2 ;;
      --max-cost)
        [ $# -ge 2 ] || { RELAY_PARSE_ERR="--max-cost requires a value"; return 1; }
        RELAY_OPT_MAX_COST="$2"; saw_launch_flag=1; shift 2 ;;
      --rotation-timeout)
        [ $# -ge 2 ] || { RELAY_PARSE_ERR="--rotation-timeout requires a value"; return 1; }
        dur="$(relay_parse_duration "$2")" || { RELAY_PARSE_ERR="invalid --rotation-timeout: $2"; return 1; }
        RELAY_OPT_ROTATION_TIMEOUT="$dur"; saw_launch_flag=1; shift 2 ;;
      --no-auto-continue)
        RELAY_OPT_AUTO_CONTINUE="0"; saw_launch_flag=1; shift ;;
      --switch)
        RELAY_OPT_SWITCH="1"; saw_launch_flag=1; shift ;;
      --list)
        RELAY_MODE="list"; saw_subcommand=1; shift ;;
      --attach|--stop|--status)
        local m="${1#--}"
        [ $# -ge 2 ] || { RELAY_PARSE_ERR="--$m requires a <run_id>"; return 1; }
        RELAY_MODE="$m"; RELAY_ARG_ID="$2"; saw_subcommand=1; shift 2 ;;
      --install-statusline)
        [ $# -ge 2 ] || { RELAY_PARSE_ERR="--install-statusline requires a <file>"; return 1; }
        RELAY_MODE="install-statusline"; RELAY_ARG_ID="$2"; saw_subcommand=1; shift 2 ;;
      *)
        RELAY_PARSE_ERR="unknown option: $1 (put claude args after --)"; return 1 ;;
    esac
  done

  if [ "$saw_subcommand" -eq 1 ] && { [ "$saw_launch_flag" -eq 1 ] || [ "${#RELAY_CLAUDE_ARGS[@]}" -gt 0 ]; }; then
    RELAY_PARSE_ERR="subcommands take no launch flags or claude args"
    return 1
  fi
  return 0
}
