"""Stable machine identity for everything this host reports to the collector.

One module, because the tag is a fleet-wide key: the collectors, the archiver and the merger must
agree on it, and a copy per caller is how they stop agreeing. The same file says parsing and the
dedup key live in a shared module "so this collector and backlog-archive.py cannot drift apart";
host identity has exactly that property.

Why not `socket.gethostname()` alone, which is what every caller used before: on macOS it follows
DHCP/network state, and a Mac with `HostName: not set` reports its `.local` name. Measured in the
merged backlog index on 2026-10-02, ONE machine appeared as four hosts —
`Gregs-MacBook-Pro-M5-2.local` 14,955 + `Mac` 10,701 + a `…ts.net` name 9,385 + `192.168.0.124`
7,990 — i.e. 42k items of one box counted four times, and its worktree-fork warnings tripled
because the same repo was seen under four names.

Precedence is `~/.zuvo/host-id` FIRST, then `ZUVO_HOST_TAG`, then the hostname. The file wins
deliberately: an env var is the mechanism that cannot be relied on to reach every launch path
(codesift measured 1,109 of 1,370 calls still mis-tagged with its LaunchAgent in place), and these
collectors run from launchd, cron and interactive shells. If the env var outranked the file, a stale
`ZUVO_HOST_TAG` in one shell profile would silently beat a correctly seeded id — and the two
collectors, launched from different contexts, would report the same box under two names. That is the
bug this module exists to remove, so the override cannot be allowed to reintroduce it; it stays as a
fallback for a host that has no file yet (CI, a container, a one-off probe).
"""

import os
import re
import socket

# Single line, no separators, no spaces: the tag is used verbatim as a key in the merged index and
# as a filename stem by the readers. A hand-edited file with a trailing comment or a path in it
# should fall through to the hostname rather than create an unusable key.
_TAG_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def zuvo_home() -> str:
    # ZUVO_DIR, because that is the name every caller of this module already resolves its state dir
    # from (`backlog`, `backlog-collect.py`, `runlog-collect.py` all read ZUVO_DIR). ZUVO_HOME is
    # honoured second so an environment that sets only the older name still lands in one directory —
    # two env names for one path is how a host ends up with two host-id files and two identities.
    return (os.environ.get("ZUVO_DIR") or os.environ.get("ZUVO_HOME")
            or os.path.join(os.path.expanduser("~"), ".zuvo"))


def host_id_path() -> str:
    return os.path.join(zuvo_home(), "host-id")


def _valid(tag: str) -> str:
    tag = (tag or "").strip()
    return tag if _TAG_RE.match(tag) else ""


def host_tag() -> str:
    """The id this machine reports: `~/.zuvo/host-id`, else `ZUVO_HOST_TAG`, else the hostname.

    Raises OSError when the file exists but cannot be read. That case used to be swallowed together
    with "no file yet", and the two are opposite situations: a `host-id` turned root-owned by a
    `sudo` run would silently fall back to the volatile hostname and quietly re-fragment the fleet,
    which is the failure this module removes. "Absent" is normal; "present and unreadable" is a
    fault the caller should surface.
    """
    try:
        with open(host_id_path(), encoding="utf-8") as fh:
            tag = _valid(fh.read())
            if tag:
                return tag
    except FileNotFoundError:
        pass

    tag = _valid(os.environ.get("ZUVO_HOST_TAG", ""))
    if tag:
        return tag
    # Through the same validator as the other two sources, so no source can emit a tag the readers
    # cannot use as a key or a filename stem. Note what this does NOT do: `Gregs-MacBook-Pro-M5-2.local`
    # and `192.168.0.124` both pass — they are well-shaped, they are just not stable, and no validator
    # can tell a drifting name from a fixed one. Seeding `host-id` is what fixes that; this only
    # guarantees the fallback is usable, and names the empty case rather than returning "".
    return _valid(socket.gethostname()) or "unknown-host"
