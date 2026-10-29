"""claude_cache.py — the Claude Code plugin cache's registry entries and old version dirs.
Called by install_claude (claude.sh).

  registry <installed_plugins.json> <cache-base> <current-version> [<sha>]
  prune    <installed_plugins.json> <cache-base> <current-version>

A Claude Code session reads `installPath` once, when it starts, and loads its hooks from that dir for
as long as it runs. Deleting the dir under it turns every plugin hook into "Plugin directory does not
exist: …/zuvo/<version>" until that session is restarted. Sessions outlive many releases
(release-autoinstall installs several a day), so keeping only the newest dirs is not enough.

prune keeps a version dir that is any of:
  - the current version, or the newest other one (the previous rule, kept as a floor);
  - named by an installPath in installed_plugins.json (any scope — a project-scope entry is loaded
    by every session started in that project);
  - in use: Claude Code writes `.in_use/<pid>` into the dir each session loads, and the pid is alive.
    A dead pid's marker does not count. A pid reused by another process keeps the dir longer — only
    disk, never a broken session; so does a zombie's. A marker is read as a pid by its name, or by
    the "pid" field of its content when the name is not one. Where liveness cannot be checked
    (Windows, Cygwin/MSYS: os.kill(pid, 0) would terminate the process there), or the `.in_use` dir
    cannot be listed, the dir is kept.

prune removes nothing, and exits 1, when installed_plugins.json exists but does not parse or is not
a plugin registry: it cannot say which dirs the registry names. A missing registry names none.

registry stamps <sha> on every zuvo entry of this cache (the stale-SHA workaround) and repoints an entry whose
installPath (inside this cache) is no longer loadable to the current version dir, when that dir is
loadable: an entry on a deleted dir breaks every session started in its project. It replaces the
file atomically, and leaves it alone when it changed while being checked.
"""
import json
import os
import re
import shutil
import stat
import sys
import tempfile

PLUGIN_KEY = 'zuvo@zuvo-marketplace'
# A version dir's name: 1.6.115. Claude Code also creates SHA-named dirs beside them; those never
# take the newest-other slot.
VERSION_RE = re.compile(r'\d+(\.\d+)+')
# A marker name that is a pid. Not "0" (os.kill(0, 0) signals the whole process group, always
# "alive"); at most 7 digits, above every pid_max (Linux 4194304), so os.kill never overflows.
PID_RE = re.compile(r'[1-9][0-9]{0,6}')
MARKER_MAX = 4096


class Unreadable(Exception):
    """installed_plugins.json exists but cannot be read, parsed, or is not a registry."""


def _entries(data):
    entries = data.get('plugins', {}).get(PLUGIN_KEY, [])
    return [e for e in entries if isinstance(e, dict)]


def _load(path):
    """The registry's data; {} when the file does not exist. Raises Unreadable otherwise: a file that
    is half-written, corrupt or of another shape says nothing about which dirs it names."""
    try:
        with open(path, encoding='utf-8') as f:
            data = json.load(f)
    except FileNotFoundError as e:
        if os.path.lexists(path):          # a dangling symlink: the registry is elsewhere, not absent
            raise Unreadable('%s: %s' % (path, e))
        return {}
    except (OSError, ValueError) as e:
        raise Unreadable('%s: %s' % (path, e))
    plugins = data.get('plugins') if isinstance(data, dict) else None
    entries = plugins.get(PLUGIN_KEY, []) if isinstance(plugins, dict) else None
    if not isinstance(entries, list):
        raise Unreadable('%s: not a plugin registry' % path)
    return data


def _write_atomic(path, data, mtime):
    """Replace the registry. Claude Code reads it at every session start, so a reader never sees a
    truncated file. Returns False, leaving the registry as it is, when the file changed since it was
    read (a session or another installer wrote it); the next install fixes it. Claude Code takes no
    lock, so this narrows the lost-update window to the stat before os.replace; it cannot close it."""
    target = os.path.realpath(path)
    mode = stat.S_IMODE(os.stat(target).st_mode)
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(target) + '.', suffix='.zuvo.tmp',
                               dir=os.path.dirname(target))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            os.fchmod(f.fileno(), mode)    # the registry's own mode, exactly; a create mode goes through the umask
            json.dump(data, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        if os.stat(target).st_mtime_ns != mtime:
            return False
        os.replace(tmp, target)
    finally:
        if os.path.lexists(tmp):
            os.unlink(tmp)
    try:                                   # durability of the rename; macOS rejects fsync on a dir
        dfd = os.open(os.path.dirname(target), os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass
    return True


def _loadable(version_dir):
    return os.path.isfile(os.path.join(version_dir, '.claude-plugin', 'plugin.json'))


def _in_cache(path, base):
    return isinstance(path, str) and path != '' and \
        os.path.dirname(os.path.realpath(os.path.expanduser(path))) == base


def registry(plugins_json, cache_base, current, sha):
    try:
        mtime = os.stat(os.path.realpath(plugins_json)).st_mtime_ns
        data = _load(plugins_json)
    except FileNotFoundError:
        return 0
    except (OSError, Unreadable) as e:
        print('  ⚠ installed_plugins.json not checked: %s' % e, file=sys.stderr)
        return 1
    current_dir = os.path.join(cache_base, current)
    base = os.path.realpath(cache_base)
    changed = []
    for entry in _entries(data):
        path = entry.get('installPath')
        # Only entries of this cache: an installPath elsewhere (a dev checkout) is the user's.
        if not _in_cache(path, base):
            continue
        if sha and entry.get('gitCommitSha') != sha:
            entry['gitCommitSha'] = sha
            changed.append('sha')
        # Not loadable covers a dir that is gone and one a failed removal left without its manifest.
        if not _loadable(os.path.expanduser(path)) and _loadable(current_dir):
            entry['installPath'] = current_dir
            entry['version'] = current
            changed.append('repointed %s entry %s -> %s' % (entry.get('scope', '?'), path, current))
    if not changed:
        return 0
    try:
        written = _write_atomic(plugins_json, data, mtime)
    except OSError as e:
        print('  ⚠ installed_plugins.json not updated: %s' % e, file=sys.stderr)
        return 1
    if not written:
        print('  ⚠ installed_plugins.json changed while it was checked — left as it is', file=sys.stderr)
        return 1
    if 'sha' in changed:
        print('  ✓ Fixed stale SHA in installed_plugins.json')
    for line in changed:
        if line != 'sha':
            print('  ✓ installed_plugins.json: %s (its dir was gone)' % line)
    return 0


def _version_key(name):
    # `sort -V` order: digit runs compare as numbers. (0, n) / (1, s) keeps int and str comparable.
    return [(0, int(p)) if p.isdigit() else (1, p) for p in re.findall(r'\d+|\D+', name)]


def _alive(pid):
    if os.name == 'nt' or sys.platform in ('cygwin', 'msys'):
        return True          # os.kill(pid, 0) terminates the process on Windows
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:          # EPERM: alive, owned by someone else
        return True
    return True


def _marker_pid(marks, name):
    if PID_RE.fullmatch(name):
        return int(name)
    # Not named by its pid: the content carries it ({"pid": N, "procStart": …}). Only a small regular
    # file is read: the open neither follows a link nor blocks on a FIFO, which would hang the install.
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
    try:
        fd = os.open(os.path.join(marks, name), flags)
    except OSError:
        return None
    try:
        with os.fdopen(fd, 'rb') as f:
            st = os.fstat(f.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_size > MARKER_MAX:
                return None
            pid = json.loads(f.read(MARKER_MAX).decode('utf-8')).get('pid')
    except (OSError, ValueError, AttributeError):
        return None
    return pid if isinstance(pid, int) and not isinstance(pid, bool) and PID_RE.fullmatch(str(pid)) else None


def _live_users(version_dir):
    """Live pids with a marker in the dir. None when the markers cannot be listed: unknown is kept."""
    marks = os.path.join(version_dir, '.in_use')
    try:
        names = os.listdir(marks)
    except FileNotFoundError:
        return []
    except OSError:
        return None
    pids = (_marker_pid(marks, n) for n in names)
    return [p for p in pids if p is not None and _alive(p)]


def prune(plugins_json, cache_base, current):
    try:
        data = _load(plugins_json)
    except Unreadable as e:
        print('  ⚠ old cache dirs kept — installed_plugins.json unreadable: %s' % e, file=sys.stderr)
        return 1
    try:
        names = os.listdir(cache_base)
    except OSError as e:
        print('  ⚠ old cache dirs not pruned: %s' % e, file=sys.stderr)
        return 1
    dirs = sorted((n for n in names
                   if not n.startswith('.') and os.path.isdir(os.path.join(cache_base, n))
                   and not os.path.islink(os.path.join(cache_base, n))), key=_version_key)
    keep = {current}
    others = [n for n in dirs if n != current and VERSION_RE.fullmatch(n)]
    if others:
        keep.add(others[-1])
    base = os.path.realpath(cache_base)
    for entry in _entries(data):
        path = entry.get('installPath')
        if _in_cache(path, base):
            keep.add(os.path.basename(os.path.realpath(os.path.expanduser(path))))
    rc = 0
    for name in dirs:
        if name in keep:
            continue
        users = _live_users(os.path.join(cache_base, name))
        if users is None:
            print('  Kept old cache: %s (its .in_use markers cannot be read)' % name)
            continue
        if users:
            print('  Kept old cache: %s (in use by %d live session%s)'
                  % (name, len(users), '' if len(users) == 1 else 's'))
            continue
        shutil.rmtree(os.path.join(cache_base, name), ignore_errors=True)
        if os.path.lexists(os.path.join(cache_base, name)):
            print('  ⚠ could not remove old cache: %s' % name, file=sys.stderr)
            rc = 1
        else:
            print('  Removed old cache: %s (no live session, not in installed_plugins.json)' % name)
    return rc


def main(argv):
    if len(argv) >= 4 and argv[0] == 'registry':
        return registry(argv[1], argv[2], argv[3], argv[4] if len(argv) > 4 else '')
    if len(argv) == 4 and argv[0] == 'prune':
        return prune(argv[1], argv[2], argv[3])
    print(__doc__.split('\n\n')[0], file=sys.stderr)
    return 64


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
