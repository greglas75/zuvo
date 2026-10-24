"""The one headless model call the review-learning helpers make: claude (`run_claude`) or codex
(`run_codex`); `run_model` picks the CLI from the model id.

Hygiene every scripted `claude -p` needs: `--strict-mcp-config` with an EMPTY server list (else the
CLI starts the user's MCP servers, orphaned when a call is killed); `--tools ""` (it never touches
files); `--no-session-persistence` and cwd /tmp, outside any repository, so no PROJECT CLAUDE.md is
pulled in (the user's own config still loads); its own process group, killed whole after EVERY call —
finished, failed, timed out or interrupted — so no child outlives it; UTF-8 on every pipe whatever the
locale (launchd often sets no LANG), an unencodable character (a lone surrogate) replaced, never fatal.
The prompt goes through stdin, never argv — diffs are large and argv is visible to `ps`.
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import signal
import subprocess
import tempfile
import time
from typing import Any, NamedTuple

CALL_TIMEOUT, ERROR_TAIL = 1800, 300
CLI_TAIL = 2000  # of stdout kept for a limit check: such text can arrive there, not as an envelope
MAX_OBJECT_STARTS = 64  # each `{` tried is one raw_decode: bounded however many braces prose holds
_PARSE_ERRORS = (ValueError, RecursionError, MemoryError)  # deep nesting raises the latter two


class ClaudeResult(NamedTuple):
    rc: int | None                 # None: did not start, or timed out
    answer: dict[str, Any] | None  # the JSON object in the model's reply; None on any failure
    usage: dict[str, Any]          # tokens_in, tokens_out, usd — empty when the CLI envelope is unreadable
    error: str                     # "" on success; "<ExceptionType>: …" or "exit <rc>: …"
    cli_error: str                 # stderr, an is_error result, non-envelope stdout: what a limit check reads
    secs: int


def claude_argv(model: str, effort: str) -> list[str]:
    return ["claude", "-p", "--model", model, "--effort", effort, "--output-format", "json", "--tools", "",
            "--mcp-config", '{"mcpServers":{}}', "--strict-mcp-config", "--no-session-persistence"]


def run_claude(prompt: str, model: str, effort: str, timeout: int = CALL_TIMEOUT,
               expect_keys: tuple[str, ...] = ()) -> ClaudeResult:
    """One call; any failure is in `.error`. With `expect_keys` only an object holding all of them is the
    answer. Only a non-Exception (Ctrl-C, SystemExit) propagates, after claude's group is killed."""
    t0 = time.monotonic()
    proc: subprocess.Popen[str] | None = None
    try:
        proc = subprocess.Popen(claude_argv(model, effort), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, encoding="utf-8", errors="replace", cwd="/tmp",
                                start_new_session=True)
        out, err = proc.communicate(prompt, timeout=timeout)
    except BaseException as ex:
        if proc is not None:
            _kill_group(proc)
        if not isinstance(ex, Exception):
            raise
        seen = f"{_partial(getattr(ex, 'stderr', None))} {_partial(getattr(ex, 'output', None))[-CLI_TAIL:]}"
        return ClaudeResult(None, None, {}, _err(ex), seen.strip(), round(time.monotonic() - t0))
    with contextlib.suppress(OSError):  # children the finished call left behind
        os.killpg(proc.pid, signal.SIGKILL)
    return _parse(proc.returncode, out or "", err or "", round(time.monotonic() - t0), expect_keys)


def run_model(prompt: str, model: str, effort: str, timeout: int = CALL_TIMEOUT,
              expect_keys: tuple[str, ...] = ()) -> ClaudeResult:
    """A claude-* model through claude, anything else (gpt-*) through codex."""
    run = run_claude if model.startswith("claude") else run_codex
    return run(prompt, model, effort, timeout=timeout, expect_keys=expect_keys)


def codex_argv() -> list[str]:
    """No shell, no exec, no image viewer, read-only sandbox: the prompt is everything it sees."""
    return ["codex", "exec", "--skip-git-repo-check", "--json", "-s", "read-only", "--disable", "shell_tool",
            "--disable", "unified_exec", "--disable", "view_image", "-"]


def _codex_home(model: str, effort: str) -> str:
    """A throwaway CODEX_HOME (mode 700): the account's auth.json copied (mode 600) from
    ${CODEX_HOME:-~/.codex} — read per call, so an account switch (cswap) takes effect on the next call —
    and a config naming only the model, effort, sandbox and approval: none of the user's MCP servers,
    profiles or instructions."""
    home = tempfile.mkdtemp(prefix="zuvo-codex.")
    try:
        src = os.path.join(os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex"), "auth.json")
        if os.path.isfile(src):
            dst = os.path.join(home, "auth.json")
            shutil.copyfile(src, dst)
            os.chmod(dst, 0o600)
        lines = [f"model = {json.dumps(model)}", 'sandbox_mode = "read-only"', 'approval_policy = "never"']
        if effort:
            lines.append(f"model_reasoning_effort = {json.dumps(effort)}")
        with open(os.path.join(home, "config.toml"), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
        os.mkdir(os.path.join(home, "cwd"))
    except BaseException:   # never leave the auth.json copy behind
        shutil.rmtree(home, ignore_errors=True)
        raise
    return home


def run_codex(prompt: str, model: str, effort: str, timeout: int = CALL_TIMEOUT,
              expect_keys: tuple[str, ...] = ()) -> ClaudeResult:
    """`run_claude`'s contract through `codex exec --json`, in an isolated CODEX_HOME removed after the call
    (it holds the auth.json copy) and its own process group, killed whole after every call."""
    t0 = time.monotonic()
    proc: subprocess.Popen[str] | None = None
    home = ""
    try:
        home = _codex_home(model, effort)
        proc = subprocess.Popen(codex_argv(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, encoding="utf-8", errors="replace",
                                cwd=os.path.join(home, "cwd"), env={**os.environ, "CODEX_HOME": home},
                                start_new_session=True)
        out, err = proc.communicate(prompt, timeout=timeout)
    except BaseException as ex:
        if proc is not None:
            _kill_group(proc)
        if home:
            shutil.rmtree(home, ignore_errors=True)
        if not isinstance(ex, Exception):
            raise
        seen = f"{_partial(getattr(ex, 'stderr', None))} {_partial(getattr(ex, 'output', None))[-CLI_TAIL:]}"
        return ClaudeResult(None, None, {}, _err(ex), seen.strip(), round(time.monotonic() - t0))
    with contextlib.suppress(OSError):
        os.killpg(proc.pid, signal.SIGKILL)
    shutil.rmtree(home, ignore_errors=True)
    return _parse_codex(proc.returncode, out or "", err or "", round(time.monotonic() - t0), expect_keys)


def _parse_codex(rc: int, out: str, err: str, secs: int, keys: tuple[str, ...]) -> ClaudeResult:
    """The JSONL event stream: the last agent_message is the reply, turn.completed carries the usage.
    `error` / `turn.failed` events and error items fail the call only when no usable reply came: codex
    reports a reconnect it recovered from as an `error` event too. A failed call's events and any
    non-JSON stdout go to cli_error, where a limit check reads them."""
    replies, usage, failures, prose = [], {}, [], []
    for line in out.splitlines():
        try:
            ev = json.loads(line)
        except _PARSE_ERRORS:
            prose.append(line)
            continue
        if not isinstance(ev, dict):
            continue
        item = ev.get("item")
        if ev.get("type") == "item.completed" and isinstance(item, dict):
            if item.get("type") == "agent_message":
                replies.append(str(item.get("text") or ""))
            elif item.get("type") == "error":
                failures.append(str(item.get("message") or item))
        elif ev.get("type") == "turn.completed" and isinstance(ev.get("usage"), dict):
            u = {k: v for k, v in ev["usage"].items() if isinstance(v, int) and not isinstance(v, bool)}
            usage = {"tokens_in": u.get("input_tokens", 0), "tokens_out": u.get("output_tokens", 0),
                     "usd": None}
        elif ev.get("type") in ("error", "turn.failed"):
            e = ev.get("error")
            failures.append(str(ev.get("message") or (e.get("message") if isinstance(e, dict) else e) or ev))
    text = "\n".join(replies)   # the verdict need not be the last message
    answer, error = None, ""
    try:
        answer = _first_object(text, keys)
    except _PARSE_ERRORS as ex:
        error = f"CLIError: {failures[-1][:ERROR_TAIL]}" if failures else \
            f"{_err(ex)} | {(text or err or out)[-ERROR_TAIL:]}"
    if rc != 0:
        error = f"exit {rc}: {error or (err or out)[-ERROR_TAIL:]}"
    cli_error = " ".join([err[-CLI_TAIL:], *failures, "\n".join(prose)[-CLI_TAIL:]]).strip() if error else ""
    return ClaudeResult(rc, None if error else answer, usage, error, cli_error, secs)


class CLIError(ValueError):
    """The CLI's own envelope reports a failed call (is_error, or an `error_*` subtype)."""


def _parse(rc: int, out: str, err: str, secs: int, keys: tuple[str, ...]) -> ClaudeResult:
    cli_error, usage, answer, error = err, {}, None, ""
    try:
        envelope = json.loads(out)
        if not isinstance(envelope, dict):
            raise ValueError("CLI output is not a JSON object")
    except _PARSE_ERRORS as ex:
        envelope, cli_error = {}, f"{err} {out[-CLI_TAIL:]}".strip()
        error = f"{_err(ex)} | {(err or out)[-ERROR_TAIL:]}"
    if not error:
        usage = _usage(envelope)
        result = envelope.get("result")
        text = json.dumps(result) if isinstance(result, (dict, list)) else str(result or "")
        try:
            subtype = envelope.get("subtype")
            if envelope.get("is_error") or (isinstance(subtype, str) and subtype.startswith("error")):
                cli_error += " " + text
                raise CLIError(f"{subtype or 'is_error'}: {text}")
            answer = _first_object(text, keys)
        except _PARSE_ERRORS as ex:
            error = f"{_err(ex)} | {(err or out)[-ERROR_TAIL:]}"
    if rc != 0:  # a crashed CLI may still print an envelope; its answer is not a judgement
        error = f"exit {rc}: {error or (err or out)[-ERROR_TAIL:]}"
    return ClaudeResult(rc, None if error else answer, usage, error, cli_error, secs)


def _first_object(text: str, keys: tuple[str, ...]) -> dict[str, Any]:
    """The reply as one JSON object, else the first object decoding at one of its `{` that holds every
    key in `keys`: prose, a fence, an example or a fragment around the answer does not count."""
    with contextlib.suppress(ValueError, RecursionError):
        whole = json.loads(text.strip())
        if isinstance(whole, dict) and all(k in whole for k in keys):
            return whole
    decoder = json.JSONDecoder()
    start = text.find("{")
    for _ in range(MAX_OBJECT_STARTS):
        if start < 0:
            break
        with contextlib.suppress(ValueError, RecursionError):
            obj, _end = decoder.raw_decode(text, start)
            if isinstance(obj, dict) and all(k in obj for k in keys):
                return obj
        start = text.find("{", start + 1)
    raise ValueError(f"no JSON object with keys {list(keys)}" if keys else "no JSON object in the reply")


def _usage(envelope: dict[str, Any]) -> dict[str, Any]:
    raw = envelope.get("usage")
    n = {k: v for k, v in (raw if isinstance(raw, dict) else {}).items()
         if isinstance(v, int) and not isinstance(v, bool)}
    ins = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
    return {"tokens_in": sum(n.get(k, 0) for k in ins), "tokens_out": n.get("output_tokens", 0),
            "usd": _usd(envelope.get("total_cost_usd"))}


def _usd(v: object) -> float | None:
    return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def _partial(stream: object) -> str:
    """Output a timed-out call already wrote: TimeoutExpired carries undecoded bytes even in text mode."""
    if isinstance(stream, bytes):
        return stream.decode("utf-8", errors="replace")
    return stream if isinstance(stream, str) else ""


def _kill_group(proc: subprocess.Popen[str]) -> None:
    """SIGKILL the whole session, close the pipes (a stray holder may never close them), reap; no raise."""
    with contextlib.suppress(OSError):
        os.killpg(proc.pid, signal.SIGKILL)
    with contextlib.suppress(OSError):
        proc.kill()
    for pipe in (proc.stdin, proc.stdout, proc.stderr):
        if pipe:
            with contextlib.suppress(OSError, ValueError):
                pipe.close()
    with contextlib.suppress(subprocess.TimeoutExpired):
        proc.wait(timeout=5)


def _err(ex: BaseException) -> str:
    return f"{type(ex).__name__}: {str(ex)[:200]}"
