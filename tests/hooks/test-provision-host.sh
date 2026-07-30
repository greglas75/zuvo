#!/usr/bin/env bash
# test-provision-host.sh — scripts/provision-host.sh must print COMPLETE remediation commands and
# signal a degraded fleet through its exit code.
#
# The bug this locks: the remediation table was a `|`-delimited string, but two install commands
# are themselves pipelines (`curl … | bash`). The separator ate the data, so the script handed the
# user a truncated instruction — `install: curl -fsSL https://…/install.sh` with the `| bash`
# missing, and the leftover ` bash` glued onto the verify line. A table is now a `case`.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PH="$ROOT/scripts/provision-host.sh"
fail=0; ok(){ printf '  ✓ %s\n' "$1"; }; bad(){ printf '  ✗ %s\n' "$1"; fail=$((fail+1)); }

echo "=== source-ability (a sourced probe would hang the suite for a minute) ==="
t0=$(date +%s); ( . "$PH" ) >/dev/null 2>&1; t1=$(date +%s)
[ $((t1 - t0)) -le 3 ] && ok "sourcing defines functions without running the probe" \
                       || bad "sourcing ran the probe ($((t1-t0))s) — the BASH_SOURCE guard is missing"

echo "=== usage + argument handling ==="
bash -n "$PH" && ok "syntax" || bad "syntax error"
bash "$PH" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help failed"
bash "$PH" --bogus >/dev/null 2>&1; [ "$?" -eq 2 ] && ok "unknown flag -> exit 2" || bad "unknown flag did not exit 2"

echo "=== remediation commands survive intact (no delimiter truncation) ==="
# Sourcing defines the functions without probing (the script guards on BASH_SOURCE, like
# install.sh). Without that guard this test hung for a minute on five provider round-trips.
. "$PH"
inst_agy=$(fix_for agy)
if printf '%s' "$inst_agy" | grep -q 'install\.sh | bash'; then
  ok "agy install command keeps its '| bash' pipeline"
else
  bad "agy install command was truncated: $(printf '%s' "$inst_agy" | tr '\n' ' ')"
fi
inst_cur=$(fix_for cursor-agent)
printf '%s' "$inst_cur" | grep -q 'install -fsS | bash' \
  && ok "cursor-agent install command keeps its pipeline" \
  || bad "cursor-agent install command was truncated"
# a verify line must never contain a stray fragment of an install command
printf '%s' "$inst_agy" | grep '^ *verify:' | grep -q '^ *verify: *bash' \
  && bad "verify line starts with leftover 'bash' — separator bug is back" \
  || ok "verify line is not polluted by install-command remnants"
# providers with no safe one-liner must SAY so, not print an empty command
fix_for claude | grep -q 'no one-liner' \
  && ok "a provider without an installer says so explicitly" \
  || bad "a provider without an installer printed an empty install command"
# install_cmd_for must be EMPTY for those, so --install can never run a blank command
c=$(install_cmd_for claude)
[ -z "$c" ] && ok "install_cmd_for is empty where there is no installer" \
             || bad "install_cmd_for returned '$c' for a provider with no installer"

echo "=== the remediation table matches the docs it claims to mirror ==="
DOC="$ROOT/docs/adversarial-providers.md"
for frag in 'npm install -g @openai/codex' 'antigravity.google/cli/install.sh' 'cursor.com/install'; do
  grep -qF "$frag" "$DOC" \
    && ok "docs still contain: $frag" \
    || bad "table drifted from docs — '$frag' is not in adversarial-providers.md"
done

echo "=== RESULT ==="; [ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
