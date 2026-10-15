#!/usr/bin/env bash
# Rerank smoke against a LOCAL stub of the paid rerank API, never the real one. Two halves:
#  (1) knowledge-prime Step 3: the command extracted from knowledge-prime.md, run from a subdirectory of a
#      temp git repo carrying the fixture knowledge store, so a doc that drifts from the helper fails here;
#  (2) backlog-add: a finding, then a reworded duplicate of it, in fresh temp repos — flagged
#      possible-dup-of (strong), bumped instead with ZUVO_BACKLOG_DEDUP_BUMP=1, untouched under ZUVO_RERANK=0.
# Runs in a temp HOME holding a mode-600 key file, with ZUVO_RERANK_BASE_URL pointing at
# tests/lib/rerank_stub.py on 127.0.0.1.
# Prints one PASS/FAIL line per check and a summary; exits non-zero on any failure.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || exit 1
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zuvo-rerank-smoke.XXXXXX")" || exit 1
[ -n "$WORK" ] && [ -d "$WORK" ] || exit 1
HOME_DIR="$WORK/home"
PASS=0
FAIL=0

stub_pid=""
cleanup() {
  : >"$WORK/stop"  # the stub wrapper polls for this file, then exits
  if [ -n "$stub_pid" ]; then
    for _ in $(seq 1 50); do kill -0 "$stub_pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$stub_pid" 2>/dev/null && kill -9 "$stub_pid" 2>/dev/null
    wait "$stub_pid" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

check() { # check <name> <exit status of the assertion>
  if [ "$2" -eq 0 ]; then PASS=$((PASS + 1)); echo "PASS: $1"; else FAIL=$((FAIL + 1)); echo "FAIL: $1"; fi
}

# The stub, in a background python process: writes its base URL to $WORK/stub.url, and the number of
# requests it has served to $WORK/stub.count, until $WORK/stop appears.
start_stub() { # start_stub <scores json>
  PYTHONPATH="$ROOT/tests/lib" python3 - "$WORK" "$1" <<'PY' &
import json, os, sys, time
from rerank_stub import RerankStub
work, scores = sys.argv[1], json.loads(sys.argv[2])
with RerankStub(scores) as stub:
    open(os.path.join(work, "stub.url.tmp"), "w").write(stub.base_url)
    os.replace(os.path.join(work, "stub.url.tmp"), os.path.join(work, "stub.url"))
    while not os.path.exists(os.path.join(work, "stop")):
        tmp = os.path.join(work, "stub.count.tmp")
        open(tmp, "w").write(str(stub.requests))
        os.replace(tmp, os.path.join(work, "stub.count"))
        time.sleep(0.05)
PY
  stub_pid=$!
  for _ in $(seq 1 100); do [ -s "$WORK/stub.url" ] && [ -s "$WORK/stub.count" ] && return 0; sleep 0.1; done
  echo "FAIL: stub did not start"; exit 1
}
stub_requests() { sleep 0.2; cat "$WORK/stub.count"; }

# Run <cmd> as a skill would, in a minimal environment: no inherited key, key file or ZUVO_RERANK*.
# Extra NAME=VALUE pairs go in front of the command.
run_clean() { # run_clean [NAME=VALUE ...] -- <dir> <bash -c text>
  local extra=()
  while [ "$1" != "--" ]; do extra+=("$1"); shift; done
  shift
  (cd "$1" && env -i PATH="$PATH" LANG="${LANG:-C}" HOME="$HOME_DIR" ZUVO_HOME="$HOME_DIR/.zuvo" \
    GIT_CONFIG_GLOBAL=/dev/null NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 \
    ZUVO_RERANK_BASE_URL="$(cat "$WORK/stub.url")" ${extra[@]+"${extra[@]}"} bash -c "$2")
}

# --- shared fixtures ---------------------------------------------------------------------------------
set -e
mkdir -p "$HOME_DIR/.zuvo" "$WORK/repo/src"
printf 'smoke-key-not-a-real-credential\n' >"$HOME_DIR/.zuvo/openrouter.key"
chmod 600 "$HOME_DIR/.zuvo/openrouter.key"
GIT_CONFIG_GLOBAL=/dev/null git init -q "$WORK/repo"
cp -R "$ROOT/tests/fixtures/rerank/knowledge" "$WORK/repo/knowledge"
# install.sh copies scripts/zuvo-home/* flat into ~/.zuvo; the symlink resolves to the same modules.
ln -s "$ROOT/scripts/zuvo-home/knowledge-rank" "$HOME_DIR/.zuvo/knowledge-rank"
start_stub '{"eval": 0.95, "retry": 0.3, "": 0.5}'
set +e

# --- (1) knowledge-prime Step 3 ----------------------------------------------------------------------
DOC="$ROOT/shared/includes/knowledge-prime.md"
python3 - "$DOC" "$WORK" <<'PY'
import re, sys
doc, work = sys.argv[1], sys.argv[2]
step3 = open(doc).read().split("### Step 3", 1)[1].split("### Step 4", 1)[0]
cmd = [b for b in re.findall(r"```bash\n(.*?)```", step3, re.S) if "knowledge-rank" in b]
assert len(cmd) == 1, "Step 3 must hold exactly one knowledge-rank block"
open(work + "/step3.sh", "w").write(cmd[0])
PY
RC=$?
[ "$RC" -eq 0 ] && [ -s "$WORK/step3.sh" ] || RC=1
check "knowledge: the Step 3 block was extracted from knowledge-prime.md" "$RC"
if [ "$RC" -ne 0 ]; then
  echo "rerank smoke: $PASS passed, $FAIL failed"
  exit 1
fi

# Every fixture tag as keywords, so each entry is a candidate and the stub's scores decide the order.
KEYWORDS="$(python3 - "$ROOT/tests/fixtures/rerank/knowledge" <<'PY'
import glob, json, sys
tags = set()
for f in glob.glob(sys.argv[1] + "/*.jsonl"):
    for line in open(f):
        try:
            tags.update(json.loads(line).get("tags", []))
        except (ValueError, AttributeError):
            pass
print(",".join(sorted(tags)))
PY
)"
# The block sets MAIN_ROOT itself; only its two placeholders are filled in, as an agent would (no keyword
# here holds a quote, so the embedded-quote rule has nothing to do).
STEP3="$(python3 - "$WORK/step3.sh" "$KEYWORDS" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
text = re.sub(r"<kw1,kw2>", lambda _: sys.argv[2], text)
print(re.sub(r"<path1>\n<path2>", lambda _: "", text))
PY
)"

# A failed command never reaches the JSON assertions: its status is recorded as the check and we move on.
check_rows() { # check_rows <name> <command exit status> <output> <ranked|local>
  if [ "$2" -ne 0 ]; then check "$1" "$2"; return; fi
  printf '%s' "$3" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
caps = {"MUST AVOID": 3, "GOTCHAS": 2, "DECISIONS": 2, "CODEBASE FACTS": 2, "PATTERNS": 1}
assert rows and len(rows) <= 10, rows
assert all(caps.get(r["section"]) for r in rows), rows
for sec, cap in caps.items():
    scores = [r["score"] for r in rows if r["section"] == sec]
    assert len(scores) <= cap and scores == sorted(scores, reverse=True), (sec, scores)
if sys.argv[1] == "ranked":
    assert rows[0]["id"] == "ap-shell-eval" and rows[0]["score"] == 0.95, rows[0]
' "$4"
  check "$1" $?
}

# The opt-out runs FIRST, with an empty rerank cache: a broken opt-out would then show up as a request,
# not hide behind a cache hit left by a ranked run.
OUT0="$(run_clean ZUVO_RERANK=0 -- "$WORK/repo/src" "$STEP3" 2>"$WORK/err0")"; RC0=$?
check "knowledge: ZUVO_RERANK=0 still exits 0" "$RC0"
[ "$(stub_requests)" -eq 0 ]
check "knowledge: ZUVO_RERANK=0 sends no request" $?
check_rows "knowledge: ZUVO_RERANK=0 still returns a local ranking within the caps" "$RC0" "$OUT0" local

OUT="$(run_clean -- "$WORK/repo/src" "$STEP3" 2>"$WORK/err1")"; RC=$?
check "knowledge: the Step 3 command exits 0 from a subdirectory with a key present" "$RC"
check_rows "knowledge: JSON order follows the stub's scores and the Step 4 caps hold" "$RC" "$OUT" ranked
[ "$(stub_requests)" -eq 1 ]
check "knowledge: the stub received exactly one rerank request" $?

# --- (2) backlog-add (same temp HOME; a fresh stub, so its request count starts at 0) --------------------
# Restarted rather than reused: (1)'s scores rank any document holding "eval" at 0.95. This one scores
# the first finding's text 0.8, inside the strong band.
restart_stub() { # restart_stub <scores json>
  : >"$WORK/stop"
  wait "$stub_pid" 2>/dev/null
  mv -f "$WORK/stop" "$WORK/stop.prev" && mv -f "$WORK/stub.url" "$WORK/stub.url.prev" \
    && mv -f "$WORK/stub.count" "$WORK/stub.count.prev" || return 1
  start_stub "$1"
}
restart_stub '{"off-by-one at the limit": 0.8}'

# A repo on a branch off main holding src/a.py, whose line 3 is the anchor the first finding cites.
mkrepo() { # mkrepo <name> -> prints its path
  local r="$WORK/$1"
  mkdir -p "$r/src" "$r/memory" || return 1
  printf 'a = 1\nb = 2\nif total > limit:\n    return total - limit\n' >"$r/src/a.py"
  printf '# Backlog\n\n' >"$r/memory/backlog.md"
  (cd "$r" && export GIT_CONFIG_GLOBAL=/dev/null && git init -q -b main . && git add -A \
    && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init \
    && git checkout -qb feat/x) || return 1
  printf '%s' "$r"
}
ADD="python3 '$ROOT/scripts/zuvo-home/backlog-add'"
FIRST="$ADD --class BUG --conf 85 --file src/a.py --line 3 --anchor 'if total > limit:' --title 'off-by-one at the limit' --source review"
# The same defect one line down, reworded: another anchor, so another F- fingerprint and B-id.
SECOND="$ADD --class BUG --conf 85 --file src/a.py --line 4 --anchor 'return total - limit' --title 'limit check misses the equal case' --source review"
add_pair() { # add_pair <repo> [NAME=VALUE ...] -> the second add's verdict; $WORK/b1 holds the first B-id
  local r="$1"; shift
  run_clean ZUVO_PR_LOOKUP=0 TZ=UTC "$@" -- "$r" "$FIRST" | awk '{print $3}' >"$WORK/b1"
  run_clean ZUVO_PR_LOOKUP=0 TZ=UTC "$@" -- "$r" "$SECOND"
}

R1="$(mkrepo flag)"
check "backlog: the temp repo was created" $?
OUT="$(add_pair "$R1")"; B1="$(cat "$WORK/b1")"
case "$OUT" in ACCEPTED*) true ;; *) false ;; esac
check "backlog: the reworded duplicate is filed as its own entry (ACCEPTED): $OUT" $?
grep -F -- '- [ ] B-' "$R1/memory/backlog.md" | grep -v -F -- "- [ ] $B1 " \
  | grep -qF "| possible-dup-of: $B1 (strong) |"
check "backlog: the second line carries possible-dup-of: <first B-id> (strong)" $?
# The first add meets an empty backlog, so only the second one has anything to send.
[ "$(stub_requests)" -eq 1 ]
check "backlog: the add-time candidate was scored by the stub, once" $?

R2="$(mkrepo bump)"
OUT="$(add_pair "$R2" ZUVO_BACKLOG_DEDUP_BUMP=1)"; B1="$(cat "$WORK/b1")"
# The verdict's seen= counts the new finding's ledger record (1); the entry's own seen: is the bump.
case "$OUT" in "BUMPED backlog $B1 "*) true ;; *) false ;; esac
check "backlog: ZUVO_BACKLOG_DEDUP_BUMP=1 bumps the first entry instead: $OUT" $?
grep -F -- "- [ ] $B1 " "$R2/memory/backlog.md" | grep -qF '| seen: 2 |'
check "backlog: the bumped entry reads seen: 2" $?
[ "$(grep -c -F -- '- [ ] B-' "$R2/memory/backlog.md")" -eq 1 ]
check "backlog: the opt-in bump leaves one entry, not two" $?

R3="$(mkrepo off)"
BEFORE="$(stub_requests)"
OUT="$(add_pair "$R3" ZUVO_RERANK=0)"
case "$OUT" in ACCEPTED*) true ;; *) false ;; esac
check "backlog: ZUVO_RERANK=0 still files the second finding (ACCEPTED): $OUT" $?
[ "$(stub_requests)" -eq "$BEFORE" ]
check "backlog: ZUVO_RERANK=0 sends no request" $?
! grep -qF 'possible-dup-of' "$R3/memory/backlog.md"
check "backlog: ZUVO_RERANK=0 writes no possible-dup-of (today's behaviour)" $?

echo "rerank smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
