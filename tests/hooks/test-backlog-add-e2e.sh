#!/usr/bin/env bash
# SMOKE1 of docs/specs/2026-10-13-backlog-noise-bar-plan.md: `backlog-add` end to end, through the
# INSTALLED layout a skill really calls (`~/.zuvo/backlog-add`, filled with the same glob
# install_zuvo_home copies), over the three layouts a finding is filed from:
#
#   repo A  memory/ tracked, on a feature branch: the ledger route, the backlog route, the paraphrase
#           dedupe through the anchor, the regression re-open after archiving, the low-confidence SEC
#           prefix, and a refusal that must leave every byte where it was.
#   repo B  memory/ ignored, filed from a LINKED worktree: the write lands beside the main checkout's
#           real backlog, never in the worktree, and `wrote=-` says there is nothing to stage.
#   gate    the segment A1 wrote is not a production file for the pipeline-entry gate.
#
# The unit specs (test_backlog_*.py) own each rule in isolation; this file proves the pieces compose.
# Every run builds fresh temp repos under a temp HOME, so it never depends on an earlier run or on the
# machine's own ~/.zuvo. Segment names (date, branch slug with its sha suffix, host) are read from the
# verdict's `wrote=`, never hard-coded. No bats, no sleep; the repos are built here, so the farm's
# .git-less tree copy is fine.
#
# Each step asserts the verdict line by exact prefix AND the exit code; a failure prints the step, the
# exit code and the full stdout/stderr. No `SKIP:` path: run-all counts a leading SKIP as green.
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

for tool in git python3; do
  command -v "$tool" >/dev/null 2>&1 || { no "(pre) $tool not on PATH"; finish; }
done

tmp="$(mktemp -d)" || { no "(pre) mktemp -d failed"; finish; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"   # git reports resolved paths (macOS /var -> /private/var)

# Hermetic: nothing from the caller's shell or a git hook may steer the launcher or the fixtures' git.
unset ZUVO_BACKLOG_PR ZUVO_BACKLOG_ADMIT ZUVO_DEFAULT_BRANCH ZUVO_LOCK_WAIT ZUVO_BACKLOG_READY_FILE \
      ZUVO_BACKLOG_NOW ZUVO_BACKLOG_HOST GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
      GIT_OBJECT_DIRECTORY GIT_PREFIX GIT_CEILING_DIRECTORIES 2>/dev/null || true
export HOME="$tmp/home" ZUVO_PR_LOOKUP=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# $HOME/.zuvo the way install_zuvo_home fills it (scripts/install.d/zuvo-home.sh): every regular file
# of scripts/zuvo-home/ except *.pyc and dotfiles, the executable bit following the source.
mkdir -p "$HOME/.zuvo"
for src in "$ROOT"/scripts/zuvo-home/*; do
  [ -f "$src" ] || continue
  name="$(basename "$src")"
  case "$name" in *.pyc|.*) continue ;; esac
  cp "$src" "$HOME/.zuvo/$name" || { no "(pre) could not copy $name into \$HOME/.zuvo"; finish; }
  if [ -x "$src" ]; then chmod +x "$HOME/.zuvo/$name"; fi
done
ADD="$HOME/.zuvo/backlog-add"
ARCHIVER="$HOME/.zuvo/backlog-archive.py"
[ -x "$ADD" ] && [ -f "$ARCHIVER" ] || { no "(pre) backlog-add / backlog-archive.py missing after the install copy"; finish; }

ANCHOR='if total > limit:'
SOURCE_A='a = 1\nb = 2\nif total > limit:\n    return total - limit\n'
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
entry(){ grep -F -- "- [ ] $2 " "$1/memory/backlog.md"; }               # open lines of one B-id

BUG_ARGS=(--class BUG --conf 85 --source review --file src/a.py --line 3 --anchor "$ANCHOR")

# ── repo A: memory/ tracked, on feat/x ─────────────────────────────────────────────────────────────
A="$tmp/A"
new_repo "$A" && mkdir -p "$A/memory" && template > "$A/memory/backlog.md" &&
  g -C "$A" add -A && g -C "$A" commit -qm init && g -C "$A" checkout -qb feat/x \
  || { no "(pre) repo A could not be built"; finish; }

echo "A1 CPLX conf 90 -> findings ledger only"
before="$(py sha "$A/memory/backlog.md")"
add A1 "$A" --class CPLX --conf 90 --source code-audit --file src/a.py --line 3 --title 'too complex'
SEG_A1=""
if verdict A1 0 "LEDGER F-"; then
  case " $OUT " in *" reason=class-report-only "*) ok "A1: reason=class-report-only" ;;
                   *) no "A1: verdict lacks reason=class-report-only"; show ;; esac
  wrote="$(field wrote)"
  case "$wrote" in
    memory/findings/*.jsonl) SEG_A1="$(basename "$wrote")"
                             [ -f "$A/$wrote" ] && ok "A1: wrote names the segment ($SEG_A1)" \
                               || no "A1: wrote=$wrote does not exist" ;;
    *) no "A1: wrote= is not one findings segment: '$wrote'"; show ;;
  esac
fi
[ "$(py sha "$A/memory/backlog.md")" = "$before" ] && ok "A1: backlog.md sha256 unchanged" \
  || no "A1: backlog.md changed on a ledger-only finding"
n="$(py count-class "$A/memory/findings" CPLX)"
[ "$n" = "1" ] && ok "A1: one CPLX record folds from memory/findings/" || no "A1: CPLX records folded: '$n', expected 1"

echo "A2 BUG conf 85 with an anchor -> backlog entry tagged [branch:feat/x]"
add A2 "$A" "${BUG_ARGS[@]}" --title 'off-by-one at the limit'
BID=""; FID=""
if verdict A2 0 "ACCEPTED backlog B-a-BUG-"; then
  BID="$(printf '%s\n' "$OUT" | cut -d' ' -f3)"; FID="$(field ledger)"
  line="$(entry "$A" "$BID")"
  case "$line" in *"| ledger: $FID |"*) ok "A2: the entry carries ledger: $FID" ;;
                  *) no "A2: entry lacks 'ledger: $FID': $line" ;; esac
  case "$line" in *" [branch:feat/x]") ok "A2: the entry ends with [branch:feat/x]" ;;
                  *) no "A2: entry does not end with [branch:feat/x]: $line" ;; esac
  got="$(py field "$A/memory/findings" "$FID" backlog)"
  [ "$got" = "\"$BID\"" ] && ok "A2: record $FID links backlog $BID" || no "A2: record $FID backlog field is $got, expected \"$BID\""
fi

echo "A3 the same BUG paraphrased -> BUMPED, not a second entry"
add A3 "$A" "${BUG_ARGS[@]}" --title 'boundary check excludes equality'
if [ -n "$BID" ] && verdict A3 0 "BUMPED backlog $BID seen=2 "; then
  n="$(entry "$A" "$BID" | wc -l | tr -d ' ')"
  [ "$n" = "1" ] && ok "A3: still one open entry for $BID" || no "A3: $n open entries for $BID"
fi

echo "A4 tick + archive, then see it again -> REOPENED regression; verify passes"
if [ -n "$BID" ]; then
  python3 - "$A/memory/backlog.md" "$BID" <<'PY'
import sys
path, bid = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().splitlines()
out = [l.replace("- [ ] ", "- [x] ", 1) + " DONE 2026-10-13" if l.startswith("- [ ] " + bid + " ") else l
       for l in lines]
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
  arc="$(python3 "$ARCHIVER" archive --repo "$A" 2>&1)"; arc_rc=$?
  [ "$arc_rc" -eq 0 ] && ok "A4: archive exit 0" || { no "A4: archive exit $arc_rc"; echo "      $arc"; }
  add A4 "$A" "${BUG_ARGS[@]}" --title 'off-by-one at the limit'
  verdict A4 0 "REOPENED backlog $BID regression "
  ver="$(python3 "$ARCHIVER" verify --repo "$A" 2>&1)"; ver_rc=$?
  [ "$ver_rc" -eq 0 ] && ok "A4: verify exit 0 ($ver)" || { no "A4: verify exit $ver_rc"; echo "      $ver"; }
else
  no "A4: no B-id from A2 to re-open"
fi

echo "A5 SEC conf 30 -> backlog, title prefixed '$LOW'"
add A5 "$A" --class SEC --conf 30 --source review --file src/a.py --line 3 --anchor "$ANCHOR" \
  --title 'limit check can be bypassed'
if verdict A5 0 "ACCEPTED backlog "; then
  sid="$(printf '%s\n' "$OUT" | cut -d' ' -f3)"
  line="$(entry "$A" "$sid")"
  case "$line" in *"— [SEC] $LOW limit check can be bypassed |"*) ok "A5: the title starts with '$LOW'" ;;
                  *) no "A5: title not prefixed: $line" ;; esac
fi

echo "A6 anchor not in the file -> REFUSED, nothing written"
before="$(py tree "$A/memory")"
add A6 "$A" --class BUG --conf 85 --source review --file src/a.py --line 3 --anchor 'not in the file at all' \
  --title 'off-by-one at the limit'
verdict A6 3 "REFUSED anchor-not-at-line"
[ "$OUT" = "REFUSED anchor-not-at-line" ] && ok "A6: the verdict is exactly 'REFUSED anchor-not-at-line'" \
  || { no "A6: verdict is not exactly 'REFUSED anchor-not-at-line'"; show; }
[ "$(py tree "$A/memory")" = "$before" ] && ok "A6: backlog.md and every segment byte-identical" \
  || no "A6: memory/ changed on a refusal"

# ── repo B: memory/ ignored, filed from a linked worktree on feat/y ───────────────────────────────
B="$tmp/B"; BWT="$tmp/B-wt"
new_repo "$B" && printf 'memory/\n' > "$B/.gitignore" && mkdir -p "$B/memory" &&
  template > "$B/memory/backlog.md" && g -C "$B" add -A && g -C "$B" commit -qm init &&
  g -C "$B" worktree add -q -b feat/y "$BWT" \
  || { no "(pre) repo B or its worktree could not be built"; finish; }

echo "B1 BUG from the worktree -> ACCEPTED, wrote=- (memory/ is ignored)"
add B1 "$BWT" "${BUG_ARGS[@]}" --title 'off-by-one at the limit'
if verdict B1 0 "ACCEPTED backlog "; then
  case "$OUT" in *" wrote=-") ok "B1: the verdict ends with wrote=-" ;;
                 *) no "B1: the verdict does not end with wrote=-"; show ;; esac
fi

echo "B2 the segment is under the MAIN checkout, not the worktree"
segs="$(find "$B/memory/findings" -name '*.jsonl' -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "${segs:-0}" -ge 1 ] && ok "B2: $segs segment(s) under $B/memory/findings" || no "B2: no segment under the main checkout"
test ! -e "$BWT/memory/findings" && ok "B2: no memory/findings in the worktree" || no "B2: $BWT/memory/findings exists"

# ── the pipeline-entry gate ────────────────────────────────────────────────────────────────────────
echo "PG ledger segments are not production files"
if [ -n "$SEG_A1" ]; then
  ( . "$ROOT/hooks/lib/pipeline-gate-lib.sh" && pg_is_production "memory/findings/$SEG_A1" ); rc=$?
  [ "$rc" -eq 1 ] && ok "PG: pg_is_production memory/findings/$SEG_A1 returns 1" \
    || no "PG: pg_is_production memory/findings/$SEG_A1 returned $rc, expected 1"
  # The control: the same call on a source file must say production, or a broken source proves nothing.
  ( . "$ROOT/hooks/lib/pipeline-gate-lib.sh" && pg_is_production "src/a.py" ); rc=$?
  [ "$rc" -eq 0 ] && ok "PG: control src/a.py is production (returns 0)" || no "PG: control src/a.py returned $rc"
else
  no "PG: no segment name from A1 to classify"
fi

finish
