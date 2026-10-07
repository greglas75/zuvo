"""publish_current.py <new> <current> <aside-dir> — put <new> (a bundle directory, or a symlink to one)
in place of <current>. Called by install_refactor_radar_bundle (zuvo-home.sh).

First os.replace, which is atomic where the platform allows it (a symlink over a symlink on POSIX).
When it refuses (a directory over a non-empty directory or a symlink, a symlink over a directory, any
directory symlink on Windows), the previous <current> is renamed aside into <aside-dir> as
bundle.retired.*, then <new> is renamed into place, and if that fails the previous one is put back,
but only into a gap: a <current> another install published meanwhile is left as it is (checked just
before the rename, so only a race inside that instant could still lose to it). Unlike
`mv`, os.rename never moves a directory INTO an existing one, so a racing install fails here instead
of nesting its bundle inside the winner's. A retired SYMLINK is removed after a successful publish:
it is only a pointer, and the bundle it named stays like every older bundle. A retired directory is
kept for sessions still running from it.

Exit 0 published; 1 not published and nothing lost (the previous <current> is in place, or another
install's is and the previous one is at the path on stderr, or there was none); 3 not published and
the previous <current> is ONLY at the path on stderr; 64 bad arguments. Not 2: Python itself exits 2
when it cannot open this file.
"""
import os
import secrets
import sys


def publish(new, current, aside_dir):
    if not os.path.lexists(new):
        print('  ! nothing to publish: %s does not exist' % new, file=sys.stderr)
        return 1
    try:
        os.replace(new, current)
        return 0
    except OSError:
        pass
    aside = None
    if os.path.lexists(current):
        aside = os.path.join(aside_dir, 'bundle.retired.%d.%s' % (os.getpid(), secrets.token_hex(4)))
        try:
            os.rename(current, aside)  # rename, not replace: aside is a fresh name
        except OSError as err:
            print('  ! cannot move the previous %s aside (in use?): %s' % (current, err), file=sys.stderr)
            return 1
    try:
        os.rename(new, current)  # rename, not replace: never nest into a racing install
    except OSError as err:
        print('  ! cannot publish %s as %s: %s' % (new, current, err), file=sys.stderr)
        if aside is not None:
            if os.path.lexists(current):
                print('  ! another install published %s meanwhile; the previous one is at %s'
                      % (current, aside), file=sys.stderr)
                return 1
            try:
                os.rename(aside, current)  # rename, not replace: put back only into a gap
            except OSError as restore_err:
                print('  ! and the previous one could not be put back: it is at %s (%s)'
                      % (aside, restore_err), file=sys.stderr)
                return 1 if os.path.lexists(current) else 3
        return 1
    if aside is not None and os.path.islink(aside):
        try:
            os.unlink(aside)
        except OSError as err:
            print('  ! published; the retired link %s stays (%s)' % (aside, err), file=sys.stderr)
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 4:
        print('  ! publish_current.py: usage: <new> <current> <aside-dir>', file=sys.stderr)
        sys.exit(64)
    sys.exit(publish(*sys.argv[1:]))
