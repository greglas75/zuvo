"""THE READ MODEL: the shape both backlog files are parsed INTO, the derived counts about the
entry-shaped lines the parser did NOT yield, and where this checkout's output goes. Imported by
backlog-groom.py; not a script, no shebang, no executable bit.

WHAT DELIBERATELY DID NOT TRAVEL HERE, and it is the most important line in this file: the
`iter_entries` CALLS. `load()` and the mint's count-neutrality re-parse stay in `backlog-groom.py`,
and not for taste — `tests/hooks/test-backlog-headings.sh` (H19c) DERIVES its pin-guard family as
"the archiver plus every `zuvo_backlog_*.py` that imports the parser" and holds a per-file expectation
for each member, with an AC4' total over the family: exactly 8 unconditionally-pinned calls, 2 unpinned
readers and exactly ONE env-gated heading request, which lives in `zuvo_backlog_heading.py` because
archiving a heading MOVES LINES across 88 checkouts. This command's reads legitimately ask for
`KIND_HEADING` (a heading entry IS an entry, and leaving the 91 of them out would make `groom`'s "every
entry is verified" refusal a statement about a subset) and they ask for it through a `KINDS` constant,
which is an indirection the guard cannot read at the call site. MEASURED: moving `load()` in here put
`0 2 load,load 0 0 -` in front of that guard and pushed the family total to 8/4/1, turning a
fleet-wide safety invariant red. Two ways out — widen the invariant, or leave the call sites in the
command — and only the second one leaves PR 1's guard saying what it was built to say. So this module
holds the model and the derivations; the act of parsing stays where the guard can see its selection.

WHY ITS OWN MODULE, and the number is the argument rather than the taste. `backlog-groom.py` measured
**416 raw lines** once `apply` landed, past `rules/file-limits.md`'s 400-line default for a Python
module (800 is the automatic CQ11 FAIL) — the same ceiling that already moved the block boundary, the
heading policy and the mint out of `backlog-archive.py`, the mint pre-pass out of this command and the
dispositions into `zuvo_backlog_apply.py`. Trimming the prose to fit was the alternative and it is the
wrong one: every paragraph here is a measurement someone paid for.

It is ONE cohesive concern — which two files, which dialects, whose line indices, and which output
directory — and that concern is READ-ONLY. Nothing in this module writes; every write in the family
happens under `zio.Lock` against a RE-READ of the same path, in the module that owns the write.

EVERYTHING IS RE-EXPORTED BY NAME from `backlog-groom.py` rather than reached through a `zgl.` prefix,
for the reason the pre-pass extraction records: the suite's probe loads `backlog-groom.py` by path and
looks these up ON IT, and a mutant of this module must be the one the command imports. `sys.path` is
the IMPORTER's job, as in every sibling; the underscore in the filename is load-bearing because
`install.sh` flattens `scripts/zuvo-home/*` into `~/.zuvo/`. By importing the parser this module joins
the pin-guard family `tests/hooks/test-backlog-headings.sh` (H19c) DERIVES, where its expectation is
the DEFAULT one: no `iter_entries` call at all lives here, which is what the paragraph above is about.
"""
import os
from typing import List, NamedTuple, Tuple

import zuvo_backlog_parse as zb


class Loaded(NamedTuple):
    """Both backlog files, parsed once. `lines` is `splitlines(keepends=True)` over `zio.read`, so the
    indices agree with `Entry.lineno` and `entry_block` measures spans over the same list.

    These are the PARSE lines, not the write lines. `zio.read` opens with the default `newline=None`,
    so universal-newline translation has already turned any `\r\n` into `\n` — which is harmless for
    counting and for spans, and would silently rewrite a CRLF backlog if it were used for the write.
    The locked write therefore re-reads through `zuvo_backlog_prepass.read_raw()`; that split is
    deliberate, not an oversight, and `read_raw`'s docstring carries the measurement.
    """

    real: str
    archive: str
    root: str
    lines: List[str]
    entries: List[zb.Entry]
    archived: List[zb.Entry]


def zuvo_dir(repo: str) -> str:
    """`$ZUVO_DIR` per shared/includes/report-output-location.md: the override verbatim, else the git
    root of `--repo` plus `/zuvo`, else the directory itself.

    The GIT ROOT of the argument, not `main_root`: the queue is this checkout's working state, while
    `main_root` deliberately jumps to the MAIN worktree so that six checkouts share ONE backlog. A
    queue written there would be overwritten by whichever worktree ran last.
    """
    override = os.environ.get("ZUVO_OUTPUT_DIR", "")
    if override:
        return override
    return os.path.join(zb.sh(["git", "rev-parse", "--show-toplevel"], cwd=repo) or repo, "zuvo")


def idless_headings(loaded: Loaded) -> List[Tuple[int, str]]:
    """Heading-shaped lines that `iter_entries` did NOT yield as entries — REPORTED, never minted.

    They are not a subset of the entries and they are not a defect: nine of the 26 here are plain
    section headers (`## benchmark skill`, `## 2026-04-17 zuvo:leads Task 1 (schema include)`), which
    is what a backlog's structure looks like. The mint set is defined by what the parser yields, so
    this list exists to be LOOKED at rather than to be acted on.
    """
    yielded = {e.lineno for e in loaded.entries}
    return [(i, ln.rstrip("\r\n")) for i, ln in enumerate(loaded.lines, start=1)
            if i not in yielded and zb.HEADING_RE.match(ln.rstrip())]


def template_lines(loaded: Loaded) -> int:
    """How many entry-shaped lines the parser dropped as TEMPLATE_RE matches. Counted so "a template
    is not an entry" is an observable number rather than an invisible absence."""
    return sum(1 for ln in loaded.lines
               if zb.TEMPLATE_RE.search(zb.body_of(ln.strip()))
               and (zb.CHECK_LINE_RE.match(ln.strip()) or zb.HEADING_RE.match(ln.rstrip())))
