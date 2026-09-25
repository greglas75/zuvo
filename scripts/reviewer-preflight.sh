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
#   2. client    — a non-writer audit client is available, applying the same
#                  host-exclusion rule as blind-audit-codex.sh (a Codex host is
#                  zms_is_codex_host: any one of its four signals). Availability is
#                  zms_client_available (the shared runner's own resolver), so a
#                  client counts exactly when the runner could start it:
#                  ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN (a SET value is final — even
#                  /nonexistent), then PATH, then the Codex.app fallback.
#   3. canary    — OPTIONAL real model round-trip, each client bounded by
#                  $ZUVO_PREFLIGHT_TIMEOUT (60s). The prompt asks for a COMPUTED
#                  answer ("the product of 6 and 7, digits only"); a canary passes
#                  only when the client EXITS 0 and a line of its stdout reads 42
#                  (blanks, markdown emphasis/backticks and a trailing period
#                  around it trimmed — "142" or "The answer is 42" do not count).
#                  A 42 followed by a crash or by a hang the timeout ended does
#                  not count either. The prompt never contains the answer: the
#                  old canary asked the client to repeat the token
#                  ZUVO_PREFLIGHT_OK and grepped for it, so a client that merely
#                  echoed its input passed. Candidates are tried in order until
#                  one passes. Without GNU timeout (timeout/gtimeout) NO canary
#                  runs — each is named on stderr. Every canary runs isolated:
#                    codex/claude  — zms_run_codex / zms_run_claude --access none:
#                                    neutral cwd, own CODEX_HOME (auth.json + a
#                                    minimal config.toml, no MCP servers), strict
#                                    EMPTY MCP config for claude, no tools;
#                                    model/effort = what the blind audit uses
#                                    (codex: ZUVO_CODEX_MODEL → registry
#                                    ZUVO_MODEL_CODEX_PRIMARY, effort
#                                    ZUVO_BLIND_AUDIT_EFFORT → ZUVO_CODEX_EFFORT_AUDIT;
#                                    claude: ZUVO_CLAUDE_AUDIT_MODEL → registry
#                                    ZUVO_MODEL_CLAUDE_REVIEWER_OPUS); no model id
#                                    = that canary fails, named on stderr
#                    agy / cursor-agent / kimi / gemini — from a neutral temp cwd
#                                    (never the caller's repository), under GNU
#                                    timeout, stdin from /dev/null (gemini: the
#                                    prompt file) — never the caller's stdin.
#                  Skipped with --no-canary or ZUVO_PREFLIGHT_NO_CANARY=1
#                  (routing+client alone already catch the common failures).
#
# Shared runner: scripts/lib/model-subprocess.sh, found the way the router and the
# adversarial driver find it — <this dir>/lib/model-subprocess.sh →
# <this dir>/model-subprocess.sh → ~/.zuvo/model-subprocess.sh. A candidate that
# exists but does not load is named on stderr and the next one is tried.
# NONE loads → fail CLOSED: preflight_status=no-provider, provider=none, exit 1,
# one stderr line naming model-subprocess.sh, and no client is run. Without it no
# reviewer can be judged available the way the runners resolve it, nor canaried in
# isolation, so "reachable" would be a guess. (The router, missing it, prints its
# routing-failed sentinel as data — passed through below — and exits 0; preflight's
# job is the verdict, and the verdict is "unavailable".)
#
# Output: KEY=VALUE lines on stdout (stable contract, one per line):
#   preflight_status=ok|degraded-routing|no-provider|canary-failed
#   provider=<the client that answered | the first candidate | none>
#   + the six reviewer-model-route.sh keys, passed through
# stderr: diagnostics only — one line per failed canary (client and why), never the
#   client's own output.
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
      # The whole header comment, however long it grows.
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2 ;;
  esac
done

# Leading zeros go: the runners take the value as seconds and refuse a leading 0, so "060" would
# have passed here and then failed every codex/claude canary as "could not start".
if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "Invalid ZUVO_PREFLIGHT_TIMEOUT: $TIMEOUT_SECONDS" >&2
  exit 2
fi
_pf_given="$TIMEOUT_SECONDS"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS#"${TIMEOUT_SECONDS%%[!0]*}"}"
if [ -z "$TIMEOUT_SECONDS" ]; then
  echo "Invalid ZUVO_PREFLIGHT_TIMEOUT: $_pf_given" >&2
  exit 2
fi
unset _pf_given

# GNU timeout under either name (macOS ships none; Homebrew coreutils installs both).
TIMEOUT_BIN="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
KILL_GRACE=5

# run_with_timeout <secs> <cmd...> — for this script's OWN helpers (the router, the driver's
# --list-providers): bounded when GNU timeout exists, run as-is otherwise. Model clients never go
# through here without a bound — see run_neutral.
run_with_timeout() {
  local secs="$1"; shift
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" -k "$KILL_GRACE" "$secs" "$@"
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

# ── 0. the shared runner (sibling first, like the router and the driver) ───────
# Sibling candidates only when SCRIPT_DIR resolved ABSOLUTE: an empty one would turn them into
# /lib/model-subprocess.sh and /model-subprocess.sh — files at the filesystem root, SOURCED here.
ZMS_LOADED=""
_pf_cands=()
case "$SCRIPT_DIR" in /*) _pf_cands=("$SCRIPT_DIR/lib/model-subprocess.sh" "$SCRIPT_DIR/model-subprocess.sh") ;; esac
if [ -n "${HOME:-}" ]; then _pf_cands+=("$HOME/.zuvo/model-subprocess.sh"); fi
# Every function used below must come from ONE candidate: an older copy lacking zms_is_codex_host
# would otherwise leave the call a "command not found" — false — and a Codex host its own reviewer.
_pf_fns="zms_client_available zms_run_codex zms_run_claude zms_source_registry zms_is_auth_stub zms_is_codex_host"
for _pf_lib in ${_pf_cands[@]+"${_pf_cands[@]}"}; do
  [ -f "$_pf_lib" ] || continue
  # A function left behind by an earlier candidate that failed half-way must not pass for this one.
  # shellcheck disable=SC2086  # one function name per word, by design
  unset -f $_pf_fns
  # shellcheck source=/dev/null
  if . "$_pf_lib"; then
    _pf_ok=1
    for _pf_fn in $_pf_fns; do declare -F "$_pf_fn" >/dev/null || _pf_ok=0; done
    if [ "$_pf_ok" -eq 1 ]; then ZMS_LOADED="$_pf_lib"; break; fi
  fi
  echo "reviewer-preflight: WARN: $_pf_lib exists but did not load the shared runner ($_pf_fns) — trying the next candidate" >&2
done
unset _pf_cands _pf_lib _pf_fns _pf_fn _pf_ok

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

if [ -z "$ZMS_LOADED" ]; then
  echo "reviewer-preflight: model-subprocess.sh (the shared reviewer runner) not loaded from next to this script ($SCRIPT_DIR/lib, $SCRIPT_DIR) or from ~/.zuvo — no reviewer can be checked the way the runners resolve it, nor canaried in isolation; failing closed (no-provider). Fix: ./scripts/install.sh" >&2
  emit_and_exit "no-provider" "none" 1 "$ROUTE_OUT"
fi

# ── 2. audit client availability (host-excluded, same rule as blind-audit) ────
HOST_EXCLUDE=""
if [ "${CLAUDECODE:-}" = "1" ]; then
  HOST_EXCLUDE="claude"
elif zms_is_codex_host; then
  # All four Codex signals (CODEX_SANDBOX, CODEX_SHELL=1, __CFBundleIdentifier=com.openai.codex,
  # CODEX_INTERNAL_ORIGINATOR_OVERRIDE="Codex Desktop"), not CODEX_SANDBOX alone: inside Codex Desktop
  # only the others are set, and codex was canaried — and reported — as its own cross-model reviewer.
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

# Availability is the runner's own answer, never a second `command -v`: that one missed a client
# pinned by ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN off the PATH (or only in Codex.app) and, worse,
# accepted a codex on PATH that ZUVO_CODEX_BIN=/nonexistent had switched off. Each client once:
# codex-5.3 and codex-5.4 both strip to `codex`, and one canary per client is the budget.
CANDIDATES=""
for candidate in $DETECTED; do
  case " $HOST_EXCLUDE " in *" $candidate "*) continue ;; esac
  case " $CANDIDATES " in *" $candidate "*) continue ;; esac
  zms_client_available "$candidate" 2>/dev/null && CANDIDATES="$CANDIDATES $candidate"
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
# reply_has_answer <file> — true when some line of the reply, once CR, surrounding blanks, markdown
# emphasis/backticks and a trailing period are trimmed, reads exactly 42. Only the client's STDOUT is
# ever checked: codex writes the prompt back on stderr ("user\n<prompt>") by design.
reply_has_answer() {
  awk '{ gsub(/\r/, ""); sub(/^[[:space:]*_`]+/, ""); sub(/[[:space:]*_`.]+$/, "")
         if ($0 == "42") found = 1 }
       END { exit(found ? 0 : 1) }' "$1" 2>/dev/null
}

# run_neutral <out> <err> <in> <client> [args...] — a client the shared runner does not cover, started
# from the neutral temp cwd (OLDPWD pointed there too, so the caller's repository is not handed over
# through it), stdin from <in> — /dev/null unless the client takes its prompt there — and bounded by
# GNU timeout with a KILL after the grace. Never the caller's stdin: under timeout the client leads its
# own process group, so reading an inherited terminal stops it (SIGTTIN) until the budget ends, and an
# inherited pipe hands it the caller's input. The client is resolved to an absolute path BEFORE the cd,
# as zms_client_available resolved it. Only called with GNU timeout present (the canary loop checks).
# Status: the client's own, 124/137 timed out, 127 not found.
run_neutral() {
  local out="$1" err="$2" in="$3" bin
  shift 3
  bin="$(type -P "$1")" || return 127
  case "$bin" in /*) ;; *) bin="$PWD/$bin" ;; esac
  shift
  ( cd "$NEUTRAL_CWD" || exit 2
    export OLDPWD="$NEUTRAL_CWD"
    exec "$TIMEOUT_BIN" -k "$KILL_GRACE" "$TIMEOUT_SECONDS" "$bin" "$@" ) < "$in" > "$out" 2> "$err"
}

# canary_failed_note <client> <status> <out> <err> — one stderr line saying why a canary did not pass.
# Never the client's output itself: its stderr can carry account details.
canary_failed_note() {
  local why
  case "$2" in
    124|137) why="timed out after ${TIMEOUT_SECONDS}s" ;;
    127)     why="client not found" ;;
    0)       why="exit 0, no line reading 42 in the reply" ;;
    *)       if reply_has_answer "$3"; then why="exit $2 — a 42 from a client that failed does not count"
             else why="exit $2, no line reading 42 in the reply"; fi ;;
  esac
  if zms_is_auth_stub "$3" || zms_is_auth_stub "$4"; then why="$why (the reply is an auth error — log the client in)"; fi
  echo "reviewer-preflight: canary $1 failed: $why" >&2
}

if [ "$CANARY" -eq 1 ]; then
  PROMPT="Reply with the product of 6 and 7, digits only."
  if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/zuvo-preflight.XXXXXX")" || [ -z "$WORK" ]; then
    echo "reviewer-preflight: cannot create a temp dir under ${TMPDIR:-/tmp} — no canary could run" >&2
    emit_and_exit "canary-failed" "$PROVIDER" 1 "$ROUTE_OUT"
  fi
  trap 'rm -rf "$WORK"' EXIT
  # Physical and absolute: the runners resolve relative paths themselves, run_neutral's cd does not.
  if _pf_abs="$(cd "$WORK" && pwd -P)" && [ -n "$_pf_abs" ]; then
    WORK="$_pf_abs"
  else
    echo "reviewer-preflight: cannot resolve the canary work dir $WORK" >&2
    emit_and_exit "canary-failed" "$PROVIDER" 1 "$ROUTE_OUT"
  fi
  unset _pf_abs
  NEUTRAL_CWD="$WORK/cwd"
  PROMPT_FILE="$WORK/prompt.txt"
  if ! { mkdir -p "$NEUTRAL_CWD" && printf '%s\n' "$PROMPT" > "$PROMPT_FILE"; }; then
    echo "reviewer-preflight: cannot prepare the canary work dir $WORK" >&2
    emit_and_exit "canary-failed" "$PROVIDER" 1 "$ROUTE_OUT"
  fi

  # Model ids come from the registry (sibling first, then ~/.zuvo), the same ones the blind audit
  # uses — a canary on another model would vouch for a call the audit never makes.
  zms_source_registry >/dev/null 2>&1 || :
  CODEX_CANARY_MODEL="${ZUVO_CODEX_MODEL:-${ZUVO_MODEL_CODEX_PRIMARY:-}}"
  CODEX_CANARY_EFFORT="${ZUVO_BLIND_AUDIT_EFFORT:-${ZUVO_CODEX_EFFORT_AUDIT:-}}"
  CLAUDE_CANARY_MODEL="${ZUVO_CLAUDE_AUDIT_MODEL:-${ZUVO_MODEL_CLAUDE_REVIEWER_OPUS:-}}"

  # Try EVERY available candidate, not just the first. A dead account on the
  # first client is not evidence that cross-model review is unavailable —
  # test-reviewer-routing.md says so in as many words, and both codex and gemini
  # are currently dead at the account level while agy works. Stopping at the
  # first failure is what turned "one bad account" into a whole-run degrade.
  CANARY_OK=""
  n=0
  for cand in $CANDIDATES; do
    n=$((n + 1))
    out="$WORK/out.$n"; err="$WORK/err.$n"; rc=0
    : > "$out"; : > "$err"
    # Every canary is bounded — codex/claude by the runner, the rest by run_neutral, both through GNU
    # timeout. Without it none is run: an unbounded canary is the hang this preflight exists to report,
    # not to reproduce. Checked here, per client, so each one is named rather than failing as "exit 2".
    if [ -z "$TIMEOUT_BIN" ]; then
      echo "reviewer-preflight: canary $cand not run: GNU timeout required (timeout or gtimeout on PATH; macOS: brew install coreutils)" >&2
      continue
    fi
    case "$cand" in
      codex)
        if [ -z "$CODEX_CANARY_MODEL" ]; then
          echo "reviewer-preflight: canary codex not run: no model id (model-registry.sh not found and ZUVO_CODEX_MODEL unset)" >&2
          continue
        fi
        cargs=(--model "$CODEX_CANARY_MODEL" --access none --prompt-file "$PROMPT_FILE"
               --timeout "$TIMEOUT_SECONDS" --stderr-file "$err")
        if [ -n "$CODEX_CANARY_EFFORT" ]; then cargs+=(--effort "$CODEX_CANARY_EFFORT"); fi
        zms_run_codex "${cargs[@]}" > "$out" || rc=$?
        ;;
      claude)
        if [ -z "$CLAUDE_CANARY_MODEL" ]; then
          echo "reviewer-preflight: canary claude not run: no model id (model-registry.sh not found and ZUVO_CLAUDE_AUDIT_MODEL unset)" >&2
          continue
        fi
        zms_run_claude --model "$CLAUDE_CANARY_MODEL" --access none --prompt-file "$PROMPT_FILE" \
          --timeout "$TIMEOUT_SECONDS" --stderr-file "$err" > "$out" || rc=$?
        ;;
      gemini)
        # the prompt on stdin — and nothing else there
        run_neutral "$out" "$err" "$PROMPT_FILE" gemini --allowed-mcp-server-names __NONE__ -p "" || rc=$?
        ;;
      agy)
        # prompt as an ARGUMENT, never stdin — piping stdin hangs this client
        # (documented at scripts/adversarial-review.sh, the agy dispatch block).
        run_neutral "$out" "$err" /dev/null agy -p "$PROMPT" || rc=$?
        ;;
      cursor-agent)
        run_neutral "$out" "$err" /dev/null cursor-agent -p "$PROMPT" || rc=$?
        ;;
      kimi)
        run_neutral "$out" "$err" /dev/null kimi -p "$PROMPT" || rc=$?
        ;;
      *)
        echo "reviewer-preflight: canary $cand not run: no canary is defined for this client" >&2
        continue
        ;;
    esac
    # Both, or it did not pass: a client that printed 42 and then crashed, or hung until the timeout
    # killed it, is not a reviewer the blind audit can run — it would crash or hang there too.
    if [ "$rc" -eq 0 ] && reply_has_answer "$out"; then
      CANARY_OK="$cand"; PROVIDER="$cand"; break
    fi
    canary_failed_note "$cand" "$rc" "$out" "$err"
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
