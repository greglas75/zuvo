#!/usr/bin/env python3
"""Rebuild the measurement that decided control (c)'s words half: does it separate genuine citations
from fabricated ones? Run it against any repo that keeps a zuvo backlog:

    python3 tests/lib/overlap-corpus.py [--repo DIR] [--spans 5,10,20,40] [--far 100] [--fakes 5]

NOT a test, and deliberately not named `test-*.sh`/`test_*.py`: `tests/run-all.sh` globs those, and a
measurement whose numbers move with the backlog is not an assertion. It lives in `tests/lib/` beside
the other shared harnesses so the claim in `zuvo_backlog_overlap.py`'s docstring — and in
`shared/includes/backlog-grooming.md`'s control table — can be re-derived instead of believed.

THE CORPUS, which is the whole argument. An entry whose own text names `P:L`, where `P` resolves and
the file holds the line, yields two citations that differ ONLY in the line cited:

  GENUINE     (entry, P, L)       the line the entry itself points at. A verifier citing it is the
                                  canonical non-fabricated citation, and the row (c) must not refuse.
  FABRICATED  (entry, P, L_k)     the SAME file, `--fakes` lines drawn more than `--far` away. The
                                  basename half passes, because the file IS one the entry names, so
                                  this is the only fabrication left for the words half to catch: a
                                  real file at a line that has nothing to do with the entry.

Both populations come from the same entries and the same files and differ only in WHICH line is
cited, so a threshold that separates them is separating "about this entry" from "merely resolves".

WHAT IT PRINTS. Per window: the AUC (0.5 = a coin flip, ties at 0.5), then, per candidate threshold,
the share of GENUINE citations the threshold would refuse and the share of FABRICATIONS it would
accept. A gate needs both columns small at one row. On zuvo-plugin at 2026-10-10 the best row of the
best window is 0.624 balanced accuracy, and 6 of 29 genuine citations score zero — which is why the
words half reports and does not refuse.
"""
import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "scripts", "zuvo-home"))

import zuvo_backlog_overlap as zo    # noqa: E402
import zuvo_backlog_parse as zb      # noqa: E402
import zuvo_backlog_verdicts as zv   # noqa: E402


def auc(pos, neg):
    """P(a genuine citation scores above a fabricated one), ties counted as half. 0.5 = no signal."""
    if not pos or not neg:
        return float("nan")
    total = 0.0
    for a in pos:
        for b in neg:
            total += 1.0 if a > b else (0.5 if a == b else 0.0)
    return total / (len(pos) * len(neg))


def perm_p(pos, neg, rounds, seed):
    """P(an AUC this high from labels assigned at random). Shuffling the labels while keeping the two
    group SIZES is the null this measurement needs: "the window score tells the two apart" against
    "it does not". Reported because a weak-but-real signal and no signal at all call for the same
    decision here (report, do not refuse) for DIFFERENT reasons, and the next reader deserves to know
    which one this is before re-tightening a threshold."""
    observed = auc(pos, neg)
    pool = list(pos) + list(neg)
    rng = random.Random(seed)
    atleast = 0
    for _ in range(rounds):
        rng.shuffle(pool)
        if auc(pool[:len(pos)], pool[len(pos):]) >= observed:
            atleast += 1
    return atleast / rounds


def collect(tree, spans, far, fakes, seed):
    """{span: (genuine hit counts, fabricated hit counts)}, plus the citation count behind them."""
    gen = {s: [] for s in spans}
    fab = {s: [] for s in spans}
    rng = random.Random(seed)
    lines_in = {}
    cited = 0
    for src in (tree.real, tree.archive):
        try:
            text = open(src, encoding="utf-8").read()
        except OSError:
            continue
        for entry in zb.iter_entries(text):
            raw = getattr(entry, "raw_text", None) or getattr(entry, "body", "")
            _, words = zo.signature_parts(raw)
            if len(words) < 2:        # `ov=n/a` in the control, and unscoreable here for the same reason
                continue
            wset = set(words)
            for match in zb._PATH_RE.finditer(zb.strip_resolution_markers(raw)):
                path, _, lineno = match.group(0).partition(":")
                if not lineno.isdigit():
                    continue
                target = zv.resolve_cited(path, tree)
                if not target or not os.path.isfile(target):
                    continue
                if target not in lines_in:
                    with open(target, encoding="utf-8", errors="replace") as fh:
                        lines_in[target] = sum(1 for _ in fh)
                line, count = int(lineno), lines_in[target]
                if count == 0 or line > count:
                    continue
                away = [n for n in range(1, count + 1) if abs(n - line) > far]
                if len(away) < fakes:
                    continue             # too small a file to hold an unrelated line
                cited += 1
                # DRAWN ONCE, outside the span loop, so `--spans` cannot change which lines are
                # fabricated: with the draw inside, adding a window shifted the shared RNG and the
                # same repo reported two different AUCs for +/-5 depending on how many windows were
                # asked for. The same fabricated citations must be scored at every window anyway --
                # that is what makes the windows comparable.
                picked = rng.sample(away, fakes)
                for span in spans:
                    gen[span].append(len(wset & zo.window_words(target, line, span)))
                    for fake in picked:
                        fab[span].append(len(wset & zo.window_words(target, fake, span)))
    return gen, fab, cited


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", default=".")
    ap.add_argument("--spans", default="5,10,20,40")
    ap.add_argument("--far", type=int, default=100)
    ap.add_argument("--fakes", type=int, default=5)
    ap.add_argument("--seed", type=int, default=20261010)
    ap.add_argument("--perm", type=int, default=2000, help="permutation rounds; 0 skips the p-value")
    a = ap.parse_args(argv)

    # THE DIRECTORY AS GIVEN, deliberately NOT through `main_root`. The runtime helpers jump to the main
    # checkout because every checkout has to agree on one backlog; a measurement has the opposite need —
    # pointed at a worktree it must measure THAT worktree's file, or a branch's numbers silently become
    # the main checkout's and the two disagree in the same sentence.
    root = os.path.abspath(a.repo)
    tree = zv.Tree(root=root, real=os.path.join(root, "memory", "backlog.md"),
                   archive=os.path.join(root, "memory", "backlog-done.md"))
    spans = [int(x) for x in a.spans.split(",") if x.strip()]
    gen, fab, cited = collect(tree, spans, a.far, a.fakes, a.seed)
    print("repo=%s" % root)
    print("labelled citations=%d  genuine=%d  fabricated=%d (%d per genuine, >%d lines away)"
          % (cited, len(gen[spans[0]]), len(fab[spans[0]]), a.fakes, a.far))
    if not cited:
        print("NO CORPUS: no entry names a `path:line` that resolves — nothing to measure here")
        return 1
    for span in spans:
        g, f = gen[span], fab[span]
        tail = ""
        if a.perm:
            tail = "  permutation p=%.3f" % perm_p(g, f, a.perm, a.seed)
        print("\n=== window +/-%d   AUC=%.3f  (0.500 = coin flip)%s" % (span, auc(g, f), tail))
        print("  genuine    hits " + " ".join("%d:%-4d" % (k, g.count(k)) for k in range(9)))
        print("  fabricated hits " + " ".join("%d:%-4d" % (k, f.count(k)) for k in range(9)))
        print("  thr | genuine REFUSED | fabrication ACCEPTED | balanced acc")
        best = (0, 0.0)
        for thr in range(1, 9):
            refused = sum(1 for h in g if h < thr) / len(g)
            accepted = sum(1 for h in f if h >= thr) / len(f)
            bal = ((1 - refused) + (1 - accepted)) / 2
            best = max(best, (thr, bal), key=lambda t: t[1])
            print("   %d  |  %11.1f%% |  %15.1f%% | %.3f" % (thr, 100 * refused, 100 * accepted, bal))
        print("  best balanced accuracy %.3f at threshold %d" % (best[1], best[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
