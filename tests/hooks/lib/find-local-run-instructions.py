#!/usr/bin/env python3
"""Print every source line that tells an agent to run a test suite on the workstation.

Lives in its own file rather than a heredoc because the workstation guard reads the Bash
command it is about to run: a heredoc carrying these very patterns reads as an attempt to
start a runner, and the check that enforces the rule cannot be the thing the rule blocks.

Only the SOURCES are scanned. `dist/` is generated, and is verified by rebuilding it.
"""
import os
import re
import sys

ROOT = os.environ.get("ROOT") or os.getcwd()
SOURCE_DIRS = ("skills", "shared", "rules")

# An instruction to run the suite here.
BAD = re.compile(
    r"(run [^\n]{0,30}\b(locally|on the workstation)\b"
    r"|local, always"
    r"|never prefix[^\n]{0,50}\brt\b"
    r"|Runner:\s+local\b)",
    re.I,
)
# ...but only when the line is about running tests at all.
TESTY = re.compile(r"test|suite|mutant|mutation|probe|runner", re.I)
# A line that names the farm, or that is explaining a corrected mistake, is the fix — not the bug.
EXEMPT = re.compile(r"\brt\b|farm|TF_ALLOW_LOCAL|wrong lesson|used to say|earlier version", re.I)

# ROUTING WORK BACK TO THE WORKSTATION IS THE SAME DEFECT WEARING A PROCESS WORD.
#
# The patterns above look for an imperative ("run it locally"). The rule was breached for weeks by
# text that never used one: env-compat's queue semantics said "decide ONCE on wake — consume
# result, fallback-local, or abort" and "QUEUE_TIMEOUT_NOT_EXECUTED / INFRA_FAILURE — route to
# local fallback". Both name the workstation as a legitimate destination for a suite the farm did
# not seat, which is exactly the behaviour that drove this Mac to load 42.9 on 2026-08-29.
#
# Deliberately NOT gated on TESTY: those two lines carry neither "test" nor "suite" — they say
# INFRA_FAILURE and "on wake" — so requiring a test word is what let them through. In this repo the
# phrase is unambiguous on its own, and EXEMPT_FALLBACK carries the lines that NAME the ban.
# Only the PROSE forms. The hyphenated token `fallback-local` is the reviewer-mode status
# (`clean:fallback-local`, `Adversarial mode: fallback-local`) and is not about execution at all.
FALLBACK = re.compile(
    r"(rout(?:e|ed|ing) to local fallback|fall(?:s|ing)? back to local|local fallback\b|route to local)",
    re.I,
)
# `fallback-local` is ALSO an established vocabulary term in this repo for a REVIEWER: a
# same-environment, different-from-writer agent standing in for a cross-model CLI
# (`test-reviewer-routing.md`). That sense has nothing to do with where a suite executes, and
# flagging it would make this check cry wolf on 12 correct lines. Discriminate by company: the
# reviewer sense always travels with review vocabulary, the execution sense never does.
EXEMPT_FALLBACK = re.compile(
    r"(not on that list|not a local fallback|never a local fallback|no local fallback"
    r"|used to say|earlier version|wrong lesson"
    r"|review|provider|second opinion|reviewer)",
    re.I,
)


def main() -> int:
    offenders = []
    for base in SOURCE_DIRS:
        for dirpath, _dirnames, filenames in os.walk(os.path.join(ROOT, base)):
            for name in filenames:
                if not name.endswith(".md"):
                    continue
                path = os.path.join(dirpath, name)
                with open(path, errors="replace") as fh:
                    for lineno, line in enumerate(fh, 1):
                        if FALLBACK.search(line) and not EXEMPT_FALLBACK.search(line):
                            offenders.append("%s:%d" % (os.path.relpath(path, ROOT), lineno))
                            continue
                        if not BAD.search(line) or not TESTY.search(line):
                            continue
                        if EXEMPT.search(line):
                            continue
                        offenders.append("%s:%d" % (os.path.relpath(path, ROOT), lineno))
    print("\n".join(offenders))
    return 0


if __name__ == "__main__":
    sys.exit(main())
