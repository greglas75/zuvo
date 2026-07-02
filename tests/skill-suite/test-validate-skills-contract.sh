#!/usr/bin/env bash
# Contract test for scripts/validate-skills.sh (Task 2: structural skill lint).
#
# Builds a synthetic skills/ tree with one broken skill per ERROR class, plus
# clean, exemption, and WARN fixtures, then asserts the two-tier severity
# output: ERRORs fail the run (exit 1), WARNs are advisory (do not fail).
# Also runs the validator against the REAL repo and asserts a clean bill
# (exit 0, ERRORS: 0) so structural regressions are caught in CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
SCRIPT="$ROOT_DIR/scripts/validate-skills.sh"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
            no-open-fence no-close-fence no-description; do
  printf '%s\n' "$ERR_LINES" | grep -Fq -- "$name" \
    || fail "expected an ERROR mentioning '$name' (errors: $ERR_LINES)"
done
pass "each of the 8 broken skills produced an ERROR"

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

# ---------- run the validator against the REAL repo ----------
set +e
REAL_OUT="$(bash "$SCRIPT" 2>&1)"
REAL_RC=$?
set -e

[ "$REAL_RC" -eq 0 ] || fail "real-repo run should exit 0, got $REAL_RC (output: $REAL_OUT)"
printf '%s\n' "$REAL_OUT" | grep -Fq -- "ERRORS: 0" \
  || fail "real-repo run should report 'ERRORS: 0' (output: $REAL_OUT)"
pass "real-repo run exits 0 with ERRORS: 0"

pass "validate-skills-contract"
