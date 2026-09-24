#!/usr/bin/env bash
# test-coverage-gate.py PHP extraction — what counts as the testable SURFACE of a class.
#
# Sibling of test-coverage-gate-script.sh, which owns this script's functional contract. It lived
# under tests/hooks/ for one commit, which split one target's coverage across two suites that do
# not reference each other — both ran, nothing was skipped, but a reader looking for PHP surface
# behaviour would not have found it where the rest of the gate's tests are.
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
  # Assert the arm took the path it NAMES. The fallback is reached by monkeypatching
  # `shutil.which` to None inside the probe; if that ever stops taking effect the arm silently
  # runs the AST path and the suite compares AST against AST while printing "[fallback]" —
  # a whole arm proving nothing, invisibly. The AST arm gets the same check below.
  want_mode="ast"; [ "$ff" = 1 ] && want_mode="degraded-text"
  printf '%s\n' "$out" | grep -q "^MODE:$want_mode$" \
    && pass "[$mode] the arm really ran the $want_mode path" \
    || bad  "[$mode] arm ran the wrong path: $(printf '%s' "$out" | grep '^MODE:')"
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

# An ANONYMOUS class inside an abstract class is an expression, not a new declaration — but it
# carries the same T_CLASS token, so it used to reset "protected is surface" permanently and every
# protected method declared after a factory-style `new class` silently left the inventory. Found
# by the behaviour audit and, independently, by a cross-model pass.
cat > "$TMP/WithFactory.php" <<'PHP'
<?php
abstract class WithFactory
{
    protected function before() {}
    public function make() { return new class { public function helper() {} }; }
    protected function afterFactory() {}
}
PHP

for mode in $ARMS; do
  ff=0; [ "$mode" = fallback ] && ff=1
  out="$(probe "$TMP/WithFactory.php" "$ff")"
  printf '%s\n' "$out" | grep -q '^before:protected$' \
    && pass "[$mode] a protected method BEFORE a nested anonymous class is surface" \
    || bad  "[$mode] protected method before the nested class was lost"
  printf '%s\n' "$out" | grep -q '^afterFactory:protected$' \
    && pass "[$mode] and so is one declared AFTER it — the anonymous class is not a declaration" \
    || bad  "[$mode] the nested anonymous class reset the rule for everything after it"
done

# TWO TYPES IN ONE FILE — the shape PHP encourages (a trait beside the class that uses it) and
# the one every fixture above avoids by having exactly one type per file. The fallback asked ONCE
# whether the SOURCE contained `abstract class` or `trait` and applied that answer to every method
# in it, so a plain class sharing a file with a trait had its protected methods inventoried too —
# while the AST path, which recomputes the flag at each class keyword, did not. The comment
# claimed the two paths applied "the same rule". Found independently by two auditors; no fixture
# here could express it, because none of them put two types in one file.
cat > "$TMP/Mixed.php" <<'PHP'
<?php
trait HelperTrait
{
    protected function sharedHelper() {}
}
class PlainConsumer
{
    public function handle() {}
    protected function shouldStayInternal() {}
}
PHP

for mode in $ARMS; do
  ff=0; [ "$mode" = fallback ] && ff=1
  out="$(probe "$TMP/Mixed.php" "$ff")"
  printf '%s\n' "$out" | grep -q '^sharedHelper:protected$' \
    && pass "[$mode] the TRAIT's protected method is surface, in a mixed file" \
    || bad  "[$mode] trait protected lost when a plain class shares the file"
  printf '%s\n' "$out" | grep -q 'shouldStayInternal' \
    && bad  "[$mode] the PLAIN class's protected leaked because a trait shares the file" \
    || pass "[$mode] a plain class keeps protected out even next to a trait"
  printf '%s\n' "$out" | grep -q '^handle:public$' \
    && pass "[$mode] the plain class's public method is still inventoried" \
    || bad  "[$mode] plain class public method lost in a mixed file"
done

# ---------------------------------------------------------------------------------------------
# T_CLASS is emitted for three different things and only ONE of them is a declaration. The other
# two both reset the rule above, and the common one is not exotic at all: `self::class` appears
# in any class that logs or registers itself. Every protected method after it left the surface.
#
# Measured on the HEAD of this file before the fix, same fixture:
#   ast:  [alsoHidden, handle, label, surface]        <- build + afterTheAnonClass GONE,
#                                                        the anonymous class's method PRESENT
#   text: [..., notSurface, ...]                      <- a plain readonly class's protected leaked
# ---------------------------------------------------------------------------------------------
cat > "$TMP/Exotic.php" <<'PHP'
<?php
abstract class Exotic
{
/*
A commented-out draft, left at column 0 the way real ones are. Neither declaration exists, but
the textual path read both as code: `phantom` became a symbol, and `class Ghost` became a plain
declaration that re-attributed every protected method BELOW it out of the surface.

class Ghost {}
function phantom() {}
*/
    public function handle(): void
    {
        $name = self::class;
        $anon = new class extends Exotic {
            protected function innerProtected(): void {}
            public function innerPublic(): void {}
        };
        $this->build($name, $anon);
    }

    #[SomeAttribute(1)]
    protected function build(string $n, object $a): string { return $n; }

    protected function afterTheAnonClass(): void {}
}

final readonly class PlainThing
{
    protected function notSurface(): void {}
    public function surface(): void {}
}

enum Status: string
{
    case Live = 'live';
    public function label(): string { return 'x'; }
}
PHP

for mode in $ARMS; do
  ff=0; [ "$mode" = fallback ] && ff=1
  out="$(probe "$TMP/Exotic.php" "$ff")"
  printf '%s\n' "$out" | grep -q '^build:protected$' \
    && pass "[$mode] a protected method after \`self::class\` is still surface" \
    || bad  "[$mode] \`::class\` ended the protected surface: $(printf '%s' "$out" | tr '\n' ' ')"
  printf '%s\n' "$out" | grep -q '^afterTheAnonClass:protected$' \
    && pass "[$mode] and so is one declared after an anonymous class" \
    || bad  "[$mode] the anonymous class ended the protected surface"
  printf '%s\n' "$out" | grep -qE '^inner(Protected|Public):' \
    && bad  "[$mode] an anonymous class's methods were inventoried — nothing can call them by name" \
    || pass "[$mode] an anonymous class's own methods are not file surface"
  printf '%s\n' "$out" | grep -q '^notSurface:' \
    && bad  "[$mode] a \`final readonly class\` was read as abstract — its protected leaked in" \
    || pass "[$mode] \`readonly\` in the modifier run does not make protected surface"
  printf '%s\n' "$out" | grep -q '^surface:public$' \
    && pass "[$mode] the readonly class's public method is inventoried" \
    || bad  "[$mode] readonly class public method lost"
  printf '%s\n' "$out" | grep -q '^label:public$' \
    && pass "[$mode] an enum's method is inventoried" \
    || bad  "[$mode] enum method lost"
  printf '%s\n' "$out" | grep -qE '^phantom:' \
    && bad  "[$mode] a \`function\` named only in a doc block became a symbol" \
    || pass "[$mode] comments are not code — no phantom symbol from the doc block"
done

# ---------------------------------------------------------------------------------------------
# The shapes a second review round found in the fix for the shapes the first one found. Each was
# reverted in a copy of the gate and the inventory changed, so none of these assertions is decor:
#   no attribute prefix in the fallback regexes -> `sameLineAttr` vanishes (degraded)
#   no parenthesis skip before the anon body    -> `insideAnon`/`alsoInsideAnon` appear (ast),
#                                                  because the CLOSURE's brace closed the "body"
#   `]` disallowed inside an attribute          -> the anon body is never blanked (degraded)
# ---------------------------------------------------------------------------------------------
cat > "$TMP/Edge.php" <<'PHP'
<?php
abstract class Edge
{
    public function make(): object
    {
        return new #[Marker([1, 2])] class(function () { return ['k' => 1]; }) extends Edge {
            protected function insideAnon(): void {}
            public function alsoInsideAnon(): void {}
        };
    }

    #[Route('/x')] protected function sameLineAttr(): void {}

    protected function lastOne(): void
    {
        $sql = <<<SQL
class NotAClass {}
function notAFunction() {}
SQL;
        unset($sql);
    }
}
PHP

for mode in $ARMS; do
  ff=0; [ "$mode" = fallback ] && ff=1
  out="$(probe "$TMP/Edge.php" "$ff")"
  printf '%s\n' "$out" | grep -q '^sameLineAttr:protected$' \
    && pass "[$mode] a method whose attribute shares its line is still inventoried" \
    || bad  "[$mode] a same-line attribute hid the whole declaration"
  printf '%s\n' "$out" | grep -qE '^(also)?[iI]nsideAnon:' \
    && bad  "[$mode] a closure in the anonymous class's CONSTRUCTOR ARGS closed the body early" \
    || pass "[$mode] constructor arguments are stepped over before the body is skipped"
  printf '%s\n' "$out" | grep -qE '^(NotAClass|notAFunction):' \
    && bad  "[$mode] a heredoc's contents were read as declarations" \
    || pass "[$mode] a heredoc is data, not code"
  printf '%s\n' "$out" | grep -q '^lastOne:protected$' \
    && pass "[$mode] the method holding the heredoc is itself still surface" \
    || bad  "[$mode] the heredoc swallowed its own method"
done

if [ -n "$PHP_BIN" ]; then
  ea="$(probe "$TMP/Exotic.php" 0)"
  printf '%s\n' "$ea" | grep -q '^MODE:ast$' \
    || bad  "exotic AST arm degraded: $(printf '%s' "$ea" | grep '^MODE:')"
  eb="$(probe "$TMP/Exotic.php" 1 | sed '/^MODE:/d' | sort)"
  ea="$(printf '%s\n' "$ea" | sed '/^MODE:/d' | sort)"
  [ "$ea" = "$eb" ] \
    && pass "both paths agree on the file that used to break BOTH of them, differently" \
    || bad  "paths disagree on the exotic file — ast=[$(printf '%s' "$ea" | tr '\n' ' ')] fallback=[$(printf '%s' "$eb" | tr '\n' ' ')]"
fi

if [ -n "$PHP_BIN" ]; then
  ma="$(probe "$TMP/Mixed.php" 0 | sed '/^MODE:/d' | sort)"
  mb="$(probe "$TMP/Mixed.php" 1 | sed '/^MODE:/d' | sort)"
  [ "$ma" = "$mb" ] \
    && pass "both paths agree on a MIXED file — the case where they used to diverge" \
    || bad  "paths disagree on a mixed file — ast=[$(printf '%s' "$ma" | tr '\n' ' ')] fallback=[$(printf '%s' "$mb" | tr '\n' ' ')]"
fi

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
