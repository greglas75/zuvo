#!/usr/bin/env python3
"""A labelled corpus for "are these two backlog entries the same defect?", built from this repo's
own history — the question `backlog-add` answers structurally (CLASS|file|anchor) and the free-text
`lookup` cannot answer at all.

WHERE THE LABELS COME FROM, and what each is worth:

  POSITIVE — one entry, two revisions. An entry's TEXT is rewritten over its life (evidence added,
  severity re-argued, a resolution appended), while its B-id does not move. Two revisions of one id
  are therefore the same defect in different words BY CONSTRUCTION, which is the pair the signature
  key provably misses (backlog-protocol.md measured it: on five open/archived pairs the id matched
  5/5 and the content key 0/5).
  NEGATIVE — two different ids citing the SAME normalised path, minus any pair where one entry's own
  text names the other's id (the backlog itself calling them one defect; `deident` would erase that
  evidence and ship a true duplicate as a negative). Same-file pairs are the hard negatives: the cheap
  half of every dedup scheme here passes them. The trivial "same path ⇒ duplicate" scorer is REPORTED
  by `main` rather than assumed to sit at 0.5 — positives are revisions of one entry, so their path
  usually survives both sides, and a model earns nothing until it beats that printed number.

THREE LIMITS, stated because they bound every number this produces:
  1. The positives are revisions of an entry, not two independent filings of one defect. Independent
     filings are what the fix is for; they are not labelled anywhere yet (the findings ledger will
     carry them as `seen>1`, and it started on 2026-10-14 with no entries since).
  2. `--min-drift` selects positives whose two revisions SHARE FEW WORDS, to keep the set from being
     dominated by near-identical pairs. That makes it a hard subset on purpose, not a sample of the
     natural distribution: a model's score here is a lower bound on easy pairs.
  3. Both sides come from one repo's backlog, written largely by the same few agents, so the wording
     conventions are not independent draws.
"""
import argparse
import os
import random
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                "scripts", "zuvo-home"))
import zuvo_backlog_parse as zb                                    # noqa: E402

WORD = re.compile(r"[a-z0-9_]{3,}")
# THE ID MUST NOT TRAVEL WITH THE TEXT. A positive is two revisions of ONE id, so leaving the id in
# both sides hands the scorer the label: it would match `B-20261007-LEDGER-...` to itself and score
# near-perfectly while answering a question nobody asked. Every B-id is stripped from both sides of
# every pair, positive and negative alike — asymmetric stripping would be the same leak upside down.
ANY_ID = re.compile(r"\bB-[A-Za-z0-9][A-Za-z0-9._-]*", re.I)
PATH = re.compile(r"[\w./-]+\.(?:py|sh|ts|tsx|js|jsx|md|json|yml|yaml)")


def words(text):
    return set(WORD.findall(text.lower()))


def deident(text):
    """The entry's text with every B-id removed (see ANY_ID)."""
    return " ".join(ANY_ID.sub(" ", text).split())


def commits(repo, path, step, limit):
    # --reverse: `git log` is newest-first, so without it `variants[-1]` — read everywhere below as
    # "the newest revision" — was the OLDEST draft, and every negative was built from stale text.
    out = subprocess.run(["git", "-C", repo, "log", "--reverse", "--format=%H", "--", path],
                         capture_output=True, text=True, check=True).stdout.split()
    return out[::step][:limit]


def entries_at(repo, sha, path):
    text = subprocess.run(["git", "-C", repo, "show", f"{sha}:{path}"],
                          capture_output=True, text=True).stdout
    return list(zb.iter_entries(text, kinds=(zb.KIND_CHECKBOX, zb.KIND_BULLET, zb.KIND_HEADING)))


def build(repo, path, step, limit, max_similarity, cap, seed):
    by_id = {}
    for sha in commits(repo, path, step, limit):
        for e in entries_at(repo, sha, path):
            # An ORDINAL id is a position, not an identity: `B-70` labels a different entry every
            # time somebody numbers a fresh batch (zuvo_backlog_parse.ORDINAL_ID_RE exists for this,
            # and keying off ordinals produced 14 false pairs when the archiver first ran). Treating
            # two unrelated `B-70`s as one defect would manufacture positives out of nothing.
            if not e.ident or zb.ORDINAL_ID_RE.match(e.ident):
                continue
            by_id.setdefault(e.ident.lower(), {})[deident(e.body)] = " ".join(e.body.split())

    rng = random.Random(seed)
    pos = []
    for ident, variants in by_id.items():
        vs = [v for v in variants if len(words(v)) >= 8]
        if len(vs) < 2:
            continue
        a, b = vs[0], vs[-1]
        wa, wb = words(a), words(b)
        jac = len(wa & wb) / max(1, len(wa | wb))
        if jac <= max_similarity:
            pos.append((ident, a, b, jac))

    by_file = {}
    raw_of = {}
    for ident, variants in by_id.items():
        newest = list(variants)[-1]
        raw_of[ident] = variants[newest] or newest
        # The NORMALISED PATH, not the basename. `src/index.ts` and `tests/index.ts`, or any two of
        # the repo's `__init__.py`, are not the same file, and pairing them produced "hard negatives"
        # that no same-file scorer would ever have confused.
        for q in PATH.findall(newest):
            by_file.setdefault(q.lstrip("./").lower(), []).append((ident, newest))
    neg = []
    for base, rows in by_file.items():
        uniq = {i: txt for i, txt in rows}
        ids = sorted(uniq)
        for i in range(len(ids)):
            for j in range(i + 1, len(ids)):
                a_id, b_id = ids[i], ids[j]
                # An entry that NAMES the other id ("dup of B-…", "see B-…", "same root cause as") is
                # one the backlog itself already calls the same defect. `deident` erases exactly that
                # evidence, so without this the pair ships as a NEGATIVE and a scorer is punished for
                # being right — inflating every reported accuracy by an amount nobody measures.
                if a_id in raw_of[b_id].lower() or b_id in raw_of[a_id].lower():
                    continue
                neg.append((base, uniq[a_id], uniq[b_id]))
    rng.shuffle(pos)
    rng.shuffle(neg)
    return pos[:cap], neg[:cap]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".")
    ap.add_argument("--path", default="memory/backlog.md")
    ap.add_argument("--step", type=int, default=8, help="take every Nth commit touching the file")
    ap.add_argument("--limit", type=int, default=40, help="at most N commits")
    ap.add_argument("--max-similarity", "--min-drift", dest="max_similarity", type=float,
                    default=0.55, help="keep a positive only when the two revisions' word Jaccard is "
                    "<= this (it is a SIMILARITY ceiling: raising it admits easier pairs)")
    ap.add_argument("--cap", type=int, default=60, help="at most N pairs per class")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--out", help="write the pairs as TSV (label, a, b)")
    a = ap.parse_args(argv)

    pos, neg = build(a.repo, a.path, a.step, a.limit, a.max_similarity, a.cap, a.seed)
    # THE TRIVIAL BASELINE, MEASURED RATHER THAN CLAIMED. An earlier docstring asserted that a scorer
    # which only learns "same file => duplicate" scores 0.5 here. It does not: a positive is two
    # revisions of ONE entry, so its cited path usually survives both, and the trivial scorer calls it
    # DUP too. Printing the number is the difference between a confound that is controlled and one
    # that is merely mentioned — a model only beats this corpus if it beats the line below.
    def paths(s):
        return {q.lstrip("./").lower() for q in PATH.findall(s)}
    pos_same = sum(1 for _, x, y, _ in pos if paths(x) & paths(y))
    neg_same = len(neg)                                   # every negative is built from a shared path
    base_acc = ((pos_same / len(pos) if pos else 0) + (1 - neg_same / len(neg) if neg else 0)) / 2
    print("positives (one id, two revisions, Jaccard <= %.2f): %d" % (a.max_similarity, len(pos)))
    print("negatives (two ids, same cited file):               %d" % len(neg))
    print("same-cited-path baseline: %d/%d positives share a path, every negative does by construction"
          " -> balanced accuracy %.3f" % (pos_same, len(pos), base_acc))
    if pos:
        print("  positive similarity: min %.2f median %.2f max %.2f"
              % (min(p[3] for p in pos),
                 sorted(p[3] for p in pos)[len(pos) // 2],
                 max(p[3] for p in pos)))
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            for _, x, y, _ in pos:
                fh.write("DUP\t%s\t%s\n" % (x[:900].replace("\t", " "), y[:900].replace("\t", " ")))
            for _, x, y in neg:
                fh.write("NEW\t%s\t%s\n" % (x[:900].replace("\t", " "), y[:900].replace("\t", " ")))
        print("wrote %s (%d pairs)" % (a.out, len(pos) + len(neg)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
