#!/usr/bin/env bash
# Platform-build integrity guards for skills/<name>/references/*.md.
#
# Two holes this contract closes:
#
#   1. INCLUDE DEPTH — validate-skills.sh resolves `../../` include tokens
#      against the repo ROOT (deliberate: ~87 agents/*.md uses are root-anchored
#      by convention, dirname-resolution would false-positive on all of them).
#      That blanket rule also let a WRONG-depth `../../shared/includes/x.md`
#      inside skills/<name>/references/foo.md pass validation, even though a
#      reader doing real relative resolution lands on skills/shared/includes/
#      and gets nothing. references/ is now resolved against the FILE'S OWN
#      dirname; ../../../ keeps the existing root-anchored handling.
#
#   2. FORBIDDEN TOKENS — all three platform builds COPY skills/*/references/
#      into their dist, but their Claude-Code-tool-token scans only covered
#      dist SKILL.md (+ rules/, protocols/). Content moved into references/
#      shipped unscanned. The scan glob now also covers
#      "$DIST"/skills/*/references/*.md in codex, cursor and antigravity.
#
# The token half is asserted against a SYNTHETIC dist (not a real build run):
# the builds enumerate skills/*/ with no SKILL.md gate, so a SKILL.md-less
# fixture dir would crash their transform step for an unrelated reason.
#
# Fixture note: skills/tmp-refguard-test/ has NO leading dot on purpose —
# a dotdir is invisible to the `skills/*/references/*.md` glob the builds use,
# which would make the whole test vacuous. It is safe without a SKILL.md
# because every count loop in the validator gates on SKILL.md presence.
# Cleanup is load-bearing: a leftover fixture dir would break a later real
# build, hence the trap on EXIT INT TERM.
#
# DISPOSITIONED (adversarial review, do not re-raise): this suite mutates the
# REAL skills/ tree and runs the whole-repo validator, so two SIMULTANEOUS runs
# can see each other's fixture and assertions (C)/(D) would false-FAIL. That is
# inherent to contract-testing a whole-repo validator against the real tree —
# the failure mode is a false FAIL, never a deletion (fixture paths are
# PID-unique + existence-guarded) and never a false PASS. Validating a copied
# tree via --root instead would forfeit exactly the real-repo coverage (D) exists
# to provide.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VALIDATE="$ROOT/scripts/validate-skills.sh"
# PID-unique so two concurrent runs cannot collide, and so cleanup can never
# delete a directory this run did not create. Keeps the tmp-refguard prefix
# (human-recognizable as debris) and no leading dot (a dotdir is invisible to
# the skills/*/references/*.md glob, which would make assertion (A) vacuous).
FIXTURE_SKILL="tmp-refguard-$$-test"
FIXTURE_DIR="$ROOT/skills/$FIXTURE_SKILL"
FIXTURE_REL="skills/$FIXTURE_SKILL/references/bad.md"
FIXTURE_MD="$ROOT/$FIXTURE_REL"
fail=0

pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# Refuse to touch a pre-existing path — never rm -rf something we did not
# create. Checked BEFORE the cleanup trap is armed, so an abort here cannot
# delete it either.
if [ -e "$FIXTURE_DIR" ]; then
  echo "FAIL: fixture path already exists, refusing to overwrite or delete it: $FIXTURE_DIR"
  echo "      (remove it by hand if it is stale debris, then re-run)"
  exit 1
fi

TMP="$(mktemp -d)"
# A failed mktemp leaves TMP empty, which would turn every "$TMP/..." into an
# absolute /... path — created, asserted on, and then rm -rf'd. Fail fast.
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: mktemp -d failed"; exit 1; }
# removes ONLY the two exact paths this run created
cleanup() { rm -rf "$FIXTURE_DIR" "$TMP"; }
# EXIT cleans up on normal end; a signal must clean up AND STOP — without the
# explicit exit the handler returns and the script would carry on running its
# assertions with the fixture already deleted.
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM HUP

# The exact token set the codex build scans for — do NOT extend here; this
# mirrors the build, it does not define it.
TOKENS='TaskCreate|TaskUpdate|TaskList|EnterPlanMode|ExitPlanMode|AskUserQuestion|run_in_background|TeamCreate|SendMessage'

cd "$ROOT" || { echo "FAIL: cannot cd to $ROOT"; exit 1; }

# write_md <path> — content on stdin. Fixture setup is checked: a silently
# failed mkdir/write would turn every later assertion into a confusing,
# misattributed failure, so setup problems abort loudly instead.
write_md() {
  mkdir -p "$(dirname "$1")" || { bad "setup: cannot create $(dirname "$1")"; exit 1; }
  cat > "$1" || { bad "setup: cannot write $1"; exit 1; }
}

# ── (A) glob visibility — everything below is vacuous without this ────────────
write_md "$FIXTURE_MD" <<'EOF'
# Refguard fixture

Load ../../shared/includes/gate-registry.md before scoring.
EOF

if compgen -G "skills/*/references/*.md" 2>/dev/null | grep -qxF "$FIXTURE_REL"; then
  pass "fixture is visible to the skills/*/references/*.md glob"
else
  bad "fixture NOT matched by skills/*/references/*.md glob (rest of suite would be vacuous)"
fi

# ── (B) wrong-depth include inside references/ must ERROR ────────────────────
# The include target EXISTS at the root — the only defect is the depth, so the
# message must say so and suggest ../../../, not claim the file is missing.
out="$(bash "$VALIDATE" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "^ERROR:.*wrong-depth.*$FIXTURE_REL"; then
  pass "wrong-depth ../../ include in references/ is an ERROR"
else
  bad "wrong-depth ../../ include in references/ NOT reported (rc=$rc)"
fi

# ── (B2) a target that resolves NEITHER way is dangling, not wrong-depth ─────
write_md "$FIXTURE_MD" <<'EOF'
# Refguard fixture

Load ../../shared/includes/no-such-include-refguard.md before scoring.
EOF

out="$(bash "$VALIDATE" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q "^ERROR:.*dangling include.*$FIXTURE_REL" \
   && ! printf '%s' "$out" | grep -q "wrong-depth.*$FIXTURE_REL"; then
  pass "unresolvable include in references/ is a plain dangling ERROR (no depth suggestion)"
else
  bad "unresolvable include in references/ mislabeled or not reported (rc=$rc)"
fi

# ── (B3) catch-all depth advice must be references-aware ─────────────────────
# The generic non-canonical-depth error hard-codes the root-anchored ../../
# convention; inside references/ that advice is simply wrong (../../ is the
# defect being reported), so the suggested depth must be ../../../ there.
write_md "$FIXTURE_MD" <<'EOF'
# Refguard fixture

Load ../shared/includes/gate-registry.md before scoring.
EOF

out="$(bash "$VALIDATE" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q "non-canonical include depth (must be \.\./\.\./\.\./).*$FIXTURE_REL"; then
  pass "non-canonical depth advice inside references/ suggests ../../../"
else
  bad "non-canonical depth advice inside references/ still suggests ../../ (rc=$rc)"
fi

# ── (C) correct depth + clean tokens must validate clean ─────────────────────
write_md "$FIXTURE_MD" <<'EOF'
# Refguard fixture

Load ../../../shared/includes/gate-registry.md before scoring.
EOF

out="$(bash "$VALIDATE" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ERRORS: 0'; then
  pass "correct-depth ../../../ include in references/ validates clean"
else
  bad "correct-depth ../../../ include in references/ wrongly flagged (rc=$rc)"
fi

# ── (C2) a NESTED references/ subdir is unshippable → hard ERROR ─────────────
# All three builds copy "$skill_dir/references/"*.md — one level, non-recursive
# (build-codex:624, build-cursor:460, build-antigravity:504) — so a nested file
# reaches no platform at all. It must be flagged as an unsupported layout, NOT
# given a bogus ../../../ depth suggestion (its include below resolves fine
# root-anchored and must therefore raise no depth complaint of its own).
NESTED_REL="skills/$FIXTURE_SKILL/references/sub/deep.md"
write_md "$ROOT/$NESTED_REL" <<'EOF'
# Nested refguard fixture

Load ../../shared/includes/gate-registry.md before scoring.
EOF

out="$(bash "$VALIDATE" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] \
   && printf '%s' "$out" | grep -q "^ERROR:.*unsupported references/ layout.*$NESTED_REL" \
   && ! printf '%s' "$out" | grep -q "wrong-depth.*$NESTED_REL"; then
  pass "nested references/ subdir is an unsupported-layout ERROR (no bogus depth advice)"
else
  bad "nested references/ subdir not flagged as unsupported layout (rc=$rc)"
fi

# flat sibling must still behave exactly as in (C) — the nested file is the only
# defect, so removing it restores a clean bill
rm -rf "$FIXTURE_DIR/references/sub"
out="$(bash "$VALIDATE" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ERRORS: 0'; then
  pass "flat references/ file unaffected by the nested-layout check"
else
  bad "nested-layout check leaked onto the flat references/ file (rc=$rc)"
fi

# ── (D) regression guard: repo without the fixture stays clean ───────────────
# The 3 legitimately root-anchored ../../ users (plan/agents/plan-reviewer.md,
# write-tests/agents/test-quality-reviewer.md, execute/agents/quality-reviewer.md)
# live under agents/, NOT references/ — they must remain unaffected.
rm -rf "$FIXTURE_DIR"
out="$(bash "$VALIDATE" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'ERRORS: 0'; then
  pass "untouched repo still validates clean (ERRORS: 0)"
else
  bad "validator regressed on the untouched repo (rc=$rc)"
fi

# ── (E) forbidden-token scan reaches references/ in a synthetic dist ─────────
mkdir -p "$TMP/dist/skills/$FIXTURE_SKILL/references"
cat > "$TMP/dist/skills/$FIXTURE_SKILL/references/bad.md" <<'EOF'
# Dispatch

Spawn the reviewer with run_in_background so the run does not block.
EOF

if grep -RnE "$TOKENS" "$TMP/dist"/skills/*/references/*.md >/dev/null 2>&1; then
  pass "build-style token scan matches a forbidden token in dist references/"
else
  bad "build-style token scan does NOT reach dist references/"
fi

# Extract the WHOLE tool_refs command substitution — from its opening line to
# the line closing it — instead of a fixed-size window. A fixed -A<N> window
# false-FAILS a correct script that merely spells the command across more lines,
# and the block bound keeps this strictly stronger than a whole-file grep: the
# glob must appear inside the token-scan command, not just somewhere in the file.
for script in build-codex-skills.sh build-cursor-skills.sh build-antigravity-skills.sh; do
  section="$(awk '
    /tool_refs=\$\(grep -rln/ { inblock = 1 }
    inblock                   { print }
    inblock && /\|\| true\)/  { exit }
  ' "$ROOT/scripts/$script" 2>/dev/null || true)"

  if [ -z "$section" ]; then
    bad "$script has no recognizable tool_refs token-scan block (assertion would be vacuous)"
    continue
  fi
  case "$section" in
    *'skills/*/references/*.md'*)
      pass "$script token-scan glob covers skills/*/references/*.md" ;;
    *)
      bad "$script token-scan glob does NOT cover skills/*/references/*.md" ;;
  esac
done

# ── (F) clean references file produces no match ──────────────────────────────
mkdir -p "$TMP/clean/skills/$FIXTURE_SKILL/references"
cat > "$TMP/clean/skills/$FIXTURE_SKILL/references/ok.md" <<'EOF'
# Dispatch

Spawn the reviewer sub-agent and wait for its verdict.
EOF

if grep -RnE "$TOKENS" "$TMP/clean"/skills/*/references/*.md >/dev/null 2>&1; then
  bad "token scan false-positives on a clean references file"
else
  pass "token scan is quiet on a clean references file"
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "SOME CHECKS FAILED"
exit 1
