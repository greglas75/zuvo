#!/usr/bin/env bash
# Task 9 — skills/infra-audit/SKILL.md orchestrator contract test.
# TDD: written RED first (no SKILL.md), then SKILL.md authored to turn it GREEN.
#
# Pure file-assertion test — no Docker, no SSH, no network, no LLM.
# Verifies that the orchestrator SKILL.md encodes every anchor the Phase 0-3
# pipeline, the dispatch/fallback contract, resume semantics, and the report/
# completion blocks the spec (2026-06-10-infra-audit-spec.md) requires.
#
# Assertion groups:
#   1.  frontmatter name: infra-audit + description lists ALL 11 flags
#   2.  two-stage include loading (Stage 1 ×4, Stage 2 ×4)
#   3.  Phase 0/1/2/3 section headers
#   4.  authorization-gate section citing ssh-probe-protocol §1
#   5.  dispatch block: all 4 agents/*.md + degraded MODE SWITCH + single-agent
#   6.  resume-semantics table: 6 statuses + bundle_sha256 stale guard + mismatch→re-analysis
#   7.  Phase 3 anchors: UNGROUNDED-FINDING, IC-6 CVE grep gate, fleet-summary written LAST
#   8.  IC-1 ZUVO_DIR resolution line
#   9.  coverage_mode: DEGRADED labeling
#   10. E10 Alpine branch (alpine-release + apk)
#   11. E11 duplicate-IP dedup (duplicate IP + merge/WARN)
#   12. DD-2 first-run hosts.yaml scaffold
#   13. Tool Availability Block template
#   14. Run: line template + append-runlog wrapper
#   15. VALIDITY GATE block
#   16. retro-marker bash block
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
TARGET="$ROOT_DIR/skills/infra-audit/SKILL.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

# Local grep-pattern helper (ERE, case-sensitive unless overridden via flags in
# the pattern). Mirrors require_grep but with a custom PASS label.
req() {
  local pattern="$1" label="$2"
  if grep -Eq -- "$pattern" "$TARGET"; then
    pass "$label"
  else
    fail "$label  (pattern not found: $pattern)"
  fi
}
reqi() {
  local pattern="$1" label="$2"
  if grep -Eqi -- "$pattern" "$TARGET"; then
    pass "$label"
  else
    fail "$label  (pattern not found (-i): $pattern)"
  fi
}

# ============================================================================
# 0. file exists
# ============================================================================
assert_file_exists "$TARGET"
pass "file exists: skills/infra-audit/SKILL.md"

# ============================================================================
# 1. frontmatter name + all 11 flags listed in the description/argument surface
# ============================================================================
req '^name:[[:space:]]*infra-audit[[:space:]]*$' "frontmatter: name: infra-audit"

for flag in \
  '--host' '--quick' '--dimensions' '--no-install' '--dry-run' \
  '--resume' '--proxy' '--external direct' '--skip-external' \
  '--deep-scan' '--confirm-targets'; do
  if grep -Fq -- "$flag" "$TARGET"; then
    pass "flag documented: $flag"
  else
    fail "flag NOT documented: $flag"
  fi
done

# ============================================================================
# 2. two-stage include loading — Stage 1 (×4) + Stage 2 (×4)
# ============================================================================
reqi 'stage 1'                          "two-stage loading: Stage 1 header present"
reqi 'stage 2'                          "two-stage loading: Stage 2 header present"
# Stage 1 includes
for inc in env-compat no-pause-protocol infra-check-registry ssh-probe-protocol; do
  if grep -Fq -- "$inc.md" "$TARGET"; then
    pass "Stage 1 include referenced: $inc.md"
  else
    fail "Stage 1 include MISSING: $inc.md"
  fi
done
# Stage 2 includes
for inc in backlog-protocol run-logger retrospective report-output-location; do
  if grep -Fq -- "$inc.md" "$TARGET"; then
    pass "Stage 2 include referenced: $inc.md"
  else
    fail "Stage 2 include MISSING: $inc.md"
  fi
done

# ============================================================================
# 3. Phase 0/1/2/3 section headers
# ============================================================================
req '^#+[[:space:]].*Phase 0'  "Phase 0 section header present"
req '^#+[[:space:]].*Phase 1'  "Phase 1 section header present"
req '^#+[[:space:]].*Phase 2'  "Phase 2 section header present"
req '^#+[[:space:]].*Phase 3'  "Phase 3 section header present"

# ============================================================================
# 4. authorization-gate section citing ssh-probe-protocol §1
# ============================================================================
reqi 'authorization gate' "authorization-gate section present"
req 'ssh-probe-protocol[^[:space:]]*[[:space:]]*(§|section[[:space:]]*)?1' \
    "authorization gate cites ssh-probe-protocol §1"

# ============================================================================
# 5. dispatch block: all 4 agents/*.md + degraded MODE SWITCH + single-agent
# ============================================================================
for ag in host-analyst network-analyst container-analyst data-analyst; do
  if grep -Fq -- "agents/$ag.md" "$TARGET"; then
    pass "dispatch references agent file: agents/$ag.md"
  else
    fail "dispatch MISSING agent file: agents/$ag.md"
  fi
done
req 'MODE SWITCH'   "degraded-dispatch anchor present (MODE SWITCH)"
reqi 'single-agent' "single-agent inline fallback present"

# ============================================================================
# 6. resume-semantics table: 6 statuses + bundle_sha256 stale guard + mismatch rule
# ============================================================================
for st in pending collecting analyzed reported unreachable failed; do
  if grep -Eq -- "(\`$st\`|\| *$st *\||\b$st\b)" "$TARGET"; then
    pass "resume status present: $st"
  else
    fail "resume status MISSING: $st"
  fi
done
req 'bundle_sha256' "bundle_sha256 stale-findings guard referenced"
# mismatch → re-analysis rule (either phrasing)
if grep -Eqi 'mismatch.*re-analysis' "$TARGET" || grep -Eqi 'bundle_sha256.*mismatch' "$TARGET" || grep -Eqi 'mismatch.*forces re-analysis' "$TARGET"; then
  pass "bundle_sha256 mismatch → re-analysis rule present"
else
  fail "bundle_sha256 mismatch → re-analysis rule MISSING"
fi

# ============================================================================
# 7. Phase 3 anchors
# ============================================================================
req 'UNGROUNDED-FINDING' "Phase 3 anchor: UNGROUNDED-FINDING"
# IC-6 CVE grep gate (any accepted phrasing)
if grep -Eq -- 'CVE-EVIDENCE-MISSING' "$TARGET" || grep -Eqi 'CVE.*grep gate' "$TARGET" || grep -Eq -- 'CVE.*raw/' "$TARGET"; then
  pass "Phase 3 anchor: IC-6 CVE grep gate"
else
  fail "Phase 3 anchor MISSING: IC-6 CVE grep gate"
fi
reqi 'fleet[ -]?summary.*(written|generated|assembled).*last|written[[:space:]]*last' \
    "Phase 3 anchor: fleet-summary written LAST"

# ============================================================================
# 8. IC-1 ZUVO_DIR resolution line
# ============================================================================
req 'ZUVO_DIR=' "IC-1 ZUVO_DIR resolution line present"

# ============================================================================
# 9. coverage_mode: DEGRADED labeling
# ============================================================================
req 'coverage_mode:[[:space:]]*DEGRADED' "coverage_mode: DEGRADED labeling present"

# ============================================================================
# 10. E10 Alpine branch
# ============================================================================
if grep -Fq -- 'alpine-release' "$TARGET" && grep -Eq -- 'apk ' "$TARGET"; then
  pass "E10 Alpine branch present (alpine-release + apk)"
else
  fail "E10 Alpine branch MISSING (need alpine-release AND apk )"
fi

# ============================================================================
# 11. E11 duplicate-IP dedup
# ============================================================================
if grep -Eqi -- 'duplicate IP' "$TARGET" && grep -Eqi -- '(merge|WARN)' "$TARGET"; then
  pass "E11 duplicate-IP dedup present (duplicate IP + merge/WARN)"
else
  fail "E11 duplicate-IP dedup MISSING (need 'duplicate IP' + merge/WARN)"
fi

# ============================================================================
# 12. DD-2 first-run hosts.yaml scaffold
# ============================================================================
if grep -Eqi -- 'scaffold' "$TARGET" && grep -Fq -- 'hosts.yaml' "$TARGET"; then
  pass "DD-2 first-run hosts.yaml scaffold present"
else
  fail "DD-2 first-run scaffold MISSING (need 'scaffold' near hosts.yaml)"
fi

# ============================================================================
# 13. Tool Availability Block template
# ============================================================================
reqi 'Tool Availability Block' "Tool Availability Block template present"

# ============================================================================
# 14. Run: line template + append-runlog wrapper
# ============================================================================
req '^[[:space:]>`]*Run:' "Run: line template present"
req 'append-runlog'        "append-runlog wrapper present"

# ============================================================================
# 15. VALIDITY GATE block
# ============================================================================
reqi 'VALIDITY GATE' "VALIDITY GATE block present"

# ============================================================================
# 16. retro-marker bash block
# ============================================================================
if grep -Eqi -- 'retro[ -]?marker' "$TARGET"; then
  pass "retro-marker bash block present"
else
  fail "retro-marker bash block MISSING"
fi

echo
echo "ALL INFRA-SKILL-CONTRACT ASSERTIONS PASSED"
