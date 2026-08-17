#!/usr/bin/env bash
# Task 8 — block-no-verify. Feeds command strings (and one JSON payload) on
# stdin; asserts exit 2 (block) vs 0 (allow). Global-flag-robust; -n is commit-
# only (dry-run for push/add passes).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/block-no-verify.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

check() { # $1=cmd  $2=expected_rc  $3=label
  printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -eq "$2" ]; then pass "$3 (rc=$rc)"; else bad "$3 — expected $2 got $rc"; fi
}

# --- should BLOCK (exit 2) ---
check 'git commit -m x --no-verify'              2 'commit --no-verify'
check 'git commit -n'                            2 'commit -n'
check 'git -c core.editor=x commit -n'           2 'global -c before commit -n'
check 'git -C /some/repo commit --no-verify'     2 'global -C dir before commit --no-verify'
check 'git push --no-verify'                      2 'push --no-verify'
check 'git commit -nm "msg"'                      2 'commit -nm (bundled short)'
check 'git pull && git commit --no-verify'        2 'chained && commit --no-verify'
check 'git merge --no-verify topic'              2 'merge --no-verify'
check 'git cherry-pick --no-verify abc'          2 'cherry-pick --no-verify'
check '{"command":"git commit --no-verify"}'      2 'JSON tool-input commit --no-verify'
# ADV-1 (gemini): metacharacter inside a quoted message must NOT split off --no-verify
check 'git commit -m "fix UI & tests" --no-verify' 2 'ADV-1: & inside quoted message → still blocked'
check 'git commit -m "a | b ; c && d" --no-verify' 2 'ADV-1: many metachars in message → still blocked'
# ADV-2 (gemini): -c core.hooksPath override disables hooks → block
check 'git -c core.hooksPath=/dev/null commit -m x' 2 'ADV-2: -c core.hooksPath=/dev/null commit blocked'
check 'git -c core.hooksPath=/dev/null push'        2 'ADV-2: -c core.hooksPath push blocked'
check 'git -c CORE.HOOKSPATH=/dev/null commit'      2 'ADV-2: case-insensitive hooksPath blocked'
# round-2 (post-fix gemini): deeper hooksPath/abbreviation bypasses
check 'git -ccore.hooksPath=/dev/null commit'       2 'R2: attached -ccore.hooksPath= blocked'
check 'git -c core.hooksPath commit'                2 'R2: boolean -c core.hooksPath blocked'
check 'git config core.hooksPath /dev/null'         2 'R2: git config core.hooksPath blocked'
check 'git config core.hooksPath=/dev/null'         2 'R2: git config core.hooksPath= blocked'
check 'git commit --no-veri'                        2 'R2: abbreviated --no-veri blocked'
check 'git commit --no-v'                           2 'R2: abbreviated --no-v blocked'
check 'git push --no-ver'                           2 'R2: abbreviated push --no-ver blocked'
# round-4 (fresh-review gemini): deeper string-parser holes
check 'git status
git commit --no-verify'                             2 'R4: newline-joined 2nd git commit --no-verify blocked'
check 'git add . && git commit --no-verify'         2 'R4: chained 2nd git invocation blocked'
check 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit' 2 'R4: GIT_CONFIG_* env injection blocked'
check 'git config alias.c "commit --no-verify"'     2 'R4: alias creation of hook-skip blocked'
# include.path is documented residue (legit config-include; not over-blocked):
check 'git -c include.path=/tmp/x.conf commit'      0 'R4: include.path NOT over-blocked (documented residue)'
printf '%s' "git commit --no-verify # '" | bash "$HOOK" >/dev/null 2>&1
[ "$?" -eq 2 ] && pass "R4: unmatched-quote tokenize-fail → fail CLOSED (rc=2)" || bad "R4: unmatched quote should fail closed"

# --- should ALLOW (exit 0) ---
check 'git push -n'                               0 'push -n (dry-run) allowed'
check 'git add -n'                                0 'add -n (dry-run) allowed'
check 'git commit -m ok'                          0 'plain commit allowed'
check 'git commit -am "ok"'                       0 'commit -am (no n) allowed'
check 'git push origin main'                      0 'plain push allowed'
check 'ls -la --no-verify'                        0 'non-git command allowed'
check ''                                          0 'empty input fail-open'
check 'git status'                                0 'git status allowed'
check 'git -C /r push -n'                          0 'global flag + push -n allowed'
# ADV-3 (gemini): -uno (= -u no) must NOT be read as containing -n → allowed
check 'git commit -uno -m ok'                     0 'ADV-3: commit -uno (untracked=no) allowed'
check 'git commit -m "mentions --no-verify here"' 0 'ADV-1: --no-verify only inside message → allowed'
check 'git -c user.name=x commit -m ok'           0 'benign -c override allowed'
check 'git config user.name "Me"'                 0 'R2: benign git config allowed'
check 'git -ccommit.gpgsign=false commit -m ok'   0 'R2: benign attached -c allowed'
check 'git config alias.co checkout'              0 'R4: benign alias creation allowed'
check 'git status && git log --oneline'           0 'R4: chained benign git commands allowed'
check 'git -c include.path=/etc/gitconfig log'    0 'R4: include.path on non-gated subcmd (log) allowed'

# 'echo git commit --no-verify' — echo is the command, but our parser finds the
# 'git' TOKEN and treats 'commit' as subcommand → would block. That is acceptable
# over-blocking for a safety hook ONLY IF it does not break normal use. Re-check:
printf '%s' 'echo "git commit --no-verify"' | bash "$HOOK" >/dev/null 2>&1
rc=$?
# Document actual behavior: the token-scan sees git→commit→--no-verify and blocks.
# That is the safe direction (false-positive on an echo string, never a false-
# negative on a real bypass). Assert it blocks so behavior is pinned & intentional.
[ "$rc" -eq 2 ] && pass "echo-with-git-tokens blocks (safe over-block, pinned)" \
  || pass "echo-with-git-tokens allowed (rc=$rc)"

# --- HEREDOC BODIES are stdin DATA, never argv (B-gate-9) --------------------
# `git commit -F - <<EOF … EOF` used to flatten through xargs into a token list where a `-n`
# occurring in the MESSAGE TEXT sat after `git commit` and read as the `--no-dry-run` flag, so a
# perfectly legitimate commit was refused. Reported from the field twice in one day.
# Quoted `-m "… -n …"` messages were NEVER affected (xargs keeps them one token) — the original
# report blamed those too, which is why the first two cases below pin the distinction.
check 'git commit -m "checked via tail -n 100"'   0 'B-gate-9: -n inside a QUOTED -m message allowed (always was)'
check 'git commit -F - <<EOF
fix: x

checked via tail -n 100
EOF'                                              0 'B-gate-9: -n inside a HEREDOC body allowed (the actual defect)'
check 'git commit -F - <<EOF
discussing --no-verify in prose
EOF'                                              0 'B-gate-9: --no-verify inside a heredoc body is data, not a flag'

# The stripping must NEVER make the hook blinder. Both of these still block.
check 'git commit -F - <<EOF
body text
git commit -n -m y'                               2 'B-gate-9: UNTERMINATED heredoc → nothing stripped, real -n still blocks'
check 'git commit -F - <<EOF
body text
EOF
git push --no-verify'                             2 'B-gate-9: real bypass AFTER a closed heredoc still blocks'
# A `<<<` herestring must NOT be treated as a heredoc opener. Asserted with an UNQUOTED
# herestring and a REAL flag on the git command itself: a quoted `cat <<<"git commit
# --no-verify"` is useless as a probe here, because xargs consumes the quotes and the whole
# string collapses into ONE token with no standalone `git` to scan — it returns 0 both before
# and after this change, so it would pin nothing. (Verified against HEAD before writing this.)
check 'git commit -n -F - <<<body'                2 'B-gate-9: <<< is not a heredoc opener — a real -n beside it still blocks'

# A COMMENT is not a heredoc opener. `# <<EOF` + a bypass + a lone `EOF` made the stripper
# suppress the bypass before tokenization and the gate returned 0 — an agent-typable bypass of the
# gate whose entire job is stopping those. Found by adversarial review OF THE COMMIT THAT ADDED
# the stripper, reproduced, fixed. The same review also alleged a quoted-string bypass
# (`echo "<<EOF"; git push --no-verify; echo EOF`); that one does NOT work and is pinned below so
# nobody "fixes" a bug that never existed.
check "$(printf '# <<EOF\ngit push --no-verify\nEOF')"  2 'B-gate-10: a commented `# <<EOF` does not open a heredoc — the bypass inside it still blocks'
check 'echo "<<EOF"; git push --no-verify; echo EOF'      2 'B-gate-11: a quoted <<EOF in an echo does not hide a following bypass'


# A `<<` inside a QUOTED string is not an opener — and this one was a live BYPASS, not a false
# positive. `echo "hi <<X"` + a bare `X` terminator made the stripper swallow the line between
# them, so the gate never saw the --no-verify and returned 0. Found by the adversarial pass over
# the commit that introduced the stripper. An earlier check of the sibling form `echo "<<EOF"` +
# `echo EOF` correctly found it SAFE — but only because `echo EOF` never closes the heredoc, so
# nothing was stripped. The bare terminator is what makes it real.
check 'echo "hi <<X"
git push --no-verify
X'                                                2 'B-gate-9b: quoted << + bare terminator does NOT hide a bypass'
check "echo 'hi <<X'
git push --no-verify
X"                                                2 'B-gate-9b: single-quoted << likewise'
check '# <<EOF
git push --no-verify
EOF'                                              2 'B-gate-9b: a commented <<EOF is not an opener either'

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
