# Task 0 Spike Findings

## (a) IPC transport: OpenBSD nc has no server mode

The `nc` on this system is OpenBSD netcat, which does not support `-l` server/listen
mode the way GNU netcat does. This was already known going in (not re-verified here
as a live spike, per the brief). **Decision: file-based IPC is chosen** for relay's
inter-process communication instead of a netcat socket relay.

## (b) Env propagation to hooks — PASS (linchpin result)

Command run:
```bash
chmod +x relay/tests/spikes/spike-env/dump-env.sh
rm -f /tmp/relay-spike-env.txt
RELAY_RUN_DIR=/tmp/relay-spike-run RELAY_STATE=/tmp/relay-spike-run/statusline.json \
  claude -p "say hi" --plugin-dir relay/tests/spikes/spike-env >/dev/null 2>&1
cat /tmp/relay-spike-env.txt
```

Actual observed output of `/tmp/relay-spike-env.txt`:
```
RELAY_RUN_DIR=/tmp/relay-spike-run
RELAY_STATE=/tmp/relay-spike-run/statusline.json
CLAUDE_PLUGIN_ROOT=/home/AMD/poyechen/workspace/repo/supervised-claude/relay/tests/spikes/spike-env
```

Environment variables set on the parent `claude -p` process **do** propagate down
into the `Stop` hook's command environment. `RELAY_RUN_DIR` and `RELAY_STATE` were
NOT `UNSET`, and `CLAUDE_PLUGIN_ROOT` resolved to the correct absolute path of the
spike plugin directory. This is the linchpin assumption for the relay design and it
holds — no fallback (baking run_id into the plugin, or deriving from `cwd`) is
needed.

## (c) SessionStart stdout injection — PASS

Command run:
```bash
claude -p "What secret word were you told at session start? Answer in one word." \
  --plugin-dir relay/tests/spikes/spike-ss 2>/dev/null
```

Actual observed stdout:
```
kumquat
```

The model's reply was exactly `kumquat`, confirming that stdout printed by a
`SessionStart` hook is injected into context and reaches the model, at least in
headless `-p` mode. This was only tested in `-p` (headless) mode; whether the same
injection behavior holds in interactive mode is **not verified here** and is
deferred to the Plan 2 smoke test.

## (d) Stop-allow-does-not-exit-interactive — deferred

The known behavior is that in interactive sessions, a `Stop` hook returning "allow"
does not necessarily cause the CLI process to exit. This spike does not depend on
that behavior: headless `-p` mode exits regardless of Stop hook decisions once the
turn completes. Verifying Stop-hook exit semantics in interactive mode is deferred
to the Plan 2 smoke test; Plan 1 (the scope covered by these spikes and immediate
subsequent tasks) does not rely on it.
