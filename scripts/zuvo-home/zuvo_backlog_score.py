"""THE READING ORDER: how a verified entry is scored, which theme it belongs to, and what command
that theme licenses. Imported by zuvo_backlog_render.py; not a script, no shebang, no executable
bit.

THE SCORES ARE DERIVED, NOT JUDGED, and the document this feeds says so on its own face.
`skills/backlog/SKILL.md`'s `prioritize` asks a HUMAN for Impact, Risk and Effort on a 1/3/5 scale
and multiplies `(Impact + Risk) x (6 - Effort)`, giving 2 at the bottom and 50 at the top. A
renderer cannot ask anyone, so it uses three proxies — the declared severity word, a small named
risk vocabulary, and the entry's block size — and reuses the formula and the range UNCHANGED. Two
scoring scales for one backlog is the drift this module exists to prevent; a derived score
presented as a judged one is the failure mode `RANK_CAVEAT` exists to prevent, and that caveat is
emitted INTO the document rather than kept in a docstring nobody renders.

WHY ITS OWN MODULE, and the number is the argument rather than the taste. `zuvo_backlog_render.py`
measured **474 raw lines** with the scoring and the clustering inlined, against
`rules/file-limits.md`'s 400-line default for a Python module (800 is the automatic CQ11 FAIL) —
the same ceiling that already moved the block boundary, the heading policy and the mint out of
`backlog-archive.py`, the mint pre-pass and the dispositions out of `backlog-groom.py`, and the
read model into `zuvo_backlog_load.py`. Trimming the prose to fit was the alternative and it is the
wrong one: every paragraph here is a measurement or a decision someone paid for. It is also ONE
cohesive concern — in what ORDER a reader should look at the entries, and which of them belong
together — kept apart from the markdown that presents it.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, exactly as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package
around them and a plain same-directory import resolves identically in both layouts. `sys.path` is
the IMPORTER's job. By importing the parser this module joins the pin-guard family that
`tests/hooks/test-backlog-headings.sh` (H19c) DERIVES, where its expectation is the default one: NO
`iter_entries` call lives here — reading and parsing the two files is backlog-groom.py's job.
"""
import collections
import os
import re
from typing import Dict, List, NamedTuple, Sequence, Tuple

import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb
import zuvo_backlog_verdicts as zv
from zuvo_backlog_block import entry_block

# `prioritize`'s own bounds, restated so a test can assert the formula never leaves them.
SCORE_MIN, SCORE_MAX = 2, 50

# Impact from the DECLARED severity word, through `parse_backlog`'s own normalisation
# (warning -> medium, info -> low) so the renderer and the fleet collector band an entry alike. A
# missing severity bands as 3 — neither the top nor the bottom — because an entry nobody graded is
# not evidence of LOW impact, and most of this repo's entries carry no severity word at all.
SEV_IMPACT: Dict[str, int] = {"critical": 5, "high": 5, "medium": 3, "low": 1, "": 3}

# Risk 5 when the entry's own words name a consequence that is not merely slow work. Deliberately a
# SMALL, auditable vocabulary: a long one reads as a classifier and would invite a reader to trust
# it as judgement, which is exactly what RANK_CAVEAT says it is not.
RISK_RE = re.compile(r"\b(?:security|secret|credential|token|data[- ]loss|corrupt|leak|race|"
                     r"deadlock|crash|outage|regression|destructive|silently)\b", re.I)

# Effort from BLOCK BYTES — the one size signal the file actually carries, via PR 1's `entry_block`.
# Bands and not a formula, so the number is reproducible and obviously coarse. A small block means
# low effort means a HIGH score, which is the direction `(6 - Effort)` already encodes.
EFFORT_BANDS: Tuple[Tuple[int, int], ...] = ((500, 1), (2000, 2), (5000, 3), (12000, 4))

RANK_CAVEAT = (
    "Impact, Risk and Effort are **derived from the bytes**, never judged: Impact comes from the "
    "entry's declared severity word, Risk from a small named vocabulary in its own text, Effort "
    "from its block size. The formula and the 2-50 range are `zuvo:backlog prioritize`'s, "
    "unchanged. A derived score is a reading order, not an assessment.")


class Scored(NamedTuple):
    """One verified entry with its derived score. `row` is the ledger row that verified it, so the
    verdict, the evidence and the disposition in the document all come from ONE record rather than
    from three lookups that can disagree."""

    entry: zb.Entry
    row: zl.Row
    impact: int
    risk: int
    effort: int

    @property
    def score(self) -> int:
        """`prioritize`'s formula verbatim."""
        return (self.impact + self.risk) * (6 - self.effort)

    @property
    def subject(self) -> str:
        """The same identity `coverage` names a shortfall by, so a rendered row and a refusal line
        are about comparably-named things."""
        return self.entry.ident or self.entry.key

    @property
    def verdict(self) -> str:
        return str(self.row.get("verdict", ""))

    @property
    def disposition(self) -> str:
        """`pending` when the row carries none — the ledger's own default, not a guess: `verify`
        writes no disposition and `groom` writes all of them."""
        return str(self.row.get("disposition", "pending"))


def effort_of(size: int) -> int:
    """The effort band for a block of `size` bytes; 5 above the last band."""
    for limit, band in EFFORT_BANDS:
        if size < limit:
            return band
    return 5


def severity_of(body: str) -> str:
    """The entry's declared severity, normalised EXACTLY as `parse_backlog` normalises it, so the
    band a renderer gives an entry and the band the fleet index records cannot drift."""
    m = zb.SEV_RE.search(body)
    sev = m.group(1).lower() if m else ""
    return {"warning": "medium", "info": "low"}.get(sev, sev)


def score_entries(lines: List[str], pairs: Sequence[Tuple[zb.Entry, zl.Row]]) -> List[Scored]:
    """Score every (entry, row) pair.

    The pairs come from `plan_reuse().reuse`, so a scored entry is one with a `text_sha`-EXACT
    verdict — never one whose text moved after it was verified. That is the same set `coverage`
    counts, which is what keeps "every entry is verified" and "every entry is rendered" from
    disagreeing about which rows are current.
    """
    out: List[Scored] = []
    for entry, row in pairs:
        impact = SEV_IMPACT.get(severity_of(entry.body), 3)
        end = entry_block(lines, entry.lineno - 1)
        size = sum(len(ln.encode("utf-8")) for ln in lines[entry.lineno - 1:end])
        out.append(Scored(entry, row, impact,
                          5 if RISK_RE.search(entry.body) else impact, effort_of(size)))
    return out


def cluster_of(entry: zb.Entry) -> str:
    """The entry's theme: the DIRECTORY of the first repo-relative path it cites, else its nearest
    enclosing section heading, else `unclustered`.

    The path's directory and not the path itself, because a cluster of one file is a list and not a
    theme; `zv.cited_paths` already requires a `/`, so that directory is never empty. The section
    fallback is what the FILE itself says the entry is about, which beats inventing a taxonomy the
    backlog does not have — and `zv.cited_paths` is reused rather than re-implemented because every
    restriction in its regex is a measured false positive (see that module's docstring).
    """
    paths = zv.cited_paths(entry.body)
    if paths:
        return os.path.dirname(paths[0]) or paths[0]
    return (entry.section or "unclustered").strip() or "unclustered"


def dominant(verdicts: Sequence[str]) -> str:
    """The cluster's commonest verdict, ties broken by the CLOSED vocabulary's own order.

    Not `Counter.most_common()[0]`: on a tie that returns insertion order, which depends on the
    order the entries happened to be parsed in, so the same cluster would get two different
    suggestions on two runs over the same bytes.
    """
    counts = collections.Counter(verdicts)
    return max(zl.VERDICTS, key=lambda v: (counts.get(v, 0), -zl.VERDICTS.index(v)))


def suggestion(cluster: str, verdicts: Sequence[str], repo: str) -> str:
    """The batch command this cluster's dominant verdict licenses — and nothing stronger.

    A `STALE-*` cluster is closed by `apply`, which DELEGATES to `backlog-archive.py`; the document
    never suggests editing either file by hand, for the reason `backlog-protocol.md` records about
    the hand-written archive that copied the helper's heading format and counted LINES as items.
    `DUPLICATE-OF` gets no command at all, because it is a report and no helper can decide which of
    two texts survives.
    """
    dom = dominant(verdicts)
    groom = "python3 scripts/zuvo-home/backlog-groom.py"
    if dom in (zl.VERDICT_STALE_FIXED, zl.VERDICT_STALE_OBSOLETE):
        return "`%s apply --repo %s` — the closures are delegated to backlog-archive.py" % (
            groom, repo)
    if dom == zl.VERDICT_DUPLICATE_OF:
        return "no command: DUPLICATE-OF is a report, never a licence to merge — settle by hand"
    if dom == zl.VERDICT_NOT_VERIFIABLE:
        return "`%s plan --repo %s` then the verifier lane — these need a re-verify, not a fix" % (
            groom, repo)
    return "`zuvo:refactor %s` or `zuvo:backlog fix <id>` — these entries are still true" % cluster
