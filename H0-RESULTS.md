# H0 results: feasibility in this dev-cli sandbox (2026-10-20)

Environment: dev-cli devcontainer (Podman, aarch64), OpenCode v2.0.32, Claude Code v2.1.303,
herdr 0.9.5 (installed with the official checksum-verified installer to `~/.local/bin`), LiteLLM gateway.

## Outcome: feasible ✅. The full lifecycle works from a shell script

| Check | Result |
|---|---|
| LiteLLM → `deepseek-v4.1-flash` (direct curl) | ✅ about 1 s round trip. The gateway also serves `deepseek-v4-pro`, `deepseek-v4.1-flash-priority`, `deepseek-v4-flash` and `deepseek-v3.2-maas` |
| OpenCode + LiteLLM config (`/var/dev-state/opencode/opencode.json`) | ✅ after `opencode service restart` (see gotcha 1) |
| herdr headless server inside the Podman container | ✅ `herdr --session h0 server` runs without a host TTY |
| `herdr agent start --kind opencode` | ✅ ready (`idle`) in a few seconds |
| `agent prompt --wait` → file created → `agent read` returns the transcript | ✅ about 20 s for a small task |
| OpenCode state reported by the herdr plugin (no screen scraping) | ✅ `agent explain` → `full_lifecycle_hook_authority` |
| Worker agent `ask` rule → herdr `blocked` → `send-keys enter` approves | ✅ |
| Worker agent `deny` rule (`git commit*`) | ✅ refused, no commit created |
| `herdr worktree create` → worktree plus its own herdr workspace | ✅ under `~/.herdr/worktrees/<repo>/<branch-slug>` |
| `herdr agent start --kind claude -- --model claude-haiku-5-5` (escalation worker) | ✅ after the trust dialog (see gotcha 5) |

## Gotchas found (they change the plan)

1. **The shared OpenCode background service.** Plain `opencode` and `opencode run` connect to a shared
   `opencode serve --service` process. It (a) had to be restarted to pick up the new config, and (b) **ignores
   per-pane env, cwd config and `OPENCODE_CONFIG_CONTENT`**.
   → **Always start workers with `--standalone`.** Each worker then gets its own private server and honours its pane's env.
2. **The interactive `opencode` has no `--agent` flag** (only `opencode run` does).
   → Select the worker agent per pane: `herdr pane split … --env 'OPENCODE_CONFIG_CONTENT={"default_agent":"worker"}'`
   plus `agent start … -- --standalone`. Confirmed: the UI shows "Worker · DeepSeek 4.1 Flash".
3. **`agent prompt --wait` can return `idle` too early.** It settles on a brief idle between model steps,
   before the permission request appears. A plain `agent wait` can also return a stale `blocked` straight after `send-keys`.
   → In `/dispatch`: after any wait, **sleep about 3–5 s and run `agent get` again**. Only treat the task as finished when
   `idle` or `done` holds steadily **and** `.delegate/<id>/result.json` exists. Use explicit `--until idle --until done --until blocked`.
4. **The image has only `python3-minimal` (no `json` module).** herdr's Claude `SessionStart` hook prints a traceback
   (non-blocking), so Claude-session resume through herdr won't work. Python-based tooling in general is affected.
   → Add the full `python3` package to the dev-cli image.
5. **The Claude Code folder-trust dialog isn't recognised by herdr.** `agent start` times out with no name assigned,
   then the pane shows `blocked`. Keys sent too quickly together (`down enter`) were lost.
   → Pre-trust worker directories (or the worktree root) in Claude's config, or send keys one at a time with pauses.
   Also: a Claude worker **inherits the PM's settings (here: auto mode)** from the shared `CLAUDE_CONFIG_DIR`.
   Give Claude workers an explicit `--permission-mode` and/or their own settings file.
6. **`herdr integration install opencode` ignores `OPENCODE_CONFIG_DIR`** (it looks for `~/.config/opencode`).
   → It was installed into a scratch HOME and copied into `/var/dev-state/opencode/` (`plugins/herdr-agent-state.js`,
   `herdr-tui-session.js`, `herdr-opencode/`, `tui.jsonc`, `cli.json`). This should be automated in the image setup.
7. **mise isn't in this image** (the research said it was). herdr was installed with its own installer instead.
8. **The run JSON had no token or cost data** (`opencode run --format json` printed no `step_finish` event). Cost
   tracking per task needs another source: LiteLLM spend logs, or the OpenCode session API.
9. zsh doesn't split words in `$VAR`, so use a shell function (`h(){ herdr --session X "$@"; }`) in scripts.
10. My mistake during the test: I picked "the last pane in the list" and sent keys to the wrong agent.
   → Always target **agent names**, never list positions.

## Not tested yet
- `guarded` mode (read-only `.git`) against a real mounted repo. `/workspaces/...` isn't a git repo here, and
  `/tmp/smoke` is a local repo. Retest in H1 on a real project.
- Hermes as a worker.
- Several workers in parallel.

## Changes made to this environment
- `~/.local/bin/herdr` (0.9.5); herdr session `h0` (stopped).
- `/var/dev-state/opencode/opencode.json` (LiteLLM provider, default model DeepSeek V4.1 Flash).
- `/var/dev-state/opencode/agents/worker.md` (restricted worker agent).
- herdr OpenCode plugin files in `/var/dev-state/opencode/`.
- herdr Claude integration: `/var/dev-state/claude/hooks/herdr-agent-state.sh` plus one `SessionStart` hook in
  `/var/dev-state/claude/settings.json`. It exits immediately outside herdr; remove it if unwanted.
- `/tmp/smoke` throwaway repo, trusted in Claude's config.
