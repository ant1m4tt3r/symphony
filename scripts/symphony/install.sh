#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SYMPHONY_HOME="${SYMPHONY_HOME:-$REPO_ROOT}"

if [[ ! -d "$SYMPHONY_HOME/elixir" ]]; then
  echo "Symphony source not found at: $SYMPHONY_HOME/elixir" >&2
  echo "Set SYMPHONY_HOME to your fork root if needed." >&2
  exit 1
fi

cd "$SYMPHONY_HOME/elixir"
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build

echo "Symphony built at: $SYMPHONY_HOME/elixir"
