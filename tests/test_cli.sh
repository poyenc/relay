#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/cli.sh

# --- duration parsing ---
assert_eq "$(relay_parse_duration 30s)"  "30"     "30s -> 30"
assert_eq "$(relay_parse_duration 90m)"  "5400"   "90m -> 5400"
assert_eq "$(relay_parse_duration 8h)"   "28800"  "8h -> 28800"
assert_eq "$(relay_parse_duration 2d)"   "172800" "2d -> 172800"
assert_eq "$(relay_parse_duration 120)"  "120"    "bare int -> seconds"
if relay_parse_duration abc >/dev/null 2>&1; then assert_eq bad ok "abc invalid duration"; else assert_ok "abc rejected"; fi
if relay_parse_duration 5x  >/dev/null 2>&1; then assert_eq bad ok "5x invalid duration";  else assert_ok "5x rejected"; fi

# --- bare relay: launch defaults ---
relay_parse_args
assert_eq "$?" "0" "bare parse ok"
assert_eq "$RELAY_MODE" "launch" "bare -> launch"
assert_eq "$RELAY_OPT_ROTATE_AT" "60" "default rotate-at 60"
assert_eq "$RELAY_OPT_ROTATION_TIMEOUT" "120" "default rotation-timeout 120"
assert_eq "$RELAY_OPT_ROTATE_GRACE" "2" "default rotate-grace 2"
assert_eq "$RELAY_OPT_EXIT_TIMEOUT" "5" "default exit-timeout 5"
assert_eq "$RELAY_OPT_AUTO_CONTINUE" "1" "auto-continue on by default"
assert_eq "$RELAY_OPT_MAX_GEN" "" "no gen cap"
assert_eq "$RELAY_OPT_MAX_RUNTIME_S" "" "no runtime cap"
assert_eq "$RELAY_OPT_MAX_COST" "" "no cost cap"
assert_eq "${#RELAY_CLAUDE_ARGS[@]}" "0" "no claude args"

# --- full launch flags + `--` split ---
relay_parse_args --rotate-at 45 --max-gen 5 --max-runtime 90m --max-cost 12.50 \
  --no-auto-continue --rotation-timeout 90s --rotate-grace 3s --exit-timeout 8s -- --model opus -p "hello world"
assert_eq "$?" "0" "full parse ok"
assert_eq "$RELAY_MODE" "launch" "flags -> launch"
assert_eq "$RELAY_OPT_ROTATE_AT" "45" "rotate-at parsed"
assert_eq "$RELAY_OPT_MAX_GEN" "5" "max-gen parsed"
assert_eq "$RELAY_OPT_MAX_RUNTIME_S" "5400" "max-runtime -> seconds"
assert_eq "$RELAY_OPT_MAX_COST" "12.50" "max-cost parsed"
assert_eq "$RELAY_OPT_AUTO_CONTINUE" "0" "no-auto-continue flips off"
assert_eq "$RELAY_OPT_ROTATION_TIMEOUT" "90" "rotation-timeout duration -> seconds"
assert_eq "$RELAY_OPT_ROTATE_GRACE" "3" "rotate-grace duration -> seconds"
assert_eq "$RELAY_OPT_EXIT_TIMEOUT" "8" "exit-timeout duration -> seconds"
assert_eq "${#RELAY_CLAUDE_ARGS[@]}" "4" "4 claude args after --"
assert_eq "${RELAY_CLAUDE_ARGS[0]}" "--model" "claude arg 0"
assert_eq "${RELAY_CLAUDE_ARGS[3]}" "hello world" "claude arg 3 (quoted preserved)"

# --- `--` with relay-looking flags AFTER it are claude args, not relay flags ---
relay_parse_args --rotate-at 30 -- --rotate-at 999 --max-gen 999
assert_eq "$RELAY_OPT_ROTATE_AT" "30" "relay flag before -- wins"
assert_eq "${RELAY_CLAUDE_ARGS[0]}" "--rotate-at" "collision flag passed to claude verbatim"
assert_eq "${#RELAY_CLAUDE_ARGS[@]}" "4" "all post---tokens are claude args"

# --- subcommands ---
relay_parse_args --list
assert_eq "$RELAY_MODE" "list" "--list mode"

relay_parse_args --attach run-abc
assert_eq "$RELAY_MODE" "attach" "--attach mode"
assert_eq "$RELAY_ARG_ID" "run-abc" "--attach id"

relay_parse_args --stop run-def
assert_eq "$RELAY_MODE" "stop" "--stop mode"
assert_eq "$RELAY_ARG_ID" "run-def" "--stop id"

relay_parse_args --status run-ghi
assert_eq "$RELAY_MODE" "status" "--status mode"
assert_eq "$RELAY_ARG_ID" "run-ghi" "--status id"

# --- error cases (return nonzero, set RELAY_PARSE_ERR, do not exit) ---
if relay_parse_args --attach; then assert_eq bad ok "--attach needs id"; else assert_ok "--attach missing id rejected"; fi
assert_contains "$RELAY_PARSE_ERR" "attach" "err mentions attach"
if relay_parse_args --bogus; then assert_eq bad ok "unknown flag rejected"; else assert_ok "unknown flag rejected"; fi
if relay_parse_args --rotate-at; then assert_eq bad ok "rotate-at needs value"; else assert_ok "rotate-at missing value rejected"; fi
if relay_parse_args --rotate-at 60 --list; then assert_eq bad ok "mixing launch flags with subcommand rejected"; else assert_ok "launch-flag + subcommand rejected"; fi
if relay_parse_args --rotation-timeout; then assert_eq bad ok "rotation-timeout needs value"; else assert_ok "rotation-timeout missing value rejected"; fi
if relay_parse_args --rotation-timeout bogus; then assert_eq bad ok "rotation-timeout rejects garbage"; else assert_ok "rotation-timeout invalid duration rejected"; fi
if relay_parse_args --rotate-grace; then assert_eq bad ok "rotate-grace needs value"; else assert_ok "rotate-grace missing value rejected"; fi
if relay_parse_args --exit-timeout bogus; then assert_eq bad ok "exit-timeout rejects garbage"; else assert_ok "exit-timeout invalid duration rejected"; fi
relay_parse_args --rotation-timeout 2m
assert_eq "$RELAY_OPT_ROTATION_TIMEOUT" "120" "rotation-timeout 2m -> 120s"

# --- statusline install flag ---
relay_parse_args --install-statusline /home/me/.claude/statusline.sh
assert_eq "$RELAY_MODE" "install-statusline" "install-statusline mode"
assert_eq "$RELAY_ARG_ID" "/home/me/.claude/statusline.sh" "statusline file path captured"

# --- help flag ---
relay_parse_args --help
assert_eq "$?" "0" "--help parse ok"
assert_eq "$RELAY_MODE" "help" "--help mode"
relay_parse_args -h
assert_eq "$RELAY_MODE" "help" "-h mode"
# help wins over other flags without tripping the mixing error
relay_parse_args --rotate-at 45 --help
assert_eq "$?" "0" "--help after a flag parse ok"
assert_eq "$RELAY_MODE" "help" "--help wins over launch flags"

# --- usage text mentions every flag/subcommand ---
u="$(relay_usage)"
assert_contains "$u" "Usage" "usage has header"
assert_contains "$u" "--rotate-at" "usage: rotate-at"
assert_contains "$u" "--max-gen" "usage: max-gen"
assert_contains "$u" "--max-runtime" "usage: max-runtime"
assert_contains "$u" "--max-cost" "usage: max-cost"
assert_contains "$u" "--no-auto-continue" "usage: no-auto-continue"
assert_contains "$u" "--rotation-timeout" "usage: rotation-timeout"
assert_contains "$u" "--rotate-grace" "usage: rotate-grace"
assert_contains "$u" "--exit-timeout" "usage: exit-timeout"
assert_contains "$u" "--list" "usage: list"
assert_contains "$u" "--attach" "usage: attach"
assert_contains "$u" "--stop" "usage: stop"
assert_contains "$u" "--status" "usage: status"
assert_contains "$u" "--install-statusline" "usage: install-statusline"

finish
