# H2 results: parallel workers, escalation, cost, sandbox setup (2026-10-20)

Demo repo `/tmp/h1-demo` (reset with `bin/reset-demo`). herdr session `h2`.

## Outcome ✅
| Item | Result |
|---|---|
| **Sandbox setup** (`bin/setup-sandbox`) | Idempotent. Installs the full python3 (fixes herdr's Claude hook), herdr 0.9.5 (checksum-verified), the OpenCode LiteLLM config with model prices, the worker agent, and the herdr integrations into `$OPENCODE_CONFIG_DIR`/`$CLAUDE_CONFIG_DIR`. A second run is a no-op |
| **Parallel workers** | 3 DeepSeek workers dispatched in about 15 s. All finished on the first round with **0 permission requests** (thanks to the H1 allowlist tuning). Reviewed, integrated one by one, 10/10 tests pass. Your interactive run (camelCase plus kebabCase in parallel) also passed |
| **Auto-rebase on integrate** | `integrate` rebases the task branch onto the repo's moved HEAD. On conflict it aborts cleanly (clean worktree, commit kept on `ds/<id>`). After a manual fix, re-running `integrate` with no message finishes it, and a no-op integrate is refused. All paths tested offline |
| **Per-task cost** (`dispatch.sh cost <id>`) | Adds up tokens and USD over the worker's OpenCode sessions. Model `cost` entries were added to `opencode.json` (DeepSeek at list price; Claude prices from Anthropic's price table). For sessions run before prices were configured, it estimates from tokens; the formula matches OpenCode's recorded cost exactly. **Measured: $0.0028–0.0035 per small DeepSeek task** (about 10k input + 1.5–2k output + 35k cache-read tokens, 8–9 steps) |
| **Claude escalation worker** (`--kind claude`) | Haiku 5.5 worker: no trust dialog, its own settings (`claude-worker/settings.json`, `acceptEdits`, not the PM's auto mode), `blocked` detected correctly, approve worked, 2 rounds (my review found a whitespace bug its own tests missed, and the feedback fixed it). `finish` removes the trust entry |

## Findings
1. **Claude Code folder trust is per exact path.** A trusted parent does not cover child worktrees.
   → `start --kind claude` adds the worktree to `.claude.json` (an in-place jq edit that keeps file mode 600), and `finish` removes it.
2. **Claude workers must not inherit the PM's user settings** (auto mode, hooks).
   → `--setting-sources project,local --settings claude-worker/settings.json --permission-mode acceptEdits`.
3. **Both worker kinds prompt for compound shell commands** (`npm test; echo "EXIT=$?"`). OpenCode and Claude both check
   each part. `echo`/`cat`/`head`/`wc` are now allowed in both. A Claude worker reads its settings at startup only.
   Claude also flags some expansions (`${PIPESTATUS[0]}`) for approval no matter what the allowlist says, so expect occasional approvals.
4. **OpenCode cost is recorded when each step runs.** Sessions from before the price config stay at $0, so `cost` estimates them.
   **OpenCode's `input` excludes cached tokens**, so cache reads are priced separately and not subtracted.
5. **OpenCode sessions are grouped under the main repo's project**, not the worktree. `cost` lists from the repo and matches the
   session's `directory`. Run `cost` **before** `finish`.
6. Worker quality (DeepSeek and Haiku) was good on small, well-specified tasks. The PM's own edge-case probes
   still found one real bug in 5 tasks, so **review by the PM is not optional**.

## Totals so far (all on `/tmp/h1-demo`)
| Phase | Tasks | Accepted | Rounds (avg) | Worker approvals |
|---|---|---|---|---|
| H1 | 3 | 3 | 1.3 | 5 |
| your interactive run | 2 | 2 | 1 | 0 |
| H2 | 4 | 4 | 1.25 | 3 (all on the Claude worker, before the allowlist fix) |

## Still open
- `guarded` dev-cli mode (read-only `.git`) on a real mounted repo, which needs a dev-cli container created that way.
- Layout 2 (herdr on the host, an isolated container per worker) is H3.
- Hermes as a worker (optional).
- Claude worker cost: comes from LiteLLM spend logs (not wired up).
- Install `pm-role.CLAUDE.md` and `proposed/settings.json` for real (you have tested them through `bin/pm`).

## Addendum: auto-approval by default (2026-10-20)
- `dispatch.sh start` now defaults to `--approve auto`. Use `--approve manual` to go back to PM-answered prompts.
  - **OpenCode:** `opencode --standalone --auto` approves everything not explicitly denied. No classifier, so the
    worker's **deny list is the only guardrail**. It now also covers `git reset/rebase/checkout/clean`, `rm -r`,
    `sudo`, `wget`, `ssh`, `npm publish` and `npm install`.
  - **Claude:** `--permission-mode auto` (`claude-worker/settings.json` `defaultMode: auto`). The classifier decides,
    and the deny list still applies.
- Live tests: harmless commands that aren't allowlisted ran with no prompt on both kinds. `curl` was rejected by the deny rule on
  both (OpenCode session record: `permission.rejected`). Under OpenCode, DeepSeek refused to even call `git commit`
  when asked explicitly, so that deny rule has not been exercised by a real call (it's configured like `curl*`, which was).
- Trade-off: auto mode removes PM round-trips. It does not make a worker safe in an untrusted repo, because
  OpenCode `--auto` will run anything not on the deny list. Use `--approve manual` or an isolated container (H3) for those.
