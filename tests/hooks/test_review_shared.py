"""scripts/zuvo-home/zuvo_review_{classes,ledger,llm,prodpath}.py — the pieces every review-learning
helper (bill, review-escapes, curate) shares, so they cannot read the same data two ways."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from typing import Any
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from review_testlib import (  # noqa: E402
    LEDGER_HEADER,
    ZUVO_HOME_SRC,
    ReviewTestCase,
    finding,
    SLEEPER_FAKE,
    any_alive_after,
    read_pids,
    verdict,
    wait_for,
)

DECISION_2 = ("race-condition", "null-handling", "numeric", "boundary", "contract-drift", "validation",
              "error-handling", "auth", "tenant-scope", "data-loss", "resource-leak", "perf", "test-gap",
              "logic", "style", "other")


class ClassVocabularyTests(ReviewTestCase):
    def test_vocabulary_is_exactly_the_closed_set_of_decision_2(self) -> None:
        # bug: a class added or dropped in code silently changes every metric's denominator
        import zuvo_review_classes as c
        self.assertEqual(DECISION_2, tuple(c.CLASSES))

    def test_free_text_folds_onto_one_canonical_class(self) -> None:
        # bug: free text splits one class into several rows in the weekly metrics
        import zuvo_review_classes as c
        table = [
            ("race", "race-condition"), ("Race Condition ", "race-condition"),
            ("race_condition", "race-condition"), ("undefined", "null-handling"),
            ("security", "auth"), ("input-validation", "validation"), ("api-break", "contract-drift"),
            ("data-integrity", "data-loss"), ("resource-cleanup", "resource-leak"),
            ("performance", "perf"), ("test-flakiness", "test-gap"), ("documentation", "style"),
            ("off-by-one", "boundary"), ("LOGIC", "logic"), ("tenant-isolation", "tenant-scope"),
            ("numeric-stability", "numeric"),
        ]
        for raw, want in table:
            with self.subTest(raw=raw):
                self.assertEqual(want, c.normalize_class(raw))

    def test_unknown_or_missing_class_is_other_never_dropped(self) -> None:
        # bug: a record without a usable class vanished from the per-class totals
        import zuvo_review_classes as c
        # "none"/"null" are a judge saying "no class", not a null-handling defect
        for raw in ("weird-new-thing", "", "   ", None, 42, ["logic"], "none", "None", "null", "n/a"):
            with self.subTest(raw=raw):
                self.assertEqual("other", c.normalize_class(raw))

    def test_every_alias_targets_a_class_in_the_vocabulary(self) -> None:
        # bug: an alias pointing at a retired name re-opens the vocabulary
        import zuvo_review_classes as c
        self.assertEqual(set(), set(c.ALIASES.values()) - set(c.CLASSES))
        self.assertEqual(set(), set(c.ALIASES.values()) - set(DECISION_2))


class LedgerTests(ReviewTestCase):
    def test_latest_verdict_wins_per_project_and_fingerprint(self) -> None:
        # bug: Bill's earlier `real` outranked the agent's later `rejected`
        import zuvo_review_ledger as led
        p = "/Users/greglas/DEV/tgm-survey-platform"
        self.write_ledger([
            finding("2026-10-01T10:00:00Z", "r1", "a.ts:3:x", "a.ts:3", p),
            verdict("2026-10-01T11:00:00Z", "a.ts:3:x", "deferred", p),
            verdict("2026-10-01T12:00:00Z", "a.ts:3:x", "rejected", p, run="agent"),
            verdict("2026-10-01T09:00:00Z", "b.ts:1:y", "fixed", p),
        ])
        got = led.latest_verdicts(led.read_rows())
        self.assertEqual({("tgm-survey-platform", "a.ts:3:x"): "rejected",
                          ("tgm-survey-platform", "b.ts:1:y"): "fixed"}, got)

    def test_same_timestamp_later_row_wins(self) -> None:
        # bug: an agent's verdict written in the same second as Bill's lost to it
        import zuvo_review_ledger as led
        self.write_ledger([verdict("2026-10-01T10:00:00Z", "f", "deferred", "proj"),
                           verdict("2026-10-01T10:00:00Z", "f", "rejected", "proj", run="agent")])
        self.assertEqual({("proj", "f"): "rejected"}, led.latest_verdicts(led.read_rows()))

    def test_an_older_verdict_appended_later_does_not_win(self) -> None:
        # bug: a merged remote ledger appended an old verdict after a newer one and it won by order
        import zuvo_review_ledger as led
        self.write_ledger([verdict("2026-10-02T10:00:00Z", "f", "rejected", "proj"),
                           verdict("2026-10-01T10:00:00Z", "f", "deferred", "proj")])
        self.assertEqual({("proj", "f"): "rejected"}, led.latest_verdicts(led.read_rows()))

    def test_abs_path_home_path_and_basename_rows_share_one_project_key(self) -> None:
        # bug: basename-project rows (old driver) never matched abs-path rows, so judged twice
        import zuvo_review_ledger as led
        self.write_ledger([
            verdict("2026-10-01T10:00:00Z", "f", "deferred", "/Users/greglas/DEV/zuvo-plugin"),
            verdict("2026-10-01T11:00:00Z", "f", "rejected", "/home/greglas/DEV/zuvo-plugin/"),
            verdict("2026-10-01T12:00:00Z", "f", "fixed", "zuvo-plugin"),
        ])
        self.assertEqual({("zuvo-plugin", "f"): "fixed"}, led.latest_verdicts(led.read_rows()))

    def test_new_rows_are_findings_not_verdicts(self) -> None:
        # bug: a `new` row counted as judged and the finding never reached Bill
        import zuvo_review_ledger as led
        self.write_ledger([finding("2026-10-01T10:00:00Z", "r1", "a:1:x", "a:1", "/x/proj")])
        rows = list(led.read_rows())
        self.assertEqual({}, led.latest_verdicts(rows))
        self.assertEqual(("r1", "codex-5.3", "proj", "a:1"),
                         (rows[0].run_id, rows[0].provider, rows[0].project_key, rows[0].file))

    def test_header_comments_and_short_rows_are_skipped(self) -> None:
        # bug: the header row parsed as a finding with run_id "run_id"
        import zuvo_review_ledger as led
        legacy_10 = "\t".join(finding("2026-10-01T09:00:00Z", "old", "fp", "a:1", "p").split("\t")[:10])
        # a second header mid-file: ledgers concatenated from two hosts
        self.write_ledger([LEDGER_HEADER, "# note", "too\tfew\tcolumns", legacy_10, LEDGER_HEADER,
                           finding("2026-10-01T10:00:00Z", "r1", "fp", "a:1", "p")], header=False)
        self.assertEqual(["r1"], [r.run_id for r in led.read_rows()])

    def test_missing_ledger_reads_as_empty(self) -> None:
        # bug: a fresh host without a ledger crashed every tick
        import zuvo_review_ledger as led
        self.assertEqual([], list(led.read_rows()))

    def test_unreadable_ledger_or_jsonl_raises_instead_of_reading_as_empty(self) -> None:
        # bug: a ledger that exists but cannot be read looked like "no findings" and nothing was judged
        import zuvo_review_ledger as led
        not_a_file = os.path.join(self.tmp, "dir.log")
        os.makedirs(not_a_file)
        with self.assertRaises(OSError):
            list(led.read_rows(not_a_file))
        with self.assertRaises(OSError):
            list(led.iter_jsonl(not_a_file))

    def test_rows_without_a_project_are_never_keyed_on_an_empty_name(self) -> None:
        # bug: every project-less verdict merged under the key "" and overrode each other
        import zuvo_review_ledger as led
        self.write_ledger([verdict("2026-10-01T10:00:00Z", "f", "rejected", ""),
                           verdict("2026-10-01T10:00:00Z", "g", "fixed", "/"),
                           verdict("2026-10-01T10:00:00Z", "h", "fixed", "repo")])
        self.assertEqual({("repo", "h"): "fixed"}, led.latest_verdicts(led.read_rows()))
        self.assertIsNone(led.project_key(""))

    def test_ledger_path_follows_env_set_after_import(self) -> None:
        # bug: a path frozen at import pointed tests (and a second ZUVO_HOME) at the real ~/.zuvo
        import zuvo_review_ledger as led
        z2 = os.path.join(self.tmp, "z2")
        table = [({"ZUVO_FINDINGS_LOG_FILE": "/x/other.log"}, "/x/other.log"),
                 ({"ZUVO_FINDINGS_LOG_FILE": "", "ZUVO_HOME": z2},
                  os.path.join(z2, "adversarial-findings.log"))]
        for env, want in table:
            with self.subTest(env=env), mock.patch.dict(os.environ, env):
                self.assertEqual(want, led.ledger_path())

    def test_file_column_splits_into_path_and_line(self) -> None:
        # bug: placeholders became a file literally named "unknown" and matched each other
        import zuvo_review_ledger as led
        table = [
            ("a/b.ts:38", ("a/b.ts", 38)),
            ("tools/x.sh:13‑15", ("tools/x.sh", 13)),
            ("x.py:12-15", ("x.py", 12)),
            ("identity-design-spec:unknown", ("identity-design-spec:unknown", None)),
            ("collect_tail.py:collect", ("collect_tail.py:collect", None)),
            ("c:/w/a.py:5", ("c:/w/a.py", 5)), ("dir:x/a.py:12-14", ("dir:x/a.py", 12)),
            ("docs/spec.md", ("docs/spec.md", None)),
            ("unknown", (None, None)), ("?", (None, None)), ("", (None, None)),
            ("unknown:AC14", ("unknown:AC14", None)), ("unknown:12", (None, None)),
            ("  a.py:7 ", ("a.py", 7)),
        ]
        for raw, want in table:
            with self.subTest(raw=raw):
                self.assertEqual(want, led.split_file(raw))

    def test_torn_or_non_object_jsonl_lines_are_skipped(self) -> None:
        # bug: a write in progress (torn last line) made the whole defects file unreadable
        import zuvo_review_ledger as led
        p = self.write("d.jsonl", '{"a": 1}\n[1, 2]\nnot json\n{"b": 2}\n{"c":')
        self.assertEqual([{"a": 1}, {"b": 2}], list(led.iter_jsonl(p)))
        self.assertEqual([], list(led.iter_jsonl(os.path.join(self.tmp, "absent.jsonl"))))

    def test_invalid_utf8_byte_is_replaced_not_fatal(self) -> None:
        # bug: one invalid byte in a lesson raised UnicodeDecodeError and hid the whole file
        import zuvo_review_ledger as led
        p = os.path.join(self.tmp, "b.jsonl")
        with open(p, "wb") as f:
            f.write(b'{"x": "\xff"}\n' + json.dumps({"y": 1}).encode() + b"\n")
        self.assertEqual([{"x": "\ufffd"}, {"y": 1}], list(led.iter_jsonl(p)))

    def test_remote_roots_reads_depth_one_and_two_never_three(self) -> None:
        # bug: remote copies (where the busiest host's reviews live) were never read
        import zuvo_review_ledger as led
        remote = os.path.join(self.zuvo, "remote")
        want = [self.write(os.path.join(remote, "self", "bill-data", "defects.jsonl"), "{}\n"),
                self.write(os.path.join(remote, "ryzen", "ryzen-dev", "bill-data", "defects.jsonl"), "{}\n")]
        depth_3 = self.write(os.path.join(remote, "a", "b", "c", "bill-data", "defects.jsonl"), "{}\n")
        got = led.remote_roots("bill-data/defects.jsonl")
        self.assertEqual(sorted(want), got)
        self.assertNotIn(depth_3, got)

    def test_remote_roots_without_a_remote_dir_is_empty(self) -> None:
        # bug: a host with no mirrored data crashed the reader
        import zuvo_review_ledger as led
        self.assertEqual([], led.remote_roots("adversarial-findings.log"))


FAKE_OK = """\
printf '%s\\n' "$@" > "$CAPTURE/argv"
pwd > "$CAPTURE/cwd"
cat > "$CAPTURE/stdin"
cat <<'EOF'
{"type":"result","is_error":false,"result":"Verdicts: {\\"defects\\": []} done","total_cost_usd":0.25,
 "usage":{"input_tokens":10,"cache_creation_input_tokens":5,"cache_read_input_tokens":100,"output_tokens":7}}
EOF
"""


class RunClaudeTests(ReviewTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.capture_dir = os.path.join(self.tmp, "cap")
        os.makedirs(self.capture_dir)
        self.setenv(CAPTURE=self.capture_dir)

    def read_cap(self, name: str) -> str:
        with open(os.path.join(self.capture_dir, name), encoding="utf-8") as f:
            return f.read()

    def test_call_is_hermetic_no_tools_no_mcp_no_session_in_tmp(self) -> None:
        # bug: a headless judge loaded the user's MCP servers and orphaned them
        import zuvo_review_llm as llm
        self.fake_exe("claude", FAKE_OK)
        llm.run_claude("PROMPT-BODY", model="claude-opus-5-5", effort="xhigh", timeout=30)
        argv = self.read_cap("argv").splitlines()
        self.assertEqual(["-p", "--model", "claude-opus-5-5", "--effort", "xhigh", "--output-format", "json",
                          "--tools", "", "--mcp-config", '{"mcpServers":{}}', "--strict-mcp-config",
                          "--no-session-persistence"], argv)
        self.assertEqual(os.path.realpath("/tmp"), os.path.realpath(self.read_cap("cwd").strip()))
        self.assertEqual("PROMPT-BODY", self.read_cap("stdin"))

    def test_answer_and_usage_come_from_the_cli_envelope(self) -> None:
        # bug: cache tokens left out of tokens_in under-reported the cost 10x
        import zuvo_review_llm as llm
        self.fake_exe("claude", FAKE_OK)
        r = llm.run_claude("p", model="m", effort="e", timeout=30)
        self.assertEqual((0, {"defects": []}, ""), (r.rc, r.answer, r.error))
        self.assertEqual({"tokens_in": 115, "tokens_out": 7, "usd": 0.25}, r.usage)

    def test_unparsable_output_is_an_error_not_a_crash(self) -> None:
        # bug: a non-JSON reply raised out of the worker thread and killed the tick
        import zuvo_review_llm as llm
        table = [
            ("echo 'not json'; echo boom >&2", "boom"),
            ("""echo '{"result":"no object here","usage":{}}'""", "no object here"),
            ("echo '[1, 2]'", "ValueError: CLI output is not a JSON object"),
        ]
        for body, needle in table:
            with self.subTest(body=body):
                self.fake_exe("claude", body + "\n")
                r = llm.run_claude("p", model="m", effort="e", timeout=30)
                self.assertIsNone(r.answer)
                self.assertIn(needle, r.error)

    def test_cli_error_text_carries_stderr_and_is_error_result_for_limit_checks(self) -> None:
        # bug: "hit your limit" arrived in the envelope's result and the tick kept paying for retries
        import zuvo_review_llm as llm
        self.fake_exe("claude", """echo 'Usage limit' >&2
echo '{"is_error":true,"result":"You hit your limit","usage":{}}'
exit 1
""")
        r = llm.run_claude("p", model="m", effort="e", timeout=30)
        self.assertEqual(1, r.rc)
        self.assertIn("Usage limit", r.cli_error)
        self.assertIn("You hit your limit", r.cli_error)

    def test_lone_surrogate_in_prompt_is_replaced_not_fatal(self) -> None:
        # bug: one broken character in a diff failed the whole judgement
        import zuvo_review_llm as llm
        self.fake_exe("claude", FAKE_OK)
        r = llm.run_claude("bad \ud800 prompt", model="m", effort="e", timeout=30)
        self.assertEqual((0, ""), (r.rc, r.error))
        self.assertEqual("bad ? prompt", self.read_cap("stdin"))

    def test_prompt_and_answer_are_utf8_under_a_non_utf8_locale(self) -> None:
        # bug: under launchd (no LANG) Popen's locale encoding could not encode Polish text in a diff
        polish = "za\u017c\u00f3\u0142\u0107"
        envelope = {"result": json.dumps({"lesson": polish}, ensure_ascii=False), "usage": {}}
        with open(os.path.join(self.capture_dir, "envelope.json"), "w", encoding="utf-8") as f:
            json.dump(envelope, f, ensure_ascii=False)
        self.fake_exe("claude", 'cat > "$CAPTURE/stdin"\ncat "$CAPTURE/envelope.json"\n')
        # The text reaches the child JSON-escaped (pure ASCII): non-ASCII argv under an ASCII locale
        # becomes lone surrogates before run_claude ever sees it. The child reports whether its locale
        # encoding can encode the text; where it can, this test proves nothing and is skipped. Where
        # en_US.ISO8859-1 is not installed (Linux farm), glibc falls back to C/ASCII — still non-UTF-8.
        child = ("import json, locale, sys; sys.path.insert(0, sys.argv[1]); import zuvo_review_llm as llm\n"
                 "text = json.loads(sys.argv[2]); enc = locale.getpreferredencoding(False)\n"
                 "try:\n    text.encode(enc); locale_can = True\n"
                 "except (UnicodeEncodeError, LookupError):\n    locale_can = False\n"
                 "r = llm.run_claude(text, 'm', 'e', 30)\n"
                 "print(json.dumps([enc, locale_can, r.error, r.answer]))")
        env = dict(os.environ, LC_ALL="en_US.ISO8859-1", PYTHONUTF8="0")
        env.pop("PYTHONIOENCODING", None)
        out = subprocess.run([sys.executable, "-c", child, str(ZUVO_HOME_SRC), json.dumps(polish)],
                             capture_output=True, env=env, timeout=60, check=True).stdout
        enc, locale_can, error, answer = json.loads(out)
        if locale_can:
            self.skipTest(f"the child's locale encoding {enc} can encode the text")
        self.assertEqual(("", {"lesson": polish}), (error, answer))
        with open(os.path.join(self.capture_dir, "stdin"), "rb") as f:
            self.assertEqual(polish.encode(), f.read())

    def test_failure_after_start_kills_the_group_and_never_escapes_as_exception(self) -> None:
        # bug: an error (or Ctrl-C) while talking to claude left it and its children running
        import zuvo_review_llm as llm
        for exc, escapes in ((RuntimeError("pipe broke"), False), (KeyboardInterrupt(), True)):
            with self.subTest(exc=type(exc).__name__):
                pidfile = os.path.join(self.capture_dir, f"{type(exc).__name__}.pids")
                self.fake_exe("claude", SLEEPER_FAKE.format(pids=pidfile))
                self.reap_on_cleanup(pidfile)
                failing = _failing_popen(llm.subprocess.Popen, pidfile, exc)
                with mock.patch.object(llm.subprocess, "Popen", failing):
                    if escapes:
                        with self.assertRaises(type(exc)):
                            llm.run_claude("p", model="m", effort="e", timeout=30)
                    else:
                        r = llm.run_claude("p", model="m", effort="e", timeout=30)
                        self.assertEqual((None, None), (r.rc, r.answer))
                        self.assertTrue(r.error.startswith("RuntimeError"), r.error)
                self.assertFalse(any_alive_after(read_pids(pidfile), 3.0), "claude or its child survived")

    def test_answer_object_is_found_among_prose_and_braces(self) -> None:
        # bug: a valid answer next to prose holding a brace was sliced first-"{" to last-"}" and lost
        import zuvo_review_llm as llm
        table = [
            ('{"defects": []} -- note: the fix wraps it in a block }', {"defects": []}),
            ('Use {braces} carefully: {"defects": [1]}', {"defects": [1]}),
            ('```json\n{"defects": [], "lessons": ["x"]}\n```', {"defects": [], "lessons": ["x"]}),
            ('{"a": 1} and also {"b": 2}', {"a": 1}),
            ('[1, 2] then {"a": 1}', {"a": 1}),
        ]
        for result, want in table:
            with self.subTest(result=result):
                self._fake_result(result)
                r = llm.run_claude("p", model="m", effort="e", timeout=30)
                self.assertEqual((want, ""), (r.answer, r.error))

    def test_reply_without_a_json_object_is_an_error(self) -> None:
        # bug: a reply with no object was recorded as an empty judgement
        import zuvo_review_llm as llm
        for result in ("nothing here", "only {broken json", "[1, 2]"):
            with self.subTest(result=result):
                self._fake_result(result)
                r = llm.run_claude("p", model="m", effort="e", timeout=30)
                self.assertIsNone(r.answer)
                self.assertTrue(r.error.startswith("ValueError"), r.error)

    def test_expected_keys_pick_the_real_answer_not_an_example_or_a_fragment(self) -> None:
        # bug: an example object in prose, or an inner dict of a truncated answer, became the judgement
        import zuvo_review_llm as llm
        keys = ("defects", "lessons")
        table = [
            ('Format: {"id": 1}. Answer: {"defects": [], "lessons": ["l"]}',
             {"defects": [], "lessons": ["l"]}, ""),
            ('{"defects": [], "lessons": [], "extra": 1}', {"defects": [], "lessons": [], "extra": 1}, ""),
            ('{"defects": [{"file": "a.py"}, {"fi', None, "no JSON object with keys"),
            ('{"defects": []}', None, "no JSON object with keys"),
        ]
        for result, want, error_part in table:
            with self.subTest(result=result):
                self._fake_result(result)
                r = llm.run_claude("p", model="m", effort="e", timeout=30, expect_keys=keys)
                self.assertEqual(want, r.answer)
                self.assertIn(error_part, r.error)

    def test_result_that_is_already_an_object_is_used_as_is(self) -> None:
        # bug: str() of a dict result is a Python repr, which no JSON parser reads back
        import zuvo_review_llm as llm
        self._fake_result({"defects": [], "note": "it's"})
        r = llm.run_claude("p", model="m", effort="e", timeout=30)
        self.assertEqual(({"defects": [], "note": "it's"}, ""), (r.answer, r.error))

    def test_deeply_nested_json_is_an_error_not_a_crash(self) -> None:
        # bug: RecursionError from a pathological reply escaped run_claude and killed the worker
        import zuvo_review_llm as llm
        deep = "[" * 1_000_000 + "]" * 1_000_000  # deep enough for RecursionError on 3.14's stack-based limit
        table = [("stdout", deep), ("result", json.dumps({"result": deep, "usage": {}}))]
        for where, stdout in table:
            with self.subTest(where=where):
                self._fake_stdout(stdout)
                r = llm.run_claude("p", model="m", effort="e", timeout=30)
                self.assertIsNone(r.answer)
                self.assertNotEqual("", r.error)

    def test_rate_limit_text_on_stdout_reaches_cli_error(self) -> None:
        # bug: a limit message printed on stdout (not an envelope, or before a hang) was invisible to
        # the limit check, so the tick kept paying for retries
        import zuvo_review_llm as llm
        table = [("echo 'You hit your limit'\n", 30), ("echo 'You hit your limit'\nexec sleep 15\n", 1)]
        for body, timeout in table:
            with self.subTest(timeout=timeout):
                self.fake_exe("claude", body)
                r = llm.run_claude("p", model="m", effort="e", timeout=timeout)
                self.assertIn("You hit your limit", r.cli_error)

    def test_children_left_behind_by_a_finished_call_are_killed(self) -> None:
        # bug: a call that exited normally left its background children (MCP servers) running
        import zuvo_review_llm as llm
        for code in (0, 3):
            with self.subTest(exit=code):
                pidfile = os.path.join(self.capture_dir, f"done{code}.pids")
                envelope = '{"result":"{}","usage":{}}'
                self.fake_exe("claude", f'sleep 15 >/dev/null 2>&1 &\n'
                                        f'echo "$$ $!" > "{pidfile}.tmp" && mv "{pidfile}.tmp" "{pidfile}"\n'
                                        f"cat >/dev/null\necho '{envelope}'\nexit {code}\n")
                self.reap_on_cleanup(pidfile)
                r = llm.run_claude("p", model="m", effort="e", timeout=30)
                self.assertEqual(code, r.rc)
                self.assertFalse(any_alive_after(read_pids(pidfile)[1:], 3.0), "a child survived the call")

    def _fake_result(self, result: object) -> None:
        self._fake_stdout(json.dumps({"result": result, "usage": {}}))

    def _fake_stdout(self, text: str) -> None:
        with open(os.path.join(self.capture_dir, "envelope.json"), "w", encoding="utf-8") as f:
            f.write(text)
        self.fake_exe("claude", 'cat "$CAPTURE/envelope.json"\n')

    def test_nonzero_exit_is_an_error_even_with_a_parsable_answer(self) -> None:
        # bug: a crashed CLI that still printed a JSON envelope was recorded as a judgement
        import zuvo_review_llm as llm
        self.fake_exe("claude", FAKE_OK + "exit 3\n")
        r = llm.run_claude("p", model="m", effort="e", timeout=30)
        self.assertEqual((3, None), (r.rc, r.answer))
        self.assertTrue(r.error.startswith("exit 3:"), r.error)

    def test_cost_is_a_float_or_none(self) -> None:
        # bug: a string or boolean cost reached the 24 h sum and crashed `--status`
        import zuvo_review_llm as llm
        for raw, want in (('"0.25"', None), ("true", None), ("null", None), ("1", 1.0), ("0.5", 0.5)):
            with self.subTest(raw=raw):
                envelope = f'{{"result":"{{}}","total_cost_usd":{raw},"usage":{{}}}}'
                self.fake_exe("claude", f"echo '{envelope}'\n")
                self.assertEqual(want, llm.run_claude("p", model="m", effort="e", timeout=30).usage["usd"])

    def test_argv_rejected_by_popen_is_an_error_not_a_raise(self) -> None:
        # bug: a NUL in the model name raised ValueError out of the worker thread
        import zuvo_review_llm as llm
        self.fake_exe("claude", FAKE_OK)
        r = llm.run_claude("p", model="m\x00x", effort="e", timeout=30)
        self.assertEqual((None, None), (r.rc, r.answer))
        self.assertTrue(r.error.startswith("ValueError"), r.error)

    def test_cli_error_envelope_is_an_error_even_with_rc_0(self) -> None:
        # bug: an is_error / error_* answer carrying a JSON-looking result was recorded as verdicts
        import zuvo_review_llm as llm
        table = [
            '{"is_error":true,"result":"Error: {\\"defects\\": []}","usage":{}}',
            '{"is_error":false,"subtype":"error_max_turns","result":"{\\"defects\\": []}","usage":{}}',
        ]
        for envelope in table:
            with self.subTest(envelope=envelope):
                self.fake_exe("claude", f"cat <<'EOF'\n{envelope}\nEOF\n")
                r = llm.run_claude("p", model="m", effort="e", timeout=30)
                self.assertEqual((0, None), (r.rc, r.answer))
                self.assertTrue(r.error.startswith("CLIError"), r.error)

    def test_timeout_keeps_the_stderr_already_written(self) -> None:
        # bug: a "usage limit" printed before the hang was dropped, so the tick kept retrying
        import zuvo_review_llm as llm
        self.fake_exe("claude", "echo 'You hit your limit' >&2\nexec sleep 15\n")
        r = llm.run_claude("p", model="m", effort="e", timeout=1)
        self.assertIsNone(r.rc)
        self.assertIn("You hit your limit", r.cli_error)

    def test_missing_claude_binary_is_an_error_with_no_rc(self) -> None:
        # bug: FileNotFoundError escaped and was retried as a crash every tick
        import zuvo_review_llm as llm
        self.setenv(PATH=self.bin)
        r = llm.run_claude("p", model="m", effort="e", timeout=30)
        self.assertEqual((None, None), (r.rc, r.answer))
        self.assertTrue(r.error.startswith(("FileNotFoundError", "OSError", "PermissionError")), r.error)

    def test_timeout_kills_the_whole_process_group(self) -> None:
        # bug: killing only `claude` orphaned its children (MCP servers) on every timed-out call
        import zuvo_review_llm as llm
        pidfile = os.path.join(self.capture_dir, "claude.pids")
        # the sleeper must outlive the 5 s reap wait + the 3 s poll, or a leak dies on its own in time
        self.fake_exe("claude", SLEEPER_FAKE.format(pids=pidfile))
        self.reap_on_cleanup(pidfile)
        r = llm.run_claude("p", model="m", effort="e", timeout=1)
        self.assertIsNone(r.rc)
        self.assertTrue(r.error.startswith("TimeoutExpired"), r.error)
        self.assertFalse(any_alive_after(read_pids(pidfile), 3.0), "claude or its child survived")


def _failing_popen(real: Any, pidfile: str, exc: BaseException) -> Any:
    """A Popen whose communicate() fails once claude is running (its pid file is written)."""
    class FailingPopen(real):
        def communicate(self, *a: Any, **k: Any) -> Any:
            wait_for(pidfile, 3.0)
            raise exc
    return FailingPopen


class ProdPathNormalizeTests(ReviewTestCase):
    def test_paths_are_normalized_before_matching(self) -> None:
        # bug: `README.md:12` (a ledger file cell) and an absolute path under a `docs/` checkout were
        # classified on their raw text — the first as production, the second as non-production
        import zuvo_review_prodpath as pp
        table = [
            ("README.md:12", None, False), ("a.json:3-5", None, False), ("./src/a.ts", None, True),
            ("./README.md", None, False), ("src/a.ts:7", None, True),
            ("/w/docs/proj/src/a.ts", "/w/docs/proj", True),
            ("/w/docs/proj/tests/a.py", "/w/docs/proj/", False),
            ("/elsewhere/src/a.ts", "/w/docs/proj", True),
        ]
        for path, root, want in table:
            with self.subTest(path=path, root=root):
                self.assertEqual(want, pp.is_production(path, root=root))


if __name__ == "__main__":
    unittest.main()
