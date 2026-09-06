"""Execute the skill's real shell example: persistence is behavior, not wording."""

import json
import subprocess

from test_refactor_radar import RADAR, ROOT, RadarRepo


class RadarSkillOutput(RadarRepo):
    def setUp(self):
        super().setUp()
        self.write(".radar.json", json.dumps({"min_cc": 1, "remote": "none"}))
        self.commit("chore: fixture profile")
        self.queue = self.write("zuvo/refactor-queue.md", "Approved queue: do not replace.\n")
        self.original_status = self.git("status", "--porcelain")

    def run_example(self, **options):
        skill = (ROOT / "skills/refactor-radar/SKILL.md").read_text()
        start = "# >>> zuvo:refactor-radar-generate\n"
        end = "# <<< zuvo:refactor-radar-generate"
        example = skill.split(start, 1)[1].split(end, 1)[0]
        env = dict(self.env, RADAR=str(RADAR), REPO_ROOT=str(self.repo), TOP="50")
        # Prevent the developer machine's output override leaking into the fixture.
        env.pop("ZUVO_OUTPUT_DIR", None)
        env.update(options)
        proc = subprocess.run(
            ["bash", "-eu", "-c", example], cwd=self.home,
            env=env, capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.queue.read_text(), "Approved queue: do not replace.\n")
        return proc

    def test_default_example_saves_all_raw_results_without_registration(self):
        self.run_example()
        reports = list((self.repo / "zuvo/reports").glob("refactor-radar-*/discovery.json"))
        self.assertEqual(len(reports), 1, "A stdout table is not a saved result")
        report = json.loads(reports[0].read_text())
        self.assertEqual(report["meta"]["sha"], self.git("rev-parse", "HEAD"))
        self.assertEqual(len(report["rows"]), 2)
        self.assertEqual({p for r in report["rows"] for p in r["files"]},
                         {"src/order-service.ts", "src/unrelated.ts"})
        self.assertTrue(all(r["availability"] == "FREE" for r in report["rows"]))
        self.assertFalse((self.repo / "zuvo/radar-history").exists())

    def test_repeated_runs_preserve_the_previous_artifact(self):
        self.run_example()
        before = {p: p.read_bytes() for p in (self.repo / "zuvo/reports").rglob("*.json")}
        self.assertEqual(len(before), 1)
        self.run_example()
        self.assertEqual(len(list((self.repo / "zuvo/reports").rglob("*.json"))), 2)
        for path, content in before.items():
            self.assertEqual(path.read_bytes(), content)

    def test_unknown_availability_still_saves_the_results(self):
        self.write(".radar.json", json.dumps({"min_cc": 1, "remote": "auto"}))
        self.commit("chore: provider cannot be identified")
        self.run_example()
        target = next((self.repo / "zuvo/reports").rglob("discovery.json"))
        report = json.loads(target.read_text())
        self.assertFalse(report["meta"]["busy"]["complete"])
        self.assertEqual(len(report["rows"]), 2)
        self.assertTrue(all(r["availability"] == "UNKNOWN" for r in report["rows"]))

    def test_empty_shortlist_is_saved_with_its_exclusions(self):
        self.write(".radar.json", json.dumps({"min_cc": 1000, "remote": "none"}))
        self.commit("chore: high fixture floor")
        self.run_example()
        target = next((self.repo / "zuvo/reports").rglob("discovery.json"))
        report = json.loads(target.read_text())
        self.assertEqual(report["rows"], [])
        self.assertEqual(len(report["excluded_rows"]), 2)

    def test_short_chat_table_does_not_truncate_saved_json(self):
        self.run_example(TOP="1")
        target = next((self.repo / "zuvo/reports").rglob("discovery.json"))
        self.assertEqual(len(json.loads(target.read_text())["rows"]), 2)

    def test_explicit_json_path_is_honoured(self):
        target = self.home / "chosen output/discovery.json"
        self.run_example(RADAR_JSON=str(target))
        self.assertEqual(len(json.loads(target.read_text())["rows"]), 2)

    def test_output_override_is_anchored_outside_scope(self):
        output = self.home / "reports with spaces"
        self.run_example(ZUVO_OUTPUT_DIR=str(output), SCOPE="src")
        self.assertEqual(len(list(output.glob("reports/refactor-radar-*/discovery.json"))), 1)
        self.assertFalse((self.repo / "src/zuvo").exists())

    def test_explicit_no_save_does_not_create_artifacts(self):
        self.run_example(RADAR_NO_SAVE="1")
        self.assertEqual(self.git("status", "--porcelain"), self.original_status)
        self.assertFalse((self.repo / "zuvo/reports").exists())

    def test_dry_run_does_not_even_create_output_directories(self):
        self.run_example(RADAR_DRY_RUN="1")
        self.assertEqual(self.git("status", "--porcelain"), self.original_status)
        self.assertFalse((self.repo / "zuvo/reports").exists())
