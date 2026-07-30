#!/usr/bin/env python3
# Rozbiera transkrypt agenta (Claude Code JSONL lub Codex rollout JSONL) na kategorie czasu.
# Uzycie: python3 profile_session.py <plik.jsonl> [window_start_iso] [window_end_iso]
import sys, json, re, datetime, os

USAGE = """profile-session — attribute a session's wall-clock time to categories.

  profile-session <transcript.jsonl> [window_start_iso] [window_end_iso]

Accepts a Claude Code session JSONL or a Codex rollout JSONL. Answers "why was this
session slow" from timestamps: gaps are attributed to the surrounding tool/agent activity.

Find a transcript:
  ls -t ~/.claude/projects/*/*.jsonl | head        # Claude Code
  ls -t ~/.codex/sessions/**/rollout-*.jsonl | head  # Codex
"""

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
    try: return datetime.datetime.fromisoformat(s.replace('Z','+00:00')).replace(tzinfo=None)
    except: return None
events=[]
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
                        names.append(f"{x.get('name','?')}:{str(cmd)[:150]}")
            if names: kind='tool_use'; label=' | '.join(names)[:320]
            else: kind='assistant_text'
        elif typ=='system':
            kind='system'; label=str(d.get('content','') or d.get('subtype',''))[:150]
        elif typ in ('response_item','event_msg','turn_context','compacted'):
            pt=p.get('type','')
            if pt in ('function_call','local_shell_call','custom_tool_call','web_search_call'):
                arg=p.get('arguments') or p.get('action') or ''
                kind='tool_use'; label=(str(p.get('name','sh'))+':'+str(arg)[:200])[:320]
            elif pt in ('function_call_output','local_shell_call_output','custom_tool_call_output'): kind='tool_result'
            elif pt=='message': kind='user_msg' if p.get('role')=='user' else 'assistant_text'
            elif pt=='reasoning': kind='assistant_text'; label='reasoning'
            else: kind='codex_'+str(pt)[:24]
        events.append((t,kind,label))
events.sort(key=lambda e:e[0])
if ws:
    w=pts(ws); events=[e for e in events if e[0]>=w]
if we:
    w=pts(we); events=[e for e in events if e[0]<=w]
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
cats={}; rows=[]
for i in range(len(events)-1):
    t,k,lab=events[i]; gap=(events[i+1][0]-t).total_seconds()
    if gap<=0: continue
    c=cat(k,lab)
    if c=='user-idle' and gap>1800: c='user-idle-long(excluded)'
    if c=='model-api-thinking' and gap>1800: c='stall/api-error-or-idle>30m'
    cats[c]=cats.get(c,0)+gap; rows.append((gap,t,c,lab or k))
rows.sort(key=lambda r:-r[0])
out={'file':path.split('/')[-2]+'/'+path.split('/')[-1][:18],'events':len(events),
 'window':[events[0][0].isoformat()[:16],events[-1][0].isoformat()[:16]],
 'span_h':round((events[-1][0]-events[0][0]).total_seconds()/3600,2),
 'categories_min':{k:round(v/60,1) for k,v in sorted(cats.items(),key=lambda x:-x[1])},
 'top_gaps':[{'min':round(g/60,1),'at':t.isoformat()[5:16],'cat':c,'what':w[:180]} for g,t,c,w in rows[:20]],
 'counts':{'tool_uses':sum(1 for _,k,_ in events if k=='tool_use'),
   'adversarial_calls':sum(1 for _,k,l in events if k=='tool_use' and 'adversarial' in l.lower()),
   'task_dispatches':sum(1 for _,k,l in events if k=='tool_use' and l.lower().startswith('task:')),
   'user_msgs':sum(1 for _,k,_ in events if k=='user_msg')}}
print(json.dumps(out,ensure_ascii=False,indent=1))
