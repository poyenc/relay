#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")"
fail=0
for t in test_*.sh; do
  echo "== $t =="
  if bash "$t"; then :; else fail=1; echo "  ^ FAILED"; fi
done
[ "$fail" -eq 0 ] && echo "ALL GREEN" || echo "SOME FAILED"
exit "$fail"
