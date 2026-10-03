"""THE VERIFIER LANE: what a model is handed, what it must hand back, and the four mechanical controls
that decide whether any of it reaches the ledger. Imported by backlog-groom.py; not a script, no
shebang, no executable bit.

THE TRUTH OF A VERDICT CANNOT BE TESTED. This module is what stands in for that, and the honest
statement of what each control buys is the product here — a control reported as stronger than it is
costs more than no control, because it retires the suspicion that would have caught the rest.

  (a) SHAPE. The verdict is one of the closed five, the evidence is exactly ONE line, and the whole row
      passes `zuvo_backlog_ledger.validate_row` — the same validator the reader uses, never a second
      copy of it. `STILL-REAL` with no `path:line` is INVALID, not weak.
  (b) RESOLVABILITY. Every `path:line` in the evidence names a file that exists and has at least that
      many lines. SKIPPED for `NOT-VERIFIABLE`, deliberately: see the incentive note below.
  (c) KEYWORD OVERLAP. Re-read the cited line ±5 and require the entry's own signature to show up
      there. **IT CATCHES FABRICATION, NOT MISJUDGEMENT** — citing the very line the entry names
      satisfies (c) while the verdict is still wrong. That sentence is in
      `shared/includes/backlog-grooming.md` verbatim and it is not a hedge.
  (d) SEEDED KNOWN-ANSWERS. K rows per chunk whose answer the repo already records, indistinguishable
      from the real ones in the dispatch. Only (d) measures judgement, and a miss in EITHER direction
      re-dispatches the whole chunk.

WHY (c) DEGRADES INSTEAD OF REJECTING, measured on this repo's 494 entries rather than assumed. Only
**156** of them have a path token in `normalize_signature`, so basename equality is unavailable for the
other 338 — applying it as a hard requirement would reject two rows in three on shape alone, and the
verifier would learn to cite a path the entry never named. And **20** entries have FEWER THAN 2 content
words in their signature, so "≥2 of 8" is unsatisfiable for them by construction. So (c) has three
recorded modes (`full`, `words-only`, `n/a:<reason>`), every row's mode is printed, and a report that
quotes a (c) pass rate without its mode split is quoting a number about a different control.

WHAT (c) STILL CANNOT DO AFTER THAT FIX, so nothing here reads stronger than it is. The bar is ">=2 of
8 content words", and `normalize_signature` does not drop stop-words: `the`, `is`, `no`, `on` count. A
window of ordinary prose about almost anything will therefore contain two of them. (c) is a check that
the citation lands somewhere plausibly ABOUT the entry — it is not a similarity score, and raising the
threshold is a change to the plan's own number rather than a tidy-up.

NOT-VERIFIABLE IS CHEAP ON PURPOSE, and it is cheap in the CODE, not only in the agent's prose. It owes
(a) — a reason, one line — and it owes neither (b) nor (c). A verifier that had to produce a resolvable
citation for "the repo does not answer this" would produce a resolvable citation for something, and the
cheapest resolvable citation is a guessed `STILL-REAL`: an entry kept alive for ever, with evidence that
resolves, and nothing in the ledger to show anybody ever looked.

NOTHING PARTIAL IS EVER APPENDED. `ingest` returns ledger rows only when the rejection list is EMPTY —
not "the rows that passed". A response that fails conservation is a response about a set nobody can
reconcile with the dispatch, and appending its clean half would record judgements next to an unexplained
hole. That is why `Result.rows` is empty whenever `Result.rejects` is not, and why the caller asserts the
ledger's byte count rather than the absence of a particular row.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, exactly as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. `sys.path` is the
IMPORTER's job. By importing the parser this module joins the pin-guard family that
`tests/hooks/test-backlog-headings.sh` (H19c) DERIVES, where its expectation is the default one: NO
`iter_entries` call lives here. This module never reads `backlog.md` — it reads the QUEUE the pre-pass
wrote, which is what keeps "what was dispatched" auditable instead of re-derived.
"""
import json
import os
from typing import Any, Dict, List, NamedTuple, Sequence, Set, Tuple

import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb
import zuvo_backlog_verdicts as zv

Row = Dict[str, Any]                 # a queue row; typing it tighter would be fiction, as in the
                                     # siblings that say so of their own
LANE = "agent:backlog-verifier"      # `_BY_RE`'s `agent:<lane>` half — the provenance the cross-model
                                     # spot check selects on
WINDOW = 5                           # control (c)'s ±5 lines. An exact-line assert would reject
                                     # CORRECT evidence: a fabricated number is usually close, and a
                                     # true one drifts by an edit above it
MIN_WORDS = 2                        # ≥2 of the signature's 8 content words

# The rejection vocabulary, closed, because a caller greps for these. A free-form reason string makes
# "which control refused this chunk" unanswerable, which is the question a re-dispatch decision asks.
R_COUNT = "COUNT"
R_KEYSET = "KEYSET"
R_MULTIPLICITY = "MULTIPLICITY"
R_UNKNOWN = "UNKNOWN-KEY"
R_SHAPE = "SHAPE"
R_UNRESOLVABLE = "UNRESOLVABLE"
R_OVERLAP = "OVERLAP"
R_SEED = "SEED-MISS"
R_AMBIGUOUS = "DISPATCH-AMBIGUOUS"
R_SEED_SHORT = "SEED-SHORTFALL"
REJECTS: Tuple[str, ...] = (R_COUNT, R_KEYSET, R_MULTIPLICITY, R_UNKNOWN, R_SHAPE, R_UNRESOLVABLE,
                            R_OVERLAP, R_SEED, R_AMBIGUOUS, R_SEED_SHORT)


class Reject(NamedTuple):
    """One refusal, naming the SUBJECT it is about. `subject` is an entry id or a seed key, never a
    row index: a reader has to be able to find the offending row in a 25 KB dispatch."""

    code: str
    subject: str
    why: str

    def __str__(self) -> str:
        return "%s %s: %s" % (self.code, self.subject, self.why)


class Result(NamedTuple):
    """`rows` is EMPTY whenever `rejects` is not — see the module docstring. `controls` records the
    per-row (c) mode so the pass rate can never be quoted without its denominator."""

    rows: List[Row]
    rejects: List[Reject]
    controls: List[str]


def read_jsonl(path: str) -> Tuple[List[Row], List[str]]:
    """(rows, defects) over a JSONL file, FAIL-CLOSED in the ledger's own direction.

    A missing terminator on the final line is a defect rather than a tolerated row, for the reason
    `zuvo_backlog_ledger.read_ledger` gives: every write here ends in "\\n", so its absence means the
    last write did not complete, and a truncation that lands on a syntactically complete prefix would
    otherwise read as a record somebody produced.
    """
    if not os.path.isfile(path):
        return [], ["%s: no such file" % os.path.basename(path)]
    with open(path, "rb") as fh:
        raw = fh.read()
    if not raw:
        return [], []
    text = raw.decode("utf-8", errors="replace")
    lines = text.split("\n")
    terminated = text.endswith("\n")
    if terminated:
        lines.pop()
    rows: List[Row] = []
    defects: List[str] = []
    base = os.path.basename(path)
    for i, line in enumerate(lines, start=1):
        if not line.strip():
            continue
        if not terminated and i == len(lines):
            defects.append("%s:%d: final line is not newline-terminated — a truncated write reads as "
                           "NO RECORD, never as a verdict" % (base, i))
            continue
        try:
            obj = json.loads(line)
        except ValueError as exc:
            defects.append("%s:%d: unparseable JSON (%s)" % (base, i, exc))
            continue
        if not isinstance(obj, dict):
            defects.append("%s:%d: not a JSON object" % (base, i))
            continue
        rows.append(obj)
    return rows, defects


def write_jsonl(path: str, rows: Sequence[Row]) -> None:
    """One JSON object per line, newline-terminated — the same shape as the queue and the ledger, so a
    truncated final line is detectable by the missing terminator rather than by a parse error."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, sort_keys=True, ensure_ascii=False) + "\n")


def key_index(rows: Sequence[Row]) -> Tuple[Dict[str, int], List[Reject]]:
    """key -> row index, plus a refusal for every key TWO dispatched rows answer to.

    MEASURED: 0 collisions in today's 414-row dispatch, because the deterministic duplicate class
    already gave every colliding entry a verdict and `assign_chunks` skips a row that carries one. That
    is a property of the pre-pass, not a law — a duplicate row whose evidence was REFUSED as
    unresolvable carries no verdict and would arrive here beside its twin. Then "one record per row"
    has no answer, so the dispatch is refused BEFORE a model is paid for it rather than after.
    """
    at: Dict[str, int] = {}
    bad: List[Reject] = []
    for i, row in enumerate(rows):
        for key in row.get("keys", []) or []:
            other = at.get(str(key))
            if other is not None:
                bad.append(Reject(R_AMBIGUOUS, str(row.get("id", "?")),
                                  "key %s is also row %d (%s) — two rows answering to one key leave "
                                  "'exactly one record per row' undecidable"
                                  % (key, other, rows[other].get("id", "?"))))
                continue
            at[str(key)] = i
    return at, bad


def conserve(rows: Sequence[Row], records: Sequence[Row]) -> List[Reject]:
    """Conservation, THREE ways, and every one of them reported — never short-circuited.

    1. COUNT — `len(records) == len(rows)`.
    2. KEYSET — every dispatched row is answered and no answer names a key nobody dispatched.
    3. MULTIPLICITY — `len(set(keys_returned)) == len(rows)`, which is what catches a MERGED PAIR: a
       response that answers one row twice and another not at all has the right COUNT.

    Honest note, because the include says it too: 3 cannot fail while 1 and 2 both hold — if all N
    dispatched keys appear among N records, no key can appear twice. It is run and reported separately
    because it names the MULTIPLICITY (which id was answered twice) where 2 names the ABSENCE, and a
    caller deciding whether to re-dispatch needs both. Reporting 3 as an independent guarantee would be
    the overstatement this module exists to avoid.
    """
    at, out = key_index(rows)
    if out:
        return out
    returned = [str(r.get("key", "")) for r in records]
    if len(records) != len(rows):
        out.append(Reject(R_COUNT, "<response>",
                          "%d record(s) for %d dispatched row(s)" % (len(records), len(rows))))
    unknown = [k for k in returned if k not in at]
    for k in sorted(set(unknown)):
        out.append(Reject(R_UNKNOWN, k or "<empty>",
                          "no dispatched row answers to this key"))
    covered = {at[k] for k in returned if k in at}
    for i in sorted(set(range(len(rows))) - covered):
        out.append(Reject(R_KEYSET, str(rows[i].get("id", "?")),
                          "dispatched but not answered — a missing row is an agent FAILURE, never an "
                          "implicit verdict"))
    if len(set(returned)) != len(rows):
        seen: Dict[str, int] = {}
        for k in returned:
            seen[k] = seen.get(k, 0) + 1
        twice = sorted(k for k, n in seen.items() if n > 1)
        out.append(Reject(R_MULTIPLICITY, ",".join(twice) or "<response>",
                          "%d distinct key(s) across %d record(s) for %d row(s) — a merged pair has "
                          "the right COUNT" % (len(set(returned)), len(records), len(rows))))
    return out


def ledger_row(row: Row, rec: Row, stamp: str, lane: str = LANE) -> Row:
    """The ledger row a record becomes. `id`, `keys` and `text_sha` come from the DISPATCH, never from
    the record: a verdict is about the text that was verified, and letting the responder restate the
    text's own sha would make staleness a claim rather than a measurement."""
    return {"id": row.get("id"),
            "keys": sorted(str(k) for k in row.get("keys", []) or []),
            "text_sha": row.get("text_sha"),
            "verdict": str(rec.get("verdict", "")),
            "evidence": str(rec.get("evidence", "")),
            "verified_at": stamp,
            "verified_by": lane,
            "disposition": "pending"}


def check_shape(row: Row, rec: Row, stamp: str, lane: str = LANE) -> List[Reject]:
    """Control (a): the closed vocabulary, ONE evidence line, and the ledger's own validator.

    `validate_row` is reused rather than re-implemented — a second copy of the schema is the drift the
    ledger module's docstring warns about, and this is the caller whose rows it would drift from.
    """
    subject = str(row.get("id", "?"))
    out: List[Reject] = []
    ev = rec.get("evidence")
    if isinstance(ev, str) and ("\n" in ev or "\r" in ev):
        out.append(Reject(R_SHAPE, subject,
                          "the evidence spans %d lines; exactly one is the contract, and a second "
                          "line is where a second, unchecked citation hides" % len(ev.splitlines())))
    problems = zl.validate_row(ledger_row(row, rec, stamp, lane), subject)
    for p in problems:
        out.append(Reject(R_SHAPE, subject, p.split(": ", 1)[-1]))
    return out


def check_resolvable(row: Row, rec: Row, tree: zv.Tree) -> List[Reject]:
    """Control (b), SKIPPED for `NOT-VERIFIABLE` — the one exemption, and the reason it exists is in
    the module docstring: a citation requirement on "the repo does not answer" is an incentive to
    answer something else."""
    if str(rec.get("verdict", "")) == zl.VERDICT_NOT_VERIFIABLE:
        return []
    bad = zv.unresolvable(str(rec.get("evidence", "")), tree)
    if not bad:
        return []
    return [Reject(R_UNRESOLVABLE, str(row.get("id", "?")), "; ".join(bad))]


def signature_parts(text: str) -> Tuple[str, List[str]]:
    """(`normalize_signature`'s basename, its content words) — parsed from the signature itself and
    never re-derived, so control (c) keys on the SAME window `entry_key` hashes. An empty basename is
    the no-path-token case, which is 338 of this repo's 494 entries."""
    sig = zb.normalize_signature(text)
    base, _, words = sig.partition("|")
    return base, words.split()


def window_words(path: str, line: int, span: int = WINDOW) -> Set[str]:
    """The WORDS in the cited line ±`span`, tokenised by the parser's own `_WORD_RE`, or an empty set
    when the file cannot be read (an unreadable file is control (b)'s refusal, not this one's, so this
    does not decide it twice).

    A SET OF WORDS, never the joined text, and this is a measured correction rather than a style
    choice. The first version asked `word in haystack`, a SUBSTRING test — and `normalize_signature`
    tokenises on `[a-z0-9]+`, so signature words of two or three letters are routine. `"on"` is inside
    `function`, `"is"` is inside `exists`, `"a"` is inside everything: a window of ordinary TypeScript
    scored 2 hits for an entry it had nothing to do with, and control (c) passed a citation it exists to
    reject. Tokenising both sides is what makes ">=2 of 8 content words" mean what it says.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return set()
    all_lines = text.splitlines()
    lo = max(0, line - 1 - span)
    return set(zb._WORD_RE.findall(" ".join(all_lines[lo:line + span]).lower()))


def check_overlap(row: Row, rec: Row, tree: zv.Tree) -> Tuple[str, List[Reject]]:
    """Control (c): (the MODE this row was checked in, refusals).

    Scoped to the two verdicts that cite a PRODUCTION path — `STALE-OBSOLETE` cites a *backlog* line by
    construction, so its basename can never equal the missing path's and (c) would reject every correct
    row, and `NOT-VERIFIABLE` owes no citation at all. FOUR modes, and the mode travels with the row
    because a (c) pass rate quoted without the split is a number about a different control:

      `full`         — basename equality AND >=2 of the 8 signature words in the +/-5 window.
      `words-only`   — the entry's signature has no path token (338 of this repo's 494 entries), so only
                       the words half can be asked. Requiring a basename the entry never named would
                       teach the verifier to invent one.
      `archive-proof`— a `STALE-FIXED` row citing `backlog-done.md`, which the include's evidence-shape
                       table explicitly permits as the second shape for that verdict. The first version
                       of this function applied basename equality to it and rejected every such row,
                       contradicting the shipped include; the plan's own wording ("scoped to the
                       verdicts that cite a production path") named the SCOPE by verdict and the REASON
                       by citation, and the reason is the one that decides. The words half still runs,
                       against the ARCHIVE's window, so the cited archive line is shown to be about
                       THIS entry rather than merely to exist.
      `n/a:...`      — out of scope, or the signature has fewer than 2 content words (20 of 494), which
                       makes ">=2 of 8" unsatisfiable rather than failed.

    A `STILL-REAL` row citing the archive is NOT this case and stays a basename rejection: the verdict
    means the defect is in the tree today, so the archive cannot be what shows it.
    """
    subject = str(row.get("id", "?"))
    if str(rec.get("verdict", "")) not in (zl.VERDICT_STILL_REAL, zl.VERDICT_STALE_FIXED):
        return "n/a:out-of-scope", []
    base, words = signature_parts(str(row.get("raw_text", "")))
    if len(words) < MIN_WORDS:
        return "n/a:signature-too-short", []
    locs = zl.evidence_locations(str(rec.get("evidence", "")))
    if not locs:
        return "n/a:no-citation", [Reject(R_OVERLAP, subject,
                                          "a %s row owes a `path:line` its signature can be checked "
                                          "against" % rec.get("verdict"))]
    cited, line = locs[0]
    archive_proof = (str(rec.get("verdict", "")) == zl.VERDICT_STALE_FIXED
                     and os.path.basename(cited) == tree.done_name)
    mode = "archive-proof" if archive_proof else ("full" if base else "words-only")
    if base and not archive_proof and os.path.basename(cited).lower() != base:
        return mode, [Reject(R_OVERLAP, subject,
                             "cites %s but the entry's signature names %s — the basenames differ, so "
                             "the citation is not about this entry" % (cited, base))]
    target = zv.resolve_cited(cited, tree)
    hay = window_words(target, line) if target else set()
    hits = sorted(set(words) & hay)
    if len(hits) < MIN_WORDS:
        return mode, [Reject(R_OVERLAP, subject,
                            "%d of %d signature word(s) within +/-%d lines of %s:%d (%s) — below the "
                            "%d required" % (len(hits), len(words), WINDOW, cited, line,
                                             ",".join(hits) or "none", MIN_WORDS))]
    return mode, []


def check_seeds(answers: Dict[str, str], records: Sequence[Row]) -> List[Reject]:
    """Control (d): a miss in EITHER direction. A seed answered `STILL-REAL` when the repo records the
    fix is the direction that keeps dead entries alive; the reverse closes live ones. Both re-dispatch
    the chunk, and neither is averaged away against the rows that were right."""
    got = {str(r.get("key", "")): str(r.get("verdict", "")) for r in records}
    out: List[Reject] = []
    for key in sorted(answers):
        if key not in got:
            out.append(Reject(R_SEED, key, "seeded row not answered at all"))
        elif got[key] != answers[key]:
            out.append(Reject(R_SEED, key, "answered %s where the repo records %s"
                              % (got[key] or "<empty>", answers[key])))
    return out


def ingest(rows: Sequence[Row], records: Sequence[Row], answers: Dict[str, str],
           tree: zv.Tree, lane: str = LANE) -> Result:
    """The whole pipeline over ONE chunk's response: conservation, then (a)-(d), then the ledger rows —
    and ONLY when nothing refused. See the module docstring for why the clean half is not appended.

    Seed rows are checked like every other row and then DROPPED: they are not entries, so a ledger row
    for one would be a verdict about a text `backlog.md` does not contain.
    """
    rejects = list(conserve(rows, records))
    rejects.extend(check_seeds(answers, records))
    at, _ = key_index(rows)
    stamp = zl.now_stamp()
    keep: List[Row] = []
    controls: List[str] = []
    for rec in records:
        row = rows[at[str(rec.get("key", ""))]] if str(rec.get("key", "")) in at else None
        if row is None:
            continue
        rejects.extend(check_shape(row, rec, stamp, lane))
        rejects.extend(check_resolvable(row, rec, tree))
        mode, over = check_overlap(row, rec, tree)
        rejects.extend(over)
        controls.append("%s %s c=%s" % (row.get("id"), rec.get("verdict"), mode))
        if str(rec.get("key", "")) not in answers:
            keep.append(ledger_row(row, rec, stamp, lane))
    return Result([] if rejects else keep, rejects, controls)
