#!/bin/sh
# Polyglot sh/python header — same reason as retro-mine.py: `#!/usr/bin/env python3` dies on
# Windows, so /bin/sh re-execs this file with whatever Python 3 the machine has, and Python reads
# the next line as a string literal and ignores it.
''''exec python3 -u "$0" "$@" #'''

"""Did a skill's follow-up actually run? Measure it, do not assume.

WHY THIS EXISTS. zuvo:review Phase 4 step 4 chains into zuvo:mutation-test: after the fix loop
commits, the review is supposed to mutation-test the tests covering what it just changed. Whether
that chain FIRES is a question about behaviour, not about the SKILL.md text — and answering it by
hand took ~20 minutes of reading runs.log with ad-hoc awk, twice, with a wrong field read on the
first attempt. Measured 2026-09-19, the first day the chain shipped: 1 of 14 reviews was followed
by a mutation-test in the same project.

WHAT IT MEASURES, AND WHAT IT CANNOT. It pairs a `review` row with a `mutation-test` row in the
SAME project inside a time window. That is a proxy: a pairing is strong evidence the chain fired,
and an unpaired review is NOT proof it did not — the trigger legitimately does not hold when the
fix loop committed nothing, when the diff touched no production or test file, or when the project
has no test runner. So read a low rate as "worth investigating", never as "agents are skipping it".
The one thing that would settle it per-run is the `mutation_chain:` field in the review's Validity
Gate, which is printed in chat and is not in runs.log — so it cannot be counted from here, and this
tool deliberately does not pretend otherwise.

  chain-adoption.py                       # last 7 days
  chain-adoption.py --since 2026-09-19    # from a date (or an ISO timestamp)
  chain-adoption.py --window 90           # widen the pairing window, minutes (default 45)
  chain-adoption.py --follower write-tests --leader review
  chain-adoption.py --json
"""

import argparse
import datetime
import json
import os
import sys

RUNS = os.path.join(os.environ.get("ZUVO_HOME", os.path.expanduser("~/.zuvo")), "runs.log")

# runs.log is a 13-column TSV; only the first three are needed here and they have been stable
# since the format was introduced. Reading by name rather than by a remembered index is the point:
# the one wrong number in this tool's own history came from counting the wrong column.
COL_DATE, COL_SKILL, COL_PROJECT = 0, 1, 2


def parse_ts(s):
    """ISO-8601 with a trailing Z, as append-runlog writes it. Returns None on anything else."""
    try:
        return datetime.datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")
    except (ValueError, TypeError):
        return None


def load_rows(path):
    rows = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line[:1].isdigit():      # header and any stray prose
                    continue
                f = line.rstrip("\n").split("\t")
                if len(f) <= COL_PROJECT:
                    continue
                t = parse_ts(f[COL_DATE])
                if t is None:
                    continue
                rows.append((t, f[COL_SKILL].strip(), f[COL_PROJECT].strip()))
    except OSError as e:
        sys.exit("chain-adoption: cannot read %s: %s" % (path, e.strerror))
    return rows


def main():
    ap = argparse.ArgumentParser(
        add_help=True,
        description="Measure whether a skill's chained follow-up actually runs.")
    ap.add_argument("--leader", default="review",
                    help="skill that should trigger the follow-up (default: review)")
    ap.add_argument("--follower", default="mutation-test",
                    help="skill it should chain into (default: mutation-test)")
    ap.add_argument("--since", default="", help="ISO date or timestamp; default is 7 days back")
    ap.add_argument("--window", type=int, default=45, help="pairing window in minutes (default 45)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    a = ap.parse_args()

    if a.window <= 0:
        sys.exit("chain-adoption: --window must be positive minutes")

    rows = load_rows(RUNS)
    if not rows:
        sys.exit("chain-adoption: no parseable rows in %s" % RUNS)

    if a.since:
        since = parse_ts(a.since if "T" in a.since else a.since + "T00:00:00")
        if since is None:
            sys.exit("chain-adoption: --since must be YYYY-MM-DD or an ISO timestamp, got %r" % a.since)
    else:
        since = max(t for t, _, _ in rows) - datetime.timedelta(days=7)

    scoped = [r for r in rows if r[0] >= since]
    leaders = [r for r in scoped if r[1] == a.leader]
    followers = [r for r in scoped if r[1] == a.follower]

    win = datetime.timedelta(minutes=a.window)
    paired, unpaired = [], []
    for t, _, proj in leaders:
        hit = next((ft for ft, _, fp in followers if fp == proj and t <= ft <= t + win), None)
        (paired if hit else unpaired).append((t, proj, hit))

    # A follower with no leader before it in the window is a STANDALONE run — someone invoked it
    # by hand. Counting those separately is what separates "the chain works" from "the user keeps
    # running it themselves", which is exactly the confusion this tool was written to end.
    standalone = [
        (t, proj) for t, _, proj in followers
        if not any(lp == proj and lt <= t <= lt + win for lt, _, lp in leaders)
    ]

    rate = (len(paired) * 100 // len(leaders)) if leaders else 0
    if a.json:
        print(json.dumps({
            "since": since.isoformat() + "Z", "window_minutes": a.window,
            "leader": a.leader, "follower": a.follower,
            "leader_runs": len(leaders), "follower_runs": len(followers),
            "paired": len(paired), "unpaired": len(unpaired),
            "standalone_followers": len(standalone), "pairing_rate_pct": rate,
        }, indent=2))
        return

    print("chain adoption: %s -> %s   since %s, window %dm"
          % (a.leader, a.follower, since.isoformat(), a.window))
    print("  %-22s %d" % (a.leader + " runs:", len(leaders)))
    print("  %-22s %d" % (a.follower + " runs:", len(followers)))
    print("  %-22s %d  (%d%%)" % ("paired:", len(paired), rate))
    print("  %-22s %d  — run by hand, no %s before them"
          % ("standalone followers:", len(standalone), a.leader))
    if unpaired:
        print("\n  unpaired %s runs (the trigger may legitimately not have held):" % a.leader)
        for t, proj, _ in unpaired[-15:]:
            print("    %s  %s" % (t.isoformat(), proj))
    print("\n  A pairing is evidence the chain fired; an unpaired run is NOT evidence it did not —")
    print("  the trigger needs a commit from the fix loop, a touched production/test file and a")
    print("  test runner. The per-run answer is the Validity Gate's mutation_chain field, which is")
    print("  printed in chat and never reaches runs.log, so it cannot be counted here.")


if __name__ == "__main__":
    main()
