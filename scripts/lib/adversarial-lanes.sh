# shellcheck shell=bash
# adversarial-lanes.sh — the CLI review lanes: codex (two models) and claude through the shared runner
# (scripts/lib/model-subprocess.sh), cursor-agent, agy (quota cooldown, fallback model, one transient
# retry), muse, qwen (plan-endpoint billing guard) and the kimi CLI (falling back to kimi-api).
# Each run_* prints a review on stdout and returns 0, or returns non-zero (124 = timed out).
# Sourced by scripts/adversarial-review.sh only; never executed. The HTTP lanes are in
# adversarial-lanes-http.sh; dispatch and the shared error-as-output guard in adversarial-dispatch.sh.
#
# Cut from the driver (afd4ed0d, byte for byte then). Linted as part of the whole program:
# tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on the driver with every module inlined.

# ─── Provider execution ─────────────────────────────────────────

# blind_audit_codex_effort — the ONE source of the codex audit effort in --mode blind-audit: read
# by run_codex (what actually runs the client) AND by the dispatch-loop announcement on the driver's
# own stderr (D1, Plan B Task 10 review — the two used to be two independent copies of the same
# expression, which could not drift TODAY but had nothing stopping it from drifting the next time
# either one alone got edited; tests/hooks/test-adversarial-blind-audit.sh's D1/D2 case proves the
# announced value IS the used value by deriving both from the env it set, not from a hardcoded string).
blind_audit_codex_effort() {
  printf '%s\n' "${ZUVO_BLIND_AUDIT_EFFORT:-${ZUVO_CODEX_EFFORT_AUDIT:-high}}"
}

run_codex() {
  # Generic codex runner, through the shared runner in `agent` access: the flags this lane was
  # benchmarked with, byte for byte (tests/hooks/test-adversarial-lane-golden.sh replays them).
  #   * an isolated CODEX_HOME holding only auth.json + a minimal config.toml — the model,
  #     danger-full-access + approval never (what "inherit the global profile" meant), the effort,
  #     and NO mcp_servers;
  #   * `exec --skip-git-repo-check`: that home has no trusted-directories list, so without the flag
  #     `codex exec` refuses to start whatever the cwd (field report 2026-07-12);
  #   * run FROM that home, not the caller's repo: codex also reads `<cwd>/.codex/config.toml`, and a
  #     `required = true` MCP server there whose daemon is down aborts the session before a token is
  #     spent — 19 of 20 codex failures on 2026-09-23, reported as `empty`. `-c mcp_servers={}` does
  #     not override it; a neutral cwd does, and the review arrives on stdin anyway.
  # Why each of these exists, in full: scripts/lib/model-subprocess.sh, "Access modes".
  local model="$1" provider_name="$2"
  # Effort is per-LANE, not per-process: the two codex lanes deliberately run different dials
  # (sol at `none`, luna at `medium`), so a single global would collapse them into one. The env
  # var stays as a manual override and as the fallback for callers that pass no third argument.
  # Empty = no model_reasoning_effort line: the model keeps its own default rather than a guess.
  local effort="${3:-${ZUVO_CODEX_EFFORT:-}}"
  local access
  review_access
  # --mode blind-audit: no file access at all (the prompt holds both files) and the audit effort —
  # blind_audit_codex_effort(), the SAME helper the dispatch-loop announcement calls (D1).
  # NOTE (F6, Plan B Task 10 review): the announcement itself lives at the dispatch loop
  # (the `echo "  Launching: $p..."` in the dispatch loop), NOT here — this function runs inside dispatch_provider, whose
  # stderr is redirected per-lane to $JSON_TMPDIR/provider_<p>.stderr on every successful run and
  # never re-printed, so an `echo … >&2` placed HERE is silently lost exactly when it would matter.
  if [[ "$REVIEW_MODE" == blind-audit ]]; then
    access=(--access none); effort="$(blind_audit_codex_effort)"
  fi
  runner_ready "$provider_name" || return 2
  # The model that RUNS, for provider_model: codex_cli_guard may have lowered the configured one (an old
  # CLI cannot reach gpt-6*), and the run log, the health ledger and --json "models" used to name the
  # configured model anyway. A file, not a variable — this runs in the lane's own subshell (as agy does).
  printf '%s' "$model" > "$JSON_TMPDIR/codex-effective-model-$provider_name" 2>/dev/null || true
  # Removed first: the runner opens it only once the client starts — no stale stderr is ever quoted.
  local err_file="$JSON_TMPDIR/err_${provider_name}.txt"
  rm -f -- "$err_file"
  # The prompt goes to the client from a file, written with printf '%s' — no added newline, so the
  # client's stdin is byte for byte what the old `printf '%s' "$REVIEW_PROMPT" |` fed it.
  local prompt_file="$JSON_TMPDIR/prompt_${provider_name}.txt"
  printf '%s' "$REVIEW_PROMPT" > "$prompt_file" || { echo "  WARN: ${provider_name}: cannot write the prompt file" >&2; return 2; }
  local status=0
  lane_runner "$provider_name" zms_run_codex --model "$model" --effort "$effort" "${access[@]}" \
    --prompt-file "$prompt_file" --timeout "$PROVIDER_TIMEOUT" --stderr-file "$err_file" || status=$?
  # Token accounting. `codex exec` prints "tokens used" followed by the count on its own line,
  # to STDERR, at the very end — and that stderr lives in JSON_TMPDIR, which is deleted when the
  # run ends. So the one number that says what a review actually cost is discarded on every
  # SUCCESSFUL run and kept only on failures, which is exactly backwards. Opt-in via an env var
  # so nothing changes for callers that do not ask.
  #
  # Why not estimate it from output_chars instead: reasoning tokens are invisible in the output,
  # and they are the whole difference between effort levels. A chars-based estimate would report
  # `max` as costing about the same as `none` — it would erase the very thing being measured.
  if [[ -n "${ZUVO_CODEX_TOKENS_FILE:-}" ]]; then
    local _tok
    _tok=$(grep -a -A1 '^tokens used' "$err_file" 2>/dev/null | tail -1 | tr -d ', ')
    [[ "$_tok" =~ ^[0-9]+$ ]] || _tok=""
    printf '%s\n' "$_tok" >> "$ZUVO_CODEX_TOKENS_FILE" 2>/dev/null || true
  fi
  if [[ $status -ne 0 ]]; then
    lane_exit_warn "$provider_name" "$status" 124 "$err_file" "$JSON_TMPDIR/runnererr_${provider_name}.txt"
    return "$status"
  fi
}

# lane_runner <lane> <zms_run_codex|zms_run_claude> <runner args...> — the runner call with its OWN
# stderr captured. The runner's pre-flight errors (a model id it rejects, no temp dir, a client it
# cannot find, …) go to ITS stderr, never to --stderr-file: the library opens that capture LAST, on
# purpose, so a runner that cannot start leaves the caller's file as it was. Captured here to
# $JSON_TMPDIR/runnererr_<lane>.txt — which lane_failed_warn quotes when the client left no stderr —
# and forwarded to this lane's stderr unchanged, so the provider_<lane>.stderr evidence holds it as
# before. When the capture cannot be created the runner runs uncaptured (its errors still reach the
# lane's stderr directly). Status: the runner's.
lane_runner() {
  local rerr="$JSON_TMPDIR/runnererr_$1.txt" status=0
  shift
  if ! { : > "$rerr"; } 2>/dev/null; then "$@" || return $?; return 0; fi
  "$@" 2> "$rerr" || status=$?
  if [[ -s "$rerr" ]]; then cat -- "$rerr" >&2; fi
  return "$status"
}

# QWEN_REFUSAL_MAX_CHARS — answers shorter than this are checked for the "looked for files instead of
# reviewing" refusal (the 18 real ones were 700-1100 chars; a genuine review that mentions it is longer).
QWEN_REFUSAL_MAX_CHARS=1500

# lane_failed_warn <lane> <status> <err_file> [<runner_err_file>] — quotes the first NON-empty line of the
# client's stderr (<err_file>, the runner's --stderr-file). When that holds none — the runner failed
# BEFORE the client started, so it never opened <err_file> — the first non-empty line of the runner's
# own stderr (<runner_err_file>, lane_runner's capture) instead: those failures are exactly the ones
# only the runner can name. Terminal-safe either way: ANSI sequences and C0/C1 controls stripped, tabs
# as spaces, at most 300 bytes (never a split UTF-8 char) + "…".
lane_failed_warn() {
  local snippet="" f
  for f in "$3" "${4:-}"; do
    [[ -n "$f" && -s "$f" ]] || continue
    snippet="$(_ar_quote_line first "$f")"
    [[ -z "$snippet" ]] || break
  done
  echo "  WARN: $1 failed (exit $2)${snippet:+: $snippet}" >&2
}

# lane_exit_warn <lane> <status> <timeout-status> <err_file> [<runner_err_file>] — the one WARN a lane prints
# when its client exits non-zero: <timeout-status> (124 from `timeout`, 28 from curl) is a timeout and says
# how long it had; anything else goes through lane_failed_warn. One copy for every lane: the nine before
# it had drifted, and four of them quoted the client's first stderr line raw, terminal codes and all.
lane_exit_warn() {
  if [[ "$2" -eq "$3" ]]; then echo "  WARN: $1 timed out after ${PROVIDER_TIMEOUT}s" >&2
  else lane_failed_warn "$1" "$2" "$4" "${5:-}"; fi
}

# codex_cli_guard <model> <override-var-name> -> a model this CLI can actually reach.
#
# A model id the local CLI does not know fails as an opaque 400 ("not supported when using Codex
# with a ChatGPT account") preceded by "Model metadata for `X` not found" — which reads like an
# ACCOUNT problem and is not one. Measured 2026-09-23: CLI 0.153 rejected every gpt-6 id this way;
# 0.156 accepts them. The ladder (gpt-6 -> gpt-5.6-sol -> gpt-5.5, an unreadable version counting as
# TOO OLD) lives in zms_codex_cli_guard, which asks the SAME codex the lane will run (ZUVO_CODEX_BIN,
# PATH, Codex.app) and bounds `--version` with a timeout. Without the runner the model passes through
# untouched: run_codex then fails with the named error before anything could use it.
codex_cli_guard() {
  if [[ -z "$ZMS_LOADED" ]]; then printf '%s' "$1"; return 0; fi
  zms_codex_cli_guard "$@"
}

# Lane defaults, set from the 11-configuration benchmark of 2026-09-23 (20 diffs each, full
# coverage, judged against the shared defect dictionary). The number that decided them is
# MARGINAL coverage — defects no other model in the set finds — not raw finding counts:
#
#   gpt-6-sol  / none    93% precision, 38 REAL, 5 NEW, 33s, $0.042 per new defect  <- primary
#   gpt-6-luna / medium  82% precision, 14 REAL, 2 NEW, 32s, $0.008 per new defect  <- alt
#   gpt-5.6-sol (the previous primary) costs $4/$20 per 1M — twice gpt-6-sol, for less.
#
# Counter-intuitive and the reason these are not set to `high`: raising effort raised PRECISION
# and lowered marginal value. sol at `medium` scored 100% precision and contributed ZERO new
# defects — it got conservative, and in a panel the obvious defects are already covered by
# someone else, so the value lives in the uncertain ones.
# runner_ready FIRST, before the model is chosen: without the runner nothing below can run, and the
# lane's failure must be the named no-runner error, not whatever choosing a model says first.
run_codex_54() {
  runner_ready "codex-5.4" || return 2
  run_codex "$(codex_cli_guard "$(lane_model codex-5.4)" ZUVO_MODEL_CODEX_ALT)" \
            "codex-5.4" "${ZUVO_CODEX_EFFORT_ALT:-${ZUVO_CODEX_EFFORT:-medium}}"
}
run_codex_53() {
  runner_ready "codex-5.3" || return 2
  run_codex "$(codex_cli_guard "$(lane_model codex-5.3)" ZUVO_MODEL_CODEX_PRIMARY)" \
            "codex-5.3" "${ZUVO_CODEX_EFFORT_PRIMARY:-${ZUVO_CODEX_EFFORT:-none}}"
}

# claude_lane_note — the claude lane reviews with Sonnet by DEFAULT, not by proof (CLAUDE_MODEL unset, or
# an alias with no recognized `opus` token): a Sonnet author would then get Sonnet-reviews-Sonnet. Said on
# the DRIVER's stderr as the lane starts. Inside run_claude it went to the lane's captured stderr, which
# nothing shows when the lane succeeds — the warning meant to keep this degradation from being silent was
# always silent. Nothing without the shared runner: the lane will not run at all.
claude_lane_note() {
  [[ -n "${ZMS_LOADED:-}" ]] || return 0
  [[ "$(claude_reviewer_model)" != *opus* && "${CLAUDE_MODEL:-}" != *opus* ]] || return 0
  echo "  NOTE: CLAUDE_MODEL='${CLAUDE_MODEL:-unset}' has no recognized Opus token — assuming Opus author, reviewing with Sonnet. Export CLAUDE_MODEL=<host-model> to guarantee a cross-model check (a Sonnet author here would be Sonnet-reviews-Sonnet)." >&2
}

run_claude() {
  local model effort=""
  # FIRST: without the runner the lane cannot run, so no model is chosen (and claude_lane_note says
  # nothing: on a Codex host HOST_PROVIDER is also empty in that state — the note's premise would be wrong).
  runner_ready claude || return 2
  model=$(claude_reviewer_model)
  # Opus reviews at its measured effort. Sonnet (CLAUDE_MODEL unset: the common Opus author assumed — a
  # heuristic, not proof, which claude_lane_note says as the lane starts) runs at its default.
  if [[ "$model" == *opus* ]]; then
    effort="${ZUVO_CLAUDE_REVIEWER_OPUS_EFFORT:-high}"
  fi

  local err_file="$JSON_TMPDIR/err_claude.txt"
  rm -f -- "$err_file"   # fresh per call — see run_codex
  # Lean reviewer subprocess, through the shared runner in `agent` access (the benchmarked flags,
  # byte for byte): an empty --strict-mcp-config drops project MCP servers (starting CodeSift via
  # `npx` on every call can HANG inside a codex/agent sandbox → the field timeout 2026-07-12), and
  # --dangerously-skip-permissions stops a tool/permission prompt from blocking a headless run. Run
  # from this process's cwd, as before. --bare would be leaner but forces ANTHROPIC_API_KEY (fails
  # on OAuth-authed claude). Prompt file: see run_codex.
  local prompt_file="$JSON_TMPDIR/prompt_claude.txt"
  printf '%s' "$REVIEW_PROMPT" > "$prompt_file" || { echo "  WARN: claude: cannot write the prompt file" >&2; return 2; }
  local status=0
  local access
  review_access
  # --mode blind-audit: no tools, no MCP, no session, a neutral cwd (the runner's access `none`).
  if [[ "$REVIEW_MODE" == blind-audit ]]; then access=(--access none); fi
  lane_runner claude zms_run_claude --model "$model" --effort "$effort" "${access[@]}" \
    --prompt-file "$prompt_file" --timeout "$PROVIDER_TIMEOUT" --stderr-file "$err_file" || status=$?
  if [[ $status -ne 0 ]]; then
    lane_exit_warn claude "$status" 124 "$err_file" "$JSON_TMPDIR/runnererr_claude.txt"
    return "$status"
  fi
}

run_cursor_agent() {
  # --workspace /tmp avoids loading project context (~3.5K tokens saved).
  # The model comes from provider_model — the same expression the run log, the health ledger and
  # --json "models" report — so what runs and what is reported cannot drift apart again (until
  # 2026-10-04 this line kept its own default, composer-2.5-fast, while the label said `auto`).
  # Default in model-registry.sh (ZUVO_MODEL_CURSOR); override with ZUVO_CURSOR_MODEL.
  local model; model="$(provider_model cursor-agent)"
  lane_model_ok cursor-agent "$model" || return 1
  local err_file="$JSON_TMPDIR/err_cursor-agent.txt"
  local out_file="$JSON_TMPDIR/raw_cursor-agent.txt"
  local result status=0
  # Capture through a FILE, never $( ): a command substitution blocks until EVERY process
  # holding the pipe closes it, so a single grandchild that outlives the timeout hangs the
  # whole review long past its budget (the 9.5h outlier). A plain > has no such reader.
  printf '%s' "$REVIEW_PROMPT" \
    | timeout $TIMEOUT_KILL_FLAG "$PROVIDER_TIMEOUT" cursor-agent -p --model "$model" --mode ask --trust --workspace /tmp \
      > "$out_file" 2>"$err_file" \
    || status=$?
  result="$(cat "$out_file" 2>/dev/null)"
  if [[ $status -ne 0 ]]; then
    lane_exit_warn cursor-agent "$status" 124 "$err_file"
    return "$status"
  fi
  # A detached session that prints only `SESSION_ID=<digits>` is not a review — treat as
  # failure so the caller moves on instead of recording it as a completed adversarial pass
  # (same class of guard as run_agy's quota/auth error-output check).
  if [[ "$(printf '%s' "$result" | tr -d '[:space:]')" =~ ^SESSION_ID=[0-9]+$ ]]; then
    echo "  WARN: cursor-agent returned only a session id (detached session), not a review" >&2
    return 1
  fi
  printf '%s\n' "$result"
}

# ── agy lane: quota cooldown + one retry for TRANSIENT errors ───────────────
#
# Antigravity meters each model separately (verified 2026-09-22: Gemini exhausted for the week
# while Sonnet 4.6 and GPT-OSS answered in 15-25s), so a dead model is not a dead lane. Three
# failure shapes, measured, each needing a different answer:
#
#   quota, spoken   "Individual quota reached ... Resets in 3h12m58s"  -> honour the stated reset
#   quota, SILENT   exhausted Gemini does not say so: agy hangs ~150-175s and exits with
#                   "error: interrupted" on stderr and nothing on stdout. Five real reviews on
#                   2026-09-21 each burned ~160s to return nothing, on a PINNED lane, all day.
#   transient       503 "No capacity available", or "Eligibility check failed: failed to get
#                   profile picture" (agy resolves the account avatar from lh3.googleusercontent
#                   .com on every call and fails the whole review when that dial times out).
#                   Measured over the bench: one retry recovered 3 of 8 and 3 of 4.
#
# A TIMEOUT is never retried. D1 (tests/adversarial/test-d1-no-retry.sh) fixed the contract that
# the first timeout is the final timeout, so no path here may open a second timeout window; the
# transient errors above all return in 1-15s, which is why retrying them does not reopen it.
_agy_cooldown_file() {
  local slug
  slug=$(printf '%s' "$1" | tr 'A-Z ()' 'a-z---' | tr -cd 'a-z0-9.-')
  printf '%s/agy-cooldown-%s' "${ZUVO_HOME:-$HOME/.zuvo}" "${slug:-unknown}"
}

_agy_on_cooldown() {   # 0 = still cooling down
  local f until
  f=$(_agy_cooldown_file "$1")
  [[ -f "$f" ]] || return 1
  until="$(ar_decimal "$(cat "$f" 2>/dev/null || true)" "")"
  [[ -n "$until" ]] || return 1
  [[ "$(date +%s)" -lt "$until" ]]
}

_agy_start_cooldown() {  # $1 model, $2 seconds
  local f; f=$(_agy_cooldown_file "$1")
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
  printf '%s\n' "$(( $(date +%s) + $2 ))" > "$f" 2>/dev/null || true
}

# The quota error carries its own reset time. Parsing it beats any constant we could pick:
# a weekly exhaustion and a five-hour one look identical except for this string.
_agy_reset_seconds() {   # stdin: error text -> seconds, or nothing
  sed -n 's/.*[Rr]esets in \([0-9hms]*\).*/\1/p' | head -1 | awk '
    { s=0
      if (match($0,/[0-9]+h/)) s += substr($0,RSTART,RLENGTH-1)*3600
      if (match($0,/[0-9]+m/)) s += substr($0,RSTART,RLENGTH-1)*60
      if (match($0,/[0-9]+s/)) s += substr($0,RSTART,RLENGTH-1)
      if (s>0) print s }'
}

# Sets _AGY_CLASS (ok|quota|transient|timeout|failed) and leaves the body in $_AGY_BODY_FILE.
# NOT a $( ) helper on purpose: a subshell could not report the class back, and the body is
# captured to a file for the same reason run_cursor_agent does it.
# _ar_lane_budget <start> — what is left of this lane's PROVIDER_TIMEOUT since <start> (a $SECONDS reading
# taken when the lane began), in whole seconds; status 1 and nothing printed when that is under
# LANE_MIN_RETRY_SECONDS — or under half the lane's timeout, when that is shorter: a lane configured for 20 s
# still gets its retry with 10 s left. A lane's second call — agy's fallback model, its transient retry, kimi's API
# lane — used to get a whole fresh PROVIDER_TIMEOUT, so one lane could take twice its budget and run past
# the whole-run deadline, which then killed the run and every other lane's answer with it.
_ar_lane_budget() {
  local left=$(( PROVIDER_TIMEOUT - (SECONDS - $1) )) floor=$LANE_MIN_RETRY_SECONDS
  (( floor <= PROVIDER_TIMEOUT / 2 )) || floor=$(( PROVIDER_TIMEOUT / 2 ))
  (( left > 0 && left >= floor )) || return 1
  printf '%s' "$left"
}

_agy_attempt() {
  local model="$1" status=0 result err combined a0=$SECONDS
  local err_file="$JSON_TMPDIR/err_agy.txt"
  _AGY_BODY_FILE="$JSON_TMPDIR/raw_agy.txt"
  if [[ "$REVIEW_MODE" == blind-audit ]]; then
    # As the 2026-09-25 spike measured it: NEVER --dangerously-skip-permissions (with it agy read outside
    # its cwd whatever else was passed), the no-tools line first, an empty cwd; --mode plan/--sandbox add nothing.
    local ws="$JSON_TMPDIR/agy_ws"
    mkdir -p "$ws" 2>/dev/null || { _AGY_CLASS="failed"; _AGY_ERR_TEXT="cannot create $ws"; return 1; }
    (cd "$ws" && OLDPWD="$ws" timeout $TIMEOUT_KILL_FLAG "$PROVIDER_TIMEOUT" agy -p "$BA_AGY_PREFIX"$'\n\n'"$REVIEW_PROMPT" \
      --model "$model") < /dev/null > "$_AGY_BODY_FILE" 2>"$err_file" || status=$?
  else
    timeout $TIMEOUT_KILL_FLAG "$PROVIDER_TIMEOUT" agy -p "$REVIEW_PROMPT" \
      --model "$model" --dangerously-skip-permissions > "$_AGY_BODY_FILE" 2>"$err_file" || status=$?
  fi
  result="$(cat "$_AGY_BODY_FILE" 2>/dev/null)"
  err="$(cat "$err_file" 2>/dev/null)"
  combined="$err
$result"
  _AGY_ERR_TEXT="$combined"
  if [[ $status -eq 124 ]]; then _AGY_CLASS="timeout"; return 1; fi
  # 137 is timeout's own SIGKILL when agy outlived the TERM by the grace: a timeout, as dispatch_provider maps
  # it — when the budget was spent; an early 137 is a kill from outside (OOM, an operator).
  if [[ $status -eq 137 && $(( SECONDS - a0 )) -ge $(( PROVIDER_TIMEOUT > 2 ? PROVIDER_TIMEOUT - 2 : PROVIDER_TIMEOUT )) ]]; then
    _AGY_CLASS="timeout"; return 1
  fi
  # Stopped by a signal (the run's own cleanup, an orchestrator's TERM, an early KILL): `timeout` exits 128+N.
  # agy then prints "interrupted"/"context canceled" — its silent quota exhaustion's words below — and the
  # model was cooled down for an hour for a review the run itself had cancelled (130/143 were checked here;
  # 137, timeout's own escalation, was not, so a slow model read as an exhausted one).
  if [[ $status -gt 128 ]]; then
    _AGY_CLASS="failed"; _AGY_ERR_TEXT="stopped by a signal (exit $status)"; return 1
  fi
  # agy can exit 0 while printing a quota/auth error AS its output (verified 2026-07-12), so the
  # classification reads stderr AND stdout. Without it a quota'd agy passes its error string
  # downstream as a CLEAN review with zero findings — a false-clean adversarial pass.
  case "$combined" in
    *"quota reached"*|*"Please upgrade your subscription"*)
      _AGY_CLASS="quota"; return 1 ;;
    *"No capacity available"*|*"code 503"*|*"high traffic"*|*"Eligibility check failed"*)
      _AGY_CLASS="transient"; return 1 ;;
    *"Authentication required"*|*"IneligibleTier"*|*"Please run 'agy login'"*|*"Please sign in"*)
      _AGY_CLASS="failed"; return 1 ;;
  esac
  if [[ $status -ne 0 || -z "$result" ]]; then
    # The silent exhaustion above: no message, just a long hang and an empty body.
    case "$err" in
      *interrupted*|*"context canceled"*) _AGY_CLASS="quota" ;;
      *)                                   _AGY_CLASS="failed" ;;
    esac
    return 1
  fi
  case "$result" in
    Error:*) _AGY_CLASS="failed"; return 1 ;;
  esac
  _AGY_CLASS="ok"; return 0
}

# A successful fallback has to be VISIBLE. Provider stderr is captured per provider and only
# kept when the provider FAILS, so the "answered on fallback" note was written to a file nobody
# reads on the happy path — the reviewer's identity silently changed and the output looked the
# same. The reader of a review is the person who must know which model wrote it, so it goes in
# the body, one line, above the findings.
_agy_emit() {   # $1 = model used, $2 = primary
  if [[ "$1" != "$2" ]]; then
    echo "[agy] fallback model: $1 (primary '$2' is out of quota)"
    echo "  NOTE: agy answered on fallback model '$1'" >&2
  fi
  cat "$_AGY_BODY_FILE"
}

run_agy() {
  # Antigravity CLI (agy) — Google's SANCTIONED headless channel via the paid Antigravity auth.
  # Two invocation facts, both verified on 2026-07-11:
  #   * the prompt is passed as an ARGUMENT (`agy -p "$PROMPT"`), NOT via stdin — piping stdin
  #     makes agy answer an empty/default prompt (it hallucinated instead of echoing the test).
  #   * --model takes the DISPLAY name from `agy models` (e.g. "Gemini 3.8 Flash (High)").
  # --dangerously-skip-permissions is required so a headless run never blocks on a permission
  # prompt. Override with ZUVO_AGY_MODEL; the fallback with ZUVO_AGY_FALLBACK_MODEL ("" disables).
  local primary fallback m attempted=0 cooled=0 cd t0=$SECONDS left
  primary="$(lane_model agy)"
  fallback="${ZUVO_AGY_FALLBACK_MODEL-${ZUVO_MODEL_AGY_FALLBACK-Claude Opus 4.6 (Thinking)}}"

  for m in "$primary" "$fallback"; do
    [[ -n "$m" ]] || continue
    [[ "$attempted" -gt 0 && "$m" == "$primary" ]] && continue
    if _agy_on_cooldown "$m"; then
      echo "  NOTE: agy model '$m' is on quota cooldown — skipping without spending its timeout" >&2
      cooled=1
      continue
    fi
    # The first model gets what is left of the lane's timeout (all of it but the cooldown checks); a
    # fallback what the first one left of it, if that is still worth a call.
    if [[ "$attempted" -eq 0 ]]; then
      left=$(( PROVIDER_TIMEOUT - (SECONDS - t0) ))
      # Nothing left (the cooldown checks took it all: a stalled ZUVO_HOME, a suspend): the lane timed out.
      # Passed on, 0 is `timeout 0` — no limit at all — and a negative value a timeout(1) usage error.
      if [[ "$left" -lt 1 ]]; then
        echo "  WARN: agy timed out — nothing left of the lane's ${PROVIDER_TIMEOUT}s before '$m' could start" >&2
        printf '%s' "$primary" > "$JSON_TMPDIR/agy-effective-model" 2>/dev/null || true
        return 124
      fi
    elif ! left="$(_ar_lane_budget "$t0")"; then
      echo "  NOTE: agy fallback '$m' not started — $(( PROVIDER_TIMEOUT - (SECONDS - t0) ))s left of the lane's ${PROVIDER_TIMEOUT}s" >&2
      break
    fi
    attempted=$((attempted + 1))
    printf '%s' "$m" > "$JSON_TMPDIR/agy-effective-model" 2>/dev/null || true
    if PROVIDER_TIMEOUT="$left" _agy_attempt "$m"; then
      _agy_emit "$m" "$primary"
      return 0
    fi
    case "$_AGY_CLASS" in
      transient)
        # Fast-failing infrastructure, not the model. One retry, no timeout window reopened.
        echo "  NOTE: agy transient error on '$m' — one retry: $(printf '%s' "$_AGY_ERR_TEXT" | _ar_quote_line first -)" >&2
        sleep 2
        if left="$(_ar_lane_budget "$t0")"; then
          if PROVIDER_TIMEOUT="$left" _agy_attempt "$m"; then
            _agy_emit "$m" "$primary"
            return 0
          fi
        else
          echo "  NOTE: agy retry on '$m' not started — too little left of the lane's ${PROVIDER_TIMEOUT}s" >&2
        fi
        ;;
      timeout)
        echo "  WARN: agy timed out after ${left}s on '$m'" >&2
        printf '%s' "$primary" > "$JSON_TMPDIR/agy-effective-model" 2>/dev/null || true   # see the end
        return 124 ;;
    esac
    if [[ "$_AGY_CLASS" == "quota" ]]; then
      cd=$(printf '%s' "$_AGY_ERR_TEXT" | _agy_reset_seconds)
      # No stated reset (the silent shape) -> one hour: short enough to self-heal, long enough
      # to stop every chunk of every run paying ~160s to rediscover the same exhaustion.
      [[ -n "$cd" ]] || cd="$(ar_env_int ZUVO_AGY_SILENT_COOLDOWN 3600)"
      _agy_start_cooldown "$m" "$cd"
      echo "  WARN: agy model '$m' is out of quota — cooling it down for $((cd / 60)) min" >&2
    else
      echo "  WARN: agy failed on '$m': $(printf '%s' "$_AGY_ERR_TEXT" | _ar_quote_line first -)" >&2
    fi
  done

  [[ "$attempted" -eq 0 && "$cooled" -eq 1 ]] && \
    echo "  WARN: agy skipped — every configured model is on quota cooldown" >&2
  # A lane that answered on NO model is recorded under its configured model — the one the bench looks up
  # before the run (the effective-model file names the fallback once that was tried). Recorded under the
  # fallback, a lane whose two models both failed was never benched, however often it failed.
  printf '%s' "$primary" > "$JSON_TMPDIR/agy-effective-model" 2>/dev/null || true
  return 1
}

run_muse() {
  # Muse Code (`muse`) — an interactive coding agent with a headless `exec` mode. Two things
  # about it are not like the other CLI lanes and both are deliberate here:
  #
  #   * THE PROMPT GOES IN A FILE. `--prompt-file` exists, and a review prompt carrying a 30 KB
  #     diff as an argv string is how a lane starts failing with "argument list too long" on the
  #     exact inputs that matter most (the big ones).
  #   * IT RUNS IN AN EMPTY WORKSPACE. This is an agent with tool access, and it has no
  #     read-only permission profile ('read-only'/'readonly' both answer "profile does not
  #     exist"). The code under review is IN the prompt, not on disk, so pointing --workspace at
  #     a throwaway directory removes the question of whether a reviewer can edit the thing it is
  #     reviewing. It also silences the "workspace untrusted, AGENTS.md skipped" warning that
  #     would otherwise be the first thing in every captured stderr.
  #
  # Model: `--model` DOES work here. Verified 2026-09-22 by reading model_id back out of the
  # --json event stream, in BOTH directions: with the flag omitted (model_id=muse-spark-1.3,
  # i.e. the CLI default) and with it set to muse-spark-1.1 / 1.2 / glimmer-30b (each echoed
  # back the id asked for). An earlier note in this lane said the flag was ignored; that was
  # wrong, and the evidence was misread — a bogus id is accepted and silently falls back to the
  # default rather than erroring, which looks identical to "the flag does nothing".
  # The default is now passed EXPLICITLY rather than relied upon, so what provider_model()
  # reports and what the CLI is asked for are one expression instead of two that agree today.
  # A lane whose log names a model nobody requested poisons its own bench the same way the agy
  # fallback did when it logged the primary model after answering on the fallback.
  #
  # Measured on the shared 20-diff bench, judged by Fable, all three through THIS CLI:
  #   muse-spark-1.3  69% precision, +21 unique defects   <- second best in the whole field
  #   muse-spark-1.2  52%, +12  (3x faster: 65-166s vs 190-245s)
  #   muse-spark-1.1  56%, +12
  #   muse-glimmer-30b  20 attempts, 20 empty replies — not usable through this plan
  # The older versions are not a speed/quality trade, they are worse on both axes. Measured through
  # OpenRouter on the shared 20-diff bench, meta/muse-spark-1.3 scored 73% precision and +15
  # defects nobody else in the set found — third best measured, behind Gemini 3.8 Flash and
  # kat-coder. This lane reaches that family without the metered OpenRouter hop.
  # ASK provider_model() rather than re-deriving the fallback chain. That function is what the
  # run log, the health ledger and --doctor report, so deriving the id here a second time makes
  # the label and the request two expressions that merely agree — and the next person to bump
  # the default in one of them reintroduces exactly the defect this lane just fixed, silently:
  # rows attributed to a model nobody invoked, with no error anywhere. One source, one answer.
  # (Leaving it empty was the original form: the CLI then picked while provider_model() claimed
  # "muse-spark-1.3". It happened to be right — a --json probe with the flag OMITTED does return
  # model_id=muse-spark-1.3 — and "correct by coincidence" is the agy-fallback defect with a
  # longer fuse.)
  local model; model="$(provider_model muse)"
  local ws="$JSON_TMPDIR/muse_ws"
  local pf="$JSON_TMPDIR/muse_prompt.txt"
  local out_file="$JSON_TMPDIR/raw_muse.txt"
  local err_file="$JSON_TMPDIR/err_muse.txt"
  mkdir -p "$ws" 2>/dev/null || return 1
  printf '%s' "$REVIEW_PROMPT" > "$pf" 2>/dev/null || return 1

  local args=(exec --prompt-file "$pf" --workspace "$ws")
  # Unconditional: provider_model() always yields a concrete id, so a guard here would only
  # suggest an empty-model path that no longer exists.
  args+=(--model "$model")

  local status=0 result
  timeout $TIMEOUT_KILL_FLAG "$PROVIDER_TIMEOUT" muse "${args[@]}" \
    > "$out_file" 2>"$err_file" || status=$?
  result="$(cat "$out_file" 2>/dev/null)"
  if [[ $status -ne 0 || -z "$result" ]]; then
    lane_exit_warn muse "$status" 124 "$err_file"
    [[ $status -eq 0 ]] && status=1
    return "$status"
  fi
  # Error-as-output guard, the agy lesson: an exit-0 body carrying a quota/auth message would
  # otherwise travel downstream as a CLEAN review with zero findings — a false-clean pass.
  if lane_error_text muse "$result" > /dev/null; then
    echo "  WARN: muse unusable (auth/quota), not a review: $(printf '%s' "$result" | _ar_quote_line first - "$LANE_ERR_QUOTE_CHARS")" >&2
    return 1
  fi
  printf '%s\n' "$result"
}

# Plan billing guard for the qwen lane. Model Studio sells two prepaid plans with plan keys
# (sk-sp-…), each on its own base URL: Coding Plan on coding(-intl).dashscope.aliyuncs.com and
# Token Plan on token-plan.{ap-southeast-1,cn-beijing}.maas.aliyuncs.com — an explicit host list, not a
# `token-plan.*` pattern: this is a money check, so a region the vendor adds later must be ADDED here
# (a refusal) rather than matched by accident. The general dashscope(-intl) compatible-mode
# endpoint is pay-as-you-go — "the system identifies the calls as pay-as-you-go and bills them
# accordingly" (Coding Plan FAQ). Same trap as the BytePlus lane, so only the plan hosts pass.
# The first cut listed only the Coding Plan hosts; the owner's subscription turned out to be a
# Token Plan and `/auth` → Coding Plan produced a 401 that looked like a dead key. The CLI resolves `-m <id>` through ~/.qwen/settings.json `modelProviders`, so
# that is what gets checked: the model must be declared there with a plan base URL, or no call is
# made. Fails CLOSED — an unreadable settings file is a refusal, not a pass.
_qwen_plan_guard() { # _qwen_plan_guard <model> -> 0 plan endpoint, 1 refused (reason on stderr)
  local model="$1" settings="${ZUVO_QWEN_SETTINGS:-$HOME/.qwen/settings.json}"
  python3 - "$settings" "$model" <<'PY'
import json, sys
from urllib.parse import urlparse
path, model = sys.argv[1], sys.argv[2]
PLAN_HOSTS = {"coding.dashscope.aliyuncs.com", "coding-intl.dashscope.aliyuncs.com",
              "token-plan.ap-southeast-1.maas.aliyuncs.com", "token-plan.cn-beijing.maas.aliyuncs.com"}
try:
    with open(path) as fh:
        cfg = json.load(fh)
except Exception as exc:
    print(f"  WARN: qwen: cannot read {path} ({exc.__class__.__name__}) — refusing: the plan endpoint cannot be verified", file=sys.stderr)
    sys.exit(1)
seen = []
for entries in (cfg.get("modelProviders") or {}).values():
    for entry in entries if isinstance(entries, list) else []:
        if isinstance(entry, dict) and entry.get("id") == model:
            seen.append(str(entry.get("baseUrl", "")))
if not seen:
    print(f"  WARN: qwen: model '{model}' is not configured in {path} — run `qwen`, then /auth -> Token Plan or Coding Plan", file=sys.stderr)
    sys.exit(1)
bad = [u for u in seen if (urlparse(u).hostname or "") not in PLAN_HOSTS or urlparse(u).scheme != "https"]
if bad:
    print(f"  WARN: qwen: refusing — '{model}' points at {bad[0]}, which is not a Token/Coding Plan endpoint and would bill per token", file=sys.stderr)
    sys.exit(1)
PY
}

run_qwen() {
  # Qwen Code CLI (`qwen`), headless. Verified against v0.20.0 with a local OpenAI-compatible
  # stub before any real call was made:
  #   * `-p` is APPENDED to stdin, so the review prompt goes in on stdin and `-p` carries only a
  #     one-line trailer — no 30 KB argv (the muse lesson), and both reach the model as one
  #     user message.
  #   * `-o json` returns an array ending in {"type":"result","is_error":…,"result":"<text>"};
  #     `-o text` would leave nothing to tell an error body from a review.
  #   * --safe-mode drops the owner's hooks, extensions, skills, MCP servers and QWEN.md, so a
  #     review is not steered by whatever the interactive setup loads. It does NOT drop auth.
  #   * it runs in an EMPTY directory: this is an agent with file tools, and the code under
  #     review is in the prompt, not on disk.
  #   * OPENAI_* are cleared for the call: the CLI honours them over settings.json, so an
  #     OpenRouter key in the caller's env would silently re-route the plan lane.
  #   * NO TOOL CALLS. Measured on the 20-input bench (2026-09-23): 21 of 200 reviews came back as
  #     "nothing to review — the workspace is empty". The word "review" makes Qwen Code reach for
  #     its bundled /review skill and file tools, find the empty dir, and never read the diff that
  #     is sitting in the prompt (deepseek-v4-flash: 7 of 20). --exclude-tools cannot stop it: the
  #     tool set is deferred, and removing ten tools surfaced twelve others. So the trailer says
  #     outright that the code is in the message, --max-tool-calls 0 turns any tool attempt into a
  #     hard failure instead of a fake clean review, and a short "workspace is empty" body is
  #     rejected below. Same refused input, before/after: wandered off vs. a full review.
  command -v qwen &>/dev/null || return 1
  local model
  model="$(lane_model qwen)"
  lane_model_ok qwen "$model" || return 1
  _qwen_plan_guard "$model" || return 1

  local ws="$JSON_TMPDIR/qwen_ws"
  local pf="$JSON_TMPDIR/qwen_prompt.txt"
  local out_file="$JSON_TMPDIR/raw_qwen.json"
  local err_file="$JSON_TMPDIR/err_qwen.txt"
  mkdir -p "$ws" 2>/dev/null || return 1
  printf '%s' "$REVIEW_PROMPT" > "$pf" 2>/dev/null || return 1

  local status=0
  (cd "$ws" && env -u OPENAI_API_KEY -u OPENAI_BASE_URL -u OPENAI_MODEL \
    timeout $TIMEOUT_KILL_FLAG "$PROVIDER_TIMEOUT" \
    qwen -p "Everything you need is in this message: the complete code under review is included above. Do NOT use any tool, do NOT read the filesystem, do NOT invoke any skill or slash command. Reply with the findings only." \
      -o json -m "$model" --safe-mode --max-tool-calls 0 \
      < "$pf" > "$out_file" 2>"$err_file") || status=$?
  if [[ $status -eq 124 ]]; then
    echo "  WARN: qwen timed out after ${PROVIDER_TIMEOUT}s" >&2
    return 124
  fi

  # The final event carries both the verdict and the text. An error still exits through here
  # with a well-formed array, so is_error — not the exit code — decides.
  local parsed
  parsed=$(jq -r 'if type=="array" then (map(select(.type=="result")) | last) else . end
                  | if . == null then "ERR\tno result event"
                    elif .is_error then "ERR\t" + ((.error.message // .result // "is_error") | tostring)
                    else "OK\t" + (.result // "") end' "$out_file" 2>/dev/null) || parsed=""
  case "$parsed" in
    OK$'\t'?*)
      local text="${parsed#OK$'\t'}"
      # Length-gated error-as-output guard (the agy lesson): a short "success" body that is
      # really a quota/auth notice must not travel on as a clean review with zero findings.
      if lane_error_text qwen "$text" > /dev/null; then
        echo "  WARN: qwen returned a quota/auth notice, not a review: $(printf '%s' "$text" | _ar_quote_line first - "$LANE_ERR_QUOTE_CHARS")" >&2
        return 1
      fi
      # A reviewer that went looking on disk instead of reading the prompt (see NO TOOL CALLS
      # above) answers "nothing to review". That is not a clean verdict — it never saw the code.
      # Patterns and the QWEN_REFUSAL_MAX_CHARS gate come from the 18 real refusals (700-1100 chars): the
      # gate keeps a genuine review that merely MENTIONS the empty dir (2.4k chars, bench) out of it.
      if [[ ${#text} -lt $QWEN_REFUSAL_MAX_CHARS ]] && printf '%s' "$text" | tr '[:upper:]' '[:lower:]' \
           | grep -qE 'nothing to review|no changes to review|no review target|not present in the workspace|skill[^.]{0,40}(could not be invoked|denied|declined)|(workspace|working directory).{0,200}(empty|no files)'; then
        echo "  WARN: qwen looked for files instead of reviewing the prompt — not a review: $(printf '%s' "$text" | _ar_quote_line first - "$LANE_ERR_QUOTE_CHARS")" >&2
        return 1
      fi
      printf '%s\n' "$text" ;;
    ERR$'\t'*)
      echo "  WARN: qwen failed: $(printf '%s' "${parsed#ERR$'\t'}" | _ar_quote_line first -)" >&2
      return 1 ;;
    *)
      echo "  WARN: qwen failed (exit $status, no parsable result): $(_ar_quote_line first "$err_file")" >&2
      [[ $status -eq 0 ]] && status=1
      return "$status" ;;
  esac
}

run_kimi() {
  # Moonshot Kimi CLI (kimi-code, OAuth) — headless -p mode. stream-json gives clean
  # {"role":"assistant","content":...} lines (plain text mode leaks reasoning bullets + a
  # resume-hint footer into the review). Prompt is an ARG like agy. Runs from the JSON tmpdir;
  # NEVER pass -y.
  command -v kimi &>/dev/null || return 1
  local t0=$SECONDS left   # the API fallback below gets only what the CLI leaves of the lane's timeout

  # Model and effort defaults live in model-registry.sh, with the measurement behind them. The model is
  # checked, not repaired (lane_model_ok): arg-quoting prevents shell breakout, but a flag-like or quoted
  # env value could still confuse the CLI's own arg parser — and a repaired id runs a model the label
  # does not name.
  local model_flag effort
  model_flag="$(lane_model kimi)"
  lane_model_ok kimi "$model_flag" || return 1
  # Effort goes through the CLI's own env override for THIS call only — the owner's
  # ~/.kimi-code/config.toml also drives interactive kimi and stays untouched.
  effort=$(printf '%s' "${ZUVO_KIMI_EFFORT:-${ZUVO_MODEL_KIMI_CLI_EFFORT:-high}}" | tr -cd 'a-z')
  case "$effort" in low|high|max) ;; *) effort=high ;; esac

  # A reviewer with NO tools. The default kimi agent runs shell commands on its own initiative:
  # a 2026-09-24 bench run timed out with a listing of the owner's home directory in its output.
  # "Runs from the tmpdir" only moved where it started; `tools: []` is what removes the ability.
  # The review prompt embeds the whole diff, so nothing is lost.
  local agent_file="$JSON_TMPDIR/kimi_reviewer.md"
  cat > "$agent_file" <<'KIMI_AGENT'
---
name: zuvo-reviewer
description: "Adversarial code reviewer. Reviews only the code in the prompt; has no tools."
tools: []
---

You are a code reviewer. Everything you need is in the user's message. You have no tools.
KIMI_AGENT

  local raw_file="$JSON_TMPDIR/kimi_raw.jsonl"
  local err_file="$JSON_TMPDIR/err_kimi.txt"
  local status=0
  (cd "$JSON_TMPDIR" && KIMI_MODEL_THINKING_EFFORT="$effort" timeout $TIMEOUT_KILL_FLAG "$PROVIDER_TIMEOUT" \
    kimi -p "$REVIEW_PROMPT" --output-format stream-json -m "$model_flag" --agent-file "$agent_file" \
    > "$raw_file" 2>"$err_file") || status=$?
  if [[ $status -eq 124 ]]; then
    echo "  WARN: kimi timed out after ${PROVIDER_TIMEOUT}s" >&2
    return 124
  fi
  if [[ $status -ne 0 ]]; then
    # An exhausted plan (5-hour or weekly limit) is a 403 on stderr with exit 1. Until
    # 2026-09-24 it landed as outcome "empty" — indistinguishable from a model that answered
    # nothing, which is how "kimi: 32 consecutive empties" in the health ledger went unexplained.
    # The marker lets the caller record `kimi:quota` instead.
    if grep -qiE 'usage limit|quota|provider\.auth_error: 403' "$err_file" 2>/dev/null; then
      : > "$JSON_TMPDIR/quota_kimi"
      echo "  WARN: kimi plan limit reached — not a review: $(grep -m1 -oiE "reached your [a-z0-9() -]*usage limit" "$err_file")" >&2
    else
      lane_failed_warn kimi "$status" "$err_file"
    fi
    # R-12: an installed-but-dead CLI must not black-hole the vendor (the documented
    # dead-gemini-CLI-shadows-working-key trap). If a key exists, try the API lane.
    if [[ -n "${MOONSHOT_API_KEY:-}" ]]; then
      if left="$(_ar_lane_budget "$t0")"; then
        echo "  INFO: kimi CLI failed — falling back to kimi-api (MOONSHOT_API_KEY set, ${left}s left)" >&2
        PROVIDER_TIMEOUT="$left" run_kimi_api && { rm -f "$JSON_TMPDIR/quota_kimi"; return 0; }
      else
        echo "  NOTE: kimi-api fallback not started — too little left of the lane's ${PROVIDER_TIMEOUT}s" >&2
      fi
    fi
    return "$status"
  fi

  # Extract assistant messages only (drops meta/resume-hint/tool lines)
  local text
  text=$(jq -r 'select(.role=="assistant") | .content // empty' "$raw_file" 2>/dev/null)

  # Error-as-output guard (agy lesson): exit-0 body carrying an error/quota message
  # must not be consumed as a CLEAN review. Case-insensitive (R-11). Length-gated
  # (fix-pass findings 3+5 in tension): genuine provider error bodies are SHORT —
  # scan those fully; a LONG body is a real review that may legitimately QUOTE
  # "rate limit"/"not authenticated" in findings, so only an error: PREFIX rejects it.
  local verdict
  if verdict="$(lane_error_text kimi "$text")"; then
    if [[ "$verdict" == short ]]; then
      echo "  WARN: kimi returned empty/error output: $(printf '%s' "$text" | _ar_quote_line first - "$LANE_ERR_QUOTE_CHARS")" >&2
      # Fix-pass finding 4: an exit-0 error body must ALSO try the API lane (R-12
      # only covered non-zero exits) — otherwise a rate-limited CLI blocks a working key.
      if [[ -n "${MOONSHOT_API_KEY:-}" ]]; then
        if left="$(_ar_lane_budget "$t0")"; then
          echo "  INFO: kimi CLI error-body — falling back to kimi-api (MOONSHOT_API_KEY set, ${left}s left)" >&2
          PROVIDER_TIMEOUT="$left" run_kimi_api && return 0
        else
          echo "  NOTE: kimi-api fallback not started — too little left of the lane's ${PROVIDER_TIMEOUT}s" >&2
        fi
      fi
    else
      echo "  WARN: kimi returned error-prefixed output: $(printf '%s' "$text" | _ar_quote_line first - "$LANE_ERR_QUOTE_CHARS")" >&2
    fi
    return 1
  fi
  printf '%s\n' "$text"
}
