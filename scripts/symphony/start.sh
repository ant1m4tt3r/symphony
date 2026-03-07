#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${SYMPHONY_ENV_FILE:-$REPO_ROOT/.env.symphony.local}"
TEMPLATE_FILE="${SYMPHONY_WORKFLOW_TEMPLATE:-$REPO_ROOT/.symphony/WORKFLOW.template.md}"
GENERATED_FILE="${SYMPHONY_WORKFLOW_FILE:-$REPO_ROOT/.symphony/WORKFLOW.generated.md}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${LINEAR_API_KEY:?LINEAR_API_KEY is required. Set it in $ENV_FILE}"
: "${LINEAR_PROJECT_SLUG:?LINEAR_PROJECT_SLUG is required. Set it in $ENV_FILE}"

SYMPHONY_HOME="${SYMPHONY_HOME:-$REPO_ROOT}"
SYMPHONY_DASHBOARD_PORT="${SYMPHONY_DASHBOARD_PORT:-4040}"
SYMPHONY_WORKSPACE_ROOT="${SYMPHONY_WORKSPACE_ROOT:-$REPO_ROOT/.symphony/workspaces}"
SYMPHONY_POLL_INTERVAL_MS="${SYMPHONY_POLL_INTERVAL_MS:-2000}"
SYMPHONY_MAX_CONCURRENT_AGENTS="${SYMPHONY_MAX_CONCURRENT_AGENTS:-1}"
SYMPHONY_MAX_TURNS="${SYMPHONY_MAX_TURNS:-8}"
SYMPHONY_ALLOW_AUTO_MERGE="${SYMPHONY_ALLOW_AUTO_MERGE:-0}"
SOURCE_REPO_URL="${SOURCE_REPO_URL:-$(git -C "$REPO_ROOT" remote get-url origin)}"
SYMPHONY_SYNC_FEEDBACK_SCRIPT="${SYMPHONY_SYNC_FEEDBACK_SCRIPT:-$REPO_ROOT/scripts/symphony/bin/sync_feedback.sh}"
DEFAULT_CODEX_COMMAND="codex --config shell_environment_policy.inherit=all --model gpt-5.3-codex app-server"
SYMPHONY_AI_ENGINE="${SYMPHONY_AI_ENGINE:-claude}"
SYMPHONY_AGENT_COMMAND="${SYMPHONY_AGENT_COMMAND:-}"
LEGACY_CODEX_COMMAND="${CODEX_COMMAND:-}"
SYMPHONY_GUARD_BIN_DIR="${SYMPHONY_GUARD_BIN_DIR:-$REPO_ROOT/scripts/symphony/bin}"

mkdir -p "$SYMPHONY_WORKSPACE_ROOT"
mkdir -p "$(dirname "$GENERATED_FILE")"

if [[ ! -x "$SYMPHONY_HOME/elixir/bin/symphony" ]]; then
  "$SCRIPT_DIR/install.sh"
fi

mkdir -p "$SYMPHONY_GUARD_BIN_DIR"

real_gh="$(command -v gh || true)"
if [[ -n "$real_gh" ]]; then
  export SYMPHONY_REAL_GH="$real_gh"
fi

real_git="$(command -v git || true)"
if [[ -n "$real_git" ]]; then
  export SYMPHONY_REAL_GIT="$real_git"
fi

export PATH="$SYMPHONY_GUARD_BIN_DIR:$PATH"

resolve_codex_command() {
  local command_in="${1:-}"
  local command_value="$command_in"

  if [[ -z "$command_value" ]]; then
    command_value="$DEFAULT_CODEX_COMMAND"
  fi

  # Resolve "codex" to an absolute binary path so app-server subprocesses do not
  # depend on the runtime PATH inside Symphony worker shells.
  if [[ "$command_value" == "codex" || "$command_value" == codex\ * ]]; then
    local codex_bin
    codex_bin="$(command -v codex || true)"

    if [[ -z "$codex_bin" && -x "/Applications/Codex.app/Contents/Resources/codex" ]]; then
      codex_bin="/Applications/Codex.app/Contents/Resources/codex"
    fi

    if [[ -z "$codex_bin" ]]; then
      echo "Unable to locate Codex CLI binary for command='$command_value'." >&2
      echo "Set SYMPHONY_AGENT_COMMAND (or CODEX_COMMAND) to an absolute path in $ENV_FILE." >&2
      exit 1
    fi

    command_value="${codex_bin}${command_value#codex}"
  fi

  printf '%s' "$command_value"
}

resolve_claude_command() {
  local command_in="${1:-}"

  if [[ -n "$command_in" ]]; then
    printf '%s' "$command_in"
    return 0
  fi

  if ! command -v claude >/dev/null 2>&1; then
    echo "Claude CLI not found in PATH." >&2
    echo "Install Claude Code CLI or set SYMPHONY_AGENT_COMMAND to an app-server-compatible command." >&2
    exit 1
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for Claude app-server shim." >&2
    exit 1
  fi

  local shim_path="$REPO_ROOT/scripts/symphony/bin/claude_app_server.py"
  if [[ ! -f "$shim_path" ]]; then
    echo "Claude app-server shim missing at $shim_path" >&2
    exit 1
  fi

  printf '%s' "python3 $shim_path"
}

resolve_opencode_command() {
  local command_in="${1:-}"

  if [[ -n "$command_in" ]]; then
    printf '%s' "$command_in"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required for OpenCode app-server shim." >&2
    exit 1
  fi

  local shim_path="$REPO_ROOT/scripts/symphony/bin/opencode_app_server.py"
  if [[ ! -f "$shim_path" ]]; then
    echo "OpenCode app-server shim missing at $shim_path" >&2
    exit 1
  fi

  printf '%s' "python3 $shim_path"
}

resolve_mixed_command() {
  local command_in="${1:-}"

  if [[ -n "$command_in" ]]; then
    printf '%s' "$command_in"
    return 0
  fi

  local router_path="$REPO_ROOT/scripts/symphony/bin/agent_router.sh"
  if [[ ! -x "$router_path" ]]; then
    echo "Mixed-agent router missing or not executable at $router_path" >&2
    exit 1
  fi

  printf '%s' "bash $router_path"
}

engine_normalized="$(printf '%s' "$SYMPHONY_AI_ENGINE" | tr '[:upper:]' '[:lower:]')"
AGENT_COMMAND=""

# Backward compatible: if CODEX_COMMAND is set and SYMPHONY_AGENT_COMMAND is not,
# preserve existing behavior for the codex engine only.
if [[ -z "$SYMPHONY_AGENT_COMMAND" && "$engine_normalized" == "codex" && -n "$LEGACY_CODEX_COMMAND" ]]; then
  SYMPHONY_AGENT_COMMAND="$LEGACY_CODEX_COMMAND"
fi

case "$engine_normalized" in
  codex)
    AGENT_COMMAND="$(resolve_codex_command "$SYMPHONY_AGENT_COMMAND")"
    ;;
  claude)
    use_codex_fallback=0

    if [[ -z "$SYMPHONY_AGENT_COMMAND" ]]; then
      claude_runtime_ok=1

      if ! command -v claude >/dev/null 2>&1; then
        claude_runtime_ok=0
      fi

      if ! command -v python3 >/dev/null 2>&1; then
        claude_runtime_ok=0
      fi

      if [[ ! -f "$REPO_ROOT/scripts/symphony/bin/claude_app_server.py" ]]; then
        claude_runtime_ok=0
      fi

      if [[ "$claude_runtime_ok" -eq 0 ]]; then
        echo "Claude runtime not fully available; falling back to Codex." >&2
        engine_normalized="codex"
        use_codex_fallback=1

        if [[ -z "$SYMPHONY_AGENT_COMMAND" && -n "$LEGACY_CODEX_COMMAND" ]]; then
          SYMPHONY_AGENT_COMMAND="$LEGACY_CODEX_COMMAND"
        fi
      fi
    fi

    if [[ "$use_codex_fallback" -eq 1 ]]; then
      AGENT_COMMAND="$(resolve_codex_command "$SYMPHONY_AGENT_COMMAND")"
    else
      AGENT_COMMAND="$(resolve_claude_command "$SYMPHONY_AGENT_COMMAND")"
    fi
    ;;
  opencode)
    AGENT_COMMAND="$(resolve_opencode_command "$SYMPHONY_AGENT_COMMAND")"
    ;;
  mixed)
    AGENT_COMMAND="$(resolve_mixed_command "$SYMPHONY_AGENT_COMMAND")"
    ;;
  *)
    if [[ -n "$SYMPHONY_AGENT_COMMAND" ]]; then
      AGENT_COMMAND="$SYMPHONY_AGENT_COMMAND"
    else
      echo "Unsupported SYMPHONY_AI_ENGINE='$SYMPHONY_AI_ENGINE' with no SYMPHONY_AGENT_COMMAND override." >&2
      exit 1
    fi
    ;;
esac

escape_for_sed() {
  printf '%s' "$1" | sed -e 's/[\\&|]/\\\\&/g'
}

normalize_bool() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
      printf '%s' "true"
      ;;
    *)
      printf '%s' "false"
      ;;
  esac
}

allow_unsafe_merge_push="$(normalize_bool "$SYMPHONY_ALLOW_AUTO_MERGE")"
slug_escaped="$(escape_for_sed "$LINEAR_PROJECT_SLUG")"
workspace_escaped="$(escape_for_sed "$SYMPHONY_WORKSPACE_ROOT")"
source_repo_escaped="$(escape_for_sed "$SOURCE_REPO_URL")"
agent_command_escaped="$(escape_for_sed "$AGENT_COMMAND")"
max_agents_escaped="$(escape_for_sed "$SYMPHONY_MAX_CONCURRENT_AGENTS")"
poll_interval_escaped="$(escape_for_sed "$SYMPHONY_POLL_INTERVAL_MS")"
max_turns_escaped="$(escape_for_sed "$SYMPHONY_MAX_TURNS")"
sync_feedback_script_escaped="$(escape_for_sed "$SYMPHONY_SYNC_FEEDBACK_SCRIPT")"
allow_unsafe_merge_push_escaped="$(escape_for_sed "$allow_unsafe_merge_push")"

sed \
  -e "s|__LINEAR_PROJECT_SLUG__|$slug_escaped|g" \
  -e "s|__SYMPHONY_WORKSPACE_ROOT__|$workspace_escaped|g" \
  -e "s|__POLL_INTERVAL_MS__|$poll_interval_escaped|g" \
  -e "s|__SOURCE_REPO_URL__|$source_repo_escaped|g" \
  -e "s|__SYNC_FEEDBACK_SCRIPT__|$sync_feedback_script_escaped|g" \
  -e "s|__AGENT_COMMAND__|$agent_command_escaped|g" \
  -e "s|__MAX_CONCURRENT_AGENTS__|$max_agents_escaped|g" \
  -e "s|__MAX_TURNS__|$max_turns_escaped|g" \
  -e "s|__ALLOW_UNSAFE_MERGE_PUSH__|$allow_unsafe_merge_push_escaped|g" \
  "$TEMPLATE_FILE" > "$GENERATED_FILE"

if [[ "${SYMPHONY_VALIDATE_ONLY:-0}" == "1" ]]; then
  cd "$SYMPHONY_HOME/elixir"
  mise exec -- mix run --no-start -e "SymphonyElixir.Workflow.set_workflow_file_path(\"$GENERATED_FILE\"); case SymphonyElixir.Config.validate!() do :ok -> IO.puts(\"Workflow config valid\") ; other -> IO.inspect(other); System.halt(1) end"
  echo "Validation complete: $GENERATED_FILE"
  exit 0
fi

echo "Starting Symphony dashboard on http://127.0.0.1:${SYMPHONY_DASHBOARD_PORT}"
echo "Workflow file: $GENERATED_FILE"
echo "AI engine: $engine_normalized"
echo "Agent command: $AGENT_COMMAND"

cd "$SYMPHONY_HOME/elixir"
mise exec -- ./bin/symphony "$GENERATED_FILE" \
  --port "$SYMPHONY_DASHBOARD_PORT" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
