#!/usr/bin/env bash
# test-profile-session-tokens.sh — profile-session.py must MEASURE tokens, not leave them to prose.
#
# Why this exists: five profiles of ONE Codex session reported gross 202,362,002 vs 203,519,738,
# 1,395 vs 1,406 model calls, and a polling "lower bound" of 45/55/83/396/400 calls — a 9x spread,
# every figure labelled MEASURED. The skill had declared token cost out of scope, so the script
# computed none and each run hand-derived them with its own classifier. Three defects were behind
# the spread and each one gets an assertion here:
#   1. no token accounting at all
#   2. the two formats define input_tokens with OPPOSITE cache semantics (codex includes cache,
#      claude excludes it) — aliasing the keys under-counts claude by nearly its whole volume
#   3. classification ran on the DISPLAY-TRUNCATED label, and newer codex rollouts put the command
#      under `custom_tool_call.input` (not `arguments`/`action`), so tool text vanished entirely
#      and a session that ran reviewers reported adversarial_calls: 0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
PS="$ROOT/scripts/zuvo-home/profile-session.py"
PASS=0; FAIL=0
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- fixture: codex rollout, new custom_tool_call shape, cache INCLUDED in input_tokens ---------
CX="$TMP/codex.jsonl"
{
  for i in 1 2 3 4 5 6; do
    printf '{"type":"response_item","timestamp":"2026-08-17T10:0%s:00.000Z","payload":{"type":"custom_tool_call","name":"exec","input":"cd /Users/x/very/long/worktree/path/that/eats/the/label/budget/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa && bash ~/.zuvo/adversarial-review --rotate"}}\n' "$i"
    printf '{"type":"event_msg","timestamp":"2026-08-17T10:0%s:30.000Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":900,"output_tokens":100,"reasoning_output_tokens":40}}}}\n' "$i"
  done
} > "$CX"

# --- fixture: claude transcript, cache EXCLUDED from input_tokens -------------------------------
CL="$TMP/claude.jsonl"
{
  for i in 1 2 3 4 5 6; do
    printf '{"type":"assistant","timestamp":"2026-08-17T11:0%s:00.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}],"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":900,"output_tokens":100}}}\n' "$i"
    printf '{"type":"user","timestamp":"2026-08-17T11:0%s:30.000Z","message":{"content":[{"type":"tool_result"}]}}\n' "$i"
  done
} > "$CL"

# Key path is passed as ARGV, never interpolated into the python source: `'$2'` inside a
# double-quoted -c produced `'d'+'['tokens']...'`, a syntax error that made every lookup return
# an empty string — i.e. a helper that reports FAIL for a script that is working.
j(){ python3 "$PS" "$1" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d.get(k) if isinstance(d,dict) else None
print("" if d is None else d)' "${@:2}" 2>/dev/null; }

# 1. tokens are emitted at all, on both formats
[ "$(j "$CX" tokens model_calls)" = "6" ] && ok "codex: 6 usage records counted" || no "codex: model_calls (got $(j "$CX" tokens model_calls))"
[ "$(j "$CL" tokens model_calls)" = "6" ] && ok "claude: 6 usage records counted" || no "claude: model_calls (got $(j "$CL" tokens model_calls))"

# 2. THE CACHE-SEMANTICS TRAP. Both fixtures describe the same spend: 1000 billed in (900 of it
#    cache) + 100 out, six times. gross must be 6600 and fresh 1200 in BOTH — that equality is the
#    whole point. A reader that aliased the key names would return 1200 gross for claude.
for f in "$CX" "$CL"; do
  n="$(basename "$f" .jsonl)"
  [ "$(j "$f" tokens gross)" = "6600" ] && ok "$n: gross 6600 (cache counted as billed input)" || no "$n: gross (got $(j "$f" tokens gross), expected 6600)"
  [ "$(j "$f" tokens fresh)" = "1200" ] && ok "$n: fresh 1200 (cache reads excluded)" || no "$n: fresh (got $(j "$f" tokens fresh), expected 1200)"
done

# 3. determinism — same file in, same numbers out. This is the property the five hand-written
#    profiles lacked; assert it rather than trust it.
a="$(python3 "$PS" "$CX" 2>/dev/null | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)['tokens'],sort_keys=True))")"
b="$(python3 "$PS" "$CX" 2>/dev/null | python3 -c "import json,sys;print(json.dumps(json.load(sys.stdin)['tokens'],sort_keys=True))")"
[ -n "$a" ] && [ "$a" = "$b" ] && ok "repeated runs produce identical token blocks" || no "token block is not reproducible"

# 4. the polling classifier is PUBLISHED with the number, so a quoted figure can be checked
case "$(python3 "$PS" "$CX" 2>/dev/null)" in *'"classifier"'*) ok "polling classifier is emitted alongside the count";; *) no "classifier not emitted";; esac

# 5. TRUNCATION + custom_tool_call.input: the reviewer is invoked 130 chars deep in the command,
#    under the payload key older readers ignored. Both defects filed it as other-tools.
[ "$(j "$CX" counts adversarial_calls)" = "6" ] && ok "adversarial seen past the label cut, in custom_tool_call.input" || no "adversarial_calls (got $(j "$CX" counts adversarial_calls), expected 6)"

# 6. a transcript with NO usage records must say UNKNOWN, not estimate
NO="$TMP/none.jsonl"
{ printf '{"type":"assistant","timestamp":"2026-08-17T12:0%s:00.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}\n' 1 2 3 4; } > "$NO"
out="$(python3 "$PS" "$NO" 2>/dev/null)"
case "$out" in *'"model_calls": 0'*) ok "no usage records -> model_calls 0";; *) no "missing-usage case not reported as 0";; esac
case "$out" in *"never hand-derive"*) ok "no usage records -> refuses to estimate";; *) no "missing-usage case lacks the do-not-estimate note";; esac

# 7. the SKILL must not re-declare tokens out of scope — that line is what made the script's
#    silence look intentional and sent five runs off to compute their own.
SK="$ROOT/skills/profile-session/SKILL.md"
case "$(cat "$SK")" in *'Out of scope:** token cost'*) no "SKILL.md still declares token cost out of scope";; *) ok "SKILL.md no longer declares token cost out of scope";; esac
case "$(cat "$SK")" in *'tokens.model_calls'*) ok "SKILL.md points at the profiler's tokens block";; *) no "SKILL.md does not reference the tokens block";; esac

echo "  --- profile-session tokens: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
