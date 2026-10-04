#!/usr/bin/env bash
# Each supported harness marker must independently classify an agent run.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DETECTOR="$ROOT/hooks/lib/agent-env.sh"
fails=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }

probe() {
  env -i PATH="$PATH" "$1=$2" /bin/sh -c '. "$1"; zuvo_is_agent_env' _ "$DETECTOR"
}

echo '=== independent agent markers ==='
for marker in ZUVO_AGENT ZUVO_AI_RUN CLAUDECODE CLAUDE_PLUGIN_ROOT \
              CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION CODEX_SANDBOX \
              CODEX_WORKSPACE CODEX_HOME CODEX_THREAD_ID CODEX_SESSION_ID \
              CURSOR_TRACE_ID CURSOR_AGENT GEMINI_CLI ANTIGRAVITY \
              GEMINI_ANTIGRAVITY ANTIGRAVITY_SESSION_ID; do
  if probe "$marker" 1; then
    ok "$marker alone identifies an agent"
  else
    bad "$marker alone was classified as human"
  fi
done

echo '=== no marker means human ==='
if env -i PATH="$PATH" /bin/sh -c '. "$1"; zuvo_is_agent_env' _ "$DETECTOR"; then
  bad 'empty harness environment was classified as agent'
else
  ok 'empty harness environment is human'
fi

echo '=== RESULT ==='
[ "$fails" -eq 0 ] && { echo 'ALL PASS'; exit 0; }
echo "$fails FAILED"; exit 1
