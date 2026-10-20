# Task <id>: <one line>

## Context
<Why this task exists. Relevant architecture. Conventions to follow, with file paths to look at.>

## Scope
- Create/modify: <files>
- Do NOT touch: <files/dirs>

## Requirements
1. <testable requirement>
2. ...

## Acceptance
These commands must pass (run them from the repo root):
- `<command>`

## Constraints
- No new dependencies.
- Do not edit or delete existing tests; add new tests instead.
- Do not commit, push, or create branches.
- Stay inside this checkout.

## Finish
1. Run every Acceptance command.
2. Write `.delegate/<id>/result.json`:
   ```json
   {"status": "done|blocked|failed",
    "summary": "<what you did, 1-3 sentences>",
    "files_changed": ["<path>"],
    "acceptance": [{"cmd": "<command>", "exit": 0}],
    "assumptions": ["..."],
    "questions": ["..."]}
   ```
3. Stop. Reply only `DONE <id>`.
