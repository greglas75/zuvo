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

echo "== model-subprocess library (bash $BASH_VERSION) =="

# ── hermetic sandbox ─────────────────────────────────────────────────────────
T="$(mktemp -d)" || { echo "  FAIL mktemp -d failed" >&2; exit 1; }
[ -n "$T" ] && [ -d "$T" ] || { echo "  FAIL mktemp -d returned an empty path or no directory" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
# Resolved (macOS /var → /private/var) because the library returns resolved paths. Guarded: an
# empty $T here would turn every "$T/…" below into a path at the filesystem root.
T="$(cd "$T" && pwd -P)" && [ -n "$T" ] || { echo "  FAIL cannot resolve the sandbox path" >&2; exit 1; }

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

ZMS_FUNCS="zms_is_codex_host zms_codex_host_model zms_codex_bin zms_claude_bin zms_client_available zms_client_for_model zms_source_registry zms_is_auth_stub zms_codex_cli_guard"

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
  # `timeout -k 2` sends TERM at the 1s budget and KILL 2s later if still alive; give that grace
  # period, then confirm the sleeping fake did not survive. Searched by its own unique marker path
  # (MARKER_BIN, distinct from every other fake in this file), not a bare `pgrep sleep`, which would
  # also match unrelated sleeps already running on a shared dev machine.
  sleep 3
  leftover="$(pgrep -f "$MARKER_BIN" 2>/dev/null || true)"
  if [ -z "$leftover" ]; then ok "no leftover sleeping fake process survives (marker: $MARKER_BIN)"
  else bad "leftover process(es) still running after the timeout: $leftover"; fi
  # A non-numeric budget falls back to the default instead of breaking the probe: handed to timeout
  # as-is, `abc` is an invalid interval, --version never answers and a NEW CLI is downgraded for nothing.
  fake_codex 0.156.1
  expect_eq "ZUVO_CODEX_VERSION_TIMEOUT=abc → default budget, the real version is still read" "gpt-6-sol" \
    "$(zrun "set -- gpt-6-sol; $GUARDQ" ZUVO_CODEX_BIN="$GV/codex" ZUVO_CODEX_VERSION_TIMEOUT=abc)"
  expect_eq "…and nothing was WARNed" "" "$(cat "$T/zrun.err")"
else
  bad "no GNU timeout/gtimeout on this machine — the bounded --version cases cannot run"
fi

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
