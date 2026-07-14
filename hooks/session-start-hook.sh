#!/usr/bin/env bash
# SessionStart hook: inject prior generation's handoff (stdout reaches the model).
set -uo pipefail
hp="${RELAY_HANDOFF_PATH:-}"
[ -n "$hp" ] && [ -f "$hp" ] || exit 0
printf '# Fresh session continuing prior work. Read the handoff below fully; read any files it references on demand as the work needs them.\n\n'
cat "$hp"
exit 0
