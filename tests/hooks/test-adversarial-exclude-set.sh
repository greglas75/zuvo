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

# `Providers: a b c` line from a dry run. Never reaches a network call.
providers() { echo x | timeout 90 bash "$ADV" --dry-run --multi "$@" 2>&1 | sed -n 's/^Providers: //p'; }
as_cursor_providers() {
  echo x | env -u CLAUDECODE -u CODEX_SANDBOX -u ANTIGRAVITY_SESSION_ID \
    VSCODE_GIT_ASKPASS_MAIN="/Applications/Cursor.app/probe" \
    timeout 90 bash "$ADV" --dry-run --multi "$@" 2>&1
}
has() { printf '%s\n' "$1" | tr ' ' '\n' | grep -qFx "$2"; }

BASE="$(providers)"
[ -n "$BASE" ] || { pass "no providers detectable in this environment — exclusion is unobservable (skipped)"; echo "=== RESULT ==="; echo "ALL PASS"; exit 0; }

# Pick two real provider names to exclude; the filter is exact whole-line by design
# (names contain regex-active chars like codex-5.3), so invented names prove nothing.
# `claude` is never auto-excluded on a claude host, so skip it as a subject here.
CAND=""
for p in $BASE; do [ "$p" = "claude" ] || CAND="$CAND $p"; done
set -- $CAND
if [ $# -lt 2 ]; then
  pass "fewer than 2 excludable providers here — multi-exclude unobservable (skipped)"
else
  A="$1"; B="$2"

  # 1. One --exclude removes exactly that provider.
  out="$(providers --exclude "$A")"
  has "$out" "$A" && bad "single --exclude $A did not remove it (got: $out)" \
                  || pass "single --exclude removes its provider"

  # 2. THE BUG: two --exclude flags must remove BOTH, not just the last one.
  out="$(providers --exclude "$A" --exclude "$B")"
  if has "$out" "$A"; then
    bad "--exclude $A --exclude $B left $A in the list — the second flag overwrote the first (got: $out)"
  elif has "$out" "$B"; then
    bad "--exclude $A --exclude $B left $B in the list (got: $out)"
  else
    pass "repeated --exclude accumulates as a set (both $A and $B removed)"
  fi

  # 3. An empty --exclude stays a documented noop and must not corrupt the set.
  out="$(providers --exclude "" --exclude "$A")"
  has "$out" "$A" && bad "empty --exclude broke a following --exclude $A (got: $out)" \
                  || pass "empty --exclude is a noop and does not corrupt the set"
fi

# 4. THE SAFETY BUG: --exclude must not disable host auto-exclusion.
#    Only meaningful if cursor-agent is actually installed here.
if has "$BASE" "cursor-agent"; then
  out="$(as_cursor_providers --exclude kimi)"
  plist="$(printf '%s\n' "$out" | sed -n 's/^Providers: //p')"
  if has "$plist" "cursor-agent"; then
    bad "on a cursor host with --exclude, cursor-agent stayed in the list — self-review (got: $plist)"
  else
    pass "host auto-exclusion still applies when --exclude is passed (no self-review)"
  fi
  # Match the shape, not the exact wording: the line now NAMES the excluded clients
  # ("auto-excluding agy gemini to prevent self-review") because a host can front several.
  printf '%s\n' "$out" | grep -qE "auto-excluding.*to prevent self-review" \
    && pass "host exclusion is announced on stderr" \
    || bad "host exclusion happened silently — no 'auto-excluding' line"
else
  pass "cursor-agent not installed — host self-review case unobservable (skipped)"
fi

# 4b. A host is a SET of clients, not one name. Antigravity reaches the SAME Gemini model
#     through BOTH `agy` and `gemini`; excluding only `agy` left the sibling lane free to
#     review its own host's output — exclusion applied, announced, and ineffective. Found by
#     cross-model adversarial on 2026-08-11 after the identical fix had landed in
#     blind-audit-codex.sh (HOST_EXCLUDE="gemini agy") but not here.
ag_out="$(echo x | env -u CLAUDECODE -u CODEX_SANDBOX -u VSCODE_GIT_ASKPASS_MAIN \
  ANTIGRAVITY_SESSION_ID=probe timeout 90 bash "$ADV" --dry-run --multi 2>&1)"
ag_list="$(printf '%s\n' "$ag_out" | sed -n 's/^Providers: //p')"
if [ -z "$ag_list" ]; then
  pass "no providers detectable under the Antigravity probe — dual-lane case unobservable (skipped)"
else
  # Only lanes that are actually INSTALLED here can be observed. Report which ones were
  # checked — a blanket "excludes BOTH" when `gemini` is not on this machine is fake
  # coverage: it passes against the pre-fix binary too (verified 2026-08-11), so it would
  # have reported the sibling-lane self-review as fixed while it was still open.
  dual_fail=0 checked="" unobservable=""
  for lane in agy gemini; do
    if ! has "$BASE" "$lane"; then unobservable="${unobservable:+$unobservable }$lane"; continue; fi
    checked="${checked:+$checked }$lane"
    if has "$ag_list" "$lane"; then
      bad "on an Antigravity host, '$lane' stayed eligible — the sibling Gemini lane can self-review (got: $ag_list)"
      dual_fail=1
    fi
  done
  if [ -z "$checked" ]; then
    pass "no Gemini-lane client installed — dual-lane exclusion unobservable here (skipped)"
  elif [ "$dual_fail" -eq 0 ]; then
    pass "Antigravity host excludes the installed Gemini lane(s): $checked${unobservable:+ (not installed, unchecked: $unobservable)}"
  fi
fi

# 4c. Source guard: detect_host_platform must keep returning both lanes for Antigravity.
if awk '/Antigravity \(Google IDE\)/,/^  fi/' "$ADV" | grep -qE 'echo "agy gemini"'; then
  pass "detect_host_platform still returns both Gemini lanes for Antigravity"
else
  bad "detect_host_platform no longer returns 'agy gemini' — the sibling-lane self-review is back"
fi

# 4d. Splitting the set must WORD-SPLIT, not GLOB. `--exclude` takes arbitrary CLI text, so an
#     unquoted `$EXCLUDE_PROVIDER` expansion also does pathname expansion: run from a directory
#     holding a file named `claude`, `--exclude 'clau*'` expanded to that filename and excluded
#     the claude provider that nobody asked to exclude. The mirror case is worse — a value that
#     globs to nothing or to the wrong name leaves the provider you DID name in the pool, so the
#     host self-review guard reports "excluded" and does not exclude. Found by the CQ auditor
#     2026-08-11 (CQ31) on code added the same day; fixed with `set -f` at each split site.
if has "$BASE" "claude"; then
  glob_dir="$(mktemp -d)"; : > "$glob_dir/claude"
  glob_out="$(cd "$glob_dir" && echo x | timeout 90 bash "$ADV" --dry-run --multi --exclude 'clau*' 2>&1 \
    | sed -n 's/^Providers: //p')"
  rm -rf "$glob_dir"
  if [ -z "$glob_out" ]; then
    pass "glob probe produced no provider list — unobservable here (skipped)"
  elif has "$glob_out" "claude"; then
    pass "--exclude splits on whitespace only; a glob pattern does not expand against CWD"
  else
    bad "--exclude 'clau*' removed claude by expanding against a CWD file — pathname expansion at the split site (got: $glob_out)"
  fi
else
  pass "claude provider not installed — glob-expansion case unobservable (skipped)"
fi

# 5. Source guard: the scalar assignment must not come back. A future edit reverting to
#    `EXCLUDE_PROVIDER="$2"` would pass every check above on a single-provider machine.
if grep -qE '^\s*EXCLUDE_PROVIDER="\$2"' "$ADV"; then
  bad "--exclude parsing reverted to a scalar assignment (EXCLUDE_PROVIDER=\"\$2\")"
else
  pass "--exclude parsing still accumulates (no scalar assignment)"
fi
if grep -qE 'if \[\[ -n "\$HOST_PROVIDER" && -z "\$EXCLUDE_PROVIDER" \]\]' "$ADV"; then
  bad "host auto-exclusion is gated on -z EXCLUDE_PROVIDER again — --exclude disables self-review prevention"
else
  pass "host auto-exclusion is not suppressed by --exclude"
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
