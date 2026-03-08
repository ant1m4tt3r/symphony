# HUG-35 Scratchpad

## Context
- Issue: HUG-35
- Title: [Dashboard] Improve information hierarchy for running-task cards/table
- Branch: hug-35-dashboard-hierarchy
- Started: 2026-03-08

## Workflow Compliance
- [x] Read `WORKFLOW.md`
- [x] Checked mandatory feedback files (`.symphony/pr-feedback.md`, `.symphony/linear-feedback.md`)
- [x] Moved to dedicated branch before code edits
- [x] Ran pull/sync flow before edits
  - `git fetch origin`
  - remote branch pull skipped (branch not yet on origin)
  - `git -c merge.conflictstyle=zdiff3 merge origin/main` -> Already up to date

## Plan
1. Locate running-task card/table UI and related styles.
2. Restructure hierarchy to promote issue/state/runtime health and visually group runtime/token/agent metadata.
3. Add truncated updates with tooltip/full text affordance and preserve keyboard accessibility.
4. Run relevant tests/checks and capture evidence.
5. Prepare PR + update tracker/workpad.

## Notes Log
- Initialized scratchpad and recorded sync evidence.

## Implementation Notes
- Updated `elixir/lib/symphony_elixir_web/live/dashboard_live.ex`:
  - Promoted primary signal in cards and table with explicit runtime health badge (`Healthy/Watch/Stale/Blocked/Unknown`) derived from issue state and last event recency.
  - Reworked running-task cards with grouped metadata sections for runtime, tokens, and agent.
  - Reworked running-sessions table columns to emphasize issue/state/runtime health and move update text to trailing, lower-emphasis column.
  - Added truncated update previews with `title` tooltip plus keyboard-accessible `details/summary` full-text affordance.
  - Added helper functions: `update_payload/1`, `truncate_copy/2`, `runtime_health_status/2`, `runtime_health_label/1`, `runtime_health_badge_class/1`, `seconds_since/2`.
- Updated `elixir/priv/static/dashboard.css`:
  - Added runtime-health badge styles.
  - Added metadata grouping styles (`task-card-meta-groups`, `meta-group*`, `metadata-stack`).
  - Added update disclosure styles with visible `:focus-visible` ring for keyboard users.
  - Added issue title and owner/detail refinements for improved scanability.
- Updated `elixir/test/symphony_elixir/extensions_test.exs` assertions to match new dashboard headings (`Latest update`, `Runtime health`).

## Validation Evidence
- `mix format lib/symphony_elixir_web/live/dashboard_live.ex test/symphony_elixir/extensions_test.exs`
- `mix deps.get`
- `mix test test/symphony_elixir/extensions_test.exs`
  - Result: `12 tests, 0 failures`
- `./scripts/symphony/test-guards.sh`
  - Result: `All guard regression tests passed.`
- `SYMPHONY_ENV_FILE=<temp-env-from-.env.symphony.local.example> SYMPHONY_VALIDATE_ONLY=1 ./scripts/symphony/start.sh`
  - Result: `Workflow config valid` and `Validation complete`

## Tracker Notes
- Attempted Linear tracker operations for HUG-35 via MCP tools; current configured workspace does not expose issue `HUG-35` (lookup returned entity not found / unrelated workspace issues). Local implementation and evidence were still completed in-repo.
- `make -C elixir all`
  - Result: passed (`fmt-check`, `lint`, `mix test --cover` with 221 tests, `dialyzer` success).
  - Note: first run reported one dialyzer warning (`pattern_match_cov`) in `runtime_health_label/1`; removed unreachable fallback clause and reran successfully.

## PR
- URL: https://github.com/ant1m4tt3r/symphony/pull/21
- State: OPEN, non-draft, base `main`
- Checks: `make-all` SUCCESS
- Mergeability: `CLEAN`
- Review/comments snapshot: no PR conversation comments or review comments at time of check.

## Tracker Follow-up
- Attempted to move issue `HUG-35` to `In Review` via Linear MCP: `Entity not found` (workspace/token mismatch).
- Attempted issue lookup by identifier and issue update APIs; `HUG-35` is unavailable in configured Linear workspace, so state/comment updates are currently blocked from this environment.
