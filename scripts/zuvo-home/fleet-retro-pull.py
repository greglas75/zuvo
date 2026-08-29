#!/bin/sh
# Polyglot sh/python header. `#!/usr/bin/env python3` fails on Windows: python.org installs
# `python` and `py`, Git Bash ships neither, and the shebang dies with
#     env: python3: No such file or directory
# (reproduced). /bin/sh executes the next line, which re-execs this file with whatever Python 3
# the machine actually has; Python parses that same line as a string literal and ignores it.
# Keep it on ONE line and do not "tidy" the quoting — both interpreters depend on it exactly.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
"""fleet-retro-pull.py — bring OTHER INSTALLS' zuvo retros down into the mining loop.

The uplink has worked for a while and nobody could see it. Zuvo retros ride the CodeSift
telemetry payload (`/ingest/codesift`, open + anonymous — the only channel that reaches anyone;
`/ingest/zuvo` is token-gated behind SSH to a tailnet host, so it holds exactly one install: this
machine). Those payloads land on the collector and stop there: `retro-mine.py` reads
`~/.zuvo/retros.md` plus `~/.zuvo/remote/*/`, and NOTHING ever wrote the fleet's rollups into
either. Measured 2026-08-12: 30 installs reporting, 4 of them carrying zuvo retro blocks, of which
3 are other people — and every digest ever generated saw zero of them.

This is the missing half. It pulls the collector's `codesift` namespace, keeps the `retros`
rollups, drops this machine's own anon id, and writes one canonical `retros.log` per foreign
install under `~/.zuvo/remote/fleet/<anon8>/` — the exact path+format `retro-mine.py` already
globs (`remote/*/` then `*/`), so no change is needed there.

The rollup is anonymous by omission: day / skill / code_type / friction / context_gap / counts and
medians. No project, no branch, no sha, no free text — those fields are never collected. The
canonical retros.log line has 17 fields, so the ones that do not exist in a rollup are written as
`N/A`; `count: N` becomes N identical lines, because the miner counts occurrences.

Usage:
  fleet-retro-pull.py            # pull, rewrite ~/.zuvo/remote/fleet/, print a summary
  fleet-retro-pull.py --dry-run  # show what would be written, touch nothing
  fleet-retro-pull.py --days 30  # only rollups whose day is within N days (default: all)

Exit: 0 = pulled (or nothing configured, stated out loud); 1 = the collector could not be read.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone

ZUVO = os.environ.get("ZUVO_HOME", os.path.expanduser("~/.zuvo"))
FLEET = os.path.join(ZUVO, "remote", "fleet")
SELF = os.path.join(ZUVO, "remote", "self")   # --restore-self target; retro-mine reads remote/*/*/
REMOTE_DATA = "/opt/telemetry-collector/data/codesift"
SSH_TIMEOUT = 25          # hard wall: an unreachable collector must fail, never hang a cron job


def collector_ssh():
    """Same resolution rule as zuvo-collector-host.sh: env, then collector.conf, no default."""
    v = os.environ.get("ZUVO_COLLECTOR_SSH")
    if v:
        return v.strip()
    conf = os.path.join(ZUVO, "collector.conf")
    try:
        with open(conf, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                m = re.match(r"\s*ZUVO_COLLECTOR_SSH\s*=\s*(.+)", line)
                if m:
                    val = m.group(1).split("#", 1)[0].strip().strip("'\"").strip()
                    if val:
                        return val
    except OSError:
        pass
    return ""


def local_anon_id():
    """This machine's own id — its rollups are already in ~/.zuvo/retros.log, not foreign data."""
    for p in (os.path.join(os.path.expanduser("~/.codesift"), "telemetry-id"),
              os.path.join(os.environ.get("CODESIFT_DATA_DIR", ""), "telemetry-id")):
        if p and os.path.isfile(p):
            try:
                return open(p, encoding="utf-8", errors="ignore").read().strip()
            except OSError:
                pass
    return ""


def fetch(vps):
    """One SSH, whole namespace. Bounded: a hung collector must not wedge the caller."""
    cmd = ["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={SSH_TIMEOUT}", vps,
           f"cat {REMOTE_DATA}/*.jsonl 2>/dev/null"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=SSH_TIMEOUT * 4)
    except subprocess.TimeoutExpired:
        print(f"fleet-retro-pull: collector {vps} did not answer in {SSH_TIMEOUT * 4}s", file=sys.stderr)
        return None
    if out.returncode != 0:
        print(f"fleet-retro-pull: ssh to {vps} failed (rc={out.returncode}): "
              f"{out.stderr.strip()[:200]}", file=sys.stderr)
        return None
    return out.stdout


# Canonical retros.log layout (17 fields after `RETRO: `). Only the ones a rollup actually carries
# are filled; the rest are N/A by construction, not by scrubbing — see the module docstring.
def rollup_to_line(day, r):
    ts = f"{day}T00:00:00Z"
    # Every value below comes from the OPEN ingestion channel. A "\n" in any of them
    # would close this row and open a forged one — retros.log is newline-delimited TSV and
    # the miner would count the forgery as a real run. Neutralize separators at the join.
    def _f(v):
        return str(v).replace("\t", " ").replace("\r", " ").replace("\n", " ")
    return "RETRO: " + "\t".join([_f(x) for x in [
        ts,
        str(r.get("skill") or "unknown"),          # 1 skill      — miner: skills[f[1]]
        "fleet",                                    # 2 project    — never collected
        str(r.get("code_type") or "N/A"),           # 3 code_type
        str(r.get("friction") or "other"),          # 4 friction   — miner: frictions[f[4]]
        "N/A",                                      # 5 note       — never collected
        str(r.get("context_gap") or "N/A"),         # 6 context gap
        str(r.get("median_turns") or "N/A"),        # 7 turns
        str(r.get("median_tool_calls") or "N/A"),   # 8 tool calls
        str(r.get("median_files_read") or "N/A"),   # 9 files read
        str(r.get("median_files_modified") or "N/A"),  # 10 files modified
        "N/A",                                      # 11 branch    — never collected
        "N/A",                                      # 12 sha       — never collected
        f"blind={r.get('blind_audit_ran', 'N/A')}",  # 13
        f"adv={r.get('adversarial_ran', 'N/A')}",    # 14
        str(r.get("codesift") or "N/A"),            # 15
        str(r.get("routing") or "N/A"),             # 16
    ]])


def local_earliest_day():
    """Oldest RETRO day still in ~/.zuvo/retros.log, or "" if unreadable/empty.

    This is the overlap fence for --restore-self. Rollups are AGGREGATES: re-importing a day the
    local log still covers would count those runs twice in the miner, and the second count would be
    indistinguishable from real activity. Restoring strictly BELOW this day makes double-counting
    impossible by construction rather than by care.
    """
    try:
        days = []
        with open(os.path.join(ZUVO, "retros.log"), encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                if line.startswith("RETRO:"):
                    d = line[6:].strip().split("\t")[0][:10]
                    if len(d) == 10 and d[4] == "-":
                        days.append(d)
        return min(days) if days else ""
    except OSError:
        return ""


def main():
    dry = "--dry-run" in sys.argv
    restore_self = "--restore-self" in sys.argv
    days = None
    if "--days" in sys.argv:
        try:
            days = int(sys.argv[sys.argv.index("--days") + 1])
        except (IndexError, ValueError):
            print("fleet-retro-pull: --days needs a number", file=sys.stderr)
            return 1
    cutoff = ""
    if days:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).strftime("%Y-%m-%d")

    # --restore-self: pull THIS install's own rollups back down, for days the local retros.log no
    # longer covers. The collector is the only surviving copy after a local truncation (measured
    # 2026-08-15: retros.log went 143486 -> 70167 bytes and lost 02-11.08 with no archive).
    # Restored rows land in remote/self/<anon8>/, NOT in retros.log: they are lossy reconstructions
    # (no project, note, branch or sha7 — the rollup never carried them), so writing them into the
    # canonical log would make reconstructions indistinguishable from real rows. remote/ is where
    # retro-mine already looks for exactly this kind of second-hand data.
    before = ""
    if restore_self:
        if "--before" in sys.argv:
            try:
                before = sys.argv[sys.argv.index("--before") + 1]
            except IndexError:
                print("fleet-retro-pull: --before needs YYYY-MM-DD", file=sys.stderr)
                return 1
        else:
            before = local_earliest_day()
        if not before:
            print("fleet-retro-pull: --restore-self needs --before YYYY-MM-DD "
                  "(could not read the oldest day from retros.log, so the overlap fence is unknown)",
                  file=sys.stderr)
            return 1
        print(f"fleet-retro-pull: restore-self — importing own rollups STRICTLY BEFORE {before} "
              f"(the oldest day retros.log still holds)")

    vps = collector_ssh()
    if not vps:
        # Loud, not silent: every other helper here soft-skips with no output, which is how five
        # days of dead sync went unnoticed. Say why nothing happened.
        print("fleet-retro-pull: no collector configured "
              f"(set ZUVO_COLLECTOR_SSH in {ZUVO}/collector.conf) — nothing pulled")
        return 0

    raw = fetch(vps)
    if raw is None:
        return 1

    mine = local_anon_id()
    # (anon, day, skill, code_type, friction, context_gap, …) -> emitted line, with its count
    per_install = defaultdict(list)
    seen = set()
    skipped_self = 0
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if not isinstance(rec, dict):        # a bare JSON array crashes .get()
            continue
        payload = rec.get("payload") or rec
        if not isinstance(payload, dict):
            continue
        anon = rec.get("anon_id") or payload.get("anon_id") or ""
        rollups = payload.get("retros")
        if not isinstance(rollups, list):    # a scalar/dict here would iterate wrongly
            continue
        if not anon or not rollups:
            continue
        is_self = bool(mine) and anon == mine
        if is_self and not restore_self:
            skipped_self += 1
            continue
        if restore_self and not is_self:
            continue          # restore mode is about THIS install only
        for r in rollups:
            if not isinstance(r, dict):
                continue
            day = str(r.get("day") or "")[:10]
            if not day or (cutoff and day < cutoff):
                continue
            if before and day >= before:
                continue      # the local log still covers this day — importing it would double-count
            # str() every element: a list-valued field would make the tuple unhashable and
            # kill the sync loop on seen.add().
            key = (anon, day, str(r.get("skill")), str(r.get("code_type")),
                   str(r.get("friction")), str(r.get("context_gap")), str(r.get("count")))
            if key in seen:          # the same rollup is re-sent on every flush until the cursor moves
                continue
            seen.add(key)
            line_out = rollup_to_line(day, r)
            try:
                # count is untrusted: 1e9 would allocate the list until the process dies,
                # and the poison payload stays on the collector, so every later run dies too.
                n = min(10000, max(1, int(r.get("count") or 1)))
            except (TypeError, ValueError):
                n = 1
            per_install[anon].extend([line_out] * n)

    if not per_install:
        print(f"fleet-retro-pull: 0 foreign retro rollups on {vps} "
              f"(own uploads skipped: {skipped_self})")
        return 0

    total = 0
    for anon, lines in sorted(per_install.items()):
        # anon_id arrives from the open/anonymous collector namespace, so it is untrusted
        # input on a filesystem path: "../../.." survives split("-")[0][:8] intact and
        # os.path.join then escapes FLEET, overwriting an arbitrary retros.log. Allowlist
        # the characters instead of trying to detect traversal.
        short = re.sub(r"[^A-Za-z0-9]", "", anon)[:8] or "unknown"
        d = os.path.join(SELF if restore_self else FLEET, short)
        total += len(lines)
        if dry:
            print(f"  would write {len(lines):>5} retros -> {d}/retros.log")
            continue
        os.makedirs(d, exist_ok=True)
        # Atomic replace: retro-mine may read this file while we rewrite it.
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".retros.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("\n".join(sorted(lines)) + "\n")
        os.replace(tmp, os.path.join(d, "retros.log"))
        print(f"  {len(lines):>5} retros -> remote/{'self' if restore_self else 'fleet'}/{short}/retros.log")

    kind = "own (restored)" if restore_self else "foreign"
    print(f"fleet-retro-pull: {total} retros from {len(per_install)} {kind} install(s)"
          f"{' [dry-run]' if dry else ''}; own uploads skipped: {skipped_self}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
