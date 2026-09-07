#!/usr/bin/env python3
"""Print every skill line that tells Codex it cannot dispatch a sub-agent.

A separate file rather than a heredoc for the same reason as its sibling: the workstation guard
inspects the Bash command it is about to run, and a heredoc carrying these patterns is easy to
misread. Keeping the matcher in a file also makes the exemptions reviewable.
"""
import os
import re
import sys

ROOT = os.environ.get("ROOT") or os.getcwd()

# A blanket prohibition.
BAN = re.compile(
    r"(SINGLE-AGENT ONLY"
    r"|CODEX SINGLE-AGENT RULE"
    r"|inline\s+fresh-eyes\s+pass\b[\s\S]{0,80}?\bSATISFIES\b"
    r"|single-agent (hard rule|lock)"
    r"|(thread )?(spawning|dispatch)[^\n]{0,40}\bFORBIDDEN\b"
    r"|no sub-?agents? (on|in) codex)",
    re.I,
)

# Lines that DISCUSS the removed ban, or state the surviving carve-out, are the fix — not the bug.
EXEMPT = re.compile(
    r"(used to say"
    r"|old wording"
    r"|NOT Codex"
    r"|is the same model"
    r"|same model"
    r"|is NOT a skip"
    r"|HARD GATE"
    r"|this repo's own Codex build"
    r"|why the old blanket ban"
    # A HOST-POLICY rule (a system prompt forbidding unprompted dispatch) is a different
    # constraint from "this harness has no sub-agents", and it is correct where it appears.
    r"|host policy"
    r"|policy-forbidden"
    r"|by host)",
    re.I,
)


def main() -> int:
    offenders = []
    scanned = 0
    for base in ("skills", "shared", "rules"):
        for dirpath, _dirnames, filenames in os.walk(os.path.join(ROOT, base)):
            for name in filenames:
                if not name.endswith(".md"):
                    continue
                path = os.path.join(dirpath, name)
                with open(path, errors="replace") as fh:
                    content = fh.read()
                scanned += 1
                lines = content.splitlines()
                for match in BAN.finditer(content):
                    lineno = content.count("\n", 0, match.start()) + 1
                    if EXEMPT.search(lines[lineno - 1]):
                        continue
                    offenders.append("%s:%d" % (os.path.relpath(path, ROOT), lineno))
    if not scanned:
        print("No Markdown instructions scanned under " + ROOT, file=sys.stderr)
        return 2
    print("\n".join(offenders))
    return 0


if __name__ == "__main__":
    sys.exit(main())
