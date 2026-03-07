#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${SYMPHONY_ENV_FILE:-$REPO_ROOT/.env.symphony.local}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${LINEAR_API_KEY:?LINEAR_API_KEY is required. Set it in $ENV_FILE}"
FILTER="${1:-}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for this script." >&2
  exit 1
fi

read -r -d '' QUERY <<'GQL' || true
query ProjectSlugs {
  projects(first: 100) {
    nodes {
      name
      slugId
      state
    }
  }
}
GQL

payload="$(jq -n --arg q "$QUERY" '{query: $q}')"
response="$(curl -sS https://api.linear.app/graphql \
  -H "Authorization: ${LINEAR_API_KEY}" \
  -H "Content-Type: application/json" \
  --data "$payload")"

if [[ "$(echo "$response" | jq '.errors | length > 0')" == "true" ]]; then
  echo "$response" | jq -r '.errors[] | "Linear API error: \(.message)"' >&2
  exit 1
fi

echo -e "project_slug\tname\tstate"
if [[ -n "$FILTER" ]]; then
  filter_lc="$(printf '%s' "$FILTER" | tr '[:upper:]' '[:lower:]')"
  echo "$response" | jq -r --arg filter "$filter_lc" '
    .data.projects.nodes
    | map(select((.name | ascii_downcase | contains($filter)) or (.slugId | ascii_downcase | contains($filter))))
    | sort_by(.slugId)
    | .[]
    | [.slugId, .name, .state]
    | @tsv
  '
else
  echo "$response" | jq -r '
    .data.projects.nodes
    | sort_by(.slugId)
    | .[]
    | [.slugId, .name, .state]
    | @tsv
  '
fi
