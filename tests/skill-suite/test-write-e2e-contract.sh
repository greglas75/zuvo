#!/usr/bin/env bash
# Contract test for the zuvo:write-e2e V2 reference files.
#
# The V1 skill carried its quality gates inline in SKILL.md with a numbering
# that drifted from the invariants it claimed to enforce (V1 E2E-Q6 was
# "external API mocking", non-critical; V2 makes network policy Q4/Q5 and
# CRITICAL, and Q6 is cleanup). Numbering drift across three files is exactly
# the class of defect a grep contract catches and prose review does not, so
# every cross-file E2E-Q citation is pinned here against ONE authoritative
# mapping:
#
#   Q1  no arbitrary waits / networkidle
#   Q2  test independence + unique data
#   Q3  causal oracle after the decisive event
#   Q4  fail-closed network policy
#   Q5  mutation contract validation
#   Q6  cleanup for destructive operations
#   Q7  runner/browser version compatibility
#   Q8  no external mutation flows without explicit consent
#   Q9  gray-box explicitly labeled
#   Q10 spec size limit + helper extraction
#
# ALL TEN ARE CRITICAL. skills/write-e2e/references/quality-gates.md is the
# single source of truth; gate-registry.md only points at it.
#
# Path depth is asserted here as well as in test-references-guards.sh: the
# guard suite proves the VALIDATOR rejects a wrong depth, this suite proves
# THESE files are actually right. A shipped references/ file is one level
# deeper than SKILL.md, so its include tokens must be ../../../.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REFDIR="$ROOT/skills/write-e2e/references"
PATTERNS="$REFDIR/playwright-patterns.md"
NETWORK="$REFDIR/network-mocking.md"
GATES="$REFDIR/quality-gates.md"
# Second reference trio (Phase 0/1 discovery+scoring, Phase 2 scaffold, Phase 4
# live validation). Asserted in sections (7)-(11) below; the sections above are
# unchanged and still describe only the first trio.
DISCOVERY="$REFDIR/discovery-and-scoring.md"
SCAFFOLD="$REFDIR/scaffold.md"
LIVEVAL="$REFDIR/live-validation.md"
fail=0

pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# ── the ONE copy of the V2 ID -> invariant map ──────────────────────────────
# Adversarial finding F2: this map used to be re-typed in every consumer, and the
# copies had ALREADY drifted (the registry check demanded `wait|networkidle|sleep`
# for E2E-Q1 while the website check demanded only `wait|networkidle`) -- the exact
# split-brain this suite exists to prevent. It is now written down once, here, and
# every consumer reads it: the authoritative table (section 3), the by-reference
# registration in gate-registry.md (section 12) and the website page (section 14).
# Do not re-type these patterns anywhere else in this file.
#
# DEPENDENCY NOTE (deliberate, do not "improve"): the python blocks below scan the
# YAML/markdown with scoped regexes instead of `yaml.safe_load`. PyYAML is a
# third-party package that nothing else in this repo's tests or scripts imports --
# scripts/validate-skill-pages.sh parses these same pages with grep -- so requiring
# it would break `bash tests/run-all.sh` on a fresh machine, and a
# `try: import yaml / except: <weaker path>` fallback is worse still: the suite
# would then enforce two different contracts depending on the box. The answer is
# not free-text grepping either: scope every scan by KEY and INDENTATION so it is
# structural without a parser dependency.
E2E_TMP="$(mktemp -d)"
trap 'rm -rf "$E2E_TMP"' EXIT
E2E_LIB="$E2E_TMP/e2e_invariants.py"
cat > "$E2E_LIB" <<'PY'
INVARIANT = {
    1:  r'wait|networkidle',
    2:  r'independen',
    3:  r'oracle|causal',
    4:  r'fail-closed|fail closed',
    5:  r'mutation contract|contract validation',
    6:  r'cleanup|teardown',
    7:  r'version',
    8:  r'consent',
    9:  r'gray-?box',
    10: r'size|helper',
}
LABEL = {
    1:  'no arbitrary waits / networkidle',
    2:  'test independence + unique data',
    3:  'causal oracle after the decisive event',
    4:  'fail-closed network policy',
    5:  'mutation contract validation',
    6:  'cleanup for destructive operations',
    7:  'runner/browser version compatibility',
    8:  'external mutation flows need consent',
    9:  'gray-box explicitly labeled',
    10: 'spec size limit + helper extraction',
}
PY

# Mirrors the codex/cursor/antigravity build token scan — this does not define
# the list, it copies it. Keep in sync with tests/skill-suite/test-references-guards.sh.
TOKENS='TaskCreate|TaskUpdate|TaskList|EnterPlanMode|ExitPlanMode|AskUserQuestion|run_in_background|TeamCreate|SendMessage'

# Same token shape validate-skills.sh uses, so "every include in these files"
# means the same set of strings the validator would inspect.
INCLUDE_TOKEN_RE='(\.\./)+(shared/includes|rules)/[A-Za-z0-9._-]+\.md'

# ── (1) the three reference files exist ──────────────────────────────────────
missing=0
for f in "$PATTERNS" "$NETWORK" "$GATES"; do
  if [ -f "$f" ]; then
    pass "exists: ${f#"$ROOT"/}"
  else
    bad "missing: ${f#"$ROOT"/}"
    missing=1
  fi
done

# Every remaining assertion reads these files; without them the greps below
# would print a wall of misleading failures.
if [ "$missing" -ne 0 ]; then
  echo ""
  echo "SOME CHECKS FAILED"
  exit 1
fi

# ── (2) include depth: references/ resolves against its OWN dir → ../../../ ──
inc_total=0
inc_bad=""
for f in "$PATTERNS" "$NETWORK" "$GATES"; do
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    inc_total=$((inc_total + 1))
    case "$tok" in
      ../../../*) ;;
      *) inc_bad="$inc_bad ${f#"$ROOT"/}:$tok" ;;
    esac
  done < <(grep -oE -- "$INCLUDE_TOKEN_RE" "$f" | sort -u)
done

if [ "$inc_total" -eq 0 ]; then
  bad "no shared/includes|rules include token in any reference file (depth assertion would be vacuous)"
elif [ -n "$inc_bad" ]; then
  bad "wrong-depth include token(s) in references/ (must be ../../../):$inc_bad"
else
  pass "all $inc_total include token(s) in references/ use ../../../"
fi

# ── (3) quality-gates.md holds EXACTLY E2E-Q1..E2E-Q10, all critical ─────────
row_count="$(grep -c '^| E2E-Q' "$GATES")"
if [ "$row_count" -eq 10 ]; then
  pass "quality-gates.md has exactly 10 '^| E2E-Q' rows"
else
  bad "quality-gates.md has $row_count '^| E2E-Q' rows (want exactly 10)"
fi

ids="$(grep -oE '^\| E2E-Q[0-9]+' "$GATES" | grep -oE 'E2E-Q[0-9]+' | sort -u -t Q -k2 -n | tr '\n' ' ')"
want="E2E-Q1 E2E-Q2 E2E-Q3 E2E-Q4 E2E-Q5 E2E-Q6 E2E-Q7 E2E-Q8 E2E-Q9 E2E-Q10 "
if [ "$ids" = "$want" ]; then
  pass "quality-gates.md row IDs are exactly E2E-Q1..E2E-Q10, each once"
else
  bad "quality-gates.md row IDs wrong: got [$ids] want [$want]"
fi

# Critical is column 3 of the pipe table (field 4 with the leading empty field).
noncrit="$(awk -F'|' '/^\| E2E-Q/ {
  v = $4; gsub(/^[ \t]+|[ \t]+$/, "", v);
  if (v != "Yes") { id = $2; gsub(/^[ \t]+|[ \t]+$/, "", id); printf "%s(%s) ", id, v }
}' "$GATES")"
if [ -z "$noncrit" ]; then
  pass "every E2E-Q row is marked critical (Yes)"
else
  bad "non-critical E2E-Q row(s) — all ten must be Yes: $noncrit"
fi

# Each row must carry the invariant the authoritative mapping assigns to it,
# so a future edit cannot silently re-point a number at a different rule.
check_row() { # check_row <id> <ere> <human>
  local line
  line="$(grep -E "^\| $1 " "$GATES" | head -1)"
  if [ -z "$line" ]; then
    bad "quality-gates.md: no row for $1"
  elif printf '%s' "$line" | grep -Eqi -- "$2"; then
    pass "quality-gates.md: $1 = $3"
  else
    bad "quality-gates.md: $1 row does not describe '$3' (mapping drift)"
  fi
}
# The ten (id, invariant, label) triples come from the ONE map defined above --
# they are not re-typed here. If the dump yields anything other than ten rows the
# loop would silently assert nothing, so the count is asserted too.
row_checks=0
while IFS="$(printf '\t')" read -r rc_id rc_re rc_human; do
  [ -n "$rc_id" ] || continue
  row_checks=$((row_checks + 1))
  check_row "$rc_id" "$rc_re" "$rc_human"
done < <(python3 - "$E2E_LIB" <<'PY' 2>/dev/null
import sys
ns = {}
exec(compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec"), ns)
for n in sorted(ns["INVARIANT"]):
    print("E2E-Q%d\t%s\t%s" % (n, ns["INVARIANT"][n], ns["LABEL"][n]))
PY
)
if [ "$row_checks" -eq 10 ]; then
  pass "all ten row checks ran off the shared invariant map"
else
  bad "shared invariant map yielded $row_checks row check(s), want 10 (the ten checks above are vacuous)"
fi

# ── (3b) cross-file citation consistency ────────────────────────────────────
# Network policy is Q4/Q5 in V2. V1 numbered network mocking E2E-Q6, which is
# now cleanup — a stale Q6 inside network-mocking.md is the exact drift to catch.
net_cites="$(grep -oE 'E2E-Q[0-9]+' "$NETWORK" | sort -u -t Q -k2 -n | tr '\n' ' ')"
if [ "$net_cites" = "E2E-Q4 E2E-Q5 " ]; then
  pass "network-mocking.md cites exactly E2E-Q4 and E2E-Q5"
else
  bad "network-mocking.md cites [$net_cites] — want exactly [E2E-Q4 E2E-Q5 ] (no stale Q6 for the network gate)"
fi

if grep -q 'E2E-Q6' "$PATTERNS"; then
  pass "playwright-patterns.md cites E2E-Q6 for cleanup"
else
  bad "playwright-patterns.md does not cite E2E-Q6 (cleanup gate wording lives here)"
fi

# Cleanup gate wording and the Q6 citation must be the same subject.
if grep -Ei 'E2E-Q6' "$PATTERNS" | grep -qi 'cleanup'; then
  pass "playwright-patterns.md ties E2E-Q6 to cleanup on the same line"
else
  bad "playwright-patterns.md cites E2E-Q6 but not next to 'cleanup'"
fi

# No citation anywhere outside the defined 1..10 range.
stray=""
for f in "$PATTERNS" "$NETWORK" "$GATES"; do
  while IFS= read -r c; do
    n="${c#E2E-Q}"
    if [ "$n" -lt 1 ] 2>/dev/null || [ "$n" -gt 10 ] 2>/dev/null; then
      stray="$stray ${f#"$ROOT"/}:$c"
    fi
  done < <(grep -oE 'E2E-Q[0-9]+' "$f" | sort -u)
done
if [ -z "$stray" ]; then
  pass "no E2E-Q citation outside the defined Q1..Q10 range"
else
  bad "out-of-range E2E-Q citation(s):$stray"
fi

# ── (4) playwright-patterns.md: causality contract, locators, confidence ─────
for field in 'trigger' 'decisive event' 'pre-state' 'post-state' 'visible oracle' 'cleanup'; do
  if grep -qi -- "$field" "$PATTERNS"; then
    pass "playwright-patterns.md names causality field '$field'"
  else
    bad "playwright-patterns.md missing causality field '$field'"
  fi
done

role_line="$(grep -n 'getByRole' "$PATTERNS" | head -1 | cut -d: -f1)"
testid_line="$(grep -n 'getByTestId' "$PATTERNS" | head -1 | cut -d: -f1)"
if [ -n "$role_line" ] && [ -n "$testid_line" ] && [ "$role_line" -lt "$testid_line" ]; then
  pass "locator hierarchy: getByRole (line $role_line) precedes getByTestId (line $testid_line)"
else
  bad "locator hierarchy wrong or incomplete (getByRole line='$role_line', getByTestId line='$testid_line')"
fi

# The V1 skill made HIGH confidence conditional on data-testid presence, which
# is what pushed generators toward testid-first locators. Must be stated dead.
if grep -Eqi 'confidence[^.]*(must not|does not|never)[^.]*testid' "$PATTERNS"; then
  pass "playwright-patterns.md states confidence does not require a testid"
else
  bad "playwright-patterns.md lacks an explicit 'confidence does not require testid' statement"
fi

if grep -Eqi 'graybox|gray-box' "$PATTERNS"; then
  pass "playwright-patterns.md defines gray-box labeling"
else
  bad "playwright-patterns.md does not define gray-box labeling"
fi

# ── (5) network-mocking.md: policy, match key, allow-list, glob ban ─────────
if grep -qi 'fail-closed' "$NETWORK"; then
  pass "network-mocking.md states the fail-closed default"
else
  bad "network-mocking.md does not state a fail-closed default"
fi

if grep -i 'hostname' "$NETWORK" | grep -i 'method' | grep -qi 'pathname'; then
  pass "network-mocking.md states the hostname+method+pathname match key"
else
  bad "network-mocking.md does not state hostname+method+pathname as ONE match key"
fi

if grep -Eqi 'allowed[- ]host' "$NETWORK"; then
  pass "network-mocking.md requires an allowed-host list"
else
  bad "network-mocking.md does not require an allowed-host list"
fi

if grep -Fq '**/api/**' "$NETWORK" && grep -qi 'vite' "$NETWORK" && grep -qi 'sentry' "$NETWORK"; then
  pass "network-mocking.md bans broad directory globs and cites the Vite/Sentry incident"
else
  bad "network-mocking.md lacks the '**/api/**' glob ban with the Vite-module/Sentry incident"
fi

if grep 'E2E-Q4' "$NETWORK" | grep -q 'CRITICAL' && grep 'E2E-Q5' "$NETWORK" | grep -q 'CRITICAL'; then
  pass "network-mocking.md marks E2E-Q4 and E2E-Q5 CRITICAL"
else
  bad "network-mocking.md does not spell out E2E-Q4 / E2E-Q5 as CRITICAL"
fi

if grep -Eqi 'escape hatch|justification' "$NETWORK"; then
  pass "network-mocking.md documents the escape hatch and its justification requirement"
else
  bad "network-mocking.md has no documented escape hatch / justification rule"
fi

# ── (5b) the example must OBEY the policy the file mandates ─────────────────
# Adversarial review, 3 providers converged: the first draft's allow-listed
# branch was `if (isAllowedHost(host)) return route.continue()`. That checks the
# hostname only — contradicting the match key one section earlier — and lets the
# app's real mutations reach the network un-intercepted, so E2E-Q5 (which
# validates the contract on intercepted requests) can never see them. An allowed
# host is a permitted destination, never an unchecked one.
if grep -n 'route.continue()' "$NETWORK" | grep -Eqi 'allow|host'; then
  bad "network-mocking.md: an allow/host check leads straight to route.continue() (fail-open example)"
else
  pass "network-mocking.md has no host-only allow-then-continue branch"
fi

if grep -q 'request.method()' "$NETWORK" && grep -q 'url.pathname' "$NETWORK"; then
  pass "network-mocking.md classifies every request on method AND pathname, not host alone"
else
  bad "network-mocking.md handler does not classify on method + pathname"
fi

if grep -qi 'regardless of which host' "$NETWORK"; then
  pass "network-mocking.md states mutations are checked regardless of which host they target"
else
  bad "network-mocking.md does not state that mutations are checked regardless of host"
fi

# FIX 5: the policy promises denied traffic is recorded and surfaced — the
# example has to actually do it, or the file ships a policy it contradicts.
if grep -Fq 'blocked.push(' "$NETWORK" && grep -Eqi 'afterEach|console.warn' "$NETWORK"; then
  pass "network-mocking.md records blocked requests and surfaces them in a hook"
else
  bad "network-mocking.md promises recording/reporting but the example does neither"
fi

# ── (5c) Playwright route precedence + the catch-all carve-out ──────────────
# A '**/*' handler registered last (or at page scope) shadows the specific mocks
# this file tells authors to write — silently, because a shadowed handler never
# runs. The prose must say so; a reader will not guess it.
if grep -qi 'precedence' "$NETWORK" && grep -Fq 'page.route()' "$NETWORK"; then
  pass "network-mocking.md explains page.route vs context.route precedence"
else
  bad "network-mocking.md does not explain route precedence / registration order"
fi

if grep -Eqi 'reverse registration order|registered (last|first)' "$NETWORK"; then
  pass "network-mocking.md states the registration-order rule explicitly"
else
  bad "network-mocking.md does not state the registration-order rule"
fi

# The mandated fail-closed handler IS '**/*' — the exact glob this file bans.
# Without an explicit carve-out a reader following the file fails their own gate.
if grep -qi 'sentinel' "$NETWORK" && grep -Eqi 'intercept and fulfil|intercept and fulfill' "$NETWORK"; then
  pass "network-mocking.md carves out the deny-all sentinel from the broad-glob ban"
else
  bad "network-mocking.md bans '**/*' while mandating it — no deny-all sentinel carve-out"
fi

# ── (5d) mutation example: listener BEFORE trigger, guarded body/header ─────
req_line="$(grep -n 'waitForRequest' "$NETWORK" | head -1 | cut -d: -f1)"
click_line="$(grep -n '\.click(' "$NETWORK" | head -1 | cut -d: -f1)"
if [ -n "$req_line" ] && [ -n "$click_line" ] && [ "$req_line" -lt "$click_line" ]; then
  pass "mutation example registers the listener (line $req_line) before the trigger (line $click_line)"
else
  bad "mutation example races: waitForRequest line='$req_line' trigger line='$click_line'"
fi

# postDataJSON() throws on multipart/urlencoded and returns null on an empty
# body; headers()['content-type'] can be undefined. The file presents this
# snippet as the exemplar, so both have to be guarded.
if grep -Fq 'request.postData()' "$NETWORK" && grep -qi 'multipart' "$NETWORK"; then
  pass "mutation example reads postData() and warns about non-JSON bodies"
else
  bad "mutation example still relies on unguarded postDataJSON()"
fi

if grep -F "?? ''" "$NETWORK" | grep -qi 'content-type'; then
  pass "mutation example guards a possibly-undefined content-type header"
else
  bad "mutation example calls a string method on a possibly-undefined content-type"
fi

# ── (5e) IPv6 loopback in the allowed-host list ─────────────────────────────
# Many dev servers bind [::1]; url.hostname renders it WITH the brackets, so
# "the app's own origin is allowed by default" is false without this entry.
if grep -Fq '[::1]' "$NETWORK"; then
  pass "allowed-host list includes the IPv6 loopback [::1]"
else
  bad "allowed-host list omits the IPv6 loopback [::1]"
fi

# ── (4b) cleanup must be best-effort and must not bury the real failure ─────
if grep -qi 'best-effort' "$PATTERNS" && grep -Eqi 'never mask|not mask' "$PATTERNS"; then
  pass "playwright-patterns.md requires best-effort cleanup that does not mask the failure"
else
  bad "playwright-patterns.md mandates cleanup without a best-effort / no-masking rule"
fi

# storageState reuse vs E2E-Q2's ban on shared mutable state — the two only
# coexist with an explicit isolation constraint.
if grep -qi 'per-worker' "$PATTERNS"; then
  pass "playwright-patterns.md gives storageState reuse a per-worker isolation constraint"
else
  bad "playwright-patterns.md recommends storageState reuse with no per-worker constraint"
fi

# ── (6) no Claude-only tool tokens (mirrors the platform build gate) ────────
hits="$(grep -REn "$TOKENS" "$PATTERNS" "$NETWORK" "$GATES" 2>/dev/null || true)"
if [ -z "$hits" ]; then
  pass "no Claude-only tool tokens in the write-e2e reference files"
else
  bad "Claude-only tool token(s) in references (platform builds would reject): $hits"
fi

# ── (7) second trio exists, with ../../../ include depth ────────────────────
# Content assertions below deliberately do NOT early-exit on a missing file:
# grep stderr is discarded so a missing file reports as a full list of failed
# invariants (useful RED) instead of one line plus a wall of noise.
for f in "$DISCOVERY" "$SCAFFOLD" "$LIVEVAL"; do
  if [ -f "$f" ]; then
    pass "exists: ${f#"$ROOT"/}"
  else
    bad "missing: ${f#"$ROOT"/}"
  fi
done

for f in "$DISCOVERY" "$SCAFFOLD" "$LIVEVAL"; do
  rel="${f#"$ROOT"/}"
  n=0
  bad_toks=""
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    n=$((n + 1))
    case "$tok" in
      ../../../*) ;;
      *) bad_toks="$bad_toks $tok" ;;
    esac
  done < <(grep -oE -- "$INCLUDE_TOKEN_RE" "$f" 2>/dev/null | sort -u)
  if [ "$n" -eq 0 ]; then
    bad "$rel: no shared/includes|rules include token (depth assertion would be vacuous)"
  elif [ -n "$bad_toks" ]; then
    bad "$rel: wrong-depth include token(s) (must be ../../../):$bad_toks"
  else
    pass "$rel: all $n include token(s) use ../../../"
  fi
done

# has <file> <ere> <human> — one grep-backed invariant, case-insensitive.
has() {
  if grep -Eqi -- "$2" "$1" 2>/dev/null; then
    pass "${1#"$ROOT"/}: $3"
  else
    bad "${1#"$ROOT"/}: $3 -- NOT FOUND"
  fi
}

# hasnt <file> <ere> <human> — the invariant is the ABSENCE of the pattern.
hasnt() {
  local hit
  hit="$(grep -Eni -- "$2" "$1" 2>/dev/null | head -3)"
  if [ -z "$hit" ]; then
    pass "${1#"$ROOT"/}: $3"
  else
    bad "${1#"$ROOT"/}: $3 -- found: $(printf '%s' "$hit" | tr '\n' ' ')"
  fi
}

# ── (8) live-validation.md: origin safety + the five-state verification model ─
# The G4 acceptance proof greps 'ORIGIN.*LOCAL' case-insensitively: a bare
# 'LOCAL' is already satisfied by VERIFIED_LOCAL, so the file must carry a
# literal origin-classification line naming all three classes on ONE line.
if grep -Eq 'Origin:.*LOCAL.*STAGING.*EXTERNAL_UNKNOWN' "$LIVEVAL" 2>/dev/null; then
  pass "live-validation.md carries the literal 'Origin: LOCAL | STAGING | EXTERNAL_UNKNOWN' line"
else
  bad "live-validation.md has no single line matching 'Origin:.*LOCAL.*STAGING.*EXTERNAL_UNKNOWN' (G4 proof anchor)"
fi
has "$LIVEVAL" 'ORIGIN.*LOCAL'   "origin token matches the G4 proof pattern ORIGIN.*LOCAL"

# Origin classes.
for cls in LOCAL STAGING EXTERNAL_UNKNOWN; do
  has "$LIVEVAL" "$cls" "origin class $cls defined"
done

# LOCAL is a REGEX, not a vibe: the loopback/private hosts must be spelled out.
# The regex ships escaped (127\.0\.0\.1), so each host token is matched with an
# OPTIONAL backslash before every dot -- prose or regex form both satisfy it.
for host in '127(\\)?\.0(\\)?\.0(\\)?\.1' 'localhost' 'host(\\)?\.docker(\\)?\.internal' '0(\\)?\.0(\\)?\.0(\\)?\.0'; do
  has "$LIVEVAL" "$host" "LOCAL regex includes $host"
done

# STAGING is explicit-only: consent flag or exact-host env, never a heuristic.
has "$LIVEVAL" 'allow-external-origin' "consent flag --allow-external-origin documented"
has "$LIVEVAL" 'ZUVO_E2E_STAGING_HOSTS' "STAGING honours ZUVO_E2E_STAGING_HOSTS exact-host match"
has "$LIVEVAL" 'no .*heuristic|heuristic.*(banned|never|not )' "STAGING states the no-hostname-heuristics rule"
if grep -Ei 'heuristic|guess' "$LIVEVAL" 2>/dev/null | grep -Eqi 'staging\.|vercel|production'; then
  pass "live-validation.md names the rejected heuristics (staging.*/vercel) and why guessing is unsafe"
else
  bad "live-validation.md does not name the rejected hostname heuristics (staging.* / *.vercel.app)"
fi

# EXTERNAL_UNKNOWN default: read-only specs, mutations BLOCKED (not warned).
has "$LIVEVAL" 'read-only' "EXTERNAL_UNKNOWN default generates read-only specs"
if grep -Ei 'block' "$LIVEVAL" 2>/dev/null | grep -Eqi 'mutat|form submit|non-GET'; then
  pass "live-validation.md BLOCKS mutating steps on an unknown origin (not a warning)"
else
  bad "live-validation.md does not state that mutating steps are BLOCKED on EXTERNAL_UNKNOWN"
fi
has "$LIVEVAL" 'destructive' "destructive operations need consent SEPARATE from --allow-external-origin"
if grep -Ei 'destructive' "$LIVEVAL" 2>/dev/null | grep -Eqi 'separate|second|additional|its own'; then
  pass "live-validation.md keeps destructive consent separate from --allow-external-origin"
else
  bad "live-validation.md does not separate destructive consent from --allow-external-origin"
fi

# The five validation states.
for st in GENERATED STATIC_CHECKED VERIFIED_LOCAL VALIDATED_LIVE BLOCKED FAILED; do
  has "$LIVEVAL" "$st" "validation state $st defined"
done

# MCP decoupling (DC-3): a local run needs preflight READY, NOT an MCP server.
if grep -Ei 'playwright test' "$LIVEVAL" 2>/dev/null | grep -Eqi 'READY'; then
  pass "live-validation.md ties a local 'playwright test' run to preflight READY"
else
  bad "live-validation.md does not tie local 'playwright test' to preflight READY"
fi
if grep -Ei 'MCP' "$LIVEVAL" 2>/dev/null | grep -Eqi 'only|not required|no MCP|never'; then
  pass "live-validation.md states MCP gates ONLY live DOM/locator inspection"
else
  bad "live-validation.md lacks the MCP-decoupling statement (MCP gates only VALIDATED_LIVE)"
fi

# Preflight helper: real invocation + all three states + a helper-absent fallback.
if grep -Fq '~/.zuvo/e2e-preflight probe' "$LIVEVAL" 2>/dev/null; then
  pass "live-validation.md invokes ~/.zuvo/e2e-preflight probe"
else
  bad "live-validation.md does not invoke '~/.zuvo/e2e-preflight probe'"
fi
for st in READY GENERATE_ONLY BOOTSTRAP_REQUIRED; do
  has "$LIVEVAL" "$st" "preflight state $st documented"
done
# A Codex/Cursor-only install never ran install_zuvo_home, so the fallback must
# reproduce the SAME three-state semantics rather than improvise.
fb="$(awk '/^##+ .*[Ff]allback/{f=1;next} f && /^##+ /{f=0} f' "$LIVEVAL" 2>/dev/null)"
if [ -z "$fb" ]; then
  bad "live-validation.md has no helper-absent fallback section"
else
  miss=""
  for st in READY GENERATE_ONLY BOOTSTRAP_REQUIRED; do
    printf '%s' "$fb" | grep -q "$st" || miss="$miss $st"
  done
  if [ -z "$miss" ]; then
    pass "live-validation.md fallback names all three preflight states"
  else
    bad "live-validation.md fallback does not name preflight state(s):$miss"
  fi
  if printf '%s' "$fb" | grep -Eq 'node_modules/\.bin/playwright|node_modules/@playwright/test'; then
    pass "live-validation.md fallback gives the manual detection mapping"
  else
    bad "live-validation.md fallback has no manual detection mapping (config/dep/binary/browser cache)"
  fi
fi
if grep -i 'npx' "$LIVEVAL" 2>/dev/null | grep -Eqi 'never|ban|do not|must not'; then
  pass "live-validation.md bans unpinned 'npx playwright' (silent install)"
else
  bad "live-validation.md does not ban unpinned 'npx playwright'"
fi

# Coverage registry: State column, legacy read rule, upsert path.
has "$LIVEVAL" 'memory/e2e-coverage\.md'  "names the coverage registry memory/e2e-coverage.md"
has "$LIVEVAL" 'State. column|State column' "registry gains a State column"
if grep -Ei 'legacy' "$LIVEVAL" 2>/dev/null | grep -q 'GENERATED'; then
  pass "live-validation.md reads legacy rows as GENERATED (no VERIFIED back-fill)"
else
  bad "live-validation.md does not state that legacy registry rows read as GENERATED"
fi
if grep -Fq 'coverage-upsert' "$LIVEVAL" 2>/dev/null; then
  pass "live-validation.md upserts via e2e-preflight coverage-upsert"
else
  bad "live-validation.md does not use 'e2e-preflight coverage-upsert' for registry writes"
fi

# ── (9) discovery-and-scoring.md: Phase 0/1, testid-free confidence ─────────
for t in 'Routes' 'API endpoint' 'Auth' 'Existing E2E'; do
  has "$DISCOVERY" "$t" "discovery target '$t' listed"
done
for sig in 'Mutation type' 'Auth requirement' 'Data sensitivity' 'traffic' 'Existing coverage'; do
  has "$DISCOVERY" "$sig" "scoring signal '$sig' listed"
done
weights="$(grep -cE '^\|.*\| *(30|20|15) *\|' "$DISCOVERY" 2>/dev/null || true)"
if [ "${weights:-0}" -ge 5 ]; then
  pass "discovery-and-scoring.md carries five weighted signal rows (30/20/20/15/15)"
else
  bad "discovery-and-scoring.md has $weights weighted signal rows (want >= 5 with weights 30/20/15)"
fi
for tier in CRITICAL IMPORTANT 'NICE-TO-HAVE' SKIP; do
  has "$DISCOVERY" "$tier" "score tier $tier defined"
done
for lv in HIGH MEDIUM LOW CONDITIONAL; do
  has "$DISCOVERY" "$lv" "confidence level $lv defined"
done

# THE regression this file exists to prevent: V1 made HIGH confidence require a
# data-testid, which is what taught the generator to reach for testid locators.
# No confidence CRITERIA ROW may mention a testid; the negation must be explicit.
conf="$(awk '/^##+ .*[Cc]onfidence/{f=1;next} f && /^##+ /{f=0} f' "$DISCOVERY" 2>/dev/null)"
if [ -z "$conf" ]; then
  bad "discovery-and-scoring.md has no confidence section"
else
  crit_rows="$(printf '%s\n' "$conf" | grep -E '^\|' | grep -i 'testid' || true)"
  if [ -z "$crit_rows" ]; then
    pass "discovery-and-scoring.md: no confidence criteria row requires a data-testid"
  else
    bad "discovery-and-scoring.md: confidence criteria row mentions testid: $(printf '%s' "$crit_rows" | tr '\n' ' ')"
  fi
  if printf '%s\n' "$conf" | grep -Eqi '(must not|does not|never|not a)[^.]*testid|testid[^.]*(is not|must not|never)'; then
    pass "discovery-and-scoring.md states explicitly that confidence does not require a testid"
  else
    bad "discovery-and-scoring.md lacks an explicit 'confidence does not require a testid' statement"
  fi
fi
if grep -Fq 'playwright-patterns.md' "$DISCOVERY" 2>/dev/null; then
  pass "discovery-and-scoring.md defers locator policy to playwright-patterns.md"
else
  bad "discovery-and-scoring.md does not cross-reference playwright-patterns.md"
fi

# ── (10) scaffold.md: write policy, structure, POM, auth, no locator restate ─
has "$SCAFFOLD" 'Write [Pp]olicy|write policy' "write policy section present"
if grep -Ei 'existing test file' "$SCAFFOLD" 2>/dev/null | grep -Eqi 'never|report only'; then
  pass "scaffold.md never modifies existing test files"
else
  bad "scaffold.md does not state 'never modify existing test files'"
fi
if grep -Ei 'playwright\.config' "$SCAFFOLD" 2>/dev/null | grep -Eqi 'propose|confirm|not auto'; then
  pass "scaffold.md proposes playwright.config changes instead of writing them"
else
  bad "scaffold.md does not gate playwright.config edits behind a proposal"
fi
has "$SCAFFOLD" 'fixtures/' "output structure names fixtures/"
has "$SCAFFOLD" '3\+' "POM threshold is 3+ reused interactions"
has "$SCAFFOLD" 'storageState' "auth fixture uses the storageState pattern"
if grep -Ei 'testid' "$SCAFFOLD" 2>/dev/null | grep -Eqi 'suggest'; then
  pass "scaffold.md suggests testids"
else
  bad "scaffold.md has no testID suggestion rule"
fi
if grep -Ei 'production code' "$SCAFFOLD" 2>/dev/null | grep -Eqi 'not|never'; then
  pass "scaffold.md never modifies production code to add testids"
else
  bad "scaffold.md does not forbid modifying production code for testids"
fi
# Locator policy has exactly ONE home. A scaffold line that talks about locators
# and testids in the same breath is a restated (and in V1, inverted) hierarchy.
hasnt "$SCAFFOLD" '[Ll]ocator[^|]*testid|testid[^|]*[Ll]ocator' "does not restate a testid-first locator order"
if grep -i 'locator' "$SCAFFOLD" 2>/dev/null | grep -Fq 'playwright-patterns.md'; then
  pass "scaffold.md defers locator priority to playwright-patterns.md"
else
  bad "scaffold.md does not defer locator priority to playwright-patterns.md"
fi

# ── (8b) live-validation.md: the three trust-the-name defects ───────────────
# All three came out of adversarial review of the first draft and share one
# root cause: treating a NAME, or a ONE-TIME check, as evidence about where
# mutating traffic actually lands.
#
#   FIX 1  a hostname regex is not a destination check -- `.test`/`.local`/
#          `.localhost` resolve through /etc/hosts, mDNS and internal DNS and
#          can point anywhere, production included (DNS rebinding likewise).
#   FIX 2  classification was one-shot: a redirect or SSO bounce moves the run
#          cross-origin and the mutation gate never re-evaluated.
#   FIX 3  one consent was doing two jobs -- DC-2 requires destructive consent
#          SEPARATE from the external-origin allowance.

# FIX 1 -- LOCAL is resolution-gated, not name-matched.
has "$LIVEVAL" 'resolve|resolution'          "LOCAL requires resolving the host, not matching its name"
has "$LIVEVAL" '127\.0\.0\.0/8'              "resolved address must fall in 127.0.0.0/8"
has "$LIVEVAL" 'link-local'                  "link-local named (see (8c): it must be named as a DENIAL, not an accepted range)"
if grep -Ei 'name|suffix|regex' "$LIVEVAL" 2>/dev/null \
   | grep -Eqi 'not evidence|insufficient|does not prove|is not a destination|never proof'; then
  pass "live-validation.md states plainly that a hostname is not evidence about the destination"
else
  bad "live-validation.md does not state that a matching hostname is insufficient evidence"
fi
has "$LIVEVAL" 'rebinding'                   "DNS rebinding named as the reason a name cannot be trusted"
has "$LIVEVAL" '/etc/hosts|mDNS'             "names the resolution paths (/etc/hosts, mDNS) that redirect a local-looking name"
if grep -Ei 'resolv' "$LIVEVAL" 2>/dev/null | grep -Eqi 'suffix|\.local|\.test|wildcard'; then
  pass "live-validation.md resolution-gates the wildcard suffixes (.local/.localhost/.test)"
else
  bad "live-validation.md does not resolution-gate the wildcard LOCAL suffixes"
fi
if grep -Ei 'EXTERNAL_UNKNOWN' "$LIVEVAL" 2>/dev/null | grep -Eqi 'regardless of|whatever the (name|suffix)|even if the name'; then
  pass "live-validation.md falls back to EXTERNAL_UNKNOWN regardless of the suffix when resolution fails"
else
  bad "live-validation.md does not force EXTERNAL_UNKNOWN when the resolved address is not loopback/link-local"
fi

# FIX 2 -- classification is continuous, and the gate reads the CURRENT origin.
has "$LIVEVAL" 're-?classif'                 "origin is re-classified, not classified once"
has "$LIVEVAL" 'current origin'              "the mutation gate reads the CURRENT origin"
if grep -Ei 'redirect' "$LIVEVAL" 2>/dev/null | grep -Eqi 're-?classif|every hop|each hop|current origin'; then
  pass "live-validation.md re-classifies across redirect chains"
else
  bad "live-validation.md does not re-classify redirect chains hop by hop"
fi
if grep -Ei 'navigat' "$LIVEVAL" 2>/dev/null | grep -Eqi 're-?classif|every navigation|each navigation'; then
  pass "live-validation.md re-classifies on every navigation"
else
  bad "live-validation.md does not re-classify on in-test navigation"
fi
if grep -Ei 'SSO|identity provider' "$LIVEVAL" 2>/dev/null | grep -Eqi 'bounce|redirect|cross-origin'; then
  pass "live-validation.md names the SSO-bounce case"
else
  bad "live-validation.md does not name the SSO / identity-provider bounce case"
fi
if grep -Ei 'fail loudly|fails loudly|hard failure' "$LIVEVAL" 2>/dev/null | grep -Eqi 'origin|block|transition'; then
  pass "live-validation.md fails loudly on a transition into EXTERNAL_UNKNOWN"
else
  bad "live-validation.md does not require a loud failure on an origin transition (silent read-only drift)"
fi

# FIX 3 -- two consents, and the four combinations pinned STRUCTURALLY.
has "$LIVEVAL" 'allow-destructive'           "the second consent has a named mechanism (--allow-destructive)"
if grep -Ei 'allow-external-origin' "$LIVEVAL" 2>/dev/null | grep -Eqi 'read-only'; then
  pass "live-validation.md limits --allow-external-origin to read-only flows"
else
  bad "live-validation.md lets --allow-external-origin grant mutations on its own (DC-2 violation)"
fi
# Structural, not keyword: the consent matrix must contain the row that proves
# external-allowed does NOT imply destructive-allowed.
consent_rows="$(awk -F'|' '/^\| *(yes|no) *\| *(yes|no) *\|/ {
  for (i = 2; i <= 5; i++) { v[i] = $i; gsub(/^[ \t]+|[ \t]+$/, "", v[i]); gsub(/[`*]/, "", v[i]) }
  printf "%s/%s/%s/%s\n", tolower(v[2]), tolower(v[3]), toupper(v[4]), toupper(v[5])
}' "$LIVEVAL" 2>/dev/null)"
row_n="$(printf '%s' "$consent_rows" | grep -c . || true)"
if [ "${row_n:-0}" -eq 4 ]; then
  pass "consent matrix has all four external x destructive combinations"
else
  bad "consent matrix has ${row_n:-0} yes/no rows (want exactly 4: external x destructive)"
fi
check_combo() { # check_combo <expected row> <human>
  if printf '%s\n' "$consent_rows" | grep -Fqx "$1"; then
    pass "consent matrix: $2"
  else
    bad "consent matrix missing row [$1] -- $2"
  fi
}
check_combo 'no/no/BLOCKED/BLOCKED'    'no consent at all blocks read-only and mutating alike'
check_combo 'no/yes/BLOCKED/BLOCKED'   'destructive consent without a permitted destination grants nothing'
check_combo 'yes/no/ALLOWED/BLOCKED'   'external allowed but destructive NOT consented still blocks mutations'
check_combo 'yes/yes/ALLOWED/ALLOWED'  'both consents given permits mutating flows'

# ── (8c) live-validation.md: what "loopback" actually means ────────────────
# Delta adversarial round on the (8b) revision. FIX A is the dangerous one and
# it came from the INSTRUCTION, not the draft: accepting link-local as LOCAL
# admits 169.254.169.254 -- the cloud instance metadata endpoint -- which would
# hand unrestricted mutating traffic to an SSRF target inside the very file
# whose job is to prevent that.
#
#   FIX A  LOCAL == loopback only. Link-local is DENIED, by name and by reason.
#   FIX B  host.docker.internal resolves to a bridge address on Docker Desktop,
#          so a listed-but-never-admissible entry had to be decided either way.
#   FIX C  fast-pathing `localhost` contradicted the file's own "names are not
#          evidence" thesis -- only literal IPs may skip resolution.
#   FIX D  re-resolution is TOCTOU-racy; the honest position is pre-flight
#          heuristic + request-level enforcement, not a fake guarantee.

# FIX A -- link-local is denied, and the metadata endpoint is the stated reason.
has "$LIVEVAL" '169\.254\.169\.254'   "names the instance metadata endpoint 169.254.169.254"
if grep -Ei '169\.254\.169\.254|link-local' "$LIVEVAL" 2>/dev/null | grep -Eqi 'metadata'; then
  pass "live-validation.md gives the metadata-endpoint reason for denying link-local"
else
  bad "live-validation.md denies link-local without naming the metadata-endpoint reason"
fi
# Structural: EVERY mention of a link-local range must carry a denial. An
# accepting mention is the exact regression this assertion exists to catch.
ll_bad=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '%s' "$line" | grep -Eqi 'not |never|deny|denied|exclude|refus|blocked|must not|no longer' \
    || ll_bad="$ll_bad [${line%%:*}]"
done < <(grep -Eni '169\.254\.0\.0/16|fe80::|169\.254\.169\.254' "$LIVEVAL" 2>/dev/null)
if [ -z "$ll_bad" ]; then
  pass "every link-local mention in live-validation.md is a denial"
else
  bad "link-local mentioned WITHOUT a denial at line(s):$ll_bad (accepting it admits 169.254.169.254)"
fi
if grep -Ei 'link-local' "$LIVEVAL" 2>/dev/null | grep -Eqi 'STAGING'; then
  pass "live-validation.md routes genuine link-local setups through STAGING"
else
  bad "live-validation.md does not send a real link-local dev host through the STAGING path"
fi
has "$LIVEVAL" 'loopback only|only loopback|means loopback' "LOCAL is defined as loopback ONLY"

# FIX B -- host.docker.internal is decided, not left dangling.
if grep -Ei 'host\.docker\.internal' "$LIVEVAL" 2>/dev/null | grep -Eqi 'only (if|when)|bridge|non-loopback|not loopback|dropped'; then
  pass "live-validation.md states the host.docker.internal decision (carve-out or drop)"
else
  bad "live-validation.md lists host.docker.internal without deciding whether the rule can ever admit it"
fi
has "$LIVEVAL" 'Docker Desktop' "names Docker Desktop as the environment where the bridge address applies"

# FIX C -- only literal IPs skip resolution; `localhost` is a name like any other.
if grep -Ei 'literal' "$LIVEVAL" 2>/dev/null | grep -Eqi 'only|no-resolution|nothing to resolve'; then
  pass "live-validation.md limits the no-resolution fast path to literal IP forms"
else
  bad "live-validation.md does not restrict the fast path to literal IP addresses"
fi
if grep -Ei 'localhost' "$LIVEVAL" 2>/dev/null | grep -Eqi 'resolved like|resolve it|is resolved|no free pass|/etc/hosts'; then
  pass "live-validation.md resolves (or explicitly justifies) localhost instead of trusting the name"
else
  bad "live-validation.md fast-paths localhost with no rationale -- contradicts its own thesis"
fi

# FIX D -- TOCTOU stated as a limit, with the real enforcement layer named.
has "$LIVEVAL" 'TOCTOU|time-of-check' "names the TOCTOU race between resolution and connection"
if grep -Ei 'pre-flight|preflight heuristic|heuristic' "$LIVEVAL" 2>/dev/null | grep -Eqi 'resolution|resolve'; then
  pass "live-validation.md calls resolution a pre-flight heuristic, not a guarantee"
else
  bad "live-validation.md presents resolution as airtight (no pre-flight/heuristic framing)"
fi
if grep -Ei 'request-level|request level' "$LIVEVAL" 2>/dev/null | grep -Eqi 'enforce|enforcement'; then
  pass "live-validation.md names request-level checking as the actual enforcement layer"
else
  bad "live-validation.md does not position request-level checking as the enforcement layer"
fi
if grep -Ei 'browser' "$LIVEVAL" 2>/dev/null | grep -Eqi 'cache|caches'; then
  pass "live-validation.md names the browser's own DNS cache as part of the residual risk"
else
  bad "live-validation.md omits the browser DNS cache from the TOCTOU limitation"
fi
if grep -Ei 'E2E-Q4' "$LIVEVAL" 2>/dev/null | grep -Fq 'network-mocking.md'; then
  pass "live-validation.md points the enforcement layer at network-mocking.md (E2E-Q4)"
else
  bad "live-validation.md does not cite network-mocking.md / E2E-Q4 as the enforcement layer"
fi

# ── (12) SKILL.md V2 contract ───────────────────────────────────────────────
# The reference files above only matter if SKILL.md actually POINTS at them. V1
# carried the same material inline (507 lines) and drifted from it; the size
# bound is the mechanical guard against that material creeping back.
SKILL="$ROOT/skills/write-e2e/SKILL.md"
if [ ! -f "$SKILL" ]; then
  bad "missing: skills/write-e2e/SKILL.md"
else
  # Body of a '## <heading>' up to the next '## ' (heading line excluded).
  sk_section() { awk -v pat="$1" '$0 ~ pat {f=1; next} f && /^## /{f=0} f' "$SKILL"; }

  # (12a) size bound, BOTH ends. Below the floor the phase skeleton cannot name
  # the states and gates it must; above the cap the references are being
  # restated inline. Cap raised 250→280 on 2026-07-31: the file shipped at 271
  # (already over) and the bootstrap-and-run policy + --no-install + WARN
  # ceiling landed on top; the correct fix at the next touch is trimming
  # restated prose, not another cap bump.
  #
  # 2026-08-02: the bound now measures the BODY, not the whole file. It was a
  # whole-file count (180..280) until the mandatory `category:` frontmatter key
  # pushed this file from exactly 280 to 281 — a schema key, not restated
  # prose, so paying for it by deleting documentation would have been backwards,
  # and bumping the cap by one would have re-run this argument at the next
  # mandatory key. Frontmatter is structural and must not consume the prose
  # budget. Bounds are the old ones minus the frontmatter block that existed
  # when they were set (46 lines here), so the anti-bloat intent is unchanged:
  # both bounds derive from the 45-line frontmatter those commits actually
  # had (e1359a8 set the floor, 4bb92f0 the cap): 180-45=135, 280-45=235.
  # Locating the closing fence needs care: 54 of the 57 SKILL.md files use a
  # bare `---` as a BODY separator too. Taking "the first `---` after line 1"
  # would silently accept a body rule as the fence whenever the real closing
  # fence went missing, and the truncated body count lands inside the passing
  # window — a false PASS, with the guard below never firing. So: line 1 must
  # open the block, and every line before the closing fence must be
  # frontmatter-shaped (`key:`, an indented continuation, a comment, or blank).
  # The first line that is not disqualifies the candidate and reports the
  # missing fence instead of guessing.
  sk_fm_end="$(awk '
    { sub(/\r$/, "") }                     # CRLF: a \r would defeat every anchor below
    NR==1 { if ($0 !~ /^---[[:space:]]*$/) exit; next }
    NR > 120 { exit }                      # bounded: no real frontmatter runs this long
    /^---[[:space:]]*$/ { print NR; exit }
    /^#{1,6}[[:space:]]/      { exit }     # a markdown heading is BODY, never a YAML comment
    /^[A-Za-z_][A-Za-z0-9_.-]*:/ { next }  # a frontmatter key (dots and digits allowed)
    /^[[:space:]]/            { next }     # an indented continuation / list item
    /^[[:space:]]*#/          { next }     # a YAML comment
    /^[[:space:]]*$/          { next }     # a blank line
    { exit }                               # anything else: the block ended without a fence
  ' "$SKILL")"
  sk_total="$(wc -l < "$SKILL" | tr -d ' ')"
  if [ -z "$sk_fm_end" ]; then
    # Do NOT fall through to the size check with a 0 fallback: on a file whose
    # TOTAL happens to land inside the window that prints `FAIL: no closing
    # fence` immediately followed by `PASS: body is N lines` — the same false
    # PASS this block exists to prevent, one branch further down.
    bad "SKILL.md has no closing frontmatter fence (or line 1 does not open one) -- body size not checked"
  # Cap raised 235 -> 245 on 2026-08-10, deliberately and for one reason: the
  # dispatch-authorization rule became mandatory in every skill that delegates
  # (all 47 of them; see test-gate-dispatch-authorization.sh). This file sat at
  # exactly 235, so it could absorb nothing, and the two alternatives were both
  # worse — delete documentation to pay for a safety rule, which the reasoning
  # above already rejects for mandatory additions, or give this one skill a
  # shorter variant of a rule whose whole point is being identical everywhere.
  # The anti-bloat intent is unchanged: 245 is the old cap plus the rule, not
  # headroom for prose.
  elif [ "$(( sk_total - sk_fm_end ))" -ge 135 ] && [ "$(( sk_total - sk_fm_end ))" -le 245 ]; then
    pass "SKILL.md body is $(( sk_total - sk_fm_end )) lines (within 135..245; frontmatter $sk_fm_end excluded)"
  else
    bad "SKILL.md body is $(( sk_total - sk_fm_end )) lines -- want 135..245 (total $sk_total, frontmatter $sk_fm_end)"
  fi

  # (12b) the V2 argument grammar, plus the positional alias the website page and
  # existing users depend on -- kept, but marked deprecated so it can eventually go.
  ARGS="$(sk_section '^## Argument Parsing')"
  if [ -z "$ARGS" ]; then
    bad "SKILL.md has no '## Argument Parsing' section"
  else
    for a in '--scope <path>' '--flow <name>' '--output <dir>' '--base-url <url>' '--max-flows N'; do
      if printf '%s\n' "$ARGS" | grep -Fq -- "$a"; then
        pass "Argument Parsing documents \`$a\`"
      else
        bad "Argument Parsing does not document \`$a\`"
      fi
    done
    for a in '--live' '--auto' '--flows' '--dry-run'; do
      printf '%s\n' "$ARGS" | grep -Fq -- "$a" \
        && pass "Argument Parsing retains \`$a\`" \
        || bad "Argument Parsing lost \`$a\`"
    done
    if printf '%s\n' "$ARGS" | grep -F '[path]' | grep -Eqi 'deprecat'; then
      pass "Argument Parsing keeps '[path]' with a deprecation note"
    else
      bad "Argument Parsing drops '[path]' or does not mark it deprecated (website page + users depend on it)"
    fi
    if printf '%s\n' "$ARGS" | grep -F '[path]' | grep -Fq -- '--scope'; then
      pass "'[path]' is documented as an alias for --scope"
    else
      bad "'[path]' is not tied to --scope as an alias"
    fi
  fi

  # (12c) scale defaults 1 / 3 / 20-only-explicit. V1 defaulted MAX_FLOWS to 20 and
  # Codex+Cursor force --auto, so V1 could emit 20 specs with nobody deciding to.
  if printf '%s\n' "$ARGS" | grep -Ei 'scope|flow <name>|named' | grep -qE '\| *1 *\|'; then
    pass "scale default: a scoped/named request generates 1 flow"
  else
    bad "scale default for a scoped/named request (1 flow) not stated in Argument Parsing"
  fi
  if printf '%s\n' "$ARGS" | grep -F -- '--auto' | grep -qE '\| *3 *\|'; then
    pass "scale default: bare --auto generates 3 flows"
  else
    bad "scale default for bare --auto (3 flows) not stated in Argument Parsing"
  fi
  if printf '%s\n' "$ARGS" | grep -F -- '--max-flows' | grep -Fq '20'; then
    pass "scale default: 20 flows only via --flows / an explicit --max-flows 20"
  else
    bad "Argument Parsing does not tie 20 flows to an explicit --max-flows / --flows request"
  fi
  hasnt "$SKILL" 'MAX_FLOWS *= *20|\(default: *20\)|default: *`?20' "carries no 20-flow default"

  # (12d) origin classes and the verification states are named in the phase
  # skeleton itself -- a bare 'LOCAL' is already satisfied by VERIFIED_LOCAL, so
  # the three origin classes must appear together on one line.
  if grep -Eq 'Origin:.*LOCAL.*STAGING.*EXTERNAL_UNKNOWN' "$SKILL"; then
    pass "SKILL.md names all three origin classes on one 'Origin:' line"
  else
    bad "SKILL.md has no 'Origin: LOCAL | STAGING | EXTERNAL_UNKNOWN' line in the phase skeleton"
  fi
  for st in GENERATED STATIC_CHECKED VERIFIED_LOCAL VALIDATED_LIVE BLOCKED FAILED; do
    grep -Fq "$st" "$SKILL" \
      && pass "SKILL.md names validation state $st" \
      || bad "SKILL.md does not name validation state $st"
  done

  # (12e) the six references are listed in Mandatory File Loading WITH a per-phase
  # trigger -- lazy loading is the point; six files loaded at start is the old cost.
  MFL="$(sk_section '^## Mandatory File Loading')"
  if [ -z "$MFL" ]; then
    bad "SKILL.md has no '## Mandatory File Loading' section"
  else
    for r in quality-gates playwright-patterns network-mocking discovery-and-scoring scaffold live-validation; do
      line="$(printf '%s\n' "$MFL" | grep -F "references/$r.md" | head -1)"
      if [ -z "$line" ]; then
        bad "Mandatory File Loading does not list references/$r.md"
      elif printf '%s' "$line" | grep -Eqi 'phase'; then
        pass "Mandatory File Loading lists references/$r.md with a per-phase trigger"
      else
        bad "references/$r.md is listed without a per-phase load trigger"
      fi
    done
    if printf '%s\n' "$MFL" | grep -Eqi 'lazy|when its phase|not at start|not all at start'; then
      pass "Mandatory File Loading states the references are loaded lazily"
    else
      bad "Mandatory File Loading does not say the references load per-phase rather than all at start"
    fi
  fi

  # (12f) preflight is asked, never guessed -- and the helper-absent fallback names
  # all three states on its own line (a Codex/Cursor-only install has no helper).
  if grep -Fq '~/.zuvo/e2e-preflight' "$SKILL" && grep -Fq 'probe' "$SKILL"; then
    pass "SKILL.md invokes ~/.zuvo/e2e-preflight probe"
  else
    bad "SKILL.md does not invoke '~/.zuvo/e2e-preflight probe'"
  fi
  if grep -E 'READY.*GENERATE_ONLY.*BOOTSTRAP_REQUIRED' "$SKILL" | grep -Eqi 'absent|missing|fallback'; then
    pass "helper-absent fallback line names all three preflight states"
  else
    bad "SKILL.md has no helper-absent fallback line naming READY/GENERATE_ONLY/BOOTSTRAP_REQUIRED together"
  fi
  # (2026-07-31 policy flip, user feedback "czemu nie testują swojej roboty?"):
  # BOOTSTRAP_REQUIRED now bootstraps the project's OWN declared deps and runs the
  # tests; what stays forbidden is changing the dependency set (lockfile mutation,
  # adding/upgrading, unpinned npx). An unexecuted run caps its verdict at WARN.
  if grep -Ei 'BOOTSTRAP_REQUIRED' "$SKILL" | grep -Eqi 'bootstrap it and run|Bootstrap the project'; then
    pass "BOOTSTRAP_REQUIRED bootstraps declared deps and runs the tests (not ship-untested)"
  else
    bad "SKILL.md BOOTSTRAP_REQUIRED does not bootstrap-and-run"
  fi
  if grep -Ei 'never add or upgrade a dependency|never mutate a lockfile' "$SKILL" >/dev/null; then
    pass "bootstrap hard limits: no dependency changes, no lockfile mutation"
  else
    bad "SKILL.md bootstrap policy lacks the no-dependency-change / no-lockfile-mutation limits"
  fi
  if grep -Ei -- '--no-install|ZUVO_E2E_NO_BOOTSTRAP' "$SKILL" >/dev/null \
     && grep -Ei 'VERDICT at WARN|at most \*\*WARN\*\*|verdict WARN' "$SKILL" >/dev/null; then
    pass "no-install opt-out exists and an unexecuted run caps its verdict at WARN"
  else
    bad "SKILL.md lacks the --no-install opt-out or the WARN verdict ceiling for unexecuted runs"
  fi
  if grep -Ei 'GENERATE_ONLY' "$SKILL" | grep -Fq 'STATIC_CHECKED'; then
    pass "GENERATE_ONLY caps the run at STATIC_CHECKED"
  else
    bad "SKILL.md does not cap a GENERATE_ONLY run at STATIC_CHECKED"
  fi

  # (12g) adversarial block: the Task-2 canonical shape, with PATH args.
  if grep -qE -- '\|\| _prc=\$\?' "$SKILL" && ! grep -qE -- '\); _prc=\$\?' "$SKILL"; then
    pass "adversarial block captures rc set -e-safely (|| _prc=\$?)"
  else
    bad "adversarial block is not the canonical safe capture (|| _prc=\$?)"
  fi
  grep -Fq 'skipped (no changes)' "$SKILL" \
    && pass "adversarial block handles exit 3 (skipped (no changes))" \
    || bad "adversarial block has no exit-3 branch"
  if grep -qE -- '_prc" -ne 0.*BLOCKED.*; false$' "$SKILL"; then
    pass "adversarial BLOCKED branch ends non-zero (false)"
  else
    bad "adversarial BLOCKED branch prints but returns 0"
  fi
  grep -Fq -- '--files' "$SKILL" \
    && pass "adversarial block keeps the --files fallback" \
    || bad "adversarial block lost the --files fallback"
  if grep -E 'build-review-patch"? "' "$SKILL" | grep -Eqi 'spec|fixture'; then
    pass "adversarial block passes PATH args (the specs/fixtures this run wrote)"
  else
    bad "adversarial block calls the helper with no scoped PATH args"
  fi

  # (12h) frontmatter shape -- installs and routing read these keys.
  fm="$(awk 'NR==1 && /^---/{f=1; next} f && /^---[[:space:]]*$/{exit} f' "$SKILL")"
  for k in name description codesift_tools; do
    if printf '%s\n' "$fm" | grep -Eq "^$k:"; then
      pass "frontmatter keeps key '$k'"
    else
      bad "frontmatter lost key '$k' (installs/routing depend on it)"
    fi
  done

  # (12i) the conflation bug itself: one string that meant BOTH "no --live" and
  # "no MCP", so a runnable local Playwright reported nothing verified.
  hasnt "$SKILL" 'VALIDATION SKIPPED' "no 'VALIDATION SKIPPED' conflation string"

  # V1's testid-first locator order and testid-gated HIGH confidence both live in
  # references/ now (as their negation); a restated copy here re-creates the drift.
  hasnt "$SKILL" '[Ll]ocator[^|]*testid|testid[^|]*[Ll]ocator' "does not restate a testid-first locator order"
  hasnt "$SKILL" 'HIGH[^|]*testid' "does not make HIGH confidence require a testid"

  # (12j) the codex/cursor builds sed on these literal tokens.
  ROUTING="$(sk_section '^## Agent Routing')"
  for tok in Sonnet Explore; do
    if printf '%s\n' "$ROUTING" | grep -Fq "$tok"; then
      pass "Agent Routing keeps the literal '$tok' form the platform builds recognize"
    else
      bad "Agent Routing lost the literal '$tok' form (platform build sed would miss it)"
    fi
  done

  # (12k) completion + run-logger wrapper (validate-skills reads these too).
  grep -Fq 'WRITE-E2E COMPLETE' "$SKILL" \
    && pass "named completion block 'WRITE-E2E COMPLETE' retained" \
    || bad "named completion block missing"
  grep -Fq 'COMPLETION GATE CHECK' "$SKILL" \
    && pass "completion gate check retained" \
    || bad "completion gate check missing"
  grep -Fq 'run-logger.md' "$SKILL" \
    && pass "run-logger.md include referenced" \
    || bad "run-logger.md include reference missing (validate-skills ERROR)"
  grep -Fq '~/.zuvo/append-runlog' "$SKILL" \
    && pass "run log appended through the append-runlog wrapper" \
    || bad "run log is not appended through the append-runlog wrapper"

  # (12l) the coverage registry contract the reference defines.
  if grep -Fq 'memory/e2e-coverage.md' "$SKILL" && grep -Fq 'coverage-upsert' "$SKILL"; then
    pass "artifact contract names memory/e2e-coverage.md and the coverage-upsert helper"
  else
    bad "artifact contract does not name memory/e2e-coverage.md + coverage-upsert"
  fi
  if grep -Ei 'State' "$SKILL" | grep -Fq '| Flow ID |'; then
    pass "coverage registry row shape carries the State column"
  else
    bad "coverage registry row shape in SKILL.md has no State column"
  fi

  # ── (12m) the origin gate is UNCONDITIONAL, not flag-scoped ────────────────
  # The P0, reached through the default door: a run with no --live and no
  # --base-url still executes, and `playwright test` then takes its baseURL from
  # the PROJECT's playwright.config -- which can point at staging or production.
  # A gate advertised as "--live only" protects the explicit path and leaves the
  # implicit one, the one most runs take, wide open.
  oh="$(grep -E '^## Phase 0\.5' "$SKILL" | head -1)"
  if [ -z "$oh" ]; then
    bad "SKILL.md has no '## Phase 0.5' origin-gate heading"
  elif printf '%s' "$oh" | grep -Eqi 'only'; then
    bad "origin-gate heading scopes the phase to flags -- default runs skip it: $oh"
  else
    pass "origin-gate heading is not flag-scoped"
  fi
  ORG="$(sk_section '^## Phase 0\.5')"
  if printf '%s\n' "$ORG" | grep -Eqi 'playwright\.config'; then
    pass "origin gate resolves the effective baseURL from the project's playwright config"
  else
    bad "origin gate never resolves the baseURL from the project's playwright.config (default-path hole)"
  fi
  if printf '%s\n' "$ORG" | grep -Eqi 'every run that executes|flagless|before anything executes|any execution'; then
    pass "origin gate applies to every executing run, flags or not"
  else
    bad "origin gate does not state that it covers flagless runs"
  fi
  if printf '%s\n' "$ORG" | grep -Fq 'BLOCK' && printf '%s\n' "$ORG" | grep -Fq -- '--allow-destructive'; then
    pass "a non-LOCAL resolved origin takes the consent path or BLOCKS"
  else
    bad "origin gate does not route a non-LOCAL resolved baseURL through consent-or-BLOCK"
  fi
  # Structural: parse the VERIFIED_LOCAL row and read its PRECONDITION cell. Prose
  # elsewhere claiming "against a LOCAL origin" is a description, not a gate --
  # the requirement column is what a reader treats as the condition to satisfy.
  vl="$(awk -F'|' '/^\| VERIFIED_LOCAL /{v=$4; gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit}' "$SKILL")"
  if [ -z "$vl" ]; then
    bad "no '| VERIFIED_LOCAL |' row in the verification ladder"
  elif printf '%s' "$vl" | grep -Fq 'LOCAL' \
       && printf '%s' "$vl" | grep -Eqi 'classif|resolved|base ?url|phase 0\.5'; then
    pass "VERIFIED_LOCAL requires the resolved baseURL to classify LOCAL"
  else
    bad "VERIFIED_LOCAL precondition cell does not require an origin classification: [$vl]"
  fi
  cg="$(grep -E '^\[ \].*[Oo]rigin' "$SKILL" | head -1)"
  if [ -z "$cg" ]; then
    bad "completion gate has no origin line"
  elif printf '%s' "$cg" | grep -Eqi 'execut' && ! printf '%s' "$cg" | grep -Eqi 'whenever --live|only when'; then
    pass "completion gate asserts the origin was classified for every executing run"
  else
    bad "completion gate conditions the origin check on flags: $cg"
  fi

  # ── (12n) the coverage-registry contract is internally consistent ──────────
  # Phase 0 documents a helper-absent fallback, so a Codex-only / Cursor-only
  # install genuinely has no ~/.zuvo/e2e-preflight. "Helper only, never by hand"
  # plus a completion gate that hard-requires the upsert makes the skill's own
  # gate unsatisfiable on those hosts.
  AC="$(sk_section '^## Artifact Contract')"
  if printf '%s\n' "$AC" | grep -Eqi 'absent|missing'; then
    pass "artifact contract names the helper-absent install"
  else
    bad "artifact contract ignores the helper-absent install documented in Phase 0"
  fi
  if printf '%s\n' "$AC" | grep -Ei 'by hand|hand-writ' | grep -Eqi 'shape|format|exact'; then
    pass "artifact contract documents the exact row shape for the hand-written path"
  else
    bad "artifact contract gives no machine-readable row shape for the helper-absent path"
  fi
  if printf '%s\n' "$AC" | grep -Eqi 'never by hand|never hand-'; then
    bad "artifact contract forbids hand-written rows outright, contradicting the Phase 0 fallback"
  else
    pass "artifact contract does not forbid the documented hand-written path"
  fi
  reg="$(grep -E '^\[ \].*e2e-coverage' "$SKILL" | head -1)"
  if [ -z "$reg" ]; then
    bad "completion gate has no coverage-registry line"
  elif printf '%s' "$reg" | grep -Eqi 'hand'; then
    pass "completion gate is satisfiable when the helper is absent"
  else
    bad "completion gate hard-requires a helper a Codex/Cursor-only install lacks: $reg"
  fi

  # ── (12o) the ladder pairs each STATE with ITS requirement, keyed by name ──
  # (12d) only proves the six tokens exist somewhere in the file. Swap two rows of
  # the Phase 4 table — VERIFIED_LOCAL demanding MCP, VALIDATED_LIVE demanding
  # nothing — and every assertion above stays green while the exact MCP/local
  # conflation this rewrite removed is silently restored. Key on the state NAME,
  # never a row index, so reordering the ladder cannot break the assertion.
  ladder_req() { # ladder_req <STATE> -> that row's Requires cell
    awk -F'|' -v st="$1" '$0 ~ "^\\| " st " \\|" { v = $4; gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }' "$SKILL"
  }
  for st in GENERATED STATIC_CHECKED VERIFIED_LOCAL VALIDATED_LIVE BLOCKED FAILED; do
    if [ -n "$(ladder_req "$st")" ]; then
      pass "verification ladder has a row for $st"
    else
      bad "verification ladder has no row for $st (the state is named in prose only)"
    fi
  done
  vlr="$(ladder_req VERIFIED_LOCAL)"
  if printf '%s' "$vlr" | grep -Eqi 'READY'; then
    pass "VERIFIED_LOCAL's requirement cell names preflight READY"
  else
    bad "VERIFIED_LOCAL requirement cell does not name preflight READY: [$vlr]"
  fi
  # "no MCP" is a denial, not a requirement — accept a negated mention, reject a demand.
  if ! printf '%s' "$vlr" | grep -Fq 'MCP' || printf '%s' "$vlr" | grep -Eqi 'no MCP|without MCP|not required'; then
    pass "VERIFIED_LOCAL does not require MCP (local execution stays decoupled)"
  else
    bad "VERIFIED_LOCAL requirement cell demands MCP — the V1 conflation is back: [$vlr]"
  fi
  lvr="$(ladder_req VALIDATED_LIVE)"
  lmiss=""
  printf '%s' "$lvr" | grep -Fq -- '--live'          || lmiss="$lmiss --live"
  printf '%s' "$lvr" | grep -Fq 'MCP'                || lmiss="$lmiss MCP"
  printf '%s' "$lvr" | grep -Eqi 'origin|phase 0\.5' || lmiss="$lmiss origin-gate"
  if [ -z "$lmiss" ]; then
    pass "VALIDATED_LIVE requires --live AND MCP AND the origin gate"
  else
    bad "VALIDATED_LIVE requirement cell is missing:$lmiss — [$lvr]"
  fi

  # ── (12p) codesift_tools.always must stay a BLOCK list ────────────────────
  # scripts/zuvo-home/compute-preload parses `always:` as a block list of `- item`
  # lines. A flow-style `always: [a, b]` is valid YAML, looks fine in review, and
  # parses to an EMPTY list there — CodeSift preload then dies for every
  # write-e2e run with no error anywhere. Asserting the KEY exists tests nothing;
  # this runs the real consumer's parser over this very file.
  cp_n="$(python3 - "$ROOT" <<'PY' 2>/dev/null
import importlib.machinery, importlib.util, pathlib, sys
root = pathlib.Path(sys.argv[1])
loader = importlib.machinery.SourceFileLoader("cp", str(root / "scripts/zuvo-home/compute-preload"))
spec = importlib.util.spec_from_loader("cp", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)          # __main__-guarded, so nothing runs on import
ct = mod.parse_codesift_tools(mod.read_frontmatter(root / "skills/write-e2e/SKILL.md"))
print(len(ct["always"]))
PY
)"
  if [ -z "$cp_n" ]; then
    bad "compute-preload's parser could not read SKILL.md frontmatter at all"
  elif [ "$cp_n" -ge 1 ] 2>/dev/null; then
    pass "compute-preload parses $cp_n codesift_tools.always entries from SKILL.md"
  else
    bad "compute-preload reads codesift_tools.always as EMPTY ($cp_n) — a flow-style list kills CodeSift preload silently"
  fi
  # Same invariant asserted on the text, so the failure names the cause directly.
  if awk '/^  always:[ \t]*$/ { f = 1; next } f && /^    - / { c++ } f && /^  [A-Za-z_]/ { exit } END { exit !(c > 0) }' "$SKILL"; then
    pass "codesift_tools.always is a block list ('- item' lines), not flow style"
  else
    bad "codesift_tools.always is not a block list — compute-preload would read it as empty"
  fi
fi

# ── (11) no Claude-only tool tokens in the second trio ──────────────────────
hits2="$(grep -REn "$TOKENS" "$DISCOVERY" "$SCAFFOLD" "$LIVEVAL" 2>/dev/null || true)"
if [ -z "$hits2" ]; then
  pass "no Claude-only tool tokens in discovery-and-scoring / scaffold / live-validation"
else
  bad "Claude-only tool token(s) in the second reference trio: $hits2"
fi

# ── (12) E2E-Q registered BY REFERENCE in the gate registry ─────────────────
# The E2E-Q family is NOT a parsed registry family. scripts/gen-gate-copies.py's
# parse_registry matches rows shaped `^\s*\|\s*(CQ|CAP|AP|Q)(\d+)\s*\|(.*)\|\s*$`
# and enforces strict duplicate-ID + 1..N contiguity per family, so a row written
# `| Q1 | ... |` inside an E2E section would be absorbed by the REAL Q family and
# either duplicate Q1 or break contiguity — a build failure with a misleading
# message. Registration is therefore by REFERENCE: gate-registry.md points at the
# authoritative table and re-states only the ID -> invariant mapping, in a shape
# the row regex cannot match.
REGISTRY="$ROOT/shared/includes/gate-registry.md"
CLAUDEMD="$ROOT/CLAUDE.md"
SITEYAML="$ROOT/website/skills/write-e2e.yaml"
AUTH_REL="skills/write-e2e/references/quality-gates.md"

if [ ! -f "$REGISTRY" ]; then
  bad "missing: shared/includes/gate-registry.md"
else
  # (12a) the registry names the AUTHORITATIVE file by its full path. A bare
  # 'quality-gates.md' grep would false-pass on the registry's existing mentions
  # of shared/includes/quality-gates.md, which is a different file.
  if grep -Fq "$AUTH_REL" "$REGISTRY"; then
    pass "gate-registry.md names $AUTH_REL as the authoritative E2E-Q definition"
  else
    bad "gate-registry.md does not name $AUTH_REL — E2E-Q is not registered anywhere"
  fi

  # (12a2) THE assertion that gives "registered by reference" its teeth. Every
  # other check in this section reads gate-registry.md only, so they all pass on a
  # registration that points at nothing: delete the authoritative file, rename it,
  # or re-point the pointer at a path that does not exist, and (12a)-(12e) stay
  # green while the "definition" the registry defers to is gone. This check follows
  # the pointer OUT of the registry -- it extracts every path the registry calls
  # authoritative, resolves it on disk, and re-derives the ten IDs, the shared
  # invariant map and the criticality claim from the file that was actually found.
  auth_out="$(python3 - "$REGISTRY" "$ROOT" "$AUTH_REL" "$E2E_LIB" <<'PY' 2>&1
import pathlib, re, sys

reg_path, root, auth_rel, lib = sys.argv[1:5]
ns = {}
exec(compile(open(lib, encoding="utf-8").read(), lib, "exec"), ns)
INVARIANT = ns["INVARIANT"]

registry = open(reg_path, encoding="utf-8", errors="replace").read()

# Every "authoritative(ly) ... `<something>.md`" claim the registry makes, in the
# order it makes them. A claim that does not resolve on disk is a dead pointer.
ptrs = sorted(set(re.findall(r'[Aa]uthoritativ\w*[^`\n]*`([^`\n]+\.md)`', registry)))
gaps = []
if not ptrs:
    gaps.append("no-authoritative-pointer")
for p in ptrs:
    if not (pathlib.Path(root) / p).is_file():
        gaps.append("unresolved:" + p)
if auth_rel not in ptrs:
    gaps.append("pointer-is-not-" + auth_rel)
print("PTR=%s" % (",".join(gaps) if gaps else "none"))

target = pathlib.Path(root) / auth_rel
if not target.is_file():
    print("MAP=NOFILE")
    print("CRIT=NOFILE")
    sys.exit(0)
body = target.read_text(encoding="utf-8", errors="replace")

# rows[n] = list of cell lists, so a duplicated ID is a failure and not a silent
# first-match win.
rows = {}
for ln in body.split("\n"):
    m = re.match(r'^\|\s*E2E-Q(\d+)\s*\|(.*)$', ln)
    if m:
        rows.setdefault(int(m.group(1)), []).append(
            [c.strip() for c in m.group(2).split("|")])

mapgap = []
for n, pat in sorted(INVARIANT.items()):
    got = rows.get(n)
    if not got:
        mapgap.append("E2E-Q%d:no-row" % n)
    elif len(got) > 1:
        mapgap.append("E2E-Q%d:duplicate-row" % n)
    elif not re.search(pat, got[0][0], re.I):
        mapgap.append("E2E-Q%d:invariant" % n)
mapgap += ["E2E-Q%d:undeclared" % n for n in sorted(rows) if n not in INVARIANT]
print("MAP=%s" % (",".join(mapgap) if mapgap else "none"))

# Criticality, from the same file: the Critical column of every row AND the prose
# claim the registry repeats. Column 2 of the row body is "Critical".
critgap = []
for n, got in sorted(rows.items()):
    cell = got[0][1] if len(got[0]) > 1 else "?"
    if cell.strip().lower() != "yes":
        critgap.append("E2E-Q%d:%s" % (n, cell or "empty"))
if not re.search(r'(all ten|all 10|every gate)[^.\n]*critical', body, re.I):
    critgap.append("no-criticality-statement")
print("CRIT=%s" % (",".join(critgap) if critgap else "none"))
PY
)"
  auth_ptr="$(printf '%s\n' "$auth_out" | sed -n 's/^PTR=//p')"
  auth_map="$(printf '%s\n' "$auth_out" | sed -n 's/^MAP=//p')"
  auth_crit="$(printf '%s\n' "$auth_out" | sed -n 's/^CRIT=//p')"
  if [ -z "$auth_ptr$auth_map$auth_crit" ]; then
    bad "authoritative-target check produced no verdict: $(printf '%s' "$auth_out" | tr '\n' ' ')"
  else
    if [ "$auth_ptr" = "none" ]; then
      pass "every 'authoritative' pointer in gate-registry.md resolves to a file on disk"
    else
      bad "gate-registry.md's authoritative pointer is dead or wrong: $auth_ptr"
    fi
    if [ "$auth_map" = "none" ]; then
      pass "$AUTH_REL defines E2E-Q1..E2E-Q10, one row each, matching the shared invariant map"
    else
      bad "the file gate-registry.md points at does not define the registered gates: $auth_map"
    fi
    if [ "$auth_crit" = "none" ]; then
      pass "$AUTH_REL marks every E2E-Q row critical and states it in prose (matches the registry's claim)"
    else
      bad "criticality drift between the registry's claim and the authoritative file: $auth_crit"
    fi
  fi

  # (12b) all ten IDs present. The trailing `([^0-9]|$)` is load-bearing: a bare
  # substring grep for `E2E-Q1` also matches inside `E2E-Q10`, so deleting the
  # E2E-Q1 row would leave this assertion green (verified by mutation).
  e2e_missing=""
  for n in 1 2 3 4 5 6 7 8 9 10; do
    grep -Eq "E2E-Q${n}([^0-9]|\$)" "$REGISTRY" || e2e_missing="$e2e_missing E2E-Q${n}"
  done
  if [ -z "$e2e_missing" ]; then
    pass "gate-registry.md lists E2E-Q1 through E2E-Q10"
  else
    bad "gate-registry.md is missing E2E gate id(s):$e2e_missing"
  fi

  # (12c) criticality summary — all ten are critical, stated in the registry.
  if grep -Eqi 'all (ten|10)[^.]*critical|ten[^.]*are critical' "$REGISTRY"; then
    pass "gate-registry.md states that all ten E2E-Q gates are critical"
  else
    bad "gate-registry.md does not state the E2E-Q criticality summary (all ten critical)"
  fi

  # (12d) the ID -> invariant pairing matches the V2 mapping used everywhere else
  #       in this suite, AND (12e) not one line of the E2E section is parseable as
  #       a registry gate row. Both run over the SECTION, extracted by heading, so
  #       a stray E2E mention elsewhere in the file cannot satisfy them.
  e2e_out="$(python3 - "$REGISTRY" "$E2E_LIB" <<'PY' 2>&1
import re, sys

ns = {}
exec(compile(open(sys.argv[2], encoding="utf-8").read(), sys.argv[2], "exec"), ns)
INVARIANT = ns["INVARIANT"]

text = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")

start = None
for i, line in enumerate(text):
    if line.startswith("## ") and "E2E-Q" in line:
        start = i
        break
if start is None:
    print("NOSECTION")
    sys.exit(0)
end = len(text)
for j in range(start + 1, len(text)):
    if text[j].startswith("## "):
        end = j
        break
section = text[start:end]

# EXACT copy of the row regex in scripts/gen-gate-copies.py :: parse_registry.
ROW = re.compile(r'^\s*\|\s*(CQ|CAP|AP|Q)(\d+)\s*\|(.*)\|\s*$')
collide = [f"{start + k + 1}:{ln}" for k, ln in enumerate(section) if ROW.match(ln.rstrip())]

# The mapping is read off the TABLE ROWS, keyed by ID -- never off the first
# textual mention. A `re.search` over the section body is satisfied by a sentence
# of prose, so deleting a row and describing the gate in a paragraph instead used
# to keep this green; and with ten IDs in one blob the first match for E2E-Q1 can
# land inside a neighbouring row. Rows first, then the mapping over the invariant
# cell of each row.
# (No apostrophes in any of these heredocs on purpose: bash 3.2 tracks quote state
# while it scans a heredoc nested inside $( ), so a lone apostrophe in a comment
# swallows the rest of the file and the script dies with an EOF syntax error.)
rows = {}
for k, ln in enumerate(section):
    m = re.match(r'^\|\s*E2E-Q(\d+)\s*\|(.*)$', ln)
    if m:
        rows.setdefault(int(m.group(1)), []).append(
            [c.strip() for c in m.group(2).split("|")])

rowgap = []
for n in sorted(INVARIANT):
    got = rows.get(n)
    if not got:
        rowgap.append("E2E-Q%d:no-row" % n)
    elif len(got) > 1:
        rowgap.append("E2E-Q%d:duplicate-row" % n)
rowgap += ["E2E-Q%d:undeclared" % n for n in sorted(rows) if n not in INVARIANT]

missing = []
for n, pat in sorted(INVARIANT.items()):
    got = rows.get(n)
    if not got:
        missing.append(f"E2E-Q{n}:no-row")
    elif not re.search(pat, got[0][0], re.I):
        missing.append(f"E2E-Q{n}:invariant")

print("LINES=%d" % len(section))
print("ROWGAP=%s" % (",".join(rowgap) if rowgap else "none"))
print("COLLIDE=%s" % ("|".join(collide) if collide else "none"))
print("MAPGAP=%s" % (",".join(missing) if missing else "none"))
PY
)"
  if printf '%s' "$e2e_out" | grep -q '^NOSECTION'; then
    bad "gate-registry.md has no '## ...E2E-Q...' section — nothing to register"
  else
    e2e_collide="$(printf '%s\n' "$e2e_out" | sed -n 's/^COLLIDE=//p')"
    e2e_mapgap="$(printf '%s\n' "$e2e_out" | sed -n 's/^MAPGAP=//p')"
    e2e_rowgap="$(printf '%s\n' "$e2e_out" | sed -n 's/^ROWGAP=//p')"
    if [ "$e2e_rowgap" = "none" ]; then
      pass "the E2E-Q section carries exactly one table row for each of E2E-Q1..E2E-Q10"
    else
      bad "E2E-Q section row set is wrong (a gate described in prose is not registered): $e2e_rowgap"
    fi
    if [ "$e2e_collide" = "none" ]; then
      pass "no line of the E2E-Q section matches gen-gate-copies parse_registry's row regex"
    else
      bad "E2E-Q section line(s) parse as a CQ/Q/CAP/AP gate row — family collision: $e2e_collide"
    fi
    if [ "$e2e_mapgap" = "none" ]; then
      pass "gate-registry.md E2E-Q1..E2E-Q10 invariants match the V2 mapping"
    else
      bad "gate-registry.md E2E-Q invariant mismatch for: $e2e_mapgap"
    fi
  fi
fi

# (12f) the generator still parses the registry cleanly. NO ARGS is check mode —
# only --write is recognised; there is no --check flag.
# stdout is the generator's normal report and is noise here; stderr is the ONLY
# place a traceback or a parse error appears, so it is captured and reported. It
# used to go to /dev/null with stdout, which turned every failure mode -- missing
# python, a syntax error in the generator, a broken registry row -- into the same
# blind one-line FAIL.
gg_err="$( (cd "$ROOT" && python3 scripts/gen-gate-copies.py >/dev/null) 2>&1 )"
gg_rc=$?
if [ "$gg_rc" -eq 0 ]; then
  pass "python3 scripts/gen-gate-copies.py (check mode) exits 0 with the E2E-Q section present"
else
  bad "gen-gate-copies.py exits $gg_rc with the E2E-Q section present — registry parse or region drift: $(printf '%s' "$gg_err" | tr '\n' ' ' | cut -c1-600)"
fi

# ── (13) CLAUDE.md describes the registration honestly ──────────────────────
if [ ! -f "$CLAUDEMD" ]; then
  bad "missing: CLAUDE.md"
else
  cl_line="$(grep -n 'gate-registry\.md' "$CLAUDEMD" | head -1)"
  if [ -z "$cl_line" ]; then
    bad "CLAUDE.md no longer mentions gate-registry.md"
  elif printf '%s' "$cl_line" | grep -Eqi 'by[ -]reference'; then
    pass "CLAUDE.md describes E2E-Q as registered by reference: ${cl_line%%:*}"
  else
    bad "CLAUDE.md gate-registry description omits the by-reference E2E-Q registration: [$cl_line]"
  fi
  if grep -Eqi 'E2E-Q' "$CLAUDEMD"; then
    pass "CLAUDE.md names the E2E-Q family"
  else
    bad "CLAUDE.md never names E2E-Q — the SSOT claim stays silently overbroad"
  fi
fi

# ── (14) website/skills/write-e2e.yaml reflects what actually shipped ───────
if [ ! -f "$SITEYAML" ]; then
  bad "missing: website/skills/write-e2e.yaml"
else
  # (14a) new argument grammar, including the deprecated positional alias.
  arg_missing=""
  for a in -- '--scope' '--flow' '--output' '--base-url' '--max-flows' '--live' '--dry-run'; do
    [ "$a" = "--" ] && continue
    grep -Fq -- "$a" "$SITEYAML" || arg_missing="$arg_missing $a"
  done
  if [ -z "$arg_missing" ]; then
    pass "website yaml documents the V2 argument grammar (--scope/--flow/--output/--base-url/--max-flows)"
  else
    bad "website yaml is missing argument(s):$arg_missing"
  fi
  if grep -Eqi 'deprecat' "$SITEYAML" && grep -Fq '[path]' "$SITEYAML"; then
    pass "website yaml marks the positional [path] as a deprecated alias"
  else
    bad "website yaml does not record [path] as a deprecated alias for --scope"
  fi

  # (14b) the verification-state vocabulary — six states, no invented seventh.
  st_missing=""
  for s in GENERATED STATIC_CHECKED VERIFIED_LOCAL VALIDATED_LIVE BLOCKED FAILED; do
    grep -Fq "$s" "$SITEYAML" || st_missing="$st_missing $s"
  done
  if [ -z "$st_missing" ]; then
    pass "website yaml carries the full validation-state vocabulary"
  else
    bad "website yaml is missing validation state(s):$st_missing"
  fi
  if grep -Fq 'VALIDATION SKIPPED' "$SITEYAML"; then
    bad "website yaml still advertises 'VALIDATION SKIPPED' — that state does not exist in V2"
  else
    pass "website yaml does not advertise a non-existent 'VALIDATION SKIPPED' state"
  fi

  # (14c) origin classes and the two consents.
  or_missing=""
  for o in LOCAL STAGING EXTERNAL_UNKNOWN --allow-external-origin --allow-destructive; do
    grep -Fq -- "$o" "$SITEYAML" || or_missing="$or_missing $o"
  done
  if [ -z "$or_missing" ]; then
    pass "website yaml documents the three origin classes and both consents"
  else
    bad "website yaml is missing origin/consent term(s):$or_missing"
  fi

  # (14d) preflight states.
  pf_missing=""
  for p in READY GENERATE_ONLY BOOTSTRAP_REQUIRED; do
    grep -Fq "$p" "$SITEYAML" || pf_missing="$pf_missing $p"
  done
  if [ -z "$pf_missing" ]; then
    pass "website yaml documents the three preflight states"
  else
    bad "website yaml is missing preflight state(s):$pf_missing"
  fi

  # (14e) flow-volume scale — 1 scoped/named, 3 for bare --auto, 20 only on an
  # explicit --max-flows request. Asserted on the ARGUMENT ENTRIES, not on a bare
  # '20' anywhere in the file: the V1 page also contained "default: 20", which is
  # the exact claim this task exists to retire.
  scale_out="$(python3 - "$SITEYAML" <<'PY' 2>&1
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
gaps = []
mf = re.search(r'flag:\s*"--max-flows[^"]*"\s*\n\s*description:\s*"([^"]*)"', text)
if not mf:
    gaps.append("--max-flows-entry")
else:
    if not (re.search(r'\b20\b', mf.group(1)) and re.search(r'explicit|never assumed|by name|asks', mf.group(1), re.I)):
        gaps.append("--max-flows-explicit-20")
    # The retired V1 claim ("--max-flows N, default: 20") can only live on THIS
    # entry, so the ban is scoped to it. Unscoped over the whole page it also fired
    # on any unrelated future `default: 20` -- a timeout, a retry count, a page
    # size -- and failed the suite under the misleading label stale-default-20.
    if re.search(r'default:\s*20\b', mf.group(1), re.I):
        gaps.append("stale-default-20")
au = re.search(r'flag:\s*"--auto"\s*\n\s*description:\s*"([^"]*)"', text)
if not au:
    gaps.append("--auto-entry")
elif not re.search(r'\b3\b|three', au.group(1)):
    gaps.append("--auto-default-3")
sc = re.search(r'flag:\s*"--scope[^"]*"\s*\n\s*description:\s*"([^"]*)"', text)
if not sc:
    gaps.append("--scope-entry")
elif not re.search(r'\b1\b|one flow|single flow', sc.group(1), re.I):
    gaps.append("--scope-single-flow")
print("SCALE=%s" % (",".join(gaps) if gaps else "none"))
PY
)"
  scale_gap="$(printf '%s\n' "$scale_out" | sed -n 's/^SCALE=//p')"
  if [ "$scale_gap" = "none" ]; then
    pass "website yaml states the 1/3/20-explicit flow scale on the argument entries"
  else
    bad "website yaml flow-scale documentation is wrong/stale: $scale_gap"
  fi

  # (14f) E2E-Q V2 mapping — the ids AND the invariants, all ten critical.
  yq_out="$(python3 - "$SITEYAML" "$E2E_LIB" <<'PY' 2>&1
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
ns = {}
exec(compile(open(sys.argv[2], encoding="utf-8").read(), sys.argv[2], "exec"), ns)
INVARIANT = ns["INVARIANT"]

bad_ids, crit_gap = [], []
for n, pat in sorted(INVARIANT.items()):
    # Block = this item up to the next `- id:` OR the next top-level key (the last
    # item has no sibling after it, and without the second alternative the lazy
    # match would have to swallow the rest of the file and would simply not match).
    # The body is UNBOUNDED on purpose: an arbitrary `.{0,400}?` cap made the lazy
    # match unable to reach the lookahead once an item grew past it, and the gate
    # was then reported `:absent` -- a false failure that reads exactly like a
    # dropped gate. The lookahead alternatives already bound the match.
    m = re.search(rf'id:\s*"?E2E-Q{n}"?\s*\n(.*?)(?=\n\s*- id:|\n[A-Za-z_]+:|\Z)', text, re.S)
    if not m:
        bad_ids.append(f"E2E-Q{n}:absent"); continue
    blk = m.group(0)
    if not re.search(pat, blk, re.I):
        bad_ids.append(f"E2E-Q{n}:invariant")
    # A real `critical:` KEY line set to exactly true. The old substring test
    # matched `critical: trueish`, and matched the phrase inside a description
    # string while the key itself was absent or false.
    if not re.search(r'^\s*critical:\s*true\s*$', blk, re.M):
        crit_gap.append(f"E2E-Q{n}")
print("IDS=%s" % (",".join(bad_ids) if bad_ids else "none"))
print("CRIT=%s" % (",".join(crit_gap) if crit_gap else "none"))
PY
)"
  yq_ids="$(printf '%s\n' "$yq_out" | sed -n 's/^IDS=//p')"
  yq_crit="$(printf '%s\n' "$yq_out" | sed -n 's/^CRIT=//p')"
  if [ "$yq_ids" = "none" ]; then
    pass "website yaml carries the V2 E2E-Q1..E2E-Q10 mapping with matching invariants"
  else
    bad "website yaml E2E-Q mapping is stale/incomplete: $yq_ids"
  fi
  if [ "$yq_crit" = "none" ]; then
    pass "website yaml marks all ten E2E-Q gates critical: true"
  else
    bad "website yaml does not mark these E2E-Q gates critical: $yq_crit"
  fi

  # V1 gate labels that MUST be gone — Q2 was 'stable locators', Q5 was
  # 'storageState auth'; both moved and are not gates in V2.
  v1_left=""
  grep -Fq 'Stable locators' "$SITEYAML" && v1_left="$v1_left stable-locators-gate"
  grep -Eq 'E2E-Q5[^\n]*storageState' "$SITEYAML" && v1_left="$v1_left q5-storagestate"
  if [ -z "$v1_left" ]; then
    pass "no V1 E2E-Q labels survive in the website yaml"
  else
    bad "V1 E2E-Q label(s) still in the website yaml:$v1_left"
  fi

  # (14g) the references/ structure is what the page describes.
  if grep -Fq 'references/' "$SITEYAML"; then
    pass "website yaml describes the references/ structure"
  else
    bad "website yaml does not mention the references/ structure the V2 skill ships"
  fi

  # (14h) the page still satisfies scripts/validate-skill-pages.sh — asserted on
  # THIS page, not on the suite's global exit code.
  #
  # Why scoped: validate-skill-pages.sh has been red on main since 440f2fc for
  # reasons that have nothing to do with write-e2e — it hard-codes
  # EXPECTED_COUNT=39 while 41 pages exist, and geo-audit/geo-fix ship 156- and
  # 160-char descriptions plus slugs missing from its ALLOW_LIST. Asserting the
  # global exit code here would make this suite fail for a defect in other files
  # and, worse, would go green later for a reason unrelated to this page. So the
  # validator's OWN rules are applied to write-e2e.yaml: every required top-level
  # key, meta.description <= 155 chars, >= 3 faq, >= 3 stats, a valid category,
  # and related_skills slugs inside its allow-list.
  vp_out="$(python3 - "$SITEYAML" "$ROOT/scripts/validate-skill-pages.sh" <<'PY' 2>&1
import re, sys
page = open(sys.argv[1], encoding="utf-8", errors="replace").read()
val = open(sys.argv[2], encoding="utf-8", errors="replace").read()
problems = []

required = ["schema_version", "last_synced", "meta", "stats", "problem", "how_it_works",
            "examples", "when_to_use", "when_not_to_use", "related_skills", "faq", "arguments"]
for key in required:
    if not re.search(rf'^{key}:', page, re.M):
        problems.append(f"missing-key:{key}")

# Scoped to the `meta:` block by key + indentation rather than grepping the whole
# page (see the dependency note at the top of this file: structural, no PyYAML).
meta = re.search(r'^meta:\s*$\n(.*?)(?=^[A-Za-z_])', page, re.M | re.S)
meta_body = meta.group(1) if meta else ""
m = re.search(r'^  description:[ \t]*(.*)$', meta_body, re.M)
if not m:
    problems.append("no-meta-description")
else:
    desc = m.group(1).strip()
    # A folded/literal block scalar puts the TEXT on the following, more-indented
    # lines; measuring the indicator instead of the text made an over-long
    # description pass. Fold it first, then measure.
    if re.fullmatch(r'[|>][+-]?\d*', desc):
        tail = meta_body[m.end():].split("\n")[1:]
        folded = []
        for ln in tail:
            if ln.strip() and not ln.startswith("    "):
                break
            folded.append(ln.strip())
        desc = " ".join(x for x in folded if x).strip()
    desc = desc.strip('"').strip("'")
    if len(desc) > 155:
        problems.append(f"description-{len(desc)}-chars")

# The validator greps two-space-indented `  description:` across ALL pages and
# fails on duplicates, so this page must carry exactly one such line.
n_desc = len(re.findall(r'^  description:', page, re.M))
if n_desc != 1:
    problems.append(f"two-space-description-lines:{n_desc}")

if len(re.findall(r'^  - q:', page, re.M)) < 3:
    problems.append("faq<3")
if len(re.findall(r'^  - label:', page, re.M)) < 3:
    problems.append("stats<3")

# `category: "task"` is valid YAML and identical in meaning to `category: task`,
# so the quotes are stripped before the enum comparison instead of being carried
# into it as literal characters.
cat = re.search(r'^  category:[ \t]*(\S+)', page, re.M)
cat_val = cat.group(1).strip().strip('"').strip("'") if cat else None
if cat_val not in "audit task pipeline utility design release".split():
    problems.append("category-invalid")

allow = re.search(r'ALLOW_LIST="([^"]*)"', val)
allowed = set(allow.group(1).split()) if allow else set()
for slug in re.findall(r'^  - slug:\s*(\S+)', page, re.M):
    if slug not in allowed:
        problems.append(f"unknown-slug:{slug}")

print("VP=%s" % (",".join(problems) if problems else "none"))
PY
)"
  vp_gap="$(printf '%s\n' "$vp_out" | sed -n 's/^VP=//p')"
  if [ "$vp_gap" = "none" ]; then
    pass "write-e2e.yaml satisfies every validate-skill-pages.sh rule (keys, length, cardinality, slugs)"
  else
    bad "write-e2e.yaml violates validate-skill-pages.sh rule(s): $vp_gap"
  fi

  # The suite-wide run is still executed, but its failures are attributed: a FAIL
  # line naming write-e2e is THIS page's problem and fails here; the pre-existing
  # geo/count failures are not silently adopted.
  vp_lines="$( (cd "$ROOT" && bash scripts/validate-skill-pages.sh 2>&1) | grep '^FAIL' | grep 'write-e2e' || true)"
  if [ -z "$vp_lines" ]; then
    pass "scripts/validate-skill-pages.sh reports no failure naming write-e2e"
  else
    bad "scripts/validate-skill-pages.sh fails on write-e2e: $vp_lines"
  fi
fi

echo ""
if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "SOME CHECKS FAILED"
exit 1
