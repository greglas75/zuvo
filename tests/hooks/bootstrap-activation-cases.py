#!/usr/bin/env python3
"""Execute the documented activation block against isolated installation fixtures."""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DOC = ROOT / "skills/refactor/references/bootstrap.md"
COMMAND_TIMEOUT = 20


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def activation_block():
    section = DOC.read_text().split("### PHASE 0 — Commit-gate activation", 1)[1]
    section = section.split("\n### ", 1)[0]
    blocks = re.findall(r"```bash\n(.*?)\n```", section, re.S)
    require(len(blocks) == 1, "activation must contain exactly one executable bash block")
    return blocks[0]


def substitute(block, variable, placeholder, value):
    original = f'{variable}="<{placeholder}>"'
    require(block.count(original) == 1, f"missing or ambiguous {variable} substitution")
    return block.replace(original, variable + "=" + shlex.quote(str(value)))


def check(layout, base):
    home = base / "isolated home"
    active = home / (".codex" if layout == "scripts" else "active plugin's root")
    target_repo = base / "target checkout's space"
    cwd_repo = base / "different caller checkout"
    for directory in (home, target_repo, cwd_repo):
        directory.mkdir(parents=True)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("GIT_CONFIG") and key not in
           ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE", "ZUVO_DISPATCH_ACTIVE")}
    env.update(HOME=str(home), GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
               GIT_CONFIG_NOSYSTEM="1")
    for directory in (target_repo, cwd_repo):
        subprocess.run(["git", "init", "-q", str(directory)], env=env, check=True, timeout=COMMAND_TIMEOUT)
    target = target_repo / "target's $(touch injected).py"
    target.write_text("fixture\n")
    gate = active / layout / "refactor-safety-gate.sh"
    gate.parent.mkdir(parents=True)
    gate.write_text("#!/bin/sh\nexit 0\n")
    gate.chmod(0o755)
    detector = gate.parent / "lib/agent-env.sh"
    detector.parent.mkdir()
    detector.write_text("zuvo_is_agent_env() { return 0; }\n")
    receipt = base / "installer receipt.json"
    checker = base / "check installer.py"
    checker.write_text(
        "import json, os, sys\n"
        "from pathlib import Path\n"
        "if sys.argv[1:] != [os.environ['EXPECTED_GATE'], os.environ['EXPECTED_REPO']]:\n"
        "    raise AssertionError(sys.argv)\n"
        "Path(os.environ['CALL_RECEIPT']).write_text(json.dumps(sys.argv[1:]))\n"
        "print('fixture installer diagnostic exit=' + os.environ['INSTALL_EXIT'])\n"
        "sys.exit(int(os.environ['INSTALL_EXIT']))\n"
    )
    installer = active / "scripts/install-refactor-gate.sh"
    installer.parent.mkdir(exist_ok=True)
    installer_text = f'#!/bin/sh\nexec {shlex.quote(sys.executable)} {shlex.quote(str(checker))} "$@"\n'
    installer.write_text(installer_text)
    # A complete, tempting inactive cache must never override the supplied active root.
    inactive = home / ".claude/plugins/cache/zuvo-marketplace/zuvo/000-inactive"
    for relative in ("scripts/install-refactor-gate.sh", "hooks/refactor-safety-gate.sh"):
        decoy = inactive / relative
        decoy.parent.mkdir(parents=True, exist_ok=True)
        decoy.write_text("#!/bin/sh\necho INACTIVE_CACHE_SELECTED >&2\nexit 94\n")
        decoy.chmod(0o755)
    block = substitute(activation_block(), "_TARGET_PATH", "actual target file or directory", target)
    block = substitute(block, "_INSTALL_ROOT", "installed root for the current harness", active)
    env.update(EXPECTED_GATE=str(gate), EXPECTED_REPO=str(target_repo.resolve()),
               CALL_RECEIPT=str(receipt))

    def run(expected, should_call=True):
        receipt.unlink(missing_ok=True)
        env["INSTALL_EXIT"] = str(expected)
        result = subprocess.run(["bash", "-u", "-c", block], cwd=cwd_repo,
                                env=env, text=True, capture_output=True, check=False, timeout=COMMAND_TIMEOUT)
        require(result.returncode == expected, (layout, expected, result.stdout, result.stderr))
        require("INACTIVE_CACHE_SELECTED" not in result.stdout + result.stderr, "inactive cache selected")
        require(f"exit={expected} repo={target_repo.resolve()} gate={gate}" in result.stdout,
                "activation receipt lost exit status, target repository or gate path")
        if should_call:
            require(json.loads(receipt.read_text()) == [str(gate), str(target_repo.resolve())],
                    "installer received incorrect arguments")
            require(f"fixture installer diagnostic exit={expected}" in result.stdout, "diagnostic missing")
        else:
            require(not receipt.exists(), "missing active helper fell back to an inactive cache")
        require(not (cwd_repo / "injected").exists(), "target path executed shell substitution")
        return result.stdout

    require("activation=verified" in run(0), "successful activation not reported")
    require("activation=unavailable" in run(3), "installer failure not reported")
    detector.unlink()
    require("harness=unavailable (detector missing)" in run(0), "missing detector not reported")
    installer.unlink()
    require("activation=unavailable" in run(2, should_call=False), "missing installer not reported")
    installer.write_text(installer_text)
    gate.unlink()
    # When hooks/ is absent, the snippet intentionally reports its scripts/ fallback.
    # Missing installer already tests unavailable for both layouts; check missing gate
    # separately without relying on that diagnostic path choice.
    receipt.unlink(missing_ok=True)
    result = subprocess.run(["bash", "-u", "-c", block], cwd=cwd_repo,
                            env=env, text=True, capture_output=True, check=False, timeout=COMMAND_TIMEOUT)
    require(result.returncode == 2 and not receipt.exists(), (result.stdout, result.stderr))
    print(f"PASS: activation {layout}/ layout uses actual target + active root; "
          "preserves 0/3/2 and diagnostics")


def check_mutation_helpers(base):
    home = base / "mutation helper home"
    home.mkdir()
    installer = ROOT / "scripts/install.sh"
    source = installer.read_text()
    block = source.split("  # Step 7: Copy scripts (benchmark.sh", 1)[1]
    block = block[block.index("  if [[ -d"):].split("    # ---- Codex event hooks:", 1)[0] + "fi\n"
    env = dict(os.environ, HOME=str(home))
    command = 'source "$1"\n' + block + '\ntest "$_vc_rc" -eq 0'
    result = subprocess.run(["bash", "-c", command, "mutation-install-test", str(installer)],
                            cwd=ROOT, env=env, text=True, capture_output=True, timeout=COMMAND_TIMEOUT)
    require(result.returncode == 0, (result.stdout, result.stderr))
    for name in ("stryker-scoped-config.sh", "mutation-survivor-reprobe.sh"):
        installed = home / ".codex/scripts" / name
        require(installed.is_file(), "Codex mutation helper missing: " + name)
        require(installed.read_bytes() == (ROOT / "scripts" / name).read_bytes(),
                "Codex mutation helper differs from canonical source: " + name)
        help_result = subprocess.run(["bash", str(installed), "--help"], env=env,
                                     text=True, capture_output=True, timeout=COMMAND_TIMEOUT)
        require(help_result.returncode == 0 and "Usage:" in help_result.stdout,
                (name, help_result.stdout, help_result.stderr))
    print("PASS: actual Codex script install delivers executable mutation helpers")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="zuvo-activation-") as temporary:
        for fixture_layout in ("scripts", "hooks"):
            check(fixture_layout, Path(temporary) / fixture_layout)
        check_mutation_helpers(Path(temporary))
    print("PASS: documented activation snippet integration")
