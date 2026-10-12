"""The closed defect-class vocabulary every review-learning helper speaks.

Per-class rates and rule retirement divide by class, so one class written two ways (`docs` and
`documentation`, `input-validation` and `validation`) reads as two half-sized ones. New answers are
asked for in this vocabulary; free text in older records is folded onto it on read, never re-judged.
Anything unrecognized is `other`, never dropped.
"""

from __future__ import annotations

import re

CLASSES: tuple[str, ...] = (
    "race-condition", "null-handling", "numeric", "boundary", "contract-drift", "validation",
    "error-handling", "auth", "tenant-scope", "data-loss", "resource-leak", "perf", "test-gap",
    "logic", "style", "other",
)

# Built from the class names present in bill-data/defects.jsonl. Names whose meaning depends on
# context (i18n, a11y, config, build) stay `other` rather than guessing a class.
_ALIAS_GROUPS: dict[str, tuple[str, ...]] = {
    "race-condition": ("race", "concurrency", "async", "shared-state", "deadlock", "atomicity", "toctou"),
    # not "null"/"none": a judge writes those for "no class", which is `other`
    "null-handling": ("undefined", "nullable", "nullability", "null-check", "null-safety",
                      "null-pointer", "null-reference", "npe", "missing-null-check"),
    "numeric": ("numeric-stability", "overflow", "precision", "rounding", "arithmetic", "math",
                "floating-point", "division-by-zero"),
    "boundary": ("off-by-one", "edge-case", "bounds", "out-of-bounds", "boundary-condition"),
    "contract-drift": ("contract", "api-contract", "api-break", "api-compat", "api-surface",
                       "breaking-change", "backward-compat", "backward-compatibility", "compat",
                       "compatibility", "data-contract", "output-contract", "type-contract", "schema",
                       "data-compat", "data-format", "wiring"),
    "validation": ("input-validation", "validation-bypass", "injection", "xss", "sanitization",
                   "sql-injection", "path-traversal"),
    "error-handling": ("errors", "error", "exception", "exception-handling", "missing-timeout", "timeout",
                       "signal-handling"),
    "auth": ("security", "authz", "authn", "authorization", "authentication", "permissions", "privacy",
             "data-leak", "data-exposure", "data-disclosure", "secrets", "secret-leak"),
    "tenant-scope": ("tenant", "tenancy", "multi-tenant", "tenant-isolation", "tenant-scoping"),
    "data-loss": ("data-integrity", "data-consistency", "data-migration", "data-retention",
                  "data-corruption", "rollback-safety"),
    "resource-leak": ("resource-cleanup", "resource-lifecycle", "leak", "memory-leak", "cleanup",
                      "fd-leak", "process-leak"),
    "perf": ("performance", "caching", "n+1", "n-plus-one", "efficiency", "scalability"),
    "test-gap": ("test-isolation", "test-flakiness", "test-design", "test-quality", "test-fixture",
                 "test-robustness", "test-duplication", "test-coupling", "test-architecture", "test-naming",
                 "brittle-test", "testing", "tests", "test", "coverage", "missing-test"),
    "logic": ("bug", "correctness", "state", "state-management", "determinism", "type-error",
              "type-safety", "type", "types"),
    "style": ("docs", "documentation", "documentation-logic", "stale-comment", "comment", "naming",
              "maintainability", "readability", "dead-code", "design", "architecture", "consistency",
              "contract-doc", "duplication"),
}

ALIASES: dict[str, str] = {alias: canon for canon, group in _ALIAS_GROUPS.items() for alias in group}

_SEPARATORS = re.compile(r"[\s_]+")
_DASHES = re.compile(r"-{2,}")


def normalize_class(value: object) -> str:
    """Fold any class the judge or an old record carries onto CLASSES; `other` when unrecognized."""
    if not isinstance(value, str):
        return "other"
    key = _DASHES.sub("-", _SEPARATORS.sub("-", value.strip().lower())).strip("-")
    if key in CLASSES:
        return key
    return ALIASES.get(key, "other")
