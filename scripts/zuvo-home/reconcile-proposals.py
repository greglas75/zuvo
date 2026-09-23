#!/bin/sh
# Polyglot sh/python header — see compute-preload for why this exact line matters on Windows.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
"""Apply verified proposal verdicts to the digest-proposals disposition ledger.

Why this exists. `digest-proposals` ranks change-proposals by how many distinct retros asked for
the same change, and the top of that list is supposed to be the most valuable open work. It had
never been reconciled against the files it names, so proposals implemented long ago kept
re-surfacing at the top — measured 2026-09-22 on a sample of six above-bar items: FIVE were
already done, including the two highest-ranked entries in the whole registry (mutation-test's
Phase 3.2b at x48 and ship's Phase 4 PR flow at x43).

That is worse than untidy. A list whose first five rows are finished work teaches its reader to
stop reading it, and the genuinely open items below them go unread with it — which is exactly
how one defect sat through 47 retros asking for it.

Reconciling means deciding, per proposal, whether the target file already does the thing. That
judgement does not automate: it is a read of prose against prose. What DOES automate, and what
this script is, is applying a batch of those judgements to the ledger without hand-transcribing
several hundred `--mark` invocations — and refusing the ones that do not typecheck.

Input is TSV, one line per proposal, as produced by a verification pass:

    <section>\\t<VERDICT>\\t<evidence>

`<section>` must match the ledger key byte-for-byte; a retyped or re-spaced section is a
different proposal and this script will say so rather than mark the wrong row. Verdicts map to
dispositions:

    COVERED     -> covered     (the file already does it)
    SUPERSEDED  -> covered     (solved a better way; the note says what replaced it)
    OPEN        -> (no-op)     stays open, which is the point
    PARTIAL     -> (no-op)     part of it is real work; leave it visible
    UNCLEAR     -> (no-op)     a proposal nobody can test is not a proposal that is done

Only COVERED and SUPERSEDED are written. The three no-op verdicts are counted and reported, so a
run says how much of the list survived the audit rather than only how much it removed.

Usage:
  reconcile-proposals.py --file skills/ship/SKILL.md --verdicts <f.tsv> --ref <tag> [--apply]
  reconcile-proposals.py --manifest <dir-of-tsv>/ --ref <tag> [--apply]

Dry-run by default: it prints what it would mark and exits. `--apply` writes.
"""
import argparse
import json
import os
import subprocess
import sys

WRITE = {"COVERED": "covered", "SUPERSEDED": "covered"}
NOOP = ("OPEN", "PARTIAL", "UNCLEAR")
HELPER = os.path.expanduser("~/.zuvo/digest-proposals")


PATH_PREFIXES = ("skills/", "shared/", "scripts/", "hooks/", "tests/", "docs/", "rules/",
                 "ci/", "evals/", "website/", "memory/", "~/", "/")
PATH_SUFFIXES = (".md", ".sh", ".py", ".json", ".yml", ".yaml", ".mjs", ".ts", ".toml")


def _looks_like_path(field):
    """Is this first TSV field a target FILE, or the start of a section name?

    Only ever asked when the caller did NOT pass --file, i.e. for a batch spanning several
    targets. Inside a single-file batch the question is not asked at all, because it cannot be
    answered: section names legitimately look like paths. Two real examples from this repo's own
    backlog, both sections of skills/ship/SKILL.md, both of which a shape test gets wrong —
    `Phase 3 / tag collision` (has a slash) and `memory/last-ship.json` (is a path, verbatim).
    Guessing there shifted rows one field left and silently dropped them; the applied count
    disagreeing with the verdict file's own tally is what surfaced it.
    """
    f = field.strip()
    if not f or " " in f:
        return False
    return f.startswith(PATH_PREFIXES) or f.endswith(PATH_SUFFIXES)


def known_sections(target_file):
    """The sections the ledger actually holds for this file, straight from the helper.

    Checking against this BEFORE marking is what makes a typo loud. `digest-proposals --mark`
    creates a ledger row for whatever key it is handed, so a mistyped section does not fail — it
    silently disposes of a proposal that does not exist while leaving the real one open. That is
    the failure this whole script exists to stop, arriving through the fix for it.
    """
    try:
        out = subprocess.run([HELPER, "--all", "--json"], capture_output=True, text=True,
                             timeout=300)
        # The exit status is part of the answer. Without this check a helper that fails while
        # printing nothing yields `[]`, which reads as "this file has no proposals" — every row
        # is then rejected as a typo and --apply marks nothing while printing what look like
        # content errors. An empty stdout from a FAILED call is not an empty ledger.
        if out.returncode != 0:
            raise RuntimeError("helper exited %d: %s"
                               % (out.returncode, (out.stderr or "").strip()[:200]))
        rows = json.loads(out.stdout or "[]")
    except Exception as exc:
        sys.stderr.write("reconcile: cannot read the proposal list (%s)\n" % exc)
        return None
    return {r["section"] for r in rows if r.get("file") == target_file}


def read_verdicts(path, multi):
    rows, bad = [], []
    # Guarded because the sibling helper in this directory already is: digest-proposals'
    # read_ledger() catches its own file errors on the principle that "a corrupt ledger must
    # never break reporting". A mistyped --verdicts path or a file deleted between runs is
    # ordinary misuse of a batch tool, and answering it with a raw traceback tells the caller
    # nothing about which path was wrong.
    try:
        fh = open(path, encoding="utf-8")
    except OSError as exc:
        sys.stderr.write("reconcile: %s: %s\n" % (path, exc.strerror or exc))
        return None, []
    with fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line.strip():
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                bad.append((n, "not TSV with >=2 fields", line[:80]))
                continue
            # Two shapes, because a batch may cover one target file or several. A row whose
            # FIRST field looks like a repo path carries its own target; otherwise the target
            # comes from --file. Guessing wrong here would mark a proposal on the wrong file,
            # so the test is the path shape, not the field count.
            rowfile = None
            if multi and _looks_like_path(parts[0]):
                rowfile, parts = parts[0], parts[1:]
                if len(parts) < 2:
                    bad.append((n, "file-qualified row with no verdict", line[:80]))
                    continue
            section, verdict = parts[0], parts[1].strip().upper()
            note = parts[2].strip() if len(parts) > 2 else ""
            if verdict not in WRITE and verdict not in NOOP:
                bad.append((n, "unknown verdict %r" % verdict, section[:60]))
                continue
            rows.append((rowfile, section, verdict, note))
    return rows, bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", help="the proposal target file the verdicts are about")
    ap.add_argument("--verdicts", help="TSV of <section>\\t<VERDICT>\\t<evidence>")
    ap.add_argument("--manifest", help="directory of <name>.tsv; --file is read from each row")
    ap.add_argument("--ref", required=True, help="ledger ref, e.g. '2026-09-22 reconcile'")
    ap.add_argument("--apply", action="store_true", help="write (default: dry run)")
    a = ap.parse_args()

    jobs = []
    if a.manifest:
        try:
            manifest_names = sorted(os.listdir(a.manifest))
        except OSError as exc:
            sys.stderr.write("reconcile: %s: %s\n" % (a.manifest, exc.strerror or exc))
            return 2
        for name in manifest_names:
            if name.endswith(".tsv"):
                jobs.append((None, os.path.join(a.manifest, name)))
    elif a.file and a.verdicts:
        jobs.append((a.file, a.verdicts))
    else:
        ap.error("need --file with --verdicts, or --manifest")

    tot = dict.fromkeys(list(WRITE) + list(NOOP), 0)
    marked = skipped = 0
    unreadable = malformed = 0
    # Hoisted out of the job loop: each miss is a `digest-proposals --all --json` subprocess with
    # a 300s timeout, and two TSVs in one --manifest directory routinely name the same target.
    cache = {}
    for target, path in jobs:
        rows, bad = read_verdicts(path, target is None)
        if rows is None:          # unreadable verdict file — already reported to stderr
            unreadable += 1
            continue
        # Malformed rows count toward the failure, not just toward the transcript. The previous
        # fix folded the unreadable-file and refused-row paths into the exit code and left this
        # one printing into the void — so a verdict file in which EVERY row was malformed still
        # exited 0. Same class, one path further along: a stdout line is not loud to a script.
        malformed += len(bad)
        for n, why, ctx in bad:
            print("  ! %s:%d %s — %s" % (os.path.basename(path), n, why, ctx))
        # A verdict file may cover several target files (the long-tail batches do), so the target
        # is resolved per row when it was not given.
        for rowfile, section, verdict, note in rows:
            tot[verdict] += 1
            if verdict not in WRITE:
                continue
            tgt = rowfile or target
            if not tgt:
                print("  ! row has no target file and none was given: %r" % section[:60])
                skipped += 1
                continue
            if tgt not in cache:
                cache[tgt] = known_sections(tgt)
            sections = cache[tgt]
            # FAIL CLOSED. `None` means the ledger could not be read, NOT "nothing to check
            # against" — and the two were treated the same, so a helper failure turned the one
            # guarantee this script exists to provide ("a mistyped section is loud") into
            # marking whatever it was handed. `digest-proposals --mark` creates a row for any
            # key, so an unvalidated mark silently disposes of a proposal that does not exist
            # and leaves the real one open. Refusing to mark is recoverable; marking blind is not.
            if sections is None:
                print("  ! cannot validate %s (ledger unreadable) — refusing to mark: %r"
                      % (tgt, section[:70]))
                skipped += 1
                continue
            if section not in sections:
                print("  ! section not in the ledger for %s: %r" % (tgt, section[:70]))
                skipped += 1
                continue
            disp = WRITE[verdict]
            cmd = [HELPER, "--mark", disp, "--file", tgt, "--section", section,
                   "--ref", a.ref, "--note", ("%s: %s" % (verdict.lower(), note))[:400]]
            if not a.apply:
                print("  would mark %-9s %s :: %s" % (disp, tgt, section[:60]))
                marked += 1
                continue
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode == 0:
                marked += 1
            else:
                skipped += 1
                print("  ! mark failed: %s :: %s — %s"
                      % (tgt, section[:50], (r.stderr or r.stdout).strip()[:120]))

    print("\nverdicts read: %d" % sum(tot.values()))
    for k in list(WRITE) + list(NOOP):
        print("  %-11s %d" % (k, tot[k]))
    print("%s %d, skipped %d" % ("marked" if a.apply else "would mark", marked, skipped))
    if not a.apply:
        print("dry run — pass --apply to write")
    # THE REFUSAL MUST REACH THE CALLER. Every skip path above — no target file, an unreadable
    # ledger, a section that is not in it, a `--mark` that failed — printed a line and returned
    # success, so a batch caller (`set -e`, a CI step, `&& next-step`) read "10 rows silently
    # refused" as a clean run. The whole premise of the script is that refusing is loud; a
    # stdout line is not loud to a script, an exit code is.
    if unreadable or malformed or (a.apply and skipped):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
