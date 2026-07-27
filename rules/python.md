# Python Conventions

Active when Python is detected in the project (pyproject.toml, requirements.txt, setup.py, or .py files). Not applicable to TypeScript/JavaScript-only projects.

---

## Type Annotations

```python
# Annotate all function signatures
def process_data(items: list[dict[str, Any]], limit: int = 100) -> list[Result]:
    ...

# Use TypedDict for structured dictionaries
class UserData(TypedDict):
    id: str
    email: str
    role: Literal["admin", "user"]

# Use Protocol for structural subtyping
class Serializable(Protocol):
    def to_dict(self) -> dict[str, Any]: ...
```

- Use `from __future__ import annotations` for forward references
- Prefer `list[str]` over `List[str]` (Python 3.9+)
- Use `X | None` over `Optional[X]` (Python 3.10+)

## Pitfall: Mutable Default Arguments

```python
# WRONG — shared mutable default accumulates across calls
def add_item(item: str, items: list[str] = []) -> list[str]:
    items.append(item)  # Mutates across calls!
    return items

# CORRECT — sentinel None with fresh list per invocation
def add_item(item: str, items: list[str] | None = None) -> list[str]:
    if items is None:
        items = []
    items.append(item)
    return items
```

## Pitfall: Blocking Calls in Async Context

```python
# WRONG — synchronous I/O blocks the event loop
async def fetch_data():
    result = requests.get(url)  # Blocks!

# CORRECT — use async HTTP client
async def fetch_data():
    async with httpx.AsyncClient() as client:
        result = await client.get(url)
```

**When no async client exists (`asyncio.to_thread`), do NOT hand-roll a timeout wrapper.** The
usual invention is subtly unsafe: `wait_for` cancels the *await*, but the worker thread keeps
running — it cannot be interrupted — so the "timed out" call still holds its connection, still
writes its result, and under load you accumulate live threads while reporting failures.

```python
# WRONG — looks like a timeout, actually leaks a running thread per call
result = await asyncio.wait_for(asyncio.to_thread(sync_client.get, url), timeout=5)

# CORRECT — push the deadline into the blocking call, which CAN honor it
result = await asyncio.to_thread(functools.partial(sync_client.get, url, timeout=5))

# and bound concurrency so a slow provider cannot exhaust the default thread pool.
# Create the semaphore INSIDE the loop that uses it -- a module-level asyncio.Semaphore()
# can bind to the wrong event loop (fresh loop per test, asyncio.run twice) and then
# deadlocks or raises "attached to a different loop".
_sem: asyncio.Semaphore | None = None
def _limiter() -> asyncio.Semaphore:
    global _sem
    if _sem is None:
        _sem = asyncio.Semaphore(10)     # first call happens on the running loop
    return _sem

async def call():
    async with _limiter():
        return await asyncio.to_thread(functools.partial(sync_client.get, url, timeout=5))
```

Rule: the timeout belongs to whatever owns the socket. `wait_for` around `to_thread` is only
acceptable as an outer *backstop* when the inner call already has its own timeout.

## Exception Handling

```python
# WRONG — bare except catches SystemExit, KeyboardInterrupt
try:
    process()
except:
    pass

# WRONG — Exception is too broad, and silently swallowed
except Exception:
    pass

# CORRECT — specific exceptions, logged, re-raised or handled
try:
    process()
except ValueError as e:
    logger.error("Invalid value: %s", e)
    raise
except (ConnectionError, TimeoutError) as e:
    logger.warning("Network issue: %s", e)
    return fallback_value
```

## Testing with pytest

```python
# File naming: test_module_name.py
# Function naming: test_descriptive_behavior()

def test_process_data_returns_empty_list_for_no_input():
    result = process_data([])
    assert result == []

def test_process_data_raises_on_invalid_input():
    with pytest.raises(ValueError, match="items cannot be None"):
        process_data(None)

# Fixtures for shared setup
@pytest.fixture
def sample_data():
    return [{"id": "1", "name": "Test"}]

# Parametrize for concise multi-case coverage
@pytest.mark.parametrize("input,expected", [
    ("hello", "HELLO"),
    ("", ""),
    ("123", "123"),
])
def test_upper(input, expected):
    assert upper(input) == expected
```

## Code Style

- Follow PEP 8 (enforced by ruff/black/flake8)
- Line length: 88 (black default) or 120
- Prefer f-strings over `.format()` or `%`
- Use pathlib over os.path
- Use dataclasses or Pydantic for data structures
- Never use `eval()`, `exec()`, or `pickle` with untrusted data

## Project Layout

```
src/
├── models/          # Data models (Pydantic/dataclass)
├── services/        # Business logic
├── repositories/    # Database access
├── utils/           # Pure utility functions
└── tests/           # Mirror source structure
    ├── test_models/
    ├── test_services/
    └── conftest.py  # Shared fixtures
```

---

## Defensive Patterns

### Mutable default argument -- use None sentinel
```python
# NEVER -- mutable default shared across calls
def add_item(item, items=[]):
    items.append(item)
    return items           # second call sees first call's data!

# ALWAYS -- None sentinel
def add_item(item, items=None):
    if items is None:
        items = []
    items.append(item)
    return items
```

### Bare except -- catch specific exceptions
```python
# NEVER -- bare except catches SystemExit, KeyboardInterrupt
try:
    process(data)
except:              # catches EVERYTHING, even Ctrl+C
    pass

# ALWAYS -- catch specific
try:
    process(data)
except (ValueError, KeyError) as e:
    logger.error(f"Processing failed: {e}")
```

### f-string in logging -- use lazy % formatting
```python
# NEVER -- f-string always evaluated (even if log level filtered)
logger.debug(f"Processing {len(items)} items with config {config}")

# ALWAYS -- lazy formatting (evaluated only if level active)
logger.debug("Processing %d items with config %s", len(items), config)
```

### Assert in production -- use proper validation
```python
# NEVER -- assert disabled with python -O (production flag)
assert user is not None, "User required"
assert len(items) > 0

# ALWAYS -- explicit check that runs in production
if user is None:
    raise ValueError("User required")
if not items:
    raise ValueError("Items cannot be empty")
```

### Global variable mutation -- pass as parameter
```python
# NEVER -- modifying module-level mutable
_cache = {}
def get_value(key):
    global _cache
    if key not in _cache:
        _cache[key] = expensive_lookup(key)
    return _cache[key]

# ALWAYS -- functools.lru_cache or class with instance state
from functools import lru_cache

@lru_cache(maxsize=128)
def get_value(key):
    return expensive_lookup(key)
```

### String concatenation in loop -- use join
```python
# NEVER -- O(n^2) string concatenation
result = ""
for line in lines:
    result += line + "\n"    # creates new string every iteration

# ALWAYS -- join (O(n))
result = "\n".join(lines)
```

### Unused import -- remove
```python
# NEVER -- imports that aren't used
import os
import json
from typing import List, Dict, Optional

def greet(name: str) -> str:  # only str used
    return f"Hello {name}"

# ALWAYS -- import only what's needed
def greet(name: str) -> str:
    return f"Hello {name}"
```

### External JSON boundaries (provider adapters)

Third-party JSON is the classic source of "validated, then crashed anyway". Validate the
**container and the leaf types**, not just the top level:

```python
# NEVER -- container-only check; items can still be anything
if isinstance(payload.get("offers"), list):
    return [o["price"] for o in payload["offers"]]        # KeyError / TypeError at runtime

# ALWAYS -- validate down to the leaf, and RAISE on malformed instead of filtering it away
offers = payload.get("offers")
if not isinstance(offers, list):
    raise MalformedResponse("offers must be a list")

prices = []
for i, o in enumerate(offers):
    if not isinstance(o, dict):
        raise MalformedResponse(f"offers[{i}] must be an object")
    p = o.get("price")
    if p is None:                       # explicitly absent/null -> documented optional
        continue
    # NOTE: bool is a subclass of int in Python -- `isinstance(True, int)` is True,
    # so a bare (int, float) check accepts `"price": true`. Exclude bool explicitly.
    if isinstance(p, bool) or not isinstance(p, (int, float, str)):
        raise MalformedResponse(f"offers[{i}].price has type {type(p).__name__}")
    prices.append(p)
```

A comprehension with an `isinstance` filter looks like validation but is the opposite: it *hides*
provider breakage by silently shrinking the result. Skip only what the contract says is optional;
raise on everything else.

Three rules that come up on every adapter:

- **Scalar-or-array fields are a documented shape, model them explicitly.** JSON-LD and many
  vendor APIs return `"author": {...}` or `"author": [{...}]` for the same field. Normalize once
  (`v if isinstance(v, list) else [v]`) instead of scattering `isinstance` checks at each use.
- **`null` is not the same as malformed.** An explicitly-null optional field is valid data → use
  the default. A wrong-typed field is a contract violation → raise. Collapsing both into
  `except (TypeError, KeyError): return default` silently swallows real provider breakage.
- **Retry transport failures only.** Timeouts, connection resets, and 5xx are retryable. A schema
  violation or a 4xx is not — retrying it just multiplies the latency before the same failure.
  Keep the retry wrapper around the *transport* call, never around the parse/validate step.

### Exception: facade re-exports when splitting a module

The rule above has one counter-case, and it bites on every module split. When a large module is
split, symbols that siblings already import from the old path -- **including private ones**
(`from x import _y`) -- must stay reachable at that path or every importer breaks. A re-export
looks exactly like an unused import to ruff, so `F401` deletes it and the split silently breaks
consumers. Re-export from the facade **and** list the names in `__all__`; that is what makes the
intent explicit and satisfies F401.

```python
# orders/__init__.py  (facade -- the historical import path)
from ._helpers import _normalize_status, build_cache_key   # noqa: F401 -- re-export
from .types import OrderStatus                             # noqa: F401 -- re-export

# __all__ is the contract, not decoration: it declares the re-export is deliberate
__all__ = ["OrderStatus", "build_cache_key", "_normalize_status"]
```

Verify before moving anything: `python -c "from orders import _normalize_status"` must still
work, and for classes/enums assert **identity** (`orders.OrderStatus is orders.types.OrderStatus`)
-- a re-export that is a distinct object still breaks `isinstance` and enum comparison.

---

## Semgrep-Derived Patterns

### Open redirect -- validate redirect URL (Flask)
```python
# NEVER -- redirect to user input
return redirect(request.args.get('next'))
# ALWAYS -- validate against allowlist
from urllib.parse import urlparse
next_url = request.args.get('next', '/')
if urlparse(next_url).netloc != '':
    next_url = '/'
return redirect(next_url)
```

### XML parsing -- use defusedxml
```python
# NEVER -- stdlib xml is XXE vulnerable
import xml.etree.ElementTree as ET
tree = ET.parse(user_file)
# ALWAYS -- defusedxml
import defusedxml.ElementTree as ET
tree = ET.parse(user_file)
```

### Credential logging -- mask sensitive data
```python
# NEVER -- logging secrets
logger.info(f"Connecting with token={api_token}")
# ALWAYS -- mask or omit
logger.info(f"Connecting with token=***{api_token[-4:]}")
```
