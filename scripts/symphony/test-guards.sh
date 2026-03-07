#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GIT_WRAPPER="$REPO_ROOT/scripts/symphony/bin/git"
GH_WRAPPER="$REPO_ROOT/scripts/symphony/bin/gh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_GIT_LOG="$TMP_DIR/fake_git.log"
FAKE_GH_LOG="$TMP_DIR/fake_gh.log"
touch "$FAKE_GIT_LOG" "$FAKE_GH_LOG"

cat > "$TMP_DIR/fake_git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${FAKE_GIT_LOG:?}"
printf '%s\n' "$*" >> "$log_file"

if [[ "${1:-}" == "rev-parse" && "${2:-}" == "--abbrev-ref" && "${3:-}" == "HEAD" ]]; then
  printf '%s\n' "${FAKE_GIT_BRANCH:-feature/test}"
  exit 0
fi

if [[ "${1:-}" == "push" ]]; then
  exit 0
fi

exit 0
EOF
chmod +x "$TMP_DIR/fake_git"

cat > "$TMP_DIR/fake_gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log_file="${FAKE_GH_LOG:?}"
printf '%s\n' "$*" >> "$log_file"
exit 0
EOF
chmod +x "$TMP_DIR/fake_gh"

failures=0

run_and_capture() {
  local out_file="$1"
  shift

  set +e
  "$@" > "$out_file" 2>&1
  local status=$?
  set -e

  printf '%s' "$status"
}

assert_exit() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [[ "$expected" != "$actual" ]]; then
    echo "FAIL: $label (expected exit $expected, got $actual)"
    failures=$((failures + 1))
  else
    echo "PASS: $label"
  fi
}

assert_contains() {
  local needle="$1"
  local haystack_file="$2"
  local label="$3"

  if grep -Fq -- "$needle" "$haystack_file"; then
    echo "PASS: $label"
  else
    echo "FAIL: $label"
    failures=$((failures + 1))
  fi
}

assert_not_contains() {
  local needle="$1"
  local haystack_file="$2"
  local label="$3"

  if grep -Fq -- "$needle" "$haystack_file"; then
    echo "FAIL: $label"
    failures=$((failures + 1))
  else
    echo "PASS: $label"
  fi
}

git_missing_out="$TMP_DIR/git_missing.out"
status="$(run_and_capture "$git_missing_out" "$GIT_WRAPPER" status)"
assert_exit 127 "$status" "git wrapper requires SYMPHONY_REAL_GIT"
assert_contains "missing real git binary" "$git_missing_out" "git wrapper missing-binary error is actionable"

git_push_main_out="$TMP_DIR/git_push_main.out"
status="$(
  run_and_capture \
    "$git_push_main_out" \
    env \
      SYMPHONY_REAL_GIT="$TMP_DIR/fake_git" \
      FAKE_GIT_LOG="$FAKE_GIT_LOG" \
      "$GIT_WRAPPER" push origin main
)"
assert_exit 43 "$status" "git wrapper blocks direct push refspec to main"
assert_contains "blocked: pushing to 'main' is disabled" "$git_push_main_out" "git wrapper emits policy message for main push"

git_push_head_main_out="$TMP_DIR/git_push_head_main.out"
status="$(
  run_and_capture \
    "$git_push_head_main_out" \
    env \
      SYMPHONY_REAL_GIT="$TMP_DIR/fake_git" \
      FAKE_GIT_LOG="$FAKE_GIT_LOG" \
      "$GIT_WRAPPER" push origin HEAD:main
)"
assert_exit 43 "$status" "git wrapper blocks HEAD:main refspec"

git_push_no_refspec_main_branch_out="$TMP_DIR/git_push_no_refspec_main_branch.out"
status="$(
  run_and_capture \
    "$git_push_no_refspec_main_branch_out" \
    env \
      SYMPHONY_REAL_GIT="$TMP_DIR/fake_git" \
      FAKE_GIT_LOG="$FAKE_GIT_LOG" \
      FAKE_GIT_BRANCH="main" \
      "$GIT_WRAPPER" push origin
)"
assert_exit 43 "$status" "git wrapper blocks push with no refspec when current branch is main"

git_push_feature_out="$TMP_DIR/git_push_feature.out"
status="$(
  run_and_capture \
    "$git_push_feature_out" \
    env \
      SYMPHONY_REAL_GIT="$TMP_DIR/fake_git" \
      FAKE_GIT_LOG="$FAKE_GIT_LOG" \
      FAKE_GIT_BRANCH="feature/hug-11" \
      "$GIT_WRAPPER" push origin HEAD:refs/heads/feature/hug-11
)"
assert_exit 0 "$status" "git wrapper allows feature-branch push refspec"
assert_not_contains "blocked: pushing to 'main'" "$git_push_feature_out" "feature-branch push is not blocked"
assert_contains "push origin HEAD:refs/heads/feature/hug-11" "$FAKE_GIT_LOG" "git wrapper forwards allowed push to real git"

gh_missing_out="$TMP_DIR/gh_missing.out"
status="$(run_and_capture "$gh_missing_out" "$GH_WRAPPER" pr view 1)"
assert_exit 127 "$status" "gh wrapper requires SYMPHONY_REAL_GH"
assert_contains "missing real gh binary" "$gh_missing_out" "gh wrapper missing-binary error is actionable"

gh_pr_merge_out="$TMP_DIR/gh_pr_merge.out"
status="$(
  run_and_capture \
    "$gh_pr_merge_out" \
    env \
      SYMPHONY_ALLOW_AUTO_MERGE=0 \
      SYMPHONY_REAL_GH="$TMP_DIR/fake_gh" \
      FAKE_GH_LOG="$FAKE_GH_LOG" \
      "$GH_WRAPPER" pr merge 123 --squash
)"
assert_exit 42 "$status" "gh wrapper blocks gh pr merge"
assert_contains "automated PR merges are disabled" "$gh_pr_merge_out" "gh wrapper emits policy message for gh pr merge"

gh_api_merge_out="$TMP_DIR/gh_api_merge.out"
status="$(
  run_and_capture \
    "$gh_api_merge_out" \
    env \
      SYMPHONY_ALLOW_AUTO_MERGE=0 \
      SYMPHONY_REAL_GH="$TMP_DIR/fake_gh" \
      FAKE_GH_LOG="$FAKE_GH_LOG" \
      "$GH_WRAPPER" api repos/owner/repo/pulls/123/merge -X PUT
)"
assert_exit 42 "$status" "gh wrapper blocks merge API endpoint"

gh_pr_merge_allowed_out="$TMP_DIR/gh_pr_merge_allowed.out"
status="$(
  run_and_capture \
    "$gh_pr_merge_allowed_out" \
    env \
      SYMPHONY_ALLOW_AUTO_MERGE=1 \
      SYMPHONY_REAL_GH="$TMP_DIR/fake_gh" \
      FAKE_GH_LOG="$FAKE_GH_LOG" \
      "$GH_WRAPPER" pr merge 456 --squash
)"
assert_exit 0 "$status" "gh wrapper allows gh pr merge when auto-merge is enabled"
assert_contains "pr merge 456 --squash" "$FAKE_GH_LOG" "gh wrapper forwards merge command when auto-merge is enabled"

gh_api_merge_allowed_out="$TMP_DIR/gh_api_merge_allowed.out"
status="$(
  run_and_capture \
    "$gh_api_merge_allowed_out" \
    env \
      SYMPHONY_ALLOW_AUTO_MERGE=true \
      SYMPHONY_REAL_GH="$TMP_DIR/fake_gh" \
      FAKE_GH_LOG="$FAKE_GH_LOG" \
      "$GH_WRAPPER" api repos/owner/repo/pulls/456/merge -X PUT
)"
assert_exit 0 "$status" "gh wrapper allows merge API endpoint when auto-merge is enabled"
assert_contains "api repos/owner/repo/pulls/456/merge -X PUT" "$FAKE_GH_LOG" "gh wrapper forwards API merge when auto-merge is enabled"

gh_pr_view_out="$TMP_DIR/gh_pr_view.out"
status="$(
  run_and_capture \
    "$gh_pr_view_out" \
    env \
      SYMPHONY_REAL_GH="$TMP_DIR/fake_gh" \
      FAKE_GH_LOG="$FAKE_GH_LOG" \
      "$GH_WRAPPER" pr view 123
)"
assert_exit 0 "$status" "gh wrapper allows non-merge gh commands"
assert_contains "pr view 123" "$FAKE_GH_LOG" "gh wrapper forwards allowed command to real gh"

if [[ "$failures" -gt 0 ]]; then
  echo
  echo "Guard regression tests failed: $failures"
  exit 1
fi

echo
echo "All guard regression tests passed."
