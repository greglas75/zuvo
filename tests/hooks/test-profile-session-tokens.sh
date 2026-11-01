#!/usr/bin/env bash
# test-profile-session-tokens.sh — profile-session.py must MEASURE tokens, not leave them to prose.
#
# Why this exists: five profiles of ONE Codex session reported gross 202,362,002 vs 203,519,738,
# 1,395 vs 1,406 model calls, and a polling "lower bound" of 45/55/83/396/400 calls — a 9x spread,
# every figure labelled MEASURED. The skill had declared token cost out of scope, so the script
# computed none and each run hand-derived them with its own classifier. Three defects were behind
# the spread and each one gets an assertion here:
#   1. no token accounting at all
#   2. the two formats define input_tokens with OPPOSITE cache semantics (codex includes cache,
#      claude excludes it) — aliasing the keys under-counts claude by nearly its whole volume
#   3. classification ran on the DISPLAY-TRUNCATED label, and newer codex rollouts put the command
#      under `custom_tool_call.input` (not `arguments`/`action`), so tool text vanished entirely
#      and a session that ran reviewers reported adversarial_calls: 0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
PS="$ROOT/scripts/zuvo-home/profile-session.py"
PASS=0; FAIL=0
# `set -u` does not catch a MISSPELLED FUNCTION: bash prints "command not found", returns 127, and
# the counters never move — so a file full of broken assertions summarises as FAIL=0. That happened
# here (11 assertions calling a helper this file does not define). command_not_found_handle turns it
# into a real failure instead of a silent pass.
command_not_found_handle(){ echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL+1)); return 127; }
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- fixture: codex rollout, new custom_tool_call shape, cache INCLUDED in input_tokens ---------
CX="$TMP/codex.jsonl"
{
  for i in 1 2 3 4 5 6; do
    printf '{"type":"response_item","timestamp":"2026-08-17T10:0%s:00.000Z","payload":{"type":"custom_tool_call","name":"exec","input":"cd /Users/x/very/long/worktree/path/that/eats/the/label/budget/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && bash ~/.zuvo/adversarial-review --rotate"}}\n' "$i"
    printf '{"type":"event_msg","timestamp":"2026-08-17T10:0%s:30.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":100,"reasoning_output_tokens":40}}}}\n' "$i"
  done
} > "$CX"

# --- fixture: claude transcript, cache EXCLUDED from input_tokens -------------------------------
CL="$TMP/claude.jsonl"
{
  for i in 1 2 3 4 5 6; do
    printf '{"type":"assistant","timestamp":"2026-08-17T11:0%s:00.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}],"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":900,"output_tokens":100}}}\n' "$i"
    printf '{"type":"user","timestamp":"2026-08-17T11:0%s:30.000Z","message":{"content":[{"type":"tool_result"}]}}\n' "$i"
  done
} > "$CL"

# Key path is passed as ARGV, never interpolated into the python source: `'$2'` inside a
# double-quoted -c produced `'d'+'['tokens']...'`, a syntax error that made every lookup return
# an empty string — i.e. a helper that reports FAIL for a script that is working.
j(){ python3 "$PS" "$1" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d.get(k) if isinstance(d,dict) else None
print("" if d is None else d)' "${@:2}" 2>/dev/null; }

# 1. tokens are emitted at all, on both formats
[ "$(j "$CX" tokens model_calls)" = "6" ] && ok "codex: 6 usage records counted" || no "codex: model_calls (got $(j "$CX" tokens model_calls))"
[ "$(j "$CL" tokens model_calls)" = "6" ] && ok "claude: 6 usage records counted" || no "claude: model_calls (got $(j "$CL" tokens model_calls))"

# 2. THE CACHE-SEMANTICS TRAP. Both fixtures describe the same spend: 1000 billed in (900 of it
#    cache) + 100 out, six times. gross must be 6600 and fresh 1200 in BOTH — that equality is the
#    whole point. A reader that aliased the key names would return 1200 gross for claude.
for f in "$CX" "$CL"; do
  n="$(basename "$f" .jsonl)"
  [ "$(j "$f" tokens gross)" = "6600" ] && ok "$n: gross 6600 (cache counted as billed input)" || no "$n: gross (got $(j "$f" tokens gross), expected 6600)"
  [ "$(j "$f" tokens fresh)" = "1200" ] && ok "$n: fresh 1200 (cache reads excluded)" || no "$n: fresh (got $(j "$f" tokens fresh), expected 1200)"
done

# 3. determinism — same file in, same numbers out. This is the property the five hand-written
#    profiles lacked; assert it rather than trust it.
a="$(python3 "$PS" "$CX" 2>/dev/null | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)['tokens'],sort_keys=True))")"
b="$(python3 "$PS" "$CX" 2>/dev/null | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)['tokens'],sort_keys=True))")"
[ -n "$a" ] && [ "$a" = "$b" ] && ok "repeated runs produce identical token blocks" || no "token block is not reproducible"

# 4. the polling classifier is PUBLISHED with the number, so a quoted figure can be checked
case "$(python3 "$PS" "$CX" 2>/dev/null)" in *'"classifier"'*) ok "polling classifier is emitted alongside the count";; *) no "classifier not emitted";; esac

# 5. TRUNCATION + custom_tool_call.input: the reviewer is invoked 130 chars deep in the command,
#    under the payload key older readers ignored. Both defects filed it as other-tools.
[ "$(j "$CX" counts adversarial_calls)" = "6" ] && ok "adversarial seen past the label cut, in custom_tool_call.input" || no "adversarial_calls (got $(j "$CX" counts adversarial_calls), expected 6)"

# 6. a transcript with NO usage records must say UNKNOWN, not estimate
NO="$TMP/none.jsonl"
{ printf '{"type":"assistant","timestamp":"2026-08-17T12:0%s:00.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}\n' 1 2 3 4; } > "$NO"
out="$(python3 "$PS" "$NO" 2>/dev/null)"
case "$out" in *'"model_calls": 0'*) ok "no usage records -> model_calls 0";; *) no "missing-usage case not reported as 0";; esac
case "$out" in *"never hand-derive"*) ok "no usage records -> refuses to estimate";; *) no "missing-usage case lacks the do-not-estimate note";; esac

# 7. the SKILL must not re-declare tokens out of scope — that line is what made the script's
#    silence look intentional and sent five runs off to compute their own.
SK="$ROOT/skills/profile-session/SKILL.md"
case "$(cat "$SK")" in *'Out of scope:** token cost'*) no "SKILL.md still declares token cost out of scope";; *) ok "SKILL.md no longer declares token cost out of scope";; esac
case "$(cat "$SK")" in *'tokens.model_calls'*) ok "SKILL.md points at the profiler's tokens block";; *) no "SKILL.md does not reference the tokens block";; esac

# --- 8. dedup identity is the TRANSCRIPT, not the caller (B-PROFILE-DEDUP) ----------------------
# The retro layer keys on skill+project+sha7 and `project` is the directory the skill was invoked
# in. For a transcript analysis that is the wrong identity: ONE Codex rollout was profiled at least
# eight times in a day under five different "projects", so the key never matched and every run
# looked new — 12 runs, 25-45 min each. The key must depend on the artifact and nothing else.
K1="$(python3 "$PS" --run-key "$CX")"
K2="$( cd / && python3 "$PS" --run-key "$CX" )"
[ -n "$K1" ] && [ "$K1" = "$K2" ] && ok "run-key is identical from a different cwd (the actual bug)" \
  || no "run-key changed with the caller's directory: '$K1' vs '$K2'"
ln -sf "$CX" "$TMP/alias.jsonl"
[ "$(python3 "$PS" --run-key "$TMP/alias.jsonl")" = "$K1" ] \
  && ok "run-key follows realpath, so a symlink alias is the same analysis" \
  || no "a symlink to the same transcript produces a different key"
[ "$(python3 "$PS" --run-key "$CL")" != "$K1" ] && ok "a different transcript gets a different key" \
  || no "two different transcripts collide"
[ "$(python3 "$PS" --run-key "$CX" 2026-08-17T10:03:00.000Z)" != "$K1" ] \
  && ok "a window bound changes the key (different question, different answer)" \
  || no "the window is not part of the identity"
# It must not read the transcript — that is what makes it cheap enough to run BEFORE the analysis
# rather than at the retro write, where a guard saves a line in a file and not the 25 minutes.
[ "$(python3 "$PS" --run-key "$TMP/does-not-exist.jsonl" 2>/dev/null)" != "" ] \
  && ok "run-key needs no readable transcript (so the guard can run first)" \
  || no "run-key requires reading the file"
# And the skill has to actually USE it, before the analysis.
SK_TXT="$(cat "$SK")"
case "$SK_TXT" in *'--run-key'*) ok "SKILL.md computes the run key" ;; *) no "SKILL.md never calls --run-key" ;; esac
case "$SK_TXT" in *'ALREADY PROFILED'*) ok "SKILL.md early-exits on a repeat with the report path" ;; *) no "no early exit for a repeat" ;; esac
_k="$(printf '%s\n' "$SK_TXT" | grep -n 'run-key' | head -1 | cut -d: -f1)"
_p1="$(printf '%s\n' "$SK_TXT" | grep -n '^## Phase 1: Run the profiler' | head -1 | cut -d: -f1)"
if [ -n "$_k" ] && [ -n "$_p1" ] && [ "$_k" -lt "$_p1" ]; then
  ok "the guard precedes Phase 1 (saves the work, not just a log line)"
else
  no "the dedup guard does not precede the analysis phase"
fi

# Response-accounting regressions exercise the CLI with synthetic, non-sensitive records.
if python3 - "$PS" "$TMP" <<'PYTEST'
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT, TMP = sys.argv[1:]
sys.argv = [sys.argv[0]]
START, END = "2026-08-17T10:00:00Z", "2026-08-17T10:10:00Z"


def claude(response, minute, output=10):
    return {"type": "assistant", "sessionId": "child", "parentSessionId": "parent",
            "timestamp": f"2026-08-17T10:{minute:02}:00Z",
            "message": {"id": response, "content": [{"type": "text", "text": "PRIVATE_PROMPT"}],
                        "usage": {"input_tokens": 20, "cache_creation_input_tokens": 30,
                                  "cache_read_input_tokens": 100, "output_tokens": output}}}


def codex(response, minute, output=10):
    return {"type": "token_usage_record", "timestamp": f"2026-08-17T10:{minute:02}:00Z",
            "payload": {"response_id": response, "thread_id": "child", "parent_id": "parent",
                        "usage": {"input_tokens": 150, "cached_input_tokens": 100,
                                  "output_tokens": output}}}


class Accounting(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(dir=TMP)
        self.addCleanup(temporary.cleanup)
        self.tmp = Path(temporary.name)

    def run_profile(self, rows, *args, export=False):
        path = self.tmp / "regression.jsonl"
        path.write_text("".join(json.dumps(row) + "\n" for row in rows))
        dest = self.tmp / "usage.jsonl"
        cmd = [sys.executable, SCRIPT, str(path), *args]
        if export:
            cmd += ["--usage-jsonl", str(dest)]
        result = subprocess.run(cmd, text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        details = [json.loads(line) for line in dest.read_text().splitlines()] if export else []
        return report, details

    def test_final_fragment_replaces_claude_cost_before_excluding_end(self):
        rows = [claude("a", 0), claude("b", 1), claude("a", 2, 30),
                claude("moved", 3), claude("moved", 10, 90), claude("c", 4)]
        report, _ = self.run_profile(rows, START, END)
        self.assertEqual((report["tokens"]["model_calls"], report["tokens"]["gross"]), (3, 500))
        self.assertEqual(report["tokens"]["source"], "message.usage")

    def test_codex_copies_replace_by_id_without_collapsing_equal_costs(self):
        rows = [codex("a", 0), codex("b", 1), codex("a", 2, 30), codex("c", 3)]
        report, _ = self.run_profile(rows)
        self.assertEqual((report["tokens"]["model_calls"], report["tokens"]["fresh"]), (3, 200))

    def test_parent_summaries_and_compactions_obey_window_without_exporting_child_detail(self):
        rows = [claude("a", 0), claude("b", 1), claude("c", 2)]
        rows += [{"type": "compacted", "timestamp": f"2026-08-17T10:{m:02}:00Z"} for m in (0, 10, 11)]
        rows += [{"type": "user", "timestamp": f"2026-08-17T10:{m:02}:00Z",
                  "toolUseResult": {"usage": {"input_tokens": 5, "output_tokens": 2}}}
                 for m in (0, 10, 11)]
        report, details = self.run_profile(rows, START, END, export=True)
        self.assertEqual(report["tokens"]["compactions"], 1)
        self.assertEqual(report["tokens"]["subagents"], {"calls": 1, "gross": 7})
        self.assertEqual(len(details), 3)

    def test_export_keeps_missing_ids_ambiguous_and_never_leaks_text(self):
        rows = [claude(None, 0), claude(None, 1), claude("a", 2)]
        report, details = self.run_profile(rows, export=True)
        self.assertEqual(report["accounting_version"], 2)
        self.assertEqual(report["tokens"]["missing_response_ids"], 2)
        self.assertEqual([r["missing_response_id"] for r in details], [True, True, False])
        self.assertEqual([r["response_id"] for r in details], [None, None, "a"])
        self.assertEqual(details[0], {"accounting_version": 2, "timestamp": START,
            "provider": "claude", "response_id": None, "thread_id": "child", "parent_id": "parent",
            "input": 150, "cached_input": 100, "output": 10, "reasoning_output": 0,
            "fresh": 60, "gross": 160, "source": "message.usage", "polling_proxy": None,
            "missing_response_id": True})
        self.assertNotIn("PRIVATE_PROMPT", json.dumps(details))

    def test_polling_proxy_cursor_preserves_nearest_tool_including_equal_timestamps(self):
        rows = [{"type": "response_item", "timestamp": START,
                 "payload": {"type": "custom_tool_call", "name": "exec", "input": "rt --wait 123"}},
                codex("a", 0), codex("b", 1),
                {"type": "response_item", "timestamp": "2026-08-17T10:02:00Z",
                 "payload": {"type": "custom_tool_call", "name": "exec", "input": "echo PRIVATE_TOOL"}},
                codex("c", 2)]
        report, details = self.run_profile(rows, export=True)
        self.assertEqual(report["tokens"]["polling"]["calls"], 2)
        self.assertNotIn("PRIVATE_TOOL", json.dumps(details))
        self.assertEqual([r["polling_proxy"] for r in details], ["tool-label-regex-v1", "tool-label-regex-v1", None])

    def test_tool_before_window_still_attributes_usage_inside_window(self):
        rows = [{"type": "response_item", "timestamp": "2026-08-17T09:59:59Z",
                 "payload": {"type": "custom_tool_call", "name": "exec", "input": "rt --wait 123"}},
                codex("a", 0)]
        report, details = self.run_profile(rows, START, END, export=True)
        self.assertEqual(report["counts"]["tool_uses"], 0)
        self.assertEqual(details[0]["polling_proxy"], "tool-label-regex-v1")

    def test_empty_window_and_absent_usage_emit_empty_details_without_inventing_cost(self):
        report, details = self.run_profile([claude("a", 0)], END, export=True)
        self.assertEqual(details, [])
        self.assertEqual(report["tokens"]["model_calls"], 0)
        self.assertEqual(report["tokens"]["source"], "none")
        no_usage = claude("no-usage", 0)
        del no_usage["message"]["usage"]
        report, details = self.run_profile([no_usage], export=True)
        self.assertEqual(details, [])
        self.assertEqual(report["tokens"]["model_calls"], 0)
        self.assertEqual(report["tokens"]["missing_response_ids"], 0)

    def test_invalid_usage_cannot_replace_existing_export(self):
        for bad in (-1, 1.5, True, "3", None):
            with self.subTest(bad=bad):
                row = codex("a", 0)
                row["payload"]["usage"]["input_tokens"] = bad
                path, dest = self.tmp / "bad.jsonl", self.tmp / "preserve.jsonl"
                path.write_text(json.dumps(row) + "\n")
                dest.write_text("original\n")
                result = subprocess.run([sys.executable, SCRIPT, str(path), "--usage-jsonl", str(dest)],
                                        text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(dest.read_text(), "original\n")
                self.assertNotIn("Traceback", result.stderr)

    def test_incomplete_usage_cannot_be_reported_as_known_zero_cost(self):
        for usage in ({}, {"input_tokens": 10}, {"output_tokens": 10}):
            with self.subTest(usage=usage):
                row = codex("known", 0)
                row["payload"]["usage"] = usage
                path = self.tmp / "incomplete.jsonl"
                path.write_text(json.dumps(row) + "\n")
                result = subprocess.run([sys.executable, SCRIPT, str(path)], text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_malformed_message_and_tool_input_fail_cleanly(self):
        bad_tool = {"content": [{"type": "tool_use", "name": "Bash", "input": ["bad"]}]}
        for message in ("bad", ["bad"], bad_tool):
            with self.subTest(message=message):
                row = claude("known", 0)
                row["message"] = message
                path = self.tmp / "malformed.jsonl"
                path.write_text(json.dumps(row) + "\n")
                result = subprocess.run([sys.executable, SCRIPT, str(path)], text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn("Traceback", result.stderr)

    def test_output_alias_cannot_destroy_transcript(self):
        path = self.tmp / "protected.jsonl"
        original = json.dumps(codex("a", 0)) + "\n"
        path.write_text(original)
        symbolic, hard = self.tmp / "symbolic.jsonl", self.tmp / "hard.jsonl"
        symbolic.symlink_to(path)
        hard.hardlink_to(path)
        for dest in (path, symbolic, hard):
            with self.subTest(destination=str(dest)):
                result = subprocess.run([sys.executable, SCRIPT, str(path), "--usage-jsonl", str(dest)],
                                        text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(path.read_text(), original)

    def test_codex_authoritative_usage_does_not_add_ui_counters_and_keeps_metadata(self):
        rows = [{"type": "session_meta", "payload": {"id": "original-thread",
                 "source": {"subagent": {"thread_spawn": {"parent_thread_id": "root"}}}}},
                {"type": "event_msg", "timestamp": START,
                 "payload": {"info": {"last_token_usage": {"input_tokens": 999, "output_tokens": 999}}}},
                codex("a", 0)]
        del rows[2]["payload"]["thread_id"]
        del rows[2]["payload"]["parent_id"]
        report, details = self.run_profile(rows, export=True)
        self.assertEqual(report["tokens"]["gross"], 160)
        self.assertEqual((details[0]["thread_id"], details[0]["parent_id"]), ("original-thread", "root"))

    def test_error_event_text_does_not_abort_valid_usage(self):
        rows = [{"type": "error", "timestamp": START, "message": "timeout"}, codex("a", 1)]
        report, details = self.run_profile(rows, export=True)
        self.assertEqual(report["tokens"]["gross"], 160)
        self.assertEqual(len(details), 1)

    def test_mixed_provider_records_keep_claude_cost_but_suppress_codex_ui_duplicates(self):
        rows = [claude("a", 0), codex("a", 1), {"type": "event_msg", "timestamp": START,
                "payload": {"info": {"last_token_usage": {"input_tokens": 999, "output_tokens": 999}}}}]
        report, details = self.run_profile(rows, export=True)
        self.assertEqual((report["tokens"]["model_calls"], report["tokens"]["gross"]), (2, 320))
        self.assertEqual(report["tokens"]["source"], "mixed")
        self.assertEqual([row["source"] for row in details], ["message.usage", "token_usage_record"])

    def test_ui_fallback_preserves_explicit_parent_over_session_parent(self):
        rows = [{"type": "session_meta", "payload": {"id": "child",
                 "source": {"subagent": {"thread_spawn": {"parent_thread_id": "root"}}}}},
                {"type": "event_msg", "timestamp": START, "payload": {"parent_id": "original-parent",
                 "info": {"last_token_usage": {"input_tokens": 150, "output_tokens": 10}}}}]
        _, details = self.run_profile(rows, export=True)
        self.assertEqual(details[0]["parent_id"], "original-parent")

    def test_export_does_not_replace_nonregular_destination_nodes(self):
        path = self.tmp / "source.jsonl"
        path.write_text(json.dumps(codex("a", 0)) + "\n")
        directory, fifo = self.tmp / "directory", self.tmp / "fifo"
        directory.mkdir()
        os.mkfifo(fifo)
        target, symbolic = self.tmp / "target", self.tmp / "symbolic"
        target.write_text("keep")
        symbolic.symlink_to(target)
        for destination in (directory, fifo, symbolic):
            with self.subTest(destination=destination.name):
                before = destination.lstat()
                result = subprocess.run([sys.executable, SCRIPT, str(path), "--usage-jsonl", str(destination)],
                                        text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
                self.assertEqual(result.returncode, 2, result.stderr)
                after = destination.lstat()
                self.assertEqual((after.st_mode, after.st_ino), (before.st_mode, before.st_ino))
                self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(target.read_text(), "keep")

    def test_fractional_timestamps_do_not_attribute_a_future_tool(self):
        future = codex("later", 0)
        future["timestamp"] = "2026-08-17T10:00:00.500Z"
        rows = [future, codex("earlier", 0), {"type": "response_item",
                "timestamp": "2026-08-17T10:00:00.250Z", "payload": {
                    "type": "custom_tool_call", "name": "exec", "input": "rt --wait 123"}}]
        _, details = self.run_profile(rows, export=True)
        self.assertEqual([r["polling_proxy"] for r in details], [None, "tool-label-regex-v1"])

    def test_invalid_cli_and_impossible_cache_fail_without_traceback(self):
        path = self.tmp / "bad-cli.jsonl"
        row = codex("a", 0)
        path.write_text(json.dumps(row) + "\n")
        for args in (["--usage-jsonl"], [END, START], ["--bogus"], ["bad-date"],
                     ["0001-01-01T00:00:00+01:00"], ["9999-12-31T23:59:59-01:00"]):
            with self.subTest(args=args):
                result = subprocess.run([sys.executable, SCRIPT, str(path), *args], text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
        row["payload"]["usage"]["cached_input_tokens"] = 151
        path.write_text(json.dumps(row) + "\n")
        result = subprocess.run([sys.executable, SCRIPT, str(path)], text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertNotIn("Traceback", result.stderr)


unittest.main()
PYTEST
then ok "response identity, window, export and validation regressions"
else no "response identity, window, export and validation regressions"
fi

echo "  --- profile-session tokens: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
