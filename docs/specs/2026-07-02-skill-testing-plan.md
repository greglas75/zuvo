# Implementation Plan: Skill-Testing Infrastructure

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (conversation proposal, 2026-07-02: validate-skills lint + run-all aggregate gate + eval corpus + zuvo:skill-eval)
**plan_revision:** 2
**status:** Approved
**Created:** 2026-07-02
**Tasks:** 10
**Estimated complexity:** 3 standard / 7 complex

## Architecture Summary

- **54 skills** actual (`skills/*/SKILL.md`); no `evals/` exists anywhere yet. `refactor`, `write-tests`, `review`, `execute` already have `agents/` subdirs.
- **Validation flow (new):** `dev-push.sh` Step 0 → `tests/run-all.sh` → `scripts/validate-skills.sh` + `tests/hooks/*.sh` + suite e2e entrypoints (`seo/geo/pentest/infra`) + `tests/benchmark-suite/test-*.sh` + `tests/adversarial/run.sh` (full scope only) + `scripts/tests/*.bats` (skip-with-warn — bats NOT installed) + `tests/skill-suite/*`. Failure aborts dev-push **before any mutation** (insertion after marketplace-dir check ~line 39, before `cd`/version-bump ~line 44). `tests/security-corpus` is audit-calibration fixture data, NOT a runnable self-test suite — excluded.
- **Eval flow (new):** `zuvo:skill-eval` → reads `evals/<skill>.evals.json` → executor subagent per case → grader agent scores assertions → report to `zuvo/reports/`. Comparison mode: `git show <ref>:skills/<name>/SKILL.md` to a scratch path. Grader scoring approach is de-risked by a feasibility spike (Task 6) BEFORE corpus/skill investment.
- **Distribution:** `install.sh install_claude()` copies `skills/*/` recursively → `skills/skill-eval/` propagates automatically. `build-codex/cursor-skills.sh` enumerate `agents/` + `references/` — repo-root `evals/` is deliberately **dev-only** (comparison mode needs `.git`, meaningless in installed caches); no build-script changes needed.
- **Pre-existing drift found (ground truth):** CLAUDE.md says "(51 total)" ×2 (category table missing `infra-audit` + entire `leads` row); `docs/skills.md` declares 54 but category rows sum to 53 (`context-audit` missing everywhere). `tests/infra-suite/test-infra-wiring.sh:33` hardcodes `'54 skills'` — breaks on the 55 bump unless updated in the same task. Its `check_count()` already validates 6 locations dynamically but does NOT cover CLAUDE.md.
- **Pre-existing conformance violations** the validator would flag: `execute` H1 = `# Zuvo Execute`; literal `## Argument Parsing` in only 34/54 (20 use equivalents; 4 legit-exempt: brainstorm, receive-review, worktree, using-zuvo); Mandatory File Loading 44/54; `{plugin_root}` exactly 1× (`skills/infra-audit/SKILL.md:376`, redundant fallback); run-logger 52/54 (using-zuvo + worktree exempt).

## Technical Decisions

- **validate-skills.sh:** accumulate-and-report (template: `validate-seo-skill-contracts.sh`), two-tier severity — `ERROR` (gate-blocking: frontmatter, H1, run-logger [exempt: using-zuvo, worktree], `{plugin_root}` ban, include-integrity, count-consistency) vs `WARN` (reported, non-blocking: ArgParse-equivalent missing, Mandatory File Loading missing). `--root <dir>` override (exact precedent: `validate-banned-vocabulary.sh`) so fixtures are testable without mutating the repo. Decomposed into `check_*()` functions ~30-50L each (CQ11 qualitative intent; repo precedent: install.sh 1130L decomposed).
- **ArgParse detection = alternation:** literal `## Argument Parsing` OR `## Arguments` OR `Parse $ARGUMENTS` heading OR `## Input Resolution` OR `## Execution Modes` OR `## Invocation Format`; exempt list: brainstorm, receive-review, worktree, using-zuvo. H1 exempt list: using-zuvo (router).
- **run-all.sh:** opaque-child aggregation copied from `tests/infra-suite/test-suite-e2e.sh` `run_test()` (`set +e` capture, first-line `SKIP:` sniff, PASS/FAIL/SKIP tally) — NOT the seo/geo/pentest fail-fast pattern. `ZUVO_TEST_SCOPE=fast` (default; excludes `tests/adversarial/run.sh`) / `full`; unknown value = loud fail. infra-suite e2e stays in fast (self-skips docker parts). `smoke-fleet-audit.sh`/`smoke-resume.sh` never invoked (require run-dir arg).
- **dev-push gate:** Step 0 block reusing `ok()/fail()/warn()`; escape hatch `ZUVO_SKIP_TESTS=1` (logged via `warn`). install.sh NOT touched — dev-push-only gate (install.sh already runs banned-vocabulary validators; duplicating the full lint doubles cost, zero new coverage).
- **Grader feasibility spike first (adversarial finding, rev 2):** before authoring the corpus, a spike proves a prototype grader prompt can distinguish a known-good from a known-bad transcript on 2-3 hand-crafted cases. Corpus authoring (Task 7) is GATED on spike PASS — a failed spike reshapes the eval design cheaply instead of at task 8 of 10.
- **Eval corpus:** repo-root `evals/<skill>.evals.json`, one file per skill (Team Lead adjustment over Tech Lead's single-file: Anthropic skill-creator schema `{skill_name, evals[]}` is per-skill; smaller diffs). Dev-only, not distributed. Schema documented in NEW `shared/includes/eval-schema.md` (input corpus + report output, paired contract — matches `*-output-schema.md` convention). Assertion-quality heuristic enforced by schema test (rev 2): length ≥20 chars, contains a checkable verb (contains/matches/exits/outputs/calls/writes/creates/commits/dispatches), no vague-qualifier endings ("well", "correctly", "properly"); eval-schema.md documents 2 accepted + 2 rejected assertion examples.
- **skill-eval:** `skills/skill-eval/SKILL.md` + `agents/executor.md` + `agents/grader.md` (15/54 skills already use the agents/ pattern). Routing table: Utility section. Guards: no-`.git` degrade and `git show` ref-missing-skill are **distinct** error paths/messages.
- **Contract tests:** NEW `tests/skill-suite/` sourcing `../seo-suite/assert.sh` (precedent: pentest/benchmark/infra suites). JSON validation via `python3 json.load` (precedented 5× in scripts/).
- **No new dependencies.** bats = optional, skip-with-warn.
- **Out of scope (flagged, not silently dropped):** (a) agent-count prose ("26 specialized agents" vs 48 actual `.md` files) — pre-existing drift, brief covers skill counts only → user-visible note + backlog candidate; (b) rewriting 20 skills' ArgParse / 9 skills' MFL sections → WARN tier + follow-up sweep; (c) `ci/zuvo-skill-tests.yml` CI template — deferred (dev-push gate is the enforcement point in this repo); (d) unifying `test-infra-wiring.sh` `check_count()` with the new validator behind one shared helper — follow-up (this plan keeps both manifests identical by construction, see Task 9); (e) adding a "Bash tooling/validator script" category to `rules/file-limits.md` — plan-reviewer non-blocking recommendation, follow-up.

## Quality Strategy

- Fixture idiom from `tests/hooks/test-pipeline-gate-lib.sh`: `TMP=$(mktemp -d)` + `trap 'rm -rf "$TMP"' EXIT`, real subprocess invocation, env/flag redirection — no mocking.
- validate-skills.sh tested against: (a) real repo (expect 0 ERRORs post-Task-1, known WARNs allowed), (b) broken-fixture tree with one violation per ERROR class, (c) clean fixture (zero false positives).
- run-all.sh mechanics proven via 3 synthetic PASS/FAIL/SKIP fixture scripts — never by running the 60+ real tests in the wiring test. Must assert FAIL-in-#1 does not stop #2/#3.
- dev-push gate: structural assertions (line order, `bash -n`, exact conditional direction `!= "1"`) + awk-fence extraction of the gate block executed against a stub run-all.sh with `ZUVO_SKIP_TESTS` set/unset — catches an inverted conditional that token-presence grep would miss.
- LLM-behavioral eval execution (executor/grader runs) is NOT CI-testable — advisory surface; only the deterministic layers (JSON schema + assertion-quality heuristic, SKILL.md contract) gate. The grader approach itself is de-risked ONCE by the Task 6 spike (human-verifiable artifact), not per-CI-run.
- Active CQ gates: CQ3 (flag/env validation — reject unknown `ZUVO_TEST_SCOPE`, missing `--root` dir), CQ8 (distinct git-show error paths, bats-absent SKIP not silent pass), CQ11 (function decomposition in a 350-450L script), CQ13 (no orphan fixtures), CQ14 (reuse assert.sh + infra-suite `run_test()` pattern; do not reimplement), CQ25 (`--root` flag form, `test-*-contract.sh` naming). CQ1/2/9/15/16/19/21/22/26/27/29 N/A — no typed runtime / transactional store / async I/O / money / API contract / DOM / structured logger / path aliases in bash+markdown deliverable.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G1 | Structural lint of all SKILL.md (frontmatter, H1, ArgParse, MFL, run-logger, {plugin_root}) | deliverable | Task 2 | two-tier ERROR/WARN |
| G2 | Include-integrity check (every ../../shared/includes/ + ../../rules/ ref exists) | deliverable | Task 3 | |
| G3 | Count-consistency check + fix existing drift (CLAUDE.md 51→54, docs/skills.md sum 53→54) | deliverable | Task 1, Task 3, Task 9 | drift is ground truth, verified |
| G4 | Aggregate runner tests/run-all.sh (fast/full, skip-with-warn) | deliverable | Task 4 | |
| G5 | dev-push.sh Step-0 gate + ZUVO_SKIP_TESTS escape | deliverable | Task 5 | before any file mutation |
| G6 | Eval corpus for refactor/write-tests/review/execute (skill-creator schema, pressure scenarios) | deliverable | Task 6 (spike gate), Task 7 | + eval-schema.md include |
| G7 | zuvo:skill-eval skill (executor+grader agents, comparison mode, zuvo/reports/ output) | deliverable | Task 8 | grader design proven by Task 6 |
| G8 | Registration: routing row + all count locations 54→55 + test-infra-wiring.sh literal | deliverable | Task 9 | atomic bump + recovery procedure |
| C1 | No new dependencies; bash/markdown only; bats optional | constraint | Task 2, Task 4 | verified in RED |
| C2 | 4 build targets unaffected; evals dev-only (not distributed) | constraint | Task 7, Task 8 | install.sh recursive copy handles skill-eval |
| C3 | No 20-skill rewrite: pre-existing violations fixed (2 files) or tiered WARN | constraint | Task 1, Task 2 | |
| C4 | Agent-count prose untouched (pre-existing 26-vs-48 drift, out of scope) | constraint | Task 9 | flagged to user |

## Review Trail

- Plan reviewer: revision 1 -> APPROVED (all 9 checks PASS; check 9 N/A — no design artifact; DAG lint: valid, 9 tasks, 0 violations; reviewer independently verified count drift, insertion anchors, include-resolution algorithm on 642 refs)
- Plan reviewer non-blocking note: add a "Bash tooling/validator script" category to rules/file-limits.md in a follow-up (cites install.sh 1130L / validate-seo-skill-contracts.sh 295L precedent) — recorded as out-of-scope item (e)
- Cross-model validation: partial (2/4 providers returned; cursor timed out at 204s; findings from claude-sonnet-4-6, gemini in pool) — 7 findings: 2 CRITICAL, 4 WARNING, 1 INFO
- Cross-model fix dispositions (rev 1 → rev 2):
  - CRITICAL "no grader spike before corpus" → FIXED: new Task 6 feasibility spike, Task 7 gated on spike PASS (rule 14/15)
  - CRITICAL "gate self-blocks between skill-creation and registration" → FIXED: recovery procedure + preflight inventory in Task 9 header; interim-red already disclosed
  - WARNING "Task 1 edits skills with no regression test" → FIXED: executable frontmatter-fence + include-ref checks added to Task 1 Verify (runnable before Task 2 exists)
  - WARNING "assertion quality untestable" → FIXED: heuristic assertion-quality check in Task 7 RED + 2 accepted/2 rejected examples in eval-schema.md
  - WARNING "smoke runner omits skill-eval contract test" → FIXED: explicit named step + per-step artifact sections in Task 10
  - WARNING "Task 9 atomic 8-file commit has no interruption recovery" → FIXED: preflight inventory step (before-snapshot per file) in Task 9
  - INFO "Task 1 commit message lists files not behavior" → applied (message now states the enabling behavior)
- Plan reviewer: revision 2 -> APPROVED (renumbered DAG verified — 60+ "Task N" cross-references checked, 0 stale; coverage matrix + artifact paths consistent; spike gate well-formed per rules 14/15; metadata matches)
- DAG lint: revision 2 -> valid DAG (10 tasks, 0 violations)
- Status gate: Approved (user, 2026-07-02 — "go")

## Task Breakdown

### Task 1: Fix pre-existing conformance violations (execute H1, {plugin_root}, count drift)
**Files:** skills/execute/SKILL.md, skills/infra-audit/SKILL.md, CLAUDE.md, docs/skills.md
**Surface:** docs
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: docs-only task — no test file (per TDD protocol exemption), but the Verify step below includes executable regression checks runnable TODAY (before Task 2/3 exist): frontmatter-fence integrity and include-ref presence on both edited skill files. The current ground truth fails: `grep -c '(54 total)' CLAUDE.md` returns 0 today; docs/skills.md category rows sum to 53. Task 3's validator becomes the permanent regression test for these values.
- [ ] GREEN: (a) `skills/execute/SKILL.md` H1 `# Zuvo Execute` → `# zuvo:execute`; (b) delete the redundant `{plugin_root}` fallback line at `skills/infra-audit/SKILL.md:376` (next `||` clause's cache glob already covers it); (c) CLAUDE.md: both `(51 total)` → `(54 total)`, category table: Infra audits 5→6 (+infra-audit), add `Lead Generation | 1 | leads` row, Utility +context-audit; (d) docs/skills.md: add `context-audit` row to Utility category + description section so category rows sum to declared 54.
- [ ] Verify: `grep -q '^# zuvo:execute' skills/execute/SKILL.md && ! grep -q '{plugin_root}' skills/infra-audit/SKILL.md && [ "$(awk '/^---$/{c++} c==2{exit} END{}' skills/execute/SKILL.md; grep -c '^---$' skills/execute/SKILL.md | head -1)" -ge 2 ] && grep -c '^---$' skills/infra-audit/SKILL.md | grep -qE '^[2-9]' && grep -q 'shared/includes/' skills/infra-audit/SKILL.md && [ "$(grep -c '(54 total)' CLAUDE.md)" = "2" ] && grep -q 'context-audit' docs/skills.md; echo EXIT=$?`
  Expected: `EXIT=0` (H1 fixed, plugin_root gone, both edited files retain intact frontmatter fences and include refs, both CLAUDE.md anchors at 54, context-audit present)
- [ ] Acceptance Proof:
  - G3 (partial: drift fix)
    - Surface: docs
    - Proof: run the Verify command above; additionally awk category-sum over CLAUDE.md skill-categories table == 54 AND over docs/skills.md table == declared Total 54
    - Expected: exit 0 for all three
    - Artifact: `zuvo/proofs/task-1-G3.txt`
- [ ] Commit: `fix pre-existing skill-conformance violations so validate-skills.sh can pass clean on day one: execute H1 casing, infra-audit plugin_root fallback, CLAUDE.md+docs/skills.md count drift 51/53→54`

### Task 2: validate-skills.sh — structural checks (frontmatter, H1, run-logger, {plugin_root}, ArgParse/MFL WARN tier)
**Files:** scripts/validate-skills.sh, tests/skill-suite/test-validate-skills-contract.sh
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 1
**Execution routing:** deep implementation tier

- [ ] RED: `tests/skill-suite/test-validate-skills-contract.sh` (new dir; source `../seo-suite/assert.sh`; mktemp-fixture idiom from tests/hooks/test-pipeline-gate-lib.sh). Build a fixture tree under `$TMP` with one broken skill per ERROR class: (a) missing frontmatter name, (b) name ≠ dir name, (c) H1 ≠ `# zuvo:<name>`, (d) `{plugin_root}` literal in body, (e) missing run-logger reference; plus a fully-clean fixture skill. Assert: `validate-skills.sh --root "$TMP"` exits 1, output contains one `ERROR:` line per broken class and zero for the clean skill; exempt-list fixtures (dirs named `using-zuvo`, `worktree`) produce no run-logger/H1 ERROR; ArgParse-missing and MFL-missing fixtures produce `WARN:` not `ERROR:`; real-repo run (`validate-skills.sh` with default root) exits 0 with `ERRORS: 0` (WARNs allowed). Fails first: script does not exist.
- [ ] GREEN: `scripts/validate-skills.sh` — `--root <dir>` flag (exact form of validate-banned-vocabulary.sh), `ERRORS`/`WARNINGS` counters, `fail_err()`/`fail_warn()`/`pass()`, functions `check_frontmatter()`, `check_h1()` (exempt: using-zuvo), `check_arg_parsing()` (alternation: `## Argument Parsing`|`## Arguments`|`Parse \$ARGUMENTS`|`## Input Resolution`|`## Execution Modes`|`## Invocation Format`; exempt: brainstorm, receive-review, worktree, using-zuvo; WARN), `check_mfl()` (WARN), `check_run_logger()` (exempt: using-zuvo, worktree), `check_plugin_root()`. Summary block + `exit $((ERRORS>0))`. Accumulate-and-report — `fail_err` never exits.
- [ ] Verify: `bash tests/skill-suite/test-validate-skills-contract.sh && bash scripts/validate-skills.sh; echo EXIT=$?`
  Expected: contract test prints final `pass` line; real-repo run prints `ERRORS: 0` and `EXIT=0`
- [ ] Acceptance Proof:
  - G1
    - Surface: backend-logic
    - Proof: `bash tests/skill-suite/test-validate-skills-contract.sh` (fixture detects all 5 ERROR classes + 2 WARN classes + exemptions) then `bash scripts/validate-skills.sh` on real repo
    - Expected: both exit 0; fixture-phase output shows ≥5 distinct ERROR detections; real repo `ERRORS: 0`
    - Artifact: `zuvo/proofs/task-2-G1.txt`
  - C1, C3
    - Surface: backend-logic
    - Proof: `head -5 scripts/validate-skills.sh | grep -q '#!/usr/bin/env bash'` and no node/npm/npx invocation in the script; WARN tier present for ArgParse/MFL
    - Expected: exit 0 (pure bash), no mass rewrite forced
    - Artifact: `zuvo/proofs/task-2-C1C3.txt`
- [ ] Commit: `add validate-skills.sh structural lint: frontmatter/H1/run-logger/plugin_root as blocking ERRORs, ArgParse/MFL as WARN tier, --root fixture override`

### Task 3: validate-skills.sh — include-integrity + count-consistency checks
**Files:** scripts/validate-skills.sh, tests/skill-suite/test-validate-skills-contract.sh
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 2 (same files — serialized), Task 1 (real counts must be fixed for real-repo pass)
**Execution routing:** deep implementation tier

- [ ] RED: extend `test-validate-skills-contract.sh`: fixture with a SKILL.md referencing `../../shared/includes/does-not-exist.md` → ERROR with the dangling path in the message; fixture repo-root with a mini CLAUDE.md/docs/skills.md/plugin.json set where one count is off by one → ERROR naming the drifted file; consistent fixture → no ERROR. Real repo: count check reconciles at 54 (post-Task-1) → exit 0. Include-resolution must resolve `../../shared/includes/*` and `../../rules/*` tokens against repo root regardless of the referencing file's depth (skills/*/agents/*.md refs would false-positive under naive dirname-relative resolution — 87 false positives measured). Fails first: new checks not implemented.
- [ ] GREEN: `check_include_integrity()` — extract every `../../shared/includes/*.md` and `../../rules/*.md` token from `skills/**/*.md`, resolve against `$ROOT/shared/includes/` + `$ROOT/rules/`, missing file = ERROR. `check_count_consistency()` — per-file anchored extraction: plugin.json ×2 + package.json `grep -o '[0-9]\+ skills'` on the description line (codex longDescription checked separately); docs/skills.md intro count + category-column awk-sum + bold Total row; using-zuvo banner regex + routing-table unique `zuvo:<name>` token count scoped `## Routing Table`→next `## `; CLAUDE.md both `(N total)` anchors + its category-table sum (no Total row there); all must equal `ls -d skills/*/ | wc -l`. Any mismatch = ERROR (this is the exact regression class the tool exists to catch). Skip count-consistency entirely under `--root` unless the fixture provides the count files (guard: file-exists per source).
- [ ] Verify: `bash tests/skill-suite/test-validate-skills-contract.sh && bash scripts/validate-skills.sh; echo EXIT=$?`
  Expected: `EXIT=0`, real-repo output shows `count-consistency: OK (54)` and `include-integrity: OK`
- [ ] Acceptance Proof:
  - G2
    - Surface: backend-logic
    - Proof: fixture with dangling include ref → run validator → assert ERROR line contains the missing path; real repo → 0 include errors across all ~642 refs
    - Expected: fixture exit 1 with named path; real repo exit 0
    - Artifact: `zuvo/proofs/task-3-G2.txt`
  - G3 (checker half)
    - Surface: backend-logic
    - Proof: off-by-one fixture → ERROR naming file; real repo → all 8 extracted numbers == 54
    - Expected: fixture detects; real repo reconciles
    - Artifact: `zuvo/proofs/task-3-G3.txt`
- [ ] Commit: `add include-integrity and count-consistency checks to validate-skills.sh: dangling include refs and any skill-count drift across 6 files are blocking ERRORs`

### Task 4: tests/run-all.sh aggregate runner (fast/full scopes, skip-with-warn)
**Files:** tests/run-all.sh, tests/skill-suite/test-run-all-wiring.sh
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 3 (invokes the completed validator; wiring test asserts its existence)
**Execution routing:** deep implementation tier

- [ ] RED: `tests/skill-suite/test-run-all-wiring.sh`: (a) every suite path run-all references exists on disk; (b) 3 synthetic fixture scripts (exit 0 / exit 1 / `echo "SKIP: x"`) fed through the aggregator via a fixture suite dir → summary shows PASS=1 FAIL=1 SKIP=1, exit 1, and — critical — the FAIL in script #1 did not prevent #2/#3 from running (assert all three appear in output); (c) `ZUVO_TEST_SCOPE=fast` output does NOT list tests/adversarial/run.sh, `=full` does; (d) `ZUVO_TEST_SCOPE=bogus` exits non-zero with a loud message (CQ3); (e) with bats absent (`command -v bats` false on this machine) the .bats group prints a skip warning, not FAIL; (f) `smoke-fleet-audit.sh`/`smoke-resume.sh` never appear in any scope's invocation list. Fails first: run-all.sh missing.
- [ ] GREEN: `tests/run-all.sh` — reuse infra-suite `run_test()` idiom verbatim (`set +e` capture + first-line `SKIP:` sniff + PASS/FAIL/SKIP tally; CQ14: copy the proven ~35-line pattern, cite source in a comment). Child list (fast): scripts/validate-skills.sh, tests/hooks/*.sh, tests/{seo,geo,pentest,infra}-suite/test-suite-e2e.sh, tests/benchmark-suite/test-*.sh, tests/skill-suite/test-*.sh, scripts/tests/*.bats (via bats if installed, else skip-warn). Full adds tests/adversarial/run.sh. `ZUVO_TEST_SCOPE` validation, per-suite summary table, exit 1 iff any FAIL. Support an internal suite-dir override (env `ZUVO_RUNALL_SUITES_DIR`) so the wiring test injects fixtures — mirrors `--root` philosophy.
- [ ] Verify: `bash tests/skill-suite/test-run-all-wiring.sh; echo EXIT=$?`
  Expected: `EXIT=0`; test output shows the PASS=1/FAIL=1/SKIP=1 synthetic tally and scope-differentiation assertions
- [ ] Acceptance Proof:
  - G4
    - Surface: backend-logic
    - Proof: wiring test (above) + one real fast run `ZUVO_TEST_SCOPE=fast bash tests/run-all.sh`
    - Expected: wiring test exit 0; real fast run exits 0 with per-suite summary (any FAIL here is a real repo defect to fix before commit)
    - Artifact: `zuvo/proofs/task-4-G4.txt`
  - C1
    - Surface: backend-logic
    - Proof: run on this machine where bats is absent — .bats group reports SKIP with warning
    - Expected: skip-warn line present, overall exit unaffected by bats absence
    - Artifact: `zuvo/proofs/task-4-C1.txt`
- [ ] Commit: `add tests/run-all.sh aggregate runner: fast/full scopes, infra-suite aggregation pattern, bats skip-with-warn, loud unknown-scope failure`

### Task 5: dev-push.sh Step-0 test gate with ZUVO_SKIP_TESTS escape
**Files:** scripts/dev-push.sh, tests/skill-suite/test-dev-push-gate.sh
**Surface:** config
**Complexity:** complex
**Dependencies:** Task 4
**Execution routing:** deep implementation tier

- [ ] RED: `tests/skill-suite/test-dev-push-gate.sh`: (a) structural — the gate block's line number is greater than the marketplace-dir check and **less than** the `# Step 1` marker and the first `cd "$ZUVO_DIR"` (gate fires before any mutation); (b) `bash -n scripts/dev-push.sh`; (c) conditional direction — assert the literal `!= "1"` (or equivalent `[[ "${ZUVO_SKIP_TESTS:-}" != "1" ]]`) appears in the gate block, not an inverted form; (d) behavioral via awk-fence extraction (idiom: tests/adversarial/test-skill-retro-wiring.sh T7.3) — extract the fenced gate block, run it against a stub `tests/run-all.sh` that exits 1: without ZUVO_SKIP_TESTS → block exits non-zero; with ZUVO_SKIP_TESTS=1 → block passes and prints the skip warning. Fails first: gate block absent.
- [ ] GREEN: insert fenced Step 0 block (markers `# >>> zuvo:test-gate` / `# <<< zuvo:test-gate` for awk extraction) after the marketplace-dir check, before Step 1: `if [[ "${ZUVO_SKIP_TESTS:-}" != "1" ]]; then bash "$ZUVO_DIR/tests/run-all.sh" || fail "Tests failed — fix or ZUVO_SKIP_TESTS=1 to bypass (logged)"; else warn "Step 0 SKIPPED (ZUVO_SKIP_TESTS=1)"; fi` reusing existing `ok()/fail()/warn()`.
- [ ] Verify: `bash tests/skill-suite/test-dev-push-gate.sh && bash -n scripts/dev-push.sh; echo EXIT=$?`
  Expected: `EXIT=0`; test output shows both branch behaviors (blocked without skip, warned with skip)
- [ ] Acceptance Proof:
  - G5
    - Surface: config
    - Proof: awk-fence extraction runs the real gate block against failing stub run-all with and without ZUVO_SKIP_TESTS=1
    - Expected: exit non-zero (blocked) vs exit 0 + skip warning
    - Artifact: `zuvo/proofs/task-5-G5.txt`
- [ ] Commit: `gate dev-push.sh on tests/run-all.sh before any mutation: Step 0 with ZUVO_SKIP_TESTS=1 escape hatch, fenced for behavioral testing`

### Task 6: Grader feasibility spike (always-run gate)
**Files:** tests/skill-suite/spike-grader-feasibility.md (spike protocol + results record)
**Surface:** docs
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

> Feasibility-spike task (adversarial CRITICAL, rev 2; task-authoring rule 14). Always-executed gate (rule 15): it MUST print an explicit `[DECISION: grader-feasible] → PASS` or `[DECISION: grader-infeasible] → BLOCKED` marker. A BLOCKED decision stops Tasks 7-8 and returns to the user with the failed transcript evidence — reshaping the eval design cheaply instead of after the corpus and skill are built.

- [ ] RED: no spike artifact exists; the grader concept (LLM scores a transcript against assertions) is unproven in this repo. Failing state = absence of `tests/skill-suite/spike-grader-feasibility.md` with a recorded PASS decision.
- [ ] GREEN: author 2-3 hand-crafted eval cases inline in the spike doc (one per shape: refactor spine-skip, write-tests bug-parking); write one known-good and one known-bad synthetic transcript per case; run a prototype grader prompt (draft of agents/grader.md scoring instructions) via a fresh subagent over each transcript; record per-assertion verdicts. Acceptance bar: grader correctly separates good from bad on ALL hand-crafted cases with zero inverted verdicts, and produces per-assertion evidence strings (not bare pass/fail). Record raw outputs + `[DECISION: ...]` marker in the spike doc.
- [ ] Verify: `grep -q '\[DECISION: grader-feasible\] → PASS' tests/skill-suite/spike-grader-feasibility.md; echo EXIT=$?`
  Expected: `EXIT=0` (or the run stops here with BLOCKED surfaced to the user — that is a valid, plan-reshaping outcome, not a silent skip)
- [ ] Acceptance Proof:
  - G6 (gate half)
    - Surface: docs
    - Proof: spike doc contains both transcripts, grader outputs, per-assertion evidence, and the explicit decision marker
    - Expected: PASS marker present; good/bad separation documented with zero inversions
    - Artifact: `zuvo/proofs/task-6-spike.txt` (copy of decision section)
- [ ] Commit: `prove grader feasibility on hand-crafted good/bad transcripts before investing in eval corpus and skill-eval (explicit gate decision recorded)`

### Task 7: eval-schema include + eval corpus for refactor/write-tests/review/execute
**Files:** shared/includes/eval-schema.md, evals/refactor.evals.json, evals/write-tests.evals.json, evals/review.evals.json, evals/execute.evals.json, tests/skill-suite/test-eval-corpus-schema.sh
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 6 (GATED on spike PASS — grader design proven before corpus investment)
**Execution routing:** deep implementation tier

- [ ] RED: `tests/skill-suite/test-eval-corpus-schema.sh` — python3 json.load validation (precedented; no new dep): all 4 files exist and parse; required keys `{skill_name, evals:[{id, prompt, expected_output, files, assertions}]}`; `skill_name` matches filename stem; `id` unique per file; `assertions` non-empty array of strings; ≥2 evals per skill; **assertion-quality heuristic (adversarial WARNING, rev 2): every assertion ≥20 chars, contains ≥1 checkable verb (contains/matches/exits/outputs/calls/writes/creates/commits/dispatches), does NOT end with a vague qualifier (well/correctly/properly)**; malformed-JSON fixture fails loudly with the file named. Fails first: files missing.
- [ ] GREEN: `shared/includes/eval-schema.md` — input corpus schema + eval-report output schema (report path convention `zuvo/reports/skill-eval-<skill>-<date>.md/.json`), Anthropic skill-creator alignment note, **2 accepted + 2 rejected assertion examples** (e.g. accepted: "transcript contains a characterization-test commit BEFORE any file-move commit"; rejected: "the skill performed well"). Four corpora with 2-3 pressure scenarios each, sourced from documented incidents: refactor — large-file refactor tempting a "condensed 5-step" spine skip (assert: artifact-proof + characterization tests before movement); write-tests — target file contains a real prod bug (assert: bug fixed in-run via stacked commit, NOT backlogged); review — TIER2+ diff (assert: sub-agents actually dispatched, not self-review); execute — approved plan present (assert: execution goes through plan tasks with review gates, no hand-roll). `expected_output` = observable behavior, `assertions` = objectively checkable statements per acceptance-proof discipline.
- [ ] Verify: `bash tests/skill-suite/test-eval-corpus-schema.sh; echo EXIT=$?`
  Expected: `EXIT=0`, output lists 4 validated corpora with eval counts and 0 assertion-quality rejections
- [ ] Acceptance Proof:
  - G6
    - Surface: docs
    - Proof: schema test (above); additionally `python3 -c "import json,sys; d=json.load(open('evals/refactor.evals.json')); sys.exit(0 if d['skill_name']=='refactor' and len(d['evals'])>=2 else 1)"`
    - Expected: exit 0
    - Artifact: `zuvo/proofs/task-7-G6.txt`
  - C2 (dev-only)
    - Surface: config
    - Proof: build scripts contain no evals/ handling (`grep -c 'evals/' scripts/build-codex-skills.sh scripts/build-cursor-skills.sh` → 0 each); `bash -n scripts/install.sh` (untouched)
    - Expected: 0 matches ×2, install.sh syntax-clean and unmodified
    - Artifact: `zuvo/proofs/task-7-C2.txt`
- [ ] Commit: `add eval corpus (4 skills, skill-creator schema) + eval-schema.md: incident-derived pressure scenarios with heuristic-enforced checkable assertions, dev-only (not distributed)`

### Task 8: zuvo:skill-eval skill (SKILL.md + executor/grader agents)
**Files:** skills/skill-eval/SKILL.md, skills/skill-eval/agents/executor.md, skills/skill-eval/agents/grader.md, tests/skill-suite/test-skill-eval-skill-contract.sh
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 7 (references eval-schema.md + corpus paths), Task 6 (grader.md codifies the spike-proven prompt), Task 2 (contract test runs validator structural checks)
**Execution routing:** deep implementation tier

- [ ] RED: `tests/skill-suite/test-skill-eval-skill-contract.sh` (template: test-pentest-skill-contract.sh): SKILL.md exists; frontmatter name `skill-eval`; H1 `# zuvo:skill-eval`; Argument Parsing table with `[skill-name]`, `--compare <ref>`, `--all-evals`; Mandatory File Loading references `eval-schema.md` + `report-output-location.md` + `run-logger.md`; phases reference `agents/executor.md` + `agents/grader.md` and both files exist; grader.md contains the spike-proven scoring instructions (per-assertion text/passed/evidence fields); output to `zuvo/reports/`; the no-`.git` guard message and the `git show` ref-missing-skill guard message exist and are **distinct strings** (grep both, assert inequality); comparison mode materializes old version under `zuvo/context/`. NOTE: repo-wide count-consistency is expected RED between this task and Task 9 (actual dirs 55 vs declared 54) — the contract test therefore runs `validate-skills.sh --root` against a fixture containing only skill-eval for structural checks, NOT the full real-repo count check. Fails first: skill dir missing.
- [ ] GREEN: author SKILL.md per canonical template (skills/build/SKILL.md structure): Phase 0 bootstrap + retro marker, Phase 1 load target evals/<skill>.evals.json (fail loud if missing/malformed), Phase 2 dispatch executor sub-agent per eval case (fresh context, target SKILL.md content + eval prompt), Phase 3 grader agent scores each transcript against assertions (per-assertion pass/fail + evidence), Phase 4 comparison mode (`--compare <ref>`: `git show <ref>:skills/<name>/SKILL.md` → `zuvo/context/skill-eval-baseline-<name>.md`; distinct guards: not-a-git-repo → degrade with message A; ref-or-path-missing → message B), Phase 5 report to `zuvo/reports/` + run-logger append. executor.md/grader.md follow existing agents/ frontmatter conventions; grader.md scoring section = the Task 6 spike-validated prompt.
- [ ] Verify: `bash tests/skill-suite/test-skill-eval-skill-contract.sh; echo EXIT=$?`
  Expected: `EXIT=0` with final `pass skill-eval-skill-contract` line
- [ ] Acceptance Proof:
  - G7
    - Surface: docs
    - Proof: contract test (above) — structure, agent files, spike-derived grader content, distinct guard paths, report location
    - Expected: exit 0
    - Artifact: `zuvo/proofs/task-8-G7.txt`
- [ ] Commit: `add zuvo:skill-eval skill: executor+grader agent pipeline over evals corpus, old-vs-new comparison via git show, reports to zuvo/reports/`

### Task 9: Register skill-eval — routing row + atomic count bump 54→55 (incl. test-infra-wiring literal)
**Files:** skills/using-zuvo/SKILL.md, .claude-plugin/plugin.json, .codex-plugin/plugin.json, package.json, docs/skills.md, CLAUDE.md, tests/infra-suite/test-infra-wiring.sh, shared/includes/report-output-location.md
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 8 (skill must exist), Task 3 (count checker verifies the bump), Task 1 (builds on corrected baseline values)
**Execution routing:** deep implementation tier

> **Oversize justification (8 files):** every edit is a single-line prose/number change keyed to ONE atomic event (skill count 54→55). Any commit boundary inside this set leaves either `validate-skills.sh` count-consistency or `test-infra-wiring.sh` red — the files are inseparable by the invariant this plan itself introduces. Interim state note: between Task 8's commit and this one, count-consistency is expectedly red (dev-push gate fires only at push, after all tasks).
> **Recovery procedure (adversarial CRITICAL, rev 2):** STEP 0 of this task is a preflight inventory — print the current declared count extracted from each of the 8 files (one grep per file) into `zuvo/proofs/task-9-preflight.txt` BEFORE editing. If execution is interrupted mid-task, re-run the inventory and diff against the preflight snapshot to see exactly which files were already bumped; complete only the un-bumped remainder, then run the Verify pair. If a dev-push is needed while the repo sits between Task 8 and Task 9 (session lost, watchdog resume), finish THIS task first — never push with ZUVO_SKIP_TESTS=1 to work around a half-registered skill.
- [ ] RED: `bash scripts/validate-skills.sh` currently FAILS count-consistency (actual 55 vs declared 54) and `bash tests/infra-suite/test-infra-wiring.sh` fails on the `'54 skills'` literal at line 33 — both red before this task, green after. This is the real regression pair; no new test file (registration is data, guarded by two existing checkers).
- [ ] GREEN: preflight inventory (see recovery procedure) → then: using-zuvo banner `54 skills`→`55 skills` + routing row in Priority 4 Utility: `| Evaluate/benchmark a skill against its eval corpus, compare skill versions | zuvo:skill-eval |`; plugin.json ×2 + package.json description `54 skills`→`55 skills` (codex longDescription too); docs/skills.md: intro 54→55, skill-eval row (Utility), Total 54→55, Utility count +1; CLAUDE.md both `(54 total)`→`(55 total)` + Utility row +skill-eval; `tests/infra-suite/test-infra-wiring.sh:33` `'54 skills'`→`'55 skills'`; report-output-location.md reports/ row + skill-eval. **Do NOT touch agent-count prose ("26 specialized agents") — pre-existing 26-vs-48 drift, separately flagged.**
- [ ] Verify: `bash scripts/validate-skills.sh && bash tests/infra-suite/test-infra-wiring.sh; echo EXIT=$?`
  Expected: `EXIT=0`; validator prints `count-consistency: OK (55)`
- [ ] Acceptance Proof:
  - G8
    - Surface: docs
    - Proof: both checkers green (command above); `grep -q 'zuvo:skill-eval' skills/using-zuvo/SKILL.md`; preflight snapshot exists
    - Expected: exit 0 ×3; `zuvo/proofs/task-9-preflight.txt` non-empty
    - Artifact: `zuvo/proofs/task-9-G8.txt`
  - C4
    - Surface: docs
    - Proof: `grep -q '26 specialized agents' .claude-plugin/plugin.json` (unchanged)
    - Expected: exit 0 — agent prose untouched
    - Artifact: `zuvo/proofs/task-9-C4.txt`
- [ ] Commit: `register zuvo:skill-eval: routing row + atomic 54→55 across all count locations incl. test-infra-wiring literal; agent-count prose deliberately untouched (pre-existing drift)`

### Task 10: Whole-feature smoke runner
**Files:** tests/skill-suite/smoke-skill-testing.sh
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 5 (gate), Task 9 (registration complete)
**Execution routing:** default implementation tier

- [ ] RED: `tests/skill-suite/smoke-skill-testing.sh` missing; SMOKE proofs below unrunnable as a single artifact-producing command.
- [ ] GREEN: author the smoke runner with **explicitly named, individually-sectioned steps** (adversarial WARNING, rev 2 — each step gets its own header + exit code in the artifact so a failure is attributable): (1) `ZUVO_TEST_SCOPE=fast bash tests/run-all.sh`, (2) `bash scripts/validate-skills.sh`, (3) `bash tests/infra-suite/test-infra-wiring.sh`, (4) `bash tests/skill-suite/test-dev-push-gate.sh` (fence branch behavior), (5) `bash tests/skill-suite/test-eval-corpus-schema.sh`, (6) `bash tests/skill-suite/test-skill-eval-skill-contract.sh`; tees combined output + per-step exit codes to `zuvo/proofs/smoke-skill-testing.txt`; exits non-zero if any step fails.
- [ ] Verify: `bash tests/skill-suite/smoke-skill-testing.sh; echo EXIT=$?; test -s zuvo/proofs/smoke-skill-testing.txt && echo ARTIFACT=ok`
  Expected: `EXIT=0` and `ARTIFACT=ok`; artifact shows 6 named sections each with exit 0
- [ ] Acceptance Proof:
  - SMOKE1/SMOKE2/SMOKE3 (below)
    - Surface: integration
    - Proof: run the smoke runner
    - Expected: all 6 steps green, per-step sections in artifact
    - Artifact: `zuvo/proofs/smoke-skill-testing.txt`
- [ ] Commit: `add whole-feature smoke runner for skill-testing infra: 6 named steps (run-all fast, validator, wiring, gate fence, corpus schema, skill contract) in one attributable artifact`

## Whole-feature Smoke Proofs

- **SMOKE1 — full fast-scope run is green on the final repo**
  - Preconditions: all 10 tasks committed
  - Proof: `ZUVO_TEST_SCOPE=fast bash tests/run-all.sh`
  - Expected: exit 0; summary lists validate-skills + hooks + 4 suite e2e + benchmark + skill-suite (incl. skill-eval contract test); bats group SKIP-warned on this machine
  - Artifact: `zuvo/proofs/smoke-skill-testing.txt` (section 1)
  - Per-task RED mapping: Task 4 RED (aggregation mechanics), Task 3 RED (validator green on real repo), Task 8 RED (contract test in suite glob)
- **SMOKE2 — dev-push gate blocks and bypasses correctly without mutating the repo**
  - Preconditions: Task 5 fence markers present
  - Proof: awk-fence extraction of the Step-0 block run against a stub failing run-all, with and without `ZUVO_SKIP_TESTS=1`
  - Expected: blocked (non-zero) without skip; warned pass with skip; `git status --porcelain` unchanged by the test
  - Artifact: `zuvo/proofs/smoke-skill-testing.txt` (section 4)
  - Per-task RED mapping: Task 5 RED (d)
- **SMOKE3 — count-consistency invariant holds end-to-end at 55**
  - Preconditions: Task 9 committed
  - Proof: `bash scripts/validate-skills.sh && bash tests/infra-suite/test-infra-wiring.sh`
  - Expected: both exit 0; validator prints `count-consistency: OK (55)`
  - Artifact: `zuvo/proofs/smoke-skill-testing.txt` (sections 2-3)
  - Per-task RED mapping: Task 9 RED (both checkers red→green), Task 3 RED (drift fixture detection)
