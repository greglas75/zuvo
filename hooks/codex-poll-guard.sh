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
import itertools
import json
import os
import re
import stat
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


# The string leaves carry JS-encoded calls; a STRUCTURED payload keeps its numbers as JSON numbers
# and its keys as dict keys, so neither ever reaches `blob`. Search the re-encoded payload too, or
# every structured tool call reads as "no timeout given" and is waved through.
raw = json.dumps(payload)


def num(field):
    for hay in (blob, raw):
        m = re.search(r'"?%s"?\s*:\s*"?(\d+)' % field, hay)
        if m:
            return int(m.group(1))
    return None


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
# The name must be matched where the call IS, not wherever the characters appear. A bare substring
# test over the flattened payload denies any command whose TEXT contains `wait_agent(` — writing
# this very file, or its test, or a doc example. And an unscoped `timeout_ms` then picks up a
# number from an unrelated field in the same call. Both halves are scoped now: the structured tool
# name decides, and when the build does not send one, the timeout must sit inside the call's own
# parentheses.
tool_name = payload.get("tool_name") or payload.get("toolName") or ""
if tool_name in ("wait_agent", "waitAgent"):
    t = num("timeout_ms")
else:
    m_wa = re.search(r"wait_agent\s*\(\s*\{?[^)]{0,400}?timeout_ms\\?\"?\s*:\s*\\?\"?(\d+)", blob)
    t = int(m_wa.group(1)) if m_wa else None
# Only a call that HAS a wait_agent timeout is decided here; anything else falls through to the
# checks below. (Guarding this with `if True:` left the block's own `allow()` unconditional and
# short-circuited every later check — caught by the probe, not by the test file.)
if t is not None:
    if t < agent_min:
        deny(
            "zuvo policy: wait_agent timeout_ms=%d is below the %d ms floor." % (t, agent_min),
            "Each poll re-sends the whole conversation (~108K tokens median here) to learn one bit. "
            "Polling a 20-minute agent every second spends ~130M tokens to hear 'not yet' 1,199 "
            "times; at 120000 the same wait costs ~1.1M. Re-issue with timeout_ms: 120000. "
            "Being on the critical path justifies a shorter interval, not one three orders of "
            "magnitude below the useful range.",
        )
    # and then FALL THROUGH. One check passing is not a verdict on the call; ending here let a
    # call carrying an acceptable wait_agent skip every later check.

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
            real = os.path.expanduser(path)
            st = os.stat(real)
            # Regular files ONLY. A FIFO with no writer makes `open()` block forever — in front of
            # EVERY tool call — and a directory raised IsADirectoryError straight through the
            # try/except below it, crashing the hook with rc=1 and no JSON. Both break this file's
            # own fail-open contract, which is worse than any case it might miss.
            size = st.st_size if stat.S_ISREG(st.st_mode) else None
        except Exception:
            size = None
        if size is not None:
            approx = size / 3.6
            nlines = None
            # Count lines ONLY when the size test already passed — the old order paid for a full
            # pass over files it had already disqualified (measured: 1.4 s on a 4.2 GB file, on
            # every matching call). And stop at hi+1: whether the file is longer is all that is
            # being asked.
            if approx <= budget * 0.85:
                try:
                    with open(real, errors="replace") as _fh:
                        nlines = sum(1 for _ in itertools.islice(_fh, hi + 1))
                except Exception:
                    nlines = None
            if nlines is not None and hi < nlines:
                deny(
                    "zuvo policy: %s is ~%d tokens and this call allows %d — reading it in slices "
                    "costs a turn per slice for nothing." % (path, approx, budget),
                    "Read it once:  cat %s   (it is %d lines).\n"
                    "Measured across 1,002 sessions: 4,191 extra turns went to splitting reads that "
                    "fit in one; exactly 18 were genuinely forced by the output limit. Each extra "
                    "turn re-sends the whole conversation (~133K tokens here) to deliver text the "
                    "first call could have carried." % (path, nlines),
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
# A NEWLINE separates commands exactly like `;` does. Requiring the semicolon meant the shape
# actually observed in the wild — `sleep 30` on its own line, then the check — walked straight
# through a guard written for it. Caught by reading real captured calls, not by any test.
# The threshold spares the settling pause: `kill -TERM $pid; sleep 1; ps -p $pid` waits for a signal
# to land, it does not poll. A command that already loops is never touched — it is the shape being
# asked for.
# FOUR encodings carry a command here, not two. The two this originally knew are the object
# forms; the wild also uses a TEMPLATE LITERAL (const cmd=`...`) and the shell-invocation array
# (["/bin/zsh","-lc","..."]). The real polling command captured on 2026-08-27 was a template
# literal, so a guard written for exactly that behaviour watched it go past.
cmd_text = ""
for pat in (r'cmd:\s*"((?:[^"\\]|\\.)*)"',
            r'"cmd"\s*:\s*"((?:[^"\\]|\\.)*)"',
            r'cmd\s*=\s*`([^`]*)`',
            r'"-l?c"\s*,\s*"((?:[^"\\]|\\.)*)"'):
    m_cmd = re.search(pat, blob)
    if m_cmd and m_cmd.group(1).strip():
        cmd_text = m_cmd.group(1)
        break
if not cmd_text:
    # ["/bin/zsh","-lc","<command>"] arrives as separate string LEAVES, so no pattern carrying a
    # comma can ever match it. The command is simply the leaf after the flag.
    for i, leaf in enumerate(leaves[:-1]):
        if leaf in ("-lc", "-c", "-lic"):
            cmd_text = leaves[i + 1]
            break
if cmd_text:
    # A sleep INSIDE any loop body is the shape being asked for — `for`, `select` and a bare
    # `do ... done` block as much as `until`/`while`. Keying off the keyword next to the sleep
    # denied `for i in $(seq 1 60); do ...; sleep 5; done`, which blocks in the shell exactly like
    # the example the refusal itself recommends. So: find the do..done spans, and ask whether the
    # sleep falls in one.
    dos = [m.end() for m in re.finditer(r"\bdo\b", cmd_text)]
    dones = [m.start() for m in re.finditer(r"\bdone\b", cmd_text)]
    m_sleep = None
    for cand in re.finditer(r"(?:^|[;&|\n]\s*|&&\s*)sleep\s+(\d+(?:\.\d+)?)\s*(?:;|&&|\\n|\n)", cmd_text):
        # In a loop iff SOME `do` opens before it and SOME `done` closes after it. Pairing them
        # positionally instead broke on `grep -q done` inside the body: the word closed the span
        # early and the loop read as no loop. When in doubt this errs toward allowing, which is the
        # only safe direction for something sitting in front of every tool call.
        if any(d <= cand.start() for d in dos) and any(e >= cand.end() for e in dones):
            continue
        m_sleep = cand
        break
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
    # `chars:` unquoted in the JS encoding, `"chars":` in the JSON one. Matching only the second
    # meant every JS-shaped empty poll — the majority — read as "no chars field" and passed.
    m = re.search(r'"?chars"?\s*:\s*"((?:[^"\\]|\\.)*)"', blob)
    chars = m.group(1) if m else None
    # ONLY a truly empty `chars` is a poll. A space advances a pager and Enter accepts a prompt —
    # real keystrokes, with a naturally short yield, and judging them against the poll floor
    # refuses the interactive work the tool exists for.
    if chars == "":
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
