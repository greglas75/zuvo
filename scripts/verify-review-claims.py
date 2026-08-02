#!/usr/bin/env python3
"""verify-review-claims.py — check a review's Validity Gate claims against the HARNESS transcript.

The problem this closes
-----------------------
`zuvo:review`'s Validity Gate is a block of self-reported fields:

    tier2_subagents:
      cq_auditor: DISPATCHED(<marker>)
    adversarial:
      passes_run: 2
      providers_used: codex,claude

Nothing read them. `~/.zuvo/append-runlog` verifies only that a retro exists and that every
MUST-FIX/RECOMMENDED carries a resolvable `file:line`. So `DISPATCHED(...)` typed without a
dispatch was indistinguishable from the real thing — the exact "typed pass" class this repo
keeps re-discovering (`--fast` self-applied, fail-open ship fallback, stale-CLEAN normhash).

Claude Code writes a per-session transcript to
`~/.claude/projects/<munged-cwd>/<session-id>.jsonl`, one JSON record per line, containing every
`tool_use` the harness executed. That file is written by the HARNESS, not by the model's own
narration — so counting `Agent` dispatches and `adversarial-review` invocations in it is
independent evidence for exactly the claims above.

Honest limits (read before trusting this)
-----------------------------------------
* **Not a security boundary.** The transcript is a file the agent can technically write to.
  This raises the cost of a fake from "type one word" to "append well-formed JSONL records
  mid-session that survive a later replay" — a deliberate forgery, not a shortcut. Same posture
  as `pg_artifact_proven`'s proof-file check, and stated for the same reason.
* **Main-transcript scope.** Work a sub-agent does lives in ITS own transcript; this verifies the
  DISPATCH happened, not what the sub-agent then did.
* **Evidence is AGGREGATED over a time window, never guessed from one file.** A first version
  picked the newest `.jsonl` and immediately produced a FALSE ACCUSATION against an honest review:
  two sessions in one repo shared an mtime and it read the wrong one. A false accusation is worse
  than no check — it teaches people to ignore the tool. So the default now sums tool calls across
  every transcript for this repo touched inside `--window-min` (default 240), and `--anchor`
  narrows that to transcripts containing a caller-supplied marker (the reviewed range or slug).
* **The transcript contains the CONVERSATION, so an anchor you merely TALKED about matches.**
  Discovered by this tool's own test: an anchor invented as "surely absent" matched, because
  typing it into the session put it in the transcript. So an anchor must be a value the WORK
  produces and prior discussion cannot contain — a post-work commit SHA, the artifact filename
  with its `<base7>..<head7>`, a proof path. A topic word ("refactor auth") anchors nothing.
* **Failure direction is deliberate: over-count, never under-count.** Aggregating can let a
  dishonest review borrow evidence from a concurrent honest one (use `--anchor` to close that),
  but it cannot invent a violation where none exists. The tool is built to be trusted when it
  ACCUSES, at the cost of being merely suggestive when it clears.

Usage
-----
    # verify the claims embedded in a review artifact (or any file holding the gate block)
    python3 scripts/verify-review-claims.py --claims memory/reviews/<a>..<b>-<slug>.md

    # or pipe the gate block straight from the review output
    printf '%s' "$VALIDITY_GATE_BLOCK" | python3 scripts/verify-review-claims.py --claims -

    # strict mode for gates/CI: any disagreement exits 1
    python3 scripts/verify-review-claims.py --claims <file> --strict

Exit: 0 agreement (or findings without --strict) | 1 disagreement in --strict | 2 usage/no transcript.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path

DISPATCH_TOOLS = {"Agent", "Task"}          # Task = older harness name for the same thing

# An INVOCATION, not a mention. A bare substring match counted `adversarial-review --help`
# (a probe `skills/review/SKILL.md` explicitly recommends), `grep adversarial-review …`, and any
# echoed command text as a completed pass — so the tool cleared the exact fabricated
# `passes_run` claim it exists to catch. Anchor to a command position: start of line or after a
# pipe/semicolon/&&/subshell, allowing leading VAR=value env assignments and a path prefix.
# `args` captures the rest of THAT command (up to the next separator) so --help can be excluded
# and --multi attributed to the invocation that actually carried it.
ADVERSARIAL_RE = re.compile(
    r"(?:^|[|;&({]|\n)"                             # command position
    r"(?:\s*(?:if|then|do|else|elif|while|until|time|exec)\b|\s*!)*"  # control-flow lead-ins
    r"(?:\s*[A-Za-z_][A-Za-z0-9_]*=\S*)*"           # optional env assignments
    r"\s*(?:[\w./~-]*/)?adversarial-review(?:\.sh)?\b"
    r"(?P<args>(?:\\\n|[^|;&\n])*)"                 # this command's own arguments
)
# `args` deliberately consumes a backslash-newline continuation rather than stopping at it.
# Stopping made `… | adversarial-review \<newline>  --multi --mode code` capture just `\`, so a
# real `--multi` pass scored adversarial_multi=0 and the verifier ACCUSED an honest reviewer of
# `DID_NOT_USE_--multi` — which flips the Validity Gate to FAIL and the verdict to INCOMPLETE.
# That inverts this tool's stated bias (over-count, never under-count; trusted when it ACCUSES):
# an undercount is the one failure mode the design forbids, because it manufactures a violation.


def munge(path: Path) -> str:
    """Claude Code's project-dir naming: absolute path with separators turned into dashes."""
    return str(path).replace("/", "-")


def locate_transcripts(cwd: Path, window_min: int, anchor: str | None) -> tuple[list[Path], str]:
    """Every transcript for this repo touched inside the window (optionally anchor-filtered).

    Aggregating is the whole point: picking ONE file by mtime falsely accused an honest review
    when a second session shared the timestamp. Summing can only over-count evidence.
    """
    base = Path.home() / ".claude" / "projects" / munge(cwd)
    if not base.is_dir():
        return [], f"no transcript dir for {cwd} (looked in {base})"
    cutoff = time.time() - window_min * 60
    files = [p for p in base.glob("*.jsonl") if p.stat().st_mtime >= cutoff]
    if not files:
        return [], f"no transcript touched in the last {window_min} min under {base}"
    if anchor:
        kept = []
        for p in files:
            try:
                if anchor in p.read_text(encoding="utf-8", errors="replace"):
                    kept.append(p)
            except OSError:
                continue
        if not kept:
            return [], f"no transcript in the window contains the anchor {anchor!r}"
        return kept, f"{len(kept)} transcript(s) matching anchor {anchor!r} within {window_min} min"
    return files, (f"{len(files)} transcript(s) within {window_min} min — NO --anchor given, so "
                   f"evidence from concurrent sessions in this repo is counted too")


def parse_tool_calls(path: Path) -> list[tuple[str, dict]]:
    """Every tool_use in the transcript, as (tool_name, input_dict)."""
    calls: list[tuple[str, dict]] = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue                      # a truncated tail line is not a parse failure
            msg = rec.get("message")
            if not isinstance(msg, dict):
                continue
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    inp = block.get("input")
                    # a non-dict `input` (truncated record, future schema) must not crash the
                    # verifier — an unreadable record is missing evidence, not a usage error
                    calls.append((block.get("name", "?"), inp if isinstance(inp, dict) else {}))
    return calls


def adversarial_invocations(command: str) -> list[str]:
    """Argument strings of the real `adversarial-review` invocations in one Bash command.

    Excludes `--help` (a capability probe, not a review pass) and anything that merely NAMES
    the tool — see ADVERSARIAL_RE.
    """
    return [m.group("args") for m in ADVERSARIAL_RE.finditer(command)
            if "--help" not in m.group("args")]


def observed(calls: list[tuple[str, dict]]) -> dict:
    dispatches = [inp for name, inp in calls if name in DISPATCH_TOOLS]
    adversarial = [
        args for name, inp in calls if name == "Bash"
        for args in adversarial_invocations(str(inp.get("command", "")))
    ]
    return {
        "dispatches": len(dispatches),
        "dispatch_labels": [str(d.get("description") or d.get("subagent_type") or "")[:60]
                            for d in dispatches],
        "adversarial_calls": len(adversarial),
        "adversarial_multi": sum(1 for args in adversarial if "--multi" in args),
    }


def claims_from(text: str) -> dict:
    """Pull the few machine-checkable assertions out of a Validity Gate block."""
    c: dict = {}
    # tier2_subagents.<role>: DISPATCHED(...) — count only real dispatch claims
    c["dispatch_claims"] = len(re.findall(r"^\s*\w+:\s*DISPATCHED\(", text, re.M))
    c["inline_lock_claims"] = len(re.findall(r"INLINE-SINGLE-AGENT-LOCK\(", text))
    m = re.search(r"^\s*passes_run:\s*\[?(\d+)", text, re.M)
    c["passes_run"] = int(m.group(1)) if m else None
    m = re.search(r"^\s*self_review_flag:\s*\[?\s*(yes|no)", text, re.M | re.I)
    c["self_review"] = m.group(1).lower() if m else None
    c["used_multi"] = bool(re.search(r"used\s+--multi", text))
    return c


def verify(c: dict, o: dict) -> list[str]:
    f: list[str] = []
    if c["dispatch_claims"] and o["dispatches"] == 0:
        f.append(
            f"claims {c['dispatch_claims']} sub-agent DISPATCHED(...) but the transcript holds "
            f"ZERO Agent/Task tool calls — the dispatches did not happen"
        )
    elif c["dispatch_claims"] > o["dispatches"]:
        f.append(
            f"claims {c['dispatch_claims']} dispatches, transcript holds {o['dispatches']} "
            f"— at least one claimed sub-agent was never dispatched"
        )
    if c["passes_run"]:
        if o["adversarial_calls"] == 0:
            f.append(
                f"claims adversarial passes_run={c['passes_run']} but the transcript holds ZERO "
                f"adversarial-review invocations"
            )
        elif c["passes_run"] > o["adversarial_calls"]:
            f.append(
                f"claims passes_run={c['passes_run']}, transcript holds "
                f"{o['adversarial_calls']} adversarial-review invocation(s)"
            )
    if c["self_review"] == "yes" and c["used_multi"] and o["adversarial_multi"] == 0:
        f.append(
            "claims SELF-REVIEW used --multi, but no adversarial-review invocation in the "
            "transcript carries --multi (section 1.1 mandates it on self-review)"
        )
    return f


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--claims", required=True,
                    help="file holding the Validity Gate block, or '-' for stdin")
    ap.add_argument("--transcript", help="explicit transcript path (skips window/anchor discovery)")
    ap.add_argument("--window-min", type=int, default=240,
                    help="only consider transcripts touched in the last N minutes (default 240)")
    ap.add_argument("--anchor",
                    help="only count transcripts containing this literal (pass the reviewed range "
                         "or artifact slug — ties the evidence to THIS review)")
    ap.add_argument("--strict", action="store_true", help="exit 1 on any disagreement")
    args = ap.parse_args()

    if args.claims == "-":
        text = sys.stdin.read()
    else:
        # symmetric with the --transcript guard below: a missing claims file is a USAGE error
        # (exit 2), not a traceback and not exit 1 — exit 1 means "disagreement found", so a
        # caller branching on the code could not tell a crash from a real finding. A review that
        # ended BLOCKED never writes its artifact, so this path is reached in normal operation.
        cpath = Path(args.claims)
        try:
            text = cpath.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"ERROR: cannot read claims file {cpath}: {exc}", file=sys.stderr)
            return 2

    if args.transcript:
        tpaths, note = [Path(args.transcript)], "explicit --transcript"
        if not tpaths[0].is_file():
            print(f"ERROR: transcript not found: {tpaths[0]}", file=sys.stderr)
            return 2
    else:
        tpaths, note = locate_transcripts(Path.cwd().resolve(), args.window_min, args.anchor)
        if not tpaths:
            print(f"verify-review-claims: SKIP — {note}")
            print("  (no transcript = no independent evidence; the gate stays self-attested here)")
            return 0

    calls: list[tuple[str, dict]] = []
    for tp in tpaths:
        calls.extend(parse_tool_calls(tp))
    c = claims_from(text)
    o = observed(calls)
    findings = verify(c, o)

    print(f"verify-review-claims: {note}")
    for tp in sorted(tpaths)[:6]:
        print(f"    transcript: {tp.name}")
    print(f"  claimed : dispatches={c['dispatch_claims']} inline-lock={c['inline_lock_claims']} "
          f"passes_run={c['passes_run']} self_review={c['self_review']}")
    print(f"  observed: dispatches={o['dispatches']} adversarial_calls={o['adversarial_calls']} "
          f"(--multi: {o['adversarial_multi']})")
    if not findings:
        print("  VERDICT: claims are consistent with the transcript")
        return 0
    print(f"  VERDICT: {len(findings)} DISAGREEMENT(S)")
    for x in findings:
        print(f"    - {x}")
    return 1 if args.strict else 0


if __name__ == "__main__":
    raise SystemExit(main())
