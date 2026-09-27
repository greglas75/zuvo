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
#
# Test-quality round (2026-09-26) — what the first three scenarios never reached:
#  3. claude_reviewer_model's OPUS branch. Every scenario above runs on a Claude host with
#     CLAUDE_MODEL unset, so only the Sonnet `else` ran. The live cases below dispatch the lane
#     for real (no --dry-run) against an argv-RECORDING claude spy and assert the `--model` /
#     `--effort` the client actually received: another vendor's host (a Codex host signal —
#     HOST_PROVIDER is computed by detect_host_platform, never read from the environment) and a
#     Sonnet / Haiku CLAUDE_MODEL each get Opus (or $ZUVO_MODEL_CLAUDE_REVIEWER_OPUS); an Opus
#     author and an unknown host get Sonnet — the control that makes the argv check discriminate.
#     The bench path is pinned too: on a Codex host the ledger key is (claude, <opus>).
#  4. Malformed / legacy ledger rows (the bench awk): a row with fewer than 4 fields and a
#     non-numeric count are skipped, and a 4-field row (no outcome column) gets the SOFT cooldown
#     — the documented fallback — while the same row with outcome `timeout` keeps the full one.
#  5. Ledger timestamps sit far from every cooldown boundary (now-60s inside, hours past the soft
#     one, a day past everything), so a slow run cannot drift across one.
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
# Each GNU timeout name falls back to the other, so a host with only one of them still gets both.
# shellcheck source=tests/lib/hermetic-tools.sh
. "$ROOT/tests/lib/hermetic-tools.sh"
hermetic_link_tools "$SPY_BIN" timeout:gtimeout gtimeout:timeout jq
[ -e "$SPY_BIN/timeout" ] || { echo "  ✗ no GNU timeout/gtimeout on this machine — cannot run the test"; exit 1; }
[ -e "$SPY_BIN/jq" ] || { echo "  ✗ no jq on this machine — cannot run the test"; exit 1; }

# A claude SPY: never a real model call. Reads stdin (the prompt), answers a
# short, syntactically valid review so a non-crash run has something to parse.
# It RECORDS what it received — every argv element on its own line in $T/claude.argv
# (rewritten per call) and one line per invocation in $T/claude.calls — at paths baked in
# here, so the record does not depend on which environment the runner hands the client.
cat > "$SPY_BIN/claude" <<SPY
#!/bin/sh
printf '%s\n' "\$@" > "$T/claude.argv"
echo call >> "$T/claude.calls"
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

# run_dry_env <health-file-contents-or-empty> [VAR=value ...] -> prints "<rc>|<stderr-path>"
# The host/model environment is ENTIRELY the caller's: nothing but HOME, TMPDIR, PATH and the bench
# switches is set here, so a case that wants a non-Claude host simply omits CLAUDECODE.
# From a scratch cwd with TMPDIR in the sandbox, like run_live: the driver keeps its run-scoped
# auth-failure cache under ${TMPDIR:-/tmp}/zuvo-adv-<uid>, keyed on the cwd's git toplevel, and a
# `--provider claude` run EMPTIES a cache that lists claude. Started from the repo with no TMPDIR, that
# was this checkout's real cache — the next real review re-probed a lane it had marked dead.
run_dry_env() {
  local health_contents="$1" health_file="$T/health-$$-$RANDOM.tsv" rc=0
  shift
  if [ -n "$health_contents" ]; then
    printf '%s\n' "$health_contents" > "$health_file"
  else
    : > "$health_file"
  fi
  local errfile="$T/err-$$-$RANDOM.txt"
  mkdir -p "$T/tmp" "$T/work"
  ( cd "$T/work" && printf '%s' "$DIFF" | env -i \
    HOME="$HOMEDIR" \
    TMPDIR="$T/tmp" \
    PATH="$SPY_BIN:/usr/bin:/bin" \
    ZUVO_PROVIDER_BENCH=1 \
    ZUVO_PROVIDER_HEALTH_FILE="$health_file" \
    "$@" \
    bash "$AR" --dry-run --mode code --provider claude ) >"$T/out-$$-$RANDOM.txt" 2>"$errfile" || rc=$?
  echo "$rc|$errfile"
}
# run_dry <health-file-contents-or-empty> — the original scenarios' host: Claude Code, with the
# Sonnet reviewer pinned (so the ledger key is (claude, claude-sonnet-5)).
run_dry() {
  run_dry_env "$1" CLAUDECODE=1 ZUVO_CLAUDE_REVIEWER_MODEL=claude-sonnet-5
}
# Ledger timestamps, each far from every cooldown boundary (defaults: soft 2700 s, full 21600 s):
# inside both (60 s old), past the soft one but inside the full one (3 h), past both (1 day).
_bench_now="$(date +%s)"
TS_FRESH=$((_bench_now - 60))
TS_3H=$((_bench_now - 10800))
TS_1D=$((_bench_now - 86400))
# benched <errfile> — the one observable of a (lane, model) match with a single provider in play.
benched() { grep -qF 'WARN: every provider is benched' "$1"; }

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
# "WARN: every provider is benched" the chosen observable. Stamped 60 s old (not `now`), well
# inside the 2700 s soft cooldown this `fail` row gets.
res="$(run_dry "$(printf 'claude\tclaude-sonnet-5\t3\t%s\tfail' "$TS_FRESH")")"
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

# ── claude_reviewer_model's OPUS branch, observed where it matters: the client's argv ──────────
# run_live <tag> [VAR=value ...] — the claude lane DISPATCHED (no --dry-run) from a scratch cwd,
# `env -i` with a fresh HOME / TMPDIR / ledger and only the caller's host variables. Prints the rc;
# the driver's stdout/stderr land in $T/live-<tag>.out / .err, the spy's record in $T/claude.*.
run_live() {
  local tag="$1" rc=0 h="$T/home-live-$1"
  shift
  rm -f "$T/claude.argv" "$T/claude.calls"
  rm -rf "$h"; mkdir -p "$h" "$T/tmp" "$T/work"
  ( cd "$T/work" && printf '%s' "$DIFF" | env -i HOME="$h" TMPDIR="$T/tmp" \
      PATH="$SPY_BIN:/usr/bin:/bin" ZUVO_NO_CAFFEINATE=1 ZUVO_PROVIDER_HEALTH_FILE="$h/health.tsv" "$@" \
      bash "$AR" --mode code --provider claude ) > "$T/live-$tag.out" 2> "$T/live-$tag.err" || rc=$?
  echo "$rc"
}
# arg_after <flag> — the argv element the spy received right after <flag> (empty when absent).
arg_after() { awk -v k="$1" 'p { print; exit } $0 == k { p = 1 }' "$T/claude.argv" 2>/dev/null; }
has_arg()   { awk -v k="$1" '$0 == k { f = 1 } END { exit !f }' "$T/claude.argv" 2>/dev/null; }
spy_calls() { if [ -f "$T/claude.calls" ]; then wc -l < "$T/claude.calls" | tr -d ' '; else echo 0; fi; }
LIVE_N=0
# live_case <label> <host premise: a stderr substring, or "none"> <want --model> <want --effort, or "none">
#           [VAR=value ...]
live_case() {
  local label="$1" premise="$2" want_model="$3" want_effort="$4" rc tag
  shift 4
  LIVE_N=$((LIVE_N+1)); tag="L$LIVE_N"
  rc="$(run_live "$tag" "$@")"
  [ "$rc" = "0" ] && ok "$label: driver exits 0" || bad "$label: driver exited $rc (want 0) — $(tail -2 "$T/live-$tag.err" | tr '\n' ' ')"
  if [ "$premise" = "none" ]; then
    grep -qF 'Host detected:' "$T/live-$tag.err" \
      && bad "$label: premise — a host was detected ($(grep -F 'Host detected:' "$T/live-$tag.err"))" \
      || ok "$label: premise — no host detected"
  else
    grep -qF "$premise" "$T/live-$tag.err" \
      && ok "$label: premise — stderr shows '$premise'" \
      || bad "$label: premise — '$premise' missing from stderr: the host signal was not taken"
  fi
  [ "$(spy_calls)" = "1" ] && ok "$label: the claude spy ran exactly once" \
                           || bad "$label: the claude spy ran $(spy_calls) times (want 1)"
  [ "$(arg_after --model)" = "$want_model" ] \
    && ok "$label: the client received --model $want_model" \
    || bad "$label: the client received --model [$(arg_after --model)] (want $want_model)"
  if [ "$want_effort" = "none" ]; then
    has_arg --effort && bad "$label: the client received --effort $(arg_after --effort) (want none — the Sonnet reviewer takes no effort flag)" \
                     || ok "$label: the client received no --effort"
  else
    [ "$(arg_after --effort)" = "$want_effort" ] \
      && ok "$label: the client received --effort $want_effort" \
      || bad "$label: the client received --effort [$(arg_after --effort)] (want $want_effort)"
  fi
}

echo "=== opus branch: another vendor's host (Codex) — Opus reviews, whatever the Sonnet override says ==="
# CODEX_SHELL=1 is a Codex host signal (zms_is_codex_host); CODEX_MODEL names the host model, so the
# driver resolves HOST_PROVIDER=codex-5.4 without a NOTE. ZUVO_CLAUDE_REVIEWER_MODEL is a DECOY: it
# only feeds the Sonnet branch, so seeing it in argv would mean the opus branch was not taken.
live_case "Codex host" "Host detected: codex-5.4" claude-opus-5-5 high \
  CODEX_SHELL=1 CODEX_MODEL=gpt-6-luna ZUVO_CLAUDE_REVIEWER_MODEL=claude-sonnet-decoy
live_case "Codex host + ZUVO_MODEL_CLAUDE_REVIEWER_OPUS" "Host detected: codex-5.4" claude-opus-override-x high \
  CODEX_SHELL=1 CODEX_MODEL=gpt-6-luna ZUVO_MODEL_CLAUDE_REVIEWER_OPUS=claude-opus-override-x

echo "=== opus branch: a Sonnet / Haiku author on a Claude host ==="
live_case "Claude host, Sonnet author" "Host detected: claude" claude-opus-5-5 high \
  CLAUDECODE=1 CLAUDE_MODEL=claude-sonnet-5-20250101
live_case "Claude host, Haiku author" "Host detected: claude" claude-opus-5-5 high \
  CLAUDECODE=1 CLAUDE_MODEL=claude-haiku-4-5-20251001

echo "=== sonnet branch (controls — the argv check must be able to say 'not Opus') ==="
live_case "Claude host, Opus author" "Host detected: claude" claude-sonnet-5 none \
  CLAUDECODE=1 CLAUDE_MODEL=claude-opus-5-5
live_case "no host signal, CLAUDE_MODEL unset" none claude-sonnet-5 none

echo "=== bench path on a Codex host: provider_model keys the ledger on the Opus reviewer ==="
res="$(run_dry_env "$(printf 'claude\tclaude-opus-5-5\t3\t%s\tfail' "$TS_FRESH")" CODEX_SHELL=1 CODEX_MODEL=gpt-6-luna)"
rc="${res%%|*}"; errfile="${res#*|}"
[ "$rc" = "0" ] && ok "Codex host, (claude, claude-opus-5-5) row: exits 0" || bad "Codex host, (claude, claude-opus-5-5) row: exited $rc (want 0)"
benched "$errfile" && ok "Codex host: a threshold-crossing (claude, claude-opus-5-5) row benches the lane — provider_model named Opus" \
                   || bad "Codex host: the (claude, claude-opus-5-5) row did not bench the lane — provider_model did not resolve Opus"
res="$(run_dry_env "$(printf 'claude\tclaude-sonnet-5\t3\t%s\tfail' "$TS_FRESH")" CODEX_SHELL=1 CODEX_MODEL=gpt-6-luna)"
rc="${res%%|*}"; errfile="${res#*|}"
[ "$rc" = "0" ] && ok "Codex host, (claude, claude-sonnet-5) row: exits 0" || bad "Codex host, (claude, claude-sonnet-5) row: exited $rc (want 0)"
benched "$errfile" && bad "Codex host: a (claude, claude-sonnet-5) row benched the lane — the Opus reviewer paid for Sonnet's failures" \
                   || ok "Codex host: a (claude, claude-sonnet-5) row does not bench the Opus reviewer"

# ── malformed and legacy ledger rows (the bench awk) ──────────────────────────────────────────────
# dry_bench <label> <want: benched|free> <ledger> [VAR=value ...] — Claude host, Sonnet pinned, so the
# key under test is (claude, claude-sonnet-5); extra VARs (cooldowns) go after the host ones.
dry_bench() {
  local label="$1" want="$2" ledger="$3" res rc errfile
  shift 3
  res="$(run_dry_env "$ledger" CLAUDECODE=1 ZUVO_CLAUDE_REVIEWER_MODEL=claude-sonnet-5 "$@")"
  rc="${res%%|*}"; errfile="${res#*|}"
  [ "$rc" = "0" ] && ok "$label: exits 0" || bad "$label: exited $rc (want 0)"
  if [ "$want" = "benched" ]; then
    benched "$errfile" && ok "$label: benched" || bad "$label: NOT benched (want benched)"
  else
    benched "$errfile" && bad "$label: benched (want not benched)" || ok "$label: not benched"
  fi
}
echo "=== malformed rows: fewer than 4 fields / non-numeric count are skipped, never benched ==="
# The short row has NO timestamp: an awk without the n<4 guard would read it as 0 and compute an age
# of ~56 years, which no default cooldown covers — so the guard would be invisible. Cooldowns of
# ~3000 years make "skipped by the guard" the ONLY reason such a row can leave the lane free; the
# well-formed row under the same cooldowns is the control that they do bench a real failure.
HUGE_CD="ZUVO_PROVIDER_BENCH_COOLDOWN=99999999999"; HUGE_CD_SOFT="ZUVO_PROVIDER_BENCH_COOLDOWN_SOFT=99999999999"
dry_bench "3-field row (count 9, no timestamp), huge cooldowns" free \
  "$(printf 'claude\tclaude-sonnet-5\t9')" "$HUGE_CD" "$HUGE_CD_SOFT"
dry_bench "control: 5-field row (count 9, 60 s old), huge cooldowns" benched \
  "$(printf 'claude\tclaude-sonnet-5\t9\t%s\tfail' "$TS_FRESH")" "$HUGE_CD" "$HUGE_CD_SOFT"
dry_bench "a 3-field row before a good row does not stop the ledger parse" benched \
  "$(printf 'claude\tclaude-sonnet-5\t9\nclaude\tclaude-sonnet-5\t3\t%s\tfail' "$TS_FRESH")"
dry_bench "non-numeric count ('abc', 60 s old) reads as 0 — below the threshold" free \
  "$(printf 'claude\tclaude-sonnet-5\tabc\t%s\tfail' "$TS_FRESH")"
echo "=== legacy 4-field rows (no outcome column) get the SOFT cooldown — the documented fallback ==="
dry_bench "4-field row, 60 s old (inside the 2700 s soft cooldown)" benched \
  "$(printf 'claude\tclaude-sonnet-5\t3\t%s' "$TS_FRESH")"
dry_bench "4-field row, 3 h old (soft cooldown over; the 6 h one must NOT apply)" free \
  "$(printf 'claude\tclaude-sonnet-5\t3\t%s' "$TS_3H")"
dry_bench "control: 5-field 'timeout' row, 3 h old (a timeout keeps the full 6 h cooldown)" benched \
  "$(printf 'claude\tclaude-sonnet-5\t3\t%s\ttimeout' "$TS_3H")"
dry_bench "5-field 'timeout' row, 1 day old (every cooldown over)" free \
  "$(printf 'claude\tclaude-sonnet-5\t3\t%s\ttimeout' "$TS_1D")"

echo "=== hermetic: the dry runs use the sandbox's auth-failure cache, keyed on the scratch cwd ==="
# Two caches that list claude — the only lane of a `--provider claude` run, which therefore EMPTIES the
# cache it reads — planted in the sandbox's cache dir: one under the key of the scratch cwd run_dry_env
# starts in, one under the key of this repository. The first must be read and emptied (the driver found
# its cache in the sandbox TMPDIR, under the scratch cwd's key); the second must stay as it was.
# ar_cache_key <path> — the driver's key for a run started in <path> outside any git checkout (its
# `pwd`, physical under env -i) or for a checkout (its toplevel): the first 16 hex of its sha1.
ar_cache_key() { printf '%s' "$1" | shasum 2>/dev/null | cut -c1-16 | tr -cd 'A-Za-z0-9'; }
_cdir="$T/tmp/zuvo-adv-$(id -u)"
_wkey="$(ar_cache_key "$(cd "$T/work" && pwd -P)")"
_rkey="$(ar_cache_key "$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$ROOT")")"
mkdir -p "$_cdir" && chmod 700 "$_cdir"
printf 'claude\n' > "$_cdir/failed-providers.$_wkey"
printf 'claude\n' > "$_cdir/failed-providers.$_rkey"
if [ "${#_wkey}" -eq 16 ] && [ "${#_rkey}" -eq 16 ] && [ "$_wkey" != "$_rkey" ]; then
  ok "premise: two distinct 16-hex cache keys (scratch cwd $_wkey, repository $_rkey)"
else
  bad "premise: cache keys unusable — scratch cwd [$_wkey], repository [$_rkey]"
fi
res="$(run_dry "")"
rc="${res%%|*}"; errfile="${res#*|}"
[ "$rc" = "0" ] && ok "hermetic: a dry run over a cache that lists claude exits 0" || bad "hermetic: exited $rc (want 0)"
if grep -qF "every provider is in the run's auth-failure cache" "$errfile" && [ ! -s "$_cdir/failed-providers.$_wkey" ]; then
  ok "hermetic: the cache the driver read (and emptied) is the sandbox's, under the scratch cwd's key"
else
  bad "hermetic: the sandbox cache under the scratch cwd's key was not the one read — [$(cat "$_cdir/failed-providers.$_wkey" 2>/dev/null)] left, stderr: $(awk '/auth-failure cache/' "$errfile" | head -1)"
fi
[ "$(cat "$_cdir/failed-providers.$_rkey" 2>/dev/null)" = "claude" ] \
  && ok "hermetic: a cache keyed on the repository is left as it was (the run did not start in the checkout)" \
  || bad "hermetic: the repository-keyed cache was touched — the dry run started in the checkout"

echo "=== RESULT ==="
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
