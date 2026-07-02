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
EMPTYROOT="$(mktemp -d)"
trap 'rm -rf "$TMP" "$TMP2" "$EMPTYROOT"' EXIT

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
mkskill no-mfl <<'EOF'
---
name: no-mfl
description: "Valid, has run-logger + arg-parsing, but no MFL section."
---

# zuvo:no-mfl

## Argument Parsing
x

References ../../shared/includes/run-logger.md for logging.
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
            no-open-fence no-close-fence no-description dangling-include; do
  printf '%s\n' "$ERR_LINES" | grep -Fq -- "$name" \
    || fail "expected an ERROR mentioning '$name' (errors: $ERR_LINES)"
done
pass "each of the 9 broken skills produced an ERROR"

# the dangling-include ERROR must contain the dangling path itself
printf '%s\n' "$ERR_LINES" | grep -Fq -- "../../shared/includes/does-not-exist.md" \
  || fail "expected the dangling include path in an ERROR line (errors: $ERR_LINES)"
pass "dangling include ERROR names the unresolved path"

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
description: "Mini router fixture with banner and routing table."
---

# Zuvo Skill Router

> **Zuvo v9.9** | 2 skills | fixture banner

## Routing Table

| Intent | Skill |
|--------|-------|
| build stuff | `zuvo:alpha` |
| ad-hoc label | `zuvo:extra-token` |

## Next Section

Nothing else.
EOF

cat > "$TMP2/.claude-plugin/plugin.json" <<'EOF'
{
  "description": "Fixture ecosystem. 3 skills with quality gates."
}
EOF

cat > "$TMP2/.codex-plugin/plugin.json" <<'EOF'
{
  "description": "Fixture ecosystem. 2 skills with quality gates.",
  "longDescription": "Long form: 2 skills across fixture categories."
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

cat > "$TMP2/CLAUDE.md" <<'EOF'
# Fixture Guide

skills/<name>/SKILL.md — skill definitions (2 total)

## Skill categories (2 total)

| Category | Count | Skills |
|----------|-------|--------|
| Core | 1 | alpha |
| Utility | 1 | using-zuvo |
EOF

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

# ---------- run the validator against the REAL repo ----------
set +e
REAL_OUT="$(bash "$SCRIPT" 2>&1)"
REAL_RC=$?
set -e

[ "$REAL_RC" -eq 0 ] || fail "real-repo run should exit 0, got $REAL_RC (output: $REAL_OUT)"
printf '%s\n' "$REAL_OUT" | grep -Fq -- "ERRORS: 0" \
  || fail "real-repo run should report 'ERRORS: 0' (output: $REAL_OUT)"
pass "real-repo run exits 0 with ERRORS: 0"

printf '%s\n' "$REAL_OUT" | grep -Fq -- "include-integrity: OK" \
  || fail "real-repo run should print 'include-integrity: OK' (output: $REAL_OUT)"
printf '%s\n' "$REAL_OUT" | grep -Fq -- "count-consistency: OK (54)" \
  || fail "real-repo run should print 'count-consistency: OK (54)' (output: $REAL_OUT)"
pass "real-repo run prints include-integrity and count-consistency OK lines"

pass "validate-skills-contract"
