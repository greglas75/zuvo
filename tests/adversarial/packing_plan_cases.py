"""Compare the public provider-free plan with actual controlled provider payloads."""

import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
DRIVER = ROOT / "scripts/adversarial-review.sh"


def diff_section(name, body):
    return f"diff --git a/{name} b/{name}\n--- a/{name}\n+++ b/{name}\n@@ -1 +1 @@\n+{body}\n"


class PackingPlanContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        capture = self.home / "mock-plan-capture"
        capture.write_text("""#!/usr/bin/env python3
import os,pathlib,sys,uuid
s=sys.stdin.buffer.read()
if b"--- CODE TO REVIEW ---\\n" in s: payload=s.split(b"--- CODE TO REVIEW ---\\n",1)[1]
else: payload=s.split(b"--- ARTIFACT BEGIN ---\\n",1)[1].rsplit(b"\\n--- ARTIFACT END ---",1)[0]
p=pathlib.Path(os.environ['PLAN_CAPTURE'])/str(uuid.uuid4());p.write_bytes(payload)
print('{"findings":[]}')
""")
        capture.chmod(0o755)
        self.capture = self.home / "captured"
        self.capture.mkdir()
        self.env = {
            **os.environ,
            "HOME": str(self.home),
            "ZUVO_HOME": str(self.home / "zuvo"),
            "PATH": str(self.home) + os.pathsep + os.environ["PATH"],
            "PLAN_CAPTURE": str(self.capture),
            "ZUVO_ADV_MAX_CHARS": "2000",
            "ZUVO_ADVERSARIAL_TEST_HARNESS": "1",
            "ZUVO_REVIEW_TEST_PROVIDERS": "mock-plan-capture",
            "LC_ALL": "C.UTF-8",
        }
        for name in ["ZUVO_ADV_CHUNK", "ZUVO_ADV_NO_CHUNK", "ZUVO_ADV_PASS_CAP", "ZUVO_RUN_ID"]:
            self.env.pop(name, None)

    def run_driver(self, payload, *args):
        return subprocess.run(
            ["bash", str(DRIVER), *args],
            input=payload,
            text=True,
            encoding="utf-8",
            capture_output=True,
            env=self.env,
            cwd=ROOT,
            timeout=60,
        )

    def plan(self, payload, *args):
        result = self.run_driver(payload, "--chunk-plan", "--json", *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def assert_dispatch_matches(self, payload, *args, expected_exit=None):
        plan = self.plan(payload, *args)
        self.assertEqual(list(self.capture.iterdir()), [], "planning must never call a provider")
        self.assertFalse((self.home / "zuvo/adversarial-findings.log").exists())
        result = self.run_driver(payload, "--single", "--provider", "mock-plan-capture", *args)
        self.assertEqual(
            result.returncode,
            expected_exit
            if expected_exit is not None
            else 4
            if any(c["truncated"] for c in plan["chunks"])
            else 0,
            result.stderr,
        )
        actual = sorted(hashlib.sha256(p.read_bytes()).hexdigest() for p in self.capture.iterdir())
        expected = sorted(c["review_input_sha256"] for c in plan["chunks"] if c["reviewable"])
        self.assertEqual(actual, expected)
        self.assertEqual(plan["planned_chunk_count"], len(plan["chunks"]))
        return plan

    def test_small_multibyte_input_keeps_character_activation_without_byte_reserve(self):
        plan = self.assert_dispatch_matches(diff_section("調査.ts", "📊" * 600))
        self.assertFalse(plan["chunked"])
        self.assertEqual(plan["byte_reserve"], 0)
        self.assertGreater(plan["normalized_input"]["bytes"], 2000)
        self.assertTrue(plan["complete"])

    def test_no_chunk_and_child_guards_disclose_real_truncation(self):
        payload = diff_section("a.ts", "x" * 1500) + diff_section("b.ts", "y" * 1500)
        plan = self.assert_dispatch_matches(payload, "--no-chunk")
        self.assertFalse(plan["complete"])
        self.assertTrue(plan["chunks"][0]["truncated"])

    def test_multi_hunk_partition_repeats_header_and_context_with_exact_dispatch(self):
        payload = diff_section("żółć.ts", "a" * 1100)
        payload += "@@ -8 +8 @@\n+" + "b" * 1100 + "\n=== CONTEXT: lifecycle owned by caller\n"
        plan = self.assert_dispatch_matches(payload)
        self.assertEqual(plan["planned_chunk_count"], 2)
        self.assertTrue(plan["complete"])
        self.assertEqual(sum(len(c["hunks"]) for c in plan["chunks"]), 2)

    def test_indivisible_hunk_is_reported_incomplete(self):
        payload = diff_section("huge.ts", "x" * 2400) + diff_section("small.ts", "ok")
        plan = self.assert_dispatch_matches(payload)
        self.assertFalse(plan["complete"])
        self.assertTrue(plan["chunks"][0]["truncated"])

    def test_files_content_with_incidental_hunks_is_not_split_as_diff(self):
        source = self.home / "input.ts"
        source.write_text("// content\n" + "x" * 1100 + "\n@@ not a diff\n" + "y" * 1100)
        plan = self.assert_dispatch_matches("", "--files", str(source))
        self.assertEqual(plan["planned_chunk_count"], 1)
        self.assertFalse(plan["complete"])

    def test_failed_hunk_split_retains_original_and_reports_incomplete_review(self):
        awk = shutil.which("awk")
        self.assertIsNotNone(awk, "awk is required by the canonical partitioner")
        self.env["REAL_AWK"] = awk
        fault = self.home / "awk"
        fault.write_text(
            "#!/usr/bin/env python3\nimport os,sys\n"
            "if any('function emit(' in a for a in sys.argv[1:]): sys.exit(1)\n"
            "os.execv(os.environ['REAL_AWK'], ['awk', *sys.argv[1:]])\n"
        )
        fault.chmod(0o755)
        payload = diff_section("huge.ts", "a" * 1400) + "@@ -8 +8 @@\n+" + "b" * 1400 + "\n"
        plan = self.assert_dispatch_matches(payload + diff_section("small.ts", "ok"))
        self.assertFalse(plan["complete"])
        self.assertEqual(plan["planned_chunk_count"], 2)

    def test_normalized_newlines_and_preamble_have_the_same_dispatch_identity(self):
        self.assert_dispatch_matches(
            "Untrusted preamble\r\n" + diff_section("żółć.ts", "📊" * 600).replace("\n", "\r\n") + "\n\n"
        )

    def test_large_single_hunk_uses_current_subhunk_split_and_matches_dispatch(self):
        body = "\n".join("+" + "x" * 100 for _ in range(45))
        payload = (
            "diff --git a/large.ts b/large.ts\n--- a/large.ts\n+++ b/large.ts\n@@ -0,0 +1,45 @@\n" + body
        )
        plan = self.assert_dispatch_matches(payload)
        self.assertGreater(plan["planned_chunk_count"], 1)
        self.assertTrue(plan["complete"])
        self.assertTrue(all(c["payload_bytes"] <= plan["payload_byte_budget"] for c in plan["chunks"]))

    def test_deleted_indivisible_content_is_explicitly_omitted_without_full_coverage_claim(self):
        payload = (
            "diff --git a/deleted.json b/deleted.json\ndeleted file mode 100644\n"
            "--- a/deleted.json\n+++ /dev/null\n@@ -1 +0,0 @@\n-" + "x" * 2500
        )
        plan = self.assert_dispatch_matches(payload)
        self.assertTrue(plan["input_omitted"])
        self.assertFalse(plan["complete"])
        self.assertTrue(plan["omission_notes"])
        self.assertEqual(plan["normalized_input"]["sha256"], hashlib.sha256(payload.encode()).hexdigest())

    def test_blank_document_preamble_chunk_cannot_claim_complete_review_coverage(self):
        payload = " " * 1200 + "\n### Task 1: first\n" + "a" * 600
        payload += "\n### Task 2: second\n" + "b" * 600 + "\n### Task 3: third\n" + "c" * 600
        plan = self.assert_dispatch_matches(payload, "--mode", "plan", expected_exit=2)
        self.assertFalse(plan["complete"])
        self.assertTrue(plan["unreviewable"])

    def test_files_mode_diff_examples_are_not_reported_as_real_input_hunks(self):
        source = self.home / "example.txt"
        source.write_text(diff_section("example.ts", "example"), encoding="utf-8")
        plan = self.assert_dispatch_matches("", "--files", str(source))
        self.assertEqual(plan["chunks"][0]["hunks"], [])

    def test_failed_json_emitter_is_nonzero_and_never_a_successful_plan(self):
        self.env["REAL_PYTHON"] = os.sys.executable
        python = self.home / "python3"
        python.write_text('#!/bin/sh\n[ "$1" != "-" ] || exit 42\nexec "$REAL_PYTHON" "$@"\n')
        python.chmod(0o755)
        result = self.run_driver(diff_section("a.ts", "ok"), "--chunk-plan")
        self.assertEqual(result.returncode, 42)
        self.assertEqual(result.stdout, "")
        self.assertEqual(list(self.capture.iterdir()), [])

    def test_context_trailer_diff_snippet_is_not_reported_as_an_input_hunk(self):
        payload = diff_section("a.ts", "value") + "=== CONTEXT: prior patch\n@@ -9 +9 @@\nold snippet"
        plan = self.assert_dispatch_matches(payload)
        self.assertEqual(len(plan["chunks"][0]["hunks"]), 1)

    def test_conflicting_dry_run_is_refused_instead_of_silently_overridden(self):
        result = self.run_driver(diff_section("a.ts", "value"), "--chunk-plan", "--dry-run")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(list(self.capture.iterdir()), [])

    def test_unicode_line_separators_in_source_do_not_invent_hunk_boundaries(self):
        payload = diff_section("a.ts", "value = 'a\u2028@@ -8 +8 @@\u2029end'")
        plan = self.assert_dispatch_matches(payload)
        self.assertEqual(len(plan["chunks"][0]["hunks"]), 1)

    def test_plan_mode_can_be_planned_repeatedly_without_spending_round_budget(self):
        payload = "# Plan\n### Task 1: first\nDo it.\n### Task 2: second\nDo it.\n### Task 3: third\nDo it.\n"
        self.env["ZUVO_PLAN_ROUND_BUDGET"] = "1"
        first = self.plan(payload, "--mode", "plan")
        second = self.plan(payload, "--mode", "plan")
        self.assertEqual(first["normalized_input"], second["normalized_input"])
        self.assertFalse((self.home / "zuvo/plan-budget").exists())
        self.assertEqual(list(self.capture.iterdir()), [])

    def test_child_guard_disables_recursive_packing_and_discloses_truncation(self):
        self.env["ZUVO_ADV_CHUNK"] = "1/2"
        plan = self.assert_dispatch_matches(
            diff_section("a.ts", "a" * 1400) + diff_section("b.ts", "b" * 1400)
        )
        self.assertFalse(plan["chunked"])
        self.assertFalse(plan["complete"])

    def test_planning_never_writes_requested_review_artifact(self):
        artifact = self.home / "review.txt"
        self.plan(diff_section("a.ts", "ok"), "--artifact", str(artifact))
        self.assertFalse(artifact.exists())
        self.assertEqual(list(self.capture.iterdir()), [])


# Table-generated named cases, like it.each: one encoding or byte boundary per test.
def encoding_case(text, filename):
    def check(self):
        payload = diff_section(filename, text * 160) + diff_section("b.ts", "b" * 1800)
        plan = self.assert_dispatch_matches(payload)
        self.assertEqual(plan["contract_version"], "zuvo-packing/1")

    return check


for case in json.loads((ROOT / "tests/fixtures/adversarial-packing/cases.json").read_text(encoding="utf-8")):
    setattr(
        PackingPlanContract,
        "test_encoding_" + case["name"].replace("-", "_"),
        encoding_case(case["text"], case.get("filename", "a.ts")),
    )


def byte_boundary_case(delta):
    def check(self):
        first = diff_section("a.ts", "a")
        first = diff_section("a.ts", "a" * (750 - len(first.encode()) + 1))
        second = diff_section("b.ts", "b")
        second = diff_section("b.ts", "b" * (750 + delta - len(second.encode()) + 1))
        plan = self.assert_dispatch_matches(first + second + diff_section("last.ts", "z" * 1700))
        self.assertEqual(plan["planned_chunk_count"], 3 if delta > 0 else 2)
        self.assertEqual(plan["payload_byte_budget"], 1500)

    return check


def activation_boundary_case(delta):
    def check(self):
        prefix = diff_section("a.ts", "a")
        second = diff_section("b.ts", "b")
        # Collector strips the final newline: the normalized character length is the target.
        padding = 2000 + delta + 1 - len(prefix + second)
        plan = self.assert_dispatch_matches(prefix + diff_section("b.ts", "b" * (padding + 1)))
        self.assertEqual(plan["normalized_input"]["characters"], 2000 + delta)
        self.assertEqual(plan["chunked"], delta > 0)

    return check


for delta, suffix in [(-1, "minus_one"), (0, "exact"), (1, "plus_one")]:
    setattr(PackingPlanContract, "test_byte_budget_" + suffix, byte_boundary_case(delta))
    setattr(PackingPlanContract, "test_activation_cap_" + suffix, activation_boundary_case(delta))

if __name__ == "__main__":
    unittest.main()
