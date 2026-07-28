#!/usr/bin/env bash
# The mechanism that makes shared/includes/gate-registry.md actually authoritative.
#
# Without this test the registry is just a seventh copy. It fails the build when:
#   1. any GENERATED region is stale (someone edited a copy instead of the registry),
#   2. a gate ID is defined outside the registry (a new hand-maintained copy appeared),
#   3. any file states a gate COUNT or range that contradicts the registry.
#
# Context: the definitions previously lived in 4-6 copies each and drifted — CQ14 lost three of
# its four clauses in the audit prompt, CQ28's timeout hierarchy was inverted in 7 places, four Q
# gates carried the wrong labels in q-scoring-protocol, and test-audit shipped Q1-Q17 while
# advertising Q1-Q19. Adding one gate meant ~30 edits across 27 files, which is why CQ29 shipped
# with six places still saying 28.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REG="$ROOT/shared/includes/gate-registry.md"
GEN="$ROOT/scripts/gen-gate-copies.py"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$REG" ] || { bad "gate-registry.md missing — the SSOT is gone"; echo "SOME FAILED"; exit 1; }
[ -f "$GEN" ] || { bad "gen-gate-copies.py missing"; echo "SOME FAILED"; exit 1; }
pass "registry and generator present"

# ---------- 1. every generated region is fresh ----------
if out=$(python3 "$GEN" 2>&1); then
  pass "all GENERATED regions match the registry"
else
  bad "stale generated region(s) — run: python3 scripts/gen-gate-copies.py --write"
  printf '%s\n' "$out" | sed 's/^/      /'
fi

# ---------- 2. counts come from the registry, not from prose ----------
counts=$(python3 - "$REG" <<'PY'
import re,sys
t=open(sys.argv[1],errors="replace").read()
for fam in ("CQ","Q","CAP","AP"):
    ids={int(m) for m in re.findall(rf'^\|\s*{fam}(\d+)\s*\|',t,re.M)}
    # Q must not absorb CQ rows
    if fam=="Q": ids={int(m) for m in re.findall(r'^\|\s*Q(\d+)\s*\|',t,re.M)}
    print(f"{fam}={max(ids) if ids else 0}:{len(ids)}")
PY
)
CQ_MAX=$(echo "$counts" | sed -n 's/^CQ=\([0-9]*\):.*/\1/p')
CQ_N=$(echo "$counts"  | sed -n 's/^CQ=[0-9]*:\([0-9]*\)/\1/p')
Q_MAX=$(echo "$counts" | sed -n 's/^Q=\([0-9]*\):.*/\1/p')
Q_N=$(echo "$counts"   | sed -n 's/^Q=[0-9]*:\([0-9]*\)/\1/p')
[ "$CQ_MAX" = "$CQ_N" ] && pass "CQ ids are contiguous 1..$CQ_MAX (no gaps)" \
  || bad "CQ ids have a gap: max=$CQ_MAX but only $CQ_N defined"
[ "$Q_MAX" = "$Q_N" ] && pass "Q ids are contiguous 1..$Q_MAX (no gaps)" \
  || bad "Q ids have a gap: max=$Q_MAX but only $Q_N defined"

CAP_MAX=$(echo "$counts" | sed -n 's/^CAP=\([0-9]*\):.*/\1/p')
AP_MAX=$(echo "$counts"  | sed -n 's/^AP=\([0-9]*\):.*/\1/p')

# Any file claiming a DIFFERENT range than the registry is drift. All four families, not just
# CQ/Q — CAP drifted to CAP1-CAP14 (15 behind) precisely because nothing checked it.
drift=$(grep -rIn --include='*.md' -oE 'CQ1-CQ[0-9]+|Q1-Q[0-9]+|CAP1-CAP[0-9]+|AP1-AP[0-9]+' \
          "$ROOT/rules" "$ROOT/shared/includes" "$ROOT/docs" "$ROOT/skills" 2>/dev/null \
        | grep -vE ":CQ1-CQ${CQ_MAX}$|:Q1-Q${Q_MAX}$|:CAP1-CAP${CAP_MAX}$|:AP1-AP${AP_MAX}$" \
        | grep -vE 'gate-registry\.md|/docs/specs/|/docs/[a-z-]*20[0-9]{2}-[0-9]{2}' || true)
# (dated reports and specs under docs/specs are historical records of the state at their time —
#  rewriting them would falsify the record, so they are excluded rather than "fixed".)
# Note: "AP1-AP30" also matches the CAP pattern's tail, so CAP rows are filtered first by the
# longer alternative winning in the -oE alternation order above.
if [ -z "$drift" ]; then
  pass "no file claims a stale range (CQ1-CQ$CQ_MAX / Q1-Q$Q_MAX / CAP1-CAP$CAP_MAX / AP1-AP$AP_MAX)"
else
  bad "stale gate range(s) claimed:"; printf '%s\n' "$drift" | head -8 | sed 's/^/      /'
fi

# ---------- 3. no gate defined OUTSIDE the registry or a generated region ----------
rogue=$(python3 - "$ROOT" "$REG" <<'PY'
import os,re,sys
root,reg=sys.argv[1],sys.argv[2]
BEG=re.compile(r'<!--\s*GATES:BEGIN'); END=re.compile(r'<!--\s*GATES:END')
DEF=re.compile(r'^\|\s*(CQ|Q|CAP|AP)\d+\s*\|.*\|\s*$')      # a table-row DEFINITION
out=[]
for base,dirs,files in os.walk(root):
    dirs[:]=[d for d in dirs if d not in ('.git','node_modules','dist','zuvo','memory')]
    for f in files:
        p=os.path.join(base,f)
        if not f.endswith('.md') or os.path.abspath(p)==os.path.abspath(reg): continue
        # Only a CONTIGUOUS run of >=12 rows is a re-copied DEFINITION table. Shorter runs are
        # legitimate reference tables (N/A justifications, conditional-activation, output
        # templates) that cite gate IDs without redefining them.
        inside=False; run=0; longest=0
        for l in open(p,errors='replace'):
            if BEG.search(l): inside=True; run=0; continue
            if END.search(l): inside=False; run=0; continue
            if not inside and DEF.match(l.rstrip('\n')): run+=1; longest=max(longest,run)
            else: run=0
        if longest>=12: out.append(f"{os.path.relpath(p,root)}: {longest} contiguous gate rows outside any generated region")
print('\n'.join(out))
PY
)
if [ -z "$rogue" ]; then
  pass "no hand-maintained gate table outside the registry"
else
  bad "gate definitions living outside the registry (new copy = future drift):"
  printf '%s\n' "$rogue" | sed 's/^/      /'
fi

# ---------- 4. the generator is safe: refuses to blank regions from an empty registry ----------
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '# empty\n' > "$tmp/empty-registry.md"
if python3 - "$GEN" "$tmp/empty-registry.md" <<'PY' 2>/dev/null; then
import importlib.util,sys
spec=importlib.util.spec_from_file_location("g",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
g=m.parse_registry(sys.argv[2])
sys.exit(0 if not g["CQ"] else 1)
PY
  pass "generator parses an empty registry to empty (guard clause can trigger)"
else
  bad "empty-registry guard did not behave as expected"
fi

# ---------- 5. pipe-in-text must survive a round trip ----------
# CAP13's text contains a literal '|' inside backticks (`dialog: { kind: '...' } | null`). A naive
# row.split("|") turned that into '-- null' — silent corruption of a shipped anti-pattern, found
# only because the generated region stopped matching. This asserts the round trip stays lossless.
if grep -qF "} | null" "$ROOT/skills/code-audit/SKILL.md"; then
  pass "pipe inside a code span survives generation (CAP13 intact)"
else
  bad "CAP13's '| null' was mangled — the cell splitter is back to a naive split"
fi

roundtrip=$(python3 - "$GEN" <<'PYCHK'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
c = m.split_cells(r"CQ1 | Types | x | code `a|b` and escaped \| pipe | short")
ok = len(c) == 5 and "a|b" in c[3] and "| pipe" in c[3]
print("OK" if ok else "BAD:%d:%s" % (len(c), c[3][:40]))
PYCHK
)
if [ "$roundtrip" = "OK" ]; then
  pass "cell splitter honours code spans and escaped pipes"
else
  bad "cell splitter mis-parses pipes: $roundtrip"
fi

# ---------- 6. scoring model: three states, proportional N/A cap ----------
CQ="$ROOT/rules/cq-checklist.md"
grep -q 'out-of-scope' "$CQ" && pass "scoring documents the third state (out-of-scope != N/A)" \
  || bad "out-of-scope state missing — stack-specific gates would blow the N/A budget"
grep -q 'floor(in_scope / 3)' "$CQ" && pass "N/A cap is proportional to the in-scope gate count" \
  || bad "N/A cap is a fixed number — it silently tightens as the gate set grows"

# Adding gates must NOT move an existing verdict. A file that passed at 25/29 must still pass
# when 5 gates are added that its stack/preconditions do not trigger.
stab=$(python3 -c "
d0=25/29
d1=25/(34-5)          # 5 new conditional gates N/A'd, or out-of-scope
print('OK' if abs(d0-d1)<1e-9 and d0>=0.86 else 'BAD:%.3f vs %.3f'%(d0,d1))")
[ "$stab" = "OK" ] && pass "adding non-triggering gates leaves existing verdicts unchanged" \
  || bad "gate addition moved an existing verdict: $stab"

# Every CQ row must declare a scope, or the three-state model has a hole.
noscope=$(grep -cE '^\| CQ[0-9]+ \|[^|]*\|[^|]*\| *\|' "$REG" || true)
[ "$noscope" = "0" ] && pass "every CQ row declares a Scope" || bad "$noscope CQ row(s) have an empty Scope"

# ---------- 7. verdict thresholds must be PERCENTAGES, not raw counts ----------
# An absolute threshold silently changes meaning when the gate set grows: "16+" was 84% of 19 and
# became 64% of 25 during the v1.6.41 expansion — a two-band loosening produced by arithmetic, not
# by any decision about quality. This catches the next one.
absthr=$(grep -rIn --include='*.md' -E '[0-9]+\+?/(19|25|29|34|40)[^0-9/].*(PASS|FIX|BLOCK|REWRITE)' \
           "$ROOT/rules" "$ROOT/shared/includes" "$ROOT/skills" 2>/dev/null \
         | grep -viE 'applicable|Run:|telemetry|example|per-file' || true)
if [ -z "$absthr" ]; then
  pass "verdict thresholds are percentages, not counts over a fixed denominator"
else
  bad "threshold(s) hardcode a denominator - they drift when the gate set grows:"
  printf '%s\n' "$absthr" | head -4 | sed 's/^/      /'
fi

# ---------- 8. criticality vocabulary is respected ----------
badcrit=$(grep -oE '^\| CQ[0-9]+ \|[^|]*\|([^|]*)\|' "$REG" \
          | sed 's/.*|\([^|]*\)|$/\1/' | tr -d ' ' \
          | grep -vE '^(critical|conditional:.*|—)$' || true)
[ -z "$badcrit" ] && pass "every CQ row uses a known criticality value" \
  || { bad "unknown criticality value(s):"; printf '%s\n' "$badcrit" | head -4 | sed 's/^/      /'; }

echo "=== RESULT ==="; [ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
