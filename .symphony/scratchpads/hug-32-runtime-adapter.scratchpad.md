# HUG-32: Runtime Adapter Abstraction

## Plan

### Acceptance Criteria
1. Agent runner no longer hard-wired to Codex-only modules/naming; runtime adapter boundary is explicit
2. Workflow/config supports selecting Claude and Codex runtimes via normalized setting model
3. Runtime startup/turn flow preserves existing behavior for Codex and adds Claude parity hooks
4. Dispatch records chosen runtime in run metadata for observability/tests

### Implementation

1. **Create `Runtime` behaviour** (`runtime.ex`) - explicit adapter boundary
   - Defines `@callback start_session/2`, `run_turn/4`, `stop_session/1`
   - Public API delegates to `Runtime.AppServer`

2. **Rename `Codex.AppServer` -> `Runtime.AppServer`**
   - Move module, update internal log messages from "Codex" to runtime-agnostic
   - Keep `Codex.AppServer` as deprecated delegator for backwards compat

3. **Rename `Codex.DynamicTool` -> `Runtime.DynamicTool`**
   - Same approach - move and alias

4. **Update `AgentRunner`** - runtime-agnostic naming
   - `run_codex_turns` -> `run_agent_turns`
   - `codex_update_recipient` -> `update_recipient`
   - `send_codex_update` -> `send_runtime_update`
   - `codex_message_handler` -> `runtime_message_handler`
   - Use `Runtime` instead of `Codex.AppServer`

5. **Add normalized Config** - `Config.runtime_settings/1` per-runtime accessor

6. **Update Orchestrator** - rename codex-specific naming in update integration

7. **Update tests** for new module paths

## Progress
- [ ] Branch created
- [ ] Runtime behaviour module
- [ ] AppServer rename
- [ ] DynamicTool rename
- [ ] AgentRunner update
- [ ] Config update
- [ ] Orchestrator update
- [ ] Tests updated
- [ ] All tests pass
