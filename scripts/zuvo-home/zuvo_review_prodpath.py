"""Which changed paths are production code — the Python twin of pg_is_production.

hooks/lib/pipeline-gate-lib.sh decides which files the push gate demands a review for. The review
metrics (lines reviewed per week, escapes per kloc) must not count a path the gate calls
non-production, or a rate moves with lockfile churn instead of with code. BASH_PATTERNS is that
function's case list verbatim, in order — tests/hooks/test-prodpath-parity.sh extracts the bash list
and fails on any difference. fnmatchcase's `*` crosses `/` exactly like a bash `case` glob.

EXTRA_PATTERNS are what only the metrics need: generated output, lockfiles bash leaves to `*.lock`,
test layouts the gate's `tests/` rule misses (e2e suites, fixtures) and CI pipeline code. Tool and
test configs (`vitest.config.ts`, `stryker.conf.mjs`) count out only OUTSIDE `src/`: a `*.config.*`
module inside it (`auth-cache.config.ts`) is application code. Both only ever REMOVE paths from
production, so a Python verdict can be stricter than the gate's, never looser.
"""

from __future__ import annotations

import re
from fnmatch import fnmatchcase

BASH_PATTERNS: tuple[str, ...] = (
    "tests/*", "*/tests/*",
    "__tests__/*", "*/__tests__/*",
    "*.test.*", "*.spec.*",
    "docs/*", "*/docs/*",
    "*.md",
    "*.json", "*.yaml", "*.yml", "*.toml",
    "*.lock",
    ".*rc", "*/.*rc",
    "zuvo/*", "*/zuvo/*",
    ".zuvo/*", "*/.zuvo/*",
    "VERSION", "*/VERSION",
    "CHANGELOG", "*/CHANGELOG",
    "LICENSE", "*/LICENSE", "LICENCE", "*/LICENCE",
    "NOTICE", "*/NOTICE",
    "AUTHORS", "*/AUTHORS",
    "CONTRIBUTORS", "*/CONTRIBUTORS",
)


def _anywhere(*dirs: str) -> tuple[str, ...]:
    return tuple(p for d in dirs for p in (f"{d}/*", f"*/{d}/*"))


def _basename(*globs: str) -> tuple[str, ...]:
    return tuple(p for g in globs for p in (g, f"*/{g}"))


EXTRA_PATTERNS: tuple[str, ...] = (
    _anywhere("test", "spec", "e2e", "fixtures", "__fixtures__", "__snapshots__", "__generated__",
              "generated", "dist", "vendor", "node_modules", ".github")
    + _basename("test_*.py", "*_test.py", "*_test.go", "*_spec.rb", "go.sum", "*.lockb")
    + ("*.min.js", "*.min.css", "*.map", "*.snap", "*.pb.go", "*_pb2.py", "*.g.dart", "*.generated.*",
       "*.fixture.*", "*.fixtures.*", "ci/*", "scripts/ci/*", "*/scripts/ci/*")
)
CONFIG_BASENAMES: tuple[str, ...] = ("*.config.*", "*.conf.*")


def _tool_config(p: str) -> bool:
    """A `*.config.*` / `*.conf.*` file outside any `src/` directory."""
    base = p.rsplit("/", 1)[-1]
    in_src = p.startswith("src/") or "/src/" in p
    return not in_src and any(fnmatchcase(base, g) for g in CONFIG_BASENAMES)


_LINE_SUFFIX = re.compile(r":[0-9]+(?:[-\u2010-\u2015\u2212][0-9]+)?$")


def _normalize(path: str, root: str | None) -> str:
    """Repo-relative form of a ledger cell or a git path: no `:line[-line]`, no leading `./`, and an
    absolute path under `root` made relative (outside it, it stays absolute)."""
    p = _LINE_SUFFIX.sub("", path.strip())
    if root and p.startswith("/"):
        prefix = root.rstrip("/") + "/"
        if p.startswith(prefix):
            p = p[len(prefix):]
    while p.startswith("./"):
        p = p[2:]
    return p


def is_production(path: str, root: str | None = None) -> bool:
    """True unless the path matches a non-production pattern; an empty path is not production.
    `root` (the checkout) turns an absolute path into a repo-relative one first, so a checkout that
    lives under e.g. `~/docs/` is not read as documentation."""
    p = _normalize(path, root)
    if not p:
        return False
    return not (_tool_config(p) or any(fnmatchcase(p, pat) for pat in BASH_PATTERNS + EXTRA_PATTERNS))
