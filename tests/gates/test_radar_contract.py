"""Medium contract tests: real CLI/files/git, no provider network or fake production."""

from __future__ import annotations

from copy import deepcopy
import json
import os
import random
import subprocess
import sys
from unittest.mock import patch

from test_refactor_radar import RadarRepo, ROOT
import radar_remote
import radar_cli
import radar_io


class RadarContract(RadarRepo):
    def test_path_validation_seed_52026_rejects_traversal_for_every_generated_path(self) -> None:
        generator = random.Random(52026)
        for _ in range(40):
            segment = "".join(generator.choice("abcdef012345_") for _ in range(12))
            path = "src/" + segment + ".ts"
            self.assertEqual(radar_remote.safe_path(path), path)
            for invalid in ("../" + path, "/" + path, path + "\n", "src/../" + segment):
                with (
                    self.subTest(path=invalid),
                    self.assertRaisesRegex(ValueError, "repository-relative path"),
                ):
                    radar_remote.safe_path(invalid)

    def test_github_pages_reject_repeated_or_malformed_provider_responses(self) -> None:
        for payload, message in [
            (json.dumps([{"filename": "src/a.ts"}] * 100), "repeated page"),
            (json.dumps({"error": "unavailable"}), "malformed page"),
        ]:
            with (
                self.subTest(message=message),
                patch.object(radar_remote, "command", return_value=payload),
                self.assertRaisesRegex(ValueError, message),
            ):
                radar_remote.gh_pages(self.repo, "repos/o/r/pulls/1/files")

    def envelope(self) -> dict:
        self.write(".radar.json", json.dumps({"repo_id": "fixture/product"}))
        return {
            "meta": {
                "repo": "fixture/product",
                "sha": self.git("rev-parse", "HEAD"),
                "complete": True,
                "version": "fixture-v1",
                "total_functions": 2,
            },
            "functions": [
                {
                    "file": "src/order-service.ts",
                    "name": "flat",
                    "line": 1,
                    "lines": 1,
                    "cyclomatic_complexity": 8,
                    "max_nesting_depth": 1,
                },
                {
                    "file": "src/order-service.ts",
                    "name": "deep",
                    "line": 2,
                    "lines": 1,
                    "cyclomatic_complexity": 5,
                    "max_nesting_depth": 4,
                },
            ],
        }

    def test_valid_codesift_envelope_controls_both_independent_maxima(self) -> None:
        envelope = self.home / "code.json"
        envelope.write_text(json.dumps(self.envelope()))
        report = self.scan("--engine", "codesift", "--codesift-json", str(envelope))
        row = self.row(report, "src/order-service.ts")
        self.assertEqual((row["sum"], row["n"], row["decisions"], row["max"], row["nest"]), (13, 2, 11, 8, 4))
        self.assertEqual(report["meta"]["parser_version"], "fixture-v1")

    def test_empty_failed_codesift_receipt_cannot_publish_a_clean_report(self) -> None:
        receipt = self.envelope()
        receipt["meta"].update(complete=False, total_functions=0)
        receipt["functions"] = []
        receipt["note"] = "git log timed out; cached empty result"
        source = self.home / "failed-scan.json"
        source.write_text(json.dumps(receipt))
        output = self.home / "must-not-look-clean.json"
        result = self.invoke(
            "--no-remote", "--engine", "codesift", "--codesift-json", str(source),
            "--json", str(output), expected=2,
        )
        self.assertIn("complete", result.stderr)
        self.assertFalse(output.exists())

    def test_zero_fix_churn_does_not_exclude_inherited_complexity(self) -> None:
        self.write("src/order-service.ts", """
export function inherited(x) {
  if (x) { if (x.a) { if (x.b) { return 1; } } }
  if (x && x.c) { return 2; }
  return 0;
}
""")
        self.commit("feat: import an existing service")
        row = self.row(self.scan(), "src/order-service.ts")
        self.assertEqual(row["fix"], 0)
        self.assertGreater(row["decisions"], 0)
        self.assertIsNone(row["excluded"])

    def test_name_hint_does_not_erase_an_unrelated_dirty_overlap(self) -> None:
        wt = self.home / "survey-logic"
        self.git("worktree", "add", "-q", "-b", "refactor/order-service-split", str(wt), "HEAD")
        self.write("src/unrelated.ts", "export function dirty() { return 2; }\n", repo=wt)
        report = self.scan()
        named = self.row(report, "src/order-service.ts")
        self.assertEqual(named["availability"], "UNKNOWN")
        self.assertIsNone(named["excluded"])
        self.assertIn("refactor/order-service-split", named["reservation_hints"])
        self.assertEqual(self.row(report, "src/unrelated.ts")["availability"], "BUSY")

    def test_codesift_duplicate_outside_scope_and_invalid_count_fail_without_output(self) -> None:
        clean = self.envelope()
        variants = []
        duplicate = deepcopy(clean)
        duplicate["functions"][1] = duplicate["functions"][0]
        variants.append((duplicate, "duplicate"))
        outside = deepcopy(clean)
        outside["functions"][0]["file"] = "outside.ts"
        variants.append((outside, "outside source census"))
        count = deepcopy(clean)
        count["meta"]["total_functions"] = 9
        variants.append((count, "incomplete function census"))
        boundary = deepcopy(clean)
        boundary["functions"][0]["cyclomatic_complexity"] = 0
        variants.append((boundary, "cyclomatic_complexity"))
        for variant, message in variants:
            with self.subTest(message=message):
                path = self.home / "code.json"
                path.write_text(json.dumps(variant))
                output = self.home / "never.json"
                proc = self.invoke(
                    "--no-remote",
                    "--engine",
                    "codesift",
                    "--codesift-json",
                    str(path),
                    "--json",
                    str(output),
                    expected=2,
                )
                self.assertIn(message, proc.stderr)
                self.assertFalse(output.exists())

    def selection(self, extra: tuple[str, ...] = ()) -> tuple[dict, list[str]]:
        self.write(".radar.json", json.dumps({"remote": "none"}))
        args = ["--min-cc", "1", "--fresh-days", "0", "--cutoff", "2026-09-05T12:00:00Z", *extra]
        path = self.home / "source-report.json"
        self.invoke(*args, "--json", str(path))
        report = json.loads(path.read_text())
        return {
            "input_fingerprint": report["meta"]["input_fingerprint"],
            "candidates": [
                {
                    "family": "src/order-service",
                    "type": "SIMPLIFY",
                    "write_scope": ["src/order-service.ts"],
                    "verification_scope": ["test: route's successful and empty inputs"],
                    "gates": {key: True for key in ("G1", "G2", "G3", "G4", "G5")},
                    "evidence": "Fixture's entrypoint, contracts, guards and stable seam inspected",
                }
            ],
        }, args

    def test_register_rejects_bad_gates_types_and_overlapping_scope(self) -> None:
        clean, args = self.selection()
        bad_gate = deepcopy(clean)
        bad_gate["candidates"][0]["gates"]["G1"] = False
        bad_type = deepcopy(clean)
        bad_type["candidates"][0]["type"] = "COVER"
        outside = deepcopy(clean)
        outside["candidates"][0]["write_scope"] = ["src/unrelated.ts"]
        duplicate = deepcopy(clean)
        duplicate["candidates"].append(deepcopy(duplicate["candidates"][0]))
        no_harness = deepcopy(clean)
        no_harness["candidates"][0]["verification_scope"] = []
        for variant in (bad_gate, bad_type, outside, duplicate, no_harness):
            with self.subTest(variant=variant["candidates"]):
                decisions = self.home / "decision.json"
                decisions.write_text(json.dumps(variant))
                queue = self.home / "never.md"
                proc = self.invoke(
                    *args, "--register", "--decisions", str(decisions), "--queue", str(queue), expected=2
                )
                self.assertIn("require measured FREE scope", proc.stderr)
                self.assertFalse(queue.exists())

    def test_register_unknown_is_not_ready_even_with_all_gates_attested(self) -> None:
        decision, args = self.selection(("--no-remote",))
        path = self.home / "decision.json"
        path.write_text(json.dumps(decision))
        queue = self.home / "never.md"
        proc = self.invoke(*args, "--register", "--decisions", str(path), "--queue", str(queue), expected=2)
        self.assertIn("FREE", proc.stderr)
        self.assertFalse(queue.exists())

    def test_hub_and_dedupe_intents_use_supported_batch_types(self) -> None:
        decision, args = self.selection()
        for intent, canonical in [("HUB_SPLIT", "SPLIT_FILE"), ("DEDUPE", "EXTRACT_METHODS")]:
            with self.subTest(intent=intent):
                decision["candidates"][0]["type"] = intent
                path = self.home / "decision.json"
                path.write_text(json.dumps(decision))
                queue = self.home / (intent + ".md")
                self.invoke(*args, "--register", "--decisions", str(path), "--queue", str(queue))
                self.assertIn(f"- [ ] src/order-service.ts | {canonical} | Score:", queue.read_text())
                self.assertIn("# intent=" + intent, queue.read_text())

    def test_bad_managed_pointer_and_missing_bundle_source_preserve_existing_files(self) -> None:
        target = self.home / "bundle"
        (target / "current").mkdir(parents=True)
        sentinel = target / "current/keep.txt"
        sentinel.write_text("owned by another tool")
        command = [
            "bash",
            "-c",
            'source "$1"; install_refactor_radar_bundle "$2"',
            "fixture",
            str(ROOT / "scripts/install.sh"),
            str(target),
        ]
        outcome = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(outcome.returncode, 1)
        self.assertIn("not a managed symlink", outcome.stdout + outcome.stderr)
        self.assertEqual(sentinel.read_text(), "owned by another tool")
        empty_source = self.home / "incomplete source"
        empty_source.mkdir()
        unused_target = self.home / "not published"
        broken = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; ZUVO_DIR="$2"; install_refactor_radar_bundle "$3"',
                "fixture",
                str(ROOT / "scripts/install.sh"),
                str(empty_source),
                str(unused_target),
            ],
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(broken.returncode, 1)
        self.assertFalse((unused_target / "current").exists())

    def test_remote_identity_is_protocol_independent_and_redacts_ssh_userinfo(self) -> None:
        self.git("remote", "add", "origin", "https://github.com/owner/product.git")
        expected = self.scan()["meta"]["repo_id"]
        for url in (
            "git@github.com:owner/product.git",
            "ssh://fixture:private-secret@github.com/owner/product.git?key=query-secret",
            "fixture:private-secret@github.com:owner/product.git",
        ):
            with self.subTest(url=url):
                self.git("remote", "set-url", "origin", url)
                report = self.scan()
                self.assertEqual(report["meta"]["repo_id"], expected)
                self.assertNotIn("private-secret", json.dumps(report))
                self.assertNotIn("query-secret", json.dumps(report))

    def test_auto_provider_requires_exact_host_and_rejects_dot_segment_slugs(self) -> None:
        for cfg, url in (
            ({}, "https://unrelated.invalid/github.com/o/r"),
            ({"remote": "gh", "gh_repo": "../r"}, ""),
            ({"remote": "bb", "bb_repo": "o/..", "bb_user": "fixture"}, ""),
        ):
            with self.subTest(cfg=cfg, url=url), patch.object(radar_remote, "command") as transport:
                result = radar_remote.collect(self.repo, cfg, False, url)
                self.assertFalse(result["complete"])
                self.assertEqual(result["paths"], [])
                transport.assert_not_called()

    def test_github_promotion_requires_the_same_repository_not_only_branch_names(self) -> None:
        cfg = {"remote": "gh", "gh_repo": "o/r", "promotion_branches": [["develop", "main"]]}
        for owner, expected in (("fork/r", ["src/busy.ts"]), (None, ["src/busy.ts"]), ("o/r", [])):
            pr = {
                "number": 7,
                "head": {"ref": "develop", "sha": "a" * 40, "repo": {"full_name": owner}},
                "base": {"ref": "main", "repo": {"full_name": "o/r"}},
            }
            pages = [json.dumps([pr]), json.dumps([{"filename": "src/busy.ts"}])]
            with (
                self.subTest(owner=owner),
                patch.object(radar_remote, "command", side_effect=pages) as transport,
            ):
                result = radar_remote.collect(self.repo, cfg, False, "")
                self.assertTrue(result["complete"])
                self.assertEqual(result["paths"], expected)
                self.assertEqual(result["promotions"], [7] if owner == "o/r" else [])
                self.assertEqual(transport.call_count, 1 if owner == "o/r" else 2)

    def test_bitbucket_promotion_from_a_fork_remains_busy(self) -> None:
        cfg = {
            "remote": "bb",
            "bb_repo": "o/r",
            "bb_user": "fixture",
            "promotion_branches": [["develop", "main"]],
        }
        for owner, expected in (("fork/r", ["src/busy.ts"]), ("o/r", [])):
            pr = {
                "id": 7,
                "source": {
                    "branch": {"name": "develop"},
                    "commit": {"hash": "a" * 40},
                    "repository": {"full_name": owner},
                },
                "destination": {"branch": {"name": "main"}, "repository": {"full_name": "o/r"}},
            }
            pages = [{"values": [pr]}, {"values": [{"old": None, "new": {"path": "src/busy.ts"}}]}]
            with (
                self.subTest(owner=owner),
                patch.dict(os.environ, {"RADAR_BB_TOKEN": "private"}),
                patch.object(radar_remote, "bb_page", side_effect=pages) as transport,
            ):
                result = radar_remote.collect(self.repo, cfg, False, "")
                self.assertTrue(result["complete"])
                self.assertEqual(result["paths"], expected)
                self.assertEqual(result["promotions"], [7] if owner == "o/r" else [])
                self.assertEqual(transport.call_count, 1 if owner == "o/r" else 2)

    def test_unsafe_pagination_and_drive_paths_are_rejected_before_transport(self) -> None:
        prefix = "/2.0/repositories/o/r"
        for suffix in ("/pullrequests/..", "/pullrequests/./1", "/pullrequests\\other", "/pullrequests?x=\n"):
            with (
                self.subTest(suffix=suffix),
                patch.object(radar_remote, "build_opener") as transport,
                self.assertRaisesRegex(ValueError, "unsafe pagination URL"),
            ):
                radar_remote.bb_page("https://api.bitbucket.org" + prefix + suffix, prefix, "private")
            transport.assert_not_called()
        for path in ("C:/escape.py", "C:escape.py"):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "repository-relative path"):
                radar_remote.safe_path(path)

    def test_busy_file_preserves_unicode_line_separator_in_a_filename(self) -> None:
        path = "src/line\u2028separator.ts"
        self.write(path, "export function answer() { return 1; }\n")
        self.git("add", "--", path)
        self.git("commit", "-qm", "feat: unicode filename")
        busy = self.home / "busy.txt"
        busy.write_text(path + "\n", encoding="utf-8")
        report = self.scan("--busy-file", str(busy))
        self.assertEqual(self.row(report, path)["availability"], "BUSY")

    def test_input_devices_and_oversized_json_are_rejected_with_a_filename(self) -> None:
        source = self.home / "too-large.json"
        source.write_text('{"value":"too many bytes"}')
        with (
            patch.object(radar_cli.git, "MAX_TOTAL", 8),
            self.assertRaisesRegex(ValueError, "too-large.json"),
        ):
            radar_cli.load_json(source, "fixture")
        result = self.invoke("--config", "/dev/null", expected=2)
        self.assertIn("regular file", result.stderr)

    def test_failed_atomic_publication_leaves_no_partial_artifact_and_retry_is_idempotent(self) -> None:
        target = self.home / "outputs/report.json"
        with (
            patch.object(radar_io.os, "link", side_effect=OSError("fixture: publication failed")),
            self.assertRaisesRegex(OSError, "publication failed"),
        ):
            radar_cli.write_artifact(target, '{"value":"pełny"}\n')
        self.assertFalse(target.exists())
        self.assertEqual(list(target.parent.iterdir()), [])
        radar_cli.write_artifact(target, '{"value":"pełny"}\n')
        radar_cli.write_artifact(target, '{"value":"pełny"}\n')
        self.assertEqual(target.read_text(encoding="utf-8"), '{"value":"pełny"}\n')
        with self.assertRaisesRegex(ValueError, "different content"):
            radar_cli.write_artifact(target, "replacement")
        self.assertEqual(target.read_text(encoding="utf-8"), '{"value":"pełny"}\n')
        self.assertEqual(list(target.parent.iterdir()), [target])

    def test_oversized_output_is_rejected_before_any_directory_is_created(self) -> None:
        target = self.home / "oversize/report.json"
        with self.assertRaisesRegex(ValueError, "output exceeds byte limit"):
            radar_io.write_artifact(target, "ąąą", 5)
        self.assertFalse(target.parent.exists())

    def test_bundle_refuses_symlinked_target_without_writing_to_destination(self) -> None:
        destination = self.home / "other-tool"
        destination.mkdir()
        link = self.home / "redirected-bundle"
        link.symlink_to(destination, target_is_directory=True)
        result = subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; install_refactor_radar_bundle "$2"',
                "fixture",
                str(ROOT / "scripts/install.sh"),
                str(link),
            ],
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("must not be a symlink", result.stdout + result.stderr)
        self.assertEqual(list(destination.iterdir()), [])

    def test_subprocess_output_limit_failure_timeout_and_stdin_are_real(self) -> None:
        with self.assertRaisesRegex(ValueError, "response exceeded limit"):
            radar_io.command([sys.executable, "-c", "print('x'*32)"], self.repo, limit=8, timeout=5)
        with self.assertRaisesRegex(ValueError, "failed") as caught:
            radar_io.command(
                [sys.executable, "-c", "import sys;sys.stderr.write('private-secret');sys.exit(2)"],
                self.repo,
                limit=128,
                timeout=5,
            )
        self.assertNotIn("private-secret", str(caught.exception))
        with self.assertRaisesRegex(ValueError, "unavailable or timed out"):
            radar_io.command(
                [sys.executable, "-c", "import time;time.sleep(3)"], self.repo, limit=128, timeout=1
            )
        result = radar_io.command(
            [sys.executable, "-c", "import sys;print(sys.stdin.read().upper())"],
            self.repo,
            limit=128,
            timeout=5,
            input_bytes=b"value",
        )
        self.assertEqual(result, b"VALUE\n")
