"""scripts/zuvo-home/review-escapes --classify (zuvo_escapes_classify) and the run-level rules around it —
the store lock held for the whole run, the deadline — plus the git batch reader (zuvo_escapes_gitbatch).

Every case runs on a real temporary git repository; --classify runs a fake `claude` on PATH that
records each prompt it is sent and answers from a file (or, for prompts holding a marker, from another)."""

from __future__ import annotations

import datetime as dt
import io
import json
import os
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from escapes_testlib import NOW, EscapesTestCase, lines, load_launcher  # noqa: E402

BASE = lines("def total(a, b):", "    x = a", "    y = b", "    return x + y", "")
SIGNS = lines("def total(a, b):", "    x = -a", "    y = -b", "")
PROMPT_END = "=====END-OF-PROMPT====="

FAKE_CLAUDE = """\
prompt=$(cat)
echo call >> "{count}"
printf '%s\\n{end}\\n' "$prompt" >> "{prompts}"
bad=$(cat "{marker}" 2>/dev/null)
if [ -n "$bad" ] && printf '%s' "$prompt" | grep -qF -- "$bad"; then cat "{bad_answer}"
else cat "{answer}"; fi
"""


class ClassifyCase(EscapesTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.count = os.path.join(self.tmp, "calls")
        self.prompt_log = os.path.join(self.tmp, "prompts")
        self.marker = os.path.join(self.tmp, "bad-marker")
        self.answer = os.path.join(self.tmp, "answer.json")
        self.bad_answer = os.path.join(self.tmp, "bad-answer.json")
        self.fake_exe("claude", FAKE_CLAUDE.format(count=self.count, prompts=self.prompt_log, end=PROMPT_END,
                                                   marker=self.marker, answer=self.answer,
                                                   bad_answer=self.bad_answer))

    @staticmethod
    def envelope(obj: object) -> str:
        return json.dumps({"type": "result", "subtype": "success", "is_error": False,
                           "result": json.dumps(obj), "usage": {"input_tokens": 10, "output_tokens": 5}})

    def reply(self, obj: object) -> None:
        self.write(self.answer, self.envelope(obj))

    def reply_badly_to(self, marker: str, obj: object) -> None:
        """Prompts holding `marker` get `obj` as the answer instead of the usual one."""
        self.write(self.marker, marker)
        self.write(self.bad_answer, self.envelope(obj))

    def calls(self) -> int:
        if not os.path.exists(self.count):
            return 0
        with open(self.count, encoding="utf-8") as f:
            return len(f.read().split())

    def prompts(self) -> list[str]:
        if not os.path.exists(self.prompt_log):
            return []
        with open(self.prompt_log, encoding="utf-8") as f:
            return [p.strip("\n") for p in f.read().split(PROMPT_END) if p.strip()]

    def build_pairs(self, n: int) -> None:
        """n escape pairs: each its own intro commit and its own fix, two lines per pair; the fix of
        m{n-1} is the newest."""
        r = self.repo
        names = [f"apps/api/src/m{i}.py" for i in range(n)]
        r.commit("init", {p: BASE for p in names}, days_ago=60)
        for i, p in enumerate(names):
            r.commit(f"feat: m{i}", {p: SIGNS}, days_ago=30 - i)
        for i, p in enumerate(names):
            r.commit(f"fix(m{i}): sign", {p: BASE}, days_ago=10 - i)

    def run_at(self, now: dt.datetime, *argv: str) -> dict:
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            rc = load_launcher().main(["--repo", self.repo.path, "--ref", "develop", "--json", *argv],
                                      now=now)
        self.assertEqual(0, rc, out.getvalue())
        return json.loads(out.getvalue())

    def classified(self) -> dict[str, str | None]:
        """intro file -> its stored class (one value per pair: every row of a pair holds the same)."""
        return {r["intro_file"]: r.get("class") for r in self.rows()}


class ClassifyTests(ClassifyCase):
    def test_valid_answer_is_stored_on_every_row_of_the_pair(self) -> None:
        # bug: one call per line multiplies cost, or only the first line of a pair gets the class
        self.build_pairs(1)
        self.reply({"class": "Off-by-one", "description": "sign flipped", "diff_catchable": True})
        s = self.summary("--classify")
        rows = self.rows()
        self.assertEqual(2, len(rows))
        self.assertEqual([("boundary", True, "sign flipped")] * 2,
                         [(r["class"], r["catchable"], r["class_reason"]) for r in rows])
        self.assertEqual((1, 1), (self.calls(), s["classify"]["classified"]))

    def test_invalid_answers_are_not_stored(self) -> None:
        # bug: a class outside the vocabulary, a non-boolean catchable or a missing key lands in the
        # store and skews every per-class rate built on it
        self.build_pairs(1)
        table = [
            ("unknown class", {"class": "banana", "description": "d", "diff_catchable": True}, "invalid"),
            ("non-string class", {"class": 3, "description": "d", "diff_catchable": True}, "invalid"),
            ("catchable as text", {"class": "logic", "description": "d", "diff_catchable": "yes"},
             "invalid"),
            ("null catchable on a whole diff", {"class": "logic", "description": "d", "diff_catchable": None},
             "invalid"),
            ("non-string description", {"class": "logic", "description": 7, "diff_catchable": True},
             "invalid"),
            ("missing key", {"class": "logic", "description": "d"}, "failed"),
        ]
        for label, answer, counter in table:
            with self.subTest(label):
                self.reply(answer)
                s = self.summary("--classify", "--reclassify")  # --reclassify: earlier attempts forgotten
                self.assertEqual([None, None], [r.get("class") for r in self.rows()])
                self.assertEqual(1, s["classify"][counter])

    def test_classify_max_bounds_the_calls_of_one_run(self) -> None:
        # bug: a first run over a long history makes one paid model call per escape with no ceiling
        self.build_pairs(3)
        self.reply({"class": "logic", "description": "d", "diff_catchable": False})
        s = self.summary("--classify", "--classify-max", "2")
        classified = {(r["fix_sha"], r["intro_sha"]) for r in self.rows() if r.get("class")}
        self.assertEqual((2, 2, 2), (self.calls(), len(classified), s["classify"]["calls"]))

    def test_classification_is_kept_on_rerun_unless_reclassify(self) -> None:
        # bug: every run pays again for pairs already classified, or --reclassify keeps stale classes
        self.build_pairs(1)
        self.reply({"class": "logic", "description": "d", "diff_catchable": False})
        self.summary("--classify")
        self.reply({"class": "numeric", "description": "e", "diff_catchable": True})
        self.summary("--classify")
        self.assertEqual((1, ["logic", "logic"]), (self.calls(), [r["class"] for r in self.rows()]))
        self.summary("--classify", "--reclassify")
        self.assertEqual((2, ["numeric", "numeric"]), (self.calls(), [r["class"] for r in self.rows()]))

    def test_without_classify_no_model_is_called(self) -> None:
        # bug: a plain scan spends model calls the operator never asked for
        self.build_pairs(1)
        self.reply({"class": "logic", "description": "d", "diff_catchable": False})
        s = self.summary()
        self.assertEqual((0, None), (self.calls(), s.get("classify")))

    def test_failed_call_is_counted_and_stores_nothing(self) -> None:
        # bug: a model failure (limit, crash) is stored as a class or aborts the scan's write
        self.build_pairs(1)
        self.write(self.answer, "not json at all")
        s = self.summary("--classify")
        self.assertEqual((1, 0), (s["classify"]["failed"], s["classify"]["classified"]))
        self.assertEqual([None, None], [r.get("class") for r in self.rows()])

    def test_failed_write_leaves_the_store_untouched_with_classify(self) -> None:
        # bug: classes are written apart from the scan rows, so a failed write after a paid call leaves a
        # half-updated store while the exit code promises nothing was written
        import zuvo_escapes_store as store
        self.build_pairs(1)
        self.reply({"class": "logic", "description": "d", "diff_catchable": True})
        self.summary()
        with open(self.store, "rb") as f:
            before = f.read()
        writes: list[int] = []

        def failing(path: str, fresh: list[dict], reclassify: bool = False) -> int:
            writes.append(len(fresh))
            raise OSError("disk full")

        with mock.patch.object(store, "upsert", failing), \
                mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            rc, _ = self.run_main("--json", "--classify", "--reclassify")
        with open(self.store, "rb") as f:
            self.assertEqual((2, 1, before), (rc, len(writes), f.read()))
        self.assertIn("disk full", err.getvalue())


class ReclassifyTests(ClassifyCase):
    def test_reclassify_replaces_every_classification_field(self) -> None:
        # bug: --reclassify writes the new class but keeps the old reason, time or model, so the store
        # says the new class was decided at the old time for the old reason
        self.build_pairs(1)
        self.reply({"class": "logic", "description": "first", "diff_catchable": False})
        self.run_at(NOW, "--classify")
        self.reply({"class": "numeric", "description": "second", "diff_catchable": True})
        later = NOW + dt.timedelta(hours=1)
        self.run_at(later, "--classify", "--reclassify")
        want = ("numeric", True, "second", later.strftime("%Y-%m-%dT%H:%M:%SZ"))
        self.assertEqual([want] * 2, [(r["class"], r["catchable"], r["class_reason"], r["classified_at"])
                                      for r in self.rows()])

    def test_rescan_does_not_bring_back_a_dropped_class(self) -> None:
        # bug: a plain rescan after --reclassify merges an old class back over the dropped one
        self.build_pairs(1)
        self.reply({"class": "logic", "description": "d", "diff_catchable": False})
        self.summary("--classify")
        self.summary("--reclassify")
        self.summary()
        self.assertEqual([None, None], [r.get("class") for r in self.rows()])


class ClassifyBudgetTests(ClassifyCase):
    def test_failing_pairs_at_the_head_do_not_starve_the_rest(self) -> None:
        # bug: a pair the model always refuses stores nothing, sorts first again on every run and uses
        # the whole --classify-max, so no other pair is ever classified
        self.build_pairs(3)
        self.reply({"class": "logic", "description": "d", "diff_catchable": False})
        self.reply_badly_to("apps/api/src/m2.py",
                            {"class": "banana", "description": "d", "diff_catchable": False})
        self.summary("--classify", "--classify-max", "1")
        self.summary("--classify", "--classify-max", "1")
        got = self.classified()
        self.assertEqual((2, None, "logic"),
                         (self.calls(), got["apps/api/src/m2.py"], got["apps/api/src/m1.py"]))

    def test_a_pair_is_given_up_after_three_failed_attempts(self) -> None:
        # bug: a pair no answer can classify is paid for again on every run, forever
        self.build_pairs(1)
        self.reply({"class": "banana", "description": "d", "diff_catchable": False})
        for _ in range(3):
            self.summary("--classify")
        s = self.summary("--classify")
        self.assertEqual((3, 1, 0), (self.calls(), s["classify"]["given_up"], s["classify"]["calls"]))
        self.summary("--classify", "--reclassify")  # a deliberate restart forgets the failed attempts
        self.assertEqual(4, self.calls())

    def test_consecutive_failed_calls_stop_the_classify_phase(self) -> None:
        # bug: a dead CLI (logged out, over its limit) is called for every pending pair, each call
        # waiting out its timeout
        self.build_pairs(5)
        self.write(self.answer, "not json at all")
        s = self.summary("--classify")
        self.assertEqual((3, 1, 2), (self.calls(), s["classify"]["stopped"], s["classify"]["pending"]))

    def test_deadline_bounds_the_classify_phase(self) -> None:
        # bug: --deadline stops the scan but not the model calls after it, so a scheduled run overruns
        # its slot by up to classify-max model timeouts
        self.build_pairs(1)
        self.reply({"class": "logic", "description": "d", "diff_catchable": False})
        self.summary()
        s = self.summary("--classify", "--deadline", "0")
        self.assertEqual((0, 1, True), (self.calls(), s["classify"]["deadline"], s["deadline_hit"]))

    def test_rows_failing_validation_are_counted_not_crashing(self) -> None:
        # bug: a stored row without an intro_file (an older schema, a hand edit) crashes the prompt
        # build with a TypeError, or vanishes from the count without a trace
        self.build_pairs(1)
        self.summary()
        [first, _] = self.rows()
        odd = {**first, "key": first["key"] + "-odd", "intro_file": None, "intro_line": "3"}
        with open(self.store, "a", encoding="utf-8") as f:
            f.write(json.dumps(odd) + "\n")
        self.reply({"class": "logic", "description": "d", "diff_catchable": False})
        s = self.summary("--classify")
        self.assertEqual((1, 1), (s["classify"]["invalid_rows"], s["classify"]["classified"]))


class ClassifyPromptTests(ClassifyCase):
    def build_big_intro(self) -> None:
        """One escape at the END of a file whose introducing commit also rewrote 700 lines at its top:
        the whole introducing diff is far longer than DIFF_MAX."""
        r = self.repo
        top = [f"value_{i:04d} = {i}  # original filler line" for i in range(700)]
        gap = [f"# gap {i}" for i in range(10)]
        tail = ["def total(a, b):", "    return a + b"]
        r.commit("init", {"apps/api/src/big.py": lines(*top, *gap, *tail)}, days_ago=60)
        changed = [t.replace("original", "rewritten") for t in top]
        buggy = ["def total(a, b):", "    return a - b  # ESCAPED_LINE_TOKEN"]
        r.commit("feat: rewrite", {"apps/api/src/big.py": lines(*changed, *gap, *buggy)}, days_ago=30)
        r.commit("fix(big): sign", {"apps/api/src/big.py": lines(*changed, *gap, *tail)}, days_ago=5)

    def test_escaped_hunk_comes_first_when_the_diff_is_cut(self) -> None:
        # bug: the length cut keeps the top of the diff, so the model judges catchability without ever
        # seeing the escaped line
        self.build_big_intro()
        self.reply({"class": "logic", "description": "d", "diff_catchable": True})
        self.summary("--classify")
        [prompt] = self.prompts()
        introducing = prompt.split("Commit that fixed it")[0]  # the fix's own small diff shows it anyway
        self.assertIn("ESCAPED_LINE_TOKEN", introducing)
        self.assertIn("[diff cut]", introducing)

    def test_cut_diff_accepts_cannot_tell(self) -> None:
        # bug: a model honestly unable to judge a cut diff is forced to guess true/false, or its null
        # is refused and the pair asked again on every run
        self.build_big_intro()
        self.reply({"class": "logic", "description": "d", "diff_catchable": None})
        s = self.summary("--classify")
        self.assertEqual((1, [("logic", None)]), (s["classify"]["classified"],
                                                  [(r["class"], r["catchable"]) for r in self.rows()]))

    def test_where_list_says_how_many_lines_it_left_out(self) -> None:
        # bug: the escaped-line list is cut at 40 entries without a word, so the model reads a 45-line
        # escape as a 40-line one
        r = self.repo
        r.commit("init", {"apps/api/src/many.py": lines(*(f"v{i} = {i}" for i in range(45)))}, days_ago=60)
        r.commit("feat: negate", {"apps/api/src/many.py": lines(*(f"v{i} = -{i}" for i in range(45)))},
                 days_ago=30)
        r.commit("fix(many): signs", {"apps/api/src/many.py": lines(*(f"v{i} = {i}" for i in range(45)))},
                 days_ago=5)
        self.reply({"class": "logic", "description": "d", "diff_catchable": True})
        self.summary("--classify")
        [prompt] = self.prompts()
        self.assertIn("(+5 more)", prompt)


class GitBatchTests(EscapesTestCase):
    def test_batch_reads_present_missing_and_spaced_names(self) -> None:
        # bug: a missing object whose name holds spaces is parsed as a found one (a crash on its "size"),
        # or one missing object shifts every later answer onto the wrong spec
        import zuvo_escapes_gitbatch as gb
        sha = self.repo.commit("init", {"a b.py": "x = 1\n", "c.py": "y = 2\n", "e.py": ""}, days_ago=1)
        specs = [f"{sha}:a b.py", f"{sha}:no such.py", f"{sha}:c.py", f"{sha}:e.py"]
        got = gb.cat_file(self.repo.path, specs)
        self.assertEqual([b"x = 1\n", None, b"y = 2\n", b""], list(got.values()))
        check = gb.cat_file(self.repo.path, [f"{sha[:10]}^{{commit}}", "f" * 40], check=True)
        self.assertEqual([sha.encode(), None], list(check.values()))

    def test_spec_holding_a_newline_is_answered_none(self) -> None:
        # bug: a spec git cannot be sent is dropped from the result, so a caller indexing it by spec
        # gets a KeyError instead of the documented None
        import zuvo_escapes_gitbatch as gb
        sha = self.repo.commit("init", {"c.py": "y = 2\n"}, days_ago=1)
        got = gb.cat_file(self.repo.path, ["a\nb", f"{sha}:c.py"])
        self.assertEqual({"a\nb": None, f"{sha}:c.py": b"y = 2\n"}, got)

    def test_spec_that_cannot_be_encoded_is_answered_none(self) -> None:
        # bug: a spec holding a lone high surrogate (a path no byte decoding produces) raises
        # UnicodeEncodeError out of the batch instead of being answered None like any unreadable spec
        import zuvo_escapes_gitbatch as gb
        sha = self.repo.commit("init", {"c.py": "y = 2\n"}, days_ago=1)
        got = gb.cat_file(self.repo.path, [f"{sha}:\ud800.py", f"{sha}:c.py"])
        self.assertEqual({f"{sha}:\ud800.py": None, f"{sha}:c.py": b"y = 2\n"}, got)

    def test_answers_stay_on_their_specs_across_process_chunks(self) -> None:
        # bug: feeding specs in chunks loses or shifts the answers at a chunk boundary
        import zuvo_escapes_gitbatch as gb
        sha = self.repo.commit("init", {f"f{i}.py": f"v = {i}\n" for i in range(4)}, days_ago=1)
        specs = [f"{sha}:f0.py", f"{sha}:f1.py", f"{sha}:gone.py", f"{sha}:f2.py", f"{sha}:f3.py"]
        with mock.patch.object(gb, "CHUNK", 2):
            got = gb.cat_file(self.repo.path, specs)
        self.assertEqual([b"v = 0\n", b"v = 1\n", None, b"v = 2\n", b"v = 3\n"], [got[s] for s in specs])

    def test_malformed_batch_output_is_an_error_not_a_missing_object(self) -> None:
        # bug: a header the reader cannot parse is read as "missing", and every later answer of the
        # stream is then read from the wrong offset
        import zuvo_escapes_fixwalk as fw
        import zuvo_escapes_gitbatch as gb
        oid = "a" * 40
        table = [("garbage", "garbage header\\n"), ("negative size", f"{oid} blob -1\\n"),
                 ("no size", f"{oid} blob\\n"), ("content not ended by a newline", f"{oid} blob 3\\nabcX"),
                 ("trailing garbage", f"{oid} blob 3\\nabc\\nextra\\n")]
        for label, output in table:
            with self.subTest(label):
                self.fake_exe("git", f"cat > /dev/null\nprintf '{output}'\n")
                with self.assertRaises(fw.GitError):
                    gb.cat_file(self.repo.path, ["HEAD:x.py"])

    def test_commit_time_of_a_short_or_malformed_header_is_none(self) -> None:
        # bug: an author line without a time (a hand-made or damaged commit) crashes with an IndexError
        import zuvo_escapes_gitbatch as gb
        table = [(b"tree t\nauthor \n\nmsg", None), (b"tree t\nauthor Bob\n\nmsg", None),
                 (b"tree t\nauthor Bob <b@x> notatime +0000\n\nmsg", None),
                 (b"tree t\nauthor Bob <b@x> 1700000000 +0000\n\nmsg", "1700000000")]
        for raw, want in table:
            with self.subTest(raw=raw):
                self.assertEqual(want, gb.commit_ts(raw, "author"))


class ClassifyInputTests(ClassifyCase):
    def test_a_naive_now_is_utc_whatever_the_local_zone(self) -> None:
        # bug: a naive `now` is read as the host's local time, so classified_at is off by the zone offset
        self.use_zone("Asia/Tokyo")
        self.build_pairs(1)
        self.reply({"class": "logic", "description": "d", "diff_catchable": False})
        self.run_at(NOW.replace(tzinfo=None), "--classify")
        self.assertEqual(["2026-10-01T12:00:00Z"] * 2, [r["classified_at"] for r in self.rows()])

    def test_a_pair_without_a_landing_time_is_asked_last(self) -> None:
        # bug: a row whose fix_landing_ts is null sorts as the NEWEST pair ("None" > "2026-…"), so a
        # damaged row is asked before every dated one
        import zuvo_escapes_classify as classify
        dated = {"key": "a", "fix_sha": "1" * 40, "intro_sha": "3" * 40, "intro_file": "x.py", "file": "x.py",
                 "intro_line": 1, "line_at_parent": 1, "fix_landing_ts": "2026-09-01T00:00:00Z"}
        undated = {**dated, "key": "b", "fix_sha": "2" * 40, "fix_landing_ts": None}
        self.assertEqual(["1" * 40, "2" * 40], [g[0]["fix_sha"] for g in classify.groups([undated, dated])])


class StoreKeepTests(EscapesTestCase):
    def test_lines_the_store_cannot_key_are_kept_verbatim(self) -> None:
        # bug: a row without a string key, or a line that is not JSON, is silently deleted by the next
        # rewrite — data the store cannot read is lost instead of kept
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": SIGNS}, days_ago=20)
        self.repo.commit("fix(app): sign", {"src/app.py": BASE}, days_ago=5)
        self.summary()
        odd = ['{"no_key": 1}', "not json at all", '{"key": 7}']
        with open(self.store, "a", encoding="utf-8") as f:
            f.write("".join(line + "\n" for line in odd))
        out = self.summary()
        with open(self.store, encoding="utf-8") as f:
            text = f.read().splitlines()
        self.assertEqual((odd, 3, 2), (text[-3:], out["kept_unkeyed"], len(text) - 3))


class MalformedRowTests(EscapesTestCase):
    def test_a_row_whose_sha_is_not_an_object_id_is_kept_but_never_used(self) -> None:
        # bug: a stored row with fix_sha `--output=x` is annotated, and the value reaches git's argv as an
        # option (here: git writes a file named x)
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": SIGNS}, days_ago=20)
        self.repo.commit("fix(app): sign", {"src/app.py": BASE}, days_ago=5)
        self.summary()
        [first, *_] = self.rows()
        odd = {k: v for k, v in first.items() if not k.startswith(("coverage", "flagged", "reviewed"))}
        odd = {**odd, "key": "zz-odd", "fix_sha": "--output=x"}
        with open(self.store, "a", encoding="utf-8") as f:
            f.write(json.dumps(odd, sort_keys=True) + "\n")
        out = self.summary("--since", "2d")
        [stored] = [r for r in self.rows() if r["key"] == "zz-odd"]
        self.assertEqual((odd, 1, False), (stored, out["coverage"]["malformed"],
                                           os.path.exists(os.path.join(self.repo.path, "x"))))


class LockTests(ClassifyCase):
    def test_held_lock_refuses_before_any_scan_or_model_call(self) -> None:
        # bug: the lock is only tried at the final write, so a run that will be refused first spends
        # its model calls — and a run that is not refused scans and classifies from a store view another
        # run is rewriting meanwhile
        self.build_pairs(1)
        self.reply({"class": "logic", "description": "d", "diff_catchable": False})
        self.summary()
        holder = self.hold_lock()
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            rc, _ = self.run_main("--json", "--classify")
        holder.kill()
        self.assertEqual((3, 0), (rc, self.calls()))
        self.assertIn("busy", err.getvalue())


if __name__ == "__main__":
    unittest.main()
