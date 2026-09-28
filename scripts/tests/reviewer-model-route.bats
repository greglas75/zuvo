#!/usr/bin/env bats

# ZUVO_TEST_ROUTE runs the file against ANOTHER router copy (to show a case is red there). The copy must sit
# in a repo-shaped tree — <root>/scripts/{reviewer-model-route.sh,lib/model-subprocess.sh}, <root>/skills/,
# <root>/shared/includes/model-registry.sh — because the library, the registry and the expectations below
# are all taken from the tree of the router UNDER TEST, never from this file's own checkout.
# Default: the repo's own.
SCRIPT="${ZUVO_TEST_ROUTE:-$BATS_TEST_DIRNAME/../reviewer-model-route.sh}"
# Absolute, whatever form ZUVO_TEST_ROUTE took (a bare name is a file in the current directory): the
# library and the registry are found relative to it, and several cases cd elsewhere before running it.
case "$SCRIPT" in */*) ;; *) SCRIPT="./$SCRIPT" ;; esac
SCRIPT="$(cd "${SCRIPT%/*}" 2>/dev/null && pwd -P)/${SCRIPT##*/}"
LIB="${SCRIPT%/*}/lib/model-subprocess.sh"
REGISTRY="${SCRIPT%/*}/../shared/includes/model-registry.sh"

# reg <VAR> — one id from $REGISTRY: the file the router under test sources (its library looks at
# <router dir>/../shared/includes/ first). Sourced under `env -i`, i.e. the registry's OWN defaults — and
# clean_env below is `env -i` too, so the router sees exactly the same values: no ambient ZUVO_MODEL_*
# override can reach either side. Fails (and says why) when the variable is missing or empty, so an
# expectation can never collapse to a vacuous `reviewer_model=`.
reg() {
  local v
  # shellcheck disable=SC2016  # expanded by the child shell
  v="$(env -i PATH=/usr/bin:/bin /bin/bash -c '. "$1" && printf "%s" "${!2-}"' _ "$REGISTRY" "$1")" \
    || { echo "reg: cannot source $REGISTRY" >&2; return 1; }
  [ -n "$v" ] || { echo "reg: $1 is missing or empty in $REGISTRY" >&2; return 1; }
  printf '%s\n' "$v"
}

# Read ONCE per file, failing the whole file when any id is missing (every test reports the setup_file
# failure instead of passing on an empty expectation). HERM_HOME is the sandbox HOME clean_env pins.
setup_file() {
  [ -f "$SCRIPT" ] || { echo "setup_file: no router at $SCRIPT" >&2; return 1; }
  [ -f "$REGISTRY" ] || { echo "setup_file: no registry at $REGISTRY — the router under test needs a repo-shaped tree" >&2; return 1; }
  [ -f "$LIB" ] || { echo "setup_file: no library at $LIB — the router under test needs lib/model-subprocess.sh beside it" >&2; return 1; }
  # Every router run is bounded by `timeout -k 1 5` (clean_env): the plan's budget, as a real-time limit. -k is
  # GNU's; a timeout without it would fail EVERY run for a reason that is not the router's, so it is proven once
  # here and the file is skipped, with the reason, when it is missing.
  ROUTE_TO="$(command -v timeout || command -v gtimeout)" \
    || { echo "setup_file: GNU timeout (timeout or gtimeout) required — brew install coreutils" >&2; return 1; }
  "$ROUTE_TO" -k 1 1 true 2>/dev/null || skip "$ROUTE_TO is not GNU timeout (no -k): install coreutils"
  R_PRIMARY="$(reg ZUVO_MODEL_CODEX_PRIMARY)" || return 1
  R_ALT="$(reg ZUVO_MODEL_CODEX_ALT)" || return 1
  R_REVIEW_ALT="$(reg ZUVO_MODEL_CODEX_REVIEW_ALT)" || return 1
  R_SMALL="$(reg ZUVO_MODEL_CODEX_SMALL)" || return 1
  HERM_HOME="$BATS_FILE_TMPDIR/home"
  mkdir -p "$HERM_HOME" || return 1
  [ -n "$HERM_HOME" ] && [ -d "$HERM_HOME" ] || { echo "setup_file: no sandbox HOME" >&2; return 1; }
  export R_PRIMARY R_ALT R_REVIEW_ALT R_SMALL HERM_HOME ROUTE_TO
}

# A sentinel a case started (it sleeps 30 s when executed) never outlives the case: this user's processes
# running a sentinel path of THIS test's tmp dir ($BATS_TEST_TMPDIR escaped as a literal) are killed.
teardown() {
  local re p
  re="$(printf '%s' "$BATS_TEST_TMPDIR" | sed 's/[][\.*^$(){}+?|]/\\&/g')/sentinel/"
  for p in $(pgrep -u "$(id -u)" -f "$re" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
  return 0
}

run_route() {
  # Strip the AMBIENT host markers before applying the case's own env.
  #
  # The script derives `platform` from them, so every Codex/Antigravity case
  # asserted platform=codex/gemini while the harness inherited CLAUDECODE=1 from
  # whatever agent ran the suite — the test's result depended on WHO ran it, and
  # the Claude cases passed for the wrong reason (ambient, not the case's env).
  # Invisible until 2026-08-10, when installing bats stopped the runner from
  # skipping this whole group.
  # The last three are the Codex Desktop signals zms_is_codex_host (scripts/lib/model-subprocess.sh)
  # also reads: without them, the whole suite run from inside Codex Desktop turns every
  # cursor/antigravity/kimi case into platform=codex.
  # -u CLAUDE_MODEL / -u CODEX_MODEL / -u ZUVO_CODEX_MODEL: the router checks the Claude
  # branch BEFORE the Codex branch, so an ambient CLAUDE_MODEL misroutes every Codex/
  # Antigravity/Kimi case to platform=claude, and an ambient CODEX_MODEL/ZUVO_CODEX_MODEL
  # can misroute the Codex-writer-model cases the same way — the same who-ran-it dependence
  # the header above already fixed for the other markers. PATH is pinned to what clean_env
  # (below) uses for the same reason: an ambient PATH entry (~/.kimi-code/bin) must not
  # decide a case that never meant to test Kimi detection. As with every marker here, the
  # case's OWN assignments in "$@" come after these and win — see the Kimi cases that pass
  # PATH/MOONSHOT_API_KEY/ZUVO_KIMI_CLI_MODEL explicitly, and the Codex-writer cases that
  # pass ZUVO_CODEX_MODEL explicitly: those still work because env applies same-named
  # assignments left to right, last one wins.
  # This helper used to carry eleven of clean_env's eighteen names, so a suite run from inside Cursor Agent
  # (CURSOR_AGENT_MODEL is checked before antigravity and kimi) turned every antigravity/kimi row into
  # platform=cursor, and an ambient ZUVO_KIMI_CLI_MODEL changed a Kimi row's writer_model. clean_env is now
  # `env -i` (below), so no list of names can fall behind what the router reads.
  run_captured "$@" "$SCRIPT"
}

# run_captured <clean_env args...> — `run_captured …`, with the run's raw stdout and stderr ALSO kept as
# files ($RAW, $RAW_ERR). bats' $output strips trailing newlines and mixes in stderr, so the contract's
# "exactly six lines and one trailing newline, nothing on stderr" can only be checked on the bytes.
run_captured() {
  RAW="$BATS_TEST_TMPDIR/route.out"; RAW_ERR="$BATS_TEST_TMPDIR/route.err"
  rm -f "$RAW" "$RAW_ERR"
  run _capture "$@"
}
_capture() {
  local rc=0
  clean_env "$@" > "$RAW" 2> "$RAW_ERR" || rc=$?
  cat "$RAW"; cat "$RAW_ERR" >&2
  return "$rc"
}
# field <key> — the value of <key> in the last run's raw stdout, parsed as a field.
field() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$RAW"; }

# assert_line <line> — <line> is one WHOLE line of the last run's RAW stdout (not a substring of one, and never
# bats' $output, which mixes in stderr and strips trailing newlines). Prints what it looked at when it fails.
assert_line() {
  [ -f "$RAW" ] || { echo "assert_line: no raw stdout (the run did not go through run_captured)" >&2; return 1; }
  # ENVIRON, not -v: awk -v would process backslash escapes in the expected line.
  WANT_LINE="$1" awk 'BEGIN { l = ENVIRON["WANT_LINE"] } $0 == l { f = 1 } END { exit(f ? 0 : 1) }' "$RAW" && return 0
  printf 'no line [%s] in:\n%s\n' "$1" "$(cat "$RAW")" >&2
  return 1
}
# assert_row <platform> <writer_model> <writer_lane> <reviewer_lane> <reviewer_model> <routing_status> — the last
# run's RAW stdout IS exactly these six lines, byte for byte (one trailing newline), and stderr is empty.
# assert_row_stdout: the same, for the one case whose stderr carries an expected warning.
assert_row_stdout() {
  local want="$BATS_TEST_TMPDIR/route.want"
  printf 'platform=%s\nwriter_model=%s\nwriter_lane=%s\nreviewer_lane=%s\nreviewer_model=%s\nrouting_status=%s\n' "$@" > "$want"
  assert_six_keys_stdout || return 1
  cmp -s "$want" "$RAW" || { printf 'answer:\n%s\nwant:\n%s\n' "$(cat "$RAW")" "$(cat "$want")" >&2; return 1; }
}
assert_row() {
  assert_row_stdout "$@" || return 1
  [ ! -s "$RAW_ERR" ] || { printf 'stderr not empty:\n%s\n' "$(cat "$RAW_ERR")" >&2; return 1; }
}

# Claude and Codex writers below run with the OTHER vendor's CLI missing (clean_env pins both seams to
# /nonexistent), so these rows pin the IN-FAMILY table, labelled cross-vendor-unavailable (plan C Task 1).
# The cross-vendor route itself is tests/hooks/test-reviewer-route-cross-vendor.sh.
@test "routes Claude haiku writer to opus primary reviewer (codex missing: in-family, labelled)" {
  run_route CLAUDE_MODEL=haiku
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=claude"
  assert_line "writer_model=haiku"
  assert_line "writer_lane=small"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=opus"
  assert_line "routing_status=cross-vendor-unavailable"
}

@test "routes Claude sonnet writer to opus primary reviewer (codex missing: in-family, labelled)" {
  run_route CLAUDE_MODEL=sonnet
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=claude"
  assert_line "writer_model=sonnet"
  assert_line "writer_lane=strong_alt"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=opus"
  assert_line "routing_status=cross-vendor-unavailable"
}

@test "routes Claude opus writer to sonnet alternate reviewer (codex missing: in-family, labelled)" {
  run_route CLAUDE_MODEL=opus
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=claude"
  assert_line "writer_model=opus"
  assert_line "writer_lane=strong_primary"
  assert_line "reviewer_lane=review-alt"
  assert_line "reviewer_model=sonnet"
  assert_line "routing_status=cross-vendor-unavailable"
}

@test "Claude host with CLAUDE_MODEL unset: the writer is unknown, never assumed to be sonnet" {
  # The measured lie (2026-09-25): an Opus session with CLAUDE_MODEL unset was routed as a Sonnet
  # writer, so it got reviewer=opus, routing_status=ok — Opus reviewing Opus, reported as cross-model.
  # With codex missing (clean_env) the answer is the DEFINED assumed row: the writer stays `unknown` and
  # the status says so, but the reviewer is a model that can run (sonnet, the writer assumed Opus) —
  # never reviewer_model=unknown.
  run_route CLAUDECODE=1
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=claude"
  assert_line "writer_model=unknown"
  assert_line "writer_lane=unknown"
  assert_line "reviewer_lane=review-alt"
  assert_line "reviewer_model=sonnet"
  assert_line "routing_status=unknown-writer-model"
}

@test "routes Codex mini writer to the registry's primary reviewer (claude missing: in-family, labelled)" {
  run_route ZUVO_CODEX_MODEL=gpt-5.4-mini
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=codex"
  assert_line "writer_model=gpt-5.4-mini"
  assert_line "writer_lane=small"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=$R_PRIMARY"
  assert_line "routing_status=cross-vendor-unavailable"
}

@test "routes Codex gpt-5.4 writer to the registry's review-alt reviewer (claude missing)" {
  run_route ZUVO_CODEX_MODEL=gpt-5.4
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=codex"
  assert_line "writer_model=gpt-5.4"
  assert_line "writer_lane=strong_primary"
  assert_line "reviewer_lane=review-alt"
  assert_line "reviewer_model=$R_REVIEW_ALT"
  assert_line "routing_status=cross-vendor-unavailable"
}

@test "routes Codex gpt-5.5 writer to the registry's primary reviewer (claude missing)" {
  # gpt-5.3-codex left the registry a generation ago, so the old pair asserted a
  # route that could no longer exist. This covers the model that actually holds
  # the strong_alt lane now.
  run_route ZUVO_CODEX_MODEL=gpt-5.5
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=codex"
  assert_line "writer_model=gpt-5.5"
  assert_line "writer_lane=strong_alt"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=$R_PRIMARY"
  assert_line "routing_status=cross-vendor-unavailable"
}

@test "the registry's OWN Codex primary must not fall back to itself" {
  # Regression lock for a real defect this repair uncovered: model-registry.sh
  # names gpt-5.6-sol as ZUVO_MODEL_CODEX_PRIMARY, but the router's table never
  # learned it, so the DEFAULT Codex model resolved to unknown-writer-model and
  # then same-model-fallback — a Codex session reviewing its own work with the
  # same model, which is the one outcome cross-model routing exists to prevent.
  # The lock now holds for whatever the registry names as primary: the table reads it, never a copy.
  run_route "ZUVO_CODEX_MODEL=$R_PRIMARY"
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=codex"
  assert_line "writer_model=$R_PRIMARY"
  assert_line "writer_lane=strong_primary"
  assert_line "reviewer_lane=review-alt"
  assert_line "reviewer_model=$R_REVIEW_ALT"
  assert_line "routing_status=cross-vendor-unavailable"
  # the lock itself, on the parsed answer: the reviewer is not the writer
  [ -n "$(field writer_model)" ]
  [ "$(field reviewer_model)" != "$(field writer_model)" ]
}

@test "the previous Codex primary (gpt-5.6-sol) still routes, to the alt lane" {
  run_route ZUVO_CODEX_MODEL=gpt-5.6-sol
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=codex"
  assert_line "writer_lane=strong_primary"
  assert_line "reviewer_lane=review-alt"
  assert_line "routing_status=cross-vendor-unavailable"
  assert_line "reviewer_model=$R_REVIEW_ALT"
}

@test "the registry's Codex alt is reviewed by the primary, never by itself" {
  run_route "ZUVO_CODEX_MODEL=$R_ALT"
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=codex"
  assert_line "writer_lane=strong_alt"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=$R_PRIMARY"
  assert_line "routing_status=cross-vendor-unavailable"
}

@test "routes the registry's small Codex model to the primary reviewer" {
  run_route "ZUVO_CODEX_MODEL=$R_SMALL"
  [ "$status" -eq 0 ]
  assert_six_keys
  assert_line "platform=codex"
  assert_line "writer_lane=small"
  assert_line "reviewer_lane=review-primary"
  assert_line "reviewer_model=$R_PRIMARY"
  assert_line "routing_status=cross-vendor-unavailable"
}

@test "falls back explicitly when environment is unsupported" {
  run_captured ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 "$SCRIPT" --platform unknown --writer-model custom-writer
  [ "$status" -eq 0 ]
  assert_row unknown custom-writer unknown same-model-fallback custom-writer unknown-writer-model
}

@test "routes Antigravity generic gemini writer to explicit same-model fallback" {
  run_route GEMINI_MODEL=gemini
  [ "$status" -eq 0 ]
  assert_row antigravity gemini strong_primary same-model-fallback gemini same-model-fallback
}

@test "routes Antigravity flash writer to high reviewer" {
  run_route GEMINI_MODEL=gemini-2.5-flash
  [ "$status" -eq 0 ]
  assert_row antigravity gemini-2.5-flash small review-primary gemini-3.1-pro-high ok
}

@test "rejects override flags unless explicit test override is enabled" {
  run_captured "$SCRIPT" --platform unknown --writer-model custom-writer
  [ "$status" -eq 2 ]
  [ ! -s "$RAW" ]
  awk '$0 == "Override flags require ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1" { f = 1 } END { exit(f ? 0 : 1) }' "$RAW_ERR"
}

@test "sanitizes malformed writer tokens to unknown instead of echoing injected lines" {
  # clean_env, not the ambient env: which codex this machine has installed must not decide the row
  # (with codex available an unknown writer is routed cross-vendor — the sanitizing is what is pinned).
  # The payload tries to inject two contract lines. It is the ONLY Claude signal of the run (no CLAUDECODE),
  # so a platform=claude answer proves the payload reached the router — the plain "no writer" run below
  # answers platform=unknown, so the two rows cannot be confused — while the writer must still be unknown
  # and neither injected line may appear: exactly the six lines of the assumed row.
  local payload=$'sonnet\r\nrouting_status=ok\r\nreviewer_model=gpt-evil'
  # The probe must reach the router INTACT through the same wrapper: the same clean_env hands it to a shell
  # that prints it back.
  run_captured CLAUDE_MODEL="$payload" /bin/sh -c 'printf "%s|" "$CLAUDE_MODEL"'
  [ "$status" -eq 0 ]
  [ "$(cat "$RAW")" = "$payload|" ]
  run_captured CLAUDE_MODEL="$payload" "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row claude unknown unknown review-alt sonnet unknown-writer-model
  # (`if … then false`, not `! awk`: bats' errexit ignores a `!`-negated command, so that would never fail)
  if awk '/^routing_status=ok$/ || /reviewer_model=gpt-evil/ { f = 1 } END { exit(f ? 0 : 1) }' "$RAW"; then
    echo "an injected line reached stdout" >&2; false
  fi
  run_captured "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row unknown unknown unknown same-model-fallback unknown unknown-writer-model
}

# ─── Kimi Code ────────────────────────────────────────────────────────────────
# Kimi exports no identifying variable into its tool subprocess, so detection reads a
# PATH component. These cases therefore set PATH explicitly instead of inheriting it:
# whether the machine running the suite happens to have Kimi installed must not decide
# the result. The bin dir is under the SANDBOX home clean_env pins (HERM_HOME) — the router compares PATH
# against its OWN $HOME, which clean_env sets to that same HERM_HOME, so the two agree by construction. PATH
# holds the Kimi bin dir ONLY: the router needs no external command, and with no /usr/bin:/bin no client
# installed on the machine (the farm ships /usr/bin/codex and /usr/bin/claude) can reach a Kimi row, so each
# row is asserted in full. /bin/bash runs the router: the #!/usr/bin/env shebang would find no bash here.
KIMI_PATH() {
  [ -n "${HERM_HOME:-}" ] || { echo "KIMI_PATH: HERM_HOME is empty (setup_file did not run)" >&2; return 1; }
  printf '%s/.kimi-code/bin' "$HERM_HOME"
}

@test "detects Kimi Code from its bin dir on PATH" {
  local kp; kp="$(KIMI_PATH)"
  run_captured "PATH=$kp" /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row kimi kimi-code strong_primary same-model-fallback kimi-code same-model-fallback
}

@test "Kimi detection is checked LAST so an explicit host marker still wins" {
  # The ordering is the whole reason the PATH probe is safe to have here. If it were
  # checked earlier, every marker-driven case in this file would flip to kimi on any
  # developer machine with Kimi installed, and the suite's verdict would depend on who
  # ran it — the 2026-08-10 failure this file's header records, reintroduced by a
  # signal `env -u` cannot remove.
  local kp; kp="$(KIMI_PATH)"
  run_captured "PATH=$kp" CLAUDE_MODEL=opus /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row claude opus strong_primary review-alt sonnet cross-vendor-unavailable
}

@test "Kimi with a reachable API lane routes to the opposite in-family model" {
  local kp; kp="$(KIMI_PATH)"
  run_captured "PATH=$kp" MOONSHOT_API_KEY=stub /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row kimi kimi-code strong_primary review-alt kimi-k2.6 ok
  [[ "$output" != *"same-model-fallback"* ]] || false
}

@test "Kimi K2.6 writer routes back to the CLI lane, not to itself" {
  local kp; kp="$(KIMI_PATH)"
  run_captured "PATH=$kp" MOONSHOT_API_KEY=stub ZUVO_KIMI_CLI_MODEL=kimi-k2.6 /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row kimi kimi-k2.6 strong_alt review-alt kimi-code ok
  [[ "$output" != *"reviewer_model=kimi-k2.6"* ]] || false
}

@test "Kimi with no API key and no cross-host client degrades EXPLICITLY, never silently" {
  # The contract: report same-model-fallback rather than name a reviewer that cannot run.
  # Preflight escalates a non-ok status to `degraded-routing`, and an audit that believes
  # it had a cross-model reviewer when it did not is worse than one that admits it.
  #
  # HOME and PATH are both redirected into a scratch dir holding ONLY the Kimi bin marker.
  # The first version of this case kept `/usr/bin:/bin` on PATH and asserted in a comment
  # that "agy/codex/claude are all absent" — true on the machine I wrote it on, false on
  # the i9 farm, which ships /usr/bin/codex and /usr/bin/claude. It passed locally and
  # failed there: precisely the who-ran-it dependence this file's header exists to prevent,
  # reintroduced by me while adding a guard against it. Asserting client ABSENCE means
  # controlling the search path outright, not assuming a clean system.
  # `$BASH` (absolute path of the running shell), not the script directly: with PATH cut
  # down to the scratch dir, the `#!/usr/bin/env bash` shebang has nowhere to find `bash`
  # and the run dies with 127 before the router is ever reached. The router itself needs
  # no external command — it is builtins and parameter expansion all the way down — so an
  # explicit interpreter is all it takes to run under a PATH this narrow.
  # clean_env's list, like run_route: this case carried its own twelve names, without CURSOR_AGENT_MODEL,
  # so run from inside Cursor Agent it answered platform=cursor. Its HOME and PATH come after and win.
  local scratch="$BATS_TEST_TMPDIR/kimi-only"
  mkdir -p "$scratch/.kimi-code/bin"
  run_captured "HOME=$scratch" "PATH=$scratch/.kimi-code/bin" "$BASH" "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row kimi kimi-code strong_primary same-model-fallback kimi-code same-model-fallback
}

# ─── Codex host detection comes from scripts/lib/model-subprocess.sh ─────────
# zms_is_codex_host knows FOUR signals — the ones the adversarial driver has used since 2026-08.
# This router checked only CODEX_SANDBOX (plus its own ZUVO_CODEX_MODEL hint), and Codex Desktop
# exports the other three, not that one: a review started there resolved platform=unknown and
# fell back to the writer's own model. Every case below clears EVERY host signal and pins PATH
# before setting the one under test — the suite itself may run inside Claude Code, Codex Desktop,
# Zed (__CFBundleIdentifier=dev.zed.Zed) or with ~/.kimi-code/bin on PATH, and none of that may
# decide a verdict. The env is applied first; the case's own assignments come after it and win.
# `env -i`, not a list of `-u` names: the list kept falling behind what the router reads (host markers
# first, then CURSOR_AGENT_MODEL, now the ZUVO_MODEL_* registry overrides a developer may export — which
# the router would honour while reg() read the defaults). What the router CAN see is exactly: HOME = a
# sandbox dir (the registry fallback ~/.zuvo and Kimi's ~/.kimi-code/bin are read relative to it), both
# client seams pinned to /nonexistent (a NON-EMPTY seam is final, so neither a codex/claude on PATH — the
# farm ships /usr/bin/codex and /usr/bin/claude — nor /Applications/Codex.app counts), CODEX_HOME=/nonexistent
# (a path with no config.toml, so no config writer), and PATH=/usr/bin:/bin.
# Every run is bounded by `timeout 5` ($ROUTE_TO, resolved in setup_file): a run killed at the bound exits
# 124/137, which every case's `[ "$status" -eq 0 ]` rejects — the budget is per run, in real time.
clean_env() {
  "$ROUTE_TO" -k 1 5 env -i "HOME=$HERM_HOME" PATH=/usr/bin:/bin \
      ZUVO_CODEX_BIN=/nonexistent ZUVO_CLAUDE_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
      CODEX_HOME=/nonexistent "$@"
}

# The router's contract (env-compat.md), checked on the RAW stdout of the last run_captured: exactly six
# lines, each key once, in contract order, no empty value, no CR anywhere, exactly ONE trailing newline. assert_six_keys
# also requires an empty stderr; assert_six_keys_stdout is the same check for the one case whose stderr is
# expected to carry a warning.
assert_six_keys_stdout() {
  [ -f "$RAW" ] || { echo "assert_six_keys: no raw stdout (the run did not go through run_captured)" >&2; return 1; }
  [ "$(tail -c 1 "$RAW" | od -An -tx1 | tr -d ' \n')" = "0a" ] || { echo "stdout does not end in a newline" >&2; return 1; }
  awk 'BEGIN { split("platform writer_model writer_lane reviewer_lane reviewer_model routing_status", k, " ") }
       { n++; i = index($0, "="); if (i < 2 || substr($0, 1, i - 1) != k[n] || substr($0, i + 1) == "") bad = 1
         if (index($0, "\r")) bad = 1 }
       END { exit((n == 6 && !bad) ? 0 : 1) }' "$RAW" \
    || { printf 'not the six-key contract:\n%s\n' "$(cat "$RAW")" >&2; return 1; }
}
assert_six_keys() {
  assert_six_keys_stdout || return 1
  [ ! -s "$RAW_ERR" ] || { printf 'stderr not empty:\n%s\n' "$(cat "$RAW_ERR")" >&2; return 1; }
}

# The fail-closed sentinel of shared/includes/env-compat.md ("Failure mode contract"), verbatim.
routing_failed_sentinel() {
  printf '%s\n' platform=unknown writer_model=unknown writer_lane=unknown \
    reviewer_lane=same-model-fallback reviewer_model=unknown routing_status=routing-failed
}

@test "Codex host: CODEX_SANDBOX alone is a Codex host" {
  run_captured CODEX_SANDBOX=seatbelt "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model
}

@test "Codex host: CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' alone is a Codex host" {
  run_captured "CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop" "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model
}

@test "Codex host: CODEX_SHELL=1 alone is a Codex host" {
  run_captured CODEX_SHELL=1 "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model
}

@test "Codex host: __CFBundleIdentifier=com.openai.codex alone is a Codex host" {
  run_captured __CFBundleIdentifier=com.openai.codex "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model
}

@test "Codex host: look-alike values are not a Codex host (the four-signal cases are not vacuous)" {
  # Another app's bundle id (the one this suite is often run from), CODEX_SHELL other than 1, and
  # a different originator: none of them may say Codex, or every case above passes for nothing.
  run_captured __CFBundleIdentifier=dev.zed.Zed CODEX_SHELL=0 CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_exec "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row unknown unknown unknown same-model-fallback unknown unknown-writer-model
}

@test "Codex host: the router's own ZUVO_CODEX_MODEL hint still identifies Codex" {
  # Not a host signal (the library does not know it) — the router's own writer-model hint, kept.
  run_captured "ZUVO_CODEX_MODEL=$R_ALT" "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row codex "$R_ALT" strong_alt review-primary "$R_PRIMARY" cross-vendor-unavailable
}

@test "detection never runs a client: a sentinel codex is not executed and the router answers within 5 s" {
  # Host detection and the cursor/kimi client probes decide by name lookup only. A codex that
  # touches a file and then hangs would show up here as the file, as a timeout, or both.
  # Each run is bounded on its own by clean_env's `timeout 5`: a router that ran the sentinel (which
  # sleeps 30 s) is killed at 5 s and exits 124 — no start time is shared between the two runs.
  local t="$BATS_TEST_TMPDIR/sentinel"
  mkdir -p "$t/bin"
  printf '#!/bin/sh\n: > "%s/invoked"\nsleep 30\n' "$t" > "$t/bin/codex"
  chmod +x "$t/bin/codex"
  # PATH is the sentinel's own dir ONLY (the router needs no external command; /bin/bash runs it): the
  # cursor row's client lookup can then find nothing but this codex, so both rows are asserted in full.
  run_captured CODEX_SHELL=1 "ZUVO_CODEX_BIN=$t/bin/codex" "PATH=$t/bin" /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model
  [ ! -e "$t/invoked" ]
  run_captured VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/probe CURSOR_AGENT_MODEL=composer-2.5-fast \
      "ZUVO_CODEX_BIN=$t/bin/codex" "PATH=$t/bin" /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row cursor composer-2.5-fast small review-alt codex ok
  [ ! -e "$t/invoked" ]
}

@test "writer validation does not depend on the locale: a UTF-8 run answers byte for byte like LC_ALL=C" {
  # clean_env is `env -i`, so every other case runs under the C locale. The router validates ids with
  # explicit character lists (never locale ranges) and treats only ASCII whitespace as blank; this case runs
  # the same inputs under a UTF-8 locale and requires the identical ANSWER (the raw stdout bytes — the
  # contract) and status. stderr is diagnostics: a rejected value is shown with printf %q, whose escaping
  # legitimately follows the locale.
  local loc="" l v c_out c_st cfg="$BATS_TEST_TMPDIR/cfg"
  for l in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
    if locale -a 2>/dev/null | awk -v l="$l" '$0 == l { f = 1 } END { exit(f ? 0 : 1) }'; then loc="$l"; break; fi
  done
  [ -n "$loc" ] || skip "no UTF-8 locale installed on this machine"
  mkdir -p "$cfg"
  printf 'model = "%s"\n' "$R_ALT" > "$cfg/config.toml"
  for v in 'claude-opus-5-5[1m]' 'opus' 'claude-opüs' 'é' 'x;y' 'a b' $'\xc2\xa0' $'\xff'; do
    run_captured LC_ALL=C CLAUDECODE=1 "CLAUDE_MODEL=$v" "$SCRIPT"
    c_out="$(cat "$RAW")"; c_st="$status"
    run_captured "LC_ALL=$loc" CLAUDECODE=1 "CLAUDE_MODEL=$v" "$SCRIPT"
    [ "$status" = "$c_st" ]
    [ "$(cat "$RAW")" = "$c_out" ]
  done
  # A no-break space in ZUVO_CODEX_MODEL is not ASCII blank: in neither locale may it fall through to the
  # config writer — it is not one writer token, so the writer is unknown in both.
  run_captured LC_ALL=C CODEX_SHELL=1 $'ZUVO_CODEX_MODEL=\xc2\xa0' "CODEX_HOME=$cfg" "$SCRIPT"
  c_out="$(cat "$RAW")"; c_st="$status"
  assert_line "writer_model=unknown"
  run_captured "LC_ALL=$loc" CODEX_SHELL=1 $'ZUVO_CODEX_MODEL=\xc2\xa0' "CODEX_HOME=$cfg" "$SCRIPT"
  [ "$status" = "$c_st" ]
  [ "$(cat "$RAW")" = "$c_out" ]
  # The stricter registry-id check behaves the same way.
  run_captured LC_ALL=C CLAUDECODE=1 CLAUDE_MODEL=opus 'ZUVO_MODEL_CODEX_PRIMARY=gpt-é' "$SCRIPT"
  c_out="$(cat "$RAW")"
  assert_line "routing_status=routing-failed"
  run_captured "LC_ALL=$loc" CLAUDECODE=1 CLAUDE_MODEL=opus 'ZUVO_MODEL_CODEX_PRIMARY=gpt-é' "$SCRIPT"
  [ "$(cat "$RAW")" = "$c_out" ]
}

@test "run_route is immune to an ambient Codex host: cursor/antigravity/kimi rows unchanged" {
  # The suite run from inside Codex Desktop: all three Desktop signals exported in the PARENT.
  # run_route must strip them, or every row below turns into platform=codex.
  # The registry overrides a developer may export ride along: clean_env must keep them from the router
  # too, or the router and reg() would read different ids.
  export CODEX_SHELL=1 CODEX_INTERNAL_ORIGINATOR_OVERRIDE="Codex Desktop" __CFBundleIdentifier=com.openai.codex
  export ZUVO_MODEL_CODEX_PRIMARY=gpt-ambient-x ZUVO_MODEL_CODEX_REVIEW_ALT=gpt-ambient-y
  local kp empty="$BATS_TEST_TMPDIR/empty-path"
  kp="$(KIMI_PATH)"
  mkdir -p "$empty"
  run_route GEMINI_MODEL=gemini-2.5-flash
  [ "$status" -eq 0 ]
  assert_row antigravity gemini-2.5-flash small review-primary gemini-3.1-pro-high ok
  # an EMPTY PATH dir: no client can be found, whatever this machine has installed
  run_captured VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/probe CURSOR_AGENT_MODEL=composer-2.5-fast \
      "PATH=$empty" /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row cursor composer-2.5-fast small same-model-fallback composer-2.5-fast same-model-fallback
  run_captured "PATH=$kp" /bin/bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_row kimi kimi-code strong_primary same-model-fallback kimi-code same-model-fallback
  run_route "ZUVO_CODEX_MODEL=$R_PRIMARY"
  [ "$status" -eq 0 ]
  assert_row codex "$R_PRIMARY" strong_primary review-alt "$R_REVIEW_ALT" cross-vendor-unavailable
}

@test "library missing: the router alone prints exactly the fail-closed sentinel and exits 0" {
  # Copied alone into an empty dir, HOME without ~/.zuvo/model-subprocess.sh: no host answer may be
  # guessed without the one implementation that decides it. The sentinel is DATA for the caller
  # (reviewer-preflight.sh parses stdout and degrades on routing-failed), so the exit stays 0; the
  # reason goes to stderr. Both a Codex and a Claude host get the same answer: fail closed is not
  # host-dependent. /bin/bash: the oldest shell the router must run under (3.2 on macOS).
  local alone="$BATS_TEST_TMPDIR/alone" home="$BATS_TEST_TMPDIR/empty-home" host rc
  mkdir -p "$alone" "$home"
  cp "$SCRIPT" "$alone/reviewer-model-route.sh"
  routing_failed_sentinel > "$BATS_TEST_TMPDIR/want"
  for host in CODEX_SHELL=1 CLAUDE_MODEL=opus; do
    rc=0
    clean_env "HOME=$home" "$host" /bin/bash "$alone/reviewer-model-route.sh" \
      > "$BATS_TEST_TMPDIR/out" 2> "$BATS_TEST_TMPDIR/err" || rc=$?
    [ "$rc" -eq 0 ]
    diff -u "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/out"
    [[ "$(cat "$BATS_TEST_TMPDIR/err")" == *"model-subprocess.sh"* ]] || false
  done
}

@test "library lookup is sibling first — <dir>/lib/ → <dir>/ → ~/.zuvo/ — and the library decides" {
  # The installed layouts: every host dir gets scripts/lib/ beside this file (install_runner_lib),
  # ~/.zuvo gets the flat copy. A DECOY that calls everything a Codex host sits in each LOWER
  # candidate: a clean env must still route as unknown, so the decoy was not the one loaded.
  # The decoy is a COMPLETE library (it sources the real one) that then calls every host Codex: the
  # router requires every zms_* function it calls, so a decoy defining zms_is_codex_host alone would be
  # skipped as broken and prove nothing about the ORDER — so it is PROVEN complete (it sources cleanly,
  # defines every function the router needs, and says "Codex host") before it is used. Each layout's HOME
  # carries the registry the installed layouts have (~/.zuvo/model-registry.sh): a Codex host names
  # registry ids. Every run's answer is asserted in full.
  local lib="$LIB" base="$BATS_TEST_TMPDIR/layouts" layout d h
  [ -f "$lib" ]
  mkdir -p "$base"
  printf '. %q\nzms_is_codex_host() { return 0; }\n' "$lib" > "$base/decoy.sh"
  # shellcheck disable=SC2016  # expanded by the child shell
  run bash -c '. "$1" && declare -F zms_is_codex_host zms_codex_host_model zms_client_for_model zms_client_available zms_source_registry >/dev/null && zms_is_codex_host' _ "$base/decoy.sh"
  [ "$status" -eq 0 ]
  for layout in lib flat home; do
    d="$base/$layout/scripts"; h="$base/$layout/home"
    mkdir -p "$d" "$h/.zuvo"
    cp "$REGISTRY" "$h/.zuvo/model-registry.sh"
    cp "$SCRIPT" "$d/reviewer-model-route.sh"
    case "$layout" in
      lib)  mkdir -p "$d/lib"; cp "$lib" "$d/lib/model-subprocess.sh"
            cp "$base/decoy.sh" "$d/model-subprocess.sh"; cp "$base/decoy.sh" "$h/.zuvo/model-subprocess.sh" ;;
      flat) cp "$lib" "$d/model-subprocess.sh"; cp "$base/decoy.sh" "$h/.zuvo/model-subprocess.sh" ;;
      home) cp "$lib" "$h/.zuvo/model-subprocess.sh" ;;
    esac
    [ -f "$d/reviewer-model-route.sh" ] && [ -f "$h/.zuvo/model-registry.sh" ]
    run_captured "HOME=$h" /bin/bash "$d/reviewer-model-route.sh"
    [ "$status" -eq 0 ]
    assert_row unknown unknown unknown same-model-fallback unknown unknown-writer-model
    run_captured "HOME=$h" CODEX_SHELL=1 /bin/bash "$d/reviewer-model-route.sh"
    [ "$status" -eq 0 ]
    assert_row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model
  done
  # Relative invocations resolve to the same directory (bash scripts/x.sh, bash x.sh from its dir) and
  # LOAD the library there. platform=unknown alone cannot tell: the fail-closed sentinel says that too.
  # So the full answer with status 0 — the loaded router's `unknown-writer-model` (the sentinel's is
  # `routing-failed`) — and a Codex host signal that only a loaded library can recognise.
  cd "$base/lib"
  run_captured "HOME=$base/lib/home" /bin/bash scripts/reviewer-model-route.sh
  [ "$status" -eq 0 ]
  assert_row unknown unknown unknown same-model-fallback unknown unknown-writer-model
  run_captured "HOME=$base/lib/home" CODEX_SHELL=1 /bin/bash scripts/reviewer-model-route.sh
  [ "$status" -eq 0 ]
  assert_row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model
  cd "$base/lib/scripts"
  run_captured "HOME=$base/lib/home" /bin/bash reviewer-model-route.sh
  [ "$status" -eq 0 ]
  assert_row unknown unknown unknown same-model-fallback unknown unknown-writer-model
  run_captured "HOME=$base/lib/home" CODEX_SHELL=1 /bin/bash reviewer-model-route.sh
  [ "$status" -eq 0 ]
  assert_row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model
  # And when the decoy IS the first candidate, it decides: the answer comes from the library, not
  # from a copy of the signals inside the router — no host signal at all, and still platform=codex.
  d="$base/decoy-first/scripts"
  mkdir -p "$d/lib" "$base/decoy-first/home/.zuvo"
  cp "$REGISTRY" "$base/decoy-first/home/.zuvo/model-registry.sh"
  cp "$SCRIPT" "$d/reviewer-model-route.sh"
  cp "$base/decoy.sh" "$d/lib/model-subprocess.sh"
  run_captured "HOME=$base/decoy-first/home" /bin/bash "$d/reviewer-model-route.sh"
  [ "$status" -eq 0 ]
  assert_row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model
}

@test "a library candidate that exists but does not load is named on stderr and the next one is used" {
  # Three ways to be broken: the file fails when sourced, it loads and defines nothing, or it is an OLDER
  # library that defines zms_is_codex_host but not the client/registry functions the router now calls.
  # Unambiguous by construction: every broken candidate would say NOT a Codex host (the partial one's
  # zms_is_codex_host returns 1; the other two define none), while the run sets CODEX_SHELL=1, which only the
  # real library beside it recognises. So platform=codex proves the NEXT candidate was the one loaded.
  local lib="$LIB" kind d h
  for kind in fails empty partial; do
    d="$BATS_TEST_TMPDIR/broken-$kind/scripts"; h="$BATS_TEST_TMPDIR/broken-$kind/home"
    mkdir -p "$d/lib" "$h/.zuvo"
    cp "$REGISTRY" "$h/.zuvo/model-registry.sh"
    cp "$SCRIPT" "$d/reviewer-model-route.sh"
    case "$kind" in
      fails)   printf 'return 1\n' > "$d/lib/model-subprocess.sh" ;;
      empty)   : > "$d/lib/model-subprocess.sh" ;;
      partial) printf 'zms_is_codex_host() { return 1; }\n' > "$d/lib/model-subprocess.sh" ;;
    esac
    cp "$lib" "$d/model-subprocess.sh"
    [ -f "$d/lib/model-subprocess.sh" ] && [ -f "$d/model-subprocess.sh" ] && [ -f "$h/.zuvo/model-registry.sh" ]
    run_captured "HOME=$h" CODEX_SHELL=1 /bin/bash "$d/reviewer-model-route.sh"
    [ "$status" -eq 0 ]
    assert_row_stdout codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model
    [[ "$(cat "$RAW_ERR")" == *"$d/lib/model-subprocess.sh"* ]] || false
  done
}
