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
import sys
import json
import re
import datetime
import os
import stat
import hashlib
import argparse
import tempfile
from contextlib import suppress
from typing import Any, NoReturn

ACCOUNTING_VERSION = 2

USAGE = """profile-session — attribute a session's wall-clock time to categories.

  profile-session <transcript.jsonl> [window_start_iso] [window_end_iso] [--usage-jsonl PATH]

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
    _rk_identity = str(ACCOUNTING_VERSION) + "|" + _rk_path + "|" + _rk_win
    print(hashlib.sha1(_rk_identity.encode("utf-8", "ignore")).hexdigest()[:12])
    sys.exit(0)

def fail(message: str) -> NoReturn:
    sys.stderr.write(f"profile-session: {message}\n")
    sys.exit(2)


parser = argparse.ArgumentParser(description=USAGE)
parser.add_argument("transcript")
parser.add_argument("window_start", nargs="?")
parser.add_argument("window_end", nargs="?")
parser.add_argument("--usage-jsonl", metavar="PATH")
args = parser.parse_args()
path, ws, we = args.transcript, args.window_start, args.window_end
if not os.path.isfile(path):
    fail(f"no such transcript: {path}")
if args.usage_jsonl:
    same_path = os.path.realpath(args.usage_jsonl) == os.path.realpath(path)
    try:
        same_file = os.path.exists(args.usage_jsonl) and os.path.samefile(args.usage_jsonl, path)
    except OSError as error:
        fail(f"cannot inspect usage output: {error.strerror}")
    if same_path or same_file:
        fail("usage output must not replace the transcript")
    try:
        output_mode = os.lstat(args.usage_jsonl).st_mode
    except FileNotFoundError:
        pass  # A new regular file will be created by the atomic writer.
    except OSError as error:
        fail(f"cannot inspect usage output: {error.strerror}")
    else:
        if not stat.S_ISREG(output_mode):
            fail("usage output must be a regular file, not a directory, symlink or special node")
def pts(s):
    """ISO -> naive UTC. Both Claude Code and Codex emit Z exclusively (verified: 2943 and 4001
    samples, zero non-Z), so this never fires today — but CONVERTING to UTC before dropping the
    tzinfo costs nothing and means a future transcript carrying a real offset is not silently
    mis-ordered by that offset's worth of minutes."""
    try:
        d = datetime.datetime.fromisoformat(s.replace('Z', '+00:00'))
        return d.astimezone(datetime.timezone.utc).replace(tzinfo=None) if d.tzinfo else d
    except (ValueError, TypeError, AttributeError, OverflowError, OSError):
        return None
start, end = pts(ws) if ws else None, pts(we) if we else None
if ws and start is None:
    fail("window_start is not an ISO timestamp")
if we and end is None:
    fail("window_end is not an ISO timestamp")
if start is not None and end is not None and start >= end:
    fail("window_start must precede window_end")


def in_window(timestamp: datetime.datetime) -> bool:
    return (start is None or timestamp >= start) and (end is None or timestamp < end)


def token_value(usage: dict[str, Any], key: str, *, required: bool = False) -> int:
    if required and key not in usage:
        fail(f"usage is missing required {key}")
    value = usage.get(key, 0)
    if type(value) is not int or value < 0:
        fail(f"{key} must be a nonnegative integer")
    return value


def identity(value: Any) -> str | None:
    return value if isinstance(value, str) and value.strip() else None


def usage_row(timestamp: datetime.datetime, usage: dict[str, Any], provider: str,
              source: str, response: Any, thread: Any, parent: Any) -> dict[str, Any]:
    inp = token_value(usage, "input_tokens", required=True)
    output = token_value(usage, "output_tokens", required=True)
    reasoning = 0
    if provider == "claude":
        cached = token_value(usage, "cache_read_input_tokens")
        inp += cached + token_value(usage, "cache_creation_input_tokens")
    else:
        cached = token_value(usage, "cached_input_tokens")
        reasoning = token_value(usage, "reasoning_output_tokens")
    if cached > inp or reasoning > output:
        fail("cached input or reasoning output exceeds its total")
    response_id = identity(response)
    return {"accounting_version": ACCOUNTING_VERSION, "timestamp": timestamp.isoformat() + "Z",
            "provider": provider, "response_id": response_id, "thread_id": identity(thread),
            "parent_id": identity(parent), "input": inp, "cached_input": cached, "output": output,
            "reasoning_output": reasoning, "fresh": inp - cached + output, "gross": inp + output,
            "source": source, "polling_proxy": None, "missing_response_id": response_id is None}


def deduplicate(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    # File order is the final-usage authority, not maximum cost or timestamp. Unknown IDs
    # remain independent observations, explicitly ambiguous to downstream consumers.
    known: dict[tuple[str, str], dict[str, Any]] = {}
    unknown = []
    for row in rows:
        if row["response_id"] is None:
            unknown.append(row)
        else:
            known[(row["provider"], row["response_id"])] = row
    return sorted([*known.values(), *unknown],
                  key=lambda row: datetime.datetime.fromisoformat(row["timestamp"][:-1]))


def write_usage(destination: str, rows: list[dict[str, Any]]) -> None:
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False,
                                         dir=os.path.dirname(os.path.abspath(destination))) as handle:
            temporary = handle.name
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    except OSError as error:
        fail(f"cannot write usage output: {error.strerror}")
    finally:
        if temporary:
            with suppress(OSError):
                os.unlink(temporary)


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

usage_events=[]
usage_records=[]
thread_id = parent_id = None
subtoks=[]
_thread_total=None
_compactions=0
try:
    transcript = open(path, encoding="utf-8", errors="replace")
except OSError as error:
    fail(f"cannot read transcript: {error.strerror}")
with transcript as f:
    for line in f:
        line=line.strip()
        if not line: continue
        # malformed JSONL line; NOT bare — a bare except here also swallowed KeyboardInterrupt
        # on a multi-million-line transcript
        try: d=json.loads(line)
        except (ValueError, TypeError): continue
        if not isinstance(d, dict): continue
        ts=d.get('timestamp')
        p=d.get('payload')
        p = p if isinstance(p, dict) else {}
        if d.get('type') == 'session_meta':
            thread_id = identity(p.get('id')) or thread_id
            source = p.get('source')
            subagent = source.get('subagent') if isinstance(source, dict) else None
            spawn = subagent.get('thread_spawn') if isinstance(subagent, dict) else None
            if isinstance(spawn, dict):
                parent_id = identity(spawn.get('parent_thread_id')) or parent_id
        if not isinstance(ts,str): ts=p.get('timestamp') if isinstance(p.get('timestamp'),str) else None
        t=pts(ts) if ts else None
        if not t: continue
        typ=d.get('type',''); kind='other'; label=''
        message = d.get('message')
        is_chat = typ in ('user', 'human', 'assistant')
        if is_chat and message is not None and not isinstance(message, dict):
            fail("message must be an object")
        content = message.get('content') if isinstance(message, dict) else None
        if is_chat and content is not None and not isinstance(content, (str, list)):
            fail("message content must be text or an array")
        if typ in ('user','human'):
            c=content
            tool=isinstance(c,list) and any(isinstance(x,dict) and x.get('type')=='tool_result' for x in c)
            kind='tool_result' if tool else 'user_msg'
        elif typ=='assistant':
            c=content; names=[]
            if isinstance(c,list):
                for x in c:
                    if isinstance(x,dict) and x.get('type')=='tool_use':
                        inp=x.get('input')
                        if inp is not None and not isinstance(inp, dict):
                            fail("tool input must be an object")
                        inp = inp or {}
                        cmd=(inp.get('command') or inp.get('prompt') or inp.get('description')
                             or inp.get('skill') or '')
                        names.append(f"{x.get('name','?')}:{str(cmd)[:400]}")
            if names:
                kind='tool_use'; _full=' | '.join(names); label=_tag(_full, _full[:320])
            else: kind='assistant_text'
        elif typ=='system':
            kind='system'; label=str(d.get('content','') or d.get('subtype',''))[:150]
        elif typ=='token_usage_record':
            kind='codex_token_usage_record'
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
            elif pt in ('function_call_output','local_shell_call_output','custom_tool_call_output'):
                kind='tool_result'
            elif pt=='message': kind='user_msg' if p.get('role')=='user' else 'assistant_text'
            elif pt=='reasoning': kind='assistant_text'; label='reasoning'
            else: kind='codex_'+str(pt)[:24]
        events.append((t,kind,label))
        # Codex input includes cache; Claude input excludes cache read AND creation.
        # Parent tool summaries are separate aggregates, never individual child responses.
        if (typ == 'compacted' or (typ == 'system' and d.get('subtype') == 'compact_boundary')) and (
            in_window(t)
        ):
            _compactions += 1
        rec = p.get('usage') if typ == 'token_usage_record' else None
        if isinstance(rec, dict):
            usage_records.append(usage_row(t, rec, "codex", "token_usage_record", p.get('response_id'),
                                           p.get('thread_id') or thread_id, p.get('parent_id') or parent_id))
            total = p.get('thread_token_usage')
            if isinstance(total, dict) and total.get('total_tokens') is not None:
                _thread_total = token_value(total, 'total_tokens')  # lifetime, never imputed into a window
        info, message = p.get('info'), d.get('message')
        if isinstance(info, dict) and isinstance(info.get('last_token_usage'), dict):
            usage_events.append(usage_row(t, info['last_token_usage'], "codex", "info.last_token_usage",
                                          p.get('response_id'), p.get('thread_id') or thread_id,
                                          p.get('parent_id') or parent_id))
        elif isinstance(message, dict) and isinstance(message.get('usage'), dict):
            usage_events.append(usage_row(t, message['usage'], "claude", "message.usage", message.get('id'),
                                          d.get('sessionId'), d.get('parentSessionId')))
        sub = d.get('toolUseResult')
        if isinstance(sub, dict) and isinstance(sub.get('usage'), dict) and in_window(t):
            summary = usage_row(t, sub['usage'], "claude", "toolUseResult.usage", None, None, None)
            subtoks.append((summary['input'], summary['output']))
events.sort(key=lambda event: event[0])
# A response in the window can still follow a tool invoked just before its start.
_tool_events = [(t, label) for t, kind, label in events if kind == 'tool_use']
# Deduplicate the entire source FIRST: a final fragment outside the window must remove
# the earlier in-window fragment. Do not combine Codex's authoritative and UI streams.
selected_events = [row for row in usage_events if not usage_records or row['provider'] != 'codex']
selected = deduplicate([*usage_records, *selected_events])
usage_rows = [row for row in selected if in_window(datetime.datetime.fromisoformat(row['timestamp'][:-1]))]
sources = {row['source'] for row in usage_rows}
tok_source = next(iter(sources)) if len(sources) == 1 else ('mixed' if sources else 'none')
events = [event for event in events if in_window(event[0])]
toks = [(datetime.datetime.fromisoformat(row['timestamp'][:-1]), row['input'], row['cached_input'],
         row['output'], row['reasoning_output']) for row in usage_rows]
def cat(kind,label):
    l=label.lower()
    if kind=='tool_use':
        if 'adversarial' in l: return 'adversarial-review'
        if re.search(r'vitest|jest|npm (run )?test|pnpm (run )?test|yarn test|turbo.*(test|build)'
                     r'|pytest|tsc\b|typecheck|npm run build|pnpm build|next build', l):
            return 'tests/build'
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
out={'accounting_version': ACCOUNTING_VERSION,
 'file':(_parent + '/' if _parent else '') + os.path.basename(path)[:18], 'events':len(events),
 'window':([events[0][0].isoformat()[:16],events[-1][0].isoformat()[:16]] if events else []),
 'span_h':round((events[-1][0]-events[0][0]).total_seconds()/3600,2) if events else 0,
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
    def _tot(idx):
        return sum(r[idx] for r in toks)
    _inp, _cached, _outp, _reas = _tot(1), _tot(2), _tot(3), _tot(4)
    # A token row is attributed to polling when the NEAREST PRECEDING tool_use matches POLL_RE.
    _p_calls=_p_in=_p_cached=_p_out=0
    _cursor = 0
    _prev = None
    for row, (_t, _i, _c, _o, _r) in zip(usage_rows, toks, strict=True):
        while _cursor < len(_tool_events) and _tool_events[_cursor][0] <= _t:
            _prev = _tool_events[_cursor][1]
            _cursor += 1
        if _prev and POLL_RE.search(_prev):
            row['polling_proxy'] = 'tool-label-regex-v1'
            _p_calls += 1; _p_in += _i; _p_cached += _c; _p_out += _o
    out['tokens'] = {
        'model_calls': len(toks),
        'missing_response_ids': sum(row['missing_response_id'] for row in usage_rows),
        'source': tok_source,
        'thread_total_tokens': _thread_total,
        'compactions': _compactions,
        'input': _inp, 'cached_input': _cached, 'output': _outp, 'reasoning_output': _reas,
        'gross': _inp + _outp,
        'fresh': _inp - _cached + _outp,
        'polling': {'calls': _p_calls, 'gross': _p_in + _p_out, 'fresh': _p_in - _p_cached + _p_out,
                    'pct_gross': round(100.0*(_p_in+_p_out)/max(1,_inp+_outp), 2)},
        'subagents': {'calls': len(subtoks), 'gross': sum(a+b for a,b in subtoks)},
        'covers_full_thread': (None if (_thread_total is None or ws or we or tok_source == 'mixed')
                               else (_inp + _outp) == _thread_total),
        'classifier': POLL_RE.pattern,
        'note': ('gross = all billed input (incl. cache) + output; fresh excludes cache reads; '
                 'reasoning_output is a SUBSET of output; subagent spend is NOT in gross. '
                 'known response IDs use final usage before [start,end) filtering; '
                 'missing IDs remain ambiguous. '
                 'source=info.last_token_usage is a UI stream that repeats rows and omits some '
                 'calls; totals may over- or under-count. covers_full_thread=false means this '
                 'transcript is a RESUMED/compacted continuation: thread_total_tokens counts spend '
                 'from before this file, so gross describes THIS transcript only and the two are '
                 'not comparable. null = a window was given, so the question does not apply.')}
else:
    out['tokens'] = {'model_calls': 0, 'missing_response_ids': 0, 'compactions': _compactions,
        'subagents': {'calls': len(subtoks), 'gross': sum(a+b for a,b in subtoks)},
        'source': tok_source,
        'note': ('no token_usage_record/last_token_usage/usage rows in the selected window — '
                 'report tokens as UNKNOWN, never hand-derive them')}
if args.usage_jsonl:
    write_usage(args.usage_jsonl, usage_rows)
print(json.dumps(out,ensure_ascii=False,indent=1))
