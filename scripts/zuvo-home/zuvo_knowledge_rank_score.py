"""Per-entry rules for zuvo_knowledge_rank: the Step 4 section, the text BM25 and the reranker see, the
Step 3 score of an entry when there is no task to match, and whether its affectedFiles cover a task file.

affectedFiles are written gitignore-style, so `*` stays inside one path segment, `**/` spans zero or more
directories, a leading `./` on either side is ignored, a pattern without `/` matches the basename at any
depth, and a trailing `/` covers everything under that directory; fnmatch would let `*` cross `/`.

Dates are ISO 8601 (a date, or a datetime with Z or ±hh:mm) compared as UTC instants; a naive value is
taken as UTC and an unparseable one sorts as the oldest.
"""

from __future__ import annotations

import re
from datetime import UTC, date, datetime
from functools import lru_cache
from typing import Any

Entry = dict[str, Any]

_SECTION_OF = {"anti-pattern": "MUST AVOID", "gotcha": "GOTCHAS", "decision": "DECISIONS",
               "codebase-fact": "CODEBASE FACTS", "api-behavior": "CODEBASE FACTS", "pattern": "PATTERNS"}
CONFIDENCE = {"high": 1.0, "medium": 0.0, "low": -1.0}
_OLDEST = datetime.min.replace(tzinfo=UTC)


def section(entry: Entry) -> str | None:
    if entry.get("type") == "gotcha" and entry.get("confidence") == "high":
        return "MUST AVOID"
    return _SECTION_OF.get(str(entry.get("type")))


def text(entry: Entry) -> str:
    tags = entry.get("tags")
    parts = [str(t) for t in tags] if isinstance(tags, list) else []
    for field, legacy in (("fact", "content"), ("recommendation", "implication")):
        value = entry.get(field) or entry.get(legacy)
        if isinstance(value, str):
            parts.append(value)
    return " ".join(parts)


def instant(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        moment = datetime.fromisoformat(value)
        return moment.replace(tzinfo=UTC) if moment.tzinfo is None else moment.astimezone(UTC)
    except (ValueError, OverflowError, TypeError):  # astimezone overflows at year 1 with a + offset
        return None


def recency(entry: Entry) -> datetime:
    return instant(entry.get("updatedAt") or entry.get("createdAt")) or _OLDEST


def prime_score(entry: Entry, today: date | None = None) -> float:
    """Step 3 without its keyword and file rows: confidence, recency bonus, staleness, unvalidated."""
    conf = str(entry.get("confidence"))
    score = CONFIDENCE.get(conf, 0.0)
    updated = instant(entry.get("updatedAt"))
    age = ((today or datetime.now(UTC).date()) - updated.date()).days if updated else None
    if age is not None and 0 <= age <= 30:  # a future date is a clock or typing error, not "recent"
        score += 1
    if age is not None and age > 180 and conf != "high":
        score -= 1
    if entry.get("timesSurfaced") == 0 and conf == "low":
        score -= 2
    return score


@lru_cache(maxsize=1024)
def _glob(pattern: str) -> re.Pattern[str]:
    out = []
    for token in re.findall(r"\*\*/|\*\*|\*|\?|[^*?]+", pattern.removeprefix("./")):
        out.append({"**/": "(?:.*/)?", "**": ".*", "*": "[^/]*", "?": "[^/]"}.get(token) or re.escape(token))
    return re.compile("".join(out) + r"\Z")


def glob_hit(entry: Entry, files: list[str]) -> bool:
    globs = entry.get("affectedFiles")
    if not isinstance(globs, list):
        return False
    return any(isinstance(g, str) and _match(g, f.removeprefix("./")) for g in globs for f in files)


def _match(pattern: str, path: str) -> bool:
    pattern = pattern.removeprefix("./")
    if pattern.startswith("/"):  # gitignore: a leading slash anchors at the root (paths are root-relative)
        pattern = pattern.lstrip("/")
        return _glob(pattern + ("**" if pattern.endswith("/") else "")).match(path) is not None
    if pattern.endswith("/"):
        pattern = ("" if "/" in pattern[:-1] else "**/") + pattern + "**"
    target = path if "/" in pattern else path.rsplit("/", 1)[-1]
    return _glob(pattern).match(target) is not None
