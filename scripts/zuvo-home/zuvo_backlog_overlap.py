"""CONTROL (c): does a verdict's evidence overlap the ENTRY'S OWN WORDS, or merely exist?

Its own module at last. It started in `zuvo_backlog_agent.py`, moved into `zuvo_backlog_verdicts.py`
when that file hit 430 lines — because the rejection vocabulary it returns lived in the module that
imports it, which is a cycle and not a layering preference — and lands here now that
`zuvo_backlog_reject.py` holds that vocabulary: nothing is left forcing it to share a file with the
verdict classifier it calls.

WHAT (c) CAN AND CANNOT ASSERT, repeated here because the include says it too and a report that implies
otherwise is the failure this control is most likely to produce: it catches FABRICATION, not
MISJUDGEMENT. Citing the very line the entry names satisfies (c) while the verdict is still wrong.

THE WORDS HALF DOES NOT REFUSE, AND THAT IS A MEASUREMENT RATHER THAN A SOFTENING. It used to reject a
row with fewer than 2 of the 8 signature words in the cited window. Scored against a labelled corpus
built from this repo's own two backlog files — 29 citations an entry makes of a `path:line` that
resolves (GENUINE: the line the entry itself points at) against 145 citations of the SAME file at a
line >100 away (FABRICATED: the basename half passes, so this is the only fabrication the words half
can still catch) — it does not separate them:

    window   AUC    perm p   best balanced accuracy   (0.500 = a coin flip)
    +/- 5    0.614   0.027   0.614 @ threshold 2      <- the setting that shipped
    +/-10    0.595   0.051   0.590 @ threshold 3
    +/-20    0.607   0.035   0.597 @ threshold 3
    +/-40    0.675   0.002   0.624 @ threshold 4

At its OWN best row — +/-5, >=2 words, exactly what shipped — it REFUSES 37.9% of genuine citations
while still ACCEPTING 39.3% of fabrications. There is a signal, barely (AUC stable at 0.604..0.617
across five fabrication draws, but p=0.051 at +/-10), and it is nowhere near a gate. No threshold
rescues it either: 6 of the 29 genuine citations score ZERO in their own window, so even ">=1 word"
refuses 20.7% of correct evidence. A check that throws away a third of true citations to catch a third
of invented ones is measuring the prose style of whoever wrote the entry, not fabrication — an entry
that DESCRIBES a defect shares few words with the code that proves it, which is normal writing rather
than a lie.

So the score is COMPUTED AND REPORTED: it travels in the mode string, where the include already
requires a (c) pass rate to be quoted with its split, and the refusals of (c) are the basename half
alone. `tests/lib/overlap-corpus.py` rebuilds the table on any repo; it reads the directory it is
given rather than jumping to the main checkout, so these numbers are this branch's own two backlogs.

WHAT CATCHES WITHIN-FILE FABRICATION NOW: nothing in (c), and the include says so. A citation of a file
the entry names, at a line that has nothing to do with it, passes (c) and is control (d)'s business —
the only control that measures judgement. Writing this down is the point; a half that refused a third
of honest rows was not catching it either, it was only reporting that it had.

THE WORD SET IS STILL TOKENISED ON BOTH SIDES, and that part was always a measured correction. The
first version asked `word in haystack`, a SUBSTRING test, and `normalize_signature` tokenises on
`[a-z0-9]+` — so `"on"` is inside `function`, `"is"` inside `exists`, `"a"` inside everything, and a
window of ordinary TypeScript scored 2 hits for an entry it had nothing to do with. Tokenising both
sides is what makes the reported `ov=k/n` mean what it says.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. By importing the parser
this module joins the H19c pin-guard family, where its expectation is the default one: NO
`iter_entries` call lives here.
"""
import os
from typing import List, Set, Tuple

import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb
import zuvo_backlog_reject as zrj
import zuvo_backlog_verdicts as zv

# --- CONTROL (c) -- moved from zuvo_backlog_agent.py for the 400-line reason zuvo_backlog_reject.py
# records, and the better home on its merits: every line calls this module's resolve_cited/zv.Tree.
def signature_parts(text: str) -> Tuple[str, List[str]]:
    """(`normalize_signature`'s basename, its content words) — parsed from the signature itself and
    never re-derived, so control (c) keys on the SAME window `entry_key` hashes. An empty basename is
    the no-path-token case, which is 338 of this repo's 494 entries."""
    sig = zb.normalize_signature(text)
    base, _, words = sig.partition("|")
    return base, words.split()


def window_words(path: str, line: int, span: int = zrj.WINDOW) -> Set[str]:
    """The WORDS in the cited line ±`span`, tokenised by the parser's own `_WORD_RE`, or an empty set
    when the file cannot be read (an unreadable file is control (b)'s refusal, not this one's, so this
    does not decide it twice).

    A SET OF WORDS, never the joined text, and this is a measured correction rather than a style
    choice. The first version asked `word in haystack`, a SUBSTRING test — and `normalize_signature`
    tokenises on `[a-z0-9]+`, so signature words of two or three letters are routine. `"on"` is inside
    `function`, `"is"` is inside `exists`, `"a"` is inside everything: a window of ordinary TypeScript
    scored 2 hits for an entry it had nothing to do with. The score is REPORTED rather than enforced
    (see the module docstring for the corpus that decided that), and tokenising both sides is what
    keeps the reported `ov=k/n` honest instead of counting substrings.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return set()
    all_lines = text.splitlines()
    lo = max(0, line - 1 - span)
    return set(zb._WORD_RE.findall(" ".join(all_lines[lo:line + span]).lower()))


def check_overlap(row: zrj.Row, rec: zrj.Row, tree: zv.Tree) -> Tuple[str, List[zrj.Reject]]:
    """Control (c): (the MODE this row was checked in, refusals).

    Scoped to the two verdicts that cite a PRODUCTION path — `STALE-OBSOLETE` cites a *backlog* line by
    construction, so its basename can never equal the missing path's and (c) would reject every correct
    row, and `NOT-VERIFIABLE` owes no citation at all. FOUR modes, and the mode travels with the row
    because a (c) pass rate quoted without the split is a number about a different control:

      `full`              — the entry names at least one path, so the citation's basename is REQUIRED to
                            be one of them. 261 of this repo's 855 open entries (31%). This is the only
                            mode in which (c) refuses anything.
      `archive-proof`     — a `STALE-FIXED` row citing `backlog-done.md`, which the include's
                            evidence-shape table explicitly permits as the second shape for that
                            verdict. The first version of this function applied basename equality to it
                            and rejected every such row, contradicting the shipped include; the plan's
                            own wording ("scoped to the verdicts that cite a production path") named the
                            SCOPE by verdict and the REASON by citation, and the reason is the one that
                            decides.
      `n/a:no-path-named` — the entry names no path at all, 594 of 855 (69%), so there is no basename to
                            compare and (c) ASSERTS NOTHING about the row. It was called `words-only`
                            while the words half refused; keeping that name after the measurement in the
                            module docstring took the refusal away would describe a check that no longer
                            happens, and the mode string exists precisely so a (c) pass rate cannot be
                            quoted without its split.
      `n/a:out-of-scope`  — `STALE-OBSOLETE` cites a *backlog* line by construction, so its basename can
                            never equal the missing path's and (c) would reject every correct row;
                            `NOT-VERIFIABLE` owes no citation at all.

    EVERY MODE EXCEPT `n/a:out-of-scope` CARRIES ` ov=k/n` — the words-half score, k of the signature's
    n DISTINCT content words found inside the +/-WINDOW, or `ov=n/a` for a signature with fewer than 2
    of them (26 of 855), where a count is not informative. It is a diagnostic, never a refusal.

    THE SHORT SIGNATURE NO LONGER BUYS AN EXEMPTION FROM THE BASENAME HALF, and that is the one thing
    this change makes STRICTER. The old `n/a:signature-too-short` returned before the basename half ran,
    because ">=2 of 8" was unsatisfiable — but 21 of those 26 entries DO name a path, so a citation of
    an unrelated file passed unchecked for the entirely unrelated reason that the words half could not
    score it. Two halves with different inputs must not share one early return.

    A `STILL-REAL` row citing the archive is NOT `archive-proof` and stays a basename rejection: the
    verdict means the defect is in the tree today, so the archive cannot be what shows it.
    """
    subject = str(row.get("id", "?"))
    if str(rec.get("verdict", "")) not in (zl.VERDICT_STILL_REAL, zl.VERDICT_STALE_FIXED):
        return "n/a:out-of-scope", []
    base, words = signature_parts(str(row.get("raw_text", "")))
    locs = zl.evidence_locations(str(rec.get("evidence", "")))
    if not locs:
        return "n/a:no-citation", [zrj.Reject(zrj.R_OVERLAP, subject,
                                          "a %s row owes a `path:line` its signature can be checked "
                                          "against" % rec.get("verdict"))]
    cited, line = locs[0]
    archive_proof = (str(rec.get("verdict", "")) == zl.VERDICT_STALE_FIXED
                     and os.path.basename(cited) == tree.done_name)
    # THE BASENAMES THE ENTRY ITSELF NAMES, from `cited_paths` — not the signature's first token. Two
    # defects in one line, both measured on the first live run (chunk 0 of this repo's backlog, 21 of 25
    # rejections):
    #
    #   (1) `_PATH_RE` is `name.ext`-shaped, so in ordinary prose it matches `e.g`, `i.e`, `sys.argv`,
    #       `json.parse`, and `normalize_signature` puts that token in the signature as the basename.
    #       The control then refused a citation of a REAL file for "not matching" `e.g`. In 682 entries
    #       of English that happens constantly, so no chunk could ever pass.
    #   (2) an entry naming several files only accepted a citation of the FIRST — `cites tests/run-all.sh
    #       but the entry's signature names test-suite-e2e.sh`, where the entry names both.
    #
    # `cited_paths` has neither problem: it is empty for `e.g`/`sys.argv` and holds every path the entry
    # names. So the question becomes "does the citation name a file THIS ENTRY names", which is what the
    # control was always trying to ask. The fix is deliberately NOT a tighter `_PATH_RE`:
    # `normalize_signature` feeds `entry_key`, and tightening it rotates ~1250 fleet keys — attempted,
    # measured and reverted (B-20261005-BACKLOG-DUPLICATE-KEYS carries the numbers, H10 blocks it).
    # DERIVED FROM THE TEXT, never read from the row's `cited_paths` field. `queue_row` does set that
    # field, but a caller that omits it would silently switch the basename half OFF — a fail-OPEN in a
    # control, and the first version of this fix did exactly that: the probe builds its row without the
    # field, so Cc6 stopped rejecting a STILL-REAL row proving itself from the archive and the suite
    # caught it. A control may not depend on a field being remembered.
    named = {os.path.basename(p).lower()
             for p in zv.cited_paths(str(row.get("raw_text", ""))) if p}
    mode = "archive-proof" if archive_proof else ("full" if named else "n/a:no-path-named")
    # The words half, SCORED AND REPORTED. It runs in every mode — including the one where the basename
    # half has already refused, because a report that says WHY a row was refused is worth the two file
    # reads, and including `archive-proof`, where the window is the ARCHIVE's.
    target = zv.resolve_cited(cited, tree)
    hay = window_words(target, line) if target else set()
    uniq = set(words)
    hits = sorted(uniq & hay)
    # DISTINCT words in the denominator, because the numerator is a set intersection. With `len(words)`
    # there, an entry whose 8-word window repeats "the" could score at most 7/8 — a reported ratio that
    # can never reach its own maximum invites exactly the wrong reading of a diagnostic.
    scored = "%s ov=%s" % (mode, "%d/%d" % (len(hits), len(uniq)) if len(uniq) >= 2 else "n/a")
    if named and not archive_proof and os.path.basename(cited).lower() not in named:
        return scored, [zrj.Reject(zrj.R_OVERLAP, subject,
                             "cites %s but this entry names %s — the citation is not about this entry"
                             % (cited, ", ".join(sorted(named))))]
    return scored, []
