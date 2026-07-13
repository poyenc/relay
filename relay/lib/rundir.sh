#!/usr/bin/env bash
# Run-directory lifecycle: root, create, discover live, prune dead.
relay_root() { printf '%s/relay-%s' "${TMPDIR:-/tmp}" "$(id -u)"; }

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
    if kill -0 "$pid" 2>/dev/null; then
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
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
    fi
    rm -rf "$d"
  done
}
