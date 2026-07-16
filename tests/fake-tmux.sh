#!/usr/bin/env bash
# Test double for tmux: logs its argv (one line per call) to $FAKE_TMUX_LOG.
# `has-session` exits per $FAKE_HAS_SESSION (default 1=alive). Everything else exits 0.
printf '%s\n' "$*" >> "${FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  has-session) [ "${FAKE_HAS_SESSION:-1}" = "1" ] && exit 0 || exit 1 ;;
  # new-session -P -F '#{pane_id}' prints the launched pane id on stdout
  new-session) case " $* " in *" -P "*) echo "${FAKE_TMUX_PANE:-%0}" ;; esac; exit 0 ;;
  *) exit 0 ;;
esac
