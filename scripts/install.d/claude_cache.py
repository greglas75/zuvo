"""claude_cache.py — the Claude Code plugin cache's registry entries and old version dirs.
Called by install_claude (claude.sh).

  registry <installed_plugins.json> <cache-base> <current-version> [<sha>]
  prune    <installed_plugins.json> <cache-base> <current-version>

A Claude Code session reads `installPath` once, when it starts, and loads its hooks from that dir for
as long as it runs. Deleting the dir under it turns every plugin hook into "Plugin directory does not
exist: …/zuvo/<version>" until that session is restarted. The old rule kept the 2 newest version dirs,
which held for sessions shorter than two releases. On the sessions host, sessions run for 10 days and
release-autoinstall installs several releases a day: on 2026-10-29 every session started on 1.6.112
lost its hooks once 1.6.114 and 1.6.115 had landed.

prune keeps a version dir that is any of:
  - the current version, or the newest other one (the previous rule, kept as a floor);
  - named by an installPath in installed_plugins.json (any scope — a project-scope entry is loaded
    by every session started in that project);
  - in use: Claude Code writes `.in_use/<pid>` into the dir each session loads, and the pid is alive.
    A dead pid's marker does not count. A pid reused by another process keeps the dir longer — only
    disk, never a broken session. Where liveness cannot be checked (Windows: os.kill(pid, 0) would
    terminate the process there), every marker counts as alive.

registry stamps <sha> on every zuvo entry (the stale-SHA workaround) and repoints an entry whose
installPath no longer exists to the current version dir, when that dir is loadable. Entries the old
prune left pointing at deleted dirs (Mac, 2026-10-29: four data-lab project entries on 1.6.83-1.6.110)
broke every session started in those projects.
"""
import json
import os
import re
import shutil
import sys

PLUGIN_KEY = 'zuvo@zuvo-marketplace'


def _entries(data):
    return data.get('plugins', {}).get(PLUGIN_KEY, [])


def _load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _loadable(version_dir):
    return os.path.isfile(os.path.join(version_dir, '.claude-plugin', 'plugin.json'))


def registry(plugins_json, cache_base, current, sha):
    data = _load(plugins_json)
    if data is None:
        return 0
    current_dir = os.path.join(cache_base, current)
    changed = []
    for entry in _entries(data):
        if sha and entry.get('gitCommitSha') != sha:
            entry['gitCommitSha'] = sha
            changed.append('sha')
        path = entry.get('installPath')
        if path and not os.path.isdir(path) and _loadable(current_dir):
            entry['installPath'] = current_dir
            entry['version'] = current
            changed.append('repointed %s entry %s -> %s' % (entry.get('scope', '?'), path, current))
    if changed:
        with open(plugins_json, 'w') as f:
            json.dump(data, f, indent=2)
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
    if os.name == 'nt':
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:          # EPERM: alive, owned by someone else
        return True
    return True


def _live_users(version_dir):
    marks = os.path.join(version_dir, '.in_use')
    try:
        names = os.listdir(marks)
    except OSError:
        return []
    return [n for n in names if n.isdigit() and _alive(int(n))]


def prune(plugins_json, cache_base, current):
    dirs = sorted((n for n in os.listdir(cache_base)
                   if not n.startswith('.') and os.path.isdir(os.path.join(cache_base, n))
                   and not os.path.islink(os.path.join(cache_base, n))), key=_version_key)
    keep = {current}
    others = [n for n in dirs if n != current]
    if others:
        keep.add(others[-1])
    data = _load(plugins_json) or {}
    base = os.path.realpath(cache_base)
    for entry in _entries(data):
        path = entry.get('installPath') or ''
        if os.path.dirname(os.path.realpath(path)) == base:
            keep.add(os.path.basename(os.path.realpath(path)))
    for name in dirs:
        if name in keep:
            continue
        users = _live_users(os.path.join(cache_base, name))
        if users:
            print('  Kept old cache: %s (in use by %d live session%s)'
                  % (name, len(users), '' if len(users) == 1 else 's'))
            continue
        shutil.rmtree(os.path.join(cache_base, name), ignore_errors=True)
        print('  Removed old cache: %s (no live session, not in installed_plugins.json)' % name)
    return 0


def main(argv):
    if len(argv) >= 4 and argv[0] == 'registry':
        return registry(argv[1], argv[2], argv[3], argv[4] if len(argv) > 4 else '')
    if len(argv) == 4 and argv[0] == 'prune':
        return prune(argv[1], argv[2], argv[3])
    print(__doc__.split('\n\n')[0], file=sys.stderr)
    return 64


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
