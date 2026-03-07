#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEFAULT_CODEX_COMMAND="codex --config shell_environment_policy.inherit=all --model gpt-5.3-codex app-server"

resolve_codex_command() {
  local command_in="${1:-}"
  local command_value="$command_in"

  if [[ -z "$command_value" ]]; then
    command_value="${CODEX_COMMAND:-$DEFAULT_CODEX_COMMAND}"
  fi

  if [[ "$command_value" == "codex" || "$command_value" == codex\ * ]]; then
    local codex_bin
    codex_bin="$(command -v codex || true)"

    if [[ -z "$codex_bin" && -x "/Applications/Codex.app/Contents/Resources/codex" ]]; then
      codex_bin="/Applications/Codex.app/Contents/Resources/codex"
    fi

    if [[ -z "$codex_bin" ]]; then
      return 1
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

  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  local shim_path="$SCRIPT_DIR/claude_app_server.py"
  if [[ ! -f "$shim_path" ]]; then
    return 1
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
    return 1
  fi

  local shim_path="$SCRIPT_DIR/opencode_app_server.py"
  if [[ ! -f "$shim_path" ]]; then
    return 1
  fi

  printf '%s' "python3 $shim_path"
}

command_for_engine() {
  local engine="$1"

  case "$engine" in
    codex)
      resolve_codex_command "${SYMPHONY_ROUTER_CODEX_COMMAND:-}"
      ;;
    claude)
      resolve_claude_command "${SYMPHONY_ROUTER_CLAUDE_COMMAND:-}"
      ;;
    opencode)
      resolve_opencode_command "${SYMPHONY_ROUTER_OPENCODE_COMMAND:-}"
      ;;
    *)
      return 1
      ;;
  esac
}

command_is_available() {
  local command="$1"
  local first

  first="$(awk '{print $1}' <<<"$command")"
  if [[ -z "$first" ]]; then
    return 1
  fi

  if [[ "$first" == */* ]]; then
    [[ -x "$first" ]]
  else
    command -v "$first" >/dev/null 2>&1
  fi
}

normalize_engine() {
  local raw="$1"
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

ROUTER_MAP_RAW="${SYMPHONY_AGENT_ROUTER_MAP:-codex:1,opencode:1}"
FALLBACK_ENGINE="$(normalize_engine "${SYMPHONY_AGENT_ROUTER_FALLBACK:-codex}")"

declare -a ENGINES=()
declare -a WEIGHTS=()
TOTAL_WEIGHT=0

IFS=',' read -r -a ENTRIES <<<"$ROUTER_MAP_RAW"
for entry in "${ENTRIES[@]}"; do
  token="$(normalize_engine "$entry")"
  [[ -z "$token" ]] && continue

  engine="${token%%:*}"
  weight_raw="${token#*:}"
  if [[ "$token" == "$engine" ]]; then
    weight_raw="1"
  fi

  if ! [[ "$weight_raw" =~ ^[0-9]+$ ]] || [[ "$weight_raw" -le 0 ]]; then
    continue
  fi

  ENGINES+=("$engine")
  WEIGHTS+=("$weight_raw")
  TOTAL_WEIGHT=$((TOTAL_WEIGHT + weight_raw))
done

if [[ "$TOTAL_WEIGHT" -le 0 ]]; then
  echo "[symphony-router] invalid SYMPHONY_AGENT_ROUTER_MAP='$ROUTER_MAP_RAW' (no positive weights)." >&2
  exit 1
fi

ISSUE_KEY="$(basename "$PWD")"
HASH_INPUT="$ISSUE_KEY"
if [[ -z "$HASH_INPUT" || "$HASH_INPUT" == "." ]]; then
  HASH_INPUT="$PWD"
fi

HASH_VALUE="$(cksum <<<"$HASH_INPUT" | awk '{print $1}')"
BUCKET=$((HASH_VALUE % TOTAL_WEIGHT))
SELECTED_ENGINE=""
ACC=0

for idx in "${!ENGINES[@]}"; do
  ACC=$((ACC + WEIGHTS[idx]))
  if [[ "$BUCKET" -lt "$ACC" ]]; then
    SELECTED_ENGINE="${ENGINES[idx]}"
    break
  fi
done

declare -a CANDIDATES=()
CANDIDATES+=("$SELECTED_ENGINE")

for engine in "${ENGINES[@]}"; do
  if [[ "$engine" != "$SELECTED_ENGINE" ]]; then
    CANDIDATES+=("$engine")
  fi
done

if [[ -n "$FALLBACK_ENGINE" ]]; then
  already_present=0
  for engine in "${CANDIDATES[@]}"; do
    if [[ "$engine" == "$FALLBACK_ENGINE" ]]; then
      already_present=1
      break
    fi
  done

  if [[ "$already_present" -eq 0 ]]; then
    CANDIDATES+=("$FALLBACK_ENGINE")
  fi
fi

CHOSEN_ENGINE=""
CHOSEN_COMMAND=""

for engine in "${CANDIDATES[@]}"; do
  cmd="$(command_for_engine "$engine" || true)"
  if [[ -z "$cmd" ]]; then
    continue
  fi

  if command_is_available "$cmd"; then
    CHOSEN_ENGINE="$engine"
    CHOSEN_COMMAND="$cmd"
    break
  fi
done

if [[ -z "$CHOSEN_COMMAND" ]]; then
  echo "[symphony-router] no available engine command from map='$ROUTER_MAP_RAW' fallback='$FALLBACK_ENGINE'." >&2
  exit 1
fi

if [[ "${SYMPHONY_ROUTER_DEBUG:-0}" == "1" ]]; then
  echo "[symphony-router] issue=${ISSUE_KEY:-unknown} selected=$CHOSEN_ENGINE map='$ROUTER_MAP_RAW' fallback='$FALLBACK_ENGINE'" >&2
fi
exec bash -lc "$CHOSEN_COMMAND"
