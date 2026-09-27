"""Temporary pytest bridge so tf-ablate can run the existing Bash suites.

The mutation engine has no Bash runner. Each test invokes the real repo harness in
its sandbox; pytest only forwards its verdict and does not replace assertions.
"""
from pathlib import Path
import subprocess
import re

ROOT = Path(__file__).resolve().parents[2]


def _run(name: str) -> None:
    result = subprocess.run(
        ["bash", "tests/adversarial/run.sh", name],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=600,
    )
    assert result.returncode == 0, result.stdout[-6000:] + result.stderr[-2000:]
    summary = re.search(r"^SUMMARY: (\d+) run, (\d+) passed, (\d+) failed$", result.stdout, re.MULTILINE)
    assert summary is not None, result.stdout[-2000:]
    run, passed, failed = map(int, summary.groups())
    assert run > 0 and failed == 0 and passed == run, result.stdout[-2000:]


def test_files_input_guard():
    _run("test-files-input-guard")


def test_smoke_all():
    _run("test-smoke-all")


def test_backward_compat():
    _run("test-backward-compat")


def test_d2_partial_status():
    _run("test-d2-partial-status")


def test_d3_single_provider_refusal():
    _run("test-d3-single-provider-refusal")


def test_provider_fanout_cap():
    _run("test-provider-fanout-cap")


def test_log_schema_marker():
    _run("test-log-schema-marker")


def test_codex_lane_defaults():
    _run("test-codex-lane-defaults")


def test_claude_reviewer_model():
    _run("test-claude-reviewer-model")


def test_provider_bench_cooldown():
    _run("test-provider-bench-cooldown")


def test_byteplus_billing_guard():
    _run("test-byteplus-billing-guard")


def test_qwen_lane():
    _run("test-qwen-lane")


def test_noverify_content_binding():
    result = subprocess.run(
        ["bash", "tests/hooks/test-noverify-content-binding.sh"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=600,
    )
    assert result.returncode == 0, result.stdout[-6000:] + result.stderr[-2000:]
    assert "FAIL=0" in result.stdout, result.stdout[-2000:]


def test_adversarial_runner_summary():
    result = subprocess.run(
        ["bash", "tests/hooks/test-adversarial-runner-summary.sh"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=60,
    )
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr[-2000:]
    assert result.stdout.count("PASS:") == 4, result.stdout[-2000:]
