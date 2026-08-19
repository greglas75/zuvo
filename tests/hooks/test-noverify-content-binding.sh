#!/usr/bin/env bash
# Adversarial artifact freshness must be CONTENT-keyed, not mtime-keyed (B-noverify-hardening #3).
#
# The pre-commit gate decided an artifact was fresh by comparing FILE MTIMES: the artifact against
# the newest staged PATH in the working tree. Those are different things. A commit stages BLOBS
# FROM THE INDEX, and a path's working-tree mtime says nothing about what its index entry holds —
# so staging content that was never reviewed, under a path whose mtime is older than the artifact,
# passed. Verified against the pre-fix gate: rc=0.
#
# Two halves, both asserted here because either one alone is inert:
#   * adversarial-review.sh RECORDS what it reviewed (`reviewed_blob=<oid>`)
#   * the gate REQUIRES every staged blob to be one of them
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
GATE="$ROOT/hooks/pre-commit-adversarial-gate.sh"
REVIEW="$ROOT/scripts/adversarial-review.sh"
PASS=0; FAIL=0
# A misspelled helper is not caught by `set -u`: bash prints "command not found", returns 127, and
# the counters never move — so a file full of broken assertions summarises as FAIL=0. That happened
# in this repo (11 assertions calling a helper the file did not define). This makes it a real failure.
command_not_found_handle(){ echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL+1)); return 127; }
t_ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
t_no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

JSON='{"tool_input":{"command":"git commit -m x"}}'
gate_rc(){ ( cd "$1" && printf '%s' "$JSON" | CLAUDECODE=1 timeout 30 bash "$GATE" >/dev/null 2>&1; echo $? ); }

mkrepo(){ # -> repo path with an in-progress execute session on task 3
  local r="$TMP/$1"; mkdir -p "$r"; ( cd "$r" || exit 1
    git init -q; git config user.email t@t; git config user.name t
    echo base > f.txt; echo base > g.txt; git add .; git commit -qm init
    mkdir -p zuvo/context
    printf '<!-- status: in-progress -->\nnext-task: 3\n' > zuvo/context/execution-state.md )
  printf '%s' "$r"
}

# --- 1. the reviewed content commits cleanly ----------------------------------------------------
R="$(mkrepo ok)"
( cd "$R" && echo REVIEWED > f.txt && git add f.txt
  printf 'artifact_kind=adversarial-review\nreviewed_blob=%s\n' "$(git hash-object f.txt)" \
    > zuvo/context/adversarial-task-3.txt )
[ "$(gate_rc "$R")" = "0" ] && t_ok "staging exactly the reviewed blob passes" || t_no "gate blocked reviewed content"

# --- 2. THE BYPASS: unreviewed blob, old mtime, artifact freshly touched -------------------------
# Every input the mtime rule looks at says "fresh". Only the content disagrees.
R="$(mkrepo toctou)"
( cd "$R" && echo REVIEWED > f.txt && git add f.txt
  printf 'artifact_kind=adversarial-review\nreviewed_blob=%s\n' "$(git hash-object f.txt)" \
    > zuvo/context/adversarial-task-3.txt
  echo SNEAKY > g.txt; touch -t 200001010000 g.txt; git add g.txt
  touch zuvo/context/adversarial-task-3.txt )
[ "$(gate_rc "$R")" = "1" ] && t_ok "an unreviewed staged blob is blocked despite a passing mtime check" \
  || t_no "TOCTOU bypass still open"

# --- 3. the same fixture must PASS a gate without the fix — proof the bypass was real ------------
# The "before" gate is DERIVED BY MUTATION of the current file, not fetched from git history. The
# first cut read `HEAD:hooks/pre-commit-adversarial-gate.sh`, which is correct exactly until the fix
# is committed — after that HEAD carries the fix, the assertion compares the gate against itself and
# reports the bypass as unreproducible. An assertion that expires the moment the work lands is worse
# than none: it goes red for a reason that has nothing to do with the behaviour it names.
mutate_out(){ # <marker-line> <until-line> -> a gate with that block removed
  python3 - "$ROOT/hooks/pre-commit-adversarial-gate.sh" "$1" "$2" <<'PYEOF' > "$TMP/gate-old.sh"
import sys
src, start_mark, end_mark = open(sys.argv[1]).read(), sys.argv[2], sys.argv[3]
i = src.index(start_mark); j = src.index(end_mark, i)
sys.stdout.write(src[:i] + src[j:])
PYEOF
}
mutate_out '  # --- CONTENT BINDING (B-noverify-hardening #3)' '  return 0
}'
rc="$( cd "$R" && printf '%s' "$JSON" | CLAUDECODE=1 timeout 30 bash "$TMP/gate-old.sh" >/dev/null 2>&1; echo $? )"
[ "$rc" = "0" ] && t_ok "a gate without content binding accepts the same fixture (bypass confirmed real)" \
  || t_no "the un-fixed gate returned $rc — the fixture may not reproduce the bypass"

# --- 4. BACKWARD COMPATIBILITY: an artifact with no reviewed_blob lines keeps the old behaviour --
# Silence must not mean "everything approved" — but it also must not block every pre-existing
# artifact, which would make the fix look like a broken gate on the day it ships.
R="$(mkrepo legacy)"
( cd "$R" && echo NEW > f.txt && git add f.txt
  printf 'artifact_kind=adversarial-review\n' > zuvo/context/adversarial-task-3.txt
  touch zuvo/context/adversarial-task-3.txt )
[ "$(gate_rc "$R")" = "0" ] && t_ok "a legacy artifact (no reviewed_blob lines) still passes on mtime" \
  || t_no "legacy artifacts are now blocked"

# --- 5. the mtime rule is NOT removed — it still catches its own case ----------------------------
R="$(mkrepo mtime)"
( cd "$R" && printf 'artifact_kind=adversarial-review\n' > zuvo/context/adversarial-task-3.txt
  touch -t 200001010000 zuvo/context/adversarial-task-3.txt
  echo NEWER > f.txt && git add f.txt )
[ "$(gate_rc "$R")" = "1" ] && t_ok "an artifact older than the staged edit is still stale" \
  || t_no "the mtime check was lost"

# --- 6. the RECORDER half: adversarial-review must actually emit the lines -----------------------
# Without this the gate's requirement is inert — no artifact would ever carry a blob, so the
# content check would silently never run and assertion 4 would mask it.
MOCK="$TMP/bin"; mkdir -p "$MOCK"
for real in timeout gtimeout jq git; do
  p="$(PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin command -v "$real" 2>/dev/null || true)"
  [ -n "$p" ] && ln -sf "$p" "$MOCK/$real"
done
cat > "$MOCK/mock-gemini" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "mcp-server" ]] && exit 1
cat > /dev/null 2>&1 || true
printf '%s\n' 'MOCK REVIEW: no findings'
EOF
chmod +x "$MOCK/mock-gemini"

R="$(mkrepo recorder)"
( cd "$R" && echo REVIEWED-BY-MOCK > f.txt )
EXPECT="$( cd "$R" && git hash-object f.txt )"
ART="$R/artifact.txt"
( cd "$R" && PATH="$MOCK:/usr/bin:/bin:/usr/sbin:/sbin" ZUVO_ADVERSARIAL_TEST_HARNESS=1 \
    timeout 60 bash "$REVIEW" --provider mock-gemini --files f.txt --artifact "$ART" ) >/dev/null 2>&1
if [ -s "$ART" ]; then
  t_ok "adversarial-review wrote an artifact under the mock harness"
  grep -q '^reviewed_blob=' "$ART" && t_ok "artifact records reviewed_blob lines" || t_no "no reviewed_blob line written"
  grep -qx "reviewed_blob=$EXPECT" "$ART" \
    && t_ok "the recorded OID matches git hash-object of the reviewed working-tree file" \
    || t_no "recorded OIDs do not include the reviewed file ($EXPECT): $(grep '^reviewed_blob=' "$ART" | head -3)"
else
  t_no "adversarial-review produced no artifact under the mock harness"
fi

# --- 7. STATE-DRIFT GUARD must not be neutered by an ANCIENT artifact (B-driftguard-bounded-age) -
# When execution-state.md is missing but a live execute marker exists, the guard asks whether any
# adversarial artifact is present. Unbounded, that is a fail-safe with no expiry: one file from a
# run that finished weeks ago disables it permanently, and the longer a repo is used the likelier
# such a file is to exist. The guard's job is to notice a live marker with no matching review, so
# "some artifact from some past run" is precisely the evidence it must refuse.
MARKERS="${ZUVO_HOME:-$HOME/.zuvo}/run-markers"
mkdir -p "$MARKERS"
R="$TMP/drift"; mkdir -p "$R"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
  && echo a > f.txt && git add f.txt && git commit -qm init && mkdir -p zuvo/context )
MK="$MARKERS/execute-zuvo-selftest-$$.marker"
printf 'repo_root=%s\nstart_ts=%s\n' "$( cd "$R" && git rev-parse --show-toplevel )" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MK"
# Removed on every exit path — a stray marker in the shared ~/.zuvo would block the NEXT commit in
# whichever repo its path happens to match.
trap 'rm -f "$MK"; rm -rf "$TMP"' EXIT

[ "$(gate_rc "$R")" = "1" ] && t_ok "live marker + no artifact blocks" || t_no "drift guard did not fire with no artifact"

( cd "$R" && : > zuvo/context/adversarial-task-1.txt && touch -t 202001010000 zuvo/context/adversarial-task-1.txt )
[ "$(gate_rc "$R")" = "1" ] && t_ok "an ANCIENT artifact no longer neuters the drift guard" \
  || t_no "a stale artifact still disables the guard indefinitely"
# Same technique: swap the bounded check back for the unbounded `ls` it replaced.
sed 's/_recent_artifact_exists "$CTX_DIR" "$GATE_GRACE"/ls "$CTX_DIR"\/adversarial-task-*.txt >\/dev\/null 2>\&1/g' \
  "$ROOT/hooks/pre-commit-adversarial-gate.sh" > "$TMP/gate-unbounded.sh"
rc="$( cd "$R" && printf '%s' "$JSON" | CLAUDECODE=1 timeout 30 bash "$TMP/gate-unbounded.sh" >/dev/null 2>&1; echo $? )"
[ "$rc" = "0" ] && t_ok "an unbounded artifact check accepts the ancient artifact (bypass confirmed real)" \
  || t_no "the unbounded variant returned $rc on the ancient-artifact fixture"

# …and it must still pass on a genuinely recent one, or it is just a gate that always blocks.
( cd "$R" && touch zuvo/context/adversarial-task-1.txt )
[ "$(gate_rc "$R")" = "0" ] && t_ok "a RECENT artifact still satisfies the drift guard" \
  || t_no "the drift guard now blocks even with a fresh artifact"

echo "  --- noverify content binding: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
