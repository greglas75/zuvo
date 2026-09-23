#!/usr/bin/env bash
# test-coverage-gate.py PHP extraction — what counts as the testable SURFACE of a class.
#
# The inventory rule for an ordinary class is right: protected is an implementation detail,
# reached through the public methods, and inventorying it would demand tests for seams nobody
# calls directly. For an ABSTRACT class or a TRAIT that reasoning inverts. Protected IS the
# contract there — it is what subclasses implement and call — and in a template-method base it
# is frequently the ONLY thing in the file.
#
# Measured on a real panel job: `AbstractInvitationJob`, whose every method (`postInit`,
# `getUser`, `getUserActiveOpportunities`, …) is protected because they exist for subclasses
# like `PushInvitationJob`, inventoried as EMPTY — "nothing to inventory". The gate reported a
# class with no testable surface, when what had happened is that it discarded the whole surface.
# The reader's conclusion was that the class was fine and the tool was right; both halves wrong.
#
# Two extraction paths must agree, or a degraded run inventories a different surface than a
# healthy one and the difference reads as the file having changed:
#   * the AST path (`php -r` over token_get_all) — used when a php binary exists;
#   * the textual fallback — whose regex did not match `protected function` at ALL, so the
#     visibility check beneath it was unreachable for the one case it existed to decide.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/scripts/test-coverage-gate.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fails=$((fails + 1)); }

[ -f "$GATE" ] || { bad "gate missing: $GATE"; exit 1; }

cat > "$TMP/AbstractJob.php" <<'PHP'
<?php
abstract class AbstractJob
{
    public function run() { $this->postInit(); }
    protected function postInit() {}
    protected function getUser() {}
    private function internalHelper() {}
    abstract protected function buildPayload();
}
PHP

cat > "$TMP/PlainService.php" <<'PHP'
<?php
class PlainService
{
    public function handle() {}
    protected function shouldStayInternal() {}
    private function secret() {}
}
PHP

cat > "$TMP/SharedTrait.php" <<'PHP'
<?php
trait SharedTrait
{
    public function pub() {}
    protected function sharedWithUsers() {}
    private function hidden() {}
}
PHP

# `extract_php` is imported rather than driven through the CLI so both paths can be exercised:
# the fallback is only reachable by making the php binary invisible, which a subprocess cannot
# be asked to do from outside.
probe() { # probe <file> <force-fallback 0|1>  -> "<symbol>:<visibility>" per line
  python3 - "$GATE" "$1" "$2" <<'PY' 2>/dev/null
import importlib.util, sys
gate, path, force_fallback = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
spec = importlib.util.spec_from_file_location("g", gate)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
if force_fallback:
    m.shutil.which = lambda *a, **k: None
syms, mode = m.extract_php(path)
print("MODE:" + mode)
for s in syms:
    print("%s:%s" % (s["symbol"].split(".")[-1], s.get("visibility", "?")))
PY
}

# The AST arm needs a php binary. On the farm there is one, but NOT on PATH — the runtimes live
# under /home/tf/runtimes/ by design — so an unprepared run silently executed the fallback while
# printing "[ast]", i.e. a test mislabelling which code path it had just exercised. Resolve a
# real php if one exists anywhere we know to look; otherwise say the arm could not run.
PHP_BIN="$(command -v php 2>/dev/null || true)"
if [ -z "$PHP_BIN" ]; then
  for c in /home/tf/runtimes/php-*/bin/php; do [ -x "$c" ] && { PHP_BIN="$c"; break; }; done
fi
if [ -n "$PHP_BIN" ]; then
  PATH="$(dirname "$PHP_BIN"):$PATH"; export PATH
  echo "note: AST arm uses $PHP_BIN"
  ARMS="ast fallback"
else
  echo "note: no php binary anywhere — the AST arm CANNOT run here and is not claimed"
  ARMS="fallback"
fi

for mode in $ARMS; do
  ff=0; [ "$mode" = fallback ] && ff=1

  out="$(probe "$TMP/AbstractJob.php" "$ff")"
  # The regression this file exists for: an empty inventory read as "nothing to test".
  [ -n "$(printf '%s' "$out" | sed '/^MODE:/d')" ] \
    && pass "[$mode] an abstract class whose contract is protected does not inventory EMPTY" \
    || bad  "[$mode] abstract class inventoried nothing — the surface was discarded"
  printf '%s\n' "$out" | grep -q '^postInit:protected$' \
    && printf '%s\n' "$out" | grep -q '^getUser:protected$' \
    && pass "[$mode] protected methods of an abstract class ARE surface" \
    || bad  "[$mode] protected methods missing: $(printf '%s' "$out" | tr '\n' ' ')"
  printf '%s\n' "$out" | grep -q '^buildPayload:protected$' \
    && pass "[$mode] an 'abstract protected' method is surface too — it is the contract itself" \
    || bad  "[$mode] abstract protected method missing"
  printf '%s\n' "$out" | grep -q '^run:public$' \
    && pass "[$mode] the public method is still there" \
    || bad  "[$mode] public method lost"
  printf '%s\n' "$out" | grep -q 'internalHelper' \
    && bad  "[$mode] PRIVATE leaked into the surface — it is not a contract with anyone" \
    || pass "[$mode] private stays out, in an abstract class as anywhere else"

  # The rule must NOT widen for ordinary classes: that would demand tests for internal seams.
  out="$(probe "$TMP/PlainService.php" "$ff")"
  printf '%s\n' "$out" | grep -q '^handle:public$' \
    && pass "[$mode] a plain class still inventories its public method" \
    || bad  "[$mode] plain class lost its public method"
  printf '%s\n' "$out" | grep -q 'shouldStayInternal' \
    && bad  "[$mode] protected leaked into a PLAIN class — the old rule was right there" \
    || pass "[$mode] a plain class keeps protected out"

  # A trait's protected members are shared with every using class — same contract argument.
  out="$(probe "$TMP/SharedTrait.php" "$ff")"
  printf '%s\n' "$out" | grep -q '^sharedWithUsers:protected$' \
    && pass "[$mode] a trait exposes protected, like an abstract class" \
    || bad  "[$mode] trait protected missing"
  printf '%s\n' "$out" | grep -q 'hidden' \
    && bad  "[$mode] private leaked out of a trait" \
    || pass "[$mode] a trait keeps private out"
done

# The two paths must not disagree, or a degraded run silently measures a different file.
if [ -n "$PHP_BIN" ]; then
  a_raw="$(probe "$TMP/AbstractJob.php" 0)"
  # Assert the arm really took the path it names; the whole point of resolving PHP_BIN above.
  printf '%s\n' "$a_raw" | grep -q '^MODE:ast$' \
    && pass "the AST arm actually ran the AST path, not the fallback wearing its label" \
    || bad  "AST arm degraded: $(printf '%s' "$a_raw" | grep '^MODE:')"
  a="$(printf '%s\n' "$a_raw" | sed '/^MODE:/d' | sort)"
  b="$(probe "$TMP/AbstractJob.php" 1 | sed '/^MODE:/d' | sort)"
  [ "$a" = "$b" ] \
    && pass "the AST path and the textual fallback inventory the SAME surface" \
    || bad  "paths disagree — ast=[$(printf '%s' "$a" | tr '\n' ' ')] fallback=[$(printf '%s' "$b" | tr '\n' ' ')]"
fi

echo
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
