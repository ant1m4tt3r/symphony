# Status transition gates runbook

This document defines the valid issue lifecycle states, allowed transitions,
and gate criteria that must be satisfied before each transition. It serves as
the authoritative reference for both human operators and automated agents.

## Lifecycle overview

```
                      human
  Backlog ────────────────► Todo
                              │
                              │ agent (pickup)
                              ▼
                          In Progress ◄──────────── Rework
                              │                       ▲
                              │ agent (PR ready)       │ human (changes requested)
                              ▼                       │
                          Human Review ───────────────┘
                              │
                              │ human (approved)
                              ▼
                           Merging
                              │
                              │ agent (PR merged via land skill)
                              ▼
                            Done
```

Terminal states: `Done`, `Closed`, `Cancelled`, `Canceled`, `Duplicate`.

## Gate definitions

### Todo to In Progress

**Trigger:** Agent picks up a queued issue.

**Gate criteria:**

1. Issue has required fields: `id`, `identifier`, `title`, `state`.
2. No non-terminal blockers: every issue in the `blockedBy` relation must be in
   a terminal state (`Done`, `Closed`, `Cancelled`, `Canceled`, `Duplicate`).
3. Agent creates or finds the bootstrap `## Codex Workpad` comment.

**Actions on entry:**

- Call `issueUpdate` to move state to `In Progress`.
- Create workpad comment if not found.
- Begin planning and implementation.

### In Progress to Human Review

**Trigger:** Agent completes implementation and PR is validated.

**Gate criteria (all required):**

1. A GitHub PR exists and is **open** (not closed, not merged).
2. The PR is **not** a draft.
3. The PR targets the `main` branch.
4. The PR is linked or attached to the Linear issue (via `attachmentLinkGitHubPR`
   or issue link).
5. The branch has at least one commit for this issue
   (`git log origin/main..HEAD` is non-empty).
6. All acceptance criteria in the workpad are checked off.
7. Validation and tests pass on the latest commit (`make -C elixir all`
   exits 0).
8. PR feedback sweep is complete: no outstanding actionable reviewer comments.
9. PR CI checks are passing (green).
10. PR has the `symphony` label.

**Verification commands:**

```sh
# 1. PR is open
gh pr view --json state -q .state  # must be "OPEN"

# 2. PR is not draft
gh pr view --json isDraft -q .isDraft  # must be "false"

# 3. PR targets main
gh pr view --json baseRefName -q .baseRefName  # must be "main"

# 5. Branch has commits
git log origin/main..HEAD --oneline  # must be non-empty

# 7. Tests pass
make -C elixir all

# 9. PR checks green
gh pr checks

# 10. Label present
gh pr view --json labels -q '.labels[].name'  # must include "symphony"
```

**If any gate fails:** The issue stays in `In Progress`. Fix the issue, push
updates, and re-check.

### Human Review to Rework

**Trigger:** Human reviewer requests changes (review comments, explicit
state change).

**Gate criteria:**

1. A human reviewer has requested changes or posted actionable feedback.

This transition is **human-initiated only**. The agent does not move issues to
`Rework`.

### Rework to In Progress

**Trigger:** Agent begins addressing review feedback.

**Gate criteria:**

1. The existing PR tied to the issue is closed.
2. The previous `## Codex Workpad` comment is removed.
3. A fresh branch is created from `origin/main`.

**Actions on entry:**

- Re-read the full issue body and all human comments.
- Identify what will be done differently.
- Create a new workpad comment and build a fresh plan.

### Human Review to Merging

**Trigger:** Human approves the PR.

**Gate criteria:**

1. The PR review state is `APPROVED`.

This transition is **human-initiated only**.

### Merging to Done

**Trigger:** PR merge completes via the land skill.

**Gate criteria:**

1. **The linked PR is merged.** `gh pr view --json state -q .state` must
   return `MERGED`.
2. The land skill flow (`.codex/skills/land/SKILL.md`) has been followed to
   completion.

**The Done state requires a merged PR.** An issue must never be moved to
`Done` unless its linked GitHub PR has been merged. This is the single
non-negotiable gate for the `Done` terminal state.

## Prohibited transitions

| From | To | Reason |
|------|----|--------|
| In Progress | Done | Must pass through Human Review and Merging |
| Todo | Human Review | Implementation must happen in In Progress first |
| Any | Done (without merged PR) | Done requires a merged PR |
| Any (by agent) | Merging | Only humans approve PRs |
| Any (by agent) | Rework | Only humans request rework |

## Agent responsibilities

- The agent must never call `gh pr merge` or merge via API. Merging is
  controlled by the land skill after a human moves the issue to `Merging`.
- The agent must verify all gate criteria before calling `issueUpdate`.
- If a gate check fails, the agent must fix the underlying issue rather than
  skip the gate.
- If the agent cannot satisfy a gate due to missing permissions or tools,
  it must document the blocker in the workpad and keep the issue in its
  current state.

## Human responsibilities

- Move issues from `Backlog` to `Todo` when ready for agent pickup.
- Review PRs in `Human Review` and either approve (triggering `Merging`) or
  request changes (triggering `Rework`).
- The PR merge itself is handled by the land skill after the human moves
  the issue to `Merging`, but the human initiates the transition.
