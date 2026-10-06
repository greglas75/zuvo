#!/usr/bin/env bash
# test-adversarial-flag-contract.sh — every adversarial-review flag a skill DOCUMENTS
# must exist in the script's parser, with the arity the docs use.
#
# Regression under contract (2026-08-07 .. 2026-08-09, six ship retros before anyone fixed it).
# skills/review/SKILL.md §1.3 documented the rotation passes as
#     ... | adversarial-review --rotate --mode code --append-artifact "$ADV_PROOF"
# while the parser's arm was `--append-artifact) APPEND_ARTIFACT=true; shift ;;` — no value.
# The path therefore fell through to `*) Unknown argument` → exit 2, so the pass ran NO review
# and wrote NO proof file. The failure surfaced a phase later as a push blocked for "missing
# adversarial proof", which points at the artifact, not at the flag that never ran. Reported from
# uptime #74, i9-farma, rs_be #263, tgm-survey-tester #49, Helper #97 and stages-actions — six
# independent runs, each re-diagnosing it from scratch, because nothing mechanical compared the
# documented command line against the parser.
#
# This test is that comparison. It also catches the phantom-flag class (`--all-providers`, which
# review/SKILL.md warns about in prose) with no prose required.
#
# Scope/limits, stated so a green run is not over-read:
#   - single-line invocations only (a flag split across a `\` continuation is not checked)
#   - only lines where the command token appears BEFORE the flags, so prose that merely mentions
#     a flag in backticks is ignored
#   - tokenization stops at a shell operator (| > >> ; && ||), so `--help | grep -- --multi`
#     checks `--help` and nothing after the pipe
#
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/adversarial-review.sh"
# The parser is in a module: the inventory below reads the program as one text (driver + modules),
# assembled into a file first — a process substitution would hide a failed assembly as an empty inventory.
. "$ROOT/tests/lib/adversarial-driver.sh"
# The (c) runs use the mock-success lane from tests/adversarial/mocks — no installed AI client.
export ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-success

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

if [ ! -f "$SCRIPT" ]; then
  bad "scripts/adversarial-review.sh not found"
  exit 1
fi
PROGRAM_SRC="$(mktemp)" || { bad "mktemp failed"; exit 1; }
_t=""   # (c)'s sandbox; ONE trap removes both — a second `trap … EXIT` would replace this one
trap 'rm -f "$PROGRAM_SRC"; [ -z "$_t" ] || rm -rf "$_t"' EXIT
adv_driver_source "$SCRIPT" > "$PROGRAM_SRC" || { bad "the program text could not be assembled (reason above) — no inventory to check"; exit 1; }

# ─── (a) build the flag inventory from the parser itself ─────────────────────
# Classification comes from what the arm does, not from a hand-kept list here — a list would rot
# exactly like the docs did. VALUE = `shift N` (N ≥ 2) only, BOOL = `shift` only, OPT = both (a flag whose
# value is optional). Arms are `    --flag)` / `    --a|--b)` at the head of the case body.
# One line per flag: <flag> TAB <kind> TAB <values> — how many values its largest `shift N` consumes (N - 1;
# 0 for BOOL; an OPT's optional value counts 1).
INVENTORY="$(awk '
  /^[[:space:]]*--[a-z0-9-]+[|)]/ {
    if (flag != "") { emit() }
    line = $0
    sub(/\).*/, "", line); gsub(/[[:space:]]/, "", line)
    flag = line; body = $0; next
  }
  flag != "" { body = body " " $0 }
  /;;[[:space:]]*$/ && flag != "" { emit() }
  function emit(   kind, n, i, parts, total, two, bare, tmp, maxn, sn) {
    # Count shifts rather than pattern-matching their position: `shift 2` consumes a value,
    # a bare `shift` does not, and an arm holding BOTH is a flag whose value is optional.
    tmp = body
    total = gsub(/shift/, "shift", tmp)
    # `shift 3` and up count too: --record-disposition FP VERDICT consumes two values, and
    # reading it as a bare shift would type it BOOL and flag every documented use as a defect.
    tmp = body
    two = gsub(/shift [2-9]/, "shift N", tmp)
    bare = total - two
    kind = "BOOL"
    if (two > 0 && bare > 0) kind = "OPT"
    else if (two > 0)        kind = "VALUE"
    maxn = 1; tmp = body
    while (match(tmp, /shift [2-9]/)) { sn = substr(tmp, RSTART + 6, 1) + 0; if (sn > maxn) maxn = sn; tmp = substr(tmp, RSTART + RLENGTH) }
    n = split(flag, parts, "|")
    for (i = 1; i <= n; i++) if (parts[i] ~ /^-/) print parts[i] "\t" kind "\t" (two > 0 ? maxn - 1 : 0)
    flag = ""; body = ""
  }
' "$PROGRAM_SRC" | sort -u)"

# `--append-artifact` takes an OPTIONAL value (canonical: `--artifact P --append-artifact`;
# legacy one-arg alias: `--append-artifact P`). The awk heuristic above can only see shifts, so
# pin the three flags whose contract the tests actually depend on, and fail loudly if the parser
# stops agreeing with the pin.
check_kind() {  # check_kind FLAG EXPECTED
  local got
  got="$(printf '%s\n' "$INVENTORY" | awk -F'\t' -v f="$1" '$1==f {print $2}' | head -1)"
  if [ -z "$got" ]; then
    bad "(a) $1 is not a parser arm in adversarial-review.sh"
  elif [ "$got" != "$2" ]; then
    bad "(a) $1 parses as $got, the docs contract says $2"
  else
    pass "(a) $1 → $2"
  fi
}
check_kind --artifact VALUE
check_kind --append-artifact OPT
check_kind --json BOOL
check_kind --record-disposition VALUE   # two values: `shift 3`

# The INDEPENDENT list: every flag ar_parse_args (scripts/lib/adversarial-cli.sh) accepts, written here by
# hand from its contract (--help and the arms' comments), with its kind and how many values it takes. The
# inventory above is derived by awk from the parser it checks, so an arm whose shift count changed WITH its
# documented usage would still agree with the docs; it cannot also agree with this list. Compared both
# ways: a flag added to or removed from the parser, or here, fails — update this list only with the parser.
EXPECTED_FLAGS='--append-artifact OPT 1
--artifact VALUE 1
--context VALUE 1
--diff VALUE 1
--doctor BOOL 0
--dry-run BOOL 0
--effectiveness BOOL 0
--exclude VALUE 1
--exclude-last VALUE 1
--file VALUE 1
--files VALUE 1
--help BOOL 0
--json BOOL 0
--known-finding VALUE 1
--list-providers BOOL 0
--mode VALUE 1
--multi BOOL 0
--no-chunk BOOL 0
--production VALUE 1
--protocol VALUE 1
--provider VALUE 1
--record-disposition VALUE 2
--rotate BOOL 0
--single BOOL 0
--test VALUE 1
-h BOOL 0'
_inv_rows="$(printf '%s\n' "$INVENTORY" | tr '\t' ' ' | LC_ALL=C sort)"
_exp_rows="$(printf '%s\n' "$EXPECTED_FLAGS" | LC_ALL=C sort)"
_only_parser="$(LC_ALL=C comm -13 <(printf '%s\n' "$_exp_rows") <(printf '%s\n' "$_inv_rows") | tr '\n' ';')"
_only_expected="$(LC_ALL=C comm -23 <(printf '%s\n' "$_exp_rows") <(printf '%s\n' "$_inv_rows") | tr '\n' ';')"
[ -z "$_only_parser" ] && pass "(a) every parser arm is in the independent list, with the same kind and value count" \
  || bad "(a) the parser has arms the independent list does not (flag kind values): $_only_parser"
[ -z "$_only_expected" ] && pass "(a) every flag of the independent list is a parser arm, with the same kind and value count" \
  || bad "(a) the independent list has flags the parser does not take that way (flag kind values): $_only_expected"
[ "$(printf '%s\n' "$_inv_rows" | grep -c .)" -eq "$(printf '%s\n' "$_exp_rows" | grep -c .)" ] \
  && pass "(a) the parser has $(printf '%s\n' "$_exp_rows" | grep -c .) flags, as listed" \
  || bad "(a) the parser has $(printf '%s\n' "$_inv_rows" | grep -c .) flags, the list $(printf '%s\n' "$_exp_rows" | grep -c .)"

# ─── (b) documented invocations must type-check against that inventory ───────
kind_of() { printf '%s\n' "$INVENTORY" | awk -F'\t' -v f="$1" '$1==f {print $2}' | head -1; }
# values_of <flag> — how many values the parser's arm consumes (the inventory's third column, which (a)
# proved equal to the independent list).
values_of() { printf '%s\n' "$INVENTORY" | awk -F'\t' -v f="$1" '$1==f {print $3}' | head -1; }

# check_docs <reporter> <file…> — type-check every invocation line in the files. <reporter> is
# called with each defect message; the real run passes `doc_bad`, the canary below a collector,
# so the SAME scanner is proven able to go red. Sets _doc_lines and _doc_files.
check_docs() {
  local reporter="$1" f hit lineno text rest tok k nxt need got i nv; shift
  _doc_lines=0; _doc_files=""
  for f in "$@"; do
    [ -f "$f" ] || continue
    # Only lines that INVOKE the script. `grep -n` keeps the line number for the failure message.
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      lineno="${hit%%:*}"
      text="${hit#*:}"
      # keep only what follows the command token
      rest="${text#*adversarial-review}"
      # a double-quoted string is ONE word, whatever it holds: an operator inside it is not an operator
      # (`--record-disposition "<id>" fixed` must not end at the `>` of the placeholder)
      rest="$(printf '%s' "$rest" | sed 's/"[^"]*"/_quoted_/g')"
      # a trailing `\` continues the command on the next line, which is not checked (see the limits above):
      # it ends this line's tokens, it is no argument
      rest="$(printf '%s' "$rest" | sed 's/[[:space:]]*\\[[:space:]]*$//')"
      # cut at the first shell operator — anything after it is a different command
      rest="$(printf '%s' "$rest" | sed 's/[|;>&].*//')"
      # strip markdown/quoting noise so `--artifact "$P"` tokenizes as two words
      rest="$(printf '%s' "$rest" | tr '`"'"'" '   ')"
      _doc_lines=$((_doc_lines + 1))
      case " $_doc_files " in *" ${f#"$ROOT"/} "*) ;; *) _doc_files="$_doc_files ${f#"$ROOT"/}" ;; esac
      set -f; set -- $rest; set +f   # split on blanks, never glob-expand a token
      while [ "$#" -gt 0 ]; do
        tok="$1"
        # A token that is pure punctuation means the line stopped being a command and became
        # prose ("run `... --doctor`, then read the output"). Stop rather than read the comma
        # as an argument — otherwise every sentence mentioning a flag reads as a defect.
        [ -n "$(printf '%s' "$tok" | tr -d '.,;:()')" ] || break
        case "$tok" in
          --*)
            k="$(kind_of "$tok")"
            nxt="${2:-}"
            # trailing prose punctuation is not an argument
            [ -n "$(printf '%s' "$nxt" | tr -d '.,;:()')" ] || nxt=""
            case "$k" in
              "")
                "$reporter" "(b) ${f#"$ROOT"/}:$lineno documents $tok — no such flag in the parser (phantom flag → exit 2, zero coverage)" ;;
              BOOL)
                case "$nxt" in
                  ""|--*) ;;
                  *) "$reporter" "(b) ${f#"$ROOT"/}:$lineno passes a value to the boolean flag $tok ('$nxt') — the parser rejects it with 'Unknown argument: $nxt' and the whole pass exits 2" ;;
                esac ;;
              VALUE)
                case "$nxt" in
                  ""|--*) "$reporter" "(b) ${f#"$ROOT"/}:$lineno uses $tok with no value — the parser requires one" ;;
                  *)
                    # a flag of several values (--record-disposition FP VERDICT) needs each of them
                    need="$(values_of "$tok")"; got=1; i=3
                    while [ "$got" -lt "${need:-1}" ]; do
                      eval "nv=\${$i:-}"
                      [ -n "$(printf '%s' "$nv" | tr -d '.,;:()')" ] || nv=""
                      case "$nv" in ""|--*) break ;; esac
                      got=$((got + 1)); i=$((i + 1))
                    done
                    [ "$got" -ge "${need:-1}" ] \
                      || "$reporter" "(b) ${f#"$ROOT"/}:$lineno uses $tok with $got of its $need values — the parser requires $need" ;;
                esac ;;
            esac ;;
        esac
        shift
      done
    done <<DOCS
$(grep -n 'adversarial-review' "$f" 2>/dev/null | grep -v 'adversarial-review\.sh"\?$')
DOCS
  done
}
_doc_fails=0
doc_bad() { bad "$1"; _doc_fails=$((_doc_fails + 1)); }

# Canary FIRST: one line per defect class the scanner exists to catch, plus one clean line. A
# tokenizer change that silently stops seeing defects fails here, not in production docs.
_canary_dir="$(mktemp -d)"
cat > "$_canary_dir/canary.md" <<'CANARY'
~/.zuvo/adversarial-review --all-providers --mode code
~/.zuvo/adversarial-review --json yes --mode code
~/.zuvo/adversarial-review --mode code --artifact
~/.zuvo/adversarial-review --json --mode code --artifact "$P" --record-disposition "a.ts:1:x" fixed
run `~/.zuvo/adversarial-review --doctor` , then --no-such-flag in prose
see `~/.zuvo/adversarial-review --doctor` .
CANARY
_canary_msgs=""
canary_hit() { _canary_msgs="${_canary_msgs}$1
"; }
check_docs canary_hit "$_canary_dir/canary.md"
rm -rf "$_canary_dir"
_canary_n="$(printf '%s' "$_canary_msgs" | grep -c '^(b)')"
[ "$_canary_n" -eq 3 ] && pass "(b) canary: exactly the 3 planted defects are reported" \
  || bad "(b) canary: expected 3 defects from the planted lines, the scanner reported $_canary_n"
case "$_canary_msgs" in *"canary.md:1 documents --all-providers"*) pass "(b) canary: phantom flag caught" ;;
  *) bad "(b) canary: phantom --all-providers (line 1) not reported" ;; esac
case "$_canary_msgs" in *"canary.md:2 passes a value to the boolean flag --json ('yes')"*) pass "(b) canary: value on a boolean caught" ;;
  *) bad "(b) canary: '--json yes' (line 2) not reported" ;; esac
case "$_canary_msgs" in *"canary.md:3 uses --artifact with no value"*) pass "(b) canary: value flag without a value caught" ;;
  *) bad "(b) canary: bare --artifact (line 3) not reported" ;; esac
case "$_canary_msgs" in *"canary.md:4"*) bad "(b) canary: the clean line 4 (incl. two-value --record-disposition) was reported" ;;
  *) pass "(b) canary: a clean line, including a two-value flag, passes" ;; esac
case "$_canary_msgs" in *"canary.md:5"*) bad "(b) canary: a flag in the PROSE after a lone ',' (line 5) was read as part of the command" ;;
  *) pass "(b) canary: tokenizing stops at a pure-punctuation token" ;; esac
case "$_canary_msgs" in *"canary.md:6"*) bad "(b) canary: a trailing '.' after a boolean (line 6) was read as its value" ;;
  *) pass "(b) canary: trailing punctuation is not an argument" ;; esac

# Canary 2: what a value flag's values must be. A value flag followed by another flag has NO value (the parser
# refuses `--artifact --json`, see (c)); a two-value flag needs both; and a double-quoted value is one word
# even when it holds a shell operator — line 4 is the real form adversarial-loop-docs.md documents, and line 5
# shows the command does not end at a quoted `>`.
_canary_dir="$(mktemp -d)"
cat > "$_canary_dir/canary.md" <<'CANARY'
~/.zuvo/adversarial-review --mode code --artifact --json
~/.zuvo/adversarial-review --record-disposition "a.ts:1:x"
~/.zuvo/adversarial-review --record-disposition "a.ts:1:x" --json
~/.zuvo/adversarial-review --record-disposition "<id>" fixed|rejected|deferred
~/.zuvo/adversarial-review --context "a > b" --no-such-flag
timeout 600 ~/.zuvo/adversarial-review --mode plan --files "docs/x-<topic>-plan.md" --json \
CANARY
_canary_msgs=""
check_docs canary_hit "$_canary_dir/canary.md"
rm -rf "$_canary_dir"
_canary_n="$(printf '%s' "$_canary_msgs" | grep -c '^(b)')"
[ "$_canary_n" -eq 4 ] && pass "(b) canary 2: exactly the 4 planted defects are reported" \
  || bad "(b) canary 2: expected 4 defects from the planted lines, the scanner reported $_canary_n: $(printf '%s' "$_canary_msgs" | tr '\n' ' ')"
case "$_canary_msgs" in *"canary.md:1 uses --artifact with no value"*) pass "(b) canary 2: a value flag followed by a flag has no value" ;;
  *) bad "(b) canary 2: '--artifact --json' (line 1) not reported" ;; esac
case "$_canary_msgs" in *"canary.md:2 uses --record-disposition with 1 of its 2 values"*) pass "(b) canary 2: a missing second value is caught" ;;
  *) bad "(b) canary 2: '--record-disposition FP' with no verdict (line 2) not reported" ;; esac
case "$_canary_msgs" in *"canary.md:3 uses --record-disposition with 1 of its 2 values"*) pass "(b) canary 2: a flag in a second value's place is caught" ;;
  *) bad "(b) canary 2: '--record-disposition FP --json' (line 3) not reported" ;; esac
case "$_canary_msgs" in *"canary.md:4"*) bad "(b) canary 2: the documented '--record-disposition \"<id>\" fixed|…' (line 4) was reported" ;;
  *) pass "(b) canary 2: a quoted placeholder holding '>' is one value" ;; esac
case "$_canary_msgs" in *"canary.md:5 documents --no-such-flag"*) pass "(b) canary 2: a quoted operator does not end the command" ;;
  *) bad "(b) canary 2: the phantom flag after a quoted '>' (line 5) not reported" ;; esac
case "$_canary_msgs" in *"canary.md:6"*) bad "(b) canary 2: the trailing '\\' continuation (line 6, skills/plan/SKILL.md's form) was read as a value" ;;
  *) pass "(b) canary 2: a trailing '\\' continuation is not a value" ;; esac

check_docs doc_bad "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/*/agents/*.md "$ROOT"/shared/includes/*.md

# A floor, not "> 0": a scan that silently shrank from 150+ lines to a handful stays green on
# "> 0". 100 sits well under today's count and well over any plausible broken tokenizer.
if [ "$_doc_lines" -lt 100 ]; then
  bad "(b) scanned only $_doc_lines invocation lines (floor 100) — the scan is broken, not the docs"
elif [ "$_doc_fails" -eq 0 ]; then
  pass "(b) $_doc_lines documented invocation lines type-check against the parser"
fi
for _must in skills/review/SKILL.md shared/includes/adversarial-loop.md; do
  case " $_doc_files " in *" $_must "*) pass "(b) $_must was scanned" ;;
    *) bad "(b) $_must holds invocations but was not scanned" ;; esac
done

# ─── (c) the canonical proof pair must survive a real parse ──────────────────
# (a) and (b) are static. This runs the script for both accepted shapes and for the
# conflicting one, because "the arm exists" and "the command works" are different claims.
_t="$(mktemp -d)"   # removed by the EXIT trap set beside PROGRAM_SRC
_in='diff --git a/x b/x
+foo'

# Real runs against a mock lane, sandboxed in their own ZUVO_HOME: the 2026-08 regression was a
# pass that "ran" and wrote NO proof file, so exit codes alone are not the claim — the file is.
export PATH="$ROOT/tests/adversarial/mocks:$PATH" ZUVO_HOME="$_t/home"
run_ar() { printf '%s\n' "$_in" | bash "$SCRIPT" --mode code "$@" >/dev/null 2>&1; }
proofs_in() { if [ -f "$1" ]; then grep -c '^REVIEW BY: MOCK-SUCCESS' "$1"; else echo 0; fi; }

run_ar --artifact "$_t/p.txt" --append-artifact; rc1=$?
run_ar --artifact "$_t/p.txt" --append-artifact; rc2=$?
[ "$rc1$rc2" = "00" ] && [ "$(proofs_in "$_t/p.txt")" -eq 2 ] \
  && pass "(c) canonical '--artifact P --append-artifact': two passes, both proofs kept in P" \
  || bad "(c) canonical pair: rc=$rc1/$rc2, $(proofs_in "$_t/p.txt") proof block(s) in P (want 2)"

run_ar --append-artifact "$_t/l.txt"; rc=$?
[ "$rc" -eq 0 ] && [ "$(proofs_in "$_t/l.txt")" -eq 1 ] \
  && pass "(c) legacy alias '--append-artifact P' writes its proof to P" \
  || bad "(c) legacy alias '--append-artifact P': rc=$rc, $(proofs_in "$_t/l.txt") proof block(s) — every already-written retro and cached skill copy uses this shape"

run_ar --artifact "$_t/a.txt" --append-artifact "$_t/b.txt"; rc=$?
[ "$rc" -eq 2 ] && [ ! -e "$_t/a.txt" ] && [ ! -e "$_t/b.txt" ] \
  && pass "(c) two DIFFERENT artifact paths: exit 2 and neither file written" \
  || bad "(c) conflicting --artifact/--append-artifact paths: rc=$rc (want 2), a.txt/b.txt must not exist"

# run_ar_err <args…> — run_ar with the driver's stderr kept in $_t/err.
run_ar_err() { printf '%s\n' "$_in" | bash "$SCRIPT" --mode code "$@" >/dev/null 2>"$_t/err"; }
# expect_refusal <label> <rc> <the one ERROR line> — exit 2, and stderr holds exactly that line.
expect_refusal() {
  [ "$2" -eq 2 ] && grep -qFx -- "$3" "$_t/err" && pass "$1" \
    || bad "$1: rc=$2 (want 2), stderr [$(head -c 300 "$_t/err")] (want the line [$3])"
}
# The REVERSE order (adversarial-cli.sh:353-367): reconciled after the loop, so the later --artifact cannot
# silently win — the same refusal, naming both paths, and nothing written.
run_ar_err --append-artifact "$_t/c.txt" --artifact "$_t/d.txt"; rc=$?
expect_refusal "(c) '--append-artifact P --artifact Q' (reverse order): refused by name" "$rc" \
  "ERROR: --append-artifact '$_t/c.txt' conflicts with --artifact '$_t/d.txt' — pass one path."
[ ! -e "$_t/c.txt" ] && [ ! -e "$_t/d.txt" ] && pass "(c) …and neither file is written" \
  || bad "(c) reverse-order conflict wrote $(ls "$_t" | tr '\n' ' ')"
# What canary 2 says of the docs, the parser does: a value flag followed by a flag, and a missing second value.
run_ar_err --artifact --json; rc=$?
expect_refusal "(c) '--artifact --json': the flag is not taken as the artifact path" "$rc" \
  "ERROR: --artifact requires a value, got '--json'."
run_ar_err --record-disposition "a.ts:1:x"; rc=$?
expect_refusal "(c) '--record-disposition FP' without a verdict: refused" "$rc" \
  "ERROR: --record-disposition requires <fingerprint> <fixed|rejected|deferred> (two values)."
# Values --record-disposition refuses (adversarial-cli.sh:139-149): a fingerprint that is empty, flag-shaped,
# or holds a control character or a backslash (:143-145), and a verdict outside fixed|rejected|deferred — whole
# words, case-sensitive, anchored (:146-148; an empty one reads <missing>). Each one exits 2 in the parser,
# before the ledger is opened: run from a project directory of its own (no git above it, so the project key is
# that directory) against a ledger seeded with an open finding for a.ts:1:x, which must be byte-identical
# afterwards — a refused pair in a batch must not leave the valid pair before it half-recorded (:136-137).
mkdir -p "$_t/rd-proj"; _rd_proj="$(cd "$_t/rd-proj" && pwd -P)"
_rd_ledger="$_t/rd-ledger.log"
printf '2026-10-06T00:00:00Z\trd-seed\tcode\tmock-success\tmock\ta.ts:1:x\tWARNING\t80\ta.ts\tnew\t%s\n' "$_rd_proj" > "$_rd_ledger"
cp "$_rd_ledger" "$_t/rd-ledger.seed"
# rd_run <args…> — run_ar_err from the project directory, against the seeded ledger.
rd_run() { ( cd "$_t/rd-proj" && GIT_CEILING_DIRECTORIES="$_t" ZUVO_FINDINGS_LOG_FILE="$_rd_ledger" run_ar_err "$@" ); }
_rd_fpmsg="is not a fingerprint (empty, flag-shaped, or holds a control character or backslash)."
rd_run --record-disposition "a.ts:1:x" accepted; rc=$?
expect_refusal "(c) '--record-disposition FP accepted': a verdict outside the set is refused" "$rc" \
  "ERROR: disposition for 'a.ts:1:x' must be fixed|rejected|deferred, got 'accepted'."
rd_run --record-disposition "a.ts:1:x" Fixed; rc=$?
expect_refusal "(c) '--record-disposition FP Fixed': the verdict is case-sensitive" "$rc" \
  "ERROR: disposition for 'a.ts:1:x' must be fixed|rejected|deferred, got 'Fixed'."
rd_run --record-disposition "a.ts:1:x" fixed-later; rc=$?
expect_refusal "(c) '--record-disposition FP fixed-later': the verdict is a whole word (anchored)" "$rc" \
  "ERROR: disposition for 'a.ts:1:x' must be fixed|rejected|deferred, got 'fixed-later'."
rd_run --record-disposition "a.ts:1:x" ""; rc=$?
expect_refusal "(c) '--record-disposition FP \"\"': an empty verdict is refused as <missing>" "$rc" \
  "ERROR: disposition for 'a.ts:1:x' must be fixed|rejected|deferred, got '<missing>'."
rd_run --record-disposition --json fixed; rc=$?
expect_refusal "(c) '--record-disposition --json fixed': a flag-shaped fingerprint is refused" "$rc" \
  "ERROR: --record-disposition: '--json' $_rd_fpmsg"
rd_run --record-disposition "" fixed; rc=$?
expect_refusal "(c) '--record-disposition \"\" fixed': an empty fingerprint is refused" "$rc" \
  "ERROR: --record-disposition: '' $_rd_fpmsg"
rd_run --record-disposition $'a.ts:1\tx' fixed; rc=$?
expect_refusal "(c) '--record-disposition FP fixed', FP holding a TAB: refused" "$rc" \
  "ERROR: --record-disposition: 'a.ts:1"$'\t'"x' $_rd_fpmsg"
rd_run --record-disposition $'a.ts:1\001x' fixed; rc=$?
expect_refusal "(c) '--record-disposition FP fixed', FP holding a ^A control character: refused" "$rc" \
  "ERROR: --record-disposition: 'a.ts:1"$'\001'"x' $_rd_fpmsg"
rd_run --record-disposition 'a.ts:1\x' fixed; rc=$?
expect_refusal "(c) '--record-disposition FP fixed', FP holding a backslash: refused" "$rc" \
  "ERROR: --record-disposition: 'a.ts:1\\x' $_rd_fpmsg"
# A batch: a valid pair for the open finding, then a refused one.
rd_run --record-disposition "a.ts:1:x" fixed --record-disposition "a.ts:2:y" maybe; rc=$?
expect_refusal "(c) a batch whose second pair has a bad verdict: refused" "$rc" \
  "ERROR: disposition for 'a.ts:2:y' must be fixed|rejected|deferred, got 'maybe'."
cmp -s "$_t/rd-ledger.seed" "$_rd_ledger" && pass "(c) …and after every refusal above the ledger is byte-identical (nothing half-recorded)" \
  || bad "(c) a refused --record-disposition changed the ledger: $(tail -3 "$_rd_ledger" | tr '\t\n' '  ')"
# The control: the same valid pair alone IS recorded — so the unchanged ledger above was the refusal's doing.
_rd_out="$( cd "$_t/rd-proj" && printf '%s\n' "$_in" | GIT_CEILING_DIRECTORIES="$_t" ZUVO_FINDINGS_LOG_FILE="$_rd_ledger" \
  bash "$SCRIPT" --mode code --record-disposition "a.ts:1:x" fixed 2>"$_t/err" )"; rc=$?
[ "$rc" -eq 0 ] && [ "$_rd_out" = "recorded 1 disposition(s) for project '$_rd_proj' in $_rd_ledger" ] \
  && pass "(c) control: the valid pair alone is recorded (exit 0, 'recorded 1 disposition(s)')" \
  || bad "(c) control: the valid pair alone: rc=$rc, stdout [$_rd_out], stderr [$(head -c 300 "$_t/err")]"
[ "$(awk -F'\t' '$6 == "a.ts:1:x" && $10 == "fixed"' "$_rd_ledger" | grep -c .)" -eq 1 ] \
  && pass "(c) control: …and its verdict row is in the ledger" \
  || bad "(c) control: the ledger holds no 'fixed' row for a.ts:1:x: $(tail -3 "$_rd_ledger" | tr '\t\n' '  ')"

# ─── (d) the DOCS must teach the canonical pair, not the tolerated alias ─────
# The parser accepts `--append-artifact PATH` so that six retros' worth of muscle memory and every
# stale cached skill copy keep working. That tolerance is a compatibility shim, not the contract:
# a doc example teaching the one-arg form re-teaches the shape that had no proof-of-work behind it
# for two days. Every documented line that appends must also name the artifact it appends to.
# check_appends <reporter> <file…> — the (d) scan, as a function for the same reason as
# check_docs: the canary below proves it can go red. Sets _d_lines.
check_appends() {
  local reporter="$1" f hit lineno text; shift
  _d_lines=0
  for f in "$@"; do
    [ -f "$f" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      lineno="${hit%%:*}"; text="${hit#*:}"
      _d_lines=$((_d_lines + 1))
      case "$text" in
        *--artifact*) ;;
        *) "$reporter" "(d) ${f#"$ROOT"/}:$lineno documents --append-artifact without --artifact — write the canonical '--artifact P --append-artifact' pair" ;;
      esac
    done <<APPENDS
$(grep -n 'adversarial-review.*--append-artifact' "$f" 2>/dev/null)
APPENDS
  done
}
_d_fails=0
d_bad() { bad "$1"; _d_fails=$((_d_fails + 1)); }

_canary_dir="$(mktemp -d)"
cat > "$_canary_dir/canary.md" <<'CANARY'
~/.zuvo/adversarial-review --rotate --mode code --append-artifact "$ADV_PROOF"
~/.zuvo/adversarial-review --rotate --mode code --artifact "$ADV_PROOF" --append-artifact
CANARY
_canary_msgs=""
check_appends canary_hit "$_canary_dir/canary.md"
rm -rf "$_canary_dir"
case "$_canary_msgs" in *"canary.md:1 documents --append-artifact without --artifact"*) pass "(d) canary: the one-arg alias is caught" ;;
  *) bad "(d) canary: '--append-artifact P' without --artifact (line 1) not reported" ;; esac
case "$_canary_msgs" in *"canary.md:2"*) bad "(d) canary: the canonical pair (line 2) was reported" ;;
  *) pass "(d) canary: the canonical pair passes" ;; esac

check_appends d_bad "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/*/agents/*.md "$ROOT"/shared/includes/*.md
# Today's docs hold 4 such lines; a scan that finds none is broken, not clean.
if [ "$_d_lines" -lt 3 ]; then
  bad "(d) saw only $_d_lines documented --append-artifact lines (floor 3) — the scan is broken, not the docs"
elif [ "$_d_fails" -eq 0 ]; then
  pass "(d) all $_d_lines documented appends pass --artifact alongside it"
fi

exit "$fail"
