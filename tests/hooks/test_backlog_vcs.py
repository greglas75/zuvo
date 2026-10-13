"""scripts/zuvo-home/zuvo_backlog_vcs.py — what `backlog-add` asks git (and gh) before it writes: does the
cited site still hold in the work tree, which branch is the default one, which `[pr:N]` / `[branch:name]`
tag the entry carries, and which lines the branch changed. Every row names the defect it would catch.

Real `git init` repos in a temp dir (the farm mirror has no .git), a stub `gh` on a narrowed PATH built
with tests/lib/hermetic-tools.sh, and HOME pointed at a temp dir so the real ~/.zuvo/cache is untouched.
"""
from __future__ import annotations

import contextlib
import errno
import io
import os
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from collections.abc import Callable
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "zuvo-home"))
import zuvo_backlog_vcs as vcs  # noqa: E402

GIT = shutil.which("git") or "git"
SLEEP = shutil.which("sleep") or "/bin/sleep"
HERMETIC = os.path.join(ROOT, "tests", "lib", "hermetic-tools.sh")
GITHUB = "https://github.com/acme/app.git"
GITHUB_SSH = "git@github.com:acme/app.git"
TOKENED = "https://ghp_secret123@github.com/acme/app.git"
BITBUCKET = "git@bitbucket.org:acme/app.git"
ANCHOR = "if total > limit:"
# 20 lines; line 10 holds the anchor with doubled inner spaces (the check is whitespace-insensitive)
A_PY = "".join(f"x{n} = {n}\n" if n != 10 else "    if total  >  limit:\n" for n in range(1, 21))
SIX = "a\nb\nc\nd\ne\nf\n"
CACHE_REL = (".zuvo", "cache", "backlog-add-pr.tsv")
SHA256_ACME_APP = "5f89da0438fa1b1767532b58bd38cda2396f39889ab9e492e7f8f20d22fc9e9f"  # sha256("acme/app")


class _EIO(io.RawIOBase):
    """A readable stream whose every read fails as a disk or NFS read error does."""

    def readable(self) -> bool:
        return True

    def readinto(self, b: object) -> int:
        raise OSError(errno.EIO, "Input/output error")


def eio_open(fd: int, *_args: object, **_kw: object) -> io.TextIOWrapper:
    """Stands in for the module's `open(fd, ...)`: the real fd is closed, reads raise EIO."""
    os.close(fd)
    return io.TextIOWrapper(io.BufferedReader(_EIO()), encoding="utf-8")


REAL_FSTAT = os.fstat


def foreign_fstat(fd: int) -> SimpleNamespace:
    """The fd's real stat, reported as owned by another user: a chown needs root, so this is the fault."""
    st = REAL_FSTAT(fd)
    return SimpleNamespace(st_mode=st.st_mode, st_uid=st.st_uid + 1)


def gh_prs(*prs: tuple[int, bool]) -> str:
    """A gh body listing open PRs as (number, from a fork) rows, newest first as gh orders them. Like real
    gh it honours `-q .[0].number` (the newest number, fork or not) and prints the JSON list otherwise."""
    rows = ", ".join(f'{{"number": {n}, "isCrossRepository": {str(fork).lower()}}}' for n, fork in prs)
    first = prs[0][0] if prs else "null"
    return f"case \"$*\" in *' -q '*) echo {first} ;; *) echo '[{rows}]' ;; esac"


PR17, PR21, PR99, NO_PR = gh_prs((17, False)), gh_prs((21, False)), gh_prs((99, False)), gh_prs()


class Sandbox:
    """One temp dir holding a repo, a HOME, and a bin dir that is the module's whole PATH."""

    def __init__(self, tc: unittest.TestCase) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="vcs-")).resolve()  # pwd -P: macOS /tmp is a symlink
        tc.addCleanup(shutil.rmtree, self.tmp, True)
        self.home, self.bin, self.repo = self.tmp / "home", self.tmp / "bin", self.tmp / "repo"
        for d in (self.home, self.bin, self.repo):
            d.mkdir()
        subprocess.run(["bash", "-c", '. "$1" && hermetic_link_tools "$2" git', "_", HERMETIC,
                        str(self.bin)], check=True, timeout=30)
        self.counter = self.tmp / "gh-calls"
        self.base_env = {"PATH": str(self.bin), "HOME": str(self.home), "GIT_CONFIG_GLOBAL": os.devnull,
                         "GIT_CONFIG_NOSYSTEM": "1", "ZUVO_GH_TIMEOUT": "5"}
        self.git_env = {**self.base_env, "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                        "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}

    def git(self, *args: str, cwd: Path | None = None) -> str:
        r = subprocess.run([GIT, *args], cwd=cwd or self.repo, env=self.git_env, check=True,
                           capture_output=True, text=True, timeout=30)
        return r.stdout.strip()

    def write(self, rel: str, content: str | bytes, root: Path | None = None) -> Path:
        p = (root or self.repo) / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        data = content.encode("utf-8") if isinstance(content, str) else content
        p.write_bytes(data)
        return p

    def init(self, remote: str | None = None) -> None:
        self.git("init", "-q")
        self.git("symbolic-ref", "HEAD", "refs/heads/main")
        self.write("src/a.py", A_PY)
        self.commit("base")
        subprocess.run([GIT, "remote", "add", "origin", remote or BITBUCKET], cwd=self.repo,
                       env=self.git_env, check=True, timeout=30)

    def commit(self, msg: str, cwd: Path | None = None) -> None:
        self.git("add", "-A", cwd=cwd)
        self.git("commit", "-q", "-m", msg, cwd=cwd)

    def stub_gh(self, body: str | None) -> None:
        """A `gh` that logs one line of argv per call and runs `body`; None leaves PATH without any gh."""
        if body is None:
            return
        gh = self.bin / "gh"
        log = shlex.quote(str(self.counter))
        gh.write_text(f"#!/bin/sh\nprintf 'call %s\\n' \"$*\" >> {log}\n{body}\n", encoding="utf-8")
        gh.chmod(0o755)

    def gh_argv(self) -> list[str]:
        return self.counter.read_text(encoding="utf-8").splitlines() if self.counter.exists() else []

    def gh_calls(self) -> int:
        return len(self.gh_argv())

    def env(self, extra: dict[str, str]) -> "mock._patch_dict":
        return mock.patch.dict(os.environ, {**self.base_env, **extra}, clear=True)


def dead_within(pid: int, seconds: float) -> bool:
    """True once `pid` is gone (or a zombie nobody reaped yet), polling at most `seconds`."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        stat = Path(f"/proc/{pid}/stat")
        if stat.exists() and stat.read_text(encoding="utf-8").rsplit(")", 1)[-1].split()[0] == "Z":
            return True
        time.sleep(0.05)
    return False


class SiteTests(unittest.TestCase):
    """check_site: the cited file:line must hold in the WORK TREE, not in HEAD."""

    def setUp(self) -> None:
        sb = self.sb = Sandbox(self)
        sb.init()
        sb.write("src/crlf.py", b"x = 1\r\nif total > limit:\r\n")
        sb.write("src/latin1.py", b"caf\xe9 = 1\nif total > limit:\n")
        sb.write("src/gone.py", "if total > limit:\n")
        sb.commit("more")
        (sb.repo / "src" / "gone.py").unlink()
        sb.write("src/new.py", "if total > limit:\n")
        self.outside = sb.write("outside.py", "if total > limit:\n", root=sb.tmp)
        (sb.repo / "src" / "out.py").symlink_to(self.outside)
        (sb.repo / "src" / "link.py").symlink_to("a.py")
        sb.write("outdir/x.py", "if total > limit:\n", root=sb.tmp)
        (sb.repo / "src" / "linkdir").symlink_to(sb.tmp / "outdir")
        os.mkfifo(sb.repo / "src" / "pipe.py")

    def rows(self) -> list[tuple[str, str, int, str | None, str | None]]:
        return [
            ("untracked new file refused, though build writes before it commits", "src/new.py", 1, ANCHOR,
             None),
            ("file deleted in the work tree accepted because HEAD still has it", "src/gone.py", 1, ANCHOR,
             "file-not-in-worktree"),
            ("anchor 3 lines below the cited line refused: window too narrow", "src/a.py", 7, ANCHOR, None),
            ("anchor 3 lines above the cited line refused: window too narrow", "src/a.py", 13, ANCHOR, None),
            ("anchor 4 lines below accepted: window too wide", "src/a.py", 6, ANCHOR, "anchor-not-at-line"),
            ("anchor 4 lines above accepted: window too wide", "src/a.py", 14, ANCHOR, "anchor-not-at-line"),
            ("anchor matched only with exact spacing", "src/a.py", 10, ANCHOR, None),
            ("a different statement at the line accepted as the anchor", "src/a.py", 10,
             "while total < limit:", "anchor-not-at-line"),
            ("line 0 accepted", "src/a.py", 0, None, "line-out-of-range"),
            ("line past EOF accepted", "src/a.py", 21, None, "line-out-of-range"),
            ("the last line read as past EOF", "src/a.py", 20, "x20 = 20", None),
            ("report-only finding without anchor refused for lacking one", "src/a.py", 2, None, None),
            ("CRLF line endings hide the anchor", "src/crlf.py", 2, ANCHOR, None),
            ("CRLF counted as two line breaks", "src/crlf.py", 3, None, "line-out-of-range"),
            ("non-UTF-8 file raises instead of answering", "src/latin1.py", 2, ANCHOR, None),
            ("`..` escapes the repo", "../outside.py", 1, ANCHOR, "path-outside-repo"),
            ("absolute path outside the repo accepted", str(self.outside), 1, ANCHOR, "path-outside-repo"),
            ("symlink pointing out of the repo followed", "src/out.py", 1, ANCHOR, "path-outside-repo"),
            ("a directory read as a file", "src", 1, None, "file-not-in-worktree"),
            ("in-repo symlink refused as if it pointed out", "src/link.py", 10, ANCHOR, None),
            ("a symlinked DIRECTORY out of the repo followed (only the last component resolved)",
             "src/linkdir/x.py", 1, ANCHOR, "path-outside-repo"),
            ("a NUL in the cited path crashes with ValueError instead of refusing", "src/a\x00.py", 1,
             ANCHOR, "path-outside-repo"),
            ("a FIFO at the cited path blocks backlog-add on open", "src/pipe.py", 1, None,
             "file-not-in-worktree"),
            ("anchor matched as a regex: `.*` holds at any line", "src/a.py", 10, ".*", "anchor-not-at-line"),
        ]

    def test_site_holds_in_the_work_tree(self) -> None:
        for name, path, line, anchor, want in self.rows():
            with self.subTest(name), self.sb.env({}):
                self.assertEqual(want, vcs.check_site(str(self.sb.repo), path, line, anchor))

    def test_normalize_path_gives_one_spelling_per_file(self) -> None:
        repo = str(self.sb.repo)
        rows = [
            ("`./` prefix splits one file into two ids", "./src/a.py", "src/a.py"),
            ("plain relative path altered", "src/a.py", "src/a.py"),
            ("absolute in-repo path kept absolute", f"{repo}/src/a.py", "src/a.py"),
            ("`..` inside the repo left unresolved", "src/../src/a.py", "src/a.py"),
            ("`..` out of the repo accepted", "../outside.py", None),
            ("absolute path outside accepted", str(self.outside), None),
            ("symlink out of the repo accepted", "src/out.py", None),
            ("in-repo symlink renamed to its target: the cited path changes", "src/link.py",
             "src/link.py"),
            ("empty path read as the repo root", "", None),
            ("symlinked directory out of the repo accepted", "src/linkdir/x.py", None),
            ("a NUL in the path raises ValueError", "src/a\x00.py", None),
            ("a non-UTF-8 byte (surrogateescape) accepted, then unwritable in the ledger", "src/a\udcff.py",
             None),
        ]
        for name, given, want in rows:
            with self.subTest(name):
                self.assertEqual(want, vcs.normalize_path(repo, given))

    def test_symlink_swapped_after_the_check_is_not_read(self) -> None:
        # normalize_path passed while src/out.py still pointed in; the read must re-check what it opened
        real = os.path.realpath
        out, inside = str(self.sb.repo / "src" / "out.py"), str(self.sb.repo / "src" / "a.py")
        rows = [
            ("re-pointed out before the open: the outside file read", {}),
            ("re-pointed back in right after the open: the outside inode read", {out: inside}),
        ]
        repo = str(self.sb.repo)
        for name, swapped in rows:
            with self.subTest(name), self.sb.env({}), \
                    mock.patch.object(vcs, "normalize_path", return_value="src/out.py"), \
                    mock.patch.object(vcs.os.path, "realpath",
                                      side_effect=lambda p, m=swapped: m.get(p) or real(p)):
                self.assertEqual("path-outside-repo", vcs.check_site(repo, "src/out.py", 1, ANCHOR))

    def test_read_error_mid_file_is_refused_not_raised(self) -> None:
        # an EIO while reading the cited file escaping check_site as a traceback instead of a refusal
        with self.sb.env({}), mock.patch.object(vcs, "open", eio_open, create=True):
            got = vcs.check_site(str(self.sb.repo), "src/a.py", 10, ANCHOR)
        self.assertEqual("file-not-in-worktree", got)

    def test_check_target_reuses_the_admission_shapes(self) -> None:
        rows = [("URL target refused", "https://shop.example.com/cart", None),
                ("host target refused", "api.example.com", None),
                ("subject target refused", "subject:review-incomplete", None),
                ("free text accepted as a target", "the checkout page", "bad-target")]
        for name, target, want in rows:
            with self.subTest(name):
                self.assertEqual(want, vcs.check_target(target))


class DefaultBranchTests(unittest.TestCase):
    """ZUVO_DEFAULT_BRANCH > origin/HEAD > main: on TGM origin/HEAD says master, the work goes to develop."""

    def test_env_beats_origin_head_beats_main(self) -> None:
        head_to_master = ("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master")
        no_head = ("update-ref", "refs/remotes/origin/other", "HEAD")
        rows = [
            ("origin/HEAD beats the env: TGM entries compared against master",
             {"ZUVO_DEFAULT_BRANCH": "develop"}, head_to_master, "develop"),
            ("origin/HEAD ignored", {}, head_to_master, "master"),
            ("no fallback when nothing names the default", {}, no_head, "main"),
        ]
        for name, env, origin_setup, want in rows:
            with self.subTest(name):
                sb = Sandbox(self)
                sb.init()
                sb.git("update-ref", "refs/remotes/origin/master", "HEAD")
                sb.git(*origin_setup)
                with sb.env(env):
                    self.assertEqual(want, vcs.default_branch(str(sb.repo)))


class TagTests(unittest.TestCase):
    """resolve_tag: default branch: none; else --pr, env, gh (github.com only), [branch:], untaggable."""

    ROWS = [
        # name, branch, remote, gh body (None = no gh), env, --pr, (kind, value, rendered), gh calls
        ("entry on the default branch tagged", "main", GITHUB, PR17, {}, None, ("none", "", ""), 0),
        ("--pr tags a default-branch entry", "main", GITHUB, None, {}, "12", ("none", "", ""), 0),
        ("--pr ignored", "feat/x", GITHUB, PR17, {}, "12", ("pr", "12", "[pr:12]"), 0),
        ("ZUVO_BACKLOG_PR ignored", "feat/x", GITHUB, PR17, {"ZUVO_BACKLOG_PR": "13"}, None,
         ("pr", "13", "[pr:13]"), 0),
        ("env beats the explicit --pr", "feat/x", GITHUB, None, {"ZUVO_BACKLOG_PR": "13"}, "12",
         ("pr", "12", "[pr:12]"), 0),
        ("open PR from gh not used", "feat/x", GITHUB, PR17, {}, None, ("pr", "17", "[pr:17]"), 1),
        ("gh asked about a non-github remote", "feat/x", BITBUCKET, PR17, {}, None,
         ("branch", "feat/x", "[branch:feat/x]"), 0),
        ("ZUVO_PR_LOOKUP=0 still calls gh", "feat/x", GITHUB, PR17, {"ZUVO_PR_LOOKUP": "0"}, None,
         ("branch", "feat/x", "[branch:feat/x]"), 0),
        ("missing gh crashes the tag", "feat/x", GITHUB, None, {}, None,
         ("branch", "feat/x", "[branch:feat/x]"), 0),
        ("scp-style github remote treated as non-github", "feat/x", GITHUB_SSH, PR17, {}, None,
         ("pr", "17", "[pr:17]"), 1),
        ("gh's empty list for no open PR used as a PR number", "feat/x", GITHUB, NO_PR, {}, None,
         ("branch", "feat/x", "[branch:feat/x]"), 1),
        ("empty gh answer read as a PR", "feat/x", GITHUB, "exit 0", {}, None,
         ("branch", "feat/x", "[branch:feat/x]"), 1),
        ("non-JSON gh answer used as a PR", "feat/x", GITHUB, "echo abc", {}, None,
         ("branch", "feat/x", "[branch:feat/x]"), 1),
        ("non-integer PR number in gh's JSON used as a PR", "feat/x", GITHUB,
         """echo '[{"number": "17 x", "isCrossRepository": false}]'""", {}, None,
         ("branch", "feat/x", "[branch:feat/x]"), 1),
        ("a fork's PR from an equally named branch tags the entry", "feat/x", GITHUB, gh_prs((30, True)),
         {}, None, ("branch", "feat/x", "[branch:feat/x]"), 1),
        ("a fork's newer PR chosen over the branch's own", "feat/x", GITHUB, gh_prs((30, True), (17, False)),
         {}, None, ("pr", "17", "[pr:17]"), 1),
        ("failing gh's stdout used as a PR", "feat/x", GITHUB, f"{PR17}; exit 1", {}, None,
         ("branch", "feat/x", "[branch:feat/x]"), 1),
        ("branch outside [A-Za-z0-9._/-] renamed or tagged", "feat/a+b", GITHUB, NO_PR, {}, None,
         ("untaggable", "feat/a+b", ""), 1),
        ("untaggable branch ignores its open PR", "feat/a+b", GITHUB, PR17, {}, None,
         ("pr", "17", "[pr:17]"), 1),
        ("legal branch name rewritten", "feat/x-y.1", BITBUCKET, None, {}, None,
         ("branch", "feat/x-y.1", "[branch:feat/x-y.1]"), 0),
        ("github.com in the PATH of another host sent to gh", "feat/x",
         "https://evil.example.com/github.com/acme/app.git", PR17, {}, None,
         ("branch", "feat/x", "[branch:feat/x]"), 0),
        ("a local path containing /github.com/ sent to gh", "feat/x", "file:///srv/github.com/acme/app",
         PR17, {}, None, ("branch", "feat/x", "[branch:feat/x]"), 0),
        ("plain-http github remote sent to gh", "feat/x", "http://github.com/acme/app.git", PR17, {},
         None, ("branch", "feat/x", "[branch:feat/x]"), 0),
        ("a host that only starts with github.com sent to gh", "feat/x",
         "https://github.com.evil.example.com/acme/app.git", PR17, {}, None,
         ("branch", "feat/x", "[branch:feat/x]"), 0),
        ("github.com as the userinfo of another host sent to gh", "feat/x",
         "https://github.com@evil.example.com/acme/app.git", PR17, {}, None,
         ("branch", "feat/x", "[branch:feat/x]"), 0),
        ("upper-case github host refused", "feat/x", "HTTPS://GitHub.com/acme/app", PR17, {}, None,
         ("pr", "17", "[pr:17]"), 1),
        ("ssh:// github remote with a port refused", "feat/x", "ssh://git@github.com:22/acme/app.git",
         PR17, {}, None, ("pr", "17", "[pr:17]"), 1),
        ("https github remote with userinfo and port refused", "feat/x",
         "https://x-access-token:t0k@github.com:443/acme/app.git", PR17, {}, None,
         ("pr", "17", "[pr:17]"), 1),
    ]

    def test_tag_order(self) -> None:
        for name, branch, remote, gh, env, pr, want, calls in self.ROWS:
            with self.subTest(name):
                sb = Sandbox(self)
                sb.init(remote)
                sb.git("checkout", "-q", "-B", branch)
                sb.stub_gh(gh)
                with sb.env(env):
                    tag = vcs.resolve_tag(str(sb.repo), pr)
                self.assertEqual(want, (tag.kind, tag.value, tag.render()))
                self.assertEqual(calls, sb.gh_calls())

    def test_gh_is_asked_about_exactly_this_repo_and_branch(self) -> None:
        rows = [
            ("gh left to pick the repo from the remotes itself (another remote, another repo)", "feat/x",
             "--repo=github.com/acme/app"),
            ("a branch named like an option handed to gh as a separate argv word", "--help", "--head=--help"),
        ]
        for name, branch, want in rows:
            with self.subTest(name):
                sb = Sandbox(self)
                sb.init(GITHUB)
                sb.git("update-ref", f"refs/heads/{branch}", "HEAD")
                sb.git("symbolic-ref", "HEAD", f"refs/heads/{branch}")
                sb.stub_gh(PR17)
                with sb.env({}):
                    vcs.resolve_tag(str(sb.repo), None)
                self.assertIn(want, sb.gh_argv()[0].split())

    def test_hung_gh_is_abandoned_at_its_timeout(self) -> None:
        # a hung gh blocking backlog-add (and the lock its caller may hold) past ZUVO_GH_TIMEOUT. No
        # wall clock: gh answers PR 17 only after 3 s, so `[pr:17]` means the 1 s timeout (or the 5 s
        # default instead of it) was not applied; 3x slack between the timeout and the answer.
        sb = Sandbox(self)
        sb.init(GITHUB)
        sb.git("checkout", "-q", "-b", "feat/x")
        sb.stub_gh(f"{shlex.quote(SLEEP)} 3; {PR17}")
        with sb.env({"ZUVO_GH_TIMEOUT": "1"}):
            tag = vcs.resolve_tag(str(sb.repo), None).render()
        self.assertEqual(("[branch:feat/x]", 1), (tag, sb.gh_calls()))

    def test_hung_gh_leaves_no_orphan(self) -> None:
        # killing only gh's own pid on timeout orphans its children; each backlog-add would leak one
        sb = Sandbox(self)
        sb.init(GITHUB)
        sb.git("checkout", "-q", "-b", "feat/x")
        pidfile = sb.tmp / "orphan.pid"
        sb.stub_gh(f"{shlex.quote(SLEEP)} 30 &\necho $! > {shlex.quote(str(pidfile))}\nwait")
        with sb.env({"ZUVO_GH_TIMEOUT": "0.5"}):
            tag = vcs.resolve_tag(str(sb.repo), None).render()
        orphan = int(pidfile.read_text(encoding="utf-8"))
        self.assertEqual(("[branch:feat/x]", True), (tag, dead_within(orphan, 5)))

    def test_gh_timeout_falls_back_to_5s(self) -> None:
        rows = [("non-numeric timeout crashes or disables the bound", "abc", 5.0),
                ("zero timeout makes every gh call time out at once", "0", 5.0),
                ("negative timeout passed to the subprocess", "-1", 5.0),
                ("a valid timeout ignored", "2.5", 2.5)]
        for name, raw, want in rows:
            with self.subTest(name), mock.patch.dict(os.environ, {"ZUVO_GH_TIMEOUT": raw}):
                self.assertEqual(want, vcs._gh_timeout())

    def test_head_sha7_is_seven_chars_and_none_before_the_first_commit(self) -> None:
        # a wrong-length or unborn-HEAD crash in the sha the ledger record carries
        sb = Sandbox(self)
        sb.init()
        full = sb.git("rev-parse", "HEAD")
        fresh = sb.tmp / "fresh"
        fresh.mkdir()
        sb.git("init", "-q", cwd=fresh)
        with sb.env({}):
            self.assertEqual((full[:7], None), (vcs.head_sha7(str(sb.repo)), vcs.head_sha7(str(fresh))))

    def test_inherited_git_env_cannot_point_at_another_repo(self) -> None:
        # a hook exports GIT_DIR / GIT_INDEX_FILE; git then answers for that repo, not the cwd one
        sb = Sandbox(self)
        sb.init()
        other = sb.tmp / "other"
        other.mkdir()
        sb.git("init", "-q", cwd=other)
        sb.write("b.py", "b\n", root=other)
        sb.commit("other", cwd=other)
        rows = [
            ("GIT_DIR: HEAD read from the other repo", {"GIT_DIR": str(other / ".git")}),
            ("GIT_WORK_TREE + GIT_DIR: HEAD read from the other repo",
             {"GIT_DIR": str(other / ".git"), "GIT_WORK_TREE": str(other)}),
        ]
        want = sb.git("rev-parse", "--short=7", "HEAD")
        for name, env in rows:
            with self.subTest(name), sb.env(env):
                self.assertEqual(want, vcs.head_sha7(str(sb.repo)))

    def test_non_integer_pr_is_refused_not_dropped(self) -> None:
        # a typo'd --pr silently falling through to [branch:] would ticket the wrong thing
        sb = Sandbox(self)
        sb.init()
        sb.git("checkout", "-q", "-b", "feat/x")
        rows = [("--pr abc", "abc", {}, r"^--pr: 'abc' is not a PR number$"),
                ("ZUVO_BACKLOG_PR=1.5", None, {"ZUVO_BACKLOG_PR": "1.5"},
                 r"^ZUVO_BACKLOG_PR: '1\.5' is not a PR number$")]
        for name, pr, env, message in rows:
            with self.subTest(name), sb.env(env), self.assertRaisesRegex(ValueError, message):
                vcs.resolve_tag(str(sb.repo), pr)

    def test_detached_head_is_tagged_by_default_sha_explicit_pr_or_nothing(self) -> None:
        rows = [
            ("detached on the default branch's sha tagged", "main", None, PR17, ("none", ""), 0),
            ("detached off the default tagged by a branch it is not on", "feat/x", None, PR17,
             ("untaggable", ""), 0),
            ("--pr ignored on a detached HEAD", "feat/x", "9", None, ("pr", "9"), 0),
        ]
        for name, ref, pr, gh, want, calls in rows:
            with self.subTest(name):
                sb = Sandbox(self)
                sb.init(GITHUB)
                sb.git("checkout", "-q", "-b", "feat/x")
                sb.write("src/b.py", "b = 1\n")
                sb.commit("feat")
                sb.git("checkout", "-q", "--detach", ref)
                sb.stub_gh(gh)
                with sb.env({}):
                    tag = vcs.resolve_tag(str(sb.repo), pr)
                self.assertEqual(want, (tag.kind, tag.value))
                self.assertEqual(calls, sb.gh_calls())


    def test_git_that_cannot_name_the_branch_is_an_error_not_a_detached_head(self) -> None:
        # a failing `git symbolic-ref` (a timeout, a locked or corrupt repo) read as a detached HEAD: the
        # feature-branch entry is filed untagged and the intake tickets it at once
        sb = Sandbox(self)
        sb.init(BITBUCKET)
        sb.git("checkout", "-q", "-b", "feat/y")
        git = sb.bin / "git"
        git.unlink()
        git.write_text(f"#!/bin/sh\ncase \" $* \" in *\" symbolic-ref \"*HEAD*) exit 128 ;; esac\n"
                       f"exec {shlex.quote(GIT)} \"$@\"\n", encoding="utf-8")
        git.chmod(0o755)
        with sb.env({}), self.assertRaisesRegex(OSError, r"symbolic-ref HEAD gave no answer \(rc=128\)"):
            vcs.resolve_tag(str(sb.repo), None)

    def test_detached_at_remote_default_without_local_ref(self) -> None:
        # a worktree with only origin/main: detached on its tip must read as the default, not untaggable
        sb = Sandbox(self)
        sb.init(GITHUB)
        sb.git("update-ref", "refs/remotes/origin/main", "main")
        sb.git("checkout", "-q", "--detach", "refs/remotes/origin/main")
        sb.git("branch", "-q", "-D", "main")
        with sb.env({}):
            tag = vcs.resolve_tag(str(sb.repo), None)
        self.assertEqual(("none", "", ""), (tag.kind, tag.value, tag.render()))


class PrCacheTests(unittest.TestCase):
    """The gh answer is cached 15 min under $HOME/.zuvo/cache, per remote and branch."""

    def setUp(self) -> None:
        sb = self.sb = Sandbox(self)
        sb.init(GITHUB)
        sb.git("checkout", "-q", "-b", "feat/x")
        sb.stub_gh(PR17)
        self.now = time.time()

    def tag_at(self, offset: float) -> str:
        with self.sb.env({}), mock.patch.object(vcs.time, "time", return_value=self.now + offset):
            return vcs.resolve_tag(str(self.sb.repo), None).render()

    def test_gh_answer_is_reused_only_inside_the_15_minute_ttl(self) -> None:
        rows = [("answer not reused inside the TTL", 899, 1), ("answer reused after the TTL", 901, 2),
                ("a row dated in the future (clock stepped back) reused instead of asking gh", -1, 2)]
        for name, offset, calls in rows:
            with self.subTest(name):
                self.sb.counter.unlink(missing_ok=True)
                shutil.rmtree(self.sb.home / ".zuvo", ignore_errors=True)
                self.assertEqual(("[pr:17]", "[pr:17]"), (self.tag_at(0), self.tag_at(offset)))
                self.assertEqual(calls, self.sb.gh_calls())

    def test_cache_written_by_rename_under_home(self) -> None:
        # a temp file left behind, or the cache written anywhere but $HOME/.zuvo/cache
        self.tag_at(0)
        cache = self.sb.home.joinpath(*CACHE_REL)
        self.assertEqual([cache.name], sorted(os.listdir(cache.parent)))
        self.assertEqual(f"{self.now:.0f}\t{SHA256_ACME_APP}\tfeat/x\t17\n",
                         cache.read_text(encoding="utf-8"))

    def test_another_repo_does_not_reuse_the_answer(self) -> None:
        # a cache keyed by branch alone tags feat/x of other/app with acme/app's PR
        first = self.tag_at(0)
        self.sb.git("remote", "set-url", "origin", "https://github.com/other/app.git")
        self.sb.stub_gh(PR99)
        self.assertEqual(("[pr:17]", "[pr:99]"), (first, self.tag_at(1)))

    def test_cache_is_private_to_the_user(self) -> None:
        # a umask-default cache dir lets other local users list which repos and branches are worked on
        self.tag_at(0)
        cache = self.sb.home.joinpath(*CACHE_REL)
        modes = (stat.S_IMODE(cache.parent.stat().st_mode), stat.S_IMODE(cache.stat().st_mode))
        self.assertEqual((0o700, 0o600), modes)

    def test_preexisting_open_cache_dir_is_tightened(self) -> None:
        # makedirs' mode applies only on creation: a 0755 ~/.zuvo/cache from another tool stays open
        (self.sb.home / ".zuvo" / "cache").mkdir(parents=True, mode=0o755)
        (self.sb.home / ".zuvo" / "cache").chmod(0o755)
        self.tag_at(0)
        self.assertEqual(0o700, stat.S_IMODE(self.sb.home.joinpath(*CACHE_REL).parent.stat().st_mode))

    def test_cache_dir_of_another_user_is_not_trusted(self) -> None:
        # rows in a directory someone else controls returned as authoritative without asking gh
        with mock.patch.object(vcs.os, "geteuid", return_value=os.geteuid() + 1):
            self.assertEqual(("[pr:17]", "[pr:17]"), (self.tag_at(0), self.tag_at(1)))
        self.assertEqual(2, self.sb.gh_calls())

    def plant_fifo(self, cache: Path) -> contextlib.AbstractContextManager[None]:
        """Replace the cache with a FIFO whose pipe already holds its rows (a writer keeps it open)."""
        rows = cache.read_bytes()
        cache.unlink()
        os.mkfifo(cache, 0o600)
        fd = os.open(cache, os.O_RDWR)
        self.addCleanup(os.close, fd)
        os.write(fd, rows)
        return contextlib.nullcontext()

    def foreign_owner(self, cache: Path) -> contextlib.AbstractContextManager[object]:
        return mock.patch.object(vcs.os, "fstat", foreign_fstat)

    def test_cache_file_that_is_not_our_plain_file_is_a_miss(self) -> None:
        rows: list[tuple[str, Callable[[Path], contextlib.AbstractContextManager[object]]]] = [
            ("a FIFO planted at the cache path: the rows a writer feeds it rendered as `[pr:N]`",
             self.plant_fifo),
            ("a cache file owned by another user (in our private dir) returned without asking gh",
             self.foreign_owner),
        ]
        cache = self.sb.home.joinpath(*CACHE_REL)
        for name, plant in rows:
            with self.subTest(name):
                self.sb.counter.unlink(missing_ok=True)
                shutil.rmtree(self.sb.home / ".zuvo", ignore_errors=True)
                self.sb.stub_gh(PR17)
                self.tag_at(0)
                with plant(cache):
                    self.sb.stub_gh(PR21)
                    self.assertEqual(("[pr:21]", 2), (self.tag_at(1), self.sb.gh_calls()))

    def test_symlinked_cache_file_is_not_read(self) -> None:
        # a cache path re-pointed at a planted file whose rows are then rendered as `[pr:N]`
        self.tag_at(0)
        cache = self.sb.home.joinpath(*CACHE_REL)
        planted = self.sb.tmp / "planted.tsv"
        planted.write_text(cache.read_text(encoding="utf-8").replace("\t17\n", "\t99\n"), encoding="utf-8")
        cache.unlink()
        cache.symlink_to(planted)
        self.sb.stub_gh(PR21)
        self.assertEqual("[pr:21]", self.tag_at(1))

    def test_another_branch_does_not_reuse_the_answer(self) -> None:
        # a cache keyed without the branch tags every branch with the first branch's PR
        first = self.tag_at(0)
        self.sb.git("checkout", "-q", "-b", "feat/y")
        self.sb.stub_gh(PR21)
        self.assertEqual(("[pr:17]", "[pr:21]"), (first, self.tag_at(1)))

    def test_tokened_remote_never_reaches_a_file_argv_or_stderr(self) -> None:
        # CQ5: a credential in the remote URL copied into the cache, gh's argv (ps) or a warning
        sb = Sandbox(self)
        sb.init(TOKENED)
        sb.git("checkout", "-q", "-b", "feat/x")
        sb.stub_gh(PR17)
        with sb.env({}), mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            tag = vcs.resolve_tag(str(sb.repo), None).render()
        cache = sb.home.joinpath(*CACHE_REL).read_text(encoding="utf-8")
        sinks = cache + "".join(sb.gh_argv()) + err.getvalue()
        self.assertEqual(("[pr:17]", True, False), (tag, "\tfeat/x\t17" in cache, "ghp_secret123" in sinks))

    def test_no_pr_answer_is_cached_as_a_miss(self) -> None:
        # a PR-less branch asking gh (up to ZUVO_GH_TIMEOUT) on every single backlog-add
        rows = [("an empty list", NO_PR), ("only a fork's PR for the branch name", gh_prs((30, True)))]
        for name, body in rows:
            with self.subTest(name):
                self.sb.counter.unlink(missing_ok=True)
                shutil.rmtree(self.sb.home / ".zuvo", ignore_errors=True)
                self.sb.stub_gh(body)
                self.assertEqual(("[branch:feat/x]", "[branch:feat/x]"), (self.tag_at(0), self.tag_at(1)))
                self.assertEqual(1, self.sb.gh_calls())

    def test_unwritable_cache_warns_and_still_tags(self) -> None:
        # a cache write failure aborting the tag, or failing with no word on stderr
        self.sb.write(".zuvo", "a file where the cache directory should be", root=self.sb.home)
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            tag = self.tag_at(0)
        self.assertEqual(("[pr:17]", True), (tag, "PR cache not written" in err.getvalue()))

    def test_tampered_cached_pr_is_asked_again(self) -> None:
        # a fresh, correctly keyed row whose PR is not a number rendered verbatim as `[pr:…]`
        rows = [("text after the number", "17 injected"), ("a fraction", "1.5"), ("a leading zero", "017")]
        cache = self.sb.home.joinpath(*CACHE_REL)
        for name, bad in rows:
            with self.subTest(name):
                self.sb.counter.unlink(missing_ok=True)
                shutil.rmtree(self.sb.home / ".zuvo", ignore_errors=True)
                self.sb.stub_gh(PR17)
                self.tag_at(0)
                cache.write_text(cache.read_text(encoding="utf-8").replace("\t17\n", f"\t{bad}\n"),
                                 encoding="utf-8")
                self.sb.stub_gh(PR21)
                self.assertEqual(("[pr:21]", 2), (self.tag_at(1), self.sb.gh_calls()))

    def test_corrupt_cache_is_ignored(self) -> None:
        # a garbage cache line crashing every later backlog-add on the machine
        garbage = "garbage\nnot\ta\tnumber\tx\n\x00\n"
        self.sb.write("cache/backlog-add-pr.tsv", garbage, root=self.sb.home / ".zuvo")
        self.assertEqual("[pr:17]", self.tag_at(0))
        self.assertEqual(1, self.sb.gh_calls())


class ChangedLinesTests(unittest.TestCase):
    """changed_lines: merge-base(HEAD, default) → work tree; an untracked file is fully changed."""

    def setUp(self) -> None:
        sb = self.sb = Sandbox(self)
        sb.init()
        for rel in ("src/c.py", "src/same.py", "src/del.py", "lib/real/x.py", ".gitignore"):
            sb.write(rel, SIX if rel != ".gitignore" else "*.log\n")
        sb.commit("six")
        sb.git("branch", "feat/x")
        sb.write("src/same.py", "MAIN\nb\nc\nd\ne\nf\n")
        sb.commit("main moved on after the branch point")
        sb.git("checkout", "-q", "feat/x")
        sb.write("src/c.py", "a\nb\nC\nd\ne\nf\n")
        sb.commit("committed change on line 3")
        sb.write("src/c.py", "a\nb\nC\nd\ne\nNEW\nf\n")         # uncommitted insert, now line 6
        sb.write("src/del.py", "a\nc\nd\ne\nf\n")                # deletion only
        sb.write("src/new.py", "one\ntwo\nthree\n")              # untracked
        sb.write("--stage", "one\ntwo\n")                         # untracked, named like a git option
        os.mkfifo(sb.repo / "src" / "pipe.py")                    # untracked FIFO
        sb.write("build.log", "one\ntwo\n")                       # ignored
        sb.write("lib/real/x.py", "a\nb\nC\nd\ne\nf\n")             # tracked, line 3 changed
        (sb.repo / "lib" / "link").symlink_to("real")            # untracked symlinked directory

    def test_changed_lines_are_the_branch_edits_in_the_work_tree(self) -> None:
        rows = [
            ("committed or uncommitted change missed (merge-base..HEAD only, or HEAD..worktree only)",
             "src/c.py", "main", {3, 6}),
            ("untracked file read as unchanged", "src/new.py", "main", {1, 2, 3}),
            ("diffed against the default's tip: main's own later edit counted as ours", "src/same.py", "main",
             set()),
            ("a pure deletion counted as a changed line", "src/del.py", "main", set()),
            ("no merge-base crashes or counts everything", "src/c.py", "nope", set()),
            ("a file named like an option read by git as one (`ls-files --stage`)", "--stage", "main",
             {1, 2}),
            ("a NUL in the path crashes Popen with ValueError", "src/c\x00.py", "main", set()),
            ("an untracked FIFO blocks backlog-add forever on open", "src/pipe.py", "main", set()),
            ("an ignored file (generated output) counted as fully changed", "build.log", "main", set()),
            ("a tracked file spelled through a symlinked directory counted as fully changed",
             "lib/link/x.py", "main", set()),
            ("a directory expanded by git into every changed line of every file under it", "src", "main",
             set()),
        ]
        for name, path, default, want in rows:
            with self.subTest(name), self.sb.env({}):
                self.assertEqual(want, vcs.changed_lines(str(self.sb.repo), path, default))

    def test_read_error_on_an_untracked_file_is_no_lines_not_a_crash(self) -> None:
        # an EIO while counting an untracked file's lines escaping changed_lines as a traceback
        with self.sb.env({}), mock.patch.object(vcs, "open", eio_open, create=True):
            self.assertEqual(set(), vcs.changed_lines(str(self.sb.repo), "src/new.py", "main"))

    def test_failing_ls_files_is_no_lines(self) -> None:
        # `git ls-files` failing (a corrupt or locked index) read as tracked: the diff then counts lines
        # whose tracking was never proved, and a TEST-GAP on them is promoted to a BUG
        git = self.sb.bin / "git"
        git.unlink()
        git.write_text(f"#!/bin/sh\ncase \" $* \" in *\" ls-files \"*) exit 128 ;; esac\n"
                       f"exec {shlex.quote(GIT)} \"$@\"\n", encoding="utf-8")
        git.chmod(0o755)
        with self.sb.env({}):
            self.assertEqual(set(), vcs.changed_lines(str(self.sb.repo), "src/c.py", "main"))

    def test_inherited_index_file_cannot_hide_tracking(self) -> None:
        # GIT_INDEX_FILE from a hook: an empty foreign index makes a tracked file look new, all lines changed
        with self.sb.env({"GIT_INDEX_FILE": str(self.sb.tmp / "no-index")}):
            self.assertEqual({3, 6}, vcs.changed_lines(str(self.sb.repo), "src/c.py", "main"))

    def test_worktree_with_only_the_remote_default(self) -> None:
        # a linked worktree with origin/develop and no local develop: an empty set would never promote
        sb = Sandbox(self)
        sb.init()
        sb.write("src/c.py", SIX)
        sb.commit("six")
        sb.git("update-ref", "refs/remotes/origin/develop", "HEAD")
        wt = sb.tmp / "wt"
        sb.git("worktree", "add", "-q", "-b", "feat/w", str(wt), "refs/remotes/origin/develop")
        sb.write("src/c.py", "a\nb\nC\nd\ne\nf\n", root=wt)
        with sb.env({"ZUVO_DEFAULT_BRANCH": "develop"}):
            self.assertEqual(({3}, "develop"),
                             (vcs.changed_lines(str(wt), "src/c.py", None), vcs.default_branch(str(wt))))


if __name__ == "__main__":
    unittest.main()
