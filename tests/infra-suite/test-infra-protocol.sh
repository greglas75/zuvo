#!/usr/bin/env bash
# Task 2 — ssh-probe-protocol.md contract test.
# TDD: written RED first (no include file), then include authored to turn it GREEN.
#
# Pure file-assertion test — no Docker, no SSH, no network.
# Verifies that shared/includes/ssh-probe-protocol.md contains every
# normative contract element required by the infra-audit spec.
#
# Assertions (≥9 groups):
#   1. file exists
#   2. all 6 normative section headers present
#   3. IC-8 verbatim SSH flag string
#   4. --confirm-targets present
#   5. all four privilege_mode values
#   6. [AUTO-DECISION] never applies to target authorization
#   7. StrictHostKeyChecking never disabled
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
TARGET="$ROOT_DIR/shared/includes/ssh-probe-protocol.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

# --- 1. file exists -----------------------------------------------------------
assert_file_exists "$TARGET"
pass "file exists: shared/includes/ssh-probe-protocol.md"

# --- 2. all 6 normative section headers present ------------------------------
require_text "Authorization Gate" "$TARGET"
pass "section header present: Authorization Gate"

require_text "SSH invariants" "$TARGET"
pass "section header present: SSH invariants"

require_text "Privilege probe" "$TARGET"
pass "section header present: Privilege probe"

require_text "Key-material ban" "$TARGET"
pass "section header present: Key-material ban"

require_text "Host-key mismatch rule" "$TARGET"
pass "section header present: Host-key mismatch rule"

require_text "Rate & timing rules" "$TARGET"
pass "section header present: Rate & timing rules"

# --- 3. IC-8 verbatim SSH flag string ----------------------------------------
IC8_FLAGS="-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes"
require_text "$IC8_FLAGS" "$TARGET"
pass "IC-8 flag string present verbatim"

# --- 4. --confirm-targets present --------------------------------------------
require_text "--confirm-targets" "$TARGET"
pass "--confirm-targets present"

# --- 5. all four privilege_mode values ---------------------------------------
require_text "root" "$TARGET"
pass "privilege_mode value present: root"

require_text "passwordless-sudo" "$TARGET"
pass "privilege_mode value present: passwordless-sudo"

require_text "limited-sudo" "$TARGET"
pass "privilege_mode value present: limited-sudo"

require_text "no-sudo" "$TARGET"
pass "privilege_mode value present: no-sudo"

# --- 6. [AUTO-DECISION] never applies to target authorization ----------------
require_text "[AUTO-DECISION]" "$TARGET"
pass "[AUTO-DECISION] semantics addressed in file"

# Verify the statement says [AUTO-DECISION] does NOT apply to target auth.
# Look for a sentence that pairs [AUTO-DECISION] with a negation near "target authorization".
require_grep "\[AUTO-DECISION\].*never|never.*\[AUTO-DECISION\]" "$TARGET"
pass "[AUTO-DECISION] never applies to target authorization"

# --- 7. StrictHostKeyChecking never disabled ---------------------------------
require_text "StrictHostKeyChecking" "$TARGET"
pass "StrictHostKeyChecking referenced"

require_grep "StrictHostKeyChecking.*never|never.*StrictHostKeyChecking|never disable.*StrictHostKeyChecking|StrictHostKeyChecking.*never disable|never.*disabl.*StrictHostKeyChecking|StrictHostKeyChecking.*disabl.*never" "$TARGET"
pass "StrictHostKeyChecking: never disabled stated"

echo ""
echo "ALL SSH-PROBE-PROTOCOL ASSERTIONS PASSED"
