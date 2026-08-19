#!/usr/bin/env bash
# infra-collect.sh SED_REDACT — value-shape redaction contract (B-infra-collect-value-heuristic-redaction).
#
# NO Docker, NO SSH, NO network. Sources the SED_REDACT constant out of the collector and runs
# real strings through it.
#
# The keyword rules only fire when the KEY NAME contains a sensitive substring, so a
# generically-named secret (`FOO=ghp_…`) used to leave the host verbatim. Adding a value-shape rule
# is easy; adding one that does not DESTROY EVIDENCE is the actual constraint — trivy, docker and
# nmap output is full of lowercase-hex sha256 digests, image refs and checksums that look exactly
# like a 32+ char opaque token. Redacting those would silently gut the bundle the collector exists
# to produce, which is why the preservation cases below are assertions and not comments.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COLLECTOR="$ROOT_DIR/scripts/infra-collect.sh"
PASS=0; FAIL=0
# A misspelled helper is not caught by `set -u`: bash prints "command not found", returns 127, and
# the counters never move — so a file full of broken assertions summarises as FAIL=0. That happened
# in this repo (11 assertions calling a helper the file did not define). This makes it a real failure.
command_not_found_handle(){ echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL+1)); return 127; }
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

[ -f "$COLLECTOR" ] || { echo "  FAIL collector missing: $COLLECTOR"; exit 1; }

# Take the constant from the collector itself — a copied fixture would drift from what runs.
eval "$(sed -n '/^SED_REDACT=/p' "$COLLECTOR")"
[ -n "${SED_REDACT:-}" ] || { echo "  FAIL SED_REDACT not extractable"; exit 1; }

red(){ printf '%s\n' "$1" | LC_ALL=C sed -E "$SED_REDACT"; }

# --- REDACTED: the value must not survive ------------------------------------------------------
must_redact(){ # <label> <line> <the secret substring that must be gone>
  local got; got="$(red "$2")"
  case "$got" in
    *"$3"*) no "$1 — secret survived: $got" ;;
    *"[REDACTED]"*) ok "$1" ;;
    *) no "$1 — neither redacted nor marked: $got" ;;
  esac
}

# keyword rules (pre-existing behaviour — asserted so the new passes cannot regress them)
must_redact "keyword: password"            'password: hunter2'                       'hunter2'
must_redact "keyword: DATABASE_URL"        'DATABASE_URL=postgres://u:pw@h/db'       'pw@h'
must_redact "line-anchored: requirepass"   'requirepass zuvo-seed-redispw-2e6f'      'zuvo-seed'

# rule A — vendor prefixes, under a key name the keyword list does not know
must_redact "generic key, github token"    'FOO=ghp_abcdefghijklmnopqrstuvwxyz012345' 'abcdefghijkl'
must_redact "generic key, aws access key"  'THING=AKIAIOSFODNN7EXAMPLE'               'IOSFODNN7EXAMPLE'
must_redact "generic key, slack bot token" 'X=xoxb-1234567890-abcdefghijklmno'        'abcdefghijklmno'
must_redact "generic key, jwt"             'hdr: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefghij' 'eyJzdWIi'

# rule B — long opaque mixed value under a name nothing keys off
must_redact "generic key, opaque 36-char"  'GENERIC_THING=aB3dEfGhIjKlMnOpQrStUvWxYz012345678'    'aB3dEfGh'

# --- PRESERVED: evidence must survive intact ---------------------------------------------------
must_keep(){ # <label> <line>
  local got; got="$(red "$2")"
  if [ "$got" = "$2" ]; then ok "$1"; else no "$1 — mangled: $got"; fi
}

must_keep "sha256 image digest kept"    'image: nginx@sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
must_keep "bare hex checksum kept"      'digest = 5d41402abc4b2a76b9719d911017c592aabbccddeeff00112233445566778899'
must_keep "hex inside JSON kept"        'json: {"sha": "5d41402abc4b2a76b9719d911017c592aabbccddeeff00112233445566778899"}'
must_keep "sshd directive kept"         'PermitRootLogin no'
must_keep "sysctl value kept"           'net.ipv4.ip_forward = 1'
must_keep "listen address kept"         'ListenAddress 0.0.0.0'
must_keep "cert subject kept"           'Subject=/C=US/O=Example Inc/CN=example.com'
must_keep "version string kept"         'version = 1.6.70-rc.1'
must_keep "cve id kept"                 'CVE-2026-12345 severity: HIGH'

# --- the sentinel is an implementation detail and must never reach output ----------------------
allout="$(red 'A=aB3dEfGhIjKlMnOpQrStUvWxYz012345678'; red 'B=5d41402abc4b2a76b9719d911017c592aabbccddeeff00112233445566778899')"
case "$allout" in *ZVSEC*) no "sentinel leaked into output: $allout";; *) ok "sentinel never appears in output";; esac

# --- the boundary bug that made rule B a no-op --------------------------------------------------
# The hex-unmark pass must require the hex run to reach a non-alphabet char or end-of-line. Without
# that, it unmarks on a leading `a` and every secret starting with a hex char walks back out.
must_redact "secret starting with a hex char" 'K=aB3dEfGhIjKlMnOpQrStUvWxYz012345678' 'B3dEfGh'
must_redact "secret starting with a digit"    'K=0B3dEfGhIjKlMnOpQrStUvWxYz012345678' 'B3dEfGh'

echo "  --- infra redaction: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
