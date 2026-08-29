#!/bin/sh
# Polyglot sh/python header. `#!/usr/bin/env python3` fails on Windows: python.org installs
# `python` and `py`, Git Bash ships neither, and the shebang dies with
#     env: python3: No such file or directory
# (reproduced). /bin/sh executes the next line, which re-execs this file with whatever Python 3
# the machine actually has; Python parses that same line as a string literal and ignores it.
# Keep it on ONE line and do not "tidy" the quoting — both interpreters depend on it exactly.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
"""retro-mine.py — deterministic weekly digest of ALL zuvo signals (Mac + fleet bots).
Sources: ~/.zuvo/retros.md, ~/.zuvo/remote/*/retros.md (popebot bots), runs.log, ~/DEV/*/memory/ideas.md.
Window: entries since --days N (default 7). Output: ~/.zuvo/mining/digest-<date>.md + stdout summary.
Consumed by the weekly retro-miner agent (cron), which fleet-triages proposals -> fixes."""
import os
import re
import glob
import sys
import collections
import dataclasses
import datetime
def _arg_int(flag, default):
    """`--days` with no value, or a non-numeric one, used to kill this script with a traceback.
    It runs from cron ("Consumed by the weekly retro-miner agent"), so a malformed invocation took
    the whole weekly digest with it instead of falling back."""
    if flag not in sys.argv:
        return default
    i = sys.argv.index(flag) + 1
    if i >= len(sys.argv):
        sys.stderr.write(f"retro-mine: {flag} needs a value — using {default}\n")
        return default
    try:
        return int(sys.argv[i])
    except ValueError:
        sys.stderr.write(f"retro-mine: {flag} expects an integer, got {sys.argv[i]!r} — using {default}\n")
        return default

DAYS = _arg_int('--days', 7)
CUT = (datetime.datetime.utcnow() - datetime.timedelta(days=DAYS)).strftime('%Y-%m-%d')
H = os.path.expanduser
out = []
frictions = collections.Counter(); skills = collections.Counter(); proposals = []; entries = 0

# Per-origin attribution. `mine_retros_log` took an `origin` argument from the day it was written
# and threw it away, so every row — this Mac's, a popebot's, an anonymous fleet install's — landed
# in the same two anonymous Counters. That is the whole value of pulling foreign retros: knowing
# that a friction pattern is OURS and not a stranger's, or the reverse. The global Counters above
# are still fed unchanged, so the digest's existing sections stay byte-identical for their parsers.
@dataclasses.dataclass
class OriginStat:
    """One install's contribution. A dict with mixed int/Counter values types as `object` under
    mypy (which this repo gates at zero), and every arithmetic use site then fails."""
    rows: int = 0
    malformed: int = 0
    proposals: int = 0
    unreadable: int = 0
    skills: collections.Counter = dataclasses.field(default_factory=collections.Counter)
    frictions: collections.Counter = dataclasses.field(default_factory=collections.Counter)


by_origin: dict = collections.defaultdict(OriginStat)


def origin_host(origin):
    """Coarse source of an origin id: 'mac', or the remote family ('fleet', 'popebot', 'self')."""
    if not origin.startswith("fleet:"):
        return origin
    return origin[len("fleet:"):].split("/")[0] or "fleet"

def valid_day(field1):
    """True if field 1 is a real calendar day. A shape-only `\\d{4}-\\d{2}-\\d{2}` regex is not
    enough: `2026-99-99` and `2026-08-29junk` both match it, and CUT compares lexicographically, so
    an impossible or far-future date would sail into the window and sit in the histograms forever.
    fromisoformat rejects both, and the failure is COUNTED as malformed rather than mined."""
    try:
        datetime.date.fromisoformat(field1[:10])
    except (ValueError, TypeError):
        return False
    return len(field1) == 10 or field1[10:11] == 'T'


def md_cell(v):
    """One markdown table cell from an untrusted string.

    Origin ids, skills and frictions on fleet rows come from the OPEN ingestion channel.
    append-retro neutralises TAB/CR/LF at the TSV boundary — nothing neutralises `|`, which ends a
    cell, so a friction of `x | y` silently shifts every later column and misattributes the counts
    to the wrong origin. Escape the delimiter and drop anything that could still break the row."""
    return re.sub(r'[\x00-\x1f]', ' ', str(v)).replace('\\', '\\\\').replace('|', '\\|')


def mine_retros_md(path, origin):
    global entries
    try: s = open(path, errors='ignore').read()
    except Exception: return
    for e in re.split(r'\n(?=## \[?\d{4}-\d{2}-\d{2})', s):
        m = re.match(r'## \[?(\d{4}-\d{2}-\d{2})', e)
        if not m or m.group(1) < CUT: continue
        entries += 1
        head = e.splitlines()[0][:90]
        pm = re.search(r'### Change Proposals.*?\n(.*?)(?=\n## |\Z)', e, re.S)
        if pm:
            for b in re.finditer(r'\*\*\d+\.\*\*\s*(.*?)(?=\n\*\*\d+\.\*\*|\Z)', pm.group(1), re.S):
                t = b.group(1).strip()
                if len(t) > 40:
                    proposals.append((origin, head, t[:1200]))
                    by_origin[origin].proposals += 1

def mine_retros_log(path, origin):
    """Mine one retros.log, attributing every row to `origin`.

    Two shape rules, both learned from the live corpus:

    `len(f) == 17`, not the old `> 4`. The canonical line has exactly 17 fields; `> 4` also
    accepted any longer or shorter mutant and mined f[1]/f[4] out of whatever happened to sit
    there. Three real files (this Mac's, one popebot's) each hold one hand-assembled 4-field
    line where the SKILL and DATE are transposed — under `> 4` it was silently dropped, and a
    5-field variant of the same drift would have been silently MIS-counted.

    Malformed rows are counted, not discarded in silence. A parser that quietly ignores what it
    cannot read reports the same "all clear" whether the input was clean or was garbage, and the
    fleet channel is the one input nobody here can inspect by hand.
    """
    stat = by_origin[origin]
    try:
        fh = open(path, errors='ignore')
    except FileNotFoundError:
        return                      # the ordinary case: this origin has no retros.log
    except OSError as e:
        # A permission or I/O error is NOT an empty source. Swallowing it produced a digest that
        # reported zero rows for an origin and looked exactly like a quiet week.
        stat.unreadable += 1
        sys.stderr.write(f'retro-mine: cannot read {path} ({e.__class__.__name__}) — '
                         f'origin {origin} is UNDER-COUNTED in this digest\n')
        return
    with fh:
        for l in fh:
            if not l.startswith('RETRO:'): continue
            f = l[6:].strip().split('\t')
            if len(f) != 17 or not valid_day(f[0]):
                stat.malformed += 1
                continue
            if f[0][:10] < CUT: continue
            skills[f[1]] += 1; frictions[f[4]] += 1
            stat.rows += 1
            stat.skills[f[1]] += 1; stat.frictions[f[4]] += 1

mine_retros_md(H('~/.zuvo/retros.md'), 'mac')
mine_retros_log(H('~/.zuvo/retros.log'), 'mac')
for d in glob.glob(H('~/.zuvo/remote/*/')):
    for sub in glob.glob(d + '*/') + [d]:
        oid = 'fleet:' + d.rstrip('/').split('/')[-1] + '/' + (sub.rstrip('/').split('/')[-1] if sub != d else '')
        mine_retros_md(os.path.join(sub, 'retros.md'), oid)
        mine_retros_log(os.path.join(sub, 'retros.log'), oid)

backlogs = []
strays = []  # worktree-local copies: canonical backlog lives ONLY in the main checkout (zuvo backlog-protocol)
import subprocess as _sp
def _main_root(d):
    try:
        out = _sp.run(['git','-C',d,'worktree','list','--porcelain'], capture_output=True, text=True, timeout=5).stdout
        if out.startswith('worktree '): return out.splitlines()[0][9:]
    except Exception: pass
    return d
for f in glob.glob(H('~/DEV/*/memory/backlog.md')) + glob.glob(H('~/DEV/*/*/memory/backlog.md')) + glob.glob(H('~/.zuvo/remote/popebot/*/repos/*/memory/backlog.md')):
    try: t = open(f, errors='ignore').read()
    except Exception: continue
    if 'MOVED — canonical' in t[:200]: continue  # consolidation stub
    proj = f.replace(H('~/'), '~/').replace('/memory/backlog.md','')
    repo_dir = os.path.dirname(os.path.dirname(f))
    if f.startswith(H('~/DEV/')) and os.path.realpath(_main_root(repo_dir)) != os.path.realpath(repo_dir):
        strays.append(proj)  # forked worktree copy — protocol violation, flag, don't count
        continue
    op = len(re.findall(r'^\s*-\s*\[ \]', t, re.M)); dn = len(re.findall(r'^\s*-\s*\[x\]', t, re.M))
    dates = re.findall(r'\b(\d{4}-\d{2}-\d{2})\b', t)
    added_wk = sum(1 for d in dates if d >= CUT)
    oldest = min(dates) if dates else '?'
    if op or dn: backlogs.append((proj, op, dn, added_wk, oldest, hash(t)))
# group by canonical repo (git remote URL): worktree clones fork the same backlog and drift —
# count the repo ONCE (max open), and flag DIVERGED when copies disagree (a real debt-hygiene bug).
import subprocess
groups = {}
for b in backlogs:
    proj = b[0]; d = os.path.expanduser(proj)
    try:
        url = subprocess.run(['git','-C',d,'remote','get-url','origin'], capture_output=True, text=True, timeout=5).stdout.strip() or proj
    except Exception: url = proj
    groups.setdefault(url, []).append(b)
merged = []
for url, bs in groups.items():
    bs.sort(key=lambda x: -x[1])
    top = min(bs, key=lambda x: len(x[0]))  # canonical = shortest path
    name = top[0] + (f'  [{len(bs)} copies, open {min(x[1] for x in bs)}-{max(x[1] for x in bs)}' +
                     (' DIVERGED]' if len({x[5] for x in bs}) > 1 else ']') if len(bs) > 1 else '')
    merged.append((name, max(x[1] for x in bs), max(x[2] for x in bs), max(x[3] for x in bs), min(x[4] for x in bs)))
# NOT reassigned to `backlogs`: that name holds 6-tuples (…, hash(t)) and these are 5-tuples with
# the hash dropped after grouping. Rebinding one name to two shapes ran correctly but read as a
# bug at the unpack 20 lines down, which is where mypy flagged it — "Too many values to unpack
# (5 expected, 6 provided)". The runtime was fine; the name was not.
backlog_rows = sorted(merged, key=lambda x: -x[1])

ideas = []
for f in glob.glob(H('~/DEV/*/memory/ideas.md')) + glob.glob(H('~/DEV/*/*/memory/ideas.md')) + glob.glob(H('~/.zuvo/remote/popebot/*/repos/*/memory/ideas.md')):
    for l in open(f, errors='ignore'):
        m = re.match(r'- \[(\d{4}-\d{2}-\d{2})\]', l.strip())
        if m and m.group(1) >= CUT: ideas.append((f.replace(H('~/'), '~/'), l.strip()[:200]))

os.makedirs(H('~/.zuvo/mining'), exist_ok=True)
dst = H(f'~/.zuvo/mining/digest-{datetime.date.today()}.md')
with open(dst, 'w') as w:
    w.write(f'# Retro-mine digest — window {CUT}..today ({entries} retro entries)\n\n')
    w.write('## Friction histogram\n')
    for k, v in frictions.most_common(15): w.write(f'- {v}x {k}\n')
    w.write('\n## Skills\n')
    for k, v in skills.most_common(12): w.write(f'- {v}x {k}\n')
    # Placed BETWEEN `## Skills` and `## Change proposals` on purpose. digest-proposals parses
    # `###\s*P(\\d+)\\b(.*?)(?=\\n###\\s*P\\d|\\Z)`, so the LAST proposal block already swallows every
    # section that follows it; adding one more at the end would grow that swallow. Here it changes
    # nothing about what any parser sees.
    w.write('\n## Origin breakdown\n')
    w.write('| origin | rows | malformed | proposals | top friction | top skill |\n')
    w.write('|---|---|---|---|---|---|\n')
    for o in sorted(by_origin, key=lambda k: (-by_origin[k].rows, k)):
        st = by_origin[o]
        if not (st.rows or st.malformed or st.proposals or st.unreadable): continue
        tf = st.frictions.most_common(1); ts = st.skills.most_common(1)
        w.write(f"| {md_cell(o)} | {st.rows} | {st.malformed} | {st.proposals} | "
                f"{(md_cell(tf[0][0]) + ' x' + str(tf[0][1])) if tf else '-'} | "
                f"{(md_cell(ts[0][0]) + ' x' + str(ts[0][1])) if ts else '-'} |\n")
    hosts = collections.Counter()
    for o, st in by_origin.items(): hosts[origin_host(o)] += st.rows
    if hosts:
        w.write('\nBy source: ' + ', '.join(f'{h} {n}' for h, n in hosts.most_common()) + '\n')
    unread = sum(st.unreadable for st in by_origin.values())
    if unread:
        w.write(f'\n**{unread} retro log(s) could not be READ** (permission or I/O error, not '
                f'absence). Those origins are under-counted above — an unreadable source and a '
                f'quiet week produce the same zero, so it is stated rather than implied.\n')
    mal = sum(st.malformed for st in by_origin.values())
    if mal:
        w.write(f'\n**{mal} malformed retro line(s) skipped** — not 17 fields, or field 1 is not a '
                f'date. They are counted here rather than dropped in silence; see the per-origin '
                f'table for which install they came from.\n')
    # A structural limit, not an empty week. Anonymous fleet rollups ride the telemetry channel and
    # carry day/skill/code_type/friction/context_gap/counts only — no free text, so no retros.md and
    # therefore no `### Change Proposals` block can ever exist for them. Their rows can move a
    # histogram; they can never produce a proposal. Saying so beats a silent zero that reads like
    # "the fleet had nothing to say this week".
    fleet_rows = sum(st.rows for o, st in by_origin.items() if origin_host(o) == 'fleet')
    if fleet_rows:
        w.write(f'\n**Fleet rollups contribute histograms only ({fleet_rows} rows, 0 proposals '
                f'possible).** They are anonymous by omission — no project, branch, sha or free '
                f'text — so no retros.md exists to mine proposals from. Read them as signal about '
                f'WHERE friction happens, never as a source of change proposals.\n')

    w.write(f'\n## Change proposals ({len(proposals)})\n')
    for i, (o, h, t) in enumerate(proposals):
        w.write(f'\n### P{i} [{o}] {h}\n{t}\n')
    w.write(f'\n## Backlog health ({len(backlog_rows)} projects, {sum(b[1] for b in backlog_rows)} open total)\n')
    w.write('| project | open | done | added-this-week | oldest-date |\n|---|---|---|---|---|\n')
    for proj, op, dn, wk, old_ in backlog_rows[:20]:
        w.write(f'| {proj} | {op} | {dn} | {wk} | {old_} |\n')
    if strays:
        w.write(f'\n**PROTOCOL VIOLATION — {len(strays)} worktree-local backlog copies** (canonical backlog lives ONLY in the main checkout; these forked after consolidation and need re-merge):\n')
        for s in strays[:15]: w.write(f'- {s}\n')
    w.write(f'\n## New ideas ({len(ideas)})\n')
    for f, l in ideas: w.write(f'- ({f}) {l}\n')
print(f'DIGEST: {dst}')
print(f'  entries={entries} proposals={len(proposals)} ideas={len(ideas)} '
      f'backlog-projects={len(backlog_rows)} open-total={sum(b[1] for b in backlog_rows)}')
print(f'  top-frictions: {dict(frictions.most_common(5))}')
print(f'  top-skills: {dict(skills.most_common(5))}')
_hosts = collections.Counter()
for _o, _st in by_origin.items(): _hosts[origin_host(_o)] += _st.rows
_mal = sum(_st.malformed for _st in by_origin.values())
_unread = sum(_st.unreadable for _st in by_origin.values())
print(f'  rows-by-source: {dict(_hosts.most_common())} malformed={_mal} unreadable={_unread}')
