"""pytest shim so tf-ablate can drive the bash hook suites (zuvo:mutation-test, 2026-09-29).

tf-ablate's runners are jest/vitest/pytest/codeception; the hook suites are bash scripts. Each
function runs ONE suite and fails when the suite exits non-zero — so a mutant a suite catches is
KILLED, exactly as with a native test. The mutation plan names these node ids in `specs`.
Not collected by default (file name does not match test_*.py); only named explicitly.
"""
import os
import subprocess

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def _run(rel, timeout=900):
    r = subprocess.run(["bash", os.path.join(ROOT, rel)], cwd=ROOT,
                       capture_output=True, text=True, timeout=timeout)
    assert r.returncode == 0, f"{rel} exit {r.returncode}\n{r.stdout[-3000:]}\n{r.stderr[-2000:]}"


def test_block_no_verify():
    _run("tests/hooks/test-block-no-verify.sh")


def test_farm_guard():
    _run("tests/hooks/test-farm-guard-vendored.sh")


def test_route_suite():
    _run("tests/hooks/test-route-suite-through-verify.sh")


def test_fast_paths():
    _run("tests/hooks/test-hook-fast-paths.sh")


def test_pre_push_gate():
    _run("tests/hooks/test-pre-push-gate.sh")


def test_todo_watchdog():
    # adversarial tests are not standalone: run.sh provides ROOT and the assert helpers
    r = subprocess.run(["bash", os.path.join(ROOT, "tests/adversarial/run.sh"), "test-todo-watchdog"],
                       cwd=ROOT, capture_output=True, text=True, timeout=600)
    assert r.returncode == 0, f"test-todo-watchdog exit {r.returncode}\n{r.stdout[-3000:]}\n{r.stderr[-2000:]}"


# ── the reviewer-routing suites (tests/mutation/reviewer-routing-plan.json, 2026-09-30) ──────────────
def test_model_run():
    _run("tests/hooks/test-model-run.sh")


def test_reviewer_preflight():
    _run("tests/hooks/test-reviewer-preflight-isolation.sh")


def test_model_subprocess():
    _run("tests/hooks/test-model-subprocess.sh")


def test_reviewer_lanes():
    _run("tests/hooks/test-reviewer-lanes.sh")


def test_audit_dispatch():
    _run("tests/skill-suite/test-test-audit-subprocess-dispatch.sh")


def test_install_wiring():
    _run("tests/hooks/test-install-wiring.sh")


def test_reviewer_route():
    _run("tests/hooks/test-reviewer-route-cross-vendor.sh")


def test_reviewer_model_builds():
    # a .bats file: the farm has no bats (run-all SKIPs it there), so npx provides one when it is missing
    import shutil
    bats = ["bats"] if shutil.which("bats") else ["npx", "--yes", "bats@1.11.0"]
    r = subprocess.run(bats + [os.path.join(ROOT, "scripts/tests/reviewer-model-builds.bats")], cwd=ROOT,
                       capture_output=True, text=True, timeout=2400)
    assert r.returncode == 0, (
        f"reviewer-model-builds.bats exit {r.returncode}\n{r.stdout[-3000:]}\n{r.stderr[-2000:]}")


def test_all_hook_suites():
    """Tier 2: every hooks/ suite, so a survivor is also checked against indirect callers.
    smoke-global-dispatch needs an installed ~/.claude/hooks and is environment-only (testing.md §5)."""
    import glob
    failed = []
    for t in sorted(glob.glob(os.path.join(ROOT, "tests/hooks/test-*.sh"))) + \
             sorted(glob.glob(os.path.join(ROOT, "tests/hooks/smoke-*.sh"))):
        if t.endswith("smoke-global-dispatch.sh"):
            continue
        r = subprocess.run(["bash", t], cwd=ROOT, capture_output=True, text=True, timeout=600)
        if r.returncode != 0:
            failed.append(os.path.basename(t))
    assert not failed, "failed: " + ", ".join(failed)
