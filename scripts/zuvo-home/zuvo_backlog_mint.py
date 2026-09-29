"""THE MINTED ID: its shape, and where on the line it goes. Imported by backlog-archive.py; not a
script, no shebang, no executable bit.

Its own module for the two reasons the other siblings are: backlog-archive.py measured 818 raw lines
with this inlined, past `rules/file-limits.md`'s automatic CQ11 FAIL at 2x the 400-line Python default
(the same line the block boundary and the heading policy had to be rescued from), and this is ONE
cohesive concern — the id's shape and its position are a single contract with `zb.MINTED_ID_RE` and
`zb.keys_for`, which strip exactly this prefix to recover the content key an entry had BEFORE it was
minted. Splitting the shape from the position is how one of them drifts. The underscore in the name is
load-bearing as in the siblings: `install.sh` flattens `scripts/zuvo-home/*` into `~/.zuvo/`, so a
plain same-directory import resolves identically in both layouts, and `sys.path` is the IMPORTER's job.

WHY ARCHIVING MINTS AT ALL is measured and recorded in backlog-archive.py's own docstring: on the
entries that sit in both files of the canonical backlog the id key matches 5/5 while the content key
matches 0/5, because closing an entry REWRITES its text. An entry archived without an id is therefore
unfindable by `lookup` for ever — which is why the failure mode this module refuses is a SILENT mint,
not a loud one.
"""
import hashlib
import re
import time
from typing import Optional

import zuvo_backlog_parse as zb


def mint_id(body: str) -> str:
    """Deterministic id for an entry being archived without one, so it stays addressable.

    The `B-A` prefix and the shape are `zb.MINTED_ID_RE`'s, not a convention: `keys_for` strips
    exactly that prefix to recover the content key the entry had BEFORE minting, and an id of any
    other shape leaves the archived entry findable only under its new id — the silent half of the
    2026-07 incident where one archive took the same three entries twice and neither guard saw it.
    """
    return "B-A" + time.strftime("%Y%m%d") + "-" + hashlib.sha1(body.encode()).hexdigest()[:6]


# WHERE a minted id goes, per dialect: after a checkbox prefix, or after a heading's hashes and the
# whitespace behind them. Both are `Entry.body`'s position 0, which is where `MINTED_ID_RE` is
# anchored. The heading alternative requires the `#`s at column 0 — an INDENTED `  ## B-x` is prose
# about an entry and never a definition (`zb._heading_parts`), so minting into one would write an id
# into text that is not an entry.
#
# HORIZONTAL WHITESPACE ONLY, `[ \t]` and never `\s`, and this is a MEASURED corruption rather than a
# tidiness rule. `\s*` matches `\n`: on a body-less or trailing-space ticked entry (`- [x]`, `- [x]   `,
# `- [x]\r\n`) the anchor swallowed the line ending and the id was written on a NEW line — leaving a
# `- [x]` with no id and an orphaned line holding only the id, in the file the archiver had just been
# told to rewrite. PRE-EXISTING, not introduced by the extraction: the expression this replaced
# (`^(\s*[-*]\s*\[[ xX]\]\s*)`) matches the newline identically, measured. Three cross-model providers
# found it; a same-model review of this file did not, because it probed CRLF, trailing spaces and level
# 6 headings but never a body-less tick.
_MINT_ANCHOR_RE = re.compile(r"^([ \t]*[-*][ \t]*\[[ xX]\][ \t]*|#{1,6}[ \t]+)")


def mint_into(line: str, minted: str) -> Optional[str]:
    """`line` with `minted` at its body position, or **None when it refuses** — never a silent no-op.

    Explicit slicing rather than a lambda in `re.sub`: at the call site the callback would close over
    the loop variable (ruff B023), correct there only by accident of evaluation order.

    THE REFUSAL IS THE POINT. Returning the line unchanged is D2 arriving through another door: the
    caller archives the entry anyway, so an id-less entry whose anchor missed lands in the archive with
    NO id — permanently unfindable by `lookup`, which is the failure this whole change exists to end.
    So two invariants are checked here, where the id is written, and either one refuses:
      * the anchor consumed no `\r` or `\n` — the FIX-1 class, pinned rather than only fixed;
      * `zb.MINTED_ID_RE` matches the text at the resulting body position, which is `line[m.end():]`
        for both dialects by construction of the anchor. That also catches a malformed `minted`.

    The checkbox branch is otherwise the pre-change expression, and the heading branch is additive.
    NOT REACHABLE FOR A HEADING TODAY: `cmd_archive` mints only `if not e.ident` and
    `zb._heading_entry` is id-anchored, so every heading ENTRY has an id. This closes the path, not the
    symptom — the day an id-less heading dialect is admitted, the mint lands where `keys_for` can strip
    it. `lead` keeps a body-less `- [x]` readable (`- [x] B-A…` rather than `- [x]B-A…`); it is empty
    for every line whose anchor already ends in whitespace, so the shapes with a body are untouched.
    """
    m = _MINT_ANCHOR_RE.match(line)
    if m is None or m.group(0)[-1:] in ("\n", "\r"):
        return None
    lead = "" if m.group(0)[-1:] in (" ", "\t") else " "
    out = line[:m.end()] + lead + minted + " " + line[m.end():]
    return out if zb.MINTED_ID_RE.match(out[m.end() + len(lead):]) else None
