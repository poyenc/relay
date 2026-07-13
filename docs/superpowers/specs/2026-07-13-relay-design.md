# relay — Design Spec

**Date:** 2026-07-13
**Status:** Approved design, pre-implementation
**Prior art:** `docs/supervised-claude.md` (original proposal)

## 1. Purpose

`relay` runs a coding agent (Claude Code today) as a long-lived, self-rotating
session. It launches the agent inside tmux, auto-attaches the user, and monitors
context usage. When context crosses a threshold, it makes the agent write a
handoff, kills the session, relaunches a fresh one, and injects the handoff — so
work continues in un-degraded context indefinitely, until the user stops it or a
cap is hit.

The name evokes a relay race: each generation hands the baton to a fresh runner
and the run continues.

**Core goal:** automate *session lifecycle management* (rotation), NOT engineering
decisions. The supervisor never understands the task, never judges handoff
*content*, never makes engineering decisions. It owns lifecycle only.

## 2. Why an external process is mandatory

Nothing inside a Claude session can rotate that session. A `Stop` hook can only
*block* the exit and hand control back — same process, same context window, which
keeps growing toward auto-compact. True rotation = new process + fresh context +
injected handoff. A process cannot fork-and-replace its own live context from the
inside. Therefore an external supervisor is the only mechanism that works. (This
also distinguishes `relay` from the ralph-loop technique, which only prevents
stopping and never rotates.)

## 3. Key decisions (locked during brainstorming)

- **Interaction model:** `relay` behaves like normal `claude`. It hosts `claude`
  in tmux and auto-attaches the user; rotation happens underneath. tmux is an
  invisible implementation detail (user need not know tmux).
- **Rotate INSTEAD of compacting:** trigger a full rotation before Claude's native
  auto-compaction kicks in. Default threshold **60%**.
- **Unattended-first with auto-continue:** after relaunch, the fresh generation
  auto-continues the outstanding task (via a `tmux send-keys` nudge). User CAN
  attach and type. `--no-auto-continue` flips to load-and-wait.
- **Task lives in the handoff chain** (seeded by the first prompt). No separate
  task file. Run ends on caps OR manual stop (user exits Claude, or `--stop`).
- **Telemetry:** authoritative context % from a statusline tee (Source A);
  transcript-parse fallback (Source B). Supervisor computes/reads the %.
- **Handoff instructions baked into the plugin** (two-tier); the on-disk `/handoff`
  skill is used when present but is NOT a dependency.
- **Zero-install hooks** via `--plugin-dir` (session-only; plain `claude`
  untouched, nothing to uninstall).
- **Agent-adapter seam:** architecture separates an agent-agnostic core from a
  per-agent adapter. Only the Claude adapter is built now; Codex/Gemini are
  future drop-in adapters, not rewrites.

## 4. Terminology

- **Run** — one continuous supervised workflow. Owns `run_id`, policy
  (threshold/caps), rotation history, the handoff chain. Spans many agent
  processes.
- **Generation** — one `claude` process. Owns `session_id`, PID, its transcript.
  Rotation increments the generation; the run continues.

## 5. Architecture — core vs. adapter

```
relay/
├── core/         # agent-agnostic
│   ├── wrapper CLI (relay)         — flags, tmux session, auto-attach, subcommands
│   ├── supervisor daemon           — run state, socket, policy, state machine
│   ├── policy engine               — operates on abstract runtime state only
│   ├── lifecycle monitor           — exit-vs-rotation detection
│   └── adapter interface (the seam):
│         get_context_pct()  trigger_handoff()  inject_handoff()  detect_death()
└── adapters/
    └── claude/   # the only adapter built now
        ├── Stop hook (plugin)      — delegate decision to supervisor
        ├── SessionStart hook       — inject prior handoff
        ├── statusline tee (2 lines)— authoritative context %
        └── transcript parser       — fallback context %
```

The policy engine and lifecycle monitor touch only abstract state, so the seam is
cheap to define now and honors the original proposal's agent-agnostic goal without
building a second adapter.

## 6. Components & responsibilities

1. **Wrapper CLI (`relay`)** — parses `[relay flags] -- [claude args]`; creates run
   dir; starts supervisor; creates tmux session (exports `RELAY_*` env); launches
   `claude --plugin-dir <relay-plugin> [args]`; auto-attaches. Subcommands:
   `--attach/--stop/--status <run_id>`, `--list`.
2. **Supervisor daemon** — owns `state.json`; listens on `run.sock`; runs the
   rotation state machine + lifecycle monitor; the ONLY component with policy
   logic.
3. **Stop hook** (Claude adapter, plugin) — thin client: forwards the Stop payload
   (incl. `transcript_path`) to `run.sock`, relays the verdict back to Claude.
   No-op (exit 0) if `$RELAY_SOCK` unset/absent/timeout.
4. **SessionStart hook** (Claude adapter, plugin) — on generation N+1, injects the
   prior generation's `handoff.md` (path via `RELAY_HANDOFF_PATH`) to stdout (reaches
   Claude as context). No-op if unsupervised/no handoff.
5. **Lifecycle monitor** (in supervisor) — watches the `claude` pane; on death,
   relaunch iff `rotation_pending`, else stop. Uses SessionEnd reason as
   corroboration.
6. **Statusline tee** — one-time 2-line no-op-safe addition to the user's actual
   statusline file: writes raw statusline JSON to `$RELAY_STATE` atomically.

## 7. Telemetry — how the supervisor gets context %

**Source A (primary, authoritative):** the statusline JSON already contains
Claude's own `.context_window.used_percentage`. The 2-line tee writes that JSON to
`$RELAY_STATE`; the supervisor reads the field. No arithmetic, correct model window.
Freshness ~60s (statusline refresh cadence).

**Source B (fallback):** when `$RELAY_STATE` is missing or its mtime is older than
~90s, the supervisor parses `transcript_path` (from the Stop payload). Context
tokens = last main-thread assistant message's
`input_tokens + cache_creation_input_tokens + cache_read_input_tokens`; `pct =
tokens / window_size * 100`. Caveats: window_size is model-dependent (default
200k; 1M for some Sonnet modes); `input_tokens` can be a streaming placeholder
(cache fields dominate and are reliable); must filter to the main thread.

**Empirically verified (probe, 2026-07-13):** NO hook payload carries context %.
All hooks carry `transcript_path`; the transcript's last assistant `usage` reflects
cumulative context (measured 67172 tokens = 33.6% of a 200k window).

## 8. Rotation state machine

```
RUNNING --Stop query--> read % (A then B) --> evaluate policy
   |  pct < threshold, caps ok: reply {} (continue), stay RUNNING
   |  pct >= threshold (or hard cap): set rotation_pending=true,
   |     pending_marker=gen-N/handoff.ready, reply block-with-handoff-instruction
   v
ROTATION_PENDING --poll pending_marker-->
   |  marker appears: ROTATING
   |  timeout (--marker-timeout, default 120s) / 8-block cap: ROTATE_FAILED
   v
ROTATING --> read handoff.md --> check caps
   |  cap hit: STOPPED
   |  else: tmux kill gen N (session-scoped ONLY) --> increment generation -->
   |        launch gen N+1 (claude --plugin-dir ... [args]) -->
   |        SessionStart injects handoff.md -->
   |        (auto-continue) send-keys "Continue from the handoff..." -->
   |        clear rotation_pending, rm honored marker --> RUNNING
   v
Any state + process death:
   rotation_pending & our kill -> handled by ROTATING
   else (user exit / crash) -> STOPPED -> teardown

ROTATE_FAILED: log; default = clear pending + return to RUNNING (retry next Stop).
```

**Invariants:**
- Decision point is ONLY the Stop query (Claude idle — the only safe rotation moment).
- `rotation_pending` is the single source of truth for exit-vs-rotation (flag, not timing).
- Loop safety: only block when `stop_hook_active == false`; 8-consecutive-block cap
  is the backstop.
- All tmux ops are `-t $RELAY_SESSION` scoped. **`kill-server` is banned** (shared
  per-user tmux server).

## 9. Marker protocol (handoff completeness handshake)

The marker (`gen-N/handoff.ready`, empty file) is a one-bit signal: "handoff.md
fully written, safe to kill me." It avoids a partial-write race: Claude writes
`handoff.md` completely FIRST, then creates the marker as its final action; marker
present ⇒ handoff flushed.

- Supervisor polls `pending_marker` only while in ROTATION_PENDING (cheap
  `stat` ~500ms, with timeout).
- A marker is meaningful ONLY when the supervisor is actively waiting for THAT
  specific generation's marker path. Outside that window, markers are inert —
  this defeats stale-marker re-rotation and duplicate/same-filename hazards.
- Per-generation directories (`gen-N/handoff.md`) mean no filename is ever shared
  or overwritten across generations.
- Marker `rm`'d after honored; new generation's marker path pre-emptively `rm -f`'d
  at launch (belt-and-suspenders).
- The rotate INSTRUCTION (write handoff + create marker) is delivered ONLY via the
  Stop `block` reason at rotation time — NEVER baked into injected handoff content.
  So a fresh generation has no standing instruction to create a marker.

## 10. Handoff — instruction & document

Modeled on the on-disk `/handoff` skill (`~/.claude/skills/handoff/SKILL.md`),
which already embodies the two requirements: it's a **`--resume`** (restore the
working setup, not just the task) and it **regenerates-and-replaces** over a prior
handoff (does not accumulate — prevents context bloat across a rotation chain).

**Two-tier instruction** (single Stop `block` reason carrying both tiers; Claude
picks at runtime based on what it actually has; supervisor treats both identically):

- **Preferred:** if a `handoff` skill is available, invoke it with two overrides —
  save to `<gen-N>/handoff.md` (not the temp default), and skip the user
  paste-prompt; instead create `<gen-N>/handoff.ready`.
- **Fallback (baked-in, self-contained):** write the handoff using the condensed
  two-pass rules — Pass 1 State (objective + done criteria; task list; key files/
  branch/commands by reference), Pass 2 HOW (operating rules WITH their why;
  decisions + rationale; dead ends/gotchas; workflow to resume) — plus
  REGENERATE-AND-REPLACE (prior handoff is already in context; carry forward only
  what still serves remaining work; collapse completed to one line; re-audit the
  reference list so it doesn't grow). Then create the marker.

**Anti-bloat mechanism:** each `gen-N/handoff.md` is a bounded, current snapshot —
NOT gen-(N-1) + delta. Context stays flat across many rotations. `## Goal` stays
stable to resist objective drift (genuine drift over dozens of rotations remains a
real limitation).

**Injection (SessionStart):** supervisor sets `RELAY_HANDOFF_PATH` to the prior gen's
`handoff.md`; the hook prints a short framing line + the file to stdout. To avoid
re-inflating context at boot, the injected handoff instructs gen N+1 to read
referenced files ON-DEMAND, not all upfront (configurable).

**Known limitation:** handoff quality is Claude's responsibility; the supervisor
only checks the file+marker EXIST, not that they're good (per the non-goals). The
structured two-tier instruction is the mitigation.

## 11. Run directory

```
/tmp/relay-$(id -u)/           # parent, mode 700, per-uid
└── run-YYYYMMDD-XXXXXX/                     # run dir, created via mktemp -d
    ├── run.sock          # RELAY_SOCK (short path — sun_path <108 safe)
    ├── state.json        # run state
    ├── statusline.json   # RELAY_STATE (tee target)
    ├── supervisor.log
    ├── gen-1/{handoff.md, handoff.ready}
    ├── gen-2/handoff.md
    └── gen-3/            # current
```

- Path: `${TMPDIR:-/tmp}/relay-$(id -u)/`. `mktemp -d` guarantees
  race-free unique run dirs even under concurrent same-second launches. Date prefix
  is for readability only; `XXXXXX` provides uniqueness.
- Env exported into the tmux session: `RELAY_RUN_DIR`, `RELAY_SOCK`, `RELAY_STATE`,
  `RELAY_HANDOFF_PATH` (set per generation).
- **Lifecycle: created at launch; `rm -rf` on exit** via supervisor `trap EXIT`.
  Backstop for hard-kill: launch path prunes dirs whose `supervisor_pid` is dead.
  Handoffs are ephemeral (accepted tradeoff — inspect during the run, not after).

### `state.json`

```json
{
  "run_id": "run-20260713-Qx8fL2",
  "generation": 3,
  "supervisor_pid": 48211,
  "tmux_session": "relay-run-20260713-Qx8fL2",
  "policy": { "rotate_at_pct": 60, "max_gen": null, "max_runtime_s": null, "max_cost_usd": null },
  "rotation_pending": false,
  "pending_marker": null,
  "rotations": [ { "gen": 1, "at_pct": 61, "ts": "..." } ],
  "started_at": "..."
}
```

## 12. IPC

Transport: `nc -U $RELAY_SOCK` (hook side), with a timeout (`nc -w 5`, or
`timeout 5 nc -U` fallback if this build's netcat mishandles `-w` on unix
sockets). Supervisor accepts one JSON request, returns one JSON line.

- **Request (Stop hook → supervisor):** the raw Stop payload verbatim
  (`{ hook_event_name, session_id, transcript_path, stop_hook_active }`).
- **Response — continue:** `{}` (hook prints nothing, exit 0, Claude stops/idles).
- **Response — rotate:** `{ "decision":"block", "reason":"<two-tier handoff
  instruction with gen-N paths>" }`.

**Decision logic:**
```
if stop_hook_active == true: return {}                 # loop safety
pct = read $RELAY_STATE.context_window.used_percentage    # Source A
if pct empty OR mtime($RELAY_STATE) > 90s old: pct = parse_transcript(transcript_path)  # B
if rotation_pending: return {}                         # already rotating
if pct >= rotate_at_pct: set pending; return block-with-instruction
return {}
```

## 13. CLI surface

Invocation: `relay [relay flags] -- [claude args passed verbatim]`. The `--`
separator makes relay flags collision-proof against any claude flag.

| Flag | Default | Meaning |
|---|---|---|
| `--rotate-at <pct>` | **60** | Rotate when context ≥ this %. |
| `--max-gen <n>` | none | Cap: stop after N generations. |
| `--max-runtime <dur>` | none | Cap: stop after wall-clock (e.g. `8h`, `90m`). |
| `--max-cost <usd>` | none | Cap: stop after cumulative cost (statusline `.cost.total_cost_usd`). API-cost mode only; no-op in subscription mode. |
| `--no-auto-continue` | off | Load handoff, wait for user (default auto-continues). |
| `--marker-timeout <s>` | 120 | Handoff wait before ROTATE_FAILED. |
| `--attach <run_id>` | — | Attach to a run (id REQUIRED). |
| `--stop <run_id>` | — | Stop a run (id REQUIRED); deletes run dir on teardown. |
| `--status <run_id>` | — | Print a run's state (id REQUIRED). |
| `--list` | — | The ONLY discovery command; table of live runs. |

- Subcommands ALWAYS require an explicit `<run_id>` (no auto-detect — no ambiguity,
  no wrong-run actions). `<run_id>` accepts unique prefixes (like git short hashes).
- Startup prints the run_id prominently with the attach command.
- `--list` scans run dirs, filters to live `supervisor_pid` (dead dirs are pruned).

Bare `relay` = `--rotate-at 60`, no caps, auto-continue on, no extra claude args.

## 14. Error handling

| Failure | Detection | Handling |
|---|---|---|
| Supervisor absent/hung at hook time | `nc -w 5` + `[ -S $RELAY_SOCK ]` fast-path | Hook exit 0 → unsupervised behavior. No hang. |
| No marker after rotate instruction | `--marker-timeout` in ROTATION_PENDING | ROTATE_FAILED; default log + clear pending + stay RUNNING. |
| Empty/garbage handoff | Not detected (non-goal) | Accepted; two-tier instruction is the mitigation. |
| Supervisor crash | `trap EXIT` rm; hard-kill → startup prune | Degrades to unsupervised; dir cleaned next launch. |
| Nested tmux (`$TMUX` set) | env check | Warn; `switch-client` not `attach`; distinct session name. |
| `nc -U -w` unsupported | build-time check | `timeout 5 nc -U` fallback. |
| Env vars don't reach hooks | **MUST-VERIFY (spike)** | Fallback: write run_id into plugin settings at launch / derive from cwd. |
| Kill races user exit | `rotation_pending` flag | Flag is truth, not timing. |
| Stale/duplicate marker | per-gen dirs + await-specific-marker | Inert outside its ROTATION_PENDING window. |
| Cap hit mid-rotation | checked at ROTATING→launch | STOPPED instead of relaunch. |

## 15. Must-verify-before-build (spikes)

Risky assumptions quarantined as throwaway proofs before real implementation:

1. **Env propagation to hooks + statusline** inside a tmux-launched `claude` (the
   linchpin — the whole per-run wiring depends on `RELAY_*` reaching subprocesses).
2. **`nc -U -w` behavior** on this box's netcat (fallback: `timeout … nc`).
3. **Interactive Stop-allow does NOT exit `claude`** (guide flagged as inferred,
   not documented) — confirm it returns to idle so the kill-from-supervisor model
   holds.
4. **SessionStart stdout injection lands in interactive mode** (not just `-p`).

## 16. Test strategy

- **Tier 1 — spikes (manual, pre-build):** the 4 must-verifies, each a tiny
  standalone test.
- **Tier 2 — unit (scripted, no real Claude):** policy engine (synthetic state →
  decision); telemetry (sample statusline JSON + transcript → %); marker/state
  machine (simulate appear/timeout → transitions); discovery/`--list` (fake live +
  dead dirs → filter + prune); hook no-op (`$RELAY_SOCK` unset → exit 0, empty).
- **Tier 3 — integration (real `claude -p`, headless):** low `--rotate-at` (~5%) to
  force a fast rotation; assert generation increments, handoff written, marker
  honored, gen N+1 gets injected context.
- **Tier 4 — interactive smoke (manual):** real `relay` session; attach; watch a
  live rotation; test `--list/--attach/--stop`; test early-exit-stops-run.

**Build order:** spikes → supervisor+policy+telemetry → plugin hooks →
wrapper/tmux/subcommands → integration → smoke.

## 17. Non-goals (unchanged from proposal)

The supervisor does NOT: understand the task, understand repo semantics, make
engineering decisions, inspect/evaluate handoff quality, or decide implementation
strategy. Those belong to Claude.

## 18. Deliberately out of scope (YAGNI)

No config file; no completion-detection/promise tags (cap-only + manual stop); no
crash-recovery (`--restart-on-crash` is future work); no per-project policy
profiles; no Codex/Gemini adapter (seam only). No run-dir sweeper daemon (trap +
startup prune suffice).

## 19. Environment (verified present)

tmux 3.4, jq, nc at `/usr/bin` on the target box. Target implementation: bash +
jq + tmux + nc (no compiled binary — matches the lightweight, hackable goal). A
small Python helper may be used for transcript JSONL parsing if bash+jq proves
awkward (decided at build time).
