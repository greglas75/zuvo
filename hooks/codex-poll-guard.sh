#!/usr/bin/env bash
# codex-poll-guard — refuse a poll that is too short to be worth its own cost.
#
# WHY THIS IS A HOOK AND NOT A RULE
#
# The rule was written first, in `shared/includes/env-compat.md`, and it did not work. Measured on
# ten live refactors: every polling session had READ the include before it polled, and across 14
# waits not one used the value the rule asks for. The reason is structural, not sloppiness — the
# `wait` tool's own description contains "cap at 30000 ms" (it applies to a different case, in the
# same sentence as the 5000-300000 range for empty polls), and the model sees that description on
# EVERY call while the include was read once, sixty calls earlier. A number in the tool contract
# beats a number in a document the run has genuinely read.
#
# Everything that actually changed behaviour today was mechanical: the harness refusing a
# `sleep N; check`, the push gate refusing an uncovered range, verify-audit refusing a stale stamp.
# So this is a refusal, not a reminder.
#
# WHAT IT COSTS TO GET WRONG
#
# Measured across the local Codex corpus: 41,870 polls carrying 5.57 BILLION tokens, of which
# `zuvo:refactor` alone accounts for 13,956. The dominant shape is `write_stdin` with empty
# `chars` — which the tool's own description defines as a poll ("Defaults to empty, which polls
# without writing") — at `yield_time_ms: 30000`. Ten times that window is permitted for an empty
# poll and costs nothing but latency at the end of a job that already ran for minutes.
#
# WHAT IT REFUSES — deliberately narrow
#
#   * an EMPTY `write_stdin` poll with yield_time_ms  < POLL_MIN_MS   (default 120000)
#   * a `wait_agent` with timeout_ms                  < AGENT_MIN_MS  (default 60000)
#
# It does NOT touch: a write_stdin that actually writes (that is input, not a poll), `exec` running
# a command (a short window on a fast command is the rule applied CORRECTLY — `rg --files` finishes
# in milliseconds and a 1 s window never elapses), or anything it cannot parse.
#
# FAIL-OPEN in every unknown: bad JSON, no python3, an unrecognised shape, any error -> allow. A
# hook that guesses wrong about a tool call is worse than one that misses a case, and this sits in
# front of every call the agent makes.
#
# OFF-SWITCH: ZUVO_ALLOW_SHORT_POLLS=1

set -uo pipefail

[ "${ZUVO_ALLOW_SHORT_POLLS:-}" = "1" ] && exit 0

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

POLL_MIN_MS="${ZUVO_POLL_MIN_MS:-120000}"
AGENT_MIN_MS="${ZUVO_AGENT_POLL_MIN_MS:-60000}"
POLL_SUGGEST_MS="${ZUVO_POLL_SUGGEST_MS:-300000}"
# Below this a `sleep` is a settling pause (waiting for a signal to land), not a poll cadence.
SLEEP_MIN_S="${ZUVO_SLEEP_POLL_MIN_S:-5}"

python3 - "$INPUT" "$POLL_MIN_MS" "$AGENT_MIN_MS" "$POLL_SUGGEST_MS" "$SLEEP_MIN_S" <<'PY'
import json
import os
import re
import sys


def allow():
    sys.exit(0)


try:
    payload = json.loads(sys.argv[1])
    poll_min = int(sys.argv[2])
    agent_min = int(sys.argv[3])
    suggest = int(sys.argv[4])
    sleep_min = float(sys.argv[5])
except Exception:
    allow()

# The call's text, wherever this build puts it. Codex carries JS in `input`; other shapes use
# `tool_input`/`arguments`. Checking all of them costs nothing and avoids the failure that has
# already happened three times today: reading one field, finding it empty, and concluding nothing
# was there.
# Collect the RAW string leaves. Dumping a dict whose value already holds escaped JSON
# double-encodes it — `"chars":""` becomes `\"chars\":\"\"` and no pattern written for the
# first shape matches the second. That is the same read-the-wrong-shape defect that has cost four
# wrong measurements today, so the walk takes the strings as they are.
def strings(node, out, depth=0):
    if depth > 6:
        return
    if isinstance(node, str):
        out.append(node)
    elif isinstance(node, dict):
        for v in node.values():
            strings(v, out, depth + 1)
    elif isinstance(node, list):
        for v in node:
            strings(v, out, depth + 1)


leaves = []
strings(payload, leaves)
blob = "\n".join(leaves)
if not blob:
    allow()


def num(field):
    m = re.search(r'"?%s"?\s*:\s*(\d+)' % field, blob)
    return int(m.group(1)) if m else None


def deny(reason, fix):
    # `deny` with a reason the model reads. Naming the value to use is the whole point: a refusal
    # that does not say what to do instead just gets retried identically.
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "pre_tool_use",
            "permissionDecision": "deny",
            "permissionDecisionReason": "%s\n%s" % (reason, fix),
        }
    }))
    sys.exit(0)


# ---- wait_agent -----------------------------------------------------------
if '"wait_agent"' in blob or "wait_agent(" in blob or "tools.wait_agent" in blob:
    t = num("timeout_ms")
    if t is not None and t < agent_min:
        deny(
            "zuvo policy: wait_agent timeout_ms=%d is below the %d ms floor." % (t, agent_min),
            "Each poll re-sends the whole conversation (~108K tokens median here) to learn one bit. "
            "Polling a 20-minute agent every second spends ~130M tokens to hear 'not yet' 1,199 "
            "times; at 120000 the same wait costs ~1.1M. Re-issue with timeout_ms: 120000. "
            "Being on the critical path justifies a shorter interval, not one three orders of "
            "magnitude below the useful range.",
        )
    allow()

# ---- paging a file that fits in one read ----------------------------------
# Same shape as polling, different verb: one operation split across turns, each carrying the whole
# context. `sed -n '1,240p' X` then `'241,520p' X` is two turns for a file that fits in one.
#
# Measured across 1,002 sessions: 4,191 extra turns (~558M tokens) went to splitting reads of files
# that fit COMFORTABLY inside the max_output_tokens the very same call requested. Genuinely forced
# by the limit: EIGHTEEN. The worst offenders are this project's own files — `SKILL.md` alone cost
# 1,973 extra turns at ~5,058 tokens against a routinely requested 30,000-token budget, a six-fold
# margin left unused.
#
# Refused only when ALL of these hold, because a partial read is often exactly right:
#   * the range is a suffix-less head read starting at line 1 (the first slice of a paging run),
#   * the file exists and fits inside the budget this call asked for, with room to spare,
#   * a budget was actually named (no budget = nothing to judge; allow).
# The path must stop at a quote or comma. `[^\s;|&]+` swallowed the trailing `",` of the JS
# wrapper, `getsize` then raised, and the rule silently allowed everything — a guard that cannot
# fail is the defect this file was written to end, reproduced inside it.
m_rd = re.search(r"""sed -n\s+'?(\d+),(\d+)p'?\s+([^\s;|&"',]+)""", blob)
if m_rd:
    lo, hi, path = int(m_rd.group(1)), int(m_rd.group(2)), m_rd.group(3)
    m_budget = re.search(r'max_output_tokens"?\s*:\s*(\d+)', blob)
    if lo == 1 and m_budget:
        budget = int(m_budget.group(1))
        try:
            size = os.path.getsize(os.path.expanduser(path))
        except Exception:
            size = None
        if size is not None:
            approx = size / 3.6
            with open(os.path.expanduser(path), errors="replace") as _fh:
                nlines = sum(1 for _ in _fh)
            if approx <= budget * 0.85 and hi < nlines:
                deny(
                    "zuvo policy: %s is ~%d tokens and this call allows %d — reading it in slices "
                    "costs a turn per slice for nothing." % (path, approx, budget),
                    "Read it once:  sed -n '1,%dp' %s   (or `cat %s`).\n"
                    "Measured across 1,002 sessions: 4,191 extra turns went to splitting reads that "
                    "fit in one; exactly 18 were genuinely forced by the output limit. Each extra "
                    "turn re-sends the whole conversation (~133K tokens here) to deliver text the "
                    "first call could have carried." % (nlines, path, path),
                )

# ---- `sleep N; <check>` outside a loop: a poll loop the model drives --------
# The third costume of the same waste. `sleep 25; curl .../pipelines/...` returns to the model,
# which decides again — one full turn per interval. `until <cond>; do sleep 25; done` blocks in the
# shell and costs ONE turn however long it runs. Same `sleep`, opposite price.
#
# BOTH command encodings are read: `exec` carries JS (`cmd: "..."`), `exec_command` carries JSON
# (`"cmd":"..."`). Reading only the first left a quarter of the corpus with no command text during
# analysis, and a guard with the same blind spot would simply never fire on half the calls.
#
# The threshold spares the settling pause: `kill -TERM $pid; sleep 1; ps -p $pid` waits for a signal
# to land, it does not poll. A command that already loops is never touched — it is the shape being
# asked for.
m_cmd = (re.search(r'cmd:\s*"((?:[^"\\]|\\.)*)"', blob)
         or re.search(r'"cmd"\s*:\s*"((?:[^"\\]|\\.)*)"', blob))
cmd_text = m_cmd.group(1) if m_cmd else ""
if cmd_text and not re.search(r"\b(?:until|while)\b[^\n]{0,120}\bdo\b", cmd_text):
    m_sleep = re.search(r"(?:^|[;&|]\s*|&&\s*)sleep\s+(\d+(?:\.\d+)?)\s*(?:;|&&)", cmd_text)
    if m_sleep and float(m_sleep.group(1)) >= sleep_min:
        secs = float(m_sleep.group(1))
        deny(
            "zuvo policy: `sleep %g; ...` outside a loop is a poll the model has to drive — one "
            "whole turn per interval." % secs,
            "Let the SHELL wait instead and pay one round-trip however long it takes:\n"
            "    until <condition>; do sleep %g; done && <read the result>\n"
            "Measured across 1,002 local sessions: 37,159 tool calls are waiting-by-polling "
            "(30%% of everything, ~4.9 billion tokens) against 1,386 done properly. And say "
            "nothing between checks: a poll returning no new information must produce no output "
            "either." % secs,
        )

# ---- write_stdin: EMPTY chars is a poll, not a write ----------------------
if "write_stdin" in blob:
    m = re.search(r'"chars"\s*:\s*"((?:[^"\\]|\\.)*)"', blob)
    chars = m.group(1) if m else None
    if chars is not None and chars.strip() == "":
        y = num("yield_time_ms")
        if y is not None and y < poll_min:
            deny(
                "zuvo policy: an empty write_stdin poll with yield_time_ms=%d is below the %d ms "
                "floor." % (y, poll_min),
                "An empty write_stdin polls without writing, and each poll carries the entire "
                "context to learn whether a job finished. The documented range for an empty poll "
                "is 5000-300000 ms; the 30000 that appears in the tool description is the cap for "
                "a NON-EMPTY write, a different case in the same sentence. Re-issue with "
                "yield_time_ms: %d. Better still, let the command block (rt --wait, "
                "gh run watch --exit-status) so no poll is needed at all.\n"
                "AND SAY NOTHING WHILE WAITING. A poll that returns no new information must "
                "produce no output either: announce the wait ONCE, then stay silent until the "
                "result arrives. Measured on this machine today, 739 of 1,535 assistant messages "
                "(48%%) were 'still waiting' restatements, one session emitting 525 of them — "
                "about 98 million tokens spent re-reading the context to add nothing." % suggest,
            )
    allow()

allow()
PY
