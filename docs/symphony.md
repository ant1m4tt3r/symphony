# Symphony Local Runbook

This runbook covers setup, validation, runtime, and policy for the
**ant1m4tt3r/symphony** fork.

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| [mise](https://mise.jdx.dev/) | latest | `brew install mise` or see mise docs |
| Erlang | 28 | managed by mise |
| Elixir | 1.19.x (OTP 28) | managed by mise |
| Git | any recent | system package manager |

A Linear personal API key is required at runtime. Generate one at
**Settings > Security & access > Personal API keys** in Linear.

## Setup

```bash
git clone git@github.com:ant1m4tt3r/symphony.git
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup        # fetches dependencies
mise exec -- mix build         # builds the escript binary at bin/symphony
```

## Validation

Run the full quality gate before every PR handoff:

```bash
make all
```

This runs, in order:

1. `mix setup` -- dependency fetch
2. `mix build` -- escript compilation
3. `mix format --check-formatted` -- formatting check
4. `mix lint` (= `mix specs.check` + `mix credo --strict`) -- spec and style lints
5. `mix test --cover` -- tests with coverage enforcement
6. `mix dialyzer` -- static type analysis

Individual targets are available via `make <target>` (see `make help`).

To validate a PR body against the required template:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Runtime

### Starting Symphony

```bash
cd elixir
LINEAR_API_KEY=lin_api_... mise exec -- ./bin/symphony ./WORKFLOW.md
```

If no workflow path is given, Symphony defaults to `./WORKFLOW.md` in the
current directory.

### Optional flags

| Flag | Purpose | Default |
|------|---------|---------|
| `--port <port>` | Start the Phoenix observability dashboard | disabled |
| `--logs-root <dir>` | Write logs to a custom directory | `./log` |

### Observability dashboard

When started with `--port`, the Phoenix LiveView dashboard is available at:

- `/` -- live dashboard
- `/api/v1/state` -- full orchestrator state (JSON)
- `/api/v1/<issue_identifier>` -- single issue state (JSON)
- `/api/v1/refresh` -- force a poll cycle

### Configuration

All runtime configuration lives in YAML front matter inside `WORKFLOW.md`.
Key sections:

- `tracker` -- Linear project slug and issue state mappings
- `workspace.root` -- where per-issue workspaces are created
- `hooks.after_create` -- shell commands to bootstrap a workspace (e.g. `git clone`)
- `agent` -- concurrency limits and max turns
- `codex` -- Codex command, approval policy, and sandbox settings

See `elixir/README.md` for full configuration reference and defaults.

### Environment variables

| Variable | Purpose |
|----------|---------|
| `LINEAR_API_KEY` | Linear personal API key (required) |

## Policy

### Manual-only merge

PRs are **never merged automatically**. Symphony agents create and update PRs
but never call `gh pr merge` or merge via API. All merges are performed manually
by a human maintainer after review.

### PR-only flow

All changes reach `main` through pull requests. Direct pushes to `main` are
not permitted. The expected lifecycle is:

1. Agent (or contributor) creates a feature branch.
2. Work is committed and pushed to the branch.
3. A PR is opened targeting `main`.
4. The PR passes CI (`make all`) and human code review.
5. A human maintainer merges the PR.

### Issue lifecycle

Issues follow this state progression:

```
Backlog/Todo --> In Progress --> Human Review --> Merging --> Done
                     ^                |
                     |   (changes)    |
                     +--- Rework <----+
```

- **Backlog** -- not acted on; waits for human to move to Todo.
- **Todo** -- queued; moved to In Progress before work begins.
- **In Progress** -- active implementation.
- **Human Review** -- PR exists and is validated; awaiting human approval.
- **Merging** -- approved; human performs the merge.
- **Done** -- terminal; PR is merged.

### Branch naming

Use flat branch names without `/` separators to avoid git ref directory
conflicts. Example: `hug-42-fix-polling` (not `hug/42/fix-polling`).
