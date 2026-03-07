# HUG-15 Scratchpad

## Summary

Define status gates for Ready for Dev -> In Progress -> In Review -> Done.

## Changes

1. **elixir/WORKFLOW.md** - Added `## Status transition gates` section between
   the Status map and Step 0. Defines valid transitions, gate criteria tables
   for each transition, and prohibited transitions.

2. **elixir/docs/status_gates.md** - New runbook document with lifecycle
   diagram, gate definitions with verification commands, prohibited transitions
   table, and agent/human responsibility boundaries.

## Acceptance criteria status

- [x] Runbook and workflow template encode valid transitions and gate criteria
- [x] Done state requires merged PR (explicitly gated in both documents)

## Validation

- `make -C elixir build` - passes
- `make -C elixir fmt-check` - passes
- `make -C elixir lint` - passes
- Test failures are pre-existing (timing flake + env variable), not related to
  documentation changes
