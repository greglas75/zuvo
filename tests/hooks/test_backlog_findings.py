"""scripts/zuvo-home/zuvo_backlog_findings.py — where the findings ledger lives, how it is segmented,
appended and folded. Every row names the defect it would catch. Git state comes from temp `git init`
repos built per test (the farm mirror has no .git), and every assertion reads the FOLDED result,
never the number of segment files.
"""

import contextlib
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Mapping, Sequence, Tuple
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "zuvo-home"))
import zuvo_backlog_admit as adm  # noqa: E402
import zuvo_backlog_findings as fnd  # noqa: E402

# Schema v1, retyped here so a key added, dropped or renamed in the module fails the golden row.
GOLDEN_RECORD_KEYS = frozenset({
    "v", "id", "ts", "class", "confidence", "severity", "title", "how", "fix", "anchor", "files",
    "target", "area", "agent", "source", "branch", "pr", "sha", "route", "reason", "backlog",
    "status", "forced"})
GOLDEN_SIGHTING_KEYS = frozenset({"v", "id", "ts", "sighting"})
GOLDEN_PATCH_KEYS = frozenset({"v", "id", "ts", "status", "backlog", "note"})

FID = "F-" + "a" * 12
FID2 = "F-" + "b" * 12
FID3 = "F-" + "c" * 12
T0, T1, T2, T3 = ("2026-10-13T08:00:00+00:00", "2026-10-13T09:00:00+00:00",
                  "2026-10-13T10:00:00+00:00", "2026-10-13T11:00:00+00:00")
SEG_A, SEG_B = "2026-10-13_a_host.jsonl", "2026-10-13_b_host.jsonl"
FOLD_BYTES = int(os.environ.get("ZUVO_FOLD_BENCH_BYTES", str(10 * 1024 * 1024)))
FOLD_BUDGET_S = 5.0
HERMETIC_GIT = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
REAL_GIT = shutil.which("git") or "git"


def h6(raw: str) -> str:
    """The 6-hex suffix a lossy slug carries (the spec: `-<sha1(raw)[:6]>`)."""
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:6]


@contextlib.contextmanager
def pinned_tz(tz: str) -> Iterator[None]:
    """Run with the process time zone set to `tz`, then restore it — `time.tzset` both ways."""
    try:
        with mock.patch.dict(os.environ, {"TZ": tz}):
            time.tzset()
            yield
    finally:
        time.tzset()


def recipe_ignore_lines() -> List[str]:
    """The `.gitignore` lines VISIBILITY_RECIPE tells the user to add."""
    return [line.strip() for line in fnd.VISIBILITY_RECIPE.splitlines() if line.startswith("    /")]


def git(cwd: str, *args: str) -> str:
    out = subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
         "-c", "init.defaultBranch=main", *args],
        cwd=cwd, capture_output=True, text=True, check=True)
    return out.stdout.strip()


def write(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    Path(path).write_text(text, encoding="utf-8")


def new_repo(base: str, name: str, ignore: str, tracked: Sequence[str], memory: bool = True) -> str:
    """A repo with `.gitignore` = `ignore`, `tracked` committed, and `memory/backlog.md` on disk
    unless `memory` is False (then `memory/` does not exist at all)."""
    repo = os.path.join(base, name)
    os.makedirs(repo)
    git(repo, "init", "-q")
    write(os.path.join(repo, ".gitignore"), ignore)
    if memory:
        write(os.path.join(repo, "memory", "backlog.md"), "# Backlog\n")
    for rel in tracked:
        write(os.path.join(repo, rel), "{}\n")
    git(repo, "add", ".gitignore", *tracked)
    git(repo, "commit", "-q", "-m", "seed")
    return repo


def visibility(repo: str) -> Any:
    return fnd.check_visibility(Path(repo, "memory", "findings"), os.path.join(repo, "memory", "backlog.md"),
                                "2026-10-13_main_h.jsonl")


def fake_git(base: str, body: str) -> str:
    """A directory holding an executable `git` that runs `body`: git failing or hanging on cue."""
    d = os.path.join(base, "fakebin")
    write(os.path.join(d, "git"), "#!/bin/sh\n" + body + "\n")
    os.chmod(os.path.join(d, "git"), 0o755)
    return d


def tree(root: str) -> List[str]:
    """Every directory and file under `root`, `.git` excluded — what "nothing written" compares."""
    return sorted(os.path.relpath(os.path.join(d, n), root)
                  for d, dirs, files in os.walk(root) if ".git" not in Path(d).parts
                  for n in dirs + files if n != ".git")


def layout_tracked_worktree(base: str) -> Tuple[str, str]:
    main = new_repo(base, "main", "", ["memory/backlog.md"])
    wt = os.path.join(base, "wt")
    git(main, "worktree", "add", "-q", "-b", "feat", wt)
    return wt, os.path.join(wt, "memory", "findings")


def layout_ignored_worktree(base: str) -> Tuple[str, str]:
    main = new_repo(base, "main", "/memory/backlog.md\n", [])
    wt = os.path.join(base, "wt")
    git(main, "worktree", "add", "-q", "-b", "feat", wt)
    return wt, os.path.join(main, "memory", "findings")


def layout_symlinked(base: str) -> Tuple[str, str]:
    main = new_repo(base, "main", "/memory/backlog.md\n", [])
    canon = os.path.join(base, "canon")
    write(os.path.join(canon, "backlog.md"), "# Backlog\n")
    backlog = os.path.join(main, "memory", "backlog.md")
    os.remove(backlog)
    os.symlink(os.path.join(canon, "backlog.md"), backlog)
    return main, os.path.join(canon, "findings")


def record(fid: str = FID, ts: str = T0, **over: Any) -> Dict[str, Any]:
    fields: Dict[str, Any] = {"id": fid, "class": "DUP", "title": "same loop in a and b",
                              "source": "review"}
    fields.update(over)
    return fnd.record_line(fields, ts=ts)


def sight(branch: str) -> Dict[str, Any]:
    return fnd.sighting_line(FID, source="review", sha="abc1234", branch=branch, pr=None, ts=T1)


def sight_at(ts: str) -> Dict[str, Any]:
    return fnd.sighting_line(FID, source="review", sha="abc1234", branch="main", pr=None, ts=ts)


def segments(directory: str, lines: Mapping[str, Sequence[Any]]) -> None:
    """Raw segment files: a dict line is JSON-encoded, a str line is written verbatim."""
    for name, rows in lines.items():
        write(os.path.join(directory, name),
              "".join((r if isinstance(r, str) else json.dumps(r)) + "\n" for r in rows))


def folded(directory: str, fid: str = FID) -> Tuple[Any, Any, int, List[str]]:
    recs, defects = fnd.fold(Path(directory))
    rec = recs[fid]
    return rec.fields["status"], rec.fields["backlog"], rec.seen, sorted(d.kind for d in defects)


def bulk_ledger(directory: str, size: int) -> int:
    """`size` bytes of records, each with one sighting and one patch. Returns the record count."""
    rec = json.dumps(record(fid="F-000000000000"))
    per = len(rec) + 120 * 2
    n = max(1, size // per)
    ids = [f"F-{i:012x}" for i in range(n)]
    lines = [json.dumps(record(fid=i)) for i in ids]
    lines += [json.dumps(fnd.sighting_line(i, source="review", sha="abc1234", branch="main", pr=None,
                                           ts=T1)) for i in ids]
    lines += [json.dumps(fnd.patch_line(i, status="kept", ts=T2)) for i in ids]
    write(os.path.join(directory, SEG_A), "\n".join(lines) + "\n")
    return n


class Hermetic(unittest.TestCase):
    """A temp base dir (realpath, so /var vs /private/var never splits a path) and a git that reads
    no user or system config — a global excludesFile would otherwise change what is ignored."""

    def setUp(self) -> None:
        self.base = os.path.realpath(tempfile.mkdtemp(prefix="zuvo-findings-"))
        self.addCleanup(shutil.rmtree, self.base, True)
        env = mock.patch.dict(os.environ, HERMETIC_GIT)
        env.start()
        self.addCleanup(env.stop)


class LocationTests(Hermetic):
    ROWS: List[Tuple[str, Callable[[str], Tuple[str, str]]]] = [
        ("tracked backlog in a linked worktree: findings written into the MAIN checkout, so the "
         "branch's ledger never travels with its backlog", layout_tracked_worktree),
        ("ignored backlog in a linked worktree: a per-worktree ledger forks the history and is "
         "lost with the worktree", layout_ignored_worktree),
        ("symlinked backlog: findings beside the link instead of the realpath (the 2026-07-19 "
         "fork bug)", layout_symlinked),
    ]

    def test_ledger_sits_beside_the_real_backlog(self) -> None:
        for name, layout in self.ROWS:
            with self.subTest(name):
                repo, want = layout(os.path.join(self.base, layout.__name__))
                self.assertEqual(Path(want), fnd.ledger_dir(repo))


class VisibilityTests(Hermetic):
    TRACKED_SEG = ["memory/findings/2026-10-01_main_h.jsonl"]
    # (name, .gitignore, tracked paths, memory/ exists, expected refusal)
    ROWS: List[Tuple[str, str, List[str], bool, Any]] = [
        ("tracked findings/ beside an ignored backlog: untracked content published through git",
         "/memory/backlog.md\n", TRACKED_SEG, True, fnd.REFUSED_TRACKED),
        ("ignored backlog, findings/ absent and not ignored: an absent dir read as 'unknown' and "
         "let through", "/memory/backlog.md\n", [], True, fnd.REFUSED_TRACKED),
        ("/memory/findings/ ignored and the dir absent: asking about the bare dir refuses a "
         "correct layout", "/memory/backlog.md\n/memory/findings/\n", [], True, None),
        ("tracked backlog: a tracked ledger beside a tracked backlog refused", "",
         ["memory/backlog.md"], True, None),
        ("no memory/ yet, backlog ignored: an absent parent read as 'unknown' and let through",
         "/memory/backlog.md\n", [], False, fnd.REFUSED_TRACKED),
        ("no memory/ yet, /memory/ ignored: an absent parent refused although all of it is ignored",
         "/memory/\n", [], False, None),
    ]

    def test_refuses_only_a_tracked_ledger_beside_an_ignored_backlog(self) -> None:
        for i, (name, ignore, tracked, memory, want) in enumerate(self.ROWS):
            with self.subTest(name):
                repo = new_repo(self.base, f"r{i}", ignore, tracked, memory)
                before = tree(repo)
                self.assertEqual((want, before), (visibility(repo), tree(repo)))

    def test_concurrent_checks_all_refuse_and_write_nothing(self) -> None:
        # CQ21: a check that creates and removes a probe directory lets one caller see another's
        # directory vanish mid-question and answer "unknown" -> accepted
        layouts = [("tracked findings/", self.TRACKED_SEG), ("absent findings/", [])]
        for name, tracked in layouts:
            with self.subTest(name):
                repo = new_repo(self.base, f"c-{len(tracked)}", "/memory/backlog.md\n", tracked)
                before = tree(repo)
                with ThreadPoolExecutor(max_workers=4) as pool:
                    got = list(pool.map(visibility, [repo] * 4))
                self.assertEqual(([fnd.REFUSED_TRACKED] * 4, before), (got, tree(repo)))

    def test_git_that_cannot_answer_is_refused(self) -> None:
        # CQ8: a git error or a hang read as "not ignored" publishes an ignored backlog's findings
        delegate = f'exec "{REAL_GIT}" "$@"'
        rows = [("git error other than not-a-repository", "echo 'fatal: index file corrupt' >&2; exit 128",
                 fnd.GIT_TIMEOUT_S),
                ("git hanging past the timeout", "exec sleep 5", 0.3),
                ("rev-parse answers but check-ignore fails (rc 128): read as 'not ignored'",
                 f'[ "$3" = check-ignore ] && {{ echo "fatal: bad pathspec" >&2; exit 128; }}\n{delegate}',
                 fnd.GIT_TIMEOUT_S),
                ("four slow calls each inside a per-call timeout: the whole check exceeds its budget",
                 f"sleep 0.2\n{delegate}", 0.5)]
        repo = new_repo(self.base, "broken", "/memory/backlog.md\n/memory/findings/\n", [])
        for name, body, timeout in rows:
            with self.subTest(name), \
                    mock.patch.dict(os.environ, {"PATH": fake_git(self.base, body) + os.pathsep
                                                 + os.environ["PATH"]}), \
                    mock.patch.object(fnd, "GIT_TIMEOUT_S", timeout):
                self.assertEqual(fnd.REFUSED_UNKNOWN, visibility(repo))

    def test_inherited_git_dir_does_not_answer_for_another_repo(self) -> None:
        # a hook's GIT_DIR outranks `git -C`: the check would read the other repo's (absent) ignore
        # rules, see the backlog as tracked, and let an ignored backlog's findings be published
        repo = new_repo(self.base, "mine", "/memory/backlog.md\n", [])
        other = new_repo(self.base, "other", "", [".gitignore"])
        with mock.patch.dict(os.environ, {"GIT_DIR": os.path.join(other, ".git")}):
            self.assertEqual(fnd.REFUSED_TRACKED, visibility(repo))

    def test_outside_a_repository_unknown_is_not_tracked(self) -> None:
        # the canonical backlog lives outside any repo; reading "unknown" as "tracked" refuses it forever
        write(os.path.join(self.base, "memory", "backlog.md"), "# Backlog\n")
        got = fnd.check_visibility(Path(self.base, "memory", "findings"),
                                   os.path.join(self.base, "memory", "backlog.md"), "2026-10-13_main_h.jsonl")
        self.assertIsNone(got)

    def test_following_the_recipe_clears_the_refusal(self) -> None:
        # a recipe naming the wrong path sends the user back to the same refusal forever
        repo = new_repo(self.base, "recipe", "/memory/backlog.md\n", [])
        before = visibility(repo)
        write(os.path.join(repo, ".gitignore"),
              "/memory/backlog.md\n" + "".join(f"{line}\n" for line in recipe_ignore_lines()))
        self.assertEqual((fnd.REFUSED_TRACKED, None), (before, visibility(repo)))


class SegmentTests(Hermetic):
    SHA = "abcdef0123456789abcdef0123456789abcdef01"
    # (name, ZUVO_BACKLOG_NOW, branch, ZUVO_BACKLOG_HOST, expected segment)
    ROWS: List[Tuple[str, str, Any, str, str]] = [
        ("plain branch: injected clock or host ignored", "2026-10-13T09:30:00+00:00", "main", "mac",
         "2026-10-13_main_mac.jsonl"),
        ("slash in the branch: a nested directory instead of one segment", "2026-10-13T09:30:00+00:00",
         "feat/x", "mac", f"2026-10-13_feat-x-{h6('feat/x')}_mac.jsonl"),
        ("safe branch: a hash added to a name that lost nothing", "2026-10-13T09:30:00+00:00",
         "feat-x", "mac", "2026-10-13_feat-x_mac.jsonl"),
        ("detached HEAD: every detached run shares one anonymous segment", "2026-10-13T09:30:00+00:00",
         None, "mac", "2026-10-13_detached-abcdef0_mac.jsonl"),
        ("local offset: the segment dated by local time, not UTC", "2026-10-14T01:00:00+02:00", "main",
         "mac", "2026-10-13_main_mac.jsonl"),
        ("unsafe host name: a space or slash in the file name", "2026-10-13T09:30:00+00:00", "main",
         "my host/x", f"2026-10-13_main_my-host-x-{h6('my host/x')}.jsonl"),
        ("underscore in the branch: the date_branch_host fields no longer split", "2026-10-13T09:30:00Z",
         "feat_x", "mac", f"2026-10-13_feat-x-{h6('feat_x')}_mac.jsonl"),
    ]

    def test_segment_name_is_date_branch_host(self) -> None:
        for name, now, branch, host, want in self.ROWS:
            with self.subTest(name), mock.patch.dict(os.environ, {"ZUVO_BACKLOG_NOW": now,
                                                                  "ZUVO_BACKLOG_HOST": host}):
                got = fnd.segment_path(Path(self.base), fnd.now_stamp(), branch, fnd.host_name(),
                                       sha=self.SHA)
                self.assertEqual(Path(self.base, want), got)

    def test_distinct_branches_never_share_a_segment(self) -> None:
        # lossy slugs (a replaced character, a cut long name) put two branch lineages in one file
        long = "feature/" + "x" * 70
        names = ["feat/x", "feat_x", "feat-x", long, long + "y"]
        segs = {fnd.branch_slug(n) for n in names}
        self.assertEqual(len(names), len(segs))

    def test_injected_clock_stamps_records_in_utc(self) -> None:
        # a naive, `Z` or local stamp sorts wrongly against the `+00:00` stamps of other hosts
        rows = [("local offset kept", "2026-10-14T01:00:00+02:00", "2026-10-13T23:00:00+00:00"),
                ("Z suffix refused or kept as Z", "2026-10-13T09:30:00Z", "2026-10-13T09:30:00+00:00"),
                ("naive time read as local", "2026-10-13T09:30:00", "2026-10-13T09:30:00+00:00")]
        # pinned to UTC+9: on a UTC farm a naive time read as local and as UTC are the same instant
        for name, now, want in rows:
            with self.subTest(name), pinned_tz("JST-9"), \
                    mock.patch.dict(os.environ, {"ZUVO_BACKLOG_NOW": now}):
                self.assertEqual(want, record(ts=fnd.now_stamp())["ts"])

    def test_caller_ts_is_stored_in_the_one_spelling_the_fold_orders(self) -> None:
        # an offset or `Z` stored verbatim sorts as a string against `+00:00` stamps: wrong winner
        rows = [("offset", "2026-10-14T20:00:00+05:00", "2026-10-14T15:00:00+00:00"),
                ("Z suffix", "2026-10-14T15:00:00Z", "2026-10-14T15:00:00+00:00"),
                ("naive", "2026-10-14T15:00:00", "2026-10-14T15:00:00+00:00")]
        for name, ts, want in rows:
            with self.subTest(name), pinned_tz("JST-9"):
                self.assertEqual((want, want, want), (record(ts=ts)["ts"], sight_at(ts)["ts"],
                                                      fnd.patch_line(FID, status="kept", ts=ts)["ts"]))

    def test_host_falls_back_to_the_short_host_name(self) -> None:
        # an empty ZUVO_BACKLOG_HOST naming the segment `_.jsonl`, or the FQDN splitting on its dots
        rows = [("FQDN shortened", "box.example.com", "box"), ("no host name at all", "", "host")]
        for name, hostname, want in rows:
            with self.subTest(name), mock.patch.dict(os.environ, {"ZUVO_BACKLOG_HOST": ""}), \
                    mock.patch.object(fnd.socket, "gethostname", return_value=hostname):
                self.assertEqual(want, fnd.host_name())

    def test_unusable_names_are_refused(self) -> None:
        # a path in the segment name escapes findings/; a detached segment without a sha collides
        rows: List[Tuple[str, Callable[[], object], str]] = [
            ("slash in the segment name", lambda: fnd.check_visibility(Path(self.base), "b.md", "a/b.jsonl"),
             "bare file name"),
            ("empty segment name", lambda: fnd.check_visibility(Path(self.base), "b.md", ""),
             "bare file name"),
            ("detached HEAD without a sha", lambda: fnd.segment_path(Path(self.base), T0, None, "mac"),
             "detached HEAD needs the commit sha"),
        ]
        for name, call, message in rows:
            with self.subTest(name), self.assertRaisesRegex(ValueError, message):
                call()

    def test_unparseable_injected_clock_is_refused(self) -> None:
        # a garbage clock silently falling back to the wall clock makes a test pass on the wrong day
        with mock.patch.dict(os.environ, {"ZUVO_BACKLOG_NOW": "yesterday"}), \
                self.assertRaisesRegex(ValueError, "ZUVO_BACKLOG_NOW"):
            fnd.now_stamp()


class SchemaTests(Hermetic):
    def test_golden_key_sets(self) -> None:
        # a renamed or dropped key breaks every consumer of the ledger (part 3's export, dup-map)
        got = (frozenset(record()), frozenset(fnd.sighting_line(FID, source="review", sha="abc1234",
                                                                branch="main", pr=7, ts=T1)),
               frozenset(fnd.patch_line(FID, status="fixed", ts=T1)))
        self.assertEqual((GOLDEN_RECORD_KEYS, GOLDEN_SIGHTING_KEYS, GOLDEN_PATCH_KEYS), got)

    def test_record_defaults_to_found_and_v1(self) -> None:
        # a record without a status folds as "unknown" and is never exported
        rec = record()
        self.assertEqual((1, "found", T0), (rec["v"], rec["status"], rec["ts"]))

    def test_builders_refuse_out_of_schema_values(self) -> None:
        rows: List[Tuple[str, Callable[[], object]]] = [
            ("status outside the closed set written by the builder",
             lambda: fnd.patch_line(FID, status="merged", ts=T1)),
            ("unknown record key smuggled into schema v1", lambda: record(extra=1)),
            ("record id that is not an F-id", lambda: record(fid="B-x-BUG-12345678")),
            ("empty patch that changes nothing", lambda: fnd.patch_line(FID, ts=T1)),
            ("a ts that is not a time sorts as a string ahead of every real one",
             lambda: record(ts="z")),
            ("meta overwriting a core field (the status) through record_for", lambda: fnd.record_for(
                adm.Finding(cls="DUP", conf=60, source="review", title="t", file="a.py", line=1),
                adm.Decision("ledger", "class-report-only", "DUP", "t", False), FID, ts=T0,
                meta={"status": "fixed"})),
            ("a sighting whose pr is not a number", lambda: fnd.append_line(
                Path(self.base, SEG_A), fnd.sighting_line(FID, source="review", sha=None, branch=None,
                                                          pr="12", ts=T1))),  # type: ignore[arg-type]
        ]
        for name, build in rows:
            with self.subTest(name), self.assertRaises(ValueError):
                build()

    def test_record_for_maps_a_finding_onto_dup_map_names(self) -> None:
        # evidence under a name the export does not read, or the promoted class stored instead of
        # the original one (the F-id is computed from the original)
        f = adm.Finding(cls="TEST-GAP", conf=85, source="review", title="empty cart untested",
                        file="src/cart.ts", line=42, evidence="no case for []",
                        missing_assertion="expect(total).toBe(0)")
        d = adm.decide(f, frozenset({42}), False)
        rec = fnd.record_for(f, d, FID, backlog="B-cart-BUG-aaaaaaaa", ts=T0,
                             meta={"branch": "feat/x", "sha": "abc1234", "pr": 12})
        self.assertEqual(
            ("TEST-GAP", 85, "no case for []", [{"path": "src/cart.ts", "line": 42,
                                                 "note": "expect(total).toBe(0)"}],
             "backlog", "promoted", "B-cart-BUG-aaaaaaaa", "ticketed", "feat/x", 12),
            (rec["class"], rec["confidence"], rec["how"], rec["files"], rec["route"], rec["reason"],
             rec["backlog"], rec["status"], rec["branch"], rec["pr"]))


class FoldTests(Hermetic):
    # (name, segments, expected (status, backlog, seen, defect kinds))
    ROWS: List[Tuple[str, Dict[str, List[Any]], Tuple[Any, Any, int, List[str]]]] = [
        ("later ts wins for status: file order used instead of time",
         {SEG_A: [record(), fnd.patch_line(FID, status="fixed", ts=T2),
                  fnd.patch_line(FID, status="refuted", ts=T1)]},
         ("fixed", None, 1, [])),
        ("patch older than its record (clock skew): dropped as stale",
         {SEG_A: [record(ts=T3), fnd.patch_line(FID, status="refuted", ts=T1)]},
         ("refuted", None, 1, [])),
        ("seen across two branch segments: absolute values undercount",
         {SEG_A: [record(), sight("main")],
          SEG_B: [sight("feat/x")]},
         ("found", None, 3, [])),
        ("backlog patch: the ticket link lost on fold",
         {SEG_A: [record(), fnd.patch_line(FID, status="ticketed", backlog="B-a-BUG-aaaaaaaa", ts=T1)]},
         ("ticketed", "B-a-BUG-aaaaaaaa", 1, [])),
        ("orphan patch, bad JSON, unknown v: one bad line aborts the fold or vanishes silently",
         {SEG_A: [record(), "{not json", dict(record(), v=2, id=FID2),
                  fnd.patch_line(FID2, status="fixed", ts=T1)]},
         ("found", None, 1, ["bad-json", "orphan", "unknown-v"])),
        ("status outside the closed set in a raw line: applied instead of named",
         {SEG_A: [record(), dict(fnd.patch_line(FID, status="fixed", ts=T1), status="merged")]},
         ("found", None, 1, ["bad-status"])),
        ("equal ts in two segments: resolved by arrival order instead of segment name",
         {SEG_B: [fnd.patch_line(FID, status="fixed", ts=T1)],
          SEG_A: [record(), fnd.patch_line(FID, status="refuted", ts=T1)]},
         ("fixed", None, 1, [])),
        ("unknown line kind: a v1 line that is no record, sighting or patch read as one",
         {SEG_A: [record(), {"v": 1, "id": FID2, "ts": T1}]},
         ("found", None, 1, ["unknown-kind"])),
        ("non-object sighting: counted as a sighting",
         {SEG_A: [record(), dict(sight("main"), sighting="main")]},
         ("found", None, 1, ["bad-record"])),
        ("empty sighting object: `{}` counted as a report",
         {SEG_A: [record(), dict(sight("main"), sighting={})]},
         ("found", None, 1, ["bad-record"])),
        ("sighting pr given as a bool: True read as PR #1",
         {SEG_A: [record(), dict(sight("main"), sighting=dict(sight("main")["sighting"], pr=True))]},
         ("found", None, 1, ["bad-record"])),
        ("patch backlog id that is a number: copied into the record as a ticket link",
         {SEG_A: [record(), dict(fnd.patch_line(FID, status="ticketed", ts=T1), backlog=123)]},
         ("found", None, 1, ["bad-record"])),
        ("record whose files is a string: consumers iterate its characters",
         {SEG_A: [record(), dict(record(fid=FID2), files="src/a.py")]},
         ("found", None, 1, ["bad-record"])),
        ("non-canonical ts (+05:00, sorts as a string): a stale patch wins the fold",
         {SEG_A: [record(), fnd.patch_line(FID, status="fixed", ts=T1),
                  dict(fnd.patch_line(FID, status="refuted", ts=T1), ts="2026-10-13T20:00:00+05:00")]},
         ("fixed", None, 1, ["bad-record"])),
        ("deeply nested JSON line: RecursionError aborts the whole fold",
         {SEG_A: [record(), "[" * 100000 + "]" * 100000]},
         ("found", None, 1, ["bad-json"])),
        ("bool v: `True == 1` reads a foreign line as schema v1",
         {SEG_A: [record(), dict(record(fid=FID2), v=True)]},
         ("found", None, 1, ["unknown-v"])),
        ("patch with a null status: the backlog link clears the status, or is called a defect",
         {SEG_A: [record(), fnd.patch_line(FID, backlog="B-a-BUG-aaaaaaaa", ts=T1)]},
         ("found", "B-a-BUG-aaaaaaaa", 1, [])),
        ("equal ts in one segment: the earlier line wins over the later one",
         {SEG_A: [record(), fnd.patch_line(FID, status="refuted", ts=T1),
                  fnd.patch_line(FID, status="kept", ts=T1)]},
         ("kept", None, 1, [])),
    ]

    def test_fold_applies_events_in_time_then_segment_then_line_order(self) -> None:
        for i, (name, segs, want) in enumerate(self.ROWS):
            with self.subTest(name):
                d = os.path.join(self.base, f"f{i}")
                segments(d, segs)
                self.assertEqual(want, folded(d))

    def test_absent_directory_folds_to_nothing(self) -> None:
        # the first call in a repo crashing on a missing findings/ directory
        self.assertEqual(({}, []), fnd.fold(Path(self.base, "nope")))

    # (name, unterminated tail, before (defects, ids), after appending FID3 (defects, ids))
    TAILS: List[Tuple[str, str, Tuple[List[str], List[str]], Tuple[List[str], List[str]]]] = [
        ("partial tail: glued onto the next line, or applied, or silently dropped",
         '{"v": 1, "id": "F-', (["torn-tail"], [FID]), (["bad-json"], [FID, FID3])),
        ("complete tail missing only its newline: dropped as torn, or lost once terminated",
         json.dumps(record(fid=FID2)), ([], [FID, FID2]), ([], [FID, FID2, FID3])),
    ]

    def test_a_tail_folds_the_same_before_and_after_an_append(self) -> None:
        for i, (name, tail, before, after) in enumerate(self.TAILS):
            with self.subTest(name):
                d = Path(self.base, f"torn{i}")
                write(str(d / SEG_A), json.dumps(record()) + "\n" + tail)
                recs0, defects0 = fnd.fold(d)
                fnd.append_line(d / SEG_A, record(fid=FID3, ts=T1))
                recs1, defects1 = fnd.fold(d)
                self.assertEqual((before, after), (([x.kind for x in defects0], sorted(recs0)),
                                                   ([x.kind for x in defects1], sorted(recs1))))

    def test_two_full_records_count_twice_and_the_latest_wins(self) -> None:
        # two branch lineages each first-seeing one finding: counted once, or the stale title kept
        d = os.path.join(self.base, "dup")
        segments(d, {SEG_B: [record(ts=T0, title="old wording")],
                     SEG_A: [record(ts=T1, title="new wording")]})
        rec = fnd.fold(Path(d))[0][FID]
        self.assertEqual((2, "new wording"), (rec.seen, rec.fields["title"]))

    def test_a_findings_path_that_is_a_file_is_not_an_empty_history(self) -> None:
        # a file at the findings path read as "no history": every finding re-ticketed, refutals lost
        path = Path(self.base, "findings")
        write(str(path), "not a directory\n")
        recs, defects = fnd.fold(path)
        self.assertEqual(({}, ["unreadable"]), (recs, [d.kind for d in defects]))

    def test_a_new_segment_is_as_private_as_the_backlog(self) -> None:
        # a 0640 backlog quoted into a umask-default (0644 / 0755) segment and directory: content the
        # owner kept private becomes readable to every account on a shared host
        memory = Path(self.base, "memory")
        backlog = memory / "backlog.md"
        write(str(backlog), "# Backlog\n")
        os.chmod(backlog, 0o640)
        os.chmod(memory, 0o750)
        seg = memory / "findings" / SEG_A
        fnd.append_line(seg, record(), backlog=str(backlog))
        fnd.append_line(seg, sight("main"), backlog=str(backlog))
        self.assertEqual((0o640, 0o750, ("found", None, 2, [])),
                         (seg.stat().st_mode & 0o777, seg.parent.stat().st_mode & 0o777,
                          folded(str(seg.parent))))

    def test_an_unreadable_segment_is_named_and_the_rest_folds(self) -> None:
        # one unreadable file (here a directory with a segment's name) aborting the whole fold
        d = os.path.join(self.base, "unread")
        segments(d, {SEG_A: [record()]})
        os.makedirs(os.path.join(d, SEG_B))
        self.assertEqual(("found", None, 1, ["unreadable"]), folded(d))

    def test_a_fifo_with_a_segments_name_does_not_hang_the_fold(self) -> None:
        # opening a FIFO blocks until a writer appears, so one stray FIFO in findings/ would hang every
        # backlog-add in the repo while it holds the lock; run in a child so a hang is a timeout
        d = os.path.join(self.base, "fifo")
        segments(d, {SEG_A: [record()]})
        os.mkfifo(os.path.join(d, SEG_B))
        prog = ("import sys; from pathlib import Path; sys.path.insert(0, sys.argv[1]); "
                "import zuvo_backlog_findings as f; print(len(f.fold(Path(sys.argv[2]))[0]))")
        out = subprocess.run([sys.executable, "-c", prog, os.path.join(ROOT, "scripts", "zuvo-home"), d],
                             capture_output=True, text=True, timeout=20, check=True)
        self.assertEqual("1", out.stdout.strip())

    def test_every_defect_kind_is_declared_and_reachable(self) -> None:
        # a defect named outside DEFECT_KINDS is invisible to any consumer filtering on it, and a
        # declared kind nothing emits is a vocabulary that lies
        d = os.path.join(self.base, "all")
        segments(d, {SEG_A: [record(), "{not json", dict(record(fid=FID2), v=True),
                             dict(sight("main"), sighting="x"),
                             dict(fnd.patch_line(FID, status="fixed", ts=T1), status="merged"),
                             {"v": 1, "id": FID2, "ts": T1}, fnd.patch_line(FID2, status="kept", ts=T1)]})
        write(os.path.join(d, "2026-10-13_c_host.jsonl"), '{"v": 1')
        os.makedirs(os.path.join(d, SEG_B))
        recs, defects = fnd.fold(Path(d))
        self.assertEqual((fnd.DEFECT_KINDS, [FID]), ({x.kind for x in defects}, sorted(recs)))

    def test_append_creates_the_directory_and_terminates_each_line(self) -> None:
        # the first sighting in a repo failing on a missing findings/ directory
        seg = Path(self.base, "memory", "findings", SEG_A)
        fnd.append_line(seg, record())
        fnd.append_line(seg, fnd.sighting_line(FID, source="review", sha="abc1234", branch="main",
                                               pr=None, ts=T1))
        self.assertEqual(("found", None, 2, []), folded(str(seg.parent)))

    def test_fold_of_ten_megabytes_stays_inside_the_lock_budget(self) -> None:
        # CQ6: a fold slower than the 5 s lock wait makes every concurrent backlog-add time out
        d = os.path.join(self.base, "big")
        n = bulk_ledger(d, FOLD_BYTES)
        start = time.monotonic()
        recs, defects = fnd.fold(Path(d))
        elapsed = time.monotonic() - start
        size = os.path.getsize(os.path.join(d, SEG_A))
        print(f"\nCQ6 fold: {size / 1048576:.1f} MB, {n} records, {elapsed:.2f}s", file=sys.stderr)
        self.assertEqual((n, [], "kept", 2), (len(recs), defects, recs["F-000000000000"].fields["status"],
                                              recs["F-000000000000"].seen))
        self.assertLess(elapsed, FOLD_BUDGET_S)


if __name__ == "__main__":
    unittest.main()
