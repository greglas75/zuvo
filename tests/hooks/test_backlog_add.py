"""scripts/zuvo-home/backlog-add — the one locked write path for memory/backlog.md and the findings
ledger. Every test drives the LAUNCHER as a subprocess in a temp `git init` repo with HOME set to a
temp directory (one in-process row aside, for a git answer no fixture can provoke), and asserts what a
caller sees and what is left on disk: the one verdict line, the exit code, the backlog text and the
folded ledger. Each test names the defect it catches.
"""

import contextlib
import glob
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME_DIR = os.path.join(ROOT, "scripts", "zuvo-home")
LAUNCHER = os.path.join(HOME_DIR, "backlog-add")
ARCHIVER = os.path.join(HOME_DIR, "backlog-archive.py")
sys.path.insert(0, HOME_DIR)
import zuvo_backlog_add as add  # noqa: E402
import zuvo_backlog_entry as ent  # noqa: E402
import zuvo_backlog_findings as fnd  # noqa: E402
import zuvo_backlog_io as zio  # noqa: E402
import zuvo_backlog_parse as zb  # noqa: E402

ANCHOR = "if total > limit:"
SOURCE = "a = 1\nb = 2\nif total > limit:\n    return total - limit\n"
NOW = "2026-10-13T10:00:00+00:00"
# Inherited from a developer shell or a git hook, each would change what the launcher (or the fixture's
# own git) acts on.
SCRUB = ("ZUVO_BACKLOG_PR", "ZUVO_BACKLOG_ADMIT", "ZUVO_DEFAULT_BRANCH", "ZUVO_LOCK_WAIT",
         "ZUVO_BACKLOG_READY_FILE", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
         "GIT_OBJECT_DIRECTORY", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES")
# XDG_CONFIG_HOME too: GIT_CONFIG_GLOBAL stops ~/.gitconfig, not the default excludes file
# ~/.config/git/ignore, so a developer's global `memory/` or `*.jsonl` changed what these specs saw.
HERMETIC_GIT = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "XDG_CONFIG_HOME": os.devnull}
BUG = ("--class", "BUG", "--conf", "85", "--file", "src/a.py", "--line", "3", "--anchor", ANCHOR,
       "--title", "off-by-one at the limit", "--source", "review")
CPLX = ("--class", "CPLX", "--conf", "90", "--file", "src/a.py", "--line", "3", "--title", "too complex",
        "--source", "code-audit")
LOCK_REL = os.path.join("memory", zio.LOCK_NAME)
# The whole line, so a second verdict, a stray word or a missing `wrote=` cannot pass as a verdict.
VERDICT_RE = re.compile(r"(?P<verdict>[A-Z-]+) (?:backlog (?P<b>\S+) (?:seen=\d+ |regression )?)?"
                        r"(?:ledger=)?(?P<f>F-[0-9a-f]{12}) (?:reason=\S+ |seen=\d+ )?(?:legacy )?wrote=\S+")


def bug_line(b_id: str, f_id: str, tag: str) -> str:
    """The whole backlog line BUG files at NOW; callers run with TZ=UTC so the entry's local day is NOW's."""
    return (f"- [ ] {b_id} src/a.py:3 — [BUG] off-by-one at the limit | evidence: - | fix: - | severity: - | "
            f"source: review | conf: 85 | seen: 1 | ledger: {f_id} | 2026-10-13 {tag}")


def scrubbed_env() -> Dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in SCRUB}
    env.update(HERMETIC_GIT)
    return env


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                           "-c", "init.defaultBranch=main", *args], cwd=cwd, env=scrubbed_env(),
                          capture_output=True, text=True, check=True).stdout.strip()


def snapshot(root: Path) -> Dict[str, Optional[str]]:
    """Every file (sha256) and directory (None) under `root` outside .git: byte-identical means equal."""
    out: Dict[str, Optional[str]] = {}
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x != ".git"]
        out.update({os.path.relpath(os.path.join(d, x), root): None for x in dirs})
        out.update({os.path.relpath(os.path.join(d, x), root):
                    hashlib.sha256(Path(d, x).read_bytes()).hexdigest() for x in files})
    return out


def with_args(base: Tuple[str, ...], *override: str) -> List[str]:
    """`base` with each `--flag value` pair in `override` replaced or added."""
    args = dict(zip(base[::2], base[1::2], strict=True))
    args.update(zip(override[::2], override[1::2], strict=True))
    return [x for kv in args.items() for x in kv]


def outside(snap: Dict[str, Optional[str]], directory: str) -> Dict[str, Optional[str]]:
    """`snap` without `directory` itself and what is inside it — not its look-alike siblings."""
    return {k: v for k, v in snap.items() if k != directory and not k.startswith(directory + os.sep)}


def line_fields(line: str) -> Dict[str, Any]:
    """The fields of a verdict line, keyed as `--json` keys them."""
    toks = line.split()
    kv = dict(t.split("=", 1) for t in toks if "=" in t)
    return {"verdict": toks[0], "backlog": toks[2] if toks[1] == "backlog" else None,
            "ledger": kv.get("ledger", toks[1]), "seen": int(kv["seen"]) if "seen" in kv else None,
            "reason": kv.get("reason"), "legacy": "legacy" in toks,
            "wrote": [] if kv["wrote"] == "-" else kv["wrote"].split(",")}


class AddCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="backlog-add-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = self.tmp / "home"
        self.home.mkdir()

    def env(self, now: str = NOW, **extra: str) -> Dict[str, str]:
        """The launcher's environment; `now=""` runs it on the real clock."""
        env = scrubbed_env()
        env.update(HOME=str(self.home), ZUVO_PR_LOOKUP="0", ZUVO_BACKLOG_NOW=now, ZUVO_BACKLOG_HOST="t",
                   **extra)
        return env

    def repo(self, name: str = "r", ignore: str = "", memory: bool = True, branch: str = "feat/x",
             backlog: str = "# Backlog\n\n") -> Path:
        """A repo on `branch` off `main`, holding src/a.py (line 3 is ANCHOR) and, when `memory`, a
        memory/backlog.md holding `backlog`. `git add -A` commits it only when `ignore` (the .gitignore
        text) does not exclude it; an ignored backlog stays an untracked file."""
        r = self.tmp / name
        (r / "src").mkdir(parents=True)
        (r / "src" / "a.py").write_text(SOURCE, encoding="utf-8")
        (r / ".gitignore").write_text(ignore, encoding="utf-8")
        if memory:
            (r / "memory").mkdir()
            (r / "memory" / "backlog.md").write_text(backlog, encoding="utf-8")
        git(r, "init", "-q")
        git(r, "add", "-A")
        git(r, "commit", "-qm", "init")
        git(r, "checkout", "-qb", branch)
        return r

    def add(self, repo: Path, *args: str, launcher: str = LAUNCHER, cwd: Optional[Path] = None,
            **env: str) -> "subprocess.CompletedProcess[str]":
        return subprocess.run([sys.executable, launcher, *args], cwd=cwd or repo, env=self.env(**env),
                              capture_output=True, text=True, timeout=180)

    def verdict(self, p: "subprocess.CompletedProcess[str]") -> Tuple[str, str, str]:
        """(verdict, B-id or "", F-id) of stdout, which must be exactly one well-formed verdict line."""
        lines = p.stdout.splitlines()
        self.assertEqual(len(lines), 1, f"stdout is not one line: {p.stdout!r} stderr: {p.stderr!r}")
        m = VERDICT_RE.fullmatch(lines[0])
        self.assertIsNotNone(m, f"not a verdict line: {lines[0]!r}")
        assert m is not None
        return m["verdict"], m["b"] or "", m["f"]

    def backlog(self, repo: Path) -> str:
        return (repo / "memory" / "backlog.md").read_text(encoding="utf-8")

    def entries(self, repo: Path, b_id: str) -> List[str]:
        return [ln for ln in self.backlog(repo).splitlines() if ln.startswith(f"- [ ] {b_id} ")]

    def folded(self, repo: Path) -> Tuple[Dict[str, fnd.Record], List[fnd.Defect]]:
        return fnd.fold(repo / "memory" / fnd.FINDINGS_DIRNAME)

    def archive(self, repo: Path, *args: str) -> "subprocess.CompletedProcess[str]":
        return subprocess.run([sys.executable, ARCHIVER, *args, "--repo", str(repo)], env=self.env(),
                              capture_output=True, text=True)

    def reopened(self, repo: Path) -> str:
        """File BUG, tick and archive it, see it again: the B-id now open as a REGRESSION re-open. TZ=UTC,
        so the re-open's `[REGRESSION <local day>]` is NOW's day on a runner in any time zone."""
        _, b_id, _ = self.verdict(self.add(repo, *BUG, TZ="UTC"))
        path = repo / "memory" / "backlog.md"
        path.write_text(self.backlog(repo).replace(f"- [ ] {b_id} ", f"- [x] {b_id} ").rstrip("\n")
                        + " DONE 2026-10-13\n", encoding="utf-8")
        self.assertEqual(self.archive(repo, "archive").returncode, 0)
        self.assertEqual(self.verdict(self.add(repo, *BUG, TZ="UTC"))[:2], ("REOPENED", b_id))
        return b_id

    def flat(self, drop: str = "", fake_archiver: str = "") -> str:
        """The launcher and its modules in ONE directory — the ~/.zuvo layout install_zuvo_home makes."""
        d = self.tmp / "flat"
        d.mkdir()
        for src in [LAUNCHER, ARCHIVER, *glob.glob(os.path.join(HOME_DIR, "zuvo_backlog_*.py"))]:
            if os.path.basename(src) != drop:
                shutil.copy2(src, d)
        if fake_archiver:
            (d / "backlog-archive.py").write_text(fake_archiver, encoding="utf-8")
        return str(d / "backlog-add")


class VerdictTests(AddCase):
    def test_accepted_cross_links_the_backlog_line_and_the_record(self) -> None:
        # Defect: the entry and its ledger record do not name each other, so neither can find the other;
        # or the success path leaves the lock behind and every later call times out.
        r = self.repo()
        p = self.add(r, *BUG, TZ="UTC")
        kind, b_id, f_id = self.verdict(p)
        records, _ = self.folded(r)
        self.assertEqual((p.returncode, kind), (0, "ACCEPTED"))
        self.assertRegex(b_id, r"^B-a-BUG-[0-9a-f]{8}$")
        self.assertEqual(self.entries(r, b_id), [bug_line(b_id, f_id, "[branch:feat/x]")])
        self.assertEqual((records[f_id].fields["backlog"], records[f_id].seen), (b_id, 1))
        self.assertFalse((r / LOCK_REL).exists())

    def test_entry_is_dated_by_the_local_day_like_the_archive(self) -> None:
        # Defect: the entry carried the UTC day while backlog-archive.py names its sections by the local
        # day, so an evening finding east of UTC read as filed the day before it was archived.
        r = self.repo()
        _, b_id, _ = self.verdict(self.add(r, *BUG, now="2026-10-13T20:00:00+00:00", TZ="UTC-07"))
        self.assertIn("| 2026-10-14 [branch:feat/x]", self.entries(r, b_id)[0])

    def test_explicit_pr_tags_the_entry(self) -> None:
        # Defect: --pr is validated but the entry is still tagged by branch, which the intake retires
        # when the branch is deleted after the merge.
        r = self.repo()
        _, b_id, f_id = self.verdict(self.add(r, *BUG, "--pr", "7", TZ="UTC"))
        self.assertEqual(self.entries(r, b_id), [bug_line(b_id, f_id, "[pr:7]")])

    def test_bumped_paraphrase_counts_seen_two_on_both_sides(self) -> None:
        # Defect: a reworded title of the same defect files a second entry, or one side undercounts.
        r = self.repo()
        _, b_id, _ = self.verdict(self.add(r, *BUG))
        p = self.add(r, *BUG[:-4], "--title", "boundary check excludes equality", "--source", "drive-by:x")
        kind, b2, f_id = self.verdict(p)
        records, _ = self.folded(r)
        self.assertEqual((p.returncode, kind, b2), (0, "BUMPED", b_id))
        self.assertIn(" seen=2 ", p.stdout)
        self.assertEqual(len(self.entries(r, b_id)), 1)
        self.assertIn("| seen: 2 |", self.entries(r, b_id)[0])
        self.assertEqual(records[f_id].seen, 2)

    def test_reopened_after_archive_writes_a_regression_that_verify_accepts(self) -> None:
        # Defect: a closed-and-archived finding seen again is filed fresh (verify reports an undeclared
        # duplicate) or silently ignored.
        r = self.repo()
        b_id = self.reopened(r)
        verify = self.archive(r, "verify")
        self.assertIn("[REGRESSION 2026-10-13", self.entries(r, b_id)[0])
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)

    def test_reopened_entry_seen_again_is_linked_and_left_as_written(self) -> None:
        # Defect: the REGRESSION line is bumped or re-filed, breaking the protocol's re-open form.
        r = self.repo()
        b_id = self.reopened(r)
        before = self.backlog(r)
        p = self.add(r, *BUG)
        self.assertEqual((p.returncode, self.verdict(p)[:2]), (0, ("BUMPED", b_id)))
        self.assertIn(" legacy wrote=", p.stdout)
        self.assertEqual(self.backlog(r), before)
        self.assertEqual(self.archive(r, "verify").returncode, 0)

    def test_id_only_a_heading_carries_is_linked_not_bumped(self) -> None:
        # Defect: an OPEN id with no checkbox line defining it (a heading entry) crashes the bump with
        # exit 1, so the finding is never persisted while the heading stays open.
        b_id = json.loads(self.add(self.repo(name="probe"), *BUG, "--dry-run", "--json").stdout)["backlog"]
        r = self.repo(backlog=f"# Backlog\n\n### {b_id} — off-by-one at the limit\n\nprose\n")
        before = self.backlog(r)
        p = self.add(r, *BUG)
        self.assertEqual((p.returncode, self.verdict(p)[:2]), (0, ("BUMPED", b_id)))
        self.assertIn(" legacy wrote=", p.stdout)
        self.assertEqual(self.backlog(r), before)
        # and the sighting is not lost: the ledger record links the heading's id
        self.assertEqual(self.folded(r)[0][self.verdict(p)[2]].fields["backlog"], b_id)

    def test_idless_legacy_entry_is_linked_by_the_text_lookup(self) -> None:
        # Defect: a hand-written entry for the same site and title is not found, so a duplicate is filed.
        r = self.repo(backlog="# Backlog\n\n- [ ] src/a.py:3 — off-by-one at the limit\n")
        before = self.backlog(r)
        p = self.add(r, *BUG)
        kind, shown, f_id = self.verdict(p)
        records, _ = self.folded(r)
        self.assertEqual((p.returncode, kind), (0, "BUMPED"))
        self.assertRegex(shown, r"^fp:[0-9a-f]+$")
        self.assertIn(" legacy wrote=", p.stdout)
        self.assertEqual(self.backlog(r), before)
        self.assertIsNone(records[f_id].fields["backlog"])

    def test_ledger_route_leaves_the_backlog_byte_identical(self) -> None:
        # Defect: report-only debt (CPLX at conf 90) leaks into the backlog the intake tickets.
        r = self.repo()
        before = snapshot(r)["memory/backlog.md"]
        p = self.add(r, *CPLX)
        kind, _, f_id = self.verdict(p)
        records, _ = self.folded(r)
        self.assertEqual((p.returncode, kind), (0, "LEDGER"))
        self.assertIn(" reason=class-report-only ", p.stdout)
        self.assertEqual(snapshot(r)["memory/backlog.md"], before)
        self.assertEqual((records[f_id].fields["class"], records[f_id].seen), ("CPLX", 1))

    def test_ledger_bumped_appends_a_sighting_not_a_second_record(self) -> None:
        # Defect: the first call writes a record AND a sighting (seen starts at 2), or a re-sighting
        # writes a second full record.
        r = self.repo()
        self.add(r, *CPLX)
        p = self.add(r, *CPLX)
        kind, _, f_id = self.verdict(p)
        records, _ = self.folded(r)
        segment = next((r / "memory" / "findings").glob("*.jsonl")).read_text(encoding="utf-8")
        self.assertEqual((p.returncode, kind, records[f_id].seen), (0, "LEDGER-BUMPED", 2))
        self.assertIn(" seen=2 ", p.stdout)
        self.assertEqual(segment.count('"class": "CPLX"'), 1)

    def test_discarded_below_the_floor_writes_nothing(self) -> None:
        # Defect: a conf-20 finding is kept somewhere, or memory/ is created for it.
        r = self.repo(memory=False)
        before = snapshot(r)
        p = self.add(r, *BUG[:2], "--conf", "20", *BUG[4:])
        self.assertEqual((p.returncode, p.stdout), (0, "DISCARDED below-floor\n"))
        self.assertEqual(snapshot(r), before)

    REFUSALS = [
        ("an anchor that is gone (fixed in this run) is filed", ("--anchor", "not in the file at all"),
         "anchor-not-at-line"),
        ("a non-integer --pr is a traceback or an untagged entry", ("--pr", "abc"), "bad-pr"),
        ("a path outside the repo is read", ("--file", "../x.py"), "path-outside-repo"),
        ("an --also site that does not exist is kept", ("--also", "src/missing.py:1"),
         "file-not-in-worktree"),
        ("a lowercase class is guessed at", ("--class", "bug"), "unknown-class"),
        ("an --also with no `:LINE` is kept as a site with no line", ("--also", "src/a.py"), "bad-path"),
        ("an --also with a non-integer line is kept or crashes", ("--also", "src/a.py:x"),
         "line-out-of-range"),
        # Last: when it is wrongly accepted, its write must not fail the rows above for the wrong reason.
        ("a 7-digit --pr is written as [pr:1000000], past the intake's 1–6 digits", ("--pr", "1000000"),
         "bad-pr"),
    ]

    def test_refusals_exit_three_and_write_nothing(self) -> None:
        r = self.repo()
        before = snapshot(r)
        for name, override, reason in self.REFUSALS:
            with self.subTest(name):
                p = self.add(r, *with_args(BUG, *override))
                self.assertEqual((p.returncode, p.stdout), (3, f"REFUSED {reason}\n"))
                self.assertEqual(snapshot(r), before)

    LOCK_WAIT_MSG = "backlog-add: ZUVO_LOCK_WAIT must be a number of seconds in (0, 3600], got %r"
    # The last stderr line, exactly: an exit 2 for ANOTHER reason (or argparse's generic one) fails.
    USAGE: List[Tuple[str, Tuple[str, ...], Dict[str, str], str]] = [
        ("an unknown flag is ignored", ("--bogus",), {},
         "backlog-add: error: unrecognized arguments: --bogus"),
        ("a flag abbreviation is guessed", ("--con", "85"), {},
         "backlog-add: error: unrecognized arguments: --con 85"),
        ("a --repo that is not a directory falls back to cwd", ("--repo", "/nonexistent/x"), {},
         "backlog-add: error: --repo '/nonexistent/x' is not a directory"),
        ("a --repo outside any git work tree dies as a detached-HEAD ValueError", ("--repo", "../nogit"), {},
         "backlog-add: error: '../nogit' is not inside a git work tree"),
        ("an unreadable ZUVO_LOCK_WAIT is an import-time traceback", (), {"ZUVO_LOCK_WAIT": "abc"},
         LOCK_WAIT_MSG % "abc"),
        ("a zero ZUVO_LOCK_WAIT makes every queued writer give up at once", (), {"ZUVO_LOCK_WAIT": "0"},
         LOCK_WAIT_MSG % "0"),
        ("a negative ZUVO_LOCK_WAIT makes every queued writer give up at once", (), {"ZUVO_LOCK_WAIT": "-1"},
         LOCK_WAIT_MSG % "-1"),
        ("a ZUVO_LOCK_WAIT above the 3600 s cap is accepted", (), {"ZUVO_LOCK_WAIT": "3601"},
         LOCK_WAIT_MSG % "3601"),
        ("an infinite ZUVO_LOCK_WAIT makes a queued writer wait for ever", (), {"ZUVO_LOCK_WAIT": "inf"},
         LOCK_WAIT_MSG % "inf"),
        ("a NaN ZUVO_LOCK_WAIT slips past a range check written as two `<`/`>` tests", (),
         {"ZUVO_LOCK_WAIT": "nan"}, LOCK_WAIT_MSG % "nan"),
    ]

    def test_usage_errors_exit_two_and_touch_nothing(self) -> None:
        r = self.repo()
        (self.tmp / "nogit").mkdir()
        # The ceiling stops git's upward search at the temp dir, so `nogit` is outside every work tree
        # wherever the temp dir lives; `r` holds its own .git below it and is unaffected. Proven here.
        ceiling = {"GIT_CEILING_DIRECTORIES": str(self.tmp)}
        probe = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=self.tmp / "nogit",
                               env=self.env(**ceiling), capture_output=True, text=True)
        self.assertNotEqual(probe.returncode, 0, f"nogit is inside a work tree: {probe.stdout}")
        before = snapshot(r)
        for name, args, env, message in self.USAGE:
            with self.subTest(name):
                p = subprocess.run([sys.executable, LAUNCHER, *BUG, *args], cwd=r,
                                   env=self.env(**ceiling, **env), capture_output=True, text=True,
                                   timeout=120)
                self.assertEqual((p.returncode, p.stdout), (2, ""))
                self.assertNotIn("Traceback", p.stderr)
                self.assertEqual(p.stderr.splitlines()[-1:], [message])
                self.assertEqual(snapshot(r), before)

    def test_lock_timeout_exits_one_and_leaves_the_holders_lock(self) -> None:
        # Defect: a writer that cannot get the lock writes anyway, or steals/deletes a live holder's lock.
        r = self.repo()
        before = snapshot(r)
        with zio.Lock(str(r / "memory")):
            p = self.add(r, *BUG, ZUVO_LOCK_WAIT="0.4")
            owner = (r / LOCK_REL / "pid").read_text(encoding="utf-8")
            after = snapshot(r)
        self.assertEqual((p.returncode, p.stdout), (1, ""))
        self.assertIn("lock held", p.stderr)
        self.assertEqual(owner, str(os.getpid()))
        self.assertEqual(outside(after, LOCK_REL), before)


class StateTests(AddCase):
    def test_crash_between_the_writes_heals_on_the_next_sighting(self) -> None:
        # Defect: a lost ledger segment makes the next sighting file a second backlog entry. The two
        # counts then differ by design: the entry kept counting bumps, the healed ledger restarts at 1.
        r = self.repo()
        _, b_id, f_id = self.verdict(self.add(r, *BUG))
        shutil.rmtree(r / "memory" / "findings")
        p = self.add(r, *BUG)
        records, _ = self.folded(r)
        self.assertEqual(self.verdict(p)[:2], ("BUMPED", b_id))
        self.assertIn(" seen=1 ", p.stdout)
        self.assertEqual(len(self.entries(r, b_id)), 1)
        self.assertIn("| seen: 2 |", self.entries(r, b_id)[0])
        self.assertEqual((records[f_id].fields["backlog"], records[f_id].seen), (b_id, 1))

    def test_unencodable_argv_is_refused_before_the_backlog_write(self) -> None:
        # Defect: a non-UTF-8 byte in --missing-assertion (stored only in the ledger) passed validation; the
        # promoted entry was written, the ledger append raised UnicodeEncodeError, and each retry bumped
        # the orphan entry's seen.
        r = self.repo()
        with (r / "src" / "a.py").open("a", encoding="utf-8") as fh:
            fh.write("total = 0\n")
        before = snapshot(r)
        p = self.add(r, "--class", "TEST-GAP", "--conf", "85", "--file", "src/a.py", "--line", "5",
                     "--title", "no test for the reset", "--source", "write-tests",
                     "--missing-assertion", "asserts \udcff the total")
        self.assertEqual((p.returncode, p.stdout), (3, "REFUSED bad-field:missing_assertion\n"))
        self.assertEqual(snapshot(r), before)

    def test_inherited_git_dir_does_not_move_the_repo_root(self) -> None:
        # Defect: run from a git hook (GIT_DIR exported) in a subdirectory, the top level read through an
        # unscrubbed git is the cwd, so `--file src/a.py` is looked up as src/src/a.py and refused.
        r = self.repo()
        p = self.add(r, *CPLX, cwd=r / "src", GIT_DIR=str(r / ".git"))
        self.assertEqual((p.returncode, self.verdict(p)[0]), (0, "LEDGER"))

    def test_dry_run_writes_nothing_and_lists_nothing(self) -> None:
        # Defect: --dry-run creates the segment or the lock, or its wrote= names paths a skill would then
        # stage although nothing was written.
        r = self.repo()
        before = snapshot(r)
        dry = self.add(r, *BUG, "--dry-run")
        self.assertEqual(snapshot(r), before)
        _, b_id, f_id = self.verdict(self.add(r, *BUG))
        self.assertEqual(dry.stdout, f"ACCEPTED backlog {b_id} ledger={f_id} wrote=- dry-run\n")

    JSON_PARITY: List[Tuple[str, str, List[str], Tuple[str, ...], str]] = [
        ("ACCEPTED fields differ between the two forms", "accepted", [], BUG, "ACCEPTED"),
        ("BUMPED fields differ between the two forms", "bumped", ["ACCEPTED"], BUG, "BUMPED"),
        ("LEDGER fields differ between the two forms", "ledger", [], CPLX, "LEDGER"),
    ]

    def set_up(self, name: str, args: Tuple[str, ...], verdicts: List[str]) -> Path:
        """A repo where `args` already ran once per entry of `verdicts`, each giving that verdict."""
        r = self.repo(name=name)
        runs = [self.add(r, *args) for _ in verdicts]
        self.assertEqual([(p.returncode, self.verdict(p)[0]) for p in runs], [(0, v) for v in verdicts])
        return r

    def test_json_carries_the_same_fields_as_the_line(self) -> None:
        for name, slug, setup, args, want in self.JSON_PARITY:
            with self.subTest(name):
                line = line_fields(self.add(self.set_up(f"line-{slug}", args, setup), *args).stdout.strip())
                obj = json.loads(self.add(self.set_up(f"json-{slug}", args, setup), *args, "--json").stdout)
                self.assertEqual(line["verdict"], want)
                self.assertEqual({k: obj[k] for k in line}, line)

    def test_wrote_lists_paths_git_add_accepts_in_the_tracked_layout(self) -> None:
        # Defect: wrote= names a path that does not exist or cannot be staged, so the commit misses it.
        r = self.repo()
        wrote = self.add(r, *BUG).stdout.split("wrote=")[1].split()[0].split(",")
        git(r, "add", "--", *wrote)
        self.assertEqual(git(r, "diff", "--cached", "--name-only").splitlines(), sorted(wrote))
        self.assertEqual(wrote[0], "memory/backlog.md")

    def test_wrote_is_a_dash_in_the_ignored_layout(self) -> None:
        # Defect: an ignored backlog's path is listed, and a committing skill force-adds it.
        r = self.repo(ignore="memory/\n")
        p = self.add(r, *BUG)
        kind, b_id, f_id = self.verdict(p)
        self.assertEqual(p.stdout, f"ACCEPTED backlog {b_id} ledger={f_id} wrote=-\n")

    def test_first_call_in_a_repo_without_memory_succeeds(self) -> None:
        # Defect: the lock on a missing memory/ directory fails for ever, or the absent backlog is read.
        r = self.repo(memory=False)
        p = self.add(r, *BUG)
        kind, b_id, _ = self.verdict(p)
        self.assertEqual((p.returncode, kind), (0, "ACCEPTED"))
        self.assertEqual(len(self.entries(r, b_id)), 1)

    def test_also_sites_are_kept_in_the_record(self) -> None:
        # Defect: the other sites of a duplicate are dropped, so the dup-map has one side only.
        r = self.repo()
        (r / "src" / "b.py").write_text(SOURCE, encoding="utf-8")
        _, _, f_id = self.verdict(self.add(r, *CPLX[:1], "DUP", *CPLX[2:], "--also", "./src/b.py:3"))
        records, _ = self.folded(r)
        self.assertEqual([(x["path"], x["line"]) for x in records[f_id].fields["files"]],
                         [("src/a.py", 3), ("src/b.py", 3)])

    def test_also_on_a_later_sighting_is_reported_as_not_recorded(self) -> None:
        # Defect: a later sighting's --also is dropped in silence, so the caller reports a site the
        # ledger never kept (a sighting line has no files[]).
        r = self.repo()
        (r / "src" / "b.py").write_text(SOURCE, encoding="utf-8")
        self.add(r, *BUG)
        p = self.add(r, *BUG, "--also", "src/b.py:3")
        _, _, f_id = self.verdict(p)
        records, _ = self.folded(r)
        self.assertEqual(p.stderr, "backlog-add: --also not recorded: the ledger keeps the sites of the "
                                   "first sighting\n")
        self.assertEqual([(x["path"], x["line"]) for x in records[f_id].fields["files"]], [("src/a.py", 3)])


class RoutingTests(AddCase):
    def test_subject_target_process_goes_to_the_ledger(self) -> None:
        # Defect: a process item with no repository file is refused, or lands in the backlog.
        r = self.repo()
        p = self.add(r, "--class", "PROCESS", "--conf", "60", "--target", "subject:review-incomplete",
                     "--title", "review incomplete", "--source", "review")
        self.assertEqual((p.returncode, self.verdict(p)[0]), (0, "LEDGER"))

    UNTAGGABLE = [
        ("a non-SEC entry on an unresolvable branch lands untagged", "BUG", "LEDGER"),
        ("a SEC entry on an unresolvable branch is held back from the backlog", "SEC", "ACCEPTED"),
    ]

    # A name outside the intake's charset, and one past its 200 characters (tagged, the intake never
    # resolves it and holds the entry for ever).
    UNRESOLVABLE = [("feat/a+b", "a"), ("feat/" + "x" * 196, "b")]

    def test_unresolvable_branch_keeps_non_sec_in_the_ledger_and_files_sec_untagged(self) -> None:
        for branch, repo_name in self.UNRESOLVABLE:
            r = self.repo(name=repo_name, branch=branch)
            for name, cls, want in self.UNTAGGABLE:
                with self.subTest(f"{name} ({len(branch)}-character {branch[:8]}…)"):
                    p = self.add(r, "--class", cls, *BUG[2:])
                    kind, _, f_id = self.verdict(p)
                    records, _ = self.folded(r)
                    self.assertEqual((p.returncode, kind), (0, want))
                    self.assertEqual(records[f_id].fields["reason"], "branch-untaggable")
                    self.assertNotIn("[branch:", self.backlog(r))

    PROMOTION = [
        ("a gap on a line the branch changed is never promoted", "5", "ACCEPTED", r"B-a-BUG-[0-9a-f]{8}"),
        ("a gap on an old line is promoted", "3", "LEDGER", ""),
    ]

    def test_missing_assertion_promotes_only_on_a_changed_line(self) -> None:
        r = self.repo()
        with (r / "src" / "a.py").open("a", encoding="utf-8") as fh:
            fh.write("total = 0\n")
        for name, line, want, prefix in self.PROMOTION:
            with self.subTest(name):
                p = self.add(r, "--class", "TEST-GAP", "--conf", "85", "--file", "src/a.py", "--line", line,
                             "--title", f"no test for line {line}", "--source", "write-tests",
                             "--missing-assertion", "asserts the total")
                kind, b_id, _ = self.verdict(p)
                self.assertEqual(kind, want)
                self.assertRegex(b_id, f"^{prefix}$")

    def test_admit_env_forces_report_only_class_and_marks_the_record(self) -> None:
        # Defect: the user's explicit request is ignored, or a forced entry is indistinguishable.
        r = self.repo()
        p = self.add(r, *CPLX, "--json", ZUVO_BACKLOG_ADMIT="1")
        obj = json.loads(p.stdout)
        records, _ = self.folded(r)
        self.assertEqual((obj["verdict"], obj["forced"]), ("ACCEPTED", True))
        self.assertTrue(records[obj["ledger"]].fields["forced"])


class ForcedTests(AddCase):
    def test_forced_resighting_of_a_ledger_finding_is_recorded(self) -> None:
        # Defect: ZUVO_BACKLOG_ADMIT escalates a known ledger-only finding into the backlog, but the
        # folded record still reads forced=false / class-report-only, so the bypass leaves no trace.
        r = self.repo()
        dup = (*CPLX[:1], "DUP", *CPLX[2:])
        self.assertEqual(self.verdict(self.add(r, *dup))[0], "LEDGER")
        kind, b_id, f_id = self.verdict(self.add(r, *dup, ZUVO_BACKLOG_ADMIT="1"))
        rec = self.folded(r)[0][f_id]
        self.assertEqual(kind, "ACCEPTED")
        self.assertEqual((rec.note, rec.fields["status"], rec.fields["backlog"]),
                         ("forced (natural: class-report-only)", "ticketed", b_id))


class InstallTests(AddCase):
    def test_flat_layout_runs_from_an_unrelated_cwd(self) -> None:
        # Defect: the launcher finds its modules only in the repo checkout, never in ~/.zuvo.
        r = self.repo()
        elsewhere = self.tmp / "elsewhere"
        elsewhere.mkdir()
        p = subprocess.run(["sh", self.flat(), "--repo", str(r), *BUG], cwd=elsewhere, env=self.env(),
                           capture_output=True, text=True, timeout=120)
        self.assertEqual((p.returncode, self.verdict(p)[0]), (0, "ACCEPTED"), p.stderr)

    def test_missing_module_is_an_install_error_not_a_traceback(self) -> None:
        # Defect: a half-copied install prints a traceback a skill cannot classify.
        r = self.repo()
        p = self.add(r, *BUG, launcher=self.flat(drop="zuvo_backlog_vcs.py"))
        self.assertEqual(p.returncode, 1)
        self.assertIn("backlog-add: install incomplete (zuvo_backlog_vcs)", p.stderr)
        self.assertNotIn("Traceback", p.stderr)

    def test_lookup_failure_exits_one_writes_nothing_and_releases_the_lock(self) -> None:
        # Defect: a broken lookup reads as ABSENT and files a duplicate, or leaves the lock held.
        r = self.repo()
        before = snapshot(r)
        p = self.add(r, *BUG, launcher=self.flat(fake_archiver="import sys\nsys.exit(2)\n"))
        self.assertEqual((p.returncode, p.stdout), (1, ""))
        self.assertIn("LookupFailed", p.stderr)
        self.assertEqual(snapshot(r), before)

    def test_hung_lookup_gives_up_inside_the_lock_budget(self) -> None:
        # Defect: one hung lookup holds the lock longer than every queued writer waits, so they all fail.
        r = self.repo()
        launcher = self.flat(fake_archiver="import time\ntime.sleep(60)\n")
        started = time.monotonic()
        p = self.add(r, *BUG, launcher=launcher, ZUVO_LOCK_WAIT="16")
        self.assertEqual((p.returncode, p.stdout), (1, ""))
        self.assertIn("LookupFailed: lookup timed out after 2.0s", p.stderr)
        # Real clock on purpose: a stubbed TimeoutExpired passes with the timeout share computed wrongly.
        self.assertLess(time.monotonic() - started, 16)

    def test_lookup_naming_the_wrong_archive_line_fails_closed(self) -> None:
        # Defect: a lookup line number that no longer points at the entry (the archive was rewritten in
        # between) re-opens the finding by quoting an unrelated archived line.
        b_id = json.loads(self.add(self.repo(name="probe"), *BUG, "--dry-run", "--json").stdout)["backlog"]
        r = self.repo()
        (r / "memory" / "backlog-done.md").write_text("# Done\n\n- [x] B-other-1 unrelated DONE\n")
        before = snapshot(r)
        verdict = f'ARCHIVED id:{b_id.lower()} {b_id} backlog-done.md:3 section="s"'
        fake = f"print({verdict!r})\nraise SystemExit(11)\n"
        p = self.add(r, *BUG, launcher=self.flat(fake_archiver=fake))
        self.assertEqual((p.returncode, p.stdout), (1, ""))
        self.assertIn("does not define", p.stderr)
        self.assertEqual(snapshot(r), before)


class LockTests(AddCase):
    def contend(self, r: Path, finds: List[List[str]], hold: float = 0.0,
                **extra: str) -> List["subprocess.CompletedProcess[str]"]:
        """Every launcher waits AT the lock (proven by the ready file) before the test releases it, so
        the writers run one after another in an order the test does not choose. Writers still alive
        when the test fails are killed, so they cannot write into the temp repo during teardown."""
        ready = self.tmp / "ready"
        env = self.env(**{"ZUVO_LOCK_WAIT": "60", "ZUVO_BACKLOG_READY_FILE": str(ready), **extra})
        procs: List["subprocess.Popen[str]"] = []
        try:
            with zio.Lock(str(r / "memory")):
                for f in finds:                 # one at a time, so `finally` sees every started writer
                    procs.append(subprocess.Popen([sys.executable, LAUNCHER, *f], cwd=r, env=env, text=True,
                                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE))
                deadline = time.monotonic() + 60
                while (len(ready.read_text().splitlines()) if ready.exists() else 0) < len(finds):
                    self.assertLess(time.monotonic(), deadline, "the writers never reached the lock")
                    time.sleep(0.05)
                time.sleep(hold)
                self.released_at = fnd.canonical_ts(time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime()))
            outs = [p.communicate(timeout=120) for p in procs]
        finally:
            for p in procs:
                if p.poll() is None:
                    p.kill()
                    p.communicate()
        return [subprocess.CompletedProcess(p.args, p.returncode, o, e)
                for p, (o, e) in zip(procs, outs, strict=True)]

    def test_parallel_writers_of_one_finding_file_one_entry_seen_n(self) -> None:
        # Defect: a lookup or fold outside the lock lets two writers both see ABSENT and file twice.
        r = self.repo()
        runs = self.contend(r, [list(BUG)] * 3)
        kinds = sorted(self.verdict(p)[0] for p in runs)
        _, b_id, f_id = self.verdict(runs[0])
        records, defects = self.folded(r)
        self.assertEqual([p.returncode for p in runs], [0, 0, 0])
        self.assertEqual(kinds, ["ACCEPTED", "BUMPED", "BUMPED"])
        self.assertEqual(len(self.entries(r, b_id)), 1)
        self.assertIn("| seen: 3 |", self.entries(r, b_id)[0])
        self.assertEqual((records[f_id].seen, defects), (3, []))

    def test_parallel_writers_of_two_findings_keep_both(self) -> None:
        # Defect: interleaved writes lose one entry, or glue two segment lines into one.
        r = self.repo()
        other = with_args(BUG, "--line", "4", "--anchor", "return total - limit")
        runs = self.contend(r, [list(BUG), other])
        ids = [self.verdict(p)[1] for p in runs]
        records, defects = self.folded(r)
        self.assertEqual([self.verdict(p)[0] for p in runs], ["ACCEPTED", "ACCEPTED"])
        self.assertEqual([len(self.entries(r, b)) for b in ids], [1, 1])
        self.assertEqual((len(records), defects), (2, []))

    UNDER_LOCK = [
        ("a refusal under the lock leaves it held", "refused", "/memory/backlog.md\n", "notes.txt", CPLX, 3,
         "REFUSED tracked-findings-beside-ignored-backlog\n"),
        ("an IO error under the lock leaves it held", "io", "", "findings", CPLX, 1, ""),
        ("an unusable ledger is found only after the backlog was already written", "half", "", "findings",
         BUG, 1, ""),
    ]

    def test_exit_under_the_lock_writes_nothing_and_releases_it(self) -> None:
        for name, slug, ignore, sabotage, args, code, out in self.UNDER_LOCK:
            with self.subTest(name):
                r = self.repo(name=slug, ignore=ignore)
                (r / "memory" / sabotage).write_text("a FILE; as `findings` it takes the ledger dir's spot\n")
                ready = self.tmp / f"ready-{slug}"
                before = snapshot(r)
                p = self.add(r, *args, ZUVO_BACKLOG_READY_FILE=str(ready))
                self.assertEqual((p.returncode, p.stdout), (code, out))
                self.assertEqual(len(ready.read_text().splitlines()), 1)    # it did reach the lock
                self.assertEqual(snapshot(r), before)

    def test_visibility_unknown_is_refused_and_releases_the_lock(self) -> None:
        # Defect: git failing to answer is read as "not tracked", publishing an ignored backlog's findings.
        r = self.repo()
        ready = self.tmp / "ready"
        out = io.StringIO()
        with mock.patch.object(fnd, "check_visibility", return_value=fnd.REFUSED_UNKNOWN), \
                mock.patch.dict(os.environ, self.env(ZUVO_BACKLOG_READY_FILE=str(ready)), clear=True), \
                contextlib.redirect_stdout(out):
            code = add.main(["--repo", str(r), *CPLX])
        self.assertEqual((code, out.getvalue()), (3, "REFUSED findings-visibility-unknown\n"))
        self.assertEqual(len(ready.read_text().splitlines()), 1)
        self.assertFalse((r / LOCK_REL).exists())


    def test_ledger_time_is_taken_after_the_lock_is_acquired(self) -> None:
        # Defect: `ts` and the segment are fixed when the lock is REQUESTED, so a writer that waited
        # stamps its line earlier than lines written before it, and the fold orders them wrongly.
        r = self.repo()
        _, _, f_id = self.verdict(self.contend(r, [list(CPLX)], hold=2.5, now="")[0])
        self.assertGreaterEqual(self.folded(r)[0][f_id].fields["ts"], self.released_at)

    def test_fifo_at_the_segment_path_is_refused_not_waited_on(self) -> None:
        # Defect: a FIFO where this call's segment goes blocks the fold for ever, holding the lock.
        r = self.repo()
        findings = r / "memory" / "findings"
        findings.mkdir()
        os.mkfifo(fnd.segment_path(findings, NOW, "feat/x", "t"))
        before = self.backlog(r)
        p = subprocess.run([sys.executable, LAUNCHER, *BUG], cwd=r, env=self.env(), capture_output=True,
                           text=True, timeout=60)
        self.assertEqual((p.returncode, p.stdout), (1, ""))
        self.assertEqual(self.backlog(r), before)

    def test_dry_run_reports_the_unusable_ledger_the_real_run_hits(self) -> None:
        # Defect: --dry-run predicts ACCEPTED where the real call exits 1 on an unusable ledger.
        r = self.repo()
        (r / "memory" / "findings").write_text("a plain FILE in the ledger dir's place\n")
        p = self.add(r, *BUG, "--dry-run")
        self.assertEqual((p.returncode, p.stdout), (1, ""))

    def test_path_git_cannot_answer_for_is_left_out_of_wrote(self) -> None:
        # Defect: a path git gave no ignore answer for is listed in wrote=, so a committing skill stages a
        # file that may be ignored. In-process: no fixture makes `git check-ignore` fail after the write.
        r = self.repo()
        out = io.StringIO()
        unanswered = fnd._GitUnanswered("git: no answer")
        with mock.patch.object(fnd, "check_visibility", return_value=None), \
                mock.patch.object(fnd, "would_be_ignored", side_effect=unanswered), \
                mock.patch.dict(os.environ, self.env(), clear=True), contextlib.redirect_stdout(out):
            code = add.main(["--repo", str(r), *BUG])
        self.assertEqual(code, 0)
        self.assertRegex(out.getvalue(),
                         r"^ACCEPTED backlog B-a-BUG-[0-9a-f]{8} ledger=F-[0-9a-f]{12} wrote=-\n$")
        self.assertEqual(len(self.entries(r, out.getvalue().split()[2])), 1)

    def test_failure_after_the_backlog_write_names_what_was_written(self) -> None:
        # Defect: a ValueError in the ledger append, after backlog.md changed, exits 1 with no wrote=,
        # so the skill neither stages nor reports the changed backlog.
        r = self.repo()
        err = io.StringIO()
        with mock.patch.object(fnd, "append_line", side_effect=ValueError("out-of-schema line")), \
                mock.patch.dict(os.environ, self.env(), clear=True), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = add.main(["--repo", str(r), *BUG])
        self.assertEqual(code, 1)
        self.assertIn("failed after writing: wrote=memory/backlog.md", err.getvalue())

    def test_render_invisible_line_exits_one_writes_nothing_and_releases_the_lock(self) -> None:
        # Defect: a line the parser would not see (RenderInvisible) escapes `_FAILURES` as a traceback, or
        # is written anyway, or leaves the lock held so every later writer times out. In-process with
        # `ent.render` raising: no CLI input reaches it, because `validate` already refuses every value
        # `render` cannot make visible (a fuzz of ~60k rendered findings and ~18k re-opened archive lines
        # found none).
        r = self.repo()
        before = snapshot(r)
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.object(ent, "render", side_effect=ent.RenderInvisible()), \
                mock.patch.dict(os.environ, self.env(), clear=True), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = add.main(["--repo", str(r), *BUG])
        self.assertEqual((code, out.getvalue(), err.getvalue()),
                         (1, "", "backlog-add: RenderInvisible: render-invisible\n"))
        self.assertEqual(snapshot(r), before)
        self.assertFalse((r / LOCK_REL).exists())


class LegacyTextKeysOnSomethingTests(unittest.TestCase):
    """The second lookup's text must always carry a signature — the reason exit 13 may fall through.

    `backlog-add` asks `lookup` twice: by B-id, then — only when that is ABSENT — by the legacy text
    `<where> — <title>`. A cross-model review called it CRITICAL that a NO-SIGNATURE answer (exit 13)
    falls through to filing a new entry instead of refusing. Filing IS the right outcome: a text that
    keys on nothing cannot match an existing entry, and refusing would discard a finding that already
    passed validation, the cited-code check and the bars. But that is only harmless while the answer
    is unreachable here, so this pins the unreachability instead of restating the argument. Every
    degenerate title `validate` still admits, against a file target and against `subject:`/URL
    targets, must leave `normalize_signature` something to key on; if a future `_legacy_text` or a
    looser title rule breaks that, this fails rather than the backlog quietly gaining duplicates.
    """

    TITLES = ("DONE", "FIXED", "CLOSED", "**Closed:**", "~~x~~", "a", ".", "RESOLVED 2026-01-01")
    WHERES = ("src/x.ts:12", "subject:release-process", "https://example.test/path", "example.test")

    def test_every_admitted_title_and_target_still_keys(self) -> None:
        for where in self.WHERES:
            for title in self.TITLES:
                text = f"{where} — {' '.join(title.split())}"
                sig = zb.normalize_signature(text)
                with self.subTest(text=text):
                    self.assertTrue(sig.replace("|", "").strip(),
                                    f"legacy text {text!r} normalises to {sig!r}: the text lookup "
                                    f"would answer NO-SIGNATURE, and the finding would be filed "
                                    f"without ever being compared against an existing entry")


if __name__ == "__main__":
    unittest.main()
