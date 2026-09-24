## test-coverage-gate: what PHP counts as testable surface

`T_CLASS` is emitted for three different things and only one of them is a declaration. The gate
treated all three alike, so two common shapes silently ended the protected surface of an abstract
class or trait — and an empty inventory reads as "nothing to test", which is the exact failure the
protected-is-surface rule exists to prevent.

- **`Foo::class` is not a class.** One `self::class` — a logger, a DI map, an event name — reset the
  rule, and every protected method below it left the inventory.
- **An anonymous class is an expression.** Its body is now skipped whole: its methods are not
  surface (nothing can call them by name), and the enclosing class's rule survives it. Previously
  the keyword was skipped but the body was not, so the inner `protected function` was demanded as
  the OUTER class's contract.
- `#[Attr]` between `new` and `class`, `enum`, and `readonly`/`final readonly class` are recognised.
  `readonly` unmatched meant such a class was invisible and its protected methods were attributed to
  whatever was declared above it.
- The degraded (no-php) path blanks comments, string literals and anonymous-class bodies character
  for character before matching, so a `class`/`function` written at column 0 inside a comment no
  longer invents a symbol or re-attributes the real ones. Offsets — and therefore line numbers — are
  unchanged, and both paths now inventory the same surface.

## verify-tests: a mutation run with no verdicts is not a pass

- Stryker's path scored a TIMEOUT as a kill, the JS twin of a rule the Infection path already
  stated. The score now divides by mutants that actually got a verdict, and timeouts are reported
  separately as excluded.
- A run where nothing was decided at all — no mutable code matched, every mutant timed out, the tool
  stopped early — had an empty survivor list and reported PASS. It now fails with an explicit gap.
  `record_survivors()` takes `decided` with no default, so a runner added later cannot inherit the
  old behaviour by saying nothing.
