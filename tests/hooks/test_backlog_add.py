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
import threading
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
sys.path.insert(0, os.path.join(ROOT, "tests", "lib"))
import zuvo_backlog_add as add  # noqa: E402
import zuvo_backlog_dedup as dd  # noqa: E402
import zuvo_backlog_entry as ent  # noqa: E402
import zuvo_backlog_findings as fnd  # noqa: E402
import zuvo_backlog_io as zio  # noqa: E402
import zuvo_backlog_parse as zb  # noqa: E402
from rerank_stub import RerankStub  # noqa: E402

ANCHOR = "if total > limit:"
SOURCE = "a = 1\nb = 2\nif total > limit:\n    return total - limit\n"
NOW = "2026-10-13T10:00:00+00:00"
# A developer's OpenRouter key would send these specs' findings to the paid rerank API, and the rest
# would move its thresholds, its target or the opt-in bump under them.
RERANK_SCRUB = ("OPENROUTER_API_KEY", "ZUVO_OR_KEY_FILE", "ZUVO_OPENROUTER_BASE_URL",
                "ZUVO_BACKLOG_DEDUP_BUMP", "NO_PROXY", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "http_proxy",
                "https_proxy", "ALL_PROXY", "all_proxy")
SCRUB_PREFIXES = ("ZUVO_RERANK", "ZUVO_BACKLOG_DUP")
# Inherited from a developer shell or a git hook, each would change what the launcher (or the fixture's
# own git) acts on.
SCRUB = ("ZUVO_BACKLOG_PR", "ZUVO_BACKLOG_ADMIT", "ZUVO_DEFAULT_BRANCH", "ZUVO_LOCK_WAIT",
         "ZUVO_BACKLOG_READY_FILE", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
         "GIT_OBJECT_DIRECTORY", "GIT_PREFIX", "GIT_CEILING_DIRECTORIES", *RERANK_SCRUB)
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
    env = {k: v for k, v in os.environ.items() if k not in SCRUB and not k.startswith(SCRUB_PREFIXES)}
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
                   ZUVO_RERANK="0")
        env.update(extra)
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

    def flat(self, drop: str = "", fake_archiver: str = "", name: str = "flat") -> str:
        """The launcher and its modules in ONE directory — the ~/.zuvo layout install_zuvo_home makes,
        rerank client included, so a stub-backed case does not silently run the no-client path."""
        d = self.tmp / name
        d.mkdir()
        rerank = [*glob.glob(os.path.join(HOME_DIR, "zuvo_rerank*.py")),
                  os.path.join(HOME_DIR, "zuvo_bm25.py")]
        for src in [LAUNCHER, ARCHIVER, *glob.glob(os.path.join(HOME_DIR, "zuvo_backlog_*.py")), *rerank]:
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

    def test_unresolvable_branch_keeps_non_sec_in_the_ledger_and_files_sec_untagged(self) -> None:
        r = self.repo(branch="feat/a+b")
        for name, cls, want in self.UNTAGGABLE:
            with self.subTest(name):
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


FIXTURE_PATH = Path(ROOT) / "tests" / "fixtures" / "rerank" / "backlog" / "open.md"
A3 = "B-20261005-CP-R-A3"
TEST_KEY = "test-key-not-a-real-credential"
# The same defect as BUG one line down: a different anchor, so a different F- fingerprint and B-id.
BUG2 = tuple(with_args(BUG, "--line", "4", "--anchor", "return total - limit", "--title",
                       "limit check misses the equal case"))
FSTR = tuple(with_args(BUG, "--title", "f-strings ignored by the tokenize fallback"))
DUP_TAIL = "| ledger: {f} | possible-dup-of: {b} ({band}) | 2026-10-13 [branch:feat/x]"
# The launcher's own work on a loaded host, on top of the rerank timeout (dd.TIMEOUT_S).
TIMEOUT_ALLOWANCE_S = 5.0


class DedupTests(AddCase):
    """The add-time duplicate flag against tests/lib/rerank_stub.py: the API is called before the lock,
    never under it, and every failure leaves today's verdict, exit code and bytes."""

    fixture = ""

    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = FIXTURE_PATH.read_text(encoding="utf-8")

    def setUp(self) -> None:
        super().setUp()
        key = self.home / ".zuvo" / "openrouter.key"
        key.parent.mkdir()
        key.write_text(TEST_KEY + "\n", encoding="utf-8")
        key.chmod(0o600)

    def stub(self, scores: Optional[Dict[str, float]] = None, **kw: Any) -> RerankStub:
        """A stub stopped when the TEST ends; subTest loops open their own with `with`."""
        s = RerankStub(scores, **kw).start()
        self.addCleanup(s.stop)
        return s

    @staticmethod
    def bodies(stub: RerankStub) -> List[Dict[str, Any]]:
        with stub._lock:                      # the handler threads append while the test reads
            return list(stub.bodies)

    def live(self, stub: RerankStub, **extra: str) -> Dict[str, str]:
        """Launcher env with the rerank pass on, pointed at `stub`."""
        return {"ZUVO_RERANK": "1", "ZUVO_RERANK_BASE_URL": stub.base_url, "NO_PROXY": "127.0.0.1",
                "no_proxy": "127.0.0.1", "TZ": "UTC", **extra}

    def on(self, stub: RerankStub, repo: Path, *args: str, launcher: str = LAUNCHER,
           **extra: str) -> "subprocess.CompletedProcess[str]":
        """Run the launcher with the rerank pass on against `stub`."""
        env = self.env(**self.live(stub, **extra))
        return subprocess.run([sys.executable, launcher, *args], cwd=repo, env=env, capture_output=True,
                              text=True, timeout=180)

    def inproc(self, repo: Path, *args: str, **extra: str) -> "subprocess.CompletedProcess[str]":
        """`add.main` in this process, so a test can replace a dedup function. A usage error's SystemExit
        becomes the return code, as it would be for the launcher."""
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, self.env(**extra), clear=True), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(err):
            try:
                code = add.main(["--repo", str(repo), *args])
            except SystemExit as exc:
                code = exc.code if isinstance(exc.code, int) else 1
        return subprocess.CompletedProcess([], code, out.getvalue(), err.getvalue())

    def digest_of(self, repo: Path, b_id: str) -> str:
        """The digest `candidates` would record for `b_id` in this repo's backlog."""
        body = next((e.body for e in dd.load((self.backlog(repo),)) if e.ident == b_id), None)
        self.assertIsNotNone(body, f"{b_id} is not in the backlog")
        return dd.digest(body or "")

    def first(self, r: Path, *args: str) -> str:
        """File BUG (or `args`) with the rerank pass off; its B-id."""
        p = self.add(r, *(args or BUG), TZ="UTC")
        self.assertEqual((p.returncode, self.verdict(p)[0]), (0, "ACCEPTED"), p.stderr)
        return self.verdict(p)[1]

    BANDS = [
        ("a strong score is not flagged strong", 0.81, "strong"),
        ("a weak score is not flagged weak", 0.60, "weak"),
    ]

    def test_scored_duplicate_is_appended_with_its_band_and_the_candidate_is_untouched(self) -> None:
        for name, score, band in self.BANDS:
            with self.subTest(name), RerankStub({"off-by-one at the limit": score}) as stub:
                r = self.repo(name=band)
                b1 = self.first(r)
                before = self.entries(r, b1)
                p = self.on(stub, r, *BUG2)
                self.assertEqual(p.returncode, 0, p.stderr)
                kind, b2, f2 = self.verdict(p)
                self.assertEqual(kind, "ACCEPTED")
                self.assertNotEqual(b2, b1)
                self.assertTrue(self.entries(r, b2)[0].endswith(DUP_TAIL.format(f=f2, b=b1, band=band)))
                self.assertIn("| seen: 1 |", self.entries(r, b2)[0])
                self.assertEqual(self.entries(r, b1), before)

    def test_score_under_the_weak_band_files_an_unflagged_entry(self) -> None:
        # Defect: every add names its nearest neighbour, however unrelated, as a possible duplicate.
        r = self.repo()
        self.first(r)
        stub = self.stub({"off-by-one at the limit": 0.54})
        p = self.on(stub, r, *BUG2)
        self.assertEqual((p.returncode, self.verdict(p)[0], stub.requests), (0, "ACCEPTED", 1))
        self.assertNotIn("possible-dup-of", self.backlog(r))

    def test_opt_in_bump_merges_a_strong_duplicate(self) -> None:
        # Defect: ZUVO_BACKLOG_DEDUP_BUMP=1 is ignored, or the bump leaves a second entry behind.
        r = self.repo()
        b1 = self.first(r)
        p = self.on(self.stub({"off-by-one at the limit": 0.81}), r, *BUG2, ZUVO_BACKLOG_DEDUP_BUMP="1")
        self.assertEqual(p.returncode, 0, p.stderr)
        kind, b, f2 = self.verdict(p)
        self.assertEqual((kind, b), ("BUMPED", b1))
        self.assertIn("| seen: 2 |", self.entries(r, b1)[0])
        self.assertEqual(len(re.findall(r"^- \[ \] B-", self.backlog(r), re.M)), 1)
        self.assertEqual(self.folded(r)[0][f2].fields["backlog"], b1)

    def test_bumped_finding_seen_again_resolves_to_the_entry_it_was_merged_into(self) -> None:
        # Defect: the merged finding's ledger record names no entry, so its exact repeat is filed as a
        # new entry after all and the opt-in merge only postponed the duplicate.
        r = self.repo()
        b1 = self.first(r)
        stub = self.stub({"off-by-one at the limit": 0.81})
        merged = self.on(stub, r, *BUG2, ZUVO_BACKLOG_DEDUP_BUMP="1")
        self.assertEqual(self.verdict(merged)[:2], ("BUMPED", b1))
        p = self.add(r, *BUG2, TZ="UTC")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.verdict(p)[:2], ("BUMPED", b1))
        self.assertIn("| seen: 3 |", self.entries(r, b1)[0])
        self.assertEqual(len(re.findall(r"^- \[ \] B-", self.backlog(r), re.M)), 1)

    def test_opt_in_bump_never_merges_a_weak_duplicate(self) -> None:
        # Defect: the bump fires on a weak score, hiding a distinct finding inside another entry.
        r = self.repo()
        b1 = self.first(r)
        p = self.on(self.stub({"off-by-one at the limit": 0.60}), r, *BUG2, ZUVO_BACKLOG_DEDUP_BUMP="1")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.verdict(p)[0], "ACCEPTED")
        self.assertIn("| seen: 1 |", self.entries(r, b1)[0])

    def test_opt_in_bump_never_merges_into_an_entry_on_another_file(self) -> None:
        # Defect: the merge keeps only the old entry's text, so a finding in another file loses its own
        # location, evidence and fix inside a neighbour that merely reads alike.
        r = self.repo()
        (r / "src" / "b.py").write_text(SOURCE, encoding="utf-8")
        git(r, "add", "src/b.py")
        git(r, "commit", "-qm", "b")
        b1 = self.first(r, *with_args(BUG, "--file", "src/b.py"))
        p = self.on(self.stub({"off-by-one at the limit": 0.81}), r, *BUG2, ZUVO_BACKLOG_DEDUP_BUMP="1")
        self.assertEqual(p.returncode, 0, p.stderr)
        kind, b2, f2 = self.verdict(p)
        self.assertEqual(kind, "ACCEPTED")
        self.assertTrue(self.entries(r, b2)[0].endswith(DUP_TAIL.format(f=f2, b=b1, band="strong")))
        self.assertIn("| seen: 1 |", self.entries(r, b1)[0])

    def test_opt_in_bump_never_merges_a_finding_without_a_file(self) -> None:
        # Defect: a target-only finding has no file to compare, and "" matches an entry whose location
        # has no colon, so it is merged into a neighbour and loses its own subject.
        r = self.repo()
        sec = ("--class", "SEC", "--conf", "80", "--target", "subject:token-in-log", "--source", "review")
        _, b1, _ = self.verdict(self.add(r, *sec, "--title", "token written to the debug log", TZ="UTC"))
        p = self.on(self.stub({"token": 0.81}), r, *sec, "--title", "bearer token printed in debug output",
                    ZUVO_BACKLOG_DEDUP_BUMP="1")
        self.assertEqual(p.returncode, 0, p.stderr)
        kind, b2, f2 = self.verdict(p)
        self.assertEqual(kind, "ACCEPTED")
        self.assertTrue(self.entries(r, b2)[0].endswith(DUP_TAIL.format(f=f2, b=b1, band="strong")))
        self.assertIn("| seen: 1 |", self.entries(r, b1)[0])

    def test_archived_candidate_is_flagged_and_never_bumped(self) -> None:
        # Defect: the opt-in merge re-opens or edits an archived entry, or drops a true flag naming it.
        r = self.repo()
        b1 = self.first(r)
        path = r / "memory" / "backlog.md"
        path.write_text(self.backlog(r).replace(f"- [ ] {b1} ", f"- [x] {b1} ").rstrip("\n")
                        + " DONE 2026-10-13\n", encoding="utf-8")
        self.assertEqual(self.archive(r, "archive").returncode, 0)
        done = (r / "memory" / "backlog-done.md").read_text(encoding="utf-8")
        p = self.on(self.stub({"off-by-one at the limit": 0.81}), r, *BUG2, ZUVO_BACKLOG_DEDUP_BUMP="1")
        self.assertEqual(p.returncode, 0, p.stderr)
        kind, b2, f2 = self.verdict(p)
        self.assertEqual(kind, "ACCEPTED")
        self.assertTrue(self.entries(r, b2)[0].endswith(DUP_TAIL.format(f=f2, b=b1, band="strong")))
        self.assertEqual((r / "memory" / "backlog-done.md").read_text(encoding="utf-8"), done)

    def test_forced_admission_is_never_redirected_into_another_entry(self) -> None:
        # Defect: a user-requested entry (ZUVO_BACKLOG_ADMIT=1) is bumped into a neighbour instead.
        r = self.repo()
        _, b1, _ = self.verdict(self.add(r, *CPLX, ZUVO_BACKLOG_ADMIT="1", TZ="UTC"))
        cplx2 = with_args(CPLX, "--line", "4", "--title", "nesting is too deep")
        p = self.on(self.stub({"too complex": 0.9}), r, *cplx2, ZUVO_BACKLOG_ADMIT="1",
                    ZUVO_BACKLOG_DEDUP_BUMP="1")
        self.assertEqual(p.returncode, 0, p.stderr)
        kind, b2, _ = self.verdict(p)
        self.assertEqual(kind, "ACCEPTED")
        self.assertNotEqual(b2, b1)
        self.assertIn("| seen: 1 |", self.entries(r, b1)[0])

    FAIL_OPEN: List[Tuple[str, Dict[str, Any]]] = [
        ("an HTTP 500 changes the verdict, the exit code or the bytes", {"status": 500, "body": b"oops"}),
        ("a hung API changes the verdict, the exit code or the bytes, or waits past the timeout",
         {"delay": dd.TIMEOUT_S + 1.0}),
    ]

    def test_api_failure_leaves_todays_verdict_exit_code_and_bytes(self) -> None:
        for i, (name, kw) in enumerate(self.FAIL_OPEN):
            with self.subTest(name), RerankStub({"f-string model": 0.9}, **kw) as stub:
                off = self.repo(name=f"off-{i}", backlog=self.fixture)
                on = self.repo(name=f"on-{i}", backlog=self.fixture)
                want = self.add(off, *FSTR, TZ="UTC")
                started = time.monotonic()
                got = self.on(stub, on, *FSTR)
                elapsed = time.monotonic() - started
                self.assertEqual(stub.requests, 1)
                self.assertEqual(got.returncode, want.returncode, got.stderr)
                self.assertEqual(self.verdict(got), self.verdict(want))
                self.assertEqual(self.backlog(on), self.backlog(off))
                self.assertLessEqual(elapsed, dd.TIMEOUT_S + TIMEOUT_ALLOWANCE_S)

    FAIL_INSIDE: List[Tuple[str, Dict[str, Any]]] = [
        ("the loader raising before the lock escapes as a traceback", {"load": RuntimeError("load")}),
        ("the scorer raising escapes as a traceback", {"candidates": RuntimeError("score")}),
        ("the lock-time check raising escapes as a traceback",
         {"candidates": dd.Candidate("B-x-1", 0.9, "strong", "0" * 64), "confirm": RuntimeError("confirm")}),
    ]

    def test_an_exception_inside_the_duplicate_check_leaves_todays_outcome(self) -> None:
        for i, (name, patches) in enumerate(self.FAIL_INSIDE):
            with self.subTest(name), RerankStub({"off-by-one at the limit": 0.81}) as stub:
                off, on = self.repo(name=f"twin-{i}"), self.repo(name=f"raise-{i}")
                self.first(off)
                self.first(on)
                want = self.inproc(off, *BUG2)
                with contextlib.ExitStack() as stack:
                    mocks = []
                    for attr, value in patches.items():
                        key = "side_effect" if isinstance(value, Exception) else "return_value"
                        mocks.append(stack.enter_context(mock.patch.object(dd, attr, **{key: value})))
                    got = self.inproc(on, *BUG2, **self.live(stub))
                self.assertEqual([m.called for m in mocks], [True] * len(mocks))
                self.assertEqual(got.returncode, want.returncode, got.stderr)
                self.assertEqual(self.verdict(got), self.verdict(want))
                self.assertEqual(self.backlog(on), self.backlog(off))

    def test_the_lock_time_check_runs_only_when_an_entry_is_appended(self) -> None:
        # Defect: the candidate is re-checked (both files re-read and parsed) under the lock even when a
        # legacy entry is bumped and the result is thrown away.
        legacy = "- [ ] src/a.py:4 — limit check misses the equal case\n"
        for name, backlog, verdict, calls in (("a legacy bump still re-checks", legacy, "BUMPED", 0),
                                              ("an append skips the re-check", "", "ACCEPTED", 1)):
            with self.subTest(name):
                r = self.repo(name=verdict.lower(), backlog="# Backlog\n\n" + backlog)
                b1 = self.first(r)
                cand = dd.Candidate(b1, 0.9, "weak", self.digest_of(r, b1))
                with mock.patch.object(dd, "candidates", return_value=cand), \
                        mock.patch.object(dd, "confirm", wraps=dd.confirm) as confirm:
                    p = self.inproc(r, *BUG2)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual((self.verdict(p)[0], confirm.call_count), (verdict, calls))

    def test_the_lock_is_not_held_during_the_network_call(self) -> None:
        # Defect: the rerank runs under the backlog lock, so one slow API call times out every writer
        # queued behind it (ZUVO_LOCK_WAIT), and their findings are lost.
        r = self.repo(backlog=self.fixture)
        release = threading.Event()
        stub = self.stub({"f-string model": 0.9}, hold_until={"alpha-marker": release})
        self.addCleanup(release.set)
        slow = with_args(FSTR, "--title", "alpha-marker f-strings ignored by the tokenize fallback")
        a = subprocess.Popen([sys.executable, LAUNCHER, *slow], cwd=r, env=self.env(**self.live(stub)),
                             text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 30
            while not any("alpha-marker" in b.get("query", "") for b in self.bodies(stub)):
                self.assertIsNone(a.poll(), "A finished without ever calling the API")
                self.assertLess(time.monotonic(), deadline, "A never called the API")
                time.sleep(0.02)
            b = self.on(stub, r, *BUG2, ZUVO_LOCK_WAIT="2")
            a_still_waiting = a.poll() is None
            release.set()
            _, err = a.communicate(timeout=60)
        finally:
            if a.poll() is None:
                a.kill()
                a.communicate()
        self.assertEqual(b.returncode, 0, b.stderr)
        self.assertEqual(self.verdict(b)[0], "ACCEPTED")
        self.assertTrue(a_still_waiting, "B returned after A: this run proves nothing about the lock")
        self.assertEqual(a.returncode, 0, err)

    RACE = [
        ("a candidate whose id changed before the lock is still named",
         lambda t: t.replace(A3, "B-renamed-1"), False),
        ("a candidate rewritten before the lock is still named",
         lambda t: t.replace("no f-string model", "a full f-string model now"), False),
        ("an untouched candidate loses its flag at the lock", lambda t: t, True),
    ]

    def test_candidate_is_rechecked_under_the_lock(self) -> None:
        for i, (name, edit, kept) in enumerate(self.RACE):
            with self.subTest(name), RerankStub({"f-string model": 0.9}) as stub:
                r = self.repo(name=f"race-{i}", backlog=self.fixture)
                ready = self.tmp / f"ready-{i}"
                env = self.env(**self.live(stub, ZUVO_BACKLOG_READY_FILE=str(ready), ZUVO_LOCK_WAIT="60"))
                p = None
                try:
                    with zio.Lock(str(r / "memory")):
                        p = subprocess.Popen([sys.executable, LAUNCHER, *FSTR], cwd=r, env=env, text=True,
                                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        deadline = time.monotonic() + 60
                        while not ready.exists():
                            self.assertLess(time.monotonic(), deadline, "the writer never reached the lock")
                            time.sleep(0.02)
                        path = r / "memory" / "backlog.md"
                        path.write_text(edit(path.read_text(encoding="utf-8")), encoding="utf-8")
                    out, err = p.communicate(timeout=60)
                finally:
                    if p is not None and p.poll() is None:
                        p.kill()
                        p.communicate()
                done = subprocess.CompletedProcess([], p.returncode, out, err)
                self.assertEqual(p.returncode, 0, err)
                self.assertEqual(self.verdict(done)[0], "ACCEPTED")
                self.assertEqual(f"possible-dup-of: {A3} (strong)" in self.backlog(r), kept)

    LEGACY_CANDIDATES = [
        ("a heading candidate is not flagged, or is edited by the bump",
         "### B-heading-1 — off-by-one at the limit when the total equals it\n\nprose\n", "B-heading-1"),
        ("a table-row candidate is not flagged, or is edited by the bump",
         "| ID | Problem | File |\n|---|---|---|\n| B-t-1 | off-by-one at the limit | src/a.py:3 |\n",
         "B-t-1"),
    ]

    def test_heading_and_table_candidates_are_flagged_never_bumped(self) -> None:
        for name, block, cand in self.LEGACY_CANDIDATES:
            with self.subTest(name), RerankStub({"off-by-one at the limit": 0.81}) as stub:
                r = self.repo(name=cand.lower(), backlog="# Backlog\n\n## Open\n\n" + block)
                p = self.on(stub, r, *BUG2, ZUVO_BACKLOG_DEDUP_BUMP="1")
                self.assertEqual(p.returncode, 0, p.stderr)
                kind, b2, f2 = self.verdict(p)
                self.assertEqual(kind, "ACCEPTED")
                tail = DUP_TAIL.format(f=f2, b=cand, band="strong")
                self.assertTrue(self.entries(r, b2)[0].endswith(tail))
                self.assertIn(block, self.backlog(r))

    def test_a_failure_while_checking_the_bump_appends_with_the_flag(self) -> None:
        # Defect: an exception reading the candidate for the opt-in bump escapes as a traceback, so the
        # finding is lost although the flag alone would have filed it.
        r = self.repo()
        b1 = self.first(r)
        cand = dd.Candidate(b1, 0.9, "strong", self.digest_of(r, b1))
        parse_own = ent.parse_own

        def broken(line: str) -> Optional[ent.Own]:
            if line.startswith(f"- [ ] {b1} "):
                raise RuntimeError("parse_own")
            return parse_own(line)

        with mock.patch.object(dd, "candidates", return_value=cand), \
                mock.patch.object(ent, "parse_own", side_effect=broken) as patched:
            p = self.inproc(r, *BUG2, ZUVO_BACKLOG_DEDUP_BUMP="1")
        self.assertTrue(any(c.args[0].startswith(f"- [ ] {b1} ") for c in patched.call_args_list))
        self.assertEqual(p.returncode, 0, p.stderr)
        kind, b2, f2 = self.verdict(p)
        self.assertEqual(kind, "ACCEPTED")
        self.assertTrue(self.entries(r, b2)[0].endswith(DUP_TAIL.format(f=f2, b=b1, band="strong")))
        self.assertIn("| seen: 1 |", self.entries(r, b1)[0])

    def test_dry_run_makes_no_request(self) -> None:
        # Defect: --dry-run, which promises no side effect, sends the finding to the API.
        r = self.repo()
        self.first(r)
        stub = self.stub({"off-by-one at the limit": 0.81})
        p = self.on(stub, r, *BUG2, "--dry-run")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(p.stdout.strip(), "no verdict printed")
        self.assertEqual((p.stdout.split()[0], stub.requests), ("ACCEPTED", 0))

    def test_flagged_entry_seen_again_is_bumped_and_keeps_its_flag(self) -> None:
        # Defect: the field makes the entry unreadable to parse_own, so its own exact repeat is only
        # linked as legacy (never counted), or the archiver's verify rejects the line.
        r = self.repo()
        b1 = self.first(r)
        stub = self.stub({"off-by-one at the limit": 0.81})
        _, b2, _ = self.verdict(self.on(stub, r, *BUG2))
        p = self.on(stub, r, *BUG2)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.verdict(p)[:2], ("BUMPED", b2))
        self.assertNotIn(" legacy ", p.stdout)
        line = self.entries(r, b2)[0]
        self.assertIn("| seen: 2 |", line)
        self.assertIn(f"| possible-dup-of: {b1} (strong) |", line)
        self.assertIsNotNone(ent.parse_own(line))
        self.assertEqual(self.archive(r, "verify").returncode, 0)

    def test_verdict_line_never_carries_the_flag_and_json_does(self) -> None:
        # Defect: the field leaks into the text verdict line (VERDICT_RE, which skills parse, breaks), or
        # --json drops it so a caller cannot report the possible duplicate.
        r, rj = self.repo(name="line"), self.repo(name="json")
        b1 = self.first(r)
        self.first(rj)
        stub = self.stub({"off-by-one at the limit": 0.81})
        line = self.on(stub, r, *BUG2)
        obj = json.loads(self.on(stub, rj, *BUG2, "--json").stdout)
        self.assertEqual(self.verdict(line)[0], "ACCEPTED")
        self.assertNotIn("possible-dup-of", line.stdout)
        self.assertEqual(obj["possible_dup_of"], {"backlog": b1, "band": "strong", "score": 0.81})

    def test_flat_copy_without_the_client_behaves_as_today(self) -> None:
        # Defect: a top-level import of zuvo_rerank breaks every flat/mutant copy built from the
        # zuvo_backlog_*.py glob; and a full flat copy must really reach the client (a control).
        for name, drop, flagged in (("no client", "zuvo_rerank.py", False), ("full copy", "", True)):
            with self.subTest(name), RerankStub({"off-by-one at the limit": 0.81}) as stub:
                r = self.repo(name="flat-" + name.replace(" ", "-"))
                b1 = self.first(r)
                launcher = self.flat(drop=drop, name="bin-" + name.replace(" ", "-"))
                p = self.on(stub, r, *BUG2, launcher=launcher)
                self.assertEqual(p.returncode, 0, p.stderr)
                self.assertEqual(self.verdict(p)[0], "ACCEPTED")
                self.assertEqual((stub.requests, f"possible-dup-of: {b1}" in self.backlog(r)),
                                 (1, True) if flagged else (0, False))

    def test_the_specs_env_carries_no_rerank_setting_from_the_parent(self) -> None:
        # Defect: a developer's key, base URL, thresholds or opt-in bump leak into these specs' launcher
        # env, so they reach the paid API or test other thresholds than the ones they name.
        parent = {k: "from-parent" for k in (*RERANK_SCRUB, "ZUVO_RERANK_BASE_URL", "ZUVO_RERANK_BUDGET_USD",
                                              "ZUVO_BACKLOG_DUP_HIGH", "ZUVO_BACKLOG_DUP_LOW")}
        with mock.patch.dict(os.environ, {**parent, "ZUVO_RERANK": "1"}):
            env = self.env()
        self.assertEqual(env["ZUVO_RERANK"], "0")
        self.assertEqual(sorted(k for k in parent if k in env), [])


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
