"""release-autoinstall and key-sync (scripts/zuvo-home): the two jobs that replace hand installs and hand
key copies.

Test level: medium — real git repositories and files in a per-test temp dir, stub scripts for install.sh,
`claude` and `op`; no network, and key-sync's clock is fixed (unittest.mock), never the wall clock."""
import contextlib
import fcntl
import importlib.machinery
import importlib.util
import io
import json
import os
import random
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def load(name):
    p = os.path.join(ROOT, "scripts", "zuvo-home", name)
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), p)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


RA, KS = load("release-autoinstall"), load("key-sync")
NOW = 1_800_000_000.0                       # key-sync's fixed clock
WITHIN_A_DAY = NOW - KS.RETRY_AFTER_S + 3600
OVER_A_DAY = NOW - KS.RETRY_AFTER_S - 3600
REAL_LISTING = os.path.join(ROOT, "tests", "hooks", "fixtures", "claude-plugin-list.txt")

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


def keypair(d, name):
    """A real ed25519 key in `d`; returns the public key's path (the private half beside it)."""
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name, "-f", os.path.join(d, name)],
                   check=True)
    return os.path.join(d, name + ".pub")


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

    def test_newest_is_the_numeric_maximum_of_any_shuffled_tag_set(self):
        # invariant over generated inputs (seed 1017): the pick never depends on order or on text sorting
        rng = random.Random(1017)
        for _ in range(200):
            versions = {tuple(rng.randrange(0, 30) for _ in range(3)) for _ in range(rng.randrange(1, 12))}
            tags = [f"v{a}.{b}.{c}" for a, b, c in versions] + ["build-x", "v1.2"]
            rng.shuffle(tags)
            want = max(versions)
            self.assertEqual(RA.newest(tags), f"v{want[0]}.{want[1]}.{want[2]}", tags)

    def test_plugin_state_reads_a_real_claude_plugin_list(self):
        # contract: real Claude Code output, three project-scope pins beside the user one
        with open(REAL_LISTING, encoding="utf-8") as f:
            self.assertEqual(RA.plugin_state(f.read()), ("1.6.87", True))

    def test_newest_of_no_release_is_none(self):
        self.assertIsNone(RA.newest(["build-1", ""]))

    def test_only_an_ssh_signed_tag_naming_itself_is_accepted(self):
        # catches a PGP-signed tag verified against GnuPG's keyring, and an old tag replayed under a new ref
        ssh = "-----BEGIN SSH SIGNATURE-----\nx\n-----END SSH SIGNATURE-----\n"
        pgp = "-----BEGIN PGP SIGNATURE-----\nx\n-----END PGP SIGNATURE-----\n"
        head = "object abc\ntype commit\ntag v1.0.0\ntagger t\n\nmsg\n"
        cases = {"ssh, own name": (head + ssh, "v1.0.0", True),
                 "pgp": (head + pgp, "v1.0.0", False),
                 "ssh and pgp": (head + ssh + pgp, "v1.0.0", False),
                 "other name": (head + ssh, "v9.9.9", False),
                 "unsigned": (head, "v1.0.0", False)}
        for name, (body, tag, want) in cases.items():
            with self.subTest(name):
                self.assertEqual(RA.ssh_signed_as(body, tag), want)

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

    def test_plugin_state_of_a_user_entry_without_a_version_has_none(self):
        # catches a missing Version line read as some version, so a broken install looks current
        listing = "  ❯ zuvo@zuvo-marketplace\n    Scope: user\n    Status: ✔ enabled\n"
        self.assertEqual(RA.plugin_state(listing), (None, True))

    def test_a_missing_command_reads_as_127_not_a_crash(self):
        self.assertEqual(RA.run([os.path.join(ROOT, "no-such-binary")], timeout=5).returncode, 127)

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
        self.key = keypair(self.tmp, "release")
        with open(self.key) as f, open(os.path.join(self.home, "release-signers"), "w") as out:
            out.write(f'release namespaces="git" {f.read()}')
        self.tag("v1.0.0")
        self.plugin = os.path.join(self.tmp, "plugin")   # what the stub `claude` reports
        with open(self.plugin, "w") as f:
            f.write("0.0.0 ✔ enabled")
        self.claude = os.path.join(self.tmp, "claude")
        self.set_claude(update_rc=0)
        os.environ.update(ZUVO_RELEASE_REPO=self.origin, ZUVO_CLAUDE_BIN=self.claude)

    def set_claude(self, update_rc, marketplace_rc=0):
        self.claude_calls = os.path.join(self.tmp, "claude-calls")
        sh(self.claude, f'''echo "$1 $2" >> "{self.claude_calls}"; p="{self.plugin}"; read v s e < "$p"
case "$1 $2" in
  "plugin list") printf '  ❯ zuvo@zuvo-marketplace\\n    Version: %s\\n' "$v"
                 printf '    Scope: user\\n    Status: %s %s\\n' "$s" "$e" ;;
  "plugin marketplace") exit {marketplace_rc} ;;
  "plugin update") [ {update_rc} -eq 0 ] || exit {update_rc}
                   t=$(git -C "{self.home}/release-src" describe --tags); echo "${{t#v}} ✔ enabled" > "$p" ;;
  "plugin enable") echo "$v ✔ enabled" > "$p" ;;
esac
''')

    def tag(self, name, key=None):
        git(self.origin, "-c", "gpg.format=ssh", "-c", f"user.signingkey={key or self.key}",
            "tag", "-s", "-m", name, name)

    def calls(self):
        try:
            with open(self.claude_calls) as f:
                return f.read().splitlines()
        except FileNotFoundError:
            return []

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
        open(self.claude_calls, "w").close()
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, ["v1.0.0"]), "an installed release is installed once")
        self.assertEqual(self.calls(), ["plugin list"], "a plugin already on the release is not updated")

    def test_a_tag_off_main_is_skipped_and_the_newest_main_release_installed(self):
        # catches installing a tag pushed on a review branch, and such a tag blocking every release below it
        git(self.origin, "checkout", "-qb", "side")
        git(self.origin, "commit", "-q", "--allow-empty", "-m", "side")
        self.tag("v9.0.0")
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, ["v1.0.0"]), out)
        self.assertIn("skipped v9.0.0: not on origin/main", out)

    def test_an_unsigned_tag_is_skipped_and_the_newest_signed_one_installed(self):
        # catches installing a tag nobody with a release key made (anyone with push access can tag)
        git(self.origin, "commit", "-q", "--allow-empty", "-m", "two")
        git(self.origin, "tag", "v1.0.1")
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, ["v1.0.0"]), out)
        self.assertIn("skipped v1.0.1: no valid signature", out)

    def test_a_tag_signed_by_a_key_not_in_release_signers_is_skipped(self):
        git(self.origin, "commit", "-q", "--allow-empty", "-m", "two")
        self.tag("v1.0.1", key=keypair(self.tmp, "stranger"))
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, ["v1.0.0"]), out)
        self.assertIn("skipped v1.0.1: no valid signature", out)

    def test_an_old_signed_tag_under_a_newer_name_is_skipped(self):
        # catches replay: the signature covers the name inside the tag, not the ref it is pushed under
        tag_object = subprocess.run(["git", "-C", self.origin, "rev-parse", "refs/tags/v1.0.0"],
                                    capture_output=True, text=True, check=True).stdout.strip()
        git(self.origin, "update-ref", "refs/tags/v9.9.9", tag_object)
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, ["v1.0.0"]), out)
        self.assertIn("skipped v9.9.9: no valid signature", out)

    def test_a_trust_list_others_can_write_is_refused(self):
        # catches trusting keys another local user could have added
        os.chmod(os.path.join(self.home, "release-signers"), 0o666)
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (1, []), out)
        self.assertIn("writable by no one else", out)

    def test_without_release_signers_nothing_is_installed(self):
        # catches a machine with no trust list treating every tag as trusted
        os.remove(os.path.join(self.home, "release-signers"))
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (1, []), out)
        self.assertIn("nothing trusted", out)

    def test_a_failed_install_is_not_recorded_and_is_retried(self):
        # catches state written before the install.sh exit code is checked: a failed install skipped forever
        script = os.path.join(self.origin, "scripts", "install.sh")
        sh(script, f'echo x >> "{self.marker}"; exit 7\n')
        git(self.origin, "commit", "-qam", "broken")
        self.tag("v1.0.1")
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
        self.assertIn("no signed release tag", out)

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

    def test_a_plugin_that_stays_disabled_is_reported(self):
        self.quiet(RA.locked_pass)
        with open(self.plugin, "w") as f:
            f.write("1.0.0 ✘ disabled")
        sh(self.claude, f'''p="{self.plugin}"; read v s e < "$p"
[ "$1 $2" = "plugin list" ] && printf '  ❯ zuvo@zuvo-marketplace\\n    Version: %s\\n' "$v" &&
  printf '    Scope: user\\n    Status: %s %s\\n' "$s" "$e"
exit 0
''')
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual(rc, 1, out)
        self.assertIn("plugin is 1.0.0, disabled — want 1.0.0, enabled", out)

    def test_a_half_made_clone_is_started_again(self):
        # catches a killed first clone (a directory without .git) failing every pass forever
        os.makedirs(os.path.join(self.home, "release-src", "partial"))
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, ["v1.0.0"]), out)

    def test_a_refused_marketplace_update_stops_before_the_plugin_update(self):
        self.set_claude(update_rc=0, marketplace_rc=5)
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual(rc, 1, out)
        self.assertIn("`plugin marketplace update zuvo-marketplace` rc=5", out)
        self.assertNotIn("plugin update", self.calls())

    def test_a_fetch_failure_after_the_clone_installs_nothing_new(self):
        self.quiet(RA.locked_pass)
        os.rename(self.origin, self.origin + ".gone")
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (1, ["v1.0.0"]), out)
        self.assertIn("fetch failed", out)

    def test_a_state_file_that_is_not_ours_reads_as_nothing_installed(self):
        # catches a crash on a hand-edited or truncated state file instead of a reinstall
        cases = {"not json": "{", "a list": "[1]", "installed not text": '{"installed": 7}'}
        for name, text in cases.items():
            with self.subTest(name):
                with open(os.path.join(self.home, "release-autoinstall.state"), "w") as f:
                    f.write(text)
                self.assertEqual(RA.read_state(), {})

    def test_enable_schedules_this_installed_file_every_30_minutes(self):
        # catches the schedule pointing at a worktree or a relative path, or a wrong interval
        unit = mock.Mock(install_unit=mock.Mock(return_value=0), uninstall_unit=mock.Mock(return_value=0))
        with mock.patch.object(RA, "schedule_module", return_value=unit):
            self.assertEqual((RA.main(["--enable"]), RA.main(["--disable"])), (0, 0))
        args, kw = unit.install_unit.call_args
        self.assertEqual((args[0], args[1], kw["interval_s"], kw["log"]),
                         ("release-autoinstall", [os.path.realpath(RA.__file__)], 1800,
                          os.path.join(self.home, "release-autoinstall.log")))
        unit.uninstall_unit.assert_called_once_with("release-autoinstall")

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
        self.assertEqual(RA.read_state()["installed"], "v2.0.0")

    def test_tags_at_or_below_the_installed_release_are_not_examined(self):
        # catches every pass re-verifying and logging all old unsigned tags
        # the state right after signing began: every tag unsigned, the installed one among them
        git(self.origin, "tag", "-d", "v1.0.0")
        git(self.origin, "tag", "v1.0.0")
        git(self.origin, "tag", "v0.9.0")
        RA.write_state({"installed": "v1.0.0"})
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((self.installs(), "skipped v" in out), ([], False), out)

    def test_a_trust_list_in_a_directory_others_can_write_is_refused(self):
        # catches a safe file inside a directory where someone else can swap it
        os.chmod(self.home, 0o777)
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (1, []), out)
        self.assertIn("must be owned by you and writable by no one else", out)

    def test_a_pass_while_another_holds_the_lock_installs_nothing(self):
        with open(os.path.join(self.home, "release-autoinstall.lock"), "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, []), out)
        self.assertIn("another pass is running", out)

    def test_an_installed_key_sync_runs_first_and_its_lines_are_logged(self):
        with open(os.path.join(self.home, "key-sync"), "w") as f:   # run by the job's own Python
            f.write("print('zai.key: written from 1Password (mode 600)')\n")
        rc, out = self.quiet(RA.locked_pass)
        synced = out.find("key-sync: zai.key: written from 1Password")
        installing = out.find("installing v1.0.0")
        self.assertEqual((rc, synced >= 0, synced < installing), (0, True, True), out)

    def test_an_unsaved_state_still_reports_the_install_and_redoes_it_next_pass(self):
        # catches a state-write OSError aborting the pass as a traceback after a good install
        os.makedirs(os.path.join(self.home, "release-autoinstall.state"))
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, ["v1.0.0"]), out)
        self.assertIn("WARN state not saved", out)

    def test_a_lock_that_cannot_be_opened_is_a_failure_not_a_crash(self):
        os.makedirs(os.path.join(self.home, "release-autoinstall.lock"))
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (1, []), out)
        self.assertIn("lock not opened", out)

    def test_status_reports_the_recorded_install(self):
        self.quiet(RA.locked_pass)
        rc, out = self.quiet(RA.main, ["--status"])
        self.assertEqual(rc, 0)
        self.assertIn("installed: v1.0.0", out)
        self.assertIn("newest tag in the clone: v1.0.0", out)

    def test_status_before_any_pass_says_nothing_is_installed(self):
        rc, out = self.quiet(RA.main, ["--status"])
        self.assertEqual(rc, 0)
        self.assertIn("installed: unknown", out)
        self.assertNotIn("newest tag", out)

    def test_an_unknown_argument_is_a_usage_error_that_installs_nothing(self):
        with contextlib.redirect_stderr(io.StringIO()):
            rc, _ = self.quiet(RA.main, ["--now"])
        self.assertEqual((rc, self.installs()), (2, []))

    def test_pause_file_stops_a_pass(self):
        open(os.path.join(self.home, "release-autoinstall.pause"), "w").close()
        rc, out = self.quiet(RA.locked_pass)
        self.assertEqual((rc, self.installs()), (0, []), out)


class ReleaseTag(Env):
    def setUp(self):
        super().setUp()
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "commit", "-q", "--allow-empty", "-m", "one")
        self.key = keypair(self.tmp, "release")

    def make(self, *args, key=None):
        env = {**os.environ, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_COMMITTER_NAME": "t",
               "GIT_COMMITTER_EMAIL": "t@t", "ZUVO_RELEASE_SIGNING_KEY": key or self.key}
        return subprocess.run(["bash", os.path.join(ROOT, "scripts", "release-tag.sh"), *args],
                              cwd=self.repo, env=env, capture_output=True, text=True)

    def verify(self, tag):
        signers = os.path.join(self.tmp, "signers")
        with open(self.key) as f, open(signers, "w") as out:
            out.write(f'release namespaces="git" {f.read()}')
        return subprocess.run(["git", "-C", self.repo, "-c", f"gpg.ssh.allowedSignersFile={signers}",
                               "verify-tag", tag], capture_output=True).returncode

    def test_with_a_key_the_release_tag_is_signed_and_verifies(self):
        r = self.make("v1.0.0", "HEAD")
        self.assertEqual((r.returncode, self.verify("v1.0.0")), (0, 0), r.stderr)

    def test_without_a_key_the_tag_is_unsigned_and_says_it_will_not_install(self):
        # catches a release that silently ships a tag no machine will install
        r = self.make("v1.0.0", "HEAD", key=os.path.join(self.tmp, "absent.pub"))
        self.assertEqual((r.returncode, self.verify("v1.0.0")), (3, 1))
        self.assertIn("will not install v1.0.0", r.stderr)

    def test_a_configured_key_that_cannot_sign_creates_no_tag(self):
        # catches a signing failure degrading to an unsigned tag that looks like a release
        lone_pub = os.path.join(self.tmp, "lone.pub")   # public half only: ssh-keygen cannot sign
        with open(self.key) as f, open(lone_pub, "w") as out:
            out.write(f.read())
        r = self.make("v1.0.0", "HEAD", key=lone_pub)
        tags = subprocess.run(["git", "-C", self.repo, "tag"], capture_output=True, text=True).stdout
        self.assertEqual((r.returncode, tags), (1, ""), r.stderr)
        self.assertIn("no tag created", r.stderr)

    def test_an_existing_tag_is_left_alone(self):
        # catches the failure path deleting a tag this run did not create
        git(self.repo, "tag", "v1.0.0")
        r = self.make("v1.0.0", "HEAD", key=os.path.join(self.tmp, "absent.pub"))
        tags = subprocess.run(["git", "-C", self.repo, "tag"], capture_output=True, text=True).stdout
        self.assertEqual((r.returncode, tags), (1, "v1.0.0\n"), r.stderr)

    def test_a_missing_argument_is_a_usage_error_that_tags_nothing(self):
        r = self.make("v1.0.0")
        r2 = self.make("1.0.0", "HEAD")
        self.assertEqual(r2.returncode, 2)
        tags = subprocess.run(["git", "-C", self.repo, "tag"], capture_output=True, text=True).stdout
        self.assertEqual((r.returncode, tags), (2, ""))


class Timeout(unittest.TestCase):
    def test_a_timeout_kills_what_the_command_started(self):
        # catches install.sh's children surviving the timeout and running on after the lock is released
        with tempfile.TemporaryDirectory() as d:
            pidfile = os.path.join(d, "pid")
            r = RA.run(["sh", "-c", f'sh -c \'echo $$ > "{pidfile}"; exec sleep 60\' & wait'], timeout=2)
            with open(pidfile) as f:
                child = int(f.read())
        self.assertEqual(r.returncode, 124)
        # gone, or a zombie nobody reaps yet (pid 1 in a container) — never still running
        ps = subprocess.run(["ps", "-o", "stat=", "-p", str(child)], capture_output=True, text=True)
        self.assertIn(ps.returncode, (0, 1), ps.stderr)   # 1: no such process; other: ps failed
        self.assertIn(ps.stdout.strip()[:1], ("", "Z"))


class KeySync(Env):
    def setUp(self):
        super().setUp()
        self.calls = os.path.join(self.tmp, "op-calls")
        self.op = os.path.join(self.tmp, "op")
        self.set_op('printf "abc.def"')
        os.environ["ZUVO_OP_BIN"] = self.op
        self.conf("zai.key\top://Hetzner/Api z.ai/password\n")
        clock = mock.patch.object(KS.time, "time", return_value=NOW)
        clock.start()
        self.addCleanup(clock.stop)

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

    def test_a_failure_within_a_day_is_not_retried(self):
        with open(os.path.join(self.home, "key-sync.failures"), "w") as f:
            json.dump({"zai.key": WITHIN_A_DAY}, f)
        rc, out = self.quiet(KS.main, [])
        self.assertEqual((rc, self.op_calls()), (1, []), out)

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
            json.dump({"zai.key": OVER_A_DAY}, f)
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
        os.utime(left, (NOW - 2 * KS.STALE_TMP_S, NOW - 2 * KS.STALE_TMP_S))
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

    def test_a_fresh_temp_file_of_a_concurrent_run_is_kept(self):
        # catches cleanup deleting a temp another run is about to link
        fresh = os.path.join(self.home, ".zai.key.x2.keysync-tmp")
        open(fresh, "w").close()
        os.utime(fresh, (NOW, NOW))
        self.quiet(KS.main, [])
        self.assertTrue(os.path.exists(fresh))

    def test_an_unknown_argument_is_a_usage_error(self):
        with contextlib.redirect_stderr(io.StringIO()):
            rc, _ = self.quiet(KS.main, ["--force"])
        self.assertEqual((rc, self.op_calls()), (2, []))

    def test_check_lists_missing_files_without_calling_op(self):
        rc, out = self.quiet(KS.main, ["--check"])
        self.assertEqual((rc, self.op_calls()), (1, []))
        self.assertIn("zai.key: missing", out)


if __name__ == "__main__":
    unittest.main()
