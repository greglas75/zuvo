"""The review-escapes launcher's argument types and its locked run: scan, coverage, classification and
the one store write, in that order, while the launcher holds the store's lock (zuvo_escapes_store).
Kept out of the launcher so it stays a thin entry point; behaviour is the launcher's (see its USAGE).
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
from collections.abc import Callable

import zuvo_escapes_blame as blame
import zuvo_escapes_classify as classify
import zuvo_escapes_coverage as coverage
import zuvo_escapes_fixwalk as fixwalk
import zuvo_escapes_store as store


def duration(text: str) -> dt.timedelta:
    try:
        return fixwalk.parse_duration(text)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc


def at_least(low: int) -> Callable[[str], int]:
    def parse(text: str) -> int:  # [0-9] only: str.isdigit() also takes `²`, which int() refuses
        if not re.fullmatch(r"[0-9]{1,9}", text) or int(text) < low:
            raise argparse.ArgumentTypeError(f"must be an integer >= {low}: {text!r}")
        return int(text)
    return parse


def locked_run(args: argparse.Namespace, repo: str, project: str, ref: str, sha: str, path: str,
               now: dt.datetime, deadline_at: float) -> tuple[dict, int]:
    """Scan, then cover and classify the WHOLE store as this run will leave it (rows of fixes outside
    --since too: a flag judged since the last run changes their label), and write it in one upsert —
    the caller holds the store's lock. (summary, store rows)."""
    updates: list[dict] = []
    opts = blame.Options(sha, args.since, args.max_age, args.mass_files, args.deadline)
    records, summary = blame.scan(repo, project, opts, now)
    view = store.merge_rows(store.read(path)[0], records, args.reclassify)
    unknown = coverage.annotate(repo, project, sha, view, args.line_window)
    out = {"ref": ref, "ref_sha": sha, **summary.as_dict(), "coverage": coverage.counts(view, unknown)}
    if args.classify:
        updates, out["classify"] = classify.run(repo, view, args.classify_max, now, deadline_at=deadline_at)
        out["deadline_hit"] = out["deadline_hit"] or out["classify"]["deadline"] > 0
    total, out["kept_unkeyed"] = store.upsert(path, view + updates, args.reclassify)
    return out, total
