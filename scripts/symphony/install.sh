#!/usr/bin/env bash
# Harness install script for Symphony (Elixir reference implementation).
# Installs mise toolchain and project dependencies.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
project_root="$repo_root/elixir"

# --- mise ---
if ! command -v mise >/dev/null 2>&1; then
  echo "mise is required. Install it from https://mise.jdx.dev/getting-started.html" >&2
  exit 1
fi

cd "$project_root"
mise trust
mise install

# --- Elixir dependencies ---
mise exec -- mix local.hex --force --if-missing
mise exec -- mix local.rebar --force --if-missing
mise exec -- mix deps.get

echo "install.sh completed successfully."
