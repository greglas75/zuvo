"""Temporary pytest bridge so tf-ablate can run the existing Bash suites.

The mutation engine has no Bash runner. Each test invokes the real repo harness in
its sandbox; pytest only forwards its verdict and does not replace assertions.
"""
from pathlib import Path
import subprocess
import re
import pytest

ROOT = Path(__file__).resolve().parents[2]


def _assert_harness_result(result: subprocess.CompletedProcess[str]) -> None:
    assert result.returncode == 0, result.stdout[-6000:] + result.stderr[-2000:]
    summary = re.search(r"^SUMMARY: (\d+) run, (\d+) passed, (\d+) failed$", result.stdout, re.MULTILINE)
    assert summary is not None, result.stdout[-2000:]
    run, passed, failed = map(int, summary.groups())
    assert run > 0 and failed == 0 and passed == run, result.stdout[-2000:]


def _run(name: str) -> None:
    result = subprocess.run(
        ["bash", "tests/adversarial/run.sh", name],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=600,
    )
    _assert_harness_result(result)


@pytest.mark.parametrize(
    ("exit_code", "output"),
    [
        (1, "SUMMARY: 1 run, 1 passed, 0 failed\n"),
        (0, "no summary\n"),
        (0, "SUMMARY: 0 run, 0 passed, 0 failed\n"),
        (0, "SUMMARY: 2 run, 1 passed, 0 failed\n"),
        (0, "SUMMARY: 2 run, 1 passed, 1 failed\n"),
    ],
    ids=["nonzero-exit", "missing-summary", "zero-run", "mismatched-counts", "failed-assertion"],
)
def test_harness_verdict_rejects_invalid_results(exit_code: int, output: str) -> None:
    result = subprocess.CompletedProcess(["fake-harness"], exit_code, stdout=output, stderr="")
    with pytest.raises(AssertionError):
        _assert_harness_result(result)


def test_harness_verdict_accepts_matching_counts() -> None:
    result = subprocess.CompletedProcess(
        ["fake-harness"], 0, stdout="SUMMARY: 2 run, 2 passed, 0 failed\n", stderr=""
    )
    _assert_harness_result(result)


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


def test_kimi_effort():
    _run("test-kimi-effort")


def test_provider_outcome_classification():
    _run("test-provider-outcome-classification")


def test_provider_outcome_refactor_regression():
    _run("test-provider-outcome-refactor-regression")


def test_openrouter_response():
    _run("test-openrouter-response")


def test_openrouter_response_refactor_regression():
    _run("test-openrouter-response-refactor-regression")


def test_noverify_content_binding():
    result = subprocess.run(
        ["bash", "tests/hooks/test-noverify-content-binding.sh"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=600,
    )
    assert result.returncode == 0, result.stdout[-6000:] + result.stderr[-2000:]
    assert re.search(r"(?m)^  --- noverify content binding: PASS=[1-9][0-9]* FAIL=0$", result.stdout), result.stdout[-2000:]


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
