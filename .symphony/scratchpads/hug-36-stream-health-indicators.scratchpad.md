# HUG-36: Stream Health Indicators and Staleness Warnings

## Issue
[HUG-36](https://linear.app/ant1m4tter/issue/HUG-36/dashboard-add-stream-health-indicators-and-staleness-warnings)

## Goal
Quickly identify stuck or silent sessions before hard timeout.

## Acceptance Criteria
- [ ] Show "last update age" and staleness badge per session
- [ ] Highlight no-output risk as elapsed time approaches configured timeout
- [ ] Distinguish between active streaming, idle, and stalled states
- [ ] Include tests for threshold transitions

## Implementation Notes
- Stall timeout is configured via `codex.stall_timeout_ms` (default 300000ms / 5 minutes)
- Need to expose stall_timeout to dashboard via Presenter
- Need to add health status calculation based on last_event timestamp vs current time
- Need to add visual indicators: badges for streaming/idle/stalled states
- Need to add tests for threshold transitions

## Progress
- [ ] Add health field to running_entry_payload in Presenter
- [ ] Update DashboardLive to display health status
- [ ] Add CSS styles for health indicators
- [ ] Add tests for threshold transitions

## Validation
- Run `mix test` to verify tests pass
- Run `mix format` to ensure code is formatted
- Run `mix dialyzer` if available
