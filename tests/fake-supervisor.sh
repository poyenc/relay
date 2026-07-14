#!/usr/bin/env bash
# Test double for a live supervisor: idles so its PID stays alive, and - crucially -
# keeps `--run-dir <rd>` in its argv so relay_pid_is_supervisor matches it, exactly
# like the real relay-supervisor.sh. Usage: fake-supervisor.sh --run-dir <rd>
# The sleep is backgrounded and reaped on TERM/EXIT so killing this PID leaves no
# orphaned sleep child (do NOT exec - that would drop the argv we need matched on).
_child=""
trap 'kill "$_child" 2>/dev/null; exit 0' TERM INT
sleep 300 & _child=$!
wait "$_child"
