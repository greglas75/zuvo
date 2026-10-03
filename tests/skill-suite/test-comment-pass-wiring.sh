#!/usr/bin/env bash
# test-comment-pass-wiring.sh — every skill that runs the comment pass loads the include, runs the
# pass at its slot and checks it off; the include states the rules those skills rely on.
#
# Targets: skills whose SKILL.md, references/*.md or agents/*.md mention comment-pass.md, plus
# PINNED, so a pinned skill that loses every mention fails instead of leaving the set unseen.
# Per target: W1 a load declaration at the depth validate-skills.sh requires (../../ from SKILL.md,
# ../../../ from agents/ and references/), W2 a comment-pass step (a heading, a numbered item or a
# bold-lead paragraph) naming the helper or the include, W3 a checklist row carrying
# [GATE: comment-pass]. Each slot then carries the build pilot's 4.2c shape: marker forms, ledger
# check, rc handling, exit valve, a BLOCKED for a missing base and a recheck before git add.
# Refactor 3d is checked as a pointer to 0b: its base binding, its recheck and the literal "0b's sequence".
# Mostly a text contract: it reads the markdown and cannot run a skill. Two parts compute instead:
# the include's numbers and its ledger lookup are run against the helper's own python modules, and
# a self-test reruns this file on mutated copies of the tree, where the check that owns each mutation
# must turn FAIL.
#
# Level: medium — reads the tree, writes only under mktemp directories, runs python3 and itself; no
# git, no network, no sleep. Bash 3.2-compatible. CPW_ROOT points it at another copy of the tree.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="${CPW_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
INC="$ROOT/shared/includes/comment-pass.md"
PINNED="build execute review refactor"
npass=0; nfail=0
WT="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
trap 'rm -rf "$WT"' EXIT
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; nfail=$((nfail + 1)); }
check() { if [ "$2" -eq 0 ]; then pass "$1"; else bad "$1"; fi; }
# Ends a pipeline instead of `grep -q`: under pipefail an early-exiting grep can SIGPIPE its producer.
has() { grep "$@" > /dev/null; }
# Succeeds only when grep ran and matched nothing: a missing file (rc 2) is not an absence.
absent() { local rc=0; grep "$@" > /dev/null 2>&1 || rc=$?; [ "$rc" -eq 1 ]; }

# Code fences are tracked so a `# comment` line inside a bash block is never read as a heading.
heading_line() { # <file> <ERE> — line number of the first heading outside fences that matches
  awk -v re="$2" '/^[[:space:]]*```/ { fence = !fence; next } !fence && $0 ~ re { print NR; exit }' "$1" 2>/dev/null
}
section() { # <file> <ERE> — that heading and its body, up to the next heading of the same or a higher level
  awk -v re="$2" '
    /^[[:space:]]*```/ { fence = !fence; if (on) print; next }
    !fence && /^#+ / { lvl = index($0, " ") - 1
                       if (on && lvl <= level) exit
                       if (!on && $0 ~ re) { on = 1; level = lvl } }
    on { print }' "$1" 2>/dev/null
}
block() { # <file> <ERE> — from the matching line to the end of its code fence
  awk -v re="$2" '!on && $0 ~ re { on = 1 } on && /^[[:space:]]*```/ { exit } on { print }' "$1" 2>/dev/null
}
paragraphs() { # <file> — one line per blank-line-separated paragraph
  awk 'BEGIN { RS = "" } { gsub(/\n/, " "); print }' "$1" 2>/dev/null
}
skill_files() { # <skill> — its SKILL.md, references/*.md and agents/*.md, one per line
  local f
  for f in "$ROOT/skills/$1/SKILL.md" "$ROOT/skills/$1"/references/*.md "$ROOT/skills/$1"/agents/*.md; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
# These take the ERE through the environment: awk -v would eat its backslashes. line_of and between
# match their anchors outside code fences only, like section and block; fenced_line_of is for a list
# that itself lives in a code block.
line_of() { # <file> <ERE> — line number of the first matching line outside code fences
  CPW_RE="$2" awk 'BEGIN { re = ENVIRON["CPW_RE"] } /^[[:space:]]*```/ { fence = !fence; next }
    !fence && $0 ~ re { print NR; exit }' "$1" 2>/dev/null
}
fenced_line_of() { # <file> <ERE> — line number of the first matching line, fenced lines included
  CPW_RE="$2" awk 'BEGIN { re = ENVIRON["CPW_RE"] } $0 ~ re { print NR; exit }' "$1" 2>/dev/null
}
between() { # <file> <start ERE> <end ERE> — from the first start line up to, not including, the next end line
  # Printed only once the end line is reached: a lost end anchor gives an empty capture, never the rest of the file.
  CPW_S="$2" CPW_E="$3" awk 'BEGIN { s = ENVIRON["CPW_S"]; e = ENVIRON["CPW_E"] }
    /^[[:space:]]*```/ { fence = !fence; if (on) buf = buf $0 "\n"; next }
    !fence && on && $0 ~ e { printf "%s", buf; exit } !fence && !on && $0 ~ s { on = 1 } on { buf = buf $0 "\n" }' "$1" 2>/dev/null
}
paras() { # stdin — one line per blank-line-separated paragraph, whitespace squeezed
  awk 'BEGIN { RS = "" } { gsub(/[[:space:]]+/, " "); print }'
}
lacks() { # <text> <fixed string>... — the strings the text does not contain, as " [s1] [s2]"
  local text="$1" w out=""; shift
  for w in "$@"; do printf '%s\n' "$text" | has -F -- "$w" || out="$out [$w]"; done
  printf '%s' "$out"
}
ordered() { # <n1> <n2>... — every value present and strictly increasing
  local prev="" n
  for n in "$@"; do
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    if [ -n "$prev" ] && [ "$n" -le "$prev" ]; then return 1; fi
    prev=$n
  done
}
row_forms() { grep -F '(ledger-verified)' | grep -F 'N/A (no files written)' | has -F 'N/A (run=<id> no audited source)'; }
# <binding> is what follows `COMMENT_BASE` = , backticks included (`HEAD`). It must be present, and every
# backticked `COMMENT_BASE` = `…` in the text must equal it: a suffix such as ~1 is a different value, and a
# second, different binding fails too.
binds_base() { # <label> <squeezed text> <binding>
  local want="\`COMMENT_BASE\` = $3" other rc=0
  printf '%s\n' "$2" | has -F -- "$want" || rc=1
  other=$(printf '%s\n' "$2" | grep -oE '`COMMENT_BASE` = `[^`]*`' | grep -vxF -- "$want" | sort -u | tr '\n' ' ')
  other=${other% }
  [ -z "$other" ] || rc=1
  check "$1 binds $want and nothing else${other:+ (also: $other)}" "$rc"
}
binds_scope() { # <label> <squeezed text> <phrase> — that binding, and no second, different one
  local want="\`COMMENT_SCOPE\` = $3" all mine rc=0
  all=$(printf '%s\n' "$2" | grep -oF -- '`COMMENT_SCOPE` = ' | wc -l)
  mine=$(printf '%s\n' "$2" | grep -oF -- "$want" | wc -l)
  [ "$((mine))" -ge 1 ] && [ "$((all))" -eq "$((mine))" ] || rc=1
  check "$1 binds $want and nothing else (bindings: $((all)), matching: $((mine)))" "$rc"
}
# The build pilot's 4.2c, step for step: <label> <slot text> <base binding> <scope phrase> (any wrapping; squeezed here).
shape() {
  local t m rc
  t=$(printf '%s\n' "$2" | paras)
  binds_base "$1" "$t" "$3"
  binds_scope "$1" "$t" "$4"
  m=$(lacks "$t" '[GATE: comment-pass] PASS run=<id> files=<n> justified=<k>' 'N/A (run=<id> no audited source)' \
    '`N/A (no files written)` is printed only when the scope is empty (include step 1), with no run' '[GATE: comment-pass] BLOCKED rc=<n>' \
    '[GATE: comment-pass] BLOCKED rc=0 no ledger row for run=<id>' "the include's \`awk\` lookup: a row for every path in scope" \
    'a scoped path without a row → re-run over the full scope')
  printf '%s\n' "$t" | has -F ', `N/A (no files written)` or `N/A (run=<id> no audited source)`' \
    && m="$m [N/A (no files written) must not follow the ledger check]"
  rc=0; [ -z "$m" ] || rc=1
  check "$1 prints the three marker forms and checks a ledger row for every path in scope${m:+ — missing:$m}" "$rc"
  m=$(lacks "$t" 'A settling edit (a test added, a number removed) means one more helper run' \
    "the marker takes that last clean run's id")
  rc=0; [ -z "$m" ] || rc=1
  check "$1 runs the helper once more after a settling edit and takes that run's id${m:+ — missing:$m}" "$rc"
  m=$(lacks "$t" 'COMMENT_BASE=<sha printed' '~/.zuvo/comment-audit --base "$COMMENT_BASE" --files' '|| rc=$?' 'COMMENT_SCOPE' \
    'checked against `git status --porcelain --untracked-files=all` — a check on the record, never a source of paths (files other sessions changed stay out)' \
    'rc 1' 'no backlog' 'The one exception is the exit valve' '[GATE: comment-pass] BLOCKED rc=1 ids=<id,…> <reason>' \
    'CHECK settled: <file:line> test|removed|softened' 'any other rc')
  printf '%s\n' "$t" | has -F 'which never adds paths' && m="$m [no 'which never adds paths']"
  rc=0; [ -z "$m" ] || rc=1
  check "$1 runs one scoped helper command with the pilot's rc handling and exit valve${m:+ — missing:$m}" "$rc"
  m=$(lacks "$t" 'COMMENT_BASE=<sha>' 'git rev-parse -q --verify HEAD || git hash-object -t tree /dev/null' \
    'the same resolver (`git rev-parse -q --verify HEAD || git hash-object -t tree /dev/null`) only when' '[GATE: comment-pass] BLOCKED rc=2 base unknown')
  printf '%s\n' "$t" | has -F '`git rev-parse HEAD` only when' && m="$m [no bare git rev-parse HEAD fallback]"
  rc=0; [ -z "$m" ] || rc=1
  check "$1 prints its base as a literal and is BLOCKED on a missing base${m:+ — missing:$m}" "$rc"
}
recheck() { # <label> <text> — one paragraph re-runs the pass before git add after a later write
  local rc=0
  printf '%s\n' "$2" | paras | grep -F 'changed or created' | grep -F 'last clean' \
    | awk '{ l = tolower($0); r = index(l, "re-run"); g = index(l, "git add"); if (r && g && r < g) ok = 1 } END { exit !ok }' || rc=1
  check "$1 re-runs the pass before git add when a file in scope changed or was created after the last clean run" "$rc"
}

echo "== comment-pass include =="
rc=0; [ -f "$INC" ] || rc=1
for f in "$ROOT"/shared/includes/*/comment-pass.md "$ROOT"/shared/*/*/comment-pass.md; do [ -e "$f" ] && rc=1; done
check "the include sits at top level: shared/includes/comment-pass.md, and nowhere deeper" "$rc"

# The ceiling is the plan's R10 budget (docs/specs/*comment-pass-plan.md): every slot loads the whole
# include into its run. There is no floor to guess: R10's sections, checked next, are what must be there.
INC_MAX_LINES=160
lines=$(awk 'END { print NR }' "$INC" 2>/dev/null); lines=${lines:-0}
rc=0; [ "$lines" -gt 0 ] && [ "$lines" -le "$INC_MAX_LINES" ] || rc=1
check "the include fits R10's budget of $INC_MAX_LINES lines (got $lines)" "$rc"
nums=""; rc=0
for h in 'What the helper judges' 'What to do with each comment' 'Inputs' 'Sequence' 'Marker' 'Never' \
         'Freshness of other gates' 'Telemetry'; do
  n=$(heading_line "$INC" "^## $h"); nums="$nums ${n:-?}"
done
# shellcheck disable=SC2086 # one line number per argument
ordered $nums || rc=1
[ "$(section "$INC" '^## Telemetry' | awk 'NR > 1 && NF { n++ } END { print n + 0 }')" -gt 0 ] || rc=1
check "the include has R10's eight sections in order, the last with a body (heading lines:$nums)" "$rc"
steps=$(section "$INC" '^## Sequence' | awk '/^[[:space:]]*```/ { f = !f; next } !f && /^[0-9]+\. \*\*/ { printf "%d ", $1 }')
nsteps=$(printf '%s' "$steps" | awk '{ print NF }'); nsteps=${nsteps:-0}
cited=$(paras < "$INC" | grep -oE '(^|[^a-z])step [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -n 1)
rc=0; [ "$nsteps" -gt 0 ] && [ "$steps" = "$(awk -v n="$nsteps" 'BEGIN { for (i = 1; i <= n; i++) printf "%d ", i }')" ] || rc=1
[ -n "$cited" ] && [ "$cited" -le "$nsteps" ] || rc=1
between "$INC" '^1\. \*\*Nothing written\*\*' '^2\. \*\*' | paras | has -F '[GATE: comment-pass] N/A (no files written)' || rc=1
check "the Sequence numbers its steps 1..n with no gap (${steps:-none}), every 'step N' the include cites exists (highest: ${cited:-none}), and step 1 is the empty-scope N/A the slots cite as include step 1" "$rc"

rc=0; grep -qF '[GATE: comment-pass] PASS run=<id> files=<n> justified=<k>' "$INC" 2>/dev/null || rc=1
check "defines the PASS marker with run, files and justified" "$rc"
rc=0; grep -qF '[GATE: comment-pass] N/A (' "$INC" 2>/dev/null || rc=1
check "defines the N/A marker with a reason" "$rc"
rc=0; grep -qF '[GATE: comment-pass] BLOCKED rc=' "$INC" 2>/dev/null || rc=1
check "defines the BLOCKED marker with the helper's rc" "$rc"
rc=0; grep -qi 'never backlog' "$INC" 2>/dev/null || rc=1
check "a breach is fixed in-run: says never backlog" "$rc"
rc=0; grep -qE '[Nn]ever set[^.]*ZUVO_COMMENT_' "$INC" 2>/dev/null || rc=1
check "forbids setting ZUVO_COMMENT_*" "$rc"
rc=0; paragraphs "$INC" | grep -F 'comment_pass:' | has -i 'retro' || rc=1
check "tells the skill to paste the comment_pass: line into the retro" "$rc"
rc=0; grep -qE '(^|[^0-9A-Za-z])CQ13([^0-9]|$)' "$INC" 2>/dev/null || rc=1
check "cites CQ13 by id" "$rc"
rc=0; grep -F 'KEEP' "$INC" 2>/dev/null | grep -F 'rules/testing.md' | has -i 'oracle' || rc=1
check "names the rules/testing.md oracle comments as KEEP" "$rc"
rc=0; paragraphs "$INC" | grep -F 'normhash' | grep -F 'ONLY' | grep -F 'python' | grep -F 'php' | has -F 'c-family' || rc=1
check "limits the normhash claim to python, php and the c-family" "$rc"
rc=0; grep -F 'TEST-OR-GO' "$INC" 2>/dev/null | has -i 'quantitative' || rc=1
check "scopes TEST-OR-GO to quantitative claims" "$rc"
rc=0; paragraphs "$INC" | grep -F 'ledger' | has -F 'INVALID' || rc=1
check "a PASS whose run id is not in the ledger is INVALID" "$rc"
rc=0; paragraphs "$INC" | grep -F 'env=' | has -i 'human' || rc=1
check "a marker carrying env= needs a human-set reason" "$rc"
rc=0; grep -F "'\$2==r {print \$6}'" "$INC" 2>/dev/null | has -F '${ZUVO_COMMENT_AUDIT_LOG:-${ZUVO_HOME:-$HOME/.zuvo}/comment-audit.log}' || rc=1
m=$(lacks "$(paras < "$INC")" 'a ledger row for every path in `COMMENT_SCOPE`' 'compare them with the scope list' \
  'A scoped path without a row → the run missed part of the scope: re-run step 2 over the full scope.' \
  'A PASS printed without this check is INVALID.')
[ -z "$m" ] || rc=1
check "rc 0 looks the run id up in the ledger with an explicit command" "$rc"
rc=0; grep -qF '`git status --porcelain --untracked-files=all`' "$INC" 2>/dev/null || rc=1
check "the scope is cross-checked against git status --porcelain --untracked-files=all (a new directory lists its files, not dir/)" "$rc"
rc=0; m=$(lacks "$(paras < "$INC")" 'porcelain C-quotes paths with special characters, so compare them unquoted' \
  'unless it is gitignored, or the run deleted it or reverted it to the base: such a path drops out of the scope')
[ -z "$m" ] || rc=1
check "the include compares porcelain paths unquoted and drops gitignored, deleted or reverted paths${m:+ — missing:$m}" "$rc"
rc=0; grep -qF '[GATE: comment-pass] N/A (no files written)' "$INC" 2>/dev/null || rc=1
check "N/A for an empty scope reads N/A (no files written)" "$rc"
rc=0; grep -F 'CHECK' "$INC" 2>/dev/null | has -F 'rc 0' || rc=1
check "CHECK lines are settled on rc 0 too, not only on a breach" "$rc"
rc=0; grep -qF '[GATE: comment-pass] BLOCKED rc=1 ids=' "$INC" 2>/dev/null || rc=1
check "the exit valve for unfixable findings over the cap is BLOCKED rc=1 ids=…" "$rc"
rc=0; grep -F 'exit valve' "$INC" 2>/dev/null | has -F 'one exception' || rc=1
grep -qF 'rc 1 only ever means findings' "$INC" 2>/dev/null || rc=1
check "step 3 loops to rc 0 with the exit valve as its one exception; rc 1 only ever means findings" "$rc"
rc=0; grep -qF 'CHECK settled: <file:line> test|removed|softened' "$INC" 2>/dev/null || rc=1
grep -qF 'settle each claim once' "$INC" 2>/dev/null || rc=1
check "CHECK stop rule: settle each claim once and report it as CHECK settled:" "$rc"
rc=0; grep -qF 'a fix creates or edits' "$INC" 2>/dev/null || rc=1
grep -qF 'never adds paths' "$INC" 2>/dev/null || rc=1
check "the scope grows with files a fix creates or edits; git never adds paths" "$rc"
rc=0; paragraphs "$INC" | grep -F 'anything but comment lines' | has -F 'verification' || rc=1
check "a change beyond comment lines re-runs the calling skill's verification" "$rc"
rc=0; grep -qF 'git hash-object -t tree /dev/null' "$INC" 2>/dev/null || rc=1
check "an unborn repository measures against the empty tree" "$rc"
rc=0; paragraphs "$INC" | grep -F 'env=' | has -F 'no reason slot' || rc=1
check "env= goes into the marker, its reason into the report: the marker has no reason slot" "$rc"
# Codex/Cursor/Antigravity/Kimi ship the include as is: no host-only tool names or paths, and no
# gate range or count denominator that drifts when the gate registry grows.
rc=0
absent -E 'TaskCreate|TaskUpdate|TaskList|EnterPlanMode|ExitPlanMode|AskUserQuestion|run_in_background|TeamCreate|SendMessage|~/\.claude/' "$INC" || rc=1
absent -E 'CQ1-CQ|Q1-Q[0-9]|CAP1-CAP|AP1-AP|[0-9]+/(19|25|29|34|40)([^0-9]|$)' "$INC" || rc=1
check "portable: no host-only tool names, no ~/.claude/ path, no gate range or /40-style threshold" "$rc"

# The include's numbers and its ledger lookup, run against the helper's own modules: what the include
# tells an agent must be what the helper does.
ZH="$ROOT/scripts/zuvo-home"; PY3="$(command -v python3)"; BASH3="$(command -v bash)"
defaults=$(PYTHONPATH="$ZH" "${PY3:-python3}" -c 'import zuvo_comment_rules as R
t = R.load_thresholds({})
print(*(R.format_threshold(t[k].value) for k in ("density", "min_lines", "block", "justify_max")), R.REASON_MIN)' 2>&1)
read -r dens minl blk jmax rmin rest <<EOF
$defaults
EOF
rc=0; [ -n "${rmin:-}" ] && [ -z "${rest:-}" ] || rc=1
m=$(lacks "$(paras < "$INC")" "above $dens, on a file with at least $minl authored lines" "a comment block of $blk+ lines" \
  "\`ZUVO_COMMENT_JUSTIFY_MAX\` (default $jmax)" "a reason of $rmin+ characters")
[ -z "$m" ] || rc=1
check "the include quotes the helper's defaults: density $dens, $minl lines, block $blk+, $jmax justified, reason $rmin+${m:+ — missing:$m}" "$rc"
cmd=$(awk '/^[[:space:]]*awk -F/ { sub(/^[[:space:]]+/, ""); print; exit }' "$INC" 2>/dev/null)
run_a=20250102T030405Z-71; run_b=20250102T030406Z-72
PYTHONPATH="$ZH" "${PY3:-python3}" - "$WT/ledger.log" "$run_a" "$run_b" > "$WT/ledger.err" 2>&1 <<'PYEOF'
import sys
import zuvo_comment_ledger as L
path, run_a, run_b = sys.argv[1:4]
where = L.Origin("proj", "abcdef1", "1234567", "sha1")
rows = L.format_rows(run_a, where, "t", [("a dir/x.sh", "n/a (binary)", "sh", None, "-"),
                                         ("b.py", "n/a (binary)", "python", None, "-")], {})
rows += L.format_rows(run_b, where, "t", [("c.sh", "n/a (binary)", "sh", None, "-")], {})
L.append(rows, path)
PYEOF
lookup() { # <run id> — the include's own awk command for that id, over the ledger the real writer made
  [ -n "$cmd" ] && env -i PATH="$PATH" HOME="$WT/home" ZUVO_COMMENT_AUDIT_LOG="$WT/ledger.log" "$BASH3" -c "${cmd//<id>/$1}"
}
got_a=$(lookup "$run_a"); rc_a=$?; got_b=$(lookup "$run_b"); got_none=$(lookup 20250102T030407Z-73); rc_none=$?
rc=0; [ "$rc_a" -eq 0 ] && [ "$got_a" = "a dir/x.sh
b.py" ] && [ "$got_b" = "c.sh" ] || rc=1
check "the include's ledger lookup lists exactly one run's files (tab-split, a path with a space intact): got [$(printf '%s' "$got_a" | tr '\n' '|')] [$got_b]$(sed -n 1p "$WT/ledger.err")" "$rc"
rc=0; [ "$rc_none" -eq 0 ] && [ -z "$got_none" ] || rc=1
check "the lookup prints nothing for a run id with no row — the include's BLOCKED rc=0 no-ledger-row case (got [$got_none])" "$rc"
expr=$(printf '%s\n' "$cmd" | sed -n 's/.*"\(\${ZUVO_COMMENT_AUDIT_LOG[^"]*\)".*/\1/p')
rc=0; seen=""; diffs=""
for envset in 'ZUVO_COMMENT_AUDIT_LOG=/l/x.log ZUVO_HOME=/z HOME=/h' 'ZUVO_HOME=/z HOME=/h' 'HOME=/h' \
              'ZUVO_COMMENT_AUDIT_LOG= ZUVO_HOME= HOME=/h'; do
  # shellcheck disable=SC2086 # one VAR=value per word
  sh_path=$(env -i $envset "$BASH3" -c "printf '%s' \"$expr\"" 2>&1)
  # shellcheck disable=SC2086
  py_path=$(env -i $envset PYTHONPATH="$ZH" "${PY3:-python3}" -c 'import os, zuvo_comment_ledger as L; print(L.ledger_path(os.environ))' 2>&1)
  [ -n "$expr" ] && [ "$sh_path" = "$py_path" ] || { rc=1; diffs="$diffs [$envset: include $sh_path, helper $py_path]"; }
  in_list "$sh_path" "$seen" || seen="$seen $sh_path"
done
# shellcheck disable=SC2086 # one path per argument
[ "$(printf '%s\n' $seen | awk 'END { print NR }')" -eq 3 ] || rc=1
check "the include's ledger path is the helper's ledger_path() for every env combination (distinct:$seen)${diffs}" "$rc"

echo "== target skills =="
mentioning=""
for d in "$ROOT"/skills/*/; do
  s=$(basename "$d"); hit=1
  while IFS= read -r f; do [ -n "$f" ] && grep -qF 'comment-pass.md' "$f" && hit=0; done <<EOF
$(skill_files "$s")
EOF
  [ "$hit" -eq 0 ] && mentioning="$mentioning $s"
done
rc=0; missing=""
for p in $PINNED; do in_list "$p" "$mentioning" || missing="$missing $p"; done
[ -z "$missing" ] || rc=1
check "premise: every pinned skill ($PINNED) mentions comment-pass.md —${missing:- none missing}" "$rc"
targets="$mentioning"
for p in $PINNED; do in_list "$p" "$targets" || targets="$targets $p"; done

for s in $targets; do
  w1=1; wrong=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      */SKILL.md) depth='../../'; depth_re='\.\./\.\./' ;;
      *) depth='../../../'; depth_re='\.\./\.\./\.\./' ;;
    esac
    for tok in $(grep -oE '(\.\./)+shared/includes/comment-pass\.md' "$f" | sort -u); do
      [ "$tok" = "${depth}shared/includes/comment-pass.md" ] || wrong="$wrong ${f#"$ROOT"/}:$tok"
    done
    grep -qE "(^|[^./])${depth_re}shared/includes/comment-pass\\.md\`?[[:space:]]*(--|\\(|:)" "$f" && w1=0
  done <<EOF
$(skill_files "$s")
EOF
  [ -z "$wrong" ] || w1=1
  check "W1 $s declares the include at its canonical depth${wrong:+ (wrong depth:$wrong)}" "$w1"

  w2=1
  while IFS= read -r f; do
    awk '
      function flush() { if (buf ~ /~\/\.zuvo\/comment-audit/ || buf ~ /comment-pass[.]md/) found = 1; buf = ""; mode = "" }
      FNR == 1 { flush(); fence = 0 }
      /^[[:space:]]*```/ { fence = !fence }
      {
        head = (!fence && /^#+ /); item = !fence && (/^[[:space:]]*[0-9]+[a-z]?[.)][[:space:]]/ || /^[*][*]/)
        if (head) lvl = index($0, " ") - 1
        if (mode == "head" && head && lvl <= hlvl) flush()
        else if (mode == "item" && (head || item || /^[[:space:]]*$/)) flush()
        if (mode == "" && (head || item) && tolower($0) ~ /comment pass/ && $0 !~ /comment-pass[.]md`?[[:space:]]*--/) {
          mode = head ? "head" : "item"; hlvl = lvl
        }
        if (mode != "") buf = buf "\n" $0
      }
      END { flush(); exit !found }' "$f" && w2=0
  done <<EOF
$(skill_files "$s")
EOF
  check "W2 $s has a comment-pass step that names ~/.zuvo/comment-audit or the include" "$w2"

  w3=1
  while IFS= read -r f; do grep -qE '\[ \].*\[GATE: comment-pass\]' "$f" && w3=0; done <<EOF
$(skill_files "$s")
EOF
  check "W3 $s has a checklist row carrying [GATE: comment-pass]" "$w3"
done

echo "== build slot =="
B="$ROOT/skills/build/SKILL.md"
rc=0; section "$B" '^### DEFERRED' | has -E '^[[:space:]]*\.\./\.\./shared/includes/comment-pass\.md[[:space:]]+-- \[READ at Phase 4\.2c\]' || rc=1
check "build loads the include in its DEFERRED block, read at Phase 4.2c" "$rc"
l2b=$(heading_line "$B" '^### 4[.]2b '); l2c=$(heading_line "$B" '^### 4[.]2c '); l3=$(heading_line "$B" '^### 4[.]3 ')
l4=$(heading_line "$B" '^### 4[.]4 ')
rc=0; [ -n "$l2b" ] && [ -n "$l2c" ] && [ -n "$l3" ] && [ "$l2b" -lt "$l2c" ] && [ "$l2c" -lt "$l3" ] || rc=1
check "build ### 4.2c sits after ### 4.2b and before ### 4.3 (lines ${l2b:-?} < ${l2c:-?} < ${l3:-?})" "$rc"
rc=0; [ -n "$l2c" ] && [ -n "$l4" ] && [ "$l2c" -lt "$l4" ] || rc=1
check "build ### 4.2c runs before the cross-model review ### 4.4 (${l2c:-?} < ${l4:-?})" "$rc"
s2b=$(section "$B" '^### 4[.]2b ')
rc=0; printf '%s\n' "$s2b" | has -i 'proceed to 4\.2c' || rc=1
printf '%s\n' "$s2b" | has -i 'proceed to 4\.3' && rc=1
check "build 4.2b hands off to 4.2c, and no 'proceed to 4.3' is left in it" "$rc"
s31=$(section "$B" '^### 3[.]1 ')
rc=0; printf '%s\n' "$s31" | grep -F 'BUILD_BASE=<sha>' | grep -F '`git status --porcelain --untracked-files=all` snapshot' \
  | has -F 'git rev-parse -q --verify HEAD || git hash-object -t tree /dev/null' || rc=1
check "build 3.1 prints BUILD_BASE=<sha> (the empty tree in an unborn repo) and the git status --porcelain --untracked-files=all snapshot" "$rc"
s2c=$(section "$B" '^### 4[.]2c ')
for want in '~/.zuvo/comment-audit --base' '--files' 'COMMENT_SCOPE' 'proceed to 4.3' 'BLOCKED rc=<n>' \
             'ledger' '[GATE: comment-pass] BLOCKED rc=1 ids=' 'The one exception is the exit valve' \
             'BLOCKED rc=2 base unknown' 'BLOCKED rc=0 no ledger row' 'CHECK settled:' \
             'a fix creates or edits' 're-run the 4.2 verification' \
             'N/A (no files written)' 'N/A (run=<id> no audited source)' \
             'the same resolver (`git rev-parse -q --verify HEAD || git hash-object -t tree /dev/null`) only when this build has committed nothing' \
             'checked against `git status --porcelain --untracked-files=all` and the 3.1 snapshot' \
             "the include's \`awk\` lookup: a row for every path in scope" \
             'A settling edit (a test added, a number removed) means one more helper run' \
             '`N/A (no files written)` is printed only when the scope is empty (include step 1), with no run'; do
  rc=0; printf '%s\n' "$s2c" | has -F -- "$want" || rc=1
  check "build 4.2c says: $want" "$rc"
done
rc=0; printf '%s\n' "$s2c" | grep -F '~/.zuvo/comment-audit --base "$BUILD_BASE"' | has -F -- '--files' || rc=1
printf '%s\n' "$s2c" | has -F 'BUILD_BASE=<sha printed in 3.1>' || rc=1
check "build 4.2c runs one scoped helper command on the BUILD_BASE printed in 3.1" "$rc"
rc=0; block "$B" '^EXECUTION VERIFICATION' | grep -F '[ALL] [ ] COMMENTS: [GATE: comment-pass]' | row_forms || rc=1
check "build 4.3 COMMENTS row accepts PASS (ledger-verified) and both N/A forms" "$rc"
rc=0; block "$B" '^COMPLETION GATE CHECK' | grep -E '^\[ \].*\[GATE: comment-pass\]' | row_forms || rc=1
check "build COMPLETION GATE CHECK row accepts PASS (ledger-verified) and both N/A forms" "$rc"
rc=0; section "$B" '^### 4[.]6 ' | awk 'BEGIN { RS = "" } { gsub(/\n/, " "); print }' | grep -E '4\.2c|comment-audit' \
  | grep 'git add' | has 'changed or created' || rc=1
check "build 4.6 re-runs the pass before git add when any file was changed or created since the last clean run" "$rc"
rc=0; section "$B" '^### 4[.]6b ' | has '4\.2c' || rc=1
check "build 4.6b re-runs the pass before its test: commit" "$rc"

echo "== slot checks on an empty capture =="
# A lost anchor yields an empty capture; every slot check must then fail, never pass vacuously.
empty=$(shape "empty" "" '`HEAD`' "x"; recheck "empty" ""; binds_base "empty" "" '`REFACTOR_SHA`'; binds_scope "empty" "" "x")
rc=0; printf '%s\n' "$empty" | has '^PASS:' && rc=1
nf=$(printf '%s\n' "$empty" | grep -c '^FAIL:'); [ "$nf" -eq 9 ] || rc=1
check "every shape, recheck and binding check fails on an empty capture ($nf of 9 failed)" "$rc"
rs=$(line_of "$ROOT/skills/review/SKILL.md" '^1b\. \*\*Comment pass\*\*')
rc=0; [ -n "$rs" ] || rc=1
[ -z "$(between "$ROOT/skills/review/SKILL.md" '^1b\. \*\*Comment pass\*\*' '^no such end anchor$')" ] || rc=1
check "between() captures nothing when its end anchor is missing (start anchor present at line ${rs:-?})" "$rc"

echo "== execute slot =="
E="$ROOT/skills/execute/SKILL.md"
rc=0; block "$E" '^CORE FILES LOADED:' | has -E '^[[:space:]]*19\. \.\./\.\./shared/includes/comment-pass\.md[[:space:]]+-- DEFERRED \(task dispatch\)' || rc=1
check "execute loads the include as MFL row 19, DEFERRED to task dispatch" "$rc"
c7=$(fenced_line_of "$E" '^7\. HANDLE quality reviewer verdict'); c7a=$(fenced_line_of "$E" '^7a\. RUN comment pass over every file this task created or modified')
c7b=$(fenced_line_of "$E" '^7b\. DISPATCH adversarial')
rc=0; ordered "$c7" "$c7a" "$c7b" || rc=1
check "execute cycle lists 7a. (comment pass) between 7. and 7b. (lines ${c7:-?} < ${c7a:-?} < ${c7b:-?})" "$rc"
h7=$(heading_line "$E" '^### Step 7: '); h7a=$(heading_line "$E" '^### Step 7a: Comment Pass'); h7b=$(heading_line "$E" '^### Step 7b: ')
rc=0; ordered "$h7" "$h7a" "$h7b" || rc=1
check "execute ### Step 7a sits after ### Step 7 and before ### Step 7b (${h7:-?} < ${h7a:-?} < ${h7b:-?})" "$rc"
s7=$(section "$E" '^### Step 7: ')
rc=0; printf '%s\n' "$s7" | has -F 'Proceed to the comment pass (step 7a)' || rc=1
printf '%s\n' "$s7" | has -F 'Proceed to adversarial review (step 7b)' && rc=1
check "execute Step 7 hands off to step 7a, and no 'Proceed to adversarial review (step 7b)' is left in it" "$rc"
a5=$(line_of "$E" '^5\. \*\*Independent test auditor pass'); a5b=$(line_of "$E" '^5b\. \*\*Comment pass:\*\* run Step 7a over every file this task created or modified and print the marker')
a6=$(line_of "$E" '^6\. \*\*Adversarial pass')
rc=0; ordered "$a5" "$a5b" "$a6" || rc=1
check "execute single-agent list carries 5b. Comment pass between the test-audit and adversarial items (${a5:-?} < ${a5b:-?} < ${a6:-?})" "$rc"
s7a=$(section "$E" '^### Step 7a: ')
shape "execute Step 7a" "$s7a" '`HEAD`' "every file this task created or modified"
rc=0; m=$(lacks "$(printf '%s\n' "$s7a" | paras)" "the task's Files field (the list Step 8 stages)" "DONE report" \
  'a new file (test or production) is added to the task'"'"'s Files record before Step 8 stages' \
  'back to the quality reviewer (multi-agent Step 6; single-agent: the quality pass, item 4) for one targeted pass on that test, outside the 3-iteration cap')
[ -z "$m" ] || rc=1
check "execute 7a takes its scope from the Files field and the DONE report, and a new test joins the Files record and the quality review${m:+ — missing:$m}" "$rc"
rc=0; printf '%s\n' "$s7a" | has -F 'comment-pass.md' || rc=1
check "execute Step 7a reads the include" "$rc"
s7c=$(section "$E" '^### Step 7c: ')
rc=0; printf '%s\n' "$s7c" | grep -F 'single-agent mode:' | has -F '[GATE: comment-pass]' || rc=1
check "execute 7c's single-agent marker list names [GATE: comment-pass]" "$rc"
rc=0; printf '%s\n' "$s7c" | grep -F 'multi-agent mode:' | has -E 'quality review `PASS` -> comment pass `PASS`.* -> adversarial' || rc=1
check "execute 7c's multi-agent order reads quality PASS -> comment pass PASS -> adversarial" "$rc"
rc=0; m=$(lacks "$(section "$E" '^### Step 7b: '; section "$E" '^### Step 8: '; between "$E" '^5b\. ' '^6\. \*\*Adversarial pass')" \
  'After quality review and the comment pass (step 7a) pass' 'the comment pass (`[GATE: comment-pass]` PASS or N/A)' \
  're-run it before the commit if anything changed after it')
[ -z "$m" ] || rc=1
check "execute 7b, Step 8 and item 5b name the comment pass in their gate order${m:+ — missing:$m}" "$rc"
rc=0; printf '%s\n' "$s7c" | paras | grep -F '[GATE: comment-pass]' | grep -F 'both modes' | has -F 'BLOCKED_MISSING_GATE' || rc=1
check "execute 7c requires the marker in both modes; a missing one is BLOCKED_MISSING_GATE" "$rc"
recheck "execute 7c" "$s7c"
rc=0; block "$E" '^COMPLETION GATE CHECK [(]per task[)]' \
  | grep -E '^\[ \] Comment pass \(Step 7a\): \[GATE: comment-pass\]' | grep -F '(7b fixes, anything)' | row_forms || rc=1
check "execute per-task COMPLETION GATE CHECK row accepts PASS (ledger-verified) and both N/A forms" "$rc"
I="$ROOT/skills/execute/agents/implementer.md"
rc=0; section "$I" '^## Self-Review Checklist' | grep -E '^- \[ \]' | grep -F '~/.zuvo/comment-audit --base HEAD --files' \
  | grep -F 'DONE' | has -F '7a' || rc=1
check "execute implementer self-review runs ~/.zuvo/comment-audit --base HEAD --files before DONE (shift-left of 7a)" "$rc"

echo "== review slot =="
R="$ROOT/skills/review/SKILL.md"
rc=0; section "$R" '^### DEFERRED' | grep -F 'comment-pass.md' | has -F -- '-- [READ at post-fix gate step 1b — FIX modes only; REPORT -> SKIP]' || rc=1
check "review loads the include in DEFERRED, at post-fix step 1b, FIX modes only" "$rc"
r1=$(line_of "$R" '^1\. \*\*Verify\*\*'); r1b=$(line_of "$R" '^1b\. \*\*Comment pass\*\*'); r2=$(line_of "$R" '^2\. \*\*Adversarial re-validation\*\*')
rc=0; ordered "$r1" "$r1b" "$r2" || rc=1
check "review post-fix 1b. sits between 1. Verify and 2. Adversarial re-validation (${r1:-?} < ${r1b:-?} < ${r2:-?})" "$rc"
spf=$(section "$R" '^### Post-fix gate')
rc=0; printf '%s\n' "$spf" | has -E '^3\. \*\*Commit\*\* only after 1\+1b\+2 pass' || rc=1
printf '%s\n' "$spf" | has -F 'after 1+2 pass' && rc=1
check "review post-fix step 3 commits only after 1+1b+2, and no 'after 1+2' is left" "$rc"
rc=0; printf '%s\n' "$spf" | grep -F 'fix-loop.md' | grep -F 'Commit' | has -F 'step 3' || rc=1
check "review says fix-loop.md's Commit happens at post-fix step 3" "$rc"
s1b=$(between "$R" '^1b\. \*\*Comment pass\*\*' '^2\. \*\*Adversarial re-validation\*\*')
shape "review post-fix 1b" "$s1b" 'the `COMMENT_BASE=<sha>` printed at the start of Phase 4' "every file the fix loop created or modified"
recheck "review post-fix 1b" "$s1b"
p4=$(heading_line "$R" '^## Phase 4: Execute'); pb=$(line_of "$R" '^\*\*Comment base, before the fix loop writes\.\*\*')
pl=$(line_of "$R" '^Read and follow the fix loop protocol')
rc=0; ordered "$p4" "$pb" "$pl" || rc=1
m=$(lacks "$(between "$R" '^\*\*Comment base, before the fix loop writes\.\*\*' '^Read and follow the fix loop protocol' | paras)" \
  "Before the fix loop's first write, and before AUTO-FIX invokes \`zuvo:build\`" 'print `COMMENT_BASE=<sha>` into the transcript' \
  'resolved by `git rev-parse -q --verify HEAD || git hash-object -t tree /dev/null`')
[ -z "$m" ] || rc=1
check "review prints COMMENT_BASE=<sha> at the start of Phase 4, before the fix loop and before AUTO-FIX invokes zuvo:build (${p4:-?} < ${pb:-?} < ${pl:-?})${m:+ — missing:$m}" "$rc"
rc=0; printf '%s\n' "$s1b" | paras | grep -F 'This step always runs, AUTO-FIX included' | has -F "4.6 commit would hide" || rc=1
grep -qiE 'cite (its|the) `\[GATE: comment-pass\]` marker|instead of a second run|A citation is never|AUTO-FIX: zuvo:build.s 4\.2c marker' "$R" && rc=1
check "review 1b always runs, AUTO-FIX included, and no citation shortcut for zuvo:build's marker is left" "$rc"
rc=0; m=$(lacks "$(printf '%s\n' "$s1b" | paras)" "(AUTO-FIX: zuvo:build's 4.6 commit counts as the fix loop's)" \
  'If the pass added a test or changed code, re-run step 1.' \
  "before the commit of any file a later step writes (step 4's gap tests)")
printf '%s\n' "$s1b" | has -F 're-run step 1 for those files' && m="$m [no 're-run step 1 for those files']"
[ -z "$m" ] || rc=1
check "review 1b: build's commit counts as the fix loop's, a changed test re-runs all of step 1, and step 4's gap tests are rechecked${m:+ — missing:$m}" "$rc"
rc=0; block "$R" '^COMPLETION GATE CHECK' | grep -E '^\[ \] FIX modes: \[GATE: comment-pass\]' | row_forms || rc=1
check "review COMPLETION GATE CHECK row (FIX modes) accepts PASS (ledger-verified) and both N/A forms" "$rc"

echo "== refactor slot =="
BS="$ROOT/skills/refactor/references/bootstrap.md"; RM="$ROOT/skills/refactor/references/remediation.md"
CP="$ROOT/skills/refactor/references/completion.md"
rc=0; grep -qE '^[[:space:]]*[0-9]+\. \.\./\.\./\.\./shared/includes/comment-pass\.md[[:space:]]+-- \[READ at Phase 3\.5\]' "$BS" 2>/dev/null || rc=1
check "refactor references/bootstrap.md loads ../../../shared/includes/comment-pass.md at Phase 3.5" "$rc"
f0=$(line_of "$RM" '^0\. \*\*Record the Prove step'); f0b=$(line_of "$RM" '^0b\. \*\*Comment pass'); f1=$(line_of "$RM" '^1\. \*\*Commit the pure refactor')
rc=0; ordered "$f0" "$f0b" "$f1" || rc=1
check "refactor remediation 0b. sits after step 0 and before 1. Commit the pure refactor (${f0:-?} < ${f0b:-?} < ${f1:-?})" "$rc"
s0b=$(between "$RM" '^0b\. \*\*Comment pass' '^1\. \*\*Commit the pure refactor')
shape "refactor remediation 0b" "$s0b" '`HEAD`' "the scope-fence files this run created or modified"
recheck "refactor remediation 0b" "$s0b"
rc=0; m=$(lacks "$(printf '%s\n' "$s0b" | paras)" 'frozen characterization file' '`removed|softened`' 'a test in a NEW file, which joins the scope' 'recorded pass count')
[ -z "$m" ] || rc=1
check "refactor 0b settles a claim in a frozen characterization file without changing what it tests${m:+ — missing:$m}" "$rc"
fc=$(line_of "$RM" '^[[:space:]]+c\. \*\*DEMONSTRATE'); fd=$(line_of "$RM" '^[[:space:]]+d\. \*\*Comment pass'); fe=$(line_of "$RM" '^[[:space:]]+e\. \*\*Commit separately')
rc=0; ordered "$fc" "$fd" "$fe" || rc=1
check "refactor step 3 d. begins with a comment pass, between c. and e. (${fc:-?} < ${fd:-?} < ${fe:-?})" "$rc"
s3d=$(between "$RM" '^[[:space:]]+d\. \*\*Comment pass' '^[[:space:]]+e\. \*\*Commit separately')
t3d=$(printf '%s\n' "$s3d" | paras)
binds_base "refactor 3d" "$t3d" '`REFACTOR_SHA`'
binds_scope "refactor 3d" "$t3d" "every file the fix touched"
rc=0; m=$(lacks "$t3d" "0b's sequence" \
  "\`git rev-parse HEAD\` only when \`git log -1 --format=%s HEAD\` is this run's \`refactor(\` commit" \
  '[GATE: comment-pass] BLOCKED rc=2 base unknown' 'Re-verify: type-check')
[ -z "$m" ] || rc=1
check "refactor 3d points to 0b's sequence, falls back to HEAD only on this run's refactor( commit, is BLOCKED otherwise, then re-verifies${m:+ — missing:$m}" "$rc"
recheck "refactor 3d" "$s3d"
rc=0; block "$CP" '^COMPLETION GATE CHECK' | grep -E '^\[ \].*\[GATE: comment-pass\]' | row_forms || rc=1
check "refactor completion.md COMPLETION GATE CHECK row accepts PASS (ledger-verified) and both N/A forms" "$rc"

echo "== marker vocabulary =="
stray=$(grep -rnE '\[GATE: comment-pass\] (WARN|FAIL|SKIP|SKIPPED|DEGRADED|PARTIAL)' "$ROOT/skills" "$ROOT/shared" 2>/dev/null | head -3)
rc=0; [ -z "$stray" ] || rc=1
check "no skill or include prints a [GATE: comment-pass] value outside PASS / N/A / BLOCKED${stray:+ — $stray}" "$rc"

# Each mutant changes one thing in a copy of the tree and reruns this file on it (CPW_ROOT). The
# check that owns the change must turn FAIL, and only it; the unmutated copy must pass first.
if [ "${CPW_MUTANT:-0}" != 1 ]; then
  echo "== self-test: mutants of a copy of the tree =="
  before=$((npass + nfail)); MT="$WT/tree"
  mkdir -p "$MT/scripts" && cp -R "$ROOT/skills" "$ROOT/shared" "$MT/" && cp -R "$ROOT/scripts/zuvo-home" "$MT/scripts/"
  rerun() { CPW_ROOT="$MT" CPW_MUTANT=1 bash "$SELF" > "$WT/$1.out" 2>&1; echo "$?" > "$WT/$1.rc"; }
  result() { sed -n 's/^RESULT: PASS=\([0-9]*\) FAIL=\([0-9]*\)$/\1 \2/p' "$WT/$1.out"; }
  mutate() { # <name> <file> <awk program> — rewrite one file of the copy, rerun, restore; 1 if nothing changed
    local ok=0
    awk "$3" "$ROOT/$2" > "$MT/$2" && ! cmp -s "$ROOT/$2" "$MT/$2" || ok=1
    rerun "$1"; cp "$ROOT/$2" "$MT/$2"
    return "$ok"
  }
  only_fail() { # <name> <changed: 0|1> <label prefix> — rc != 0 and exactly that one check failed
    local first rc=0
    first=$(awk '/^FAIL: / { print; exit }' "$WT/$1.out")
    [ "$2" -eq 0 ] && [ "$(cat "$WT/$1.rc")" != 0 ] && [ "$(result "$1")" = "$((before - 1)) 1" ] || rc=1
    case "$first" in "FAIL: $3"*) ;; *) rc=1 ;; esac
    check "mutant $1: only '$3' fails (result: $(result "$1"), first: ${first:-none})" "$rc"
  }
  counts() { # <name> <start line> <end line> — "PASS FAIL" between those output lines
    awk -v s="$2" -v e="$3" '$0 == s { on = 1; next } $0 == e { on = 0 } on && /^PASS: / { p++ } on && /^FAIL: / { f++ }
      END { print p + 0, f + 0 }' "$WT/$1.out"
  }
  labelled() { # <name> <ERE on the label> — "PASS FAIL" of the checks whose label matches
    awk -v re="$2" '/^(PASS|FAIL): / { l = substr($0, 7); if (l ~ re) { if (/^PASS/) p++; else f++ } } END { print p + 0, f + 0 }' "$WT/$1.out"
  }

  rerun base
  rc=0; [ "$(cat "$WT/base.rc")" = 0 ] && [ "$(result base)" = "$before 0" ] || rc=1
  check "the unmutated copy passes all $before checks above (result: $(result base))" "$rc"

  ch=0; mutate slot-moved skills/execute/SKILL.md '
    /^[[:space:]]*```/ { fence = !fence }
    !fence && /^(#|##|###) / {
      if (st == 1) st = 2; else if (st == 3) { printf "%s", buf; st = 4 }
      if (st == 0 && /^### Step 7a: /) st = 1; else if (st == 2 && /^### Step 7b: /) st = 3
    }
    st == 1 { buf = buf $0 "\n"; next } { print } END { if (st == 3) printf "%s", buf }' || ch=1
  only_fail slot-moved "$ch" 'execute ### Step 7a sits after ### Step 7 and before ### Step 7b'

  # A missing include or slot is FAIL, never a silent pass: every check that reads it flips.
  rm -f "$MT/shared/includes/comment-pass.md"; rerun include-missing; cp "$ROOT/shared/includes/comment-pass.md" "$MT/shared/includes/"
  inc_base=$(counts base '== comment-pass include ==' '== target skills ==')
  inc_mut=$(counts include-missing '== comment-pass include ==' '== target skills ==')
  others=$(( $(result include-missing | awk '{ print $2 + 0 }') - ${inc_mut#* } ))
  rc=0; [ "${inc_base#* }" = 0 ] && [ "${inc_base% *}" -gt 0 ] && [ "$inc_mut" = "0 ${inc_base% *}" ] && [ "$others" -eq 0 ] || rc=1
  check "mutant include-missing: all ${inc_base% *} include checks fail (PASS FAIL: $inc_mut), none elsewhere ($others)" "$rc"

  ch=0; mutate slot-missing skills/review/SKILL.md '
    /^1b\. \*\*Comment pass\*\*/ { skip = 1 } /^2\. \*\*Adversarial re-validation\*\*/ { skip = 0 } !skip { print }' || ch=1
  rb=$(labelled base '^review (post-fix )?1b'); rm1=$(labelled slot-missing '^review (post-fix )?1b')
  rc=0; [ "$ch" -eq 0 ] && [ "$(cat "$WT/slot-missing.rc")" != 0 ] && [ "${rb#* }" = 0 ] && [ "${rb% *}" -gt 0 ] \
    && [ "$rm1" = "0 ${rb% *}" ] || rc=1
  check "mutant slot-missing: all ${rb% *} review 1b checks fail (PASS FAIL: $rm1)" "$rc"
fi

printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"
[ "$nfail" -eq 0 ]
