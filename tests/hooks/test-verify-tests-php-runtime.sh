#!/usr/bin/env bash
# test-verify-tests-php-runtime.sh — the PHP interpreter and its pcov ini must come from ONE runtime.
#
# The farm deliberately keeps its PHP builds OFF the PATH (/home/tf/runtimes/php-*), because
# repositories pin an exact version through .tf.json. verify-tests knew about that layout for the
# INI half — it globbed the runtimes to set PHP_INI_SCAN_DIR at the pcov conf.d — and not for the
# BINARY half, which ran a bare `php`. So it configured a coverage driver for an interpreter that
# does not exist there and died with `env: php: No such file or directory` (B-196): coverage and
# mutation reported SKIP on a host carrying four working PHP runtimes, two of them with pcov.
#
# The property is not "php is found". It is that the two halves agree. A binary from one place
# with an ini from another is the failure this guards, and it is silent: the run succeeds and the
# coverage numbers are simply wrong.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VT="$ROOT/scripts/zuvo-home/verify-tests"
pass=0; fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
no()  { echo "FAIL: $1 — $2"; fail=$((fail+1)); }

[ -f "$VT" ] || { echo "FAIL: verify-tests missing"; exit 1; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RT="$T/php-8.4.23-pcov"
mkdir -p "$RT/etc/conf.d" "$RT/lib" "$RT/bin"
touch "$RT/lib/pcov.so"
printf '#!/bin/sh\necho FARM-PHP\n' > "$RT/bin/php"; chmod +x "$RT/bin/php"
# An OLDER runtime that must lose to the newer one; reverse-sorted glob is what picks it.
mkdir -p "$T/php-8.3.33-pcov/etc/conf.d" "$T/php-8.3.33-pcov/lib" "$T/php-8.3.33-pcov/bin"
touch "$T/php-8.3.33-pcov/lib/pcov.so"
printf '#!/bin/sh\necho OLD\n' > "$T/php-8.3.33-pcov/bin/php"; chmod +x "$T/php-8.3.33-pcov/bin/php"

# PATH is set EXPLICITLY in every case. Leaving the ambient one would make these assertions
# depend on whether the machine happens to have php installed — they would then pass on the farm
# (no php on PATH) and fail on a laptop (Homebrew php), which is a test that describes the host
# rather than the code.
probe() { # probe <runtimes-root> [path]
  ZUVO_PHP_RUNTIMES="$1" PATH="${2:-/usr/bin:/bin}" python3 -c "
import runpy
ns = runpy.run_path('$VT', run_name='vt')
print(ns['php_bin']())
print(ns['php_coverage_env']().get('PHP_INI_SCAN_DIR',''))
" 2>/dev/null; }

out=$(probe "$T"); bin=$(echo "$out" | sed -n 1p); ini=$(echo "$out" | sed -n 2p)

case "$bin" in
  /*/php-8.4.23-pcov/bin/php) ok "farm layout resolves an ABSOLUTE php from the newest pcov runtime" ;;
  php) no "farm layout resolves a real binary" "got the bare name — this is the B-196 failure" ;;
  *)   no "farm layout resolves the newest runtime" "got <$bin>" ;;
esac

if [ "${bin%/bin/php}" = "${ini%/etc/conf.d}" ] && [ -n "$ini" ]; then
  ok "binary and PHP_INI_SCAN_DIR come from the SAME runtime"
else
  no "binary and ini agree" "bin=<$bin> ini=<$ini>"
fi

[ -x "$bin" ] && ok "the resolved interpreter is executable" \
               || no "resolved interpreter is executable" "<$bin> is not"

# Off the farm nothing changes: a laptop's PATH php is the right one, and no ini is forced.
out2=$(probe "$T/does-not-exist"); bin2=$(echo "$out2" | sed -n 1p); ini2=$(echo "$out2" | sed -n 2p)
[ "$bin2" = "php" ] && ok "no farm layout -> plain 'php', unchanged laptop behaviour" \
                    || no "laptop fallback" "expected 'php', got <$bin2>"
[ -z "$ini2" ] && ok "no farm layout -> no PHP_INI_SCAN_DIR is forced" \
               || no "laptop ini untouched" "got <$ini2>"

# An explicit caller setting still wins — the farm must not override a deliberate choice.
out3=$(PHP_INI_SCAN_DIR=/caller/choice probe "$T"); ini3=$(echo "$out3" | sed -n 2p)
[ "$ini3" = "/caller/choice" ] && ok "an explicit PHP_INI_SCAN_DIR from the caller still wins" \
                               || no "caller override" "expected /caller/choice, got <$ini3>"

# THE PRECEDENCE THAT MATTERS. The farm's convention is that a repository pins its exact PHP in
# the profile — tgm-panel's ablate-unit exports PATH=/home/tf/runtimes/php-8.3.32-bulk/bin because
# that build lacks pdo_sqlite and its calibration against Jenkins depends on it. A globbed
# php-*-pcov must never win over that: it would run the suite on a different interpreter than the
# profile chose and report green for the wrong runtime. Silent, and worse than the missing-binary
# error this whole function exists to remove.
mkdir -p "$T/profile"
printf '#!/bin/sh\necho PROFILE-PHP\n' > "$T/profile/php"; chmod +x "$T/profile/php"
out4=$(probe "$T" "$T/profile:/usr/bin:/bin"); bin4=$(echo "$out4" | sed -n 1p); ini4=$(echo "$out4" | sed -n 2p)
[ "$bin4" = "$T/profile/php" ] \
  && ok "a php the profile put on PATH beats the globbed pcov runtime" \
  || no "PATH precedence" "expected the profile's php, got <$bin4> — a pinned runtime would be silently replaced"

# And the half this file used to leave unasserted, which is how the defect shipped. Checking only
# the binary here passed while PHP_INI_SCAN_DIR still pointed into an unrelated php-*-pcov tree —
# a pcov.so built for ONE interpreter loaded into the scan dir of ANOTHER. Best case an ABI crash;
# worst case coverage that looks configured and records nothing. The ini must follow the binary,
# so when the interpreter is NOT the pcov runtime, no scan dir may be claimed at all.
[ -z "$ini4" ] \
  && ok "a profile-pinned interpreter gets NO forced ini — pcov config never crosses runtimes" \
  || no "ini follows binary" "binary is <$bin4> but ini is <$ini4> — two different runtimes"

echo "SUMMARY: $((pass+fail)) run, $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
