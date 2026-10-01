#!/usr/bin/env bash
#
# test-reviewer-preflight-isolation.sh — scripts/reviewer-preflight.sh's canaries must run isolated
# and must COMPUTE an answer (plan A, Task 7; coverage rows X2 / K1 / X3).
#
# Test level: MEDIUM. Real subprocesses (the spy-cli fixture, the driver, the router), real temp
# dirs and wall-clock timeout bounds — never a real model CLI and never the network; every client
# this suite exercises is a spy standing in for codex/claude/agy/etc.
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
ROUTE_MODEL_SCRIPT="$ROOT/scripts/reviewer-model-route.sh"
# ok / bad / expect_eq / expect_has / expect_not_has / re_lit / kv_field / assert_result
# shellcheck source=tests/lib/assert.sh
. "$ROOT/tests/lib/assert.sh"
# under <dir> <path> — true when <path> is <dir> or below it.
under() { case "$2" in "$1"|"$1"/*) return 0 ;; esac; return 1; }
poll() { local n=$(( $1 * 2 )) i=0; shift; until "$@"; do [ "$i" -lt "$n" ] || return 1; sleep 0.5; i=$((i+1)); done; }
# no_proc_re <ERE> — true ONLY when pgrep ran and no command line matches <ERE> (fails closed without
# pgrep); no_proc <text> — the same for a LITERAL text anywhere in a command line.
no_proc_re() { command -v pgrep >/dev/null 2>&1 || return 1; pgrep -f "$1" >/dev/null 2>&1; [ $? -eq 1 ]; }
no_proc() { no_proc_re "$(re_lit "$1")"; }

echo "== reviewer-preflight canary isolation (bash $BASH_VERSION) =="

for _f in "$PF" "$LIB" "$DRIVER" "$BAP" "$SPY_SRC" "$FIX_SRC/auth.json" "$FIX_SRC/config.toml" "$REGISTRY" "$ROUTE_MODEL_SCRIPT"; do
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

C=""; RC=""; OUT=""; ERR=""; CT=""; PF_STDIN=""; PF_BOUND=""
# new_case <name> — a fresh case dir: bin (tool symlinks only), off (spies NOT on PATH), spy, home, tmp.
# PF_STDIN (preflight's stdin, /dev/null when empty) is reset for every case.
new_case() {
  C="$T/$1"; PF_STDIN=""; PF_BOUND=""
  mkdir -p "$C/bin" "$C/off" "$C/spy" "$C/home/.zuvo" "$C/tmp" || exit 1
  local t
  for t in timeout gtimeout jq; do
    if [ -e "$T/tools/$t" ]; then ln -s "$T/tools/$t" "$C/bin/$t"; fi
  done
  CT="$(cd "$C/tmp" && pwd -P)"
  echo "-- $1"
}
# sys_farm_without_timeout — for the current case: $C/sys links every /usr/bin and /bin tool EXCEPT
# timeout/gtimeout (a Linux /usr/bin has timeout), and $C/bin loses its own timeout links, so
# PATH="$C/bin:$C/sys" is a whole system with no GNU timeout on it. A timeout that still resolves, or a
# farm missing basic tools, ends the suite: every case built on it would prove nothing.
sys_farm_without_timeout() {
  local _f _to
  rm -f "$C/bin/timeout" "$C/bin/gtimeout"
  mkdir -p "$C/sys" || exit 1
  ln -s /usr/bin/* "$C/sys/" 2>/dev/null
  for _f in /bin/*; do
    if [ ! -e "$C/sys/${_f##*/}" ] && [ ! -L "$C/sys/${_f##*/}" ]; then ln -s "$_f" "$C/sys/"; fi
  done
  rm -f "$C/sys/timeout" "$C/sys/gtimeout"
  _to="$(PATH="$C/bin:$C/sys" type -P timeout gtimeout 2>/dev/null || true)"
  [ -z "$_to" ] || { echo "  FAIL ${C##*/}: a timeout still resolves on the case PATH ($_to)" >&2; exit 1; }
  if [ ! -e "$C/sys/mktemp" ] || [ ! -e "$C/sys/awk" ] || [ ! -e "$C/sys/sleep" ] || [ ! -e "$C/sys/ps" ]; then
    echo "  FAIL ${C##*/}: the tool farm is incomplete" >&2; exit 1
  fi
}
# spy <dir> <client-name> — the spy under the client's name (the name picks its record file).
spy() { ln -s "$SPY" "$1/$2"; }
# spy_counting <dir> <client-name> <counter-file> — T5 (adversarial pass 3, f1-3/f1-16/f1-7
# BYTEPLUS CRITICAL): like spy(), but the installed file appends one line to <counter-file> BEFORE
# running the SAME spy-cli logic $SPY itself runs. The real spy-cli OVERWRITES its own .rec file on
# every invocation (`mv "$rec.tmp" "$rec"`), so a rec file alone cannot tell "ran once" from "ran
# twice" — exactly what a broken CANDIDATES dedup would produce. This is the only way to count
# actual invocations without editing the shared fixture. `awk 'END{print NR+0}' <counter-file>`
# after the run is the dedup proof.
#
# NOT a wrapper that execs a SEPARATE spy-cli file: `exec [-a name] "$SPY" "$@"` cannot preserve
# the client name here — spy-cli is itself a shebang script, and the kernel's shebang handling
# re-execs the interpreter with argv[1] bound to the PATH used to load it ($SPY, e.g. ".../spy-
# cli"), not to whatever argv[0] a caller set; the real spy-cli's own `name="${0##*/}"` would then
# read "spy-cli", not "codex", and write its record to the wrong file, leaving spy_ran/spy_not_ran
# blind (found by this file's own T5 case going unexpectedly RED against fully-fixed code — the
# wrapper's counter proved the invocation happened, but codex.rec never existed). Instead, this
# builds a STANDALONE copy of spy-cli's own body (the same construction $SPY itself uses at the
# top of this file: $SPY_SH shebang, spy-cli's content minus ITS OWN shebang line) with ONE counter-
# increment line inserted first — $0 when THIS file runs (invoked directly as "codex", never via a
# second exec) is exactly the name it was installed under, so `name="${0##*/}"` resolves correctly.
spy_counting() {
  local dir="$1" name="$2" counter="$3"
  : > "$counter" || return 1
  {
    printf '#!%s\n' "${SPY_SH:-/bin/sh}"
    printf 'printf '"'"'x\\n'"'"' >> %s\n' "$(printf '%q' "$counter")"
    tail -n +2 "$SPY_SRC"
  } > "$dir/$name" || return 1
  chmod +x "$dir/$name" || return 1
}
# run_pf <preflight-script> [VAR=value | preflight-arg ...] — one hermetic preflight run, started from
# the REPO ROOT (so "the canary ran in the caller's cwd" is observable), stdin from $PF_STDIN (default
# /dev/null). A VAR=value given here comes after the defaults, so it overrides them (PATH included).
# PF_BOUND=<secs> (one case only) runs preflight itself under an OUTER GNU timeout: a preflight that
# waited on something it should not have is then killed, and RC reads 124/137 — a mechanism, not a
# wall-clock window. Sets RC, OUT, ERR. No elapsed time is measured: a bound is proven by what it did
# (the status, the "timed out" diagnostic, the killed process), which a loaded host cannot turn red.
run_pf() {
  local script="$1" a bound=()
  shift
  local envs=() args=()
  for a in "$@"; do case "$a" in *=*) envs+=("$a") ;; *) args+=("$a") ;; esac; done
  if [ -n "$PF_BOUND" ]; then
    a="$T/tools/timeout"; [ -e "$a" ] || a="$T/tools/gtimeout"
    bound=("$a" -k 2 "$PF_BOUND")
  fi
  ( cd "$ROOT" && ${bound[@]+"${bound[@]}"} env -i HOME="$C/home" ZUVO_HOME="$C/home/.zuvo" TMPDIR="$C/tmp" CODEX_HOME="$FIX" \
      ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_CODEX_BIN=/nonexistent ZUVO_CLAUDE_BIN=/nonexistent \
      PATH="$C/bin:/usr/bin:/bin" SPY_DIR="$C/spy" \
      ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude agy" \
      ZUVO_PREFLIGHT_TIMEOUT=30 ZUVO_TIMEOUT_GRACE=2 ZUVO_PROVIDER_HEALTH_FILE="$C/health.tsv" \
      ${envs[@]+"${envs[@]}"} "$BASH" "$script" ${args[@]+"${args[@]}"} \
      < "${PF_STDIN:-/dev/null}" > "$C/out" 2> "$C/err" )
  RC=$?
  OUT="$(cat "$C/out")"; ERR="$(cat "$C/err")"
}
field() { kv_field "$1" "$OUT"; }
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
# P2-138: and every CALLER gates the rest of its case on that status (`if install_home_driver; then
# … else SKIP … fi`) — a bare call let a half-installed ~/.zuvo run straight into run_pf and the
# case's own assertions, burying the one real cause under a cascade of unrelated-looking FAILs.
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
# P2-141: blind-audit-panel.sh goes FLAT (~/.zuvo/blind-audit-panel.sh) on purpose, not beside the
# driver's ~/.zuvo/lib/ as install_home_driver puts it: the driver finds it there all the same (its
# `<dir>/blind-audit-panel.sh` candidate), and ~/.zuvo/lib/ is then never even created — so nothing
# under it can ever pose as a lib candidate in the cases that must prove there is none.
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

# ── P2-39: a BARE codex-5 lane id (no minor tier) is still the one codex CLI — the old `codex-5.*`
# glob needed a literal `.`, so it fell through unmapped, never became a candidate and read as a
# missing provider. ──
new_case pf-map-lane-bare-codex-tier
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
cp "$REGISTRY" "$C/home/.zuvo/model-registry.sh"
printf '#!/bin/sh\nprintf "codex-5\\n"\n' > "$C/solo/adversarial-review.sh"
chmod +x "$C/solo/adversarial-review.sh"
spy "$C/off" codex
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_ECHO=1
spy_ran "bare codex tier (codex-5): pf_map_lane collapses it to the codex canary (P2-39)" codex
expect_eq "bare codex tier: exit 1 (the echoing spy answers nothing)" "1" "$RC"
contract "bare codex tier"
tmp_clean "bare codex tier"
rm -f "$C/solo/adversarial-review.sh"

# ── P2-35: only NUMERIC codex tiers collapse. A suffixed lane (a future codex-5.4-api / -alt: a
# different execution path, the way kimi-api is not the kimi CLI) must pass through under its own
# name — never borrow the codex CLI's canary and be vouched for by a client it does not run on. ──
new_case pf-map-lane-codex-suffix-distinct
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
cp "$REGISTRY" "$C/home/.zuvo/model-registry.sh"
printf '#!/bin/sh\nprintf "codex-5.4-api\\n"\n' > "$C/solo/adversarial-review.sh"
chmod +x "$C/solo/adversarial-review.sh"
spy "$C/off" codex
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_ECHO=1
spy_not_ran "suffixed codex lane (codex-5.4-api): NOT collapsed into the codex canary (P2-35)" codex
expect_eq "suffixed codex lane: exit 1 (no candidate answers to that name)" "1" "$RC"
expect_eq "suffixed codex lane: preflight_status=no-provider" "no-provider" "$(field preflight_status)"
contract "suffixed codex lane"
tmp_clean "suffixed codex lane"
rm -f "$C/solo/adversarial-review.sh"

# ── P3C-7: a tier id with MORE than one numeric segment (codex-5.4.1) is still the one codex CLI —
# P2-35/P2-39's `^codex-5(\.[0-9]+)?$` allowed at most one, so a three-part tier fell through unmapped
# where the old `codex-5.*` glob had collapsed it. Numeric segments only, any number of them. ──
new_case pf-map-lane-multi-segment-codex-tier
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
cp "$REGISTRY" "$C/home/.zuvo/model-registry.sh"
printf '#!/bin/sh\nprintf "codex-5.4.1\\n"\n' > "$C/solo/adversarial-review.sh"
chmod +x "$C/solo/adversarial-review.sh"
spy "$C/off" codex
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_ECHO=1
spy_ran "multi-segment codex tier (codex-5.4.1): pf_map_lane collapses it to the codex canary (P3C-7)" codex
expect_eq "multi-segment codex tier: exit 1 (the echoing spy answers nothing)" "1" "$RC"
contract "multi-segment codex tier"
tmp_clean "multi-segment codex tier"
rm -f "$C/solo/adversarial-review.sh"

# ── F3: the panel listing can run up to 20s — a kill during that window must not leak the
# stderr-capture temp file (zuvo-preflight-panel-err.*). The stub sleeps well past the moment we
# signal preflight directly (via `exec`, so the backgrounded PID IS the actual bash process, not a
# wrapper around it) with SIGTERM; TMPDIR is inspected only after preflight has actually exited.
# ADV-A88: the stub sleeps 30s (comfortably longer than the short poll window below, and longer
# than run_with_timeout's own 20s+5s-grace bound would take to reap an orphan on its own) so
# "the in-flight child is gone quickly" can only mean the trap explicitly killed it, never that
# it happened to finish naturally or was reaped by the unrelated 20s ceiling within the window.
# P2-133/P2-144: the stub's own 30s sleep runs as a grandchild under a DISTINCT argv — a symlink to
# the real sleep named for this case — so it can be asserted on (and, whatever the verdict, reaped)
# without matching an unrelated `sleep` elsewhere on a shared machine. ──
new_case panel-err-file-sigterm-cleanup
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
ln -s "$(command -v sleep)" "$C/solo/f3-grandchild-sleep"
cat > "$C/solo/adversarial-review.sh" <<'STUBEOF'
#!/bin/sh
"$(dirname "$0")/f3-grandchild-sleep" 30
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
# P2-133: the grandchild must be RUNNING when the signal lands, or "it is gone afterwards" below
# would pass on a sleep that never started.
# pgrep is a precondition of the whole suite (checked before any case runs), so a miss here can only
# mean "not running". The pattern is the grandchild's own argv[0], literal and anchored (P3C-8).
F3_GC_RE="^$(re_lit "$C/solo/f3-grandchild-sleep")( |\$)"
f3_grandchild_running() { pgrep -f "$F3_GC_RE" >/dev/null 2>&1; }
if poll 5 f3_grandchild_running; then
  ok "F3: premise — the listing stub's grandchild sleep is running before signaling"
else
  bad "F3: premise — the listing stub's grandchild sleep never started; the grandchild check below proves nothing"
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
# P2-133/P2-144 (was the ADV-C57 scope note): the stub's OWN sleep grandchild, not only the bash
# process running the stub — `timeout` signals its whole process group, so the grandchild must go
# with it rather than outlive preflight for up to 30s as an orphan. Asserted by the distinct argv
# above, then reaped unconditionally, so a regression here never leaves a stray process behind.
if poll 3 no_proc_re "$F3_GC_RE"; then
  ok "F3: the listing stub's grandchild sleep dies with the SIGTERM too — no orphan outlives preflight (P2-133)"
else
  bad "F3: the listing stub's grandchild sleep survived the SIGTERM — an orphan outlives preflight (P2-133)"
fi
pkill -f "$F3_GC_RE" 2>/dev/null
rm -f "$C/solo/adversarial-review.sh" "$C/solo/f3-grandchild-sleep"

# ── The panel listing's own timeout is tunable (ZUVO_PREFLIGHT_PANEL_TIMEOUT): a stub whose listing takes
# 8s is CUT by a 2s budget. Proven by the mechanism, not by elapsed time: run_with_timeout reports 124 (the
# budget fired), the stub's sleep — a distinctly named link — is gone, and the stub never reached the line
# after it (its completion marker is absent). ──
new_case panel-list-timeout-tunable
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
ln -s "$(command -v sleep)" "$C/solo/tunable-listing-sleep"
cat > "$C/solo/adversarial-review.sh" <<'STUBEOF'
#!/bin/sh
"$(dirname "$0")/tunable-listing-sleep" 8
: > "$(dirname "$0")/listing-completed"
printf 'agy\n'
STUBEOF
chmod +x "$C/solo/adversarial-review.sh"
TUNE_RE="^$(re_lit "$C/solo/tunable-listing-sleep")( |\$)"
# One timing check, a LOWER bound only: the cut may not come before the 2 s budget (a mis-scaled knob that
# fires at once would still pass every check above). Load can only lengthen a run, so it cannot turn this
# red. Measured in milliseconds: SECONDS is whole seconds, and a 1.2 s run that starts at x.9 already reads
# as 2 — only the converse holds (a >= 2 s span never reads below 2), so SECONDS cannot prove a floor.
# The clock is MONOTONIC where one exists (perl's CLOCK_MONOTONIC): a wall clock stepped by NTP mid-run
# could read a span shorter than the real one. Else bash 5's EPOCHREALTIME, used only in its documented
# shape (seconds, a '.' or ',' — the locale's radix — and a fraction); empty when neither is there. The
# source is chosen ONCE, so both ends of a span always read the same clock.
_ms_perl() { perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%d\n", clock_gettime(CLOCK_MONOTONIC) * 1000' 2>/dev/null; }
_ms_bash() {
  local t="${EPOCHREALTIME:-}"
  case "$t" in [0-9]*[.,][0-9]*) ;; *) return 0 ;; esac
  case "${t%[.,]*}${t#*[.,]}" in *[!0-9]*) return 0 ;; esac
  printf '%s%s\n' "${t%[.,]*}" "$(printf '%s000' "${t#*[.,]}" | cut -c1-3)"
}
case "$(_ms_perl)" in ""|*[!0-9]*) case "$(_ms_bash)" in ""|*[!0-9]*) _ms_src="" ;; *) _ms_src=_ms_bash ;; esac ;; *) _ms_src=_ms_perl ;; esac
now_ms() { [ -z "$_ms_src" ] || "$_ms_src"; }
_pl0="$(now_ms)"
run_pf "$C/solo/reviewer-preflight.sh" ZUVO_PREFLIGHT_PANEL_TIMEOUT=2 --no-canary
_pl1="$(now_ms)"
expect_eq "panel-list-timeout: exit 1 (no-provider — the listing itself timed out)" "1" "$RC"
case "$_pl0:$_pl1" in
  :*|*:|*[!0-9:]*) bad "panel-list-timeout: no millisecond clock (perl's CLOCK_MONOTONIC or bash 5 EPOCHREALTIME) — the lower bound is NOT RUN" ;;
  *) _plel=$((_pl1 - _pl0))
     if [ "$_plel" -ge 1950 ]; then ok "panel-list-timeout: the cut came no earlier than the 2s budget (${_plel} ms)"
     else bad "panel-list-timeout: preflight ended after ${_plel} ms — before the 2s budget could have fired"; fi ;;
esac
unset _pl0 _pl1 _plel _ms_src
# 124 is run_with_timeout's contract for "the budget fired" — GNU timeout's status here, and the status
# preflight's own watchdog reports on a PATH without it (the no-gnu-timeout case below).
expect_has "panel-list-timeout: the listing ended in run_with_timeout's 124, i.e. the budget fired" "exited 124" "$ERR"
if [ ! -e "$C/solo/listing-completed" ]; then ok "panel-list-timeout: the 8s listing never completed — it was cut, not waited out"
else bad "panel-list-timeout: the listing ran to completion — the 2s budget did not cut it"; fi
if poll 3 no_proc_re "$TUNE_RE"; then ok "panel-list-timeout: the listing's sleep was killed with it"
else bad "panel-list-timeout: the listing's sleep outlived the budget"; fi
pkill -f "$TUNE_RE" 2>/dev/null
contract "panel-list-timeout"
tmp_clean "panel-list-timeout"
rm -f "$C/solo/adversarial-review.sh" "$C/solo/tunable-listing-sleep" "$C/solo/listing-completed"

# ── P2-33: ZUVO_PREFLIGHT_PANEL_TIMEOUT must stay a BOUND. GNU timeout reads a duration of 0 as "no
# timeout at all", so `=0` (or 00) silently removed the very ceiling the knob exists to tune, and an
# arbitrarily large value did the same in practice. Validated like ZUVO_PREFLIGHT_TIMEOUT (digits,
# leading zeros dropped), then required to be 1..120: anything else is refused up front (exit 2,
# named on stderr) before any listing runs. The stub answers instantly, so a value that slipped
# through would show up as a normal exit 0, not as a timeout. ──
new_case panel-list-timeout-bounds
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
printf '#!/bin/sh\nprintf "agy\\n"\n' > "$C/solo/adversarial-review.sh"
chmod +x "$C/solo/adversarial-review.sh"
spy "$C/bin" agy
for _pt in 0 00 121 999999 abc -5; do
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_PREFLIGHT_PANEL_TIMEOUT="$_pt" --no-canary
  expect_eq "panel-list-timeout bounds: ZUVO_PREFLIGHT_PANEL_TIMEOUT=[$_pt] refused with exit 2 (P2-33)" "2" "$RC"
  expect_has "panel-list-timeout bounds: [$_pt] …named on stderr" "Invalid ZUVO_PREFLIGHT_PANEL_TIMEOUT" "$ERR"
done
for _pt in 1 020 120; do
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_PREFLIGHT_PANEL_TIMEOUT="$_pt" --no-canary
  expect_eq "panel-list-timeout bounds: ZUVO_PREFLIGHT_PANEL_TIMEOUT=[$_pt] accepted (exit 0)" "0" "$RC"
  expect_eq "panel-list-timeout bounds: [$_pt] …provider=agy" "agy" "$(field provider)"
done
contract "panel-list-timeout bounds"
tmp_clean "panel-list-timeout bounds"
rm -f "$C/solo/adversarial-review.sh"

# ── P3C-2: NO GNU timeout on PATH (stock macOS ships none) and the panel listing HANGS. run_with_timeout
# used to run the listing as-is there — unbounded, so a wedged driver hung preflight. It must be cut at
# the budget by preflight's own watchdog, end in the same 124, and leave nothing running. The stub's
# sleep is a GRANDCHILD under a distinct argv (the F3 technique): a grandchild the watchdog missed
# would hold the `$(...)` pipe open, and the "bound" would then be the stub's own 20s. ──
new_case panel-list-timeout-no-gnu-timeout
sys_farm_without_timeout
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
ln -s "$(command -v sleep)" "$C/solo/p3c2-grandchild-sleep"
cat > "$C/solo/adversarial-review.sh" <<'STUBEOF'
#!/bin/sh
"$(dirname "$0")/p3c2-grandchild-sleep" 20
: > "$(dirname "$0")/listing-completed"
printf 'agy\n'
STUBEOF
chmod +x "$C/solo/adversarial-review.sh"
spy "$C/bin" agy
P3C2_GC_RE="^$(re_lit "$C/solo/p3c2-grandchild-sleep")( |\$)"
run_pf "$C/solo/reviewer-preflight.sh" PATH="$C/bin:$C/sys" ZUVO_PREFLIGHT_PANEL_TIMEOUT=2 --no-canary
if [ ! -e "$C/solo/listing-completed" ]; then ok "no GNU timeout: the 20s listing never completed — preflight's own watchdog cut it"
else bad "no GNU timeout: the listing ran to completion — it was not bounded"; fi
expect_eq "no GNU timeout: exit 1 (no-provider — the listing itself timed out) (P3C-2)" "1" "$RC"
expect_eq "no GNU timeout: preflight_status=no-provider (P3C-2)" "no-provider" "$(field preflight_status)"
expect_has "no GNU timeout: the watchdog reports GNU timeout's own 124 (P3C-2/P3C-9)" "exited 124" "$ERR"
expect_has "no GNU timeout: …and says the bound was its own, and why (P3C-2)" "own watchdog (no GNU timeout on PATH" "$ERR"
if poll 3 no_proc_re "$P3C2_GC_RE"; then
  ok "no GNU timeout: the listing's grandchild was taken down with it — nothing outlives preflight (P3C-2)"
else
  bad "no GNU timeout: the listing's grandchild sleep survived the watchdog (P3C-2)"
fi
pkill -f "$P3C2_GC_RE" 2>/dev/null
contract "no GNU timeout, hung listing"
tmp_clean "no GNU timeout, hung listing"
rm -f "$C/solo/adversarial-review.sh" "$C/solo/p3c2-grandchild-sleep" "$C/solo/listing-completed"

# …and when the listing answers at once, the watchdog goes with it: no sleep of the budget's length is
# left idling (the budget is an odd 117s, so its sleep is recognisable by its exact argv).
new_case panel-list-no-gnu-timeout-watchdog-reaped
sys_farm_without_timeout
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
printf '#!/bin/sh\nprintf "agy\\n"\n' > "$C/solo/adversarial-review.sh"
chmod +x "$C/solo/adversarial-review.sh"
spy "$C/bin" agy
# Preflight itself runs under an outer 30s bound: had it waited out its own 117s watchdog, it would be
# killed there and RC would read 124/137 instead of 0.
PF_BOUND=30
run_pf "$C/solo/reviewer-preflight.sh" PATH="$C/bin:$C/sys" ZUVO_PREFLIGHT_PANEL_TIMEOUT=117 --no-canary
expect_eq "no GNU timeout, fast listing: exit 0 — not killed by the outer bound, so it never waited on its watchdog" "0" "$RC"
expect_eq "no GNU timeout, fast listing: provider=agy" "agy" "$(field provider)"
if poll 3 no_proc_re '^sleep 117$'; then
  ok "no GNU timeout, fast listing: the watchdog's 117s sleep was taken down with it (P3C-2)"
else
  bad "no GNU timeout, fast listing: a 'sleep 117' outlives preflight — the watchdog's sleep was orphaned (P3C-2)"
fi
contract "no GNU timeout, fast listing"
tmp_clean "no GNU timeout, fast listing"
rm -f "$C/solo/adversarial-review.sh"

# ── 0e. driver lookup: SCRIPT_DIR has no adversarial-review.sh sibling — the ~/.zuvo/adversarial-review
# fallback (no `.sh`, matching scripts/install.sh's rename) is found and used ──
new_case driver-home-fallback
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/solo/model-subprocess.sh"
if install_home_driver; then
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "driver ~/.zuvo fallback: exit 0 (~/.zuvo/adversarial-review, no .sh, was found)" "0" "$RC"
  expect_eq "driver ~/.zuvo fallback: provider=agy" "agy" "$(field provider)"
  contract "driver ~/.zuvo fallback"
  tmp_clean "driver ~/.zuvo fallback"
else
  echo "  SKIP driver ~/.zuvo fallback: the rest of this case — install_home_driver failed above, so nothing below could be about what this case tests (P2-138)"
fi

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

# ── 0f. RED (c), source lint: reviewer-preflight.sh carries no host-exclusion logic of its own for
# the PANEL/CANDIDATES list — that stays the driver's alone (CQ14, one exclusion implementation).
# Comment LINES are stripped before matching (lint_no_token) — see T3 above for proof that this
# actually matters.
#
# Since adversarial pass 2 (S1), CLAUDECODE / zms_is_codex_host are legitimately used ONCE,
# narrowly, by the routed-client same-vendor guard in section 1a of reviewer-preflight.sh — a
# check on ROUTED_CLIENT (a value the ROUTER produced), never a second exclusion pass over the
# panel. So the lint no longer bans those two tokens from the WHOLE file — it bans them from
# section 2 onward (panel listing, candidate building, the canary loop, the verdict), which is
# where a reintroduced PANEL-exclusion implementation would actually live; that is CQ14's real
# invariant, and it is unchanged. HOST_EXCLUDE and the Antigravity/Cursor signals stay banned
# EVERYWHERE: Task 6's same-vendor guard only ever concerns claude/codex (cross-vendor routing
# never targets a third vendor), so this script has no legitimate reason to read any of those,
# anywhere.
_pf_lint_slice="$C/pf-section2-onward.sh"
awk '/── 2\. audit client availability/{f=1} f' "$PF" > "$_pf_lint_slice"
if [ ! -s "$_pf_lint_slice" ]; then
  echo "  FAIL source lint: could not extract reviewer-preflight.sh's section 2 (marker not found) — the two slice-scoped checks below would pass vacuously" >&2
  # T13 (adversarial pass 3, f2-5): removed on EVERY path, including this early exit — the earlier
  # version left this temp file behind here, the one path that did not reach the rm -f below.
  rm -f "$_pf_lint_slice"
  exit 1
fi
if lint_no_token "$_pf_lint_slice" 'zms_is_codex_host'; then
  bad "source lint: reviewer-preflight.sh's section 2 onward (panel/candidates/canary/verdict) still calls zms_is_codex_host — CQ14 wants ONE exclusion implementation for the PANEL, the driver's; section 1a's routed-client same-vendor guard is the only legitimate caller, and it lives earlier in the file"
else ok "source lint: no zms_is_codex_host call in reviewer-preflight.sh's panel/candidate/canary/verdict code (section 2 onward)"; fi
if lint_no_token "$PF" 'HOST_EXCLUDE'; then
  bad "source lint: reviewer-preflight.sh still assigns a HOST_EXCLUDE set of its own"
else ok "source lint: no hand-written HOST_EXCLUDE assignment"; fi
if lint_no_token "$_pf_lint_slice" 'CLAUDECODE'; then
  bad "source lint: reviewer-preflight.sh's section 2 onward (panel/candidates/canary/verdict) still branches on CLAUDECODE — section 1a's routed-client same-vendor guard is the only legitimate caller, and it lives earlier in the file"
else ok "source lint: no CLAUDECODE check in reviewer-preflight.sh's panel/candidate/canary/verdict code (section 2 onward)"; fi
if lint_no_token "$PF" 'VSCODE_GIT_ASKPASS_MAIN|ANTIGRAVITY_SESSION_ID|CURSOR_AGENT_MODEL|CURSOR_MODEL'; then
  bad "source lint: reviewer-preflight.sh still reads Antigravity/Cursor host signals itself"
else ok "source lint: no Antigravity/Cursor host-signal checks left in reviewer-preflight.sh"; fi
rm -f "$_pf_lint_slice"
unset _pf_lint_slice

# ── 0f2. ONE runner-lib candidate order. A script cannot call a function from a library it has not found
# yet, so each consumer carries the tiny `zms-locate` bootstrap — and all four carry the SAME one, byte
# for byte (the copies used to differ: model-run alone looked in <repo>/scripts/lib/).
new_case one-locator
_loc_ref=""; _loc_ref_src=""
for _src in "$PF" "$ROUTE_MODEL_SCRIPT" "$ROOT/scripts/zuvo-home/model-run" "$DRIVER"; do
  _n="$(awk '/^# zms-locate:begin/ { n++ } END { print n + 0 }' "$_src")"
  expect_eq "one locator: ${_src#"$ROOT"/} carries exactly one zms-locate block" 1 "$_n"
  _blk="$(awk '/^# zms-locate:begin/ { f = 1 } f { print } /^# zms-locate:end/ { f = 0 }' "$_src")"
  if [ -z "$_loc_ref_src" ]; then _loc_ref="$_blk"; _loc_ref_src="${_src#"$ROOT"/}"; continue; fi
  if [ -n "$_blk" ] && [ "$_blk" = "$_loc_ref" ]; then ok "one locator: ${_src#"$ROOT"/} is byte-identical to $_loc_ref_src"
  else bad "one locator: ${_src#"$ROOT"/} differs from $_loc_ref_src"; fi
done
case "$_loc_ref" in
  *'"$_zms_dir/lib/model-subprocess.sh" "$_zms_dir/model-subprocess.sh"'*'"$_zms_repo/scripts/lib/model-subprocess.sh"'*'"$HOME/.zuvo/model-subprocess.sh"'*)
    ok "one locator: the order is <dir>/lib → <dir> → <repo>/scripts/lib → ~/.zuvo" ;;
  *) bad "one locator: the candidate order is not <dir>/lib → <dir> → <repo>/scripts/lib → ~/.zuvo" ;;
esac
unset _src _n _blk _loc_ref _loc_ref_src

# ── 0g. ONE model-id predicate. The reviewer-id charset ([A-Za-z0-9][A-Za-z0-9._:-]*) and the writer-id
# shape (that charset plus one optional trailing [alnum] suffix) are defined once, as zms_is_model_id and
# zms_is_writer_id in scripts/lib/model-subprocess.sh, which the router, model-run and preflight all
# source. Pinned two ways: no consumer carries its own copy any more (the copies drifted as four
# hand-restated case patterns), and the one definition gives the documented verdict for every probe,
# under LC_ALL=C and a UTF-8 locale — the alphabet is spelled out letter by letter because a bracket
# RANGE follows the locale's collation in bash 3.2.
new_case charset-parity
for _src in "$PF" "$ROUTE_MODEL_SCRIPT" "$ROOT/scripts/zuvo-home/model-run" "$ROOT/scripts/lib/reviewer-lanes.sh"; do
  _defs="$(awk '/^[[:space:]]*#/ { next } /ID_ALNUM=|is_model_id[[:space:]]*\(\)|is_writer_id[[:space:]]*\(\)|(^|[^_a-z])is_id[[:space:]]*\(\)/ { print FILENAME ":" FNR ": " $0 }' "$_src")"
  case "$_src" in
    */reviewer-lanes.sh)
      # zrl_is_model_id stays as the lane library's own name for the build scripts, as a one-line call.
      # Nothing else is excused: the library reads ZMS_ID_ALNUM where it needs the alphabet and keeps no
      # copy, so even an alias (`ZRL_ID_ALNUM="$ZMS_ID_ALNUM"`) would be a second name to drift and fails.
      _defs="$(printf '%s\n' "$_defs" | awk 'NF && !/zrl_is_model_id\(\) \{ zms_is_model_id "\$@"; \}/')" ;;
  esac
  expect_eq "one id predicate: ${_src#"$ROOT"/} defines no charset of its own" "" "$_defs"
done
unset _src _defs
PARITY_SCRIPT="$C/charset-parity.sh"
{
  printf '. "%s" || exit 9\n' "$LIB"
  cat <<'PARITYEOF'
rc=0
for p in gpt-6-sol claude-opus-5-5 codex-5.3 opus sonnet haiku a A0._:-Z9 5x; do
  zms_is_model_id "$p" || { printf 'REJECTED model id [%s]\n' "$p"; rc=1; }
  zms_is_writer_id "$p" || { printf 'REJECTED writer id [%s]\n' "$p"; rc=1; }
done
for p in "opus[1m]" "claude-opus-5-5[1m]"; do
  zms_is_writer_id "$p" || { printf 'REJECTED writer id [%s]\n' "$p"; rc=1; }
  ! zms_is_model_id "$p" || { printf 'ACCEPTED model id [%s]\n' "$p"; rc=1; }
done
for p in "" "-leading-dash" ".x" ":x" "with space" "trailing-space " "dollar\$sign" "back\`tick" "slash/here" \
         "equals=sign" "glob*star" "question?mark" "a;b" $'cr\rhere' $'lf\nhere' $'gpt-\xc3\xa9' "opus[" "opus[]" \
         "op[1m]us" "opus[1m][2m]" "opus[1-m]"; do
  ! zms_is_model_id "$p" || { printf 'ACCEPTED model id [%q]\n' "$p"; rc=1; }
  ! zms_is_writer_id "$p" || { printf 'ACCEPTED writer id [%q]\n' "$p"; rc=1; }
done
exit $rc
PARITYEOF
} > "$PARITY_SCRIPT"
_parity_locales="C"
if command -v locale >/dev/null 2>&1; then
  _u="$(locale -a 2>/dev/null | awk 'tolower($0) ~ /utf-?8/ && tolower($0) ~ /^en_us/ {print; exit}')"
  [ -z "$_u" ] && _u="$(locale -a 2>/dev/null | awk 'tolower($0) ~ /utf-?8/ {print; exit}')"
  [ -n "$_u" ] && _parity_locales="C $_u"
fi
for _loc in $_parity_locales; do
  _out="$(LC_ALL="$_loc" bash "$PARITY_SCRIPT" 2>&1)"; _rc=$?
  if [ "$_rc" -eq 0 ]; then ok "id predicates ($_loc): zms_is_model_id / zms_is_writer_id give the documented verdict for every probe"
  else bad "id predicates ($_loc): $_out"; fi
done
if [ "$_parity_locales" = "C" ]; then
  echo "  SKIP id predicates: no UTF-8 locale found via 'locale -a' — only LC_ALL=C ran"
fi
unset _parity_locales _u PARITY_SCRIPT
# (a) no private copies left: a re-added one is how the four copies this replaced came about.
if grep -qE '^(ID_ALNUM|_PF_ID_ALNUM)=|^(is_model_id|pf_is_model_id)\(\)' "$ROUTE_MODEL_SCRIPT" "$PF"; then
  bad "the router or preflight defines its own reviewer-id grammar again — call zms_is_model_id"
else
  ok "the router and preflight carry no private reviewer-id grammar (they call zms_is_model_id)"
fi

# ── 0h. ONE same-vendor guard. "`ok` names the OTHER vendor" is zms_route_same_vendor in the library; the
# preflight and model-run both call it and neither detects the host vendor on its own any more (the two
# hand-written copies could drift: one learning a new Codex host signal, the other not). The function's
# verdicts, host signals included, are pinned here as a table; status 0 = same vendor = refuse.
new_case same-vendor-guard
for _src in "$PF" "$ROOT/scripts/zuvo-home/model-run"; do
  _calls="$(awk '/^[[:space:]]*#/ { next } /zms_route_same_vendor "/ { n++ } END { print n + 0 }' "$_src")"
  expect_eq "one same-vendor guard: ${_src#"$ROOT"/} calls zms_route_same_vendor once" 1 "$_calls"
  # Every host signal the library reads, bare or braced: a hand-rolled `$CLAUDECODE` or CODEX_SANDBOX test
  # is a second copy of the guard just as much as a zms_is_codex_host call is.
  _own="$(awk '/^[[:space:]]*#/ { next } /zms_is_codex_host|CLAUDECODE|CODEX_SANDBOX|CODEX_SHELL|CODEX_INTERNAL_ORIGINATOR_OVERRIDE|__CFBundleIdentifier/ { print FNR ": " $0 }' "$_src")"
  expect_eq "one same-vendor guard: ${_src#"$ROOT"/} reads no host-vendor signal itself" "" "$_own"
done
unset _src _calls _own
# sv <label> <want-status> <want-host> <client> <platform> [VAR=value ...]
sv() {
  local label="$1" want="$2" host="$3" client="$4" platform="$5" got
  shift 5
  got="$(env -i PATH=/usr/bin:/bin ZUVO_CODEX_APP_BIN=/nonexistent "$@" "$BASH" -c \
    '. "$1" || exit 9; h="$(zms_route_same_vendor "$2" "$3")"; printf "%s [%s]" "$?" "$h"' _ "$LIB" "$client" "$platform" 2>&1)"
  expect_eq "same-vendor guard: $label" "$want [$host]" "$got"
}
sv "codex for a claude platform, no host signal — cross-vendor" 1 "" codex claude
sv "claude for a codex platform, no host signal — cross-vendor" 1 "" claude codex
sv "claude for a claude platform — the platform's own vendor" 0 "" claude claude
sv "codex for a codex platform — the platform's own vendor" 0 "" codex codex
sv "codex, platform=claude, on a Codex host (a lying platform=) — the host's vendor" 0 codex codex claude CODEX_SANDBOX=seatbelt
sv "claude, platform=codex, under CLAUDECODE=1 (a lying platform=) — the host's vendor" 0 claude claude codex CLAUDECODE=1
sv "codex, platform=claude, under CLAUDECODE=1 — cross-vendor, host reported" 1 claude codex claude CLAUDECODE=1
sv "claude, platform=codex, on a Codex host — cross-vendor, host reported" 1 codex claude codex CODEX_SHELL=1
sv "an empty client is never a match" 1 "" "" claude

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
# PF_BOUND=15 on every hung-client case (here, the 42-then-hang pair and the open stdin pipe): the
# diagnostic and the dead spy alone would still pass a preflight that fired its 2 s budget and then waited
# the 30 s spy out anyway (the spy is gone by then too). Under the outer bound that wait reads RC 124/137,
# not the expected 1. The spy sleeps in 1 s steps, so no long-lived sleep child can outlive it unseen.
new_case agy-hung
spy "$C/bin" agy
PF_BOUND=15
run_pf "$PF" SPY_SLEEP=30 SPY_REPLY=42 ZUVO_PREFLIGHT_TIMEOUT=2
spy_ran "agy hung" agy
expect_eq "agy hung: exit 1" "1" "$RC"
expect_eq "agy hung: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
# The bound is proven by what it did: the 2s budget fired (the diagnostic names it) and killed the 30s spy.
expect_has "agy hung: stderr says the canary timed out at its 2s budget" "canary agy failed: timed out after 2s" "$ERR"
if poll 5 no_proc "$C/bin/agy"; then ok "agy hung: no agy spy process survives"
else bad "agy hung: an agy spy process survived preflight"; fi
contract "agy hung"
tmp_clean "agy hung"

new_case codex-hung
spy "$C/off" codex
PF_BOUND=15
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" SPY_SLEEP=30 SPY_REPLY=42 ZUVO_PREFLIGHT_TIMEOUT=2
spy_ran "codex hung" codex
expect_eq "codex hung: exit 1" "1" "$RC"
expect_eq "codex hung: provider=codex" "codex" "$(field provider)"
expect_has "codex hung: bounded by the runner's --timeout — the canary timed out at its 2s budget" "canary codex failed: timed out after 2s" "$ERR"
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
if install_home_driver_no_lib; then
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
else
  echo "  SKIP broken lib/: the rest of this case — install_home_driver_no_lib failed above, so nothing below could be about what this case tests (P2-138)"
fi

new_case home-lib
mkdir -p "$C/solo"
cp "$PF" "$C/solo/reviewer-preflight.sh"
cp "$LIB" "$C/home/.zuvo/model-subprocess.sh"
if install_home_driver; then
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "~/.zuvo lib: exit 0 (the last candidate loads)" "0" "$RC"
  expect_eq "~/.zuvo lib: provider=agy" "agy" "$(field provider)"
  expect_not_has "~/.zuvo lib: no missing-runner error" "not loaded" "$ERR"
  contract "~/.zuvo lib"
  tmp_clean "~/.zuvo lib"
else
  echo "  SKIP ~/.zuvo lib: the rest of this case — install_home_driver failed above, so nothing below could be about what this case tests (P2-138)"
fi

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
if install_home_driver_no_lib; then
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
else
  echo "  SKIP partial lib/: the rest of this case — install_home_driver_no_lib failed above, so nothing below could be about what this case tests (P2-138)"
fi

# The script's directory is resolved PHYSICALLY, like the driver's and the router's. Invoked as
# <link>/../scripts/reviewer-preflight.sh where <link> is a symlink to real/scripts, bash (the kernel)
# opens real/scripts/reviewer-preflight.sh — but a LOGICAL `cd` folds `<link>/..` lexically into the
# case dir and lands in <case>/scripts, a directory this file is not in, whose lib/ it then SOURCED.
new_case symlinked-dir
mkdir -p "$C/real/scripts/lib" "$C/scripts/lib"
cp "$PF" "$C/real/scripts/reviewer-preflight.sh"
cp "$LIB" "$C/real/scripts/lib/model-subprocess.sh"
if install_home_driver; then
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
else
  echo "  SKIP symlinked dir: the rest of this case — install_home_driver failed above, so nothing below could be about what this case tests (P2-138)"
fi

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
PF_BOUND=15
run_pf "$PF" SPY_REPLY=42 SPY_SLEEP_AFTER=30 ZUVO_PREFLIGHT_TIMEOUT=2
spy_ran "agy 42+hang" agy
expect_eq "agy 42+hang: exit 1" "1" "$RC"
expect_eq "agy 42+hang: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "agy 42+hang: provider=agy" "agy" "$(field provider)"
expect_has "agy 42+hang: stderr says the canary timed out at its 2s budget" "canary agy failed: timed out after 2s" "$ERR"
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
PF_BOUND=15
run_pf "$PF" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 SPY_SLEEP_AFTER=30 ZUVO_PREFLIGHT_TIMEOUT=2
spy_ran "codex 42+hang" codex
expect_eq "codex 42+hang: exit 1" "1" "$RC"
expect_eq "codex 42+hang: preflight_status=canary-failed" "canary-failed" "$(field preflight_status)"
expect_eq "codex 42+hang: provider=codex" "codex" "$(field provider)"
expect_has "codex 42+hang: stderr says the canary timed out at its 2s budget" "canary codex failed: timed out after 2s" "$ERR"
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

# A caller stdin that never reaches EOF (a pipe whose writer stays open) must not hold the canary. The
# outer bound (30 s, under the 40 s writer) turns a preflight that waits on the pipe past its budget into RC 124.
new_case stdin-open-pipe
spy "$C/bin" agy
mkfifo "$C/fifo" || { echo "  FAIL mkfifo failed" >&2; exit 1; }
sleep 40 > "$C/fifo" &
_writer=$!
PF_STDIN="$C/fifo"
PF_BOUND=30
run_pf "$PF" SPY_REPLY=42 ZUVO_PREFLIGHT_TIMEOUT=20
{ kill "$_writer"; wait "$_writer"; } 2>/dev/null
spy_ran "open stdin pipe" agy
expect_eq "open stdin pipe: exit 0 (agy did not wait on the caller's stdin)" "0" "$RC"
expect_eq "open stdin pipe: provider=agy" "agy" "$(field provider)"
# A canary that waited on the caller's stdin would sit until its 20s budget killed it and be reported as
# timed out (exit 1 above); an answered one names no timeout.
expect_not_has "open stdin pipe: the canary was not ended by its budget — it never waited on the caller's stdin" "timed out" "$ERR"
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
sys_farm_without_timeout
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
# the repo. CLAUDE_MODEL=sonnet makes the router answer platform=claude, and since plan C Task 1 a
# Claude host is routing_status=ok only CROSS-VENDOR: a codex must be installed (here the spy, pinned
# by ZUVO_CODEX_BIN off the PATH), and the reviewer is the registry's codex primary ($REG_MODEL) on
# lane cross-vendor. The same spy is then the first candidate of the driver's panel, so it is the
# canary that answers (provider=codex). Combined with that answering canary, BOTH halves of "ok" —
# reachable routing AND a working reviewer — are genuinely exercised together, not assumed from
# reading the router alone. (Which candidate preflight probes FIRST is plan C Task 6, not this case.)
new_case success-ok
spy "$C/bin" agy
spy "$C/off" codex
run_pf "$PF" CLAUDE_MODEL=sonnet SPY_REPLY=42 ZUVO_CODEX_BIN="$C/off/codex"
_want_ok="preflight_status=ok
provider=codex
platform=claude
writer_model=sonnet
writer_lane=strong_alt
reviewer_lane=cross-vendor
reviewer_model=$REG_MODEL
routing_status=ok"
expect_eq "success-ok: exit 0" "0" "$RC"
expect_eq "success-ok: the full 8-line ok output block, exact" "$_want_ok" "$OUT"
spy_ran "success-ok" codex
# Two spies in one case: each client's record is its own file ($C/spy/<name>.rec, keyed by the name the spy
# was invoked under), so the codex record says nothing about agy. The first candidate answered, so agy — the
# later candidate — must not have been run at all.
spy_not_ran "success-ok" agy
contract "success-ok"
tmp_clean "success-ok"

# ── 21a. plan C Task 6: the ROUTED cross-vendor client is probed BEFORE the panel's own order,
# not merely because it happens to be first in the driver's panel listing. Distinguishing
# feature vs. success-ok above: the panel order here puts a DIFFERENT candidate ahead of the
# routed one (agy before codex-5.3 / claude), and BOTH spies answer 42 — so if preflight still
# canaried in plain panel order, the panel's own first candidate would answer and win. Proving
# the routed client answers instead, and the panel's first candidate never ran at all, is the
# only way to show the reordering happened (spy_ran / spy_not_ran — this file's own idiom: the
# canary loop tries candidates strictly one at a time and stops at the first success, so "only
# the routed client's spy has a record" already IS the order proof; no separate log needed).
# The routed client still goes through the SAME computed-answer canary (SPY_REPLY=42, not a
# short-circuit) — proven by asserting provider/preflight_status exactly as success-ok does.

new_case route-first-claude-host
spy "$C/off" codex
spy "$C/bin" agy
run_pf "$PF" CLAUDE_MODEL=sonnet SPY_REPLY=42 ZUVO_CODEX_BIN="$C/off/codex" \
  ZUVO_REVIEW_TEST_PROVIDERS="agy codex-5.3"
expect_eq "route-first claude host: exit 0" "0" "$RC"
expect_eq "route-first claude host: routing_status=ok (codex is the router's cross-vendor pick)" \
  "ok" "$(field routing_status)"
expect_eq "route-first claude host: provider=codex — the routed reviewer, probed ahead of agy despite the panel listing agy first" \
  "codex" "$(field provider)"
spy_ran "route-first claude host" codex
spy_not_ran "route-first claude host (the panel's own first-listed candidate must not run — the routed client already answered)" agy
contract "route-first claude host"
tmp_clean "route-first claude host"

new_case route-first-codex-host
spy "$C/off" claude
spy "$C/bin" agy
run_pf "$PF" CODEX_SANDBOX=seatbelt ZUVO_CLAUDE_BIN="$C/off/claude" SPY_REPLY=42 \
  ZUVO_REVIEW_TEST_PROVIDERS="agy claude"
expect_eq "route-first codex host: exit 0" "0" "$RC"
expect_eq "route-first codex host: routing_status=ok (claude is the router's cross-vendor pick)" \
  "ok" "$(field routing_status)"
expect_eq "route-first codex host: provider=claude — the routed reviewer, probed ahead of agy despite the panel listing agy first" \
  "claude" "$(field provider)"
spy_ran "route-first codex host" claude
spy_not_ran "route-first codex host (the panel's own first-listed candidate must not run — the routed client already answered)" agy
contract "route-first codex host"
tmp_clean "route-first codex host"

# ── 21b. a non-ok route (the routed client itself unavailable) must not block or replace the
# panel canary — preflight still canaries the panel candidates exactly as it always did, and the
# verdict mapping (any non-ok routing_status -> degraded-routing) is unchanged. ZUVO_CODEX_BIN is
# already /nonexistent by run_pf's own default; named explicitly here for the reader.
new_case route-degraded-still-canaries-panel
spy "$C/bin" agy
run_pf "$PF" CLAUDE_MODEL=sonnet ZUVO_CODEX_BIN=/nonexistent SPY_REPLY=42
expect_eq "route degraded still canaries panel: exit 0" "0" "$RC"
expect_eq "route degraded still canaries panel: routing_status=cross-vendor-unavailable (codex not installed)" \
  "cross-vendor-unavailable" "$(field routing_status)"
expect_eq "route degraded still canaries panel: preflight_status=degraded-routing (non-ok route, unchanged mapping)" \
  "degraded-routing" "$(field preflight_status)"
expect_eq "route degraded still canaries panel: provider=agy (the panel's own candidate; no routed client was available to try first)" \
  "agy" "$(field provider)"
spy_ran "route degraded still canaries panel" agy
contract "route degraded still canaries panel"
tmp_clean "route degraded still canaries panel"

# ── 21c. dedup: the routed client also appears in the panel's own listing (the normal case —
# cross-vendor always names the OTHER vendor, which the panel already includes) — it must be
# canaried exactly ONCE, never once as the routed client and again at its panel position. Both
# spies ECHO (neither answers 42), so the canary loop keeps going past codex to agy — if codex
# were tried twice, "canary codex failed" would appear twice on stderr.
# T5 (adversarial pass 3, f1-3/f1-16/f1-7 BYTEPLUS CRITICAL): verified first — "codex-5.3" is a
# literal entry of ZUVO_REVIEW_TEST_PROVIDERS below, and the harness precondition earlier in this
# file already pins that the driver's --list-providers --mode blind-audit returns it verbatim under
# this override; pf_map_lane folds it to "codex", the SAME literal the router resolves ROUTED_
# CLIENT to for a Claude writer. So a broken dedup here would genuinely try codex TWICE: once as
# the prepended routed client, once again from its own panel entry — this setup CAN detect a failed
# dedup, not merely assume it. The assertion below counts actual spy INVOCATIONS (spy_counting's
# wrapper, appending to a counter file) rather than a stderr substring: the real spy-cli fixture
# OVERWRITES its own .rec file on every run, so a rec-based or stderr-message-based count could not
# tell "ran once" from "ran twice" as directly as a counter that increments BEFORE each handoff.
new_case route-first-dedup-no-double-canary
CODEX_INVOCATIONS="$C/codex-invocations.count"
spy_counting "$C/off" codex "$CODEX_INVOCATIONS"
spy "$C/bin" agy
run_pf "$PF" CLAUDE_MODEL=sonnet ZUVO_CODEX_BIN="$C/off/codex" SPY_ECHO=1 \
  ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 agy"
expect_eq "route-first dedup: exit 1 (both candidates echo, neither answers)" "1" "$RC"
_ccount="$(awk 'END{print NR+0}' "$CODEX_INVOCATIONS" 2>/dev/null)" || _ccount=0
expect_eq "route-first dedup (T5): the routed client dedups against its own panel entry — codex invoked EXACTLY once (spy invocation COUNT via a counter-file wrapper, not a stderr substring)" \
  "1" "$_ccount"
spy_ran "route-first dedup" codex
spy_ran "route-first dedup" agy
contract "route-first dedup"
tmp_clean "route-first dedup"

# ── 21d. fallthrough: the routed client is tried FIRST, but when ITS canary genuinely fails (a
# wrong computed answer, not merely absent), the loop must fall through to the panel's own next
# candidate — never stop, never fail the whole preflight just because the routed reviewer itself
# is unreachable this run. Panel order puts agy AFTER codex-5.3, so agy winning here can only mean
# codex was tried and failed first: both spies leave a record (spy_ran), and the code's own
# structure is the order proof this file's header promises ("log order or the failure line") —
# the canary loop is a strict `for` that breaks on the FIRST success, so a winner that is not
# CANDIDATES[0] necessarily means CANDIDATES[0] (codex, the routed client) ran and failed before
# the loop ever reached agy; a canary-failed line for codex with none for agy (which won, so it
# never gets one) is that same fact read off stderr.
new_case route-first-fallthrough-to-panel
spy "$C/off" codex
spy "$C/bin" agy
printf '41\n' > "$C/spy/codex.reply"
printf '42\n' > "$C/spy/agy.reply"
run_pf "$PF" CLAUDE_MODEL=sonnet ZUVO_CODEX_BIN="$C/off/codex" \
  ZUVO_REVIEW_TEST_PROVIDERS="agy codex-5.3"
expect_eq "route-first fallthrough: exit 0" "0" "$RC"
expect_eq "route-first fallthrough: routing_status=ok (codex is still the router's cross-vendor pick)" \
  "ok" "$(field routing_status)"
expect_eq "route-first fallthrough: provider=agy — the routed client (codex) failed its canary, so the panel's own next candidate ran and won" \
  "agy" "$(field provider)"
spy_ran "route-first fallthrough" codex
spy_ran "route-first fallthrough" agy
expect_has "route-first fallthrough: codex (the routed client, tried FIRST) failed its own canary — a wrong computed answer, 41 not 42" \
  "canary codex failed" "$ERR"
expect_not_has "route-first fallthrough: agy (the panel's own candidate, tried only AFTER codex failed) never gets a failure line — it is the one that WINS" \
  "canary agy failed" "$ERR"
contract "route-first fallthrough"
tmp_clean "route-first fallthrough"

# ── 21e. adversarial pass 1, Q1 (F12 WARNING/CLAUDE): the missing test — a routed client that is
# ABSENT from the panel listing entirely. Every case above included the routed client's own name
# in ZUVO_REVIEW_TEST_PROVIDERS, so none of them could tell "probed first because routed" apart
# from "probed first because the panel put it first anyway". Decision (investigated first — see
# section 1a's own comment in scripts/reviewer-preflight.sh): `provider=` has exactly two
# consumers in this repo (skills/write-tests/SKILL.md, shared/includes/test-reviewer-routing.md)
# and both act only on `preflight_status`/exit code, never on `provider=` as a panel lane — so the
# prepend stays a UNION with the panel, not an intersection, and codex is expected to be canaried
# here even though the panel never listed it.
new_case route-first-absent-from-panel
spy "$C/off" codex
spy "$C/bin" agy
run_pf "$PF" CLAUDE_MODEL=sonnet SPY_REPLY=42 ZUVO_CODEX_BIN="$C/off/codex" \
  ZUVO_REVIEW_TEST_PROVIDERS="agy"
expect_eq "route-first absent from panel: exit 0" "0" "$RC"
expect_eq "route-first absent from panel: routing_status=ok" "ok" "$(field routing_status)"
expect_eq "route-first absent from panel: provider=codex — the routed reviewer, canaried even though the panel listing never named it (union, not intersection — the documented decision)" \
  "codex" "$(field provider)"
spy_ran "route-first absent from panel" codex
spy_not_ran "route-first absent from panel (agy is the panel's only candidate; codex answered first)" agy
contract "route-first absent from panel"
tmp_clean "route-first absent from panel"

# ── 21e2. an ok route from a Cursor, Kimi or Antigravity host is the ROUTER's answer and stays ok. The
# router reports ok on these hosts with a reviewer no codex/claude CLI serves (agy, kimi-k2.6,
# gemini-3.1-pro-high) — a cross-host or in-family reviewer the panel canaries by its own order. The
# claude/codex routed-client checks (client mapping, same vendor) do not apply to them: before plan C
# preflight answered ok here, and treating the unmapped reviewer as a broken contract made every
# write-tests run on these hosts degraded. The REAL router answers each case (host signals set, no stub).
new_case route-ok-cursor-host
spy "$C/bin" agy
run_pf "$PF" CURSOR_AGENT_MODEL=composer-2.5-fast SPY_REPLY=42
expect_eq "cursor host: exit 0" "0" "$RC"
expect_eq "cursor host: the router answers platform=cursor reviewer_model=agy routing_status=ok" \
  "cursor agy ok" "$(field platform) $(field reviewer_model) $(field routing_status)"
expect_eq "cursor host: preflight_status=ok (the router's ok, not a broken claude/codex contract)" "ok" "$(field preflight_status)"
expect_not_has "cursor host: no contract-violation diagnostic" "degrading" "$ERR"
expect_eq "cursor host: provider=agy (the panel's candidate)" "agy" "$(field provider)"
contract "cursor host"
tmp_clean "cursor host"

new_case route-ok-kimi-host
spy "$C/bin" agy
run_pf "$PF" ZUVO_KIMI_CLI_MODEL=kimi-code MOONSHOT_API_KEY=dummy-not-a-key SPY_REPLY=42
expect_eq "kimi host: exit 0" "0" "$RC"
expect_eq "kimi host: the router answers platform=kimi reviewer_model=kimi-k2.6 routing_status=ok" \
  "kimi kimi-k2.6 ok" "$(field platform) $(field reviewer_model) $(field routing_status)"
expect_eq "kimi host: preflight_status=ok" "ok" "$(field preflight_status)"
expect_not_has "kimi host: no contract-violation diagnostic" "degrading" "$ERR"
expect_eq "kimi host: provider=agy (the panel's candidate)" "agy" "$(field provider)"
contract "kimi host"
tmp_clean "kimi host"

new_case route-ok-antigravity-host
spy "$C/off" codex
run_pf "$PF" GEMINI_MODEL=gemini-3-flash ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 ZUVO_REVIEW_TEST_PROVIDERS=codex-5.3
expect_eq "antigravity host: exit 0" "0" "$RC"
expect_eq "antigravity host: the router answers platform=antigravity reviewer_model=gemini-3.1-pro-high routing_status=ok" \
  "antigravity gemini-3.1-pro-high ok" "$(field platform) $(field reviewer_model) $(field routing_status)"
expect_eq "antigravity host: preflight_status=ok" "ok" "$(field preflight_status)"
expect_not_has "antigravity host: no contract-violation diagnostic" "degrading" "$ERR"
expect_eq "antigravity host: provider=codex (the panel's candidate)" "codex" "$(field provider)"
contract "antigravity host"
tmp_clean "antigravity host"

# critical_setup_fail <label> — T2 (renamed from critical_skip: it calls bad(), so it IS a fail,
# never a skip — the old name read as an escape hatch). S5 (adversarial pass 2, F13 CLAUDE): for
# the Task 6 critical-path cases below (the same-vendor guard, the Q2/Q3 contract-violation
# checks), a failed setup step (install_home_driver OR write_stub_router OR a manual mkdir/cp) is a
# HARD FAIL, never a silent SKIP — a flaky/unavailable install in CI must not hide zero coverage of
# the self-review fix behind an all-green run. T2: also runs tmp_clean, so the new_case/tmp_clean
# pairing holds even on this path (contract() is skipped deliberately — nothing ran run_pf, so $OUT
# is stale from whatever case ran before this one, and asserting the 8-key contract against it would
# validate the WRONG run). (Pre-existing Plan B cases elsewhere in this file keep their own SKIP
# convention, P2-138 — out of scope here, not Task 6's own critical path.)
critical_setup_fail() {
  bad "$1: a setup step failed above — treating this critical-path case as a hard FAIL, not a silent skip (T1/T2/S5)"
  tmp_clean "$1"
}

# write_stub_router <reviewer_model line, e.g. "reviewer_model=banana-model"> [platform line,
# default "platform=claude"] — a stub at $C/solo/reviewer-model-route.sh printing a fixed,
# well-formed six-key block (a valid writer, reviewer_lane=cross-vendor, routing_status=ok) with
# the GIVEN reviewer_model (and, when given, platform) lines substituted. This is Q2/Q3/S1's
# controlled way to reach preflight's routing_status=ok arm with a specific reviewer_model/platform
# shape (empty, unmapped, a metacharacter, a leading space, a lying platform) that no REAL router
# invocation in this suite could produce — every other case runs under `env -i`, which clears
# every host signal the real router reads, so it can only ever answer unknown-writer-model here.
# $C/solo also gets its own $PF/$LIB siblings (the same shape as the broken-lib/driver-list-fails
# cases above); the panel driver comes from install_home_driver. T1: every setup step here returns
# non-zero on failure (mkdir/cp already did; the new payload check below is the same shape), so a
# caller chaining `install_home_driver && write_stub_router ...` correctly treats ANY of these as
# one hard setup failure.
#
# T4 (adversarial pass 3, f1-4 / f1-14): the payload itself is validated BEFORE it ever reaches the
# generated file — a newline would split into extra physical lines this stub never intended, and
# the literal heredoc terminator `ROUTEEOF` (own line, exact) would prematurely close the quoted
# heredoc the generated stub uses to print itself, truncating or corrupting its own output. Both
# would build a stub that lies about what it prints, silently invalidating whatever case called it
# rather than the intended six-key shape — refused here instead, loudly.
#
# T3 (f3-6/f3-7/f3-8): the registry copy target ($C/home/.zuvo/model-registry.sh) must not already
# exist when this runs — a stale file there would mean either a caller reused a case name (this
# suite's actual isolation: $C = $T/<case-name>, a FRESH directory per new_case call, so this can
# only fire on a genuine name collision) or a leftover from an earlier bug. Asserted, not assumed.
#
# The registry is copied to $C/home/.zuvo/model-registry.sh: without it, zms_source_registry cannot
# resolve (the solo/model-subprocess.sh copy is FLAT, not under a `scripts/lib` its own registry
# lookup recognises, so its only remaining candidate is the $HOME fallback) and every codex/claude
# canary is skipped with "no model id" REGARDLESS of whether a same-vendor guard fired — which
# would make a spy_not_ran/provider assertion pass vacuously on a BROKEN guard too. With the
# registry present, a same-vendor client that the guard failed to drop genuinely reaches its spy
# and answers, so spy_not_ran/provider assertions in these cases are proof of the guard, not an
# artifact of the sandbox.
#
# S6 (adversarial pass 2, F6/F20 MUSE): the generated stub's OWN heredoc uses a QUOTED delimiter
# (`<<'ROUTEEOF'`), so it never re-expands anything when the stub itself RUNS. The caller-supplied
# lines are never interpolated through a heredoc at ALL — each is written with its own ordinary
# `printf '%s\n' "$1"` / `"$_wsr_platform"`, a single plain parameter expansion, so a future hostile
# payload ($(...), backticks, `$VAR`) lands as inert bytes in the generated file instead of being
# re-evaluated by THIS script at stub-creation time (the bug the old unquoted `<<STUBEOF` with `$1`
# embedded inside it would have had).
write_stub_router() {
  case "$1" in
    *$'\n'*|*ROUTEEOF*)
      echo "  FAIL write_stub_router: reviewer_model payload contains a newline or the heredoc terminator — refusing to build a corrupt stub" >&2
      return 1 ;;
  esac
  case "${2:-}" in
    *$'\n'*|*ROUTEEOF*)
      echo "  FAIL write_stub_router: platform payload contains a newline or the heredoc terminator — refusing to build a corrupt stub" >&2
      return 1 ;;
  esac
  if [ -e "$C/home/.zuvo/model-registry.sh" ]; then
    echo "  FAIL write_stub_router: $C/home/.zuvo/model-registry.sh already exists — this case dir is not fresh (T3)" >&2
    return 1
  fi
  mkdir -p "$C/solo" || return 1
  cp "$PF" "$C/solo/reviewer-preflight.sh" || return 1
  cp "$LIB" "$C/solo/model-subprocess.sh" || return 1
  mkdir -p "$C/home/.zuvo" || return 1
  cp "$REGISTRY" "$C/home/.zuvo/model-registry.sh" || return 1
  local _wsr_platform="${2:-platform=claude}"
  {
    printf '#!/bin/sh\n'
    printf 'cat <<'"'"'ROUTEEOF'"'"'\n'
    printf '%s\n' "$_wsr_platform" 'writer_model=sonnet' 'writer_lane=strong_alt' 'reviewer_lane=cross-vendor'
    printf '%s\n' "$1"
    printf '%s\n' 'routing_status=ok'
    printf 'ROUTEEOF\n'
  } > "$C/solo/reviewer-model-route.sh" || return 1
  chmod +x "$C/solo/reviewer-model-route.sh" || return 1
}

# (spy_counting is defined near the top of this file, next to spy() — it is used earlier too, by
# the route-first-dedup-no-double-canary case's T5 rewrite.)

# jail_no_ambient_clients — T8 (adversarial pass 3, f3-2): for the current case, builds $C/sys
# linking every real /usr/bin and /bin tool EXCEPT codex/claude/agy/cursor-agent/kimi/gemini (the
# client names this suite's canary loop dispatches to). PATH="$C/bin:$C/sys" then still supplies
# every ordinary utility a spy/preflight/the driver needs (mktemp, awk, sed, sh, GNU timeout if the
# host has one under /usr/bin) while an ambient client binary cannot resolve even if the suite's
# global "no real client on /usr/bin:/bin" precondition (checked ONCE, at start) somehow stopped
# holding for this one, later case — belt and suspenders, not a replacement for that precondition.
jail_no_ambient_clients() {
  local _f _base
  mkdir -p "$C/sys" || exit 1
  for _f in /usr/bin/* /bin/*; do
    _base="${_f##*/}"
    case "$_base" in codex|claude|agy|cursor-agent|kimi|gemini) continue ;; esac
    [ -e "$C/sys/$_base" ] || [ -L "$C/sys/$_base" ] || ln -s "$_f" "$C/sys/$_base" 2>/dev/null
  done
  hermetic_link_tools "$C/sys" timeout gtimeout
}

# ── shared tool jail for sections 22-25 AND 21l (T8) — moved ahead of 21f so 21l (defined before
# 22-25 in file order) can use it too; nothing before this point ever referenced T_SYS, so moving
# its construction earlier changes no other case's behaviour. ──
# ADV-C67/C68: sections 22-25 below used to fall back to the raw ambient `/usr/bin:/bin` for every
# tool besides the one being fault-injected, unlike the "no-timeout" case's own controlled
# `$C/sys` tool jail (built above specifically so mktemp/awk/timeout-absence is verified, not
# assumed). A host whose real /usr/bin differs (e.g. genuinely missing timeout/gtimeout) could
# make these four cases behave inconsistently between CI and local dev. Build ONE shared jail
# (real tools, timeout INCLUDED — these cases fault-inject mktemp/mkdir, not timeout) once, reused
# by all four, in place of the ambient PATH tail.
# P2-127: "timeout INCLUDED" was only true on a host whose GNU timeout lives in /usr/bin or /bin —
# on macOS it is Homebrew's (/opt/homebrew/bin), so the jail itself held none and only $C/bin's own
# link supplied one. The jail now links it the way new_case does (hermetic_link_tools, resolved on
# the caller's PATH) and its completeness gate REQUIRES it, so a jail without a timeout fails loud
# instead of silently leaning on whatever else happens to be on the case PATH.
T_SYS="$T/sys"; mkdir -p "$T_SYS"
ln -s /usr/bin/* "$T_SYS/" 2>/dev/null
for _f in /bin/*; do
  if [ ! -e "$T_SYS/${_f##*/}" ] && [ ! -L "$T_SYS/${_f##*/}" ]; then ln -s "$_f" "$T_SYS/"; fi
done
hermetic_link_tools "$T_SYS" timeout gtimeout
_tsys_missing=""
for _f in mktemp awk mkdir; do [ -e "$T_SYS/$_f" ] || _tsys_missing="$_tsys_missing $_f"; done
[ -e "$T_SYS/timeout" ] || [ -e "$T_SYS/gtimeout" ] || _tsys_missing="$_tsys_missing timeout|gtimeout"
if [ -n "$_tsys_missing" ]; then
  bad "sections 22-25 / 21l jail: the shared tool jail $T_SYS is incomplete — missing:$_tsys_missing"
  echo "=== RESULT ==="
  echo "RESULT: PASS=$PASS FAIL=$FAIL (stopped before sections 22-25)"
  exit 1
fi

# ── 21f. Q1/S1 same-vendor guard, CLAUDE arm (F13 MUSE CRITICAL): a router bug (here, a stub
# standing in for one) reports routing_status=ok while naming a reviewer of the WRITER's OWN
# vendor — exactly the disagreement-between-independent-code-paths F11 (CLAUDE) describes: the
# panel listing here never includes claude at all (ZUVO_REVIEW_TEST_PROVIDERS=agy), yet the stub
# router still claims platform=claude / reviewer_model=claude-opus-5-5 / ok. CLAUDECODE=1 makes
# this a REAL claude host (S1: the guard now compares ROUTED_CLIENT against the independently
# detected host vendor, not the route's own platform= string — this case's platform= happens to
# agree with reality, isolating the host-vendor comparison itself; the LYING-platform case is
# 21f2 below). Without the guard this prepends and canaries the host's OWN vendor client
# (self-review, answered here by a claude spy that WOULD pass the computed-answer check) even
# though the panel driver never offered it. With the guard, ROUTED_CLIENT is dropped, only the
# panel's own agy runs, and the contract violation downgrades the verdict to degraded-routing.
#
# T6 (adversarial pass 3, f1-2): positive control — the "no model id" skip line proves claude's
# canary was genuinely ELIGIBLE (the registry resolved, a model id was available) and would have
# answered had the guard not dropped ROUTED_CLIENT first; without this, spy_not_ran could pass
# vacuously on a sandbox where claude was never going to be tried anyway.
new_case route-same-vendor-guard
if install_home_driver && write_stub_router 'reviewer_model=claude-opus-5-5'; then
  spy "$C/off" claude
  spy "$C/bin" agy
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_REPLY=42 \
    CLAUDECODE=1 ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "same-vendor guard: exit 0" "0" "$RC"
  expect_eq "same-vendor guard: preflight_status=degraded-routing (an 'ok' route naming the writer's own vendor is a contract violation)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "same-vendor guard: stderr names the same-vendor violation" "same vendor" "$ERR"
  expect_eq "same-vendor guard: provider=agy — the same-vendor 'reviewer' was dropped before ever being prepended, never canaried" \
    "agy" "$(field provider)"
  spy_not_ran "same-vendor guard (claude is the writer's OWN vendor — self-review — and must never run)" claude
  spy_ran "same-vendor guard" agy
  expect_not_has "same-vendor guard (T6): claude was not skipped for lack of a model id — it was genuinely eligible and dropped by the guard, not by sandbox starvation" \
    "canary claude not run: no model id" "$ERR"
  contract "same-vendor guard"
  tmp_clean "same-vendor guard"
else
  critical_setup_fail "same-vendor guard"
fi

# ── 21f1. Q7 (quality review gap): the CODEX mirror of 21f above. A mutant that neuters ONLY the
# guard's codex arm (the `elif zms_is_codex_host; then host=codex` of zms_route_same_vendor) produced 0 failures
# across the whole suite before this case existed — 21f alone only exercises the CLAUDE arm.
# CODEX_SANDBOX=seatbelt makes this a REAL codex host; the stub's platform=codex agrees with
# reality (same shape as 21f, mirrored).
new_case route-same-vendor-guard-codex
if install_home_driver && write_stub_router 'reviewer_model=gpt-6-sol' 'platform=codex'; then
  spy "$C/off" codex
  spy "$C/bin" agy
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 \
    CODEX_SANDBOX=seatbelt ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "same-vendor guard (codex): exit 0" "0" "$RC"
  expect_eq "same-vendor guard (codex): preflight_status=degraded-routing (an 'ok' route naming the writer's own vendor is a contract violation)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "same-vendor guard (codex): stderr names the same-vendor violation" "same vendor" "$ERR"
  expect_eq "same-vendor guard (codex): provider=agy — the same-vendor 'reviewer' was dropped before ever being prepended, never canaried" \
    "agy" "$(field provider)"
  spy_not_ran "same-vendor guard (codex) (codex is the writer's OWN vendor — self-review — and must never run)" codex
  spy_ran "same-vendor guard (codex)" agy
  expect_not_has "same-vendor guard (codex) (T6): codex was not skipped for lack of a model id" \
    "canary codex not run: no model id" "$ERR"
  contract "same-vendor guard (codex)"
  tmp_clean "same-vendor guard (codex)"
else
  critical_setup_fail "same-vendor guard (codex)"
fi

# ── 21f1b. T7 (adversarial pass 3, f1-10): CONFLICTING host signals — CLAUDECODE=1 AND
# CODEX_SANDBOX=seatbelt set TOGETHER. Pins the documented precedence (scripts/reviewer-preflight.sh:
# `if CLAUDECODE=1 ... elif zms_is_codex_host ...` — CLAUDECODE checked first, so it wins). Isolated
# from platform= entirely: platform=codex (so the platform-based half of the guard's OR does NOT
# match ROUTED_CLIENT=claude either), leaving ONLY host-vendor detection able to decide the outcome.
# If CLAUDECODE wins (the documented behaviour), host vendor = claude = ROUTED_CLIENT -> guard
# fires. If codex had wrongly won instead, host vendor = codex != claude -> guard would NOT fire and
# this would come back "ok" with the claude spy answering first.
new_case route-same-vendor-guard-conflicting-host-signals
if install_home_driver && write_stub_router 'reviewer_model=claude-opus-5-5' 'platform=codex'; then
  spy "$C/off" claude
  spy "$C/bin" agy
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_REPLY=42 \
    CLAUDECODE=1 CODEX_SANDBOX=seatbelt ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "conflicting host signals: exit 0" "0" "$RC"
  expect_eq "conflicting host signals: preflight_status=degraded-routing (CLAUDECODE wins over CODEX_SANDBOX; host vendor=claude=ROUTED_CLIENT)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "conflicting host signals: stderr attributes the vendor CLAUDECODE resolved to (claude), proving CLAUDECODE's precedence decided this, not platform=" \
    "independently detected as claude" "$ERR"
  spy_not_ran "conflicting host signals (CLAUDECODE must win — claude is the detected host vendor)" claude
  spy_ran "conflicting host signals" agy
  contract "conflicting host signals"
  tmp_clean "conflicting host signals"
else
  critical_setup_fail "conflicting host signals"
fi

# ── 21f2. S1 (F1 CURSOR CRITICAL — "construct the real mismatch"): the route's OWN platform= LIES
# (says claude, the default from write_stub_router) while the REAL host is codex
# (CODEX_SANDBOX=seatbelt) and reviewer_model=gpt-6-sol maps to codex too — the host's own vendor.
# The OLD guard (platform= vs ROUTED_CLIENT) would compare "claude" against "codex" and find no
# match on EITHER arm, so it would never fire — self-review would persist despite this being a
# real Codex host. The NEW guard (S1) ignores platform= entirely for this comparison and asks
# zms_is_codex_host directly, so the lie does not matter.
new_case route-same-vendor-guard-real-mismatch
if install_home_driver && write_stub_router 'reviewer_model=gpt-6-sol'; then
  spy "$C/off" codex
  spy "$C/bin" agy
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 \
    CODEX_SANDBOX=seatbelt ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "same-vendor guard (real mismatch): exit 0" "0" "$RC"
  expect_eq "same-vendor guard (real mismatch): preflight_status=degraded-routing (the route's platform=claude lies; the REAL host is codex, and that is what must be caught)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "same-vendor guard (real mismatch): stderr names the same-vendor violation" "same vendor" "$ERR"
  expect_eq "same-vendor guard (real mismatch): provider=agy — dropped before prepend despite the route's platform= lying about the host" \
    "agy" "$(field provider)"
  spy_not_ran "same-vendor guard (real mismatch) (codex is the REAL host's own vendor, whatever platform= claims — self-review, must never run)" codex
  spy_ran "same-vendor guard (real mismatch)" agy
  contract "same-vendor guard (real mismatch)"
  tmp_clean "same-vendor guard (real mismatch)"
else
  critical_setup_fail "same-vendor guard (real mismatch)"
fi

# ── 21f2b. P2 (adversarial pass 3, f2-1 / f2-8 MUSE CRITICAL / f2-14): the OLD guard's OTHER hole
# — NO host signal at all (neither CLAUDECODE nor a Codex-host signal), so host-vendor detection
# resolves to nothing, and the OLD guard failed OPEN unconditionally. This case has platform=claude
# (matching write_stub_router's default) and reviewer_model=claude-opus-5-5 (same vendor) with NO
# host env override — P2 makes the guard ALSO compare against the route's own validated platform=,
# which alone is enough to catch this even with zero host signals.
new_case route-same-vendor-guard-no-host-signal
if install_home_driver && write_stub_router 'reviewer_model=claude-opus-5-5'; then
  spy "$C/off" claude
  spy "$C/bin" agy
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CLAUDE_BIN="$C/off/claude" SPY_REPLY=42 \
    ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "same-vendor guard (no host signal): exit 0" "0" "$RC"
  expect_eq "same-vendor guard (no host signal): preflight_status=degraded-routing (platform=claude alone catches it; no CLAUDECODE/CODEX_SANDBOX needed)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "same-vendor guard (no host signal): stderr names the same-vendor violation" "same vendor" "$ERR"
  expect_eq "same-vendor guard (no host signal): provider=agy" "agy" "$(field provider)"
  spy_not_ran "same-vendor guard (no host signal) (claude must not run first — P2's platform= comparison alone must catch this)" claude
  spy_ran "same-vendor guard (no host signal)" agy
  contract "same-vendor guard (no host signal)"
  tmp_clean "same-vendor guard (no host signal)"
else
  critical_setup_fail "same-vendor guard (no host signal)"
fi

# ── 21f3. S1: platform= is EMPTY. routing_status=ok promises a claude/codex route — an empty
# platform is itself a contract violation, independent of whatever ROUTED_CLIENT ended up being
# (no real host signal is set here, so the host-vendor guard above stays inert; this isolates the
# platform-validation check specifically).
new_case route-ok-platform-empty
if install_home_driver && write_stub_router 'reviewer_model=gpt-6-sol' 'platform='; then
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "platform empty: exit 0" "0" "$RC"
  expect_eq "platform empty: preflight_status=degraded-routing (ok route, platform is empty — contract violation)" \
    "degraded-routing" "$(field preflight_status)"
  # An empty value never passes the six-key gate (the check model-run shares), so the route fails closed there.
  expect_has "platform empty: stderr names the violation" "empty value: platform" "$ERR"
  expect_eq "platform empty: provider=agy (the panel is still canaried)" "agy" "$(field provider)"
  spy_ran "platform empty" agy
  contract "platform empty"
  tmp_clean "platform empty"
else
  critical_setup_fail "platform empty"
fi

# ── 21f4. S1: platform= is an ODD CASE/SPACE variant ("Claude", leading space) — not one of the
# two exact literals `claude`/`codex` this script accepts. Fail CLOSED (contract violation), not
# an attempt to trim/normalize and accept it.
new_case route-ok-platform-odd-case
if install_home_driver && write_stub_router 'reviewer_model=gpt-6-sol' 'platform= Claude'; then
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "platform odd case: exit 0" "0" "$RC"
  expect_eq "platform odd case: preflight_status=degraded-routing (' Claude' is not the exact literal claude/codex — contract violation)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "platform odd case: stderr names the violation" "platform is not claude or codex" "$ERR"
  expect_eq "platform odd case: provider=agy (the panel is still canaried)" "agy" "$(field provider)"
  spy_ran "platform odd case" agy
  contract "platform odd case"
  tmp_clean "platform odd case"
else
  critical_setup_fail "platform odd case"
fi

# ── 21g. Q3 (F3/F7/F10/F14/F1/F9): routing_status=ok whose reviewer_model is EMPTY — the six-key
# structural gate (exactly one line per key) is satisfied (the key IS present, just with an empty
# value), so this reaches section 1a with routing_status=ok and nothing to route. Without Q3 this
# silently falls through to plain panel order while still reporting preflight_status=ok — readiness
# attributed to a reviewer the route never actually named.
new_case route-ok-reviewer-model-empty
if install_home_driver && write_stub_router 'reviewer_model='; then
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "empty reviewer_model: exit 0" "0" "$RC"
  expect_eq "empty reviewer_model: preflight_status=degraded-routing (ok route, no reviewer_model — contract violation)" \
    "degraded-routing" "$(field preflight_status)"
  # An empty value never passes the six-key gate (the check model-run shares), so the route fails closed there.
  expect_has "empty reviewer_model: stderr names the violation" "empty value: reviewer_model" "$ERR"
  expect_eq "empty reviewer_model: provider=agy (the panel is still canaried)" "agy" "$(field provider)"
  spy_ran "empty reviewer_model" agy
  contract "empty reviewer_model"
  tmp_clean "empty reviewer_model"
else
  critical_setup_fail "empty reviewer_model"
fi

# ── 21h. Q3: routing_status=ok whose reviewer_model is well-formed but UNMAPPED — no client's
# case arm in zms_client_for_model matches it (not a gpt-/o<N>/codex- or claude-/opus/sonnet/haiku
# id). Distinct from the empty case above: reviewer_model itself passes the charset check; the
# mapping step is what fails.
new_case route-ok-reviewer-model-unmapped
if install_home_driver && write_stub_router 'reviewer_model=banana-model'; then
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "unmapped reviewer_model: exit 0" "0" "$RC"
  expect_eq "unmapped reviewer_model: preflight_status=degraded-routing (no client serves this model — contract violation)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "unmapped reviewer_model: stderr names the violation" "no client serves reviewer_model=banana-model" "$ERR"
  expect_eq "unmapped reviewer_model: provider=agy (the panel is still canaried)" "agy" "$(field provider)"
  spy_ran "unmapped reviewer_model" agy
  contract "unmapped reviewer_model"
  tmp_clean "unmapped reviewer_model"
else
  critical_setup_fail "unmapped reviewer_model"
fi

# ── 21i. Q2: reviewer_model carries a METACHARACTER payload after a valid-looking vendor prefix.
# Without the charset check, zms_client_for_model's own `gpt-*` glob matches ANY string starting
# with "gpt-", metacharacters included, and returns codex anyway — so the routed client would
# still get prepended and canaried on a value that was never a real model id.
new_case route-ok-reviewer-model-metachar
if install_home_driver && write_stub_router 'reviewer_model=gpt-6-sol; rm -rf /'; then
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "metachar reviewer_model: exit 0" "0" "$RC"
  expect_eq "metachar reviewer_model: preflight_status=degraded-routing (not a single valid model id — contract violation)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "metachar reviewer_model: stderr names the violation" "not a single valid model id" "$ERR"
  expect_eq "metachar reviewer_model: provider=agy (the panel is still canaried; the metacharacter value was never handed to zms_client_for_model)" \
    "agy" "$(field provider)"
  spy_ran "metachar reviewer_model" agy
  contract "metachar reviewer_model"
  tmp_clean "metachar reviewer_model"
else
  critical_setup_fail "metachar reviewer_model"
fi

# ── 21i2. The id check applies on EVERY platform, not only on the cross-vendor claude/codex routes: a
# kimi `ok` whose reviewer_model is not one id degrades too (env-compat.md's consumer paragraph says so).
# The space is printable ASCII, so the six-key gate lets the answer through and the id check is what
# catches it — the diagnostic names that check.
new_case route-ok-kimi-reviewer-model-not-an-id
if install_home_driver && write_stub_router 'reviewer_model=kimi k2' 'platform=kimi'; then
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "kimi, reviewer_model not one id: exit 0" "0" "$RC"
  expect_eq "kimi, reviewer_model not one id: preflight_status=degraded-routing (the id check is not claude/codex-only)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "kimi, reviewer_model not one id: stderr names the id check" "not a single valid model id" "$ERR"
  expect_eq "kimi, reviewer_model not one id: provider=agy (the panel is still canaried)" "agy" "$(field provider)"
  contract "kimi reviewer_model not one id"
  tmp_clean "kimi reviewer_model not one id"
else
  critical_setup_fail "kimi reviewer_model not one id"
fi
# The same rule in the consumer documentation: env-compat.md's preflight paragraph must say the id check
# runs on every platform, and must not promise that a cursor/kimi/antigravity ok stays ok unconditionally.
_ec="$ROOT/shared/includes/env-compat.md"
_ecpara="$(awk '/^- `scripts\/reviewer-preflight.sh` --/ { f = 1 } f && /^- `/ && !/reviewer-preflight/ { exit } f' "$_ec" | tr '\n' ' ')"
if [ -z "$_ecpara" ]; then bad "env-compat.md: the reviewer-preflight consumer paragraph was not found"
else
  expect_has "env-compat.md: the preflight paragraph says the id check applies on every platform" "checked on every platform" "$_ecpara"
fi
# The negative is judged over the WHOLE file, not the paragraph: a paragraph cut short at a bullet would
# let the old promise survive in its unread tail, or move one bullet down.
expect_not_has "env-compat.md: no unconditional 'stays preflight_status=ok' for cursor/kimi/antigravity, anywhere in the file" \
  'and stays `preflight_status=ok`, with no routed client' "$(tr '\n' ' ' < "$_ec" | tr -s ' ')"
unset _ec _ecpara

# ── 21j. Q2: reviewer_model carries a LEADING SPACE — fails the charset check (the first
# character must be alnum), and also happens to fail zms_client_for_model's own glob (a leading
# space means the value does not literally start with "gpt-"/"claude-"/etc either) — so this case
# is caught twice over, but the diagnostic must still be the charset one, and the verdict must
# still degrade rather than silently reporting ok with an empty ROUTED_CLIENT.
new_case route-ok-reviewer-model-leading-space
if install_home_driver && write_stub_router 'reviewer_model= gpt-6-sol'; then
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "leading-space reviewer_model: exit 0" "0" "$RC"
  expect_eq "leading-space reviewer_model: preflight_status=degraded-routing (not a single valid model id — contract violation)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "leading-space reviewer_model: stderr names the violation" "not a single valid model id" "$ERR"
  expect_eq "leading-space reviewer_model: provider=agy (the panel is still canaried)" "agy" "$(field provider)"
  spy_ran "leading-space reviewer_model" agy
  contract "leading-space reviewer_model"
  tmp_clean "leading-space reviewer_model"
else
  critical_setup_fail "leading-space reviewer_model"
fi

# ── 21i2. P5 (adversarial pass 3, f2-15): TWO independent violations on the SAME route (a bad
# platform= AND a bad reviewer_model=) must EACH print their own diagnostic line — not just the
# first one encountered, silencing the other because PF_ROUTE_CONTRACT_BROKEN was already 1.
new_case route-ok-multiple-violations-both-reported
if install_home_driver && write_stub_router 'reviewer_model=gpt-6-sol; rm -rf /' 'platform=banana'; then
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "multiple violations: exit 0" "0" "$RC"
  expect_eq "multiple violations: preflight_status=degraded-routing" "degraded-routing" "$(field preflight_status)"
  expect_has "multiple violations: the reviewer_model violation is reported" "not a single valid model id" "$ERR"
  expect_has "multiple violations: the platform violation is ALSO reported, not silenced by the earlier one" \
    "platform is not claude or codex" "$ERR"
  expect_eq "multiple violations: provider=agy" "agy" "$(field provider)"
  spy_ran "multiple violations" agy
  contract "multiple violations"
  tmp_clean "multiple violations"
else
  critical_setup_fail "multiple violations"
fi

# ── 21i3. P1 (adversarial pass 3, f2-3/f2-9): a broken "ok" route NEVER prepends its client — even
# when the violation (a malformed platform=) is discovered AFTER reviewer_model/ROUTED_CLIENT were
# already resolved successfully. Uses a codex spy that WOULD win the canary if wrongly prepended.
new_case route-ok-broken-platform-never-prepends
if install_home_driver && write_stub_router 'reviewer_model=gpt-6-sol' 'platform=banana'; then
  spy "$C/off" codex
  spy "$C/bin" agy
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 \
    ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "broken platform never prepends: exit 0" "0" "$RC"
  expect_eq "broken platform never prepends: preflight_status=degraded-routing" "degraded-routing" "$(field preflight_status)"
  expect_eq "broken platform never prepends: provider=agy — codex was resolved successfully from reviewer_model, but platform= was invalid, so it is never prepended (panel order unchanged)" \
    "agy" "$(field provider)"
  spy_not_ran "broken platform never prepends (codex resolved fine from reviewer_model, but the route as a WHOLE is broken)" codex
  spy_ran "broken platform never prepends" agy
  contract "broken platform never prepends"
  tmp_clean "broken platform never prepends"
else
  critical_setup_fail "broken platform never prepends"
fi

# ── 21i3b. P3 (adversarial pass 3, f2-7 CLAUDE): the routed client's OWN canary uses the model the
# route actually named (PF_ROUTED_MODEL), not the panel's generic registry model — the task's own
# commit promise ("check the reviewer the route will actually use"). ZUVO_CODEX_MODEL pins the
# GENERIC registry model to "gpt-a-registry" (what every OTHER candidate would get); the stub names
# reviewer_model=gpt-b-custom. Codex never takes `--model` as an argv flag at all (unlike claude) —
# zms_run_codex bakes the model into the isolated CODEX_HOME's config.toml instead (see the "codex
# 42" case above: `rec_has_line codex "config=model = ..."`), so that config line, not argv, is
# where the routed-vs-generic model actually shows up.
new_case route-ok-canary-uses-routed-model
if install_home_driver && write_stub_router 'reviewer_model=gpt-b-custom'; then
  spy "$C/off" codex
  printf '42\n' > "$C/spy/codex.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_CODEX_MODEL=gpt-a-registry \
    ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "canary uses routed model: exit 0" "0" "$RC"
  expect_eq "canary uses routed model: preflight_status=ok (a genuine cross-vendor route)" "ok" "$(field preflight_status)"
  expect_eq "canary uses routed model: provider=codex" "codex" "$(field provider)"
  if rec_has_line codex 'config=model = "gpt-b-custom"'; then
    ok "canary uses routed model (P3): the codex spy's isolated CODEX_HOME config.toml carries the ROUTED model (gpt-b-custom), never the generic registry model every other candidate would get"
  else
    bad "canary uses routed model (P3): config.toml does not carry model = \"gpt-b-custom\" — $(rec codex config)"
  fi
  if rec_lacks codex 'model = "gpt-a-registry"'; then
    ok "canary uses routed model (P3): the generic registry model (gpt-a-registry) never reached this candidate's config"
  else
    bad "canary uses routed model (P3): the generic registry model leaked into the routed candidate's config"
  fi
  spy_ran "canary uses routed model" codex
  contract "canary uses routed model"
  tmp_clean "canary uses routed model"
else
  critical_setup_fail "canary uses routed model"
fi

# ── 21i4. P4 (adversarial pass 3, f2-4): a BLANK LINE smuggled into an otherwise well-formed
# six-key block (7 physical lines: 6 real + 1 blank). `grep -c .` (the OLD line-count check) never
# counted the blank line at all, so this shape used to read as "6 lines, nothing wrong". awk's NR
# counts every line record regardless of content.
new_case route-ok-blank-line-smuggled
if mkdir -p "$C/solo" \
   && cp "$PF" "$C/solo/reviewer-preflight.sh" \
   && cp "$LIB" "$C/solo/model-subprocess.sh" \
   && cat > "$C/solo/reviewer-model-route.sh" <<'STUBEOF'
#!/bin/sh
cat <<'ROUTEEOF'
platform=claude

writer_model=sonnet
writer_lane=strong_alt
reviewer_lane=cross-vendor
reviewer_model=gpt-6-sol
routing_status=ok
ROUTEEOF
STUBEOF
   chmod +x "$C/solo/reviewer-model-route.sh" && install_home_driver
then
  spy "$C/off" codex
  spy "$C/bin" agy
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 \
    ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "blank line smuggled: exit 0" "0" "$RC"
  expect_eq "blank line smuggled: preflight_status=degraded-routing (7 physical lines, one blank — six-key gate rejects it)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "blank line smuggled: stderr names the got-7 line count" "got 7 lines" "$ERR"
  expect_eq "blank line smuggled: provider=agy (codex never gets prepended; routing_status never becomes ok at all)" \
    "agy" "$(field provider)"
  spy_not_ran "blank line smuggled (the smuggled blank line means routing_status stays routing-failed, never ok)" codex
  spy_ran "blank line smuggled" agy
  contract "blank line smuggled"
  tmp_clean "blank line smuggled"
else
  critical_setup_fail "blank line smuggled"
fi

# ── 21i5. P4 (f2-11): a CR embedded in `writer_lane=` — a field NO OTHER check in this script
# re-validates (unlike platform=/reviewer_model=, which S1/Q2 happen to re-check independently), so
# only the six-key gate's own non-printable-byte check can catch it. Proves the fix is not
# redundant with something else that would have caught this particular field anyway.
new_case route-ok-cr-in-writer-lane
if mkdir -p "$C/solo" \
   && cp "$PF" "$C/solo/reviewer-preflight.sh" \
   && cp "$LIB" "$C/solo/model-subprocess.sh" \
   && { printf '#!/bin/sh\n'
        printf 'cat <<'"'"'ROUTEEOF'"'"'\n'
        printf 'platform=claude\nwriter_model=sonnet\nwriter_lane=strong_alt\r\nreviewer_lane=cross-vendor\nreviewer_model=gpt-6-sol\nrouting_status=ok\n'
        printf 'ROUTEEOF\n'
      } > "$C/solo/reviewer-model-route.sh" \
   && chmod +x "$C/solo/reviewer-model-route.sh" && install_home_driver
then
  spy "$C/off" codex
  spy "$C/bin" agy
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 \
    ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "CR in writer_lane: exit 0" "0" "$RC"
  expect_eq "CR in writer_lane: preflight_status=degraded-routing (a CR in a field nothing else re-validates — only the six-key gate's byte check catches it)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "CR in writer_lane: stderr names the non-printable-byte violation" "non-printable byte" "$ERR"
  expect_eq "CR in writer_lane: provider=agy" "agy" "$(field provider)"
  spy_not_ran "CR in writer_lane (routing_status never becomes ok)" codex
  spy_ran "CR in writer_lane" agy
  contract "CR in writer_lane"
  tmp_clean "CR in writer_lane"
else
  critical_setup_fail "CR in writer_lane"
fi

# ── 21i6. the six-key gate is the SAME one model-run applies (zms_route_contract_ok, on the router's
# BYTES): a blank line AFTER six good ones and an EMPTY value are both refused. A command substitution
# drops trailing newlines, so the old string-based gate read the first as six lines; and it counted a
# key with an empty value (writer_lane=) as present. model-run refused both, so preflight said ok for a
# route model-run would then not run.
# route_stub_bytes <printf-format> — a stub router printing exactly these bytes, plus the solo layout.
route_stub_bytes() {
  mkdir -p "$C/solo" && cp "$PF" "$C/solo/reviewer-preflight.sh" && cp "$LIB" "$C/solo/model-subprocess.sh" \
    && printf '#!/bin/sh\nprintf '"'"'%s'"'"'\n' "$1" > "$C/solo/reviewer-model-route.sh" \
    && chmod +x "$C/solo/reviewer-model-route.sh" && install_home_driver
}
for _g in "trailing-blank|platform=claude\\nwriter_model=sonnet\\nwriter_lane=strong_alt\\nreviewer_lane=cross-vendor\\nreviewer_model=gpt-6-sol\\nrouting_status=ok\\n\\n|got 7 lines" \
          "empty-writer-lane|platform=claude\\nwriter_model=sonnet\\nwriter_lane=\\nreviewer_lane=cross-vendor\\nreviewer_model=gpt-6-sol\\nrouting_status=ok\\n|empty value: writer_lane"; do
  _gname="${_g%%|*}"; _grest="${_g#*|}"; _gbytes="${_grest%|*}"; _gwhy="${_grest##*|}"
  new_case "route-gate-$_gname"
  if route_stub_bytes "$_gbytes"; then
    spy "$C/off" codex
    spy "$C/bin" agy
    run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 ZUVO_REVIEW_TEST_PROVIDERS=agy
    expect_eq "six-key gate ($_gname): exit 0" "0" "$RC"
    expect_eq "six-key gate ($_gname): preflight_status=degraded-routing (model-run refuses this answer too)" \
      "degraded-routing" "$(field preflight_status)"
    expect_has "six-key gate ($_gname): stderr names why" "$_gwhy" "$ERR"
    expect_eq "six-key gate ($_gname): the trailing six lines are the fail-closed sentinel" "routing-failed" "$(field routing_status)"
    spy_not_ran "six-key gate ($_gname) (routing_status never becomes ok, so codex is never prepended)" codex
    spy_ran "six-key gate ($_gname)" agy
    contract "six-key gate ($_gname)"
    tmp_clean "six-key gate ($_gname)"
  else
    critical_setup_fail "six-key gate ($_gname)"
  fi
done
unset _g _gname _grest _gbytes _gwhy

# ── 21i7. ONE value check with model-run (zms_route_values_ok): a well-SHAPED answer (it passes the six-key
# gate above) whose value is outside its enum — writer_lane=turbo — used to pass as routing_status=ok while
# model-run refused the same answer as malformed. It degrades here too, on its own stderr line AFTER the
# specific 1a checks, and the routed client never runs. (An EMPTY value — origin's second probe here — is
# refused earlier, by the six-key gate: 21i6's empty-writer-lane case.)
_pf_case="writer_lane=turbo"
{
  new_case "route-ok-bad-value-${_pf_case#writer_lane=}"
  _pf_d="$C/solo-v-$(printf '%s' "${_pf_case#writer_lane=}" | tr -c 'a-z' 'x')"
  if mkdir -p "$_pf_d" \
     && cp "$PF" "$_pf_d/reviewer-preflight.sh" \
     && cp "$LIB" "$_pf_d/model-subprocess.sh" \
     && { printf '#!/bin/sh\n'
          printf 'cat <<'"'"'ROUTEEOF'"'"'\n'
          printf 'platform=claude\nwriter_model=sonnet\n%s\nreviewer_lane=cross-vendor\nreviewer_model=gpt-6-sol\nrouting_status=ok\n' "$_pf_case"
          printf 'ROUTEEOF\n'
        } > "$_pf_d/reviewer-model-route.sh" \
     && chmod +x "$_pf_d/reviewer-model-route.sh" && install_home_driver
  then
    spy "$C/off" codex
    spy "$C/bin" agy
    run_pf "$_pf_d/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 \
      ZUVO_REVIEW_TEST_PROVIDERS=agy
    expect_eq "[$_pf_case]: exit 0" "0" "$RC"
    expect_eq "[$_pf_case]: preflight_status=degraded-routing (the value check model-run applies)" \
      "degraded-routing" "$(field preflight_status)"
    expect_has "[$_pf_case]: stderr names the value violation" "outside its contract" "$ERR"
    expect_not_has "[$_pf_case]: the six-key SHAPE gate passed it (the value check refused it, in 1a)" "failed the six-key contract" "$ERR"
    spy_not_ran "[$_pf_case] (a broken ok route never runs its client)" codex
    contract "[$_pf_case]"
    tmp_clean "[$_pf_case]"
  else
    critical_setup_fail "[$_pf_case]"
  fi
}
unset _pf_case _pf_d

# ── 21k. Q2: a DUPLICATED reviewer_model= line, alongside a MISSING writer_lane. Structurally
# this already fails the six-key STRUCTURAL gate above (section 1, exactly 6 total lines with
# exactly one of each key) before section 1a is ever reached. This case locks in that end-to-end
# outcome as a regression test; 21k1 below isolates the duplicate alone (S4 — Muse F19 / Byteplus
# F11: this case's own missing writer_lane means it would still pass even if the six-key gate
# started PERMITTING duplicates, since writer_lane's absence alone is enough to fail it — the
# gate's own message is asserted precisely to rule that out).
new_case route-ok-reviewer-model-duplicated
if mkdir -p "$C/solo" \
   && cp "$PF" "$C/solo/reviewer-preflight.sh" \
   && cp "$LIB" "$C/solo/model-subprocess.sh" \
   && cat > "$C/solo/reviewer-model-route.sh" <<'STUBEOF'
#!/bin/sh
printf '%s\n' 'platform=claude' 'writer_model=sonnet' 'reviewer_lane=cross-vendor' 'reviewer_model=gpt-6-sol' 'reviewer_model=claude-opus-5-5' 'routing_status=ok'
STUBEOF
   chmod +x "$C/solo/reviewer-model-route.sh" && install_home_driver
then
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "duplicated reviewer_model: exit 0" "0" "$RC"
  expect_eq "duplicated reviewer_model: preflight_status=degraded-routing (the six-key gate rejects a duplicated key; writer_lane is also missing here, doubly invalid)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "duplicated reviewer_model: stderr names BOTH offending keys, not just the missing one" \
    "writer_lane=0" "$ERR"
  expect_has "duplicated reviewer_model: stderr also names the duplicate itself" \
    "reviewer_model=2" "$ERR"
  expect_eq "duplicated reviewer_model: provider=agy (the panel is still canaried)" "agy" "$(field provider)"
  spy_ran "duplicated reviewer_model" agy
  contract "duplicated reviewer_model"
  tmp_clean "duplicated reviewer_model"
else
  critical_setup_fail "duplicated reviewer_model"
fi

# ── 21k1. S4 (adversarial pass 2, F11 CLAUDE / F16 MUSE / F19 MUSE): the ISOLATED duplicate — all
# six keys present exactly as required, reviewer_model alone appearing TWICE (7 lines total, every
# OTHER key's own count is exactly 1). Unlike 21k above, no key is missing — a future six-key gate
# that started PERMITTING duplicates while still requiring every key present would pass 21k
# (writer_lane is still missing there) but must NOT pass this one. The gate's own message is
# asserted to name reviewer_model=2 specifically, proving THIS case's rejection is attributable to
# the duplicate alone. T11: the exact "got 7 lines" wording is NOT pinned any more (only the
# semantically load-bearing per-key attribution is) — the contract this case locks in is the
# offending KEY, the fail-closed routing status, and that the panel still runs, not the message's
# line-count phrasing.
new_case route-ok-reviewer-model-duplicated-isolated
if mkdir -p "$C/solo" \
   && cp "$PF" "$C/solo/reviewer-preflight.sh" \
   && cp "$LIB" "$C/solo/model-subprocess.sh" \
   && cat > "$C/solo/reviewer-model-route.sh" <<'STUBEOF'
#!/bin/sh
printf '%s\n' 'platform=claude' 'writer_model=sonnet' 'writer_lane=strong_alt' 'reviewer_lane=cross-vendor' 'reviewer_model=gpt-6-sol' 'reviewer_model=claude-opus-5-5' 'routing_status=ok'
STUBEOF
   chmod +x "$C/solo/reviewer-model-route.sh" && install_home_driver
then
  spy "$C/off" codex
  spy "$C/bin" agy
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 \
    ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "duplicated reviewer_model (isolated): exit 0" "0" "$RC"
  expect_eq "duplicated reviewer_model (isolated): preflight_status=degraded-routing — routing_status never became ok, so nothing is ever routed/prepended (fail-closed)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "duplicated reviewer_model (isolated): the message names reviewer_model specifically as the offending key (2 occurrences), not a missing one — every other key is present exactly once" \
    "per-key counts off: reviewer_model=2" "$ERR"
  expect_eq "duplicated reviewer_model (isolated): provider=agy — the panel is still canaried" "agy" "$(field provider)"
  spy_not_ran "duplicated reviewer_model (isolated) (codex would map cleanly from gpt-6-sol were routing_status ever ok, so its absence here proves the fail-closed routing, not merely a missing candidate)" codex
  spy_ran "duplicated reviewer_model (isolated)" agy
  contract "duplicated reviewer_model (isolated)"
  tmp_clean "duplicated reviewer_model (isolated)"
else
  critical_setup_fail "duplicated reviewer_model (isolated)"
fi

# make_wrong_client_mapper <output> — T9: writes a monkey-patched $C/solo/model-subprocess.sh (the
# real library, zms_client_for_model REDEFINED afterward to print <output> unconditionally) plus a
# SOURCED-SIDE-EFFECT MARKER ($C/solo/.lib-sourced-marker, touched unconditionally at source time,
# not only when the function is CALLED) proving preflight genuinely loaded THIS file rather than
# silently falling back to a different candidate. f3-12 REJECTED: the file is sourced with `.`
# (scripts/reviewer-preflight.sh's lib-loading loop: `. "$_pf_lib"`), which reads and executes its
# content in the CURRENT shell without ever calling exec() — the executable bit is irrelevant to a
# dot-source, so this function does not chmod +x the patched copy, proving the claim it needs no
# execute permission by construction (the case still passes without it).
make_wrong_client_mapper() {
  rm -f "$C/solo/.lib-sourced-marker"
  {
    cat "$LIB"
    printf '\ntouch "%s/.lib-sourced-marker"\n' "$C/solo"
    printf 'zms_client_for_model() { printf '"'"'%%s\\n'"'"' %s; }\n' "$(printf '%q' "$1")"
  } > "$C/solo/model-subprocess.sh"
}

# ── 21k2. S2 (adversarial pass 2, F10 BYTEPLUS): ROUTED_CLIENT ends up something OTHER than codex
# or claude. zms_client_for_model's own case arms can never actually produce this today — proven
# by reading them, not assumed — so this is tested via DEPENDENCY INJECTION (make_wrong_client_
# mapper above). T9: the bogus client ("gemini") is ALSO spied this time (a real gemini spy on
# PATH, not merely absent) — without one, spy_not_ran gemini would pass vacuously regardless of
# whether S2 works, since there is nothing anywhere that could ever record an invocation.
new_case route-ok-reviewer-model-wrong-client-mapping
if install_home_driver && write_stub_router 'reviewer_model=gpt-6-sol'; then
  make_wrong_client_mapper gemini
  spy "$C/bin" agy
  spy "$C/bin" gemini
  printf '42\n' > "$C/spy/agy.reply"
  printf '42\n' > "$C/spy/gemini.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "wrong client mapping: exit 0" "0" "$RC"
  expect_eq "wrong client mapping: preflight_status=degraded-routing (mapped to gemini, neither codex nor claude — contract violation)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "wrong client mapping: stderr names the violation" "not codex or claude" "$ERR"
  expect_eq "wrong client mapping: provider=agy (the panel is still canaried; gemini was never prepended)" \
    "agy" "$(field provider)"
  spy_not_ran "wrong client mapping (gemini is now genuinely spied — this proves it, not sandbox starvation)" gemini
  spy_ran "wrong client mapping" agy
  if [ -e "$C/solo/.lib-sourced-marker" ]; then ok "wrong client mapping (T9): preflight sourced the patched library (side-effect marker present)"
  else bad "wrong client mapping (T9): the sourced-library marker is missing — cannot prove preflight loaded the patched model-subprocess.sh"; fi
  contract "wrong client mapping"
  tmp_clean "wrong client mapping"
else
  critical_setup_fail "wrong client mapping"
fi

# ── 21k2b. T9: mapper prints EMPTY. Distinct code path from "unmapped" (21h, where the REAL
# zms_client_for_model genuinely fails) — here the function returns success with a blank line, the
# EARLIER "no client serves..." branch (not S2's "not codex or claude" branch) is what must catch
# it, since ROUTED_CLIENT="" never even reaches the S2 comparison.
new_case route-ok-reviewer-model-wrong-client-mapping-empty
if install_home_driver && write_stub_router 'reviewer_model=gpt-6-sol'; then
  make_wrong_client_mapper ""
  spy "$C/bin" agy
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "wrong client mapping (empty): exit 0" "0" "$RC"
  expect_eq "wrong client mapping (empty): preflight_status=degraded-routing" "degraded-routing" "$(field preflight_status)"
  expect_has "wrong client mapping (empty): stderr names the violation (the earlier 'no client serves' branch, not S2's)" \
    "no client serves reviewer_model=gpt-6-sol" "$ERR"
  expect_eq "wrong client mapping (empty): provider=agy" "agy" "$(field provider)"
  spy_ran "wrong client mapping (empty)" agy
  if [ -e "$C/solo/.lib-sourced-marker" ]; then ok "wrong client mapping (empty) (T9): patched library sourced"
  else bad "wrong client mapping (empty) (T9): sourced-library marker missing"; fi
  contract "wrong client mapping (empty)"
  tmp_clean "wrong client mapping (empty)"
else
  critical_setup_fail "wrong client mapping (empty)"
fi

# ── 21k2c. T9: mapper prints "codex " — a TRAILING SPACE, not the exact literal `codex`. Proves
# S2's comparison is exact-string, not a prefix/trim match.
new_case route-ok-reviewer-model-wrong-client-mapping-trailing-space
if install_home_driver && write_stub_router 'reviewer_model=gpt-6-sol'; then
  make_wrong_client_mapper "codex "
  spy "$C/bin" agy
  spy "$C/off" codex
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "wrong client mapping (trailing space): exit 0" "0" "$RC"
  expect_eq "wrong client mapping (trailing space): preflight_status=degraded-routing ('codex ' is not the exact literal codex)" \
    "degraded-routing" "$(field preflight_status)"
  expect_has "wrong client mapping (trailing space): stderr names the violation" "not codex or claude" "$ERR"
  expect_eq "wrong client mapping (trailing space): provider=agy" "agy" "$(field provider)"
  spy_not_ran "wrong client mapping (trailing space) (the codex spy, pinned and available, must never run for a mapped value that is not the exact literal codex)" codex
  spy_ran "wrong client mapping (trailing space)" agy
  if [ -e "$C/solo/.lib-sourced-marker" ]; then ok "wrong client mapping (trailing space) (T9): patched library sourced"
  else bad "wrong client mapping (trailing space) (T9): sourced-library marker missing"; fi
  contract "wrong client mapping (trailing space)"
  tmp_clean "wrong client mapping (trailing space)"
else
  critical_setup_fail "wrong client mapping (trailing space)"
fi

# ── 21k2d. T9: mapper prints a MULTI-LINE value ("codex\nclaude"). Command substitution preserves
# embedded newlines (only trailing ones are stripped), so ROUTED_CLIENT could genuinely hold this;
# S2's exact `!= codex` / `!= claude` comparisons both correctly reject a multi-line string.
new_case route-ok-reviewer-model-wrong-client-mapping-multiline
if install_home_driver && write_stub_router 'reviewer_model=gpt-6-sol'; then
  make_wrong_client_mapper "$(printf 'codex\nclaude')"
  spy "$C/bin" agy
  spy "$C/off" codex
  spy "$C/off" claude
  printf '42\n' > "$C/spy/agy.reply"
  run_pf "$C/solo/reviewer-preflight.sh" ZUVO_CODEX_BIN="$C/off/codex" ZUVO_CLAUDE_BIN="$C/off/claude" \
    ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "wrong client mapping (multiline): exit 0" "0" "$RC"
  expect_eq "wrong client mapping (multiline): preflight_status=degraded-routing" "degraded-routing" "$(field preflight_status)"
  expect_has "wrong client mapping (multiline): stderr names the violation" "not codex or claude" "$ERR"
  expect_eq "wrong client mapping (multiline): provider=agy" "agy" "$(field provider)"
  spy_not_ran "wrong client mapping (multiline) (neither line of the multi-line mapping is a candidate)" codex
  spy_not_ran "wrong client mapping (multiline)" claude
  spy_ran "wrong client mapping (multiline)" agy
  if [ -e "$C/solo/.lib-sourced-marker" ]; then ok "wrong client mapping (multiline) (T9): patched library sourced"
  else bad "wrong client mapping (multiline) (T9): sourced-library marker missing"; fi
  contract "wrong client mapping (multiline)"
  tmp_clean "wrong client mapping (multiline)"
else
  critical_setup_fail "wrong client mapping (multiline)"
fi

# ── 21l. Quality-review INFO gap: isolate the OUTER `ROUTING_STATUS = ok` gate itself. A mutant
# that removed/neutered just that condition produced 0 failures across the whole suite before this
# case existed, because every other case pairs routing_status=ok with a reviewer_model that would
# ALSO fail one of the Q1-Q3 checks (or pairs a non-ok status with an unroutable reviewer_model) —
# none of them isolate "routing_status says NOT ok, yet everything else about reviewer_model would
# otherwise validate cleanly". This case does: routing_status=cross-vendor-unavailable (not ok),
# reviewer_model=gpt-6-sol (a perfectly valid, cleanly-mapping id — codex is even available here,
# via a pinned spy). If the outer gate were bypassed, ROUTED_CLIENT would still resolve to codex
# and get prepended/canaried; the outer verdict switch is a SEPARATE piece of code from section 1a
# and would still correctly report degraded-routing regardless (routing_status isn't ok), so the
# discriminating assertions are provider/spy, not preflight_status.
#
# T8 (adversarial pass 3, f3-2): runs under jail_no_ambient_clients ($C/sys, built above from
# T_SYS's own recipe) instead of the ambient PATH tail, so an ambient `codex` on /usr/bin:/bin
# cannot make spy_not_ran vacuous here even if the suite's global precondition somehow stopped
# holding for this one later case.
new_case route-first-ok-gate-isolated
jail_no_ambient_clients
if mkdir -p "$C/solo" "$C/home/.zuvo" \
   && cp "$PF" "$C/solo/reviewer-preflight.sh" \
   && cp "$LIB" "$C/solo/model-subprocess.sh" \
   && cp "$REGISTRY" "$C/home/.zuvo/model-registry.sh" \
   && cat > "$C/solo/reviewer-model-route.sh" <<'STUBEOF'
#!/bin/sh
printf '%s\n' 'platform=claude' 'writer_model=sonnet' 'writer_lane=strong_alt' 'reviewer_lane=review-alt' 'reviewer_model=gpt-6-sol' 'routing_status=cross-vendor-unavailable'
STUBEOF
   chmod +x "$C/solo/reviewer-model-route.sh" && install_home_driver
then
  spy "$C/off" codex
  spy "$C/bin" agy
  run_pf "$C/solo/reviewer-preflight.sh" "PATH=$C/bin:$C/sys" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 \
    ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "ok-gate isolated: exit 0" "0" "$RC"
  expect_eq "ok-gate isolated: preflight_status=degraded-routing (routing_status is not ok)" \
    "degraded-routing" "$(field preflight_status)"
  expect_eq "ok-gate isolated: provider=agy — the panel's own candidate; codex must never be prepended when routing_status != ok, however cleanly reviewer_model would otherwise map" \
    "agy" "$(field provider)"
  spy_not_ran "ok-gate isolated (codex must not run — routing_status is not ok)" codex
  spy_ran "ok-gate isolated" agy
  contract "ok-gate isolated"
  tmp_clean "ok-gate isolated"
else
  critical_setup_fail "ok-gate isolated"
fi

# ── 21l2. T3 (adversarial pass 3, f3-6/f3-7/f3-8): rerun 21l's EXACT case, with a different name,
# after several sibling cases (each of which writes its OWN $C/home/.zuvo/model-registry.sh under
# ITS OWN $C) — proves per-case isolation empirically, not just by architecture: since $C = $T/
# <case-name> is a fresh directory keyed by the case NAME, no sibling's registry copy, stub, or
# .lib-sourced-marker can leak into this rerun, and the rerun gets the SAME verdict as the original.
new_case route-first-ok-gate-isolated-rerun
jail_no_ambient_clients
if mkdir -p "$C/solo" "$C/home/.zuvo" \
   && cp "$PF" "$C/solo/reviewer-preflight.sh" \
   && cp "$LIB" "$C/solo/model-subprocess.sh" \
   && cp "$REGISTRY" "$C/home/.zuvo/model-registry.sh" \
   && cat > "$C/solo/reviewer-model-route.sh" <<'STUBEOF'
#!/bin/sh
printf '%s\n' 'platform=claude' 'writer_model=sonnet' 'writer_lane=strong_alt' 'reviewer_lane=review-alt' 'reviewer_model=gpt-6-sol' 'routing_status=cross-vendor-unavailable'
STUBEOF
   chmod +x "$C/solo/reviewer-model-route.sh" && install_home_driver
then
  spy "$C/off" codex
  spy "$C/bin" agy
  run_pf "$C/solo/reviewer-preflight.sh" "PATH=$C/bin:$C/sys" ZUVO_CODEX_BIN="$C/off/codex" SPY_REPLY=42 \
    ZUVO_REVIEW_TEST_PROVIDERS=agy
  expect_eq "ok-gate isolated rerun (T3): exit 0, same as the original" "0" "$RC"
  expect_eq "ok-gate isolated rerun (T3): preflight_status=degraded-routing, same as the original — no sibling leaked in" \
    "degraded-routing" "$(field preflight_status)"
  expect_eq "ok-gate isolated rerun (T3): provider=agy, same as the original" "agy" "$(field provider)"
  spy_not_ran "ok-gate isolated rerun (T3)" codex
  spy_ran "ok-gate isolated rerun (T3)" agy
  contract "ok-gate isolated rerun"
  tmp_clean "ok-gate isolated rerun"
  rm -f "$C/home/.zuvo/model-registry.sh"
else
  critical_setup_fail "ok-gate isolated rerun"
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

assert_result
