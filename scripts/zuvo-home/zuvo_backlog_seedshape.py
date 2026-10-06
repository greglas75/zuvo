"""HOW A SEED IS SHAPED so it cannot be told from a real row: the identity, the dialect, the body.

Split from `zuvo_backlog_seeds.py` at 406 raw lines against the 400-line default in
`rules/file-limits.md`, and the two halves are genuinely different questions. That file answers WHAT the
seeds are — which closures and which live lines this repo can prove — and this one answers whether a
dispatched row gives itself away. Every fix in this module came from one enumerating assertion
(`test-backlog-grooming.sh` W6b and the smoke suite's A3b) rather than from reading: a `chunk: null` no
real row can hold, `lineno: 0` against a queue that writes >= 1, an `fp:ffff…` key prefix the prose had
written down as a FEATURE, an `id` field holding a key where real rows hold a display id, a constant
`kind: checkbox` in chunks that contain no checkbox, and a one-key `keys` list among two-key rows.

THE LIMIT, stated because the include claims no more than this: a seed is indistinguishable by
INSPECTION OF THE DISPATCH. It is not indistinguishable against the repository — a verifier that greps
`backlog.md` for each row's id finds every real row and no seed, because a seed is not in the file. No
field can fix that; it is a property of synthesising rows at all. (d) therefore measures a verifier that
answers the rows it is given, which is the lane's actual job, and the suite asserts the dispatch-level
property it can actually hold.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. By importing the parser
this module joins the H19c pin-guard family, where its expectation is the default one: NO `iter_entries`
call lives here.
"""
import hashlib
import re
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

import zuvo_backlog_parse as zb
from zuvo_backlog_prepass import RC_QUEUE, refuse

Row = Dict[str, Any]

# The LAST maximal ALPHANUMERIC run of an id. A minted id is `B-A<YYYYMMDD>-<NNNNNN>`, so replacing
# only this run keeps the prefix, the date segment, the separators and the length — everything an
# observer could key on — and changes the one segment that is arbitrary anyway.
#
# ALNUM, NOT DIGITS. The first version matched digits, and a digit-less id (`B-skillmd-size-policy`,
# which is most of them) has none: `_shaped` returned "", no candidate was ever produced, and the nonce
# loop ran 65,536 times before refusing the whole chunk. The dogfood lane found it on chunk 1 of 10 —
# chunk 0 happened to hold no minted ids at all, so a one-chunk check would have reported success.
_TAIL_ALNUM_RE = re.compile(r"[0-9A-Za-z]+(?![\s\S]*[0-9A-Za-z])")
_LOWER = "abcdefghijklmnopqrstuvwxyz"


def _subst(ch: str, hexit: str) -> str:
    """One character of the same CLASS as `ch`, chosen by one hex digit of the material."""
    if ch.isdigit():
        return str(int(hexit, 16) % 10)
    if ch.islower():
        return _LOWER[int(hexit, 16) % 26]
    return _LOWER[int(hexit, 16) % 26].upper()


def _shaped(template: str, material: str) -> str:
    """`template` with its last alnum run replaced class-for-class ("" when it holds no alnum at all).

    Class-for-class rather than "random hex", so a display id and the key derived from it move together:
    the key is the lowercased id, and a per-character class map preserves exactly that relationship.
    """
    m = _TAIL_ALNUM_RE.search(template)
    if m is None:
        return ""
    run = template[m.start():m.end()]
    digest = hashlib.sha1(material.encode("utf-8")).hexdigest()
    while len(digest) < len(run):
        digest += hashlib.sha1(digest.encode("utf-8")).hexdigest()
    return template[:m.start()] + "".join(
        _subst(c, digest[i]) for i, c in enumerate(run)) + template[m.end():]


def seed_identity(chunk: int, n: int, body: str, taken: Set[str],
                  tpl: Optional[Row] = None) -> Tuple[str, str, List[str], str]:
    """(the row's `id`, the ANSWER key, every key the row answers to, the row's BODY) for one seed.

    FOUR VALUES FROM ONE FUNCTION, deliberately. The previous shape returned `(id, key)` and let
    `seed_row` recompute the key set with `keys_for` — two derivations of one fact, which diverged the
    moment a template's `id` turned out to be a KEY rather than a display id. `queue_row` writes
    `e.ident or e.key`, so a row whose `ident` is empty but whose text carries a `B-` id has `id` =
    `id:b-…`; shaping that produced an ident of `id:b-…`, and `entry_key` prefixed it again into
    `id:id:b-…`, which `_KEY_RE` rejects. The whole chunk then failed control (a) on its own seeds. One
    function now owns identity and hands back everything derived from it.

    THE HISTORY OF THE KEY'S SHAPE, because the prose was part of the defect. It was `fp:ffff%08x`,
    chosen so no real `sha1[:12]` could collide — achieved by making every seed key greppable in one
    pattern, and this module's docstring and `shared/includes/backlog-grooming.md` both CITED that
    prefix as the reason `interleave` exists ("`fp:ffff…` sorts after every real `fp:` key"). The
    ordering symptom was fixed and the value tell was written down and kept; one `grep fp:ffff` named
    all four graded rows, and the lane's declared tools include `Grep`. Nor is `fp:` a universal shape:
    against a chunk of minted `id:` keys, four `fp:` seeds are named by three characters. The seed
    copies a REAL key of its own chunk and rewrites only its last alnum run; collision avoidance lives
    in `taken`, a property of this dispatch, so it cannot double as a marker.
    """
    tpl_keys = [str(k) for k in ((tpl or {}).get("keys") or [])]
    tslug = next((k[3:] for k in sorted(tpl_keys) if k.startswith("id:")), "")
    if not tslug:
        # NO MINTED IDS IN THIS CHUNK. A real row's `id` is then its own CONTENT key, and so is the
        # seed's — there is no nonce to turn, because the key is a function of the text and the text is
        # what makes this seed this seed. A collision means two equivalent bodies, worth refusing.
        clean = _unidentified(body)
        keys = sorted(zb.keys_for(clean, ""))
        if keys and not set(keys) & taken:
            return keys[0], keys[0], keys, clean
        refuse(RC_QUEUE, f"chunk {chunk}: the seed's content key {keys[0] if keys else '<none>'} "
                         f"already names a row in this dispatch; a colliding seed key would attach a "
                         f"synthetic verdict to a real entry")
    tpl_id = str((tpl or {}).get("id", ""))
    # Is the template row's `id` a DISPLAY id or its own key? `queue_row` writes whichever it has, and a
    # seed has to write the same kind or the field tells them apart.
    id_is_key = tpl_id.startswith(("id:", "fp:"))
    # SHAPE THE DISPLAY ID, not the key's slug, whenever the template HAS a display id. `entry_key`
    # lowercases, so shaping `id:b-t3-alpha`'s slug yields `b-t3-…` while every real row's `id` reads
    # `B-t3-…` — one capital letter, shared by all four seeds and by no real row, which the affix probe
    # reported as `PREFIX id='b-t3-'`. `_shaped` substitutes class-for-class, so the display form and the
    # key it derives into stay in step on the same material.
    base = tslug if id_is_key else tpl_id
    for nonce in range(1 << 16):
        slug = _shaped(base, "seed|%d|%d|%d|%s" % (chunk, n, nonce, body))
        if not slug:
            break
        full = _with_ident(_unidentified(body), slug, tpl)
        keys = sorted(zb.keys_for(full, slug))
        key = next((k for k in keys if k.startswith("id:")), "")
        if key and not set(keys) & taken:
            return (key if id_is_key else slug), key, keys, full
    refuse(RC_QUEUE, f"chunk {chunk}: no seed identity outside the {len(taken)} keys already in this "
                     f"dispatch (template slug {tslug!r}); a colliding seed key would attach a "
                     f"synthetic verdict to a real entry")
    raise AssertionError("unreachable: refuse() exits")  # pragma: no cover


def _unidentified(body: str) -> str:
    """`body` with any leading `B-` id removed.

    A closed seed is a COPY of an archived entry's text, so it arrives carrying that entry's id — and
    `entry_key` reads an id out of the body when none is passed. The seed's "content key" was therefore
    the SOURCE entry's key: it collided with the real row (the dispatch refused outright, which is how
    this was found) and, worse, a seed that keeps a real id is a seed anyone can identify by looking the
    id up. The identity a seed gets must be the one this module mints for it, so the inherited one goes.
    """
    m = zb.BODY_ID_RE.match(body.strip())
    return body.strip()[m.end(1):].strip() if m else body.strip()


def _with_ident(body: str, ident: str, tpl: Optional[Row]) -> str:
    """`body` carrying `ident` the way the TEMPLATE row carries its own id, or unchanged.

    A real minted entry's text begins with its id, and `keys_for` returns TWO keys for exactly those —
    the `id:` one and the pre-mint content key. A seed whose body carried no id returned one key, so
    `len(keys)` told them apart in any repo where `plan` has minted. Composing the body the way a real
    entry is composed makes the two run through the same `keys_for` branch instead of being patched to
    agree.
    """
    if not ident or tpl is None or not zb.BODY_ID_RE.match(str(tpl.get("raw_text", "")).strip()):
        return body
    return "%s %s" % (ident, body)


def _kind_of(tpl: Optional[Row]) -> str:
    """The template row's dialect, or the checkbox default when the chunk offered no template."""
    return str((tpl or {}).get("kind") or zb.KIND_CHECKBOX)


def _template(pool: Sequence[Row], chunk: int, n: int) -> Optional[Row]:
    """One of the chunk's real ROWS, picked deterministically — None when the chunk has none.

    A row rather than a key, because `id` and `keys` must be shaped TOGETHER: shaping only the key left
    every seed's `id` prefixed `id:` while no real row's was.
    """
    if not pool:
        return None
    return pool[int(hashlib.sha1(("tpl|%d|%d" % (chunk, n)).encode("utf-8")).hexdigest(), 16)
                % len(pool)]
