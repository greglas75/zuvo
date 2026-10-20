#!/usr/bin/env bash
# Regression inputs from the round-two hook review; no installed HOME is touched.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import ast
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(sys.argv[1])
INSTALLER = ROOT / "scripts/install-refactor-gate.sh"
DISPATCHER = ROOT / "hooks/refactor-gate-dispatch.sh"
# Load the shipped polyglot's functions without executing its CLI entry point.
source = INSTALLER.read_text().split("<<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
module = ast.parse(source)
module.body.pop()  # final CLI try/except
with patch.object(sys, "argv", [str(INSTALLER), str(INSTALLER)]):
    api = {}
    exec(compile(module, str(INSTALLER), "exec"), api)


class HookReview(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / "home"
        self.home.mkdir()
        self.cache = self.home / ".claude/plugins/cache/zuvo-marketplace/zuvo"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_")}
        self.env.update(HOME=str(self.home), GIT_CONFIG_GLOBAL="/dev/null",
                        GIT_CONFIG_SYSTEM="/dev/null", GIT_CONFIG_NOSYSTEM="1")
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.run_cmd("git", "init", "-q")

    def run_cmd(self, *args, input=None):
        return subprocess.run(args, cwd=self.repo, env=self.env, input=input,
                              text=True, capture_output=True, timeout=10, check=False)

    def gate(self, root, body="#!/bin/sh\nexit 23\n"):
        gate = root / "hooks/refactor-safety-gate.sh"
        gate.parent.mkdir(parents=True, exist_ok=True)
        gate.write_text(body)
        gate.chmod(0o755)
        return gate

    def test_no_arguments_returns_unavailable_instead_of_traceback(self):
        result = self.run_cmd("sh", str(INSTALLER))
        self.assertEqual(result.returncode, 2, result)
        self.assertIn("absolute gate path is required", result.stdout)
        self.assertNotIn("Traceback", result.stdout + result.stderr)

    def test_missing_template_returns_unavailable_instead_of_traceback(self):
        isolated = self.base / "isolated/install-refactor-gate.sh"
        isolated.parent.mkdir()
        isolated.write_bytes(INSTALLER.read_bytes())
        gate = self.gate(self.cache / "1.0.0")
        result = self.run_cmd("sh", str(isolated), str(gate), str(self.repo))
        self.assertEqual(result.returncode, 2, result)
        self.assertIn("runtime dispatcher missing", result.stdout)
        self.assertNotIn("Traceback", result.stdout + result.stderr)

    def test_stdin_installer_cannot_embed_repository_template(self):
        gate = self.gate(self.cache / "1.0.0")
        gate.with_name("refactor-gate-dispatch.sh").write_bytes(DISPATCHER.read_bytes())
        (self.repo / "refactor-gate-dispatch.sh").write_text("#!/bin/sh\nexit 97\n")
        result = self.run_cmd("sh", "-s", "--", str(gate), str(self.repo),
                              input=INSTALLER.read_text())
        self.assertEqual(result.returncode, 0, result)
        invoked = self.run_cmd(str(self.repo / ".git/hooks/pre-commit"))
        self.assertEqual(invoked.returncode, 23, invoked)

    def test_symlinked_home_still_embeds_resolver_after_cache_eviction(self):
        alias = self.base / "home-link"
        alias.symlink_to(self.home, target_is_directory=True)
        self.env["HOME"] = str(alias)
        gate = self.gate(self.cache / "1.0.0")
        result = self.run_cmd("sh", str(INSTALLER), str(gate), str(self.repo))
        self.assertEqual(result.returncode, 0, result)
        gate.parent.parent.rename(self.cache / "1.0.1")
        invoked = self.run_cmd(str(self.repo / ".git/hooks/pre-commit"))
        self.assertEqual(invoked.returncode, 23, invoked)

    def test_private_wrapper_digest_is_recognized_for_refresh(self):
        gate = self.gate(self.cache / "1.0.0")
        origin = self.base / "original-hooks"
        with patch.dict(os.environ, HOME=str(self.home)):
            body = api["chained_body"](gate, origin, "pre-commit")
            self.assertTrue(api["refreshable_hook"](body, "pre-commit", origin))

    def test_registry_cannot_select_gate_outside_zuvo_cache(self):
        foreign = self.base / "foreign"
        self.gate(foreign, "#!/bin/sh\nexit 97\n")
        self.gate(self.cache / "1.0.0")
        registry = self.home / ".claude/plugins/installed_plugins.json"
        registry.write_text(json.dumps({"plugins": {"zuvo@zuvo-marketplace": [
            {"installPath": str(foreign)}]}}))
        result = self.run_cmd("sh", str(DISPATCHER), "pre-commit")
        self.assertEqual(result.returncode, 23, result)

    def test_cache_gate_symlink_cannot_escape_its_install(self):
        foreign = self.gate(self.base / "foreign", "#!/bin/sh\nexit 97\n")
        gate = self.gate(self.cache / "2.0.0")
        gate.unlink()
        gate.symlink_to(foreign)
        self.gate(self.cache / "1.0.0")
        result = self.run_cmd("sh", str(DISPATCHER), "pre-commit")
        self.assertEqual(result.returncode, 23, result)

    def test_long_header_cannot_hide_recursive_dispatcher(self):
        body = DISPATCHER.read_text().replace(
            "# zuvo:refactor-runtime-dispatcher\n", "# zuvo:refactor-runtime-dispatcher \t\n", 1).replace(
            "# Stable entry for installed Git hooks. Resolve on every invocation, never at install time.\n",
            "# Stable entry for installed Git hooks. Resolve on every invocation, never at install time. \t\n", 1)
        self.gate(self.home / ".zuvo/current", "#!/bin/sh\n# " + "padding" * 100 + "\n" + body)
        self.gate(self.cache / "1.0.0")
        result = self.run_cmd("sh", str(DISPATCHER), "pre-commit")
        self.assertEqual(result.returncode, 23, result)
        self.assertIn("recursive dispatcher skipped", result.stderr)

    def test_real_gate_can_quote_dispatcher_marker_without_being_skipped(self):
        self.gate(self.cache / "1.0.0", '#!/bin/sh\n# Explains "# Stable entry for installed Git hooks."\nexit 23\n')
        result = self.run_cmd("sh", str(DISPATCHER), "pre-commit")
        self.assertEqual(result.returncode, 23, result)

    def test_harness_file_symlink_cannot_escape_its_install(self):
        foreign = self.gate(self.base / "foreign", "#!/bin/sh\nexit 97\n")
        gate = self.home / ".codex/scripts/refactor-safety-gate.sh"
        gate.parent.mkdir(parents=True)
        gate.symlink_to(foreign)
        self.gate(self.home / ".cursor", "#!/bin/sh\nexit 23\n").parent.rename(
            self.home / ".cursor/scripts")
        result = self.run_cmd("sh", str(DISPATCHER), "pre-commit")
        self.assertEqual(result.returncode, 23, result)
        self.assertIn("unavailable gate skipped", result.stderr)

    def test_gate_swapped_after_open_is_skipped_before_exec(self):
        gate = self.gate(self.cache / "2.0.0")
        self.gate(self.cache / "1.0.0")
        foreign = self.gate(self.base / "foreign", "#!/bin/sh\nexit 97\n")
        self.env.update(SWAPPED_GATE=str(gate), FOREIGN_GATE=str(foreign))
        self.python_fault('''import os
from pathlib import Path
original = Path.open
def swapped(path, *args, **kwargs):
    stream = original(path, *args, **kwargs)
    if str(path) == os.environ["SWAPPED_GATE"] and args == ("rb",):
        path.rename(path.with_suffix(".saved"))
        path.symlink_to(os.environ["FOREIGN_GATE"])
    return stream
Path.open = swapped
''')
        result = self.run_cmd("sh", str(DISPATCHER), "pre-commit")
        self.assertEqual(result.returncode, 23, result)
        self.assertIn("concurrent gate change", result.stderr)

    def python_fault(self, body):
        injected = self.base / "python-fault"
        injected.mkdir()
        (injected / "sitecustomize.py").write_text(body)
        self.env["PYTHONPATH"] = str(injected)

    def test_permission_error_inspecting_candidate_falls_back(self):
        self.gate(self.cache / "2.0.0")
        self.gate(self.cache / "1.0.0")
        self.python_fault('''from pathlib import Path
original = Path.is_file
def denied(path):
    if "/2.0.0/hooks/" in str(path):
        raise PermissionError("candidate denied by test")
    return original(path)
Path.is_file = denied
''')
        result = self.run_cmd("sh", str(DISPATCHER), "pre-commit")
        self.assertEqual(result.returncode, 23, result)
        self.assertIn("candidate denied by test", result.stderr)

    def test_unresolvable_home_warns_and_fails_open(self):
        self.python_fault('''from pathlib import Path
def missing_home(cls):
    raise RuntimeError("home unavailable in test")
Path.home = classmethod(missing_home)
''')
        result = self.run_cmd("sh", str(DISPATCHER), "pre-commit")
        self.assertEqual(result.returncode, 0, result)
        self.assertIn("fail-open", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def install_global(self):
        self.env["ZUVO_DIR"] = str(ROOT)
        return self.run_cmd("bash", "-c", '''
source "$ZUVO_DIR/scripts/install.d/hooks.sh"
warn(){ printf '%s\\n' "$*" >&2; }
fail(){ printf '%s\\n' "$*" >&2; }
install_hook_tree "$HOME/.claude/hooks"
''')

    def test_global_install_preserves_foreign_file_and_permissions(self):
        gate = self.gate(self.home / ".claude", "#!/bin/sh\n# user owned\nexit 97\n")
        gate.chmod(0o600)
        result = self.install_global()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(gate.read_text(), "#!/bin/sh\n# user owned\nexit 97\n")
        self.assertEqual(gate.stat().st_mode & 0o777, 0o600)
        self.assertIn("preserved", result.stdout + result.stderr)

    def test_global_install_preserves_foreign_symlink_and_target(self):
        foreign = self.gate(self.base / "foreign", "#!/bin/sh\nexit 97\n")
        gate = self.home / ".claude/hooks/refactor-safety-gate.sh"
        gate.parent.mkdir(parents=True)
        gate.symlink_to(foreign)
        result = self.install_global()
        self.assertEqual(result.returncode, 0, result)
        self.assertTrue(gate.is_symlink())
        self.assertEqual(foreign.read_text(), "#!/bin/sh\nexit 97\n")

    def test_global_install_refreshes_managed_real_gate(self):
        gate = self.gate(self.home / ".claude", (ROOT / "hooks/refactor-safety-gate.sh").read_text())
        result = self.install_global()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(gate.read_bytes(), DISPATCHER.read_bytes())
        self.assertTrue(os.access(gate, os.X_OK))

    def test_writable_receipt_cannot_authorize_foreign_hook_overwrite(self):
        gate = self.gate(self.home / ".claude", "#!/bin/sh\nexit 97\n")
        receipt = gate.with_name(".refactor-safety-gate.sha256")
        receipt.write_text(hashlib.sha256(gate.read_bytes()).hexdigest() + "\n")
        receipt.chmod(0o666)
        result = self.install_global()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(gate.read_text(), "#!/bin/sh\nexit 97\n")

    def test_foreign_receipt_is_rejected_before_managed_gate_changes(self):
        body = (ROOT / "hooks/refactor-safety-gate.sh").read_text()
        gate = self.gate(self.home / ".claude", body)
        receipt = gate.with_name(".refactor-safety-gate.sha256")
        receipt.symlink_to(self.base / "foreign-receipt")
        result = self.install_global()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(gate.read_text(), body)
        self.assertTrue(receipt.is_symlink())

    def test_receipt_swapped_after_trust_check_cannot_authorize_foreign_hook(self):
        gate = self.gate(self.home / ".claude", "#!/bin/sh\nexit 97\n")
        receipt = gate.with_name(".refactor-safety-gate.sha256")
        receipt.write_text(hashlib.sha256(gate.read_bytes()).hexdigest() + "\n")
        receipt.chmod(0o644)
        original_identity = api["file_identity"]
        swapped = False

        def replace_before_snapshot(path):
            nonlocal swapped
            if path == receipt and not swapped:
                receipt.chmod(0o666)
                swapped = True
            return original_identity(path)

        with patch.dict(api, file_identity=replace_before_snapshot):
            self.assertFalse(api["install_global_dispatch"](
                gate, ROOT / "hooks/refactor-safety-gate.sh"))
        self.assertTrue(swapped)
        self.assertEqual(gate.read_text(), "#!/bin/sh\nexit 97\n")

    def test_bulk_hook_copy_preserves_foreign_symlink_target_and_mode(self):
        foreign = self.gate(self.base / "foreign", "#!/bin/sh\nexit 97\n")
        foreign.chmod(0o600)
        hook = self.home / ".claude/hooks/zuvo-plugin-enable-guard.sh"
        hook.parent.mkdir(parents=True)
        hook.symlink_to(foreign)
        result = self.install_global()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(foreign.read_text(), "#!/bin/sh\nexit 97\n")
        self.assertEqual(foreign.stat().st_mode & 0o777, 0o600)
        self.assertTrue(hook.is_symlink())

    def test_refresh_preserves_symlink_swapped_during_identity_read(self):
        hook = self.repo / "pre-commit"
        hook.write_text("original hook\n")
        identity = api["file_identity"](hook)
        saved = self.repo / "saved-hook"
        original_hash = api["hashlib"].sha256
        swapped = False

        def swap_during_hash(data):
            nonlocal swapped
            if not swapped:
                hook.rename(saved)
                hook.symlink_to(saved)
                swapped = True
            return original_hash(data)

        # The pathname now names a foreign symlink, even though stat follows it
        # to the very same inode/bytes. Replacing it must be refused.
        with patch.object(api["hashlib"], "sha256", swap_during_hash):
            with self.assertRaises(RuntimeError):
                api["refresh_hook"](hook, "replacement hook\n", identity)
        self.assertTrue(hook.is_symlink())
        self.assertEqual(saved.read_text(), "original hook\n")


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
