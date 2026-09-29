#!/usr/bin/env bash
#
# test-reviewer-route-cross-vendor.sh — scripts/reviewer-model-route.sh routes a writer to a reviewer
# of the OTHER vendor (plan C Task 1: docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md;
# coverage rows G1 / G2 / K3 / K4 / K10 / X7).
#
# What was wrong: on a Claude host the router flipped Opus<->Sonnet and, with CLAUDE_MODEL unset (the
# normal Claude Code case), assumed the writer was Sonnet — so an Opus session got reviewer=opus,
# routing_status=ok: Opus reviewing Opus, reported as cross-model (measured live 2026-09-25). On a
# Codex host the reviewer ids were literals the registry had to be copied into by hand (01c1727e).
#
# What this pins (the user's decision: a Claude writer is reviewed by Codex, a Codex writer by Opus 5.5):
#   * Claude host, codex available -> reviewer_lane=cross-vendor, reviewer_model=$ZUVO_MODEL_CODEX_PRIMARY,
#     routing_status=ok, for ANY writer, an unknown one included;
#   * Claude host, codex missing -> the in-family row (opus -> sonnet, sonnet/haiku -> opus) with
#     cross-vendor-unavailable; the lane comes from the alias (opus, opus[1m]), the full id (claude-opus,
#     claude-opus-5-5[1m]) or the legacy shape (claude-3-5-sonnet-20241022) alike;
#   * Codex host (each of the four host signals), claude available -> cross-vendor /
#     $ZUVO_MODEL_CLAUDE_REVIEWER_OPUS / ok (probe P5, zuvo/proofs/probe-5-claude-from-codex-2026-09-25.txt:
#     a nested `claude -p` answered from inside `codex exec`); claude missing -> the registry's in-family
#     GPT pair with cross-vendor-unavailable; the writer comes from ZUVO_CODEX_MODEL -> CODEX_MODEL ->
#     the top-level model of config.toml -> unknown;
#   * EVERY writer source on these two hosts (--writer-model, CLAUDE_MODEL, ZUVO_CODEX_MODEL, CODEX_MODEL,
#     config.toml) passes ONE check — one writer token, [A-Za-z0-9][A-Za-z0-9._:[\]-]* — or is `unknown`;
#   * an UNKNOWN writer that gets no cross-vendor reviewer — with --fallback, or because the other vendor's
#     CLI is missing — gets a fully defined row (Claude: review-alt/sonnet, Codex: review-alt/
#     $ZUVO_MODEL_CODEX_REVIEW_ALT) with unknown-writer-model: on a Claude or Codex host reviewer_model is
#     NEVER `unknown` (a sweep below runs every host x writer x seam x flag combination);
#   * --fallback -> the in-family row with in-family-fallback, whatever is installed; no override gate;
#   * the ids come from the registry (a swapped ZUVO_MODEL_* moves the answer; the router source names none);
#     no registry, or a registry id that is not one plain token ([A-Za-z0-9][A-Za-z0-9._:-]*), fails closed
#     to the env-compat.md sentinel on a Claude/Codex host;
#   * Cursor / Antigravity / Kimi / unknown rows are byte-identical to the pre-change router's (golden rows
#     below), with or without --fallback and with the client seams set;
#   * --platform / --writer-model need a value — not the last argument, not empty, not starting with `-`
#     — or they are a usage error (exit 2, stderr), never a silent `shift 2` death under set -e
#     (B-20260928-ROUTE-PLATFORM-NOVALUE).
#
# Every router run is checked in full (check() below):
#   * the exit code;
#   * stdout compared as a FILE — exactly the six keys in contract order, each once, each value one token of
#     the contract charset (no blank, CR or empty value), one trailing newline — and, wherever the answer is
#     known in advance, cmp against the expected bytes;
#   * stderr empty, or EXACTLY the set of lines the case names (each an exact line or an anchored prefix):
#     an expected line missing fails, and so does any line nobody expected;
#   * no SENTINEL client executed: a sentinel's FIRST action appends its name to $T/invoked.log (append-only,
#     never deleted, so no later run can erase the evidence; check() compares its size with the size before
#     the run, and the end of the suite compares it once more, which catches a sentinel that ran late); and
#     nothing the run started may outlive it — its process group (GNU timeout's) and any process running a
#     sentinel path (pgrep, this user, $T escaped as a literal) are checked, and killed, after every run;
#   * every run is checked by the check() that follows it — a second run before that check is a harness
#     error — so a leak is always reported against the run that caused it;
#   * the plan's 5 s budget, enforced as a real-time bound: every run sits under `timeout 5`, and rc 124/137
#     (killed at the bound) fails the case as over budget. No whole-second arithmetic is involved.
#
# Hermetic: every router run is `env -i` with HOME / ZUVO_HOME / CODEX_HOME in the sandbox,
# ZUVO_CODEX_APP_BIN=/nonexistent, ZUVO_CODEX_BIN and ZUVO_CLAUDE_BIN set to a sentinel or /nonexistent (a
# NON-EMPTY seam is final; the library reads an EMPTY one as unset) unless a case removes them with `-u`,
# no host signal unless the case sets it, and PATH=<shim>:/usr/bin:/bin (shim = links to the real
# timeout/gtimeout/jq only, tests/lib/hermetic-tools.sh; checked to hold no client). Two cases run with both
# seams REMOVED and PATH=<shim> ALONE — no /usr/bin:/bin on purpose: the router needs no external command
# (it is also run under PATH=/nonexistent), so a client it could find there is a client it found itself.
# ZUVO_TEST_ROUTE runs every case against ANOTHER router copy (to show the cases are red there). The library
# and the registry fixture are taken from THAT copy's tree (<dir>/lib/, <dir>/../shared/includes/), so the
# copy must sit in a repo-shaped tree.
#
# Run under both shells (bash 3.2 is macOS's /bin/bash):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/test-reviewer-route-cross-vendor.sh
#   TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/test-reviewer-route-cross-vendor.sh
set -uo pipefail

PASS=0; FAIL=0
ok()  { echo "  PASS $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
die() { echo "  FAIL setup: $1" >&2; echo "RESULT: PASS=$PASS FAIL=$((FAIL+1)) (setup aborted)"; exit 1; }
expect_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
oneline() { printf '%s' "$1" | tr '\n' ' '; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
# The router under test, made absolute (a bare or relative ZUVO_TEST_ROUTE included); its library and the
# registry fixture come from ITS tree, never from this file's checkout.
ROUTE="${ZUVO_TEST_ROUTE:-$ROOT/scripts/reviewer-model-route.sh}"
case "$ROUTE" in */*) _rd="${ROUTE%/*}" ;; *) _rd=. ;; esac
_rd="$(cd "${_rd:-/}" 2>/dev/null && pwd -P)" || die "cannot enter the directory of the router under test [$ROUTE]"
ROUTE="$_rd/${ROUTE##*/}"
LIB="$_rd/lib/model-subprocess.sh"
REGISTRY="$(cd "$_rd/.." 2>/dev/null && pwd -P)/shared/includes/model-registry.sh"
RBASH="$BASH"
BUDGET_S=5

echo "== reviewer-model-route cross-vendor routing (bash $BASH_VERSION) =="

for _f in "$ROUTE" "$REGISTRY" "$LIB"; do
  [ -f "$_f" ] || die "missing $_f (the router under test must sit in a repo-shaped tree)"
done

# ── sandbox ──────────────────────────────────────────────────────────────────
T="$(mktemp -d)" || die "mktemp -d failed"
[ -n "$T" ] && [ -d "$T" ] || die "mktemp -d returned no directory"
T="$(cd "$T" && pwd -P)" && [ -n "$T" ] || die "cannot resolve the sandbox path"
# re_lit <text> — <text> as an ERE matching exactly itself ($T holds `.`, which pgrep would read as "any").
re_lit() { printf '%s' "$1" | sed 's/[][\.*^$(){}+?|]/\\&/g'; }
ME="$(id -u)" || die "id -u failed"
# sentinel_pids — pids of THIS user's processes running a sentinel or stub path of THIS sandbox.
sentinel_pids() { pgrep -u "$ME" -f "$SENT_RE" 2>/dev/null; }
# Anything still running from a sentinel is killed, then the sandbox goes.
cleanup() {
  local p
  if [ -n "${SENT_RE:-}" ]; then
    for p in $(sentinel_pids); do kill -KILL "$p" 2>/dev/null; done
  fi
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/home/.zuvo" "$T/codex-empty" "$T/shim" "$T/sentinel" "$T/stubs" || die "cannot create the sandbox dirs"
# shellcheck source=tests/lib/hermetic-tools.sh
. "$ROOT/tests/lib/hermetic-tools.sh" || die "cannot load tests/lib/hermetic-tools.sh"
hermetic_link_tools "$T/shim" timeout:gtimeout jq || die "hermetic_link_tools failed"
TO="$T/shim/timeout"
[ -x "$TO" ] || die "GNU timeout (timeout or gtimeout) required for the per-run budget — brew install coreutils"
command -v pgrep >/dev/null 2>&1 || die "pgrep required for the leftover-process check"
SENT_RE="$(re_lit "$T")/(sentinel|stubs|p-agy)/"
[ -n "$(re_lit "$T")" ] || die "cannot build the sentinel process pattern"
for _c in codex claude agy cursor-agent kimi gemini; do
  [ ! -e "$T/shim/$_c" ] || die "the shim holds a client ($_c): the hermetic PATH would not be"
done

# SENTINEL clients: the FIRST action appends the client's name to $T/invoked.log (builtin printf and a
# redirection — it works under any PATH), then the sentinel hangs. A router that ran one shows up in the log,
# as a process still alive after the run, or as a run over budget.
MARKS="$T/invoked.log"
for _c in codex claude; do
  printf '#!/bin/sh\nprintf "%%s\\n" %s >> "%s"\n/bin/sleep 30\n' "$_c" "$MARKS" > "$T/sentinel/$_c" \
    && chmod +x "$T/sentinel/$_c" || die "cannot write the $_c sentinel"
done
SC="$T/sentinel/codex"; SL="$T/sentinel/claude"
# The same sentinels under their bare names in a PATH directory (the PATH-lookup cases).
cp "$SC" "$T/stubs/codex" && cp "$SL" "$T/stubs/claude" || die "cannot copy the sentinels into stubs/"
# Seams that EXIST but are no executable regular file: a mode-644 file and a directory.
printf '#!/bin/sh\nprintf "%%s\\n" noexec >> "%s"\n' "$MARKS" > "$T/noexec-codex" && chmod 644 "$T/noexec-codex" \
  && mkdir -p "$T/dir-codex" || die "cannot write the non-executable seam fixtures"

# The registry's ids, read the way the router must read them — never restated here.
# shellcheck disable=SC2016  # expanded by the child shell
_reg="$(env -i PATH=/usr/bin:/bin /bin/bash -c '. "$1" && printf "%s|%s|%s|%s|%s" "$ZUVO_MODEL_CODEX_PRIMARY" \
  "$ZUVO_MODEL_CODEX_ALT" "$ZUVO_MODEL_CODEX_REVIEW_ALT" "$ZUVO_MODEL_CODEX_SMALL" "$ZUVO_MODEL_CLAUDE_REVIEWER_OPUS"' _ "$REGISTRY")" \
  || die "cannot source $REGISTRY"
IFS='|' read -r R_PRIMARY R_ALT R_REVIEW_ALT R_SMALL R_OPUS <<EOF
$_reg
EOF
for _v in "$R_PRIMARY" "$R_ALT" "$R_REVIEW_ALT" "$R_SMALL" "$R_OPUS"; do
  [ -n "$_v" ] || die "cannot read the codex/claude reviewer ids from $REGISTRY"
done
[ "$R_PRIMARY" != "$R_REVIEW_ALT" ] || die "registry primary == review-alt: the in-family cases would be vacuous"
echo "  note: registry codex primary=$R_PRIMARY alt=$R_ALT review-alt=$R_REVIEW_ALT small=$R_SMALL claude reviewer=$R_OPUS"

# Codex homes. codex-luna: the TOP-LEVEL model is the writer (the [profiles] model below it must not count).
# The rest are malformed: every one must read as an unknown writer, never be printed.
mkcfg() { mkdir -p "$T/$1" && printf '%b' "$2" > "$T/$1/config.toml" || die "cannot write the $1 fixture"; }
mkcfg codex-luna "model = \"$R_ALT\"\n[profiles.x]\nmodel = \"not-the-writer\"\n"
mkcfg cfg-unterminated 'model = "gpt-6-sol\n'
mkcfg cfg-blank 'model = "   "\n'
mkcfg cfg-space 'model = "gpt 6"\n'
mkcfg cfg-equals 'model = "a=b"\n'
mkcfg cfg-glob 'model = "gpt-*"\n'
mkcfg cfg-semicolon 'model = "gpt;6"\n'
mkcfg cfg-garbage '\001\002 model = \377\376\nmodel =\n'

# ── harness ──────────────────────────────────────────────────────────────────
RC=""; LEAKED=""; PENDING=0; MARKS_BEFORE=0; MARKS_CHECKED=0
# marks — lines in the append-only sentinel log (0 while nothing has run).
marks() { if [ -f "$MARKS" ]; then awk 'END { print NR }' "$MARKS"; else echo 0; fi; }
DEFAULT_NAMES=" HOME ZUVO_HOME CODEX_HOME ZUVO_CODEX_APP_BIN ZUVO_CODEX_BIN ZUVO_CLAUDE_BIN PATH "
# run_router <router> [-u NAME]... [VAR=value]... [-- router-args...] — one hermetic run inside the budget.
# `-u NAME` drops NAME from the defaults (the seam is then really UNSET, not empty); NAME must be one of
# DEFAULT_NAMES — a missing or unknown one is a HARNESS error and ends the suite. A VAR=value given here
# comes after the defaults and wins. stdout/stderr land in $T/out / $T/err; sets RC and LEAKED.
# The run is started in the background so its process group (GNU timeout makes itself the leader; the
# router and anything it starts inherit it) can be checked after it returns: a living member is a leaked
# child — reported, then killed.
run_router() {
  local router="$1" drop=" " d tpid
  shift
  local defaults=("HOME=$T/home" "ZUVO_HOME=$T/home/.zuvo" "CODEX_HOME=$T/codex-empty" ZUVO_CODEX_APP_BIN=/nonexistent
                  ZUVO_CODEX_BIN=/nonexistent ZUVO_CLAUDE_BIN=/nonexistent "PATH=$T/shim:/usr/bin:/bin")
  local keep=() envs=() args=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    if [ "$1" = "-u" ]; then
      case "${2:-}" in
        ""|--|*=*) die "harness: -u needs the NAME of a default (got [${2:-}])" ;;
      esac
      case "$DEFAULT_NAMES" in *" $2 "*) ;; *) die "harness: -u $2 — not a default this harness sets ($DEFAULT_NAMES)" ;; esac
      drop="$drop$2 "; shift 2; continue
    fi
    envs+=("$1"); shift
  done
  if [ $# -gt 0 ]; then shift; args=("$@"); fi
  for d in "${defaults[@]}"; do
    case "$drop" in *" ${d%%=*} "*) ;; *) keep+=("$d") ;; esac
  done
  if [ "$PENDING" = 1 ]; then bad "harness: a run was started before the previous run was checked"; fi
  PENDING=1
  rm -f "$T/out" "$T/err"
  MARKS_BEFORE="$(marks)"
  "$TO" -k 1 "$BUDGET_S" env -i ${keep[@]+"${keep[@]}"} ${envs[@]+"${envs[@]}"} \
    "$RBASH" "$router" ${args[@]+"${args[@]}"} > "$T/out" 2> "$T/err" &
  tpid=$!
  wait "$tpid"
  RC=$?
  LEAKED=""
  if kill -0 -- "-$tpid" 2>/dev/null; then
    LEAKED="process group $tpid still has a member after the run"
    kill -KILL -- "-$tpid" 2>/dev/null
  fi
  # ... and anything running a sentinel path, whatever group it moved to.
  local left p
  left="$(sentinel_pids | tr '\n' ' ')"
  if [ -n "$left" ]; then
    LEAKED="$LEAKED${LEAKED:+; }sentinel process(es) alive after the run: $left"
    for p in $left; do kill -KILL "$p" 2>/dev/null; done
  fi
}
run_route() { run_router "$ROUTE" "$@"; }
# sentinel_ran — the log grew during the last run.
sentinel_ran() { [ "$(marks)" -gt "$MARKS_BEFORE" ]; }
# six_keys_file <file> — exactly six lines, the contract's keys in order, each once, one trailing newline,
# and each VALUE in its own domain (byte semantics, LC_ALL=C: the ranges are ASCII):
#   platform, writer_lane, reviewer_lane, routing_status — their closed enums;
#   writer_model   — a writer id: [A-Za-z0-9][A-Za-z0-9._:-]* with at most ONE trailing [<alnum>+] suffix;
#   reviewer_model — a registry-strict id ([A-Za-z0-9][A-Za-z0-9._:-]*; the aliases opus/sonnet/haiku fit),
#                    or `unknown` ONLY where the contract allows it: the routing-failed sentinel, and the hosts
#                    this router does not route itself (cursor / antigravity / kimi / unknown), whose
#                    same-model rows also repeat the writer id.
six_keys_file() {
  [ -s "$1" ] || return 1
  [ "$(tail -c 1 "$1" | od -An -tx1 | tr -d ' \n')" = "0a" ] || return 1
  LC_ALL=C awk '
    BEGIN { split("platform writer_model writer_lane reviewer_lane reviewer_model routing_status", k, " ")
            id = "^[A-Za-z0-9][A-Za-z0-9._:-]*$"; wid = "^[A-Za-z0-9][A-Za-z0-9._:-]*(\\[[A-Za-z0-9]+\\])?$" }
    { n++; i = index($0, "="); if (i < 2) { bad = 1; next }
      key = substr($0, 1, i - 1); v[key] = substr($0, i + 1); if (key != k[n]) bad = 1 }
    END {
      if (n != 6 || bad) exit 1
      if (v["platform"] !~ /^(claude|codex|cursor|antigravity|kimi|unknown)$/) exit 1
      if (v["writer_lane"] !~ /^(small|strong_primary|strong_alt|unknown)$/) exit 1
      if (v["reviewer_lane"] !~ /^(cross-vendor|review-primary|review-alt|same-model-fallback)$/) exit 1
      if (v["routing_status"] !~ /^(ok|cross-vendor-unavailable|in-family-fallback|unknown-writer-model|same-model-fallback|routing-failed)$/) exit 1
      if (v["writer_model"] !~ wid) exit 1
      r = v["reviewer_model"]; own = (v["platform"] == "claude" || v["platform"] == "codex")
      if (v["routing_status"] == "routing-failed") { if (r != "unknown") exit 1 }
      else if (own) { if (r !~ id || r == "unknown") exit 1 }
      else if (r !~ wid) exit 1
      exit 0 }' "$1"
}
# field <key> — the value of <key> in $T/out, parsed as a field (never a substring match).
field() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$T/out"; }
# row <platform> <writer_model> <writer_lane> <reviewer_lane> <reviewer_model> <routing_status>
row() { printf 'platform=%s\nwriter_model=%s\nwriter_lane=%s\nreviewer_lane=%s\nreviewer_model=%s\nrouting_status=%s' "$@"; }
# The fail-closed answer of shared/includes/env-compat.md ("Failure mode contract"), verbatim: platform=unknown,
# so it is no Claude/Codex routing row — the only row on which reviewer_model=unknown is the contract.
ROUTING_FAILED_ROW="$(row unknown unknown unknown same-model-fallback unknown routing-failed)"
# err_set_ok <specs> — $T/err is EXACTLY the named set: every spec (`line:<text>` = a line IS <text>, byte for
# byte; `prefix:<text>` = a line STARTS with <text>) matches some line, and every line matches some spec.
# Prints what is wrong; status 1 on a mismatch, 2 on a malformed spec or an unreadable file.
err_set_ok() {
  printf '%s\n' "$1" | LC_ALL=C awk -v errf="$T/err" '
    NF == 0 { next }
    { m = $0; sub(/:.*/, "", m); t = substr($0, length(m) + 2)
      if (m != "line" && m != "prefix") { print "malformed spec [" $0 "]"; st = 2; exit }
      ns++; mode[ns] = m; text[ns] = t }
    END {
      if (st) exit st
      while ((r = (getline l < errf)) > 0) {
        nl++; hit = 0
        for (s = 1; s <= ns; s++)
          if ((mode[s] == "line" && l == text[s]) || (mode[s] == "prefix" && index(l, text[s]) == 1)) { hit = 1; used[s] = 1 }
        if (!hit) { print "unexpected stderr line [" l "]"; bad = 1 } }
      if (r < 0) { print "cannot read " errf; exit 2 }
      for (s = 1; s <= ns; s++) if (!used[s]) { print "no stderr line for [" mode[s] ":" text[s] "]"; bad = 1 }
      exit(bad ? 1 : 0) }'
}
# expand_specs <specs> — the spec `usage` stands for every line of the router's own --help text (captured once,
# below), each as an exact `line:` spec: a usage error must print the usage and nothing but it.
expand_specs() {
  local s
  while IFS= read -r s; do
    if [ "$s" = usage ]; then awk '{ print "line:" $0 }' "$T/usage.txt"; else printf '%s\n' "$s"; fi
  done <<EOF
$1
EOF
}
# check <label> <want-rc> <want> <stderr-specs> — the full per-run contract for the LAST run.
#   <want>: a six-key block — compared byte for byte as a file (six_keys_file too); every case whose answer
#           is known in advance uses this.
#           SIX — six_keys_file only: the SHAPE of the contract (keys, order, value charset, trailing newline)
#           but NOT the values. Used by the 5b sweep alone, which asserts one field (reviewer_model) across 36
#           host x writer x seam x flag rows whose exact answers are each pinned byte for byte elsewhere.
#           - — nothing on stdout (usage errors).
#           ANY — stdout not checked here: --help only, which prints prose, not the contract; its content is
#           checked by the caller.
#   <stderr-specs>: empty = stderr must be empty; otherwise newline-separated specs (see err_spec_ok), EACH of
#           which must hold.
check() {
  local label="$1" want_rc="$2" want="$3" specs="$4" why="" msg rc
  PENDING=0
  case "$RC" in 124|137) why="$why OVER BUDGET: killed at ${BUDGET_S}s (rc=$RC);" ;; esac
  [ "$RC" = "$want_rc" ] || why="$why exit=$RC (want $want_rc);"
  if sentinel_ran; then why="$why a SENTINEL client was executed ($(awk -v s="$MARKS_BEFORE" 'NR > s' "$MARKS" | tr '\n' ' '));"; fi
  MARKS_CHECKED="$(marks)"
  [ -z "$LEAKED" ] || why="$why $LEAKED;"
  case "$want" in
    -)   [ ! -s "$T/out" ] || why="$why stdout not empty [$(oneline "$(cat "$T/out")")];" ;;
    ANY) ;;
    SIX) six_keys_file "$T/out" || why="$why stdout is not the six-key contract [$(oneline "$(cat "$T/out")")];" ;;
    *)   printf '%s\n' "$want" > "$T/want"
         six_keys_file "$T/out" || why="$why stdout is not the six-key contract;"
         cmp -s "$T/want" "$T/out" || why="$why answer [$(oneline "$(cat "$T/out")")] want [$(oneline "$want")];" ;;
  esac
  if [ -z "$specs" ]; then
    [ ! -s "$T/err" ] || why="$why stderr [$(oneline "$(cat "$T/err")")];"
  else
    msg="$(err_set_ok "$(expand_specs "$specs")")"; rc=$?
    [ "$rc" = 0 ] || why="$why stderr is not the expected set (status $rc): $(oneline "$msg");"
  fi
  if [ -z "$why" ]; then ok "$label"; else bad "$label —$why"; fi
}
# expect_route <label> <want-block> [run_route args...] — exit 0, that exact answer, silent stderr.
expect_route() {
  local label="$1" want="$2"; shift 2
  run_route "$@"
  check "$label" 0 "$want" ""
}

CL=(CLAUDECODE=1)
# The router's --help text, the reference for every `usage` stderr spec.
run_route -- --help
check "--help: exit 0, silent stderr (captured as the usage reference)" 0 ANY ""
cp "$T/out" "$T/usage.txt" || die "cannot keep the usage text"
[ -s "$T/usage.txt" ] || die "the router printed no --help text"
CODEX_SIGNALS=("CODEX_SANDBOX=seatbelt" "CODEX_SHELL=1" "CODEX_INTERNAL_ORIGINATOR_OVERRIDE=Codex Desktop" "__CFBundleIdentifier=com.openai.codex")

# ── 1. Claude host, codex available: cross-vendor for EVERY writer (G1, K4) ──
echo "-- 1. Claude host, codex available"
expect_route "claude/opus, codex available: cross-vendor to the registry's codex primary" \
  "$(row claude opus strong_primary cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" CLAUDE_MODEL=opus "ZUVO_CODEX_BIN=$SC"
expect_route "claude/sonnet, codex available: cross-vendor, not opus" \
  "$(row claude sonnet strong_alt cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" CLAUDE_MODEL=sonnet "ZUVO_CODEX_BIN=$SC"
expect_route "claude/haiku, codex available: cross-vendor" \
  "$(row claude haiku small cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" CLAUDE_MODEL=haiku "ZUVO_CODEX_BIN=$SC"
expect_route "claude, CLAUDE_MODEL UNSET: writer_model=unknown (never sonnet), still cross-vendor ok" \
  "$(row claude unknown unknown cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" "ZUVO_CODEX_BIN=$SC"
expect_route "claude, CLAUDE_MODEL EMPTY: writer_model=unknown" \
  "$(row claude unknown unknown cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" CLAUDE_MODEL= "ZUVO_CODEX_BIN=$SC"
expect_route "claude, CLAUDE_MODEL BLANK: writer_model=unknown, never the blanks" \
  "$(row claude unknown unknown cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" "CLAUDE_MODEL=   " "ZUVO_CODEX_BIN=$SC"
expect_route "claude, full id claude-opus-5-5: the opus lane" \
  "$(row claude claude-opus-5-5 strong_primary cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" CLAUDE_MODEL=claude-opus-5-5 "ZUVO_CODEX_BIN=$SC"
expect_route "claude, the real Claude Code shape claude-opus-5-5[1m]: accepted, the opus lane" \
  "$(row claude 'claude-opus-5-5[1m]' strong_primary cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" 'CLAUDE_MODEL=claude-opus-5-5[1m]' "ZUVO_CODEX_BIN=$SC"
expect_route "claude, a writer id the table does not know: cross-vendor ok (the platform names the vendor)" \
  "$(row claude claude-mystery-9 unknown cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" CLAUDE_MODEL=claude-mystery-9 "ZUVO_CODEX_BIN=$SC"
# ONE writer check for every source: a value that is not one writer token is `unknown`, never printed.
expect_route "claude, CLAUDE_MODEL='x;y': not one writer token -> unknown" \
  "$(row claude unknown unknown cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" 'CLAUDE_MODEL=x;y' "ZUVO_CODEX_BIN=$SC"
expect_route "claude, CLAUDE_MODEL with a blank inside ('claude opus'): unknown" \
  "$(row claude unknown unknown cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" 'CLAUDE_MODEL=claude opus' "ZUVO_CODEX_BIN=$SC"
expect_route "claude, --writer-model 'a b' (override on): unknown, not printed" \
  "$(row claude unknown unknown cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 "ZUVO_CODEX_BIN=$SC" \
  -- --writer-model 'a b'
expect_route "claude, --writer-model 'claude-opus-5-5[1m]' (override on, codex missing): accepted, the opus lane in-family" \
  "$(row claude 'claude-opus-5-5[1m]' strong_primary review-alt sonnet cross-vendor-unavailable)" "${CL[@]}" \
  ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 -- --writer-model 'claude-opus-5-5[1m]'
expect_route "CLAUDE_MODEL alone (no CLAUDECODE) is a Claude host too" \
  "$(row claude opus strong_primary cross-vendor "$R_PRIMARY" ok)" CLAUDE_MODEL=opus "ZUVO_CODEX_BIN=$SC"
expect_route "seam UNSET (-u): a codex found on PATH counts as available (looked up, never run)" \
  "$(row claude opus strong_primary cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" CLAUDE_MODEL=opus -u ZUVO_CODEX_BIN \
  "PATH=$T/stubs:$T/shim:/usr/bin:/bin"
expect_route "seam EMPTY: the library reads an empty ZUVO_CODEX_BIN as unset (PATH lookup)" \
  "$(row claude opus strong_primary cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" CLAUDE_MODEL=opus ZUVO_CODEX_BIN= \
  "PATH=$T/stubs:$T/shim:/usr/bin:/bin"
expect_route "same-model guard still applies: a writer equal to the cross-vendor reviewer is not ok" \
  "$(row claude "$R_PRIMARY" unknown same-model-fallback "$R_PRIMARY" same-model-fallback)" "${CL[@]}" \
  "CLAUDE_MODEL=$R_PRIMARY" "ZUVO_CODEX_BIN=$SC"

# ── 2. Claude host, codex missing: in-family, labelled (K3) ───────────────────
echo "-- 2. Claude host, codex missing"
expect_route "claude/opus, codex missing: sonnet, cross-vendor-unavailable" \
  "$(row claude opus strong_primary review-alt sonnet cross-vendor-unavailable)" "${CL[@]}" CLAUDE_MODEL=opus
expect_route "claude/sonnet, codex missing: opus, cross-vendor-unavailable" \
  "$(row claude sonnet strong_alt review-primary opus cross-vendor-unavailable)" "${CL[@]}" CLAUDE_MODEL=sonnet
expect_route "claude/haiku, codex missing: opus, cross-vendor-unavailable" \
  "$(row claude haiku small review-primary opus cross-vendor-unavailable)" "${CL[@]}" CLAUDE_MODEL=haiku
expect_route "claude-opus-5-5 (full id), codex missing: sonnet, cross-vendor-unavailable" \
  "$(row claude claude-opus-5-5 strong_primary review-alt sonnet cross-vendor-unavailable)" "${CL[@]}" CLAUDE_MODEL=claude-opus-5-5
expect_route "claude-sonnet-5 (full id), codex missing: opus, cross-vendor-unavailable" \
  "$(row claude claude-sonnet-5 strong_alt review-primary opus cross-vendor-unavailable)" "${CL[@]}" CLAUDE_MODEL=claude-sonnet-5
expect_route "claude-haiku-4-5-20251001 (full id), codex missing: opus, cross-vendor-unavailable" \
  "$(row claude claude-haiku-4-5-20251001 small review-primary opus cross-vendor-unavailable)" "${CL[@]}" \
  CLAUDE_MODEL=claude-haiku-4-5-20251001
# Every Claude id shape names its lane: the alias with a context suffix, the bare full id, the full id with
# a version (and a suffix), and the legacy claude-3(-5)-<tier>-<date> ids. An EMPTY version is not a version.
for _w in 'opus[1m]:strong_primary:review-alt:sonnet' 'claude-opus:strong_primary:review-alt:sonnet' \
          'claude-sonnet:strong_alt:review-primary:opus' 'claude-haiku:small:review-primary:opus' \
          'claude-opus-5-5[1m]:strong_primary:review-alt:sonnet' 'claude-3-opus-20240229:strong_primary:review-alt:sonnet' \
          'claude-3-5-sonnet-20241022:strong_alt:review-primary:opus' 'claude-3-5-haiku-20241022:small:review-primary:opus' \
          'claude-3-haiku-20240307:small:review-primary:opus'; do
  IFS=: read -r _id _lane _rl _rm <<EOF
$_w
EOF
  expect_route "claude lane from the id shape [$_id]: $_lane, codex missing" \
    "$(row claude "$_id" "$_lane" "$_rl" "$_rm" cross-vendor-unavailable)" "${CL[@]}" "CLAUDE_MODEL=$_id"
done
for _id in claude-opus- claude-sonnet- claude-3-5-haiku- opus-; do
  expect_route "claude id [$_id] (empty version): no lane — the assumed row, unknown-writer-model" \
    "$(row claude "$_id" unknown review-alt sonnet unknown-writer-model)" "${CL[@]}" "CLAUDE_MODEL=$_id"
done
expect_route "claude, writer UNKNOWN and codex missing: the defined assumed row, never reviewer_model=unknown" \
  "$(row claude unknown unknown review-alt sonnet unknown-writer-model)" "${CL[@]}"
expect_route "claude, a writer id the table does not know, codex missing: the assumed row, unknown-writer-model" \
  "$(row claude claude-mystery-9 unknown review-alt sonnet unknown-writer-model)" "${CL[@]}" CLAUDE_MODEL=claude-mystery-9
expect_route "codex missing with a codex ON PATH: a set ZUVO_CODEX_BIN is final" \
  "$(row claude opus strong_primary review-alt sonnet cross-vendor-unavailable)" "${CL[@]}" CLAUDE_MODEL=opus \
  "PATH=$T/stubs:$T/shim:/usr/bin:/bin"
# A seam that EXISTS but is no executable regular file is not a client: availability is `-f` AND `-x`
# (scripts/lib/model-subprocess.sh _zms_exe), never existence alone.
expect_route "seam at a mode-644 file: not available (and never run)" \
  "$(row claude opus strong_primary review-alt sonnet cross-vendor-unavailable)" "${CL[@]}" CLAUDE_MODEL=opus "ZUVO_CODEX_BIN=$T/noexec-codex"
expect_route "seam at a directory: not available" \
  "$(row claude opus strong_primary review-alt sonnet cross-vendor-unavailable)" "${CL[@]}" CLAUDE_MODEL=opus "ZUVO_CODEX_BIN=$T/dir-codex"
expect_route "codex host, claude seam at a mode-644 file: not available" \
  "$(row codex "$R_PRIMARY" strong_primary review-alt "$R_REVIEW_ALT" cross-vendor-unavailable)" CODEX_SHELL=1 \
  "ZUVO_CODEX_MODEL=$R_PRIMARY" "ZUVO_CLAUDE_BIN=$T/noexec-codex"
# No client installed on this machine can reach the router: both seams REMOVED, PATH = the shim alone (checked
# at setup to hold no client), HOME / CODEX_HOME in the sandbox, the Codex.app fallback off.
expect_route "seams unset, PATH=<shim> only: no host-installed codex leaks in (Claude host)" \
  "$(row claude opus strong_primary review-alt sonnet cross-vendor-unavailable)" "${CL[@]}" CLAUDE_MODEL=opus \
  -u ZUVO_CODEX_BIN -u ZUVO_CLAUDE_BIN "PATH=$T/shim"
expect_route "seams unset, PATH=<shim> only: no host-installed claude leaks in (Codex host)" \
  "$(row codex "$R_PRIMARY" strong_primary review-alt "$R_REVIEW_ALT" cross-vendor-unavailable)" CODEX_SHELL=1 \
  "ZUVO_CODEX_MODEL=$R_PRIMARY" -u ZUVO_CODEX_BIN -u ZUVO_CLAUDE_BIN "PATH=$T/shim"

# ── 3. Codex host, claude available: Opus 5.5 (G2; P5 passed) ─────────────────
echo "-- 3. Codex host, claude available"
for _sig in "${CODEX_SIGNALS[@]}"; do
  expect_route "codex host [$_sig], writer $R_PRIMARY: cross-vendor to the registry's claude reviewer" \
    "$(row codex "$R_PRIMARY" strong_primary cross-vendor "$R_OPUS" ok)" "$_sig" "ZUVO_CODEX_MODEL=$R_PRIMARY" "ZUVO_CLAUDE_BIN=$SL"
done
expect_route "codex host, writer $R_ALT: cross-vendor" \
  "$(row codex "$R_ALT" strong_alt cross-vendor "$R_OPUS" ok)" CODEX_SHELL=1 "ZUVO_CODEX_MODEL=$R_ALT" "ZUVO_CLAUDE_BIN=$SL"
expect_route "codex host, NO writer hint and no config model: writer unknown, still cross-vendor ok" \
  "$(row codex unknown unknown cross-vendor "$R_OPUS" ok)" CODEX_SHELL=1 "ZUVO_CLAUDE_BIN=$SL"
expect_route "codex host: the writer is read from CODEX_MODEL when ZUVO_CODEX_MODEL is unset" \
  "$(row codex "$R_ALT" strong_alt cross-vendor "$R_OPUS" ok)" CODEX_SHELL=1 "CODEX_MODEL=$R_ALT" "ZUVO_CLAUDE_BIN=$SL"
expect_route "codex host: ZUVO_CODEX_MODEL wins over CODEX_MODEL" \
  "$(row codex "$R_PRIMARY" strong_primary cross-vendor "$R_OPUS" ok)" CODEX_SHELL=1 "ZUVO_CODEX_MODEL=$R_PRIMARY" \
  "CODEX_MODEL=$R_ALT" "ZUVO_CLAUDE_BIN=$SL"
expect_route "codex host: the writer is the TOP-LEVEL model of \$CODEX_HOME/config.toml" \
  "$(row codex "$R_ALT" strong_alt cross-vendor "$R_OPUS" ok)" CODEX_SHELL=1 "CODEX_HOME=$T/codex-luna" "ZUVO_CLAUDE_BIN=$SL"

# ── 4. Codex host, claude missing: the registry's in-family pair, labelled ───
echo "-- 4. Codex host, claude missing"
expect_route "codex/$R_PRIMARY, claude missing: review-alt = registry review-alt, cross-vendor-unavailable" \
  "$(row codex "$R_PRIMARY" strong_primary review-alt "$R_REVIEW_ALT" cross-vendor-unavailable)" CODEX_SHELL=1 "ZUVO_CODEX_MODEL=$R_PRIMARY"
expect_route "codex/$R_ALT, claude missing: review-primary = registry primary, cross-vendor-unavailable" \
  "$(row codex "$R_ALT" strong_alt review-primary "$R_PRIMARY" cross-vendor-unavailable)" CODEX_SHELL=1 "ZUVO_CODEX_MODEL=$R_ALT"
expect_route "codex/$R_SMALL (registry small), claude missing: review-primary, cross-vendor-unavailable" \
  "$(row codex "$R_SMALL" small review-primary "$R_PRIMARY" cross-vendor-unavailable)" CODEX_SHELL=1 "ZUVO_CODEX_MODEL=$R_SMALL"
UNK_CODEX="$(row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model)"
expect_route "codex, writer UNKNOWN and claude missing: the defined assumed row, never reviewer_model=unknown" \
  "$UNK_CODEX" CODEX_SHELL=1
expect_route "claude missing with a claude ON PATH: a set ZUVO_CLAUDE_BIN is final" \
  "$(row codex "$R_PRIMARY" strong_primary review-alt "$R_REVIEW_ALT" cross-vendor-unavailable)" CODEX_SHELL=1 \
  "ZUVO_CODEX_MODEL=$R_PRIMARY" "PATH=$T/stubs:$T/shim:/usr/bin:/bin"
# A blank or malformed writer is UNKNOWN — never printed into the contract (a blank value, a stray quote).
expect_route "codex, ZUVO_CODEX_MODEL EMPTY: falls through, writer unknown" "$UNK_CODEX" CODEX_SHELL=1 ZUVO_CODEX_MODEL=
expect_route "codex, ZUVO_CODEX_MODEL BLANK: falls through, writer unknown" "$UNK_CODEX" CODEX_SHELL=1 "ZUVO_CODEX_MODEL=  "
expect_route "codex, ZUVO_CODEX_MODEL BLANK falls through to the config writer" \
  "$(row codex "$R_ALT" strong_alt review-primary "$R_PRIMARY" cross-vendor-unavailable)" CODEX_SHELL=1 "ZUVO_CODEX_MODEL=  " \
  "CODEX_HOME=$T/codex-luna"
expect_route "codex, CODEX_MODEL EMPTY: writer unknown" "$UNK_CODEX" CODEX_SHELL=1 CODEX_MODEL=
expect_route "codex, CODEX_MODEL BLANK: writer unknown" "$UNK_CODEX" CODEX_SHELL=1 "CODEX_MODEL=   "
expect_route "codex, ZUVO_CODEX_MODEL='gpt 6': not one writer token -> unknown (no fall-through to config)" "$UNK_CODEX" \
  CODEX_SHELL=1 "ZUVO_CODEX_MODEL=gpt 6" "CODEX_HOME=$T/codex-luna"
expect_route "codex, CODEX_MODEL='gpt;6': unknown" "$UNK_CODEX" CODEX_SHELL=1 'CODEX_MODEL=gpt;6'
expect_route "codex, --writer-model 'x;y' (override on): unknown" "$UNK_CODEX" CODEX_SHELL=1 ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 \
  -- --writer-model 'x;y'
for _cfg in cfg-unterminated cfg-blank cfg-space cfg-equals cfg-glob cfg-semicolon cfg-garbage; do
  expect_route "codex, malformed config.toml ($_cfg): writer unknown, no crash" "$UNK_CODEX" CODEX_SHELL=1 "CODEX_HOME=$T/$_cfg"
done
# The library's contract is "status 0 = a model printed"; a library that broke it (status 0, nothing on stdout)
# must still leave the writer unknown, never an empty value. The tree is self-contained and repo-shaped: the
# real library copied in as real.sh (so ITS registry lookup finds this tree's own registry), and the library
# the router loads = real.sh + the broken zms_codex_host_model.
mkdir -p "$T/emptyhost/scripts/lib" "$T/emptyhost/skills" "$T/emptyhost/shared/includes" || die "cannot create the emptyhost layout"
cp "$ROUTE" "$T/emptyhost/scripts/reviewer-model-route.sh" && cp "$LIB" "$T/emptyhost/scripts/lib/real.sh" \
  && cp "$REGISTRY" "$T/emptyhost/shared/includes/model-registry.sh" || die "cannot populate the emptyhost layout"
printf '. %q\nzms_codex_host_model() { return 0; }\n' "$T/emptyhost/scripts/lib/real.sh" > "$T/emptyhost/scripts/lib/model-subprocess.sh" \
  || die "cannot write the emptyhost library"
run_router "$T/emptyhost/scripts/reviewer-model-route.sh" CODEX_SHELL=1
check "codex, a host-model lookup that succeeds with EMPTY output: writer unknown" 0 "$UNK_CODEX" ""

# ── 5. --fallback: the in-family row, whatever is installed (K3) ─────────────
echo "-- 5. --fallback"
expect_route "--fallback, claude/opus (codex available): sonnet, in-family-fallback" \
  "$(row claude opus strong_primary review-alt sonnet in-family-fallback)" "${CL[@]}" CLAUDE_MODEL=opus "ZUVO_CODEX_BIN=$SC" -- --fallback
expect_route "--fallback, claude/sonnet: opus, in-family-fallback" \
  "$(row claude sonnet strong_alt review-primary opus in-family-fallback)" "${CL[@]}" CLAUDE_MODEL=sonnet "ZUVO_CODEX_BIN=$SC" -- --fallback
expect_route "--fallback, claude/haiku (codex missing): opus, in-family-fallback" \
  "$(row claude haiku small review-primary opus in-family-fallback)" "${CL[@]}" CLAUDE_MODEL=haiku -- --fallback
expect_route "--fallback, claude-opus-5-5 (full id): sonnet, in-family-fallback" \
  "$(row claude claude-opus-5-5 strong_primary review-alt sonnet in-family-fallback)" "${CL[@]}" CLAUDE_MODEL=claude-opus-5-5 -- --fallback
expect_route "--fallback, claude, writer UNKNOWN: review-alt/sonnet, unknown-writer-model (writer assumed opus)" \
  "$(row claude unknown unknown review-alt sonnet unknown-writer-model)" "${CL[@]}" "ZUVO_CODEX_BIN=$SC" -- --fallback
expect_route "--fallback, claude, writer unknown, codex missing: the same defined row" \
  "$(row claude unknown unknown review-alt sonnet unknown-writer-model)" "${CL[@]}" -- --fallback
expect_route "--fallback, codex/$R_PRIMARY (claude available): registry review-alt, in-family-fallback" \
  "$(row codex "$R_PRIMARY" strong_primary review-alt "$R_REVIEW_ALT" in-family-fallback)" CODEX_SHELL=1 \
  "ZUVO_CODEX_MODEL=$R_PRIMARY" "ZUVO_CLAUDE_BIN=$SL" -- --fallback
expect_route "--fallback, codex/$R_ALT: registry primary, in-family-fallback" \
  "$(row codex "$R_ALT" strong_alt review-primary "$R_PRIMARY" in-family-fallback)" CODEX_SHELL=1 \
  "ZUVO_CODEX_MODEL=$R_ALT" "ZUVO_CLAUDE_BIN=$SL" -- --fallback
expect_route "--fallback, codex, NO writer hint: review-alt = registry review-alt, unknown-writer-model" \
  "$UNK_CODEX" CODEX_SHELL=1 "ZUVO_CLAUDE_BIN=$SL" -- --fallback
expect_route "--fallback, codex, no writer hint, claude missing: the same defined row" \
  "$UNK_CODEX" "__CFBundleIdentifier=com.openai.codex" -- --fallback
# The override gate is not consulted for --fallback: the defaults never set ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE
# (every --fallback case in this file runs without it); these two name both states explicitly.
expect_route "--fallback with ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE UNSET (the harness never sets it): routes" \
  "$(row claude opus strong_primary review-alt sonnet in-family-fallback)" "${CL[@]}" CLAUDE_MODEL=opus -- --fallback
expect_route "--fallback with ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=0: routes the same" \
  "$(row claude opus strong_primary review-alt sonnet in-family-fallback)" "${CL[@]}" CLAUDE_MODEL=opus \
  ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=0 -- --fallback

# The router's own working variables are set before they are read: an environment that exports them — the six
# contract keys included — changes nothing (the in-family pair, the assumed row, the flags, the overrides,
# the charset). The clean run is checked like every other run.
POISON=(if_model=evil if_lane=evil FALLBACK=1 PLATFORM_OVERRIDE=cursor WRITER_OVERRIDE=evil platform=cursor
        writer_model=evil writer_lane=evil reviewer_lane=evil reviewer_model=evil routing_status=ok ID_ALNUM=x REGISTRY_IDS=)
for _h in "CLAUDECODE=1 CLAUDE_MODEL=opus" "CLAUDECODE=1" "CODEX_SHELL=1 ZUVO_CODEX_MODEL=$R_PRIMARY"; do
  # shellcheck disable=SC2086  # one VAR=value per word, by design
  run_route $_h
  check "exported internals [$_h]: the clean run" 0 SIX ""
  cp "$T/out" "$T/clean-answer"
  # shellcheck disable=SC2086
  run_route $_h "${POISON[@]}"
  check "exported internals [$_h]: the poisoned run keeps the contract" 0 SIX ""
  if cmp -s "$T/clean-answer" "$T/out"; then ok "exported internals [$_h]: the answer is the clean run's, byte for byte"
  else bad "exported internals [$_h]: answer [$(oneline "$(cat "$T/out")")] differs from the clean run [$(oneline "$(cat "$T/clean-answer")")]"; fi
done
# A PLAUSIBLE poison: the six keys exported as a complete, well-formed Claude cross-vendor answer, on a Codex host
# whose correct answer differs in EVERY key. Only a router that ignores them all can pass.
_want_codex="$(row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model)"
_poison=(platform=claude writer_model=opus writer_lane=strong_primary reviewer_lane=cross-vendor
         "reviewer_model=$R_PRIMARY" routing_status=ok)
_same=""
for _kv in "${_poison[@]}"; do
  case "$_want_codex" in *"$_kv"*) _same="$_same $_kv" ;; esac
done
expect_eq "plausible poison: every exported key differs from the answer the router must compute" "" "$_same"
expect_route "plausible poison: a Codex host ignores a complete exported Claude answer" "$_want_codex" CODEX_SHELL=1 "${_poison[@]}"

# ── 5b. reviewer_model is NEVER `unknown` on a Claude or Codex host ───────────
# Every host x writer x seam x flag combination — writer hints carrying `;`, a CR or a LF included — with the
# EXACT answer expected for each, byte for byte, derived from the routing rules:
#   the other vendor's CLI present, no --fallback -> cross-vendor / the registry id / ok
#   otherwise, a writer with an in-family lane    -> that row, in-family-fallback (--fallback) or
#                                                    cross-vendor-unavailable
#   otherwise (unknown writer)                     -> the assumed row, unknown-writer-model
# The reviewer_model field is also parsed on its own: never `unknown`, never empty.
echo "-- 5b. sweep: every Claude/Codex host x writer x seam x flag, exact rows"
_n=0; _bad_rows=""; _hosts=0
# sweep_host <kind> <writer_model> <writer_lane> <in-family lane> <in-family model> -- <env...>
sweep_host() {
  local kind="$1" wm="$2" wl="$3" il="$4" im="$5" seam flag want xv am
  shift 5; [ "${1:-}" = -- ] && shift
  if [ "$kind" = claude ]; then xv="$R_PRIMARY"; am=sonnet; else xv="$R_OPUS"; am="$R_REVIEW_ALT"; fi
  _hosts=$((_hosts + 1))
  for seam in on off; do
    for flag in default --fallback; do
      _n=$((_n + 1))
      if [ "$seam" = on ] && [ "$flag" = default ]; then want="$(row "$kind" "$wm" "$wl" cross-vendor "$xv" ok)"
      elif [ -n "$im" ] && [ "$flag" = --fallback ]; then want="$(row "$kind" "$wm" "$wl" "$il" "$im" in-family-fallback)"
      elif [ -n "$im" ]; then want="$(row "$kind" "$wm" "$wl" "$il" "$im" cross-vendor-unavailable)"
      else want="$(row "$kind" "$wm" "$wl" review-alt "$am" unknown-writer-model)"; fi
      local seams=("ZUVO_CODEX_BIN=/nonexistent" "ZUVO_CLAUDE_BIN=/nonexistent")
      [ "$seam" = off ] || seams=("ZUVO_CODEX_BIN=$SC" "ZUVO_CLAUDE_BIN=$SL")
      if [ "$flag" = --fallback ]; then run_route "$@" "${seams[@]}" -- --fallback; else run_route "$@" "${seams[@]}"; fi
      check "sweep [$kind $(printf '%q' "$*") | seam $seam | $flag]" 0 "$want" ""
      case "$(field reviewer_model)" in
        unknown|"") _bad_rows="$_bad_rows [$kind $(printf '%q' "$*") | seam $seam | $flag]" ;;
      esac
    done
  done
}
sweep_host claude unknown unknown "" "" -- CLAUDECODE=1
sweep_host claude opus strong_primary review-alt sonnet -- CLAUDECODE=1 CLAUDE_MODEL=opus
sweep_host claude claude-mystery-9 unknown "" "" -- CLAUDECODE=1 CLAUDE_MODEL=claude-mystery-9
sweep_host claude sonnet strong_alt review-primary opus -- CLAUDECODE=1 CLAUDE_MODEL=sonnet
sweep_host claude unknown unknown "" "" -- CLAUDECODE=1 'CLAUDE_MODEL=x;y'
sweep_host claude unknown unknown "" "" -- CLAUDECODE=1 $'CLAUDE_MODEL=op\nus'
sweep_host claude unknown unknown "" "" -- CLAUDECODE=1 $'CLAUDE_MODEL=op\rus'
sweep_host codex unknown unknown "" "" -- CODEX_SHELL=1
sweep_host codex "$R_ALT" strong_alt review-primary "$R_PRIMARY" -- CODEX_SANDBOX=x "ZUVO_CODEX_MODEL=$R_ALT"
sweep_host codex "$R_ALT" strong_alt review-primary "$R_PRIMARY" -- CODEX_SHELL=1 "CODEX_HOME=$T/codex-luna"
sweep_host codex gpt-mystery-9 unknown "" "" -- CODEX_SHELL=1 ZUVO_CODEX_MODEL=gpt-mystery-9
sweep_host codex unknown unknown "" "" -- CODEX_SHELL=1 "CODEX_HOME=$T/cfg-unterminated"
sweep_host codex unknown unknown "" "" -- CODEX_SHELL=1 'ZUVO_CODEX_MODEL=gpt;6'
sweep_host codex unknown unknown "" "" -- CODEX_SHELL=1 $'ZUVO_CODEX_MODEL=gpt\r6'
expect_eq "sweep: it ran every row (14 hosts x 2 seams x 2 flags)" "14|56" "$_hosts|$_n"
expect_eq "sweep: in none of the $_n Claude/Codex rows is reviewer_model unknown or empty" "" "$_bad_rows"

# ── 6. Registry-driven ids (K10) ─────────────────────────────────────────────
echo "-- 6. registry"
expect_route "registry swap: ZUVO_MODEL_CODEX_PRIMARY=gpt-test-x is the Claude host's reviewer" \
  "$(row claude opus strong_primary cross-vendor gpt-test-x ok)" "${CL[@]}" CLAUDE_MODEL=opus "ZUVO_CODEX_BIN=$SC" \
  ZUVO_MODEL_CODEX_PRIMARY=gpt-test-x
expect_route "registry swap: ZUVO_MODEL_CLAUDE_REVIEWER_OPUS=claude-test-y is the Codex host's reviewer" \
  "$(row codex "$R_PRIMARY" strong_primary cross-vendor claude-test-y ok)" CODEX_SHELL=1 "ZUVO_CODEX_MODEL=$R_PRIMARY" \
  "ZUVO_CLAUDE_BIN=$SL" ZUVO_MODEL_CLAUDE_REVIEWER_OPUS=claude-test-y
expect_route "registry swap: ZUVO_MODEL_CODEX_REVIEW_ALT=gpt-test-alt is the Codex in-family review-alt" \
  "$(row codex "$R_PRIMARY" strong_primary review-alt gpt-test-alt in-family-fallback)" CODEX_SHELL=1 \
  "ZUVO_CODEX_MODEL=$R_PRIMARY" ZUVO_MODEL_CODEX_REVIEW_ALT=gpt-test-alt -- --fallback
expect_route "registry swap: the writer lanes follow the registry too (primary=gpt-test-x writer -> review-alt)" \
  "$(row codex gpt-test-x strong_primary review-alt "$R_REVIEW_ALT" cross-vendor-unavailable)" CODEX_SHELL=1 \
  ZUVO_CODEX_MODEL=gpt-test-x ZUVO_MODEL_CODEX_PRIMARY=gpt-test-x
expect_route "a registry id no known client serves is never routed as ok" \
  "$(row claude opus strong_primary review-alt sonnet cross-vendor-unavailable)" "${CL[@]}" CLAUDE_MODEL=opus \
  "ZUVO_CODEX_BIN=$SC" ZUVO_MODEL_CODEX_PRIMARY=gemini-not-codex
expect_route "a 'cross-vendor' id served by the host's OWN vendor is never cross-vendor (claude id on a Claude host)" \
  "$(row claude opus strong_primary review-alt sonnet cross-vendor-unavailable)" "${CL[@]}" CLAUDE_MODEL=opus \
  "ZUVO_CODEX_BIN=$SC" "ZUVO_CLAUDE_BIN=$SL" ZUVO_MODEL_CODEX_PRIMARY=claude-opus-5
expect_route "... nor a codex id on a Codex host" \
  "$(row codex "$R_PRIMARY" strong_primary review-alt "$R_REVIEW_ALT" cross-vendor-unavailable)" CODEX_SHELL=1 \
  "ZUVO_CODEX_MODEL=$R_PRIMARY" "ZUVO_CODEX_BIN=$SC" "ZUVO_CLAUDE_BIN=$SL" ZUVO_MODEL_CLAUDE_REVIEWER_OPUS=gpt-6-x
expect_route "same-model guard covers the labelled fallback too: review-alt == writer is same-model-fallback" \
  "$(row codex "$R_PRIMARY" strong_primary same-model-fallback "$R_PRIMARY" same-model-fallback)" CODEX_SHELL=1 \
  "ZUVO_CODEX_MODEL=$R_PRIMARY" "ZUVO_MODEL_CODEX_REVIEW_ALT=$R_PRIMARY" -- --fallback
# A registry id must be ONE plain token — [A-Za-z0-9][A-Za-z0-9._:-]* — or the route fails closed: it is
# printed into the six-key contract and used as a `case` pattern / CLI argument downstream.
_nl='gpt
x'
for _bad in "ZUVO_MODEL_CODEX_PRIMARY=gpt 6" "ZUVO_MODEL_CLAUDE_REVIEWER_OPUS=a=b" "ZUVO_MODEL_CODEX_PRIMARY=gpt-*" \
            'ZUVO_MODEL_CODEX_PRIMARY=gpt-$x' 'ZUVO_MODEL_CODEX_REVIEW_ALT=gpt-`id`' "ZUVO_MODEL_CODEX_ALT=$_nl" \
            "ZUVO_MODEL_CODEX_SMALL=-gpt" "ZUVO_MODEL_CODEX_PRIMARY=gpt[6]" "ZUVO_MODEL_CLAUDE_REVIEWER_OPUS=claude/opus"; do
  for _h in "CLAUDECODE=1 CLAUDE_MODEL=opus ZUVO_CODEX_BIN=$SC" "CODEX_SHELL=1 ZUVO_CODEX_MODEL=$R_PRIMARY ZUVO_CLAUDE_BIN=$SL"; do
    # shellcheck disable=SC2086  # one VAR=value per word, by design
    run_route $_h "$_bad"
    check "registry value [$(oneline "$_bad")] on [${_h%% *}]: the fail-closed sentinel, stderr names the variable" 0 \
      "$ROUTING_FAILED_ROW" "prefix:reviewer-model-route: ${_bad%%=*} from "
  done
done
# ... and on the --fallback arm and the override arm too: the registry is read before any route is chosen.
for _bad in "ZUVO_MODEL_CODEX_PRIMARY=gpt 6" 'ZUVO_MODEL_CODEX_REVIEW_ALT=gpt-`id`' "ZUVO_MODEL_CLAUDE_REVIEWER_OPUS=a=b"; do
  run_route CLAUDECODE=1 CLAUDE_MODEL=opus "$_bad" -- --fallback
  check "registry value [$_bad], --fallback arm: the fail-closed sentinel" 0 "$ROUTING_FAILED_ROW" \
    "prefix:reviewer-model-route: ${_bad%%=*} from "
  run_route ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 "ZUVO_CLAUDE_BIN=$SL" "$_bad" -- --platform codex --writer-model "$R_PRIMARY"
  check "registry value [$_bad], override arm (--platform codex): the fail-closed sentinel" 0 "$ROUTING_FAILED_ROW" \
    "prefix:reviewer-model-route: ${_bad%%=*} from "
done
# The router source names none of the registry's reviewer ids: they are READ, never restated (01c1727e).
# Whole tokens (split on anything outside the id charset), not substrings: `gpt-6-sol-legacy` is not a copy of
# `gpt-6-sol`, while `gpt-6-sol` standing alone anywhere — code, a case arm or a comment — is.
_lit=""
for _id in "$R_PRIMARY" "$R_ALT" "$R_REVIEW_ALT" "$R_SMALL" "$R_OPUS"; do
  if LC_ALL=C awk -v id="$_id" '{ n = split($0, w, /[^A-Za-z0-9._:-]+/); for (j = 1; j <= n; j++) if (w[j] == id) f = 1 }
       END { exit(f ? 0 : 1) }' "$ROUTE"; then _lit="$_lit $_id"; fi
done
expect_eq "the router source holds no literal copy of a registry id" "" "$_lit"
# No registry reachable: a router + library copy with no repo root around it, run in EXACTLY run_route's
# environment (HOME=$T/home, which has a .zuvo/ but no model-registry.sh). A Claude/Codex host fails CLOSED
# to the env-compat.md sentinel and says why; other hosts need no registry and are unchanged. The control
# layout next to it differs ONLY by the registry (a repo-shaped root: skills/ + shared/includes/) and routes.
mkdir -p "$T/noreg/scripts/lib" "$T/withreg/scripts/lib" "$T/withreg/skills" "$T/withreg/shared/includes" \
  || die "cannot create the registry layouts"
for _d in noreg withreg; do
  cp "$ROUTE" "$T/$_d/scripts/reviewer-model-route.sh" && cp "$LIB" "$T/$_d/scripts/lib/model-subprocess.sh" \
    || die "cannot copy the router/library into $_d"
done
cp "$REGISTRY" "$T/withreg/shared/includes/model-registry.sh" || die "cannot copy the registry into withreg"
[ ! -e "$T/home/.zuvo/model-registry.sh" ] || die "the sandbox HOME holds a registry: the no-registry case would be vacuous"
# ... and no directory above the copied router holds one either (the library's repo-root lookup walks up from
# its own dir): checked for EVERY ancestor, not only the one the library uses today.
_d="$T/noreg/scripts"
while :; do
  [ ! -e "$_d/shared/includes/model-registry.sh" ] || die "an ancestor of the no-registry router holds a registry ($_d)"
  [ "$_d" = / ] && break
  _d="${_d%/*}"; [ -n "$_d" ] || _d=/
done
NOREG="$T/noreg/scripts/reviewer-model-route.sh"; WITHREG="$T/withreg/scripts/reviewer-model-route.sh"
run_router "$NOREG" "${CL[@]}" CLAUDE_MODEL=opus "ZUVO_CODEX_BIN=$SC"
check "no registry, Claude host: the fail-closed sentinel, stderr names model-registry.sh" 0 "$ROUTING_FAILED_ROW" "prefix:reviewer-model-route: shared/includes/model-registry.sh (the reviewer model ids) not found"
run_router "$NOREG" CODEX_SHELL=1 "ZUVO_CODEX_MODEL=$R_PRIMARY" "ZUVO_CLAUDE_BIN=$SL"
check "no registry, Codex host: the fail-closed sentinel, stderr names model-registry.sh" 0 "$ROUTING_FAILED_ROW" "prefix:reviewer-model-route: shared/includes/model-registry.sh (the reviewer model ids) not found"
run_router "$NOREG" "${CL[@]}" CLAUDE_MODEL=opus -- --fallback
check "no registry, Claude host, --fallback: the fail-closed sentinel too" 0 "$ROUTING_FAILED_ROW" "prefix:reviewer-model-route: shared/includes/model-registry.sh (the reviewer model ids) not found"
run_router "$NOREG" GEMINI_MODEL=gemini-3-flash
check "no registry: an Antigravity row is unaffected" 0 "$(row antigravity gemini-3-flash small review-primary gemini-3.1-pro-high ok)" ""
run_router "$WITHREG" "${CL[@]}" CLAUDE_MODEL=opus "ZUVO_CODEX_BIN=$SC"
check "control: the same copy WITH a registry beside it routes cross-vendor" 0 "$(row claude opus strong_primary cross-vendor "$R_PRIMARY" ok)" ""

# ── 7. PATH=/nonexistent and SMOKE-C1 ─────────────────────────────────────────
echo "-- 7. PATH=/nonexistent, SMOKE-C1"
expect_route "PATH=/nonexistent: Claude host still routes cross-vendor" \
  "$(row claude opus strong_primary cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" CLAUDE_MODEL=opus "ZUVO_CODEX_BIN=$SC" PATH=/nonexistent
expect_route "PATH=/nonexistent: Codex host still routes cross-vendor" \
  "$(row codex unknown unknown cross-vendor "$R_OPUS" ok)" CODEX_SHELL=1 "ZUVO_CLAUDE_BIN=$SL" PATH=/nonexistent
expect_route "PATH=/nonexistent: --fallback with an unknown writer" \
  "$(row claude unknown unknown review-alt sonnet unknown-writer-model)" "${CL[@]}" PATH=/nonexistent -- --fallback
if [ "$RBASH" != /bin/bash ] && [ -x /bin/bash ]; then
  _save="$RBASH"; RBASH=/bin/bash
  expect_route "PATH=/nonexistent under /bin/bash itself" \
    "$(row claude unknown unknown cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" "ZUVO_CODEX_BIN=$SC" PATH=/nonexistent
  RBASH="$_save"
fi
# SMOKE-C1 (plan, Whole-feature Smoke Proofs): the sentinel codex, PATH=/usr/bin:/bin, CLAUDECODE=1, no
# CLAUDE_MODEL — the writer is unknown and the reviewer is Codex, and the router ran nothing.
expect_route "SMOKE-C1: CLAUDECODE=1 + sentinel codex + PATH=/usr/bin:/bin" \
  "$(row claude unknown unknown cross-vendor "$R_PRIMARY" ok)" "${CL[@]}" "ZUVO_CODEX_BIN=$SC" PATH=/usr/bin:/bin
expect_route "SMOKE-C1: ZUVO_CODEX_BIN=/nonexistent -> unknown-writer-model (a defined reviewer)" \
  "$(row claude unknown unknown review-alt sonnet unknown-writer-model)" "${CL[@]}" PATH=/usr/bin:/bin
expect_route "SMOKE-C1: --fallback (known writer) -> in-family-fallback" \
  "$(row claude opus strong_primary review-alt sonnet in-family-fallback)" "${CL[@]}" CLAUDE_MODEL=opus "ZUVO_CODEX_BIN=$SC" \
  PATH=/usr/bin:/bin -- --fallback

# ── 8. Cursor / Antigravity / Kimi / unknown: byte-identical (X7) ────────────
# Golden rows captured from the router BEFORE this change (commit b7093ff2), for the PATHs below. Each is
# asserted plain, with --fallback, and with both client seams pointing at the sentinels: none of the three
# may change a row on these hosts.
echo "-- 8. other hosts unchanged (X7)"
mkdir -p "$T/p-none" "$T/p-agy" "$T/home/.kimi-code/bin" || die "cannot create the X7 PATH dirs"
printf '#!/bin/sh\nprintf "%%s\\n" agy >> "%s"\n' "$MARKS" > "$T/p-agy/agy" && chmod +x "$T/p-agy/agy" || die "cannot write the agy stub"
KP="$T/home/.kimi-code/bin"
# x7 <label> <want-block> <VAR=value...> — plain, --fallback, seams set.
x7() {
  local label="$1" want="$2"; shift 2
  expect_route "X7 $label" "$want" "$@"
  expect_route "X7 $label (--fallback)" "$want" "$@" -- --fallback
  expect_route "X7 $label (seams at the sentinels)" "$want" "ZUVO_CODEX_BIN=$SC" "ZUVO_CLAUDE_BIN=$SL" "$@"
}
x7 "cursor composer-2.5-fast, no client" "$(row cursor composer-2.5-fast small same-model-fallback composer-2.5-fast same-model-fallback)" \
  "PATH=$T/p-none" VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/probe CURSOR_AGENT_MODEL=composer-2.5-fast
x7 "cursor composer-2.5, agy on PATH" "$(row cursor composer-2.5 strong_primary review-alt agy ok)" \
  "PATH=$T/p-agy" VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/probe CURSOR_AGENT_MODEL=composer-2.5
x7 "cursor gpt-5.5, codex stub on PATH" "$(row cursor gpt-5.5 unknown review-alt codex ok)" \
  "PATH=$T/stubs" VSCODE_GIT_ASKPASS_MAIN=/Applications/Cursor.app/probe CURSOR_AGENT_MODEL=gpt-5.5
x7 "antigravity gemini-3.1-pro-high" "$(row antigravity gemini-3.1-pro-high strong_primary review-alt gemini-3.1-pro-low ok)" \
  GEMINI_MODEL=gemini-3.1-pro-high
x7 "antigravity session only (default writer)" "$(row antigravity gemini-3.1-pro-low strong_alt review-primary gemini-3.1-pro-high ok)" \
  ANTIGRAVITY_SESSION_ID=abc
x7 "antigravity generic gemini" "$(row antigravity gemini strong_primary same-model-fallback gemini same-model-fallback)" \
  GEMINI_MODEL=gemini
x7 "kimi default, no key, no client" "$(row kimi kimi-code strong_primary same-model-fallback kimi-code same-model-fallback)" \
  "PATH=$KP"
x7 "kimi default, API key" "$(row kimi kimi-code strong_primary review-alt kimi-k2.6 ok)" "PATH=$KP" MOONSHOT_API_KEY=stub
x7 "kimi k2.6, API key" "$(row kimi kimi-k2.6 strong_alt review-alt kimi-code ok)" "PATH=$KP" MOONSHOT_API_KEY=stub \
  ZUVO_KIMI_CLI_MODEL=kimi-k2.6
x7 "kimi, no key, agy on PATH" "$(row kimi kimi-code strong_primary review-alt agy ok)" "PATH=$KP:$T/p-agy"
x7 "unknown platform" "$(row unknown unknown unknown same-model-fallback unknown unknown-writer-model)"
x7 "unknown platform, PATH=/nonexistent" "$(row unknown unknown unknown same-model-fallback unknown unknown-writer-model)" \
  PATH=/nonexistent

# ── 8b. Writer-id shape, the same-model suffix, the literal `unknown` ─────────
echo "-- 8b. writer-id shape, same-model suffix, literal unknown"
# A writer id carries brackets only as ONE trailing context suffix of letters and digits ([1m], [200k]).
# Anything else with a bracket — unbalanced, empty, embedded, repeated, or with other characters inside — is
# not one writer token: unknown (codex missing, so the answer shows the assumed row).
for _w in 'opus[' 'opus]' 'op[1m]us' 'opus[]' 'opus[1m][2m]' '[1m]opus' 'opus[1-m]' 'opus[1m]x'; do
  expect_route "writer [$_w]: not one writer token -> unknown" \
    "$(row claude unknown unknown review-alt sonnet unknown-writer-model)" CLAUDECODE=1 "CLAUDE_MODEL=$_w"
done
expect_route "writer [claude-sonnet-5[200k]]: one well-formed suffix -> accepted, the sonnet lane" \
  "$(row claude 'claude-sonnet-5[200k]' strong_alt review-primary opus cross-vendor-unavailable)" CLAUDECODE=1 'CLAUDE_MODEL=claude-sonnet-5[200k]'
expect_route "codex writer [gpt-6-sol[]: unknown" \
  "$(row codex unknown unknown review-alt "$R_REVIEW_ALT" unknown-writer-model)" CODEX_SHELL=1 'ZUVO_CODEX_MODEL=gpt-6-sol['
expect_route "--writer-model 'opus[1m][2m]' (override on): unknown" \
  "$(row claude unknown unknown review-alt sonnet unknown-writer-model)" CLAUDECODE=1 ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 \
  -- --writer-model 'opus[1m][2m]'
# A CR or a LF inside a Claude writer is malformed (never silently deleted to form another id); ONE trailing CR
# — a CRLF line ending — is the only one stripped.
expect_route "CLAUDE_MODEL with an embedded CR ('op<CR>us'): unknown, not 'opus'" \
  "$(row claude unknown unknown review-alt sonnet unknown-writer-model)" CLAUDECODE=1 $'CLAUDE_MODEL=op\rus'
expect_route "CLAUDE_MODEL with an embedded LF ('op<LF>us'): unknown" \
  "$(row claude unknown unknown review-alt sonnet unknown-writer-model)" CLAUDECODE=1 $'CLAUDE_MODEL=op\nus'
expect_route "CLAUDE_MODEL with a trailing CR ('opus<CR>', a CRLF ending): opus" \
  "$(row claude opus strong_primary review-alt sonnet cross-vendor-unavailable)" CLAUDECODE=1 $'CLAUDE_MODEL=opus\r'
expect_route "CLAUDE_MODEL='a;b': unknown" \
  "$(row claude unknown unknown review-alt sonnet unknown-writer-model)" CLAUDECODE=1 'CLAUDE_MODEL=a;b'
# The same-model guard compares the models WITHOUT a context suffix: a writer `<id>[1m]` reviewed by `<id>` is
# the same model reviewing itself, never ok.
expect_route "same model with a suffix: Claude writer ${R_PRIMARY}[1m] vs cross-vendor $R_PRIMARY -> same-model-fallback" \
  "$(row claude "${R_PRIMARY}[1m]" unknown same-model-fallback "$R_PRIMARY" same-model-fallback)" CLAUDECODE=1 \
  "CLAUDE_MODEL=${R_PRIMARY}[1m]" "ZUVO_CODEX_BIN=$SC"
expect_route "same model with a suffix: Codex writer ${R_OPUS}[1m] vs cross-vendor $R_OPUS -> same-model-fallback" \
  "$(row codex "${R_OPUS}[1m]" unknown same-model-fallback "$R_OPUS" same-model-fallback)" CODEX_SHELL=1 \
  "ZUVO_CODEX_MODEL=${R_OPUS}[1m]" "ZUVO_CLAUDE_BIN=$SL"
# The literal `unknown` in a writer variable is NOT a writer, and not a host signal either: every pair below
# must answer byte for byte like the run without that variable.
# same_as <label> <env of run A> -- <env of run B> — both runs checked, then compared.
same_as() {
  local label="$1" a=() b=(); shift
  while [ $# -gt 0 ] && [ "$1" != -- ]; do a+=("$1"); shift; done
  shift; b=("$@")
  run_route ${a[@]+"${a[@]}"}; check "$label: run with the literal" 0 SIX ""; cp "$T/out" "$T/same-a"
  run_route ${b[@]+"${b[@]}"}; check "$label: run without it" 0 SIX ""
  if cmp -s "$T/same-a" "$T/out"; then ok "$label: byte-identical"
  else bad "$label: [$(oneline "$(cat "$T/same-a")")] vs [$(oneline "$(cat "$T/out")")]"; fi
}
same_as "CLAUDE_MODEL=unknown on a Claude host" CLAUDECODE=1 CLAUDE_MODEL=unknown -- CLAUDECODE=1
same_as "CLAUDE_MODEL=unknown alone (no host signal)" CLAUDE_MODEL=unknown --
same_as "ZUVO_CODEX_MODEL=unknown falls through to the config writer" CODEX_SHELL=1 ZUVO_CODEX_MODEL=unknown "CODEX_HOME=$T/codex-luna" \
  -- CODEX_SHELL=1 "CODEX_HOME=$T/codex-luna"
same_as "CODEX_MODEL=unknown falls through to the config writer" CODEX_SHELL=1 CODEX_MODEL=unknown "CODEX_HOME=$T/codex-luna" \
  -- CODEX_SHELL=1 "CODEX_HOME=$T/codex-luna"
same_as "ZUVO_CODEX_MODEL=unknown alone (no host signal)" ZUVO_CODEX_MODEL=unknown --

# ── 9. Argument errors (B-20260928-ROUTE-PLATFORM-NOVALUE) ───────────────────
echo "-- 9. argument errors"
expect_eq "the usage reference starts with the documented Usage line" \
  "Usage: reviewer-model-route.sh [--fallback] [--platform <name>] [--writer-model <model>]" "$(awk 'NR == 1' "$T/usage.txt")"
for _flag in --platform --writer-model; do
  for _v in LAST --fallback "" -x; do
    if [ "$_v" = LAST ]; then run_route ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 -- "$_flag"
    else run_route ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 -- "$_flag" "$_v"; fi
    check "$_flag given [${_v}] as its value: exit 2, no stdout, the reason and the usage on stderr" 2 - \
      "line:reviewer-model-route: $_flag requires a value
usage"
  done
done
run_route ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 -- --platform --writer-model opus
check "--platform --writer-model opus: --platform has no value (exit 2)" 2 - "line:reviewer-model-route: --platform requires a value
usage"
run_route ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 -- --writer-model opus --platform
check "--platform last after a complete --writer-model: exit 2" 2 - "line:reviewer-model-route: --platform requires a value
usage"
run_route -- --bogus
check "an unknown argument is still exit 2, named on stderr" 2 - "line:Unknown argument: --bogus
usage"
run_route -- --platform claude
check "--platform without the override gate is still refused (exit 2)" 2 - "line:Override flags require ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1"
expect_route "--platform claude --writer-model opus (override on): the override arm routes cross-vendor" \
  "$(row claude opus strong_primary cross-vendor "$R_PRIMARY" ok)" ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1 "ZUVO_CODEX_BIN=$SC" \
  -- --platform claude --writer-model opus
run_route -- --help
check "--help: exit 0, silent stderr" 0 ANY ""
# scan <label> <want: found|absent> <awk-program> — one awk pass over $T/out; awk's status 0 = found, 1 = not
# found, anything else (an unreadable file, a bad program) FAILS the check whatever was wanted.
scan() {
  local label="$1" want="$2" prog="$3" rc
  LC_ALL=C awk "$prog" "$T/out"; rc=$?
  case "$want:$rc" in
    found:0|absent:1) ok "$label" ;;
    found:1)  bad "$label — not found in [$(oneline "$(cat "$T/out")")]" ;;
    absent:0) bad "$label — found in [$(oneline "$(cat "$T/out")")]" ;;
    *)        bad "$label — the scan itself failed (awk status $rc)" ;;
  esac
}
scan "--help documents --fallback" found 'index($0, "--fallback") { f = 1 } END { exit(f ? 0 : 1) }'
scan "--help lists the routing_status key" found '$0 ~ /^[[:space:]]*routing_status$/ { f = 1 } END { exit(f ? 0 : 1) }'
scan "--help prints no routing answer (no KEY=VALUE contract line)" absent \
  '/^(platform|writer_model|writer_lane|reviewer_lane|reviewer_model|routing_status)=/ { f = 1 } END { exit(f ? 0 : 1) }'
# Control: scan() must FAIL when awk cannot read the file — it may never read as "absent". Run in a subshell
# with its own counters, so the deliberate failure is observed, not counted.
mv "$T/out" "$T/help-out"
if ( PASS=0; FAIL=0; scan "unreadable" absent 'END { exit 1 }' >/dev/null 2>&1; [ "$FAIL" -eq 1 ] ); then
  ok "control: a scan of an unreadable stdout fails instead of passing as 'absent'"
else
  bad "control: a scan of an unreadable stdout passed"
fi
mv "$T/help-out" "$T/out"

# Every run was checked; no sentinel wrote after its run was checked; nothing a run started is still alive.
expect_eq "harness: the last run was checked" 0 "$PENDING"
expect_eq "no sentinel ran after its run was checked (late entries in $MARKS)" "$MARKS_CHECKED" "$(marks)"
_left="$(sentinel_pids | tr '\n' ' ')"
expect_eq "no sentinel or stub process outlived its run" "" "$_left"

echo "=== RESULT ==="
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
