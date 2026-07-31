# Implementation Plan: write-e2e V2 + fleet-wide adversarial staging fix

**Spec:** inline — no spec (verified external review, score 5.2/10, is the authority)
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (external review findings, verified against repo 2026-07-30)
**plan_revision:** 6 <!-- rev 6 = pass-2 dispositions: proof/test/wording strengthening only; no task added/removed/reordered, no AC or coverage change -->

**status:** Approved
**Created:** 2026-07-30
**Tasks:** 10
**Estimated complexity:** 8 complex, 2 standard

## Design Constraints (source: external review + verification session)

- DC-1 [P0] Review patch must NEVER touch the git index. Build from scoped file list: `git diff -- <files>` (tracked) + `git diff --no-index /dev/null <f>` (new). Second review pass after material fixes reuses the SAME scope.
- DC-2 [P0] `--live` classifies origin LOCAL / STAGING / EXTERNAL_UNKNOWN; mutation flows BLOCKED by default on external origin; `--allow-external-origin` + separate consent for destructive flows.
- DC-3 Validation states: GENERATED / STATIC_CHECKED / VERIFIED_LOCAL / VALIDATED_LIVE / BLOCKED|FAILED. Local `playwright test` requires NO MCP; MCP gates only live DOM inspection.
- DC-4 Preflight: READY / GENERATE_ONLY / BOOTSTRAP_REQUIRED. Never unpinned `npx playwright` (silent install ban).
- DC-5 Causality contract per scenario: trigger → decisive event → pre-state → post-state → visible oracle → cleanup. No visible error state → testability gap report. Gray-box → labeled CHARACTERIZATION/GRAYBOX.
- DC-6 Network mocking = CRITICAL gate: hostname+method+pathname match, mutation body/query/header validation, explicit allowed-host list, block all other external requests, error on unknown internal API, NO broad directory globs (`**/api/**` banned).
- DC-7 Locator priority: getByRole+name → getByLabel → getByPlaceholder → stable text → getByTestId (only justified) → CSS last. Confidence MUST NOT depend on testid presence.
- DC-8 Scale: scoped request = 1 flow, bare `--auto` = 3, 20 only via `--flows`/explicit `--max-flows`. Args split `--scope/--flow/--output/--base-url`; `[path]` kept as `--scope` alias (deprecation note).
- DC-9 SKILL.md target 180-250 lines (enforced: `180 ≤ wc -l ≤ 250`); extracted content in `skills/write-e2e/references/*.md`; helper scripts NOT per-skill (3 of 4 platform builds drop them) — in `scripts/zuvo-home/`. [DEVIATION — surfaced] The review names 3 scripts (`detect-playwright-readiness`, `build-review-patch`, `upsert-e2e-coverage`); this plan ships the same capabilities as 2 files (`build-review-patch` + `e2e-preflight` with `probe|coverage-upsert` subcommands) because the probe and upsert share registry-path resolution and one fallback branch beats two.
- DC-10 E2E-Q1..Q10 registered with upgraded criticals (arbitrary waits, independence, causal oracle, fail-closed network, mutation contract, cleanup, runner/browser version, external-mutation consent, graybox labeling, spec size).
- DC-11 Eval corpus: 8 cases (ready-Playwright; Vite w/o Playwright; `/api/` in module path; 500-with-loader; monorepo scope; external prod-like URL; dirty worktree; a11y UI zero testids).
- DC-12 Order: patch safety + --live first, then verification model + causal/network gates, then modularization + eval corpus. Not cosmetics first. [DEVIATION — surfaced] Patch safety IS first (T1→T2). The `--live` origin gate, however, lands in T6/T7 (after T3 preflight and T5 references) because its V2 home is `references/live-validation.md` — a file the modularization creates; delivering it twice (once in the old monolith, again in the reference) would double the churn for zero safety gain, since `--live` behavior only changes when the rewritten SKILL.md ships (T7) and nothing releases between T2 and T7 (single PR). Release gate making this structural, not aspirational: the run cannot complete without T7 — dependency chain T10←T8←T7 — and `zuvo:execute` declares COMPLETED only after T10's smoke, so the monolith's old `--live` text can never ship alone.

## Architecture Summary

- `shared/includes/adversarial-loop.md` is DOC-ONLY (line 3: skills inline the bash). The broken pattern exists at **12 call-sites**, not 10: 10 SKILL.md (`build:632, execute:614, debug:341, fix-tests:280, write-e2e:364, receive-review:187, content-fix:262, content-migration:394, seo-fix:495, geo-fix:454`) + `hooks/post-skill-adversarial-check.sh:62` (injects "git add -u… Run NOW" into agent context — overrides skill fixes if unfixed) + `hooks/pre-commit-adversarial-gate.sh:102` (remediation string).
- Per-skill `scripts/` subdirs are copied ONLY by the Claude build (`cp -r`); Codex/Cursor/Antigravity builds allowlist `agents/*.md` + `references/*.md` + root `*.md`. `scripts/zuvo-home/*` installs to `~/.zuvo/` via a generic loop (`install.sh:368-394`, atomic tmp+mv, exec bit propagated from source) — ONE absolute path on every host. Caveat: only runs in `both|all` install branch → call-sites need a fallback branch.
- `references/*.md` are copied by all 4 builds but NO skill uses them yet. Files under `skills/*/references/` MUST use `../../../shared/includes/`; `agents/*.md` KEEPS the existing root-anchored `../../` convention (3 files rely on it today — Task 4's regression guard protects them). **Validator gap**: `validate-skills.sh:272-275` root-anchors `../../` so wrong-depth tokens in references/ PASS validation and break at runtime.
- **Codex/Cursor forbidden-token gates scan SKILL.md only** (`build-codex-skills.sh:820-822`, `build-cursor-skills.sh:512-518`) while copying `references/` — modularization would silently move prose out of the gate unless the globs are extended.
- `gen-gate-copies.py` `parse_registry` regex `^\s*\|\s*(CQ|CAP|AP|Q)(\d+)\s*\|(.*)\|\s*$` skips `E2E-Q` rows silently, but a row starting `| Q1 |` would collide with the real Q family (strict duplicate-ID/contiguity checks). The `GATES:BEGIN` regions live in the CONSUMERS (rules/testing.md, rules/cq-checklist.md, quality-gates.md, code-audit, test-audit), NOT in gate-registry.md itself. → E2E-Q registered as single-copy authoritative table in `references/quality-gates.md` + pointer section in `gate-registry.md` whose lines must NOT match the `parse_registry` row regex (option a′). `gen-gate-copies.py` has NO `--check` flag — the no-arg invocation IS check mode (`--write` is the only recognized arg).
- `adversarial-review.sh` stdin contract: any text within 10s; 30k char cap; **empty stdin → `ERROR: No input provided`, exit 2** (so call-sites must capture the helper's output and branch on its exit code BEFORE piping — a bare `helper | adversarial-review` discards the helper's exit-3 and turns a clean tree into a hard error); `--files "<list>"` mode exists (whole-file cat); exit codes 0/2/3/7/124/125 load-bearing. `tests/adversarial/test-spec-includes.sh` asserts 5 literals in BOTH `adversarial-loop.md` AND `adversarial-loop-docs.md`: `status: "partial"`, `single_provider_only`, `exclude-last`, `exit code 3`, `exit code 124` — preserve them (test runs only at `ZUVO_TEST_SCOPE=full`).
- `website/skills/write-e2e.yaml`: 24 hard-coded E2E-Q refs + gate counts + args — goes stale with WP4/5; `validate-skill-pages.sh` checks structure not accuracy → in-scope update.
- Eval corpora: glob-discovered by `tests/skill-suite/test-eval-corpus-schema.sh:227`; absence is NOT a failure — RED requires adding `write-e2e` to the hardcoded `SKILLS` list at `:46`. Schema: top-level exactly `{skill_name, evals}`; each eval exactly `{id,prompt,expected_output,files,assertions}` + optional `fixtures[]{path,content,stage}`; all-synthetic fixtures pattern confirmed in `evals/write-tests.evals.json` and `evals/review.evals.json`.

## Technical Decisions

- **WP1 mechanism:** shared helper `scripts/zuvo-home/build-review-patch` (→ `~/.zuvo/build-review-patch`). Contract: `build-review-patch [--base <ref>] [PATH...]`; **no-PATH mode includes untracked-not-ignored files** (QA ruling — protects the 10 call-sites that pass no list AND the documented fallback path; build:632/execute:614 additionally pass explicit lists per T2 RED item 6, so for them the permissive default is the safety net), bounded by: `ZUVO_REVIEW_PATCH_NO_UNTRACKED=1` escape, binary-file skip, included-untracked manifest on stderr. Tracked, no `--base`: `git -C "$top" diff -- <paths>` + `git -C "$top" diff --cached -- <paths>`; **with `--base <ref>`: `git -C "$top" diff <ref> -- <paths>` (one diff — base→worktree already spans committed-since-base + staged + unstaged; the two-part split applies only to the no-base mode)**; untracked: `git diff --no-index --no-color -- /dev/null "$f"` with EXPLICIT rc capture (`rc<=1` ok, `rc>=2` fatal exit 2) — never bare `|| true` (swallows real errors), never under pipefail in a pipeline. At the `build`/`execute` call-sites, pass the run's written-file list as PATH args when the skill tracks it (execution-state `## Files Changed`) — the permissive no-PATH default is the safety net, not the routine path. Exit codes: 0 = diff emitted; 3 = no changes → **caller skips review with note `adversarial review: skipped (no changes)` — NOT a --files fallback** (QA ruling: fallback there would paper over helper bugs); 2 = usage/not-a-repo/bad --base (validated via `git rev-parse --verify "$ref^{commit}"`). Worktree-safe: `git rev-parse --show-toplevel` (worktree root); paths canonicalized before any cd; always `--` before pathspecs; `-z`/read -d '' for exotic filenames. `#!/usr/bin/env bash`, bash-3.2-safe, committed `chmod +x`. Call-site shape (all 12 identical) is **capture-then-branch, never a bare pipe** (a pipe discards the helper's exit-3 and empty stdin makes adversarial-review exit 2 — a clean tree would report a hard error):
  ```bash
  if [ -x "$HOME/.zuvo/build-review-patch" ]; then
    _patch=$("$HOME/.zuvo/build-review-patch" [paths]); _prc=$?
    if [ "$_prc" -eq 3 ]; then echo "adversarial review: skipped (no changes)"
    elif [ "$_prc" -ne 0 ]; then echo "ERROR: build-review-patch failed (rc=$_prc)"; # surface, do not mask
    else printf '%s\n' "$_patch" | "$AR_CMD" --json --mode <mode> --artifact <path>; fi
  else "$AR_CMD" --json --mode <mode> --artifact <path> --files "<changed files>"; fi
  ```
  Path lists are passed quoted (`"$@"`-style / individually quoted args) — the helper's argv contract (scenario 7, spaced filenames) holds only if call-sites do not word-split. Context split for the rc≠0 branch: in the 10 SKILL call-sites the `ERROR:` line surfaces and the skill's own review-required gate handles it; in the TWO HOOK strings (pre-commit gate remediation, post-skill injected directive) the instruction explicitly says "treat as a blocked review — do NOT proceed to commit", since a hook context has no later gate to catch it. Fallback reserved ONLY for helper-absent. Step 5 re-run: same helper invocation, same PATH args, never stage.
- **Gate registration:** option a′ — authoritative E2E-Q table ONLY in `skills/write-e2e/references/quality-gates.md`; `gate-registry.md` gets a short pointer section (outside GATES regions); `CLAUDE.md` SSOT wording updated to "E2E-Q registered by reference".
- **e2e helper:** ONE `scripts/zuvo-home/e2e-preflight` with subcommands `probe` (→ READY/GENERATE_ONLY/BOOTSTRAP_REQUIRED via `playwright.config.*` + `node_modules/@playwright/test` + `node_modules/.bin/playwright --version` + browser cache dirs; NEVER invokes npx) and `coverage-upsert` (idempotent registry row upsert).
- **Origin classifier:** LOCAL = `^https?://(localhost|127\.0\.0\.1|\[::1\]|0\.0\.0\.0|host\.docker\.internal|[a-z0-9-]+\.(local|localhost|test))(:\d+)?(/|$)`; STAGING = explicit only (`--allow-external-origin` or `ZUVO_E2E_STAGING_HOSTS` exact match — NO hostname heuristics); default EXTERNAL_UNKNOWN → read-only specs only, mutations BLOCKED.
- **Registry migration:** `memory/e2e-coverage.md` gains `State` column; legacy rows read as GENERATED (never back-fill VERIFIED). **Owned by Task 3:** `coverage-upsert` detects a registry lacking the `State` column, rewrites the header once (atomic), and leaves legacy rows' state empty (= GENERATED by the read rule).
- **E2E-Q V2 mapping (authoritative, single source — resolves the Q-number/invariant pairing everywhere):** E2E-Q1 no arbitrary waits/networkidle · Q2 test independence + unique data · Q3 causal oracle after the decisive event · Q4 fail-closed network policy · Q5 mutation contract validation · Q6 cleanup for destructive operations · Q7 runner/browser version compatibility · Q8 no external mutation flows without explicit consent · Q9 gray-box explicitly labeled · Q10 spec size limit + helper extraction. ALL TEN CRITICAL (the review's list verbatim). V1 concerns that are generation guidance rather than gates (locator policy, auth via storageState, error-path coverage, journey naming) live in `playwright-patterns.md` as rules, not gate IDs. `network-mocking.md` cites E2E-Q4/Q5; cleanup cites Q6.
- **Corpus:** 8 all-synthetic-fixture cases; explicit ≥8 assertion added (schema floor is only ≥2).
- **No new dependencies.**

## Quality Strategy

- Test harness: dialect (a) standalone (`set -u`, own pass/bad, `ALL PASS`/exit 1) in `tests/hooks/` (fast scope, auto-discovered by `tests/run-all.sh:106`). Temp-repo fixture idiom: `tests/hooks/test-pre-push-gate.sh:17-26` verbatim. Install-outcome idiom: `tests/adversarial/test-install-verify-plan-dag.sh:18-33` (awk-extract `install_zuvo_home`, run under mktemp HOME, assert `-f` AND `-x`).
- New helper/call-site tests live in `tests/hooks/`, contract/guard tests in `tests/skill-suite/` — both fast-scope (NOT `tests/adversarial/`, which is full-scope-only). `ZUVO_TEST_SCOPE=full` run required before WP1 commit (spec-includes literals).
- CQ gates active: CQ3 (argv validation, exit 2 + usage), CQ8 (`--no-index` rc capture; `chmod 000` test case), CQ25 (`#!/usr/bin/env bash` like verify-plan-dag; exec bit committed), CQ31 (`--` before pathspecs, no eval, -z parsing, pathspec-relativity resolved before cd). CQ11: no shell limit in file-limits.md; zuvo-home precedent 295-383 lines — helpers at ~110/~140 fine.
- Known risks (mitigated in tasks): (1) no-PATH misses untracked → ruling applied T1; (2) `||true` swallows rc≥2 → rc capture T1; (3) references/ escapes Codex/Cursor token gate → T4 extends globs; (4) include-depth validator gap → T4 fixes resolution + T5/T6 use `../../../`; (5) spec-includes full-scope-only → T2 verify runs full scope; (6) exec bit single point of failure → T1 install test asserts `-x` in-tree and post-install.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G1 | DC-1 scoped patch, index never touched, 12 call-sites | requirement | Task 1, Task 2 | |
| G2 | DC-1 second pass same scope (Step 5) | requirement | Task 2 | |
| G3 | DC-2 --live origin safety | requirement | Task 6, Task 7 | |
| G4 | DC-3 validation states + MCP decouple | requirement | Task 6, Task 7 | T3 feeds preflight vocabulary + owns State-column persistence (registry migration); the state MODEL lives in T6/T7 |
| G5 | DC-4 preflight 3-state, no unpinned npx | requirement | Task 3 | |
| G6 | DC-5 causality contract + GRAYBOX | requirement | Task 5 | |
| G7 | DC-6 fail-closed network CRITICAL gate | requirement | Task 5 | |
| G8 | DC-7 locator inversion, confidence decoupled | requirement | Task 5, Task 7 | |
| G9 | DC-8 scale defaults + arg grammar | requirement | Task 7 | |
| G10 | DC-9 modularization 180-250 lines + references/ | deliverable | Task 5, Task 6, Task 7 | line-count bound proven by T7's proof; T5/T6 prove the references halves |
| G11 | DC-10 E2E-Q registration + criticals | deliverable | Task 5, Task 8 | |
| G12 | platform-build integrity (token gate covers references/, include depth enforced) | constraint | Task 4 | architect/QA discovery, not in review |
| G13 | DC-11 eval corpus 8 cases | deliverable | Task 9 | |
| G14 | website yaml sync + CLAUDE.md SSOT wording | deliverable | Task 8 | |
| G15 | suites green: validate-skills (count 56), run-all full, install.sh | constraint | Task 10 (+ every task's Verify) | |
| G16 | DC-12 implementation order | constraint | task ordering | patch safety first (T1→T2); --live lands T6/T7 — surfaced deviation recorded at DC-12 |

## Review Trail

- Phase 1: full fan-out (Architect → Tech Lead → QA Engineer, all Opus general-purpose, sequential)
- Plan reviewer: revision 1 → ISSUES FOUND (12: T4 would break 3 agents/ files → rule narrowed to references/ only; pipe discards helper exit-3 → capture-then-branch shape mandated; T8 proof theatre → real failing-today assertions + separate G14 proof; T7 missing dep on T2 (same-file) → added; T10 runner gitignored → moved to tests/smoke-write-e2e-v2.sh tracked; T1 proof fixture couldn't catch index mutation → tracked-modified+staged added; DC-12 --live ordering deviation surfaced; T8 region-overlap assertion vacuous → row-regex collision assertion; size bound 260 → 180-250 both ends; T5/T6 over-serialized behind T4 → dep moved to T10; adversarial-loop-docs.md added to T2 Files; factual drift fixed: 24 yaml refs, 489 lines, no --check flag, antigravity gate exists)
- Plan reviewer: revision 2 → ISSUES FOUND (1 substantive + 5 minor; all 12 rev-1 fixes independently confirmed). Rev-3 fixes: T4 fixture non-dot dir + glob-visibility sub-assertion + find/case implementation pinned; G10 matrix 180-250; Arch Summary references-vs-agents convention split; T8 G11 grep full authoritative path; T10 proof subshell+pipefail+mkdir; T3 proof root-relative; T1 fixture gpgsign off + trap-clean + config fix
- Plan reviewer: revision 3 → APPROVED (all 6 rev-2 issues verified fixed empirically; no new issues; proofs confirmed fail-today/pass-after)
- Cross-model validation (pass 1, on rev 3): partial (3/5 providers returned: codex-5.3, cursor-agent, claude; kimi timeout, agy empty) — 17 findings. Dispositions:
  - FIXED in rev 4 (CRITICAL): base-ref-never-used → helper contract now consumes `--base` (single base→worktree diff) + RED scenario 5b; platform-failures-discovered-last → T7 Verify runs all three platform builds (T10 remains final repetition).
  - FIXED in rev 4 (WARNING, semantics-changing): E2E-Q number/invariant conflict → authoritative 1:1 V2 mapping pinned in Technical Decisions, T5 RED 3/3b assert cross-file consistency; T5 deps restored to Task 4 + guards in T5 Verify (two providers; supersedes rev-2 issue 10 — safety over path length); registry State-column migration now owned by T3 (scenario 11); T6 G4 proof asserts all 5 states + 3 origin classes; T6 re-rated complex (two providers); build/execute call-sites pass tracked written-file lists (bounds no-PATH exposure); T9 cases 2/6 assert literal state tokens (GENERATE_ONLY/BLOCKED).
  - DISPOSITIONED, no change: DC-12 --live ordering (cursor CRITICAL) = the already-surfaced deviation, strengthened with the structural release-gate note (single branch; T10←T8←T7 chain makes shipping old --live text alone impossible); Task-2 15-file bloat (codex WARNING + cursor INFO) = accepted atomic per runtime-injection argument, twice reviewed; SMOKE4 real-HOME install (codex WARNING medium) = install.sh IS the documented dev workflow (CLAUDE.md), helpers land atomically (tmp+mv) — accepted-note; FAILED-state eval (part of cursor finding) = FAILED requires a real live-run failure, exercised in T3 helper tests instead — corpus asserts BLOCKED/GENERATE_ONLY; claude G4/G10 matrix drift = fixed in matrix Notes; 180-250 feasibility spike = failure direction is safe (overflow moves INTO references), noted.
- Plan reviewer: revision 4 → ISSUES FOUND (1 substantive: stale `E2E-Q6→CRITICAL` in T5 GREEN contradicting the new mapping + T5's own RED 3b; 5 minor: complexity tally 8/2, T6 routing→deep, T6 proof subshell + anchored ORIGIN-LOCAL token, T7 build logs not /dev/null, T2 RED item 6 for build/execute PATH args; G4 note understated T3's State-column ownership). Reviewer confirmed: --base semantics sound (both call-sites correctly pre-commit/no-base), T5 dep restoration legitimately supersedes rev-2 issue 10 (withdrawn), E2E-Q mapping otherwise consistent, dist/ gitignored so T7 builds are worktree-safe, DC-12 release gate structurally true. All fixed in rev 5.
- Plan reviewer: revision 5 → APPROVED (all 6 rev-4 fixes verified, incl. empirical subshell/anchor checks; one one-token correction applied in-revision: `grep -Eiq` in T6's G4 proof — the case-sensitive form failed closed against the plan's own `Origin:` example; every proof re-checked for the same class, clean)
- Cross-model validation (pass 2a, on rev 5, `--exclude-last codex-5.3`): status ok, 4/5 providers (agy, cursor-agent, kimi, claude), 0 timeouts. Input truncated at 49,998/55,855 chars (whole-section boundary) — tail sections (Task 9, Task 10, Smoke Proofs, Reality pre-check) fell outside this pass; they were covered line-by-line by all five plan-reviewer passes. Findings → rev 6:
  - FIXED (CRITICAL, agy): T5 proof chained commands with the English word "and" → single `&&` chain with exit-status semantics.
  - FIXED (WARNING): T2 proof's python predicate had escaped backticks that could never match → rewritten as path-exclusion + separate prohibition-line grep (agy); T4 proof prose "run the new guard test" → exact command (agy INFO, fixed anyway); T4 token-gate RED re-grounded on a synthetic dist tree + build-script glob-source grep (claude — build copy loops are SKILL.md-gated so the fixture would be invisible to a real build); T6 RED item 2 now REQUIRES the literal `Origin:` header line the G4 proof anchors on (kimi); T7 run-all now `ZUVO_TEST_SCOPE=full` (cursor); T7 RED item 6 fallback must name all 3 preflight states for helper-absent installs (cursor); T3 coverage-upsert scenario 12: 6-state enum round-trip + unknown-state exit 2 (kimi); G2 proof: zero-count assertion + `same helper invocation` literal instead of a non-discriminating mention-count (kimi INFO + claude "same scope" — fixed together); canonical block: quoted path lists + hook-context rc≠0 = "treat as blocked review" vs advisory skill-context (kimi fails-open + claude quoting); WP1 untracked-inclusion justification reworded to name the 10 no-list sites, not build/execute (kimi INFO).
  - DISPOSITIONED, no change: Task 8 "bloat" at 4 files (agy) — within the ≤5 boundary, mixed-doc sync is one concern; Task 3 "must commit memory/e2e-coverage.md" (agy) — FP: the registry is a runtime artifact in TARGET projects, not a file in this repo; Task 2 split (cursor, 3rd occurrence) — accepted atomic, twice reviewer-endorsed; DC-12 --live ordering (cursor, 3rd occurrence) — surfaced deviation + structural release gate stand; "cross-model pass 2 pending" (cursor) — meta, resolved by this pass; T7 rewrite-risk spike (cursor) — T7 GREEN's 11-section outline IS the budget outline; overflow direction is safe (moves INTO references); SMOKE4 real-HOME install (repeat) — documented dev workflow.
- Cross-model validation (pass 2b, tail extract): **skipped (script-generated reason: "plan too short — 2 tasks, minimum 3")** — the tail extract holds only Tasks 9-10. Tail coverage rests on the plan-reviewer passes, which verified both tasks' proofs empirically (incl. the T10 PIPESTATUS fix and T9 RED polarity).
- Plan reviewer: revision 6 (final convergence) → APPROVED after 2 prose corrections applied in-revision: (1) T4 synthetic-dist rationale corrected — builds have NO SKILL.md gate (only `shared` excluded); the SKILL.md-less fixture would crash `transform_skill_for_codex` for an unrelated reason, which is the (stronger) real justification for the synthetic tree; trap cleanup flagged load-bearing; (2) T7 Expected "fast scope" → "full scope" to match the command. Optional symmetry item also taken: T2 RED item (7) asserts the hooks' blocked-review wording. Reviewer minor notes (T5 absent-token fails closed; T2 proof refactor-file exclusion partly compensated by RED item 1) recorded, no change. Six reviewer passes total; all proofs verified fail-today/pass-after.
- Plan-review budget: 3/8 passes used (window OK).
- Status gate: **Approved** (user, 2026-07-30, interactive) — reviewer APPROVED on current revision + cross-model pass with all CRITICALs resolved and WARNINGs dispositioned; stop rule engaged.

## Task Breakdown

### Task 1: build-review-patch helper — scoped review patch without touching the index
**Files:** `scripts/zuvo-home/build-review-patch` (new, ~110L, +x), `tests/hooks/test-build-review-patch.sh` (new)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: `tests/hooks/test-build-review-patch.sh` (dialect (a), mktemp repo per `test-pre-push-gate.sh:17-26`, `trap 'rm -rf' EXIT INT TERM`). Scenarios: (1) repo with 1 modified tracked + 1 untracked new + 1 staged + 1 user-dirty unrelated file → no-PATH output contains the NEW file's content AND the modified hunk AND `git diff --cached` is byte-identical before/after (index untouched); (2) with PATH args → user-dirty file excluded; (3) clean repo → exit 3, empty stdout; (4) not a git repo → exit 2; (5) bad `--base` → exit 2; (5b) **base-aware diff**: commit a change AFTER a recorded base ref, run `--base <that ref>` → the committed-since-base hunk IS in the patch (without `--base` it is not — proves the flag is consumed, not merely validated); (6) `ZUVO_REVIEW_PATCH_NO_UNTRACKED=1` → untracked excluded; (7) filename with space; leading-dash filename (needs `--`); (8) `.gitignore`d file absent from output; (9) binary file → skipped from untracked set, noted on stderr; (10) `chmod 000` file → exit 2 (skip case when EUID=0); (11) worktree: `git worktree add`, run from worktree root AND from subdirectory with relative PATH → patch paths worktree-root-relative; (12) install-outcome: awk-extract `install_zuvo_home` from install.sh, run under mktemp HOME, assert `~/.zuvo/build-review-patch` exists AND `-x`; assert in-tree source is `-x`; assert build-codex/cursor/antigravity scripts do NOT reference the helper (distribution invariant per `test-install-verify-plan-dag.sh:51-59`).
- [ ] GREEN: `scripts/zuvo-home/build-review-patch` — `#!/usr/bin/env bash`, bash-3.2-safe (no mapfile/assoc arrays). Argv parse (`--base <ref>` validated `git rev-parse --verify "$ref^{commit}"`; unknown flag → usage stderr + exit 2). Resolve `top=$(git rev-parse --show-toplevel)` (exit 2 on failure); canonicalize PATH args repo-relative BEFORE any cd; reject paths outside root (exit 2). Emit — no `--base`: `git -C "$top" diff -- <paths>` + `git -C "$top" diff --cached -- <paths>`; with `--base <ref>`: `git -C "$top" diff "$ref" -- <paths>` (single diff spans committed-since-base + staged + unstaged; the validated ref MUST be consumed here, not just checked); untracked via `git -C "$top" ls-files --others --exclude-standard -z [-- <paths>]` piped to `while IFS= read -r -d ''`; each new file: explicit rc capture around `git diff --no-index --no-color -- /dev/null "$f"` (rc≤1 append, rc≥2 fatal exit 2); binary untracked skipped with stderr note; untracked manifest → stderr. Empty total output → exit 3. Stdout = patch only.
- [ ] Verify: `bash tests/hooks/test-build-review-patch.sh`
  Expected: final line `ALL PASS`, exit 0.
- [ ] Acceptance Proof:
  - G1 (helper half):
    - Surface: backend-logic
    - Proof (run from repo root; fixture has tracked-modified + staged + untracked so `git add -u` behavior would be caught):
      ```bash
      H="$(git rev-parse --show-toplevel)/scripts/zuvo-home/build-review-patch"
      T=$(mktemp -d); trap 'cd /; rm -rf "$T"' EXIT INT TERM; cd "$T"; git init -q -b main
      git config user.email t@t; git config user.name t; git config commit.gpgsign false
      echo v1 > tracked.ts; echo s1 > staged.ts; git add tracked.ts staged.ts
      git commit -q -m i
      echo v2 > tracked.ts                    # tracked, modified, UNSTAGED
      echo s2 > staged.ts; git add staged.ts  # deliberately staged by "user"
      echo new > brand-new.spec.ts            # untracked NEW file
      before=$(git diff --cached | shasum)
      out=$(bash "$H"); rc=$?
      after=$(git diff --cached | shasum)
      printf '%s' "$out" | grep -q 'brand-new.spec.ts' \
        && printf '%s' "$out" | grep -q '+v2' \
        && [ "$before" = "$after" ] && [ "$rc" -eq 0 ]; echo EXIT=$?
      ```
    - Expected: `EXIT=0` — new untracked file AND the modified hunk present in patch; staged-state hash byte-identical (an implementation that ran `git add -u` would change it by staging tracked.ts)
    - Artifact: `zuvo/proofs/task-1-report.md`
- [ ] Commit: `feat(zuvo-home): build-review-patch — scoped adversarial-review patch that never mutates the git index and includes new untracked files`

### Task 2: migrate all 12 call-sites + adversarial-loop.md to the scoped patch
**Files:** `shared/includes/adversarial-loop.md`, `shared/includes/adversarial-loop-docs.md` (mirror check — contains NO `git add -u` today, expect a no-op; listed so the executor verifies rather than hunts), `hooks/post-skill-adversarial-check.sh`, `hooks/pre-commit-adversarial-gate.sh`, `skills/{build,execute,debug,fix-tests,write-e2e,receive-review,content-fix,content-migration,seo-fix,geo-fix}/SKILL.md`, `tests/hooks/test-review-patch-callsites.sh` (new)
**Surface:** docs (protocol prose) + config (hook strings)
**Complexity:** complex — 15 files, but one inseparable mechanical sweep: leaving ANY call-site on `git add -u` (especially the post-skill hook, which injects the old pattern into agent context at runtime) re-teaches the broken pattern and defeats the others; splitting would ship a half-migrated fleet.
**Dependencies:** Task 1
**Execution routing:** deep implementation tier

- [ ] RED: `tests/hooks/test-review-patch-callsites.sh` (dialect (a), pure grep — model `test-review-artifact.sh:27-66`). Asserts: (1) zero occurrences of `git add -u` across `skills/*/SKILL.md`, `shared/includes/*.md`, `hooks/*.sh` EXCEPT the prohibition line in `skills/refactor/SKILL.md` (match its "not `git add -u`" context) — `docs/specs/` excluded; (2) each of the 12 call-sites contains `build-review-patch` AND the `[ -x` guard AND a `--files` fallback; (3) the 5 spec-includes literals still present in `shared/includes/adversarial-loop.md` AND `adversarial-loop-docs.md` (`status: "partial"`, `single_provider_only`, `exclude-last`, `exit code 3`, `exit code 124`); (4) adversarial-loop.md Step 5 contains no staging instruction and references re-running the same helper invocation; (5) every one of the 12 call-sites uses the capture-then-branch shape — assert each contains the rc-capture (`_prc=$?` or equivalent) AND the exit-3 branch with `skipped (no changes)` — a bare `build-review-patch | adversarial-review` pipe anywhere is a FAIL; (6) the `build:632` and `execute:614` blocks invoke the helper WITH a path-list argument (non-empty PATH args sourced from the run's written-file list), not the bare no-PATH form; (7) the two hook strings (`pre-commit-adversarial-gate.sh`, `post-skill-adversarial-check.sh`) contain the blocked-review wording on the rc≠0 branch (grep `do NOT proceed to commit` or equivalent) — hooks have no later gate, so their error branch must block, not advise. Test FAILS now (12 sites still on `git add -u`).
- [ ] GREEN: replace the pipeline at all 12 sites with the canonical capture-then-branch block from Technical Decisions (helper output captured, rc branched: 3 → skip-note, ≠0 → surfaced error, 0 → printf into `$AR_CMD`; else-branch `--files`), each keeping its site-specific `--mode`/`--artifact` args. At `build:632` and `execute:614`, the block passes the run's written-file list as PATH args (both skills track it — execute via execution-state `## Files Changed`, build via its plan step list); the no-PATH form remains the documented fallback when the list is unavailable. Rewrite adversarial-loop.md Step 2 (staging → scoped patch, helper contract, exit-code table row for 3 = skipped-no-changes) and Step 5 (`Stage fixes: git add -u` → re-run same helper invocation, never stage; material fixes ⇒ second pass mandatory). Update `hooks/post-skill-adversarial-check.sh:62` injected directive and `hooks/pre-commit-adversarial-gate.sh:102` remediation string to the same canonical block. `adversarial-loop-docs.md`: mirror if it repeats the staging line.
- [ ] Verify: `bash tests/hooks/test-review-patch-callsites.sh && ZUVO_TEST_SCOPE=full bash tests/run-all.sh`
  Expected: `ALL PASS` from the new test; run-all final summary reports 0 failures (full scope includes `test-spec-includes.sh`).
- [ ] Acceptance Proof:
  - G1 (call-site half):
    - Surface: docs
    - Proof: `python3 -c "import glob,sys; bad=[f for f in glob.glob('skills/*/SKILL.md')+glob.glob('hooks/*.sh')+glob.glob('shared/includes/*.md') if f!='skills/refactor/SKILL.md' and any('git add -u' in l for l in open(f))]; sys.exit(1 if bad else 0)" && grep -q 'not .git add -u' skills/refactor/SKILL.md; echo EXIT=$?`
    - Expected: `EXIT=0` — zero `git add -u` anywhere except refactor's prohibition line, which is asserted to still exist (the earlier inline-backtick-escape variant was a broken predicate — `\`` inside a double-quoted python string literal looks for literal backslashes)
    - Artifact: `zuvo/proofs/task-2-report.md`
  - G2:
    - Surface: docs
    - Proof: `test "$(grep -c 'git add -u' shared/includes/adversarial-loop.md)" -eq 0 && grep -q 'same helper invocation' shared/includes/adversarial-loop.md; echo EXIT=$?`
    - Expected: `EXIT=0` — zero staging references remain, and Step 5 explicitly ties its re-run to the Step-2 scope via the literal `same helper invocation` phrase (a bare mention-count of `build-review-patch` was rejected as non-discriminating — Step 2's block alone contains it 3×)
    - Artifact: `zuvo/proofs/task-2-report.md`
- [ ] Commit: `fix(adversarial): review patch is scoped and index-free at all 12 call-sites — new untracked files are reviewed, user WIP is never staged`

### Task 3: e2e-preflight helper — probe + coverage-upsert
**Files:** `scripts/zuvo-home/e2e-preflight` (new, ~140L, +x), `tests/hooks/test-e2e-preflight.sh` (new)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: `tests/hooks/test-e2e-preflight.sh` (dialect (a), mktemp project fixtures). `probe` scenarios: (1) `playwright.config.ts` + `node_modules/@playwright/test/` + executable `node_modules/.bin/playwright` stub + non-empty browser-cache dir (point `$PLAYWRIGHT_BROWSERS_PATH` at a fixture) → stdout `READY`, exit 0; (2) config + devDep in package.json but no node_modules binary → `BOOTSTRAP_REQUIRED`; (3) no config, no dep → `GENERATE_ONLY`; (4) binary present but browsers cache empty → `GENERATE_ONLY` with reason line on stderr; (5) **npx canary**: prepend PATH stub `npx` that writes a canary file; run all probe scenarios; assert canary file does NOT exist (helper never shells to npx); (6) unknown subcommand → usage + exit 2. `coverage-upsert` scenarios: (7) registry absent → created with V2 header (incl. `State` column) + row; (8) same flow re-upserted → single row (idempotent); (9) different flow → appended; (10) malformed registry → exit 2 with message, file unmodified; (11) **legacy-header migration**: fixture registry WITHOUT a `State` column → header rewritten once (atomic), **legacy header cells preserved VERBATIM (never relabelled to canonical names) with only `State` appended**, legacy rows preserved verbatim **as an exact prefix plus exactly one padding cell** (empty state = GENERATED by the read rule), second run does not rewrite again; [SPEC-AMENDED during execute, 2026-07-31: the original "byte-for-byte" wording is unachievable together with table integrity — widening the header without padding the rows leaves ragged rows that render as a broken markdown table (found by 2 independent adversarial providers). The amended form is strictly stronger: content preserved verbatim as a prefix, integrity restored.] (12) **state-enum round-trip**: `--state` accepts each of GENERATED/STATIC_CHECKED/VERIFIED_LOCAL/VALIDATED_LIVE/BLOCKED/FAILED and writes it verbatim; an unknown `--state` value → exit 2, file unmodified (GREEN adds the enum check).
- [ ] GREEN: `scripts/zuvo-home/e2e-preflight` — `#!/usr/bin/env bash`, bash-3.2-safe, subcommands `probe [dir]` and `coverage-upsert --file <registry> --flow <id> --state <STATE> [--spec <path>] [--score N] [--confidence L]`. Probe prints exactly one of `READY|GENERATE_ONLY|BOOTSTRAP_REQUIRED` on stdout (machine-readable), reasons on stderr. Detection: config glob, `node_modules/@playwright/test` dir, `node_modules/.bin/playwright` executable (invoke `--version` from the project dir, never npx), browser cache via `$PLAYWRIGHT_BROWSERS_PATH` fallback `~/Library/Caches/ms-playwright` / `~/.cache/ms-playwright` non-empty. Upsert: match row by flow id, replace or append; atomic tmp+mv.
- [ ] Verify: `bash tests/hooks/test-e2e-preflight.sh`
  Expected: `ALL PASS`, exit 0.
- [ ] Acceptance Proof:
  - G5:
    - Surface: backend-logic
    - Proof: `H="$(git rev-parse --show-toplevel)/scripts/zuvo-home/e2e-preflight"; T=$(mktemp -d); (cd "$T" && bash "$H" probe); rc=$?; rm -rf "$T"; echo EXIT=$rc` on an empty dir
    - Expected: stdout `GENERATE_ONLY`, `EXIT=0`; and the npx-canary test case passed in the suite (no npx invocation ever)
    - Artifact: `zuvo/proofs/task-3-report.md`
- [ ] Commit: `feat(zuvo-home): e2e-preflight — deterministic READY/GENERATE_ONLY/BOOTSTRAP_REQUIRED probe (no npx installs) + idempotent e2e-coverage upsert`

### Task 4: platform-build integrity guards — token gate over references/, include-depth resolution fix
**Files:** `scripts/build-codex-skills.sh`, `scripts/build-cursor-skills.sh`, `scripts/build-antigravity-skills.sh` (token gate exists at :522-528 — extend its glob), `scripts/validate-skills.sh`, `tests/skill-suite/test-references-guards.sh` (new)
**Surface:** config
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: `tests/skill-suite/test-references-guards.sh` (dialect (a)). Creates throwaway fixture `skills/tmp-refguard-test/references/bad.md` (NO leading dot — shell `*` globs skip dotdirs, so a `.tmp-` fixture would be invisible to the very `skills/*/references/*.md` glob under test and the guard could never go red; a non-dot dir is safe because every other validator loop gates on `*/SKILL.md` presence and the fixture has none; trap-cleaned `EXIT INT TERM`) containing (a) a Claude-only token (`run_in_background`) and (b) a wrong-depth include `../../shared/includes/gate-registry.md`. Sub-assertion FIRST: the fixture path is matched by the literal glob the build scripts use (`compgen -G "skills/*/references/*.md"` includes it) — proves the fixture is visible before testing that the gates fire. The token-gate assertion (2) runs against a SYNTHETIC dist tree the test constructs itself (`$TMP/dist/skills/tmp-refguard-test/references/bad.md`) using the same glob the build scripts' scan uses — NOT via a full build run: the builds enumerate `skills/*/` with NO SKILL.md gate (`build-codex-skills.sh:567-569`, cursor `:405-407`, antigravity `:445-447`; only `shared` is excluded), so a SKILL.md-less fixture drives `transform_skill_for_codex` against a missing file and the build fails for a reason UNRELATED to the token — assertion (2) would pass on the wrong cause; a real build also writes into `dist/`. The synthetic tree isolates the scan under test; the companion sub-assertion greps each build script's source for the literal extended glob string, proving the scan the synthetic test exercises is the scan that ships. Because the fixture is NOT inert to a concurrent real build, the `trap … EXIT INT TERM` cleanup is load-bearing, not hygiene. Asserts: (1) `validate-skills.sh` reports ERROR for the wrong-depth include when the file is under a `skills/*/references/` directory (currently PASSES — this is the RED); (2) the codex build's forbidden-token grep, run against a dist containing that references file, FAILS the build (extend `build-codex-skills.sh:820-822` glob to `"$DIST"/skills/*/references/*.md`; same for cursor `:512-518` and antigravity `:522-528`); (3) fixture with correct `../../../` depth + clean tokens passes everything; (4) regression guard: `skills/plan/agents/plan-reviewer.md`, `skills/write-tests/agents/test-quality-reviewer.md`, `skills/execute/agents/quality-reviewer.md` (which legitimately use root-anchored `../../` today) still validate clean.
- [ ] GREEN: `validate-skills.sh` `check_include_integrity`: **scoped to `skills/*/references/*.md` ONLY**, implemented as a `case "$fileloc" in */references/*.md)` guard inside the existing `find`-based walk (`:280`) — NOT a new glob loop, so dotdir visibility semantics stay uniform — resolve `../../` tokens against the file's OWN dirname and ERROR when the resolved path does not exist; existing behavior untouched for SKILL.md and `agents/*.md` (3 agent files use root-anchored `../../` today and dirname-resolution would false-positive them — the validator's own comment at :248-256 documents ~87 false positives from blanket dirname resolution; the narrow scope is deliberate, not a shortcut). Build scripts: extend forbidden-token scan globs to include `skills/*/references/*.md` in the dist. Do NOT change the forbidden-token list itself.
- [ ] Verify: `bash tests/skill-suite/test-references-guards.sh && bash scripts/validate-skills.sh`
  Expected: `ALL PASS`; validate-skills ends `ERRORS: 0` (rule scoped to references/ dirs, which only write-e2e will have — the 3 root-anchored agents/ files are outside the rule's scope by construction).
- [ ] Acceptance Proof:
  - G12:
    - Surface: config
    - Proof: `bash tests/skill-suite/test-references-guards.sh && bash scripts/validate-skills.sh; echo EXIT=$?`
    - Expected: `EXIT=0` — guard test ends `ALL PASS` and validator ends `ERRORS: 0`
    - Artifact: `zuvo/proofs/task-4-report.md`
- [ ] Commit: `fix(build): forbidden-token gate and include-depth validation now cover skills/*/references/ — modularization cannot silently escape platform safety checks`

### Task 5: references — playwright-patterns.md, network-mocking.md, quality-gates.md (E2E-Q V2)
**Files:** `skills/write-e2e/references/playwright-patterns.md` (new ~180L), `skills/write-e2e/references/network-mocking.md` (new ~120L), `skills/write-e2e/references/quality-gates.md` (new ~160L), extend `tests/skill-suite/test-write-e2e-contract.sh` (new file started here)
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 4 (restored per cross-model pass-1: this task creates the repo's FIRST `skills/*/references/` content and must land under active guards — two providers flagged the unguarded window; the plan-reviewer's earlier over-serialization concern is answered by T4 being independent and early, so the critical path cost is one small task)
**Execution routing:** deep implementation tier

- [ ] RED: start `tests/skill-suite/test-write-e2e-contract.sh` (dialect (a), grep contract). Asserts for this task: (1) all 3 files exist; (2) every `shared/includes` reference inside them uses `../../../`; (3) `quality-gates.md` contains an E2E-Q table with EXACTLY rows E2E-Q1..E2E-Q10 matching the authoritative V2 mapping from Technical Decisions 1:1 (Q1 waits · Q2 independence · Q3 causal oracle · Q4 fail-closed network · Q5 mutation contract · Q6 cleanup · Q7 runner/browser version · Q8 external-mutation consent · Q9 graybox · Q10 spec size), all marked critical; (3b) cross-file consistency: every `E2E-Q<n>` citation in `network-mocking.md` and `playwright-patterns.md` agrees with that mapping (network cites Q4/Q5, cleanup cites Q6 — no stray V1 numbering); (4) `playwright-patterns.md` contains the causality-contract field list (trigger, decisive event, pre-state, post-state, visible oracle, cleanup) AND the locator hierarchy with `getByRole` FIRST and `getByTestId` after text AND an explicit statement that confidence does not require testid; (5) `network-mocking.md` states fail-closed default, hostname+method+pathname match key, allowed-host list, the `**/api/**` glob ban (cite the Vite-module/Sentry incident), and CRITICAL-gate wording; (6) no Claude-only tool tokens in any of the 3 files (mirrors the build gate).
- [ ] GREEN: write the 3 reference files. `quality-gates.md` is the authoritative E2E-Q1..Q10 definition (V2 semantics per DC-10 — remap old E2E-Q1..Q10 IDs to the new critical set, each with: what it checks, critical yes/no, auto-fixable, evidence format). `playwright-patterns.md` sections: Causality contract · Oracle selection (visible-state rules, testability-gap reporting) · Locator hierarchy (DC-7 order + justification rules for testid) · Confidence scoring decoupled from testid · GRAYBOX labeling · Cleanup & isolation · Anti-patterns (sleep/networkidle/CSS-chain). `network-mocking.md` sections: Fail-closed default · Match key · Allowed-host list · Glob ban + incident · Mutation contract validation · Escape hatch + justification · Gate wording (E2E-Q4 fail-closed / E2E-Q5 mutation contract → CRITICAL, per the authoritative mapping); cleanup gate wording (E2E-Q6) lands in `playwright-patterns.md` → "Cleanup & isolation".
- [ ] Verify: `bash tests/skill-suite/test-write-e2e-contract.sh && bash tests/skill-suite/test-references-guards.sh && bash scripts/validate-skills.sh`
  Expected: `ALL PASS` ×2 (guards now exercised against real references content); `ERRORS: 0`.
- [ ] Acceptance Proof:
  - G6, G7, G8 (reference half), G11 (table half):
    - Surface: docs
    - Proof: `test "$(grep -c '^| E2E-Q' skills/write-e2e/references/quality-gates.md)" -eq 10 && test "$(grep -n 'getByRole' skills/write-e2e/references/playwright-patterns.md | head -1 | cut -d: -f1)" -lt "$(grep -n 'getByTestId' skills/write-e2e/references/playwright-patterns.md | head -1 | cut -d: -f1)" && grep -q 'fail-closed' skills/write-e2e/references/network-mocking.md; echo EXIT=$?`
    - Expected: `EXIT=0` — exactly 10 E2E-Q rows, getByRole's first mention precedes getByTestId's, fail-closed stated (single `&&` chain — an earlier draft chained fragments with the English word "and", which is not executable)
    - Artifact: `zuvo/proofs/task-5-report.md`
- [ ] Commit: `feat(write-e2e): V2 quality contracts — causal oracles, role-first locators, fail-closed network mocking as critical gate (E2E-Q1..Q10 v2)`

### Task 6: references — discovery-and-scoring.md, scaffold.md, live-validation.md
**Files:** `skills/write-e2e/references/discovery-and-scoring.md` (new ~140L), `skills/write-e2e/references/scaffold.md` (new ~120L), `skills/write-e2e/references/live-validation.md` (new ~130L), extend `tests/skill-suite/test-write-e2e-contract.sh`
**Surface:** docs
**Complexity:** complex (same shape as Task 5 — 3 substantial reference files + shared contract-test extension + 2 cross-task deps; two cross-model providers flagged the "standard" rating as inconsistent)
**Dependencies:** Task 3 (state vocabulary + preflight contract), Task 5 (serialize on shared contract test file; transitively under Task 4's guards)
**Execution routing:** deep implementation tier

- [ ] RED: extend the contract test: (1) 3 files exist, `../../../` depth respected; (2) `live-validation.md` contains the origin classifier (LOCAL regex, STAGING explicit-only rule, EXTERNAL_UNKNOWN default-block) INCLUDING a literal origin-classification header line matching `Origin:.*LOCAL` (e.g. `Origin: LOCAL | STAGING | EXTERNAL_UNKNOWN` — the token the G4 proof anchors on; without this RED requirement a semantically-conformant file could still fail the proof), the 5 validation states, the MCP-decoupling rule (local `playwright test` needs READY only), and the `--allow-external-origin` + destructive-consent gates; (3) `discovery-and-scoring.md` carries the migrated Phase 0/1 content (discovery targets, scoring signals, tiers) with confidence criteria NOT requiring data-testid; (4) `scaffold.md` carries write policy, output structure, POM threshold, auth fixture rules — locator priority references playwright-patterns.md instead of restating testid-first.
- [ ] GREEN: write the 3 files, migrating SKILL.md sections (Discovery :187-215, Scoring :216-260, Scaffold :273-330, Validate :380-403) with V2 semantics applied (states, origin gates, preflight `~/.zuvo/e2e-preflight probe` invocation, registry `State` column + legacy-rows-read-as-GENERATED note).
- [ ] Verify: `bash tests/skill-suite/test-write-e2e-contract.sh && bash scripts/validate-skills.sh`
  Expected: `ALL PASS`; `ERRORS: 0`.
- [ ] Acceptance Proof:
  - G3 (reference half), G4 (reference half):
    - Surface: docs
    - Proof: `f=skills/write-e2e/references/live-validation.md; ( for t in GENERATED STATIC_CHECKED VERIFIED_LOCAL VALIDATED_LIVE BLOCKED 'ORIGIN.*LOCAL' STAGING EXTERNAL_UNKNOWN; do grep -Eiq "$t" "$f" || { echo "MISSING $t"; exit 1; }; done ); echo EXIT=$?`
    - Expected: `EXIT=0` — all five validation states AND all three origin classes present (subshell so the `EXIT=` line always prints; the origin-LOCAL token is anchored `ORIGIN.*LOCAL` because bare `LOCAL` is satisfied by `VERIFIED_LOCAL` and could not fail independently — the reference file must therefore contain an origin-classification line matching that pattern, e.g. an `Origin: LOCAL | STAGING | EXTERNAL_UNKNOWN` table header)
    - Artifact: `zuvo/proofs/task-6-report.md`
- [ ] Commit: `feat(write-e2e): discovery/scaffold/live-validation references — origin safety, 5-state verification model, MCP decoupled from local runs`

### Task 7: SKILL.md V2 rewrite — 489 → 180-250 lines
**Files:** `skills/write-e2e/SKILL.md` (rewrite), extend `tests/skill-suite/test-write-e2e-contract.sh`
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 2 (canonical adversarial block — Task 2 also edits this file: same-file serialization), Task 3, Task 5, Task 6
**Execution routing:** deep implementation tier

- [ ] RED: extend contract test: (1) `180 ≤ wc -l ≤ 250` (the review's bound, both ends enforced); (2) Argument Parsing table contains `--scope`, `--flow`, `--output`, `--base-url`, `--max-flows`, retains `[path]` with deprecation-alias note; (3) scale defaults present: scoped=1, `--auto`=3, 20 only explicit; (4) origin classes + 5 states named in the phase skeleton; (5) Mandatory File Loading lists the 6 references with lazy-load triggers (per-phase, not all-at-start) using `references/` relative paths; (6) preflight step invokes `~/.zuvo/e2e-preflight probe` with a helper-absent fallback line, and the fallback line itself names all three preflight states (READY/GENERATE_ONLY/BOOTSTRAP_REQUIRED) with the manual detection mapping — a Codex/Cursor-only install (where `install_zuvo_home` never ran) must degrade to the same 3-state semantics, not to improvisation; (7) adversarial block uses the Task-2 canonical form (no `git add -u`); (8) frontmatter unchanged in shape (name/description/codesift_tools) so installs/routing stay intact; (9) `VALIDATION SKIPPED` string gone — replaced by per-state reporting; (10) Agent Routing table keeps the literal `Sonnet`/`Explore` forms the codex build sed recognizes; (11) completion block + run-logger wrapper retained (validate-skills MFL/run-logger checks must stay green).
- [ ] GREEN: rewrite SKILL.md: frontmatter (unchanged keys) · H1 + scope · Argument Parsing (new grammar + alias) · Env compat + CodeSift setup pointers · Mandatory File Loading incl. per-phase lazy references · Phase 0 preflight (probe → READY/GENERATE_ONLY/BOOTSTRAP_REQUIRED branches; BOOTSTRAP_REQUIRED = conscious-install consent, GENERATE_ONLY = write specs + STATIC_CHECKED at most) · Phase 0.5 origin gate (--live only) · Phase 1 discover+score (→ discovery-and-scoring.md; defaults 1/3/20) · Phase 2 scaffold (→ scaffold.md) · Phase 3 generate (causality contract per scenario → playwright-patterns.md; network policy → network-mocking.md; E2E-Q gate check → quality-gates.md) · Phase 3.5 adversarial (canonical block) · Phase 4 verification ladder (STATIC_CHECKED always; VERIFIED_LOCAL when READY; VALIDATED_LIVE only --live+MCP+origin-allowed) · Artifact contract (State column) · Completion gate + report + run-logger.
- [ ] Verify: `mkdir -p zuvo/proofs && bash tests/skill-suite/test-write-e2e-contract.sh && bash scripts/validate-skills.sh && ZUVO_TEST_SCOPE=full bash tests/run-all.sh && bash scripts/build-codex-skills.sh > zuvo/proofs/build-codex.log 2>&1 && bash scripts/build-cursor-skills.sh > zuvo/proofs/build-cursor.log 2>&1 && bash scripts/build-antigravity-skills.sh > zuvo/proofs/build-antigravity.log 2>&1`
  Expected: `ALL PASS`; `ERRORS: 0`; run-all 0 failures (full scope — catches `test-spec-includes.sh` literals here, not first at T10); all three platform builds exit 0 with output captured to logs (NOT `/dev/null` — the token gate prints its per-file findings to stdout, and a suppressed failure would be an undiagnosable bare exit code). Platform regressions surface HERE, not first at Task 10 (cross-model pass-1 CRITICAL: build failures discovered last).
- [ ] Acceptance Proof:
  - G3, G4, G8, G9, G10:
    - Surface: docs
    - Proof: `n=$(wc -l < skills/write-e2e/SKILL.md); [ "$n" -ge 180 ] && [ "$n" -le 250 ] && grep -q -- '--base-url' skills/write-e2e/SKILL.md && grep -q 'GENERATE_ONLY' skills/write-e2e/SKILL.md && ! grep -q 'VALIDATION SKIPPED' skills/write-e2e/SKILL.md; echo EXIT=$?`
    - Expected: `EXIT=0` (note the `! grep` half is meaningful only post-rewrite — the positive assertions carry the proof; `VALIDATION SKIPPED` exists at :382 today so the combined command fails now and passes after)
    - Artifact: `zuvo/proofs/task-7-report.md`
- [ ] Commit: `feat(write-e2e): V2 SKILL — safe-by-default --live, 3-state preflight, 5-state verification ladder, 1/3/20 scale defaults, modular references`

### Task 8: registry pointer + CLAUDE.md + website yaml sync
**Files:** `shared/includes/gate-registry.md`, `CLAUDE.md`, `website/skills/write-e2e.yaml`, extend `tests/skill-suite/test-write-e2e-contract.sh`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 5, Task 7
**Execution routing:** default implementation tier

- [ ] RED: extend contract test: (1) `gate-registry.md` contains an `E2E-Q` section that names `skills/write-e2e/references/quality-gates.md` as authoritative and lists the 10 IDs + criticality summary (FAILS today — 0 E2E-Q mentions); (2) no line of that new section matches the `parse_registry` row regex `^\s*\|\s*(CQ|CAP|AP|Q)(\d+)\s*\|.*\|\s*$` (a `| Q1 |`-shaped row would collide with the real Q family's strict duplicate/contiguity checks; gate-registry.md itself contains no GATES:BEGIN regions — those live in consumers, so region-overlap is not the risk, row-regex collision is); (3) `python3 scripts/gen-gate-copies.py` with NO args (that IS check mode — only `--write` is recognized) exits 0; (4) `website/skills/write-e2e.yaml`: positive assertions that fail today — `--base-url` present, `State` vocabulary present, E2E-Q names match the V2 set from quality-gates.md — and `bash scripts/validate-skill-pages.sh` exits 0; (5) CLAUDE.md SSOT line mentions E2E-Q registered-by-reference.
- [ ] GREEN: add the pointer section to gate-registry.md (no `| E2E-Q1 |`-style rows that could collide with family parsing — prose + compact list); update CLAUDE.md gate-registry description; rewrite the stale fields of `website/skills/write-e2e.yaml` (gates, args incl. new grammar + alias, artifact contract, how_it_works narrative for the V2 pipeline).
- [ ] Verify: `bash tests/skill-suite/test-write-e2e-contract.sh && bash scripts/validate-skills.sh && bash scripts/validate-skill-pages.sh`
  Expected: `ALL PASS`; `ERRORS: 0`; skill-pages validator exit 0.
- [ ] Acceptance Proof:
  - G11 (registration half):
    - Surface: docs
    - Proof: `grep -q 'skills/write-e2e/references/quality-gates.md' shared/includes/gate-registry.md && grep -q 'E2E-Q10' shared/includes/gate-registry.md && python3 scripts/gen-gate-copies.py; echo EXIT=$?`
    - Expected: `EXIT=0` — both greps FAIL today (0 E2E-Q mentions; the full authoritative path appears nowhere — a bare `quality-gates.md` grep would false-pass on the registry's existing mentions of `shared/includes/quality-gates.md`); generator exits 0 with the new section in place
    - Artifact: `zuvo/proofs/task-8-report.md`
  - G14:
    - Surface: docs
    - Proof: `grep -q -- '--base-url' website/skills/write-e2e.yaml && ! grep -q 'VALIDATION SKIPPED' website/skills/write-e2e.yaml && bash scripts/validate-skill-pages.sh; echo EXIT=$?`
    - Expected: `EXIT=0` — the `--base-url` grep FAILS today (yaml documents the old arg grammar); skill-pages validator green after the update
    - Artifact: `zuvo/proofs/task-8-report.md`
- [ ] Commit: `docs: register E2E-Q v2 by reference in gate-registry, sync CLAUDE.md and website skill page`

### Task 9: eval corpus — evals/write-e2e.evals.json (8 cases)
**Files:** `tests/skill-suite/test-eval-corpus-schema.sh` (one-line SKILLS edit), `evals/write-e2e.evals.json` (new ~450L)
**Surface:** config
**Complexity:** complex
**Dependencies:** Task 7
**Execution routing:** deep implementation tier

- [ ] RED: add `write-e2e` to `SKILLS` at `tests/skill-suite/test-eval-corpus-schema.sh:46` → suite FAILS (corpus absent). Also add an assertion that the write-e2e corpus has ≥8 evals (schema floor is 2).
- [ ] GREEN: author `evals/write-e2e.evals.json` — `skill_name: "write-e2e"`, 8 evals, ALL target-project files synthetic via `fixtures[] {path, content}` (pattern: `evals/write-tests.evals.json`), keys exactly `{id,prompt,expected_output,files,assertions}` + `fixtures`, assertions ≥20 chars each with checkable verbs. Cases: (1) ready-Playwright repo → expects VERIFIED_LOCAL path attempted, causal oracle in generated spec; (2) Vite/Preact without Playwright → preflight GENERATE_ONLY (literal state token asserted), no npx install, spec written + STATIC_CHECKED at most; (3) source module `src/api/client.ts` with `/api/` in path → network mock must NOT glob-intercept it (assert no `**/api/**` route pattern in output); (4) 500-error flow with loader visible pre-request → assertion that the test waits for the decisive event (response/error state), not the initial loader; (5) monorepo two apps no scope → asks/reports scope requirement instead of generating 20 flows; (6) external prod-like `--live https://app.example.com` → mutations BLOCKED with the literal `BLOCKED` state vocabulary emitted, read-only or refusal without `--allow-external-origin`, and zero mutation side-effects in the transcript; (7) dirty worktree with foreign staged changes + new spec → review patch contains the new spec, foreign staged file untouched (registry/staging assertions); (8) accessible UI with zero testids → HIGH-confidence flow still generated using getByRole, no testid-suggestion demands as blocker.
- [ ] Verify: `bash tests/skill-suite/test-eval-corpus-schema.sh`
  Expected: `ALL PASS` (or suite-standard success line), exit 0 — corpus present, schema-valid, ≥8 cases.
- [ ] Acceptance Proof:
  - G13:
    - Surface: config
    - Proof: `python3 -c "import json,sys; d=json.load(open('evals/write-e2e.evals.json')); assert d['skill_name']=='write-e2e'; assert len(d['evals'])>=8; sys.exit(0)"; echo EXIT=$?`
    - Expected: `EXIT=0`
    - Artifact: `zuvo/proofs/task-9-report.md`
- [ ] Commit: `test(write-e2e): 8-case eval corpus — regression protection for preflight, origin safety, causal oracles, network scoping, staging isolation`

### Task 10: smoke runner + full verification + install
**Files:** `tests/smoke-write-e2e-v2.sh` (new, TRACKED — `zuvo/` is gitignored so a runner there could not be committed; the `smoke-*` name keeps it outside `tests/run-all.sh`'s `test-*.sh` globs, consistent with `tests/hooks/smoke-pipeline-entry.sh`), plus Task 4's guard consumption check
**Surface:** config
**Complexity:** standard
**Dependencies:** Task 2, Task 4 (guards consumed here via SMOKE4 install/build), Task 8, Task 9
**Execution routing:** default implementation tier

- [ ] RED: N/A — verification-only task; the runner IS the deliverable and exits non-zero until all prior tasks landed (running it before they land demonstrates the failing state).
- [ ] GREEN: write `tests/smoke-write-e2e-v2.sh` executing SMOKE1-SMOKE4 below, each with explicit exit-status assertions, `set -u`, aggregate `ALL SMOKE PASS`/exit 1. Its output is captured to `zuvo/proofs/smoke-write-e2e-v2.out` (artifact, gitignored — the runner itself is tracked).
- [ ] Verify: `bash tests/smoke-write-e2e-v2.sh`
  Expected: `ALL SMOKE PASS`, exit 0.
- [ ] Acceptance Proof:
  - G15:
    - Surface: config
    - Proof: `mkdir -p zuvo/proofs; ( set -o pipefail; bash tests/smoke-write-e2e-v2.sh | tee zuvo/proofs/smoke-write-e2e-v2.out ); echo EXIT=$?`
    - Expected: `EXIT=0` and the captured output ends `ALL SMOKE PASS` (subshell + pipefail so the runner's status survives the tee and the `EXIT=` line still prints; `mkdir -p` because `zuvo/proofs/` is gitignored and absent on a fresh clone; independent evidence: SMOKE2 re-runs the full tracked suite `ZUVO_TEST_SCOPE=full bash tests/run-all.sh`, not only the runner's own assertions)
    - Artifact: `zuvo/proofs/task-10-report.md` + `zuvo/proofs/smoke-write-e2e-v2.out`
- [ ] Commit: `test: smoke runner for write-e2e V2 — scoped-patch e2e, full suite, validators, 4-platform install checks`

## Whole-feature Smoke Proofs

- **SMOKE1 — scoped-patch end-to-end**
  - Preconditions: mktemp git repo; 1 committed file then modified; 1 brand-new untracked spec; 1 unrelated user-dirty file; something user-staged.
  - Proof: run `scripts/zuvo-home/build-review-patch` no-PATH and with PATH scoping; pipe no-PATH output into `wc -c`.
  - Expected: patch contains new-file content; `git diff --cached` hash unchanged; PATH-scoped run excludes the unrelated file; exit codes 0/0.
  - Artifact: `tests/smoke-write-e2e-v2.sh` output section 1, captured in `zuvo/proofs/smoke-write-e2e-v2.out` (maps to Task 1 RED scenarios 1-2)
- **SMOKE2 — full test suite**
  - Proof: `ZUVO_TEST_SCOPE=full bash tests/run-all.sh`
  - Expected: 0 failures (includes spec-includes literals, callsites test, helpers tests, contract test, eval schema).
  - Artifact: section 2 (maps to Task 2 RED)
- **SMOKE3 — validators + generator**
  - Proof: `bash scripts/validate-skills.sh && bash scripts/validate-skill-pages.sh`
  - Expected: `ERRORS: 0` + `count-consistency: OK (56)` + gate-registry regions fresh; skill pages exit 0.
  - Artifact: section 3 (maps to Task 4/8 REDs)
- **SMOKE4 — install lands everything**
  - Proof: `./scripts/install.sh` then: `[ -x ~/.zuvo/build-review-patch ] && [ -x ~/.zuvo/e2e-preflight ]`; references present under the Claude cache installPath dir and in `~/.codex/skills/write-e2e/references/`; codex dist SKILL.md contains no forbidden tokens.
  - Expected: all checks exit 0.
  - Artifact: section 4 (maps to Task 1 RED scenario 12)

## Reality pre-check (rule 18)

Verified TODAY (2026-07-30) — every task fills a real gap: `git add -u` present at all 12 cited lines; no `scripts/zuvo-home/build-review-patch` or `e2e-preflight` exists; `skills/*/references/` count = 0; gate-registry has 0 E2E-Q mentions; `evals/write-e2e.evals.json` absent; SKILL.md is 489 lines with `VALIDATION SKIPPED` at :382 and testid-first at :209/:313. Nothing in this plan is already implemented.
