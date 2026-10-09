#!/usr/bin/env bash
# measure-tokens.sh <label> <cli> <model> [effort] — token usage of one SUBSCRIPTION reviewer config.
#
# Subscription lanes (claude, codex, cursor, agy, kimi, muse) are not billed per call, so the benchmark
# had no cost for them and the page could only say "abonament" — which cannot tell Kimi K3 from K2.8.
# This measures what one review consumes, so build.py can price it at the vendor's API list price
# (an estimate of what the subscription is spending, not an invoice).
#
#   measure-tokens.sh claude-sonnet-5-5 claude claude-sonnet-5-5
#   measure-tokens.sh claude-opus-5-5-high claude claude-opus-5-5 high
#   measure-tokens.sh sol-light codex gpt-6-sol none
#   measure-tokens.sh k3-256k-high kimi kimi-code/k3-256k high
#   measure-tokens.sh cursor-agent cursor composer-2.5-fast
#   measure-tokens.sh gemini-3.8-flash-medium agy "Gemini 3.8 Flash (Medium)"
#   measure-tokens.sh muse-spark-1.3 muse muse-spark-1.3
#
# Each diff gets the EXACT prompt the driver sends (captured once through a spy client, cached in
# $BENCH_HOME/prompts/<id>.txt). Output: $BENCH_HOME/subs/usage-<label>.tsv
#   id  rc  secs  in  cache_read  cache_write  out  reasoning  reported_usd
# `in` excludes cached input; `out` includes reasoning (every vendor here bills reasoning as output);
# `reasoning` is informational. reported_usd is the CLI's own API-price figure where it gives one
# (claude). Rows already present are skipped, so an interrupted run resumes.
#
# Env: BENCH_HOME (default ~/.zuvo/bench); MEASURE_DIFFS (space-separated ids; default five diffs
# spread across the corpus' size range); MEASURE_TIMEOUT (default 900 s, the bench's lane ceiling).
set -uo pipefail
LAB="${1:-}"; CLI="${2:-}"; MODEL="${3:-}"; EFF="${4:-}"
[ -n "$LAB" ] && [ -n "$CLI" ] && [ -n "$MODEL" ] || { echo "usage: measure-tokens.sh <label> <cli> <model> [effort]" >&2; exit 2; }
case "$CLI" in claude|codex|cursor|agy|kimi|muse) ;; *) echo "measure-tokens.sh: unknown cli: $CLI" >&2; exit 2 ;; esac
D="${BENCH_HOME:-$HOME/.zuvo/bench}"
DRIVER="${ADV:-$HOME/.zuvo/adversarial-review}"
TIMEOUT="${MEASURE_TIMEOUT:-900}"
DIFFS="${MEASURE_DIFFS:-1788097281-9996 1788094994-91059 1788095259-67132 1788097410-31790 1788097157-76385}"
OUT="$D/subs/usage-$LAB.tsv"
mkdir -p "$D/prompts" "$D/subs/usage-raw"
[ -s "$OUT" ] || printf 'id\trc\tsecs\tin\tcache_read\tcache_write\tout\treasoning\treported_usd\n' > "$OUT"
TOOLS=$(mktemp -d); trap 'rm -rf "$TOOLS"' EXIT

# The exact prompt the driver builds for a diff: a spy client records its stdin and answers "clean".
capture_prompt() {
  local id=$1 p="$D/prompts/$1.txt"
  [ -s "$p" ] && return 0
  cat > "$TOOLS/claude" <<'SPY'
#!/bin/sh
case "$1" in --version) echo "2.9.0 (Claude Code)"; exit 0;; esac
cat > "$SPY_OUT"; printf 'NO ISSUES FOUND.\n'
SPY
  chmod +x "$TOOLS/claude"
  # A per-process temp name: several measure runs may capture the same diff at once.
  SPY_OUT="$p.$$.tmp" ZUVO_CLAUDE_BIN="$TOOLS/claude" CLAUDE_MODEL=claude-opus-5-5 \
    ZUVO_ADVERSARIAL_LOG_FILE="$TOOLS/adv.log" "$DRIVER" --provider claude --mode code \
    < "$D/judge2/$id/CODE.diff" > /dev/null 2>&1
  if [ -s "$p.$$.tmp" ]; then mv "$p.$$.tmp" "$p"; else rm -f "$p.$$.tmp"; fi
  [ -s "$p" ]
}

agent_file() {
  cat > "$1" <<'A'
---
name: zuvo-reviewer
description: "Adversarial code reviewer. Reviews only the code in the prompt; has no tools."
tools: []
---

You are a code reviewer. Everything you need is in the user's message. You have no tools.
A
}

# run_cli <prompt> <raw> <workdir> — the vendor CLI with machine-readable output, no tools where possible.
run_cli() {
  local p=$1 raw=$2 wd=$3
  case "$CLI" in
    claude) timeout "$TIMEOUT" claude -p --model "$MODEL" ${EFF:+--effort "$EFF"} --output-format json --tools "" \
              --mcp-config '{"mcpServers":{}}' --strict-mcp-config --no-session-persistence < "$p" > "$raw" ;;
    codex)  (cd "$wd" && timeout "$TIMEOUT" codex exec --json --skip-git-repo-check -s read-only -m "$MODEL" \
              ${EFF:+-c model_reasoning_effort="$EFF"} - < "$p" > "$raw") ;;
    cursor) timeout "$TIMEOUT" cursor-agent -p --model "$MODEL" --mode ask --trust --workspace "$wd" \
              --output-format json < "$p" > "$raw" ;;
    agy)    (cd "$wd" && timeout "$TIMEOUT" agy -p "$(cat "$p")" --model "$MODEL" --output-format stream-json \
              < /dev/null > "$raw") ;;
    kimi)   agent_file "$wd/agent.md"
            (cd "$wd" && KIMI_MODEL_THINKING_EFFORT="${EFF:-high}" timeout "$TIMEOUT" kimi -p "$(cat "$p")" \
              --output-format stream-json -m "$MODEL" --agent-file "$wd/agent.md" > "$raw") ;;
    muse)   timeout "$TIMEOUT" muse exec --prompt-file "$p" --workspace "$wd" --model "$MODEL" --json > "$raw" ;;
  esac
}

# parse_usage <raw> <workdir> — prints: in cache_read cache_write out reasoning reported_usd (tab-separated).
parse_usage() {
  python3 - "$CLI" "$1" "$2" <<'PY'
import glob, json, os, sys
cli, raw, wd = sys.argv[1], sys.argv[2], sys.argv[3]
def lines(path):
    for l in open(path, errors="replace"):
        l = l.strip()
        if l.startswith("{"):
            try: yield json.loads(l)
            except ValueError: pass
row = None
if cli == "claude":
    d = json.load(open(raw)); u = d.get("usage") or {}
    th = (u.get("output_tokens_details") or {}).get("thinking_tokens", 0)
    row = (u.get("input_tokens", 0), u.get("cache_read_input_tokens", 0), u.get("cache_creation_input_tokens", 0),
           u.get("output_tokens", 0), th, d.get("total_cost_usd", ""))
elif cli == "codex":
    t = [e["usage"] for e in lines(raw) if e.get("type") == "turn.completed" and isinstance(e.get("usage"), dict)]
    if t:
        u = {k: sum(x.get(k, 0) for x in t) for k in t[0]}
        row = (u.get("input_tokens", 0) - u.get("cached_input_tokens", 0), u.get("cached_input_tokens", 0),
               u.get("cache_write_input_tokens", 0), u.get("output_tokens", 0), u.get("reasoning_output_tokens", 0), "")
elif cli == "cursor":
    u = json.load(open(raw)).get("usage") or {}
    row = (u.get("inputTokens", 0), u.get("cacheReadTokens", 0), u.get("cacheWriteTokens", 0), u.get("outputTokens", 0), "", "")
elif cli == "agy":
    r = [e["result"] for e in lines(raw) if e.get("event") == "result" and isinstance(e.get("result"), dict)]
    u = (r[-1].get("usage") if r else None) or {}
    if u:
        row = (u.get("input_tokens", 0), u.get("cache_read_tokens", 0), 0, u.get("output_tokens", 0), u.get("thinking_tokens", 0), "")
elif cli == "kimi":
    # kimi's stream carries no usage; its session log does, under a dir named after the cwd's basename.
    base = os.path.basename(wd.rstrip("/")).lower()   # kimi lowercases the cwd basename in the dir name
    ins = cr = cw = out = 0; seen = False
    for p in glob.glob(os.path.expanduser(f"~/.kimi-code/sessions/wd_{base}_*/session_*/agents/main/wire.jsonl")):
        for e in lines(p):
            if e.get("type") == "usage.record" and e.get("usageScope") == "turn":
                u = e.get("usage") or {}; seen = True
                ins += u.get("inputOther", 0); cr += u.get("inputCacheRead", 0)
                cw += u.get("inputCacheCreation", 0); out += u.get("output", 0)
    if seen: row = (ins, cr, cw, out, "", "")
elif cli == "muse":
    ins = cr = out = 0; seen = False
    for e in lines(raw):
        u = (e.get("payload") or {}).get("usage") if isinstance(e.get("payload"), dict) else None
        if isinstance(u, dict):
            seen = True
            ins += u.get("input_tokens", u.get("inputTokens", 0)); cr += u.get("cache_read_tokens", u.get("cachedInputTokens", 0))
            out += u.get("output_tokens", u.get("outputTokens", 0))
    if seen: row = (ins, cr, 0, out, "", "")
print("\t".join(str(x) for x in row) if row else "")
PY
}

n=0
for id in $DIFFS; do
  if awk -F'\t' -v id="$id" 'NR>1 && $1==id && $2==0 && $7>0 {f=1} END{exit !f}' "$OUT"; then continue; fi
  [ -f "$D/judge2/$id/CODE.diff" ] || { echo "  $id: no diff in the corpus, skipped" >&2; continue; }
  capture_prompt "$id" || { echo "  $id: could not capture the driver prompt" >&2; continue; }
  wd=$(mktemp -d "${TMPDIR:-/tmp}/mtok-$LAB-XXXX" | tr -d '\n')
  raw="$D/subs/usage-raw/$LAB-$id.raw"
  s=$(date +%s); rc=0
  run_cli "$D/prompts/$id.txt" "$raw" "$wd" 2> "$raw.err" || rc=$?
  secs=$(( $(date +%s) - s ))
  u=$(parse_usage "$raw" "$wd" 2>>"$raw.err")
  [ -n "$u" ] || { [ "$rc" = 0 ] && rc=97; u=$'0\t0\t0\t0\t\t'; }
  awk -F'\t' -v id="$id" 'NR==1 || $1!=id' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
  printf '%s\t%s\t%s\t%s\n' "$id" "$rc" "$secs" "$u" >> "$OUT"
  echo "  $LAB $id rc=$rc ${secs}s usage: $(printf '%s' "$u" | tr '\t' ' ')"
  n=$((n+1))
done
echo "MEASURED $LAB: $n new, $(($(wc -l < "$OUT") - 1)) total rows in $OUT"
