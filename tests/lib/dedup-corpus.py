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
  NEGATIVE — two different ids citing the SAME file. Same-file pairs are the hard negatives: the
  cheap half of every dedup scheme here (basename equality) passes them, so a scorer that merely
  learns "same file ⇒ duplicate" scores 0.5 against this set rather than looking good.

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
    out = subprocess.run(["git", "-C", repo, "log", "--format=%H", "--", path],
                         capture_output=True, text=True, check=True).stdout.split()
    return out[::step][:limit]


def entries_at(repo, sha, path):
    text = subprocess.run(["git", "-C", repo, "show", f"{sha}:{path}"],
                          capture_output=True, text=True).stdout
    return list(zb.iter_entries(text, kinds=(zb.KIND_CHECKBOX, zb.KIND_BULLET, zb.KIND_HEADING)))


def build(repo, path, step, limit, min_drift, cap, seed):
    by_id = {}
    for sha in commits(repo, path, step, limit):
        for e in entries_at(repo, sha, path):
            if not e.ident:
                continue
            by_id.setdefault(e.ident.lower(), {})[deident(e.body)] = None

    rng = random.Random(seed)
    pos = []
    for ident, variants in by_id.items():
        vs = [v for v in variants if len(words(v)) >= 8]
        if len(vs) < 2:
            continue
        a, b = vs[0], vs[-1]
        wa, wb = words(a), words(b)
        jac = len(wa & wb) / max(1, len(wa | wb))
        if jac <= min_drift:
            pos.append((ident, a, b, jac))

    by_file = {}
    for ident, variants in by_id.items():
        newest = list(variants)[-1]
        for p in PATH.findall(newest):
            by_file.setdefault(os.path.basename(p).lower(), []).append((ident, newest))
    neg = []
    for base, rows in by_file.items():
        uniq = {i: t for i, t in rows}
        ids = sorted(uniq)
        for i in range(len(ids)):
            for j in range(i + 1, len(ids)):
                neg.append((base, uniq[ids[i]], uniq[ids[j]]))
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
    ap.add_argument("--min-drift", type=float, default=0.55,
                    help="keep a positive only when the two revisions' word Jaccard is <= this")
    ap.add_argument("--cap", type=int, default=60, help="at most N pairs per class")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--out", help="write the pairs as TSV (label, a, b)")
    a = ap.parse_args(argv)

    pos, neg = build(a.repo, a.path, a.step, a.limit, a.min_drift, a.cap, a.seed)
    print("positives (one id, two revisions, Jaccard <= %.2f): %d" % (a.min_drift, len(pos)))
    print("negatives (two ids, same cited file):               %d" % len(neg))
    if pos:
        print("  positive drift: min %.2f median %.2f max %.2f"
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
