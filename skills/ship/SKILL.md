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
```

If any file is missing: proceed in degraded mode. Note which files are unavailable in the Phase 5 output.

---

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

1. **Detect current branch:**
   ```bash
   git branch --show-current
   ```
   - If on `main`, `master`, `trunk`, or `develop`: **direct flow** (tag + push to current branch).
   - If on any other branch: **PR flow** (push branch + create PR targeting the default branch). Detect the default branch for `targetBranch`:
     ```bash
     TARGET_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null \
       || git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' \
       || echo main)
     ```

2. **Check GitHub CLI availability:**
   ```bash
   gh auth status
   ```
   - If the command fails or `gh` is not installed: set `GH_AVAILABLE=false`. Continue — PR creation will be skipped at Phase 4 (see E3 handling).

3. **Check for changes since last tag:**
   ```bash
   git log $(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~10)..HEAD --oneline
   ```
   - If no commits in range: print "Nothing to ship. No commits since the last tag." and exit cleanly.

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

4. **Dry-run gate:** If `--dry-run` was passed, walk through each subsequent phase printing what would happen at each step (branch, flow, diff LOC, review depth, bump type, files staged, tag name, push target). Then exit without executing anything.

---

## Phase 1: Tests

1. **Detect test command.** Check in order:
   - `package.json` → `scripts.test` (run with `npm test` / `yarn test` / `pnpm test`)
   - `Makefile` → `test` target (run with `make test`)
   - `pyproject.toml` → `[tool.pytest]` or `[tool.pytest.ini_options]` (run with `pytest`)
   - `Cargo.toml` → `cargo test`
   - `composer.json` → `scripts.test` (run with `composer test`)
   - If no test command found: print "No test runner detected. Skipping tests." and continue.

2. **Run the test suite.** Capture exit code, pass count, and fail count.

3. **If tests fail: TRIAGE, never a bare abort.** A red suite has three different causes with
   three different fixes — collapsing them into "stop and ask" froze a shippable branch on two
   inherited snapshots (field feedback 2026-08-01: "czemu nie każe naprawić, tylko blokuje?").
   Classify EVERY failing test first:

   a. **Baseline the failures against the ship base.** Preferred: run ONLY the failing test
      files at the merge-base (`git worktree add <tmp> $(git merge-base HEAD <default>)`,
      reusing installed deps when the lockfile is unchanged; remove the worktree after).
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
   d. **Never end the turn asking "may I push despite red tests?"** for a fixable failure —
      fix it and re-run. The only question ship may ask is a genuine behavior/product decision
      surfaced by a class-(b) fix (interactive only; batch picks the safe default and logs it).

   Print the triage table before proceeding. The counters are OUTCOMES — deliberately not
   labelled a-d, because those letters already name the procedure steps above and reusing them
   made the table unreadable (fixed 2026-08-01):
   ```
   TEST TRIAGE: [N] failing → NEW-FIXED [n1], NEW-ABORT [n2], PRE-FIXED [n3], PRE-CARRIED [n4]
     (NEW-* come from step b, PRE-* from step c; n1+n2+n3+n4 MUST equal N)
   ```
   A count that does not add up to N means some failure was never classified — classify it
   before proceeding, do not print a partial table.

---

## Phase 2: Review Scaling

**0. Secret scan — unconditional, BEFORE the threshold branch.** The frontmatter calls
`scan_secrets` "the last-line check before push"; it belongs on every path, including the <20 LOC
fast path that skips review entirely (a one-line commit is exactly how a credential ships).
Run `scan_secrets` over the release range; any high-confidence hit BLOCKS the ship until removed
AND rotated — a leaked secret is not a WARN.

1. **Compute diff LOC.** Count insertions + deletions since the last tag:
   ```bash
   BASE_REF=$(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~10)
   git diff --stat ${BASE_REF}..HEAD | tail -1
   ```
   Extract the total insertions + deletions number as `DIFF_LOC`. Uses the tag ref directly — `HEAD~N` is fragile with merge commits and non-linear history.

   **Diff scope is the entire release.** `DIFF_LOC` includes ALL changes since the last tag — not just "your feature." If the diff is 4000 LOC because 3000 LOC of other work landed too, the review covers ALL 4000 LOC. Do not rationalize a smaller scope by counting only "feature commits."

2. **Apply review threshold (MANDATORY).** These thresholds are non-negotiable (see Safety Rule 5). The only override is `--full` — escalation UP:

   | Diff LOC | Review actions |
   |----------|----------------|
   | < 20 | **Fast path** — skip review entirely |
   | 20 - 100 | Dispatch `review-light` agent (read `skills/ship/agents/review-light.md`) |
   | 100+ | Dispatch `review-light` + invoke `zuvo:review` via the Skill tool (`Skill(skill="zuvo:review", args="${BASE_REF}..HEAD --report-only")`) — runs adversarial pass at TIER 2+ + invoke `Skill(skill="zuvo:design-review")` if frontend files changed (`.tsx`, `.jsx`, `.css`, `.scss`, `.html`) |
   | 300+ | All of the above + dispatch `coverage-check` agent (read `skills/ship/agents/coverage-check.md`). `Skill(skill="zuvo:review", args="${BASE_REF}..HEAD --report-only")` runs at TIER 3 with automatic adversarial pass. |

   **ALWAYS pass the RANGE `${BASE_REF}..HEAD`, never bare `--report-only`.** Ship runs AFTER the work is committed, so an argument-less `zuvo:review` scopes to *uncommitted* changes — empty at this point — and the "mandatory" review passes on nothing. Use the same range Phase 2 measured `DIFF_LOC` over.

   **Pass `--report-only` when invoking `zuvo:review` from ship** — a pre-merge release review must SURFACE blockers for the release decision, not silently auto-rewrite the diff you are about to tag. (Direct `/zuvo:review` defaults to auto-fix; ship-dispatched does not.)

   **Flag override (user-provided ONLY — agent must NEVER self-apply):**
   - `--full`: always use 300+ path (all reviews + coverage check) regardless of diff size.
   - There is NO downgrade flag. A review skip cannot be expressed as an argument to this skill.

   **Invocation form is non-negotiable.** When the threshold says "invoke `zuvo:review`", you MUST issue an actual `Skill(skill="zuvo:review")` tool call. Reading the review skill, simulating it mentally, summarizing findings from prior commits, or asserting that `zuvo:execute` / per-task review "covered it" does NOT count as invocation. The tool call is the only acceptable evidence.

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
   Decision:
   - All boxes checked → proceed at threshold-required depth.
   - ANY unchecked → escalate to full+coverage; reason: <which thought you had>.
   ```

   The forbidden thoughts above are the EXACT rationalizations that have caused past ship runs to skip review on integrated multi-tier diffs. They are listed so you can recognize them, not so you can pattern-match around them. If your reasoning resembles ANY of these — even with different wording — treat the corresponding box as unchecked.

3. **Agent dispatch — review-light:**
   - Read `skills/ship/agents/review-light.md` for the agent's instructions.
   - Provide the git diff as input.
   - If the agent returns verdict `BLOCK`: pause. Show the blocker list. Ask the user to fix the issues or explicitly override. In non-interactive environments: stop and print `SHIP PAUSED: review blockers found`.

4. **Cross-provider review** (100+ LOC, after zuvo:review completes):

   After `zuvo:review` returns its verdict, run a cross-provider adversarial review. Read `../../shared/includes/cross-provider-review.md` for the protocol.

   ```bash
   SCRIPT_PATH="${PLUGIN_ROOT}/scripts/adversarial-review.sh"
   if [[ -x "$SCRIPT_PATH" ]]; then
     "$SCRIPT_PATH" --diff "${BASE_REF}" > /tmp/ship-cross-review.md
   fi
   ```

   - If CRITICAL findings: pause. Show the findings alongside zuvo:review's report. Ask the user to fix or override.
   - If WARNING/INFO only: include in the ship report as informational. Do not block.
   - If script unavailable: print `[CROSS-REVIEW] No external provider available.` Continue.

5. **Agent dispatch — coverage-check** (300+ LOC or `--full` only):
   - Read `skills/ship/agents/coverage-check.md` for the agent's instructions.
   - Provide the list of changed production files (exclude test files).
   - The coverage-check verdict is **informational only** — it never blocks ship.

6. **Record review depth** for the artifact:
   - `"none"` — fast path, no review performed
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

2. **Skip gate — TWO conditions, and the second is not optional:**

   a. `--no-bump` was passed.

   b. **The flow is PR flow** (Phase 0 put you on a non-default branch). On a feature branch,
      **do not bump the version and do not touch `CHANGELOG.md` at all.** Print
      `[AUTO-DECISION] PR flow → version + changelog deferred to the release on <TARGET_BRANCH>`
      and go straight to Phase 4 with the version unchanged.

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

   Decision logic:
   - If the user provided an explicit `patch`, `minor`, or `major` argument: use that. Skip detection.
   - If >= 50% of commits follow conventional commit format: auto-compute bump type from the highest-impact prefix (BREAKING > feat > fix).
   - If < 50% follow convention (E4): list the raw commit messages. Ask the user for bump type (`patch`, `minor`, or `major`). In non-interactive environments (Codex, Cursor): default to `patch` with `[AUTO-DECISION]` annotation.

4. **Apply the bump** to the detected version file. Read the current version, increment the appropriate segment, write back.

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
> gate-substantial. On `BLOCKED: pushing substantial unreviewed work`: read the per-file reason it
> prints (each reason has a DIFFERENT fix), then run `zuvo:review ${BASE_REF}..HEAD` to produce the
> artifact+proof pair and push again. Never reach for `ZUVO_ALLOW_ADHOC=1` on ship's behalf — that
> escape is the human's to type, not the skill's.

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

### Step 3: Tag (unless `--no-tag`)

```bash
git tag v<version>
```

If `--no-tag` was passed, do not create a tag and record `newTag: null` in the artifact.

### Step 4: Push

**Push. Every platform, no confirmation prompt** (SAFETY RULE 2 — invoking ship IS the
authorization; the mandatory tests + review + `scan_secrets` upstream are what make it safe).

- **Direct flow:** `git push origin <branch>`, then `git push origin v<version>` if a tag was created.
- **PR flow:** `git push -u origin <branch>`, then `gh pr create --base <targetBranch>`.

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
  "reviewDepth": "<none|light|full|full+coverage>",
  "diffLOC": <number>,
  "tagPushed": true or false,
  "pushed": true or false
}
```

Field notes:
- `releaseCommitSha` is the immutable release commit SHA.
- `range` is always SHA-based and stable.
- `targetBranch`: set to `TARGET_BRANCH` (detected default branch) in PR flow, `null` in direct flow.
- `memory/last-ship.json` is local runtime state for downstream skills; it is not committed.

---

## Phase 5: Output

**Phase 5 order is non-negotiable.** Retro append → log append → print SHIP COMPLETE. Printing SHIP COMPLETE before the appends are verified makes the SHIP run unauditable. Past failure mode: agents printed the markdown retro section + a fake `Run:` line in chat without ever executing the bash append commands, leaving `~/.zuvo/retros.log`, `~/.zuvo/retros.md`, and `~/.zuvo/runs.log` empty.

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] DIFF_LOC computed from last tag and review threshold applied
[ ] Phase 2 attestation block printed (all boxes considered, escalation applied if any unchecked)
[ ] Review depth recorded: none/light/full/full+coverage
[ ] If invocation form was zuvo:review — actual Skill(skill="zuvo:review") tool call exists in the tool log (not simulated, not summarized)
[ ] Tests ran; failures TRIAGED (new-fixed / new-abort / pre-existing-fixed / pre-existing-carried+WARN) with the TEST TRIAGE table printed — never a bare abort, never an "allow push despite red?" question
[ ] Version bumped with CHANGELOG section added
[ ] Only version files staged (never git add -A)
[ ] memory/last-ship.json written
[ ] Retrospective bash appends EXECUTED (retros.log + retros.md) — printing markdown is not enough
[ ] append-runlog wrapper invoked and exited 0
[ ] Logs evidence block printed with real `tail` output
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
  Version:     <old-version> → <new-version>
  Tag:         v<new-version> / skipped (--no-tag)
  Diff:        <N> LOC (<review-depth> path)
  Tests:       <PASS|WARN (pre-existing carried)|SKIPPED (no runner)> (<N> passed, <N> failed)
  DOC:         <changelog-only — feature docs current | updated: <paths> | N/A — <reason>>
  Coverage:    <PASS|WARN|FAIL — from coverage-check, or 'not dispatched (<300 LOC)'>
  Review:      <depth> (<details>) [escalated-from <table-depth> due to attestation: <reason>]
  Changelog:   CHANGELOG.md updated / skipped
  Push:        pushed to origin/<branch> / skipped (non-interactive) / skipped (user declined)
  PR:          #<N> / — (direct flow) / skipped (gh unavailable)
  Artifact:    memory/last-ship.json written locally
  Logs:        retros.log=ok retros.md=ok(<count> entries) runs.log=ok  [paste tails from step 3]

  Next: zuvo:deploy (when ready)
```

Render each line conditionally based on actual outcomes (`pushed`, `tagPushed`, `--no-tag` flag). Do not show success indicators for actions that were skipped. The `Logs:` line MUST reflect actual file state from step 3 — if any append failed, the block is `SHIP INCOMPLETE`, not `SHIP COMPLETE`.
