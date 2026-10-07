#!/usr/bin/env bash
#
# test-adversarial-blind-audit.sh — `adversarial-review.sh --mode blind-audit`: the blind coverage
# audit of ONE production file + its test file, run as a cross-vendor panel of isolated lanes
# (docs/specs/2026-09-25-blind-audit-panel-plan.md, Task 4 = input, isolation, panel dispatch).
#
# The decisions live in scripts/lib/blind-audit-panel.sh (tests/hooks/test-blind-audit-panel.sh pins
# them); this file pins the DRIVER's wiring of them, end to end:
#   A  input: --production/--test (+ --protocol) only in this mode, the other inputs refused (stdin data
#      too — even a lone NUL, even on a PATH with no `timeout`), empty
#      input exit 5, binary (NUL) input exit 2, oversize exit 6 before any lane runs, the library
#      looked up next to the driver or in ~/.zuvo — and missing, the mode alone refuses;
#      `--list-providers` without the mode keeps HEAD's output byte for byte
#   B  `--provider <lane>` = a panel of one: at best degraded, exit 3; mock lanes only in the test
#      harness; a global ZUVO_REVIEW_PROVIDER does not shrink the panel
#   C  the whole file reaches every lane: no 30k cap, no chunking, no truncation; agy's argv exactly
#   D  over the argv limit, the argv lanes (agy, kimi) are dropped loudly; the stdin lanes still run;
#      agy's argument is measured WITH its no-tools line
#   E  panel size ZUVO_BLIND_AUDIT_PANEL (default 3), ZUVO_REVIEW_MAX_PROVIDERS ignored
#   F  agy pinned in the default random pick
#   G  host exclusion by VENDOR (Claude excludes claude — kept in the other modes); an unmapped host
#      fails closed
#   H  isolation per lane, proven by SPIES named after real lanes and run through the REAL runners
#   I  ZUVO_BLIND_AUDIT_ALLOWLIST narrows; it can never admit a lane whose isolation was never proven
#   K  agy is left out when its settings.json holds allow-rules (or cannot be read)
#   L  every candidate excluded → exit 1 WITH the reason (this mode and code mode)
# Task 5 = the collection half:
#   M  each answer validated, the panel merged to the worst verdict, stdout = the merged block only
#      (exit 0 strict / 3 degraded / 2 none, stdout empty), --json's shape, no SEVERITY counting, the
#      provider-health ledger keeps ok/auth/quota but never an outcome of the INPUT (timeout, empty,
#      invalid), one adversarial.log row per lane (findings = the lane's uncovered rows), the
#      per-lane timeout clamped to 510 s, --help
#   N  the items Task 4 left: the whole-run deadline (timeout + grace + 60, never past 585 s whatever
#      the grace — a long grace shortens the per-lane timeout), a garbage/zero timeout, failure
#      evidence for a run whose only answers were invalid, --help's exit-code table, the no-lane ERROR
#      block naming --exclude-last and this mode's own exclusions, and a NOTE for --single/--rotate
# Mocks (tests/adversarial/mocks/mock-*) prove count and exit logic only; SPIES prove isolation. Every
# spy case asserts the spy's record exists before reading it, so a run that never dispatched cannot
# pass; every "did not run" assertion is paired with a lane that DID run in the same case.
#
# Hermetic: every driver run is `env -i` — a temp HOME/ZUVO_HOME/TMPDIR, the fixture CODEX_HOME with a
# DUMMY auth.json, ZUVO_CODEX_BIN/ZUVO_CODEX_APP_BIN=/nonexistent unless the case needs the codex spy,
# the provider-health bench off, every host signal absent unless the case sets one, and an explicit PATH
# of spies/mocks + symlinks to the real timeout/gtimeout/jq (tests/lib/hermetic-tools.sh). No real model
# CLI runs and nothing touches the network.
#
# Run (both shells; the DRIVER runs under the bash the narrowed PATH finds, /bin/bash):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-blind-audit.sh
#   TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/test-adversarial-blind-audit.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
AR="${ZUVO_TEST_AR:-$ROOT/scripts/adversarial-review.sh}"
LIB="$ROOT/scripts/lib/blind-audit-panel.sh"
ZMS="$ROOT/scripts/lib/model-subprocess.sh"
PROTO="$ROOT/shared/includes/blind-coverage-audit.md"
MOCKS="$ROOT/tests/adversarial/mocks"
FIXD="$ROOT/tests/hooks/fixtures/model-subprocess"
FXBA="$ROOT/tests/hooks/fixtures/blind-audit"
# agy's no-tool-use line, verbatim from the plan's Technical Decisions (the only wording tested live).
AGY_PREFIX='Do not invoke any tools, shell commands, or file operations. Respond with plain text only, using only the information given below.'
PASS=0; FAIL=0
ok()  { echo "  PASS $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
cut300() { if [ "${#1}" -gt 300 ]; then printf '%s…' "${1:0:300}"; else printf '%s' "$1"; fi; }
expect_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$(cut300 "$3")]"; fi; }
expect_has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — [$2] not found in [$(cut300 "$3")]" ;; esac; }
expect_not() { case "$3" in *"$2"*) bad "$1 — [$2] found in [$(cut300 "$3")]" ;; *) ok "$1" ;; esac; }

echo "== adversarial --mode blind-audit (test bash $BASH_VERSION) =="
[ -f "$AR" ] || { echo "  FAIL driver not found: $AR"; exit 1; }
[ -f "$LIB" ] || { echo "  FAIL panel library not found: $LIB"; exit 1; }
command -v shasum >/dev/null 2>&1 || { echo "  FAIL shasum required (every prompt comparison is a sha256)"; exit 1; }

# ── hermetic sandbox ─────────────────────────────────────────────────────────
T_LOG="$(mktemp -d)" || { echo "  FAIL mktemp -d failed"; exit 1; }
[ -n "$T_LOG" ] && [ -d "$T_LOG" ] || { echo "  FAIL mktemp -d returned no directory"; exit 1; }
trap 'rm -rf "$T_LOG"' EXIT
# Physical: the spies record `pwd -P`, so every path compared with theirs must be physical too.
T="$(cd "$T_LOG" && pwd -P)" && [ -n "$T" ] || { echo "  FAIL cannot resolve the sandbox path"; exit 1; }

SHIM="$T/shim"; mkdir -p "$SHIM"
# shellcheck source=tests/lib/hermetic-tools.sh
. "$ROOT/tests/lib/hermetic-tools.sh"
hermetic_link_tools "$SHIM" timeout:gtimeout gtimeout:timeout jq
[ -e "$SHIM/timeout" ] || { echo "  FAIL no GNU timeout on this machine — the driver cannot run"; exit 1; }
[ -e "$SHIM/jq" ] || { echo "  FAIL no jq on this machine — the driver cannot run"; exit 1; }

# The spy must see the OLDPWD a real client would get: macOS /bin/sh (bash 3.2) drops an inherited
# OLDPWD at startup, dash keeps it (same selection as the lane golden), and so does a bash of 4.4 or later
# (it keeps an inherited OLDPWD that names a directory) — the bash running this file, the one on PATH or a
# Homebrew one, tried after the sh/dash candidates so a host that has dash keeps using it. The spy body is
# POSIX sh, so any of them runs it. A host where none of them keeps OLDPWD cannot check the OLDPWD half of
# the isolation contract: the H cases below then FAIL, naming that, rather than skip it in silence.
keeps_oldpwd() { env OLDPWD=/ "$1" -c '[ "${OLDPWD:-}" = / ]' 2>/dev/null; }
SPY_SH=""
SPY_SH_TRIED="/bin/sh /bin/dash /usr/bin/dash ${BASH:-} $(command -v bash 2>/dev/null) /opt/homebrew/bin/bash /usr/local/bin/bash"
for _s in $SPY_SH_TRIED; do
  if [ -x "$_s" ] && keeps_oldpwd "$_s"; then SPY_SH="$_s"; break; fi
done
# no_oldpwd_check <label> — the loud stand-in for an OLDPWD assertion this host cannot make.
no_oldpwd_check() { bad "$1 — cannot be checked: no shell here keeps an inherited OLDPWD (tried: $SPY_SH_TRIED)"; }
# Put in front of the fixture spy's body: every call appends its first argument to <name>.calls, and
# the argv of the LAST call is kept NUL-separated in <name>.argv0 — agy takes the prompt as an
# argument, so its exact argv (element count included) can only be compared byte for byte.
# shellcheck disable=SC2016  # expanded by the spy, not here
SPY_PRE='[ -z "${SPY_DIR:-}" ] || { printf "%s\n" "${1:-}" >> "$SPY_DIR/${0##*/}.calls"; printf "%s\0" "$@" > "$SPY_DIR/${0##*/}.argv0"; } 2>/dev/null'
install_spy() {
  { if [ -n "$SPY_SH" ]; then printf '#!%s\n' "$SPY_SH"; else head -1 "$FIXD/spy-cli"; fi
    printf '%s\n' "$SPY_PRE"
    tail -n +2 "$FIXD/spy-cli"; } > "$1"
  chmod +x "$1"
}
SPY_BIN="$T/spybin"; WORK="$T/work"; SRC="$T/src"
mkdir -p "$SPY_BIN" "$WORK" "$SRC" "$T/tmp"
for _c in codex claude agy cursor-agent kimi muse qwen; do install_spy "$SPY_BIN/$_c"; done
FIX_CH="$T/codex-home"; cp -R "$FIXD/codex-home" "$FIX_CH"
BASE_PATH="$SHIM:/usr/bin:/bin"
MOCK_PATH="$MOCKS:$BASE_PATH"
SPY_PATH="$SPY_BIN:$MOCKS:$BASE_PATH"
H1="ZUVO_ADVERSARIAL_TEST_HARNESS=1"
# utf8_locale — an installed UTF-8 locale, spelled EXACTLY as `locale -a` lists it: glibc lists
# en_US.utf8 / C.utf8, macOS en_US.UTF-8 / C.UTF-8, and an exact `$0 == "en_US.UTF-8"` probe skipped
# every glibc host (the self-hosted Linux farm) although the locale was there. en_US first: its
# character classes are the fullest. Empty when none is installed. A glibc `@modifier` spelling
# (en_US.utf8@x) counts too, after the plain spelling of the same name. utf8_pick is the choice alone,
# reading a `locale -a` listing on stdin, so the checks below can feed it fixed lists.
utf8_pick() {
  awk '{ l = tolower($0); m = sub(/@[a-z0-9_-]+$/, "", l) }
    l ~ /^en_us\.utf-?8$/ && en[m] == "" { en[m] = $0 }
    l ~ /^c\.utf-?8$/ && c[m] == "" { c[m] = $0 }
    END { print ((en[0] != "") ? en[0] : ((en[1] != "") ? en[1] : ((c[0] != "") ? c[0] : c[1]))) }'
}
utf8_locale() { locale -a 2>/dev/null | utf8_pick; }
U8="$(utf8_locale)"
# locale_skip <what> — the LOUD stand-in for a case this host cannot run (no UTF-8 locale installed): a
# column-0 "SKIP: … did NOT run" line — the shape scripts/dev-push.sh's dark-gate scan reports before a release
# (an indented "  SKIP" reached no one) — counted, and totalled as NOT TESTED beside the RESULT line.
LOCALE_SKIPS=0
locale_skip_line() { printf 'SKIP: %s did NOT run — no UTF-8 locale (en_US / C, any spelling) is installed on this machine\n' "$1"; }
locale_skip() { locale_skip_line "$1"; LOCALE_SKIPS=$((LOCALE_SKIPS + 1)); }
# The pattern the release gate greps the suite log with, read from dev-push.sh itself, not restated.
DARK_RE="$(sed -n "s/.*_dark=\$(grep -E '\([^']*\)'.*/\1/p" "$ROOT/scripts/dev-push.sh" 2>/dev/null | head -1)"
expect_eq "helper: a locale_skip line is one dev-push.sh's dark-gate scan reports (pattern read: ${DARK_RE:-none})" "1" \
  "$([ -n "$DARK_RE" ] && locale_skip_line "X" | grep -cE -- "$DARK_RE")"
expect_eq "helper: utf8_pick accepts a @modifier spelling when it is the only en_US one" "en_US.utf8@x" \
  "$(printf '%s\n' C POSIX en_US.utf8@x | utf8_pick)"
expect_eq "helper: utf8_pick prefers the plain spelling to a @modifier one" "en_US.UTF-8" \
  "$(printf '%s\n' en_US.UTF-8@x en_US.UTF-8 | utf8_pick)"
expect_eq "helper: utf8_pick skips a look-alike, falls back to C.UTF-8" "C.UTF-8" \
  "$(printf '%s\n' en_US.UTF-8x en_US.UTF-8@ C.UTF-8 | utf8_pick)"
# A `sleep` that logs its argv (one line per call) and execs the real one: the whole-run watchdog is
# `( sleep "$RUN_DEADLINE"; … kill -TERM )`, so the deadline the driver ARMED — not only the one it
# announced — is the one `sleep` line equal to it. And a lane that answers only after
# MOCK_SLOW_SECONDS (default 1): a run that must outlive a would-be deadline, or must still be running
# when the watchdog's `sleep` starts, cannot use an instantly-answering mock.
REAL_SLEEP="$(PATH=/bin:/usr/bin command -v sleep)"
SSHIM="$T/sshim"; SLOWM="$T/slowmock"; mkdir -p "$SSHIM" "$SLOWM"
printf '#!/bin/sh\n[ -z "${SLEEP_ARGV_LOG:-}" ] || printf "%%s\\n" "$*" >> "$SLEEP_ARGV_LOG"\nexec "${REAL_SLEEP:-/bin/sleep}" "$@"\n' > "$SSHIM/sleep"
printf '#!/bin/sh\nsleep "${MOCK_SLOW_SECONDS:-1}"\nexec mock-strict-clean\n' > "$SLOWM/mock-strict-slow"
chmod +x "$SSHIM/sleep" "$SLOWM/mock-strict-slow"
SLOW_PATH="$SSHIM:$SLOWM:$MOCK_PATH"
_st=0; SLEEP_ARGV_LOG="$T/premise.sleeps" REAL_SLEEP="$REAL_SLEEP" "$SSHIM/sleep" 0 || _st=$?
expect_eq "premise: the sleep shim logs its argv and still sleeps (the real one ran: status 0)" "0|0" "$_st|$(cat "$T/premise.sleeps" 2>/dev/null)"
# sleeps <tag> — the arguments `sleep` was called with during that run, one per line.
sleeps() { cat "$T/$1.sleeps" 2>/dev/null; }
if [ -n "$SPY_SH" ]; then echo "  note: spy interpreter $SPY_SH (keeps an inherited OLDPWD)"
else echo "  note: no shell here keeps an inherited OLDPWD — the OLDPWD checks FAIL below (tried: $SPY_SH_TRIED)"; fi

# ── the file pair under audit ────────────────────────────────────────────────
P="$SRC/sum.sh"; TT="$SRC/sum.test.sh"; EMPTYF="$SRC/empty.sh"
printf '#!/bin/sh\nsum_or_zero() {\n  [ -z "$1" ] && { echo 0; return 0; }\n  t=0; for n in $1; do t=$((t + n)); done\n  echo "$t"\n}\n' > "$P"
printf '#!/bin/sh\n. ./sum.sh\n[ "$(sum_or_zero "1 2 3")" = 6 ] || exit 1\n' > "$TT"
: > "$EMPTYF"
# The --mode code input the code-mode and dry-run cases redirect to stdin: one real diff, written here once
# and never changed, so no case depends on another having written it (each copies it to its own <tag>.in).
CODE_DIFF="$SRC/code.diff"; printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n' > "$CODE_DIFF"
# 100-byte lines: 60000 bytes is twice the code mode's 30000-char cap; 130000 is over the 120000-byte
# argv limit; 400001 is one byte over the 400000-byte refusal limit.
lines100() { LC_ALL=C awk -v n="$1" 'BEGIN { for (j = 0; j < 85; j++) x = x "x"; for (i = 1; i <= n; i++) printf "# line %06d %s\n", i, x }'; }
BIG60="$SRC/big60k.sh";  lines100 600  > "$BIG60"
BIG130="$SRC/big130k.sh"; lines100 1300 > "$BIG130"
HUGE="$SRC/huge.sh"; { lines100 4000; printf 'x'; } > "$HUGE"
# 70000 × U+017C: 70000 CHARACTERS (under the limit if counted as chars) but 140000 BYTES (over it).
MBF="$SRC/multibyte.sh"; LC_ALL=C awk 'BEGIN { for (i = 0; i < 70000; i++) printf "\305\274"; printf "\n" }' > "$MBF"
_sz() { wc -c < "$1" | tr -d ' '; }
expect_eq "premise: the 60k file is 60000 bytes"   "60000"  "$(_sz "$BIG60")"
expect_eq "premise: the 130k file is 130000 bytes" "130000" "$(_sz "$BIG130")"
expect_eq "premise: the huge file is 400001 bytes" "400001" "$(_sz "$HUGE")"
expect_eq "premise: the multi-byte file is 140001 bytes" "140001" "$(_sz "$MBF")"

# The prompt the panel must receive, built by the library the driver loads (sourced in a clean shell).
prompt_of() { env -i PATH=/usr/bin:/bin HOME="$T" bash -c '. "$1" && bap_build_prompt "$2" "$3" "$4"' _ "$LIB" "$PROTO" "$1" "$2"; }
sha_of() { shasum -a 256 < "$1" | cut -d' ' -f1; }

# drive <tag> <PATH> [VAR=value ...] -- <driver args...> — one driver run from $WORK under `env -i`.
# HOME=$T/home-<tag> (a case may seed it first); stdin = $T/<tag>.in when present, a PIPE from
# $T/<tag>.pipe when present, else /dev/null. Output in $T/<tag>.out / .err; mocks log their calls to
# $T/<tag>.calls. DRIVE_AR runs another driver copy. Later VAR=value pairs override the defaults.
drive() {
  local tag="$1" path="$2" h="$T/home-$1" in=/dev/null rc=0 envs=(); shift 2
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  mkdir -p "$h"
  [ -f "$T/$tag.in" ] && in="$T/$tag.in"
  if [ -f "$T/$tag.pipe" ]; then
    # Under this file's own `set -o pipefail`, `rc=$?` after the pipeline would read CAT's exit code
    # (via pipefail) if cat ever failed on its own, not the driver's — PIPESTATUS[1] names the driver
    # subshell (the pipeline's second stage) directly, regardless of what cat did.
    cat "$T/$tag.pipe" | ( cd "$WORK" && env -i HOME="$h" ZUVO_HOME="$h/.zuvo" TMPDIR="$T/tmp" CODEX_HOME="$FIX_CH" \
        ZUVO_NO_CAFFEINATE=1 ZUVO_PROVIDER_BENCH=0 ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
        MOCK_CALL_LOG="$T/$tag.calls" PATH="$path" ${envs[@]+"${envs[@]}"} bash "${DRIVE_AR:-$AR}" "$@" ) \
      > "$T/$tag.out" 2> "$T/$tag.err"
    rc="${PIPESTATUS[1]}"
  else
    ( cd "$WORK" && env -i HOME="$h" ZUVO_HOME="$h/.zuvo" TMPDIR="$T/tmp" CODEX_HOME="$FIX_CH" \
        ZUVO_NO_CAFFEINATE=1 ZUVO_PROVIDER_BENCH=0 ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
        MOCK_CALL_LOG="$T/$tag.calls" PATH="$path" ${envs[@]+"${envs[@]}"} bash "${DRIVE_AR:-$AR}" "$@" ) \
      < "$in" > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  fi
  return "$rc"
}
out() { cat "$T/$1.out" 2>/dev/null; }
err() { cat "$T/$1.err" 2>/dev/null; }
calls() { tr '\n' ' ' 2>/dev/null < "$T/$1.calls" | sed 's/ $//'; }
ncalls() { if [ -f "$T/$1.calls" ]; then wc -l < "$T/$1.calls" | tr -d ' '; else echo 0; fi; }
# spy_dir <tag> — a fresh spy record dir for one run.
spy_dir() { rm -rf "$T/spy-$1"; mkdir -p "$T/spy-$1"; printf '%s' "$T/spy-$1"; }
rec() { printf '%s' "$T/spy-$1/$2.rec"; }
# rec_calls <tag> <name> — the spy's OWN invocation-attempt log (SPY_PRE writes this before .rec, on
# every attempt including a crashed/partial one). ".rec absent" alone only proves "did not COMPLETE" —
# a "never ran" assertion should check this too, so a spy invoked but killed mid-run is not misreported
# as never having run at all.
rec_calls() { printf '%s' "$T/spy-$1/$2.calls"; }
# rec_get <rec> <key> — the first value recorded under <key>.
rec_get() { awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$1" 2>/dev/null; }
# rec_args <rec> — the recorded argv, one `arg=` element per line (a multi-line element is cut to its first line).
rec_args() { awk '/^arg=/ { print substr($0, 5) }' "$1" 2>/dev/null; }
# neutral <path> — a physical directory a lane may run in: not the checkout under review, not inside it,
# not the repository holding this test, not HOME.
neutral() {
  case "$1" in ''|"$WORK"|"$WORK"/*|"$ROOT"|"$ROOT"/*) return 1 ;; esac
  case "$1" in "$T"/home-*) return 1 ;; esac
  return 0
}

# ═══ A. input ════════════════════════════════════════════════════════════════
echo "-- A. input: flags, rejections, list, gates, library lookup"
rc=0; drive a1 "$MOCK_PATH" "$H1" -- --mode blind-audit --provider mock-strict-clean || rc=$?
expect_eq "A1 --mode blind-audit without --production/--test → exit 2" "2" "$rc"
expect_has "A1 …and stderr names --production" "--production" "$(err a1)"
expect_eq "A1 …and no lane ran" "0" "$(ncalls a1)"
rc=0; drive a1b "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$P" --provider mock-strict-clean || rc=$?
expect_eq "A1b --production without --test → exit 2" "2" "$rc"
expect_has "A1b …and stderr names --test" "--test" "$(err a1b)"

rc=0; drive a2 "$MOCK_PATH" "$H1" -- --production "$P" --test "$TT" --provider mock-strict-clean || rc=$?
expect_eq "A2 --production/--test outside the mode (default code) → exit 2" "2" "$rc"
expect_has "A2 …and stderr says they belong to --mode blind-audit" "blind-audit" "$(err a2)"
expect_eq "A2 …and no lane ran" "0" "$(ncalls a2)"
rc=0; drive a2b "$MOCK_PATH" "$H1" -- --mode security --test "$TT" --provider mock-strict-clean || rc=$?
expect_eq "A2b --test with --mode security → exit 2" "2" "$rc"
rc=0; drive a2c "$MOCK_PATH" "$H1" -- --mode code --protocol "$PROTO" --provider mock-strict-clean || rc=$?
expect_eq "A2c --protocol with --mode code → exit 2" "2" "$rc"

BA=(--mode blind-audit --production "$P" --test "$TT")
rc=0; drive a3f "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean --files "$P" || rc=$?
expect_eq "A3 --files in the mode → exit 2" "2" "$rc"
expect_eq "A3 --files refused …and no lane ran" "0" "$(ncalls a3f)"
rc=0; drive a3fi "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean --file "$P" || rc=$?
expect_eq "A3 --file in the mode → exit 2" "2" "$rc"
rc=0; drive a3d "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean --diff HEAD~1 || rc=$?
expect_eq "A3 --diff in the mode → exit 2" "2" "$rc"
rc=0; drive a3a "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean --artifact "$T/art-a3.txt" || rc=$?
expect_eq "A3 --artifact in the mode → exit 2" "2" "$rc"
if [ -e "$T/art-a3.txt" ]; then bad "A3 …and no artifact is written"; else ok "A3 …and no artifact is written"; fi
rc=0; drive a3p "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean --append-artifact || rc=$?
expect_eq "A3 --append-artifact in the mode → exit 2" "2" "$rc"
printf 'diff --git a/x b/x\n+x\n' > "$T/a3s.pipe"
rc=0; drive a3s "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A3 a diff piped on stdin in the mode → exit 2" "2" "$rc"
expect_has "A3 …and stderr says stdin is not read here" "stdin" "$(err a3s)"
expect_eq "A3 piped stdin refused …and no lane ran" "0" "$(ncalls a3s)"
printf 'diff --git a/x b/x\n+x\n' > "$T/a3r.in"
rc=0; drive a3r "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A3 a file redirected to stdin in the mode → exit 2" "2" "$rc"
# ADV-A18 / P2-12: the stdin-refusal probe is bash's own bounded `read`, so it runs on a PATH with no
# `timeout` at all — it used to need `timeout head -c 1` and, without it, only NOTEd and skipped the
# check. A PATH with no timeout is BUILT, not assumed: `$MOCKS:/usr/bin:/bin` still has one on most
# Linux hosts (GNU coreutils puts it in /usr/bin), which would test nothing there — so every tool of
# /usr/bin and /bin is linked into a dir of our own, minus timeout/gtimeout, and that is a premise.
NOTMO_BIN="$T/notmo-bin"; mkdir -p "$NOTMO_BIN"
for _d in /usr/bin /bin; do ln -s "$_d"/* "$NOTMO_BIN"/ 2>/dev/null; done   # a name in both: the first wins
rm -f "$NOTMO_BIN/timeout" "$NOTMO_BIN/gtimeout"
NOTMO="$MOCKS:$NOTMO_BIN"
expect_eq "A18 premise: the narrowed PATH has no timeout/gtimeout, but has bash" "|yes" \
  "$(env -i PATH="$NOTMO" /bin/sh -c 'command -v timeout; command -v gtimeout' 2>/dev/null)|$([ -e "$NOTMO_BIN/bash" ] && echo yes)"
printf 'diff --git a/x b/x\n+x\n' > "$T/a18.pipe"
rc=0; drive a18 "$NOTMO" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A18 blind-audit, stdin has data and NO timeout on PATH → still refused, exit 2" "2" "$rc"
expect_has "A18 …stderr says it refuses stdin (the check ran without timeout)" "refusing stdin" "$(err a18)"
expect_not "A18 …and no 'timeout is unavailable' skip NOTE any more" "'timeout' is unavailable" "$(err a18)"
expect_eq "A18 stdin data, no timeout on PATH …and no lane ran" "0" "$(ncalls a18)"
: > "$T/a18e.pipe"   # a pipe that closes with nothing on it: EOF, not data
rc=0; drive a18e "$NOTMO" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_not "A18 control: an EMPTY pipe (no timeout on PATH) is not refused as stdin data" "refusing stdin" "$(err a18e)"
expect_has "A18 control: …the run goes on to the driver's own timeout requirement" "GNU timeout required" "$(err a18e)"
# A NUL first byte is data too: `$(… head -c 1)` dropped it (bash strips NULs from a substitution) and
# waved the input through; `read -d ''` sees it.
printf '\000' > "$T/a18n.pipe"
rc=0; drive a18n "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A18 a lone NUL byte on stdin → refused, exit 2" "2" "$rc"
expect_has "A18 …stderr says it refuses stdin" "refusing stdin" "$(err a18n)"
expect_eq "A18 a lone NUL on stdin …and no lane ran" "0" "$(ncalls a18n)"
# Control: the rejections above are about the flags, not about the run — the same run without them works.
rc=0; drive a3ok "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A3 control: the same run without the refused input runs its lane (exit 3)" "3" "$rc"
expect_eq "A3 control: …the lane ran once" "mock-strict-clean" "$(calls a3ok)"

rc=0; drive a4 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean codex-5.3 cursor-agent muse" \
  -- --list-providers --mode blind-audit || rc=$?
expect_eq "A4 --list-providers --mode blind-audit needs no --production/--test → exit 0" "0" "$rc"
expect_eq "A4 …and prints the panel candidates (cursor-agent/muse are never candidates here)" \
  "mock-strict-clean codex-5.3" "$(out a4 | tr '\n' ' ' | sed 's/ $//')"
expect_eq "A4 …and runs no lane" "0" "$(ncalls a4)"

# Byte-identity with HEAD. Captured from the UNMODIFIED driver (HEAD 35b9d7cf, 2026-09-27) under
# exactly these environments, before --mode blind-audit existed: `--list-providers` without the mode
# must not move by a byte — reviewer-preflight.sh parses it.
LIST_ENV=(ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_ADV_QWEN=1)
HEAD_LIST_NOHOST="$(printf 'cursor-agent\nagy\ncodex-5.3\nclaude\nmuse\nkimi\nqwen\n_')"
HEAD_LIST_HARNESS="$(printf 'codex-5.3\ncursor-agent\nmuse\nmock-strict-clean\n_')"
for _v in nohost:: claude:CLAUDECODE=1: harness:"$H1":; do
  _tag="a5-${_v%%:*}"; _e="${_v#*:}"; _e="${_e%:}"
  _envs=("${LIST_ENV[@]}"); [ -n "$_e" ] && _envs+=("$_e")
  [ "$_tag" = a5-harness ] && _envs+=(ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 cursor-agent muse mock-strict-clean")
  rc=0; drive "$_tag" "$SPY_PATH" "${_envs[@]}" -- --list-providers || rc=$?
  expect_eq "A5 --list-providers (no mode, ${_v%%:*}) → exit 0" "0" "$rc"
  _want="$HEAD_LIST_NOHOST"; [ "$_tag" = a5-harness ] && _want="$HEAD_LIST_HARNESS"
  expect_eq "A5 …stdout byte-identical to HEAD's (${_v%%:*})" "$_want" "$(cat "$T/$_tag.out"; printf _)"
done

cp "$EMPTYF" "$SRC/empty.test.sh"
rc=0; drive a6 "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$EMPTYF" --test "$TT" --provider mock-strict-clean || rc=$?
expect_eq "A6 an empty production file → exit 5" "5" "$rc"
expect_eq "A6 …and no lane ran" "0" "$(ncalls a6)"
rc=0; drive a6b "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$P" --test "$SRC/empty.test.sh" --provider mock-strict-clean || rc=$?
expect_eq "A6b an empty test file → exit 5" "5" "$rc"
rc=0; drive a6c "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$SRC/nope.sh" --test "$TT" --provider mock-strict-clean || rc=$?
expect_eq "A6c a production file that does not exist → exit 2 (a usage error, not 'empty')" "2" "$rc"
expect_has "A6c …and stderr names the path" "nope.sh" "$(err a6c)"
expect_eq "A6c …and no lane ran" "0" "$(ncalls a6c)"
# A NUL byte cannot travel in a bash variable: the prompt would silently lose everything after it.
printf 'sum() { echo 1; }\n\000# after the NUL byte\n' > "$SRC/nul.sh"; cp "$SRC/nul.sh" "$SRC/nul.test.sh"
rc=0; drive a6d "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$SRC/nul.sh" --test "$TT" --provider mock-strict-clean || rc=$?
expect_eq "A6d a production file holding a NUL byte → exit 2" "2" "$rc"
expect_has "A6d …stderr says binary input" "binary input" "$(err a6d)"
expect_has "A6d …and names the file" "nul.sh" "$(err a6d)"
expect_eq "A6d …and no lane ran" "0" "$(ncalls a6d)"
rc=0; drive a6e "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$P" --test "$SRC/nul.test.sh" --provider mock-strict-clean || rc=$?
expect_eq "A6e a test file holding a NUL byte → exit 2, no lane ran" "2|0" "$rc|$(ncalls a6e)"
expect_has "A6e …stderr says binary input and names the test file" "nul.test.sh" "$(err a6e | awk '/binary input/')"

SD="$(spy_dir a7)"
rc=0; drive a7 "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_BLIND_AUDIT_PANEL=5 \
  ZUVO_REVIEW_TEST_PROVIDERS="agy codex-5.3 mock-strict-clean" -- --mode blind-audit --production "$HUGE" --test "$TT" || rc=$?
expect_eq "A7 a 400001-byte production file → exit 6" "6" "$rc"
expect_eq "A7 …and no mock lane was invoked" "0" "$(ncalls a7)"
if [ -e "$(rec a7 agy)" ] || [ -e "$(rec a7 codex)" ]; then bad "A7 …and no spy lane was invoked (a .rec exists)"
else ok "A7 …and no spy lane was invoked (no .rec)"; fi
expect_has "A7 …and stderr names the byte limit" "400000" "$(err a7)"

printf 'no strict marker here\n' > "$SRC/bad-protocol.md"
rc=0; drive a8 "$MOCK_PATH" "$H1" -- "${BA[@]}" --protocol "$SRC/bad-protocol.md" --provider mock-strict-clean || rc=$?
expect_eq "A8 --protocol without an 'Audit mode: strict' line → exit 2" "2" "$rc"
expect_eq "A8 …and no lane ran" "0" "$(ncalls a8)"
# A protocol that DIFFERS from the repo's (one extra last line): a driver that ignored --protocol would
# still hand over a prompt starting with the repo protocol's first line.
{ cat "$PROTO"; printf 'Custom protocol marker: a8b-7f3a (this copy only)\n'; } > "$SRC/own-protocol.md"
mkdir -p "$T/a8b-stdin"
rc=0; drive a8b "$MOCK_PATH" "$H1" MOCK_STDIN_DIR="$T/a8b-stdin" ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt mock-strict-clean" \
  -- "${BA[@]}" --protocol "$SRC/own-protocol.md" || rc=$?
_pn="$(_sz "$SRC/own-protocol.md")"
head -c "$_pn" "$T/a8b-stdin/mock-echo-prompt.stdin" > "$T/a8b-head" 2>/dev/null
if cmp -s "$SRC/own-protocol.md" "$T/a8b-head"; then ok "A8b the lane's prompt begins with the WHOLE --protocol file, byte for byte"
else bad "A8b the lane's prompt does not begin with the whole --protocol file ($(_sz "$T/a8b-head" 2>/dev/null || echo 0) of $_pn bytes match-checked)"; fi
expect_eq "A8b …and the production file's header follows it" "=== PRODUCTION FILE: sum.sh ===" \
  "$(tail -c +"$((_pn + 1))" "$T/a8b-stdin/mock-echo-prompt.stdin" 2>/dev/null | sed -n 2p)"
expect_eq "A8b the audit completed: one valid answer of two → exit 3" "3" "$rc"
expect_eq "A8b …the merged block is printed (line 1)" "Audit mode: strict" "$(out a8b | sed -n 1p)"
expect_has "A8b …with its panel line" "Audit panel: degraded valid=1/2" "$(out a8b | sed -n 2p)"

# The library next to the driver is not the only place it can come from, and without it only THIS mode
# refuses. A lone copy of the driver — its own modules, no panel library or shared runner beside it, no
# ~/.zuvo copy in the temp HOME.
. "$ROOT/tests/lib/adversarial-driver.sh"
LONE="$T/lone"; adv_driver_copy "$AR" "$LONE/adversarial-review.sh" || bad "A9 premise: copying the driver and its modules failed"
rc=0; DRIVE_AR="$LONE/adversarial-review.sh" drive a9 "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A9 library missing → --mode blind-audit exits 2" "2" "$rc"
expect_has "A9 …naming the file it looked for" "blind-audit-panel.sh" "$(err a9)"
expect_eq "A9 …and no lane ran" "0" "$(ncalls a9)"
cp "$CODE_DIFF" "$T/a9c.in"
rc=0; DRIVE_AR="$LONE/adversarial-review.sh" drive a9c "$MOCK_PATH" "$H1" -- --mode code --dry-run --provider mock-strict-clean || rc=$?
expect_eq "A9 …while --mode code is unaffected (dry run exits 0)" "0" "$rc"
expect_not "A9 …and does not even mention the panel library" "blind-audit-panel" "$(err a9c)"
# Installed layout: the library (and the shared runner) in ~/.zuvo. Without the protocol there the mode
# still refuses — naming the protocol; with it, the panel runs.
mkdir -p "$T/home-a9i/.zuvo" "$T/home-a9j/.zuvo"
cp "$LIB" "$ZMS" "$T/home-a9i/.zuvo/"; cp "$LIB" "$ZMS" "$PROTO" "$T/home-a9j/.zuvo/"
rc=0; DRIVE_AR="$LONE/adversarial-review.sh" drive a9i "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A9 library in ~/.zuvo but no protocol anywhere → exit 2" "2" "$rc"
expect_has "A9 …naming the protocol" "blind-coverage-audit.md" "$(err a9i)"
rc=0; DRIVE_AR="$LONE/adversarial-review.sh" drive a9j "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A9 library + protocol in ~/.zuvo → the lone driver runs the panel (exit 3)" "3" "$rc"
expect_has "A9 …and prints the panel line" "Audit panel: degraded valid=1/1" "$(out a9j)"
# An INCOMPLETE library candidate (adversarial-blind-audit.sh ar_ba_setup, the candidate loop): a file that
# exists but does not leave every bap_* function the driver calls defined is skipped with
# "  WARN: <file> exists but does not define the panel functions — trying the next candidate", and the next
# candidate is tried. Each candidate is sourced after `unset -f` of all of them, so a later partial file cannot
# pass on functions an earlier one left behind. Two more lone copies, each with its own candidates:
#   A9w — lib/: the WHOLE library and then `return 1` (everything defined, but the source fails); next to the
#         driver: a file defining bap_find_protocol only; ~/.zuvo: the real library, runner and protocol.
#         Both local files are refused, in lookup order, and the ~/.zuvo library runs the panel.
#   A9x — lib/: bap_find_protocol only, and no other candidate → the mode refuses, exit 2, no lane ran.
LONEW="$T/lone-w"; adv_driver_copy "$AR" "$LONEW/adversarial-review.sh" || bad "A9w premise: copying the driver and its modules failed"
mkdir -p "$LONEW/lib" "$T/home-a9w/.zuvo"
{ cat "$LIB"; printf '\nreturn 1\n'; } > "$LONEW/lib/blind-audit-panel.sh"
printf 'bap_find_protocol() { echo /nonexistent; }\n' > "$LONEW/blind-audit-panel.sh"
cp "$LIB" "$ZMS" "$PROTO" "$T/home-a9w/.zuvo/"
rc=0; DRIVE_AR="$LONEW/adversarial-review.sh" drive a9w "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A9w two incomplete local candidates, the real library in ~/.zuvo → the panel runs (exit 3)" "3" "$rc"
expect_eq "A9w …exactly two WARNs, the lib/ candidate first, then the one next to the driver" \
  "  WARN: $LONEW/lib/blind-audit-panel.sh exists but does not define the panel functions — trying the next candidate|  WARN: $LONEW/blind-audit-panel.sh exists but does not define the panel functions — trying the next candidate" \
  "$(err a9w | awk '/WARN: .*blind-audit-panel/' | paste -sd '|' -)"
expect_eq "A9w …and the lane ran once, on the ~/.zuvo library" "mock-strict-clean" "$(calls a9w)"
expect_has "A9w …which printed the panel line" "Audit panel: degraded valid=1/1" "$(out a9w | sed -n 2p)"
LONEX="$T/lone-x"; adv_driver_copy "$AR" "$LONEX/adversarial-review.sh" || bad "A9x premise: copying the driver and its modules failed"
mkdir -p "$LONEX/lib"
printf 'bap_find_protocol() { echo /nonexistent; }\n' > "$LONEX/lib/blind-audit-panel.sh"
rc=0; DRIVE_AR="$LONEX/adversarial-review.sh" drive a9x "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A9x the only candidate is incomplete → exit 2 (never run on a partial library)" "2" "$rc"
expect_eq "A9x …one WARN names it" \
  "  WARN: $LONEX/lib/blind-audit-panel.sh exists but does not define the panel functions — trying the next candidate" \
  "$(err a9x | awk '/WARN: .*blind-audit-panel/')"
expect_has "A9x …then the ERROR that none loaded" "ERROR: --mode blind-audit needs blind-audit-panel.sh — none loaded from $LONEX/lib/" "$(err a9x)"
expect_eq "A9x …and no lane ran" "0" "$(ncalls a9x)"

# A10 — a helper the setup calls FAILS (adversarial-blind-audit.sh ar_ba_setup, each `|| exit 2`: :64
# bap_build_prompt, :66 bap_bytes on the prompt, :67 bap_size_class, :73 bap_bytes on agy's argument): the
# mode stops there with exit 2 — nothing on stdout, no lane run, no run log — and says nothing of its own
# beyond the helper's message. bap_bytes and bap_size_class cannot fail on input the driver can be handed
# (bap_bytes counts what it is piped; bap_size_class is handed bap_bytes' digits), so their failure is
# INJECTED: a lone driver copy whose lib/ holds the real library plus an override of ONE helper that fails
# on its <nth> call (an earlier call runs the real one), the shared runner beside it, --protocol given.
# ba_inject <dir> <fn> <nth> [<stdout>] — that copy; every call of <fn> is counted in <dir>/<fn>.count, and the
# failing call prints <stdout> (a word, default nothing) before it fails — what a caller must not keep.
ba_inject() {
  adv_driver_copy "$AR" "$1/adversarial-review.sh" || { bad "A10 premise: copying the driver and its modules failed ($1)"; return 1; }
  cp "$ZMS" "$1/lib/"
  { cat "$LIB"
    printf '\neval "$(declare -f %s | sed "1s/^%s /_ba_real_%s /")"\n' "$2" "$2" "$2"
    printf '%s() { local n; n=$(( $(cat "%s" 2>/dev/null || echo 0) + 1 )); echo "$n" > "%s"\n' "$2" "$1/$2.count" "$1/$2.count"
    printf '  if [ "$n" -eq %s ]; then echo "INJECTED: %s fails on call $n" >&2; printf %%s "%s"; return 1; fi\n' "$3" "$2" "${4:-}"
    printf '  _ba_real_%s "$@"\n}\n' "$2"
  } > "$1/lib/blind-audit-panel.sh"
}
# ba_stopped <tag> <label> <fn> <nth> — exit 2 at that call: the injected line is the only thing on stderr that
# is not an indented NOTE/WARN, <fn> ran exactly <nth> times (so it was THAT call site), no lane ran, stdout
# is empty and no run log was opened.
ba_stopped() {
  expect_eq "$2 → exit 2" "2" "$rc"
  expect_eq "$2 …stderr holds the helper's failure and no other ERROR" "INJECTED: $3 fails on call $4" \
    "$(err "$1" | grep -v '^  ' | paste -sd '|' -)"
  expect_eq "$2 …$3 ran exactly $4 time(s): it stopped at that call" "$4" "$(cat "$T/$1/$3.count" 2>/dev/null)"
  expect_eq "$2 …no lane ran, stdout is empty, no run log" "0|0|absent" \
    "$(ncalls "$1")|$(_sz "$T/$1.out")|$([ -e "$T/home-$1/.zuvo/adversarial.log" ] && echo present || echo absent)"
}
for _v in a10b:bap_bytes:1:":66, the prompt's size" a10s:bap_size_class:1:":67, the prompt's size class" \
          a10a:bap_bytes:2:":73, agy's argument size" a10p:bap_build_prompt:1:":64, the prompt"; do
  _tag="${_v%%:*}"; _r="${_v#*:}"; _fn="${_r%%:*}"; _r="${_r#*:}"; _nth="${_r%%:*}"; _what="${_r#*:}"
  ba_inject "$T/$_tag" "$_fn" "$_nth" || continue
  rc=0; DRIVE_AR="$T/$_tag/adversarial-review.sh" drive "$_tag" "$MOCK_PATH" "$H1" -- "${BA[@]}" --protocol "$PROTO" \
    --provider mock-strict-clean || rc=$?
  ba_stopped "$_tag" "A10 $_fn fails at $_what" "$_fn" "$_nth"
done
# The control: the same injected copy, the failure set on a call that never comes — the panel runs (exit 3),
# so the copies above stopped at the injected failure, not at the layout.
ba_inject "$T/a10ctl" bap_bytes 99 && {
  rc=0; DRIVE_AR="$T/a10ctl/adversarial-review.sh" drive a10ctl "$MOCK_PATH" "$H1" -- "${BA[@]}" --protocol "$PROTO" \
    --provider mock-strict-clean || rc=$?
  expect_eq "A10 control: the injected copy, no call failing → the lane runs (exit 3), bap_bytes ran twice" "3|mock-strict-clean|2" \
    "$rc|$(calls a10ctl)|$(cat "$T/a10ctl/bap_bytes.count" 2>/dev/null)"
}
# bap_build_prompt's other refusal, reached without an injection: a production file NAME holding a control
# character (a newline) — status 2 from the library, exit 2 from the driver, no lane run.
_cf="$SRC/sum"$'\n'"x.sh"; cp "$P" "$_cf"
rc=0; drive a10n "$MOCK_PATH" "$H1" -- --mode blind-audit --production "$_cf" --test "$TT" --provider mock-strict-clean || rc=$?
expect_eq "A10 a production file name holding a newline → exit 2, no lane ran, stdout empty" "2|0|0" "$rc|$(ncalls a10n)|$(_sz "$T/a10n.out")"
expect_has "A10 …refused by bap_build_prompt by name" "bap_build_prompt: a file name holds a control character — refused" "$(err a10n)"

# ═══ B. a panel of one ═══════════════════════════════════════════════════════
echo "-- B. --provider <lane> in this mode"
rc=0; drive b1 "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "B1 --provider mock-strict-clean → exit 3 (one valid answer = degraded)" "3" "$rc"
expect_eq "B1 …exactly that one lane ran, once" "mock-strict-clean" "$(calls b1)"
expect_eq "B1 …stdout line 1 is 'Audit mode: strict'" "Audit mode: strict" "$(out b1 | sed -n 1p)"
expect_has "B1 …line 2 is the panel line" "Audit panel: degraded valid=1/1" "$(out b1 | sed -n 2p)"
expect_has "B1 …the verdict is the lane's" "Coverage verdict: CLEAN" "$(out b1)"
SD="$(spy_dir b2)"
rc=0; drive b2 "$SPY_PATH" "$H1" SPY_DIR="$SD" -- "${BA[@]}" --provider cursor-agent || rc=$?
expect_eq "B2 --provider cursor-agent (isolation never proven) → no lane left, exit 1" "1" "$rc"
if [ -e "$(rec b2 cursor-agent)" ] || [ -e "$(rec_calls b2 cursor-agent)" ]; then bad "B2 …and cursor-agent never ran"; else ok "B2 …and cursor-agent never ran"; fi
expect_has "B2 …and stderr names it" "cursor-agent" "$(err b2)"
# mock-* lanes are the test harness's (run_mock's own gate): outside it the allowlist admits none.
rc=0; drive b3 "$MOCK_PATH" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "B3 without ZUVO_ADVERSARIAL_TEST_HARNESS a mock-* lane is not admitted → exit 1" "1" "$rc"
expect_has "B3 …stderr names it as excluded" "mock-strict-clean" "$(err b3 | awk '/xclud/')"
expect_eq "B3 …and it never ran" "0" "$(ncalls b3)"
# A global ZUVO_REVIEW_PROVIDER (a pin meant for code reviews) must not shrink the panel to one lane.
rc=0; drive b4 "$MOCK_PATH" "$H1" ZUVO_REVIEW_PROVIDER=mock-strict-clean \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite" -- "${BA[@]}" || rc=$?
expect_eq "B4 ZUVO_REVIEW_PROVIDER set: the whole panel still ran (3 lanes)" "3" "$(ncalls b4)"
expect_eq "B4 …a strict panel, exit 0" "0" "$rc"
expect_has "B4 …stderr says the variable is ignored in this mode" "ZUVO_REVIEW_PROVIDER" "$(err b4 | awk '/gnored/')"

# ═══ C. the whole file reaches the lane ═════════════════════════════════════
echo "-- C. whole files, no cap / chunk / truncation; agy's exact argv"
prompt_of "$BIG60" "$TT" > "$T/c-expected.prompt"
SD="$(spy_dir c1)"; mkdir -p "$T/c1-stdin"
rc=0; drive c1 "$SPY_PATH" "$H1" SPY_DIR="$SD" MOCK_STDIN_DIR="$T/c1-stdin" ZUVO_CODEX_BIN="$SPY_BIN/codex" \
  ZUVO_BLIND_AUDIT_PANEL=5 ZUVO_AGY_MODEL=agy-test-model ZUVO_AGY_FALLBACK_MODEL= \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-echo-prompt codex-5.3 agy" -- --mode blind-audit --production "$BIG60" --test "$TT" || rc=$?
expect_eq "C1 premise: the expected prompt is bigger than the code mode's 30000-char cap" "yes" \
  "$([ "$(_sz "$T/c-expected.prompt")" -gt 60000 ] && echo yes || echo no)"
if [ -s "$T/c1-stdin/mock-echo-prompt.stdin" ]; then
  ok "C1 the echo mock ran (its stdin was kept)"
  expect_eq "C1 …it received bap_build_prompt's bytes exactly (sha256)" "$(sha_of "$T/c-expected.prompt")" "$(sha_of "$T/c1-stdin/mock-echo-prompt.stdin")"
else bad "C1 the echo mock never ran — $(err c1 | tail -3 | tr '\n' ' ')"; fi
_r="$(rec c1 codex)"
if [ -s "$_r" ]; then
  ok "C1 the codex spy ran through the real runner (.rec present)"
  expect_eq "C1 …its stdin is bap_build_prompt's bytes exactly (sha256)" "$(sha_of "$T/c-expected.prompt")" "$(rec_get "$_r" stdin_sha)"
else bad "C1 the codex spy never ran — $(err c1 | tail -3 | tr '\n' ' ')"; fi
_e="$(err c1)"
case "$_e" in *[Tt][Rr][Uu][Nn][Cc][Aa][Tt]*|*[Cc][Hh][Uu][Nn][Kk]*) bad "C1 no truncation/chunk line on stderr — [$(cut300 "$_e")]" ;;
  *) ok "C1 no truncation/chunk line on stderr" ;; esac
if [ -s "$SD/agy.argv0" ]; then
  ok "C1 the agy spy ran (argv kept)"
  { printf '%s\0' -p; printf '%s\n\n' "$AGY_PREFIX"; cat "$T/c-expected.prompt"; printf '\0%s\0%s\0' --model agy-test-model; } > "$T/c-agy.argv0"
  if cmp -s "$T/c-agy.argv0" "$SD/agy.argv0"; then
    ok "C1 agy argv is exactly: -p <no-tools line + blank line + the prompt> --model <model> (4 elements)"
  else
    bad "C1 agy argv differs from '-p <prefix+prompt> --model <model>': $(tr '\0' '\n' < "$SD/agy.argv0" | awk 'NR<=2 || /^--/' | head -8 | tr '\n' '|')"
  fi
else bad "C1 the agy spy never ran — $(err c1 | tail -3 | tr '\n' ' ')"; fi

# ═══ D. argv lanes over the argv limit ═══════════════════════════════════════
echo "-- D. over 120000 bytes the argv lanes are dropped, loudly"
for _v in d1:"$BIG130": d2:"$MBF":LC_ALL=U8; do
  _tag="${_v%%:*}"; _rest="${_v#*:}"; _f="${_rest%%:*}"; _loc="${_rest#*:}"
  # D2's locale must actually be installed — setting an uninstalled LC_ALL doesn't fail loud, it
  # silently falls back, which would let this case pass without ever exercising the multi-byte-under-a-
  # UTF-8-locale path it exists to prove. utf8_locale finds it under whatever spelling this host lists
  # (en_US.UTF-8 on macOS, en_US.utf8 on glibc); none at all → a visible SKIP of that angle.
  if [ -n "$_loc" ]; then
    if [ -n "$U8" ]; then _loc="LC_ALL=$U8"
    else locale_skip "$_tag's UTF-8 angle (the case itself runs, under the default locale)"; _loc=""; fi
  fi
  SD="$(spy_dir "$_tag")"
  _envs=("$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_BLIND_AUDIT_PANEL=5
         ZUVO_REVIEW_TEST_PROVIDERS="agy kimi codex-5.3 mock-strict-clean")
  [ -n "$_loc" ] && _envs+=("$_loc")
  rc=0; drive "$_tag" "$SPY_PATH" "${_envs[@]}" -- --mode blind-audit --production "$_f" --test "$TT" || rc=$?
  L="$_tag ($(basename "$_f")${_loc:+, $_loc})"
  if [ -s "$(rec "$_tag" codex)" ]; then ok "$L the stdin lane codex-5.3 still ran (.rec present)"
  else bad "$L the stdin lane codex-5.3 never ran — $(err "$_tag" | tail -3 | tr '\n' ' ')"; fi
  expect_eq "$L …and the stdin mock still ran" "mock-strict-clean" "$(calls "$_tag")"
  if [ -e "$(rec "$_tag" agy)" ] || [ -e "$(rec "$_tag" kimi)" ]; then bad "$L agy/kimi were not dispatched (a .rec exists)"
  else ok "$L agy/kimi were not dispatched"; fi
  _line="$(err "$_tag" | awk '/agy/ && /kimi/ && /120000/ { print; exit }')"
  if [ -n "$_line" ]; then ok "$L one stderr line names agy, kimi and the 120000-byte limit"
  else bad "$L no stderr line names agy + kimi + 120000 — [$(cut300 "$(err "$_tag")")]"; fi
  expect_eq "$L one valid answer → exit 3" "3" "$rc"
done
# agy's argument is the no-tools line + a blank line + the prompt: a prompt of EXACTLY 120000 bytes is
# at the limit (kimi's argument is the prompt alone — it may run), and agy's is over it.
EDGE="$SRC/edge.sh"; printf 'x' > "$EDGE"
_ovh=$(( $(prompt_of "$EDGE" "$TT" | wc -c) - 1 ))
lines100 1300 | head -c "$((120000 - _ovh))" > "$EDGE"
expect_eq "D3 premise: the prompt is exactly 120000 bytes" "120000" "$(prompt_of "$EDGE" "$TT" | wc -c | tr -d ' ')"
SD="$(spy_dir d3)"
rc=0; drive d3 "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_BLIND_AUDIT_PANEL=5 ZUVO_REVIEW_TEST_PROVIDERS="agy kimi mock-strict-clean" \
  -- --mode blind-audit --production "$EDGE" --test "$TT" || rc=$?
if [ -s "$(rec d3 kimi)" ]; then ok "D3 kimi (argument = the prompt, 120000 bytes) still ran"
else bad "D3 kimi never ran — $(err d3 | tail -3 | tr '\n' ' ')"; fi
if [ -e "$(rec d3 agy)" ] || [ -e "$(rec_calls d3 agy)" ]; then bad "D3 agy ran with a $((120000 + ${#AGY_PREFIX} + 2))-byte argument"
else ok "D3 agy (argument = no-tools line + blank line + prompt) was not dispatched"; fi
_line="$(err d3 | awk '/excluding/ && /agy/ && /120000/ { print; exit }')"
if [ -n "$_line" ]; then ok "D3 one stderr line names agy and the 120000-byte limit"; else bad "D3 no stderr line names agy + 120000 — [$(cut300 "$(err d3)")]"; fi
expect_not "D3 …and that line does not drop kimi" "kimi" "$_line"

# ═══ E. panel size ═══════════════════════════════════════════════════════════
echo "-- E. ZUVO_BLIND_AUDIT_PANEL (default 3); ZUVO_REVIEW_MAX_PROVIDERS ignored"
FIVE="mock-strict-clean mock-strict-fix mock-strict-rewrite mock-invalid-block mock-echo-prompt"
rc=0; drive e1 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="$FIVE" ZUVO_REVIEW_PROVIDER_PICK=ranked \
  ZUVO_REVIEW_MAX_PROVIDERS=5 -- "${BA[@]}" || rc=$?
expect_eq "E1 5 candidates, ranked pick, ZUVO_REVIEW_MAX_PROVIDERS=5 → exactly 3 run" "3" "$(ncalls e1)"
expect_eq "E1 …the three ranked-first lanes ran (compared as a SET: they run in parallel, so call order is not an order)" \
  "mock-strict-clean mock-strict-fix mock-strict-rewrite" "$(calls e1 | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
expect_eq "E1 …the panel kept is in RANKING order (the fan-out line's list)" "mock-strict-clean mock-strict-fix mock-strict-rewrite" \
  "$(err e1 | awk '/Fan-out cap:/ { print; exit }' | sed -n 's/^[^(]*(\([^)]*\)).*/\1/p')"
expect_has "E1 …and the panel line keeps that order" "providers=mock-strict-clean,mock-strict-fix,mock-strict-rewrite " "$(out e1 | sed -n 2p)"
expect_eq "E1 …three valid answers → exit 0" "0" "$rc"
expect_has "E1 …the panel line says strict 3/3" "Audit panel: strict valid=3/3" "$(out e1)"
rc=0; drive e2 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="$FIVE" ZUVO_BLIND_AUDIT_PANEL=5 -- "${BA[@]}" || rc=$?
expect_eq "E2 ZUVO_BLIND_AUDIT_PANEL=5 → all 5 run" "5" "$(ncalls e2)"
expect_has "E2 …3 valid of 5 (the invalid block and the echo do not count)" "valid=3/5" "$(out e2)"
rc=0; drive e3 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="$FIVE" ZUVO_BLIND_AUDIT_PANEL=abc -- "${BA[@]}" || rc=$?
expect_eq "E3 ZUVO_BLIND_AUDIT_PANEL=abc → the default, 3 run" "3" "$(ncalls e3)"
expect_has "E3 …with a warning naming the variable" "ZUVO_BLIND_AUDIT_PANEL" "$(err e3)"

# ═══ F. agy pinned (default random pick) ═════════════════════════════════════
echo "-- F. agy is pinned in every random panel of 3"
_pin=0; _runs=0; _ok=0; _pinmsg=0
for _i in 1 2 3 4 5 6 7 8 9 10; do
  SD="$(spy_dir "f$_i")"; cp "$FXBA/clean.txt" "$SD/agy.reply"
  rc=0; drive "f$_i" "$SPY_PATH" "$H1" SPY_DIR="$SD" \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite mock-invalid-block agy" \
    -- "${BA[@]}" || rc=$?
  _runs=$((_runs + 1))
  [ "$rc" = 0 ] && _ok=$((_ok + 1))
  if [ -s "$(rec "f$_i" agy)" ] && [ "$(( $(ncalls "f$_i") + 1 ))" = 3 ]; then _pin=$((_pin + 1)); fi
  [ -z "$(err "f$_i" | awk '/pinned: agy/')" ] || _pinmsg=$((_pinmsg + 1))
done
expect_eq "F1 agy ran in every one of 10 panels, each panel exactly 3 lanes" "10" "$_pin"
expect_eq "F1 …every panel had >= 2 valid answers (agy + a valid mock) → exit 0" "10" "$_ok"
expect_eq "F1 …every run's stderr names the pin ('pinned: agy')" "10" "$_pinmsg"

# ═══ G. host exclusion by vendor ═════════════════════════════════════════════
echo "-- G. host exclusion by vendor (--list-providers --mode blind-audit)"
GLIST="codex-5.3 codex-5.4 claude agy cursor-agent kimi kimi-api qwen openrouter-3"
BASELINE="codex-5.3 codex-5.4 claude agy kimi kimi-api qwen openrouter-3"
glist() { # glist <tag> [VAR=value...] — the post-exclusion candidates on one line; status = the driver's
  local tag="$1"; shift
  drive "$tag" "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="$GLIST" "$@" -- --list-providers --mode blind-audit
}
rc=0; glist g0 || rc=$?
expect_eq "G0 no host → exit 0" "0" "$rc"
expect_eq "G0 no host → every isolated lane (cursor-agent is not one)" "$BASELINE" "$(out g0 | tr '\n' ' ' | sed 's/ $//')"
without() { local x w; x=" $1 "; shift; for w in "$@"; do x="${x/ $w / }"; done; x="${x# }"; printf '%s' "${x% }"; }
for _v in "claude|CLAUDECODE=1|claude" \
          "codex-sandbox|CODEX_SANDBOX=seatbelt|codex-5.3 codex-5.4" \
          "codex-desktop|CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop|codex-5.3 codex-5.4" \
          "codex-shell|CODEX_SHELL=1|codex-5.3 codex-5.4" \
          "codex-bundle|__CFBundleIdentifier=com.openai.codex|codex-5.3 codex-5.4" \
          "antigravity|ANTIGRAVITY_SESSION_ID=abc|agy" \
          "qwen|QWEN_CODE=1|qwen"; do
  _n="${_v%%|*}"; _r="${_v#*|}"; _set="${_r%%|*}"; _gone="${_r#*|}"
  rc=0; glist "g-$_n" "$_set" || rc=$?
  # shellcheck disable=SC2086  # _gone is a word list by design
  expect_eq "G $_n host ($_set) → exit 0, without: $_gone" "0|$(without "$BASELINE" $_gone)" \
    "$rc|$(out "g-$_n" | tr '\n' ' ' | sed 's/ $//')"
  expect_has "G $_n …stderr announces the exclusion" "auto-excluding" "$(err "g-$_n")"
done
rc=0; glist g-kimi PATH="$MOCK_PATH:$T/home-g-kimi/.kimi-code/bin" || rc=$?
expect_eq "G kimi host (its bin dir on PATH) → exit 0, without: kimi kimi-api" "0|$(without "$BASELINE" kimi kimi-api)" \
  "$rc|$(out g-kimi | tr '\n' ' ' | sed 's/ $//')"
rc=0; glist g-cursor VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/Contents/askpass.sh || rc=$?
expect_eq "G cursor host → exit 0, the isolated list unchanged (cursor-agent was never a candidate)" "0|$BASELINE" \
  "$rc|$(out g-cursor | tr '\n' ' ' | sed 's/ $//')"
expect_has "G cursor …stderr names cursor-agent as auto-excluded" "auto-excluding cursor-agent" "$(err g-cursor)"
# An UNMAPPED host fails CLOSED: its own lane is excluded, with a WARN. detect_host_platform only ever
# names hosts the vendor table knows, so no production seam reaches that arm — it is reached through a
# MUTANT copy of the driver under test whose Qwen signal names a host the table has never seen
# ("unmapped-host" — no vendor table arm matches it), with the driver's lib/ beside it. Real qwen must then stay (no vendor is guessed).
MUT="$T/unmapped"; mkdir -p "$MUT/lib"; cp "$(dirname "$AR")"/lib/*.sh "$MUT/lib/"; cp "$AR" "$MUT/adversarial-review.sh"
_g_unmapped_premise_ok=0
# The line lives in one file of the program (driver or module): mutate that file's copy.
_g_src="$(adv_driver_file_with "$AR" 'if [[ "${QWEN_CODE:-}" == "1" ]]; then')" || _g_src="$AR"
_g_dst="$MUT/adversarial-review.sh"; [ "$_g_src" = "$AR" ] || _g_dst="$MUT/lib/${_g_src##*/}"
# The Qwen branch is an `if` on QWEN_CODE whose body picks the lanes; the mutant answers "unmapped-host"
# as soon as that condition holds, ahead of the original body (left in place, never reached).
if awk '{ if (index($0, "if [[ \"${QWEN_CODE:-}\" == \"1\" ]]; then")) {
            print; print "    echo \"unmapped-host\"; return"; n++; next } print }
        END { exit n != 1 }' "$_g_src" > "$_g_dst"; then
  ok "G unmapped premise: the mutant makes exactly one host signal name an unknown host (qwen → unmapped-host)"; _g_unmapped_premise_ok=1
else bad "G unmapped premise: the Qwen host line was not found exactly once in the program (looked in $_g_src)"; fi
if [ "$_g_unmapped_premise_ok" -eq 1 ]; then
  rc=0; DRIVE_AR="$MUT/adversarial-review.sh" drive g-unmapped "$MOCK_PATH" "$H1" QWEN_CODE=1 \
    ZUVO_REVIEW_TEST_PROVIDERS="qwen codex-5.3" -- --list-providers --mode blind-audit || rc=$?
  expect_eq "G unmapped host → exit 0, no vendor guessed (qwen and codex-5.3 stay)" "0|qwen codex-5.3" \
    "$rc|$(out g-unmapped | tr '\n' ' ' | sed 's/ $//')"
  expect_has "G unmapped …its own lane is excluded" "auto-excluding unmapped-host" "$(err g-unmapped)"
  expect_has "G unmapped …with ONE warning naming it" "unmapped-host" "$(err g-unmapped | awk '/WARN/')"
  expect_eq "G unmapped …exactly one such warning" "1" "$(err g-unmapped | awk '/WARN/ && /unmapped-host/ { n++ } END { print n + 0 }')"
fi
# The vendor rule is THIS mode's: a code review on a Claude host keeps claude (it flips Opus<->Sonnet).
cp "$CODE_DIFF" "$T/g-code.in"
rc=0; drive g-code "$MOCK_PATH" "$H1" CLAUDECODE=1 -- --mode code --dry-run --provider claude || rc=$?
expect_eq "G --mode code on a Claude host: the dry run exits 0" "0" "$rc"
expect_has "G --mode code on a Claude host still keeps claude" "KEPT as cross-model reviewer" "$(err g-code)"

# ═══ H. isolation per lane (spies through the real runners) ════════════════
echo "-- H. isolation: every lane run through its real runner, recorded by a spy"
SD="$(spy_dir h1)"
rc=0; drive h1 "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_BLIND_AUDIT_PANEL=5 \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy cursor-agent kimi" -- "${BA[@]}" || rc=$?
# codex-5.3 — access none: neutral cwd + OLDPWD, isolated CODEX_HOME, effort high, read-only, no tools.
_r="$(rec h1 codex)"
if [ -s "$_r" ]; then
  ok "H codex: the spy ran (.rec present)"
  _pwd="$(rec_get "$_r" pwd_P)"
  if neutral "$_pwd" && case "$_pwd" in "$T/tmp"/*) true ;; *) false ;; esac; then ok "H codex: cwd is a neutral dir under the run's TMPDIR"
  else bad "H codex: cwd [$_pwd] is not a neutral dir under $T/tmp"; fi
  if [ -n "$SPY_SH" ]; then expect_eq "H codex: OLDPWD is the neutral cwd (the checkout path is not handed over)" "$_pwd" "$(rec_get "$_r" OLDPWD_P)"
  else no_oldpwd_check "H codex: OLDPWD is the neutral cwd"; fi
  _ch="$(rec_get "$_r" CODEX_HOME)"
  if [ -n "$_ch" ] && [ "$_ch" != "$FIX_CH" ] && case "$_ch" in "$T/tmp"/*) true ;; *) false ;; esac; then ok "H codex: CODEX_HOME is an isolated copy, not the user's"
  else bad "H codex: CODEX_HOME [$_ch] is not an isolated dir under $T/tmp"; fi
  expect_has "H codex: model_reasoning_effort = \"high\" (ZUVO_CODEX_EFFORT_AUDIT)" 'config=model_reasoning_effort = "high"' "$(cat "$_r")"
  expect_has "H codex: sandbox_mode = \"read-only\"" 'config=sandbox_mode = "read-only"' "$(cat "$_r")"
  expect_has "H codex: shell, exec and image tools disabled (access none)" "shell_tool unified_exec view_image" \
    "$(rec_args "$_r" | awk 'p { print; p = 0 } $0 == "--disable" { p = 1 }' | tr '\n' ' ' | sed 's/ $//')"
  # F6: the plan expects "codex effort high" provable on STDERR — config.toml (isolated CODEX_HOME)
  # is gone almost as soon as this one lane's runner subshell exits, well before a live SMOKE-B2 run
  # can look at it. One stderr line, blind-audit only, names the lane/effort/access.
  expect_has "H codex: driver stderr names the audit effort and access (F6)" "codex-5.3: blind-audit effort=high access=none" "$(err h1)"
else bad "H codex: the spy never ran — $(err h1 | tail -3 | tr '\n' ' ')"; fi
# claude — access none: no tools, safe mode, empty strict MCP config, no session, NOT skip-permissions.
_r="$(rec h1 claude)"
if [ -s "$_r" ]; then
  ok "H claude: the spy ran (.rec present)"
  _a="$(rec_args "$_r")"
  expect_eq "H claude: EVERY --tools is given an EMPTY list (a later one would override the first)" "arg=" \
    "$(awk 'p { print; p = 0 } $0 == "arg=--tools" { p = 1 }' "$_r" | sort -u)"
  for _f in --safe-mode --strict-mcp-config --no-session-persistence; do
    expect_has "H claude: $_f" "$_f" "$_a"
  done
  expect_not "H claude: no --dangerously-skip-permissions" "--dangerously-skip-permissions" "$_a"
  if neutral "$(rec_get "$_r" pwd_P)"; then ok "H claude: cwd is neutral"; else bad "H claude: cwd [$(rec_get "$_r" pwd_P)] is not neutral"; fi
  expect_has "H claude: the MCP config is empty" '{"mcpServers":{}}' "$(rec_get "$_r" mcp_content)"
else bad "H claude: the spy never ran — $(err h1 | tail -3 | tr '\n' ' ')"; fi
# agy — neutral cwd, argv without the permission-skipping flag (nor --mode plan / --sandbox).
_r="$(rec h1 agy)"
if [ -s "$_r" ]; then
  ok "H agy: the spy ran (.rec present)"
  _pwd="$(rec_get "$_r" pwd_P)"
  if neutral "$_pwd"; then ok "H agy: cwd is neutral"; else bad "H agy: cwd [$_pwd] is not neutral"; fi
  if [ -n "$SPY_SH" ]; then
    if neutral "$(rec_get "$_r" OLDPWD_P)"; then ok "H agy: OLDPWD is neutral too"; else bad "H agy: OLDPWD [$(rec_get "$_r" OLDPWD_P)] hands over a checkout path"; fi
  else no_oldpwd_check "H agy: OLDPWD is neutral too"; fi
  # Element by element (NUL-delimited — the prompt element spans many lines): no argument may START with
  # a forbidden flag, so `--mode=plan` / `--sandbox=true` are caught as well as the bare flags. `--mode`
  # is matched bare or with `=`: as a bare prefix it would also match the required `--model`.
  _n=0; _forb=""
  while IFS= read -r -d '' _el; do
    _n=$((_n + 1))
    case "$_el" in --dangerously-skip-permissions*|--sandbox*|--mode|--mode=*) _forb="$_forb ${_el%%[[:space:]]*}" ;; esac
  done < "$SD/agy.argv0"
  expect_eq "H agy: no argument starts with --dangerously-skip-permissions, --mode or --sandbox" "" "$_forb"
  expect_eq "H agy: exactly 4 argv elements (-p <prompt> --model <model>)" "4" "$_n"
  expect_eq "H agy: the first element is -p" "-p" "$(rec_args "$_r" | sed -n 1p)"
  if [ -f "$SD/agy.stdin" ] && [ ! -s "$SD/agy.stdin" ]; then ok "H agy: its stdin was empty (the prompt travels in its argument only)"
  else bad "H agy: its stdin was not empty ($(_sz "$SD/agy.stdin" 2>/dev/null || echo 'no record') bytes)"; fi
else bad "H agy: the spy never ran — $(err h1 | tail -3 | tr '\n' ' ')"; fi
# cursor-agent — never proven isolatable: no run at all in this mode.
if [ -e "$(rec h1 cursor-agent)" ] || [ -e "$(rec_calls h1 cursor-agent)" ]; then bad "H cursor-agent: it ran — its read tool is not scoped by --workspace"
else ok "H cursor-agent: never dispatched (isolation not provable, spike 2026-09-25)"; fi
expect_has "H cursor-agent: …and stderr names it as excluded" "cursor-agent" "$(err h1 | awk '/xclud|efus/')"
# kimi — runs from the run's own temp dir (where its tool-less agent file lives).
_r="$(rec h1 kimi)"
if [ -s "$_r" ]; then
  ok "H kimi: the spy ran (.rec present)"
  _af="$(awk 'p { print substr($0, 5); exit } $0 == "arg=--agent-file" { p = 1 }' "$_r")"
  # Logical PWD against the agent file's dir as the driver spelled both (that dir is gone by now, so
  # it cannot be made physical here); the physical pwd is then checked for neutrality.
  expect_eq "H kimi: cwd is the run's temp dir (where its agent file is)" "${_af%/*}" "$(rec_get "$_r" PWD)"
  _pwd="$(rec_get "$_r" pwd_P)"
  if neutral "$_pwd"; then ok "H kimi: …which is neutral"; else bad "H kimi: cwd [$_pwd] is not neutral"; fi
else bad "H kimi: the spy never ran — $(err h1 | tail -3 | tr '\n' ' ')"; fi

# ═══ D1/D2: the codex blind-audit effort is ONE source; the announcement IS the used value ═══
# D1 moved both the dispatch-loop announcement and run_codex's own effort to a single helper —
# this proves it, by DERIVING the expected strings from the env value set (never a hardcoded
# "high"/"medium"), so a future edit that only updates one of the two call sites shows up here as
# a mismatch between the announced and the used value, not as a silently-passing duplicate.
echo "-- D1/D2: codex blind-audit effort — one source, announced == used"
for _v in unset:high medium:medium; do
  _envval="${_v%%:*}"; _want="${_v#*:}"; _tag="d2-$_envval"
  SD="$(spy_dir "$_tag")"
  _extra=()
  [ "$_envval" = unset ] || _extra+=(ZUVO_BLIND_AUDIT_EFFORT="$_envval")
  rc=0; drive "$_tag" "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" \
    ${_extra[@]+"${_extra[@]}"} -- "${BA[@]}" --provider codex-5.3 || rc=$?
  _r="$(rec "$_tag" codex)"
  if [ -s "$_r" ]; then
    ok "D2 ZUVO_BLIND_AUDIT_EFFORT=$_envval: the codex spy ran (.rec present)"
    expect_has "D2 $_envval: USED — config.toml records model_reasoning_effort = \"$_want\"" \
      "config=model_reasoning_effort = \"$_want\"" "$(cat "$_r")"
  else bad "D2 $_envval: the codex spy never ran — $(err "$_tag" | tail -3 | tr '\n' ' ')"; fi
  expect_has "D2 $_envval: ANNOUNCED — driver stderr says effort=$_want" \
    "codex-5.3: blind-audit effort=$_want access=none" "$(err "$_tag")"
done

# ═══ I. the allowlist narrows, never widens ═════════════════════════════════
echo "-- I. ZUVO_BLIND_AUDIT_ALLOWLIST"
# codex and claude answer a valid block here, so the run's exit code says something (kimi's spy reply
# is not kimi's stream-json: that lane fails) — 2 valid of 3 → strict, exit 0.
SD="$(spy_dir i1)"; cp "$FXBA/clean.txt" "$SD/codex.reply"; cp "$FXBA/fix.txt" "$SD/claude.reply"
rc=0; drive i1 "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_BLIND_AUDIT_PANEL=5 \
  ZUVO_BLIND_AUDIT_ALLOWLIST="codex-5.3 claude kimi" \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy cursor-agent kimi" -- "${BA[@]}" || rc=$?
expect_eq "I1 the narrowed panel audited: codex-5.3 + claude valid of 3 → exit 0" "0" "$rc"
expect_has "I1 …panel line: strict, 2 valid of the 3 admitted lanes" "Audit panel: strict valid=2/3" "$(out i1)"
for _c in codex claude kimi; do
  if [ -s "$(rec i1 "$_c")" ]; then ok "I1 narrowed to codex-5.3 claude kimi: $_c ran"; else bad "I1 $_c never ran — $(err i1 | tail -3 | tr '\n' ' ')"; fi
done
for _c in agy cursor-agent; do
  if [ -e "$(rec i1 "$_c")" ] || [ -e "$(rec_calls i1 "$_c")" ]; then bad "I1 $_c ran although the allowlist leaves it out"; else ok "I1 $_c did not run"; fi
  expect_has "I1 …stderr names $_c as excluded" "$_c" "$(err i1 | awk '/xclud/')"
done
SD="$(spy_dir i2)"; cp "$FXBA/clean.txt" "$SD/agy.reply"
rc=0; drive i2 "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_BLIND_AUDIT_PANEL=6 \
  ZUVO_BLIND_AUDIT_ALLOWLIST="agy cursor-agent muse" \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy cursor-agent kimi muse" -- "${BA[@]}" || rc=$?
expect_eq "I2 agy alone admitted and valid → a panel of one, exit 3" "3" "$rc"
expect_has "I2 …panel line: degraded, 1 of 1" "Audit panel: degraded valid=1/1" "$(out i2)"
if [ -s "$(rec i2 agy)" ]; then ok "I2 'agy cursor-agent muse': agy (on the default list) runs"; else bad "I2 agy never ran — $(err i2 | tail -3 | tr '\n' ' ')"; fi
for _c in cursor-agent muse; do
  if [ -e "$(rec i2 "$_c")" ] || [ -e "$(rec_calls i2 "$_c")" ]; then bad "I2 $_c ran — an override WIDENED the allowlist"; else ok "I2 $_c still did not run (an override cannot widen)"; fi
  expect_has "I2 …stderr names $_c as refused" "$_c" "$(err i2 | awk '/efus/')"
done
for _c in codex claude kimi; do
  if [ -e "$(rec i2 "$_c")" ]; then bad "I2 $_c ran although the override leaves it out"; else ok "I2 $_c did not run (narrowed out)"; fi
done
# P2-36: an override that refuses EVERY lane it names makes bap_allowlist print nothing and return 1.
# The driver assigned that substitution bare, so `set -e` killed the run on the spot — exit 1 with only
# the library's refusal line, no no-lane report. Now: every candidate is dropped loudly and the run ends
# at the documented no-lane outcome (exit 1 + the ERROR block naming this mode's exclusions).
SD="$(spy_dir i3)"
rc=0; drive i3 "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_CODEX_BIN="$SPY_BIN/codex" ZUVO_BLIND_AUDIT_PANEL=5 \
  ZUVO_BLIND_AUDIT_ALLOWLIST="cursor-agent muse" \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy kimi" -- "${BA[@]}" || rc=$?
expect_eq "I3 an allowlist that refuses every lane it names → exit 1 (no lane), not an errexit crash" "1" "$rc"
expect_has "I3 …the library's refusal line names them" "refused (isolation never proven): cursor-agent muse" "$(err i3)"
expect_has "I3 …every candidate is dropped loudly, with the reason" \
  "Blind audit: excluding codex-5.3 claude agy kimi — isolation not proven" "$(err i3)"
expect_has "I3 …and the run reaches the no-lane ERROR block" "No cross-provider review tool found" "$(err i3)"
expect_has "I3 …which names this mode's own exclusions" "Excluded by the blind audit's own rules: codex-5.3 claude agy kimi" "$(err i3)"
for _c in codex claude agy kimi; do
  if [ -e "$(rec i3 "$_c")" ] || [ -e "$(rec_calls i3 "$_c")" ]; then bad "I3 $_c ran with an allowlist that admits nothing"
  else ok "I3 $_c did not run"; fi
done
rc=0; drive i3l "$SPY_PATH" "$H1" ZUVO_BLIND_AUDIT_ALLOWLIST="cursor-agent muse" \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude" -- --list-providers --mode blind-audit || rc=$?
expect_eq "I3 --list-providers with the same allowlist → exit 0 and an EMPTY list (no crash)" "0|" "$rc|$(out i3l)"

# ═══ K. agy's own allow-rules ═══════════════════════════════════════════════
echo "-- K. ~/.gemini/antigravity-cli/settings.json"
for _v in k1:'{"permissions":{"allow":["Read(*)"]}}':out k2:'{"trustedWorkspaces":["/somewhere"]}':in \
          k3:'{"permissions":{"allow":[]}}':in k4:'{"permissions": nope':out; do
  _tag="${_v%%:*}"; _rest="${_v#*:}"; _json="${_rest%:*}"; _want="${_rest##*:}"
  mkdir -p "$T/home-$_tag/.gemini/antigravity-cli"; printf '%s\n' "$_json" > "$T/home-$_tag/.gemini/antigravity-cli/settings.json"
  SD="$(spy_dir "$_tag")"
  rc=0; drive "$_tag" "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_REVIEW_TEST_PROVIDERS="agy mock-strict-clean" -- "${BA[@]}" || rc=$?
  expect_eq "K $_tag ($_json): the mock lane ran" "mock-strict-clean" "$(calls "$_tag")"
  if [ "$_want" = out ]; then
    if [ -e "$(rec "$_tag" agy)" ]; then bad "K $_tag agy ran despite its settings"; else ok "K $_tag agy left out"; fi
    expect_has "K $_tag …stderr names the settings file" "$T/home-$_tag/.gemini/antigravity-cli/settings.json" "$(err "$_tag")"
  else
    if [ -s "$(rec "$_tag" agy)" ]; then ok "K $_tag agy admitted"; else bad "K $_tag agy never ran — $(err "$_tag" | tail -3 | tr '\n' ' ')"; fi
  fi
done

# ═══ L. no candidate left: exit 1 WITH the reason (both modes) ════════════════
# An exclusion that removes EVERY candidate used to kill the driver inside a `grep -v` pipeline
# (pipefail): exit 1 and not a word on stderr. The exit code stays 1; the reason must be printed.
echo "-- L. every candidate excluded: exit 1 and say which lanes went, and why"
rc=0; drive l1 "$SPY_PATH" "$H1" CLAUDECODE=1 -- "${BA[@]}" --provider claude || rc=$?
expect_eq "L1 blind-audit: --provider claude on a Claude host → exit 1" "1" "$rc"
expect_has "L1 …stderr says no tool is left" "No cross-provider review tool found" "$(err l1)"
expect_has "L1 …and names claude as the host's own lane" "auto-excluded: claude" "$(err l1)"
for _t in l2 l3 l4; do cp "$CODE_DIFF" "$T/$_t.in"; done
rc=0; drive l2 "$SPY_PATH" "$H1" VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/askpass.sh \
  -- --mode code --provider cursor-agent || rc=$?
expect_eq "L2 code mode: --provider cursor-agent on a Cursor host → exit 1" "1" "$rc"
expect_has "L2 …stderr says no tool is left" "No cross-provider review tool found" "$(err l2)"
expect_has "L2 …and names cursor-agent as the host's own lane" "auto-excluded: cursor-agent" "$(err l2)"
rc=0; drive l3 "$MOCK_PATH" "$H1" -- --mode code --provider mock-success --exclude mock-success || rc=$?
expect_eq "L3 code mode: --exclude removes the only lane → exit 1" "1" "$rc"
expect_has "L3 …stderr names it as excluded by --exclude" "Excluded by --exclude: mock-success" "$(err l3)"
expect_not "L3 …and does not blame the host" "auto-excluded" "$(err l3)"
rc=0; drive l4 "$MOCK_PATH" "$H1" -- --mode code --provider mock-success --exclude-last mock-success || rc=$?
expect_eq "L4 code mode: --exclude-last removes the only lane → exit 1" "1" "$rc"
expect_has "L4 …stderr says no tool is left" "No cross-provider review tool found" "$(err l4)"
expect_has "L4 …and names the --exclude-last removal" "--exclude-last" "$(err l4)"
# ADV-A28: EXCLUDE_PROVIDER (user's --exclude) and HOST_EXCLUDED (the host's vendor auto-exclusion,
# appended AFTER it) must be split apart correctly in the "no lane left" message even when they OVERLAP
# — a codex host auto-excludes BOTH codex-5.3 and codex-5.4, but the user already named codex-5.3
# explicitly, so the host side only ever appends codex-5.4 (the "already excluded, no change" skip at
# line ~1653). The message must still credit codex-5.3 to --exclude and codex-5.4 to the host, not
# double-count or misattribute either.
rc=0; drive l5 "$MOCK_PATH" "$H1" CODEX_SANDBOX=seatbelt \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 codex-5.4" -- --mode blind-audit --production "$P" --test "$TT" --exclude codex-5.3 || rc=$?
expect_eq "L5 blind-audit, codex host, --exclude codex-5.3 (one of the host's own two lanes) → exit 1" "1" "$rc"
expect_has "L5 …--exclude is credited with EXACTLY codex-5.3, not codex-5.4 too" "Excluded by --exclude: codex-5.3." "$(err l5)"
expect_not "L5 …--exclude is not credited with codex-5.4" "Excluded by --exclude: codex-5.3 codex-5.4" "$(err l5)"
expect_has "L5 …the host is credited with EXACTLY codex-5.4, the one it actually added" \
  "Host platform auto-excluded: codex-5.4 " "$(err l5)"

# ═══ M. collection: validate, merge, print, ledger, log ══════════════════════
# Expected rows come from the mocks' own tables: mock-strict-clean has ONE non-FULL row (B3 PARTIAL),
# mock-strict-fix TWO (B1, B2 NONE), mock-strict-rewrite TWO (B1 STRUCTURAL_ONLY, E1 NONE).
echo "-- M. collection: each answer validated, one merged block, ledger and log per the plan"
rc=0; drive m1 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite" -- "${BA[@]}" || rc=$?
expect_eq "M1 three valid answers (clean, fix, rewrite) → exit 0" "0" "$rc"
expect_eq "M1 …stdout line 1 is 'Audit mode: strict'" "Audit mode: strict" "$(out m1 | sed -n 1p)"
expect_has "M1 …line 2: strict, 3 valid of 3" "Audit panel: strict valid=3/3 " "$(out m1 | sed -n 2p)"
expect_eq "M1 …line 3: the WORST verdict (REWRITE > FIX > CLEAN)" "Coverage verdict: REWRITE" "$(out m1 | sed -n 3p)"
expect_has "M1 …the fix lane's uncovered rows carry its prefix" "| mock-strict-fix:B1 |" "$(out m1)"
expect_has "M1 …the rewrite lane's too" "| mock-strict-rewrite:E1 |" "$(out m1)"
expect_not "M1 …a FULL row is not carried" "mock-strict-fix:B3" "$(out m1)"
expect_not "M1 …stdout is the block only (no review banner)" "CROSS-PROVIDER" "$(out m1)"
_e="$(err m1)"
expect_not "M6 no 'finding counts are incomplete' WARN in this mode" "finding counts" "$_e"
expect_not "M6 …no SEVERITY line" "SEVERITY" "$_e"
expect_not "M6 …no 'partial' status" "partial" "$_e"

rc=0; drive m2 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-echo-prompt" -- "${BA[@]}" || rc=$?
expect_eq "M2 clean + fix + an ECHO of the prompt → exit 0 (two valid answers are strict)" "0" "$rc"
expect_has "M2 …valid=2/3" "Audit panel: strict valid=2/3 " "$(out m2 | sed -n 2p)"
expect_has "M2 …the echo is failed as invalid in the panel line" "failed=mock-echo-prompt:invalid" "$(out m2 | sed -n 2p)"
expect_has "M2 …and stderr reports it invalid" "mock-echo-prompt" "$(err m2 | awk '/invalid/')"
rc=0; drive m2j "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-echo-prompt" -- "${BA[@]}" --json || rc=$?
J="$T/m2j.out"
expect_eq "M2 --json: exit 0" "0" "$rc"
expect_has "M2 --json: provider_outcomes reports the echo invalid" "mock-echo-prompt:invalid" "$(jq -r .provider_outcomes "$J" 2>&1)"
expect_eq "M5 --json: stdout is ONE JSON document" "1" "$(jq -s length "$J" 2>&1)"
expect_eq "M5 --json: exactly the plan's keys" \
  "excluded_argv_lanes merged_block mode prompt_bytes provider_outcomes results status valid_providers verdict" \
  "$(jq -r 'keys | join(" ")' "$J" 2>&1)"
expect_eq "M5 …status strict, mode blind-audit, verdict FIX (the worst VALID verdict — the echo does not count)" \
  "strict|blind-audit|FIX" "$(jq -r '[.status, .mode, .verdict] | join("|")' "$J" 2>&1)"
expect_eq "M5 …valid_providers: the two valid lanes" "mock-strict-clean mock-strict-fix" "$(jq -r '.valid_providers | sort | join(" ")' "$J" 2>&1)"
expect_eq "M5 …prompt_bytes: the bytes bap_build_prompt makes of the pair" \
  "$(prompt_of "$P" "$TT" | wc -c | tr -d ' ')" "$(jq -r .prompt_bytes "$J" 2>&1)"
expect_eq "M5 …excluded_argv_lanes: none for a small prompt" "0" "$(jq -r '.excluded_argv_lanes | length' "$J" 2>&1)"
jq -j .merged_block "$J" > "$T/m2j.block" 2>/dev/null
if cmp -s "$T/m2.out" "$T/m2j.block"; then ok "M5 …merged_block is the text mode's stdout, byte for byte"
else bad "M5 …merged_block differs from the text mode's stdout — [$(cut300 "$(cat "$T/m2j.block")")]"; fi
expect_eq "M5 …results: every lane that ANSWERED, valid or not" "mock-echo-prompt mock-strict-clean mock-strict-fix" \
  "$(jq -r '.results | keys | join(" ")' "$J" 2>&1)"
expect_eq "M5 …results hold the raw reply" "Audit mode: strict" "$(jq -r '.results["mock-strict-fix"]' "$J" 2>&1 | sed -n 1p)"
rc=0; drive m5b "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean" -- --mode blind-audit --production "$BIG130" --test "$TT" --json || rc=$?
expect_eq "M5b a 130000-byte file, one lane: exit 3, status degraded, excluded_argv_lanes = agy kimi" "3|degraded|agy kimi" \
  "$rc|$(jq -r '.status + "|" + (.excluded_argv_lanes | join(" "))' "$T/m5b.out" 2>&1)"

rc=0; drive m3 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-invalid-block mock-fail" -- "${BA[@]}" || rc=$?
expect_eq "M3 one valid answer (+ an invalid block + a failed lane) → exit 3" "3" "$rc"
expect_has "M3 …Audit panel: degraded valid=1/3" "Audit panel: degraded valid=1/3 " "$(out m3 | sed -n 2p)"
expect_has "M3 …the invalid block is named invalid" "mock-invalid-block:invalid" "$(out m3 | sed -n 2p)"
expect_has "M3 …the failed lane is named empty" "mock-fail:empty" "$(out m3 | sed -n 2p)"

rc=0; drive m4 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-invalid-block mock-echo-prompt mock-fail" -- "${BA[@]}" || rc=$?
expect_eq "M4 no valid answer → exit 2" "2" "$rc"
expect_eq "M4 …and stdout is EMPTY (0 bytes)" "0" "$(_sz "$T/m4.out")"
expect_has "M4 …stderr says no lane gave a valid answer" "no valid answer" "$(err m4)"
rc=0; drive m4j "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-invalid-block mock-echo-prompt mock-fail" -- "${BA[@]}" --json || rc=$?
expect_eq "M4 --json, no valid answer → exit 2, ONE document: status none, verdict null, an empty block" "2|none|null|" \
  "$rc|$(jq -r '[.status, (.verdict | tostring), .merged_block] | join("|")' "$T/m4j.out" 2>&1)"

# The ledger: ok / auth / quota describe the lane's ACCOUNT and are recorded; timeout / empty / invalid
# describe THIS input or prompt and are not — a huge file pair must not bench a healthy lane for code
# reviews. The auth stub is inline, like the lane golden's: the runner's token list catches "Not logged in".
MX="$T/mockx"; mkdir -p "$MX"
printf '#!/bin/sh\ncat > /dev/null\necho "Error: Not logged in. Please run /login"\n' > "$MX/mock-auth-stub"; chmod +x "$MX/mock-auth-stub"
hrow() { awk -F'\t' -v p="$2" '$1 == p { print $3 "/" $5 }' "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
HF="$T/health-m7.tsv"
rc=0; drive m7 "$MX:$MOCK_PATH" "$H1" ZUVO_PROVIDER_BENCH=1 ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_RUN_ID="m7-$$" \
  ZUVO_BLIND_AUDIT_PANEL=5 ZUVO_BLIND_AUDIT_TIMEOUT=2 MOCK_HANG_SECONDS=30 \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-invalid-block mock-timeout mock-fail mock-auth-stub" -- "${BA[@]}" || rc=$?
expect_eq "M7 premise: five lanes, one valid answer → exit 3" "3" "$rc"
expect_has "M7 premise: the timeout lane timed out (ZUVO_BLIND_AUDIT_TIMEOUT=2 reached it)" "mock-timeout:timeout" "$(out m7 | sed -n 2p)"
expect_has "M7 premise: the stub lane was classified auth" "mock-auth-stub:auth" "$(out m7 | sed -n 2p)"
expect_eq "M7 the valid lane is recorded ok (0 consecutive failures)" "0/ok" "$(hrow "$HF" mock-strict-clean)"
expect_eq "M7 the auth-stub lane IS recorded auth (its account, not the input)" "1/auth" "$(hrow "$HF" mock-auth-stub)"
for _l in mock-invalid-block mock-timeout mock-fail; do
  expect_eq "M7 $_l (an outcome of the input or prompt) is NOT recorded" "" "$(hrow "$HF" "$_l")"
done
cp "$CODE_DIFF" "$T/m7c.in"
rc=0; drive m7c "$MOCK_PATH" "$H1" ZUVO_PROVIDER_BENCH=1 ZUVO_PROVIDER_HEALTH_FILE="$T/health-m7c.tsv" -- --mode code --provider mock-fail || rc=$?
expect_eq "M7 control: --mode code still records an empty lane" "1/empty" "$(hrow "$T/health-m7c.tsv" mock-fail)"

# adversarial.log (in $ZUVO_HOME): one row per lane, col 3 = blind-audit, col 7 (findings) = the lane's
# uncovered rows in the merged block (0 for an invalid or failed lane); the severity columns do not apply.
# M8's own runs, in their own homes: M2's panel (clean + fix + an echo) and M3's (clean + invalid + failed).
rc=0; drive m8 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-echo-prompt" -- "${BA[@]}" || rc=$?
expect_eq "M8 premise: clean + fix + echo → exit 0" "0" "$rc"
rc=0; drive m8f "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-invalid-block mock-fail" -- "${BA[@]}" || rc=$?
expect_eq "M8 premise: clean + invalid + failed → exit 3" "3" "$rc"
LOGF="$T/home-m8/.zuvo/adversarial.log"
lrow() { awk -F'\t' -v p="$2" '$1 != "SUMMARY" && $3 == "blind-audit" && $14 == p { print $7 "|" $15 "|" $12 }' "$1" 2>/dev/null; }
expect_eq "M8 adversarial.log: one row per lane, mode blind-audit" "3" \
  "$(awk -F'\t' '$1 != "SUMMARY" && $3 == "blind-audit"' "$LOGF" 2>/dev/null | wc -l | tr -d ' ')"
expect_eq "M8 …mock-strict-clean: 1 uncovered row, ok, exit 0" "1|ok|0" "$(lrow "$LOGF" mock-strict-clean)"
expect_eq "M8 …mock-strict-fix: 2 uncovered rows, ok, exit 0" "2|ok|0" "$(lrow "$LOGF" mock-strict-fix)"
expect_eq "M8 …mock-echo-prompt: invalid, 0 rows, exit 1" "0|invalid|1" "$(lrow "$LOGF" mock-echo-prompt)"
expect_eq "M8 …the severity columns stay 0" "0|0|0" \
  "$(awk -F'\t' '$3 == "blind-audit" && $14 == "mock-strict-fix" { print $8 "|" $9 "|" $10 }' "$LOGF" 2>/dev/null)"
expect_eq "M8 …the rows share one run id" "1" \
  "$(awk -F'\t' '$1 != "SUMMARY" && $3 == "blind-audit" { print $2 }' "$LOGF" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
expect_eq "M8 …a failed lane: 0 rows, empty, exit 1" "0|empty|1" "$(lrow "$T/home-m8f/.zuvo/adversarial.log" mock-fail)"

rc=0; drive m9 "$MOCK_PATH" "$H1" ZUVO_BLIND_AUDIT_TIMEOUT=900 -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "M9 ZUVO_BLIND_AUDIT_TIMEOUT=900: the run still completes (exit 3)" "3" "$rc"
expect_has "M9 …a WARN names the variable and the 510-second ceiling" "510" "$(err m9 | awk '/WARN/ && /ZUVO_BLIND_AUDIT_TIMEOUT/')"
expect_has "M9 …and the lanes run with 510 s" "510s per lane" "$(err m9)"

# bap_merge's own usage-error exit 2 (a malformed argument) is unreachable today from this call site —
# PROVIDER_COUNT>0 is already verified and every argument built here is internally well-formed — but if
# it ever fired, the per-lane adversarial.log rows must not be lost. No production seam reaches that
# arm, so it is forced through a MUTANT copy of the driver (the same technique as the G-unmapped-host
# case above) whose bap_merge call site is given a bogus flag, exactly as bap_merge's own usage checker
# would reject it.
MUTM="$T/mutmerge"; mkdir -p "$MUTM/lib" "$T/home-m10/.zuvo"; cp "$(dirname "$AR")"/lib/*.sh "$MUTM/lib/"; cp "$AR" "$MUTM/adversarial-review.sh"
_m_src="$(adv_driver_file_with "$AR" '    bap_merge "${_ba_args[@]}" > "$_ba_merged" || _ba_merge_rc=$?')" || _m_src="$AR"
_m_dst="$MUTM/adversarial-review.sh"; [ "$_m_src" = "$AR" ] || _m_dst="$MUTM/lib/${_m_src##*/}"
cp "$PROTO" "$T/home-m10/.zuvo/"   # MUTM has no ../shared/includes sibling; ~/.zuvo is its fallback
if awk 'BEGIN { old = "    bap_merge \"${_ba_args[@]}\" > \"$_ba_merged\" || _ba_merge_rc=$?"
                new = "    bap_merge --bogus-flag \"${_ba_args[@]}\" > \"$_ba_merged\" || _ba_merge_rc=$?" }
        { if ($0 == old) { print new; n++ } else print }
        END { exit n != 1 }' "$_m_src" > "$_m_dst"; then
  ok "M10 premise: the mutant forces bap_merge's own call site into a usage error (exactly one line changed)"
  rc=0; DRIVE_AR="$MUTM/adversarial-review.sh" drive m10 "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
  expect_eq "M10 bap_merge's own usage error → exit 2 (same class as 'no valid answer')" "2" "$rc"
  expect_eq "M10 …and stdout is EMPTY" "0" "$(_sz "$T/m10.out")"
  expect_eq "M10 …the lane that DID answer still gets an adversarial.log row (written BEFORE the exit, not lost)" "1" \
    "$(awk -F'\t' '$1 != "SUMMARY" && $3 == "blind-audit" && $14 == "mock-strict-clean"' "$T/home-m10/.zuvo/adversarial.log" 2>/dev/null | wc -l | tr -d ' ')"
  # P2-11/P2-19: the exit 2 was SILENT (only bap_merge's own usage line, no word from the driver), and it
  # swallowed what the panel had actually done. The ERROR names the step + rc and the withheld outcome.
  expect_has "M10 …an ERROR names the failing step and its rc (the exit 2 is never silent)" \
    "ERROR: blind audit: bap_merge (rc=2) failed — nothing on stdout, exit 2" "$(err m10)"
  expect_has "M10 …and the panel's own outcome it withheld (degraded, 1 valid, exit 3)" \
    "the panel itself was degraded with 1 valid answer(s) (exit 3 withheld)" "$(err m10)"
else
  bad "M10 premise: the bap_merge call site was not found exactly once, byte for byte, in the program (looked in $_m_src)"
fi
# The same for bap_json (--json): merge succeeds, the JSON step fails — forced by a mutant whose bap_json
# call passes a status bap_json's own usage check refuses.
MUTJ="$T/mutjson"; mkdir -p "$MUTJ/lib" "$T/home-m10j/.zuvo"; cp "$(dirname "$AR")"/lib/*.sh "$MUTJ/lib/"; cp "$AR" "$MUTJ/adversarial-review.sh"
_j_src="$(adv_driver_file_with "$AR" 'bap_json "$_ba_status"')" || _j_src="$AR"
_j_dst="$MUTJ/adversarial-review.sh"; [ "$_j_src" = "$AR" ] || _j_dst="$MUTJ/lib/${_j_src##*/}"
cp "$PROTO" "$T/home-m10j/.zuvo/"
if awk 'BEGIN { old = "bap_json \"$_ba_status\""; new = "bap_json \"bogus-status\"" }
        { i = index($0, old); if (i) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)); n++ } print }
        END { exit n != 1 }' "$_j_src" > "$_j_dst"; then
  ok "M10j premise: the mutant forces bap_json's call into a usage error (exactly one call changed)"
  rc=0; DRIVE_AR="$MUTJ/adversarial-review.sh" drive m10j "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean --json || rc=$?
  expect_eq "M10j bap_json's own usage error → exit 2 and stdout EMPTY" "2|0" "$rc|$(_sz "$T/m10j.out")"
  expect_has "M10j …an ERROR names bap_json and its rc" "ERROR: blind audit: bap_json (rc=2) failed" "$(err m10j)"
  expect_has "M10j …and the withheld panel outcome" "the panel itself was degraded with 1 valid answer(s) (exit 3 withheld)" "$(err m10j)"
  expect_eq "M10j …the lane still gets its adversarial.log row" "1" \
    "$(awk -F'\t' '$1 != "SUMMARY" && $3 == "blind-audit" && $14 == "mock-strict-clean"' "$T/home-m10j/.zuvo/adversarial.log" 2>/dev/null | wc -l | tr -d ' ')"
else
  bad "M10j premise: the bap_json call was not found exactly once in the program (looked in $_j_src)"
fi
# M11 — the per-lane row's uncovered-row count when bap_uncovered_rows itself FAILS
# (adversarial-blind-audit.sh:184, `_n="$(bap_uncovered_rows …)" || _n=0`): the run is not taken down — the
# merged block is already on stdout and the exit is the panel's own — and the row's findings column is 0, not
# whatever the failed call printed. Injected (A10's ba_inject): bap_uncovered_rows prints 5, then fails. M8
# shows the real count for this lane is 1, so 0 here is the fallback's, and 5 would be the failed call's.
ba_inject "$T/m11" bap_uncovered_rows 1 5 && {
  rc=0; DRIVE_AR="$T/m11/adversarial-review.sh" drive m11 "$MOCK_PATH" "$H1" -- "${BA[@]}" --protocol "$PROTO" \
    --provider mock-strict-clean || rc=$?
  expect_eq "M11 bap_uncovered_rows fails in the log loop → the panel's own exit (3), its block on stdout" \
    "3|Audit mode: strict|Audit panel: degraded valid=1/1 providers=mock-strict-clean verdicts=mock-strict-clean:CLEAN" \
    "$rc|$(out m11 | sed -n 1p)|$(out m11 | sed -n 2p)"
  expect_eq "M11 …the failure was the injected one, on the one lane's call" "1" "$(cat "$T/m11/bap_uncovered_rows.count" 2>/dev/null)"
  expect_has "M11 …and its message is on stderr" "INJECTED: bap_uncovered_rows fails on call 1" "$(err m11)"
  expect_eq "M11 …the lane's row: findings 0 (not the 5 the failed call printed), ok, exit 0" "0|ok|0" \
    "$(lrow "$T/home-m11/.zuvo/adversarial.log" mock-strict-clean)"
}

# ═══ N. what Task 4 left ═════════════════════════════════════════════════════
echo "-- N. deadline, timeout knob, failure evidence, --help, the no-lane message"
# N1's own runs: the default (M1's three-lane panel, no knob) and the clamped knob (M9's 900 s).
rc=0; drive n1-default "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite" -- "${BA[@]}" || rc=$?
expect_eq "N1 default premise: the three-lane panel completes strict (exit 0)" "0" "$rc"
expect_has "N1 default: 480 s per lane, whole-run deadline 555 s (480 + 15 grace + 60)" "480s per lane, whole-run deadline 555s" "$(err n1-default)"
rc=0; drive n1-clamped "$MOCK_PATH" "$H1" ZUVO_BLIND_AUDIT_TIMEOUT=900 -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "N1 clamped premise: ZUVO_BLIND_AUDIT_TIMEOUT=900, the run completes (exit 3)" "3" "$rc"
expect_has "N1 clamped: 510 + 15 + 60 = 585 s, under the skill's 600 s Bash call" "whole-run deadline 585s" "$(err n1-clamped)"
rc=0; drive n1 "$MOCK_PATH" "$H1" ZUVO_BLIND_AUDIT_TIMEOUT=100 ZUVO_TIMEOUT_GRACE=5 -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_has "N1 …it follows the knobs: 100 + 5 + 60 = 165" "100s per lane, whole-run deadline 165s" "$(err n1)"
# F1: the kill grace is part of the budget. A 60 s grace with the 510 s ceiling would put the deadline at
# 630 s — past the caller's 600 s Bash call. The per-lane timeout gives way instead: 585 - 60 - 60 = 465.
for _v in "n1g:510:60:465:585" "n1d:unset:60:465:585" "n1x:unset:600:1:585"; do
  IFS=: read -r _tag _to _gr _wt _wd <<EOF
$_v
EOF
  _envs=("$H1" ZUVO_TIMEOUT_GRACE="$_gr"); [ "$_to" = unset ] || _envs+=(ZUVO_BLIND_AUDIT_TIMEOUT="$_to")
  rc=0; drive "$_tag" "$MOCK_PATH" "${_envs[@]}" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
  [ "$_wt" = 1 ] || expect_eq "N1 grace $_gr, timeout $_to: the run still audits (exit 3)" "3" "$rc"
  expect_has "N1 grace $_gr, timeout $_to → ${_wt}s per lane, deadline ${_wd}s (never past 585)" \
    "${_wt}s per lane, whole-run deadline ${_wd}s" "$(err "$_tag")"
  expect_eq "N1 …exactly ONE WARN about the budget" "1" \
    "$(err "$_tag" | awk '/WARN/ && /ZUVO_BLIND_AUDIT_TIMEOUT/ { n++ } END { print n + 0 }')"
  expect_has "N1 …naming the effective values" "$_wt s per lane, whole-run deadline $_wd s" "$(err "$_tag" | awk '/WARN/')"
done

# G1: ZUVO_TIMEOUT_GRACE with leading zeros is DECIMAL, in every mode. The driver's own arithmetic read
# `0060` as octal 48 and died on `08` ("value too great for base"). The kill flag is observed through a
# `timeout` wrapper that logs its argv and execs the real one; `000` stays 0 (today's value — only an
# override with no digits at all falls back to 15).
TSHIM="$T/tshim"; mkdir -p "$TSHIM"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$TIMEOUT_ARGV_LOG"\nexec "$REAL_TIMEOUT" "$@"\n' > "$TSHIM/timeout"; chmod +x "$TSHIM/timeout"
for _v in 08:8 0060:60 000:0; do
  _g="${_v%%:*}"; _want="${_v#*:}"; _tag="g1-$_g"; cp "$CODE_DIFF" "$T/$_tag.in"
  rc=0; drive "$_tag" "$TSHIM:$MOCK_PATH" "$H1" ZUVO_TIMEOUT_GRACE="$_g" TIMEOUT_ARGV_LOG="$T/$_tag.targv" REAL_TIMEOUT="$SHIM/timeout" \
    -- --mode code --provider mock-success || rc=$?
  expect_eq "G1 --mode code, ZUVO_TIMEOUT_GRACE=$_g: the review completes (exit 0, no arithmetic error)" "0|" \
    "$rc|$(err "$_tag" | awk '/value too great|syntax error/')"
  expect_eq "G1 …the lane's kill grace is $_want (decimal)" "-k $_want" \
    "$(awk '/mock-success/ { print $1 " " $2; exit }' "$T/$_tag.targv" 2>/dev/null)"
done
rc=0; drive g1-ba "$MOCK_PATH" "$H1" ZUVO_TIMEOUT_GRACE=0060 -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_has "G1 blind-audit, grace 0060 = grace 60: 465s per lane, deadline 585s" "465s per lane, whole-run deadline 585s" "$(err g1-ba)"
# B106: the code-mode cases above prove announced == used via a raw `timeout -k` argv spy; blind-audit's
# case only checked the stderr announcement — do the same real-invocation check here, for the same rigor.
rc=0; drive g1-ba-argv "$TSHIM:$MOCK_PATH" "$H1" ZUVO_TIMEOUT_GRACE=0060 TIMEOUT_ARGV_LOG="$T/g1-ba-argv.targv" REAL_TIMEOUT="$SHIM/timeout" \
  -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "G1 blind-audit: the lane's kill grace is REALLY 60 (not just announced)" "-k 60" \
  "$(awk '/mock-strict-clean/ { print $1 " " $2; exit }' "$T/g1-ba-argv.targv" 2>/dev/null)"

# ADV-A9/A10: ar_decimal (the ONE normaliser behind ZUVO_TIMEOUT_GRACE/SUSPEND_THRESHOLD/RUN_DEADLINE)
# caps a 10+-digit value at 999999999 before any arithmetic, mirroring the library's own _bap_secs/
# _bap_knob, and WARNS + falls back to the default on a LEADING DASH instead of silently sign-flipping
# it (`tr -cd '0-9'` would otherwise turn "-5" into "5" with no diagnostic). Observed the same way as
# G1 above, through the real `timeout -k` invocation.
cp "$CODE_DIFF" "$T/g1-cap.in"
rc=0; drive g1-cap "$TSHIM:$MOCK_PATH" "$H1" ZUVO_TIMEOUT_GRACE=99999999999999999999 TIMEOUT_ARGV_LOG="$T/g1-cap.targv" REAL_TIMEOUT="$SHIM/timeout" \
  -- --mode code --provider mock-success || rc=$?
expect_eq "ar_decimal: a 20-digit ZUVO_TIMEOUT_GRACE completes (exit 0, no arithmetic error)" "0|" \
  "$rc|$(err g1-cap | awk '/value too great|syntax error/')"
expect_eq "ar_decimal: …capped at 999999999 before reaching timeout -k (not wrapped, not left 20 digits wide)" \
  "-k 999999999" "$(awk '/mock-success/ { print $1 " " $2; exit }' "$T/g1-cap.targv" 2>/dev/null)"
cp "$CODE_DIFF" "$T/g1-neg.in"
rc=0; drive g1-neg "$TSHIM:$MOCK_PATH" "$H1" ZUVO_TIMEOUT_GRACE=-5 TIMEOUT_ARGV_LOG="$T/g1-neg.targv" REAL_TIMEOUT="$SHIM/timeout" \
  -- --mode code --provider mock-success || rc=$?
expect_eq "ar_decimal: a NEGATIVE ZUVO_TIMEOUT_GRACE=-5 falls back to the default 15, not a silent sign flip to 5" \
  "-k 15" "$(awk '/mock-success/ { print $1 " " $2; exit }' "$T/g1-neg.targv" 2>/dev/null)"
expect_has "ar_decimal: …and WARNS on stderr rather than silently flipping the sign" "ar_decimal: WARN" "$(err g1-neg)"
# P2-2: the sign is whatever precedes the FIRST digit — a `-*` test on the raw value missed " -5" and
# "\t-5", and `tr -cd` then turned them into 5 with no word said. P2-17: the WARN echoes that
# unvalidated value SANITIZED and capped (as the ZUVO_RUN_DEADLINE NOTE does), never raw.
_g1_tab="$(printf '\t')-5"
for _v in "sp: -5" "tab:$_g1_tab" "mid:x-5"; do
  _tag="g1-neg-${_v%%:*}"; _val="${_v#*:}"; cp "$CODE_DIFF" "$T/$_tag.in"
  rc=0; drive "$_tag" "$TSHIM:$MOCK_PATH" "$H1" ZUVO_TIMEOUT_GRACE="$_val" TIMEOUT_ARGV_LOG="$T/$_tag.targv" REAL_TIMEOUT="$SHIM/timeout" \
    -- --mode code --provider mock-success || rc=$?
  expect_eq "ar_decimal: ZUVO_TIMEOUT_GRACE [${_v%%:*}-led '-5'] is negative too → the default 15, never a silent 5" \
    "0|-k 15" "$rc|$(awk '/mock-success/ { print $1 " " $2; exit }' "$T/$_tag.targv" 2>/dev/null)"
  expect_has "ar_decimal: …with a WARN naming the default it used" "is negative — using 15" "$(err "$_tag")"
done
_g1_unsafe='-5;$(id)'"$(printf 'B%.0s' $(seq 1 30))"   # 8 + 30 = 38 raw chars, single-quoted: never run
cp "$CODE_DIFF" "$T/g1-neg-unsafe.in"
rc=0; drive g1-neg-unsafe "$MOCK_PATH" "$H1" ZUVO_TIMEOUT_GRACE="$_g1_unsafe" -- --mode code --provider mock-success || rc=$?
_g1_warn="$(err g1-neg-unsafe | awk '/ar_decimal: WARN/ { print; exit }')"
expect_has "ar_decimal: an unsafe negative value draws the WARN (present, so the checks below are not vacuous)" \
  "ar_decimal: WARN: '" "$_g1_warn"
expect_not "ar_decimal: …the WARN does not echo the raw metacharacters" '$(id)' "$_g1_warn"
_g1_shown="$(printf '%s' "$_g1_warn" | awk -F"'" '{ print $2; exit }')"
expect_eq "ar_decimal: …the shown value is [A-Za-z0-9._-] only and at most 20 chars" "1|-5idBBBBBBBBBBBBBBBB" \
  "$(printf '%s' "$_g1_shown" | awk '{ print (length($0) <= 20 && $0 !~ /[^a-zA-Z0-9._-]/) ? 1 : 0 }')|$_g1_shown"
# …and under a UTF-8 locale an invalid byte in the value neither leaks `tr: Illegal byte sequence` nor
# discards the digits (BSD tr fails on the whole input there — the value silently became the default).
if [ -n "$U8" ]; then
  cp "$CODE_DIFF" "$T/g1-badbytes.in"
  rc=0; drive g1-badbytes "$TSHIM:$MOCK_PATH" "$H1" LC_ALL="$U8" ZUVO_TIMEOUT_GRACE="$(printf '\377\3767')" \
    TIMEOUT_ARGV_LOG="$T/g1-badbytes.targv" REAL_TIMEOUT="$SHIM/timeout" -- --mode code --provider mock-success || rc=$?
  expect_eq "ar_decimal: ZUVO_TIMEOUT_GRACE=<invalid UTF-8>7 under LC_ALL=$U8 → its digit 7 is read, no tr error" "0|-k 7|" \
    "$rc|$(awk '/mock-success/ { print $1 " " $2; exit }' "$T/g1-badbytes.targv" 2>/dev/null)|$(err g1-badbytes | awk '/Illegal byte/')"
else
  locale_skip "the ar_decimal invalid-UTF-8 case"
fi
# P3-1: a Unicode minus before the first digit (U+2212 −, U+FE63 ﹣, U+FF0D －) is a sign too — `tr -cd`
# used to drop its bytes and read "−5" as a silent 5. Matched as UTF-8 BYTES, so the C locale every
# drive() runs in (env -i) sees it as well as a UTF-8 one; the WARN shows it as an ASCII `-`.
for _v in "u2212:$(printf '\342\210\222')5" "ufe63:$(printf '\357\271\243')5" "uff0d:$(printf '\357\274\215')5"; do
  _tag="g1-neg-${_v%%:*}"; _val="${_v#*:}"; cp "$CODE_DIFF" "$T/$_tag.in"
  rc=0; drive "$_tag" "$TSHIM:$MOCK_PATH" "$H1" ZUVO_TIMEOUT_GRACE="$_val" TIMEOUT_ARGV_LOG="$T/$_tag.targv" REAL_TIMEOUT="$SHIM/timeout" \
    -- --mode code --provider mock-success || rc=$?
  expect_eq "ar_decimal: ZUVO_TIMEOUT_GRACE=<${_v%%:*}>5 (a Unicode minus) is negative → the default 15, never a silent 5" \
    "0|-k 15" "$rc|$(awk '/mock-success/ { print $1 " " $2; exit }' "$T/$_tag.targv" 2>/dev/null)"
  expect_has "ar_decimal: …with the WARN, the sign shown as '-'" "'-5' is negative — using 15" "$(err "$_tag")"
done
if [ -n "$U8" ]; then
  cp "$CODE_DIFF" "$T/g1-neg-u8.in"
  rc=0; drive g1-neg-u8 "$TSHIM:$MOCK_PATH" "$H1" LC_ALL="$U8" ZUVO_TIMEOUT_GRACE="$(printf '\342\210\222')5" \
    TIMEOUT_ARGV_LOG="$T/g1-neg-u8.targv" REAL_TIMEOUT="$SHIM/timeout" -- --mode code --provider mock-success || rc=$?
  expect_eq "ar_decimal: …and under LC_ALL=$U8 too (−5 → the default 15, a WARN)" "0|-k 15|1" \
    "$rc|$(awk '/mock-success/ { print $1 " " $2; exit }' "$T/g1-neg-u8.targv" 2>/dev/null)|$(err g1-neg-u8 | awk '/is negative — using 15/ { n++ } END { print n + 0 }')"
else
  locale_skip "the ar_decimal Unicode-minus case under a UTF-8 locale"
fi
# P3-9: a value with NO digit at all is no number, not a negative one: "my-host" falls back to the
# default silently, like "abc" — it used to draw an "is negative" WARN for its hyphen.
cp "$CODE_DIFF" "$T/g1-nodigit.in"
rc=0; drive g1-nodigit "$TSHIM:$MOCK_PATH" "$H1" ZUVO_TIMEOUT_GRACE=my-host TIMEOUT_ARGV_LOG="$T/g1-nodigit.targv" \
  REAL_TIMEOUT="$SHIM/timeout" -- --mode code --provider mock-success || rc=$?
expect_eq "ar_decimal: a digit-less ZUVO_TIMEOUT_GRACE=my-host → the default 15" "0|-k 15" \
  "$rc|$(awk '/mock-success/ { print $1 " " $2; exit }' "$T/g1-nodigit.targv" 2>/dev/null)"
expect_not "ar_decimal: …with no 'is negative' WARN (a hyphen in a digit-less value is not a sign)" "is negative" "$(err g1-nodigit)"
# A `tr` for ar_decimal's own digit filter (`tr -cd 0-9`, the driver's only such call): it logs every
# input to TR_ARGV_LOG, one per line, and FAILS on an input holding TR_FAIL_ON; any other call is the
# real tr, untouched.
REAL_TR="$(PATH=/usr/bin:/bin command -v tr)"
TRSHIM="$T/trshim"; mkdir -p "$TRSHIM"
cat > "$TRSHIM/tr" <<'EOF'
#!/bin/sh
[ "$*" = "-cd 0-9" ] || exec "$REAL_TR" "$@"
_in="$(cat)"   # trailing newlines lost: this filter deletes them anyway
[ -z "${TR_ARGV_LOG:-}" ] || printf '%s\n' "$_in" >> "$TR_ARGV_LOG"
if [ -n "${TR_FAIL_ON:-}" ]; then case "$_in" in *"$TR_FAIL_ON"*) exit 1 ;; esac; fi
printf '%s' "$_in" | "$REAL_TR" "$@"
EOF
chmod +x "$TRSHIM/tr"
_st=0; _o="$(printf '4242x' | REAL_TR="$REAL_TR" TR_FAIL_ON=4242 "$TRSHIM/tr" -cd 0-9)" || _st=$?
expect_eq "premise: the tr shim fails on its trigger, and filters like tr otherwise" "1||42" \
  "$_st|$_o|$(printf 'x4y2' | REAL_TR="$REAL_TR" TR_FAIL_ON=4242 "$TRSHIM/tr" -cd 0-9)"
# P3-3: the digit filter carries the same `|| v=""` guard as the sign branch. Every driver call is
# `$(ar_decimal …)`, where errexit is off, so the guard is proven on the function itself: extracted
# from the driver and called DIRECTLY under `set -euo pipefail` with a failing tr, it prints the
# default and returns 0 — it never takes its caller down.
_ard="$(awk '/^ar_decimal\(\) \{$/ { f = 1 } f { print } f && /^}$/ { exit }' "$AR")"
expect_has "premise: ar_decimal() is extracted from the driver whole" "printf '%s' \"\$v\"" "$_ard"
# shellcheck disable=SC2016  # expanded by the child shell
_o="$(PATH="$TRSHIM:$PATH" REAL_TR="$REAL_TR" TR_FAIL_ON=424242 "$BASH" -c \
  'set -euo pipefail; eval "$1"; ar_decimal 424242 77; printf "|survived"' _ "$_ard" 2>/dev/null)"
expect_eq "ar_decimal: a failing digit filter, called directly under set -e → the default, the caller survives" "77|survived" "$_o"
# P3-10: without ZUVO_RUN_DEADLINE the computed deadline, once normalised, IS the deadline — it is not
# fed through ar_decimal a second time. Counted on the tr shim's input log, against the deadline the
# watchdog really armed (its `sleep`, the largest one the sleep shim saw). The lane answers after 1 s,
# so the watchdog's sleep has started (and logged) before the run ends.
printf '#!/bin/sh\nsleep "${MOCK_SLOW_SECONDS:-1}"\nexec mock-success\n' > "$SLOWM/mock-success-slow"; chmod +x "$SLOWM/mock-success-slow"
cp "$CODE_DIFF" "$T/g1-rd-once.in"
rc=0; drive g1-rd-once "$SSHIM:$TRSHIM:$SLOWM:$MOCK_PATH" "$H1" SLEEP_ARGV_LOG="$T/g1-rd-once.sleeps" REAL_SLEEP="$REAL_SLEEP" \
  TR_ARGV_LOG="$T/g1-rd-once.trin" REAL_TR="$REAL_TR" -- --mode code --provider mock-success-slow || rc=$?
_rd_armed="$(awk '/^[0-9]+$/ && $0 + 0 > m { m = $0 + 0 } END { print m + 0 }' "$T/g1-rd-once.sleeps" 2>/dev/null)"
expect_eq "premise: the run completes and its watchdog armed a deadline" "0|yes" "$rc|$([ "${_rd_armed:-0}" -gt 0 ] && echo yes)"
expect_eq "ar_decimal: no ZUVO_RUN_DEADLINE → the computed deadline ($_rd_armed) is normalised exactly once" "1" \
  "$(_W="$_rd_armed" awk '$0 == ENVIRON["_W"] { n++ } END { print n + 0 }' "$T/g1-rd-once.trin" 2>/dev/null)"

# G2: ZUVO_RUN_DEADLINE is a global knob meant for code/security/spec reviews — like
# ZUVO_REVIEW_TIMEOUT/ZUVO_REVIEW_MAX_PROVIDERS/ZUVO_REVIEW_PROVIDER above, it must be IGNORED in
# --mode blind-audit: a larger value would break the 585 s invariant this mode's callers rely on
# (they wait in a 600 s Bash call), a smaller one would SIGTERM the panel before a lane can answer.
# Proven for a small value, a large one, and the octal-looking `08` that used to crash bash
# arithmetic before this even mattered — in every case the deadline stays the default-derived
# 480s/555s and a NOTE names the ignored knob.
for _v in 5 9999 08; do
  _tag="g2-rd-$_v"
  rc=0; drive "$_tag" "$MOCK_PATH" "$H1" ZUVO_RUN_DEADLINE="$_v" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
  expect_eq "G2 ZUVO_RUN_DEADLINE=$_v: exit 3, no arithmetic error" "3|" \
    "$rc|$(err "$_tag" | awk '/value too great|syntax error/')"
  expect_has "G2 …the knob is ignored: deadline stays 480s per lane, whole-run deadline 555s" \
    "480s per lane, whole-run deadline 555s" "$(err "$_tag")"
  expect_has "G2 …a NOTE names the ignored knob" \
    "NOTE: ZUVO_RUN_DEADLINE='$_v' is ignored in --mode blind-audit" "$(err "$_tag")"
done
# The loop above proves "ignored" only by what stderr ANNOUNCES, with a lane that answers at once — a
# run over in well under 5 s cannot tell a 555 s watchdog from a 5 s one. Proven here by what the
# driver DOES: the watchdog's own `sleep` is armed with 555, never with the knob's value, and a lane
# that answers only after 8 s still completes normally under ZUVO_RUN_DEADLINE=2 (an honoured 2 s
# deadline would SIGTERM it: exit 124 at ~2 s). The time it took is measured against a CONTROL — the
# same run with a lane that answers at once — so the bound is this host's own overhead plus the lane's
# 8 s, not a guess about how fast the machine is: at least 6 s more than the control (8 s, less two
# whole-second roundings), where an honoured 2 s deadline could add 4 at most.
_g2_t0=$(date +%s)
rc=0; drive g2-rd-live-ctl "$SLOW_PATH" "$H1" ZUVO_RUN_DEADLINE=2 MOCK_SLOW_SECONDS=0 \
  REAL_SLEEP="$REAL_SLEEP" -- "${BA[@]}" --provider mock-strict-slow || rc=$?
_g2_ctl=$(( $(date +%s) - _g2_t0 ))
expect_eq "G2 control: the same run with a lane answering at once completes (exit 3)" "3" "$rc"
_g2_t0=$(date +%s)
rc=0; drive g2-rd-live "$SLOW_PATH" "$H1" ZUVO_RUN_DEADLINE=2 MOCK_SLOW_SECONDS=8 SLEEP_ARGV_LOG="$T/g2-rd-live.sleeps" \
  REAL_SLEEP="$REAL_SLEEP" -- "${BA[@]}" --provider mock-strict-slow || rc=$?
_g2_elapsed=$(( $(date +%s) - _g2_t0 ))
expect_eq "G2 ZUVO_RUN_DEADLINE=2 + a lane answering after 8 s: the run completes normally (exit 3, not 124)" "3" "$rc"
if [ $(( _g2_elapsed - _g2_ctl )) -ge 6 ]; then ok "G2 …the run really outlived the ignored 2 s by the lane's 8 s (elapsed ${_g2_elapsed}s, control ${_g2_ctl}s)"
else bad "G2 …elapsed ${_g2_elapsed}s is not 6 s past the control's ${_g2_ctl}s — the slow lane did not run as built, so this proves nothing"; fi
expect_eq "G2 …the watchdog was ARMED with 555 (once), and no sleep ever ran for the ignored 2" "1|0" \
  "$(sleeps g2-rd-live | awk '$0 == "555" { n++ } END { print n + 0 }')|$(sleeps g2-rd-live | awk '$0 == "2" { n++ } END { print n + 0 }')"

# G2 sanitization: the NOTE must not echo the raw knob verbatim — an oversized, non-alnum value must
# come out capped and stripped, not verbatim (unbounded output / stray shell metacharacters in a log
# line). Single-quoted so `$(id)` is inert text, never executed, both here and in the driver's NOTE.
_g2_unsafe='5;$(id)'"$(printf 'A%.0s' $(seq 1 30))"   # 7 + 30 = 37 raw chars
rc=0; drive g2-rd-unsafe "$MOCK_PATH" "$H1" ZUVO_RUN_DEADLINE="$_g2_unsafe" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "G2 sanitized NOTE: exit 3, no arithmetic error" "3|" \
  "$rc|$(err g2-rd-unsafe | awk '/value too great|syntax error/')"
expect_has "G2 sanitized NOTE …deadline still ignored (480s/555s, unaffected by the garbage value)" \
  "480s per lane, whole-run deadline 555s" "$(err g2-rd-unsafe)"
expect_not "G2 sanitized NOTE …the raw metacharacters do not reach stderr" '$(id)' "$(err g2-rd-unsafe)"
# The NOTE must be THERE before its value is judged: both checks below pass vacuously on an empty
# value, so a regression that dropped the NOTE altogether would otherwise go unseen.
expect_has "G2 sanitized NOTE …the NOTE line is present at all" "  NOTE: ZUVO_RUN_DEADLINE='" "$(err g2-rd-unsafe)"
_g2_note_val="$(err g2-rd-unsafe | awk -F"'" '/^  NOTE: ZUVO_RUN_DEADLINE=/ { print $2; exit }')"
expect_eq "G2 sanitized NOTE …the shown value is the sanitized, capped one (non-empty)" "5idAAAAAAAAAAAAAAAAA" "$_g2_note_val"
expect_eq "G2 sanitized NOTE …shown value is at most 20 chars (the raw value is 37)" "1" \
  "$(printf '%s' "$_g2_note_val" | awk '{ print (length($0) <= 20) ? 1 : 0 }')"
expect_eq "G2 sanitized NOTE …shown value holds only [A-Za-z0-9._-] (no ';' or '\$(…)' survived)" "1" \
  "$(printf '%s' "$_g2_note_val" | awk '{ print ($0 !~ /[^a-zA-Z0-9._-]/) ? 1 : 0 }')"

# G2 [CRITICAL] locale robustness: BSD tr exits non-zero ("Illegal byte sequence") on an invalid
# byte sequence when a UTF-8 locale is active. Under this script's `set -euo pipefail`, an unguarded
# `_rd_shown="$(... | tr ... )"` would take the WHOLE RUN down, not just the NOTE's display — the
# fix is LC_ALL=C on the tr call plus `|| _rd_shown=""`. Skipped visibly if no UTF-8 locale is
# installed on this host (found under whatever spelling it lists — see utf8_locale).
if [ -n "$U8" ]; then
  _g2_badbytes=$'\xff\xfe12'
  rc=0; drive g2-rd-badbytes "$MOCK_PATH" "$H1" LC_ALL="$U8" ZUVO_RUN_DEADLINE="$_g2_badbytes" \
    -- "${BA[@]}" --provider mock-strict-clean || rc=$?
  expect_eq "G2 invalid UTF-8 in ZUVO_RUN_DEADLINE under LC_ALL=$U8: the run does NOT abort (exit 3, same as any clean single-lane audit)" \
    "3" "$rc"
  expect_has "G2 …the mock panel still ran to its normal merged-block output" \
    "Audit mode: strict" "$(out g2-rd-badbytes | sed -n 1p)"
  expect_has "G2 …the NOTE still appears, showing only the surviving ASCII bytes ('12')" \
    "NOTE: ZUVO_RUN_DEADLINE='12' is ignored in --mode blind-audit" "$(err g2-rd-badbytes)"
else
  locale_skip "the G2 invalid-UTF-8 locale case"
fi

# G2 [cosmetic] an all-whitespace ZUVO_RUN_DEADLINE sanitizes to an EMPTY string — a bare
# `NOTE: ZUVO_RUN_DEADLINE=''` reads like a driver bug, not env input. Must show a human label.
rc=0; drive g2-rd-blank "$MOCK_PATH" "$H1" ZUVO_RUN_DEADLINE="   " -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "G2 all-whitespace ZUVO_RUN_DEADLINE: exit 3, run unaffected" "3" "$rc"
expect_has "G2 …the NOTE shows (unprintable), not empty quotes" \
  "NOTE: ZUVO_RUN_DEADLINE='(unprintable)' is ignored in --mode blind-audit" "$(err g2-rd-blank)"
expect_not "G2 …never shows a bare empty pair of quotes" "ZUVO_RUN_DEADLINE=''" "$(err g2-rd-blank)"

# G2 [hardening] bap_deadline's contract is "always digits, never more than the library's ceiling" —
# if it ever broke that promise, blind-audit must not silently run with NO watchdog while its skill
# callers wait in a bounded Bash call. Unreachable by construction today (bap_deadline always prints
# digits — see scripts/lib/blind-audit-panel.sh), so proven with a scratch copy of the LIBRARY
# (never the real file) whose bap_deadline is mutated to print nothing, run through an unmutated
# driver copy. Same technique as the "G unmapped" mutant test above.
_bap_ceiling="$(env -i PATH=/usr/bin:/bin bash -c '. "$1" && bap_run_ceiling' _ "$LIB" 2>/dev/null)"
_ceil_ok="$(printf '%s' "$_bap_ceiling" | awk '{ print ($0 ~ /^[1-9][0-9]*$/) ? 1 : 0 }')"
expect_eq "G2 empty-deadline premise: the library's ceiling accessor prints a positive integer" "1" "$_ceil_ok"
MUT2="$T/mut-empty-deadline"; mkdir -p "$MUT2/lib"
cp "$AR" "$MUT2/adversarial-review.sh"
cp "$(dirname "$AR")"/lib/*.sh "$MUT2/lib/"
awk -v q="  printf '%s\\\\n' \"\$d\"" -v r="  printf ''" \
   '{ if ($0 == q) { print r; n++ } else { print } } END { exit n != 1 }' \
   "$LIB" > "$MUT2/lib/blind-audit-panel.sh"
# PREMISE, asserted independently of the awk script's own exit code (which could itself be wrong):
# diff between the original and the mutated copy must show EXACTLY one changed line — one removed,
# one added (2 marker lines). Anything else (0 = mutation missed, >2 = it hit more than intended)
# fails loudly here, before the driver ever runs against this copy, so a missed mutation cannot pass
# by silently asserting against unmutated (correct) behavior.
_mut_marks="$(diff "$LIB" "$MUT2/lib/blind-audit-panel.sh" | awk '/^[<>]/ { n++ } END { print n + 0 }')"
# Every assertion on the mutated run lives INSIDE the premise branch: with a failed premise the run
# never happens, and an assertion outside would add a second, unrelated failure on an absent .err
# that hides the real (premise) one.
if [ "$_ceil_ok" != 1 ]; then
  echo "  SKIP G2 empty-deadline run — the ceiling premise above failed, its expected strings would be meaningless"
elif [ "$_mut_marks" -eq 2 ]; then
  ok "G2 empty-deadline premise: exactly one line differs between the original and mutated library (diff: 1 removed + 1 added)"
  # --protocol explicit: $MUT2 is a standalone scratch dir with no sibling shared/includes/ or
  # ~/.zuvo copy, and this test is about the deadline fallback, not protocol discovery. The lane
  # answers after 1 s (mock-strict-slow) so the watchdog's `sleep` has started, and logged, by then.
  rc=0; DRIVE_AR="$MUT2/adversarial-review.sh" drive g2-rd-emptydl "$SLOW_PATH" "$H1" SLEEP_ARGV_LOG="$T/g2-rd-emptydl.sleeps" \
    REAL_SLEEP="$REAL_SLEEP" -- "${BA[@]}" --protocol "$PROTO" --provider mock-strict-slow || rc=$?
  expect_eq "G2 bap_deadline returns empty: the run still completes (exit 3), not a crash" "3" "$rc"
  expect_has "G2 …whole-run deadline falls back to the library's ceiling (${_bap_ceiling}s), never silently 'none'" \
    "whole-run deadline ${_bap_ceiling}s" "$(err g2-rd-emptydl)"
  expect_not "G2 …never runs with no watchdog at all" "whole-run deadline none" "$(err g2-rd-emptydl)"
  expect_has "G2 …a WARN names the reason and the ceiling value" \
    "WARN: blind-audit whole-run deadline could not be derived; using the ceiling ${_bap_ceiling}s" "$(err g2-rd-emptydl)"
  # Announced is not enforced: the fallback must also be what the watchdog ARMS. Its `sleep` ran with
  # exactly the ceiling (waiting the real 585 s is out of reach; that the watchdog fires at its value
  # is g2-rdv's proof below, and the mechanism is one code path for every mode).
  expect_eq "G2 …and ARMED: the watchdog's sleep ran once, with the ceiling ${_bap_ceiling}" "1" \
    "$(sleeps g2-rd-emptydl | awk -v c="$_bap_ceiling" '$0 == c { n++ } END { print n + 0 }')"
else
  bad "G2 empty-deadline premise: expected exactly one changed line (2 diff marks), got $_mut_marks — the mutation missed or over-matched, this case would assert against the WRONG library"
fi

# G2 control: OUTSIDE blind-audit the knob still overrides. Two proofs, both --mode code (default):
#
# (1) VALUE proof for the octal-looking `08`: it must mean DECIMAL 8 seconds, not merely avoid an
#     arithmetic crash. A hanging provider with a much larger per-provider timeout isolates the
#     watchdog's actual value. Same technique AND same invocation shape as
#     tests/adversarial/test-hard-timeout-and-suspend.sh HT.3 (ZUVO_REVIEW_TEST_PROVIDERS + --files,
#     not --provider): an explicit --provider forces synchronous single-candidate dispatch, where a
#     foreground `timeout mock-hang` defers the TERM trap until IT exits — a real quirk, but not
#     this fix's — so it would fail this timing assertion for a reason unrelated to ar_decimal.
#     The bounds come from a CONTROL: the same run with ZUVO_RUN_DEADLINE=1 measures this host's own
#     overhead (start-up, the hung lane, the kill and teardown), so `08` must take about 7 s MORE than it
#     — at least 4 (not instant, not a 1 s deadline) and at most 30 (the 60 s provider budget would add
#     ~59). And by mechanism, not time: the watchdog's own `sleep` (the shim logs it) was armed with 8.
_g2_t0=$(date +%s)
rc=0; drive g2-rdv-ctl "$SLOW_PATH" "$H1" ZUVO_REVIEW_TIMEOUT=60 ZUVO_RUN_DEADLINE=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-hang \
  REAL_SLEEP="$REAL_SLEEP" -- --mode code --json --files "$EMPTYF" || rc=$?
_g2_ctl=$(( $(date +%s) - _g2_t0 ))
expect_eq "G2 control: ZUVO_RUN_DEADLINE=1, hung provider: exit 124" "124" "$rc"
_g2_t0=$(date +%s)
rc=0; drive g2-rdv "$SLOW_PATH" "$H1" ZUVO_REVIEW_TIMEOUT=60 ZUVO_RUN_DEADLINE=08 ZUVO_REVIEW_TEST_PROVIDERS=mock-hang \
  SLEEP_ARGV_LOG="$T/g2-rdv.sleeps" REAL_SLEEP="$REAL_SLEEP" -- --mode code --json --files "$EMPTYF" || rc=$?
_g2_elapsed=$(( $(date +%s) - _g2_t0 ))
expect_eq "G2 ZUVO_RUN_DEADLINE=08, --mode code, hung provider: exit 124 (deadline fired, not the 60s provider budget)" "124" "$rc"
_g2_extra=$(( _g2_elapsed - _g2_ctl ))
if [ "$_g2_extra" -ge 4 ] && [ "$_g2_extra" -le 30 ]; then
  ok "G2 …deadline fired at ~8s (elapsed ${_g2_elapsed}s, ${_g2_extra}s past the 1 s control: not instant, well under the 60s budget)"
else
  bad "G2 …deadline fired at ~8s — elapsed ${_g2_elapsed}s is ${_g2_extra}s past the 1 s control's ${_g2_ctl}s (expected about 7: floor 4, ceiling 30)"
fi
expect_eq "G2 …the watchdog was armed with decimal 8 (once)" "1" "$(sleeps g2-rdv | awk '$0 == "8" { n++ } END { print n + 0 }')"
# (2) the pre-existing octal-safety control: the same value must not crash bash arithmetic when the
#     provider answers immediately (the watchdog never fires here, so this only proves parse safety,
#     not the value — (1) above proves the value).
cp "$CODE_DIFF" "$T/g2-rdc.in"
rc=0; drive g2-rdc "$MOCK_PATH" "$H1" ZUVO_RUN_DEADLINE=08 -- --mode code --provider mock-success || rc=$?
expect_eq "G2 ZUVO_RUN_DEADLINE=08, --mode code, fast provider: exit 0, no arithmetic error" "0|" "$rc|$(err g2-rdc | awk '/value too great|syntax error/')"
# ZUVO_SUSPEND_THRESHOLD — compared with the measured sleep when nothing answered. A fake python3 makes
# the monotonic clock go BACK 80 s during the run, so the driver measures ~80 s of host sleep: `0100`
# (decimal 100, octal 64) must NOT be suspended (exit 2), `08` (decimal 8, not octal at all) must be
# (exit 125); the plain-decimal controls prove the fake clock both ways.
PYSHIM="$T/pyshim"; mkdir -p "$PYSHIM"
printf '#!/bin/sh\nif [ -f "$PY_MONO_STATE" ]; then echo 920; else : > "$PY_MONO_STATE"; echo 1000; fi\n' > "$PYSHIM/python3"; chmod +x "$PYSHIM/python3"
for _v in 100:2 8:125 0100:2 08:125; do
  _tag="g2-st-${_v%%:*}"; cp "$CODE_DIFF" "$T/$_tag.in"
  rc=0; drive "$_tag" "$PYSHIM:$MOCK_PATH" "$H1" ZUVO_SUSPEND_THRESHOLD="${_v%%:*}" PY_MONO_STATE="$T/$_tag.mono" \
    -- --mode code --provider mock-fail || rc=$?
  expect_eq "G2 ZUVO_SUSPEND_THRESHOLD=${_v%%:*} vs ~80 s of measured sleep → exit ${_v#*:}, no arithmetic error" "${_v#*:}|" \
    "$rc|$(err "$_tag" | awk '/value too great|syntax error/')"
done
# The agy cooldown file (driver-written: an epoch second) is read the same way: `0` + an epoch far in the
# future (decimal 7777777777 = year 2216, octal = 2004) must keep the model cooling down, and a stray `08`
# must be read as 8 (long past), not as an arithmetic error.
for _v in 07777777777:cool 08:free; do
  _tag="g2-cd-${_v%%:*}"; SD="$(spy_dir "$_tag")"; cp "$FXBA/clean.txt" "$SD/agy.reply"
  mkdir -p "$T/home-$_tag/.zuvo"; printf '%s\n' "${_v%%:*}" > "$T/home-$_tag/.zuvo/agy-cooldown-agy-primary"
  rc=0; drive "$_tag" "$SPY_PATH" "$H1" SPY_DIR="$SD" ZUVO_AGY_MODEL=agy-primary ZUVO_AGY_FALLBACK_MODEL=agy-fallback \
    -- "${BA[@]}" --provider agy || rc=$?
  _m="$(tr '\0' '\n' < "$SD/agy.argv0" 2>/dev/null | awk 'p { print; exit } $0 == "--model" { p = 1 }')"
  if [ "${_v#*:}" = cool ]; then _want=agy-fallback; else _want=agy-primary; fi
  expect_eq "G2 agy cooldown file [${_v%%:*}] → the run uses $_want, no arithmetic error" "$_want|" \
    "$_m|$(err "$_tag" | awk '/value too great|syntax error/')"
done

# F6: the panel always runs in parallel — --single / --rotate cannot change that, and say so once.
for _f in single rotate; do
  rc=0; drive "n6-$_f" "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite" \
    -- "${BA[@]}" "--$_f" || rc=$?
  expect_eq "F6 --$_f in this mode: the whole panel still ran (3 lanes), exit 0" "3|0" "$(ncalls "n6-$_f")|$rc"
  expect_eq "F6 …ONE stderr NOTE says --$_f is ignored" "1" \
    "$(err "n6-$_f" | awk -v f="--$_f" '/NOTE/ && index($0, f) && /ignored/ { n++ } END { print n + 0 }')"
done
# The controls run here, not borrowed from B1/M1: --provider alone, and the same panel with no flag.
rc=0; drive n6-ctl-provider "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "F6 control premise: --provider alone ran its lane (exit 3)" "3|mock-strict-clean" "$rc|$(calls n6-ctl-provider)"
expect_not "F6 control: --provider alone draws no such NOTE" "is ignored in --mode blind-audit" "$(err n6-ctl-provider)"
rc=0; drive n6-ctl-none "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix mock-strict-rewrite" -- "${BA[@]}" || rc=$?
expect_eq "F6 control premise: no flag, the whole panel ran (3 lanes), exit 0" "3|0" "$(ncalls n6-ctl-none)|$rc"
expect_not "F6 control: no flag, no NOTE" "is ignored in --mode blind-audit" "$(err n6-ctl-none)"
for _v in abc 0; do
  rc=0; drive "n2-$_v" "$MOCK_PATH" "$H1" ZUVO_BLIND_AUDIT_TIMEOUT="$_v" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
  expect_eq "N2 ZUVO_BLIND_AUDIT_TIMEOUT=$_v: the run completes (exit 3)" "3" "$rc"
  expect_has "N2 …a WARN names the variable" "ZUVO_BLIND_AUDIT_TIMEOUT" "$(err "n2-$_v" | awk '/WARN/')"
  expect_has "N2 …and the default 480 s applies" "480s per lane" "$(err "n2-$_v")"
done
rc=0; drive n2r "$MOCK_PATH" "$H1" ZUVO_REVIEW_TIMEOUT=7 -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_has "N2 ZUVO_REVIEW_TIMEOUT=7 does not apply in this mode (480 s)" "480s per lane" "$(err n2r)"
expect_not "N2 …and draws no timeout WARN" "ZUVO_BLIND_AUDIT_TIMEOUT" "$(err n2r | awk '/WARN/')"

# Failure evidence: a run whose only answers were INVALID produced no audit — its evidence is kept,
# the invalid replies included; a run with a valid answer keeps none (as in the other modes).
# N5's own runs, in their own homes: M4's panel (no valid answer) and M3's (one valid answer).
rc=0; drive n5 "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-invalid-block mock-echo-prompt mock-fail" -- "${BA[@]}" || rc=$?
expect_eq "N5 premise: no valid answer → exit 2" "2" "$rc"
rc=0; drive n5v "$MOCK_PATH" "$H1" ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-invalid-block mock-fail" -- "${BA[@]}" || rc=$?
expect_eq "N5 premise: one valid answer → exit 3" "3" "$rc"
_ev=""; for _d in "$T/home-n5/.zuvo/adversarial-failures"/*/; do [ -f "$_d/meta.txt" ] && { _ev="${_d%/}"; break; }; done
if [ -n "$_ev" ]; then ok "N5 no valid answer: failure evidence kept"; else bad "N5 no valid answer: no evidence dir under $T/home-n5/.zuvo/adversarial-failures"; fi
expect_has "N5 …meta.txt says mode=blind-audit" "mode=blind-audit" "$(cat "$_ev/meta.txt" 2>/dev/null)"
expect_has "N5 …meta.txt holds the invalid outcomes" "mock-invalid-block:invalid" "$(cat "$_ev/meta.txt" 2>/dev/null)"
expect_has "N5 …the invalid reply itself is kept" "| id | kind | lines | coverage | notes |" "$(cat "$_ev"/*mock-invalid-block* 2>/dev/null)"
expect_has "N5 …stderr names the evidence dir" "$T/home-n5/.zuvo/adversarial-failures/" "$(err n5)"
_ev3=0; for _d in "$T/home-n5v/.zuvo/adversarial-failures"/*/; do [ -d "$_d" ] && _ev3=$((_ev3 + 1)); done
expect_eq "N5 …a run with a valid answer keeps no evidence" "0" "$_ev3"

rc=0; drive help "$MOCK_PATH" -- --help || rc=$?
expect_eq "N6 --help exits 0" "0" "$rc"
for _w in "--mode blind-audit" --production --test --protocol ZUVO_BLIND_AUDIT_PANEL ZUVO_BLIND_AUDIT_ALLOWLIST \
          ZUVO_BLIND_AUDIT_TIMEOUT ZUVO_BLIND_AUDIT_EFFORT ZUVO_BLIND_AUDIT_ARGV_MAX ZUVO_BLIND_AUDIT_MAX_BYTES; do
  expect_has "N6 --help names $_w" "$_w" "$(out help)"
done
# exit_entry <code> — one entry of --help's exit-code table: its line and the indented lines under it.
exit_entry() { out help | awk -v c="$1" '/^Exit codes:/ { s = 1; next } s && /^[^ ]/ { exit }
  s && $1 ~ /^[0-9]+$/ { e = ($1 == c) } s && e' | tr '\n' ' '; }
expect_has "N6 exit code 3 keeps single_provider_only" "single_provider_only" "$(exit_entry 3)"
expect_has "N6 …and states its blind-audit meaning: degraded" "blind-audit: degraded" "$(exit_entry 3)"
expect_has "N6 exit code 6 is listed: blind-audit input too large" "blind-audit: input too large" "$(exit_entry 6)"
expect_has "N6 exit code 2 states its blind-audit meaning (no valid answer, stdout empty)" "no valid answer" "$(exit_entry 2)"
# ADV-A7/A8: exit 3 means two DIFFERENT things depending on --mode (single_provider_only in code/doc
# modes, degraded in blind-audit) and is not distinguishable by the exit code alone — --help must say so.
expect_has "N6 exit code 3 states it is scoped by --mode, not distinguishable by the code alone" \
  "scoped by --mode" "$(exit_entry 3)"
# ADV-A36: exit 124 means "every ATTEMPTED lane timed out with none answering AT ALL, even invalidly" —
# a mixed outcome (some invalid, some timeout) reports exit 2 instead, which --help must not leave
# looking like a documentation gap.
expect_has "N6 exit code 124 clarifies it is EVERY attempted lane, none answering at all (even invalidly)" \
  "none answering at all, even invalidly" "$(exit_entry 124)"

# N7's own runs: L4's (code mode, --exclude-last removes the only lane) and B2's (cursor-agent refused here).
cp "$CODE_DIFF" "$T/n7c.in"
rc=0; drive n7c "$MOCK_PATH" "$H1" -- --mode code --provider mock-success --exclude-last mock-success || rc=$?
expect_eq "N7 premise: code mode, --exclude-last removes the only lane → exit 1" "1" "$rc"
expect_has "N7 code mode: the no-lane ERROR block names the --exclude-last removal" "Excluded by --exclude-last: mock-success" \
  "$(err n7c | awk '/No cross-provider review tool found/ { s = 1 } s')"
SD="$(spy_dir n7b)"
rc=0; drive n7b "$SPY_PATH" "$H1" SPY_DIR="$SD" -- "${BA[@]}" --provider cursor-agent || rc=$?
expect_eq "N7 premise: blind-audit, --provider cursor-agent → no lane left, exit 1" "1" "$rc"
expect_has "N7 blind-audit: the no-lane ERROR block names the lane this mode refused" "cursor-agent" \
  "$(err n7b | awk '/No cross-provider review tool found/ { s = 1 } s && /blind audit/')"

# N8/N9: the blind-audit-only override at adversarial-review.sh's `PROVIDER_COUNT -eq 0 && -z
# ALL_RESULTS` branch — nothing answered at all, so the generic 2 (no valid answer) is replaced by
# 124 (every lane timed out) or 125 (the host itself was asleep), exactly as the other modes already
# do (mirrored from tests/adversarial/test-hard-timeout-and-suspend.sh's HT.3/HT.4, adapted to a
# blind-audit panel of one). No case anywhere else in this file drives PROVIDER_COUNT to 0 together
# with TIMEOUT_COUNT>0 or a real suspend in --mode blind-audit: M7 always leaves one lane answering.
rc=0; drive n8 "$MOCK_PATH" "$H1" ZUVO_BLIND_AUDIT_PANEL=1 ZUVO_BLIND_AUDIT_TIMEOUT=2 ZUVO_TIMEOUT_GRACE=1 \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout" -- "${BA[@]}" || rc=$?
expect_eq "N8 the panel's only lane times out (blind-audit) → exit 124, not the generic 2" "124" "$rc"
rc=0; drive n8j "$MOCK_PATH" "$H1" ZUVO_BLIND_AUDIT_PANEL=1 ZUVO_BLIND_AUDIT_TIMEOUT=2 ZUVO_TIMEOUT_GRACE=1 \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout" -- "${BA[@]}" --json || rc=$?
expect_eq "N8 --json: exit 124" "124" "$rc"
expect_eq "N8 --json: status=timeout" "timeout" "$(jq -r .status "$T/n8j.out" 2>&1)"

rc=0; drive n9 "$PYSHIM:$MOCK_PATH" "$H1" ZUVO_BLIND_AUDIT_PANEL=1 ZUVO_SUSPEND_THRESHOLD=8 \
  PY_MONO_STATE="$T/n9.mono" -- "${BA[@]}" --provider mock-fail || rc=$?
expect_eq "N9 host suspension during blind-audit → exit 125, not the generic 2" "125" "$rc"
rc=0; drive n9j "$PYSHIM:$MOCK_PATH" "$H1" ZUVO_BLIND_AUDIT_PANEL=1 ZUVO_SUSPEND_THRESHOLD=8 \
  PY_MONO_STATE="$T/n9j.mono" -- "${BA[@]}" --provider mock-fail --json || rc=$?
expect_eq "N9 --json: exit 125" "125" "$rc"
expect_eq "N9 --json: status=suspended" "suspended" "$(jq -r .status "$T/n9j.out" 2>&1)"

echo "=== RESULT ==="
[ "$LOCALE_SKIPS" -eq 0 ] || echo "NOT TESTED: $LOCALE_SKIPS locale case(s) — see the SKIP: lines above (no UTF-8 locale on this machine)"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
