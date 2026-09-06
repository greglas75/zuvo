#!/bin/sh
# Shared harness markers. Presence detects an agent; it never grants permission.
zuvo_is_agent_env() {
  [ "${ZUVO_AGENT:-0}" = "1" ] && return 0
  [ -n "${ZUVO_AI_RUN:-}" ] && return 0
  [ -n "${CLAUDECODE:-}${CLAUDE_PLUGIN_ROOT:-}${CLAUDE_CODE_ENTRYPOINT:-}${CLAUDE_CODE_SESSION:-}" ] && return 0
  [ -n "${CODEX_SANDBOX:-}${CODEX_WORKSPACE:-}${CODEX_HOME:-}${CODEX_THREAD_ID:-}${CODEX_SESSION_ID:-}" ] && return 0
  [ -n "${CURSOR_TRACE_ID:-}${CURSOR_AGENT:-}" ] && return 0
  [ -n "${GEMINI_CLI:-}${ANTIGRAVITY:-}${GEMINI_ANTIGRAVITY:-}${ANTIGRAVITY_SESSION_ID:-}" ] && return 0
  return 1
}
