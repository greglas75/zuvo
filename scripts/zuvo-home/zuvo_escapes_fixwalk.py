"""Which commits fix a defect, and which first-parent commit brought each commit onto the ref.

A fix is a commit reachable from the ref whose subject says so: a merge of a fix branch ("Merged in
fix/... (pull request #N)" — a squash, single-parent commit on Bitbucket — "Merge branch 'fix/...'",
"Merge pull request #N from x/fix/...", hotfix/ and bugfix/ alike) or a conventional commit
("fix(scope): ...", "fix: ..."). A true merge of a fix branch is one fix whose change is its diff
against the first parent; the commits it brought in are then not fixes of their own, or one defect
would be written twice (counted as skipped `in_fix_merge`).

The landing of a commit is the first-parent commit of the ref that brought it in: itself when it is on
the first-parent chain (a squash merge), else the merge whose second side contains it, whatever the
commit's own date. Its time is that first-parent commit's committer time.

Windows (--since, --max-age) are cut on the first-parent chain, newest first: it is in the window up to
the last first-parent commit at or after the cutoff, and ends only once SKEW_RUN consecutive older ones
follow. One commit with a clock far behind therefore sits inside the window instead of ending it, and
the fixes picked are exactly those whose landing is in the window — a fix committed weeks ago on a
branch merged yesterday is in a 30-day window.
"""

from __future__ import annotations

import datetime as dt
import os
import re
import subprocess
from collections.abc import Mapping
from typing import NamedTuple

from zuvo_review_ledger import project_key

GIT_TIMEOUT = 120
FETCH_TIMEOUT = 300
SKEW_RUN = 10
DEFAULT_BRANCHES = ("develop", "main", "master")
FALLBACK_REFS = ("origin/develop", "origin/main")
# Set by git for hooks and by wrappers; any of them would point a `git -C repo` call at another repository.
REPO_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX")
# Config that would change output this module and its callers parse, pinned whatever the user's says:
# log.showSignature puts gpg's lines into every log/show; quotepath is the form the path parsers expect.
PINNED = ("-c", "core.quotepath=off", "-c", "log.showSignature=false")
_DURATION = re.compile(r"^([1-9][0-9]{0,4})([hdw])$")
_UNIT = {"h": dt.timedelta(hours=1), "d": dt.timedelta(days=1), "w": dt.timedelta(weeks=1)}
_FIX_BRANCH = r"(?:fix|hotfix|bugfix)/"
_FIX_SUBJECT = re.compile(
    rf"^(?:Merged in {_FIX_BRANCH}|Merge branch '{_FIX_BRANCH}"
    rf"|Merge pull request #[0-9]+ from [^/\s]+/{_FIX_BRANCH}"
    r"|(?:fix|hotfix|bugfix)(?:\([^)]*\))?!?:\s)", re.IGNORECASE)


class GitError(RuntimeError):
    """A git command failed or timed out; the message names the command and git's last stderr line."""


class Commit(NamedTuple):
    sha: str
    parents: tuple[str, ...]
    ts: int
    subject: str


class Landing(NamedTuple):
    sha: str
    ts: int


def parse_duration(text: str) -> dt.timedelta:
    """`30d`, `12h`, `2w` -> timedelta. Anything else (no unit, zero, negative) raises ValueError."""
    m = _DURATION.match(text.strip())
    if not m:
        raise ValueError(f"not a duration like 30d, 12h or 2w: {text!r}")
    return int(m.group(1)) * _UNIT[m.group(2)]


def git(repo: str, *args: str, timeout: int = GIT_TIMEOUT, env: Mapping[str, str] | None = None) -> str:
    cmd = ["git", "--literal-pathspecs", "-C", repo, *PINNED, *args]
    name = next((a for a in args if not a.startswith("-") and "=" not in a), "git")
    clean = {k: v for k, v in (os.environ if env is None else env).items() if k not in REPO_ENV}
    try:
        # surrogateescape: a non-UTF-8 path byte survives the round trip back into a git argv
        proc = subprocess.run(cmd, capture_output=True, text=True, errors="surrogateescape", timeout=timeout,
                              stdin=subprocess.DEVNULL, env=clean)
    except subprocess.TimeoutExpired as exc:
        raise GitError(f"git {name} timed out after {timeout}s") from exc
    except OSError as exc:
        raise GitError(f"git {name} could not start: {exc}") from exc
    if proc.returncode != 0:
        last = (proc.stderr.strip().splitlines() or ["no output"])[-1]
        raise GitError(f"git {name} failed (rc {proc.returncode}): {last}")
    return proc.stdout


def project_of(repo: str) -> str:
    """The store name of `repo`: its main checkout's basename. A linked worktree's main checkout is the
    directory that holds the shared .git, so every worktree of one repo feeds one store."""
    top = git(repo, "rev-parse", "--show-toplevel").strip()
    common = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").strip().rstrip("/")
    main = os.path.dirname(common) if os.path.basename(common) == ".git" else common.removesuffix(".git")
    return project_name(main, top)


def project_name(main_checkout: str, toplevel: str) -> str:
    """The main checkout's basename, else the checkout's own; never a shared placeholder, which would
    pour unrelated repositories into one store. Raises GitError when neither has a name."""
    name = project_key(main_checkout) or project_key(toplevel)
    if not name:
        raise GitError(f"cannot name the project of {toplevel}")
    return name


def shallow_commits(repo: str) -> frozenset[str]:
    """The graft commits of a shallow clone (empty for a full one): blame stops at them, so they look
    like the introducer of everything older."""
    path = git(repo, "rev-parse", "--git-path", "shallow").strip()
    try:
        with open(os.path.join(repo, path), encoding="utf-8") as f:
            return frozenset(f.read().split())
    except FileNotFoundError:
        return frozenset()


def resolve_ref(repo: str, ref: str) -> str:
    try:
        return git(repo, "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}").strip()
    except GitError as exc:
        raise GitError(f"ref {ref} does not resolve to a commit in {repo}") from exc


def default_ref(repo: str) -> str:
    """The ref a run reads when --ref is not given: the upstream of the first local branch among
    DEFAULT_BRANCHES that exists, else the first FALLBACK_REFS entry that resolves (else the first,
    which then fails to resolve with a clear error). `origin` is not assumed to be the live remote: a
    clone can track another one while `origin` is a stale mirror. The upstream is read from the branch
    config, so it is known even before its remote-tracking ref has been fetched."""
    out = git(repo, "for-each-ref", "--format=%(refname)%00%(upstream:short)", "refs/heads/")
    upstreams = dict(line.split("\0", 1) for line in out.splitlines() if "\0" in line)
    branch = next((b for b in DEFAULT_BRANCHES if f"refs/heads/{b}" in upstreams), None)
    if branch and upstreams[f"refs/heads/{branch}"]:
        return upstreams[f"refs/heads/{branch}"]
    for ref in FALLBACK_REFS:
        try:
            resolve_ref(repo, ref)
            return ref
        except GitError:
            continue
    return FALLBACK_REFS[0]


def fetch_env(repo: str, environ: Mapping[str, str]) -> dict[str, str]:
    """`environ` for a fetch that never prompts: a scheduled run has nobody to answer. BatchMode ssh
    is added only when nothing chooses the ssh command: not GIT_SSH_COMMAND, GIT_SSH or GIT_SSH_VARIANT
    (git prefers an injected GIT_SSH_COMMAND over all of them), nor the repo's core.sshCommand (a deploy
    key lives there)."""
    env = {**environ, "GIT_TERMINAL_PROMPT": "0"}
    try:
        configured = bool(git(repo, "config", "--get", "core.sshCommand").strip())
    except GitError:
        configured = False
    chosen = any(env.get(k) for k in ("GIT_SSH_COMMAND", "GIT_SSH", "GIT_SSH_VARIANT"))
    if not chosen and not configured:
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
    return env


def fetch(repo: str, ref: str) -> None:
    """Fetch the branch of the remote `ref` names. The remote is the longest configured remote name
    that prefixes it (remote names may hold a slash); a ref naming no remote is an error."""
    remote = max((r for r in git(repo, "remote").split() if ref.startswith(r + "/")), key=len, default=None)
    if remote is None:
        raise GitError(f"--fetch: {ref} names no remote of {repo} (expected <remote>/<branch>)")
    git(repo, "fetch", "--quiet", remote, ref[len(remote) + 1:], timeout=FETCH_TIMEOUT,
        env=fetch_env(repo, os.environ))


def resolve_run(repo: str, ref: str | None, do_fetch: bool) -> tuple[str, str, str]:
    """(project, ref name, the sha that name pointed at). Every later git call reads the sha, so a
    ref that moves during the run cannot mix two histories."""
    project = project_of(repo)
    name = ref or default_ref(repo)
    if do_fetch:
        fetch(repo, name)
    return project, name, resolve_ref(repo, name)


def is_fix_subject(subject: str) -> bool:
    return bool(_FIX_SUBJECT.match(subject.strip()))


def first_parent_chain(repo: str, ref: str) -> list[tuple[str, int, list[str]]]:
    """(sha, committer time, parents) of each first-parent commit of `ref`, newest first."""
    out = git(repo, "log", "--first-parent", "--format=%H %ct %P", ref)
    return [(sha, int(ts), parents) for sha, ts, *parents in (line.split() for line in out.splitlines())]


def window_end(chain: list[tuple[str, int, list[str]]], cutoff_ts: int) -> int:
    """How many leading chain entries are in the window of `cutoff_ts` (see the module docstring)."""
    end = older = 0
    for i, (_, ts, _parents) in enumerate(chain):
        if ts >= cutoff_ts:
            end, older = i + 1, 0
        else:
            older += 1
            if older >= SKEW_RUN:
                break
    return end


def walk_fixes(repo: str, ref: str, since_ts: int) -> tuple[list[Commit], dict[str, int]]:
    """(fix commits whose landing is in the --since window; skip counts by reason). A merge's change is
    parents[0]..sha. Skipped: `in_fix_merge`, a fix-named commit some fix merge brought in (an inner fix
    merge included: claims never release), and `root_fix`, a fix with no parent to diff against (the
    first commit, or a shallow clone's graft)."""
    chain = first_parent_chain(repo, ref)
    end = window_end(chain, since_ts)
    if end == 0:
        return [], {}
    bound = [f"^{chain[end][0]}"] if end < len(chain) else []
    # NUL ends each record (-z) and the subject is the last field, split off at most three times: a
    # subject may hold any other byte, the separators included.
    out = git(repo, "log", "-z", ref, *bound, "--format=%H%x1f%P%x1f%ct%x1f%s")
    found: list[Commit] = []
    for rec in out.split("\0"):
        fields = rec.split("\x1f", 3)
        if len(fields) == 4 and is_fix_subject(fields[3]):
            found.append(Commit(fields[0], tuple(fields[1].split()), int(fields[2]), fields[3]))
    claimed: set[str] = set()
    for c in found:
        if len(c.parents) > 1:
            claimed |= set(git(repo, "rev-list", c.sha, f"^{c.parents[0]}").split()) - {c.sha}
    kept = [c for c in found if c.sha not in claimed]
    fixes = [c for c in kept if c.parents]
    return fixes, {"in_fix_merge": len(found) - len(kept), "root_fix": len(kept) - len(fixes)}


def landing_map(repo: str, ref: str, cutoff_ts: int) -> dict[str, Landing]:
    """commit sha -> its landing, for every commit landed by a first-parent commit in the window of
    `cutoff_ts`. Each merge contributes what it brought in beyond its first parent, so every commit
    lands at the earliest merge that contains it."""
    chain = first_parent_chain(repo, ref)
    landings: dict[str, Landing] = {}
    for sha, ts, parents in chain[:window_end(chain, cutoff_ts)]:
        landing = Landing(sha, ts)
        landings[sha] = landing
        if len(parents) > 1:
            for brought in git(repo, "rev-list", sha, f"^{parents[0]}").split():
                landings.setdefault(brought, landing)
    return landings
