#!/usr/bin/env bash
# test-skill-retro-wiring.sh — Plan Task 7 (SC1+SC3 wiring).
# Two layers: (1) structure grep; (2) RUNTIME — extract the fenced Phase-0
# marker block from each SKILL.md, bash -n it, execute it hermetically, and
# assert a real run-marker file is created on disk (NOT grep-only theater).

_w=""; _wc(){ for d in $_w; do rm -rf "$d" 2>/dev/null; done; }; trap _wc EXIT INT TERM

start_test "T7.1 each SKILL.md has a fenced Phase-0 retro-marker block + --sweep"
for s in brainstorm plan execute; do
  F="$ROOT/skills/$s/SKILL.md"
  grep -q '# >>> zuvo:retro-marker' "$F" && grep -q '# <<< zuvo:retro-marker' "$F" \
    && pass "$s: retro-marker fence present" || fail "T7.1" "$s: missing retro-marker fence"
  blk=$(awk '/# >>> zuvo:retro-marker/{f=1} f{print} /# <<< zuvo:retro-marker/{exit}' "$F")
  printf '%s' "$blk" | grep -q 'retro-stub' && printf '%s' "$blk" | grep -q -- '--sweep' \
    && pass "$s: block invokes retro-stub --sweep" || fail "T7.1" "$s: block missing retro-stub --sweep"
  printf '%s' "$blk" | grep -q 'run-markers' \
    && pass "$s: block writes a run-marker" || fail "T7.1" "$s: block does not write run-markers"
done

start_test "T7.2 no {plugin_root}; relative include paths only"
for s in brainstorm plan execute; do
  if grep -q '{plugin_root}' "$ROOT/skills/$s/SKILL.md"; then
    fail "T7.2" "$s: contains forbidden {plugin_root}"
  else
    pass "$s: no {plugin_root}"
  fi
done

start_test "T7.3 RUNTIME: fenced block is valid bash, runs, creates a real marker"
for s in brainstorm plan execute; do
  F="$ROOT/skills/$s/SKILL.md"
  blk=$(awk '/# >>> zuvo:retro-marker/{f=1;next} /# <<< zuvo:retro-marker/{exit} f{print}' "$F")
  if [ -z "$blk" ]; then fail "T7.3" "$s: empty fenced block"; continue; fi
  printf '%s\n' "$blk" | bash -n 2>/dev/null && pass "$s: block is syntactically valid bash" \
    || fail "T7.3" "$s: fenced block fails bash -n"
  Z=$(mktemp -d); _w="$_w $Z"
  ZUVO_HOME="$Z" SKILL="$s" PROJECT="demo-$s" bash -c "$blk" >/dev/null 2>&1
  if ls "$Z"/run-markers/*.marker >/dev/null 2>&1; then
    pass "$s: executing the block created a real run-marker on disk"
  else
    fail "T7.3" "$s: block ran but no run-marker file appeared"
  fi
done

start_test "T7.4 brainstorm@Approved / plan@Reviewed / execute context-out + resume hooks"
grep -qiE 'status: *Approved' "$ROOT/skills/brainstorm/SKILL.md" \
  && grep -q 'retrospective' "$ROOT/skills/brainstorm/SKILL.md" \
  && pass "brainstorm: terminal retro tied to Approved" || fail "T7.4" "brainstorm terminal retro/Approved missing"
grep -qiE 'status: *Reviewed' "$ROOT/skills/plan/SKILL.md" \
  && grep -q 'retrospective' "$ROOT/skills/plan/SKILL.md" \
  && pass "plan: terminal retro present (Reviewed gate)" || fail "T7.4" "plan terminal retro missing"
# execute: context-out / abandon must emit a CONTEXT_OUT|PARTIAL stub, and
# the resume path must reference session-state Retro State carry. Scope to the
# zuvo:retro-stop fenced block; assert it invokes retro-stub --status and
# documents both CONTEXT_OUT and PARTIAL (runtime value via $_RST).
STOPB=$(awk '/# >>> zuvo:retro-stop/{f=1} f{print} /# <<< zuvo:retro-stop/{exit}' "$ROOT/skills/execute/SKILL.md")
if [ -n "$STOPB" ] \
   && printf '%s' "$STOPB" | grep -q 'retro-stub' \
   && printf '%s' "$STOPB" | grep -q -- '--status' \
   && printf '%s' "$STOPB" | grep -q 'CONTEXT_OUT' \
   && printf '%s' "$STOPB" | grep -q 'PARTIAL'; then
  pass "execute: non-terminal-stop block emits a CONTEXT_OUT/PARTIAL retro-stub"
else
  fail "T7.4" "execute has no zuvo:retro-stop block emitting a CONTEXT_OUT/PARTIAL stub"
fi
# bash -n the retro-stop block too (it is executable skill instruction)
printf '%s\n' "$(awk '/# >>> zuvo:retro-stop/{f=1;next} /# <<< zuvo:retro-stop/{exit} f{print}' "$ROOT/skills/execute/SKILL.md")" | bash -n 2>/dev/null \
  && pass "execute: retro-stop block is valid bash" || fail "T7.4" "retro-stop block fails bash -n"
grep -qiE 'Retro State|retro-session-id' "$ROOT/skills/execute/SKILL.md" \
  && pass "execute: resume path references session-state Retro State" \
  || fail "T7.4" "execute resume does not reference Retro State carry"
