"""CONTROL (d)'s SEEDS: the rows whose answer this repo already records, and the interleave that makes
them indistinguishable from real work. Imported by backlog-groom.py; not a script, no shebang, no
executable bit.

WHY THIS IS THE ONLY CONTROL THAT MEASURES JUDGEMENT. (a) shape, (b) resolvability and (c) keyword
overlap all ask whether a verdict is well-formed and grounded in a line that exists. None of them can
ask whether it is RIGHT — (c)'s own limit, stated in `shared/includes/backlog-grooming.md`, is that
citing the very line the entry names satisfies it while the verdict is still wrong. A seed can ask,
because the answer is already on record, and that is the whole reason K=4 rows of every chunk are spent
on work whose result is known.

WHY A SEED MUST BE INDISTINGUISHABLE, and why that shapes the file layout rather than only the prose.
Nothing in a dispatched seed row says it is one: `seed_row` emits exactly the queue's field set, the
expected verdict lives in a SEPARATE answer file the read-only agent is never pointed at, and
`interleave` mixes the seeds through the chunk by a stable hash instead of appending them. Sorting the
dispatch by key would have put every seed in one block — `fp:ffff…` sorts after every real `fp:` key —
and a verifier that can see which four rows are graded is being graded on four rows it can look up.

WHY THE CLOSED SEEDS ARE STRIPPED. A seed built from an archived entry's text VERBATIM carries its own
`FIXED <sha>` marker, so the answer is legible from the seed and (d) degrades into a reading test — and
the deterministic marker class would have decided it anyway. `strip_resolution_markers` removes exactly
that shrapnel, which leaves the agent the work the seed exists to measure: find the fix.

A SHORTFALL IS A REFUSAL AT THE CALLER, never a smaller K. A chunk dispatched with two seeds instead of
four is an under-gated chunk that reads identically to a gated one in every report, which is the one
failure this control cannot survive.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, exactly as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. `sys.path` is the
IMPORTER's job. By importing the parser this module joins the pin-guard family that
`tests/hooks/test-backlog-headings.sh` (H19c) DERIVES, where its expectation is the default one: NO
`iter_entries` call lives here.
"""
import hashlib
import os
from typing import Any, Dict, List, Sequence, Tuple

import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb
import zuvo_backlog_verdicts as zv

Row = Dict[str, Any]                 # a queue row, as in the siblings that say so of their own
SEEDS_PER_CHUNK = 4                  # K=4, 2 provably fixed and 2 provably still real
SEED_SECTION = "Open"                # a seed's `section`, and it is a PLAUSIBLE one on purpose. The
                                     # first version put a literal "zuvo-seed" marker there — a field
                                     # of the DISPATCHED row — so `jq 'select(.section=="zuvo-seed")'`
                                     # named all four graded rows. Measured by the assertion that greps
                                     # the dispatch for a marker; the control it gates was a lookup.


def _candidates(root: str, rel: str, want: int) -> List[Tuple[str, int, str]]:
    """The first `want` quotable lines of ONE tracked file: at least four words, and no `"` or `|`.

    The two excluded characters are not fastidiousness — `|` is `normalize_signature`'s own field
    separator, and a quote inside the seed's prose would land inside the evidence clause a verifier
    quotes back, where it reads as the end of it.
    """
    try:
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    out = []
    for n, text in enumerate(lines, start=1):
        if len(text.split()) >= 4 and '"' not in text and "|" not in text:
            out.append((rel, n, text))
            if len(out) >= want:
                break
    return out


def live_anchors(root: str, want: int) -> List[Tuple[str, int, str]]:
    """(path, line, text) triples from the tree AS IT STANDS — the `STILL-REAL` half of the seeds.

    `git ls-files`, SORTED, so the same tree yields the same anchors on every run: a seed that moved
    between two dispatches would make a re-dispatch decision unreproducible, and (d) is the one control
    whose entire value is that a miss is attributable.

    TWO PASSES, one line per file and then a second, because one-per-file alone made the seed count a
    function of how many tracked `.py`/`.sh`/`.md` files a repo has. Measured on a 2-file fixture: it
    derived ONE live anchor, the dispatch refused on the shortfall, and the refusal was about the
    fixture's size rather than about anything the control cares about. Diversity still comes first — a
    second line of the same file is only reached when the tree cannot spread them.
    """
    files = [rel for rel in sorted((zb.sh(["git", "ls-files"], cwd=root) or "").split("\n"))
             if rel and rel.endswith((".py", ".sh", ".md"))]
    out: List[Tuple[str, int, str]] = []
    for depth in (1, 2):
        for rel in files:
            got = _candidates(root, rel, depth)
            if len(got) >= depth:
                out.append(got[depth - 1])
            if len(out) >= want:
                return out
    return out


def interleave(rows: Sequence[Row], salt: str) -> List[Row]:
    """The dispatch order: a STABLE hash of (salt, key), so the seeds sit among the real rows.

    Deterministic, because two dispatches of one chunk have to be the same dispatch; and not the key's
    own order, because `fp:ffff…` sorts after every real `fp:` key and would park all four seeds in one
    block at the end of the file.
    """
    def rank(row: Row) -> str:
        key = str((row.get("keys") or [row.get("id", "")])[0])
        return hashlib.sha1((salt + "|" + key).encode("utf-8")).hexdigest()
    return sorted(rows, key=rank)


def seed_row(key: str, body: str, section: str) -> Row:
    """One seed, shaped EXACTLY like a queue row — `mark`/`expect` live in the answer key, never here.
    A dispatched row a model can tell is a seed gates nothing; it becomes a lookup."""
    return {"id": key, "keys": [key], "text_sha": zl.text_sha(body),
            "raw_text": body if body.endswith("\n") else body + "\n",
            "section": section, "cited_paths": zv.cited_paths(body),
            "kind": zb.KIND_CHECKBOX, "lineno": 0, "end_lineno": 0,
            "bytes": len(body.encode("utf-8")), "chunk": None, "reused": False,
            "verdict": None, "evidence": None, "verified_by": None}


def seed_key(chunk: int, n: int) -> str:
    """A seed's key. `fp:` shaped so `_KEY_RE` accepts it if one ever reached `validate_row`, and
    prefixed `ffff` so no real `sha1[:12]` can collide with it — a seed colliding with a real entry
    would put a synthetic verdict on a real row."""
    return "fp:ffff%08x" % ((chunk << 8) | (n & 0xFF))


def build_seeds(chunk: int, closed: Sequence[str], live: Sequence[Tuple[str, int, str]],
                k: int = SEEDS_PER_CHUNK,
                section: str = SEED_SECTION) -> Tuple[List[Row], Dict[str, str], str]:
    """(seed rows, key -> expected verdict, a SHORTFALL message — "" when the chunk is fully seeded).

    The shortfall is a plain STRING and not this family's `Reject`, which is what keeps this module out
    of an import cycle with `zuvo_backlog_agent`: that one checks the ANSWERS at ingest and owns the
    rejection vocabulary, this one builds the rows at dispatch. The caller wraps the message.

    Half `STALE-FIXED`, half `STILL-REAL`, both derived from what this repo RECORDS rather than from a
    hand-written fixture:

      * `closed` — entry texts the archive already holds, with their resolution markers STRIPPED. The
        closure is provable (it is in `backlog-done.md`); stripping the marker is what stops the answer
        being legible from the seed's own text, which would make (d) a reading test.
      * `live` — (path, line, text) triples from the tree as it stands, phrased as an entry about that
        line. Provably still real, because the line is there.

    A SHORTFALL IS A REFUSAL, not a smaller K. A chunk dispatched with no seeds is an UNGATED chunk,
    and it looks exactly like a gated one in every report — the one failure this control cannot
    survive. A repo with no recorded closures therefore cannot self-seed and must be given `--seeds`.
    """
    want = k // 2
    rows: List[Row] = []
    answers: Dict[str, str] = {}
    for i, body in enumerate(list(closed)[:want]):
        key = seed_key(chunk, i)
        rows.append(seed_row(key, zb.strip_resolution_markers(body), section))
        answers[key] = zl.VERDICT_STALE_FIXED
    for j, (path, line, text) in enumerate(list(live)[:k - want]):
        key = seed_key(chunk, want + j)
        body = "%s:%d still reads %s" % (path, line, " ".join(text.split()[:8]))
        rows.append(seed_row(key, body, section))
        answers[key] = zl.VERDICT_STILL_REAL
    short = "" if len(rows) == k else (
        "chunk %d: only %d of %d seed(s) could be derived (%d closed, %d live) — a chunk with fewer "
        "seeds is an UNGATED chunk and reads identically to a gated one"
        % (chunk, len(rows), k, min(len(closed), want), min(len(live), k - want)))
    return rows, answers, short
