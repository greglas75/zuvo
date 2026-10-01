"""THE FLEET LANE, AND THE THREE REFUSALS THAT KEEP IT READ-ONLY. Imported by backlog-groom.py; not
a script, no shebang, no executable bit.

WHY `groom --fleet` DOES NOT EXIST, and why that is the most important sentence in this file.
Grooming needs each repo's own `Lock`, its realpath, its git-ignore status and its own
`backlog-done.md`. Doing that across every checkout at once is the 2026-07-19 fork-the-backlog
incident (`backlog-protocol.md:14-29`) with the fleet's multiplier on it. MEASURED on this machine
before this module was written: `~/.zuvo/backlog-local.jsonl` is **8,543,783 bytes / 14,583 rows
over 56 distinct (host, repo) pairs**, while `memory/backlog*.md` under `~/DEV` and `~/projects`
comes to **3,250 files in 727 directories** (3,188 distinct realpaths; the collector's own
one-level `<root>/*/memory/backlog.md` model sees 76 of them). A write bug here would land in other
people's repositories, so decision 13 makes the fleet lane READ-ONLY by construction rather than by
care: this module reads ONE file and writes into `~/.zuvo/` and nowhere else. It never resolves a
repo path, never takes another checkout's lock and never imports the archiver.

The three refusals, each its own code so an operator who greps one gets one answer:

  * `apply --fleet` -> `RC_FLEET`, naming the per-repo command. The flag EXISTS on `apply` purely so
    that asking for it is answered instead of being silently accepted by argparse as an unknown
    argument on some future parser, or — worse — quietly doing a per-repo run under a fleet-shaped
    command line.
  * a ledger row carrying `source=index` -> `RC_INDEX`. Fleet verdicts are judged from text the
    collector TRUNCATES at 400 characters (`parse_backlog:354`, and 400 is the measured maximum in
    today's snapshot), so such a row describes a prefix of an entry. A disposition is destructive,
    and a destructive action on a prefix is not a judgement about the entry.
  * a seed shortfall is somebody else's refusal, but the same principle: an under-gated run that
    reads like a gated one is the failure mode every refusal in this family exists to prevent.

WHY A FLEET ROW IS *ALSO* NEARLY UNABLE TO SATISFY A PER-REPO GATE — and why that is not the
control. `text_sha` is taken over the row's `text`, which is the truncated prefix, so for every
entry longer than 400 characters the sha cannot equal the per-repo ledger's. For a SHORT entry it
can, exactly. So the shape of the data is a mitigation and `refuse_index_rows` is the control; the
suite asserts the refusal on a row whose sha DOES match, because a refusal that only fires on the
truncated majority would be a refusal nobody could rely on.

WHAT IT CAN DECIDE FROM THE INDEX ALONE. Two of the four deterministic classes survive truncation:
a resolution marker inside the prefix is a recorded closure, and two rows of the same repo sharing
a `key` are a duplicate pair. Everything else is `NOT-VERIFIABLE` with the reason stated — the
index holds no tree, so a verdict about code genuinely cannot be reached from it. Guessing
`STILL-REAL` there would be the cheapest way to look thorough and the most expensive to undo, which
is why `backlog-grooming.md` says `NOT-VERIFIABLE` is cheap and legitimate.

ENV NAMES ARE THE COLLECTOR'S, deliberately: `ZUVO_DIR` for the HOME-local state root and
`ZUVO_BACKLOG_OUT` for the snapshot, exactly as `backlog-collect.py:49-51` resolves them. This
module consumes what that one writes, and a second spelling of the same path is how a reader ends up
verifying a snapshot nobody is updating. NOTE the collision worth knowing about: `ZUVO_DIR` here
means `~/.zuvo` (HOME-local), while `shared/includes/report-output-location.md` uses `$ZUVO_DIR` for
the project's `zuvo/` directory, whose override is the differently-named `ZUVO_OUTPUT_DIR`. Two
meanings, two variable names, no overlap in code — but they are one grep apart in the docs.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, exactly as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package
around them and a plain same-directory import resolves identically in both layouts. `sys.path` is
the IMPORTER's job. By importing the parser this module joins the pin-guard family that
`tests/hooks/test-backlog-headings.sh` (H19c) DERIVES, where its expectation is the default one: NO
`iter_entries` call lives here — this module never parses a backlog file at all.
"""
import collections
import json
import os
import re
from typing import Any, Dict, Iterator, List, NamedTuple, Sequence, Tuple

import zuvo_backlog_io as zio
import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb
from zuvo_backlog_prepass import RC_FLEET, RC_INDEX, RC_QUEUE, refuse

IndexRow = Dict[str, Any]               # a snapshot row, as in the siblings that say the same of
                                        # their own: typing it tighter than the JSON would be fiction
SOURCE_INDEX = "index"                  # the `source` every row this module writes carries
INDEX_NAME = "backlog-local.jsonl"      # backlog-collect.py's own default snapshot name
VERDICTS_DIR = "backlog-verdicts"       # under ~/.zuvo/, never inside any checkout
LANE = "deterministic:fleet-index"      # `_BY_RE`'s `deterministic:<class>` shape

# The snapshot truncates at `text[:400]` (parse_backlog). Stated as a constant because two things
# depend on the number: the honest `NOT-VERIFIABLE` reason, and the suite's assertion that a long
# entry's fleet sha can never equal its per-repo one.
TRUNCATED_AT = 400

# A filename component, so a repo called `../etc` cannot aim the write out of the verdicts
# directory. Belt and braces over a value that comes from a JSON file this process did not write.
_SAFE_RE = re.compile(r"[^A-Za-z0-9._-]+")


class IndexRead(NamedTuple):
    """What the snapshot yielded. `defects` are NAMED lines whose rows are absent from `rows`, the
    same fail-closed shape `read_ledger` uses: a line this cannot account for is no row at all."""

    rows: List[IndexRow]
    defects: List[str]
    lines: int
    size: int


def home() -> str:
    """`$ZUVO_DIR`, else `~/.zuvo` — `backlog-collect.py:49`'s resolution, not a second one."""
    return os.environ.get("ZUVO_DIR") or os.path.join(os.path.expanduser("~"), ".zuvo")


def index_path() -> str:
    """`$ZUVO_BACKLOG_OUT`, else `<home>/backlog-local.jsonl` — `backlog-collect.py:51`'s.

    Decision 13 is explicit that this is NOT `~/.zuvo/backlog-index.jsonl`, which was measured at
    **0 bytes**: reading the empty one would make the fleet lane report a clean pass over nothing.
    """
    return os.environ.get("ZUVO_BACKLOG_OUT") or os.path.join(home(), INDEX_NAME)


def verdicts_dir() -> str:
    """`<home>/backlog-verdicts` — the ONLY directory this module writes into."""
    return os.path.join(home(), VERDICTS_DIR)


def out_path(host: str, repo: str) -> str:
    """`<verdicts dir>/<host>-<repo>.jsonl`, with both components reduced to a safe filename."""
    return os.path.join(verdicts_dir(), "%s-%s.jsonl" % (_SAFE_RE.sub("_", host) or "unknown",
                                                         _SAFE_RE.sub("_", repo) or "unknown"))


def stream_index(path: str) -> Iterator[Tuple[int, Any]]:
    """Yield `(lineno, parsed-or-None)` one line at a time.

    STREAMED, not `json.load`ed into a list first: the snapshot is 8.5 MB today and grows with every
    checkout on the host, and CQ6 is about the shape of the read rather than about today's size.
    An unparseable line yields `None` so the caller can NAME it instead of aborting the whole fleet
    on one bad row — the fail-closed direction here is "that row is not verified", not "no row is".
    """
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, start=1):
            if not line.strip():
                continue
            try:
                yield n, json.loads(line)
            except ValueError:
                yield n, None


def read_index(path: str) -> IndexRead:
    """Parse the snapshot fail-closed, naming every line it cannot use."""
    rows: List[IndexRow] = []
    defects: List[str] = []
    count = 0
    base = os.path.basename(path)
    for n, obj in stream_index(path):
        count = n
        if not isinstance(obj, dict):
            defects.append("%s:%d: unparseable or not a JSON object — reads UNVERIFIED" % (base, n))
            continue
        if not all(isinstance(obj.get(f), str) and obj.get(f) for f in ("host", "repo", "key")):
            defects.append("%s:%d: missing host/repo/key — a verdict with no subject and no "
                           "destination file cannot be written" % (base, n))
            continue
        obj["_lineno"] = n
        rows.append(obj)
    return IndexRead(rows, defects, count,
                     os.path.getsize(path) if os.path.exists(path) else 0)


def _marker_clause(text: str) -> str:
    """The clause around the rightmost resolution marker, for the evidence line. Bounded, because an
    evidence line quoting a 400-character prefix is not evidence, it is the row again."""
    pos = zb.resolution_marker_pos(text)
    return re.sub(r"\s+", " ", text[max(0, pos - 8):pos + 56]).strip()


def _verdict_for(row: IndexRow, dup: str, base: str) -> Tuple[str, str]:
    """(verdict, evidence) for one index row — the two classes truncation survives, else the honest
    `NOT-VERIFIABLE`.

    The evidence cites the SNAPSHOT and says so, because that is where the judgement was made. A
    citation of the repo's own `backlog.md:<line>` would read as if this lane had opened that file,
    which is precisely the thing decision 13 forbids it from doing.
    """
    text = str(row.get("text", ""))
    line = int(row.get("_lineno", 0) or 0)
    if dup:
        return (zl.VERDICT_DUPLICATE_OF,
                "%s:%d shares entry key %s with another row of the same repo (source=%s)"
                % (base, line, dup, SOURCE_INDEX))
    if zb.has_resolution_marker(text):
        return (zl.VERDICT_STALE_FIXED,
                '%s:%d "%s" — the snapshot records this entry resolved (source=%s)'
                % (base, line, _marker_clause(text), SOURCE_INDEX))
    return (zl.VERDICT_NOT_VERIFIABLE,
            "%s:%d the fleet snapshot holds no tree and truncates entry text at %d characters, so "
            "no verdict about code can be reached from it; run `backlog-groom.py plan --repo "
            "%s` in that checkout" % (base, line, TRUNCATED_AT, row.get("repo_path", "<checkout>")))


def _dup_keys(rows: Sequence[IndexRow]) -> Dict[int, str]:
    """{lineno: the key it shares} for every row whose `key` appears more than once in ITS repo.

    Per repo and not per snapshot: two checkouts legitimately hold the same finding, and calling
    that a duplicate would report every shared entry across 56 repos as one.
    """
    seen: Dict[Tuple[str, str, str], List[IndexRow]] = collections.defaultdict(list)
    for row in rows:
        seen[(str(row["host"]), str(row["repo"]), str(row["key"]))].append(row)
    out: Dict[int, str] = {}
    for (_, _, key), mine in seen.items():
        if len(mine) > 1:
            out.update({int(r.get("_lineno", 0) or 0): key for r in mine})
    return out


def ledger_rows(rows: Sequence[IndexRow], base: str) -> List[zl.Row]:
    """One ledger row per index row, every one carrying `source=index`.

    `keys` is the snapshot's own `key` — the collector computes it through the shared
    `zb.entry_key`, so it is the same identity the per-repo ledger uses, which is what makes the
    `source=index` refusal necessary rather than merely tidy: these rows would otherwise RESOLVE
    against real entries.
    """
    dups = _dup_keys(rows)
    out: List[zl.Row] = []
    stamp = zl.now_stamp()
    for row in rows:
        text = str(row.get("text", ""))
        verdict, evidence = _verdict_for(row, dups.get(int(row.get("_lineno", 0) or 0), ""), base)
        out.append({"id": str(row.get("item_id") or row["key"]), "keys": [str(row["key"])],
                    "text_sha": zl.text_sha(text), "verdict": verdict, "evidence": evidence,
                    "verified_at": stamp, "verified_by": LANE, "disposition": "pending",
                    "source": SOURCE_INDEX, "host": str(row["host"]), "repo": str(row["repo"])})
    return out


def refuse_fleet_apply(flag: bool) -> None:
    """Decision 13: there is no fleet grooming. Rejected by NAMING the per-repo command, because a
    refusal that does not say what to run instead gets worked around."""
    if not flag:
        return
    refuse(RC_FLEET,
           "`--fleet` is a VERIFY-only mode and there is no fleet grooming. a disposition needs the "
           "repo's own lock, its realpath, its git-ignore status and its own "
           f"{zio.ARCHIVE_NAME}; doing that across every checkout at once is the fork-the-backlog "
           "incident with the fleet's multiplier on it. run it per repo instead:\n"
           "    python3 backlog-groom.py apply --repo <checkout>\n"
           "fleet verdicts are read-only and live in " + verdicts_dir())


def refuse_index_rows(rows: Sequence[zl.Row]) -> None:
    """A disposition on a `source=index` row is refused, NAMING the offending ids.

    These rows are judged from text truncated at 400 characters, so the row describes a prefix of
    an entry. `read_ledger` would accept them — `validate_row` checks a closed field set and
    ignores extras — and their `keys` come from the shared `entry_key`, so they RESOLVE. Nothing
    else would stop them.
    """
    bad = [str(r.get("id")) for r in rows if str(r.get("source", "")) == SOURCE_INDEX]
    if not bad:
        return
    refuse(RC_INDEX,
           f"{len(bad)} ledger row(s) carry source={SOURCE_INDEX} and a disposition refuses on "
           f"those: a fleet verdict is judged from text the collector truncates at "
           f"{TRUNCATED_AT} characters, so it describes a PREFIX of the entry and a closure is not "
           f"reversible. re-verify those entries in this checkout with `backlog-groom.py plan "
           f"--repo .` and the verifier lane. the rows, by id: " + ", ".join(sorted(bad)[:10]))


def verify_fleet(dry_run: bool) -> int:
    """Read the snapshot, write one verdict file per (host, repo) under `~/.zuvo/`, touch nothing
    else. Returns 0, or refuses when the snapshot is unusable."""
    path = index_path()
    read = read_index(path)
    for line in read.defects:
        print("INDEX_DEFECT=" + line)
    print("FLEET_INDEX=%s bytes=%d lines=%d rows=%d defects=%d"
          % (path, read.size, read.lines, len(read.rows), len(read.defects)))
    if not read.rows:
        refuse(RC_QUEUE,
               f"{path} yielded no usable rows, so a fleet run over it would report a clean pass "
               f"over nothing. `backlog-collect.py` writes that snapshot; decision 13 also records "
               f"that ~/.zuvo/backlog-index.jsonl is the WRONG file and was measured at 0 bytes.")
    base = os.path.basename(path)
    groups: Dict[Tuple[str, str], List[IndexRow]] = collections.defaultdict(list)
    for row in read.rows:
        groups[(str(row["host"]), str(row["repo"]))].append(row)
    print("FLEET_REPOS=%d" % len(groups))
    print("FLEET_VERDICTS=%s" % verdicts_dir())
    total = 0
    for (host, repo) in sorted(groups):
        rows = ledger_rows(groups[(host, repo)], base)
        total += len(rows)
        _emit(host, repo, rows, dry_run)
    print("FLEET_ROWS=%d source=%s" % (total, SOURCE_INDEX))
    if dry_run:
        print("DRY_RUN=1 wrote nothing")
    return 0


def _emit(host: str, repo: str, rows: Sequence[zl.Row], dry_run: bool) -> None:
    """Report one repo's verdicts and, unless this is a dry run, write them.

    EVERY row is validated through the ledger's own `validate_row` BEFORE the write, so a fleet file
    cannot hold a row the per-repo reader would call a defect. `atomic_write` into `~/.zuvo/` and
    never `zl.append_rows`: that function resolves the REPO's backlog and takes the lock in the
    repo's `memory/` directory, which would create a lock directory inside somebody else's
    checkout — the one thing AC11 measures that this lane never does.
    """
    counts = collections.Counter(str(r["verdict"]) for r in rows)
    path = out_path(host, repo)
    print("FLEET_REPO=%s/%s rows=%d %s out=%s" % (
        host, repo, len(rows),
        " ".join("%s=%d" % (v, counts.get(v, 0)) for v in zl.VERDICTS if counts.get(v)), path))
    bad = [p for i, r in enumerate(rows, start=1) for p in zl.validate_row(r, f"<fleet row {i}>")]
    if bad:
        refuse(RC_INDEX, "refusing to write an invalid fleet verdict row:\n  " + "\n  ".join(bad))
    if dry_run:
        return
    os.makedirs(verdicts_dir(), exist_ok=True)
    zio.atomic_write(path, "".join(
        json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n" for r in rows), None)
