# HUG-23: Expose PR/check status badges on each task card

## Plan

### Acceptance criteria
- Card visual state includes CI/check health and review status when present
- Failure states are visually distinct and keyboard-accessible
- Add snapshot tests for key card states

### Implementation

1. **Orchestrator**: Add optional `pr_status` map to running entry metadata + snapshot
2. **Orchestrator API**: Add `update_pr_status/3` public function
3. **Presenter**: Pass `pr_status` through to LiveView payload
4. **LiveView**: Render CI check + review status badges on task cards
5. **CSS**: Style badges (success/failure/pending), keyboard-accessible focus
6. **Tests**: Snapshot tests for LiveView card states with various PR/CI statuses

### PR status shape
```elixir
%{
  pr_url: "https://github.com/org/repo/pull/42",
  pr_number: 42,
  checks: "passing" | "failing" | "pending" | nil,
  review_status: "approved" | "changes_requested" | "pending" | nil
}
```

## Progress
- [ ] Branch created
- [ ] Orchestrator changes
- [ ] Presenter changes
- [ ] LiveView + CSS changes
- [ ] Snapshot tests
- [ ] All tests passing
