#!/usr/bin/env bash
# Task 6 — infra-collect.sh FAILURE HARDENING contract test (docker-guarded).
# TDD: written RED first; the hardening paths (host-key fail-fast, defensive
# per-check error capture, $SECONDS wall-clock guard, lynis<3.0 degradation) are
# authored GREEN until every scenario below passes.
#
# =========================================================================
# SAFETY (AC8 / host-key isolation — READ BEFORE EDITING):
#   This test sets HOME=$(mktemp -d) AND drives the collector with an ISOLATED
#   --known-hosts file inside a temp dir. The real ~/.ssh is NEVER read, written,
#   poisoned, or touched. The poisoned known_hosts entry (scenario a) lives ONLY
#   in $TEST_HOME/known_hosts. A trap removes $TEST_HOME + $WORK_DIR on EXIT.
#   ssh on macOS resolves ~ via getpwuid() not $HOME, so the collector's
#   --known-hosts flag (NOT HOME) is what actually redirects host-key
#   verification — but we ALSO set HOME=$(mktemp -d) as defense-in-depth so no
#   tool in this test can ever resolve the operator's real known_hosts.
# =========================================================================
#
# Scenarios (plan Task 6 RED):
#   (a) AC8 host-key mismatch: poison the isolated known_hosts with a WRONG key
#       for the misconfigured fixture (127.0.0.1:2201) → bundle/<host>.phase0.json
#       with reason `host-key-mismatch` (CRITICAL), zero post-handshake commands
#       ran on the container (no remote run-dir created), exit 0 (host FAILED, not
#       crash). LC_ALL=C makes the `REMOTE HOST IDENTIFICATION HAS CHANGED` match
#       locale-stable.
#   (b) IC-7 negative: a probed command emits NO sanity marker (forced via a
#       fixture command lacking the expected marker) → that check status `error`
#       with a `raw_ref`; the bundle is STILL valid JSON (defensive jq under
#       set -e — one bad parse never aborts the bundle).
#   (c) IC-9 wall-clock: WALL_CLOCK_LIMIT_S=1 env override against the
#       misconfigured fixture → after the budget, remaining checks get status
#       `skipped` with a wall-clock note; bundle valid; $SECONDS-based.
#   (d) E12 lynis<3.0: PATH-shim a fake `lynis` on the container reporting
#       `lynis 2.6.8` → tool_availability.lynis records the version string AND
#       lynis-sourced checks degrade with `DEGRADED (lynis 2.6.8 < 3.0)`
#       notation; manual-fallback checks (sshd -T etc.) still populate.
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
command -v ssh-keygen >/dev/null 2>&1 || { echo "SKIP: ssh-keygen required for known_hosts poisoning"; exit 0; }

COMPOSE_PROJECT="zuvo-infra-hardening"
TEST_KEY="$FIXT_DIR/.keys/zuvo_test_key"

# =========================================================================
# SAFETY: isolated HOME + isolated known_hosts (NEVER the real ~/.ssh).
#
#   TEST_HOME = $(mktemp -d) is the isolated HOME the COLLECTOR (and the ssh it
#   spawns) runs under — so no ssh in this test can ever resolve the operator's
#   real ~/.ssh/known_hosts. The collector's --known-hosts flag is the
#   authoritative redirect; HOME isolation is belt-and-suspenders.
#
#   REAL_HOME is captured FIRST and used for every `docker`/`docker compose`
#   command: the compose CLI plugin lives at $HOME/.docker/cli-plugins, so a
#   `docker compose` run under the isolated HOME loses its plugin and rejects
#   `-p`. We therefore NEVER globally export HOME — instead `dc()` restores
#   REAL_HOME for docker, and collector calls set HOME=$TEST_HOME inline.
# =========================================================================
REAL_HOME="$HOME"
TEST_HOME="$(mktemp -d)"
WORK_DIR="$(mktemp -d)"

# All docker / docker-compose lifecycle commands run under the operator's real
# HOME so the compose CLI plugin resolves; they never touch ~/.ssh.
dc() { HOME="$REAL_HOME" docker compose -p "$COMPOSE_PROJECT" -f "$FIXT_DIR/docker-compose.yml" "$@"; }
dex() { HOME="$REAL_HOME" docker "$@"; }

_cleanup() {
  dc down -v >/dev/null 2>&1 || true
  rm -rf "$TEST_HOME" "$WORK_DIR" 2>/dev/null || true
}
trap _cleanup EXIT

# ---------------------------------------------------------------------------
# Bring fixtures up (build + wait healthy).
# ---------------------------------------------------------------------------
ensure_fixtures || { echo "FAIL: ensure-fixtures failed"; exit 1; }

echo "Bringing fixtures up (compose build --wait)…"
if ! dc up -d --build --wait >/dev/null 2>&1; then
  echo "FAIL: docker compose up --wait failed for fixtures"
  dc ps || true
  exit 1
fi
pass "fixtures up (misconfigured:2201, hardened:2202, socks:1080)"

# Resolve the misconfigured container id (for auth-log / run-dir inspection).
MISCONF_CID="$(dc ps -q sshd-misconfigured 2>/dev/null)"
if [ -z "$MISCONF_CID" ]; then
  fail "could not resolve misconfigured container id"
fi

# Isolated known_hosts seeded with the REAL host keys for the good runs.
KNOWN_HOSTS="$TEST_HOME/known_hosts"
for PORT in 2201 2202; do
  ssh-keyscan -H -p "$PORT" 127.0.0.1 >> "$KNOWN_HOSTS" 2>/dev/null || true
done
chmod 600 "$KNOWN_HOSTS" 2>/dev/null || true

# Collector runs under the ISOLATED HOME (never the operator's ~/.ssh) and with
# the explicit isolated known_hosts path.
run_collector() {
  HOME="$TEST_HOME" bash "$COLLECTOR" --ssh-key "$TEST_KEY" --known-hosts "$KNOWN_HOSTS" "$@"
}

# ===========================================================================
# Scenario (a): AC8 host-key mismatch — poisoned known_hosts → phase0 fail-fast.
# ===========================================================================
echo ""
echo "### Scenario (a): AC8 — poisoned known_hosts → phase0 host-key-mismatch, fail-fast"

# A SEPARATE poisoned known_hosts (never the real one). It contains a WRONG key
# for [127.0.0.1]:2201 — generated locally, NOT the container's real key — so
# ssh's StrictHostKeyChecking=yes raises REMOTE HOST IDENTIFICATION HAS CHANGED.
POISON_KH="$TEST_HOME/known_hosts.poison"
# Generate a throwaway host key and register its public half under the fixture's
# hashed-or-plain hostport. Use a plain (un-hashed) entry so the wrong key is
# unambiguously matched to [127.0.0.1]:2201.
WRONG_KEY="$TEST_HOME/wrong_host_key"
ssh-keygen -t ed25519 -N "" -C "zuvo-wrong-host-key" -f "$WRONG_KEY" >/dev/null 2>&1 || true
WRONG_PUB="$(awk '{print $1" "$2}' "$WRONG_KEY.pub" 2>/dev/null)"
printf '[127.0.0.1]:2201 %s\n' "$WRONG_PUB" > "$POISON_KH"
chmod 600 "$POISON_KH" 2>/dev/null || true

# Pre-state: confirm NO zuvo run-dir exists on the container yet.
dex exec "$MISCONF_CID" sh -c 'rm -rf /tmp/ztest-hk-* 2>/dev/null' >/dev/null 2>&1 || true

BUNDLE_A="$WORK_DIR/a-hostkey.json"
set +e
LC_ALL=C HOME="$TEST_HOME" bash "$COLLECTOR" --ssh-key "$TEST_KEY" --known-hosts "$POISON_KH" \
  --host audituser@127.0.0.1:2201 --out "$BUNDLE_A" \
  --no-install --run-id "ztest-hk-$$" >"$WORK_DIR/a.log" 2>&1
RC=$?
set -e
# Host FAILED but the collector must NOT crash — fleet continuity (exit 0).
require_eq "$RC" "0" "(a) host-key mismatch should exit 0 (host FAILED, fleet continues; log: $WORK_DIR/a.log)"
pass "(a) collector exits 0 on host-key mismatch (no crash)"

# phase0 bundle written (collector writes phase0 to --out).
PHASE0_A="$BUNDLE_A"
[ -f "${BUNDLE_A%.json}.phase0.json" ] && PHASE0_A="${BUNDLE_A%.json}.phase0.json"
assert_file_exists "$PHASE0_A"
if ! jq -e . "$PHASE0_A" >/dev/null 2>&1; then
  fail "(a) phase0 bundle is not valid JSON: $(cat "$PHASE0_A")"
fi
pass "(a) phase0 bundle is valid JSON"

REASON_A="$(jq -r '.reason' "$PHASE0_A")"
require_eq "$REASON_A" "host-key-mismatch" "(a) phase0 reason should be host-key-mismatch"
pass "(a) phase0 reason: host-key-mismatch"

STATUS_A="$(jq -r '.status' "$PHASE0_A")"
require_eq "$STATUS_A" "FAILED" "(a) phase0 status should be FAILED (distinct from UNREACHABLE)"
pass "(a) phase0 status: FAILED (CRITICAL host-key)"

# The phase0 evidence must carry the mismatch marker (redacted is fine; the
# marker itself is not a secret).
if ! grep -qi 'REMOTE HOST IDENTIFICATION HAS CHANGED\|host key' "$PHASE0_A" 2>/dev/null; then
  fail "(a) phase0 stderr_evidence lacks the host-key-mismatch marker: $(cat "$PHASE0_A")"
fi
pass "(a) phase0 carries host-key-mismatch stderr evidence"

# Fail-fast proof: ZERO post-handshake commands ran on the container — no zuvo
# run-dir for this run-id was ever created (the run-dir claim happens only AFTER
# the host-key gate passes).
RUNDIR_COUNT="$(dex exec "$MISCONF_CID" sh -c 'ls -d /tmp/ztest-hk-* 2>/dev/null | wc -l' 2>/dev/null | tr -d '[:space:]')"
require_eq "${RUNDIR_COUNT:-0}" "0" "(a) a remote run-dir was created — battery ran despite host-key mismatch (fail-fast breach)"
pass "(a) zero post-handshake commands ran on container (no remote run-dir; fail-fast)"

# ===========================================================================
# Scenario (b): IC-7 negative — a check missing its sanity marker → status error
# with raw_ref; bundle still valid JSON (defensive jq under set -e).
# ===========================================================================
echo ""
echo "### Scenario (b): IC-7 negative — missing sanity marker → status error + raw_ref, bundle valid"
# Force IC-7 negative deterministically via the documented test-only env hook:
# ZUVO_FORCE_ERROR_CHECK names a check id (or comma list) whose parsed output is
# treated as missing-its-sanity-marker → status error + raw_ref. This exercises
# the defensive capture path without depending on a flaky truncated transport.
BUNDLE_B="$WORK_DIR/b-marker.json"
RAW_B="$WORK_DIR/b-raw"
mkdir -p "$RAW_B"
set +e
ZUVO_FORCE_ERROR_CHECK="IS1-lynis-hardening" run_collector \
  --host audituser@127.0.0.1:2201 --out "$BUNDLE_B" \
  --no-install --raw-dir "$RAW_B" --run-id "ztest-b-$$" >"$WORK_DIR/b.log" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "(b) collect should exit 0 even with a forced check error (log: $WORK_DIR/b.log)"
assert_file_exists "$BUNDLE_B"
if ! jq -e . "$BUNDLE_B" >/dev/null 2>&1; then
  fail "(b) bundle is NOT valid JSON after a forced check error (defensive-jq breach): $(cat "$BUNDLE_B")"
fi
pass "(b) bundle is valid JSON despite a forced check error (defensive jq)"

ERR_STATUS="$(jq -r '.checks[] | select(.id=="IS1-lynis-hardening") | .status' "$BUNDLE_B" | head -1)"
require_eq "$ERR_STATUS" "error" "(b) the marker-less check should have status=error (IC-7 negative)"
pass "(b) marker-less check status: error (IC-7 negative)"

ERR_RAWREF="$(jq -r '.checks[] | select(.id=="IS1-lynis-hardening") | .raw_ref // "null"' "$BUNDLE_B" | head -1)"
if [ "$ERR_RAWREF" = "null" ] || [ -z "$ERR_RAWREF" ]; then
  fail "(b) error check must carry a raw_ref to its captured output (got: '$ERR_RAWREF')"
fi
pass "(b) error check carries raw_ref: $ERR_RAWREF"

# Every OTHER check must still be present — one bad parse never aborts the bundle.
TOTAL_CHECKS_B="$(jq -r '.checks | length' "$BUNDLE_B")"
if [ "${TOTAL_CHECKS_B:-0}" -lt 2 ]; then
  fail "(b) bundle truncated to <2 checks after one error — the bad parse aborted the bundle"
fi
pass "(b) bundle retains all checks ($TOTAL_CHECKS_B) — one bad parse did not abort assembly"

# ===========================================================================
# Scenario (c): IC-9 wall-clock — WALL_CLOCK_LIMIT_S=0 → remaining checks skipped
# with a wall-clock note; bundle valid.
# ===========================================================================
echo ""
echo "### Scenario (c): IC-9 — WALL_CLOCK_LIMIT_S=0 → remaining checks skipped (wall-clock), bundle valid"
BUNDLE_C="$WORK_DIR/c-wallclock.json"
RAW_C="$WORK_DIR/c-raw"
mkdir -p "$RAW_C"
set +e
WALL_CLOCK_LIMIT_S=0 run_collector \
  --host audituser@127.0.0.1:2201 --out "$BUNDLE_C" \
  --no-install --raw-dir "$RAW_C" --run-id "ztest-c-$$" >"$WORK_DIR/c.log" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "(c) wall-clock-bounded collect should exit 0 (log: $WORK_DIR/c.log)"
assert_file_exists "$BUNDLE_C"
if ! jq -e . "$BUNDLE_C" >/dev/null 2>&1; then
  fail "(c) bundle is NOT valid JSON after wall-clock break: $(cat "$BUNDLE_C")"
fi
pass "(c) bundle is valid JSON after wall-clock break"

# At least one check is skipped with a wall-clock note.
SKIPPED_WC="$(jq -r '[.checks[] | select(.status=="skipped" and ((.evidence//"")|test("wall.?clock";"i")))] | length' "$BUNDLE_C")"
if [ "${SKIPPED_WC:-0}" -lt 1 ]; then
  fail "(c) no checks skipped with a wall-clock note (WALL_CLOCK_LIMIT_S=0 fires on first row: all skipped): $(jq -c '[.checks[]|{id,status,evidence}]' "$BUNDLE_C")"
fi
pass "(c) $SKIPPED_WC check(s) skipped with wall-clock note (IC-9, \$SECONDS-based)"

# ===========================================================================
# Scenario (d): E12 lynis<3.0 — shim a fake lynis reporting 2.6.8 → version
# recorded + lynis checks DEGRADED; manual fallback (sshd -T) still populates.
# ===========================================================================
echo ""
echo "### Scenario (d): E12 — lynis 2.6.8 shim → version recorded, lynis checks DEGRADED, fallbacks populate"
# Shadow the real lynis on the container with a fake one earlier in PATH.
# /usr/local/bin precedes /usr/bin in the default Ubuntu PATH, so the remote
# `lynis` the collector invokes genuinely returns version 2.6.8.
dex exec "$MISCONF_CID" sh -c 'cat > /usr/local/bin/lynis <<'"'"'SHIM'"'"'
#!/bin/sh
case "$1" in
  --version|version|show) echo "lynis 2.6.8" ;;
  *) echo "lynis 2.6.8"; echo "Hardening index : 60"; exit 0 ;;
esac
SHIM
chmod 0755 /usr/local/bin/lynis' >/dev/null 2>&1 \
  || { echo "SKIP: could not install lynis shim on container"; exit 0; }

BUNDLE_D="$WORK_DIR/d-oldlynis.json"
RAW_D="$WORK_DIR/d-raw"
mkdir -p "$RAW_D"
set +e
run_collector --host audituser@127.0.0.1:2201 --out "$BUNDLE_D" \
  --no-install --raw-dir "$RAW_D" --run-id "ztest-d-$$" >"$WORK_DIR/d.log" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "(d) collect with old-lynis shim should exit 0 (log: $WORK_DIR/d.log)"
assert_file_exists "$BUNDLE_D"
if ! jq -e . "$BUNDLE_D" >/dev/null 2>&1; then
  fail "(d) bundle is NOT valid JSON with old-lynis shim: $(cat "$BUNDLE_D")"
fi
pass "(d) bundle is valid JSON with old-lynis shim"

# tool_availability.lynis records the version STRING (not bare true).
LYNIS_AVAIL="$(jq -r '.tool_availability.lynis' "$BUNDLE_D")"
if ! printf '%s' "$LYNIS_AVAIL" | grep -q '2\.6\.8'; then
  fail "(d) tool_availability.lynis should record version 2.6.8 (got: '$LYNIS_AVAIL')"
fi
pass "(d) tool_availability.lynis records version: $LYNIS_AVAIL"

# Lynis-sourced checks degrade with the DEGRADED (lynis 2.6.8 < 3.0) notation.
LYNIS_NOTE="$(jq -r '.checks[] | select(.id|test("lynis")) | .evidence // ""' "$BUNDLE_D")"
if ! printf '%s' "$LYNIS_NOTE" | grep -qE 'DEGRADED \(lynis 2\.6\.8 < 3\.0\)'; then
  fail "(d) lynis-sourced check missing 'DEGRADED (lynis 2.6.8 < 3.0)' notation. Evidence: $LYNIS_NOTE"
fi
pass "(d) lynis-sourced check tagged DEGRADED (lynis 2.6.8 < 3.0)"

# Manual-fallback checks still populate: IS1-sshd-permitrootlogin (sshd -T) runs
# and is NOT skipped/error (it does not depend on lynis at all).
SSHD_STATUS="$(jq -r '.checks[] | select(.id=="IS1-sshd-permitrootlogin") | .status' "$BUNDLE_D" | head -1)"
case "$SSHD_STATUS" in
  ok|finding|insufficient-data) pass "(d) manual-fallback IS1-sshd-permitrootlogin still populates (status=$SSHD_STATUS)" ;;
  *) fail "(d) IS1-sshd-permitrootlogin should still run with old lynis (got status=$SSHD_STATUS)" ;;
esac

# ===========================================================================
# Scenario (e): Q11 gap — lynis ABSENT on hardened container (2202) → tool_availability.lynis
# == null AND IS1-lynis-hardening status == skipped (AC9 no-fabrication).
# The hardened fixture image installs only openssh-server + sudo, never lynis.
# ===========================================================================
echo ""
echo "### Scenario (e): Q11 — lynis absent on hardened container → tool_availability.lynis==null, IS1-lynis-hardening==skipped"
BUNDLE_E="$WORK_DIR/e-lynis-absent.json"
RAW_E="$WORK_DIR/e-raw"
mkdir -p "$RAW_E"
set +e
run_collector \
  --host audituser@127.0.0.1:2202 --out "$BUNDLE_E" \
  --no-install --raw-dir "$RAW_E" --run-id "ztest-e-$$" >"$WORK_DIR/e.log" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "(e) collect on lynis-absent hardened host should exit 0 (log: $WORK_DIR/e.log)"
assert_file_exists "$BUNDLE_E"
if ! jq -e . "$BUNDLE_E" >/dev/null 2>&1; then
  fail "(e) bundle is NOT valid JSON (lynis-absent run): $(cat "$BUNDLE_E")"
fi
pass "(e) bundle is valid JSON (lynis absent on hardened container)"

# tool_availability.lynis must be null — lynis is not installed.
LYNIS_AVAIL_E="$(jq -r '.tool_availability.lynis // "null"' "$BUNDLE_E")"
require_eq "$LYNIS_AVAIL_E" "null" "(e) tool_availability.lynis should be null when lynis is absent (got: '$LYNIS_AVAIL_E')"
pass "(e) tool_availability.lynis == null (lynis absent, AC9)"

# IS1-lynis-hardening must be status=skipped (AC9 — no fabrication when required tool absent).
LYNIS_CHECK_STATUS_E="$(jq -r '.checks[] | select(.id=="IS1-lynis-hardening") | .status' "$BUNDLE_E" | head -1)"
require_eq "$LYNIS_CHECK_STATUS_E" "skipped" "(e) IS1-lynis-hardening should be skipped when lynis absent (got: '$LYNIS_CHECK_STATUS_E')"
pass "(e) IS1-lynis-hardening status=skipped (lynis absent, AC9 no-fabrication)"

echo ""
echo "ALL INFRA-COLLECTOR-HARDENING ASSERTIONS PASSED"
