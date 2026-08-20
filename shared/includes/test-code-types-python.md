# Test Code-Type Templates — Python

> Loaded when stack detection resolves Python (see SKILL.md — signals include
> `requirements.txt`/`pytest.ini`, not only `pyproject.toml`). Shapes below come from the
> 2026-08-19 fleet audit: data-lab (1,549 py), coding-ui (176), translation-qa (59),
> tgm-survey-platform (17). The core table's code types still apply; this file adds the
> Python-specific shapes the core rows cannot see and the fixture rules that have no JS analog.

## Python-Specific Shapes

| Shape | Detection | What to test | Key pattern |
|-------|-----------|--------------|-------------|
| MIXIN-COMPOSITION | `class X(AMixin, BMixin, CMixin)`; 60+ `*Mixin` classes in data-lab | Each mixin in isolation via a minimal host class; ONE composed test pinning `X.__mro__` order for every overridden member; `super()` chain reaches the base exactly once | Minimal host: `class Host(TargetMixin): <only the attrs the mixin reads>` |
| FLUENT-BUILDER | Methods returning `self`, terminal `.apply()`/`.preview()` (`CodingBuilder`, 924 LOC) | Chain-identity (`b.id_field(..) is b`); terminal ops separately (preview mutates NOTHING, apply commits); invalid step ORDER raises; two builder instances share NO state | State-isolation: build two, interleave calls, assert independence |
| DATACLASS-DTO | `@dataclass` value objects (80+ files; 33 in one module) | Field defaults, `frozen`/`eq` semantics where declared, and NOTHING else — do NOT apply "Functions × 4" to a record | One test per invariant the dataclass declares, not per field |
| DATAFRAME-PIPELINE | `import polars as pl` / `import pandas as pd` transforms (90+ files) | Golden small-frame in → expected frame out via `pl.testing.assert_frame_equal` / `pd.testing.assert_frame_equal` (NEVER row-count-only); dtype pins; empty-frame; when code branches on frame type (`df: pl.DataFrame or pd.DataFrame`), parametrize the SAME case over both libraries | Frame-equality with `check_dtype=True`; empty frame is a first-class case |
| ABC/PROTOCOL | `ABC` bases, `typing.Protocol` (`_WeightingServiceProtocol`) | ONE contract test module parametrized over every registered implementation; each impl passes the identical behavioral suite | `@pytest.mark.parametrize("impl", ALL_IMPLS)` over the shared contract |
| CONTEXT-MANAGER-DB | `with get_conn() as c:` raw SQL, no ORM (`postgres/core.py`, `sqlite/core.py`) | Fake connection object RECORDING `execute` calls (SQL text + params asserted); commit on success path; rollback on the exception path; unit tests never open a real DB | Recording fake: `calls: list[tuple[sql, params]]`; engine-specific SQL semantics → NEEDS_INTEGRATION row |
| RENDERER/LAYOUT | Mutates a passed-in document object (python-pptx `Presentation`, matplotlib fig) instead of returning data | Assert on the RESULTING object graph — shapes, text runs, positions, slide count; boundary-test every size-dependent branch and every divide-by-count guard (`sum(...) or 1`); never pixel-compare in unit tests | Walk the object tree; one test per defensive fallback branch |
| CONSOLE/SCRIPT | `argparse`/`click` entrypoints, `if __name__ == "__main__"` | Parser accepts/rejects (invalid arg → SystemExit with code); handler called with parsed namespace; exit codes per outcome | Call `main(argv=[...])` directly; never subprocess in unit tests |

## Fixture Scope — the #1 Python flake source (no JS analog)

pytest fixtures form a GRAPH (data-lab: 26+36+11 across three conftests, chained, mixed
session/module/autouse). Rules:

1. Any `autouse` or `session`-scoped fixture a test depends on must be NAMED in the test's
   contract row — invisible setup is how order-dependent flakes are born.
2. A `session`/`module` fixture that yields a MUTABLE object needs one state-leak test: two
   consumers, second asserts pristine state.
3. Chained fixtures (fixture requesting fixture): test the terminal fixture's contract once,
   not each link separately.
4. Never widen a fixture's scope to make a slow suite faster without adding the state-leak test
   from rule 2 in the same commit.

## Legitimate skips (contra the PHP-worded blocklist)

`pytest.skip("DATABASE_URL not set")` guarding a real integration dependency is a LEGITIMATE
environment gate, not AP28 — the repo pattern (28+ instances in data-lab) is correct. AP28
applies when the skip has no reason string naming the missing dependency/env var, or when it
gates a test that needs no environment.

## Mutation probes for Python

`mutmut 3.x` cannot scope per file (SKILL.md Step 3.3 exclusion stands), so Python relies
entirely on the manual 3–5 probe floor. For transform-heavy files (DATAFRAME-PIPELINE,
column/join/filter logic) raise the floor to 5 and target: one dropped column, one inverted
filter, one wrong join type — the exact classes an under-sampled probe set misses.
