#!/usr/bin/env bash
# SMOKE1 of docs/specs/2026-10-13-backlog-noise-bar-plan.md: `backlog-add` end to end, through the
# installed layout a skill really calls. `$HOME/.zuvo` is filled by the REAL `install_zuvo_home`
# (scripts/install.d/zuvo-home.sh, sourced through scripts/install.sh) into a temp HOME, so a change to
# what the installer ships is what this smoke runs. That function writes only under $HOME/.zuvo.
# The smoke covers three layouts a finding is filed from:
#
#   repo A  memory/ tracked, on a feature branch: the ledger route, the backlog route, the paraphrase
#           dedupe through the anchor (also after the cited line moved), the regression re-open after
#           archiving, the low-confidence SEC prefix, and a refusal that must leave every byte in place.
#   repo B  memory/ ignored, filed from a LINKED worktree: the entry and the ledger land beside the main
#           checkout's real backlog, never in the worktree, and `wrote=-` says there is nothing to stage.
#   gate    the segment A1 wrote is not a production file for the pipeline-entry gate, and it is the
#           memory/findings/ arm that says so (same name and extension elsewhere is production).
#
# The unit specs (test_backlog_*.py) own each rule in isolation; this file proves the pieces compose.
# Every run builds fresh temp repos under a temp HOME, so it never depends on an earlier run or on the
# machine's own ~/.zuvo. Segment names (date, branch slug with its sha suffix, host) are read from the
# verdict's `wrote=`, never hard-coded. The clock is real: the one literal date below is the closure
# marker text of a hand-ticked entry, which the archiver reads as a resolution and never compares with
# the clock. No bats, no sleep; the repos are built here, so the farm's .git-less tree copy is fine.
#
# Each step asserts the verdict line by exact prefix AND the exit code, plus the state it should leave
# on disk; a failure prints the step, the exit code and the full stdout/stderr. Every helper failure is
# a FAIL. No check is guarded by an earlier one: a value an earlier step did not produce (a B-id, an
# F-id, a segment name) becomes a `<none: …>` sentinel no verdict, file or record can match, so every
# check that needs it runs and FAILs on its own. No `SKIP:` path: run-all counts a leading SKIP as green.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
finish(){
  echo "RESULT: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 0
}

tmp=""
trap '[ -n "$tmp" ] && rm -rf "$tmp"' EXIT   # armed before anything is created: setup failures clean up too

for tool in git python3; do
  command -v "$tool" >/dev/null 2>&1 || { no "(pre) $tool not on PATH"; finish; }
done

tmp="$(mktemp -d)" || { tmp=""; no "(pre) mktemp -d failed"; finish; }
tmp="$(cd "$tmp" && pwd -P)" || { no "(pre) temp dir unreadable"; finish; }   # git reports resolved paths

# Hermetic: nothing from the caller's shell, an outer git or a git hook may steer the launcher or the
# fixtures' git. GIT_CONFIG_GLOBAL=/dev/null does not stop config injected through the environment
# (GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT + KEY_n/VALUE_n), so those go too.
unset ZUVO_BACKLOG_PR ZUVO_BACKLOG_ADMIT ZUVO_DEFAULT_BRANCH ZUVO_LOCK_WAIT ZUVO_BACKLOG_READY_FILE \
      ZUVO_BACKLOG_NOW ZUVO_BACKLOG_HOST ZUVO_OUTPUT_DIR ZUVO_HOME \
      GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX \
      GIT_CEILING_DIRECTORIES GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_PAGER GIT_EDITOR \
      PYTHONPATH PYTHONHOME BASH_ENV 2>/dev/null || true
for v in $(compgen -e); do
  case "$v" in GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*|GIT_AUTHOR_*|GIT_COMMITTER_*) unset "$v" ;; esac
done
export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" ZUVO_PR_LOOKUP=0 \
       GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$tmp/install-tmp" || { no "(pre) could not create the temp HOME"; finish; }

# ── install: the real install_zuvo_home into the temp HOME ────────────────────────────────────────
inst="$(cd "$ROOT" && env -i HOME="$HOME" TMPDIR="$tmp/install-tmp" PATH="$PATH" \
          XDG_CONFIG_HOME="$XDG_CONFIG_HOME" ZDOTDIR="$HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
          bash -c 'set +u; . ./scripts/install.sh >/dev/null 2>&1 || { echo "source-failed"; exit 0; }
                   install_zuvo_home >"$1" 2>&1; echo "rc=$? missing=${INSTALL_VERIFY_MISSING:-unset}"' \
          _ "$tmp/install.log")"
if [ "$inst" = "rc=0 missing=0" ]; then
  ok "(pre) install_zuvo_home into the temp HOME: exit 0, nothing missing"
else
  no "(pre) install_zuvo_home: '$inst'"; tail -15 "$tmp/install.log" 2>/dev/null | sed 's/^/      /'; finish
fi
ADD="$HOME/.zuvo/backlog-add"
ARCHIVER="$HOME/.zuvo/backlog-archive.py"
GATE_LIB="$ROOT/hooks/lib/pipeline-gate-lib.sh"
installed_ok=1
for name in backlog-add backlog-archive.py zuvo_backlog_add.py zuvo_backlog_admit.py zuvo_backlog_findings.py \
            zuvo_backlog_vcs.py zuvo_backlog_entry.py zuvo_backlog_lookup.py zuvo_backlog_io.py; do
  if ! cmp -s "$ROOT/scripts/zuvo-home/$name" "$HOME/.zuvo/$name"; then
    no "(pre) ~/.zuvo/$name is missing or differs from scripts/zuvo-home/$name"; installed_ok=0
  fi
done
[ -x "$ADD" ] || { no "(pre) ~/.zuvo/backlog-add is not executable"; installed_ok=0; }
[ "$installed_ok" -eq 1 ] && ok "(pre) the launcher and its modules are installed byte-identical" || finish

ANCHOR='if total > limit:'
SOURCE_A='a = 1\nb = 2\nif total > limit:\n    return total - limit\n'
DRIFTED_A='x = 0\ny = 0\na = 1\nb = 2\nif total > limit:\n    return total - limit\n'
LOW='(low confidence — verify manually)'

g(){ git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }
new_repo(){   # DIR — git repo on main with a local identity and src/a.py (line 3 is $ANCHOR)
  mkdir -p "$1/src" && printf "$SOURCE_A" > "$1/src/a.py" &&
  g -C "$1" init -q && g -C "$1" config user.name t && g -C "$1" config user.email t@t &&
  g -C "$1" config commit.gpgsign false
}
template(){   # the protocol's "Backlog Table Format" template (shared/includes/backlog-protocol.md)
  cat <<'EOF'
# Tech Debt Backlog

| ID | Status | Fingerprint | File | Problem | Severity | Category | Source | Seen | Added |
|----|--------|-------------|------|---------|----------|----------|--------|------|-------|
| B-1 | OPEN | order.service.ts|CQ8|no-try-catch | order.service.ts:45 | Missing error handling on payment call | high | CQ | zuvo:review | 1 | 2026-03-27 |
EOF
}

# py MODE ARGS… — read-only helpers over the installed modules (fold) and the file system (hashes).
py(){
  python3 - "$HOME/.zuvo" "$@" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
mode, args = sys.argv[2], sys.argv[3:]
if mode == "sha":                       # sha256 of one file
    print(hashlib.sha256(Path(args[0]).read_bytes()).hexdigest())
elif mode == "tree":                    # "<relpath> <sha256>" for every file under a dir, sorted
    root = Path(args[0])
    for p in sorted(x for x in root.rglob("*") if x.is_file()):
        print(p.relative_to(root), hashlib.sha256(p.read_bytes()).hexdigest())
else:
    import zuvo_backlog_findings as fnd
    records, defects = fnd.fold(Path(args[0]))
    if defects:
        print("fold defects: %r" % (defects,), file=sys.stderr)
        sys.exit(2)
    if mode == "count-class":           # how many folded records have this class
        print(sum(1 for r in records.values() if r.fields.get("class") == args[1]))
    elif mode == "field":               # one field of one folded record, as JSON; <absent> if no record
        rec = records.get(args[1])
        print("<absent>" if rec is None else json.dumps(rec.fields.get(args[2])))
    else:
        sys.exit("unknown mode " + mode)
PY
}
# q STEP MODE ARGS… — py, with a failure or an empty answer recorded as a FAIL; the answer in Q.
q(){
  local step="$1" rc; shift
  Q="$(py "$@" 2>"$tmp/pyerr")"; rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$Q" ]; then
    no "$step: helper 'py $*' failed (exit $rc, output '$Q'): $(tr '\n' ' ' < "$tmp/pyerr")"; Q=""; return 1
  fi
}
# unchanged STEP LABEL BASELINE MODE ARGS… — the helper's answer now equals a NON-EMPTY baseline.
unchanged(){
  local step="$1" label="$2" base="$3"; shift 3
  if [ -z "$base" ]; then no "$step: no baseline for '$label' (the helper failed before the step)"; return; fi
  q "$step" "$@" || return
  [ "$Q" = "$base" ] && ok "$step: $label" || no "$step: $label — it changed"
}

# add STEP CWD ARGS… — run the installed launcher; leaves OUT, ERR, RC.
add(){
  local step="$1" cwd="$2"; shift 2
  OUT="$(cd "$cwd" && "$ADD" --repo . "$@" 2>"$tmp/stderr")"; RC=$?
  ERR="$(cat "$tmp/stderr")"
  echo "  ... $step: rc=$RC $OUT"
}
show(){ echo "      rc=$RC"; echo "      stdout: $OUT"; echo "      stderr: $ERR"; }
# verdict STEP RC PREFIX — exactly one stdout line, starting with PREFIX, and exit code RC.
verdict(){
  local step="$1" want_rc="$2" prefix="$3"
  if [ "$RC" -ne "$want_rc" ]; then no "$step: exit $RC, expected $want_rc"; show; return 1; fi
  if [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" != "1" ]; then no "$step: stdout is not one line"; show; return 1; fi
  case "$OUT" in
    "$prefix"*) ok "$step: '$prefix…' exit $RC"; return 0 ;;
    *) no "$step: verdict does not start with '$prefix'"; show; return 1 ;;
  esac
}
field(){ printf '%s\n' "$OUT" | tr ' ' '\n' | sed -n "s/^$1=//p"; }   # KEY=value token of the verdict
entry(){ grep -F -- "- [ ] $2 " "$1" 2>/dev/null; }                     # open lines of one B-id in a file
count_open(){ entry "$1" "$2" | wc -l | tr -d ' '; }
one_open(){   # STEP FILE B-ID — exactly one open line for the B-id
  local n; n="$(count_open "$2" "$3")"
  [ "$n" = "1" ] && ok "$1: exactly one open line for $3 in ${2#"$tmp"/}" || no "$1: $n open lines for $3 in ${2#"$tmp"/}"
}

BUG_ARGS=(--class BUG --conf 85 --source review --file src/a.py --anchor "$ANCHOR")

# ── repo A: memory/ tracked, on feat/x ─────────────────────────────────────────────────────────────
A="$tmp/A"; AB="$A/memory/backlog.md"; AD="$A/memory/backlog-done.md"
new_repo "$A" && mkdir -p "$A/memory" && template > "$AB" &&
  g -C "$A" add -A && g -C "$A" commit -qm init && g -C "$A" checkout -qb feat/x \
  || { no "(pre) repo A could not be built"; finish; }

echo "A1 CPLX conf 90 -> findings ledger only"
q A1 sha "$AB" && before="$Q" || before=""
add A1 "$A" --class CPLX --conf 90 --source code-audit --file src/a.py --line 3 --title 'too complex'
verdict A1 0 "LEDGER F-"
case " $OUT " in *" reason=class-report-only "*) ok "A1: reason=class-report-only" ;;
                 *) no "A1: verdict lacks reason=class-report-only"; show ;; esac
wrote="$(field wrote)"; wrote="${wrote:-<none: no wrote= from A1>}"
SEG_A1="$(basename "$wrote")"
case "$wrote" in memory/findings/*.jsonl) ok "A1: wrote= is one findings segment ($SEG_A1)" ;;
                 *) no "A1: wrote= is not one findings segment: '$wrote'"; show ;; esac
[ -f "$A/$wrote" ] && ok "A1: the segment wrote= names exists" || no "A1: wrote=$wrote does not exist"
unchanged A1 "backlog.md sha256 unchanged" "$before" sha "$AB"
q A1 count-class "$A/memory/findings" CPLX && { [ "$Q" = "1" ] && ok "A1: one CPLX record folds from memory/findings/" \
  || no "A1: CPLX records folded: '$Q', expected 1"; }

echo "A2 BUG conf 85 with an anchor -> backlog entry tagged [branch:feat/x]"
add A2 "$A" "${BUG_ARGS[@]}" --line 3 --title 'off-by-one at the limit'
verdict A2 0 "ACCEPTED backlog B-a-BUG-"
BID="$(printf '%s\n' "$OUT" | cut -d' ' -f3)"; BID="${BID:-<none: no B-id from A2>}"
FID="$(field ledger)"; FID="${FID:-<none: no F-id from A2>}"
line="$(entry "$AB" "$BID")"
case "$line" in *"| ledger: $FID |"*) ok "A2: the entry carries ledger: $FID" ;;
                *) no "A2: entry lacks 'ledger: $FID': $line" ;; esac
case "$line" in *" [branch:feat/x]") ok "A2: the entry ends with [branch:feat/x]" ;;
                *) no "A2: entry does not end with [branch:feat/x]: $line" ;; esac
q A2 field "$A/memory/findings" "$FID" backlog && { [ "$Q" = "\"$BID\"" ] && ok "A2: record $FID links backlog $BID" \
  || no "A2: record $FID backlog field is $Q, expected \"$BID\""; }

echo "A3 the same BUG paraphrased -> BUMPED, not a second entry"
add A3 "$A" "${BUG_ARGS[@]}" --line 3 --title 'boundary check excludes equality'
verdict A3 0 "BUMPED backlog $BID seen=2 "
one_open A3 "$AB" "$BID"

echo "A3b the cited line moved down 2 (committed) -> the anchor still dedupes: BUMPED at --line 5"
printf "$DRIFTED_A" > "$A/src/a.py" && g -C "$A" commit -qam 'two lines above the finding' \
  || { no "(pre) A3b could not commit the drift"; finish; }
add A3b "$A" "${BUG_ARGS[@]}" --line 5 --title 'limit equality is rejected'
verdict A3b 0 "BUMPED backlog $BID seen=3 "
one_open A3b "$AB" "$BID"

echo "A4 tick + archive, then see it again -> REOPENED regression; verify passes"
ticked="$(python3 - "$AB" "$BID" <<'PY'
import sys
path, bid = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines()
hit = [i for i, l in enumerate(lines) if l.startswith("- [ ] " + bid + " ")]
for i in hit:
    lines[i] = lines[i].replace("- [ ] ", "- [x] ", 1) + " DONE 2026-10-13"
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(len(hit))
PY
)"; tick_rc=$?
[ "$tick_rc" -eq 0 ] && [ "$ticked" = "1" ] && ok "A4: ticked exactly one line for $BID" \
  || no "A4: the tick edit exited $tick_rc and changed '$ticked' line(s), expected 1"
arc="$(python3 "$ARCHIVER" archive --repo "$A" 2>&1)"; arc_rc=$?
[ "$arc_rc" -eq 0 ] && ok "A4: archive exit 0" || { no "A4: archive exit $arc_rc"; echo "      $arc"; }
n="$(grep -cF -- "$BID " "$AB")"
[ "$n" = "0" ] && ok "A4: after archive, $BID is gone from backlog.md (open or ticked)" \
  || no "A4: after archive, backlog.md still has $n line(s) with $BID"
n="$(grep -cF -- "- [x] $BID " "$AD" 2>/dev/null)"
[ "$n" = "1" ] && ok "A4: after archive, backlog-done.md holds the ticked $BID once" \
  || no "A4: after archive, backlog-done.md has '$n' ticked line(s) for $BID, expected 1"
add A4 "$A" "${BUG_ARGS[@]}" --line 5 --title 'off-by-one at the limit'
verdict A4 0 "REOPENED backlog $BID regression "
one_open A4 "$AB" "$BID"
n="$(count_open "$AD" "$BID")"
[ "$n" = "0" ] && ok "A4: backlog-done.md holds no open copy of $BID" || no "A4: backlog-done.md has $n open line(s) for $BID"
ver="$(python3 "$ARCHIVER" verify --repo "$A" 2>&1)"; ver_rc=$?
[ "$ver_rc" -eq 0 ] && ok "A4: verify exit 0" || { no "A4: verify exit $ver_rc"; echo "      $ver"; }
case "$ver" in *"1 declared regression"*) ok "A4: verify counts the re-open as 1 declared regression ($ver)" ;;
               *) no "A4: verify does not report the declared regression: $ver" ;; esac

echo "A5 SEC conf 30 -> backlog, title prefixed '$LOW'"
add A5 "$A" --class SEC --conf 30 --source review --file src/a.py --line 5 --anchor "$ANCHOR" \
  --title 'limit check can be bypassed'
verdict A5 0 "ACCEPTED backlog B-a-SEC-"
sid="$(printf '%s\n' "$OUT" | cut -d' ' -f3)"; sid="${sid:-<none: no B-id from A5>}"
one_open A5 "$AB" "$sid"
line="$(entry "$AB" "$sid")"
case "$line" in *"— [SEC] $LOW limit check can be bypassed |"*) ok "A5: the title starts with '$LOW'" ;;
                *) no "A5: title not prefixed: $line" ;; esac

echo "A6 anchor not in the file -> REFUSED, nothing written"
q A6 tree "$A/memory" && before="$Q" || before=""
add A6 "$A" --class BUG --conf 85 --source review --file src/a.py --line 5 --anchor 'not in the file at all' \
  --title 'off-by-one at the limit'
verdict A6 3 "REFUSED anchor-not-at-line"
[ "$OUT" = "REFUSED anchor-not-at-line" ] && ok "A6: the verdict is exactly 'REFUSED anchor-not-at-line'" \
  || { no "A6: verdict is not exactly 'REFUSED anchor-not-at-line'"; show; }
unchanged A6 "backlog.md and every segment byte-identical" "$before" tree "$A/memory"

# ── repo B: memory/ ignored, filed from a linked worktree on feat/y ───────────────────────────────
B="$tmp/B"; BWT="$tmp/B-wt"
new_repo "$B" && printf 'memory/\n' > "$B/.gitignore" && mkdir -p "$B/memory" &&
  template > "$B/memory/backlog.md" && g -C "$B" add -A && g -C "$B" commit -qm init &&
  g -C "$B" worktree add -q -b feat/y "$BWT" \
  || { no "(pre) repo B or its worktree could not be built"; finish; }

echo "B1 BUG from the worktree -> ACCEPTED, wrote=- (memory/ is ignored)"
add B1 "$BWT" "${BUG_ARGS[@]}" --line 3 --title 'off-by-one at the limit'
verdict B1 0 "ACCEPTED backlog B-a-BUG-"
BIDB="$(printf '%s\n' "$OUT" | cut -d' ' -f3)"; BIDB="${BIDB:-<none: no B-id from B1>}"
FIDB="$(field ledger)"; FIDB="${FIDB:-<none: no F-id from B1>}"
case "$OUT" in *" wrote=-") ok "B1: the verdict ends with wrote=-" ;;
               *) no "B1: the verdict does not end with wrote=-"; show ;; esac

echo "B2 the entry and the segment are under the MAIN checkout, not the worktree"
one_open B2 "$B/memory/backlog.md" "$BIDB"
test ! -e "$BWT/memory/backlog.md" && ok "B2: no memory/backlog.md was created in the worktree" \
  || no "B2: $BWT/memory/backlog.md exists"
test ! -e "$BWT/memory/findings" && ok "B2: no memory/findings in the worktree" || no "B2: $BWT/memory/findings exists"
q B2 field "$B/memory/findings" "$FIDB" id && { [ "$Q" = "\"$FIDB\"" ] \
  && ok "B2: the main checkout's ledger folds record $FIDB (B1's ledger=)" || no "B2: record $FIDB folds as $Q"; }
q B2 field "$B/memory/findings" "$FIDB" backlog && { [ "$Q" = "\"$BIDB\"" ] \
  && ok "B2: record $FIDB links backlog $BIDB" || no "B2: record $FIDB backlog field is $Q, expected \"$BIDB\""; }

# The controls change only the directory, so only the gate's memory/findings/ arm can tell them apart.
echo "PG ledger segments are not production files"
[ -f "$GATE_LIB" ] && ok "PG: $GATE_LIB exists" || no "PG: $GATE_LIB is missing"
# 99 when the library cannot be sourced, so a missing library is never read as pg_is_production's 1.
pg(){ ( cd "$A" && . "$GATE_LIB" || exit 99; pg_is_production "$1" ); }
pg "memory/findings/$SEG_A1"; rc=$?
[ "$rc" -eq 1 ] && ok "PG: pg_is_production memory/findings/$SEG_A1 returns 1" \
  || no "PG: pg_is_production memory/findings/$SEG_A1 returned $rc, expected 1"
for control in "data/$SEG_A1" "memory/$SEG_A1"; do
  pg "$control"; rc=$?
  [ "$rc" -eq 0 ] && ok "PG: control $control is production (returns 0)" \
    || no "PG: control $control returned $rc, expected 0 — the exclusion is not the memory/findings/ arm"
done

finish
