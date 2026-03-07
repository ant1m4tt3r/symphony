#!/usr/bin/env bash
# Harness start script for Symphony (Elixir reference implementation).
# Loads .env.symphony.local, validates config, and optionally starts the service.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
project_root="$repo_root/elixir"
env_file="$repo_root/.env.symphony.local"

# --- Load env file ---
if [ -f "$env_file" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$env_file"
  set +a
  echo "Loaded environment from $env_file"
else
  echo "Warning: $env_file not found; using existing environment." >&2
fi

# --- Validate required environment ---
errors=0

if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "Error: LINEAR_API_KEY is not set." >&2
  errors=$((errors + 1))
fi

if [ -z "${LINEAR_PROJECT_SLUG:-}" ]; then
  echo "Error: LINEAR_PROJECT_SLUG is not set." >&2
  errors=$((errors + 1))
fi

if [ "$errors" -gt 0 ]; then
  echo "Validation failed with $errors error(s)." >&2
  exit 1
fi

# --- Validate toolchain ---
if ! command -v mise >/dev/null 2>&1; then
  echo "Error: mise is not installed. Run scripts/symphony/install.sh first." >&2
  exit 1
fi

cd "$project_root"

if ! mise exec -- elixir --version >/dev/null 2>&1; then
  echo "Error: Elixir toolchain not available. Run scripts/symphony/install.sh first." >&2
  exit 1
fi

# --- Validate WORKFLOW.md project_slug matches env ---
workflow_slug=$(grep 'project_slug:' "$project_root/WORKFLOW.md" | head -1 | sed 's/.*project_slug:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/')
if [ "$workflow_slug" != "$LINEAR_PROJECT_SLUG" ]; then
  echo "Error: WORKFLOW.md project_slug ($workflow_slug) does not match LINEAR_PROJECT_SLUG ($LINEAR_PROJECT_SLUG)." >&2
  exit 1
fi

echo "Validation passed."
echo "  LINEAR_PROJECT_SLUG=$LINEAR_PROJECT_SLUG"
echo "  WORKFLOW.md project_slug=$workflow_slug"

# --- Validate-only mode ---
if [ "${SYMPHONY_VALIDATE_ONLY:-0}" = "1" ]; then
  echo "SYMPHONY_VALIDATE_ONLY=1; exiting after validation."
  exit 0
fi

# --- Start Symphony ---
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md "$@"
