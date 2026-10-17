"""ADVISORY duplicate hint for `backlog-add` — stage 1 of B-20261015-DEDUP-ANCHOR-CHOICE-SPLITS.
Not a script, no shebang, no executable bit.

WHAT IT IS FOR. `backlog-add`'s identity is structural: `fingerprint = CLASS | where | anchor`, and
the anchor is free choice within +-3 lines of `--line`. Two sessions that describe ONE defect but
pick different anchor lines therefore file two entries, and nothing today says so. This module asks a
model whether the candidate is the same defect as a finding already in the ledger, and PRINTS the
answer. That is all it does.

WHAT IT DOES NOT DO. It writes nothing, decides nothing, and changes no verdict. `backlog-add`
behaves identically whether this module answers, refuses or explodes. Stage 3 of the backlog entry is
where a verdict could start depending on it, and only once stage 2 has measured precision on real
pairs; until then a wrong hint costs a line of stderr.

OFF BY DEFAULT. Two independent conditions, both required: `ZUVO_BACKLOG_SIMILAR=1` and an
OpenRouter key. Either one missing is a silent no-op, not a warning — this runs on every ACCEPT, so a
nag would train callers to ignore backlog-add's stderr.

FAIL-OPEN, ALWAYS. Every failure path — no key, no candidates, a timeout, an HTTP error, a response
in a shape this does not know, a corrupt ledger — returns None. `advise` catches BaseException
subclasses other than the ones that must never be swallowed (see `advise`), because an advisory that
can break the one locked write path is worth less than no advisory at all.

OUTSIDE THE LOCK, BY CONSTRUCTION. The lock budget is `ZUVO_LOCK_WAIT` (30 s) and holds the only
write path for the backlog and the ledger; a network call inside it would make every other writer on
the machine wait on a third party. `advise` is called from `_execute` BEFORE `zio.Lock` is taken, and
it therefore folds the ledger WITHOUT the lock. That read is deliberately dirty: a writer committing
between this fold and our lock can only mean the hint was unnecessary, which costs one stderr line.

THE QUESTION. OpenRouter's Decisions API (`POST /api/alpha/decisions`), not `chat/completions` —
that endpoint refuses these models and says so. It returns a PROBABILITY rather than a label, which
is the reason for the route: a threshold can be moved once stage 2 has real pairs, a label cannot.
Measured over `tests/lib/dedup-corpus.py` (2026-10-15), `perplexity/pplx-decider-v1.1-27b` held
AUC 0.919 / 0.913 / 0.923 across three corpus versions, best balanced accuracy 0.856 at p>=0.55 —
hence MODEL and THRESHOLD. Those numbers come from a hard, small subset (18 positives, all of them
REVISIONS of one entry) and are a LOWER bound, not a promise.
"""

from __future__ import annotations

import http.client
import json
import math
import os
import stat
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional, Tuple

import zuvo_backlog_admit as adm
import zuvo_backlog_findings as fnd

ENABLE_ENV = "ZUVO_BACKLOG_SIMILAR"
KEY_ENV = "OPENROUTER_API_KEY"
KEY_FILE = "~/.zuvo/openrouter.key"
KEY_PREFIX = "sk-or-"
# Mirrors the adversarial driver's rule: a key file readable by the group or the world is not used.
KEY_FILE_MODES = (0o600, 0o400)

URL_ENV = "ZUVO_BACKLOG_SIMILAR_URL"
URL = "https://openrouter.ai/api/alpha/decisions"
MODEL_ENV = "ZUVO_BACKLOG_SIMILAR_MODEL"
MODEL = "perplexity/pplx-decider-v1.1-27b"
THRESHOLD_ENV = "ZUVO_BACKLOG_SIMILAR_THRESHOLD"
THRESHOLD = 0.55
TIMEOUT_ENV = "ZUVO_BACKLOG_SIMILAR_TIMEOUT"
TIMEOUT_S = 8.0
# The deadline for the WHOLE advisory, not one call. Without it the per-call timeout multiplies by
# the number of candidates (5 x 8 s = 40 s) and a degraded endpoint stalls the caller before the
# verdict is printed — the lock is safe, the human is not. Calls stop when the budget is spent; the
# answers already in hand are still used.
BUDGET_ENV = "ZUVO_BACKLOG_SIMILAR_BUDGET"
BUDGET_S = 12.0
# A response larger than this is not read. The body is a handful of probabilities; anything bigger
# is a broken or hostile endpoint, and `read()` with no limit would hold whatever it sends in memory.
MAX_RESPONSE_BYTES = 64 * 1024
DEBUG_ENV = "ZUVO_BACKLOG_SIMILAR_DEBUG"

# The label whose probability is read. `criteria` names both sides, so the model answers a two-way
# choice and `probabilities` carries both; only DUP is thresholded.
DUP, NOT_DUP = "DUP", "DIFFERENT"
QUESTION = "same_defect"
INSTRUCTIONS = (
    "Two findings were filed against one repository by automated code review. Decide whether they "
    "describe THE SAME DEFECT. The same defect can be described in different words, cite different "
    "line numbers, quote a different anchor line a few lines apart, and be filed by different "
    "sessions. Two different defects can sit in the same file, in the same function, and share "
    "wording. Judge the defect, not the prose."
)
CRITERIA = {
    DUP: "The two findings are the same defect: fixing one fixes the other.",
    NOT_DUP: "The two findings are different defects: each needs its own fix, even if they are "
             "close together or worded alike.",
}

# How many ledger findings are offered to the model. Candidates are ranked most-recent-first, so the
# cap drops the oldest. One call per candidate: at the measured median (339 ms) and price
# (~$0.0000049/pair) five is a hint that arrives while the caller is still reading the verdict.
MAX_CANDIDATES = 5
# Cap on each field pasted into the question. `how` is capped at adm.EVIDENCE_CAP in the ledger
# already; this bounds a hand-edited segment too.
FIELD_CAP = 600


def _env_float(name: str, default: float) -> float:
    """A malformed or non-positive override falls back to the default: this is an advisory, and
    `ZUVO_BACKLOG_SIMILAR_TIMEOUT=abc` must not be the reason a caller sees a traceback."""
    try:
        value = float(os.environ.get(name, "").strip())
    except ValueError:
        return default
    return value if value > 0 else default


def _debug(what: str, detail: Any) -> None:
    """Say why the advisory gave up, but only when asked. Fail-open silence is the right default on
    the write path and the wrong default when someone is trying to work out why no hint appears, and
    `except Exception: return None` with no way to see the exception is how a feature quietly dies
    and nobody notices for a month."""
    if os.environ.get(DEBUG_ENV, "").strip() == "1":
        import sys as _sys
        print(f"backlog-add: similar: {what}: {detail}", file=_sys.stderr)


def enabled() -> bool:
    return os.environ.get(ENABLE_ENV, "").strip() == "1"


def api_key() -> Optional[str]:
    """`OPENROUTER_API_KEY`, else the key file when its mode is 600 or 400. Returns None rather than
    raising, and never returns the file's contents when the mode is wrong — a world-readable key is
    treated as absent, exactly as the adversarial driver treats it."""
    key = os.environ.get(KEY_ENV, "").strip()
    if key.startswith(KEY_PREFIX):
        return key
    path = Path(os.path.expanduser(KEY_FILE))
    try:
        if stat.S_IMODE(path.stat().st_mode) not in KEY_FILE_MODES:
            return None
        key = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    return key if key.startswith(KEY_PREFIX) else None


def _cap(value: Any) -> str:
    text = "" if value is None else str(value).strip()
    return text[:FIELD_CAP]


def _describe(cls: str, title: str, how: str, anchor: str, path: str, line: Any) -> str:
    """One finding as the question sees it. The F-id is deliberately NOT included: it is a hash of
    the very fields being compared, so showing it would let the model answer from the identity it is
    being asked to second-guess."""
    where = path if not path else f"{path}:{line}" if line not in (None, "") else path
    rows = (("class", cls), ("file", where), ("anchor", anchor), ("title", title), ("evidence", how))
    return "\n".join(f"{name}: {_cap(value)}" for name, value in rows if _cap(value))


def _candidate_text(rec: fnd.Record, path: str = "") -> str:
    """One ledger finding as the question sees it. `path` is the file the candidate filter matched
    on: a record citing several files would otherwise be DESCRIBED by its first one while having
    been SELECTED by another, and the model would be comparing two different places."""
    files = [e for e in (rec.fields.get("files") or []) if isinstance(e, Mapping)]
    cited = next((e for e in files if str(e.get("path") or "") == path), None) or (files[0] if files else {})
    return _describe(str(rec.fields.get("class") or ""), str(rec.fields.get("title") or ""),
                     str(rec.fields.get("how") or ""), str(rec.fields.get("anchor") or ""),
                     str(cited.get("path") or ""), cited.get("line"))


def _finding_text(f: adm.Finding, d: adm.Decision) -> str:
    return _describe(f.cls, d.title or f.title, f.evidence or "", f.anchor or "", f.file or "", f.line)


def _same_file(rec: fnd.Record, path: str) -> bool:
    files = rec.fields.get("files") or []
    if not isinstance(files, list):
        return False
    return any(isinstance(e, Mapping) and str(e.get("path") or "") == path for e in files)


def candidates(records: Mapping[str, fnd.Record], f: adm.Finding, fid: str) -> List[Tuple[str, fnd.Record]]:
    """Same class, same cited file, not this finding — ranked most-recent first, capped.

    Same-class and same-file is the whole filter on purpose. It is the population the anchor split
    actually lives in (one defect, one file, one class, two anchors), it is what keeps the call count
    at one per genuinely plausible pair, and it is cheap enough to compute from the fold we already
    have. A finding with no cited file cannot be in that population and is not asked about.
    """
    if not f.file:
        return []
    rows = [(fid_other, rec) for fid_other, rec in records.items()
            if fid_other != fid
            and str(rec.fields.get("class") or "") == f.cls
            and _same_file(rec, f.file)]
    rows.sort(key=lambda row: str(row[1].fields.get("ts") or ""), reverse=True)
    return rows[:MAX_CANDIDATES]


def _probability(payload: Any) -> Optional[float]:
    """The DUP probability, wherever the response carries it.

    The shape measured on 2026-10-15 is flat (`{"choice":…,"probabilities":{…},"confidence":…}`), but
    the endpoint is `/api/alpha/` and takes a MAP of questions, so a per-question nesting is the
    obvious way for it to change. Rather than pin one shape and start returning silent no-ops the day
    it moves, this walks the response for the first `probabilities` object that prices DUP.
    """
    stack: List[Any] = [payload]
    while stack:
        node = stack.pop(0)
        if isinstance(node, Mapping):
            probs = node.get("probabilities")
            value = probs.get(DUP) if isinstance(probs, Mapping) else None
            # bool is an int: `{"DUP": true}` is a label, not a probability, and must not read as 1.0.
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                p = float(value)
                # NaN fails every comparison, so an unchecked NaN slips past the threshold test and
                # prints `p=nan`; a value outside [0, 1] is not a probability whatever it is.
                if math.isfinite(p) and 0.0 <= p <= 1.0:
                    return p
                return None
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
    return None


def _post(key: str, state: str, timeout: float) -> Any:
    body = {
        "model": os.environ.get(MODEL_ENV, "").strip() or MODEL,
        "state": state,
        "questions": {QUESTION: {"type": "choice", "instructions": INSTRUCTIONS, "criteria": CRITERIA}},
    }
    req = urllib.request.Request(
        os.environ.get(URL_ENV, "").strip() or URL,
        data=json.dumps(body).encode("utf-8"),
        headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json",
                 "X-Title": "zuvo-backlog-similar"})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read(MAX_RESPONSE_BYTES), strict=False)


def ask(key: str, existing: str, new: str, timeout: Optional[float] = None) -> Optional[float]:
    """P(same defect) for one pair, or None when the call or the response fails."""
    state = f"EXISTING FINDING\n{existing}\n\nNEW FINDING\n{new}"
    try:
        return _probability(_post(key, state, timeout or _env_float(TIMEOUT_ENV, TIMEOUT_S)))
    except Exception as exc:                     # noqa: BLE001 — see FAIL-OPEN, ALWAYS above
        # Not OSError|ValueError: a truncated body raises http.client.IncompleteRead and a dropped
        # connection RemoteDisconnected, both HTTPException, which is neither of those.
        _debug("call failed", exc)
        return None


def _best(key: str, rows: List[Tuple[str, fnd.Record]], new: str, path: str) -> Optional[Tuple[str, float]]:
    """The highest-scoring candidate, within one overall deadline. Candidates are asked in order
    (newest first), so a budget that runs out drops the least likely ones, and whatever was answered
    before it ran out still counts."""
    per_call = _env_float(TIMEOUT_ENV, TIMEOUT_S)
    deadline = time.monotonic() + _env_float(BUDGET_ENV, BUDGET_S)
    scored: List[Tuple[str, float]] = []
    for other, rec in rows:
        left = deadline - time.monotonic()
        if left <= 0.5:                          # too little left to be worth a connection
            _debug("budget spent", f"{len(scored)}/{len(rows)} candidates asked")
            break
        p = ask(key, _candidate_text(rec, path), new, timeout=min(per_call, left))
        if p is not None:
            scored.append((other, p))
    if not scored:
        return None
    return max(scored, key=lambda row: row[1])


def advise(ledger: Path, f: adm.Finding, d: adm.Decision, fid: str) -> Optional[str]:
    """The one entry point. Returns the stderr line, or None when there is nothing to say.

    Returns None — never raises — for: the feature off, no key, no cited file, a fingerprint the
    ledger already knows (the structural key HITS, so this call would be bumped and no hint is owed),
    no same-file same-class candidate, every call failing, and the best probability below the
    threshold. KeyboardInterrupt and SystemExit are deliberately NOT caught: a caller interrupting
    `backlog-add` must not be told it was an advisory hiccup.
    """
    if not enabled():
        return None
    try:
        key = api_key()
        if key is None:
            return None
        records, _ = fnd.fold(ledger)            # unlocked read: see OUTSIDE THE LOCK above
        if fid in records:
            return None
        rows = candidates(records, f, fid)
        if not rows:
            return None
        best = _best(key, rows, _finding_text(f, d), f.file or "")
        if best is None:
            return None
        other, p = best
        if p < _env_float(THRESHOLD_ENV, THRESHOLD):
            return None
        return f"SIMILAR {other} p={p:.2f} (advisory: nothing was changed by this)"
    except Exception as exc:                     # noqa: BLE001 — see FAIL-OPEN, ALWAYS above
        # KeyboardInterrupt and SystemExit are BaseException, not Exception, so they are not caught
        # here: a caller interrupting `backlog-add` must not be told it was an advisory hiccup.
        _debug("advisory failed", exc)
        return None
