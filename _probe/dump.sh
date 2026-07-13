#!/bin/bash
# Capture a hook's stdin payload to a per-event file, then no-op allow.
EVENT="${1:-unknown}"
OUT="/home/AMD/poyechen/workspace/repo/supervised-claude/_probe/payloads"
mkdir -p "$OUT"
cat > "$OUT/${EVENT}.json"
exit 0
