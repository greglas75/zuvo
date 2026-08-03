#!/usr/bin/env python3
"""Structural lint for skills/*/SKILL.md — two defect classes that reading misses.

Both checks here exist because a human (and an agent) read the same files
carefully and did not see the bug. They are mechanical for that reason.

1. fence-structure
   A parity count of ``` says nothing: a fence opened and closed in the WRONG
   PLACES still counts even. Two real mis-pairings hid behind a clean parity
   check across 8 skills (commit 4683f85):

   - a completion block opens a fence, prints the Run: line, and never closes it
     before '### Retrospective (REQUIRED)' — so the retro protocol, the
     append-runlog mandate and the VERDICT mapping all render as sample text to
     print rather than instructions to follow. Those are exactly the steps the
     retro-gate enforces, so the skill can reach COMPLETE with empty log files.
   - a report template wraps a ```lang example in a same-length ``` fence.
     CommonMark closes the OUTER block at the inner example's closer, so the
     rest of the template escapes and the trailing ``` opens a new block —
     inverting every fence to end of file. Nesting needs a longer outer fence.

   Detection: track fences with CommonMark rules (a closing fence carries no
   info string and must be at least as long as its opener), then flag any
   skill-structural heading found inside a block, plus any block still open at
   EOF.

2. loading-list-integrity
   A bulk insert of retrospective.md into every Mandatory File Loading block
   never renumbered what followed (commit 682d26e). The duplicate ordinals are
   cosmetic; what they hid is not. In content-fix, geo-fix and seo-fix the
   printed CORE FILES LOADED block listed no-pause-protocol.md as READ while the
   prose "read these files" list above it never mentioned the file at all — so
   an agent reads everything it was told to, then reports READ for a file it
   never opened. That file is the HARD rule against mid-batch pauses.

   Detection: every run of numbered include lines must be sequential, and no
   file may appear only in the printed checklist when a prose list exists.

Exit 0 clean, 1 on findings. --verbose lists what was checked.
"""
import re
import sys
from pathlib import Path

# Headings that are unambiguously instructions TO THE AGENT and therefore can
# never legitimately sit inside a fenced block. Deliberately tight: skills also
# emit report/spec templates that legitimately contain headings of their own
# ('## Adversarial Review', '### Edge Cases' are real sections of the design
# spec brainstorm writes), and flagging those would train everyone to ignore
# this check. Add a heading here only when no template could own it.
STRUCTURAL_HEADING = re.compile(
    r"^#{2,4}\s+("
    r"Retrospective\s*\(REQUIRED\)"
    r"|Validity Gate\b"
    r"|Completion Gate Check\b"
    r"|Next-Action Routing\b"
    r"|Mandatory File Loading\b"
    r"|MANDATORY TOOL CALLS\b"
    r"|Phase \d+[:.]"
    r")"
)

FENCE = re.compile(r"^(\s*)(`{3,}|~{3,})(.*)$")
# a numbered loading line: '1. ../../shared/includes/x.md' or with backticks,
# covering rules/ paths too (cq-patterns.md is referenced from rules/).
# Placeholder segments (<resolved-lang>.md, {stack}.md) must match: they are
# real entries, and excluding them SPLITS a single list in two, which then
# reads as a numbering collision (write-article's item 4 did exactly that).
LOADING_LINE = re.compile(
    r"^\s*(\d+)\.\s+`?(?:\.\./)+(?:shared/includes|rules)/([A-Za-z0-9._/<>{}-]+\.md)`?"
)
# bare form used inside printed checklists: '  3. run-logger.md  -- [READ ...]'
LOADING_BARE = re.compile(r"^\s*(\d+)\.\s+([a-z0-9-]+\.md)\s*(?:--|—)")


def fence_map(lines):
    """Walk fences ONCE with CommonMark rules. The single source of the rule.

    Returns (inside, opener, unclosed) for 1-based line numbers:
      inside[i]  — True if line i is a fence marker or sits inside a block
      opener[i]  — line number of the fence enclosing i (0 when outside)
      unclosed   — line number of a fence still open at EOF, else None

    CommonMark: a closing fence carries NO info string, uses the same character,
    and is at least as long as its opener. A ```lang line while a block is open
    is therefore literal content, not a close — that is exactly how a same-length
    nested fence truncates a report template.

    Extracted deliberately: both scanners need this state machine, and this file's
    whole purpose is catching rules that drift between copies. Two hand-maintained
    copies of the fence rule inside the fence linter would be the joke writing
    itself — one edit away from the two callers disagreeing.
    """
    inside = [False] * (len(lines) + 1)
    opener = [0] * (len(lines) + 1)
    open_at, open_marker = None, ""
    for i, line in enumerate(lines, 1):
        m = FENCE.match(line)
        if m:
            marker, info = m.group(2), m.group(3).strip()
            if open_at is None:
                open_at, open_marker = i, marker
                inside[i], opener[i] = True, i
                continue
            if not info and marker[0] == open_marker[0] and len(marker) >= len(open_marker):
                inside[i], opener[i] = True, open_at
                open_at = None
                continue
            # a ```lang line while open: literal content, falls through
        inside[i] = open_at is not None
        opener[i] = open_at or 0
    return inside, opener, open_at


def scan_fences(lines):
    """Return (findings, unclosed_opener_or_None) — structural headings in a block."""
    inside, opener, unclosed = fence_map(lines)
    findings = []
    for i, line in enumerate(lines, 1):
        # opener[i] == i marks the fence line itself; a heading cannot live there
        if inside[i] and opener[i] != i and STRUCTURAL_HEADING.match(line):
            findings.append((i, opener[i], line.strip()))
    return findings, unclosed


def scan_loading(lines):
    """Return (numbering_errors, printed_only_files)."""
    errors = []
    inside, _opener, _unclosed = fence_map(lines)

    runs, cur = [], []
    for i, line in enumerate(lines, 1):
        m = LOADING_LINE.match(line) or LOADING_BARE.match(line)
        if m:
            cur.append((i, int(m.group(1)), Path(m.group(2)).name, inside[i]))
        elif cur:
            runs.append(cur)
            cur = []
    if cur:
        runs.append(cur)

    prose_files, printed = set(), {}
    prev_max = None
    seen_runs = set()
    for run in runs:
        if len(run) < 3:
            continue  # too short to be a loading list
        nums = [n for _, n, _, _ in run]
        # A skill may RE-DISPLAY a deferred list at the point of use (a11y-audit
        # reprints its Stage 2 block at Phase 5 under 'Read deferred files').
        # An identical repeat is not a second list, so it neither collides with
        # the previous one nor advances the running maximum.
        signature = tuple((n, f) for _, n, f, _ in run)
        if signature in seen_runs:
            for lineno, _, fname, in_fence in run:
                (printed.setdefault(fname, lineno) if in_fence else prose_files.add(fname))
            continue
        seen_runs.add(signature)
        want = list(range(nums[0], nums[0] + len(nums)))
        if nums != want:
            errors.append(
                f"L{run[0][0]}-{run[-1][0]}: loading list numbered {nums}, expected {want}"
            )
        # A second list in the same skill is legitimate in exactly two shapes:
        # it restarts at 1 (the printed checklist mirroring the prose list), or
        # it continues at prev_max+1 (a Stage 2 / lazy-loaded half). Starting
        # anywhere else means it collides with an entry of the previous list —
        # which is how content-expand and pentest each ended up with two
        # different files sharing one ordinal, and how the HARD no-pause rule
        # got excluded from a 'print items 1-6' instruction.
        if prev_max is not None and nums[0] not in (1, prev_max + 1):
            errors.append(
                f"L{run[0][0]}: loading list starts at {nums[0]}, which collides "
                f"with the previous list (ends at {prev_max}) — continue at "
                f"{prev_max + 1} or restart at 1"
            )
        prev_max = max(prev_max or 0, nums[-1])
        for lineno, _, fname, in_fence in run:
            if in_fence:
                printed.setdefault(fname, lineno)
            else:
                prose_files.add(fname)

    printed_only = []
    # Only meaningful when the skill HAS a prose list. Skills whose only list is
    # the printed block (infra-audit, pentest, architecture) are correct by
    # construction — the printed block IS the instruction.
    if prose_files:
        for fname, lineno in sorted(printed.items(), key=lambda kv: kv[1]):
            if fname not in prose_files:
                printed_only.append((lineno, fname))
    return errors, printed_only


def main():
    verbose = "--verbose" in sys.argv
    root = Path(__file__).resolve().parent.parent
    # Agent files carry the same defect classes and are dispatched the same way:
    # skills/plan/agents/architect.md had its whole "## Constraints" section —
    # including "You are read-only. Do not create, modify, or delete any files" —
    # sealed inside an unclosed fence, i.e. the read-only mandate of a read-only
    # agent rendered as sample text. Scanning only SKILL.md missed it.
    skills = sorted((root / "skills").glob("*/SKILL.md")) + sorted(
        (root / "skills").glob("*/agents/*.md")
    )
    if not skills:
        print("ERROR: no skills/*/SKILL.md or skills/*/agents/*.md found", file=sys.stderr)
        return 2

    n_err = 0
    for path in skills:
        # Label by repo-relative path, not parent dir: every agent file would
        # otherwise report as "agents" and you could not tell which one failed.
        name = path.relative_to(root / "skills").as_posix()
        lines = path.read_text(encoding="utf-8").split("\n")

        findings, unclosed = scan_fences(lines)
        for lineno, opener, text in findings:
            print(
                f"ERROR: {name}: {text!r} at L{lineno} is inside the code fence "
                f"opened at L{opener} — it renders as sample output, not as an "
                f"instruction. Close that fence before the heading."
            )
            n_err += 1
        if unclosed is not None:
            print(
                f"ERROR: {name}: code fence opened at L{unclosed} is never closed "
                f"— everything after it is swallowed."
            )
            n_err += 1

        num_errors, printed_only = scan_loading(lines)
        for msg in num_errors:
            print(f"ERROR: {name}: {msg}")
            n_err += 1
        for lineno, fname in printed_only:
            print(
                f"ERROR: {name}: L{lineno} prints '{fname}' as READ, but no prose "
                f"loading entry tells the agent to read it."
            )
            n_err += 1

        if verbose and not findings and unclosed is None and not num_errors and not printed_only:
            print(f"OK: {name}")

    if n_err:
        print(f"skill-structure: {n_err} error(s)")
        return 1
    print(f"skill-structure: OK ({len(skills)} skills)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
