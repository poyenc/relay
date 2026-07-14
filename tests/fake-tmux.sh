#!/usr/bin/env bash
# Test double for tmux: logs its argv (one line per call) to $FAKE_TMUX_LOG.
# `has-session` exits per $FAKE_HAS_SESSION (default 1=alive). Everything else exits 0.
printf '%s\n' "$*" >> "${FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  has-session) [ "${FAKE_HAS_SESSION:-1}" = "1" ] && exit 0 || exit 1 ;;
  *) exit 0 ;;
esac
