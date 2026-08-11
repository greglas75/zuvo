#!/usr/bin/env bash
#
# reviewer-preflight.sh — cheap canary for the write-tests review infrastructure.
#
# Run this BEFORE writing any test. It answers one question early: "will the
# blind coverage audit be able to run at the end of this pipeline?" — so a
# broken reviewer route / missing client / dead model is surfaced up front
# (run marked DRAFT/BLOCKED_INFRA from the start) instead of after an hour of
# test writing, which is how the `supports_reasoning_summaries` failure
# invalidated a finished run.
#
# Checks, in order (cheapest first):
#   1. routing   — reviewer-model-route.sh resolves the 6-key contract in <=5s
#   2. client    — a non-writer audit client (codex|gemini|claude) is on PATH,
#                  applying the same host-exclusion rule as blind-audit-codex.sh
#   3. canary    — OPTIONAL real model round-trip: trivial prompt must echo the
#                  marker ZUVO_PREFLIGHT_OK within $ZUVO_PREFLIGHT_TIMEOUT (60s).
#                  Skipped with --no-canary or ZUVO_PREFLIGHT_NO_CANARY=1
#                  (routing+client alone already catch the common failures).
#
# Output: KEY=VALUE lines (stable contract, one per line):
#   preflight_status=ok|degraded-routing|no-provider|canary-failed
#   provider=<codex|gemini|claude|none>
#   + the six reviewer-model-route.sh keys, passed through
#
# Exit codes:
#   0  review infrastructure reachable (status ok OR degraded-routing —
#      degraded routing still permits a same-model-fallback audit)
#   1  review infrastructure unavailable (no-provider / canary-failed) —
#      caller must mark the run BLOCKED_INFRA from the start
#   2  usage error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROUTE_SCRIPT="$SCRIPT_DIR/reviewer-model-route.sh"
CANARY=1
TIMEOUT_SECONDS="${ZUVO_PREFLIGHT_TIMEOUT:-60}"
[ "${ZUVO_PREFLIGHT_NO_CANARY:-0}" = "1" ] && CANARY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --no-canary) CANARY=0; shift ;;
    --canary) CANARY=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2 ;;
  esac
done

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$TIMEOUT_SECONDS" -le 0 ]; then
  echo "Invalid ZUVO_PREFLIGHT_TIMEOUT: $TIMEOUT_SECONDS" >&2
  exit 2
fi

run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    "$@"
  fi
}

emit_and_exit() {
  # emit_and_exit <status> <provider> <exit-code> [route-output]
  local status="$1" provider="$2" code="$3" route="${4:-}"
  printf 'preflight_status=%s\n' "$status"
  printf 'provider=%s\n' "$provider"
  if [ -n "$route" ]; then
    printf '%s\n' "$route"
  else
    printf 'platform=unknown\nwriter_model=unknown\nwriter_lane=unknown\n'
    printf 'reviewer_lane=same-model-fallback\nreviewer_model=unknown\nrouting_status=routing-failed\n'
  fi
  exit "$code"
}

# ── 1. routing ────────────────────────────────────────────────────────────────
ROUTE_OUT=""
ROUTING_STATUS="routing-failed"
if [ -x "$ROUTE_SCRIPT" ] || [ -f "$ROUTE_SCRIPT" ]; then
  ROUTE_OUT="$(run_with_timeout 5 bash "$ROUTE_SCRIPT" 2>/dev/null)" || ROUTE_OUT=""
fi
if [ -n "$ROUTE_OUT" ]; then
  # validate the strict 6-key single-line contract
  keys_ok=1
  for key in platform writer_model writer_lane reviewer_lane reviewer_model routing_status; do
    n="$(printf '%s\n' "$ROUTE_OUT" | grep -c "^${key}=")" || n=0
    [ "$n" -eq 1 ] || keys_ok=0
  done
  n_lines="$(printf '%s\n' "$ROUTE_OUT" | grep -c .)" || n_lines=0
  [ "$n_lines" -eq 6 ] || keys_ok=0
  if [ "$keys_ok" -eq 1 ]; then
    ROUTING_STATUS="$(printf '%s\n' "$ROUTE_OUT" | sed -n 's/^routing_status=//p')"
  else
    ROUTE_OUT=""
  fi
fi

# ── 2. audit client availability (host-excluded, same rule as blind-audit) ────
HOST_EXCLUDE=""
if [ "${CLAUDECODE:-}" = "1" ]; then
  HOST_EXCLUDE="claude"
elif [ -n "${CODEX_SANDBOX:-}" ]; then
  HOST_EXCLUDE="codex"
elif [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"Antigravity"* ]] \
  || [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"antigravity"* ]] \
  || [ -n "${ANTIGRAVITY_SESSION_ID:-}" ]; then
  # agy IS the Antigravity CLI, so on that host it is same-model like gemini.
  HOST_EXCLUDE="gemini agy"
elif [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"Cursor"* ]] \
  || [ -n "${CURSOR_AGENT_MODEL:-}" ] || [ -n "${CURSOR_MODEL:-}" ]; then
  # Cursor had no arm here at all. Harmless while cursor-agent was invisible to
  # this script; the moment detect_providers() made it reachable, the host could
  # have been picked as its own "cross-model" reviewer — same model, ok status,
  # no signal that the audit was worthless.
  HOST_EXCLUDE="cursor-agent"
fi

# `agy` is in this list because it is the ONLY client test-reviewer-routing.md
# records as working cross-model (codex and gemini are both dead at the ACCOUNT
# level; claude is the host). Probing only codex/gemini/claude found a provider,
# failed to route it, and reported degraded-routing while the one reviewer that
# works sat unprobed — which is the exact scenario that include warns about
# ("a working cross-model client sits right next to it"). Measured cost of
# accepting that degrade: a same-model audit returned CLEAN where agy found 8
# uncovered defensive paths on the same pair.
# Ask adversarial-review for the client list instead of keeping a second one.
# Its detect_providers() knows cursor-agent and kimi and the
# /Applications/Codex.app fallback; this file's hand-written list knew none of
# them, so the blind audit could reach fewer reviewers than the adversarial pass
# on the SAME machine, and listed `gemini` which is dead at the account level.
# Model IDs were unified into shared/includes/model-registry.sh long ago; client
# DETECTION is unified here. Fail-safe: if the script is absent, fall back to the
# old inline list rather than reporting no-provider.
ADV="$SCRIPT_DIR/adversarial-review.sh"
DETECTED=""
if [ -x "$ADV" ] || [ -f "$ADV" ]; then
  DETECTED="$(run_with_timeout 20 bash "$ADV" --list-providers 2>/dev/null \
              | sed 's/-[0-9][0-9.]*$//' | tr '\n' ' ')"
fi
[ -z "${DETECTED// /}" ] && DETECTED="codex gemini agy claude"

CANDIDATES=""
for candidate in $DETECTED; do
  case " $HOST_EXCLUDE " in *" $candidate "*) continue ;; esac
  command -v "$candidate" >/dev/null 2>&1 && CANDIDATES="$CANDIDATES $candidate"
done

if [ -z "${CANDIDATES// /}" ]; then
  emit_and_exit "no-provider" "none" 1 "$ROUTE_OUT"
fi
# Strip the leading space BEFORE taking the first word, not after. CANDIDATES is built
# as `CANDIDATES="$CANDIDATES $candidate"`, so it always starts with a space; then
# `${CANDIDATES%% *}` matches the WHOLE string (the longest suffix beginning with a
# space starts at index 0) and yields "". The trailing `${PROVIDER# }` was meant to fix
# exactly this but ran one step too late, on an already-empty value — so PROVIDER came
# out unconditionally empty and a `canary-failed` exit never named which provider failed.
PROVIDER="${CANDIDATES# }"; PROVIDER="${PROVIDER%% *}"

# ── 3. optional canary round-trip ─────────────────────────────────────────────
if [ "$CANARY" -eq 1 ]; then
  MARKER="ZUVO_PREFLIGHT_OK"
  PROMPT="Respond with exactly this token and nothing else: $MARKER"
  tmpout="$(mktemp "${TMPDIR:-/tmp}/zuvo-preflight.XXXXXX")"
  trap 'rm -f "$tmpout"' EXIT

  # Try EVERY available candidate, not just the first. A dead account on the
  # first client is not evidence that cross-model review is unavailable —
  # test-reviewer-routing.md says so in as many words, and both codex and gemini
  # are currently dead at the account level while agy works. Stopping at the
  # first failure is what turned "one bad account" into a whole-run degrade.
  CANARY_OK=""
  for cand in $CANDIDATES; do
    : > "$tmpout"
    case "$cand" in
      codex)
        printf '%s\n' "$PROMPT" | run_with_timeout "$TIMEOUT_SECONDS" \
          codex exec --ephemeral --color never --skip-git-repo-check - \
          > "$tmpout" 2>/dev/null
        ;;
      gemini)
        printf '%s\n' "$PROMPT" | run_with_timeout "$TIMEOUT_SECONDS" \
          gemini --allowed-mcp-server-names __NONE__ -p "" \
          > "$tmpout" 2>/dev/null
        ;;
      agy)
        # prompt as an ARGUMENT, never stdin — piping stdin hangs this client
        # (documented at scripts/adversarial-review.sh, the agy dispatch block).
        run_with_timeout "$TIMEOUT_SECONDS" agy -p "$PROMPT" \
          > "$tmpout" 2>/dev/null
        ;;
      cursor-agent)
        run_with_timeout "$TIMEOUT_SECONDS" cursor-agent -p "$PROMPT" \
          > "$tmpout" 2>/dev/null
        ;;
      kimi)
        run_with_timeout "$TIMEOUT_SECONDS" kimi -p "$PROMPT" \
          > "$tmpout" 2>/dev/null
        ;;
      claude)
        printf '%s\n' "$PROMPT" | run_with_timeout "$TIMEOUT_SECONDS" \
          claude --print --output-format text --tools "" \
          > "$tmpout" 2>/dev/null
        ;;
    esac
    if grep -q "$MARKER" "$tmpout" 2>/dev/null; then
      CANARY_OK="$cand"; PROVIDER="$cand"; break
    fi
  done

  if [ -z "$CANARY_OK" ]; then
    emit_and_exit "canary-failed" "$PROVIDER" 1 "$ROUTE_OUT"
  fi
fi

# ── verdict ───────────────────────────────────────────────────────────────────
case "$ROUTING_STATUS" in
  ok) emit_and_exit "ok" "$PROVIDER" 0 "$ROUTE_OUT" ;;
  *)  emit_and_exit "degraded-routing" "$PROVIDER" 0 "$ROUTE_OUT" ;;
esac
