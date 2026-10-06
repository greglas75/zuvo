#!/usr/bin/env python3
"""Register one Claude Code hook in ~/.claude/settings.json — the merge behind install.sh's
_claude_home_register_hook (scripts/install.d/claude-home.sh), for all four hooks it registers.

    claude_settings.py <settings.json> <hook script> <event> <matcher|-> <timeout> <label> [<note>]

Exit status: 0 registered, or already registered; 1 settings.json is malformed or unreadable (left
exactly as it was); 2 it could not be written; 3 it kept changing under the merge. Every non-zero
status prints its reason on one '  ! ' line first; install.sh adds its own one-line warning after it.

What "already registered" means. A group under <event> whose matcher fires for <matcher> (no matcher,
'*', or a pattern that matches it — 'Skill|Read' fires for Skill) and that holds a command running
THIS script: the script alone, or `bash|sh <script>`, compared after expanding $HOME, ${HOME} and ~
and after resolving symlinks. The merges this replaces asked only whether a command ENDED in the
script's file name, so a user's hook of the same name at another path, or zuvo's under a matcher
that never fires, counted as zuvo's registration and zuvo's own was never added; the farm guard's
stricter copy compared paths without resolving links, and added a second registration for a file
reached through a symlink.

How it writes. A temp file in the REAL file's directory (so a symlinked settings.json, as dotfile
managers keep it, is written through), fsync'd, given the file's own mode, then os.replace'd over it
— never a truncating open(path, 'w'), which leaves an invalid settings.json on an interrupt, and then
no Claude Code session starts until it is repaired by hand. Concurrent zuvo installers (parallel agents
each run install.sh) are serialized by an advisory lock in ~/.zuvo/locks/; anything else that writes
settings.json between the read and the replace (Claude Code itself takes no lock) is caught by
comparing the file's bytes just before the replace, and the merge starts over, up to ATTEMPTS times.
The compare and the replace are two steps, so a write landing between them is still lost: closing that
window needs a lock every writer honours, and Claude Code has none to share.
"""
import json
import os
import re
import shlex
import stat
import sys
import tempfile

try:
    import fcntl
except ImportError:  # Windows Python (the Git-Bash target): no advisory locks; the byte check still applies
    fcntl = None  # type: ignore[assignment]  # checked before every use

ATTEMPTS = 3
# The call, for the bad-arguments line (the docstring is gone under python -OO / PYTHONOPTIMIZE=2).
USAGE = 'claude_settings.py <settings.json> <hook script> <event> <matcher|-> <timeout> <label> [<note>]'


class Malformed(Exception):
    pass


def load(real_path, event):
    """(original bytes, parsed settings, the event's group list) — or Malformed, nothing changed."""
    try:
        with open(real_path, 'rb') as f:
            original = f.read()
        settings = json.loads(original)
    except (OSError, ValueError) as e:
        raise Malformed(str(e)) from e
    if not isinstance(settings, dict):
        raise Malformed('the top level must be an object')
    hooks = settings.setdefault('hooks', {})
    if not isinstance(hooks, dict):
        raise Malformed('"hooks" must be an object')
    groups = hooks.setdefault(event, [])
    if not isinstance(groups, list) or not all(isinstance(g, dict) for g in groups):
        raise Malformed('"hooks.%s" must be an array of objects' % event)
    for g in groups:
        entries = g.get('hooks', [])
        if not isinstance(entries, list) or not all(isinstance(h, dict) for h in entries):
            raise Malformed('hook entries under "%s" must be objects' % event)
    return original, settings, groups


def expand(path, home):
    for token in ('${HOME}', '$HOME'):
        if path.startswith(token):
            path = home + path[len(token):]
    return os.path.expanduser(path)


def runs_script(command, script, home):
    """True when <command> runs <script>: the path alone, or `bash|sh <path>`."""
    if not isinstance(command, str):
        return False
    try:
        tokens = shlex.split(command)
    except ValueError:
        return False
    if len(tokens) == 1:
        candidate = tokens[0]
    elif len(tokens) == 2 and os.path.basename(tokens[0]) in ('bash', 'sh'):
        candidate = tokens[1]
    else:
        return False
    candidate = expand(candidate, home)
    return (os.path.normpath(candidate) == os.path.normpath(script)
            or os.path.realpath(candidate) == os.path.realpath(script))


def fires_for(group_matcher, matcher):
    """Does a group with <group_matcher> fire for <matcher>? '-' = an event without matchers."""
    if matcher == '-' or group_matcher in (None, '', '*'):
        return True
    if not isinstance(group_matcher, str):
        return False
    try:
        return re.fullmatch(group_matcher, matcher) is not None
    except re.error:
        return group_matcher == matcher


def registered(groups, script, matcher, home):
    return any(
        fires_for(g.get('matcher'), matcher)
        and any(h.get('type') in (None, 'command') and runs_script(h.get('command'), script, home)
                for h in g.get('hooks', []))
        for g in groups)


def lock(home):
    """An exclusive advisory lock shared by every zuvo installer, or None where there are none."""
    if fcntl is None:
        return None
    path = os.path.join(home, '.zuvo', 'locks', 'claude-settings.lock')
    handle = None
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        handle = open(path, 'a')
        fcntl.flock(handle, fcntl.LOCK_EX)
        return handle
    except OSError as e:
        # Said, not swallowed (a root-owned lock file from a sudo install would otherwise turn the lock off
        # for good, unnoticed); the byte check still guards the replace.
        if handle is not None:
            handle.close()
        print('  ! could not take %s (%s) — merging without it; '
              'settings.json is re-checked before it is replaced' % (path, e))
        return None


def replace_checked(real_path, settings, original):
    """Write <settings> over <real_path> unless its bytes are no longer <original>. True = written."""
    mode = stat.S_IMODE(os.stat(real_path).st_mode)
    fd, temporary = tempfile.mkstemp(prefix='.settings.', suffix='.tmp', dir=os.path.dirname(real_path))
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(settings, f, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.chmod(temporary, mode)
        with open(real_path, 'rb') as f:
            if f.read() != original:
                return False
        os.replace(temporary, real_path)
        return True
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def merge(settings_path, script, event, matcher, timeout, label, note=''):
    home = os.path.expanduser('~')
    real_path = os.path.realpath(settings_path)
    # Key order type, command, timeout — the order every earlier merge wrote, so a settings.json this
    # registers into comes out byte-identical to what those merges produced.
    entry = {'type': 'command',
             'command': '$HOME' + script[len(home):] if script.startswith(home + os.sep) else script,
             'timeout': int(timeout)}
    group = {'hooks': [entry]} if matcher == '-' else {'matcher': matcher, 'hooks': [entry]}
    held = lock(home)
    try:
        for _ in range(ATTEMPTS):
            try:
                original, settings, groups = load(real_path, event)
            except Malformed as e:
                print('  ! ~/.claude/settings.json is malformed (%s) — skipping %s merge' % (e, label))
                return 1
            if registered(groups, script, matcher, home):
                print('  ✓ %s already registered in ~/.claude/settings.json (no change)' % label)
                return 0
            groups.append(group)
            try:
                if replace_checked(real_path, settings, original):
                    print('  ✓ %s registered in ~/.claude/settings.json%s' % (label, note))
                    return 0
            except OSError as e:
                print('  ! could not write ~/.claude/settings.json (%s) — %s not registered' % (e, label))
                return 2
        print('  ! ~/.claude/settings.json kept changing during the merge (%d attempts) — '
              '%s not registered; rerun' % (ATTEMPTS, label))
        return 3
    finally:
        if held is not None:
            held.close()


if __name__ == '__main__':
    args = sys.argv[1:]
    # A wrong call says so on the one '  ! ' line every other failure uses (stdout, which install.sh shows),
    # never a traceback. Every positional argument must be non-empty (an empty script would register a bare
    # `bash`), and the timeout ASCII digits ('²'.isdigit() is True, and int() rejects it).
    if len(args) not in (6, 7) or not all(args[:6]) or not (args[4].isascii() and args[4].isdigit()):
        print('  ! claude_settings.py: bad arguments %r — usage: %s' % (args, USAGE))
        sys.exit(64)
    sys.exit(merge(*args))
