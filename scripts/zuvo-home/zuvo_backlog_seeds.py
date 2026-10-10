"""CONTROL (d)'s SEEDS: the rows whose answer this repo already records, and the interleave that makes
them indistinguishable from real work. Imported by backlog-groom.py; not a script, no shebang, no
executable bit.

WHY THIS IS THE ONLY CONTROL THAT MEASURES JUDGEMENT. (a) shape, (b) resolvability and (c) keyword
overlap all ask whether a verdict is well-formed and grounded in a line that exists. None of them can
ask whether it is RIGHT — (c)'s own limit, stated in `shared/includes/backlog-grooming.md`, is that
citing the very line the entry names satisfies it while the verdict is still wrong. A seed can ask,
because the answer is already on record, and that is the whole reason K=4 rows of every chunk are spent
on work whose result is known.

WHY A SEED MUST BE INDISTINGUISHABLE, and why that shapes the file layout rather than only the prose.
Nothing in a dispatched seed row says it is one: `seed_row` emits exactly the queue's field set, the
expected verdict lives in a SEPARATE answer file the read-only agent is never pointed at, and
`interleave` mixes the seeds through the chunk by a stable hash instead of appending them, and a
verifier that can see which four rows are graded is being graded on four rows it can look up.

INDISTINGUISHABLE MEANS NO FIELD VALUE PARTITIONS THE DISPATCH, not that the field NAMES match. The
first version asserted name parity and shipped five tells anyway: `chunk: None` (no real row can hold
it), `lineno`/`end_lineno` of `0` (`queue_row` always writes >= 1) and a `fp:ffff…` key prefix — the
last one not overlooked but WRITTEN DOWN, here and in the include, as the reason `interleave` exists.
Fixing the ordering symptom while documenting the value tell is the shape of the mistake. The suite now
enumerates every field of a real dispatch and fails on any value held by exactly the seed rows, or on
any string prefix shared by all of them and by no real row.

WHY THE CLOSED SEEDS ARE STRIPPED, AND IN WHICH ORDER. A seed built from an archived entry's text
VERBATIM carries its own `FIXED <sha>` marker, so the answer is legible from the seed and (d) degrades
into a reading test — and the deterministic marker class would have decided it anyway.
`strip_resolution_markers` removes exactly that shrapnel, which leaves the agent the work the seed
exists to measure: find the fix. The ORDER is load-bearing: the id comes off FIRST, because stripping
markers eats the date out of a minted id and leaves `B- -cb8b1c` behind, which `BODY_ID_RE` can no
longer recognise. `build_seeds` records the measurement.

A SHORTFALL IS A REFUSAL AT THE CALLER, never a smaller K. A chunk dispatched with two seeds instead of
four is an under-gated chunk that reads identically to a gated one in every report, which is the one
failure this control cannot survive.

A SEED WHOSE ANSWER THE TREE NO LONGER SUPPORTS IS NOT A SEED, IT IS A TRAP. Measured on the first
live verify run (2026-10-06): 2 of the 4 known-answer misses were the seeds' fault. A closed seed is a
copy of an archived entry's prose, and some of those entries name only files that the very commit
closing them moved or deleted. The verifier is then asked to show `STALE-FIXED` about code that is not
there, answers `NOT-VERIFIABLE` — which is CORRECT about the repo — and is scored a miss. The control
whose entire job is measuring judgement was rewarding a guess over an honest abstention, and a
re-dispatch triggered by such a miss is a re-dispatch of a chunk nothing was wrong with.

So admissibility is checked HERE, at build time, against the tree the chunk is dispatched against:
`_closed_derivable` and `_live_derivable` below say why a candidate cannot be answered, the candidate
is DROPPED rather than counted against the agent, and the drop is REPORTED. Dropping interacts with
the K floor exactly as it should — a pool that cannot yield K admissible seeds produces a shortfall,
and a shortfall is already a refusal. Filtering happens BEFORE the slice, not after: taking the first
K candidates and then dropping the bad ones would refuse a repo with 75 archived entries because two
of the first two were inadmissible.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, exactly as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. `sys.path` is the
IMPORTER's job. By importing the parser this module joins the pin-guard family that
`tests/hooks/test-backlog-headings.sh` (H19c) DERIVES, where its expectation is the default one: NO
`iter_entries` call lives here.
"""
import hashlib
import json
import os
from typing import Any, Dict, List, Sequence, Set, Tuple

import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb
# The identity, the dialect and the body composition that make a dispatched seed
# indistinguishable, extracted whole for the 400-line reason its docstring records.
import zuvo_backlog_seedadmit as zsa
import zuvo_backlog_seedshape as zsh
import zuvo_backlog_verdicts as zv
from zuvo_backlog_prepass import RC_QUEUE, refuse

Row = Dict[str, Any]                 # a queue row, as in the siblings that say so of their own
SEEDS_PER_CHUNK = 4                  # K=4, 2 provably fixed and 2 provably still real
SEED_SECTION = "Open"                # a seed's `section`, and it is a PLAUSIBLE one on purpose. The
                                     # first version put a literal "zuvo-seed" marker there — a field
                                     # of the DISPATCHED row — so `jq 'select(.section=="zuvo-seed")'`
                                     # named all four graded rows. Measured by the assertion that greps
                                     # the dispatch for a marker; the control it gates was a lookup.


def _candidates(root: str, rel: str, want: int) -> List[Tuple[str, int, str]]:
    """The first `want` quotable lines of ONE tracked file: at least four words, and no `"` or `|`.

    The two excluded characters are not fastidiousness — `|` is `normalize_signature`'s own field
    separator, and a quote inside the seed's prose would land inside the evidence clause a verifier
    quotes back, where it reads as the end of it.
    """
    try:
        with open(os.path.join(root, rel), encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    out = []
    for n, text in enumerate(lines, start=1):
        if len(text.split()) >= 4 and '"' not in text and "|" not in text:
            out.append((rel, n, text))
            if len(out) >= want:
                break
    return out


def live_anchors(root: str, want: int) -> List[Tuple[str, int, str]]:
    """(path, line, text) triples from the tree AS IT STANDS — the `STILL-REAL` half of the seeds.

    `git ls-files`, SORTED, so the same tree yields the same anchors on every run: a seed that moved
    between two dispatches would make a re-dispatch decision unreproducible, and (d) is the one control
    whose entire value is that a miss is attributable.

    TWO PASSES, one line per file and then a second, because one-per-file alone made the seed count a
    function of how many tracked `.py`/`.sh`/`.md` files a repo has. Measured on a 2-file fixture: it
    derived ONE live anchor, the dispatch refused on the shortfall, and the refusal was about the
    fixture's size rather than about anything the control cares about. Diversity still comes first — a
    second line of the same file is only reached when the tree cannot spread them.
    """
    files = [rel for rel in sorted((zb.sh(["git", "ls-files"], cwd=root) or "").split("\n"))
             if rel and rel.endswith((".py", ".sh", ".md"))]
    out: List[Tuple[str, int, str]] = []
    for depth in (1, 2):
        for rel in files:
            got = _candidates(root, rel, depth)
            if len(got) >= depth:
                out.append(got[depth - 1])
            if len(out) >= want:
                return out
    return out


# Fields a DISPATCHED row does not carry. `lineno`/`end_lineno` were a seed tell (`0` against
# `queue_row`'s >= 1), and the fix is not a plausible fake: their only reader is `plan`'s chunk
# line-range summary, which reads the QUEUE, and the verifier contract never documented them. A field
# no consumer needs cannot leak what it does not travel in — and this list lives beside `seed_row`
# rather than in the CLI because "what the graded party can see" is this module's concern.
DISPATCH_DROP: Tuple[str, ...] = ("lineno", "end_lineno")


def dispatch_view(rows: Sequence[Row]) -> List[Row]:
    """The rows as the verifier lane receives them, with `DISPATCH_DROP` removed from EVERY row.

    Applied to seeds and real rows alike, because a field dropped from only one side is the tell it was
    meant to remove.
    """
    return [{k: v for k, v in r.items() if k not in DISPATCH_DROP} for r in rows]


def interleave(rows: Sequence[Row], salt: str) -> List[Row]:
    """The dispatch order: a STABLE hash of (salt, key), so the seeds sit among the real rows.

    Deterministic, because two dispatches of one chunk have to be the same dispatch; and not the key's
    own order, because `fp:ffff…` sorts after every real `fp:` key and would park all four seeds in one
    block at the end of the file.
    """
    def rank(row: Row) -> str:
        key = str((row.get("keys") or [row.get("id", "")])[0])
        return hashlib.sha1((salt + "|" + key).encode("utf-8")).hexdigest()
    return sorted(rows, key=rank)


def seed_row(sid: str, keys: Sequence[str], body: str, section: str, chunk: int, kind: str) -> Row:
    """One seed, shaped EXACTLY like a queue row — `mark`/`expect` live in the answer key, never here.
    A dispatched row a model can tell is a seed gates nothing; it becomes a lookup.

    `id` AND `keys` FOLLOW `queue_row`'S OWN RULES, which is the only form of this that holds up. `id`
    was the minted key, while a real row carries `e.ident or e.key` — the DISPLAY id (`B-T0-alpha`), with
    no `id:` prefix. So in any repo whose entries carry ids, every seed's `id` began `id:` and no real
    row's did. `keys` came as a one-element list where `queue_row` emits `sorted(keys_for(...))`, often
    two. Both are now produced by the same `keys_for` the real rows go through, so the shapes cannot
    diverge by being written twice. This repo hid the first one completely: all 263 mint-set entries are
    the bullet dialect, `mintable` is 0, so `e.ident` is empty and `id` is the `fp:` key on BOTH sides.
    A fixture with ids found it immediately — which is the argument for the enumerating assertion over
    any amount of reading.

    `kind` COMES FROM THE TEMPLATE ROW, like `section` does. It was the constant `KIND_CHECKBOX`, and
    the dialects are not evenly spread: 4 of this repo's 10 chunks hold no checkbox entry at all, so in
    those `kind` named the four graded rows exactly. "Checkbox is the majority dialect so it is
    plausible" is true of the FILE and false of the CHUNK, which is the unit a verifier sees.

    `chunk` IS THE REAL CHUNK NUMBER. It was `None`, and `cmd_dispatch` selects real rows on
    `r["chunk"] == a.chunk`, so no real row in a dispatch could ever hold it: one
    `jq 'select(.chunk==null)'` named all four graded rows. Field-NAME parity (what the first version
    asserted) is not indistinguishability; a field whose VALUE no real row can hold is the same lookup
    with an extra step.

    NO `lineno`/`end_lineno`. They were `0` while `queue_row` always writes >= 1 — the same defect
    twice more. They are not merely faked here: `cmd_dispatch` drops them from EVERY dispatched row,
    because the only reader is `plan`'s chunk line-range summary, which reads the QUEUE, and the
    verifier contract never documented them. A field no consumer needs cannot leak what it does not
    travel in.
    """
    return {"id": sid, "keys": list(keys), "text_sha": zl.text_sha(body),
            "raw_text": body if body.endswith("\n") else body + "\n",
            "section": section, "cited_paths": zv.cited_paths(body),
            "kind": kind,
            "bytes": len(body.encode("utf-8")), "chunk": chunk, "reused": False,
            "verdict": None, "evidence": None, "verified_by": None}


def _one(chunk: int, n: int, body: str, pool: Sequence[Row], claimed: Set[str], section: str,
         answers: Dict[str, str], verdict: str) -> Row:
    """ONE seed row, recording its expected verdict in `answers` and its key in `claimed`.

    Both halves of `build_seeds` went through the same six lines twice; the composition below (template
    -> identity -> body carrying that identity -> row) has to be identical on both or the two halves of
    control (d) become distinguishable from each other, never mind from the real rows.
    """
    tpl = zsh._template(pool, chunk, n)
    sid, key, keys, full = zsh.seed_identity(chunk, n, body, claimed, tpl)
    claimed.update(keys)
    answers[key] = verdict
    return seed_row(sid, keys, full, section, chunk, zsh._kind_of(tpl))


def build_seeds(chunk: int, closed: Sequence[str], live: Sequence[Tuple[str, int, str]],
                peers: Sequence[Row] = (),
                k: int = SEEDS_PER_CHUNK,
                section: str = SEED_SECTION,
                *, tree: zv.Tree) -> Tuple[List[Row], Dict[str, str], str, List[str]]:
    """(seed rows, key -> expected verdict, a SHORTFALL message — "" when fully seeded, the DROPS).

    `tree` IS KEYWORD-ONLY AND HAS NO DEFAULT, on purpose. It is what admissibility is checked against,
    and a default of `None` would let a caller that had not been updated build seeds with the check
    switched off — silently, which is the one way this control fails. A missing argument is a
    `TypeError` at the call site instead.

    The shortfall is a plain STRING and not this family's `Reject`, which is what keeps this module out
    of an import cycle with `zuvo_backlog_agent`: that one checks the ANSWERS at ingest and owns the
    rejection vocabulary, this one builds the rows at dispatch. The caller wraps the message.

    Half `STALE-FIXED`, half `STILL-REAL`, both derived from what this repo RECORDS rather than from a
    hand-written fixture:

      * `closed` — entry texts the archive already holds, with their resolution markers STRIPPED. The
        closure is provable (it is in `backlog-done.md`); stripping the marker is what stops the answer
        being legible from the seed's own text, which would make (d) a reading test.
      * `live` — (path, line, text) triples from the tree as it stands, phrased as an entry about that
        line. Provably still real, because the line is there.

    A SHORTFALL IS A REFUSAL, not a smaller K. A chunk dispatched with no seeds is an UNGATED chunk,
    and it looks exactly like a gated one in every report — the one failure this control cannot
    survive. A repo with no recorded closures therefore cannot self-seed, and the dispatch REFUSES;
    there is no flag that lowers K, because a flag an agent can type is not a control.

    K IS FLOOR-CHECKED HERE, not only at the caller. The shortfall used to be measured against the
    REQUESTED `k`, so `--seeds 2` produced two seeds, no shortfall and a reported pass — exactly the
    under-gated chunk the paragraph above calls the one failure this control cannot survive. `--seeds`
    is gone, and this floor means no in-process caller can reintroduce it either.
    """
    if k < SEEDS_PER_CHUNK:
        refuse(RC_QUEUE, f"chunk {chunk}: K={k} is below the floor of {SEEDS_PER_CHUNK}; a chunk "
                         f"dispatched with fewer seeds is an UNDER-GATED chunk that reads identically "
                         f"to a gated one in every report")
    want = k // 2
    # ADMISSIBILITY BEFORE THE SLICE — see the module docstring. A candidate whose expected verdict the
    # dispatched tree cannot support is dropped and reported, never counted against the agent.
    dropped: List[str] = []
    ok_closed: List[str] = []
    for body in closed:
        if len(ok_closed) >= want:
            break
        # The body AS DISPATCHED, composed once here instead of inside the row loop, because the
        # admissibility question is about the text the verifier actually receives.
        #
        # IDENTITY FIRST, MARKERS SECOND, and the order is the whole fix for the amputated-fragment
        # seed. `strip_resolution_markers` runs `DATE_RE` over the text, which eats the date out of a
        # MINTED id — `B-A20261007-cb8b1c` becomes `B- -cb8b1c` — and `BODY_ID_RE` then no longer
        # recognises it as an id, so `_unidentified` leaves the wreckage at the front of the seed:
        #
        #     B- -cb8b1c - [B-secaudit-2] pentest SCA preflight (0.5b): snippet is advisory; 4 adversa…
        #
        # which is indistinguishable from the metadata continuation lines this backlog is full of, and
        # is the text the first live run's verifier was asked to produce a STALE-FIXED about (it
        # answered NOT-VERIFIABLE and was scored a miss). Measured on the main checkout's archive:
        # 40 of 55 closed-seed candidates carried that residue; reversing the two calls leaves 0,
        # because the id is matched and removed while it is still intact.
        seed_body = zb.strip_resolution_markers(zsh._unidentified(body))
        why = zsa.closed_derivable(seed_body, tree)
        if why:
            # ONE LINE per drop, because `print_drops` writes one `SEED_DROP=` per entry and an
            # embedded newline would split a reason across two records a reader greps separately.
            dropped.append("closed candidate %r: %s" % (" ".join(seed_body.split())[:48], why))
        else:
            ok_closed.append(seed_body)
    ok_live: List[Tuple[str, int, str]] = []
    for anchor in live:
        if len(ok_live) >= k - want:
            break
        why = zsa.live_derivable(anchor, tree)
        if why:
            dropped.append("live candidate %s:%d: %s" % (anchor[0], anchor[1], why))
        else:
            ok_live.append(anchor)
    rows: List[Row] = []
    answers: Dict[str, str] = {}
    # The chunk's real keys, derived HERE so the caller never has to know the extraction rule, and
    # grown as keys are minted so two seeds of one chunk cannot collide with each other either.
    claimed = {str(key) for row in peers for key in (row.get("keys") or [row.get("id", "")])}
    # The shape pool: this chunk's own keys, indexed by a hash so the pick is spread rather than biased
    # toward whichever shape sorts first (`fp:` does). A mixed chunk therefore gets a mixed seed set.
    pool = sorted(peers, key=lambda r: str(r.get("id", "")))
    for i, seed_body in enumerate(ok_closed):
        rows.append(_one(chunk, i, seed_body,
                         pool, claimed, section, answers, zl.VERDICT_STALE_FIXED))
    for j, (path, line, text) in enumerate(ok_live):
        rows.append(_one(chunk, want + j,
                         "%s:%d still reads %s" % (path, line, " ".join(text.split()[:8])),
                         pool, claimed, section, answers, zl.VERDICT_STILL_REAL))
    short = "" if len(rows) == k else (
        "chunk %d: only %d of %d seed(s) could be derived (%d closed, %d live; %d candidate(s) dropped "
        "as underivable at this commit) — a chunk with fewer seeds is an UNGATED chunk and reads "
        "identically to a gated one"
        % (chunk, len(rows), k, len(ok_closed), len(ok_live), len(dropped)))
    return rows, answers, short, dropped


def print_drops(dropped: Sequence[str]) -> None:
    """`SEEDS_DROPPED=<n>` and one `SEED_DROP=<why>` per dropped candidate, on stdout.

    It lives here rather than at the CLI for the reason the module docstring gives: a chunk seeded from
    a pool that quietly lost half its candidates is a DIFFERENT measurement from one that did not, and
    `SEEDS=` alone cannot tell the two apart — so the reporting belongs with the dropping. It also
    keeps `backlog-groom.py` under rules/file-limits.md's 400 lines, which the four lines it replaces
    had just pushed it past.
    """
    print("SEEDS_DROPPED=%d" % len(dropped))
    for why in dropped:
        print("SEED_DROP=%s" % why)


def read_answers(path: str) -> Dict[str, str]:
    """The answer key read back, or a refusal.

    It lives beside `build_seeds` — the function that MINTS this file — so the writer and the reader
    cannot disagree about its shape. It arrived here from `backlog-groom.py`, which measured 403 raw
    lines once `render` and `--fleet` landed, against rules/file-limits.md's 400-line default.

    AN UNREADABLE KEY IS NOT AN EMPTY ONE. Returning `{}` would make control (d) pass every chunk,
    silently, and the run would look exactly like a gated one in every line of its report — which is
    the single failure this control cannot survive.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            obj = json.load(fh)
    except (OSError, ValueError) as exc:
        refuse(RC_QUEUE, f"cannot read the seed answer key {path} ({exc}); an unreadable key would "
                         f"make control (d) pass every chunk while reporting that it ran")
    if not isinstance(obj, dict) or not obj:
        refuse(RC_QUEUE, f"{path} holds no seed answers, so control (d) would gate nothing")
    return {str(k): str(v) for k, v in obj.items()}
