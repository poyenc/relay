#!/usr/bin/env bash
# Run-directory lifecycle: root, create, discover live, prune dead.
relay_root() { printf '%s/relay-%s' "${TMPDIR:-/tmp}" "$(id -un)"; }

# True iff <pid> is actually THIS run's supervisor, not just any live process with
# that PID. `kill -0` alone is unsafe: after the supervisor dies its PID can be
# recycled by an unrelated process, which would then be reported live and - worse -
# be the target of `relay --stop`. Match the recorded run dir in the process's
# cmdline (the supervisor is always `... relay-supervisor.sh --run-dir <rd>`).
relay_pid_is_supervisor() {  # <pid> <run_dir>
  local pid="$1" rd="$2" cl="/proc/$1/cmdline"
  kill -0 "$pid" 2>/dev/null || return 1
  # The run dir is a unique mktemp path; its presence in the process's argv
  # (`... --run-dir <rd>`) confirms this PID is genuinely that run's supervisor.
  if [ -r "$cl" ]; then
    # Extract the --run-dir value from cmdline and compare resolved (canonical)
    # paths so that symlink renames of the relay root don't break the check.
    local cmdline_rd
    cmdline_rd="$(tr '\0' '\n' < "$cl" 2>/dev/null | grep -A1 '^--run-dir$' | tail -1)"
    [ -z "$cmdline_rd" ] && \
      cmdline_rd="$(tr '\0' ' ' < "$cl" 2>/dev/null | sed -n 's/.*--run-dir \([^ ]*\).*/\1/p')"
    [ -z "$cmdline_rd" ] && return 1
    local real_rd real_cmdline_rd
    real_rd="$(readlink -f "$rd" 2>/dev/null || printf '%s' "$rd")"
    real_cmdline_rd="$(readlink -f "$cmdline_rd" 2>/dev/null || printf '%s' "$cmdline_rd")"
    [ "$real_rd" = "$real_cmdline_rd" ]
    return $?
  fi
  # No /proc (non-Linux): degrade to the liveness-only check rather than falsely
  # pruning a live run. (Linux is the documented target; this is a safety net.)
  return 0
}

relay_create_rundir() {
  local root; root="$(relay_root)"
  mkdir -m 700 -p "$root"
  mktemp -d "$root/$(date +%y%m%d-%H%M%S)-XXXXXX"
}

relay_list_live() {
  local root; root="$(relay_root)"; local d pid gen
  [ -d "$root" ] || return 0
  for d in "$root"/*; do
    [ -f "$d/state.json" ] || continue
    pid="$(jq -r '.supervisor_pid // empty' "$d/state.json" 2>/dev/null)"
    [ -n "$pid" ] || continue
    if relay_pid_is_supervisor "$pid" "$d"; then
      gen="$(jq -r '.generation // 0' "$d/state.json" 2>/dev/null)"
      printf '%s\t%s\t%s\n' "$d" "$pid" "$gen"
    fi
  done
}

# Prune ended run dirs, but only when stale (> 7 days since they ended). A run is
# "ended" when its supervisor PID is not live; "ended-at" is .stopped_at if
# present, else the state.json mtime. Live runs are never pruned. This keeps
# recent runs on disk for post-mortem (handoff, pane.log, supervisor.log).
relay_prune_dead() {
  local root; root="$(relay_root)"; local d pid ended now age
  local ttl=604800   # 7 days in seconds
  [ -d "$root" ] || return 0
  now="$(date +%s)"
  for d in "$root"/*; do
    [ -d "$d" ] || continue
    if [ -f "$d/state.json" ]; then
      pid="$(jq -r '.supervisor_pid // empty' "$d/state.json" 2>/dev/null)"
      if [ -n "$pid" ] && relay_pid_is_supervisor "$pid" "$d"; then continue; fi
      ended="$(jq -r '.stopped_at // empty' "$d/state.json" 2>/dev/null)"
      [ -n "$ended" ] || ended="$(stat -c %Y "$d/state.json" 2>/dev/null || echo 0)"
    else
      ended="$(stat -c %Y "$d" 2>/dev/null || echo 0)"
    fi
    age=$(( now - ended ))
    [ "$age" -ge "$ttl" ] && rm -rf "$d"
  done
}
