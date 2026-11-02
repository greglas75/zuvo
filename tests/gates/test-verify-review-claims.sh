#!/usr/bin/env bash
#
# test-verify-review-claims.sh — the transcript-vs-claims verifier must ACCUSE a fabricated
# Validity Gate and must NEVER accuse an honest one.
#
# The second property is the load-bearing one: the first version of this verifier picked the
# newest transcript by mtime and immediately false-accused a real review (two sessions in one
# repo shared an mtime). A checker that cries wolf gets ignored, which is strictly worse than
# having no checker. These tests lock both directions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
V="$ROOT/scripts/verify-review-claims.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: verify-review-claims (no python3)"; exit 0; }
[ -f "$V" ] || { bad "scripts/verify-review-claims.py missing"; echo "=== RESULT ==="; echo "SOME FAILED"; exit 1; }

# ── fixtures ────────────────────────────────────────────────────────────────
# empty transcript: a session where nothing at all was dispatched
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}\n' > "$TMP/empty.jsonl"

# honest transcript: two real Agent dispatches + one --multi adversarial Bash call
{
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"description":"behavior audit"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"description":"cq audit"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git diff | adversarial-review --multi --mode code"}}]}}'
} > "$TMP/honest.jsonl"

CLAIMS_2='tier2_subagents:
  behavior_auditor: DISPATCHED(m1)
  cq_auditor: DISPATCHED(m2)
adversarial:
  passes_run: 1
  self_review_flag: yes — used --multi'

# ── 1. fabricated claims vs an empty transcript MUST be accused ─────────────
out="$(printf '%s' "$CLAIMS_2" | python3 "$V" --claims - --transcript "$TMP/empty.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "DISAGREEMENT"; then
  pass "fabricated DISPATCHED/passes_run claims are accused (exit 1)"
else
  bad "fabrication NOT accused (rc=$rc): $out"
fi

# ── 2. honest claims vs a matching transcript MUST pass clean ──────────────
out="$(printf '%s' "$CLAIMS_2" | python3 "$V" --claims - --transcript "$TMP/honest.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "consistent with the transcript"; then
  pass "honest claims backed by real tool calls are NOT accused (exit 0)"
else
  bad "FALSE ACCUSATION against an honest review (rc=$rc): $out"
fi

# ── 3. the self-review --multi rule is actually checked ────────────────────
{
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"description":"a"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git diff | adversarial-review --rotate --mode code"}}]}}'
} > "$TMP/norotate.jsonl"
out="$(printf 'tier2_subagents:\n  a: DISPATCHED(m)\nadversarial:\n  passes_run: 1\n  self_review_flag: yes — used --multi\n' \
  | python3 "$V" --claims - --transcript "$TMP/norotate.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q -- "--multi"; then
  pass "claiming self-review --multi without a --multi invocation is accused"
else
  bad "self-review --multi claim not checked (rc=$rc): $out"
fi

# ── 4. a missing transcript must SKIP cleanly, never accuse ────────────────
# NOTE: do NOT test this with a "surely absent" anchor string — the transcript contains the
# conversation, so an anchor merely MENTIONED in the session matches itself (this tool's own
# first run of this test proved it). Exercise the no-evidence path from a cwd that has no
# transcript directory at all instead.
#
# Two different things must both hold, and they are NOT the same exit code:
#   rc 1 = "I checked and the claims are false" — an ACCUSATION. Must never fire
#          on missing data; that was this case's original point and it still holds.
#   rc 2 = "I could not check" — not an accusation, and the ONLY honest answer for
#          --strict. Returning 0 there made the verifier unfalsifiable in exactly the
#          environment it polices: delete the transcript, pass the gate. Caught by the
#          cross-provider adversarial pass on v1.6.53..HEAD (2026-08-03); the module
#          docstring had documented "2 usage/no transcript" all along while the code
#          returned 0. Non-strict keeps 0 so an interactive run stays useful.
out="$(cd "$TMP" && printf '%s' "$CLAIMS_2" | python3 "$V" --claims - --strict 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "SKIP"; then
  pass "--strict with absent evidence exits 2 (cannot-verify), never 0"
elif [ "$rc" -eq 1 ]; then
  bad "missing-transcript path ACCUSED (rc=1) — it must never accuse on missing data: $out"
else
  bad "--strict missing-transcript expected rc=2, got rc=$rc: $out"
fi

out="$(cd "$TMP" && printf '%s' "$CLAIMS_2" | python3 "$V" --claims - 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "SKIP"; then
  pass "non-strict with absent evidence still SKIPs cleanly (rc=0)"
else
  bad "non-strict missing-transcript expected rc=0 SKIP, got rc=$rc: $out"
fi

# ── 5. a `--help` probe is NOT a review pass ───────────────────────────────
# review/SKILL.md itself recommends `adversarial-review --help | grep -- --multi` to check for the
# flag. A substring match counted that probe as a completed --multi pass, so the tool CLEARED the
# exact fabricated claim it exists to catch. Command-position + --help exclusion closes it.
{
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"adversarial-review --help | grep -- --multi"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"grep -rn adversarial-review scripts/"}}]}}'
} > "$TMP/probe-only.jsonl"
out="$(printf 'adversarial:\n  passes_run: 1\n  self_review_flag: yes — used --multi\n' \
  | python3 "$V" --claims - --transcript "$TMP/probe-only.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "ZERO"; then
  pass "a --help probe / grep mention does NOT count as an adversarial pass"
else
  bad "mention-only commands were counted as real passes (rc=$rc): $out"
fi

# ── 6. a real invocation behind env vars and a pipe IS counted ─────────────
# guards the opposite direction of check 5: the anchored regex must still match the real shape
# the skills use (`git diff | ZUVO_REVIEW_TIMEOUT=240 adversarial-review --multi ...`).
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git diff a..b | ZUVO_REVIEW_TIMEOUT=240 adversarial-review --multi --mode code"}}]}}' > "$TMP/real-invoke.jsonl"
out="$(printf 'adversarial:\n  passes_run: 1\n  self_review_flag: yes — used --multi\n' \
  | python3 "$V" --claims - --transcript "$TMP/real-invoke.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "(--multi: 1)"; then
  bad_multi=0
else
  bad_multi=1
fi
[ "$bad_multi" -eq 0 ] \
  && pass "a real piped invocation with env prefix is counted (no false accusation)" \
  || bad "real invocation behind a pipe/env prefix was NOT counted (rc=$rc): $out"

# ── 6b. a backslash-continued invocation keeps its flags ───────────────────
# The `args` capture used to stop at the newline, so `adversarial-review \<NL>  --multi …`
# captured only `\` — a REAL --multi pass scored 0 and the verifier ACCUSED an honest reviewer of
# DID_NOT_USE_--multi (Validity Gate -> FAIL, verdict -> INCOMPLETE). An undercount is the one
# failure mode this tool's design forbids: it is trusted precisely BECAUSE it never under-counts.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git diff a..b | adversarial-review \\\n  --multi --mode code"}}]}}' > "$TMP/cont-invoke.jsonl"
out="$(printf 'adversarial:\n  passes_run: 1\n  self_review_flag: yes — used --multi\n' \
  | python3 "$V" --claims - --transcript "$TMP/cont-invoke.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "(--multi: 1)"; then
  pass "a backslash-continued invocation keeps --multi (no false accusation)"
else
  bad "backslash-continued --multi was lost -> false accusation (rc=$rc): $out"
fi

# ── 6c. an invocation behind timeout / nice / nohup is still an invocation ──
# zuvo:review runs each pass as `timeout 1500 ~/.zuvo/adversarial-review --multi …`; the command-
# position anchor stopped at `timeout`, so nine real --multi passes scored --multi: 0 and the
# verifier accused an honest review of not using --multi (2026-10-12, S-66).
{
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git diff a..b | timeout 1500 ~/.zuvo/adversarial-review --multi --mode code"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"FOO=1 timeout -k 10 25m adversarial-review --multi --mode code < d"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"nice -n 5 nohup adversarial-review --multi --mode code < d"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo timeout 1500 adversarial-review --multi"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"command -v adversarial-review --multi"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"command -p -v adversarial-review --multi; command -pV adversarial-review --multi"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"timeout \"$T\" \\\n  adversarial-review --multi --mode code < d"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"timeout .5h adversarial-review --multi < d"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"NOTE=\"two words\" adversarial-review --multi < d"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"command adversarial-review --multi < d"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"MSG=\"see adversarial-review --multi\" true"}}]}}'
} > "$TMP/wrapped-invoke.jsonl"
out="$(printf 'adversarial:\n  passes_run: 7\n  self_review_flag: yes — used --multi\n' \
  | python3 "$V" --claims - --transcript "$TMP/wrapped-invoke.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "(--multi: 7)"; then
  pass "invocations behind timeout/nice/nohup are counted; an echoed one, a command -v lookup or a quoted mention is not"
else
  bad "wrapped invocations miscounted (rc=$rc): $out"
fi

# ── 6d. the wrapper forms 6c does not cover; a continuation is not a command position ──
# `timeout "${TO:-1500}"`, `env -u FOO`, `stdbuf -o L`, `time -p` and an escaped quote inside an env
# value each hid a real --multi pass (an undercount accuses an honest review). `echo foo \<newline>
# adversarial-review` is echo's argument, not an invocation.
python3 - "$TMP/wrapped-more.jsonl" <<'PY'
import json, sys
commands = [
    'timeout "${TO:-1500}" adversarial-review --multi < d',
    'timeout "$((60*25))" adversarial-review --multi < d',
    'env -u FOO adversarial-review --multi < d',
    'env -i PATH=/bin adversarial-review --multi < d',
    'stdbuf -o L adversarial-review --multi < d',
    'stdbuf -oL adversarial-review --multi < d',
    'time -p adversarial-review --multi < d',
    'X="a \\"b\\"" adversarial-review --multi < d',
    'X="a\\\nb" adversarial-review --multi < d',
    'X=1 Y=$(id -u) adversarial-review --multi < d',
    'timeout -- 1500 adversarial-review --multi < d',
    '"$HOME"/.zuvo/adversarial-review --multi < d',
    '"$ZUVO_BASE/scripts/adversarial-review.sh" --multi < d',
    'echo foo \\\n  adversarial-review --multi',
]
with open(sys.argv[1], "w") as f:
    for c in commands:
        rec = {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Bash", "input": {"command": c}}]}}
        f.write(json.dumps(rec) + "\n")
PY
out="$(printf 'adversarial:\n  passes_run: 13\n  self_review_flag: yes — used --multi\n' \
  | python3 "$V" --claims - --transcript "$TMP/wrapped-more.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "(--multi: 13)"; then
  pass "env/stdbuf/time -p, \${T:-N}/\$((…)) durations, timeout --, \$(…) and escaped-quote values, a \$VAR path are counted; a continued echo is not"
else
  bad "wrapper forms miscounted (rc=$rc): $out"
fi

# ── 6e. no input makes the scan exponential or quadratic ──────────────────
# An assignment value that could end anywhere (`a=a=a=…x`) split exponentially many ways, and each
# newline of a long run of newlines or backslash-newlines rescanned the rest. Heredocs reach this
# regex too, so the verifier hung.
python3 - "$TMP/pathological.jsonl" <<'PY'
import json, sys
commands = ["a=" * 40 + "x", "OPTS=" + ",".join(f"k{i}=v" for i in range(40)) + "=",
            "env -i " * 40 + "x", "a=1;" * 10000, "a=b(" * 5000,
            "|" + "\\\n" * 40000 + "x", "\n" * 40000 + "x"]
with open(sys.argv[1], "w") as f:
    for c in commands:
        rec = {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "Bash", "input": {"command": c}}]}}
        f.write(json.dumps(rec) + "\n")
PY
TMO=(); command -v timeout >/dev/null 2>&1 && TMO=(timeout 30)   # no timeout binary: a hang hangs the suite instead
out="$(printf 'adversarial:\n  passes_run: 0\n' \
  | ${TMO[@]+"${TMO[@]}"} python3 "$V" --claims - --transcript "$TMP/pathological.jsonl" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q Traceback; then
  pass "pathological commands are scanned in linear time"
else
  bad "verifier hung or crashed on pathological commands (rc=$rc): $(printf '%s' "$out" | tail -2)"
fi

# ── 7. partial mismatch (some evidence, not enough) is accused ─────────────
# the elif branches: observed > 0 but fewer than claimed. Previously untested — a bug here would
# only surface as a silent clear on a half-done review.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"description":"one only"}}]}}' > "$TMP/partial.jsonl"
out="$(printf 'tier2_subagents:\n  a: DISPATCHED(m1)\n  b: DISPATCHED(m2)\n  c: DISPATCHED(m3)\n' \
  | python3 "$V" --claims - --transcript "$TMP/partial.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "transcript holds 1"; then
  pass "partial dispatch evidence (3 claimed, 1 observed) is accused"
else
  bad "partial-mismatch branch not exercised/working (rc=$rc): $out"
fi

# ── 8. exit code 2 is a real, distinct contract ────────────────────────────
# the docstring promises 0/1/2; exit 1 means "disagreement", so a usage error MUST NOT reuse it.
out="$(printf '%s' "$CLAIMS_2" | python3 "$V" --claims - --transcript "$TMP/nope.jsonl" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "missing --transcript exits 2 (usage), not 1" \
                || bad "missing --transcript did not exit 2 (rc=$rc): $out"
out="$(python3 "$V" --claims "$TMP/no-such-claims.md" --transcript "$TMP/honest.jsonl" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q "Traceback"; then
  pass "missing --claims exits 2 with a message, not a traceback"
else
  bad "missing --claims crashed or used the wrong exit code (rc=$rc): $out"
fi

# ── 9. --anchor filtering actually filters ─────────────────────────────────
# the mechanism the docstring calls the tie-to-THIS-review; never exercised before.
ANCHDIR="$TMP/proj"; mkdir -p "$ANCHDIR"
out="$(cd "$ANCHDIR" && printf '%s' "$CLAIMS_2" | python3 "$V" --claims - \
        --anchor 'anchor-that-no-transcript-holds-9f3a2b' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "SKIP"; then
  pass "--anchor with no matching transcript SKIPs (never accuses)"
else
  bad "--anchor no-match path did not SKIP (rc=$rc): $out"
fi

# ── 10. a malformed tool_use.input must not crash the verifier ─────────────
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":"not-a-dict"}]}}' > "$TMP/malformed.jsonl"
out="$(printf '%s' "$CLAIMS_2" | python3 "$V" --claims - --transcript "$TMP/malformed.jsonl" 2>&1)"; rc=$?
if [ "$rc" -ne 2 ] && ! printf '%s' "$out" | grep -q "Traceback"; then
  pass "a non-dict tool_use.input is skipped, not a crash"
else
  bad "malformed transcript record crashed the verifier (rc=$rc): $out"
fi

# ── 11. the skill must actually tell agents to run it ──────────────────────
if grep -q 'verify-review-claims.py' "$ROOT/skills/review/SKILL.md"; then
  pass "review/SKILL.md wires the verifier into the Validity Gate"
else
  bad "review/SKILL.md no longer references verify-review-claims.py — the check is orphaned"
fi

# Codex records use direct JSON tool calls or raw JavaScript orchestration, never Claude content blocks.
if python3 - "$V" "$TMP" <<'PYCODEX'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

VERIFIER, TEMP_ROOT = sys.argv[1:]
sys.argv = [sys.argv[0]]
REVIEW = "adversarial-review --multi --mode code"


def codex(name, body, kind="function_call"):
    field = "input" if kind == "custom_tool_call" else "arguments"
    return {"type": "response_item", "payload": {"type": kind, "name": name, field: body}}


def js(body):
    return codex("exec", body, "custom_tool_call")


class CodexEvidence(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=TEMP_ROOT)
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def verify(self, rows, claims, expected):
        path = self.root / "transcript.jsonl"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        result = subprocess.run(
            [sys.executable, VERIFIER, "--transcript", str(path), "--claims", "-", "--strict"],
            input=claims, text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        return result.stdout

    def test_direct_codex_calls_do_not_false_accuse_real_dispatch_and_review(self):
        for kind in ("function_call", "custom_tool_call"):
            with self.subTest(kind=kind):
                rows = [codex("exec_command", json.dumps({"cmd": REVIEW}), kind),
                        codex("spawn_agent", json.dumps({"task_name": "cq_audit", "message": "PRIVATE"}))]
                output = self.verify(rows, "  cq: DISPATCHED(marker)\npasses_run: 1\nself_review_flag: yes used --multi", 0)
                self.assertIn("dispatches=1 adversarial_calls=1 (--multi: 1)", output)
                self.assertNotIn("PRIVATE", output)

    def test_raw_js_await_and_promise_arrays_count_only_literal_command_calls(self):
        cases = (
            ("await wrapper", 'text(await tools.exec_command({cmd: "'+REVIEW+'", max_output_tokens: 1000}));'),
            ("promise array", "const results = await Promise.allSettled([tools.exec_command({cmd: '"+REVIEW+
             "'}), tools.exec_command({cmd: 'echo not-a-review'})]); text(results);"),
            ("escaped continuation", 'await tools.exec_command({cmd: '+json.dumps("adversarial-review " + chr(92) + "\n --multi")+'});'),
        )
        for name, body in cases:
            with self.subTest(case=name):
                output = self.verify([js(body)], "passes_run: 1\nself_review_flag: yes used --multi", 0)
                self.assertIn("adversarial_calls=1 (--multi: 1)", output)

    def test_js_strings_and_comments_do_not_fabricate_invocation_evidence(self):
        example = 'await tools.exec_command({cmd: "adversarial-review --multi"})'
        body = ('const example = ' + json.dumps(example) + '; '
                '// await tools.exec_command({cmd: "adversarial-review --multi"})\n'
                '/* tools.exec_command({cmd: "adversarial-review --multi"}) */ text(example);')
        output = self.verify([js(body)], "passes_run: 1", 1)
        self.assertIn("ZERO adversarial-review invocations", output)

    def test_unreadable_or_dynamic_calls_are_unknown_instead_of_false_zero_or_pass(self):
        cases = (
            ("dynamic command", js('await tools.exec_command({cmd: command});')),
            ("concatenated command", js('await tools.exec_command({cmd: "adversarial-review " + flags});')),
            ("interpolated command", js('await tools.exec_command({cmd: `adversarial-review ${flags}`});')),
            ("computed tool", js('await tools[method]({cmd: "adversarial-review"});')),
            ("unexecuted callback", js('const f = () => tools.exec_command({cmd: "adversarial-review"});')),
            ("conditional call", js('false && tools.exec_command({cmd: "adversarial-review"});')),
            ("truncated literal", js('await tools.exec_command({cmd: "adversarial-review')),
            ("unreadable direct arguments", codex("exec_command", "not-json")),
            ("object method not called", js('const o = { f() { tools.exec_command({cmd: "adversarial-review"}); }};')),
            ("getter not read", js('const o = { get x() { tools.exec_command({cmd: "adversarial-review"}); }};')),
            ("labeled break", js('done: { break done; tools.exec_command({cmd: "adversarial-review"}); }')),
            ("non-ASCII identifier", js('await πtools.exec_command({cmd: "adversarial-review"});')),
            ("global tool alias", js('globalThis["tools"].exec_command({cmd: "adversarial-review"});')),
            ("self tool alias", js('self["tools"].exec_command({cmd: "adversarial-review"});')),
            ("window tool alias", js('window["tools"].exec_command({cmd: "adversarial-review"});')),
            ("global computed alias", js('global["tools"].exec_command({cmd: "adversarial-review"});')),
            ("this computed alias", js('this["tools"].exec_command({cmd: "adversarial-review"});')),
            ("shadowed tools", js('const tools = fake; tools.exec_command({cmd: "adversarial-review"});')),
        )
        for name, row in cases:
            with self.subTest(case=name):
                output = self.verify([row], "passes_run: 1", 2)
                self.assertIn("UNKNOWN", output)
                self.assertNotIn("ZERO adversarial-review", output)
                self.assertNotIn("consistent with the transcript", output)

    def test_unknown_calls_only_block_claims_that_need_their_evidence(self):
        known = codex("exec_command", json.dumps({"cmd": REVIEW}))
        unknown = js('await tools.exec_command({cmd: command});')
        output = self.verify([known, unknown], "passes_run: 1", 0)
        self.assertIn("unsupported", output.lower())
        self.assertIn("consistent with the transcript", output)
        output = self.verify([known, unknown], "passes_run: 0\nself_review_flag: yes used --multi", 0)
        self.assertIn("adversarial_calls=1 (--multi: 1)", output)
        self.assertIn("UNKNOWN", self.verify([known, unknown], "passes_run: 2", 2))
        self.assertIn("consistent with the transcript", self.verify([unknown], "passes_run: 0", 0))
        self.assertIn("consistent with the transcript", self.verify([unknown], "", 0))
        self.assertIn("UNKNOWN", self.verify([codex("spawn_agent", "not-json")], "  cq: DISPATCHED(m)", 2))

    def test_unknown_review_evidence_cannot_hide_a_proven_dispatch_disagreement(self):
        cases = (
            ("unknown reviews, false dispatch", [codex("exec_command", "not-json")],
             "  cq: DISPATCHED(m)\npasses_run: 2", "ZERO Agent/Task", "ZERO adversarial-review"),
            ("unknown dispatch, false review", [codex("spawn_agent", "not-json")],
             "  cq: DISPATCHED(m)\npasses_run: 2", "ZERO adversarial-review", "ZERO Agent/Task"),
        )
        for name, rows, claims, proven, uncertain in cases:
            with self.subTest(case=name):
                output = self.verify(rows, claims, 1)
                self.assertIn("DISAGREEMENT", output)
                self.assertIn(proven, output)
                self.assertNotIn(uncertain, output)
                self.assertIn("UNKNOWN", output)

    def test_nonempty_stdin_is_unknown_review_evidence_but_empty_poll_is_irrelevant(self):
        cases = (
            ("direct command write", codex("write_stdin", json.dumps({"chars": REVIEW + "\n"})), 2),
            ("raw JS command write", js('await tools.write_stdin({chars: '+json.dumps(REVIEW+'\n')+'});'), 2),
            ("direct empty poll", codex("write_stdin", json.dumps({"chars": ""})), 1),
            ("direct absent chars", codex("write_stdin", json.dumps({"session_id": 1})), 1),
            ("raw JS empty poll", js('await tools.write_stdin({chars: "", session_id: 1});'), 1),
            ("raw JS absent chars", js('await tools.write_stdin({session_id: 1});'), 1),
        )
        for name, row, exit_code in cases:
            with self.subTest(case=name):
                output = self.verify([row], "passes_run: 1", exit_code)
                self.assertIn("adversarial_calls=0", output)

    def test_flat_helper_import_survives_isolated_python_and_conflicting_lib_package(self):
        package = self.root / "lib"
        package.mkdir()
        (package / "__init__.py").write_text('raise RuntimeError("wrong lib package imported")\n')
        path = self.root / "calls.jsonl"
        path.write_text(json.dumps(codex("exec_command", json.dumps({"cmd": REVIEW}))) + "\n")
        for flags in ((), ("-P",), ("-I",)):
            with self.subTest(flags=flags):
                result = subprocess.run(
                    [sys.executable, *flags, VERIFIER, "--transcript", str(path), "--claims", "-", "--strict"],
                    input="passes_run: 1", text=True, capture_output=True, timeout=20, cwd=self.root,
                    env={**os.environ, "PYTHONPATH": str(self.root)},
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("adversarial_calls=1", result.stdout)
                self.assertNotIn("wrong lib package imported", result.stderr)

    def test_codex_default_does_not_borrow_an_unrelated_claude_transcript(self):
        home = self.root / "home"
        transcripts = home / ".claude" / "projects" / str(self.root).replace("/", "-")
        transcripts.mkdir(parents=True)
        row = {"message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": REVIEW}}]}}
        (transcripts / "claude.jsonl").write_text(json.dumps(row) + "\n")
        result = subprocess.run(
            [sys.executable, VERIFIER, "--claims", "-", "--strict"],
            input="passes_run: 1", text=True, capture_output=True, timeout=20, cwd=self.root,
            env={**os.environ, "HOME": str(home), "CODEX_THREAD_ID": "synthetic-codex-thread"},
        )
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("Codex requires explicit --transcript", result.stdout)
        self.assertNotIn("consistent with the transcript", result.stdout)

    def test_invocation_does_not_certify_review_completion_or_execute_transcript(self):
        marker = self.root / "must-not-exist"
        rows = [js('await tools.exec_command({cmd: '+json.dumps('touch "'+str(marker)+'"')+'});'),
                codex("exec_command", json.dumps({"cmd": REVIEW})),
                {"type": "response_item", "payload": {"type": "function_call_output", "output": "exit 7"}}]
        output = self.verify(rows, "passes_run: 1", 0)
        self.assertIn("completion/results are not verified", output)
        self.assertFalse(marker.exists())


unittest.main()
PYCODEX
then pass "Codex invocation evidence and unsupported-call boundaries"
else bad "Codex invocation evidence and unsupported-call boundaries"
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
