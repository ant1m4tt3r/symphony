# Symphony Harness Setup

## Harness scripts

| Script | Purpose |
|--------|---------|
| `scripts/symphony/install.sh` | Installs mise toolchain (Erlang/Elixir) and fetches Mix dependencies. |
| `scripts/symphony/start.sh` | Loads `.env.symphony.local`, validates config, and starts Symphony. Supports `SYMPHONY_VALIDATE_ONLY=1` for dry-run validation. |

## Environment

The local environment file `.env.symphony.local` (git-ignored) provides:

- `LINEAR_API_KEY` -- Linear personal API token.
- `LINEAR_PROJECT_SLUG` -- Linear project slug (`2010f66df8de`).

Copy `.env.symphony.local.example` and fill in your `LINEAR_API_KEY` to get started.

## Verification evidence

### install.sh

```
$ ./scripts/symphony/install.sh
mise trusted .../elixir
mise all tools are installed
Resolving Hex dependencies...
Resolution completed in 0.07s
...
install.sh completed successfully.
```

### start.sh (validate-only)

```
$ SYMPHONY_VALIDATE_ONLY=1 ./scripts/symphony/start.sh
Loaded environment from .../env.symphony.local
Validation passed.
  LINEAR_PROJECT_SLUG=2010f66df8de
  WORKFLOW.md project_slug=2010f66df8de
SYMPHONY_VALIDATE_ONLY=1; exiting after validation.
```

### WORKFLOW.md alignment

`elixir/WORKFLOW.md` `project_slug` updated from `symphony-0c79b11b75ea` to `2010f66df8de` to match `.env.symphony.local`.
