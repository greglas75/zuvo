"""Run the install copy contract under pytest for farm mutation ablation."""

from pathlib import Path
import re
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def test_install_copy_verification_shell_contract():
    result = subprocess.run(
        ["bash", str(ROOT / "tests/hooks/test-install-copy-verification.sh")],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=900,      # the suite runs real installs; 60 s cut it off mid-run
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    # The summary with no failures, not a fixed count: the suite grows, and a pinned PASS=28 made every
    # run after the first new case fail here — which ablation then read as every mutant killed.
    assert re.search(r"install copy-verify: PASS=[1-9][0-9]* FAIL=0$", result.stdout, re.M), result.stdout
