# Guardrail Troubleshooting

This guide documents the blocked-command messages that Symphony's workflow guardrails produce, explains why each guardrail exists, and describes the recovery path when you encounter one.

## Why manual-only merges?

Symphony agents never merge PRs automatically. All merges go through a human maintainer who moves the issue to `Merging` in Linear, which triggers the `land` skill. This policy exists for three reasons:

1. **Human accountability** -- A merged PR changes shared state for every contributor. A human reviewer confirming the merge ensures that intent, scope, and quality have been validated by someone who can weigh context the agent cannot see (release timing, downstream consumers, related in-flight work).
2. **Irreversibility** -- Unlike most agent actions (editing files, pushing branches), a merge to `main` is hard to reverse cleanly. Requiring human approval before this step limits blast radius.
3. **Audit trail** -- The Linear state machine (`Human Review` -> `Merging` -> `Done`) creates a clear record of who approved the change and when, separate from the agent's execution log.

The `land` skill itself calls `gh pr merge --squash`, but only after a human has moved the issue to `Merging`. The agent is explicitly prohibited from calling `gh pr merge` directly outside this flow.

## Blocked command messages and recovery

### "Do not call `gh pr merge` directly"

**When:** The agent attempts to merge a PR outside the `land` skill flow.

**Message:** The workflow instructs: *"do not call `gh pr merge` directly"* and *"execute the `land` skill flow"*.

**Why:** Merging is gated on human approval via the `Merging` state. Bypassing the `land` skill skips the conflict-check, CI-watch, and review-acknowledgment loop that the skill enforces.

**Recovery:** Wait for a human maintainer to move the issue to `Merging` in Linear. The agent then opens `.codex/skills/land/SKILL.md` and follows its loop (resolve conflicts, watch CI, squash-merge).

---

### "Do not move to `Human Review` unless the Completion bar is satisfied"

**When:** The agent tries to transition an issue to `Human Review` before all acceptance criteria, validation, PR checks, and feedback sweeps are complete.

**Message:** The workflow's *"Completion bar before Human Review"* section lists required gates.

**Why:** Moving to `Human Review` signals to the human maintainer that the work is ready for review. Premature transitions waste reviewer time and erode trust in agent-produced PRs.

**Recovery:** Check the workpad against the completion bar:
- Step 1/2 checklist is fully complete.
- Acceptance criteria and ticket-provided validation items pass.
- PR feedback sweep is complete (no actionable comments remain).
- PR checks are green and the `symphony` label is applied.
- Branch is pushed and PR is linked on the issue.

Address any gaps, then retry the transition.

---

### "If the branch PR is already closed/merged, do not reuse that branch"

**When:** The agent detects that the PR associated with the current branch is `CLOSED` or `MERGED`.

**Message:** *"treat prior branch work as non-reusable for this run"* and *"create a fresh branch from `origin/main`"*.

**Why:** Reusing a branch tied to a closed/merged PR risks pushing to a stale ref, creating confusing PR history, or conflicting with already-landed changes.

**Recovery:** Create a new branch from `origin/main` and restart the execution flow from planning/reproduction. Do not attempt to reopen the old PR.

---

### "Do not edit the issue body/description for planning or progress tracking"

**When:** The agent attempts to modify the Linear issue description.

**Message:** *"Do not edit the issue body/description for planning or progress tracking."*

**Why:** The issue description is owned by the human who filed the ticket. Agent progress belongs in the `## Codex Workpad` comment, which is clearly separated from the original scope definition.

**Recovery:** Use the single persistent `## Codex Workpad` comment for all planning, checklists, and progress updates.

---

### "Use exactly one persistent workpad comment per issue"

**When:** The agent creates multiple workpad comments or posts separate status updates.

**Message:** *"Use exactly one persistent workpad comment (`## Codex Workpad`) per issue."*

**Why:** Multiple comments fragment the execution record and make it harder for reviewers to find the current state. A single workpad is the source of truth.

**Recovery:** Search existing comments for the `## Codex Workpad` header. If one exists, reuse it. If the agent accidentally created duplicates, consolidate into the original and delete extras.

---

### "If issue state is `Backlog`, do not modify it"

**When:** The agent encounters an issue in `Backlog` state.

**Message:** *"wait for human to move to `Todo`"*.

**Why:** `Backlog` issues have not been prioritized for agent work. Acting on them prematurely can conflict with human planning decisions.

**Recovery:** No action required. The agent should shut down for this issue and wait for a human to move it to `Todo`.

---

### Push rejected: non-fast-forward or auth/permission error

**When:** `git push` fails.

**Message:** Git or GitHub returns a non-fast-forward rejection, or an authentication/permission error.

**Why:** The `push` skill distinguishes between sync problems and access problems because the recovery paths are different.

**Recovery:**
- **Non-fast-forward / stale branch:** Run the `pull` skill to merge `origin/main`, resolve conflicts, rerun validation, then push again.
- **Auth / permission / workflow restriction:** Stop and surface the exact error. Do not attempt to rewrite remotes or switch protocols as a workaround.

---

### "Do not enable auto-merge"

**When:** The agent considers enabling GitHub's auto-merge feature on a PR.

**Message:** *"Do not enable auto-merge; this repo has no required checks so auto-merge can skip tests."*

**Why:** Without required status checks configured on the repository, auto-merge would allow the PR to merge as soon as it is approved, potentially before CI finishes or before review feedback is addressed.

**Recovery:** Use the `land` skill's manual watch loop (`land_watch.py`) to monitor checks and review comments before merging.

---

### "Temporary proof edits must be reverted before commit"

**When:** The agent makes local edits to verify behavior (e.g., hardcoding a value to test a path).

**Message:** *"Temporary proof edits are allowed only for local verification and must be reverted before commit."*

**Why:** Proof edits that leak into commits can introduce bugs, expose test credentials, or change behavior in ways that are invisible to reviewers.

**Recovery:** Before committing, verify that all temporary proof edits are reverted. Document the proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence without the edits being present in the code.

---

## PR flow as the recovery path

When an agent run is blocked or produces an unexpected result, the PR-based flow is the universal recovery mechanism:

1. **Agent creates a branch and PR** -- All work happens on a feature branch, never on `main`.
2. **CI validates the branch** -- The `make-all` workflow and `pr-description-lint` check run on every push.
3. **Human reviews the PR** -- The agent moves the issue to `Human Review` only after the completion bar is met.
4. **Human approves and moves to `Merging`** -- This is the only way a merge can begin.
5. **`land` skill executes the merge** -- Conflict resolution, CI watch, and squash-merge happen under the skill's control.
6. **If anything fails, the PR stays open** -- The human can request changes (moving the issue to `Rework`), and the agent starts fresh on a new branch.

This flow ensures that no agent action can irreversibly affect `main` without human approval. If the agent gets stuck, the worst case is an open PR that a human can close or redirect.
