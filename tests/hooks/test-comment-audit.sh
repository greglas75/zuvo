#!/usr/bin/env bash
# Contract for scripts/zuvo-home/comment-audit: which lines a change authored, and what the exit code means.
# rc 1 sends an agent to rewrite comments, so a git or internal error must read as rc 2, never as 1. Every
# expected id is sha1 of the comment text computed here, every git fixture is a temp repo.
# Level: integration — the CLI runs against hermetic git repositories under mktemp; no network.
#
# bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || { echo "FAIL: cannot resolve the repo root"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
HELPERS="$ROOT/scripts/zuvo-home"
CLI="$HELPERS/comment-audit"
fail=0
npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }
finish() { printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"; exit "$fail"; }
check() { if [ "$1" = "$2" ]; then pass "$3"; else bad "$3 — got [$1], want [$2]"; fi; }
skip() { [ "$fail" -eq 0 ] || finish; echo "SKIP: $1"; exit 0; }

# Needs no python, so it runs before the SKIP gate; a failure here is a FAIL, never a SKIP.
if [ -f "$CLI" ] && [ -x "$CLI" ]; then pass "comment-audit exists and is executable"
else bad "scripts/zuvo-home/comment-audit is missing or not executable"; finish; fi
check "$(head -4 "$CLI")" "$(head -4 "$HELPERS/adversarial-stats")" "the polyglot header is identical to adversarial-stats"
for module in zuvo_comment_scan.py zuvo_comment_rules.py zuvo_comment_ledger.py; do
  if [ -f "$HELPERS/$module" ]; then pass "$module sits next to the CLI"; else bad "$module is missing"; finish; fi
done

for tool in python3 git perl; do command -v "$tool" >/dev/null 2>&1 || skip "$tool not available"; done
export PYTHONDONTWRITEBYTECODE=1 PYTHONIOENCODING=utf-8 PYTHONUTF8=1 PYTHONUNBUFFERED=1 LC_ALL=C LANG=C

TMP="$(mktemp -d)" && TMP="$(cd "$TMP" && pwd -P)" || { echo "FAIL: mktemp -d failed"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" ZUVO_COMMENT_AUDIT_LOG="$TMP/ledger.log" GIT_CEILING_DIRECTORIES="$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_EXTERNAL_DIFF GIT_DIFF_OPTS ZUVO_HOME
unset ZUVO_COMMENT_MAX_DENSITY ZUVO_COMMENT_MIN_LINES ZUVO_COMMENT_BLOCK_MIN ZUVO_COMMENT_JUSTIFY_MAX
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$TMP/norepo" "$TMP/shim" "$TMP/nogit" || { bad "cannot create the sandbox"; finish; }
LIMIT=120
sed "s#^REALGIT#exec $(command -v git)#" > "$TMP/shim/git" <<'SH'
#!/bin/sh
case "${SHIM:-}: $* " in
  hang-diff:*" diff "*|hang-rev:*" rev-parse "*) exec sleep 30 ;;
  junk:*" diff "*) printf 'diff --git a/x b/y\n'; exit 0 ;;
  short:*" --batch "*) read -r _; printf '%040d blob 100\nabc' 0; exit 0 ;;
  count:*" --batch-check "*) cat > /dev/null; printf '%040d blob 1\n%040d blob 1\n' 0 0; exit 0 ;;
  vanish:*" --others "*) rm -f vanish.py ;;
  todir:*" --others "*) rm -f vanish.py; mkdir vanish.py ;;
esac
REALGIT "$@"
SH
chmod +x "$TMP/shim/git"

repo()   { R="$TMP/$1"; mkdir -p "$R" && git -C "$R" -c init.defaultBranch=main init -q; }
put()    { mkdir -p "$(dirname "$R/$1")" && printf '%b' "$2" > "$R/$1"; }
putb()   { python3 -c 'import sys; open(sys.argv[1], "wb").write(eval(sys.argv[2], {"__builtins__": {}}))' "$R/$1" "$2"; }
commit() { git -C "$R" add -A && git -C "$R" -c user.name=Test -c user.email=test@example.invalid \
             -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm "${1:-fixture}"; }
bounded() { perl -e 'alarm shift; exec @ARGV' "$LIMIT" "$@"; }
# Every run happens under $TMP, is killed after $LIMIT s, and stores its exit code in $rc before anything else.
audit()  {
  local dir="${CWD:-$R}"
  case "$dir/" in "$TMP"/*) ;; *) bad "refusing to run the CLI outside \$TMP: $dir"; rc=99; return ;; esac
  ( cd "$dir" && bounded "${BIN:-$CLI}" "$@" ) > "$TMP/out" 2> "$TMP/err"; rc=$?
}
# closed out|err ARGS: that stream is a pipe whose reader is gone before the CLI starts; prints rc, the byte
# count of the other stream and whether it holds a traceback.
closed() {
  ( cd "${CWD:-$R}" && env -u PYTHONUNBUFFERED python3 -c 'import os, subprocess, sys
r, w = os.pipe(); os.close(r)
out = sys.argv[1] == "out"
p = subprocess.run(sys.argv[2:], stdout=w if out else subprocess.PIPE, stderr=subprocess.PIPE if out else w, timeout=120)
seen = (p.stderr if out else p.stdout) or b""
print(p.returncode, len(seen), b"Traceback" in seen or b"Exception ignored" in seen)' "$1" "${BIN:-$CLI}" "${@:2}" )
}
sha8()   { printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:8])'; }
last()   { tail -n "$1" "$TMP/out" | head -1; }
runid()  { sed -n 's/^RESULT: comment-pass [A-Z/]* run=\([^ ]*\) .*/\1/p' "$TMP/out"; }
j()      { python3 -c 'import json, re, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except ValueError:
    sys.exit(print("JSON-PARSE-FAILED"))
F = lambda path: next((f for f in d["files"] if f["path"] == path), {})
print(eval(sys.argv[2]))' "$TMP/out" "$1" 2>&1; }
vj()     { j '"|".join(f["verdict"] for f in d["files"])'; }
row()    { awk -v p="$1" '$1 == p { print $NF }' "$TMP/out"; }
rc_is()  { check "$rc" "$1" "$2"; }
has()    { if grep -qF -- "$1" "$TMP/out"; then pass "$2"; else bad "$2 — no [$1] in: $(head -c 600 "$TMP/out")"; fi; }
line_is() { if grep -qxF -- "$1" "$TMP/out"; then pass "$2"; else bad "$2 — no line [$1] in: $(head -c 600 "$TMP/out")"; fi; }
errors_cleanly() {  # <stderr fragment> <label>: rc 2, exactly one stderr line naming the cause, not a crash
  local line ok=1; line=$(head -1 "$TMP/err")
  { [ "$rc" -eq 2 ] && [ "$(awk 'END { print NR }' "$TMP/err")" -eq 1 ]; } || ok=0
  case "$line" in *"$1"*) ;; *) ok=0 ;; esac
  case "$1|$line" in *"internal error"*"|"*) ;; *"|"*"internal error"*) ok=0 ;; esac
  if [ "$ok" -eq 1 ]; then pass "$2"; else bad "$2 — rc $rc, stderr: $(head -c 300 "$TMP/err")"; fi
}
FIX="fixture setup failed"
HINT_N="move the history to the commit message or a runbook; keep only the current constraint"
HINT_L="cut to the WHY, or delete it if it restates the code"
DEFAULTS="density=0.30(default) min_lines=20(default) block=4(default) justify_max=2(default)"

# ── a clean file, a narrative comment, the machine lines, justification ──────
repo basic && put app.py 'import os\n\n\ndef load(path):\n    return open(path).read()\n' && commit || { bad "$FIX: basic"; finish; }
put clean.py 'def add(a, b):\n    return a + b\n'
audit --files clean.py; run=$(runid)
check "$rc|$(awk '$1=="clean.py" { print $2, $3, $4, $5, $6, $7, $8, $9, $10 }' "$TMP/out")" "0|python 2 0 - 0.000 0 0 0 pass" "a clean file: rc 0; 2 authored code lines, density not gated under 20 lines, whole-file 0.000"
printf '%s' "$run" | grep -Eq '^[0-9]{8}T[0-9]{6}Z-[0-9]+$' && pass "run id is <UTC yyyymmddTHHMMSSZ>-<pid>" || bad "run id [$run]"
check "$(tail -n 3 "$TMP/out" | tr '\n' '|')" "thresholds: $DEFAULTS|RESULT: comment-pass PASS run=$run files=1 findings=0 justified=0|comment_pass: run=$run files=1 max_density=- narrative=0 long=0 density_breaches=0 claims=0 justified=0 verdict=pass|" "the last three lines are thresholds, RESULT and comment_pass, sharing one run id"
put app.py 'import os\n\n# previously the cache was global\ndef load(path):\n    return open(path).read()\n'
ID="N:app.py:$(sha8 'previously the cache was global')"
audit --files app.py; run=$(runid)
rc_is 1 "an added '# previously ...' comment exits 1"
line_is "app.py:3 N $ID \"previously the cache was global\" -> $HINT_N [N-history]" "the finding line is 'path:line RULE ID \"text\" -> hint [sub]'"
check "$(tail -n 2 "$TMP/out" | tr '\n' '|')" "RESULT: comment-pass BREACH run=$run files=1 findings=1 justified=0|comment_pass: run=$run files=1 max_density=- narrative=1 long=0 density_breaches=0 claims=0 justified=0 verdict=breach|" "RESULT says BREACH with one finding; comment_pass counts it"
audit --files app.py --justify "$ID=the history explains why the cache is per request"; run=$(runid)
check "$rc|$(row app.py)" "0|justified" "an accepted --justify: rc 0, verdict 'justified'"
check "$(tail -n 2 "$TMP/out" | tr '\n' '|')" "RESULT: comment-pass PASS run=$run files=1 findings=1 justified=1|comment_pass: run=$run files=1 max_density=- narrative=1 long=0 density_breaches=0 claims=0 justified=1 verdict=pass|" "both machine lines carry justified=1"
audit --files app.py --justify "$ID=1234567890123456789"
check "$rc|$(row app.py)|$(grep -c "^REJECTED $ID (short)" "$TMP/out")" "1|breach|1" "a 19-character reason is rejected: rc 1, verdict breach"
audit --files clean.py --justify "N:clean.py:deadbeef=a reason that is long enough to count"
check "$rc|$(grep -c '^WARN stale justification N:clean.py:deadbeef$' "$TMP/out")" "0|1" "a stale justification is a WARN line and leaves rc 0"
audit --json --files clean.py --justify "N:clean.py:deadbeef=a reason that is long enough to count"
check "$rc|$(j 'd["stale"], d["rejected"], d["justified"]')" "0|(['N:clean.py:deadbeef'], [], [])" "JSON lists a stale id under 'stale', not 'rejected'"
audit --files app.py --justify "no-separator-here"; errors_cleanly "expected ID=REASON" "a --justify without ID=REASON is rc 2"

# ── density: authored vs whole file, the D finding, env thresholds, claims, JSON shape ──
repo dens && put w.py 'v0 = 0\nv1 = 1\nv2 = 2\nv3 = 3\nv4 = 4\nv5 = 5\nv6 = 6\nv7 = 7\n' && commit || { bad "$FIX: dens"; finish; }
put w.py 'v0 = 0\nv1 = 1\nv2 = 2\nv3 = 3\nv4 = 4\nv5 = 5\nv6 = 6\nv7 = 7\n# why: the order matters\n'
dfile=""; for k in 1 2 3 4 5 6 7; do dfile="$dfile# step $k keeps order\nv$k = $k\n"; done
for k in 1 2 3 4 5 6; do dfile="${dfile}w$k = $k\n"; done
put d.py "$dfile"; put c.py '# gives up within 5 s\ntimeout = 5\n'
audit --files w.py
check "$rc|$(awk '$1=="w.py" { print $2, $3, $4, $5, $6, $10 }' "$TMP/out")" "0|python 0 1 - 0.111 pass" "whole-file density 1/9 is reported next to the ungated authored density"
audit --files d.py
rc_is 1 "7 comment lines of 20 authored (0.350 > 0.30) exit 1"
line_is 'd.py:1 D D:d.py "7 of 20 authored lines are comments" -> delete comments that restate the code [0.350>0.30]' "the D finding states the fraction"
check "$(last 1 | sed 's/run=[^ ]* //')" "comment_pass: files=1 max_density=0.350 narrative=0 long=0 density_breaches=1 claims=0 justified=0 verdict=breach" "comment_pass carries max_density and density_breaches"
ZUVO_COMMENT_MAX_DENSITY=0.9 audit --files d.py
rc_is 0 "ZUVO_COMMENT_MAX_DENSITY=0.9 lets 0.350 pass"
check "$(last 2 | sed 's/.* justified=0//')|$(last 1 | sed 's/.* verdict=pass//')" " env=ZUVO_COMMENT_MAX_DENSITY| env=ZUVO_COMMENT_MAX_DENSITY" "both machine lines end with env=ZUVO_COMMENT_MAX_DENSITY"
check "$(last 3)" "thresholds: density=0.90(env) min_lines=20(default) block=4(default) justify_max=2(default)" "the thresholds line marks the env source"
audit --files c.py
check "$rc|$(grep -c '^CHECK c.py:1 "gives up within 5 s"$' "$TMP/out")" "0|1" "a quantitative claim is a CHECK line and never changes the exit code"
check "$(last 1 | sed 's/run=[^ ]* //')" "comment_pass: files=1 max_density=- narrative=0 long=0 density_breaches=0 claims=1 justified=0 verdict=pass" "comment_pass counts the claim"
audit --json --files d.py c.py
check "$rc|$(j 'sorted(d)')" "1|['base', 'files', 'justified', 'range', 'rc', 'rejected', 'retro_line', 'run', 'stale', 'thresholds', 'verdict']" "--json keeps rc and prints one object with the R8 keys and 'stale'"
check "$rc|$(j 'sorted(F("d.py")), sorted(F("d.py")["findings"][0]), sorted(F("c.py")["claims"][0])')" "1|(['authored_code', 'authored_comment', 'carried', 'claims', 'degraded', 'density', 'file_density', 'findings', 'lang', 'path', 'verdict'], ['hint', 'id', 'line', 'rule', 'sub', 'text'], ['line', 'text'])" "file, finding and claim objects have the R8 keys"
check "$rc|$(j 'sorted((k, sorted(v), v["source"]) for k, v in d["thresholds"].items())')" "1|[('block', ['source', 'value'], 'default'), ('density', ['source', 'value'], 'default'), ('justify_max', ['source', 'value'], 'default'), ('min_lines', ['source', 'value'], 'default')]" "thresholds carry value and source"
check "$rc|$(j 'd["rc"], d["verdict"], d["base"], d["range"], F("d.py")["density"], F("c.py")["claims"][0]["line"]')" "1|(1, 'breach', 'HEAD', None, 0.35, 1)" "rc, verdict, base, range, density and the claim line in JSON"
check "$rc|$(j 'd["retro_line"].startswith("comment_pass: run=" + d["run"] + " files=2 ")')|$(grep -c '^RESULT:' "$TMP/out")" "1|True|0" "retro_line is this run's comment_pass line; --json prints no RESULT line"
audit --json --files w.py
check "$rc|$(j 'round(F("w.py")["file_density"], 3), F("w.py")["density"]')" "0|(0.111, None)" "JSON carries file_density and an ungated density as null"

# ── carried lines: the removed pool is the WHOLE diff, untracked files and renames included ──
BLOCK='# The cache was previously global; we changed it\n# to a per-request map because worker threads\n# shared one dict and raced on writes. Keep the\n# map local to the request.\nCACHE = {}\n'
H=$(sha8 "$(printf 'The cache was previously global; we changed it\nto a per-request map because worker threads\nshared one dict and raced on writes. Keep the\nmap local to the request.')")
repo move && put a.py "import sys\n\n$BLOCK" && commit || { bad "$FIX: move"; finish; }
put b.py "import sys\n\n$BLOCK"
audit --files b.py
rc_is 1 "premise: the copied block is authored while a.py still has it"
line_is "b.py:3 N N:b.py:$H \"The cache was previously global; we changed it\" -> $HINT_N [N-history]" "premise: the block is narrative"
line_is "b.py:3 L L:b.py:$H \"The cache was previously global; we changed it\" -> $HINT_L [4>1]" "premise: 4 comment lines over 1 line of code"
put a.py 'import sys\n'
audit --files b.py; rc_is 0 "moved a.py -> untracked b.py with --files b.py: carried, rc 0"
put c.py "import sys\n\n$BLOCK"
audit --files c.py; rc_is 1 "a second copy is authored: one removed line carries one added line, whatever --files lists"
audit --files b.py; rc_is 0 "the first copy in path order stays carried when a second copy exists"
rm -f "$R/c.py"; git -C "$R" add b.py
audit --files b.py; rc_is 0 "moved a.py -> staged b.py with --files b.py: carried, rc 0"
repo tmove && put a.py "import sys\n\n$BLOCK" && put t.py 't0 = 0\nt1 = 1\n' && commit || { bad "$FIX: tmove"; finish; }
put t.py "t0 = 0\n${BLOCK}t1 = 1\n"
audit --files t.py; rc_is 1 "premise: a block inserted into a file tracked at HEAD is authored while a.py keeps it"
put a.py 'import sys\n'
audit --files t.py; rc_is 0 "a block moved into the middle of a tracked file is carried at its hunk offset"
repo ren && put a.py "import sys\n\n$BLOCK" && commit && git -C "$R" mv a.py b.py && printf 'extra = 1\n' >> "$R/b.py" || { bad "$FIX: ren"; finish; }
audit --json --files a.py b.py
check "$rc|$(j '[(f["path"], f["verdict"], f["carried"], f["authored_code"]) for f in d["files"]]')" "0|[('a.py', 'deleted', None, None), ('b.py', 'pass', 6, 1)]" "git mv + edit: renames off, a.py deleted, b.py carries 6 lines"

# ── --base HEAD: staged, unstaged and untracked are all audited ──────────────
repo states && put s.py 'x = 1\n' && put u.py 'y = 2\n' && commit || { bad "$FIX: states"; finish; }
put s.py 'x = 1\n# previously s\n' && git -C "$R" add s.py
put u.py 'y = 2\n# previously u\n'; put n.py '# previously n\nz = 3\n'
HS="N:s.py:$(sha8 'previously s')"; HU="N:u.py:$(sha8 'previously u')"; HN="N:n.py:$(sha8 'previously n')"
audit
rc_is 1 "without --files the whole working tree is audited"
has "s.py:2 N $HS \"" "a staged-only change is audited"
has "u.py:2 N $HU \"" "an unstaged-only change is audited"
has "n.py:1 N $HN \"" "an untracked file is audited as fully added"
check "$(last 2 | sed 's/run=[^ ]* //')" "RESULT: comment-pass BREACH files=3 findings=3 justified=0" "three files, three findings"
REASON="the line names a constraint this module keeps"
audit --justify "$HN=$REASON" --justify "$HS=$REASON" --justify "$HU=$REASON"
check "$rc|$(last 2 | sed 's/run=[^ ]* //')|$(grep -c "^REJECTED $HU (over-cap)" "$TMP/out")" "1|RESULT: comment-pass BREACH files=3 findings=3 justified=2|1" "cap 2: the first two justifications in argument order count, the third is rejected, rc 1"
repo unborn && put staged.py '# previously a\nq = 1\n' && git -C "$R" add staged.py && put loose.py 'w = 2\n' || { bad "$FIX: unborn"; finish; }
LIMIT=10 audit --json --files staged.py loose.py < <(sleep 30 2>/dev/null)
check "$rc|$(vj)|$(j 'F("staged.py")["findings"][0]["id"]')" "1|breach|pass|N:staged.py:$(sha8 'previously a')" "unborn HEAD: audited against the empty tree within 10 s while the CLI's stdin stays open"
repo brokenhead && put x.py 'x = 1\n' && commit && printf '1111111111111111111111111111111111111111\n' > "$R/.git/HEAD" || { bad "$FIX: brokenhead"; finish; }
audit --files x.py; errors_cleanly "unknown revision 'HEAD'" "a detached HEAD naming a missing commit is rc 2, not an empty-tree audit"

# ── --range A..B reads B:, never the working tree; any --base commit works ───
repo range && put f.py 'v = 1\n' && put g.py 'k = 0\n' && commit A && A=$(git -C "$R" rev-parse HEAD) || { bad "$FIX: range"; finish; }
put f.py 'v = 1\n# previously v was 2\n' && rm -f "$R/g.py" && commit B && B=$(git -C "$R" rev-parse HEAD) || { bad "$FIX: range B"; finish; }
put f.py 'v = 1\n'
audit --json --range "$A..$B" --files f.py g.py
check "$rc|$(j '[f["verdict"] for f in d["files"]], F("f.py")["findings"][0]["id"], d["base"], d["range"]')" "1|(['breach', 'deleted'], 'N:f.py:$(sha8 'previously v was 2')', None, '$A..$B')" "--range reads B: after the working tree dropped the comment; g.py deleted"
audit --files f.py; rc_is 0 "--base HEAD sees only the removal in the working tree"
put f.py 'v = 1\n# previously v was 2\n'
audit --base "$A" --files f.py; rc_is 1 "--base <older sha> audits everything since that commit"
audit --json --files f.py; check "$rc|$(vj)" "0|unchanged" "the same file against HEAD is unchanged"
putb big.py 'b"x = 1\n" * 349525 + b"#\n\n"' && ln -s f.py "$R/ln.py" && commit C && C=$(git -C "$R" rev-parse HEAD) || { bad "$FIX: range C"; finish; }
check "$(git -C "$R" cat-file -s "$C:big.py")" "2097153" "premise: the committed big.py is 2 MB + 1 byte"
audit --json --range "$B..$C" --files big.py ln.py
check "$rc|$(vj)" "0|n/a (too large)|n/a (symlink)" "--range: a blob over 2 MB is n/a (too large), a symlink blob n/a (symlink)"
SHIM=short PATH="$TMP/shim:$PATH" audit --range "$A..$B" --files f.py; errors_cleanly "git cat-file returned 3 of 101 bytes for f.py" "a short cat-file reply is rc 2, never a cut post-image"
SHIM=count PATH="$TMP/shim:$PATH" audit --range "$B..$C" --files f.py; errors_cleanly "2 replies for 1 paths" "a batch-check reply count that differs from the request is rc 2"
audit --range "$B..$C" --files $'v\rt.py'; errors_cleanly 'v\x0dt.py in '"${C:0:7}"': missing' "a missing path holding a carriage return is one reply, not two"
for spec in "$A:expected A..B" "$A...$B:expected A..B" "..$B:expected A..B" "$A..:expected A..B" "nope..$B:unknown revision 'nope'"; do
  audit --range "${spec%%:*}" --files f.py; errors_cleanly "${spec#*:}" "--range '${spec%%:*}' is rc 2 naming the cause"
done
audit --base '' --files f.py; errors_cleanly "unknown revision ''" "--base '' is rc 2"
audit --base=-x --files f.py; errors_cleanly "unknown revision '-x'" "--base=-x is rc 2, never a git option"
audit --range "$A..$B" --files ghost.py; errors_cleanly "ghost.py in ${B:0:7}: missing" "a path missing from B is rc 2"
audit --range "$A..$B" --files 'x blob'; errors_cleanly "x blob in ${B:0:7}: missing" "a missing path that looks like 'x blob' is rc 2"
EMPTY=$(git -C "$R" hash-object -t tree /dev/null)
audit --json --range "$EMPTY..$B" --files f.py
check "$rc|$(j 'F("f.py")["verdict"], F("f.py")["authored_code"], F("f.py")["authored_comment"], d["range"]')|$(tail -1 "$ZUVO_COMMENT_AUDIT_LOG" | cut -f5)" "1|('breach', 1, 1, '$EMPTY..$B')|${EMPTY:0:7}" "--range <empty tree>..B audits every line of B as added; the ledger's base7 is the tree id"
audit --json --base "$EMPTY" --files f.py
check "$rc|$(j 'F("f.py")["verdict"], F("f.py")["authored_code"], F("f.py")["authored_comment"], d["base"]')" "1|('breach', 1, 1, '$EMPTY')" "--base <empty tree> audits the whole working-tree file as added"
audit --range "$B..$EMPTY" --files f.py; errors_cleanly "'$EMPTY' is a tree; the B of --range A..B must be a commit" "a tree as the B of --range is rc 2 naming why"
repo nlrange && python3 -c 'import sys; open(sys.argv[1] + "/n\nl.py", "w").write("a = 1\n")' "$R" && commit A && A=$(git -C "$R" rev-parse HEAD) \
  && python3 -c 'import sys; open(sys.argv[1] + "/n\nl.py", "a").write("b = 2\n")' "$R" && commit B && B=$(git -C "$R" rev-parse HEAD) || { bad "$FIX: nlrange"; finish; }
audit --range "$A..$B"; errors_cleanly "cannot be read from" "a changed path holding a newline in --range is rc 2"

# ── paths: cwd-relative, absolute, unchanged, deleted, ignored, fifo, empty, invalid ──
repo sub && put pkg/m.py 'k = 1\n' && commit && put pkg/m.py 'k = 1\n# previously k\n' || { bad "$FIX: sub"; finish; }
CWD="$R/pkg" audit --files m.py
has "pkg/m.py:2 N N:pkg/m.py:$(sha8 'previously k') \"" "--files is relative to the current directory, ids to the repo root"
CWD="$R/pkg" audit --files "$R/pkg/m.py"; has "pkg/m.py:2 N N:pkg/m.py:" "an absolute --files path inside the repo is accepted"
CWD="$R/pkg" audit --files ../../outside.py; errors_cleanly "outside the repository" "a path outside the repository is rc 2"
CWD="$R/pkg" audit --files .; errors_cleanly "is a directory" "a directory in --files is rc 2"
audit --files ghost.py; errors_cleanly "no such file" "a missing untracked path is rc 2"
repo ud && put keep.py 'a = 1\n' && put gone.py 'b = 2\n' && put .gitignore 'ign.py\n' && commit || { bad "$FIX: ud"; finish; }
rm -f "$R/gone.py"; put ign.py '# previously ignored\n'; : > "$R/zero.py"; put br.py '# previously b\n'; put jf.py '# previously j\n'; mkfifo "$R/fifo.py" || { bad "$FIX: fifo"; finish; }
audit --json --files keep.py gone.py ign.py fifo.py zero.py br.py jf.py --justify "N:jf.py:$(sha8 'previously j')=$REASON"
check "$rc|$(vj)|$(j 'all(re.fullmatch(r"pass|breach|justified|unchanged|deleted|n/a( [(].+[)])?", f["verdict"]) for f in d["files"])')" "1|unchanged|deleted|n/a (ignored)|n/a (not a regular file)|pass|breach|justified|True" "every verdict kind in one run, each one of pass|breach|justified|unchanged|deleted|n/a[ (reason)]"
audit --json --files keep.py gone.py ign.py; check "$rc|$(j 'd["verdict"]')" "0|n/a" "nothing evaluated reads n/a"
repo empty && put e.py 'e = 1\n' && commit && mkdir -p "$R/nest" && git -C "$R/nest" init -q && put nest/n.py '# previously n\n' || { bad "$FIX: empty"; finish; }
audit; check "$rc|$(last 2 | sed 's/run=[^ ]* //')" "0|RESULT: comment-pass N/A files=0 findings=0 justified=0" "a clean tree with a nested repo in an untracked dir is N/A, rc 0"

# ── errors are rc 2 with one stderr line naming the cause, never rc 1 ────────
repo errs && put e.py 'e = 1\n' && commit && put e.py 'e = 1\n# previously e\n' && put vanish.py 'v = 1\n' || { bad "$FIX: errs"; finish; }
git -C "$R" add vanish.py && put vanish.py 'v = 1\n# previously v\n'
CWD="$TMP/norepo" audit --files x.py; errors_cleanly "not a git repository" "outside a repository: rc 2 with git's own reason"
audit --base nosuchref --files e.py; errors_cleanly "unknown revision 'nosuchref'" "an unknown --base ref is rc 2"
audit --base HEAD --range HEAD..HEAD; errors_cleanly "not allowed with argument" "--base with --range is rc 2"
ZUVO_COMMENT_MAX_DENSITY=abc audit --files e.py; errors_cleanly "ZUVO_COMMENT_MAX_DENSITY" "an invalid ZUVO_COMMENT_MAX_DENSITY is rc 2"
ZUVO_COMMENT_MIN_LINES=0 audit --files e.py; errors_cleanly "ZUVO_COMMENT_MIN_LINES" "ZUVO_COMMENT_MIN_LINES=0 is rc 2"
audit --bogus; errors_cleanly "unrecognized arguments" "an unknown option is rc 2"
( cd "$R" && perl -e 'alarm shift; close STDERR; exec @ARGV' "$LIMIT" "$CLI" --bogus ) > "$TMP/out"; rc=$?
rc_is 2 "an error with stderr closed (perl closes it right before exec; a shell 2>&- is reopened by perl) still exits 2"
check "$(CWD="$TMP/norepo" closed err --files x.py)" "2 0 False" "an error with stderr on a dead pipe still exits 2 and writes nothing to stdout"
ln -s "$(command -v python3)" "$TMP/nogit/python3" && ln -s "$(command -v perl)" "$TMP/nogit/perl" || { bad "$FIX: nogit"; finish; }
PATH="$TMP/nogit" audit --files e.py; errors_cleanly "cannot run git" "git missing from PATH is rc 2"
SHIM=junk PATH="$TMP/shim:$PATH" audit --files e.py; errors_cleanly "unexpected header" "a diff git cannot have written is rc 2"
SHIM=vanish PATH="$TMP/shim:$PATH" audit --json --files vanish.py; check "$rc|$(vj)" "0|deleted" "a file gone between the diff and the read is 'deleted'"
put vanish.py 'v = 2\n'; SHIM=todir PATH="$TMP/shim:$PATH" audit --json --files vanish.py; check "$rc|$(vj)" "0|n/a (not a regular file)" "a directory swapped in before the read is n/a (not a regular file)"
put lk.py 'x = 1\n'; chmod 000 "$R/lk.py"; if [ "$(id -u)" -ne 0 ]; then audit --files lk.py; errors_cleanly "lk.py: Permission denied" "an unreadable file is rc 2 naming the path and the errno text"; fi; chmod 644 "$R/lk.py"
mkdir -p "$TMP/zh" "$TMP/zs" "$TMP/zt" "$TMP/zb" "$TMP/zn" || { bad "$FIX: copies"; finish; }
for dir in zh zs zt zb zn; do cp "$CLI" "$HELPERS"/zuvo_comment_*.py "$TMP/$dir/"; done
printf '\nNARRATIVE = NARRATIVE + (("N-probe", "probe"),)\n\n\ndef evaluate(view, thresholds):\n    raise RuntimeError("forced internal error")\n' >> "$TMP/zh/zuvo_comment_rules.py"
printf '\n\ndef evaluate(view, thresholds):\n    raise SystemExit(1)\n' >> "$TMP/zs/zuvo_comment_rules.py"
BIN="$TMP/zh/comment-audit" audit --files e.py; errors_cleanly "internal error: RuntimeError: forced internal error" "an internal exception is rc 2, never rc 1"
BIN="$TMP/zs/comment-audit" audit --files e.py; errors_cleanly "internal error: unexpected exit 1" "a SystemExit(1) inside the audit is rc 2, never rc 1"
sed 's/^GIT_TIMEOUT = 600$/GIT_TIMEOUT = 1/' "$CLI" > "$TMP/zt/comment-audit" && chmod +x "$TMP/zt/comment-audit"
sed 's/("O_NOFOLLOW", /(/; s/hasattr(os, "O_NOFOLLOW")/False/' "$CLI" > "$TMP/zn/comment-audit" && chmod +x "$TMP/zn/comment-audit"
check "$(grep -c '^GIT_TIMEOUT = 1$' "$TMP/zt/comment-audit")" "1" "premise: the timeout copy waits 1 s"
SHIM=hang-diff PATH="$TMP/shim:$PATH" BIN="$TMP/zt/comment-audit" audit --files e.py; errors_cleanly "git diff timed out after 1 s" "a streaming git child that hangs is killed: rc 2"
SHIM=hang-rev PATH="$TMP/shim:$PATH" BIN="$TMP/zt/comment-audit" audit --files e.py; errors_cleanly "git rev-parse timed out after 1 s" "a git call that hangs is killed: rc 2"
sed 's/^UNTRACKED_BUDGET = 64 \* 1024 \* 1024$/UNTRACKED_BUDGET = 30/' "$CLI" > "$TMP/zb/comment-audit" && chmod +x "$TMP/zb/comment-audit"
repo budget && put k.py 'a = 1\nb = 2\n' && commit && put a.py 'aaaa = 1\nbbbb = 2\n' && put u.py '# previously u\nc = 3\n' \
  && put w.py '# previously w\nw = 1234567890123456789\n' && put z.py '# z\nz = 1234567890123456789012345678\n' || { bad "$FIX: budget"; finish; }
BIN="$TMP/zb/comment-audit" audit --files u.py w.py
check "$rc|$(row u.py) $(row w.py)|$(grep -c '^NOTE' "$TMP/out")" "1|breach breach|0" "with nothing removed no untracked file is read for the pool, and no NOTE is printed"
put k.py 'a = 1\n'
BIN="$TMP/zb/comment-audit" audit --files u.py w.py
check "$rc|$(row u.py) $(row w.py)|$(last 4)" "1|breach breach|NOTE carried pool truncated: 1 untracked files not read (budget)" "a 30-byte budget: listed u.py (21) and w.py (39) are audited; unlisted a.py (18) fits, z.py (37) is a NOTE"
audit --help; missing=""; for name in ZUVO_COMMENT_MAX_DENSITY ZUVO_COMMENT_MIN_LINES ZUVO_COMMENT_BLOCK_MIN ZUVO_COMMENT_JUSTIFY_MAX \
  ZUVO_COMMENT_AUDIT_LOG N-date N-history N-incident N-measured N-pl; do grep -qF -- "$name" "$TMP/out" || missing="$missing $name"; done
check "$rc|$missing" "0|" "--help exits 0 and lists the env table and every N family"
BIN="$TMP/zh/comment-audit" audit --help; check "$rc|$(grep -c 'N-probe' "$TMP/out")" "0|1" "--help renders the families from the rules module's constants"

# ── diff parsing: single-line hunks, no trailing newline, invalid UTF-8, hidden characters ──
repo hunks && put one.py 'a = 1\nb = 2\nc = 3\n' && put noeol.py 'a = 1\nb = 2' && put src.py 's = 1\n# previously moved' && commit || { bad "$FIX: hunks"; finish; }
put one.py 'a = 1\n# previously one\nb = 2\nc = 3\n'; put noeol.py 'a = 1\nb = 2  # previously two'
putb bad.py 'b"s = \"\xff\xfe\"\n# previously bytes\n"'; putb bidi.py 'b"# previously \xe2\x80\xaex\n"'
put src.py 's = 1\n'; put dst.py 'd = 1\n# previously moved'; put $'x\xff.py' '# previously x\n'
audit --files one.py noeol.py bad.py bidi.py dst.py $'x\xff.py'
rc_is 1 "single-line hunk, missing final newline and invalid UTF-8 are audited"
has "one.py:2 N N:one.py:$(sha8 'previously one') \"" "a '+c @@' hunk without a count is one added line"
line_is "noeol.py:2 N N:noeol.py:$(sha8 'previously two') \"previously two\" -> $HINT_N [N-history]" "a last line without a newline keeps its final character"
has "bad.py:2 N N:bad.py:$(sha8 'previously bytes') \"" "invalid UTF-8 is decoded with replacement, not a crash"
has '"previously \u202ex"' "a bidi override in comment text is printed escaped"
has 'x\xff.py:1 N N:x\xff.py:' "a non-UTF-8 byte in a path prints as its \\xNN byte"
check "$(row dst.py)" "pass" "a removed last line without a newline carries its copy"

# ── user git config and environment cannot change the parse ──────────────────
NAMES=("a b.py" "zażółć.py" $'t\tab.py' 'q"x.py' 'b\s.py' $'c\x01.py' $'n\nl.py')
repo cfg && python3 -c 'import os, sys
for name in sys.argv[2:]: open(os.path.join(sys.argv[1], name), "w").write("p = 1\n")' "$R" "${NAMES[@]}" \
  && put two.py 'l0 = 0\nl1 = 1\nl2 = 2\nl3 = 3\nl4 = 4\nl5 = 5\nl6 = 6\n' && commit || { bad "$FIX: cfg"; finish; }
python3 -c 'import os, sys
for name in sys.argv[2:]: open(os.path.join(sys.argv[1], name), "w").write("p = 1\n# previously p\n")' "$R" "${NAMES[@]}"
put two.py 'l0 = 0\n# previously a\nl1 = 1\nl2 = 2\nl3 = 3\n# previously b\nl4 = 4\nl5 = 5\nl6 = 6\n'
git -C "$R" config core.quotePath false
audit --json; cp "$TMP/out" "$TMP/plain.json"
check "$rc|$(j 'len(d["files"]), sorted(set(f["verdict"] for f in d["files"])), len(F("zażółć.py")["findings"]), len(F("two.py")["findings"])')" "1|(8, ['breach'], 1, 2)" "names with a space, quote, backslash, tab, control char, newline and non-ASCII are audited"
for kv in core.quotePath=true diff.noprefix=true diff.mnemonicPrefix=true color.ui=always diff.external=false \
          diff.renames=copies diff.algorithm=patience diff.submodule=log diff.interHunkContext=5; do
  git -C "$R" config "${kv%%=*}" "${kv#*=}"
done
GIT_DIFF_OPTS=-u3 audit --json
check "$rc|$(python3 -c 'import json, sys
a, b = (json.load(open(p, encoding="utf-8")) for p in sys.argv[1:3])
print(a["files"] == b["files"] and sorted(f["path"] for f in a["files"]) == sorted(sys.argv[3:] + ["two.py"]))' "$TMP/plain.json" "$TMP/out" "${NAMES[@]}")" "1|True" "quotePath, noprefix, mnemonicPrefix, colour, external diff, interHunkContext and GIT_DIFF_OPTS change nothing"
audit
check "$rc|$(last 2 | cut -c1-27)|$(grep -cF 'n\x0al.py' "$TMP/out")" "1|RESULT: comment-pass BREACH|2" "a path with a newline is printed escaped and the machine lines stay last"

# ── n/a: unsupported, binary, too large, symlink; degraded scan ──────────────
repo misc && putb data.bin 'b"a\x00b\n"' && putb gone.bin 'b"\x00x"' && put README.md 'hello\n' && put attr.py 'a = 1\n' \
  && put .gitattributes 'attr.py binary\n' && commit || { bad "$FIX: misc"; finish; }
rm -f "$R/gone.bin"; putb data.bin 'b"a\x00c\n"'; put README.md 'hello\nThe cache was previously global.\n'; put attr.py 'a = 1\n# previously attr\n'
putb edge.py 'b"# previously edge\n" + b"x = 1\n" * 349522 + b"#\n"'; putb big.py 'b"# previously edge\n" + b"x = 1\n" * 349522 + b"#\n\n"'
ln -s app.py "$R/link.py"; put deg.py 'x = """open\n'; putb blob.py 'b"x = 1\x00\n# previously\n"'
audit --json --files README.md data.bin big.py link.py blob.py attr.py gone.bin
check "$rc|$(vj)" "0|n/a|n/a (binary)|n/a (too large)|n/a (symlink)|n/a (binary)|n/a (binary)|deleted" "unsupported, binary diff, over 2 MB, symlink, NUL bytes, .gitattributes binary: n/a; a deleted binary: deleted"
check "$(wc -c < "$R/edge.py" | tr -d ' ')" "2097152" "premise: edge.py is exactly 2 MB"
audit --files edge.py; has "edge.py:1 N N:edge.py:$(sha8 'previously edge') \"" "a file of exactly 2 MB is still audited"
BIN="$TMP/zn/comment-audit" audit --json --files link.py; check "$rc|$(vj)|$(grep -c O_NOFOLLOW "$TMP/zn/comment-audit")" "0|n/a (symlink)|0" "without O_NOFOLLOW an lstat check still never follows a symlink"
audit --files deg.py; has "DEGRADED deg.py" "a degraded scan is named in the table output"
audit --json --files deg.py; check "$rc|$(j 'F("deg.py")["degraded"], F("deg.py")["verdict"]')" "0|(True, 'pass')" "JSON marks the degraded file"

# ── a closed pipe never changes the exit code ────────────────────────────────
repo pipe && put tiny.py 't = 1\n' && python3 -c 'import sys; sys.stdout.write("".join("# previously %d\nv%d = %d\n" % (k, k, k) for k in range(1500)))' > "$R/many.py"
check "$(closed out --files many.py)" "1 0 False" "a 220 KB report into a closed pipe: the audit's rc, nothing on stderr"
check "$(closed out --files tiny.py)" "0 0 False" "a short report into a closed pipe: the final flush fails quietly, rc 0"
check "$(closed out --help)" "0 0 False" "--help into a closed pipe: rc 0, nothing on stderr"

# ── --trend over a ledger of its own ─────────────────────────────────────────
repo trend && put t.py 't = 1\n' && put u.py 'u = 1\n' && commit && put t.py 't = 1\n# previously t\n' || { bad "$FIX: trend"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$TMP/trend.log" audit --files t.py u.py; ZUVO_COMMENT_AUDIT_LOG="$TMP/trend.log" audit --trend --project trend
check "$rc|$(awk '$1 == "trend" { print $2, $3, $10 }' "$TMP/out")|$(head -1 "$TMP/out" | cut -d' ' -f3-5)" "0|1 1 1|project=trend rows=2 skipped=0" "--trend on its own ledger: one run, the unchanged file is not a file, one N"

finish
