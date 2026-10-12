"""Coverage of each escape row: `reviewed` (zuvo_escapes_artifacts) × `flagged` (zuvo_escapes_ledgerjoin),
folded into one label, flagged-* > reviewed > unreviewed: a flag says more about the review than its
having happened. Fields written on every well-formed row (store.well_formed) of the WHOLE store on
every run, not only the rows this run scanned: reviewed, flagged, coverage, coverage_evidence
{artifact, method, provisional, range_unresolved, review_tags, findings, match} — names, shas and
fingerprints only, never text from a diff or an artifact body.

Counts (scope "store") come per row (line) and per fix/intro pair; a pair takes the strongest label
among its rows. `flag_unknown` counts the rows whose ledger time window git could not read (left
unflagged), `malformed` the rows left without a label.
"""

from __future__ import annotations

from collections import Counter
from typing import Any

import zuvo_escapes_artifacts as arts
import zuvo_escapes_discover as disc
import zuvo_escapes_ledgerjoin as lj
import zuvo_escapes_store as store

LABELS = ("flagged-accepted", "flagged-dismissed", "flagged-unjudged", "reviewed", "unreviewed")
_RANK = {name: i for i, name in enumerate(LABELS)}


def label(reviewed: bool, flagged: str) -> str:
    if flagged != "none":
        return f"flagged-{flagged}"
    return "reviewed" if reviewed else "unreviewed"


def annotate(repo: str, project: str, ref_sha: str, rows: list[dict[str, Any]], line_window: int) -> int:
    """Add the coverage fields to every row in place; returns how many rows could not be joined to the
    ledger (their window unreadable). Raises OSError when a ledger cannot be read."""
    rows = [r for r in rows if store.well_formed(r)]
    if not rows:
        return 0
    reviews = arts.Reviews(repo, ref_sha, disc.discover(repo, project))
    reviews.prefetch(rows)
    join = lj.Join(repo, project, line_window)
    join.prefetch(rows)
    for row in rows:
        seen = reviews.verdict(row)
        flag = join.flag(row)
        row.update({
            "reviewed": seen.reviewed, "flagged": flag.flagged,
            "coverage": label(seen.reviewed, flag.flagged),
            "coverage_evidence": {
                "artifact": seen.artifact, "method": seen.method, "provisional": seen.provisional,
                "range_unresolved": seen.range_unresolved, "review_tags": reviews.review_tags(row),
                "findings": flag.findings, "match": flag.match,
            },
        })
    return join.unknown


def counts(rows: list[dict[str, Any]], flag_unknown: int = 0) -> dict[str, Any]:
    good = [r for r in rows if store.well_formed(r)]
    by_row = Counter(r["coverage"] for r in good)
    best: dict[tuple[str, str], str] = {}
    for r in good:
        pair = (r["fix_sha"], r["intro_sha"])
        if pair not in best or _RANK[r["coverage"]] < _RANK[best[pair]]:
            best[pair] = r["coverage"]
    by_pair = Counter(best.values())
    return {"scope": "store", "rows": {k: by_row[k] for k in LABELS},
            "pairs": {k: by_pair[k] for k in LABELS}, "flag_unknown": flag_unknown,
            "malformed": len(rows) - len(good)}


def report(project: str, out: dict[str, Any], path: str, total: int) -> str:
    """The launcher's one-line text summary of a run's JSON summary `out`."""
    def pairs(d: dict[str, Any], keep_zero: bool = False) -> str:
        return " ".join(f"{k}={v}" for k, v in sorted(d.items()) if v or keep_zero) or "none"
    cov = out["coverage"]
    cls = f"; classify: {pairs(out['classify'], True)}" if "classify" in out else ""
    hit = str(out["deadline_hit"]).lower()
    unknown = f", flag_unknown={cov['flag_unknown']}" if cov.get("flag_unknown") else ""
    kept = f", {out['kept_unkeyed']} unkeyed lines kept" if out.get("kept_unkeyed") else ""
    return (f"review-escapes: {project} @ {out['ref']} ({out['ref_sha'][:10]}): {out['fixes']} fixes, "
            f"{out['escapes']} escapes ({out['escape_pairs']} fix/intro pairs), {out['unattributed']} "
            f"unattributed, deadline_hit={hit}; skipped: {pairs(out['skipped'])}; "
            f"coverage: {pairs(cov['rows'])} (pairs: {pairs(cov['pairs'])}){unknown}{cls}; "
            f"store {path} ({total} rows{kept})")
