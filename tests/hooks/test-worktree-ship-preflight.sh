#!/usr/bin/env bash
# Two preflights that were missing, both reported from the test farm as skill-side gaps:
#
#   zuvo:worktree Step 4.5 — prove the installed dependency tree matches THIS branch's lockfile.
#     A worktree once ran its suite against another branch's node_modules (TanStack v9 installed,
#     v8 in the lockfile) and reported failures that did not exist in the code. It did NOT happen
#     on the farm, which runs its own `npm ci` from the branch lockfile — so it is a local-only
#     failure and nothing upstream could catch it.
#   zuvo:ship preflight (c) — HEAD already fully contained in <remote>/<target>. ship checked the
#     base moving (b) and unpublished commits on the target (a), never the case where this branch
#     contributes nothing. That run passes tests, reviews an empty diff, invents a version bump and
#     pushes a no-op, and reports success.
#
# The shell in both skills is EXTRACTED and EXECUTED here, so the documented commands cannot drift
# from behaviour the way prose does.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WT="$ROOT/skills/worktree/SKILL.md"
SHIP="$ROOT/skills/ship/SKILL.md"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

echo "=== ship preflight (c): HEAD already merged ==="

# The real check, verbatim from the skill — if the skill's line changes, this extraction fails loudly.
# Newlines are KEPT: the command uses a `\`-continuation, and collapsing it to one line turns
# that into a stray `\ ` and the check silently never runs — which is how it would fail in a
# skill too, so the test must execute the exact shape the skill documents.
CHECK=$(awk '/# \(c\) the INVERSE of \(b\)/,/nothing to ship"/' "$SHIP" | grep -vE '^[[:space:]]*#')
if [ -z "$CHECK" ]; then
  bad "could not extract preflight (c) from ship/SKILL.md — re-anchor this test"
else
  ok "preflight (c) extracted from the skill"
fi

mkrepo(){ rm -rf "$TMP/r" "$TMP/rem"; mkdir -p "$TMP/r"; cd "$TMP/r"
  git init -q; git config user.email t@t; git config user.name t
  echo a > f; git add f; git commit -qm base
  git init -q --bare "$TMP/rem"; git remote add origin "$TMP/rem"
  git push -q origin HEAD:refs/heads/main 2>/dev/null
  git fetch -q origin 2>/dev/null; }
runcheck(){ PUSH_REMOTE=origin TARGET_BRANCH=main sh -c "$CHECK" 2>&1; }

# 1. HEAD == remote/main -> nothing to ship. This is the case that used to sail through.
mkrepo
case "$(runcheck)" in *"already merged"*) ok "HEAD identical to origin/main: fires" ;;
  *) bad "HEAD identical to origin/main did NOT fire — a no-op ship still reports success" ;; esac

# 2. HEAD ahead of remote/main -> a real release, must stay silent.
echo b >> f; git commit -qam work
case "$(runcheck)" in *"already merged"*) bad "fired on a branch with unpushed work — false positive blocks real releases" ;;
  *) ok "HEAD ahead of origin/main: silent (a real release is not blocked)" ;; esac

# 3. The post-merge shape the farm reported: the target moved ahead AND absorbed this branch.
#    Both (b) and (c) are true at once; (c) must still fire, because (b)'s remedy (merge and
#    re-run) produces nothing when there is nothing left to contribute.
git push -q origin HEAD:refs/heads/main 2>/dev/null
git commit -q --allow-empty -m "other work on target" 2>/dev/null
git push -q origin HEAD:refs/heads/main 2>/dev/null
git reset -q --hard HEAD~1                       # this branch is now behind AND contained
git fetch -q origin 2>/dev/null
case "$(runcheck)" in *"already merged"*) ok "branch behind AND contained: still fires" ;;
  *) bad "did not fire when the branch was behind and fully contained" ;; esac

# 4. The remedy must be a STOP with a question, never a silent continue.
grep -q '(c) fired → STOP before Phase 1' "$SHIP" \
  && ok "the skill routes (c) to STOP before Phase 1" || bad "(c) has no STOP instruction"
grep -q 're-release of an already-merged' "$SHIP" \
  && ok "the one legitimate continue (re-release) is named and must be declared" \
  || bad "no escape documented for a deliberate re-release — agents will invent one"

echo "=== worktree Step 4.5: dependency verdict ==="

DEPCHECK=$(awk '/^case "\$\(ls package-lock.json/,/^esac$/' "$WT")
if [ -z "$DEPCHECK" ]; then
  bad "could not extract the Step 4.5 check from worktree/SKILL.md — re-anchor this test"
else
  ok "Step 4.5 check extracted from the skill"
fi

cd "$TMP"; mkdir -p dep && cd dep
# no lockfile at all -> UNVERIFIED, and it must SAY so rather than implying OK
case "$(sh -c "$DEPCHECK" 2>&1)" in *UNVERIFIED*) ok "no lockfile: UNVERIFIED (not a silent OK)" ;;
  *) bad "no lockfile did not report UNVERIFIED" ;; esac

# a real npm project whose installed tree does NOT match the lockfile is the reported failure
if command -v npm >/dev/null 2>&1; then
  printf '{"name":"t","version":"1.0.0","dependencies":{"left-pad":"^1.3.0"}}' > package.json
  printf '{"name":"t","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{}}' > package-lock.json
  mkdir -p node_modules            # present but empty: the "looks installed" shape
  case "$(sh -c "$DEPCHECK" 2>&1)" in *MISMATCH*) ok "declared dep missing from node_modules: MISMATCH" ;;
    *"deps: OK"*) bad "an empty node_modules reported OK — this is the exact reported failure" ;;
    *) ok "npm path produced a verdict (environment-dependent wording)" ;; esac
else
  ok "npm absent — skipped the npm case (verdict path still covered by the UNVERIFIED case)"
fi

# the verdict must reach the user-facing output block, or it is a check nobody sees
grep -q 'Deps:' "$WT" && ok "CREATE output carries a Deps: line" || bad "the verdict never reaches the output block"
grep -q 'run this check ALWAYS' "$WT" \
  && ok "the check is mandated precisely for the case that looks fine" \
  || bad "nothing forces the check when node_modules already exists — the failing path stays open"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
