"""WHAT `backlog-add` ASKS GIT (and gh) before a finding is written: does the cited site still hold in
the work tree, which branch is the default one, which `[pr:N]` / `[branch:name]` tag the entry carries,
and which lines of a file the branch changed (the promotion rule of zuvo_backlog_admit reads that set).

"HOLDS ON HEAD" MEANS THE WORK TREE. Build writes findings before it commits, so a file the run created
(untracked) counts, a file deleted in the work tree is refused, and an anchor that is no longer within
±ANCHOR_WINDOW lines of the cited line is how "fixed in this same run" is caught.

A READ OPENS FIRST AND CHECKS WHAT IT OPENED: the inode read must be the one the path resolves to
after the open, inside the repo, so a symlink re-pointed after normalize_path cannot aim the read
outside; O_NONBLOCK, so a FIFO at the cited path is refused instead of blocking backlog-add.

THE TAG is the downstream intake's contract (tgm-caretaker 2af315d): `[pr:N]` waits for the PR, and
`[branch:name]` is resolved to the branch's newest PR. Branch names outside `[A-Za-z0-9._/-]` are
never rewritten into a name the intake could not resolve; with no PR they are `untaggable`, and the
CLI decides what that means per class. gh is asked only when origin names github.com as its HOST,
and is pinned to that `owner/repo`: origin comes from a cloned .git/config, and gh carries the user's
token to whatever repo it resolves.

EVERY SUBPROCESS HAS A TIMEOUT, and runs in its own session so a timeout kills the whole group: a
`gh` wrapper script leaves a grandchild holding stdout, and waiting for EOF would outlast the timeout.

The parser module is not imported here, so this file stays outside the H19c pin-guard family.
"""
from __future__ import annotations

import contextlib
import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import PurePath
from typing import NamedTuple, Optional, Set, TextIO, Tuple, Union

import zuvo_backlog_admit as adm

GIT_TIMEOUT_S = 15.0
GH_TIMEOUT_DEFAULT_S = 5.0
PR_CACHE_TTL_S = 15 * 60
PR_CACHE_PARTS = (".zuvo", "cache", "backlog-add-pr.tsv")
ANCHOR_WINDOW = 3

TAG_NONE, TAG_PR, TAG_BRANCH, TAG_UNTAGGABLE = "none", "pr", "branch", "untaggable"

_BRANCH_OK_RE = re.compile(r"[A-Za-z0-9._/-]+")      # the intake's allowed characters, exactly
_PR_RE = re.compile(r"[1-9][0-9]{0,8}")
# The three shapes whose HOST is github.com: https://[userinfo@]github.com[:port]/, ssh://git@github.com
# [:port]/ and scp-style git@github.com:. Groups: owner, repo. Anything else (`evil.com/github.com/…`,
# `github.com.evil.com`, `github.com@evil.com`, file://, http://) never reaches gh.
_GITHUB_RE = re.compile(r"(?:https://(?:[^@/?#\s]*@)?github\.com(?::[0-9]{1,5})?/"
                        r"|ssh://git@github\.com(?::[0-9]{1,5})?/|git@github\.com:/?)"
                        r"([A-Za-z0-9-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?", re.IGNORECASE)
# Exported by git into hooks; each would make git answer for another repo, index or object store than cwd's.
_GIT_LOCATION_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX", "GIT_OBJECT_DIRECTORY",
                     "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_CEILING_DIRECTORIES")
# epoch \t sha256(owner/repo) \t branch \t pr-or-empty; anything else in the cache file is skipped
_CACHE_ROW_RE = re.compile(r"([0-9]{1,12})\t([0-9a-f]{64})\t([^\t]+)\t([1-9][0-9]{0,8})?")
_HUNK_RE = re.compile(r"^@@ -[0-9,]+ \+([0-9]+)(?:,([0-9]+))? @@", re.MULTILINE)


class Tag(NamedTuple):
    kind: str       # TAG_NONE | TAG_PR | TAG_BRANCH | TAG_UNTAGGABLE
    value: str      # the PR number, the branch name, or "" (none / detached untaggable)

    def render(self) -> str:
        """The tail the backlog line ends with; "" for none and untaggable."""
        return {TAG_PR: f"[pr:{self.value}]", TAG_BRANCH: f"[branch:{self.value}]"}.get(self.kind, "")


# ── subprocess ───────────────────────────────────────────────────────────────────────────────────
def _run(argv: list[str], cwd: str, timeout: float) -> Tuple[int, str]:
    """(returncode, stdout decoded with replacement). (-1, "") when it cannot start or times out."""
    env = {k: v for k, v in os.environ.items() if k not in _GIT_LOCATION_ENV}
    env.update(GH_PROMPT_DISABLED="1", GIT_TERMINAL_PROMPT="0")
    try:
        proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, start_new_session=True)
    except (OSError, ValueError):            # ValueError: a NUL in argv
        return -1, ""
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        return -1, ""
    return proc.returncode, out.decode("utf-8", errors="replace")


def _kill_group(proc: subprocess.Popen[bytes]) -> None:
    """SIGKILL the whole session, close the pipes (a stray holder may never close them), reap; never
    raises. Same shape as zuvo_review_llm._kill_group."""
    with contextlib.suppress(OSError):
        os.killpg(proc.pid, signal.SIGKILL)
    with contextlib.suppress(OSError):
        proc.kill()
    for pipe in (proc.stdin, proc.stdout, proc.stderr):
        if pipe:
            with contextlib.suppress(OSError, ValueError):
                pipe.close()
    with contextlib.suppress(subprocess.TimeoutExpired):
        proc.wait(timeout=5)


def _git(repo: str, *args: str) -> Optional[str]:
    """Stripped stdout of `git <args>` in `repo`, or None on any failure."""
    rc, out = _run(["git", "--literal-pathspecs", *args], repo, GIT_TIMEOUT_S)
    return out.strip() if rc == 0 else None


# ── the cited site ───────────────────────────────────────────────────────────────────────────────
def _escapes(rel: str) -> bool:
    return rel == os.curdir or rel == os.pardir or rel.startswith(os.pardir + os.sep)


def normalize_path(repo: str, p: str) -> Optional[str]:
    """`p` as a repo-relative POSIX path (`./a`, `a` and `<repo>/a` all give `a`), or None when it is
    empty, the repo itself, or outside the repo — lexically (`..`, an absolute path elsewhere) or
    through a symlink pointing out. The spelling is kept lexical, so an in-repo symlink keeps its name."""
    if not p or not p.strip() or "\0" in p:
        return None
    root_real, root_abs = os.path.realpath(repo), os.path.abspath(repo)
    rel = os.path.normpath(p)
    if os.path.isabs(p):
        rel = next((r for r in (os.path.relpath(os.path.normpath(p), b) for b in (root_abs, root_real))
                    if not _escapes(r)), os.path.relpath(os.path.realpath(p), root_real))
    if _escapes(rel):
        return None
    if _escapes(os.path.relpath(os.path.realpath(os.path.join(root_real, rel)), root_real)):
        return None
    return PurePath(rel).as_posix()


def _open_in_repo(repo: str, rel: str) -> Union[TextIO, str]:
    """`rel` opened as text, or the refusal reason: file-not-in-worktree (missing, not a regular file)
    or path-outside-repo (what was opened is not the in-repo file its path resolves to now)."""
    root = os.path.realpath(repo)
    full = os.path.join(root, rel)
    try:
        fd = os.open(full, os.O_RDONLY | os.O_NONBLOCK)
    except (OSError, ValueError):
        return "file-not-in-worktree"
    reason = "path-outside-repo"
    with contextlib.suppress(OSError):
        st, real = os.fstat(fd), os.path.realpath(full)
        if not _escapes(os.path.relpath(real, root)) and os.path.samestat(st, os.stat(real)):
            reason = "" if stat.S_ISREG(st.st_mode) else "file-not-in-worktree"
    if reason:
        os.close(fd)
        return reason
    return open(fd, encoding="utf-8", errors="replace")


def _window(fh: TextIO, line: int) -> Tuple[int, str]:
    """(lines read, whitespace-free text of lines line-W..line+W). Reading stops after the window, so a
    huge file costs only its first line+W lines; universal newlines count CRLF once; bad bytes are
    replaced, never raised."""
    seen, parts = 0, []
    for seen, text in enumerate(fh, start=1):
        if seen >= line - ANCHOR_WINDOW:
            parts.append("".join(text.split()))
        if seen >= line + ANCHOR_WINDOW:
            break
    return seen, "".join(parts)


def check_site(repo: str, path: str, line: int, anchor: Optional[str]) -> Optional[str]:
    """The refusal reason when `path:line` (and the anchor, when one is given) does not hold in the
    work tree, else None: path-outside-repo, file-not-in-worktree, line-out-of-range, anchor-not-at-line.
    Whether an anchor is REQUIRED is zuvo_backlog_admit.validate's call, not this one's."""
    rel = normalize_path(repo, path)
    if rel is None:
        return "path-outside-repo"
    opened = _open_in_repo(repo, rel)
    if isinstance(opened, str):
        return opened
    with opened as fh:
        if line < 1:
            return "line-out-of-range"
        try:
            count, window = _window(fh, line)
        except OSError:
            return "file-not-in-worktree"
    if count < line:
        return "line-out-of-range"
    needle = "".join((anchor or "").split())
    return "anchor-not-at-line" if needle and needle not in window else None


def check_target(target: str) -> Optional[str]:
    """`bad-target` unless the target is a URL, a hostname or `subject:<slug>` (the shapes live in
    zuvo_backlog_admit.target_kind, the one home of them)."""
    return None if adm.target_kind(target) is not None else "bad-target"


# ── branches ─────────────────────────────────────────────────────────────────────────────────────
def default_branch(repo: str) -> str:
    """Ported from hooks/lib/pipeline-gate-lib.sh pg_default_branch with the precedence REVERSED on
    purpose: there origin/HEAD wins and the env var is only a fallback. On TGM origin/HEAD points at
    `master` (it carries version tags and runs ahead) while the integration branch is `develop`, and
    only the env var can say so — with the gate's order every TGM entry would compare against master,
    tagging work that is already on develop and diffing against the wrong base."""
    env = os.environ.get("ZUVO_DEFAULT_BRANCH", "").strip()
    if env:
        return env
    head = _git(repo, "symbolic-ref", "--short", "-q", "refs/remotes/origin/HEAD") or ""
    return head[len("origin/"):] if head.startswith("origin/") and len(head) > 7 else "main"


def _default_shas(repo: str, default: str) -> list[str]:
    """Commit shas of the default branch: the local ref, then `origin/<default>` (worktrees often have
    only the remote ref). Full refnames, so a name can never be read as an option or a sha."""
    refs = (f"refs/heads/{default}", f"refs/remotes/origin/{default}")
    shas = (_git(repo, "rev-parse", "--verify", "-q", f"{r}^{{commit}}") for r in refs)
    return [s for s in shas if s]


def current_branch(repo: str) -> Optional[str]:
    """The checked-out branch name, or None on a detached HEAD (or outside git)."""
    return _git(repo, "symbolic-ref", "--short", "-q", "HEAD") or None


def head_sha7(repo: str) -> Optional[str]:
    """The 7-character HEAD sha, or None before the first commit."""
    return _git(repo, "rev-parse", "--short=7", "--verify", "-q", "HEAD") or None


# ── the tag ──────────────────────────────────────────────────────────────────────────────────────
def _explicit_pr(raw: Optional[str], what: str) -> Optional[str]:
    text = str(raw or "").strip()
    if not text:
        return None
    if not _PR_RE.fullmatch(text):
        raise ValueError(f"{what}: {text!r} is not a PR number")
    return text


def resolve_tag(repo: str, pr_arg: Optional[str]) -> Tag:
    """The entry's tag. No tag on the default branch (or detached on its sha); otherwise `--pr`, then
    ZUVO_BACKLOG_PR, then the open PR gh reports for the branch (github.com remotes only, cached), then
    `[branch:<name>]`. A detached HEAD elsewhere has no branch to name: `--pr`/env, else untaggable. A
    name outside the intake's charset with no PR is untaggable, never renamed.
    Raises ValueError when `--pr` or ZUVO_BACKLOG_PR is given and is not a positive integer."""
    pr = _explicit_pr(pr_arg, "--pr") or _explicit_pr(os.environ.get("ZUVO_BACKLOG_PR"), "ZUVO_BACKLOG_PR")
    default = default_branch(repo)
    branch = current_branch(repo)
    if branch is None:
        head = _git(repo, "rev-parse", "--verify", "-q", "HEAD^{commit}")
        if head and head in _default_shas(repo, default):
            return Tag(TAG_NONE, "")
        return Tag(TAG_PR, pr) if pr else Tag(TAG_UNTAGGABLE, "")
    if branch == default:
        return Tag(TAG_NONE, "")
    found = pr or _looked_up_pr(repo, branch)
    if found:
        return Tag(TAG_PR, found)
    return Tag(TAG_BRANCH, branch) if _BRANCH_OK_RE.fullmatch(branch) else Tag(TAG_UNTAGGABLE, branch)


def _gh_timeout() -> float:
    try:
        value = float(os.environ.get("ZUVO_GH_TIMEOUT", GH_TIMEOUT_DEFAULT_S))
    except ValueError:
        return GH_TIMEOUT_DEFAULT_S
    return value if value > 0 else GH_TIMEOUT_DEFAULT_S


def _looked_up_pr(repo: str, branch: str) -> Optional[str]:
    """The branch's own open PR number, through the 15-minute cache. Only a clean gh answer is cached
    (a number, or no own PR, so a PR-less branch does not ask gh on every call), never a failure, a
    timeout or garbage."""
    if os.environ.get("ZUVO_PR_LOOKUP", "1").strip() == "0":
        return None
    m = _GITHUB_RE.fullmatch((_git(repo, "remote", "get-url", "origin") or "").strip())
    if m is None:
        return None
    slug = f"{m.group(1)}/{m.group(2)}"
    key = f"{hashlib.sha256(slug.lower().encode('utf-8')).hexdigest()}\t{branch}"
    cached = _cache_get(key)
    if cached is not None:
        return cached or None
    # `=` binds each value to its flag, so a branch or slug can never be parsed as an option
    rc, out = _run(["gh", "pr", "list", f"--repo=github.com/{slug}", f"--head={branch}", "--state",
                    "open", "--json", "number,isCrossRepository"], repo, _gh_timeout())
    answer = _own_pr(out) if rc == 0 else None
    if answer is None:
        return None
    _cache_put(key, answer)
    return answer or None


def _own_pr(out: str) -> Optional[str]:
    """The newest same-repo PR in gh's JSON list, "" when there is none, None for anything else. `--head`
    matches the branch NAME, so a fork's PR from an equally named branch is listed too; only
    `isCrossRepository: false` is this branch's (that already pins the head owner to the base repo's)."""
    try:
        own = [str(p.get("number")) for p in json.loads(out) if p.get("isCrossRepository") is False]
    except (ValueError, TypeError, AttributeError):     # not JSON, not a list, not a list of objects
        return None
    return "" if not own else own[0] if _PR_RE.fullmatch(own[0]) else None


# ── PR cache: $HOME/.zuvo/cache/backlog-add-pr.tsv, rows `epoch \t sha256(owner/repo) \t branch \t pr`.
# Keyed by the slug gh is asked about, never the remote URL: a tokened remote (`https://ghp_…@github.com/…`)
# must not put its secret into a file under $HOME (CQ5), and ssh and https of one repo are one key.
def _cache_path() -> str:
    home = os.environ.get("HOME") or os.path.expanduser("~")
    return os.path.join(home, *PR_CACHE_PARTS)


def _private_dir(path: str) -> bool:
    """Create `path` 0700, or tighten it to 0700 when it exists open; False (no cache, live lookups)
    when it is not a real directory owned by us. makedirs' mode applies only to a directory it creates."""
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
        st = os.lstat(path)
        ours = stat.S_ISDIR(st.st_mode) and st.st_uid == os.geteuid()
        if ours and st.st_mode & 0o077:
            os.chmod(path, 0o700)
        return ours
    except OSError:
        return False


def _cache_rows(now: float) -> list[Tuple[float, str, str]]:
    """Fresh (epoch, key, pr) rows; unreadable files and malformed rows are skipped, never raised. A cache
    that is a symlink, not a regular file, not ours, or in a directory that is not private is a miss."""
    path = _cache_path()
    try:
        if not _private_dir(os.path.dirname(path)):
            return []
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with open(fd, encoding="utf-8", errors="replace") as fh:
            st = os.fstat(fd)
            lines = fh.read().splitlines() if stat.S_ISREG(st.st_mode) and st.st_uid == os.geteuid() else []
    except OSError:
        return []
    rows = [(float(m[1]), f"{m[2]}\t{m[3]}", m[4] or "") for m in map(_CACHE_ROW_RE.fullmatch, lines) if m]
    return [row for row in rows if 0 <= now - row[0] < PR_CACHE_TTL_S]


def _cache_get(key: str) -> Optional[str]:
    """The cached answer for `key` ("" = no open PR), or None when nothing fresh is cached."""
    hits = [(epoch, pr) for epoch, k, pr in _cache_rows(time.time()) if k == key]
    return max(hits)[1] if hits else None


def _cache_put(key: str, pr: str) -> None:
    """Rewrite the cache with expired rows and the old row for `key` dropped, via temp file + rename so
    a reader never sees a half-written file. A failure only costs the next call a gh lookup."""
    now = time.time()
    keep = [f"{epoch:.0f}\t{k}\t{p}" for epoch, k, p in _cache_rows(now) if k != key]
    path = _cache_path()
    try:
        if not _private_dir(os.path.dirname(path)):                     # rows name repos and branches
            raise OSError("cache directory missing, not ours or not private")
        fd, tmp = tempfile.mkstemp(prefix=".backlog-add-pr.", dir=os.path.dirname(path))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                fh.write("\n".join([*keep, f"{now:.0f}\t{key}\t{pr}"]) + "\n")
            os.replace(tmp, path)
        except OSError:
            with contextlib.suppress(OSError):
                os.unlink(tmp)
            raise
    except OSError as e:
        print(f"backlog-add: PR cache not written ({e.strerror or e})", file=sys.stderr)


# ── changed lines ────────────────────────────────────────────────────────────────────────────────
def _merge_base(repo: str, default: str) -> Optional[str]:
    bases = (_git(repo, "merge-base", "HEAD", sha) for sha in _default_shas(repo, default))
    return next((b for b in bases if b), None)


def changed_lines(repo: str, path: str, default: Optional[str] = None) -> Set[int]:
    """Line numbers of `path` (repo-relative) that the branch changed: `git diff -U0` from
    merge-base(HEAD, default) — the local default ref, else `origin/<default>` — to the WORK TREE, so
    committed and uncommitted edits both count. A file git lists as untracked and not ignored is changed
    in full. Anything unproven is the empty set: no merge-base, a path outside the repo or not one
    regular file (git would expand a directory to every file under it), an ignored file, or a tracked
    file spelled through a symlinked directory (git does not list it either way)."""
    rel = normalize_path(repo, path)
    opened = _open_in_repo(repo, rel) if rel is not None else "path-outside-repo"
    if rel is None or isinstance(opened, str):
        return set()
    with opened as fh:
        tracked = _git(repo, "ls-files", "--", rel)
        if tracked == "":
            new = _git(repo, "ls-files", "-z", "--others", "--exclude-standard", "--", rel)
            return _line_numbers(fh) if new == f"{rel}\0" else set()
    if tracked is None:
        return set()
    base = _merge_base(repo, default or default_branch(repo))
    diff = _git(repo, "diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", base, "--", rel) \
        if base else None
    lines: Set[int] = set()
    for m in _HUNK_RE.finditer(diff or ""):
        start, count = int(m.group(1)), int(m.group(2) or "1")
        lines.update(range(start, start + count))
    return lines


def _line_numbers(fh: TextIO) -> Set[int]:
    try:
        return {n for n, _ in enumerate(fh, start=1)}
    except OSError:
        return set()
