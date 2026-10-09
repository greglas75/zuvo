#!/usr/bin/env bash
# Contract for scripts/zuvo-home/comment-audit: which lines a change authored, and what the exit code means.
# rc 1 sends an agent to rewrite comments, so a git or internal error must read as rc 2, never as 1. Every
# expected id is sha1 of the comment text computed here, every git fixture is a temp repo.
# Level: medium (Q20) — the CLI runs against hermetic git repositories under mktemp; no network, no sleep.
# Every case builds its own repository and ledger first, so any case runs alone. A git shim logs each call
# and fakes one reply per mode. The git timeouts run in-process with a timer that fires as it is armed.
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
check "$(head -1 "$CLI")|$(head -8 "$CLI" | grep -c "^''''exec .*command -v python3 || command -v python")" "#!/bin/sh|1" \
  "the polyglot header: #!/bin/sh, then one ''''exec line in the first 8 that finds python3 or python (what test-python-lint selects)"
for module in zuvo_comment_scan.py zuvo_comment_rules.py zuvo_comment_ledger.py; do
  if [ -f "$HELPERS/$module" ]; then pass "$module sits next to the CLI"; else bad "$module is missing"; finish; fi
done

for tool in python3 git perl; do command -v "$tool" >/dev/null 2>&1 || skip "$tool not available"; done
export PYTHONDONTWRITEBYTECODE=1 PYTHONIOENCODING=utf-8 PYTHONUTF8=1 PYTHONUNBUFFERED=1 LC_ALL=C LANG=C

TMP="$(mktemp -d)" && TMP="$(cd "$TMP" && pwd -P)" || { echo "FAIL: mktemp -d failed"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
# A shim child the CLI failed to kill stays blocked on the hang fifo; opening it for writing lets it exit.
cleanup() {
  perl -e 'use Fcntl; sysopen(my $fh, $ARGV[0], O_WRONLY | O_NONBLOCK) and close $fh' "$TMP/hang.fifo" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" ZUVO_COMMENT_AUDIT_LOG="$TMP/ledgers/none.log" GIT_CEILING_DIRECTORIES="$TMP"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_EXTERNAL_DIFF GIT_DIFF_OPTS ZUVO_HOME
unset ZUVO_COMMENT_MAX_DENSITY ZUVO_COMMENT_MIN_LINES ZUVO_COMMENT_BLOCK_MIN ZUVO_COMMENT_JUSTIFY_MAX
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$TMP/norepo" "$TMP/shim" "$TMP/nogit" "$TMP/ledgers" \
  && mkfifo "$TMP/hang.fifo" || { bad "cannot create the sandbox"; finish; }
LIMIT=120
sed -e "s#^REALGIT#exec $(command -v git)#" -e "s#GITBIN#$(command -v git)#" -e "s#HANGFIFO#$TMP/hang.fifo#" > "$TMP/shim/git" <<'SH'
#!/bin/sh
[ -n "${SHIMLOG:-}" ] && printf '%s\n' "$*" >> "$SHIMLOG"
fed() { while IFS= read -r req; do printf 'stdin %s\n' "$req" >> "$SHIMLOG"; [ "${1:-}" = all ] || break; done; }
case "${SHIM:-}: $* " in
  hang-diff:*" diff "*) exec cat "HANGFIFO" ;;
  junk:*" diff "*) printf 'diff --git a/x b/y\n'; exit 0 ;;
  badhunk:*" diff "*) printf 'diff --git a/e.py b/e.py\n@@ -1 +1 bogus @@\n'; exit 0 ;;
  hunkline:*" diff "*) printf 'diff --git a/e.py b/e.py\n@@ -1 +1 @@\n x = 1\n'; exit 0 ;;
  badquote:*" diff "*) printf 'diff --git "a/x\n'; exit 0 ;;
  short:*" --batch "*) fed; printf '%040d blob 100\nabc' 0; exit 0 ;;
  nonl:*" --batch "*) fed; printf '%040d blob 3\nabcd' 0; exit 0 ;;
  early:*" --batch "*) fed; printf '%040d blob 3000000\nabc' 0; exit 0 ;;
  garble:*" --batch "*) fed; printf 'nonsense\n'; exit 0 ;;
  tree:*" --batch "*) fed; printf '%040d tree 3\nabc\n' 0; exit 0 ;;
  count:*" --batch-check "*) fed all; printf '%040d blob 1\n%040d blob 1\n' 0 0; exit 0 ;;
  vanish:*" --others "*) rm -f vanish.py ;;
  todir:*" --others "*) rm -f vanish.py; mkdir vanish.py ;;
  tosock:*" --others "*) rm -f lk.py; python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' lk.py ;;
  sockafter:*" --others "*) GITBIN "$@"; rc=$?; rm -f out.py
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' out.py; exit "$rc" ;;
esac
REALGIT "$@"
SH
chmod +x "$TMP/shim/git"
# inproc.py OUTDIR CLI ARGS: the CLI's main() in this process. INPROC=timer swaps threading.Timer for one whose
# deadline has passed when it is armed; INPROC=count swaps it for one that never fires; INPROC=run makes every
# subprocess.run time out; INPROC=nostderr runs with sys.stderr set to None. Prints rc, the timers made, the
# git child each started timer was armed for, and the subprocess.run calls as JSON.
cat > "$TMP/inproc.py" <<'PY'
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import threading
import types

loader = importlib.machinery.SourceFileLoader("comment_audit", sys.argv[2])
cli = importlib.util.module_from_spec(importlib.util.spec_from_loader("comment_audit", loader))
sys.modules["comment_audit"] = cli
loader.exec_module(cli)
mode, timers, runs = os.environ.get("INPROC", ""), [], []


class FiringTimer:
    def __init__(self, interval, function):
        self.interval, self.function, self.daemon, self.started = interval, function, False, False
        timers.append(self)

    def start(self):
        self.started = True
        self.function()

    def cancel(self):
        return None


class CountingTimer(FiringTimer):
    def start(self):
        self.started = True


def timing_out(args, **kwargs):
    runs.append([args, sorted(kwargs), kwargs.get("timeout"), repr(kwargs.get("input"))])
    raise subprocess.TimeoutExpired(args, kwargs.get("timeout"))


if mode in ("timer", "count"):
    cli.threading = types.SimpleNamespace(Timer=FiringTimer if mode == "timer" else CountingTimer, Event=threading.Event)
if mode == "run":
    subprocess.run = timing_out
out, err = io.StringIO(), io.StringIO()
with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
    if mode == "nostderr":
        sys.stderr = None
    code = cli.main(sys.argv[3:])
for name, text in (("out", out.getvalue()), ("err", err.getvalue())):
    with open(os.path.join(sys.argv[1], name), "w", encoding="utf-8", errors="backslashreplace") as handle:
        handle.write(text)
print(json.dumps({"rc": code, "timers": [[t.interval, t.started] for t in timers], "runs": runs,
                  "armed": [" ".join(t.function.__self__.args) for t in timers if t.started],
                  "killed": [[" ".join(t.function.__self__.args), t.function.__self__.proc.returncode]
                             for t in timers if t.started]}))
PY

FIX="fixture setup failed"
n=0
repo()   { R="$TMP/$1"; export ZUVO_COMMENT_AUDIT_LOG="$TMP/ledgers/$1.log"; mkdir -p "$R" && git -C "$R" -c init.defaultBranch=main init -q; }
# fx BUILDER: a fresh repository (and ledger) under a new name, built by BUILDER; every case starts with one.
fx()     { n=$((n + 1)); "$1" "${1#fx_}-$n" || { bad "$FIX: $1"; finish; }; }
put()    { mkdir -p "$(dirname "$R/$1")" && printf '%b' "$2" > "$R/$1"; }
putb()   { python3 -c 'import sys; open(sys.argv[1], "wb").write(eval(sys.argv[2], {"__builtins__": {}}))' "$R/$1" "$2"; }
commit() { git -C "$R" add -A && git -C "$R" -c user.name=Test -c user.email=test@example.invalid \
             -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm "${1:-fixture}"; }
# copy_cli: the CLI and its modules copied to a new directory, named in $COPY.
copy_cli() { n=$((n + 1)); COPY="$TMP/copy-$n"; mkdir -p "$COPY" && cp "$CLI" "$HELPERS"/zuvo_comment_*.py "$COPY/" || { bad "$FIX: copy"; finish; }; }
bounded() { perl -e 'alarm shift; exec @ARGV' "$LIMIT" "$@"; }
# Every run happens under $TMP, is killed after $LIMIT s, and stores its exit code in $rc before anything else.
audit()  {
  local dir="${CWD:-$R}"
  case "$dir/" in "$TMP"/*) ;; *) bad "refusing to run the CLI outside \$TMP: $dir"; rc=99; return ;; esac
  ( cd "$dir" && bounded "${BIN:-$CLI}" "$@" ) > "$TMP/out" 2> "$TMP/err"; rc=$?
}
inproc() {
  ( cd "${CWD:-$R}" && INPROC="$1" bounded python3 "$TMP/inproc.py" "$TMP" "$CLI" "${@:2}" ) > "$TMP/report.json" 2> "$TMP/inproc.err"
  rc=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["rc"])' "$TMP/report.json" 2>/dev/null) \
    || rc="driver failed: $(head -c 300 "$TMP/inproc.err")"
}
report() { python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$TMP/report.json" "$1" 2>&1; }
# shimrun MODE ARGS: audit with git behind the shim in MODE; $TMP/shim.log holds each git argv and fed stdin.
shimrun() { : > "$TMP/shim.log"; SHIM="$1" SHIMLOG="$TMP/shim.log" PATH="$TMP/shim:$PATH" audit "${@:2}"; }
shimtail() { tail -n "$1" "$TMP/shim.log" | tr '\n' '|'; }
shimcount() { grep -cF -- "$1" "$TMP/shim.log"; }
shimexact() { grep -cxF -- "$1" "$TMP/shim.log"; }
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
  { [ "$rc" = 2 ] && [ "$(awk 'END { print NR }' "$TMP/err")" -eq 1 ]; } || ok=0
  case "$line" in *"$1"*) ;; *) ok=0 ;; esac
  case "$1|$line" in *"internal error"*"|"*) ;; *"|"*"internal error"*) ok=0 ;; esac
  if [ "$ok" -eq 1 ]; then pass "$2"; else bad "$2 — rc $rc, stderr: $(head -c 300 "$TMP/err")"; fi
}
HINT_N="move the history to the commit message or a runbook; keep only the current constraint"
HINT_L="cut to the WHY, or delete it if it restates the code"
DEFAULTS="density=0.30(default) min_lines=20(default) block=4(default) justify_max=2(default)"
DIFFARGS="-c core.quotePath=false diff -U0 --inter-hunk-context=0 --no-color --no-ext-diff --no-textconv --no-renames --diff-algorithm=myers --ignore-submodules=all --src-prefix=a/ --dst-prefix=b/"
BATCH="-c core.quotePath=false cat-file --batch"
OTHERS="-c core.quotePath=false ls-files -z --others --exclude-standard"
REASON="the line names a constraint this module keeps"
STALE="N:clean.py:deadbeef=a reason that is long enough to count"
ID="N:app.py:$(sha8 'previously the cache was global')"
BLOCK='# The cache was previously global; we changed it\n# to a per-request map because worker threads\n# shared one dict and raced on writes. Keep the\n# map local to the request.\nCACHE = {}\n'
H=$(sha8 "$(printf 'The cache was previously global; we changed it\nto a per-request map because worker threads\nshared one dict and raced on writes. Keep the\nmap local to the request.')")

# ── a clean file, a narrative comment, the machine lines, justification ──────
fx_basic() { repo "$1" && put app.py 'import os\n\n\ndef load(path):\n    return open(path).read()\n' && commit; }
fx_basic_clean() { fx_basic "$1" && put clean.py 'def add(a, b):\n    return a + b\n'; }
fx_basic_narr() { fx_basic "$1" && put app.py 'import os\n\n# previously the cache was global\ndef load(path):\n    return open(path).read()\n'; }
fx fx_basic_clean; audit --files clean.py; run=$(runid)
check "$rc|$(awk '$1=="clean.py" { print $2, $3, $4, $5, $6, $7, $8, $9, $10 }' "$TMP/out")" "0|python 2 0 - 0.000 0 0 0 pass" "a clean file: rc 0; 2 authored code lines, density not gated under 20 lines, whole-file 0.000"
printf '%s' "$run" | grep -Eq '^[0-9]{8}T[0-9]{6}Z-[0-9]+$' && pass "run id is <UTC yyyymmddTHHMMSSZ>-<pid>" || bad "run id [$run]"
check "$(tail -n 3 "$TMP/out" | tr '\n' '|')" "thresholds: $DEFAULTS|RESULT: comment-pass PASS run=$run files=1 findings=0 justified=0 degraded=0 unchanged=0|comment_pass: run=$run files=1 max_density=- narrative=0 long=0 density_breaches=0 claims=0 justified=0 verdict=pass degraded=0 unchanged=0|" "the last three lines are thresholds, RESULT and comment_pass, sharing one run id"
fx fx_basic_clean; audit --files clean.py --justify "$STALE"
check "$rc|$(grep -c '^WARN stale justification N:clean.py:deadbeef$' "$TMP/out")" "0|1" "a stale justification is a WARN line and leaves rc 0"
fx fx_basic_clean; audit --json --files clean.py --justify "$STALE"
check "$rc|$(j 'd["stale"], d["rejected"], d["justified"]')" "0|(['N:clean.py:deadbeef'], [], [])" "JSON lists a stale id under 'stale', not 'rejected'"
fx fx_basic_narr; audit --files app.py; run=$(runid)
rc_is 1 "an added '# previously ...' comment exits 1"
line_is "app.py:3 N $ID \"previously the cache was global\" -> $HINT_N [N-history]" "the finding line is 'path:line RULE ID \"text\" -> hint [sub]'"
check "$(tail -n 2 "$TMP/out" | tr '\n' '|')" "RESULT: comment-pass BREACH run=$run files=1 findings=1 justified=0 degraded=0 unchanged=0|comment_pass: run=$run files=1 max_density=- narrative=1 long=0 density_breaches=0 claims=0 justified=0 verdict=breach degraded=0 unchanged=0|" "RESULT says BREACH with one finding; comment_pass counts it"
fx fx_basic_narr; audit --files app.py --justify "$ID=the history explains why the cache is per request"; run=$(runid)
check "$rc|$(row app.py)" "0|justified" "an accepted --justify: rc 0, verdict 'justified'"
check "$(tail -n 2 "$TMP/out" | tr '\n' '|')" "RESULT: comment-pass PASS run=$run files=1 findings=1 justified=1 degraded=0 unchanged=0|comment_pass: run=$run files=1 max_density=- narrative=1 long=0 density_breaches=0 claims=0 justified=1 verdict=pass degraded=0 unchanged=0|" "both machine lines carry justified=1"
fx fx_basic_narr; audit --files app.py --justify "$ID=1234567890123456789"
check "$rc|$(row app.py)|$(grep -c "^REJECTED $ID (short)" "$TMP/out")" "1|breach|1" "a 19-character reason is rejected: rc 1, verdict breach"
fx fx_basic_narr; audit --files app.py --justify "no-separator-here"; errors_cleanly "expected ID=REASON" "a --justify without ID=REASON is rc 2"

# ── density: authored vs whole file, the D finding, env thresholds, claims, JSON shape ──
fx_dens() {
  local dfile="" k
  repo "$1" && put w.py 'v0 = 0\nv1 = 1\nv2 = 2\nv3 = 3\nv4 = 4\nv5 = 5\nv6 = 6\nv7 = 7\n' && commit || return 1
  put w.py 'v0 = 0\nv1 = 1\nv2 = 2\nv3 = 3\nv4 = 4\nv5 = 5\nv6 = 6\nv7 = 7\n# why: the order matters\n' || return 1
  for k in 1 2 3 4 5 6 7; do dfile="$dfile# step $k keeps order\nv$k = $k\n"; done
  for k in 1 2 3 4 5 6; do dfile="${dfile}w$k = $k\n"; done
  put d.py "$dfile" && put c.py '# gives up within 5 s\ntimeout = 5\n'
}
fx fx_dens; audit --files w.py
check "$rc|$(awk '$1=="w.py" { print $2, $3, $4, $5, $6, $10 }' "$TMP/out")" "0|python 0 1 - 0.111 pass" "whole-file density 1/9 is reported next to the ungated authored density"
fx fx_dens; audit --files d.py
rc_is 1 "7 comment lines of 20 authored (0.350 > 0.30) exit 1"
line_is 'd.py:1 D D:d.py "7 of 20 authored lines are comments" -> delete comments that restate the code [0.350>0.30]' "the D finding states the fraction"
check "$(last 1 | sed 's/run=[^ ]* //')" "comment_pass: files=1 max_density=0.350 narrative=0 long=0 density_breaches=1 claims=0 justified=0 verdict=breach degraded=0 unchanged=0" "comment_pass carries max_density and density_breaches"
fx fx_dens; ZUVO_COMMENT_MAX_DENSITY=0.9 audit --files d.py
rc_is 0 "ZUVO_COMMENT_MAX_DENSITY=0.9 lets 0.350 pass"
check "$(last 2 | sed 's/.* justified=0//')|$(last 1 | sed 's/.* verdict=pass//')" " env=ZUVO_COMMENT_MAX_DENSITY degraded=0 unchanged=0| env=ZUVO_COMMENT_MAX_DENSITY degraded=0 unchanged=0" "both machine lines carry env=ZUVO_COMMENT_MAX_DENSITY, then unchanged= last"
check "$(last 3)" "thresholds: density=0.90(env) min_lines=20(default) block=4(default) justify_max=2(default)" "the thresholds line marks the env source"
fx fx_dens; audit --files c.py
check "$rc|$(grep -c '^CHECK c.py:1 "gives up within 5 s"$' "$TMP/out")" "0|1" "a quantitative claim is a CHECK line and never changes the exit code"
check "$(last 1 | sed 's/run=[^ ]* //')" "comment_pass: files=1 max_density=- narrative=0 long=0 density_breaches=0 claims=1 justified=0 verdict=pass degraded=0 unchanged=0" "comment_pass counts the claim"
fx fx_dens; audit --json --files d.py c.py
check "$rc|$(j 'sorted(d)')" "1|['base', 'files', 'justified', 'range', 'rc', 'rejected', 'retro_line', 'run', 'stale', 'thresholds', 'verdict']" "--json keeps rc and prints one object with the R8 keys and 'stale'"
check "$rc|$(j 'sorted(F("d.py")), sorted(F("d.py")["findings"][0]), sorted(F("c.py")["claims"][0])')" "1|(['authored_code', 'authored_comment', 'carried', 'claims', 'degraded', 'density', 'file_density', 'findings', 'lang', 'path', 'verdict'], ['hint', 'id', 'line', 'rule', 'sub', 'text'], ['line', 'text'])" "file, finding and claim objects have the R8 keys"
check "$rc|$(j 'sorted((k, sorted(v), v["source"]) for k, v in d["thresholds"].items())')" "1|[('block', ['source', 'value'], 'default'), ('density', ['source', 'value'], 'default'), ('justify_max', ['source', 'value'], 'default'), ('min_lines', ['source', 'value'], 'default')]" "thresholds carry value and source"
check "$rc|$(j 'd["rc"], d["verdict"], d["base"], d["range"], F("d.py")["density"], F("c.py")["claims"][0]["line"]')" "1|(1, 'breach', 'HEAD', None, 0.35, 1)" "rc, verdict, base, range, density and the claim line in JSON"
check "$rc|$(j 'd["retro_line"].startswith("comment_pass: run=" + d["run"] + " files=2 ")')|$(grep -c '^RESULT:' "$TMP/out")" "1|True|0" "retro_line is this run's comment_pass line; --json prints no RESULT line"
fx fx_dens; audit --json --files w.py
check "$rc|$(j 'round(F("w.py")["file_density"], 3), F("w.py")["density"]')" "0|(0.111, None)" "JSON carries file_density and an ungated density as null"

# ── carried lines: the removed pool is the WHOLE diff, untracked files and renames included ──
fx_move_copy() { repo "$1" && put a.py "import sys\n\n$BLOCK" && commit && put b.py "import sys\n\n$BLOCK"; }
fx_move_moved() { fx_move_copy "$1" && put a.py 'import sys\n'; }
fx_move_twice() { fx_move_moved "$1" && put c.py "import sys\n\n$BLOCK"; }
fx_move_staged() { fx_move_moved "$1" && git -C "$R" add b.py; }
fx_tmove_copy() { repo "$1" && put a.py "import sys\n\n$BLOCK" && put t.py 't0 = 0\nt1 = 1\n' && commit && put t.py "t0 = 0\n${BLOCK}t1 = 1\n"; }
fx_tmove_moved() { fx_tmove_copy "$1" && put a.py 'import sys\n'; }
fx_ren() { repo "$1" && put a.py "import sys\n\n$BLOCK" && commit && git -C "$R" mv a.py b.py && printf 'extra = 1\n' >> "$R/b.py"; }
fx fx_move_copy; audit --files b.py
rc_is 1 "premise: the copied block is authored while a.py still has it"
line_is "b.py:3 N N:b.py:$H \"The cache was previously global; we changed it\" -> $HINT_N [N-history]" "premise: the block is narrative"
line_is "b.py:3 L L:b.py:$H \"The cache was previously global; we changed it\" -> $HINT_L [4>1]" "premise: 4 comment lines over 1 line of code"
fx fx_move_moved; audit --files b.py; rc_is 0 "moved a.py -> untracked b.py with --files b.py: carried, rc 0"
fx fx_move_twice; audit --files c.py; rc_is 1 "a second copy is authored: one removed line carries one added line, whatever --files lists"
fx fx_move_twice; audit --files b.py; rc_is 0 "the first copy in path order stays carried when a second copy exists"
fx fx_move_staged; audit --files b.py; rc_is 0 "moved a.py -> staged b.py with --files b.py: carried, rc 0"
fx fx_tmove_copy; audit --files t.py; rc_is 1 "premise: a block inserted into a file tracked at HEAD is authored while a.py keeps it"
fx fx_tmove_moved; audit --files t.py; rc_is 0 "a block moved into the middle of a tracked file is carried at its hunk offset"
fx fx_ren; audit --json --files a.py b.py
check "$rc|$(j '[(f["path"], f["verdict"], f["carried"], f["authored_code"]) for f in d["files"]]')" "0|[('a.py', 'deleted', None, None), ('b.py', 'pass', 6, 1)]" "git mv + edit: renames off, a.py deleted, b.py carries 6 lines"

# ── --base HEAD: staged, unstaged and untracked are all audited ──────────────
HS="N:s.py:$(sha8 'previously s')"; HU="N:u.py:$(sha8 'previously u')"; HN="N:n.py:$(sha8 'previously n')"
fx_states() {
  repo "$1" && put s.py 'x = 1\n' && put u.py 'y = 2\n' && commit && put s.py 'x = 1\n# previously s\n' \
    && git -C "$R" add s.py && put u.py 'y = 2\n# previously u\n' && put n.py '# previously n\nz = 3\n'
}
fx_unborn() { repo "$1" && put staged.py '# previously a\nq = 1\n' && git -C "$R" add staged.py && put loose.py 'w = 2\n'; }
fx_brokenhead() { repo "$1" && put x.py 'x = 1\n' && commit && printf '1111111111111111111111111111111111111111\n' > "$R/.git/HEAD"; }
fx fx_states; audit
rc_is 1 "without --files the whole working tree is audited"
has "s.py:2 N $HS \"" "a staged-only change is audited"
has "u.py:2 N $HU \"" "an unstaged-only change is audited"
has "n.py:1 N $HN \"" "an untracked file is audited as fully added"
check "$(last 2 | sed 's/run=[^ ]* //')" "RESULT: comment-pass BREACH files=3 findings=3 justified=0 degraded=0 unchanged=0" "three files, three findings"
fx fx_states; audit --justify "$HN=$REASON" --justify "$HS=$REASON" --justify "$HU=$REASON"
check "$rc|$(last 2 | sed 's/run=[^ ]* //')|$(grep -c "^REJECTED $HU (over-cap)" "$TMP/out")" "1|RESULT: comment-pass BREACH files=3 findings=3 justified=2 degraded=0 unchanged=0|1" "cap 2: the first two justifications in argument order count, the third is rejected, rc 1"
fx fx_unborn; mkfifo "$R.release" || { bad "$FIX: stdin fifo"; finish; }
audit --json --files staged.py loose.py < <(IFS= read -r _ < "$R.release")
bounded sh -c 'printf "go\n" > "$1"' sh "$R.release"
check "$rc|$(vj)|$(j 'F("staged.py")["findings"][0]["id"]')" "1|breach|pass|N:staged.py:$(sha8 'previously a')" "unborn HEAD: audited against the empty tree while the CLI's stdin stays open and never reaches EOF"
fx fx_brokenhead; audit --files x.py; errors_cleanly "unknown revision 'HEAD'" "a detached HEAD naming a missing commit is rc 2, not an empty-tree audit"

# ── --range A..B reads B:, never the working tree; any --base commit works ───
fx_range() {  # commit A has f.py and g.py; commit B adds a comment to f.py and drops g.py; sets $A and $B
  repo "$1" && put f.py 'v = 1\n' && put g.py 'k = 0\n' && commit A && A=$(git -C "$R" rev-parse HEAD) \
    && put f.py 'v = 1\n# previously v was 2\n' && rm -f "$R/g.py" && commit B && B=$(git -C "$R" rev-parse HEAD)
}
fx_range_dropped() { fx_range "$1" && put f.py 'v = 1\n'; }
fx_range_c() { fx_range "$1" && putb big.py 'b"x = 1\n" * 349525 + b"#\n\n"' && ln -s f.py "$R/ln.py" && commit C && C=$(git -C "$R" rev-parse HEAD); }
fx_range_dir() { fx_range "$1" && put d/h.py 'h = 1\n' && commit D && D=$(git -C "$R" rev-parse HEAD) && rm -f "$R/d/h.py" && rmdir "$R/d"; }
fx_nlrange() {
  repo "$1" && python3 -c 'import sys; open(sys.argv[1] + "/n\nl.py", "w").write("a = 1\n")' "$R" && commit A && A=$(git -C "$R" rev-parse HEAD) \
    && python3 -c 'import sys; open(sys.argv[1] + "/n\nl.py", "a").write("b = 2\n")' "$R" && commit B && B=$(git -C "$R" rev-parse HEAD)
}
fx fx_range_dropped; audit --json --range "$A..$B" --files f.py g.py
check "$rc|$(j '[f["verdict"] for f in d["files"]], F("f.py")["findings"][0]["id"], d["base"], d["range"]')" "1|(['breach', 'deleted'], 'N:f.py:$(sha8 'previously v was 2')', None, '$A..$B')" "--range reads B: after the working tree dropped the comment; g.py deleted"
fx fx_range_dropped; audit --files f.py; rc_is 0 "--base HEAD sees only the removal in the working tree"
fx fx_range; audit --base "$A" --files f.py; rc_is 1 "--base <older sha> audits everything since that commit"
fx fx_range; audit --json --files f.py; check "$rc|$(vj)" "0|unchanged" "the same file against HEAD is unchanged"
WARN_F="WARN unchanged f.py: base wrong or file not changed by this run"
fx fx_range; audit --files f.py
check "$rc|$(tail -n 2 "$TMP/out" | sed 's/run=[^ ]* //' | tr '\n' '|')|$(grep -cxF "$WARN_F" "$TMP/out")" \
  "0|RESULT: comment-pass N/A files=1 findings=0 justified=0 degraded=0 unchanged=1|comment_pass: files=1 max_density=- narrative=0 long=0 density_breaches=0 claims=0 justified=0 verdict=n/a degraded=0 unchanged=1||1" \
  "an unchanged-only scope (a wrong base) is N/A with unchanged=1 last on both machine lines and a WARN naming the path"
fx fx_basic_clean; audit --files clean.py app.py
check "$rc|$(last 2 | cut -d' ' -f1-3)|$(last 2 | sed 's/.* //')|$(last 1 | sed 's/.* //')|$(grep -c '^WARN unchanged ' "$TMP/out")|$(grep -cxF 'WARN unchanged app.py: base wrong or file not changed by this run' "$TMP/out")" \
  "0|RESULT: comment-pass PASS|unchanged=1|unchanged=1|1|1" "a changed and an unchanged file: PASS, unchanged=1 last on both lines, one WARN, for the unchanged path"
fx fx_range_c; check "$(git -C "$R" cat-file -s "$C:big.py")" "2097153" "premise: the committed big.py is 2 MB + 1 byte"
audit --json --range "$B..$C" --files big.py ln.py
check "$rc|$(vj)" "0|n/a (too large)|n/a (symlink)" "--range: a blob over 2 MB is n/a (too large), a symlink blob n/a (symlink)"
fx fx_range; shimrun short --range "$A..$B" --files f.py; errors_cleanly "git cat-file returned 3 of 101 bytes for f.py" "a short cat-file reply is rc 2, never a cut post-image"
check "$(shimexact "$BATCH")|$(shimtail 2)" "1|$BATCH|stdin $B:f.py|" "the shim saw one 'cat-file --batch' asked for B:f.py, and no git call after it"
fx fx_range; shimrun nonl --range "$A..$B" --files f.py; errors_cleanly "git cat-file returned 4 of 4 bytes for f.py" "a reply of the right length without its closing newline is rc 2"
check "$(shimexact "$BATCH")|$(shimtail 2)" "1|$BATCH|stdin $B:f.py|" "the newline-less reply came from the one batch call for B:f.py"
fx fx_range; shimrun early --range "$A..$B" --files f.py; errors_cleanly "git cat-file: f.py ended early" "a too-large blob whose bytes stop before its size is rc 2"
check "$(shimexact "$BATCH")|$(shimtail 2)" "1|$BATCH|stdin $B:f.py|" "the early end came from the one batch call for B:f.py"
fx fx_range; shimrun garble --range "$A..$B" --files f.py; errors_cleanly "git cat-file: f.py in ${B:0:7}: unexpected reply b'nonsense'" "a reply line that is no cat-file header is rc 2 and quoted"
check "$(shimexact "$BATCH")|$(shimtail 2)" "1|$BATCH|stdin $B:f.py|" "the garbled reply came from the one batch call for B:f.py"
fx fx_range; shimrun tree --json --range "$A..$B" --files f.py; check "$rc|$(vj)" "0|n/a (not a file: tree)" "a post-image that cat-file calls a tree is n/a (not a file: tree), rc 0"
check "$(shimexact "$BATCH")|$(shimtail 2)" "1|$BATCH|stdin $B:f.py|" "the tree reply came from the one batch call for B:f.py"
fx fx_range_c; shimrun count --range "$B..$C" --files f.py; errors_cleanly "2 replies for 1 paths" "a batch-check reply count that differs from the request is rc 2"
check "$(shimcount 'cat-file --batch-check')|$(shimtail 2)" "1|-c core.quotePath=false cat-file --batch-check|stdin $C:f.py|" "the shim saw one 'cat-file --batch-check' asked for C:f.py only, and no git call after it"
fx fx_range; audit --range "$A..$B" --files $'v\rt.py'; errors_cleanly 'v\x0dt.py in '"${B:0:7}"': missing' "a missing path holding a carriage return is one reply, not two"
for spec in "@A:expected A..B" "@A...@B:expected A..B" "..@B:expected A..B" "@A..:expected A..B" "nope..@B:unknown revision 'nope'"; do
  fx fx_range; given=${spec%%:*}; given=${given//@A/$A}; given=${given//@B/$B}
  audit --range "$given" --files f.py; errors_cleanly "${spec#*:}" "--range '${spec%%:*}' is rc 2 naming the cause"
done
fx fx_range; audit --base '' --files f.py; errors_cleanly "unknown revision ''" "--base '' is rc 2"
fx fx_range; audit --base=-x --files f.py; errors_cleanly "unknown revision '-x'" "--base=-x is rc 2, never a git option"
fx fx_range; audit --range "$A..$B" --files ghost.py; errors_cleanly "ghost.py in ${B:0:7}: missing" "a path missing from B is rc 2"
fx fx_range; audit --range "$A..$B" --files 'x blob'; errors_cleanly "x blob in ${B:0:7}: missing" "a missing path that looks like 'x blob' is rc 2"
EMPTY=$(git -C "$TMP/norepo" hash-object -t tree /dev/null)
fx fx_range; audit --json --range "$EMPTY..$B" --files f.py; run=$(j 'd["run"]')
check "$rc|$(j 'F("f.py")["verdict"], F("f.py")["authored_code"], F("f.py")["authored_comment"], d["range"]')|$(awk -F'\t' -v r="$run" '$2 == r { print $5 }' "$ZUVO_COMMENT_AUDIT_LOG")" "1|('breach', 1, 1, '$EMPTY..$B')|${EMPTY:0:7}" "--range <empty tree>..B audits every line of B as added; the ledger's base7 is the tree id"
fx fx_range; audit --json --base "$EMPTY" --files f.py
check "$rc|$(j 'F("f.py")["verdict"], F("f.py")["authored_code"], F("f.py")["authored_comment"], d["base"]')" "1|('breach', 1, 1, '$EMPTY')" "--base <empty tree> audits the whole working-tree file as added"
fx fx_range; audit --range "$B..$EMPTY" --files f.py; errors_cleanly "'$EMPTY' is a tree; the B of --range A..B must be a commit" "a tree as the B of --range is rc 2 naming why"
fx fx_range_dir; audit --range "$A..$D" --files d; errors_cleanly "git cat-file: d in ${D:0:7}: not a file" "a listed path that is a directory in B and absent from the working tree is rc 2"
fx fx_nlrange; audit --json --range "$A..$B"
check "$rc|$(j '[(f["path"], f["verdict"]) for f in d["files"]]')|$(wc -c < "$TMP/err" | tr -d ' ')" \
  "0|[('n\\nl.py', 'n/a (newline in path)')]|0" \
  "--range: a changed path holding a newline (git cat-file reads one name per line) is a row of its own, n/a (newline in path), not rc 2"
fx_nlquiet() {  # q<LF>l.py is the same in A and B; B adds a comment to f.py
  repo "$1" && put f.py 'v = 1\n' && python3 -c 'import sys; open(sys.argv[1] + "/q\nl.py", "w").write("q = 1\n")' "$R" \
    && commit A && A=$(git -C "$R" rev-parse HEAD) && put f.py 'v = 1\n# previously v was 2\n' && commit B && B=$(git -C "$R" rev-parse HEAD)
}
fx fx_nlquiet; audit --json --range "$A..$B" --files f.py "$(printf 'q\nl.py')"
check "$rc|$(j '[(f["path"], f["verdict"]) for f in d["files"]]')|$(wc -c < "$TMP/err" | tr -d ' ')" \
  "1|[('f.py', 'breach'), ('q\\nl.py', 'n/a (newline in path)')]|0" \
  "--range: an UNCHANGED listed path holding a newline is n/a (newline in path), and the rest of the run is still audited"

# ── paths: cwd-relative, absolute, unchanged, deleted, ignored, fifo, empty, invalid ──
fx_sub() { repo "$1" && put pkg/m.py 'k = 1\n' && commit && put pkg/m.py 'k = 1\n# previously k\n'; }
fx_ud() {
  repo "$1" && put keep.py 'a = 1\n' && put gone.py 'b = 2\n' && put .gitignore 'ign.py\n' && commit && rm -f "$R/gone.py" \
    && put ign.py '# previously ignored\n' && : > "$R/zero.py" && put br.py '# previously b\n' && put jf.py '# previously j\n' && mkfifo "$R/fifo.py"
}
fx_empty() { repo "$1" && put e.py 'e = 1\n' && commit && mkdir -p "$R/nest" && git -C "$R/nest" init -q && put nest/n.py '# previously n\n'; }
fx fx_sub; CWD="$R/pkg" audit --files m.py
has "pkg/m.py:2 N N:pkg/m.py:$(sha8 'previously k') \"" "--files is relative to the current directory, ids to the repo root"
fx fx_sub; CWD="$R/pkg" audit --files "$R/pkg/m.py"; has "pkg/m.py:2 N N:pkg/m.py:" "an absolute --files path inside the repo is accepted"
fx fx_sub; CWD="$R/pkg" audit --files ../../outside.py; errors_cleanly "outside the repository" "a path outside the repository is rc 2"
fx fx_sub; CWD="$R/pkg" audit --files .; errors_cleanly "is a directory" "a directory in --files is rc 2"
fx fx_sub; audit --files ghost.py; errors_cleanly "no such file" "a missing untracked path is rc 2"
fx fx_ud; audit --json --files keep.py gone.py ign.py fifo.py zero.py br.py jf.py --justify "N:jf.py:$(sha8 'previously j')=$REASON"
check "$rc|$(vj)|$(j 'all(re.fullmatch(r"pass|breach|justified|unchanged|deleted|n/a( [(].+[)])?", f["verdict"]) for f in d["files"])')" "1|unchanged|deleted|n/a (ignored)|n/a (not a regular file)|pass|breach|justified|True" "every verdict kind in one run, each one of pass|breach|justified|unchanged|deleted|n/a[ (reason)]"
fx fx_ud; audit --json --files keep.py gone.py ign.py; check "$rc|$(j 'd["verdict"]')" "0|n/a" "nothing evaluated reads n/a"
fx fx_empty; audit; check "$rc|$(last 2 | sed 's/run=[^ ]* //')" "0|RESULT: comment-pass N/A files=0 findings=0 justified=0 degraded=0 unchanged=0" "a clean tree with a nested repo in an untracked dir is N/A, rc 0"

# ── errors are rc 2 with one stderr line naming the cause, never rc 1 ────────
fx_errs() {
  repo "$1" && put e.py 'e = 1\n' && put lk.py 'x = 1\n' && commit && put e.py 'e = 1\n# previously e\n' && put vanish.py 'v = 1\n' \
    && git -C "$R" add vanish.py && put vanish.py 'v = 1\n# previously v\n' && HEADSHA=$(git -C "$R" rev-parse HEAD)
}
fx_errs_todir() { fx_errs "$1" && put vanish.py 'v = 2\n'; }
fx_errs_sock() { fx_errs "$1" && put lk.py 'x = 2\n'; }
fx_budget_kept() {
  repo "$1" && put k.py 'a = 1\nb = 2\n' && commit && put a.py 'aaaa = 1\nbbbb = 2\n' && put u.py '# previously u\nc = 3\n' \
    && put w.py '# previously w\nw = 1234567890123456789\n' && put z.py '# z\nz = 1234567890123456789012345678\n'
}
fx_budget_cut() { fx_budget_kept "$1" && put k.py 'a = 1\n'; }
# A removed line makes untracked files compete for the pool; the sockafter shim turns out.py into a socket after listing it.
fx_sockpool() { repo "$1" && put k.py 'a = 1\nb = 2\n' && commit && put k.py 'a = 1\n' && put u.py '# previously u\nc = 3\n' && put out.py 'b = 2\n'; }
fx_pool() { repo "$1" && put k.py 'a = 1\nb = 2\nc = 3\n' && commit && put k.py 'a = 1\nx = 9\n' && put m.py 'b = 2\nq = 1\n  c   =  3\n'; }
diff_last() { check "$(shimcount ' diff ')|$(shimtail 1)" "1|$DIFFARGS $HEADSHA --|" "$1"; }
CWD="$TMP/norepo" audit --files x.py; errors_cleanly "not a git repository" "outside a repository: rc 2 with git's own reason"
fx fx_errs; audit --base nosuchref --files e.py; errors_cleanly "unknown revision 'nosuchref'" "an unknown --base ref is rc 2"
fx fx_errs; audit --base HEAD --range HEAD..HEAD; errors_cleanly "not allowed with argument" "--base with --range is rc 2"
fx fx_errs; ZUVO_COMMENT_MAX_DENSITY=abc audit --files e.py; errors_cleanly "ZUVO_COMMENT_MAX_DENSITY" "an invalid ZUVO_COMMENT_MAX_DENSITY is rc 2"
fx fx_errs; ZUVO_COMMENT_MIN_LINES=0 audit --files e.py; errors_cleanly "ZUVO_COMMENT_MIN_LINES" "ZUVO_COMMENT_MIN_LINES=0 is rc 2"
fx fx_errs; audit --bogus; errors_cleanly "unrecognized arguments" "an unknown option is rc 2"
check "$(perl -e 'close STDERR; exec @ARGV' python3 -c 'import sys; print(sys.stderr is None)')" "True" "premise: python started with fd 2 closed (perl closes it right before exec) has sys.stderr None"
fx fx_errs; ( cd "$R" && perl -e 'alarm shift; close STDERR; exec @ARGV' "$LIMIT" "$CLI" --bogus ) > "$TMP/out"; rc=$?
check "$rc|$(wc -c < "$TMP/out" | tr -d ' ')" "2|0" "sys.stderr is None (fd 2 closed at exec): an error exits exactly 2 and writes nothing to stdout"
fx fx_errs; inproc nostderr --bogus
check "$rc|$(wc -c < "$TMP/out" | tr -d ' ')|$(wc -c < "$TMP/err" | tr -d ' ')|$(wc -c < "$TMP/inproc.err" | tr -d ' ')" "2|0|0|0" "main() with sys.stderr None returns exactly 2 for an error, raises nothing and writes nothing anywhere"
fx fx_errs; check "$(CWD="$TMP/norepo" closed err --files x.py)" "2 0 False" "an error with stderr on a dead pipe still exits 2 and writes nothing to stdout"
check "$(perl -e 'close STDOUT; exec @ARGV' python3 -c 'import sys; sys.stderr.write(str(sys.stdout is None))' 2>&1)" "True" "premise: python started with fd 1 closed (perl closes it right before exec) has sys.stdout None"
fx fx_basic_narr; ( cd "$R" && perl -e 'alarm shift; close STDOUT; exec @ARGV' "$LIMIT" "$CLI" --files app.py ) 2> "$TMP/err"; rc=$?
check "$rc|$(wc -c < "$TMP/err" | tr -d ' ')|$(awk -F'\t' '$6 == "app.py" { n++ } END { print n + 0 }' "$ZUVO_COMMENT_AUDIT_LOG")" "1|0|1" \
  "sys.stdout is None (fd 1 closed at exec): the report is dropped, rc stays the breach's 1, stderr stays empty, the ledger row is written"
ln -s "$(command -v python3)" "$TMP/nogit/python3" && ln -s "$(command -v perl)" "$TMP/nogit/perl" || { bad "$FIX: nogit"; finish; }
fx fx_errs; PATH="$TMP/nogit" audit --files e.py; errors_cleanly "cannot run git" "git missing from PATH is rc 2"
fx fx_basic_narr; GIT_DIR="$TMP/nowhere" GIT_WORK_TREE="$TMP/nowhere" GIT_INDEX_FILE="$TMP/nowhere/index" \
  GIT_OBJECT_DIRECTORY="$TMP/nowhere/objects" audit --files app.py
check "$rc|$(row app.py)|$(wc -c < "$TMP/err" | tr -d ' ')" "1|breach|0" \
  "an inherited GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE or GIT_OBJECT_DIRECTORY is ignored: the audit is of the repository cwd is in"
fx fx_errs; shimrun junk --files e.py; errors_cleanly "unexpected header" "a diff git cannot have written is rc 2"
check "$(shimcount ' diff ')|$(shimtail 1)|$(shimcount 'ls-files')" "1|$DIFFARGS $HEADSHA --||0" "the diff the shim answered was asked with the fixed flags against HEAD, and the error stopped the run before ls-files"
fx fx_errs; shimrun badhunk --files e.py; errors_cleanly "git diff: unexpected hunk header in e.py" "a hunk header git cannot have written is rc 2 naming the file"
diff_last "the bad hunk header came from the one diff call, the last git call of its run"
fx fx_errs; shimrun hunkline --files e.py; errors_cleanly "git diff: unexpected line in a hunk of e.py" "a context line inside a -U0 hunk is rc 2 naming the file"
diff_last "the stray context line came from the one diff call, the last git call of its run"
fx fx_errs; shimrun badquote --files e.py; errors_cleanly "git diff: cannot read the quoted path b'\"a/x'" "an unterminated C-quoted path is rc 2 and quoted"
diff_last "the unterminated quote came from the one diff call, the last git call of its run"
fx fx_errs; copy_cli; printf '\n\ndef evaluate(view, thresholds):\n    raise RuntimeError("forced internal error")\n' >> "$COPY/zuvo_comment_rules.py"
BIN="$COPY/comment-audit" audit --files e.py; errors_cleanly "internal error: RuntimeError: forced internal error" "an internal exception is rc 2, never rc 1"
fx fx_errs; copy_cli; printf '\n\ndef evaluate(view, thresholds):\n    raise SystemExit(1)\n' >> "$COPY/zuvo_comment_rules.py"
BIN="$COPY/comment-audit" audit --files e.py; errors_cleanly "internal error: unexpected exit 1" "a SystemExit(1) inside the audit is rc 2, never rc 1"
fx fx_errs; SHIM=hang-diff PATH="$TMP/shim:$PATH" inproc timer --files e.py
errors_cleanly "git diff timed out after 600 s" "a streaming git child that hangs is killed when its GIT_TIMEOUT timer fires: rc 2"
check "$(report 'd["timers"], d["killed"]')" "([[0, False], [600, True]], [['${DIFFARGS#-c core.quotePath=false } $HEADSHA --', -9]])" "the diff child's timer is armed for 600 s, and firing it SIGKILLs that diff child, the only one armed"
fx fx_range_c; inproc count --range "$B..$C" --files big.py
check "$(report 'd["rc"], d["armed"].count("cat-file --batch")')" "(0, 5)" \
  "draining a 2 MB + 1 blob re-arms the cat-file timer per 1 MB chunk: once at start, once for the blob, 3 chunks"
fx fx_errs; inproc run --files e.py
errors_cleanly "git rev-parse timed out after 600 s" "a git call that times out is rc 2 naming the call and GIT_TIMEOUT"
check "$(report 'd["runs"]')" "[[['git', '-c', 'core.quotePath=false', 'rev-parse', '--show-toplevel'], ['capture_output', 'cwd', 'env', 'input', 'timeout'], 600, \"b''\"]]" "the timed-out call was the first, rev-parse --show-toplevel with timeout 600 and empty stdin, and the only one"
fx fx_errs; shimrun vanish --json --files vanish.py; check "$rc|$(vj)" "0|deleted" "a file gone between the diff and the read is 'deleted'"
check "$(shimexact "$OTHERS")|$(shimcount ' diff ')" "1|1" "the shim removed the file at the one untracked listing, after the one diff"
fx fx_errs_todir; shimrun todir --json --files vanish.py; check "$rc|$(vj)" "0|n/a (not a regular file)" "a directory swapped in before the read is n/a (not a regular file)"
check "$(shimexact "$OTHERS")" "1" "the directory was swapped in at the one untracked listing"
SOCKERR=$(cd "$TMP" && python3 -c 'import os, socket
socket.socket(socket.AF_UNIX).bind("probe.sock")
try:
    os.open("probe.sock", os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    print("opened")
except OSError as exc:
    print(exc.strerror)' 2>&1)
fx fx_errs_sock; shimrun tosock --files lk.py; errors_cleanly "lk.py: $SOCKERR" "a file open(2) refuses (a socket swapped in after the diff) is rc 2 naming the path and the errno text"
check "$([ -n "$SOCKERR" ] && [ "$SOCKERR" != opened ] && echo refused)|$(shimexact "$OTHERS")" "refused|1" "premise: the probe could not open a socket either, and the swap happened at the one untracked listing"
NOTE_OUT="NOTE skipped unreadable out.py: $SOCKERR"
fx fx_sockpool; shimrun sockafter --files u.py
check "$rc|$(row u.py)|$(grep -cxF "$NOTE_OUT" "$TMP/out")|$(wc -c < "$TMP/err" | tr -d ' ')|$(shimexact "$OTHERS")" "1|breach|1|0|1" \
  "an untracked file outside --files that turns unreadable (a socket after the listing) is skipped with a NOTE: rc is the findings' 1, not 2"
fx fx_sockpool; shimrun sockafter
check "$rc|$(grep -c '^out\.py .* n/a (unreadable)$' "$TMP/out")|$(grep -cxF "$NOTE_OUT" "$TMP/out")|$(wc -c < "$TMP/err" | tr -d ' ')" "1|1|1|0" \
  "without --files an unreadable untracked file is n/a (unreadable) with one NOTE across the pool read and the audit read: rc 1, not 2"
fx fx_sockpool; shimrun sockafter --files u.py out.py; errors_cleanly "out.py: $SOCKERR" "a listed untracked file that cannot be read is still rc 2"
fx fx_budget_kept; copy_cli; sed -i.orig 's/^UNTRACKED_BUDGET = 64 \* 1024 \* 1024$/UNTRACKED_BUDGET = 30/' "$COPY/comment-audit"
BIN="$COPY/comment-audit" audit --files u.py w.py
check "$rc|$(row u.py) $(row w.py)|$(grep -c '^NOTE' "$TMP/out")|$(grep -c '^UNTRACKED_BUDGET = 30$' "$COPY/comment-audit")" "1|breach breach|0|1" "with nothing removed no untracked file is read for the pool, and no NOTE is printed"
fx fx_budget_cut; copy_cli; sed -i.orig 's/^UNTRACKED_BUDGET = 64 \* 1024 \* 1024$/UNTRACKED_BUDGET = 30/' "$COPY/comment-audit"
BIN="$COPY/comment-audit" audit --files u.py w.py
check "$rc|$(row u.py) $(row w.py)|$(last 4)" "1|breach breach|NOTE carried pool truncated: 1 untracked files not searched for carried lines (budget)" "a 30-byte budget: listed u.py (21) and w.py (39) are audited; unlisted a.py (18) fits, z.py (37) is a NOTE"
fx fx_budget_cut; copy_cli; sed -i.orig 's/^UNTRACKED_BUDGET = 64 \* 1024 \* 1024$/UNTRACKED_BUDGET = 30/' "$COPY/comment-audit"
BIN="$COPY/comment-audit" audit
check "$rc|$(row a.py) $(row u.py) $(row w.py) $(row z.py)|$(grep -c '^NOTE' "$TMP/out")|$(last 4)" "1|pass breach breach pass|1|NOTE carried pool truncated: 3 untracked files not searched for carried lines (budget)" \
  "without --files the budget counts every untracked file: a.py (18) fits 30 bytes, u.py, w.py and z.py are one NOTE, and all four are audited"
fx fx_pool; check "$(cd "$R" && python3 - "$CLI" <<'PY' 2>&1
import importlib.machinery
import importlib.util
import os
import sys

loader = importlib.machinery.SourceFileLoader("comment_audit", sys.argv[1])
cli = importlib.util.module_from_spec(importlib.util.spec_from_loader("comment_audit", loader))
sys.modules["comment_audit"] = cli
loader.exec_module(cli)
top = os.getcwd()
diff = cli._diff(top, cli.Target(cli._resolve(top, "HEAD"), "", "HEAD", None), None)
print(sorted(diff.added.items()), sorted(diff.rows.items()), sorted(diff.removed.items()))
PY
)" "[('k.py', {}), ('m.py', {0: 'b = 2', 2: 'c = 3'})] [('k.py', frozenset({1}))] [('b = 2', 1), ('c = 3', 1)]" \
  "the diff keeps only rows whose text is in the removed pool (normalized), every added row number of the patch, and the pool as counts"
CWD="$TMP/norepo" audit --help; missing=""; for name in ZUVO_COMMENT_MAX_DENSITY ZUVO_COMMENT_MIN_LINES ZUVO_COMMENT_BLOCK_MIN ZUVO_COMMENT_JUSTIFY_MAX \
  ZUVO_COMMENT_AUDIT_LOG N-date N-history N-incident N-measured N-pl; do grep -qF -- "$name" "$TMP/out" || missing="$missing $name"; done
check "$rc|$missing" "0|" "--help exits 0 and lists the env table and every N family"
copy_cli; printf '\nNARRATIVE = NARRATIVE + (("N-probe", "probe"),)\n' >> "$COPY/zuvo_comment_rules.py"
CWD="$TMP/norepo" BIN="$COPY/comment-audit" audit --help; check "$rc|$(grep -c 'N-probe' "$TMP/out")" "0|1" "--help renders the families from the rules module's constants"

# ── the polyglot header: a python older than the modules need is rc 2, never a SyntaxError's rc 1 ──
REALPY=$(command -v python3)
mkdir -p "$TMP/oldpy" "$TMP/nopy" && ln -s "$(command -v perl)" "$TMP/nopy/perl" || { bad "$FIX: python shims"; finish; }
# python3 reporting version $FAKEVER: a -c probe sees it as sys.version_info; a script run is logged and, below 3.8,
# fails with rc 1 the way `from __future__ import annotations` does on 3.6.
cat > "$TMP/oldpy/python3" <<SH || { bad "$FIX: old python"; finish; }
#!/bin/sh
if [ "\$1" = -c ]; then exec "$REALPY" -c "import sys; sys.version_info = (\$FAKEVER,); exec(sys.argv[1])" "\$2"; fi
printf 'script %s\n' "\$FAKEVER" >> "$TMP/oldpy.log"
"$REALPY" -c "import sys; sys.exit((\$FAKEVER,) < (3, 8))" || { echo 'SyntaxError: future feature annotations is not defined' >&2; exit 1; }
exec "$REALPY" "\$@"
SH
chmod +x "$TMP/oldpy/python3" || { bad "$FIX: old python"; finish; }
CWD="$TMP/norepo" FAKEVER="3, 6, 15" PATH="$TMP/oldpy:$PATH" audit --help
check "$rc|$(cat "$TMP/err")|$(wc -c < "$TMP/out" | tr -d ' ')|$(cat "$TMP/oldpy.log" 2>/dev/null)" "2|comment-audit: error: python3 >= 3.8 required|0|" \
  "python3 3.6 first on PATH: the header exits 2 with one line naming the minimum, and never runs the script on it"
: > "$TMP/oldpy.log"; CWD="$TMP/norepo" FAKEVER="3, 8, 0" PATH="$TMP/oldpy:$PATH" audit --help
check "$rc|$(grep -c '^usage: comment-audit' "$TMP/out")|$(cat "$TMP/oldpy.log" 2>/dev/null)" "0|1|script 3, 8, 0" "python3 3.8 passes the probe and runs the script, once"
mkdir -p "$TMP/brokenpy" && printf '#!/bin/sh\necho "python3: error while loading shared libraries: libpython3.so" >&2\necho second >&2\nexit 127\n' \
  > "$TMP/brokenpy/python3" && chmod +x "$TMP/brokenpy/python3" || { bad "$FIX: broken python"; finish; }
CWD="$TMP/norepo" PATH="$TMP/brokenpy:$PATH" audit --help
check "$rc|$(cat "$TMP/err")|$(wc -c < "$TMP/out" | tr -d ' ')" \
  "2|comment-audit: error: $TMP/brokenpy/python3 does not start (rc 127): python3: error while loading shared libraries: libpython3.so|0" \
  "a python3 that does not start is rc 2 naming it, its rc and its first stderr line, not a version it never reported"
CWD="$TMP/norepo" PATH="$TMP/nopy" audit --help
check "$rc|$(cat "$TMP/err")" "127|comment-audit: error: no python3 or python on PATH" "no python3 or python on PATH: rc 127 (what the include's step 5 reads as a missing python) with one line saying so"

# ── diff parsing: single-line hunks, no trailing newline, invalid UTF-8, hidden characters ──
# A non-UTF-8 byte in a FILE NAME needs a filesystem that stores one: ext4 does, APFS refuses it (EILSEQ). Probed
# once; where the name cannot exist, that one file and its one assertion are left out and said, not failed.
if : 2>/dev/null > "$TMP/"$'probe\xff'; then BADNAME=$'x\xff.py'; rm -f "$TMP/"$'probe\xff'; else BADNAME=""; fi
fx_hunks() {
  repo "$1" && put one.py 'a = 1\nb = 2\nc = 3\n' && put noeol.py 'a = 1\nb = 2' && put src.py 's = 1\n# previously moved' && commit \
    && put one.py 'a = 1\n# previously one\nb = 2\nc = 3\n' && put noeol.py 'a = 1\nb = 2  # previously two' \
    && putb bad.py 'b"s = \"\xff\xfe\"\n# previously bytes\n"' && putb bidi.py 'b"# previously \xe2\x80\xaex\n"' \
    && put src.py 's = 1\n' && put dst.py 'd = 1\n# previously moved' \
    && { [ -z "$BADNAME" ] || put "$BADNAME" '# previously x\n'; }
}
fx fx_hunks; audit --files one.py noeol.py bad.py bidi.py dst.py ${BADNAME:+"$BADNAME"}
rc_is 1 "single-line hunk, missing final newline and invalid UTF-8 are audited"
has "one.py:2 N N:one.py:$(sha8 'previously one') \"" "a '+c @@' hunk without a count is one added line"
line_is "noeol.py:2 N N:noeol.py:$(sha8 'previously two') \"previously two\" -> $HINT_N [N-history]" "a last line without a newline keeps its final character"
has "bad.py:2 N N:bad.py:$(sha8 'previously bytes') \"" "invalid UTF-8 is decoded with replacement, not a crash"
has '"previously \u202ex"' "a bidi override in comment text is printed escaped"
if [ -n "$BADNAME" ]; then
  has 'x\xff.py:1 N N:x\xff.py:' "a non-UTF-8 byte in a path prints as its \\xNN byte"
else
  echo "  note: a non-UTF-8 byte in a path — not exercised on this machine (this filesystem refuses non-UTF-8 file names)"
fi
check "$(row dst.py)" "pass" "a removed last line without a newline carries its copy"

# ── user git config and environment cannot change the parse ──────────────────
NAMES=("a b.py" "zażółć.py" $'t\tab.py' 'q"x.py' 'b\s.py' $'c\x01.py' $'n\nl.py')
fx_cfg() {
  repo "$1" && python3 -c 'import os, sys
for name in sys.argv[2:]: open(os.path.join(sys.argv[1], name), "w").write("p = 1\n")' "$R" "${NAMES[@]}" \
    && put two.py 'l0 = 0\nl1 = 1\nl2 = 2\nl3 = 3\nl4 = 4\nl5 = 5\nl6 = 6\n' && commit && python3 -c 'import os, sys
for name in sys.argv[2:]: open(os.path.join(sys.argv[1], name), "w").write("p = 1\n# previously p\n")' "$R" "${NAMES[@]}" \
    && put two.py 'l0 = 0\n# previously a\nl1 = 1\nl2 = 2\nl3 = 3\n# previously b\nl4 = 4\nl5 = 5\nl6 = 6\n' \
    && git -C "$R" config core.quotePath false
}
hostile_config() {
  for kv in core.quotePath=true diff.noprefix=true diff.mnemonicPrefix=true color.ui=always diff.external=false \
            diff.renames=copies diff.algorithm=patience diff.submodule=log diff.interHunkContext=5; do
    git -C "$R" config "${kv%%=*}" "${kv#*=}" || return 1
  done
}
fx_cfg_hostile() { fx_cfg "$1" && hostile_config; }
fx fx_cfg; audit --json; cp "$TMP/out" "$TMP/plain.json"
check "$rc|$(j 'len(d["files"]), sorted(set(f["verdict"] for f in d["files"])), len(F("zażółć.py")["findings"]), len(F("two.py")["findings"])')" "1|(8, ['breach'], 1, 2)" "names with a space, quote, backslash, tab, control char, newline and non-ASCII are audited"
hostile_config || { bad "$FIX: hostile config"; finish; }
GIT_DIFF_OPTS=-u3 audit --json
check "$rc|$(python3 -c 'import json, sys
a, b = (json.load(open(p, encoding="utf-8")) for p in sys.argv[1:3])
print(a["files"] == b["files"] and sorted(f["path"] for f in a["files"]) == sorted(sys.argv[3:] + ["two.py"]))' "$TMP/plain.json" "$TMP/out" "${NAMES[@]}")" "1|True" "quotePath, noprefix, mnemonicPrefix, colour, external diff, interHunkContext and GIT_DIFF_OPTS change nothing"
fx fx_cfg_hostile; audit
check "$rc|$(last 2 | cut -c1-27)|$(grep -cF 'n\x0al.py' "$TMP/out")" "1|RESULT: comment-pass BREACH|2" "a path with a newline is printed escaped and the machine lines stay last"

# ── n/a: unsupported, binary, too large, symlink; degraded scan ──────────────
fx_misc() {
  repo "$1" && putb data.bin 'b"a\x00b\n"' && putb gone.bin 'b"\x00x"' && put README.md 'hello\n' && put attr.py 'a = 1\n' \
    && put .gitattributes 'attr.py binary\n' && commit && rm -f "$R/gone.bin" && putb data.bin 'b"a\x00c\n"' \
    && put README.md 'hello\nThe cache was previously global.\n' && put attr.py 'a = 1\n# previously attr\n' \
    && putb edge.py 'b"# previously edge\n" + b"x = 1\n" * 349522 + b"#\n"' && putb big.py 'b"# previously edge\n" + b"x = 1\n" * 349522 + b"#\n\n"' \
    && ln -s app.py "$R/link.py" && put deg.py 'x = """open\n' && putb blob.py 'b"x = 1\x00\n# previously\n"'
}
fx fx_misc; audit --json --files README.md data.bin big.py link.py blob.py attr.py gone.bin
check "$rc|$(vj)" "0|n/a|n/a (binary)|n/a (too large)|n/a (symlink)|n/a (binary)|n/a (binary)|deleted" "unsupported, binary diff, over 2 MB, symlink, NUL bytes, .gitattributes binary: n/a; a deleted binary: deleted"
fx fx_misc; check "$(wc -c < "$R/edge.py" | tr -d ' ')" "2097152" "premise: edge.py is exactly 2 MB"
audit --files edge.py; has "edge.py:1 N N:edge.py:$(sha8 'previously edge') \"" "a file of exactly 2 MB is still audited"
fx fx_misc; copy_cli; sed -i.orig 's/("O_NOFOLLOW", /(/; s/hasattr(os, "O_NOFOLLOW")/False/' "$COPY/comment-audit"
BIN="$COPY/comment-audit" audit --json --files link.py; check "$rc|$(vj)|$(grep -c O_NOFOLLOW "$COPY/comment-audit")" "0|n/a (symlink)|0" "without O_NOFOLLOW an lstat check still never follows a symlink"
fx fx_misc; audit --files deg.py; has "DEGRADED deg.py" "a degraded scan is named in the table output"
check "$(last 2 | sed 's/.* justified=0//')|$(last 1 | sed 's/.* verdict=pass//')|$(awk -F'\t' '$6 == "deg.py" { print $21 }' "$ZUVO_COMMENT_AUDIT_LOG")" \
  " degraded=1 unchanged=0| degraded=1 unchanged=0|degraded" "a degraded file counts in degraded= on both machine lines (unchanged= stays last) and is a ledger note"
fx fx_misc; audit --json --files deg.py; check "$rc|$(j 'F("deg.py")["degraded"], F("deg.py")["verdict"]')" "0|(True, 'pass')" "JSON marks the degraded file"

# ── a closed pipe never changes the exit code ────────────────────────────────
fx_pipe() { repo "$1" && put tiny.py 't = 1\n' && python3 -c 'import sys; sys.stdout.write("".join("# previously %d\nv%d = %d\n" % (k, k, k) for k in range(1500)))' > "$R/many.py"; }
fx fx_pipe; check "$(closed out --files many.py)" "1 0 False" "a 220 KB report into a closed pipe: the audit's rc, nothing on stderr"
fx fx_pipe; check "$(closed out --files tiny.py)" "0 0 False" "a short report into a closed pipe: the final flush fails quietly, rc 0"
check "$(CWD="$TMP/norepo" closed out --help)" "0 0 False" "--help into a closed pipe: rc 0, nothing on stderr"

# ── --trend over a ledger of its own ─────────────────────────────────────────
fx_trend() { repo "$1" && put t.py 't = 1\n' && put u.py 'u = 1\n' && commit && put t.py 't = 1\n# previously t\n'; }
fx fx_trend; audit --files t.py u.py; audit --trend --project "${R##*/}"
check "$rc|$(awk -v p="${R##*/}" '$1 == p { print $2, $3, $10 }' "$TMP/out")|$(head -1 "$TMP/out" | cut -d' ' -f3-5)" "0|1 1 1|project=${R##*/} rows=2 skipped=0" "--trend on its own ledger: one run, the unchanged file is not a file, one N"

# ── --skill names the calling skill in the ledger; --trend --by skill groups on it ──
fx_skill() { repo "$1" && put t.py 't = 1\n' && commit && put t.py 't = 1\n# previously t\n'; }
fx fx_skill; audit --files t.py --skill build
check "$rc|$(awk -F'\t' '$1 ~ /^[0-9][0-9][0-9][0-9]-/ { print $6 "=" $21 }' "$ZUVO_COMMENT_AUDIT_LOG")" "1|t.py=skill=build" \
  "--skill build: the ledger row's notes start with skill=build (rc 1 is the narrative finding)"
audit --files t.py --skill review; audit --files t.py; audit --trend --by skill --project "${R##*/}"
check "$rc|$(head -1 "$TMP/out" | cut -d' ' -f3-5)|$(sed -n 2p "$TMP/out" | cut -d' ' -f1)|$(awk 'NR > 2 { printf "%s:%s ", $1, $2 }' "$TMP/out")" \
  "0|project=${R##*/} by=skill rows=3|SKILL|-:1 build:1 review:1 " \
  "--trend --by skill: one row per calling skill, '-' for the run that named none, and the header says so"
audit --trend --project "${R##*/}"
check "$rc|$(sed -n 2p "$TMP/out" | cut -d' ' -f1)|$(head -1 "$TMP/out" | cut -d' ' -f3-4)" "0|PROJECT|project=${R##*/} rows=3" \
  "--trend without --by is still per project, with no by= in the header"
fx fx_skill; audit --files t.py --skill 'Build!'; errors_cleanly "--skill 'Build!': expected a lowercase skill name" "--skill outside [a-z0-9-] is rc 2 before any audit"
check "$([ -e "$ZUVO_COMMENT_AUDIT_LOG" ] && echo written || echo absent)" "absent" "a refused --skill writes no ledger row"
fx fx_skill; audit --files t.py --skill "$(printf 'a%.0s' $(seq 41))"; errors_cleanly "expected a lowercase skill name" "--skill longer than 40 characters is rc 2"
fx fx_skill; audit --files t.py --skill 'a|b'; errors_cleanly "--skill 'a|b': expected a lowercase skill name" "--skill holding a '|' (the notes separator) is rc 2"
fx fx_skill; audit --files t.py --skill ''; errors_cleanly "--skill '': expected a lowercase skill name" "--skill with an empty name is a malformed call (rc 2), not 'no skill'"
fx fx_skill; audit --files t.py --skill build; audit --trend --markdown --by skill --project "${R##*/}"
check "$rc|$(sed -n 3p "$TMP/out" | cut -d'|' -f2 | tr -d ' ')|$(sed -n 5p "$TMP/out" | cut -d'|' -f2-3 | tr -d ' ')" "0|SKILL|build|1" \
  "--trend --markdown --by skill: the table's first column is SKILL and its row is build with 1 run"
fx fx_skill; ID="N:t.py:$(sha8 'previously t')"
audit --files t.py --skill build --justify "$ID=the reviewer wrote|skill=review"
audit --files t.py --justify "$ID=the reviewer wrote|skill=review"
audit --trend --by skill --project "${R##*/}"
check "$(awk -F'\t' '$1 ~ /^[0-9][0-9][0-9][0-9]-/ { print $21 }' "$ZUVO_COMMENT_AUDIT_LOG" | tr '\n' '#')|$(awk 'NR > 2 { printf "%s:%s ", $1, $2 }' "$TMP/out")" \
  "skill=build|$ID=the reviewer wrote skill=review#$ID=the reviewer wrote skill=review#|-:1 build:1 " \
  "a justification follows skill=NAME in notes; a reason holding '|skill=review' stays one note ('|' becomes a space) and no run counts for review"
fx fx_skill; audit --trend --skill build; errors_cleanly "--skill is not allowed with --trend" "--skill is an audit option, rc 2 with --trend"
fx fx_skill; audit --files t.py --by skill; errors_cleanly "--by needs --trend" "--by is a --trend option, rc 2 without it"
fx fx_skill; audit --trend --by team; errors_cleanly "invalid choice: 'team'" "--by accepts only project or skill"

finish
