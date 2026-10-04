#!/usr/bin/env bash
#
# test-adversarial-hardening.sh — defects in scripts/adversarial-review.sh (and its modules) found while it
# was split into modules (2026-10-04, zuvo:refactor): by the CQ audits taken before and after the split and
# by the split's cross-model review. One section per defect. Every section was RED on the code before its
# fix and GREEN after it; the refactor's red/green proof ran each one alone:
#   ADV_HARDENING_ONLY=<ID> bash tests/hooks/test-adversarial-hardening.sh     # one section
#   bash tests/hooks/test-adversarial-hardening.sh                              # all of them
# No real provider is called: lanes are test-harness mocks or fake clients first on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AR="${ZUVO_TEST_AR:-$ROOT/scripts/adversarial-review.sh}"
T="$(mktemp -d)" || { echo "  ✗ mktemp -d failed"; exit 1; }
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — [$2] not in [$(printf '%s' "$3" | head -c 300)]" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1 — [$2] found in [$(printf '%s' "$3" | head -c 300)]" ;; *) ok "$1" ;; esac; }
only() { [ -z "${ADV_HARDENING_ONLY:-}" ] || [ "$ADV_HARDENING_ONLY" = "$1" ]; }

[ -f "$AR" ] || { echo "  ✗ driver not found: $AR"; exit 1; }
BIN="$T/bin"; mkdir -p "$BIN" "$T/tmp"
REPO="$T/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q . && git config user.email t@t && git config user.name t \
  && printf 'const a = 1;\n' > a.js && git add a.js && git commit -qm init ) >/dev/null 2>&1
DIFF='diff --git a/a.js b/a.js
--- a/a.js
+++ b/a.js
@@ -1 +1 @@
-const a = 1;
+const a = 2;
'
# mock <name> <body> — a test-harness lane on PATH: it reads the prompt from stdin, then runs <body>.
mock() { printf '#!/bin/sh\ncat > /dev/null\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
mock mock-ok 'printf "%s\n" "{\"findings\": []}"'
# drive <tag> [VAR=value...] -- <driver args...> — the driver in $REPO under the test harness, stdin =
# $DIFF unless STDIN_FILE is set; out/err in $T/<tag>.out/.err; prints the exit code. HOME, ZUVO_HOME and
# TMPDIR are the case's own, so nothing reaches the real ~/.zuvo.
drive() {
  local tag="$1" rc=0; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  mkdir -p "$T/home-$tag/.zuvo"
  ( cd "$REPO" && env HOME="$T/home-$tag" ZUVO_HOME="$T/home-$tag/.zuvo" TMPDIR="$T/tmp" PATH="$BIN:$PATH" \
      ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="${LANES:-mock-ok}" \
      ZUVO_RUN_ID="hardening-$tag-$$" ${envs[@]+"${envs[@]}"} \
      bash "$AR" "$@" < "${STDIN_FILE:-/dev/stdin}" ) > "$T/$tag.out" 2> "$T/$tag.err" <<< "$DIFF" || rc=$?
  echo "$rc"
}
out() { cat "$T/$1.out" 2>/dev/null; }
err() { cat "$T/$1.err" 2>/dev/null; }

if only M1; then
echo "=== M1 a module set from two installs is never loaded (the split's own loader) ==="
# The loader checked one directory, every file present, every required function defined — and a COMPLETE
# set whose files came from two releases passed all three: an install interrupted between two modules, or
# a review started while one was copying, ran code no single checkout ever held. install.sh now writes
# adversarial-modules.cksum beside every set it installs, last; the loader refuses a set that does not
# match it (after waiting briefly for an install still in progress) and moves on to the next candidate.
. "$ROOT/tests/lib/adversarial-driver.sh"
# shellcheck disable=SC2046  # module names, one word each: split on purpose
m1_sum() { ( cd "$1" && cat $(adv_driver_modules "$AR") ) | cksum; }
m1_copy() {   # <dir> <layout> — a driver copy with its modules (no stamp yet)
  rm -rf "$1"; adv_driver_copy "$AR" "$1/adversarial-review.sh" "$2" || bad "M1 premise: copying the driver into $1 failed"
}
m1_run() {    # <tag> <driver> [VAR=value...] — a dry run; prints the exit code
  local tag="$1" drv="$2" rc=0; shift 2
  mkdir -p "$T/home-$tag/.zuvo"
  ( cd "$REPO" && env HOME="$T/home-$tag" ZUVO_HOME="$T/home-$tag/.zuvo" TMPDIR="$T/tmp" PATH="$BIN:$PATH" \
      ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-ok "$@" \
      bash "$drv" --dry-run <<< "$DIFF" ) > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  echo "$rc"
}
# A stamp that matches: the set runs.
m1_copy "$T/m1-ok" lib; m1_sum "$T/m1-ok/lib" > "$T/m1-ok/lib/adversarial-modules.cksum"
same "M1 a set that matches its stamp runs (dry run, exit 0)" "0" "$(m1_run m1-ok "$T/m1-ok/adversarial-review.sh")"
# A set changed after its stamp was written — an install that stopped half way — and nothing else to use.
m1_copy "$T/m1-mixed" lib; m1_sum "$T/m1-mixed/lib" > "$T/m1-mixed/lib/adversarial-modules.cksum"
printf '\n# a module from another release\n' >> "$T/m1-mixed/lib/$(adv_driver_modules "$AR" | tail -1)"
rc="$(m1_run m1-mixed "$T/m1-mixed/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=1)"
same "M1 a set that does not match its stamp is refused (exit 2)" "2" "$rc"
has "M1 …saying why" "does not match its install stamp" "$(err m1-mixed)"
# The same in lib/, with a complete flat set that matches its own stamp beside the driver: the flat set is
# used. The lib/ set is unloadable on purpose (a module that does not parse), so only skipping it passes.
m1_copy "$T/m1-fall" lib; m1_sum "$T/m1-fall/lib" > "$T/m1-fall/lib/adversarial-modules.cksum"
printf '\nif then\n' >> "$T/m1-fall/lib/$(adv_driver_modules "$AR" | tail -1)"
for m in $(adv_driver_modules "$AR"); do cp "$(adv_driver_module_dir "$AR")/$m" "$T/m1-fall/$m"; done
m1_sum "$T/m1-fall" > "$T/m1-fall/adversarial-modules.cksum"
same "M1 lib/ out of step with its stamp, a stamped flat set beside it: the flat set runs (exit 0)" "0" \
  "$(m1_run m1-fall "$T/m1-fall/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=1)"
# An install still copying: the stamp is rewritten a moment later, and the run waits for it.
m1_copy "$T/m1-wait" lib; printf '1 2\n' > "$T/m1-wait/lib/adversarial-modules.cksum"
( sleep 1; m1_sum "$T/m1-wait/lib" > "$T/m1-wait/lib/adversarial-modules.cksum.new" \
  && mv "$T/m1-wait/lib/adversarial-modules.cksum.new" "$T/m1-wait/lib/adversarial-modules.cksum" ) &
same "M1 a stamp that catches up within the wait: the set runs (exit 0)" "0" \
  "$(m1_run m1-wait "$T/m1-wait/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=5)"
wait
# An install that knew it failed says so in the stamp: refused at once, no wait.
m1_copy "$T/m1-inc" lib; printf 'install-incomplete\n' > "$T/m1-inc/lib/adversarial-modules.cksum"
m1_t0=$(date +%s)
rc="$(m1_run m1-inc "$T/m1-inc/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=10)"
m1_el=$(( $(date +%s) - m1_t0 ))
same "M1 a set its install marked incomplete is refused (exit 2)" "2" "$rc"
[ "$m1_el" -lt 5 ] && ok "M1 …at once, without the wait (${m1_el}s)" || bad "M1 …after ${m1_el}s — it waited for a stamp that cannot change"
# No stamp at all — a git checkout, the plugin cache, a copy a test made: loaded as before.
m1_copy "$T/m1-none" lib
same "M1 a set with no stamp loads as before (exit 0)" "0" "$(m1_run m1-none "$T/m1-none/adversarial-review.sh")"
fi

if only F1; then
echo "=== F1 a flag that takes a value refuses a missing or flag-shaped one (CQ3) ==="
# Six flags read "$2" unguarded: under `set -u` a missing value died as `$2: unbound variable`, exit 1 —
# the code the contract reserves for "no review provider available".
for flag in --provider --mode --context --diff --files --artifact; do
  rc="$(drive "f1-missing$flag" -- --single "$flag")"
  same "F1 $flag with no value is a usage error (exit 2)" "2" "$rc"
  hasnt "F1 …not an unbound-variable crash" "unbound variable" "$(err "f1-missing$flag")"
  has "F1 …and it names the flag" "$flag requires" "$(err "f1-missing$flag")"
done
# --diff's value reaches `git diff "$REF"..HEAD`: a flag-shaped one was an OPTION to git, and
# --output=<file> made git write wherever the caller pointed (as <file>..HEAD, or <file> on the retry).
rc="$(drive f1-inject -- --single --dry-run --diff "--output=$T/pwned")"
same "F1 --diff with a flag-shaped value is a usage error (exit 2)" "2" "$rc"
if ls "$T"/pwned* >/dev/null 2>&1; then bad "F1 …but git wrote $(ls -d "$T"/pwned* | head -1): the value reached git as an option"
else ok "F1 …and nothing reached git as an option"; fi
# A value starting with '-' is a flag swallowed as the value: `--mode --json` used to read as mode '--json'.
rc="$(drive f1-swallow -- --single --mode --json)"
same "F1 --mode followed by another flag is a usage error (exit 2)" "2" "$rc"
has "F1 …that says the value is missing" "--mode requires" "$(err f1-swallow)"
fi

if only F2; then
echo "=== F2 a whole-number knob that is not one is refused with a WARN, never misread (CQ3) ==="
# ZUVO_REVIEW_TIMEOUT=10m is a valid `timeout` duration, and it crashed the deadline arithmetic.
rc="$(drive f2-timeout ZUVO_REVIEW_TIMEOUT=10m -- --single)"
same "F2 ZUVO_REVIEW_TIMEOUT=10m: the review still runs (exit 0)" "0" "$rc"
# No arithmetic error: one used to abort the deadline assignment (then an unbound variable ended the
# run), and since the module split it abandons the rest of ar_arm_deadline, the watchdog included.
hasnt "F2 …without an arithmetic error" "value too great" "$(err f2-timeout)"
has "F2 …and a WARN names the knob it ignored" "ZUVO_REVIEW_TIMEOUT" "$(err f2-timeout)"
# The --mode plan circuit-breaker: 9 passes already inside the window and a budget of 'eight'. The
# test `[ 9 -gt eight ]` errored inside the `if`, read as false, and the breaker never fired.
PLAN="$T/plan.md"
{ printf '# Plan\n\n'; for i in 1 2 3 4; do printf '### Task %d: step %d\n\nDo the thing number %d.\n\n' "$i" "$i" "$i"; done; } > "$PLAN"
key="$(printf '%s' "$(git -C "$REPO" rev-parse --show-toplevel)" | { shasum 2>/dev/null || sha1sum; } | cut -c1-16)"
mkdir -p "$T/home-f2-plan/.zuvo/plan-budget"
for i in 1 2 3 4 5 6 7 8 9; do date +%s >> "$T/home-f2-plan/.zuvo/plan-budget/$key"; done
rc="$(STDIN_FILE="$PLAN" drive f2-plan ZUVO_PLAN_ROUND_BUDGET=eight -- --mode plan --single)"
same "F2 ZUVO_PLAN_ROUND_BUDGET=eight with 9 passes in the window: the breaker fires on the default 8 (exit 7)" "7" "$rc"
has "F2 …and a WARN names the knob it ignored" "ZUVO_PLAN_ROUND_BUDGET" "$(err f2-plan)"
# A valid value is still honoured: with a budget of 20 the same 9 passes are allowed.
rc="$(STDIN_FILE="$PLAN" drive f2-plan ZUVO_PLAN_ROUND_BUDGET=20 -- --mode plan --single)"
same "F2 anchor: ZUVO_PLAN_ROUND_BUDGET=20 lets the 10th pass run (exit 0)" "0" "$rc"
fi

if only F3; then
echo "=== F3 truncating an input with many files cannot kill the run (CQ8) ==="
# The manifest of omitted files ran `… | sed … | head -20 | …` under pipefail. Once the omitted names
# outgrow one pipe write (a few KB: ~75 long paths), head exits after 20 lines, sed's next write takes
# SIGPIPE, the assignment returns 141, and `set -e` ended the run before any lane was asked.
MANY="$T/many.txt"
for i in $(seq 1 150); do
  printf '=== FILE: src/components/feature-area-with-a-long-name/sub-module-%03d/implementation-of-the-thing.js ===\n' "$i"
  for j in 1 2 3 4 5 6 7 8; do printf 'export const value_%03d_%d = "%s";\n' "$i" "$j" "padding-padding-padding"; done
done > "$MANY"
rc="$(STDIN_FILE="$MANY" drive f3 -- --single --no-chunk --dry-run)"
same "F3 150 long-named files over the cap, chunking off: the run goes on (dry run, exit 0)" "0" "$rc"
has "F3 …and says the input was truncated" "input truncated" "$(err f3)"
n="$(err f3 | sed -n 's/.*(omitted: \(.*\)).*/\1/p' | wc -w | tr -d ' ')"
same "F3 …naming the first 20 omitted files, as before" "20" "$n"
fi

if only F15; then
echo "=== F15 no SHA-1 tool on the host cannot kill a --mode plan run (CQ8) ==="
# With neither shasum nor sha1sum, the plan-budget key's pipeline exited 127 under pipefail and set -e
# ended the run there, silently — its own "SHA-free fallback" two lines later was unreachable.
mkdir -p "$T/nosha"
for t in shasum sha1sum; do printf '#!/bin/sh\nexit 127\n' > "$T/nosha/$t"; chmod +x "$T/nosha/$t"; done
PLAN="$T/f15-plan.md"
{ printf '# Plan\n\n'; for i in 1 2 3 4; do printf '### Task %d: step %d\n\nDo the thing number %d.\n\n' "$i" "$i" "$i"; done; } > "$PLAN"
rc="$(STDIN_FILE="$PLAN" drive f15 PATH="$T/nosha:$BIN:$PATH" -- --mode plan --single)"
same "F15 --mode plan with no shasum/sha1sum: the review runs (exit 0)" "0" "$rc"
same "F15 …and the pass is counted in the plan budget" "1" "$(cat "$T/home-f15/.zuvo/plan-budget/"* 2>/dev/null | wc -l | tr -d ' ')"
fi

if only F4; then
echo "=== F4 the codestral key never reaches curl's argv (CQ5) ==="
# `-H "Authorization: Bearer $CODESTRAL_API_KEY"` put the key in curl's argv, readable by every process
# on the host through ps for the life of the request — the exposure the openrouter and kimi-api lanes
# already close with a curl config file.
FAKE="$T/fake-curl"; mkdir -p "$FAKE"
cat > "$FAKE/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$@" > "$T/curl.argv"
prev=""; for a in "\$@"; do [ "\$prev" = "-K" ] && cat "\$a" > "$T/curl.cfg"; prev="\$a"; done
printf '%s' '{"choices":[{"message":{"content":"NO ISSUES FOUND."}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
EOF
chmod +x "$FAKE/curl"
rm -f "$T/curl.argv" "$T/curl.cfg"
rc="$(drive f4 PATH="$FAKE:$BIN:$PATH" CODESTRAL_API_KEY=sk-hardening-secret-4711 -- --provider codestral)"
same "F4 the codestral lane answers through the fake curl (exit 0)" "0" "$rc"
[ -s "$T/curl.argv" ] && ok "F4 premise: curl was called" || bad "F4 premise: curl was never called — the case proves nothing"
hasnt "F4 the key is not in curl's argv" "sk-hardening-secret-4711" "$(cat "$T/curl.argv" 2>/dev/null)"
has "F4 …it travels in the -K config file instead" "sk-hardening-secret-4711" "$(cat "$T/curl.cfg" 2>/dev/null)"
fi

# mode_of <path> — its permission bits in octal (GNU stat, then BSD stat).
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

if only F5; then
echo "=== F5 the saved review input is private (CQ5) ==="
# Every review's input — the diff, which can hold secrets — is kept for 7 days under
# ~/.zuvo/adversarial-inputs/. It was written at the ambient umask (world-readable on most hosts),
# while the failure evidence beside it is forced to 0700 for exactly this reason.
rc="$( umask 022; drive f5 -- --single )"
same "F5 the review runs (exit 0)" "0" "$rc"
saved="$(ls "$T/home-f5/.zuvo/adversarial-inputs/"*.diff 2>/dev/null | head -1)"
[ -n "$saved" ] && ok "F5 premise: the input was saved" || bad "F5 premise: no saved input under adversarial-inputs/"
same "F5 the saved input is 600 (owner only)" "600" "$(mode_of "$saved")"
same "F5 …in a 700 directory" "700" "$(mode_of "$T/home-f5/.zuvo/adversarial-inputs")"
fi

if only F6; then
echo "=== F6 the run log never lands in the repository under review (CQ8) ==="
# When ~/.zuvo/adversarial-inputs could not be created, LOG_DIR fell back to "." — the CWD, i.e. the
# repository being reviewed: the run log and the saved diff were written into it, and the tamper-check
# then reported the reviewers for changing the tree.
: > "$T/not-a-dir"
rc="$(drive f6 ZUVO_HOME="$T/not-a-dir" -- --single)"
same "F6 a ZUVO_HOME that cannot hold the log: the review still runs (exit 0)" "0" "$rc"
if [ -e "$REPO/adversarial.log" ] || [ -e "$REPO/adversarial-inputs" ]; then bad "F6 the run log / saved input was written into the reviewed repository"
else ok "F6 nothing was written into the reviewed repository"; fi
hasnt "F6 …so the tamper-check has nothing to report" "working tree changed during the review" "$(err f6)"
rm -rf "$REPO/adversarial.log" "$REPO/adversarial-inputs"
fi

echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "Tests: $PASS passed, $FAIL failed"   # the summary shape the refactor contract's red/green proof reads
[ "$FAIL" -eq 0 ]
