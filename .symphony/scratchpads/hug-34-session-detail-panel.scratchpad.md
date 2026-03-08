# HUG-34: Session Detail Panel Scratchpad

## Plan
- Add expandable detail panel to running sessions table rows
- Panel shows: session ID, app-server PID, start time, last event timestamp, agent command preview, runtime info
- Include links to JSON details and workspace path
- Responsive layout for narrow viewports

## Changes
- `presenter.ex`: Added `app_server_pid` and `workspace_path` to `running_entry_payload/1`
- `dashboard_live.ex`: Added `expanded_session` assign, `toggle_detail`/`noop` events, expandable detail panel UI below each running row
- `dashboard.css`: Added `.detail-panel-*` styles with responsive breakpoints
- `extensions_test.exs`: Updated test assertion to include new fields

## Validation
- `make -C elixir all` passes (only pre-existing flaky timing test in core_test.exs occasionally fails)
- Format, lint, specs all clean
