# shellcheck shell=bash
# adversarial-cli.sh — the driver's command line: option defaults, the flag parser and --help, the
# --append-artifact reconciliation, the ZUVO_REVIEW_PROVIDER default, --mode validation and the
# --mode plan round budget. Sourced by scripts/adversarial-review.sh only; never executed.
#
# Phases (run in this order from the driver's Main, among other modules' phases): ar_init_options,
# ar_parse_args "$@", ar_reconcile_append_artifact, ar_resolve_provider_env, ar_validate_mode,
# ar_check_plan_budget. Every option global (PROVIDER, REVIEW_MODE, OUTPUT_FORMAT, FILES, …) is set here.
# Function: chunked_doc_mode.
#
# Phase bodies sit at column 0, byte for byte the top-level code they were cut from:
# indenting them would change the multi-line prompt strings and heredocs several carry, and would
# make the move unprovable by diff. Each runs once, from the driver's Main, at the point it used to.
# Linted as part of the whole program: tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on
# the driver with every module inlined (the repo's shellcheck gate skips files without a shebang).

# The document modes, defined once (CQ20). AR_DOC_MODES: the review input is a document, not code — the
# document-auditor prompt and no language hint. Four copies with two memberships let --mode article fall
# out of two of them until b65b319d edited all four. AR_UNCHUNKED_DOC_MODES: the document modes whose input
# keeps the code rules — the 30,000-char cap, file-header boundaries, never chunked: `tests` (a test-audit
# report) was left out when chunking came to documents (a265416c) because none of its 1,293 runs had
# reached the cap. chunked_doc_mode says which rule this run's input follows.
AR_DOC_MODES='^(spec|plan|audit|tests|migrate|article)$'
AR_UNCHUNKED_DOC_MODES='^(tests)$'
chunked_doc_mode() { [[ "$REVIEW_MODE" =~ $AR_DOC_MODES && ! "$REVIEW_MODE" =~ $AR_UNCHUNKED_DOC_MODES ]]; }

# ar_init_options — the option globals and their defaults, before the command line is read.
ar_init_options() {
# ─── Argument parsing ───────────────────────────────────────────

PROVIDER=""
MULTI_MODE=""  # empty = auto (multi if 2+ available), "single" = first-success only, "rotate" = random single
REVIEW_MODE="code"  # code | test | security | spec | plan | audit | tests
OUTPUT_FORMAT="text"  # text | json
CONTEXT_HINT=""
DIFF_REF=""
FILES=""
ARTIFACT_PATH=""
TAMPER_NOTE=""   # set by _tamper_verify when the tree changed under the reviewers
INPUT_MODE="stdin"  # stdin | diff | files
DRY_RUN=false
DOCTOR=false         # --doctor: live auth probe of every detected provider, then exit
LIST_PROVIDERS=false     # --list-providers: print detected clients, one per line, and exit
EXCLUDE_PROVIDER=""  # --exclude: space-separated SET of providers to skip. Repeatable; the
                     # host auto-exclusion (self-review prevention) ADDS to it rather than
                     # replacing it. It was a scalar until 2026-08-11, which broke two ways:
                     # a second --exclude silently dropped the first (a rotation pass came
                     # back to an already-used provider and burned a full chunk), and passing
                     # --exclude at all suppressed host auto-exclusion, letting the host
                     # review its own output.
EXCLUDE_LAST=""      # --exclude-last: cross-call rotation handoff (D4)
APPEND_ARTIFACT=false  # --append-artifact: append this pass to an existing artifact (rotations)
APPEND_ARTIFACT_PATH="" # optional path given to --append-artifact (legacy doc form; see the arm)
KNOWN_FINDINGS=""      # --known-finding FP (repeatable): fingerprints already dispositioned
RECORD_ROWS=""         # --record-disposition FP VERDICT (repeatable): "fp<TAB>verdict" lines; append, then exit
EFFECTIVENESS=false    # --effectiveness: per-model precision over the findings ledger, then exit
NO_CHUNK=false         # --no-chunk / ZUVO_ADV_NO_CHUNK=1: disable auto-chunking, fall back to truncation
BA_PRODUCTION=""; BA_TEST=""; BA_PROTOCOL=""; BA_PROMPT=""; BA_PROMPT_BYTES=0; BA_AGY_ARG_BYTES=0; BA_ARGV_DROP=""   # --mode blind-audit only
return 0
}

# _ar_flag_value <flag> <argc> [<value>] [empty-ok] — the value a flag takes must be there and must not be
# the next flag; anything else is a usage error (exit 2) that names the flag. Six flags read "$2" with no
# such check until 2026-10-04: under `set -u` a missing value died as an unbound variable with exit 1 —
# the code the contract reserves for "no provider available" — and a flag-shaped --diff value reached
# `git diff "$REF"..HEAD` as an OPTION (`--diff --output=<file>` wrote that file). empty-ok: an empty
# string is a value (--context ""), a missing one is not.
_ar_flag_value() {
  if [[ "$2" -lt 2 || "${3:-}" == -* || ( -z "${3:-}" && "${4:-}" != empty-ok ) ]]; then
    echo "ERROR: $1 requires a value, got '${3:-<missing>}'." >&2; exit 2
  fi
}

# ar_parse_args "$@" — the command line into the option globals; --help prints and exits 0, a bad flag exits 2.
ar_parse_args() {
while [[ $# -gt 0 ]]; do
  case $1 in
    --doctor)    DOCTOR=true; shift ;;
    --list-providers) LIST_PROVIDERS=true; shift ;;
    --provider)  _ar_flag_value "$1" $# "${2-}"; PROVIDER="$2"; shift 2 ;;
    --multi)     MULTI_MODE="multi"; shift ;;
    --single)    MULTI_MODE="single"; shift ;;
    --rotate)    MULTI_MODE="rotate"; shift ;;
    --exclude)
      # Reject next-arg-is-a-flag (prevents `--exclude --json` from swallowing --json).
      # Allow empty string explicitly (treated as noop downstream).
      if [[ $# -lt 2 || ( -n "${2:-}" && "$2" == -* ) ]]; then
        echo "ERROR: --exclude requires a value (provider name or empty string), got '${2:-<missing>}'." >&2; exit 2
      fi
      # Accumulate — repeated --exclude flags form a SET, they do not overwrite.
      # Empty string stays a noop (test contract) and must not append a stray separator.
      [[ -n "$2" ]] && EXCLUDE_PROVIDER="${EXCLUDE_PROVIDER:+$EXCLUDE_PROVIDER }$2"
      shift 2 ;;
    --exclude-last)
      # Same flag-swallow guard as --exclude. Empty string = explicit noop (test contract).
      if [[ $# -lt 2 || ( -n "${2:-}" && "$2" == -* ) ]]; then
        echo "ERROR: --exclude-last requires a value (provider name or empty string), got '${2:-<missing>}'." >&2; exit 2
      fi
      EXCLUDE_LAST="$2"; shift 2 ;;
    --mode)      _ar_flag_value "$1" $# "${2-}"; REVIEW_MODE="$2"; shift 2 ;;
    --json)      OUTPUT_FORMAT="json"; shift ;;
    --context)   _ar_flag_value "$1" $# "${2-}" empty-ok; CONTEXT_HINT="$2"; shift 2 ;;
    --diff)      _ar_flag_value "$1" $# "${2-}"; DIFF_REF="$2"; INPUT_MODE="diff"; shift 2 ;;
    --files)     _ar_flag_value "$1" $# "${2-}"; FILES="$2"; INPUT_MODE="files"; shift 2 ;;
    --file)
      # Repeatable single-path form (field retro 2026-08-02): a shell-quoted
      # newline list passed as --files was interpreted as ONE filename twice in
      # one day — 2 attempts + ~8 min per hit. --file has no quoting ambiguity:
      # one path per flag, appended newline-separated internally.
      if [[ $# -lt 2 || -z "${2:-}" || "$2" == -* ]]; then
        echo "ERROR: --file requires a path, got '${2:-<missing>}'." >&2; exit 2
      fi
      FILES="${FILES:+$FILES$'\n'}$2"; INPUT_MODE="files"; shift 2 ;;
    --artifact)  _ar_flag_value "$1" $# "${2-}"; ARTIFACT_PATH="$2"; shift 2 ;;
    --append-artifact)
      # `--append-artifact "$PATH"` was the form documented in skills/review/SKILL.md §1.3 from
      # the day the flag shipped, while the parser took no value — so every copied rotation pass
      # fell through to `*) Unknown argument: <path>` and exited 2 having written NO proof file,
      # which is the artifact the push gate reads. Six ship retros reported it between 2026-08-07
      # and 2026-08-09 (uptime #74, i9-farma, rs_be #263, tgm-survey-tester #49, Helper #97,
      # stages-actions) and the docs stayed wrong through all six.
      # The docs are correct now (`--artifact P --append-artifact`), and the parser ALSO accepts
      # the value form, because the wrong shape is baked into other checkouts' skill caches, into
      # every already-written retro, and into agent habit. Accepting it means exactly
      # `--artifact PATH --append-artifact`; a CONFLICTING --artifact is a hard error in either
      # order (reconciled after the loop), never a silent pick of one path over the other.
      APPEND_ARTIFACT=true
      if [[ $# -ge 2 && -n "${2:-}" && "$2" != -* ]]; then
        APPEND_ARTIFACT_PATH="$2"; shift 2
      else
        shift
      fi
      ;;
    --known-finding)
      if [[ $# -lt 2 || -z "${2:-}" || "$2" == -* ]]; then
        echo "ERROR: --known-finding requires a fingerprint value, got '${2:-<missing>}'." >&2; exit 2
      fi
      KNOWN_FINDINGS="${KNOWN_FINDINGS:+$KNOWN_FINDINGS$'\n'}$2"; shift 2 ;;
    # Close the loop a review opens: a model raised the finding, and only the caller knows what
    # became of it. Validated here, before anything is written, so one bad pair in a batch
    # leaves the ledger untouched instead of half-recorded.
    --record-disposition)
      if [[ $# -lt 3 ]]; then
        echo "ERROR: --record-disposition requires <fingerprint> <fixed|rejected|deferred> (two values)." >&2; exit 2
      fi
      if [[ -z "$2" || "$2" == -* || "$2" =~ [[:cntrl:]] || "$2" == *\\* ]]; then
        echo "ERROR: --record-disposition: '$2' is not a fingerprint (empty, flag-shaped, or holds a control character or backslash)." >&2; exit 2
      fi
      if [[ ! "${3:-}" =~ ^(fixed|rejected|deferred)$ ]]; then
        echo "ERROR: disposition for '$2' must be fixed|rejected|deferred, got '${3:-<missing>}'." >&2; exit 2
      fi
      RECORD_ROWS="${RECORD_ROWS:+$RECORD_ROWS$'\n'}$2"$'\t'"$3"; shift 3 ;;
    --effectiveness) EFFECTIVENESS=true; shift ;;
    --production|--test|--protocol)   # --mode blind-audit only — checked once the mode is known
      [[ $# -ge 2 && -n "${2:-}" && "$2" != -* ]] || { echo "ERROR: $1 requires a path, got '${2:-<missing>}'." >&2; exit 2; }
      case $1 in --production) BA_PRODUCTION="$2" ;; --test) BA_TEST="$2" ;; *) BA_PROTOCOL="$2" ;; esac
      shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --no-chunk)  NO_CHUNK=true; shift ;;
    --help|-h)
      cat <<'HELP'
Usage: adversarial-review.sh [OPTIONS] [--diff REF] [--files "path"]
       adversarial-review.sh --mode blind-audit --production FILE --test FILE [--protocol FILE] [--provider P] [--json]

Provider options:
  (default)        Multi: run ALL available providers (best-effort with 1)
  --multi          Explicit multi: REQUIRES 2+ providers (else exit 3)
  --single         First-success: stop after first provider
  --rotate         Random single: shuffle providers, pick one
                   REQUIRES 2+ providers (else exit 3)
  --exclude P      Skip provider P (e.g. host self-exclusion)
  --exclude-last P Cross-call rotation: skip P (caller threads providers_used[0]
                   from prior JSON). Stale value → stderr warning, proceeds.
  --provider P     Auto: codex-5.3, agy, cursor-agent, kimi, claude
                   Manual: codex-5.4, codestral

Exit codes:
  0    success (or partial: some providers timed out, others succeeded)
  1    no provider available (none detected/installed)
  2    all providers failed (reached and refused/errored — see evidence_dir); also a usage
       error, or the driver's own modules missing (nothing ran — reinstall)
       blind-audit: no valid answer from any lane (text stdout is EMPTY)
  3    single_provider_only (--multi/--rotate requested but <2 providers) — code/doc modes only
       blind-audit: degraded (SAME exit code, different meaning — scoped by --mode, not distinguishable
       by exit code alone) — exactly ONE valid answer; its block IS printed (not a failure)
  5    no reviewable material (nothing was sent to any provider — this is NOT a completed review)
  6    blind-audit: input too large (prompt over ZUVO_BLIND_AUDIT_MAX_BYTES; nothing was sent)
       (blind-audit: 0 = strict, >= 2 valid answers; 1 = no lane left after its exclusions)
  124  timeout — every ATTEMPTED lane timed out with none answering at all, even invalidly (all
       providers timed out, or the whole-run deadline fired)
  125  suspended (the HOST slept mid-run; providers never had a chance — safe to retry)
  130  interrupted (SIGINT — Ctrl-C)
  143  terminated (SIGTERM — orchestrator kill)

Review modes:
  --mode code      (default) General code review
  --mode test      Test-specific: flaky patterns, coverage theater, missing edge cases
  --mode security  Security-focused: OWASP, injection, auth bypass
  --mode spec      Design spec: hallucinations, contradictions, scope creep
  --mode plan      Implementation plan: task bloat, ordering violations, AC orphans
  --mode audit     Audit report: score inflation, gate inconsistency, N/A abuse
  --mode tests     Test audit report: Q-score inflation, coverage theater
  --mode migrate   Migration/schema: irreversible DDL, missing backfill, index locks
  --mode article   Long-form article: slop vocabulary, unsupported claims, structure
  --mode blind-audit  Blind coverage audit of ONE production file + its test file by a
                   cross-vendor panel of isolated lanes; stdout = ONE merged strict block
  (An unrecognized mode is a hard error, exit 2 — it used to fall back to `code` silently.)

Blind audit (--mode blind-audit only; stdin, --diff, --files, --artifact are refused):
  --production F   The production file (required)
  --test F         Its test file (required; an empty file of the pair → exit 5)
  --protocol F     Protocol to audit by (default: shared/includes/blind-coverage-audit.md,
                   then ~/.zuvo/blind-coverage-audit.md)
  --provider P     A panel of one lane (at best degraded, exit 3)
  --json           {status, mode, verdict, valid_providers, provider_outcomes, prompt_bytes,
                   excluded_argv_lanes, merged_block, results}

Diagnostics:
  --doctor         Live auth+dispatch probe of every detected provider (tiny prompt,
                   ZUVO_DOCTOR_TIMEOUT=60s each). Presence on PATH ≠ working login —
                   run this after provisioning a host/bot. Exit 0 if ≥1 provider works.
  --list-providers Print the detected client list (one per line) and exit. The single
                   source reviewer-preflight.sh reads instead of keeping its own.

Output:
  --json           Machine-readable JSON (for agent-in-the-loop)
  --context "..."  Add context hint (e.g. "NestJS auth middleware")
  --dry-run        Print the prompt that would be sent, then exit (debug)

Input:
  --diff REF       Review diff from REF to HEAD
  --files "f1\nf2"  Review specific files (newline-separated, supports spaces in paths)
  --file PATH      Review one file; REPEAT --file for multiple. Prefer this over --files —
                   no shell quoting ambiguity (a mis-quoted newline list reads as ONE filename)
  --artifact PATH  Save review output + metadata to PATH for downstream gates
  --append-artifact [PATH]
                   Append this pass to an existing artifact instead of overwriting it
                   (use for sequential --rotate passes so pass 1 is not lost). Canonical
                   form is `--artifact PATH --append-artifact`; the one-arg form
                   `--append-artifact PATH` is accepted as an alias for exactly that.
                   Giving both a --artifact and a DIFFERENT --append-artifact path is an error.
  --known-finding FP  Fingerprint already dispositioned in a previous pass (repeatable).
                   Repeats are reported separately and do not consume the finding budget.
  --record-disposition FP fixed|rejected|deferred
                   Record what became of a finding (repeatable; nothing is reviewed). FP is
                   the `id` from a --json review, recorded from the same repository the review
                   ran in (any of its worktrees). A verdict judges the raises logged before it;
                   recording again supersedes it. Ids no review from this repository raised are
                   refused by name (exit 1) — a verdict that joins nothing would read as success.
  --effectiveness  Per-model report over ~/.zuvo/adversarial-findings.log: findings raised,
                   CRITICALs, verdicts, and precision = (fixed+deferred) / judged — rejected
                   is the false-positive column. Unjudged findings are excluded from precision,
                   not counted against the model. Only --json reviews are in the ledger: text
                   output carries no fingerprints to join a verdict to.
  --no-chunk      Disable auto-chunking of oversized input (env: ZUVO_ADV_NO_CHUNK=1).
                   Default: input over the char cap with 2+ file boundaries is split at
                   file boundaries and reviewed chunk-by-chunk — no silent truncation.
  (stdin)          Pipe a diff

Environment variables:
  ZUVO_REVIEW_PROVIDER     Force provider
  ZUVO_REVIEW_MAX_PROVIDERS  Fan-out cap: how many of the detected providers actually run
                           (default: 5, raised from 3 on 2026-09-04). Applied AFTER host
                           auto-exclusion and --exclude, so it keeps the best N still standing.
                           The order is the measured ranking in detect_providers().
                           The old default of 3 was justified by "retains ~92% of
                           CRITICAL-producing runs for 39% fewer provider calls" — a true
                           statement about a DIFFERENT question. It measures how often a run
                           produced ANY critical. A second measurement (2026-09-02, 20 real
                           diffs, every finding judged REAL/FALSE_POSITIVE by an independent
                           Opus judge, shared defect-id vocabulary so duplicates collapse)
                           asked how many DISTINCT defects a set of models covers: 57% of each
                           model's true findings are unique to it, no single model exceeds 28%
                           of the 347 defects, and coverage runs 3 models -> ~54%,
                           4 -> ~62%, 5 -> ~66%. Both numbers are correct; they answer
                           "does review catch something" vs "does review catch everything".
                           5 is the point where the marginal model still adds ~20 defects.
                           Ignored with --provider.
  ZUVO_REVIEW_TIMEOUT      Per-provider timeout in seconds (default: 400, flat across modes)
  ZUVO_TIMEOUT_GRACE       Seconds between SIGTERM and SIGKILL for a provider (default: 15).
                           Without the hard kill a TERM-ignoring CLI runs unbounded.
  ZUVO_RUN_DEADLINE        Whole-run wall-clock ceiling in seconds (default: derived from the
                           per-provider timeout and dispatch mode). Fires SIGTERM → exit 124.
                           Ignored in --mode blind-audit (see below): the deadline there is derived
                           from the per-lane timeout, never from this knob.
  ZUVO_SUSPEND_THRESHOLD   Seconds of host sleep before a run is classed `suspended` (default: 60)
  ZUVO_AUTH_CACHE_TTL      Seconds a lane that failed authentication stays skipped (default: 21600)
  ZUVO_STDIN_WAIT          Seconds to wait for the first byte of a piped input (default: 10)
  ZUVO_STDIN_TIMEOUT       Seconds a piped input may take to END; past it the run is refused (default: 300)
  ZUVO_ADV_MODULE_STAMP_WAIT Seconds to wait for a module set to match its install stamp (default: 10)
  ZUVO_PROVIDER_HEALTH_LOCK_WAIT Seconds to wait for the provider-health ledger's lock (default: 10)
  ZUVO_ARTIFACT_LOCK_WAIT  Seconds --append-artifact waits for the artifact's lock (default: 30)
  ZUVO_NO_CAFFEINATE=1     Do not hold off idle sleep for the duration of the run (macOS)
  ZUVO_AGY_MODEL           agy (Antigravity CLI) model — the sanctioned paid Gemini channel, and the
                           only Gemini lane this script supports (Google killed the free `gemini` CLI
                           for individuals — IneligibleTierError).
                           Display name from 'agy models' (default: "Gemini 3.8 Flash (Medium)").
                           3.1 Pro is NOT a deeper alternative here: measured 7/20 answered
                           vs 20/20 for Flash, at 3.5x the latency. See model-registry.sh.
  ZUVO_AGY_FALLBACK_MODEL  Model this lane switches to when the primary is out of quota — Antigravity
                           meters each model separately (default: "Claude Opus 4.6 (Thinking)").
                           Set to "" to disable the fallback. See model-registry.sh for the bench
                           that rejected Sonnet 4.6 and GPT-OSS 120B for this slot.
  ZUVO_AGY_SILENT_COOLDOWN Seconds to skip an agy model that exhausted its quota WITHOUT saying so
                           (an exhausted Gemini just hangs ~160s and exits; default: 3600). When the
                           error does state "Resets in ...", that time is honoured instead.
  ZUVO_CURSOR_MODEL        cursor-agent model (default: composer-2.5-fast; id from 'cursor-agent models')
  ZUVO_CLAUDE_REVIEWER_MODEL  claude reviewer's Sonnet model when the author is Opus (default: claude-sonnet-5)
  ZUVO_REVIEW_ACCESS       What the codex and claude REVIEW lanes may touch: agent (default — the
                           reviewer may open the repo to check a finding), read (Read/Grep/Glob over
                           the repo root, nothing written) or none (the input only). An unknown value
                           is read. --mode blind-audit always runs none.
  CODESTRAL_API_KEY        Required for codestral provider (manual: --provider codestral)
  ZUVO_CODESTRAL_MODEL     Codestral model (default: codestral-latest)
  ZUVO_KIMI_CLI_MODEL      kimi CLI -m alias (default: kimi-code/k3-256k)
  ZUVO_KIMI_EFFORT         kimi CLI thinking effort: low|high|max (default: high)
  MOONSHOT_API_KEY         Enables kimi-api fallback when the kimi CLI is absent (Moonshot Kimi K2)
  ZUVO_KIMI_MODEL          Kimi model (default: kimi-k2.6; kimi-k2.7-code = coding variant)
  ZUVO_KIMI_BASE_URL       Kimi endpoint (default: https://api.moonshot.ai/v1; .cn for China accounts)
  ZUVO_ADV_QWEN=1          Opt IN to the `qwen` lane: Qwen Code CLI on an Alibaba Token/Coding Plan. Set
                           it up once with `qwen` → /auth → the plan you bought. The lane refuses any model
                           whose configured baseUrl is not a plan endpoint (anything else bills per token).
  ZUVO_QWEN_MODEL          qwen lane model (default: qwen3.8-flash; qwen3.8-max finds more at ~375 s/diff)
  ZUVO_ADV_OPENROUTER=1    Opt IN to the PAID OpenRouter lane (default off). Requires a key in
                           OPENROUTER_API_KEY or ~/.zuvo/openrouter.key (must be mode 600/400).
                           Adds `openrouter`, `-alt`, `-3`, `-4`. Key presence alone
                           does NOT enable it — spending is an explicit decision.
  ZUVO_OPENROUTER_MODEL    Primary OpenRouter model (default: ZUVO_MODEL_OPENROUTER from model-registry.sh, qwen/qwen3.8-flash)
  ZUVO_MODEL_OPENROUTER_ALT  Provider `openrouter-alt` (default: deepseek/deepseek-v4-flash-vision-exp)
  ZUVO_MODEL_OPENROUTER_3    Provider `openrouter-3`   (default: inception/mercury-2.5-preview)
  ZUVO_MODEL_OPENROUTER_4    Provider `openrouter-4`   (default: openai/gpt-oss-120b)
  CLAUDE_MODEL             Used for opposite-model detection (claude provider)
  --mode blind-audit only (ZUVO_REVIEW_MAX_PROVIDERS, ZUVO_REVIEW_TIMEOUT and ZUVO_RUN_DEADLINE do not apply):
  ZUVO_BLIND_AUDIT_PANEL     Panel size (default 3; agy pinned, the rest random)
  ZUVO_BLIND_AUDIT_ALLOWLIST Lanes a panel may use; can only NARROW the isolated default
  ZUVO_BLIND_AUDIT_TIMEOUT   Per-lane seconds (default 480; above 510 clamped, with a WARN — and
                             shortened so timeout + ZUVO_TIMEOUT_GRACE + 60 never passes 585)
  ZUVO_BLIND_AUDIT_EFFORT    Codex effort override (default ZUVO_CODEX_EFFORT_AUDIT, high)
  ZUVO_BLIND_AUDIT_ARGV_MAX  Prompt bytes above which agy/kimi are left out (default 120000)
  ZUVO_BLIND_AUDIT_MAX_BYTES Prompt bytes above which nothing runs, exit 6 (default 400000)
HELP
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
return 0
}

# ar_reconcile_append_artifact — the legacy `--append-artifact PATH` folded into --artifact; a conflicting pair exits 2.
ar_reconcile_append_artifact() {
# Reconcile the legacy `--append-artifact PATH` form with `--artifact PATH`, in EITHER order.
# Doing it here rather than inside the arm is what makes `--append-artifact P --artifact Q`
# fail as loudly as `--artifact Q --append-artifact P`; inside the arm the later --artifact
# would just overwrite and one of the two paths would vanish without a word.
if [[ -n "$APPEND_ARTIFACT_PATH" ]]; then
  if [[ -n "$ARTIFACT_PATH" && "$ARTIFACT_PATH" != "$APPEND_ARTIFACT_PATH" ]]; then
    echo "ERROR: --append-artifact '$APPEND_ARTIFACT_PATH' conflicts with --artifact '$ARTIFACT_PATH' — pass one path." >&2
    exit 2
  fi
  ARTIFACT_PATH="$APPEND_ARTIFACT_PATH"
fi
return 0
}

# ar_resolve_provider_env — ZUVO_REVIEW_PROVIDER as the default --provider (ignored in --mode blind-audit).
ar_resolve_provider_env() {
# Allow env var override — not in --mode blind-audit, where a global pin meant for reviews would shrink
# every panel to one lane: there only an explicit --provider picks a single lane.
if [[ -z "$PROVIDER" && -n "${ZUVO_REVIEW_PROVIDER:-}" && "$REVIEW_MODE" == blind-audit ]]; then
  echo "  NOTE: ZUVO_REVIEW_PROVIDER='$ZUVO_REVIEW_PROVIDER' is ignored in --mode blind-audit (a panel; --provider picks one lane)" >&2
else
  PROVIDER="${PROVIDER:-${ZUVO_REVIEW_PROVIDER:-}}"
fi
return 0
}

# ar_validate_mode — an unknown or unsubstituted --mode exits 2 instead of falling back to `code`.
ar_validate_mode() {
# ─── Mode validation ────────────────────────────────────────────────────────
# WHY: the FOCUS dispatch below (`case "$REVIEW_MODE"`) ends in `*) FOCUS="$FOCUS_CODE"`, so
# ANY unrecognized mode silently degraded to a generic code review while the caller believed
# it had asked for a security/tests/migrate rubric — and the observability log recorded the
# bogus mode string, so the substitution never showed up as a failure. Measured in
# ~/.zuvo/adversarial.log: 45 runs in one week were dispatched with the LITERAL string
# `{MODE}` (the unsubstituted placeholder from shared/includes/adversarial-loop.md), plus
# stray `refactor` from a skill passing its own name. Silent wrong-rubric review is the
# no-gate-substitution failure mode; fail loudly instead, matching the unknown-provider guard.
case "$REVIEW_MODE" in
  code|test|tests|security|spec|plan|audit|migrate|article|blind-audit) ;;
  \{*\}|\[*\])
    echo "ERROR: --mode received the literal placeholder '$REVIEW_MODE' — it was never substituted." >&2
    echo "  The template in shared/includes/adversarial-loop.md expects you to SET the mode first:" >&2
    echo "    _ADV_MODE=code   # or test|security|spec|plan|audit|tests|migrate|article" >&2
    echo "    ... | ~/.zuvo/adversarial-review --json --mode \"\$_ADV_MODE\"" >&2
    echo "  Pick the mode from that file's Step 1 mode table, then re-run." >&2
    exit 2 ;;
  *)
    echo "ERROR: unknown --mode '$REVIEW_MODE'." >&2
    echo "  Valid: code, test, tests, security, spec, plan, audit, migrate, article, blind-audit" >&2
    echo "  (An unknown mode used to fall back to 'code' silently — that hid the wrong rubric" >&2
    echo "   behind a passing review, so it is now a hard error.)" >&2
    exit 2 ;;
esac
return 0
}

# ar_check_plan_budget — the --mode plan round budget: past it, exit 7 before any provider runs.
ar_check_plan_budget() {
# ─── Plan-review round budget (deterministic circuit-breaker) ────────────────
# WHY: zuvo:plan splits a large scope into up to 3 sequential plan documents, and each one runs
# its own plan-reviewer loop + this adversarial pass. The skill's caps ("max 3 iterations",
# "adversarial gets ONE re-review") are PROSE — they do not COMPOSE across the 3-document split
# and the agent does not enforce them. Observed: a single zuvo:plan ran ~10 `--mode plan`
# adversarial passes (each 185-225s) across r1..r4 of three documents plus "one more independent
# review", for a 6-hour run. Each pass here shells out to 4-5 external provider CLIs.
#
# This is the composing global budget the prose lacks: it counts `--mode plan` invocations PER
# REPO within a rolling window (a plan run keeps hitting adversarial every few minutes, so the
# count accumulates; a genuinely new run 30min+ later starts fresh). Past the budget the tool
# REFUSES to run the providers and exits 7, so the loop cannot continue no matter what the agent
# decides — it must finalize the current revision. Only --mode plan is affected; code/security/
# etc. are untouched. Disable with ZUVO_PLAN_BUDGET_OFF=1 for a deliberately long session.
# --list-providers asks no provider anything, like --dry-run and --doctor: it is not a review round, and
# counting it let a few listings (a chunked plan's children ask for one each) use up the budget.
if [[ "$REVIEW_MODE" == "plan" && "${ZUVO_PLAN_BUDGET_OFF:-}" != "1" && "$DOCTOR" != "true" && "$DRY_RUN" != "true" \
      && "$LIST_PROVIDERS" != "true" ]]; then
  _pb_budget="$(ar_env_int ZUVO_PLAN_ROUND_BUDGET 8)"
  _pb_window="$(ar_env_int ZUVO_PLAN_BUDGET_WINDOW 1800)"   # 30 min: gap that separates two runs
  _pb_home="${ZUVO_HOME:-$HOME/.zuvo}"
  _pb_root="$(ar_repo_root)"
  # ar_digest16 cannot fail (no SHA tool → cksum → the path itself). An empty key would make _pb_file a
  # bare directory path — the append fails, count stays 0, and the breaker SILENTLY never fires.
  _pb_key="$(ar_digest16 "$_pb_root")"
  [ -n "$_pb_key" ] || _pb_key="default"
  _pb_dir="$_pb_home/plan-budget"; _pb_file="$_pb_dir/$_pb_key"
  mkdir -p "$_pb_dir" 2>/dev/null || true
  _pb_now="$(date +%s)"
  # Append-then-count, NOT read-modify-write. The transcript that motivated this ran the three
  # split documents' reviews in PARALLEL, so a read/increment/write counter races and loses
  # increments — under-counting under-enforces the breaker. A single `>>` of one epoch line is
  # atomic for a short write; the budget is then the number of appended lines still inside the
  # window. A race can only make two passes both append and both see the higher count, so it
  # errs toward stopping EARLIER — the safe direction for a circuit-breaker (over-enforce, never
  # under-enforce). The window also doubles as the new-run reset: old lines age out of the count.
  # A ZUVO_HOME this pass cannot write to costs the breaker this pass, not the review: it is said, and the
  # count below reads nothing instead of failing — an unreadable budget file used to end every plan review
  # with exit 2 before any provider was asked (awk's missing-file status, through pipefail).
  printf '%s\n' "$_pb_now" >> "$_pb_file" 2>/dev/null \
    || echo "  WARN: the --mode plan budget cannot be recorded ($_pb_file is not writable) — this pass is not counted" >&2
  _pb_cutoff=$(( _pb_now - _pb_window ))
  _pb_count="$( { awk -v c="$_pb_cutoff" '$1 ~ /^[0-9]+$/ && $1 >= c' "$_pb_file" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  _pb_count="${_pb_count:-1}"
  # NO inline prune. Rewriting the file (awk > tmp; mv) races with a concurrent append — a line
  # appended between the read and the mv is lost, which UNDER-counts and re-opens the very hole
  # this fixes. The count already filters to the window with awk, so out-of-window lines are
  # simply ignored; they cost ~11 bytes each and a runaway adds only tens per day, so the file
  # is bounded in practice without ever rewriting it. (Append-only is the whole point.)
  if [ "$_pb_count" -gt "$_pb_budget" ]; then
    printf '%s\n' "PLAN REVIEW BUDGET EXHAUSTED: $_pb_budget adversarial --mode plan passes already ran for this plan within ${_pb_window}s." >&2
    printf '%s\n' "  This is the deterministic circuit-breaker for the plan review loop (the skill's prose caps do" >&2
    printf '%s\n' "  not compose across the 3-document split). STOP revising: finalize the CURRENT revision, disposition" >&2
    printf '%s\n' "  remaining WARNINGs in ## Review Trail, set the plan status, and hand it to the user." >&2
    printf '%s\n' "  Override for a deliberately long session: ZUVO_PLAN_BUDGET_OFF=1. Reset: wait ${_pb_window}s or rm $_pb_file" >&2
    echo '{"status":"budget_exhausted","mode":"plan","passes":'"$_pb_count"',"budget":'"$_pb_budget"'}'
    exit 7
  fi
  echo "  plan-review budget: pass $_pb_count/$_pb_budget (window ${_pb_window}s)" >&2
fi
return 0
}
