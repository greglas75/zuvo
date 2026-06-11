#!/usr/bin/env bash
# smoke-fleet-audit.sh <run-dir>
#
# VERIFIER for a completed zuvo:infra-audit run.
# This harness does NOT run the skill — the skill is invoked by the LLM at
# execute Phase Final (per SKILL.md). Once the skill has completed, point this
# harness at the resulting run directory to verify all invariants hold.
#
# Usage:
#   bash tests/infra-suite/smoke-fleet-audit.sh <run-dir>
#
# To produce a run-dir to verify:
#   1. Bring fixtures up:  cd tests/infra-suite/fixtures && docker compose -p zuvo-infra-fixtures up -d --build
#   2. Run the skill:      (in Claude Code) /zuvo:infra-audit tests/infra-suite/fixtures/hosts-3.yaml
#   3. Run this harness:   bash tests/infra-suite/smoke-fleet-audit.sh <run-dir>
#
# Precondition guard: exits 2 with usage when run-dir argument is missing.
set -euo pipefail

# ── precondition guard (RED: exit 2 when no arg) ────────────────────────────
if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "USAGE ERROR: run-dir argument required." >&2
  echo "" >&2
  echo "  Usage: bash smoke-fleet-audit.sh <run-dir>" >&2
  echo "" >&2
  echo "  This harness verifies a COMPLETED zuvo:infra-audit run." >&2
  echo "  Run the skill first per SKILL.md, then point me at the run dir." >&2
  echo "  Example run-dir: zuvo/audits/infra-audit-2026-06-11-1430" >&2
  exit 2
fi

RUN_DIR="$1"

# ── resolve paths ─────────────────────────────────────────────────────────
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE_DIR="$ROOT_DIR/tests/infra-suite"
FIXT_DIR="$SUITE_DIR/fixtures"
PROJECT="zuvo-infra-fixtures"

PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "PASS: $*"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL: $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# ── Docker guard (docker-dependent harness) ──────────────────────────────
# shellcheck source=tests/infra-suite/lib/docker-guard.sh
source "$SUITE_DIR/lib/docker-guard.sh"

# ── ensure fixtures are up ─────────────────────────────────────────────────
# shellcheck source=tests/infra-suite/lib/ensure-fixtures.sh
source "$SUITE_DIR/lib/ensure-fixtures.sh"
ensure_fixtures

if [ -d /Applications/Docker.app/Contents/Resources/bin ]; then
  export PATH="$PATH:/Applications/Docker.app/Contents/Resources/bin"
fi

echo "--- Bringing fixtures up (ensure running) ---"
docker compose -f "$FIXT_DIR/docker-compose.yml" -p "$PROJECT" up -d --build 2>&1 | tail -5 || true

# ── 1. Run-dir existence ────────────────────────────────────────────────────
if [ ! -d "$RUN_DIR" ]; then
  echo "FAIL: run-dir does not exist: $RUN_DIR" >&2
  echo "      Run the skill first per SKILL.md, then point me at the run dir." >&2
  exit 2
fi

# ── 2. IC-1 naming pattern ──────────────────────────────────────────────────
BASENAME="$(basename "$RUN_DIR")"
if echo "$BASENAME" | grep -qE '^infra-audit-[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$'; then
  pass "IC-1 run-dir name matches pattern: $BASENAME"
else
  fail "IC-1 run-dir name does not match infra-audit-YYYY-MM-DD-HHMM: $BASENAME"
fi

# ── 3. Per-host report files ────────────────────────────────────────────────
# Expect .md report for the misconfigured and hardened fixture containers.
# Exact filename depends on how SKILL.md maps host names → report names.
# Verify ≥2 per-host .md files (excluding fleet-summary.md).
HOST_REPORTS=()
while IFS= read -r -d '' f; do
  HOST_REPORTS+=("$f")
done < <(find "$RUN_DIR" -maxdepth 1 -name '*.md' ! -name 'fleet-summary.md' -print0 2>/dev/null)

if [ "${#HOST_REPORTS[@]}" -ge 2 ]; then
  pass "per-host reports: ${#HOST_REPORTS[@]} report files found (≥2 required)"
else
  fail "per-host reports: expected ≥2 host .md files in $RUN_DIR, found ${#HOST_REPORTS[@]}"
fi

# ── 4. fleet-summary.md exists ──────────────────────────────────────────────
FLEET_SUMMARY="$RUN_DIR/fleet-summary.md"
if [ -f "$FLEET_SUMMARY" ]; then
  pass "fleet-summary.md exists"
else
  fail "fleet-summary.md not found in $RUN_DIR"
fi

# ── 5. fleet-summary contains UNREACHABLE entry for black-hole host ─────────
if [ -f "$FLEET_SUMMARY" ]; then
  if grep -qi 'UNREACHABLE' "$FLEET_SUMMARY"; then
    pass "fleet-summary contains UNREACHABLE entry (black-hole host 192.0.2.1)"
  else
    fail "fleet-summary missing UNREACHABLE entry — black-hole host should appear as UNREACHABLE (AC1)"
  fi
fi

# ── 6. fleet-summary mtime is NEWEST (written LAST) ─────────────────────────
# fleet-summary must be newer than (or equal to) all per-host reports.
if [ -f "$FLEET_SUMMARY" ] && [ "${#HOST_REPORTS[@]}" -gt 0 ]; then
  FLEET_MTIME="$(stat -c '%Y' "$FLEET_SUMMARY" 2>/dev/null || stat -f '%m' "$FLEET_SUMMARY" 2>/dev/null)"
  ALL_OLDER=true
  for rpt in "${HOST_REPORTS[@]}"; do
    RPT_MTIME="$(stat -c '%Y' "$rpt" 2>/dev/null || stat -f '%m' "$rpt" 2>/dev/null)"
    if [ "$RPT_MTIME" -gt "$FLEET_MTIME" ]; then
      ALL_OLDER=false
      fail "fleet-summary mtime ($FLEET_MTIME) < $(basename "$rpt") mtime ($RPT_MTIME) — fleet-summary must be written LAST"
      break
    fi
  done
  if $ALL_OLDER; then
    pass "fleet-summary mtime is newest (written last)"
  fi
fi

# ── 7. bundle/*.json schema-valid (IC-3 required keys) ──────────────────────
BUNDLE_DIR="$RUN_DIR/bundle"
BUNDLE_VALID=true
BUNDLE_COUNT=0
if [ -d "$BUNDLE_DIR" ]; then
  while IFS= read -r -d '' f; do
    BUNDLE_COUNT=$((BUNDLE_COUNT+1))
    BASENAME_F="$(basename "$f")"
    if ! jq . "$f" >/dev/null 2>&1; then
      fail "bundle/${BASENAME_F}: not valid JSON"
      BUNDLE_VALID=false
      continue
    fi
    # Check IC-3 required keys
    MISSING=$(jq -r '
      [
        (if has("host") then empty else "host" end),
        (if has("collected_at") then empty else "collected_at" end),
        (if has("privilege_mode") then empty else "privilege_mode" end),
        (if has("tool_availability") then empty else "tool_availability" end),
        (if has("checks") then empty else "checks" end),
        (if has("external") then empty else "external" end)
      ] | join(",")
    ' "$f" 2>/dev/null || echo "parse-error")
    if [ -n "$MISSING" ]; then
      fail "bundle/${BASENAME_F}: missing IC-3 keys: $MISSING"
      BUNDLE_VALID=false
    fi
  done < <(find "$BUNDLE_DIR" -name '*.json' ! -name '*.phase0.json' -print0 2>/dev/null)
fi
if [ "$BUNDLE_COUNT" -gt 0 ] && $BUNDLE_VALID; then
  pass "bundle/*.json: $BUNDLE_COUNT bundles valid (IC-3 keys present)"
elif [ "$BUNDLE_COUNT" -eq 0 ]; then
  fail "bundle/*.json: no bundle files found in $BUNDLE_DIR"
fi

# ── 8. findings/*.json carry bundle_sha256 matching shasum of their bundle ───
FINDINGS_DIR="$RUN_DIR/findings"
FINDINGS_COUNT=0; SHA_MATCH=0; SHA_FAIL=0
if [ -d "$FINDINGS_DIR" ]; then
  while IFS= read -r -d '' f; do
    FINDINGS_COUNT=$((FINDINGS_COUNT+1))
    BASENAME_F="$(basename "$f")"
    RECORDED_SHA="$(jq -r '.bundle_sha256 // empty' "$f" 2>/dev/null || true)"
    if [ -z "$RECORDED_SHA" ]; then
      fail "findings/${BASENAME_F}: missing bundle_sha256 field"
      SHA_FAIL=$((SHA_FAIL+1))
      continue
    fi
    # Determine host name from findings filename: findings/<host>-<layer>.json
    HOST_PART="${BASENAME_F%-*}"       # strip last -<layer>.json component
    HOST_PART="${HOST_PART%.json}"
    BUNDLE_FILE="$BUNDLE_DIR/${HOST_PART}.json"
    if [ ! -f "$BUNDLE_FILE" ]; then
      # Try alternate: host part may be just the first segment before -
      fail "findings/${BASENAME_F}: no corresponding bundle at $BUNDLE_FILE"
      SHA_FAIL=$((SHA_FAIL+1))
      continue
    fi
    ACTUAL_SHA="$( (sha256sum "$BUNDLE_FILE" 2>/dev/null || shasum -a 256 "$BUNDLE_FILE") | awk '{print $1}')"
    if [ "$RECORDED_SHA" = "$ACTUAL_SHA" ]; then
      SHA_MATCH=$((SHA_MATCH+1))
    else
      fail "findings/${BASENAME_F}: bundle_sha256 mismatch (recorded=$RECORDED_SHA actual=$ACTUAL_SHA)"
      SHA_FAIL=$((SHA_FAIL+1))
    fi
  done < <(find "$FINDINGS_DIR" -name '*.json' -print0 2>/dev/null)
fi
if [ "$FINDINGS_COUNT" -gt 0 ] && [ "$SHA_FAIL" -eq 0 ]; then
  pass "findings/*.json bundle_sha256: $SHA_MATCH/$FINDINGS_COUNT files match"
elif [ "$FINDINGS_COUNT" -eq 0 ]; then
  fail "findings/*.json: no findings files found in $FINDINGS_DIR"
fi

# ── 9. external.vantage == proxy in at least one bundle ──────────────────────
VANTAGE_PROXY=false
if [ -d "$BUNDLE_DIR" ]; then
  while IFS= read -r -d '' f; do
    VANTAGE="$(jq -r '.external.vantage // empty' "$f" 2>/dev/null || true)"
    if [ "$VANTAGE" = "proxy" ]; then
      VANTAGE_PROXY=true
      break
    fi
  done < <(find "$BUNDLE_DIR" -name '*.json' ! -name '*.phase0.json' -print0 2>/dev/null)
fi
if $VANTAGE_PROXY; then
  pass "external.vantage=proxy present in at least one bundle"
else
  fail "external.vantage=proxy not found in any bundle (fixtures use SOCKS proxy at 1080)"
fi

# ── 10. Misconfigured host grade WORSE than hardened host ────────────────────
# Parse grade/severity counts from per-host .md reports.
# fleet-summary row format: | host | status | grade | critical | high | ...
# Grade ordering: A < B < C < D < F (worse = later in alphabet / higher letter).
if [ -f "$FLEET_SUMMARY" ]; then
  # Extract grade for misconfigured and hardened from fleet-summary table rows
  MISC_GRADE="$(grep -i 'misconfigured' "$FLEET_SUMMARY" | grep -oE '\| [A-F] \|' | head -1 | tr -d '| ' || true)"
  HARD_GRADE="$(grep -i 'hardened' "$FLEET_SUMMARY" | grep -oE '\| [A-F] \|' | head -1 | tr -d '| ' || true)"

  if [ -n "$MISC_GRADE" ] && [ -n "$HARD_GRADE" ]; then
    # ASCII: A=65 B=66 ... F=70 — worse grade has higher ASCII value
    if [[ "$MISC_GRADE" > "$HARD_GRADE" ]]; then
      pass "grade: misconfigured ($MISC_GRADE) worse than hardened ($HARD_GRADE)"
    else
      fail "grade: expected misconfigured ($MISC_GRADE) to be worse than hardened ($HARD_GRADE)"
    fi
  else
    # Fall back to critical+high count comparison
    MISC_CRIT="$(grep -i 'misconfigured' "$FLEET_SUMMARY" | grep -oE '\| [0-9]+ \|' | head -1 | tr -d '| ' || true)"
    HARD_CRIT="$(grep -i 'hardened' "$FLEET_SUMMARY" | grep -oE '\| [0-9]+ \|' | head -1 | tr -d '| ' || true)"
    if [ -n "$MISC_CRIT" ] && [ -n "$HARD_CRIT" ] && [ "$MISC_CRIT" -gt "$HARD_CRIT" ]; then
      pass "severity counts: misconfigured ($MISC_CRIT critical) > hardened ($HARD_CRIT critical)"
    else
      fail "could not confirm misconfigured grade worse than hardened (grades: misc=$MISC_GRADE hard=$HARD_GRADE crits: misc=$MISC_CRIT hard=$HARD_CRIT)"
    fi
  fi
fi

# ── 11. ~/.zuvo/runs.log tail contains an infra-audit line ───────────────────
RUNS_LOG="$HOME/.zuvo/runs.log"
if [ -f "$RUNS_LOG" ]; then
  if tail -50 "$RUNS_LOG" | grep -q 'infra-audit'; then
    pass "~/.zuvo/runs.log: infra-audit entry found in tail-50"
  else
    fail "~/.zuvo/runs.log: no infra-audit line in tail-50 of $RUNS_LOG"
  fi
else
  fail "~/.zuvo/runs.log: file not found at $RUNS_LOG (run logger not fired?)"
fi

# ── 12. Zero seeded secrets in run dir ───────────────────────────────────────
# Seed values from seed-manifest.md (IS12 leaked-secrets row)
SEEDED_SECRETS=(
  "zuvo-seed-jwt-4b8d"
)
# Also scan for other known seeded literal secrets from env.seed
ADDITIONAL_SECRETS=()
if [ -f "$FIXT_DIR/sshd-misconfigured/env.seed" ]; then
  # Extract non-comment, non-empty values from env.seed.
  # `|| [ -n "$line" ]` keeps the LAST line even when the file lacks a trailing
  # newline (a bare `while read` would silently drop it).
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    val="${line#*=}"
    # Only scan the unmistakable seeded-secret TOKENS (`zuvo-seed-*`), not whole
    # values. A bare value like `redis://:...@127.0.0.1:6379` contains the
    # generic substring `127.0.0.1` which legitimately appears in audit reports
    # (loopback bind findings) — grepping the full value would false-positive.
    # Extract every zuvo-seed-<token> from the value instead.
    while IFS= read -r tok; do
      [ -n "$tok" ] && ADDITIONAL_SECRETS+=("$tok")
    done < <(printf '%s\n' "$val" | grep -oE 'zuvo-seed-[A-Za-z0-9-]+' || true)
  done < "$FIXT_DIR/sshd-misconfigured/env.seed"
fi

SECRET_LEAK=false
for secret in "${SEEDED_SECRETS[@]}" "${ADDITIONAL_SECRETS[@]}"; do
  if grep -rqF "$secret" "$RUN_DIR" 2>/dev/null; then
    fail "seeded secret found in run dir: '$secret' (IC-5 redaction failed)"
    SECRET_LEAK=true
  fi
done
if ! $SECRET_LEAK; then
  pass "zero seeded secrets found in run dir (IC-5 redaction verified)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== smoke-fleet-audit RESULTS ==="
echo "RUN_DIR: $RUN_DIR"
echo "PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "SMOKE1: ALL INVARIANTS HOLD"
  exit 0
else
  echo "SMOKE1: $FAIL_COUNT invariant(s) FAILED"
  exit 1
fi
