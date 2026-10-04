#!/bin/sh
# Polyglot sh/python header — same reason as backlog-archive.py: `#!/usr/bin/env python3` dies on
# Windows/Git Bash. Keep it on ONE line and do not "tidy" the quoting.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
"""Count the heading-shaped lines in every backlog under an EXPLICIT root set, per heading level.

    backlog-census.py [--roots DIR[:DIR…]]… [--min-repos N] [--json]

WHY THIS IS A COMMITTED SCRIPT AND NOT A NUMBER IN A PLAN. The plan this belongs to carries
"1004-1227 heading entries across 14-20 of 69-88 backlogs" — a range, because the figure was produced
by a one-off shell pipeline nobody can re-run. A range is exactly the shape a hazard number must not
have: it is the number that decides whether a fleet-wide remedy is a tidy-up or an incident, and
"1004 or 1227" is the difference between those two readings. So the measurement ships, with its root
set printed, and anybody can disagree with it by running it.

`--roots` TAKES LITERAL DIRECTORY PATHS, and expands `~` ITSELF. Python's `glob` does not expand `~`
(and `os.path.expanduser` does not expand a glob), so `--roots '~/DEV'` handed to `glob` silently
matches NOTHING and a census over nothing prints zeros and exits 0 — a false clean. Two defences:
`~` is expanded here, and an EMPTY ROOT SET EXITS NON-ZERO, so an unexpanded or misspelled root is a
failure rather than a quiet zero.

WHAT IT COUNTS, and why the three columns are not one:
  * `headings`  — every ATX heading-shaped line, which is the population;
  * `entries`   — the ones `iter_entries` yields as HEADING entries, i.e. the ones carrying a `B-` id
                  at the heading's body position. These are addressable and archivable;
  * `idless`    — heading-shaped lines that are NOT entries. NOT a defect and NOT a mint target: a
                  backlog's section headers live here (`## benchmark skill`), and PR 1's decision 1 is
                  that they are reported rather than written into. The gap between the second and
                  third column is the whole reason this script exists.

This is a READ-ONLY census and it deliberately sits OUTSIDE the archiver's pin-guard family (the
derived family is `backlog-archive.py` plus every `zuvo_backlog_*.py` importing the parser). The
family's invariant — seven pinned `kinds=(KIND_CHECKBOX,)` sites plus exactly ONE env-gated heading
request — is about WRITE paths, where admitting a heading MOVES lines. Counting them moves nothing.
"""
import argparse
import glob
import json
import os
import sys
from typing import Dict, List, NamedTuple, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import zuvo_backlog_parse as zb  # noqa: E402  (path must be set before the import)
# THE FAMILY'S ONE EXIT-CODE REGISTRY. These two were declared locally as 30 and 31 and collided
# with RC_PARTIAL/RC_FLEET; a set split across files is a set nobody checks.
from zuvo_backlog_prepass import RC_NO_ROOTS, RC_TOO_FEW  # noqa: E402

# The documented default, and it is documented rather than discovered: the fleet is the checkouts under
# these two trees, the plan's 69-88 figure was taken over them, and a default that globbed wider would
# make two runs of this script incomparable.
DEFAULT_ROOTS: Tuple[str, ...] = ("~/DEV", "~/projects")
# Depth is FIXED and printed. `**` would wander into node_modules and every vendored checkout, so the
# pattern is one level of repo below each root — the shape `backlog-collect.py` walks.
PATTERN = "*/memory/backlog*.md"
LEVELS: Tuple[int, ...] = (1, 2, 3, 4, 5, 6)



class Count(NamedTuple):
    """One file's tally. `entries` and `idless` partition `headings`, and the caller asserts that."""

    headings: int
    entries: int
    idless: int


def expand_roots(values: Sequence[str]) -> Tuple[List[str], List[str]]:
    """(roots that exist as directories, roots that do not) — `~` expanded here, `os.pathsep` split.

    Splitting on `os.pathsep` is what lets one shell variable carry several roots
    (`--roots "$A:$B"`), which is how the suite hands its fixture root in. A value is never globbed:
    a literal path that happens to contain `[` would otherwise resolve to nothing.
    """
    found: List[str] = []
    missing: List[str] = []
    for value in values:
        for part in value.split(os.pathsep):
            if not part:
                continue
            path = os.path.abspath(os.path.expanduser(part))
            (found if os.path.isdir(path) else missing).append(path)
    return found, missing


def backlogs(root: str) -> List[str]:
    """Every `memory/backlog*.md` one level below `root`, plus `root`'s own if it is itself a repo.

    Sorted, so two runs over the same tree print the same order and a diff of two censuses is a diff
    of the numbers rather than of the filesystem's iteration order.
    """
    hits = set(glob.glob(os.path.join(root, PATTERN)))
    hits.update(glob.glob(os.path.join(root, "memory", "backlog*.md")))
    return sorted(p for p in hits if os.path.isfile(p))


def count_file(path: str) -> Dict[int, Count]:
    """Per-level tallies for one file. A level with no headings is absent from the result."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    entries = {e.lineno for e in zb.iter_entries(text, kinds=(zb.KIND_HEADING,))}
    out: Dict[int, Count] = {}
    for lineno, raw in enumerate(text.splitlines(), start=1):
        m = zb.HEADING_RE.match(raw.rstrip())
        if m is None:
            continue
        level = len(raw.rstrip()) - len(raw.rstrip().lstrip("#"))
        if level not in LEVELS:
            continue
        is_entry = lineno in entries
        cur = out.get(level, Count(0, 0, 0))
        out[level] = Count(cur.headings + 1, cur.entries + int(is_entry),
                           cur.idless + int(not is_entry))
    return out


def census(roots: Sequence[str]) -> Tuple[Dict[int, Count], int, int]:
    """(per-level totals over every file, files counted, repos holding at least one file)."""
    totals: Dict[int, Count] = {}
    files = 0
    repos = set()
    for root in roots:
        for path in backlogs(root):
            files += 1
            repos.add(os.path.dirname(os.path.dirname(path)))
            for level, c in count_file(path).items():
                cur = totals.get(level, Count(0, 0, 0))
                totals[level] = Count(cur.headings + c.headings, cur.entries + c.entries,
                                      cur.idless + c.idless)
    return totals, files, len(repos)


def report(roots: Sequence[str], missing: Sequence[str], totals: Dict[int, Count],
           files: int, repos: int) -> List[str]:
    """The printed census. The ROOT SET comes first, because a count whose scope is unstated is not a
    measurement — every number below it is only true of the paths on that line."""
    out = ["ROOTS=%d pattern=%s" % (len(roots), PATTERN)]
    out += ["ROOT=%s" % r for r in roots]
    out += ["ROOT_MISSING=%s" % r for r in missing]
    out.append("FILES=%d REPOS=%d" % (files, repos))
    for level in LEVELS:
        c = totals.get(level, Count(0, 0, 0))
        out.append("LEVEL=%d headings=%d entries=%d idless=%d"
                   % (level, c.headings, c.entries, c.idless))
    tot = Count(sum(c.headings for c in totals.values()), sum(c.entries for c in totals.values()),
                sum(c.idless for c in totals.values()))
    out.append("TOTAL headings=%d entries=%d idless=%d" % tot)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(prog="backlog-census.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--roots", action="append", default=None,
                    help="literal directory path(s), `os.pathsep`-separated; repeatable. "
                         "`~` is expanded here. Default: " + " ".join(DEFAULT_ROOTS))
    ap.add_argument("--min-repos", type=int, default=1,
                    help="exit non-zero when fewer repos than this hold a backlog")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    roots, missing = expand_roots(a.roots if a.roots else list(DEFAULT_ROOTS))
    totals, files, repos = census(roots)
    lines = report(roots, missing, totals, files, repos)
    if a.json:
        print(json.dumps({"roots": roots, "missing": missing, "files": files, "repos": repos,
                          "levels": {str(k): v._asdict() for k, v in sorted(totals.items())}},
                         sort_keys=True))
    else:
        print("\n".join(lines))
    # AN EMPTY ROOT SET IS A FAILURE, not a census of nothing. This is the branch that catches an
    # unexpanded `~`, a typo and a glob the shell left literal — each of which otherwise prints a wall
    # of zeros and exits 0.
    if not roots:
        print("backlog-census: no root resolved to a directory (asked for: %s) — refusing to report a "
              "census of nothing, which is what an unexpanded `~` or a mistyped path looks like"
              % ", ".join(missing or ["<none>"]), file=sys.stderr)
        return RC_NO_ROOTS
    if repos < a.min_repos:
        print("backlog-census: %d repo(s) hold a backlog under those roots, --min-repos is %d"
              % (repos, a.min_repos), file=sys.stderr)
        return RC_TOO_FEW
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
