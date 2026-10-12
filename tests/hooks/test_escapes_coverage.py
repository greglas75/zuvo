"""scripts/zuvo-home/review-escapes — review coverage of each escape (zuvo_escapes_artifacts,
zuvo_escapes_ledgerjoin, zuvo_escapes_coverage, zuvo_escapes_discover) and the launcher's argument and
summary rules; classification is in test_escapes_classify.py.

Every case runs the helper on a real temporary git repository with fixture memory/reviews/
artifacts, review archives, ledgers and Bill defect files."""

from __future__ import annotations

import datetime as dt
import io
import json
import os
import shutil
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from escapes_testlib import NOW, EscapesTestCase, lines, load_launcher  # noqa: E402
from review_testlib import finding, verdict  # noqa: E402

APP = "apps/api/src/app.py"
OTHER = "apps/api/src/other.py"
BASE = lines("def total(a, b):", "    x = a", "    y = b", "    return x + y", "")
BUGGY = lines("def total(a, b):", "    x = a", "    y = -b  # BUGGY_LINE_TOKEN", "    return x + y", "")
PROJECT = "/Users/someone/DEV/proj"
LABELS = ("flagged-accepted", "flagged-dismissed", "flagged-unjudged", "reviewed", "unreviewed")


def iso(days_ago: float) -> str:
    return (NOW - dt.timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def padded(n: int, body: str) -> str:
    return lines(*(f"# pad {i}" for i in range(n))) + body


class CoverageCase(EscapesTestCase):
    """History: init (60d) → branch feature/a: intro BUGGY at line 3 (20d), tip (19.8d) → merged into
    develop (19d) → fix restores the line (5d). One escape row: APP line 3."""

    def build(self) -> dict[str, str]:
        r = self.repo
        sha = {"init": r.commit("init", {APP: BASE, OTHER: "z = 0\n"}, days_ago=60)}
        r.branch("feature/a")
        sha["intro"] = r.commit("feat: sign", {APP: BUGGY}, days_ago=20)
        sha["tip"] = r.commit("feat: more", {OTHER: "z = 1\n"}, days_ago=19.8)
        r.checkout("develop")
        sha["landing"] = r.merge("feature/a", "Merged in feature/a (pull request #1)", days_ago=19)
        sha["fix"] = r.commit("fix(app): sign", {APP: BASE}, days_ago=5)
        return sha

    def build_squashed(self, base: str = BASE, buggy: str = BUGGY) -> dict[str, str]:
        """feature/b reviewed at commit `reviewed`, then squash-merged (a new sha holding the same
        line) and the branch deleted: the reviewed commit is no longer reachable from develop."""
        r = self.repo
        sha = {"init": r.commit("init", {APP: base}, days_ago=60)}
        r.branch("feature/b")
        sha["reviewed"] = r.commit("feat: sign", {APP: buggy}, days_ago=21)
        r.checkout("develop")
        r.branch("feature/c")
        sha["unrelated"] = r.commit("feat: other", {OTHER: "q = 1\n"}, days_ago=21)
        r.checkout("develop")
        sha["squash"] = r.commit("Merged in feature/b (pull request #2)", {APP: buggy}, days_ago=19)
        r.git("branch", "-D", "feature/b", "feature/c")
        sha["fix"] = r.commit("fix(app): sign", {APP: base}, days_ago=5)
        return sha

    def verdict_of(self, row: dict) -> tuple[bool, str | None, bool]:
        """(reviewed, method, range_unresolved) of `row` against the artifacts on disk, asked of the
        coverage module directly — for rows a real scan cannot produce (a git read failing mid-run)."""
        import zuvo_escapes_artifacts as arts
        import zuvo_escapes_discover as disc
        ref = self.repo.git("rev-parse", "develop")
        v = arts.Reviews(self.repo.path, ref, disc.discover(self.repo.path, "proj")).verdict(row)
        return v.reviewed, v.method, v.range_unresolved

    def archive_dir(self) -> str:
        return os.path.join(self.zuvo, "review-archive", "proj", "reviews")

    def reviews_dir(self, root: str | None = None) -> str:
        return os.path.join(root or self.repo.path, "memory", "reviews")

    def artifact(self, name: str, rng: str, files: str, root: str | None = None, extra: str = "",
                 marker: str = "<!-- zuvo-review -->\n") -> str:
        text = f"{marker}{extra}range: {rng}\nfiles: {files}\nverdict: PASS\n-->\n\nbody\n"
        return self.write(os.path.join(root or self.reviews_dir(), name), text)

    def clear_reviews(self) -> None:
        shutil.rmtree(self.reviews_dir(), ignore_errors=True)

    def ledger(self, *rows: str) -> None:
        self.write_ledger(list(rows))

    def defects(self, *recs: dict, host: str | None = None) -> None:
        base = os.path.join(self.zuvo, "remote", "ryzen", host) if host else self.zuvo
        self.write(os.path.join(base, "bill-data", "defects.jsonl"),
                   "".join(json.dumps(r) + "\n" for r in recs))

    def one_row(self, *argv: str) -> dict:
        rc, out = self.run_main("--json", *argv)
        self.assertEqual(0, rc, out)
        rows = self.rows()
        self.assertEqual(1, len(rows), rows)
        return rows[0]


class ReviewedByAncestryTests(CoverageCase):
    def test_reviewed_follows_the_artifact_range_by_ancestry(self) -> None:
        # bug: a review is credited for a bug its range never contained (intro before base, the fix
        # already in head), a missing head reads as reviewed, or a review tag grants coverage
        s = self.build()
        missing = "f" * 40
        table = [
            ("intro inside base..head", f"{s['init']}..{s['tip']}", APP, (True, "ancestry", False)),
            ("short range shas", f"{s['init'][:7]}..{s['tip'][:7]}", APP, (True, "ancestry", False)),
            ("intro at the base", f"{s['intro']}..{s['tip']}", APP, (False, None, False)),
            ("range already holds the fix", f"{s['init']}..{s['fix']}", APP, (False, None, False)),
            ("file not listed", f"{s['init']}..{s['tip']}", OTHER, (False, None, False)),
            ("head object missing", f"{s['init']}..{missing}", APP, (False, None, True)),
        ]
        for label, rng, files, want in table:
            with self.subTest(label):
                self.clear_reviews()
                self.artifact("a..b-x.md", rng, files)
                row = self.one_row()
                ev = row["coverage_evidence"]
                self.assertEqual(want, (row["reviewed"], ev["method"], ev["range_unresolved"]))

    def test_review_tag_is_evidence_and_grants_nothing(self) -> None:
        # bug: a reviewed/<hash> audit tag on the introducing commit is read as a review of the line
        s = self.build()
        self.repo.git("tag", f"reviewed/{s['intro'][:8]}", s["intro"])
        row = self.one_row()
        self.assertEqual((False, "unreviewed", [f"reviewed/{s['intro'][:8]}"]),
                         (row["reviewed"], row["coverage"], row["coverage_evidence"]["review_tags"]))


class ReviewedByContentTests(CoverageCase):
    def test_rebased_away_range_falls_back_to_the_line_content(self) -> None:
        # bug: every squash-merged review reads as unreviewed because its head never reached develop,
        # or a rebased-away range that never touched the line is credited anyway
        s = self.build_squashed()
        table = [
            ("head holds the line, base does not", f"{s['init']}..{s['reviewed']}", APP, (True, "content")),
            ("head never had the line", f"{s['init']}..{s['unrelated']}", "*", (False, None)),
        ]
        for label, rng, files, want in table:
            with self.subTest(label):
                self.clear_reviews()
                self.artifact("a..b-x.md", rng, files)
                row = self.one_row()
                self.assertEqual(s["squash"], row["intro_sha"])
                self.assertEqual(want, (row["reviewed"], row["coverage_evidence"]["method"]))


    def test_a_later_review_that_moved_the_file_is_not_credited(self) -> None:
        # bug: a refactor reviewed after the bug landed moves the file; every line is new at the new path,
        # so the content fallback credits that review with reviewing a bug it only carried along
        r = self.repo
        r.commit("init", {APP: BASE}, days_ago=60)
        r.commit("Merged in feature/a (pull request #1)", {APP: BUGGY}, days_ago=20)
        before_move = r.git("rev-parse", "HEAD")
        r.branch("feature/move")
        moved = "apps/api/src/moved/app.py"
        tip = r.commit("refactor: move", {APP: None, moved: BUGGY}, days_ago=10)
        r.checkout("develop")
        r.commit("Merged in feature/move (pull request #2)", {APP: None, moved: BUGGY}, days_ago=9)
        r.git("branch", "-D", "feature/move")
        r.commit("fix(app): sign", {moved: BASE}, days_ago=5)
        self.artifact("a..b-move.md", f"{before_move}..{tip}", "*")
        row = self.one_row()
        self.assertEqual((APP, moved, False), (row["intro_file"], row["file"], row["reviewed"]))


class ArtifactSourceTests(CoverageCase):
    def test_artifact_header_rules(self) -> None:
        # bug: the coverage reader disagrees with the push gate on which artifacts count — a marker-less
        # dated report counted, `*` or a spaced comma list missed, a space-separated list split on spaces
        s = self.build()
        rng = f"{s['init']}..{s['tip']}"
        title = "# Review of the sign change\n"
        table = [
            ("marker-less dated report", "2026-09-10-sign.md", APP, "", True, False),
            ("files: *", "a..b-star.md", "*", "<!-- zuvo-review -->\n", False, True),
            ("comma list with spaces", "a..b-list.md", f"{OTHER} ,  {APP}", "<!-- zuvo-review -->\n",
             False, True),
            ("space-separated list", "a..b-spaced.md", f"{OTHER} {APP}", "<!-- zuvo-review -->\n",
             False, False),
            ("marker after a title line", "a..b-titled.md", APP, title + "<!-- zuvo-review -->\n",
             False, True),
        ]
        for label, name, files, marker, bare, want in table:
            with self.subTest(label):
                self.clear_reviews()
                self.artifact(name, rng, files, marker="" if bare else marker)
                self.assertEqual(want, self.one_row()["reviewed"])

    def test_provisional_artifact_is_marked_and_checked_by_its_recorded_blob(self) -> None:
        # bug: an uncommitted-edit review either grants coverage blindly or is dropped without a trace
        s = self.build()
        blob = self.repo.git("rev-parse", f"{s['intro']}:{APP}")
        status = "status: PROVISIONAL\n"
        table = [
            ("recorded blob holds the line", f"blobs: {APP}={blob}\n", (True, True)),
            ("no recorded blob", "", (False, True)),
        ]
        for label, blobs, want in table:
            with self.subTest(label):
                self.clear_reviews()
                self.artifact("a..worktree-x.md", f"{s['init']}..WORKTREE", APP,
                              extra=status + blobs)
                row = self.one_row()
                self.assertEqual(want, (row["reviewed"], row["coverage_evidence"]["provisional"]))

    def test_sources_worktrees_archive_and_remote_copies(self) -> None:
        # bug: a review held only in a linked worktree, the review archive or a remote host's archive
        # copy is invisible, so its escape reads as unreviewed
        s = self.build()
        rng = f"{s['init']}..{s['tip']}"
        wt = os.path.join(self.tmp, "wt")
        self.repo.git("worktree", "add", "-q", wt, "-b", "wt-branch", s["tip"])
        archive = os.path.join(self.zuvo, "review-archive", "proj", "reviews")
        remote = os.path.join(self.zuvo, "remote", "ryzen", "ryzen-dev", "review-archive", "proj", "reviews")
        for label, root in [("linked worktree", self.reviews_dir(wt)), ("archive", archive),
                            ("remote archive copy", remote)]:
            with self.subTest(label):
                for d in (self.reviews_dir(wt), archive, remote):
                    shutil.rmtree(d, ignore_errors=True)
                self.artifact("a..b-x.md", rng, APP, root=root)
                self.assertEqual(True, self.one_row()["reviewed"])

    def test_checkout_copy_beats_the_archive_copy_of_the_same_name(self) -> None:
        # bug: a stale archived copy of an artifact that was since corrected in the checkout still counts
        s = self.build()
        rng = f"{s['init']}..{s['tip']}"
        self.artifact("a..b-x.md", rng, OTHER)
        archive = os.path.join(self.zuvo, "review-archive", "proj", "reviews")
        self.artifact("a..b-x.md", rng, APP, root=archive)
        self.assertEqual(False, self.one_row()["reviewed"])


class CoverageSoundnessTests(CoverageCase):
    """False credit hides an escape: every case here is a review credited for a line it never showed."""

    def test_merge_fix_whose_own_side_is_in_head_is_not_credited(self) -> None:
        # bug: a review of the fix branch itself — its range already shows the bug removed — is credited
        # by ancestry because the fix MERGE commit is not an ancestor of the branch tip it reviewed
        r = self.repo
        init = r.commit("init", {APP: BASE, OTHER: "z = 0\n"}, days_ago=60)
        intro = r.commit("Merged in feature/a (pull request #1)", {APP: BUGGY}, days_ago=20)
        r.branch("fix/sign")
        tip = r.commit("fix(app): sign", {APP: BASE}, days_ago=6)
        r.checkout("develop")
        merge = r.merge("fix/sign", "Merged in fix/sign (pull request #2)", days_ago=5)
        table = [("range ends on the fix branch tip", f"{init}..{tip}", (False, None)),
                 ("range ends at the introducing commit", f"{init}..{intro}", (True, "ancestry"))]
        for label, rng, want in table:
            with self.subTest(label):
                self.clear_reviews()
                self.artifact("a..b-x.md", rng, APP)
                row = self.one_row()
                self.assertEqual(merge, row["fix_sha"])
                self.assertEqual(want, (row["reviewed"], row["coverage_evidence"]["method"]))

    def test_unknown_fix_ancestry_grants_nothing(self) -> None:
        # bug: git failing to say whether the fix is in head (a timeout, a missing object) reads as
        # "the fix is not in head", so the artifact is credited by ancestry
        s = self.build()
        self.artifact("a..b-x.md", f"{s['init']}..{s['tip']}", APP)
        row = self.one_row()
        self.assertEqual(True, row["reviewed"])
        self.assertEqual((False, None, True), self.verdict_of({**row, "fix_sha": "e" * 40}))

    def test_content_needs_a_resolved_base(self) -> None:
        # bug: a squashed review whose base object is gone skips the changed-file check and reads every
        # line of its head as new, so it is credited with a line it may only have carried along
        s = self.build_squashed()
        self.artifact("a..b-x.md", f"{'f' * 40}..{s['reviewed']}", APP)
        row = self.one_row()
        self.assertEqual((False, True), (row["reviewed"], row["coverage_evidence"]["range_unresolved"]))

    def test_content_credits_a_range_that_added_the_file(self) -> None:
        # bug: a squashed review whose range created the file is refused because base has no copy of it
        r = self.repo
        init = r.commit("init", {OTHER: "z = 0\n"}, days_ago=60)
        r.branch("feature/b")
        reviewed = r.commit("feat: app", {APP: BUGGY}, days_ago=21)
        r.checkout("develop")
        r.commit("Merged in feature/b (pull request #2)", {APP: BUGGY}, days_ago=19)
        r.git("branch", "-D", "feature/b")
        r.commit("fix(app): sign", {APP: BASE}, days_ago=5)
        self.artifact("a..b-x.md", f"{init}..{reviewed}", APP)
        row = self.one_row()
        self.assertEqual((True, "content"), (row["reviewed"], row["coverage_evidence"]["method"]))

    def test_provisional_review_must_sit_below_the_introducing_commit(self) -> None:
        # bug: a WORKTREE review of edits on an unrelated base is credited because its recorded blob
        # happens to hold the line and that base does not
        s = self.build_squashed()
        blob = self.repo.git("rev-parse", f"{s['squash']}:{APP}")
        table = [("base below the introducing commit", s["init"], True),
                 ("base on an unrelated branch", s["unrelated"], False)]
        for label, base, want in table:
            with self.subTest(label):
                self.clear_reviews()
                self.artifact("a..worktree-x.md", f"{base}..WORKTREE", APP,
                              extra=f"status: PROVISIONAL\nblobs: {APP}={blob}\n")
                self.assertEqual(want, self.one_row()["reviewed"])

    def test_provisional_blob_must_be_an_object_id(self) -> None:
        # bug: a `blobs:` value such as `<rev>:<path>` is read as a git spec, so the artifact is credited
        # with content it never recorded
        s = self.build()
        self.artifact("a..worktree-x.md", f"{s['init']}..WORKTREE", APP,
                      extra=f"status: PROVISIONAL\nblobs: {APP}={s['intro']}:{APP}\n")
        row = self.one_row()
        self.assertEqual((False, True), (row["reviewed"], row["coverage_evidence"]["provisional"]))

    def test_unparsable_intro_time_still_checks_ancestry(self) -> None:
        # bug: one malformed intro_ts in a row crashes the whole coverage pass with a ValueError
        s = self.build()
        self.artifact("a..b-x.md", f"{s['init']}..{s['tip']}", APP)
        row = self.one_row()
        self.assertEqual((True, "ancestry", False), self.verdict_of({**row, "intro_ts": "yesterday"}))

    def test_landing_time_forms_for_the_content_check(self) -> None:
        # bug: a millisecond or +00:00 landing time crashes the content check, and an unreadable one
        # must grant nothing rather than skip the "head no later than the landing" condition
        s = self.build_squashed()
        self.artifact("a..b-x.md", f"{s['init']}..{s['reviewed']}", APP)
        row = self.one_row()
        landed = row["intro_landing_ts"]
        table = [("as written", landed, (True, "content", False)),
                 ("milliseconds", landed.replace("Z", ".250Z"), (True, "content", False)),
                 ("+00:00", landed.replace("Z", "+00:00"), (True, "content", False)),
                 ("unreadable", "soon", (False, None, False))]
        for label, value, want in table:
            with self.subTest(label):
                self.assertEqual(want, self.verdict_of({**row, "intro_landing_ts": value}))

    def test_utc_timestamp_parser(self) -> None:
        # bug: the coverage and ledger readers disagree on which timestamps they can read, or one
        # crashes on a form the other accepts
        import zuvo_escapes_gitbatch as gb
        table = [("2026-09-11T12:00:00Z", 1789128000), ("2026-09-11T12:00:00.250Z", 1789128000),
                 ("2026-09-11T12:00:00+00:00", 1789128000), ("2026-09-11T12:00:00+0000", 1789128000),
                 (" 2026-09-11T12:00:00Z\n", 1789128000),
                 ("2026-09-11T12:00:00+02:00", None), ("2026-09-11 12:00:00", None),
                 ("2026-13-11T12:00:00Z", None), ("", None), ("soon", None)]
        for text, want in table:
            with self.subTest(text=text):
                self.assertEqual(want, gb.parse_utc(text))

    def test_line_numbers_count_newlines_only(self) -> None:
        # bug: str.splitlines() also breaks at a form feed (and \x85,  , a bare \r), which blame
        # does not count, so the content check compares another line than the one blamed
        base = lines("def total(a, b):", "    x = a  # \x0c sep", "    y = b", "    return x + y", "")
        buggy = base.replace("    y = b", "    y = -b  # BUGGY_LINE_TOKEN")
        s = self.build_squashed(base, buggy)
        self.artifact("a..b-x.md", f"{s['init']}..{s['reviewed']}", APP)
        row = self.one_row()
        self.assertEqual((3, True, "content"),
                         (row["intro_line"], row["reviewed"], row["coverage_evidence"]["method"]))

    def test_unreadable_checkout_copy_does_not_hide_the_archive_copy(self) -> None:
        # bug: an artifact whose checkout copy cannot be opened suppresses its readable archive copy
        if os.geteuid() == 0:
            self.skipTest("root opens a mode-000 file")
        s = self.build()
        rng = f"{s['init']}..{s['tip']}"
        os.chmod(self.artifact("a..b-x.md", rng, APP), 0)
        self.artifact("a..b-x.md", rng, APP, root=self.archive_dir())
        self.assertEqual(True, self.one_row()["reviewed"])

    def test_checkout_copy_without_the_marker_un_marks_the_archive_copy(self) -> None:
        # bug: removing the marker from an artifact in the checkout (a deliberate withdrawal) is undone
        # by its archived copy
        s = self.build()
        rng = f"{s['init']}..{s['tip']}"
        self.artifact("a..b-x.md", rng, APP, marker="")
        self.artifact("a..b-x.md", rng, APP, root=self.archive_dir())
        self.assertEqual(False, self.one_row()["reviewed"])


class LedgerJoinTests(CoverageCase):
    def test_finding_matches_by_project_path_line_and_time(self) -> None:
        # bug: a finding on another project, another file, a far line, before the bug existed or from
        # the fix's own review is joined to the escape (or a real flag is missed across path shapes)
        self.build()
        table = [
            ("abs project, repo path", PROJECT, f"{APP}:3", 19.5, "unjudged"),
            ("bare project", "proj", f"{APP}:3", 19.5, "unjudged"),
            ("linux path, trailing slash", "/home/x/DEV/proj/", f"{APP}:3", 19.5, "unjudged"),
            ("another project", "/Users/someone/DEV/other", f"{APP}:3", 19.5, "none"),
            ("finding path longer", PROJECT, f"/Users/someone/DEV/proj/{APP}:3", 19.5, "unjudged"),
            ("finding path shorter", PROJECT, "src/app.py:3", 19.5, "unjudged"),
            ("unique bare basename", PROJECT, "app.py:3", 19.5, "unjudged"),
            ("partial segment", PROJECT, "i/src/app.py:3", 19.5, "none"),
            ("line + 10", PROJECT, f"{APP}:13", 19.5, "unjudged"),
            ("line + 11", PROJECT, f"{APP}:14", 19.5, "none"),
            ("range cell", PROJECT, f"{APP}:1-2", 19.5, "unjudged"),
            ("no line", PROJECT, APP, 19.5, "none"),
            ("just inside intro - 72h", PROJECT, f"{APP}:3", 22.9, "unjudged"),
            ("before intro - 72h", PROJECT, f"{APP}:3", 23.1, "none"),
            ("the fix's own review", PROJECT, f"{APP}:3", 4.5, "none"),
        ]
        for label, project, file, days, want in table:
            with self.subTest(label):
                self.ledger(finding(iso(days), "r1", "fp-1", file, project))
                row = self.one_row()
                self.assertEqual(want, row["flagged"])

    def test_a_longer_finding_path_must_be_absolute(self) -> None:
        # bug: a relative finding path LONGER than the row's repo path (`x/apps/api/src/app.py`) names
        # another file, yet it is joined because the row's path is a suffix of it
        self.build()
        table = [("relative, longer", f"x/{APP}:3", "none"),
                 ("absolute", f"/home/x/DEV/proj/{APP}:3", "unjudged"),
                 ("absolute, another checkout", f"/home/x/DEV/other/{APP}:3", "none"),
                 ("absolute, another directory", f"/srv/{APP}:3", "none"),
                 ("home-relative", f"~/DEV/proj/{APP}:3", "unjudged"),
                 ("windows drive", "C:\\DEV\\proj\\" + APP.replace("/", "\\") + ":3", "unjudged"),
                 ("same path", f"{APP}:3", "unjudged"),
                 ("shorter", "src/app.py:3", "unjudged")]
        for label, file, want in table:
            with self.subTest(label):
                self.ledger(finding(iso(19.5), "r1", "fp-1", file, PROJECT))
                self.assertEqual(want, self.one_row()["flagged"])

    def test_basename_match_reports_its_kind(self) -> None:
        # bug: a weak bare-basename join is indistinguishable from a path join in the evidence
        self.build()
        self.ledger(finding(iso(19.5), "r1", "fp-1", "app.py:3", PROJECT))
        ev = self.one_row()["coverage_evidence"]
        self.assertEqual(("basename", ["fp-1"]), (ev["match"], ev["findings"]))

    def test_non_unique_basename_does_not_match(self) -> None:
        # bug: `app.py:3` is joined to an escape although the fix touched two different app.py files
        r = self.repo
        web = "apps/web/app.py"
        r.commit("init", {APP: BASE, web: BASE}, days_ago=60)
        r.commit("feat: sign", {APP: BUGGY, web: BUGGY}, days_ago=20)
        r.commit("fix(app): sign", {APP: BASE, web: BASE}, days_ago=5)
        self.ledger(finding(iso(19.5), "r1", "fp-1", "app.py:3", PROJECT))
        rc, out = self.run_main("--json")
        self.assertEqual(0, rc, out)
        self.assertEqual(["none", "none"], [r["flagged"] for r in self.rows()])

    def test_line_window_follows_the_blamed_original_line_when_the_line_moved(self) -> None:
        # bug: a finding made at review time misses the escape because later edits moved the line
        r = self.repo
        r.commit("init", {APP: BASE}, days_ago=60)
        r.commit("feat: sign", {APP: BUGGY}, days_ago=20)
        r.commit("feat: header", {APP: padded(15, BUGGY)}, days_ago=10)
        r.commit("fix(app): sign", {APP: padded(15, BASE)}, days_ago=5)
        table = [("at the introducing commit's line", 3, "unjudged"),
                 ("at the fix parent's line only", 18, "unjudged"),
                 ("near neither", 30, "none")]
        for label, line, want in table:
            with self.subTest(label):
                self.ledger(finding(iso(19.5), "r1", "fp-1", f"{APP}:{line}", PROJECT))
                row = self.one_row()
                self.assertEqual((18, 3, want), (row["line_at_parent"], row["intro_line"], row["flagged"]))

    def test_verdict_resolution(self) -> None:
        # bug: an earlier verdict overrides a later one, a process rejection is overridden by Bill, or
        # Bill's remote verdicts are never read — the flagged class of the escape is then wrong
        self.build()
        hit = finding(iso(19.5), "r1", "fp-1", f"{APP}:3", PROJECT)
        bill = {"ts": iso(18), "project": "/home/x/DEV/proj", "finding_ids": ["fp-1"]}
        table = [
            ("no verdict", [], [], None, "unjudged"),
            ("fixed", [verdict(iso(18), "fp-1", "fixed", PROJECT)], [], None, "accepted"),
            ("deferred", [verdict(iso(18), "fp-1", "deferred", "proj")], [], None, "accepted"),
            ("rejected", [verdict(iso(18), "fp-1", "rejected", PROJECT)], [], None, "dismissed"),
            ("latest ledger verdict wins", [verdict(iso(18), "fp-1", "fixed", PROJECT),
                                            verdict(iso(17), "fp-1", "rejected", PROJECT)], [], None,
             "dismissed"),
            ("Bill real", [], [{**bill, "verdict": "real"}], None, "accepted"),
            ("Bill false positive", [], [{**bill, "verdict": "false_positive"}], None, "dismissed"),
            ("Bill uncertain", [], [{**bill, "verdict": "uncertain"}], None, "unjudged"),
            ("Bill remote copy", [], [{**bill, "verdict": "real"}], "ryzen-dev", "accepted"),
            ("later rejected beats earlier Bill real", [verdict(iso(17), "fp-1", "rejected", PROJECT)],
             [{**bill, "verdict": "real"}], None, "dismissed"),
            ("Bill on another project", [], [{**bill, "project": "/x/other", "verdict": "real"}], None,
             "unjudged"),
            ("unparsable newer Bill time does not win", [],
             [{**bill, "verdict": "real"}, {**bill, "ts": "2026-09-14", "verdict": "false_positive"}], None,
             "accepted"),
            ("newer Bill uncertain keeps an older real", [],
             [{**bill, "verdict": "real"}, {**bill, "ts": iso(17), "verdict": "uncertain"}], None,
             "accepted"),
        ]
        for label, verdicts, bill_recs, host, want in table:
            with self.subTest(label):
                shutil.rmtree(os.path.join(self.zuvo, "bill-data"), ignore_errors=True)
                shutil.rmtree(os.path.join(self.zuvo, "remote"), ignore_errors=True)
                self.ledger(hit, *verdicts)
                if bill_recs:
                    self.defects(*bill_recs, host=host)
                self.assertEqual(want, self.one_row()["flagged"])

    def test_remote_ledger_copy_is_read(self) -> None:
        # bug: findings recorded on the review host never reach the curator's join
        self.build()
        remote = os.path.join(self.zuvo, "remote", "ryzen", "ryzen-dev", "adversarial-findings.log")
        self.write(remote, finding(iso(19.5), "r1", "fp-1", f"{APP}:3", PROJECT) + "\n")
        self.assertEqual("unjudged", self.one_row()["flagged"])

    def test_several_matching_findings_take_the_strongest_verdict(self) -> None:
        # bug: one dismissed finding hides that another flag on the same line was accepted
        self.build()
        self.ledger(finding(iso(19.5), "r1", "fp-1", f"{APP}:3", PROJECT),
                    finding(iso(19.4), "r2", "fp-2", f"{APP}:4", PROJECT),
                    finding(iso(19.3), "r3", "fp-3", f"{APP}:2", PROJECT),
                    verdict(iso(18), "fp-1", "rejected", PROJECT),
                    verdict(iso(18), "fp-2", "fixed", PROJECT))
        row = self.one_row()
        self.assertEqual(("accepted", ["fp-2", "fp-1", "fp-3"]),  # the deciding finding first
                         (row["flagged"], row["coverage_evidence"]["findings"]))

    def test_millisecond_and_offset_ledger_times_are_read(self) -> None:
        # bug: a finding stamped with fractional seconds or `+00:00` is silently dropped from the join
        self.build()
        for label, ts in (("milliseconds", iso(19.5).replace("Z", ".250Z")),
                          ("+00:00", iso(19.5).replace("Z", "+00:00"))):
            with self.subTest(label):
                self.ledger(finding(ts, "r1", "fp-1", f"{APP}:3", PROJECT))
                self.assertEqual("unjudged", self.one_row()["flagged"])

    def test_ledger_verdict_outside_the_join_mapping_is_ignored(self) -> None:
        # bug: a verdict name the ledger accepts but this join has no mapping for crashes the run with a
        # KeyError, or (as the latest verdict) hides the older one the join understands
        import zuvo_review_ledger as ledger
        self.build()
        self.ledger(finding(iso(19.5), "r1", "fp-1", f"{APP}:3", PROJECT),
                    verdict(iso(18), "fp-1", "fixed", PROJECT),
                    verdict(iso(17), "fp-1", "superseded", PROJECT))
        with mock.patch.object(ledger, "VERDICTS", ledger.VERDICTS | {"superseded"}):
            self.assertEqual("accepted", self.one_row()["flagged"])

    def test_long_lived_fix_branch_window_ends_at_its_first_commit_after_the_intro(self) -> None:
        # bug: a fix branch opened before the bug existed ends the window at its oldest commit, which
        # predates the introducing commit, so no finding can ever flag the escape
        r = self.repo
        r.commit("init", {APP: BASE, OTHER: "z = 0\n"}, days_ago=60)
        r.branch("fix/sign")
        r.commit("docs: plan", {"docs/plan.md": "plan\n"}, days_ago=30)
        r.checkout("develop")
        r.commit("Merged in feature/a (pull request #1)", {APP: BUGGY}, days_ago=20)
        r.checkout("fix/sign")
        r.merge("develop", "Merge branch 'develop' into fix/sign", days_ago=8)
        r.commit("fix(app): sign", {APP: BASE}, days_ago=6)
        r.checkout("develop")
        merge = r.merge("fix/sign", "Merged in fix/sign (pull request #2)", days_ago=5)
        self.ledger(finding(iso(19.5), "r1", "fp-1", f"{APP}:3", PROJECT))
        row = self.one_row()
        self.assertEqual((merge, "unjudged"), (row["fix_sha"], row["flagged"]))

    def test_unreadable_fix_window_leaves_the_row_unflagged_and_counted(self) -> None:
        # bug: one fix whose commits git cannot list aborts the whole coverage pass (exit 2, nothing
        # written) instead of costing that one row its flag
        import zuvo_escapes_ledgerjoin as lj
        self.build()
        self.ledger(finding(iso(19.5), "r1", "fp-1", f"{APP}:3", PROJECT))
        row = self.one_row()
        join = lj.Join(self.repo.path, "proj", 10)
        flag = join.flag({**row, "fix_sha": "e" * 40})
        self.assertEqual(("none", 1), (flag.flagged, join.unknown))

    def test_evidence_lists_the_deciding_finding_first(self) -> None:
        # bug: the evidence keeps the first five fingerprints by name, so the one accepted finding that
        # made the escape flagged-accepted is missing from it
        self.build()
        fps = [f"fp-{c}" for c in "abcdef"]
        self.ledger(*(finding(iso(19.5), "r1", fp, f"{APP}:3", PROJECT) for fp in fps),
                    verdict(iso(18), "fp-f", "fixed", PROJECT))
        row = self.one_row()
        found = row["coverage_evidence"]["findings"]
        self.assertEqual(("accepted", "fp-f", 5), (row["flagged"], found[0], len(found)))

    def test_unreadable_ledger_is_an_error_not_an_unflagged_run(self) -> None:
        # bug: a ledger that cannot be read looks like a ledger with no findings: every escape unflagged
        self.build()
        os.makedirs(os.path.join(self.zuvo, "adversarial-findings.log"))
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            rc, _ = self.run_main("--json")
        self.assertEqual(2, rc)
        self.assertIn("review-escapes: error:", err.getvalue())


class LabelTests(CoverageCase):
    def test_label_precedence(self) -> None:
        # bug: a reviewed-and-flagged escape is reported as merely reviewed, hiding a dismissed flag
        import zuvo_escapes_coverage as cov
        table = [
            (True, "none", "reviewed"),
            (False, "none", "unreviewed"),
            (True, "dismissed", "flagged-dismissed"),
            (False, "accepted", "flagged-accepted"),
            (True, "unjudged", "flagged-unjudged"),
        ]
        for reviewed, flagged, want in table:
            with self.subTest(reviewed=reviewed, flagged=flagged):
                self.assertEqual(want, cov.label(reviewed, flagged))

    def test_summary_counts_labels_per_row_and_per_pair(self) -> None:
        # bug: coverage is only counted per line, so one large fix outweighs many small escapes
        r = self.repo
        r.commit("init", {APP: BASE, OTHER: BASE}, days_ago=60)
        r.commit("feat: sign", {APP: lines("a1", "a2", "a3")}, days_ago=20)
        r.commit("feat: other", {OTHER: BUGGY}, days_ago=19)
        r.commit("fix(app): both", {APP: BASE, OTHER: BASE}, days_ago=5)
        self.ledger(finding(iso(19.5), "r1", "fp-1", f"{APP}:1", PROJECT))
        s = self.summary()
        rows = {k: v for k, v in s["coverage"]["rows"].items() if v}
        pairs = {k: v for k, v in s["coverage"]["pairs"].items() if v}
        self.assertEqual(({"flagged-unjudged": 3, "unreviewed": 1}, {"flagged-unjudged": 1, "unreviewed": 1}),
                         (rows, pairs))
        self.assertEqual(set(LABELS), set(s["coverage"]["rows"]))

    def test_every_stored_row_is_annotated_on_every_run(self) -> None:
        # bug: only this run's scan is annotated, so a row whose fix fell out of --since never gets coverage
        # and a row keeps a stale flag after a finding on it was judged
        s = self.build()
        self.summary()
        [row] = self.rows()
        stripped = {k: v for k, v in row.items() if k not in ("coverage", "coverage_evidence", "flagged",
                                                              "reviewed")}
        self.write(self.store, json.dumps(stripped) + "\n")
        self.artifact("a..b-x.md", f"{s['init']}..{s['tip']}", APP)
        self.ledger(finding(iso(19.5), "r1", "fp-1", f"{APP}:3", PROJECT),
                    verdict(iso(18), "fp-1", "fixed", PROJECT))
        out = self.summary("--since", "2d")  # the fix (5 days ago) is outside the scan window
        [after] = self.rows()
        self.assertEqual((0, "flagged-accepted", True, "store", 1),
                         (out["escapes"], after["coverage"], after["reviewed"], out["coverage"]["scope"],
                          out["coverage"]["rows"]["flagged-accepted"]))

    def test_every_stored_row_carries_a_label_and_a_rerun_is_byte_identical(self) -> None:
        # bug: coverage makes the store depend on run order, so an unchanged history rewrites the file
        s = self.build()
        self.artifact("a..b-x.md", f"{s['init']}..{s['tip']}", APP)
        self.ledger(finding(iso(19.5), "r1", "fp-1", f"{APP}:3", PROJECT))
        self.summary()
        with open(self.store, "rb") as f:
            first = f.read()
        self.summary()
        with open(self.store, "rb") as f:
            self.assertEqual(first, f.read())
        self.assertEqual(["flagged-unjudged"], [r["coverage"] for r in self.rows()])


class LauncherArgumentTests(CoverageCase):
    def test_integer_options_accept_only_ascii_digits(self) -> None:
        # bug: str.isdigit() lets `²` through to int(), a traceback instead of a usage error, and lets
        # `٣` through as 3
        for value in ("²", "٣", "-1", "", "1.5"):
            with self.subTest(value=value), mock.patch("sys.stderr", new_callable=io.StringIO), \
                    self.assertRaises(SystemExit) as ctx:
                self.run_main("--mass-files", value)
            self.assertEqual(2, ctx.exception.code)

    def test_text_summary_says_when_the_deadline_cut_the_run_short(self) -> None:
        # bug: a run that stopped at --deadline prints like a complete one
        self.build()
        for deadline, want in (("0", "deadline_hit=true"), ("900", "deadline_hit=false")):
            with self.subTest(deadline=deadline):
                rc, out = self.run_main("--deadline", deadline)
                self.assertEqual(0, rc, out)
                self.assertIn(want, out)

    def test_text_summary_names_the_coverage_counts(self) -> None:
        # bug: the default output hides the coverage result the run computed
        self.build()
        rc, out = self.run_main()
        self.assertEqual(0, rc, out)
        self.assertIn("coverage: unreviewed=1", out)

    def test_help_says_an_error_exit_writes_nothing(self) -> None:
        # bug: a scheduler re-runs after exit 2 assuming nothing changed, while a partial write happened
        self.assertIn("2 usage, git, I/O or install error (nothing written)", load_launcher().USAGE)


if __name__ == "__main__":
    unittest.main()
