#!/usr/bin/env bash
# Task 2 — assert EVERY adversarial call-site uses the scoped, index-free helper
# (`~/.zuvo/build-review-patch`) instead of staging the caller's work with
# `git add -u`.
#
# The bug this locks down: `git add -u && git diff --staged | adversarial-review`
# silently STAGES the user's tracked edits (changing what their next commit
# captures) and still misses brand-new untracked files. The helper emits the same
# review patch on stdout without ever writing the index.
#
# Pure grep/awk assertions on markdown + shell sources — no fixtures, no runtime
# side effects. `docs/specs/` is deliberately NOT swept (historical spec text).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

STAGE_ALL='git add -u'
HELPER='build-review-patch'
LOOP="$ROOT/shared/includes/adversarial-loop.md"
DOCS="$ROOT/shared/includes/adversarial-loop-docs.md"

# The 12 call-sites that must be migrated (10 SKILL.md + 2 hooks).
SITES="
skills/build/SKILL.md
skills/execute/SKILL.md
skills/debug/SKILL.md
skills/fix-tests/SKILL.md
skills/write-e2e/SKILL.md
skills/receive-review/SKILL.md
skills/content-fix/SKILL.md
skills/content-migration/SKILL.md
skills/seo-fix/SKILL.md
skills/geo-fix/SKILL.md
hooks/post-skill-adversarial-check.sh
hooks/pre-commit-adversarial-gate.sh
"

# The swept surface for the "zero stagings anywhere" assertions.
sweep_files() {
  local f
  for f in "$ROOT"/skills/*/SKILL.md "$ROOT"/shared/includes/*.md "$ROOT"/hooks/*.sh; do
    [ -f "$f" ] || continue
    case "$f" in */skills/refactor/SKILL.md) continue ;; esac
    printf '%s\n' "$f"
  done
}

# ── (1) zero `git add -u` across skills / shared includes / hooks ────────────
offenders=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -qF -- "$STAGE_ALL" "$f"; then
    offenders="$offenders ${f#"$ROOT"/}"
  fi
done <<EOF
$(sweep_files)
EOF

if [ -z "$offenders" ]; then
  pass "no '$STAGE_ALL' in skills/*/SKILL.md, shared/includes/*.md, hooks/*.sh"
else
  bad "'$STAGE_ALL' still present in:$offenders"
fi

# refactor's PROHIBITION line must survive the sweep (it is the one legal mention)
if grep -q 'not .git add -u' "$ROOT/skills/refactor/SKILL.md"; then
  pass "refactor SKILL.md keeps its 'not \`$STAGE_ALL\`' prohibition"
else
  bad "refactor SKILL.md lost its '$STAGE_ALL' prohibition line"
fi

# ── (2) every site uses the helper, guarded, with a --files fallback ─────────
# ── (5) every site is capture-then-branch (rc captured, exit-3 handled) ──────
for rel in $SITES; do
  f="$ROOT/$rel"
  if [ ! -f "$f" ]; then bad "$rel: missing"; continue; fi

  grep -qF -- "$HELPER" "$f" \
    && pass "$rel: invokes $HELPER" \
    || bad "$rel: does not invoke $HELPER"

  grep -qF -- '[ -x' "$f" \
    && pass "$rel: has the '[ -x' helper-present guard" \
    || bad "$rel: missing the '[ -x' helper-present guard"

  grep -qF -- '--files' "$f" \
    && pass "$rel: has the --files fallback for a missing helper" \
    || bad "$rel: missing the --files fallback"

  # `\$?` tolerated: the hooks emit the block through a heredoc/JSON string, where
  # the literal `$` is backslash-escaped so it survives to the agent verbatim.
  grep -qE -- '_prc=\\?\$\?' "$f" \
    && pass "$rel: captures the helper exit code (_prc=\$?)" \
    || bad "$rel: does not capture the helper exit code — bare pipe discards it"

  # (9) the capture must survive `set -e`. `_patch=$(cmd); _prc=$?` aborts the shell
  # at the assignment whenever the helper exits non-zero, so exit 3 (a NORMAL "no
  # changes" outcome) becomes a hard abort and exit 2 dies before BLOCKED can print.
  # An `||` list is a *tested* command, which `set -e` exempts. Behaviour is proved
  # executably at the bottom of this file; here we lock the shape at every site.
  if grep -qE -- '\|\| _prc=\\?\$\?' "$f" && ! grep -qE -- '\); _prc=\\?\$\?' "$f"; then
    pass "$rel: capture is set -e-safe (|| _prc=\$?, not ; _prc=\$?)"
  else
    bad "$rel: capture uses '; _prc=\$?' — aborts under set -e before the branch runs"
  fi

  grep -qF -- 'skipped (no changes)' "$f" \
    && pass "$rel: handles exit 3 (skipped (no changes))" \
    || bad "$rel: no exit-3 branch — a clean tree would report a hard error"

  # (7) rc≠0 (and ≠3) is a BLOCKED review at EVERY site — see the note below.
  # `\"` tolerated inside the test expression: the hooks emit the block through a
  # heredoc / JSON string where the literal quote is backslash-escaped.
  if grep -qE -- '_prc\\?" -ne 0.*BLOCKED' "$f" && grep -qF -- 'do NOT proceed to commit' "$f"; then
    pass "$rel: rc≠0 branch BLOCKS (BLOCKED + 'do NOT proceed to commit')"
  else
    bad "$rel: rc≠0 branch is advisory — a failed helper would let the run finish green"
  fi

  # (10) …and the BLOCKED branch must END NON-ZERO. Printing is not enforcement:
  # with a 0 status a hook, CI step, `set -e` wrapper or `if ! …` caller sails past
  # a review that never ran. `false` in pasteable blocks (does not kill an inlining
  # caller's shell); `exit 1` in the two hooks, which own their exit status.
  if grep -qE -- '_prc\\?" -ne 0.*BLOCKED.*(; false$|; exit 1([; ]|$))' "$f"; then
    pass "$rel: BLOCKED branch ends non-zero (false / exit 1)"
  else
    bad "$rel: BLOCKED branch prints but returns 0 — an automated caller sails past it"
  fi
done

# a bare `helper | adversarial-review` pipe anywhere loses the exit code
piped=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -qE -- "$HELPER\"?[[:space:]]*\|" "$f"; then
    piped="$piped ${f#"$ROOT"/}"
  fi
done <<EOF
$(sweep_files)
EOF
if [ -z "$piped" ]; then
  pass "no bare '$HELPER | ...' pipe (exit code always captured)"
else
  bad "bare '$HELPER | ...' pipe found in:$piped"
fi

# ── (3) the 5 protocol literals survive in BOTH loop includes ───────────────
check_literals() {
  local f="$1" name="$2" lit missing=""
  # newline-separated so the literal with a space survives the loop
  while IFS= read -r lit; do
    [ -n "$lit" ] || continue
    grep -qF -- "$lit" "$f" || missing="$missing [$lit]"
  done <<'LITS'
status: "partial"
single_provider_only
exclude-last
exit code 3
exit code 124
LITS
  if [ -z "$missing" ]; then
    pass "$name: all 5 protocol literals present"
  else
    bad "$name: missing protocol literals:$missing"
  fi
}
[ -f "$LOOP" ] && check_literals "$LOOP" "adversarial-loop.md" || bad "adversarial-loop.md missing"
[ -f "$DOCS" ] && check_literals "$DOCS" "adversarial-loop-docs.md" || bad "adversarial-loop-docs.md missing"

# ── (4) adversarial-loop.md Step 5: no staging, re-run the same invocation ───
if [ -f "$LOOP" ]; then
  step5="$(awk '/^### Step 5:/{f=1} f&&/^### Step 6:/{f=0} f' "$LOOP")"
  if [ -z "$step5" ]; then
    bad "adversarial-loop.md: Step 5 section not found"
  else
    if printf '%s\n' "$step5" | grep -qE 'git add|Stage fixes|--staged|git stash'; then
      bad "adversarial-loop.md Step 5 still contains a staging instruction"
    else
      pass "adversarial-loop.md Step 5 contains no staging instruction"
    fi
    if printf '%s\n' "$step5" | grep -qF 'same helper invocation'; then
      pass "adversarial-loop.md Step 5 re-runs the 'same helper invocation'"
    else
      bad "adversarial-loop.md Step 5 does not say 'same helper invocation'"
    fi
    # Step 5 must RE-INVOKE the helper, not reuse $_patch from Step 2: agent Bash
    # calls run in fresh shells, so the variable is empty there and the reviewer
    # would get empty stdin (exit 2) — a silently failed validation run.
    if printf '%s\n' "$step5" | grep -qF 'build-review-patch' \
       && printf '%s\n' "$step5" | grep -qF 'FRESH SHELL'; then
      pass "adversarial-loop.md Step 5 re-invokes the helper (warns \$_patch is dead in a new shell)"
    else
      bad "adversarial-loop.md Step 5 reuses \$_patch instead of re-invoking the helper"
    fi
    # The VERIFIED CONTEXT block must be piped into the reviewer, not just described.
    if printf '%s\n' "$step5" | grep -qE '_ctx.*\| *adversarial-review|printf .*_ctx'; then
      pass "adversarial-loop.md Step 5 pipes the VERIFIED CONTEXT into the reviewer"
    else
      bad "adversarial-loop.md Step 5 describes VERIFIED CONTEXT without feeding it to stdin"
    fi
  fi
fi

# ── (8) the joined-path footgun is documented ───────────────────────────────
# Observed 2026-07-31: `build-review-patch --base <ref> $FILES` under zsh (which does
# NOT word-split an unquoted expansion) passes the whole list as ONE path — the helper
# matches nothing and returns exit 3 "no changes", and a caller trusting exit 3 skips
# the review. Same silent-skip outcome as the bug this task fixes, reached through
# caller error. Verified: joined arg -> rc=3 + 0 bytes; separate args -> rc=0 + patch.
# The note is the only defence, so it is asserted where paths are actually passed.
if grep -qF -- 'never a single space-joined string' "$LOOP" \
   && grep -qF -- 'zsh' "$LOOP" \
   && grep -qF -- 'could not open directory' "$LOOP"; then
  pass "adversarial-loop.md documents the joined-path footgun + failure signature"
else
  bad "adversarial-loop.md lost the separate-quoted-args note / failure signature"
fi
# (the per-site half of this lives in (6b) below, which covers all 10 skill sites)

# ── (6) EVERY skill site passes a non-empty PATH list to the helper ──────────
# Originally only build/execute. Widened after review: the no-PATH form reviews the
# whole dirty tree INCLUDING untracked files and ships all of it to the external
# providers — a real behaviour change from the old tracked-only staged diff. Every
# one of the 10 skills knows the files it wrote, so every one now scopes explicitly.
for rel in $SITES; do
  case "$rel" in hooks/*) continue ;; esac   # hooks are a generic reminder, no file list
  f="$ROOT/$rel"
  [ -f "$f" ] || { bad "$rel: missing"; continue; }
  # helper invocation followed by at least one quoted path argument
  if grep -qE -- "$HELPER\"[[:space:]]+\"[^\"]+\"" "$f"; then
    pass "$rel: helper invoked WITH a scoped path list"
  else
    bad "$rel: helper invoked bare (no PATH args) — sends the whole dirty tree to providers"
  fi
done

# ── (7b) the blocking wording is IDENTICAL at all 12 sites ──────────────────
# The plan's Task-2 contract made only the two hooks block, on the reasoning that
# a hook has no later gate while a skill's own review-required gate would catch an
# advisory ERROR line. Review found that reasoning half-true: content-fix,
# content-migration and geo-fix have NO "do NOT proceed" directive in their prose,
# are absent from post-skill-adversarial-check.sh's monitored-skill list, and get
# no pre-commit-gate coverage — so at those three an advisory line let a failed
# helper finish the run green, re-opening the exact silent-skip class this task
# exists to close. Deliberate strengthening of the original contract: rc≠0 BLOCKS
# everywhere, asserted per-site above, and the wording is asserted identical here
# so the 12 sites cannot drift into three phrasings.
BLOCK_LINE='Adversarial review did NOT run; do NOT proceed to commit and do NOT report this skill complete'
drift=""
for rel in $SITES; do
  f="$ROOT/$rel"
  [ -f "$f" ] || continue
  grep -qF -- "$BLOCK_LINE" "$f" || drift="$drift $rel"
done
if [ -z "$drift" ]; then
  pass "all 12 sites share the identical blocking wording"
else
  bad "blocking wording drifted / missing at:$drift"
fi

# ── (9b) EXECUTABLE proof that the documented capture shape survives set -e ──
# Extract the real capture line from the canonical template, swap the helper for a
# stub returning 0/2/3, and run it under `set -e`. All three must reach the branch.
cap="$(grep -m1 -E '^\s*_prc=0; _patch=\$\("\$HOME/\.zuvo/build-review-patch"' "$LOOP" | sed 's/^[[:space:]]*//')"
if [ -z "$cap" ]; then
  bad "adversarial-loop.md: could not extract the canonical capture line"
else
  seok=1
  for rc in 0 2 3; do
    stub="$(printf '%s' "$cap" | sed 's|\$("\$HOME/.zuvo/build-review-patch"[^)]*)|$(exit '"$rc"')|')"
    got="$(bash -c "set -e; $stub; echo REACHED:\$_prc" 2>/dev/null)" || got="ABORTED"
    case "$got" in
      "REACHED:$rc") ;;
      *) seok=0; bad "set -e proof: helper rc=$rc did not reach the branch (got: ${got:-ABORTED})" ;;
    esac
  done
  [ "$seok" -eq 1 ] && pass "set -e proof: canonical capture reaches its branch for rc 0, 2 and 3"
fi

# ── (9c) EXECUTABLE proof that the WHOLE block's exit status is non-zero on rc=2 ──
# The status, not the message, is what an automated caller reads. Extract the real
# Step-2 block, stub the helper and the reviewer, and assert the block's own status.
blk="$(awk '/^if \[ -x "\$HOME\/\.zuvo\/build-review-patch" \]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$LOOP")"
if [ -z "$blk" ]; then
  bad "adversarial-loop.md: could not extract the Step 2 block"
else
  # The block invokes `~/.zuvo/adversarial-review` by PATH, so a shell function named
  # `adversarial-review` never intercepts it — until 2026-08-20 this case executed the REAL
  # reviewer on every run of this test, three times, hitting live provider CLIs (231s, the
  # slowest child in the suite) to assert a branch's exit status. Point HOME at a throwaway
  # tree holding a stub reviewer instead: same contract under test, no external calls.
  # `_ADV_MODE` is set in adversarial-loop.md ABOVE the extracted `if`, so the block alone
  # does not carry it; supply it here rather than widening the extraction, which would drag
  # in the mktemp artifact setup this case does not exercise.
  _rpc_home="$(mktemp -d)"
  mkdir -p "$_rpc_home/.zuvo"
  printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1 || true\nexit 0\n' > "$_rpc_home/.zuvo/adversarial-review"
  chmod +x "$_rpc_home/.zuvo/adversarial-review"
  prelude="HOME='$_rpc_home'; _ADV_MODE=code; _ADV_ART=\"\$(mktemp)\"; adversarial-review() { cat >/dev/null; }"
  for rc in 0 2 3; do
    stub="$(printf '%s\n' "$blk" \
      | sed 's|\[ -x "\$HOME/\.zuvo/build-review-patch" \]|true|' \
      | sed 's|\$("\$HOME/\.zuvo/build-review-patch"[^)]*)|$(echo patch; exit '"$rc"')|')"
    bash -c "$prelude
$stub" >/dev/null 2>&1
    st=$?
    case "$rc" in
      2) [ "$st" -ne 0 ] \
           && pass "block exit status on helper rc=2 is non-zero ($st) — caller cannot sail past" \
           || bad  "block exit status on helper rc=2 is 0 — BLOCKED printed but nothing failed" ;;
      *) [ "$st" -eq 0 ] \
           && pass "block exit status on helper rc=$rc is 0 (genuine success path)" \
           || bad  "block exit status on helper rc=$rc is $st — success path must return 0" ;;
    esac
  done
  # and the same under `set -e`, the shape a wrapper script actually runs
  stub2="$(printf '%s\n' "$blk" \
    | sed 's|\[ -x "\$HOME/\.zuvo/build-review-patch" \]|true|' \
    | sed 's|\$("\$HOME/\.zuvo/build-review-patch"[^)]*)|$(echo patch; exit 2)|')"
  bash -c "set -e
$prelude
$stub2" >/dev/null 2>&1
  [ "$?" -ne 0 ] \
    && pass "under set -e the block still exits non-zero on helper rc=2" \
    || bad  "under set -e the block returns 0 on helper rc=2"
  rm -rf "$_rpc_home"
fi

# ── (11) scope derivation must not parse patch text (breaks on diff.noprefix) ──
EXE="$ROOT/skills/execute/SKILL.md"
if grep -qF -- '+++ b/' "$EXE"; then
  bad "execute: scope list still parsed from patch text ('+++ b/') — empty under diff.noprefix=true"
else
  pass "execute: scope list is git-derived, not parsed from patch text"
fi
# executable: the documented git-derived command must work with diff.noprefix=true
np="$(mktemp -d)"
(
  cd "$np" || exit 1
  git init -q . 2>/dev/null
  git config diff.noprefix true
  git config user.email t@t; git config user.name t
  printf 'a\n' > tracked.txt; git add tracked.txt >/dev/null 2>&1
  git commit -qm base >/dev/null 2>&1
  printf 'a\nb\n' > tracked.txt          # dirty tracked
  printf 'new\n' > untracked.txt         # untracked
  { git diff --name-only; git diff --cached --name-only; git ls-files --others --exclude-standard; } \
    | sort -u > scope.txt
  grep -q '^tracked.txt$' scope.txt && grep -q '^untracked.txt$' scope.txt
) && pass "git-derived scope list is correct under diff.noprefix=true" \
  || bad "git-derived scope list wrong/empty under diff.noprefix=true"
# and prove the OLD approach really was broken there (so this test has teeth)
np2="$(mktemp -d)"
(
  cd "$np2" || exit 1
  git init -q . 2>/dev/null; git config diff.noprefix true
  git config user.email t@t; git config user.name t
  printf 'a\n' > f.txt; git add f.txt >/dev/null 2>&1; git commit -qm base >/dev/null 2>&1
  printf 'a\nb\n' > f.txt
  n=$(git diff | sed -n 's|^+++ b/||p' | wc -l | tr -d ' ')
  [ "$n" -eq 0 ]
) && pass "confirmed: the old '+++ b/' parse yields an EMPTY scope under diff.noprefix" \
  || bad "the old '+++ b/' parse was not actually broken — re-check this assertion"
rm -rf "$np" "$np2"

# ── (6b) the joined-path trap and provider exposure are stated at EVERY site ──
scope_bad=""
for rel in $SITES; do
  f="$ROOT/$rel"
  [ -f "$f" ] || continue
  case "$rel" in hooks/*) continue ;; esac   # hooks carry a one-line form, not the comment block
  grep -qF -- 'Quote each SEPARATELY' "$f" || scope_bad="$scope_bad $rel"
done
if [ -z "$scope_bad" ]; then
  pass "all 10 skill sites warn about joined path args + provider exposure"
else
  bad "missing the scoping/exposure warning at:$scope_bad"
fi

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "SOME FAILED"
  exit 1
fi
