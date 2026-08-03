#!/usr/bin/env bash
# Contract test for scripts/validate-skills.sh (Task 2 + Task 3 structural lint).
#
# Builds a synthetic skills/ tree with one broken skill per ERROR class, plus
# clean, exemption, and WARN fixtures, then asserts the two-tier severity
# output: ERRORs fail the run (exit 1), WARNs are advisory (do not fail).
# Task 3 adds: include-integrity (dangling ../../shared/includes|rules tokens)
# and count-consistency (declared skill counts vs actual dirs) — exercised via
# a dangling-include fixture and a second mini-repo fixture with count drift.
# Also runs the validator against the REAL repo and asserts a clean bill
# (exit 0, ERRORS: 0) so structural regressions are caught in CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
SCRIPT="$ROOT_DIR/scripts/validate-skills.sh"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

TMP="$(mktemp -d)"
TMP2="$(mktemp -d)"
TMP3="$(mktemp -d)"
EMPTYROOT="$(mktemp -d)"
# A copy of the script inside <dir>/scripts/ so its IMPLICIT root (dirname $0/..)
# is a tree with no skills/ — the only way to exercise the implicit-root branch.
IMPLICITROOT="$(mktemp -d)"
mkdir -p "$IMPLICITROOT/scripts"
cp "$SCRIPT" "$IMPLICITROOT/scripts/validate-skills.sh"
IMPLICIT_SCRIPT="$IMPLICITROOT/scripts/validate-skills.sh"
trap 'rm -rf "$TMP" "$TMP2" "$TMP3" "$EMPTYROOT" "$IMPLICITROOT"' EXIT

# real include files so include-resolution is exercised positively too
mkdir -p "$TMP/shared/includes"
echo "# Run Logger (fixture)" > "$TMP/shared/includes/run-logger.md"
echo "# Something Else (fixture)" > "$TMP/shared/includes/something-else.md"

# mkskill <dir-name> — writes stdin to $TMP/skills/<dir-name>/SKILL.md
mkskill() {
  local dir="$TMP/skills/$1"
  mkdir -p "$dir"
  cat > "$dir/SKILL.md"
}

# --- Fully clean skill (no ERROR, no WARN) ---
mkskill clean-skill <<'EOF'
---
name: clean-skill
description: "A fully valid clean skill fixture."
---

# zuvo:clean-skill — Clean Fixture

## Argument Parsing

Parse the invocation here.

## Mandatory File Loading

- ../../shared/includes/run-logger.md
EOF

# --- ERROR class (a): frontmatter missing name: field ---
mkskill no-name <<'EOF'
---
description: "Missing the name field entirely."
---

# zuvo:no-name

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF

# --- ERROR class (b): name: does not match directory ---
mkskill wrong-name <<'EOF'
---
name: other-thing
description: "Name field does not match the directory."
---

# zuvo:wrong-name

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF

# --- ERROR class (c): H1 is not # zuvo:<dirname> ---
mkskill bad-h1 <<'EOF'
---
name: bad-h1
description: "H1 heading is wrong."
---

# Bad H1

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF

# --- ERROR class (d): body contains literal {plugin_root} ---
mkskill has-plugin-root <<'EOF'
---
name: has-plugin-root
description: "Contains a literal plugin_root token."
---

# zuvo:has-plugin-root

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md

Body references {plugin_root}/skills which is banned.
EOF

# --- ERROR class (e): no run-logger include reference anywhere ---
# NB: the check greps for the literal 'run-logger.md' include filename. The
# body deliberately mentions bare 'run-logger' in prose to prove a mere
# mention does NOT satisfy the check (substring-bypass regression).
mkskill no-runlogger <<'EOF'
---
name: no-runlogger
description: "Omits the shared logging include entirely."
---

# zuvo:no-runlogger

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/something-else.md

Mentions run-logger in prose but never loads the include file.
EOF

# --- ERROR class (f): file does not start with a '---' fence ---
mkskill no-open-fence <<'EOF'
# zuvo:no-open-fence

No frontmatter at all — the file opens with the H1.

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF

# --- ERROR class (g): opening '---' fence but no closing '---' fence ---
mkskill no-close-fence <<'EOF'
---
name: no-close-fence
description: "Opening fence is never closed."

# zuvo:no-close-fence

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF

# --- ERROR class (h): valid name + H1 but no description: field ---
mkskill no-description <<'EOF'
---
name: no-description
---

# zuvo:no-description

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF

# --- ERROR class (i): dangling include reference (Task 3 include-integrity) ---
# Valid skill in every other respect; references an include that does not
# exist under the fixture root. run-logger.md DOES exist (positive resolution).
mkskill dangling-include <<'EOF'
---
name: dangling-include
description: "References an include file that does not exist."
---

# zuvo:dangling-include

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
- ../../shared/includes/does-not-exist.md
EOF

# --- ERROR class (j): non-canonical include depth in a SKILL.md-level file ---
# ../../../ is only filesystem-correct in agent-level files; in a SKILL.md it
# must be flagged (and must NOT be substring-truncated into a passing ../../).
mkskill deep-include <<'EOF'
---
name: deep-include
description: "References an include with too many ../ levels."
---

# zuvo:deep-include

## Argument Parsing
x
## Mandatory File Loading
- ../../../shared/includes/run-logger.md
EOF

# --- ERROR class (k): too-shallow include depth (single ../) in a SKILL.md ---
mkskill shallow-include <<'EOF'
---
name: shallow-include
description: "References an include with too few ../ levels."
---

# zuvo:shallow-include

## Argument Parsing
x
## Mandatory File Loading
- ../shared/includes/run-logger.md
EOF

# --- ERROR class (l): 4-deep include depth in a SKILL.md ---
mkskill too-deep-include <<'EOF'
---
name: too-deep-include
description: "References an include with four ../ levels."
---

# zuvo:too-deep-include

## Argument Parsing
x
## Mandatory File Loading
- ../../../../shared/includes/run-logger.md
EOF

# --- ERROR class (m): dangling ../../../ include at AGENT depth ---
# ../../../ is canonical in agents/*.md, but the target must still resolve.
mkskill agent-dangle <<'EOF'
---
name: agent-dangle
description: "Valid skill whose agent references a dangling deep include."
---

# zuvo:agent-dangle

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF
mkdir -p "$TMP/skills/agent-dangle/agents"
cat > "$TMP/skills/agent-dangle/agents/deep-dangle.md" <<'EOF'
# Deep Dangle Agent

Load ../../../shared/includes/does-not-exist-agent.md before starting.
EOF

# --- Positive agent-depth fixture: ../../../ IS canonical in agents/*.md ---
# (matches the real repo, e.g. skills/refactor/agents/cq-auditor.md); lives
# under clean-skill so any false ERROR would trip the clean-skill assertion.
mkdir -p "$TMP/skills/clean-skill/agents"
cat > "$TMP/skills/clean-skill/agents/helper.md" <<'EOF'
# Helper Agent

Load ../../../shared/includes/run-logger.md before starting.
EOF

# --- Exemption fixture: using-zuvo (router H1, no run-logger/argparse/mfl) ---
mkskill using-zuvo <<'EOF'
---
name: using-zuvo
description: "The Zuvo skill router; exempt from H1, run-logger, and arg-parsing."
---

# Zuvo Skill Router

Routing content only. No arg parsing, no run-logger, no file loading.
EOF

# --- Exemption fixture: worktree (valid H1, no run-logger/argparse/mfl) ---
mkskill worktree <<'EOF'
---
name: worktree
description: "Worktree isolation; exempt from run-logger, arg-parsing, and MFL."
---

# zuvo:worktree

Body without run-logger, arg parsing, or a file-loading section.
EOF

# --- WARN fixture: valid but no arg-parsing signal ---
mkskill no-argparse <<'EOF'
---
name: no-argparse
description: "Valid, has run-logger + MFL, but no arg-parsing signal."
---

# zuvo:no-argparse

## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF

# --- WARN fixture: valid but no Mandatory File Loading section ---
# The include here must be a START-of-run one. 8ca7d9e taught check_mfl that a skill whose ONLY
# shared includes are retrospective.md / run-logger.md has nothing to load at start (both run at
# completion), so demanding an MFL block there would document something untrue — it passes with a
# stated reason. This fixture referenced run-logger.md alone and therefore stopped exercising the
# warning it exists to prove, silently, for 12 commits. It now loads a real start-of-run include.
mkskill no-mfl <<'EOF'
---
name: no-mfl
description: "Valid, has arg-parsing and loads a start-of-run include, but no MFL section."
---

# zuvo:no-mfl

## Argument Parsing
x

Loads ../../shared/includes/something-else.md during discovery, and
../../shared/includes/run-logger.md for logging.
EOF

# ---------- run the validator against the fixture tree ----------
set +e
FIX_OUT="$(bash "$SCRIPT" --root "$TMP" 2>&1)"
FIX_RC=$?
set -e

[ "$FIX_RC" -eq 1 ] || fail "fixture run should exit 1, got $FIX_RC (output: $FIX_OUT)"
pass "fixture run exits 1 (ERRORs present)"

ERR_LINES="$(printf '%s\n' "$FIX_OUT" | grep '^ERROR:' || true)"
WARN_LINES="$(printf '%s\n' "$FIX_OUT" | grep '^WARN:' || true)"

# every broken skill must surface at least one ERROR naming it
for name in no-name wrong-name bad-h1 has-plugin-root no-runlogger \
            no-open-fence no-close-fence no-description dangling-include \
            deep-include shallow-include too-deep-include agent-dangle; do
  printf '%s\n' "$ERR_LINES" | grep -Fq -- "$name" \
    || fail "expected an ERROR mentioning '$name' (errors: $ERR_LINES)"
done
pass "each of the 13 broken skills produced an ERROR"

# the dangling-include ERROR must contain the dangling path itself
printf '%s\n' "$ERR_LINES" | grep -Fq -- "../../shared/includes/does-not-exist.md" \
  || fail "expected the dangling include path in an ERROR line (errors: $ERR_LINES)"
pass "dangling include ERROR names the unresolved path"

# the deep-include ERROR must be the non-canonical-depth class with the token
printf '%s\n' "$ERR_LINES" | grep -F -- "non-canonical include depth" \
  | grep -Fq -- "../../../shared/includes/run-logger.md" \
  || fail "expected a non-canonical-depth ERROR with the ../../../ token (errors: $ERR_LINES)"
pass "SKILL.md-level ../../../ include produces the non-canonical-depth ERROR"

# depth-branch coverage: shallow (../) and 4-deep are non-canonical too
printf '%s\n' "$ERR_LINES" | grep -F -- "shallow-include" \
  | grep -Fq -- "non-canonical include depth" \
  || fail "expected shallow-include's ERROR to be non-canonical-depth (errors: $ERR_LINES)"
printf '%s\n' "$ERR_LINES" | grep -F -- "too-deep-include" \
  | grep -Fq -- "non-canonical include depth" \
  || fail "expected too-deep-include's ERROR to be non-canonical-depth (errors: $ERR_LINES)"
pass "shallow (../) and 4-deep includes produce non-canonical-depth ERRORs"

# agent-depth dangling: ../../../ accepted in agents/ but must still resolve
printf '%s\n' "$ERR_LINES" | grep -F -- "agent-dangle" \
  | grep -F -- "dangling include" \
  | grep -Fq -- "does-not-exist-agent.md" \
  || fail "expected a dangling-include ERROR at agent depth (errors: $ERR_LINES)"
pass "dangling ../../../ include at agent depth produces a dangling-include ERROR"

# clean / exemption / WARN fixtures must NOT produce any ERROR
for name in clean-skill using-zuvo worktree no-argparse no-mfl; do
  if printf '%s\n' "$ERR_LINES" | grep -Fq -- "$name"; then
    fail "unexpected ERROR mentioning '$name' (errors: $ERR_LINES)"
  fi
done
pass "clean/exempt/WARN fixtures produced no ERROR"

# WARN fixtures must surface WARN lines
for name in no-argparse no-mfl; do
  printf '%s\n' "$WARN_LINES" | grep -Fq -- "$name" \
    || fail "expected a WARN mentioning '$name' (warns: $WARN_LINES)"
done
pass "no-argparse and no-mfl produced WARN lines"

# exempt fixtures must be fully silent — zero WARN lines too, not just zero ERROR
for name in using-zuvo worktree; do
  if printf '%s\n' "$WARN_LINES" | grep -Fq -- "$name"; then
    fail "unexpected WARN mentioning exempt skill '$name' (warns: $WARN_LINES)"
  fi
done
pass "using-zuvo and worktree produced zero WARN lines"

# ---------- CLI arg handling (exit 2 on user error) ----------
set +e
BADROOT_OUT="$(bash "$SCRIPT" --root /nonexistent/path 2>&1)"
BADROOT_RC=$?
set -e
[ "$BADROOT_RC" -eq 2 ] || fail "--root /nonexistent/path should exit 2, got $BADROOT_RC (output: $BADROOT_OUT)"
printf '%s\n' "$BADROOT_OUT" | grep -Fq -- "--root path does not exist" \
  || fail "--root /nonexistent/path should report a does-not-exist error (output: $BADROOT_OUT)"
pass "--root with nonexistent path exits 2 with error message"

set +e
BOGUS_OUT="$(bash "$SCRIPT" --bogus 2>&1)"
BOGUS_RC=$?
set -e
[ "$BOGUS_RC" -eq 2 ] || fail "--bogus should exit 2, got $BOGUS_RC (output: $BOGUS_OUT)"
printf '%s\n' "$BOGUS_OUT" | grep -Fq -- "unknown argument: --bogus" \
  || fail "--bogus should report an unknown-argument error (output: $BOGUS_OUT)"
pass "unknown flag --bogus exits 2 with error message"

set +e
EXTRA_OUT="$(bash "$SCRIPT" --root "$TMP" --strict 2>&1)"
EXTRA_RC=$?
set -e
[ "$EXTRA_RC" -eq 2 ] || fail "--root \$TMP --strict should exit 2, got $EXTRA_RC (output: $EXTRA_OUT)"
printf '%s\n' "$EXTRA_OUT" | grep -Fq -- "unexpected extra arguments" \
  || fail "trailing args should report an unexpected-extra-arguments error (output: $EXTRA_OUT)"
pass "trailing args after --root <dir> exit 2 with error message"

set +e
NOVAL_OUT="$(bash "$SCRIPT" --root 2>&1)"
NOVAL_RC=$?
set -e
[ "$NOVAL_RC" -eq 2 ] || fail "bare --root (no value) should exit 2, got $NOVAL_RC (output: $NOVAL_OUT)"
printf '%s\n' "$NOVAL_OUT" | grep -Fq -- "--root requires a value" \
  || fail "bare --root should report a requires-a-value error (output: $NOVAL_OUT)"
pass "bare --root without a value exits 2 with error message"

# A repeated --root used to silently last-win with no complaint. Reject it
# like every other malformed invocation.
set +e
DUPROOT_OUT="$(bash "$SCRIPT" --root "$TMP" --root "$TMP2" 2>&1)"
DUPROOT_RC=$?
set -e
[ "$DUPROOT_RC" -eq 2 ] || fail "a repeated --root flag should exit 2, got $DUPROOT_RC (output: $DUPROOT_OUT)"
printf '%s\n' "$DUPROOT_OUT" | grep -Fq -- "--root specified more than once" \
  || fail "a repeated --root flag should report a specified-more-than-once error (output: $DUPROOT_OUT)"
pass "a second --root flag exits 2 instead of silently last-winning"

set +e
NOSKILLS_OUT="$(bash "$SCRIPT" --root "$EMPTYROOT" 2>&1)"
NOSKILLS_RC=$?
set -e
[ "$NOSKILLS_RC" -eq 2 ] || fail "--root <existing-dir-without-skills/> should exit 2, got $NOSKILLS_RC (output: $NOSKILLS_OUT)"
printf '%s\n' "$NOSKILLS_OUT" | grep -Fq -- "no skills/ directory" \
  || fail "explicit root without skills/ should report the no-skills error (output: $NOSKILLS_OUT)"
pass "explicit --root without a skills/ dir exits 2 with error message"

# ---------- Task 3: count-consistency mini-repo fixture ----------
# 2 actual skill dirs (alpha + using-zuvo); every count-declaring source says
# 2 EXCEPT .claude-plugin/plugin.json which drifts to 3.
mkdir -p "$TMP2/skills/alpha" "$TMP2/skills/using-zuvo" \
         "$TMP2/shared/includes" "$TMP2/.claude-plugin" "$TMP2/.codex-plugin" "$TMP2/docs"
echo "# Run Logger (fixture)" > "$TMP2/shared/includes/run-logger.md"

cat > "$TMP2/skills/alpha/SKILL.md" <<'EOF'
---
name: alpha
category: Core
description: "Tiny valid fixture skill."
---

# zuvo:alpha

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF

cat > "$TMP2/skills/using-zuvo/SKILL.md" <<'EOF'
---
name: using-zuvo
category: Utility
description: "Mini router fixture with banner and routing table."
---

# Zuvo Skill Router

> **Zuvo v9.9** | 2 skills | fixture banner

## Routing Table

| Intent | Skill |
|--------|-------|
| build stuff | `zuvo:alpha` |
| ad-hoc label | `zuvo:adhoc-approved` |

## Next Section

Nothing else.
EOF

cat > "$TMP2/.claude-plugin/plugin.json" <<'EOF'
{
  "description": "Fixture ecosystem. 3 skills with quality gates."
}
EOF

# NESTED interface.longDescription — mirrors the real .codex-plugin manifest
cat > "$TMP2/.codex-plugin/plugin.json" <<'EOF'
{
  "description": "Fixture ecosystem. 2 skills with quality gates.",
  "interface": {
    "longDescription": "Long form: 2 skills across fixture categories."
  }
}
EOF

cat > "$TMP2/package.json" <<'EOF'
{
  "description": "Fixture ecosystem. 2 skills with quality gates."
}
EOF

cat > "$TMP2/docs/skills.md" <<'EOF'
# Skills Reference

Fixture includes 2 skills organized into 2 categories.

| Category | Count | Skills |
|----------|-------|--------|
| Core | 1 | alpha |
| Utility | 1 | using-zuvo |
| **Total** | **2** | |
EOF

# write_tmp2_claude_md — the mini-repo's CLAUDE.md fixture, restorable to its
# "honest" (matching) table state from anywhere below.
#
# Shape MUST mirror the REAL CLAUDE.md, not docs/skills.md's shape: the real
# CLAUDE.md's '## Skill categories' table has NO '**Total**' row — it ends at
# the next '## ' heading ('## Common tasks'), which is followed by an
# UNRELATED '| Task | Command |' table. docs/skills.md's table, by contrast,
# DOES end with a '**Total**' row. category_rows() in scripts/validate-skills.sh
# has to terminate correctly on BOTH shapes (heading-terminated AND
# Total-terminated); a previous fix added the heading-termination rule
# specifically because, without it, "scan to Total-or-EOF" ran past the real
# CLAUDE.md table into '## Common tasks' and invented bogus categories like
# "Periodic deep audit: 453" from that unrelated table's rows.
#
# If this fixture's CLAUDE.md merely ended at EOF right after its table (as it
# used to), the heading-termination branch would never be exercised here at
# all — EOF stops the awk loop either way, termination-rule or not, so a
# regression that deletes the heading-termination rule would NOT be caught by
# this fixture. Appending a real trailing heading + an unrelated pipe table
# (mirroring "Periodic deep audit: 453" exactly) means a broken termination
# rule would inflate this fixture's category sum/tally and fail the very
# assertions built on top of this function — the same way it would on the
# real repo.
write_tmp2_claude_md() {
  cat > "$TMP2/CLAUDE.md" <<'EOF'
# Fixture Guide

skills/<name>/SKILL.md — skill definitions (2 total)

## Skill categories (2 total)

| Category | Count | Skills |
|----------|-------|--------|
| Core | 1 | alpha |
| Utility | 1 | using-zuvo |

## Common tasks

| Task | Command |
|------|---------|
| Periodic deep audit | 453 |
EOF
}
write_tmp2_claude_md

set +e
DRIFT_OUT="$(bash "$SCRIPT" --root "$TMP2" 2>&1)"
DRIFT_RC=$?
set -e
[ "$DRIFT_RC" -eq 1 ] || fail "count-drift fixture should exit 1, got $DRIFT_RC (output: $DRIFT_OUT)"
printf '%s\n' "$DRIFT_OUT" | grep '^ERROR:' | grep -Fq -- ".claude-plugin/plugin.json" \
  || fail "expected a count ERROR naming .claude-plugin/plugin.json (output: $DRIFT_OUT)"
pass "count drift (3 declared vs 2 actual) produces ERROR naming the drifted file"

# fully consistent variant: fix the drifted file -> zero count ERRORs, both OK lines
cat > "$TMP2/.claude-plugin/plugin.json" <<'EOF'
{
  "description": "Fixture ecosystem. 2 skills with quality gates."
}
EOF
set +e
CONSIST_OUT="$(bash "$SCRIPT" --root "$TMP2" 2>&1)"
CONSIST_RC=$?
set -e
[ "$CONSIST_RC" -eq 0 ] || fail "consistent mini-repo should exit 0, got $CONSIST_RC (output: $CONSIST_OUT)"
printf '%s\n' "$CONSIST_OUT" | grep -Fq -- "ERRORS: 0" \
  || fail "consistent mini-repo should report ERRORS: 0 (output: $CONSIST_OUT)"
printf '%s\n' "$CONSIST_OUT" | grep -Fq -- "count-consistency: OK (2)" \
  || fail "consistent mini-repo should print 'count-consistency: OK (2)' (output: $CONSIST_OUT)"
printf '%s\n' "$CONSIST_OUT" | grep -Fq -- "include-integrity: OK" \
  || fail "consistent mini-repo should print 'include-integrity: OK' (output: $CONSIST_OUT)"
pass "fully consistent mini-repo passes with both OK lines"

# POSITIVE category fixture: both skills declare a category that matches both
# tables, so the per-category check must be silent and print its own OK line.
if printf '%s\n' "$CONSIST_OUT" | grep '^ERROR:' | grep -Fq -- "category-consistency"; then
  fail "matching categories should produce zero category ERRORs (output: $CONSIST_OUT)"
fi
printf '%s\n' "$CONSIST_OUT" | grep -Fxq -- "category-consistency: OK (2 categories)" \
  || fail "consistent mini-repo should print exactly 'category-consistency: OK (2 categories)' (output: $CONSIST_OUT)"
pass "matching frontmatter categories produce zero ERRORs and the OK (2) line"

# nested-drift variant: interface.longDescription (NESTED) says 3 → must be
# caught, proving the dotted-path extraction is not inert on nested keys
cat > "$TMP2/.codex-plugin/plugin.json" <<'EOF'
{
  "description": "Fixture ecosystem. 2 skills with quality gates.",
  "interface": {
    "longDescription": "Long form: 3 skills across fixture categories."
  }
}
EOF
set +e
NESTED_OUT="$(bash "$SCRIPT" --root "$TMP2" 2>&1)"
NESTED_RC=$?
set -e
[ "$NESTED_RC" -eq 1 ] || fail "nested longDescription drift should exit 1, got $NESTED_RC (output: $NESTED_OUT)"
printf '%s\n' "$NESTED_OUT" | grep '^ERROR:' | grep -F -- ".codex-plugin/plugin.json" \
  | grep -Fq -- "interface.longDescription" \
  || fail "expected a count ERROR naming .codex-plugin/plugin.json interface.longDescription (output: $NESTED_OUT)"
pass "NESTED interface.longDescription drift (3 vs 2) produces ERROR naming the file"

# ---------- category-consistency: per-category counts vs SKILL.md frontmatter ----------
# The Count column of the '| Category | Count |' tables was only ever SUMMED by
# count-consistency, never COMPARED against anything, so a row could claim any
# distribution as long as the total held. These cases pin the comparison.
#
# The .codex-plugin manifest is restored to the consistent (2 skills) form first
# so every exit code below is attributable to the category checks alone.
cat > "$TMP2/.codex-plugin/plugin.json" <<'EOF'
{
  "description": "Fixture ecosystem. 2 skills with quality gates.",
  "interface": {
    "longDescription": "Long form: 2 skills across fixture categories."
  }
}
EOF

# (d) anchor-absent skip, RESERVED for roots where NEITHER docs/skills.md nor
# CLAUDE.md exists — the fixture-root case. $TMP is exactly that root, so the
# check must stay silent about categories rather than inventing 17 "missing
# category" ERRORs. (A root where those files EXIST but lost their table is a
# defect, not a skip — asserted further down.)
#
# Re-run fresh rather than reusing $FIX_OUT/$ERR_LINES (captured once, far
# above, before a long run of --root $TMP2 fixture edits): $TMP itself is
# never mutated after its initial construction so those old captures are not
# WRONG here, but asserting against a re-run is what actually proves this
# behavior at the point it is being tested, instead of trusting a possibly
# stale capture from a different part of the file.
[ ! -e "$TMP/docs/skills.md" ] && [ ! -e "$TMP/CLAUDE.md" ] \
  || fail "fixture root \$TMP must contain NEITHER category-table file for the n/a skip to be the thing under test"
set +e
NA_OUT="$(bash "$SCRIPT" --root "$TMP" 2>&1)"
NA_RC=$?
set -e
[ "$NA_RC" -eq 1 ] || fail "\$TMP re-run should still exit 1 (the non-category ERROR classes are still present), got $NA_RC (output: $NA_OUT)"
if printf '%s\n' "$NA_OUT" | grep '^ERROR:' | grep -Fq -- "category-consistency"; then
  fail "no-category-table root must produce zero category ERRORs (output: $NA_OUT)"
fi
printf '%s\n' "$NA_OUT" | grep -Fq -- "category-consistency: n/a (no category table in $TMP; per-skill 'category:' presence/label checks were skipped too)" \
  || fail "no-category-table root should print the n/a skip line stating per-skill category checks were ALSO skipped (output: $NA_OUT)"
pass "root with NEITHER category-table file skips category-consistency (n/a, zero ERRORs, and states per-skill checks were skipped too)"

# (b) the Count column disagrees with the frontmatter tally (sum unchanged, so
# only the per-category comparison can catch it)
#
# CLAUDE.md is explicitly restored to its known-good table FIRST, so this case
# proves something a lone docs/skills.md edit cannot: that the ERROR names
# ONLY the drifted file. Without a known-good CLAUDE.md asserted right here,
# a docs/skills.md-only edit can only show that AN error appears somewhere —
# it cannot show that CLAUDE.md (undrifted) stays silent, which is asserted
# explicitly below.
write_tmp2_claude_md
cat > "$TMP2/docs/skills.md" <<'EOF'
# Skills Reference

Fixture includes 2 skills organized into 2 categories.

| Category | Count | Skills |
|----------|-------|--------|
| Core | 2 | alpha |
| Utility | 0 | using-zuvo |
| **Total** | **2** | |
EOF
set +e
CAT_DRIFT_OUT="$(bash "$SCRIPT" --root "$TMP2" 2>&1)"
CAT_DRIFT_RC=$?
set -e
[ "$CAT_DRIFT_RC" -eq 1 ] || fail "category count drift should exit 1, got $CAT_DRIFT_RC (output: $CAT_DRIFT_OUT)"
printf '%s\n' "$CAT_DRIFT_OUT" | grep '^ERROR:' | grep -F -- "docs/skills.md" \
  | grep -Fq -- "Core" \
  || fail "expected a category ERROR naming docs/skills.md and the 'Core' label (output: $CAT_DRIFT_OUT)"
if printf '%s\n' "$CAT_DRIFT_OUT" | grep '^ERROR:' | grep -Fq -- "CLAUDE.md"; then
  fail "CLAUDE.md carries a known-good table and must stay silent while only docs/skills.md drifts (output: $CAT_DRIFT_OUT)"
fi
pass "per-category drift (Core 2 vs 1, total still 2) produces ERROR naming docs/skills.md, while CLAUDE.md (known-good) stays silent"

# restore the honest table
cat > "$TMP2/docs/skills.md" <<'EOF'
# Skills Reference

Fixture includes 2 skills organized into 2 categories.

| Category | Count | Skills |
|----------|-------|--------|
| Core | 1 | alpha |
| Utility | 1 | using-zuvo |
| **Total** | **2** | |
EOF

# (c) a skill with no category: at all
cat > "$TMP2/skills/alpha/SKILL.md" <<'EOF'
---
name: alpha
description: "Tiny valid fixture skill."
---

# zuvo:alpha

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF
set +e
CAT_MISSING_OUT="$(bash "$SCRIPT" --root "$TMP2" 2>&1)"
CAT_MISSING_RC=$?
set -e
[ "$CAT_MISSING_RC" -eq 1 ] || fail "undeclared category should exit 1, got $CAT_MISSING_RC (output: $CAT_MISSING_OUT)"
printf '%s\n' "$CAT_MISSING_OUT" | grep '^ERROR:' | grep -F -- "alpha" \
  | grep -Fq -- "missing 'category:'" \
  || fail "expected a 'missing category:' ERROR naming alpha (output: $CAT_MISSING_OUT)"
pass "a skill without 'category:' produces an ERROR naming that skill"

# a category that is not a row in the table is its own ERROR class
cat > "$TMP2/skills/alpha/SKILL.md" <<'EOF'
---
name: alpha
category: Not A Real Category
description: "Tiny valid fixture skill."
---

# zuvo:alpha

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF
set +e
CAT_UNKNOWN_OUT="$(bash "$SCRIPT" --root "$TMP2" 2>&1)"
CAT_UNKNOWN_RC=$?
set -e
[ "$CAT_UNKNOWN_RC" -eq 1 ] || fail "unknown category should exit 1, got $CAT_UNKNOWN_RC (output: $CAT_UNKNOWN_OUT)"
printf '%s\n' "$CAT_UNKNOWN_OUT" | grep '^ERROR:' | grep -F -- "alpha" \
  | grep -Fq -- "Not A Real Category" \
  || fail "expected an ERROR naming alpha and its unknown category (output: $CAT_UNKNOWN_OUT)"
pass "a category with no matching table row produces an ERROR naming skill and label"

# (e) DELETED table in a file that EXISTS is an ERROR, never the n/a skip.
# The skip used to be keyed on "zero tables found", which covered this case too:
# deleting the '| Category | Count |' table from docs/skills.md AND CLAUDE.md
# silently disabled every per-category assertion and the run still printed green.
# The n/a skip is now reserved for roots where NEITHER file exists ($TMP above).
cat > "$TMP2/skills/alpha/SKILL.md" <<'EOF'
---
name: alpha
category: Core
description: "Tiny valid fixture skill."
---

# zuvo:alpha

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF
cat > "$TMP2/docs/skills.md" <<'EOF'
# Skills Reference

Fixture includes 2 skills organized into 2 categories.
EOF
cat > "$TMP2/CLAUDE.md" <<'EOF'
# Fixture Guide

skills/<name>/SKILL.md — skill definitions (2 total)
EOF
set +e
NOTABLE_OUT="$(bash "$SCRIPT" --root "$TMP2" 2>&1)"
NOTABLE_RC=$?
set -e
[ "$NOTABLE_RC" -eq 1 ] || fail "mini-repo whose EXISTING docs lost their category table should exit 1, got $NOTABLE_RC (output: $NOTABLE_OUT)"
for f in "docs/skills.md" "CLAUDE.md"; do
  printf '%s\n' "$NOTABLE_OUT" | grep '^ERROR:' | grep -F -- "category-consistency" \
    | grep -Fq -- "$f" \
    || fail "expected a category-consistency ERROR naming '$f' as existing-without-a-table (output: $NOTABLE_OUT)"
done
if printf '%s\n' "$NOTABLE_OUT" | grep -Fq -- "category-consistency: n/a"; then
  fail "a root whose category-table FILES exist must never degrade to n/a (output: $NOTABLE_OUT)"
fi
pass "deleting the table from files that exist is an ERROR naming each file, never the n/a skip"

# restore both honest tables — every case below is attributable to its own edit
# (write_tmp2_claude_md is defined once, above, right before its first use)
write_tmp2_claude_md

# (f) a BLANK LINE inside the table must not truncate the walk. The walker left
# the table on the first non-matching line, so every row after a stray blank was
# silently dropped — a partial tally that still compared "successfully" (here:
# Utility would vanish, and using-zuvo's category would read as undeclared).
cat > "$TMP2/docs/skills.md" <<'EOF'
# Skills Reference

Fixture includes 2 skills organized into 2 categories.

| Category | Count | Skills |
|----------|-------|--------|
| Core | 1 | alpha |

| Utility | 1 | using-zuvo |
| **Total** | **2** | |
EOF
set +e
BLANKROW_OUT="$(bash "$SCRIPT" --root "$TMP2" 2>&1)"
BLANKROW_RC=$?
set -e
[ "$BLANKROW_RC" -eq 0 ] || fail "a blank line inside the category table should not change the verdict, got rc $BLANKROW_RC (output: $BLANKROW_OUT)"
if printf '%s\n' "$BLANKROW_OUT" | grep '^ERROR:' | grep -Fq -- "Utility"; then
  fail "rows after a blank line inside the table must still be parsed (output: $BLANKROW_OUT)"
fi
printf '%s\n' "$BLANKROW_OUT" | grep -Fxq -- "category-consistency: OK (2 categories)" \
  || fail "blank-line table should still yield exactly 'category-consistency: OK (2 categories)' (output: $BLANKROW_OUT)"
pass "a blank line inside the category table does not truncate row parsing"

# (f2) a STRAY PROSE line (non-blank, non-table-row) inside the table is the
# SAME defect class as the blank-line case above, half-fixed: the walker used
# to leave the table on ANY non-matching line, silently dropping every row
# after it into a partial tally that still compared "successfully". Rows after
# it must still be parsed, AND the malformed table must be reported LOUD — an
# ERROR naming the file and the offending line number — rather than silently
# accepted as a valid partial table.
cat > "$TMP2/docs/skills.md" <<'EOF'
# Skills Reference

Fixture includes 2 skills organized into 2 categories.

| Category | Count | Skills |
|----------|-------|--------|
| Core | 1 | alpha |
This is a stray line of prose, not a table row.
| Utility | 1 | using-zuvo |
| **Total** | **2** | |
EOF
set +e
STRAYROW_OUT="$(bash "$SCRIPT" --root "$TMP2" 2>&1)"
STRAYROW_RC=$?
set -e
[ "$STRAYROW_RC" -eq 1 ] || fail "a stray prose line inside the category table should be flagged (exit 1), got rc $STRAYROW_RC (output: $STRAYROW_OUT)"
if printf '%s\n' "$STRAYROW_OUT" | grep '^ERROR:' | grep -Fq -- "not a row of the category table"; then
  fail "rows after a stray prose line inside the table must still be parsed — 'Utility' must not read as an unknown category (output: $STRAYROW_OUT)"
fi
printf '%s\n' "$STRAYROW_OUT" | grep '^ERROR:' | grep -F -- "docs/skills.md" | grep -F -- "malformed table" | grep -Fq -- "line 8" \
  || fail "expected a malformed-table ERROR naming docs/skills.md and line 8 (output: $STRAYROW_OUT)"
pass "a stray prose line inside the category table does not truncate row parsing, and produces a loud ERROR naming the file and line"

# restore the honest table for subsequent cases
cat > "$TMP2/docs/skills.md" <<'EOF'
# Skills Reference

Fixture includes 2 skills organized into 2 categories.

| Category | Count | Skills |
|----------|-------|--------|
| Core | 1 | alpha |
| Utility | 1 | using-zuvo |
| **Total** | **2** | |
EOF

# (g) a DUPLICATE label is an ERROR (the chosen resolution over aggregating).
# The counts below are rigged so first-match-wins still compares "correctly"
# (Core=1, Utility=1, sum=2): without an explicit duplicate check this table
# passes silently while reading as two contradictory rows to any human.
cat > "$TMP2/docs/skills.md" <<'EOF'
# Skills Reference

Fixture includes 2 skills organized into 2 categories.

| Category | Count | Skills |
|----------|-------|--------|
| Core | 1 | alpha |
| Core | 0 | alpha again |
| Utility | 1 | using-zuvo |
| **Total** | **2** | |
EOF
set +e
DUP_OUT="$(bash "$SCRIPT" --root "$TMP2" 2>&1)"
DUP_RC=$?
set -e
[ "$DUP_RC" -eq 1 ] || fail "a duplicated category row should exit 1, got $DUP_RC (output: $DUP_OUT)"
printf '%s\n' "$DUP_OUT" | grep '^ERROR:' | grep -F -- "docs/skills.md" \
  | grep -F -- "more than one row" | grep -Fq -- "Core" \
  || fail "expected a duplicate-label ERROR naming docs/skills.md and 'Core' (output: $DUP_OUT)"
pass "a category label repeated across rows produces an ERROR naming the label"

# (h) ONE header anchor, two consumers (CQ14): has_category_table (grep -E) and
# category_rows (awk) must agree on the SAME synthetic header line. This header
# is a spacing variant ('|Category|Count|Skills|'); if the two expressions had
# drifted, one of them would miss it and the failure mode would be a DIFFERENT
# ERROR class — either "exists but has no ... table" (grep missed it) or
# "'Core' is not a row of the category table" (awk missed it). Asserting the
# per-category DRIFT message proves both matched the same line.
cat > "$TMP2/docs/skills.md" <<'EOF'
# Skills Reference

Fixture includes 2 skills organized into 2 categories.

|Category|Count|Skills|
|--------|-----|------|
|Core|2|alpha|
|Utility|0|using-zuvo|
|**Total**|**2**||
EOF
set +e
HDR_OUT="$(bash "$SCRIPT" --root "$TMP2" 2>&1)"
HDR_RC=$?
set -e
[ "$HDR_RC" -eq 1 ] || fail "spacing-variant header with a drifted count should exit 1, got $HDR_RC (output: $HDR_OUT)"
printf '%s\n' "$HDR_OUT" | grep '^ERROR:' | grep -F -- "docs/skills.md" \
  | grep -F -- "category 'Core' says 2" | grep -Fq -- "tally is 1" \
  || fail "expected the per-category drift ERROR on a spacing-variant header — both anchors must match the same header line (output: $HDR_OUT)"
if printf '%s\n' "$HDR_OUT" | grep '^ERROR:' | grep -Fq -- "has no '| Category | Count |' table"; then
  fail "grep and awk anchors disagree: the header was matched by one consumer and not the other (output: $HDR_OUT)"
fi
pass "grep and awk header anchors agree on a synthetic spacing-variant header line"

# ---------- (i) a SECOND '| Category | Count |' table anchor in one file ----------
# Both category_rows (category-consistency) and sum_category_table (count-
# consistency) are ONE walker whose awk state machine locks onto the FIRST
# header match and never re-arms, so a second table anywhere below it used to
# be silently invisible — its rows counted nowhere, compared against nothing.
# A minimal, separate mini-repo (not $TMP2, which is mid-flight through many
# other cases) with exactly one skill and a docs/skills.md containing TWO
# anchors isolates this to a single defect class.
mkdir -p "$TMP3/skills/only-skill" "$TMP3/shared/includes" "$TMP3/docs"
echo "# Run Logger (fixture)" > "$TMP3/shared/includes/run-logger.md"
cat > "$TMP3/skills/only-skill/SKILL.md" <<'EOF'
---
name: only-skill
category: Core
description: "Fixture skill for the duplicate-category-table-anchor test."
---

# zuvo:only-skill

## Argument Parsing
x
## Mandatory File Loading
- ../../shared/includes/run-logger.md
EOF
cat > "$TMP3/docs/skills.md" <<'EOF'
# Skills Reference

Fixture with a duplicated category-table header.

| Category | Count | Skills |
|----------|-------|--------|
| Core | 1 | only-skill |
| **Total** | **1** | |

## Another Table (must be flagged, not silently ignored)

| Category | Count | Skills |
|----------|-------|--------|
| Core | 1 | only-skill |
| **Total** | **1** | |
EOF
set +e
DUPANCHOR_OUT="$(bash "$SCRIPT" --root "$TMP3" 2>&1)"
DUPANCHOR_RC=$?
set -e
[ "$DUPANCHOR_RC" -eq 1 ] || fail "a docs file with two '| Category | Count |' anchors should exit 1, got $DUPANCHOR_RC (output: $DUPANCHOR_OUT)"
printf '%s\n' "$DUPANCHOR_OUT" | grep '^ERROR:' | grep -F -- "docs/skills.md" | grep -Fq -- "table anchors" \
  || fail "expected an ERROR naming docs/skills.md and 'table anchors' for a duplicated category-table header (output: $DUPANCHOR_OUT)"
pass "a second '| Category | Count |' table anchor in the same file produces an ERROR naming the file, not silent ignoring"

# ---------- (f) --print-count ----------
# Machine-readable count for callers (docs/CI). It must answer even when the
# tree fails the lint, so it is asserted for its own exit code and output shape.
# Oracle matches the script's OWN definition of "a skill" (count_actual_skills:
# a skills/*/ dir that CONTAINS a SKILL.md), not "any directory under skills/".
# They agree today (every dir has one), so a plain `ls -d skills/*/` oracle
# passed for the wrong reason; a stray non-skill directory under skills/ would
# have failed this test with a misleading message pointing at the script
# instead of at the repo.
REAL_SKILL_DIRS=$(find "$ROOT_DIR/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')
set +e
PC_OUT="$(bash "$SCRIPT" --print-count 2>&1)"
PC_RC=$?
set -e
[ "$PC_RC" -eq 0 ] || fail "--print-count should exit 0, got $PC_RC (output: $PC_OUT)"
[ "$PC_OUT" = "$REAL_SKILL_DIRS" ] \
  || fail "--print-count should print exactly '$REAL_SKILL_DIRS', got '$PC_OUT'"
PC_LINES=$(bash "$SCRIPT" --print-count | wc -l | tr -d ' ')
[ "$PC_LINES" = "1" ] || fail "--print-count should print exactly one line, got $PC_LINES"
pass "--print-count prints exactly the skill count and exits 0"

set +e
PC_ROOT_OUT="$(bash "$SCRIPT" --print-count --root "$TMP2" 2>&1)"
PC_ROOT_RC=$?
set -e
[ "$PC_ROOT_RC" -eq 0 ] || fail "--print-count --root \$TMP2 should exit 0, got $PC_ROOT_RC (output: $PC_ROOT_OUT)"
[ "$PC_ROOT_OUT" = "2" ] || fail "--print-count --root \$TMP2 should print '2', got '$PC_ROOT_OUT'"
pass "--print-count honours --root"

set +e
PC_ROOT2_OUT="$(bash "$SCRIPT" --root "$TMP2" --print-count 2>&1)"
PC_ROOT2_RC=$?
set -e
[ "$PC_ROOT2_RC" -eq 0 ] || fail "--root \$TMP2 --print-count should exit 0, got $PC_ROOT2_RC (output: $PC_ROOT2_OUT)"
[ "$PC_ROOT2_OUT" = "2" ] || fail "--root \$TMP2 --print-count should print '2', got '$PC_ROOT2_OUT'"
pass "--print-count is recognised in either argument order (--root DIR --print-count)"

set +e
PC_EMPTY_OUT="$(bash "$SCRIPT" --print-count --root "$EMPTYROOT" 2>&1)"
PC_EMPTY_RC=$?
set -e
[ "$PC_EMPTY_RC" -eq 2 ] || fail "--print-count --root <dir-without-skills/> should exit 2, got $PC_EMPTY_RC (output: $PC_EMPTY_OUT)"
printf '%s\n' "$PC_EMPTY_OUT" | grep -Fq -- "no skills/ directory" \
  || fail "--print-count on a root without skills/ should report the no-skills error (output: $PC_EMPTY_OUT)"
pass "--print-count on an EXPLICIT root without skills/ exits 2 instead of printing 0"

# The IMPLICIT root (dirname $0/..) must behave IDENTICALLY. It did not: count-only
# mode fell through into the lint's "nothing to lint" success branch and printed a
# two-line summary with rc 0, so a caller doing N="$(validate-skills.sh --print-count)"
# silently bound N to lint prose while rc claimed success — the exact poisoning the
# flag exists to prevent.
#
# ONE invocation, not two: stdout and stderr are captured to separate sinks
# from the SAME process run (stdout via command substitution, stderr to a temp
# file), then both PC_IMPL_RC and PC_IMPL_OUT (the combined view the other
# assertions grep) are derived from that single run — a second invocation
# could not be guaranteed to observe the same state as the first.
PC_IMPL_ERRFILE="$(mktemp)"
set +e
PC_IMPL_STDOUT="$(bash "$IMPLICIT_SCRIPT" --print-count 2>"$PC_IMPL_ERRFILE")"
PC_IMPL_RC=$?
set -e
PC_IMPL_STDERR="$(cat "$PC_IMPL_ERRFILE")"
rm -f "$PC_IMPL_ERRFILE"
PC_IMPL_OUT="$PC_IMPL_STDOUT
$PC_IMPL_STDERR"
[ "$PC_IMPL_RC" -eq 2 ] || fail "--print-count with an IMPLICIT root lacking skills/ should exit 2, got $PC_IMPL_RC (output: $PC_IMPL_OUT)"
printf '%s\n' "$PC_IMPL_OUT" | grep -Fq -- "no skills/ directory" \
  || fail "--print-count with an implicit root lacking skills/ should report the no-skills error (output: $PC_IMPL_OUT)"
[ -z "$PC_IMPL_STDOUT" ] \
  || fail "--print-count must put NOTHING on stdout when it cannot answer, got '$PC_IMPL_STDOUT'"
if printf '%s\n' "$PC_IMPL_OUT" | grep -Eq '^(ERRORS: |WARN: )'; then
  fail "--print-count must never emit lint output on any path (output: $PC_IMPL_OUT)"
fi
pass "--print-count on an IMPLICIT root without skills/ exits 2 with an empty stdout, never lint prose"

# ...while the SAME implicit root WITHOUT --print-count keeps its documented
# lint behaviour (clean summary, exit 0) — the fix is scoped to count-only mode.
set +e
IMPL_LINT_OUT="$(bash "$IMPLICIT_SCRIPT" 2>&1)"
IMPL_LINT_RC=$?
set -e
[ "$IMPL_LINT_RC" -eq 0 ] || fail "implicit root without skills/ (no --print-count) should exit 0, got $IMPL_LINT_RC (output: $IMPL_LINT_OUT)"
printf '%s\n' "$IMPL_LINT_OUT" | grep -Fq -- "ERRORS: 0  WARNINGS: 0" \
  || fail "implicit root without skills/ should still print the clean summary (output: $IMPL_LINT_OUT)"
printf '%s\n' "$IMPL_LINT_OUT" | grep -Fq -- "nothing to lint" \
  || fail "implicit root without skills/ should still print the nothing-to-lint line (output: $IMPL_LINT_OUT)"
pass "implicit root without skills/ still lints to a clean exit 0 when --print-count is absent"

# both orders answer identically against the real repo
PC_ORDER_A="$(bash "$SCRIPT" --print-count --root "$ROOT_DIR")"
PC_ORDER_B="$(bash "$SCRIPT" --root "$ROOT_DIR" --print-count)"
[ "$PC_ORDER_A" = "$REAL_SKILL_DIRS" ] && [ "$PC_ORDER_B" = "$REAL_SKILL_DIRS" ] \
  || fail "both --print-count/--root orders should print '$REAL_SKILL_DIRS', got '$PC_ORDER_A' and '$PC_ORDER_B'"
pass "both --print-count/--root orders agree with the real skills/ dir count"

# ---------- run the validator against the REAL repo ----------
# number of real skills that declare a NON-EMPTY 'category:' inside their
# frontmatter window (same window fm_value reads: between the opening line and
# the closing '---').
#
# This mirrors scripts/validate-skills.sh's OWN fm_value()/strip() extraction
# rather than sourcing that script directly: validate-skills.sh is not written
# to be sourced — after its function definitions it unconditionally RUNS the
# full lint (check_frontmatter, check_categories, ...) and calls `exit 0`/
# `exit 1` at module scope, so `source`-ing it here would execute the whole
# lint pipeline as a side effect and then terminate THIS harness process via
# its exit call. Reproducing the extraction is the practical alternative; the
# awk below matches fm_value's frontmatter window (skip line 1, stop at the
# closing '---' fence) and its CRLF handling (`sub(/\r$/, "", v)`) exactly, and
# the quote-stripping afterward mirrors strip() exactly too. This is a
# meaningful behavioral difference from the old hand-rolled version, not just
# a style match: the old version counted a skill as "categorized" merely
# because a line matching /^category:/ existed, even if the value were empty
# (`category:` with nothing after it) or only quotes — a case the validator's
# own check_categories would flag as `missing 'category:'` (it gates on
# `[ -z "$label" ]` AFTER strip()). A hand-rolled reader that disagrees with
# the validator on that edge case is precisely the parallel-parser drift this
# fix exists to close.
count_declared_categories() {
  local n=0 f v
  for f in "$ROOT_DIR"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    v="$(awk '
        NR == 1                   { next }
        /^---[[:space:]]*$/       { exit }
        /^category:/              { v=$0; sub(/^category:[[:space:]]*/, "", v); sub(/\r$/, "", v); print v; exit }
      ' "$f")"
    # strip() equivalent: trim whitespace (already done by the awk field split
    # above via the leading-space-eating substitution), then one layer of
    # matching quotes.
    case "$v" in
      \"*\") v="${v#\"}"; v="${v%\"}" ;;
      \'*\') v="${v#\'}"; v="${v%\'}" ;;
    esac
    [ -n "$v" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# `category:` is declared in every SKILL.md by Task 2 of the count-SSOT plan.
# Until at least ONE skill carries it the real repo is DELIBERATELY red (one
# "missing 'category:'" ERROR per skill), so the clean-bill assertions are gated
# on the tree having entered that state. The gate is `> 0`, never "all" — the
# moment any skill declares a category the assertions go live, so a half-finished
# migration fails here instead of passing quietly. Zero declared skills is not a
# free pass either: that branch asserts the RED shape explicitly.
#
# TOCTOU: REAL_CATEGORIZED must be derived from the SAME snapshot of
# skills/*/SKILL.md that REAL_OUT's validator run reads — computed here,
# BEFORE the validator invocation below, so nothing between "read the repo for
# the gate decision" and "read the repo for the thing being gated" can change
# the files out from under the comparison (a concurrent edit mid-test would
# otherwise let the two reads disagree about the very state each is reporting
# on).
REAL_CATEGORIZED="$(count_declared_categories)"

set +e
REAL_OUT="$(bash "$SCRIPT" 2>&1)"
REAL_RC=$?
set -e
if [ "$REAL_CATEGORIZED" -gt 0 ]; then
  [ "$REAL_RC" -eq 0 ] || fail "real-repo run should exit 0, got $REAL_RC (output: $REAL_OUT)"
  printf '%s\n' "$REAL_OUT" | grep -Fq -- "ERRORS: 0" \
    || fail "real-repo run should report 'ERRORS: 0' (output: $REAL_OUT)"
  pass "real-repo run exits 0 with ERRORS: 0"

  printf '%s\n' "$REAL_OUT" | grep -Eq -- '^category-consistency: OK \([0-9]+ categories\)$' \
    || fail "real-repo run should print 'category-consistency: OK (<n> categories)' as its own exact line (output: $REAL_OUT)"
  pass "real-repo category-consistency is live (OK line present)"
else
  [ "$REAL_RC" -eq 1 ] || fail "pre-Task-2 real repo should exit 1 (no skill declares 'category:'), got $REAL_RC (output: $REAL_OUT)"
  printf '%s\n' "$REAL_OUT" | grep -Fq -- "missing 'category:'" \
    || fail "pre-Task-2 real repo should report missing-category ERRORs (output: $REAL_OUT)"
  pass "real repo is in the documented pre-Task-2 state: 0 skills declare 'category:', validator exits 1 with missing-category ERRORs"
fi

# fail-open guard: deleting the '| Category | Count |' table from docs/skills.md
# AND CLAUDE.md would flip category-consistency to the n/a skip and silently
# disable every per-category assertion. Both anchor files exist (with a table)
# in this tree REGARDLESS of whether any skill has declared 'category:' yet, so
# this must hold pre- AND post-Task-2 — it is asserted unconditionally here
# rather than nested inside the `> 0` gate above, where it was previously
# dormant exactly while it mattered most (the real repo is pre-Task-2 right now).
# The complementary case — an anchor file that EXISTS but has LOST its table
# produces an explicit ERROR, never n/a — is covered unconditionally by the
# NOTABLE_OUT mini-repo fixture assertions above, which do not depend on
# REAL_CATEGORIZED either.
if printf '%s\n' "$REAL_OUT" | grep -Fq -- "category-consistency: n/a"; then
  fail "real repo must NEVER print 'category-consistency: n/a' — that means the category table was removed from docs/skills.md and CLAUDE.md, disabling every per-category check (output: $REAL_OUT)"
fi
pass "real-repo category-consistency fail-open guard: n/a absent (holds pre- and post-Task-2)"

printf '%s\n' "$REAL_OUT" | grep -Fq -- "include-integrity: OK" \
  || fail "real-repo run should print 'include-integrity: OK' (output: $REAL_OUT)"
# Count the skill dirs instead of hardcoding the number. The literal 55 here had to be updated by
# hand on every skill addition, was not on the "add a new skill" checklist, and duly went red the
# first time a 56th skill landed — a test failing for bookkeeping rather than for a defect. What
# actually matters is that the validator agrees with the tree, which is what this now asserts.
# Still anchored on a non-digit/EOL so 'OK (560)' cannot satisfy a check for 'OK (56)'.
# Same SKILL.md-counting oracle as REAL_SKILL_DIRS above — matches count_actual_skills().
REAL_N=$(find "$ROOT_DIR/skills" -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')
printf '%s\n' "$REAL_OUT" | grep -qE "count-consistency: OK \($REAL_N\)([^0-9]|$)" \
  || fail "real-repo run should print 'count-consistency: OK ($REAL_N)' — one per skills/ dir (output: $REAL_OUT)"
pass "real-repo run prints include-integrity and count-consistency OK lines"

pass "validate-skills-contract"
