#!/usr/bin/env bash
#
# test-reviewer-preflight-isolation.sh — scripts/reviewer-preflight.sh's canaries must run isolated
# and must COMPUTE an answer (plan A, Task 7; coverage rows X2 / K1 / X3).
#
# What was wrong: the canary prompt was "Respond with exactly this token …: ZUVO_PREFLIGHT_OK" and the
# check was `grep ZUVO_PREFLIGHT_OK` on the reply — the token was IN the prompt, so a client that merely
# echoed its input passed, and preflight reported a reviewer that had answered nothing. The codex canary
# ran with the user's global CODEX_HOME (MCP servers included: the required `codesift` daemon that hung
# on 2026-09-25 took it down), the claude canary without --strict-mcp-config, and agy / cursor-agent /
# kimi from the caller's cwd — the repository under review. Availability was `command -v` only, so the
# ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN seams (and the Codex.app fallback) that the runners honour were not.
#
# What this pins:
#   * candidates are decided by zms_client_available: a spy OFF the PATH named by ZUVO_CODEX_BIN /
#     ZUVO_CLAUDE_BIN counts; ZUVO_CODEX_BIN=/nonexistent does not, even with a codex spy ON the PATH;
#   * the codex canary runs through zms_run_codex --access none: its own CODEX_HOME (not the fixture dir,
#     auth.json + a minimal config.toml, no mcp_servers, read-only, shell tools off), neutral cwd, the
#     registry's audit model and effort; the claude canary through zms_run_claude --access none
#     (--strict-mcp-config + an EMPTY MCP config, --tools "", --safe-mode); agy from a neutral temp cwd;
#   * every canary's prompt is the computed-answer prompt and holds no `42`: an ECHOING spy → canary-failed
#     for that client, exit 1; a spy answering 42 → exit 0 and provider=<that spy> (preflight_status is
#     degraded-routing here — every host signal is cleared, so the router answers unknown-writer-model —
#     which is why these cases assert the provider line and the exit code, not `ok`);
#   * a canary passes only when the client EXITS 0 and a stdout line reads 42: a 42 followed by exit 3, or
#     by a hang past the timeout, is canary-failed. The line check is exact up to the documented trim
#     (blanks, markdown emphasis/backticks, a trailing period): `142` and `The answer is 42` fail;
#   * a hung client is bounded by ZUVO_PREFLIGHT_TIMEOUT (agy through preflight's own timeout, codex
#     through the runner's --timeout); without GNU timeout on PATH NO canary runs, each named on stderr;
#   * agy / cursor-agent / kimi get stdin from /dev/null, never the caller's (a stdin that never reaches
#     EOF does not stall them); gemini gets the prompt there and nothing else;
#   * on a Codex host — ANY one of CODEX_SANDBOX, CODEX_SHELL=1, __CFBundleIdentifier=com.openai.codex,
#     CODEX_INTERNAL_ORIGINATOR_OVERRIDE="Codex Desktop" — codex is no candidate (zms_is_codex_host);
#   * the shared runner is looked up like the router/driver do it (<dir>/lib → <dir> → ~/.zuvo, a broken
#     candidate WARNed about by name); when NONE loads, preflight fails CLOSED: no-provider, provider=none,
#     exit 1, stderr names model-subprocess.sh, and no client is run;
#   * the stdout contract every consumer parses (shared/includes/test-reviewer-routing.md,
#     skills/write-tests/SKILL.md) stays eight KEY=VALUE lines in the same order; nothing is left in TMPDIR.
#
# Hermetic, and pinned to the harness so it NEVER reaches a real client: every preflight run is `env -i`
# — which clears every host signal (CLAUDECODE, CLAUDE_MODEL, CODEX_SANDBOX, CODEX_SHELL,
# CODEX_INTERNAL_ORIGINATOR_OVERRIDE, __CFBundleIdentifier, CODEX_MODEL, ZUVO_CODEX_MODEL,
# ANTIGRAVITY_SESSION_ID, VSCODE_GIT_ASKPASS_MAIN, CURSOR_AGENT_MODEL, …), a superset of `env -u` for each
# — plus ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy", a temp
# HOME / ZUVO_HOME / TMPDIR, a COPY of the fixture CODEX_HOME (dummy auth.json + a config.toml with an MCP
# server), ZUVO_CODEX_APP_BIN=/nonexistent, ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN ALWAYS set (a spy or
# /nonexistent: a set value is final, so the Codex app is unreachable), and PATH=<case bin>:/usr/bin:/bin
# where <case bin> holds only spies and symlinks to the real timeout / gtimeout / jq. A precondition
# refuses to run when any real client resolves on /usr/bin:/bin. Spy: tests/hooks/fixtures/model-subprocess/spy-cli,
# copied under the first sh that keeps an inherited OLDPWD (see "sandbox").
#
# Run under both shells (bash 3.2 is macOS's /bin/bash):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/test-reviewer-preflight-isolation.sh
#   TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/test-reviewer-preflight-isolation.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
# ZUVO_TEST_PF runs the cases against ANOTHER preflight copy (a deliberately broken one, to show a case is
# red there). It needs its siblings as the real one has them (lib/, the router, the driver, and a repo
# layout holding shared/includes/model-registry.sh). Not used in normal runs: default, the repo's own.
PF="${ZUVO_TEST_PF:-$ROOT/scripts/reviewer-preflight.sh}"
LIB="$ROOT/scripts/lib/model-subprocess.sh"
DRIVER="$ROOT/scripts/adversarial-review.sh"
SPY_SRC="$ROOT/tests/hooks/fixtures/model-subprocess/spy-cli"
FIX_SRC="$ROOT/tests/hooks/fixtures/model-subprocess/codex-home"
REGISTRY="$ROOT/shared/includes/model-registry.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
expect_eq()      { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
expect_has()     { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — [$2] not found in [$3]" ;; esac; }
expect_not_has() { case "$3" in *"$2"*) bad "$1 — [$2] found in [$3]" ;; *) ok "$1" ;; esac; }
# under <dir> <path> — true when <path> is <dir> or below it.
under() { case "$2" in "$1"|"$1"/*) return 0 ;; esac; return 1; }
poll() { local n=$(( $1 * 2 )) i=0; shift; until "$@"; do [ "$i" -lt "$n" ] || return 1; sleep 0.5; i=$((i+1)); done; }
# no_proc <pattern> — true ONLY when pgrep ran and matched nothing (fails closed without pgrep).
no_proc() { command -v pgrep >/dev/null 2>&1 || return 1; pgrep -f "$1" >/dev/null 2>&1; [ $? -eq 1 ]; }

echo "== reviewer-preflight canary isolation (bash $BASH_VERSION) =="

for _f in "$PF" "$LIB" "$DRIVER" "$SPY_SRC" "$FIX_SRC/auth.json" "$FIX_SRC/config.toml" "$REGISTRY"; do
  [ -f "$_f" ] || { echo "  FAIL missing $_f" >&2; exit 1; }
done
for _tool in pgrep shasum mkfifo; do
  command -v "$_tool" >/dev/null 2>&1 || { echo "  FAIL $_tool required — assertions would pass vacuously" >&2; exit 1; }
done
# Never a real client: nothing on the fixed part of the narrowed PATH may answer to a client's name.
for _cl in codex claude agy cursor-agent kimi gemini; do
  _p="$(PATH=/usr/bin:/bin type -P "$_cl" 2>/dev/null || true)"
  [ -z "$_p" ] || { echo "  FAIL a real $_cl resolves on /usr/bin:/bin ($_p) — refusing to run" >&2; exit 1; }
done

# ── sandbox ──────────────────────────────────────────────────────────────────
T="$(mktemp -d)" || { echo "  FAIL mktemp -d failed" >&2; exit 1; }
[ -n "$T" ] && [ -d "$T" ] || { echo "  FAIL mktemp -d returned no directory" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
T="$(cd "$T" && pwd -P)" && [ -n "$T" ] || { echo "  FAIL cannot resolve the sandbox path" >&2; exit 1; }

# The spy must SEE the OLDPWD a real client would receive. macOS /bin/sh is bash 3.2, which throws an
# inherited OLDPWD away at startup (bash >= 4.4, dash and zsh keep it): the record would read empty
# whatever preflight did. So the spy runs under the first sh that keeps it — the recipe
# test-model-subprocess.sh uses; if none does, the OLDPWD checks say SKIP instead of passing on nothing.
keeps_oldpwd() { env OLDPWD=/ "$1" -c '[ "${OLDPWD:-}" = / ]' 2>/dev/null; }
SPY_SH=""
for _s in /bin/sh /bin/dash /usr/bin/dash; do
  if [ -x "$_s" ] && keeps_oldpwd "$_s"; then SPY_SH="$_s"; break; fi
done
SPY="$T/spy-cli"
if [ -n "$SPY_SH" ]; then
  { printf '#!%s\n' "$SPY_SH"; tail -n +2 "$SPY_SRC"; } > "$SPY" || { echo "  FAIL cannot build the spy" >&2; exit 1; }
  echo "  note: spy interpreter $SPY_SH (keeps an inherited OLDPWD)"
else
  cp "$SPY_SRC" "$SPY" || { echo "  FAIL cannot copy the spy" >&2; exit 1; }
  echo "  note: no sh here keeps an inherited OLDPWD — the OLDPWD checks are SKIPPED"
fi
chmod +x "$SPY" || { echo "  FAIL cannot make the spy executable" >&2; exit 1; }

# Real timeout/gtimeout/jq, resolved BEFORE any PATH is narrowed (the driver and the runners need GNU
# timeout; without one every canary fails closed and the answering cases could never pass).
mkdir -p "$T/tools"
for _tool in timeout gtimeout jq; do
  _real="$(command -v "$_tool" 2>/dev/null || true)"
  [ -n "$_real" ] && ln -s "$_real" "$T/tools/$_tool"
done
[ -e "$T/tools/timeout" ] || [ -e "$T/tools/gtimeout" ] \
  || { echo "  FAIL GNU timeout (timeout or gtimeout) required — brew install coreutils" >&2; exit 1; }

# A COPY of the fixture CODEX_HOME: nothing a run does can touch the repo's fixture.
FIX="$T/codex-home"
cp -R "$FIX_SRC" "$FIX" || { echo "  FAIL cannot copy the fixture CODEX_HOME" >&2; exit 1; }
FIX_AUTH_SHA="$(shasum -a 256 < "$FIX/auth.json" | cut -d' ' -f1)"
FIX_CFG_SHA="$(shasum -a 256 < "$FIX/config.toml" | cut -d' ' -f1)"
# The audit model and effort the codex canary must use — read from the registry, not restated here.
# shellcheck disable=SC2016  # expanded by the child shell
REG="$(env -i PATH=/usr/bin:/bin /bin/bash -c '. "$1" && printf "%s|%s" "$ZUVO_MODEL_CODEX_PRIMARY" "$ZUVO_CODEX_EFFORT_AUDIT"' _ "$REGISTRY")"
REG_MODEL="${REG%%|*}"; REG_EFFORT="${REG#*|}"
[ -n "$REG_MODEL" ] && [ -n "$REG_EFFORT" ] || { echo "  FAIL cannot read the codex audit model/effort from $REGISTRY" >&2; exit 1; }

C=""; RC=""; OUT=""; ERR=""; ELAPSED=0; CT=""; PF_STDIN=""
# new_case <name> — a fresh case dir: bin (tool symlinks only), off (spies NOT on PATH), spy, home, tmp.
# PF_STDIN (preflight's stdin, /dev/null when empty) is reset for every case.
new_case() {
  C="$T/$1"; PF_STDIN=""
  mkdir -p "$C/bin" "$C/off" "$C/spy" "$C/home/.zuvo" "$C/tmp" || exit 1
  local t
  for t in timeout gtimeout jq; do
    if [ -e "$T/tools/$t" ]; then ln -s "$T/tools/$t" "$C/bin/$t"; fi
  done
  CT="$(cd "$C/tmp" && pwd -P)"
  echo "-- $1"
}
# spy <dir> <client-name> — the spy under the client's name (the name picks its record file).
spy() { ln -s "$SPY" "$1/$2"; }
# run_pf <preflight-script> [VAR=value | preflight-arg ...] — one hermetic preflight run, started from
# the REPO ROOT (so "the canary ran in the caller's cwd" is observable), stdin from $PF_STDIN (default
# /dev/null). A VAR=value given here comes after the defaults, so it overrides them (PATH included).
# Sets RC, OUT, ERR, ELAPSED.
run_pf() {
  local script="$1" a t0 t1
  shift
  local envs=() args=()
  for a in "$@"; do case "$a" in *=*) envs+=("$a") ;; *) args+=("$a") ;; esac; done
  t0="$(date +%s)"
  ( cd "$ROOT" && env -i HOME="$C/home" ZUVO_HOME="$C/home/.zuvo" TMPDIR="$C/tmp" CODEX_HOME="$FIX" \
      ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_CODEX_BIN=/nonexistent ZUVO_CLAUDE_BIN=/nonexistent \
      PATH="$C/bin:/usr/bin:/bin" SPY_DIR="$C/spy" \
      ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy" \
      ZUVO_PREFLIGHT_TIMEOUT=30 ZUVO_TIMEOUT_GRACE=2 ZUVO_PROVIDER_HEALTH_FILE="$C/health.tsv" \
      ${envs[@]+"${envs[@]}"} "$BASH" "$script" ${args[@]+"${args[@]}"} \
      < "${PF_STDIN:-/dev/null}" > "$C/out" 2> "$C/err" )
  RC=$?
  t1="$(date +%s)"; ELAPSED=$((t1 - t0))
  OUT="$(cat "$C/out")"; ERR="$(cat "$C/err")"
}
field() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
# Every record reader fails CLOSED when the spy left no record: a negative check ("no MCP servers",
# "not in the repo") must never pass because there was nothing to look at.
# rec <client> <key> — first value of <key> in the spy's record ("<no-record>" without one).
rec() {
  [ -f "$C/spy/$1.rec" ] || { echo "<no-record>"; return 0; }
  sed -n "s/^$2=//p" "$C/spy/$1.rec" | head -1
}
rec_has_line() { [ -f "$C/spy/$1.rec" ] && grep -qxF -e "$2" -- "$C/spy/$1.rec"; }
# rec_lacks <client> <ERE> — true only when the record EXISTS and no line matches <ERE>.
rec_lacks() { [ -f "$C/spy/$1.rec" ] && ! grep -qE -e "$2" -- "$C/spy/$1.rec"; }
# rec_arg_after <client> <flag> — the argv element right after <flag> ("<none>" / "<no-record>").
rec_arg_after() {
  [ -f "$C/spy/$1.rec" ] || { echo "<no-record>"; return 0; }
  awk -v f="arg=$2" 'found { sub(/^arg=/, ""); print; done = 1; exit } $0 == f { found = 1 }
    END { if (!done) print "<none>" }' "$C/spy/$1.rec"
}
# spy_stdin <client> — what the spy read on stdin ("<no-record>" when it never ran).
spy_stdin() { if [ -f "$C/spy/$1.stdin" ]; then cat "$C/spy/$1.stdin"; else echo "<no-record>"; fi; }
# contract <label> — stdout is exactly the eight keys, in the order the consumers read them.
contract() {
  local keys
  keys="$(printf '%s\n' "$OUT" | sed 's/=.*//' | tr '\n' ' ')"
  expect_eq "$1: stdout keeps the 8-line KEY=VALUE contract" \
    "preflight_status provider platform writer_model writer_lane reviewer_lane reviewer_model routing_status " "$keys"
}
# tmp_clean <label> — preflight's work dir (zuvo-preflight.*) and the runner's temp dir (zms.*, which
# holds the auth.json copy) are gone. The driver's own per-user state dir (zuvo-adv-<uid>, created by
# --list-providers and kept on purpose) is not preflight's to remove.
tmp_clean() {
  local left="" f
  for f in "$C/tmp"/zuvo-preflight.* "$C/tmp"/zms.*; do
    if [ -e "$f" ]; then left="$left${f##*/} "; fi
  done
  expect_eq "$1: nothing of preflight's or the runner's left in TMPDIR" "" "$left"
}
spy_ran()     { if [ -s "$C/spy/$2.rec" ]; then ok "$1: the $2 spy was invoked"; else bad "$1: the $2 spy was NOT invoked (vacuous run)"; fi; }
spy_not_ran() { if [ -e "$C/spy/$2.rec" ]; then bad "$1: the $2 spy was invoked but must not be"; else ok "$1: the $2 spy was not invoked"; fi; }
# neutral_cwd <label> <client> — the client ran in a temp dir under TMPDIR, not in the repository,
# and was not handed the repository through OLDPWD either. Both checks fail CLOSED: a missing record,
# an absent key and an empty value are none of them "under the temp dir".
neutral_cwd() {
  local p o
  p="$(rec "$2" pwd_P)"; o="$(rec "$2" OLDPWD_P)"
  if under "$CT" "$p" && ! under "$ROOT" "$p"; then ok "$1: $2 ran in a neutral temp cwd"
  else bad "$1: $2 cwd [$p] is not a temp dir under [$CT] outside the repo [$ROOT]"; fi
  if [ -z "$SPY_SH" ]; then echo "  SKIP $1: $2 OLDPWD (not observable — no sh here keeps it)"; return 0; fi
  if under "$CT" "$o" && ! under "$ROOT" "$o"; then ok "$1: $2 did not inherit the repository as OLDPWD"
  else bad "$1: $2 OLDPWD [$o] is not a temp dir under [$CT] outside the repo [$ROOT] (or was not recorded)"; fi
}

# ── 0. harness precondition: the candidate list really comes from the driver's pinned list ──
new_case harness
# shellcheck disable=SC2016
_list="$(cd "$ROOT" && env -i HOME="$C/home" ZUVO_HOME="$C/home/.zuvo" TMPDIR="$C/tmp" PATH="$C/bin:/usr/bin:/bin" \
  ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_CODEX_BIN=/nonexistent ZUVO_CLAUDE_BIN=/nonexistent \
  ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy" \
  bash "$DRIVER" --list-providers 2>/dev/null < /dev/null | tr '\n' ' ')"
expect_eq "harness: the driver's --list-providers returns the pinned test list" "codex-5.3 claude agy " "$_list"

# ── 1. codex off the PATH, ECHOING → canary-failed for codex ──────────────────
new_case codex-echo
spy "$C/off" codex
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" SPY_ECHO=1
spy_ran "codex echo" codex
expect_eq "codex echo: exit 1 (review infrastructure unavailable)" "1" "$RC"
expect_eq "codex echo: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "codex echo: provider names the client whose canary failed" "codex" "$(field provider)"
expect_has "codex echo: stderr says which canary failed" "canary codex" "$ERR"
contract "codex echo"
tmp_clean "codex echo"

# ── 2. codex off the PATH answering 42 → exit 0, provider=codex, isolated ─────
new_case codex-42
spy "$C/off" codex
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42
spy_ran "codex 42" codex
expect_eq "codex 42: exit 0 (a spy OFF the PATH named by ZUVO_CODEX_BIN is a candidate)" "0" "$RC"
expect_eq "codex 42: provider=codex" "codex" "$(field provider)"
expect_eq "codex 42: status is degraded-routing (all host signals cleared → unknown-writer-model)" \
  "degraded-routing" "$(field preflight_status)"
contract "codex 42"
_chome="$(rec codex CODEX_HOME)"
if [ -n "$_chome" ] && [ "$_chome" != "$FIX" ] && under "$CT" "$_chome"; then
  ok "codex 42: CODEX_HOME is the call's own temp dir, not the fixture/user dir"
else bad "codex 42: CODEX_HOME [$_chome] is not an isolated temp dir under [$CT] (fixture: $FIX)"; fi
expect_eq "codex 42: the isolated CODEX_HOME holds exactly auth.json + config.toml" "auth.json config.toml " "$(rec codex codex_home_ls)"
expect_eq "codex 42: auth.json is the fixture's (copied, not re-written)" "$FIX_AUTH_SHA" "$(rec codex auth_sha)"
if rec_lacks codex '^config=.*mcp_servers'; then ok "codex 42: config.toml carries no mcp_servers"
else bad "codex 42: config.toml carries mcp_servers (or no record)"; fi
if rec_has_line codex 'config=sandbox_mode = "read-only"'; then ok "codex 42: sandbox_mode = read-only"
else bad "codex 42: sandbox_mode is not read-only"; fi
if rec_has_line codex "config=model = \"$REG_MODEL\""; then ok "codex 42: model is the registry's audit model ($REG_MODEL)"
else bad "codex 42: model is not the registry's $REG_MODEL — $(grep '^config=model' "$C/spy/codex.rec")"; fi
if rec_has_line codex "config=model_reasoning_effort = \"$REG_EFFORT\""; then ok "codex 42: effort is ZUVO_CODEX_EFFORT_AUDIT ($REG_EFFORT)"
else bad "codex 42: effort is not $REG_EFFORT — $(grep '^config=model_reasoning_effort' "$C/spy/codex.rec")"; fi
expect_eq "codex 42: access none — shell tool disabled" "shell_tool" "$(rec_arg_after codex --disable)"
if rec_lacks codex '^arg=(danger-full-access|--dangerously-bypass-approvals-and-sandbox)$'; then
  ok "codex 42: argv carries no full-access flag"; else bad "codex 42: argv carries a full-access flag (or no record)"; fi
neutral_cwd "codex 42" codex
_stdin="$(spy_stdin codex)"
expect_has "codex 42: the prompt asks for a computed answer" "product of 6 and 7" "$_stdin"
expect_not_has "codex 42: the prompt does not contain the expected answer" "42" "$_stdin"
expect_eq "codex 42: the fixture CODEX_HOME's config.toml is untouched" "$FIX_CFG_SHA" "$(shasum -a 256 < "$FIX/config.toml" | cut -d' ' -f1)"
expect_eq "codex 42: the fixture CODEX_HOME's auth.json is untouched" "$FIX_AUTH_SHA" "$(shasum -a 256 < "$FIX/auth.json" | cut -d' ' -f1)"
tmp_clean "codex 42"

# ── 3. claude off the PATH, ECHOING; codex ON the PATH but ZUVO_CODEX_BIN=/nonexistent ──
new_case claude-echo
spy "$C/off" claude
spy "$C/bin" codex
run_pf "$PF" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_ECHO=1
spy_ran "claude echo" claude
spy_not_ran "claude echo (a set ZUVO_CODEX_BIN=/nonexistent is final — the codex on PATH is no candidate)" codex
expect_eq "claude echo: exit 1" "1" "$RC"
expect_eq "claude echo: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "claude echo: provider=claude" "claude" "$(field provider)"
contract "claude echo"
tmp_clean "claude echo"

# ── 4. claude off the PATH answering 42 → exit 0, provider=claude, isolated ───
new_case claude-42
spy "$C/off" claude
spy "$C/bin" codex
run_pf "$PF" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_REPLY=42
spy_ran "claude 42" claude
spy_not_ran "claude 42 (ZUVO_CODEX_BIN=/nonexistent)" codex
expect_eq "claude 42: exit 0" "0" "$RC"
expect_eq "claude 42: provider=claude" "claude" "$(field provider)"
contract "claude 42"
if rec_has_line claude 'arg=--strict-mcp-config'; then ok "claude 42: --strict-mcp-config"
else bad "claude 42: no --strict-mcp-config"; fi
expect_eq "claude 42: --mcp-config names an EMPTY MCP config" '{"mcpServers":{}}' "$(rec claude mcp_content)"
expect_eq "claude 42: --tools \"\" (no tools)" "" "$(rec_arg_after claude --tools)"
if rec_has_line claude 'arg=--safe-mode'; then ok "claude 42: --safe-mode"; else bad "claude 42: no --safe-mode"; fi
if rec_lacks claude '^arg=--dangerously-skip-permissions$'; then ok "claude 42: no --dangerously-skip-permissions"
else bad "claude 42: --dangerously-skip-permissions on a canary (or no record)"; fi
neutral_cwd "claude 42" claude
_stdin="$(spy_stdin claude)"
expect_has "claude 42: the prompt asks for a computed answer" "product of 6 and 7" "$_stdin"
expect_not_has "claude 42: the prompt does not contain the expected answer" "42" "$_stdin"
tmp_clean "claude 42"

# ── 5. agy on the PATH, ECHOING (the prompt reaches agy as an ARGUMENT) ───────
new_case agy-echo
spy "$C/bin" agy
run_pf "$PF" SPY_ECHO=1
spy_ran "agy echo" agy
expect_eq "agy echo: exit 1" "1" "$RC"
expect_eq "agy echo: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "agy echo: provider=agy" "agy" "$(field provider)"
contract "agy echo"
tmp_clean "agy echo"

# ── 6. agy answering 42 → exit 0, provider=agy, from a neutral cwd ────────────
new_case agy-42
spy "$C/bin" agy
run_pf "$PF" SPY_REPLY=42
spy_ran "agy 42" agy
expect_eq "agy 42: exit 0" "0" "$RC"
expect_eq "agy 42: provider=agy" "agy" "$(field provider)"
contract "agy 42"
neutral_cwd "agy 42" agy
_prompt="$(rec_arg_after agy -p)"
expect_has "agy 42: the prompt (argv) asks for a computed answer" "product of 6 and 7" "$_prompt"
expect_not_has "agy 42: the prompt does not contain the expected answer" "42" "$_prompt"
tmp_clean "agy 42"

# ── 7. every candidate is tried; an echo never wins over a real answer ────────
new_case mixed
spy "$C/off" codex
spy "$C/off" claude
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_ECHO=1
spy_ran "mixed" codex
spy_ran "mixed" claude
spy_ran "mixed" agy
expect_eq "mixed: exit 0" "0" "$RC"
expect_eq "mixed: provider=agy — the two echoing clients did not pass" "agy" "$(field provider)"
expect_has "mixed: stderr names the failed codex canary" "canary codex" "$ERR"
expect_has "mixed: stderr names the failed claude canary" "canary claude" "$ERR"
contract "mixed"
tmp_clean "mixed"

# ── 7b. a candidate that was available when the list was made and is GONE by its canary ──
# Availability (zms_client_available) is decided for every candidate BEFORE the first canary runs, so a
# client can pass it and then disappear — an uninstall, an unmounted volume, a tool upgrade mid-run.
# Built portably with no timing: the FIRST canary (codex, a wrapper that execs the spy under its own
# name) deletes the claude spy that ZUVO_CLAUDE_BIN names; claude's canary then finds no client. That
# canary must fail with a NAMED reason, and the loop must go on to the next candidate, which wins.
new_case vanished
mkdir -p "$C/real"
ln -s "$SPY" "$C/real/codex"
printf '#!/bin/sh\nrm -f "%s"\nexec "%s" "$@"\n' "$C/off/claude" "$C/real/codex" > "$C/off/codex"
chmod +x "$C/off/codex"
spy "$C/off" claude
spy "$C/bin" agy
printf 'no answer from this one\n' > "$C/spy/codex.reply"
printf '42\n' > "$C/spy/agy.reply"
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_CLAUDE_BIN="$C/off/claude"
spy_ran "vanished (the codex canary that removes the claude client)" codex
if [ ! -e "$C/off/claude" ]; then ok "vanished: premise — the claude client admitted as a candidate is gone before its canary"
else bad "vanished: premise — the claude spy still exists, the case proves nothing"; fi
spy_not_ran "vanished (claude, deleted before its canary)" claude
expect_has "vanished: the claude canary fails with a named reason" "canary claude failed: client not found" "$ERR"
expect_has "vanished: the codex canary (no 42) is named too" "canary codex failed: exit 0, no line reading 42" "$ERR"
spy_ran "vanished (the next candidate)" agy
expect_eq "vanished: exit 0 — the next candidate still ran and answered" "0" "$RC"
expect_eq "vanished: provider=agy" "agy" "$(field provider)"
contract "vanished"
tmp_clean "vanished"

# ── 7c. a reply that is an AUTH STUB (exit 0) is never the provider ──
# A logged-out CLI exits 0 and prints a login prompt instead of an answer. Not a 42, so it cannot pass —
# and the stderr line must say WHY (log the client in), from the reply on stdout (codex, through the
# runner) or on the client's stderr (agy, through run_neutral), without quoting the client's text.
new_case auth-stub-then-42
spy "$C/off" codex
spy "$C/off" claude
printf 'Not logged in \302\267 Please run /login\n' > "$C/spy/codex.reply"
printf '42\n' > "$C/spy/claude.reply"
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_CLAUDE_BIN="$C/off/claude"
spy_ran "auth stub, then 42" codex
spy_ran "auth stub, then 42" claude
expect_eq "auth stub, then 42: exit 0 — the next candidate answered" "0" "$RC"
expect_eq "auth stub, then 42: provider=claude, never the logged-out codex" "claude" "$(field provider)"
expect_has "auth stub, then 42: stderr names the codex canary's auth failure" \
  "canary codex failed: exit 0, no line reading 42 in the reply (the reply is an auth error — log the client in)" "$ERR"
expect_not_has "auth stub, then 42: the client's own text is not quoted on stderr" "Please run /login" "$ERR"
contract "auth stub, then 42"
tmp_clean "auth stub, then 42"

new_case auth-stub-only
spy "$C/bin" agy
: > "$C/spy/agy.reply"   # nothing on stdout: the stub is on the client's stderr only
run_pf "$PF" ZUVO_REVIEW_TEST_PROVIDERS=agy 'SPY_STDERR=Error: Not logged in. Please run /login'
spy_ran "auth stub only" agy
expect_eq "auth stub only: exit 1 — a logged-out client is no reviewer" "1" "$RC"
expect_eq "auth stub only: preflight_status=canary-failed (never ok / degraded-routing)" "canary-failed" "$(field preflight_status)"
expect_has "auth stub only: stderr names the agy canary's auth failure (read from the client's stderr)" \
  "canary agy failed: exit 0, no line reading 42 in the reply (the reply is an auth error — log the client in)" "$ERR"
expect_not_has "auth stub only: the client's own text is not quoted on stderr" "Please run /login" "$ERR"
contract "auth stub only"
tmp_clean "auth stub only"

# ── 7d. two candidates that BOTH answer: the first in candidate order is the provider, the loop stops ──
# The candidate order is the driver's list (codex-5.3 claude agy → codex, claude, agy). Preflight BREAKS
# at the first canary that passes (reviewer-preflight.sh: CANARY_OK=…; break): one canary is the budget,
# so the second answering client is never run at all.
new_case first-of-two
spy "$C/off" codex
spy "$C/off" claude
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_REPLY=42
spy_ran "first of two" codex
spy_not_ran "first of two (claude answers 42 too, but comes second — preflight stopped at codex)" claude
expect_eq "first of two: exit 0" "0" "$RC"
expect_eq "first of two: provider=codex, the first in candidate order" "codex" "$(field provider)"
expect_not_has "first of two: no canary is reported failed" "canary" "$ERR"
contract "first of two"
tmp_clean "first of two"

# ── 8. a hung client is bounded ──────────────────────────────────────────────
new_case agy-hung
spy "$C/bin" agy
run_pf "$PF" SPY_SLEEP=30 SPY_REPLY=42 ZUVO_PREFLIGHT_TIMEOUT=2
spy_ran "agy hung" agy
expect_eq "agy hung: exit 1" "1" "$RC"
expect_eq "agy hung: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
if [ "$ELAPSED" -lt 20 ]; then ok "agy hung: preflight returned within the bound (${ELAPSED}s)"
else bad "agy hung: preflight took ${ELAPSED}s with ZUVO_PREFLIGHT_TIMEOUT=2"; fi
expect_has "agy hung: stderr says the canary timed out" "timed out" "$ERR"
if poll 5 no_proc "$C/bin/agy"; then ok "agy hung: no agy spy process survives"
else bad "agy hung: an agy spy process survived preflight"; fi
contract "agy hung"
tmp_clean "agy hung"

new_case codex-hung
spy "$C/off" codex
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" SPY_SLEEP=30 SPY_REPLY=42 ZUVO_PREFLIGHT_TIMEOUT=2
spy_ran "codex hung" codex
expect_eq "codex hung: exit 1" "1" "$RC"
expect_eq "codex hung: provider=codex" "codex" "$(field provider)"
if [ "$ELAPSED" -lt 20 ]; then ok "codex hung: bounded by the runner's --timeout (${ELAPSED}s)"
else bad "codex hung: preflight took ${ELAPSED}s with ZUVO_PREFLIGHT_TIMEOUT=2"; fi
if poll 5 no_proc "$C/off/codex"; then ok "codex hung: no codex spy process survives"
else bad "codex hung: a codex spy process survived preflight"; fi
contract "codex hung"
tmp_clean "codex hung"

# ── 9. the shared runner is missing → fail closed ────────────────────────────
new_case no-lib
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
run_pf "$C/solo/reviewer-preflight.sh"
expect_eq "no lib: exit 1" "1" "$RC"
expect_eq "no lib: preflight_status=no-provider (fails closed)" "no-provider" "$(field preflight_status)"
expect_eq "no lib: provider=none" "none" "$(field provider)"
expect_has "no lib: stderr names the missing model-subprocess.sh" "model-subprocess.sh" "$ERR"
spy_not_ran "no lib (no client is run without the shared runner)" agy
expect_eq "no lib: routing_status passed through as routing-failed" "routing-failed" "$(field routing_status)"
contract "no lib"
tmp_clean "no lib"

# ── 10. lookup order: a broken <dir>/lib candidate is named, the flat sibling loads ──
new_case broken-lib
mkdir -p "$C/solo/lib"
cp "$PF" "$C/solo/reviewer-preflight.sh"
printf 'return 3\n' > "$C/solo/lib/model-subprocess.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
run_pf "$C/solo/reviewer-preflight.sh"
expect_eq "broken lib/: exit 0 (the flat sibling loaded)" "0" "$RC"
expect_eq "broken lib/: provider=agy" "agy" "$(field provider)"
expect_has "broken lib/: stderr WARNs about the candidate that did not load" "$C/solo/lib/model-subprocess.sh" "$ERR"
contract "broken lib/"
tmp_clean "broken lib/"

new_case home-lib
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/home/.zuvo/model-subprocess.sh"
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
run_pf "$C/solo/reviewer-preflight.sh"
expect_eq "~/.zuvo lib: exit 0 (the last candidate loads)" "0" "$RC"
expect_eq "~/.zuvo lib: provider=agy" "agy" "$(field provider)"
expect_not_has "~/.zuvo lib: no missing-runner error" "not loaded" "$ERR"
contract "~/.zuvo lib"
tmp_clean "~/.zuvo lib"

# A candidate WITHOUT zms_is_codex_host (an older copy) is not the runner: accepted, the host check
# would be "command not found" — false — and a Codex host would canary its own codex as the reviewer.
new_case partial-lib
mkdir -p "$C/solo/lib"
cp "$PF" "$C/solo/reviewer-preflight.sh"
{ cat "$LIB"; printf '\nunset -f zms_is_codex_host\n'; } > "$C/solo/lib/model-subprocess.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
spy "$C/off" codex
spy "$C/bin" agy
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_CODEX_MODEL="$REG_MODEL" \
  SPY_REPLY=42 CODEX_SHELL=1
expect_has "partial lib/: stderr WARNs about the candidate lacking zms_is_codex_host" "$C/solo/lib/model-subprocess.sh" "$ERR"
expect_not_has "partial lib/: the host check never ran as a missing command" "command not found" "$ERR"
spy_not_ran "partial lib/ (Codex host: codex excluded through the complete flat sibling)" codex
expect_eq "partial lib/: exit 0" "0" "$RC"
expect_eq "partial lib/: provider=agy" "agy" "$(field provider)"
contract "partial lib/"
tmp_clean "partial lib/"

# ── 11. --no-canary: availability only, no client is run ─────────────────────
new_case no-canary
spy "$C/bin" agy
run_pf "$PF" --no-canary
expect_eq "--no-canary: exit 0" "0" "$RC"
expect_eq "--no-canary: provider=agy" "agy" "$(field provider)"
spy_not_ran "--no-canary" agy
contract "--no-canary"
tmp_clean "--no-canary"

# ── 12. a leading-zero timeout reaches the runner as plain seconds ───────────
# The runners refuse "030" (--timeout must not start with 0): passed through unchanged, a value this
# script accepts would fail every codex/claude canary as "could not start".
new_case timeout-leading-zero
spy "$C/off" codex
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 ZUVO_PREFLIGHT_TIMEOUT=030
spy_ran "ZUVO_PREFLIGHT_TIMEOUT=030" codex
expect_eq "ZUVO_PREFLIGHT_TIMEOUT=030: exit 0" "0" "$RC"
expect_eq "ZUVO_PREFLIGHT_TIMEOUT=030: provider=codex" "codex" "$(field provider)"
contract "ZUVO_PREFLIGHT_TIMEOUT=030"
tmp_clean "ZUVO_PREFLIGHT_TIMEOUT=030"

# ── 13. a 42 from a client that FAILED does not count: exit ≠ 0, or a hang after answering ──
# An answer-then-crash or answer-then-hang client would otherwise be admitted as THE reviewer, and the
# blind audit would then run into the same crash or hang. Both paths: run_neutral (agy) and the runner (codex).
new_case agy-42-exit3
spy "$C/bin" agy
run_pf "$PF" SPY_REPLY=42 SPY_EXIT=3
spy_ran "agy 42+exit 3" agy
expect_eq "agy 42+exit 3: exit 1" "1" "$RC"
expect_eq "agy 42+exit 3: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "agy 42+exit 3: provider=agy" "agy" "$(field provider)"
expect_has "agy 42+exit 3: stderr names the client's exit status" "canary agy failed: exit 3" "$ERR"
contract "agy 42+exit 3"
tmp_clean "agy 42+exit 3"

new_case agy-42-then-hang
spy "$C/bin" agy
run_pf "$PF" SPY_REPLY=42 SPY_SLEEP_AFTER=30 ZUVO_PREFLIGHT_TIMEOUT=2
spy_ran "agy 42+hang" agy
expect_eq "agy 42+hang: exit 1" "1" "$RC"
expect_eq "agy 42+hang: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "agy 42+hang: provider=agy" "agy" "$(field provider)"
expect_has "agy 42+hang: stderr says the canary timed out" "canary agy failed: timed out" "$ERR"
if [ "$ELAPSED" -lt 20 ]; then ok "agy 42+hang: bounded (${ELAPSED}s)"
else bad "agy 42+hang: preflight took ${ELAPSED}s with ZUVO_PREFLIGHT_TIMEOUT=2"; fi
if poll 5 no_proc "$C/bin/agy"; then ok "agy 42+hang: no agy spy process survives"
else bad "agy 42+hang: an agy spy process survived preflight"; fi
contract "agy 42+hang"
tmp_clean "agy 42+hang"

new_case codex-42-exit3
spy "$C/off" codex
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 SPY_EXIT=3
spy_ran "codex 42+exit 3" codex
expect_eq "codex 42+exit 3: exit 1" "1" "$RC"
expect_eq "codex 42+exit 3: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "codex 42+exit 3: provider=codex" "codex" "$(field provider)"
expect_has "codex 42+exit 3: stderr names the client's exit status" "canary codex failed: exit 3" "$ERR"
contract "codex 42+exit 3"
tmp_clean "codex 42+exit 3"

new_case codex-42-then-hang
spy "$C/off" codex
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 SPY_SLEEP_AFTER=30 ZUVO_PREFLIGHT_TIMEOUT=2
spy_ran "codex 42+hang" codex
expect_eq "codex 42+hang: exit 1" "1" "$RC"
expect_eq "codex 42+hang: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "codex 42+hang: provider=codex" "codex" "$(field provider)"
expect_has "codex 42+hang: stderr says the canary timed out" "canary codex failed: timed out" "$ERR"
if [ "$ELAPSED" -lt 20 ]; then ok "codex 42+hang: bounded (${ELAPSED}s)"
else bad "codex 42+hang: preflight took ${ELAPSED}s with ZUVO_PREFLIGHT_TIMEOUT=2"; fi
if poll 5 no_proc "$C/off/codex"; then ok "codex 42+hang: no codex spy process survives"
else bad "codex 42+hang: a codex spy process survived preflight"; fi
contract "codex 42+hang"
tmp_clean "codex 42+hang"

# ── 14. the reply check is line-exact up to the documented trim ─────────────
# reply_case <case> <reply line> <expected exit> <why> — agy answers <reply line>, nothing else.
reply_case() {
  new_case "$1"
  spy "$C/bin" agy
  printf '%s\n' "$2" > "$C/spy/agy.reply"
  run_pf "$PF"
  spy_ran "$1" agy
  expect_eq "$1: exit $3 ($4)" "$3" "$RC"
  if [ "$3" = 0 ]; then expect_eq "$1: provider=agy" "agy" "$(field provider)"
  else expect_eq "$1: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"; fi
  contract "$1"
  tmp_clean "$1"
}
reply_case reply-142 '142' 1 "142 is not 42"
reply_case reply-sentence 'The answer is 42' 1 "a 42 inside a sentence is not a line reading 42"
reply_case reply-padded ' 42 ' 0 "surrounding blanks are trimmed"
reply_case reply-period '42.' 0 "a trailing period is trimmed"
reply_case reply-bold '**42**' 0 "markdown emphasis is trimmed"

# ── 15. neutral canaries: stdin is /dev/null, never the caller's ─────────────
# Under GNU timeout the client leads its own process group: reading an inherited TERMINAL it gets SIGTTIN
# and stalls until the budget ends; reading an inherited pipe it takes the caller's input as its own.
printf 'CALLER-STDIN\n' > "$T/caller-stdin"
for _cl in agy cursor-agent kimi; do
  new_case "stdin-$_cl"
  spy "$C/bin" "$_cl"
  PF_STDIN="$T/caller-stdin"
  run_pf "$PF" ZUVO_REVIEW_TEST_PROVIDERS="$_cl" SPY_REPLY=42
  spy_ran "stdin $_cl" "$_cl"
  expect_eq "stdin $_cl: exit 0" "0" "$RC"
  expect_eq "stdin $_cl: provider=$_cl" "$_cl" "$(field provider)"
  expect_eq "stdin $_cl: the client read NOTHING on stdin (not the caller's)" "0" "$(rec "$_cl" stdin_bytes)"
  neutral_cwd "stdin $_cl" "$_cl"
  _prompt="$(rec_arg_after "$_cl" -p)"
  expect_has "stdin $_cl: the prompt (argv) asks for a computed answer" "product of 6 and 7" "$_prompt"
  expect_not_has "stdin $_cl: the prompt does not contain the expected answer" "42" "$_prompt"
  contract "stdin $_cl"
  tmp_clean "stdin $_cl"
done

# gemini takes the prompt ON stdin: that, and not the caller's input.
new_case stdin-gemini
spy "$C/bin" gemini
PF_STDIN="$T/caller-stdin"
run_pf "$PF" ZUVO_REVIEW_TEST_PROVIDERS=gemini SPY_REPLY=42
spy_ran "stdin gemini" gemini
expect_eq "stdin gemini: exit 0" "0" "$RC"
expect_eq "stdin gemini: provider=gemini" "gemini" "$(field provider)"
_stdin="$(spy_stdin gemini)"
expect_has "stdin gemini: stdin carries the computed-answer prompt" "product of 6 and 7" "$_stdin"
expect_not_has "stdin gemini: stdin is not the caller's" "CALLER-STDIN" "$_stdin"
expect_not_has "stdin gemini: the prompt does not contain the expected answer" "42" "$_stdin"
expect_eq "stdin gemini: no MCP server allowed" "__NONE__" "$(rec_arg_after gemini --allowed-mcp-server-names)"
neutral_cwd "stdin gemini" gemini
contract "stdin gemini"
tmp_clean "stdin gemini"

# A caller stdin that never reaches EOF (a pipe whose writer stays open) must not hold the canary.
new_case stdin-open-pipe
spy "$C/bin" agy
mkfifo "$C/fifo" || { echo "  FAIL mkfifo failed" >&2; exit 1; }
sleep 40 > "$C/fifo" &
_writer=$!
PF_STDIN="$C/fifo"
run_pf "$PF" SPY_REPLY=42 ZUVO_PREFLIGHT_TIMEOUT=20
{ kill "$_writer"; wait "$_writer"; } 2>/dev/null
spy_ran "open stdin pipe" agy
expect_eq "open stdin pipe: exit 0 (agy did not wait on the caller's stdin)" "0" "$RC"
expect_eq "open stdin pipe: provider=agy" "agy" "$(field provider)"
if [ "$ELAPSED" -lt 10 ]; then ok "open stdin pipe: returned well under the 20s budget (${ELAPSED}s)"
else bad "open stdin pipe: preflight took ${ELAPSED}s — the canary waited on the caller's stdin"; fi
contract "open stdin pipe"
tmp_clean "open stdin pipe"

# ── 16. on a Codex host the host's own client is no candidate — ANY one of the four signals ──
for _sig in "CODEX_SANDBOX=seatbelt" "CODEX_SHELL=1" "__CFBundleIdentifier=com.openai.codex" \
            "CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop"; do
  _nm="${_sig%%=*}"
  new_case "codex-host-$_nm"
  spy "$C/off" codex
  spy "$C/bin" agy
  run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 "$_sig"
  spy_not_ran "codex host ($_sig): codex excluded" codex
  spy_ran "codex host ($_sig)" agy
  expect_eq "codex host ($_sig): exit 0" "0" "$RC"
  expect_eq "codex host ($_sig): provider=agy, not the host's own codex" "agy" "$(field provider)"
  contract "codex host ($_sig)"
  tmp_clean "codex host ($_sig)"
done

# ── 17. no GNU timeout on PATH: no canary runs unbounded, each is named on stderr ──
# PATH = spies + every /usr/bin and /bin tool EXCEPT timeout/gtimeout (a Linux /usr/bin has timeout).
new_case no-timeout
rm -f "$C/bin/timeout" "$C/bin/gtimeout"
mkdir -p "$C/sys"
ln -s /usr/bin/* "$C/sys/" 2>/dev/null
for _f in /bin/*; do
  if [ ! -e "$C/sys/${_f##*/}" ] && [ ! -L "$C/sys/${_f##*/}" ]; then ln -s "$_f" "$C/sys/"; fi
done
rm -f "$C/sys/timeout" "$C/sys/gtimeout"
_to="$(PATH="$C/bin:$C/sys" type -P timeout gtimeout 2>/dev/null || true)"
[ -z "$_to" ] || { echo "  FAIL no-timeout: a timeout still resolves on the case PATH ($_to)" >&2; exit 1; }
if [ ! -e "$C/sys/mktemp" ] || [ ! -e "$C/sys/awk" ]; then
  echo "  FAIL no-timeout: the tool farm is incomplete" >&2; exit 1
fi
spy "$C/off" codex
spy "$C/off" claude
for _cl in agy cursor-agent kimi gemini; do spy "$C/bin" "$_cl"; done
run_pf "$PF" PATH="$C/bin:$C/sys" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_REPLY=42 \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy cursor-agent kimi gemini"
expect_eq "no timeout: exit 1" "1" "$RC"
expect_eq "no timeout: preflight_status=canary-failed (never a silent pass)" "canary-failed" "$(field preflight_status)"
expect_eq "no timeout: provider names the first candidate" "codex" "$(field provider)"
for _cl in codex claude agy cursor-agent kimi gemini; do
  expect_has "no timeout: stderr says why the $_cl canary did not run" "canary $_cl not run: GNU timeout required" "$ERR"
  spy_not_ran "no timeout ($_cl is never run unbounded)" "$_cl"
done
contract "no timeout"
tmp_clean "no timeout"

echo "=== RESULT ==="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
