#!/usr/bin/env bash
# Behaviour tests for scripts/refactor-radar.sh — the deterministic half of zuvo:refactor-radar.
#
# Each case below locks a property that, when wrong, produces a ranking that LOOKS fine at
# the call site and sends an agent to refactor the wrong file:
#
#   raw churn instead of fix-churn  → the facade every fix passes through ranks #1 with ΣCC 3
#   per-file instead of per-family  → the facade (ΣCC 0) and its satellite (ΣCC 45) both look healthy
#   busy set by diff only           → a `refactor/<stem>-split` worktree with zero commits is invisible
#   no fresh-refactor exclusion     → last week's refactor is this week's top hotspot (its own churn)
#   noise not filtered              → node_modules / tests / minified report assets take the top
#   queue format drift              → zuvo:refactor batch triage silently treats lines as bare paths
#   persistence R missing           → a one-week activity burst outranks a year-old hotspot
#
# The fixture repo is built here from scratch (no network, no CodeSift); the builtin CC
# engine is the one under test, so numbers are asserted as ORDER and PRESENCE, not as
# exact CC values (the estimator may be tuned; the ranking properties may not).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RADAR="$ROOT/scripts/refactor-radar.sh"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$RADAR" ] || { bad "missing scripts/refactor-radar.sh"; echo "SOME FAILED"; exit 1; }
bash -n "$RADAR" 2>/dev/null || bad "syntax error in refactor-radar.sh"
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }

TMP="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
case "$TMP" in /*) ;; *) echo "FAIL: mktemp returned a relative path"; exit 1 ;; esac
REPO="$TMP/repo"
WT=""
cleanup() {
  if [ -n "$WT" ] && [ -d "$WT" ]; then
    git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
    git -C "$REPO" worktree prune >/dev/null 2>&1
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

# ── fixture repo ─────────────────────────────────────────────────────────────
mkdir -p "$REPO" && cd "$REPO" || exit 1
git init -q . && git config user.email t@t && git config user.name t && git checkout -q -b main
mkdir -p src/svc src/util src/plain node_modules/dep src/quiet

# facade (trivial) + satellite (complex) = ONE family "src/svc/orders"
cat > src/svc/orders.ts <<'EOF'
import { helper } from './orders.helpers';
export function route(a: number) { return helper(a); }
EOF
cat > src/svc/orders.helpers.ts <<'EOF'
export function helper(a: number) {
  if (a) { for (let i = 0; i < a; i++) { if (i % 2 && a > 3 || i === 7) { while (a--) { switch (a) { case 1: break; case 2: break; } } } } }
  return a ? 1 : 0;
}
export const other = (x: number) => { if (x) { return x && 1; } return 0; };
EOF
# similar complexity, feat-churn only, NO fix churn
cat > src/util/pricing.ts <<'EOF'
export function a(x: number) { if (x) { for (let i = 0; i < x; i++) { if (i % 2 && x > 3 || i === 7) { while (x--) { switch (x) { case 1: break; case 2: break; } } } } } return x ? 1 : 0; }
export const b = (x: number) => { if (x) { return x && 1; } return 0; };
EOF
# noise that must NEVER rank: dependency, a test file
cat > node_modules/dep/index.js <<'EOF'
function z(a) { if (a) { if (a) { if (a) { if (a) { if (a) { if (a) { return 1 } } } } } } return 0 }
EOF
cat > src/util/pricing.test.ts <<'EOF'
function t(a) { if (a) { if (a) { if (a) { if (a) { if (a) { if (a) { return 1 } } } } } } return 0 }
EOF
# a file that will be excluded as a FRESH refactor
cat > src/quiet/legacy.ts <<'EOF'
export function q(a: number) { if (a) { if (a > 1) { if (a > 2) { if (a > 3) { if (a > 4) { return 1 } } } } } return 0 }
export function q2(a: number) { if (a) { if (a > 1) { if (a > 2) { return 1 } } } return 0 }
EOF
# python source counts too
cat > src/plain/calc.py <<'EOF'
def calc(a, b):
    if a and b:
        for i in range(a):
            if i % 2 or b:
                pass
    return a
EOF
git add -A && git commit -qm "chore: initial tree"
i=0; while [ $i -lt 4 ]; do i=$((i+1)); echo "// fix $i" >> src/svc/orders.ts; git commit -qam "fix(orders): bug $i"; done
i=0; while [ $i -lt 6 ]; do i=$((i+1)); echo "// feat $i" >> src/util/pricing.ts; git commit -qam "feat(util): grow $i"; done
echo "// tidy" >> src/quiet/legacy.ts; git commit -qam "refactor(quiet): split legacy"

run() { bash "$RADAR" --repo "$REPO" --no-remote --min-cc 1 --quiet "$@"; }
jq_py() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); $2" "$1"; }

# ── (a) exit codes ───────────────────────────────────────────────────────────
bash "$RADAR" --repo "$TMP" --quiet >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && pass "(a) not a git repo → exit 3" || bad "(a) expected exit 3 outside a repo, got $rc"
bash "$RADAR" --repo "$REPO" --mode bogus >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "(a) bad --mode → exit 2" || bad "(a) expected exit 2 for --mode bogus, got $rc"
bash "$RADAR" --repo "$REPO" --nope >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "(a) unknown flag → exit 2" || bad "(a) expected exit 2 for unknown flag, got $rc"

# ── (b) fix-churn beats feat-churn at equal complexity; families merge ───────
run --fresh-days 0 --json "$TMP/b.json"; rc=$?
[ "$rc" -eq 0 ] || bad "(b) radar exited $rc"
top="$(jq_py "$TMP/b.json" 'print(d["rows"][0]["family"])')"
[ "$top" = "src/svc/orders" ] && pass "(b) fix-churn family ranks above feat-churn family" || bad "(b) expected src/svc/orders first, got '$top'"
nf="$(jq_py "$TMP/b.json" 'r=[x for x in d["rows"] if x["family"]=="src/svc/orders"][0]; print(r["n_files"], r["fix"], r["feat"])')"
[ "$nf" = "2 4 0" ] && pass "(b) facade + satellite merged into one family (2 files, fix=4, feat=0)" || bad "(b) family/churn counts wrong: '$nf'"
big="$(jq_py "$TMP/b.json" 'r=[x for x in d["rows"] if x["family"]=="src/util/pricing"][0]; print(r["fix"], r["feat"])')"
[ "$big" = "0 6" ] && pass "(b) feat commits counted as feat, not fix" || bad "(b) pricing.ts churn wrong: '$big'"
py="$(jq_py "$TMP/b.json" 'print(any(x["family"]=="src/plain/calc" and x["sum"]>=4 for x in d["rows"]))')"
[ "$py" = "True" ] && pass "(b) python source measured by the builtin engine" || bad "(b) calc.py missing or ΣCC<4"

# ── (c) noise never ranks ────────────────────────────────────────────────────
noise="$(jq_py "$TMP/b.json" 'print(sum(1 for x in d["rows"]+d["excluded_rows"] if "node_modules" in x["family"] or ".test" in x["family"]))')"
[ "$noise" = "0" ] && pass "(c) node_modules and *.test.* never appear (ranked or excluded)" || bad "(c) $noise noise rows leaked"

# ── (d) fresh refactor excluded by default, listed with a reason ────────────
run --json "$TMP/d.json" >/dev/null
reason="$(jq_py "$TMP/d.json" 'r=[x for x in d["excluded_rows"] if x["family"]=="src/quiet/legacy"]; print(r[0]["excluded"] if r else "RANKED")')"
[ "$reason" = "fresh-refactor" ] && pass "(d) family touched by a refactor: commit within fresh window is excluded as fresh-refactor" || bad "(d) legacy.ts should be fresh-refactor, got '$reason'"
ranked="$(jq_py "$TMP/b.json" 'print(any(x["family"]=="src/quiet/legacy" for x in d["rows"]))')"
[ "$ranked" = "True" ] && pass "(d) --fresh-days 0 lets it back in" || bad "(d) --fresh-days 0 did not re-include legacy.ts"

# ── (e) busy by worktree NAME with zero diff ─────────────────────────────────
WT="$TMP/wt-orders"
git -C "$REPO" worktree add -q -b refactor/orders-split "$WT" HEAD >/dev/null 2>&1 || bad "(e) could not create worktree"
run --fresh-days 0 --json "$TMP/e.json" >/dev/null
why="$(jq_py "$TMP/e.json" 'r=[x for x in d["excluded_rows"] if x["family"]=="src/svc/orders"]; print(r[0]["excluded"], r[0]["busy_name"] if r else "RANKED")')"
case "$why" in busy:name*orders-split*) pass "(e) zero-diff worktree named after the stem marks the family busy:name" ;; *) bad "(e) expected busy:name via refactor/orders-split, got '$why'" ;; esac
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1; git -C "$REPO" worktree prune >/dev/null 2>&1; git -C "$REPO" branch -D refactor/orders-split >/dev/null 2>&1; WT=""
# --busy-file injects the same signal without a worktree
printf 'refactor/pricing-extract\n' > "$TMP/busy.txt"
run --fresh-days 0 --busy-file "$TMP/busy.txt" --json "$TMP/e2.json" >/dev/null
why2="$(jq_py "$TMP/e2.json" 'r=[x for x in d["excluded_rows"] if x["family"]=="src/util/pricing"]; print(r[0]["excluded"] if r else "RANKED")')"
[ "$why2" = "busy:name" ] && pass "(e) --busy-file entries exclude by name too" || bad "(e) --busy-file did not exclude src/util/pricing: '$why2'"

# ── (f) queue file is in zuvo:refactor batch format ──────────────────────────
run --fresh-days 0 --top 3 --queue "$TMP/q.md" >/dev/null
n_entries="$(grep -c '^- \[ \] ' "$TMP/q.md")"
[ "$n_entries" -eq 3 ] && pass "(f) --top 3 writes exactly 3 queue entries" || bad "(f) expected 3 entries, got $n_entries"
badlines="$(grep '^- \[ \] ' "$TMP/q.md" | grep -vcE '^- \[ \] [^ |]+ \| (EXTRACT_METHODS|SPLIT_FILE|GOD_CLASS|SIMPLIFY) \| Score: [01]\.[0-9]{2}$')"
[ "$badlines" -eq 0 ] && pass "(f) every entry is '- [ ] path | TYPE | Score: 0.NN' with a zuvo:refactor type" || bad "(f) $badlines queue lines break the batch-mode contract"
head -1 "$TMP/q.md" | grep -q '^# Refactor Batch -- ' && pass "(f) queue header matches batch-mode header" || bad "(f) queue header missing"
first_path="$(grep -m1 '^- \[ \] ' "$TMP/q.md" | awk '{print $4}')"
[ -f "$REPO/$first_path" ] && pass "(f) queue paths resolve to real files (the satellite, not the family key)" || bad "(f) queue path does not exist: $first_path"

# ── (g) persistence R across snapshots ───────────────────────────────────────
run --fresh-days 0 --history "$TMP/hist" --json "$TMP/g1.json" >/dev/null
n_snap="$(ls "$TMP/hist"/*.json 2>/dev/null | wc -l | tr -d ' ')"
[ "$n_snap" = "1" ] && pass "(g) first run writes one snapshot" || bad "(g) expected 1 snapshot, got $n_snap"
mkdir -p src/new && cat > src/new/thing.ts <<'EOF'
export function thing(a: number) { if (a) { if (a > 1) { if (a > 2) { if (a > 3) { if (a > 4) { if (a > 5) { return 1 } } } } } } return 0 }
export function thing2(a: number) { if (a) { if (a > 1) { if (a > 2) { return 1 } } } return 0 }
EOF
git add -A && git commit -qm "feat(new): add thing"
run --fresh-days 0 --history "$TMP/hist" --json "$TMP/g2.json" >/dev/null
rvals="$(jq_py "$TMP/g2.json" 'm={x["family"]:x["r"] for x in d["rows"]}; print(m.get("src/svc/orders"), m.get("src/new/thing"))')"
[ "$rvals" = "1.0 0.6" ] && pass "(g) second run: persistent family R=1.0, first-appearance family R=0.6" || bad "(g) R values wrong: '$rvals'"
prev="$(jq_py "$TMP/g2.json" 'print(bool(d["meta"]["prev"]))')"
[ "$prev" = "True" ] && pass "(g) meta.prev records which snapshot R was computed against" || bad "(g) meta.prev empty on second run"

# ── (h) tests mode ranks the coverage GAP and drops covered families ────────
cat > src/svc/orders.test.ts <<'EOF'
import { route } from './orders';
test('a', () => { expect(route(1)).toBe(1); });
test('b', () => { expect(route(2)).toBe(1); });
test('c', () => { expect(route(3)).toBe(1); });
test('d', () => { expect(route(4)).toBe(1); });
test('e', () => { expect(route(5)).toBe(1); });
test('f', () => { expect(route(6)).toBe(1); });
test('g', () => { expect(route(7)).toBe(1); });
test('h', () => { expect(route(8)).toBe(1); });
EOF
git add -A && git commit -qm "test(orders): cover route"
run --fresh-days 0 --mode tests --json "$TMP/h.json" >/dev/null
cov="$(jq_py "$TMP/h.json" 'r=[x for x in d["excluded_rows"] if x["family"]=="src/svc/orders"]; print(r[0]["excluded"] if r else "RANKED")')"
[ "$cov" = "covered" ] && pass "(h) --mode tests excludes a family whose test LOC ratio is >= 0.6" || bad "(h) expected 'covered' for src/svc/orders, got '$cov'"
uncovered_first="$(jq_py "$TMP/h.json" 'print(d["rows"][0]["cov"] < 0.6 if d["rows"] else "EMPTY")')"
[ "$uncovered_first" = "True" ] && pass "(h) top of the tests queue has a real coverage gap" || bad "(h) tests-mode top row is not under-covered: $uncovered_first"

# ── (i) --engine codesift without an index is loud, never a silent fallback ──
bash "$RADAR" --repo "$REPO" --no-remote --engine codesift --quiet >"$TMP/i.out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && pass "(i) --engine codesift on an unindexed repo exits 2 (no silent builtin fallback)" || bad "(i) expected exit 2, got $rc: $(head -1 "$TMP/i.out")"

# ── (j) determinism: same tree, same table ──────────────────────────────────
run --fresh-days 0 --json "$TMP/j1.json" >/dev/null; run --fresh-days 0 --json "$TMP/j2.json" >/dev/null
same="$(python3 -c "
import json
a=[(r['family'],r['score']) for r in json.load(open('$TMP/j1.json'))['rows']]
b=[(r['family'],r['score']) for r in json.load(open('$TMP/j2.json'))['rows']]
print(a==b)")"
[ "$same" = "True" ] && pass "(j) two runs on the same tree produce the same ranking" || bad "(j) ranking is not deterministic"

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; exit 0; else echo "SOME FAILED"; exit 1; fi
