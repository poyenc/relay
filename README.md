# relay

Run Claude Code as a long-lived, **self-rotating** session.

`relay` hosts `claude` inside tmux and watches its context usage. When context
crosses a threshold, it makes the agent write a handoff, replaces the session
with a fresh one, and injects the handoff — so work continues in un-degraded
context indefinitely, until you stop it or a cap is hit.

The name evokes a relay race: each generation hands the baton to a fresh runner
and the run continues.

## How it works

- A **supervisor** daemon owns the run: it reads context %, decides when to
  rotate, and drives the handoff → settle → graceful-exit → relaunch cycle.
  Teardown is always **pane-scoped**: it sends `/exit` so Claude runs its own
  shutdown (SessionEnd hook, transcript flush), waits up to `--exit-timeout`,
  then replaces the pane (rotation) or kills just that pane (stop) — never the
  tmux session, so your other panes/windows are untouched. Ended runs persist
  under `/tmp/relay-<user>/` for 7 days for post-mortem.
- A bundled **Claude plugin** (loaded per-session via `--plugin-dir`, nothing
  installed globally) contributes two hooks:
  - a **Stop** hook that asks the supervisor "rotate or continue?" when the
    agent goes idle, and
  - a **SessionStart** hook that injects the prior generation's handoff into the
    fresh session.
- Context % comes from your **statusline** (authoritative — it's Claude's own
  `context_window.used_percentage`), with transcript-token parsing as a fallback.

Plain `claude` is untouched: the hooks no-op unless a supervisor is present, and
there is nothing to uninstall.

## Requirements

- `bash`, `jq`, `tmux`
- `claude` (Claude Code CLI) on your `PATH`

## Install

`relay` is a directory of bash scripts — no build, no compile. Copy the project
somewhere stable and put its `bin/` on your `PATH`.

```bash
# copy the project somewhere permanent (run from inside the repo)
cp -r . ~/.local/share/relay

# add its bin/ to PATH (append to ~/.bashrc or ~/.zshrc to make it permanent)
export PATH="$HOME/.local/share/relay/bin:$PATH"

# verify
relay --help
```

The `relay` launcher finds the plugin and supervisor relative to its own
location, so the directory can live anywhere as long as its internal layout
(`bin/`, `hooks/`, `lib/`, `.claude-plugin/`) is intact.

## Statusline patch (recommended)

`relay` reads the authoritative context % from a small **tee** added to your
statusline command. Without it, `relay` falls back to parsing transcript tokens
against a default 200k window — correct in the common case, but the tee is exact
and model-aware.

If you have a statusline script (the `statusLine.command` in your Claude
settings, e.g. `~/.claude/statusline.sh`), install the tee:

```bash
relay --install-statusline ~/.claude/statusline.sh
```

This is **idempotent**, **no-op-safe**, and **backs up the original** to
`<file>.relay-bak`. It inserts a block that captures the statusline JSON, writes
it atomically to `$RELAY_STATE` when that variable is set (i.e. inside a `relay`
session), and re-feeds the byte-identical input to your script. Outside a
`relay` session `$RELAY_STATE` is unset and the block does nothing — your
statusline behaves exactly as before.

> If you don't have a statusline script, you can skip this — `relay` uses the
> transcript fallback. To adopt one later, point `statusLine.command` at a
> script and run the install command above.

## Usage

```bash
relay [relay flags] -- [claude args passed verbatim to claude]
```

The `--` separates relay's own flags from arguments handed straight to `claude`,
so they can never collide.

```bash
# simplest: rotate at 60% (default), auto-continue after each rotation
relay -- -p "refactor the auth module and add tests"

# rotate earlier, cap the run, pass a model through to claude
relay --rotate-at 50 --max-gen 8 --max-runtime 4h -- --model opus

# load the handoff into the fresh session but wait for you to type
relay --no-auto-continue -- "start on the migration"
```

When a run starts it prints the `run_id` and the attach/stop commands.

### Launch flags

| Flag | Default | Meaning |
|---|---|---|
| `--rotate-at <pct>` | `60` | Rotate when context ≥ this %. |
| `--max-gen <n>` | none | Cap: stop after N generations. |
| `--max-runtime <dur>` | none | Cap: stop after wall-clock (`30s`, `90m`, `8h`, `2d`). |
| `--max-cost <usd>` | none | Cap: stop after cumulative cost (API-cost mode only). |
| `--no-auto-continue` | off | Load handoff and wait, instead of auto-continuing. |
| `--rotation-timeout <dur>` | `120s` | Wait for the outgoing generation to hand off and settle (its post-handoff Stop) before giving up on a rotation. On timeout, a written handoff still rotates; otherwise the attempt is abandoned and retried on the next Stop. |
| `--rotate-grace <dur>` | `2s` | Pause before teardown so the outgoing agent's final message stays readable. |
| `--exit-timeout <dur>` | `5s` | Wait for a clean `/exit` before force-killing the pane. |
| `--switch` | off | When nested in tmux (e.g. byobu), switch the client to the new session on launch. Default: stay put and print the attach command. |

### Subcommands

Each takes an explicit `<run_id>` (a unique prefix works, like a git short
hash):

| Command | Meaning |
|---|---|
| `relay --list` | Table of live runs (the only discovery command). |
| `relay --attach <run_id>` | Attach your terminal to a run. |
| `relay --stop <run_id>` | Stop a run and tear down its run dir. |
| `relay --status <run_id>` | Print a run's `state.json`. |
| `relay --install-statusline <file>` | Install the statusline tee (see above). |

Detach from an attached run the normal tmux way (`Ctrl-b d`) — the run keeps
going in the background; re-attach with `relay --attach`.

## Run state

Each run lives under `${TMPDIR:-/tmp}/relay-$(id -un)/YYMMDD-HHMMSS-XXXXXX/`
(per-user, mode `700`). It holds `state.json`, the supervisor log, per-generation
handoffs, and a captured `pane.log` per generation. Ended run dirs **persist for
post-mortem** and are pruned only after 7 days; a live run's dir is never pruned.

## Tests

```bash
bash tests/run-all.sh
```

Runs the full suite (unit + a headless end-to-end test that uses real
`claude -p`, which auto-skips if `claude` is absent).
