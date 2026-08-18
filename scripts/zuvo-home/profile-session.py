#!/bin/sh
# Polyglot sh/python header. `#!/usr/bin/env python3` fails on Windows: python.org installs
# `python` and `py`, Git Bash ships neither, and the shebang dies with
#     env: python3: No such file or directory
# (reproduced). /bin/sh executes the next line, which re-execs this file with whatever Python 3
# the machine actually has; Python parses that same line as a string literal and ignores it.
# Keep it on ONE line and do not "tidy" the quoting — both interpreters depend on it exactly.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
# Rozbiera transkrypt agenta (Claude Code JSONL lub Codex rollout JSONL) na kategorie czasu.
# Uzycie: python3 profile_session.py <plik.jsonl> [window_start_iso] [window_end_iso]
import sys, json, re, datetime, os, hashlib

USAGE = """profile-session — attribute a session's wall-clock time to categories.

  profile-session <transcript.jsonl> [window_start_iso] [window_end_iso]

Accepts a Claude Code session JSONL or a Codex rollout JSONL. Answers "why was this
session slow" from timestamps: gaps are attributed to the surrounding tool/agent activity.

Find a transcript:
  ls -t ~/.claude/projects/*/*.jsonl | head        # Claude Code
  ls -t ~/.codex/sessions/**/rollout-*.jsonl | head  # Codex
"""

# --run-key <transcript> [start] [end] — print the IDENTITY of this analysis and exit (B-PROFILE-DEDUP).
#
# The retro layer deduplicates on skill+project+sha7, and `project` is the directory the skill was
# INVOKED in. For most skills that is right — a review of repo A is not a review of repo B. For this
# one it is wrong, because the artifact being analysed is a TRANSCRIPT, and a transcript is the same
# transcript whichever worktree the agent happened to sit in.
#
# Measured 2026-08-18: ONE Codex rollout was profiled at least eight times in a day, logged under
# five different "projects" (mutation-data-flush-final, rs_be, tgm-survey-platform,
# ResearchShieldNew, mutation-data-flush-profile-detailed), so the key never matched and every run
# looked new. 12 profile-session runs that day, 25-45 min of agent work each. It also explains the
# contradictory self-reports: some runs printed "idempotent no-op", others did the full analysis,
# purely by invocation site.
#
# The key is the realpath of the transcript plus the window bounds — the inputs that determine the
# ANSWER — and nothing about the caller. It reads no bytes of the transcript, so the guard is cheap
# enough to run BEFORE the analysis rather than at the retro write, which is the second half of the
# defect: a write-time guard saves a line in a file, not the 25 minutes of work.
if len(sys.argv) > 1 and sys.argv[1] == "--run-key":
    if len(sys.argv) < 3:
        sys.stderr.write("profile-session: --run-key needs a transcript path\n")
        sys.exit(2)
    _rk_path = os.path.realpath(sys.argv[2])
    _rk_win = "|".join(sys.argv[3:5]) if len(sys.argv) > 3 else ""
    print(hashlib.sha1((_rk_path + "|" + _rk_win).encode("utf-8", "ignore")).hexdigest()[:12])
    sys.exit(0)

if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
    sys.stderr.write(USAGE)
    sys.exit(0 if len(sys.argv) > 1 else 2)
path = sys.argv[1]
if not os.path.isfile(path):
    sys.stderr.write(f"profile-session: no such transcript: {path}\n\n" + USAGE)
    sys.exit(2)
ws = sys.argv[2] if len(sys.argv) > 2 else None
we = sys.argv[3] if len(sys.argv) > 3 else None
def pts(s):
    """ISO -> naive UTC. Both Claude Code and Codex emit Z exclusively (verified: 2943 and 4001
    samples, zero non-Z), so this never fires today — but CONVERTING to UTC before dropping the
    tzinfo costs nothing and means a future transcript carrying a real offset is not silently
    mis-ordered by that offset's worth of minutes."""
    try:
        d = datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
        return d.astimezone(datetime.timezone.utc).replace(tzinfo=None) if d.tzinfo else d
    except Exception:
        return None
events=[]
# Labels are truncated for display (150/200/320 chars). Classification used to run on the TRUNCATED
# string, so a reviewer invoked through the shell as
#   cd /Users/…/very/long/worktree/path && bash ~/.zuvo/adversarial-review --rotate …
# lost the word "adversarial" past the cut and was silently filed under `other-tools` — which is
# how a profile can report `adversarial_calls: 0` for a session that ran several. The tag is
# therefore computed from the FULL text and prepended, so the truncated label still carries it.
_TAGS = (
    ('adversarial', re.compile(r'adversarial|reviewer-preflight|blind-audit', re.I)),
    ('subagent',    re.compile(r'\bsubagent_type\b|\bTask\b|agent-dispatch', re.I)),
)
def _tag(full, label):
    hits = [n for n, rx in _TAGS if rx.search(full) and n not in label.lower()]
    return ('[' + ']['.join(hits) + ']' + label) if hits else label

toks=[]
subtoks=[]
with open(path, errors='ignore') as f:
    for line in f:
        line=line.strip()
        if not line: continue
        try: d=json.loads(line)
        except: continue
        ts=d.get('timestamp')
        p=d.get('payload') or {}
        if not isinstance(ts,str): ts=p.get('timestamp') if isinstance(p.get('timestamp'),str) else None
        t=pts(ts) if ts else None
        if not t: continue
        typ=d.get('type',''); kind='other'; label=''
        if typ in ('user','human'):
            c=(d.get('message') or {}).get('content')
            tool=isinstance(c,list) and any(isinstance(x,dict) and x.get('type')=='tool_result' for x in c)
            kind='tool_result' if tool else 'user_msg'
        elif typ=='assistant':
            c=(d.get('message') or {}).get('content'); names=[]
            if isinstance(c,list):
                for x in c:
                    if isinstance(x,dict) and x.get('type')=='tool_use':
                        inp=x.get('input') or {}
                        cmd=inp.get('command') or inp.get('prompt') or inp.get('description') or inp.get('skill') or ''
                        names.append(f"{x.get('name','?')}:{str(cmd)[:400]}")
            if names:
                kind='tool_use'; _full=' | '.join(names); label=_tag(_full, _full[:320])
            else: kind='assistant_text'
        elif typ=='system':
            kind='system'; label=str(d.get('content','') or d.get('subtype',''))[:150]
        elif typ in ('response_item','event_msg','turn_context','compacted'):
            pt=p.get('type','')
            if pt in ('function_call','local_shell_call','custom_tool_call','web_search_call'):
                # Codex has moved the payload key more than once: `arguments` (function_call),
                # `action` (local_shell_call), and `input` on the newer `custom_tool_call`. Reading
                # only the first two left every custom_tool_call labelled as a bare `exec:` with no
                # command text — so tests/build, adversarial review and everything else classified
                # as `other-tools`, and a session that ran reviewers reported adversarial_calls: 0.
                arg = (p.get('arguments') or p.get('action') or p.get('input')
                       or p.get('command') or '')
                _full=str(p.get('name','sh'))+':'+str(arg)
                kind='tool_use'; label=_tag(_full, _full[:320])
            elif pt in ('function_call_output','local_shell_call_output','custom_tool_call_output'): kind='tool_result'
            elif pt=='message': kind='user_msg' if p.get('role')=='user' else 'assistant_text'
            elif pt=='reasoning': kind='assistant_text'; label='reasoning'
            else: kind='codex_'+str(pt)[:24]
        events.append((t,kind,label))
        # --- TOKEN ACCOUNTING (deterministic) ------------------------------------------------
        # Five hand-written profiles of ONE Codex session reported gross 202,362,002 vs
        # 203,519,738, model calls 1395 vs 1406, and a "strict lower bound" for polling of
        # 45 / 55 / 83 / 396 / 400 calls -- a 9x spread, every figure labelled MEASURED. They
        # disagreed because the skill declared token cost out of scope, so each run re-derived
        # the numbers by hand. The trap that makes hand-derivation unreliable is right here:
        # THE TWO TRANSCRIPT FORMATS DEFINE input_tokens WITH OPPOSITE CACHE SEMANTICS.
        #   Codex  payload.info.last_token_usage : input_tokens INCLUDES cached_input_tokens
        #   Claude message.usage                 : input_tokens EXCLUDES cache_read/cache_creation
        # Aliasing the key names together (as a generic reader is tempted to) silently under-counts
        # every Claude session by the whole cache-read volume, which is most of it. So each format
        # is read explicitly, and `gross` means the same thing in both: everything billed on the
        # way in, plus everything generated.
        _u = None
        if isinstance(p.get('info'), dict) and isinstance(p['info'].get('last_token_usage'), dict):
            _u = p['info']['last_token_usage']                     # codex
            _in = int(_u.get('input_tokens') or 0)                 # already includes cache
            _cached = int(_u.get('cached_input_tokens') or 0)
            _out = int(_u.get('output_tokens') or 0)
            _reas = int(_u.get('reasoning_output_tokens') or 0)
        elif isinstance(d.get('message'), dict) and isinstance(d['message'].get('usage'), dict):
            _u = d['message']['usage']                             # claude main loop
            _cached = int(_u.get('cache_read_input_tokens') or 0)
            _in = (int(_u.get('input_tokens') or 0)
                   + int(_u.get('cache_creation_input_tokens') or 0) + _cached)
            _out = int(_u.get('output_tokens') or 0)
            _reas = 0
        if _u is not None:
            toks.append((t, _in, _cached, _out, _reas))
        # Sub-agent spend arrives inside a tool_result (`toolUseResult.usage`) and is NOT part of
        # the main loop's own usage. It is counted, but SEPARATELY -- folding it into `gross`
        # would make a session with sub-agents look like one enormous context window.
        _sub = d.get('toolUseResult')
        if isinstance(_sub, dict) and isinstance(_sub.get('usage'), dict):
            _su = _sub['usage']
            subtoks.append((int(_su.get('input_tokens') or 0)
                            + int(_su.get('cache_creation_input_tokens') or 0)
                            + int(_su.get('cache_read_input_tokens') or 0),
                            int(_su.get('output_tokens') or 0)))
events.sort(key=lambda e:e[0])
toks.sort(key=lambda e:e[0])
for _bound, _val, _keep in (("window_start", ws, True), ("window_end", we, False)):
    if not _val:
        continue
    _w = pts(_val)
    if _w is None:
        # A malformed bound used to reach the comparison and raise TypeError (datetime vs None).
        # Refusing loudly beats both crashing and silently profiling the whole file as if no
        # window had been asked for.
        sys.stderr.write(f"profile-session: {_bound} is not an ISO timestamp: {_val!r}\n")
        sys.exit(2)
    events = [e for e in events if (e[0] >= _w if _keep else e[0] <= _w)]
    toks   = [e for e in toks   if (e[0] >= _w if _keep else e[0] <= _w)]
if len(events)<3: print(json.dumps({'file':path,'error':'too few events in window','events':len(events)})); sys.exit()
def cat(kind,label):
    l=label.lower()
    if kind=='tool_use':
        if 'adversarial' in l: return 'adversarial-review'
        if re.search(r'vitest|jest|npm (run )?test|pnpm (run )?test|yarn test|turbo.*(test|build)|pytest|tsc\b|typecheck|npm run build|pnpm build|next build', l): return 'tests/build'
        if l.startswith('task:') or 'subagent' in l: return 'subagent-dispatch'
        if l.startswith('skill:'): return 'skill-invoke'
        return 'other-tools'
    if kind in ('assistant_text','tool_result'): return 'model-api-thinking'
    if kind=='user_msg': return 'user-idle'
    if kind=='system': return 'system-hooks'
    return kind
# A gap is charged to the category of the event BEFORE it. That is only sound while the gap is
# short enough for the preceding activity to plausibly still be running. It was previously guarded
# for exactly two categories, so a `system` line (a hook message — milliseconds of work) could own
# a 24-HOUR gap and land 2187 minutes in "system-hooks" on a 38-hour span, burying every real
# finding. Attribution is now bounded for every category.
#
#   <= LONG          attribute normally
#   LONG..IMPLAUSIBLE attribute only to things that genuinely run long (tests/build, subagent
#                     dispatch, adversarial review); anything else is a stall or the user away
#   >  IMPLAUSIBLE    nothing in-session runs this long without emitting an event — session
#                     boundary, never charged to the preceding activity
LONG = float(os.environ.get("ZUVO_PROFILE_LONG_GAP_S", 1800))       # 30 min
IMPLAUSIBLE = float(os.environ.get("ZUVO_PROFILE_MAX_GAP_S", 14400))  # 4 h
LONG_RUNNERS = {"tests/build", "subagent-dispatch", "adversarial-review"}

cats={}; rows=[]
for i in range(len(events)-1):
    t,k,lab=events[i]; gap=(events[i+1][0]-t).total_seconds()
    if gap<=0: continue
    c=cat(k,lab)
    if gap > IMPLAUSIBLE:
        c = 'session-boundary/away(excluded)'
    elif gap > LONG:
        if c == 'user-idle':
            c = 'user-idle-long(excluded)'
        elif c not in LONG_RUNNERS:
            c = f'stall-or-idle>{int(LONG/60)}m'
        # a long-runner keeps its category — that IS the signal this tool exists to surface
    cats[c]=cats.get(c,0)+gap; rows.append((gap,t,c,lab or k))
rows.sort(key=lambda r:-r[0])
# os.path.basename on the parent, NOT split('/')[-2] — a bare `file.jsonl` (no separator) made
# that index raise IndexError, so the tool crashed on the most natural way to invoke it.
_parent = os.path.basename(os.path.dirname(os.path.abspath(path)))
out={'file':(_parent + '/' if _parent else '') + os.path.basename(path)[:18],'events':len(events),
 'window':[events[0][0].isoformat()[:16],events[-1][0].isoformat()[:16]],
 'span_h':round((events[-1][0]-events[0][0]).total_seconds()/3600,2),
 'categories_min':{k:round(v/60,1) for k,v in sorted(cats.items(),key=lambda x:-x[1])},
 'top_gaps':[{'min':round(g/60,1),'at':t.isoformat()[5:16],'cat':c,'what':w[:180]} for g,t,c,w in rows[:20]],
 'counts':{'tool_uses':sum(1 for _,k,_ in events if k=='tool_use'),
   'adversarial_calls':sum(1 for _,k,l in events if k=='tool_use' and 'adversarial' in l.lower()),
   'task_dispatches':sum(1 for _,k,l in events if k=='tool_use' and l.lower().startswith('task:')),
   'user_msgs':sum(1 for _,k,_ in events if k=='user_msg')}}

# --- tokens: ONE definition, applied the same way every run ---------------------------------
# `polling` is deliberately a NARROW, FIXED tool-label pattern, not a judgement about which calls
# "felt like waiting". A judgement re-made per run is what produced a 9x spread across five
# profiles of one transcript. If this list is wrong it is wrong reproducibly, which can be argued
# about; a per-run classifier cannot be.
POLL_RE = re.compile(r'(rt\s+--?(attach|queue|log|stats|summary|wait)'
                     r'|gh\s+(pr\s+checks|run\s+(view|watch|list))'
                     r'|\bwait\b|write_stdin'
                     r'|gh\s+api\s+.*(check-runs|actions/runs))', re.I)
if toks:
    _tot = lambda idx: sum(r[idx] for r in toks)
    _inp, _cached, _outp, _reas = _tot(1), _tot(2), _tot(3), _tot(4)
    # A token row is attributed to polling when the NEAREST PRECEDING tool_use matches POLL_RE.
    _tool_events = [(t,l) for t,k,l in events if k=='tool_use']
    _p_calls=_p_in=_p_cached=_p_out=0
    for _t,_i,_c,_o,_r in toks:
        _prev = None
        for _tt,_ll in _tool_events:
            if _tt <= _t: _prev = _ll
            else: break
        if _prev and POLL_RE.search(_prev):
            _p_calls += 1; _p_in += _i; _p_cached += _c; _p_out += _o
    out['tokens'] = {
        'model_calls': len(toks),
        'input': _inp, 'cached_input': _cached, 'output': _outp, 'reasoning_output': _reas,
        'gross': _inp + _outp,
        'fresh': _inp - _cached + _outp,
        'polling': {'calls': _p_calls, 'gross': _p_in + _p_out, 'fresh': _p_in - _p_cached + _p_out,
                    'pct_gross': round(100.0*(_p_in+_p_out)/max(1,_inp+_outp), 2)},
        'subagents': {'calls': len(subtoks), 'gross': sum(a+b for a,b in subtoks)},
        'classifier': POLL_RE.pattern,
        'note': 'gross = all billed input (incl. cache) + output; fresh excludes cache reads; reasoning_output is a SUBSET of output; subagent spend is NOT in gross'}
else:
    out['tokens'] = {'model_calls': 0,
        'note': 'no last_token_usage/usage records in this transcript — report tokens as UNKNOWN, never hand-derive them'}
print(json.dumps(out,ensure_ascii=False,indent=1))
