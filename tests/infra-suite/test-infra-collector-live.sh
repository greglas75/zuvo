#!/usr/bin/env bash
# Task 5 — infra-collect.sh CORE LIVE COLLECTION contract test (docker-guarded).
# TDD: written RED first (skeleton only emits `skipped` placeholders), then the
# live check battery is authored GREEN until every scenario below passes.
#
# This RED also doubles as the SMOKE1 single-host collect→bundle slice (rule 8b):
# the (a) scenario is a full live collect of one fixture host → IC-3 bundle.
#
# SAFETY: SSH state (known_hosts, identity) is isolated via explicit
# --ssh-key / --known-hosts flags passed to the collector — the real ~/.ssh is
# NEVER touched or read. The collector itself reads no key material
# (ssh-probe-protocol §4); ssh resolves -i and UserKnownHostsFile from the
# provided paths only.
#
# Scenarios (plan Task 5 RED):
#   (a) IC-7 positive: full collect vs misconfigured (audituser) → bundle valid
#       per IC-3 jq schema, privilege_mode: passwordless-sudo, lynis check has a
#       `Hardening index` marker AND that check is NOT `error`.
#   (b) AC4 no-sudo: collect as nosudo user → every needs_sudo:true check has
#       status insufficient-data, none ok; bundle privilege_mode reflects no-sudo.
#   (c) AC5 redaction: the 5 seeded secret values grep ZERO across bundle+raw dir;
#       `[REDACTED]` present where they were.
#   (d) AC1 collector half: black-hole 192.0.2.1 → phase0.json status UNREACHABLE,
#       exit 0, <10s (nc -zw5 preflight).
#   (e) AC9/AC6: --no-install on a fixture lacking trivy → trivy-dependent checks
#       status: skipped, tool_availability.trivy: null; grep bundle+raw for CVE- == 0.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE_DIR="$ROOT_DIR/tests/infra-suite"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
COLLECTOR="$ROOT_DIR/scripts/infra-collect.sh"
FIXT_DIR="$SUITE_DIR/fixtures"

# Docker SKIP guard (sourced; exits 0 cleanly when docker/compose absent).
# shellcheck source=tests/infra-suite/lib/docker-guard.sh
source "$SUITE_DIR/lib/docker-guard.sh"
# shellcheck source=tests/infra-suite/lib/ensure-fixtures.sh
source "$SUITE_DIR/lib/ensure-fixtures.sh"
# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required for this test"; exit 1; }
command -v nc >/dev/null 2>&1 || { echo "SKIP: nc (netcat) required for reachability preflight"; exit 0; }

COMPOSE_PROJECT="zuvo-infra-fixtures"
TEST_KEY="$FIXT_DIR/.keys/zuvo_test_key"

# Isolated SSH HOME — NEVER the real ~/.ssh (SAFETY).
TEST_HOME="$(mktemp -d)"
WORK_DIR="$(mktemp -d)"

_cleanup() {
  docker compose -p "$COMPOSE_PROJECT" -f "$FIXT_DIR/docker-compose.yml" down -v >/dev/null 2>&1 || true
  rm -rf "$TEST_HOME" "$WORK_DIR" 2>/dev/null || true
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Bring fixtures up (build + wait healthy).
# ---------------------------------------------------------------------------
ensure_fixtures || { echo "FAIL: ensure-fixtures failed"; exit 1; }

echo "Bringing fixtures up (compose build --wait)…"
if ! docker compose -p "$COMPOSE_PROJECT" -f "$FIXT_DIR/docker-compose.yml" up -d --build --wait >/dev/null 2>&1; then
  echo "FAIL: docker compose up --wait failed for fixtures"
  docker compose -p "$COMPOSE_PROJECT" -f "$FIXT_DIR/docker-compose.yml" ps || true
  exit 1
fi
pass "fixtures up (misconfigured:2201, hardened:2202, socks:1080)"

# ---------------------------------------------------------------------------
# Wire the test-only identity. The collector takes the key + known_hosts as
# PATHS (--ssh-key / --known-hosts), exactly as the skill passes the inventory
# ssh_key field; it never reads the key itself (ssh-probe-protocol §4). We seed
# known_hosts here so the collector's StrictHostKeyChecking=yes verifies an
# already-known key without ever weakening the flag.
#
# Why paths, not HOME isolation: ssh on macOS resolves ~ via getpwuid(), NOT
# $HOME, so an isolated HOME can't redirect ssh's config/known_hosts. The
# explicit path flags are the correct, portable mechanism.
# ---------------------------------------------------------------------------
KNOWN_HOSTS="$TEST_HOME/known_hosts"
for PORT in 2201 2202; do
  ssh-keyscan -H -p "$PORT" 127.0.0.1 >> "$KNOWN_HOSTS" 2>/dev/null || true
done
chmod 600 "$KNOWN_HOSTS" 2>/dev/null || true

# Helper to run the collector with the test identity + isolated known_hosts.
run_collector() {
  bash "$COLLECTOR" --ssh-key "$TEST_KEY" --known-hosts "$KNOWN_HOSTS" "$@"
}

# The 5 seeded secret values (from seed-manifest.md env.seed).
SEEDED_SECRETS=(
  "zuvo-seed-dbpass-7f3a"
  "zuvo-seed-apikey-9c1e"
  "zuvo-seed-jwt-4b8d"
  "zuvo-seed-redispw-2e6f"
  "zuvo-seed-aws-5d9b"
)

# ===========================================================================
# Scenario (a): IC-7 positive — full collect vs misconfigured as audituser.
# ===========================================================================
echo ""
echo "### Scenario (a): IC-7 positive — full collect (audituser, passwordless-sudo)"
BUNDLE_A="$WORK_DIR/a-misconfigured.json"
RAW_A="$WORK_DIR/a-raw"
mkdir -p "$RAW_A"
set +e
run_collector --host audituser@127.0.0.1:2201 --out "$BUNDLE_A" \
  --no-install --raw-dir "$RAW_A" --run-id "ztest-a-$$" >"$WORK_DIR/a.log" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "scenario (a) collect should exit 0 (log: $WORK_DIR/a.log)"
assert_file_exists "$BUNDLE_A"
if ! jq -e . "$BUNDLE_A" >/dev/null 2>&1; then
  fail "scenario (a): bundle is not valid JSON: $(cat "$BUNDLE_A")"
fi
pass "(a) bundle is valid JSON"

# IC-3 schema: required keys present.
for KEY in host collected_at privilege_mode tool_availability tools_installed_this_run checks external; do
  jq -e "has(\"$KEY\")" "$BUNDLE_A" >/dev/null 2>&1 || fail "(a) bundle missing key: $KEY"
done
pass "(a) bundle has all IC-3 top-level keys"

# privilege_mode = passwordless-sudo (audituser has NOPASSWD:ALL).
PM_A="$(jq -r '.privilege_mode' "$BUNDLE_A")"
require_eq "$PM_A" "passwordless-sudo" "(a) privilege_mode should be passwordless-sudo"
pass "(a) privilege_mode: passwordless-sudo"

# lynis check carries a `Hardening index` marker AND is NOT error.
LYNIS_CHECK="$(jq -r '.checks[] | select(.source=="lynis" or (.id|test("lynis"))) | @json' "$BUNDLE_A" | head -1)"
if [ -z "$LYNIS_CHECK" ]; then
  # Fall back: any check whose evidence contains the marker.
  LYNIS_CHECK="$(jq -r '.checks[] | select((.evidence//"")|test("Hardening index")) | @json' "$BUNDLE_A" | head -1)"
fi
if [ -z "$LYNIS_CHECK" ]; then
  fail "(a) no lynis check found in bundle (expected a lynis-sourced check with Hardening index)"
fi
# Marker present somewhere in the lynis evidence/raw.
if ! grep -rqi 'Hardening index' "$BUNDLE_A" "$RAW_A" 2>/dev/null; then
  fail "(a) lynis 'Hardening index' marker absent from bundle+raw (IC-7 sanity marker)"
fi
pass "(a) lynis 'Hardening index' marker present (IC-7)"
LYNIS_STATUS="$(printf '%s' "$LYNIS_CHECK" | jq -r '.status')"
if [ "$LYNIS_STATUS" = "error" ]; then
  fail "(a) lynis check is status=error (IC-7 expects a successful parse): $LYNIS_CHECK"
fi
pass "(a) lynis check NOT error (status=$LYNIS_STATUS)"

# ===========================================================================
# Scenario (b): AC4 no-sudo — collect as nosudo user.
# ===========================================================================
echo ""
echo "### Scenario (b): AC4 — collect as nosudo → needs_sudo checks insufficient-data"
BUNDLE_B="$WORK_DIR/b-nosudo.json"
set +e
run_collector --host nosudo@127.0.0.1:2201 --out "$BUNDLE_B" \
  --no-install --run-id "ztest-b-$$" >"$WORK_DIR/b.log" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "scenario (b) collect should exit 0 (log: $WORK_DIR/b.log)"
assert_file_exists "$BUNDLE_B"

# nosudo user HAS the sudo binary but no rights → limited-sudo OR no-sudo; either
# way it is unprivileged. Per AC4/§3 the relevant invariant is: needs_sudo checks
# are insufficient-data, none ok, and privilege_mode is NOT a privileged value.
PM_B="$(jq -r '.privilege_mode' "$BUNDLE_B")"
case "$PM_B" in
  limited-sudo|no-sudo) : ;;
  *) fail "(b) privilege_mode '$PM_B' should be limited-sudo or no-sudo (unprivileged)" ;;
esac
pass "(b) privilege_mode unprivileged: $PM_B"

# Every needs_sudo:true check is insufficient-data; none ok.
SUDO_STATUSES="$(jq -r '[.checks[] | select(.needs_sudo==true) | .status] | unique | sort | @json' "$BUNDLE_B")"
if [ "$(jq -r --argjson s "$SUDO_STATUSES" -n '$s | length')" -eq 0 ]; then
  fail "(b) no needs_sudo:true checks present in bundle to validate AC4"
fi
# none ok
OK_COUNT="$(jq -r '[.checks[] | select(.needs_sudo==true and .status=="ok")] | length' "$BUNDLE_B")"
require_eq "$OK_COUNT" "0" "(b) needs_sudo checks must never be 'ok' when unprivileged (AC4)"
pass "(b) zero needs_sudo checks are 'ok'"
# all insufficient-data, EXCEPT checks that the E3 limited-sudo allowlist-aware
# probe (commit b4c8759) ran directly and annotated with the
# "[via limited-sudo allowlist]" evidence marker — those are excluded from the
# must-be-insufficient-data set because they legitimately surface a real result.
NON_ISD="$(jq -r '[.checks[] | select(.needs_sudo==true and .status!="insufficient-data" and ((.evidence // "") | contains("[via limited-sudo allowlist]") | not))] | length' "$BUNDLE_B")"
require_eq "$NON_ISD" "0" "(b) every needs_sudo check (excl. limited-sudo allowlist probes) should be insufficient-data; statuses seen: $SUDO_STATUSES"
pass "(b) all needs_sudo:true checks are insufficient-data, except limited-sudo allowlist probes (AC4/E3)"

# E3 exception, explicit (commit b4c8759): IS1-sshd-permitrootlogin reads a
# world-readable file directly under limited-sudo (no allowlist grant needed),
# so on the misconfigured fixture (PermitRootLogin yes) it must surface as a
# real "finding" — not insufficient-data. Documents the intentional exception.
IS1_STATUS_B="$(jq -r '.checks[] | select(.id=="IS1-sshd-permitrootlogin") | .status' "$BUNDLE_B")"
require_eq "$IS1_STATUS_B" "finding" "(b) IS1-sshd-permitrootlogin should be status=finding under limited-sudo (E3 world-readable exception)"
pass "(b) IS1-sshd-permitrootlogin status=finding on misconfigured fixture under limited-sudo (E3)"

# ===========================================================================
# Scenario (c): AC5 redaction — 5 seeded secrets grep ZERO across bundle+raw.
# ===========================================================================
echo ""
echo "### Scenario (c): AC5 — secret redaction total across bundle+raw"
# Re-use scenario (a) artifacts (full run, raw dir captured).
LEAKS=0
for SECRET in "${SEEDED_SECRETS[@]}"; do
  # `|| true`: grep exits 1 when there are no matches (the DESIRED outcome);
  # under the inherited `set -e`/pipefail that would silently abort the test.
  HITS="$( { grep -rcF -- "$SECRET" "$BUNDLE_A" "$RAW_A" 2>/dev/null || true; } | awk -F: '{s+=$2} END{print s+0}')"
  if [ "${HITS:-0}" -ne 0 ]; then
    echo "  LEAK: '$SECRET' found $HITS time(s) in bundle/raw"
    LEAKS=$((LEAKS + 1))
  fi
done
require_eq "$LEAKS" "0" "(c) seeded secrets leaked: $LEAKS/5 (AC5 redaction breach)"
pass "(c) 0/5 seeded secrets found across bundle+raw (AC5)"
# [REDACTED] marker present where secrets were (the .env / redis config dumps).
if ! grep -rqF '[REDACTED]' "$BUNDLE_A" "$RAW_A" 2>/dev/null; then
  fail "(c) no [REDACTED] markers present — redaction should have replaced the secret values"
fi
pass "(c) [REDACTED] markers present where secrets were"

# --- redis requirepass redaction (SED_REDACT RULE 2; space separator) --------
# The IS10 check greps requirepass/bind/protected-mode from /etc/redis/redis.conf.
# The fixture redis.conf carries `requirepass zuvo-seed-redispw-2e6f` (space sep,
# NOT key=value), which RULE 1 cannot match ("requirepass" has no sensitive
# substring). RULE 2 must redact it. The seed value is already covered by the
# 5-secret loop above (it also lives in env.seed's REDIS_URL), but assert it
# EXPLICITLY against the IS10 evidence so a RULE-2 regression is caught precisely.
# NB: jq `first(...)` returns the WHOLE (multi-line) evidence string of the first
# matching check. A shell `| head -1` here would truncate to the first LINE and
# silently drop the requirepass / key-name lines below it — do NOT add it.
IS10_EVID="$(jq -r 'first(.checks[] | select(.id|test("^IS10-")) | .evidence) // ""' "$BUNDLE_A")"
if printf '%s' "$IS10_EVID" | grep -qF 'zuvo-seed-redispw-2e6f'; then
  fail "(c) redis requirepass seed value LEAKED in IS10 evidence (SED_REDACT RULE 2 miss): $IS10_EVID"
fi
pass "(c) redis requirepass seed value redacted in IS10 evidence (RULE 2)"
# And the redaction marker is present on the requirepass line specifically.
if printf '%s' "$IS10_EVID" | grep -qiE '^[[:space:]]*requirepass[[:space:]]'; then
  if ! printf '%s' "$IS10_EVID" | grep -qiE '^[[:space:]]*requirepass[[:space:]]+\[REDACTED\]'; then
    fail "(c) IS10 requirepass line present but value not [REDACTED]: $IS10_EVID"
  fi
  pass "(c) IS10 requirepass line redacted to [REDACTED]"
fi

# --- IS12 reports key NAMES, never values ------------------------------------
# IS12 must flag the world-readable .env (path + perms + key NAMES + count) and
# must NOT cat raw values. Assert: evidence contains the world-readable marker
# and at least one KEY NAME, but none of the 5 seed VALUES.
# first(...) keeps the FULL multi-line evidence (marker + key-name lines). A
# `| head -1` would drop every key name and falsely fail the names-present check.
IS12_EVID="$(jq -r 'first(.checks[] | select(.id|test("^IS12-")) | .evidence) // ""' "$BUNDLE_A")"
IS12_STATUS="$(jq -r 'first(.checks[] | select(.id|test("^IS12-")) | .status) // ""' "$BUNDLE_A")"
if [ "$IS12_STATUS" = "ok" ]; then
  # IS12 ran (privileged): it must flag the file and list key names, no values.
  if ! printf '%s' "$IS12_EVID" | grep -qF 'world-readable secret file'; then
    fail "(c) IS12 ran but evidence lacks the world-readable marker: $IS12_EVID"
  fi
  if ! printf '%s' "$IS12_EVID" | grep -qE 'DB_PASSWORD|API_KEY|JWT_SECRET|REDIS_URL|AWS_SECRET_ACCESS_KEY'; then
    fail "(c) IS12 evidence must list .env key NAMES (none found): $IS12_EVID"
  fi
  pass "(c) IS12 evidence lists key NAMES + world-readable marker (status=ok)"
  for SECRET in "${SEEDED_SECRETS[@]}"; do
    if printf '%s' "$IS12_EVID" | grep -qF -- "$SECRET"; then
      fail "(c) IS12 evidence LEAKED seed value '$SECRET' (must report names only): $IS12_EVID"
    fi
  done
  pass "(c) IS12 evidence contains 0/5 seed VALUES (names-only, value-leak structurally impossible)"
else
  # Unprivileged: IS12 needs sudo, so insufficient-data is acceptable (no values
  # collected at all → value-leak trivially impossible).
  pass "(c) IS12 not run as ok (status=$IS12_STATUS) — no raw .env values collected"
fi

# ===========================================================================
# Scenario (d): AC1 collector half — black-hole → phase0 UNREACHABLE, <10s.
# ===========================================================================
echo ""
echo "### Scenario (d): AC1 — black-hole 192.0.2.1 → phase0 UNREACHABLE, exit 0, <10s"
BUNDLE_D="$WORK_DIR/d-blackhole.json"
set +e
T0=$(date +%s)
run_collector --host audituser@192.0.2.1 --out "$BUNDLE_D" \
  --no-install --run-id "ztest-d-$$" >"$WORK_DIR/d.log" 2>&1
RC=$?
T1=$(date +%s)
set -e
require_eq "$RC" "0" "(d) black-hole collect should exit 0 (fleet continuity, AC1)"
pass "(d) black-hole collect exits 0"
ELAPSED=$((T1 - T0))
if [ "$ELAPSED" -ge 10 ]; then
  fail "(d) black-hole took ${ELAPSED}s — nc -zw5 preflight should fail-fast <10s"
fi
pass "(d) black-hole fails fast in ${ELAPSED}s (<10s)"
# A phase0.json is written. Collector writes phase0 to --out (per skeleton phase0_writer).
PHASE0_D="$BUNDLE_D"
[ -f "${BUNDLE_D%.json}.phase0.json" ] && PHASE0_D="${BUNDLE_D%.json}.phase0.json"
assert_file_exists "$PHASE0_D"
STATUS_D="$(jq -r '.status' "$PHASE0_D")"
require_eq "$STATUS_D" "UNREACHABLE" "(d) phase0 status should be UNREACHABLE"
pass "(d) phase0.json status: UNREACHABLE (AC1 collector half)"

# ===========================================================================
# Scenario (e): AC9/AC6 — --no-install without trivy → trivy checks skipped,
# tool_availability.trivy null, zero CVE- across bundle+raw.
# ===========================================================================
echo ""
echo "### Scenario (e): AC9/AC6 — no trivy → trivy checks skipped, no CVE leakage"
# Re-use scenario (a) bundle+raw: misconfigured fixture has NO trivy installed,
# run was --no-install, so trivy must be unavailable and its checks skipped.
TRIVY_AVAIL="$(jq -r '.tool_availability.trivy' "$BUNDLE_A")"
require_eq "$TRIVY_AVAIL" "null" "(e) tool_availability.trivy should be null (not installed, --no-install)"
pass "(e) tool_availability.trivy: null"
# Trivy-dependent checks (IS9 image CVE) are status: skipped (not error, not ok).
TRIVY_CHECK_BAD="$(jq -r '[.checks[] | select((.source//"")=="trivy" or (.id|test("image-critical-cve|known-cve"))) | select(.status!="skipped" and .status!="insufficient-data")] | length' "$BUNDLE_A")"
require_eq "$TRIVY_CHECK_BAD" "0" "(e) trivy-dependent checks must be skipped when trivy absent"
pass "(e) trivy-dependent checks are skipped"
# AC6: no CVE- string anywhere in bundle+raw without scanner evidence.
CVE_HITS="$( { grep -rcF -- "CVE-" "$BUNDLE_A" "$RAW_A" 2>/dev/null || true; } | awk -F: '{s+=$2} END{print s+0}')"
require_eq "${CVE_HITS:-0}" "0" "(e) found CVE- strings without scanner evidence (AC6 breach): $CVE_HITS"
pass "(e) 0 CVE- strings across bundle+raw (AC6)"

# ===========================================================================
# Quote-safe transport proof: a long-mode battery command containing a single
# quote (awk '{print $1}') must execute and parse — proving the base64 transport
# is robust against single quotes (PREREQ B-infra-collect-nohup-quote-transport).
# Scenario (a) ran the full battery (which includes single-quote awk/find lines);
# the bundle validating as JSON + lynis parsing already exercise this. Assert the
# IS2 uid0 check (awk '($3==0){print $1}') did not error.
# ===========================================================================
echo ""
echo "### Quote-safe transport proof (single-quote battery command survives)"
IS2_STATUS="$(jq -r '.checks[] | select(.id|test("^IS2-")) | .status' "$BUNDLE_A" | head -1)"
if [ -z "$IS2_STATUS" ]; then
  fail "quote-safe: no IS2 check in bundle to validate single-quote transport"
fi
if [ "$IS2_STATUS" = "error" ]; then
  fail "quote-safe: IS2 single-quote awk check errored — transport not quote-safe"
fi
pass "quote-safe transport: IS2 single-quote awk check executed cleanly (status=$IS2_STATUS)"

# ===========================================================================
# Scenario (f): hardened fixture at audituser@127.0.0.1:2202 — bundle valid
# AND IS1-sshd-permitrootlogin evidence does NOT contain `PermitRootLogin yes`.
# (hardened sshd_config has `PermitRootLogin no`.)
# ===========================================================================
echo ""
echo "### Scenario (f): hardened fixture — bundle valid, IS1-sshd-permitrootlogin not 'yes'"
BUNDLE_F="$WORK_DIR/f-hardened.json"
RAW_F="$WORK_DIR/f-raw"
mkdir -p "$RAW_F"
set +e
run_collector --host audituser@127.0.0.1:2202 --out "$BUNDLE_F" \
  --no-install --raw-dir "$RAW_F" --run-id "ztest-f-$$" >"$WORK_DIR/f.log" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "scenario (f) hardened collect should exit 0 (log: $WORK_DIR/f.log)"
assert_file_exists "$BUNDLE_F"
if ! jq -e . "$BUNDLE_F" >/dev/null 2>&1; then
  fail "scenario (f): bundle is not valid JSON: $(cat "$BUNDLE_F")"
fi
pass "(f) bundle is valid JSON"

# IC-3 schema: required keys present.
for KEY in host collected_at privilege_mode tool_availability tools_installed_this_run checks external; do
  jq -e "has(\"$KEY\")" "$BUNDLE_F" >/dev/null 2>&1 || fail "(f) bundle missing key: $KEY"
done
pass "(f) bundle has all IC-3 top-level keys"

# IS1-sshd-permitrootlogin evidence must NOT contain `PermitRootLogin yes`
# (hardened fixture has PermitRootLogin no).
PR_EVIDENCE="$(jq -r '.checks[] | select(.id=="IS1-sshd-permitrootlogin") | .evidence // ""' "$BUNDLE_F")"
if [ -z "$PR_EVIDENCE" ] && [ "$(jq -r '.checks[] | select(.id=="IS1-sshd-permitrootlogin") | .status' "$BUNDLE_F")" = "insufficient-data" ]; then
  # Acceptable: audituser may not have sudo on hardened; in that case the check
  # is insufficient-data, which means root-login status was not asserted at all —
  # the constraint `not contains yes` is trivially satisfied.
  pass "(f) IS1-sshd-permitrootlogin insufficient-data (no sudo on hardened fixture) — constraint satisfied"
else
  if echo "$PR_EVIDENCE" | grep -iq 'PermitRootLogin yes'; then
    fail "(f) IS1-sshd-permitrootlogin evidence contains 'PermitRootLogin yes' on hardened host"
  fi
  pass "(f) IS1-sshd-permitrootlogin evidence does NOT contain 'PermitRootLogin yes' (hardened)"
fi

echo ""
echo "ALL INFRA-COLLECTOR-LIVE ASSERTIONS PASSED"
