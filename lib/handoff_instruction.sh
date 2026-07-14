#!/usr/bin/env bash
# Emits the two-tier rotate instruction sent as the Stop hook's block reason.
relay_handoff_instruction() {
  local hp="$1" mp="$2"
  cat <<EOF
ROTATION REQUESTED — you are about to be replaced by a fresh session with empty context.
Write a COMPLETE handoff to $hp so your successor can continue with zero prior memory.

PREFERRED: if you have a handoff skill available, invoke it now, with two overrides:
  - Save to $hp (NOT the temp-dir default).
  - Skip the "paste-prompt for the user" step; instead create the marker below.

FALLBACK: if you do NOT have a handoff skill, write $hp yourself. It is a --resume,
not a summary. Two passes:
  Pass 1 (WHAT): objective and what "done" looks like; task list (done/doing/todo);
    key files, branch, and build/test/run commands — BY REFERENCE, do not paste contents.
  Pass 2 (HOW): operating rules WITH their why; decisions and rationale; dead ends and
    gotchas (what NOT to retry); the workflow to resume if one is in use.
  REGENERATE-AND-REPLACE: the prior handoff is already in your context. Do NOT fold it in
    verbatim. Carry forward only what is still true and serves the REMAINING work; collapse
    completed tasks to one line; drop settled decisions and foreclosed dead ends; re-audit
    the reference list so it does not grow each cycle. Keep the Goal section stable.

As your final action, create the empty marker file $mp . Do nothing else — do not continue the task.
EOF
}
