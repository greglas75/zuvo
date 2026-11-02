"""Literal-only Codex invocation evidence; never execute transcript JavaScript.

This is deliberately not a JS interpreter. Straight-line calls with literal argument
objects, including Promise argument lists, are supported. Dynamic arguments, control flow,
callbacks, regexes and computed tools are unknown. Strings/comments cannot introduce call
sites. Counts prove invocation syntax, not successful execution or review completion.
"""
from __future__ import annotations

import json
import re
from typing import Any

UNSUPPORTED = "UnsupportedCodexEvidence"
Call = tuple[str, dict[str, Any]]
Token = tuple[str, str]
_WORD = re.compile(r"[A-Za-z_$][A-Za-z0-9_$]*|[0-9]+(?:\.[0-9]+)?")
_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "b": "\b", "f": "\f", "v": "\v", "0": "\0"}
_FLOW = {"if", "else", "for", "while", "do", "switch", "function", "return", "throw",
         "try", "catch", "class", "eval", "Function", "exit", "break", "continue",
         "globalThis", "self", "window", "global", "this"}


class UnsupportedSyntax(ValueError):
    """Evidence outside the supported static subset, with a payload-free diagnostic."""


def _string(source: str, offset: int) -> tuple[str, int]:
    quote = source[offset]
    offset += 1
    value: list[str] = []
    while offset < len(source):
        char = source[offset]
        offset += 1
        if char == quote:
            return "".join(value), offset
        if quote == "`" and char == "$" and source[offset:offset + 1] == "{":
            raise UnsupportedSyntax("interpolated JavaScript template")
        if char in "\r\n" and quote != "`":
            raise UnsupportedSyntax("unescaped newline in JavaScript string")
        if char != "\\":
            value.append(char)
            continue
        if offset == len(source):
            break
        escaped = source[offset]
        offset += 1
        if escaped in "\r\n":
            if escaped == "\r" and source[offset:offset + 1] == "\n": offset += 1
        elif escaped in _ESCAPES:
            value.append(_ESCAPES[escaped])
        elif escaped in "\\\"'`/":
            value.append(escaped)
        elif escaped in ("u", "x"):
            length = 4 if escaped == "u" else 2
            digits = source[offset:offset + length]
            if len(digits) != length or not re.fullmatch(r"[0-9a-fA-F]+", digits):
                raise UnsupportedSyntax("unsupported JavaScript string escape")
            value.append(chr(int(digits, 16)))
            offset += length
        else:
            raise UnsupportedSyntax("unsupported JavaScript string escape")
    raise UnsupportedSyntax("unterminated JavaScript string")


def _tokens(source: str) -> list[Token]:
    tokens: list[Token] = []
    offset = 0
    while offset < len(source):
        char = source[offset]
        if char.isspace():
            offset += 1
        elif source.startswith("//", offset):
            end = source.find("\n", offset)
            offset = len(source) if end < 0 else end + 1
        elif source.startswith("/*", offset):
            end = source.find("*/", offset + 2)
            if end < 0: raise UnsupportedSyntax("unterminated JavaScript comment")
            offset = end + 2
        elif char in "\"'`":
            value, offset = _string(source, offset)
            tokens.append(("string", value))
        elif not char.isascii():
            raise UnsupportedSyntax("non-ASCII JavaScript identifier or punctuation")
        elif char in "/\\":
            raise UnsupportedSyntax("regex, division or escaped identifier outside static subset")
        elif match := _WORD.match(source, offset):
            value = match.group()
            tokens.append(("number" if value[0].isdigit() else "word", value))
            offset = match.end()
        else:
            tokens.append(("punct", char))
            offset += 1
    return tokens


def _object(tokens: list[Token], offset: int) -> tuple[dict[str, str], int]:
    """Flat literal tool arguments; reject spreads/getters/overwrites or expressions."""
    if offset >= len(tokens) or tokens[offset] != ("punct", "{"):
        raise UnsupportedSyntax("tool arguments are not a literal object")
    values: dict[str, str] = {}
    offset += 1
    while offset < len(tokens) and tokens[offset] != ("punct", "}"):
        key = tokens[offset]
        if key[0] not in ("word", "string") or tokens[offset + 1:offset + 2] != [("punct", ":")]:
            raise UnsupportedSyntax("computed or nonliteral tool property")
        if key[1] in values: raise UnsupportedSyntax("duplicate tool property")
        offset += 2
        if offset >= len(tokens): raise UnsupportedSyntax("truncated tool arguments")
        kind, value = tokens[offset]
        if kind not in ("string", "number") and (kind, value) not in (
            ("word", "true"), ("word", "false"), ("word", "null")
        ):
            raise UnsupportedSyntax("dynamic tool argument")
        if key[1] in ("cmd", "task_name", "description", "chars") and kind != "string":
            raise UnsupportedSyntax("tool command or label is not a string literal")
        values[key[1]] = value
        offset += 1
        if tokens[offset:offset + 1] == [("punct", ",")]: offset += 1
        elif tokens[offset:offset + 1] != [("punct", "}")]:
            raise UnsupportedSyntax("tool argument expression outside static subset")
    if offset >= len(tokens): raise UnsupportedSyntax("unterminated tool arguments")
    return values, offset + 1


def _canonical(name: str, arguments: dict[str, Any]) -> Call | None:
    if name == "write_stdin":
        chars = arguments.get("chars", "")
        if not isinstance(chars, str): raise UnsupportedSyntax("unreadable stdin write")
        if chars:
            return UNSUPPORTED, {
                "scope": "adversarial", "reason": "nonempty stdin may invoke a shell command",
            }
        return None
    if name == "spawn_agent":
        return "Agent", {"description": arguments.get("task_name") or arguments.get("description") or ""}
    if not isinstance(arguments.get("cmd"), str):
        raise UnsupportedSyntax("exec_command has no readable cmd string")
    return "Bash", {"command": arguments["cmd"]}


def _javascript(source: str) -> list[Call]:
    tokens = _tokens(source)
    # Do not turn a never-called callback or a conditional/deferred call into evidence.
    if any(kind == "word" and value in _FLOW or kind == "punct" and value in "?&|"
           for kind, value in tokens) or any(
               tokens[i:i + 2] == [("punct", "="), ("punct", ">")]
               for i in range(len(tokens))):
        raise UnsupportedSyntax("control flow or deferred JavaScript calls")
    calls: list[Call] = []
    offset = 0
    braces = 0
    while offset < len(tokens):
        if tokens[offset] == ("punct", "{"): braces += 1
        elif tokens[offset] == ("punct", "}"):
            braces -= 1
            if braces < 0: raise UnsupportedSyntax("unbalanced JavaScript scope")
        if tokens[offset] != ("word", "tools"):
            offset += 1
            continue
        if braces:
            raise UnsupportedSyntax("tool reference inside an object, method or block scope")
        if (offset and tokens[offset - 1] == ("punct", ".")) or (
            tokens[offset + 1:offset + 2] != [("punct", ".")]
            or offset + 2 >= len(tokens)
        ):
            raise UnsupportedSyntax("computed, aliased or shadowed tools object")
        name = tokens[offset + 2][1]
        offset += 3
        if name not in ("exec_command", "spawn_agent", "write_stdin"):
            continue
        if tokens[offset:offset + 1] != [("punct", "(")]:
            raise UnsupportedSyntax("tool reference is not a direct call")
        arguments, offset = _object(tokens, offset + 1)
        if tokens[offset:offset + 1] != [("punct", ")")]:
            raise UnsupportedSyntax("tool call has unsupported trailing arguments")
        call = _canonical(name, arguments)
        if call is not None: calls.append(call)
        offset += 1
    if braces: raise UnsupportedSyntax("unbalanced JavaScript scope")
    return calls


def codex_calls(payload: dict[str, Any]) -> list[Call]:
    """Normalize supported Codex records or retain explicit unsupported evidence."""
    name = str(payload.get("name", "")).rsplit(".", 1)[-1]
    if name not in ("exec", "exec_command", "spawn_agent", "write_stdin"):
        return []
    scope = "both" if name == "exec" else "dispatch" if name == "spawn_agent" else "adversarial"
    body = payload.get("input") if payload.get("type") == "custom_tool_call" else payload.get("arguments")
    try:
        if name == "exec":
            if not isinstance(body, str): raise UnsupportedSyntax("unreadable JavaScript tool payload")
            return _javascript(body)
        arguments = json.loads(body) if isinstance(body, str) else body
        if not isinstance(arguments, dict): raise UnsupportedSyntax("unreadable Codex tool arguments")
        call = _canonical(name, arguments)
        return [call] if call is not None else []
    except (ValueError, RecursionError) as error:
        reason = str(error) if isinstance(error, UnsupportedSyntax) else "unreadable Codex tool arguments"
        return [(UNSUPPORTED, {"scope": scope, "reason": reason})]
