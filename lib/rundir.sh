#!/usr/bin/env bash
# Run-directory lifecycle: root, create, discover live, prune dead.
relay_root() { printf '%s/relay-%s' "${TMPDIR:-/tmp}" "$(id -u)"; }

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
    tr '\0' ' ' < "$cl" 2>/dev/null | grep -qF -- "--run-dir $rd"
    return $?
  fi
  # No /proc (non-Linux): degrade to the liveness-only check rather than falsely
  # pruning a live run. (Linux is the documented target; this is a safety net.)
  return 0
}

relay_create_rundir() {
  local root; root="$(relay_root)"
  mkdir -m 700 -p "$root"
  mktemp -d "$root/run-$(date +%Y%m%d)-XXXXXX"
}

relay_list_live() {
  local root; root="$(relay_root)"; local d pid gen
  [ -d "$root" ] || return 0
  for d in "$root"/run-*; do
    [ -f "$d/state.json" ] || continue
    pid="$(jq -r '.supervisor_pid // empty' "$d/state.json" 2>/dev/null)"
    [ -n "$pid" ] || continue
    if relay_pid_is_supervisor "$pid" "$d"; then
      gen="$(jq -r '.generation // 0' "$d/state.json" 2>/dev/null)"
      printf '%s\t%s\t%s\n' "$d" "$pid" "$gen"
    fi
  done
}

relay_prune_dead() {
  local root; root="$(relay_root)"; local d pid
  [ -d "$root" ] || return 0
  for d in "$root"/run-*; do
    [ -d "$d" ] || continue
    if [ -f "$d/state.json" ]; then
      pid="$(jq -r '.supervisor_pid // empty' "$d/state.json" 2>/dev/null)"
      if [ -n "$pid" ] && relay_pid_is_supervisor "$pid" "$d"; then continue; fi
    fi
    rm -rf "$d"
  done
}
