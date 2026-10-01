"""THE WORKING DOCUMENT: what a groomed backlog looks like when it is read rather than executed.
Imported by backlog-groom.py; not a script, no shebang, no executable bit.

WHY A SEPARATE DOCUMENT AT ALL, and what it is NOT. Decision 7 keeps ordering, grouping and
backfilled metadata OUT of `memory/backlog.md`: option A (re-emitting the tracked file in a new
order) has no oracle, and the per-entry `text_sha` this PR creates is the entry-level conservation
check a line-level one cannot express. So the sorting and grouping the user asked for ("sortowal,
grupowal") live HERE, in a regenerable report under `$ZUVO_DIR/reports/`, and the tracked file keeps
its original order. That is a deliberate trade, and decision 12 is what keeps it honest: the
document carries the source's sha256, so a reader can always tell whether it still describes the
file. `zuvo/` is gitignored, which decision 2 rejected for the LEDGER on durability grounds — 495
re-spent judgements per machine — and a rendered document is regenerable from the ledger in one
command, so the same tree is the right home for this and the wrong home for that. The difference is
deliberate, and this is where it is written down.

THE GATE IS DECISION 11's, and it is NOT the same refusal as `apply`'s. `apply` refuses because a
closure is irreversible; `render` refuses because decision 3 forbids *ranking, grouping and
rendering* before verification, not only closing. `--partial` is the escape, and it is not a
"clearly labelled" render of everything: it stamps the coverage ratio, OMITS the ranking section
entirely, renders only the entries that carry a current verdict, and NAMES the rest in a section of
their own. Plan revision 1 let `doc` run unflagged "clearly labelled"; that was a silent deviation
from the user's brief and `gate_or_refuse` is its correction.

THE FILENAME'S DATE IS LOCAL AND THE STAMP IS AWARE-UTC, which looks inconsistent and is not. The
task's own Verify line greps `backlog-groomed-$(date +%F).md`, and `date +%F` is the LOCAL date, so
a UTC-derived filename disagrees with it for several hours a day — a red with nothing to do with the
code. `generated_at` stays aware UTC because `_dedup` orders ledger stamps from several hosts as
strings. Nothing should recompute either one: `render` PRINTS `REPORT=<path>`, and every caller
derives the filename from that single line.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, exactly as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package
around them and a plain same-directory import resolves identically in both layouts. `sys.path` is
the IMPORTER's job. By importing the parser this module joins the pin-guard family that
`tests/hooks/test-backlog-headings.sh` (H19c) DERIVES, where its expectation is the default one: NO
`iter_entries` call lives here — reading and parsing the two files is backlog-groom.py's job.
"""
import collections
import datetime
import hashlib
import os
import re
from typing import Dict, List, NamedTuple, Sequence, Tuple

import zuvo_backlog_io as zio
import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb  # noqa: F401  (joins H19c's derived pin-guard family by importing)
from zuvo_backlog_load import Loaded
from zuvo_backlog_prepass import RC_PARTIAL, refuse
from zuvo_backlog_score import (RANK_CAVEAT, Scored, cluster_of, score_entries, suggestion)

REPORT_NAME = "backlog-groomed-%s.md"

PARTIAL_BANNER = (
    "> **PARTIAL VERIFICATION.** %d of %d entries carry a current verdict. The ranking section is "
    "OMITTED (decision 11): nothing is ranked before the whole set is verified. Only the verified "
    "entries are rendered below; the rest are NAMED, unrendered, under *Unverified*.")

SELF_CHECK = '''## Provenance self-check

Run this with ONLY this document in hand. It reads `source:` and `source_sha256:` back out of the
header above and compares them with the backlog on disk, so a document that has stopped describing
its source says so without anyone having to remember what the source used to be.

```sh
REPORT=<path to this file>
python3 - "$REPORT" <<'EOF'
import hashlib, re, sys
doc = open(sys.argv[1], encoding="utf-8").read()
path = re.search(r"^source: (.+)$", doc, re.M).group(1)
want = re.search(r"^source_sha256: ([0-9a-f]{64})$", doc, re.M).group(1)
have = hashlib.sha256(open(path, "rb").read()).hexdigest()
print("MATCH" if have == want else "MISMATCH want=%s have=%s" % (want, have))
EOF
```
'''


class Doc(NamedTuple):
    """Everything the document is rendered FROM, in one value.

    A context object and not six positional arguments: each section below needs a different three
    of them, and six-parameter helpers is how `rules/file-limits.md`'s parameter ceiling gets
    argued with instead of met.
    """

    loaded: Loaded
    repo: str
    ledger: str
    read: zl.LedgerRead
    scored: List[Scored]
    short: List[str]
    partial: bool

    @property
    def verified(self) -> int:
        return len(self.scored)

    @property
    def total(self) -> int:
        """Rendered plus named-but-unrendered. It equals `len(loaded.entries)` and is derived from
        the two lists instead, so a section that silently dropped an entry moves this number."""
        return len(self.scored) + len(self.short)


def generator() -> str:
    """Decision 12's third field: WHICH code produced this document.

    The plugin's `package.json` version when this runs from a checkout; otherwise a content hash of
    the two files that actually rendered it. `unknown` was the alternative and it makes the field
    unfalsifiable — the flattened `~/.zuvo/` install has no `package.json`, which is exactly where a
    stale helper is most likely to be the one running.
    """
    here = os.path.dirname(os.path.realpath(__file__))
    pkg = os.path.join(os.path.dirname(os.path.dirname(here)), "package.json")
    m = re.search(r'"version"\s*:\s*"([^"]+)"', zio.read(pkg)) if os.path.exists(pkg) else None
    if m:
        return "backlog-groom.py render (zuvo %s)" % m.group(1)
    digest = hashlib.sha256()
    for name in ("backlog-groom.py", os.path.basename(__file__)):
        with open(os.path.join(here, name), "rb") as fh:
            digest.update(fh.read())
    return "backlog-groom.py render (unversioned install, code sha256 %s)" % digest.hexdigest()[:12]


def source_digest(path: str) -> Tuple[str, int]:
    """(sha256, size) of the source backlog, read as BYTES.

    Bytes and not `zio.read`'s text: the self-check this document publishes runs
    `open(path, "rb")`, and a digest taken over universal-newline-translated text would not match
    it on a CRLF backlog — a provenance field reporting a mismatch on a file nobody touched.
    """
    with open(path, "rb") as fh:
        raw = fh.read()
    return hashlib.sha256(raw).hexdigest(), len(raw)


def report_path(zuvo: str) -> str:
    """`$ZUVO_DIR/reports/backlog-groomed-<date>.md`, with the LOCAL date — see the module docstring
    for why it is local while `generated_at` is aware UTC."""
    return os.path.join(zuvo, "reports", REPORT_NAME % datetime.date.today().isoformat())


def _oneline(text: str, cap: int = 110) -> str:
    """One table cell: collapsed whitespace, pipes escaped, truncated. A raw `|` would silently add
    a column and shift every later cell of that row."""
    flat = re.sub(r"\s+", " ", text).strip().replace("|", "\\|")
    return flat[:cap] + ("…" if len(flat) > cap else "")


def _provenance(doc: "Doc") -> List[str]:
    """Decision 12's header: the source and its sha256, the coverage count, and the generator.

    Every field is on its own `key: value` line, which is what makes the self-check a two-regex
    script rather than a markdown parser.
    """
    sha, size = source_digest(doc.loaded.real)
    pct = (100.0 * doc.verified / doc.total) if doc.total else 0.0
    return ["## Provenance", "",
            "```", "source: %s" % doc.loaded.real, "source_sha256: %s" % sha,
            "source_bytes: %d" % size, "entries: %d" % doc.total,
            "coverage: %d/%d (%.1f%%)" % (doc.verified, doc.total, pct),
            "mode: %s" % ("partial" if doc.partial else "full"),
            "ledger: %s" % doc.ledger, "ledger_rows: %d" % len(doc.read.rows),
            "ledger_defects: %d" % len(doc.read.defects),
            "generated_by: %s" % generator(),
            "generated_at: %s" % zl.now_stamp(), "```", ""]


def _coverage(scored: Sequence[Scored]) -> List[str]:
    """Per-verdict and per-disposition counts over the rendered entries. EVERY token of both closed
    vocabularies is printed, including the zeroes: a vocabulary with its empty rows removed cannot
    be told apart from a shorter vocabulary."""
    verdicts = collections.Counter(s.verdict for s in scored)
    disp = collections.Counter(s.disposition for s in scored)
    out = ["## Coverage", "", "| Verdict | Entries |", "|---|---|"]
    out += ["| `%s` | %d |" % (v, verdicts.get(v, 0)) for v in zl.VERDICTS]
    out += ["", "| Disposition | Entries |", "|---|---|"]
    out += ["| `%s` | %d |" % (d, disp.get(d, 0)) for d in zl.DISPOSITIONS]
    out.append("")
    return out


def ranked(scored: Sequence[Scored]) -> List[Scored]:
    """The entries the ranking covers, in rank order.

    Scoped to the verdicts that KEEP an entry (`STILL-REAL`, `NOT-VERIFIABLE`): a `STALE-*` entry is
    a closure, and ranking work that is about to be archived would put the document's loudest list
    at odds with its own dispositions. Ties break on `subject`, so the order is total.
    """
    keep = [s for s in scored
            if s.verdict in (zl.VERDICT_STILL_REAL, zl.VERDICT_NOT_VERIFIABLE)]
    return sorted(keep, key=lambda s: (-s.score, s.subject))


def _ranking(scored: Sequence[Scored]) -> List[str]:
    """The ranking section — the one decision 11 omits entirely under `--partial`."""
    out = ["## Ranking", "", RANK_CAVEAT, "",
           "| Rank | ID | Score | Impact | Risk | Effort | Verdict | Entry |",
           "|---|---|---|---|---|---|---|---|"]
    for n, s in enumerate(ranked(scored), start=1):
        out.append("| %d | %s | %d | %d | %d | %d | %s | %s |" % (
            n, s.subject, s.score, s.impact, s.risk, s.effort, s.verdict, _oneline(s.entry.body)))
    out.append("")
    return out


def _clusters(scored: Sequence[Scored], repo: str) -> List[str]:
    """Grouping by theme, with one suggested batch command per cluster.

    Clusters are sorted by NAME and never by score: a score-sorted grouping is a second ranking
    wearing a grouping's clothes, and `--partial` has to be able to keep the grouping while the
    ranking is gone.
    """
    groups: Dict[str, List[Scored]] = collections.defaultdict(list)
    for s in scored:
        groups[cluster_of(s.entry)].append(s)
    out = ["## Clusters", ""]
    for name in sorted(groups):
        mine = sorted(groups[name], key=lambda s: s.subject)
        out += ["### %s (%d)" % (name, len(mine)), "",
                "suggested batch: %s" % suggestion(name, [s.verdict for s in mine], repo), ""]
        out += ["- `%s` — %s — disposition `%s` — %s" % (
            s.subject, s.verdict, s.disposition, _oneline(s.entry.body, 90)) for s in mine]
        out.append("")
    return out


def _not_verifiable(scored: Sequence[Scored]) -> List[str]:
    """The explicit NOT-VERIFIABLE section. It prints `none` rather than disappearing: a missing
    section reads as "nothing was undecidable", which is a claim, while an empty one is a fact."""
    mine = sorted((s for s in scored if s.verdict == zl.VERDICT_NOT_VERIFIABLE),
                  key=lambda s: s.subject)
    out = ["## Not verifiable", "",
           "Reported rather than omitted: an entry the repo does not answer is a known unknown, and "
           "`NOT-VERIFIABLE` is cheap and legitimate.", ""]
    if not mine:
        return out + ["none", ""]
    out += ["- `%s` — %s" % (s.subject, _oneline(str(s.row.get("evidence", "")), 150))
            for s in mine]
    out.append("")
    return out


def _unverified(short: Sequence[str]) -> List[str]:
    """The entries `--partial` did NOT render, named one per line.

    Named and not rendered: decision 3 forbids rendering an entry that carries no verdict, naming it
    is not rendering it, and leaving it out entirely would make the document silently describe a
    subset of the file it claims to be about.
    """
    out = ["## Unverified", "",
           "%d %s no current verdict, so %s NAMED here and rendered nowhere."
           % (len(short), "entry carries" if len(short) == 1 else "entries carry",
              "it is" if len(short) == 1 else "they are"), ""]
    return out + ["- `%s`" % s for s in short] + [""]


def _defects(read: zl.LedgerRead) -> List[str]:
    """Ledger lines the read could not account for, rendered when there are any.

    For the reason `plan` prints them: an unreadable line leaves its entry UNVERIFIED, and a reader
    has to be able to tell that apart from an entry nobody ever verified.
    """
    if not read.defects:
        return []
    return ["## Ledger defects", "",
            "%d line(s) of the ledger do not parse or do not validate. Their entries read "
            "UNVERIFIED, never verified." % len(read.defects), ""] \
        + ["- %s" % _oneline(d, 200) for d in read.defects] + [""]


def document(doc: Doc) -> str:
    """The whole document, in one place, so its section ORDER is readable as a list."""
    out = ["# Groomed backlog", ""]
    if doc.partial:
        out += [PARTIAL_BANNER % (doc.verified, doc.total), ""]
    out += _provenance(doc)
    out += _coverage(doc.scored)
    if not doc.partial:
        out += _ranking(doc.scored)
    out += _clusters(doc.scored, doc.repo)
    out += _not_verifiable(doc.scored)
    if doc.short:
        out += _unverified(doc.short)
    out += _defects(doc.read)
    out.append(SELF_CHECK)
    return "\n".join(out)


def gate_or_refuse(verified: int, total: int, short: Sequence[str], partial: bool) -> None:
    """Decision 11: refuse to render a partially verified backlog unless `--partial` is passed.

    Its OWN exit code, not `apply`'s: "verify the rest" and "pass --partial" are different
    remedies, and an operator who greps an exit code must get one answer. The shortfall is named,
    not sampled, for the reason `coverage_or_refuse` names its own: "494 of 495" sends a reader back
    to a 265 KB file to diff two lists by hand.
    """
    print("VERIFIED=%d/%d" % (verified, total))
    if verified == total or partial:
        return
    for subject in short:
        print("UNVERIFIED=" + subject)
    named = ", ".join(short[:10]) + (f" … and {len(short) - 10} more" if len(short) > 10 else "")
    refuse(RC_PARTIAL,
           f"refusing to render: {verified} of {total} entries carry a current verdict, "
           f"{len(short)} do not. nothing is ranked, grouped or rendered without a verdict backed "
           f"by an evidence line. pass --partial to render the verified subset with the coverage "
           f"ratio stamped in and the ranking omitted, or verify the rest first. the shortfall, by "
           f"id: {named}.")


def render(loaded: Loaded, repo: str, zuvo: str, partial: bool, dry_run: bool) -> int:
    """Gate, score, render, write — and print every number the document claims."""
    ledger = zl.ledger_paths(repo)[1]
    read = zl.read_ledger(ledger)
    for line in read.defects:
        print("LEDGER_DEFECT=" + line)
    print("BACKLOG=%s" % loaded.real)
    print("ENTRIES=%d" % len(loaded.entries))
    print("LEDGER=%s rows=%d defects=%d" % (ledger, len(read.rows), len(read.defects)))
    verified, total, short = zl.coverage(loaded.entries, read.rows)
    gate_or_refuse(verified, total, short, partial)
    scored = score_entries(loaded.lines, zl.plan_reuse(loaded.entries, read.rows).reuse)
    text = document(Doc(loaded, repo, ledger, read, scored, short, partial))
    path = report_path(zuvo)
    print("CLUSTERS=%d" % len({cluster_of(s.entry) for s in scored}))
    print("RANKING=%s" % ("omitted" if partial else str(len(ranked(scored)))))
    print("NOT_VERIFIABLE=%d" % sum(1 for s in scored
                                    if s.verdict == zl.VERDICT_NOT_VERIFIABLE))
    print("RENDERED=%d UNRENDERED=%d" % (len(scored), len(short)))
    print("REPORT=%s" % path)
    if dry_run:
        print("DRY_RUN=1 wrote nothing")
        return 0
    os.makedirs(os.path.dirname(path), exist_ok=True)
    zio.atomic_write(path, text, None)
    print("REPORT_BYTES=%d" % len(text.encode("utf-8")))
    return 0
