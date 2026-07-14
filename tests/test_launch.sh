#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.."
source tests/assert.sh
source lib/state.sh
source bin/relay          # sourceable: dispatch guarded by BASH_SOURCE test

FAKE="$PWD/tests/fake-tmux.sh"; chmod +x "$FAKE"

# --- pure: build_launch_cmd quotes each arg safely ---
cmd="$(relay_build_launch_cmd /usr/bin/claude /plug --model opus -p "hello world")"
assert_contains "$cmd" "/usr/bin/claude" "claude bin present"
assert_contains "$cmd" "--plugin-dir /plug" "plugin dir present"
# round-trip: the string must eval back to the exact argv (this proves quoting)
eval "set -- $cmd"
assert_eq "$1" "/usr/bin/claude" "argv0"
assert_eq "$4" "--model" "argv after plugin-dir"
assert_eq "$#" "7" "arg count: claude --plugin-dir /plug --model opus -p 'hello world'"
assert_eq "${!#}" "hello world" "last argv is the spaced arg intact"

# --- full launch flow (fake tmux, stub supervisor, no attach) ---
export TMPDIR; TMPDIR="$(mktemp -d)"    # isolate run root
stub_sup="$TMPDIR/stub-sup.sh"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$stub_sup"; chmod +x "$stub_sup"
tmuxlog="$TMPDIR/tmux.log"; : > "$tmuxlog"

out="$(
  RELAY_TMUX="$FAKE" FAKE_TMUX_LOG="$tmuxlog" \
  RELAY_CLAUDE_BIN=/usr/bin/claude RELAY_SUPERVISOR_BIN="$stub_sup" \
  RELAY_NO_ATTACH=1 \
  bash bin/relay --rotate-at 45 --max-gen 3 --no-auto-continue -- -p "do work"
)"

# a run dir was created under the isolated root
rd="$(ls -d "$(relay_root)"/* 2>/dev/null | head -1)"
assert_file_exists "$rd/state.json" "state.json created by launch"
assert_eq "$(relay_state_get "$rd" '.policy.rotate_at_pct')" "45" "rotate-at stored"
assert_eq "$(relay_state_get "$rd" '.policy.max_gen')" "3" "max-gen stored"
assert_eq "$(relay_state_get "$rd" '.auto_continue')" "false" "auto-continue off stored"
sess="$(relay_state_get "$rd" '.tmux_session')"
assert_contains "$sess" "relay-" "session name derived from run_id"
assert_contains "$(relay_state_get "$rd" '.launch_cmd')" "/usr/bin/claude" "launch cmd recorded"
# launch_cmd must eval back to the exact argv (claude ... -p 'do work')
eval "set -- $(relay_state_get "$rd" '.launch_cmd')"
assert_eq "${!#}" "do work" "claude arg 'do work' survives launch_cmd round-trip"
# supervisor pid is a live process (our stub)
sup_pid="$(relay_state_get "$rd" '.supervisor_pid')"
assert_ok "supervisor pid recorded: $sup_pid"
kill -0 "$sup_pid" 2>/dev/null && assert_ok "supervisor process alive" || assert_eq alive dead "supervisor should be alive"

# tmux new-session called with env + the launch command
assert_contains "$(cat "$tmuxlog")" "new-session" "tmux session created"
assert_contains "$(cat "$tmuxlog")" "RELAY_RUN_DIR=$rd" "run dir exported into session"
assert_contains "$(cat "$tmuxlog")" "-s $sess" "session named"
# RELAY_* scrubbed from session scope so later windows don't inherit + clobber
assert_contains "$(cat "$tmuxlog")" "set-environment -u -t $sess RELAY_RUN_DIR" "run dir unset from session scope"
assert_contains "$(cat "$tmuxlog")" "set-environment -u -t $sess RELAY_STATE" "statusline path unset from session scope"
# startup banner prints run_id + attach hint
assert_contains "$out" "$(basename "$rd")" "run_id printed"
assert_contains "$out" "--attach" "attach hint printed"

# cleanup the stub supervisor
kill "$sup_pid" 2>/dev/null; wait "$sup_pid" 2>/dev/null

finish
