#!/usr/bin/env python3
"""Minimal Codex app-server protocol shim backed by Claude Code CLI."""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from queue import Empty, Queue
from typing import Any


def _emit(payload: dict[str, Any]) -> None:
    message = {"jsonrpc": "2.0"}
    message.update(payload)
    sys.stdout.write(json.dumps(message, ensure_ascii=True) + "\n")
    sys.stdout.flush()


def _emit_result(request_id: Any, result: dict[str, Any]) -> None:
    _emit({"id": request_id, "result": result})


def _emit_error(request_id: Any, code: int, message: str, data: Any = None) -> None:
    error_obj: dict[str, Any] = {"code": code, "message": message}
    if data is not None:
        error_obj["data"] = data
    _emit({"id": request_id, "error": error_obj})


def _emit_event(method: str, params: dict[str, Any] | None = None) -> None:
    payload: dict[str, Any] = {"method": method}
    if params is not None:
        payload["params"] = params
    _emit(payload)


def _emit_event_with_usage(method: str, params: dict[str, Any], usage: dict[str, Any]) -> None:
    payload: dict[str, Any] = {"method": method, "params": params, "usage": usage}
    _emit(payload)


def _extract_prompt(params: dict[str, Any]) -> str:
    items = params.get("input")
    if not isinstance(items, list):
        return ""

    chunks: list[str] = []
    for item in items:
        if not isinstance(item, dict):
            continue
        text = item.get("text")
        if isinstance(text, str) and text.strip():
            chunks.append(text)

    return "\n\n".join(chunks).strip()


def _claude_command(prompt: str, cwd: str) -> list[str]:
    binary = os.environ.get("CLAUDE_COMMAND", "claude")
    permission_mode = os.environ.get("CLAUDE_PERMISSION_MODE", "bypassPermissions")

    command = [
        binary,
        "--print",
        "--verbose",
        "--output-format",
        "stream-json",
        "--include-partial-messages",
        "--permission-mode",
        permission_mode,
    ]

    model = os.environ.get("CLAUDE_MODEL", "claude-opus-4-6").strip()
    if model:
        command.extend(["--model", model])

    disable_sounds = os.environ.get("CLAUDE_DISABLE_SOUNDS", "1").strip().lower()
    if disable_sounds not in {"0", "false", "no", "off"}:
        mute_settings = {"hooks": {"Notification": [], "Stop": []}}
        command.extend(["--settings", json.dumps(mute_settings, separators=(",", ":"))])

    mcp_config_override = os.environ.get("CLAUDE_MCP_CONFIG", "").strip()
    has_mcp_config = False
    if mcp_config_override:
        command.extend(["--mcp-config", mcp_config_override])
        has_mcp_config = True
    else:
        local_mcp = Path(cwd) / ".mcp.json"
        if local_mcp.is_file():
            command.extend(["--mcp-config", str(local_mcp)])
            has_mcp_config = True

    strict_mcp_config = os.environ.get("CLAUDE_STRICT_MCP_CONFIG", "1").strip().lower()
    if has_mcp_config and strict_mcp_config not in {"0", "false", "no", "off"}:
        command.append("--strict-mcp-config")

    extra_args = os.environ.get("CLAUDE_EXTRA_ARGS", "").strip()
    if extra_args:
        command.extend(shlex.split(extra_args))

    # `--mcp-config` accepts variadic values; use `--` so the prompt is
    # always parsed as the positional prompt argument, not another config.
    command.extend(["--", prompt])
    return command


def _extract_usage(payload: dict[str, Any]) -> dict[str, Any] | None:
    candidates: list[Any] = [
        payload.get("usage"),
        payload.get("event", {}).get("usage") if isinstance(payload.get("event"), dict) else None,
        payload.get("event", {}).get("message", {}).get("usage")
        if isinstance(payload.get("event"), dict) and isinstance(payload.get("event", {}).get("message"), dict)
        else None,
        payload.get("message", {}).get("usage") if isinstance(payload.get("message"), dict) else None,
    ]

    for candidate in candidates:
        if isinstance(candidate, dict):
            return candidate
    return None


def _extract_text_delta(payload: dict[str, Any]) -> str:
    payload_type = payload.get("type")

    if payload_type == "stream_event":
        event = payload.get("event")
        if not isinstance(event, dict):
            return ""

        if event.get("type") == "content_block_delta":
            delta = event.get("delta")
            if isinstance(delta, dict) and delta.get("type") == "text_delta":
                text = delta.get("text")
                if isinstance(text, str):
                    return text

    return ""


def _extract_mcp_init_summary(payload: dict[str, Any]) -> str:
    if payload.get("type") != "system" or payload.get("subtype") != "init":
        return ""

    mcp_servers = payload.get("mcp_servers")
    if not isinstance(mcp_servers, list) or not mcp_servers:
        return ""

    failed: list[str] = []
    needs_auth: list[str] = []
    connected: int = 0

    for server in mcp_servers:
        if not isinstance(server, dict):
            continue
        name = str(server.get("name", "")).strip() or "unknown"
        status = str(server.get("status", "")).strip().lower()

        if status == "connected":
            connected += 1
        elif status == "needs-auth":
            needs_auth.append(name)
        elif status:
            failed.append(f"{name}({status})")

    details: list[str] = [f"MCP init: {connected} connected"]
    if needs_auth:
        details.append(f"needs-auth: {', '.join(needs_auth)}")
    if failed:
        details.append(f"failed: {', '.join(failed)}")
    return "; ".join(details)


def _log_path_for_turn(cwd: str, turn_id: str) -> Path:
    log_dir = Path(cwd) / ".symphony" / "claude-logs"
    log_dir.mkdir(parents=True, exist_ok=True)
    return log_dir / f"{turn_id}.log"


def _stream_pipe(stream, source: str, queue: Queue) -> None:
    for line in iter(stream.readline, ""):
        queue.put((source, line))
    queue.put((source, None))


def _run_turn(turn_id: str, params: dict[str, Any]) -> None:
    prompt = _extract_prompt(params)
    if not prompt:
        _emit_event(
            "turn/failed",
            {"turnId": turn_id, "error": {"message": "turn/start missing text prompt input"}},
        )
        return

    cwd = params.get("cwd")
    if not isinstance(cwd, str) or not cwd:
        cwd = os.getcwd()

    command = _claude_command(prompt, cwd)
    command_preview = " ".join(shlex.quote(part) for part in command[:-1]) + " <PROMPT>"
    log_path = _log_path_for_turn(cwd, turn_id)

    _emit_event(
        "codex/event/exec_command_begin",
        {"turnId": turn_id, "msg": {"command": command_preview}},
    )
    _emit_event(
        "item/agentMessage/delta",
        {"turnId": turn_id, "delta": f"Claude turn started. Log: {log_path}"},
    )

    try:
        proc = subprocess.Popen(
            command,
            cwd=cwd,
            env=os.environ.copy(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
    except Exception as exc:  # pragma: no cover - fatal shell/runtime issues
        _emit_event(
            "turn/failed",
            {"turnId": turn_id, "error": {"message": f"claude invocation failed: {exc}"}},
        )
        return

    queue: Queue = Queue()
    stdout_thread = threading.Thread(target=_stream_pipe, args=(proc.stdout, "stdout", queue), daemon=True)
    stderr_thread = threading.Thread(target=_stream_pipe, args=(proc.stderr, "stderr", queue), daemon=True)
    stdout_thread.start()
    stderr_thread.start()

    completed_streams = 0
    stdout_lines: list[str] = []
    stderr_lines: list[str] = []
    next_heartbeat_at = time.monotonic() + 12.0
    last_activity_at = time.monotonic()
    no_output_timeout_sec_raw = os.environ.get("CLAUDE_NO_OUTPUT_TIMEOUT_SEC", "420").strip()
    try:
        no_output_timeout_sec = int(no_output_timeout_sec_raw)
    except ValueError:
        no_output_timeout_sec = 420

    mcp_summary_emitted = False
    stream_result_error: str | None = None

    with log_path.open("w", encoding="utf-8") as log_file:
        log_file.write(f"command: {command_preview}\n\n")
        log_file.flush()

        while completed_streams < 2:
            try:
                source, data = queue.get(timeout=1.0)
            except Empty:
                now = time.monotonic()

                if proc.poll() is None and no_output_timeout_sec > 0 and int(now - last_activity_at) >= no_output_timeout_sec:
                    try:
                        proc.kill()
                    except Exception:
                        pass

                    stalled_for = int(now - last_activity_at)
                    _emit_event(
                        "codex/event/exec_command_end",
                        {"turnId": turn_id, "msg": {"exit_code": -1}},
                    )
                    _emit_event(
                        "turn/failed",
                        {
                            "turnId": turn_id,
                            "error": {
                                "message": (
                                    f"Claude produced no output for {stalled_for}s and was stopped. "
                                    f"Likely stalled during startup/MCP init. See log: {log_path}"
                                ),
                                "exitCode": -1,
                            },
                        },
                    )
                    return

                if proc.poll() is None and now >= next_heartbeat_at:
                    silent_for = int(now - last_activity_at)
                    _emit_event(
                        "codex/event/agent_reasoning_delta",
                        {
                            "turnId": turn_id,
                            "delta": f"Claude turn still running (no stream output for {silent_for}s)...",
                        },
                    )
                    next_heartbeat_at = now + 12.0
                continue

            if data is None:
                completed_streams += 1
                continue

            last_activity_at = time.monotonic()
            line = data.rstrip("\n")
            if line == "":
                continue

            if source == "stdout":
                stdout_lines.append(line)
            else:
                stderr_lines.append(line)

            log_file.write(f"[{source}] {line}\n")
            log_file.flush()

            if source == "stdout":
                parsed: dict[str, Any] | None = None
                try:
                    decoded = json.loads(line)
                    if isinstance(decoded, dict):
                        parsed = decoded
                except json.JSONDecodeError:
                    parsed = None

                if parsed is not None:
                    usage = _extract_usage(parsed)
                    if usage is not None:
                        _emit_event_with_usage(
                            "thread/tokenUsage/updated",
                            {"turnId": turn_id, "usage": usage},
                            usage,
                        )

                    if not mcp_summary_emitted:
                        mcp_summary = _extract_mcp_init_summary(parsed)
                        if mcp_summary:
                            _emit_event("item/agentMessage/delta", {"turnId": turn_id, "delta": mcp_summary})
                            mcp_summary_emitted = True

                    text_delta = _extract_text_delta(parsed)
                    if text_delta:
                        _emit_event("item/agentMessage/delta", {"turnId": turn_id, "delta": text_delta})
                        _emit_event(
                            "item/commandExecution/outputDelta",
                            {"turnId": turn_id, "delta": text_delta, "stream": source},
                        )

                    if parsed.get("type") == "result" and parsed.get("is_error") is True:
                        result_text = parsed.get("result")
                        if isinstance(result_text, str) and result_text.strip():
                            stream_result_error = result_text.strip()
                        else:
                            stream_result_error = "Claude returned an error result."
                    continue

            _emit_event(
                "item/commandExecution/outputDelta",
                {"turnId": turn_id, "delta": line, "stream": source},
            )

    proc.wait()
    stdout_thread.join(timeout=0.2)
    stderr_thread.join(timeout=0.2)
    return_code = proc.returncode

    _emit_event(
        "codex/event/exec_command_end",
        {"turnId": turn_id, "msg": {"exit_code": return_code}},
    )

    if return_code == 0 and stream_result_error:
        _emit_event(
            "turn/failed",
            {"turnId": turn_id, "error": {"message": stream_result_error, "exitCode": return_code}},
        )
        return

    if return_code == 0:
        final_summary = "Claude turn completed successfully."
        _emit_event("item/agentMessage/delta", {"turnId": turn_id, "delta": final_summary})
        _emit_event("turn/completed", {"turnId": turn_id, "turn": {"status": "completed"}})
        return

    stderr = "\n".join(stderr_lines).strip()
    stdout = "\n".join(stdout_lines).strip()
    error_message = stderr or stdout or f"claude exited with code {return_code}"
    _emit_event(
        "turn/failed",
        {
            "turnId": turn_id,
            "error": {"message": error_message, "exitCode": return_code},
        },
    )


def main() -> int:
    thread_id = f"claude-thread-{uuid.uuid4().hex}"

    for raw in sys.stdin:
        line = raw.strip()
        if not line:
            continue

        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = message.get("method")
        request_id = message.get("id")

        if not isinstance(method, str):
            continue

        if method == "initialize":
            _emit_result(
                request_id,
                {
                    "serverInfo": {"name": "claude-app-server-shim", "version": "0.1.0"},
                    "capabilities": {"experimentalApi": True},
                },
            )
            continue

        if method == "initialized":
            continue

        if method == "thread/start":
            _emit_result(request_id, {"thread": {"id": thread_id}})
            continue

        if method == "turn/start":
            turn_id = f"claude-turn-{uuid.uuid4().hex}"
            _emit_result(request_id, {"turn": {"id": turn_id}})
            params = message.get("params")
            if not isinstance(params, dict):
                params = {}
            _run_turn(turn_id, params)
            continue

        _emit_error(request_id, -32601, f"Method not found: {method}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
