#!/usr/bin/env bash
#
# mutation-survivor-reprobe.sh — physically apply ONE mutant, run the tests, restore, report.
#
# Why this exists: the retro log's single largest recorded burn (140 turns, one session) is
# "physical-ablation harness for stryker survivors", and the same need shows up under
# `Stryker static module re-probe`, `native survivor reprobe harness`, `exact mutant re-probe`,
# `static-mutant normalization`, `survivor equivalence ledger`. They are all one question:
#
#     "Stryker says this mutant SURVIVED. Is that a real test gap, or an artifact of the run?"
#
# A native runner's survivor list is NOT that answer. Under `coverageAnalysis: perTest`, a
# module-level ("static") mutant is reported SURVIVED because per-test coverage cannot attribute
# code that executed at import time — the tests may kill it perfectly well. Reasoning about that
# from the report is how sessions disappear; applying the mutation and running the suite settles
# it in one command.
#
# The script is deliberately narrow: one mutant, one file, content-anchored, always restored.
#
# Usage:
#   mutation-survivor-reprobe.sh --file <path> --original <text> --mutated <text> --test-cmd <cmd>
#   mutation-survivor-reprobe.sh --file <path> --original-file <p> --mutated-file <p> --test-cmd <cmd>
#
# Options:
#   --file <path>          the production file to mutate
#   --original <text>      the EXACT current text to replace — must occur exactly once
#   --mutated <text>       what to put in its place
#   --original-file <p>    read --original from a file (for multi-line / quote-heavy snippets)
#   --mutated-file <p>     read --mutated from a file
#   --test-cmd <cmd>       command that runs the RELEVANT tests (run via `bash -c`)
#   --timeout <seconds>    kill the test command after N seconds (default 600)
#   --label <id>           mutant id echoed back in the output (default: -)
#   --skip-baseline        the caller already proved --test-cmd passes unmutated; skip that run
#
# BATCH MODE — the supported LOCAL loop for the LLM engine (no farm needed):
#   mutation-survivor-reprobe.sh --plan <plan.json> --out <results.json> [--test-cmd <cmd>]
#                                [--scope-file <list> | --diff <base> | --whole-files]
#   --plan <p>        {"test_cmd": "...", "mutants": [{"id","file","original","mutated","test_cmd"?}]}
#                     (or a bare list). Same content-anchored rules as a single probe.
#   --out <p>         results JSON: per-mutant verdict/test_exit/restored/baseline/reason + counts + score.
#   --scope-file <p>  the allowed scope, one `path` or `path:start-end` per line. Default: the lines
#                     this branch changed (merge-base diff incl. uncommitted + untracked files).
#                     A mutant whose anchor lies outside it is SKIPPED, never run.
#   --diff <base>     diff base for the default scope.
#   --whole-files     no scope filter — ONLY on the user's explicit request.
#   One process: the baseline runs once per distinct test command, each mutant is applied, tested
#   and restored by a single-probe call. Blocks go to stdout, a summary line to stderr.
#   Batch exit: 0 every mutant got a verdict · 2 usage · 3 incomplete (ERROR, baseline failed,
#   a file not restored, interrupted). Interrupt = the running probe restores, the batch stops.
#
# Output — KEY=VALUE lines:
#   label=<id>
#   file=<path>
#   verdict=KILLED|SURVIVED|ERROR
#   test_exit=<code>|-
#   restored=yes|no
#   baseline=passed|failed|skipped|not_run
#   sha_before=<sha256>
#   sha_after=<sha256>
#   reason=<one line>
#
# Exit codes:
#   0  KILLED    — tests failed with the mutant applied: the mutant is covered, not a gap
#   1  SURVIVED  — tests passed with the mutant applied: a REAL gap, confirmed by execution
#   2  usage error
#   3  ERROR     — NO VERDICT. Failing baseline, dirty file, ambiguous/missing anchor, timeout,
#                  command-not-found, signal death, concurrent edit, or an unverified restore.
#                  ERROR is never a verdict in disguise: only exit 0 and 1 are claims about tests.
#
# SURVIVED here is worth more than a report line: it was produced by running the code.
#
# The probe runs --test-cmd TWICE: once on the unmutated file to prove it passes at all, then once
# with the mutant applied. Without that baseline a broken command exits non-zero on both runs, and
# every real gap in the file is silently reclassified KILLED — confident false coverage, which is
# strictly worse than the noise this tool was built to remove.
#
# A timeout binary is REQUIRED (`timeout` or `gtimeout`). Running --test-cmd unbounded is not a
# degraded timeout, it is no timeout, and this tool's entire output is a claim about a bounded run.
#
# ⚠️ BUILD-CACHE HAZARD — read before choosing --test-cmd. Running the suite twice primes whatever
# compile cache the runner keeps, and many caches are keyed on (mtime-in-SECONDS, size). A mutation
# that does not change the file SIZE and lands in the same second as the baseline therefore looks
# unchanged to the cache, the stale artifact is reused, the mutant never executes, and the probe
# reports SURVIVED — a fabricated gap. Measured here with CPython: `+` → `-` is size-preserving, and
# `__pycache__` masked it every time until the baseline run was made cache-free.
# So: --test-cmd must not depend on a stale-able build cache. Disable it explicitly
# (`python3 -B` / `PYTHONDONTWRITEBYTECODE=1`, `ts-node --files`, a clean `--no-cache` flag) or
# point the command at a runner that hashes content rather than metadata.
set -uo pipefail

FILE=""
ORIGINAL=""
MUTATED=""
HAVE_ORIGINAL=0
HAVE_MUTATED=0
TEST_CMD=""
TIMEOUT_SECONDS=600
LABEL="-"
BACKUP=""
SKIP_BASELINE=0
BASELINE_STATE="not_run"   # not_run (stopped before it) | skipped | passed | failed — the batch loop reads it
PLAN=""
OUT=""
SCOPE_FILE=""
DIFF_BASE=""
WHOLE_FILES=0

die() { echo "$1" >&2; exit "${2:-2}"; }

emit() {
  # emit <verdict> <test_exit> <restored> <reason>
  printf 'label=%s\n' "$LABEL"
  printf 'file=%s\n' "$FILE"
  printf 'verdict=%s\n' "$1"
  printf 'test_exit=%s\n' "$2"
  printf 'restored=%s\n' "$3"
  printf 'baseline=%s\n' "$BASELINE_STATE"
  printf 'sha_before=%s\n' "${SHA_BEFORE:--}"
  printf 'sha_after=%s\n' "${SHA_AFTER:--}"
  printf 'reason=%s\n' "$4"
}

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else echo "-"; fi
}

# Restore on EVERY exit path — normal, error, and signal. This is the shape that leaves a mutated
# production file behind when a run is interrupted: the probe writes real source, and an
# un-restored mutant is indistinguishable from a bug the next reader has to chase.
#
# Two rules here are the difference between a safety net and a shredder, and BOTH were defects in
# the first version of this file (found by cross-model review, 2026-09-05):
#
#   1. `$BACKUP` is assigned ONLY after a verified copy. `mktemp` creates the file before `cp`
#      runs, so assigning first meant a FAILED backup (disk full, ACL, FS error) left a zero-byte
#      file that the EXIT trap then copied over the production source. The script's own error path
#      destroyed the file it exists to protect.
#   2. The backup is NOT deleted by `restore()`. It is deleted only after the post-restore hash
#      matches. A `cp` that fails or half-writes during restore used to unlink the only copy of the
#      original, leaving the source mutated and unrecoverable — reported as "restore by hand" with
#      nothing left to restore from.
restore() {
  [ -n "$BACKUP" ] && [ -f "$BACKUP" ] || return 0
  cp -p "$BACKUP" "$FILE" 2>/dev/null || {
    echo "reprobe: RESTORE FAILED — the original is still at $BACKUP; recover with: cp '$BACKUP' '$FILE'" >&2
    return 1
  }
}

# Kill the test command's whole process group, then restore. Without this the child survives a
# TERM sent to THIS script by PID (how an orchestrator kills a hung helper — terminal Ctrl-C
# signals the group and hides the bug): the file is restored correctly and a detached suite keeps
# running. Worse than the wasted CPU: if --test-cmd ever writes to the target (a codegen or
# lint --fix step wired in by mistake) it can re-corrupt the file AFTER this run reported success.
kill_child() {
  [ -n "${CHILD_PGID:-}" ] || return 0
  kill -TERM "-$CHILD_PGID" 2>/dev/null
  CHILD_PGID=""
}
trap 'kill_child; restore' EXIT
trap 'kill_child; restore; exit 3' INT TERM

# Every value-taking flag must prove its value exists BEFORE `shift 2`. With a trailing valueless
# flag, `shift 2` on one remaining arg fails without consuming it, so `while [ $# -gt 0 ]` re-enters
# on the same token forever — a silent infinite loop instead of the documented exit 2. Reproduced
# on bash 3.2 in review; it burned a farm slot with zero output.
need_val() { [ "$1" -ge 2 ] || die "missing value for $2"; }

# Read a file argument WITHOUT losing trailing newlines. `$(cat f)` strips every trailing newline,
# and --original-file exists precisely for line-exact multi-line anchors — most of which end in
# one. A stripped anchor does not match, which surfaces as the misleading "the file moved on since
# the report was produced" and sends the reader chasing drift that never happened.
# NB: this ASSIGNS to a named variable instead of echoing. Returning the text through stdout
# would put it back inside a `$( )` at the call site, and command substitution strips trailing
# newlines unconditionally — undoing the very thing the `printf x` guard is here to prevent.
# `printf -v` rather than `eval`: the escaped-eval form is in fact safe (the file's contents are
# expanded as a VALUE, never re-parsed — verified with a `$(...)` payload that stayed literal), but
# two independent reviewers read it as injection on sight. A construct that costs a reviewer a
# repro every time is worth replacing even when it is correct.
read_arg_file() {   # read_arg_file <dest-var-name> <path>
  local __content
  __content="$(cat "$2"; printf x)"
  printf -v "$1" '%s' "${__content%x}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --file)          need_val $# "$1"; FILE="$2"; shift 2 ;;
    --original)      need_val $# "$1"; ORIGINAL="$2"; HAVE_ORIGINAL=1; shift 2 ;;
    --mutated)       need_val $# "$1"; MUTATED="$2"; HAVE_MUTATED=1; shift 2 ;;
    --original-file) need_val $# "$1"; [ -f "$2" ] || die "--original-file: no such file: $2"
                     read_arg_file ORIGINAL "$2"; HAVE_ORIGINAL=1; shift 2 ;;
    --mutated-file)  need_val $# "$1"; [ -f "$2" ] || die "--mutated-file: no such file: $2"
                     read_arg_file MUTATED "$2"; HAVE_MUTATED=1; shift 2 ;;
    --test-cmd)      need_val $# "$1"; TEST_CMD="$2"; shift 2 ;;
    --timeout)       need_val $# "$1"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    --label)         need_val $# "$1"; LABEL="$2"; shift 2 ;;
    --skip-baseline) SKIP_BASELINE=1; shift ;;
    --plan)          need_val $# "$1"; PLAN="$2"; shift 2 ;;
    --out)           need_val $# "$1"; OUT="$2"; shift 2 ;;
    --scope-file)    need_val $# "$1"; SCOPE_FILE="$2"; shift 2 ;;
    --diff)          need_val $# "$1"; DIFF_BASE="$2"; shift 2 ;;
    --whole-files)   WHOLE_FILES=1; shift ;;
    -h|--help)       sed -n '2,69p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

# ── BATCH MODE ──────────────────────────────────────────────────────────────
# One orchestrator process that calls THIS script in single-probe mode for every mutant, so the
# apply / test / restore / hash-verify guarantees below are exactly the ones a lone probe has —
# there is no second implementation of them to drift. The baseline runs once per distinct test
# command (the first probe of a command runs it, later ones --skip-baseline).
if [ -n "$PLAN" ]; then
  [ -z "$FILE$ORIGINAL$MUTATED" ] || die "--plan cannot be combined with --file/--original/--mutated"
  [ -f "$PLAN" ] || die "--plan: no such file: $PLAN"
  [ -n "$OUT" ]  || die "--out is required with --plan"
  [[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be an integer >= 1"
  [ -z "$SCOPE_FILE" ] || [ -f "$SCOPE_FILE" ] || die "--scope-file: no such file: $SCOPE_FILE"
  [ "$WHOLE_FILES" = 0 ] || [ -z "$SCOPE_FILE$DIFF_BASE" ] || die "--whole-files excludes --scope-file/--diff"
  exec python3 -I - "$0" "$PLAN" "$OUT" "$SCOPE_FILE" "$DIFF_BASE" "$WHOLE_FILES" "$TEST_CMD" "$TIMEOUT_SECONDS" <<'PY'
import json, os, re, signal, subprocess, sys, tempfile

script, plan_path, out_path, scope_file, diff_base, whole, default_cmd, timeout = sys.argv[1:9]


def usage(msg):
    print("reprobe: " + msg, file=sys.stderr)
    sys.exit(2)


def git(*args):
    return subprocess.run(["git", "-c", "core.quotepath=off", *args], capture_output=True, text=True)


try:
    with open(plan_path, encoding="utf-8") as fh:
        plan = json.load(fh)
except (OSError, ValueError) as e:
    usage("--plan: %s" % e)
if isinstance(plan, list):
    plan = {"mutants": plan}
mutants = plan.get("mutants") if isinstance(plan, dict) else None
if not isinstance(mutants, list) or not mutants:
    usage("--plan: needs a non-empty mutants list")
plan_cmd = plan.get("test_cmd") or default_cmd
seen = set()
for i, m in enumerate(mutants):
    if not isinstance(m, dict):
        usage("--plan: mutant %d is not an object" % i)
    for k in ("id", "file", "original"):
        if not isinstance(m.get(k), str) or not m[k]:
            usage("--plan: mutant %d needs a non-empty string %r" % (i, k))
    if not isinstance(m.get("mutated"), str):
        usage("--plan: mutant %d needs a string 'mutated'" % i)
    m["_cmd"] = m.get("test_cmd") or plan_cmd
    if not m["_cmd"]:
        usage("--plan: mutant %s has no test_cmd (set it per mutant, in the plan, or via --test-cmd)" % m["id"])
    if m["id"] in seen:
        usage("--plan: duplicate id %s" % m["id"])
    seen.add(m["id"])


def scope_from_file(path):
    scope = {}
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            p, rng = line, None
            head, _, tail = line.rpartition(":")
            if head and re.fullmatch(r"\d+-\d+", tail):
                p, rng = head, tuple(int(x) for x in tail.split("-"))
            p = os.path.normpath(p)
            if rng is None:
                scope[p] = None
            elif scope.get(p, []) is not None:
                scope.setdefault(p, []).append(rng)
    return scope


def scope_from_diff(base_arg):
    if git("rev-parse", "--is-inside-work-tree").returncode != 0:
        usage("not a git work tree: pass --scope-file, or --whole-files if the user asked for whole files")
    cands = [base_arg] if base_arg else []
    if not base_arg:
        r = git("symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD")
        if r.returncode == 0 and r.stdout.strip():
            cands.append(r.stdout.strip())
        cands += ["origin/develop", "origin/main", "origin/master", "develop", "main", "master"]
    best = None
    for c in dict.fromkeys(cands):
        mb = git("merge-base", "HEAD", c)
        if mb.returncode != 0:
            continue
        sha = mb.stdout.strip()
        n = int(git("rev-list", "--count", sha + "..HEAD").stdout.strip() or 0)
        if best is None or n < best[0]:
            best = (n, sha)
    if best is None:
        usage("no diff base found (tried %s): pass --diff <base> or --scope-file" % ", ".join(cands))
    scope = {}
    cur = None
    for line in git("diff", "-U0", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--relative",
                    best[1], "--").stdout.splitlines():
        if line.startswith("+++ "):
            cur = None if line.startswith("+++ /dev/null") else os.path.normpath(line[6:])
        elif line.startswith("@@") and cur:
            mt = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", line)
            if mt:
                start, count = int(mt.group(1)), int(mt.group(2) if mt.group(2) is not None else 1)
                if count > 0 and scope.get(cur, []) is not None:
                    scope.setdefault(cur, []).append((start, start + count - 1))
    for p in git("ls-files", "--others", "--exclude-standard").stdout.splitlines():
        scope[os.path.normpath(p)] = None
    return scope


if whole == "1":
    scope = None
elif scope_file:
    scope = scope_from_file(scope_file)
else:
    scope = scope_from_diff(diff_base)


def out_of_scope(m):
    """True only when the anchor is found exactly once and lies outside the scope.

    The plan's `line` is a hint that expires (2.3b); the anchor's CURRENT line decides. An
    unfound or ambiguous anchor is left to the probe, which reports ERROR for it.
    """
    if scope is None:
        return False
    p = os.path.normpath(m["file"])
    if p not in scope:
        return True
    ranges = scope[p]
    if ranges is None:
        return False
    try:
        with open(m["file"], encoding="utf-8", errors="surrogateescape") as fh:
            src = fh.read()
    except OSError:
        return False
    if src.count(m["original"]) != 1:
        return False
    first = src.count("\n", 0, src.index(m["original"])) + 1
    return not any(a <= first <= b for a, b in ranges)


results = [{"id": m["id"], "file": m["file"], "verdict": "NOT_RUN", "test_exit": "-", "restored": "yes",
            "baseline": "not_run", "reason": "not reached"} for m in mutants]
child = None
state = {}          # test command -> "passed" | "failed"
stopped = None      # why the batch stopped early, if it did


def write_results(interrupted=False):
    c = {"killed": 0, "survived": 0, "error": 0, "skipped_out_of_scope": 0, "not_run": 0}
    for r in results:
        key = {"KILLED": "killed", "SURVIVED": "survived", "ERROR": "error",
               "SKIPPED": "skipped_out_of_scope", "NOT_RUN": "not_run"}[r["verdict"]]
        c[key] += 1
    measured = c["killed"] + c["survived"]
    complete = not interrupted and not stopped and c["error"] == 0 and c["not_run"] == 0
    doc = {"version": 1, "plan": plan_path, "complete": complete, "stopped": stopped,
           "scope": "whole-files" if scope is None else "changed-lines", "counts": c,
           "score": round(100.0 * c["killed"] / measured, 2) if measured else None, "mutants": results}
    tmp = "%s.%d.tmp" % (out_path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
    os.replace(tmp, out_path)
    print("batch: killed=%d survived=%d error=%d skipped_out_of_scope=%d not_run=%d score=%s complete=%s%s"
          % (c["killed"], c["survived"], c["error"], c["skipped_out_of_scope"], c["not_run"],
             "n/a" if doc["score"] is None else "%s%%" % doc["score"], str(complete).lower(),
             " stopped=" + stopped if stopped else ""), file=sys.stderr)
    return complete


def on_signal(sig, frame):
    global stopped
    stopped = "interrupted"
    for r in results:
        if r["verdict"] == "NOT_RUN":
            r["reason"] = "batch interrupted"
    if child is not None and child.poll() is None:
        child.send_signal(signal.SIGTERM)   # the probe's own trap restores the mutated file
        try:
            child.wait(timeout=60)
        except subprocess.TimeoutExpired:
            child.kill()
    write_results(interrupted=True)
    sys.exit(3)


signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGTERM, on_signal)

tmpdir = tempfile.mkdtemp(prefix="reprobe-batch.")
for idx, m in enumerate(mutants):
    rec = results[idx]
    if out_of_scope(m):
        rec.update(verdict="SKIPPED", reason="anchor is outside the changed-lines scope — not run")
        print("reprobe: %s skipped: outside the changed-lines scope" % m["id"], file=sys.stderr)
        continue
    if state.get(m["_cmd"]) == "failed":
        rec.update(verdict="ERROR", reason="baseline failed for this test command — no verdict is possible")
        continue
    paths = []
    for name in ("original", "mutated"):
        p = os.path.join(tmpdir, "%d.%s" % (idx, name))
        with open(p, "w", encoding="utf-8", errors="surrogateescape", newline="") as fh:
            fh.write(m[name])
        paths.append(p)
    argv = ["bash", script, "--file", m["file"], "--original-file", paths[0], "--mutated-file", paths[1],
            "--test-cmd", m["_cmd"], "--label", m["id"], "--timeout", timeout]
    if state.get(m["_cmd"]) == "passed":
        argv.append("--skip-baseline")
    child = subprocess.Popen(argv, stdout=subprocess.PIPE, text=True, errors="surrogateescape")
    stdout, _ = child.communicate()
    rc, child = child.returncode, None
    sys.stdout.write(stdout)
    sys.stdout.flush()
    kv = dict(l.split("=", 1) for l in stdout.splitlines() if re.match(r"^[a-z_]+=", l))
    verdict = kv.get("verdict")
    if verdict not in ("KILLED", "SURVIVED", "ERROR"):
        verdict, kv["reason"] = "ERROR", "no verdict emitted (probe exit %d)" % rc
    rec.update(verdict=verdict, test_exit=kv.get("test_exit", "-"), restored=kv.get("restored", "yes"),
               baseline=kv.get("baseline", "not_run"), reason=kv.get("reason", ""))
    if rec["baseline"] in ("passed", "failed"):
        state[m["_cmd"]] = rec["baseline"]
    if rec["restored"] != "yes":
        stopped = "file not restored: %s" % m["file"]
        for rest in results[idx + 1:]:
            rest["reason"] = "batch stopped: " + stopped
        break

for f in os.listdir(tmpdir):
    os.unlink(os.path.join(tmpdir, f))
os.rmdir(tmpdir)
sys.exit(0 if write_results() else 3)
PY
fi

[ -n "$FILE" ]      || die "--file is required"
[ -f "$FILE" ]      || die "--file: no such file: $FILE"
[ "$HAVE_ORIGINAL" = 1 ] || die "--original / --original-file is required"
[ "$HAVE_MUTATED" = 1 ]  || die "--mutated / --mutated-file is required"
[ -n "$TEST_CMD" ]  || die "--test-cmd is required"
# `>= 1`, not `>= 0`: GNU timeout treats DURATION=0 as "no timeout at all", so `--timeout 0` would
# silently restore the unbounded run this script refuses to perform — the documented 679-minute
# incident, reachable through an argument instead of a missing binary.
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be an integer >= 1 (0 disables GNU timeout entirely)"
[ "$ORIGINAL" != "$MUTATED" ] || die "--original and --mutated are identical: nothing to probe"

# Normalize to an absolute path BEFORE anything consults git. `git -C <dir> … -- <pathspec>`
# resolves the pathspec relative to <dir>, so `--file src/foo.ts` used to send git looking for
# `src/src/foo.ts` — no match, empty porcelain output, and the dirty-file check below passed
# silently on exactly the input it was written to refuse.
FILE_DIR="$(cd "$(dirname "$FILE")" && pwd)" || die "--file: cannot resolve directory of $FILE"
FILE="$FILE_DIR/$(basename "$FILE")"

SHA_BEFORE="$(sha_of "$FILE")"

# A dirty target is refused, not worked around. After the probe runs, a hash mismatch has to mean
# "the probe failed to restore" — if the file was already modified going in, that signal is gone
# and a restore would overwrite the user's uncommitted work with the committed version.
if git -C "$FILE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -n "$(git -C "$FILE_DIR" status --porcelain -- "$FILE" 2>/dev/null)" ]; then
    emit "ERROR" "-" "yes" "target file has uncommitted changes; commit or stash before probing"
    exit 3
  fi
fi

# Content anchoring, per the skill's 2.3b rule: line numbers move, content does not. The anchor
# must be UNIQUE — replacing the first of several identical snippets probes a different mutant
# than the one the report named, and the verdict would be attributed to the wrong site.
OCCURRENCES="$(ORIGINAL="$ORIGINAL" python3 - "$FILE" <<'PY'
import os, sys
src = open(sys.argv[1], encoding='utf-8', errors='surrogateescape').read()
print(src.count(os.environ['ORIGINAL']))
PY
)" || die "failed to scan the file for the anchor" 3

case "$OCCURRENCES" in
  0) emit "ERROR" "-" "yes" "anchor text not found in $FILE — the file moved on since the report was produced"; exit 3 ;;
  1) ;;
  *) emit "ERROR" "-" "yes" "anchor text occurs $OCCURRENCES times — widen --original until it is unique"; exit 3 ;;
esac

# Resolve a timeout binary ONCE, and refuse to run without one.
#
# The first version fell back to running the command unbounded when `timeout` was absent — which
# is stock macOS, the stated target platform (GNU coreutils installs it as `gtimeout`, and only
# if the user installed coreutils at all). So `--timeout 2` against a 6-second command waited the
# full six seconds and reported SURVIVED: the safety mechanism silently did nothing and then
# handed back a confident verdict. An unbounded run is not a degraded timeout, it is no timeout,
# and this tool's whole output is a claim about a bounded execution.
TIMEOUT_BIN=""
if command -v timeout  >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
fi
[ -n "$TIMEOUT_BIN" ] || die "no timeout binary found (need 'timeout' or 'gtimeout'; on macOS: brew install coreutils) — refusing to run --test-cmd unbounded" 3

# run_tests — one place, so the baseline and the mutated run are provably the SAME command.
# `-k` so a runner that ignores SIGTERM still dies: a probe that leaves a suite running is the
# 679-minute failure this fleet already paid for once. `set -m` puts the child in its own process
# group so kill_child can take the whole tree down, not just the wrapper.
run_tests() {
  set -m
  "$TIMEOUT_BIN" -k 10 "$TIMEOUT_SECONDS" bash -c "$TEST_CMD" >/dev/null 2>&1 &
  CHILD_PGID=$!
  wait "$CHILD_PGID"
  local rc=$?
  CHILD_PGID=""
  set +m
  return "$rc"
}

# Classify an exit code from run_tests. Only a clean 0 or an ordinary test failure is a VERDICT;
# everything else is the harness failing, and must not be dressed up as one.
#
#   124/137  timeout family — the suite never finished, so it said nothing about the mutant
#   126/127  not executable / command not found — nothing ran at all
#   >=128    killed by a signal — same
#
# The first version special-cased only 124/137 and funnelled every other non-zero exit into
# KILLED with the text "the reported survivor was a run artifact, not a gap". A typo in
# --test-cmd therefore certified coverage for a real gap. That is the exact failure this tool
# exists to prevent, arriving through a different exit code.
classify_exit() {   # echoes: verdict-ok | infra:<reason>
  case "$1" in
    0)       echo "verdict-ok" ;;
    124|137) echo "infra:test command exceeded ${TIMEOUT_SECONDS}s — no verdict; raise --timeout or narrow --test-cmd" ;;
    126)     echo "infra:test command is not executable (exit 126) — check --test-cmd" ;;
    127)     echo "infra:test command not found (exit 127) — check --test-cmd" ;;
    *)       if [ "$1" -ge 128 ]; then
               echo "infra:test command killed by signal $(( $1 - 128 )) (exit $1) — no verdict"
             else
               echo "verdict-ok"
             fi ;;
  esac
}

# ── BASELINE: the tests must PASS on the unmutated file ─────────────────────
# Without this the tool has an inverted failure mode that is worse than the one it was built to
# prevent. A misconfigured --test-cmd (wrong glob, missing module, an unrelated red test, a
# compile error) exits non-zero on EVERY probe; the verdict logic below reads any non-zero exit as
# KILLED, so every real gap in the file is silently reclassified as a "run artifact" and dropped.
# That manufactures coverage out of a broken command — exactly the class the timeout→ERROR rule
# already refuses, arriving through the front door. Establish the baseline first, or return no
# verdict at all.
#
# --skip-baseline is the batch loop's: the first probe of a test command ran this baseline and it
# passed, so the later probes of the same command trust it instead of paying for it again.
if [ "$SKIP_BASELINE" = 1 ]; then
  BASELINE_EXIT=0
  BASELINE_STATE="skipped"
else
  run_tests
  BASELINE_EXIT=$?
  if [ "$BASELINE_EXIT" -eq 0 ]; then BASELINE_STATE="passed"; else BASELINE_STATE="failed"; fi
fi
if [ "$BASELINE_EXIT" -ne 0 ]; then
  BASELINE_CLASS="$(classify_exit "$BASELINE_EXIT")"
  case "$BASELINE_CLASS" in
    infra:*) emit "ERROR" "$BASELINE_EXIT" "yes" "baseline: ${BASELINE_CLASS#infra:}" ;;
    *)       emit "ERROR" "$BASELINE_EXIT" "yes" \
               "baseline FAILED: --test-cmd does not pass on the unmutated file (exit $BASELINE_EXIT) — no verdict is possible; fix the command or the suite first" ;;
  esac
  exit 3
fi

# Assign BACKUP only after a VERIFIED copy. mktemp creates the file before cp runs, so assigning
# first meant a failed cp left a zero-byte file that the EXIT trap copied over the real source.
BACKUP_TMP="$(mktemp "${TMPDIR:-/tmp}/reprobe.XXXXXX")" || die "failed to create a backup file" 3
if cp -p "$FILE" "$BACKUP_TMP"; then
  # macOS `cp -p` preserves BSD file FLAGS too, not just the mode. A flag-protected source
  # (`chflags uchg`) makes the backup itself undeletable, so cleanup fails with a raw `rm:
  # Operation not permitted` on stderr — outside this script's KEY=VALUE contract — and leaks a
  # temp file. Clearing the flags on our own copy costs nothing and is a no-op elsewhere.
  chflags nouchg,noschg "$BACKUP_TMP" 2>/dev/null || true
  BACKUP="$BACKUP_TMP"
else
  rm -f "$BACKUP_TMP"
  die "failed to back up $FILE" 3
fi

ORIGINAL="$ORIGINAL" MUTATED="$MUTATED" python3 - "$FILE" <<'PY' || { emit "ERROR" "-" "yes" "failed to apply the mutation"; exit 3; }
import os, sys
p = sys.argv[1]
src = open(p, encoding='utf-8', errors='surrogateescape').read()
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(
    src.replace(os.environ['ORIGINAL'], os.environ['MUTATED'], 1))
PY

SHA_MUTATED="$(sha_of "$FILE")"

# The mutation must have actually changed something on disk. A silent no-op — line-ending
# translation, an --original that normalizes to --mutated, a filter in the write path — leaves the
# ORIGINAL code running while the probe believes a mutant is in place. The tests then pass for the
# most boring reason possible and the run reports SURVIVED: a fabricated gap, indistinguishable in
# the output from a real one.
if [ "$SHA_MUTATED" = "$SHA_BEFORE" ]; then
  emit "ERROR" "-" "yes" "the mutation did not change the file on disk (hash unchanged) — no mutant was ever applied, so no verdict is possible"
  exit 3
fi

run_tests
TEST_EXIT=$?

# Concurrent-modification check, BEFORE restoring. The pre-probe hash cannot see this: if someone
# saved the file while the suite ran, restoring the backup silently discards their edit and the
# post-restore hash still matches SHA_BEFORE, so the run reports a clean restore over lost work.
# Comparing against the hash we WROTE is the only way to tell "nobody touched it" from "somebody did".
SHA_PRE_RESTORE="$(sha_of "$FILE")"
if [ "$SHA_PRE_RESTORE" != "$SHA_MUTATED" ]; then
  emit "ERROR" "$TEST_EXIT" "no" \
    "file changed while the probe was running — NOT restoring over it; the pre-probe copy is kept at $BACKUP"
  BACKUP=""   # disarm the trap: restoring here would destroy the concurrent edit
  exit 3
fi

restore
SHA_AFTER="$(sha_of "$FILE")"

if [ "$SHA_AFTER" != "$SHA_BEFORE" ]; then
  # Keep the backup — it is the only remaining copy of the original, and the recovery step below
  # needs it. Deleting it here is what turned a failed restore into unrecoverable loss.
  emit "ERROR" "$TEST_EXIT" "no" "file did not restore to its pre-probe hash — recover with: cp '$BACKUP' '$FILE'"
  BACKUP=""   # disarm the EXIT trap so it cannot retry the copy that just failed
  exit 3
fi

# Restore verified — only now is the backup safe to drop.
rm -f "$BACKUP"
BACKUP=""

# Anything the harness did to itself is ERROR, never a verdict — see classify_exit.
CLASS="$(classify_exit "$TEST_EXIT")"
case "$CLASS" in
  infra:*) emit "ERROR" "$TEST_EXIT" "yes" "${CLASS#infra:}"; exit 3 ;;
esac

if [ "$TEST_EXIT" -eq 0 ]; then
  emit "SURVIVED" "$TEST_EXIT" "yes" "tests passed with the mutant applied — confirmed gap, not a coverageAnalysis artifact"
  exit 1
fi

emit "KILLED" "$TEST_EXIT" "yes" "tests failed with the mutant applied — the reported survivor was a run artifact, not a gap"
exit 0
