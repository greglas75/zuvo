#!/usr/bin/env bash
# Task 7 — infra-collect.sh EXTERNAL VANTAGE (proxy) contract test (docker-guarded).
# TDD: written RED first (the external leg is unimplemented — write_bundle hard-codes
# external.vantage="none" with no proxy state machine and no proxychains/nuclei
# command emission), then the external leg is authored GREEN until every scenario
# below passes.
#
# Contract (spec IC-4 / plan Task 7):
#   - nmap (-sT) and testssl.sh are routed via proxychains-ng (NEVER testssl native
#     --proxy with SOCKS); nuclei via its native -proxy with a PINNED tag allowlist.
#   - nuclei tag allowlist is EXACTLY:
#       -tags exposures,misconfiguration,technologies,ssl,dns
#       -exclude-tags intrusive,dos,fuzz,bruteforce,default-login
#     and NO other nuclei tag set ever appears (AC3).
#   - external.vantage ∈ proxy|direct|none|failed:
#       proxy reachable           → proxy
#       proxy set but unreachable → failed
#       --skip-external / no proxy → none
#       proxychains-ng absent      → none + preflight warning (IC-4)
#
# SAFETY: SSH/proxy state is isolated; the real ~/.ssh is NEVER touched. The SOCKS
# proxy is the TEST-ONLY loopback container from the fixture rig (127.0.0.1:1080).
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

COMPOSE_PROJECT="zuvo-infra-fixtures-ext"
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
# Bring fixtures up (build + wait healthy) — incl. the socks-proxy service.
# ---------------------------------------------------------------------------
ensure_fixtures || { echo "FAIL: ensure-fixtures failed"; exit 1; }

echo "Bringing fixtures up (compose build --wait, incl. socks-proxy)…"
if ! docker compose -p "$COMPOSE_PROJECT" -f "$FIXT_DIR/docker-compose.yml" up -d --build --wait >/dev/null 2>&1; then
  echo "FAIL: docker compose up --wait failed for fixtures"
  docker compose -p "$COMPOSE_PROJECT" -f "$FIXT_DIR/docker-compose.yml" ps || true
  exit 1
fi
pass "fixtures up (misconfigured:2201, hardened:2202, socks:1080)"

# The published SOCKS proxy must actually accept a TCP connection before the live
# scenarios rely on it (the container reports healthy on its own port mapping).
if ! nc -z 127.0.0.1 1080 >/dev/null 2>&1; then
  echo "SKIP: SOCKS proxy 127.0.0.1:1080 not accepting connections (proxy container not published)"
  exit 0
fi
pass "SOCKS proxy reachable on 127.0.0.1:1080"

KNOWN_HOSTS="$TEST_HOME/known_hosts"
for PORT in 2201 2202; do
  ssh-keyscan -H -p "$PORT" 127.0.0.1 >> "$KNOWN_HOSTS" 2>/dev/null || true
done
chmod 600 "$KNOWN_HOSTS" 2>/dev/null || true

run_collector() {
  bash "$COLLECTOR" --ssh-key "$TEST_KEY" --known-hosts "$KNOWN_HOSTS" "$@"
}

PROXY_OK="socks5://127.0.0.1:1080"
PROXY_DEAD="socks5://127.0.0.1:9999"

# proxychains-ng presence gate. Scenarios (a)/(b)/(c) require a proxychains-ng
# binary on the laptop (the collector wraps nmap/testssl with it; IC-4). When it
# is absent, those three SKIP cleanly (suite convention — mirrors the docker/nc
# guards). Scenarios (d) (--skip-external) and (e) (proxychains ABSENT path) do
# NOT need it present and always run. We never FAIL merely because the operator
# laptop lacks proxychains — that is the IC-4 degrade, exercised by (e).
HAVE_PROXYCHAINS=false
for B in proxychains4 proxychains-ng proxychains; do
  if command -v "$B" >/dev/null 2>&1; then HAVE_PROXYCHAINS=true; break; fi
done

# ===========================================================================
# Scenario (a): AC3 nuclei-tags — dry-run command audit with a proxy.
# proxychains wraps nmap -sT AND testssl.sh; nuclei uses native -proxy with the
# EXACT pinned tag allowlist; negative asserts: no intrusive tags, no bare nuclei
# without the allowlist.
# ===========================================================================
echo ""
echo "### Scenario (a): AC3 — dry-run proxychains nmap/testssl + nuclei pinned tags"
if [ "$HAVE_PROXYCHAINS" != true ]; then
  echo "SKIP: proxychains-ng not installed — (a) requires it to print the wrapped external commands (IC-4 degrade is covered by (e))"
else
DRY_OUT="$WORK_DIR/a-dry.log"
set +e
bash "$COLLECTOR" --dry-run --no-install \
  --host audituser@127.0.0.1:2201 --out "$WORK_DIR/a-dry.json" \
  --proxy "$PROXY_OK" >"$DRY_OUT" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "(a) dry-run with --proxy should exit 0 (log: $DRY_OUT)"
pass "(a) dry-run with --proxy exits 0"

# proxychains (4 / -ng / plain) wrapping nmap -sT.
if ! grep -Eiq 'proxychains(4|-ng)?[^\n]*nmap[^\n]*-sT' "$DRY_OUT"; then
  fail "(a) dry-run did not print proxychains-wrapped 'nmap -sT' (IC-4). Output: $(cat "$DRY_OUT")"
fi
pass "(a) proxychains wraps nmap -sT"

# proxychains wrapping testssl.sh.
if ! grep -Eiq 'proxychains(4|-ng)?[^\n]*testssl' "$DRY_OUT"; then
  fail "(a) dry-run did not print proxychains-wrapped 'testssl.sh' (IC-4). Output: $(cat "$DRY_OUT")"
fi
pass "(a) proxychains wraps testssl.sh"

# testssl native --proxy must NEVER be used with a SOCKS proxy (IC-4): a testssl
# line must NOT carry its own `--proxy` flag.
if grep -Ei 'testssl[^\n]*' "$DRY_OUT" | grep -Eq -- '--proxy'; then
  fail "(a) testssl line used native --proxy (forbidden with SOCKS; must go via proxychains)"
fi
pass "(a) testssl does NOT use native --proxy (SOCKS goes via proxychains)"

# nuclei via native -proxy with the SOCKS URL.
NUCLEI_LINE="$(grep -Ei 'nuclei' "$DRY_OUT" | head -1)"
if [ -z "$NUCLEI_LINE" ]; then
  fail "(a) dry-run printed no nuclei command. Output: $(cat "$DRY_OUT")"
fi
if ! printf '%s' "$NUCLEI_LINE" | grep -Eq -- "-proxy[[:space:]=]+$PROXY_OK|-proxy[[:space:]=]*$PROXY_OK"; then
  fail "(a) nuclei did not use native -proxy $PROXY_OK. Line: $NUCLEI_LINE"
fi
pass "(a) nuclei uses native -proxy $PROXY_OK"

# EXACT pinned allowlist (positive).
if ! printf '%s' "$NUCLEI_LINE" | grep -qF -- '-tags exposures,misconfiguration,technologies,ssl,dns'; then
  fail "(a) nuclei missing EXACT -tags allowlist. Line: $NUCLEI_LINE"
fi
pass "(a) nuclei carries EXACT -tags exposures,misconfiguration,technologies,ssl,dns"
if ! printf '%s' "$NUCLEI_LINE" | grep -qF -- '-exclude-tags intrusive,dos,fuzz,bruteforce,default-login'; then
  fail "(a) nuclei missing EXACT -exclude-tags allowlist. Line: $NUCLEI_LINE"
fi
pass "(a) nuclei carries EXACT -exclude-tags intrusive,dos,fuzz,bruteforce,default-login"

# NEGATIVE: the `-tags` RUN set must contain none of the excluded tags. Isolate
# the value of the `-tags` flag ONLY (the token right after `-tags `, up to the
# next space) so the legitimate `-exclude-tags intrusive,...` is NOT mis-matched.
TAGS_VAL="$(printf '%s\n' "$NUCLEI_LINE" | sed -nE 's/.*[[:space:]]-tags[[:space:]]+([^[:space:]]+).*/\1/p')"
if [ -z "$TAGS_VAL" ]; then
  fail "(a) could not isolate the nuclei -tags value from: $NUCLEI_LINE"
fi
for EXC in intrusive dos fuzz bruteforce default-login; do
  if printf '%s' "$TAGS_VAL" | grep -Eq "(^|,)$EXC(,|$)"; then
    fail "(a) nuclei -tags run set contains EXCLUDED tag '$EXC'. -tags=$TAGS_VAL"
  fi
done
pass "(a) nuclei -tags run set ($TAGS_VAL) contains none of the 5 excluded tags"

# NEGATIVE (both directions): every nuclei invocation must carry the allowlist —
# no bare nuclei without -tags.
BARE_NUCLEI="$(grep -Ei 'nuclei' "$DRY_OUT" | grep -v -- '-tags exposures,misconfiguration,technologies,ssl,dns' || true)"
if [ -n "$BARE_NUCLEI" ]; then
  fail "(a) found a nuclei invocation WITHOUT the pinned allowlist: $BARE_NUCLEI"
fi
pass "(a) no bare nuclei invocation without the pinned allowlist"
fi  # end HAVE_PROXYCHAINS guard for (a)

# ===========================================================================
# Scenario (b): live vantage=proxy — SOCKS fixture up + --proxy → vantage proxy.
# ===========================================================================
echo ""
echo "### Scenario (b): live — reachable proxy → external.vantage = proxy"
if [ "$HAVE_PROXYCHAINS" != true ]; then
  echo "SKIP: proxychains-ng not installed — (b) live proxy vantage requires it present (IC-4)"
else
BUNDLE_B="$WORK_DIR/b-proxy.json"
set +e
run_collector --host audituser@127.0.0.1:2201 --out "$BUNDLE_B" \
  --no-install --run-id "ztest-ext-b-$$" --proxy "$PROXY_OK" \
  >"$WORK_DIR/b.log" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "(b) collect with reachable proxy should exit 0 (log: $WORK_DIR/b.log)"
assert_file_exists "$BUNDLE_B"
jq -e . "$BUNDLE_B" >/dev/null 2>&1 || fail "(b) bundle not valid JSON: $(cat "$BUNDLE_B")"
VANTAGE_B="$(jq -r '.external.vantage' "$BUNDLE_B")"
require_eq "$VANTAGE_B" "proxy" "(b) external.vantage should be proxy with a reachable proxy"
pass "(b) external.vantage = proxy"
# Internal checks unaffected: bundle still has all IC-3 keys + checks populated.
require_eq "$(jq -r '.checks | length >= 1' "$BUNDLE_B")" "true" "(b) internal checks still collected"
pass "(b) internal checks unaffected (checks[] populated)"

# ===========================================================================
# Scenario (c): dead proxy → external.vantage = failed; internals unaffected.
# ===========================================================================
echo ""
echo "### Scenario (c): live — unreachable proxy → external.vantage = failed"
BUNDLE_C="$WORK_DIR/c-deadproxy.json"
set +e
run_collector --host audituser@127.0.0.1:2201 --out "$BUNDLE_C" \
  --no-install --run-id "ztest-ext-c-$$" --proxy "$PROXY_DEAD" \
  >"$WORK_DIR/c.log" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "(c) collect with dead proxy should still exit 0 (log: $WORK_DIR/c.log)"
assert_file_exists "$BUNDLE_C"
jq -e . "$BUNDLE_C" >/dev/null 2>&1 || fail "(c) bundle not valid JSON: $(cat "$BUNDLE_C")"
VANTAGE_C="$(jq -r '.external.vantage' "$BUNDLE_C")"
require_eq "$VANTAGE_C" "failed" "(c) external.vantage should be failed with an unreachable proxy"
pass "(c) external.vantage = failed"
# Internal checks unaffected: checks[] still populated and privilege_mode resolved.
require_eq "$(jq -r '.checks | length >= 1' "$BUNDLE_C")" "true" "(c) internal checks still collected despite dead proxy"
pass "(c) internal checks unaffected by dead proxy"
PM_C="$(jq -r '.privilege_mode' "$BUNDLE_C")"
if [ "$PM_C" = "insufficient-data" ]; then
  fail "(c) privilege_mode insufficient-data — internal collection was disrupted by the dead proxy"
fi
pass "(c) privilege_mode resolved despite dead proxy ($PM_C)"
fi  # end HAVE_PROXYCHAINS guard for (b)+(c)

# ===========================================================================
# Scenario (d): no proxy + --skip-external → external.vantage = none.
# ===========================================================================
echo ""
echo "### Scenario (d): --skip-external → external.vantage = none"
BUNDLE_D="$WORK_DIR/d-skip.json"
set +e
run_collector --host audituser@127.0.0.1:2201 --out "$BUNDLE_D" \
  --no-install --run-id "ztest-ext-d-$$" --skip-external \
  >"$WORK_DIR/d.log" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "(d) collect --skip-external should exit 0 (log: $WORK_DIR/d.log)"
assert_file_exists "$BUNDLE_D"
VANTAGE_D="$(jq -r '.external.vantage' "$BUNDLE_D")"
require_eq "$VANTAGE_D" "none" "(d) external.vantage should be none with --skip-external"
pass "(d) external.vantage = none (--skip-external)"

# ===========================================================================
# Scenario (e): proxychains-ng ABSENT (PATH-masked) → vantage none + preflight warning.
# A minimal PATH directory holds shims for every binary the collector needs (jq,
# ssh, nc, base64, etc.) EXCEPT proxychains*, so the collector's proxychains
# detection misses and degrades to vantage=none with an explicit warning (IC-4).
# ===========================================================================
echo ""
echo "### Scenario (e): proxychains-ng absent → external.vantage = none + warning"
MASK_BIN="$WORK_DIR/maskbin"
mkdir -p "$MASK_BIN"
# Symlink the real binaries the collector relies on into the mask dir, but NOT any
# proxychains variant — so `command -v proxychains4/proxychains-ng/proxychains`
# fails even though everything else still resolves.
for B in jq ssh scp nc base64 sed grep awk cut head date dirname mkdir cat sleep stat printf env bash sh ssh-keyscan test true tr wc; do
  RP="$(command -v "$B" 2>/dev/null || true)"
  [ -n "$RP" ] && ln -sf "$RP" "$MASK_BIN/$B" 2>/dev/null || true
done
# Defensive: ensure no proxychains leaks into the masked PATH.
rm -f "$MASK_BIN"/proxychains* 2>/dev/null || true

BUNDLE_E="$WORK_DIR/e-noproxychains.json"
set +e
PATH="$MASK_BIN" run_collector --host audituser@127.0.0.1:2201 --out "$BUNDLE_E" \
  --no-install --run-id "ztest-ext-e-$$" --proxy "$PROXY_OK" \
  >"$WORK_DIR/e.log" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "(e) collect with proxychains absent should exit 0 (log: $WORK_DIR/e.log)"
assert_file_exists "$BUNDLE_E"
VANTAGE_E="$(jq -r '.external.vantage' "$BUNDLE_E")"
require_eq "$VANTAGE_E" "none" "(e) external.vantage should be none when proxychains-ng is absent"
pass "(e) external.vantage = none (proxychains-ng absent)"
# Explicit preflight warning printed.
if ! grep -Eiq 'proxychains' "$WORK_DIR/e.log" || ! grep -Eiq 'warn|warning|not (found|installed|available)|absent|missing' "$WORK_DIR/e.log"; then
  fail "(e) no preflight warning about missing proxychains-ng printed (IC-4). Log: $(cat "$WORK_DIR/e.log")"
fi
pass "(e) preflight warning about missing proxychains-ng printed"

# ===========================================================================
# Scenario (f): --external direct dry-run → vantage=direct + nmap -T2 preview.
# Pure dry-run; no docker, no SSH, no proxychains required.  Exercises the 5th
# vantage branch (direct) of the state machine (DD-4 / IC-4).
# Asserts:
#   1. bundle JSON records external.vantage = "direct"
#   2. dry-run log contains 'nmap' with the polite-timing flag '-T2'
# ===========================================================================
echo ""
echo "### Scenario (f): --external direct dry-run → vantage=direct + nmap -T2"
BUNDLE_F="$WORK_DIR/f-direct-dry.json"
DRY_F="$WORK_DIR/f-direct-dry.log"
set +e
bash "$COLLECTOR" --dry-run --no-install \
  --host audituser@127.0.0.1:2201 --out "$BUNDLE_F" \
  --external direct >"$DRY_F" 2>&1
RC=$?
set -e
require_eq "$RC" "0" "(f) --external direct --dry-run should exit 0 (log: $DRY_F)"
pass "(f) --external direct dry-run exits 0"

# 1. Bundle records correct vantage.
assert_file_exists "$BUNDLE_F"
jq -e . "$BUNDLE_F" >/dev/null 2>&1 || fail "(f) bundle not valid JSON: $(cat "$BUNDLE_F")"
VANTAGE_F="$(jq -r '.external.vantage' "$BUNDLE_F")"
require_eq "$VANTAGE_F" "direct" "(f) external.vantage should be direct with --external direct"
pass "(f) external.vantage = direct"

# 2. Dry-run log prints nmap with the polite-timing flag -T2.
if ! grep -Eq 'nmap[[:print:]]*-T2' "$DRY_F"; then
  fail "(f) dry-run log did not print nmap with -T2 (polite timing, DD-4). Log: $(cat "$DRY_F")"
fi
pass "(f) dry-run log prints nmap with -T2 (polite timing)"

echo ""
echo "ALL INFRA-COLLECTOR-EXTERNAL ASSERTIONS PASSED"
