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
# Task 8 (docs/specs/2026-09-25-blind-audit-panel-plan.md, coverage row X2): the candidate LIST
# itself is no longer this script's own — it is exactly `adversarial-review(.sh) --list-providers
# --mode blind-audit`'s post-exclusion panel, mapped to this script's client names (codex-5.3 /
# codex-5.4 -> codex; everything else unchanged). Preflight keeps no exclusion logic of its own any
# more (CQ14): host-vendor exclusion (CLAUDECODE, a Codex host, Antigravity, Cursor) and the
# isolation allowlist (cursor-agent and gemini can never be candidates — not proven isolated for a
# blind audit) are the driver's alone. Driver missing, or its listing failing, fails this script
# CLOSED (no-provider) — never a private fallback list.
#
# What this pins:
#   * the candidate list equals the driver's `--list-providers --mode blind-audit`, mapped (codex-5.3
#     AND codex-5.4 collapse into ONE `codex` canary attempt);
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
#     CODEX_INTERNAL_ORIGINATOR_OVERRIDE="Codex Desktop" — codex is no candidate; on CLAUDECODE=1,
#     claude is no candidate: BOTH are the DRIVER's own zms_is_codex_host / host-vendor exclusion now,
#     never a second check in this script (source-lint pins that it is gone from here);
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
BAP="$ROOT/scripts/lib/blind-audit-panel.sh"
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

for _f in "$PF" "$LIB" "$DRIVER" "$BAP" "$SPY_SRC" "$FIX_SRC/auth.json" "$FIX_SRC/config.toml" "$REGISTRY"; do
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
# shellcheck source=tests/lib/hermetic-tools.sh
. "$ROOT/tests/lib/hermetic-tools.sh"
hermetic_link_tools "$T/tools" timeout gtimeout jq
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
# tmp_clean <label> — TMPDIR holds nothing but the driver's own per-user state dir (zuvo-adv-<uid>,
# created by --list-providers and kept on purpose — not preflight's to remove): preflight's work dir
# (zuvo-preflight.*), the runner's temp dir (zms.*, which holds the auth.json copy) and anything under
# ANY other name — a new temp file, a `mktemp` without a template (tmp.XXXX) — are gone. The dir itself
# must still be there: an `ls` of a vanished TMPDIR would read as empty too.
tmp_clean() {
  local left
  if [ ! -d "$C/tmp" ]; then bad "$1: TMPDIR itself is gone"; return 0; fi
  left="$(ls -A "$C/tmp" | awk -v keep="zuvo-adv-$(id -u)" '$0 != keep' | tr '\n' ' ')"
  expect_eq "$1: nothing left in TMPDIR but the driver's zuvo-adv-$(id -u)" "" "$left"
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
# install_home_driver — a fully working adversarial-review + its libs, copied into THIS case's
# ~/.zuvo (the SECOND candidate in reviewer-preflight's driver lookup: <dir>/adversarial-review.sh
# sibling first, then ~/.zuvo/adversarial-review, no `.sh` — matching scripts/install.sh). For cases
# whose reviewer-preflight.sh copy has no adversarial-review.sh sibling of its own: without this, the
# driver-missing check (Task 8, RED d) would fire and the case would prove nothing about what it is
# actually testing (a broken/partial model-subprocess.sh candidate, a symlinked SCRIPT_DIR, …).
# ADV-C43/C56: bad()-and-return, matching this file's own convention everywhere else — the old
# `|| exit 1` on every step discarded every pass/fail already accumulated in the whole suite on a
# single copy failure, and printed no case attribution at all.
install_home_driver() {
  mkdir -p "$C/home/.zuvo/lib" || { bad "install_home_driver: mkdir -p $C/home/.zuvo/lib failed"; return 1; }
  cp "$DRIVER" "$C/home/.zuvo/adversarial-review" || { bad "install_home_driver: cp $DRIVER failed"; return 1; }
  cp "$LIB" "$C/home/.zuvo/lib/model-subprocess.sh" || { bad "install_home_driver: cp $LIB failed"; return 1; }
  cp "$BAP" "$C/home/.zuvo/lib/blind-audit-panel.sh" || { bad "install_home_driver: cp $BAP failed"; return 1; }
}
# ADV-C74: install_home_driver's ~/.zuvo/lib/model-subprocess.sh side effect is exactly what a case
# needs when it is ALSO the thing being tested (e.g. "home-lib" below), but it silently defeats a
# case whose whole claim is "the FLAT SIBLING specifically loads" (broken-lib,
# partial-lib-with-fallback) — with both a flat sibling AND a valid ~/.zuvo/lib candidate present,
# `exit 0` / `provider=agy` pass either way, and the case's own name is asserted by inference (the
# documented lookup order) rather than proven. This narrower helper supplies ONLY the driver (what
# those cases actually need to avoid a false "driver missing" failure), never a lib candidate.
install_home_driver_no_lib() {
  mkdir -p "$C/home/.zuvo" || { bad "install_home_driver_no_lib: mkdir -p $C/home/.zuvo failed"; return 1; }
  cp "$DRIVER" "$C/home/.zuvo/adversarial-review" || { bad "install_home_driver_no_lib: cp $DRIVER failed"; return 1; }
  cp "$BAP" "$C/home/.zuvo/blind-audit-panel.sh" || { bad "install_home_driver_no_lib: cp $BAP failed"; return 1; }
}
# lint_no_token <file> <ERE> — true (a hit) when <ERE> appears in <file> OUTSIDE a comment. T3 (fix
# round 1): a bare `grep -q` counted a token inside a comment EXPLAINING why the check is gone as
# if it were the check itself — hit once already, on this file's own prose, before the comment was
# reworded to dodge it. `-E` throughout so the same helper takes both a plain token and an
# alternation.
#
# T6 (fix round 2): a MISSING or unreadable file must FAIL this check (return 0, "a hit" — the
# caller's `bad` branch), not silently read as "no hit". A lint that cannot see the file it is
# supposed to be checking has proven nothing, and "the file doesn't exist so the forbidden pattern
# isn't in it" is exactly backwards for a lint meant to fail closed.
#
# T7 (fix round 2): comments are stripped with `sed -E 's/(^|[[:space:]])#.*$//'` — a `#` at the
# START of a line OR preceded by whitespace, through end of line, is removed; this covers a full
# comment LINE and a TRAILING end-of-line comment in one pass, and — the reason it is not simply
# "strip from the first #" — it leaves a `#` that is NOT preceded by whitespace or line-start
# alone, so `${VAR#pattern}` / `${VAR##pattern}` parameter expansion in real code is never mistaken
# for a comment opener.
#
# ADV-C44/C45/C46/C54: this is a best-effort LINT, not a shell parser — the strip is purely
# textual, not quote-aware, so a real code line like `echo "value # CLAUDECODE"` has its
# ` # CLAUDECODE` stripped as if it were a comment (a false negative: a genuine in-code token
# inside a quoted string would not be seen). Accepted, not fixed: none of the four tokens this
# lint actually greps for (zms_is_codex_host, HOST_EXCLUDE, CLAUDECODE, the host-signal
# alternation) currently appear inside a quoted string anywhere in scripts/reviewer-preflight.sh,
# and a quote-aware rewrite risks new bugs in a working helper for a scenario that does not occur.
lint_no_token() {
  [ -r "$1" ] || return 0
  sed -E 's/(^|[[:space:]])#.*$//' "$1" | grep -qE -- "$2"
}

# ── 0. harness precondition: the driver's blind-audit panel list is what this script now sources ──
new_case harness
# shellcheck disable=SC2016
_list="$(cd "$ROOT" && env -i HOME="$C/home" ZUVO_HOME="$C/home/.zuvo" TMPDIR="$C/tmp" PATH="$C/bin:/usr/bin:/bin" \
  ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_CODEX_BIN=/nonexistent ZUVO_CLAUDE_BIN=/nonexistent \
  ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 codex-5.4 claude agy" \
  bash "$DRIVER" --list-providers --mode blind-audit 2>/dev/null < /dev/null | tr '\n' ' ')"
expect_eq "harness: the driver's --list-providers --mode blind-audit returns the pinned test list" \
  "codex-5.3 codex-5.4 claude agy " "$_list"

# ── 0a. RED (a): preflight's candidate list is exactly that list, mapped to its client names —
# codex-5.3 AND codex-5.4 collapse into ONE `codex` canary attempt, never two ──
new_case candidates-match-driver
spy "$C/off" codex
spy "$C/off" claude
spy "$C/bin" agy
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_CLAUDE_BIN="$C/off/claude" \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 codex-5.4 claude agy" SPY_ECHO=1
spy_ran "candidates match driver" codex
spy_ran "candidates match driver" claude
spy_ran "candidates match driver" agy
expect_eq "candidates match driver: exit 1 (all three echo, none answers)" "1" "$RC"
_ccount="$(printf '%s\n' "$ERR" | grep -c 'canary codex failed')"
expect_eq "candidates match driver: codex-5.3 AND codex-5.4 map to ONE codex canary attempt, not two" \
  "1" "$_ccount"
expect_has "candidates match driver: claude canary attempted" "canary claude failed" "$ERR"
expect_has "candidates match driver: agy canary attempted" "canary agy failed" "$ERR"
contract "candidates match driver"
tmp_clean "candidates match driver"

# ── 0b. RED (b), T1 control pair: CLAUDECODE deliberately UNSET → claude IS a candidate; CLAUDECODE=1
# → claude is excluded. Only the excluded half was asserted before T1 — without this control, a
# preflight that excluded claude UNCONDITIONALLY (a regression indistinguishable from correct
# behaviour on the excluded case alone) would still pass every existing assertion. Both cases run
# with an otherwise-IDENTICAL env (ZUVO_ADVERSARIAL_TEST_HARNESS=1 from run_pf's own fixed default
# either way — T5: never left to whatever the caller's shell happens to have), differing ONLY in
# CLAUDECODE, so the difference in outcome is attributable to that one variable.
new_case claudecode-unset-control
spy "$C/off" claude
run_pf "$PF" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_REPLY=42 ZUVO_REVIEW_TEST_PROVIDERS=claude
spy_ran "CLAUDECODE unset" claude
expect_eq "CLAUDECODE unset: exit 0" "0" "$RC"
expect_eq "CLAUDECODE unset: provider=claude — a candidate when CLAUDECODE is not set" "claude" "$(field provider)"
contract "CLAUDECODE unset"
tmp_clean "CLAUDECODE unset"

new_case claudecode-host
spy "$C/off" claude
spy "$C/bin" agy
run_pf "$PF" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_REPLY=42 CLAUDECODE=1
spy_not_ran "CLAUDECODE=1: claude excluded (the driver's own host-vendor exclusion)" claude
spy_ran "CLAUDECODE=1" agy
expect_eq "CLAUDECODE=1: exit 0" "0" "$RC"
expect_eq "CLAUDECODE=1: provider=agy, not the host's own claude" "agy" "$(field provider)"
contract "CLAUDECODE=1"
tmp_clean "CLAUDECODE=1"

# ── 0c. RED (d): the panel driver is missing entirely → fail closed, no client run ──
new_case no-driver
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
run_pf "$C/solo/reviewer-preflight.sh"
expect_eq "no driver: exit 1" "1" "$RC"
expect_eq "no driver: preflight_status=no-provider (fails closed)" "no-provider" "$(field preflight_status)"
expect_eq "no driver: provider=none" "none" "$(field provider)"
expect_has "no driver: stderr names the missing panel driver" "adversarial-review" "$ERR"
spy_not_ran "no driver (no client is run without the panel driver)" agy
contract "no driver"
tmp_clean "no driver"

# ── 0d. RED (d), T2: the panel driver exists but its listing FAILS (nonzero exit) → fail closed
# too, with its OWN distinct message — F1: the driver's stderr FIRST LINE ("boom") reaches the
# operator, and its exit code is named — never the same generic text the legitimate-but-empty
# case below prints (which is: nothing at all). This is a driver malfunction, not "nothing
# available", and the two must read differently on stderr, not just both end in no-provider.
new_case driver-list-fails
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
printf '#!/bin/sh\necho "boom" >&2\necho "second line, must not be the one quoted" >&2\nexit 2\n' \
  > "$C/solo/adversarial-review.sh"
chmod +x "$C/solo/adversarial-review.sh"
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
run_pf "$C/solo/reviewer-preflight.sh"
expect_eq "driver list fails: exit 1" "1" "$RC"
expect_eq "driver list fails: preflight_status=no-provider (fails closed)" "no-provider" "$(field preflight_status)"
expect_eq "driver list fails: provider=none" "none" "$(field provider)"
expect_has "driver list fails: stderr names the driver" "adversarial-review.sh" "$ERR"
expect_has "driver list fails: stderr names the exit code" "exited 2:" "$ERR"
expect_has "driver list fails: stderr carries the driver's FIRST stderr line (F1)" "boom" "$ERR"
expect_not_has "driver list fails: not the driver's SECOND stderr line" "second line, must not be the one quoted" "$ERR"
spy_not_ran "driver list fails (no client is run when the panel listing fails)" agy
contract "driver list fails"
tmp_clean "driver list fails"
rm -f "$C/solo/adversarial-review.sh"

# ── F4: a driver whose stderr OPENS with a blank line — the FIRST NON-EMPTY line ("boom") must
# still reach the message, not the generic fallback a naive `head -n 1` (which would have taken the
# blank line itself) would have produced. ──
new_case driver-list-fails-blank-first-line
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
cat > "$C/solo/adversarial-review.sh" <<'STUBEOF'
#!/bin/sh
printf '\nboom\n' >&2
exit 2
STUBEOF
chmod +x "$C/solo/adversarial-review.sh"
run_pf "$C/solo/reviewer-preflight.sh"
expect_eq "blank first line: exit 1" "1" "$RC"
expect_eq "blank first line: preflight_status=no-provider" "no-provider" "$(field preflight_status)"
expect_has "blank first line: the message carries the first NON-EMPTY line, not a blank" \
  "exited 2: boom" "$ERR"
contract "blank first line"
tmp_clean "blank first line"
rm -f "$C/solo/adversarial-review.sh"

# ── F5: the driver's stderr text is embedded with printf '%s\n', never echo — a literal `\c` /
# `\n` in that text (2 real characters each, backslash + letter) must come through VERBATIM, not
# be reinterpreted as a C-style escape the way some `echo` builtins/modes would. ──
new_case driver-list-fails-backslash-text
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
cat > "$C/solo/adversarial-review.sh" <<'STUBEOF'
#!/bin/sh
printf '%s\n' 'literal \c and \n stay put' >&2
exit 2
STUBEOF
chmod +x "$C/solo/adversarial-review.sh"
run_pf "$C/solo/reviewer-preflight.sh"
expect_eq "backslash text: exit 1" "1" "$RC"
expect_has "backslash text: the driver's \\c/\\n survive verbatim (F5)" \
  'literal \c and \n stay put' "$ERR"
contract "backslash text"
tmp_clean "backslash text"
rm -f "$C/solo/adversarial-review.sh"

# T2 companion: the driver runs FINE and legitimately lists ZERO candidates (every lane excluded
# for this host/env — a real "nothing available", not a driver malfunction) → also no-provider,
# but with NO "exited N" driver-failure text at all — proving the two no-provider paths read
# distinctly on stderr, never confusable with one another.
new_case driver-list-empty
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
printf '#!/bin/sh\nexit 0\n' > "$C/solo/adversarial-review.sh"
chmod +x "$C/solo/adversarial-review.sh"
run_pf "$C/solo/reviewer-preflight.sh"
expect_eq "driver list empty: exit 1" "1" "$RC"
expect_eq "driver list empty: preflight_status=no-provider" "no-provider" "$(field preflight_status)"
expect_eq "driver list empty: provider=none" "none" "$(field provider)"
expect_not_has "driver list empty: no driver-failure message (the driver succeeded; it just listed nothing)" \
  "exited" "$ERR"
# T8: assert the zero-candidates outcome POSITIVELY — its actual shape — not only the absence of
# "exited". There is no driver-malfunction diagnostic to print here (the driver succeeded; it is
# not a bug to report), so the positive claim is twofold: stderr is EXACTLY empty (not merely
# lacking one substring), and stdout is EXACTLY the no-provider sentinel's 8 lines, byte for byte —
# $C/solo has no reviewer-model-route.sh sibling, so routing degrades to the documented
# unknown-writer-model sentinel block, and that whole block is what a caller actually parses.
expect_eq "driver list empty: stderr is exactly empty" "" "$ERR"
expect_eq "driver list empty: stdout is exactly the no-provider sentinel block" \
"preflight_status=no-provider
provider=none
platform=unknown
writer_model=unknown
writer_lane=unknown
reviewer_lane=same-model-fallback
reviewer_model=unknown
routing_status=routing-failed" "$OUT"
contract "driver list empty"
tmp_clean "driver list empty"
rm -f "$C/solo/adversarial-review.sh"

# ── F2: PANEL_OUT (and DETECTED/CANDIDATES downstream) is consumed with `read` into a bash ARRAY,
# never unquoted `for x in $PANEL_OUT` / `for x in $DETECTED` word-splitting or globbing. A
# candidate line containing a SPACE or a `*` must reach zms_client_available and the canary loop
# as ONE untouched string — proven with REAL executables under those exact (space-/glob-
# containing) names: a split "weird" alone, or an expanded "*", would find nothing there.
new_case panel-out-weird-names
mkdir -p "$C/solo" "$C/weird-bin"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "weird lane" "another*name"\n' > "$C/solo/adversarial-review.sh"
chmod +x "$C/solo/adversarial-review.sh"
printf '#!/bin/sh\nexit 0\n' > "$C/weird-bin/weird lane"
chmod +x "$C/weird-bin/weird lane"
printf '#!/bin/sh\nexit 0\n' > "$C/weird-bin/another*name"
chmod +x "$C/weird-bin/another*name"
run_pf "$C/solo/reviewer-preflight.sh" "PATH=$C/weird-bin:$C/bin:/usr/bin:/bin"
expect_eq "weird names: exit 1 (neither weird candidate has a canary defined)" "1" "$RC"
expect_eq "weird names: provider is the FIRST candidate, its embedded space intact" "weird lane" "$(field provider)"
expect_has "weird names: the space-containing candidate reached the canary loop whole" \
  "canary weird lane not run: no canary is defined for this client" "$ERR"
expect_has "weird names: the glob-containing candidate reached the canary loop whole, unexpanded" \
  "canary another*name not run: no canary is defined for this client" "$ERR"
contract "weird names"
tmp_clean "weird names"
rm -f "$C/solo/adversarial-review.sh"

# ── F6: each panel line is CR-stripped, then trimmed of surrounding blanks, before pf_map_lane —
# a CRLF-terminated listing must yield the real lane names (not "codex-5.3\r", which matches
# neither the codex-5.3|codex-5.4 case in pf_map_lane NOR the codex client name later, so a broken
# strip would silently drop the codex candidate — observable as "the codex spy was never invoked"),
# and a line of nothing but spaces must be skipped exactly like an empty line (proven by counting
# canary attempts: exactly 2, never a phantom third candidate for the blank line). ──
new_case panel-out-crlf-and-blank-line
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
# The codex/claude canaries read their model id from the registry (zms_source_registry): sibling-
# first relative to model-subprocess.sh's OWN location (which needs a `skills/` dir there to mean
# "a real repo" — $C/solo is not one), then ~/.zuvo/model-registry.sh. Supply the latter so this
# case exercises the SAME codex/claude canary path the real installs use, not a "no model id" skip
# that would happen to also never invoke the spy (a false pass for entirely the wrong reason).
cp "$REGISTRY" "$C/home/.zuvo/model-registry.sh"
cat > "$C/solo/adversarial-review.sh" <<'STUBEOF'
#!/bin/sh
printf 'codex-5.3\r\n'
printf '   \r\n'
printf 'claude\r\n'
STUBEOF
chmod +x "$C/solo/adversarial-review.sh"
spy "$C/off" codex
spy "$C/off" claude
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_ECHO=1
spy_ran "CRLF listing: the CR was stripped — this is 'codex' (from codex-5.3), not a mangled name" codex
spy_ran "CRLF listing" claude
expect_eq "CRLF listing: exit 1 (both echo, neither answers)" "1" "$RC"
_canary_lines="$(printf '%s\n' "$ERR" | grep -c '^reviewer-preflight: canary ')"
expect_eq "CRLF listing: exactly 2 canary attempts — the whitespace-only line was skipped, not a phantom third candidate" \
  "2" "$_canary_lines"
contract "CRLF listing"
tmp_clean "CRLF listing"
rm -f "$C/solo/adversarial-review.sh"

# ── ADV-A87: pf_map_lane only collapses codex-5.3/5.4 into "codex" — a hypothetical future
# codex-5.5+ tier (one CLI still answers to all of them, per this file's own comment) must collapse
# the same way, not fall through unmapped and silently lose its canary. ──
new_case pf-map-lane-forward-compat-codex-tier
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
cp "$REGISTRY" "$C/home/.zuvo/model-registry.sh"
printf '#!/bin/sh\nprintf "codex-5.5\\n"\n' > "$C/solo/adversarial-review.sh"
chmod +x "$C/solo/adversarial-review.sh"
spy "$C/off" codex
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_ECHO=1
spy_ran "future codex tier (codex-5.5): pf_map_lane still collapses it to the codex canary" codex
expect_eq "future codex tier: exit 1 (the echoing spy answers nothing)" "1" "$RC"
contract "future codex tier"
tmp_clean "future codex tier"
rm -f "$C/solo/adversarial-review.sh"

# ── F3: the panel listing can run up to 20s — a kill during that window must not leak the
# stderr-capture temp file (zuvo-preflight-panel-err.*). The stub sleeps well past the moment we
# signal preflight directly (via `exec`, so the backgrounded PID IS the actual bash process, not a
# wrapper around it) with SIGTERM; TMPDIR is inspected only after preflight has actually exited.
# ADV-A88: the stub sleeps 30s (comfortably longer than the short poll window below, and longer
# than run_with_timeout's own 20s+5s-grace bound would take to reap an orphan on its own) so
# "the in-flight child is gone quickly" can only mean the trap explicitly killed it, never that
# it happened to finish naturally or was reaped by the unrelated 20s ceiling within the window. ──
new_case panel-err-file-sigterm-cleanup
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
cat > "$C/solo/adversarial-review.sh" <<'STUBEOF'
#!/bin/sh
sleep 30
printf 'agy\n'
STUBEOF
chmod +x "$C/solo/adversarial-review.sh"
# ADV-C50: true only when a real zuvo-preflight-panel-err.* file exists right now — checked BEFORE
# signaling (below) so the later "no leaked panel-err temp file" assertion cannot pass vacuously by
# the file having never been created in the first place (e.g. SIGTERM landing before the mktemp call).
panel_err_created() { for _pef in "$C/tmp"/zuvo-preflight-panel-err.*; do [ -e "$_pef" ] && return 0; done; return 1; }
( cd "$ROOT" && exec env -i HOME="$C/home" ZUVO_HOME="$C/home/.zuvo" TMPDIR="$C/tmp" \
    ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_CODEX_BIN=/nonexistent ZUVO_CLAUDE_BIN=/nonexistent \
    PATH="$C/bin:/usr/bin:/bin" ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=agy \
    ZUVO_PREFLIGHT_TIMEOUT=30 ZUVO_TIMEOUT_GRACE=2 ZUVO_PROVIDER_HEALTH_FILE="$C/health.tsv" \
    "$BASH" "$C/solo/reviewer-preflight.sh" < /dev/null > "$C/out" 2> "$C/err" ) &
_pf_pid=$!
# ADV-C49: poll for the panel-err file's actual creation instead of a fixed `sleep 1` — a
# slow/loaded host could still be before the mktemp call at a flat 1s, sending the SIGTERM before
# the window this case means to test and weakening what it proves.
if poll 5 panel_err_created; then
  ok "F3: premise — the panel-err temp file was created before signaling"
else
  bad "F3: premise — no panel-err temp file ever appeared; the case below proves nothing"
fi
kill -TERM "$_pf_pid" 2>/dev/null
wait "$_pf_pid" 2>/dev/null
RC=$?
if [ "$RC" -eq 0 ]; then
  bad "F3: premise — preflight exited 0, the SIGTERM apparently never reached it (case proves nothing)"
else ok "F3: premise — preflight did not exit 0 (the SIGTERM took effect, exit $RC)"; fi
_left=""
for _leftf in "$C/tmp"/zuvo-preflight-panel-err.*; do
  [ -e "$_leftf" ] || continue
  _left="$_left ${_leftf##*/}"
done
_left="${_left# }"
if [ -z "$_left" ]; then ok "F3: no zuvo-preflight-panel-err.* left in TMPDIR after SIGTERM during listing"
else bad "F3: leaked panel-err temp file(s) after SIGTERM: $_left"; fi
# ADV-C51: tmp_clean extends coverage to any OTHER TMPDIR leak besides the one named file above.
# `contract` is deliberately NOT called here — $OUT is incomplete after a mid-run SIGTERM, so the
# 8-line KEY=VALUE contract cannot hold and asserting it would be testing the wrong thing.
tmp_clean "F3 panel-err sigterm cleanup"
# ADV-A88 (confidence-rescored, REJECTED on re-verification): the code has no EXPLICIT
# child-pid-tracking kill in the INT/TERM trap, but a direct `kill -TERM <preflight-pid>` (the
# exact "not a group-wide Ctrl-C" case the finding worried was uncovered) was verified — here and
# by hand outside this suite — to already take the in-flight run_with_timeout child down with it,
# not leave it orphaned to its own ~20s+5s-grace bound. This case pins that already-correct
# behavior so a future change (e.g. disowning the child, or a different backgrounding shape)
# cannot silently reintroduce the orphan this finding described.
if poll 3 no_proc "$C/solo/adversarial-review.sh"; then
  ok "F3: the in-flight panel-listing child dies with a direct SIGTERM to preflight, not left running as an orphan (ADV-A88, pinned)"
else
  bad "F3: the in-flight panel-listing child survived the SIGTERM — orphaned until its own timeout bound (ADV-A88 regression)"
fi
# ADV-C57 (scope note, not fixed): only the bash process running the stub is checked above (by its
# argv, which names the stub's path); the stub's OWN `sleep 30` grandchild has no comparably
# specific argv to assert on without risking a false match against an unrelated `sleep` elsewhere
# on a shared dev machine. Outside this case's own stated scope (its docstring above claims only
# the panel-err temp file); an orphaned sleep in a throwaway per-case namespace has no real cost.
rm -f "$C/solo/adversarial-review.sh"

# ── ADV-A92: the panel listing's own timeout must be tunable (ZUVO_PREFLIGHT_PANEL_TIMEOUT), not
# hardcoded — proven end-to-end: a stub that sleeps 8s must be cut off around a 2s panel timeout
# (well before its own natural completion), verified by wall-clock elapsed time staying well under
# the stub's 8s, not just under the default 20s. ──
new_case panel-list-timeout-tunable
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
cat > "$C/solo/adversarial-review.sh" <<'STUBEOF'
#!/bin/sh
sleep 8
printf 'agy\n'
STUBEOF
chmod +x "$C/solo/adversarial-review.sh"
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_PREFLIGHT_PANEL_TIMEOUT=2 --no-canary
if [ "$ELAPSED" -le 6 ]; then
  ok "panel-list-timeout: ZUVO_PREFLIGHT_PANEL_TIMEOUT=2 cut the 8s stub short (elapsed=${ELAPSED}s)"
else
  bad "panel-list-timeout: ZUVO_PREFLIGHT_PANEL_TIMEOUT=2 did not shorten the panel-list timeout (elapsed=${ELAPSED}s, stub sleeps 8s)"
fi
expect_eq "panel-list-timeout: exit 1 (no-provider — the listing itself timed out)" "1" "$RC"
rm -f "$C/solo/adversarial-review.sh"

# ── 0e. driver lookup: SCRIPT_DIR has no adversarial-review.sh sibling — the ~/.zuvo/adversarial-review
# fallback (no `.sh`, matching scripts/install.sh's rename) is found and used ──
new_case driver-home-fallback
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
install_home_driver
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
expect_eq "driver ~/.zuvo fallback: exit 0 (~/.zuvo/adversarial-review, no .sh, was found)" "0" "$RC"
expect_eq "driver ~/.zuvo fallback: provider=agy" "agy" "$(field provider)"
contract "driver ~/.zuvo fallback"
tmp_clean "driver ~/.zuvo fallback"

# ADV-C55: T3/T6/T7 (prove lint_no_token itself is correct) now run BEFORE 0f (which USES
# lint_no_token to check reviewer-preflight.sh) — purely a readability/diagnostic-ordering fix,
# no functional change: the shared `fail`/`ok`/`bad` bookkeeping means a broken helper already
# turned the whole run RED via these very assertions regardless of order.
#
# ── T3: prove lint_no_token actually strips comment LINES, both directions — a bare `grep -q`
# would have failed the FIRST of these two (this exact bug, hit once already: a comment explaining
# the removal of zms_is_codex_host named the function and tripped its own lint). ──
new_case source-lint-comment-strip
printf '#!/usr/bin/env bash\n# CLAUDECODE is mentioned only in this comment, never called\necho hi\n' \
  > "$C/comment-only.sh"
printf '#!/usr/bin/env bash\n[ "${CLAUDECODE:-}" = "1" ] && echo yes\n' > "$C/in-code.sh"
if lint_no_token "$C/comment-only.sh" 'CLAUDECODE'; then
  bad "T3: a token inside a comment LINE must NOT trip the lint (false positive)"
else ok "T3: a token inside a comment line does not trip the lint"; fi
if lint_no_token "$C/in-code.sh" 'CLAUDECODE'; then
  ok "T3: the SAME token in actual code still trips the lint"
else bad "T3: a token in actual code failed to trip the lint (too permissive — would miss a real regression)"; fi

# ── T6: a MISSING/unreadable file must FAIL the lint (a hit), never read as "no token found" ──
if lint_no_token "$C/does-not-exist.sh" 'CLAUDECODE'; then
  ok "T6: a nonexistent target file trips the lint (fails closed) rather than reading as no-hit"
else bad "T6: a nonexistent target file was read as 'no hit' — a lint that cannot see the file proved nothing"; fi
: > "$C/unreadable.sh"
chmod 000 "$C/unreadable.sh"
if [ ! -r "$C/unreadable.sh" ]; then
  if lint_no_token "$C/unreadable.sh" 'CLAUDECODE'; then
    ok "T6: an unreadable target file trips the lint too"
  else bad "T6: an unreadable target file was read as 'no hit'"; fi
else
  echo "  SKIP T6 unreadable-file case: chmod 000 did not make the file unreadable here (running as root?)"
fi
chmod 644 "$C/unreadable.sh"

# ── T7: a TRAILING end-of-line comment is stripped too (not only a full comment LINE), and a `#`
# that is part of real parameter-expansion syntax (${VAR#pattern}, no whitespace before the `#`)
# is left alone — proven both ways on the SAME line. ──
printf '#!/usr/bin/env bash\necho hi  # CLAUDECODE is mentioned only in this trailing comment\n' \
  > "$C/trailing-comment.sh"
if lint_no_token "$C/trailing-comment.sh" 'CLAUDECODE'; then
  bad "T7: a token inside a TRAILING end-of-line comment must NOT trip the lint (false positive)"
else ok "T7: a token inside a trailing comment does not trip the lint"; fi
printf '#!/usr/bin/env bash\nx="${CLAUDECODE#prefix}"\n' > "$C/param-expansion.sh"
if lint_no_token "$C/param-expansion.sh" 'CLAUDECODE'; then
  ok "T7: a token used in \${VAR#pattern} parameter expansion still trips the lint (the # right after the name is not mistaken for a comment opener)"
else bad "T7: \${CLAUDECODE#prefix} was wrongly read as a comment and the token was missed"; fi

# ── 0f. RED (c), source lint: reviewer-preflight.sh no longer carries its own host-exclusion block —
# that is now the driver's alone (CQ14, one exclusion implementation). Comment LINES are stripped
# before matching (lint_no_token) — see T3 above for proof that this actually matters.
if lint_no_token "$PF" 'zms_is_codex_host'; then
  bad "source lint: reviewer-preflight.sh still calls zms_is_codex_host — CQ14 wants ONE exclusion implementation, the driver's, not a second one here"
else ok "source lint: no zms_is_codex_host call left in reviewer-preflight.sh"; fi
if lint_no_token "$PF" 'HOST_EXCLUDE'; then
  bad "source lint: reviewer-preflight.sh still assigns a HOST_EXCLUDE set of its own"
else ok "source lint: no hand-written HOST_EXCLUDE assignment"; fi
if lint_no_token "$PF" 'CLAUDECODE'; then
  bad "source lint: reviewer-preflight.sh still branches on CLAUDECODE itself (the driver does this now)"
else ok "source lint: no CLAUDECODE host check in reviewer-preflight.sh"; fi
if lint_no_token "$PF" 'VSCODE_GIT_ASKPASS_MAIN|ANTIGRAVITY_SESSION_ID|CURSOR_AGENT_MODEL|CURSOR_MODEL'; then
  bad "source lint: reviewer-preflight.sh still reads Antigravity/Cursor host signals itself"
else ok "source lint: no Antigravity/Cursor host-signal checks left in reviewer-preflight.sh"; fi

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
install_home_driver_no_lib
# ADV-C74: prove the flat sibling is the ONLY valid lib candidate present — without this, a passing
# `exit 0` / `provider=agy` below would be equally explained by a ~/.zuvo fallback, and the case's
# own name ("the flat sibling loaded") would be asserted by inference, not proven.
if [ ! -e "$C/home/.zuvo/model-subprocess.sh" ] && [ ! -e "$C/home/.zuvo/lib/model-subprocess.sh" ]; then
  ok "broken lib/: premise — no ~/.zuvo lib candidate exists; only the flat sibling can load"
else
  bad "broken lib/: premise — a ~/.zuvo lib candidate exists too; this case would prove nothing about the flat sibling specifically"
fi
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
expect_eq "broken lib/: exit 0 (the flat sibling loaded)" "0" "$RC"
expect_eq "broken lib/: provider=agy" "agy" "$(field provider)"
expect_has "broken lib/: stderr WARNs about the candidate that did not load" "$C/solo/lib/model-subprocess.sh" "$ERR"
contract "broken lib/"
tmp_clean "broken lib/"

new_case home-lib
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/home/.zuvo/model-subprocess.sh"
install_home_driver
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
expect_eq "~/.zuvo lib: exit 0 (the last candidate loads)" "0" "$RC"
expect_eq "~/.zuvo lib: provider=agy" "agy" "$(field provider)"
expect_not_has "~/.zuvo lib: no missing-runner error" "not loaded" "$ERR"
contract "~/.zuvo lib"
tmp_clean "~/.zuvo lib"

# T4 (fix round): a stub that merely EXISTS does not count as "the runner" — prove the REFUSAL
# path first, with NO other candidate anywhere (no flat sibling, no ~/.zuvo fallback): the broken
# lib/ candidate is the ONLY one on offer, so preflight must genuinely fail closed, exactly like
# the "no lib" case, never silently proceed.
new_case partial-lib-only
mkdir -p "$C/solo/lib"
cp "$PF" "$C/solo/reviewer-preflight.sh"
{ cat "$LIB"; printf '\nunset -f zms_run_codex\n'; } > "$C/solo/lib/model-subprocess.sh"
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
run_pf "$C/solo/reviewer-preflight.sh"
expect_eq "partial lib/ only: exit 1 (no other candidate loads)" "1" "$RC"
expect_eq "partial lib/ only: preflight_status=no-provider (fails closed)" "no-provider" "$(field preflight_status)"
expect_eq "partial lib/ only: provider=none" "none" "$(field provider)"
expect_has "partial lib/ only: stderr WARNs about the candidate missing a required function" "$C/solo/lib/model-subprocess.sh" "$ERR"
expect_not_has "partial lib/ only: the missing function never surfaces as a plain command-not-found" "command not found" "$ERR"
spy_not_ran "partial lib/ only (no client is run without a complete runner)" agy
contract "partial lib/ only"
tmp_clean "partial lib/ only"

# The SAME broken lib/ candidate, but now with a complete flat sibling available too: rejected
# with a WARN naming it, and the complete flat sibling loads instead — the fallback half of T4.
new_case partial-lib-with-fallback
mkdir -p "$C/solo/lib"
cp "$PF" "$C/solo/reviewer-preflight.sh"
{ cat "$LIB"; printf '\nunset -f zms_run_codex\n'; } > "$C/solo/lib/model-subprocess.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
install_home_driver_no_lib
# ADV-C74: same premise as broken-lib above — only the flat sibling may be a valid lib candidate.
if [ ! -e "$C/home/.zuvo/model-subprocess.sh" ] && [ ! -e "$C/home/.zuvo/lib/model-subprocess.sh" ]; then
  ok "partial lib/: premise — no ~/.zuvo lib candidate exists; only the flat sibling can load"
else
  bad "partial lib/: premise — a ~/.zuvo lib candidate exists too; this case would prove nothing about the flat sibling specifically"
fi
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
expect_has "partial lib/: stderr WARNs about the candidate missing a required function" "$C/solo/lib/model-subprocess.sh" "$ERR"
expect_not_has "partial lib/: the missing function never surfaces as a plain command-not-found" "command not found" "$ERR"
expect_eq "partial lib/: exit 0 (the complete flat sibling loaded)" "0" "$RC"
expect_eq "partial lib/: provider=agy" "agy" "$(field provider)"
contract "partial lib/"
tmp_clean "partial lib/"

# The script's directory is resolved PHYSICALLY, like the driver's and the router's. Invoked as
# <link>/../scripts/reviewer-preflight.sh where <link> is a symlink to real/scripts, bash (the kernel)
# opens real/scripts/reviewer-preflight.sh — but a LOGICAL `cd` folds `<link>/..` lexically into the
# case dir and lands in <case>/scripts, a directory this file is not in, whose lib/ it then SOURCED.
new_case symlinked-dir
mkdir -p "$C/real/scripts/lib" "$C/scripts/lib"
cp "$PF" "$C/real/scripts/reviewer-preflight.sh"
cp "$LIB" "$C/real/scripts/lib/model-subprocess.sh"
install_home_driver
ln -s "$C/real/scripts" "$C/link"
{ cat "$LIB"; printf '\n: > "%s/wrong-dir-lib-sourced"\n' "$C"; } > "$C/scripts/lib/model-subprocess.sh"
spy "$C/bin" agy
printf '42\n' > "$C/spy/agy.reply"
if [ "$C/link/../scripts/reviewer-preflight.sh" -ef "$C/real/scripts/reviewer-preflight.sh" ] \
   && [ ! -e "$C/scripts/reviewer-preflight.sh" ]; then
  ok "symlinked dir: premise — <link>/../scripts/reviewer-preflight.sh IS real/scripts/reviewer-preflight.sh, and <case>/scripts holds no preflight"
else bad "symlinked dir: premise — the path does not resolve to real/scripts (the case would prove nothing)"; fi
run_pf "$C/link/../scripts/reviewer-preflight.sh"
if [ -e "$C/wrong-dir-lib-sourced" ]; then
  bad "symlinked dir: preflight SOURCED <case>/scripts/lib/model-subprocess.sh — its directory was folded lexically, not resolved"
else ok "symlinked dir: the lib/ of the lexically-folded <case>/scripts was NOT sourced"; fi
expect_eq "symlinked dir: exit 0 (its own sibling lib/ loaded)" "0" "$RC"
expect_eq "symlinked dir: provider=agy" "agy" "$(field provider)"
expect_not_has "symlinked dir: no missing-runner error" "not loaded" "$ERR"
contract "symlinked dir"
tmp_clean "symlinked dir"

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
# script accepts would fail every codex/claude canary as "could not start". Accepted is not enough,
# though: read as OCTAL (`$((030))`) it is 24 — and 08 is no octal number at all. So the budget GNU
# timeout receives is read from a recording stand-in on the case PATH (it logs its argv, then execs the
# real one), under both names the runner may pick.
# to_rec <label> <want seconds> — the canary's `timeout -k <grace> <secs> <codex> …` call (the runner's;
# preflight's own 5 s bound on the router goes through the same recorder) carried <want seconds>.
to_rec() {
  local got
  got="$(awk -v b="$C/off/codex" '$1 == "-k" && $4 == b { print $3; exit }' "$C/to.args" 2>/dev/null)"
  expect_eq "$1: GNU timeout got the canary a budget of $2 seconds" "$2" "$got"
}
rec_timeout_shim() { # rec_timeout_shim — the case's timeout/gtimeout links replaced by the recorder
  local t
  for t in timeout gtimeout; do
    [ -e "$T/tools/$t" ] || continue
    rm -f "$C/bin/$t"
    # shellcheck disable=SC2016  # the recorder's own "$@"
    printf '#!/bin/sh\necho "$@" >> "%s/to.args"\nexec "%s" "$@"\n' "$C" "$T/tools/$t" > "$C/bin/$t"
    chmod +x "$C/bin/$t"
  done
}
for _z in 030:30 08:8; do
  _v="${_z%%:*}"; _want="${_z#*:}"
  new_case "timeout-leading-zero-$_v"
  rec_timeout_shim
  spy "$C/off" codex
  run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 ZUVO_PREFLIGHT_TIMEOUT="$_v"
  spy_ran "ZUVO_PREFLIGHT_TIMEOUT=$_v" codex
  expect_eq "ZUVO_PREFLIGHT_TIMEOUT=$_v: exit 0" "0" "$RC"
  expect_eq "ZUVO_PREFLIGHT_TIMEOUT=$_v: provider=codex" "codex" "$(field provider)"
  to_rec "ZUVO_PREFLIGHT_TIMEOUT=$_v" "$_want"
  contract "ZUVO_PREFLIGHT_TIMEOUT=$_v"
  tmp_clean "ZUVO_PREFLIGHT_TIMEOUT=$_v"
done

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
expect_has "agy 42+exit 3: stderr names the exit status AND why the 42 did not count" \
  "canary agy failed: exit 3 — a 42 from a client that failed does not count" "$ERR"
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
expect_has "codex 42+exit 3: stderr names the exit status AND why the 42 did not count" \
  "canary codex failed: exit 3 — a 42 from a client that failed does not count" "$ERR"
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
reply_case reply-star '*42*' 0 "single-star emphasis is trimmed"
reply_case reply-underscore '_42_' 0 "underscore emphasis is trimmed"
reply_case reply-backtick '`42`' 0 "inline-code backticks are trimmed"

# ── 15. neutral canaries: stdin is /dev/null, never the caller's ─────────────
# Under GNU timeout the client leads its own process group: reading an inherited TERMINAL it gets SIGTTIN
# and stalls until the budget ends; reading an inherited pipe it takes the caller's input as its own.
# cursor-agent is not on the driver's blind-audit isolation allowlist (bap_allowlist) — it can never be
# a candidate any more (see the "cursor-agent/gemini not isolated" cases below) — so it is not in this
# loop; agy and kimi both still are.
printf 'CALLER-STDIN\n' > "$T/caller-stdin"
for _cl in agy kimi; do
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

# gemini (and cursor-agent) are not on the driver's blind-audit isolation allowlist (bap_allowlist)
# — the driver's --list-providers --mode blind-audit never includes them, so they can never be a
# candidate here, no matter what ZUVO_REVIEW_TEST_PROVIDERS asks for. Their old canary bodies (still
# defined in reviewer-preflight.sh, for defense in depth) are unreachable via normal candidate
# sourcing — proven here rather than deleted. ADV-C72: the assertions below are hardcoded (spy_not_ran
# / expect_eq), so the day the allowlist changes to include one of them, this case correctly goes RED
# (alerting the maintainer) — not silently green — because the spy would then actually be invoked.
# This also pins RED (d)'s sibling: exclusion happens ONCE, in the driver, never in a second list
# this script keeps for itself.
for _cl in gemini cursor-agent; do
  new_case "$_cl-not-isolated"
  spy "$C/bin" "$_cl"
  run_pf "$PF" ZUVO_REVIEW_TEST_PROVIDERS="$_cl" SPY_REPLY=42
  spy_not_ran "$_cl not isolated (bap_allowlist excludes it; no duplicate exclusion list here)" "$_cl"
  expect_eq "$_cl not isolated: exit 1" "1" "$RC"
  expect_eq "$_cl not isolated: preflight_status=no-provider" "no-provider" "$(field preflight_status)"
  expect_eq "$_cl not isolated: provider=none" "none" "$(field provider)"
  contract "$_cl not isolated"
  tmp_clean "$_cl not isolated"
done

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
for _cl in agy kimi cursor-agent gemini; do spy "$C/bin" "$_cl"; done
# cursor-agent and gemini are named in ZUVO_REVIEW_TEST_PROVIDERS too, to prove they are dropped by
# the driver's isolation allowlist BEFORE reaching the canary loop at all — no "GNU timeout required"
# line for them, because they are never candidates in the first place (RED (a): no duplicate
# exclusion list here that could disagree with the driver about which lanes are isolated).
run_pf "$PF" PATH="$C/bin:$C/sys" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_REPLY=42 \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy kimi cursor-agent gemini"
expect_eq "no timeout: exit 1" "1" "$RC"
expect_eq "no timeout: preflight_status=canary-failed (never a silent pass)" "canary-failed" "$(field preflight_status)"
expect_eq "no timeout: provider names the first candidate" "codex" "$(field provider)"
for _cl in codex claude agy kimi; do
  expect_has "no timeout: stderr says why the $_cl canary did not run" "canary $_cl not run: GNU timeout required" "$ERR"
  spy_not_ran "no timeout ($_cl is never run unbounded)" "$_cl"
done
for _cl in cursor-agent gemini; do
  expect_not_has "no timeout: $_cl is not isolated — no canary attempt at all, not even a skipped one" \
    "canary $_cl" "$ERR"
  spy_not_ran "no timeout ($_cl was never a candidate)" "$_cl"
done
contract "no timeout"
tmp_clean "no timeout"

# ── 18. invalid ZUVO_PREFLIGHT_TIMEOUT — reject non-numeric/zero/negative, accept very-long ──
# scripts/reviewer-preflight.sh:124-133. The regex `^[0-9]+$` rejects anything with a non-digit
# (including a leading `-`) BEFORE the leading-zero strip ever runs; an all-zero value passes the
# regex but strips to empty and is rejected there instead, with the message carrying the ORIGINAL
# given value, not the stripped one. Both exits print `Invalid ZUVO_PREFLIGHT_TIMEOUT: <value>` and
# exit 2 — read directly off the script, not assumed. These all exit before any driver/candidate
# lookup, so no spy or siblings are needed.
for _t in abc:2 0:2 000:2 -5:2; do
  _val="${_t%%:*}"; _want_rc="${_t#*:}"
  new_case "timeout-invalid-$_val"
  run_pf "$PF" ZUVO_PREFLIGHT_TIMEOUT="$_val"
  expect_eq "ZUVO_PREFLIGHT_TIMEOUT=[$_val]: exit $_want_rc" "$_want_rc" "$RC"
  expect_has "ZUVO_PREFLIGHT_TIMEOUT=[$_val]: exact message, original value" \
    "Invalid ZUVO_PREFLIGHT_TIMEOUT: $_val" "$ERR"
  tmp_clean "ZUVO_PREFLIGHT_TIMEOUT=[$_val]"
done

# Unset (the documented default) must NOT hit this path at all: no "Invalid" message, normal exit.
new_case timeout-unset-default
spy "$C/bin" agy
run_pf "$PF" --no-canary ZUVO_PREFLIGHT_TIMEOUT=
expect_eq "ZUVO_PREFLIGHT_TIMEOUT= (empty/unset): exit 0" "0" "$RC"
expect_not_has "ZUVO_PREFLIGHT_TIMEOUT= (empty/unset): no Invalid message" "Invalid ZUVO_PREFLIGHT_TIMEOUT" "$ERR"
tmp_clean "timeout-unset-default"

# A very-long all-digit value has NO upper bound anywhere in lines 124-133: accepted unchanged, not
# rejected and not clamped to the 60s default — production finding territory if this were ever found
# to error or silently fall back, so pin the actual behavior: it reaches normal operation.
new_case timeout-very-long
_long="$(printf '%040d' 0 | tr '0' '9')"
spy "$C/bin" agy
run_pf "$PF" --no-canary ZUVO_PREFLIGHT_TIMEOUT="$_long"
expect_eq "ZUVO_PREFLIGHT_TIMEOUT=<40 nines>: exit 0 (accepted, not rejected)" "0" "$RC"
expect_not_has "ZUVO_PREFLIGHT_TIMEOUT=<40 nines>: no Invalid message" "Invalid ZUVO_PREFLIGHT_TIMEOUT" "$ERR"
expect_eq "ZUVO_PREFLIGHT_TIMEOUT=<40 nines>: provider=agy" "agy" "$(field provider)"
spy_not_ran "ZUVO_PREFLIGHT_TIMEOUT=<40 nines>" agy
contract "ZUVO_PREFLIGHT_TIMEOUT=<40 nines>"
tmp_clean "ZUVO_PREFLIGHT_TIMEOUT=<40 nines>"

# ADV-C61: timeout-unset-default and timeout-very-long above both pass --no-canary, so the
# accepted value is validated (regex + leading-zero strip) but never actually CONSUMED by a real
# canary/`timeout <N>` invocation — a pathological value could still break the real `timeout`
# binary's own argument parsing downstream and nothing above would catch it. This case (canary
# ENABLED, a large-but-realistic value) proves a real canary actually runs successfully with an
# accepted ZUVO_PREFLIGHT_TIMEOUT; the 40-nines case above intentionally tests validation only,
# not real `timeout` consumption — deliberately, not an oversight.
new_case timeout-realistic-large-canary-runs
spy "$C/bin" agy
run_pf "$PF" ZUVO_PREFLIGHT_TIMEOUT=3600 SPY_REPLY=42
expect_eq "ZUVO_PREFLIGHT_TIMEOUT=3600: exit 0 (canary actually ran and answered)" "0" "$RC"
expect_eq "ZUVO_PREFLIGHT_TIMEOUT=3600: provider=agy" "agy" "$(field provider)"
spy_ran "ZUVO_PREFLIGHT_TIMEOUT=3600 (canary consumed the accepted timeout value)" agy
contract "ZUVO_PREFLIGHT_TIMEOUT=3600"
tmp_clean "ZUVO_PREFLIGHT_TIMEOUT=3600"

# ── 19. -h/--help: prints the header comment to stdout, exit 0, no canary ──────
# scripts/reviewer-preflight.sh:112-115. The whole leading comment block (shebang line skipped,
# stops at the first non-# line, "# " stripped) goes to STDOUT via a bare `awk … "$0"` — no
# redirection, so it is NOT the diagnostics stream the header's own "Output" section reserves for
# canary failures. Exits 0 before any routing/candidate/canary work, so nothing on stderr and no
# client is ever run — asserted against a real spy on PATH, not a vacuous "never planted" check.
for _h in -h --help; do
  new_case "help-$_h"
  spy "$C/bin" agy
  run_pf "$PF" "$_h"
  expect_eq "$_h: exit 0" "0" "$RC"
  expect_has "$_h: stdout carries the script's own description" \
    "cheap canary for the write-tests review infrastructure" "$OUT"
  expect_has "$_h: stdout carries the documented exit-code section" "Exit codes:" "$OUT"
  expect_eq "$_h: nothing on stderr (usage is not the diagnostics stream)" "" "$ERR"
  spy_not_ran "$_h" agy
  tmp_clean "$_h"
done

# ── 20. unknown argument: exact exit code and message on stderr, no canary ─────
# scripts/reviewer-preflight.sh:116-118 — the `*)` case arm. Exits 2 before any routing/candidate
# work, with nothing on stdout (the success-path contract never starts) and the exact message on
# stderr, naming the argument it did not recognise.
new_case unknown-arg
spy "$C/bin" agy
run_pf "$PF" --bogus
expect_eq "unknown arg: exit 2" "2" "$RC"
expect_eq "unknown arg: stdout is empty (the success-path contract never starts)" "" "$OUT"
expect_has "unknown arg: stderr names the exact argument" "Unknown argument: --bogus" "$ERR"
spy_not_ran "unknown arg" agy
tmp_clean "unknown-arg"

# ── 21. SUCCESS verdict: preflight_status=ok, exit 0 — the full output block ───
# scripts/reviewer-preflight.sh:528-529. Every OTHER case in this file runs under `env -i`, which
# clears every host signal reviewer-model-route.sh reads, so ROUTING_STATUS never resolves to
# anything but "routing-failed" and this arm of the verdict `case` is never reached anywhere in
# the repo. CLAUDE_MODEL=sonnet is the ONE additional signal that makes the router answer
# platform=claude / routing_status=ok (verified directly against reviewer-model-route.sh's own
# case table — sonnet is the "strong_alt" writer lane, reviewed by opus on review-primary);
# combined with a spy canary that actually answers, BOTH halves of "ok" — reachable routing AND a
# working reviewer — are genuinely exercised together, not assumed from reading the router alone.
new_case success-ok
spy "$C/bin" agy
run_pf "$PF" CLAUDE_MODEL=sonnet SPY_REPLY=42
_want_ok="preflight_status=ok
provider=agy
platform=claude
writer_model=sonnet
writer_lane=strong_alt
reviewer_lane=review-primary
reviewer_model=opus
routing_status=ok"
expect_eq "success-ok: exit 0" "0" "$RC"
expect_eq "success-ok: the full 8-line ok output block, exact" "$_want_ok" "$OUT"
spy_ran "success-ok" agy
contract "success-ok"
tmp_clean "success-ok"

# ADV-C67/C68: sections 22-25 below used to fall back to the raw ambient `/usr/bin:/bin` for every
# tool besides the one being fault-injected, unlike the "no-timeout" case's own controlled
# `$C/sys` tool jail (built above specifically so mktemp/awk/timeout-absence is verified, not
# assumed). A host whose real /usr/bin differs (e.g. genuinely missing timeout/gtimeout) could
# make these four cases behave inconsistently between CI and local dev. Build ONE shared jail
# (real tools, timeout INCLUDED — these cases fault-inject mktemp/mkdir, not timeout) once, reused
# by all four, in place of the ambient PATH tail.
T_SYS="$T/sys"; mkdir -p "$T_SYS"
ln -s /usr/bin/* "$T_SYS/" 2>/dev/null
for _f in /bin/*; do
  if [ ! -e "$T_SYS/${_f##*/}" ] && [ ! -L "$T_SYS/${_f##*/}" ]; then ln -s "$_f" "$T_SYS/"; fi
done
if [ ! -e "$T_SYS/mktemp" ] || [ ! -e "$T_SYS/awk" ] || [ ! -e "$T_SYS/mkdir" ]; then
  echo "  FAIL sections 22-25: the shared tool jail is incomplete" >&2; exit 1
fi

# ── 22. panel stderr-capture mktemp fails (:283-300): DEGRADE and continue, never abort ────────
# The comment above this block is explicit: "A mktemp failure degrades to the old discard-and-
# generic-message behaviour rather than aborting preflight over a diagnostics nicety." Two cases
# prove BOTH halves of that: (22a) the happy path still reaches a real candidate and succeeds
# even though the diagnostics-file mktemp failed — the degrade cannot cost the happy path
# anything; (22b) when the driver ALSO genuinely fails, the verdict is still the same no-provider/
# exit 1 the working-mktemp case gets, just with the PLAINER message (no captured stderr line) —
# proving this is a downgrade in message QUALITY, not a different failure mode. The stand-in
# matches only the exact panel-err mktemp TEMPLATE (a literal string before mktemp ever replaces
# the X's), so it never touches the canary work-dir's own mktemp call three sections down.
FAILMK_PANELERR="$T/failmk-panelerr"; mkdir -p "$FAILMK_PANELERR"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in */zuvo-preflight-panel-err.XXXXXX) exit 1 ;; esac; done\nexec "%s" "$@"\n' \
  "$(command -v mktemp)" > "$FAILMK_PANELERR/mktemp"
chmod +x "$FAILMK_PANELERR/mktemp"

# (22a) mktemp fails, but the driver genuinely succeeds — degrade must not break the happy path.
new_case panel-err-mktemp-fails-driver-ok
spy "$C/bin" agy
run_pf "$PF" SPY_REPLY=42 "PATH=$FAILMK_PANELERR:$C/bin:$T_SYS"
expect_eq "panel-err mktemp fails (driver ok): exit 0 — the diagnostics-file failure cost nothing" "0" "$RC"
expect_eq "panel-err mktemp fails (driver ok): provider=agy (the panel listing still ran and succeeded)" "agy" "$(field provider)"
spy_ran "panel-err mktemp fails (driver ok)" agy
contract "panel-err mktemp fails (driver ok)"
tmp_clean "panel-err mktemp fails (driver ok)"

# (22b) mktemp fails AND the driver genuinely fails — same no-provider/exit 1 verdict as a normal
# driver failure, but the GENERIC message (exit code only): the driver's own stderr ("boom") was
# never captured, because the very temp file meant to hold it could not be created.
new_case panel-err-mktemp-fails-driver-fails
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
printf '#!/bin/sh\necho "boom" >&2\nexit 2\n' > "$C/solo/adversarial-review.sh"
chmod +x "$C/solo/adversarial-review.sh"
run_pf "$C/solo/reviewer-preflight.sh" "PATH=$FAILMK_PANELERR:$C/bin:$T_SYS"
expect_eq "panel-err mktemp fails (driver fails): exit 1" "1" "$RC"
expect_eq "panel-err mktemp fails (driver fails): preflight_status=no-provider" "no-provider" "$(field preflight_status)"
expect_has "panel-err mktemp fails (driver fails): the GENERIC message (exit code only)" \
  "exited 2 — the panel candidate list could not be computed" "$ERR"
expect_not_has "panel-err mktemp fails (driver fails): the driver's own stderr line is LOST (nothing captured it)" \
  "boom" "$ERR"
contract "panel-err mktemp fails (driver fails)"
tmp_clean "panel-err mktemp fails (driver fails)"
rm -f "$C/solo/adversarial-review.sh"

# ── 23. canary work-dir mktemp fails outright (:423-426): FAIL CLOSED, not a degrade ────────────
# Distinct from section 22: there is no "try anyway with less detail" here — the canary cannot
# run at all without a work dir, so this is an immediate, explicit canary-failed/exit 1 with its
# own documented message. The stand-in matches the work-dir's own template, which the panel-err
# template above does NOT — the literal string right after "zuvo-preflight" differs ("." here vs
# "-panel-err." there) — so the two stand-ins can never shadow each other.
FAILMK_WORK="$T/failmk-work"; mkdir -p "$FAILMK_WORK"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in */zuvo-preflight.XXXXXX) exit 1 ;; esac; done\nexec "%s" "$@"\n' \
  "$(command -v mktemp)" > "$FAILMK_WORK/mktemp"
chmod +x "$FAILMK_WORK/mktemp"
new_case canary-work-mktemp-fails
spy "$C/bin" agy
run_pf "$PF" "PATH=$FAILMK_WORK:$C/bin:$T_SYS"
expect_eq "canary WORK mktemp fails: exit 1" "1" "$RC"
expect_eq "canary WORK mktemp fails: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "canary WORK mktemp fails: provider=agy (the first candidate, named even though its canary never ran)" \
  "agy" "$(field provider)"
expect_has "canary WORK mktemp fails: the documented message" "cannot create a temp dir under" "$ERR"
spy_not_ran "canary WORK mktemp fails" agy
contract "canary WORK mktemp fails"
tmp_clean "canary WORK mktemp fails"

# ── 24. canary work-dir path resolution fails (:429-434): FAIL CLOSED ───────────────────────────
# `cd "$WORK" && pwd -P` fails when $WORK does not actually exist — a case `mktemp -d` itself
# cannot be made to hit directly (it either fails, covered above, or creates a real directory).
# This stand-in exercises it precisely: mktemp "succeeds" (exit 0, non-empty stdout, satisfying
# the check at :423) while printing a path to a directory it never creates, so the VERY NEXT step
# — resolving that path — is what fails, exactly as it would for a real mktemp whose directory
# vanished between creation and use.
FAILMK_GHOST="$T/failmk-ghost"; mkdir -p "$FAILMK_GHOST"
_realmktemp="$(command -v mktemp)"
cat > "$FAILMK_GHOST/mktemp" <<STUBEOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    */zuvo-preflight.XXXXXX)
      printf '%s/zuvo-preflight.GHOST000\n' "\${TMPDIR:-/tmp}"
      exit 0
      ;;
  esac
done
exec "$_realmktemp" "\$@"
STUBEOF
chmod +x "$FAILMK_GHOST/mktemp"
new_case canary-work-resolve-fails
spy "$C/bin" agy
run_pf "$PF" "PATH=$FAILMK_GHOST:$C/bin:$T_SYS"
expect_eq "canary WORK resolve fails: exit 1" "1" "$RC"
expect_eq "canary WORK resolve fails: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "canary WORK resolve fails: provider=agy" "agy" "$(field provider)"
expect_has "canary WORK resolve fails: the documented message" "cannot resolve the canary work dir" "$ERR"
expect_has "canary WORK resolve fails: names the ghost path mktemp claimed to create" "zuvo-preflight.GHOST000" "$ERR"
spy_not_ran "canary WORK resolve fails" agy
contract "canary WORK resolve fails"
tmp_clean "canary WORK resolve fails"

# ── 25. canary neutral-cwd mkdir fails (:438-441): FAIL CLOSED ──────────────────────────────────
# mktemp -d WORK and its path resolution both succeed for real here — only `mkdir -p
# "$NEUTRAL_CWD"` (always "$WORK/cwd") fails. The stand-in matches any mkdir call whose target
# ends in "/cwd", which nothing else in this script's flow ever creates.
FAILMKDIR_CWD="$T/failmkdir-cwd"; mkdir -p "$FAILMKDIR_CWD"
_realmkdir="$(command -v mkdir)"
cat > "$FAILMKDIR_CWD/mkdir" <<STUBEOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    */cwd) exit 1 ;;
  esac
done
exec "$_realmkdir" "\$@"
STUBEOF
chmod +x "$FAILMKDIR_CWD/mkdir"
new_case canary-neutral-cwd-mkdir-fails
spy "$C/bin" agy
run_pf "$PF" "PATH=$FAILMKDIR_CWD:$C/bin:$T_SYS"
expect_eq "neutral-cwd mkdir fails: exit 1" "1" "$RC"
expect_eq "neutral-cwd mkdir fails: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "neutral-cwd mkdir fails: provider=agy" "agy" "$(field provider)"
expect_has "neutral-cwd mkdir fails: the documented message" "cannot prepare the canary work dir" "$ERR"
spy_not_ran "neutral-cwd mkdir fails" agy
contract "neutral-cwd mkdir fails"
tmp_clean "neutral-cwd mkdir fails"

# ── 26. --canary: a documented no-op flag (CANARY already defaults to 1) ────────────────────────
# scripts/reviewer-preflight.sh:111 — no test anywhere invoked it. It must be ACCEPTED (never fall
# into the `*` unknown-argument arm) and produce the EXACT SAME outcome as omitting it entirely.
new_case explicit-canary-flag
spy "$C/bin" agy
run_pf "$PF" --canary SPY_REPLY=42
expect_eq "--canary: exit 0 (same as the default)" "0" "$RC"
expect_eq "--canary: provider=agy (canary ran and answered, same as the default)" "agy" "$(field provider)"
expect_not_has "--canary: not treated as an unknown argument" "Unknown argument" "$ERR"
spy_ran "--canary" agy
contract "--canary"
tmp_clean "--canary"

echo "=== RESULT ==="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
