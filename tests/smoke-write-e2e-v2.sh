#!/usr/bin/env bash
#
# smoke-write-e2e-v2.sh — whole-feature smoke for the write-e2e V2 plan
# (docs/specs/2026-07-30-write-e2e-v2-plan.md → "Whole-feature Smoke Proofs").
#
#   SMOKE1  scoped review patch end-to-end (scripts/zuvo-home/build-review-patch)
#   SMOKE2  full test suite               (ZUVO_TEST_SCOPE=full tests/run-all.sh)
#   SMOKE3  validators + gate generator
#   SMOKE4  install lands helpers, references and a token-clean Codex dist
#
# Usage:
#   tests/smoke-write-e2e-v2.sh          run all four sections → `ALL SMOKE PASS`
#   tests/smoke-write-e2e-v2.sh 1 3      run a subset → `SMOKE SUBSET PASS (1 3)`
#
# The subset form exists so a single section can be pointed at a deliberately
# broken tree to prove the assertions can actually fail. A subset run NEVER
# prints `ALL SMOKE PASS` — the aggregate line names exactly what ran.
#
# Exit: 0 = every assertion in every selected section passed; 1 = anything else;
#       2 = usage error.
#
# WHY `smoke-` AND NOT `test-`: tests/run-all.sh enumerates `tests/hooks/test-*.sh`
# and `tests/skill-suite/test-*.sh`, and SMOKE2 below RUNS run-all.sh. A `test-`
# name here would make the suite recurse into itself. Do not rename this file.
#
# SIDE EFFECTS: SMOKE4 runs ./scripts/install.sh, which writes to the real
# ~/.claude, ~/.codex, ~/.cursor and ~/.zuvo. That is the documented dev workflow
# (CLAUDE.md) and the only way to prove the install actually lands the helpers and
# the references. Everything after the install only READS those paths. SMOKE1
# works exclusively inside a mktemp repo and never touches this checkout.
#
# NO `set -o pipefail`: SMOKE2/SMOKE3 produce multi-thousand-line output, and an
# early-exiting reader in a pipeline reports 141 (SIGPIPE) instead of the real
# status — this repo already ate that bug (commit 9a74df5). Large output is
# written to a file and matched with `grep FILE` (no pipeline); small strings are
# matched with `case` on a variable.
#
# bash 3.2-safe (macOS default): no associative arrays, no mapfile, no ${var^^}.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGDIR="$(mktemp -d)"
SMOKE_TMP="$(mktemp -d)"
trap 'rm -rf "$LOGDIR" "$SMOKE_TMP"' EXIT
trap 'rm -rf "$LOGDIR" "$SMOKE_TMP"; trap - EXIT; exit 130' INT TERM HUP

FAILED=0
NCHECK=0

ok()  { NCHECK=$((NCHECK + 1)); printf '  PASS  %s\n' "$1"; }
no()  { NCHECK=$((NCHECK + 1)); FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; }
note(){ printf '        %s\n' "$1"; }
hdr() { printf '\n========================================================\n%s\n========================================================\n' "$1"; }

# has NEEDLE HAYSTACK — literal substring test on an in-memory string.
has() {
  case "$2" in
    *"$1"*) return 0 ;;
    *)      return 1 ;;
  esac
}

# ── section selection ────────────────────────────────────────────────────────
WANT1=0; WANT2=0; WANT3=0; WANT4=0
SUBSET=0
SELECTED=""
if [ "$#" -eq 0 ]; then
  WANT1=1; WANT2=1; WANT3=1; WANT4=1
  SELECTED="1 2 3 4"
else
  SUBSET=1
  for a in "$@"; do
    case "$a" in
      1) WANT1=1 ;;
      2) WANT2=1 ;;
      3) WANT3=1 ;;
      4) WANT4=1 ;;
      *) printf 'ERROR: unknown section: %s\n' "$a" >&2
         printf 'Usage: %s [1] [2] [3] [4]\n' "$0" >&2
         exit 2 ;;
    esac
    SELECTED="$SELECTED${SELECTED:+ }$a"
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# SMOKE1 — scoped-patch end-to-end
#
# The invariant under test is Task 1's whole reason to exist: the review patch
# must SEE brand-new untracked files (the old `git add -u` did not) while leaving
# the caller's index EXACTLY as it found it (the old `git add -u` did not).
# ─────────────────────────────────────────────────────────────────────────────
smoke1() {
  hdr "SMOKE1 — scoped review patch, end-to-end (build-review-patch)"
  HELPER="$ROOT/scripts/zuvo-home/build-review-patch"

  if [ -x "$HELPER" ]; then
    ok "helper present and executable: scripts/zuvo-home/build-review-patch"
  else
    no "helper present and executable: $HELPER"
    note "cannot continue SMOKE1 without the helper"
    return
  fi

  REPO="$SMOKE_TMP/smoke1-repo"
  mkdir -p "$REPO" || { no "could not create the fixture repo"; return; }

  # Fixture: committed-then-modified + brand-new untracked + user-staged +
  # unrelated user-dirty + one pristine tracked file (for the exit-3 scope).
  (
    cd "$REPO" || exit 1
    git init -q -b main 2>/dev/null || { git init -q || exit 1; git symbolic-ref HEAD refs/heads/main; }
    git config user.email smoke@example.invalid || exit 1
    git config user.name smoke || exit 1
    git config commit.gpgsign false || exit 1
    mkdir -p src e2e || exit 1
    printf 'SMOKE1_TRACKED_V1\n'   > src/tracked.ts
    printf 'SMOKE1_STAGED_V1\n'    > src/staged.ts
    printf 'SMOKE1_UNRELATED_V1\n' > src/unrelated.ts
    printf 'SMOKE1_PRISTINE\n'     > src/pristine.ts
    git add src/tracked.ts src/staged.ts src/unrelated.ts src/pristine.ts || exit 1
    git commit -q -m init || exit 1
    # tracked, modified, NOT staged
    printf 'SMOKE1_TRACKED_V2\n'   > src/tracked.ts
    # staged BY THE USER — this is what must survive the run untouched
    printf 'SMOKE1_STAGED_V2\n'    > src/staged.ts
    git add src/staged.ts || exit 1
    # unrelated user-dirty file — must be absent from a scoped run
    printf 'SMOKE1_UNRELATED_V2\n' > src/unrelated.ts
    # brand-new UNTRACKED spec — the file `git add -u` never saw
    printf 'SMOKE1_UNTRACKED_BODY\n' > e2e/brand-new.spec.ts
  ) || { no "fixture repo built"; return; }
  ok "fixture repo built (modified + untracked + staged + unrelated + pristine)"

  INDEX_BEFORE="$(git -C "$REPO" diff --cached)"

  # ── (1) no-PATH run ────────────────────────────────────────────────────────
  OUT1="$( cd "$REPO" && bash "$HELPER" 2>"$LOGDIR/s1-nopath.err" )"; RC1=$?
  INDEX_AFTER1="$(git -C "$REPO" diff --cached)"

  [ "$RC1" -eq 0 ] && ok "no-PATH run exits 0 (a patch was emitted)" \
                   || no "no-PATH run exits 0 — got $RC1"

  has 'e2e/brand-new.spec.ts' "$OUT1" \
    && ok "patch names the brand-new UNTRACKED file" \
    || no "patch names the brand-new UNTRACKED file"

  # The point of Task 1: the untracked file's CONTENT is in the patch body, not
  # just its name. `git add -u` would have shown neither.
  has '+SMOKE1_UNTRACKED_BODY' "$OUT1" \
    && ok "patch BODY contains the untracked file's content (+SMOKE1_UNTRACKED_BODY)" \
    || no "patch BODY contains the untracked file's content (+SMOKE1_UNTRACKED_BODY)"

  has '+SMOKE1_TRACKED_V2' "$OUT1" \
    && ok "patch contains the modified tracked hunk (+SMOKE1_TRACKED_V2)" \
    || no "patch contains the modified tracked hunk (+SMOKE1_TRACKED_V2)"

  has '+SMOKE1_STAGED_V2' "$OUT1" \
    && ok "patch spans the user-staged change too (one HEAD-vs-worktree snapshot)" \
    || no "patch spans the user-staged change too (one HEAD-vs-worktree snapshot)"

  # THE index invariant. Byte-for-byte, not a summary: an implementation that ran
  # `git add -u` would pull tracked.ts and unrelated.ts into the index and this
  # comparison would differ.
  if [ "$INDEX_BEFORE" = "$INDEX_AFTER1" ]; then
    ok "user index is UNTOUCHED by the no-PATH run (git diff --cached byte-identical)"
  else
    no "user index is UNTOUCHED by the no-PATH run (git diff --cached CHANGED)"
    note "the helper mutated the caller's staging area — that is the bug Task 1 exists to prevent"
  fi

  # ── (2) scoped run excludes the unrelated dirty file ───────────────────────
  OUT2="$( cd "$REPO" && bash "$HELPER" src/tracked.ts e2e/brand-new.spec.ts 2>"$LOGDIR/s1-scoped.err" )"; RC2=$?
  [ "$RC2" -eq 0 ] && ok "scoped run exits 0" || no "scoped run exits 0 — got $RC2"
  has '+SMOKE1_TRACKED_V2' "$OUT2" \
    && ok "scoped run includes the in-scope tracked change" \
    || no "scoped run includes the in-scope tracked change"
  has '+SMOKE1_UNTRACKED_BODY' "$OUT2" \
    && ok "scoped run includes the in-scope untracked spec" \
    || no "scoped run includes the in-scope untracked spec"
  if has 'unrelated' "$OUT2"; then
    no "scoped run EXCLUDES the unrelated dirty file"
    note "src/unrelated.ts leaked into a patch scoped to two other paths"
  else
    ok "scoped run EXCLUDES the unrelated dirty file (src/unrelated.ts)"
  fi

  # ── (3) exit 3 — path resolved, nothing changed in that scope ──────────────
  OUT3="$( cd "$REPO" && bash "$HELPER" src/pristine.ts 2>"$LOGDIR/s1-clean.err" )"; RC3=$?
  [ "$RC3" -eq 3 ] && ok "resolved-but-unchanged scope exits 3 (clean, not an error)" \
                   || no "resolved-but-unchanged scope exits 3 — got $RC3"
  [ -z "$OUT3" ] && ok "exit-3 run emits an EMPTY patch on stdout" \
                 || no "exit-3 run emits an EMPTY patch on stdout"

  # ── (4) exit 2 — a path git knows nothing about is a BAD REQUEST ───────────
  OUT4="$( cd "$REPO" && bash "$HELPER" src/no-such-file.ts 2>"$LOGDIR/s1-bad.err" )"; RC4=$?
  if [ "$RC4" -eq 2 ]; then
    ok "unknown path exits 2 (bad request, never silently 'clean')"
  else
    no "unknown path exits 2 — got $RC4"
    note "exit 3 here would turn a caller typo into a silently skipped review"
  fi

  # ── (5) the index survived ALL FOUR invocations ────────────────────────────
  INDEX_END="$(git -C "$REPO" diff --cached)"
  if [ "$INDEX_BEFORE" = "$INDEX_END" ]; then
    ok "user index still byte-identical after all four helper invocations"
  else
    no "user index still byte-identical after all four helper invocations"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SMOKE2 — full test suite
# ─────────────────────────────────────────────────────────────────────────────
smoke2() {
  hdr "SMOKE2 — full test suite (ZUVO_TEST_SCOPE=full bash tests/run-all.sh)"
  LOG="$LOGDIR/run-all.log"
  note "this takes several minutes (full scope pulls in the adversarial suite)"
  ( cd "$ROOT" && ZUVO_TEST_SCOPE=full bash tests/run-all.sh ) > "$LOG" 2>&1
  RC=$?

  # Exit 3 = run-all refused a NESTED invocation. This mattered more here than in the
  # sibling smoke: this one asks for ZUVO_TEST_SCOPE=full from INSIDE a fast run, so a
  # nested execution was not merely a second pass — it was a strictly LARGER one, pulling
  # in the adversarial suite the outer run had deliberately scoped out.
  if [ "$RC" -eq 3 ]; then
    note "SKIPPED: nested run-all (the outer suite already ran these children; run this file directly to exercise full scope)"
    return 0
  fi

  [ "$RC" -eq 0 ] && ok "run-all.sh (full scope) exits 0" \
                  || no "run-all.sh (full scope) exits 0 — got $RC"

  # grep against the FILE, never a pipeline: this log is large and `grep -q` in a
  # pipe would SIGPIPE the writer (see the pipefail note in the header).
  if grep -q 'FAIL=0' "$LOG"; then
    ok "suite summary reports FAIL=0"
  else
    no "suite summary reports FAIL=0"
  fi
  if grep -q 'ALL PASSED' "$LOG"; then
    ok "suite prints ALL PASSED"
  else
    no "suite prints ALL PASSED"
  fi

  SUMMARY="$(grep 'RESULT: PASS=' "$LOG" 2>/dev/null)"
  [ -n "$SUMMARY" ] && note "$SUMMARY"
  [ "$RC" -eq 0 ] || note "full log: $LOG (tail below)"
  [ "$RC" -eq 0 ] || tail -n 25 "$LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# SMOKE3 — validators + gate generator
# ─────────────────────────────────────────────────────────────────────────────
smoke3() {
  hdr "SMOKE3 — validators + gate-copy generator"

  # Skill count is DERIVED from skills/, not hardcoded: CLAUDE.md's own rule is
  # that the count must not gain another place to update. A hardcoded 56 here
  # would be an eighth.
  NSKILLS=0
  for f in "$ROOT"/skills/*/SKILL.md; do
    [ -f "$f" ] && NSKILLS=$((NSKILLS + 1))
  done
  note "skills/ contains $NSKILLS SKILL.md files (expected count-consistency value)"

  # ── validate-skills.sh ─────────────────────────────────────────────────────
  VLOG="$LOGDIR/validate-skills.log"
  ( cd "$ROOT" && bash scripts/validate-skills.sh ) > "$VLOG" 2>&1
  VRC=$?
  [ "$VRC" -eq 0 ] && ok "scripts/validate-skills.sh exits 0" \
                   || no "scripts/validate-skills.sh exits 0 — got $VRC"

  if grep -qE '^ERRORS: 0( |$)' "$VLOG"; then
    ok "validate-skills reports ERRORS: 0"
  else
    no "validate-skills reports ERRORS: 0"
    note "$(grep -E '^ERRORS:' "$VLOG" 2>/dev/null | head -n 1)"
  fi

  if grep -Fq "count-consistency: OK ($NSKILLS)" "$VLOG"; then
    ok "validate-skills reports count-consistency: OK ($NSKILLS)"
  else
    no "validate-skills reports count-consistency: OK ($NSKILLS)"
    note "$(grep -F 'count-consistency' "$VLOG" 2>/dev/null | head -n 1)"
  fi

  if grep -Fq 'gate-registry: OK' "$VLOG"; then
    ok "validate-skills reports gate-registry regions fresh"
  else
    no "validate-skills reports gate-registry regions fresh"
    note "$(grep -F 'gate-registry' "$VLOG" 2>/dev/null | head -n 1)"
  fi

  # ── gen-gate-copies.py (NO ARGS **is** check mode — there is no --check) ────
  GLOG="$LOGDIR/gen-gate-copies.log"
  ( cd "$ROOT" && python3 scripts/gen-gate-copies.py ) > "$GLOG" 2>&1
  GRC=$?
  [ "$GRC" -eq 0 ] && ok "python3 scripts/gen-gate-copies.py (check mode) exits 0" \
                   || no "python3 scripts/gen-gate-copies.py (check mode) exits 0 — got $GRC"
  if grep -Fq '0 stale' "$GLOG"; then
    ok "gen-gate-copies reports 0 stale regions"
  else
    no "gen-gate-copies reports 0 stale regions"
    note "$(head -n 2 "$GLOG" 2>/dev/null)"
  fi

  # ── validate-skill-pages.sh ────────────────────────────────────────────────
  PLOG="$LOGDIR/validate-skill-pages.log"
  ( cd "$ROOT" && bash scripts/validate-skill-pages.sh ) > "$PLOG" 2>&1
  PRC=$?
  [ "$PRC" -eq 0 ] && ok "scripts/validate-skill-pages.sh exits 0" \
                   || no "scripts/validate-skill-pages.sh exits 0 — got $PRC"
  # Exit 0 alone is weak evidence here: this validator was silently incapable of
  # failing until 92a29f9. Require it to say it actually validated files.
  if grep -Fq 'PASS: All' "$PLOG"; then
    ok "validate-skill-pages printed a real PASS summary (not a silent no-op)"
  else
    no "validate-skill-pages printed a real PASS summary (not a silent no-op)"
    note "$(tail -n 2 "$PLOG" 2>/dev/null)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# SMOKE4 — install lands helpers, references, and a token-clean Codex dist
# ─────────────────────────────────────────────────────────────────────────────
smoke4() {
  hdr "SMOKE4 — ./scripts/install.sh lands helpers, references and a clean Codex dist"
  note "this writes to the real ~/.claude, ~/.codex, ~/.cursor and ~/.zuvo (documented dev workflow)"

  ILOG="$LOGDIR/install.log"
  ( cd "$ROOT" && ./scripts/install.sh ) > "$ILOG" 2>&1
  IRC=$?
  [ "$IRC" -eq 0 ] && ok "./scripts/install.sh exits 0" \
                   || { no "./scripts/install.sh exits 0 — got $IRC"; note "log: $ILOG"; tail -n 25 "$ILOG"; }

  # ── zuvo-home helpers ──────────────────────────────────────────────────────
  for h in build-review-patch e2e-preflight; do
    if [ -f "$HOME/.zuvo/$h" ] && [ -x "$HOME/.zuvo/$h" ]; then
      ok "~/.zuvo/$h exists and is executable"
    else
      no "~/.zuvo/$h exists and is executable"
    fi
  done

  # ── write-e2e references under the Claude Code cache installPath ───────────
  # installPath, not a hardcoded version dir: CLAUDE.md documents that Claude
  # Code loads from the installPath field and that several cache dirs coexist.
  INSTALLPATH="$(python3 -c 'import json,os,sys
p = os.path.expanduser("~/.claude/plugins/installed_plugins.json")
try:
    d = json.load(open(p))
except Exception:
    sys.exit(1)
for name, entry in d.get("plugins", {}).items():
    if "zuvo" not in name.lower():
        continue
    for rec in (entry if isinstance(entry, list) else [entry]):
        ip = rec.get("installPath")
        if ip:
            print(ip)
            sys.exit(0)
sys.exit(1)' 2>/dev/null)"

  if [ -n "$INSTALLPATH" ] && [ -d "$INSTALLPATH" ]; then
    ok "Claude Code installPath resolved from installed_plugins.json"
    note "installPath: $INSTALLPATH"
    check_reference_dir "$INSTALLPATH/skills/write-e2e/references" "Claude cache installPath"
  else
    no "Claude Code installPath resolved from installed_plugins.json"
    note "resolved value: '${INSTALLPATH:-<none>}'"
  fi

  # ── write-e2e references under ~/.codex ────────────────────────────────────
  check_reference_dir "$HOME/.codex/skills/write-e2e/references" "Codex install"

  # ── Codex dist is free of Claude-Code-only tool tokens ─────────────────────
  # The list is the one scripts/build-codex-skills.sh actually enforces (its
  # validation grep at "Check for Claude Code-specific tool references"). The
  # second assertion pins that: if the build script's list changes, this smoke
  # goes red instead of silently checking a stale set.
  FORBIDDEN_ERE='TaskCreate|TaskUpdate|TaskList|EnterPlanMode|ExitPlanMode|AskUserQuestion|run_in_background|TeamCreate|SendMessage'
  FORBIDDEN_BRE="$(printf '%s' "$FORBIDDEN_ERE" | sed 's/|/\\|/g')"
  if grep -Fq "$FORBIDDEN_BRE" "$ROOT/scripts/build-codex-skills.sh"; then
    ok "forbidden-token list matches the one build-codex-skills.sh enforces"
  else
    no "forbidden-token list matches the one build-codex-skills.sh enforces"
    note "build-codex-skills.sh no longer contains this literal alternation — update this smoke"
  fi

  CODEX_SKILL="$HOME/.codex/skills/write-e2e/SKILL.md"
  if [ -f "$CODEX_SKILL" ]; then
    ok "Codex dist SKILL.md installed: ~/.codex/skills/write-e2e/SKILL.md"
    HITS="$(grep -nE "$FORBIDDEN_ERE" "$CODEX_SKILL" 2>/dev/null)"
    if [ -z "$HITS" ]; then
      ok "Codex dist SKILL.md contains no Claude-Code-only tool tokens"
    else
      no "Codex dist SKILL.md contains no Claude-Code-only tool tokens"
      printf '%s\n' "$HITS" | head -n 5
    fi
    # references/ are copied verbatim into the dist, so they are in scope for the
    # same gate (that is exactly what Task 4 extended).
    REFHITS=""
    for r in "$HOME/.codex/skills/write-e2e/references"/*.md; do
      [ -f "$r" ] || continue
      H="$(grep -nE "$FORBIDDEN_ERE" "$r" 2>/dev/null)"
      [ -n "$H" ] && REFHITS="$REFHITS$r: $H
"
    done
    if [ -z "$REFHITS" ]; then
      ok "Codex dist write-e2e references/ contain no Claude-Code-only tool tokens"
    else
      no "Codex dist write-e2e references/ contain no Claude-Code-only tool tokens"
      printf '%s' "$REFHITS" | head -n 5
    fi
  else
    no "Codex dist SKILL.md installed: ~/.codex/skills/write-e2e/SKILL.md"
  fi
}

# check_reference_dir DIR LABEL — the dir exists and mirrors every reference file
# that skills/write-e2e/references/ holds in this checkout (derived, not a
# hardcoded file list, so adding a reference cannot silently go uninstalled).
check_reference_dir() {
  _dir="$1"; _label="$2"
  if [ ! -d "$_dir" ]; then
    no "write-e2e references/ present under $_label"
    note "missing directory: $_dir"
    return
  fi
  _missing=""
  _n=0
  for _src in "$ROOT"/skills/write-e2e/references/*.md; do
    [ -f "$_src" ] || continue
    _n=$((_n + 1))
    _base="$(basename "$_src")"
    [ -f "$_dir/$_base" ] || _missing="$_missing $_base"
  done
  if [ "$_n" -eq 0 ]; then
    no "write-e2e references/ present under $_label"
    note "this checkout has no skills/write-e2e/references/*.md to compare against"
  elif [ -z "$_missing" ]; then
    ok "write-e2e references/ present under $_label (all $_n files)"
  else
    no "write-e2e references/ present under $_label"
    note "missing:$_missing"
  fi
}

# ── run ──────────────────────────────────────────────────────────────────────
printf 'smoke-write-e2e-v2 — sections: %s\n' "$SELECTED"
printf 'repo root: %s\n' "$ROOT"

[ "$WANT1" -eq 1 ] && smoke1
[ "$WANT2" -eq 1 ] && smoke2
[ "$WANT3" -eq 1 ] && smoke3
[ "$WANT4" -eq 1 ] && smoke4

printf '\n========================================================\n'
printf 'assertions: %s   failed: %s\n' "$NCHECK" "$FAILED"
if [ "$FAILED" -ne 0 ]; then
  if [ "$SUBSET" -eq 1 ]; then
    printf 'SMOKE SUBSET FAIL (%s)\n' "$SELECTED"
  else
    printf 'SMOKE FAIL\n'
  fi
  exit 1
fi
if [ "$SUBSET" -eq 1 ]; then
  printf 'SMOKE SUBSET PASS (%s)\n' "$SELECTED"
else
  printf 'ALL SMOKE PASS\n'
fi
exit 0
