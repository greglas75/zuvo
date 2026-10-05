#!/usr/bin/env python3
"""Retire the review queue: remove what scripts/claude-home/scripts/post-commit-review-backlog.sh left
on a machine — run by install_claude_home (scripts/install.d/claude-home.sh) on every install.

    retire_review_queue.py <home> [--dry-run]

The script (installed to ~/.claude/scripts/, called from ~/.claude/hooks/post-commit) appended every
commit to ~/.claude/projects/<repo path, '/' -> '-'>/memory/review-backlog.md and, in every repository
with a docs/ directory, to an untracked docs/review-queue.md. Nothing read either file: review coverage
is content-keyed (memory/reviews/). It was removed on 2026-10-05; this undoes what it left behind:

  1. ~/.claude/hooks/post-commit — the line that runs the script (as $HOME, ~ or this home's absolute
     path) is dropped, when the script at that path is zuvo's (or already gone). Every other byte (line
     endings included), the file's mode and a symlink to it are kept: zuvo did not install this
     dispatcher, and it still chains each repository's own post-commit hook, which core.hooksPath would
     otherwise skip. Where dropping the line would leave something its shell (the shebang's: bash, or sh)
     cannot parse, or nothing at all, the line becomes the no-op `:` instead. A line that continues the
     one before it (after a `\\`) is not a command of its own and is never touched. A file changed since
     it was read is left as it is.
  2. ~/.claude/scripts/post-commit-review-backlog.sh — removed when it is zuvo's (carries SIGNATURE) and
     nothing will call it any more. A dispatcher line this cleanup does not recognise, an unreadable
     dispatcher, a failed rewrite, or a repository's own post-commit hook (in its git dir or its local
     core.hooksPath) that still calls it keeps it, so no commit runs a missing file.
  3. Each memory/review-backlog.md, and docs/review-queue.md in the repository its directory name
     encodes — only a regular file of at most MAX_BYTES still in the script's output format (a line of
     any other shape keeps it) and, for the queue, not tracked by git. Anything else is kept and named,
     with the reason. A queue is found only through its memory file: the script wrote both every time.

Every file is first copied into ~/.zuvo/archive/review-queue-retired-<UTC time>-<pid>.tar.gz, verified
by content, and when that fails nothing is touched. Just before a file is deleted it is judged again
and must still hold the bytes that went into the archive. A repository's own executable post-commit hook
that still calls the script is reported, never edited (the installer leaves every .git/hooks alone).

Exit status: 0 done, or nothing left; 1 a removal or rewrite failed (the rest went ahead); 2 the archive
could not be written (nothing changed); 64 bad arguments. Problems print one '  ! ' line each.
"""
import contextlib
import functools
import hashlib
import io
import os
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

USAGE = 'retire_review_queue.py <home> [--dry-run]'
SCRIPT_NAME = 'post-commit-review-backlog.sh'
SIGNATURE = '# Post-commit hook: adds new commit to review-backlog.md in Claude memory dir.'
_TAIL = r'/\.claude/scripts/' + re.escape(SCRIPT_NAME)


@functools.lru_cache(maxsize=8)
def call_re(home):
    """The dispatcher line that runs the script: `bash|sh <path>`, the path as $HOME, ${HOME}, ~ or <home>
    itself — unquoted, or quoted (then <home> may hold spaces) — optionally silenced and/or `|| true`. A
    line that does anything else, or names another home's copy, is not touched."""
    absolute = re.escape(home.rstrip(os.sep))
    quoted = r'(?:\$HOME|\$\{HOME\}|~|' + absolute + ')'
    # unquoted, a home holding whitespace is not one word: `bash /Users/A B/…` runs /Users/A
    bare = r'(?:\$HOME|\$\{HOME\}|~' + ('' if re.search(r'\s', home) else '|' + absolute) + ')'
    path = '"' + quoted + _TAIL + '"|\'' + quoted + _TAIL + "'|" + bare + _TAIL
    tail = r'(?:\s+2>\s*/dev/null)?(?:\s*\|\|\s*(?:true|:))?\s*$'
    return re.compile(r'^\s*(?:bash|sh)\s+(?:' + path + ')' + tail)
# What replaces a call line whose removal could change the dispatcher. It must not name the script: a
# dispatcher still naming it reads as "may still call it" on the next run.
NOOP = ':  # zuvo: the retired review-queue call was here (2026-10-05)'
BACKLOG_FIXED = {'# Review Backlog', 'Commits pending review. Managed by post-commit hook + /review skill.'}
BACKLOG_LINE = re.compile(r'^(?:## [A-Za-z ]+|- \[[ xX]\] [0-9a-f]{4,40}(?: .*)?)$')
QUEUE_FIXED = {'# Review Queue', 'Commits pending review. Auto-managed:',
               '- post-commit hook → adds new commits',
               '- `/review` after audit → removes reviewed commits',
               '- `/review mark-reviewed` → removes in bulk'}
QUEUE_LINE = re.compile(r'^- [0-9a-f]{4,40} \(\d{4}-\d{2}-\d{2}\)(?: .*)?$')
MAX_NAME_PARTS = 64            # bounds the path decode; a real repository path has far fewer components
MAX_BYTES = 16 * 1024 * 1024   # a generated list this large is not one; larger files are kept, unread
TIMEOUT = 20                   # seconds per git or `bash -n` call: a hung child must not hang the installer


def generated(text, header, fixed, line_re):
    """True when <text> holds nothing the script would not have written: its header first, then only its
    fixed lines, blank lines and lines of its entry shape (a commit hash first). A line of any other shape
    makes it a file to keep; an entry someone typed in the script's own shape cannot be told apart, and
    is in the archive."""
    lines = text.split('\n')
    return lines[0] == header and all(not ln or ln in fixed or line_re.match(ln) for ln in lines[1:])


def read_text(path):
    """The file's text exactly as stored (no newline translation), or None when it is not a regular file
    (a FIFO would block the read), unreadable, larger than MAX_BYTES or not UTF-8 (such a file is kept)."""
    if not os.path.isfile(path):
        return None
    try:
        with open(path, 'rb') as f:
            data = f.read(MAX_BYTES + 1)
        return None if len(data) > MAX_BYTES else data.decode('utf-8')
    except (OSError, UnicodeError):
        return None


def regular(path):
    return os.path.isfile(path) and not os.path.islink(path)


def format_verdict(path, header, fixed, line_re):
    """None when <path> is a regular file holding only the script's output, else why it is kept."""
    if not regular(path):
        return 'a symlink or not a regular file'
    with contextlib.suppress(OSError):
        if os.path.getsize(path) > MAX_BYTES:
            return 'larger than %d bytes — not read' % MAX_BYTES
    text = read_text(path)
    if text is None:
        return 'unreadable or not UTF-8 text'
    return None if generated(text, header, fixed, line_re) else 'not the generated format (edited by hand?)'


@functools.lru_cache(maxsize=4096)
def entries(directory):
    try:
        return tuple(os.listdir(directory))
    except OSError:
        return ()


def repo_roots(dir_name):
    """The existing directories whose path, with '/' replaced by '-', is <dir_name> — the script's encoding.
    '-' also occurs inside path components (zuvo-plugin), so a '-' is a separator only where the prefix up
    to it is an existing directory, and joins a component only where some entry there starts that way —
    the walk follows the filesystem, never every split. Two directories can encode alike; each is
    returned, normalised."""
    if not dir_name.startswith('-'):
        return []
    parts = dir_name[1:].split('-')
    if len(parts) > MAX_NAME_PARTS:
        return []
    found = []

    def walk(base, i, comp):
        here = os.path.join(base, comp)
        if i == len(parts):
            if comp not in ('', '.', '..') and os.path.isdir(here):
                found.append(os.path.normpath(here))
            return
        if comp not in ('', '.', '..') and os.path.isdir(here):
            walk(here, i + 1, parts[i])
        joined = comp + '-' + parts[i]
        if any(e.startswith(joined) for e in entries(base)):
            walk(base, i + 1, joined)

    walk('/', 1, parts[0])
    return found


def run(argv, stdin=None):
    """(exit status, stdout) of <argv>, or (None, '') when it cannot be run or does not finish in time."""
    try:
        p = subprocess.run(argv, input=stdin, capture_output=True, text=True, encoding='utf-8',
                           errors='replace', timeout=TIMEOUT)
    except (OSError, subprocess.SubprocessError):
        return None, ''
    return p.returncode, p.stdout.strip()


def git(root, *args):
    return run(['git', '-C', root, *args])


def queue_verdict(root, queue):
    """None when <queue> may be deleted, else the reason it is kept. `ls-files --error-unmatch` exits 1
    exactly when the path is unknown to git; its other failures exit 128."""
    reason = format_verdict(queue, '# Review Queue', QUEUE_FIXED, QUEUE_LINE)
    if reason:
        return reason
    rc, top = git(root, 'rev-parse', '--show-toplevel')
    if rc is None:
        return 'git could not be run to tell whether it is tracked'
    if rc != 0 or os.path.realpath(top) != os.path.realpath(root):
        return 'not at the root of a git work tree'
    rc, _ = git(root, 'ls-files', '--error-unmatch', '--', 'docs/review-queue.md')
    if rc == 0:
        return 'tracked in git — remove it with a commit in that repository'
    return None if rc == 1 else 'git could not tell whether it is tracked'


def repo_hooks_calling_script(root, dispatcher):
    """The repository's own executable post-commit hooks that still name the script: the one in its git
    common dir, and the one its local core.hooksPath (Husky and the like) points at — `--git-path hooks/…`
    answers with core.hooksPath, which is the shared dispatcher unless the repository overrides it; that
    shared one is handled as the dispatcher, not here. Without git, the plain <root>/.git/hooks is read.
    A linked worktree's common dir is absolute and shared with its main checkout: both name the same hook."""
    candidates = []
    rc, common = git(root, 'rev-parse', '--git-common-dir')
    if rc is None:
        candidates.append(os.path.join(root, '.git', 'hooks', 'post-commit'))
    elif rc == 0 and common:
        candidates.append(os.path.join(root, common, 'hooks', 'post-commit'))
    rc, configured = git(root, 'rev-parse', '--git-path', 'hooks/post-commit')
    if rc == 0 and configured:
        candidates.append(os.path.join(root, configured))
    found = []
    for hook in (os.path.normpath(c) for c in candidates):
        if hook in found or os.path.realpath(hook) == os.path.realpath(dispatcher):
            continue
        text = read_text(hook)
        if text is not None and SCRIPT_NAME in text and os.access(hook, os.X_OK):
            found.append(hook)
    return found


def call_lines(lines, home):
    """Indexes of the lines that run the script as a command of their own: a matching line that continues
    the one before it (after a `\\`) is part of that command, not a call, and is never touched."""
    pattern = call_re(home)
    return [i for i, ln in enumerate(lines)
            if pattern.match(ln) and not (i > 0 and lines[i - 1].rstrip('\r').endswith('\\'))]


def without_call(text, calls):
    """<text> with the lines at <calls> dropped — unless nothing but blank lines would remain, or the
    shell the shebang names (bash, else sh) cannot parse the result (or cannot be run to tell): then each
    of those lines becomes NOOP at its own indentation."""
    lines = text.split('\n')
    dropped = '\n'.join(ln for i, ln in enumerate(lines) if i not in calls)
    shell = 'bash' if 'bash' in lines[0] else 'sh'
    if dropped.strip() and run([shell, '-n'], stdin=dropped)[0] == 0:
        return dropped
    return '\n'.join(re.match(r'\s*', ln).group(0) + NOOP + ('\r' if ln.endswith('\r') else '')
                     if i in calls else ln for i, ln in enumerate(lines))


def plan_script(home, kept):
    """(path, zuvo's?) — None when there is no installed script; a foreign one is kept and named here."""
    script = os.path.join(home, '.claude', 'scripts', SCRIPT_NAME)
    if not os.path.lexists(script):
        return None
    text = read_text(script) if regular(script) else None
    if text is None or SIGNATURE not in text:
        kept.append((script, 'not the copy zuvo installed'))
        return script, False
    return script, True


def plan_dispatcher(home, ours, kept):
    """(rewrite, still_calls). rewrite = (real path, its text as read, its text without the call) or None;
    still_calls = after this cleanup the dispatcher may still run the script. The call is dropped only
    when the script it runs is zuvo's (<ours>) or gone: a user's own file of that name stays hooked."""
    dispatcher = os.path.join(home, '.claude', 'hooks', 'post-commit')
    real = os.path.realpath(dispatcher)
    if not os.path.isfile(real):
        return None, False
    text = read_text(real)
    if text is None:
        kept.append((dispatcher, 'unreadable or not UTF-8 text — cannot tell whether it calls the script'))
        return None, True
    lines = text.split('\n')
    calls = call_lines(lines, home)
    rest = [ln for i, ln in enumerate(lines) if i not in calls]
    if calls and ours is False:
        kept.append((dispatcher, 'calls a same-named script that is not zuvo\'s — left as it is'))
        return None, True
    rewrite = (real, text, without_call(text, calls)) if calls else None
    if any(SCRIPT_NAME in ln for ln in rest):
        kept.append((dispatcher, 'names the script in a line this cleanup does not recognise'))
        return rewrite, True
    return rewrite, False


def plan_queue(root, home, delete, kept, hooks):
    queue = os.path.join(root, 'docs', 'review-queue.md')
    if os.path.lexists(queue):
        reason = queue_verdict(root, queue)
        if reason:
            kept.append((queue, reason))
        else:
            delete.append((queue, functools.partial(queue_verdict, root, queue)))
    dispatcher = os.path.join(home, '.claude', 'hooks', 'post-commit')
    hooks.extend(h for h in repo_hooks_calling_script(root, dispatcher) if h not in hooks)


def backlog_verdict(backlog):
    return format_verdict(backlog, '# Review Backlog', BACKLOG_FIXED, BACKLOG_LINE)


def plan_projects(home, delete, kept, hooks):
    """Each memory backlog, and through its directory name the repository it was written for."""
    projects = os.path.join(home, '.claude', 'projects')
    try:
        names = sorted(os.listdir(projects)) if os.path.isdir(projects) else []
    except OSError as e:
        kept.append((projects, 'could not be listed (%s)' % e))
        return
    for name in names:
        backlog = os.path.join(projects, name, 'memory', 'review-backlog.md')
        if not os.path.lexists(backlog):
            continue
        reason = backlog_verdict(backlog)
        if reason:
            kept.append((backlog, reason))
        else:
            delete.append((backlog, functools.partial(backlog_verdict, backlog)))
        for root in repo_roots(name):
            plan_queue(root, home, delete, kept, hooks)


def script_verdict(script):
    text = read_text(script) if regular(script) else None
    return None if text is not None and SIGNATURE in text else 'no longer the copy zuvo installed'


def plan(home):
    """(deletions as (path, recheck) pairs, the dispatcher rewrite or None, [(path, reason) kept],
    [repository post-commit hooks that still call the script]). recheck() re-judges a file just before it
    is deleted: None while it may still go, else the reason it is kept."""
    delete, kept, hooks = [], [], []
    script = plan_script(home, kept)
    rewrite, still_calls = plan_dispatcher(home, script[1] if script else None, kept)
    plan_projects(home, delete, kept, hooks)
    if script and script[1]:
        if still_calls or hooks:
            why = 'the dispatcher' if still_calls else 'a repository post-commit hook (below)'
            kept.append((script[0], '%s may still call it — kept, so no commit runs a missing file' % why))
        else:
            delete.insert(0, (script[0], functools.partial(script_verdict, script[0])))
    return delete, rewrite, kept, hooks


def write_archive(home, paths):
    """(archive path, {path: sha256 of the bytes archived}) for a new
    ~/.zuvo/archive/review-queue-retired-<UTC>-<pid>.tar.gz holding <paths> (members named by their
    normalised absolute paths). Each file is read once; those bytes are archived and hashed, and the
    archive is read back and checked member by member against the hashes before it is kept. Written
    under a temporary name and renamed once complete; OSError/tarfile.TarError on any failure, with no
    temporary file left."""
    folder = os.path.join(home, '.zuvo', 'archive')
    os.makedirs(folder, exist_ok=True)
    final = os.path.join(folder, 'review-queue-retired-%s-%d.tar.gz'
                         % (time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()), os.getpid()))
    fd, temporary = tempfile.mkstemp(prefix='.review-queue-retired.', suffix='.tmp', dir=folder)
    os.close(fd)
    digests, names = {}, {}
    try:
        with tarfile.open(temporary, 'w:gz') as tar:
            for p in paths:
                with open(p, 'rb') as f:
                    data = f.read(MAX_BYTES + 1)
                if len(data) > MAX_BYTES:
                    raise tarfile.TarError('%s grew past %d bytes since it was judged' % (p, MAX_BYTES))
                info = tar.gettarinfo(p, arcname=os.path.normpath(p).lstrip(os.sep))
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
                digests[p] = hashlib.sha256(data).hexdigest()
                names[info.name] = digests[p]
        with tarfile.open(temporary, 'r:gz') as tar:
            members = tar.getmembers()
            for member in members:
                member_file = tar.extractfile(member)
                got = hashlib.sha256(member_file.read()).hexdigest() if member_file else None
                if got is None or got != names.get(member.name):
                    raise tarfile.TarError('archive member %s does not hold the bytes read' % member.name)
            if len(members) != len(paths):
                raise tarfile.TarError('archive holds %d of %d files' % (len(members), len(paths)))
        os.replace(temporary, final)
        return final, digests
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def replace_unchanged(real, before, text):
    """Write <text> over <real> through a temp file beside it, keeping its mode and its bytes as written
    (no newline translation) — unless <real> no longer holds <before> (something rewrote it since it was
    read). True written, False left as it is. The check and the replace are two steps: this narrows the
    window a concurrent writer has; no lock every writer of this file honours exists to close it."""
    mode = stat.S_IMODE(os.stat(real).st_mode)
    fd, temporary = tempfile.mkstemp(prefix='.post-commit.', suffix='.tmp', dir=os.path.dirname(real))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temporary, mode)
        if read_text(real) != before:
            return False
        os.replace(temporary, real)
        return True
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def drop_call(rewrite):
    """Rewrite the dispatcher without the call; True done, False not done (and said why)."""
    real, before, after = rewrite
    try:
        if replace_unchanged(real, before, after):
            return True
        print('  ! review queue: %s changed while it was being cleaned — left as it is; rerun the install'
              % real)
    except OSError as e:
        print('  ! review queue: could not rewrite %s (%s) — it still calls the script' % (real, e))
    return False


def unchanged_since_archive(path, digest):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read(MAX_BYTES + 1)).hexdigest() == digest


def remove_all(delete, digests):
    """(paths removed, number that failed). Each (path, recheck) is judged again first, and removed only
    while recheck() still allows it and the file holds the bytes archived; a memory dir the backlog alone
    filled goes with it; a file already gone (a concurrent install) is skipped."""
    removed, failed = [], 0
    for p, recheck in delete:
        try:
            reason = recheck()
            if reason is None and not unchanged_since_archive(p, digests.get(p)):
                reason = 'it changed after it was archived'
            if reason:
                print('  ! review queue: kept %s — %s' % (p, reason))
                continue
            os.unlink(p)
        except FileNotFoundError:
            continue
        except OSError as e:
            print('  ! review queue: could not remove %s (%s)' % (p, e))
            failed += 1
            continue
        removed.append(p)
        if p.endswith(os.path.join('memory', 'review-backlog.md')):
            with contextlib.suppress(OSError):   # only when the script's file was all the dir held
                os.rmdir(os.path.dirname(p))
    return removed, failed


def report_kept(kept, hooks):
    for path, reason in kept:
        print('  ! review queue: kept %s — %s' % (path, reason))
    for hook in hooks:
        print('  ! review queue: %s still runs the retired %s — delete that line by hand'
              % (hook, SCRIPT_NAME))


def summary(removed, call_dropped, archive):
    backlogs = sum(p.endswith('review-backlog.md') for p in removed)
    queues = sum(p.endswith('review-queue.md') for p in removed)
    extras = [s for s, on in (('the installed script', any(p.endswith(SCRIPT_NAME) for p in removed)),
                              ('its call in ~/.claude/hooks/post-commit', call_dropped)) if on]
    return ('  ✓ review queue retired: %d memory backlog(s), %d repository queue file(s)%s — archived in %s'
            % (backlogs, queues, ''.join(', ' + s for s in extras), archive))


def retire(home, dry_run=False):
    delete, rewrite, kept, hooks = plan(home)
    report_kept(kept, hooks)
    if not delete and rewrite is None:
        return 0
    if dry_run:
        for p, _ in delete:
            print('  (dry run) would remove %s' % p)
        if rewrite:
            print('  (dry run) would drop the %s call from %s' % (SCRIPT_NAME, rewrite[0]))
        return 0
    try:
        archive, digests = write_archive(home, [p for p, _ in delete] + ([rewrite[0]] if rewrite else []))
    except (OSError, tarfile.TarError) as e:
        print('  ! review queue: could not write the archive under %s/.zuvo/archive (%s) — nothing removed'
              % (home, e))
        return 2
    call_dropped = drop_call(rewrite) if rewrite else False
    script = os.path.join(home, '.claude', 'scripts', SCRIPT_NAME)
    if rewrite and not call_dropped and any(p == script for p, _ in delete):
        # still called: a missing file would fail every commit
        delete = [(p, r) for p, r in delete if p != script]
        print('  ! review queue: kept %s — the dispatcher still calls it' % script)
    removed, failed = remove_all(delete, digests)
    print(summary(removed, call_dropped, archive))
    return 1 if failed or (rewrite and not call_dropped) else 0


if __name__ == '__main__':
    args = sys.argv[1:]
    dry = '--dry-run' in args
    rest = [a for a in args if a != '--dry-run']
    if len(rest) != 1 or not os.path.isdir(rest[0]):
        print('  ! retire_review_queue.py: bad arguments %r — usage: %s' % (args, USAGE))
        sys.exit(64)
    sys.exit(retire(os.path.abspath(rest[0]), dry))
