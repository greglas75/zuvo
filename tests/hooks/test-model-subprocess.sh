#!/usr/bin/env bash
#
# test-model-subprocess.sh — the shared reviewer-subprocess library, scripts/lib/model-subprocess.sh.
#
# Why this library exists: three scripts each carried their own copy of "find and run a Codex /
# Claude CLI". The adversarial driver checks FOUR Codex host signals, the router ONE; the driver
# falls back to /Applications/Codex.app, the preflight does not; the blind-audit wrapper ran codex
# with the user's global CODEX_HOME and died with it when the required `codesift` MCP daemon hung
# (2026-09-25). This file pins the library's core so every consumer gets the same answer:
#
#   * host detection   — the four Codex signals, and the TOP-LEVEL model of config.toml only
#   * client resolution — ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN are test seams AND final when set;
#                         without that, /Applications/Codex.app makes a missing codex unfakeable
#   * the registry     — sibling-first, and a `..` path is only trusted inside a real repo layout
#   * the auth-stub and CLI-version guard, lifted from the driver and checked AGAINST the driver
#   * the isolated runners (none / read / agent) — flag sets decided by the live probes P1/P2/P3/P6
#     (zuvo/proofs/probe-*-2026-09-25.txt); `agent` reproduces the adversarial driver's flags
#     literally, which is the contract the driver refactor relies on
#
# Hermetic: every probe runs in `env -i` with a temp HOME, a fixture CODEX_HOME holding a DUMMY
# auth.json, ZUVO_CODEX_APP_BIN=/nonexistent unless the case is about the app fallback, and an
# explicit PATH. No real model CLI is ever executed — the Codex app on this Mac included.
#
# Run under both shells (bash 3.2 is macOS's /bin/bash):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/test-model-subprocess.sh
#   TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/test-model-subprocess.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
LIB="$ROOT/scripts/lib/model-subprocess.sh"
ADV="$ROOT/scripts/adversarial-review.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
expect_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
expect_has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — [$2] not found in [$3]" ;; esac; }
# fmode <path> — octal permission bits. GNU `stat -c` FIRST: GNU's `stat -f` means filesystem
# status and prints to stdout before it fails, so BSD's form must be the fallback, not the probe.
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# poll <seconds> <command...> — run <command> every 0.5 s until it succeeds; status 1 once <seconds>
# have passed without success. Every wait on a process in this file goes through here: a bare
# `wait` on a runner that hangs would hang the suite with it.
poll() { local n=$(( $1 * 2 )) i=0; shift; until "$@"; do [ "$i" -lt "$n" ] || return 1; sleep 0.5; i=$((i+1)); done; }
gone() { ! kill -0 "$1" 2>/dev/null; }
# no_proc <pattern> — true ONLY when pgrep ran and matched nothing (status 1). Fails closed: with no
# pgrep, `! pgrep` was "no process" and every survival check passed vacuously; 2/3 are pgrep errors.
no_proc() { command -v pgrep >/dev/null 2>&1 || return 1; pgrep -f "$1" >/dev/null 2>&1; [ $? -eq 1 ]; }
# wait_gone <pid> <seconds> — bounded wait for a background job: 0 once it has exited (then reaped,
# which cannot block any more), 1 when it is still running at the deadline.
wait_gone() { poll "$2" gone "$1" || return 1; wait "$1" 2>/dev/null; return 0; }

echo "== model-subprocess library (bash $BASH_VERSION) =="

# ── hermetic sandbox ─────────────────────────────────────────────────────────
T="$(mktemp -d)" || { echo "  FAIL mktemp -d failed" >&2; exit 1; }
[ -n "$T" ] && [ -d "$T" ] || { echo "  FAIL mktemp -d returned an empty path or no directory" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
# Resolved (macOS /var → /private/var) because the library returns resolved paths. Guarded: an
# empty $T here would turn every "$T/…" below into a path at the filesystem root.
T="$(cd "$T" && pwd -P)" && [ -n "$T" ] || { echo "  FAIL cannot resolve the sandbox path" >&2; exit 1; }
# Without pgrep, no_proc / the leftover checks see "no process" and every survival assertion passes
# vacuously; without shasum, both sides of every sha comparison are empty and compare equal.
for _tool in pgrep shasum; do
  command -v "$_tool" >/dev/null 2>&1 \
    || { echo "  FAIL $_tool required — survival/sha assertions would pass vacuously" >&2; exit 1; }
done

SPY_BIN="$T/bin"; mkdir -p "$SPY_BIN"
# Real coreutils resolved BEFORE the PATH is narrowed (Quality Strategy: the narrowed PATH must
# still hold timeout/jq, or a consumer would exit before anything under test runs).
for _tool in timeout gtimeout jq; do
  _real="$(command -v "$_tool" 2>/dev/null || true)"
  [ -n "$_real" ] && ln -s "$_real" "$SPY_BIN/$_tool"
done
HOMEDIR="$T/home"; mkdir -p "$HOMEDIR/.zuvo"
FIX_CODEX_HOME="$T/codex-home"; mkdir -p "$FIX_CODEX_HOME"
printf '{"OPENAI_API_KEY":null,"tokens":{"access_token":"DUMMY-NOT-A-TOKEN"}}\n' > "$FIX_CODEX_HOME/auth.json"
BASE_PATH="$SPY_BIN:/usr/bin:/bin"

# zrun_lib <lib> <snippet> [VAR=value ...] — run <snippet> in a FRESH `bash -euo pipefail` that has
# sourced <lib> and sees ONLY the hermetic environment (+ the given overrides). Strict mode on
# purpose: the router and the driver source this library under `set -euo pipefail`, so a helper
# that trips -e or -u would abort them. Stdout is the result; stderr goes to $T/zrun.err.
zrun_lib() {
  local lib="$1" snippet="$2"; shift 2
  env -i HOME="$HOMEDIR" ZUVO_HOME="$HOMEDIR/.zuvo" CODEX_HOME="$FIX_CODEX_HOME" \
    ZUVO_CODEX_APP_BIN=/nonexistent PATH="$BASE_PATH" "$@" \
    "$BASH" -euo pipefail -c '. "$1"; eval "$2"' _ "$lib" "$snippet" 2>"$T/zrun.err"
}
zrun() { local snippet="$1"; shift; zrun_lib "$LIB" "$snippet" "$@"; }

ZMS_FUNCS="zms_is_codex_host zms_codex_host_model zms_codex_bin zms_claude_bin zms_client_available zms_client_for_model zms_source_registry zms_is_auth_stub zms_codex_cli_guard zms_codex_home zms_run_codex zms_run_claude"

# ── 1. sourcing: no externals, every function defined, caller options untouched ──
echo "-- 1. sourcing"
# shellcheck disable=SC2016  # the single-quoted script expands in the child shell, by design
out="$(env -i PATH=/nonexistent /bin/bash -c '. "$1" || exit 9; for f in $2; do declare -F "$f" >/dev/null || echo "MISSING $f"; done' _ "$LIB" "$ZMS_FUNCS" 2>&1)"; rc=$?
expect_eq "sources under env -i PATH=/nonexistent /bin/bash: exit 0" "0" "$rc"
expect_eq "…and defines every zms_* function with nothing on stdout/stderr" "" "$out"

# A PATH made only of spies for the usual externals: if sourcing ran ANY of them, the log fills.
EXT_DIR="$T/extspy"; mkdir -p "$EXT_DIR"
for _tool in sed grep awk cat head tail wc dirname basename mktemp uname tr cut date readlink realpath ls id cp mv rm mkdir chmod env timeout gtimeout jq codex claude python3 sh; do
  printf '#!/bin/sh\necho %s >> "$EXT_LOG"\n' "$_tool" > "$EXT_DIR/$_tool"
  chmod +x "$EXT_DIR/$_tool"
done
env -i PATH="$EXT_DIR" EXT_LOG="$T/ext-called" "$BASH" -c '. "$1"' _ "$LIB" >/dev/null 2>&1; rc=$?
expect_eq "sources with a PATH of spy externals: exit 0" "0" "$rc"
if [ -e "$T/ext-called" ]; then bad "sourcing executed external commands: $(tr '\n' ' ' < "$T/ext-called")"
else ok "sourcing executed no external command"; fi

# shellcheck disable=SC2016
out="$(env -i PATH=/nonexistent "$BASH" -c 'a="$(set +o)"; . "$1"; . "$1"; b="$(set +o)"; [ "$a" = "$b" ] && echo same' _ "$LIB" 2>&1)"
expect_eq "sourcing twice leaves the caller's shell options untouched (plain caller)" "same" "$out"
# shellcheck disable=SC2016
out="$(env -i PATH=/nonexistent "$BASH" -euo pipefail -c 'a="$(set +o)"; . "$1"; b="$(set +o)"; [ "$a" = "$b" ] && echo same' _ "$LIB" 2>&1)"
expect_eq "sourcing under set -euo pipefail leaves the options untouched and does not abort" "same" "$out"

# ── 2. zms_is_codex_host: the four signals, each alone ────────────────────────
echo "-- 2. Codex host detection"
HOSTQ='if zms_is_codex_host; then echo HOST; else echo NOT; fi'
expect_eq "CODEX_SANDBOX=seatbelt alone → host" "HOST" "$(zrun "$HOSTQ" CODEX_SANDBOX=seatbelt)"
expect_eq "CODEX_INTERNAL_ORIGINATOR_OVERRIDE='Codex Desktop' alone → host" "HOST" "$(zrun "$HOSTQ" 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop')"
expect_eq "CODEX_SHELL=1 alone → host" "HOST" "$(zrun "$HOSTQ" CODEX_SHELL=1)"
expect_eq "__CFBundleIdentifier=com.openai.codex alone → host" "HOST" "$(zrun "$HOSTQ" __CFBundleIdentifier=com.openai.codex)"
expect_eq "all signals cleared → not a host" "NOT" "$(zrun "$HOSTQ")"
expect_eq "CODEX_SANDBOX set but empty → not a host" "NOT" "$(zrun "$HOSTQ" CODEX_SANDBOX=)"
expect_eq "CODEX_SHELL=0 → not a host (exact value 1)" "NOT" "$(zrun "$HOSTQ" CODEX_SHELL=0)"
expect_eq "another originator → not a host" "NOT" "$(zrun "$HOSTQ" CODEX_INTERNAL_ORIGINATOR_OVERRIDE=codex_cli_rs)"
expect_eq "another bundle id → not a host" "NOT" "$(zrun "$HOSTQ" __CFBundleIdentifier=com.apple.Terminal)"
expect_eq "ZUVO_CODEX_MODEL alone is the router's extra hint, not a host signal" "NOT" "$(zrun "$HOSTQ" ZUVO_CODEX_MODEL=gpt-6-sol)"
expect_eq "CODEX_MODEL alone is not a host signal (the driver never treated it as one)" "NOT" "$(zrun "$HOSTQ" CODEX_MODEL=gpt-6-sol)"

# ── 3. zms_codex_host_model: CODEX_MODEL, else the TOP-LEVEL model= of config.toml ──
echo "-- 3. Codex host model"
MODELQ='if m="$(zms_codex_host_model)"; then echo "known:$m"; else echo "unknown:[$m]"; fi'
cat > "$FIX_CODEX_HOME/config.toml" <<'EOF'
# the active model is the top-level key; tables below must not count
model = "gpt-6-sol"
model_reasoning_effort = "high"

[profiles.fast]
model = "decoy-profile-model"
EOF
expect_eq "top-level model= wins over a later [profiles.x] model= decoy" "known:gpt-6-sol" "$(zrun "$MODELQ")"
expect_eq "CODEX_MODEL wins over config.toml" "known:gpt-5.3-spark" "$(zrun "$MODELQ" CODEX_MODEL=gpt-5.3-spark)"
cat > "$FIX_CODEX_HOME/config.toml" <<'EOF'
approval_policy = "never"
  [profiles.fast]
model = "decoy-only"
EOF
expect_eq "a model= only under an (indented) table header is NOT the host model" "unknown:[]" "$(zrun "$MODELQ")"
printf 'model_reasoning_effort = "high"\nmodel=gpt-5.3-spark' > "$FIX_CODEX_HOME/config.toml"
expect_eq "unquoted value on a last line without newline; model_reasoning_effort is not model" "known:gpt-5.3-spark" "$(zrun "$MODELQ")"
rm -f "$FIX_CODEX_HOME/config.toml"
expect_eq "no config.toml → unknown, non-zero, nothing printed" "unknown:[]" "$(zrun "$MODELQ")"
mkdir -p "$HOMEDIR/.codex"; printf 'model = "home-default-model"\n' > "$HOMEDIR/.codex/config.toml"
expect_eq "CODEX_HOME unset → \$HOME/.codex/config.toml" "known:home-default-model" "$(zrun "unset CODEX_HOME; $MODELQ")"
expect_eq "HOME and CODEX_HOME both unset → unknown, no set -u abort" "unknown:[]" "$(zrun "unset CODEX_HOME HOME; $MODELQ")"
rm -rf "$HOMEDIR/.codex"

# Parity with the driver's own expression (adversarial-review.sh:~1368 as of 3cc29f7f): the library
# reads config.toml in pure bash so it also works with no PATH at all; it must agree line for line.
DRIVER_SED='/^[[:space:]]*\[/q; s/^[[:space:]]*model[[:space:]]*=[[:space:]]*"\{0,1\}\([^"#]*\)"\{0,1\}.*/\1/p'
parity_i=0
for _cfg in 'model = "gpt-6-sol"' '  model="gpt-5.5"   # host' 'model = gpt-6 # c' 'model = ""
model = "second"' 'x = 1
[t]
model = "decoy"' 'model_reasoning_effort = "high"' "model = 'single'"; do
  parity_i=$((parity_i+1))
  printf '%s\n' "$_cfg" > "$FIX_CODEX_HOME/config.toml"
  want="$(sed -n "$DRIVER_SED" "$FIX_CODEX_HOME/config.toml" 2>/dev/null | head -1)"
  got="$(zrun 'zms_codex_host_model || true')"
  expect_eq "config parity #$parity_i with the driver's sed" "$want" "$got"
done
rm -f "$FIX_CODEX_HOME/config.toml"

# ── 4. client resolution: seams, finality, the app fallback — never executing a client ──
echo "-- 4. client resolution"
mk_sentinel() { # mk_sentinel <path> — a fake client that records it was EXECUTED
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\ntouch "%s/invoked"\necho SHOULD-NOT-RUN\n' "$T" > "$1"
  chmod +x "$1"
}
mk_sentinel "$T/offpath/codex"; mk_sentinel "$T/offpath/claude"
mk_sentinel "$T/onpath/codex";  mk_sentinel "$T/onpath/claude"; mk_sentinel "$T/onpath/agy"
mk_sentinel "$T/onpath/codex-alt"
mk_sentinel "$T/app/codex"
printf '#!/bin/sh\n' > "$T/app/not-exec"   # present but NOT executable
AVQ='if zms_client_available "$1"; then echo yes; else echo no; fi'
BINQ='if b="$(zms_codex_bin)"; then echo "bin:$b"; else echo "none:[$b]"; fi'
CLQ='if b="$(zms_claude_bin)"; then echo "bin:$b"; else echo "none:[$b]"; fi'
avail() { # avail <client> [VAR=value ...]
  local c="$1"; shift
  zrun "set -- $c; $AVQ" "$@"
}

expect_eq "ZUVO_CODEX_BIN off PATH → zms_codex_bin returns it" "bin:$T/offpath/codex" "$(zrun "$BINQ" ZUVO_CODEX_BIN="$T/offpath/codex")"
expect_eq "ZUVO_CODEX_BIN off PATH → codex available" "yes" "$(avail codex ZUVO_CODEX_BIN="$T/offpath/codex")"
expect_eq "ZUVO_CODEX_BIN=/nonexistent + ZUVO_CODEX_APP_BIN=/nonexistent → unavailable" "no" "$(avail codex ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent)"
expect_eq "…and zms_codex_bin fails with nothing on stdout" "none:[]" "$(zrun "$BINQ" ZUVO_CODEX_BIN=/nonexistent)"
[ -x /Applications/Codex.app/Contents/Resources/codex ] \
  && echo "  note: /Applications/Codex.app is installed here — the next case really exercises finality" \
  || echo "  note: no /Applications/Codex.app here — finality is also proven by the fake-app case below"
expect_eq "a SET ZUVO_CODEX_BIN is final: /nonexistent, APP_BIN unset (default path), codex on PATH → unavailable" \
  "no" "$(avail codex ZUVO_CODEX_BIN=/nonexistent PATH="$T/onpath:$BASE_PATH")"
# The zrun env always sets ZUVO_CODEX_APP_BIN; unset it inside to reach the built-in default path.
expect_eq "…same with ZUVO_CODEX_APP_BIN truly unset inside the shell" \
  "no" "$(zrun "unset ZUVO_CODEX_APP_BIN; set -- codex; $AVQ" ZUVO_CODEX_BIN=/nonexistent PATH="$T/onpath:$BASE_PATH")"
expect_eq "a SET ZUVO_CODEX_BIN is final even with an executable fake app and codex on PATH" \
  "no" "$(avail codex ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN="$T/app/codex" PATH="$T/onpath:$BASE_PATH")"
expect_eq "ZUVO_CODEX_BIN unset: PATH codex wins over the app bundle" "bin:$T/onpath/codex" \
  "$(zrun "$BINQ" ZUVO_CODEX_APP_BIN="$T/app/codex" PATH="$T/onpath:$BASE_PATH")"
expect_eq "app fallback preserved: no seam, no PATH codex, APP_BIN=fake → the fake" "bin:$T/app/codex" \
  "$(zrun "$BINQ" ZUVO_CODEX_APP_BIN="$T/app/codex")"
expect_eq "…and codex is available through the app" "yes" "$(avail codex ZUVO_CODEX_APP_BIN="$T/app/codex")"
expect_eq "no seam, no PATH codex, APP_BIN=/nonexistent → unavailable" "no" "$(avail codex)"
expect_eq "an app path that is not executable does not count" "no" "$(avail codex ZUVO_CODEX_APP_BIN="$T/app/not-exec")"
expect_eq "ZUVO_CODEX_APP_BIN set EMPTY disables the app fallback (not the default path)" "none:[]" \
  "$(zrun "$BINQ" ZUVO_CODEX_APP_BIN=)"
expect_eq "ZUVO_CODEX_BIN set EMPTY counts as unset → PATH codex" "bin:$T/onpath/codex" \
  "$(zrun "$BINQ" ZUVO_CODEX_BIN= PATH="$T/onpath:$BASE_PATH")"
expect_eq "ZUVO_CODEX_BIN pointing at a directory → unavailable" "no" "$(avail codex ZUVO_CODEX_BIN="$T")"
expect_eq "a RELATIVE ZUVO_CODEX_BIN is returned ABSOLUTE (runners change directory)" "bin:$T/offpath/codex" \
  "$(zrun "cd '$T'; $BINQ" ZUVO_CODEX_BIN=offpath/codex)"
expect_eq "a bare-name ZUVO_CODEX_BIN is resolved on PATH" "bin:$T/onpath/codex-alt" \
  "$(zrun "$BINQ" ZUVO_CODEX_BIN=codex-alt PATH="$T/onpath:$BASE_PATH")"
expect_eq "ZUVO_CLAUDE_BIN off PATH → zms_claude_bin returns it" "bin:$T/offpath/claude" "$(zrun "$CLQ" ZUVO_CLAUDE_BIN="$T/offpath/claude")"
expect_eq "ZUVO_CLAUDE_BIN off PATH → claude available" "yes" "$(avail claude ZUVO_CLAUDE_BIN="$T/offpath/claude")"
expect_eq "a SET ZUVO_CLAUDE_BIN is final: /nonexistent with claude on PATH → unavailable" "no" \
  "$(avail claude ZUVO_CLAUDE_BIN=/nonexistent PATH="$T/onpath:$BASE_PATH")"
expect_eq "no seam → claude from PATH" "bin:$T/onpath/claude" "$(zrun "$CLQ" PATH="$T/onpath:$BASE_PATH")"
expect_eq "no seam, no claude on PATH → unavailable" "no" "$(avail claude)"
expect_eq "any other client (agy) is decided by PATH: present" "yes" "$(avail agy PATH="$T/onpath:$BASE_PATH")"
expect_eq "any other client (agy) is decided by PATH: absent" "no" "$(avail agy)"
out="$(zrun 'rc=0; zms_client_available "" || rc=$?; echo "rc=$rc"')"
expect_eq "zms_client_available with no client name → usage error rc=2" "rc=2" "$out"
expect_has "…and says why on stderr" "client name required" "$(cat "$T/zrun.err")"
if [ -e "$T/invoked" ]; then bad "a client was EXECUTED during resolution/availability checks"
else ok "no client was executed by any resolution/availability check (decided by -x / PATH lookup only)"; fi

# ── 5. zms_client_for_model ──────────────────────────────────────────────────
echo "-- 5. client for model"
FORQ='if c="$(zms_client_for_model "$1")"; then echo "$c"; else echo "none"; fi'
for _pair in gpt-6-sol:codex gpt-5.6-luna:codex o3:codex o4-mini:codex codex-mini-latest:codex \
             claude-opus-5-5:claude opus:claude sonnet:claude haiku:claude claude-haiku-4-5-20251001:claude \
             gemini-3:none gpt-oss-120b:none openai/gpt-oss-120b:none kimi-code/k3:none opal:none :none; do
  _m="${_pair%:*}"; _want="${_pair##*:}"
  expect_eq "model [$_m] → $_want" "$_want" "$(zrun "set -- '$_m'; $FORQ")"
done

# ── 6. zms_source_registry: sibling first, guarded `..`, then ~/.zuvo ─────────
echo "-- 6. registry lookup"
printf 'ZUVO_SENTINEL=1\nZUVO_CODEX_EFFORT_AUDIT=from-home-sentinel\n' > "$HOMEDIR/.zuvo/model-registry.sh"
REGQ='rc=0; zms_source_registry || rc=$?; echo "rc=$rc S=${ZUVO_SENTINEL:-} P=${ZUVO_PLANTED:-} A=${ZUVO_CODEX_EFFORT_AUDIT:-} F=${ZMS_REGISTRY_FILE:-}"'
out="$(zrun "$REGQ")"
expect_has "repo library loads the REPO registry, not the ~/.zuvo sentinel" "rc=0 S= P= A=high " "$out"
expect_has "…and reports which file it loaded" "shared/includes/model-registry.sh" "$out"
expect_eq "ZUVO_CODEX_EFFORT_AUDIT keeps a caller override" "medium" \
  "$(zrun 'zms_source_registry; echo "$ZUVO_CODEX_EFFORT_AUDIT"' ZUVO_CODEX_EFFORT_AUDIT=medium)"
mkdir -p "$T/flat"; cp "$LIB" "$T/flat/model-subprocess.sh"
expect_eq "library installed flat (~/.zuvo layout) → falls back to \$HOME/.zuvo/model-registry.sh" \
  "rc=0 S=1 P= A=from-home-sentinel F=$HOMEDIR/.zuvo/model-registry.sh" "$(zrun_lib "$T/flat/model-subprocess.sh" "$REGQ")"
# A `..` path escapes the install root; it is only trusted inside a real repo/cache layout.
mkdir -p "$T/plant/scripts/lib" "$T/plant/shared/includes"; cp "$LIB" "$T/plant/scripts/lib/model-subprocess.sh"
printf 'ZUVO_PLANTED=1\n' > "$T/plant/shared/includes/model-registry.sh"
expect_has "a planted ../../shared/includes registry WITHOUT a skills/ dir is ignored" "rc=0 S=1 P= " \
  "$(zrun_lib "$T/plant/scripts/lib/model-subprocess.sh" "$REGQ")"
mkdir -p "$T/plant/skills"
expect_has "…and the same layout WITH skills/ (a real repo/cache tree) is used first" "rc=0 S= P=1 " \
  "$(zrun_lib "$T/plant/scripts/lib/model-subprocess.sh" "$REGQ")"
rm -f "$HOMEDIR/.zuvo/model-registry.sh"
expect_eq "no registry anywhere → rc=1, nothing loaded" "rc=1 S= P= A= F=" "$(zrun_lib "$T/flat/model-subprocess.sh" "$REGQ")"

# ── 7. zms_is_auth_stub agrees with the driver's is_auth_failure_output ──────
echo "-- 7. auth-stub detection (differential against the driver)"
AF="$T/auth"; mkdir -p "$AF"
printf 'Not logged in · Please run /login\n' > "$AF/claude-stub.txt"
printf "Error: Not logged in. Please run 'codex login'\n" > "$AF/codex-stub.txt"
{ echo "SEVERITY: WARNING"; echo "ISSUE: the unauthorized branch returns 200"; i=0
  while [ $i -lt 40 ]; do echo "FILE: src/auth/guard.ts:$i — a real review line discussing the login flow"; i=$((i+1)); done
} > "$AF/review-2k.txt"
: > "$AF/empty.txt"
# Short, non-empty and token-free: the ONLY file fixture that reaches the file branch's final grep
# and must come back "not". Without it, a file branch whose grep always succeeded passed every case.
printf 'SEVERITY: INFO\nISSUE: no defects found in the reviewed diff\n' > "$AF/short-clean.txt"
pad_to() { # pad_to <bytes> <file> — 'unauthorized' followed by x's, exactly <bytes> long
  local n=$(( $1 - 12 )); { printf 'unauthorized'; printf '%*s' "$n" '' | tr ' ' x; } > "$2"
}
pad_to 599 "$AF/599.txt"; pad_to 600 "$AF/600.txt"; pad_to 601 "$AF/601.txt"
S600="$(cat "$AF/600.txt")"; S601="$(cat "$AF/601.txt")"
DIFFQ='eval "$(sed -n "/^is_auth_failure_output()/,/^}/p" "$ADV")"
declare -F is_auth_failure_output >/dev/null || { echo "NO-DRIVER-FUNCTION"; exit 0; }
if zms_is_auth_stub "$1"; then l=stub; else l=not; fi
if is_auth_failure_output "$1"; then d=stub; else d=not; fi
echo "$l/$d"'
stub_case() { # stub_case <description> <expected stub|not> <file-or-string>
  expect_eq "$1" "$2/$2" "$(zrun "set -- \"\$ARG\"; $DIFFQ" ADV="$ADV" ARG="$3")"
}
stub_case "claude 'Not logged in' file → stub (lib = driver)" stub "$AF/claude-stub.txt"
stub_case "codex 'Not logged in … codex login' file → stub (lib = driver)" stub "$AF/codex-stub.txt"
stub_case "short login_required STRING → stub (lib = driver)" stub "login_required"
stub_case "a 2 KB real review mentioning 'unauthorized' → not a stub (length guard)" not "$AF/review-2k.txt"
stub_case "empty file → not a stub" not "$AF/empty.txt"
stub_case "short non-empty file with NO auth token → not a stub (file branch's grep decides)" not "$AF/short-clean.txt"
stub_case "empty string → not a stub" not ""
stub_case "599-byte file with a token → stub (under the 600 B guard)" stub "$AF/599.txt"
stub_case "600-byte file with a token → stub (boundary is inclusive)" stub "$AF/600.txt"
stub_case "601-byte file with a token → not a stub" not "$AF/601.txt"
stub_case "600-char STRING with a token → stub" stub "$S600"
stub_case "601-char STRING with a token → not a stub" not "$S601"
stub_case "a path that does not exist is judged as a string" not "/nonexistent/auth-output.txt"
# Agreement only: codex's bare hint carries none of the listed tokens, so BOTH say "not". Kept so the
# lifted copy cannot drift from the driver silently — widening the token list is a separate change.
stub_case "bare \"Please run 'codex login'\" → both 'not' (agreement, token list unchanged)" not "Please run 'codex login'"
# Library only — a deliberate divergence: the driver's copy hands the path to grep unprotected, so a
# relative path starting with '-' is parsed as grep OPTIONS (BSD and GNU grep both permute) and a
# real auth stub comes back "not a stub" with an error on stderr. Fixed here; the driver delegates
# to this function later (plan Task 4), which fixes it there too.
cp "$AF/claude-stub.txt" "$AF/-dash-stub.txt"
expect_eq "a relative path starting with '-' is read as a FILE, not as grep options → stub" "stub" \
  "$(zrun "cd '$AF'; if zms_is_auth_stub -dash-stub.txt; then echo stub; else echo not; fi")"
expect_eq "…and grep printed nothing on stderr" "" "$(cat "$T/zrun.err")"

# A file the file branch cannot READ (exists, non-empty, passes -s, but wc/grep hit EACCES): the
# `wc -c < "$src"` redirection fails, which — called exactly the way every stub_case above calls it,
# `if zms_is_auth_stub …; then … fi` — does not abort the caller (set -e is suspended while a
# compound command evaluates its condition) but DOES leak "Permission denied" onto stderr from the
# failed redirection and, unguarded, from the grep that follows it. Root can still read a 000 file,
# so this case is skipped there instead of asserting a false failure.
if [ "$(id -u)" = "0" ]; then
  echo "  SKIP unreadable (mode 000) auth-stub case — running as root, 000 files are still readable"
else
  printf 'not empty — real content past the mode-000 permission bit\n' > "$AF/unreadable.txt"
  chmod 000 "$AF/unreadable.txt"
  UNREADQ='if zms_is_auth_stub "$1"; then echo stub; else echo not; fi; echo END'
  out="$(zrun "set -- \"\$ARG\"; $UNREADQ" ARG="$AF/unreadable.txt")"; rc=$?
  expect_eq "unreadable (mode 000) non-empty file: if-guarded snippet completes, verdict 'not', reaches END" \
    "not
END" "$out"
  expect_eq "…exit status 0 (no set -e abort)" "0" "$rc"
  expect_eq "…and nothing printed on stderr (no Permission-denied noise)" "" "$(cat "$T/zrun.err")"
  chmod 644 "$AF/unreadable.txt"
fi

# ── 8. zms_codex_cli_guard reproduces the driver's verdicts ──────────────────
echo "-- 8. codex CLI guard"
GV="$T/gv"; mkdir -p "$GV"
fake_codex() { # fake_codex <version-or-empty> — records every execution to $T/gv.calls
  if [ -z "$1" ]; then printf '#!/bin/sh\necho "$@" >> "%s/gv.calls"\nexit 1\n' "$T" > "$GV/codex"
  else printf '#!/bin/sh\necho "$@" >> "%s/gv.calls"\necho "codex-cli %s"\n' "$T" "$1" > "$GV/codex"; fi
  chmod +x "$GV/codex"; rm -f "$T/gv.calls"
}
GUARDQ='zms_codex_cli_guard "$1" TEST_OVERRIDE'
# The driver only ever calls its guard inside "$(...)" (run_codex "$(codex_cli_guard …)"), where
# bash drops errexit; call it the same way. The LIBRARY is called directly under -e above — stricter.
DRVGUARDQ='eval "$(sed -n "/^codex_cli_guard()/,/^}/p" "$ADV")"
declare -F codex_cli_guard >/dev/null || { echo "NO-DRIVER-FUNCTION"; exit 0; }
printf "%s" "$(codex_cli_guard "$1" TEST_OVERRIDE)"'
guard_case() { # guard_case <cli-version-or-empty> <model> <expected>
  fake_codex "$1"
  expect_eq "CLI [${1:-unparsable}] $2 → $3 (library)" "$3" "$(zrun "set -- '$2'; $GUARDQ" ZUVO_CODEX_BIN="$GV/codex")"
  # The driver resolves bare `codex` from PATH; same fake, same verdict.
  expect_eq "CLI [${1:-unparsable}] $2 → $3 (driver agrees)" "$3" \
    "$(zrun "set -- '$2'; $DRVGUARDQ" ADV="$ADV" PATH="$GV:$BASE_PATH")"
}
guard_case 0.156.1 gpt-6-sol  gpt-6-sol
guard_case 0.156.1 gpt-6-luna gpt-6-luna
guard_case 0.157.0 gpt-6-sol  gpt-6-sol
guard_case 0.155.9 gpt-6-sol  gpt-5.6-sol
guard_case 0.150.0 gpt-6-sol  gpt-5.6-sol
guard_case 0.144.0 gpt-5.6-sol gpt-5.6-sol
guard_case 0.143.0 gpt-5.6-sol gpt-5.5
guard_case 0.143.0 gpt-6-sol  gpt-5.5
guard_case 0.140.0 gpt-6-sol  gpt-5.5
guard_case ""      gpt-6-sol  gpt-5.5
guard_case 1.0.0   gpt-6-sol  gpt-6-sol
fake_codex ""
zrun "set -- gpt-6-sol; $GUARDQ" ZUVO_CODEX_BIN="$GV/codex" >/dev/null
err="$(cat "$T/zrun.err")"
expect_has "an unparsable version WARNs that it falls back" "cannot parse codex CLI version — falling back to gpt-5.6-sol" "$err"
# The override variable is only the CALLER's model choice (the driver passes "${VAR:-default}"): the
# guard checks whatever model it receives, so setting the variable to a guarded id can never force
# that id past the check. The WARN used to promise exactly that ("set VAR to force").
case "$err" in
  *"to force"*) bad "the WARN still promises that setting the variable forces the model — nothing honours that" ;;
  *)            ok "the WARN no longer promises a force that neither the library nor the driver honours" ;;
esac
expect_has "…it names what works: an unguarded id in the override variable" "set TEST_OVERRIDE to a model outside gpt-6*/gpt-5.6*" "$err"
expect_has "…or a codex CLI whose --version answers" "make \`codex --version\` answer" "$err"
fake_codex 0.140.0
zrun "set -- gpt-6-sol; $GUARDQ" ZUVO_CODEX_BIN="$GV/codex" >/dev/null
expect_has "a too-old CLI WARNs with the upgrade hint" "is too old for gpt-6-sol" "$(cat "$T/zrun.err")"
fake_codex 0.156.1
expect_eq "an unguarded model passes through" "gpt-5.5" "$(zrun "set -- gpt-5.5; $GUARDQ" ZUVO_CODEX_BIN="$GV/codex")"
if [ -e "$T/gv.calls" ]; then bad "an unguarded model still executed codex --version"
else ok "an unguarded model never executes the CLI"; fi
expect_eq "the guarded case DID execute exactly one --version (positive anchor)" "gpt-6-sol|--version" \
  "$(zrun "set -- gpt-6-sol; $GUARDQ" ZUVO_CODEX_BIN="$GV/codex")|$(tr '\n' ' ' 2>/dev/null < "$T/gv.calls" | sed 's/ $//')"
expect_eq "codex unavailable (ZUVO_CODEX_BIN=/nonexistent) → safest model" "gpt-5.5" \
  "$(zrun "set -- gpt-6-sol; $GUARDQ" ZUVO_CODEX_BIN=/nonexistent)"
out="$(zrun 'rc=0; zms_codex_cli_guard "" X || rc=$?; echo "rc=$rc"')"
expect_eq "an empty model is a usage error (rc=2, nothing resolved)" "rc=2" "$out"
# No GNU timeout at all (stock macOS without coreutils): an unbounded `codex --version` could hang the
# review it only vouches for, so the CLI is NOT run — the version counts as unparsable. The fake is a
# NEW CLI on purpose: had it been executed, the guard would have kept gpt-6-sol.
NT="$T/no-timeout-path"; mkdir -p "$NT"   # PATH with neither timeout nor gtimeout (nor anything else)
fake_codex 0.156.1
got="$(zrun "set -- gpt-6-sol; $GUARDQ" ZUVO_CODEX_BIN="$GV/codex" PATH="$NT")"
err="$(cat "$T/zrun.err")"
expect_eq "no timeout/gtimeout on PATH → the guard takes its fallback ladder" "gpt-5.5" "$got"
if [ -e "$T/gv.calls" ]; then bad "…but codex --version was EXECUTED with no bound"
else ok "…and the codex CLI was never executed"; fi
n="$(printf '%s\n' "$err" | awk '/GNU timeout not found — skipping codex --version probe/ {c++} END {print c+0}')"
expect_eq "…with exactly ONE WARN naming the reason (probed once, not once per rung)" "1" "$n"
expect_eq "no timeout, unguarded model → passes through, nothing probed" "gpt-5.5|" \
  "$(zrun "set -- gpt-5.5; $GUARDQ" ZUVO_CODEX_BIN="$GV/codex" PATH="$NT")|$(cat "$T/zrun.err")"

# ZUVO_CODEX_VERSION_TIMEOUT is honoured, robust to a loaded machine: the fake --version answers a
# NEW version only after sleeping 30 s — a long, unambiguous margin — with ZUVO_CODEX_VERSION_TIMEOUT
# =1 s. The assertion is "well under the fake's 30 s" (≤10 s), not "close to 1 s": on a Mac that can
# sit at load 200+, a tight 1 s-vs-3 s margin against `date +%s`'s 1 s resolution is itself flaky, not
# just the guard. Were the budget ignored, the call would take ~30 s, not ≤10 s — the bound still
# proves the timeout is honoured without racing scheduler noise.
if [ -e "$SPY_BIN/timeout" ] || [ -e "$SPY_BIN/gtimeout" ]; then
  MARKER_BIN="$GV/codex-timeout-probe"
  printf '#!/bin/sh\necho "$@" >> "%s/gv.calls"\nsleep 30\necho "codex-cli 0.156.1"\n' "$T" > "$MARKER_BIN"
  chmod +x "$MARKER_BIN"; rm -f "$T/gv.calls"
  _t0=$(date +%s)
  got="$(zrun "set -- gpt-6-sol; $GUARDQ" ZUVO_CODEX_BIN="$MARKER_BIN" ZUVO_CODEX_VERSION_TIMEOUT=1)"
  _dt=$(( $(date +%s) - _t0 ))
  expect_eq "ZUVO_CODEX_VERSION_TIMEOUT=1 cuts off a 30s --version → unparsable → safest model" "gpt-5.5" "$got"
  expect_has "…with the unparsable-version WARN" "cannot parse codex CLI version" "$(cat "$T/zrun.err")"
  if [ "$_dt" -le 10 ]; then ok "…well under the fake's 30s sleep (${_dt}s ≤ 10s bound)"
  else bad "the guard took ${_dt}s (>10s) — ZUVO_CODEX_VERSION_TIMEOUT was not honoured"; fi
  # `timeout -k 2` sends TERM at the 1s budget and KILL 2s later if still alive; allow that grace
  # (polled, bounded), then confirm the sleeping fake did not survive — through no_proc, which fails
  # closed: a pgrep ERROR is not "nothing left". Searched by its own unique marker path (MARKER_BIN,
  # distinct from every other fake in this file), not a bare `pgrep sleep`, which would also match
  # unrelated sleeps already running on a shared dev machine.
  if poll 10 no_proc "$MARKER_BIN"; then ok "no leftover sleeping fake process survives (marker: $MARKER_BIN)"
  else
    bad "leftover process(es) still running after the timeout (or pgrep failed): $(pgrep -f "$MARKER_BIN" | tr '\n' ' ')"
    pkill -KILL -f "$MARKER_BIN" 2>/dev/null
  fi
  # A non-numeric budget falls back to the default instead of breaking the probe: handed to timeout
  # as-is, `abc` is an invalid interval, --version never answers and a NEW CLI is downgraded for nothing.
  fake_codex 0.156.1
  expect_eq "ZUVO_CODEX_VERSION_TIMEOUT=abc → default budget, the real version is still read" "gpt-6-sol" \
    "$(zrun "set -- gpt-6-sol; $GUARDQ" ZUVO_CODEX_BIN="$GV/codex" ZUVO_CODEX_VERSION_TIMEOUT=abc)"
  expect_eq "…and nothing was WARNed" "" "$(cat "$T/zrun.err")"
else
  bad "no GNU timeout/gtimeout on this machine — the bounded --version cases cannot run"
fi

# ── 9. isolated runners: zms_codex_home, zms_run_codex, zms_run_claude ───────
# Every client here is the SPY fixture (tests/hooks/fixtures/model-subprocess/spy-cli), reached only
# through the ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN seams. The spy records what it saw WHILE running
# (argv, cwd, OLDPWD, CODEX_HOME + its listing/mode, config.toml, the MCP config, stdin hash); every
# case first checks that record exists, so a runner that never dispatched cannot pass vacuously.
# Callers run from INSIDE the repo: "the client's cwd is not under the repo" is measured against that.
echo "-- 9. isolated runners (none / read / agent)"
FIXD="$ROOT/tests/hooks/fixtures/model-subprocess"
SPY_DIR="$T/spy"; RTMP="$T/rtmp"; RROOT="$T/readroot"; SPYB="$T/spybin"
mkdir -p "$SPY_DIR" "$RTMP" "$RROOT" "$SPYB"
# PHYSICAL paths, resolved once: the spy records pwd -P, so a logical /var/… on this side against a
# physical /private/var/… on that side would turn every "not under" check into a vacuous pass.
ROOT="$(cd "$ROOT" && pwd -P)"; RTMP="$(cd "$RTMP" && pwd -P)"; RROOT="$(cd "$RROOT" && pwd -P)"
[ -n "$ROOT" ] && [ -n "$RTMP" ] && [ -n "$RROOT" ] || { echo "  FAIL cannot resolve the runner paths" >&2; exit 1; }
# The spy must SEE the OLDPWD a real client would receive. macOS /bin/sh is bash 3.2, which throws an
# inherited OLDPWD away at startup (bash >= 4.4, dash and zsh keep it) — the record would read empty
# whatever the runner did. So the spy runs under the first sh that keeps it; if none does, the OLDPWD
# checks say SKIP instead of passing on an empty value.
keeps_oldpwd() { env OLDPWD=/ "$1" -c '[ "${OLDPWD:-}" = / ]' 2>/dev/null; }
SPY_SH=""
for _s in /bin/sh /bin/dash /usr/bin/dash; do
  if [ -x "$_s" ] && keeps_oldpwd "$_s"; then SPY_SH="$_s"; break; fi
done
install_spy() { # install_spy <dest> — the fixture spy, under $SPY_SH when one was found
  if [ -n "$SPY_SH" ]; then { printf '#!%s\n' "$SPY_SH"; tail -n +2 "$FIXD/spy-cli"; } > "$1"
  else cp "$FIXD/spy-cli" "$1"; fi
  chmod +x "$1"
}
if [ -n "$SPY_SH" ]; then echo "  note: spy interpreter $SPY_SH (keeps an inherited OLDPWD)"
else echo "  note: no sh here keeps an inherited OLDPWD — the OLDPWD checks are SKIPPED"; fi
expect_oldpwd_not_under() { # <label> <spy-name> <dir> — compared in PHYSICAL form
  if [ -z "$SPY_SH" ]; then echo "  SKIP $1 (OLDPWD not observable)"; return 0; fi
  expect_not_under "$1" "$(rec "$2" OLDPWD_P)" "$3"
}
install_spy "$SPYB/codex"; install_spy "$SPYB/claude"
RUN_CH="$T/run-codex-home"; cp -R "$FIXD/codex-home" "$RUN_CH"   # the user's CODEX_HOME: auth + a hostile config
# hex64 <value> — yes when <value> is exactly 64 lowercase hex digits (a sha256 shasum really printed).
# Both sides of every sha comparison below come from shasum; empty on both sides would compare equal.
hex64() { case "$1" in *[!0-9a-f]*) echo no ;; *) if [ "${#1}" -eq 64 ]; then echo yes; else echo no; fi ;; esac; }
AUTH_SHA="$(shasum -a 256 < "$FIXD/codex-home/auth.json" | cut -d' ' -f1)"
expect_eq "AUTH_SHA is a 64-hex sha256 (the auth.json comparisons cannot pass empty)" "yes" "$(hex64 "$AUTH_SHA")"
PROMPT="$T/prompt.txt"
printf 'Review this diff.\nza\305\274\303\263\305\202\304\207 multibyte, and no trailing newline' > "$PROMPT"
PROMPT_SHA="$(shasum -a 256 < "$PROMPT" | cut -d' ' -f1)"
expect_eq "PROMPT_SHA is a 64-hex sha256 (the stdin comparisons cannot pass empty)" "yes" "$(hex64 "$PROMPT_SHA")"
PROMPT_BYTES="$(wc -c < "$PROMPT" | tr -d ' ')"
ERRF="$T/client-stderr.txt"
MCP_EMPTY='{"mcpServers":{}}'

# rrun <client> [VAR=value ...] -- <runner args...> — zms_run_<client> called from INSIDE the repo,
# under the caller's `set -euo pipefail`. Prints "rc=<status>"; the runner's stdout → $T/run.out,
# its stderr → $T/zrun.err. Clears the previous spy record first.
rrun() {
  local client="$1" q envs=(); shift
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  q="$(printf '%q ' "$@")"
  rm -f "$SPY_DIR"/*.rec "$SPY_DIR"/*.stdin "$T/run.out"
  # shellcheck disable=SC2016  # expanded by the child shell
  zrun "cd \"\$REPO\"; set -- $q; rc=0; zms_run_$client \"\$@\" > \"\$OUT\" || rc=\$?; echo \"rc=\$rc\"" \
    REPO="$ROOT" OUT="$T/run.out" SPY_DIR="$SPY_DIR" TMPDIR="$RTMP" CODEX_HOME="$RUN_CH" \
    ZUVO_CODEX_BIN="$SPYB/codex" ZUVO_CLAUDE_BIN="$SPYB/claude" ZUVO_TIMEOUT_GRACE=2 \
    ${envs[@]+"${envs[@]}"}
}
# rec <name> <key> — every value of <key> in the spy's record, one per line
rec() { awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }' "$SPY_DIR/$1.rec" 2>/dev/null; }
# recj <name> <key> — the same values joined with '|' (an empty value stays visible as '||')
recj() { rec "$1" "$2" | awk '{ printf "%s%s", (NR > 1 ? "|" : ""), $0 } END { print "" }'; }
spy_ran() { # spy_ran <name> <label> — the vacuous-pass guard every runner case starts with
  if [ -s "$SPY_DIR/$1.rec" ]; then ok "$2: the $1 spy ran (.rec present)"; return 0; fi
  bad "$2: the $1 spy never ran — no $SPY_DIR/$1.rec"; return 1
}
spy_absent() { # spy_absent <name> <label> — no client was invoked
  if [ -e "$SPY_DIR/$1.rec" ]; then bad "$2: the $1 spy WAS invoked"; else ok "$2: no client invoked"; fi
}
# under <path> <dir> — <path> IS <dir> or lies below it. Trailing slashes do not count on either
# side (the old `case "$1/" in "$2"/*` said NO for `under /a/b /a/b/`, so a runner sitting exactly
# at a root given with a slash passed "not under" vacuously); /a/bc is never under /a/b. The prefix
# lives in its own variable: bash 5.3 does not match `"${d%/}"/*` as a case pattern for d=/.
under() {
  local p="$1" d="$2" pre
  while case "$p" in ?*/) true ;; *) false ;; esac; do p="${p%/}"; done
  while case "$d" in ?*/) true ;; *) false ;; esac; do d="${d%/}"; done
  [ "$p" = "$d" ] && return 0
  if [ "$d" = / ]; then pre=/; else pre="$d/"; fi
  case "$p" in "$pre"*) return 0 ;; *) return 1 ;; esac
}
under_case() { # under_case <label> <path> <dir> <yes|no>
  if under "$2" "$3"; then _u=yes; else _u=no; fi
  expect_eq "under: $1 ($2 in $3)" "$4" "$_u"
}
under_case "a path equal to the dir" /a/b /a/b yes
under_case "equal, the dir given with a trailing slash" /a/b /a/b/ yes
under_case "equal, the path given with a trailing slash" /a/b/ /a/b yes
under_case "a child" /a/b/c /a/b yes
under_case "a sibling sharing the prefix is NOT under" /a/bc /a/b no
under_case "the parent is NOT under its child" /a /a/b no
under_case "every absolute path is under /" /a/b / yes
expect_under() { if under "$2" "$3"; then ok "$1"; else bad "$1 — [$2] is not under [$3]"; fi; }
expect_not_under() { if [ -n "$2" ] && ! under "$2" "$3"; then ok "$1"; else bad "$1 — [$2] is empty or under [$3]"; fi; }
rtmp_empty() { [ -z "$(ls -A "$RTMP" 2>/dev/null)" ]; }
rtmp_clean() { # rtmp_clean <label> — the call's temp dir (and its CODEX_HOME with auth.json) is gone
  local left; left="$(ls -A "$RTMP" 2>/dev/null)"
  if [ -z "$left" ]; then ok "$1: the call's temp dir was removed (TMPDIR empty again)"
  else bad "$1: left behind in TMPDIR: $left"; rm -rf "${RTMP:?}"/*; fi
}
stdin_same() { # stdin_same <name> <label> — the prompt reached the client on stdin, byte for byte
  expect_eq "$2: stdin = the prompt file (sha256 + $PROMPT_BYTES bytes)" "$PROMPT_SHA/$PROMPT_BYTES" \
    "$(rec "$1" stdin_sha)/$(rec "$1" stdin_bytes)"
}

# ── 9a. zms_codex_home ──
out="$(zrun 'zms_codex_home "$D" gpt-6-sol high read-only; echo "rc=$?"' D="$T/ch-direct" CODEX_HOME="$RUN_CH")"
expect_eq "zms_codex_home builds the isolated home (rc=0)" "rc=0" "$out"
expect_eq "…mode 700" "700" "$(fmode "$T/ch-direct")"
expect_eq "…auth.json copied byte for byte, mode 600" "$AUTH_SHA/600" \
  "$(shasum -a 256 < "$T/ch-direct/auth.json" | cut -d' ' -f1)/$(fmode "$T/ch-direct/auth.json")"
expect_eq "…holds exactly auth.json and config.toml" "auth.json config.toml" "$(ls -A "$T/ch-direct" | tr '\n' ' ' | sed 's/ $//')"
expect_eq "…config.toml minimal: model, sandbox, approval, effort — nothing from the user's config" \
  'model = "gpt-6-sol"|sandbox_mode = "read-only"|approval_policy = "never"|model_reasoning_effort = "high"' \
  "$(awk '{ printf "%s%s", (NR > 1 ? "|" : ""), $0 } END { print "" }' "$T/ch-direct/config.toml")"
# A target that ALREADY holds an auth.json (a reused dir): `cp` onto an existing file keeps THAT
# file's mode — umask 077 only shapes files cp creates — so a 644 copy of the account token stayed
# world-readable. And an existing SYMLINK there was written THROUGH: the token landed in whatever
# file the link named.
mkdir -p "$T/ch-stale"; printf 'stale\n' > "$T/ch-stale/auth.json"; chmod 644 "$T/ch-stale/auth.json"
zrun 'zms_codex_home "$D" gpt-5.5 "" read-only' D="$T/ch-stale" CODEX_HOME="$RUN_CH" >/dev/null
expect_eq "a PRE-EXISTING 644 auth.json in the target → the source's bytes, mode 600" "$AUTH_SHA/600" \
  "$(shasum -a 256 < "$T/ch-stale/auth.json" | cut -d' ' -f1)/$(fmode "$T/ch-stale/auth.json")"
mkdir -p "$T/ch-link"; printf 'decoy\n' > "$T/ch-link-decoy"; chmod 644 "$T/ch-link-decoy"
ln -s "$T/ch-link-decoy" "$T/ch-link/auth.json"
zrun 'zms_codex_home "$D" gpt-5.5 "" read-only' D="$T/ch-link" CODEX_HOME="$RUN_CH" >/dev/null
expect_eq "an auth.json SYMLINK in the target is replaced, not written through (decoy unchanged, 644)" \
  "decoy/644" "$(cat "$T/ch-link-decoy")/$(fmode "$T/ch-link-decoy")"
if [ -f "$T/ch-link/auth.json" ] && [ ! -L "$T/ch-link/auth.json" ]; then
  expect_eq "…and the target is now a regular file with the source's bytes, mode 600" "$AUTH_SHA/600" \
    "$(shasum -a 256 < "$T/ch-link/auth.json" | cut -d' ' -f1)/$(fmode "$T/ch-link/auth.json")"
else bad "…the target auth.json is still a symlink (or missing)"; fi
# config.toml is the same class: `> "$dir/config.toml"` onto a SYMLINK wrote the sandbox config
# THROUGH it, into whatever file the link named, and onto an existing file kept that file's mode.
mkdir -p "$T/ch-cfglink"; printf 'decoy-config\n' > "$T/ch-cfglink-decoy"; chmod 644 "$T/ch-cfglink-decoy"
ln -s "$T/ch-cfglink-decoy" "$T/ch-cfglink/config.toml"
zrun 'zms_codex_home "$D" gpt-5.5 "" read-only' D="$T/ch-cfglink" CODEX_HOME="$RUN_CH" >/dev/null
expect_eq "a config.toml SYMLINK in the target is replaced, not written through (decoy unchanged, 644)" \
  "decoy-config/644" "$(cat "$T/ch-cfglink-decoy")/$(fmode "$T/ch-cfglink-decoy")"
if [ -f "$T/ch-cfglink/config.toml" ] && [ ! -L "$T/ch-cfglink/config.toml" ]; then
  expect_eq "…and config.toml is now a regular file with the minimal config, mode 600" \
    'model = "gpt-5.5"|sandbox_mode = "read-only"|approval_policy = "never"/600' \
    "$(awk '{ printf "%s%s", (NR > 1 ? "|" : ""), $0 } END { print "" }' "$T/ch-cfglink/config.toml")/$(fmode "$T/ch-cfglink/config.toml")"
else bad "…the target config.toml is still a symlink (or missing)"; fi
# A reused dir whose source has NO auth.json: the old copy used to survive, so the client ran on a
# stale account file the caller no longer has — and none/read counted it as present.
mkdir -p "$T/ch-noauth-src" "$T/ch-stale-noauth"; printf 'stale-token\n' > "$T/ch-stale-noauth/auth.json"
out="$(zrun 'zms_codex_home "$D" gpt-5.5 "" read-only; echo "rc=$?"' D="$T/ch-stale-noauth" CODEX_HOME="$T/ch-noauth-src")"
expect_eq "a stale auth.json + a source WITHOUT one → built (rc=0)" "rc=0" "$out"
expect_eq "…the stale copy is gone: the target holds exactly config.toml" "config.toml" \
  "$(ls -A "$T/ch-stale-noauth" | tr '\n' ' ' | sed 's/ $//')"
mkdir -p "$T/ch-lax"; chmod 755 "$T/ch-lax"
zrun 'zms_codex_home "$D" gpt-5.5 "" danger-full-access' D="$T/ch-lax" CODEX_HOME="$RUN_CH" >/dev/null
expect_eq "an EXISTING lax (755) dir is tightened to 700" "700" "$(fmode "$T/ch-lax")"
expect_eq "an empty effort writes no model_reasoning_effort line (the model keeps its default)" \
  'model = "gpt-5.5"|sandbox_mode = "danger-full-access"|approval_policy = "never"' \
  "$(awk '{ printf "%s%s", (NR > 1 ? "|" : ""), $0 } END { print "" }' "$T/ch-lax/config.toml")"
out="$(zrun 'rc=0; zms_codex_home "$D" gpt-6-sol high full-disk || rc=$?; echo "rc=$rc"' D="$T/ch-bad")"
expect_eq "an unknown sandbox is a usage error (rc=2)" "rc=2" "$out"
out="$(zrun 'rc=0; zms_codex_home "$D" "gpt\"injected = 1" high read-only || rc=$?; echo "rc=$rc"' D="$T/ch-inj")"
expect_eq "a model id carrying a quote is refused (it would inject TOML) — rc=2" "rc=2" "$out"
# Any control character, not only a line break: a TAB, CR or ESC inside a TOML basic string is invalid
# TOML (the client refuses its own config) or an escape sequence replayed into every log that prints it.
for _cc in 'TAB:\t' 'ESC:\033' 'CR:\r' 'DEL:\177'; do
  out="$(zrun 'rc=0; zms_codex_home "$D" "$(printf "gpt-5.5${C}x")" high read-only || rc=$?; echo "rc=$rc"' \
    D="$T/ch-cc" C="${_cc#*:}")"
  expect_eq "a model id carrying a ${_cc%%:*} is refused — rc=2" "rc=2" "$out"
done
out="$(zrun 'rc=0; zms_codex_home "$D" gpt-5.5 "$(printf "high\tx")" read-only || rc=$?; echo "rc=$rc"' D="$T/ch-cc")"
expect_eq "an effort carrying a TAB is refused too — rc=2" "rc=2" "$out"

# ── 9b. zms_run_codex --access none ──
L="codex none"
out="$(rrun codex -- --model gpt-6-sol --effort high --access none --prompt-file "$PROMPT" --timeout 60)"
expect_eq "$L: exit 0" "rc=0" "$out"
if spy_ran codex "$L"; then
  expect_eq "$L: the client's reply is the runner's stdout" "SPY-REPLY codex" "$(cat "$T/run.out")"
  expect_eq "$L: argv = exec, no git check, read-only sandbox, shell tools + view_image disabled (P1/P6)" \
    "exec|--skip-git-repo-check|-s|read-only|--disable|shell_tool|--disable|unified_exec|--disable|view_image" "$(recj codex arg)"
  ch="$(rec codex CODEX_HOME)"; pw="$(rec codex pwd_P)"
  expect_not_under "$L: cwd is not under the repo" "$pw" "$ROOT"
  expect_not_under "$L: \$PWD is not under the repo" "$(rec codex PWD_P)" "$ROOT"
  expect_oldpwd_not_under "$L: \$OLDPWD is not under the repo (a cd would leave the caller's dir there)" codex "$ROOT"
  expect_under "$L: cwd is inside the call's temp dir" "$pw" "$RTMP"
  expect_eq "$L: an absolute TMPDIR reaches the client unchanged" "$RTMP" "$(rec codex tmpdir)"
  if [ "$pw" != "$ch" ]; then ok "$L: cwd is a separate empty dir, not the CODEX_HOME holding auth.json"
  else bad "$L: cwd is the CODEX_HOME itself"; fi
  expect_under "$L: CODEX_HOME is inside the call's temp dir" "$ch" "$RTMP"
  case "${ch##*/}" in codex_home_*) ok "$L: CODEX_HOME is named codex_home_*" ;; *) bad "$L: CODEX_HOME named [${ch##*/}]" ;; esac
  expect_eq "$L: CODEX_HOME mode 700" "700" "$(rec codex codex_home_mode)"
  expect_eq "$L: CODEX_HOME holds exactly auth.json + config.toml" "auth.json config.toml " "$(rec codex codex_home_ls)"
  expect_eq "$L: auth.json == the fixture's DUMMY auth.json" "$AUTH_SHA" "$(rec codex auth_sha)"
  expect_eq "$L: config.toml = requested model, read-only, never, effort high — and nothing else" \
    'model = "gpt-6-sol"|sandbox_mode = "read-only"|approval_policy = "never"|model_reasoning_effort = "high"' "$(recj codex config)"
  case "$(recj codex config)" in *mcp_servers*|*user-global-model*|*xhigh*) bad "$L: the user's config.toml leaked in" ;;
    *) ok "$L: no mcp_servers and nothing else from the user's config.toml" ;; esac
  stdin_same codex "$L"
fi
rtmp_clean "$L"

# ── 9c. --access read ──
L="codex read"
out="$(rrun codex -- --model gpt-6-sol --effort high --access read --read-root "$RROOT" --prompt-file "$PROMPT" --timeout 60)"
expect_eq "$L: exit 0" "rc=0" "$out"
if spy_ran codex "$L"; then
  # P6: the read-only sandbox confines WRITES, not reads — with the shell tool present the model
  # reads absolute paths anywhere, so the read-root is reachable (and NOT a boundary: it is advisory
  # for codex); the prompt names absolute paths. view_image goes: reads happen through the shell,
  # so the image viewer is only one more read primitive (P1a: it was the model's next reach).
  expect_eq "$L: argv = exec, no git check, read-only sandbox, view_image disabled, shell tool KEPT" \
    "exec|--skip-git-repo-check|-s|read-only|--disable|view_image" "$(recj codex arg)"
  expect_eq "$L: config.toml read-only" \
    'model = "gpt-6-sol"|sandbox_mode = "read-only"|approval_policy = "never"|model_reasoning_effort = "high"' "$(recj codex config)"
  pw="$(rec codex pwd_P)"
  expect_not_under "$L: cwd is not under the repo" "$pw" "$ROOT"
  expect_not_under "$L: cwd is not the read-root (a project config there must not load)" "$pw" "$RROOT"
  expect_oldpwd_not_under "$L: \$OLDPWD is not under the repo" codex "$ROOT"
  expect_eq "$L: CODEX_HOME holds exactly auth.json + config.toml" "auth.json config.toml " "$(rec codex codex_home_ls)"
  stdin_same codex "$L"
fi
rtmp_clean "$L"
out="$(rrun codex -- --model gpt-6-sol --access read --prompt-file "$PROMPT" --timeout 60)"
expect_eq "$L without --read-root → usage error rc=2" "rc=2" "$out"
expect_has "…naming --read-root" "--read-root" "$(cat "$T/zrun.err")"
spy_absent codex "$L without --read-root"
out="$(rrun codex -- --model gpt-6-sol --access read --read-root "$T/no-such-dir" --prompt-file "$PROMPT" --timeout 60)"
expect_eq "$L with a read-root that is not a directory → rc=2" "rc=2" "$out"
out="$(rrun codex -- --model gpt-6-sol --access none --read-root "$RROOT" --prompt-file "$PROMPT" --timeout 60)"
expect_eq "--read-root with --access none → usage error rc=2 (none means no file access)" "rc=2" "$out"
spy_absent codex "--read-root with none"

# ── 9d. --access agent: TODAY's adversarial-driver flags, literally ──
L="codex agent"
out="$(rrun codex -- --model gpt-6-sol --effort none --access agent --prompt-file "$PROMPT" --timeout 60)"
expect_eq "$L: exit 0" "rc=0" "$out"
if spy_ran codex "$L"; then
  expect_eq "$L: argv = exec --skip-git-repo-check (run_codex today)" "exec|--skip-git-repo-check" "$(recj codex arg)"
  expect_eq "$L: config.toml = run_codex today: model, danger-full-access, never, effort" \
    'model = "gpt-6-sol"|sandbox_mode = "danger-full-access"|approval_policy = "never"|model_reasoning_effort = "none"' "$(recj codex config)"
  # run_codex does `cd "$tmp_home"`: cwd IS the isolated CODEX_HOME, and bash's cd leaves the
  # caller's dir in OLDPWD. Kept literally — the driver refactor is proven byte-identical against this.
  expect_eq "$L: cwd is the isolated CODEX_HOME (run_codex: cd \$tmp_home)" "$(rec codex CODEX_HOME)" "$(rec codex pwd_P)"
  if [ -n "$SPY_SH" ]; then expect_eq "$L: OLDPWD is the caller's dir, as today" "$ROOT" "$(rec codex OLDPWD)"
  else echo "  SKIP $L: OLDPWD is the caller's dir (OLDPWD not observable)"; fi
  expect_eq "$L: CODEX_HOME holds auth.json + config.toml" "auth.json config.toml " "$(rec codex codex_home_ls)"
  stdin_same codex "$L"
fi
rtmp_clean "$L"
rrun codex -- --model gpt-5.5 --access agent --prompt-file "$PROMPT" --timeout 60 >/dev/null
if spy_ran codex "$L without --effort"; then
  expect_eq "$L without --effort: no model_reasoning_effort line" \
    'model = "gpt-5.5"|sandbox_mode = "danger-full-access"|approval_policy = "never"' "$(recj codex config)"
fi
rtmp_clean "$L without --effort"

# ── 9e. zms_run_claude ──
L="claude none"
out="$(rrun claude -- --model claude-opus-5-5 --effort high --access none --prompt-file "$PROMPT" --timeout 60)"
expect_eq "$L: exit 0" "rc=0" "$out"
if spy_ran claude "$L"; then
  mcp="$(rec claude mcp_file)"
  expect_eq "$L: argv = no tools, safe mode, strict EMPTY MCP, no session persistence (P2)" \
    "--model|claude-opus-5-5|--effort|high|--print|--output-format|text|--tools||--safe-mode|--mcp-config|$mcp|--strict-mcp-config|--no-session-persistence" \
    "$(recj claude arg)"
  case "|$(recj claude arg)|" in *"|--dangerously-skip-permissions|"*) bad "$L: carries --dangerously-skip-permissions" ;;
    *) ok "$L: no --dangerously-skip-permissions" ;; esac
  expect_eq "$L: the --mcp-config file holds an EMPTY server map" "$MCP_EMPTY" "$(rec claude mcp_content)"
  expect_under "$L: the MCP config lives in the call's temp dir" "$mcp" "$RTMP"
  pw="$(rec claude pwd_P)"
  expect_not_under "$L: cwd is not under the repo" "$pw" "$ROOT"
  expect_under "$L: cwd is inside the call's temp dir" "$pw" "$RTMP"
  expect_oldpwd_not_under "$L: \$OLDPWD is not under the repo" claude "$ROOT"
  stdin_same claude "$L"
fi
rtmp_clean "$L"
rrun claude -- --model claude-sonnet-5 --access none --prompt-file "$PROMPT" --timeout 60 >/dev/null
if spy_ran claude "$L without --effort"; then
  case "|$(recj claude arg)|" in *"|--effort|"*) bad "$L without --effort: an --effort was passed" ;;
    *) ok "$L without --effort: no --effort in argv (the model keeps its default)" ;; esac
fi
rtmp_clean "$L without --effort"

L="claude read"
# A RELATIVE read-root, resolved against the caller's cwd: the client runs from elsewhere.
out="$(rrun claude -- --model claude-opus-5-5 --access read --read-root tests/hooks --prompt-file "$PROMPT" --timeout 60)"
expect_eq "$L: exit 0" "rc=0" "$out"
if spy_ran claude "$L"; then
  mcp="$(rec claude mcp_file)"
  expect_eq "$L: argv = Read/Grep/Glob only, --add-dir <ABSOLUTE root>, safe mode, prompts auto-denied (P3)" \
    "--model|claude-opus-5-5|--print|--output-format|text|--tools|Read,Grep,Glob|--add-dir|$ROOT/tests/hooks|--safe-mode|--permission-prompts|none|--mcp-config|$mcp|--strict-mcp-config|--no-session-persistence" \
    "$(recj claude arg)"
  expect_eq "$L: the --mcp-config file holds an EMPTY server map" "$MCP_EMPTY" "$(rec claude mcp_content)"
  expect_not_under "$L: cwd is not under the repo (the root is reached through --add-dir only)" "$(rec claude pwd_P)" "$ROOT"
  stdin_same claude "$L"
fi
rtmp_clean "$L"
# A SYMLINKED read-root: --add-dir is the one boundary claude enforces, so it gets the PHYSICAL
# directory. Handed the link, the boundary is a name — whatever the link points at when the client
# resolves it, which need not be what was validated here.
L="claude read, symlinked root"
ln -s "$RROOT" "$T/readroot-link"
out="$(rrun claude -- --model claude-opus-5-5 --access read --read-root "$T/readroot-link" --prompt-file "$PROMPT" --timeout 60)"
expect_eq "$L: exit 0" "rc=0" "$out"
if spy_ran claude "$L"; then
  expect_eq "$L: --add-dir is the link's PHYSICAL target, not the link" "$RROOT" \
    "$(rec claude arg | awk 'p { print; exit } $0 == "--add-dir" { p = 1 }')"
fi
rtmp_clean "$L"
if [ "$(id -u)" = "0" ]; then
  echo "  SKIP read-root that cannot be entered — running as root, a mode-000 dir is still enterable"
else
  L="claude read, a read-root that cannot be entered"
  mkdir -p "$T/readroot-locked"; chmod 000 "$T/readroot-locked"
  out="$(rrun claude -- --model claude-opus-5-5 --access read --read-root "$T/readroot-locked" --prompt-file "$PROMPT" --timeout 60)"
  expect_eq "$L (mode 000: a directory, but not resolvable) → rc=2" "rc=2" "$out"
  spy_absent claude "$L"
  chmod 755 "$T/readroot-locked"
  rtmp_clean "$L"
fi

L="claude agent"
out="$(rrun claude -- --model claude-opus-5-5 --effort high --access agent --prompt-file "$PROMPT" --timeout 60)"
expect_eq "$L: exit 0" "rc=0" "$out"
if spy_ran claude "$L"; then
  mcp="$(rec claude mcp_file)"
  expect_eq "$L: argv = run_claude today, literally" \
    "--model|claude-opus-5-5|--effort|high|--print|--output-format|text|--mcp-config|$mcp|--strict-mcp-config|--dangerously-skip-permissions" \
    "$(recj claude arg)"
  expect_eq "$L: the --mcp-config file holds an EMPTY server map" "$MCP_EMPTY" "$(rec claude mcp_content)"
  expect_eq "$L: cwd is the caller's (run_claude never changes directory)" "$ROOT" "$(rec claude pwd_P)"
  stdin_same claude "$L"
fi
rtmp_clean "$L"

# ── 9f. the caller's traps survive (the runners' cleanup trap lives in their own subshell) ──
TB="$T/traps-before"; TA="$T/traps-after"
rm -f "$SPY_DIR"/*.rec
# shellcheck disable=SC2016
out="$(zrun 'cd "$REPO"; trap "echo caller-exit" EXIT; trap "echo caller-int" INT; trap -p > "$TB"
zms_run_codex --model m --access none --prompt-file "$P" --timeout 30 > /dev/null
zms_run_claude --model m --access none --prompt-file "$P" --timeout 30 > /dev/null
trap -p > "$TA"; cmp -s "$TB" "$TA" && echo TRAPS-SAME' \
  REPO="$ROOT" P="$PROMPT" TB="$TB" TA="$TA" SPY_DIR="$SPY_DIR" TMPDIR="$RTMP" CODEX_HOME="$RUN_CH" \
  ZUVO_CODEX_BIN="$SPYB/codex" ZUVO_CLAUDE_BIN="$SPYB/claude")"
expect_eq "both runners leave the caller's EXIT/INT traps exactly as they were — and EXIT still fires" \
  "TRAPS-SAME
caller-exit" "$out"
if [ -s "$SPY_DIR/codex.rec" ] && [ -s "$SPY_DIR/claude.rec" ]; then ok "…both spies really ran"
else bad "the trap case never dispatched a spy"; fi
rtmp_clean "trap case"

# ── 9g. timeout → 124, nothing survives; TERM mid-run → nothing left behind ──
if [ -e "$SPY_BIN/timeout" ] || [ -e "$SPY_BIN/gtimeout" ]; then
  # The spy is a COPY at a path unique to this case, so a leftover is found by that path — never by
  # a bare pattern that would also match this test or an unrelated process.
  MARK="$T/runner-timeout-marker-$$"; mkdir -p "$MARK"; install_spy "$MARK/codex"
  _t0=$(date +%s)
  out="$(rrun codex SPY_SLEEP=30 ZUVO_CODEX_BIN="$MARK/codex" -- --model m --access none --prompt-file "$PROMPT" --timeout 2)"
  _dt=$(( $(date +%s) - _t0 ))
  expect_eq "a client sleeping 30 s with --timeout 2 → 124" "rc=124" "$out"
  spy_ran codex "timeout case"
  if [ "$_dt" -le 20 ]; then ok "…returned in ${_dt}s (≤ 20 s bound; 2 s budget + 2 s kill grace)"
  else bad "the timeout case took ${_dt}s (> 20 s) — the budget was not enforced"; fi
  if poll 10 no_proc "$MARK/codex"; then ok "…no spy process survives (marker $MARK/codex)"
  else
    bad "surviving spy process(es) (or pgrep failed): $(pgrep -f "$MARK/codex" | tr '\n' ' ')"
    pkill -KILL -f "$MARK/codex" 2>/dev/null
  fi
  rtmp_clean "timeout case"

  MARK2="$T/runner-term-marker-$$"; mkdir -p "$MARK2"; install_spy "$MARK2/codex"
  rm -f "$SPY_DIR"/*.rec
  # Own process group (set -m) so the TERM reaches the caller shell AND the runner's subshell, the
  # way a Ctrl-C or an outer timeout does. GNU timeout keeps the client in a group of its own, so
  # only the runner's trap can take it down.
  set -m
  env -i HOME="$HOMEDIR" PATH="$BASE_PATH" CODEX_HOME="$RUN_CH" ZUVO_CODEX_APP_BIN=/nonexistent \
    SPY_DIR="$SPY_DIR" SPY_SLEEP=60 TMPDIR="$RTMP" ZUVO_CODEX_BIN="$MARK2/codex" ZUVO_TIMEOUT_GRACE=2 \
    "$BASH" -c '. "$1"; cd "$2"; zms_run_codex --model m --access none --prompt-file "$3" --timeout 120' \
    _ "$LIB" "$ROOT" "$PROMPT" >/dev/null 2>&1 &
  _bg=$!
  set +m
  if poll 30 test -s "$SPY_DIR/codex.rec"; then
    ok "TERM case: the spy is running (record present) before the signal"
    kill -TERM -- "-$_bg" 2>/dev/null
    # Bounded: the caller has no trap and dies at once; were it still there after 10 s, say so
    # loudly and KILL the group instead of waiting on it for ever.
    if ! wait_gone "$_bg" 10; then
      bad "TERM case: the caller was still running 10 s after TERM — KILLing its group"
      kill -KILL -- "-$_bg" 2>/dev/null; wait_gone "$_bg" 5 || bad "TERM case: the caller survived KILL"
    fi
    rtmp_and_marker_gone() { rtmp_empty && no_proc "$1"; }
    poll 20 rtmp_and_marker_gone "$MARK2/codex" || true
    _left="$(ls -A "$RTMP" 2>/dev/null)"
    case "$_left" in *codex_home_*|zms*) bad "TERM mid-run left the call's temp dir / codex_home_* behind: $_left" ;;
      "") ok "TERM mid-run: no codex_home_* dir (nor the call's temp dir) left behind" ;;
      *) bad "TERM mid-run: unexpected leftovers in TMPDIR: $_left" ;; esac
    if no_proc "$MARK2/codex"; then ok "TERM mid-run: the client was taken down too (marker $MARK2/codex)"
    else
      bad "TERM mid-run: the client survived (or pgrep failed): $(pgrep -f "$MARK2/codex" | tr '\n' ' ')"
      pkill -KILL -f "$MARK2/codex" 2>/dev/null
    fi
  else
    bad "TERM case: the spy never started within 30 s"
    kill -KILL -- "-$_bg" 2>/dev/null; wait_gone "$_bg" 5 || bad "TERM case: the caller survived KILL"
  fi
  rm -rf "${RTMP:?}"/*

  # ── a client that IGNORES TERM ──
  # GNU timeout's -k escalates on an EXTERNAL TERM as well, so with a real GNU timeout and a grace of
  # at least 1 s the client dies after the grace. The other two cases take that away — a timeout that
  # never escalates (busybox-style; modelled by a shim that drops -k and execs the real one, so the
  # pid and its process group stay GNU's) and ZUVO_TIMEOUT_GRACE=0 (`timeout -k 0` means NO kill at
  # all) — and the runner then sat in its EXIT trap's unbounded `wait` for ever, auth copy on disk.
  # The caller CATCHES TERM (a caught trap, not an ignore a subshell would inherit), so bash defers it
  # until the runner returns: the caller's exit time is the runner's, and it records the status.
  NOESC="$T/no-escalation-timeout"; mkdir -p "$NOESC"
  _real_to="$SPY_BIN/timeout"; [ -e "$_real_to" ] || _real_to="$SPY_BIN/gtimeout"
  for _n in timeout gtimeout; do
    printf '#!/bin/sh\n# GNU timeout with its kill-after dropped: passes TERM on, never escalates to KILL\n[ "$1" = "-k" ] && shift 2\nexec "%s" "$@"\n' \
      "$_real_to" > "$NOESC/$_n"
    chmod +x "$NOESC/$_n"
  done
  term_ignore_case() { # term_ignore_case <label> <grace> <PATH-prefix-or-empty> <tag>
    local label="$1" grace="$2" pre="$3" mark="$T/term-ignore-$4-$$" rcf="$T/term-ignore-$4.rc"
    local p="$BASE_PATH" bg t0 dt limit left
    [ -z "$pre" ] || p="$pre:$BASE_PATH"
    mkdir -p "$mark"; install_spy "$mark/codex"; rm -f "$rcf" "$SPY_DIR"/*.rec
    set -m
    # shellcheck disable=SC2016  # expanded by the child shell
    env -i HOME="$HOMEDIR" PATH="$p" CODEX_HOME="$RUN_CH" ZUVO_CODEX_APP_BIN=/nonexistent \
      SPY_DIR="$SPY_DIR" SPY_SLEEP=60 SPY_IGNORE_TERM=1 TMPDIR="$RTMP" ZUVO_CODEX_BIN="$mark/codex" \
      ZUVO_TIMEOUT_GRACE="$grace" \
      "$BASH" -c 'trap ": deferred until the runner returns" TERM; . "$1"; cd "$2"
        zms_run_codex --model m --access none --prompt-file "$3" --timeout 120 >/dev/null 2>&1
        echo "rc=$?" > "$4"' _ "$LIB" "$ROOT" "$PROMPT" "$rcf" >/dev/null 2>&1 &
    bg=$!
    set +m
    if ! poll 30 test -s "$SPY_DIR/codex.rec"; then
      bad "$label: the spy never started within 30 s"
      kill -KILL -- "-$bg" 2>/dev/null; wait_gone "$bg" 5 || true
      pkill -KILL -f "$mark/codex" 2>/dev/null; rm -rf "${RTMP:?}"/*; return 0
    fi
    # grace + 8 s: the grace itself plus room for a loaded machine — far below the spy's 60 s.
    limit=$(( grace + 8 )); t0=$(date +%s)
    kill -TERM -- "-$bg" 2>/dev/null
    if wait_gone "$bg" "$limit"; then
      dt=$(( $(date +%s) - t0 ))
      ok "$label: the runner returned ${dt}s after TERM (bound: grace + 8 = ${limit}s)"
      expect_eq "$label: …with the TERM status" "rc=143" "$(cat "$rcf" 2>/dev/null)"
    else
      bad "$label: the runner was STILL RUNNING ${limit}s after TERM — it waits for ever on a client that ignores TERM"
      kill -KILL -- "-$bg" 2>/dev/null; wait_gone "$bg" 5 || true
    fi
    if poll 10 no_proc "$mark/codex"; then ok "$label: no client process survives (marker $mark/codex)"
    else
      bad "$label: client process(es) survived: $(pgrep -f "$mark/codex" | tr '\n' ' ')"
      pkill -KILL -f "$mark/codex" 2>/dev/null
    fi
    left="$(ls -A "$RTMP" 2>/dev/null)"
    if [ -z "$left" ]; then ok "$label: the call's temp dir was removed"
    else bad "$label: left behind in TMPDIR: $left"; rm -rf "${RTMP:?}"/*; fi
  }
  term_ignore_case "TERM-ignoring client, GNU timeout, grace 2" 2 "" gnu
  term_ignore_case "TERM-ignoring client, a timeout that never escalates, grace 2" 2 "$NOESC" noesc
  term_ignore_case "TERM-ignoring client, ZUVO_TIMEOUT_GRACE=0" 0 "" grace0

  # The same `-k 0` on the BUDGET path, no runner TERM at all: GNU timeout TERMs the client at the
  # budget, never KILLs it, and the runner waited for ever. The grace must be at least 1 s. Run in
  # the background with a bounded wait — a synchronous call would hang this suite with it.
  L="TERM-ignoring client past its --timeout 2, ZUVO_TIMEOUT_GRACE=0"
  MARK3="$T/budget-grace0-marker-$$"; mkdir -p "$MARK3"; install_spy "$MARK3/codex"
  rm -f "$SPY_DIR"/*.rec "$T/budget-grace0.rc"
  # shellcheck disable=SC2016  # expanded by the child shell
  env -i HOME="$HOMEDIR" PATH="$BASE_PATH" CODEX_HOME="$RUN_CH" ZUVO_CODEX_APP_BIN=/nonexistent \
    SPY_DIR="$SPY_DIR" SPY_SLEEP=60 SPY_IGNORE_TERM=1 TMPDIR="$RTMP" ZUVO_CODEX_BIN="$MARK3/codex" \
    ZUVO_TIMEOUT_GRACE=0 \
    "$BASH" -c '. "$1"; cd "$2"; zms_run_codex --model m --access none --prompt-file "$3" --timeout 2 >/dev/null 2>&1
      echo "rc=$?" > "$4"' _ "$LIB" "$ROOT" "$PROMPT" "$T/budget-grace0.rc" >/dev/null 2>&1 &
  _bg=$!
  if wait_gone "$_bg" 15; then
    ok "$L: the runner returned within 15 s"
    case "$(cat "$T/budget-grace0.rc" 2>/dev/null)" in
      rc=124|rc=137) ok "$L: …timed out (124, or 137 when the client had to be KILLed)" ;;
      *) bad "$L: unexpected status [$(cat "$T/budget-grace0.rc" 2>/dev/null)]" ;; esac
  else
    bad "$L: the runner was STILL RUNNING 15 s in — the budget never ended a client that ignores TERM"
    pkill -KILL -f "$MARK3/codex" 2>/dev/null; wait_gone "$_bg" 5 || true
  fi
  spy_ran codex "$L"
  if poll 10 no_proc "$MARK3/codex"; then ok "$L: no client process survives"
  else bad "$L: client process(es) survived"; pkill -KILL -f "$MARK3/codex" 2>/dev/null; fi
  if poll 5 rtmp_empty; then ok "$L: the call's temp dir was removed"
  else bad "$L: left behind in TMPDIR: $(ls -A "$RTMP")"; rm -rf "${RTMP:?}"/*; fi

  # ── a client that exits but leaves a TERM-ignoring grandchild in its process group ──
  # GNU timeout leads a process group (setpgid, unless --foreground), and that group outlives timeout
  # for as long as any member lives. A client that exits promptly — TERMed with the runner, TERMed at
  # its budget, or simply done — can leave a detached grandchild there that ignores TERM (SPY_ORPHAN:
  # a sleeping sh whose $0 is a marker path unique to the case). The reap returned as soon as timeout
  # itself had gone, and after the client's own exit it never ran at all: the grandchild lived on.
  orphan_case() { # orphan_case <label> <term|budget|exit> <expected rc=N>
    local label="$1" mode="$2" mark="$T/orphan-$2-$$" rcf="$T/orphan-$2.rc" bg sleep=60 secs=120 setup_bad
    mkdir -p "$mark"; install_spy "$mark/codex"; rm -f "$rcf" "$SPY_DIR"/*.rec
    case "$mode" in budget) secs=2 ;; exit) sleep=0 ;; esac
    set -m
    # shellcheck disable=SC2016  # expanded by the child shell
    env -i HOME="$HOMEDIR" PATH="$BASE_PATH" CODEX_HOME="$RUN_CH" ZUVO_CODEX_APP_BIN=/nonexistent \
      SPY_DIR="$SPY_DIR" SPY_SLEEP="$sleep" SPY_ORPHAN="$mark/orphan" TMPDIR="$RTMP" \
      ZUVO_CODEX_BIN="$mark/codex" ZUVO_TIMEOUT_GRACE=2 \
      "$BASH" -c 'trap ": deferred until the runner returns" TERM; . "$1"; cd "$2"
        zms_run_codex --model m --access none --prompt-file "$3" --timeout "$5" >/dev/null 2>&1
        echo "rc=$?" > "$4"' _ "$LIB" "$ROOT" "$PROMPT" "$rcf" "$secs" >/dev/null 2>&1 &
    bg=$!
    set +m
    # Non-vacuous: the spy ran AND the grandchild really exists with its TERM-ignore in place. Without
    # either, "the grandchild did not survive" below would pass on a grandchild that never was — so
    # clean up and stop here, as term_ignore_case does. The runner's client and grandchild sit in
    # GNU timeout's own process group, beyond the KILL of the caller's: pkill them by marker path.
    if ! poll 30 test -s "$SPY_DIR/codex.rec"; then setup_bad="the spy never started within 30 s"
    elif [ ! -e "$mark/orphan.ready" ]; then setup_bad="the grandchild never signalled ready — the survival check would be vacuous"
    else setup_bad=""; fi
    if [ -n "$setup_bad" ]; then
      bad "$label: $setup_bad"
      kill -KILL -- "-$bg" 2>/dev/null; wait_gone "$bg" 5 || true
      pkill -KILL -f "$mark/" 2>/dev/null; rm -rf "${RTMP:?}"/*; return 0
    fi
    ok "$label: the grandchild was started, ignoring TERM"
    [ "$mode" != term ] || kill -TERM -- "-$bg" 2>/dev/null
    if wait_gone "$bg" 20; then expect_eq "$label: the runner's status" "$3" "$(cat "$rcf" 2>/dev/null)"
    else
      bad "$label: the runner was still running 20 s later"
      kill -KILL -- "-$bg" 2>/dev/null; wait_gone "$bg" 5 || true
    fi
    if poll 10 no_proc "$mark/orphan"; then ok "$label: the grandchild did not survive (marker $mark/orphan)"
    else
      bad "$label: the grandchild survived: $(pgrep -f "$mark/orphan" | tr '\n' ' ')"
      pkill -KILL -f "$mark/orphan" 2>/dev/null
    fi
    if poll 5 rtmp_empty; then ok "$label: the call's temp dir was removed"
    else bad "$label: left behind in TMPDIR: $(ls -A "$RTMP")"; rm -rf "${RTMP:?}"/*; fi
  }
  orphan_case "TERM mid-run, the client exits, its TERM-ignoring grandchild stays" term rc=143
  orphan_case "budget expires, the client exits on TERM, its grandchild stays" budget rc=124
  orphan_case "the client answers and exits 0, leaving a TERM-ignoring grandchild" exit rc=0

  # ── ZUVO_TIMEOUT_GRACE: digits only, at least 1, at most 3600 ──
  # Read back from timeout's own argv (a shim that records it, then execs the real one). A value past
  # the cap used to reach shell arithmetic whole: 30 digits wrapped around to a negative number without
  # a word — and a long grace is a runner that sits out an hour on a client that ignores TERM.
  RECTO="$T/recording-timeout"; mkdir -p "$RECTO"
  for _n in timeout gtimeout; do
    { printf '#!/bin/sh\n'; printf 'printf "%%s\\n" "$@" > "%s"\n' "$T/timeout.args"; printf 'exec "%s" "$@"\n' "$_real_to"; } > "$RECTO/$_n"
    chmod +x "$RECTO/$_n"
  done
  grace_case() { # grace_case <ZUVO_TIMEOUT_GRACE> <expected -k value>
    rm -f "$T/timeout.args"
    out="$(rrun codex PATH="$RECTO:$BASE_PATH" ZUVO_TIMEOUT_GRACE="$1" -- --model m --access none --prompt-file "$PROMPT" --timeout 60)"
    expect_eq "ZUVO_TIMEOUT_GRACE=[$1] → the client runs, timeout gets -k $2, nothing on stderr" "rc=0|-k|$2|60|" \
      "$out|$(head -3 "$T/timeout.args" 2>/dev/null | tr '\n' '|')$(cat "$T/zrun.err")"
  }
  grace_case 123456789012345678901234567890 3600
  grace_case 99999 3600
  grace_case 4000 3600
  grace_case 3600 3600
  grace_case 0012 12
  grace_case 0 1
  grace_case 000 1
  grace_case abc 15
  grace_case -5 15
  grace_case 1.5 15
  rtmp_clean "grace cases"
else
  bad "no GNU timeout/gtimeout on this machine — the runner timeout cases cannot run"
fi

# ── 9h. stderr: captured, never on stdout ──
L="stderr capture"
out="$(rrun codex SPY_STDERR='AUTH_TOKEN=sekret-zms-test' -- --model m --access none --prompt-file "$PROMPT" --timeout 60 --stderr-file "$ERRF")"
expect_eq "$L: exit 0" "rc=0" "$out"
spy_ran codex "$L"
expect_has "$L: the client's stderr is in the --stderr-file" "AUTH_TOKEN=sekret-zms-test" "$(cat "$ERRF" 2>/dev/null)"
case "$(cat "$T/run.out")" in *sekret*) bad "$L: the client's stderr reached the runner's STDOUT" ;;
  *) ok "$L: the token never appears on the runner's stdout" ;; esac
case "$(cat "$T/zrun.err")" in *sekret*) bad "$L: the client's stderr ALSO reached the runner's stderr" ;;
  *) ok "$L: with --stderr-file the runner's own stderr stays clean" ;; esac
rtmp_clean "$L"
out="$(rrun codex SPY_STDERR='client-diagnostic-line' -- --model m --access none --prompt-file "$PROMPT" --timeout 60)"
expect_has "without --stderr-file the client's stderr passes through to the runner's stderr" \
  "client-diagnostic-line" "$(cat "$T/zrun.err")"
case "$(cat "$T/run.out")" in *client-diagnostic-line*) bad "…but it reached stdout" ;; *) ok "…and not to stdout" ;; esac
rtmp_clean "stderr pass-through"
# Opening --stderr-file TRUNCATES it. Named as the prompt — the same path, or a symlink / hardlink to
# it — it emptied the prompt before the client read a byte, and the "review" of nothing exited 0. The
# prompt here is a COPY: the old runner destroyed whatever file this case handed it.
SAMEP="$T/same-prompt.txt"
same_file_case() { # same_file_case <label> <stderr-file> — <stderr-file> IS $SAMEP under another name
  out="$(rrun codex -- --model m --access none --prompt-file "$SAMEP" --timeout 60 --stderr-file "$2")"
  expect_eq "$1 → rc=2" "rc=2" "$out"
  expect_has "$1: stderr says the two must differ" "--stderr-file must differ from --prompt-file" "$(cat "$T/zrun.err")"
  spy_absent codex "$1"
  expect_eq "$1: the prompt file is byte-identical afterwards" "$PROMPT_SHA" "$(shasum -a 256 < "$SAMEP" | cut -d' ' -f1)"
}
cp "$PROMPT" "$SAMEP"
same_file_case "--stderr-file = --prompt-file (the same path)" "$SAMEP"
cp "$PROMPT" "$SAMEP"; ln -sf "$SAMEP" "$T/same-prompt-symlink"
same_file_case "--stderr-file is a SYMLINK to the prompt" "$T/same-prompt-symlink"
cp "$PROMPT" "$SAMEP"; rm -f "$T/same-prompt-hardlink"; ln "$SAMEP" "$T/same-prompt-hardlink"
same_file_case "--stderr-file is a HARDLINK to the prompt" "$T/same-prompt-hardlink"
rtmp_clean "stderr-file = prompt-file"
# A runner that cannot start leaves --stderr-file as it found it. It used to be opened — created, or
# truncated — BEFORE the temp dir, the CODEX_HOME and the auth check, so an rc=2 infrastructure failure
# left an empty capture file behind, or emptied one that still held the previous run's diagnostics.
NOSTART_ERRF="$T/stderr-not-yet.txt"
for _c in codex claude; do
  L="$_c: a TMPDIR mktemp -d cannot create in"
  rm -f "$NOSTART_ERRF"
  out="$(rrun "$_c" TMPDIR="$T/no-such-tmpdir" -- --model m --access none --prompt-file "$PROMPT" --timeout 60 --stderr-file "$NOSTART_ERRF")"
  expect_eq "$L → rc=2" "rc=2" "$out"
  spy_absent "$_c" "$L"
  if [ -e "$NOSTART_ERRF" ]; then bad "$L: the --stderr-file was created by a runner that never started"
  else ok "$L: the --stderr-file was not created"; fi
done
L="codex none, no auth.json and no OPENAI_API_KEY"
printf 'previous run diagnostics\n' > "$NOSTART_ERRF"
out="$(rrun codex CODEX_HOME="$T/ch-noauth-src" -- --model m --access none --prompt-file "$PROMPT" --timeout 60 --stderr-file "$NOSTART_ERRF")"
expect_eq "$L → rc=2" "rc=2" "$out"
spy_absent codex "$L"
expect_eq "$L: an existing --stderr-file is not truncated" "previous run diagnostics" "$(cat "$NOSTART_ERRF" 2>/dev/null)"
rtmp_clean "$L"
# Opened last, the file now fails to open AFTER the temp dir exists: the same status and message, and
# the EXIT trap still removes the temp dir (and the auth.json copy in it).
L="--stderr-file in a directory that does not exist"
out="$(rrun codex -- --model m --access none --prompt-file "$PROMPT" --timeout 60 --stderr-file "$T/no/such/dir/err")"
expect_eq "$L → rc=2" "rc=2" "$out"
expect_has "$L: stderr says why" "cannot write --stderr-file $T/no/such/dir/err" "$(cat "$T/zrun.err")"
rtmp_clean "$L"

# ── 9i. failures: missing client, missing timeout, missing auth.json, a failing client, usage ──
out="$(rrun codex ZUVO_CODEX_BIN=/nonexistent -- --model m --access none --prompt-file "$PROMPT" --timeout 60)"
expect_eq "codex unavailable (ZUVO_CODEX_BIN=/nonexistent) → rc=127, distinct from a client failure" "rc=127" "$out"
expect_has "…and stderr names the client" "codex" "$(cat "$T/zrun.err")"
out="$(rrun claude ZUVO_CLAUDE_BIN=/nonexistent -- --model m --access none --prompt-file "$PROMPT" --timeout 60)"
expect_eq "claude unavailable (ZUVO_CLAUDE_BIN=/nonexistent) → rc=127" "rc=127" "$out"
expect_has "…and stderr names the client" "claude" "$(cat "$T/zrun.err")"
rtmp_clean "missing client"

NTP="$T/no-timeout-bin"; mkdir -p "$NTP"
out="$(rrun codex PATH="$NTP" -- --model m --access none --prompt-file "$PROMPT" --timeout 60)"
expect_eq "no timeout/gtimeout on PATH → rc=2" "rc=2" "$out"
expect_has "…with 'GNU timeout required' on stderr" "GNU timeout required" "$(cat "$T/zrun.err")"
spy_absent codex "no timeout"
out="$(rrun claude PATH="$NTP" -- --model m --access none --prompt-file "$PROMPT" --timeout 60)"
expect_eq "claude runner: no timeout/gtimeout → rc=2 too" "rc=2" "$out"
spy_absent claude "no timeout (claude)"
rtmp_clean "no timeout"

mv "$RUN_CH/auth.json" "$T/auth.json.aside"
out="$(rrun codex -- --model m --access none --prompt-file "$PROMPT" --timeout 60)"
expect_eq "no auth.json in CODEX_HOME, --access none → rc=2 (cannot start)" "rc=2" "$out"
expect_has "…stderr names auth.json" "auth.json" "$(cat "$T/zrun.err")"
spy_absent codex "no auth.json, none"
out="$(rrun codex -- --model m --access read --read-root "$RROOT" --prompt-file "$PROMPT" --timeout 60)"
expect_eq "no auth.json in CODEX_HOME, --access read → rc=2 (cannot start)" "rc=2" "$out"
expect_has "…stderr names auth.json" "auth.json" "$(cat "$T/zrun.err")"
spy_absent codex "no auth.json, read"
out="$(rrun codex -- --model m --access agent --prompt-file "$PROMPT" --timeout 60)"
expect_eq "no auth.json, --access agent → the client still runs, as run_codex does today (env-key users)" "rc=0" "$out"
if spy_ran codex "no auth.json, agent"; then
  expect_eq "…its CODEX_HOME holds config.toml only" "config.toml " "$(rec codex codex_home_ls)"
fi
# API-key auth needs no auth.json: the codex CLI reads OPENAI_API_KEY from its environment. So none /
# read refuse only when there is neither. The key must reach the client through the environment and
# nowhere else — not argv, not config.toml, not any file in the call's temp dir, not stdout/stderr.
KEY='sk-zms-dummy-not-a-key-7f3a91'
for _acc in none read; do
  L="no auth.json + OPENAI_API_KEY, --access $_acc"
  if [ "$_acc" = read ]; then _ra=(--read-root "$RROOT"); else _ra=(); fi
  out="$(rrun codex OPENAI_API_KEY="$KEY" -- --model m --access "$_acc" ${_ra[@]+"${_ra[@]}"} \
    --prompt-file "$PROMPT" --timeout 60 --stderr-file "$ERRF")"
  expect_eq "$L → the client runs (rc=0)" "rc=0" "$out"
  if spy_ran codex "$L"; then
    expect_eq "$L: the key reached the client through its environment" "yes" "$(rec codex OPENAI_API_KEY_set)"
    expect_eq "$L: its CODEX_HOME holds config.toml only (nothing invented)" "config.toml " "$(rec codex codex_home_ls)"
    _n="$(rec codex key_scan_files)"
    if [ "${_n:-0}" -ge 1 ] 2>/dev/null; then ok "$L: the spy scanned the call's temp dir ($_n files)"
    else bad "$L: the temp-dir scan saw no files [$_n] — the next check would be vacuous"; fi
    expect_eq "$L: no file in the call's temp dir holds the key (scanned while the client ran)" "" "$(rec codex openai_key_in_tmp)"
  fi
  case "$(cat "$SPY_DIR/codex.rec" "$T/run.out" "$T/zrun.err" "$ERRF" 2>/dev/null)" in
    *"$KEY"*) bad "$L: the key appears in argv/config (spy record), stdout or stderr" ;;
    *) ok "$L: the key appears in no argv, config.toml, stdout or stderr" ;; esac
done
out="$(rrun codex OPENAI_API_KEY= -- --model m --access none --prompt-file "$PROMPT" --timeout 60)"
expect_eq "no auth.json + an EMPTY OPENAI_API_KEY → still refused (rc=2)" "rc=2" "$out"
expect_has "…stderr names auth.json" "auth.json" "$(cat "$T/zrun.err")"
spy_absent codex "no auth.json, empty OPENAI_API_KEY"
mv "$T/auth.json.aside" "$RUN_CH/auth.json"
rtmp_clean "no auth.json"

out="$(rrun codex SPY_EXIT=3 SPY_STDERR='boom: model not supported' -- --model m --access none --prompt-file "$PROMPT" --timeout 60 --stderr-file "$ERRF")"
expect_eq "a client that exits 3 → the runner returns 3" "rc=3" "$out"
spy_ran codex "failing client"
expect_has "…and its stderr is kept in the capture file" "boom: model not supported" "$(cat "$ERRF" 2>/dev/null)"
out="$(rrun claude SPY_EXIT=3 -- --model m --access agent --prompt-file "$PROMPT" --timeout 60)"
expect_eq "claude runner propagates a client's exit 3 too" "rc=3" "$out"
rtmp_clean "failing client"

usage_case() { # usage_case <label> <runner args...> — rc=2, nothing invoked
  local label="$1"; shift
  expect_eq "usage: $label → rc=2" "rc=2" "$(rrun codex -- "$@")"
  spy_absent codex "usage: $label"
}
usage_case "unknown --access" --model m --access full --prompt-file "$PROMPT" --timeout 60
usage_case "missing --access" --model m --prompt-file "$PROMPT" --timeout 60
usage_case "missing --model" --access none --prompt-file "$PROMPT" --timeout 60
usage_case "prompt file does not exist" --model m --access none --prompt-file "$T/nope.txt" --timeout 60
usage_case "--timeout 0" --model m --access none --prompt-file "$PROMPT" --timeout 0
usage_case "--timeout abc" --model m --access none --prompt-file "$PROMPT" --timeout abc
usage_case "missing --timeout" --model m --access none --prompt-file "$PROMPT"
usage_case "unknown option" --model m --access none --prompt-file "$PROMPT" --timeout 60 --yolo
usage_case "option without its value" --model m --access none --prompt-file "$PROMPT" --timeout
usage_case "stderr-file in a directory that does not exist" --model m --access none --prompt-file "$PROMPT" --timeout 60 --stderr-file "$T/no/such/dir/err"
usage_case "model id with a quote (TOML injection)" --model 'm" sandbox_mode = "danger-full-access' --access none --prompt-file "$PROMPT" --timeout 60
usage_case "model id with a TAB (control character)" --model "$(printf 'gpt-5.5\tx')" --access none --prompt-file "$PROMPT" --timeout 60
usage_case "model id with an ESC (control character)" --model "$(printf 'gpt-5.5\033[31m')" --access none --prompt-file "$PROMPT" --timeout 60
usage_case "effort with an ESC (control character)" --model m --effort "$(printf 'high\033')" --access none --prompt-file "$PROMPT" --timeout 60
rtmp_clean "usage cases"

# ── 9j. a RELATIVE TMPDIR ──
# mktemp -d under a relative TMPDIR returns a relative path. After the runner's `cd` into <tmp>/cwd
# that path pointed nowhere: the client got a CODEX_HOME / --mcp-config it could not find from its
# cwd, and the EXIT trap's rm -rf deleted nothing — the auth.json copy stayed on disk. The caller
# sits in the sandbox, so a relative TMPDIR lands there and never in the repo.
RELT="$T/reltmp-caller"; mkdir -p "$RELT/rel-tmp"
for _c in codex claude; do
  L="$_c none, relative TMPDIR"
  rm -f "$SPY_DIR"/*.rec
  # shellcheck disable=SC2016  # expanded by the child shell
  out="$(zrun 'cd "$D"; rc=0; zms_run_'"$_c"' --model m --access none --prompt-file "$P" --timeout 60 > /dev/null || rc=$?; echo "rc=$rc"' \
    D="$RELT" P="$PROMPT" SPY_DIR="$SPY_DIR" TMPDIR=rel-tmp CODEX_HOME="$RUN_CH" \
    ZUVO_CODEX_BIN="$SPYB/codex" ZUVO_CLAUDE_BIN="$SPYB/claude" ZUVO_TIMEOUT_GRACE=2)"
  expect_eq "$L: exit 0" "rc=0" "$out"
  if spy_ran "$_c" "$L"; then
    # The client runs from another cwd: handed the RELATIVE value, its TMPDIR named a directory that
    # does not exist there. It must get the caller's directory, absolute — not the call's temp dir.
    _td="$(rec "$_c" tmpdir)"
    case "$_td" in /*) ok "$L: the client's TMPDIR is absolute" ;;
      *) bad "$L: the client's TMPDIR is relative [$_td] — from its cwd it names nothing" ;; esac
    if [ -d "$_td" ] && [ "$_td" -ef "$RELT/rel-tmp" ]; then
      ok "$L: …an existing directory, the one the caller meant (not the call's temp dir)"
    else bad "$L: the client's TMPDIR [$_td] is not the caller's $RELT/rel-tmp"; fi
    if [ "$_c" = codex ]; then
      _ch="$(rec codex CODEX_HOME)"
      case "$_ch" in /*) ok "$L: CODEX_HOME is absolute" ;; *) bad "$L: CODEX_HOME is relative [$_ch]" ;; esac
      expect_eq "$L: …and the client finds auth.json + config.toml in it" "auth.json config.toml " "$(rec codex codex_home_ls)"
      expect_under "$L: …under the relative TMPDIR, resolved against the caller's cwd" "$_ch" "$RELT/rel-tmp"
    else
      _mcp="$(rec claude mcp_file)"
      case "$_mcp" in /*) ok "$L: --mcp-config is absolute" ;; *) bad "$L: --mcp-config is relative [$_mcp]" ;; esac
      expect_eq "$L: …and the client can read it" "$MCP_EMPTY" "$(rec claude mcp_content)"
    fi
  fi
  _left="$(ls -A "$RELT/rel-tmp" 2>/dev/null)"
  if [ -z "$_left" ]; then ok "$L: the call's temp dir was removed"
  else bad "$L: left behind under the relative TMPDIR: $_left"; rm -rf "${RELT:?}/rel-tmp"/*; fi
done

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
