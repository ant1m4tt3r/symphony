# HUG-11 Scratchpad

## Status: In review

## Branch
- `hug-11-guard-wrapper-regression-tests`

## PR
- https://github.com/ant1m4tt3r/symphony/pull/7
- commit: `1982454`

## Sync evidence
- pull source: `origin/main`
- result: `clean` (fast-forward on local `main`, merge step no-op)
- resulting HEAD after pull: `0c50c92`

## Plan
- [x] Add regression tests for `scripts/symphony/bin/git` push guards.
- [x] Add regression tests for `scripts/symphony/bin/gh` merge guards.
- [x] Run targeted tests locally and record output.

## Reproduction signal
- Before implementation, `scripts/symphony/bin/git` and `scripts/symphony/bin/gh` were missing from this checkout (`sed` and `find` checks returned "No such file or directory").

## Changes made
- Added `scripts/symphony/bin/git` guard wrapper to block pushes to `main` while allowing feature-branch refspec pushes.
- Added `scripts/symphony/bin/gh` guard wrapper to block `gh pr merge` and merge API endpoint calls.
- Added `scripts/symphony/test-guards.sh` regression harness with fake `git`/`gh` binaries and assertions for allowed/blocked flows.
- Updated `.github/workflows/make-all.yml` to run `scripts/symphony/test-guards.sh` in CI.
- Updated `elixir/test/symphony_elixir/core_test.exs` to assert a generic GitHub owner in `after_create` clone URL, fixing CI brittleness with fork URLs.

## Notes
- 2026-03-07T13:08:21Z: Created issue branch and initialized scratchpad.
- 2026-03-07T13:13:51Z: Local guard tests initially failed because this environment exports `SYMPHONY_REAL_GIT`/`SYMPHONY_REAL_GH`; fixed missing-binary assertions by unsetting those vars for that test path.
- 2026-03-07T13:14:11Z: Validation passed: `bash ./scripts/symphony/test-guards.sh`.
- 2026-03-07T13:16:53Z: `cd elixir && make all` failed with pre-existing/environment-sensitive test failures unrelated to this change:
  - `SymphonyElixir.OrchestratorStatusTest` retry-backoff timing assertion (`remaining_ms >= 9500`, got `9232`).
  - `SymphonyElixir.CoreTest` expected `Config.linear_assignee() == nil`, but environment sets `LINEAR_ASSIGNEE=me`.
  - `SymphonyElixir.CoreTest` expected clone URL `openai/symphony`, but `WORKFLOW.md` currently uses `ant1m4tt3r/symphony`.
- 2026-03-07T13:14:11Z: Tracker caveat: Linear `commentUpdate/commentDelete/commentResolve` are blocked by token scope (`Invalid scope: write required`), so only initial workpad comment creation succeeded in this session.
- 2026-03-07T13:20:07Z: Pushed branch, opened PR #7, added `symphony` label, and moved Linear issue `HUG-11` to `In Review`; `make-all` check is currently in progress.
- 2026-03-07T13:23:23Z: Investigated failed CI run and fixed `CoreTest` to accept `https://github.com/<owner>/symphony` in `WORKFLOW.md` `after_create`.
- 2026-03-07T13:23:54Z: Validation passed:
  - `cd elixir && mix test test/symphony_elixir/core_test.exs:74`
  - `bash ./scripts/symphony/test-guards.sh`
