"""pytest shim so tf-ablate can drive the bash hook suites (zuvo:mutation-test, 2026-09-29).

tf-ablate's runners are jest/vitest/pytest/codeception; the hook suites are bash scripts. Each
function runs ONE suite and fails when the suite exits non-zero — so a mutant a suite catches is
KILLED, exactly as with a native test. The mutation plan names these node ids in `specs`.
Not collected by default (file name does not match test_*.py); only named explicitly.
"""
import os
import signal
import subprocess

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
# The routing suites below take longer than the older hook suites; they get this budget explicitly, and
# the default stays the one every other suite had.
ROUTING_TIMEOUT = 900


def _exec(argv, timeout):
    """Run argv in its own process group; on timeout kill the WHOLE group (a suite's clients, a bats run
    under npx), not only the direct child, then fail. Returns (returncode, stdout, stderr)."""
    p = subprocess.Popen(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                         start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        out, err = p.communicate()
        raise AssertionError(f"{' '.join(argv)} timed out after {timeout}s (process group killed)\n"
                             f"{out[-3000:]}\n{err[-2000:]}")
    return p.returncode, out, err


def _run(rel, timeout=600):
    rc, out, err = _exec(["bash", os.path.join(ROOT, rel)], timeout)
    assert rc == 0, f"{rel} exit {rc}\n{out[-3000:]}\n{err[-2000:]}"


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
    rc, out, err = _exec(["bash", os.path.join(ROOT, "tests/adversarial/run.sh"), "test-todo-watchdog"], 600)
    assert rc == 0, f"test-todo-watchdog exit {rc}\n{out[-3000:]}\n{err[-2000:]}"


# ── the reviewer-routing suites (tests/mutation/reviewer-routing-plan.json, 2026-09-30) ──────────────
def test_model_run():
    _run("tests/hooks/test-model-run.sh", ROUTING_TIMEOUT)


def test_reviewer_preflight():
    _run("tests/hooks/test-reviewer-preflight-isolation.sh", ROUTING_TIMEOUT)


def test_model_subprocess():
    _run("tests/hooks/test-model-subprocess.sh", ROUTING_TIMEOUT)


def test_reviewer_lanes():
    _run("tests/hooks/test-reviewer-lanes.sh", ROUTING_TIMEOUT)


def test_audit_dispatch():
    _run("tests/skill-suite/test-test-audit-subprocess-dispatch.sh", ROUTING_TIMEOUT)


def test_install_wiring():
    _run("tests/hooks/test-install-wiring.sh", ROUTING_TIMEOUT)


def test_reviewer_route():
    _run("tests/hooks/test-reviewer-route-cross-vendor.sh", ROUTING_TIMEOUT)


def test_reviewer_model_builds():
    # a .bats file: the farm has no bats (run-all SKIPs it there), so npx provides the PINNED 1.11.0 when it
    # is missing. Never a skip: a skipped suite would report every mutant it guards as survived.
    import shutil
    bats = ["bats"] if shutil.which("bats") else ["npx", "--yes", "bats@1.11.0"]
    rc, out, err = _exec(bats + [os.path.join(ROOT, "scripts/tests/reviewer-model-builds.bats")], 2400)
    assert rc == 0, f"reviewer-model-builds.bats exit {rc}\n{out[-3000:]}\n{err[-2000:]}"


def test_all_hook_suites():
    """Tier 2: every hooks/ suite, so a survivor is also checked against indirect callers.
    smoke-global-dispatch needs an installed ~/.claude/hooks and is environment-only (testing.md §5)."""
    import glob
    failed = []
    for t in sorted(glob.glob(os.path.join(ROOT, "tests/hooks/test-*.sh"))) + \
             sorted(glob.glob(os.path.join(ROOT, "tests/hooks/smoke-*.sh"))):
        if t.endswith("smoke-global-dispatch.sh"):
            continue
        rc, _out, _err = _exec(["bash", t], 600)
        if rc != 0:
            failed.append(os.path.basename(t))
    assert not failed, "failed: " + ", ".join(failed)
