"""THE DETERMINISTIC VERDICTS: the four classes a machine can decide, and the evidence each one
owes. Imported by backlog-groom.py; not a script, no shebang, no executable bit.

WHY A PRE-PASS AT ALL. The binding decision is that every entry carries a verdict before anything is
closed, ranked, grouped or rendered — 483 entries here today, several hundred per checkout across the
fleet. Dispatching all of them to a model costs the fan-out and buys nothing on the entries where the
FILE ALREADY ANSWERS: an entry that says DONE, an entry whose key is in the archive, an entry that
repeats another one, an entry whose every cited path is gone. Those four are decided from bytes, so
they are decided here, once, deterministically. The model sees the remainder.

THEY STILL CARRY EVIDENCE. Decision 3 exempts the deterministic classes from the model's JUDGEMENT,
never from the evidence line — "the file said so" is not a verdict anybody can re-check. So each class
emits a citation that RESOLVES: a path that exists, at a line the file really has. `unresolvable()` is
the check, and backlog-groom.py refuses to emit a row that fails it rather than shipping a verdict
whose proof points nowhere.

TWO PATH REGEXES, DELIBERATELY, and confusing them is the bug this paragraph exists to prevent:

  * `_CITED_RE` reads the ENTRY's prose, looking for a repo-relative path the entry is ABOUT. It is
    much stricter than the parser's `_PATH_RE` and every restriction is a measured false positive that
    would otherwise have produced a STALE-OBSOLETE — a verdict whose disposition is `dropped`:
      - a `/` is REQUIRED, so `backlog.md`, `e.g.` and `conf 62` are not paths;
      - the lookbehind rejects a token whose real path extends LEFT out of the match, which is how
        `~/.codex/scripts/benchmark.sh` and `/Applications/Codex.app/…` arrived as the repo-relative
        `codex/scripts/benchmark.sh` and `Applications/Codex.app`; `*` and `?` are in the same set, so
        the glob `skills/*/SKILL.md` no longer yields `/SKILL.md`;
      - the extension must be LOWERCASE, which is what stops `origin/main..HEAD` reading as a file
        with an `.HEAD` extension. The cost is that a cited `x/y.TS` is not seen; the benefit is that a
        git range is never reported as a deleted file.
    Measured on this repo's 483 entries: 107 cite at least one such path and 0 have all of them
    absent, so the obsolete class is empty here today. It is fixture-tested instead.
  * `zuvo_backlog_ledger.evidence_locations` reads the EVIDENCE this module writes, and it accepts a
    bare `backlog.md:44` because that is the shape three of the four classes cite. Using `_CITED_RE`
    there would reject every one of them.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, exactly as in the five siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so the parser, the io layer, the ledger and
this module end up as FLAT siblings with no package around them, and a plain same-directory
`import zuvo_backlog_ledger` resolves identically in the checkout and on the flattened layout. Putting
the importer's directory on `sys.path` is the IMPORTER's job. By importing the parser this module also
joins the pin-guard family that `tests/hooks/test-backlog-headings.sh` (H19c) DERIVES, where its
expectation is the default one: NO `iter_entries` call at all lives here. Reading the two files is
backlog-groom.py's job; this module only judges what it is handed.
"""
import os
import re
from typing import Dict, List, NamedTuple, Optional, Sequence, Tuple

import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb

CLASS_MARKER = "marker"
CLASS_ARCHIVED = "archived"
CLASS_DUPLICATE = "duplicate"
CLASS_OBSOLETE = "obsolete"
CLASSES: Tuple[str, ...] = (CLASS_MARKER, CLASS_ARCHIVED, CLASS_DUPLICATE, CLASS_OBSOLETE)

VERIFIED_BY = "deterministic:%s"          # `_BY_RE`'s shape; a free-form provenance makes "which of
                                          # these did a MODEL produce" unanswerable, which is exactly
                                          # what the cross-model spot check asks

# See the module docstring for why every restriction here is in place. The `(?![\w/])` tail stops a
# directory being harvested out of the middle of a longer path.
_CITED_RE = re.compile(
    r"(?<![\w./@~*?+-])([\w.@-]+(?:/[\w.@-]+)*/[\w.@-]*[\w@-]\.[a-z][a-z0-9]{0,4})(?::(\d+))?(?![\w/])")
# A `path:line` inside a QUOTED clause would be a second citation, and then "every location in this
# evidence resolves" becomes a claim about text the entry happened to contain rather than about the
# citation this module made. The line number is dropped from the quote; the path is kept, so the quote
# still reads as the entry's own words.
_QUOTED_LOC_RE = re.compile(r"(\.[A-Za-z][A-Za-z0-9]{0,4}):\d+")
_CLAUSE_MAX = 72                          # a clause, not a paragraph: enough to show WHICH marker


class Tree(NamedTuple):
    """What a cited path is resolved against. The two backlog files are named explicitly because the
    evidence cites them by BASENAME (`backlog.md:44`) while they live at a realpath that six ~/DEV
    checkouts reach through symlinks — joining them onto `root` would resolve to a file that is not
    the one the verdict is about."""

    root: str
    real: str
    archive: str

    @property
    def open_name(self) -> str:
        """The basename the evidence cites for the OPEN file. Derived, never the literal `backlog.md`:
        a citation this module writes must resolve through `resolve_cited`, which matches on the
        basename of THIS tree's file — so a hardcoded name silently stops resolving the moment the
        canonical backlog is reached under any other name, and every row of three of the four classes
        is then refused at emit. Measured: it refused 100% of them on a differently-named fixture."""
        return os.path.basename(self.real)

    @property
    def done_name(self) -> str:
        """The same, for the archive."""
        return os.path.basename(self.archive)


class Verdict(NamedTuple):
    """One deterministic judgement. `klass` travels separately from `verdict` because two classes emit
    the same verdict (`STALE-FIXED`) for different reasons, and `verified_by` has to say which."""

    entry: zb.Entry
    verdict: str
    evidence: str
    klass: str


def cited_paths(body: str) -> List[str]:
    """The repo-relative paths an entry is ABOUT, in order, deduplicated. See the docstring."""
    out: List[str] = []
    for m in _CITED_RE.finditer(body):
        path = m.group(1)
        if path.startswith(("http", "www.")) or path in out:
            continue
        out.append(path)
    return out


def resolve_cited(path: str, tree: Tree) -> Optional[str]:
    """Where a cited path lives on disk, or None when the citation names nothing this tree has.

    The two backlog basenames are special-cased, not joined onto `root`: that is how `backlog.md:44`
    and `backlog-done.md:9` — the shapes three of the four classes cite — reach the REAL files rather
    than a `memory/` path that may be a symlink into another checkout.
    """
    base = os.path.basename(path)
    if base == os.path.basename(tree.real) and "/" not in path:
        return tree.real
    if base == os.path.basename(tree.archive) and "/" not in path:
        return tree.archive
    if os.path.isabs(path):
        return None
    return os.path.join(tree.root, path)


def unresolvable(evidence: str, tree: Tree) -> List[str]:
    """Every location in `evidence` that does NOT resolve, named. An empty list means all of them do.

    "Resolves" is the include's control (b) verbatim: the path exists AND the file has at least that
    many lines. Checking mere non-emptiness is what lets a fabricated `src/gone.ts:9000` read as proof,
    and this module's own rows are held to the same bar as a model's — a deterministic class that
    emitted an unresolvable citation would be the most convincing wrong verdict in the ledger.
    """
    locs = zl.evidence_locations(evidence)
    if not locs:
        return ["no `path:line` citation at all"]
    bad: List[str] = []
    for path, line in locs:
        target = resolve_cited(path, tree)
        if target is None or not os.path.isfile(target):
            bad.append(f"{path}:{line} — no such file")
            continue
        with open(target, encoding="utf-8", errors="replace") as fh:
            have = sum(1 for _ in fh)
        if line < 1 or line > have:
            bad.append(f"{path}:{line} — the file has {have} line(s)")
    return bad


def quote_clause(text: str) -> str:
    """One line of quotable evidence text: whitespace collapsed, quotes removed, line numbers dropped
    out of any path inside it (see `_QUOTED_LOC_RE`), truncated to a clause."""
    flat = " ".join(text.replace('"', "").split())
    flat = _QUOTED_LOC_RE.sub(r"\1", flat)
    return flat[:_CLAUSE_MAX].rstrip()


def marker_pos(e: zb.Entry) -> int:
    """Rightmost resolution-marker offset in this entry, by DIALECT, or -1.

    A heading gets the stricter `heading_resolution_pos`, and that is not a stylistic preference: a
    heading has no tick, so the loose guard's every tolerance becomes a false "resolved" in the
    ARCHIVABLE direction — measured at 50 false positives over 3561 heading entries. Reusing one
    predicate for both dialects is how those 50 would arrive here as `STALE-FIXED`.
    """
    return (zb.heading_resolution_pos(e.body) if e.kind == zb.KIND_HEADING
            else zb.resolution_marker_pos(e.body))


def archive_index(archived: Sequence[zb.Entry]) -> Dict[str, zb.Entry]:
    """key -> the archived entry carrying it. Built from `keys_for`, never from `key` alone, so the
    pre-mint content key an archived entry still answers to is in the index too — that bridge is the
    only thing that finds an entry which was archived AFTER an id was minted into it."""
    out: Dict[str, zb.Entry] = {}
    for e in archived:
        for key in zb.keys_for(e.body, e.ident):
            out.setdefault(key, e)
    return out


def duplicate_anchors(entries: Sequence[zb.Entry]) -> Dict[int, Tuple[str, zb.Entry]]:
    """lineno -> (the shared key, the FIRST entry carrying it) for every entry that is not the first.

    Keyed off `keys_for` and not `key`: once the pre-pass mints an id, `entry_key` prefers `id:` and
    stops reading the text, so every content collision in the file would vanish from view at exactly
    the moment the ids were written. `keys_for` keeps the pre-mint `fp:` key, which is what still sees
    them. Only the entries AFTER the first are marked, because `DUPLICATE-OF` is a report and the
    anchor is the entry it reports against — marking all N would leave no entry to point at.
    """
    first: Dict[str, zb.Entry] = {}
    out: Dict[int, Tuple[str, zb.Entry]] = {}
    for e in entries:
        for key in sorted(zb.keys_for(e.body, e.ident)):
            anchor = first.get(key)
            if anchor is None:
                first[key] = e
            elif e.lineno not in out:
                out[e.lineno] = (key, anchor)
    return out


def _marker_verdict(e: zb.Entry, pos: int, tree: Tree) -> Verdict:
    """The entry says it was closed, in its own words, at its own line."""
    clause = quote_clause(e.body[pos:])
    return Verdict(e, zl.VERDICT_STALE_FIXED,
                   f'{tree.open_name}:{e.lineno} "{clause}"', CLASS_MARKER)


def _archived_verdict(e: zb.Entry, key: str, other: zb.Entry, tree: Tree) -> Verdict:
    """The archive already holds this key, so the entry in the open file is a leftover copy."""
    return Verdict(e, zl.VERDICT_STALE_FIXED,
                   f'{tree.done_name}:{other.lineno} section="{quote_clause(other.section)}"'
                   f" holds {key}", CLASS_ARCHIVED)


def _duplicate_verdict(e: zb.Entry, key: str, other: zb.Entry, tree: Tree) -> Verdict:
    """Both line numbers, and the OTHER entry's key in the evidence — never in the `verdict` field.

    The vocabulary is closed at five tokens and the ledger validates against that closed set, so a
    `DUPLICATE-OF <key>` verdict is unvalidatable by construction. The key rides here.
    """
    return Verdict(e, zl.VERDICT_DUPLICATE_OF,
                   f"{tree.open_name}:{e.lineno} duplicates {key} at"
                   f" {tree.open_name}:{other.lineno} — reported, never merged", CLASS_DUPLICATE)


def _obsolete_verdict(e: zb.Entry, paths: Sequence[str], tree: Tree) -> Verdict:
    """The citation is the BACKLOG line that names the missing path, with the absence in the text.

    Citing the missing path itself could not resolve, so control (b) would reject every correct row of
    this class — which is why the shape is prescribed rather than left to whoever writes the row.
    """
    named = ", ".join(paths[:3]) + ("…" if len(paths) > 3 else "")
    return Verdict(e, zl.VERDICT_STALE_OBSOLETE,
                   f'{tree.open_name}:{e.lineno} "{named}" does not exist', CLASS_OBSOLETE)


def classify(entries: Sequence[zb.Entry], tree: Tree,
             archived: Sequence[zb.Entry]) -> Tuple[List[Verdict], List[str]]:
    """(the deterministic verdicts, the rows REFUSED because their evidence did not resolve).

    FIRST MATCH WINS, in the order marker -> archived -> duplicate -> obsolete, and the order is the
    strength of the proof rather than a coincidence of writing: the entry's own recorded closure beats
    an inference from the archive, both beat "it looks like another entry", and all three beat "the
    files it names are gone" — the only class whose input is the tree rather than the two backlogs.

    An entry that matches nothing is absent from the result: it is the MODEL's work, and inventing a
    `NOT-VERIFIABLE` for it here would make the coverage count read full while nobody had looked.
    """
    ix = archive_index(archived)
    dups = duplicate_anchors(entries)
    out: List[Verdict] = []
    refused: List[str] = []
    for e in entries:
        v = _classify_one(e, tree, ix, dups)
        if v is None:
            continue
        bad = unresolvable(v.evidence, tree)
        if bad:
            refused.append(f"{e.ident or e.key} ({v.klass}): evidence does not resolve — "
                           + "; ".join(bad))
            continue
        out.append(v)
    return out, refused


def _classify_one(e: zb.Entry, tree: Tree, ix: Dict[str, zb.Entry],
                  dups: Dict[int, Tuple[str, zb.Entry]]) -> Optional[Verdict]:
    """The four classes for ONE entry, in precedence order. See `classify` for why that order."""
    pos = marker_pos(e)
    if pos >= 0:
        return _marker_verdict(e, pos, tree)
    hit = next(((k, ix[k]) for k in sorted(zb.keys_for(e.body, e.ident)) if k in ix), None)
    if hit is not None:
        return _archived_verdict(e, hit[0], hit[1], tree)
    if e.lineno in dups:
        key, other = dups[e.lineno]
        return _duplicate_verdict(e, key, other, tree)
    paths = cited_paths(e.body)
    if paths and all(not os.path.exists(os.path.join(tree.root, p)) for p in paths):
        return _obsolete_verdict(e, paths, tree)
    return None


def ledger_rows(verdicts: Sequence[Verdict]) -> List[Dict[str, object]]:
    """Ledger rows for `append_rows`, built through the ledger's own helpers so the schema cannot
    drift from the one that validates it. `disposition` stays `pending`: a verdict says what is true
    and `groom` says what was done about it, and writing a disposition here would close entries from
    the pass whose whole purpose is to decide nothing."""
    stamp = zl.now_stamp()
    return [{"id": v.entry.ident or v.entry.key,
             "keys": sorted(zb.keys_for(v.entry.body, v.entry.ident)),
             "text_sha": zl.text_sha(v.entry.body),
             "verdict": v.verdict,
             "evidence": v.evidence,
             "verified_at": stamp,
             "verified_by": VERIFIED_BY % v.klass,
             "disposition": "pending"} for v in verdicts]
