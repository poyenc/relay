#!/usr/bin/env bash
cat > /dev/null   # drain stdin
printf 'RELAY_RUN_DIR=%s\nRELAY_STATE=%s\nCLAUDE_PLUGIN_ROOT=%s\n' \
  "${RELAY_RUN_DIR:-UNSET}" "${RELAY_STATE:-UNSET}" "${CLAUDE_PLUGIN_ROOT:-UNSET}" \
  > /tmp/relay-spike-env.txt
exit 0
