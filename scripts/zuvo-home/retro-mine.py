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
import os, re, glob, sys, collections, datetime
DAYS = int(sys.argv[sys.argv.index('--days')+1]) if '--days' in sys.argv else 7
CUT = (datetime.datetime.utcnow() - datetime.timedelta(days=DAYS)).strftime('%Y-%m-%d')
H = os.path.expanduser
out = []
frictions = collections.Counter(); skills = collections.Counter(); proposals = []; entries = 0

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
                if len(t) > 40: proposals.append((origin, head, t[:1200]))

def mine_retros_log(path, origin):
    try:
        for l in open(path, errors='ignore'):
            if not l.startswith('RETRO:'): continue
            f = l[6:].strip().split('\t')
            if len(f) > 4 and f[0][:10] >= CUT:
                skills[f[1]] += 1; frictions[f[4]] += 1
    except Exception: pass

mine_retros_md(H('~/.zuvo/retros.md'), 'mac')
mine_retros_log(H('~/.zuvo/retros.log'), 'mac')
for d in glob.glob(H('~/.zuvo/remote/*/')):
    for sub in glob.glob(d + '*/') + [d]:
        oid = 'fleet:' + d.rstrip('/').split('/')[-1] + '/' + (sub.rstrip('/').split('/')[-1] if sub != d else '')
        mine_retros_md(os.path.join(sub, 'retros.md'), oid)
        mine_retros_log(os.path.join(sub, 'retros.log'), oid)

backlogs = []
strays = []  # worktree-local copies: canonical backlog lives ONLY in the main checkout (zuvo backlog-protocol)
import datetime as _dt
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
backlogs = sorted(merged, key=lambda x: -x[1])

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
    w.write(f'\n## Change proposals ({len(proposals)})\n')
    for i, (o, h, t) in enumerate(proposals):
        w.write(f'\n### P{i} [{o}] {h}\n{t}\n')
    w.write(f'\n## Backlog health ({len(backlogs)} projects, {sum(b[1] for b in backlogs)} open total)\n')
    w.write('| project | open | done | added-this-week | oldest-date |\n|---|---|---|---|---|\n')
    for proj, op, dn, wk, old_ in backlogs[:20]:
        w.write(f'| {proj} | {op} | {dn} | {wk} | {old_} |\n')
    if strays:
        w.write(f'\n**PROTOCOL VIOLATION — {len(strays)} worktree-local backlog copies** (canonical backlog lives ONLY in the main checkout; these forked after consolidation and need re-merge):\n')
        for s in strays[:15]: w.write(f'- {s}\n')
    w.write(f'\n## New ideas ({len(ideas)})\n')
    for f, l in ideas: w.write(f'- ({f}) {l}\n')
print(f'DIGEST: {dst}')
print(f'  entries={entries} proposals={len(proposals)} ideas={len(ideas)} backlog-projects={len(backlogs)} open-total={sum(b[1] for b in backlogs)}')
print(f'  top-frictions: {dict(frictions.most_common(5))}')
print(f'  top-skills: {dict(skills.most_common(5))}')
