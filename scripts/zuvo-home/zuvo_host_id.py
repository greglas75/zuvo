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

import hashlib
import os
import re
import socket
import sys

# Single line, no separators, no spaces: the tag is used verbatim as a key in the merged index and
# as a filename stem by the readers. A hand-edited file with a trailing comment or a path in it
# should fall through to the hostname rather than create an unusable key.
_TAG_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
# `.` and `..` match the pattern above and are legal filename stems to the regex while being
# directory references to every reader that joins them into a path.
_RESERVED_TAGS = {".", ".."}


def zuvo_home() -> str:
    # ZUVO_DIR only — the one name every caller already resolves its state dir from (`backlog`,
    # `backlog-collect.py`, `runlog-collect.py`). An earlier draft also honoured ZUVO_HOME "for
    # compatibility"; since no caller reads it, that could only ever point this module at a
    # different directory than its callers, which is the two-identities hazard it warns about.
    return os.environ.get("ZUVO_DIR") or os.path.join(os.path.expanduser("~"), ".zuvo")


def host_id_path() -> str:
    return os.path.join(zuvo_home(), "host-id")


def _valid(tag: str) -> str:
    tag = (tag or "").strip()
    if tag in _RESERVED_TAGS or not _TAG_RE.match(tag):
        return ""
    return tag


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
            raw = fh.read()
    except FileNotFoundError:
        raw = None
    if raw is not None:
        tag = _valid(raw)
        if tag:
            return tag
        # Present but unusable. Silence here would send this host back to the volatile hostname
        # with no trace, which is the failure the file exists to end — so name it on stderr and
        # fall through rather than exit: telemetry must not become the reason a tool cannot run.
        print(f"zuvo: ignoring {host_id_path()} — not a usable host tag "
              f"(single line, [A-Za-z0-9._-], 1-64 chars)", file=sys.stderr)

    tag = _valid(os.environ.get("ZUVO_HOST_TAG", ""))
    if tag:
        return tag
    # Through the same validator as the other two sources, so no source can emit a tag the readers
    # cannot use as a key or a filename stem. Note what this does NOT do: `Gregs-MacBook-Pro-M5-2.local`
    # and `192.168.0.124` both pass — they are well-shaped, they are just not stable, and no validator
    # can tell a drifting name from a fixed one. Seeding `host-id` is what fixes that; this only
    # guarantees the fallback is usable, and names the empty case rather than returning "".
    raw = (socket.gethostname() or "").strip()
    tag = _valid(raw)
    if tag:
        return tag
    if raw:
        # Too long (a 70-character FQDN) or carrying a character the readers cannot use: derive a
        # key FROM THE NAME, so it is deterministic and stays the same on every run of every
        # process. An earlier version hashed `uuid.getnode()` here, which is exactly the wrong
        # source — the docs say it returns a RANDOM value for the life of the process when it
        # cannot read a MAC, so a machine in that state would mint a new identity per run and
        # fragment itself worse than the hostname ever did.
        return "h-" + hashlib.sha256(raw.encode("utf-8", "surrogateescape")).hexdigest()[:10]
    # Only reachable when the host has no name at all. This is the one shared sentinel left, and it
    # is named rather than empty so the records stay groupable and the cause is visible.
    return "unknown-host"
