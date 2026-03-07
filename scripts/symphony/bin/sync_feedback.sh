#!/usr/bin/env bash
set -euo pipefail

now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

mkdir -p .symphony

SYMPHONY_PR_COMMENT_LIMIT="${SYMPHONY_PR_COMMENT_LIMIT:-20}"
SYMPHONY_LINEAR_COMMENT_LIMIT="${SYMPHONY_LINEAR_COMMENT_LIMIT:-20}"
PR_FEEDBACK_SCHEMA_VERSION="v2"
LINEAR_FEEDBACK_SCHEMA_VERSION="v1"

sync_github_feedback() {
  local feedback_file state_file branch pr_number pr_meta_json pr_updated_at
  local state_key previous_state repo tmpdir

  feedback_file=".symphony/pr-feedback.md"
  state_file=".symphony/pr-feedback.state"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

  if ! command -v gh >/dev/null 2>&1 || [[ -z "$branch" || "$branch" == "main" ]]; then
    rm -f "$feedback_file" "$state_file"
    return 0
  fi

  pr_number="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || true)"
  if [[ -z "$pr_number" ]]; then
    rm -f "$feedback_file" "$state_file"
    return 0
  fi

  pr_meta_json="$(gh pr view "$pr_number" --json number,title,url,updatedAt,isDraft 2>/dev/null || true)"

  if command -v jq >/dev/null 2>&1; then
    pr_updated_at="$(printf '%s' "$pr_meta_json" | jq -r '.updatedAt // empty' 2>/dev/null || true)"
  else
    pr_updated_at="$(gh pr view "$pr_number" --json updatedAt --jq '.updatedAt' 2>/dev/null || true)"
  fi

  if [[ -z "$pr_meta_json" ]]; then
    rm -f "$feedback_file" "$state_file"
    return 0
  fi

  state_key="${PR_FEEDBACK_SCHEMA_VERSION}|${pr_number}|${pr_updated_at}"
  previous_state="$(cat "$state_file" 2>/dev/null || true)"

  if [[ -n "$pr_updated_at" && "$state_key" == "$previous_state" && -s "$feedback_file" ]]; then
    return 0
  fi

  repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  if [[ -z "$repo" ]]; then
    rm -f "$feedback_file" "$state_file"
    return 0
  fi

  tmpdir="$(mktemp -d .symphony/prsync.XXXXXX)"

  (
    gh api "repos/$repo/issues/$pr_number/comments?per_page=$SYMPHONY_PR_COMMENT_LIMIT&sort=updated&direction=desc" 2>/dev/null ||
      echo "[]"
  ) >"$tmpdir/issue_comments.json" &
  local pid_issue_comments=$!

  (
    gh api "repos/$repo/pulls/$pr_number/reviews?per_page=$SYMPHONY_PR_COMMENT_LIMIT" 2>/dev/null ||
      echo "[]"
  ) >"$tmpdir/reviews.json" &
  local pid_reviews=$!

  (
    gh api "repos/$repo/pulls/$pr_number/comments?per_page=$SYMPHONY_PR_COMMENT_LIMIT&sort=updated&direction=desc" 2>/dev/null ||
      echo "[]"
  ) >"$tmpdir/review_comments.json" &
  local pid_review_comments=$!

  (
    gh pr checks "$pr_number" 2>/dev/null || true
  ) >"$tmpdir/checks.txt" &
  local pid_checks=$!

  wait "$pid_issue_comments" "$pid_reviews" "$pid_review_comments" "$pid_checks" || true

  local issue_comments_output reviews_output review_comments_output

  if command -v jq >/dev/null 2>&1; then
    issue_comments_output="$(jq -c '[.[] | {id,author:(.user.login // ""),created_at,updated_at,body}]' "$tmpdir/issue_comments.json" 2>/dev/null || echo "[]")"
    reviews_output="$(jq -c '[.[] | {id,state,author:(.user.login // ""),submitted_at,body}]' "$tmpdir/reviews.json" 2>/dev/null || echo "[]")"
    review_comments_output="$(jq -c '[.[] | {id,author:(.user.login // ""),path,line,side,created_at,updated_at,body,in_reply_to_id,pull_request_review_id}]' "$tmpdir/review_comments.json" 2>/dev/null || echo "[]")"
  else
    issue_comments_output="$(cat "$tmpdir/issue_comments.json")"
    reviews_output="$(cat "$tmpdir/reviews.json")"
    review_comments_output="$(cat "$tmpdir/review_comments.json")"
  fi

  {
    echo "### PR metadata ($(now_utc))"
    printf '%s\n' "$pr_meta_json"
    echo ""
    echo "----"
    echo "### PR conversation comments (latest ${SYMPHONY_PR_COMMENT_LIMIT})"
    printf '%s\n' "$issue_comments_output"
    echo ""
    echo "----"
    echo "### PR reviews (latest ${SYMPHONY_PR_COMMENT_LIMIT})"
    printf '%s\n' "$reviews_output"
    echo ""
    echo "----"
    echo "### PR code review comments (latest ${SYMPHONY_PR_COMMENT_LIMIT})"
    printf '%s\n' "$review_comments_output"
    echo ""
    echo "----"
    echo "### PR checks snapshot ($(now_utc))"
    cat "$tmpdir/checks.txt"
  } >"$feedback_file"

  rm -rf "$tmpdir"

  if [[ -n "$pr_updated_at" ]]; then
    printf '%s\n' "$state_key" >"$state_file"
  else
    rm -f "$state_file"
  fi
}

sync_linear_feedback() {
  local feedback_file state_file issue_ref issue_number branch
  local state_key previous_state
  local meta_query meta_payload meta_response issue_updated_at
  local comments_query comments_payload comments_response issue_json

  feedback_file=".symphony/linear-feedback.md"
  state_file=".symphony/linear-feedback.state"

  if [[ -z "${LINEAR_API_KEY:-}" || -z "${LINEAR_PROJECT_SLUG:-}" ]]; then
    rm -f "$feedback_file" "$state_file"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    rm -f "$feedback_file" "$state_file"
    return 0
  fi

  issue_ref="${SYMPHONY_ISSUE_IDENTIFIER:-$(basename "$PWD")}"
  issue_number=""

  if [[ "$issue_ref" =~ -([0-9]+)$ ]]; then
    issue_number="${BASH_REMATCH[1]}"
  else
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ "$branch" =~ ([A-Za-z]+-[0-9]+) ]]; then
      issue_ref="${BASH_REMATCH[1]}"
    fi

    if [[ "$issue_ref" =~ -([0-9]+)$ ]]; then
      issue_number="${BASH_REMATCH[1]}"
    fi
  fi

  if [[ -z "$issue_number" ]]; then
    rm -f "$feedback_file" "$state_file"
    return 0
  fi

  read -r -d '' meta_query <<'GRAPHQL' || true
query SymphonyLinearIssueMeta($slug: String!, $number: Float!) {
  issues(filter: {project: {slugId: {eq: $slug}}, number: {eq: $number}}, first: 1) {
    nodes {
      id
      identifier
      title
      url
      updatedAt
    }
  }
}
GRAPHQL

  meta_payload="$(jq -nc \
    --arg query "$meta_query" \
    --arg slug "$LINEAR_PROJECT_SLUG" \
    --argjson number "$issue_number" \
    '{query:$query,variables:{slug:$slug,number:$number}}')"

  meta_response="$(
    curl -sS \
      --connect-timeout 3 \
      --max-time 10 \
      https://api.linear.app/graphql \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "$meta_payload" ||
      true
  )"

  issue_updated_at="$(printf '%s' "$meta_response" | jq -r '.data.issues.nodes[0].updatedAt // empty' 2>/dev/null || true)"
  if [[ -z "$issue_updated_at" ]]; then
    rm -f "$feedback_file" "$state_file"
    return 0
  fi

  state_key="${LINEAR_FEEDBACK_SCHEMA_VERSION}|${issue_ref}|${issue_updated_at}"
  previous_state="$(cat "$state_file" 2>/dev/null || true)"

  if [[ "$state_key" == "$previous_state" && -s "$feedback_file" ]]; then
    return 0
  fi

  read -r -d '' comments_query <<'GRAPHQL' || true
query SymphonyLinearIssueComments($slug: String!, $number: Float!, $first: Int!) {
  issues(filter: {project: {slugId: {eq: $slug}}, number: {eq: $number}}, first: 1) {
    nodes {
      id
      identifier
      title
      url
      updatedAt
      comments(first: $first) {
        nodes {
          id
          body
          createdAt
          updatedAt
          user {
            name
            displayName
          }
        }
      }
    }
  }
}
GRAPHQL

  comments_payload="$(jq -nc \
    --arg query "$comments_query" \
    --arg slug "$LINEAR_PROJECT_SLUG" \
    --argjson number "$issue_number" \
    --argjson first "$SYMPHONY_LINEAR_COMMENT_LIMIT" \
    '{query:$query,variables:{slug:$slug,number:$number,first:$first}}')"

  comments_response="$(
    curl -sS \
      --connect-timeout 3 \
      --max-time 10 \
      https://api.linear.app/graphql \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "$comments_payload" ||
      true
  )"

  issue_json="$(printf '%s' "$comments_response" | jq -c '.data.issues.nodes[0] // empty' 2>/dev/null || true)"
  if [[ -z "$issue_json" || "$issue_json" == "null" ]]; then
    rm -f "$feedback_file" "$state_file"
    return 0
  fi

  {
    echo "### Linear issue snapshot ($(now_utc))"
    printf '%s\n' "$issue_json"
  } >"$feedback_file"

  printf '%s\n' "$state_key" >"$state_file"
}

sync_github_feedback &
gh_pid=$!

sync_linear_feedback &
linear_pid=$!

wait "$gh_pid" "$linear_pid" || true
