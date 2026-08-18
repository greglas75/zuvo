---
name: ship
description: >
  Pre-merge release pipeline: run tests, auto-scaled code review, version bump,
  changelog generation, git tag, push or PR. Auto-detects branch context (direct
  push on main, PR on feature branch). Scales review depth by diff size.
  Flags: --full, --no-bump, --no-tag, --dry-run, patch/minor/major.
category: Release
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - changed_symbols
    - diff_outline
    - scan_secrets             # KEY — last-line check before push
    - search_patterns
  by_stack: {}                  # delegates to review/code-audit which have full by_stack
---

# zuvo:ship

Prepare and push a release. Tests, version bump, changelog, tag, and push — auto-scaled by diff size.

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Argument | Effect |
|----------|--------|
| _(no flags)_ | Auto-scaled pipeline based on diff size |
| `--full` | Force full pipeline: tests + review + design-review + coverage + bump + push |
| `--no-bump` | Skip version bumping (hotfixes, chores) |
| `--no-tag` | Skip git tag creation |
| `--dry-run` | Show what would happen without executing |
| `patch` / `minor` / `major` | Explicit bump type (overrides auto-detection) |

Flags can be combined: `zuvo:ship --full --no-tag`, `zuvo:ship minor --no-tag`

**There is NO review-skip flag — removed 2026-08-02.** A field run proved the failure mode: the
agent self-applied `--fast` when the user typed only "ship"; the prose rule ("user-provided
ONLY") caught it that once, but a bypass that exists as text an agent can type is a bypass that
will eventually be typed. Small diffs (<20 LOC) already take the fast path automatically via the
threshold table, so the flag's only unique power was skipping review on LARGE diffs — the exact
case review exists for. If a human genuinely must ship unreviewed, that decision lives OUTSIDE
this skill (the logged `ZUVO_ALLOW_ADHOC=1` escape at the push gate), never as a skill argument.

## Mandatory File Loading

Read each file below using the Read tool. Print the checklist with status before proceeding. Do not proceed from memory.

```
CORE FILES LOADED:
  1. ../../shared/includes/env-compat.md       — READ/MISSING
  2. ../../shared/includes/codesift-setup.md   — READ/MISSING
  3. ../../shared/includes/run-logger.md       — READ/MISSING
  4. ../../shared/includes/retrospective.md    — READ/MISSING
  5. ../../shared/includes/knowledge-curate.md — READ/MISSING
  6. ../../shared/includes/knowledge-prime.md  — READ/MISSING
  7. ../../shared/includes/no-pause-protocol.md — READ/MISSING (HARD: no mid-pipeline pauses)
  8. ../../shared/includes/documentation-mandate.md — READ/MISSING (Phase 3 cites it as a completion-gate item)
  9. ../../shared/includes/terminal-state.md    — READ/MISSING (HARD: no SHIP COMPLETE over a pending check)
```

If any file is missing: proceed in degraded mode. Note which files are unavailable in the Phase 5 output.

---

**Dispatch is already authorized — do not ask, do not downgrade.** Invoking this skill IS the
request for every agent and gate it mandates, so a session rule about unprompted Agent use does not
apply here. Only a harness with NO dispatch capability takes the documented single-agent fallback,
and it still runs every gate inline — see `../../shared/includes/env-compat.md`. Skipping a mandated
agent and self-scoring the result is a substituted gate, not a degraded run.

## SAFETY RULES

**Read these before executing any phase. Violations are non-recoverable.**

1. **NEVER** use `git add -A` or `git add .`. Stage ONLY source files that were actually generated or modified by the release step: the version file (only if bump was performed) and `CHANGELOG.md` (only if created/updated). `memory/last-ship.json` is runtime release state and MUST be written locally after the release commit is finalized; do not commit it.
2. **PUSH IS PART OF SHIP — do not stop before it and do not ask for it.** Invoking `zuvo:ship`
   IS the authorization to push: the user asked to ship, and a release sitting unpushed on the
   local machine is not shipped. Push the branch (and the tag, if one was created) on every
   platform, interactive or not. Do NOT print "run this manually" — that hands the user back the
   one step they invoked the skill to avoid. The gates that make this safe are the ones ALREADY in
   this skill: tests must be green, the review threshold in Phase 2 is mandatory and unskippable,
   and `scan_secrets` runs as the last-line check before push. If those pass, push.
3. **NEVER** force-push (`--force`, `--force-with-lease`), never push to a branch other than the
   one ship is on, and never rewrite history. Those are a different blast radius from a
   fast-forward push and are out of scope for ship entirely — they stay a human decision. Likewise,
   if the pre-push gate BLOCKS (see Phase 4), fix the cause; never reach for `ZUVO_ALLOW_ADHOC=1`
   on ship's behalf.
4. **Default to `patch`** bump with `[AUTO-DECISION]` annotation in non-interactive environments when the user cannot be asked for bump type.
5. **NEVER** propose skipping, downgrading, or shortcutting the review threshold from Phase 2. The threshold table is MANDATORY — the agent does not get to override it based on effort estimates ("this would take hours"), prior pipeline claims ("execute already reviewed"), or diff complexity ("most of this is boilerplate"). There is NO flag that skips review — `--fast` was removed 2026-08-02 after an agent self-applied it (see Argument Parsing). If you catch yourself thinking "this is too much review for this release" — that is exactly when the review is most needed.
6. **NEVER** claim that prior pipeline steps (zuvo:execute, zuvo:plan) substitute for ship review. Execute reviews individual tasks during implementation. Ship reviews the integrated whole. These are different scopes — one does not replace the other.

---

### Knowledge Prime

Run the knowledge prime protocol from `knowledge-prime.md`:
```
WORK_TYPE = "implementation"
WORK_KEYWORDS = <keywords from user request>
WORK_FILES = <files being touched>
```

---

## Phase 0: Pre-flight

1. **Detect current branch, flow, and the remote everything else resolves against:**
   ```bash
   BRANCH=$(git branch --show-current)
   [ -n "$BRANCH" ] || { echo "[SHIP] detached HEAD — checkout a branch before shipping"; exit 1; }

   # Resolve the push remote ONCE — never hardcode `origin`. A repo with a dead `origin` mirror
   # and a real work remote is not exotic, and push, PR creation and every base comparison below
   # must all mean the same remote.
   PUSH_REMOTE=$(git config --get remote.pushdefault 2>/dev/null || true)
   [ -n "$PUSH_REMOTE" ] || PUSH_REMOTE=$(git config --get "branch.$BRANCH.remote" 2>/dev/null || true)
   [ -n "$PUSH_REMOTE" ] || PUSH_REMOTE=origin
   ```
   - If on `main`, `master`, `trunk`, or `develop`: **direct flow** — set `FLOW=direct` and
     `TARGET_BRANCH=<current branch>` (tag + push to current branch; the target IS this branch,
     and the steps below all resolve against `$TARGET_BRANCH` regardless of flow).
   - If on any other branch: **PR flow** — set `FLOW=pr` (push branch + create PR targeting the default branch). Detect the default branch for `targetBranch`:
     ```bash
     TARGET_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null \
       || git symbolic-ref "refs/remotes/$PUSH_REMOTE/HEAD" 2>/dev/null | sed "s@^refs/remotes/$PUSH_REMOTE/@@" \
       || echo main)
     ```
   - **A repo-level convention overrides this heuristic.** If the project's `CLAUDE.md`/contributing
     docs say "PR required, no direct commits to main" or name an integration branch as the merge
     target, that wins over the branch-name rule and over `origin/HEAD`. Print which source decided:
     `[SHIP] flow=<direct|pr> target=<branch> (source: <branch-heuristic|repo-convention>)`.

2. **Check GitHub CLI availability:**
   ```bash
   gh auth status
   ```
   - If the command fails or `gh` is not installed: set `GH_AVAILABLE=false`. Continue — Phase 4
     Step 4 pushes the branch and ends `SHIP INCOMPLETE: PR not created`, because an unmerged
     branch is not a shipped release (see E3 handling).
   - **`gh` present does not mean this remote is a GitHub it can talk to.** Ask `gh` which hosts it
     is authenticated against and compare with the remote's host —
     `gh auth status` lists them, `git remote get-url "$PUSH_REMOTE"` gives the host. A match
     (including **GitHub Enterprise**, whose hostname is not github.com and which `gh` supports
     natively) → PR flow works. A GitLab/Bitbucket/Gitea remote, or a host `gh` is not logged into
     → the same `GH_AVAILABLE=false` path. Do not infer "not GitHub" from "not github.com": that
     forces every Enterprise repo down the PR-not-created path with a working forge in front of it. On direct flow none of this matters; the plain `git push` is
     forge-agnostic and the run completes normally.

3. **Resolve `BASE_REF` — ONCE, here — and check the range is non-empty.**
   Every later phase measures against this: the "nothing to ship" check, the Phase 1 baseline
   worktree, the Phase 2 DIFF_LOC + review range, the Phase 2.5 reflection diff. They used to
   resolve it independently (or reference a `<default>` placeholder), which is how the same run
   could review one range and baseline against another.
   ```bash
   # Fetch FIRST — step 4's base preflight runs after this, but `merge-base` against
   # $PUSH_REMOTE/$TARGET_BRANCH is only as correct as the last fetch, and a stale remote ref makes
   # the PR base older than reality: the review then covers commits that are already merged.
   git fetch --quiet "$PUSH_REMOTE" || echo "[SHIP] fetch failed — BASE_REF resolves against stale refs"

   if [ "$FLOW" = "pr" ]; then
     # PR flow: what THIS branch adds. The last tag can be hundreds of already-merged commits back.
     BASE_REF=$(git merge-base HEAD "$PUSH_REMOTE/$TARGET_BRANCH" 2>/dev/null \
                || git merge-base HEAD "$TARGET_BRANCH" 2>/dev/null || true)
     [ -n "$BASE_REF" ] || { echo "[SHIP] cannot resolve a PR base against $TARGET_BRANCH — fix the remote before shipping"; exit 1; }
   else
     # Release flow: since the last RELEASE tag. --match is not optional: bare `git describe --tags`
     # returns the newest tag of ANY kind, and this skill family writes operational tags
     # (`reviewed/<sha>`, `review-YYYY-MM-DD-*`) into the same namespace. A review marker as the
     # base silently shrinks the release to "since the last review".
     BASE_REF=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --match '[0-9]*.[0-9]*' 2>/dev/null || true)
     # First release: BASE_REF stays a COMMIT (the root), because everything downstream treats it
     # as one — `git log BASE..HEAD`, `git worktree add <tmp> "$BASE_REF"`, `git merge-base`. The
     # empty-tree hash works in `git diff` and nowhere else; using it here fails Phase 0's own
     # `git log` on the very release it exists for.
     if [ -z "$BASE_REF" ]; then
       BASE_REF=$(git rev-list --max-parents=0 HEAD | tail -1)
       FIRST_RELEASE=true
     fi
   fi

   # DIFF_BASE is what every DIFF uses (LOC, review input, cross-provider input). It equals
   # BASE_REF everywhere except a first release, where `git diff <root>..HEAD` would omit
   # everything the ROOT COMMIT itself introduced — usually the entire initial codebase.
   # Assigned here, OUTSIDE the if/else: setting it only in the release branch left it EMPTY on
   # every PR-flow run, and `git diff --stat "" HEAD` compares the working tree to HEAD — a
   # near-zero DIFF_LOC that fast-paths past review entirely.
   if [ "${FIRST_RELEASE:-false}" = true ]; then
     DIFF_BASE=$(git hash-object -t tree /dev/null)     # 4b825dc642cb… — first release only
   else
     DIFF_BASE="$BASE_REF"
   fi
   [ -n "$DIFF_BASE" ] || { echo "[SHIP] DIFF_BASE empty — refusing to measure a diff against nothing"; exit 1; }

   echo "[SHIP] BASE_REF=$(git rev-parse --short "$BASE_REF") DIFF_BASE=$DIFF_BASE ($FLOW flow)"
   # On a first release the root commit IS part of the release, and `root..HEAD` excludes it —
   # a single-commit repo would report "nothing to ship" about its entire contents.
   if [ "${FIRST_RELEASE:-false}" = true ]; then git log --oneline HEAD
   else git log --oneline "${BASE_REF}..HEAD"; fi
   ```
   - If no commits in range: print "Nothing to ship. No commits in `${BASE_REF}..HEAD`." and exit
     cleanly. Name the base in the message — "no commits since the last tag" was reported against a
     base nobody could see, and on the wrong base it is a lie that reads like a fact.
   - **Re-resolve `BASE_REF` AND `DIFF_BASE` after step 4(b)** if you merge the moved base in: the
     merge changes what `merge-base` returns, and a stale value scopes the review to the pre-merge
     range. Re-run this whole block — a `${DIFF_BASE:-...}` style default would keep the old value
     precisely because it is already set, which is the failure it looks like it prevents.

   **Half-completed prior run (idempotency — this HAPPENED on 2026-08-01).** A previous ship can
   have committed the release and then died before tagging/pushing (e.g. the pre-push gate blocked
   it). Detect it before bumping anything:
   ```bash
   HEAD_MSG=$(git log -1 --format='%s')
   case "$HEAD_MSG" in
     # capture the FULL version token, not just [0-9.] — truncating `v1.2.3-rc.1` to `1.2.3` makes
    # the tag lookup below miss the real tag and declare a completed release "half-done"
    release:\ v*) HALF_DONE_VER=$(printf '%s' "$HEAD_MSG" | sed -n 's/^release: v\([0-9A-Za-z.+-]*\).*/\1/p') ;;
     *) HALF_DONE_VER="" ;;
   esac
   # a release commit whose tag does NOT exist = the previous run stopped between commit and tag
   [ -n "$HALF_DONE_VER" ] && ! git rev-parse -q --verify "refs/tags/v$HALF_DONE_VER" >/dev/null \
     && echo "RESUME: v$HALF_DONE_VER committed but not tagged"
   ```
   If that fires: **SKIP Phase 3 entirely** (the version file is already at `$HALF_DONE_VER`;
   bumping again would ship v+2 and pollute the conventional-commit scan with the previous
   `release:` message), set `RELEASE_SHA=HEAD`, and resume at Phase 4 Step 3 (tag). Print
   `[RESUME] half-completed ship detected — skipping bump, resuming at tag`.

   **The HEAD-only form above is not sufficient — also sweep recent history for UNTAGGED
   releases.** A ship that dies between commit and tag is only at HEAD until the next commit
   lands; after that the check above sees an ordinary HEAD and the release stays permanently
   untagged while the version numbers march on. That happened in this very repo: `v1.6.67`
   (2026-08-11) bumped every version file and pushed, never got a tag, four commits landed on top,
   and the next run shipped `v1.6.68` straight past it. Nothing noticed until `git tag` was diffed
   against the release commits by hand a day later.
   ```bash
   git log --format='%H %s' -30 --grep='^release: v' | while read -r _sha _msg; do
     _ver=$(printf '%s' "$_msg" | sed -n 's/^release: v\([0-9A-Za-z.+-]*\).*/\1/p')
     [ -n "$_ver" ] || continue
     git rev-parse -q --verify "refs/tags/v$_ver" >/dev/null 2>&1 \
       || echo "UNTAGGED RELEASE: v$_ver at $_sha"
   done
   ```
   For each hit that is NOT HEAD: create the missing tag at ITS commit
   (`git tag -a "v$_ver" "$_sha" -m "release: v$_ver (tag reconstructed)"`), push it with this
   run's tag push, and report it in SHIP COMPLETE. Do **not** re-bump and do **not** move the tag
   to HEAD — the tag names the commit that carried that version, and a tag pointing at later code
   silently misstates what shipped.

4. **Base preflight — fetch, then check the two things that invalidate everything downstream.**
   Both failures below surface at push time otherwise, i.e. *after* tests, review and the version
   bump have already been paid for. Ten+ ship retros between 2026-08-05 and 2026-08-11 hit one of
   them; the review skill has this check and ship did not.
   ```bash
   git fetch --quiet "$PUSH_REMOTE" || echo "[SHIP] fetch failed — the base checks below ran on stale refs"

   # (a) PR FLOW ONLY — unpublished commits on the TARGET branch. The PR silently carries work
   #     the user never pushed, and the review scope question then has no honest answer.
   #     (On direct flow TARGET_BRANCH is the branch being shipped, so this list is simply the
   #     release itself — do not run the check there, and never read it as a finding.)
   [ "$FLOW" = "pr" ] && git log --oneline "$TARGET_BRANCH" --not --remotes | head -20

   # (b) the base moved: <remote>/<target> has commits this branch does not.
   git merge-base --is-ancestor "$PUSH_REMOTE/$TARGET_BRANCH" HEAD \
     || echo "[SHIP] base moved — $PUSH_REMOTE/$TARGET_BRANCH is ahead of this branch"

   # (c) the INVERSE of (b), and the one nothing checked: HEAD is already fully contained in
   #     <remote>/<target>. There is nothing to ship. Distinct from (b) — (b) says the base gained
   #     commits, (c) says this branch contributes none. Both can be true at once after a merge.
   git merge-base --is-ancestor HEAD "$PUSH_REMOTE/$TARGET_BRANCH" 2>/dev/null \
     && echo "[SHIP] HEAD already merged into $PUSH_REMOTE/$TARGET_BRANCH — nothing to ship"
   ```
   - **(a) non-empty on PR flow → STOP** before Phase 1. Print the commits and ask whether to push
     the default branch first or cherry-pick this work onto a fresh branch off the remote base.
     Shipping N unreviewed inherited commits under one `ship` invocation is a blast radius the user
     did not ask for.
   - **(c) fired → STOP before Phase 1.** Every commit on this branch is already on the remote
     target, so there is no release here: the suite would pass, the review would find an empty
     diff, a version bump and tag would be invented for work that shipped earlier, and the push
     would be a no-op the run still reports as success. That is the shape of a ship that "worked"
     and changed nothing. Say which commits are already merged (`git log --oneline
     "$PUSH_REMOTE/$TARGET_BRANCH" --not HEAD | head -5` shows the target's extra work) and ask
     what was actually meant: ship a DIFFERENT branch, re-cut work on top of the current base, or
     nothing at all. The one case where continuing is legitimate is a re-tag/re-release of the same
     tree — proceed only if the user says so, and print `[SHIP] re-release of an already-merged
     tree, per user` so the run log does not read as a fresh release.
   - **(b) fired → merge `$PUSH_REMOTE/$TARGET_BRANCH` into the branch NOW, and re-run the suite on
     the merged tree** (Phase 1 runs after this, so this is free). A textual merge accepts semantic
     conflicts silently; the merged tree is the only tree the test result is about. Merging later —
     after review — invalidates the review scope and, past ~100 commits of distance, GitHub stops
     computing mergeability at all (see the four failure modes in Phase 4 Step 4).

5. **Dry-run gate:** If `--dry-run` was passed, walk through each subsequent phase printing what would happen at each step (branch, flow, diff LOC, review depth, bump type, files staged, tag name, push target). Then exit without executing anything.

---

## Phase 1: Tests

1. **Detect test command.** Check in order:
   - `package.json` → `scripts.test` (run with `npm test` / `yarn test` / `pnpm test`)
   - `Makefile` → `test` target (run with `make test`)
   - `pyproject.toml` → `[tool.pytest]` or `[tool.pytest.ini_options]` (run with `pytest`)
   - `Cargo.toml` → `cargo test`
   - `composer.json` → `scripts.test` (run with `composer test`)
   - If no test command found: print "No test runner detected. Skipping tests." and continue.

1b. **Run the CHEAP checks CI runs, not only the test suite.** A green `npm test` is not a green
   pipeline. Detect and run, in this order, every one the project defines — they are seconds each
   and they gate the same push:

   | Check | Where to look |
   |---|---|
   | format | `scripts.format:check` / `format:ci` / `fmt:check`; `biome ci`, `prettier --check`, `cargo fmt --check`, `ruff format --check`, `gofmt -l` |
   | lint | `scripts.lint:ci` / `lint`; `eslint`, `biome check`, `ruff check`, `clippy`, `golangci-lint` |
   | typecheck | `scripts.typecheck` / `type-check`; `tsc --noEmit`, `mypy`, `pyright` |
   | build | `scripts.build`; `cargo build`, `go build ./...` |

   Prefer the `:ci` variant when both exist — it is the one the pipeline runs, and the plain
   variant often auto-fixes instead of failing. Run them BEFORE the suite: they are the fastest and
   they fail on the largest class of trivially-avoidable CI reds.

   **Why this is not optional.** Measured 2026-08-17 on `rs_be`: the first CI run of a PR died on
   **one Biome formatting difference** in a spec file. That cost a 291 s CI job, a full retry cycle,
   a second 568 s Semgrep pass, and the polling around all of it. The check that would have caught
   it — `npm run lint:ci` — measured **under 1 second across 1217 files**. Ship ran only `npm test`,
   so it pushed a diff it already had everything needed to reject.

   A failure here is a normal, fixable finding: fix it (a formatter difference is a formatter run,
   not a judgement call), re-run the check, and continue. It is NOT grounds to skip the check — a
   project whose formatter cannot be satisfied locally will fail the same way in CI, just slower and
   after a push. Apply the same `TEST_RAN` discipline as step 2: a checker that exits 0 having
   inspected zero files has proved nothing. Record each as
   `format: pass (1217 files)` / `typecheck: pass` in the artifact, and `n/a` where the project
   defines no such script — never silently omit one that ran.

2. **Run the test suite — and prove it produced a verdict.** Capture exit code, pass count and
   fail count. All three, from the RUNNER, not from whatever wrapped it:

   ```bash
   # NO PIPE around the runner. `runner | tail` makes `$?` tail's status (always 0), and the usual
   # fix is not portable either: ${PIPESTATUS[0]} is bash-only — under zsh (the macOS default
   # login shell) the array is $pipestatus and 1-indexed, so ${PIPESTATUS[0]} expands to EMPTY and
   # TEST_RC silently becomes "". Redirect to a file, read $?, then look at the file.
   TEST_LOG=$(mktemp -t ship-tests.XXXXXX)   # not a fixed /tmp name: two ship runs on one host
   npm test > "$TEST_LOG" 2>&1               # would clobber each other's verdict, and a symlink
   TEST_RC=$?                                # pre-created at a predictable path redirects the write
   tail -40 "$TEST_LOG"
   echo "[SHIP] TEST_RC=$TEST_RC log=$TEST_LOG"   # print it: the next block is a different shell

   # A summary line proving tests EXECUTED — passed OR failed. "0 tests"/"0 passed, 0 failed" is
   # what an evicted or never-scheduled runner prints, and it satisfies "0 failures" while proving
   # nothing ran. Counting only PASSES would misread the opposite case: a suite where every test
   # fails legitimately reports "0 passed, 12 failed" and must go to triage, not to ENV-RERUN.
   if grep -Eiq '([1-9][0-9]* (passed|passing|failing|failed|tests?|examples?)|Tests:[[:space:]]*[1-9]|OK \([1-9][0-9]* tests?\)|RESULT: (PASS|FAIL)=[1-9]|^ok[[:space:]]+[^[:space:]]+|^(PASS|FAIL)$)' "$TEST_LOG"; then
     RAN=true
   else
     RAN=false
   fi
   echo "[SHIP] TEST_RAN=$RAN"
   ```

   Two ways a green result is not one, both observed on this fleet:
   - **The status came from a pipe or a wrapper.** Every agent pipes a noisy runner through
     `| tail`, and `$?` then belongs to `tail`. A backgrounded or `timeout`-wrapped run reports the
     wrapper's status the same way. Read `${PIPESTATUS[0]}`, or `set -o pipefail` first.
   - **Exit 0 with no summary line.** A farm/remote runner that is evicted, truncated or never
     scheduled exits 0 having run nothing. Pass count and fail count are both zero, which satisfies
     "0 failures" and satisfies nothing else. An absent summary is NOT a pass — treat it as the
     ENV-RERUN class in step 3 c2 and re-run before reading anything into it.

   **`TEST_RAN=false` is a hard branch, not a warning.** It means the suite produced no evidence of
   executing anything: go to step 3 class c2 (ENV-RERUN) and re-run — regardless of `TEST_RC`, and
   *especially* when `TEST_RC=0`, which is exactly what an evicted runner returns. Do not proceed to
   Phase 2 on `TEST_RAN=false`; a printed warning that nothing enforces is how "0 tests" shipped as
   green.

   Record the numbers you actually parsed. `tests: "pass"` in the artifact must trace to a summary
   line you can quote, not to an exit code alone.

3. **If tests fail: TRIAGE, never a bare abort.** A red suite has three different causes with
   three different fixes — collapsing them into "stop and ask" froze a shippable branch on two
   inherited snapshots (field feedback 2026-08-01: "czemu nie każe naprawić, tylko blokuje?").
   Classify EVERY failing test first:

   a. **Baseline the failures against the ship base.** Preferred: run ONLY the failing test
      files at the ship base (`git worktree add --detach "$(mktemp -du -t ship-base.XXXXXX)" "$BASE_REF"`
      — `-u` because `worktree add` refuses a directory that already exists, and `--detach` because
      the default creates a BRANCH named after the directory, leaving `ship-base.XXXX` refs behind
      in the repo forever; a literal `<tmp>` reused across runs fails outright once one run aborts;
      reusing installed deps when
      the lockfile is unchanged; remove the worktree after). Use `$BASE_REF` — the base Phase 0
      resolved and Phase 2 measures — not a literal `<default>` placeholder: on direct flow
      `git merge-base HEAD main` IS HEAD, so the "baseline" worktree is the code under test and
      every failure baselines as pre-existing. That is the one classification error this whole
      triage exists to prevent, produced by the procedure meant to prevent it.
      Fallback when that is impractical — **fail-CLOSED, and weaker than it looks**: direct
      file intersection is NOT sufficient evidence of innocence. A shipped change to a shared
      util, a type, a fixture, a config or a mock breaks tests whose own file and whose direct
      production target both sit outside the range. So the fallback treats a failure as
      pre-existing ONLY when all three hold: (1) neither the failing test file nor its
      production target is in the ship range, (2) nothing the failing test transitively imports
      is in the range (`impact_analysis` / `find_references` on the changed symbols, or a
      dependency-graph grep), and (3) the failure mode is unrelated to what shipped (a network
      timeout, a stale snapshot of untouched markup). **Ambiguity resolves to class (b) NEW,
      never to pre-existing** — misclassifying a regression as inherited debt ships the
      regression under a WARN, which is the one outcome this triage exists to prevent. Record
      which of the three tests carried the decision: `[SHIP] fallback classification: <test> →
      pre-existing (no range intersection, no transitive import, unrelated failure mode)`.
   b. **NEW failure (green on base, red now)** — the ship's own regression. FIX it in-run:
      a production bug per the fix-in-run philosophy, or the test's contract update when the
      shipped change legitimately altered behavior. Re-run, continue. Only a new failure that
      cannot be fixed in-scope aborts — print `SHIP ABORTED: new regression <test> — <reason>`
      with the classification table. That abort is correct and stays.
   c. **PRE-EXISTING failure (red on base too)** — inherited debt, not this ship's regression:
      - **In-scope trivially fixable** (stale snapshot whose diff is verifiably benign — e.g. a
        dependency changed SVG/markup serialization and the diff touches NO shipped code;
        an assertion obsoleted by an already-landed change) → FIX NOW in a separate
        `test(ship): ...` commit, re-run, continue. Auto-updating a snapshot REQUIRES that
        attribution: inspect the snapshot diff and name the benign cause in the commit body;
        a snapshot diff implicating shipped code is class (b), never a blind `--update`.
      - **Not in-scope fixable** → do NOT hold the ship hostage to debt the base already has:
        print `[SHIP] pre-existing failures carried: <list>`, write them to `memory/backlog.md`,
        continue — and cap the run-line verdict at WARN.
   c2. **ENVIRONMENT failure — the suite did not produce a verdict at all.** Two shapes, both
      reported repeatedly on this fleet, and neither is a code failure:
      - **Killed by the OS** (exit 137/OOM, a runner reaped mid-run) with ZERO failing tests. There
        is nothing to triage — the suite did not finish. Re-run it with less concurrency (`rt`, or
        a lower worker cap) before classifying anything.
      - **Load-starvation flake**: a test that passes alone and fails only while other suites run
        on the same box. The (a) fallback classifier CANNOT see this — file intersection and
        transitive imports both say "not in range" while the failure is real-but-not-yours. The
        discriminator is a solo re-run of the failing file, not more static analysis.
      Record it as `TEST TRIAGE: ... ENV-RERUN [n5]` and re-run before deciding. Never fold an
      environment failure into PRE-CARRIED — that ships a WARN describing a defect that does not
      exist, and hides one that might.

      **Cap the re-runs at 2.** ENV-RERUN is a transient state, not a loop: if the third attempt
      still produces no verdict, the environment — not this change — is what is broken. Stop with
      `SHIP INCOMPLETE: suite produced no verdict in 3 attempts (<last symptom>)` and say what to
      fix (host load, missing toolchain, an evicted runner). A run that keeps re-running a suite
      that cannot finish burns the session and ships nothing, which is strictly worse than saying
      so on attempt three.

   d. **Never end the turn asking "may I push despite red tests?"** for a fixable failure —
      fix it and re-run. The only question ship may ask is a genuine behavior/product decision
      surfaced by a class-(b) fix (interactive only; batch picks the safe default and logs it).

   Print the triage table before proceeding. The counters are OUTCOMES — deliberately not
   labelled a-d, because those letters already name the procedure steps above and reusing them
   made the table unreadable (fixed 2026-08-01):
   ```
   TEST TRIAGE: [N] failing → NEW-FIXED [n1], NEW-ABORT [n2], PRE-FIXED [n3], PRE-CARRIED [n4], ENV-RERUN [n5]
     (NEW-* from step b, PRE-* from step c, ENV-RERUN from step c2; n1+n2+n3+n4+n5 MUST equal N)
   ```
   A count that does not add up to N means some failure was never classified — classify it
   before proceeding, do not print a partial table. `ENV-RERUN` is a transient state: the table is
   printed again after the re-run, with those failures landing in a real class.

---

## Phase 2: Review Scaling

**0. Secret scan — unconditional, BEFORE the threshold branch.** The frontmatter calls
`scan_secrets` "the last-line check before push"; it belongs on every path, including the <20 LOC
fast path that skips review entirely (a one-line commit is exactly how a credential ships).
Run `scan_secrets` over the release range; any high-confidence hit BLOCKS the ship until removed
AND rotated — a leaked secret is not a WARN.

**A scan that ERRORED is not a scan that found nothing.** Check the exit status, not the output: a
tool that dies on its own limits (`ugrep: error ... exceeds complexity limits`, a regex engine
bailing, a missing binary) prints nothing, which reads exactly like a clean result. Non-zero exit
with no findings = the scan did not run — fall back to another scanner or `git diff | grep` for the
high-signal patterns, and record which one produced the verdict. Never carry an errored scan as a
pass.

1. **Compute diff LOC over `${BASE_REF}..HEAD`** — the base Phase 0 step 3 already resolved for
   this flow (and re-resolved if step 4(b) merged the moved base in). Do NOT resolve it again here:
   a second resolution is a second chance to disagree with the range Phase 1 baselined against.
   ```bash
   [ -n "$BASE_REF" ] || { echo "[SHIP] BASE_REF unset — Phase 0 step 3 did not run"; exit 1; }
   # No pipe around git: `git diff --stat ... | tail -1` makes `$?` tail's, so an unresolvable base
   # reads as "0 changed lines" — the fast path, review skipped. Same rule as Phase 1 step 2.
   DIFF_STAT=$(git diff --stat "$DIFF_BASE" HEAD) || { echo "[SHIP] git diff failed against $DIFF_BASE"; exit 1; }
   printf '%s\n' "$DIFF_STAT" | tail -1          # two-arg form: works for a commit AND the empty tree
   ```
   Extract the total insertions + deletions number as `DIFF_LOC`. Re-print the base with the
   measurement so the threshold decision carries its own scope:
   `[SHIP] DIFF_LOC=<N> over <sha7>..HEAD (<pr: merge-base with $PUSH_REMOTE/$TARGET_BRANCH | release: tag <name> | first release: root>)`.
   Never `HEAD~N` — it is fragile with merge commits and non-linear history.

   **Diff scope is the whole range, whichever base applies.** On release flow `DIFF_LOC` includes
   ALL changes since the last release tag — not just "your feature". If the diff is 4000 LOC
   because 3000 LOC of other work landed too, the review covers all 4000. Do not rationalize a
   smaller scope by counting only "feature commits." The PR-flow base above is NOT such a
   rationalization: `merge-base..HEAD` is the complete set of commits this push adds, which is the
   whole point — it excludes only work that is already on the target branch and was reviewed there.

   **If the honest range is genuinely enormous** (first release, or a long-lived branch), the
   sanctioned procedure is to review it in chunks — `adversarial-review` already splits oversized
   input at file boundaries automatically, and `zuvo:review` runs at TIER 3. Shrinking the range to
   fit is never the answer.

1b. **Coverage reuse — resolve WHAT still needs review, before deciding HOW DEEP.**

   The content-keyed artifacts a preceding `zuvo:refactor` / `zuvo:build` / `zuvo:execute` /
   `zuvo:review` wrote are evidence about **file CONTENT**, not about "a pipeline ran recently"
   (`../../shared/includes/review-artifact.md`). When a file's CURRENT blob is the exact blob some
   proven artifact reviewed, reviewing it again runs the same reviewers over the same bytes and
   returns the same findings. That duplication is the entire cost of the ship-straight-after-refactor
   path, and it is not small: one 2026-08-16 session ran refactor (blind audit + 3 adversarial
   passes), a nested `test-audit`, then ship's own TIER 2 `zuvo:review` + `--multi` adversarial over
   the same files — four full pipelines, one set of changes.

   ```bash
   # install.sh installs the lib GLOBALLY, so this resolves in the repo you are shipping — not
   # only inside zuvo-plugin. The repo-relative path is the dev fallback, never the only one.
   PG_LIB="$HOME/.claude/hooks/lib/pipeline-gate-lib.sh"
   [ -f "$PG_LIB" ] || PG_LIB="$(git rev-parse --show-toplevel)/hooks/lib/pipeline-gate-lib.sh"
   UNCOVERED=""; UNC_RC=2
   if [ -f "$PG_LIB" ]; then
     # shellcheck source=/dev/null
     . "$PG_LIB"
     UNCOVERED=$(pg_uncovered_files "$DIFF_BASE..HEAD"); UNC_RC=$?
   fi
   echo "[SHIP] coverage: rc=$UNC_RC uncovered=$(printf '%s' "$UNCOVERED" | grep -c .)"
   ```

   **Read the CODE, never the emptiness.** `pg_uncovered_files` prints nothing in three different
   states and exactly one of them means "already reviewed":

   | `UNC_RC` | Meaning | Ship does |
   |----------|---------|-----------|
   | `0`, empty stdout | every production file's current blob is already reviewed | **reuse** — depth `reused` (step 2) |
   | `0`, non-empty | those files are unreviewed | review **scoped to them** — depth `partial:<n>-files` |
   | `2` | could NOT compute (lib absent, unresolvable range, no repo) | **full depth over the whole range** |
   | `3` | the range changed no production files | **full depth over the whole range** — unchanged behaviour, so a docs-only release still gets its LOC-band review |

   Reading `rc=2` as "nothing uncovered" converts a missing library into a skipped review. The
   emptiness looks identical; only the code separates them. If those two states ever merge in your
   reasoning, that is the bug this table exists to prevent.

   **A worktree's missing artifact is not yet a missing review.** The artifact and its proof are a
   PAIR — both per-checkout, both gitignored — so a refactor run in a worktree may have left its
   pair *there* rather than here. That is precisely the ship-after-refactor case this step serves,
   so falling straight through to a full review would defeat it. Try to pull the pairs in, then
   re-compute ONCE:

   ```bash
   if [ "$UNC_RC" -eq 0 ] && [ -n "$UNCOVERED" ]; then
     SELF=$(git rev-parse --show-toplevel)
     # Every OTHER checkout of this repo: the main checkout plus every linked worktree.
     git worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r wt; do
       [ "$wt" = "$SELF" ] && continue
       ~/.zuvo/review-artifact-sync.sh --from "$wt" --to "$SELF" 2>/dev/null || true
     done
     UNCOVERED=$(pg_uncovered_files "$DIFF_BASE..HEAD"); UNC_RC=$?
     echo "[SHIP] coverage after pair-sync: rc=$UNC_RC uncovered=$(printf '%s' "$UNCOVERED" | grep -c .)"
   fi
   ```

   Re-compute exactly **once**. A sync that moved nothing moves nothing on a second pass either;
   looping here iterates over the filesystem, not over new evidence.

   **Print the evidence, or you did not reuse anything.** For every file you are about to NOT
   review, name the artifact that covers it — one line each,
   `[SHIP] review reused: <file> ← memory/reviews/<base7>..<head7>-<slug>.md`. If that list cannot
   be produced, the reuse is unauditable and you fall back to full depth. An unprintable
   justification is the same thing as no justification.

   **Pin the HEAD you measured, and re-derive if it moves.** The list is a statement about the
   blobs at one commit; the reviewers run later. On a branch another agent is also committing to
   (this project's normal case), a commit landing in between makes the scoped list describe content
   that is no longer what will be pushed — and the file it silently drops is, by construction, the
   one that just changed.

   ```bash
   COV_HEAD=$(git rev-parse HEAD)      # record it here; compare before every dispatch below
   ```

   Before dispatching reviewers (step 3) and again before the push-gate preflight, check
   `git rev-parse HEAD` against `$COV_HEAD`. Different → re-run step 1b and rebuild the scope from
   the new HEAD. Same → proceed. This is the concurrent-commit twin of the ship-edits-its-own-files
   rule in step 4.5: both are the same defect, one caused by another agent and one by this run.

2. **Apply review threshold (MANDATORY).** These thresholds are non-negotiable (see Safety Rule 5). The only override is `--full` — escalation UP:

   **The band is measured over the UNCOVERED subset, not over the whole range.** `DIFF_LOC` stays
   printed as the integration scope — it is what the release actually carries — but the review's
   size is the size of the work that has no review yet. The two are different numbers and both
   belong in the output:

   ```bash
   # EACH BASH CALL IS A FRESH SHELL — the same rule Phase 1 step 2 calls out. `$PG_LIB`,
   # `$UNCOVERED` and `$UNC_RC` do NOT survive from step 1b unless this runs in the SAME
   # invocation. Re-derive them if they are gone: an UNSET UNC_RC must never be read as 0,
   # which is `[ "${UNC_RC:-}" -eq 0 ]` silently succeeding on an empty string in some shells
   # and, worse, the reuse row being taken because a variable evaporated.
   if [ -z "${UNC_RC:-}" ]; then
     PG_LIB="$HOME/.claude/hooks/lib/pipeline-gate-lib.sh"
     [ -f "$PG_LIB" ] || PG_LIB="$(git rev-parse --show-toplevel)/hooks/lib/pipeline-gate-lib.sh"
     UNCOVERED=""; UNC_RC=2
     # shellcheck source=/dev/null
     [ -f "$PG_LIB" ] && { . "$PG_LIB"; UNCOVERED=$(pg_uncovered_files "$DIFF_BASE..HEAD"); UNC_RC=$?; }
   fi

   if [ "$UNC_RC" -eq 0 ] && [ -n "$UNCOVERED" ]; then
     # `git diff` has NO --pathspec-from-file — that flag belongs to add/commit/checkout/rm;
     # git diff answers with its usage block and exit 129, which a pipe would then swallow.
     # Re-expand the newline-separated list into POSITIONAL PARAMETERS inside a subshell:
     # portable to bash and zsh alike, and space-safe, which an unquoted `$(cat …)` is not.
     REVIEW_LOC=$(
       set --
       while IFS= read -r p; do [ -n "$p" ] && set -- "$@" "$p"; done <<LIST
$UNCOVERED
LIST
       [ "$#" -eq 0 ] && { echo 0; exit 0; }
       git diff --numstat "$DIFF_BASE" HEAD -- "$@" | awk '{a+=$1; d+=$2} END {print a+d+0}'
     )
     REVIEW_SCOPE="$UNCOVERED"       # newline-separated; re-expand the same way wherever used
   elif [ "$UNC_RC" -eq 0 ]; then
     REVIEW_LOC=0; REVIEW_SCOPE=""   # fully covered → the `reused` row below
   else
     REVIEW_LOC="$DIFF_LOC"; REVIEW_SCOPE=""   # rc 2/3 → whole range, unchanged behaviour
   fi
   echo "[SHIP] REVIEW_LOC=$REVIEW_LOC (band input) DIFF_LOC=$DIFF_LOC (integration scope) UNC_RC=$UNC_RC"
   ```

   | Review LOC | Review actions |
   |----------|----------------|
   | **`reused`** (`UNC_RC=0`, nothing uncovered) | **Skip** `review-light`, `zuvo:review`, the cross-provider adversarial pass (step 4) and `coverage-check` — the per-file artifact evidence from step 1b is printed instead. Everything else in Phase 2 still runs: the step-0 secret scan is unconditional and NEVER reused. |
   | < 20 | **Fast path** — skip review entirely |
   | 20 - 100 | Dispatch `review-light` agent (read `skills/ship/agents/review-light.md`) |
   | 100+ | Dispatch `review-light` + invoke `zuvo:review` via the Skill tool (`Skill(skill="zuvo:review", args="${BASE_REF}..HEAD --report-only")`) — runs adversarial pass at TIER 2+ + invoke `Skill(skill="zuvo:design-review")` if frontend files changed (`.tsx`, `.jsx`, `.css`, `.scss`, `.html`) |
   | 300+ | All of the above + dispatch `coverage-check` agent (read `skills/ship/agents/coverage-check.md`). `Skill(skill="zuvo:review", args="${BASE_REF}..HEAD --report-only")` runs at TIER 3 with automatic adversarial pass. |

   **First release only:** `${BASE_REF}..HEAD` excludes everything the root commit introduced, and
   a range argument cannot express "the whole tree". Scope the review by FILES instead
   (`zuvo:review <paths> --report-only`, or the full production file list), and say so in SHIP
   COMPLETE. `DIFF_LOC` already measures the real size via `DIFF_BASE`, so the threshold band is
   right; it is only the review's own scope argument that needs the different form.

   **ALWAYS pass the RANGE `${BASE_REF}..HEAD`, never bare `--report-only`.** Ship runs AFTER the work is committed, so an argument-less `zuvo:review` scopes to *uncommitted* changes — empty at this point — and the "mandatory" review passes on nothing. Use the same range Phase 2 measured `DIFF_LOC` over.

   **When `REVIEW_SCOPE` is set (partial coverage), scope the review to those FILES.** Every
   dispatch in this phase — `review-light`, `zuvo:review`, the adversarial diff, `coverage-check` —
   takes the uncovered file list instead of the whole range: `Skill(skill="zuvo:review",
   args="<uncovered files, space-separated> --report-only")`, and `git diff "$DIFF_BASE" HEAD --
   <those paths>` wherever the range diff was fed in. The range is still
   what `DIFF_LOC` reports and what the release carries; it is only the reviewers' input that
   narrows, and it narrows to exactly the content no artifact has seen. Record it:
   `[SHIP] review scoped to <n> uncovered file(s) of <m> production files in range`.

   **Scoping is derived, never chosen.** The file list comes from `pg_uncovered_files` reading
   blobs on disk — it is not a judgement about which files "probably need" review, and it may not
   be narrowed further by any reasoning about the diff. If you find yourself removing a file from
   `$UNCOVERED` because it looks trivial, that is the downgrade the attestation below forbids,
   wearing a new hat.

   **There is no zero-visual-delta exemption from `zuvo:design-review`.** A frontend file in the
   diff dispatches it, full stop — even when you can show the rendered class strings are identical
   before and after. That demonstration is the agent's own reasoning about its own change, which is
   precisely what the gate exists to distrust, and "provably no visual change" is one rephrasing
   away from "this refactor is obviously safe". If the run genuinely has no visual delta,
   design-review costs one dispatch and says so; that is the price of the mandate being
   unconditional. (Raised as friction 2026-08-07 — the answer is the rule, not an escape hatch.)

   **Pass `--report-only` when invoking `zuvo:review` from ship** — a pre-merge release review must SURFACE blockers for the release decision, not silently auto-rewrite the diff you are about to tag. (Direct `/zuvo:review` defaults to auto-fix; ship-dispatched does not.)

   **Flag override (user-provided ONLY — agent must NEVER self-apply):**
   - `--full`: always use 300+ path (all reviews + coverage check) regardless of diff size.
   - There is NO downgrade flag. A review skip cannot be expressed as an argument to this skill.

   **Invocation form is non-negotiable.** When the threshold says "invoke `zuvo:review`", you MUST
   actually run it. Reading the review skill, simulating it mentally, summarizing findings from
   prior commits, or asserting that `zuvo:execute` / per-task review "covered it" does NOT count.

   **What "actually run it" means per harness** — the mandate is the RUN, not one tool's name.
   Claude Code has a `Skill` tool and MUST use it: `Skill(skill="zuvo:review", args="${BASE_REF}..HEAD --report-only")`.
   Codex, Cursor and Antigravity have no such tool; there the equivalent is the dispatch pattern in
   `../../shared/includes/env-compat.md` — load the review skill's own instructions and execute its
   phases in a dedicated sub-agent/thread, with its gates intact. Record which transport ran:
   `[SHIP] review transport: Skill tool | env-compat dispatch (<harness>)`. Stating a literal
   `Skill()` call is the "only acceptable evidence" made the gate unsatisfiable on three of four
   platforms, and an unsatisfiable gate gets skipped, not met — that is how it started reading as
   optional. What remains forbidden is unchanged: no inline self-review standing in for the run.

   **MANDATORY: Phase 2 Anti-Rationalization Attestation.** Before proceeding to step 3, print this block verbatim with your honest answers. If ANY box is left unchecked because the statement is true (i.e., you HAD that thought), you MUST escalate review depth to `full+coverage` regardless of the LOC table — and record the escalation reason in the SHIP COMPLETE block.

   ```
   PHASE 2 ATTESTATION (DIFF_LOC=<N>, threshold-required depth=<depth>)
   I confirm I am NOT rationalizing a downgrade with any of the following:
   [ ] "redundant because each task / tier / commit was already reviewed during creation"
   [ ] "zuvo:execute / zuvo:plan / zuvo:build already covered this — running review again is duplicate work"
   [ ] "most of this diff is boilerplate / merge artifacts / generated code / formatting"
   [ ] "the integration is trivial — only conflicts were in template literals / imports / config"
   [ ] "running a full review feels excessive for this release"
   [ ] "I can mentally substitute review by re-reading the diff myself"
   DIFF_LOC scope confirmation:
   [ ] DIFF_LOC counts ALL commits since the last tag (integration scope), not just "my feature"
   Coverage-reuse confirmation (step 1b):
   [ ] Every file I am NOT reviewing was reported covered by `pg_uncovered_files` reading blobs on
       disk — not because I remember, believe, or was told that refactor/build/execute covered it
   Decision:
   - All boxes checked → proceed at threshold-required depth.
   - ANY unchecked → escalate to full+coverage; reason: <which thought you had>.
   ```

   The forbidden thoughts above are the EXACT rationalizations that have caused past ship runs to skip review on integrated multi-tier diffs. They are listed so you can recognize them, not so you can pattern-match around them. If your reasoning resembles ANY of these — even with different wording — treat the corresponding box as unchecked.

   **The second and third boxes are not in tension — one is about memory, the other about
   measurement.** "zuvo:execute already covered this" stays forbidden as an *assertion*: it is the
   agent vouching for its own prior work, which is what the attestation exists to distrust. Step 1b
   is the same claim made *checkable* — a blob comparison the run did not perform and cannot argue
   with. So the rule is about the evidence, never the conclusion: a covered file is one
   `pg_uncovered_files` did not print, and nothing else qualifies.

   **This is deliberately not a flag.** There is no argument to `zuvo:ship` that expresses reuse,
   and none may be added: an escape an agent can type is an escape an agent will type. The decision
   is derived from files on disk, so the only way to obtain it is to actually have the reviewed
   content — which is the point.

3. **Agent dispatch — review-light:** (skipped on the `reused` row; scoped by `$REVIEW_SCOPE` on `partial`)
   - Read `skills/ship/agents/review-light.md` for the agent's instructions.
   - Provide **`git diff "$DIFF_BASE" HEAD`** as input — byte-for-byte the diff step 1 measured.
     On `partial`, add `--pathspec-from-file="$REVIEW_SCOPE"` so the agent sees exactly the
     unreviewed files; state in the prompt which files were carried on prior artifacts and why,
     so it does not report the covered ones as "missing from the diff".
     Not `git diff --cached` (empty here: ship runs after the work is committed), not `HEAD~1` (one
     commit of a range that is usually many), and not `${BASE_REF}..HEAD` (identical to `$DIFF_BASE`
     except on a FIRST RELEASE, where it silently drops the root commit's entire contents — the
     agent would then bless a codebase it never saw while the LOC table said 300+). Any of the
     three hands the agent less than the release and gets back a confident "no ship-blockers",
     which travels into SHIP COMPLETE as a review that happened.
   - State the resolved base and head SHAs in the dispatch prompt. The agent verifies an empty
     diff itself and BLOCKS on an unresolved range (see `agents/review-light.md`), which it can
     only do if you tell it what the range was.
   - If the agent returns verdict `BLOCK`: **FIX the blockers in this run**, then re-run it. A
     ship-blocker is a security hole, a data-corruption path or a crash — the fix is the work, and
     handing it back as a question is the deferral pattern this project has rejected repeatedly.
     Commit the fixes as their own `fix(ship): ...` commit, ahead of the release commit. Only two
     outcomes escalate: a genuine product/behavior decision (interactive: ask; batch: safe default
     + `[AUTO-DECISION]`), and a blocker that genuinely cannot be fixed inside this scope — that
     one prints `SHIP INCOMPLETE: <blocker>` and stops. "Pause and ask the user to override" is
     neither, and it contradicts `no-pause-protocol.md`, which this skill loads as HARD.

4. **Cross-provider review** (100+ LOC, after zuvo:review completes):

   **Skipped entirely on the `reused` row** — the artifacts that granted coverage each cite their
   own adversarial proof (`pg_artifact_proven` requires it), so the cross-model pass already ran
   over these exact blobs. On `partial`, it runs over the uncovered files only. On `UNC_RC` 2 or 3
   it runs over the whole range as before.

   After `zuvo:review` returns its verdict, run a cross-provider adversarial review. Read `../../shared/includes/cross-provider-review.md` for the protocol.

   ```bash
   # ~/.zuvo/ is the version-INDEPENDENT path install.sh writes. The previous form
   # (`SCRIPT_PATH="${PLUGIN_ROOT}/scripts/adversarial-review.sh"` guarded by `[[ -x $SCRIPT_PATH ]]`)
   # could never run: no harness sets a bare PLUGIN_ROOT (they set CLAUDE_PLUGIN_ROOT /
   # CURSOR_PLUGIN_ROOT), so the path was "/scripts/adversarial-review.sh", the guard was false,
   # and the step fell straight through to "No external provider available" — a mandatory gate
   # that self-skipped on every platform, every run, with a line that reads like a provider fault.
   AR="$HOME/.zuvo/adversarial-review"
   # Key the proof on the RESOLVED SHAs, not on the literal string "${BASE_REF}..HEAD" — that text
   # is identical across runs and across content, so a rerun that failed or was skipped would leave
   # the PREVIOUS proof sitting at the same path, and the push gate would accept it for blobs it
   # never saw. Resolved SHAs also need no `shasum` (absent on minimal Linux images, and its exit
   # status is swallowed by the pipe — the exact failure class this file warns about elsewhere).
   BASE7=$(git rev-parse --short "$BASE_REF"); HEAD7=$(git rev-parse --short HEAD)
   ADV_PROOF="zuvo/proofs/ship-${BASE7}..${HEAD7}-adversarial.txt"
   mkdir -p zuvo/proofs

   # Never pipe `git diff` straight into the reviewer: a failed diff (bad base, corrupt index)
   # exits non-zero while the PIPELINE's status is the reviewer's, so an empty input comes back as
   # a clean review. Materialize it, check it, then feed it. mktemp, not a fixed /tmp name —
   # concurrent ship runs on one host clobber each other, and a pre-created symlink at a
   # predictable path redirects the write.
   DIFF_FILE=$(mktemp -t ship-diff.XXXXXX); ADV_OUT=$(mktemp -t ship-cross-review.XXXXXX)
   # On `partial`, review the uncovered files only — the rest already carry their own proof.
   # Same positional-parameter expansion as step 2 (git diff has no --pathspec-from-file), in a
   # subshell so the subshell's status IS git's and the `if !` below still sees a failed diff.
   if ! (
        set --
        while IFS= read -r p; do [ -n "$p" ] && set -- "$@" "$p"; done <<LIST
${REVIEW_SCOPE:-}
LIST
        if [ "$#" -eq 0 ]; then git diff "$DIFF_BASE" HEAD
        else git diff "$DIFF_BASE" HEAD -- "$@"; fi
      ) > "$DIFF_FILE"; then
     echo "[CROSS-REVIEW] git diff failed — cross-provider review NOT run"; AR_RC=1
   elif [ ! -s "$DIFF_FILE" ]; then
     # Empty diff = no review happened and NO proof file exists. Record it as such; rc=0 here means
     # "correctly nothing to do", never "reviewed and clean". If the range is genuinely empty there
     # is also nothing to push, so a run that continues on this branch is a run with a range bug.
     echo "[CROSS-REVIEW] empty diff for $BASE7..$HEAD7 — NOT RUN (no proof written)"; AR_RC=0; CROSS_STATE=not_run:empty-diff
   elif [ -x "$AR" ]; then
     "$AR" --mode code --artifact "$ADV_PROOF" < "$DIFF_FILE" > "$ADV_OUT"
     AR_RC=$?
   else
     AR_RC=127
   fi
   echo "[CROSS-REVIEW] AR_RC=$AR_RC proof=$ADV_PROOF out=$ADV_OUT"   # print it — the branch below is a different shell
   ```

   **Write the proof with `--artifact`, not a stdout redirect.** The canonical `REVIEW BY:` markers
   are emitted only into the artifact file; `> /tmp/ship-cross-review.md` captured the human-readable
   summary and nothing the push gate can read, so the most expensive step in Phase 2 produced no
   proof-of-work at all. `zuvo/proofs/` is also where `zuvo:review`'s artifact expects to find it.

   **Branch on `AR_RC`, and never read an empty file as a clean result:**
   - `0` — findings parsed normally (see severities below).
   - `3` — `single_provider_only`: honest degraded. Record it; do not treat it as clean.
   - `1`/`2`/`124`/`127` — the pass did NOT happen (no provider, all failed, timeout, helper
     missing). Print `[CROSS-REVIEW] pass did not run (rc=$AR_RC)` and record it as NOT RUN in the
     SHIP COMPLETE block. An empty or 0-byte output is the same case: zero CRITICALs found by a
     reviewer that never ran is not zero CRITICALs.
   - CRITICAL findings → fix them in-run (same rule as step 3), then re-run this pass so the proof
     covers the fixed blobs. WARNING/INFO → carry as informational; they do not block.

4.5 **Disposition every finding — `--report-only` means "do not auto-rewrite", not "do not fix".**
   The threshold table dispatches `zuvo:review --report-only` so the review surfaces blockers for
   the release decision instead of silently rewriting the diff you are about to tag. What it never
   said is what happens next, and a finding nobody dispositions is a finding nobody acted on:
   - **MUST-FIX** → fix it in this run, as a separate commit ahead of the release commit, then
     re-run the adversarial pass (step 4) so the proof covers the fixed blobs. Content-keyed
     coverage is per-blob: a fix after the pass leaves the pushed content unreviewed.
   - **RECOMMENDED** → fix if it is inside this release's fence; otherwise record it in
     `memory/backlog.md` with the finding text, and say which you did.
   - **NIT** → backlog or ignore, silently is fine.
   - **Cross-chunk artifacts** (a finding about a symbol whose definition sat in another chunk of a
     split diff) → discount by construction, and say so; do not "fix" a diff to satisfy a reviewer
     that saw half of it.
   Print `[SHIP] findings dispositioned: <n> MUST-FIX fixed, <n> RECOMMENDED fixed, <n> backlogged`.
   Zero findings is a legitimate line — an ABSENT line is not.

   **Re-measure `DIFF_LOC` after fixing.** The fixes are new commits in the same range, so a run
   that entered at 280 LOC can leave at 340 — past the 300+ band, where `coverage-check` and TIER 3
   are mandatory. Re-run the step-1 measurement; if the band moved UP, run the extra depth. (It can
   only move up: fixes add commits. A band that moved down is a measurement error, not a licence to
   review less.)

   **Re-compute `UNCOVERED` too — ship invalidates its OWN coverage.** Coverage is keyed on file
   CONTENT, so every fix applied in step 3 or 4.5 changed that file's blob and dropped whatever
   artifact used to cover it. This is the same mechanism as cause #2 in the push-gate diagnosis
   below, arriving one phase earlier. (Phase 1 triage fixes need no special handling — they land
   before step 1b measures, so the first computation already sees them. It is only the fixes made
   *after* 1b that go stale.) Re-run `pg_uncovered_files` before concluding anything about depth:

   ```bash
   # Fresh shell again — re-source before calling, exactly as step 2 does.
   PG_LIB="$HOME/.claude/hooks/lib/pipeline-gate-lib.sh"
   [ -f "$PG_LIB" ] || PG_LIB="$(git rev-parse --show-toplevel)/hooks/lib/pipeline-gate-lib.sh"
   UNCOVERED=""; UNC_RC=2
   # shellcheck source=/dev/null
   [ -f "$PG_LIB" ] && { . "$PG_LIB"; UNCOVERED=$(pg_uncovered_files "$DIFF_BASE..HEAD"); UNC_RC=$?; }
   echo "[SHIP] coverage after fixes: rc=$UNC_RC uncovered=$(printf '%s' "$UNCOVERED" | grep -c .)"
   ```

   **A file ship itself edited can never be reported as `reused`.** If a run applied fixes and
   still lands on `reused`, the re-computation did not happen — go back and run it. Skipping the
   re-check is how a run reviews the code it received and ships the code it wrote.

5. **Agent dispatch — coverage-check** (300+ LOC or `--full` only; skipped on the `reused` row):
   - Read `skills/ship/agents/coverage-check.md` for the agent's instructions.
   - Provide the list of changed production files (exclude test files) — on `partial`, the
     uncovered subset only.
   - The coverage-check verdict is **informational only** — it never blocks ship.

6. **Record review depth** for the artifact:
   - `"none"` — fast path, no review performed
   - `"reused"` — every production file already covered by a proven artifact; no reviewer ran in
     this phase. MUST be accompanied by the per-file `[SHIP] review reused:` evidence lines from
     step 1b, and is invalid for any file this run edited (step 4.5).
   - `"partial:<n>-files"` — review ran, scoped to the `<n>` uncovered files. Append the depth the
     band actually selected, e.g. `partial:2-files/light`, `partial:6-files/full`.
   - `"light"` — review-light agent only
   - `"full"` — review-light + zuvo:review with adversarial pass (+ design-review if applicable)
   - `"full+coverage"` — full + coverage-check agent

---

## Phase 2.5: Knowledge Curation (Self-Reflect)

After all review phases complete and before committing the release, extract learnings from this release cycle.

Read `../../shared/includes/knowledge-curate.md` and run the protocol:

```
WORK_TYPE = "implementation"
CALLER = "zuvo:ship"
REFERENCE = <current git SHA before the release commit>
```

Reflect on the full diff (`git diff ${BASE_REF}..HEAD`) and any review findings from Phase 2. Ask:
- What patterns emerged across the changed files?
- Did any review finding reveal a recurring gotcha in this codebase?
- Was any architectural decision made during this release worth recording?

This step runs regardless of flags and diff size (fast path included). It does NOT block the release — even if zero insights are extracted, proceed to Phase 3.

---

## Phase 3: Version Bump

1. **Detect version file.** Check project root in this order:

   | File | Ecosystem | Version field |
   |------|-----------|---------------|
   | `package.json` | Node.js | `.version` |
   | `pyproject.toml` | Python | `[project].version` or `[tool.poetry].version` |
   | `Cargo.toml` | Rust | `[package].version` |
   | `go.mod` | Go | git tags only (no file bump) |
   | `composer.json` | PHP | `.version` |
   | `VERSION` | Generic | entire file content |
   | None found | — | Offer to create a `VERSION` file, or skip versioning with user consent (E5) |

   **A manifest with NO version field is the common case, not the "None found" row.** `package.json`
   with `"private": true` (every app in this fleet), a Composer app, a `pyproject.toml` using
   `dynamic = ["version"]`, and `go.mod` all ship without a version string in the file. Do not
   invent one, and do not fall through to "None found" — that row is for a repo with no manifest at
   all. Use **tag-only versioning**: the last release tag is the current version, the bump produces
   the next tag, and no file is staged. Print
   `[SHIP] tag-only versioning (<manifest> has no version field) — current v<X>, next v<Y>` and
   record `versionFile: null` in the artifact. A repo that has neither a version field nor any
   release tag is the genuine E5 case.

2. **Skip gate — THREE conditions, and only the first is a flag:**

   a. `--no-bump` was passed.

   b. **The flow is PR flow** (Phase 0 put you on a non-default branch). On a feature branch,
      **do not bump the version and do not touch `CHANGELOG.md` at all.** Print
      `[AUTO-DECISION] PR flow → version + changelog deferred to the release on <TARGET_BRANCH>`
      and go straight to Phase 4 with the version unchanged.

   c. **The repo's own release script owns the version — and then it owns the TAG and the PUSH
      too.** If the project documents a release path (`scripts/release.sh`, `npm version`, a CI
      release workflow, semantic-release) that produces the version itself, ship must not bump:
      a second bump either collides with the script's or ships a version the script never recorded
      in its own artifacts (marketplace SHA, lockfile, published package). Detect it from the
      repo's `CLAUDE.md`/README/`package.json` scripts.

      **Ownership is all-or-nothing.** Deferring only the bump leaves `NEW_VERSION` unset while
      Phase 4 Step 3 still tries to tag it — `git tag -a "v"` on a version nobody computed. So when
      this fires, set `VERSION_OWNER=<script>` and Phase 4 **skips Step 3 (tag) and the tag push**
      exactly as PR flow does; the release script creates the tag when it runs. Print
      `[SHIP] version+tag owned by <script> — ship stops at the commit; run <script> to release`,
      record `newTag: null` and `versionOwner: "<script>"` in the artifact, and say so in SHIP
      COMPLETE. Ship does not invoke the script itself: those wrappers bundle remote effects
      (tags, marketplace/registry pushes) that are a separate, human-authorized decision.

   **Why this is a correctness rule, not a convenience.** The version belongs to the RELEASE, not
   to the pull request. `VERSION` is a single line and a `CHANGELOG.md` entry is always prepended
   at the top, so two open PRs edit the same line of both files and conflict by construction —
   every PR against every other PR, guaranteed. Worse than the conflict: both branches bump
   `1.6.55 → 1.6.56`, so whichever merges SECOND declares a version number that is already taken.
   That ships a wrong version, and no merge resolution catches it because both sides look correct
   in isolation.

   This matches what the repo has always actually done: every version bump in this project's
   history is a plain single-parent commit on the default branch (`release: v1.6.50` … `v1.6.56`),
   made by `scripts/release.sh` → `dev-push.sh` AFTER the merge. Not one arrived through a PR.
   Ship on a feature branch produces the change; ship (or `release.sh`) on the default branch
   produces the version.

   **This is the routing rule `documentation-mandate.md` points at.** That include sets a
   minimum floor of "every change gets a CHANGELOG entry"; on a feature branch the entry is still
   mandatory, it just goes somewhere that cannot collide. Deferring the note entirely satisfies
   neither document.

   **If a PR must carry its own release note**, add a NEW file — `changelog.d/<branch-slug>.md`
   — rather than editing `CHANGELOG.md`. Distinct new files never conflict, and the release step
   concatenates them into the changelog section and deletes them. Do NOT reach for
   `CHANGELOG.md merge=union` in `.gitattributes` as a shortcut: it papers over the changelog
   collision while doing nothing about `VERSION`, where a union merge yields a two-line version
   file — a broken release instead of a visible conflict.

3. **Detect conventional commits.** Scan all commits in the release range for prefixes:
   - `BREAKING CHANGE:` or `!:` suffix → major
   - `feat:` → minor
   - `fix:` → patch

   The result is `BUMP_TYPE`; applying it to the current version gives **`CANDIDATE_VERSION`** (what
   step 4 preflights against the tag namespace) which, once the preflight clears it, becomes
   **`NEW_VERSION`** (what Phase 4 commits and tags). Two names, because a candidate that collides
   is recomputed and must never leak into the tag.

   Decision logic:
   - If the user provided an explicit `patch`, `minor`, or `major` argument: use that. Skip detection.
   - If >= 50% of commits follow conventional commit format: auto-compute bump type from the highest-impact prefix (BREAKING > feat > fix).
   - If < 50% follow convention (E4): list the raw commit messages. Ask the user for bump type (`patch`, `minor`, or `major`). In non-interactive environments (Codex, Cursor): default to `patch` with `[AUTO-DECISION]` annotation.

   **Recognize the case where bumping MISREPRESENTS the release.** If `CHANGELOG.md` carries an
   `## Unreleased` section holding many entries that have never shipped, cutting a patch version
   for the one change in front of you publishes all of them under a version whose notes describe
   only your change. That is a documentation defect, not a version-number question. Say so, and
   either (a) generate the section from the FULL unreleased range rather than from this run's
   commits, or (b) `--no-bump` and leave the release to a deliberate one. Do not silently pick.

4. **Apply the bump — after a tag-collision preflight.** The candidate version comes from a FILE;
   whether it is free is a fact about the TAG NAMESPACE, local and remote. Nothing checked that,
   and the two failure modes both land at the very last step of a run that has already paid for
   tests, review and a release commit:
   - a concurrent worktree/session already published `v<candidate>` → `git push --tags` is rejected,
     or worse the local tag silently disagrees with the remote one of the same name;
   - the version file drifted BEHIND the tags (a release whose file edit was reverted, or a
     tag-only repo) → the "bump" produces a version that shipped weeks ago.

   ```bash
   # Both tag styles, matching Phase 0's base resolution: a repo on bare `1.2.3` tags would
   # otherwise report NEWEST_TAG="" and never detect the file-behind-tags case.
   NEWEST_TAG=$(git tag --list 'v[0-9]*' '[0-9]*.[0-9]*' --sort=-v:refname | head -1)
   # Follow the repo's own convention instead of forcing `v`: on a bare-semver repo, checking and
   # creating `v1.2.4` probes a namespace nobody uses — the collision check always passes and the
   # tag lands in a second, parallel scheme.
   case "$NEWEST_TAG" in v*) TAG_PREFIX=v ;; *) TAG_PREFIX="${NEWEST_TAG:+}" ;; esac
   NEXT="${TAG_PREFIX}${CANDIDATE_VERSION}"

   COLLIDES=false
   git rev-parse -q --verify "refs/tags/$NEXT" >/dev/null 2>&1 && COLLIDES=true

   if git fetch --quiet --tags "$PUSH_REMOTE"; then
     if [ "$COLLIDES" != true ]; then            # a KNOWN local collision is never downgraded
       git ls-remote --tags --exit-code "$PUSH_REMOTE" -- "$NEXT" >/dev/null 2>&1; _rc=$?
       case $_rc in
         0) COLLIDES=true ;;                     # exists remotely
         2) : ;;                                 # --exit-code: genuinely absent
         *) echo "[SHIP] ls-remote error (rc=$_rc) — cannot prove $NEXT is free"; COLLIDES=unknown ;;
       esac                                      # 128 = network/auth: NOT "free"
     fi
   else
     # A failed fetch means the remote half never ran. Leaving COLLIDES=false here would turn an
     # infrastructure failure into "the version is available" — fail closed.
     [ "$COLLIDES" = true ] || COLLIDES=unknown
     echo "[SHIP] tag fetch FAILED — remote collision check did not run"
   fi
   echo "[SHIP] tag preflight: NEXT=$NEXT COLLIDES=$COLLIDES NEWEST_TAG=$NEWEST_TAG"
   ```
   **Act on the result — the echo is not the fix.** `COLLIDES=true` → recompute `CANDIDATE_VERSION`
   from `max(version file, NEWEST_TAG)` and run this preflight again (loop until it is false).
   `COLLIDES=unknown` (the remote could not be reached) → do not gamble the last step of the run on
   it: stop with `SHIP INCOMPLETE: cannot verify tag $NEXT is free (<error>)`, or continue only with
   `--no-tag`. Proceed to the bump only on `COLLIDES=false`.
   - **Collision → recompute** the candidate from `max(version file, newest release tag)` and
     preflight again. Never `git tag -f`, never delete a published tag: both rewrite what other
     checkouts already fetched.
   - **File behind the tags** (`NEWEST_TAG` > version file) → bump from the TAG and correct the
     file to match in the same release commit. Say so:
     `[SHIP] version file <X> is behind tag <Y> — bumping from the tag`.

   Once `COLLIDES=false`: set `NEW_VERSION="$CANDIDATE_VERSION"`, then write it back to the
   detected version file (tag-only repos skip the write — see step 1). Phase 4 tags `NEW_VERSION`,
   so a version that never cleared the preflight is a version that can never be tagged.

5. **Generate or update CHANGELOG.md:**
   - If `CHANGELOG.md` exists: prepend a new section at the top (below the header).
   - If `CHANGELOG.md` does not exist (E6): create it from scratch with the Keep-a-Changelog header:
     ```markdown
     # Changelog

     All notable changes to this project will be documented in this file.

     The format is based on [Keep a Changelog](https://keepachangelog.com/).
     ```
   - New section format:
     ```markdown
     ## [<version>] — YYYY-MM-DD

     ### Added
     - ...

     ### Changed
     - ...

     ### Fixed
     - ...
     ```
   - Group commit messages under the appropriate heading (Added for `feat:`, Fixed for `fix:`, Changed for everything else). If commits are not conventional, list all under Changed.

6. **Documentation sync (per `documentation-mandate.md`).** The CHANGELOG above is the
   release-level doc; it does NOT cover feature/API/README docs. If the diff in this release
   changed a public API, a user-facing feature, env/config, or a runbook-relevant behavior and
   the matching docs were NOT updated upstream (in the execute/build that produced the code),
   dispatch `Skill(skill="zuvo:release-docs")` (diff-driven — updates only docs whose source
   changed). If all feature/API docs are already current, record `[DOC: changelog-only — feature
   docs current]` in the SHIP COMPLETE block. A release that ships a new public surface with stale
   docs is a defect.

---

## Phase 4: Stage, Commit, Tag, Push, Artifact

> **The push WILL hit the pipeline-entry pre-push gate.** `hooks/pre-push-gate.sh` runs on every
> agent push and BLOCKS a range that changes >=3 production files or >=150 lines without a
> content-keyed review artifact covering the CURRENT blob of each file. Ship does not write that
> artifact — only `zuvo:review`/`zuvo:build`/`zuvo:execute` do. Its threshold is INDEPENDENT of
> ship's own LOC bands (production files only, 3-or-150), so a change ship fast-paths can still be
> gate-substantial. Never reach for `ZUVO_ALLOW_ADHOC=1` on ship's behalf — that escape is the
> human's to type, not the skill's.
>
> **`BLOCKED` has five distinct causes and only one of them is "no review happened".** Read the
> per-file reason the hook prints; re-running `zuvo:review` blindly fixes exactly one of the five
> and loops forever on three of them.
>
> 1. **Genuinely unreviewed** → `zuvo:review ${BASE_REF}..HEAD`, which writes the artifact+proof
>    pair. This is the only cause the "just run review" advice fits.
> 2. **Reviewed, but ship's own Phase 2 fixed something afterwards.** Coverage is keyed on file
>    CONTENT, so any fix applied after the artifact was written changes the blob and drops coverage
>    for that file. This is the LIKELIEST way a ship run hits the gate. The fix is one more
>    adversarial pass over the fixed blob plus an updated artifact — not a re-run from scratch.
> 3. **The artifact+proof pair is in a DIFFERENT checkout.** Coverage is two files: the
>    `memory/reviews/*.md` artifact AND the `zuvo/proofs/*` file its `adversarial:` header names.
>    Both directories are gitignored in this repo *by design* (they are local proof-of-work, not
>    shipped content), so neither travels with a branch, a worktree, or a merge. Work reviewed in a
>    worktree and pushed from the main checkout reads as "never reviewed". Do not re-review — MOVE
>    THE PAIR:
>    ```bash
>    ~/.zuvo/review-artifact-sync.sh --from <checkout-that-reviewed> --to . --slug <range-or-slug>
>    ~/.zuvo/review-artifact-sync.sh --check .        # lint header + proof before pushing again
>    ```
> 4. **The artifact exists but its FORMAT does not parse.** The gate reads a literal contract, and
>    an artifact that misses any line grants zero coverage while looking complete:
>    ```
>    <!-- zuvo-review -->
>    range: <base-sha>..<head-sha>
>    files: path/one.ts, path/two.ts        # comma-separated, or * for the whole range
>    adversarial: zuvo/proofs/<name>.txt    # must resolve, and hold >=2 "REVIEW BY:" lines
>                                           # (or 1 + an explicit single-provider note)
>    ```
>    Re-running `zuvo:review` here reproduces the same unusable artifact. Run
>    `~/.zuvo/review-artifact-sync.sh --check .` — it lints exactly these fields — and repair the
>    header.
> 5. **The blocked files belong to the BASE branch, not to this work** (you merged the target
>    branch in, per Phase 0 step 4). Those files were reviewed in their own PRs, in other
>    checkouts, whose artifacts are local there. Re-reviewing them means reviewing other people's
>    already-merged code, which is a real cost, not a formality — say so out loud, then either
>    sync the pairs (cause 3) or review only the files this branch actually changed and state in
>    the run line which files were carried on the base branch's own review.
>
> **A repo-owned pre-push hook is a different gate with a different fix.** If the block comes from
> the project's own hook (`npm run type-check`, lint, a build) rather than from zuvo's, no review
> artifact will ever satisfy it — the fix is bootstrapping the toolchain (a worktree created for
> backend work still needs `npm ci` to pass a frontend type-check). Read the failing command before
> assuming which gate spoke.

### Step 0: Push-gate preflight (before the release commit, not after the rejection)

Everything the pre-push gate checks is knowable NOW, while fixing it is cheap. Run it here and the
gate becomes a confirmation; skip it and the first time you learn the artifact header is malformed
is after tests, review, a bump, a commit and a tag have all been paid for — and each rejected push
names only ONE reason at a time, so a run with two problems needs two more attempts.

```bash
~/.zuvo/review-artifact-sync.sh --check .        # marker, range:, comma-separated files:, proof >=2 REVIEW BY:
```

Then dry-run the gate itself against the range you are about to push. **Resolve the hook, do not
assume its path** — it lives at `core.hooksPath` when one is configured (this fleet sets a GLOBAL
one), otherwise `.git/hooks/`, and repos vary (`.githooks/pre-push`, `hooks/pre-push-gate.sh`):

```bash
# --git-common-dir, not --git-dir: in a LINKED WORKTREE (this skill creates them in Phase 1, and
# agents routinely work from one) --git-dir returns the worktree's private dir, which has no hooks,
# so the preflight would silently report "no hook installed" in exactly the setup that needs it.
HOOK_DIR=$(git config --get core.hooksPath || echo "$(git rev-parse --git-common-dir)/hooks")
PP_HOOK="$HOOK_DIR/pre-push"
ZERO=0000000000000000000000000000000000000000
# git supplies the REMOTE SIDE as 40 zeros when the branch does not exist there yet. Substituting
# BASE_REF instead simulates an incremental push and hides everything a first push would carry.
REMOTE_SHA=$(git rev-parse "$PUSH_REMOTE/$BRANCH" 2>/dev/null || echo "$ZERO")
if [ -x "$PP_HOOK" ]; then
  # $1 = remote name, $2 = remote URL — real hooks read them to pick policy or resolve refs.
  printf 'refs/heads/%s %s refs/heads/%s %s\n' "$BRANCH" "$(git rev-parse HEAD)" "$BRANCH" "$REMOTE_SHA" \
    | "$PP_HOOK" "$PUSH_REMOTE" "$(git remote get-url --push "$PUSH_REMOTE" 2>/dev/null || echo '')"
  PREFLIGHT_RC=$?
else
  PREFLIGHT_RC=0; echo "[SHIP] no pre-push hook installed here — the CI gate is still authoritative"
fi
echo "[SHIP] PREFLIGHT_RC=$PREFLIGHT_RC"   # print it: the decision below happens in another shell
```

`PREFLIGHT_RC=0` = the push will pass this gate. Anything else: fix it NOW (the five causes are in
the preamble above), re-run the preflight, and only then continue. **A missing hook is not a pass**
— it means this preflight proved nothing, and the server-side CI gate still applies; say which of
the two you got. Note the release commit you are about to create changes nothing about coverage:
the gate is content-keyed on the production files, which already sit at their final blobs.

### Step 1: Stage files

Stage **only** files that were actually generated or modified:

```bash
# Only if bump was performed (NOT --no-bump AND NOT PR flow — see Phase 3 skip gate):
git add <version-file>

# Only if CHANGELOG.md was created or updated in Phase 3 (never on PR flow):
git add CHANGELOG.md

# On PR flow neither of the two lines above runs. If `git status` shows the version
# file or CHANGELOG.md modified while you are on a feature branch, Phase 3's skip
# gate did not fire — stop and fix that rather than staging them, or this PR will
# conflict with every other open PR and claim a version number that is already taken.
```

**NEVER** use `git add -A` or `git add .`.

### Step 2: Commit

```bash
git commit -m "release: v<version>"
RELEASE_SHA=$(git rev-parse HEAD)
```

Use `RELEASE_SHA` as the immutable release commit SHA for all downstream metadata.

### Step 3: Tag (release flow only, unless `--no-tag`)

```bash
# PR flow produced NO version (Phase 3 skip gate b), so there is nothing to tag: `git tag v<version>`
# there re-tags the ALREADY-RELEASED version at this branch's head — a published tag now pointing at
# unmerged code. Tagging is the release's job, on the target branch, after the merge.
if [ "$FLOW" = "pr" ]; then
  echo "[SHIP] PR flow → no tag (the release on $TARGET_BRANCH tags the version)"
elif [ -n "${VERSION_OWNER:-}" ]; then
  echo "[SHIP] version+tag owned by $VERSION_OWNER → no tag here (NEW_VERSION was never computed)"
elif [ -z "${NEW_VERSION:-}" ]; then
  echo "[SHIP] no NEW_VERSION (--no-bump or tag-only repo with no bump) → no tag"
else
  # Re-verify at the last moment: Phase 3's preflight ran before tests, review and the release
  # commit, and a concurrent worktree can publish the same version inside that window.
  git rev-parse -q --verify "refs/tags/${TAG_PREFIX}${NEW_VERSION}" >/dev/null 2>&1 \
    && { echo "[SHIP] ${TAG_PREFIX}${NEW_VERSION} appeared since the Phase 3 preflight — recompute the bump, do not overwrite"; exit 1; }
  git tag -a "${TAG_PREFIX}${NEW_VERSION}" -m "release: ${TAG_PREFIX}${NEW_VERSION}"   # annotated: author + date
fi
```

If `--no-tag` was passed, do not create a tag and record `newTag: null` in the artifact.

**Tag AFTER the commit it names, and never move it.** If the push in Step 4 is rejected as
non-fast-forward and you resolve it by merging, the tag you already created points at the
PRE-merge commit — delete the local (unpushed) tag and re-create it on the final commit before
pushing tags. A tag that was already pushed is immutable: cut the next patch instead.

### Step 4: Push

**Push. Every platform, no confirmation prompt** (SAFETY RULE 2 — invoking ship IS the
authorization; the mandatory tests + review + `scan_secrets` upstream are what make it safe).

Push to `$PUSH_REMOTE` (resolved in Phase 0 step 1), not to a hardcoded `origin`.

- **Direct flow:** `git push "$PUSH_REMOTE" <branch>`, then `git push "$PUSH_REMOTE" v<version>` if a tag was created.
- **PR flow:** push the branch, then ensure a PR EXISTS (create or reuse), then
  **WAIT FOR CI AND MERGE IT.** Creating the PR is not shipping; the change is shipped when it is
  on the target branch.

  ```sh
  git push -u "$PUSH_REMOTE" "$BRANCH"

  # Reuse an existing PR — `gh pr create` exits non-zero when one is already open for this head,
  # which is the NORMAL shape of a second ship on the same branch (ship, review, fix, ship again).
  # Treated as a failure, it ended the run at the last step with the work already pushed.
  PR_NUMBER=$(gh pr view "$BRANCH" --json number -q .number 2>/dev/null || true)
  if [ -n "$PR_NUMBER" ]; then
    echo "[SHIP] reusing open PR #$PR_NUMBER (branch already has one)"
  else
    PR_NUMBER=$(gh pr create --base "$TARGET_BRANCH" --head "$BRANCH" --fill | sed -n 's#.*/pull/\([0-9]*\).*#\1#p')
  fi

  gh pr checks "$PR_NUMBER" --watch --fail-fast     # blocks until every check concludes
  gh pr merge "$PR_NUMBER" --squash                 # only if they all passed
  gh pr view "$PR_NUMBER" --json state,mergedAt -q '.state'   # VERIFY: MERGED, not the exit code
  ```

  **MERGED is not the terminal state — a green target branch is.** Post-merge workflows (CI on the
  target branch, deploy gates, scheduled scans) are dispatched BY the merge, so by construction none
  of them has concluded when `gh pr merge` returns. Watch them:

  ```sh
  git fetch "$PUSH_REMOTE" "$TARGET_BRANCH"
  MERGE_SHA=$(git rev-parse "$PUSH_REMOTE/$TARGET_BRANCH")

  # Runs appear a few seconds after the merge. An EMPTY list means "not dispatched yet", not
  # "none configured" — re-read once after a short wait before concluding there is nothing.
  gh run list --commit "$MERGE_SHA" --json databaseId,name,status,conclusion

  # One blocking call per run — never a model-loop poll (see terminal-state.md: 399 polling calls
  # were measured on one profiled run, for information --watch delivers in a single call).
  gh run watch "$RUN_ID" --exit-status
  ```

  Then read `conclusion`, not the exit code:

  - every run `success` → the release is shipped; proceed to Step 5.
  - any run `failure` / `timed_out` → `SHIP INCOMPLETE` with the run URL and the failing job. Fix it
    if it is fixable here (a transient `setup-node` 503/429 is a re-run: `gh run rerun <id> --failed`,
    then watch again — twice, then stop and report it as infrastructure).
  - any run `cancelled` → **not a pass.** A job cancelled by a timeout ignores `continue-on-error`
    and reds the check anyway; reading cancellation as "inconclusive, proceed" converts a real block
    into a green banner.
  - no runs after the second read → say `no post-merge checks configured` and proceed. Absence
    stated is fine; absence assumed is not.

  **Why this is a phase and not a nicety.** Measured 2026-08-17 on `rs_be`: ship merged the PR and
  printed its completion block. The post-merge CI on `main` then failed (`setup-node` 503 → 502 →
  429) and the production gate was `CANCELED`. The release was reported shipped over a broken target
  branch — and the failure became visible ~3.6 minutes *after* the banner, so nothing in the run
  could have caught it. Shipping means the target branch works, not that the merge button worked.

  **Read PR state, not exit codes.** Three shapes that are not what they look like:
  - `gh pr merge` can exit non-zero *after* the merge landed (it also deletes the branch and
    updates the local ref; a failure in that tail is not a failed merge). Confirm with
    `gh pr view --json state` — `MERGED` is the ground truth, and a false `SHIP INCOMPLETE` over a
    merged PR sends the next run to re-ship work that is already on the target branch.
  - `gh pr checks --watch` exits non-zero when there are NO checks configured, and returns
    immediately when none have been dispatched yet. Distinguish: zero checks configured → proceed
    (nothing to wait for, say so); checks pending/queued → keep waiting; a check FAILED → fix it or
    print `SHIP INCOMPLETE` with the failing check name.
  - The PR can be `CONFLICTING`/`DIRTY` (`gh pr view --json mergeable`). Merge
    `$PUSH_REMOTE/$TARGET_BRANCH` into the branch, re-run the suite on the merged tree (Phase 0
    step 4(b) rule — a textual merge accepts semantic conflicts), push, and wait again. Do not
    leave an unmergeable PR behind as "shipped".

  **No `gh`, or a forge that is not GitHub** (`GH_AVAILABLE=false` from Phase 0 step 2): the branch
  push still happens — that part is forge-agnostic. What cannot happen is the PR and the merge, so
  the run ends `SHIP INCOMPLETE: branch pushed, PR not created (<no gh | non-GitHub forge>)` with
  the compare URL for the human to open it. `GH_AVAILABLE` existed as a variable that nothing read;
  a "skipped (gh unavailable)" line under a SHIP COMPLETE banner claims a shipped release that is
  sitting on a branch nobody has been asked to merge.

  **Why merging is part of ship, not a separate human step.** On this fleet nobody reviews the
  queue — an open PR buys ZERO additional safety and costs a compounding one. Measured on
  2026-08-10, sixteen green PRs had accumulated and every one of the four failure modes below had
  fired at least once:

  - a branch cut before someone else's change **silently reverted it** on merge, with no conflict
    (a manifest fix removed on Aug 3 was back on Aug 5, and the build started emitting dev bundles
    again)
  - PRs touching the same shared file **blocked each other**, so the queue could only shrink one
    PR at a time
  - after the target branch moved ~124 commits, **GitHub stopped computing mergeability at all**
    and refused merges that were provably clean locally
  - rebasing a branch that far behind puts the ENTIRE target branch in the push range, so the
    review gate blocks it

  Every one of those disappears when the branch is a handful of commits behind. The cost is not
  linear in waiting time — it is the distance from the target branch at the moment you merge.

  **If a check is RED: fix it or say so. Never leave the PR open and walk away** — that is the
  state that produced all four. If it genuinely cannot be fixed here, print `SHIP INCOMPLETE` with
  the failing check, exactly as for a blocked push.

There is deliberately no non-interactive carve-out. It used to skip the push on Codex App and
Cursor and print the commands for the user to run by hand — which is the single step they invoked
ship to get, so "shipped" meant "not shipped" on two of four platforms.

**If the push is BLOCKED** (pre-push gate, auth failure, non-fast-forward): do NOT silently record
`pushed: false` and print SHIP COMPLETE. Read the reason, fix it if it is fixable (a missing review
artifact → produce it; a stale `zuvo/plans/active-plan.md` still saying `in-progress` on a finished
plan → set it to `completed`), and push again. If it genuinely cannot be resolved here, the block is
`SHIP INCOMPLETE` with the verbatim gate output — never a success banner over an unpushed release.

Track final local state in variables:
```
PUSHED=true|false
TAG_PUSHED=true|false
PR_NUMBER=<number-or-null>
```

### Step 5: Write `memory/last-ship.json`

Write the artifact **after** commit/tag/push decisions are complete:

```json
{
  "version": "<new-version>",
  "previousVersion": "<old-version>",
  "newTag": "v<new-version>" or null,
  "previousTag": "<BASE_REF>",
  "baseSha": "<sha-of-BASE_REF>",
  "releaseCommitSha": "<RELEASE_SHA>",
  "range": "<baseSha>..<releaseCommitSha>",
  "branch": "<current-branch>",
  "targetBranch": "<TARGET_BRANCH>" or null,
  "flow": "direct" or "pr",
  "pr": <number-or-null>,
  "date": "<ISO-8601>",
  "tests": "<pass|warn-carried|skipped-no-runner>",   // from the Phase 1 triage outcome — NEVER hardcode "pass"
  "reviewDepth": "<none|reused|partial:<n>-files/<depth>|light|full|full+coverage>",
  "coverageReuse": {                                  // from Phase 2 step 1b — omit only when UNC_RC was 2/3
    "uncoveredRc": <0|2|3>,
    "reusedFiles": ["<path>", "..."],                 // files no reviewer saw in THIS run
    "artifacts": ["memory/reviews/<base7>..<head7>-<slug>.md", "..."]
  },
  "pushRemote": "<$PUSH_REMOTE>",                     // deploy MUST reuse this, not re-derive it
  "reviewTransport": "<skill-tool|env-compat-dispatch|none>",   // which transport actually ran the review
  "crossProvider": "<ok|single_provider_only|not_run:rc=<N>>",  // NEVER "ok" on a pass that did not run
  "advProof": "<zuvo/proofs/... or null>",
  "versionFile": "<path or null>",                    // null = tag-only versioning
  "diffLOC": <number>,
  "prState": "<MERGED|OPEN|null>",                    // from gh pr view, not from an exit code
  "tagPushed": true or false,
  "pushed": true or false
}
```

Field notes:
- `releaseCommitSha` is the immutable release commit SHA.
- `range` is always SHA-based and stable.
- `targetBranch`: set to `TARGET_BRANCH` (detected default branch) in PR flow, `null` in direct flow.
- `memory/last-ship.json` is local runtime state for downstream skills; it is not committed.
- **In a worktree that is about to be removed, this file dies with it.** Write it anyway, and say
  so in the SHIP COMPLETE `Artifact:` line (`written to <worktree> — ephemeral`). Do NOT redirect it
  to the main checkout to make it survive: another session ships from there, and last-ship state is
  single-slot, so "surviving" means overwriting someone else's release record.

---

## Phase 5: Output

**Phase 5 order is non-negotiable.** Retro append → log append → print SHIP COMPLETE. Printing SHIP COMPLETE before the appends are verified makes the SHIP run unauditable. Past failure mode: agents printed the markdown retro section + a fake `Run:` line in chat without ever executing the bash append commands, leaving `~/.zuvo/retros.log`, `~/.zuvo/retros.md`, and `~/.zuvo/runs.log` empty.

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] BASE_REF resolved ONCE in Phase 0 step 3, printed, and used by Phase 1's baseline, Phase 2's
    DIFF_LOC and the review range — one base, not three
[ ] Phase 2 attestation block printed (all boxes considered, escalation applied if any unchecked)
[ ] Review depth recorded: none/reused/partial:<n>-files/light/full/full+coverage
[ ] Coverage reuse (Phase 2 step 1b): UNC_RC printed; `reused`/`partial` backed by the per-file
    `[SHIP] review reused: <file> ← <artifact>` lines; UNCOVERED re-computed after any fix this run
    applied (step 4.5), so no file ship edited is reported as reused
[ ] The review actually RAN on the mandated path: a Skill(skill="zuvo:review") tool call on Claude
    Code, or the env-compat dispatch on a harness without that tool — transport recorded either way,
    never simulated or summarized
[ ] Cross-provider pass: exit code read, and recorded as ok / single_provider_only / not_run:rc=N —
    an empty output is NOT zero findings, and a proof file exists at zuvo/proofs/ when it ran
[ ] Tests ran and PRODUCED a verdict (runner summary line parsed, status read via PIPESTATUS not a
    pipe's exit); failures TRIAGED with the TEST TRIAGE table printed — never a bare abort, never an
    "allow push despite red?" question
[ ] Phase 1b cheap checks recorded one line each — format / lint / typecheck / build — as pass with
    the count, fail-then-fixed, or `n/a (no such script)`. A check the project defines and the run
    did not execute is an unfinished item, not an omission
[ ] Version bumped with CHANGELOG section added — after the tag-collision preflight (no reuse of a
    published version, no `git tag -f`)
[ ] PR flow only: no version bump, no CHANGELOG edit, no tag created
[ ] Only version files staged (never git add -A)
[ ] memory/last-ship.json written
[ ] Retrospective bash appends EXECUTED (retros.log + retros.md) — printing markdown is not enough
[ ] append-runlog wrapper invoked and exited 0
[ ] Logs evidence block printed with real `tail` output
[ ] PR flow only: PR state read from `gh pr view --json state` is MERGED, or SHIP INCOMPLETE
    printed with the failing check / conflict / missing-forge reason. An open PR left behind is an
    unfinished ship — nobody on this fleet reviews the queue, so it buys no safety and starts
    accruing the four failure modes documented in the push section. A non-zero `gh pr merge` exit
    over a PR whose state is MERGED is NOT a failure.
[ ] Terminal state A: processes launched = N, still alive = 0   (PIDs + how each ended)
[ ] Terminal state B: external checks triggered = N, unconcluded = 0   (run IDs + conclusions)
[ ] Terminal state C: artifacts created = N, not landed = 0   (PR/branch/tag + its state)
[ ] Terminal state (terminal-state.md): post-merge runs on the target branch enumerated by
    `gh run list --commit <merge sha>` and each watched to a conclusion — listed by id with its
    conclusion, or `no post-merge checks configured` after a second read. `cancelled` is not a pass.
    A SHIP COMPLETE printed while a post-merge run is still in flight is the failure this line
    exists to prevent
[ ] Terminal state (terminal-state.md): processes launched by this run = N, still alive = 0
```

### 1. Run retrospective (REQUIRED, before SHIP COMPLETE)

Follow the retrospective protocol from `retrospective.md`. Fill the 9 fields, then **execute the bash append commands** for `retros.log` and `retros.md`. Printing the markdown section is not the retrospective — the bash execution is.

If gate check skips (only valid when literally 1-2 tool calls were made): print `RETRO: skipped (trivial session)` and proceed to step 2 with the `ZUVO_SKIP_RETRO_GATE=1` override.

### 2. Append run line via wrapper (REQUIRED)

Compose `RUN_LINE` per `run-logger.md`, then append via the gate wrapper. **Never `>>` directly to `runs.log`** — the wrapper is the gate that verifies the retro entry exists.

```bash
RUN_LINE="<ISO-8601-Z>\tship\t<project>\t-\t-\t<VERDICT>\t-\t5-phase\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>"
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Capture the wrapper's stdout. Expected: `OK: appended to runs.log (retro verified for ship on <project>)`. If it exits non-zero with `RETRO_REQUIRED`, the retro was not actually appended — go back to step 1 and execute the bash, do not retry by adding `ZUVO_SKIP_RETRO_GATE=1`.

### 3. Print Logs evidence block (REQUIRED)

Run these three commands and paste the actual stdout. This is the audit trail that proves the writes happened — agents cannot fabricate it without a corresponding tool call in the transcript.

```bash
tail -1 ~/.zuvo/retros.log
grep -c '^<!-- RETRO -->' ~/.zuvo/retros.md
tail -1 ~/.zuvo/runs.log
```

### 4. Print SHIP COMPLETE block

```
SHIP COMPLETE
  Branch:      <branch>
  Flow:        direct / pr (#<number>)
  Version:     <old-version> → <new-version> / unchanged (PR flow — version belongs to the release) / n/a (repo has no version file)
  Tag:         v<new-version> / skipped (--no-tag) / n/a (no version to tag)
  Diff:        <N> LOC (<review-depth> path)
  Tests:       <PASS|WARN (pre-existing carried)|SKIPPED (no runner)> (<N> passed, <N> failed)
  DOC:         <changelog-only — feature docs current | updated: <paths> | N/A — <reason>>
  Coverage:    <PASS|WARN|FAIL — from coverage-check (% of changed files, not of code), or 'not dispatched (<300 LOC)'>
  Cross-model: <providers (N findings) | single_provider_only | NOT RUN (rc=<N>)> proof: <zuvo/proofs/... | none>
  Review:      <depth> (<details>) via <Skill tool|env-compat dispatch> [escalated-from <table-depth> due to attestation: <reason>]
  Changelog:   CHANGELOG.md updated / skipped
  Push:        pushed to <remote>/<branch> / BLOCKED (<gate + cause>)
  PR:          #<N> created + merged / #<N> updated + merged / #<N> open (SHIP INCOMPLETE — <failing check|CONFLICTING>) / — (direct flow) / not created (SHIP INCOMPLETE — <no gh|non-GitHub forge>)
  Artifact:    memory/last-ship.json written locally
  Logs:        retros.log=ok retros.md=ok(<count> entries) runs.log=ok  [paste tails from step 3]

  Next: zuvo:deploy (when ready)
```

Render each line conditionally based on actual outcomes (`pushed`, `tagPushed`, `--no-tag` flag). Do not show success indicators for actions that were skipped. A repo with no version file renders
`Version: n/a` and `Tag: n/a` — never a fabricated `→ 0.0.1`, and never a bump invented so the
template has something to print. `Push: skipped (non-interactive)` is NOT a valid rendering: ship
pushes on every platform (SAFETY RULE 2), so an unpushed release is `SHIP INCOMPLETE`, not a
skipped line. The `Logs:` line MUST reflect actual file state from step 3 — if any append failed, the block is `SHIP INCOMPLETE`, not `SHIP COMPLETE`.
