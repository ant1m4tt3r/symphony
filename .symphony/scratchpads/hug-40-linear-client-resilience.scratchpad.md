## HUG-40 Scratchpad

- Branch: `hug-40-linear-client-resilience`
- Issue: `HUG-40`
- Linear workpad comment id: `c68b28a1-d9c0-4d35-855b-2af87eb4eab7`
- Status: `In Progress`

### Objective

- Add exponential backoff retries and a circuit breaker to the Linear GraphQL client, with rate-limit-aware proactive throttling and structured observability metadata.

### Progress

- [x] Read root `WORKFLOW.md` and mandatory `.symphony/linear-feedback.md` input.
- [x] Moved Linear issue `HUG-40` from `Todo` to `In Progress`.
- [x] Created/switch to dedicated branch `hug-40-linear-client-resilience`.
- [x] Ran pull skill flow and synced branch with `origin/main`.
  - merge source: `origin/main`
  - remote branch sync: skipped (`origin/hug-40-linear-client-resilience` does not exist yet)
  - result: `clean` (no conflicts)
  - resulting HEAD: `96b6682`
- [x] Implemented Linear client resilience flow in `linear/client.ex`:
  - transient retry handling (`429`, `5xx`, timeout/network request errors)
  - exponential retry delays with `Retry-After` support
  - circuit breaker state with failure threshold and cooldown recovery
  - low-budget rate-limit proactive backoff from response headers
  - structured resilience metadata on failure/retry log paths
- [x] Updated orchestrator Linear fetch error logging to include resilience metadata payloads when present.
- [x] Extended dynamic tool error formatting to preserve metadata from enriched Linear client failures.
- [x] Added dedicated resilience tests in `linear_client_resilience_test.exs`.
- [x] Stabilized test environment isolation by clearing/restoring `LINEAR_API_KEY` in test setup.
- [x] Ran relevant tests/checks and recorded evidence.

### Validation Evidence

- `git fetch origin`
- `git -c merge.conflictstyle=zdiff3 merge origin/main`
- `cd elixir && mix test test/symphony_elixir/linear_client_resilience_test.exs test/symphony_elixir/workspace_and_config_test.exs test/symphony_elixir/dynamic_tool_test.exs test/symphony_elixir/orchestrator_status_test.exs`
- `cd elixir && mix test`
- `cd elixir && mix specs.check`
- `./scripts/symphony/test-guards.sh`
- `tmp_env="$(mktemp)" && cp .env.symphony.local.example "$tmp_env" && SYMPHONY_ENV_FILE="$tmp_env" SYMPHONY_VALIDATE_ONLY=1 ./scripts/symphony/start.sh`

### Blockers / Notes

- Linear workpad comment mutation is partially blocked in this session:
  - `commentUpdate` for workpad comment `c68b28a1-d9c0-4d35-855b-2af87eb4eab7` returns HTTP `400`.
  - `commentDelete` for temporary comment cleanup also returns HTTP `400`.
  - A temporary probe comment was created while validating mutation behavior: `aff97fee-0924-40e3-8edf-cf5375f5cc5d`.

### Pending

- [ ] Commit
- [ ] Push + PR
- [ ] Move issue to `In Review` once working PR exists
