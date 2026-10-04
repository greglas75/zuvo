"""CONTROL (c): does a verdict's evidence overlap the ENTRY'S OWN WORDS, or merely exist?

Its own module at last. It started in `zuvo_backlog_agent.py`, moved into `zuvo_backlog_verdicts.py`
when that file hit 430 lines — because the rejection vocabulary it returns lived in the module that
imports it, which is a cycle and not a layering preference — and lands here now that
`zuvo_backlog_reject.py` holds that vocabulary: nothing is left forcing it to share a file with the
verdict classifier it calls.

WHAT (c) CAN AND CANNOT ASSERT, repeated here because the include says it too and a report that implies
otherwise is the failure this control is most likely to produce: it catches FABRICATION, not
MISJUDGEMENT. Citing the very line the entry names satisfies (c) while the verdict is still wrong.

THE WORD SET IS A MEASURED CORRECTION. The first version asked `word in haystack`, a SUBSTRING test, and
`normalize_signature` tokenises on `[a-z0-9]+` — so `"on"` is inside `function`, `"is"` inside `exists`,
`"a"` inside everything, and a window of ordinary TypeScript scored 2 hits for an entry it had nothing
to do with. Tokenising BOTH sides is what makes ">=2 of 8 content words" mean what it says.

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


def check_overlap(row: zrj.Row, rec: zrj.Row, tree: zv.Tree) -> Tuple[str, List[zrj.Reject]]:
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
    if len(words) < zrj.MIN_WORDS:
        return "n/a:signature-too-short", []
    locs = zl.evidence_locations(str(rec.get("evidence", "")))
    if not locs:
        return "n/a:no-citation", [zrj.Reject(zrj.R_OVERLAP, subject,
                                          "a %s row owes a `path:line` its signature can be checked "
                                          "against" % rec.get("verdict"))]
    cited, line = locs[0]
    archive_proof = (str(rec.get("verdict", "")) == zl.VERDICT_STALE_FIXED
                     and os.path.basename(cited) == tree.done_name)
    mode = "archive-proof" if archive_proof else ("full" if base else "words-only")
    if base and not archive_proof and os.path.basename(cited).lower() != base:
        return mode, [zrj.Reject(zrj.R_OVERLAP, subject,
                             "cites %s but the entry's signature names %s — the basenames differ, so "
                             "the citation is not about this entry" % (cited, base))]
    target = zv.resolve_cited(cited, tree)
    hay = window_words(target, line) if target else set()
    hits = sorted(set(words) & hay)
    if len(hits) < zrj.MIN_WORDS:
        return mode, [zrj.Reject(zrj.R_OVERLAP, subject,
                            "%d of %d signature word(s) within +/-%d lines of %s:%d (%s) — below the "
                            "%d required" % (len(hits), len(words), zrj.WINDOW, cited, line,
                                             ",".join(hits) or "none", zrj.MIN_WORDS))]
    return mode, []
