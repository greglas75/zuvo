#!/usr/bin/env bash
# Tests scripts/bench/measure-tokens.sh with a stand-in driver and a stand-in `claude` CLI.
# Level: medium — real processes and files in a temp BENCH_HOME.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MT="$ROOT/scripts/bench/measure-tokens.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
# A precondition, not a wrapper: measure-tokens.sh itself refuses to run without one.
command -v timeout >/dev/null || command -v gtimeout >/dev/null \
  || { echo "  ✗ no timeout/gtimeout on PATH — measure-tokens.sh requires one"; exit 1; }

export BENCH_HOME="$TMP/bench" MEASURE_DIFFS="d1"
mkdir -p "$BENCH_HOME/judge2/d1" "$TMP/bin"
printf '+x = 1\n' > "$BENCH_HOME/judge2/d1/CODE.diff"
# The driver splits this diff into two chunks: two client calls with different prompts.
cat > "$TMP/driver" <<'EOF'
#!/bin/sh
echo "chunk one" | "$ZUVO_CLAUDE_BIN" -p >/dev/null
echo "chunk two" | "$ZUVO_CLAUDE_BIN" -p >/dev/null
EOF
# The measured CLI: usage depends on the prompt, so a lost chunk changes the sum.
cat > "$TMP/bin/claude" <<EOF
#!/bin/sh
echo call >> "$TMP/calls"
case "\$(cat)" in
  *one*) echo '{"usage":{"input_tokens":100,"cache_read_input_tokens":10,"cache_creation_input_tokens":0,"output_tokens":7},"total_cost_usd":0.5}' ;;
  *two*) echo '{"usage":{"input_tokens":200,"cache_read_input_tokens":20,"cache_creation_input_tokens":0,"output_tokens":9},"total_cost_usd":0.25}' ;;
esac
EOF
chmod +x "$TMP/driver" "$TMP/bin/claude"
export ADV="$TMP/driver" PATH="$TMP/bin:$PATH"
OUT="$BENCH_HOME/subs/usage-lab.tsv"

echo "=== a chunked diff is measured as the sum of its calls ==="
bash "$MT" lab claude m >/dev/null 2>&1; rc=$?
row="$(awk -F'\t' '$1=="d1"' "$OUT" | cut -f1,2,4-9)"
[ "$rc" -eq 0 ] && [ "$row" = "d1	0	300	30	0	16	0	0.75" ] \
  && ok "both chunk prompts captured and summed (catches measuring only the last chunk)" || bad "rc=$rc row=[$row]"

echo "=== resume ==="
calls_before="$(wc -l < "$TMP/calls")"
bash "$MT" lab claude m >/dev/null 2>&1
[ "$(wc -l < "$TMP/calls")" = "$calls_before" ] && ok "a measured diff is not re-measured on a rerun (no CLI call)" \
  || bad "rerun called the CLI again: $(wc -l < "$TMP/calls") calls, was $calls_before"

echo "=== a run where every call fails exits non-zero ==="
printf '#!/bin/sh\ncat >/dev/null; exit 3\n' > "$TMP/bin/claude"
bash "$MT" lab2 claude m >/dev/null 2>&1; rc=$?
row="$(awk -F'\t' '$1=="d1"' "$BENCH_HOME/subs/usage-lab2.tsv" | cut -f2)"
[ "$rc" -ne 0 ] && [ "$row" = 3 ] && ok "all-failed run: exit $rc, the row keeps the CLI's rc 3 (catches 'MEASURED' + exit 0 on nothing)" \
  || bad "rc=$rc row rc=[$row]"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
