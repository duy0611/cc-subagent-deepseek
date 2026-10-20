---
name: dispatch
description: Delegate implementation tasks to cheaper worker agents (OpenCode + DeepSeek V4.1 Flash via LiteLLM, or Claude Haiku/Sonnet for escalation) running in herdr panes, then review and integrate their work. Use for implementation work larger than ~30 lines or touching several files, once the plan is settled.
---

# Dispatch: delegate implementation to herdr workers

You are the project manager. Workers implement; you plan, brief, review and integrate.
All herdr calls go through the helper `dispatch.sh` in this skill's directory, so use it rather than
raw `herdr` commands. It handles the known pitfalls (OpenCode must run `--standalone`; waits can settle on a
transient idle; agents are targeted by name only).

Call it by its **absolute path, as a plain command**: no `D=` variable, no `cd … &&` prefix, one command per Bash call.
That way the permission allow rule for the script matches, and the user isn't prompted for every step.
Below, `$D` stands for that absolute path (`<this checkout>/.claude/skills/dispatch/dispatch.sh`; `bin/pm` starts you in the checkout, so use `$PWD/.claude/skills/dispatch/dispatch.sh` resolved to its full path).

When piping its JSON to jq, use `printf '%s\n' "$out"`, not `echo` (zsh's echo mangles backslashes).

Requires herdr on PATH and a running herdr server. Outside herdr (`HERDR_ENV` unset) set `HERDR_SESSION=<name>`.

## 1. Plan
- Split the work into self-contained tasks with clear acceptance commands. Start with at most 3 in parallel,
  and only parallelise tasks that touch different files.
- Task ids: `t-<short-slug>`, matching `[a-z][a-z0-9_-]{0,31}` (for example `t-slugify`).
- The worktree branches from the repo's **committed HEAD**. Commit anything the worker needs first.

## 2. Start the worker
```bash
$D start <id> <repo>                                     # OpenCode + DeepSeek (default)
$D start <id> <repo> --kind opencode --model litellm/claude-sonnet-5-5   # escalation, same harness
$D start <id> <repo> --kind claude --model claude-sonnet-5-5             # escalation, Claude Code
                                                                         # (own settings from claude-worker/settings.json,
                                                                         #  worktree pre-trusted; cost not tracked)
```
Workers start with **auto-approval** by default (`--approve auto`). OpenCode runs with `--auto`, which approves
everything not explicitly denied, so the deny rules in its `worker` agent are the guardrail. Claude runs in auto mode,
where its classifier decides. Add `--approve manual` for sensitive repos: every non-allowlisted command then
comes to you as `blocked`.

It prints JSON with `worktree` (the checkout path), `branch` (`ds/<id>`) and `agent_status`. If the agent wasn't
detected (a startup dialog), run `$D read <id>` and decide.

## 3. Write the brief
Write `<worktree>/.delegate/<id>/brief.md` from `brief-template.md` in this skill's directory. Make it
self-contained: the worker doesn't see this conversation. Name exact files, testable requirements and exact
acceptance commands.

## 4. Prompt and wait
```bash
$D prompt <id>                 # sends "Read and execute .delegate/<id>/brief.md"
$D wait <id> 1800              # run with Bash run_in_background for long tasks
```
`wait` returns one JSON line with `state`:
- `finished`: `result.json` exists. Go to review.
- `blocked`: the worker is asking permission. Run `$D read <id> 40`, then `$D approve <id>` if the command is
  safe and in scope, or `$D reject <id>`. Then `wait` again. If you're unsure, ask the user.
- `idle_without_result`: the worker stopped without finishing. Read the screen and nudge with `$D prompt <id> "<instruction>"`.
- `timeout` or `agent_gone`: read the screen, then decide. **Never re-send a prompt blindly.**

## 5. Review (always, even when the worker reports success)
1. Read `result.json`. Then `git -C <worktree> status --short` and `git -C <worktree> diff`
   (include untracked files: `git -C <worktree> add -N . && git -C <worktree> diff`).
2. Run the acceptance commands yourself in the worktree.
3. Check: the work stays in scope; existing tests aren't weakened or deleted; no hard-coded results; the code is sound.

## 6. Iterate or escalate
- Problems: `$D prompt <id> "Review feedback: <specific issues>. Fix them, re-run acceptance, rewrite result.json."`,
  delete the old `result.json` first, then `wait`. At most 2 feedback rounds.
- Still failing: `finish` the task with `--keep-branch` for reference, then start a new one with a stronger model.
  As a last resort, do it yourself.

## 7. Integrate and clean up
```bash
$D integrate <id> "<commit message>"   # commits the worker's changes on ds/<id>, fast-forwards <repo>'s HEAD
# run the full test suite in <repo>
$D finish <id>                         # stops the agent, removes worktree+workspace and the merged branch
```
Commits are made by you (the PM), never by the worker. `finish` refuses to throw away uncommitted or unmerged
work. Use `--keep-branch` to keep a rejected attempt for reference, and use `--discard` only when you mean to drop the work.
If `<repo>` moved on (parallel tasks), `integrate` rebases `ds/<id>` onto it automatically. On a conflict it aborts the
rebase and leaves the commit on `ds/<id>`: resolve it in the worktree (`git rebase <branch>`, fix, `git rebase --continue`),
then re-run `$D integrate <id>` (no message needed). Integrate parallel tasks **one at a time**.

## 8. Log
Run `$D cost <id>` **before** `finish` (it reads the worker's sessions), then append one line to `<repo>/.delegate/ledger.jsonl` (`mkdir -p <repo>/.delegate` first):
`{"id","date","kind","model","rounds","approvals","outcome":"accepted|rejected|escalated","cost_usd","notes"}`.
