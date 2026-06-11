#!/usr/bin/env bash
# Task 1 — Docker fixture spike contract test.
# TDD: written RED first (no fixtures), then fixtures authored to turn it GREEN.
#
# Verifies that the infra-audit Docker fixture rig:
#   - parses under compose v2
#   - builds + boots a misconfigured + hardened sshd container and a SOCKS proxy
#   - is SSH-reachable as audituser on both sshd containers
#   - actually carries the seeded misconfigurations (sshd -T) and the hardened
#     container actually rejects root + password auth
#   - the SOCKS proxy answers on 1080
#   - every one of the 10 seeded-issue literals still lives in its declared
#     fixture file (drift gate, driven off seed-manifest.md)
#   - the Dockerfile sha256 recorded in the manifest matches the live file
#
# Test-only SSH isolation: StrictHostKeyChecking=no + UserKnownHostsFile=/dev/null
# so we NEVER touch the operator's real ~/.ssh known_hosts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUITE_DIR="$ROOT_DIR/tests/infra-suite"
FIXT_DIR="$SUITE_DIR/fixtures"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
COMPOSE_FILE="$FIXT_DIR/docker-compose.yml"
MANIFEST="$FIXT_DIR/seed-manifest.md"
KEY="$FIXT_DIR/.keys/zuvo_test_key"
PROJECT="zuvo-infra-fixtures"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

# Docker Desktop ships its cred helper outside the non-login-shell PATH; make
# sure pulls/builds can find docker-credential-desktop.
if [ -d /Applications/Docker.app/Contents/Resources/bin ]; then
  export PATH="$PATH:/Applications/Docker.app/Contents/Resources/bin"
fi

# --- guard: skip cleanly when docker is unavailable -------------------------
# shellcheck source=tests/infra-suite/lib/docker-guard.sh
source "$SUITE_DIR/lib/docker-guard.sh"

# --- fixture presence -------------------------------------------------------
assert_file_exists "$COMPOSE_FILE"
assert_file_exists "$MANIFEST"
assert_file_exists "$SUITE_DIR/lib/ensure-fixtures.sh"
pass "fixture files present"

# --- generate ephemeral keypair + authorized_keys (never committed) ---------
# shellcheck source=tests/infra-suite/lib/ensure-fixtures.sh
source "$SUITE_DIR/lib/ensure-fixtures.sh"
ensure_fixtures
assert_file_exists "$KEY"
pass "ephemeral ssh keypair generated"

SSH_OPTS=(-i "$KEY"
  -o BatchMode=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
  -o LogLevel=ERROR)

# --- teardown trap ----------------------------------------------------------
cleanup() {
  # Best-effort, but don't silently swallow a teardown failure — a lingering
  # stack leaks ports/containers into the next run. Surface a recovery hint.
  docker compose -p "$PROJECT" -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 \
    || echo "WARN: compose down failed — containers may linger (docker compose -p $PROJECT down -v)" >&2
}
trap cleanup EXIT

# --- compose parses ---------------------------------------------------------
docker compose -f "$COMPOSE_FILE" config -q
pass "compose config parses"

# --- build + boot -----------------------------------------------------------
docker compose -p "$PROJECT" -f "$COMPOSE_FILE" up -d --build --wait
pass "containers up (misconfigured + hardened + socks)"

# --- ssh reachability as audituser on both sshd containers -------------------
# `--wait` only proves the port is open (healthcheck greps /proc/net/tcp), NOT
# that sshd has finished accepting auth. Bound the FIRST login in a retry so a
# narrow port-open-but-not-auth-ready window doesn't flake the suite. Once this
# succeeds the daemon is auth-ready; subsequent ssh calls stay single-shot.
_login_ok=0
for _i in $(seq 1 10); do
  if ssh "${SSH_OPTS[@]}" -p 2201 audituser@127.0.0.1 true 2>/dev/null; then
    _login_ok=1; break
  fi
  sleep 2
done
[ "$_login_ok" -eq 1 ] || fail "ssh audituser@2201 (misconfigured) not auth-ready after 10×2s"
pass "ssh audituser@2201 (misconfigured) login ok"

# Same bounded auth-ready retry for the hardened daemon: `--wait` proves the
# port is open, not that sshd finished accepting auth. The two containers boot
# independently, so 2202 can still be in the port-open-but-not-auth-ready window
# even after 2201 succeeded.
_login_ok=0
for _i in $(seq 1 10); do
  if ssh "${SSH_OPTS[@]}" -p 2202 audituser@127.0.0.1 true 2>/dev/null; then
    _login_ok=1; break
  fi
  sleep 2
done
[ "$_login_ok" -eq 1 ] || fail "ssh audituser@2202 (hardened) not auth-ready after 10×2s"
pass "ssh audituser@2202 (hardened) login ok"

# --- misconfigured: sshd -T shows the seeded weakness -----------------------
MIS_SSHDT="$(ssh "${SSH_OPTS[@]}" -p 2201 audituser@127.0.0.1 'sudo sshd -T' 2>/dev/null)"
echo "$MIS_SSHDT" | grep -iq '^permitrootlogin yes$'
pass "misconfigured sshd -T: permitrootlogin yes"

# --- hardened: sshd -T shows the hardened posture ---------------------------
HARD_SSHDT="$(ssh "${SSH_OPTS[@]}" -p 2202 audituser@127.0.0.1 'sudo sshd -T' 2>/dev/null)"
echo "$HARD_SSHDT" | grep -iq '^permitrootlogin no$'
pass "hardened sshd -T: permitrootlogin no"
echo "$HARD_SSHDT" | grep -iq '^passwordauthentication no$'
pass "hardened sshd -T: passwordauthentication no"

# hardened really refuses root: pubkey-as-root must not yield a shell. We assert
# the failure REASON (captured stderr) — a crashed/unreachable container also
# fails to yield a shell, so without checking WHY it failed it could masquerade
# as a legitimate root rejection. Require a genuine auth/connection refusal.
_root_stderr="$(ssh "${SSH_OPTS[@]}" -p 2202 root@127.0.0.1 true 2>&1)" && \
  fail "hardened container accepted root login (should reject)"
if ! printf '%s' "$_root_stderr" \
     | grep -qi 'Permission denied\|Connection closed\|no supported authentication'; then
  fail "hardened root rejection had unexpected reason (container may be down): $_root_stderr"
fi
pass "hardened rejects root login"

# --- socks proxy answers -----------------------------------------------------
# The socks-proxy image (serjs/go-socks5-proxy) is FROM scratch — no shell or
# nc binary, so a compose healthcheck is not possible for that service.
# We poll here instead: up to 15×1 s, then assert.
_socks_up=0
for _i in $(seq 1 15); do
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 2 127.0.0.1 1080 2>/dev/null && { _socks_up=1; break; }
  else
    (exec 3<>/dev/tcp/127.0.0.1/1080) 2>/dev/null && exec 3>&- && { _socks_up=1; break; }
  fi
  sleep 1
done
if [ "$_socks_up" -eq 0 ]; then
  fail "socks proxy not reachable on 1080 after 15 s"
fi
if command -v nc >/dev/null 2>&1; then
  nc -z -w 5 127.0.0.1 1080
  pass "socks proxy reachable on 1080 (nc)"
else
  # portable fallback: /dev/tcp
  (exec 3<>/dev/tcp/127.0.0.1/1080) 2>/dev/null && exec 3>&- || fail "socks proxy not reachable on 1080"
  pass "socks proxy reachable on 1080 (/dev/tcp)"
fi

# --- socks proxy: application-layer proof (not just TCP-open) ----------------
# A TCP-open port on 1080 doesn't prove the SOCKS5 handshake works or that the
# proxy actually forwards. Drive a real proxied connection through it and read
# the upstream SSH banner ("SSH-2.0..."). macOS/BSD nc supports -X 5 (SOCKS5)
# and -x host:port (proxy address); we read the first line nc emits.
#
# Target selection (platform-independence first):
#   1. compose SERVICE NAME (sshd-misconfigured:22) — the proxy shares the
#      compose network and resolves service DNS, so this works on EVERY platform
#      (Docker Desktop AND Linux CI) with no extra_hosts. PREFERRED.
#   2. host.docker.internal:2201 — published host port via the Docker host;
#      resolves on Docker Desktop, needs host-gateway on Linux. FALLBACK.
# We try (1) first, fall back to (2), and report which variant carried the banner.
if ! command -v nc >/dev/null 2>&1; then
  echo "WARN: nc unavailable — skipping socks application-layer proof" >&2
  pass "socks application-layer proof skipped (no nc) — TCP-open verified above"
else
  _socks_banner=""
  _socks_variant=""
  # Variant 1: compose service DNS (platform-independent).
  _socks_banner="$(timeout 10 nc -X 5 -x 127.0.0.1:1080 sshd-misconfigured 22 < /dev/null 2>/dev/null | head -1 || true)"
  if printf '%s' "$_socks_banner" | grep -q '^SSH-2\.0'; then
    _socks_variant="compose service DNS (sshd-misconfigured:22)"
  else
    # Variant 2: host.docker.internal published port.
    _socks_banner="$(timeout 10 nc -X 5 -x 127.0.0.1:1080 host.docker.internal 2201 < /dev/null 2>/dev/null | head -1 || true)"
    if printf '%s' "$_socks_banner" | grep -q '^SSH-2\.0'; then
      _socks_variant="host.docker.internal:2201 (published port)"
    fi
  fi
  if [ -z "$_socks_variant" ]; then
    fail "socks proxy did not forward to upstream SSH (no SSH-2.0 banner via service DNS or host.docker.internal)"
  fi
  pass "socks proxy forwards (app-layer): got SSH banner via $_socks_variant"
fi

# --- seed drift gate: every manifest literal must live in its fixture file ---
# Manifest rows look like:
#   | IS1 | seed-id | literal value | fixture file | expected detection source |
# We iterate data rows, skip the header/separator, and grep the literal in the
# declared fixture file (path is relative to fixtures/).
seed_rows=0
while IFS= read -r line; do
  case "$line" in
    '| IS'[0-9]*)
      # split on the | delimiter
      seed_id="$(printf '%s' "$line" | awk -F'|' '{print $3}' | sed 's/^ *//; s/ *$//')"
      literal="$(printf '%s' "$line" | awk -F'|' '{print $4}' | sed 's/^ *//; s/ *$//')"
      relfile="$(printf '%s' "$line" | awk -F'|' '{print $5}' | sed 's/^ *//; s/ *$//')"
      # strip surrounding backticks if present
      seed_id="${seed_id#\`}"; seed_id="${seed_id%\`}"
      literal="${literal#\`}"; literal="${literal%\`}"
      relfile="${relfile#\`}"; relfile="${relfile%\`}"
      [ -n "$literal" ] || continue
      target="$FIXT_DIR/$relfile"
      assert_file_exists "$target"
      if ! grep -Fq -- "$literal" "$target"; then
        fail "seed drift: literal '$literal' missing from $relfile"
      fi
      pass "seed: $seed_id ($literal) in $relfile"
      seed_rows=$((seed_rows + 1))
      ;;
  esac
done < "$MANIFEST"
require_eq "$seed_rows" "10" "seed-manifest must declare exactly 10 seeded issues"
pass "all 10 seed literals present in their fixture files (no drift)"

# --- manifest Dockerfile sha256 matches live file ---------------------------
MANIFEST_SHA="$(grep -E '^# Dockerfile-sha256:' "$MANIFEST" | head -1 | awk '{print $3}')"
[ -n "$MANIFEST_SHA" ] || fail "manifest missing '# Dockerfile-sha256:' line"
LIVE_SHA="$( (sha256sum "$FIXT_DIR/sshd-misconfigured/Dockerfile" 2>/dev/null || shasum -a 256 "$FIXT_DIR/sshd-misconfigured/Dockerfile") | awk '{print $1}')"
require_eq "$LIVE_SHA" "$MANIFEST_SHA" "manifest Dockerfile-sha256 must match live Dockerfile"
pass "manifest Dockerfile-sha256 matches sshd-misconfigured/Dockerfile"

echo "ALL INFRA FIXTURE ASSERTIONS PASSED"
