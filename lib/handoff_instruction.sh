#!/usr/bin/env bash
# Emits the two-tier rotate instruction sent as the Stop hook's block reason.
relay_handoff_instruction() {
  local hp="$1" mp="$2" dir
  dir="$(dirname "$hp")"
  cat <<EOF
ROTATION REQUESTED - you are about to be replaced by a fresh session with empty context.
Write a COMPLETE handoff so your successor continues with zero prior memory. It is a
--resume (restore the working setup), not a summary.

ROSTER FIRST - did you spawn teammates via the Agent tool this session that are still
reachable via SendMessage and hold live context? Idle/waiting teammates COUNT; one-shot
subagents that already returned (Explore, research) and background shells do NOT.
  - SOLO (none): write ONE handoff to $hp .
  - TEAM (one or more): write the LEAD handoff to $hp AND one file per live teammate next
    to it at $dir/handoff-<seat>.md (seat = the teammate's Agent name). The lead handoff
    MUST include a "Respawn the team" section listing, per seat: Agent name, agent type
    (subagent_type + any model), a one-line role, its handoff path above, and any
    worktree/branch it used. Relay injects ONLY $hp into your successor, so the fresh lead
    rebuilds the roster from that section and routes each teammate its own file - the lead
    file must be self-executing. Losing a teammate's context is the worst outcome here.

PREFERRED: if you have a handoff skill available, invoke it now, with these relay overrides:
  - Save the (lead) handoff to $hp, NOT the temp-dir default; for a team, put teammate files
    at $dir/handoff-<seat>.md (the gen dir is the namespace - no timestamp suffix needed).
  - For a team, still follow the skill's team path (references/team-handoffs.md): pause
    teammates, collect one handoff per teammate, then record the Respawn section.
  - Skip the "paste-prompt / kickoff-prompt for the user" step; create the marker below instead.

FALLBACK: if you do NOT have a handoff skill, write it yourself. Two passes:
  Pass 1 (WHAT): objective and what "done" looks like; task list (done/doing/todo);
    key files, branch, and build/test/run commands - BY REFERENCE, do not paste contents.
  Pass 2 (HOW): operating rules WITH their why; decisions and rationale; dead ends and
    gotchas (what NOT to retry); the workflow to resume if one is in use.
  TEAM fallback: before the lead file, SendMessage each live teammate to write its own seat
    handoff to $dir/handoff-<seat>.md (its mid-task state and exact next action; the rules
    YOU gave it and why; its decisions and dead ends; the files/branch it touches; no
    secrets). Then add the "Respawn the team" section to the lead file.
  REGENERATE-AND-REPLACE: the prior handoff(s) are already in your context. Do NOT fold them
    in verbatim. Carry forward only what is still true and serves the REMAINING work; collapse
    completed tasks to one line; drop settled decisions and foreclosed dead ends; re-audit
    the reference list so it does not grow each cycle. Keep the Goal section stable. Drop
    finished teammate seats; keep only still-active seats as respawn targets.

As your final action - after the lead handoff AND every teammate file exist - create the
empty marker file $mp . Do nothing else - do not continue the task.
EOF
}
