#!/usr/bin/env bash
# test-infra-limited-sudo-scanvia.sh — unit coverage for the two collector
# capabilities added after the QuotasMobi/Hetzner real-run findings:
#   1. E3 limited-sudo allowlist-aware probing (_allowlist_has_binary): a deploy
#      account with a granular NOPASSWD allowlist must let the SPECIFIC granted
#      commands run instead of every needs_sudo check degrading to insufficient-data.
#   2. --scan-via external vantage (_scan_via_parse): the portable nc/openssl/curl
#      external leg (macOS-safe, no proxychains/nmap/testssl/nuclei) parses its
#      line-tagged report into open_ports / tls / nuclei_findings correctly.
#
# Pure-logic test: the two functions are extracted from the collector by name and
# evaluated against fixed samples — no Docker, no SSH, runs anywhere with jq.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
COLLECTOR="$HERE/../../scripts/infra-collect.sh"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[ -f "$COLLECTOR" ] || { echo "FAIL: collector not found at $COLLECTOR"; exit 1; }

# Shared stubs the extracted functions reference.
SED_REDACT='s/(password|secret|token|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^[:space:]]+/\1=<REDACTED>/gI'
EXTERNAL_OPEN_PORTS_JSON='[]'; EXTERNAL_TLS_JSON='{}'; EXTERNAL_NUCLEI_JSON='[]'; EXTERNAL_NOTES_JSON='[]'; SCAN_VIA='scanhost'
SUDO_ALLOWLIST=''
_external_note() { EXTERNAL_NOTES_JSON="$(printf '%s' "$EXTERNAL_NOTES_JSON" | jq --arg n "$1" '. + [$n]')"; }

# Extract the functions under test (awk range from the collector source).
eval "$(awk '/^_allowlist_has_binary\(\) \{/,/^}/' "$COLLECTOR")"
eval "$(awk '/^_scan_via_parse\(\) \{/,/^}/' "$COLLECTOR")"

echo "== 1. limited-sudo allowlist matcher =="
SUDO_ALLOWLIST='User claude may run the following commands on h:
    (ALL) NOPASSWD: /usr/bin/docker, /bin/systemctl status *, /usr/sbin/ufw status*, /usr/bin/ss, /usr/sbin/ss'
for b in ufw docker ss; do _allowlist_has_binary "$b" && ok "granted: $b" || bad "should grant: $b"; done
for b in iptables redis nmap trivy apt; do _allowlist_has_binary "$b" && bad "should NOT grant: $b" || ok "denied: $b"; done
SUDO_ALLOWLIST=''
_allowlist_has_binary ufw && bad "empty allowlist must deny" || ok "empty allowlist denies all"

echo "== 2. scan-via parse — hardened host (0 findings expected) =="
EXTERNAL_OPEN_PORTS_JSON='[]'; EXTERNAL_TLS_JSON='{}'; EXTERNAL_NUCLEI_JSON='[]'; EXTERNAL_NOTES_JSON='[]'
_scan_via_parse 'OPEN 22
OPEN 443
===TLS===
subject=CN = host.example.com
issuer=C = US, O = Lets Encrypt, CN = E7
notAfter=Aug 23 04:13:47 2026 GMT
PROTO tls1_2 ECDHE-ECDSA-AES128-GCM-SHA256
PROTO tls1_3 TLS_AES_128_GCM_SHA256
===HTTP===
HTTP/1.1 308 Permanent Redirect
---HTTPS---
HTTP/2 307
strict-transport-security: max-age=31536000; includeSubDomains; preload
===ADMIN===
PATH /admin 307
PATH /.env 307'
[ "$(printf '%s' "$EXTERNAL_OPEN_PORTS_JSON" | jq 'length')" = "2" ] && ok "2 open ports" || bad "open ports count"
[ "$(printf '%s' "$EXTERNAL_TLS_JSON" | jq '.weak_protocols|length')" = "0" ] && ok "no weak protocols" || bad "weak protocols"
[ "$(printf '%s' "$EXTERNAL_TLS_JSON" | jq -r '.cert.subject')" = "CN = host.example.com" ] && ok "cert subject parsed" || bad "cert subject"
[ "$(printf '%s' "$EXTERNAL_NUCLEI_JSON" | jq 'length')" = "0" ] && ok "hardened host → 0 http findings" || bad "expected 0 findings"

echo "== 3. scan-via parse — weak host (findings expected) =="
EXTERNAL_OPEN_PORTS_JSON='[]'; EXTERNAL_TLS_JSON='{}'; EXTERNAL_NUCLEI_JSON='[]'; EXTERNAL_NOTES_JSON='[]'
_scan_via_parse 'OPEN 443
OPEN 3306
===TLS===
subject=CN = old.example.com
notAfter=Jan 1 00:00:00 2021 GMT
PROTO tls1 AES256-SHA
PROTO tls1_1 AES256-SHA
PROTO tls1_2 ECDHE-RSA-AES256-GCM-SHA384
===HTTP===
HTTP/1.1 200 OK
---HTTPS---
HTTP/1.1 200 OK
server: Apache
===ADMIN===
PATH /admin 200
PATH /.env 200
PATH /metrics 401'
[ "$(printf '%s' "$EXTERNAL_TLS_JSON" | jq -c '.weak_protocols')" = '["tls1","tls1_1"]' ] && ok "weak TLS 1.0/1.1 detected" || bad "weak protocols not detected"
[ "$(printf '%s' "$EXTERNAL_NUCLEI_JSON" | jq '[.[]|select(.template_id|startswith("exposed-path"))]|length')" = "2" ] && ok "2 exposed admin paths (HTTP 200)" || bad "exposed-path findings"
[ "$(printf '%s' "$EXTERNAL_NUCLEI_JSON" | jq '[.[]|select(.template_id=="missing-header-hsts")]|length')" = "1" ] && ok "missing-HSTS flagged" || bad "missing-HSTS"
# A 401 admin path must NOT be flagged (auth-gated, not exposed).
[ "$(printf '%s' "$EXTERNAL_NUCLEI_JSON" | jq '[.[]|select(.matched_at=="/metrics")]|length')" = "0" ] && ok "401 path not flagged" || bad "401 wrongly flagged"

echo ""
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
