#!/usr/bin/env bash
# Guards shared/includes/regression-fence.md — the pattern five retros across three projects
# hand-rolled independently in one week because no include described it.
# The doc's commands are EXECUTED here, so prose and behaviour cannot drift apart.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DOC="$ROOT/shared/includes/regression-fence.md"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$DOC" ] || { bad "regression-fence.md missing"; echo "SOME FAILED"; exit 1; }
pass "include present"

for k in "declare the fence BEFORE" "MISSING_HEAD" "MISSING_BASE" "Honest limits" "verify --quiet is REQUIRED"; do
  grep -qi "$k" "$DOC" && pass "documents: $k" || bad "missing: $k"
done

# The two callers must reference it, or the pattern stays unreachable where it was needed.
grep -q 'regression-fence.md' "$ROOT/skills/refactor/SKILL.md" && pass "refactor references the fence" \
  || bad "refactor does not reference the fence"
grep -q 'regression-fence.md' "$ROOT/skills/execute/SKILL.md" && pass "execute references the fence" \
  || bad "execute does not reference the fence"

# --- execute the prescribed mechanics in a throwaway repo ---
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
(
  cd "$TMP" || exit 1
  git init -q . && git config user.email t@t.t && git config user.name t && git config commit.gpgsign false
  mkdir -p src tests && printf 'a\n' > tests/a.ts && printf 'b\n' > tests/b.ts && printf 'x\n' > src/x.ts
  git add -A && git commit -qm base
  BASE=$(git rev-parse HEAD)

  printf 'changed\n' > src/x.ts && git add -A && git commit -qm "only src"
  git diff --quiet "$BASE"..HEAD -- tests/ || { echo "BAD-intact"; exit 0; }

  printf 'changed\n' > tests/a.ts && git add -A && git commit -qm "touch fence"
  git diff --quiet "$BASE"..HEAD -- tests/ && { echo "BAD-violation-missed"; exit 0; }

  # blob form must flag the touched file and clear the untouched one
  b0=$(git rev-parse "$BASE:tests/a.ts"); b1=$(git rev-parse "HEAD:tests/a.ts")
  [ "$b0" = "$b1" ] && { echo "BAD-blob-same"; exit 0; }
  c0=$(git rev-parse "$BASE:tests/b.ts"); c1=$(git rev-parse "HEAD:tests/b.ts")
  [ "$c0" = "$c1" ] || { echo "BAD-blob-diff"; exit 0; }

  # a DELETED fenced file must be caught — the case a naive "diff is empty" check misses
  git rm -q tests/b.ts && git commit -qm "delete fenced file"
  d1=$(git rev-parse --verify --quiet "HEAD:tests/b.ts" || echo MISSING_HEAD)
  [ "$d1" = "MISSING_HEAD" ] || { echo "BAD-deletion-missed"; exit 0; }
  echo OK
) > "$TMP/out" 2>&1
out="$(tail -1 "$TMP/out")"
[ "$out" = "OK" ] && pass "prescribed checks catch: intact, modified, deleted" \
  || bad "fence mechanics misbehave: $out"

echo "=== RESULT ==="; [ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
