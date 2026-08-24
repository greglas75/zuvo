#!/usr/bin/env python3
"""Where a zuvo:refactor run's wall-clock and turns actually go.

Reads real Claude Code session transcripts — the fleet has already run this skill 845 times, so
there is no need to build a rig to find out how it spends its time.

NOTHING HERE READS NARRATIVE TEXT. The skill's own prose names every phase it has, so a detector
built on text scores a run that merely LOADED the skill as having executed all of it. That mistake
has already produced two confident, false conclusions in this project. Each assistant turn is
classified by the TOOL CALL it makes, and a bash turn by the program that command actually invokes.
A turn with no tool call is `think` — a real cost, worth seeing separately rather than folded into
whatever surrounds it.

Wall-clock per bucket comes from consecutive turn timestamps, so one 90-second test run shows up as
90 seconds rather than as one turn.

Usage:
  analyze-refactor-sessions.py [--limit N] [--since YYYY-MM-DD] [--json]
"""
import argparse
import glob
import json
import os
import re
import statistics as S
import sys
from collections import Counter, defaultdict

PROJECTS = os.path.expanduser("~/.claude/projects")

# A session counts as a refactor RUN only if the skill was actually invoked — a Skill tool_use, or
# the run-log line the skill appends when it finishes. Mentioning the word does not count.
INVOKED = re.compile(r'"(?:skill|name)"\s*:\s*"(?:zuvo:)?refactor"')
RUNLOG = re.compile(r"append-runlog[^\n]*\brefactor\b|\brefactor\b[^\n]*append-runlog")


def classify_bash(cmd):
    """Bucket a shell command by the program it runs, not by what it is about.

    Agents write multi-line, multi-segment commands: a `cd` on its own line, then the real work.
    A first-token classifier therefore buckets 2,675 calls as "cd" and hides everything behind it —
    which is how 30% of a session's wall-clock ended up in an "unclassified" pile that was really
    tests, git and search. Every segment is scanned, and the most specific match wins.
    """
    segments = [seg for seg in re.split(r"[\n;]|&&|\|\|", cmd) if seg.strip()]
    # Navigation and pure shell plumbing are not work; skip them so the real program is reached.
    segments = [s for s in segments
                if not re.match(r"^\s*(cd|export|set|source|\.)\s", s)
                and s.strip() not in ("cd", "true", ":")]
    c = " ".join(" ".join(segments).split())[:600] or " ".join(cmd.split())[:600]
    pairs = [
        ("verify-helper", r"~?/?\.zuvo/verify-tests|verify-tests --manifest"),
        ("adversarial", r"adversarial-review|blind-audit|agy |codex |kimi |cursor-agent"),
        ("test-run", r"\b(vitest|jest|pytest|go test|cargo test|npm (run )?test|pnpm test|rt )\b"),
        ("typecheck", r"\btsc\b|--noEmit|mypy|pyright"),
        ("lint", r"\b(eslint|biome|ruff|shellcheck)\b"),
        ("build", r"\b(npm run build|pnpm build|turbo run build|vite build|tsup)\b"),
        ("git", r"^git\b|\bgit (add|commit|status|diff|log|stash|worktree|checkout|push)\b"),
        ("coverage-gate", r"test-coverage-gate\.py"),
        ("search", r"^(rg|grep|find|ls|fd)\b|\b(rg|grep -r)\b"),
        ("read-file", r"^(cat|head|tail|sed -n|wc)\b"),
    ]
    for name, pat in pairs:
        if re.search(pat, c):
            return name
    return "bash-other"


def classify_turn(rec):
    msg = rec.get("message") or {}
    content = msg.get("content")
    if not isinstance(content, list):
        return None
    for item in content:
        if not isinstance(item, dict) or item.get("type") != "tool_use":
            continue
        name = item.get("name") or ""
        inp = item.get("input") or {}
        if name == "Bash":
            return classify_bash(inp.get("command") or "")
        if name in ("Edit", "Write", "NotebookEdit", "MultiEdit"):
            path = str(inp.get("file_path") or "")
            if re.search(r"\.(spec|test)\.[cm]?[jt]sx?$|_test\.py$|test_\w+\.py$", path):
                return "write-tests"
            if re.search(r"\.(md|json|ya?ml)$", path):
                return "write-artifact"
            return "write-prod"
        if name == "Read":
            path = str(inp.get("file_path") or "")
            if "/shared/includes/" in path or "/rules/" in path or "SKILL.md" in path:
                return "load-skill"
            return "read"
        if name in ("Agent", "Task"):
            return "subagent"
        if name.startswith("mcp__codesift__"):
            return "codesift"
        if name in ("Grep", "Glob"):
            return "search"
        return "tool-other"
    # An assistant turn with no tool call is deliberation, and it is not free.
    return "think" if msg.get("role") == "assistant" else None


def ts(rec):
    t = rec.get("timestamp")
    if not t:
        return None
    try:
        from datetime import datetime
        return datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def analyse(path):
    turns, secs = Counter(), defaultdict(float)
    prev_t = prev_label = None
    n = 0
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except Exception:
                continue
            label = classify_turn(rec)
            t = ts(rec)
            if label is None:
                continue
            n += 1
            turns[label] += 1
            if prev_t is not None and t is not None:
                gap = t - prev_t
                # A gap over 10 minutes is the operator away, not the skill working. Counting it
                # would make an overnight pause look like a slow phase.
                if 0 < gap < 600 and prev_label:
                    secs[prev_label] += gap
            prev_t, prev_label = t, label
    return n, turns, secs


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=40)
    ap.add_argument("--since", default=None, help="YYYY-MM-DD; skip transcripts older than this")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)

    cutoff = 0.0
    if a.since:
        from datetime import datetime
        cutoff = datetime.fromisoformat(a.since).timestamp()

    candidates = []
    for f in glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")):
        try:
            st = os.stat(f)
        except OSError:
            continue
        if st.st_mtime < cutoff or st.st_size < 20000:
            continue
        candidates.append((st.st_mtime, f))
    candidates.sort(reverse=True)

    sessions = []
    for _mt, f in candidates:
        if len(sessions) >= a.limit:
            break
        try:
            with open(f, errors="replace") as fh:
                head = fh.read(4_000_000)
        except OSError:
            continue
        if not (INVOKED.search(head) or RUNLOG.search(head)):
            continue
        n, turns, secs = analyse(f)
        if n < 40:                     # too short to be a real run
            continue
        sessions.append((os.path.basename(f)[:8], n, turns, secs))

    if not sessions:
        print("no refactor sessions matched", file=sys.stderr)
        return 1

    agg_secs, agg_turns = defaultdict(list), defaultdict(list)
    for _sid, _n, turns, secs in sessions:
        total = sum(secs.values()) or 1
        for k, v in secs.items():
            agg_secs[k].append(100.0 * v / total)
        for k, v in turns.items():
            agg_turns[k].append(v)

    if a.json:
        print(json.dumps({"sessions": len(sessions),
                          "share_pct": {k: S.median(v) for k, v in agg_secs.items()},
                          "turns_median": {k: S.median(v) for k, v in agg_turns.items()}}, indent=1))
        return 0

    wall = [sum(s.values()) for _a, _b, _c, s in sessions]
    print("refactor sessions analysed: %d" % len(sessions))
    print("wall-clock per session: median %.0f min, p90 %.0f min"
          % (S.median(wall) / 60, sorted(wall)[int(len(wall) * 0.9) - 1] / 60))
    print("\n%-16s %10s %8s %10s %s" % ("bucket", "median %", "max %", "turns", "largest in N"))
    biggest = Counter()
    for _sid, _n, _t, secs in sessions:
        if secs:
            biggest[max(secs, key=secs.get)] += 1
    for k in sorted(agg_secs, key=lambda k: -S.median(agg_secs[k])):
        print("%-16s %9.1f%% %7.1f%% %10.0f %d"
              % (k, S.median(agg_secs[k]), max(agg_secs[k]),
                 S.median(agg_turns.get(k, [0])), biggest.get(k, 0)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
