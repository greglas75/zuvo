"""--classify: one model call per unclassified escape PAIR (fix, introducing commit), never per line,
and never more than --classify-max calls in one run.

Candidates come from the whole project store (read under the run's store lock), unattempted pairs
first, then those an earlier run failed on, each newest fix landing first (a row without one: oldest),
so a run with a small cap still works through the backlog across runs and a pair the model keeps
refusing cannot starve the rest. A pair one of whose rows already holds a class (a rescan added a line)
gets that class copied without a call. Rows that are not store.well_formed() are left out and counted
(invalid_rows).

The model sees the two commits' subjects and the diffs of the escaped files (not persisted), the
hunks holding the escaped lines first (zuvo_escapes_hunks); when a diff had to be cut the prompt says
so. It must answer {"class", "description", "diff_catchable"} without quoting code: the class is
folded onto the closed vocabulary and refused when it names none of it, catchable must be a JSON
boolean — or null ("cannot tell") when a diff was cut — the description a string (kept to REASON_MAX
characters). A refused, failed or unbuildable pair stores no class but its attempt
(classify_attempts, classify_failed_at); after MAX_ATTEMPTS it is given up (given_up) until
--reclassify. MAX_FAILED_CALLS failed calls in a row stop the phase (stopped: a dead CLI is not
called once per pending pair), and no call starts after the run's deadline (deadline). The results
are row updates the launcher writes in the SAME upsert as the scan, so a run writes everything or
nothing.
"""

from __future__ import annotations

import datetime as dt
import time
from typing import Any

import zuvo_escapes_fixwalk as fw
import zuvo_escapes_hunks as hunks
import zuvo_escapes_store as store
from zuvo_review_classes import CLASSES, normalize_class
from zuvo_review_llm import run_claude

MODEL = "claude-opus-5-5"
EFFORT = "high"
CALL_TIMEOUT = 600
DIFF_MAX = 12000
REASON_MAX = 300
WHERE_MAX = 40
MAX_ATTEMPTS = 3
MAX_FAILED_CALLS = 3
KEYS = ("class", "description", "diff_catchable")
FIELDS = ("class", "catchable", "class_reason", "classified_at", "classify_model")
STATS = ("calls", "classified", "invalid", "failed", "copied", "pending", "given_up", "stopped", "deadline",
         "invalid_rows")

PROMPT = """You classify a defect that passed code review and was fixed later.

Commit that introduced it — {intro_subject}
{intro_diff}

Commit that fixed it — {fix_subject}
{fix_diff}

The fix removed or rewrote these lines of the introducing commit: {where}
{cut_note}
Answer with ONE JSON object and nothing else. Do not quote code in your answer.
{{"class": one of {classes}, "description": "one sentence: what was wrong",
  "diff_catchable": true if a reviewer reading only the introducing diff could have seen it,
  else false{null}}}
"""
CUT_NOTE = ("A diff above was cut to fit (marked [diff cut]); the hunks holding the escaped lines come "
            "first.\n")
NULL_CHOICE = ", or null if the cut diff cannot tell"


def groups(rows: list[dict[str, Any]], stats: dict[str, int] | None = None) -> list[list[dict[str, Any]]]:
    """Valid rows grouped by (fix_sha, intro_sha): unattempted pairs first, then failed ones, each newest
    fix landing first. Invalid rows are counted in stats["invalid_rows"]."""
    by: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for r in rows:
        if store.well_formed(r):
            by.setdefault((r["fix_sha"], r["intro_sha"]), []).append(r)
        elif stats is not None:
            stats["invalid_rows"] += 1
    order = sorted(by, key=lambda k: (_landed(by[k][0]), k), reverse=True)
    order.sort(key=lambda k: attempts(by[k]) > 0)  # stable: newest first within each half
    return [sorted(by[k], key=lambda r: r["key"]) for k in order]


def _landed(row: dict[str, Any]) -> str:
    """The fix's landing time as text; "" (oldest) when the row has none."""
    ts = row.get("fix_landing_ts")
    return ts if isinstance(ts, str) else ""


def attempts(group: list[dict[str, Any]]) -> int:
    counts = [r.get("classify_attempts") for r in group]
    return max((c for c in counts if isinstance(c, int) and not isinstance(c, bool)), default=0)


def validate(answer: dict[str, Any], cut: bool = False) -> dict[str, Any] | None:
    raw, catchable, reason = answer.get("class"), answer.get("diff_catchable"), answer.get("description")
    if not isinstance(raw, str) or not isinstance(reason, str):
        return None
    if not isinstance(catchable, bool) and not (cut and catchable is None):
        return None  # null ("cannot tell") only when the model was shown a cut diff
    cls = normalize_class(raw)
    if cls == "other" and raw.strip().lower() != "other":
        return None  # a name outside the vocabulary and its aliases, not a deliberate `other`
    return {"class": cls, "catchable": catchable, "class_reason": reason.strip()[:REASON_MAX]}


def _lines(group: list[dict[str, Any]], path_key: str, line_key: str) -> dict[str, set[int]]:
    out: dict[str, set[int]] = {}
    for r in group:
        out.setdefault(r[path_key], set()).add(r[line_key])
    return out


def prompt(repo: str, group: list[dict[str, Any]]) -> tuple[str, bool]:
    """(the prompt for one pair, whether a diff in it was cut). Raises fw.GitError."""
    first = group[0]
    intro_diff, cut_a = hunks.ordered(repo, first["intro_sha"], _lines(group, "intro_file", "intro_line"),
                                      True, DIFF_MAX)
    fix_diff, cut_b = hunks.ordered(repo, first["fix_sha"], _lines(group, "file", "line_at_parent"),
                                    False, DIFF_MAX)
    listed = [f"{p}:{n}" for p, n in sorted({(r["intro_file"], r["intro_line"]) for r in group})]
    more = len(listed) - WHERE_MAX
    where = ", ".join(listed[:WHERE_MAX]) + (f" (+{more} more)" if more > 0 else "")
    subject = fw.git(repo, "show", "-s", "--format=%s", first["intro_sha"]).strip()
    cut = cut_a or cut_b
    return PROMPT.format(intro_subject=subject, intro_diff=intro_diff,
                         fix_subject=first.get("fix_subject", ""), fix_diff=fix_diff, where=where,
                         cut_note=CUT_NOTE if cut else "", classes=", ".join(CLASSES),
                         null=NULL_CHOICE if cut else ""), cut


def run(repo: str, rows: list[dict[str, Any]], max_calls: int, now: dt.datetime, model: str = MODEL,
        deadline_at: float | None = None) -> tuple[list[dict[str, Any]], dict[str, int]]:
    """(row updates for the pairs of `rows`, counts: see STATS; pending = pairs left for a later run by
    the cap or a stop). `deadline_at` is a time.monotonic() value after which no call starts."""
    stats = dict.fromkeys(STATS, 0)
    updates: list[dict[str, Any]] = []
    if now.tzinfo is None:  # a naive `now` is UTC, as in blame.scan — never the host's local time
        now = now.replace(tzinfo=dt.timezone.utc)
    stamp = now.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    failed_in_a_row = 0
    for group in groups(rows, stats):
        done = next((r for r in group if r.get("class")), None)
        if done is not None:
            todo = [r for r in group if not r.get("class")]
            updates += [{"key": r["key"], **{f: done.get(f) for f in FIELDS}} for r in todo]
            stats["copied"] += len(todo)
            continue
        tried = attempts(group)
        if tried >= MAX_ATTEMPTS:
            stats["given_up"] += 1
        elif stats["calls"] >= max_calls or stats["stopped"]:
            stats["pending"] += 1
        elif deadline_at is not None and time.monotonic() >= deadline_at:
            stats["deadline"] += 1
        else:
            fields, call_failed = _classify(repo, group, model, stats)
            failed_in_a_row = failed_in_a_row + 1 if call_failed else 0
            stats["stopped"] = int(failed_in_a_row >= MAX_FAILED_CALLS)
            extra = ({**fields, "classified_at": stamp, "classify_model": model} if fields is not None
                     else {"classify_attempts": tried + 1, "classify_failed_at": stamp})
            updates += [{"key": r["key"], **extra} for r in group]
            if fields is not None:
                stats["classified"] += 1
    return updates, stats


def _classify(repo: str, group: list[dict[str, Any]], model: str,
              stats: dict[str, int]) -> tuple[dict[str, Any] | None, bool]:
    """(the validated class fields or None, whether the model call itself failed)."""
    try:
        text, cut = prompt(repo, group)
    except fw.GitError:
        stats["failed"] += 1  # a commit gone from this clone; no call is spent on it
        return None, False
    stats["calls"] += 1
    result = run_claude(text, model, EFFORT, CALL_TIMEOUT, expect_keys=KEYS)
    if result.answer is None:
        stats["failed"] += 1
        return None, True
    fields = validate(result.answer, cut)
    if fields is None:
        stats["invalid"] += 1
    return fields, False
