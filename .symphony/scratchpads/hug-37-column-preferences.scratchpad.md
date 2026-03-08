# HUG-37: Persist operator column preferences

## Plan

### Columns (toggleable)
- `runtime` — Runtime column (col 4)
- `runtime_turns` — Runtime / turns column (col 5)
- `agent_runtime` — Agent runtime (model/provider) column (col 6)
- `codex_update` — Codex update (update text) column (col 7)
- `tokens` — Tokens column (col 8)

### Always visible (not toggleable)
- Issue (col 1)
- State (col 2)
- Session (col 3)

### Approach
1. Add column visibility state to LiveView assigns (default: all visible)
2. Add a JavaScript hook (`ColumnPrefs`) in layouts.ex that:
   - Reads preferences from `localStorage` on mount
   - Pushes stored prefs to LiveView via `pushEvent`
   - Listens for `store-column-prefs` events from LiveView to persist changes
3. Add `handle_event` callbacks for `toggle-column` and `reset-columns`
4. Make table template conditional on column visibility
5. Add a dropdown/popover toggle UI in the Running sessions section header
6. Add CSS for the toggle dropdown

### Default preset
All columns visible (matches current behavior).

## Progress
- [ ] Branch created
- [ ] Implementation
- [ ] Validation
- [ ] PR created
