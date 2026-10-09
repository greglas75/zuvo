#!/usr/bin/env bash
# test-codex-lane-defaults.sh — the codex lanes' model, their effort dial, and the CLI guard.
#
# Three things here are only ever exercised on a host, which is why they get a test instead:
#
# 1. EFFORT IS PER-LANE. The two lanes deliberately run different dials (sol at `none`, luna at
#    `medium`) because the 2026-09-23 benchmark found the dial runs BACKWARDS for panel value:
#    sol at `medium` scored 100% precision and contributed zero defects the rest of the set
#    misses. A single global effort would collapse both lanes onto one setting and quietly undo
#    that result — the run would still succeed, which is what makes it worth pinning.
#
# 2. THE CLI GUARD IS A CHAIN. gpt-6 ids need codex CLI >=0.156; on an older CLI they fail as an
#    opaque 400 that reads like an ACCOUNT problem ("not supported when using Codex with a
#    ChatGPT account") — a diagnosis that was actually made, out loud, and was wrong. The guard
#    downgrades gpt-6 -> gpt-5.6-sol -> gpt-5.5, and a chain that stops one rung short is
#    invisible: it just picks a model that also fails.
#
# 3. An unparsable version must count as TOO OLD. Wrongly downgrading a new CLI costs one
#    generation; wrongly keeping a new id on an old CLI costs EVERY review.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1

CLTMP="$HERE/.tmp/codexlane.$$"; mkdir -p "$CLTMP/bin"
cleanup_cl() { rm -rf "$CLTMP"; }
trap cleanup_cl EXIT

# The guard shells out to `codex --version`. A fake one lets us test every rung without owning
# five CLI installs — and without the test depending on whichever version this host happens to
# have, which would make it pass or fail for reasons that are not the code.
# Every fake also writes the HOME / CODEX_HOME it was started with to $CLTMP/seen-env, so the test
# can show the guard never runs against the user's own ~/.zuvo or ~/.codex, and appends a line to
# $CLTMP/probes, so a case can count how often the CLI was asked (probes_since_reset).
fake_codex() { # fake_codex <version-string-or-empty>
  # shellcheck disable=SC2016  # expanded by the fake, not here
  printf '#!/bin/sh\nprintf "HOME=%%s CODEX_HOME=%%s\\n" "$HOME" "${CODEX_HOME:-}" > "%s/seen-env"\necho probe >> "%s/probes"\n' "$CLTMP" "$CLTMP" > "$CLTMP/bin/codex"
  if [ -z "$1" ]; then
    printf 'exit 1\n' >> "$CLTMP/bin/codex"
  else
    printf 'echo "codex-cli %s"\n' "$1" >> "$CLTMP/bin/codex"
  fi
  chmod +x "$CLTMP/bin/codex"
}

# The driver's codex_cli_guard is a one-line delegation to the shared runner's zms_codex_cli_guard
# (plan Task 4; the delegation itself is pinned by tests/hooks/test-adversarial-lane-golden.sh), so
# the ladder is exercised there, by sourcing the library — not by sed-extracting a driver function.
# codex is found the way a user's driver finds it: the fake on PATH, no ZUVO_CODEX_BIN, no app bundle.
# HOME and CODEX_HOME are a temp dir: nothing the library (or the fake) reads may come from the
# user's own ~/.zuvo or ~/.codex.
LIB="$ROOT/scripts/lib/model-subprocess.sh"
mkdir -p "$CLTMP/home/.codex"
# probes_since_reset — how many times the fake codex ran since the last `rm -f "$CLTMP/probes"`.
probes_since_reset() { if [ -f "$CLTMP/probes" ]; then wc -l < "$CLTMP/probes" | tr -d ' '; else echo 0; fi; }
guard() { # guard <model> -> what the guard resolves it to
  HOME="$CLTMP/home" CODEX_HOME="$CLTMP/home/.codex" PATH="$CLTMP/bin:$PATH" ZUVO_CODEX_APP_BIN=/nonexistent bash -c '
    unset ZUVO_CODEX_BIN; . "$1" || exit 9
    zms_codex_cli_guard "$2" TEST_OVERRIDE' _ "$LIB" "$1" 2>/dev/null
}

# ─── 1. a current CLI keeps the benchmarked ids ───────────────────────────
start_test "cx.1 codex CLI 0.156 runs the gpt-6 ids unchanged"
fake_codex "0.156.1"
# Removed right before the guarded call: a seen-env left by an earlier fake would otherwise satisfy
# the HOME/CODEX_HOME check below even if this call never ran codex.
rm -f "$CLTMP/seen-env"
assert_eq "gpt-6-sol"  "$(guard gpt-6-sol)"  "gpt-6-sol survives on a current CLI"
assert_eq "re-created" "$([ -f "$CLTMP/seen-env" ] && echo re-created || echo missing)" \
  "the guarded call ran the fake codex (seen-env re-created)"
assert_eq "HOME=$CLTMP/home CODEX_HOME=$CLTMP/home/.codex" "$(cat "$CLTMP/seen-env" 2>/dev/null)" \
  "the guard ran with a temp HOME and CODEX_HOME, never the user's ~/.zuvo or ~/.codex"
assert_eq "gpt-6-luna" "$(guard gpt-6-luna)" "gpt-6-luna survives on a current CLI"

# ─── 2. an older CLI downgrades ONE rung, not to the floor ────────────────
start_test "cx.2 CLI 0.150 downgrades gpt-6 to gpt-5.6-sol (which it can run)"
fake_codex "0.150.0"
assert_eq "gpt-5.6-sol" "$(guard gpt-6-sol)" "one rung down, not straight to the floor"
# The rung it lands on is one this CLI CAN run: gpt-5.6 needs >=0.144 (model-subprocess.sh, the gpt-5.6* arm
# of zms_codex_cli_guard), so 0.150 keeps it as configured.
assert_eq "gpt-5.6-sol" "$(guard gpt-5.6-sol)" "gpt-5.6-sol is KEPT on 0.150 (it needs >=0.144)"
# The luna id takes the same rung — the gpt-6* fallback is gpt-5.6-sol whichever gpt-6 it was — and stops
# there; the second rung is checked against the version already read ("asked at most once").
rm -f "$CLTMP/probes"
assert_eq "gpt-5.6-sol" "$(guard gpt-6-luna)" "gpt-6-luna on 0.150 -> gpt-5.6-sol, and no further"
assert_eq "1" "$(probes_since_reset)" "…the CLI was asked for its version once for both rungs"

# ─── 3. THE CHAIN: a CLI too old for BOTH must reach the floor ────────────
# This is the rung that a hand-written guard forgets. 0.140 cannot run gpt-6 (needs 156) and
# cannot run gpt-5.6 either (needs 144), so stopping at gpt-5.6-sol would pick a second model
# that also fails — and report success while doing it.
start_test "cx.3 CLI 0.140 falls all the way through to gpt-5.5"
fake_codex "0.140.0"
assert_eq "gpt-5.5" "$(guard gpt-6-sol)"   "gpt-6 -> gpt-5.6-sol -> gpt-5.5"
assert_eq "gpt-5.5" "$(guard gpt-5.6-sol)" "gpt-5.6 -> gpt-5.5 directly"

# ─── 4. an unparsable version counts as too old ───────────────────────────
start_test "cx.4 a CLI whose version cannot be read is treated as too old"
fake_codex ""
assert_eq "gpt-5.5" "$(guard gpt-6-sol)" "no version -> safest model, not the newest"

# ─── 5. a model outside the guarded families passes through untouched ─────
start_test "cx.5 an unguarded model id is returned as-is"
fake_codex "0.156.1"
rm -f "$CLTMP/probes"
assert_eq "gpt-5.5" "$(guard gpt-5.5)" "gpt-5.5 is not downgraded by its own fallback rule"
# zms_codex_cli_guard: "not at all for a model outside the guarded families" — the probe happens only inside
# the gpt-6*/gpt-5.6* arms, so an unguarded id never runs `codex --version`.
assert_eq "0" "$(probes_since_reset)" "…and codex --version was never run for it"

# ─── 6. the lanes carry the benchmarked defaults ──────────────────────────
start_test "cx.6 lane defaults match the 2026-09-23 benchmark"
REG="$ROOT/shared/includes/model-registry.sh"
assert_contains "$(cat "$REG")" 'ZUVO_MODEL_CODEX_PRIMARY:-gpt-6-sol'   "primary lane = gpt-6-sol"
assert_contains "$(cat "$REG")" 'ZUVO_MODEL_CODEX_ALT:-gpt-6-luna'      "alt lane = gpt-6-luna"
# The efforts by VALUE, from the registry sourced with no effort variable set (ZUVO_CODEX_EFFORT, when set,
# overrides both — hardening F43): the text pin broke on the first change that kept the defaults.
assert_eq "none medium" "$(env -u ZUVO_CODEX_EFFORT -u ZUVO_CODEX_EFFORT_PRIMARY -u ZUVO_CODEX_EFFORT_ALT \
  bash -c '. "$1" || exit 9; echo "$ZUVO_CODEX_EFFORT_PRIMARY $ZUVO_CODEX_EFFORT_ALT"' _ "$REG")" "primary effort = none, alt effort = medium"

# ─── spy fixtures for cx.7-cx.10 ───────────────────────────────────────────
# A spy codex that records the model_reasoning_effort its isolated CODEX_HOME was built with — the one place
# the dial reaches the client — or the sentinel `<no effort line>` when config.toml carries none. It then
# prints $SPY_STDERR (printf %b) on its stderr, answers a review and exits $SPY_EXIT (default 0).
mkdir -p "$CLTMP/spy" "$CLTMP/spyhome/.codex" "$CLTMP/tmp"
cp "$ROOT/tests/hooks/fixtures/model-subprocess/codex-home/auth.json" "$CLTMP/spyhome/.codex/auth.json"
cat > "$CLTMP/spy/codex" <<'EOF'
#!/bin/sh
[ "${1:-}" = --version ] && { echo "codex-cli 0.156.1"; exit 0; }
cat > /dev/null
e="$(sed -n 's/^model_reasoning_effort = "\(.*\)"$/\1/p' "${CODEX_HOME:-/nonexistent}/config.toml" 2>/dev/null)"
printf '%s\n' "${e:-<no effort line>}" > "$SPY_OUT"
[ -z "${SPY_STDERR:-}" ] || printf '%b' "$SPY_STDERR" >&2
printf 'SEVERITY: INFO\nFILE: x.ts:1\nISSUE: the spy reviewed this\nFIX: none\n'
exit "${SPY_EXIT:-0}"
EOF
chmod +x "$CLTMP/spy/codex"
printf 'diff --git a/x.ts b/x.ts\n@@ -1 +1 @@\n-const a = 1\n+const a = 2\n' > "$CLTMP/diff"
# spy_run <driver> <lane> [VAR=value...] — one review by <lane> through the spy; status = the driver's.
spy_run() {
  local drv="$1" lane="$2"; shift 2
  rm -f "$CLTMP/spy.out"
  env -i HOME="$CLTMP/spyhome" CODEX_HOME="$CLTMP/spyhome/.codex" ZUVO_HOME="$CLTMP/spyhome/.zuvo" \
    TMPDIR="$CLTMP/tmp" PATH="$PATH" LANG=C ZUVO_NO_CAFFEINATE=1 ZUVO_PROVIDER_BENCH=0 \
    ZUVO_CODEX_BIN="$CLTMP/spy/codex" ZUVO_CODEX_APP_BIN=/nonexistent SPY_OUT="$CLTMP/spy.out" "$@" \
    bash "$drv" --provider "$lane" --mode code < "$CLTMP/diff" > /dev/null 2> "$CLTMP/effort.err"
}
# effort_of <driver> <lane> [VAR=value...] — the effort that lane's client got, or "rc=<n>" when the run failed.
effort_of() {
  local rc=0
  spy_run "$@" || rc=$?
  if [ "$rc" -eq 0 ]; then cat "$CLTMP/spy.out" 2>/dev/null || echo "<spy never ran>"; else echo "rc=$rc"; fi
}
# NOREG — a copy of the driver with its modules and the shared runner but no model registry: an install
# without it, where the lane wrappers' own fallbacks decide.
. "$ROOT/tests/lib/adversarial-driver.sh"
adv_driver_copy "$ADV" "$CLTMP/noreg/adversarial-review.sh" || fail "premise: copying the driver failed"
cp "$ROOT/scripts/lib/model-subprocess.sh" "$CLTMP/noreg/lib/model-subprocess.sh"
NOREG="$CLTMP/noreg/adversarial-review.sh"

# ─── 7. the two efforts are INDEPENDENT, not one global ───────────────────
# The wrappers must read a per-lane variable first. If both collapsed onto ZUVO_CODEX_EFFORT the
# reviews would still run — with the wrong dial on one lane and nothing to show for it.
start_test "cx.7 each lane reads its own effort variable"
# The repo driver loads the model registry, which gives each lane its own default.
assert_eq "none"   "$(effort_of "$ADV" codex-5.3)" "codex-5.3 (sol): none, the registry's per-lane default"
assert_eq "medium" "$(effort_of "$ADV" codex-5.4)" "codex-5.4 (luna): medium"
assert_eq "low"  "$(effort_of "$ADV" codex-5.3 ZUVO_CODEX_EFFORT_PRIMARY=low ZUVO_CODEX_EFFORT_ALT=high)" \
  "codex-5.3 takes ZUVO_CODEX_EFFORT_PRIMARY…"
assert_eq "high" "$(effort_of "$ADV" codex-5.4 ZUVO_CODEX_EFFORT_PRIMARY=low ZUVO_CODEX_EFFORT_ALT=high)" \
  "…and codex-5.4 ZUVO_CODEX_EFFORT_ALT, each its own"
# A driver that finds no registry (an install without it) falls back inside the lane wrappers: the lane's
# own variable, then the global ZUVO_CODEX_EFFORT, then the lane's benchmarked default.
assert_eq "none"   "$(effort_of "$NOREG" codex-5.3)" "no registry: codex-5.3 falls back to none"
assert_eq "medium" "$(effort_of "$NOREG" codex-5.4)" "no registry: codex-5.4 falls back to medium"
assert_eq "high" "$(effort_of "$NOREG" codex-5.3 ZUVO_CODEX_EFFORT=high)" "no registry: the global ZUVO_CODEX_EFFORT comes before the lane default (codex-5.3)"
assert_eq "high" "$(effort_of "$NOREG" codex-5.4 ZUVO_CODEX_EFFORT=high)" "…(codex-5.4)"
assert_eq "low"  "$(effort_of "$NOREG" codex-5.4 ZUVO_CODEX_EFFORT=high ZUVO_CODEX_EFFORT_ALT=low)" \
  "no registry: the lane's own variable comes before the global"

# ─── 8. an EMPTY lane variable is an unset one ────────────────────────────
# Both the registry (`${ZUVO_CODEX_EFFORT_PRIMARY:-none}`) and the wrappers (adversarial-lanes.sh:167, :172,
# `${ZUVO_CODEX_EFFORT_ALT:-${ZUVO_CODEX_EFFORT:-medium}}`) read with `:-`, so `VAR=` takes the next source.
# Never the empty string: run_codex turns an empty effort into NO model_reasoning_effort line (cx.9), and a
# lane would then silently run at the model's own default instead of its benchmarked dial.
start_test "cx.8 an empty per-lane effort variable falls through, it does not blank the dial"
assert_eq "none"   "$(effort_of "$ADV" codex-5.3 ZUVO_CODEX_EFFORT_PRIMARY=)" "registry: an empty PRIMARY gives codex-5.3 its default none"
assert_eq "medium" "$(effort_of "$ADV" codex-5.4 ZUVO_CODEX_EFFORT_ALT=)" "registry: an empty ALT gives codex-5.4 its default medium"
assert_eq "high"   "$(effort_of "$NOREG" codex-5.3 ZUVO_CODEX_EFFORT_PRIMARY= ZUVO_CODEX_EFFORT=high)" \
  "no registry: an empty PRIMARY falls through to the global ZUVO_CODEX_EFFORT"
assert_eq "medium" "$(effort_of "$NOREG" codex-5.4 ZUVO_CODEX_EFFORT_ALT= ZUVO_CODEX_EFFORT=)" \
  "no registry: empty ALT and empty global — the lane default medium, not <no effort line>"

# ─── 9. run_codex itself: no effort given → no effort line ────────────────
# The wrappers always pass an effort (cx.8), so this is reachable only through run_codex itself: the shared
# runner and the driver's modules sourced into one shell, runner_ready taken from the driver's text.
start_test "cx.9 run_codex with no effort argument writes no effort line, or the global one"
awk '/^runner_ready\(\) \{/ { f = 1 } f { print } f && /^}/ { exit }' "$ADV" > "$CLTMP/runner_ready.sh"
assert_contains "$(cat "$CLTMP/runner_ready.sh")" "runner_ready()" "premise: runner_ready read from the driver"
CX_MODDIR="$(adv_driver_module_dir "$ADV")"
# direct_codex [VAR=value...] — run_codex gpt-5.5 codex-5.3 (two arguments, no effort) against the spy: the
# effort the client got, or "rc=<n>".
direct_codex() {
  local rc=0
  rm -f "$CLTMP/spy.out"
  # shellcheck disable=SC2016,SC2046  # expanded by the inner bash; module names are single words
  env -i HOME="$CLTMP/spyhome" CODEX_HOME="$CLTMP/spyhome/.codex" TMPDIR="$CLTMP/tmp" PATH="$PATH" LANG=C \
    ZUVO_CODEX_BIN="$CLTMP/spy/codex" ZUVO_CODEX_APP_BIN=/nonexistent SPY_OUT="$CLTMP/spy.out" "$@" \
    bash -c '
      lib="$1" md="$2" rr="$3"; shift 3
      . "$lib" || exit 9
      for m in "$@"; do . "$md/$m" || exit 9; done
      . "$rr" || exit 9
      ZMS_LOADED="$lib" REVIEW_MODE=code PROVIDER_TIMEOUT=60 REVIEW_PROMPT="review this"
      JSON_TMPDIR="$(mktemp -d)" || exit 9
      rc=0; run_codex gpt-5.5 codex-5.3 > /dev/null || rc=$?
      rm -rf "$JSON_TMPDIR"; exit "$rc"' _ "$LIB" "$CX_MODDIR" "$CLTMP/runner_ready.sh" $(adv_driver_modules "$ADV") \
    2> "$CLTMP/direct.err" || rc=$?
  if [ "$rc" -eq 0 ]; then cat "$CLTMP/spy.out" 2>/dev/null || echo "<spy never ran>"; else echo "rc=$rc"; fi
}
assert_eq "<no effort line>" "$(direct_codex)" "no argument, no ZUVO_CODEX_EFFORT: config.toml has no model_reasoning_effort"
assert_eq "low" "$(direct_codex ZUVO_CODEX_EFFORT=low)" "no argument: ZUVO_CODEX_EFFORT is the effort"

# ─── 10. token accounting (ZUVO_CODEX_TOKENS_FILE) ────────────────────────
# adversarial-lanes.sh:78-83: opt-in; after the client exits — success OR failure — the line after the
# client's `tokens used` stderr line is appended to the file, commas and spaces removed, as one line; anything
# that is then not all digits (or no such line at all) appends an EMPTY line, so one run is one line.
start_test "cx.10 ZUVO_CODEX_TOKENS_FILE gets one line per run: the token count, or nothing"
TOK="$CLTMP/tokens.txt"; rm -f "$TOK"
tok_lines() { tr '\n' '|' 2>/dev/null < "$TOK"; }
spy_run "$ADV" codex-5.3 ZUVO_CODEX_TOKENS_FILE="$TOK" SPY_STDERR='working\ntokens used\n12,345\n'
assert_exit_code "0" "$?" "a review whose client reported 12,345 tokens"
assert_eq "12345|" "$(tok_lines)" "…the file holds 12345 (separator removed) on one line"
spy_run "$ADV" codex-5.3 ZUVO_CODEX_TOKENS_FILE="$TOK" SPY_STDERR='tokens used\nn/a\n'
assert_eq "12345||" "$(tok_lines)" "a count that is not all digits appends an empty line"
spy_run "$ADV" codex-5.3 ZUVO_CODEX_TOKENS_FILE="$TOK" SPY_STDERR='boom\ntokens used\n9,876\n' SPY_EXIT=3
assert_exit_code "2" "$?" "a client that fails (exit 3): no review"
assert_eq "12345||9876|" "$(tok_lines)" "…and its tokens are still recorded (accounting runs before the status check)"
spy_run "$ADV" codex-5.3 ZUVO_CODEX_TOKENS_FILE="$TOK"
assert_eq "12345||9876||" "$(tok_lines)" "a client that printed no 'tokens used' appends an empty line"

# ─── 11. token accounting is OFF unless asked for ─────────────────────────
# adversarial-lanes.sh:78 gates the block on `-n`: unset or empty, the count reaches no file under HOME,
# TMPDIR or the cwd. The control sets the knob, so the number was there to be written.
start_test "cx.11 ZUVO_CODEX_TOKENS_FILE unset or empty: the token count is written nowhere"
CX11="$CLTMP/cx11"; mkdir -p "$CX11/cwd"
# cx11_hits — files under the run's HOME, TMPDIR and cwd that hold the count, in either spelling.
cx11_hits() { grep -rlE '73,?519' "$CLTMP/spyhome" "$CLTMP/tmp" "$CX11/cwd" 2>/dev/null | wc -l | tr -d ' '; }
assert_eq "0" "$(cx11_hits)" "premise: no file holds the count before the runs"
rc=0; ( cd "$CX11/cwd" && spy_run "$ADV" codex-5.3 SPY_STDERR='working\ntokens used\n73,519\n' ) || rc=$?
assert_exit_code "0" "$rc" "unset: the review ran (the client printed 'tokens used' and 73,519)"
assert_eq "0" "$(cx11_hits)" "unset: no file anywhere holds the count"
rc=0; ( cd "$CX11/cwd" && spy_run "$ADV" codex-5.3 ZUVO_CODEX_TOKENS_FILE= SPY_STDERR='working\ntokens used\n73,519\n' ) || rc=$?
assert_exit_code "0" "$rc" "empty: the review ran"
assert_eq "0" "$(cx11_hits)" "empty is unset (-n, lanes.sh:78): no file anywhere holds the count"
assert_eq "" "$(ls -A "$CX11/cwd")" "…and nothing at all was written into the working directory"
rc=0; ( cd "$CX11/cwd" && spy_run "$ADV" codex-5.3 ZUVO_CODEX_TOKENS_FILE="$CX11/tokens.txt" SPY_STDERR='working\ntokens used\n73,519\n' ) || rc=$?
assert_exit_code "0" "$rc" "control: the same review with the knob set"
assert_eq "73519" "$(cat "$CX11/tokens.txt" 2>/dev/null)" "control: then the count IS written, as one line (lanes.sh:79-82)"
assert_eq "0" "$(cx11_hits)" "control: …to the named file only — still nothing under HOME, TMPDIR or the cwd"

# ─── 12. the run log records the effort each codex lane ran at ────────────
# spy_run's log is ZUVO_HOME/adversarial.log; the column is found by NAME in its header. The expected values
# are the ones cx.7 proved reach the client — the log must say what ran, not what is configured somewhere.
# logged_effort <lane> -> that lane's effort in the newest row of the spy's log
logged_effort() {
  awk -F'\t' -v l="$1" 'NR == 1 { for (i = 1; i <= NF; i++) { if ($i == "effort") e = i; if ($i == "provider") p = i }; next }
                       e && $p == l { v = $e } END { print (e ? v : "<no effort column>") }' "$CLTMP/spyhome/.zuvo/adversarial.log" 2>/dev/null
}
start_test "cx.12 each codex lane's log row carries the effort its client got"
rm -f "$CLTMP/spyhome/.zuvo/adversarial.log"
assert_eq "none" "$(effort_of "$ADV" codex-5.3)" "premise: codex-5.3's client got none"
assert_eq "none" "$(logged_effort codex-5.3)" "codex-5.3 row: none"
assert_eq "medium" "$(effort_of "$ADV" codex-5.4)" "premise: codex-5.4's client got medium"
assert_eq "medium" "$(logged_effort codex-5.4)" "codex-5.4 row: medium"
assert_eq "low" "$(effort_of "$ADV" codex-5.3 ZUVO_CODEX_EFFORT_PRIMARY=low)" "premise: an override reaches the client"
assert_eq "low" "$(logged_effort codex-5.3)" "…and the row: the override, not the registry default"

start_test "cx.13 the logged effort is lowercased, and one that is still not a plain word is ?"
# The runner passes these on (it refuses only quotes, backslashes and control characters, so a tab never reaches a
# row through codex — test-lane-effort le.5 covers that one on provider_effort directly).
rm -f "$CLTMP/spyhome/.zuvo/adversarial.log"
assert_eq "High" "$(effort_of "$ADV" codex-5.3 ZUVO_CODEX_EFFORT_PRIMARY=High)" "premise: the client got High"
assert_eq "high" "$(logged_effort codex-5.3)" "the row: high — the level that ran, in the column's one spelling"
assert_eq "very high" "$(effort_of "$ADV" codex-5.3 "ZUVO_CODEX_EFFORT_PRIMARY=very high")" "premise: the client got 'very high'"
assert_eq "?" "$(logged_effort codex-5.3)" "the row: ? (a space is not a plain word)"
assert_eq "18" "$(awk -F'\t' '$14 == "codex-5.3" { n = NF } END { print n }' "$CLTMP/spyhome/.zuvo/adversarial.log" 2>/dev/null)" \
  "…in a row of exactly 18 fields"

