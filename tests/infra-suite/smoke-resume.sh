#!/usr/bin/env bash
# smoke-resume.sh <run-dir>
#
# VERIFIER for a completed zuvo:infra-audit --resume round-trip (SMOKE2).
# Checks that a resumed run left no stale/duplicate artifacts and that hosts
# which were already `reported` before the resume remain untouched.
#
# Usage:
#   bash tests/infra-suite/smoke-resume.sh <run-dir>
#
# Workflow (SMOKE2):
#   1. Run the skill; interrupt it after host 1 reaches `reported` state.
#   2. Record mtime baseline:  stat -f '%m' <run-dir>/<host1>.md
#   3. Re-run with:  /zuvo:infra-audit --resume <run-dir>  (in Claude Code)
#   4. Run this harness:  bash tests/infra-suite/smoke-resume.sh <run-dir>
#
# The harness also accepts an optional baseline file written by a prior run:
#   <run-dir>/smoke-resume-baseline.json   — {"reported_host": "<host>", "mtime": <epoch>}
# If present, it uses the recorded mtime to verify the host was not touched.
#
# Precondition guard: exits 2 with usage when run-dir argument is missing.
set -euo pipefail

# ── precondition guard (RED: exit 2 when no arg) ────────────────────────────
if [ $# -lt 1 ] || [ -z "$1" ]; then
  echo "USAGE ERROR: run-dir argument required." >&2
  echo "" >&2
  echo "  Usage: bash smoke-resume.sh <run-dir>" >&2
  echo "" >&2
  echo "  This harness verifies a COMPLETED --resume round-trip (SMOKE2)." >&2
  echo "  Workflow:" >&2
  echo "    1. Run the skill and interrupt it after host 1 reaches 'reported'." >&2
  echo "    2. Re-run with: /zuvo:infra-audit --resume <run-dir>" >&2
  echo "    3. Then point me at the run dir." >&2
  echo "  Example run-dir: zuvo/audits/infra-audit-2026-06-11-1430" >&2
  exit 2
fi

RUN_DIR="$1"

PASS_COUNT=0; FAIL_COUNT=0
pass() { echo "PASS: $*"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL: $*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# ── run-dir existence check ──────────────────────────────────────────────────
if [ ! -d "$RUN_DIR" ]; then
  echo "FAIL: run-dir does not exist: $RUN_DIR" >&2
  echo "      Run and resume the skill first per SKILL.md, then point me at the run dir." >&2
  exit 2
fi

# ── 1. state.json all-final (no pending/collecting/analyzing) ────────────────
STATE_JSON="$RUN_DIR/state.json"
if [ ! -f "$STATE_JSON" ]; then
  fail "state.json not found in $RUN_DIR"
else
  # Valid terminal statuses: reported, unreachable, failed, skipped
  # state.json shape per SKILL.md spec: {"hosts": {"<name>": {"status": "...", ...}, ...}}
  PENDING_HOSTS="$(jq -r '
    .hosts | to_entries[]
    | select(.value.status | test("^(pending|collecting|analyzed)$"))
    | .key
  ' "$STATE_JSON" 2>/dev/null || echo "parse-error")"

  if [ -z "$PENDING_HOSTS" ] || [ "$PENDING_HOSTS" = "null" ]; then
    pass "state.json: all hosts in terminal status (no pending/collecting/analyzed)"
  else
    fail "state.json: hosts still in non-terminal status: $(echo "$PENDING_HOSTS" | tr '\n' ' ')"
  fi
fi

# ── 2. Exactly ONE fleet-summary.md ──────────────────────────────────────────
FLEET_COUNT="$(find "$RUN_DIR" -maxdepth 1 -name 'fleet-summary.md' | wc -l | tr -d ' ')"
if [ "$FLEET_COUNT" -eq 1 ]; then
  pass "fleet-summary.md: exactly 1 found (no duplicates)"
else
  fail "fleet-summary.md: expected exactly 1, found $FLEET_COUNT"
fi

# ── 3. SMOKE2 resume-idempotency: no host double-listed in fleet-summary.md ───
# A bug in --resume could re-append a host row to fleet-summary, producing two
# rows for the same host. Detect this by extracting the first-column identifier
# from every data row in the fleet-summary Markdown table, then checking for
# duplicates.  A directory cannot contain two files with the same name, so a
# filename-level dedup is vacuous — the real idempotency risk is in the table.
# Portable to bash 3.2 (macOS) — no associative arrays.
#
# Fleet-summary table row format (per SKILL.md):
#   | host | status | grade | critical | high | vantage | coverage_mode |
# Data rows start with '|' followed by non-dash/non-header content.
FLEET_SUMMARY_CHECK="$RUN_DIR/fleet-summary.md"
if [ -f "$FLEET_SUMMARY_CHECK" ]; then
  # Extract first column from data rows: lines matching ^| (non-header, non-separator)
  # Separator rows look like |---|---| so skip lines where col1 trims to only dashes/spaces.
  SUMMARY_HOSTS="$(grep -E '^\|[^|]' "$FLEET_SUMMARY_CHECK" 2>/dev/null \
    | awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}' \
    | grep -v '^[-[:space:]]*$' \
    | grep -v '^host$' \
    || true)"
  SUMMARY_HOST_COUNT="$(printf '%s\n' "$SUMMARY_HOSTS" | grep -c . || true)"
  SUMMARY_DUP_HOSTS="$(printf '%s\n' "$SUMMARY_HOSTS" | sort | uniq -d)"

  if [ -n "$SUMMARY_DUP_HOSTS" ]; then
    while IFS= read -r duphost; do
      [ -n "$duphost" ] && fail "resume-idempotency: host '$duphost' listed MORE THAN ONCE in fleet-summary.md (resume doubled a row)"
    done <<< "$SUMMARY_DUP_HOSTS"
  else
    pass "resume-idempotency: fleet-summary.md host table has no duplicate rows ($SUMMARY_HOST_COUNT distinct hosts)"
  fi

  # Cross-check: number of per-host .md reports should equal the number of
  # distinct hosts in fleet-summary (no orphan report from a spurious re-run).
  REPORT_COUNT="$(find "$RUN_DIR" -maxdepth 1 -name '*.md' ! -name 'fleet-summary.md' 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$REPORT_COUNT" -eq "$SUMMARY_HOST_COUNT" ]; then
    pass "report-count matches fleet-summary host count ($REPORT_COUNT = $SUMMARY_HOST_COUNT)"
  else
    fail "report-count ($REPORT_COUNT) != fleet-summary distinct host count ($SUMMARY_HOST_COUNT) — orphan or missing report from a re-run"
  fi
else
  fail "fleet-summary.md not found — cannot run SMOKE2 idempotency checks (check section 2)"
fi

# ── 4. `reported` hosts' report mtimes unchanged across the resume ───────────
# If a baseline file exists, use it to verify reported hosts were not touched.
BASELINE="$RUN_DIR/smoke-resume-baseline.json"
if [ -f "$BASELINE" ] && command -v jq >/dev/null 2>&1; then
  REPORTED_HOST="$(jq -r '.reported_host // empty' "$BASELINE" 2>/dev/null || true)"
  RECORDED_MTIME="$(jq -r '.mtime // empty' "$BASELINE" 2>/dev/null || true)"

  if [ -n "$REPORTED_HOST" ] && [ -n "$RECORDED_MTIME" ]; then
    # Look for the host's report file (may be named <host>.md)
    HOST_REPORT="$RUN_DIR/${REPORTED_HOST}.md"
    if [ -f "$HOST_REPORT" ]; then
      CURRENT_MTIME="$(stat -c '%Y' "$HOST_REPORT" 2>/dev/null || stat -f '%m' "$HOST_REPORT" 2>/dev/null)"
      if [ "$CURRENT_MTIME" -eq "$RECORDED_MTIME" ]; then
        pass "mtime baseline: $REPORTED_HOST report unchanged after resume (mtime=$CURRENT_MTIME)"
      else
        fail "mtime baseline: $REPORTED_HOST report was MODIFIED after resume (recorded=$RECORDED_MTIME current=$CURRENT_MTIME) — state=reported hosts must not be re-written"
      fi
    else
      fail "mtime baseline: host report not found: $HOST_REPORT"
    fi
  else
    fail "smoke-resume-baseline.json: missing reported_host or mtime fields"
  fi
else
  # No baseline — verify at least that all `reported` hosts have report files
  if [ -f "$STATE_JSON" ] && command -v jq >/dev/null 2>&1; then
    REPORTED_HOSTS="$(jq -r '.hosts | to_entries[] | select(.value.status=="reported") | .key' "$STATE_JSON" 2>/dev/null || true)"
    if [ -n "$REPORTED_HOSTS" ]; then
      MISSING_REPORTS=false
      while IFS= read -r rhost; do
        if [ ! -f "$RUN_DIR/${rhost}.md" ]; then
          fail "reported host '$rhost' has no per-host report file in $RUN_DIR"
          MISSING_REPORTS=true
        fi
      done <<< "$REPORTED_HOSTS"
      if ! $MISSING_REPORTS; then
        pass "all state=reported hosts have report files (no baseline file — mtime unchanged assertion skipped)"
      fi
    else
      pass "no hosts in reported state found in state.json (baseline check skipped)"
    fi
  else
    pass "no smoke-resume-baseline.json found — mtime unchanged assertion skipped (create it before the resume to enable)"
  fi
fi

# ── 5. Fleet-summary lists both fixture hosts + the unreachable host ─────────
FLEET_SUMMARY="$RUN_DIR/fleet-summary.md"
if [ -f "$FLEET_SUMMARY" ]; then
  if grep -qi 'UNREACHABLE' "$FLEET_SUMMARY"; then
    pass "fleet-summary: UNREACHABLE entry present (black-hole host)"
  else
    fail "fleet-summary: no UNREACHABLE entry (black-hole host should appear)"
  fi

  # Should have ≥2 rows (misconfigured + hardened), possibly 3 (+ unreachable)
  DATA_ROWS="$(grep -cE '^\|[^-]' "$FLEET_SUMMARY" 2>/dev/null || echo 0)"
  if [ "$DATA_ROWS" -ge 2 ]; then
    pass "fleet-summary: $DATA_ROWS data rows (≥2 hosts listed)"
  else
    fail "fleet-summary: only $DATA_ROWS data rows (expected ≥2)"
  fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== smoke-resume RESULTS ==="
echo "RUN_DIR: $RUN_DIR"
echo "PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
if [ "$FAIL_COUNT" -eq 0 ]; then
  echo "SMOKE2: ALL INVARIANTS HOLD"
  exit 0
else
  echo "SMOKE2: $FAIL_COUNT invariant(s) FAILED"
  exit 1
fi
