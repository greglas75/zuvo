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
has "F8 …which a WARN says" "provider-health" "$(err f8-held)"
rmdir "$HF.lock"
rc="$(drive f8-free ZUVO_PROVIDER_HEALTH_FILE="$HF" -- --single)"
same "F8 lock free: exit 0" "0" "$rc"
has "F8 …and the lane's row is written" "mock-ok	" "$(cat "$HF")"
[ -e "$HF.lock" ] && bad "F8 …but the lock was left behind" || ok "F8 …and the lock is released"
# A lock left by a run that died (older than the stale limit) does not block the ledger forever.
mkdir "$HF.lock"; touch -t 202001010000 "$HF.lock"
: > "$HF"
rc="$(drive f8-stale ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_PROVIDER_HEALTH_LOCK_WAIT=1 -- --single)"
has "F8 a stale lock from a dead run is broken, and the row is written" "mock-ok	" "$(cat "$HF")"
rmdir "$HF.lock" 2>/dev/null || true
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
printf 'mock-ok\n' > "$CACHE_DIR/failed-providers.hardening-f10-legacy-$$"
rc="$(LANES="mock-ok mock-ok2" drive f10-legacy -- --multi)"
hasnt "F10 a cached failure with no time (from before) no longer excludes the lane" "auth failed earlier this run): mock-ok" "$(err f10-legacy)"
printf 'mock-ok\t%s\n' "$((now - 7 * 3600))" > "$CACHE_DIR/failed-providers.hardening-f10-old-$$"
rc="$(LANES="mock-ok mock-ok2" drive f10-old -- --multi)"
hasnt "F10 a failure cached 7 h ago (TTL 6 h) no longer excludes the lane" "auth failed earlier this run): mock-ok" "$(err f10-old)"
printf 'mock-ok\t%s\n' "$((now - 3600))" > "$CACHE_DIR/failed-providers.hardening-f10-fresh-$$"
rc="$(LANES="mock-ok mock-ok2" drive f10-fresh -- --multi)"
has "F10 a failure cached 1 h ago still excludes the lane" "auth failed earlier this run): mock-ok" "$(err f10-fresh)"
printf 'mock-ok\t%s\n' "$((now - 3600))" > "$CACHE_DIR/failed-providers.hardening-f10-short-$$"
rc="$(LANES="mock-ok mock-ok2" drive f10-short ZUVO_AUTH_CACHE_TTL=600 -- --multi)"
hasnt "F10 …unless ZUVO_AUTH_CACHE_TTL is shorter than its age" "auth failed earlier this run): mock-ok" "$(err f10-short)"
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
if [ -z "$sleeper" ]; then bad "F11 premise: the sleeping lane never started"
else
  ok "F11 premise: a lane's client is running (pid $sleeper)"
  kill -TERM "$drv"; wait "$drv"; rc=$?
  same "F11 the driver exits 143 on TERM" "143" "$rc"
  alive=1; for _ in $(seq 1 30); do kill -0 "$sleeper" 2>/dev/null || { alive=0; break; }; sleep 0.1; done
  if [ "$alive" -eq 0 ]; then ok "F11 …and the lane's client is gone"
  else bad "F11 …but the lane's client (pid $sleeper) is still running"; kill -9 "$sleeper" 2>/dev/null; fi
fi
fi

if only F18; then
echo "=== F18 the run's temp dir is cleaned up from the moment it exists (CQ35) ==="
# JSON_TMPDIR was created in ar_init_run_state and the traps only armed after the run log was set up:
# a TERM in between left the temp dir (and anything a lane later wrote into it) behind.
REAL_MKDIR="$(command -v mkdir)"
mkdir -p "$T/slowmk"
printf '#!/bin/sh\ncase "$*" in *adversarial-inputs*) sleep 4 ;; esac\nexec "%s" "$@"\n' "$REAL_MKDIR" > "$T/slowmk/mkdir"
chmod +x "$T/slowmk/mkdir"
rm -rf "$T/tmp-f18"; "$REAL_MKDIR" -p "$T/tmp-f18"
( cd "$REPO" && exec env HOME="$T/home-f18" ZUVO_HOME="$T/home-f18/.zuvo" TMPDIR="$T/tmp-f18" PATH="$T/slowmk:$BIN:$PATH" \
    ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-ok \
    bash "$AR" --single <<< "$DIFF" > "$T/f18.out" 2> "$T/f18.err" ) &
f18_pid=$!
sleep 2
f18_dirs_before="$(find "$T/tmp-f18" -mindepth 1 -maxdepth 1 -type d -name 'tmp.*' | wc -l | tr -d ' ')"
kill -TERM "$f18_pid" 2>/dev/null; wait "$f18_pid" 2>/dev/null
sleep 1
same "F18 premise: the run's temp dir existed when TERM came (inside the run-log setup)" "1" "$f18_dirs_before"
same "F18 …and TERM removed it" "0" "$(find "$T/tmp-f18" -mindepth 1 -maxdepth 1 -type d -name 'tmp.*' | wc -l | tr -d ' ')"
fi

if only F17; then
echo "=== F17 --doctor probes its lanes at the same time (CQ27) ==="
# One after another, a doctor over N lanes took up to N x ZUVO_DOCTOR_TIMEOUT — nine minutes for nine.
for n in 1 2 3; do mock "mock-slow$n" 'sleep 3; echo PROVIDER-OK'; done
f17_t0=$(date +%s)
rc="$(LANES="mock-slow1 mock-slow2 mock-slow3" drive f17 -- --doctor)"
f17_el=$(( $(date +%s) - f17_t0 ))
same "F17 three lanes that take 3 s each: exit 0" "0" "$rc"
[ "$f17_el" -lt 8 ] && ok "F17 …in ${f17_el}s, not 9+" || bad "F17 …took ${f17_el}s (one after another)"
same "F17 …all three reported WORKING" "3" "$(grep -c 'WORKING' "$T/f17.out")"
same "F17 …in the order they were listed" "mock-slow1 mock-slow2 mock-slow3" "$(awk '/WORKING/ { printf "%s%s", s, $1; s = " " }' "$T/f17.out")"
fi

if only F16; then
echo "=== F16 a lane's fallback gets what is left of its timeout, not a second one (CQ28) ==="
# agy fell back from a quota-dead primary with a FULL fresh timeout (and kimi to kimi-api), so one lane
# could run past the whole-run deadline — which then killed the run and every other lane's answer.
REAL_TIMEOUT="$(command -v timeout)"
# One line per call: the prompt's own newlines would otherwise split the record.
cat > "$BIN/timeout" <<SHIM
#!/bin/sh
{ printf '%s' "\$*" | tr '\n' ' '; echo; } >> "$T/timeout.log"
exec "$REAL_TIMEOUT" "\$@"
SHIM
chmod +x "$BIN/timeout"
cat > "$BIN/agy" <<'AGY'
#!/bin/sh
case "$*" in
  *"PRIMARY-M"*) sleep 3; echo "context canceled" >&2; exit 1 ;;
  *) echo '{"findings": []}' ;;
esac
AGY
chmod +x "$BIN/agy"
: > "$T/timeout.log"
rc="$(LANES=agy drive f16-agy ZUVO_REVIEW_TIMEOUT=60 ZUVO_AGY_MODEL=PRIMARY-M ZUVO_AGY_FALLBACK_MODEL=FALLBACK-M -- --single)"
same "F16 agy: primary out of quota after ~3 s, fallback answers: exit 0" "0" "$rc"
f16_last="$(awk '/ agy / && /FALLBACK-M/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/ && $(i+1) == "agy") print $i }' "$T/timeout.log" | tail -1)"
[ -n "$f16_last" ] && [ "$f16_last" -le 58 ] && ok "F16 …the fallback's timeout is what was left (${f16_last}s of 60)" \
  || bad "F16 …the fallback ran with timeout [${f16_last:-none}] — want at most 58 of the 60 s lane budget: $(cut -c1-24 "$T/timeout.log" | tr '\n' '|')"
# Too little left to be worth a call — under LANE_MIN_RETRY_SECONDS, or under half the lane's timeout when
# that is shorter (20 s of 40 here): the fallback is not started, and the lane's own stderr says so (kept as
# failure evidence: agy was the only lane, so nothing was reviewed).
cat > "$BIN/agy" <<'AGY'
#!/bin/sh
case "$*" in
  *"PRIMARY-M"*) sleep 22; echo "context canceled" >&2; exit 1 ;;
  *) echo '{"findings": []}' ;;
esac
AGY
: > "$T/timeout.log"
rc="$(LANES=agy drive f16-skip ZUVO_REVIEW_TIMEOUT=40 ZUVO_AGY_MODEL=PRIMARY-M ZUVO_AGY_FALLBACK_MODEL=FALLBACK-M -- --single)"
same "F16 agy: 18 s left of 40 after the primary, under the 20 s floor — no review (exit 2)" "2" "$rc"
hasnt "F16 …and the fallback model is not started" "FALLBACK-M" "$(cut -c1-60 "$T/timeout.log"; grep -o 'model [A-Z-]*' "$T/timeout.log")"
has "F16 …which the lane says" "fallback 'FALLBACK-M' not started" "$(cat "$T"/home-f16-skip/.zuvo/adversarial-failures/*/* 2>/dev/null)"
# kimi: the CLI fails on its plan limit after ~3 s; the API lane gets what is left, not a fresh timeout.
cat > "$BIN/kimi" <<'KIMI'
#!/bin/sh
sleep 3; echo "You've reached your weekly usage limit" >&2; exit 1
KIMI
chmod +x "$BIN/kimi"
cat > "$BIN/curl" <<CURL
#!/bin/sh
printf '%s\n' "\$*" >> "$T/curl.log"
printf '%s' '{"choices":[{"message":{"content":"{\"findings\": []}"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
CURL
chmod +x "$BIN/curl"
: > "$T/curl.log"
rc="$(LANES=kimi drive f16-kimi ZUVO_REVIEW_TIMEOUT=60 MOONSHOT_API_KEY=test-key -- --single)"
same "F16 kimi: CLI at its limit after ~3 s, kimi-api answers: exit 0" "0" "$rc"
f16_mt="$(awk '{ for (i = 1; i < NF; i++) if ($i == "--max-time") print $(i+1) }' "$T/curl.log" | tail -1)"
[ -n "$f16_mt" ] && [ "$f16_mt" -le 58 ] && ok "F16 …kimi-api's --max-time is what was left (${f16_mt}s of 60)"   || bad "F16 …kimi-api ran with --max-time [${f16_mt:-none}] — want at most 58 of the 60 s lane budget"
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
{ printf '%s' "$DIFF"; sleep 30; } > "$T/f14-open.fifo" &
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
{ sleep 20; } > "$T/f14-none.fifo" &
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
fi

echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "Tests: $PASS passed, $FAIL failed"   # the summary shape the refactor contract's red/green proof reads
[ "$FAIL" -eq 0 ]
