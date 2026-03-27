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
