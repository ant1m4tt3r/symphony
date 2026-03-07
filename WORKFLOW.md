# Symphony Fork Workspace Workflow

This repository is the canonical Symphony harness fork. Agents running inside
issue workspaces cloned from this repo must follow this contract.

## Required startup sequence

1. Read the Linear issue prompt and this file.
2. If present, read `.symphony/pr-feedback.md` and `.symphony/linear-feedback.md`
   before new implementation.
3. Move issue state from `Backlog`/`Todo`/`Ready for Dev` to `In Progress`
   before starting implementation.
4. Create a dedicated issue branch before code edits.
   - Branch names must not contain `/`.
5. Keep a persistent branch scratchpad at
   `.symphony/scratchpads/<branch>.scratchpad.md`.
6. Keep one persistent Linear comment headed `## Codex Workpad` as the source of
   truth for plan, progress, acceptance criteria, and validation evidence.

## State and PR gates

- Lifecycle: `Backlog/Todo/Ready for Dev -> In Progress -> In Review -> Done`.
- Move to `In Review` only when a working PR exists:
  - open and non-draft,
  - targets `main`,
  - linked to the Linear issue,
  - branch has at least one commit for the issue.
- Move to `Done` only after the linked PR is merged.
- Never push directly to `main`; always use PR flow.

## Implementation and validation expectations

- Use `.codex/skills/pull`, `.codex/skills/commit`, and `.codex/skills/push`
  when those workflows apply.
- Run the `pull` skill before code edits and record merge/sync evidence in the
  workpad.
- For harness changes, run and record:
  - `./scripts/symphony/test-guards.sh`
  - `SYMPHONY_ENV_FILE=<temp-env> SYMPHONY_VALIDATE_ONLY=1 ./scripts/symphony/start.sh`
- Keep project-scoped docs and env examples current with script behavior.

## In Review expectations

- Fetch latest PR checks and discussion at the start of each review pass.
- Fetch latest Linear issue comments at the start of each review pass.
- Treat human reviewer comments as actionable guidance (including comments from
  issue assignee/PR author).
- If `SYMPHONY_ALLOW_AUTO_MERGE=1`, merge only after checks are green and
  review actions are resolved.
- If auto-merge is disabled, do not merge manually.

## References

- Harness runtime workflow template: `.symphony/WORKFLOW.template.md`
- Fork harness runbook: `docs/symphony.md`
