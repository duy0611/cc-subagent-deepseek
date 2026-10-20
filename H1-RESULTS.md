# H1 results: PM setup and real end-to-end tasks (2026-10-20)

Demo repo: `/tmp/h1-demo` (ESM JavaScript plus `node --test`). herdr session `h1`. Workers: OpenCode + `litellm/deepseek-v4.1-flash`.

## Deliverables (in this repo)
| File | What it is |
|---|---|
| `.claude/skills/dispatch/SKILL.md` | The PM procedure: plan, start, brief, prompt and wait, review, iterate or escalate, integrate, log |
| `.claude/skills/dispatch/dispatch.sh` | herdr helper: `start / prompt / wait / status / read / approve / reject / integrate / finish` |
| `.claude/skills/dispatch/brief-template.md` | Self-contained brief with a `result.json` contract |
| `opencode/agents/worker.md` | Restricted OpenCode worker agent (copy installed at `/var/dev-state/opencode/agents/worker.md`) |
| `pm-role.CLAUDE.md` | PM role section to paste into `~/.claude/CLAUDE.md` (not installed yet) |
| `proposed/settings.json` | Permission allowlist so a PM can run the flow without prompts (not installed yet) |

## Task log
| Task | Driven by | Rounds | Worker approvals | Outcome | Notes |
|---|---|---|---|---|---|
| t-slugify | me, as PM | 2 | 2 | ✅ accepted | Round 2 = review feedback (transliterate ß/ø/æ/đ/ł); fixed correctly in the same session |
| t-wordcount | me, as PM | 1 | 1 | ✅ accepted | Unicode-aware regex; held up against my extra edge cases |
| t-reversewords | **headless Claude Sonnet PM** using the skill | 1 | 2 | ✅ accepted | The PM briefed, approved, waited and reviewed on its own; it stopped correctly before integrating because it couldn't run the tests itself |

DeepSeek worker turnaround: about 10–80 s per round for these small tasks. Worker output quality was good:
it stayed in scope, didn't touch existing tests, matched the house style, and listed honest assumptions in `result.json`.
Headless PM cost (Sonnet 5.5): about $0.18 for a 20-turn dispatch-and-review.

## Issues found and fixed
1. **The PM lost work at cleanup (my scripting bug).** The `git add` pathspec `':!.delegate'` errors when `.delegate` is
   git-ignored, so nothing was committed. `finish` then force-removed the worktree, and the branch was deleted as "merged".
   The work was recovered from dangling git blobs and committed.
   → New `integrate` subcommand (commit plus fast-forward). `finish` now **refuses** if there are uncommitted changes
   or unmerged commits, unless given `--keep-branch` or `--discard`. Tested: it refused, then integrate and finish succeeded.
2. **`agent read` with scrollback fails while blocked** (`agent_not_idle`). → `read` falls back to `--source visible`.
3. **Worker permission prompts for harmless commands.** OpenCode matches each part of a compound command separately
   (`npm test 2>&1; echo …` asked because of `echo`, and `ls; cat …` because of `cat`).
   → Allowlisted `echo`, `cat`, `head`, `wc`, `npm run test*` and `node --test*`. Some approvals will always happen;
   that's by design, and the PM handles them.
4. **JSON robustness.** `dispatch.sh` now builds all of its JSON with `jq -n`. Separately, zsh's `echo` mangles `\\` in
   JSON, so the skill says to use `printf '%s'`.
5. **The PM's allow rule didn't match** because the model called the script by an absolute path or through `$D=`.
   → The skill now asks for a plain absolute-path call, and `proposed/settings.json` uses the absolute path.
6. **The PM couldn't run tests in worktrees** (`npm --prefix …` and `cd … && npm test` weren't allowed in the headless run).
   → Covered by `proposed/settings.json` (`npm --prefix`, `git -C`, Read/Write in `~/.herdr/worktrees`).
7. `sed -i` dropped the script's executable bit once. Watch for this when editing.

## Still open (H2 and later)
- Parallel workers (2–3 at once), and the PM using background waits.
- Escalation worker run end to end (`--kind claude`; trust dialog plus permission mode, see H0).
- `guarded` dev-cli mode on a real mounted repo (worktree creation writes to `.git`).
- Per-task cost: OpenCode reported no tokens or cost, so pull it from LiteLLM spend logs.
- Install herdr, the full python3, the integrations and the skill in the dev-cli image (or the project devcontainer).
- Hermes as a worker.
