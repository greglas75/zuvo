#!/usr/bin/env bash
# test-comment-pass-wiring.sh — every skill that runs the comment pass loads the include, runs the
# pass at its slot and checks it off; the include states the rules those skills rely on.
#
# Targets: skills whose SKILL.md, references/*.md or agents/*.md mention comment-pass.md, plus
# PINNED, so a pinned skill that loses every mention fails instead of leaving the set unseen.
# Per target: W1 a load declaration at the depth validate-skills.sh requires (../../ from SKILL.md,
# ../../../ from agents/ and references/), W2 a comment-pass step naming the helper or the include,
# W3 a checklist row carrying [GATE: comment-pass].
# A text contract: it reads the markdown and cannot run a skill or the helper.
#
# Standalone, git-free, bash 3.2-compatible. CPW_ROOT points it at another copy of the tree.
set -uo pipefail

ROOT="${CPW_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
INC="$ROOT/shared/includes/comment-pass.md"
PINNED="build"
npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; nfail=$((nfail + 1)); }
check() { if [ "$2" -eq 0 ]; then pass "$1"; else bad "$1"; fi; }
# Ends a pipeline instead of `grep -q`: under pipefail an early-exiting grep can SIGPIPE its producer.
has() { grep "$@" > /dev/null; }

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

echo "== comment-pass include =="
rc=0; [ -f "$INC" ] || rc=1
for f in "$ROOT"/shared/includes/*/comment-pass.md "$ROOT"/shared/*/*/comment-pass.md; do [ -e "$f" ] && rc=1; done
check "the include sits at top level: shared/includes/comment-pass.md, and nowhere deeper" "$rc"

lines=$(awk 'END { print NR }' "$INC" 2>/dev/null); lines=${lines:-0}
rc=0; [ "$lines" -ge 40 ] && [ "$lines" -le 160 ] || rc=1
check "the include is 40-160 lines (got $lines)" "$rc"

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
rc=0; grep -F "'\$2==r'" "$INC" 2>/dev/null | has -F '${ZUVO_COMMENT_AUDIT_LOG:-${ZUVO_HOME:-$HOME/.zuvo}/comment-audit.log}' || rc=1
check "rc 0 looks the run id up in the ledger with an explicit command" "$rc"
rc=0; grep -qF 'git status --porcelain' "$INC" 2>/dev/null || rc=1
check "the scope is cross-checked against git status --porcelain" "$rc"
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
grep -qE 'TaskCreate|TaskUpdate|TaskList|EnterPlanMode|ExitPlanMode|AskUserQuestion|run_in_background|TeamCreate|SendMessage|~/\.claude/' "$INC" 2>/dev/null && rc=1
grep -qE 'CQ1-CQ|Q1-Q[0-9]|CAP1-CAP|AP1-AP|[0-9]+/(19|25|29|34|40)([^0-9]|$)' "$INC" 2>/dev/null && rc=1
check "portable: no host-only tool names, no ~/.claude/ path, no gate range or /40-style threshold" "$rc"

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
        head = (!fence && /^#+ /); item = /^[[:space:]]*[0-9]+[a-z]?[.)][[:space:]]/
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
rc=0; printf '%s\n' "$s31" | grep -F 'BUILD_BASE=<sha>' | has -F 'git rev-parse -q --verify HEAD || git hash-object -t tree /dev/null' || rc=1
check "build 3.1 prints BUILD_BASE=<sha>, the empty tree in an unborn repo" "$rc"
s2c=$(section "$B" '^### 4[.]2c ')
for want in '~/.zuvo/comment-audit --base' '--files' 'COMMENT_SCOPE' 'proceed to 4.3' 'BLOCKED rc=<n>' \
             'ledger' '[GATE: comment-pass] BLOCKED rc=1 ids=' 'The one exception is the exit valve' \
             'BLOCKED rc=2 base unknown' 'BLOCKED rc=0 no ledger row' 'CHECK settled:' \
             'a fix creates or edits' 're-run the 4.2 verification' \
             'N/A (no files written)' 'N/A (run=<id> no audited source)'; do
  rc=0; printf '%s\n' "$s2c" | has -F -- "$want" || rc=1
  check "build 4.2c says: $want" "$rc"
done
rc=0; printf '%s\n' "$s2c" | grep -F '~/.zuvo/comment-audit --base "$BUILD_BASE"' | has -F -- '--files' || rc=1
printf '%s\n' "$s2c" | has -F 'BUILD_BASE=<sha printed in 3.1>' || rc=1
check "build 4.2c runs one scoped helper command on the BUILD_BASE printed in 3.1" "$rc"
row_forms() { grep -F '(ledger-verified)' | grep -F 'N/A (no files written)' | has -F 'N/A (run=<id> no audited source)'; }
rc=0; block "$B" '^EXECUTION VERIFICATION' | grep -F '[ALL] [ ] COMMENTS: [GATE: comment-pass]' | row_forms || rc=1
check "build 4.3 COMMENTS row accepts PASS (ledger-verified) and both N/A forms" "$rc"
rc=0; block "$B" '^COMPLETION GATE CHECK' | grep -E '^\[ \].*\[GATE: comment-pass\]' | row_forms || rc=1
check "build COMPLETION GATE CHECK row accepts PASS (ledger-verified) and both N/A forms" "$rc"
rc=0; section "$B" '^### 4[.]6 ' | awk 'BEGIN { RS = "" } { gsub(/\n/, " "); print }' | grep -E '4\.2c|comment-audit' \
  | grep 'git add' | has 'changed or created' || rc=1
check "build 4.6 re-runs the pass before git add when any file was changed or created since the last clean run" "$rc"
rc=0; section "$B" '^### 4[.]6b ' | has '4\.2c' || rc=1
check "build 4.6b re-runs the pass before its test: commit" "$rc"

echo "== marker vocabulary =="
stray=$(grep -rnE '\[GATE: comment-pass\] (WARN|FAIL|SKIP|SKIPPED|DEGRADED|PARTIAL)' "$ROOT/skills" "$ROOT/shared" 2>/dev/null | head -3)
rc=0; [ -z "$stray" ] || rc=1
check "no skill or include prints a [GATE: comment-pass] value outside PASS / N/A / BLOCKED${stray:+ — $stray}" "$rc"

printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"
[ "$nfail" -eq 0 ]
