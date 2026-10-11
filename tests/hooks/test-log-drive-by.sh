#!/usr/bin/env bash
# Tests ~/.zuvo/log-drive-by (scripts/zuvo-home/log-drive-by). Records a receipt that the
# "Drive-by findings" step ran, with per-category counts, without forcing findings.
# Level: medium — real processes, git repos and file I/O, each case in its own temp ZUVO_HOME.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LD="$ROOT/scripts/zuvo-home/log-drive-by"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

# run <case> <args…> — runs the helper with a fresh ZUVO_HOME and --project p, so no case sees
# another's log. Sets OUT, ERR, RC; ROW = the last row minus its DATE column.
run() {
  local c="$1"; shift
  CASE_HOME="$TMP/$c"
  OUT="$(ZUVO_HOME="$CASE_HOME" bash "$LD" --project p "$@" 2>"$TMP/$c.err")"; RC=$?
  ERR="$(cat "$TMP/$c.err")"
  ROW="$(tail -1 "$CASE_HOME/drive-by.log" 2>/dev/null | cut -f2-)"
}
# expect_row <name> <expected SKILL…READ, TAB-separated> — whole-row equality, exit 0.
expect_row() {
  if [ "$RC" -eq 0 ] && [ "$ROW" = "$2" ]; then ok "$1"; else bad "$1 — rc=$RC row=[$ROW] want=[$2]"; fi
}
T=$'\t'

echo "=== each count flag lands in its own column (catches a swapped or dropped column) ==="
while IFS='|' read -r flag want; do
  run "col$flag" --skill build "--$flag" 7
  expect_row "--$flag 7 -> its column" "$want"
done <<EOF
sec|build${T}p${T}7${T}7${T}0${T}0${T}0${T}0${T}0${T}0${T}0
bug|build${T}p${T}7${T}0${T}7${T}0${T}0${T}0${T}0${T}0${T}0
size|build${T}p${T}7${T}0${T}0${T}7${T}0${T}0${T}0${T}0${T}0
dup|build${T}p${T}7${T}0${T}0${T}0${T}7${T}0${T}0${T}0${T}0
cplx|build${T}p${T}7${T}0${T}0${T}0${T}0${T}7${T}0${T}0${T}0
perf|build${T}p${T}7${T}0${T}0${T}0${T}0${T}0${T}7${T}0${T}0
dead|build${T}p${T}7${T}0${T}0${T}0${T}0${T}0${T}0${T}7${T}0
read|build${T}p${T}7${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}7
EOF

echo "=== totals, forms and defaults ==="
run total --skill build --sec 2 --dup 1 --read=3
expect_row "TOTAL sums the categories; --flag=value form accepted" "build${T}p${T}6${T}2${T}0${T}0${T}1${T}0${T}0${T}0${T}3"
[ "$OUT" = "log-drive-by: recorded 6 drive-by finding(s) (SEC:2) for build on p" ] \
  && ok "stdout confirms the recorded total and SEC" || bad "stdout: $OUT"
run zero --skill review
expect_row "no counts = honest all-zero row" "review${T}p${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0"
[ "$(head -1 "$CASE_HOME/drive-by.log")" = "# DATE${T}SKILL${T}PROJECT${T}TOTAL${T}SEC${T}BUG${T}SIZE${T}DUP${T}CPLX${T}PERF${T}DEAD${T}READ" ] \
  && ok "a new log starts with the column header" || bad "header: $(head -1 "$CASE_HOME/drive-by.log")"
run noskill
expect_row "missing --skill defaults to 'unknown'" "unknown${T}p${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0"
run proj --skill build --project "my repo/x"
expect_row "an explicit --project wins over the git name and is sanitized" "build${T}myrepox${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0"

run emptied --skill "';;" --project "//"
expect_row "a skill or project that sanitizes to nothing falls back to 'unknown'" "unknown${T}unknown${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0"
run trailing --skill build --read
expect_row "a trailing count flag with no value records 0" "build${T}p${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0"

echo "=== project resolution without --project ==="
# proj_of <dir> — the PROJECT column the helper records when run from <dir>.
proj_of() {
  local h; h="$(mktemp -d "$TMP/pr.XXXXXX")"
  (cd "$1" && ZUVO_HOME="$h" bash "$LD" --skill s >/dev/null 2>&1); tail -1 "$h/drive-by.log" | cut -f3
}
mkdir -p "$TMP/main-repo" "$TMP/plain dir"
git -C "$TMP/main-repo" init -q && git -C "$TMP/main-repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$TMP/main-repo" worktree add -q "$TMP/linked-wt" -b wt 2>/dev/null || bad "fixture: git worktree add failed"
[ "$(proj_of "$TMP/main-repo")" = "main-repo" ] && ok "inside a repo: the repo's basename" || bad "repo: $(proj_of "$TMP/main-repo")"
[ "$(proj_of "$TMP/linked-wt")" = "main-repo" ] && ok "inside a linked worktree: the MAIN checkout's name, not the worktree's" || bad "worktree: $(proj_of "$TMP/linked-wt")"
[ "$(PROJECT=plan-slug proj_of "$TMP/main-repo")" = "main-repo" ] && ok "an inherited PROJECT env var is ignored (an orchestrator's plan-slug must not mis-attribute the row)" || bad "inherited PROJECT used"
[ "$(GIT_CEILING_DIRECTORIES="$TMP" proj_of "$TMP/plain dir")" = "plaindir" ] && ok "outside git: the sanitized directory name" || bad "plain: $(GIT_CEILING_DIRECTORIES="$TMP" proj_of "$TMP/plain dir")"

echo "=== CRITICAL regression: a trailing value-flag must NOT infinite-loop ==="
# Stock macOS ships no `timeout`: an unresolved binary exits 127, which a "not 124" check would
# read as "no hang" without ever running the script. Resolve it, and fail loudly when it is absent.
TO="$(command -v timeout || command -v gtimeout || true)"
if [ -z "$TO" ]; then
  bad "no timeout/gtimeout on PATH — the hang regression cannot be checked here"
else
  for args in "--skill" "--sec" "--project" "--sec 3 --skill" "--skill build --read"; do
    ZUVO_HOME="$TMP/hang" "$TO" 10 bash "$LD" $args >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && ok "no hang, exit 0: [$args]" || bad "rc=$rc (124 = HANG) on trailing flag: [$args]"
  done
fi

echo "=== bad input is reported, never silently read as a count ==="
run swallow --skill --sec 3
expect_row "--skill --sec 3 keeps SEC=3 (a value-less flag must not swallow the next flag)" "unknown${T}p${T}3${T}3${T}0${T}0${T}0${T}0${T}0${T}0${T}0"
run typo --skill build --secc 2
[ "$ERR" = "log-drive-by: ignored unknown flag: --secc" ] && ok "a misspelled flag is named on stderr" || bad "typo stderr: [$ERR]"
expect_row "…and the row still records SEC=0, not 2" "build${T}p${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0${T}0"
run stray --skill build extra
[ "$ERR" = "log-drive-by: ignored stray argument: extra" ] && ok "a stray argument is named on stderr" || bad "stray stderr: [$ERR]"
run inject --skill "x'; rm -rf /tmp/xx" --sec "9a9" --bug 99999999999999999999 --dup 3.5
expect_row "skill sanitized, non-numeric counts recorded as 0 (not 9a9 -> 99), absurd count clipped to 6 digits" "xrm-rftmpxx${T}p${T}999999${T}0${T}999999${T}0${T}0${T}0${T}0${T}0${T}0"
[ "$ERR" = "log-drive-by: ignored non-numeric --sec value: 9a9
log-drive-by: ignored non-numeric --dup value: 3.5" ] && ok "each non-numeric count is named on stderr" || bad "non-numeric stderr: [$ERR]"
run octal --skill build --sec 08 --bug 09
expect_row "08 and 09 are read as decimal 8 and 9 (catches a dropped 10#: octal error, non-zero exit)" "build${T}p${T}17${T}8${T}9${T}0${T}0${T}0${T}0${T}0${T}0"

echo "=== a receipt that cannot be written says so and still exits 0 ==="
mkdir -p "$TMP/dirlog/drive-by.log"            # a directory where the file should be
ERR="$(ZUVO_HOME="$TMP/dirlog" bash "$LD" --skill build 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ "$ERR" = "log-drive-by: receipt NOT written (cannot append to $TMP/dirlog/drive-by.log)" ] \
  && ok "unappendable log: exit 0 + named on stderr" || bad "rc=$RC err=[$ERR]"
: > "$TMP/afile"
ERR="$(ZUVO_HOME="$TMP/afile/zh" bash "$LD" --skill build 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ "$ERR" = "log-drive-by: receipt NOT written (cannot create $TMP/afile/zh)" ] \
  && ok "uncreatable ZUVO_HOME: exit 0 + named on stderr" || bad "rc=$RC err=[$ERR]"
ERR="$(env -u HOME -u ZUVO_HOME bash "$LD" --skill build 2>&1 >/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && [ "$ERR" = "log-drive-by: receipt NOT written (neither ZUVO_HOME nor HOME is set)" ] \
  && ok "no HOME and no ZUVO_HOME: exit 0 + named (set -u must not abort)" || bad "rc=$RC err=[$ERR]"

mkdir -p "$TMP/home"
env -u ZUVO_HOME HOME="$TMP/home" bash "$LD" --project p --skill build >/dev/null 2>&1
[ "$(tail -1 "$TMP/home/.zuvo/drive-by.log" | cut -f2-3)" = "build${T}p" ] \
  && ok "without ZUVO_HOME the receipt goes to \$HOME/.zuvo/drive-by.log" || bad "HOME fallback: $(ls -R "$TMP/home" 2>&1 | tr '\n' ' ')"

echo "=== concurrent first writers keep one header and every row ==="
for i in 1 2 3 4 5 6 7 8; do ZUVO_HOME="$TMP/conc" bash "$LD" --project p --skill "c$i" >/dev/null 2>&1 & done; wait
[ "$(grep -c '^# DATE' "$TMP/conc/drive-by.log")" -eq 1 ] && ok "exactly one header" || bad "header count $(grep -c '^# DATE' "$TMP/conc/drive-by.log")"
[ "$(grep -v '^#' "$TMP/conc/drive-by.log" | cut -f2 | sort | tr '\n' ' ')" = "c1 c2 c3 c4 c5 c6 c7 c8 " ] \
  && ok "all 8 concurrent rows survived, each exactly once (no truncation by a late header write)" || bad "rows: $(cut -f2 "$TMP/conc/drive-by.log" | tr '\n' ' ')"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
