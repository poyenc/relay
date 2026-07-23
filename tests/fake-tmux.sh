#!/usr/bin/env bash
# Test double for tmux: logs its argv (one line per call) to $FAKE_TMUX_LOG.
# has-session exits per $FAKE_HAS_SESSION (default 1=alive).
# list-panes models pane liveness/existence for teardown + lifecycle tests:
#   FAKE_PANE_MISSING=1 -> pane gone (no output; mimics a closed pane)
#   FAKE_PANE_DEAD (default 1) -> value of #{pane_dead} for a present pane
# Everything else exits 0.
printf '%s\n' "$*" >> "${FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  has-session) [ "${FAKE_HAS_SESSION:-1}" = "1" ] && exit 0 || exit 1 ;;
  # new-session -P -F '#{pane_id}' prints the launched pane id on stdout
  new-session) case " $* " in *" -P "*) echo "${FAKE_TMUX_PANE:-%0}" ;; esac; exit 0 ;;
  list-panes)
    [ "${FAKE_PANE_MISSING:-0}" = "1" ] && exit 0   # pane gone: print nothing
    # -F '#{pane_dead}' -> liveness; any other -F / bare -> a present-pane line
    case " $* " in
      *"#{pane_dead}"*) printf '%s\n' "${FAKE_PANE_DEAD:-1}" ;;
      *) printf '%%0\n' ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
