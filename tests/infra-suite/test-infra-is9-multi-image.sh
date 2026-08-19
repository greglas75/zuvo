#!/usr/bin/env bash
# IS9-image-critical-cve — fleet-wide CVE coverage (B-infra-collect-multi-container-cve).
#
# NO Docker, NO SSH, NO network: the battery row is extracted from the collector and executed
# against stub `docker`/`trivy` binaries on PATH.
#
# The check used to scan `docker ps | head -1` — one image, whichever docker listed first. Its
# findings were correct and its silence was not: a host running ten containers reported on one and
# the bundle gave the analyst no way to tell. Scanning all of them is the fix; doing it without a
# bound is a different bug, because N images x TRIVY_TIMEOUT_S overruns CHECK_TIMEOUT_S and the
# whole check comes back truncated. Hence the cap — and hence the assertion that the cap ANNOUNCES
# itself with the real total, since a silent cap reads exactly like full coverage.
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

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# Take the command the way PRODUCTION does — by running the collector's own `battery()` heredoc —
# instead of re-implementing its unescaping with sed. The sed form worked until the row grew a
# `printf '%s\\n'`, which it left as a literal backslash-n; the emitted command was correct and the
# TEST was measuring a mangled copy of it. A test that decodes its subject by hand drifts from the
# subject; sourcing the emitter cannot.
CMD="$(
  set -a
  # shellcheck disable=SC1090
  . <(sed -n '/^: "${TRIVY_TIMEOUT_S/p;/^: "${IS9_MAX_IMAGES/p' "$COLLECTOR")
  set +a
  sed -n '/^battery() {/,/^EOF/p' "$COLLECTOR" > "$TMP/battery.sh"; echo '}' >> "$TMP/battery.sh"
  # shellcheck disable=SC1090
  . "$TMP/battery.sh"
  battery | sed -n '/^IS9-image-critical-cve/p' | cut -d'|' -f7-
)"
[ -n "$CMD" ] || { echo "  FAIL could not extract the IS9 cmd column"; exit 1; }

run(){ PATH="$BIN:$PATH" sh -c "$CMD" 2>&1; }

stub_docker(){ { echo '#!/bin/sh'; echo '[ "$1" = "ps" ] || exit 0'; printf 'printf %s\n' "'$1'"; } > "$BIN/docker"; chmod +x "$BIN/docker"; }
stub_trivy_ok(){ printf '#!/bin/sh\nfor a; do :; done\necho "CVE-2026-11111 CRITICAL in $a"\n' > "$BIN/trivy"; chmod +x "$BIN/trivy"; }
stub_trivy_fail(){ printf '#!/bin/sh\nexit 1\n' > "$BIN/trivy"; chmod +x "$BIN/trivy"; }

# --- 1. every running image is scanned, not just the first --------------------------------------
stub_docker 'nginx:1.25\nredis:7\npostgres:16\n'; stub_trivy_ok
out="$(run)"
n_scanned="$(printf '%s\n' "$out" | grep -c '^IS9-IMAGE: ' || true)"
[ "$n_scanned" = "3" ] && ok "all 3 running images scanned (was: 1)" || no "scanned $n_scanned images, expected 3"
case "$out" in *redis:7*) ok "a NON-first image reaches the scanner";; *) no "non-first image never scanned";; esac

# --- 2. duplicates collapse — N containers of one image is one scan, not N ----------------------
stub_docker 'nginx:1.25\nnginx:1.25\nnginx:1.25\nredis:7\n'
n_scanned="$(run | grep -c '^IS9-IMAGE: ' || true)"
[ "$n_scanned" = "2" ] && ok "duplicate images deduplicated (4 containers -> 2 scans)" || no "dedup failed: $n_scanned scans"

# --- 3. THE CAP MUST ANNOUNCE ITSELF ------------------------------------------------------------
# A cap that truncates quietly is indistinguishable from full coverage in the bundle, which is the
# exact failure this whole entry was about — just moved one layer up.
stub_docker 'a:1\nb:1\nc:1\nd:1\ne:1\nf:1\ng:1\nh:1\ni:1\nj:1\n'
out="$(run)"
n_scanned="$(printf '%s\n' "$out" | grep -c '^IS9-IMAGE: ' || true)"
[ "$n_scanned" = "8" ] && ok "cap holds at IS9_MAX_IMAGES (8 of 10)" || no "cap not enforced: $n_scanned scans"
case "$out" in *IS9-IMAGE-SCAN-CAPPED*) ok "cap is reported, not silent";; *) no "cap truncated silently";; esac
case "$out" in *"8 of 10 distinct images"*) ok "cap line names the REAL total, so the gap is measurable";; *) no "cap line does not state the true image count: $(printf '%s\n' "$out" | grep CAPPED)";; esac

# --- 4. a host with no containers says so rather than emitting nothing ---------------------------
stub_docker ''
out="$(run)"
case "$out" in *IS9-NO-RUNNING-CONTAINERS*) ok "empty host reports NO-RUNNING-CONTAINERS";; *) no "empty host produced no marker: '$out'";; esac

# --- 4b. an enumeration FAILURE must not read as an empty host -----------------------------------
# `docker ps` failing (daemon down, permission denied) left `imgs` empty, and the check then emitted
# IS9-NO-RUNNING-CONTAINERS — which tells the analyst the attack surface WAS empty. It was unknown.
# Same class as the silent cap this file already guards: a gap reported as a clean result.
printf '#!/bin/sh\nexit 1\n' > "$BIN/docker"; chmod +x "$BIN/docker"
out="$(run)"
case "$out" in
  *IS9-IMAGE-ENUMERATION-FAILED*) ok "a failed docker ps reports UNKNOWN coverage, not an empty host" ;;
  *IS9-NO-RUNNING-CONTAINERS*) no "docker ps failure reported as NO-RUNNING-CONTAINERS (gap read as a clean result)" ;;
  *) no "docker ps failure produced no marker at all: '$out'" ;;
esac

# --- 5. a failing scanner is attributed per image, and does not abort the remaining images -------
stub_docker 'x:1\ny:1\n'; stub_trivy_fail
out="$(run)"
[ "$(printf '%s\n' "$out" | grep -c 'IS9-IMAGE-SCAN-FAILED' || true)" = "2" ] && ok "per-image scan failure reported for each image" || no "scan failure not attributed per image: $out"
[ "$(printf '%s\n' "$out" | grep -c '^IS9-IMAGE: ' || true)" = "2" ] && ok "one image failing does not abort the rest" || no "loop aborted on first failure"

# --- 6. the finding classifier still matches (match_re column unchanged) -------------------------
mre="$(sed -n '/^IS9-image-critical-cve/p' "$COLLECTOR" | cut -d'|' -f6)"
stub_docker 'nginx:1.25\n'; stub_trivy_ok
printf '%s\n' "$(run)" | grep -qiE "${mre//\~\~/|}" && ok "emitted evidence still matches the row's match_re" || no "match_re no longer classifies the output as a finding"

echo "  --- IS9 multi-image: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
