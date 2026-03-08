# HUG-33: Show engine, provider, and model in Running sessions

## Status: In Progress

## Findings

The feature (engine/provider/model in running sessions table) is already implemented in main:
- Dashboard table: `dashboard_live.ex` lines 254-264 show Agent runtime column
- Presenter: `running_entry_payload/1` includes `agent` map with command/engine/provider/model
- API: `/api/v1/state` serves these fields via Presenter
- Live updates: PubSub integration + `integrate_codex_update/2` in Orchestrator
- Runtime column added: shows effective runtime selection (claude/codex)

## Bug Found

`display_or_na/1` in `dashboard_live.ex` has a nil handling bug:
- `nil` is an atom in Elixir, so `is_atom(nil)` is `true`
- `Atom.to_string(nil)` returns `"nil"` (confirmed)
- This means nil values display as literal string "nil" instead of "n/a"
- Violates acceptance criterion #3: "Unknown values render as explicit fallback (n/a)"

## Fix

Add explicit `nil` clause before the atom clause in `display_or_na/1`.

## Validation

- [ ] Fix applied
- [ ] Tests pass
- [ ] PR created
