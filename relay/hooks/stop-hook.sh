#!/usr/bin/env bash
# Stop hook: delegate rotate/continue decision to the relay supervisor via file IPC.
# Must NEVER hard-fail the turn: always exit 0.
set -uo pipefail
payload="$(cat)"
rd="${RELAY_RUN_DIR:-}"
[ -n "$rd" ] && [ -d "$rd" ] || exit 0

rm -f "$rd/stop-response.json" 2>/dev/null
printf '%s' "$payload" > "$rd/stop-request.json.tmp" 2>/dev/null || exit 0
mv "$rd/stop-request.json.tmp" "$rd/stop-request.json" 2>/dev/null || exit 0

# poll up to 5s (50 * 0.1)
for _ in $(seq 1 50); do
  if [ -f "$rd/stop-response.json" ]; then
    resp="$(cat "$rd/stop-response.json" 2>/dev/null)"
    rm -f "$rd/stop-response.json" 2>/dev/null
    [ -z "$resp" ] || [ "$resp" = "{}" ] && exit 0
    printf '%s\n' "$resp"
    exit 0
  fi
  sleep 0.1
done
exit 0   # timeout -> no-op (supervisor absent/hung)
