#!/usr/bin/env bash
# tests/lib/human-env.sh — the HUMAN env fixture, DERIVED rather than copied.
#
# Four gate tests each carried a byte-identical `HUMAN=(env -u ZUVO_AGENT -u ZUVO_AI_RUN …)`
# array listing every variable that marks an agent (B-gate-8, filed when there were three
# copies). They had not drifted from each other yet, but nothing stopped them — and the same
# week, the two LIBRARY lists they mirror DID drift: pg_is_agent_env was missing ZUVO_AI_RUN
# and ANTIGRAVITY_SESSION_ID, which turned "human push exempt" into a live pre-push bypass
# (B-gate-2). A hardcoded fixture cannot notice that; it just keeps unsetting the old set and
# every test keeps passing.
#
# So this does not extract a fifth copy. It EXTRACTS THE NAMES FROM THE LIBRARIES, so a variable
# added to either detector is unset by every test automatically, and a fixture/library mismatch
# stops being a thing that can exist.
#
# Usage:
#   . "$ROOT/tests/lib/human-env.sh"      # defines HUMAN=(...)
#   "${HUMAN[@]}" bash -c '…'
#
# Falls back to the historical literal list if neither library is readable, so a test that runs
# against a partial checkout degrades to the old behaviour instead of silently unsetting nothing
# — which would make every "human bypass" assertion pass for the wrong reason.

_he_root="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)}"


# Names that must NEVER reach `env -u`, however they got extracted. The extraction is deliberately
# derived from the detector source rather than an allowlist — that is what keeps it from drifting
# when a new harness is added — but derivation means any uppercase token in those functions becomes
# an unset. A comment like `# must not modify PATH`, or a `$HOME` reference added later, would put
# PATH or HOME on the list and every subsequent test would fail cryptically, far from the cause.
# So the guard is a denylist of things whose absence breaks the shell itself, not an allowlist of
# vendors. Flagged as CRITICAL by adversarial review; verified LATENT today (the two detectors
# currently yield 15 clean vendor names and nothing else) and fixed before it becomes live.
_HE_NEVER_UNSET='PATH|HOME|USER|SHELL|TMPDIR|TMP|TEMP|LANG|LC_ALL|PWD|OLDPWD|TERM|SHLVL|IFS'

_he_names() {
  # Uppercase tokens inside the two detector functions. Both are scanned: they are deliberately
  # separate implementations (bash ${!var} vs POSIX), so the union is what "an agent env" means.
  {
    sed -n '/^pg_is_agent_env()/,/^}/p'  "$_he_root/hooks/lib/pipeline-gate-lib.sh" 2>/dev/null
    sed -n '/^_is_agent_env()/,/^}/p'    "$_he_root/hooks/lib/refactor-gate-lib.sh" 2>/dev/null
  } | grep -oE '\b[A-Z][A-Z0-9_]{3,}\b' | sort -u | grep -vxE "$_HE_NEVER_UNSET"
}

HUMAN=(env)
_he_count=0
while IFS= read -r _he_v; do
  [ -n "$_he_v" ] || continue
  HUMAN+=(-u "$_he_v")
  _he_count=$((_he_count + 1))
done < <(_he_names)

if [ "$_he_count" -lt 10 ]; then
  # Neither library readable (or unrecognisably changed) — fall back to the literal set this
  # fixture replaced, rather than shipping a HUMAN=(env) that unsets nothing.
  HUMAN=(env -u ZUVO_AGENT -u ZUVO_AI_RUN -u CLAUDECODE -u CLAUDE_PLUGIN_ROOT \
         -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION -u CODEX_SANDBOX -u CODEX_WORKSPACE \
         -u CODEX_HOME -u CURSOR_TRACE_ID -u CURSOR_AGENT -u GEMINI_CLI -u ANTIGRAVITY \
         -u GEMINI_ANTIGRAVITY -u ANTIGRAVITY_SESSION_ID)
  echo "  ! human-env: derived only $_he_count vars — using the literal fallback set" >&2
fi
unset _he_v _he_count _he_root
