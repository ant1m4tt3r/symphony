---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "__LINEAR_PROJECT_SLUG__"
  assignee: $LINEAR_ASSIGNEE
  active_states:
    - Backlog
    - Todo
    - Ready for Dev
    - In Progress
    - In Review
  terminal_states:
    - Done
    - Canceled
    - Duplicate
polling:
  interval_ms: __POLL_INTERVAL_MS__
workspace:
  root: "__SYMPHONY_WORKSPACE_ROOT__"
hooks:
  timeout_ms: __HOOK_TIMEOUT_MS__
  after_create: |
    git clone --depth 1 "__SOURCE_REPO_URL__" .
    git config rerere.enabled true
    git config rerere.autoupdate true
    cat > .git/hooks/pre-push <<'HOOK'
    #!/usr/bin/env bash
    set -euo pipefail

    remote_name="${1:-origin}"

    while read -r local_ref local_sha remote_ref remote_sha; do
      if [[ "$remote_ref" == "refs/heads/main" ]]; then
        echo "[pre-push] blocked: refusing to push to 'main' on '$remote_name'." >&2
        echo "[pre-push] open a PR from a feature branch instead." >&2
        exit 1
      fi
    done

    exit 0
    HOOK
    chmod +x .git/hooks/pre-push
    if command -v mise >/dev/null 2>&1; then
      mise trust || true
      mise install || true
    fi
  before_run: |
    set -euo pipefail

    if [[ -x "__SYNC_FEEDBACK_SCRIPT__" ]]; then
      "__SYNC_FEEDBACK_SCRIPT__"
    else
      mkdir -p .symphony
      rm -f .symphony/pr-feedback.md .symphony/pr-feedback.state .symphony/linear-feedback.md .symphony/linear-feedback.state
    fi
agent:
  max_concurrent_agents: __MAX_CONCURRENT_AGENTS__
  max_turns: __MAX_TURNS__
codex:
  command: __AGENT_COMMAND__
  approval_policy: never
  thread_sandbox: danger-full-access
  allow_unsafe_merge_push: __ALLOW_UNSAFE_MERGE_PUSH__
  turn_sandbox_policy:
    type: dangerFullAccess
---

You are working on Linear issue `{{ issue.identifier }}`.

Issue details:
- Identifier: {{ issue.identifier }}
- Title: {{ issue.title }}
- State: {{ issue.state }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Execution contract:
1. Read and follow `/WORKFLOW.md` in the cloned repository.
2. Keep a persistent branch scratchpad inside the repository at `.symphony/scratchpads/<branch>.scratchpad.md` (never outside workspace root).
3. Use `.codex/skills` when needed (`commit`, `pull`, `push`) and use the active engine's tracker integration for issue updates.
4. If `.symphony/pr-feedback.md` or `.symphony/linear-feedback.md` exists, treat them as mandatory review input for the current run and address all actionable comments/check failures before ending the turn.
5. Keep issue states in this lifecycle: `Backlog/Todo/Ready for Dev -> In Progress -> In Review -> Done`.
6. If review requests changes, continue implementation in `In Progress`, then return to `In Review`.
7. Never push directly to `main`; use a PR-based flow.
8. Run relevant tests/checks before handoff and record evidence in the issue workpad.
9. Keep one persistent workpad comment in the issue as the source of truth.
10. Respect merge policy from environment:
    - If `SYMPHONY_ALLOW_AUTO_MERGE=1`, you may merge eligible PRs after checks pass and review feedback is addressed.
    - Otherwise, keep merge manual-only.
11. For meta-driver tickets (for example title prefixed `[Ongoing]`), perform backlog grooming: create/update actionable child tasks with explicit acceptance criteria and priority so implementation work can be dispatched next.
12. Keep your branch mergeable: before requesting review, and whenever PR mergeability becomes dirty/conflicted, run the `.codex/skills/pull` merge-based update flow with `origin/main`, resolve conflicts, and push.
13. Treat these GitHub `merge_state_status` values as must-act signals from `.symphony/pr-feedback.md`: `DIRTY`, `BEHIND`, `BLOCKED`, `UNSTABLE`. When seen, immediately run the `.codex/skills/pull` flow and push an updated branch.

Status transition gates (strict):
1. Move an issue to `In Review` only when a working GitHub PR exists.
2. A "working PR" means all of the following:
   - PR is open (not closed/merged).
   - PR is not draft.
   - PR targets `main`.
   - PR is linked/attached to the Linear issue.
   - Branch has at least one commit for this issue.
3. Do not move to `Done` unless the linked PR is merged.
4. In `In Review` state:
   - Do not start new feature work outside review scope.
   - If `SYMPHONY_ALLOW_AUTO_MERGE=1`, merge only when CI/checks are green and no unresolved human review actions remain.
   - If auto-merge is disabled, never merge the PR yourself (no `gh pr merge`, no merge via API/UI automation).
   - If PR mergeability is dirty/conflicted, immediately run the `.codex/skills/pull` update-branch flow, resolve conflicts, and push.
   - If PR mergeability snapshot says `requires_update_branch: true`, do not wait; run update-branch now and push.
   - Continuously monitor PR checks/CI and PR comments/suggestions.
   - Continuously monitor Linear issue comments for new steering from maintainers.
   - At the start of each `In Review` pass, fetch the latest PR checks and discussion from GitHub before deciding there is no action.
   - At the start of each `In Review` pass, fetch the latest Linear issue comments before deciding there is no action.
   - Read both PR conversation comments and code-review comments/threads (resolved and unresolved).
   - Read Linear issue comments and treat human comments as actionable guidance.
   - Treat comments from any human reviewer as actionable input, including comments authored by the PR author/issue assignee.
   - Treat comments prefixed with `[symphony]` (especially from PR author/assignee) as explicit steering directives.
   - If CI fails, investigate and implement the required fixes, push updates, and keep the issue in `In Review`.
   - For PR comments/suggestions, implement when they make sense for scope/quality.
   - If a suggestion should not be applied, reply on the PR with a concise technical reason.
   - Ignore only clearly automated bot comments, except when they report failing checks that require action.
   - If changes are requested, move back to `In Progress`, implement fixes, and return to `In Review`.
   - If PR is merged, move issue to `Done`.
5. If no PR exists yet, keep issue in `In Progress`.
6. If an issue starts in `Backlog`, `Todo`, or `Ready for Dev`, move it to `In Progress` before implementation work begins.

Branch and workspace rules:
1. Create and work on a dedicated issue branch before code changes (avoid `main` for implementation).
2. Use branch names without `/` separators (example: `hug-2926-reconciler`) to avoid ref directory creation failures.
3. If branch creation fails, treat it as a blocker; do not fallback to implementing on `main`.
