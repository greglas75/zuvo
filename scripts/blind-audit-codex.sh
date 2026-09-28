#!/usr/bin/env bash
# blind-audit-codex.sh — back-compat only — call `adversarial-review --mode blind-audit` directly.
#
# Until 2026-09-25 this file WAS the blind coverage audit: it built the prompt, dispatched ONE
# provider itself, and grepped the reply for the protocol's markers. The panel
# (docs/specs/2026-09-25-blind-audit-panel-plan.md) moved every one of those decisions into
# scripts/adversarial-review.sh --mode blind-audit + scripts/lib/blind-audit-panel.sh — the prompt,
# the byte gates, the host exclusion, the isolated dispatch per lane, the strict-block validation,
# the panel merge and the exit mapping all live there now, pinned by
# tests/hooks/test-adversarial-blind-audit.sh and tests/hooks/test-blind-audit-panel.sh.
#
# This file only keeps OLD CALLERS working: it accepts the same flags as the single-provider era,
# validates its own input the way that era did (a bad --production/--test/--protocol/--timeout/
# --effort/--provider must never reach the driver — see below), translates the flags the driver has
# no equivalent for into its env vars, and forwards the rest untouched. New callers should invoke
# the driver directly:
#   adversarial-review.sh --mode blind-audit --production <file> --test <file> [--provider P]
#
# Flag -> driver mapping (the driver takes NO --model/--effort/--timeout of its own in this mode):
#   --timeout N            -> ZUVO_BLIND_AUDIT_TIMEOUT=N        (unset when --timeout is not given —
#                              the driver's own default/clamp then applies, not this script's old 600s)
#   --effort E              -> ZUVO_BLIND_AUDIT_EFFORT=E          (codex reasoning effort only)
#   --provider codex --model M  -> ZUVO_MODEL_CODEX_PRIMARY=M
#   --provider claude --model M -> ZUVO_CLAUDE_REVIEWER_MODEL=M and ZUVO_MODEL_CLAUDE_REVIEWER_OPUS=M
#                                  (both: claude_reviewer_model() in the driver picks one or the other
#                                  by host/CLAUDE_MODEL, and this wrapper cannot know which in advance)
#   --provider agy --model M    -> ZUVO_AGY_MODEL=M
#   --model without --provider  -> ignored, with a WARN (the driver has no writer-agnostic model knob)
#   --provider codex             -> --provider codex-5.3 (the driver's lane name; `codex` was always
#                                    an alias here, never a literal client name it understood)
#   --provider agy|claude        -> forwarded as-is (already the driver's own lane names)
#   --provider gemini            -> refused, exit 2: the gemini blind-audit lane was removed
#                                    2026-08-04 (Google killed the free `gemini` CLI for individuals —
#                                    IneligibleTierError; `agy` is the sanctioned paid Gemini channel)
#   --protocol F                 -> forwarded as-is when given (the driver has its own default
#                                    lookup when omitted — omitting it stays optional and is not
#                                    validated, but a GIVEN path is checked exactly like
#                                    --production/--test, below: the single-provider era required it)
#   (no --provider)              -> forwarded as no --provider: the driver runs its FULL panel, not a
#                                    single client — this is a behavior change from the pre-panel era,
#                                    where "no --provider" meant "auto-pick the first available client"
#
# Input validation happens HERE, before the driver ever runs — exit 2, the single-provider era's own
# wording where it had one:
#   * missing --production/--test                          -> "Missing required arguments."
#   * --production/--test/a GIVEN --protocol that does not
#     exist or cannot be read                               -> "Missing file: <path>"
#   * --timeout given but not a positive integer            -> "Invalid timeout: <value>"
#   * --effort given but not a bare lowercase word           -> "Invalid effort: <value>"
#   * --provider not in {codex, agy, claude} (gemini has
#     its own message; see above)                            -> "Unsupported provider: <value>"
# Without this the driver's OWN exit 2 for a DIFFERENT problem (bad args it never saw, because we
# catch them first, or "no valid answer") fell into the "anything else" bucket below and came out
# as exit 1 — a silent behavior change from the old wrapper's exit 2 on bad input.
#
# Every value-taking flag (--protocol/--production/--test/--provider/--model/--timeout/--effort) is
# rejected with exit 2 "<flag> needs a value" in ONE place in the parser (not per flag) when its
# value is MISSING (the flag was the last argument), EMPTY (`--provider ""`), or itself looks like
# another flag (`--effort --provider codex` — the next token starts with `--`). This also means the
# flag can never dangle into a `shift 2` that has nothing left to shift, which used to abort the
# whole script with a bare, undocumented exit 1 under `set -e`. A single-dash value (`--timeout -5`)
# is NOT caught here — it still flows through to that flag's own semantic validation above, which is
# what actually rejects it (`-5` is not a positive integer).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: blind-audit-codex.sh --production <file> --test <file> [--protocol <file>]
         [--provider codex|agy|claude] [--model <model>] [--timeout <seconds>] [--effort <word, e.g. low|medium|high|xhigh>]

Back-compat wrapper. Runs `adversarial-review.sh --mode blind-audit` and prints its merged strict
output block. See the header comment in this file for the full flag -> env mapping.
EOF
}

# _bac_need_value <flag> <value> — exit 2 "<flag> needs a value" unless <value> is present,
# non-empty, and does not itself look like another flag. The ONE place this is checked, for every
# value-taking flag — see the header comment. Callers pass "${2:-}" so a genuinely missing $2 (the
# flag was the last argument) and an explicitly empty one (`--provider ""`) both land here as "",
# with the same message, instead of one being caught here and the other slipping through as a
# silently-empty value.
_bac_need_value() {
  case "$2" in
    ''|--*) echo "$1 needs a value" >&2; exit 2 ;;
  esac
}

PROTOCOL_FILE=""
PRODUCTION_FILE=""
TEST_FILE=""
MODEL=""
PROVIDER=""
TIMEOUT_SECONDS=""
TIMEOUT_GIVEN=""
REASONING_EFFORT=""
EFFORT_GIVEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --protocol)
      _bac_need_value "$1" "${2:-}"
      PROTOCOL_FILE="$2"; shift 2 ;;
    --production)
      _bac_need_value "$1" "${2:-}"
      PRODUCTION_FILE="$2"; shift 2 ;;
    --test)
      _bac_need_value "$1" "${2:-}"
      TEST_FILE="$2"; shift 2 ;;
    --provider)
      _bac_need_value "$1" "${2:-}"
      PROVIDER="$2"; shift 2 ;;
    --model)
      _bac_need_value "$1" "${2:-}"
      MODEL="$2"; shift 2 ;;
    --timeout)
      _bac_need_value "$1" "${2:-}"
      TIMEOUT_SECONDS="$2"; TIMEOUT_GIVEN=1; shift 2 ;;
    --effort)
      _bac_need_value "$1" "${2:-}"
      REASONING_EFFORT="$2"; EFFORT_GIVEN=1; shift 2 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ── Input validation: the same checks the single-provider era made, run BEFORE the driver ever
# starts — its own exit 2 for a bad-args/no-valid-answer run is otherwise indistinguishable from a
# genuine review failure, and this wrapper maps THAT to exit 1 (see the exit-mapping below).
if [[ -z "$PRODUCTION_FILE" || -z "$TEST_FILE" ]]; then
  echo "Missing required arguments." >&2
  usage >&2
  exit 2
fi

_bac_check_files=("$PRODUCTION_FILE" "$TEST_FILE")
[[ -n "$PROTOCOL_FILE" ]] && _bac_check_files+=("$PROTOCOL_FILE")
for _bac_f in "${_bac_check_files[@]}"; do
  if [[ ! -f "$_bac_f" || ! -r "$_bac_f" ]]; then
    echo "Missing file: $_bac_f" >&2
    exit 2
  fi
done
unset _bac_f _bac_check_files

if [[ -n "$TIMEOUT_GIVEN" ]]; then
  # A positive integer, any number of leading zeros. No bash arithmetic ($(( )) / [[ -le ]]) touches
  # the raw value: bash reads a leading-zero operand like 08/09 as octal and dies with "value too
  # great for base" (the same class the driver's own ar_decimal() fixes) — and a 20+ digit value
  # can overflow arithmetic entirely. The regex alone proves positivity, so no comparison is needed.
  if [[ "$TIMEOUT_SECONDS" =~ ^0*[1-9][0-9]*$ ]]; then
    # Strip the leading zeros with pure parameter expansion before export (same idiom as the
    # driver's ar_decimal): the longest suffix starting with a non-zero digit is what is KEPT.
    TIMEOUT_SECONDS="${TIMEOUT_SECONDS#"${TIMEOUT_SECONDS%%[!0]*}"}"
  else
    echo "Invalid timeout: $TIMEOUT_SECONDS" >&2
    exit 2
  fi
fi

if [[ -n "$EFFORT_GIVEN" ]]; then
  # A bare lowercase word — not a fixed enum, because codex also accepts effort levels this wrapper
  # was never told about (`minimal`, `none`, …). This still rejects whitespace-only values and
  # anything with digits/punctuation, which reaching codex's `-c model_reasoning_effort=<value>`
  # unescaped would otherwise pass through as garbage.
  if ! [[ "$REASONING_EFFORT" =~ ^[a-z]+$ ]]; then
    echo "Invalid effort: $REASONING_EFFORT" >&2
    exit 2
  fi
fi

# The provider vocabulary this wrapper accepts is the CLOSED set the single-provider era supported
# (codex, agy, gemini, claude) — never the driver's wider lane list (codex-5.4, kimi, muse, …), which
# has no equivalent in the old argv surface this file exists to preserve.
DRIVER_PROVIDER=""
case "$PROVIDER" in
  '') ;;
  codex) DRIVER_PROVIDER="codex-5.3" ;;
  agy|claude) DRIVER_PROVIDER="$PROVIDER" ;;
  gemini)
    echo "blind-audit-codex: --provider gemini is unsupported — the gemini blind-audit lane was removed 2026-08-04 (Google killed the free gemini CLI for individuals; agy is the sanctioned paid Gemini channel). Use --provider codex|agy|claude, or omit --provider to run the full panel." >&2
    exit 2
    ;;
  *)
    echo "Unsupported provider: $PROVIDER" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ -n "$MODEL" ]]; then
  case "$PROVIDER" in
    codex)  export ZUVO_MODEL_CODEX_PRIMARY="$MODEL" ;;
    claude) export ZUVO_CLAUDE_REVIEWER_MODEL="$MODEL"; export ZUVO_MODEL_CLAUDE_REVIEWER_OPUS="$MODEL" ;;
    agy)    export ZUVO_AGY_MODEL="$MODEL" ;;
    *)
      echo "  WARN: --model '$MODEL' given without a mapped --provider (codex|claude|agy) — ignored." >&2
      ;;
  esac
fi

[[ -n "$TIMEOUT_SECONDS" ]] && export ZUVO_BLIND_AUDIT_TIMEOUT="$TIMEOUT_SECONDS"
[[ -n "$REASONING_EFFORT" ]] && export ZUVO_BLIND_AUDIT_EFFORT="$REASONING_EFFORT"

# This script's directory, PHYSICAL — same resolution as the driver/router/preflight (one method,
# several copies: a sourced library cannot resolve the path it is being looked up by).
_bac_src="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR=""
case "$_bac_src" in
  */*) SCRIPT_DIR="${_bac_src%/*}"; [[ -n "$SCRIPT_DIR" ]] || SCRIPT_DIR=/ ;;
  ?*)
    if [[ -n "${PWD:-}" && -f "$PWD/$_bac_src" ]]; then
      SCRIPT_DIR="$PWD"
    elif _bac_which="$(command -v -- "$_bac_src" 2>/dev/null)" && [[ -n "$_bac_which" ]]; then
      # Bare-name PATH invocation (BASH_SOURCE has no slash and it's not in $PWD): resolve via PATH
      # so the sibling driver is still found instead of silently falling through to the HOME install.
      # A path at the filesystem root (`/name`) strips to "" — that directory is `/`, as in the `*/*`
      # arm above, not "no directory" (which would skip the sibling lookup).
      SCRIPT_DIR="${_bac_which%/*}"; [[ -n "$SCRIPT_DIR" ]] || SCRIPT_DIR=/
    fi
    unset _bac_which
    ;;
esac
if [[ -n "$SCRIPT_DIR" ]]; then
  SCRIPT_DIR="$(CDPATH='' cd -P -- "$SCRIPT_DIR" 2>/dev/null && pwd -P)" || SCRIPT_DIR=""
fi
unset _bac_src

# Sibling first (a repo or plugin-cache checkout), then the HOME install (install.sh ships the
# driver there as `adversarial-review`, no .sh — see scripts/install.sh).
ADV=""
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/adversarial-review.sh" ]]; then
  ADV="$SCRIPT_DIR/adversarial-review.sh"
elif [[ -n "${HOME:-}" && -f "$HOME/.zuvo/adversarial-review" ]]; then
  ADV="$HOME/.zuvo/adversarial-review"
fi
if [[ -z "$ADV" ]]; then
  echo "blind-audit-codex: cannot find adversarial-review.sh (looked next to this script${SCRIPT_DIR:+ ($SCRIPT_DIR)} and at \$HOME/.zuvo/adversarial-review) — reinstall: ./scripts/install.sh" >&2
  exit 1
fi

DRIVER_ARGS=(--mode blind-audit)
[[ -n "$PRODUCTION_FILE" ]] && DRIVER_ARGS+=(--production "$PRODUCTION_FILE")
[[ -n "$TEST_FILE" ]] && DRIVER_ARGS+=(--test "$TEST_FILE")
[[ -n "$PROTOCOL_FILE" ]] && DRIVER_ARGS+=(--protocol "$PROTOCOL_FILE")
[[ -n "$DRIVER_PROVIDER" ]] && DRIVER_ARGS+=(--provider "$DRIVER_PROVIDER")

DRIVER_STATUS=0
bash "$ADV" "${DRIVER_ARGS[@]}" || DRIVER_STATUS=$?

# Exit code mapping (driver -> this wrapper). DRIVER_STATUS is bash's own $?, always a clean 0-255
# integer with no leading zeros — the octal-parsing hazard above does not apply to it, so a plain
# arithmetic comparison is safe here.
#   0 strict / 3 degraded                                -> 0
#   5 no auditable material / 6 oversize                  -> 2
#   124 (a lane timed out) / 129-255 (killed by a signal:
#   130 SIGINT, 137 SIGKILL, 143 SIGTERM, …)               -> forwarded UNCHANGED — the caller's own
#                                                              timeout/signal handling, if any, needs
#                                                              the real code, not a flattened 1
#   128 / anything else (1 no provider, 2 no valid answer,
#   125 suspended, 7 plan-budget, …)                       -> 1
if [[ "$DRIVER_STATUS" -eq 0 || "$DRIVER_STATUS" -eq 3 ]]; then
  exit 0
elif [[ "$DRIVER_STATUS" -eq 5 || "$DRIVER_STATUS" -eq 6 ]]; then
  exit 2
elif [[ "$DRIVER_STATUS" -eq 124 || "$DRIVER_STATUS" -ge 129 ]]; then
  exit "$DRIVER_STATUS"
else
  exit 1
fi
