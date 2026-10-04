#!/usr/bin/env bash
#
# test-adversarial-driver-modules.sh — scripts/adversarial-review.sh and the modules it loads
# (scripts/lib/adversarial-*.sh).
#
# The driver was one 5,000-line file. It is now a bootstrap plus Main — the phases in the order they
# run — and one module per responsibility, loaded by its "Driver modules" section. Every other suite
# checks what the driver DOES; this one pins what the split itself must keep true:
#   (1) the module set: AR_MODULES names exactly the scripts/lib/adversarial-*.sh files there are;
#   (2) the loader's contract is complete: AR_REQUIRED_FNS is every function Main calls plus every lane
#       the router dispatches to, and every function of the program is defined exactly once — a module
#       that silently redefined another's function would win or lose by load order;
#   (3) a module only DEFINES: sourcing one under errexit prints nothing, runs no command, fails nothing
#       and sets no variable but the module-scope state named below — otherwise the order the modules
#       load in would start to matter, and the loader's `. module || refuse` (which suspends errexit for
#       the module) would let a failing statement pass unseen;
#   (4) loading end to end: modules in lib/ or flat both run; a driver copied without them, with one
#       missing, with one that does not parse or with one lacking a function exits 2 before any input is
#       read — and there is no ~/.zuvo fallback;
#   (5) lint: the program read as one text (tests/lib/adversarial-driver.sh) has no shellcheck finding at
#       warning level — the bar the repo's shellcheck gate held the single file to. The gate itself only
#       lints files with a shebang, and the modules have none (they are sourced, like every scripts/lib/
#       library), so without this check the moved code would leave the lint entirely;
#   (6) the phases are functions now: their bodies were top-level code, and a handful of constructs mean
#       something else inside a function — `declare`/`typeset` make a LOCAL (the split rewrote the two it
#       found, PIDS and PNAMES), `"$@"`/`$#`/`shift`/`set --` see the function's arguments, BASH_SOURCE
#       and FUNCNAME name the module and the phase. Only ar_parse_args, which Main hands "$@", may use
#       the arguments; a function a phase defines for itself is its own scope and is skipped.
# Nothing here calls a provider: (4) runs --dry-run under the test harness, which prints the prompt
# and exits before dispatch.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AR="${ZUVO_TEST_AR:-$ROOT/scripts/adversarial-review.sh}"
# shellcheck source=tests/lib/adversarial-driver.sh
. "$ROOT/tests/lib/adversarial-driver.sh"
T="$(mktemp -d)" || { echo "  ✗ mktemp -d failed"; exit 1; }
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }

[ -f "$AR" ] || { echo "  ✗ driver not found: $AR"; exit 1; }
MODDIR="$(adv_driver_module_dir "$AR")" || { echo "  ✗ no module directory beside $AR"; exit 1; }
adv_driver_source "$AR" > "$T/program.sh" || { echo "  ✗ the program text could not be assembled"; exit 1; }

echo "=== (1) the module set ==="
declared="$(adv_driver_modules "$AR" | sort | tr '\n' ' ')"
present="$(for f in "$MODDIR"/adversarial-*.sh; do [ -f "$f" ] && basename "$f"; done | sort | tr '\n' ' ')"
same "AR_MODULES names every scripts/lib/adversarial-*.sh file, and only those" "$present" "$declared"
[ "$(adv_driver_modules "$AR" | wc -l | tr -d ' ')" -ge 5 ] && ok "premise: the driver declares its modules ($(adv_driver_modules "$AR" | wc -l | tr -d ' '))" \
  || bad "premise: AR_MODULES could not be read from $AR"

echo "=== (2) the loader's contract ==="
required="$(awk '/^AR_REQUIRED_FNS="/ { f = 1; sub(/^AR_REQUIRED_FNS="/, "") }
  f { line = $0; done = sub(/".*$/, "", line); n = split(line, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (w[i] != "") print w[i]; if (done) exit }' "$AR" | sort)"
main_calls="$(awk '/^# ─── Main ─/ { f = 1; next } f && /^[A-Za-z_]/ { print $1 }' "$AR")"
router="$(awk '/^_dispatch_provider_inner\(\) \{$/ { f = 1; next } f && /^}$/ { exit }
  f { while (match($0, /run_[a-z0-9_]+/)) { print substr($0, RSTART, RLENGTH); $0 = substr($0, RSTART + RLENGTH) } }' \
  "$T/program.sh" | sort -u)"
[ "$(printf '%s\n' "$main_calls" | grep -c .)" -ge 20 ] && ok "premise: Main lists the phases ($(printf '%s\n' "$main_calls" | grep -c .) calls)" \
  || bad "premise: no Main section found in $AR"
[ "$(printf '%s\n' "$router" | grep -c .)" -ge 5 ] && ok "premise: the lane router dispatches to $(printf '%s\n' "$router" | grep -c .) lanes" \
  || bad "premise: _dispatch_provider_inner was not found in the program"
# The two lists above are read off the text, so pin the shape they assume: Main is bare calls only (one per
# line, "$@" for ar_parse_args, a module note), and every lane arm of the router hands off to a run_*
# function. A call inside an `if`, or a lane with no run_*, would otherwise drop out of both sides unseen.
same "Main holds nothing but bare phase calls" "" \
  "$(awk '/^# ─── Main ─/ { f = 1; next } f && !/^#/ && !/^$/' "$AR" | grep -vE '^[A-Za-z_][A-Za-z0-9_]*( "\$@")?( +#.*)?$' | tr '\n' ' ')"
same "every lane arm of _dispatch_provider_inner calls a run_* function" "" \
  "$(awk '/^_dispatch_provider_inner\(\) \{$/ { f = 1; next } f && /^}$/ { exit }
      f && /^    [a-z*][a-z0-9.*-]*\)/ { if (arm != "" && !hit) print arm; arm = $1; hit = 0; if (arm == "*)") arm = "" }
      f && /run_[a-z0-9_]+/ { hit = 1 }
      END { if (arm != "" && !hit) print arm }' "$T/program.sh" | tr '\n' ' ')"
same "Main calls no phase twice" "" "$(printf '%s\n' "$main_calls" | sort | uniq -d | tr '\n' ' ')"
# A phase is an ar_* function of a module; one that Main does not call is code that never runs.
same "every phase a module defines (ar_*) is called from Main" "" \
  "$(for m in $(adv_driver_modules "$AR"); do grep -oE '^ar_[A-Za-z0-9_]+\(\) \{' "$MODDIR/$m" | sed 's/().*//'; done \
     | sort | comm -23 - <(printf '%s\n' "$main_calls" | sort) | tr '\n' ' ')"
same "AR_REQUIRED_FNS = every function Main calls + every lane the router dispatches to" \
  "$(printf '%s\n%s\n' "$main_calls" "$router" | sed '/^$/d' | sort -u | tr '\n' ' ')" "$(printf '%s\n' "$required" | tr '\n' ' ')"
# Every definition, at any indentation and in either syntax (`name() {`, `function name {`): a phase that
# defines a helper for itself does it indented, and a second one of the same name anywhere would win or
# lose by which ran last.
defs="$(awk '{ l = $0; sub(/^[[:space:]]+/, "", l); sub(/^function[[:space:]]+/, "", l) }
  l ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*[{(]/ || ($0 ~ /^[[:space:]]*function[[:space:]]/ && l ~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[{(]?[[:space:]]*$/) {
    sub(/[[:space:]]*(\(\))?[[:space:]]*[{(].*$/, "", l); sub(/[[:space:]]*$/, "", l); print l }' "$T/program.sh" | sort)"
dups="$(printf '%s\n' "$defs" | uniq -d | tr '\n' ' ')"
same "no function of the program is defined twice (driver + modules)" "" "$dups"
missing=""
for f in $required; do grep -qx "$f" <<< "$defs" || missing="$missing $f"; done
same "every required function is defined somewhere in the program" "" "$missing"

echo "=== (3) a module only defines ==="
# The module-scope state the split carried over from the single file: initial values the phases and the
# EXIT trap read, set exactly as they were at top level. A new entry here is a decision, not an accident.
expect_vars() {
  case "$1" in
    adversarial-input.sh)    echo "COLLECTED_BLOBS _TAMPER_BEFORE _TAMPER_CAPTURED _TAMPER_DONE _TAMPER_HEAD" ;;
    adversarial-dispatch.sh) echo "LANE_ERR_QUOTE_CHARS LANE_ERR_RESPONSE_QUOTE_CHARS LANE_ERR_SCAN_CHARS LANE_MIN_RETRY_SECONDS" ;;
    adversarial-run.sh)      echo "CLEANED_UP PIDS" ;;
    *)                       echo "" ;;
  esac
}
# source-probe.sh <module> <PATH> — what sourcing <module> alone does to a shell: under errexit, with a
# plain `.` and no PATH (an external command fails). Prints one line per finding, then LOADED:
#   FAILED <command>   a module-scope statement failed — the check the loader's `|| refuse` cannot make
#   NEW <name>         a variable sourcing created
#   CHANGED <name>     a variable that existed and was changed (IFS, PATH, anything)
#   STATE              set -o, shopt or trap settings differ afterwards
#   LOADED             last, and only when `.` returned — a module-scope `exit` never gets here
cat > "$T/source-probe.sh" <<'PROBE'
set -eu
_p_dyn=" BASH_ARGC BASH_ARGV BASH_COMMAND BASH_LINENO BASH_REMATCH BASH_SOURCE BASH_SUBSHELL BASHPID COLUMNS EPOCHREALTIME EPOCHSECONDS FUNCNAME LINENO LINES PIPESTATUS RANDOM SECONDS SRANDOM _ "
_p_vars() {
  local _p_v
  for _p_v in $(compgen -v); do
    case "$_p_dyn" in *" $_p_v "*) continue ;; esac
    case "$_p_v" in _p_*) continue ;; esac
    declare -p "$_p_v" 2>/dev/null || true
  done
}
_p_state() { set -o; shopt -p; trap -p; }
_p_path="$2"; PATH=/nonexistent
_p_v0="$(_p_vars)"; _p_s0="$(_p_state)"
trap 'echo "FAILED $BASH_COMMAND"' ERR
. "$1"
trap - ERR
_p_v1="$(_p_vars)"; _p_s1="$(_p_state)"
PATH="$_p_path"
awk 'FNR == 1 { f++ } /^declare -/ { k = $3; sub(/=.*/, "", k) } { v[f, k] = v[f, k] $0 "\n"; seen[f, k] = 1; names[k] = 1 }
     END { for (k in names) if (!seen[1, k]) print "NEW " k; else if (seen[2, k] && v[1, k] != v[2, k]) print "CHANGED " k }' \
  <(printf '%s\n' "$_p_v0") <(printf '%s\n' "$_p_v1")
[ "$_p_s0" = "$_p_s1" ] || echo STATE
echo LOADED
PROBE
for m in $(adv_driver_modules "$AR"); do
  # declare/typeset at module scope makes a global only while the loader sources at top level; a plain
  # assignment is global wherever the module is sourced from.
  same "$m declares nothing at module scope (a plain assignment is scope-proof)" "" \
    "$(grep -nE '^(declare|typeset)[[:space:]]' "$MODDIR/$m" | grep -vE '^[0-9]+:(declare|typeset)[[:space:]]+-[fFp][[:space:]]' | tr '\n' ' ')"
  # LANG=C: Homebrew bash under `env -i` with no locale can SIGSEGV in a forked subshell (libintl).
  out="$(env -i LANG=C "$BASH" "$T/source-probe.sh" "$MODDIR/$m" "$PATH" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] || ! printf '%s\n' "$out" | grep -qx LOADED; then
    bad "$m: sourcing it alone did not complete (exit $rc): $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
    continue
  fi
  noise="$(printf '%s\n' "$out" | grep -vxE 'LOADED|NEW [A-Za-z_][A-Za-z0-9_]*' || true)"
  same "$m runs nothing, fails nothing and changes no existing variable, option or trap" "" "$(printf '%s' "$noise" | tr '\n' ' ')"
  same "$m sets only its declared module-scope state" "$(expect_vars "$m" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' ')" \
    "$(printf '%s\n' "$out" | sed -n 's/^NEW //p' | LC_ALL=C sort | tr '\n' ' ')"
done

echo "=== (4) loading, end to end ==="
DIFF='diff --git a/x.ts b/x.ts
@@ -1 +1 @@
-const a = 1
+const a = 2
'
# dry <tag> <driver> [VAR=value...] — a --dry-run review of DIFF under the test harness (no provider is
# ever called; with AR_TEST_FULL=1 a --single review through the mock lane); stdout/stderr in
# $T/<tag>.out/.err, rc on stdout.
dry() {
  local tag="$1" drv="$2" rc=0 how=--dry-run; shift 2
  [ -z "${AR_TEST_FULL:-}" ] || how=--single   # AR_TEST_FULL=1: the whole review, not just the prompt
  mkdir -p "$T/home-$tag/.zuvo" "$T/tmp"
  printf '%s' "$DIFF" | env -i HOME="$T/home-$tag" ZUVO_HOME="$T/home-$tag/.zuvo" TMPDIR="$T/tmp" LANG=C \
    PATH="$PATH" ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-success "$@" \
    bash "$drv" --mode code "$how" > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  echo "$rc"
}
reviewed() { grep -q -- '--- CODE TO REVIEW ---' "$T/$1.out"; }
refused()  { # <tag> <what stderr must name> — exit 2, nothing on stdout, the driver's own refusal
  same "$1: exit 2" "2" "$2"
  [ -s "$T/$1.out" ] && bad "$1: something reached stdout: $(head -c 120 "$T/$1.out")" || ok "$1: nothing on stdout"
  grep -q 'adversarial-review cannot run' "$T/$1.err" && grep -qF -- "$3" "$T/$1.err" \
    && ok "$1: stderr says the driver cannot run, naming $3" || bad "$1: stderr does not name $3: $(head -c 300 "$T/$1.err")"
  [ -e "$T/home-$1/.zuvo/adversarial.log" ] && bad "$1: the run log was written — the refusal came too late" \
    || ok "$1: refused before the run log, i.e. before any input or provider"
}

rc="$(dry repo "$AR")"; same "the driver in place runs (dry run, exit 0)" "0" "$rc"
reviewed repo && ok "…and builds the review prompt" || bad "…but printed no prompt: $(head -c 200 "$T/repo.err")"

adv_driver_copy "$AR" "$T/libcopy/adversarial-review.sh" lib
rc="$(dry libcopy "$T/libcopy/adversarial-review.sh")"; same "a copy with its modules in lib/ runs" "0" "$rc"
reviewed libcopy && ok "…and builds the same prompt" || bad "…but printed no prompt"
same "…byte for byte the prompt the driver in place builds" "$(cat "$T/repo.out")" "$(cat "$T/libcopy.out")"

adv_driver_copy "$AR" "$T/flat/adversarial-review" flat
rc="$(dry flat "$T/flat/adversarial-review")"; same "a flat copy (driver and modules side by side, ~/.zuvo style) runs" "0" "$rc"
# Past the prompt: a whole review through a mock lane — dispatch, the lane, the report — from the flat set,
# so the phases after the dry-run exit run from loaded modules too. The runner library goes beside it (the
# mock's short answer is checked for an auth stub, which needs it) and the suite's mock lanes onto PATH.
cp "$ROOT/scripts/lib/model-subprocess.sh" "$T/flat/model-subprocess.sh"
rc="$(AR_TEST_FULL=1 dry flatfull "$T/flat/adversarial-review" PATH="$ROOT/tests/adversarial/mocks:$PATH")"
same "…and carries a whole review through a mock lane (dispatch, lane, report)" "0" "$rc"
grep -q 'mock-success' "$T/flatfull.out" 2>/dev/null && ok "…whose output names the lane that answered" \
  || bad "…but the output does not name the lane: $(head -c 300 "$T/flatfull.out") / $(tail -c 300 "$T/flatfull.err")"

mkdir -p "$T/alone"; cp "$AR" "$T/alone/adversarial-review.sh"
rc="$(dry alone "$T/alone/adversarial-review.sh")"; refused alone "$rc" "lacks adversarial-"

first="$(adv_driver_modules "$AR" | head -1)"
adv_driver_copy "$AR" "$T/gap/adversarial-review.sh" lib; rm -f "$T/gap/lib/$first"
rc="$(dry gap "$T/gap/adversarial-review.sh")"; refused gap "$rc" "$first"

adv_driver_copy "$AR" "$T/gapflat/adversarial-review.sh" lib; rm -f "$T/gapflat/lib/$first"
for m in $(adv_driver_modules "$AR"); do cp "$MODDIR/$m" "$T/gapflat/$m"; done
rc="$(dry gapflat "$T/gapflat/adversarial-review.sh")"
same "lib/ lacking a module, a complete flat set beside the driver: the complete set is used" "0" "$rc"

last="$(adv_driver_modules "$AR" | tail -1)"
adv_driver_copy "$AR" "$T/broken/adversarial-review.sh" lib; printf '\nif then\n' >> "$T/broken/lib/$last"
rc="$(dry broken "$T/broken/adversarial-review.sh")"; refused broken "$rc" "$last did not load"

adv_driver_copy "$AR" "$T/partial/adversarial-review.sh" lib; printf '\nunset -f ar_dry_run\n' >> "$T/partial/lib/$last"
rc="$(dry partial "$T/partial/adversarial-review.sh")"; refused partial "$rc" "ar_dry_run is not defined"

# No ~/.zuvo fallback: an installed module set in the HOME the driver runs under is not its own.
mkdir -p "$T/home-nofallback/.zuvo/lib"
for m in $(adv_driver_modules "$AR"); do cp "$MODDIR/$m" "$T/home-nofallback/.zuvo/lib/$m"; done
rc="$(dry nofallback "$T/alone/adversarial-review.sh")"; refused nofallback "$rc" "lacks adversarial-"

echo "=== (5) lint, the program as one text ==="
if ! command -v shellcheck >/dev/null 2>&1; then
  # Column 0 and "did NOT run": the shape dev-push.sh's dark-gate scan looks for in the suite log, so a
  # machine without shellcheck says so before a release instead of passing this section in silence.
  echo "SKIP: shellcheck is not installed — the lint of the moved code (test-adversarial-driver-modules (5)) did NOT run."
else
  # .shellcheckrc is looked up beside the file it lints: give the assembled program the repo's.
  cp "$ROOT/.shellcheckrc" "$T/.shellcheckrc"
  sc_rc=0; findings="$(cd "$T" && shellcheck -S warning -f gcc program.sh 2>&1)" || sc_rc=$?
  # 0 = clean, 1 = findings; anything else is shellcheck itself failing, which a count of 0 would hide.
  case "$sc_rc" in 0|1) ;; *) bad "shellcheck failed to run (exit $sc_rc): $(printf '%s' "$findings" | head -c 300)" ;; esac
  same "the program as one text has no shellcheck finding at warning level" "0" "$(printf '%s' "$findings" | grep -c '\[SC' || true)"
  [ -z "$findings" ] || printf '%s\n' "$findings" | head -10 | sed 's/^/      /'
fi

echo "=== (6) the phases keep no construct a function changes ==="
# scope_hits <program> <phases> — "phase: line" for each such construct in a phase body. Skipped: comment
# text, heredoc bodies, functions a phase defines for itself (their own scope), and ar_parse_args'
# arguments. $1..$9 are not looked for: a phase's awk programs are full of them, and no phase reads them.
scope_hits() {
  awk -v phases=" $2 " '
    function strip(s) { sub(/(^|[[:space:]])#.*$/, "", s); return s }
    !ph && /^[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ { n = $0; sub(/\(\).*/, "", n); if (index(phases, " " n " ")) { ph = n; nest = ""; hd = "" }; next }
    !ph { next }
    hd != "" { t = $0; sub(/^\t+/, "", t); if (t == hd) hd = ""; next }
    nest != "" { if ($0 == nest "}") nest = ""; next }
    $0 == "}" { ph = ""; next }
    {
      l = strip($0)
      if (match(l, /<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*/)) { hd = substr(l, RSTART, RLENGTH); sub(/^<<-?[[:space:]]*["\047]?/, "", hd) }
      if (l ~ /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)[[:space:]]*\{/) {
        if (l !~ /\}[[:space:]]*$/) { nest = l; sub(/[^[:space:]].*$/, "", nest) }
        next
      }
      bad = ""
      # declare -F/-f/-p only ask; every other declare/typeset declares, and in a function that is a local.
      if (l ~ /(^|[^A-Za-z0-9_-])(declare|typeset)[[:space:]]/ && l !~ /(declare|typeset)[[:space:]]+-[fFp][[:space:]]/) bad = "declare/typeset makes a local"
      else if (ph != "ar_parse_args" && l ~ /\$@|\$\{@|\$\*|\$#|(^|[;&|[:space:]])shift([[:space:];]|$)|set --/) bad = "reads the function arguments"
      else if (l ~ /BASH_SOURCE|FUNCNAME/) bad = "BASH_SOURCE/FUNCNAME name the module and the phase"
      if (bad != "") print ph ": " bad ": " $0
    }' "$1"
}
phases="$(printf '%s\n' "$main_calls" | grep '^ar_' | tr '\n' ' ')"
[ "$(printf '%s' "$phases" | wc -w | tr -d ' ')" -ge 20 ] && ok "premise: $(printf '%s' "$phases" | wc -w | tr -d ' ') phases to check" || bad "premise: no phases found in Main"
hits="$(scope_hits "$T/program.sh" "$phases")"
same "no phase body uses declare/typeset, the arguments, BASH_SOURCE or FUNCNAME" "" "$hits"
# The check itself: each kind of construct, planted in a phase, is found — and in a helper the phase
# defines for itself, or in a heredoc, it is not.
probe_phase="$(printf '%s' "$phases" | awk '{ print $NF }')"
awk -v p="$probe_phase" '{ print } $0 == p "() {" {
  print "declare -a PROBE_A=()"; print "[[ $# -gt 0 ]] && shift"; print "x=${BASH_SOURCE[0]}"
  print "  probe_helper() {"; print "    local a=\"$1\"; shift; declare b=\"$@\""; print "  }"
  print "cat <<EOF"; print "shift declare -a \"$@\""; print "EOF" }' "$T/program.sh" > "$T/probed.sh"
probed="$(scope_hits "$T/probed.sh" "$probe_phase")"
same "probe: the three planted constructs are found, the helper and the heredoc are not" "3" "$(printf '%s\n' "$probed" | grep -c "^$probe_phase: ")"
# A library a phase SOURCES runs its own top level in that phase's scope: ar_ba_setup loads the blind-audit
# panel library, so a declare/typeset at that library's top level would make a local of ar_ba_setup and be
# gone when the phase returns. (model-subprocess.sh is sourced by the bootstrap, at top level.)
same "the panel library ar_ba_setup sources declares nothing at its top level" "" \
  "$(grep -nE '^(declare|typeset)[[:space:]]' "$ROOT/scripts/lib/blind-audit-panel.sh" | grep -vE '^[0-9]+:(declare|typeset)[[:space:]]+-[fFp][[:space:]]' | tr '\n' ' ')"

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
