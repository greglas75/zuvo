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
# Nothing here calls a provider: (4) runs the driver under the test harness, with only its mock lanes —
# --dry-run (the prompt, then exit before dispatch) or, with AR_TEST_FULL=1, a whole --single review.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AR="${ZUVO_TEST_AR:-$ROOT/scripts/adversarial-review.sh}"
# shellcheck source=tests/lib/adversarial-driver.sh
. "$ROOT/tests/lib/adversarial-driver.sh"
# Physical path: the helper names the modules it resolved, and macOS mktemp's /var/folders is a symlink to
# /private/var/folders — an expected message spelled with the unresolved path failed there and nowhere else.
T="$(mktemp -d)" && T="$(cd "$T" && pwd -P)" || { echo "  ✗ mktemp -d failed"; exit 1; }
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
# driver_words <VAR> — the words of the driver's top-level VAR="…" assignment as BASH reads it (that assignment
# alone, evaluated in a clean shell), one per line: a reading independent of the awk parses below, so their
# premises can be exact counts instead of lower bounds.
driver_words() {
  # shellcheck disable=SC2016  # expanded by the inner bash
  env -i bash -c 'eval "$1"; for w in ${!2}; do printf "%s\n" "$w"; done' _ "$(sed -n "/^$1=\"/,/\"\$/p" "$AR")" "$1"
}
# main_calls_of — the calls of the driver's Main section, one per line (each line's first word).
main_calls_of() { awk '/^# ─── Main ─/ { f = 1; next } f && /^[A-Za-z_]/ { print $1 }' "$AR"; }

[ -f "$AR" ] || { echo "  ✗ driver not found: $AR"; exit 1; }
MODDIR="$(adv_driver_module_dir "$AR")" || { echo "  ✗ no module directory beside $AR"; exit 1; }
adv_driver_source "$AR" > "$T/program.sh" || { echo "  ✗ the program text could not be assembled"; exit 1; }

echo "=== (1) the module set ==="
declared="$(adv_driver_modules "$AR" | sort | tr '\n' ' ')"
present="$(for f in "$MODDIR"/adversarial-*.sh; do [ -f "$f" ] && basename "$f"; done | sort | tr '\n' ' ')"
same "AR_MODULES names every scripts/lib/adversarial-*.sh file, and only those" "$present" "$declared"
same "premise: the driver declares its modules ($(driver_words AR_MODULES | grep -c .)) — adv_driver_modules reads AR_MODULES word for word as bash does" \
  "$(driver_words AR_MODULES | tr '\n' ' ')" "$(adv_driver_modules "$AR" | tr '\n' ' ')"
# The helper every source assertion of every suite reads the program through (tests/lib/adversarial-driver.sh)
# must refuse a text it cannot assemble whole — one with a module silently left out would turn each absence
# check that trusts it into a pass. Its refusals, driven on copies of the driver:
h_first="$(adv_driver_modules "$AR" | head -1)"; h_last="$(adv_driver_modules "$AR" | tail -1)"
h_line=". \"\$AR_LIB_DIR/$h_first\""
helper_refuses() { # <label> <what stderr must name> <command...> — status 1 and the reason on stderr (stdout
  local label="$1" want="$2" rc=0; shift 2   # is not promised empty: every caller acts on the status)
  "$@" > "$T/helper.out" 2> "$T/helper.err" || rc=$?
  same "helper, $label: status 1" "1" "$rc"
  grep -qF -- "$want" "$T/helper.err" && ok "helper, $label: stderr names $want" \
    || bad "helper, $label: stderr does not name $want: $(head -c 300 "$T/helper.err")"
}
adv_driver_copy "$AR" "$T/h-gone/adversarial-review.sh" lib || bad "helper premise: adv_driver_copy failed"
rm -f "$T/h-gone/lib/$h_last"
helper_refuses "a module deleted from lib/" "no module directory beside" adv_driver_source "$T/h-gone/adversarial-review.sh"
helper_refuses "…and the copy of that driver" "no module directory beside" adv_driver_copy "$T/h-gone/adversarial-review.sh" "$T/h-gone2/adversarial-review.sh"
adv_driver_copy "$AR" "$T/h-empty/adversarial-review.sh" lib || bad "helper premise: adv_driver_copy failed"
: > "$T/h-empty/lib/$h_last"
helper_refuses "a module present but empty" "cannot read $T/h-empty/lib/$h_last" adv_driver_source "$T/h-empty/adversarial-review.sh"
adv_driver_copy "$AR" "$T/h-dup/adversarial-review.sh" lib || bad "helper premise: adv_driver_copy failed"
awk -v l="$h_line" '{ print } index($0, l) == 1 { print }' "$AR" > "$T/h-dup/adversarial-review.sh"
same "helper premise: the copy sources $h_first twice" "2" "$(grep -cF -- "$h_line" "$T/h-dup/adversarial-review.sh")"
helper_refuses "a module line duplicated" "inlined [$h_first $h_first " adv_driver_source "$T/h-dup/adversarial-review.sh"
same "helper: adv_driver_file_with finds a line that occurs once, in the driver" "$AR" "$(adv_driver_file_with "$AR" "$h_line")"
helper_refuses "adv_driver_file_with, a line that occurs twice" "occurs 2 time(s)" adv_driver_file_with "$T/h-dup/adversarial-review.sh" "$h_line"
# A single-file driver — no AR_MODULES, nothing sourced from $AR_LIB_DIR: the driver before the split, which
# ZUVO_TEST_AR may name — is a whole program: its source is the file, its copy is the file alone.
mkdir -p "$T/h-single" "$T/h-nomods"
printf '#!/usr/bin/env bash\n# a driver from before the split\necho "single-file review"\n' > "$T/h-single/adversarial-review.sh"
same "helper, a single-file driver: no modules" "" "$(adv_driver_modules "$T/h-single/adversarial-review.sh")"
rc=0; adv_driver_source "$T/h-single/adversarial-review.sh" > "$T/h-single.src" 2> "$T/h-single.err" || rc=$?
same "helper, a single-file driver: adv_driver_source succeeds" "0" "$rc"
cmp -s "$T/h-single/adversarial-review.sh" "$T/h-single.src" && ok "helper, …and its program text is the file, byte for byte" \
  || bad "helper, …but its program text is not the file: $(head -c 200 "$T/h-single.src") / $(head -c 200 "$T/h-single.err")"
rc=0; adv_driver_copy "$T/h-single/adversarial-review.sh" "$T/h-single-copy/adversarial-review.sh" lib || rc=$?
same "helper, a single-file driver: adv_driver_copy succeeds" "0" "$rc"
same "helper, …and lays out the file alone (no lib/)" "adversarial-review.sh" "$(ls -A "$T/h-single-copy" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
[ -x "$T/h-single-copy/adversarial-review.sh" ] && cmp -s "$T/h-single/adversarial-review.sh" "$T/h-single-copy/adversarial-review.sh" \
  && ok "helper, …an executable copy of it" || bad "helper, …but the copy is missing, different or not executable"
same "helper, a single-file driver: adv_driver_file_with searches the file itself" "$T/h-single/adversarial-review.sh" \
  "$(adv_driver_file_with "$T/h-single/adversarial-review.sh" 'single-file review')"
# …but a driver that sources from $AR_LIB_DIR while naming no modules is no single file: refused, as before.
# shellcheck disable=SC2016  # the literal line a driver holds
printf '#!/usr/bin/env bash\n. "$AR_LIB_DIR/%s" || exit 2\n' "$h_first" > "$T/h-nomods/adversarial-review.sh"
helper_refuses "module lines but no AR_MODULES" "no module directory beside" adv_driver_source "$T/h-nomods/adversarial-review.sh"
helper_refuses "…and its copy" "no module directory beside" adv_driver_copy "$T/h-nomods/adversarial-review.sh" "$T/h-nomods2/adversarial-review.sh"
# adv_driver_module_dir's second candidate (tests/lib/adversarial-driver.sh:68, `for c in "$d/lib" "$d"`): the
# driver's own directory, when lib/ is absent or lacks a module — and lib/ first when both are complete.
adv_driver_copy "$AR" "$T/h-flat/adversarial-review.sh" flat || bad "helper premise: adv_driver_copy flat failed"
h_flat="$(cd "$T/h-flat" && pwd -P)"
same "helper: adv_driver_module_dir finds a flat set in the driver's own directory" "$h_flat" "$(adv_driver_module_dir "$T/h-flat/adversarial-review.sh")"
adv_driver_source "$T/h-flat/adversarial-review.sh" > "$T/h-flat.src" 2> "$T/h-flat.err" \
  && cmp -s "$T/program.sh" "$T/h-flat.src" && ok "helper, …and the flat set inlines to the same program text" \
  || bad "helper, …but the flat set's program text differs: $(head -c 200 "$T/h-flat.err")"
mkdir -p "$T/h-flat/lib"; cp "$MODDIR/$h_first" "$T/h-flat/lib/$h_first"
same "helper: a lib/ that lacks a module is passed over for the complete flat set" "$h_flat" "$(adv_driver_module_dir "$T/h-flat/adversarial-review.sh")"
for m in $(adv_driver_modules "$AR"); do cp "$MODDIR/$m" "$T/h-flat/lib/$m"; done
same "helper: with both complete, lib/ comes first" "$h_flat/lib" "$(adv_driver_module_dir "$T/h-flat/adversarial-review.sh")"
# A line that sources from $AR_LIB_DIR in another shape (:83-85) cannot be inlined: refused, never skipped.
adv_driver_copy "$AR" "$T/h-shape/adversarial-review.sh" lib || bad "helper premise: adv_driver_copy failed"
awk -v l="$h_line" 'index($0, l) == 1 { $0 = "source" substr($0, 2) } { print }' "$AR" > "$T/h-shape/adversarial-review.sh"
same "helper premise: the copy sources $h_first with \`source\`" "1" "$(grep -cF -- "source \"\$AR_LIB_DIR/$h_first\"" "$T/h-shape/adversarial-review.sh")"
helper_refuses "a module line in another shape (source …)" "cannot inline this module line: source \"\$AR_LIB_DIR/$h_first\"" \
  adv_driver_source "$T/h-shape/adversarial-review.sh"
# adv_driver_file_with's other count (:127): a line that occurs in no file of the program.
helper_refuses "adv_driver_file_with, a line that occurs nowhere" "the line occurs 0 time(s), not once" \
  adv_driver_file_with "$AR" "adv-driver-modules: a line in no file of the program"

echo "=== (2) the loader's contract ==="
required="$(awk '/^AR_REQUIRED_FNS="/ { f = 1; sub(/^AR_REQUIRED_FNS="/, "") }
  f { line = $0; done = sub(/".*$/, "", line); n = split(line, w, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (w[i] != "") print w[i]; if (done) exit }' "$AR" | sort)"
main_calls="$(main_calls_of)"
router="$(awk '/^_dispatch_provider_inner\(\) \{$/ { f = 1; next } f && /^}$/ { exit }
  f { while (match($0, /run_[a-z0-9_]+/)) { print substr($0, RSTART, RLENGTH); $0 = substr($0, RSTART + RLENGTH) } }' \
  "$T/program.sh" | sort -u)"
# Exact, from AR_REQUIRED_FNS as bash reads it: its run_* words are the lanes, the rest are Main's calls.
req_words="$(driver_words AR_REQUIRED_FNS)"
same "premise: Main lists the phases — as many calls as AR_REQUIRED_FNS names non-lane functions ($(printf '%s\n' "$req_words" | grep -vc '^run_'))" \
  "$(printf '%s\n' "$req_words" | grep -vc '^run_')" "$(printf '%s\n' "$main_calls" | grep -c .)"
same "premise: the lane router dispatches to as many lanes as AR_REQUIRED_FNS names run_* functions ($(printf '%s\n' "$req_words" | grep -c '^run_'))" \
  "$(printf '%s\n' "$req_words" | grep -c '^run_')" "$(printf '%s\n' "$router" | grep -c .)"
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
    adversarial-cli.sh)      echo "AR_DOC_MODES AR_UNCHUNKED_DOC_MODES" ;;
    adversarial-ledger.sh)   echo "INPUT_KEEP_DAYS LOCK_PID_REUSE_SLACK_S" ;;
    adversarial-input.sh)    echo "CHUNK_NOTE_HEADROOM_CHARS COLLECTED_BLOBS FILE_HEADER_RE MAX_INPUT_BYTES_DEFAULT MIN_DOC_WORDS MIN_PLAN_TASKS MIN_REPORT_WORDS OMITTED_FILES_SHOWN _TAMPER_BEFORE _TAMPER_CAPTURED _TAMPER_DONE _TAMPER_HEAD" ;;
    adversarial-dispatch.sh) echo "AUTH_STUB_MAX_BYTES KILL_ROUNDING_SLACK_SECONDS LANE_ERR_QUOTE_CHARS LANE_ERR_RESPONSE_QUOTE_CHARS LANE_ANSWER_MAX_BYTES LANE_ERR_SCAN_CHARS LANE_MIN_RETRY_SECONDS LANE_QUOTE_MAX_BYTES" ;;
    adversarial-providers.sh) echo "ARGV_PROMPT_LANES" ;;
    adversarial-lanes.sh)    echo "QWEN_REFUSAL_MAX_CHARS" ;;
    adversarial-lanes-http.sh) echo "OR_ATTEMPTS OR_MIN_ATTEMPT_SECONDS" ;;
    adversarial-report.sh)   echo "META_CLEAN_LINES" ;;
    adversarial-run.sh)      echo "CLEANED_UP DEADLINE_SLACK_SECONDS PIDS" ;;
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
# dry_exec <tag> [VAR=value...] -- <bash args...> — bash under the environment every loading case runs in
# (the test harness, its mock lane, a HOME of the tag's own), stdin inherited; stdout/stderr in
# $T/<tag>.out/.err; status = bash's.
dry_exec() {
  local tag="$1" envs=(); shift
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  mkdir -p "$T/home-$tag/.zuvo" "$T/tmp"
  env -i HOME="$T/home-$tag" ZUVO_HOME="$T/home-$tag/.zuvo" TMPDIR="$T/tmp" LANG=C \
    PATH="$PATH" ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-success \
    ${envs[@]+"${envs[@]}"} bash "$@" > "$T/$tag.out" 2> "$T/$tag.err"
}
# dry <tag> <driver> [VAR=value...] — a --dry-run review of DIFF under the test harness (no provider is
# ever called; with AR_TEST_FULL=1 a --single review through the mock lane); stdout/stderr in
# $T/<tag>.out/.err, rc on stdout.
dry() {
  local tag="$1" drv="$2" rc=0 how=--dry-run; shift 2
  [ -z "${AR_TEST_FULL:-}" ] || how=--single   # AR_TEST_FULL=1: the whole review, not just the prompt
  printf '%s' "$DIFF" | dry_exec "$tag" "$@" -- "$drv" --mode code "$how" || rc=$?
  echo "$rc"
}
reviewed() { grep -q -- '--- CODE TO REVIEW ---' "$T/$1.out"; }
# refused <tag> <rc> <what stderr must name> — exit 2, nothing on stdout, the driver's own refusal, and no run
# log. The refusal cases run with AR_TEST_FULL=1: a --dry-run ends before the run log is opened even when it
# succeeds, so only a whole review makes "no run log" mean "stopped at the loader".
refused()  {
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
# The positive control for refused()'s side-effect check: a whole review that got past the loader writes the run log.
[ -s "$T/home-flatfull/.zuvo/adversarial.log" ] && ok "…and writes the run log (what a refusal must never get to)" \
  || bad "…but wrote no run log at $T/home-flatfull/.zuvo/adversarial.log — refused()'s 'no run log' check would prove nothing"

mkdir -p "$T/alone"; cp "$AR" "$T/alone/adversarial-review.sh"
rc="$(AR_TEST_FULL=1 dry alone "$T/alone/adversarial-review.sh")"; refused alone "$rc" "lacks adversarial-"

first="$(adv_driver_modules "$AR" | head -1)"
adv_driver_copy "$AR" "$T/gap/adversarial-review.sh" lib; rm -f "$T/gap/lib/$first"
rc="$(AR_TEST_FULL=1 dry gap "$T/gap/adversarial-review.sh")"; refused gap "$rc" "$first"

adv_driver_copy "$AR" "$T/gapflat/adversarial-review.sh" lib; rm -f "$T/gapflat/lib/$first"
for m in $(adv_driver_modules "$AR"); do cp "$MODDIR/$m" "$T/gapflat/$m"; done
rc="$(dry gapflat "$T/gapflat/adversarial-review.sh")"
same "lib/ lacking a module, a complete flat set beside the driver: the complete set is used" "0" "$rc"

last="$(adv_driver_modules "$AR" | tail -1)"
adv_driver_copy "$AR" "$T/broken/adversarial-review.sh" lib; printf '\nif then\n' >> "$T/broken/lib/$last"
rc="$(AR_TEST_FULL=1 dry broken "$T/broken/adversarial-review.sh")"; refused broken "$rc" "$last did not load"

adv_driver_copy "$AR" "$T/partial/adversarial-review.sh" lib; printf '\nunset -f ar_dry_run\n' >> "$T/partial/lib/$last"
rc="$(AR_TEST_FULL=1 dry partial "$T/partial/adversarial-review.sh")"; refused partial "$rc" "ar_dry_run is not defined"

# No ~/.zuvo fallback: an installed module set in the HOME the driver runs under is not its own. (A driver
# copy of its own, without modules — not the one "alone" made: this case must hold when run by itself.)
mkdir -p "$T/home-nofallback/.zuvo/lib" "$T/alone-nofallback"
cp "$AR" "$T/alone-nofallback/adversarial-review.sh"
for m in $(adv_driver_modules "$AR"); do cp "$MODDIR/$m" "$T/home-nofallback/.zuvo/lib/$m"; done
rc="$(AR_TEST_FULL=1 dry nofallback "$T/alone-nofallback/adversarial-review.sh")"; refused nofallback "$rc" "lacks adversarial-"

# The install stamp (adversarial-review.sh:320-345): a module set with adversarial-modules.cksum loads only
# when the stamp is the cksum of THIS driver's bytes, then its modules in AR_MODULES order. A driver that can no
# longer be read at startup (an install beside the review removed it) sums to "unreadable" (:335-339), which no
# stamp matches. Each copy plants a lib/model-subprocess.sh, sourced BEFORE the bytes are read, that does nothing
# (the control) or removes the driver file (bash, already reading it, runs on). ZUVO_ADV_MODULE_STAMP_WAIT=0
# makes a mismatch final at once.
# installer_stamp <module dir> <driver> [<file summed in the driver's place>] — the cksum THIS tree's installer
# writes (install.sh install_adv_module_stamp), so nothing here restates what the stamp sums (AP3). A third
# argument points ADV_DRIVER_SRC at that file for the sum only; the module list stays the installer's reading
# of <driver>, as an EMPTY file names no modules. Status 0 when a cksum was written, 1 otherwise.
installer_stamp() {
  mkdir -p "$T/home-stamp-installer"
  # shellcheck disable=SC2034  # ADV_DRIVER_SRC is the installer's: install_adv_module_stamp sums the file it names
  ( export HOME="$T/home-stamp-installer"; . "${AR%/*}/install.sh" >/dev/null 2>&1
    ADV_DRIVER_SRC="$2"
    if [ -n "${3:-}" ]; then
      _is_names="$(_adv_module_names)"; ADV_DRIVER_SRC="$3"
      # shellcheck disable=SC2329  # called by the installer's install_adv_module_stamp
      _adv_module_names() { printf '%s\n' "$_is_names"; }
    fi
    install_adv_module_stamp stamp-copy "$1" "$1" 1 ) >/dev/null 2>&1
  case "$(cat "$1/adversarial-modules.cksum" 2>/dev/null)" in ''|*[!0-9\ ]*) return 1 ;; esac
}
# stamp_copy <dir> <full|modules> <plant: keep|remove> — a lib/ copy of the driver with the installer's stamp
# for that driver (full) or for an EMPTY driver file in its place (modules: the sum an unread driver would give
# if the loader summed it as empty).
stamp_copy() {
  adv_driver_copy "$AR" "$1/adversarial-review.sh" lib || { bad "stamp premise: adv_driver_copy failed ($1)"; return 1; }
  if [ "$2" = modules ]; then
    : > "$1/empty-driver"
    installer_stamp "$1/lib" "$1/adversarial-review.sh" "$1/empty-driver" \
      || bad "stamp premise: the installer wrote no cksum for $1/lib (empty driver)"
  else
    installer_stamp "$1/lib" "$1/adversarial-review.sh" || bad "stamp premise: the installer wrote no cksum for $1/lib"
  fi
  if [ "$3" = remove ]; then printf 'rm -f -- "%s"\nreturn 1\n' "$1/adversarial-review.sh" > "$1/lib/model-subprocess.sh"
  else printf 'return 1\n' > "$1/lib/model-subprocess.sh"; fi
}
stamp_copy "$T/stamp-ok" full keep
rc="$(dry stampok "$T/stamp-ok/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=0)"
same "stamp control: a set whose stamp sums this driver and its modules loads (dry run, exit 0)" "0" "$rc"
reviewed stampok && ok "stamp control: …and builds the prompt" || bad "stamp control: …but printed no prompt: $(head -c 300 "$T/stampok.err")"
stamp_copy "$T/stamp-gone" full remove
rc="$(AR_TEST_FULL=1 dry stampgone "$T/stamp-gone/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=0)"
[ -e "$T/stamp-gone/adversarial-review.sh" ] && bad "stamp premise: the planted lib did not remove the driver" \
  || ok "stamp premise: the driver file was removed during startup"
# The loader names the directory physically (pwd -P), as it resolved it.
refused stampgone "$rc" "$(cd "$T/stamp-gone" && pwd -P)/lib/ holds a module set that does not match its install stamp"
# The branch itself: summed as empty, the gone driver WOULD match a stamp of its modules alone.
stamp_copy "$T/stamp-empty" modules remove
# The two stamps differ only by the bytes summed in the driver's place — the installer did sum the driver.
s_full="$(cat "$T/stamp-ok/lib/adversarial-modules.cksum" 2>/dev/null)"
s_empty="$(cat "$T/stamp-empty/lib/adversarial-modules.cksum" 2>/dev/null)"
[ -n "$s_full" ] && [ -n "$s_empty" ] && [ "$s_full" != "$s_empty" ] \
  && ok "stamp premise: the installer's stamp for an empty driver differs from its stamp for this one" \
  || bad "stamp premise: the stamps for this driver [$s_full] and an empty one [$s_empty] are not two different sums"
rc="$(AR_TEST_FULL=1 dry stampempty "$T/stamp-empty/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=0)"
refused stampempty "$rc" "$(cd "$T/stamp-empty" && pwd -P)/lib/ holds a module set that does not match its install stamp"

# No script directory at all (:360): the driver's TEXT on stdin (`bash -s`) has no path, so there is nowhere
# to look for its modules — refused with that reason, not with an empty list of what each place lacked.
mkdir -p "$T/noscriptdir-cwd"
rc=0; ( cd "$T/noscriptdir-cwd" && dry_exec noscriptdir -- -s -- --mode code --single < "$AR" ) || rc=$?
refused noscriptdir "$rc" "no usable set of its modules (scripts/lib/adversarial-*.sh) is beside it: the script directory could not be resolved, so there was nowhere to look"
# …and a complete module set in that CWD is still not used: with no script path, BASH_SOURCE is empty and the
# bootstrap falls back to $0 — "bash", a bare name — and the bare-name arm (:182) takes $PWD only when $PWD holds
# that file. Without that check the CWD (the repository under review) would be the script directory and its
# modules would run. The decoy set's last module leaves a marker when sourced.
decoy_set() { # <dir> <marker> — a complete module set in <dir>/lib/ that leaves <marker> when sourced
  mkdir -p "$1/lib"
  for m in $(adv_driver_modules "$AR"); do cp "$MODDIR/$m" "$1/lib/$m"; done
  printf '\n: > "%s"\n' "$2" >> "$1/lib/$(adv_driver_modules "$AR" | tail -1)"
}
decoy_set "$T/stdin-decoy-cwd" "$T/stdin-decoy.loaded"
rc=0; ( cd "$T/stdin-decoy-cwd" && dry_exec stdindecoy -- -s -- --mode code --single < "$AR" ) || rc=$?
refused stdindecoy "$rc" "the script directory could not be resolved, so there was nowhere to look"
[ -e "$T/stdin-decoy.loaded" ] && bad "stdindecoy: the module set in the CWD was sourced" \
  || ok "stdindecoy: the module set in the CWD was never sourced"

# The bare-name arm itself (:182): `bash adversarial-review.sh` from the driver's own directory records the bare
# name in BASH_SOURCE, and the script directory is $PWD — made physical (:184) before anything is looked up.
adv_driver_copy "$AR" "$T/bare/adversarial-review.sh" lib || bad "bare premise: adv_driver_copy failed"
rc="$(cd "$T/bare" && dry bare adversarial-review.sh)"
same "a bare name run from the driver's own directory: the script directory is \$PWD (dry run, exit 0)" "0" "$rc"
reviewed bare && ok "…and builds the review prompt" || bad "…but printed no prompt: $(head -c 300 "$T/bare.err")"
# Through a symlinked CWD (PWD handed to bash, so $PWD is the LINK): the directory named is the physical one —
# shown by a set the loader refuses for its stamp (the installer's install-incomplete marker), whose refusal
# names the directory as the loader resolved it.
adv_driver_copy "$AR" "$T/bare-phys/adversarial-review.sh" lib || bad "bare premise: adv_driver_copy failed"
printf 'install-incomplete\n' > "$T/bare-phys/lib/adversarial-modules.cksum"
ln -s "$T/bare-phys" "$T/bare-link"
rc="$(cd "$T/bare-link" && AR_TEST_FULL=1 dry barelink adversarial-review.sh PWD="$T/bare-link" ZUVO_ADV_MODULE_STAMP_WAIT=0)"
refused barelink "$rc" "$(cd "$T/bare-phys" && pwd -P)/lib/ holds a module set that does not match its install stamp"
grep -qF -- "$T/bare-link/" "$T/barelink.err" && bad "barelink: the refusal names the symlinked (logical) directory" \
  || ok "barelink: …and never the symlinked (logical) one"
# A name bash resolves through PATH (not in the CWD): bash records the full path, so the script directory is the
# driver's — never the CWD, whose decoy set must stay unsourced.
adv_driver_copy "$AR" "$T/onpath/adversarial-review.sh" lib || bad "onpath premise: adv_driver_copy failed"
decoy_set "$T/onpath-cwd" "$T/onpath-decoy.loaded"
same "onpath premise: the CWD holds no adversarial-review.sh (bash must search PATH)" "no" \
  "$([ -e "$T/onpath-cwd/adversarial-review.sh" ] && echo yes || echo no)"
rc="$(cd "$T/onpath-cwd" && dry onpath adversarial-review.sh PATH="$T/onpath:$PATH")"
same "a bare name resolved through PATH runs from the driver's directory (dry run, exit 0)" "0" "$rc"
reviewed onpath && ok "…and builds the review prompt" || bad "…but printed no prompt: $(head -c 300 "$T/onpath.err")"
[ -e "$T/onpath-decoy.loaded" ] && bad "onpath: the module set in the CWD was sourced" \
  || ok "onpath: the module set in the CWD was never sourced"

# ar_repo_root (:123) cannot fail: git, else pwd -P, else "unknown-cwd". The function as the driver defines it,
# called under errexit: in a plain directory outside any work tree it is that directory, physically; in a
# directory deleted under the shell (git exits 128, pwd -P fails) it is unknown-cwd — and the shell goes on.
rr_fn="$(grep -E '^ar_repo_root\(\) \{' "$AR")"
same "premise: the driver defines ar_repo_root on one line" "1" "$(printf '%s\n' "$rr_fn" | grep -c .)"
mkdir -p "$T/rr-plain" "$T/rr-gone"; ln -s "$T/rr-plain" "$T/rr-plain-link"
# shellcheck disable=SC2016  # expanded by the inner bash
rr_call='set -euo pipefail; eval "$1"; r="$(ar_repo_root)"; printf "%s|survived" "$r"'
same "ar_repo_root outside a work tree: the physical current directory" "$(cd "$T/rr-plain" && pwd -P)|survived" \
  "$(cd "$T/rr-plain-link" && GIT_CEILING_DIRECTORIES="$T" bash -c "$rr_call" _ "$rr_fn" 2>/dev/null)"
same "ar_repo_root in a deleted directory: unknown-cwd, under errexit, and the shell goes on" "unknown-cwd|survived" \
  "$(cd "$T/rr-gone" && rmdir "$T/rr-gone" && bash -c "$rr_call" _ "$rr_fn" 2>/dev/null)"
# At the caller: a whole review run from a deleted directory completes, and the run log's project column (17,
# log_project = basename of ar_repo_root, adversarial-ledger.sh:44-46) says unknown-cwd — not "unknown", which
# is what an empty root would give.
mkdir -p "$T/rr-gone-run"
rc="$(cd "$T/rr-gone-run" && rmdir "$T/rr-gone-run" && AR_TEST_FULL=1 dry rrgone "$AR" PATH="$ROOT/tests/adversarial/mocks:$PATH")"
same "a whole review from a deleted directory completes (exit 0)" "0" "$rc"
# The lane rows only: the header ("date") and the run's SUMMARY line have no project column.
same "…and logs its project as unknown-cwd" "unknown-cwd" \
  "$(awk -F'\t' '$1 != "date" && $1 != "SUMMARY" { print $17 }' "$T/home-rrgone/.zuvo/adversarial.log" 2>/dev/null | sort -u | tr '\n' ' ' | sed 's/ $//')"

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
# Its own reading of Main (not (2)'s main_calls): this section must hold when run by itself.
phases="$(main_calls_of | grep '^ar_' | tr '\n' ' ')"
same "premise: $(printf '%s' "$phases" | wc -w | tr -d ' ') phases to check — every ar_* function AR_REQUIRED_FNS names" \
  "$(driver_words AR_REQUIRED_FNS | grep -c '^ar_')" "$(printf '%s' "$phases" | wc -w | tr -d ' ')"
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
