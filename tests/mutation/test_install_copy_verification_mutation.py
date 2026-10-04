"""Run the install copy contract under pytest for farm mutation ablation."""

from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[2]


def test_install_copy_verification_shell_contract():
    result = subprocess.run(
        ["bash", str(ROOT / "tests/hooks/test-install-copy-verification.sh")],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert "install copy-verify: PASS=28 FAIL=0" in result.stdout
