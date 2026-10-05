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
# only <ID> — run this section? Records that one ran: an ADV_HARDENING_ONLY naming no section (a typo, a
# renumbered id) used to run nothing and pass, "proving" a fix with zero cases (see the tail).
ONLY_HIT=0
only() {
  if [ -z "${ADV_HARDENING_ONLY:-}" ] || [ "$ADV_HARDENING_ONLY" = "$1" ]; then ONLY_HIT=1; return 0; fi
  return 1
}

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
# TMPDIR are the case's own, so nothing reaches the real ~/.zuvo. A VAR the caller passes REPLACES the
# default of that name — each variable reaches `env` once (which of two assignments wins is unspecified).
drive() {
  local tag="$1" rc=0 d e; shift
  local envs=() defs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  mkdir -p "$T/home-$tag/.zuvo"
  for d in "HOME=$T/home-$tag" "ZUVO_HOME=$T/home-$tag/.zuvo" "TMPDIR=$T/tmp" "PATH=$BIN:$PATH" \
           ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 "ZUVO_REVIEW_TEST_PROVIDERS=${LANES:-mock-ok}" \
           "ZUVO_RUN_ID=hardening-$tag-$$"; do
    for e in ${envs[@]+"${envs[@]}"}; do [ "${e%%=*}" = "${d%%=*}" ] && continue 2; done
    defs+=("$d")
  done
  ( cd "$REPO" && env "${defs[@]}" ${envs[@]+"${envs[@]}"} \
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
# m1_sum <module dir> — the stamp install.sh writes for that set: the driver beside it (in <dir> when flat,
# in its parent when <dir> is lib/), then its modules in AR_MODULES order.
# shellcheck disable=SC2046  # module names, one word each: split on purpose
m1_sum() {
  local drv="$1/adversarial-review.sh"
  [ -f "$drv" ] || drv="${1%/*}/adversarial-review.sh"
  { cat "$drv"; ( cd "$1" && cat $(adv_driver_modules "$AR") ); } | cksum
}
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
  "$(m1_run m1-wait "$T/m1-wait/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=20)"   # returns as soon as it matches
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
# empty-ok: an empty --context is a value, not a missing one.
rc="$(drive f1-ctx-empty -- --single --dry-run --context "")"
same "F1 --context \"\" is accepted (exit 0)" "0" "$rc"
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
# The budget file is the one a real plan review writes (a copy of the key formula here would drift from
# the driver's silently): one pass first, then eight more timestamps in that same file.
rc="$(STDIN_FILE="$PLAN" drive f2-plan -- --mode plan --single)"
same "F2 premise: a first plan review runs (exit 0)" "0" "$rc"
f2_files="$(ls "$T/home-f2-plan/.zuvo/plan-budget/" 2>/dev/null)"
same "F2 premise: it wrote exactly one budget file" "1" "$(printf '%s\n' "$f2_files" | awk 'NF' | wc -l | tr -d ' ')"
for i in 1 2 3 4 5 6 7 8; do date +%s >> "$T/home-f2-plan/.zuvo/plan-budget/$f2_files"; done
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
prev=""; for a in "\$@"; do
  if [ "\$prev" = "-K" ]; then
    cat "\$a" > "$T/curl.cfg"; printf '%s\n' "\$a" > "$T/curl.cfgpath"
    stat -c '%a' "\$a" 2>/dev/null > "$T/curl.cfgmode" || stat -f '%Lp' "\$a" > "$T/curl.cfgmode"
  fi
  prev="\$a"
done
printf '%s' '{"choices":[{"message":{"content":"NO ISSUES FOUND."}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
EOF
chmod +x "$FAKE/curl"
rm -f "$T/curl.argv" "$T/curl.cfg"
rc="$(drive f4 PATH="$FAKE:$BIN:$PATH" CODESTRAL_API_KEY=sk-hardening-secret-4711 -- --provider codestral)"
same "F4 the codestral lane answers through the fake curl (exit 0)" "0" "$rc"
[ -s "$T/curl.argv" ] && ok "F4 premise: curl was called" || bad "F4 premise: curl was never called — the case proves nothing"
hasnt "F4 the key is not in curl's argv" "sk-hardening-secret-4711" "$(cat "$T/curl.argv" 2>/dev/null)"
has "F4 …it travels in the -K config file instead" "sk-hardening-secret-4711" "$(cat "$T/curl.cfg" 2>/dev/null)"
# Moving the key from argv to a file must not leave it readable there: owner-only while curl reads it, and
# gone with the run's temp dir afterwards.
same "F4 …a file that is 600 while curl reads it" "600" "$(cat "$T/curl.cfgmode" 2>/dev/null)"
f4_cfg="$(cat "$T/curl.cfgpath" 2>/dev/null)"
[ -n "$f4_cfg" ] && [ ! -e "$f4_cfg" ] && ok "F4 …and removed with the run" || bad "F4 …and removed with the run — [${f4_cfg:-no path}] is still there"
# A key holding a quote would break out of the config's quoted `header = "…"` line: refused, never written.
rm -f "$T/curl.argv" "$T/curl.cfg"
rc="$(drive f4-quote PATH="$FAKE:$BIN:$PATH" CODESTRAL_API_KEY='sk-bad"key' -- --provider codestral)"
same "F4 a key holding a quote is refused: no review (exit 2)" "2" "$rc"
[ -e "$T/curl.argv" ] && bad "F4 …but curl ran with a config built from it" || ok "F4 …and curl is never called"
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
# Not merely "not in the repo": in the private temp dir runs share, owner-only.
f6_dir="$T/tmp/zuvo-adv-$(id -u)"
[ -s "$f6_dir/adversarial.log" ] && ok "F6 …the log went to the private temp dir" || bad "F6 …the log went to the private temp dir — no $f6_dir/adversarial.log"
same "F6 …whose saved inputs are 700" "700" "$(mode_of "$f6_dir/adversarial-inputs")"
rm -rf "$REPO/adversarial.log" "$REPO/adversarial-inputs"
# The private temp dir not ours either: the run's own temp dir, and still nothing in the repository.
mv "$f6_dir" "$f6_dir.f6-saved"; : > "$f6_dir"
rc="$(drive f6-noprivate ZUVO_HOME="$T/not-a-dir" -- --single)"
rm -f "$f6_dir"; mv "$f6_dir.f6-saved" "$f6_dir"
same "F6 no ZUVO_HOME and no private temp dir: the review still runs (exit 0)" "0" "$rc"
if [ -e "$REPO/adversarial.log" ] || [ -e "$REPO/adversarial-inputs" ]; then bad "F6 …but it wrote into the reviewed repository"
else ok "F6 …and nothing was written into the reviewed repository"; fi
rm -rf "$REPO/adversarial.log" "$REPO/adversarial-inputs"
fi

if only F7; then
echo "=== F7 a large --json answer is assembled from files, not argv (CQ6) ==="
# Each lane's answer reached jq as ONE argv string (--argjson v "$(…)"), and so did the whole results
# object. Past 128 KiB (Linux MAX_ARG_STRLEN) jq fails with E2BIG after the review has finished: no
# document on stdout and no artifact, as if nobody had answered.
cat > "$BIN/mock-big" <<'EOF'
#!/bin/sh
cat > /dev/null
pad="$(awk 'BEGIN { for (i = 0; i < 200000; i++) printf "x" }')"
printf '{"findings":[{"id":"a.js:1:big-answer","severity":"INFO","confidence":"low","file":"a.js:1","issue":"%s","attack_vector":"-","fix":"-","disposition":"new"}]}\n' "$pad"
EOF
chmod +x "$BIN/mock-big"
rc="$(LANES=mock-big drive f7 -- --single --json)"
same "F7 a 200 KB answer in --json mode: exit 0" "0" "$rc"
same "F7 …and stdout is one document holding it" "a.js:1:big-answer" "$(out f7 | jq -r '.results["mock-big"].findings[0].id' 2>/dev/null)"
same "F7 …byte for byte" "200000" "$(out f7 | jq -r '.results["mock-big"].findings[0].issue | length' 2>/dev/null)"
# A small answer that is not JSON is still kept as a string (the other branch of the same code).
mock mock-prose 'printf "%s\n" "SEVERITY: INFO — prose, not JSON"'
rc="$(LANES=mock-prose drive f7-prose -- --single --json)"
same "F7 anchor: a non-JSON answer is kept as a string" "SEVERITY: INFO — prose, not JSON" "$(out f7-prose | jq -r '.results["mock-prose"]' 2>/dev/null)"
fi

if only F8; then
echo "=== F8 the provider-health ledger is rewritten under a lock (CQ21) ==="
# record_provider_health reads the ledger, recomputes it and mv's the result over it. Parallel reviews
# do exactly that at the same time, and the last writer silently erased the other's increments and
# resets — the bench then reads a history that never happened. A writer that cannot take the lock
# leaves the ledger as it is (one lost update, said in a WARN) rather than clobbering a concurrent one.
HF="$T/health.tsv"; : > "$HF"
mkdir "$HF.lock"
rc="$(drive f8-held ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_PROVIDER_HEALTH_LOCK_WAIT=1 -- --single)"
same "F8 lock held by another run: the review itself still succeeds (exit 0)" "0" "$rc"
same "F8 …and the ledger is left untouched while the lock is held" "" "$(cat "$HF")"
has "F8 …which a WARN says" "provider-health ledger busy" "$(err f8-held)"
rmdir "$HF.lock"
rc="$(drive f8-free ZUVO_PROVIDER_HEALTH_FILE="$HF" -- --single)"
same "F8 lock free: exit 0" "0" "$rc"
has "F8 …and the lane's row is written" "mock-ok	" "$(cat "$HF")"
[ -e "$HF.lock" ] && bad "F8 …but the lock was left behind" || ok "F8 …and the lock is released"
# A lock left by a run that died (older than the stale limit) does not block the ledger forever.
mkdir "$HF.lock"; touch -t 202001010000 "$HF.lock"
: > "$HF"
rc="$(drive f8-stale ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_PROVIDER_HEALTH_LOCK_WAIT=1 -- --single)"
same "F8 stale lock: exit 0" "0" "$rc"
has "F8 a stale lock from a dead run is broken, and the row is written" "mock-ok	" "$(cat "$HF")"
[ -e "$HF.lock" ] && bad "F8 …but the broken lock was left behind" || ok "F8 …and the lock taken in its place is released"
rm -rf "$HF.lock"
fi

if only F9; then
echo "=== F9 the cursor lane runs the model its log and --json name (CQ20) ==="
# run_cursor_agent ran ${ZUVO_CURSOR_MODEL:-composer-2.5-fast} while provider_model — the run log, the
# health ledger, --json "models" — reported ZUVO_MODEL_CURSOR (auto). Verified 2026-10-04 against the
# live client (stream-json init event): the lane was reviewing with "Composer 2.5 Fast" all along. One
# source now: the lane asks provider_model, and the registry names composer-2.5-fast.
FAKE="$T/fake-cursor"; mkdir -p "$FAKE"
cat > "$FAKE/cursor-agent" <<EOF
#!/bin/sh
cat > /dev/null
prev=""; for a in "\$@"; do [ "\$prev" = "--model" ] && printf '%s\n' "\$a" > "$T/cursor.model"; prev="\$a"; done
echo "NO ISSUES FOUND."
EOF
chmod +x "$FAKE/cursor-agent"
rm -f "$T/cursor.model"
rc="$(drive f9 PATH="$FAKE:$BIN:$PATH" -- --provider cursor-agent --json)"
same "F9 the cursor lane answers (exit 0)" "0" "$rc"
ran="$(cat "$T/cursor.model" 2>/dev/null)"
[ -n "$ran" ] && ok "F9 premise: the client was asked for model [$ran]" || bad "F9 premise: the client was never called with --model"
same "F9 --json names the model the client was asked for" "$ran" "$(out f9 | jq -r '.models["cursor-agent"]' 2>/dev/null)"
same "F9 …which is composer-2.5-fast (the registry's choice, 2026-10-04)" "composer-2.5-fast" "$ran"
rc="$(drive f9-pin PATH="$FAKE:$BIN:$PATH" ZUVO_CURSOR_MODEL=cursor-grok-4.5-high-fast -- --provider cursor-agent --json)"
same "F9 a pinned ZUVO_CURSOR_MODEL is what runs AND what is reported" "cursor-grok-4.5-high-fast cursor-grok-4.5-high-fast" \
  "$(cat "$T/cursor.model" 2>/dev/null) $(out f9-pin | jq -r '.models["cursor-agent"]' 2>/dev/null)"
fi

if only F13; then
echo "=== F13 a codex lane reports the model the CLI guard let it run (CQ20) ==="
# codex_cli_guard drops gpt-6* to gpt-5.6-sol (and further) when the local CLI is too old for it, but
# provider_model kept reporting the configured id — the run log, the health ledger and --json "models"
# named a model that never ran. The lane now records the model it actually ran, as the agy lane does.
FAKE="$T/fake-codex"; mkdir -p "$FAKE"
cat > "$FAKE/codex" <<EOF
#!/bin/sh
case "\$1" in
  --version) echo "codex-cli 0.150.0"; exit 0 ;;
esac
cat > /dev/null
sed -n 's/^model *= *"\(.*\)"/\1/p' "\$CODEX_HOME/config.toml" > "$T/codex.model"
echo "NO ISSUES FOUND."
EOF
chmod +x "$FAKE/codex"
rm -f "$T/codex.model"
rc="$(drive f13 ZUVO_CODEX_BIN="$FAKE/codex" ZUVO_CODEX_APP_BIN= -- --provider codex-5.3 --json)"
same "F13 the codex lane answers through the fake CLI (exit 0)" "0" "$rc"
ran="$(cat "$T/codex.model" 2>/dev/null)"
same "F13 premise: CLI 0.150 is too old for gpt-6, so the guard ran gpt-5.6-sol" "gpt-5.6-sol" "$ran"
same "F13 --json names the model that ran, not the one configured" "$ran" "$(out f13 | jq -r '.models["codex-5.3"]' 2>/dev/null)"
log="$(ls "$T/home-f13/.zuvo/adversarial.log" 2>/dev/null)"
same "F13 …and so does the run log's model column" "$ran" "$(awk -F'\t' '$14 == "codex-5.3" { m = $4 } END { print m }' "$log" 2>/dev/null)"
fi

if only F10; then
echo "=== F10 an auth failure excludes a lane for ZUVO_AUTH_CACHE_TTL, not forever (CQ23) ==="
# The run-scoped auth-failure cache is keyed by ZUVO_RUN_ID, else by the repository — and without a
# run id nothing ever expired an entry: one failed login kept the lane out of every later review of
# that repository until the temp directory was cleared. Entries now carry their time; older than the
# TTL (default 6 h) they no longer exclude. A line from before (no time) is treated as expired.
mock mock-ok2 'printf "%s\n" "{\"findings\": []}"'
CACHE_DIR="$T/tmp/zuvo-adv-$(id -u)"; mkdir -p "$CACHE_DIR"; chmod 700 "$CACHE_DIR"
now="$(date +%s)"
# drive's ZUVO_RUN_ID is hardening-<tag>-<pid>; the cache file is failed-providers.<that id>.
# --single over "mock-ok mock-ok2": the first lane NOT excluded answers, so the outcome says which one ran —
# the absence of the skip line alone would also pass for a run that died before the cache was read.
f10_case() {   # <tag> <cache line> <want outcome> <label> [VAR=value...]
  local tag="$1" line="$2" want="$3" label="$4" rc; shift 4
  printf '%s\n' "$line" > "$CACHE_DIR/failed-providers.hardening-$tag-$$"
  rc="$(LANES="mock-ok mock-ok2" drive "$tag" "$@" -- --single --json)"
  same "$label: exit 0" "0" "$rc"
  same "$label: the lane that answered" "$want" "$(out "$tag" | jq -r '.provider_outcomes' 2>/dev/null)"
}
f10_case f10-legacy "mock-ok" "mock-ok:ok" "F10 a cached failure with no time (from before) no longer excludes the lane"
f10_case f10-old "$(printf 'mock-ok\t%s' "$((now - 7 * 3600))")" "mock-ok:ok" "F10 a failure cached 7 h ago (TTL 6 h) no longer excludes the lane"
f10_case f10-fresh "$(printf 'mock-ok\t%s' "$((now - 3600))")" "mock-ok2:ok" "F10 a failure cached 1 h ago still excludes the lane"
f10_case f10-short "$(printf 'mock-ok\t%s' "$((now - 3600))")" "mock-ok:ok" "F10 …unless ZUVO_AUTH_CACHE_TTL is shorter than its age" ZUVO_AUTH_CACHE_TTL=600
# Without a run id the cache is keyed by the REPOSITORY — the path on which nothing ever expired an entry.
# The driver writes that file itself (an auth stub, no ZUVO_RUN_ID); the case then ages the entry.
mock mock-authstub 'printf "%s\n" "Not logged in · Please run /login"'
f10_before=" $(ls "$CACHE_DIR" | tr '\n' ' ')"
rc="$(LANES="mock-authstub mock-ok" drive f10-repo ZUVO_RUN_ID= -- --multi)"
f10_repo_file="$(ls "$CACHE_DIR" | awk -v b="$f10_before" 'index(b, " " $0 " ") == 0' | head -1)"
[ -n "$f10_repo_file" ] && ok "F10 premise: without a run id the driver keyed its cache by the repository ($f10_repo_file)" \
  || bad "F10 premise: no repository-keyed cache file was written"
if [ -n "$f10_repo_file" ]; then
  printf 'mock-ok\t%s\n' "$((now - 3600))" > "$CACHE_DIR/$f10_repo_file"
  rc="$(LANES="mock-ok mock-ok2" drive f10-repo-fresh ZUVO_RUN_ID= -- --single --json)"
  same "F10 repository-keyed cache: an entry 1 h old excludes the lane" "mock-ok2:ok" "$(out f10-repo-fresh | jq -r '.provider_outcomes' 2>/dev/null)"
  printf 'mock-ok\t%s\n' "$((now - 7 * 3600))" > "$CACHE_DIR/$f10_repo_file"
  rc="$(LANES="mock-ok mock-ok2" drive f10-repo-old ZUVO_RUN_ID= -- --single --json)"
  same "F10 …and one 7 h old no longer does" "mock-ok:ok" "$(out f10-repo-old | jq -r '.provider_outcomes' 2>/dev/null)"
  rm -f "$CACHE_DIR/$f10_repo_file"
fi
# A new auth failure is recorded WITH its time, so it can expire.
mock mock-authstub 'printf "%s\n" "Not logged in · Please run /login"'
rc="$(LANES="mock-authstub mock-ok" drive f10-record -- --multi)"
rec="$(cat "$CACHE_DIR/failed-providers.hardening-f10-record-$$" 2>/dev/null)"
case "$rec" in mock-authstub$'\t'[0-9]*) ok "F10 a new auth failure is cached with its time" ;; *) bad "F10 a new auth failure is cached as [$rec], not <lane><TAB><epoch>" ;; esac
fi

if only F12; then
echo "=== F12 --mode article is reviewed as a document, by an article rubric ==="
# write-article and content-expand pass their draft as --mode article. The mode was accepted but had
# no rubric anywhere: the draft went out under "You are a hostile code reviewer" with the CODE focus
# list (edge cases, resource leaks, God objects) — a long-form article judged as source code.
ART="$T/article.md"
{ printf '# Why teams adopt feature flags\n\n'
  for s in 1 2 3; do
    printf '## Section %d\n\n' "$s"
    for _ in 1 2 3; do printf 'Feature flags let a team ship code dark and switch it on later. Teams report fewer rollbacks and calmer releases when the switch is separate from the deploy, and the evidence for that is mixed. '; done
    printf '\n\n'
  done; } > "$ART"
rc="$(drive f12 -- --single --mode article --dry-run --files "$ART")"
same "F12 --mode article dry run: exit 0" "0" "$rc"
has "F12 …the prompt is the document auditor's" "hostile document auditor" "$(out f12)"
hasnt "F12 …not the code reviewer's" "hostile code reviewer" "$(out f12)"
has "F12 …with the article rubric" "LONG-FORM ARTICLE" "$(out f12)"
hasnt "F12 …and no code focus list" "God objects" "$(out f12)"
printf '# Short\n\nOnly a few words here.\n' > "$T/short.md"
rc="$(drive f12-short -- --single --mode article --dry-run --files "$T/short.md")"
same "F12 an article under the document minimum is not reviewable material (exit 5)" "5" "$rc"
fi

if only F11; then
echo "=== F11 an interrupted review takes its lanes' clients down with it (CQ35) ==="
# cleanup killed the dispatch subshells only. Each lane runs its client under `timeout` (its own
# process group) or the shared runner, so after Ctrl-C / an orchestrator's TERM the clients kept running
# — and kept spending — until their own timeout, up to ZUVO_REVIEW_TIMEOUT + grace later.
cat > "$BIN/mock-sleeper" <<EOF
#!/bin/sh
cat > /dev/null
echo \$\$ > "$T/sleeper.pid"
exec sleep 300
EOF
chmod +x "$BIN/mock-sleeper"
rm -f "$T/sleeper.pid"
mkdir -p "$T/home-f11/.zuvo"
( cd "$REPO" && exec env HOME="$T/home-f11" ZUVO_HOME="$T/home-f11/.zuvo" TMPDIR="$T/tmp" PATH="$BIN:$PATH" \
    ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="mock-sleeper mock-ok" \
    ZUVO_RUN_ID="hardening-f11-$$" bash "$AR" --multi <<< "$DIFF" > "$T/f11.out" 2> "$T/f11.err" ) &
drv=$!
for _ in $(seq 1 100); do [ -s "$T/sleeper.pid" ] && break; sleep 0.1; done
sleeper="$(cat "$T/sleeper.pid" 2>/dev/null)"
if [ -z "$sleeper" ]; then
  bad "F11 premise: the sleeping lane never started"
  kill -TERM "$drv" 2>/dev/null; wait "$drv" 2>/dev/null
else
  ok "F11 premise: a lane's client is running (pid $sleeper)"
  kill -TERM "$drv"; wait "$drv"; rc=$?
  same "F11 the driver exits 143 on TERM" "143" "$rc"
  alive=1; for _ in $(seq 1 30); do kill -0 "$sleeper" 2>/dev/null || { alive=0; break; }; sleep 0.1; done
  if [ "$alive" -eq 0 ]; then ok "F11 …and the lane's client is gone"
  else bad "F11 …but the lane's client (pid $sleeper) is still running"; kill -9 "$sleeper" 2>/dev/null; fi
fi
# A client NOT in `timeout`'s process group (the shared runner gives each client its own) is reached only
# by walking the WHOLE process tree — a walk one level deep left it running.
cat > "$BIN/mock-deep" <<EOF
#!/bin/sh
cat > /dev/null
python3 -c 'import os, sys; os.setsid(); open(sys.argv[1], "w").write(str(os.getpid())); os.execvp("sleep", ["sleep", "300"])' "$T/deep.pid" &
wait
EOF
chmod +x "$BIN/mock-deep"
rm -f "$T/deep.pid"
( cd "$REPO" && exec env HOME="$T/home-f11" ZUVO_HOME="$T/home-f11/.zuvo" TMPDIR="$T/tmp" PATH="$BIN:$PATH" \
    ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="mock-deep mock-ok" \
    ZUVO_RUN_ID="hardening-f11d-$$" bash "$AR" --multi <<< "$DIFF" > "$T/f11d.out" 2> "$T/f11d.err" ) &
drv=$!
for _ in $(seq 1 100); do [ -s "$T/deep.pid" ] && break; sleep 0.1; done
deep="$(cat "$T/deep.pid" 2>/dev/null)"
if [ -z "$deep" ]; then
  bad "F11 premise: the client in its own session never started"
  kill -TERM "$drv" 2>/dev/null; wait "$drv" 2>/dev/null
else
  kill -TERM "$drv"; wait "$drv"
  alive=1; for _ in $(seq 1 30); do kill -0 "$deep" 2>/dev/null || { alive=0; break; }; sleep 0.1; done
  if [ "$alive" -eq 0 ]; then ok "F11 …and a client in its own session, below the lane's timeout, is gone too"
  else bad "F11 …but the client in its own session (pid $deep) is still running"; kill -9 "$deep" 2>/dev/null; fi
fi
fi

if only F18; then
echo "=== F18 the run's temp dir is cleaned up from the moment it exists (CQ35) ==="
# JSON_TMPDIR was created in ar_init_run_state and the traps only armed after the run log was set up:
# a TERM in between left the temp dir (and anything a lane later wrote into it) behind.
REAL_MKDIR="$(command -v mkdir)"
mkdir -p "$T/slowmk"
# The shim leaves a marker when it is reached: TERM goes in then, inside the window — a fixed sleep could
# land before it on a loaded host (a false red), or after a refactor closed it (a false green).
rm -f "$T/f18.reached"
printf '#!/bin/sh\ncase "$*" in *adversarial-inputs*) : > "%s"; sleep 4 ;; esac\nexec "%s" "$@"\n' "$T/f18.reached" "$REAL_MKDIR" > "$T/slowmk/mkdir"
chmod +x "$T/slowmk/mkdir"
rm -rf "$T/tmp-f18"; "$REAL_MKDIR" -p "$T/tmp-f18"
( cd "$REPO" && exec env HOME="$T/home-f18" ZUVO_HOME="$T/home-f18/.zuvo" TMPDIR="$T/tmp-f18" PATH="$T/slowmk:$BIN:$PATH" \
    ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-ok \
    bash "$AR" --single <<< "$DIFF" > "$T/f18.out" 2> "$T/f18.err" ) &
f18_pid=$!
for _ in $(seq 1 100); do [ -e "$T/f18.reached" ] && break; sleep 0.1; done
[ -e "$T/f18.reached" ] && ok "F18 premise: the run reached the run-log setup" || bad "F18 premise: the run never reached the run-log setup's mkdir — the window was not held open"
f18_dirs_before="$(find "$T/tmp-f18" -mindepth 1 -maxdepth 1 -type d -name 'tmp.*' | wc -l | tr -d ' ')"
kill -TERM "$f18_pid" 2>/dev/null; wait "$f18_pid" 2>/dev/null
sleep 1
same "F18 premise: the run's temp dir existed when TERM came (inside the run-log setup)" "1" "$f18_dirs_before"
same "F18 …and TERM removed it" "0" "$(find "$T/tmp-f18" -mindepth 1 -maxdepth 1 -type d -name 'tmp.*' | wc -l | tr -d ' ')"
fi

if only F17; then
echo "=== F17 --doctor probes its lanes at the same time (CQ27) ==="
# One after another, a doctor over N lanes took up to N x ZUVO_DOCTOR_TIMEOUT — nine minutes for nine.
# The bound comes from a CONTROL doctor whose lanes answer at once (its own start-up on this host), plus
# one lane's 5 s and margin — far below the 15 s one-after-another would take.
for n in 1 2 3; do mock "mock-slow$n" 'sleep 5; echo PROVIDER-OK'; mock "mock-fast$n" 'echo PROVIDER-OK'; done
f17_t0=$(date +%s)
rc="$(LANES="mock-fast1 mock-fast2 mock-fast3" drive f17-control -- --doctor)"
f17_base=$(( $(date +%s) - f17_t0 ))
same "F17 premise: the control doctor exits 0" "0" "$rc"
f17_t0=$(date +%s)
rc="$(LANES="mock-slow1 mock-slow2 mock-slow3" drive f17 -- --doctor)"
f17_el=$(( $(date +%s) - f17_t0 ))
same "F17 three lanes that take 5 s each: exit 0" "0" "$rc"
[ "$f17_el" -lt $(( f17_base + 10 )) ] && ok "F17 …in ${f17_el}s (control ${f17_base}s), not 15+" || bad "F17 …took ${f17_el}s (control ${f17_base}s; one after another is 15+)"
same "F17 …all three reported WORKING" "mock-slow1 mock-slow2 mock-slow3" "$(awk '/WORKING/ { print $1 }' "$T/f17.out" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
fi

if only F16; then
echo "=== F16 a lane's fallback gets what is left of its timeout, not a second one (CQ28) ==="
# agy fell back from a quota-dead primary with a FULL fresh timeout (and kimi to kimi-api), so one lane
# could run past the whole-run deadline — which then killed the run and every other lane's answer.
REAL_TIMEOUT="$(command -v timeout)"
# Its fakes live in its own bin: written into the shared $BIN they shadowed timeout, curl, agy and kimi for
# every section after this one.
F16B="$T/f16bin"; mkdir -p "$F16B"
# One line per call: the prompt's own newlines would otherwise split the record.
cat > "$F16B/timeout" <<SHIM
#!/bin/sh
{ printf '%s' "\$*" | tr '\n' ' '; echo; } >> "$T/timeout.log"
exec "$REAL_TIMEOUT" "\$@"
SHIM
chmod +x "$F16B/timeout"
cat > "$F16B/agy" <<'AGY'
#!/bin/sh
case "$*" in
  *"PRIMARY-M"*) sleep 3; echo "context canceled" >&2; exit 1 ;;
  *) echo '{"findings": []}' ;;
esac
AGY
chmod +x "$F16B/agy"
: > "$T/timeout.log"
rc="$(LANES=agy drive f16-agy PATH="$F16B:$BIN:$PATH" ZUVO_REVIEW_TIMEOUT=60 ZUVO_AGY_MODEL=PRIMARY-M ZUVO_AGY_FALLBACK_MODEL=FALLBACK-M -- --single)"
same "F16 agy: primary out of quota after ~3 s, fallback answers: exit 0" "0" "$rc"
f16_last="$(awk '/ agy / && /FALLBACK-M/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/ && $(i+1) == "agy") print $i }' "$T/timeout.log" | tail -1)"
# Both bounds: under the full 60 (what was LEFT), and not near zero (it is not merely small).
[ -n "$f16_last" ] && [ "$f16_last" -le 58 ] && [ "$f16_last" -ge 50 ] && ok "F16 …the fallback's timeout is what was left (${f16_last}s of 60)" \
  || bad "F16 …the fallback ran with timeout [${f16_last:-none}] — want at most 58 of the 60 s lane budget: $(cut -c1-24 "$T/timeout.log" | tr '\n' '|')"
# Too little left to be worth a call — under LANE_MIN_RETRY_SECONDS, or under half the lane's timeout when
# that is shorter (20 s of 40 here): the fallback is not started, and the lane's own stderr says so (kept as
# failure evidence: agy was the only lane, so nothing was reviewed).
cat > "$F16B/agy" <<'AGY'
#!/bin/sh
case "$*" in
  *"PRIMARY-M"*) sleep 22; echo "context canceled" >&2; exit 1 ;;
  *) echo '{"findings": []}' ;;
esac
AGY
: > "$T/timeout.log"
rc="$(LANES=agy drive f16-skip PATH="$F16B:$BIN:$PATH" ZUVO_REVIEW_TIMEOUT=40 ZUVO_AGY_MODEL=PRIMARY-M ZUVO_AGY_FALLBACK_MODEL=FALLBACK-M -- --single)"
same "F16 agy: 18 s left of 40 after the primary, under the 20 s floor — no review (exit 2)" "2" "$rc"
hasnt "F16 …and the fallback model is not started" "FALLBACK-M" "$(cut -c1-60 "$T/timeout.log"; grep -o 'model [A-Z-]*' "$T/timeout.log")"
has "F16 …which the lane says" "fallback 'FALLBACK-M' not started" "$(cat "$T"/home-f16-skip/.zuvo/adversarial-failures/*/* 2>/dev/null)"
# kimi: the CLI fails on its plan limit after ~3 s; the API lane gets what is left, not a fresh timeout.
cat > "$F16B/kimi" <<'KIMI'
#!/bin/sh
sleep 3; echo "You've reached your weekly usage limit" >&2; exit 1
KIMI
chmod +x "$F16B/kimi"
cat > "$F16B/curl" <<CURL
#!/bin/sh
printf '%s\n' "\$*" >> "$T/curl.log"
printf '%s' '{"choices":[{"message":{"content":"{\"findings\": []}"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
CURL
chmod +x "$F16B/curl"
: > "$T/curl.log"
rc="$(LANES=kimi drive f16-kimi PATH="$F16B:$BIN:$PATH" ZUVO_REVIEW_TIMEOUT=60 MOONSHOT_API_KEY=test-key -- --single)"
same "F16 kimi: CLI at its limit after ~3 s, kimi-api answers: exit 0" "0" "$rc"
f16_mt="$(awk '{ for (i = 1; i < NF; i++) if ($i == "--max-time") print $(i+1) }' "$T/curl.log" | tail -1)"
[ -n "$f16_mt" ] && [ "$f16_mt" -le 58 ] && [ "$f16_mt" -ge 50 ] && ok "F16 …kimi-api's --max-time is what was left (${f16_mt}s of 60)" \
  || bad "F16 …kimi-api ran with --max-time [${f16_mt:-none}] — want 50..58 of the 60 s lane budget"
# Too little left after the CLI: kimi-api is not started, and the lane says so.
cat > "$F16B/kimi" <<'KIMI'
#!/bin/sh
sleep 22; echo "You've reached your weekly usage limit" >&2; exit 1
KIMI
: > "$T/curl.log"
rc="$(LANES=kimi drive f16-kimi-skip PATH="$F16B:$BIN:$PATH" ZUVO_REVIEW_TIMEOUT=40 MOONSHOT_API_KEY=test-key -- --single)"
same "F16 kimi: 18 s left of 40 after the CLI, under the 20 s floor — no review (exit 2)" "2" "$rc"
same "F16 …kimi-api is not called" "" "$(cat "$T/curl.log")"
has "F16 …which the lane says" "kimi-api fallback not started" "$(cat "$T"/home-f16-kimi-skip/.zuvo/adversarial-failures/*/* 2>/dev/null)"
fi

if only F14; then
echo "=== F14 stdin is read to its end, however slowly it arrives (CQ8) ==="
# `timeout 10 cat` capped the WHOLE read at 10 s: a producer still writing then (a big git diff, a slow
# pipeline) was cut off mid-diff, the 124 swallowed, and half a change was reviewed as all of it.
mkfifo "$T/f14-slow.fifo"
{ printf 'diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n@@ -1 +1 @@\n-const a = 1;\n+const a = 2;\n'
  sleep 12
  printf 'diff --git a/b.js b/b.js\n--- a/b.js\n+++ b/b.js\n@@ -1 +1 @@\n-const b = 1;\n+const b = 2;\n'; } > "$T/f14-slow.fifo" &
rc="$(STDIN_FILE="$T/f14-slow.fifo" drive f14-slow -- --dry-run)"
wait
same "F14 a producer that pauses 12 s mid-diff: dry run exit 0" "0" "$rc"
has "F14 …and the part written after the pause reaches the prompt" "+const b = 2;" "$(out f14-slow)"
# A producer that never closes stdin must not hang the review, nor be reviewed in part: it is refused.
mkfifo "$T/f14-open.fifo"
{ printf '%s' "$DIFF"; exec sleep 30; } > "$T/f14-open.fifo" &   # exec: the PID killed below IS the sleep
f14_writer=$!
f14_t0=$(date +%s)
rc="$(STDIN_FILE="$T/f14-open.fifo" drive f14-open ZUVO_STDIN_TIMEOUT=3 -- --dry-run)"
f14_el=$(( $(date +%s) - f14_t0 ))
kill "$f14_writer" 2>/dev/null; wait 2>/dev/null
same "F14 stdin that does not end within ZUVO_STDIN_TIMEOUT: exit 2" "2" "$rc"
has "F14 …saying it did not end" "did not end" "$(err f14-open)"
[ "$f14_el" -lt 15 ] && ok "F14 …after the timeout, not the writer's 30 s (${f14_el}s)" || bad "F14 …took ${f14_el}s"
# Nothing at all: the wait for the first byte is ZUVO_STDIN_WAIT, then the usual "No input provided".
mkfifo "$T/f14-none.fifo"
{ exec sleep 20; } > "$T/f14-none.fifo" &
f14_writer=$!
f14_t0=$(date +%s)
rc="$(STDIN_FILE="$T/f14-none.fifo" drive f14-none ZUVO_STDIN_WAIT=1 -- --dry-run)"
f14_el=$(( $(date +%s) - f14_t0 ))
kill "$f14_writer" 2>/dev/null; wait 2>/dev/null
same "F14 nothing on stdin: exit 2" "2" "$rc"
has "F14 …No input provided" "No input provided" "$(err f14-none)"
[ "$f14_el" -lt 6 ] && ok "F14 …after ZUVO_STDIN_WAIT (1 s), not 10 s (${f14_el}s)" || bad "F14 …took ${f14_el}s"
fi

if only F20; then
echo "=== F20 --list-providers is not a --mode plan review round (CQ21) ==="
# The plan circuit-breaker counted every --mode plan invocation that was not --dry-run or --doctor —
# --list-providers included, though it asks no provider anything. A chunked plan's children and test
# suites list providers in plan mode, and those listings used up the budget real plan reviews need.
rc="$(drive f20 -- --mode plan --list-providers)"
same "F20 --mode plan --list-providers: exit 0" "0" "$rc"
same "F20 …and it adds nothing to the plan budget" "0" "$(cat "$T/home-f20/.zuvo/plan-budget/"* 2>/dev/null | wc -l | tr -d ' ')"
# Anchor: in the same home a real plan review IS counted — the zero above is not a budget that moved away.
PLAN="$T/f20-plan.md"
{ printf '# Plan\n\n'; for i in 1 2 3 4; do printf '### Task %d: step %d\n\nDo the thing number %d.\n\n' "$i" "$i" "$i"; done; } > "$PLAN"
rc="$(STDIN_FILE="$PLAN" drive f20 -- --mode plan --single)"
same "F20 anchor: a plan review in the same home is counted (1)" "1" "$(cat "$T/home-f20/.zuvo/plan-budget/"* 2>/dev/null | wc -l | tr -d ' ')"
fi

if only M2; then
echo "=== M2 the stamp wait is a number like every other knob, and a skipped set is reported ==="
. "$ROOT/tests/lib/adversarial-driver.sh"
# shellcheck disable=SC2046  # module names, one word each: split on purpose
m2_sum() {   # <module dir> — as m1_sum: the driver beside the set, then its modules
  local drv="$1/adversarial-review.sh"
  [ -f "$drv" ] || drv="${1%/*}/adversarial-review.sh"
  { cat "$drv"; ( cd "$1" && cat $(adv_driver_modules "$AR") ); } | cksum
}
m2_run() {    # <tag> <driver> [VAR=value...] — a dry run; prints the exit code
  local tag="$1" drv="$2" rc=0; shift 2
  mkdir -p "$T/home-$tag/.zuvo"
  ( cd "$REPO" && env HOME="$T/home-$tag" ZUVO_HOME="$T/home-$tag/.zuvo" TMPDIR="$T/tmp" PATH="$BIN:$PATH" \
      ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-ok "$@" \
      bash "$drv" --dry-run <<< "$DIFF" ) > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  echo "$rc"
}
# ZUVO_ADV_MODULE_STAMP_WAIT=08 passed a digits-only check and then died in $(( 08 * 2 )) — an octal
# error that abandoned the loader's loop, so EVERY stamped install refused to run ("Reinstall zuvo").
rm -rf "$T/m2-oct"; adv_driver_copy "$AR" "$T/m2-oct/adversarial-review.sh" lib || bad "M2 premise: copy failed"
m2_sum "$T/m2-oct/lib" > "$T/m2-oct/lib/adversarial-modules.cksum"
same "M2 ZUVO_ADV_MODULE_STAMP_WAIT=08 on a stamped set: the review runs (exit 0)" "0" \
  "$(m2_run m2-oct "$T/m2-oct/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=08)"
hasnt "M2 …with no arithmetic error" "value too great" "$(err m2-oct)"
# A lib/ set skipped for its stamp, the flat set used: one NOTE says which and why (the run paid the wait).
rm -rf "$T/m2-note"; adv_driver_copy "$AR" "$T/m2-note/adversarial-review.sh" lib || bad "M2 premise: copy failed"
m2_sum "$T/m2-note/lib" > "$T/m2-note/lib/adversarial-modules.cksum"
printf '\n# from another release\n' >> "$T/m2-note/lib/$(adv_driver_modules "$AR" | tail -1)"
for m in $(adv_driver_modules "$AR"); do cp "$(adv_driver_module_dir "$AR")/$m" "$T/m2-note/$m"; done
m2_sum "$T/m2-note" > "$T/m2-note/adversarial-modules.cksum"
same "M2 lib/ out of step, flat set stamped: the review runs (exit 0)" "0" \
  "$(m2_run m2-note "$T/m2-note/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=1)"
has "M2 …and a NOTE names the skipped set" "skipped $T/m2-note/lib/" "$(err m2-note)"
fi

if only F21; then
echo "=== F21 --single and a chunked review stop at once on TERM, clients and children included (CQ35) ==="
# F11 covered --multi. In --single the lane ran inside $( ), where bash holds a trap until the command
# substitution returns: a TERM waited out the whole lane (up to its timeout), and a KILL then orphaned the
# client. A chunked review's parent had only an EXIT trap: TERM removed the chunk dir and left the child
# review running with PPID 1.
cat > "$BIN/mock-sleeper21" <<EOF2
#!/bin/sh
cat > /dev/null
echo \$\$ >> "$T/sleeper21.pid"
exec sleep 300
EOF2
chmod +x "$BIN/mock-sleeper21"
# f21_run <tag> <stdin file> <args…> — start the driver in the background, wait for a lane client, TERM the
# driver; prints "<rc> <seconds from TERM to exit> <client still alive 0|1>".
f21_run() {
  local tag="$1" input="$2" drv sleeper t0 rc alive; shift 2
  rm -f "$T/sleeper21.pid"; mkdir -p "$T/home-$tag/.zuvo"
  ( cd "$REPO" && exec env HOME="$T/home-$tag" ZUVO_HOME="$T/home-$tag/.zuvo" TMPDIR="$T/tmp" PATH="$BIN:$PATH" \
      ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="mock-sleeper21" \
      ZUVO_RUN_ID="hardening-$tag-$$" bash "$AR" "$@" < "$input" > "$T/$tag.out" 2> "$T/$tag.err" ) &
  drv=$!
  for _ in $(seq 1 150); do [ -s "$T/sleeper21.pid" ] && break; sleep 0.1; done
  sleeper="$(head -1 "$T/sleeper21.pid" 2>/dev/null)"
  [ -n "$sleeper" ] || { kill -TERM "$drv" 2>/dev/null; wait "$drv" 2>/dev/null; echo "nolane 0 0"; return; }
  t0=$(date +%s); kill -TERM "$drv"; wait "$drv"; rc=$?
  alive=1; for _ in $(seq 1 30); do kill -0 "$sleeper" 2>/dev/null || { alive=0; break; }; sleep 0.1; done
  [ "$alive" -eq 0 ] || kill -9 "$sleeper" 2>/dev/null
  echo "$rc $(( $(date +%s) - t0 )) $alive"
}
printf '%s' "$DIFF" > "$T/f21-diff.txt"
read -r rc secs alive <<< "$(f21_run f21-single "$T/f21-diff.txt" --single)"
same "F21 --single: TERM while the lane runs → exit 143" "143" "$rc"
[ "$secs" != "" ] && [ "$secs" -le 5 ] 2>/dev/null && ok "F21 …at once (${secs}s), not after the lane's timeout" || bad "F21 …only after ${secs}s"
same "F21 …and the lane's client is gone" "0" "$alive"
# A chunked review: two files over a small cap, so the parent runs each chunk as a child review.
{ for n in one two; do
    printf 'diff --git a/%s.js b/%s.js\n--- a/%s.js\n+++ b/%s.js\n@@ -1,40 +1,40 @@\n' "$n" "$n" "$n" "$n"
    for i in $(seq 1 40); do printf '+const %s_%d = %d; // a line long enough to fill the cap\n' "$n" "$i" "$i"; done
  done; } > "$T/f21-chunks.txt"
export ZUVO_ADV_MAX_CHARS=2000
read -r rc secs alive <<< "$(f21_run f21-chunk "$T/f21-chunks.txt" --single)"
unset ZUVO_ADV_MAX_CHARS
same "F21 chunked review: TERM to the parent while a child's lane runs → exit 143" "143" "$rc"
[ "$secs" != "" ] && [ "$secs" -le 5 ] 2>/dev/null && ok "F21 …at once (${secs}s)" || bad "F21 …only after ${secs}s"
same "F21 …and the child's lane client is gone" "0" "$alive"
# Any copy of THIS driver still running is the orphaned child (the test runs nothing else meanwhile).
f21_left=1; for _ in $(seq 1 30); do pgrep -f "$AR" >/dev/null 2>&1 || { f21_left=0; break; }; sleep 0.1; done
same "F21 …and no child review of it is left running" "0" "$f21_left"
has "F21 premise: the review really was chunked" "CHUNKED INPUT" "$(err f21-chunk)"
fi

if only F22; then
echo "=== F22 knobs and homes the driver cannot use are refused or warned about, never a silent exit (CQ3, CQ8) ==="
# An unwritable ZUVO_HOME (the host class the run-log fallback exists for) ended every --mode plan review at
# the budget check: awk on a missing file, pipefail, exit 2 before any provider was asked.
PLAN="$T/f22-plan.md"
{ printf '# Plan\n\n'; for i in 1 2 3 4; do printf '### Task %d: step %d\n\nDo the thing number %d.\n\n' "$i" "$i" "$i"; done; } > "$PLAN"
rc="$(STDIN_FILE="$PLAN" drive f22-plan ZUVO_HOME=/dev/null/zuvo-home -- --mode plan --single)"
same "F22 --mode plan with an unwritable ZUVO_HOME: the review runs (exit 0)" "0" "$rc"
has "F22 …and says the pass was not counted" "plan budget cannot be recorded" "$(err f22-plan)"
# ZUVO_REVIEW_MAX_PROVIDERS=09 failed both [[ ]] tests as an octal error: no WARN, and no cap — every lane ran.
for n in 1 2 3 4 5 6 7 8 9 10; do mock "mock-cap$n" 'printf "%s\n" "{\"findings\": []}"'; done
f22_lanes="mock-cap1 mock-cap2 mock-cap3 mock-cap4 mock-cap5 mock-cap6 mock-cap7 mock-cap8 mock-cap9 mock-cap10"
rc="$(LANES="$f22_lanes" drive f22-cap ZUVO_REVIEW_MAX_PROVIDERS=09 -- --multi --dry-run)"
same "F22 ZUVO_REVIEW_MAX_PROVIDERS=09: the dry run exits 0" "0" "$rc"
same "F22 …and caps the fan-out at 9 of 10 lanes" "9" "$(sed -n 's/^Providers: //p' "$T/f22-cap.err" "$T/f22-cap.out" | head -1 | sed 's/ *(.*//' | wc -w | tr -d ' ')"
hasnt "F22 …with no arithmetic error" "value too great" "$(err f22-cap)"
# A timeout of 0 is `timeout 0` — no limit at all.
rc="$(drive f22-t0 ZUVO_REVIEW_TIMEOUT=0 -- --single --dry-run)"
same "F22 ZUVO_REVIEW_TIMEOUT=0: the dry run exits 0" "0" "$rc"
hasnt "F22 …and does not run with no limit" "Timeout: 0s" "$(out f22-t0; err f22-t0)"
has "F22 …which a WARN says" "below its minimum" "$(err f22-t0)"
fi

if only F23; then
echo "=== F23 a lock is broken only when its holder is gone; --append-artifact appends under it (CQ21) ==="
# The F8 lock was broken by AGE: a run that held it longer than the limit lost it to a waiter while still
# writing, and a lock left by a run that had just died blocked everybody for the whole limit. It now holds
# its holder's pid: broken at once when that pid is dead, never while it is alive.
f23_dead="$(sh -c 'echo $$')"
HF="$T/f23-health.tsv"; : > "$HF"
mkdir "$HF.lock"; echo "$$" > "$HF.lock/pid"; touch -t 202001010000 "$HF.lock"
rc="$(drive f23-live ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_PROVIDER_HEALTH_LOCK_WAIT=1 -- --single)"
same "F23 health lock held by a LIVE run, however old: the review succeeds (exit 0)" "0" "$rc"
same "F23 …and the lock is not taken from it — the ledger is untouched" "" "$(cat "$HF")"
same "F23 …and the holder still holds it" "$$" "$(cat "$HF.lock/pid" 2>/dev/null)"
rm -rf "$HF.lock"
mkdir "$HF.lock"; echo "$f23_dead" > "$HF.lock/pid"
rc="$(drive f23-dead ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_PROVIDER_HEALTH_LOCK_WAIT=1 -- --single)"
same "F23 health lock left by a DEAD run a moment ago: exit 0" "0" "$rc"
has "F23 …is broken at once, and the row is written" "mock-ok	" "$(cat "$HF")"
[ -e "$HF.lock" ] && bad "F23 …but a lock was left behind" || ok "F23 …and released"
rm -rf "$HF.lock"

# --append-artifact read the artifact, appended its pass and mv'd the result over it with no lock: of two
# runs appending at once (parallel rotation passes) the later mv erased the earlier pass — and its proof.
ART="$T/f23-art/proof.txt"; mkdir -p "$T/f23-art"; printf 'SEED PASS\n' > "$ART"
mkdir "$ART.lock"; echo "$$" > "$ART.lock/pid"
rc="$(drive f23-held ZUVO_ARTIFACT_LOCK_WAIT=1 -- --single --artifact "$ART" --append-artifact)"
# (A pass that does not land fails the run, exit 2 — the artifact a gate reads lacks it; F32, p6.)
same "F23 artifact lock held by another run: the run fails (exit 2), the pass kept" "2" "$rc"
same "F23 …the artifact is not written over" "SEED PASS" "$(cat "$ART")"
f23_kept="$(ls "$ART".pass-* 2>/dev/null | head -1)"
[ -n "$f23_kept" ] && ok "F23 …the pass is kept beside it" || bad "F23 …the pass is kept beside it — no $ART.pass-*"
has "F23 …which a WARN names" "kept as $ART.pass-" "$(err f23-held)"
rm -rf "$ART.lock" "$ART".pass-*
for k in 1 2 3 4; do
  drive "f23-par$k" -- --single --artifact "$ART" --append-artifact > "$T/f23-par$k.rc" &
done
wait
same "F23 four runs appending at once: all exit 0" "0000" "$(cat "$T"/f23-par[1-4].rc | tr -d '\n')"
same "F23 …and all four passes are in the artifact" "4" "$(grep -c '^=== APPENDED PASS' "$ART")"
has "F23 …after the seed" "SEED PASS" "$(head -1 "$ART")"
[ -e "$ART.lock" ] && bad "F23 …but the lock was left behind" || ok "F23 …and the lock is released"
# An artifact that cannot be read: the merge's status was its last `cat`'s, so the artifact was replaced
# by this pass alone. (Root reads a mode-000 file, so the case needs a non-root run.)
printf 'SEED PASS\n' > "$ART"; chmod 000 "$ART"
if [ -r "$ART" ]; then
  echo "  SKIP F23 unreadable artifact: running as root"
else
  rc="$(drive f23-unread -- --single --artifact "$ART" --append-artifact)"
  chmod 644 "$ART"
  same "F23 artifact that cannot be read: the run fails (exit 2), the pass kept" "2" "$rc"
  same "F23 …the passes in it are not written over" "SEED PASS" "$(cat "$ART")"
  has "F23 …and a WARN says where this pass went" "kept as $ART.pass-" "$(err f23-unread)"
fi
chmod 644 "$ART"; rm -f "$ART".pass-*

# The lock itself: a waiter does not break a dead holder's lock while another waiter is breaking it, and a
# run releases only a lock it holds.
. "$ROOT/tests/lib/adversarial-driver.sh"
L="$T/f23-unit.lock"
f23_unit() {    # runs "$@" with the ledger module loaded; prints its status
  ( . "$(adv_driver_module_dir "$AR")/adversarial-ledger.sh" >/dev/null 2>&1 || exit 99
    "$@" ) >/dev/null 2>&1
  echo "$?"
}
mkdir "$L" "$L.break"; echo "$f23_dead" > "$L/pid"
same "F23 dead holder, another waiter breaking it (.break): not taken" "1" "$(f23_unit _ar_lock "$L" 1)"
same "F23 …and the lock is the dead holder's still" "$f23_dead" "$(cat "$L/pid" 2>/dev/null)"
touch -t 202001010000 "$L.break"
same "F23 a .break left by a killed breaker is cleared: the lock is taken" "0" "$(f23_unit _ar_lock "$L" 1)"
[ -e "$L.break" ] && bad "F23 …and .break is gone" || ok "F23 …and .break is gone"
# (Not $$: in the module's subshell $$ is still this shell's pid — the lock would be "ours".)
rm -rf "$L"; mkdir "$L"; echo "$PPID" > "$L/pid"
same "F23 _ar_unlock of a lock another run holds: status 0" "0" "$(f23_unit _ar_unlock "$L")"
same "F23 …and the lock stays that run's" "$PPID" "$(cat "$L/pid" 2>/dev/null)"
rm -rf "$L" "$L.break"
fi

if only F24; then
echo "=== F24 a lane sends the model its label names, or refuses — it never repairs the id (CQ20) ==="
# codestral, kimi-api, qwen and the kimi CLI ran `tr -cd` over the configured id and sent what was left
# under the label of the id as configured: 'codestral latest' ran as 'codestrallatest' while the run log,
# the health ledger and the artifact named the other. The openrouter lane already refused instead.
F24="$T/f24-bin"; mkdir -p "$F24"
cat > "$F24/curl" <<EOF
#!/bin/sh
: > "$T/f24.called"
for a in "\$@"; do case "\$a" in @*) cat "\${a#@}" > "$T/f24.payload" ;; esac; done
printf '%s' '{"choices":[{"message":{"content":"NO ISSUES FOUND."}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
for a in "\$@"; do [ "\$a" = "-w" ] && printf '\n200'; done   # the openrouter lane asks for the status code
exit 0
EOF
cat > "$F24/cursor-agent" <<EOF
#!/bin/sh
: > "$T/f24.called"; printf '%s\n' "\$@" > "$T/f24.argv"; cat > /dev/null
printf '%s\n' 'NO ISSUES FOUND.'
EOF
chmod +x "$F24/curl" "$F24/cursor-agent"
f24_model() { jq -r '.model' "$T/f24.payload" 2>/dev/null; }
rm -f "$T/f24.called" "$T/f24.payload"
rc="$(drive f24-cs-bad PATH="$F24:$BIN:$PATH" CODESTRAL_API_KEY=k ZUVO_CODESTRAL_MODEL='codestral latest' -- --provider codestral)"
[ "$rc" != 0 ] && ok "F24 codestral, id with a space: no review (exit $rc)" || bad "F24 codestral, id with a space: no review — got exit 0"
[ -e "$T/f24.called" ] && bad "F24 …and no request is sent — it was, as model '$(f24_model)'" || ok "F24 …and no request is sent"
has "F24 …the driver says why, in the lane's words" "failed or returned empty: codestral model id 'codestral latest'" "$(err f24-cs-bad)"
rm -f "$T/f24.called" "$T/f24.payload"
rc="$(drive f24-cs-ok PATH="$F24:$BIN:$PATH" CODESTRAL_API_KEY=k ZUVO_CODESTRAL_MODEL='mistral/codestral:2508' -- --provider codestral)"
same "F24 codestral, a well-formed vendor/name:tag id: exit 0" "0" "$rc"
same "F24 …sent exactly as configured, not with / and : deleted" "mistral/codestral:2508" "$(f24_model)"
rm -f "$T/f24.called" "$T/f24.payload"
rc="$(drive f24-ka-bad PATH="$F24:$BIN:$PATH" MOONSHOT_API_KEY=k ZUVO_KIMI_MODEL='kimi-k2.6"' -- --provider kimi-api)"
[ -e "$T/f24.called" ] && bad "F24 kimi-api, id with a quote: refused — it was sent as '$(f24_model)'" || ok "F24 kimi-api, id with a quote: refused, no request"
has "F24 …said in a WARN" "kimi-api model id" "$(err f24-ka-bad)"
rm -f "$T/f24.called" "$T/f24.argv"
rc="$(drive f24-cur-flag PATH="$F24:$BIN:$PATH" ZUVO_CURSOR_MODEL='--trust' -- --provider cursor-agent)"
[ -e "$T/f24.called" ] && bad "F24 cursor-agent, a flag-like id: refused — cursor-agent ran with: $(tr '\n' ' ' < "$T/f24.argv")" || ok "F24 cursor-agent, a flag-like id: refused, the client never runs"
has "F24 …said in a WARN" "cursor-agent model id '--trust'" "$(err f24-cur-flag)"
# The router takes the model from lane_model, the same function the label comes from.
rm -f "$T/f24.called" "$T/f24.payload"
rc="$(drive f24-or-alt PATH="$F24:$BIN:$PATH" OPENROUTER_API_KEY=k ZUVO_MODEL_OPENROUTER_ALT='vendor/alt-model' -- --provider openrouter-alt --json)"
same "F24 openrouter-alt: exit 0" "0" "$rc"
same "F24 …requests the model its label reports" "vendor/alt-model" "$(f24_model)"
same "F24 …which --json reports for the lane" "vendor/alt-model" "$(out f24-or-alt | jq -r '.models["openrouter-alt"] // empty' 2>/dev/null)"
fi

if only F25; then
echo "=== F25 an answer with no text is no review; the JSON document never drops answers silently (CQ8) ==="
# A lane that printed only blank lines exited 0 with a non-empty file, and was recorded `ok`: a clean
# review, REVIEW BY: in the artifact the push gate reads, for an answer that said nothing.
mock mock-blank 'printf "  \n\n   \n"'
ART="$T/f25-art.txt"
rc="$(LANES=mock-blank drive f25-blank1 -- --single --artifact "$ART")"
[ "$rc" != 0 ] && ok "F25 the only lane answered blank lines: no review (exit $rc)" || bad "F25 the only lane answered blank lines: no review — got exit 0"
hasnt "F25 …and the artifact names no reviewer" "REVIEW BY: MOCK-BLANK" "$(cat "$ART" 2>/dev/null)"
has "F25 …the lane is reported as returning nothing" "mock-blank failed or returned empty" "$(err f25-blank1)"
rc="$(LANES="mock-blank mock-ok" drive f25-blank2 -- --multi --json)"
same "F25 a blank lane beside a real one: exit 0" "0" "$rc"
same "F25 …its outcome is empty, the other's ok" "mock-blank:empty,mock-ok:ok" \
  "$(out f25-blank2 | jq -r '.provider_outcomes | split(",") | sort | join(",")' 2>/dev/null)"
same "F25 …and only the real answer counts" "1" "$(out f25-blank2 | jq -r '.provider_count' 2>/dev/null)"
# A jq that failed while the results object was built left an empty .next, which the unconditional mv
# put in place: "results": null with status ok, every lane's answer gone and nothing said.
F25B="$T/f25-bin"; mkdir -p "$F25B"
cat > "$F25B/jq" <<EOF
#!/bin/sh
case " \$* " in *" --arg k mock-ok2 "*) exit 5 ;; esac
exec "$(command -v jq)" "\$@"
EOF
chmod +x "$F25B/jq"
mock mock-ok2 'printf "%s\n" "{\"findings\": []}"'
rc="$(LANES="mock-ok mock-ok2" drive f25-jq PATH="$F25B:$BIN:$PATH" -- --multi --json)"
same "F25 jq fails on one lane's answer: exit 0" "0" "$rc"
same "F25 …the other lane's answer is still in the document" "true" "$(out f25-jq | jq -r '.results | has("mock-ok")' 2>/dev/null)"
same "F25 …the status says the document is incomplete" "partial" "$(out f25-jq | jq -r '.status' 2>/dev/null)"
has "F25 …and a WARN names the lane left out" "leaves out the answer of: mock-ok2" "$(err f25-jq)"
# The clean-pass META warning counted lines with wc -l, one short when the input ends without a newline
# ($(cat) strips it): a diff one line over META_CLEAN_LINES never got the warning.
f25_diff="$T/f25-151.diff"
{ printf 'diff --git a/b.js b/b.js\n--- a/b.js\n+++ b/b.js\n@@ -0,0 +1,147 @@\n'
  i=1; while [ "$i" -le 147 ]; do printf '+const v%d = %d;\n' "$i" "$i"; i=$((i + 1)); done; } > "$f25_diff"
mock mock-clean 'printf "%s\n" "NO ISSUES FOUND."'
rc="$(LANES=mock-clean STDIN_FILE="$f25_diff" drive f25-meta -- --single --json)"
same "F25 a 151-line diff passed clean: exit 0" "0" "$rc"
has "F25 …gets the clean-pass META warning (151 > 150 lines)" "Clean pass on 151-line diff" "$(err f25-meta)"
fi

if only F26; then
echo "=== F26 quotes are terminal-safe and named right; a dated cache entry from the future expires; nothing is left in TMPDIR (CQ8, CQ12) ==="
# An auth-cache entry dated after "now" (written before the clock was set back) passed `now - t < ttl`
# with a negative age, and kept the lane out for however far the clock had moved.
CACHE_DIR="$T/tmp/zuvo-adv-$(id -u)"; mkdir -p "$CACHE_DIR"; chmod 700 "$CACHE_DIR"
mock mock-ok2 'printf "%s\n" "{\"findings\": []}"'
printf 'mock-ok\t%s\n' "$(( $(date +%s) + 30 * 86400 ))" > "$CACHE_DIR/failed-providers.hardening-f26-future-$$"
rc="$(LANES="mock-ok mock-ok2" drive f26-future -- --multi)"
same "F26 a cache entry dated 30 days ahead: exit 0" "0" "$rc"
hasnt "F26 …does not exclude the lane" "auth failed earlier this run): mock-ok" "$(err f26-future)"
# The doctor quoted a probe's stderr with `head -c 160` — a client's terminal escapes went straight to the
# user's terminal. Every quote of client output now goes through one cleaner.
mock mock-esc 'printf "\033[31mauth expired\033[0m\n" >&2; exit 1'
rc="$(LANES=mock-esc drive f26-doc -- --doctor)"
has "F26 --doctor quotes the failing probe's stderr" "auth expired" "$(out f26-doc)"
case "$(out f26-doc)" in *$'\033'*) bad "F26 …without its terminal escapes — an ESC reached the output" ;; *) ok "F26 …without its terminal escapes" ;; esac
# A BytePlus lane's HTTP error said "openrouter HTTP 401": the shared client named the wrong lane.
F26B="$T/f26-bin"; mkdir -p "$F26B"
cat > "$F26B/curl" <<'EOF'
#!/bin/sh
printf '%s' 'Unauthorized'
for a in "$@"; do [ "$a" = "-w" ] && printf '\n401'; done
exit 0
EOF
chmod +x "$F26B/curl"
printf 'bp-key\n' > "$T/f26-bp.key"; chmod 600 "$T/f26-bp.key"
rc="$(drive f26-bp PATH="$F26B:$BIN:$PATH" ZUVO_ADV_BYTEPLUS=1 ZUVO_BYTEPLUS_KEY_FILE="$T/f26-bp.key" -- --provider byteplus)"
has "F26 a BytePlus lane's HTTP error names the lane that failed" "byteplus HTTP 401: Unauthorized" "$(err f26-bp)"
hasnt "F26 …not openrouter" "openrouter HTTP" "$(err f26-bp)"
# With ZUVO_HOME unwritable and the per-user temp dir not ours, the run used a fresh mktemp dir for the
# auth cache and another for the run log — neither ever removed, every reviewed diff left in $TMPDIR.
f26_cd="$T/tmp/zuvo-adv-$(id -u)"
mv "$f26_cd" "$f26_cd.f26-saved"; : > "$f26_cd"
f26_before="$(ls -A "$T/tmp" | LC_ALL=C sort | tr '\n' ' ')"
rc="$(drive f26-orphan ZUVO_HOME=/dev/null/zuvo-home -- --single)"
f26_after="$(ls -A "$T/tmp" | LC_ALL=C sort | tr '\n' ' ')"
rm -f "$f26_cd"; mv "$f26_cd.f26-saved" "$f26_cd"
same "F26 no private dir for the log or the cache: the review runs (exit 0)" "0" "$rc"
same "F26 …and leaves nothing behind in TMPDIR" "$f26_before" "$f26_after"
has "F26 …says the auth-failure cache is off" "auth-failure cache is off" "$(err f26-orphan)"
has "F26 …and that this run's log is not kept" "this run's log is not kept" "$(err f26-orphan)"
fi

if only F27; then
echo "=== F27 the second cross-model pass: stamp, flags, locks, stdin, keys, codex's ledger row, shared hosts (CQ3, CQ6, CQ8, CQ14, CQ21) ==="
. "$ROOT/tests/lib/adversarial-driver.sh"
# A stamp that summed the modules alone matched a set whose DRIVER was not the one it was written with: an
# install writes the modules (and their stamp) before the driver, and a review starting in between ran the
# old bootstrap with new modules — which may call bootstrap functions the old one lacks.
# The stamp is written by THIS tree's installer (install_adv_module_stamp, sourced): the test asks whether
# the loader beside it notices a driver changed after the stamp, whatever that installer sums.
f27_run() {   # <tag> — the copied driver, dry run; prints its exit code
  local rc=0
  mkdir -p "$T/home-$1/.zuvo"
  ( cd "$REPO" && env HOME="$T/home-$1" ZUVO_HOME="$T/home-$1/.zuvo" TMPDIR="$T/tmp" PATH="$BIN:$PATH" \
      ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-ok ZUVO_ADV_MODULE_STAMP_WAIT=1 \
      bash "$T/f27-drv/adversarial-review.sh" --single --dry-run <<< "$DIFF" ) > "$T/$1.out" 2> "$T/$1.err" || rc=$?
  echo "$rc"
}
rm -rf "$T/f27-drv"; adv_driver_copy "$AR" "$T/f27-drv/adversarial-review.sh" lib || bad "F27 premise: copy failed"
# A sandbox HOME: sourcing install.sh checks the commit installed in HOME and refuses a "downgrade".
mkdir -p "$T/home-f27-inst"
( export HOME="$T/home-f27-inst"; . "${AR%/*}/install.sh" >/dev/null 2>&1
  install_adv_module_stamp f27 "$T/f27-drv/lib" "$T/f27-drv/lib" 1 ) >/dev/null 2>&1
[ -s "$T/f27-drv/lib/adversarial-modules.cksum" ] && ok "F27 premise: the tree's installer stamped the set" \
  || bad "F27 premise: the tree's installer wrote no stamp — the case proves nothing"
same "F27 premise: the set as stamped runs (exit 0)" "0" "$(f27_run f27-drv-ok)"
printf '\n# a newer driver, installed after its modules\n' >> "$T/f27-drv/adversarial-review.sh"
same "F27 a driver other than the one its set was stamped with: refused (exit 2)" "2" "$(f27_run f27-drv-new)"

# A value starting with one '-' is a value — refusing every `-*` turned --context "-WIP spike" into a usage
# error; only the next FLAG (`--…`) is refused, and for --diff any '-' (git reads it as an option).
rc="$(drive f27-ctx -- --single --dry-run --context "-WIP spike")"
same "F27 --context with a value starting with '-': accepted (exit 0)" "0" "$rc"
rc="$(drive f27-diff -- --single --dry-run --diff -x)"
same "F27 --diff with a value starting with '-': refused (exit 2)" "2" "$rc"
rc="$(drive f27-excl -- --single --dry-run --exclude --json)"
same "F27 --exclude followed by a flag: refused (exit 2)" "2" "$rc"
rc="$(drive f27-excl-empty -- --single --dry-run --exclude "")"
same "F27 --exclude \"\": still a no-op (exit 0)" "0" "$rc"

f27_unit() {    # <module> <command…> — the command with that module loaded, in a subshell; prints its stdout
  local m="$1"; shift
  ( . "$(adv_driver_module_dir "$AR")/$m" >/dev/null 2>&1 || exit 99; "$@" ) 2>/dev/null
}
# lanes_filter split its lists on whatever IFS its caller had: under IFS=, "a b c" was one word.
# (IFS set after the module is loaded: the test's own helpers split on it too.)
same "F27 lanes_filter keeps a lane under a caller's IFS=," "b" \
  "$( . "$(adv_driver_module_dir "$AR")/adversarial-providers.sh" >/dev/null 2>&1; IFS=,; lanes_filter keep "a b c" "b" )"
# A lock whose directory cannot be written is not "held by another run": it is refused at once.
f27_t0=$SECONDS
rc="$(drive f27-lockdir ZUVO_PROVIDER_HEALTH_FILE=/dev/null/f27/health.tsv ZUVO_PROVIDER_HEALTH_LOCK_WAIT=6 -- --single)"
same "F27 provider-health ledger in a directory that cannot be written: exit 0" "0" "$rc"
[ $(( SECONDS - f27_t0 )) -lt 6 ] && ok "F27 …without waiting out the lock wait" || bad "F27 …without waiting out the lock wait — took $(( SECONDS - f27_t0 ))s"
has "F27 …and the WARN says why" "cannot be written" "$(err f27-lockdir)"
# ledger_header writes a fresh file's header under the file's lock: with the lock held by a live run it
# leaves the header to that run (two runs on one fresh file each appended one).
L="$T/f27-ledger.log"; : > "$L"; mkdir "$L.lock"; echo "$PPID" > "$L.lock/pid"
f27_unit adversarial-ledger.sh ledger_header "$L" "date	run" >/dev/null
same "F27 ledger_header with the file's lock held elsewhere: no header written" "" "$(cat "$L")"
rm -rf "$L.lock"
f27_unit adversarial-ledger.sh ledger_header "$L" "date	run" >/dev/null
same "F27 …and with the lock free: the header" "date	run" "$(cat "$L")"

# A request that could not be built was sent anyway, as an empty body.
F27B="$T/f27-bin"; mkdir -p "$F27B"
cat > "$F27B/jq" <<EOF
#!/bin/sh
case " \$* " in *" -Rs "*) exit 3 ;; esac
exec "$(command -v jq)" "\$@"
EOF
cat > "$F27B/curl" <<EOF
#!/bin/sh
: > "$T/f27.curl"
printf '%s' '{"choices":[{"message":{"content":"NO ISSUES FOUND."}}]}'
EOF
chmod +x "$F27B/jq" "$F27B/curl"
rm -f "$T/f27.curl"
rc="$(drive f27-payload PATH="$F27B:$BIN:$PATH" CODESTRAL_API_KEY=k -- --provider codestral)"
[ -e "$T/f27.curl" ] && bad "F27 a request jq could not build: not sent — curl was called" || ok "F27 a request jq could not build: not sent"
has "F27 …and the driver says why" "the request could not be built" "$(err f27-payload)"

# A first byte slower than ZUVO_STDIN_WAIT was "no input", with nothing said.
# The writer opens the fifo FIRST (so the driver's open returns) and writes 3 s later.
mkfifo "$T/f27.fifo"
( exec 3> "$T/f27.fifo"; sleep 3; printf '%s' "$DIFF" >&3 ) 2>/dev/null &
f27_w=$!
rc="$(STDIN_FILE="$T/f27.fifo" drive f27-slow ZUVO_STDIN_WAIT=1 -- --single --dry-run)"
wait "$f27_w" 2>/dev/null
has "F27 stdin whose first byte comes after ZUVO_STDIN_WAIT: the run says so" "no input arrived on stdin within 1s" "$(err f27-slow)"

# With no hash tool, the plan budget's key was the repository path's FIRST 16 characters: every repository
# under one parent shared one budget.
mkdir -p "$T/nohash"
for t in shasum sha1sum cksum; do printf '#!/bin/sh\nexit 127\n' > "$T/nohash/$t"; chmod +x "$T/nohash/$t"; done
PLAN="$T/f27-plan.md"
{ printf '# Plan\n\n'; for i in 1 2 3 4; do printf '### Task %d: step %d\n\nDo the thing number %d.\n\n' "$i" "$i" "$i"; done; } > "$PLAN"
for r in a b; do
  mkdir -p "$T/f27-repo-$r"; ( cd "$T/f27-repo-$r" && git init -q . ) >/dev/null 2>&1
  REPO="$T/f27-repo-$r" STDIN_FILE="$PLAN" drive "f27-key-$r" PATH="$T/nohash:$BIN:$PATH" ZUVO_HOME="$T/f27-home" -- --mode plan --single >/dev/null
done
same "F27 two repositories, no hash tool: two plan budgets, not one" "2" "$(ls "$T/f27-home/plan-budget" 2>/dev/null | wc -l | tr -d ' ')"

# codex's health row: the bench reads it before the lane runs, by the CONFIGURED model; it was recorded by
# the model codex_cli_guard lowered it to, so a failing codex lane's rows were never found.
FAKE="$T/f27-codex"; mkdir -p "$FAKE"
printf '#!/bin/sh\ncase "$1" in --version) echo "codex-cli 0.150.0"; exit 0 ;; esac\ncat > /dev/null\necho "boom" >&2\nexit 1\n' > "$FAKE/codex"
chmod +x "$FAKE/codex"
HF="$T/f27-health.tsv"; : > "$HF"
rc="$(drive f27-codex ZUVO_CODEX_BIN="$FAKE/codex" ZUVO_CODEX_APP_BIN= ZUVO_PROVIDER_HEALTH_FILE="$HF" -- --provider codex-5.3)"
same "F27 a failing codex lane is recorded under its configured model" "gpt-6-sol" "$(awk -F'\t' '$1 == "codex-5.3" { print $2 }' "$HF")"

# ZUVO_SHARED_HOST=1: no lane that hands the diff to its client as an argument.
rc="$(LANES="agy mock-ok mock-ok2" drive f27-shared ZUVO_SHARED_HOST=1 -- --multi --dry-run)"
same "F27 ZUVO_SHARED_HOST=1: exit 0" "0" "$rc"
hasnt "F27 …agy is not among the providers" "agy" "$(sed -n 's/^Providers: //p' "$T/f27-shared.err" "$T/f27-shared.out" | head -1)"
has "F27 …and a NOTE says why" "ZUVO_SHARED_HOST=1 — not running agy" "$(err f27-shared)"

# agy's timeout WARN named the lane's whole timeout, not what the attempt had: a fallback started after a
# 2 s quota failure on a 6 s lane ran 4 s and was reported as 6.
FAKEA="$T/f27-agy"; mkdir -p "$FAKEA"
cat > "$FAKEA/agy" <<'EOF'
#!/bin/sh
m=""; while [ $# -gt 0 ]; do [ "$1" = "--model" ] && m="$2"; shift; done
case "$m" in
  primary) sleep 2; echo "quota reached"; exit 1 ;;
  *)       sleep 30 ;;
esac
EOF
chmod +x "$FAKEA/agy"
rc="$(drive f27-agy PATH="$FAKEA:$BIN:$PATH" ZUVO_AGY_MODEL=primary ZUVO_AGY_FALLBACK_MODEL=fallback ZUVO_REVIEW_TIMEOUT=6 -- --provider agy)"
f27_ev="$(cat "$T"/home-f27-agy/.zuvo/adversarial-failures/*/provider_agy.stderr 2>/dev/null)"
has "F27 agy: the fallback's timeout WARN names the 4 s it had" "agy timed out after 4s on 'fallback'" "$f27_ev"
fi

if only F28; then
echo "=== F28 bounds: the input, one answer, a --single walk and a chunked run fit their budgets; the bench ignores the future (CQ6, CQ28) ==="
# The input was read whole with no ceiling: an endless or enormous producer filled the memory first.
f28_diff() {   # <lines> — a one-file diff of that many added lines
  local i=1
  printf 'diff --git a/c.js b/c.js\n--- a/c.js\n+++ b/c.js\n@@ -0,0 +1,%d @@\n' "$1"
  while [ "$i" -le "$1" ]; do printf '+const value_%d = %d;\n' "$i" "$i"; i=$((i + 1)); done
}
f28_diff 20 > "$T/f28-big.diff"
rc="$(STDIN_FILE="$T/f28-big.diff" drive f28-cap ZUVO_ADV_MAX_INPUT_BYTES=200 -- --single --dry-run)"
same "F28 stdin over ZUVO_ADV_MAX_INPUT_BYTES: refused (exit 2)" "2" "$rc"
has "F28 …saying why" "over ZUVO_ADV_MAX_INPUT_BYTES=200 bytes" "$(err f28-cap)"
rc="$(drive f28-cap-ok ZUVO_ADV_MAX_INPUT_BYTES=200 -- --single --dry-run)"
same "F28 …an input under it runs (exit 0)" "0" "$rc"
printf 'const a = 1;\n%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 > "$REPO/f28-a.js"; cp "$REPO/f28-a.js" "$REPO/f28-b.js"
rc="$(drive f28-files ZUVO_ADV_MAX_INPUT_BYTES=200 -- --single --dry-run --files "f28-a.js
f28-b.js")"
same "F28 --files adding up past the ceiling: refused (exit 2)" "2" "$rc"
rm -f "$REPO/f28-a.js" "$REPO/f28-b.js"

# One lane's answer had no bound but the disk: it is read into memory, merged and logged.
mock mock-huge 'head -c 3000000 /dev/zero | tr "\0" "a"; echo'
rc="$(LANES=mock-huge drive f28-huge -- --single --json)"
same "F28 a 3 MB answer: the review still completes (exit 0)" "0" "$rc"
has "F28 …and keeps its first 2 MiB, said in a WARN" "answer was 3000001 bytes" "$(err f28-huge)"
f28_len="$(out f28-huge | jq -r '.results["mock-huge"] | if type == "string" then length else -1 end' 2>/dev/null)"
# (+1: --single stores the answer it kept with `echo`, which ends it with a newline)
[ "${f28_len:-0}" -gt 0 ] && [ "${f28_len:-0}" -le 2097153 ] && ok "F28 …the document holds at most 2 MiB of it" \
  || bad "F28 …the document holds at most 2 MiB of it — got [${f28_len:-none}]"

# --single walked its candidates one after another with a full timeout EACH: a first lane that timed out
# left the next a fresh window, past every caller's wrapper. One budget now; a fast failure still leaves
# the next lane its turn.
mock mock-slow 'exec sleep 30'
mock mock-fail 'exit 1'
f28_t0=$SECONDS
rc="$(LANES="mock-slow mock-ok" drive f28-walk ZUVO_REVIEW_TIMEOUT=8 -- --single)"
has "F28 --single: after a lane used the whole budget, the next is not started" "not starting mock-ok" "$(err f28-walk)"
[ $(( SECONDS - f28_t0 )) -lt 40 ] && ok "F28 …so the run stays inside its one budget" || bad "F28 …so the run stays inside its one budget — took $(( SECONDS - f28_t0 ))s"
rc="$(LANES="mock-fail mock-ok" drive f28-walk2 ZUVO_REVIEW_TIMEOUT=8 -- --single)"
same "F28 …while a lane that failed fast still hands over to the next (exit 0)" "0" "$rc"

# A chunked run gave every part the caller's whole ZUVO_RUN_DEADLINE, so N parts took N x the budget.
{ for f in one two three; do
    printf 'diff --git a/%s.js b/%s.js\n--- a/%s.js\n+++ b/%s.js\n@@ -0,0 +1,40 @@\n' "$f" "$f" "$f" "$f"
    i=1; while [ "$i" -le 40 ]; do printf '+const %s_%d = %d;\n' "$f" "$i" "$i"; i=$((i + 1)); done
  done; } > "$T/f28-three.diff"
mock mock-ten 'sleep 10; printf "%s\n" "{\"findings\": []}"'
rc="$(LANES=mock-ten STDIN_FILE="$T/f28-three.diff" drive f28-chunk ZUVO_ADV_MAX_CHARS=2000 ZUVO_RUN_DEADLINE=35 -- --single)"
same "F28 a chunked run under ZUVO_RUN_DEADLINE=35 with 10 s parts: partial coverage (exit 4)" "4" "$rc"
has "F28 …the parts past the budget are not started, and said" "not started" "$(err f28-chunk)"

# The chunk summary counted a part reviewed with its input cut (exit 4) as "failed", and printed
# ", 0 with no material" because "0" is not empty.
{ printf 'diff --git a/small.js b/small.js\n--- a/small.js\n+++ b/small.js\n@@ -0,0 +1,2 @@\n+const s = 1;\n+const t = 2;\n'
  f28_diff 140; } > "$T/f28-cut.diff"
rc="$(STDIN_FILE="$T/f28-cut.diff" drive f28-sum ZUVO_ADV_MAX_CHARS=2000 -- --single)"
f28_line="$(grep '^CHUNKED: .*Aggregate exit' "$T/f28-sum.err" | tail -1)"
has "F28 a part reviewed with its input cut is not called failed" "reviewed with input cut" "$f28_line"
hasnt "F28 …and no count of zero is printed" ", 0 with no material" "$f28_line"

# The bench took a failure dated after now as recent forever-ish: its "age" was negative.
HF="$T/f28-health.tsv"
printf 'mock-ok2\tunknown\t5\t%s\tauth\n' "$(( $(date +%s) + 30 * 86400 ))" > "$HF"
mock mock-ok2 'printf "%s\n" "{\"findings\": []}"'
rc="$(LANES="mock-ok mock-ok2" drive f28-bench ZUVO_PROVIDER_HEALTH_FILE="$HF" -- --multi --dry-run)"
hasnt "F28 a health row dated 30 days ahead does not bench the lane" "Benched" "$(err f28-bench)"
fi

if only F29; then
echo "=== F29 the claude lane's Sonnet default is said where the user sees it (CQ8) ==="
# With CLAUDE_MODEL unset the claude lane reviews with Sonnet, assuming an Opus author — a heuristic, so
# it warns. The warning was printed inside the lane, whose stderr is captured to a file nothing shows when
# the lane succeeds: the note meant to keep a Sonnet-reviews-Sonnet run from being silent was always silent.
F29B="$T/f29-bin"; mkdir -p "$F29B"
cat > "$F29B/claude" <<'EOF'
#!/bin/sh
cat > /dev/null
printf 'SEVERITY: WARNING\nFILE: a.js:1\nISSUE: f29 fake finding\n'
EOF
chmod +x "$F29B/claude"
f29_neutral="CLAUDECODE= CODEX_SANDBOX= CODEX_SHELL= CODEX_INTERNAL_ORIGINATOR_OVERRIDE= __CFBundleIdentifier= QWEN_CODE= ZUVO_CLAUDE_REVIEWER_MODEL="
# shellcheck disable=SC2086  # a list of assignments, one per word
rc="$(drive f29-sonnet PATH="$F29B:$BIN:$PATH" CLAUDE_MODEL= $f29_neutral -- --provider claude)"
same "F29 claude lane, CLAUDE_MODEL unset: the review runs (exit 0)" "0" "$rc"
has "F29 …and the run says Sonnet is a default, not a proof" "has no recognized Opus token" "$(err f29-sonnet)"
# shellcheck disable=SC2086
rc="$(drive f29-opus PATH="$F29B:$BIN:$PATH" CLAUDE_MODEL=claude-sonnet-5 $f29_neutral -- --provider claude)"
same "F29 a Sonnet author (Opus reviews): exit 0" "0" "$rc"
hasnt "F29 …and nothing to warn about" "has no recognized Opus token" "$(err f29-opus)"
fi

if only F30; then
echo "=== F30 the input ceiling is measured before anything strips the input; a failing git diff is not reviewed; a failed chunk outranks a cut one (p6) ==="
# A command substitution drops trailing newlines AFTER the bounded read: an input whose first byte over the
# ceiling was a newline came back under it, and its tail was silently never reviewed (exit 0).
{ printf 'diff --git a/n.js b/n.js\n--- a/n.js\n+++ b/n.js\n@@ -0,0 +1,3 @@\n+const n = 1;\n'
  printf '%s' "$(head -c 400 /dev/zero | tr '\0' 'a')"; } > "$T/f30-head"
f30_lim="$(wc -c < "$T/f30-head" | tr -d ' ')"
{ cat "$T/f30-head"; printf '\n+const tail_that_must_not_vanish = 2;\n'; } > "$T/f30-nl.diff"
rc="$(STDIN_FILE="$T/f30-nl.diff" drive f30-nl ZUVO_ADV_MAX_INPUT_BYTES="$f30_lim" -- --single --dry-run)"
same "F30 stdin one byte over the ceiling, that byte a newline: refused (exit 2)" "2" "$rc"
has "F30 …saying why" "over ZUVO_ADV_MAX_INPUT_BYTES=$f30_lim bytes" "$(err f30-nl)"
rc="$(STDIN_FILE="$T/f30-head" drive f30-at ZUVO_ADV_MAX_INPUT_BYTES="$f30_lim" -- --single --dry-run)"
same "F30 …while an input exactly AT the ceiling still runs (exit 0)" "0" "$rc"
# --files: a file that crossed the ceiling only by its trailing newline ended the read, and every later path
# was never read — accepted with exit 0, reviewing the first file alone.
printf 'const f = 1;\n' > "$REPO/f30-a.js"; printf 'const g = 2;\n' > "$REPO/f30-b.js"
f30_flim=$(( $(printf '=== FILE: f30-a.js ===\nconst f = 1;\n' | wc -c) ))
rc="$(drive f30-files ZUVO_ADV_MAX_INPUT_BYTES="$f30_flim" -- --single --dry-run --file f30-a.js --file f30-b.js)"
same "F30 --files crossing the ceiling by a trailing newline: refused (exit 2)" "2" "$rc"
hasnt "F30 …nothing is reviewed with the second file silently left out" "const f = 1;" "$(out f30-files)"
rm -f "$REPO/f30-a.js" "$REPO/f30-b.js"
# A git diff that fails after printing part of the change went to the providers as the whole change (exit 0).
mkdir -p "$T/f30-git"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *..HEAD) printf "diff --git a/p.js b/p.js\\n--- a/p.js\\n+++ b/p.js\\n@@ -1 +1 @@\\n-a\\n+b\\n"; echo "fatal: unable to read 1234abcd" >&2; exit 128 ;; esac; done\nexec %s "$@"\n' "$(command -v git)" > "$T/f30-git/git"
chmod +x "$T/f30-git/git"
rc="$(drive f30-diff PATH="$T/f30-git:$BIN:$PATH" -- --single --dry-run --diff HEAD~1)"
same "F30 --diff whose git diff fails part-way: refused (exit 2)" "2" "$rc"
has "F30 …named as a failed git diff, not reviewed in part" "failed (exit 128) after printing part of the diff" "$(err f30-diff)"
hasnt "F30 …and its partial hunk never reaches a prompt" "+b" "$(out f30-diff)"
# The chunked aggregate was the highest child code: a part reviewed with its input cut (4) outranked a part
# that FAILED (2), and the run read "completed over truncated input".
{ printf 'diff --git a/fail.js b/fail.js\n--- a/fail.js\n+++ b/fail.js\n@@ -0,0 +1,2 @@\n+const FAILME = 1;\n+const x = 2;\n'
  printf 'diff --git a/big.js b/big.js\n--- a/big.js\n+++ b/big.js\n@@ -0,0 +1,120 @@\n'
  i=1; while [ "$i" -le 120 ]; do printf '+const big_value_number_%d = %d;\n' "$i" "$i"; i=$((i + 1)); done; } > "$T/f30-mix.diff"
printf '#!/bin/sh\nin="$(cat)"\ncase "$in" in *FAILME*) exit 1 ;; esac\nprintf "%%s\\n" "{\\"findings\\": []}"\n' > "$BIN/mock-mix"; chmod +x "$BIN/mock-mix"
rc="$(LANES=mock-mix STDIN_FILE="$T/f30-mix.diff" drive f30-agg ZUVO_ADV_MAX_CHARS=2000 -- --single)"
same "F30 a failed part beside a part reviewed with its input cut: the run fails (exit 2), not 4" "2" "$rc"
has "F30 …and the summary counts both" "1 failed, 1 reviewed with input cut" "$(err f30-agg)"
# A part reviewed with its input cut beside a part with no material: partial coverage (4), not "NONE carried
# reviewable material" (5) — the cut part WAS reviewed.
# The prose preamble is a part of its own (bigger than half the budget) and has no material; both diffs are
# over the cap, so each is a part reviewed with its input cut — no part is plain ok.
{ i=1; while [ "$i" -le 30 ]; do printf 'Just prose about the change, line %d, nothing a reviewer can judge.\n' "$i"; i=$((i + 1)); done
  for f in big2 big3; do
    printf 'diff --git a/%s.js b/%s.js\n--- a/%s.js\n+++ b/%s.js\n@@ -0,0 +1,120 @@\n' "$f" "$f" "$f" "$f"
    i=1; while [ "$i" -le 120 ]; do printf '+const %s_value_number_%d = %d;\n' "$f" "$i" "$i"; i=$((i + 1)); done
  done; } > "$T/f30-nomat.diff"
rc="$(STDIN_FILE="$T/f30-nomat.diff" drive f30-nomat ZUVO_ADV_MAX_CHARS=2000 -- --single)"
same "F30 a cut part beside a part with no material: partial coverage (exit 4)" "4" "$rc"
hasnt "F30 …never reported as nothing reviewed" "NONE carried reviewable material" "$(err f30-nomat)"
# _ck_stop ran between `child &` and `_ck_pid=$!` (a trap fires between two commands) returned at once: the
# child just started kept reviewing after its chunk dir was removed. With no pid saved, the last job is it.
f30_stop="$(awk '/^  _ck_stop\(\) \{$/ { f = 1 } f { print } f && /^  \}$/ { exit }' "$(dirname "$AR")/lib/adversarial-input.sh")"
if [ -n "$f30_stop" ]; then
  f30_out="$(bash -c "$f30_stop"'
    sleep 30 & _ck_pid=""; _ck_stop; if kill -0 $! 2>/dev/null; then echo alive; kill $! 2>/dev/null; else echo stopped; fi' 2>/dev/null)"
  same "F30 _ck_stop with no pid saved yet stops the child just started" "stopped" "$f30_out"
else
  bad "F30 _ck_stop could not be read from adversarial-input.sh"
fi
fi

if only F31; then
echo "=== F31 a lock's holder is judged by a process that is really it: another user's live process holds, a reused pid does not (p6) ==="
# `kill -0` was the only test of the holder. It fails with EPERM for a live process of another user — whose
# lock was then broken as dead — and succeeds for a pid reused since, whose lock was then never broken.
HF31="$T/f31-health.tsv"; : > "$HF31"
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$HF31.lock"; printf '1\n' > "$HF31.lock/pid"   # pid 1: alive, not ours — kill -0 says EPERM
  rc="$(drive f31-eperm ZUVO_PROVIDER_HEALTH_FILE="$HF31" ZUVO_PROVIDER_HEALTH_LOCK_WAIT=1 -- --single)"
  same "F31 a lock held by another user's live process: the review completes (exit 0)" "0" "$rc"
  has "F31 …and the lock is NOT broken: the ledger is busy" "provider-health ledger busy" "$(err f31-eperm)"
  [ -d "$HF31.lock" ] && ok "F31 …the holder's lock is still there" || bad "F31 …the holder's lock was removed"
  rm -rf "$HF31.lock"
else
  echo "  SKIP F31 EPERM case — this suite runs as root, where kill -0 reaches every process"
fi
# A reused pid: the lock was taken 10 minutes ago, the live process with its pid started a moment ago.
sleep 60 & f31_pid=$!
mkdir -p "$HF31.lock"; printf '%s\n' "$f31_pid" > "$HF31.lock/pid"
python3 -c 'import os, sys, time; t = time.time() - 600; os.utime(sys.argv[1], (t, t)); os.utime(sys.argv[2], (t, t))' \
  "$HF31.lock/pid" "$HF31.lock"
rc="$(drive f31-reuse ZUVO_PROVIDER_HEALTH_FILE="$HF31" ZUVO_PROVIDER_HEALTH_LOCK_WAIT=2 -- --single)"
kill "$f31_pid" 2>/dev/null; wait "$f31_pid" 2>/dev/null
same "F31 a lock whose pid now belongs to a younger process: the review completes (exit 0)" "0" "$rc"
hasnt "F31 …the stale lock is broken, not waited out as busy" "provider-health ledger busy" "$(err f31-reuse)"
has "F31 …and the run's outcome is recorded" "mock-ok" "$(cat "$HF31" 2>/dev/null)"
[ ! -e "$HF31.lock" ] && ok "F31 …and released" || bad "F31 …a lock was left behind"
fi

if only F32; then
echo "=== F32 the artifact never claims what it does not hold: a pass that did not land fails the run, a dropped answer is not credited; any-case JSON fences (p6) ==="
# --append-artifact returned 0 on every failure path: the pass kept beside the artifact (or lost) while the
# run exited 0 — and the artifact a gate reads lacked its REVIEW BY lines.
A32="$T/f32-art/review.txt"; mkdir -p "$T/f32-art"
rc="$(drive f32-first -- --single --artifact "$A32")"
same "F32 premise: a first pass writes the artifact (exit 0)" "0" "$rc"
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$A32"   # the artifact cannot be read, so this pass cannot be appended to it
  rc="$(drive f32-unread -- --single --artifact "$A32" --append-artifact)"
  chmod 644 "$A32"
  same "F32 an append to an artifact that cannot be read: the run fails (exit 2), not 0" "2" "$rc"
  has "F32 …the pass is kept beside the artifact, said" "this pass is kept as" "$(err f32-unread)"
  has "F32 …and the run says the artifact was not written" "Failed to write adversarial artifact" "$(err f32-unread)"
  [ "$(find "$T/f32-art" -name 'review.txt.pass-*' | wc -l | tr -d ' ')" = 1 ] && ok "F32 …one kept pass file" \
    || bad "F32 …one kept pass file — found: $(ls "$T/f32-art")"
else
  echo "  SKIP F32 unreadable-artifact case — root reads a mode-000 file"
fi
# A lane whose answer jq could not add to the --json document was still in providers_used — the artifact
# carried its REVIEW BY line and its finding counts for an answer its body did not hold.
mkdir -p "$T/f32-jq"
printf '#!/bin/sh\ncase " $* " in *" mock-drop "*--rawfile*|*--rawfile*" mock-drop "*) exit 5 ;; esac\nexec %s "$@"\n' "$(command -v jq)" > "$T/f32-jq/jq"
chmod +x "$T/f32-jq/jq"
mock mock-drop 'printf "SEVERITY: CRITICAL\nISSUE: dropped lane finding\n"'
A32b="$T/f32-art/drop.txt"
rc="$(LANES="mock-ok mock-drop" drive f32-drop PATH="$T/f32-jq:$BIN:$PATH" -- --multi --json --artifact "$A32b")"
same "F32 a lane jq cannot add: the review completes (exit 0)" "0" "$rc"
has "F32 …the document leaves it out, said" "leaves out the answer of: mock-drop" "$(err f32-drop)"
hasnt "F32 …and the artifact gives it no REVIEW BY line" "REVIEW BY: MOCK-DROP" "$(cat "$A32b" 2>/dev/null)"
has "F32 …while the lane that IS in it keeps its line" "REVIEW BY: MOCK-OK" "$(cat "$A32b" 2>/dev/null)"
same "F32 …nor its CRITICAL in the counts" "critical=0" "$(grep '^critical=' "$A32b" 2>/dev/null)"
same "F32 …nor in providers_used" "mock-ok" "$(out f32-drop | jq -r '.providers_used' 2>/dev/null)"
# Only a lowercase ```json fence at column 0 was stripped: an answer fenced ```JSON was stored as a string.
mock mock-fenced 'printf "\`\`\`JSON\n{\"findings\": []}\n\`\`\`\n"'
rc="$(LANES=mock-fenced drive f32-fence -- --single --json)"
same "F32 an answer fenced \`\`\`JSON: the review completes (exit 0)" "0" "$rc"
same "F32 …and its JSON is stored as JSON, not as a string" "object" "$(out f32-fence | jq -r '.results["mock-fenced"] | type' 2>/dev/null)"
fi

if only F33; then
echo "=== F33 lanes: agy's budget never reaches 0, a killed agy is not 'out of quota', a lane failing on both models is benched; openrouter lanes say their own name and keep their own files; an answer that cannot be cut is never read whole (p6) ==="
LIB33="$(dirname "$AR")/lib"
# f33_agy <stubs> <command> — run_agy's module in a fresh shell, with <stubs> defined after it (they replace
# what the rest of the program would supply), then <command>; prints what <command> prints.
f33_agy() {
  bash -c '. "$1/adversarial-lanes.sh" || exit 9; eval "$2"; eval "$3"' _ "$LIB33" "$1" "$2" 2>&1
}
F33_STUBS='JSON_TMPDIR="$(mktemp -d)"; lane_model() { echo primary-model; }; _ar_quote_line() { head -1; }
_ar_lane_budget() { return 1; }; ZUVO_AGY_FALLBACK_MODEL=fallback-model; ZUVO_HOME="$JSON_TMPDIR/home"'
# The first attempt's budget had no floor: with the lane's time gone before agy started, it was `timeout 0`
# — no limit at all.
f33_out="$(f33_agy "$F33_STUBS"'; PROVIDER_TIMEOUT=1
_agy_on_cooldown() { sleep 2; return 1; }
_agy_attempt() { echo "ATTEMPT PROVIDER_TIMEOUT=$PROVIDER_TIMEOUT"; _AGY_CLASS=failed; return 1; }' 'run_agy; echo "rc=$?"')"
hasnt "F33 agy with nothing left of its budget: no attempt is started" "ATTEMPT" "$f33_out"
has "F33 …it is a timeout (124), said" "rc=124" "$f33_out"
# timeout's own SIGKILL (137, agy outlived the TERM) after an "interrupted" — read as silent quota exhaustion,
# the model cooled down for an hour. When the budget was spent it is a timeout; an early 137 is a kill.
f33_out="$(f33_agy "$F33_STUBS"'; PROVIDER_TIMEOUT=1; TIMEOUT_KILL_FLAG=""
timeout() { echo "error: interrupted" >&2; sleep 2; return 137; }' '_agy_attempt m; echo "class=$_AGY_CLASS"')"
has "F33 agy SIGKILLed by timeout after its budget: class timeout" "class=timeout" "$f33_out"
f33_out="$(f33_agy "$F33_STUBS"'; PROVIDER_TIMEOUT=60; TIMEOUT_KILL_FLAG=""
timeout() { echo "error: interrupted" >&2; return 137; }' '_agy_attempt m; echo "class=$_AGY_CLASS"')"
has "F33 agy SIGKILLed early (an outside kill): a failure" "class=failed" "$f33_out"
hasnt "F33 …never quota" "class=quota" "$f33_out"
# A lane failing on BOTH models was recorded under the fallback, while the bench looks up the configured
# model before the run — so it was never benched however often it failed.
f33_out="$(f33_agy "$F33_STUBS"'; PROVIDER_TIMEOUT=60
_agy_on_cooldown() { return 1; }; _ar_lane_budget() { echo 30; }
_agy_attempt() { _AGY_CLASS=failed; _AGY_ERR_TEXT=boom; return 1; }' 'run_agy >/dev/null 2>&1; echo "recorded=$(cat "$JSON_TMPDIR/agy-effective-model")"')"
has "F33 agy failing on both models is recorded under its configured model" "recorded=primary-model" "$f33_out"
# openrouter-alt/-3/-4 said "openrouter" in their WARNs (now on the driver's line about a failed lane), and two
# lanes with one model id shared their payload, curl config and error file mid-flight.
mkdir -p "$T/f33-curl"
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -K) printf "cfg %%s\\n" "$2" >> "%s/f33-curl.log" ;; -d) printf "data %%s\\n" "$2" >> "%s/f33-curl.log" ;; esac; shift; done\nprintf "%%s\\n%%s" "{\\"error\\":{\\"message\\":\\"bad key\\"}}" 401\n' "$T" "$T" > "$T/f33-curl/curl"
chmod +x "$T/f33-curl/curl"; : > "$T/f33-curl.log"
rc="$(LANES="openrouter-3 openrouter-4" drive f33-or PATH="$T/f33-curl:$BIN:$PATH" OPENROUTER_API_KEY=sk-test \
  ZUVO_MODEL_OPENROUTER_3=vendor/same-model ZUVO_MODEL_OPENROUTER_4=vendor/same-model -- --multi)"
has "F33 openrouter-3's failure is told under its own name" "openrouter-3 returned error" "$(err f33-or)"
has "F33 …and openrouter-4's" "openrouter-4 returned error" "$(err f33-or)"
same "F33 two lanes with one model id use two curl configs" "2" "$(awk '$1 == "cfg" { print $2 }' "$T/f33-curl.log" | sort -u | wc -l | tr -d ' ')"
same "F33 …and two payload files" "2" "$(awk '$1 == "data" { print $2 }' "$T/f33-curl.log" | sort -u | wc -l | tr -d ' ')"
# An answer the copy-and-move could not cut (a full disk, an unwritable dir) stayed whole, no WARN, and was
# then read in full. It is cut in place, or dropped.
f33_out="$(bash -c '. "$1/adversarial-dispatch.sh" || exit 9; JSON_TMPDIR="$(mktemp -d)"; LANE_ANSWER_MAX_BYTES=1000
  head -c 3000 /dev/zero | tr "\0" a > "$JSON_TMPDIR/result_lane.txt"
  head() { return 1; }
  _ar_cap_answer lane; echo "size=$(wc -c < "$JSON_TMPDIR/result_lane.txt" | tr -d " ")"' _ "$LIB33" 2>&1)"
has "F33 an answer the copy cannot cut is cut in place to the cap" "size=1000" "$f33_out"
has "F33 …said in a WARN" "keeps its first 1000" "$f33_out"
fi

if only F34; then
echo "=== F34 a driver started before an install replaced it never loads the new modules; a driver that did not install is INSTALL INCOMPLETE (p6) ==="
. "$ROOT/tests/lib/adversarial-driver.sh"
# f34_sum <module dir> <driver file> — the stamp an install writes for that set beside that driver.
# shellcheck disable=SC2046  # module names, one word each: split on purpose
f34_sum() { { cat "$2"; ( cd "$1" && cat $(adv_driver_modules "$AR") ); } | cksum; }
# The loader re-read its own file BY PATH inside the stamp wait: a driver that started during an install —
# running the old bootstrap — matched the stamp the moment the new driver file landed, and loaded the new
# modules. Here the set is stamped for the NEXT driver; the running one is replaced by it 2 s into its wait.
rm -rf "$T/f34"
if adv_driver_copy "$AR" "$T/f34/adversarial-review.sh" lib; then
  cp "$T/f34/adversarial-review.sh" "$T/f34-next.sh"; printf '\n# the next release of the driver\n' >> "$T/f34-next.sh"
  f34_sum "$T/f34/lib" "$T/f34-next.sh" > "$T/f34/lib/adversarial-modules.cksum"
  ( sleep 2; cp "$T/f34-next.sh" "$T/f34/.next" && mv "$T/f34/.next" "$T/f34/adversarial-review.sh" ) &
  f34_swap=$!
  mkdir -p "$T/home-f34/.zuvo"; rc=0
  ( cd "$REPO" && env HOME="$T/home-f34" ZUVO_HOME="$T/home-f34/.zuvo" TMPDIR="$T/tmp" PATH="$BIN:$PATH" \
      ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-ok ZUVO_ADV_MODULE_STAMP_WAIT=6 \
      bash "$T/f34/adversarial-review.sh" --dry-run <<< "$DIFF" ) > "$T/f34.out" 2> "$T/f34.err" || rc=$?
  wait "$f34_swap"
  same "F34 the old driver, its file replaced mid-wait by the one the stamp is for: refused (exit 2)" "2" "$rc"
  has "F34 …because its own bytes do not match the stamp" "does not match its install stamp" "$(err f34)"
else
  bad "F34 premise: copying the driver with its modules failed"
fi
# The helper loop only WARNED when ~/.zuvo/adversarial-review did not land ("skipped"): the install reported no
# failure while the old driver beside the newly stamped sets refused every review.
INSTALL34="$ROOT/scripts/install.sh"
H34="$T/f34-home"; mkdir -p "$H34/.zuvo/adversarial-review"   # a directory where the driver goes: no file lands
f34_log="$(HOME="$H34" "$BASH" -c '. "$1" >/dev/null 2>&1 || { echo "SOURCE FAILED"; exit 97; }
  trap "printf \"INSTALL_VERIFY_MISSING=%s\n%s\n\" \"\$INSTALL_VERIFY_MISSING\" \"\$INSTALL_VERIFY_DETAIL\"" EXIT
  install_zuvo_home' _ "$INSTALL34" 2>&1)"
hasnt "F34 premise: the installer sources" "SOURCE FAILED" "$f34_log"
has "F34 a ~/.zuvo/adversarial-review that did not install is counted for INSTALL INCOMPLETE" \
  "adversarial driver: $H34/.zuvo/adversarial-review" "$f34_log"
fi

if only F35; then
echo "=== F35 the plan budget says when it cannot be read; --help states the real timeout; a recorded model with a control character is not reported (p6) ==="
# A budget file this pass could write but not read counted 0, silently: the breaker never fired again.
P35="$T/f35-plan.md"
{ printf '# Plan\n\n'; for i in 1 2 3 4; do printf '### Task %d: step %d\n\nDo the thing number %d.\n\n' "$i" "$i" "$i"; done; } > "$P35"
if [ "$(id -u)" -ne 0 ]; then
  rc="$(STDIN_FILE="$P35" drive f35-plan -- --mode plan --single)"   # a real pass: it creates the budget file
  f35_file="$(find "$T/home-f35-plan/.zuvo/plan-budget" -type f 2>/dev/null | head -1)"
  if [ -n "$f35_file" ]; then
    chmod 200 "$f35_file"
    rc="$(STDIN_FILE="$P35" drive f35-plan -- --mode plan --single)"
    chmod 600 "$f35_file"
    same "F35 a plan budget that can be written but not read: the review still runs (exit 0)" "0" "$rc"
    has "F35 …and says the round budget does not apply to this pass" "budget cannot be read" "$(err f35-plan)"
  else
    bad "F35 premise: a --mode plan pass created no budget file"
  fi
else
  echo "  SKIP F35 unreadable-budget case — root reads a mode-200 file"
fi
# --help said the per-provider timeout defaults to 400; it is 500.
rc="$(drive f35-help -- --help)"
has "F35 --help states the real default timeout" "Per-provider timeout in seconds (default: 500" "$(out f35-help)"
# A model name read back from the lane's file went out unvalidated: a tab or newline in it splits the
# ledgers' tab-separated rows. It falls back to the configured model instead.
f35_out="$(bash -c '. "$1/adversarial-providers.sh" || exit 9; JSON_TMPDIR="$(mktemp -d)"
  printf "bad\tmodel" > "$JSON_TMPDIR/agy-effective-model"
  lane_model() { echo configured-model; }
  provider_model agy' _ "$(dirname "$AR")/lib" 2>&1)"
same "F35 a recorded model holding a tab is not reported; the configured one is" "configured-model" "$f35_out"
fi

if [ -n "${ADV_HARDENING_ONLY:-}" ] && [ "$ONLY_HIT" -eq 0 ]; then
  bad "ADV_HARDENING_ONLY=$ADV_HARDENING_ONLY names no section of this suite — nothing ran"
fi
echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "Tests: $PASS passed, $FAIL failed"   # the summary shape the refactor contract's red/green proof reads
[ "$FAIL" -eq 0 ]
