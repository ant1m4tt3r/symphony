# Symphony Fork Harness

This fork includes a local harness to run Symphony from this repository with
dashboard + Linear tracker.

## Files

- `scripts/symphony/install.sh`: build Symphony runtime from this fork.
- `scripts/symphony/start.sh`: render workflow + start Symphony + dashboard.
- `scripts/symphony/preflight.sh`: one-command readiness check for env/project/workflow.
- `scripts/symphony/list-projects.sh`: list available Linear project slugs.
- `scripts/symphony/bin/claude_app_server.py`: Claude Code CLI shim that speaks Symphony's expected app-server protocol.
- `.symphony/WORKFLOW.template.md`: template used to render the runtime workflow.
- `.env.symphony.local`: local env config (gitignored).

## First-time setup

1. Bootstrap local env:

```bash
cp .env.symphony.local.example .env.symphony.local
```

2. Fill required values in `.env.symphony.local`:
   - `LINEAR_API_KEY`
   - `LINEAR_PROJECT_SLUG` (Linear `slugId`)
3. Set `SYMPHONY_MAX_CONCURRENT_AGENTS=1` for single-task processing (already defaulted in this repo).
4. Verify statuses exist in your Linear team workflow:
   - Active for Symphony polling: `Backlog`, `Todo`, `Ready for Dev`, `In Progress`, `In Review`
   - Terminal: `Done`, `Canceled`, `Duplicate`
5. Install Symphony:

```bash
./scripts/symphony/install.sh
```

## Run

Before starting Symphony, run the readiness preflight:

```bash
./scripts/symphony/preflight.sh
```

Expected successful output:

```text
[preflight] Symphony harness readiness check
[preflight] env_file=/path/to/repo/.env.symphony.local
[check] Required environment keys
  [ok] LINEAR_API_KEY is set
  [ok] LINEAR_PROJECT_SLUG is set
[check] Linear project reachability
  [ok] project reachable: <project-name> (<project-slug>, state=<state>)
[check] Workflow validation
  [ok] Workflow config valid
[ready] Symphony harness preflight passed
```

Any failed check exits non-zero and prints a `[fail] ...` line with the reason.

Then start Symphony:

```bash
./scripts/symphony/start.sh
```

Dashboard URL defaults to `http://127.0.0.1:4040`.

By default, `scripts/symphony/start.sh` runs Symphony from this fork (`SYMPHONY_HOME=$REPO_ROOT`).

To validate config without starting the daemon:

```bash
SYMPHONY_VALIDATE_ONLY=1 ./scripts/symphony/start.sh
```

## Reproducibility smoke checks

Run guard regression tests:

```bash
./scripts/symphony/test-guards.sh
```

Run workflow/config validation with an isolated temp env file:

```bash
tmp_env="$(mktemp)"
cat > "$tmp_env" <<'EOF'
LINEAR_API_KEY=lin_api_smoke_test
LINEAR_PROJECT_SLUG=smoke-test-project
SYMPHONY_AI_ENGINE=codex
EOF
SYMPHONY_ENV_FILE="$tmp_env" SYMPHONY_VALIDATE_ONLY=1 ./scripts/symphony/start.sh
rm -f "$tmp_env"
```

## AI engine selection

Default engine is `claude`.

If Claude runtime is not fully available locally (missing `claude`, `python3`, or shim file), the harness automatically falls back to `codex`.

Use Claude Code locally:

```bash
SYMPHONY_AI_ENGINE=claude ./scripts/symphony/start.sh
```

Use a custom/cloud app-server-compatible command:

```bash
SYMPHONY_AI_ENGINE=custom \
SYMPHONY_AGENT_COMMAND="your-agent-app-server-command" \
./scripts/symphony/start.sh
```

Use OpenCode via shim:

```bash
SYMPHONY_AI_ENGINE=opencode ./scripts/symphony/start.sh
```

Distribute agents across Codex and OpenCode:

```bash
SYMPHONY_AI_ENGINE=mixed \
SYMPHONY_AGENT_ROUTER_MAP=claude:6,codex:1,opencode:1 \
./scripts/symphony/start.sh
```

Engine env vars:

- `SYMPHONY_AI_ENGINE`: `claude` (default), `codex`, `opencode`, `mixed`, or `custom`.
- `SYMPHONY_AGENT_COMMAND`: full command override for the agent runtime.
- `CODEX_COMMAND`: legacy alias still supported for backward compatibility.
- `SYMPHONY_POLL_INTERVAL_MS`: tracker polling interval in milliseconds (default `2000`).
- `SYMPHONY_HOOK_TIMEOUT_MS`: workspace hook timeout in milliseconds (default `180000`). Increase when `after_create` bootstrap needs longer than 60s.
- `SYMPHONY_MAX_TURNS`: max continuation turns per agent run (default `8`; lower means faster reaction to new comments/state updates).
- `SYMPHONY_ALLOW_AUTO_MERGE`: set to `1` to allow Symphony to run `gh pr merge` / merge API calls and to opt out of the local `git merge`-to-`main` guard when explicitly needed; default is blocked.
  - This also enables `codex.allow_unsafe_merge_push: true` in generated workflow so app-server approval guardrails do not block merge commands.
- Mixed routing options:
  - `SYMPHONY_AGENT_ROUTER_MAP`: weighted list (default `claude:6,codex:1,opencode:1`; example `claude:6,codex:1,opencode:1`).
  - `SYMPHONY_AGENT_ROUTER_FALLBACK`: fallback engine when selected engine is unavailable (default `codex`).
  - `SYMPHONY_ROUTER_CODEX_COMMAND`: optional Codex command override for router mode.
  - `SYMPHONY_ROUTER_OPENCODE_COMMAND`: optional OpenCode command override for router mode.
  - `SYMPHONY_ROUTER_CLAUDE_COMMAND`: optional Claude command override for router mode.
- `SYMPHONY_SYNC_FEEDBACK_SCRIPT`: override path for the pre-run feedback sync script (default `scripts/symphony/bin/sync_feedback.sh` in this repo).
- Claude mode options:
  - `CLAUDE_COMMAND` (default `claude`)
  - `CLAUDE_MODEL` (default `claude-opus-4-6`)
  - `CLAUDE_MCP_CONFIG` (optional explicit MCP config path; defaults to workspace `.mcp.json` if present)
  - `CLAUDE_STRICT_MCP_CONFIG` (default `1`; when MCP config is provided, load only that config and ignore global MCP configs)
  - `CLAUDE_DISABLE_SOUNDS` (default `1`; suppresses user `Notification`/`Stop` sound hooks for Symphony runs)
  - `CLAUDE_NO_OUTPUT_TIMEOUT_SEC` (default `420`; fail a turn if Claude emits no stream output for too long)
  - `CLAUDE_PERMISSION_MODE` (default `bypassPermissions`)
  - `CLAUDE_EXTRA_ARGS` (optional extra CLI args)

Claude mode note:

- The shim executes Claude per turn and preserves the same git/gh safety guards.
- The shim now streams progress events to Symphony dashboard and writes per-turn logs to `.symphony/claude-logs/<turn-id>.log` inside each issue workspace.
- Claude runs now use stream JSON output, so dashboard receives token usage updates (`thread/tokenUsage/updated`) and incremental output while a turn is running.
- Claude shim automatically passes `--mcp-config .mcp.json` when available in the workspace, so MCP servers (including Linear) are loaded in Claude runs.
- Full Codex app-server dynamic tool parity is not guaranteed in Claude mode; keep tracker workflows simple or provide a custom `SYMPHONY_AGENT_COMMAND` adapter when needed.

## Feedback sync

- Before each agent run, `scripts/symphony/bin/sync_feedback.sh` updates feedback snapshots:
  - `.symphony/pr-feedback.md` for GitHub PR metadata, comments/reviews, and checks.
  - `.symphony/linear-feedback.md` for Linear issue snapshot and latest comments.
- PR feedback now includes an explicit mergeability snapshot (`mergeStateStatus`, review decision, head/base refs, `requires_update_branch`) so agents can detect conflicts and run update-branch flow quickly.
- Sync is incremental and cached via:
  - `.symphony/pr-feedback.state`
  - `.symphony/linear-feedback.state`
- GitHub API calls run in parallel to reduce pre-run latency.
- Limits are configurable:
  - `SYMPHONY_PR_COMMENT_LIMIT` (default `20`)
  - `SYMPHONY_LINEAR_COMMENT_LIMIT` (default `20`)
- Agents must treat both feedback files as mandatory review input when present.

## Conflict handling

- Workspace setup enables Git `rerere` (`rerere.enabled=true`, `rerere.autoupdate=true`) to reduce repeat conflict effort.
- Agents are expected to keep branches mergeable by running the `.codex/skills/pull` merge-based update flow with `origin/main` whenever PR mergeability is dirty/conflicted.
- Treat GitHub `mergeStateStatus` values `DIRTY`, `BEHIND`, `BLOCKED`, and `UNSTABLE` as immediate update-branch signals.

## Helper

To list project slugs from your Linear workspace:

```bash
./scripts/symphony/list-projects.sh
```

## Status policy

- PR-only flow: all changes must go through pull requests targeting `main`.
  Direct pushes to `main` are not allowed.
- Manual-only merge by default: unless `SYMPHONY_ALLOW_AUTO_MERGE=1`, PRs stay
  human-merged only.
- Move to `In Review` only after a working PR exists (open, non-draft, target `main`, linked to the issue, with commits).
- If an issue begins in `Backlog`, `Todo`, or `Ready for Dev`, Symphony may move it to `In Progress` before implementation.
- Dispatch prioritization favors active delivery:
  - state order: `In Review` -> `In Progress` -> `Todo` -> `Ready for Dev` -> `Backlog`;
  - within the same state, higher priority (1 is highest) and older issue age are processed first;
  - issues labeled/title-prefixed as epics (for example `[Epic]`) are deprioritized versus actionable tasks.
- While `In Review`, Symphony must continuously monitor PR CI/check failures and PR comments/suggestions:
  - at the start of each review pass, fetch latest PR checks and discussion directly from GitHub;
  - read both PR conversation comments and code-review comments/threads;
  - comments from any human reviewer are valid steering input, including comments authored by the PR author/issue assignee;
  - comments prefixed with `[symphony]` are explicit steering directives and should be prioritized;
  - if CI fails, implement fixes and push updates;
  - if a suggestion is valid, implement it;
  - if a suggestion should not be applied, reply on the PR with a concise technical reason;
  - ignore only clearly automated bot comments, except bot reports of failing checks.
- Move to `Done` only after that PR is merged.
- Merge behavior is environment-controlled:
  - If `SYMPHONY_ALLOW_AUTO_MERGE=1`, Symphony may merge eligible PRs once checks are green and human review feedback is resolved.
  - Otherwise, merge remains manual-only.

## Dashboard runtime metadata

- Running sessions now surface per-task runtime identity:
  - engine (`codex`, `opencode`, `claude`, `mixed`, or `custom`)
  - model (for example `gpt-5.3-codex`, `claude-opus-4-6`, `openai/gpt-5`)
  - provider (derived from model/runtime, for example `openai`, `anthropic`)
- These values are also included in observability API payloads under `running[].agent`.

## Sandbox and scratchpad policy

- Symphony workers run with `danger-full-access` sandbox inside isolated issue workspaces to allow branch/commit/ref updates.
- Scratchpads must stay inside the workspace repository at `.symphony/scratchpads/<branch>.scratchpad.md` (not `../...`).

## Merge safety guard

- The harness prepends `scripts/symphony/bin` to `PATH` and routes `gh` and `git` through guard wrappers.
- By default, the `gh` wrapper blocks `gh pr merge` and GitHub API merge endpoints (`/pulls/<n>/merge`) and returns a hard error.
- Set `SYMPHONY_ALLOW_AUTO_MERGE=1` to allow merge commands for this repository harness.
- The `git` guard blocks direct pushes to `main` (including `HEAD:main` style refspecs), even if hooks are bypassed.
- The `git` guard also blocks `git merge` while checked out on `main` by default and prints PR-flow remediation. Set `SYMPHONY_ALLOW_AUTO_MERGE=1` only when intentionally opting out locally.
- Each Symphony workspace clone also installs a `pre-push` hook that blocks pushes to `refs/heads/main`.
