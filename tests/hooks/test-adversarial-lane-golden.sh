#!/usr/bin/env bash
#
# test-adversarial-lane-golden.sh — the adversarial driver's codex and claude lanes run through the
# shared runner (scripts/lib/model-subprocess.sh) and still reach their clients EXACTLY as before.
#
# Plan A, Task 4 moved the driver's own "run a Codex / Claude CLI safely" code onto the library. The
# refactor must not change what a client sees, and the only way to prove that is a CHARACTERIZATION:
# the pre-refactor driver was run once, in a throwaway worktree of its commit, against SPY clients,
# and what the spies recorded is kept in tests/hooks/fixtures/adversarial-lane-golden/<lane>.rec
# (its header names the driver blob it was recorded from). This file replays the same two runs
# against the working tree and diffs the records. What the golden holds, per client invocation:
#   argv (one element per line), cwd / $PWD / $OLDPWD as a CLASS, the $TMPDIR the client got,
#   CODEX_HOME as a class + its listing + the auth.json hash + config.toml verbatim, the MCP config
#   (path class + content), whether OPENAI_API_KEY was set, and stdin (byte count + sha256).
# Normalised away, and only these: the per-run temp names ($T and its /var vs /private/var forms;
# the per-call temp dir → <RUN_TMP> — the old driver's JSON_TMPDIR sat in mktemp's default dir, which
# on macOS is /var/folders/…/T whatever $TMPDIR says, the runner's sits under $TMPDIR; the isolated
# CODEX_HOME's own name), the spy's pid, and the CODEX_HOME permission bits — the runner creates it
# 0700 (the old driver left it at the umask default inside its 0700 temp dir); that one hardening is
# asserted positively below. The $TMPDIR the CLIENT receives is compared as is (<T>/tmp).
#
# The rest pins what the refactor ADDS, each case red against the pre-refactor driver:
#   * ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN are honoured for INVOCATION and for DETECTION, and a SET value
#     is final — never a fall-through to PATH or to /Applications/Codex.app;
#   * the provider-health ledger follows ZUVO_HOME (tests stop writing the real ~/.zuvo);
#   * without the library the driver warns ONCE, its codex/claude lanes fail with a named error, and
#     every other lane still runs; a short answer is excluded as `unverified` — never cached for the
#     run nor benched in the ledger as an auth failure (with the library: `auth`, exactly as before);
#   * an excluded lane stays excluded when its result file cannot be removed, and a failure WARN
#     quotes the client's stderr terminal-safe (no control characters, at most 300 characters);
#   * source: the driver no longer builds a CODEX_HOME or probes `codex --version` itself.
#
# Hermetic: every driver run is `env -i` with a temp HOME/ZUVO_HOME, TMPDIR under the sandbox, a copy
# of the fixture CODEX_HOME holding a DUMMY auth.json, and an explicit PATH of spies + symlinks to the
# real timeout/gtimeout/jq (the driver exits without timeout before any client would run). Clients
# are spies or decoys; no real model CLI runs and nothing touches the network. Every lane case first
# asserts the spy's record exists, so a run that never dispatched cannot pass.
#
# Run (both shells; the DRIVER always runs under the bash found on the narrowed PATH, /bin/bash):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-lane-golden.sh
#   TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/test-adversarial-lane-golden.sh
# Re-characterize (only when the pre-refactor behaviour itself is meant to change — never to make a
# red golden pass): record from a worktree of the commit whose driver is the reference,
#   ZUVO_GOLDEN_RECORD=1 ZUVO_TEST_AR=<worktree>/scripts/adversarial-review.sh \
#     TF_ALLOW_LOCAL=1 bash tests/hooks/test-adversarial-lane-golden.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
# ZUVO_TEST_AR runs every case against ANOTHER driver copy (the pre-refactor one, to show the cases
# are red there); default: the working tree's.
AR="${ZUVO_TEST_AR:-$ROOT/scripts/adversarial-review.sh}"
GOLD="$ROOT/tests/hooks/fixtures/adversarial-lane-golden"
FIXD="$ROOT/tests/hooks/fixtures/model-subprocess"
PASS=0; FAIL=0
ok()  { echo "  PASS $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
# A failure quotes what it looked at — cut to 300 bytes: a source assertion's subject is a whole function.
cut300() { if [ "${#1}" -gt 300 ]; then printf '%s…' "${1:0:300}"; else printf '%s' "$1"; fi; }
expect_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$(cut300 "$3")]"; fi; }
expect_has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — [$2] not found in [$(cut300 "$3")]" ;; esac; }
expect_not() { case "$3" in *"$2"*) bad "$1 — [$2] found in [$(cut300 "$3")]" ;; *) ok "$1" ;; esac; }
# fn_body <file> <function> — the function's definition: up to its closing `}` line, or the definition
# line alone when it closes on the same line (a one-line wrapper).
fn_body() {
  awk -v f="$2" '$0 ~ "^" f "\\(\\)" { on = 1; print; if ($0 ~ /}[[:space:]]*$/) exit; next }
                 on { print } on && /^}/ { exit }' "$1"
}

echo "== adversarial lanes on the shared runner (test bash $BASH_VERSION) =="
[ -f "$AR" ] || { echo "  FAIL driver not found: $AR"; exit 1; }
echo "  note: driver under test: $AR"

# ── hermetic sandbox ─────────────────────────────────────────────────────────
T_LOG="$(mktemp -d)" || { echo "  FAIL mktemp -d failed" >&2; exit 1; }
[ -n "$T_LOG" ] && [ -d "$T_LOG" ] || { echo "  FAIL mktemp -d returned an empty path or no directory" >&2; exit 1; }
# chflags first: case 5c (5) makes a result file user-immutable, which rm -rf alone cannot remove.
trap 'chflags -R nouchg "$T_LOG" 2>/dev/null; rm -rf "$T_LOG"' EXIT
# Physical: the spy records `pwd -P`, and a logical /var/… here against a physical /private/var/…
# there would never match. Both spellings are normalised to <T>.
T="$(cd "$T_LOG" && pwd -P)" && [ -n "$T" ] || { echo "  FAIL cannot resolve the sandbox path" >&2; exit 1; }
command -v shasum >/dev/null 2>&1 \
  || { echo "  FAIL shasum required — without it every stdin hash is empty on both sides and compares equal" >&2; exit 1; }

# Real coreutils resolved BEFORE PATH is narrowed: the driver hard-exits without `timeout`, and a golden
# recorded from a run that never dispatched would be worthless.
SHIM="$T/shim"; mkdir -p "$SHIM"
# shellcheck source=tests/lib/hermetic-tools.sh
. "$ROOT/tests/lib/hermetic-tools.sh"
hermetic_link_tools "$SHIM" timeout gtimeout jq
[ -e "$SHIM/timeout" ] || { echo "  FAIL no GNU timeout on this machine — the driver cannot run" >&2; exit 1; }
[ -e "$SHIM/jq" ] || { echo "  FAIL no jq on this machine — the driver cannot run" >&2; exit 1; }

# The spy must SEE the OLDPWD a real client would get. macOS /bin/sh (bash 3.2) drops an inherited
# OLDPWD at startup; dash keeps it. Same selection as tests/hooks/test-model-subprocess.sh.
keeps_oldpwd() { env OLDPWD=/ "$1" -c '[ "${OLDPWD:-}" = / ]' 2>/dev/null; }
SPY_SH=""
for _s in /bin/sh /bin/dash /usr/bin/dash; do
  if [ -x "$_s" ] && keeps_oldpwd "$_s"; then SPY_SH="$_s"; break; fi
done
# The fixture spy REWRITES <name>.rec and <name>.stdin on every run, so a second invocation of the
# same client leaves the same two files behind. This line, put in front of the spy's body, is the
# only thing that can tell one call from two: every invocation (--version included) appends its
# first argument to $SPY_DIR/<name>.calls. It writes nothing the spy records.
# shellcheck disable=SC2016  # expanded by the spy, not here
SPY_CALL_LOG='[ -z "${SPY_DIR:-}" ] || { printf "%s\n" "${1:-}" >> "$SPY_DIR/${0##*/}.calls"; } 2>/dev/null'
install_spy() { # install_spy <dest> — the fixture spy (records what the client saw, then answers)
  { if [ -n "$SPY_SH" ]; then printf '#!%s\n' "$SPY_SH"; else head -1 "$FIXD/spy-cli"; fi
    printf '%s\n' "$SPY_CALL_LOG"
    tail -n +2 "$FIXD/spy-cli"; } > "$1"
  chmod +x "$1"
}
# A DECOY: a client on PATH that must NOT be the one invoked. It answers like a client, so a driver
# that picks it up still completes — but it leaves $T/decoy.<name>, which the case then reads. It also
# keeps the pre-refactor driver away from any real client: that driver takes whatever is on PATH.
install_decoy() { # install_decoy <dest>
  printf '#!/bin/sh\n: > "%s/decoy.${0##*/}"\n[ "${1:-}" = --version ] && { echo "codex-cli 0.156.1"; exit 0; }\ncat > /dev/null\necho "DECOY-REPLY ${0##*/}"\n' "$T" > "$1"
  chmod +x "$1"
}
SPY_BIN="$T/spybin"; OFF_BIN="$T/offpath"; DECOY_BIN="$T/decoybin"; MOCK_BIN="$T/mockbin"
mkdir -p "$SPY_BIN" "$OFF_BIN" "$DECOY_BIN" "$MOCK_BIN" "$T/tmp" "$T/work"
install_spy "$SPY_BIN/codex"; install_spy "$SPY_BIN/claude"
install_spy "$OFF_BIN/codex"; install_spy "$OFF_BIN/claude"
install_decoy "$DECOY_BIN/codex"; install_decoy "$DECOY_BIN/claude"
# mock-ok answers like a real reviewer — LONGER than 600 B: without the shared runner the driver
# excludes any short answer as unverified (fail closed), so a toy one-liner would be discarded.
# mock-login answers only a short login stub, worded so the runner's token list would NOT catch it.
cat > "$MOCK_BIN/mock-ok" <<'MOCK'
#!/bin/sh
cat > /dev/null
cat <<'REVIEW'
SEVERITY: WARNING
FILE: src/auth.ts:12
ISSUE: MOCK-OK review — the new length check accepts any string longer than eight characters as a
valid token. Nothing verifies the signature or the expiry, so a random 9-character value passes.
FIX: verify the token against the issuer (signature + exp) before trusting its length.

SEVERITY: INFO
FILE: src/auth.ts:11
ISSUE: the early `return false` for an empty token and the new length check return the same type
through two different paths; a caller cannot tell "missing" from "too short" when logging a denial.
FIX: return a reason (or throw a typed error) so a rejected login can be diagnosed.

SEVERITY: INFO
FILE: src/auth.ts:13
ISSUE: no test covers the boundary (8 vs 9 characters) that this change introduces.
FIX: add a table test for lengths 0, 8 and 9.
REVIEW
MOCK
printf '#!/bin/sh\ncat > /dev/null\necho "Please run login"\n' > "$MOCK_BIN/mock-login"
# mock-authstub: a login stub the runner's token list DOES catch ("not logged in").
printf '#!/bin/sh\ncat > /dev/null\necho "Error: Not logged in. Please run /login"\n' > "$MOCK_BIN/mock-authstub"
chmod +x "$MOCK_BIN/mock-ok" "$MOCK_BIN/mock-login" "$MOCK_BIN/mock-authstub"
mkdir -p "$T/app"; printf '#!/bin/sh\n: > "%s/decoy.app"\necho APP\n' "$T" > "$T/app/codex"; chmod +x "$T/app/codex"
FIX_CH="$T/codex-home"; cp -R "$FIXD/codex-home" "$FIX_CH"   # dummy auth.json + a hostile user config
WORK="$T/work"
BASE_PATH="$SHIM:/usr/bin:/bin"
if [ -n "$SPY_SH" ]; then echo "  note: spy interpreter $SPY_SH (keeps an inherited OLDPWD)"
else echo "  note: no sh here keeps an inherited OLDPWD — the golden still compares it, as recorded"; fi

DIFF='diff --git a/src/auth.ts b/src/auth.ts
--- a/src/auth.ts
+++ b/src/auth.ts
@@ -10,3 +10,4 @@
 export function checkToken(token: string) {
   if (!token) return false;
+  return token.length > 8;
 }
'

# drive <tag> <PATH> [VAR=value ...] -- <driver args...> — one driver run from $WORK, `env -i`, a fresh
# HOME (no ledger, no cooldowns carried between cases), the fixed diff on stdin. Output in $T/<tag>.out
# and $T/<tag>.err; status = the driver's. The interpreter is the `bash` the narrowed PATH finds
# (/bin/bash): the SAME for recording and replay, whichever shell runs this file.
drive() {
  local tag="$1" path="$2" h rc=0 envs=(); shift 2
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  h="$T/home-$tag"; rm -rf "$h"; mkdir -p "$h"
  ( cd "$WORK" && printf '%s' "$DIFF" | env -i HOME="$h" ZUVO_HOME="$h/.zuvo" TMPDIR="$T/tmp" \
      CODEX_HOME="$FIX_CH" ZUVO_NO_CAFFEINATE=1 PATH="$path" ${envs[@]+"${envs[@]}"} \
      bash "$AR" "$@" ) > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  return "$rc"
}

# Where a bare `mktemp -d` lands under the drivers' environment. Not always $TMPDIR: macOS mktemp
# ignores TMPDIR without a template and uses the per-user /var/folders/…/T — which is where the
# pre-refactor driver's temp dir (and the CODEX_HOME inside it) lived. Probed, never assumed.
_probe="$(cd "$WORK" && env -i HOME="$T" PATH=/usr/bin:/bin TMPDIR="$T/tmp" mktemp -d)" \
  || { echo "  FAIL cannot probe mktemp's default directory" >&2; exit 1; }
SYS_TMP_LOG="${_probe%/*}"; rmdir "$_probe"
SYS_TMP="$(cd "$SYS_TMP_LOG" && pwd -P)" && [ -n "$SYS_TMP" ] || { echo "  FAIL cannot resolve $SYS_TMP_LOG" >&2; exit 1; }

# normalize <raw spy record> — the golden view of one invocation (see the header for what is kept).
# Each prefix is replaced physical-first: a logical /var/… is a SUBSTRING of /private/var/…, so the
# other order would leave "/private<T>". $T goes before the system temp dir because $T usually lies
# inside it. A per-run temp dir directly under either ($TMPDIR = <T>/tmp, or mktemp's default) is
# <RUN_TMP>: the old driver's JSON_TMPDIR and the runner's own dir are both exactly that.
normalize() {
  awk -v tp="$T" -v tl="$T_LOG" -v sp="$SYS_TMP" -v sl="$SYS_TMP_LOG" '
    function lit(s, a, b,   o, i) { o = ""; while (a != "" && (i = index(s, a)) > 0) { o = o substr(s, 1, i - 1) b; s = substr(s, i + length(a)) } return o s }
    function norm(s) {
      s = lit(s, tp, "<T>"); s = lit(s, tl, "<T>"); s = lit(s, sp, "<SYS_TMP>"); s = lit(s, sl, "<SYS_TMP>")
      gsub(/<T>\/tmp\/[^\/]+/, "<RUN_TMP>", s); gsub(/<SYS_TMP>\/[^\/]+/, "<RUN_TMP>", s); return s
    }
    { e = index($0, "="); k[NR] = substr($0, 1, e - 1); v[NR] = norm(substr($0, e + 1)); if (k[NR] == "CODEX_HOME") ch = v[NR] }
    END {
      for (i = 1; i <= NR; i++) {
        if (k[i] == "pid" || k[i] == "codex_home_mode") continue
        x = v[i]
        if (k[i] == "CODEX_HOME" && x ~ /^<RUN_TMP>\//) x = "<RUN_TMP>/<isolated CODEX_HOME>"
        else if (ch != "" && x == ch && k[i] ~ /^(pwd_P|PWD|PWD_P|OLDPWD|OLDPWD_P)$/) x = "<CODEX_HOME>"
        print k[i] "=" x
      }
    }' "$1"
}

# golden_run <provider> <client> — the characterization run: host = Claude Code with CLAUDE_MODEL=opus
# (so claude_reviewer_model is deterministic), every other host signal absent (env -i), clients =
# spies on PATH. Leaves the spy record in $T/gspy-<client>/<client>.rec; status = the driver's.
golden_run() {
  rm -rf "$T/gspy-$2"; mkdir -p "$T/gspy-$2"
  drive "gold-$2" "$SPY_BIN:$BASE_PATH" SPY_DIR="$T/gspy-$2" ZUVO_CODEX_APP_BIN=/nonexistent \
    CLAUDECODE=1 CLAUDE_MODEL=opus -- --mode code --provider "$1"
}

# The NUMBER of client invocations is part of the golden: the .rec compares the last one only.
# golden_calls <client> — what the reference driver ran, in order, first argument of each call:
#   codex  — codex_cli_guard's `--version` probe (gpt-6-sol needs CLI >= 0.156), then ONE `exec`;
#   claude — ONE `--model …` call, nothing else.
# Taken from the reference blob named in the fixture header (this file run with ZUVO_TEST_AR = that
# blob): re-characterizing a driver that calls its clients differently updates this with the fixture.
golden_calls() { case "$1" in codex) echo "--version exec" ;; claude) echo "--model" ;; esac; }
spy_files() { ls -A "$T/gspy-$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
spy_calls() { tr '\n' ' ' < "$T/gspy-$1/$1.calls" 2>/dev/null | sed 's/ $//'; }

# ── record mode: only ever against the reference (pre-refactor) driver ──────────
if [ "${ZUVO_GOLDEN_RECORD:-}" = "1" ]; then
  ardir="$(cd "$(dirname "$AR")/.." && pwd -P)"
  blob="$(git -C "$ardir" rev-parse HEAD:scripts/adversarial-review.sh 2>/dev/null)" \
    || { echo "  FAIL record: $AR is not scripts/adversarial-review.sh of a git checkout"; exit 1; }
  # The golden names ONE blob: a driver with uncommitted edits is not that blob, so it is refused.
  [ "$(git -C "$ardir" hash-object "$AR")" = "$blob" ] \
    || { echo "  FAIL record: $AR differs from HEAD:scripts/adversarial-review.sh ($blob) — refusing to record"; exit 1; }
  for _pair in codex-5.3:codex claude:claude; do
    rc=0; golden_run "${_pair%%:*}" "${_pair##*:}" || rc=$?
    [ "$rc" = 0 ] || { echo "  FAIL record: the ${_pair%%:*} run exited $rc — see $T/gold-${_pair##*:}.err"; cat "$T/gold-${_pair##*:}.err"; exit 1; }
  done
  # Both records must exist BEFORE anything is saved: a golden from a run that never dispatched is a
  # file of nothing that every later run would match.
  for _c in codex claude; do
    [ -s "$T/gspy-$_c/$_c.rec" ] || { echo "  FAIL record: the $_c spy never ran — nothing saved"; exit 1; }
    # …and hold exactly what the reference's calls leave: a record of the LAST of several calls would
    # otherwise be saved as if it were the only one.
    [ "$(spy_files "$_c")" = "$_c.calls $_c.rec $_c.stdin" ] \
      || { echo "  FAIL record: the $_c spy dir holds [$(spy_files "$_c")] — nothing saved"; exit 1; }
    [ "$(spy_calls "$_c")" = "$(golden_calls "$_c")" ] \
      || { echo "  FAIL record: the $_c client was called [$(spy_calls "$_c")], golden_calls says [$(golden_calls "$_c")] — update golden_calls with the re-characterization; nothing saved"; exit 1; }
  done
  mkdir -p "$GOLD"
  for _pair in codex-5.3:codex claude:claude; do
    _p="${_pair%%:*}"; _c="${_pair##*:}"
    { echo "# adversarial-lane golden: what the $_c client saw for \`adversarial-review.sh --mode code --provider $_p\`"
      echo "# driver-blob: $blob (git rev-parse HEAD:scripts/adversarial-review.sh at recording)"
      echo "# host: CLAUDECODE=1 CLAUDE_MODEL=opus, every other signal absent (env -i); clients: tests/hooks/fixtures/model-subprocess/spy-cli"
      echo "# written by: ZUVO_GOLDEN_RECORD=1 tests/hooks/test-adversarial-lane-golden.sh — never edit by hand"
      normalize "$T/gspy-$_c/$_c.rec"
    } > "$GOLD/$_p.rec"
    echo "  recorded $GOLD/$_p.rec ($(awk '!/^#/' "$GOLD/$_p.rec" | wc -l | tr -d ' ') lines, driver blob $blob)"
  done
  exit 0
fi

# ── 1. golden: the codex and claude lanes invoke their clients exactly as before ──
echo "-- 1. golden characterization (driver blob of the reference: $(awk '/^# driver-blob:/ {print $3; exit}' "$GOLD/codex-5.3.rec" 2>/dev/null))"
for _pair in codex-5.3:codex claude:claude; do
  _p="${_pair%%:*}"; _c="${_pair##*:}"; L="golden $_p"
  if [ ! -s "$GOLD/$_p.rec" ]; then bad "$L: no golden fixture at $GOLD/$_p.rec"; continue; fi
  _blob="$(awk '/^# driver-blob:/ {print $3; exit}' "$GOLD/$_p.rec")"
  case "$_blob" in *[!0-9a-f]*|'') bad "$L: the fixture header names no driver blob" ;;
    *) if [ "${#_blob}" -eq 40 ]; then ok "$L: the fixture names the driver blob it was recorded from"
       else bad "$L: driver blob [$_blob] is not a 40-hex sha"; fi ;; esac
  rc=0; golden_run "$_p" "$_c" || rc=$?
  expect_eq "$L: the driver exits 0" "0" "$rc"
  if [ -s "$T/gspy-$_c/$_c.rec" ]; then ok "$L: the $_c spy ran (.rec present)"
  else bad "$L: the $_c spy never ran — $(tail -3 "$T/gold-$_c.err" | tr '\n' ' ')"; continue; fi
  expect_has "$L: the spy's answer is the review" "SPY-REPLY $_c" "$(cat "$T/gold-$_c.out")"
  expect_eq "$L: the spy dir holds one client's files and nothing else" "$_c.calls $_c.rec $_c.stdin" "$(spy_files "$_c")"
  expect_eq "$L: the $_c client was called as often as by the reference, in the same order" \
    "$(golden_calls "$_c")" "$(spy_calls "$_c")"
  normalize "$T/gspy-$_c/$_c.rec" > "$T/replay-$_p.rec"
  awk '!/^#/' "$GOLD/$_p.rec" > "$T/golden-$_p.body"
  if d="$(diff "$T/golden-$_p.body" "$T/replay-$_p.rec")"; then
    ok "$L: argv, cwd class, CODEX_HOME listing, config.toml, MCP config and stdin are identical to the golden"
  else
    bad "$L: the client saw something different from the golden:"; printf '%s\n' "$d" | sed 's/^/      /'
  fi
done
# The one normalised-away field, asserted positively: the runner's CODEX_HOME is private (0700).
_m="$(awk -F= '$1 == "codex_home_mode" {print $2}' "$T/gspy-codex/codex.rec" 2>/dev/null)"
expect_eq "golden codex-5.3: the isolated CODEX_HOME is mode 700 (it holds the auth.json copy)" "700" "$_m"

# ── 1b. the codex-5.4 (alt) lane at RUNTIME: its own model and effort reach the client ──────────
# The golden drives codex-5.3 only; tests/adversarial/test-codex-lane-defaults.sh cx.7 checks the
# per-lane variables by SOURCE text. This runs the alt lane against the codex spy and reads what the
# client got. Expected values are not typed here: they come from the registry the driver loads in
# this layout (<driver>/../shared/includes/model-registry.sh; the repo's when a copy has none),
# sourced in a clean environment — and they must differ from the primary lane's, or this case could
# not tell the two lanes apart.
echo "-- 1b. codex-5.4 lane at runtime"
_reg="$(cd "$(dirname "$AR")/.." 2>/dev/null && pwd -P)/shared/includes/model-registry.sh"
[ -f "$_reg" ] || _reg="$ROOT/shared/includes/model-registry.sh"
reg_val() { env -i PATH=/usr/bin:/bin bash -c '. "$1" && eval "printf %s \"\${$2}\""' _ "$_reg" "$1"; }
_alt_m="$(reg_val ZUVO_MODEL_CODEX_ALT)"; _alt_e="$(reg_val ZUVO_CODEX_EFFORT_ALT)"
_pri_m="$(reg_val ZUVO_MODEL_CODEX_PRIMARY)"; _pri_e="$(reg_val ZUVO_CODEX_EFFORT_PRIMARY)"
L="1b codex-5.4"
if [ -n "$_alt_m" ] && [ -n "$_alt_e" ] && [ "$_alt_m" != "$_pri_m" ] && [ "$_alt_e" != "$_pri_e" ]; then
  ok "$L: premise — the registry gives the alt lane its own model and effort ($_alt_m/$_alt_e vs $_pri_m/$_pri_e)"
else
  bad "$L: premise — registry values unusable: alt=[$_alt_m/$_alt_e] primary=[$_pri_m/$_pri_e] ($_reg)"
fi
rm -rf "$T/gspy-codex54"; mkdir -p "$T/gspy-codex54"
rc=0; drive "alt-codex54" "$SPY_BIN:$BASE_PATH" SPY_DIR="$T/gspy-codex54" ZUVO_CODEX_APP_BIN=/nonexistent \
  CLAUDECODE=1 CLAUDE_MODEL=opus -- --mode code --provider codex-5.4 || rc=$?
expect_eq "$L: the driver exits 0" "0" "$rc"
_r="$T/gspy-codex54/codex.rec"
if [ -s "$_r" ]; then
  ok "$L: the codex spy ran (.rec present)"
  _rv="$(cat "$_r")"
  expect_eq "$L: argv is the lane's exec invocation" "exec --skip-git-repo-check" \
    "$(awk -F= '$1 == "arg" {print substr($0, 5)}' "$_r" | tr '\n' ' ' | sed 's/ $//')"
  expect_has "$L: config.toml names the alt model" "config=model = \"$_alt_m\"" "$_rv"
  expect_has "$L: config.toml carries the alt effort" "config=model_reasoning_effort = \"$_alt_e\"" "$_rv"
  expect_not "$L: config.toml does not name the primary model" "config=model = \"$_pri_m\"" "$_rv"
  expect_not "$L: config.toml does not carry the primary effort" "config=model_reasoning_effort = \"$_pri_e\"" "$_rv"
  expect_eq "$L: the client was probed (--version) then run once (exec)" "--version exec" \
    "$(tr '\n' ' ' < "$T/gspy-codex54/codex.calls" 2>/dev/null | sed 's/ $//')"
  expect_has "$L: the spy's answer is the review" "SPY-REPLY codex" "$(cat "$T/alt-codex54.out")"
else
  bad "$L: the codex spy never ran — $(tail -3 "$T/alt-codex54.err" | tr '\n' ' ')"
fi

# ── 2. ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN are honoured for INVOCATION ──────────────
# The spy sits OFF the PATH and a decoy sits ON it: the pre-refactor driver took whatever was on PATH.
echo "-- 2. client seams: invocation"
for _pair in codex-5.3:codex:ZUVO_CODEX_BIN claude:claude:ZUVO_CLAUDE_BIN; do
  _p="${_pair%%:*}"; _rest="${_pair#*:}"; _c="${_rest%%:*}"; _v="${_rest#*:}"; L="$_v invocation"
  rm -rf "$T/ispy-$_c" "$T/decoy.$_c"; mkdir -p "$T/ispy-$_c"
  rc=0; drive "inv-$_c" "$DECOY_BIN:$BASE_PATH" SPY_DIR="$T/ispy-$_c" ZUVO_CODEX_APP_BIN=/nonexistent \
    "$_v=$OFF_BIN/$_c" CLAUDECODE=1 CLAUDE_MODEL=opus -- --mode code --provider "$_p" || rc=$?
  expect_eq "$L: the driver exits 0" "0" "$rc"
  if [ -s "$T/ispy-$_c/$_c.rec" ]; then ok "$L: the $_c spy named by $_v (off PATH) was invoked"
  else bad "$L: the $_c spy named by $_v was NOT invoked"; fi
  if [ -e "$T/decoy.$_c" ]; then bad "$L: the $_c on PATH was executed although $_v names another"
  else ok "$L: the $_c on PATH was never executed (not even --version)"; fi
done

# ── 2b. a client that cannot be started: the lane's WARN has no empty snippet ─────
# --provider bypasses detection, so the lane is dispatched with its client missing: the runner fails
# BEFORE the client starts (named error, exit 127) and never opens the lane's stderr capture. The
# lane's `failed (exit N): <first stderr line>` WARN then quoted nothing and ended in ": ".
echo "-- 2b. a missing client"
for _pair in codex-5.3:ZUVO_CODEX_BIN claude:ZUVO_CLAUDE_BIN; do
  _p="${_pair%%:*}"; _v="${_pair#*:}"; L="2b $_v=/nonexistent, --provider $_p"
  rc=0; drive "miss-$_p" "$BASE_PATH" "$_v=/nonexistent" ZUVO_CODEX_APP_BIN=/nonexistent \
    CLAUDECODE=1 CLAUDE_MODEL=opus -- --mode code --provider "$_p" || rc=$?
  expect_eq "$L: no review (exit 2)" "2" "$rc"
  _ev="$(ls -d "$T/home-miss-$_p/.zuvo/adversarial-failures"/*/ 2>/dev/null | head -1)"
  _e="$(cat "$_ev/provider_$_p.stderr" 2>/dev/null)"
  expect_has "$L: the runner's own named error is in the lane's stderr" "CLI not available" "$_e"
  _w="$(printf '%s\n' "$_e" | awk -v p="WARN: $_p failed (exit " 'index($0, p) > 0' | head -1)"
  if [ -z "$_w" ]; then bad "$L: no 'WARN: $_p failed (exit …)' line — [$(cut300 "$_e")]"
  else
    case "$_w" in
      *:|*": ") bad "$L: the WARN ends in an empty snippet — [$_w]" ;;
      *) ok "$L: the WARN names the exit status without an empty ': ' snippet — [$_w]" ;;
    esac
  fi
  # The runner's pre-flight errors go to ITS stderr, never to the lane's client capture (the library
  # opens that last, on purpose): the WARN printed no reason for exactly the runner's failure modes.
  expect_has "$L: …and quotes the RUNNER's reason (its own stderr: the client never started)" "CLI not available" "$_w"
done
# ── 2c. a model id the runner REJECTS before starting the client: the WARN says why ─────
# A quote in a model id (it would inject TOML into the isolated config.toml) is refused by the runner's
# pre-flight, exit 2, before any client starts — so the client capture is empty and only the runner's
# stderr holds the reason.
echo "-- 2c. a model id the runner rejects"
for _pair in 'codex-5.3:ZUVO_MODEL_CODEX_PRIMARY=gpt-5.5"x' 'claude:ZUVO_CLAUDE_REVIEWER_MODEL=claude-x"y'; do
  _p="${_pair%%:*}"; _kv="${_pair#*:}"; L="2c ${_kv%%=*} holding a quote, --provider $_p"
  rm -rf "$T/rspy-$_p"; mkdir -p "$T/rspy-$_p"
  rc=0; drive "rej-$_p" "$SPY_BIN:$BASE_PATH" SPY_DIR="$T/rspy-$_p" "$_kv" ZUVO_CODEX_APP_BIN=/nonexistent \
    CLAUDECODE=1 CLAUDE_MODEL=opus -- --mode code --provider "$_p" || rc=$?
  expect_eq "$L: no review (exit 2)" "2" "$rc"
  if [ -z "$(ls -A "$T/rspy-$_p" 2>/dev/null)" ]; then ok "$L: premise — no client was started (the runner refused first)"
  else bad "$L: premise — a client ran [$(ls -A "$T/rspy-$_p" | tr '\n' ' ')]; the case needs a pre-flight refusal"; fi
  _ev="$(ls -d "$T/home-rej-$_p/.zuvo/adversarial-failures"/*/ 2>/dev/null | head -1)"
  _e="$(cat "$_ev/provider_$_p.stderr" 2>/dev/null)"
  expect_has "$L: the runner's own error is in the lane's stderr evidence" "may not contain quotes" "$_e"
  _w="$(printf '%s\n' "$_e" | awk -v p="WARN: $_p failed (exit " 'index($0, p) > 0' | head -1)"
  expect_has "$L: the failure WARN quotes the runner's reason" "may not contain quotes" "$_w"
done

# ── 3. … and for DETECTION; a set value is final ──────────────────────────────────
echo "-- 3. client seams: detection (--list-providers)"
# list_providers <PATH> [VAR=value ...] — the detected lanes, space-joined. Never runs a client. The
# driver's own exit status goes to $T/list.rc (the pipe below would drop it): --list-providers exits 0
# even when it finds nothing, so a driver that CRASHED during detection prints nothing too, and every
# "lane X is absent" case would pass on it. list_ok asserts that status after each call.
list_providers() {
  local path="$1"; shift
  rm -f "$T/list.rc"
  ( cd "$WORK" || exit
    env -i HOME="$T/home-list" ZUVO_HOME="$T/home-list/.zuvo" TMPDIR="$T/tmp" \
      CODEX_HOME="$FIX_CH" PATH="$path" "$@" bash "$AR" --list-providers < /dev/null 2> "$T/list.err"
    echo "$?" > "$T/list.rc" ) \
    | tr '\n' ' ' | sed 's/ $//'
}
# list_ok <label> — the last list_providers call's driver exited 0 (its stderr quoted when not).
list_ok() {
  local rc; rc="$(cat "$T/list.rc" 2>/dev/null || echo "<none>")"
  if [ "$rc" = 0 ]; then ok "$1: --list-providers exited 0"
  else bad "$1: --list-providers exited [$rc] — $(cut300 "$(tr '\n' ' ' < "$T/list.err" 2>/dev/null)")"; fi
}
# has_lane <name> <space-joined list> — <name> is one of the lanes, compared WHOLE: a substring check
# lets `claude` match any lane that merely contains the word.
has_lane() { printf '%s\n' "$2" | tr ' ' '\n' | awk -v n="$1" '$0 == n { f = 1 } END { exit !f }'; }
expect_lane()    { if has_lane "$2" "$3"; then ok "$1"; else bad "$1 — lane [$2] not among [$3]"; fi; }
expect_no_lane() { if has_lane "$2" "$3"; then bad "$1 — lane [$2] among [$3]"; else ok "$1"; fi; }
expect_no_lane "3 matcher: [claude] is not a lane of [claude-lite codex-5.3x]" claude "claude-lite codex-5.3x"
expect_no_lane "3 matcher: [codex-5.3] is not a lane of [codex-5.3x]" codex-5.3 "codex-5.3x"
expect_lane "3 matcher: [claude] is a lane of [codex-5.3 claude]" claude "codex-5.3 claude"
mkdir -p "$T/home-list"; rm -f "$T"/decoy.*
if [ -x /Applications/Codex.app/Contents/Resources/codex ]; then
  echo "  note: /Applications/Codex.app is installed here — case 3a exercises finality against it"
else
  echo "  note: no /Applications/Codex.app here — 3a cannot fail on this machine; 3b/3c prove finality"
fi
# Every absence below is paired with the driver's exit status, and 3b/3g with the OTHER lane, which the
# same PATH does offer: a detection that died, or that dropped every lane, cannot pass as "finality".
out="$(list_providers "$BASE_PATH" ZUVO_CODEX_BIN=/nonexistent)"
list_ok "3a"
expect_no_lane "3a ZUVO_CODEX_BIN=/nonexistent, no codex on PATH, default app path → codex-5.3 not offered" "codex-5.3" "$out"
out="$(list_providers "$DECOY_BIN:$BASE_PATH" ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent)"
list_ok "3b"
expect_no_lane "3b ZUVO_CODEX_BIN=/nonexistent is final: a codex ON PATH does not bring codex-5.3 back" "codex-5.3" "$out"
expect_lane "3b …while the claude on the same PATH is still offered" "claude" "$out"
out="$(list_providers "$BASE_PATH" ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN="$T/app/codex")"
list_ok "3c"
expect_no_lane "3c ZUVO_CODEX_BIN=/nonexistent is final: an executable app bundle does not bring codex-5.3 back" "codex-5.3" "$out"
out="$(list_providers "$BASE_PATH" ZUVO_CODEX_BIN="$OFF_BIN/codex" ZUVO_CODEX_APP_BIN=/nonexistent)"
list_ok "3d"
expect_lane "3d ZUVO_CODEX_BIN names a codex off PATH → codex-5.3 offered" "codex-5.3" "$out"
out="$(list_providers "$BASE_PATH" ZUVO_CODEX_APP_BIN="$T/app/codex")"
list_ok "3e"
expect_lane "3e app-bundle fallback kept: no seam, no codex on PATH, ZUVO_CODEX_APP_BIN executable → codex-5.3" "codex-5.3" "$out"
out="$(list_providers "$BASE_PATH" ZUVO_CLAUDE_BIN="$OFF_BIN/claude" ZUVO_CODEX_APP_BIN=/nonexistent)"
list_ok "3f"
expect_lane "3f ZUVO_CLAUDE_BIN names a claude off PATH → claude offered" "claude" "$out"
out="$(list_providers "$DECOY_BIN:$BASE_PATH" ZUVO_CLAUDE_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent)"
list_ok "3g"
expect_no_lane "3g ZUVO_CLAUDE_BIN=/nonexistent is final: a claude ON PATH does not bring claude back" "claude" "$out"
expect_lane "3g …while the codex on the same PATH is still offered" "codex-5.3" "$out"
out="$(list_providers "$DECOY_BIN:$BASE_PATH" ZUVO_CODEX_APP_BIN=/nonexistent)"
list_ok "3h"
expect_eq "3h no seams: codex and claude on PATH are both offered (positive anchor)" "codex-5.3 claude" "$out"
if ls "$T"/decoy.* >/dev/null 2>&1; then bad "3 detection EXECUTED a client: $(ls "$T" | awk '/^decoy\./' | tr '\n' ' ')"
else ok "3 detection never executed a client (decided by PATH lookup / -x only)"; fi

# ── 4. the provider-health ledger follows ZUVO_HOME ─────────────────────────────
echo "-- 4. ledger path"
rm -rf "$T/lspy" "$T/zh"; mkdir -p "$T/lspy"
# drive's HOME gets a .zuvo dir, so a driver that still wrote $HOME/.zuvo/provider-health.tsv would.
mkdir -p "$T/home-ledger/.zuvo"
( cd "$WORK" && printf '%s' "$DIFF" | env -i HOME="$T/home-ledger" ZUVO_HOME="$T/zh" TMPDIR="$T/tmp" \
    CODEX_HOME="$FIX_CH" ZUVO_NO_CAFFEINATE=1 PATH="$SPY_BIN:$BASE_PATH" SPY_DIR="$T/lspy" \
    ZUVO_CODEX_APP_BIN=/nonexistent CLAUDECODE=1 CLAUDE_MODEL=opus \
    bash "$AR" --mode code --provider claude ) > "$T/ledger.out" 2> "$T/ledger.err"; rc=$?
expect_eq "4 a claude run with ZUVO_HOME=\$T/zh (not created beforehand) exits 0" "0" "$rc"
if [ -s "$T/lspy/claude.rec" ]; then ok "4 the claude spy ran (.rec present)"; else bad "4 the claude spy never ran"; fi
if [ -f "$T/zh/provider-health.tsv" ]; then
  expect_has "4 the ledger is \$ZUVO_HOME/provider-health.tsv and holds the claude row" "claude	" "$(cat "$T/zh/provider-health.tsv")"
else bad "4 no ledger at \$ZUVO_HOME/provider-health.tsv"; fi
if [ -e "$T/home-ledger/.zuvo/provider-health.tsv" ]; then bad "4 the ledger was ALSO written to \$HOME/.zuvo — the real one, outside a test"
else ok "4 \$HOME/.zuvo/provider-health.tsv was not created"; fi
# A ledger whose directory does not exist yet (a fresh ZUVO_HOME above is created by the run log
# before the ledger is written; an explicit ZUVO_PROVIDER_HEALTH_FILE's directory is not): the
# driver creates the directory, or benching never persists — the write fails silently every run.
rm -rf "$T/lspy2" "$T/fresh-ledger"; mkdir -p "$T/lspy2"
rc=0; drive ledger-new "$SPY_BIN:$BASE_PATH" SPY_DIR="$T/lspy2" ZUVO_CODEX_APP_BIN=/nonexistent \
  ZUVO_PROVIDER_HEALTH_FILE="$T/fresh-ledger/sub/health.tsv" CLAUDECODE=1 CLAUDE_MODEL=opus \
  -- --mode code --provider claude || rc=$?
expect_eq "4b a claude run whose ZUVO_PROVIDER_HEALTH_FILE directory does not exist yet exits 0" "0" "$rc"
if [ -f "$T/fresh-ledger/sub/health.tsv" ]; then
  expect_has "4b the ledger was created with its directory and holds the claude row" "claude	" "$(cat "$T/fresh-ledger/sub/health.tsv")"
else bad "4b no ledger at \$ZUVO_PROVIDER_HEALTH_FILE — its directory was never created"; fi

# ── 5. the library missing: one warning, loud codex/claude failures, other lanes unaffected ──
echo "-- 5. library missing"
ALONE="$T/alone"; mkdir -p "$ALONE"; cp "$AR" "$ALONE/adversarial-review.sh"; chmod +x "$ALONE/adversarial-review.sh"
rm -f "$T"/decoy.*
# harness_run <tag> <driver> <providers> [driver args...] — <driver> with the test harness dispatching
# <providers>; decoy clients on PATH. ALONE_ENV (an array, empty unless a case sets it) adds VAR=value
# pairs to the driver's environment.
# alone_run <tag> <providers> [driver args...] — the same with the driver copied ALONE (no lib/
# sibling, no ~/.zuvo/model-subprocess.sh).
ALONE_ENV=()
harness_run() {
  local tag="$1" drv="$2" provs="$3" h="$T/home-$1" rc=0; shift 3
  rm -rf "$h"; mkdir -p "$h/.zuvo"
  ( cd "$WORK" && printf '%s' "$DIFF" | env -i HOME="$h" ZUVO_HOME="$h/.zuvo" TMPDIR="$T/tmp" \
      CODEX_HOME="$FIX_CH" ZUVO_NO_CAFFEINATE=1 PATH="$MOCK_BIN:$DECOY_BIN:$BASE_PATH" \
      ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="$provs" \
      CLAUDECODE=1 CLAUDE_MODEL=opus ${ALONE_ENV[@]+"${ALONE_ENV[@]}"} \
      bash "$drv" --mode code "$@" ) \
    > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  return "$rc"
}
alone_run() { local tag="$1"; shift; harness_run "$tag" "$ALONE/adversarial-review.sh" "$@"; }
# The run's auth-failure cache: <TMPDIR>/zuvo-adv-<uid>/failed-providers.<ZUVO_RUN_ID>.
FAILC="$T/tmp/zuvo-adv-$(id -u)/failed-providers"
# The premise of the fail-closed cases below: one answer is a review past the 600-byte stub guard,
# the other is a short stub.
n="$("$MOCK_BIN/mock-ok" < /dev/null | wc -c | tr -d ' ')"
if [ "$n" -gt 600 ]; then ok "5 premise: mock-ok answers a review longer than 600 B ($n B)"
else bad "5 premise: mock-ok's review is only $n B — the fail-closed cases below would prove nothing"; fi
n="$("$MOCK_BIN/mock-login" < /dev/null | wc -c | tr -d ' ')"
if [ "$n" -le 600 ]; then ok "5 premise: mock-login answers a short stub ($n B)"
else bad "5 premise: mock-login's stub is $n B — not short"; fi
ALONE_ENV=(ZUVO_RUN_ID=golden-5-mixed ZUVO_PROVIDER_HEALTH_FILE="$T/health-5-mixed.tsv")
rc=0; alone_run alone-mixed "codex-5.3 mock-ok mock-login" --json || rc=$?
ALONE_ENV=()
expect_eq "5 codex-5.3 + two mock lanes without the library: the run still succeeds (exit 0)" "0" "$rc"
n="$(awk '/model-subprocess\.sh/ {c++} END {print c+0}' "$T/alone-mixed.err")"
expect_eq "5 exactly ONE stderr line names model-subprocess.sh (the startup warning)" "1" "$n"
expect_has "5 …and it says short outputs are excluded as unverified" "excluded as unverified" \
  "$(awk '/model-subprocess\.sh/' "$T/alone-mixed.err")"
expect_has "5 …and that codex host detection is off in this state" "codex host detection is off" \
  "$(awk '/model-subprocess\.sh/' "$T/alone-mixed.err")"
expect_has "5 the mock lane's review is in the output" "MOCK-OK review" "$(cat "$T/alone-mixed.out")"
_oc="$(jq -r '.provider_outcomes // empty' "$T/alone-mixed.out" 2>/dev/null)"
expect_has "5 the mock lane with a review longer than 600 B is ok" "mock-ok:ok" "$_oc"
expect_has "5 the codex lane is recorded as failed, not silently dropped" "codex-5.3:" "$_oc"
expect_not "5 …and not as ok" "codex-5.3:ok" "$_oc"
# Fail CLOSED, but claim no verdict it cannot make: without the runner's token list the driver cannot
# tell a login stub from a short review, so a short answer from ANY lane is excluded — as `unverified`,
# not `auth`. Neither cached for the run nor benched in the PERSISTENT ledger: a broken install must
# not bench a healthy lane on the long auth cooldown, long after the install is fixed.
expect_has "5 a short stub from another lane is excluded as unverified" "mock-login:unverified" "$_oc"
expect_not "5 …not recorded as an auth failure" "mock-login:auth" "$_oc"
expect_not "5 …not as ok" "mock-login:ok" "$_oc"
expect_not "5 …and the stub is not in the review output" "Please run login" "$(cat "$T/alone-mixed.out")"
_w="$(awk 'index($0, "mock-login") && /WARN/' "$T/alone-mixed.err")"
expect_has "5 …its WARN says the shared runner is missing" "shared runner is missing" "$_w"
expect_not "5 …and does not call the lane unauthenticated" "not authenticated" "$_w"
expect_not "5 …it is not in the run's auth-failure cache" "mock-login" "$(cat "$FAILC.golden-5-mixed" 2>/dev/null)"
_hl="$(cat "$T/health-5-mixed.tsv" 2>/dev/null)"
expect_has "5 anchor: the ledger at ZUVO_PROVIDER_HEALTH_FILE holds the ok lane's row" "mock-ok	" "$_hl"
expect_eq "5 …and NO row for the unverified lane (no auth row, no failure counted)" "" \
  "$(printf '%s\n' "$_hl" | awk -F'\t' '$1 == "mock-login"')"
# With the library loaded nothing changes: a stub the token list catches is `auth`, cached for the run
# and benched in the ledger — which also anchors the cache and ledger paths the checks above read.
ALONE_ENV=(ZUVO_RUN_ID=golden-5-lib ZUVO_PROVIDER_HEALTH_FILE="$T/health-5-lib.tsv")
rc=0; harness_run lib-mixed "$AR" "mock-ok mock-authstub" --json || rc=$?
ALONE_ENV=()
expect_eq "5 library loaded, a review + a login stub: exit 0" "0" "$rc"
expect_eq "5 library loaded: no missing-library warning" "0" "$(awk '/model-subprocess\.sh/ {c++} END {print c+0}' "$T/lib-mixed.err")"
_oc="$(jq -r '.provider_outcomes // empty' "$T/lib-mixed.out" 2>/dev/null)"
expect_has "5 library loaded: the login stub is an auth failure, as before" "mock-authstub:auth" "$_oc"
expect_has "5 library loaded: …the review still counts" "mock-ok:ok" "$_oc"
expect_has "5 library loaded: …its WARN says the lane is not authenticated" "WARN: mock-authstub not authenticated" "$(cat "$T/lib-mixed.err")"
expect_has "5 library loaded: …it is in the run's auth-failure cache" "mock-authstub" "$(cat "$FAILC.golden-5-lib" 2>/dev/null)"
expect_eq "5 library loaded: …and benched in the ledger as auth (1 failure)" "1 auth" \
  "$(awk -F'\t' '$1 == "mock-authstub" {print $3, $5}' "$T/health-5-lib.tsv" 2>/dev/null)"
rc=0; alone_run alone-both "codex-5.3 claude" || rc=$?
expect_eq "5 codex-5.3 + claude alone without the library: no review (exit 2)" "2" "$rc"
ev="$(ls -d "$T/home-alone-both/.zuvo/adversarial-failures"/*/ 2>/dev/null | head -1)"
for _pair in codex-5.3:codex claude:claude; do
  _p="${_pair%%:*}"
  _e="$(cat "$ev/provider_$_p.stderr" 2>/dev/null)"
  expect_has "5 the $_p lane fails with a named error" "$_p" "$_e"
  expect_has "5 the $_p lane's error names the missing model-subprocess.sh" "model-subprocess.sh" "$_e"
done
if ls "$T"/decoy.* >/dev/null 2>&1; then bad "5 without the library a client was still EXECUTED: $(ls "$T" | awk '/^decoy\./' | tr '\n' ' ')"
else ok "5 without the library no codex/claude client was executed"; fi
# A lane that could not RUN for want of the runner is `no-runner` — never `empty`: an `empty` lands in
# the PERSISTENT provider-health ledger as a lane failure and benches a healthy lane long after the
# install is fixed. Not in the ledger, not in the run's fail cache; checked before a model is chosen, so
# run_claude prints no "assuming Opus author" NOTE (CLAUDE_MODEL is cleared here: the NOTE's trigger).
ALONE_ENV=(ZUVO_RUN_ID=golden-5-norunner ZUVO_PROVIDER_HEALTH_FILE="$T/health-5-norunner.tsv" CLAUDE_MODEL=)
rc=0; alone_run alone-norunner "codex-5.3 claude" --json || rc=$?
ALONE_ENV=()
expect_eq "5 no-runner: codex-5.3 + claude without the library, --json: no review (exit 2)" "2" "$rc"
_oc="$(jq -r '.provider_outcomes // empty' "$T/alone-norunner.out" 2>/dev/null)"
expect_has "5 no-runner: the codex lane's outcome is no-runner" "codex-5.3:no-runner" "$_oc"
expect_has "5 no-runner: the claude lane's outcome is no-runner" "claude:no-runner" "$_oc"
expect_not "5 no-runner: …neither is recorded as empty" ":empty" "$_oc"
expect_eq "5 no-runner: the ledger holds NO row for codex-5.3 or claude" "" \
  "$(awk -F'\t' '$1 == "codex-5.3" || $1 == "claude"' "$T/health-5-norunner.tsv" 2>/dev/null)"
_fc="$(cat "$FAILC.golden-5-norunner" 2>/dev/null)"
expect_not "5 no-runner: codex-5.3 is not in the run's fail cache" "codex-5.3" "$_fc"
expect_not "5 no-runner: claude is not in the run's fail cache" "claude" "$_fc"
ev="$(ls -d "$T/home-alone-norunner/.zuvo/adversarial-failures"/*/ 2>/dev/null | head -1)"
_e="$(cat "$ev/provider_claude.stderr" 2>/dev/null)"
expect_has "5 no-runner: the claude lane's stderr holds the named runner error" "claude cannot run" "$_e"
expect_not "5 no-runner: …and NO 'assuming Opus author' NOTE — the runner is checked before the model is chosen" "NOTE:" "$_e"
expect_has "5 no-runner: the run's error says no lane could run, and why" "no lane could run — the shared runner model-subprocess.sh was not loaded" \
  "$(cat "$T/alone-norunner.err")"
# Anchor: the SAME ledger path does get rows — a lane that answers is recorded — so the absence above
# is the no-runner rule, not a ledger that was never written.
ALONE_ENV=(ZUVO_RUN_ID=golden-5-norunner-mixed ZUVO_PROVIDER_HEALTH_FILE="$T/health-5-norunner-mixed.tsv")
rc=0; alone_run alone-norunner-mixed "codex-5.3 mock-ok" --json || rc=$?
ALONE_ENV=()
expect_eq "5 no-runner anchor: codex-5.3 + mock-ok without the library: exit 0" "0" "$rc"
expect_has "5 no-runner anchor: codex-5.3 is no-runner beside a lane that answered" "codex-5.3:no-runner" \
  "$(jq -r '.provider_outcomes // empty' "$T/alone-norunner-mixed.out" 2>/dev/null)"
_hl="$(cat "$T/health-5-norunner-mixed.tsv" 2>/dev/null)"
expect_has "5 no-runner anchor: the ledger holds the answering lane's row" "mock-ok	" "$_hl"
expect_eq "5 no-runner anchor: …and still none for codex-5.3" "" "$(printf '%s\n' "$_hl" | awk -F'\t' '$1 == "codex-5.3"')"

# ── 5b. where the library is found: next to the driver (flat ~/.zuvo install), else ~/.zuvo/ ──
echo "-- 5b. library lookup"
# lookup_run <tag> <driver> <home> — a codex-5.3 run whose client is the off-PATH spy named by
# ZUVO_CODEX_BIN, a decoy codex on PATH: only a driver that LOADED the library reaches the spy.
lookup_run() {
  local rc=0
  rm -rf "$T/kspy-$1"; mkdir -p "$T/kspy-$1"
  ( cd "$WORK" && printf '%s' "$DIFF" | env -i HOME="$3" ZUVO_HOME="$3/.zuvo" TMPDIR="$T/tmp" \
      CODEX_HOME="$FIX_CH" ZUVO_NO_CAFFEINATE=1 PATH="$DECOY_BIN:$BASE_PATH" SPY_DIR="$T/kspy-$1" \
      ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_CODEX_BIN="$OFF_BIN/codex" CLAUDECODE=1 CLAUDE_MODEL=opus \
      bash "$2" --mode code --provider codex-5.3 ) > "$T/$1.out" 2> "$T/$1.err" || rc=$?
  return "$rc"
}
lookup_case() { # lookup_case <label> <tag> <driver> <home>
  local rc=0
  rm -f "$T"/decoy.*
  lookup_run "$2" "$3" "$4" || rc=$?
  expect_eq "$1: exit 0" "0" "$rc"
  expect_eq "$1: no missing-library warning" "0" "$(awk '/model-subprocess\.sh/ {c++} END {print c+0}' "$T/$2.err")"
  if [ -s "$T/kspy-$2/codex.rec" ] && [ ! -e "$T/decoy.codex" ]; then ok "$1: the library was loaded (the ZUVO_CODEX_BIN spy ran, the PATH codex did not)"
  else bad "$1: the library was not loaded (spy ran: $([ -s "$T/kspy-$2/codex.rec" ] && echo yes || echo no), PATH codex ran: $([ -e "$T/decoy.codex" ] && echo yes || echo no))"; fi
}
LIBSRC="$(cd "$(dirname "$AR")" && pwd -P)/lib/model-subprocess.sh"
[ -f "$LIBSRC" ] || LIBSRC="$ROOT/scripts/lib/model-subprocess.sh"
FLAT="$T/flat-home/.zuvo"; mkdir -p "$FLAT"
cp "$AR" "$FLAT/adversarial-review"; cp "$LIBSRC" "$FLAT/model-subprocess.sh"
lookup_case "5b flat install (~/.zuvo/adversarial-review + ~/.zuvo/model-subprocess.sh)" flat "$FLAT/adversarial-review" "$T/flat-home"
mkdir -p "$T/fallback-home/.zuvo"; cp "$LIBSRC" "$T/fallback-home/.zuvo/model-subprocess.sh"
lookup_case "5b driver alone elsewhere, library only in ~/.zuvo → loaded from there" fallback "$ALONE/adversarial-review.sh" "$T/fallback-home"
# Sibling first: a repo checkout must not source whatever an older install left in ~/.zuvo.
mkdir -p "$T/planted-home/.zuvo"
printf ': > "%s/planted-lib-sourced"\n' "$T" > "$T/planted-home/.zuvo/model-subprocess.sh"
lookup_case "5b the repo driver with a stale ~/.zuvo/model-subprocess.sh present" planted "$AR" "$T/planted-home"
if [ -e "$T/planted-lib-sourced" ]; then bad "5b the repo driver SOURCED ~/.zuvo/model-subprocess.sh instead of its sibling lib/"
else ok "5b the repo driver used its sibling lib/, not ~/.zuvo/model-subprocess.sh"; fi
# A sibling that EXISTS but fails to source: the lookup moves on to ~/.zuvo — the very stale copy
# sibling-first exists to avoid — so it must say so, naming the broken file.
BROKEN="$T/broken-sib"; mkdir -p "$BROKEN/lib" "$T/broken-home/.zuvo"
cp "$AR" "$BROKEN/adversarial-review.sh"
printf 'return 1\n' > "$BROKEN/lib/model-subprocess.sh"
cp "$LIBSRC" "$T/broken-home/.zuvo/model-subprocess.sh"
rm -f "$T"/decoy.*
rc=0; lookup_run broken "$BROKEN/adversarial-review.sh" "$T/broken-home" || rc=$?
expect_eq "5b a sibling lib/ that fails to source, a good ~/.zuvo copy: exit 0" "0" "$rc"
if [ -s "$T/kspy-broken/codex.rec" ] && [ ! -e "$T/decoy.codex" ]; then ok "5b …the ~/.zuvo copy was loaded (the ZUVO_CODEX_BIN spy ran)"
else bad "5b …no library was loaded after the broken sibling"; fi
_w="$(awk -v f="$BROKEN/lib/model-subprocess.sh" 'index($0, f)' "$T/broken.err")"
expect_eq "5b …ONE stderr line names the broken sibling" "1" "$(printf '%s' "$_w" | awk 'END {print NR}')"
expect_has "5b …and it is a WARN" "WARN" "$_w"
# A sibling that SOURCES cleanly but lacks a function the driver calls — an older or truncated copy —
# is no runner either: accepted, its first missing call is a "command not found" in the middle of a
# review. Rejected by name like one that fails to source, and the complete ~/.zuvo copy is loaded (the
# check the router and the preflight already made, each for its own function list).
PARTIAL="$T/partial-sib"; mkdir -p "$PARTIAL/lib" "$T/partial-home/.zuvo"
cp "$AR" "$PARTIAL/adversarial-review.sh"
{ cat "$LIBSRC"; printf '\nunset -f zms_run_codex\n'; } > "$PARTIAL/lib/model-subprocess.sh"
cp "$LIBSRC" "$T/partial-home/.zuvo/model-subprocess.sh"
rm -f "$T"/decoy.*
rc=0; lookup_run partial "$PARTIAL/adversarial-review.sh" "$T/partial-home" || rc=$?
expect_eq "5b a sibling lib/ that sources but lacks zms_run_codex, a complete ~/.zuvo copy: exit 0" "0" "$rc"
if [ -s "$T/kspy-partial/codex.rec" ] && [ ! -e "$T/decoy.codex" ]; then ok "5b …the complete ~/.zuvo copy was loaded (the ZUVO_CODEX_BIN spy ran)"
else bad "5b …the incomplete sibling was accepted (spy ran: $([ -s "$T/kspy-partial/codex.rec" ] && echo yes || echo no)) — $(tail -2 "$T/partial.err" | tr '\n' ' ')"; fi
_w="$(awk -v f="$PARTIAL/lib/model-subprocess.sh" 'index($0, f)' "$T/partial.err")"
expect_eq "5b …ONE stderr line names the incomplete sibling" "1" "$(printf '%s' "$_w" | awk 'END {print NR}')"
expect_has "5b …a WARN listing the functions a candidate must define (zms_run_codex among them)" "zms_run_codex" "$_w"
expect_not "5b …and no call hit a missing function" "command not found" "$(cat "$T/partial.err")"
# …and when NO candidate loads, nothing the rejected one defined stays callable. The list is unset
# before each candidate, which cleans up after every candidate but the LAST. This one is the only
# candidate: it defines three of the listed functions (so it is rejected) and a PROBE — an `id` function
# the driver's own startup calls after the lookup (`$(id -u)`, its cache dir) — that records which of
# the three still exist at that moment, then runs the real id.
REJ="$T/rejected-sib"; mkdir -p "$REJ/lib" "$T/rejected-home"
cp "$AR" "$REJ/adversarial-review.sh"
cat > "$REJ/lib/model-subprocess.sh" <<EOF
zms_client_available() { return 1; }
zms_is_codex_host() { return 1; }
zms_is_auth_stub() { return 1; }
id() { _l=""; for _f in zms_client_available zms_is_codex_host zms_is_auth_stub; do declare -F "\$_f" >/dev/null && _l="\$_l \$_f"; done; printf 'id-called:%s\n' "\$_l" >> "$T/rejected-probe"; command id "\$@"; }
EOF
rm -f "$T/rejected-probe"
rc=0; ( cd "$WORK" && env -i HOME="$T/rejected-home" ZUVO_HOME="$T/rejected-home/.zuvo" TMPDIR="$T/tmp" \
    CODEX_HOME="$FIX_CH" PATH="$BASE_PATH" bash "$REJ/adversarial-review.sh" --list-providers < /dev/null ) \
  > "$T/rejected.out" 2> "$T/rejected.err" || rc=$?
expect_eq "5b a lone candidate that defines only some zms_* functions: --list-providers exits 0" "0" "$rc"
expect_has "5b …it is rejected by name" "$REJ/lib/model-subprocess.sh exists but did not load" "$(cat "$T/rejected.err")"
expect_has "5b …and no runner is loaded (the missing-library warning)" "model-subprocess.sh (the shared codex/claude runner) not loaded" "$(cat "$T/rejected.err")"
if [ -s "$T/rejected-probe" ]; then ok "5b premise: the probe ran after the lookup ($(awk 'END {print NR}' "$T/rejected-probe") id call(s))"
else bad "5b premise: the probe never ran — the case says nothing about what stayed defined"; fi
expect_eq "5b …none of the rejected candidate's zms_* functions is still defined after startup" "" \
  "$(awk -F: '$2 != "" {print $2}' "$T/rejected-probe" 2>/dev/null | sort -u | tr '\n' ' ')"

# ── 5c. the fail-closed fallback judges OUTPUT, in bytes; the failure WARN quotes a real line ──
echo "-- 5c. degraded auth verdicts, the failure WARN"
# fd_mock <name> <command> <answer> — a mock lane that prints <answer>, then finds the file its stdout
# was opened on (the driver's result_<name>.txt: /proc on Linux, lsof elsewhere), runs <command> on
# it and exits 0. $T/fd.<name> exists only when it found that file and <command> succeeded — the premise;
# it holds that file's path.
fd_mock() {
  cat > "$MOCK_BIN/$1" <<EOF
#!/bin/sh
cat > /dev/null
printf '%s' '$3'
f="\$(readlink "/proc/\$\$/fd/1" 2>/dev/null)"
[ -n "\$f" ] || f="\$(/usr/sbin/lsof -a -p \$\$ -d 1 -Fn 2>/dev/null | sed -n 's/^n//p')"
case "\$f" in */result_$1.txt) $2 "\$f" && printf '%s\n' "\$f" > "$T/fd.$1" ;; esac
exit 0
EOF
  chmod +x "$MOCK_BIN/$1"
}
fd_mock mock-nofile "rm -f" ""
fd_mock mock-unread "chmod 000" "Please run login"
fd_mock mock-pinned "chflags uchg" "Please run login"
# (1) A lane that exits 0 and leaves NO result file: the fallback used to measure the PATH (< 600 chars)
# and bench the lane as `auth`. A missing file is no output — `empty`, never cached as unauthenticated.
rm -f "$T"/fd.mock-*
ALONE_ENV=(ZUVO_RUN_ID=golden-5c-nofile)
rc=0; alone_run alone-nofile "mock-ok mock-login mock-nofile" --json || rc=$?
ALONE_ENV=()
if [ -e "$T/fd.mock-nofile" ]; then ok "5c premise: mock-nofile removed its own result file"
else bad "5c premise: mock-nofile could not find/remove its result file (no /proc, no lsof?) — case (1) proves nothing"; fi
expect_eq "5c (1) a lane without a result file, beside a real review: exit 0" "0" "$rc"
_oc="$(jq -r '.provider_outcomes // empty' "$T/alone-nofile.out" 2>/dev/null)"
expect_has "5c (1) the lane without a result file is recorded as empty" "mock-nofile:empty" "$_oc"
expect_not "5c (1) …not as auth" "mock-nofile:auth" "$_oc"
expect_not "5c (1) …nor as unverified" "mock-nofile:unverified" "$_oc"
expect_has "5c (1) anchor: the short stub from mock-login IS judged (unverified)" "mock-login:unverified" "$_oc"
# The cache path itself is anchored by section 5's library-loaded run.
expect_not "5c (1) the lane without a result file is NOT in the auth-failure cache" "mock-nofile" "$(cat "$FAILC.golden-5c-nofile" 2>/dev/null)"
# (2) An existing result file whose size cannot be read: fail CLOSED (auth), and the run survives it.
if [ "$(id -u)" = 0 ]; then
  echo "  note: running as root — mode 000 does not stop root reading; case (2) skipped"
else
  rm -f "$T"/fd.mock-*
  ALONE_ENV=(ZUVO_RUN_ID=golden-5c-unread)
  rc=0; alone_run alone-unread "mock-ok mock-unread" --json || rc=$?
  ALONE_ENV=()
  if [ -e "$T/fd.mock-unread" ]; then ok "5c premise: mock-unread made its own result file mode 000"
  else bad "5c premise: mock-unread could not find/chmod its result file (no /proc, no lsof?) — case (2) proves nothing"; fi
  expect_eq "5c (2) an unreadable short result, beside a real review: exit 0" "0" "$rc"
  _oc="$(jq -r '.provider_outcomes // empty' "$T/alone-unread.out" 2>/dev/null)"
  expect_has "5c (2) the unreadable result is excluded (fail closed), as unverified" "mock-unread:unverified" "$_oc"
  expect_has "5c (2) …and the real review still counts" "mock-ok:ok" "$_oc"
  printf 'Please run login' > "$T/unread.txt"; chmod 000 "$T/unread.txt"
  rc=0; ( fn_body "$AR" is_auth_failure_output > "$T/iafo.sh" && . "$T/iafo.sh" \
    && ZMS_LOADED="" is_auth_failure_output "$T/unread.txt" ) 2> "$T/iafo-unread.err" || rc=$?
  chmod 600 "$T/unread.txt"
  expect_eq "5c (2) called directly: an unreadable file is an auth failure (returns 0)" "0" "$rc"
  expect_eq "5c (2) …and says nothing on stderr" "" "$(cat "$T/iafo-unread.err")"
fi
# (3) The 600 guard is BYTES for a string too: 250 three-byte characters are 750 B, not a stub.
U8=""
for _l in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
  if [ "$(LC_ALL="$_l" bash -c 's="$(printf "\342\202\254")"; printf %s "${#s}"' 2>/dev/null)" = 1 ]; then U8="$_l"; break; fi
done
if [ -z "$U8" ]; then bad "5c (3) no UTF-8 locale here — the byte-vs-character case cannot run"
else
  _mb="$(printf '\342\202\254')"; _s250=""; _s200=""
  for _i in $(seq 250); do _s250="$_s250$_mb"; done
  for _i in $(seq 200); do _s200="$_s200$_mb"; done
  fn_body "$AR" is_auth_failure_output > "$T/iafo.sh"
  # verdict <string> — "<chars> <verdict: 0 auth / 1 not> <chars after the call>" in a UTF-8 locale.
  verdict() {
    ( LC_ALL="$U8"; . "$T/iafo.sh"; n="${#1}"; v=0
      ZMS_LOADED="" is_auth_failure_output "$1" || v=$?; printf '%s %s %s' "$n" "$v" "${#1}" )
  }
  expect_eq "5c (3) premise: under $U8 the 750-byte string is 250 characters" "250" "$(verdict "$_s250" | awk '{print $1}')"
  expect_eq "5c (3) 250 x U+20AC (750 B) is NOT an auth stub (> 600 bytes)" "1" "$(verdict "$_s250" | awk '{print $2}')"
  expect_eq "5c (3) …and the caller's locale is untouched after the call" "250" "$(verdict "$_s250" | awk '{print $3}')"
  expect_eq "5c (3) anchor: 200 x U+20AC (600 B) is within the guard (auth)" "0" "$(verdict "$_s200" | awk '{print $2}')"
  expect_eq "5c (3) anchor: a short ASCII stub is an auth failure" "0" "$(verdict "Please run login" | awk '{print $2}')"
fi
# (4) The failure WARN quotes the client's first NON-empty stderr line, not the blank one before it.
printf '#!/bin/sh\ncat > /dev/null\nprintf "\\n   \\nclaude: first real line\\nsecond line\\n" >&2\nexit 3\n' > "$T/blankerr-claude"
chmod +x "$T/blankerr-claude"
rc=0; drive blankerr "$BASE_PATH" ZUVO_CLAUDE_BIN="$T/blankerr-claude" ZUVO_CODEX_APP_BIN=/nonexistent \
  CLAUDECODE=1 CLAUDE_MODEL=opus -- --mode code --provider claude || rc=$?
expect_eq "5c (4) a claude client that fails (exit 3): no review (exit 2)" "2" "$rc"
_ev="$(ls -d "$T/home-blankerr/.zuvo/adversarial-failures"/*/ 2>/dev/null | head -1)"
_e="$(cat "$_ev/provider_claude.stderr" 2>/dev/null)"
_w="$(printf '%s\n' "$_e" | awk 'index($0, "WARN: claude failed (exit ") > 0' | head -1)"
expect_eq "5c (4) the WARN quotes the first non-empty stderr line" \
  "  WARN: claude failed (exit 3): claude: first real line" "$_w"
# (5) Exclusion is a per-lane FLAG, not the unlink: a stub whose result file cannot be removed (the
# user-immutable flag; rm fails with EPERM) stays excluded — nowhere in the output, the counts or the
# tally — and the failed rm does not end the run (it used to, under set -e).
if ! command -v chflags >/dev/null 2>&1; then
  echo "  note: no chflags here — case (5) needs a file rm cannot remove; skipped"
else
  rm -f "$T"/fd.mock-*
  ALONE_ENV=(ZUVO_RUN_ID=golden-5c-pinned)
  rc=0; alone_run alone-pinned "mock-ok mock-pinned" --json || rc=$?
  ALONE_ENV=()
  _pf="$(cat "$T/fd.mock-pinned" 2>/dev/null)"
  if [ -n "$_pf" ]; then ok "5c premise: mock-pinned made its own result file immutable"
  else bad "5c premise: mock-pinned could not find/pin its result file (no /proc, no lsof?) — case (5) proves nothing"; fi
  # The driver cannot delete its temp dir around a pinned file (mktemp's default dir may lie outside $T).
  [ -z "$_pf" ] || { chflags nouchg "$_pf" 2>/dev/null; rm -rf "${_pf%/*}"; }
  expect_eq "5c (5) a stub whose result file cannot be removed, beside a real review: exit 0" "0" "$rc"
  _oc="$(jq -r '.provider_outcomes // empty' "$T/alone-pinned.out" 2>/dev/null)"
  expect_has "5c (5) …the stub is excluded (unverified)" "mock-pinned:unverified" "$_oc"
  expect_has "5c (5) …the real review still counts" "mock-ok:ok" "$_oc"
  expect_eq "5c (5) …and is the only one used" "mock-ok" "$(jq -r '.providers_used // empty' "$T/alone-pinned.out" 2>/dev/null)"
  expect_not "5c (5) …the stub is not in the review output" "Please run login" "$(cat "$T/alone-pinned.out")"
fi
# (6) The failure WARN quotes stderr TERMINAL-SAFE: a client's first line holding an ANSI sequence, a
# tab, a BEL and 1000 characters reaches the WARN without any control character and cut to 300
# characters plus "…" — a hostile or runaway client cannot rewrite the operator's terminal.
{ printf '\033[31mclaude: BOOM\033[0m\tdetail\a '; for _i in $(seq 1000); do printf x; done; printf '\n'; } > "$T/noisy.stderr"
printf '#!/bin/sh\ncat > /dev/null\ncat "%s" >&2\nexit 3\n' "$T/noisy.stderr" > "$T/noisy-claude"
chmod +x "$T/noisy-claude"
rc=0; drive noisy "$BASE_PATH" ZUVO_CLAUDE_BIN="$T/noisy-claude" ZUVO_CODEX_APP_BIN=/nonexistent \
  CLAUDECODE=1 CLAUDE_MODEL=opus -- --mode code --provider claude || rc=$?
expect_eq "5c (6) a claude client that fails (exit 3) with a hostile stderr line: no review (exit 2)" "2" "$rc"
_ev="$(ls -d "$T/home-noisy/.zuvo/adversarial-failures"/*/ 2>/dev/null | head -1)"
_w="$(awk 'index($0, "WARN: claude failed (exit ") > 0' "$_ev/provider_claude.stderr" 2>/dev/null | head -1)"
if [ -z "$_w" ]; then bad "5c (6) no 'WARN: claude failed (exit …)' line in the lane's stderr"
else
  expect_eq "5c (6) the WARN carries no control character (ESC, BEL, TAB…)" "0" \
    "$(printf '%s' "$_w" | LC_ALL=C tr -dc '\000-\037\177' | wc -c | tr -d ' ')"
  _s="${_w#*"(exit 3): "}"
  expect_has "5c (6) …the ANSI sequences go whole (no '[31m' residue) and the tab is a space" "claude: BOOM detail x" "$_s"
  case "$_s" in *…) ok "5c (6) …the cut is marked with …" ;; *) bad "5c (6) the snippet is not cut with … — [$(cut300 "$_s")]" ;; esac
  _s="${_s%…}"
  expect_eq "5c (6) …and the snippet is 300 characters" "300" "${#_s}"
fi
# (6b) …and the 300 is BYTES, cut on a character boundary. Case (6) is ASCII, where a byte is a
# character. Here the first stderr line is one ASCII byte and 1000 x U+20AC (3 bytes each): byte 300
# falls INSIDE the 100th euro sign, so a cut that ignored the UTF-8 boundary would end in a broken
# sequence. Measured with LC_ALL=C (bytes, whatever this shell's locale is): at most 300 + the 3 bytes
# of "…"; and the WARN must still be valid UTF-8 (iconv refuses an invalid sequence).
{ printf 'x'; _i=0; while [ "$_i" -lt 1000 ]; do printf '\342\202\254'; _i=$((_i + 1)); done; printf '\n'; } > "$T/wide.stderr"
printf '#!/bin/sh\ncat > /dev/null\ncat "%s" >&2\nexit 3\n' "$T/wide.stderr" > "$T/wide-claude"
chmod +x "$T/wide-claude"
rc=0; drive wide "$BASE_PATH" ZUVO_CLAUDE_BIN="$T/wide-claude" ZUVO_CODEX_APP_BIN=/nonexistent \
  CLAUDECODE=1 CLAUDE_MODEL=opus -- --mode code --provider claude || rc=$?
expect_eq "5c (6b) a claude client that fails (exit 3) with a 3001-byte multi-byte stderr line: no review (exit 2)" "2" "$rc"
_ev="$(ls -d "$T/home-wide/.zuvo/adversarial-failures"/*/ 2>/dev/null | head -1)"
_w="$(awk 'index($0, "WARN: claude failed (exit ") > 0' "$_ev/provider_claude.stderr" 2>/dev/null | head -1)"
if [ -z "$_w" ]; then bad "5c (6b) no 'WARN: claude failed (exit …)' line in the lane's stderr"
else
  _s="${_w#*"(exit 3): "}"
  case "$_s" in x*…) ok "5c (6b) …the snippet is the stderr line, cut and marked with …" ;;
    *) bad "5c (6b) the snippet is not the cut stderr line — [$(cut300 "$_s")]" ;; esac
  _nb="$(printf '%s' "$_s" | LC_ALL=C wc -c | tr -d ' ')"
  if [ "$_nb" -le 303 ] && [ "$_nb" -ge 290 ]; then ok "5c (6b) …it is $_nb bytes: at most 300 + the 3-byte …"
  else bad "5c (6b) the snippet is $_nb bytes — want 300 at most, plus the 3-byte …"; fi
  if printf '%s\n' "$_w" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then ok "5c (6b) …and the WARN is valid UTF-8 (no split character)"
  else bad "5c (6b) the WARN is not valid UTF-8 — the 300-byte cut split a character"; fi
fi

# ── 6. source: the driver delegates, it no longer carries its own copy ───────────
echo "-- 6. source assertions"
# strip_comments — stdin without its comments: full-line ones dropped, a trailing one (a `#` after a
# blank, outside quotes and not escaped) cut off. Every source check below reads this, never the raw
# text: a delegation "present" only in a comment must not pass, and a word in a comment must not fail
# an absence check. `${x#y}` and `$#` stay: their `#` follows no blank.
strip_comments() {
  awk '
    { out = ""; q = ""; prev = " "; n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (q == "\047") { out = out c; if (c == "\047") q = ""; prev = c; continue }
        if (c == "\\") { out = out c substr($0, i + 1, 1); i++; prev = "x"; continue }
        if (q == "\"") { out = out c; if (c == "\"") q = ""; prev = c; continue }
        if (c == "\047" || c == "\"") { q = c; out = out c; prev = c; continue }
        if (c == "#" && (prev == " " || prev == "\t")) break
        out = out c; prev = c
      }
      if (out ~ /^[[:space:]]*$/ && $0 ~ /^[[:space:]]*#/) next
      print out }'
}
# code_lines <file> — the whole file through strip_comments (it used to drop only full-line comments,
# so a trailing `# replaces /Applications/Codex.app` turned an absence check red).
code_lines() { strip_comments < "$1"; }
# fn_code <file> <function> — fn_body through strip_comments.
fn_code() { fn_body "$@" | strip_comments; }
# has_word <ERE> <text> — <ERE> as a whole WORD of <text>: not inside a longer word (`parsed `, `used `
# and `regrep` hold no sed/grep), not glued to an identifier (`sed_i`, `zms_grep`).
has_word() { printf '%s\n' "$2" | awk -v w="$1" '{ if (match(" " $0 " ", "[^[:alnum:]_]" w "[^[:alnum:]_]")) f = 1 } END { exit !f }'; }
expect_no_word() { if has_word "$2" "$3"; then bad "$1 — the word [$2] is in [$(cut300 "$3")]"; else ok "$1"; fi; }
cat > "$T/fn-demo.sh" <<'DEMO'
demo() {
  # zms_only_in_a_comment
  echo "kept # zms_in_quotes" 'and # zms_in_single'   # zms_trailing_comment
  x="${y#pre}"; echo "$#" \# zms_escaped_hash
  zms_codex_bin  # replaces /Applications/Codex.app
  echo "the parsed value is used as-is" 'regrep' sed_i zms_grep
}
DEMO
b="$(fn_code "$T/fn-demo.sh" demo)"
expect_not "6 fn_code: a full-line comment is not code" "zms_only_in_a_comment" "$b"
expect_not "6 fn_code: a trailing ' # …' comment is not code" "zms_trailing_comment" "$b"
expect_has "6 fn_code: a # inside double quotes is kept" "kept # zms_in_quotes" "$b"
expect_has "6 fn_code: a # inside single quotes is kept" "and # zms_in_single" "$b"
expect_has "6 fn_code: \${y#pre} and \$# are kept" 'x="${y#pre}"; echo "$#"' "$b"
expect_has "6 fn_code: an escaped \\# is kept" 'zms_escaped_hash' "$b"
b="$(code_lines "$T/fn-demo.sh")"
expect_not "6 code_lines: a trailing comment is not code (whole-file view too)" "Applications/Codex.app" "$b"
expect_not "6 code_lines: a full-line comment is not code" "zms_only_in_a_comment" "$b"
expect_has "6 code_lines: the code before a trailing comment is kept" "zms_codex_bin" "$b"
expect_no_word "6 has_word: 'parsed ' / 'used ' / sed_i are not the word sed" "g?sed" "$b"
expect_no_word "6 has_word: 'regrep' / zms_grep are not the word grep" "[ef]?grep" "$b"
if has_word "g?sed" 'x="$(sed -n 1p f)"' && has_word "[ef]?grep" 'a | grep -q b' && has_word "[ef]?grep" 'egrep x'; then
  ok "6 has_word: anchor — a real sed / grep / egrep call IS found"
else bad "6 has_word: a real sed / grep / egrep call is not found — every absence check below would pass"; fi
n="$(code_lines "$AR" | awk '/sandbox_mode/ {c++} END {print c+0}')"
expect_eq "6 the driver writes no sandbox_mode (the library builds every CODEX_HOME)" "0" "$n"
n="$(code_lines "$AR" | awk '/>[[:space:]]*"?[^"[:space:]]*config\.toml/ {c++} END {print c+0}')"
expect_eq "6 the driver redirects nothing into a config.toml" "0" "$n"
n="$(code_lines "$AR" | awk '/Applications\/Codex\.app/ {c++} END {print c+0}')"
expect_eq "6 the driver no longer hardcodes the Codex.app path (zms_codex_bin owns the fallback)" "0" "$n"
b="$(fn_code "$AR" codex_cli_guard)"
expect_has "6 codex_cli_guard delegates to zms_codex_cli_guard" "zms_codex_cli_guard" "$b"
expect_not "6 …and no longer runs codex --version itself" "--version" "$b"
b="$(fn_code "$AR" is_auth_failure_output)"
expect_has "6 is_auth_failure_output delegates to zms_is_auth_stub" "zms_is_auth_stub" "$b"
expect_no_word "6 …and carries no grep of its own" "[ef]?grep" "$b"
b="$(fn_code "$AR" detect_host_platform)"
expect_has "6 detect_host_platform's Codex branch uses zms_is_codex_host" "zms_is_codex_host" "$b"
expect_has "6 …and zms_codex_host_model" "zms_codex_host_model" "$b"
expect_no_word "6 …with no config.toml sed of its own" "g?sed" "$b"
expect_has "6 run_codex runs through zms_run_codex" "zms_run_codex" "$(fn_code "$AR" run_codex)"
expect_has "6 run_codex takes its lane access from review_access" "review_access" "$(fn_code "$AR" run_codex)"
expect_has "6 run_claude runs through zms_run_claude" "zms_run_claude" "$(fn_code "$AR" run_claude)"
expect_has "6 run_claude takes its lane access from review_access" "review_access" "$(fn_code "$AR" run_claude)"
# ZUVO_REVIEW_ACCESS (b23cd153) moved the literal into review_access(); the contract is unchanged:
# unset means agent, and agent still means `--access agent`.
b="$(fn_code "$AR" review_access)"
expect_has "6 review_access defaults to agent when ZUVO_REVIEW_ACCESS is unset" '${ZUVO_REVIEW_ACCESS:-agent}' "$b"
expect_has "6 …and agent still maps to --access agent" "agent) access=(--access agent)" "$b"
b="$(fn_code "$AR" detect_providers)"
n="$(printf '%s\n' "$b" | awk '/client_available (codex|claude)/ {c++} END {print c+0}')"
expect_eq "6 detect_providers decides codex and claude through client_available" "2" "$n"
n="$(printf '%s\n' "$b" | awk '/command -v (codex|claude)/ {c++} END {print c+0}')"
expect_eq "6 …not by a PATH lookup of its own" "0" "$n"
expect_has "6 client_available is the runner's zms_client_available" "zms_client_available" "$(fn_code "$AR" client_available)"

echo "=== RESULT ==="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
