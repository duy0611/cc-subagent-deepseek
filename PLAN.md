# Plan: Claude as project manager, DeepSeek workers, orchestrated with herdr in dev-cli sandboxes

**Goal.** Claude Code (Opus/Fable) is the project manager (PM). It plans, writes briefs, reviews and decides.
The coding and testing go to cheaper worker agents, by default OpenCode running DeepSeek V4.1 Flash through LiteLLM.
**herdr** starts, prompts, watches and reads every agent. **dev-cli** provides the sandbox the agents run in.
There's no custom wrapper or MCP server: the only glue is a Claude skill, agent configs and conventions.

This also solves the original problem. Each model runs inside its own harness (DeepSeek in OpenCode,
Claude in Claude Code), so no built-in tool is lost.

---

## 1. Building blocks (research summary)

### herdr (v0.9.5, Rust, Apache-2.0, https://github.com/herdrdev/herdr)
- A terminal workspace manager for coding agents. It has its own PTY layer and a headless server reached over a local
  socket; it doesn't use tmux. Agents run in real interactive panes that you can watch or take over at any time.
- Install: `mise use -g herdr`, `brew install herdr`, or `curl -fsSL https://herdr.dev/install.sh | sh`.
- **Orchestration commands** (JSON on stdout; JSON error on stderr with exit 1; bad syntax exits 2):
  ```sh
  herdr pane split --current --direction right --cwd "$DIR" --no-focus   # new shell pane → pane id
  herdr agent start <name> --kind opencode|claude|hermes|… --pane <id> [--timeout MS] -- <agent args>
  herdr agent prompt <name> "<text>" --wait --until done --until blocked --timeout <ms>
  herdr agent wait   <name> --until done|idle|blocked [--timeout MS]
  herdr agent read   <name> --source recent-unwrapped --lines 150
  herdr agent send-keys <name> enter|esc|…      # answer approval prompts
  herdr agent list | get <name> | explain <name> | rename | focus | attach [--takeover]
  herdr worktree create --cwd . --branch <branch> [--base REF] | open | remove
  herdr notification show "<title>" --body "…" --sound done|request
  ```
- **Agent states:** `idle`, `working`, `blocked`, `done`, `unknown`.
  - OpenCode (also Pi, Kimi, Kilo and a few others) **reports its state** through herdr's OpenCode integration, so it is reliable.
  - Claude Code, Codex and Hermes are judged by **screen detection** (regex manifests). A prompt herdr doesn't recognise can show as `idle`.
- `agent start` needs an existing shell pane and returns once the agent is ready (default timeout 30 s; max 300 s).
- `agent prompt --wait` follows state changes, not individual turns. Only prompt an agent when it's `idle` or `done`.
  A timeout doesn't prove nothing was sent, so read the screen before resending.
- herdr **never approves anything on its own**. It refuses to prompt an agent that's `blocked`. Approvals happen either through `send-keys`
  or through the agent's own permission config.
- Model and provider live in each agent's own config, or in args after `--`. herdr itself has no model config.
- It ships a **Claude skill** for exactly this pattern: `herdr --skill`, or `npx skills add herdrdev/herdr --skill herdr -g`.
- Integrations (`herdr integration install opencode|claude|hermes`) add state reporting and resume after a restart.
- Config: `~/.config/herdr/config.toml` (`[worktrees] directory`, `[server] headless_cols/rows`,
  `[session] resume_agents_on_restore`, `[ui.toast]`).
- There's no sandbox built in. For agents started through a sandbox wrapper, the `HERDR_AGENT=<kind>` hint helps detection.

### dev-cli (`dev`, Go, https://github.com/duy0611/dev-cli)
- Manages devcontainers, using the devcontainer CLI with Docker or Podman. **This environment is a dev-cli sandbox.**
- The image already has `claude`, `opencode` (`@opencode/cli`), `hermes`, node and gh. **It doesn't have herdr, mise, or the full python3** (only `python3-minimal`; H0 found this).
- Persistent state volume at `/var/dev-state`: `CLAUDE_CONFIG_DIR`, `OPENCODE_CONFIG_DIR=/var/dev-state/opencode`,
  `HERMES_HOME` and `GIT_CONFIG_GLOBAL` all live there.
- Secrets are stored as references, never values (`literal:`, `keychain:`, `op://…`), set with `dev workspace set KEY SPEC`
  and injected as env vars. That's how `LITELLM_BASE_URL` and `ANTHROPIC_AUTH_TOKEN` reach the container.
- Security modes:
  | mode | `.git` | Use for |
  |---|---|---|
  | `guarded` (default) | read-only, the agent can't commit | interactive work |
  | `unprotected` | writable | trusted automation that needs to commit |
  | `isolated` | the repo is copied into a volume; you pull branches back with `dev container fetch` | unattended or untrusted agents |
  - No mode restricts the network. Root and sudo work inside the container.
- Key commands: `dev container create NAME --folder PATH [--mode …]`, `start`, `shell`, `exec NAME -- CMD`,
  `start-agent NAME --agent claude|opencode|hermes [--agent-name X] [-- ARGS]`, `fetch`, `dev worktree create|list|remove`.
- It already calls herdr **on the host** (`herdr worktree open`, and `herdr agent rename` when `--agent-name` is given).
- Extension points: `.devcontainer/devcontainer.json` features and `postCreateCommand`, and `.devcontainer/agents.yaml`
  (plugins and MCP for claude, opencode and hermes).

### Models through LiteLLM (`$LITELLM_BASE_URL`)
- Worker: `litellm/deepseek-v4.1-flash`. At DeepSeek's list prices it's roughly $0.15 in and $0.60 out per 1M tokens, double at peak. Check your gateway's actual billing.
- Escalation workers: `litellm/claude-haiku-5-5` and `litellm/claude-sonnet-5-5`, run through OpenCode or Claude Code.
- PM: Claude Code on Opus/Fable, using the existing `ANTHROPIC_BASE_URL`.

### Best practices carried over (Anthropic's multi-agent write-up and existing delegation projects)
- Write specific, self-contained briefs: objective, scope, acceptance commands, constraints, report format.
- Return small results. The PM must not soak up worker transcripts.
- Verify the end state yourself (diff plus tests). The worker saying it's done is not verification.
- Delegate self-contained work that costs a lot of tokens. Do tiny or delicate edits directly.
- Parallelise only across independent modules, each in its own worktree.
- Never re-send a prompt whose delivery is uncertain. Read the screen first.

---

## 2. Architecture

### Layout 1: everything in one dev-cli sandbox (start here)
```
dev container "proj-pm" (mode: unprotected or guarded, see §5)
└── herdr server (headless, inside the container)
    ├── pane w1:p1  Claude Code  ← PM (Opus/Fable), herdr skill + /dispatch skill
    ├── pane w1:p2  OpenCode "ds-auth"   (litellm/deepseek-v4.1-flash) in worktree ds/auth
    ├── pane w1:p3  OpenCode "ds-tests"  (litellm/deepseek-v4.1-flash) in worktree ds/tests
    └── pane w1:p4  Claude Code "cl-fix" (litellm/claude-sonnet-5-5), escalation only
you: `dev container shell proj-pm` → `herdr` (attach and watch, or take over any pane)
```
Simple, and agents talk to each other through the herdr socket inside the container. The downside: workers share
the container's credentials and network.

### Layout 2: herdr on the host, one dev container per worker (stronger isolation, later)
```
host herdr
├── pane: PM (Claude Code), in its own dev container, or on the host
├── pane: `dev container start-agent w-auth  --agent opencode --agent-name w-auth`   (mode isolated)
└── pane: `dev container start-agent w-tests --agent opencode --agent-name w-tests`  (mode isolated)
results come back with: dev container fetch w-auth → branch → PM reviews and merges
```
dev-cli already names these panes in herdr. What still needs checking: herdr's detection of an agent inside
`dev container start-agent` (set `HERDR_AGENT=opencode`), and whether the PM can call the host's herdr from inside a container.

---

## 3. Conventions (they replace a wrapper)

**Task ID and paths:** `<id>` = `t-YYYYMMDD-NN`. Worktree branch `ds/<id>`. Task folder
`.delegate/<id>/` with `brief.md`, `result.json` and `review.md` (`.delegate/` is git-ignored).

**Brief** (the PM writes it to `.delegate/<id>/brief.md`, then prompts the worker with
"Read and execute .delegate/<id>/brief.md"):
```
# Task <id>: <one line>
## Context      – why; relevant architecture; conventions (link files)
## Scope        – files to create/modify; files NOT to touch
## Requirements – numbered, testable
## Acceptance   – exact commands that must pass
## Constraints  – no new deps / keep public API / do not edit or delete existing tests / do not commit
## Finish       – run the acceptance commands, then write .delegate/<id>/result.json:
                  {"status":"done|blocked|failed","summary":"…","files_changed":[…],
                   "acceptance":[{"cmd":"…","exit":0}],"assumptions":[…],"questions":[…]}
                  then stop.
```

**Result handling.** `herdr agent wait` only tells the PM when to look. The real result is
`result.json` plus `git diff` plus the PM running the acceptance commands itself. The PM reads the screen
(`agent read --lines ≤150`) only when the state is `blocked` or `unknown`, or `result.json` is missing.

---

## 4. Configuration to create

| File | Purpose |
|---|---|
| `/var/dev-state/opencode/opencode.json` | LiteLLM provider; default `model` and `small_model` = `litellm/deepseek-v4.1-flash` (as discussed) |
| `/var/dev-state/opencode/agents/worker.md` (or the project's `.opencode/agents/worker.md`) | Restricted worker agent (below) |
| `$HERMES_HOME/config.yaml` | LiteLLM endpoint for Hermes (optional, H2) |
| `~/.config/herdr/config.toml` | Worktree directory, headless size, toasts |
| `.claude/skills/herdr/` | The skill herdr ships (`herdr --skill`) |
| `.claude/skills/dispatch/SKILL.md` | Our PM procedure (§6) plus the brief template |
| `~/.claude/CLAUDE.md` or `/var/dev-state/claude/CLAUDE.md` | PM role and rules (§6) |
| `.claude/settings.json` | Allow `Bash(herdr:*)`, `Bash(git diff:*)`, `Bash(git worktree:*)`. I'll show it to you before applying it |
| `.devcontainer/devcontainer.json` (project) or a dev-cli PR | Install herdr (official installer, pinned 0.9.5) and the full `python3`; install the herdr integrations into `$OPENCODE_CONFIG_DIR` and `$CLAUDE_CONFIG_DIR` (the OpenCode installer ignores `OPENCODE_CONFIG_DIR`, so copy the files) |

**OpenCode worker agent** (deny by default, so `--auto`-style approval is safe enough):
```md
---
description: Implementation worker driven by a PM via herdr
mode: primary
model: litellm/deepseek-v4.1-flash
steps: 80
permission:
  "*": deny
  read: allow
  glob: allow
  grep: allow
  edit: allow
  lsp: allow
  external_directory: deny
  doom_loop: deny
  bash:
    "*": ask
    "git status*": allow
    "git diff*": allow
    "npm test*": allow
    "npm run lint*": allow
    "npx tsc*": allow
    "pytest*": allow
    "git commit*": deny
    "git push*": deny
    "rm -rf*": deny
    "curl*": deny
---
You are an implementation worker. A project manager gives you a brief file.
Do exactly what the brief says, stay within its Scope, never commit, never weaken tests.
Finish by writing the result.json described in the brief, then stop.
```
Anything in bash that isn't listed is `ask`. herdr then shows the worker as `blocked`, and the PM decides through `send-keys`.
That way you see the edge cases instead of having them auto-approved.

**Claude Code workers** (escalation): pre-trust worktree folders (herdr doesn't recognise the trust dialog), and note that workers inherit the PM's `CLAUDE_CONFIG_DIR` settings (for example auto mode), so always pass an explicit `--permission-mode`. Start with `-- --model claude-sonnet-5-5 --permission-mode acceptEdits` plus a
project Bash allowlist. Avoid `--dangerously-skip-permissions` except in an `isolated` container (Layout 2).

---

## 5. Picking the security mode

- Layout 1: the PM and workers share the container. Worktrees need git writes: `git worktree add` writes into `.git`.
  - `guarded` (read-only `.git`) will probably block `herdr worktree create`, so check this in H0. If it does, either
    use `unprotected` for trusted repos, or use `isolated` and pull the PM's branches back with `dev container fetch`.
- Layout 2: use `isolated` for each worker, so even a worker that goes wrong can only damage its own copy.
- Data governance: worker prompts send code to DeepSeek through LiteLLM. Decide per repo whether that's acceptable.

---

## 6. The PM procedure

**CLAUDE.md (PM role), kept short:**
```
## Role: project manager
You plan, write briefs, review and decide. Implementation work larger than ~30 lines
or touching several files is delegated with the /dispatch skill (herdr + OpenCode/DeepSeek).
Do it yourself only for tiny edits, delicate debugging, or after 2 failed worker rounds.
Never accept work without reading the diff and running the acceptance commands yourself.
Never send a prompt to an agent that isn't idle/done; read its screen first.
```

**`/dispatch` skill, step by step** (implemented in `.claude/skills/dispatch/`; herdr calls are wrapped by `dispatch.sh`, which adds an `integrate` step and a `finish` guard):
1. **Plan.** Split the work into independent tasks (at most 3 in parallel to start). Assign each an `<id>`.
2. **Isolate.** `herdr worktree create --cwd . --branch ds/<id>` → worktree path `$WT`.
3. **Brief.** Write `$WT/.delegate/<id>/brief.md` from the template.
4. **Spawn.**
   `P=$(herdr pane split --current --direction right --cwd "$WT" --no-focus | jq -r …)`
   (split with `--env 'OPENCODE_CONFIG_CONTENT={"default_agent":"worker"}'`)
   `herdr agent start <id> --kind opencode --pane "$P" -- --standalone`   ← `--standalone` is required (H0 gotcha 1–2)
5. **Prompt.** `herdr agent prompt <id> "Read and execute .delegate/<id>/brief.md" --wait --until idle --until done --until blocked --timeout 1800000`
   - **Settle check (H0 gotcha 3):** after any wait, sleep 3–5 s and run `agent get` again. The task is finished only when `idle`/`done` holds steadily **and** `result.json` exists. Otherwise wait again.
   - Use Bash `run_in_background` so the PM can dispatch several tasks and get a notification as each finishes.
6. **Handle the state:**
   - `blocked`: `herdr agent read <id> --lines 60` → approve (`send-keys enter`) or reject (`esc`) with a
     reason, then wait again. If the decision is risky, raise a herdr notification for you.
   - `done` or `idle`: go to review.
   - Timeout or `unknown`: `agent read`, then decide whether to nudge, abort or take over. Never re-send blindly.
7. **Review.** Read `result.json`, run `git -C $WT diff --stat`, then read the full diff. Re-run the acceptance commands. Check scope,
   design, that tests weren't weakened, and that no results are hard-coded.
8. **Iterate.** Send feedback to the **same** agent (`agent prompt <id> "Review feedback: …" --wait …`), up to 2 rounds.
   After that, escalate: OpenCode with `-m litellm/claude-sonnet-5-5`, or a Claude Code worker. As a last resort, the PM does it.
9. **Integrate.** Merge or cherry-pick `ds/<id>` into the working branch, run the full test suite, then
   `herdr worktree remove` and close the pane.
10. **Log.** Append to `.delegate/ledger.jsonl`: id, worker kind and model, rounds, accepted or rejected, reason, and cost if known.

---

## 7. Phased implementation

### H0: Feasibility in this sandbox ✅ DONE 2026-10-20, see H0-RESULTS.md
1. Write `/var/dev-state/opencode/opencode.json` (LiteLLM). Run `opencode models | grep litellm`. Run one smoke test:
   `opencode run -m litellm/deepseek-v4.1-flash "say hi"` in `/tmp/smoke` (a throwaway git repo).
2. `mise use -g herdr@0.9.5`. Start herdr headless in the Podman container and check that the socket and server work without a host TTY.
3. `herdr integration install opencode` (and `claude`).
4. In `/tmp/smoke`: `pane split` → `agent start t1 --kind opencode` → `agent prompt t1 "create hello.py, run it" --wait`
   → confirm the `done` state, and that `agent read` and the file both exist.
5. Check whether `herdr worktree create` works in the current dev-cli mode (§5).
6. Check that the `worker` agent's `ask` rule shows up as `blocked` in herdr, and that `send-keys` approves it.

**Exit:** the full lifecycle (spawn, prompt, block, approve, done, read, kill) works from a shell script.

### H1: PM setup in one sandbox ✅ DONE 2026-10-20, see H1-RESULTS.md
- Create the files in §4: worker agent, herdr skill, `/dispatch` skill, CLAUDE.md section, settings allowlist.
- Make herdr part of the sandbox: a `postCreateCommand` in the project's devcontainer for now.
- Dry run: the PM dispatches one real, small task from one of your repos while you watch in `herdr`.
- **Exit:** 5 real tasks of different sizes completed end to end, with the PM's interventions noted.

### H2: Parallel and hardening (1 day)
- 2–3 parallel workers in separate worktrees. The PM uses background waits and gets a notification for each.
- Tune the worker prompt, the brief template and the `bash` allowlist from what went wrong in H1.
- Add escalation workers (Claude Code `--kind claude` with Sonnet or Haiku through LiteLLM).
- Optional: try Hermes as a worker (`--kind hermes`, LiteLLM configured in `$HERMES_HOME`). It uses screen detection, so watch it closely.

### H3: Layout 2, isolated containers (optional, 1–2 days)
- Create worker containers with `dev container create w-<n> --folder … --mode isolated`.
- The PM spawns them with `dev container start-agent w-<n> --agent opencode --agent-name <id>` inside herdr panes on the host,
  with `HERDR_AGENT=opencode`.
- Results come back with `dev container fetch w-<n>`, followed by a review of the branch.
- Possible upstream contributions to dev-cli: herdr in the image, passing the `HERDR_AGENT` hint through, and a `start-agent` preset for the worker agent.

### H4: Measure and tune (ongoing)
- Track success rate, review rounds, how often the PM had to intervene, DeepSeek cost per task, and PM (Claude) usage per task.
- Route task types that keep failing to stronger workers, or keep them with the PM.

---

## 8. Risks and mitigations
| Risk | Mitigation |
|---|---|
| Screen detection misreads state (an unfamiliar prompt shows as `idle`) | Default to OpenCode (it reports its own state); read before every prompt; `herdr agent explain` to debug |
| `prompt --wait` satisfied by an earlier turn | One task per agent instance; prompt only when `idle` or `done` |
| Worker does something destructive | Deny-by-default worker permissions, worktrees, no commit or push, `isolated` mode for unattended runs |
| Worker games the tests | The brief forbids it; the PM reviews the test diff; the PM re-runs the tests itself |
| PM context fills up with screen text | `result.json` is the main channel; bounded `--lines`; review the diff stat before the full diff |
| `guarded` mode blocks worktrees | Checked in H0; use `unprotected` for trusted repos, or `isolated` plus `fetch` |
| Workers in one sandbox share credentials and network | Acceptable for trusted repos; otherwise Layout 2 |
| herdr 0.9.x changes quickly (about 400 open issues) | Pin the version; keep all herdr calls in the `/dispatch` skill |
| Code is sent to DeepSeek | Opt in per repo |

## 9. Open decisions
1. Layout 1 only, or plan for Layout 2 (isolated containers per worker) from the start?
2. Which dev-cli mode for the PM container: `unprotected` (simplest) or `isolated`?
3. Should herdr go into dev-cli's image upstream, or stay in each project's devcontainer for now?
4. Do you want Hermes in the worker pool now, or later?
