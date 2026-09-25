#!/usr/bin/env bash
#
# test-adversarial-claude-lane-bench.sh — the claude lane must not crash under the health bench.
#
# Commit 7907fe70 added `claude_reviewer_model` and called it from `provider_model`
# (adversarial-review.sh:~1774), but the function itself is defined ~370 lines later
# (:~2144). Bash resolves function calls at CALL TIME, not at parse time, so the crash
# is silent until something actually reaches that call: `provider_model` is invoked
# from the provider-health BENCH loop (:~1840), which only runs when
# ZUVO_PROVIDER_BENCH is enabled AND the health ledger is non-empty (:~1831). On this
# machine the ledger is never empty, so every adversarial run with `claude` in the
# provider list — including every per-task review gate of zuvo:execute — exited 127
# with "claude_reviewer_model: command not found". Measured 2026-09-25 (three
# `--mode plan` passes exited 127 before this fix).
#
# The fix is a pure move (definition above its first use, no logic change), so this
# test pins BEHAVIOUR (exit code + absence of the crash message), not line numbers.
#
# Two follow-up hardenings after cross-model review (2026-09-25):
#  1. Exit-0 + "no crash text" alone is vacuous — it also passes a run that silently
#     never reached the crash site at all. The "bench threshold crossed" case below
#     seeds a ledger row that crosses the bench threshold (count>=3, fresh timestamp),
#     so `provider_model`'s RETURN VALUE — not just the call — is consumed: the bench
#     awk matches it against the ledger's (lane, model) key. With one provider in play,
#     a successful match makes the driver print a distinct line ("WARN: every provider
#     is benched..."); that line can only be reached by resolving the model AND
#     completing the awk match, so it is present on the fixed driver and unreachable on
#     the pre-fix one (which dies at rc=127 at the call site first). Verified absent on
#     an EMPTY ledger, where the whole bench block is skipped (see the last case below)
#     — so the assertion is not "this string exists somewhere", it is tied to the code
#     path actually running.
#  2. The old check (`grep -q 'claude_reviewer_model'`) matched ANY mention of the
#     name, not just the crash — a future success-path log line naming the function
#     would have failed this test for no reason. Narrowed to the exact failure text
#     `claude_reviewer_model: command not found`.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# ZUVO_TEST_AR points this test at a DIFFERENT driver copy (e.g. a pre-fix revision
# extracted with `git show <rev>:scripts/adversarial-review.sh`) to prove it is a real
# regression test rather than one that happens to pass. Not used in normal runs —
# defaults to the repo's current driver.
AR="${ZUVO_TEST_AR:-$ROOT/scripts/adversarial-review.sh}"
fails=0
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails+1)); }

[ -x "$AR" ] || { echo "  ✗ $AR missing or not executable"; exit 1; }

# --- hermetic sandbox -------------------------------------------------------
T="$(mktemp -d)" || { echo "  ✗ mktemp -d failed" >&2; exit 1; }
[ -n "$T" ] || { echo "  ✗ mktemp -d returned an empty path" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

SPY_BIN="$T/bin"; mkdir -p "$SPY_BIN"
# Resolve the real coreutils BEFORE narrowing PATH — the driver hard-exits at
# ~:3368 without GNU timeout, and jq is used for JSON parsing; either missing
# would make this test record a golden from a run that never dispatched.
TIMEOUT_REAL="$(command -v timeout || command -v gtimeout)"
GTIMEOUT_REAL="$(command -v gtimeout || command -v timeout)"
JQ_REAL="$(command -v jq)"
[ -n "$TIMEOUT_REAL" ] || { echo "  ✗ no GNU timeout/gtimeout on this machine — cannot run the test"; exit 1; }
[ -n "$JQ_REAL" ] || { echo "  ✗ no jq on this machine — cannot run the test"; exit 1; }
ln -s "$TIMEOUT_REAL" "$SPY_BIN/timeout"
ln -s "$GTIMEOUT_REAL" "$SPY_BIN/gtimeout"
ln -s "$JQ_REAL" "$SPY_BIN/jq"

# A claude SPY: never a real model call. Reads stdin (the prompt), answers a
# short, syntactically valid review so a non-crash run has something to parse.
cat > "$SPY_BIN/claude" <<'SPY'
#!/usr/bin/env bash
cat > /dev/null
printf 'SEVERITY: WARNING\nFILE: x.ts:1\nISSUE: spy answer\n'
SPY
chmod +x "$SPY_BIN/claude"

HOMEDIR="$T/home"; mkdir -p "$HOMEDIR"

DIFF="diff --git a/x.ts b/x.ts
@@ -1 +1 @@
-const a=1
+const a=2
"

# run_dry <health-file-contents-or-empty> -> prints "<rc>|<stderr-path>"
run_dry() {
  local health_contents="$1" health_file="$T/health-$$-$RANDOM.tsv" rc=0
  if [ -n "$health_contents" ]; then
    printf '%s\n' "$health_contents" > "$health_file"
  else
    : > "$health_file"
  fi
  local errfile="$T/err-$$-$RANDOM.txt"
  printf '%s' "$DIFF" | env -i \
    HOME="$HOMEDIR" \
    PATH="$SPY_BIN:/usr/bin:/bin" \
    CLAUDECODE=1 \
    ZUVO_PROVIDER_BENCH=1 \
    ZUVO_PROVIDER_HEALTH_FILE="$health_file" \
    ZUVO_CLAUDE_REVIEWER_MODEL=claude-sonnet-5 \
    bash "$AR" --dry-run --mode code --provider claude >"$T/out-$$-$RANDOM.txt" 2>"$errfile" || rc=$?
  echo "$rc|$errfile"
}

echo "=== non-empty health ledger + bench enabled: the driver crash reproduced here ==="
res="$(run_dry "$(printf 'claude\tclaude-sonnet-5\t1\t1000000000\tok')")"
rc="${res%%|*}"; errfile="${res#*|}"
[ "$rc" = "0" ] && ok "exits 0 with a non-empty ledger (was 127 at HEAD)" \
                 || bad "exited $rc with a non-empty ledger (want 0)"
grep -q 'command not found' "$errfile" \
  && bad "stderr still shows 'command not found' — claude_reviewer_model is still called before it is defined" \
  || ok "stderr has no 'command not found'"
# Narrowed (see header note 2): exact failure text, not any mention of the name.
grep -qF 'claude_reviewer_model: command not found' "$errfile" \
  && bad "stderr shows the exact crash 'claude_reviewer_model: command not found' — the crash is still reachable" \
  || ok "stderr does not show the exact crash text"

echo "=== bench threshold crossed: proves provider_model's RETURN VALUE was consumed, not just called ==="
# A count=1 row (above) proves the CALL site doesn't crash, but never proves the RESULT
# was right: below the bench threshold (default 3) the awk skips the row entirely (no
# "bad" key built from it), so a provider_model that silently returned the wrong string
# — or nothing — would be invisible to that case. This row crosses the threshold with a
# fresh timestamp so the bench awk must match (lane, model) = (claude, claude-sonnet-5)
# against what provider_model actually returned; see the header note for why that makes
# "WARN: every provider is benched" the chosen observable.
_bench_now="$(date +%s)"
res="$(run_dry "$(printf 'claude\tclaude-sonnet-5\t3\t%s\tfail' "$_bench_now")")"
rc="${res%%|*}"; errfile="${res#*|}"
[ "$rc" = "0" ] && ok "exits 0 with a threshold-crossing ledger row (was 127 at HEAD)" \
                 || bad "exited $rc with a threshold-crossing ledger row (want 0)"
grep -qF 'WARN: every provider is benched' "$errfile" \
  && ok "bench matched (claude, claude-sonnet-5) against the ledger — provider_model's return value was consumed" \
  || bad "bench WARN line missing — provider_model did not resolve/match the expected model"

echo "=== empty health ledger + bench enabled: must also exit 0 (was already 0 at HEAD), and the bench block must not run at all ==="
res="$(run_dry "")"
rc="${res%%|*}"; errfile="${res#*|}"
[ "$rc" = "0" ] && ok "exits 0 with an empty ledger (rc=$rc)" \
                 || bad "exited $rc with an empty ledger (want 0) — regression"
grep -q 'command not found' "$errfile" \
  && bad "empty-ledger run also shows 'command not found'" \
  || ok "empty-ledger run has no 'command not found'"
grep -qF 'WARN: every provider is benched' "$errfile" \
  && bad "empty-ledger run shows the bench WARN — the bench block ran with no ledger rows to read" \
  || ok "empty-ledger run shows no bench WARN (bench block correctly skipped on an empty file)"

echo "=== RESULT ==="
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
