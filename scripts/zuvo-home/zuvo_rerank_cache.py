"""On-disk cache for rerank scores: one JSON file per (base URL, model, query, ordered docs).

    ${ZUVO_HOME:-$HOME/.zuvo}/cache/rerank/<sha[:2]>/<sha256>.json   {"scores": [float, ...]}

The key covers doc ORDER, because scores are positional. A file is written to a temp name and renamed,
so a reader never sees half of it; a shard that does not parse, or holds the wrong number of finite
floats, is a miss. About one write in 50 prunes the tree: files older than 30 days go, then the oldest
until at most 5 000 remain. Every function here swallows OSError — the cache can only cost a call.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import random
import tempfile
import time
from pathlib import Path

MAX_FILES = 5000
MAX_AGE_S = 30 * 86400
PRUNE_ONE_IN = 50


def default_root() -> Path:
    return Path(os.environ.get("ZUVO_HOME") or Path.home() / ".zuvo") / "cache" / "rerank"


def key(model: str, query: str, docs: list[str], *, base: str) -> str:
    """Covers the endpoint too: scores from one base URL (a stub, another vendor) never serve another."""
    # surrogatepass: text cut mid-pair (a lone surrogate) must hash, not raise UnicodeEncodeError
    raw = json.dumps([base, model, query, docs], ensure_ascii=False).encode("utf-8", "surrogatepass")
    return hashlib.sha256(raw).hexdigest()


def _path(root: Path, k: str) -> Path:
    return root / k[:2] / f"{k}.json"


def get(k: str, n: int, root: Path | None = None) -> list[float] | None:
    try:
        data = json.loads(_path(root or default_root(), k).read_text())
    except (OSError, ValueError):
        return None
    got = data.get("scores") if isinstance(data, dict) else None
    if not isinstance(got, list) or len(got) != n:
        return None
    try:
        if not all(isinstance(x, (int, float)) and not isinstance(x, bool) and math.isfinite(x) for x in got):
            return None
        return [float(x) for x in got]
    except OverflowError:  # an integer too large for a float (10**400) is not a score
        return None


def put(k: str, scores: list[float], root: Path | None = None) -> None:
    root = root or default_root()
    dest = _path(root, k)
    try:
        dest.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=dest.parent, prefix=".tmp-", suffix=".json")
        try:
            with os.fdopen(fd, "w") as fh:
                json.dump({"scores": scores}, fh)
            os.replace(tmp, dest)
        except OSError:
            Path(tmp).unlink(missing_ok=True)
            return
    except OSError:
        return
    if random.randrange(PRUNE_ONE_IN) == 0:
        prune(root)


def prune(root: Path, max_files: int = MAX_FILES, max_age_s: float = MAX_AGE_S) -> int:
    """Remove shards older than max_age_s, then the oldest beyond max_files. Returns how many went."""
    now, live, removed = time.time(), [], 0
    for f in root.glob("*/*.json"):
        try:
            mtime = f.stat().st_mtime
            if now - mtime > max_age_s:
                f.unlink()
                removed += 1
            else:
                live.append((mtime, f))
        except OSError:
            continue
    live.sort()
    for _, f in live[:max(len(live) - max_files, 0)]:
        try:
            f.unlink()
            removed += 1
        except OSError:
            continue
    return removed
