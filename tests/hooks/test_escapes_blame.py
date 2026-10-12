"""scripts/zuvo-home/review-escapes + zuvo_escapes_{fixwalk,blame,store}.py — fix discovery, blame of a
fix's deleted lines to the commit that introduced them, and the idempotent per-project store.

Every case runs against a real temporary git repository (escapes_testlib.FixtureRepo)."""

from __future__ import annotations

import datetime as dt
import hashlib
import io
import json
import os
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from escapes_testlib import AUTHOR_EMAIL, LAUNCHER, NOW, EscapesTestCase, FixtureRepo, lines  # noqa: E402

# A gpg stand-in: signs anything with a fixed block, and "verifies" by printing the line a real gpg
# prints to stderr (which `git log --show-signature` copies into its output).
FAKE_GPG = """\
for a in "$@"; do
  if [ "$a" = "--verify" ]; then
    echo "gpg: Signature made FAKE" >&2; echo "[GNUPG:] GOODSIG 0 fake"; exit 0
  fi
done
cat > /dev/null
printf '%s\\n' '-----BEGIN PGP SIGNATURE-----' fake '-----END PGP SIGNATURE-----'
echo "[GNUPG:] SIG_CREATED D 1 8 00 0 fake" >&2
"""
BASE = lines("def total(a, b):", "    x = a", "    y = b", "    return x + y", "")
BUGGY = lines("def total(a, b):", "    x = a", "    y = -b  # BUGGY_LINE_TOKEN", "    return x + y", "")
FIXED = lines("def total(a, b):", "    x = a", "    y = b", "    return x + y", "")


class FixDiscoveryTests(EscapesTestCase):
    def test_subjects_holding_record_separators_are_read_whole(self) -> None:
        # bug: a subject holding \x1f or \x1e (the walk's own field and record separators) splits its
        # record, so that fix is silently dropped or read with a cut subject
        self.repo.commit("init", {"src/a.py": BASE, "src/b.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/a.py": BUGGY, "src/b.py": BUGGY},
                         days_ago=20)
        self.repo.commit("fix(a): unit\x1fsep", {"src/a.py": FIXED}, days_ago=6)
        self.repo.commit("fix(b): record\x1esep", {"src/b.py": FIXED}, days_ago=5)
        self.summary()
        self.assertEqual(["fix(a): unit\x1fsep", "fix(b): record\x1esep"],
                         sorted(r["fix_subject"] for r in self.rows()))

    def test_fix_subject_patterns(self) -> None:
        # bug: a squash-merged fix branch or a conventional fix commit is never looked at, or a
        # `fixture:` / `feat:` commit is blamed as if it fixed a defect
        import zuvo_escapes_fixwalk as fw
        table = [
            ("Merged in fix/pairwise-tie-1003 (pull request #1657)", True),
            ("Merged in hotfix/prod-crash (pull request #12)", True),
            ("fix(designer): Radio Slider Grid canvas preview", True),
            ("fix: keep labels readable", True),
            ("fix!: breaking fix", True),
            ("fixture: add survey data", False),
            ("feat: new export", False),
            ("Merged in feature/fix-later (pull request #3)", False),
            ("fixed typo", False),
            ("Merge branch 'hotfix/prod' into develop", True),
            ("Merge pull request #7 from org/bugfix/x", True),
            ("Merge branch 'develop' into fix/x", False),
            ("prefix(x): y", False),
        ]
        for subject, want in table:
            with self.subTest(subject=subject):
                self.assertEqual(want, fw.is_fix_subject(subject))

    def test_non_fix_commits_changing_a_line_produce_no_escape(self) -> None:
        # bug: every edit of an old line is counted as an escaped defect
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        self.repo.commit("fixture: reshape", {"src/app.py": FIXED}, days_ago=6)
        self.repo.commit("feat: more", {"src/app.py": BUGGY}, days_ago=5)
        s = self.summary()
        self.assertEqual((0, 0), (s["fixes"], s["escapes"]))
        self.assertEqual([], self.rows())

    def fixes_with_fix_aged(self, days: float) -> int:
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=90)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=60)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=days)
        return int(self.summary("--since", "30d")["fixes"])

    def test_since_window_includes_a_fix_landed_exactly_at_its_age(self) -> None:
        # bug: an off-by-one at the window edge drops the boundary fix from every run
        self.assertEqual(1, self.fixes_with_fix_aged(30))

    def test_since_window_excludes_a_fix_one_second_older(self) -> None:
        # bug: the window edge leaks one step, so consecutive runs count a fix twice in rates
        self.assertEqual(0, self.fixes_with_fix_aged(30 + 1 / 86400))

    def test_fix_older_than_since_is_not_walked(self) -> None:
        # bug: --since ignored, every run re-walks the whole history
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=90)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=60)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=40)
        self.assertEqual(0, self.summary("--since", "30d")["fixes"])
        self.assertEqual(1, self.summary("--since", "45d")["fixes"])


class PatchParseTests(EscapesTestCase):
    def test_unquote_keeps_a_non_utf8_byte_inside_a_quoted_name(self) -> None:
        # bug: with core.quotepath=off a non-UTF-8 byte reaches unquote() raw (a surrogate escape) inside a
        # name git quoted for another reason; encoding it as UTF-8 raises and the fix's diff is lost
        import zuvo_escapes_patch as pt
        self.assertEqual('a"b\udce9.py', pt.unquote('"a\\"b\udce9.py"'))

    def test_patch_parsing_edge_cases(self) -> None:
        # bug: a removed line reading like a header, a quoted or spaced name, or a rename/binary/
        # deleted header put ranges on the wrong file or lost the file
        import zuvo_escapes_patch as pt
        patch = "\n".join([
            "diff --git a/src/a.py b/src/a.py", "index 1..2 100644", "--- a/src/a.py", "+++ b/src/a.py",
            "@@ -3,2 +3 @@", "--- not a header", "-+++ nor this", "+x", "\\ No newline at end of file",
            "@@ -9,0 +8,2 @@", "+y", "+z",
            "diff --git a/h t.py b/h t.py", "--- a/h t.py\t", "+++ b/h t.py\t", "@@ -1 +1 @@", "-q", "+r",
            'diff --git "a/caf\\303\\251.py" "b/caf\\303\\251.py"', '--- "a/caf\\303\\251.py"',
            '+++ "b/caf\\303\\251.py"', "@@ -2 +0,0 @@", "-gone",
            "diff --git a/old.py b/new.py", "similarity index 90%", "rename from old.py", "rename to new.py",
            "--- a/old.py", "+++ b/new.py", "@@ -4 +4 @@", "-a", "+b",
            "diff --git a/dead.py b/dead.py", "deleted file mode 100644", "--- a/dead.py", "+++ /dev/null",
            "@@ -1,2 +0,0 @@", "-1", "-2",
            "diff --git a/img.png b/img.png", "Binary files a/img.png and b/img.png differ",
            "diff --git a/n.py b/n.py", "new file mode 100644", "--- /dev/null", "+++ b/n.py",
            "@@ -0,0 +1 @@", "+n",
            "",
        ])
        F = pt.FilePatch
        self.assertEqual([
            F("src/a.py", False, False, False, ((3, 2),)),
            F("h t.py", False, False, False, ((1, 1),)),
            F("caf\u00e9.py", False, False, False, ((2, 1),)),
            F("old.py", False, False, False, ((4, 1),)),
            F("dead.py", False, True, False, ((1, 2),)),
            F("img.png", False, False, True, ()),
            F("n.py", True, False, False, ()),
        ], pt.parse_patch(patch))

    def test_mixed_hunks_skip_their_whole_body(self) -> None:
        # bug: skipping only the removed lines of a hunk read its added `--- a/x` / `@@` lines as headers
        import zuvo_escapes_patch as pt
        patch = "\n".join([
            "diff --git a/m.py b/m.py", "--- a/m.py", "+++ b/m.py",
            "@@ -2,2 +2,3 @@", "-x", "-y", "+--- a/fake.py", "+@@ -40,9 +40 @@", "+z",
            "@@ -10 +11 @@", "-q", "+r", "",
        ])
        self.assertEqual([pt.FilePatch("m.py", False, False, False, ((2, 2), (10, 1)))],
                         pt.parse_patch(patch))

    def test_truncated_hunk_does_not_swallow_the_next_file(self) -> None:
        # bug: a hunk whose body ended early left its line count running into the next file's headers
        import zuvo_escapes_patch as pt
        patch = "\n".join([
            "diff --git a/one.py b/one.py", "--- a/one.py", "+++ b/one.py", "@@ -1,3 +1,3 @@", "-a",
            # a quoted header names the file only through its ---/+++ lines
            'diff --git "a/t\\tw.py" "b/t\\tw.py"', '--- "a/t\\tw.py"', '+++ "b/t\\tw.py"', "@@ -5 +5 @@",
            "-b", "+c", "",
        ])
        self.assertEqual([pt.FilePatch("one.py", False, False, False, ((1, 3),)),
                          pt.FilePatch("t\tw.py", False, False, False, ((5, 1),))], pt.parse_patch(patch))

    def test_non_utf8_path_bytes_round_trip(self) -> None:
        # bug: a Latin-1 file name became U+FFFD, so blame was asked for a path that does not exist
        import zuvo_escapes_patch as pt
        name = pt.unquote('"caf\\351.py"')
        self.assertEqual(b"caf\xe9.py", os.fsencode(name))

    def test_malformed_octal_escape_does_not_crash(self) -> None:
        # bug: `\\9..` or a non-ASCII digit after a backslash raised ValueError and killed the run
        import zuvo_escapes_patch as pt
        table = [('"\\101b"', "Ab"), ('"a\\9zz"', "a\\9zz"), ('"\\989"', "\\989"),
                 ('"\\\u0663\u0663\u0663"', "\\\u0663\u0663\u0663"), ("plain", "plain")]
        for raw, want in table:
            with self.subTest(raw=raw):
                self.assertEqual(want, pt.unquote(raw))


class PorcelainParseTests(EscapesTestCase):
    def test_boundary_and_per_group_filenames(self) -> None:
        # bug: a `boundary` or `previous` key misread as a header moved lines onto another commit, or
        # the last filename of a commit was applied to every group of it
        import zuvo_escapes_blame as b
        a, c = "a" * 40, "c" * 40
        porcelain = "\n".join([
            f"{a} 7 1 1", "author X", "committer-time 100", "boundary", "filename old.py", "\tline one",
            f"{c} 2 2 1", "committer-time 200", f"previous {a} old.py", "filename new.py", "\tline two",
            f"{a} 9 3 1", "filename \"sp ace.py\"", "\tline three",
            f"{a} 10 4 1", "\tline four", "",
        ])
        self.assertEqual(([
            b.BlameLine(1, a, 7, "old.py", 100), b.BlameLine(2, c, 2, "new.py", 200),
            b.BlameLine(3, a, 9, "sp ace.py", 100), b.BlameLine(4, a, 10, "sp ace.py", 100),
        ], 0), b.parse_porcelain(porcelain))

    def test_a_malformed_committer_time_is_a_parse_error(self) -> None:
        # bug: `committer-time 12x` raised ValueError and killed the run
        import zuvo_escapes_blame as b
        a = "a" * 40
        self.assertEqual(([], 1), b.parse_porcelain(f"{a} 1 1 1\ncommitter-time 12x\nfilename x.py\n\tl\n"))

    def test_a_line_without_committer_time_is_a_parse_error(self) -> None:
        # bug: a missing committer-time became 1970, so the line was filed as too old
        import zuvo_escapes_blame as b
        a, c = "a" * 40, "c" * 40
        porcelain = "\n".join([f"{a} 1 1 1", "filename x.py", "\tno time", f"{c} 2 2 1",
                                "committer-time 200", "filename x.py", "\ttimed", ""])
        self.assertEqual(([b.BlameLine(2, c, 2, "x.py", 200)], 1), b.parse_porcelain(porcelain))


class BlameAttributionTests(EscapesTestCase):
    def test_deleted_line_blames_onto_the_introducing_commit(self) -> None:
        # bug: the escape is pinned on the fix itself or on the file's first commit
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        intro = self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY},
                                 days_ago=20)
        fix = self.repo.commit("Merged in fix/sign (pull request #2)", {"src/app.py": FIXED}, days_ago=5)
        s = self.summary()
        self.assertEqual({"fixes": 1, "escapes": 1, "unattributed": 0}, {k: s[k] for k in
                                                                       ("fixes", "escapes", "unattributed")})
        [row] = self.rows()
        self.assertEqual(f"{fix}:src/app.py:3", row["key"])
        self.assertEqual((intro, intro, "src/app.py", 3), (row["intro_sha"], row["intro_landing_sha"],
                                                          row["intro_file"], row["intro_line"]))
        self.assertEqual((fix, fix, 3), (row["fix_sha"], row["fix_landing_sha"], row["line_at_parent"]))
        # the fix lands 5 days before the injected NOW: its week is that day's, never the wall clock's
        year, week, _ = (NOW - dt.timedelta(days=5)).isocalendar()
        self.assertEqual(f"{year}-W{week:02d}", row["fix_week"])
        self.assertIs(False, s["deadline_hit"])

    def test_intro_on_a_merged_branch_lands_at_the_first_parent_merge(self) -> None:
        # bug: the review range is looked up for a branch commit no review artifact names
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.branch("feature/a")
        intro = self.repo.commit("feat: negate", {"src/app.py": BUGGY}, days_ago=25)
        self.repo.checkout("develop")
        self.repo.commit("chore: unrelated", {"README.txt": "x\n"}, days_ago=24)
        merge = self.repo.merge("feature/a", "Merged in feature/a (pull request #1)", days_ago=22)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        self.summary()
        [row] = self.rows()
        self.assertEqual((intro, merge), (row["intro_sha"], row["intro_landing_sha"]))

    def test_intro_merged_twice_lands_at_the_earlier_merge(self) -> None:
        # bug: a branch merged again later re-landed its old commits at the later merge, so the
        # review range searched for the escape was the wrong one
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.branch("feature/a")
        intro = self.repo.commit("feat: negate", {"src/app.py": BUGGY}, days_ago=30)
        self.repo.checkout("develop")
        self.repo.commit("chore: one", {"README.txt": "1\n"}, days_ago=29)
        first = self.repo.merge("feature/a", "Merged in feature/a (pull request #1)", days_ago=28)
        self.repo.checkout("feature/a")
        self.repo.commit("feat: more", {"src/more.py": "m = 1\n"}, days_ago=20)
        self.repo.checkout("develop")
        self.repo.commit("chore: two", {"README.txt": "2\n"}, days_ago=19)
        self.repo.merge("feature/a", "Merged in feature/a (pull request #2)", days_ago=18)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        self.summary()
        self.assertEqual([(intro, first)], [(r["intro_sha"], r["intro_landing_sha"]) for r in self.rows()])

    def test_paths_with_glob_and_colon_characters_are_literal(self) -> None:
        # bug: a path like `:(icase)x` or `a*.py` read as pathspec magic blamed another file or none
        odd = "src/:w*ld[1].py"
        self.repo.commit("init", {odd: BASE, "src/:wild1.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {odd: BUGGY}, days_ago=20)
        self.repo.commit("fix(app): sign", {odd: FIXED}, days_ago=5)
        s = self.summary()
        self.assertEqual((1, None), (s["escapes"], s["skipped"].get("blame_error")))
        self.assertEqual([odd], [r["file"] for r in self.rows()])

    def test_shallow_clone_boundary_is_not_an_introducer(self) -> None:
        # bug: in a shallow clone every old line blames to the graft commit, which is then charged
        # with escapes it never introduced
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        self.repo.commit("chore: unrelated", {"README.txt": "x\n"}, days_ago=10)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        shallow = os.path.join(self.tmp, "shallow")
        self.repo.git("clone", "-q", "--depth", "2", "--branch", "develop", f"file://{self.repo.path}",
                      shallow)
        rc, out = self.run_main("--repo", shallow, "--ref", "origin/develop", "--json")
        self.assertEqual(0, rc)
        s = json.loads(out)
        self.assertEqual((0, 1), (s["escapes"], s["skipped"].get("shallow_boundary")))

    def test_root_commit_is_a_valid_introducer(self) -> None:
        # bug: the root commit's `boundary` marker made its lines unattributable
        init = self.repo.commit("init", {"src/app.py": BUGGY}, days_ago=60)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        self.summary()
        self.assertEqual([init], [r["intro_sha"] for r in self.rows()])

    def test_fix_of_a_line_its_own_branch_introduced_is_not_an_escape(self) -> None:
        # bug: a fix made before the merge (the review could not have missed it yet) counted as an escape
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.branch("feature/a")
        self.repo.commit("feat: negate", {"src/app.py": BUGGY}, days_ago=25)
        self.repo.commit("fix(app): sign before merge", {"src/app.py": FIXED}, days_ago=24)
        self.repo.checkout("develop")
        self.repo.commit("chore: unrelated", {"README.txt": "x\n"}, days_ago=23)
        self.repo.merge("feature/a", "Merged in feature/a (pull request #1)", days_ago=22)
        s = self.summary()
        self.assertEqual((1, 0, 1), (s["fixes"], s["escapes"], s["skipped"].get("same_merge")))
        self.assertEqual([], self.rows())

    def test_pure_addition_fix_is_unattributed_with_no_row(self) -> None:
        # bug: SZZ has nothing to blame when a fix only adds lines; inventing an intro commit would
        # attribute the escape to an innocent review
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("fix(app): add guard", {"src/app.py": BASE + "assert True\n"}, days_ago=5)
        s = self.summary()
        self.assertEqual((1, 0, 1), (s["fixes"], s["escapes"], s["unattributed"]))
        self.assertEqual([], self.rows())

    def test_intro_older_than_max_age_is_skipped(self) -> None:
        # bug: a defect from years before the review system existed is charged to today's reviews
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=400)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=200)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        s = self.summary()
        self.assertEqual((1, 0, 1), (s["fixes"], s["escapes"], s["skipped"].get("too_old")))
        self.assertEqual(1, self.summary("--max-age", "365d")["escapes"])


class PathAndCommitFilterTests(EscapesTestCase):
    NOISE = {"tests/test_app.py": "a\nb\n", "package-lock.json": "{}\n", "docs/guide.md": "a\nb\n",
             "dist/bundle.js": "a\nb\n"}

    def test_only_production_paths_are_blamed(self) -> None:
        # bug: lockfile and test churn counted as production escapes
        self.repo.commit("init", {"src/app.py": BASE, **self.NOISE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        changed = {p: "changed\n" for p in self.NOISE}
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED, **changed}, days_ago=5)
        s = self.summary()
        self.assertEqual(["src/app.py"], [r["file"] for r in self.rows()])
        self.assertEqual(4, s["skipped"].get("non_production_path"))

    def test_fix_touching_only_tests_is_not_a_fix(self) -> None:
        # bug: a test-only fix inflated the fix count with nothing to attribute
        self.repo.commit("init", {"tests/test_app.py": "a\nb\n"}, days_ago=60)
        self.repo.commit("fix(tests): flake", {"tests/test_app.py": "a\nc\n"}, days_ago=5)
        s = self.summary()
        self.assertEqual((0, 1), (s["fixes"], s["skipped"].get("non_production")))

    def test_mass_files_threshold_is_inclusive(self) -> None:
        # bug: a repo-wide rename or reformat blamed as hundreds of escapes
        files = {f"src/m{i}.py": BASE for i in range(3)}
        self.repo.commit("init", files, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {p: BUGGY for p in files}, days_ago=20)
        self.repo.commit("fix(all): sign", {p: FIXED for p in files}, days_ago=5)
        at = self.summary("--mass-files", "3")
        self.assertEqual((0, 1), (at["escapes"], at["skipped"].get("mass_files")))
        above = self.summary("--mass-files", "4")
        self.assertEqual((3, None), (above["escapes"], above["skipped"].get("mass_files")))

    def fix_branch(self, branch_subject: str, merge_subject: str) -> tuple[str, str]:
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        intro = self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY},
                                 days_ago=20)
        self.repo.branch("fix/sign")
        self.repo.commit(branch_subject, {"src/app.py": FIXED}, days_ago=6)
        self.repo.checkout("develop")
        self.repo.commit("chore: unrelated", {"README.txt": "x\n"}, days_ago=6)
        return intro, self.repo.merge("fix/sign", merge_subject, days_ago=5)

    def test_true_merge_of_a_fix_branch_is_a_fix_with_its_first_parent_diff(self) -> None:
        # bug: a fix branch merged with a real merge commit, whose own commits are not named fix,
        # was never looked at
        intro, merge = self.fix_branch("chore: sign", "Merged in fix/sign (pull request #2)")
        s = self.summary()
        self.assertEqual((1, 1), (s["fixes"], s["escapes"]))
        self.assertEqual([(merge, merge, intro, 3)], [(r["fix_sha"], r["fix_landing_sha"], r["intro_sha"],
                                                       r["line_at_parent"]) for r in self.rows()])

    def test_fix_named_commit_inside_a_fix_merge_is_not_counted_twice(self) -> None:
        # bug: the merge and the fix commit it brought in each wrote a row for the same defect
        intro, merge = self.fix_branch("fix(app): sign", "Merge branch 'fix/sign' into develop")
        s = self.summary()
        self.assertEqual((1, 1, 1), (s["fixes"], s["escapes"], s["skipped"].get("in_fix_merge")))
        self.assertEqual([(merge, intro)], [(r["fix_sha"], r["intro_sha"]) for r in self.rows()])

    def test_escape_pairs_count_each_fix_and_intro_once(self) -> None:
        # bug: one large fix PR rewriting many lines of one bad commit outweighs many separate escapes
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        two = lines("def total(a, b):", "    x = -a", "    y = -b", "    return x + y", "")
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": two}, days_ago=20)
        three = two.replace("return x + y", "return x - y")
        self.repo.commit("Merged in feature/b (pull request #2)", {"src/app.py": three}, days_ago=15)
        self.repo.commit("fix(app): signs", {"src/app.py": FIXED}, days_ago=5)
        s = self.summary()
        self.assertEqual((3, 2), (s["escapes"], s["escape_pairs"]))
        self.assertEqual(3, len(self.rows()))


class BlameIgnoreRevsTests(EscapesTestCase):
    def build(self) -> tuple[str, str]:
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        intro = self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY},
                                 days_ago=20)
        reformat = self.repo.commit("style: reflow", {"src/app.py": BUGGY.replace("-b", "-(b)")},
                                    days_ago=15)
        return intro, reformat

    def test_listed_revision_is_looked_through(self) -> None:
        # bug: a mass reformat listed in .git-blame-ignore-revs absorbs every escape
        intro, reformat = self.build()
        self.repo.commit("chore: ignore reformat", {".git-blame-ignore-revs": reformat + "\n"}, days_ago=14)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        self.summary()
        self.assertEqual([intro], [r["intro_sha"] for r in self.rows()])

    def test_absent_file_blames_plainly(self) -> None:
        # bug: a repo without the file fails blame (git errors on a missing ignore-revs file)
        _, reformat = self.build()
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        s = self.summary()
        self.assertEqual([reformat], [r["intro_sha"] for r in self.rows()])
        self.assertIsNone(s["skipped"].get("blame_error"))


class StoreTests(EscapesTestCase):
    def build(self) -> None:
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)

    def read_bytes(self) -> bytes:
        with open(self.store, "rb") as f:
            return f.read()

    def build_many(self) -> None:
        self.repo.commit("init", {"src/app.py": BASE, "src/b.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY, "src/b.py": BUGGY},
                         days_ago=20)
        self.repo.commit("fix(b): sign", {"src/b.py": FIXED}, days_ago=6)
        two = BUGGY.replace("x = a", "x = -a")
        self.repo.commit("Merged in feature/c (pull request #2)", {"src/app.py": two}, days_ago=8)
        self.repo.commit("fix(app): signs", {"src/app.py": FIXED}, days_ago=5)

    def test_rerun_rewrites_a_byte_identical_store(self) -> None:
        # bug: a weekly rerun duplicates rows or reorders them, so every diff of the store is noise
        self.build_many()
        self.summary()
        first = self.read_bytes()
        self.summary()
        self.assertEqual(first, self.read_bytes())
        rows = self.rows()
        self.assertEqual(3, len(rows))
        self.assertEqual(sorted(r["key"] for r in rows), [r["key"] for r in rows])

    def test_rerun_after_history_changed_replaces_the_row_in_place(self) -> None:
        # bug: a rescan that blames differently (here: a reformat added to the ignore list) appended
        # a second row for the same line, or rewrote the store in another order
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        intro = self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        reformat = self.repo.commit("style: reflow", {"src/app.py": BUGGY.replace("-b", "-(b)")}, days_ago=15)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        self.summary()
        [before] = self.rows()
        self.repo.commit("chore: ignore reformat", {".git-blame-ignore-revs": reformat + "\n"}, days_ago=4)
        self.summary()
        [after] = self.rows()
        self.assertEqual((before["key"], reformat, intro),
                         (after["key"], before["intro_sha"], after["intro_sha"]))
        self.assertEqual(json.dumps(after, sort_keys=True) + "\n",
                         self.read_bytes().decode("utf-8"))

    def test_classification_survives_a_rerun_unless_reclassify(self) -> None:
        # bug: a rescan wipes the paid-for classification of every escape
        self.build()
        self.summary()
        [row] = self.rows()
        row.update({"class": "logic", "catchable": True})
        with open(self.store, "w", encoding="utf-8") as f:
            f.write(json.dumps(row) + "\n")
        self.summary()
        self.assertEqual(("logic", True), (self.rows()[0].get("class"), self.rows()[0].get("catchable")))
        self.summary("--reclassify")
        [after] = self.rows()
        self.assertEqual((None, None, row["key"]), (after.get("class"), after.get("catchable"), after["key"]))

    def test_records_hold_no_author_email_or_diff_text(self) -> None:
        # bug: the HOME store leaks a colleague's address and source lines (CQ5)
        self.build()
        self.summary()
        data = self.read_bytes().decode("utf-8")
        self.assertIn('"intro_sha"', data)
        self.assertNotIn(AUTHOR_EMAIL, data)
        self.assertNotIn("BUGGY_LINE_TOKEN", data)
        self.assertNotIn("return x + y", data)

    def test_store_path_cannot_leave_the_store_directory(self) -> None:
        # bug: a project named `..` or `/etc/x` made the whole-file rewrite replace a file elsewhere
        import zuvo_escapes_store as st
        base = os.path.join(self.zuvo, "review-escapes-data")

        def tag(name: str) -> str:  # the documented suffix of a rewritten name
            return hashlib.sha1(name.encode("utf-8")).hexdigest()[:8]

        table = [("../x", f".._x-{tag('../x')}.jsonl"),
                 ("/etc/passwd", f"_etc_passwd-{tag('/etc/passwd')}.jsonl"),
                 ("ok.repo-1_x", "ok.repo-1_x.jsonl")]
        for name, want in table:
            with self.subTest(name=name):
                self.assertEqual(os.path.join(base, want), st.store_path(name))
        for bad in ("", ".", ".."):
            with self.subTest(bad=bad), self.assertRaises(st.BadProject):
                st.store_path(bad)

    def test_rewritten_project_names_never_share_a_store(self) -> None:
        # bug: `foo/bar`, `foo bar` and `foo_bar` all became foo_bar.jsonl and overwrote each other
        import zuvo_escapes_store as st
        paths = {st.store_path(n) for n in ("foo/bar", "foo bar", "foo_bar")}
        self.assertEqual(3, len(paths))
        long = st.store_path("x" * 300)
        self.assertLessEqual(len(os.path.basename(long)), 100 + len(".jsonl"))
        self.assertNotEqual(long, st.store_path("x" * 299))

    def test_reclassify_drops_classification_from_every_stored_row(self) -> None:
        # bug: rows outside this run's window kept a classification made under the old vocabulary
        self.build()
        self.summary()
        [row] = self.rows()
        old = {"key": "0" * 40 + ":src/old.py:1", "project": "proj", "class": "logic", "catchable": True}
        with open(self.store, "w", encoding="utf-8") as f:
            f.write(json.dumps({**row, "class": "logic"}) + "\n" + json.dumps(old) + "\n")
        self.summary("--reclassify")
        self.assertEqual([(old["key"], None, None), (row["key"], None, None)],
                         sorted((r["key"], r.get("class"), r.get("catchable")) for r in self.rows()))

    def test_reclassify_keeps_the_classes_written_by_the_same_upsert(self) -> None:
        # bug: --reclassify --classify drops the classes it just paid for, so they need a second write
        # (which can fail after the first succeeded)
        import zuvo_escapes_store as st
        stored: list[dict] = [{"key": "a", "class": "logic", "file": "x"}, {"key": "b", "class": "numeric"}]
        fresh: list[dict] = [{"key": "a", "file": "y"}, {"key": "b", "class": "boundary", "catchable": False}]
        self.assertEqual([{"key": "a", "file": "y"}, {"key": "b", "class": "boundary", "catchable": False}],
                         st.merge_rows(stored, fresh, reclassify=True))

    def test_unwritable_store_is_an_error_exit_not_a_traceback(self) -> None:
        # bug: a read-only ~/.zuvo crashed the weekly job with a traceback instead of exit 2
        self.build()
        data = os.path.dirname(self.store)
        os.makedirs(data)
        os.chmod(data, 0o500)
        self.addCleanup(os.chmod, data, 0o700)
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            rc, _ = self.run_main("--json")
        self.assertEqual(2, rc)
        self.assertIn(data, err.getvalue())

    def test_summary_pins_the_ref_to_one_commit(self) -> None:
        # bug: a ref moving during the run mixed two histories; the report could not say which
        self.build()
        self.assertEqual(self.repo.git("rev-parse", "develop"), self.summary()["ref_sha"])

    def test_held_lock_refuses_and_leaves_an_existing_store_unchanged(self) -> None:
        # bug: two runs interleave their rewrites and one loses the other's rows
        self.build()
        self.summary()
        stored = self.read_bytes()
        self.repo.commit("Merged in feature/b (pull request #2)", {"src/app.py": BUGGY}, days_ago=4)
        self.repo.commit("fix(app): again", {"src/app.py": FIXED}, days_ago=3)
        holder = self.hold_lock()
        rc, _ = self.run_main("--json")
        self.assertEqual((3, stored), (rc, self.read_bytes()))
        holder.kill()
        holder.wait()
        # both fixes are in the window again: one row each, the first one unchanged
        self.assertEqual(2, self.summary()["escapes"])
        self.assertEqual(2, len(self.rows()))


class RobustnessTests(EscapesTestCase):
    def test_whitespace_only_rewrite_is_not_an_escape(self) -> None:
        # bug: the diff saw a re-indented line as removed while blame -w looked through the
        # whitespace commit, so the escape landed on an innocent older commit
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)",
                         {"src/app.py": BASE.replace("y = b", "y =  b")}, days_ago=20)
        self.repo.commit("fix(app): spacing", {"src/app.py": BASE}, days_ago=5)
        s = self.summary()
        self.assertEqual((0, 1), (s["escapes"], s["skipped"].get("whitespace_only")))
        self.assertEqual([], self.rows())

    def test_deleted_file_is_not_blamed(self) -> None:
        # bug: removing dead code charged every line of the file as an escape
        self.repo.commit("init", {"src/app.py": BASE, "src/dead.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        self.repo.commit("fix(app): sign, drop dead code", {"src/app.py": FIXED, "src/dead.py": None},
                         days_ago=5)
        s = self.summary()
        self.assertEqual(["src/app.py"], [r["file"] for r in self.rows()])
        self.assertEqual(1, s["skipped"].get("deleted_file"))

    def test_git_failure_in_one_fix_is_counted_and_the_run_goes_on(self) -> None:
        # bug: one unreadable object (shallow clone, timeout) aborted the whole run with exit 2
        init = self.repo.commit("init", {"src/app.py": BASE, "src/other.py": "only = 1\n"}, days_ago=60)
        intro = self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        self.repo.commit("fix(other): value", {"src/other.py": "only = 2\n"}, days_ago=6)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        self.repo.drop_object(f"{init}:src/other.py")
        s = self.summary()
        self.assertEqual((1, 1), (s["fixes"], s["skipped"].get("git_error")))
        self.assertEqual([intro], [r["intro_sha"] for r in self.rows()])

    def test_deadline_stops_starting_new_fixes(self) -> None:
        # bug: a scheduled run over a huge history never finished and held the store lock
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        s = self.summary("--deadline", "0")
        self.assertEqual((True, 0, 1), (s["deadline_hit"], s["fixes"], s["skipped"].get("deadline")))
        self.assertEqual([], self.rows())

    def test_fix_on_a_long_branch_is_selected_by_its_landing_date(self) -> None:
        # bug: a fix committed 40 days ago on a branch merged 5 days ago fell outside --since 30d
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=90)
        intro = self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=60)
        self.repo.branch("feature/long")
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=40)
        self.repo.checkout("develop")
        self.repo.commit("chore: unrelated", {"README.txt": "x\n"}, days_ago=39)
        merge = self.repo.merge("feature/long", "Merged in feature/long (pull request #2)", days_ago=5)
        s = self.summary("--since", "30d")
        self.assertEqual((1, 1), (s["fixes"], s["escapes"]))
        self.assertEqual([(intro, merge)], [(r["intro_sha"], r["fix_landing_sha"]) for r in self.rows()])

    def test_ignore_list_is_read_from_the_ref_not_the_working_tree(self) -> None:
        # bug: a checkout on another branch silently dropped the ref's .git-blame-ignore-revs
        init = self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        intro = self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        reformat = self.repo.commit("style: reflow", {"src/app.py": BUGGY.replace("-b", "-(b)")}, days_ago=15)
        self.repo.commit("chore: ignore reformat", {".git-blame-ignore-revs": reformat + "\n"}, days_ago=14)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        self.repo.git("checkout", "-q", "-b", "elsewhere", init)
        self.summary()
        self.assertEqual([intro], [r["intro_sha"] for r in self.rows()])

    def test_backdated_first_parent_commit_cuts_nothing_off(self) -> None:
        # bug: one commit with a clock 300 days behind ended the window and the landing walk there,
        # so the fix and the intro behind it vanished
        self.repo.commit("init", {"src/app.py": BASE, "src/b.py": BASE}, days_ago=60)
        intro = self.repo.commit("Merged in feature/a (pull request #1)",
                                 {"src/app.py": BUGGY, "src/b.py": BUGGY}, days_ago=20)
        fix_a = self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=10)
        self.repo.commit("chore: skewed clock", {"README.txt": "x\n"}, days_ago=300)
        fix_b = self.repo.commit("fix(b): sign", {"src/b.py": FIXED}, days_ago=5)
        s = self.summary()
        self.assertEqual((2, 2, None), (s["fixes"], s["escapes"], s["skipped"].get("no_landing")))
        self.assertEqual({(fix_a, intro), (fix_b, intro)},
                         {(r["fix_sha"], r["intro_sha"]) for r in self.rows()})

    def test_intro_whose_landing_is_older_than_the_walk_has_no_landing(self) -> None:
        # bug: a branch commit with a clock ahead of its (old) merge was filed as too old, hiding it
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=400)
        self.repo.branch("feature/a")
        self.repo.commit("feat: negate", {"src/app.py": BUGGY}, days_ago=10)
        self.repo.checkout("develop")
        self.repo.commit("chore: one", {"README.txt": "1\n"}, days_ago=399)
        self.repo.merge("feature/a", "Merged in feature/a (pull request #1)", days_ago=200)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        s = self.summary()
        skipped = s["skipped"]
        self.assertEqual((0, 1, None), (s["escapes"], skipped.get("no_landing"), skipped.get("too_old")))

    def test_fix_brought_by_an_in_window_merge_lands_there_whatever_its_own_date(self) -> None:
        # bug: the landing walk applied --since to branch commits, so an old fix commit merged inside
        # the window had no landing (and its rows a wrong week)
        import zuvo_escapes_fixwalk as fw
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=90)
        self.repo.branch("feature/long")
        fix = self.repo.commit("fix(app): sign", {"src/app.py": FIXED + "# x\n"}, days_ago=40)
        self.repo.checkout("develop")
        self.repo.commit("chore: unrelated", {"README.txt": "x\n"}, days_ago=39)
        merge = self.repo.merge("feature/long", "Merged in feature/long (pull request #2)", days_ago=5)
        since_ts = int((NOW - dt.timedelta(days=30)).timestamp())
        landing = fw.landing_map(self.repo.path, "develop", since_ts).get(fix)
        self.assertEqual(merge, landing.sha if landing else None)
        self.assertEqual(1, self.summary("--since", "30d", "--max-age", "10d")["fixes"])

    def test_five_consecutive_lines_of_one_commit_are_all_blamed(self) -> None:
        # bug: the porcelain parser kept only the first line of a group of lines from one commit
        six = lines("a = 1", "b = 2", "c = 3", "d = 4", "e = 5", "f = 6")
        self.repo.commit("init", {"src/app.py": six}, days_ago=60)
        intro = self.repo.commit("Merged in feature/a (pull request #1)",
                                 {"src/app.py": six.replace(" = ", " = -").replace("a = -1", "a = 1")},
                                 days_ago=20)
        self.repo.commit("fix(app): signs", {"src/app.py": six}, days_ago=5)
        self.summary()
        self.assertEqual([(2, intro), (3, intro), (4, intro), (5, intro), (6, intro)],
                         sorted((r["line_at_parent"], r["intro_sha"]) for r in self.rows()))

    def test_inherited_git_dir_does_not_redirect_the_scan(self) -> None:
        # bug: run from a git hook (GIT_DIR set), every git call read the hook's repository instead
        other = FixtureRepo(os.path.join(self.tmp, "other"))
        other.commit("init", {"x.py": "x = 1\n"}, days_ago=50)
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        self.setenv(GIT_DIR=os.path.join(other.path, ".git"))
        self.assertEqual(1, self.summary()["escapes"])


class FetchTests(EscapesTestCase):
    def upstream_with_late_fix(self) -> FixtureRepo:
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        clone = FixtureRepo(os.path.join(self.tmp, "clone"), clone_of=self.repo.path)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        return clone

    def test_fetch_takes_the_remote_name_from_the_configured_remotes(self) -> None:
        # bug: `team/up/develop` was read as remote `team`, branch `up/develop`, and the fetch failed
        clone = self.upstream_with_late_fix()
        clone.git("remote", "add", "team/up", self.repo.path)
        rc, out = self.run_main("--repo", clone.path, "--ref", "team/up/develop", "--fetch", "--json")
        self.assertEqual(0, rc)
        self.assertEqual(1, json.loads(out)["escapes"])

    def test_fetch_of_a_ref_naming_no_remote_is_an_error(self) -> None:
        # bug: `feature/x` was fetched as branch `x` of a remote called `feature`
        clone = self.upstream_with_late_fix()
        clone.git("branch", "feature/x")
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            rc, _ = self.run_main("--repo", clone.path, "--ref", "feature/x", "--fetch", "--json")
        self.assertEqual(2, rc)
        self.assertIn("names no remote", err.getvalue())


class FetchEnvTests(EscapesTestCase):
    def test_fetch_never_prompts_and_keeps_the_users_ssh_command(self) -> None:
        # bug: forcing GIT_SSH_COMMAND overrode a repo's core.sshCommand (its deploy key)
        import zuvo_escapes_fixwalk as fw
        self.repo.commit("init", {"a.py": "a\n"}, days_ago=1)
        plain = fw.fetch_env(self.repo.path, {})
        self.assertEqual(("0", "ssh -o BatchMode=yes"),
                         (plain["GIT_TERMINAL_PROMPT"], plain["GIT_SSH_COMMAND"]))
        self.assertEqual("mine", fw.fetch_env(self.repo.path, {"GIT_SSH_COMMAND": "mine"})["GIT_SSH_COMMAND"])
        self.repo.git("config", "core.sshCommand", "ssh -i deploy_key")
        self.assertNotIn("GIT_SSH_COMMAND", fw.fetch_env(self.repo.path, {}))


class GitConfigTests(EscapesTestCase):
    def test_ssh_program_chosen_by_git_ssh_is_kept(self) -> None:
        # bug: a GIT_SSH (or GIT_SSH_VARIANT) the user set is overridden by the injected GIT_SSH_COMMAND,
        # which git prefers — the scheduled fetch then runs another ssh than the one configured
        import zuvo_escapes_fixwalk as fw
        self.repo.commit("init", {"a.py": "a\n"}, days_ago=1)
        for env in ({"GIT_SSH": "/opt/bin/plink"}, {"GIT_SSH_VARIANT": "plink"}):
            with self.subTest(env=env):
                self.assertNotIn("GIT_SSH_COMMAND", fw.fetch_env(self.repo.path, env))

    def test_signature_display_config_does_not_change_parsed_output(self) -> None:
        # bug: a user's log.showSignature=true puts gpg's lines into every `git log` the walk parses,
        # so the first-parent chain read crashes on a line that is not `<sha> <time> <parents>`
        gpg = self.fake_exe("fakegpg", FAKE_GPG)
        for key, value in (("gpg.program", gpg), ("user.signingkey", "fake"), ("commit.gpgSign", "true"),
                           ("log.showSignature", "true")):
            self.repo.git("config", key, value)
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        self.assertIn("gpg: Signature made", self.repo.git("log", "-1", "--format=%H"))
        self.assertEqual((1, 1), (self.summary()["escapes"], len(self.rows())))


class DefaultRefTests(EscapesTestCase):
    def two_remotes(self, fix_before_clone: bool) -> FixtureRepo:
        """A clone whose develop tracks `bitbucket` (the live remote) while `origin` is a stale mirror."""
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        stale = FixtureRepo(os.path.join(self.tmp, "stale"), clone_of=self.repo.path)
        if fix_before_clone:
            self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        clone = FixtureRepo(os.path.join(self.tmp, "clone"), clone_of=self.repo.path)
        clone.git("remote", "rename", "origin", "bitbucket")
        clone.git("remote", "add", "origin", stale.path)
        clone.git("fetch", "-q", "origin")
        if not fix_before_clone:
            self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=5)
        return clone

    def default_run(self, clone: FixtureRepo, *argv: str) -> dict:
        rc, out = self.run_bare("--repo", clone.path, "--json", *argv)
        self.assertEqual(0, rc)
        return json.loads(out)

    def test_default_ref_is_the_upstream_of_develop(self) -> None:
        # bug: the default origin/develop was a stale mirror, so the run measured week-old history
        s = self.default_run(self.two_remotes(fix_before_clone=True))
        self.assertEqual(("bitbucket/develop", 1, 1), (s["ref"], s["fixes"], s["escapes"]))

    def test_fetch_fetches_the_remote_of_the_resolved_ref(self) -> None:
        # bug: --fetch refreshed the stale mirror and the run still missed the newest fix
        s = self.default_run(self.two_remotes(fix_before_clone=False), "--fetch")
        self.assertEqual(("bitbucket/develop", 1), (s["ref"], s["fixes"]))

    def test_without_an_upstream_the_default_is_origin_develop(self) -> None:
        # bug: a branch with no upstream left the run with no ref at all
        clone = self.two_remotes(fix_before_clone=True)
        clone.git("branch", "--unset-upstream", "develop")
        s = self.default_run(clone)
        self.assertEqual(("origin/develop", 0), (s["ref"], s["fixes"]))

    def test_explicit_ref_wins_over_the_upstream(self) -> None:
        # bug: an explicit --ref was overridden by the detected upstream
        s = self.default_run(self.two_remotes(fix_before_clone=True), "--ref", "origin/develop")
        self.assertEqual(("origin/develop", 0), (s["ref"], s["fixes"]))


class DeltaRoundTests(EscapesTestCase):
    def test_root_commit_named_fix_is_counted_as_skipped(self) -> None:
        # bug: a parentless fix (first commit, or a shallow graft) vanished from every count
        self.repo.commit("fix: initial import", {"src/app.py": BASE}, days_ago=5)
        s = self.summary()
        self.assertEqual((0, 1), (s["fixes"], s["skipped"].get("root_fix")))

    def test_fix_merge_inside_a_fix_merge_is_counted_once(self) -> None:
        # bug: the inner merge removed itself from the outer merge's claimed set and became a 2nd fix
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=60)
        intro = self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=20)
        self.repo.branch("fix/outer")
        self.repo.commit("chore: notes", {"NOTES.txt": "n\n"}, days_ago=9)
        self.repo.branch("fix/inner")
        self.repo.commit("chore: sign", {"src/app.py": FIXED}, days_ago=8)
        self.repo.checkout("fix/outer")
        self.repo.commit("chore: more notes", {"NOTES.txt": "m\n"}, days_ago=7)
        self.repo.merge("fix/inner", "Merge branch 'fix/inner' into fix/outer", days_ago=7)
        self.repo.checkout("develop")
        self.repo.commit("chore: unrelated", {"README.txt": "x\n"}, days_ago=6)
        outer = self.repo.merge("fix/outer", "Merged in fix/outer (pull request #2)", days_ago=5)
        s = self.summary()
        self.assertEqual((1, 1, 1), (s["fixes"], s["escapes"], s["skipped"].get("in_fix_merge")))
        self.assertEqual([(outer, intro)], [(r["fix_sha"], r["intro_sha"]) for r in self.rows()])

    def test_fixes_are_ordered_by_landing_not_commit_date(self) -> None:
        # bug: a deadline cut dropped a fix that landed yesterday because it was committed long ago
        import zuvo_escapes_blame as b
        import zuvo_escapes_fixwalk as fw
        old_commit = fw.Commit("a" * 40, ("p",), 100, "fix: a")
        new_commit = fw.Commit("b" * 40, ("p",), 500, "fix: b")
        landings = {old_commit.sha: fw.Landing("m" * 40, 900),
                    new_commit.sha: fw.Landing(new_commit.sha, 500)}
        self.assertEqual([old_commit, new_commit], b.newest_landing_first([new_commit, old_commit], landings))

    def test_a_naive_now_is_utc_whatever_the_local_zone(self) -> None:
        # bug: a naive `now` was read as local time, moving every window by the zone offset
        import zuvo_escapes_blame as b
        self.use_zone("Asia/Tokyo")
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=90)
        self.repo.commit("Merged in feature/a (pull request #1)", {"src/app.py": BUGGY}, days_ago=60)
        self.repo.commit("fix(app): sign", {"src/app.py": FIXED}, days_ago=30 + 1 / 24)
        sha = self.repo.git("rev-parse", "develop")
        opts = b.Options(sha, dt.timedelta(days=30), dt.timedelta(days=180), 200)
        _, summary = b.scan(self.repo.path, "proj", opts, NOW.replace(tzinfo=None))
        self.assertEqual(0, summary.fixes)


class ProjectNameTests(EscapesTestCase):
    def test_project_name_never_collapses_into_a_shared_placeholder(self) -> None:
        # bug: every repo whose name could not be derived wrote one shared unknown.jsonl
        import zuvo_escapes_fixwalk as fw
        self.assertEqual("repo", fw.project_name("/home/x/DEV/repo", "/home/x/DEV/repo-wt"))
        self.assertEqual("repo-wt", fw.project_name("/", "/home/x/DEV/repo-wt"))
        with self.assertRaises(fw.GitError):
            fw.project_name("/", "/")


class LauncherTests(EscapesTestCase):
    def cli(self, *argv: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, str(LAUNCHER), *argv], capture_output=True, text=True,
                              timeout=60)

    def test_json_summary_has_the_documented_keys(self) -> None:
        # bug: the curator reads a key the summary never had
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=1)
        proc = self.cli("--repo", self.repo.path, "--ref", "develop", "--json")
        self.assertEqual(0, proc.returncode, proc.stderr)
        self.assertEqual({"ref", "ref_sha", "fixes", "escapes", "escape_pairs", "unattributed", "skipped",
                          "deadline_hit", "coverage", "kept_unkeyed"},
                         set(json.loads(proc.stdout)))

    def test_classify_counts_appear_only_when_classifying(self) -> None:
        # bug: a plain scan reports classify counts it never produced, or --classify hides its own
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=1)
        keys = []
        for extra in ([], ["--classify"]):
            proc = self.cli("--repo", self.repo.path, "--ref", "develop", "--json", *extra)
            self.assertEqual(0, proc.returncode, proc.stderr)
            keys.append("classify" in json.loads(proc.stdout))
        self.assertEqual([False, True], keys)

    def test_unresolvable_ref_is_an_error_not_an_empty_scan(self) -> None:
        # bug: a missing origin/develop reads as "no fixes this month"
        self.repo.commit("init", {"src/app.py": BASE}, days_ago=1)
        proc = self.cli("--repo", self.repo.path, "--ref", "origin/nope", "--json")
        self.assertEqual(2, proc.returncode)
        self.assertIn("origin/nope", proc.stderr)
        self.assertEqual("", proc.stdout)

    def test_bad_duration_is_a_usage_error(self) -> None:
        # bug: `--since 30` (no unit) silently meant 30 seconds or nothing
        proc = self.cli("--repo", self.repo.path, "--since", "30")
        self.assertEqual(2, proc.returncode)
        self.assertIn("--since", proc.stderr)

    def test_help_documents_the_exit_codes(self) -> None:
        # bug: a scheduler cannot tell "busy" (3) from "broken" (2) without reading the source
        proc = self.cli("--help")
        self.assertEqual(0, proc.returncode)
        self.assertIn("3 another run holds the store's lock", proc.stdout)


if __name__ == "__main__":
    unittest.main()
