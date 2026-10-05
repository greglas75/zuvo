#!/usr/bin/env bash
# --exclude was a SCALAR, and that broke two independent things at once.
#
# 1. Repeated flags overwrote each other. `--exclude agy --exclude kimi` excluded only
#    kimi, so a rotation pass came back to a provider it had already used and burned a
#    full adversarial chunk producing findings the previous pass had produced. Reported
#    from a field run on 2026-08-11 ("pass 2 przypadkiem wrócił na kimi").
#
# 2. Worse, and not what was reported: the host auto-exclusion at ~line 1035 was guarded
#    by `-z "$EXCLUDE_PROVIDER"`, so passing --exclude for ANY unrelated reason turned
#    self-review prevention OFF. On a Cursor host, `--exclude kimi` left `cursor-agent`
#    in the provider list and Cursor audited its own output — silently, with no degraded
#    status anywhere in the report. Host exclusion is a safety property; a user flag
#    about rotation must not displace it.
#
# Both collapse to: a set was being modelled as a scalar. These cases pin the set.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ADV="$ROOT/scripts/adversarial-review.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -x "$ADV" ] || { bad "adversarial-review.sh missing or not executable"; echo "SOME FAILED"; exit 1; }

# Every probe is a dry run (no client is ever called) over the TEST HARNESS's lanes, in a sandboxed HOME
# with every host signal cleared: the suite used to probe whatever CLIs this machine had installed, so on
# a host with fewer than two — the farm, CI — each runtime case "passed" as skipped while the suite
# printed ALL PASS, and a probe that failed outright read as "no providers here". The input is a real
# diff: the driver refuses a payload with no diff hunk (exit 5), which printed no Providers line at all.
XS_DIFF='diff --git a/x.js b/x.js
--- a/x.js
+++ b/x.js
@@ -1 +1 @@
-const x = 1;
+const x = 2;
'
XS_T="$(mktemp -d)" || { bad "mktemp -d failed"; echo "SOME FAILED"; exit 1; }
trap 'rm -rf "$XS_T"' EXIT
mkdir -p "$XS_T/home/.zuvo" "$XS_T/tmp"
XS_LANES="codex-5.3 cursor-agent agy gemini kimi claude"
# probe <tag> [VAR=value…] -- <driver args…> — a dry run from the CWD; output in $XS_T/<tag>.out; prints
# the exit code. The fan-out cap is lifted: since 0982d1d it SAMPLES lanes at random, and a dry run
# calls nothing, so every probe must see the whole set.
probe() {
  local tag="$1" rc=0 envs=(); shift
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  printf '%s' "$XS_DIFF" | env -u CLAUDECODE -u ANTIGRAVITY_SESSION_ID -u VSCODE_GIT_ASKPASS_MAIN -u QWEN_CODE \
      -u CODEX_SANDBOX -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE -u CODEX_SHELL -u __CFBundleIdentifier \
      HOME="$XS_T/home" ZUVO_HOME="$XS_T/home/.zuvo" TMPDIR="$XS_T/tmp" ZUVO_NO_CAFFEINATE=1 \
      ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="$XS_LANES" ZUVO_REVIEW_MAX_PROVIDERS=99 \
      ${envs[@]+"${envs[@]}"} timeout 90 bash "$ADV" --dry-run --multi "$@" > "$XS_T/$tag.out" 2>&1 || rc=$?
  echo "$rc"
}
plist() { sed -n 's/^Providers: //p' "$XS_T/$1.out" | head -1 | sed 's/ *(.*//'; }
has() { printf '%s\n' "$1" | tr ' ' '\n' | grep -qFx "$2"; }
# probed <tag> <label> — the probe exited 0 and printed a Providers line; anything else fails the case,
# never skips it.
probed() {
  if [ "$(cat "$XS_T/$1.rc")" != 0 ] || [ -z "$(plist "$1")" ]; then
    bad "$2: the probe failed (exit $(cat "$XS_T/$1.rc")): $(tail -3 "$XS_T/$1.out" | tr '\n' ' ')"; return 1
  fi
}
run() { local tag="$1"; shift; probe "$tag" "$@" > "$XS_T/$tag.rc"; }

run base --
if probed base "the base probe"; then
  [ "$(plist base)" = "$XS_LANES" ] && pass "the base probe lists every harness lane" \
    || bad "the base probe lists [$(plist base)], not [$XS_LANES]"
fi

# 1. One --exclude removes exactly that provider.
run x1 -- --exclude codex-5.3
if probed x1 "single --exclude"; then
  [ "$(plist x1)" = "cursor-agent agy gemini kimi claude" ] && pass "single --exclude removes its provider, and only it" \
    || bad "single --exclude codex-5.3 left [$(plist x1)]"
fi

# 2. THE BUG: two --exclude flags must remove BOTH, not just the last one.
run x2 -- --exclude codex-5.3 --exclude cursor-agent
if probed x2 "repeated --exclude"; then
  if has "$(plist x2)" codex-5.3; then
    bad "--exclude codex-5.3 --exclude cursor-agent left codex-5.3 — the second flag overwrote the first (got: $(plist x2))"
  elif has "$(plist x2)" cursor-agent; then
    bad "--exclude codex-5.3 --exclude cursor-agent left cursor-agent (got: $(plist x2))"
  else
    pass "repeated --exclude accumulates as a set (both removed)"
  fi
fi

# 3. An empty --exclude stays a documented noop and must not corrupt the set.
run x3 -- --exclude "" --exclude codex-5.3
if probed x3 "empty --exclude"; then
  [ "$(plist x3)" = "cursor-agent agy gemini kimi claude" ] && pass "empty --exclude is a noop and does not corrupt the set" \
    || bad "--exclude \"\" --exclude codex-5.3 left [$(plist x3)]"
fi

# 4. THE SAFETY BUG: --exclude must not disable host auto-exclusion. A Cursor host (its terminal's askpass
#    path) with an unrelated --exclude: cursor-agent must still go.
run cur VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/probe -- --exclude kimi
if probed cur "the Cursor-host probe"; then
  if has "$(plist cur)" cursor-agent; then
    bad "on a cursor host with --exclude, cursor-agent stayed in the list — self-review (got: $(plist cur))"
  elif has "$(plist cur)" kimi; then
    bad "on a cursor host, --exclude kimi was lost to the host exclusion (got: $(plist cur))"
  else
    pass "host auto-exclusion still applies when --exclude is passed (no self-review), and --exclude too"
  fi
  # Match the shape, not the exact wording: the line NAMES the excluded clients ("auto-excluding agy
  # gemini to prevent self-review") because a host can front several.
  grep -qE "auto-excluding.*to prevent self-review" "$XS_T/cur.out" \
    && pass "host exclusion is announced on stderr" \
    || bad "host exclusion happened silently — no 'auto-excluding' line"
fi

# 4b. A host is a SET of clients, not one name. Antigravity reaches the SAME Gemini model through BOTH
#     `agy` and `gemini`; excluding only `agy` left the sibling lane free to review its own host's output —
#     exclusion applied, announced, and ineffective (cross-model adversarial, 2026-08-11). Both lanes are
#     harness lanes here, so both are always observed.
run ag ANTIGRAVITY_SESSION_ID=probe --
if probed ag "the Antigravity-host probe"; then
  if has "$(plist ag)" agy || has "$(plist ag)" gemini; then
    bad "on an Antigravity host a Gemini lane stayed eligible — sibling self-review (got: $(plist ag))"
  else
    pass "Antigravity host excludes BOTH Gemini lanes (agy and gemini)"
  fi
fi

# 4c. Source guard: detect_host_platform must keep returning both lanes for Antigravity.
# Source guards read the program as one text — driver + modules (tests/lib/adversarial-driver.sh).
. "$ROOT/tests/lib/adversarial-driver.sh"
# Here-strings, not `printf | grep -q`: if this file ever gains pipefail, grep's early exit on a match could
# SIGPIPE the writer and turn the absence checks in 5 into passes.
XS_OK=1; XS_SRC="$(adv_driver_source "$ADV")" || { XS_OK=0; bad "the program text could not be assembled (reason above) — the source guards in 4c and 5 are skipped"; }
if [ "$XS_OK" -eq 1 ]; then
  # The awk range starts at the first line naming the Antigravity block: in the program as one text that
  # must still be detect_host_platform's, so the anchor has to be unique.
  xs_anchor="$(grep -c 'Antigravity (Google IDE)' <<< "$XS_SRC")"
  if [ "$xs_anchor" != "1" ]; then
    bad "the Antigravity anchor occurs $xs_anchor time(s) in the program, not once — the guard below would read the wrong block"
  elif awk '/Antigravity \(Google IDE\)/,/^  fi/' <<< "$XS_SRC" | grep -qE 'echo "agy gemini"'; then
    pass "detect_host_platform still returns both Gemini lanes for Antigravity"
  else
    bad "detect_host_platform no longer returns 'agy gemini' — the sibling-lane self-review is back"
  fi
fi

# 4d. Splitting the set must WORD-SPLIT, not GLOB. `--exclude` takes arbitrary CLI text, so an unquoted
#     `$EXCLUDE_PROVIDER` expansion also does pathname expansion: run from a directory holding a file named
#     `claude`, `--exclude 'clau*'` expanded to that filename and excluded the claude provider nobody asked
#     to exclude. The mirror case is worse — a value that globs to nothing or to the wrong name leaves the
#     provider you DID name in the pool, so the host self-review guard reports "excluded" and does not
#     exclude. Found by the CQ auditor 2026-08-11 (CQ31); fixed with `set -f` at each split site.
glob_dir="$XS_T/globdir"; mkdir -p "$glob_dir"; : > "$glob_dir/claude"
( cd "$glob_dir" && probe glob -- --exclude 'clau*' > "$XS_T/glob.rc" )
if probed glob "the glob probe"; then
  has "$(plist glob)" claude && pass "--exclude splits on whitespace only; a glob pattern does not expand against CWD" \
    || bad "--exclude 'clau*' removed claude by expanding against a CWD file — pathname expansion at the split site (got: $(plist glob))"
fi

# 5. Source guard: the scalar assignment must not come back. A future edit reverting to
#    `EXCLUDE_PROVIDER="$2"` would pass every check above on a single-provider machine.
if [ "$XS_OK" -eq 1 ]; then
  # Anywhere on a line, not only at its start: `[[ -n "$2" ]] && EXCLUDE_PROVIDER="$2"` is the same revert.
  if grep -qE '(^|[;&|[:space:]])EXCLUDE_PROVIDER="\$2"' <<< "$XS_SRC"; then
    bad "--exclude parsing reverted to a scalar assignment (EXCLUDE_PROVIDER=\"\$2\")"
  else
    pass "--exclude parsing still accumulates (no scalar assignment)"
  fi
  if grep -qE 'if \[\[ -n "\$HOST_PROVIDER" && -z "\$EXCLUDE_PROVIDER" \]\]' <<< "$XS_SRC"; then
    bad "host auto-exclusion is gated on -z EXCLUDE_PROVIDER again — --exclude disables self-review prevention"
  else
    pass "host auto-exclusion is not suppressed by --exclude"
  fi
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
