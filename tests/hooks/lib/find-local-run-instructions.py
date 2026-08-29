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
                        if not BAD.search(line) or not TESTY.search(line):
                            continue
                        if EXEMPT.search(line):
                            continue
                        offenders.append("%s:%d" % (os.path.relpath(path, ROOT), lineno))
    print("\n".join(offenders))
    return 0


if __name__ == "__main__":
    sys.exit(main())
