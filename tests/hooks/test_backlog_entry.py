"""scripts/zuvo-home/zuvo_backlog_entry.py — what `backlog-add` writes into memory/backlog.md and how it
bumps a line it wrote before. Every row names the defect it catches: an entry the parser cannot see (it
would be re-filed for ever), a line the bump cannot read back, a bump that edits someone else's text, or a
regression line `verify` flags. The REGRESSION row runs the REAL archiver's `verify` on a fixture; the
lookup wrapper has its own spec, test_backlog_lookup.py.
"""

import dataclasses
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import ModuleType
from typing import Any

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME_DIR = os.path.join(ROOT, "scripts", "zuvo-home")
sys.path.insert(0, HOME_DIR)
import zuvo_backlog_admit as adm  # noqa: E402
import zuvo_backlog_entry as ent  # noqa: E402
import zuvo_backlog_parse as zb  # noqa: E402

ARCHIVER = os.path.join(HOME_DIR, "backlog-archive.py")
FROZEN = os.path.join(ROOT, "tests", "fixtures", "zuvo-backlog-parse-frozen.pysnap")
FID = "F-0123456789ab"
TODAY = "2026-10-14"
BASE = adm.Finding(cls="BUG", conf=85, source="review", title="total is NaN when the cart is empty",
                   file="src/cart.ts", line=42, anchor="const total = sum(cart.items)",
                   evidence="sum([]) returns undefined", fix="default to 0", severity="high")


def load_frozen() -> ModuleType:
    """The pre-heading parser, loaded by path exactly as H10 loads it (not `*.py`, so SourceFileLoader)."""
    spec = importlib.util.spec_from_file_location("frozen_parse", FROZEN,
                                                  loader=SourceFileLoader("frozen_parse", FROZEN))
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FROZEN_ZB = load_frozen()


def finding(**over: Any) -> adm.Finding:
    return dataclasses.replace(BASE, **over)


def line_for(f: adm.Finding, tag: str = "", seen: int = 1) -> tuple[str, str]:
    """(rendered line, its B-id), through the real bars and the real id derivation."""
    d = adm.decide(f, frozenset({42}), False)
    bid = adm.b_id(f, d, adm.fingerprint(f))
    return ent.render(f, d, bid, FID, seen, tag, TODAY), bid


def entries_of(line: str) -> list[tuple[str, str]]:
    return [(e.key, e.status) for e in zb.iter_entries(line, kinds=(zb.KIND_CHECKBOX,))]


def frozen_entries_of(line: str) -> list[tuple[str, str]]:
    return [(e.key, e.status) for e in FROZEN_ZB.iter_entries(line, checkbox_only=True)]


class RenderTests(unittest.TestCase):
    TEXTS = [
        ("a plain finding renders invisible to the parser", {}),
        ("`Map<K> | <V>` in evidence reads as a TEMPLATE line and the entry vanishes",
         {"evidence": "returns Map<K> | <V> instead of a list"}),
        ("`severity: [x]` in the title reads as a TEMPLATE line", {"title": "doc says severity: [x] here"}),
        ("`critical|high|medium` in the fix reads as a TEMPLATE line", {"fix": "map critical|high|medium"}),
        ("`CRITICAL / HIGH` in evidence reads as a TEMPLATE line",
         {"evidence": "band CRITICAL / HIGH wrong"}),
        ("`HIGH/MEDIUM` as the severity value reads as a TEMPLATE line", {"severity": "HIGH/MEDIUM"}),
        ("`severity: [` as the severity value reads as a TEMPLATE line", {"severity": "[x]"}),
        ("`fingerprint | source-task` in evidence reads as a TEMPLATE line",
         {"evidence": "the fingerprint | source-task header leaked"}),
        ("a U+2028 in the title splits the line in two", {"title": "first\u2028second"}),
        ("a title opening with DONE reads as resolved inline", {"title": "DONE flag never cleared"}),
    ]

    def test_rendered_entry_is_exactly_one_open_entry_keyed_by_its_id(self) -> None:
        for name, over in self.TEXTS:
            with self.subTest(name):
                line, bid = line_for(finding(**over))
                self.assertEqual(entries_of(line), [("id:" + bid.lower(), "open")])

    def test_frozen_parser_agrees_the_entry_is_visible(self) -> None:
        # Defect: an entry only TODAY's parser sees — an older ~/.zuvo install would re-file it.
        for name, over in self.TEXTS:
            with self.subTest(name):
                line, bid = line_for(finding(**over))
                self.assertEqual(frozen_entries_of(line), [("id:" + bid.lower(), "open")])

    def test_line_has_the_documented_field_order(self) -> None:
        # Defect: a field order the bump parser and the intake do not expect.
        line, bid = line_for(finding())
        self.assertEqual(line, f"- [ ] {bid} src/cart.ts:42 — [BUG] total is NaN when the cart is empty | "
                               "evidence: sum([]) returns undefined | fix: default to 0 | severity: high | "
                               f"source: review | conf: 85 | seen: 1 | ledger: {FID} | {TODAY}")

    def test_missing_optional_fields_render_as_dash(self) -> None:
        # Defect: an empty field collapses two separators and the own-format bump stops matching.
        line, _ = line_for(finding(evidence=None, fix=None, severity=None))
        self.assertIn("| evidence: - | fix: - | severity: - |", line)
        self.assertIsNotNone(ent.parse_own(line))

    def test_tag_tail_does_not_change_the_key(self) -> None:
        for tag in ("[pr:123]", "[branch:feat/x]"):
            with self.subTest(f"{tag} enters the key and splits one entry in two"):
                line, bid = line_for(finding(), tag=tag)
                self.assertEqual(line, line_for(finding())[0] + " " + tag)
                self.assertEqual(entries_of(line), [("id:" + bid.lower(), "open")])

    DOT_PATHS = [
        ("a leading `./` is kept, so the entry names a site the same finding without it does not",
         "./src/cart.ts"),
        ("only the first of repeated `./` prefixes is stripped (an `if` where the loop must be a `while`)",
         "././src/cart.ts"),
    ]

    def test_leading_dot_slash_is_stripped_from_the_location(self) -> None:
        for name, path in self.DOT_PATHS:
            with self.subTest(name):
                self.assertEqual(line_for(finding(file=path)), line_for(finding()))

    def test_target_line_passes_the_self_check(self) -> None:
        # Defect: a pentest/infra finding (no file) renders an entry the parser cannot see.
        f = finding(cls="SEC", file=None, line=None, anchor=None, target="https://api.example.com/v1/orders",
                    evidence="IDOR on /orders/{id}")
        line, bid = line_for(f)
        self.assertEqual(line, f"- [ ] {bid} https://api.example.com/v1/orders — [SEC] total is NaN when the "
                               "cart is empty | evidence: IDOR on /orders/{id} | fix: default to 0 | "
                               f"severity: high | source: review | conf: 85 | seen: 1 | ledger: {FID} | "
                               f"{TODAY}")
        self.assertTrue(ent.self_check(line, bid))

    def test_unescapable_id_is_refused_as_render_invisible(self) -> None:
        # Defect: an ordinal id keys by content, so `lookup <id>` never finds what was written.
        d = adm.decide(BASE, frozenset({42}), False)
        with self.assertRaises(ent.RenderInvisible) as ctx:
            ent.render(BASE, d, "B-1234", FID, 1, "", TODAY)
        self.assertEqual(str(ctx.exception), "render-invisible")

    def test_source_the_bump_cannot_read_is_refused_as_render_invisible(self) -> None:
        # Defect: a raw `Bad Source` renders a VISIBLE line that `parse_own` cannot read, so the entry is
        # never bumped again and every later sighting is only linked.
        d = adm.decide(BASE, frozenset({42}), False)
        with self.assertRaises(ent.RenderInvisible):
            ent.render(finding(source="Bad Source"), d, adm.b_id(BASE, d, adm.fingerprint(BASE)), FID, 1, "",
                       TODAY)

    SELF_CHECK_FALSE = [
        ("a TEMPLATE-shaped line passes although the parser skips it",
         "- [ ] B-a-BUG-12345678 x critical|high|medium"),
        ("a ticked line passes although it is not an OPEN entry", "- [x] B-a-BUG-12345678 x"),
        ("a line for another id passes", "- [ ] B-b-BUG-12345678 x"),
        ("two entries pass as one", "- [ ] B-a-BUG-12345678 x\n- [ ] B-a-BUG-12345678 y"),
        ("a trailing newline passes although the raw line differs", "- [ ] B-a-BUG-12345678 x\n"),
    ]

    def test_self_check_rejects_lines_that_are_not_exactly_one_open_entry(self) -> None:
        for name, line in self.SELF_CHECK_FALSE:
            with self.subTest(name):
                self.assertFalse(ent.self_check(line, "B-a-BUG-12345678"))

    # The exact message per row: a row raising for ANOTHER row's reason (or a later bar's) still fails.
    BAD_ARGS: list[tuple[str, dict[str, Any], str]] = [
        ("a non-F-id ledger link breaks the own-format bump", {"f_id": "F-xyz"}, "not an F-id: 'F-xyz'"),
        ("seen 0 is written", {"seen": 0}, "seen must be >= 1, got 0"),
        ("a tag outside the intake charset is written", {"tag": "[branch:feat/a+b]"},
         "not a [pr:N] / [branch:name] tag: '[branch:feat/a+b]'"),
        ("an impossible date is written", {"today": "2026-02-31"}, "not a date: '2026-02-31'"),
        ("a malformed confidence renders `conf: None`, refused only as render-invisible",
         {"f": finding(conf="abc")}, "not a confidence: 'abc'"),
    ]

    def test_render_refuses_bad_arguments_with_their_own_reason(self) -> None:
        d = adm.decide(BASE, frozenset({42}), False)
        bid = adm.b_id(BASE, d, adm.fingerprint(BASE))
        for name, over, message in self.BAD_ARGS:
            args: dict[str, Any] = {"f": BASE, "f_id": FID, "seen": 1, "tag": "", "today": TODAY, **over}
            with self.subTest(name), self.assertRaisesRegex(ValueError, f"^{re.escape(message)}$"):
                ent.render(args["f"], d, bid, args["f_id"], args["seen"], args["tag"], args["today"])


ARCHIVED_SECTION = "Archived from backlog.md on 2026-10-13 (1 completed item moved out)"


def archived_line(sev: str = "high", tail: str = " DONE 2026-10-13",
                  title: str = BASE.title) -> tuple[str, str]:
    """An own-format entry as `archive` leaves it in backlog-done.md: ticked, with its marker appended."""
    own, bid = line_for(finding(severity=sev, title=title), tag="[pr:7]")
    return own.replace("- [ ] ", "- [x] ", 1) + tail, bid


def regression_line(bid: str, tail: str) -> str:
    """The whole re-open line for `archived_line()`'s entry: its severity one band up, its `[pr:7]` gone."""
    return (f"- [ ] {bid} [REGRESSION {TODAY} — closed DONE 2026-10-13, archived in backlog-done.md "
            f'"{ARCHIVED_SECTION}"] src/cart.ts:42 — [BUG] total is NaN when the cart is empty | evidence: '
            "sum([]) returns undefined | fix: default to 0 | severity: critical | source: review | "
            f"conf: 85 | seen: 1 | ledger: {FID} | {TODAY} {tail}")


class RegressionTests(unittest.TestCase):

    def test_regression_has_the_protocol_form(self) -> None:
        # Defect: a re-open line in a shape the protocol (and `verify`'s exemption) does not know.
        archived, bid = archived_line()
        line = ent.render_regression(bid, archived, ARCHIVED_SECTION, "code-audit", 90, "", TODAY)
        self.assertEqual(line, regression_line(bid, "| re-observed by code-audit | conf: 90"))
        self.assertIsNotNone(zb.REOPEN_RE.search(line))
        self.assertTrue(ent.self_check(line, bid))

    BANDS = [
        ("low is not raised to medium", "low", "medium"),
        ("medium is not raised to high", "medium", "high"),
        ("high is not raised to critical", "high", "critical"),
        ("critical overflows past the last band", "critical", "critical"),
        ("an upper-case band loses its case", "HIGH", "CRITICAL"),
        ("an unknown band crashes the regression or is forced onto a real band", "urgent", "urgent"),
    ]

    def test_severity_is_raised_one_band(self) -> None:
        for name, old, new in self.BANDS:
            with self.subTest(name):
                archived, bid = archived_line(sev=old)
                line = ent.render_regression(bid, archived, ARCHIVED_SECTION, "review", 85, "", TODAY)
                self.assertIn(f"| severity: {new} |", line)

    def test_title_mimicking_the_severity_field_is_not_raised(self) -> None:
        # Defect: the title's escaped `\| severity: low`, followed by OUR ` | evidence:` separator, reads as
        # the field, so the title is rewritten as well. (`\| severity: low \|` escaped on BOTH sides
        # cannot match at all, so only a title ENDING in the mimic exercises the escape guard.)
        archived, bid = archived_line(title="badge reads | severity: low")
        line = ent.render_regression(bid, archived, ARCHIVED_SECTION, "review", 85, "", TODAY)
        self.assertIn("badge reads \\| severity: low | evidence:", line)
        self.assertIn("| severity: critical |", line)

    BAD_ARGS: list[tuple[str, dict[str, Any], str]] = [
        ("a source carrying ` | conf: 99` forges the re-open line's confidence",
         {"source": "review | conf: 99"}, "not a source token: 'review | conf: 99'"),
        ("a confidence above 100 is written", {"conf": 101}, "not a confidence: 101"),
        ("a tag outside the intake charset is written", {"tag": "[branch:feat/a+b]"},
         "not a [pr:N] / [branch:name] tag: '[branch:feat/a+b]'"),
        ("an impossible date is written", {"today": "2026-02-31"}, "not a date: '2026-02-31'"),
    ]

    def test_render_regression_refuses_bad_arguments_with_their_own_reason(self) -> None:
        archived, bid = archived_line()
        for name, over, message in self.BAD_ARGS:
            args: dict[str, Any] = {"source": "review", "conf": 85, "tag": "", "today": TODAY, **over}
            with self.subTest(name), self.assertRaisesRegex(ValueError, f"^{re.escape(message)}$"):
                ent.render_regression(bid, archived, ARCHIVED_SECTION, args["source"], args["conf"],
                                      args["tag"], args["today"])

    def test_old_tag_is_replaced_by_the_current_one(self) -> None:
        # Defect: the merged PR's tag survives and the intake tickets a regression still on a branch.
        archived, bid = archived_line()
        line = ent.render_regression(bid, archived, ARCHIVED_SECTION, "review", 85, "[branch:feat/x]", TODAY)
        self.assertEqual(line, regression_line(bid, "| re-observed by review | conf: 85 [branch:feat/x]"))

    def test_bare_tick_is_recorded_as_such(self) -> None:
        # Defect: with no marker, the prose is split at an arbitrary word and half lands in "closed …".
        archived, bid = archived_line(tail="")
        line = ent.render_regression(bid, archived, ARCHIVED_SECTION, "review", 85, "", TODAY)
        self.assertIn(f"[REGRESSION {TODAY} — closed (bare tick), archived in backlog-done.md", line)
        self.assertIn("] src/cart.ts:42 — [BUG] total is NaN", line)

    def test_real_verify_accepts_the_archived_entry_plus_the_reopened_copy(self) -> None:
        # Defect: the re-open the protocol mandates is flagged by `verify` as an id in both files.
        archived, bid = archived_line()
        line = ent.render_regression(bid, archived, ARCHIVED_SECTION, "review", 85, "", TODAY)
        tmp = Path(tempfile.mkdtemp(prefix="entry-verify-")).resolve()
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "memory").mkdir()
        (tmp / "memory" / "backlog.md").write_text("# Backlog\n\n" + line + "\n", encoding="utf-8")
        (tmp / "memory" / "backlog-done.md").write_text(f"## {ARCHIVED_SECTION}\n{archived}\n",
                                                         encoding="utf-8")
        env = {**os.environ, "GIT_CEILING_DIRECTORIES": str(tmp.parent)}
        r = subprocess.run([sys.executable, ARCHIVER, "verify", "--repo", str(tmp)], env=env,
                           capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("declared regression", r.stdout)


class BumpTests(unittest.TestCase):
    def test_own_format_line_is_bumped(self) -> None:
        # Defect: a re-sighting leaves seen/conf/date stale, so the backlog under-reports recurrence.
        line, bid = line_for(finding(conf=82), tag="[pr:5]")
        out = ent.bump(["# Backlog\n", line + "\n"], bid, 90, "code-audit", "2026-10-20")
        assert out is not None
        self.assertEqual(out[0], "# Backlog\n")
        self.assertEqual(out[1], line.replace("source: review | conf: 82 | seen: 1",
                                              "source: review, code-audit | conf: 90 | seen: 2")
                         .replace(TODAY, "2026-10-20") + "\n")

    def test_lower_conf_and_known_source_keep_their_values(self) -> None:
        # Defect: conf drops to the weaker sighting's, or a source is listed twice.
        line, bid = line_for(finding(conf=95))
        out = ent.bump([line], bid, 81, "review", TODAY)
        assert out is not None
        own = ent.parse_own(out[0])
        assert own is not None
        self.assertEqual((own.conf, own.seen, own.sources), (95, 2, ("review",)))

    def test_title_mimicking_a_field_does_not_hijack_it(self) -> None:
        # Defect: `| seen: 9 |` inside the title is read (and rewritten) as the real counter.
        line, bid = line_for(finding(title="counter shows | seen: 9 | twice"))
        out = ent.bump([line], bid, 85, "review", TODAY)
        assert out is not None
        self.assertIn("counter shows \\| seen: 9 \\| twice", out[0])
        self.assertIn("| seen: 2 |", out[0])

    def test_lines_not_in_own_format_are_never_edited(self) -> None:
        archived, bid = archived_line()
        reopened = ent.render_regression(bid, archived, ARCHIVED_SECTION, "review", 85, "", TODAY)
        rows = [
            ("a hand-written legacy line is rewritten", f"- [ ] {bid} src/cart.ts:42 NaN total | conf: 70\n"),
            ("a REOPENED line is re-formatted on its next sighting", reopened + "\n"),
            ("a ticked own-format line is bumped back to life", archived + "\n"),
        ]
        for name, legacy in rows:
            with self.subTest(name):
                lines = ["# Backlog\n", legacy]
                self.assertIsNone(ent.bump(lines, bid, 99, "code-audit", TODAY))
                self.assertEqual(lines, ["# Backlog\n", legacy])

    def test_later_own_format_duplicate_of_a_legacy_definition_is_not_edited(self) -> None:
        # Defect: the bump edits a later duplicate while the lookup answers with the first (legacy)
        # definition, so the entry the backlog shows never records the re-sighting.
        line, bid = line_for(finding())
        lines = [f"- [ ] {bid} src/cart.ts:42 NaN total | conf: 70\n", line + "\n"]
        self.assertIsNone(ent.bump(lines, bid, 99, "code-audit", TODAY))

    def test_bump_of_an_id_no_line_defines_raises(self) -> None:
        # Defect: bumping an id no line defines reads as "legacy" and links to nothing.
        with self.assertRaisesRegex(ValueError, "^no line defines B-cart-BUG-01234567$"):
            ent.bump(["# Backlog\n"], "B-cart-BUG-01234567", 85, "review", TODAY)

    # On a line the bump WOULD rewrite, so a bump that skipped a check writes the bad value into the
    # entry instead of raising (and the exact message rules out the no-such-line error).
    BAD_BUMP = [
        ("an impossible date is written into the bumped line", "2026-02-31", "code-audit", 90,
         "not a date: '2026-02-31'"),
        ("a day in another notation is written into the bumped line", "14.10.2026", "code-audit", 90,
         "not a date: '14.10.2026'"),
        ("a source parse_own cannot read is written, so the entry is never bumped again", TODAY,
         "Review run", 90, "not a source token: 'Review run'"),
        ("a four-digit confidence is written, so parse_own stops reading the line", TODAY, "code-audit",
         1000, "not a confidence: 1000"),
    ]

    def test_bump_refuses_input_its_line_could_not_be_read_back_with(self) -> None:
        line, bid = line_for(finding())
        for name, today, source, conf, message in self.BAD_BUMP:
            with self.subTest(name), self.assertRaisesRegex(ValueError, f"^{re.escape(message)}$"):
                ent.bump([line + "\n"], bid, conf, source, today)


class ParseOwnTests(unittest.TestCase):
    OWN = line_for(finding())[0]
    # Each line is NOT in `render`'s open format; reading it as one lets the bump rewrite it.
    NOT_OWN = [
        ("a hand-written legacy line is read as own-format and rewritten",
         "- [ ] B-cart-BUG-01234567 src/cart.ts:42 NaN total | conf: 70"),
        ("a ticked own-format line is read as an open one", OWN.replace("- [ ] ", "- [x] ", 1)),
        ("a line whose ledger link is not an F-id is read", OWN.replace(FID, "F-xyz", 1)),
        ("a line with text after the date is read, losing that text on the bump", OWN + " trailing note"),
    ]

    def test_lines_not_in_render_format_parse_as_none(self) -> None:
        for name, line in self.NOT_OWN:
            with self.subTest(name):
                self.assertIsNone(ent.parse_own(line))

if __name__ == "__main__":
    unittest.main()
