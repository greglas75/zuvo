"""scripts/zuvo-home/zuvo_backlog_lookup.py — how `backlog-add` asks whether an entry is already known. Every
row names the defect it catches; the one that matters most is a lookup failure read as ABSENT, which
writes a duplicate on every infrastructure hiccup.

The wrapper runs against a FAKE `backlog-archive.py` in a flat temp dir — the `~/.zuvo` layout — except
the contract row, which runs the REAL archiver so its output and `_VERDICT_RES` cannot drift apart.
"""

import os
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME_DIR = os.path.join(ROOT, "scripts", "zuvo-home")
sys.path.insert(0, HOME_DIR)
import zuvo_backlog_lookup as lk  # noqa: E402

ARCHIVER = os.path.join(HOME_DIR, "backlog-archive.py")
FAKE = """import sys
sys.stdout.write({out!r})
sys.stderr.write({err!r})
sys.exit({rc})
"""


class LookupTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="lookup-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def fake(self, out: str, rc: int, err: str = "") -> str:
        """A fake archiver in a flat dir — the `~/.zuvo` layout."""
        path = self.tmp / "backlog-archive.py"
        path.write_text(FAKE.format(out=out, err=err, rc=rc), encoding="utf-8")
        return str(path)

    PARSED = [
        ("OPEN is misread",
         "OPEN id:b-x-bug-12345678 B-x-BUG-12345678 backlog.md:7\n", 10,
         lk.Verdict("open", "id:b-x-bug-12345678", "B-x-BUG-12345678", 7, None, None)),
        ("OPEN with the ALSO ARCHIVED suffix is not parsed",
         "OPEN id:b-x-bug-12345678 B-x-BUG-12345678 backlog.md:7 "
         "(ALSO ARCHIVED backlog-done.md:3 — run verify)\n", 10,
         lk.Verdict("open", "id:b-x-bug-12345678", "B-x-BUG-12345678", 7, None, 3)),
        ("ARCHIVED loses its section heading",
         'ARCHIVED id:b-x-bug-12345678 B-x-BUG-12345678 backlog-done.md:3 section="Archived on 2026-10-01"\n',
         11, lk.Verdict("archived", "id:b-x-bug-12345678", "B-x-BUG-12345678", 3,
                        "Archived on 2026-10-01", None)),
        ("an id-less match keeps the `-` placeholder as its id",
         'ARCHIVED fp:0123456789ab - backlog-done.md:9 section=""\n', 11,
         lk.Verdict("archived", "fp:0123456789ab", None, 9, "", None)),
        ("ABSENT is misread", "ABSENT fp:0123456789ab\n", 0,
         lk.Verdict("absent", "fp:0123456789ab", None, None, None, None)),
    ]

    def test_verdicts_are_parsed(self) -> None:
        for name, out, rc, want in self.PARSED:
            with self.subTest(name):
                self.assertEqual(lk.lookup(str(self.tmp), "B-x-BUG-12345678", archiver=self.fake(out, rc)),
                                 want)

    FAIL_CLOSED = [
        ("rc 1 reads as ABSENT", "", 1),
        ("rc 2 (usage error) reads as ABSENT", "usage: backlog-archive.py\n", 2),
        ("a garbage line reads as ABSENT", "Traceback (most recent call last)\n", 0),
        ("an ABSENT line under the OPEN exit code is trusted", "ABSENT fp:0123456789ab\n", 10),
        ("an OPEN line under exit 0 is trusted", "OPEN id:b-x B-x backlog.md:1\n", 0),
        ("a second stdout line is ignored", "ABSENT fp:0123456789ab\nNOTE something\n", 0),
        ("empty output reads as ABSENT", "", 0),
    ]

    def test_failures_raise_lookup_failed_never_absent(self) -> None:
        for name, out, rc in self.FAIL_CLOSED:
            # The rc in the message: a refusal that names another exit code misleads whoever triages it.
            want = f"^lookup gave rc={rc} and an unparseable answer: "
            with self.subTest(name), self.assertRaisesRegex(lk.LookupFailed, want):
                lk.lookup(str(self.tmp), "B-x-BUG-12345678", archiver=self.fake(out, rc))

    def test_failure_message_keeps_the_archivers_traceback(self) -> None:
        # Defect: the archiver's stderr is dropped, so a crashed lookup says only "rc=1" and nobody can
        # tell a broken install from a corrupt backlog.
        err = "Traceback (most recent call last):\n" + "  frame\n" * 60 + "KeyError: 'section'\n"
        with self.assertRaises(lk.LookupFailed) as ctx:
            lk.lookup(str(self.tmp), "B-x", archiver=self.fake("", 1, err))
        self.assertIn("KeyError: 'section'", str(ctx.exception))

    def test_timeout_raises_lookup_failed(self) -> None:
        # Defect: a hung archiver holds the backlog lock for ever, or its silence reads as ABSENT.
        # A REAL hang, not a stubbed TimeoutExpired: a stub would pass with `timeout=` dropped from the
        # subprocess call. No upper bound on the elapsed time is asserted; the sleep is 60x the timeout.
        path = self.tmp / "backlog-archive.py"
        path.write_text("import time\ntime.sleep(30)\n", encoding="utf-8")
        with self.assertRaisesRegex(lk.LookupFailed, r"^lookup timed out after 0\.5s$"):
            lk.lookup(str(self.tmp), "B-x", archiver=str(path), timeout=0.5)

    def test_interpreter_that_cannot_start_raises_lookup_failed(self) -> None:
        # Defect: an OSError from exec escapes as a traceback instead of the CLI's exit-1 refusal.
        with mock.patch.object(sys, "executable", str(self.tmp / "no-python")), \
                self.assertRaisesRegex(lk.LookupFailed, "^lookup could not start: "):
            lk.lookup(str(self.tmp), "B-x", archiver=self.fake("ABSENT fp:0123456789ab\n", 0))

    def test_missing_archiver_raises_lookup_failed(self) -> None:
        # Defect: an incomplete install answers ABSENT and every finding is filed again.
        absent = str(self.tmp / "absent.py")
        want = f"backlog-archive.py not found (install incomplete): {absent}"
        with self.assertRaisesRegex(lk.LookupFailed, f"^{re.escape(want)}$"):
            lk.lookup(str(self.tmp), "B-x", archiver=absent)

    def test_query_is_passed_after_double_dash(self) -> None:
        # Defect: a text query starting with `-` is parsed by the archiver as an option (rc 2).
        path = self.tmp / "backlog-archive.py"
        path.write_text("import sys\nprint('ABSENT fp:0123456789ab' if sys.argv[1:] == "
                        f"['lookup', '--repo', {str(self.tmp)!r}, '--', '-x — t'] else 'argv')\n",
                        encoding="utf-8")
        self.assertEqual(lk.lookup(str(self.tmp), "-x — t", archiver=str(path)).status, "absent")


SECTION = "Archived from backlog.md on 2026-10-13 (1 completed item moved out)"


class RealArchiverContractTests(unittest.TestCase):
    """The REAL `backlog-archive.py lookup` on a temp repo, parsed by the real wrapper."""

    CASES = [
        ("OPEN", "B-cart-BUG-0123abcd",
         lk.Verdict("open", "id:b-cart-bug-0123abcd", "B-cart-BUG-0123abcd", 3, None, None)),
        ("ARCHIVED", "B-old-BUG-89abcdef",
         lk.Verdict("archived", "id:b-old-bug-89abcdef", "B-old-BUG-89abcdef", 2, SECTION, None)),
        ("ABSENT", "B-none-BUG-00000000",
         lk.Verdict("absent", "id:b-none-bug-00000000", None, None, None, None)),
        ("OPEN with the ALSO ARCHIVED suffix", "B-both-BUG-11111111",
         lk.Verdict("open", "id:b-both-bug-11111111", "B-both-BUG-11111111", 4, None, 3)),
    ]

    def test_real_archiver_output_matches_the_verdict_grammar(self) -> None:
        # Defect: format drift between `cmd_lookup`'s print statements and `_VERDICT_RES` — every real
        # lookup then raises LookupFailed (no entry can be filed) or, worse, parses into the wrong field.
        tmp = Path(tempfile.mkdtemp(prefix="lookup-real-")).resolve()
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "memory").mkdir()
        (tmp / "memory" / "backlog.md").write_text(
            "# Backlog\n\n- [ ] B-cart-BUG-0123abcd src/cart.ts:42 — [BUG] total is NaN\n"
            "- [ ] B-both-BUG-11111111 src/both.ts:1 — [BUG] open and archived\n", encoding="utf-8")
        (tmp / "memory" / "backlog-done.md").write_text(
            f"## {SECTION}\n- [x] B-old-BUG-89abcdef src/old.ts:1 — [BUG] stale cache DONE 2026-10-13\n"
            "- [x] B-both-BUG-11111111 src/both.ts:1 — [BUG] open and archived DONE 2026-10-13\n",
            encoding="utf-8")
        with mock.patch.dict(os.environ, {"GIT_CEILING_DIRECTORIES": str(tmp.parent)}):
            for name, query, want in self.CASES:
                with self.subTest(f"{name} from the real archiver is not parsed as {name}"):
                    self.assertEqual(lk.lookup(str(tmp), query, archiver=ARCHIVER), want)


class ArchiverPathTests(unittest.TestCase):
    def setUp(self) -> None:
        tmp = Path(tempfile.mkdtemp(prefix="lookup-path-")).resolve()
        self.addCleanup(shutil.rmtree, tmp, True)
        self.here, self.home = tmp / "here", tmp / "home"
        (self.home / ".zuvo").mkdir(parents=True)
        self.here.mkdir()
        self.zuvo_copy = self.home / ".zuvo" / "backlog-archive.py"

    def test_copy_beside_the_module_wins(self) -> None:
        # Defect: the ~/.zuvo copy (another install's) shadows the archiver shipped with this module.
        (self.here / "backlog-archive.py").write_text("", encoding="utf-8")
        self.zuvo_copy.write_text("", encoding="utf-8")
        self.assertEqual(lk.archiver_path(here=str(self.here), home=str(self.home)),
                         str(self.here / "backlog-archive.py"))

    def test_zuvo_home_is_the_fallback(self) -> None:
        # Defect: a module imported from the repo checkout cannot find the installed archiver.
        self.zuvo_copy.write_text("", encoding="utf-8")
        self.assertEqual(lk.archiver_path(here=str(self.here), home=str(self.home)), str(self.zuvo_copy))

    def test_no_archiver_resolves_to_none(self) -> None:
        # Defect: a path that does not exist is handed to the subprocess and its failure misread.
        self.assertIsNone(lk.archiver_path(here=str(self.here), home=str(self.home)))

    def test_repo_layout_finds_the_real_archiver(self) -> None:
        # Defect: the default resolution misses the archiver shipped beside the module.
        self.assertEqual(lk.archiver_path(), os.path.realpath(ARCHIVER))


if __name__ == "__main__":
    unittest.main()
