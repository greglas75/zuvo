#!/usr/bin/env bash
# Contract for the comment-audit ledger and --trend: one row per audited file per run is the proof a gate
# cites, so a lost row, a wrong run id or an unwritable ledger that still exits 0 breaks that proof.
# Level: medium (Q20) — the CLI runs against hermetic git repositories under mktemp; no network, no sleep.
# Every case builds its own repository, ledger and files first, so any case runs alone. Lock order is a fifo
# handshake: an audit hook reports the CLI's second flock attempt. Time is never the wall clock: --trend reads a
# frozen now and the lock deadline a fake clock, both in-process.
#
# bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || { echo "FAIL: cannot resolve the repo root"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
HELPERS="$ROOT/scripts/zuvo-home"
CLI="$HELPERS/comment-audit"
DECLARED=109
FLOOR=20
fail=0
npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }
finish() {
  local ran=$((npass + nfail))
  if [ "$DECLARED" -ge "$FLOOR" ] && [ "$ran" -eq "$((DECLARED - 1))" ]; then pass "every declared check ran ($DECLARED)"
  else bad "ran $ran checks before this one, declared $DECLARED in all (floor $FLOOR)"; fi
  printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"; exit "$fail"
}
check() { if [ "$1" = "$2" ]; then pass "$3"; else bad "$3 — got [$1], want [$2]"; fi; }
skip() { [ "$fail" -eq 0 ] || finish; echo "SKIP: $1"; exit 0; }

if [ -f "$CLI" ] && [ -x "$CLI" ]; then pass "comment-audit exists and is executable"
else bad "scripts/zuvo-home/comment-audit is missing or not executable"; finish; fi
if [ -f "$HELPERS/zuvo_comment_ledger.py" ] && [ ! -x "$HELPERS/zuvo_comment_ledger.py" ]; then
  pass "zuvo_comment_ledger.py is a plain module next to the CLI"
else bad "zuvo_comment_ledger.py is missing or executable in $HELPERS"; fi

for tool in python3 git perl; do command -v "$tool" >/dev/null 2>&1 || skip "$tool not available"; done
export PYTHONDONTWRITEBYTECODE=1 PYTHONIOENCODING=utf-8 PYTHONUTF8=1 PYTHONUNBUFFERED=1 LC_ALL=C LANG=C

TMP="$(mktemp -d)" && TMP="$(cd "$TMP" && pwd -P)" || { echo "FAIL: mktemp -d failed"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" ZUVO_COMMENT_AUDIT_LOG="$TMP/ledgers/unset.log" GIT_CEILING_DIRECTORIES="$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_EXTERNAL_DIFF GIT_DIFF_OPTS ZUVO_HOME PYTHONPATH
unset ZUVO_COMMENT_MAX_DENSITY ZUVO_COMMENT_MIN_LINES ZUVO_COMMENT_BLOCK_MIN ZUVO_COMMENT_JUSTIFY_MAX
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$TMP/shim" "$TMP/ledgers" "$TMP/spy" || { bad "cannot create the sandbox"; finish; }
LIMIT=120
run=""
NL='
'

repo()   { R="$TMP/$1"; export ZUVO_COMMENT_AUDIT_LOG="$TMP/ledgers/$1.log"; mkdir -p "$R" && git -C "$R" -c init.defaultBranch=main init -q "${@:2}"; }
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
closed() {
  ( cd "${CWD:-$R}" && env -u PYTHONUNBUFFERED python3 -c 'import os, subprocess, sys
r, w = os.pipe(); os.close(r)
p = subprocess.run(sys.argv[1:], stdout=w, stderr=subprocess.PIPE, timeout=120)
print(p.returncode, len(p.stderr), b"Traceback" in p.stderr or b"Exception ignored" in p.stderr)' "${BIN:-$CLI}" "$@" )
}
unit()   { PYTHONPATH="$HELPERS" python3 -c "$1" "${@:2}" 2>&1; }
sha8()   { printf '%s' "$1" | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:8])'; }
ho()     { git -C "$R" hash-object -- "$1"; }
last()   { tail -n "$1" "$TMP/out" | head -1; }
runid()  {  # sets $run from the output's RESULT line; anything but exactly one run id is a FAIL
  local ids; ids=$(sed -n 's/^RESULT: comment-pass [A-Z/]* run=\([^ ]*\) .*/\1/p' "${1:-$TMP/out}")
  case "$ids" in ""|*"$NL"*) bad "expected one run id in ${1:-$TMP/out}, got [$ids]"; run="none" ;; *) run=$ids ;; esac
}
j()      { python3 -c 'import json, sys; d = json.load(open(sys.argv[1], encoding="utf-8")); print(eval(sys.argv[2]))' "$TMP/out" "$1" 2>&1; }
stamp()  { printf '%s-%s-%sT%s:%s:%sZ' "${1:0:4}" "${1:4:2}" "${1:6:2}" "${1:9:2}" "${1:11:2}" "${1:13:2}"; }
inproc() {  # inproc MODE ARGS: the CLI's main() in one python process; rc, $TMP/out, $TMP/err and $TMP/report.json
  ( cd "${CWD:-$R}" && INPROC="$1" bounded python3 "$TMP/inproc.py" "$TMP" "$CLI" "${@:2}" ) > "$TMP/report.json" 2> "$TMP/inproc.err"
  rc=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["rc"])' "$TMP/report.json" 2>/dev/null) \
    || rc="driver failed: $(head -c 300 "$TMP/inproc.err")"
}
report() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$TMP/report.json" "$1" 2>&1; }
# INPROC=clock freezes datetime.now at INPROC_NOW; INPROC=lockclock gives the ledger a clock that jumps LOCK_WAIT
# per poll sleep and records each flock operation.
cat > "$TMP/inproc.py" <<'PY'
import contextlib
import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import types

loader = importlib.machinery.SourceFileLoader("comment_audit", sys.argv[2])
cli = importlib.util.module_from_spec(importlib.util.spec_from_loader("comment_audit", loader))
sys.modules["comment_audit"] = cli
loader.exec_module(cli)
mode, sleeps, flocks, now_calls = os.environ.get("INPROC", ""), [], [], []

if mode == "clock":
    fixed = dt.datetime.fromisoformat(os.environ["INPROC_NOW"])

    class Frozen(dt.datetime):
        @classmethod
        def now(cls, tz=None):
            now_calls.append(tz)
            return fixed.astimezone(tz)
    cli.dt = types.SimpleNamespace(datetime=Frozen, timezone=dt.timezone)
if mode == "lockclock":
    ledger = cli.ledger
    real_flock = ledger.fcntl.flock

    class Clock:
        moment = 100.0

        def monotonic(self):
            return self.moment

        def sleep(self, seconds):
            sleeps.append(seconds)
            self.moment += ledger.LOCK_WAIT

    def flock(fd, operation):
        flocks.append(operation)
        return real_flock(fd, operation)
    ledger.time = Clock()
    ledger.fcntl = types.SimpleNamespace(flock=flock, LOCK_EX=ledger.fcntl.LOCK_EX, LOCK_NB=ledger.fcntl.LOCK_NB)
out, err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
    code = cli.main(sys.argv[3:])
for name, text in (("out", out.getvalue()), ("err", err.getvalue())):
    with open(os.path.join(sys.argv[1], name), "w", encoding="utf-8", errors="backslashreplace") as handle:
        handle.write(text)
print(json.dumps({"rc": code, "sleeps": sleeps, "flocks": flocks, "now_calls": len(now_calls)}))
PY
strerr() { python3 -c 'import errno, os, sys; print(os.strerror(getattr(errno, sys.argv[1])))' "$1"; }
# A fifo read or write blocks until the other side opens it; bounded turns a peer that never comes into a FAIL.
handshake() { bounded sh -c 'IFS= read -r line < "$1"' sh "$1"; }
# hold LEDGER TAG TEXT: a background process takes the ledger's flock and says so on the fifo TAG.ready, then
# waits on TAG.release; released, it writes TEXT, creates TAG.done and exits, which drops the lock.
hold()   {
  mkfifo "$TMP/$2.ready" "$TMP/$2.release" || { bad "$FIX: fifos for $2"; finish; }
  bounded python3 -c 'import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND | os.O_CREAT)
fcntl.flock(fd, fcntl.LOCK_EX)
with open(sys.argv[2] + ".ready", "w") as ready:
    ready.write("locked\n")
with open(sys.argv[2] + ".release") as release:
    release.readline()
os.write(fd, sys.argv[3].encode())
open(sys.argv[2] + ".done", "w").close()' "$1" "$TMP/$2" "$3" & holder=$!
  handshake "$TMP/$2.ready" || bad "the lock holder $2 never reported the lock taken"
}
release() { bounded sh -c 'printf "go\n" > "$1"' sh "$TMP/$1.release"; wait "$holder"; }
# spied LEDGER TAG ARGS: the CLI in the background with an audit hook that logs each flock operation to
# TAG.ops and, on its second attempt (the first came back busy), writes to the fifo TAG.waiting.
spied()  {
  local ledger="$1" tag="$2"; shift 2
  mkfifo "$TMP/$tag.waiting" || { bad "$FIX: fifo for $tag"; finish; }
  ( cd "$R" && ZUVO_COMMENT_AUDIT_LOG="$ledger" PYTHONPATH="$TMP/spy" FLOCK_SPY_LOG="$TMP/$tag.ops" \
      FLOCK_SPY_WAITING="$TMP/$tag.waiting" bounded "${BIN:-$CLI}" "$@" ) > "$TMP/out" 2> "$TMP/err" & auditor=$!
}
LOCK_NB_EX=$(python3 -c 'import fcntl; print(fcntl.LOCK_EX | fcntl.LOCK_NB)' 2>&1)
cat > "$TMP/spy/sitecustomize.py" <<'PY'
import os
import sys

_LOG, _WAITING, _SEEN = os.environ.get("FLOCK_SPY_LOG"), os.environ.get("FLOCK_SPY_WAITING"), []


def _spy(event, args):
    if event != "fcntl.flock" or not _LOG:
        return
    _SEEN.append(args[1])
    with open(_LOG, "a") as log:
        log.write("%d\n" % args[1])
    if len(_SEEN) == 2 and _WAITING:
        with open(_WAITING, "w") as fifo:
            fifo.write("retrying\n")


sys.addaudithook(_spy)
PY
COLS="date run project head7 base7 file lang authored_code authored_comment carried density file_density narrative long claims density_breach justified verdict blob thresholds notes"
HEADER=$(printf '%s' "$COLS" | tr ' ' '\t')
SCHEMA="# comment-audit ledger schema=1"
DEFAULTS="density=0.30(default) min_lines=20(default) block=4(default) justify_max=2(default)"
# lq EXPR [ARG...]: L ledger lines, R dated rows as dicts (nf = field count), N rows of $run, F(path) this
# run's row, A the extra arguments; values reach python only through argv.
lq() { local expr="$1"; shift; python3 -c 'import re, sys
COLS, A = sys.argv[4].split(), sys.argv[5:]
try:
    L = open(sys.argv[2], "rb").read().decode("utf-8").split("\n")
except (OSError, ValueError) as exc:
    sys.exit(print("NO-LEDGER", type(exc).__name__))
try:
    D = lambda x: re.match(r"\d{4}-\d\d-\d\dT", x, re.ASCII) is not None
    R = [dict(zip(COLS, x.split("\t")), nf=len(x.split("\t"))) for x in L if D(x)]
    N = [r for r in R if r["run"] == sys.argv[3]]
    F = lambda p: next((r for r in N if r["file"] == p), {})
    print(eval(sys.argv[1]))
except Exception as exc:
    print("LQ-ERROR", type(exc).__name__)' "$expr" "${LEDGER:-$ZUVO_COMMENT_AUDIT_LOG}" "$run" "$COLS" "$@" 2>&1; }
cells() { lq '" ".join(F(A[0]).get(c, "?") for c in COLS[int(A[1]):int(A[2])])' "$1" "${2%:*}" "${2#*:}"; }
rows_of() { awk -v p="$1" '$1 == p { $1 = $1; print }' "$TMP/out"; }
errors_cleanly() {  # <stderr fragment> <label>: rc 2, one stderr line naming the cause, nothing on stdout
  local line ok=1; line=$(head -1 "$TMP/err")
  { [ "$rc" -eq 2 ] && [ "$(awk 'END { print NR }' "$TMP/err")" -eq 1 ] && [ ! -s "$TMP/out" ]; } || ok=0
  case "$line" in *"$1"*) ;; *) ok=0 ;; esac
  case "$line" in *"internal error"*) ok=0 ;; esac
  if [ "$ok" -eq 1 ]; then pass "$2"; else bad "$2 — rc $rc, stderr: $(head -c 300 "$TMP/err") stdout: $(head -c 200 "$TMP/out")"; fi
}
FIX="fixture setup failed"
n=0
# fx BUILDER: a fresh repository (and ledger) under a new name, built by BUILDER; every case starts with one.
fx()     { n=$((n + 1)); "$1" "${1#fx_}-$n" || { bad "$FIX: $1"; finish; }; }
casedir() { n=$((n + 1)); CD="$TMP/case-$n"; mkdir -p "$CD" || { bad "$FIX: case dir"; finish; }; }
copy_cli() { casedir; COPY="$CD"; cp "$CLI" "$HELPERS"/zuvo_comment_*.py "$COPY/" || { bad "$FIX: copy"; finish; }; }
fx_unb() { repo "$1" && put s.py 'q = 1\n'; }
FFFD=$(printf '\357\277\275')

# ── one row per audited file; schema and header once; the run id of the machine lines ──
fx_led() {
  repo "$1" && put a.py 'x = 1\n' && put b.py 'y = 2\n' && put keep.py 'k = 0\n' && commit && H7=$(git -C "$R" rev-parse HEAD | cut -c1-7) \
    && put a.py 'x = 1\nz = 3\n' && put b.py 'y = 2\n# previously y was 3\n' && put c.md '# notes\n'
}
fx fx_led; audit --files a.py b.py c.md keep.py; runid
check "$rc|$(lq 'L[0], L[1] == "\t".join(COLS)')" "1|('$SCHEMA', True)" "a new ledger starts with the schema line and the 21-column header"
check "$(lq 'len(R), [(r["file"], r["nf"]) for r in N]')" "(4, [('a.py', 21), ('b.py', 21), ('c.md', 21), ('keep.py', 21)])" "4 files listed: 4 rows of 21 fields, in --files order, all under the RESULT run id"
check "$(lq 'sorted(set((r["date"], r["project"], r["head7"], r["base7"]) for r in N))')" "[('$(stamp "$run")', '${R##*/}', '$H7', '$H7')]" "date is the run's UTC second; project, head7 and base7 name the checkout and HEAD"
check "$(cells b.py '6:18')" "python 0 1 0 - 0.500 1 0 0 0 0 breach" "a narrative comment: lang, counts, whole-file density 0.500, narrative=1, verdict breach"
check "$(cells a.py '6:18')" "python 1 0 0 - 0.000 0 0 0 0 0 pass" "a clean code line: authored_code=1, verdict pass"
check "$(cells c.md '6:18')|$(cells keep.py '6:19')" "n/a - - - - - - - - - - n/a|- - - - - - - - - - - unchanged -" "an unsupported file is n/a, an unchanged one has no metrics and no blob"
check "$(lq 'F("a.py")["blob"], F("b.py")["blob"], F("c.md")["blob"]')" "('$(ho a.py)', '$(ho b.py)', '$(ho c.md)')" "blob is git hash-object of each post-image read"
check "$(lq 'sorted(set((r["thresholds"], r["notes"]) for r in N))')" "[('$DEFAULTS', '-')]" "every row records the thresholds; notes are empty without justifications"
check "$(tail -n 2 "$TMP/out" | grep -c ' env=')" "0" "ZUVO_COMMENT_AUDIT_LOG is not a threshold: neither machine line carries env="
fx fx_led; audit --files a.py b.py c.md keep.py; runid; run1=$run
audit --files a.py; runid
check "$rc|$(lq 'L.count(A[0]), L.count(A[1]), len(R), len(N)' "$SCHEMA" "$HEADER")|$([ "$run" != "$run1" ] && echo distinct)" "0|(1, 1, 5, 1)|distinct" "a second run appends one row under a new run id; schema and header stay single"
fx fx_led; audit --json --files b.py; run=$(j 'd["run"]')
check "$rc|$(lq 'len(N), len(R), F("b.py")["verdict"]')" "1|(1, 1, 'breach')" "--json writes its row under the JSON run id, rc 1 kept"
fx fx_led; ZUVO_COMMENT_MAX_DENSITY=0.9 audit --files a.py; runid
check "$rc|$(lq 'F("a.py")["thresholds"]')|$(last 2 | sed 's/.* justified=0//')" "0|density=0.90(env) min_lines=20(default) block=4(default) justify_max=2(default)| env=ZUVO_COMMENT_MAX_DENSITY unchanged=0" "an env threshold is recorded with its source; env= names the threshold only"
fx fx_led; ZUVO_COMMENT_MIN_LINES=1 audit --files b.py; runid
check "$rc|$(cells b.py '12:17')" "1|1 0 0 1 0" "one comment line of one: narrative, long, claims, density_breach and justified land in their own columns"

# ── verdict kinds, notes and cells that hold tabs, invalid UTF-8 or separators ──
fx_kinds() {
  repo "$1" && put keep.py 'k = 1\n' && put gone.py 'g = 1\n' && commit && rm -f "$R/gone.py" && putb big.py 'b"x = 1\n" * 349526' \
    && put j.py 'j = 1\n# previously j\n' && putb bad.py 'b"s = \"\xff\xfe\"\n"' \
    && python3 -c 'import sys; open(sys.argv[1] + "/t\tab.py", "w").write("p = 1\n")' "$R"
}
fx_kinds2() { repo "$1" && python3 -c 'import os, sys; open(os.path.join(sys.argv[1], "l\u2028s.py"), "w").write("w = 1\n")' "$R"; }
JID="N:j.py:$(sha8 'previously j')"
fx fx_kinds; audit --files keep.py gone.py big.py j.py bad.py $'t\tab.py' --justify "$JID="$'keeps the cache|local\tper request'; runid
check "$rc|$(lq '"|".join(r["file"] + ":" + r["verdict"] for r in N)')" '0|keep.py:unchanged|gone.py:deleted|big.py:n/a|j.py:justified|bad.py:pass|t\x09ab.py:pass' "every n/a form is stored as n/a; a tab in a path is escaped"
check "$(lq 'F("j.py")["justified"], F("j.py")["narrative"], F("j.py")["notes"]')" "('1', '1', '$JID=keeps the cache local per request')" "an accepted justification is counted and kept in notes with | and tab flattened"
check "$(lq 'F("big.py")["notes"], F("big.py")["lang"], F("big.py")["blob"], F("gone.py")["blob"]')" "('n/a (too large)', '-', '-', '-')" "the whole n/a verdict goes to notes; a working-tree file never read has no blob"
check "$(lq 'F("bad.py")["blob"], sorted(set(r["nf"] for r in R))')" "('$(ho bad.py)', [21])" "invalid UTF-8 is hashed as raw bytes; every row keeps 21 fields"
fx fx_kinds2; audit --files $'l\xe2\x80\xa8s.py'; runid
check "$rc|$(lq '" ".join(r["file"] for r in N) + " " + str(sorted(set(r["nf"] for r in N)))')" '0|l\u2028s.py [21]' "U+2028 in a path is written as \\u2028, never raw, and the row keeps 21 fields"
check "$(unit 'import zuvo_comment_ledger as l
rows = l.format_rows("20260102T030405Z-1", l.Origin("p", "-", "-", "sha1"), "t",
                     [("x\udcff.py", "pass", "python", None, "-"), ("l\u2028s.py", "pass", "python", None, "-")], {})
print(" ".join(r.split("\t")[5] for r in rows), sorted(set(len(r.split("\t")) for r in rows)))')" 'x\xff.py l\u2028s.py [21]' "a path byte that is not UTF-8, surrogate-escaped as the CLI decodes it, is written as \\xNN"

# ── invalid UTF-8 inside the ledger: read as U+FFFD, never a crash ───────────
check "$(unit 'import io, zuvo_comment_ledger as l
good = b"2026-01-01T00:00:00Z\tr1\tp\xffq\tabc1234\tabc1234\tf.py\tpython\t1\t0\t0\t-\t-\t0\t0\t0\t0\t0\tpass\t-\tt\t-"
cells = good.split(b"\t")
lines = [l.SCHEMA.encode(), "\t".join(l.COLUMNS).encode(), good, b"\t".join(cells[:7] + [b"1\xff"] + cells[8:]),
         b"\t".join([b"2026\xff-01-01T00:00:00Z"] + cells[1:])]
got = [(d, s and (s.project, s.run, s.measured, s.sums)) for d, s in l.read_rows(io.BytesIO(b"\n".join(lines) + b"\n"))]
try:
    list(l.read_rows(io.BytesIO(b"# comment-audit ledger schema=1\xff\n")))
    refused = "read"
except ValueError as exc:
    refused = str(exc)
print(ascii((got, refused)))')" "([('2026-01-01T00:00:00Z', ('p\\ufffdq', 'r1', True, (0, 0, 0, 0, 0))), ('2026-01-01T00:00:00Z', None)], \"unsupported ledger header '# comment-audit ledger schema=1\\ufffd', this comment-audit reads '$SCHEMA'\")" "read_rows: an invalid byte in a project reads as U+FFFD, in a count makes the row malformed, in the date makes it no row, in the schema line refuses the ledger"
bytes_ledger() {  # bytes_ledger PATH: schema, header, a row whose project holds \xff, one whose count does, one whose date does
  python3 -c 'import sys
good = b"2026-01-01T00:00:00Z\tr1\tp\xffq\tabc1234\tabc1234\tf.py\tpython\t1\t0\t0\t-\t-\t0\t0\t0\t0\t0\tpass\t-\tt\t-"
cells = good.split(b"\t")
lines = [sys.argv[2].encode(), sys.argv[3].encode(), good, b"\t".join(cells[:7] + [b"1\xff"] + cells[8:]),
         b"\t".join([b"2026\xff-01-01T00:00:00Z"] + cells[1:])]
open(sys.argv[1], "wb").write(b"\n".join(lines) + b"\n")' "$1" "$SCHEMA" "$HEADER"
}
casedir; bytes_ledger "$CD/bytes.log" || { bad "$FIX: bytes ledger"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$CD/bytes.log" CWD="$CD" audit --trend --since 2025-12-31
check "$rc|$(head -1 "$TMP/out")|$(rows_of "p${FFFD}q")|$(wc -l < "$TMP/out" | tr -d ' ')" "0|trend: since=2025-12-31T00:00:00Z project=* rows=1 skipped=1 ledger=$CD/bytes.log|p${FFFD}q 1 1 0 - - - 0 0 0 0 0|3" "--trend over invalid UTF-8: the project prints with U+FFFD, a count holding the byte is skipped, a date holding it is no row"
casedir; printf '# comment-audit ledger schema=1\377\n%s\n' "$HEADER" > "$CD/badschema.log" || { bad "$FIX: bad schema"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$CD/badschema.log" CWD="$CD" audit --trend
errors_cleanly "error: unsupported ledger header '# comment-audit ledger schema=1${FFFD}', this comment-audit reads '$SCHEMA'" "--trend refuses a schema line holding an invalid byte and names it with U+FFFD"
fx fx_unb; printf '# comment-audit ledger schema=1\377\n%s\n' "$HEADER" > "$R.bad.log" && cp "$R.bad.log" "$R.bad.before" || { bad "$FIX: bad schema write"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$R.bad.log" audit --files s.py
errors_cleanly "cannot write the ledger $R.bad.log: unsupported ledger header '# comment-audit ledger schema=1${FFFD}'" "an audit refuses to append to a ledger whose schema line holds an invalid byte"
check "$(cmp "$R.bad.log" "$R.bad.before" 2>&1 && echo identical)" "identical" "the refused ledger with the invalid byte is left byte-identical"

# ── --range, --base, an unborn HEAD and sha256 object ids ────────────────────
fx_rng() {
  repo "$1" && put f.py 'v = 1\n' && commit A && A=$(git -C "$R" rev-parse HEAD) && put f.py 'v = 1\n# previously 2\n' \
    && commit B && B=$(git -C "$R" rev-parse HEAD) && put g.py 'g = 1\n' && commit C && C=$(git -C "$R" rev-parse HEAD) && put f.py 'v = 3\n'
}
fx_bigr() { repo "$1" && put x.py 'x = 1\n' && commit E && E=$(git -C "$R" rev-parse HEAD) && putb big.py 'b"x = 1\n" * 349526' && commit F && F=$(git -C "$R" rev-parse HEAD); }
fx_s256() {
  repo "$1" --object-format=sha256 && put k.py 'k = 1\n' && commit A && S1=$(git -C "$R" rev-parse HEAD) \
    && put k.py 'k = 1\n# previously k\n' && commit B && S2=$(git -C "$R" rev-parse HEAD) && put k.py 'k = 2\n'
}
fx fx_rng; audit --range "$A..$B" --files f.py; runid
check "$rc|$(lq 'F("f.py")["head7"], F("f.py")["base7"], F("f.py")["blob"], F("f.py")["verdict"]')" "1|('${B:0:7}', '${A:0:7}', '$(git -C "$R" rev-parse "$B:f.py")', 'breach')" "--range A..B with HEAD at C: head7 is B, base7 is A, blob is B:f.py"
fx fx_rng; audit --base "$A" --files f.py; runid
check "$rc|$(lq 'F("f.py")["head7"], F("f.py")["base7"], F("f.py")["blob"], F("f.py")["verdict"]')" "0|('${C:0:7}', '${A:0:7}', '$(ho f.py)', 'pass')" "--base A: head7 is HEAD, base7 is A, blob is the working-tree bytes"
fx fx_bigr; audit --range "$E..$F" --files big.py; runid
check "$rc|$(lq 'F("big.py")["verdict"], F("big.py")["notes"], F("big.py")["blob"]')" "0|('n/a', 'n/a (too large)', '$(git -C "$R" rev-parse "$F:big.py")')" "--range: a blob too large to read still records its object id"
fx fx_unb; audit --files s.py; runid
check "$rc|$(lq 'F("s.py")["project"], F("s.py")["head7"], F("s.py")["base7"], F("s.py")["blob"]')" "0|('${R##*/}', '-', '$(git -C "$R" hash-object -t tree /dev/null | cut -c1-7)', '$(ho s.py)')" "unborn HEAD: head7 is -, base7 the empty tree"
fx fx_s256; audit --files k.py; runid; blob=$(lq 'F("k.py")["blob"]')
check "$rc|$blob|$(printf '%s' "$blob" | grep -cE '^[0-9a-f]{64}$')" "0|$(ho k.py)|1" "a sha256 repository: the blob is the 64-hex id git hash-object gives"
fx fx_s256; audit --range "$S1..$S2" --files k.py; runid
check "$rc|$(lq 'F("k.py")["blob"], F("k.py")["head7"]')" "1|('$(git -C "$R" rev-parse "$S2:k.py")', '${S2:0:7}')" "a sha256 repository with --range: blob is B:k.py's 64-hex id"

# ── where the ledger lives ──────────────────────────────────────────────────
fx fx_unb; BIN='env' audit -u ZUVO_COMMENT_AUDIT_LOG ZUVO_HOME="$R.zhome" "$CLI" --files s.py; runid
check "$rc|$(LEDGER="$R.zhome/comment-audit.log" lq 'L[0], len(N)')|$([ -e "$ZUVO_COMMENT_AUDIT_LOG" ] && echo written || echo absent)" "0|('$SCHEMA', 1)|absent" "without ZUVO_COMMENT_AUDIT_LOG the ledger is \$ZUVO_HOME/comment-audit.log, its directory created"
fx fx_unb; BIN='env' audit -u ZUVO_COMMENT_AUDIT_LOG -u ZUVO_HOME HOME="$R.home" "$CLI" --files s.py; runid
check "$rc|$(LEDGER="$R.home/.zuvo/comment-audit.log" lq 'len(N)')|$([ -e "$ZUVO_COMMENT_AUDIT_LOG" ] && echo written || echo absent)" "0|1|absent" "without either variable the ledger is ~/.zuvo/comment-audit.log"
fx fx_unb; ZUVO_COMMENT_AUDIT_LOG='' ZUVO_HOME="$R.zh3" audit --files s.py; runid
check "$rc|$(LEDGER="$R.zh3/comment-audit.log" lq 'len(N)')|$([ -e "$ZUVO_COMMENT_AUDIT_LOG" ] && echo written || echo absent)" "0|1|absent" "an empty ZUVO_COMMENT_AUDIT_LOG is unset: the rows go to \$ZUVO_HOME and the exported path is never created"
check "$(unit 'import zuvo_comment_ledger as l
print(l.ledger_path({"HOME": "/else/h"}), l.ledger_path({"HOME": "/else/h", "ZUVO_HOME": "/z"}), l.ledger_path({"ZUVO_COMMENT_AUDIT_LOG": "/x.log"}), l.ledger_path({}))')" \
  "/else/h/.zuvo/comment-audit.log /z/comment-audit.log /x.log $TMP/home/.zuvo/comment-audit.log" "ledger_path reads HOME from the environ it is given; only a missing HOME falls back to the process"

# ── an unwritable or short-written ledger is rc 2 even when the audit is clean ──
fx_many() { local i=0; repo "$1" || return 1; while [ "$i" -lt 120 ]; do printf 'm%d = %d\n' "$i" "$i" > "$R/m$i.py" || return 1; i=$((i + 1)); done; }
fx fx_unb; : > "$R.afile" || { bad "$FIX: afile"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$R.afile/ledger.log" audit --files s.py
errors_cleanly "cannot write the ledger $R.afile/ledger.log: $(strerr EEXIST)" "a ledger under a FILE: a clean audit exits 2 with the errno text, prints no PASS"
fx fx_unb; mkdir -p "$R.adir" || { bad "$FIX: adir"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$R.adir" audit --json --files s.py
errors_cleanly "cannot write the ledger $R.adir: $(strerr EISDIR)" "a ledger path that is a directory: --json exits 2 with the errno text and prints nothing"
fx fx_many; TORN="$R.torn.log"
ZUVO_COMMENT_AUDIT_LOG="$TORN" audit --files m0.py; cp "$TORN" "$R.torn.before" || { bad "$FIX: torn seed"; finish; }
( ulimit -f 8 && cd "$R" && ZUVO_COMMENT_AUDIT_LOG="$TORN" bounded "$CLI" ) > "$TMP/out" 2> "$TMP/err"; rc=$?
errors_cleanly "cannot write the ledger $TORN: wrote " "a 120-file run whose write comes back short (ulimit -f 8): rc 2, nothing printed"
check "$(cmp "$TORN" "$R.torn.before" 2>&1 && echo identical)" "identical" "the short write is truncated away: the ledger is byte-identical to before the run"
fx fx_unb; printf 'hello\n' > "$R.foreign.log" || { bad "$FIX: foreign"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$R.foreign.log" audit --files s.py
check "$rc|$(head -1 "$TMP/err")|$(cat "$R.foreign.log")" "2|comment-audit: error: cannot write the ledger $R.foreign.log: not a comment-audit ledger|hello" "a file whose first line is not the schema line is refused and left as it was"
fx fx_unb; printf '# comment-audit ledger schema=2\n%s\n' "$HEADER" > "$R.s2w.log" && cp "$R.s2w.log" "$R.s2w.before" || { bad "$FIX: s2w"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$R.s2w.log" audit --files s.py; errors_cleanly "unsupported ledger header '# comment-audit ledger schema=2'" "rows are never appended to a schema=2 ledger"
check "$(cmp "$R.s2w.log" "$R.s2w.before" 2>&1 && echo identical)" "identical" "the refused schema=2 ledger is left byte-identical"
fx fx_unb; printf '# comment-audit ledger schema=2\033[31m\n' > "$R.esc.log" || { bad "$FIX: esc"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$R.esc.log" audit --files s.py; errors_cleanly "unsupported ledger header '# comment-audit ledger schema=2\\x1b[31m'" "a refused ledger header is echoed escaped, never raw"
fx fx_unb; mkfifo "$R.fifo.log" || { bad "$FIX: fifo"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$R.fifo.log" audit --files s.py; errors_cleanly "cannot write the ledger $R.fifo.log: not a regular file" "a FIFO as the ledger is refused, never blocked on"
fx fx_unb; printf '%s\n%s\n' "$SCHEMA" "$HEADER" > "$R.target.log" && cp "$R.target.log" "$R.target.before" && ln -s "$R.target.log" "$R.link.log" \
  || { bad "$FIX: link"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$R.link.log" audit --files s.py; errors_cleanly "cannot write the ledger $R.link.log: $(strerr ELOOP)" "a symlink as the ledger is refused (O_NOFOLLOW) with the errno text"
check "$(cmp "$R.target.log" "$R.target.before" 2>&1 && echo identical)" "identical" "the symlink's target ledger got no row"
fx fx_unb; printf '%s\n%s\n2026-01-01T00:00:00Z\tpartial' "$SCHEMA" "$HEADER" > "$ZUVO_COMMENT_AUDIT_LOG" || { bad "$FIX: torn tail"; finish; }
audit --files s.py; runid
check "$rc|$(lq '[x.split("\t")[:2] for x in L[-3:-1]], len(N), N[0]["nf"], len(L)')" "0|([['2026-01-01T00:00:00Z', 'partial'], ['$(stamp "$run")', '$run']], 1, 21, 5)" "a ledger ending in a torn line gets a newline first: the new row never fuses with it"

# ── project is the main checkout, also from a linked worktree ───────────────
fx_wt() {
  repo "$1" && put m.py 'm = 1\n' && commit && git -C "$R" worktree add -q "$R.side" -b side && put sub/n.py 'n = 1\n' \
    && printf 'w = 1\n' > "$R.side/w.py"
}
fx fx_wt; CWD="$R.side" audit --files w.py; runid
check "$rc $(lq 'F("w.py")["project"]')" "0 ${R##*/}" "project is the main checkout's name from a linked worktree"
fx fx_wt; CWD="$R/sub" audit --files n.py; runid
check "$rc $(lq 'F("sub/n.py")["project"]')" "0 ${R##*/}" "project is the main checkout's name from a subdirectory"

# ── concurrent runs and the lock ────────────────────────────────────────────
fx_conc() { local i=0; repo "$1" || return 1; while [ "$i" -lt 40 ]; do printf 'c%d = %d\n' "$i" "$i" > "$R/c$i.py" || return 1; i=$((i + 1)); done; }
fx fx_conc; CONC="$ZUVO_COMMENT_AUDIT_LOG"
( cd "$R" && bounded "$CLI" ) > "$TMP/o1" 2>&1 & w1=$!
( cd "$R" && bounded "$CLI" ) > "$TMP/o2" 2>&1 & w2=$!
wait "$w1"; r1=$?; wait "$w2"; r2=$?
runid "$TMP/o1"; c1=$run; runid "$TMP/o2"; c2=$run
check "$r1 $r2|$(LEDGER="$CONC" lq 'L.count(A[0]), len(R), sorted(set(r["nf"] for r in R))' "$SCHEMA")|$(run=$c1 LEDGER="$CONC" lq 'len(N)') $(run=$c2 LEDGER="$CONC" lq 'len(N)')|$([ "$c1" != "$c2" ] && echo distinct)" \
  "0 0|(1, 80, [21])|40 40|distinct" "two concurrent runs: distinct run ids, one header, both runs' 40 rows intact"
check "$(python3 -c 'import fcntl; print(callable(fcntl.flock))' 2>&1)|$LOCK_NB_EX" "True|6" "premise: this POSIX python has fcntl.flock and LOCK_EX|LOCK_NB is 6, so every lock case below runs"
ops() { sort -u "$TMP/$1.ops" 2>/dev/null | tr '\n' ' '; }
retries() { awk 'END { print (NR >= 2) ? "retried" : "attempts " NR }' "$TMP/$1.ops" 2>/dev/null; }
fx fx_conc; LK="$ZUVO_COMMENT_AUDIT_LOG"; printf '%s\n%s\n' "$SCHEMA" "$HEADER" > "$LK" || { bad "$FIX: lock ledger"; finish; }
hold "$LK" lk $'# held\n'
spied "$LK" lk --files c0.py; handshake "$TMP/lk.waiting"; seen=$([ -e "$TMP/lk.done" ] && echo after || echo held)
release lk; wait "$auditor"; rc=$?; runid
check "$rc|$seen|$(retries lk)|$(ops lk)|$(LEDGER="$LK" lq '[x.split("\t")[1] if D(x) else x for x in L[-3:]]')" \
  "0|held|retried|$LOCK_NB_EX |['# held', '$run', '']" "a run retries a held lock with LOCK_EX|LOCK_NB only, and its row lands after the holder's line"
fx fx_conc; RACE="$ZUVO_COMMENT_AUDIT_LOG"; : > "$RACE" || { bad "$FIX: race ledger"; finish; }
hold "$RACE" race "$SCHEMA$NL$HEADER$NL"
spied "$RACE" race --files c0.py; handshake "$TMP/race.waiting"; release race; wait "$auditor"; rc=$?; runid
check "$rc|$(retries race)|$(LEDGER="$RACE" lq 'L.count(A[0]), L.count(A[1]), len(N), len(L)' "$SCHEMA" "$HEADER")" "0|retried|(1, 1, 1, 4)" "a ledger empty when the run opened it but given a header under the lock gets no second header"
fx fx_conc; ZL="$ZUVO_COMMENT_AUDIT_LOG"; printf '%s\n%s\n' "$SCHEMA" "$HEADER" > "$ZL" && cp "$ZL" "$R.before" || { bad "$FIX: zwait ledger"; finish; }
hold "$ZL" zw ""
inproc lockclock --files c0.py; seen=$([ -e "$TMP/zw.done" ] && echo after || echo held); release zw
check "$rc|$seen|$(head -1 "$TMP/err")|$(cmp "$ZL" "$R.before" && echo unchanged)|$(report 'd["flocks"], d["sleeps"]')" \
  "2|held|comment-audit: error: cannot write the ledger $ZL: ledger is locked by another run|unchanged|([6, 6], [0.05])" "a fake clock past LOCK_WAIT: two real flock tries on the held lock, one poll sleep, then rc 2 and nothing written"
LATE=$(printf '2026-01-01T00:00:00Z\tlate1\tlate\tabc1234\tabc1234\tf.py\tpython\t1\t0\t0\t-\t-\t0\t0\t0\t0\t0\tpass\t-\tt\t-')
casedir; TL="$CD/trend-lock.log"; printf '%s\n%s\n' "$SCHEMA" "$HEADER" > "$TL" || { bad "$FIX: trend lock ledger"; finish; }
hold "$TL" tl "$LATE$NL"
ZUVO_COMMENT_AUDIT_LOG="$TL" CWD="$CD" audit --trend --project late --since 2025-12-31; seen=$([ -e "$TMP/tl.done" ] && echo after || echo held)
during="$rc|$(sed -n 2p "$TMP/out")|$seen"; release tl
ZUVO_COMMENT_AUDIT_LOG="$TL" CWD="$CD" audit --trend --project late --since 2025-12-31
check "$during|$rc|$(rows_of late)" "0|(no rows)|held|0|late 1 1 0 - - - 0 0 0 0 0" "--trend takes no lock: it answers while a writer holds the lock, and counts the row once the writer lands it"
check "$(unit 'import errno, os, sys, types, zuvo_comment_ledger as l
out = []
for code in (errno.ENOLCK, errno.EOPNOTSUPP, errno.ENOSYS, errno.EIO):
    calls = []
    def refuse(fd, operation, code=code, calls=calls):
        calls.append((os.fstat(fd).st_ino == os.stat(sys.argv[1]).st_ino, operation))
        raise OSError(code, os.strerror(code))
    l.fcntl = types.SimpleNamespace(flock=refuse, LOCK_EX=2, LOCK_NB=4)
    try:
        l.append(["row"], sys.argv[1])
        out.append(("ok", calls))
    except OSError as exc:
        out.append((errno.errorcode[exc.errno], calls))
print(out, open(sys.argv[1]).read().count("row\n"))' "$TMP/nolock.log")" "[('ok', [(True, 6)]), ('ok', [(True, 6)]), ('ok', [(True, 6)]), ('EIO', [(True, 6)])] 3" "flock refused with ENOLCK, EOPNOTSUPP or ENOSYS falls back to a plain append; any other errno is an error; each append asks once, LOCK_EX|LOCK_NB on the ledger's fd"
check "$(unit 'import errno, os, sys, types, zuvo_comment_ledger as l
class Clock:
    def __init__(self, jump):
        self.now, self.jump, self.sleeps = 100.0, jump, []
    def monotonic(self):
        return self.now
    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += self.jump or seconds
def busy(times, path, clock):
    calls = []
    def flock(fd, operation):
        calls.append((os.fstat(fd).st_ino == os.stat(path).st_ino, operation))
        if len(calls) <= times:
            raise OSError(errno.EWOULDBLOCK, os.strerror(errno.EWOULDBLOCK))
    l.fcntl, l.time = types.SimpleNamespace(flock=flock, LOCK_EX=2, LOCK_NB=4), clock
    try:
        l.append(["row"], path)
        outcome = "written"
    except OSError as exc:
        outcome = (exc.errno == errno.EWOULDBLOCK, exc.strerror)
    return outcome, calls, clock.sleeps, open(path).read().count("row\n")
print(busy(2, sys.argv[1], Clock(0)))
print(busy(10 ** 6, sys.argv[2], Clock(l.LOCK_WAIT)))' "$TMP/busy.log" "$TMP/stuck.log")" \
  "('written', [(True, 6), (True, 6), (True, 6)], [0.05, 0.05], 1)${NL}((True, 'ledger is locked by another run'), [(True, 6), (True, 6)], [0.05], 0)" "a fake clock: two busy answers cost two LOCK_POLL sleeps before the row lands; busy past LOCK_WAIT gives up after one sleep and writes nothing"
check "$(cd "$TMP" && unit 'import errno, os, zuvo_comment_ledger as l
l.fcntl = None
l.append(["one"], "bare.log")
real, writes, truncates = os.write, [], []
def short(fd, data):
    writes.append(data)
    return real(fd, data[:2])
os.write, os.ftruncate = short, lambda fd, size: truncates.append(size)
try:
    l.append(["two"], "bare.log")
except OSError as exc:
    print(errno.errorcode[exc.errno], end=" ")
os.write = real
l.append(["three"], "bare.log")
print(open("bare.log").read().split("\n")[2:], writes, truncates)')" "EIO ['one', 'tw', 'three', ''] [b'two\\n'] []" "without fcntl, in a path with no directory part: one write of the row, a short write is not truncated (no lock) and the next run starts on a new line"
check "$(cd "$TMP" && unit 'import os, zuvo_comment_ledger as l
l.fcntl = None
l.append(["one"], "unlocked.log")
real, writes = os.write, []
def racing(fd, data):
    writes.append(data)
    other = os.open("unlocked.log", os.O_WRONLY | os.O_APPEND)
    real(other, b"other\n")
    os.close(other)
    return real(fd, data)
os.write = racing
l.append(["two"], "unlocked.log")
os.write = real
print(open("unlocked.log").read().split("\n")[2:], writes)')" "['one', 'other', 'two', ''] [b'two\\n']" "without a lock, a line another writer appends after the run positioned itself survives: the write is one O_APPEND"
check "$(unit 'import zuvo_comment_ledger as l
print(l.origin("/w/sub", "/x/modules/sub", "sha1", "", ""), l.origin("/w/wt", "../main/.git", "sha9", "abcdef12", "1234567890"))')" \
  "Origin(project='sub', head7='-', base7='-', fmt='sha1') Origin(project='main', head7='abcdef1', base7='1234567', fmt='sha1')" "origin: a common dir not named .git names the checkout itself; an unknown object format is sha1"

# ── --trend over a ledger with known rows, read at a frozen now ─────────────
# TNOW is the clock every case below reads; each row date is written out by hand relative to it.
TNOW="2026-06-15T12:00:00+00:00"
trend_ledger() {  # trend_ledger PATH
  python3 -c 'import sys
COLS = sys.argv[2].split()
def row(when, run, project, density="-", fdens="-", cmt="0", n="0", l="0", d="0", j="0", ncols=21):
    cells = [when, run, project, "abc1234", "abc1234", "f.py", "python", "1", cmt, "0", density, fdens,
             n, l, "0", d, j, "pass", "-", "t", "-"]
    return "\t".join(cells[:ncols] + ["x"] * (ncols - 21))
H1, H2, BETA, OLD = "2026-06-15T11:00:00Z", "2026-06-15T10:00:00Z", "2026-06-05T13:00:00Z", "2026-05-06T12:00:00Z"
out = ["# comment-audit ledger schema=1", "\t".join(COLS), "# a note", "hello world"]
for i in range(1, 11):
    out.append(row(H1, "r1", "alpha", "%.3f" % (i / 100), "0.500", "1", str(int(i == 3)), str(int(i == 4)),
                   "0", str(int(i == 5))))
out.append(row(H1, "r1", "alpha"))
out.append(row(H2, "r2", "alpha", cmt="2", n="1"))
out.append(row(BETA, "r3", "beta", "0.350", "0.400", "7", l="2", d="1"))
out.append(row("2026-05-26T00:00:00Z", "g1", "gamma"))
out.append(row("2026-05-25T23:59:59Z", "g0", "gamma"))
out.append(row(H1, "p1", "pi|pe"))
out.append(row("\u0662\u0660\u0662\u0666-01-01T00:00:00Z", "e1", "eta"))
out.append("\t".join([H1, "d1", "delta", "abc1234", "abc1234", "u.py", "-"] + ["-"] * 10 + ["unchanged", "-", "t", "-"]))
out.append(row(OLD, "old", "alpha", "0.900", "0.900"))
out += [row(H1, "bad", "alpha", ncols=3), row(H1, "bad", "alpha", n="x"), row(H1, "bad", "alpha", ncols=22),
        row(H1, "bad", "alpha", "1.500"), row(H1, "bad", "alpha", n="-1"), row(OLD, "bad", "alpha", ncols=3)]
open(sys.argv[1], "w").write("\n".join(out) + "\n")' "$1" "$COLS"
}
# trend_case ARGS: a fresh known-rows ledger in a new case directory, then --trend ARGS at TNOW in-process.
trend_case() { casedir; TREND="$CD/trend.log"; trend_ledger "$TREND" || { bad "$FIX: trend ledger"; finish; }; ZUVO_COMMENT_AUDIT_LOG="$TREND" CWD="$CD" INPROC_NOW="$TNOW" inproc clock --trend "$@"; }
trend_case
check "$rc|$(head -1 "$TMP/out")" "0|trend: since=2026-05-16T12:00:00Z project=* rows=17 skipped=5 ledger=$TREND" "--trend (30 days back from TNOW): header, # lines and undated text are not rows; 5 malformed rows in the window are counted"
check "$(rows_of PROJECT)|$(rows_of alpha)" "PROJECT RUNS FILES GATED DENS_P50 DENS_P90 FILE_P50 AUTH_CMT D N L JUSTIFIED|alpha 2 12 10 0.050 0.090 0.500 12 0 2 1 1" "alpha: 2 runs, nearest-rank p50 and p90 over the 10 gated densities, sums of N, L and justified"
check "$(rows_of beta)|$(rows_of gamma)|$(rows_of 'pi|pe')|$(rows_of delta)" "beta 1 1 1 0.350 0.350 0.400 7 1 0 2 0|gamma 2 2 0 - - - 0 0 0 0 0|pi|pe 1 1 0 - - - 0 0 0 0 0|delta 1 0 0 - - - 0 0 0 0 0" "one row per project; FILES counts measured rows only, so an unchanged file is a run, not a file"
check "$(awk 'NR > 2 { print $1 }' "$TMP/out" | tr '\n' ' ')" "alpha beta delta gamma pi|pe " "projects are sorted by name"
casedir; trend_ledger "$CD/full.log" && tail -n +2 "$CD/full.log" > "$CD/noschema.log" || { bad "$FIX: noschema"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$CD/noschema.log" CWD="$CD" INPROC_NOW="$TNOW" inproc clock --trend
check "$rc|$(head -1 "$TMP/out" | cut -d' ' -f4,5)|$(rows_of alpha)" "0|rows=17 skipped=5|alpha 2 12 10 0.050 0.090 0.500 12 0 2 1 1" "a ledger without the schema line is still read"
casedir; trend_ledger "$CD/full.log" && sed '1s/schema=1/schema=2/' "$CD/full.log" > "$CD/schema2.log" || { bad "$FIX: schema2"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$CD/schema2.log" CWD="$CD" INPROC_NOW="$TNOW" inproc clock --trend
errors_cleanly "unsupported ledger header '# comment-audit ledger schema=2'" "a ledger declaring schema=2 is rc 2, never read as schema 1"
casedir; trend_ledger "$CD/full.log" && sed '1s/$/ /' "$CD/full.log" > "$CD/schema1sp.log" || { bad "$FIX: schema1sp"; finish; }
ZUVO_COMMENT_AUDIT_LOG="$CD/schema1sp.log" CWD="$CD" INPROC_NOW="$TNOW" inproc clock --trend
errors_cleanly "unsupported ledger header '# comment-audit ledger schema=1 '" "the reader is as strict as the writer: a schema line with a trailing space is refused"
trend_case --days 7
check "$rc|$(head -1 "$TMP/out" | cut -d' ' -f2,4,5)|$(awk 'NR > 2 { print $1 }' "$TMP/out" | tr '\n' ' ')" "0|since=2026-06-08T12:00:00Z rows=14 skipped=5|alpha delta pi|pe " "--days 7 drops rows older than 7 days"
trend_case --days 10; in10=$(rows_of beta | cut -d' ' -f1); trend_case --days 9; in9=$(rows_of beta | cut -d' ' -f1)
check "$in10|$in9" "beta|" "a row 10 days minus an hour old is inside --days 10 and outside --days 9"
trend_case --days 60
check "$rc|$(head -1 "$TMP/out" | cut -d' ' -f4,5)|$(rows_of alpha)" "0|rows=18 skipped=6|alpha 3 13 11 0.060 0.100 0.500 12 0 2 1 1" "--days 60 takes the 40-day-old row and its malformed neighbour; p50 and p90 move with it"
trend_case --since 2026-05-26 --project gamma; g1=$(rows_of gamma); trend_case --since 2026-05-25 --project gamma; g2=$(rows_of gamma)
check "$g1|$g2" "gamma 1 1 0 - - - 0 0 0 0 0|gamma 2 2 0 - - - 0 0 0 0 0" "--since keeps a row at 00:00:00Z of that day and drops 23:59:59Z of the day before"
check "$(report 'd["now_calls"]')" "1" "the frozen clock was read once, by the trend window"
check "$(unit 'import datetime as dt, zuvo_comment_ledger as l
now = dt.datetime(2026, 1, 2, 12, 0, tzinfo=dt.timezone(dt.timedelta(hours=2)))
print(l.window_start(1, None, now), l.window_start(None, "2026-01-02", now), l.window_start(None, None, now))
try:
    l.window_start(1, None, now.replace(tzinfo=None))
except ValueError as exc:
    print("ValueError", exc)')" \
  "2026-01-01T10:00:00Z 2026-01-02T00:00:00Z 2025-12-03T10:00:00Z${NL}ValueError now must be timezone-aware" "the window is UTC: --days counts 24-hour days back from now in UTC, --since is 00:00:00Z; a naive now is refused"
trend_case --project beta
check "$rc|$(head -1 "$TMP/out" | cut -d' ' -f3-5)|$(awk 'NR > 2' "$TMP/out" | wc -l | tr -d ' ')" "0|project=beta rows=1 skipped=5|1" "--project keeps one project's rows; malformed rows stay counted"
trend_case --markdown
check "$rc|$(sed -n '3,6p' "$TMP/out" | tr '\n' '#')" '0|| PROJECT | RUNS | FILES | GATED | DENS_P50 | DENS_P90 | FILE_P50 | AUTH_CMT | D | N | L | JUSTIFIED |#|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|#| alpha | 2 | 12 | 10 | 0.050 | 0.090 | 0.500 | 12 | 0 | 2 | 1 | 1 |#| beta | 1 | 1 | 1 | 0.350 | 0.350 | 0.400 | 7 | 1 | 0 | 2 | 0 |#' "--markdown prints a pipe table after the header line"
check "$(grep -cF '| pi\|pe | 1 |' "$TMP/out")|$(sed -n 2p "$TMP/out")" "1|" "--markdown escapes | in a project name; a blank line follows the header"
trend_case --markdown --project 'pi|pe'
check "$rc|$(head -1 "$TMP/out" | cut -d' ' -f3)" '0|project=pi\|pe' "--markdown escapes the header's project name like a cell"
trend_case --markdown --project 'no_such'
check "$rc|$(head -1 "$TMP/out" | cut -d' ' -f3)|$(sed -n 2p "$TMP/out")" '0|project=no\_such|(no rows)' "--markdown escapes the header when there are no rows too"
casedir; trend_ledger "$CD/trend.log" || { bad "$FIX: closed trend"; finish; }
check "$(ZUVO_COMMENT_AUDIT_LOG="$CD/trend.log" CWD="$CD" closed --trend)" "0 0 False" "--trend into a closed pipe: rc 0, nothing on stderr"
casedir; ZUVO_COMMENT_AUDIT_LOG="$CD/none.log" CWD="$CD" audit --trend
check "$rc|$(cut -d' ' -f4,5 "$TMP/out" | head -1)|$(sed -n 2p "$TMP/out")" "0|rows=0 skipped=0|(no rows)" "a missing ledger is no rows, rc 0"
casedir; mkdir -p "$CD/adir" && ZUVO_COMMENT_AUDIT_LOG="$CD/adir" CWD="$CD" audit --trend
errors_cleanly "cannot read the ledger $CD/adir: not a regular file" "a ledger that is a directory: --trend exits 2 naming why"
trend_error() { local want="$1"; shift; casedir; ZUVO_COMMENT_AUDIT_LOG="$CD/none.log" CWD="$CD" audit --trend "$@"; errors_cleanly "$want" "--trend $* is rc 2 naming the cause"; }
trend_error "--project: empty project name" --project ""
trend_error "--days 0" --days 0
trend_error "--days -7" --days -7
trend_error "--days 3651" --days 3651
trend_error "invalid int value" --days x
trend_error "--since '2026-13-01'" --since 2026-13-01
trend_error "--since '20260901'" --since 20260901
trend_error "not allowed with argument" --days 3 --since 2026-09-01
trend_error "--files is not allowed with --trend" --files a.py
trend_error "argument --files: expected at least one argument" --files
casedir; CWD="$CD" audit --days 3 --files a.py; errors_cleanly "--days needs --trend" "--days without --trend is rc 2, never ignored"
check "$(unit 'import zuvo_comment_ledger as l
out = []
for run in ("20260102T030405Z", "20261302T030405Z-1", "20260132T030405Z-1", "20260102T240405Z-1", "20260102T036005Z-1",
            "20260102T030460Z-1", "20261231T235959Z-1"):
    try:
        out.append(len(l.format_rows(run, l.Origin("p", "-", "-", "sha1"), "t", [], {})))
    except ValueError:
        out.append("ValueError")
print(out)')" "['ValueError', 'ValueError', 'ValueError', 'ValueError', 'ValueError', 'ValueError', 0]" "a run id without a pid or with month, day, hour, minute or second out of range is refused before it becomes a date"
SEED=20261003
check "$(unit 'import calendar, datetime as dt, io, random, sys, zuvo_comment_ledger as l
seed, cases, bad = int(sys.argv[1]), 400, []
rng, now = random.Random(int(sys.argv[1])), dt.datetime(2026, 1, 2, 12, 0, tzinfo=dt.timezone.utc)
COUNTS = ("authored_code", "authored_comment", "carried", "narrative", "long", "claims", "density_breach", "justified")
def outcome(call):
    try:
        return call()
    except ValueError as exc:
        return "ValueError: %s" % exc
def counted(cells):
    table, rows, skipped = l.trend(l.read_rows(io.BytesIO(("\t".join(cells) + "\n").encode())), "2000", None)
    return rows, skipped, [row[2:4] + row[7:] for row in table]
for case in range(cases):
    y, m = rng.randint(1, 9999), rng.randint(1, 12)
    last = calendar.monthrange(y, m)[1]
    d = rng.randint(1, last)
    good = "%04d-%02d-%02d" % (y, m, d)
    wrong = rng.choice(["%04d-%02d-%02d" % (y, rng.randint(13, 99), d), "%04d-%02d-%02d" % (y, m, rng.randint(last + 1, 99)),
                        "%04d-00-%02d" % (y, d), "%04d-%02d-00" % (y, m), "0000-%02d-%02d" % (m, d), good[:-1], good + "1",
                        good.replace("-", "/")])
    days = rng.randint(-5, 3700)
    in_range = 1 <= days <= 3650
    counts = {c: rng.choice(["-", str(rng.randint(0, 50))]) for c in COUNTS}
    ratios = {c: rng.choice(["-", "%.3f" % rng.random()]) for c in ("density", "file_density")}
    fixed = dict(date="2026-01-01T00:00:00Z", run="r%d" % case, project="p", head7="abc1234", base7="abc1234",
                 file="f.py", lang="python", verdict="pass", blob="-", thresholds="t", notes="-")
    row = [{**fixed, **counts, **ratios}[c] for c in l.COLUMNS]
    metric, dens = l.COLUMNS.index(rng.choice(COUNTS)), l.COLUMNS.index("density")
    flaws = {"negative": row[:metric] + ["-%d" % rng.randint(1, 9)] + row[metric + 1:],
             "word": row[:metric] + ["x"] + row[metric + 1:], "short": row[:-1], "long": row + ["x"],
             "ratio": row[:dens] + ["1.%03d" % rng.randint(1, 999)] + row[dens + 1:]}
    flaw = rng.choice(sorted(flaws))
    measured = any(v != "-" for v in list(counts.values()) + list(ratios.values()))
    sums = tuple(str(int(counts[c]) if counts[c] != "-" else 0) for c in l.SUMMED)
    stamp = dt.datetime(2000, 1, 1) + dt.timedelta(seconds=rng.randint(0, 100 * 365 * 86400))
    run = stamp.strftime("%Y%m%dT%H%M%SZ") + "-%d" % rng.randint(1, 99999)
    spans = {"month": (4, 6, 13), "day": (6, 8, 32), "hour": (9, 11, 24), "minute": (11, 13, 60), "second": (13, 15, 60)}
    field = rng.choice(sorted(spans))
    lo, hi, first_bad = spans[field]
    values = ["%02d" % v for v in range(first_bad, 100)] + (["00"] if field in ("month", "day") else [])
    bad_run = rng.choice([run[:lo] + rng.choice(values) + run[hi:], run.split("-")[0]])
    entry = [("f.py", "pass", "python", None, "-")]
    pairs = [(outcome(lambda: l.window_start(None, good, now)), good + "T00:00:00Z"),
             (outcome(lambda: l.window_start(None, wrong, now)), "ValueError: --since %r: expected YYYY-MM-DD" % wrong),
             (outcome(lambda: l.window_start(days, None, now)), (now - dt.timedelta(days=days)).strftime("%Y-%m-%dT%H:%M:%SZ")
              if in_range else "ValueError: --days %d: expected 1-3650" % days),
             (counted(row), (1, 0, [(str(int(measured)), str(int(ratios["density"] != "-"))) + sums])),
             (counted(flaws[flaw]), (0, 1, [])),
             (outcome(lambda: l.format_rows(run, l.Origin("p", "-", "-", "sha1"), "t", entry, {})[0].split("\t")[:2]),
              [stamp.strftime("%Y-%m-%dT%H:%M:%SZ"), run]),
             (outcome(lambda: l.format_rows(bad_run, l.Origin("p", "-", "-", "sha1"), "t", entry, {})),
              "ValueError: run id %r is not yyyymmddTHHMMSSZ-pid" % bad_run)]
    bad += [(seed, case, got, want) for got, want in pairs if got != want]
print(bad[:1] or "ok %d cases" % cases)' "$SEED")" "ok 400 cases" "property (seed $SEED): generated --since days, --days counts, ledger rows with one flaw each and run ids are accepted or refused by class, with exact results"

# ── a missing or broken module, or an old git, is rc 2 and never a breach ───
fx fx_unb; copy_cli; rm -f "$COPY/zuvo_comment_ledger.py"
BIN="$COPY/comment-audit" audit --files s.py; errors_cleanly "cannot load its modules: ModuleNotFoundError" "a missing ledger module: rc 2 with one stderr line, no traceback"
fx fx_unb; copy_cli; printf '\nraise RuntimeError("broken\\x1b on import")\n' >> "$COPY/zuvo_comment_ledger.py"
BIN="$COPY/comment-audit" audit --files s.py; errors_cleanly 'cannot load its modules: RuntimeError: broken\x1b on import' "a module that raises on import: rc 2, no traceback, the control byte escaped"
fx fx_unb; copy_cli; printf '\nraise SystemExit(1)\n' >> "$COPY/zuvo_comment_rules.py"
BIN="$COPY/comment-audit" audit --files s.py; errors_cleanly "cannot load its modules: SystemExit: 1" "a module that exits 1 on import still exits 2"
fx fx_unb; copy_cli; sed -i.orig 's/^def escape(/def escape_gone(/' "$COPY/zuvo_comment_ledger.py"
BIN="$COPY/comment-audit" audit --files s.py; errors_cleanly "cannot load its modules: AttributeError" "a ledger module without escape fails inside the import guard: rc 2, no traceback"
sed "s#^REALGIT#exec $(command -v git)#" > "$TMP/shim/git" <<'SH'
#!/bin/sh
case " $* " in *" --show-object-format "*) echo "error: unknown option 'show-object-format'" >&2; exit 129 ;; esac
REALGIT "$@"
SH
chmod +x "$TMP/shim/git"
fx fx_unb; PATH="$TMP/shim:$PATH" audit --files s.py; runid
check "$rc|$(lq 'F("s.py")["blob"]')" "0|$(ho s.py)" "a git without --show-object-format: the audit still runs and hashes as sha1"

# ── end to end from the flat layout install.sh produces ─────────────────────
copy_cli; ZH="$COPY"
check "$(cd "$ZH" && ls | tr '\n' ' ')" "comment-audit zuvo_comment_ledger.py zuvo_comment_rules.py zuvo_comment_scan.py " "premise: the CLI and its three modules sit flat in one directory"
fx_e2e() { repo "$1" && put app.py 'import os\n' && commit; }
fx fx_e2e
put app.py 'import os\n\n# Checked on 2026-09-14 after the field report.\nTIMEOUT = 30\n\n\n# The loader reads the config path from the environment\n# because the service runs in containers that mount the\n# config at a path chosen at deploy time. Reading it here\n# keeps the module free of deploy details and lets tests\n# point it at a fixture without patching the module.\n# Keep this lookup at import time.\nCONFIG = os.environ.get("APP_CONFIG", "app.toml")\n'
BIN='env' audit -u ZUVO_COMMENT_AUDIT_LOG ZUVO_HOME="$ZH" "$ZH/comment-audit" --files app.py; runid
check "$rc|$(grep -c '^app.py:[0-9]* N N:app.py:' "$TMP/out") $(grep -c '^app.py:[0-9]* L L:app.py:' "$TMP/out")|$(last 2 | cut -d' ' -f1-3)|$(LEDGER="$ZH/comment-audit.log" lq 'F("app.py")["narrative"], F("app.py")["long"]')" \
  "1|1 1|RESULT: comment-pass BREACH|('1', '1')" "end to end: a dated narrative and a 6-line block over one line exit 1 with one N and one L, both in the ledger"
put app.py 'import os\n\nTIMEOUT = 30\n\n\n# Containers mount the config at a path chosen at deploy time.\nCONFIG = os.environ.get("APP_CONFIG", "app.toml")\n'
BIN='env' audit -u ZUVO_COMMENT_AUDIT_LOG ZUVO_HOME="$ZH" "$ZH/comment-audit" --files app.py
check "$rc|$(last 2 | cut -d' ' -f1-3)" "0|RESULT: comment-pass PASS" "end to end: history moved out and the block cut to the WHY exit 0"
BIN='env' audit -u ZUVO_COMMENT_AUDIT_LOG ZUVO_HOME="$ZH" "$ZH/comment-audit" --trend --days 1
check "$rc|$(rows_of "${R##*/}" | cut -d' ' -f1-3)|$(LEDGER="$ZH/comment-audit.log" lq 'len(R)')" "0|${R##*/} 2 2|2" "end to end: --trend --days 1 shows runs=2 for the project, read from \$ZUVO_HOME/comment-audit.log"

# ── the calling skill: first in notes, read back into Stat, grouped by --by skill ──
check "$(unit 'import io, zuvo_comment_ledger as l
o = l.Origin("p", "-", "-", "sha1")
named = l.format_rows("20260102T030405Z-1", o, "t", [("a.py", "n/a (too large)", "-", None, "-")], {}, "build")
plain = l.format_rows("20260102T030405Z-1", o, "t", [("a.py", "pass", "python", None, "-")], {})
verdicts = []
for name in ("Build", "a b", "x" * 41, "-x", "x" * 40):
    try:
        l.format_rows("20260102T030405Z-1", o, "t", [], {}, name); verdicts.append("ok")
    except ValueError:
        verdicts.append("refused")
print(named[0].split("\t")[-1], plain[0].split("\t")[-1], " ".join(verdicts), sep=" | ")')" \
  "skill=build|n/a (too large) | - | refused refused refused refused ok" \
  "format_rows puts skill=NAME first in notes, writes nothing without one, and refuses a name outside [a-z0-9][a-z0-9-]{0,39}"
check "$(unit 'import io, datetime as dt, zuvo_comment_ledger as l
o = l.Origin("p", "-", "-", "sha1")
rows = []
for run, skill in (("20260102T030405Z-1", "build"), ("20260102T030406Z-2", "build"), ("20260102T030407Z-3", "review"), ("20260102T030408Z-4", "")):
    rows += l.format_rows(run, o, "t", [("a.py", "pass", "python", None, "-")], {}, skill)
data = b"\n".join([l.SCHEMA.encode(), "\t".join(l.COLUMNS).encode()] + [r.encode() for r in rows]) + b"\n"
stats = [s.skill for _, s in l.read_rows(io.BytesIO(data))]
table, used, skipped = l.trend(l.read_rows(io.BytesIO(data)), "2026-01-01T00:00:00Z", None, "skill")
other = l.format_rows("20260102T030409Z-5", l.Origin("q", "-", "-", "sha1"), "t", [("b.py", "pass", "python", None, "-")], {}, "refactor")
both = data + other[0].encode() + b"\n"
only_p, used_p, _ = l.trend(l.read_rows(io.BytesIO(both)), "2026-01-01T00:00:00Z", "p", "skill")
print(stats, [(r[0], r[1]) for r in table], used, skipped, [(r[0], r[1]) for r in only_p], used_p)')" \
  "['build', 'build', 'review', ''] [('-', '1'), ('build', '2'), ('review', '1')] 4 0 [('-', '1'), ('build', '2'), ('review', '1')] 4" \
  "Stat.skill is read back from notes; trend by skill gives one row per skill (runs counted), '-' for none, and --project still filters"
check "$(unit 'import io, zuvo_comment_ledger as l
o = l.Origin("p", "-", "-", "sha1")
row = l.format_rows("20260102T030405Z-1", o, "t", [("j.py", "justified", "python", None, "-")], {}, "review")[0].split("\t")
moved = row[:-1] + ["N:j.py:0123abcd=a reason long enough|skill=execute"]
forged = row[:-1] + ["skill=Not A Name|n/a (too large)"]
data = b"\n".join([l.SCHEMA.encode(), "\t".join(l.COLUMNS).encode()] + ["\t".join(r).encode() for r in (row, moved, forged)]) + b"\n"
try:
    l.trend(iter(()), "2026-01-01T00:00:00Z", None, "team"); refused = "accepted"
except ValueError as exc:
    refused = str(exc)
print([s.skill for _, s in l.read_rows(io.BytesIO(data))], refused)')" "['review', '', ''] --by 'team': expected one of project, skill" \
  "Stat.skill is read only from the first note, where format_rows writes it (a later or malformed skill= reads as none), and trend() refuses an unknown by"
check "$(unit 'import datetime as dt, zuvo_comment_ledger as l
try:
    l.trend_report("/nonexistent/ledger", l.TrendOptions(1, None, None, False, "team"), dt.datetime(2026, 1, 2, tzinfo=dt.timezone.utc))
    print("accepted")
except ValueError as exc:
    print(exc)')" "--by 'team': expected one of project, skill" "trend_report refuses a --by other than project or skill"

finish
