"""Stable machine identity for everything this host reports to the collector.

One module, because the tag is a fleet-wide key: the collectors, the archiver and the merger must
agree on it, and a copy per caller is how they stop agreeing. The same file says parsing and the
dedup key live in a shared module "so this collector and backlog-archive.py cannot drift apart";
host identity has exactly that property.

Why not `socket.gethostname()` alone, which is what every caller used before: on macOS it follows
DHCP/network state, and a Mac with `HostName: not set` reports its `.local` name. Measured in the
merged backlog index on 2026-10-02, ONE machine appeared as four hosts —
`Gregs-MacBook-Pro-M5-2.local` 14,955 + `Mac` 10,701 + a `…ts.net` name 9,385 + its bare LAN
address 7,990 — i.e. 42k items of one box counted four times, and its worktree-fork warnings tripled
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
    # Read as BYTES and decode here. `open(..., encoding="utf-8")` raises UnicodeDecodeError on a
    # file that is not text, and that is a ValueError — so it escaped this function's
    # `except FileNotFoundError` AND the callers' `except OSError`, and a host-id holding binary
    # (a truncated write, an editor's swap file, a stray `>` from another command) ended every
    # collector in a bare traceback at import rather than in any of the three named outcomes below.
    try:
        with open(host_id_path(), "rb") as fh:
            blob = fh.read()
    except FileNotFoundError:
        blob = None
    raw, why = None, "not a usable host tag (single line, [A-Za-z0-9._-], 1-64 chars)"
    if blob is not None:
        try:
            raw = blob.decode("utf-8")
        except UnicodeDecodeError:
            # Binary content carries no identity at all, which is the same situation as a malformed
            # line: fall through to the next source rather than refuse. Contrast the UNREADABLE case
            # (the OSError this function lets propagate): there the file may well hold the right id
            # and the next source would report this machine under a DIFFERENT name, so the caller
            # must surface it. "No usable id here" and "an id I am not allowed to see" are opposite.
            raw, why = "", "not UTF-8 text"
    if raw is not None:
        tag = _valid(raw)
        if tag:
            # Both sources set and disagreeing is the one case where file-first changes a tag that
            # used to be the env var's: every caller read `ZUVO_HOST_TAG` FIRST before this module.
            # An upgrade on a host with a stale host-id would therefore flip its identity, and the
            # flip is the exact fleet-fragmentation this module exists to end — silent, it would
            # surface weeks later as a second key in the merged index. Named here, it surfaces in
            # the first cron mail. Not an exit: one of the two IS correct and reporting continues.
            env_tag = _valid(os.environ.get("ZUVO_HOST_TAG", ""))
            if env_tag and env_tag != tag:
                print(f"zuvo: {host_id_path()} says {tag!r} but ZUVO_HOST_TAG says {env_tag!r} — "
                      f"reporting as {tag!r} (the file wins); delete whichever is wrong",
                      file=sys.stderr)
            return tag
        # Present but unusable. Silence here would send this host back to the volatile hostname
        # with no trace, which is the failure the file exists to end — so name it on stderr and
        # fall through rather than exit: telemetry must not become the reason a tool cannot run.
        print(f"zuvo: ignoring {host_id_path()} — {why}", file=sys.stderr)

    tag = _valid(os.environ.get("ZUVO_HOST_TAG", ""))
    if tag:
        return tag
    # Through the same validator as the other two sources, so no source can emit a tag the readers
    # cannot use as a key or a filename stem. Note what this does NOT do: `Gregs-MacBook-Pro-M5-2.local`
    # and a bare LAN address both pass — they are well-shaped, they are just not stable, and no validator
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
