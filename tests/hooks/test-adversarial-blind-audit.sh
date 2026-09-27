#!/usr/bin/env bash
#
# test-adversarial-blind-audit.sh — `adversarial-review.sh --mode blind-audit`: the blind coverage
# audit of ONE production file + its test file, run as a cross-vendor panel of isolated lanes
# (docs/specs/2026-09-25-blind-audit-panel-plan.md, Task 4 = input, isolation, panel dispatch).
#
# The decisions live in scripts/lib/blind-audit-panel.sh (tests/hooks/test-blind-audit-panel.sh pins
# them); this file pins the DRIVER's wiring of them, end to end:
#   A  input: --production/--test (+ --protocol) only in this mode, the other inputs refused, empty
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
# OLDPWD at startup, dash keeps it (same selection as the lane golden).
keeps_oldpwd() { env OLDPWD=/ "$1" -c '[ "${OLDPWD:-}" = / ]' 2>/dev/null; }
SPY_SH=""
for _s in /bin/sh /bin/dash /usr/bin/dash; do
  if [ -x "$_s" ] && keeps_oldpwd "$_s"; then SPY_SH="$_s"; break; fi
done
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
if [ -n "$SPY_SH" ]; then echo "  note: spy interpreter $SPY_SH (keeps an inherited OLDPWD)"
else echo "  note: no sh here keeps an inherited OLDPWD — the OLDPWD checks are skipped"; fi

# ── the file pair under audit ────────────────────────────────────────────────
P="$SRC/sum.sh"; TT="$SRC/sum.test.sh"; EMPTYF="$SRC/empty.sh"
printf '#!/bin/sh\nsum_or_zero() {\n  [ -z "$1" ] && { echo 0; return 0; }\n  t=0; for n in $1; do t=$((t + n)); done\n  echo "$t"\n}\n' > "$P"
printf '#!/bin/sh\n. ./sum.sh\n[ "$(sum_or_zero "1 2 3")" = 6 ] || exit 1\n' > "$TT"
: > "$EMPTYF"
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
    cat "$T/$tag.pipe" | ( cd "$WORK" && env -i HOME="$h" ZUVO_HOME="$h/.zuvo" TMPDIR="$T/tmp" CODEX_HOME="$FIX_CH" \
        ZUVO_NO_CAFFEINATE=1 ZUVO_PROVIDER_BENCH=0 ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
        MOCK_CALL_LOG="$T/$tag.calls" PATH="$path" ${envs[@]+"${envs[@]}"} bash "${DRIVE_AR:-$AR}" "$@" ) \
      > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
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
expect_eq "A3 …and no lane ran" "0" "$(ncalls a3f)"
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
expect_eq "A3 …and no lane ran" "0" "$(ncalls a3s)"
printf 'diff --git a/x b/x\n+x\n' > "$T/a3r.in"
rc=0; drive a3r "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A3 a file redirected to stdin in the mode → exit 2" "2" "$rc"
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
# refuses. A lone copy of the driver has no lib/ beside it and no ~/.zuvo copy in the temp HOME.
LONE="$T/lone"; mkdir -p "$LONE"; cp "$AR" "$LONE/adversarial-review.sh"
rc=0; DRIVE_AR="$LONE/adversarial-review.sh" drive a9 "$MOCK_PATH" "$H1" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "A9 library missing → --mode blind-audit exits 2" "2" "$rc"
expect_has "A9 …naming the file it looked for" "blind-audit-panel.sh" "$(err a9)"
expect_eq "A9 …and no lane ran" "0" "$(ncalls a9)"
printf 'diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n' > "$T/a9c.in"
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
if [ -e "$(rec b2 cursor-agent)" ]; then bad "B2 …and cursor-agent never ran"; else ok "B2 …and cursor-agent never ran"; fi
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
for _v in d1:"$BIG130": d2:"$MBF":LC_ALL=en_US.UTF-8; do
  _tag="${_v%%:*}"; _rest="${_v#*:}"; _f="${_rest%%:*}"; _loc="${_rest#*:}"
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
if [ -e "$(rec d3 agy)" ]; then bad "D3 agy ran with a $((120000 + ${#AGY_PREFIX} + 2))-byte argument"
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
# ("qwen-next"), with the driver's lib/ beside it. Real qwen must then stay (no vendor is guessed).
MUT="$T/unmapped"; mkdir -p "$MUT/lib"; cp "$(dirname "$AR")"/lib/*.sh "$MUT/lib/"
if awk '{ if (index($0, "echo \"qwen\" && return")) { sub(/echo "qwen"/, "echo \"qwen-next\""); n++ } print }
        END { exit n != 1 }' "$AR" > "$MUT/adversarial-review.sh"; then
  ok "G unmapped premise: the mutant renames exactly one host signal (qwen → qwen-next)"
else bad "G unmapped premise: the Qwen host line was not found exactly once in $AR"; fi
rc=0; DRIVE_AR="$MUT/adversarial-review.sh" drive g-unmapped "$MOCK_PATH" "$H1" QWEN_CODE=1 \
  ZUVO_REVIEW_TEST_PROVIDERS="qwen codex-5.3" -- --list-providers --mode blind-audit || rc=$?
expect_eq "G unmapped host → exit 0, no vendor guessed (qwen and codex-5.3 stay)" "0|qwen codex-5.3" \
  "$rc|$(out g-unmapped | tr '\n' ' ' | sed 's/ $//')"
expect_has "G unmapped …its own lane is excluded" "auto-excluding qwen-next" "$(err g-unmapped)"
expect_has "G unmapped …with ONE warning naming it" "qwen-next" "$(err g-unmapped | awk '/WARN/')"
expect_eq "G unmapped …exactly one such warning" "1" "$(err g-unmapped | awk '/WARN/ && /qwen-next/ { n++ } END { print n + 0 }')"
# The vendor rule is THIS mode's: a code review on a Claude host keeps claude (it flips Opus<->Sonnet).
cp "$T/a9c.in" "$T/g-code.in"
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
  if [ -n "$SPY_SH" ]; then expect_eq "H codex: OLDPWD is the neutral cwd (the checkout path is not handed over)" "$_pwd" "$(rec_get "$_r" OLDPWD_P)"; fi
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
  fi
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
if [ -e "$(rec h1 cursor-agent)" ]; then bad "H cursor-agent: it ran — its read tool is not scoped by --workspace"
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
  if [ -e "$(rec i1 "$_c")" ]; then bad "I1 $_c ran although the allowlist leaves it out"; else ok "I1 $_c did not run"; fi
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
  if [ -e "$(rec i2 "$_c")" ]; then bad "I2 $_c ran — an override WIDENED the allowlist"; else ok "I2 $_c still did not run (an override cannot widen)"; fi
  expect_has "I2 …stderr names $_c as refused" "$_c" "$(err i2 | awk '/efus/')"
done
for _c in codex claude kimi; do
  if [ -e "$(rec i2 "$_c")" ]; then bad "I2 $_c ran although the override leaves it out"; else ok "I2 $_c did not run (narrowed out)"; fi
done

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
for _t in l2 l3 l4; do cp "$T/a9c.in" "$T/$_t.in"; done
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
cp "$T/a9c.in" "$T/m7c.in"
rc=0; drive m7c "$MOCK_PATH" "$H1" ZUVO_PROVIDER_BENCH=1 ZUVO_PROVIDER_HEALTH_FILE="$T/health-m7c.tsv" -- --mode code --provider mock-fail || rc=$?
expect_eq "M7 control: --mode code still records an empty lane" "1/empty" "$(hrow "$T/health-m7c.tsv" mock-fail)"

# adversarial.log (in $ZUVO_HOME): one row per lane, col 3 = blind-audit, col 7 (findings) = the lane's
# uncovered rows in the merged block (0 for an invalid or failed lane); the severity columns do not apply.
LOGF="$T/home-m2/.zuvo/adversarial.log"
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
expect_eq "M8 …a failed lane: 0 rows, empty, exit 1" "0|empty|1" "$(lrow "$T/home-m3/.zuvo/adversarial.log" mock-fail)"

rc=0; drive m9 "$MOCK_PATH" "$H1" ZUVO_BLIND_AUDIT_TIMEOUT=900 -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_eq "M9 ZUVO_BLIND_AUDIT_TIMEOUT=900: the run still completes (exit 3)" "3" "$rc"
expect_has "M9 …a WARN names the variable and the 510-second ceiling" "510" "$(err m9 | awk '/WARN/ && /ZUVO_BLIND_AUDIT_TIMEOUT/')"
expect_has "M9 …and the lanes run with 510 s" "510s per lane" "$(err m9)"

# ═══ N. what Task 4 left ═════════════════════════════════════════════════════
echo "-- N. deadline, timeout knob, failure evidence, --help, the no-lane message"
expect_has "N1 default: 480 s per lane, whole-run deadline 555 s (480 + 15 grace + 60)" "480s per lane, whole-run deadline 555s" "$(err m1)"
expect_has "N1 clamped: 510 + 15 + 60 = 585 s, under the skill's 600 s Bash call" "whole-run deadline 585s" "$(err m9)"
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
  _g="${_v%%:*}"; _want="${_v#*:}"; _tag="g1-$_g"; cp "$T/a9c.in" "$T/$_tag.in"
  rc=0; drive "$_tag" "$TSHIM:$MOCK_PATH" "$H1" ZUVO_TIMEOUT_GRACE="$_g" TIMEOUT_ARGV_LOG="$T/$_tag.targv" REAL_TIMEOUT="$SHIM/timeout" \
    -- --mode code --provider mock-success || rc=$?
  expect_eq "G1 --mode code, ZUVO_TIMEOUT_GRACE=$_g: the review completes (exit 0, no arithmetic error)" "0|" \
    "$rc|$(err "$_tag" | awk '/value too great|syntax error/')"
  expect_eq "G1 …the lane's kill grace is $_want (decimal)" "-k $_want" \
    "$(awk '/mock-success/ { print $1 " " $2; exit }' "$T/$_tag.targv" 2>/dev/null)"
done
rc=0; drive g1-ba "$MOCK_PATH" "$H1" ZUVO_TIMEOUT_GRACE=0060 -- "${BA[@]}" --provider mock-strict-clean || rc=$?
expect_has "G1 blind-audit, grace 0060 = grace 60: 465s per lane, deadline 585s" "465s per lane, whole-run deadline 585s" "$(err g1-ba)"

# G1 class: EVERY digit-filtered number in the driver that reaches bash arithmetic is decimal.
# ZUVO_RUN_DEADLINE — the watchdog's sleep, the suspend budget; `08` used to print "value too great for
# base" and silently leave the run WITHOUT a watchdog. Read through the blind-audit announcement.
for _v in 08:8 0100:100; do
  _tag="g2-rd-${_v%%:*}"
  rc=0; drive "$_tag" "$MOCK_PATH" "$H1" ZUVO_RUN_DEADLINE="${_v%%:*}" -- "${BA[@]}" --provider mock-strict-clean || rc=$?
  expect_eq "G2 ZUVO_RUN_DEADLINE=${_v%%:*}: exit 3, no arithmetic error" "3|" "$rc|$(err "$_tag" | awk '/value too great|syntax error/')"
  expect_has "G2 …the whole-run deadline is ${_v#*:}s (decimal)" "whole-run deadline ${_v#*:}s" "$(err "$_tag")"
done
cp "$T/a9c.in" "$T/g2-rdc.in"
rc=0; drive g2-rdc "$MOCK_PATH" "$H1" ZUVO_RUN_DEADLINE=08 -- --mode code --provider mock-success || rc=$?
expect_eq "G2 ZUVO_RUN_DEADLINE=08, --mode code: exit 0, no arithmetic error" "0|" "$rc|$(err g2-rdc | awk '/value too great|syntax error/')"
# ZUVO_SUSPEND_THRESHOLD — compared with the measured sleep when nothing answered. A fake python3 makes
# the monotonic clock go BACK 80 s during the run, so the driver measures ~80 s of host sleep: `0100`
# (decimal 100, octal 64) must NOT be suspended (exit 2), `08` (decimal 8, not octal at all) must be
# (exit 125); the plain-decimal controls prove the fake clock both ways.
PYSHIM="$T/pyshim"; mkdir -p "$PYSHIM"
printf '#!/bin/sh\nif [ -f "$PY_MONO_STATE" ]; then echo 920; else : > "$PY_MONO_STATE"; echo 1000; fi\n' > "$PYSHIM/python3"; chmod +x "$PYSHIM/python3"
for _v in 100:2 8:125 0100:2 08:125; do
  _tag="g2-st-${_v%%:*}"; cp "$T/a9c.in" "$T/$_tag.in"
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
expect_not "F6 control: --provider alone draws no such NOTE" "is ignored in --mode blind-audit" "$(err b1)"
expect_not "F6 control: no flag, no NOTE" "is ignored in --mode blind-audit" "$(err m1)"
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
_ev=""; for _d in "$T/home-m4/.zuvo/adversarial-failures"/*/; do [ -f "$_d/meta.txt" ] && { _ev="${_d%/}"; break; }; done
if [ -n "$_ev" ]; then ok "N5 no valid answer: failure evidence kept"; else bad "N5 no valid answer: no evidence dir under $T/home-m4/.zuvo/adversarial-failures"; fi
expect_has "N5 …meta.txt says mode=blind-audit" "mode=blind-audit" "$(cat "$_ev/meta.txt" 2>/dev/null)"
expect_has "N5 …meta.txt holds the invalid outcomes" "mock-invalid-block:invalid" "$(cat "$_ev/meta.txt" 2>/dev/null)"
expect_has "N5 …the invalid reply itself is kept" "| id | kind | lines | coverage | notes |" "$(cat "$_ev"/*mock-invalid-block* 2>/dev/null)"
expect_has "N5 …stderr names the evidence dir" "$T/home-m4/.zuvo/adversarial-failures/" "$(err m4)"
_ev3=0; for _d in "$T/home-m3/.zuvo/adversarial-failures"/*/; do [ -d "$_d" ] && _ev3=$((_ev3 + 1)); done
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

expect_has "N7 code mode: the no-lane ERROR block names the --exclude-last removal" "Excluded by --exclude-last: mock-success" \
  "$(err l4 | awk '/No cross-provider review tool found/ { s = 1 } s')"
expect_has "N7 blind-audit: the no-lane ERROR block names the lane this mode refused" "cursor-agent" \
  "$(err b2 | awk '/No cross-provider review tool found/ { s = 1 } s && /blind audit/')"

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
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
