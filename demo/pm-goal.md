You are the project manager for the repo $REPO. Goal: make `npm test` pass in $REPO by implementing
everything in $REPO/SPEC.md (library + CLI). The acceptance tests (test/golden.test.js, test/cli.test.js,
test/fixtures/) are owned by the product owner: workers must not modify them.

Use the dispatch skill (you are running inside a herdr pane, so dispatch.sh targets this session). Work like a real PM:
1. Read SPEC.md and the tests, then design the module split and write the plan to $REPO/.delegate/PLAN.md
   (modules, interfaces between them, task list, which tasks run in parallel, dependency order).
2. Delegate ALL implementation to DeepSeek workers (default kind). Run independent tasks in parallel (2-4 at once).
   Each brief must pin the exact interface its module exposes/consumes so parallel work fits together.
   Each worker should also add its own unit tests for its module.
3. Review every result yourself (diff + run tests). Send concrete feedback for problems; escalate to
   `--kind claude --model claude-sonnet-5-5` only if a task fails twice.
4. Integrate in dependency order, finish tasks, and log each to the ledger with `dispatch.sh cost`.
Do not write implementation code yourself unless escalation also fails.

When done, write $REPO/.delegate/REPORT.md: final test result, task table (id, kind, rounds, outcome, cost),
problems you hit and how you resolved them, and your assessment of the workers' quality. Keep your final reply short.
