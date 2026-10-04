#!/usr/bin/env bash
# scripts/verify-leads-release.sh STEP 6 — the installer syntax check of the leads release gate.
#
# install.sh sources scripts/install.d/*.sh, so STEP 6 checks every module, not only install.sh. A
# module that does not parse, or a tree with no modules at all, must END the gate with a non-zero exit:
# the check used to print its FAIL line and carry on to "RELEASE GATE: PASS", exit 0.
#
# Test level: MEDIUM — the real gate script in a fixture repo whose other steps are stubs that pass; a
# PATH holding only bash, grep and dirname (so STEP 1-2 take their no-bats SKIP); nothing outside $TMP.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0; npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: mktemp -d failed"; exit 1; }
. "$ROOT/tests/lib/hermetic-tools.sh"
mkdir -p "$TMP/bin" && hermetic_link_tools "$TMP/bin" bash grep dirname
for t in bash grep dirname; do [ -e "$TMP/bin/$t" ] || { echo "FAIL: $t not found to link"; exit 1; }; done

# fixture <name> <modules: good|broken|none> — a repo whose STEP 6 input is the case, every other step a pass
fixture() {
  local r="$TMP/$1"
  mkdir -p "$r/scripts/tests"
  cp "$ROOT/scripts/verify-leads-release.sh" "$r/scripts/"
  for s in leads-routing-smoke leads-manifest-counts leads-skill-structure; do printf 'exit 0\n' > "$r/scripts/tests/$s.sh"; done
  printf 'docs/leads/\n' > "$r/.gitignore"
  printf '#!/usr/bin/env bash\ntrue\n' > "$r/scripts/install.sh"
  case "$2" in
    good)   mkdir -p "$r/scripts/install.d"; printf 'm() { :; }\n' > "$r/scripts/install.d/a.sh" ;;
    broken) mkdir -p "$r/scripts/install.d"; printf 'm() { :; }\n' > "$r/scripts/install.d/a.sh"
            printf 'if then fi\n' > "$r/scripts/install.d/b.sh" ;;
    none)   : ;;
  esac
  printf '%s' "$r"
}
# gate <repo> — run the gate there; output to <repo>.out, its exit status returned
gate() { env -i PATH="$TMP/bin" HOME="$TMP" REPO_ROOT="$1" bash "$1/scripts/verify-leads-release.sh" > "$1.out" 2>&1; }

# (1) a tree whose install.sh and modules all parse: STEP 6 passes and the gate passes
R="$(fixture good good)"; gate "$R"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^STEP 6: PASS' "$R.out" && grep -q '^RELEASE GATE: PASS' "$R.out" \
  && pass "(1) every module parses: STEP 6 passes, the gate passes" \
  || bad "(1) good tree: exit $rc [$(tail -3 "$R.out" | tr '\n' '|')]"

# (2) one module that does not parse: named, the gate ends non-zero before STEP 7, never a PASS line
R="$(fixture broken broken)"; gate "$R"; rc=$?
[ "$rc" -ne 0 ] && grep -q '^FAIL: STEP 6 syntax error in scripts/install.d/b.sh' "$R.out" \
  && ! grep -q 'RELEASE GATE: PASS' "$R.out" && ! grep -q '^STEP 6: PASS' "$R.out" && ! grep -q '^STEP 7' "$R.out" \
  && pass "(2) a module that does not parse is named and ends the gate non-zero, before STEP 7" \
  || bad "(2) broken module: exit $rc [$(tail -3 "$R.out" | tr '\n' '|')]"

# (3) no install.d modules: install.sh could not run, so STEP 6 fails instead of passing on zero files
R="$(fixture none none)"; gate "$R"; rc=$?
[ "$rc" -ne 0 ] && grep -q '^FAIL: STEP 6 no scripts/install.d/\*.sh modules' "$R.out" && ! grep -q 'RELEASE GATE: PASS' "$R.out" \
  && pass "(3) no modules: STEP 6 fails, the gate ends non-zero" \
  || bad "(3) no modules: exit $rc [$(tail -3 "$R.out" | tr '\n' '|')]"

echo
echo "RESULT: PASS=$npass FAIL=$nfail"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
