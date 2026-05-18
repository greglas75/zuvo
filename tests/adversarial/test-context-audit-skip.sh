#!/usr/bin/env bash
# test-context-audit-skip.sh — Plan Task 9 (SC4b).
# zuvo:context-audit must actually CONSUME skip-retro-gate.log so retro-gate
# bypasses are surfaced (Task 4 only produces the parseable contract).

C="$ROOT/skills/context-audit/SKILL.md"
_c=""; _cc(){ for d in $_c; do rm -rf "$d" 2>/dev/null; done; }; trap _cc EXIT INT TERM

start_test "T9.1 context-audit documents + reads skip-retro-gate.log"
grep -q 'skip-retro-gate.log' "$C" && pass "references skip-retro-gate.log" \
  || fail "T9.1" "context-audit does not mention skip-retro-gate.log"
grep -qE 'ZUVO_HOME|\.zuvo' "$C" && pass "honors the ZUVO_HOME/.zuvo location" \
  || fail "T9.1" "no ZUVO_HOME/.zuvo path for the skip log"
grep -qE '# v1 SKIP|SKIP .*DATE .*SKILL .*PROJECT|SKIP: schema' "$C" \
  && pass "documents the SKIP: schema it parses" \
  || fail "T9.1" "skip-log schema not documented"

start_test "T9.2 a fenced zuvo:skip-audit block exists and is valid bash"
grep -q '# >>> zuvo:skip-audit' "$C" && grep -q '# <<< zuvo:skip-audit' "$C" \
  && pass "zuvo:skip-audit fence present" || fail "T9.2" "missing zuvo:skip-audit fence"
blk=$(awk '/# >>> zuvo:skip-audit/{f=1;next} /# <<< zuvo:skip-audit/{exit} f{print}' "$C")
if [ -n "$blk" ]; then
  printf '%s\n' "$blk" | bash -n 2>/dev/null && pass "skip-audit block is valid bash" \
    || fail "T9.2" "skip-audit block fails bash -n"
else
  fail "T9.2" "empty skip-audit block"
fi

start_test "T9.3 RUNTIME: the block reports the bypass count + projects"
blk=$(awk '/# >>> zuvo:skip-audit/{f=1;next} /# <<< zuvo:skip-audit/{exit} f{print}' "$C")
Z=$(mktemp -d); _c="$_c $Z"
printf '# v1 SKIP\tDATE\tSKILL\tPROJECT\tNOTE\n' > "$Z/skip-retro-gate.log"
printf 'SKIP:\t2026-05-19T01:00:00Z\tplan\tdemo\truns.log gate bypassed\n'      >> "$Z/skip-retro-gate.log"
printf 'SKIP:\t2026-05-19T02:00:00Z\texecute\tacme\truns.log gate bypassed\n'   >> "$Z/skip-retro-gate.log"
printf 'SKIP:\t2026-05-19T03:00:00Z\tbrainstorm\tacme\truns.log gate bypassed\n' >> "$Z/skip-retro-gate.log"
out=$(ZUVO_HOME="$Z" bash -c "$blk" 2>&1)
echo "$out" | grep -q '3' && pass "reports the bypass count (3)" || fail "T9.3" "count 3 not reported (out=<$out>)"
echo "$out" | grep -q 'acme' && pass "names affected project(s)" || fail "T9.3" "project not surfaced"

start_test "T9.4 RUNTIME: missing/empty skip log => 0 bypasses, not an error"
blk=$(awk '/# >>> zuvo:skip-audit/{f=1;next} /# <<< zuvo:skip-audit/{exit} f{print}' "$C")
Z2=$(mktemp -d); _c="$_c $Z2"   # no skip-retro-gate.log at all
out=$(ZUVO_HOME="$Z2" bash -c "$blk" 2>&1); rc=$?
assert_exit_code 0 "$rc" "missing skip log is not an error"
echo "$out" | grep -qiE '0|no .*bypass|none' && pass "reports zero bypasses cleanly" \
  || fail "T9.4" "did not degrade cleanly on missing skip log (out=<$out>)"
