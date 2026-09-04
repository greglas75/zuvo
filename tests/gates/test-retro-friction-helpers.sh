#!/usr/bin/env bash
# Behaviour tests for the three helpers added to close the top recurring frictions in
# ~/.zuvo/retros.log (measured 2026-09-05 over 3302 entries):
#
#   scripts/codesift-worktree-scope.sh     ~10 invented names for one worktree-scope rule
#   scripts/stryker-scoped-config.sh       "scoped Stryker config" — most-requested missing template
#   scripts/mutation-survivor-reprobe.sh   "physical-ablation harness" — largest single burn, 140 turns
#
# These test the properties that make each helper WORTH having. A helper whose scoping is wrong
# is worse than no helper: every failure mode below looks like success at the call site — an
# unscoped Stryker run reports a 100% score over an empty mutate set, a worktree resolved to its
# parent answers confidently about files nobody is editing, and a re-probe that leaves the mutant
# in place turns a measurement into a defect.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WT_SCOPE="$ROOT/scripts/codesift-worktree-scope.sh"
STRYKER="$ROOT/scripts/stryker-scoped-config.sh"
REPROBE="$ROOT/scripts/mutation-survivor-reprobe.sh"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
cleanup() {
  # Remove the throwaway worktree through git so the parent repo's admin dir is not left
  # pointing at a deleted path.
  if [ -n "${WT_DIR:-}" ] && [ -d "${WT_DIR:-}" ]; then
    git -C "$ROOT" worktree remove --force "$WT_DIR" >/dev/null 2>&1
    git -C "$ROOT" worktree prune >/dev/null 2>&1
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

for f in "$WT_SCOPE" "$STRYKER" "$REPROBE"; do
  [ -f "$f" ] || { bad "missing helper: ${f#"$ROOT"/}"; echo "SOME FAILED"; exit 1; }
  bash -n "$f" 2>/dev/null || bad "syntax error: ${f#"$ROOT"/}"
done
pass "all three helpers present and parse"

kv() { sed -n "s/^$2=//p" <<<"$1" | head -1; }

# ── 1. codesift-worktree-scope.sh ────────────────────────────────────────────
out="$(bash "$WT_SCOPE" "$ROOT" 2>&1)"
[ "$(kv "$out" action)" = "scope_only" ] \
  && pass "worktree-scope: main checkout → scope_only" \
  || bad "worktree-scope: main checkout gave action=$(kv "$out" action), want scope_only"

out="$(bash "$WT_SCOPE" "$TMP" 2>&1)"
[ "$(kv "$out" action)" = "not_a_repo" ] \
  && pass "worktree-scope: non-repo → not_a_repo" \
  || bad "worktree-scope: non-repo gave action=$(kv "$out" action), want not_a_repo"

# The case the whole helper exists for. A linked worktree MUST resolve to itself and demand an
# index_folder — resolving to the parent is the silent failure that reads as a healthy index.
WT_DIR="$TMP/linked-wt"
if git -C "$ROOT" worktree add --detach "$WT_DIR" HEAD >/dev/null 2>&1; then
  out="$(bash "$WT_SCOPE" "$WT_DIR" 2>&1)"
  [ "$(kv "$out" is_linked_worktree)" = "yes" ] \
    && pass "worktree-scope: linked worktree detected" \
    || bad "worktree-scope: linked worktree not detected (is_linked_worktree=$(kv "$out" is_linked_worktree))"
  [ "$(kv "$out" action)" = "index_folder" ] \
    && pass "worktree-scope: linked worktree → index_folder" \
    || bad "worktree-scope: linked worktree gave action=$(kv "$out" action), want index_folder"
  # target_repo must be the WORKTREE (what to index), git_common_dir the PARENT (the identity key).
  case "$(kv "$out" target_repo)" in
    *linked-wt) pass "worktree-scope: target_repo is the worktree, not the parent" ;;
    *) bad "worktree-scope: target_repo=$(kv "$out" target_repo) — resolved to the parent, the exact bug this prevents" ;;
  esac
  case "$(kv "$out" git_common_dir)" in
    "$ROOT"/*) pass "worktree-scope: git_common_dir is absolute and points at the parent" ;;
    *) bad "worktree-scope: git_common_dir=$(kv "$out" git_common_dir) — must be the parent's absolute common dir" ;;
  esac
else
  printf 'SKIP: linked-worktree case (git worktree add failed)\n'
fi

# ── 2. stryker-scoped-config.sh ──────────────────────────────────────────────
PROJ="$TMP/proj"
mkdir -p "$PROJ/src"
printf '{"name":"t","version":"1.0.0","devDependencies":{"vitest":"^2.0.0"},"scripts":{"test":"vitest run"}}\n' > "$PROJ/package.json"
printf 'export const add=(a,b)=>a+b;\n' > "$PROJ/src/a.js"
printf 'export const sub=(a,b)=>a-b;\n' > "$PROJ/src/b.js"

if command -v node >/dev/null 2>&1; then
  out="$(bash "$STRYKER" --repo "$PROJ" --file src/a.js --file src/b.js 2>&1)"
  cfg="$(kv "$out" config_path)"
  [ "$(kv "$out" mutate_count)" = "2" ] \
    && pass "stryker: mutate_count reflects the scope set" \
    || bad "stryker: mutate_count=$(kv "$out" mutate_count), want 2"
  [ "$(kv "$out" test_runner)" = "vitest" ] \
    && pass "stryker: runner detected from the manifest" \
    || bad "stryker: test_runner=$(kv "$out" test_runner), want vitest"
  # Decision 3 in the script header: perTest mismarks static mutants as SURVIVED, so the
  # default must be off. A silent flip here re-opens the false-survivor class the re-probe exists for.
  [ "$(kv "$out" coverage_analysis)" = "off" ] \
    && pass "stryker: coverageAnalysis defaults to off" \
    || bad "stryker: coverage_analysis=$(kv "$out" coverage_analysis), want off by default"
  if [ -f "$cfg" ] && python3 - "$cfg" <<'PY'
import json,sys
c=json.load(open(sys.argv[1]))
assert c["mutate"]==["src/a.js","src/b.js"], c["mutate"]
assert c["tempDirName"] != ".stryker-tmp", "shared temp dir — concurrent runs corrupt each other"
assert c["jsonReporter"]["fileName"].startswith("/"), "report path must be absolute"
PY
  then
    pass "stryker: config carries the full scope, a private temp dir and an absolute report path"
  else
    bad "stryker: generated config failed its shape assertions"
  fi
  # Two invocations over the same scope must not share a sandbox.
  out2="$(bash "$STRYKER" --repo "$PROJ" --file src/a.js --file src/b.js 2>&1)"
  [ "$(kv "$out" temp_dir)" != "$(kv "$out2" temp_dir)" ] \
    && pass "stryker: two runs get distinct temp dirs" \
    || bad "stryker: two runs shared temp_dir=$(kv "$out" temp_dir)"

  # An empty/typo'd scope must be an ERROR, never a config: Stryker scores an empty
  # mutate set as a successful 100% run.
  bash "$STRYKER" --repo "$PROJ" --file src/typo.js >/dev/null 2>&1
  [ "$?" -eq 3 ] && pass "stryker: nonexistent file → exit 3, no config emitted" \
                 || bad "stryker: nonexistent file did not exit 3"
  bash "$STRYKER" --repo "$PROJ" >/dev/null 2>&1
  [ "$?" -eq 2 ] && pass "stryker: no --file → usage error" || bad "stryker: no --file did not exit 2"
else
  printf 'SKIP: stryker-scoped-config cases (node not installed)\n'
fi

# ── 3. mutation-survivor-reprobe.sh ──────────────────────────────────────────
if command -v python3 >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
  RP="$TMP/reprobe"
  mkdir -p "$RP"
  (
    cd "$RP" || exit 1
    git init -q .
    # Two functions on purpose: `return a` then occurs TWICE, which is what makes the
    # non-unique-anchor assertion below a real test rather than a tautology.
    printf 'def add(a, b):\n    return a + b\n\ndef sub(a, b):\n    return a - b\n' > calc.py
    printf 'python3 -c "import calc; assert calc.add(2,3)==5"\n' > covered.sh
    printf 'python3 -c "import calc; calc.add(2,3)"\n' > weak.sh
    git add -A && git -c user.email=t@t -c user.name=t commit -qm init
  ) || bad "reprobe: could not build the fixture repo"

  SHA_PRE="$(shasum -a 256 "$RP/calc.py" 2>/dev/null | awk '{print $1}')"

  ( cd "$RP" && bash "$REPROBE" --file calc.py --original "return a + b" --mutated "return a - b" \
      --test-cmd "bash covered.sh" >/dev/null 2>&1 )
  [ "$?" -eq 0 ] && pass "reprobe: covered mutant → KILLED (exit 0)" \
                 || bad "reprobe: covered mutant did not report KILLED"

  ( cd "$RP" && bash "$REPROBE" --file calc.py --original "return a + b" --mutated "return a - b" \
      --test-cmd "bash weak.sh" >/dev/null 2>&1 )
  [ "$?" -eq 1 ] && pass "reprobe: uncovered mutant → SURVIVED (exit 1)" \
                 || bad "reprobe: uncovered mutant did not report SURVIVED"

  SHA_POST="$(shasum -a 256 "$RP/calc.py" 2>/dev/null | awk '{print $1}')"
  [ "$SHA_PRE" = "$SHA_POST" ] \
    && pass "reprobe: production file restored byte-identical after both probes" \
    || bad "reprobe: production file NOT restored — a probe left a mutant in real source"

  # A timeout is not a kill. Reading its non-zero exit as KILLED manufactures coverage out of
  # an infrastructure failure, which is the most dangerous possible direction for this tool.
  ( cd "$RP" && bash "$REPROBE" --file calc.py --original "return a + b" --mutated "return a - b" \
      --test-cmd "sleep 30" --timeout 3 >/dev/null 2>&1 )
  [ "$?" -eq 3 ] && pass "reprobe: timeout → ERROR (exit 3), never KILLED" \
                 || bad "reprobe: timeout was not reported as ERROR"

  # An ambiguous anchor probes a different site than the report named.
  ( cd "$RP" && bash "$REPROBE" --file calc.py --original "return a" --mutated "return b" \
      --test-cmd "true" >/dev/null 2>&1 )
  [ "$?" -eq 3 ] && pass "reprobe: non-unique anchor refused" || bad "reprobe: non-unique anchor was accepted"

  # A dirty target destroys the restore-verification signal.
  ( cd "$RP" && printf '# dirty\n' >> calc.py && bash "$REPROBE" --file calc.py \
      --original "return a + b" --mutated "return a - b" --test-cmd "true" >/dev/null 2>&1 )
  [ "$?" -eq 3 ] && pass "reprobe: dirty target refused" || bad "reprobe: dirty target was accepted"
  ( cd "$RP" && git checkout -- calc.py 2>/dev/null )
else
  printf 'SKIP: reprobe cases (python3 or git missing)\n'
fi

if [ "$fail" = 0 ]; then echo "ALL PASSED"; exit 0; else echo "SOME FAILED"; exit 1; fi
