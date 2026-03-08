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

fail() {
  echo "[fail] $*" >&2
  exit 1
}

require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "'$cmd' is required for preflight."
}

echo "[preflight] Symphony harness readiness check"
echo "[preflight] env_file=$ENV_FILE"

echo "[check] Required environment keys"
required_env_keys=(
  LINEAR_API_KEY
  LINEAR_PROJECT_SLUG
)

for key in "${required_env_keys[@]}"; do
  if [[ -z "${!key:-}" ]]; then
    fail "Missing required environment variable '$key' (set it in $ENV_FILE or the shell env)."
  fi
  echo "  [ok] $key is set"
done

require_command curl
require_command jq

echo "[check] Linear project reachability"
read -r -d '' QUERY <<'GQL' || true
query PreflightProject($slug: String!) {
  projects(filter: {slugId: {eq: $slug}}, first: 1) {
    nodes {
      name
      slugId
      state
    }
  }
}
GQL

payload="$(
  jq -n \
    --arg query "$QUERY" \
    --arg slug "$LINEAR_PROJECT_SLUG" \
    '{query: $query, variables: {slug: $slug}}'
)"

if ! response="$(curl -sS https://api.linear.app/graphql \
  -H "Authorization: ${LINEAR_API_KEY}" \
  -H "Content-Type: application/json" \
  --data "$payload")"; then
  fail "Failed to reach Linear API endpoint."
fi

if [[ "$(echo "$response" | jq '.errors | length > 0')" == "true" ]]; then
  error_message="$(
    echo "$response" | jq -r '.errors | map(.message) | join("; ")'
  )"
  fail "Linear API error: $error_message"
fi

project_json="$(echo "$response" | jq -c '.data.projects.nodes[0] // empty')"
if [[ -z "$project_json" ]]; then
  fail "No Linear project found for LINEAR_PROJECT_SLUG='$LINEAR_PROJECT_SLUG'."
fi

project_name="$(echo "$project_json" | jq -r '.name')"
project_slug="$(echo "$project_json" | jq -r '.slugId')"
project_state="$(echo "$project_json" | jq -r '.state')"
echo "  [ok] project reachable: $project_name ($project_slug, state=$project_state)"

echo "[check] Workflow validation"
if ! validation_output="$(SYMPHONY_VALIDATE_ONLY=1 "$SCRIPT_DIR/start.sh" 2>&1)"; then
  echo "$validation_output" >&2
  fail "Workflow validation failed."
fi

workflow_line="$(
  printf '%s\n' "$validation_output" | rg -m 1 'Workflow config valid|Validation complete:' || true
)"
if [[ -n "$workflow_line" ]]; then
  echo "  [ok] $workflow_line"
else
  echo "  [ok] workflow config validation completed"
fi

echo "[ready] Symphony harness preflight passed"
