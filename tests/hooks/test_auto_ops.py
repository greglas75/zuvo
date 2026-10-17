"""release-autoinstall and key-sync (scripts/zuvo-home): the two jobs that replace hand installs and hand
key copies. Real git repositories in a temp dir; install.sh, `claude` and `op` are stub scripts."""
import contextlib
import fcntl
import importlib.machinery
import importlib.util
import io
import json
import os
import stat
import subprocess
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load(name):
    p = os.path.join(ROOT, "scripts", "zuvo-home", name)
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), p)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


RA, KS = load("release-autoinstall"), load("key-sync")

LISTING = """Installed plugins:

  ❯ zuvo@zuvo-marketplace
    Version: 1.6.83
    Scope: project
    Status: ✔ enabled

  ❯ zuvo@zuvo-marketplace
    Version: {v}
    Scope: user
    Status: {s}
"""


def sh(path, body):
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(path, 0o755)


def git(cwd, *args):
    subprocess.run(["git", "-C", cwd, *args], check=True, capture_output=True,
                   env={**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "t",
                        "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"})


class Env(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.home = os.path.join(self.tmp, "zuvo")
        os.makedirs(self.home)
        self.env = {k: os.environ.get(k) for k in ("ZUVO_HOME", "ZUVO_RELEASE_REPO", "ZUVO_CLAUDE_BIN",
                                                    "ZUVO_OP_BIN", "GIT_CONFIG_GLOBAL")}
        os.environ.update(ZUVO_HOME=self.home, GIT_CONFIG_GLOBAL="/dev/null")

    def tearDown(self):
        for k, v in self.env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        subprocess.run(["rm", "-rf", self.tmp], check=False)

    def quiet(self, fn, *a):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = fn(*a)
        return rc, out.getvalue()


class TagAndListing(unittest.TestCase):
    def test_newest_compares_numerically_not_as_text(self):
        # catches a string sort, under which v1.6.9 beats v1.6.10
        self.assertEqual(RA.newest(["v1.6.9", "v1.6.10", "v1.5.99"]), "v1.6.10")

    def test_newest_ignores_tags_that_are_not_releases(self):
        cases = {"build tag": ["build-2026-10-17-x", "v1.2.3"], "two-part": ["v2.0", "v1.2.3"],
                 "suffix": ["v9.9.9-rc1", "v1.2.3"]}
        for name, tags in cases.items():
            with self.subTest(name):
                self.assertEqual(RA.newest(tags), "v1.2.3")

    def test_newest_of_no_release_is_none(self):
        self.assertIsNone(RA.newest(["build-1", ""]))

    def test_plugin_state_reads_the_user_scope_not_a_project_pin(self):
        self.assertEqual(RA.plugin_state(LISTING.format(v="1.6.86", s="✔ enabled")), ("1.6.86", True))

    def test_redact_masks_credentials_in_a_url(self):
        # catches a token in ZUVO_RELEASE_REPO reaching the world-readable log
        cases = {"user:token": ("fatal: https://me:ghp_x@github.com/a/b", "fatal: https://***@github.com/a/b"),
                 "token only": ("https://ghp_x@host/r", "https://***@host/r"),
                 "no credentials": ("https://github.com/a/b", "https://github.com/a/b")}
        for name, (raw, want) in cases.items():
            with self.subTest(name):
                self.assertEqual(RA.redact(raw), want)

    def test_plugin_state_without_a_user_install_is_absent(self):
        self.assertEqual(RA.plugin_state(LISTING.split("  ❯")[0]), (None, False))

    def test_plugin_state_sees_a_disabled_user_install(self):
        self.assertEqual(RA.plugin_state(LISTING.format(v="1.6.86", s="✘ disabled")), ("1.6.86", False))


class Release(Env):
    def setUp(self):
        super().setUp()
        self.origin = os.path.join(self.tmp, "origin")
        os.makedirs(os.path.join(self.origin, "scripts"))
        git(self.origin, "init", "-q", "-b", "main")
        self.marker = os.path.join(self.tmp, "installs")
        sh(os.path.join(self.origin, "scripts", "install.sh"),
           f'git -C "$(dirname "$0")/.." describe --tags >> "{self.marker}"\n')
        git(self.origin, "add", ".")
        git(self.origin, "commit", "-qm", "one")
        git(self.origin, "tag", "v1.0.0")
        self.plugin = os.path.join(self.tmp, "plugin")   # what the stub `claude` reports
        with open(self.plugin, "w") as f:
            f.write("0.0.0 ✔ enabled")
        self.claude = os.path.join(self.tmp, "claude")
        self.set_claude(update_rc=0)
        os.environ.update(ZUVO_RELEASE_REPO=self.origin, ZUVO_CLAUDE_BIN=self.claude)

    def set_claude(self, update_rc):
        sh(self.claude, f'''p="{self.plugin}"; read v s e < "$p"
case "$1 $2" in
  "plugin list") printf '  ❯ zuvo@zuvo-marketplace\\n    Version: %s\\n' "$v"
                 printf '    Scope: user\\n    Status: %s %s\\n' "$s" "$e" ;;
  "plugin update") [ {update_rc} -eq 0 ] || exit {update_rc}
                   t=$(git -C "{self.home}/release-src" describe --tags); echo "${{t#v}} ✔ enabled" > "$p" ;;
  "plugin enable") echo "$v ✔ enabled" > "$p" ;;
esac
''')

    def installs(self):
        try:
            with open(self.marker) as f:
                return f.read().split()
        except FileNotFoundError:
            return []

    def test_a_new_release_is_installed_once_and_the_plugin_brought_to_it(self):
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, ["v1.0.0"]), out)
        self.assertEqual(RA.read_state()["installed"], "v1.0.0")
        with open(self.plugin) as f:
            self.assertEqual(f.read().split()[0], "1.0.0")
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, ["v1.0.0"]), "an installed release is installed once")

    def test_a_tag_off_main_is_skipped_and_the_newest_main_release_installed(self):
        # catches installing a tag pushed on a review branch, and such a tag blocking every release below it
        git(self.origin, "checkout", "-qb", "side")
        git(self.origin, "commit", "-q", "--allow-empty", "-m", "side")
        git(self.origin, "tag", "v9.0.0")
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, ["v1.0.0"]), out)
        self.assertIn("skipped v9.0.0: not on origin/main", out)

    def test_a_failed_install_is_not_recorded_and_is_retried(self):
        # catches state written before the install.sh exit code is checked: a failed install skipped forever
        script = os.path.join(self.origin, "scripts", "install.sh")
        sh(script, f'echo x >> "{self.marker}"; exit 7\n')
        git(self.origin, "commit", "-qam", "broken")
        git(self.origin, "tag", "v1.0.1")
        rc1, out = self.quiet(RA.locked_pass)
        rc2, _ = self.quiet(RA.locked_pass)
        got = (rc1, rc2, len(self.installs()), RA.read_state().get("installed"))
        self.assertEqual(got, (1, 1, 2, None), out)
        self.assertIn("install.sh rc=7", out)

    def test_an_unreachable_origin_installs_nothing(self):
        os.environ["ZUVO_RELEASE_REPO"] = os.path.join(self.tmp, "no-such-repo")
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (1, []), out)
        self.assertIn("clone failed", out)

    def test_an_origin_without_a_release_tag_installs_nothing(self):
        git(self.origin, "tag", "-d", "v1.0.0")
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (1, []), out)
        self.assertIn("no release tag", out)

    def test_a_plugin_that_stays_on_an_older_version_is_reported(self):
        # catches "update exited 0" taken as success while the marketplace still serves the old version
        sh(self.claude, '''case "$1 $2" in
  "plugin list") printf '  ❯ zuvo@zuvo-marketplace\\n    Version: 0.9.0\\n'
                 printf '    Scope: user\\n    Status: ✔ enabled\\n' ;;
esac''')
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual(rc, 1, out)
        self.assertIn("plugin is 0.9.0, enabled — want 1.0.0", out)

    def test_a_refused_plugin_update_is_retried_without_a_second_install(self):
        self.set_claude(update_rc=3)
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual(rc, 1, out)
        self.assertIn("retried next pass", out)
        self.set_claude(update_rc=0)
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, ["v1.0.0"]), out)

    def test_an_installed_but_disabled_plugin_is_enabled(self):
        self.quiet(RA.locked_pass)
        with open(self.plugin, "w") as f:
            f.write("1.0.0 ✘ disabled")
        rc, out = self.quiet(RA.locked_pass)
        with open(self.plugin) as f:
            self.assertEqual((rc, f.read().split()), (0, ["1.0.0", "✔", "enabled"]), out)

    def test_an_older_newest_tag_is_never_installed_over_a_newer_one(self):
        # catches `!=` instead of `>`: a release tag deleted on origin would roll every machine back
        RA.write_state({"installed": "v2.0.0"})
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual(self.installs(), [], out)
        self.assertIn("not downgraded", out)
        self.assertEqual(RA.read_state()["installed"], "v2.0.0")

    def test_a_pass_while_another_holds_the_lock_installs_nothing(self):
        with open(os.path.join(self.home, "release-autoinstall.lock"), "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, []), out)
        self.assertIn("another pass is running", out)

    def test_pause_file_stops_a_pass(self):
        open(os.path.join(self.home, "release-autoinstall.pause"), "w").close()
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, []), out)


class KeySync(Env):
    def setUp(self):
        super().setUp()
        self.calls = os.path.join(self.tmp, "op-calls")
        self.op = os.path.join(self.tmp, "op")
        self.set_op('printf "abc.def"')
        os.environ["ZUVO_OP_BIN"] = self.op
        self.conf("zai.key\top://Hetzner/Api z.ai/password\n")

    def set_op(self, body):
        sh(self.op, f'echo "$@" >> "{self.calls}"\n{body}\n')

    def conf(self, text):
        with open(os.path.join(self.home, "key-sync.conf"), "w") as f:
            f.write(text)

    def op_calls(self):
        try:
            with open(self.calls) as f:
                return f.read().splitlines()
        except FileNotFoundError:
            return []

    def key(self):
        return os.path.join(self.home, "zai.key")

    def test_a_missing_key_is_written_mode_600_and_never_printed(self):
        rc, out = self.quiet(KS.main, [])
        self.assertEqual(rc, 0, out)
        with open(self.key()) as f:
            self.assertEqual(f.read(), "abc.def")
        self.assertEqual(stat.S_IMODE(os.stat(self.key()).st_mode), 0o600)
        self.assertNotIn("abc.def", out)
        self.assertEqual(self.op_calls(), ["read --no-newline op://Hetzner/Api z.ai/password"])

    def test_an_existing_key_is_not_overwritten_nor_fetched(self):
        with open(self.key(), "w") as f:
            f.write("mine")
        rc, out = self.quiet(KS.main, [])
        with open(self.key()) as f:
            self.assertEqual((rc, f.read(), self.op_calls()), (0, "mine", []))

    def test_a_dangling_symlink_is_reported_not_taken_for_a_written_key(self):
        # catches a dangling link read as missing, then the failed link() read as another pass's write
        os.symlink(os.path.join(self.tmp, "nowhere"), self.key())
        rc, out = self.quiet(KS.main, [])
        self.assertEqual((rc, self.op_calls()), (1, []), out)
        self.assertIn("not a regular file", out)

    def test_a_failed_op_is_not_retried_within_a_day(self):
        # catches a desktop 1Password prompting on every pass
        self.set_op("echo 'not signed in' >&2; exit 1")
        rc1, _ = self.quiet(KS.main, [])
        rc2, out = self.quiet(KS.main, [])
        self.assertEqual((rc1, rc2, len(self.op_calls())), (1, 1, 1), out)
        self.assertIn("next try after 24 h", out)
        self.assertFalse(os.path.exists(self.key()))

    def test_a_failure_older_than_a_day_is_retried(self):
        with open(os.path.join(self.home, "key-sync.failures"), "w") as f:
            json.dump({"zai.key": time.time() - 90000}, f)
        rc, out = self.quiet(KS.main, [])
        self.assertEqual((rc, len(self.op_calls())), (0, 1), out)

    def test_values_that_are_not_one_line_are_refused(self):
        for name, body in {"empty": "printf ''", "two lines": "printf 'a\\nb'"}.items():
            with self.subTest(name):
                with contextlib.suppress(FileNotFoundError):
                    os.remove(os.path.join(self.home, "key-sync.failures"))
                self.set_op(body)
                rc, out = self.quiet(KS.main, [])
                self.assertEqual((rc, os.path.exists(self.key())), (1, False), out)

    def test_malformed_conf_lines_are_reported_and_skipped(self):
        cases = {"no tab": "zai.key op://a/b/c", "path in name": "../evil.key\top://a/b/c",
                 "not op": "zai.key\thttps://x/y/z"}
        for name, line in cases.items():
            with self.subTest(name):
                self.conf(line + "\n")
                rc, out = self.quiet(KS.main, [])
                self.assertEqual((rc, self.op_calls()), (1, []), out)
                self.assertIn("skipped", out)

    def test_a_temp_file_left_by_a_killed_run_is_removed(self):
        # catches a secret-bearing temp file outliving the run that wrote it
        left = os.path.join(self.home, ".zai.key.x1.keysync-tmp")
        with open(left, "w") as f:
            f.write("old-secret")
        os.utime(left, (time.time() - 7200, time.time() - 7200))
        self.quiet(KS.main, [])
        self.assertEqual([n for n in os.listdir(self.home) if n.endswith(".keysync-tmp")], [])

    def test_op_not_installed_is_a_failure_not_a_crash(self):
        # catches an OSError traceback on a fresh machine without the 1Password CLI
        os.environ["ZUVO_OP_BIN"] = os.path.join(self.tmp, "no-op")
        rc, out = self.quiet(KS.main, [])
        self.assertEqual((rc, os.path.exists(self.key())), (1, False), out)
        self.assertIn("op not runnable", out)

    def test_no_conf_is_nothing_to_sync(self):
        os.remove(os.path.join(self.home, "key-sync.conf"))
        rc, out = self.quiet(KS.main, [])
        self.assertEqual((rc, self.op_calls()), (0, []), out)

    def test_a_key_written_while_fetching_is_kept(self):
        # catches the fetched value overwriting a key another pass or a person wrote meanwhile
        self.set_op(f'printf theirs > "{self.key()}"; printf "abc.def"')
        rc, out = self.quiet(KS.main, [])
        with open(self.key()) as f:
            self.assertEqual(f.read(), "theirs", out)
        self.assertIn("appeared while fetching", out)

    def test_check_lists_missing_files_without_calling_op(self):
        rc, out = self.quiet(KS.main, ["--check"])
        self.assertEqual((rc, self.op_calls()), (1, []))
        self.assertIn("zai.key: missing", out)


if __name__ == "__main__":
    unittest.main()
