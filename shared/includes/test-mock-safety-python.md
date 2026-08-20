# Test Mock Safety — Python

> Loaded with `test-code-types-python.md`. Five rules; the first two account for most silent
> Python test rot (fleet audit 2026-08-19, data-lab GAP-3).

## 1. Patch where it is LOOKED UP, not where it is defined

`monkeypatch.setattr` / `mock.patch` target the CONSUMING module's reference:

```python
# theme_loader.py:      from config import THEME_DIR
# WRONG: patch('config.THEME_DIR', ...)          — theme_loader keeps its old reference
# RIGHT: monkeypatch.setattr(theme_loader_module, 'THEME_DIR', tmp_path)
```

The repo pattern (`test_theme_loader.py`, 50× `monkeypatch.setattr(_theme_loader_module, ...)`)
is the reference implementation. A patch that targets the defining module while production
imported the name directly is a mock that never fires — the test goes green against nothing.

## 2. Autospec gate — `MagicMock()` without a spec is `as any`

A bare `MagicMock()` accepts every attribute and any call signature, so signature drift in
production never fails the test. This is the same violation class the TS gate catches as
`as any` (Q5) — score it identically.

- Own interfaces: `create_autospec(RealClass)` or `Mock(spec=RealClass)` — mandatory.
- `mock.patch(...)`: pass `autospec=True` unless patching a plain attribute/constant.
- The one exemption: truly duck-typed third-party payloads with no importable type — note it
  in the contract row.

Reference density from the fleet: 10–16 `autospec`/`spec=` uses per AI-provider test module in
data-lab. Zero uses in a new module touching owned classes = Q5 fail.

## 3. Time — check for an injected clock BEFORE reaching for freezegun

Same rule as the JS injected-clock row: read the signature first. If production takes a
`clock`/`now_fn` parameter, inject a controlled one; `freezegun.freeze_time` is for code that
reads module-level `datetime.now()` with no seam. Never mix both in one test.

## 4. Async

`pytest.mark.asyncio` only when the unit under test is `async def`. Wrapping sync production
code in an async test adds an event loop for nothing and hides `RuntimeWarning: coroutine was
never awaited` failures. (data-lab: production `src/**` has no `async def` — an async test
there is a smell by itself.)

## 5. Network and processes

Unit tests never open sockets or spawn subprocesses. HTTP boundaries: `responses` /
`respx`-style transport mocks on the client object, asserted with full request args (URL,
method, body) — the CalledWith discipline from the core rules applies unchanged. If a test
needs a real port or a real interpreter, it is NEEDS_INTEGRATION and says so in its header.
