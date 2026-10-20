# cc-subagent-deepseek

**Claude as the project manager, DeepSeek as the coders.** Claude Code (Opus/Fable/Sonnet) plans, writes briefs,
reviews and integrates. The coding goes to cheap worker agents (OpenCode running DeepSeek V4.1 Flash through a
LiteLLM gateway) in their own git worktrees. [herdr](https://github.com/herdrdev/herdr) runs every agent in a live
terminal pane you can watch or take over, and everything runs inside a
[dev-cli](https://github.com/duy0611/dev-cli) sandbox.

Each model runs in its own harness, so nothing is lost: Claude keeps all its Claude Code tools, and DeepSeek gets
OpenCode's. A small DeepSeek task costs about **$0.003**; Claude only spends tokens on planning and review.

```
dev-cli sandbox
└── herdr session
    ├── pane: Claude Code ── project manager (dispatch skill)
    │        │  dispatch.sh start / prompt / wait / integrate / finish
    ├── workspace t-auth  ── OpenCode · DeepSeek worker · worktree ds/t-auth
    ├── workspace t-tests ── OpenCode · DeepSeek worker · worktree ds/t-tests
    └── workspace t-fix   ── Claude Code · Sonnet/Haiku (escalation only)
```

## How a task flows

1. **Plan.** The PM splits the work into self-contained tasks with exact acceptance commands.
2. **Start.** `dispatch.sh start` creates a worktree (`ds/<id>`) and a herdr pane, then starts the worker in it.
3. **Brief.** The PM writes `.delegate/<id>/brief.md`: scope, requirements, acceptance commands, constraints.
4. **Work.** The worker implements, runs the tests, and writes `.delegate/<id>/result.json`.
5. **Review.** The PM reads the diff and re-runs the tests itself. If something is wrong, it sends feedback to the
   same worker (at most 2 rounds), then escalates to a Claude worker.
6. **Integrate.** `dispatch.sh integrate` commits on the task branch and fast-forwards (or rebases onto) the repo's
   branch. `finish` removes the worktree. `cost` logs tokens and dollars to `.delegate/ledger.jsonl`.

Workers never commit or push; only the PM integrates.

---

## Install (in a dev-cli sandbox)

### Prerequisites
- A dev-cli devcontainer with `claude`, `opencode` and `node` (the dev-cli image ships all three), plus `git`,
  `jq`, `curl` and `sudo`.
- A LiteLLM gateway that serves `deepseek-v4.1-flash` (and optionally the Claude models). The sandbox needs these
  environment variables, set for example as dev-cli workspace settings (`dev workspace set KEY SPEC`):

  | Variable | Used by | Purpose |
  |---|---|---|
  | `LITELLM_BASE_URL` | OpenCode | gateway URL, without `/v1` |
  | `LITELLM_API_KEY` | OpenCode | gateway key |
  | `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` | Claude Code | if Claude also goes through the gateway |
  | `OPENCODE_CONFIG_DIR`, `CLAUDE_CONFIG_DIR` | both | set by dev-cli to `/var/dev-state/...` (persistent) |

### Steps
```sh
git clone <this repo> ~/cc-subagent-deepseek      # any location works
cd ~/cc-subagent-deepseek
bin/setup-sandbox
```

`bin/setup-sandbox` is idempotent, so it's safe to re-run. It:
- installs the full `python3` (the dev-cli image only has `python3-minimal`, which herdr's Claude hook can't use);
- installs herdr 0.9.5 to `~/.local/bin`, using herdr's official installer, which checks the SHA-256;
- installs the OpenCode config `opencode/opencode.json` (LiteLLM provider, default model, prices for cost tracking)
  and the restricted worker agent `opencode/agents/worker.md` into `$OPENCODE_CONFIG_DIR`;
- installs herdr's OpenCode and Claude integrations, which report agent state to herdr.

It does **not** overwrite an existing `opencode.json`. Compare it with `opencode/opencode.json` if you already
have one.

Check that it works:
```sh
herdr --version                                   # herdr 0.9.5
opencode models | grep litellm/                   # litellm/deepseek-v4.1-flash, ...
opencode run --standalone -m litellm/deepseek-v4.1-flash "Reply with exactly: ok"
```
If `~/.local/bin` isn't on your `PATH`, add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile.

---

## Use

Open a terminal **inside the sandbox**. If you also run herdr on the host, use a plain terminal rather than a
host herdr pane, otherwise the two herdrs fight over `ctrl+b`.

```sh
herdr --session work                              # start (or attach to) a herdr session
# in the first pane:
cd ~/cc-subagent-deepseek
bin/pm /path/to/your/repo                         # Claude Code as the PM, for that repo
```

Then just describe the work, for example:

> Use the dispatch skill: add rate limiting to the API client (see issue #42). Split it into tasks, run independent
> ones in parallel, review everything, integrate, and log costs to the ledger.

Watch the workers appear as new workspaces in herdr's sidebar. Talk to the PM in its pane at any time.

### `bin/pm` options
```sh
bin/pm <repo> --model claude-sonnet-5-5           # cheaper PM
bin/pm <repo> --permission-mode auto              # PM in auto mode (no prompts for its own actions)
PM_SETTINGS=my-settings.json bin/pm <repo>        # different permission template (@ROOT@ / @HOME@ placeholders)
```
`bin/pm` doesn't touch your global Claude config. It loads the PM role (`pm-role.CLAUDE.md`) as an extra system
prompt and the permission allowlist from `proposed/settings.json`. To make the PM role permanent, copy
`pm-role.CLAUDE.md` into `~/.claude/CLAUDE.md` (or `$CLAUDE_CONFIG_DIR/CLAUDE.md`).

### Driving workers by hand
The PM uses `.claude/skills/dispatch/dispatch.sh`, and you can too (from a herdr pane, or with `HERDR_SESSION=<name>`):

```sh
D=.claude/skills/dispatch/dispatch.sh
$D start t-login ~/code/app                       # OpenCode + DeepSeek worker in worktree ds/t-login
$D start t-hard  ~/code/app --kind claude --model claude-sonnet-5-5   # Claude escalation worker
$D start t-safe  ~/code/app --approve manual      # every non-allowlisted command waits for approval
# write ~/.herdr/worktrees/app/ds-t-login/.delegate/t-login/brief.md  (template: .claude/skills/dispatch/brief-template.md)
$D prompt t-login                                 # "Read and execute .delegate/t-login/brief.md"
$D wait t-login                                   # finished | blocked | idle_without_result | timeout
$D read t-login                                   # see the worker's screen
$D approve t-login | $D reject t-login            # answer a permission prompt
$D cost t-login                                   # tokens + USD (OpenCode workers)
$D integrate t-login "Add login form"             # commit on ds/t-login, rebase if needed, fast-forward the repo
$D finish t-login                                 # stop the worker, remove the worktree (refuses to drop unmerged work)
```

### Permissions and safety
- **Workers auto-approve by default.** OpenCode runs with `--auto`, which approves everything that isn't
  explicitly denied, so the deny list in `opencode/agents/worker.md` is the guardrail. It blocks commit, push,
  reset, rebase, checkout, `rm -r`, `sudo`, `curl`, `wget`, `ssh`, and `npm install`/`publish`. Claude workers run
  in auto mode with `claude-worker/settings.json`.
- Use `--approve manual` for a repo you don't fully trust. The sandbox is the outer boundary: workers share the
  container's network and credentials.
- Worker code is sent to DeepSeek through your gateway. Decide per repo whether that's acceptable.

### Stop and clean up
- `ctrl+b q` detaches from herdr; agents keep running. `herdr session attach work` reattaches.
- `herdr session stop work` stops the session and every agent in it.
- `dispatch.sh finish <id> [--keep-branch|--discard]` cleans up a single task.

---

## Demo: build a Markdown converter from a spec

A realistic end-to-end run. `demo/mdx` is a small repo with a written spec (`SPEC.md`), an empty `src/index.js`
and 16 acceptance tests: byte-exact HTML fixtures for nested lists, blockquotes, code fences, links and emphasis,
heading slugs, a table of contents, and the CLI. The PM gets only the goal. It must plan the modules, run
DeepSeek workers in parallel, review, integrate, and write a report.

```sh
herdr --session demo
# in the first pane:
cd ~/cc-subagent-deepseek
demo/run                                          # resets /tmp/mdx-demo and starts the PM (Opus, auto mode)
PM_MODEL=claude-sonnet-5-5 demo/run               # or with a cheaper PM
```

Afterwards:
```sh
demo/run check                                    # tests, commits, cost ledger, PM's report
demo/run reset                                    # start over
```

`demo/.reference/` holds the private implementation that generated the expected fixtures. Don't show it to
the PM (its demo settings deny reading it).

For a quick single-task test, `bin/reset-demo` creates a tiny repo at `/tmp/h1-demo` instead.

---

## Repository layout

| Path | What it is |
|---|---|
| `bin/setup-sandbox` | one-time, idempotent sandbox setup |
| `bin/pm` | starts Claude Code as the PM for a repo |
| `bin/reset-demo` | creates the tiny `/tmp/h1-demo` test repo |
| `.claude/skills/dispatch/SKILL.md` | the PM's procedure (loaded by Claude Code as a skill) |
| `.claude/skills/dispatch/dispatch.sh` | herdr/git helper: start, prompt, wait, read, approve, cost, integrate, finish |
| `.claude/skills/dispatch/brief-template.md` | task brief template with the `result.json` contract |
| `pm-role.CLAUDE.md` | PM role instructions |
| `proposed/settings.json` | PM permission allowlist template |
| `opencode/opencode.json` | OpenCode LiteLLM provider, default model, model prices |
| `opencode/agents/worker.md` | restricted OpenCode worker agent (deny list) |
| `claude-worker/settings.json` | settings for Claude escalation workers |
| `demo/` | the mdx demo (`run`, seed repo, PM goal, PM settings) |
| `PLAN.md`, `H*-RESULTS.md` | design plan and the findings of each phase |

## Troubleshooting
- **`ctrl+b` doesn't reach the sandbox's herdr.** You're inside a host herdr: press `ctrl+b ctrl+b`, or set a
  different `prefix` in the sandbox's `~/.config/herdr/config.toml`.
- **OpenCode hangs, or ignores config changes.** Run `opencode service restart`. Workers always use `--standalone`.
- **A worker sits at a "Permission required" prompt.** That's a command outside its allowlist (with
  `--approve manual`). Run `dispatch.sh read <id>`, then `approve` or `reject`.
- **The PM gets permission prompts for its own commands.** Add rules to `proposed/settings.json` (or start the PM
  with `--permission-mode auto`).
- **`dispatch.sh cost` shows 0.** The model has no `cost` entry in `opencode.json`, or the worker is a Claude worker
  (check LiteLLM's spend logs instead).
- Known gaps and design notes: `H0-RESULTS.md`, `H1-RESULTS.md`, `H2-RESULTS.md`.
