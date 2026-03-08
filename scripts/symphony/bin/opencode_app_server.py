#!/usr/bin/env python3
"""Codex app-server protocol shim backed by OpenCode CLI."""

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


def _opencode_command(prompt: str) -> list[str]:
    binary = os.environ.get("OPENCODE_COMMAND", "opencode").strip() or "opencode"
    command = [binary, "run", "--format", "json"]

    model = os.environ.get("OPENCODE_MODEL", "").strip()
    if model:
        command.extend(["--model", model])

    agent = os.environ.get("OPENCODE_AGENT", "").strip()
    if agent:
        command.extend(["--agent", agent])

    extra_args = os.environ.get("OPENCODE_EXTRA_ARGS", "").strip()
    if extra_args:
        command.extend(shlex.split(extra_args))

    command.extend(["--", prompt])
    return command


def _extract_usage(payload: dict[str, Any]) -> dict[str, Any] | None:
    part = payload.get("part")
    if not isinstance(part, dict):
        return None

    tokens = part.get("tokens")
    if isinstance(tokens, dict):
        return tokens

    return None


def _extract_text_delta(payload: dict[str, Any]) -> str:
    if payload.get("type") != "text":
        return ""

    part = payload.get("part")
    if not isinstance(part, dict):
        return ""

    text = part.get("text")
    if isinstance(text, str):
        return text

    return ""


def _log_path_for_turn(cwd: str, turn_id: str) -> Path:
    log_dir = Path(cwd) / ".symphony" / "opencode-logs"
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

    command = _opencode_command(prompt)
    command_preview = " ".join(shlex.quote(part) for part in command[:-1]) + " <PROMPT>"
    log_path = _log_path_for_turn(cwd, turn_id)

    _emit_event(
        "codex/event/exec_command_begin",
        {"turnId": turn_id, "msg": {"command": command_preview}},
    )
    _emit_event(
        "item/agentMessage/delta",
        {"turnId": turn_id, "delta": f"OpenCode turn started. Log: {log_path}"},
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
    except Exception as exc:  # pragma: no cover
        _emit_event(
            "turn/failed",
            {"turnId": turn_id, "error": {"message": f"opencode invocation failed: {exc}"}},
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
    no_output_timeout_raw = os.environ.get("OPENCODE_NO_OUTPUT_TIMEOUT_SEC", "420").strip()
    try:
        no_output_timeout_sec = int(no_output_timeout_raw)
    except ValueError:
        no_output_timeout_sec = 420

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
                                    f"OpenCode produced no output for {stalled_for}s and was stopped. "
                                    f"See log: {log_path}"
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
                            "delta": f"OpenCode turn still running (no stream output for {silent_for}s)...",
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

                    text_delta = _extract_text_delta(parsed)
                    if text_delta:
                        _emit_event("item/agentMessage/delta", {"turnId": turn_id, "delta": text_delta})
                        _emit_event(
                            "item/commandExecution/outputDelta",
                            {"turnId": turn_id, "delta": text_delta, "stream": source},
                        )

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

    if return_code == 0:
        _emit_event("item/agentMessage/delta", {"turnId": turn_id, "delta": "OpenCode turn completed successfully."})
        _emit_event("turn/completed", {"turnId": turn_id, "turn": {"status": "completed"}})
        return

    stderr = "\n".join(stderr_lines).strip()
    stdout = "\n".join(stdout_lines).strip()
    error_message = stderr or stdout or f"opencode exited with code {return_code}"
    _emit_event(
        "turn/failed",
        {
            "turnId": turn_id,
            "error": {"message": error_message, "exitCode": return_code},
        },
    )


def main() -> int:
    thread_id = f"opencode-thread-{uuid.uuid4().hex}"

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
                    "serverInfo": {"name": "opencode-app-server-shim", "version": "0.1.0"},
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
            turn_id = f"opencode-turn-{uuid.uuid4().hex}"
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
