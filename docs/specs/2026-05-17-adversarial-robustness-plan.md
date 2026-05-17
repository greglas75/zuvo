# Implementation Plan: Adversarial Robustness (A1 + A2)

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief
**plan_revision:** 3
**status:** Approved
**Created:** 2026-05-17
**Tasks:** 13 (11 ACs + 1 G covering deliverables)
**Estimated complexity:** 1 complex (test harness foundation) + 12 standard

## Architecture Summary

Adversarial review pipeline = `bin/adversarial-review` → `scripts/adversarial-review.sh` (1297 LOC) → per-provider `run_*()` functions (each already wrapped in GNU `timeout`) → JSON or text assembly → caller skills.

Current friction (per retros, ~55 hits):
- Timeout exit 124 only fires when ALL providers fail; multi-mode retry block (lines 970-1064) doubles worst-case wall-clock by re-running on truncated input
- JSON `status` field hardcoded to `"ok"` whenever any result exists — partial timeouts invisible to callers
- Host self-exclusion can silently leave only 1 provider; `--rotate` is stateless and re-picks the same provider on successive calls
- 4 flagship caller skills (review, brainstorm, plan, write-article) handle timeout/partial-degradation inconsistently
- Zero existing test coverage for the script

Component dependencies: skills → bash CLI → script → provider CLIs; protocol includes (`adversarial-loop.md`, `adversarial-loop-docs.md`) are reference-only (not loaded at runtime). Pre-commit hook `hooks/pre-commit-adversarial-gate.sh` checks artifact presence + key-value header only, not JSON status — safe surface for additive JSON changes.

## Technical Decisions

- **D1 — Remove retry path** (`scripts/adversarial-review.sh:970-1064` deleted). First timeout = final timeout. Cuts worst-case wall-clock in half. Truncated-retry was probabilistic recovery; replaced by caller-side `--rotate` opt-in.
- **D2 — Partial status + always-present counts.** JSON gains `attempted_count` and `timeout_count` (always present). Status enum extends with `"partial"` (0 < success < attempted) alongside existing `"ok"` / `"timeout"` / `"error"`. **Field semantics (unchanged from current script):** `attempted_count` = providers dispatched after host/exclude filtering; `provider_count` = providers that produced usable output (success count, NOT total dispatched); `timeout_count` = providers killed by GNU `timeout`. The three relate as: `attempted_count = provider_count + timeout_count + other_failures`.
- **D3 — Hard refusal on single-provider + `--multi`/`--rotate`.** Post-exclusion provider count < 2 with diversity requested → exit non-zero with `status: "single_provider_only"` and stderr guidance. `--single` and `--provider <name>` unaffected.
- **D4 — `--exclude-last <name>` env-var handoff.** Stateless cross-call rotation: caller extracts `providers_used[0]` from prior JSON, threads back via flag. No sidecar file.
- **D5 — Spec + 4 flagship skills patched in same release.** `shared/includes/adversarial-loop*.md` + `skills/{review,brainstorm,plan,write-article}/SKILL.md`. Remaining 5 mandatory-integration skills (build, write-tests, execute, refactor, debug, fix-tests, receive-review, write-e2e, seo-fix) adopt asynchronously.
- **D6 — Additive JSON only.** No schema versioning. Old consumers that match `status == "ok"` correctly stop matching `"partial"`. Pre-commit hook unaffected (header-only check).

## Quality Strategy

**Test layers:**
- **L1 unit (custom shell harness):** `tests/adversarial/run.sh` + `tests/adversarial/assert.sh` + 4 mock provider stubs (`mock-success`, `mock-timeout`, `mock-fail`, `mock-hang`). Mock injection via `ZUVO_REVIEW_TEST_PROVIDERS` escape hatch added to script.
- **L2 integration:** docs-only grep assertions for spec includes + flagship SKILL.md updates (validates rollout).
- **L3 smoke:** 3 whole-feature scenarios at end (mixed pass/fail, hard refusal, cross-call rotation).

**Critical risks:**
1. **D2 + D5 decoupling** — if script ships before skills, callers checking `status == "ok"` silently skip `"partial"` results. Mitigation: same-release rollout enforced by Task dependencies.
2. **D1 backward-compat** — large-diff callers lose implicit retry. Mitigation: release notes + per-skill `--exclude-last` rotation pattern doc.
3. **D3 behavioral break** — single-vendor environments hit hard refusal. Mitigation: clear stderr message + `--single` workaround.

**CQ gates to watch:** CQ16 (error paths — 3 new), CQ22 (dead code — ensure retry-block cleanup is complete), CQ23 (test coverage — was 0%, now ≥ 80% of new behavior).

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| AC1 | D1: all-timeout case exits 124 within `PROVIDER_TIMEOUT + 5s` (no retry-double-wait) | requirement | Task 3 | Verified via mock-timeout single-provider |
| AC2 | D1: partial-timeout case (some succeed, some timeout) keeps script exit 0 and emits succeeded results | requirement | Task 3 | Tied to AC4 partial status |
| AC3 | D2: JSON always contains `attempted_count` and `timeout_count` fields, including on full success | requirement | Task 2 | |
| AC4 | D2: JSON `status == "partial"` when 0 < provider_count < attempted_count | requirement | Task 2 | |
| AC5 | D3: when post-exclusion provider count < 2 AND mode in (--multi, --rotate), script exits non-zero with stderr containing `single_provider_only` | requirement | Task 4 | --single / --provider unaffected |
| AC6 | D4: `--exclude-last <name>` filters that provider from candidates, validates input, appears in `--help` | requirement | Task 5 | |
| AC7 | D5: spec includes (`adversarial-loop.md`, `adversarial-loop-docs.md`) document partial-status handling, single_provider_only signal, exclude-last pattern | deliverable | Task 7, Task 8 | |
| AC8 | D5: 4 flagship skills' adversarial sections explicitly branch on `status: "partial"` and `single_provider_only` | deliverable | Task 9, 10, 11, 12 | |
| AC9 | D6: existing pre-commit hook accepts new artifacts; old `status == "ok"` consumer pattern does NOT match `"partial"` | constraint | Task 13 | Backward-compat contract test |
| AC10 | Observability: `~/.zuvo/adversarial.log` summary row includes `attempted_count` and `timeout_count` per invocation | requirement | Task 6 | TSV append |
| AC11 | D2: non-timeout failure case (1 success + 1 hard-fail provider) yields `status: "partial"`, `attempted_count = 2`, `timeout_count = 0`, `provider_count = 1` | requirement | Task 2 | Distinguishes failure-mode from timeout-mode |
| G1 | Test harness for adversarial-review.sh exists and is runnable | deliverable | Task 1, Task 13 | Foundation for all other RED stages + final smoke gate |

## Review Trail
- Plan reviewer: revision 1 → APPROVED (3 non-blocking notes; 2 applied as task notes — Task 1 /tmp/empty.txt prereq, Task 13 explicit Task 1 dependency; 1 already covered — exit code 3 documented)
- Cross-model validation (cursor-agent, --mode plan): revision 1 → 1 CRITICAL + 4 WARNING + 2 INFO. Fixed in revision 2:
    - CRITICAL (Tasks 3-5 unserialized script edits) → added explicit T3, T4 dependency chains
    - WARNING (Tasks 9-12 missing Task 8 dep) → added Task 8 to all four
    - WARNING (SMOKE1-3 not in a task) → wrapped into Task 13 as `test-smoke-all.sh`
    - WARNING (SMOKE1 field-name ambiguity) → field semantics paragraph added under Technical Decisions
    - WARNING (wrapper bin/adversarial-review unmentioned) → added Execution Note confirming pass-through
    - 2 INFO ignored (Task 1 GREEN snippets acceptable for foundation; Task 13 hook precondition added inline)
- Plan reviewer: revision 2 → APPROVED (all rev 1 cross-model findings resolved; no new issues)
- Cross-model validation (cursor-agent, --mode plan): revision 2 → 0 CRITICAL, 4 WARNING, 2 INFO. Applied in revision 3:
    - WARNING (Task 1 RED referenced non-tracked `test-harness.sh`) → RED rewritten to invoke `run.sh --self-test` directly
    - WARNING (no AC for non-timeout failure path) → added AC11 + Task 2 test case 5 (mock-success + mock-fail) + Acceptance Proof block
    - WARNING (D1 has no rollback narrative) → added Rollback & Operational Notes section
    - WARNING (Tasks 9-12 grep-only validation) → documented intentional design under Operational Notes; full skill-level behavioral test deferred to next `zuvo:review`
    - 2 INFO (Task 1 GREEN over-specifies; Tasks 9-12 could batch) → ignored — foundation task scaffold acceptable; per-skill commit granularity preferred for git history
- Cross-model validation cap reached (2 of 2 runs per `adversarial-loop-docs.md`). No further iteration.
- Plan reviewer: revision 3 → (single iteration following cap; not re-run since edits are surgical and address only flagged findings)
- Status gate: **Approved** (user confirmed via `kontynuj` on 2026-05-17)

## Task Breakdown

### Task 1: Test harness foundation + mock provider stubs + script escape hatch
**Files:**
- `tests/adversarial/run.sh` (new)
- `tests/adversarial/assert.sh` (new)
- `tests/adversarial/mocks/mock-success` (new)
- `tests/adversarial/mocks/mock-timeout` (new)
- `tests/adversarial/mocks/mock-fail` (new)
- `tests/adversarial/mocks/mock-hang` (new)
- `scripts/adversarial-review.sh` (add `ZUVO_REVIEW_TEST_PROVIDERS` honored in `detect_providers()`, ~line 521)
**Surface:** integration
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

> Note (reviewer rev1): the harness `run.sh --self-test` MUST ensure `/tmp/empty.txt` exists (used as a no-op input file by every downstream test). Idempotent `touch /tmp/empty.txt` at harness startup.

- [ ] RED: Run `bash tests/adversarial/run.sh --self-test` directly. Assertion: harness returns exit 0 and prints `harness: ok` on stdout. Initially fails because `run.sh` doesn't exist.
- [ ] GREEN:
  - Mocks: each is a 1-3 line bash script. `mock-success` prints `{"findings":[]}` and exits 0. `mock-timeout` sleeps `${MOCK_HANG_SECONDS:-300}` (designed to be killed by GNU timeout). `mock-fail` exits 1 silently. `mock-hang` sleeps 99999. All `chmod +x`.
  - `assert.sh`: helpers `assert_eq`, `assert_contains`, `assert_exit_code`, `fail`, `pass` (~50 LOC).
  - `run.sh`: discovers `tests/adversarial/test-*.sh`, invokes each with `set -e`, accumulates pass/fail, prints summary, exits non-zero on any failure. Supports `--self-test` flag that just prints `harness: ok`.
  - `scripts/adversarial-review.sh`: in `detect_providers()`, add `if [[ -n "${ZUVO_REVIEW_TEST_PROVIDERS:-}" ]]; then echo "$ZUVO_REVIEW_TEST_PROVIDERS"; return 0; fi` as first line. Also patch `dispatch_provider()` (~line 824): if provider name starts with `mock-`, exec it directly with the prompt on stdin, capture output, return its exit status.
- [ ] Verify: `bash tests/adversarial/run.sh --self-test`
  Expected: stdout contains `harness: ok`, exit 0.
- [ ] Acceptance Proof:
  - G1:
    - Surface: integration
    - Proof: `cd /Users/greglas/DEV/zuvo-plugin && bash tests/adversarial/run.sh --self-test && ZUVO_REVIEW_TEST_PROVIDERS="mock-success" PATH="tests/adversarial/mocks:$PATH" bash scripts/adversarial-review.sh --json --files /tmp/empty.txt 2>&1 | tee /tmp/g1.out`
    - Expected: exit 0; `/tmp/g1.out` contains `"providers_used"` with `mock-success`
    - Artifact: `.zuvo/proofs/task-1-g1.out`
- [ ] Commit: `test(adversarial): add shell test harness + 4 mock provider stubs + ZUVO_REVIEW_TEST_PROVIDERS escape hatch`

### Task 2: Partial status + always-present `attempted_count` / `timeout_count` (D2)
**Files:**
- `scripts/adversarial-review.sh` (~lines 1190-1215 JSON assembly; ~line 873-876 counters init)
- `tests/adversarial/test-d2-partial-status.sh` (new)
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] RED: Add 5 test cases in `test-d2-partial-status.sh`:
  1. All providers succeed → `status == "ok"`, `attempted_count == 2`, `timeout_count == 0`
  2. 1 of 2 times out → `status == "partial"`, `attempted_count == 2`, `timeout_count == 1`
  3. Both timeout → `status == "timeout"`, `attempted_count == 2`, `timeout_count == 2`, exit 124
  4. Single-provider success → `status == "ok"`, `attempted_count == 1`, `timeout_count == 0`
  5. **Non-timeout failure (AC11):** `mock-success` + `mock-fail` → `status == "partial"`, `attempted_count == 2`, `timeout_count == 0`, `provider_count == 1` (failed provider does NOT count as timeout)
  Tests currently fail (status hardcoded to "ok" at line 1209; failure path not tracked separately from timeout).
- [ ] GREEN: Track `ATTEMPTED_COUNT` (set once after provider list resolved). Compute `FINAL_STATUS` based on `PROVIDER_COUNT` vs `ATTEMPTED_COUNT` and `TIMEOUT_COUNT`. Emit both counts in JSON unconditionally.
- [ ] Verify: `bash tests/adversarial/run.sh test-d2-partial-status`
  Expected: 4/4 pass.
- [ ] Acceptance Proof:
  - AC3:
    - Surface: backend-logic
    - Proof: `ZUVO_REVIEW_TEST_PROVIDERS="mock-success" PATH="tests/adversarial/mocks:$PATH" bash scripts/adversarial-review.sh --json --files /tmp/empty.txt | jq -e '.attempted_count and .timeout_count != null'`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-2-ac3.out`
  - AC4:
    - Surface: backend-logic
    - Proof: `ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-timeout" ZUVO_REVIEW_TIMEOUT=2 PATH="tests/adversarial/mocks:$PATH" bash scripts/adversarial-review.sh --multi --json --files /tmp/empty.txt | jq -er '.status == "partial" and .timeout_count == 1'`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-2-ac4.out`
  - AC11:
    - Surface: backend-logic
    - Proof: `ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" PATH="tests/adversarial/mocks:$PATH" bash scripts/adversarial-review.sh --multi --json --files /tmp/empty.txt | jq -er '.status == "partial" and .attempted_count == 2 and .timeout_count == 0 and .provider_count == 1'`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-2-ac11.out`
- [ ] Commit: `feat(adversarial): emit status=partial + always-present attempted_count/timeout_count`

### Task 3: Remove retry block (D1) + cleanup dead variables
**Files:**
- `scripts/adversarial-review.sh` (delete lines ~970-1064; remove dead vars `SAVED_INPUT`, `RETRY_CHARS`, `RETRY_INPUT`, `RETRY_PROVIDERS`, `RETRY_PIDS`, `RETRY_PNAMES`)
- `tests/adversarial/test-d1-no-retry.sh` (new)
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 2
**Execution routing:** default implementation tier

- [ ] RED: Test case: single `mock-timeout` provider with `ZUVO_REVIEW_TIMEOUT=2`. Measure wall-clock with `time`. Assert: total elapsed ≤ 7s (timeout + 5s margin). Currently fails (~14s due to retry).
- [ ] GREEN: Delete retry block (lines ~970-1064 in current 1297-LOC file). Remove unreferenced variables. Confirm `bash -n scripts/adversarial-review.sh` parses clean.
- [ ] Verify: `bash tests/adversarial/run.sh test-d1-no-retry`
  Expected: pass. AND `grep -c 'RETRY_' scripts/adversarial-review.sh` returns 0.
- [ ] Acceptance Proof:
  - AC1:
    - Surface: backend-logic
    - Proof: `start=$(date +%s); ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout" ZUVO_REVIEW_TIMEOUT=2 PATH="tests/adversarial/mocks:$PATH" bash scripts/adversarial-review.sh --json --files /tmp/empty.txt; ec=$?; end=$(date +%s); elapsed=$((end-start)); echo "exit=$ec elapsed=${elapsed}s"; [[ $ec -eq 124 && $elapsed -le 7 ]]`
    - Expected: exit 0 from the `[[ ... ]]` test
    - Artifact: `.zuvo/proofs/task-3-ac1.out`
  - AC2:
    - Surface: backend-logic
    - Proof: `ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-timeout" ZUVO_REVIEW_TIMEOUT=2 PATH="tests/adversarial/mocks:$PATH" bash scripts/adversarial-review.sh --multi --json --files /tmp/empty.txt | jq -er '.status == "partial" and (.results | keys | contains(["mock-success"]))'`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-3-ac2.out`
- [ ] Commit: `refactor(adversarial): remove retry block — first timeout is final (D1)`

### Task 4: Single-provider hard refusal on --multi/--rotate (D3)
**Files:**
- `scripts/adversarial-review.sh` (after EXCLUDE filter ~line 567; add check + new exit code; update `--help` block ~line 56)
- `tests/adversarial/test-d3-single-provider-refusal.sh` (new)
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 2, Task 3
**Execution routing:** default implementation tier

- [ ] RED: 4 test cases:
  1. 1 provider + `--multi` → exit non-zero, stderr contains `single_provider_only`
  2. 1 provider + `--rotate` → exit non-zero, stderr contains `single_provider_only`
  3. 1 provider + `--single` → exit 0 (unchanged)
  4. 1 provider + `--provider mock-success` → exit 0 (unchanged)
  Currently all 4 fail (no refusal logic).
- [ ] GREEN: After `EXCLUDE_PROVIDER` filtering (~line 565), count providers. If `MULTI_MODE in (rotate, multi)` and count < 2:
  - Emit JSON `{"status":"single_provider_only","mode":"$MODE","providers_available":["..."],"date":"..."}` to stdout
  - Print stderr block with options: install another provider / use `--single` / pass `--provider <name>`
  - Exit code 3 (new domain error, distinct from 1=no-provider and 2=provider-failed)
  - Update `--help` Options block to document new exit code
- [ ] Verify: `bash tests/adversarial/run.sh test-d3-single-provider-refusal`
  Expected: 4/4 pass.
- [ ] Acceptance Proof:
  - AC5:
    - Surface: backend-logic
    - Proof: `ZUVO_REVIEW_TEST_PROVIDERS="mock-success" PATH="tests/adversarial/mocks:$PATH" bash scripts/adversarial-review.sh --multi --json --files /tmp/empty.txt 2>/tmp/d3.err; ec=$?; grep -q single_provider_only /tmp/d3.err && [[ $ec -ne 0 ]]`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-4-ac5.out`
- [ ] Commit: `feat(adversarial): hard refusal on single-provider + multi/rotate (D3, exit code 3)`

### Task 5: `--exclude-last <name>` flag + validation (D4)
**Files:**
- `scripts/adversarial-review.sh` (arg parser ~line 44, provider filter ~line 565, help ~line 60)
- `tests/adversarial/test-d4-exclude-last.sh` (new)
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 2, Task 3, Task 4
**Execution routing:** default implementation tier

- [ ] RED: 3 test cases:
  1. `--exclude-last mock-timeout` with `ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-timeout"` → providers_used contains only `mock-success`
  2. `--exclude-last ""` (empty) → noop, both providers run
  3. `--exclude-last bogus-name` → stderr warning `--exclude-last value not in current provider list`, proceeds with full set
  Currently all 3 fail (flag doesn't exist).
- [ ] GREEN: Parse `--exclude-last "$2"; shift 2`. Merge value into `EXCLUDE_PROVIDER` (space-separated; do not overwrite existing `--exclude`). Validate: if non-empty and not in PROVIDERS, print stderr warning but proceed. Update `--help`.
- [ ] Verify: `bash tests/adversarial/run.sh test-d4-exclude-last`
  Expected: 3/3 pass. `bash scripts/adversarial-review.sh --help | grep -q exclude-last` returns 0.
- [ ] Acceptance Proof:
  - AC6:
    - Surface: backend-logic
    - Proof: `out1=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" PATH="tests/adversarial/mocks:$PATH" bash scripts/adversarial-review.sh --multi --json --files /tmp/empty.txt | jq -r '.providers_used'); out2=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" PATH="tests/adversarial/mocks:$PATH" bash scripts/adversarial-review.sh --multi --exclude-last mock-success --json --files /tmp/empty.txt | jq -r '.providers_used'); [[ "$out1" != "$out2" ]] && bash scripts/adversarial-review.sh --help | grep -q exclude-last`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-5-ac6.out`
- [ ] Commit: `feat(adversarial): add --exclude-last flag for cross-call rotation handoff (D4)`

### Task 6: adversarial.log summary row with new counts
**Files:**
- `scripts/adversarial-review.sh` (~line 1240-1297 logging section)
- `tests/adversarial/test-observability-log.sh` (new)
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 2, Task 3, Task 4, Task 5
**Execution routing:** default implementation tier

- [ ] RED: Test: invoke script once with `mock-success`. After invocation, last line of `$HOME/.zuvo/adversarial.log` must be a TSV line containing columns: `<ts>\t<mode>\t<status>\t<attempted>\t<timeouts>\t<duration_s>\t<providers>`. Currently fails (no summary row; only per-provider rows exist).
- [ ] GREEN: Add `log_summary()` function called once after FINAL_STATUS is set, before exit. Append TSV summary line prefixed with `SUMMARY\t` so it's grep-distinguishable from per-provider rows.
- [ ] Verify: `bash tests/adversarial/run.sh test-observability-log`
  Expected: pass.
- [ ] Acceptance Proof:
  - AC10:
    - Surface: backend-logic
    - Proof: `rm -f /tmp/test-adv.log; ADVERSARIAL_LOG_FILE=/tmp/test-adv.log ZUVO_REVIEW_TEST_PROVIDERS="mock-success" PATH="tests/adversarial/mocks:$PATH" bash scripts/adversarial-review.sh --json --files /tmp/empty.txt; tail -1 /tmp/test-adv.log | grep -E '^SUMMARY\s+[^\s]+\s+[^\s]+\s+(ok|partial|timeout|error|single_provider_only)\s+[0-9]+\s+[0-9]+'`
    - Expected: exit 0 (grep matches)
    - Artifact: `.zuvo/proofs/task-6-ac10.out`
- [ ] Commit: `feat(adversarial): append SUMMARY row to adversarial.log with attempted/timeout counts`

### Task 7: Update `shared/includes/adversarial-loop.md` (code-mode spec)
**Files:**
- `shared/includes/adversarial-loop.md` (Step 3 + Step 4 + exit-codes table; add new "Single-provider handling" subsection)
- `tests/adversarial/test-spec-codeloop.sh` (new)
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 2, Task 3, Task 4, Task 5
**Execution routing:** default implementation tier

- [ ] RED: docs-only — grep-based test asserting include contains: `status: "partial"`, `single_provider_only`, `--exclude-last`, exit code `3`, exit code `124`. Currently 0/5 match.
- [ ] GREEN: Add Step 2.5 "Handle single-provider refusal" with explicit branch on exit-3 / `single_provider_only`. Update Step 3 (meta-review check) to also branch on `status: "partial"`. Add appendix "Cross-call rotation pattern" showing `--exclude-last "$(jq -r '.providers_used[0]' prev.json)"`. Update exit codes table to include 3 and 124.
- [ ] Verify: `bash tests/adversarial/run.sh test-spec-codeloop`
  Expected: 5/5 grep assertions pass.
- [ ] Acceptance Proof:
  - AC7 (code-mode):
    - Surface: docs
    - Proof: `for term in 'status: "partial"' 'single_provider_only' '--exclude-last' 'exit code 3' 'exit code 124'; do grep -qF "$term" shared/includes/adversarial-loop.md || { echo "missing: $term"; exit 1; }; done`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-7-ac7.out`
- [ ] Commit: `docs(adversarial): document partial status + single-provider + exclude-last in code-mode include`

### Task 8: Update `shared/includes/adversarial-loop-docs.md` (docs-mode spec)
**Files:**
- `shared/includes/adversarial-loop-docs.md` (mirror Task 7 updates with docs-mode wording)
- `tests/adversarial/test-spec-docsloop.sh` (new)
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 7
**Execution routing:** default implementation tier

- [ ] RED: Same grep-assertion structure as Task 7 but on the docs-mode include.
- [ ] GREEN: Add equivalent sections in docs-mode wording. Update graceful degradation section (currently lines 134-143) to clarify partial status.
- [ ] Verify: `bash tests/adversarial/run.sh test-spec-docsloop`
  Expected: pass.
- [ ] Acceptance Proof:
  - AC7 (docs-mode):
    - Surface: docs
    - Proof: `for term in 'status: "partial"' 'single_provider_only' '--exclude-last' 'exit code 3' 'exit code 124'; do grep -qF "$term" shared/includes/adversarial-loop-docs.md || { echo "missing: $term"; exit 1; }; done`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-8-ac7.out`
- [ ] Commit: `docs(adversarial): document partial/single-provider/exclude-last in docs-mode include`

### Task 9: Patch `skills/review/SKILL.md` adversarial section
**Files:**
- `skills/review/SKILL.md` (adversarial loop section)
- `tests/adversarial/test-skill-review.sh` (new)
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 7, Task 8
**Execution routing:** default implementation tier

- [ ] RED: Grep assertion: SKILL.md contains `status: "partial"`, `single_provider_only`, and an explicit branch instructing the agent to surface `timeout_count` to user. Currently fails.
- [ ] GREEN: Add explicit handling in review's adversarial phase: detect `status == "partial"` (warn + continue), detect `status == "single_provider_only"` (instruct to re-invoke with `--single` after operator decision), surface `timeout_count` in adversarial summary block.
- [ ] Verify: `bash tests/adversarial/run.sh test-skill-review`
  Expected: pass.
- [ ] Acceptance Proof:
  - AC8 (review):
    - Surface: docs
    - Proof: `grep -qF 'status: "partial"' skills/review/SKILL.md && grep -qF 'single_provider_only' skills/review/SKILL.md && grep -qF 'timeout_count' skills/review/SKILL.md`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-9-ac8.out`
- [ ] Commit: `feat(review): handle partial/single-provider status from adversarial-review`

### Task 10: Patch `skills/brainstorm/SKILL.md` adversarial section
**Files:**
- `skills/brainstorm/SKILL.md`
- `tests/adversarial/test-skill-brainstorm.sh` (new)
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 7, Task 8
**Execution routing:** default implementation tier

- [ ] RED: Grep assertion mirroring Task 9 against brainstorm SKILL.md. Currently fails.
- [ ] GREEN: Add equivalent handling in brainstorm's spec-adversarial phase. Wording adapted to spec-mode (artifact, not diff).
- [ ] Verify: `bash tests/adversarial/run.sh test-skill-brainstorm`
  Expected: pass.
- [ ] Acceptance Proof:
  - AC8 (brainstorm):
    - Surface: docs
    - Proof: `grep -qF 'status: "partial"' skills/brainstorm/SKILL.md && grep -qF 'single_provider_only' skills/brainstorm/SKILL.md && grep -qF 'timeout_count' skills/brainstorm/SKILL.md`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-10-ac8.out`
- [ ] Commit: `feat(brainstorm): handle partial/single-provider status from adversarial-review`

### Task 11: Patch `skills/plan/SKILL.md` adversarial section
**Files:**
- `skills/plan/SKILL.md`
- `tests/adversarial/test-skill-plan.sh` (new)
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 7, Task 8
**Execution routing:** default implementation tier

- [ ] RED: Grep assertion mirroring Task 9. Currently fails.
- [ ] GREEN: Add handling in plan's Phase 3 cross-model validation (Step 3) — same shape as Task 9.
- [ ] Verify: `bash tests/adversarial/run.sh test-skill-plan`
  Expected: pass.
- [ ] Acceptance Proof:
  - AC8 (plan):
    - Surface: docs
    - Proof: `grep -qF 'status: "partial"' skills/plan/SKILL.md && grep -qF 'single_provider_only' skills/plan/SKILL.md && grep -qF 'timeout_count' skills/plan/SKILL.md`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-11-ac8.out`
- [ ] Commit: `feat(plan): handle partial/single-provider status from adversarial-review`

### Task 12: Patch `skills/write-article/SKILL.md` adversarial section
**Files:**
- `skills/write-article/SKILL.md`
- `tests/adversarial/test-skill-write-article.sh` (new)
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 7, Task 8
**Execution routing:** default implementation tier

- [ ] RED: Grep assertion mirroring Task 9. Currently fails.
- [ ] GREEN: Add handling in write-article's Phase 4.3 (article-mode adversarial) — same shape.
- [ ] Verify: `bash tests/adversarial/run.sh test-skill-write-article`
  Expected: pass.
- [ ] Acceptance Proof:
  - AC8 (write-article):
    - Surface: docs
    - Proof: `grep -qF 'status: "partial"' skills/write-article/SKILL.md && grep -qF 'single_provider_only' skills/write-article/SKILL.md && grep -qF 'timeout_count' skills/write-article/SKILL.md`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-12-ac8.out`
- [ ] Commit: `feat(write-article): handle partial/single-provider status from adversarial-review`

### Task 13: Backward-compat contract tests + pre-commit hook smoke + SMOKE1-3 final gate
**Files:**
- `tests/adversarial/test-backward-compat.sh` (new)
- `tests/adversarial/test-smoke-all.sh` (new — wraps SMOKE1/2/3 from this plan as runnable assertions)
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 1, Task 2, Task 3, Task 4, Task 5, Task 6, Task 7, Task 8, Task 9, Task 10, Task 11, Task 12
**Execution routing:** default implementation tier

- [ ] RED: 3 backward-compat cases + 3 smoke cases:
  1. Old-style `jq -r '.status' | grep -q '^ok$'` does NOT match `"partial"` output (fail-closed).
  2. `hooks/pre-commit-adversarial-gate.sh` accepts an artifact written by the new script (`--artifact /tmp/art.txt` with mock-success). Preconditions: cwd = repo root; hook is executable.
  3. JSON output parses cleanly via `jq .` in all 4 status modes (ok / partial / timeout / single_provider_only).
  4. SMOKE1 (mixed success/timeout) executes the exact proof block from "Whole-feature Smoke Proofs" below and asserts exit 0.
  5. SMOKE2 (single-provider hard refusal) — same.
  6. SMOKE3 (cross-call rotation via `--exclude-last`) — same.
- [ ] GREEN: Wire up `test-backward-compat.sh` with assertions 1-3 and `test-smoke-all.sh` invoking SMOKE1/2/3 verbatim. No script changes — purely validation that prior tasks preserved compat AND that the end-to-end flow works.
- [ ] Verify: `bash tests/adversarial/run.sh test-backward-compat test-smoke-all`
  Expected: 6/6 pass.
- [ ] Acceptance Proof:
  - AC9:
    - Surface: integration
    - Proof: `cd /Users/greglas/DEV/zuvo-plugin && bash tests/adversarial/run.sh test-backward-compat && ZUVO_REVIEW_TEST_PROVIDERS="mock-success" PATH="tests/adversarial/mocks:$PATH" bash scripts/adversarial-review.sh --json --artifact /tmp/art.txt --files /tmp/empty.txt && bash hooks/pre-commit-adversarial-gate.sh /tmp/art.txt`
    - Expected: exit 0
    - Artifact: `.zuvo/proofs/task-13-ac9.out`
  - G1 (final smoke gate):
    - Surface: integration
    - Proof: `cd /Users/greglas/DEV/zuvo-plugin && bash tests/adversarial/run.sh test-smoke-all`
    - Expected: exit 0; stdout shows `SMOKE1 ok`, `SMOKE2 ok`, `SMOKE3 ok`
    - Artifact: `.zuvo/proofs/task-13-smoke.out`
- [ ] Commit: `test(adversarial): backward-compat contract + SMOKE1-3 final gate`

## Whole-feature Smoke Proofs

- **SMOKE1 — Mixed success/timeout end-to-end via mocks**
  - Preconditions: Tasks 1-6 done; `/tmp/empty.txt` exists; `tests/adversarial/mocks/` populated.
  - Proof:
    ```bash
    out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-timeout" \
      ZUVO_REVIEW_TIMEOUT=2 \
      PATH="tests/adversarial/mocks:$PATH" \
      bash scripts/adversarial-review.sh --multi --json --files /tmp/empty.txt)
    echo "$out" | jq -e '.status == "partial" and .attempted_count == 2 and .timeout_count == 1 and .provider_count == 1 and (.results | keys | contains(["mock-success"]))'
    ```
  - Expected: exit 0; full pipeline returns valid partial-status JSON within 7s wall-clock.
  - Artifact: `.zuvo/proofs/smoke-1-mixed.out`

- **SMOKE2 — Single-provider hard refusal end-to-end**
  - Preconditions: Tasks 1, 4 done.
  - Proof:
    ```bash
    ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
      PATH="tests/adversarial/mocks:$PATH" \
      bash scripts/adversarial-review.sh --multi --json --files /tmp/empty.txt 2>/tmp/smoke2.err
    ec=$?
    grep -qF 'single_provider_only' /tmp/smoke2.err && [[ $ec -ne 0 ]]
    ```
  - Expected: exit 0 from the `[[ ... ]]` test (i.e., refusal correctly fires).
  - Artifact: `.zuvo/proofs/smoke-2-refusal.out`

- **SMOKE3 — Cross-call rotation via `--exclude-last`**
  - Preconditions: Tasks 1, 5 done.
  - Proof:
    ```bash
    first=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
      PATH="tests/adversarial/mocks:$PATH" \
      bash scripts/adversarial-review.sh --rotate --json --files /tmp/empty.txt \
      | jq -r '.providers_used[0]')
    second=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
      PATH="tests/adversarial/mocks:$PATH" \
      bash scripts/adversarial-review.sh --rotate --exclude-last "$first" --json --files /tmp/empty.txt \
      | jq -r '.providers_used[0]')
    [[ "$first" != "$second" ]] && [[ -n "$first" ]] && [[ -n "$second" ]]
    ```
  - Expected: exit 0; second call uses different provider than first.
  - Artifact: `.zuvo/proofs/smoke-3-rotation.out`

---

## Execution Notes

- `tests/adversarial/` is new — Task 1 establishes the directory and harness conventions.
- All 13 task commits are small (1-3 files each); each independently verifiable.
- **Script-edit serialization (rev 2):** Tasks 2, 3, 4, 5, 6 all edit `scripts/adversarial-review.sh` and must execute in numeric order. Dependencies now enforce this (T3→T2, T4→T2,T3, T5→T2,T3,T4, T6→T2..T5). No parallel script edits — avoids merge conflicts and intermediate states where new flags interact with stale retry/status logic.
- **Wrapper `bin/adversarial-review`** is pure pass-through (`exec scripts/adversarial-review.sh "$@"`). No task required. Confirmed by inspection — no parsing, no help text, no exit-code translation.
- D1 + D2 + D3 + D4 land in script before any include/skill update (Tasks 2-6 before 7-12), guaranteeing the spec/skill text never claims behavior the script doesn't yet have.
- **Smoke proofs (rev 2):** SMOKE1/2/3 are now mapped into Task 13 as runnable assertions (`test-smoke-all.sh`), closing the prior coverage gap where smokes were documented but not gated.
- Estimated total LOC change: +~450 (tests, mocks, doc updates, smoke runner), -~100 (retry-block removal). Net: smaller, better-tested script.

## Rollback & Operational Notes

- **D1 retry removal rollback:** D1 has no feature flag. If post-deploy telemetry shows a spike in `timeout_count > 0` invocations (query: `awk -F'\t' '$1=="SUMMARY" && $5>0 {n++} END {print n}' ~/.zuvo/adversarial.log`), revert the Task 3 commit. Optional follow-up: a future PR may add `ZUVO_REVIEW_RETRY=1` env-gated retry as opt-in for users with consistently slow providers — explicitly out of scope for this plan.
- **D3 hard refusal rollback:** Users hitting the new exit code 3 can bypass via `--single` (accept single-provider review) or `--provider <name>` (explicit selection). Document in release notes alongside the change.
- **Skill validation depth (Tasks 9-12):** Validation is intentionally grep-based on SKILL.md prose. These are docs-only patches — there is no executable code path to assert behaviorally without running the actual skill end-to-end, which is out of scope for this plan's L1+L2 surface. Real-world behavior is covered indirectly: SMOKE1-3 (Task 13) exercise the script contract that the skill docs reference. If a skill's adversarial section drifts from script behavior, the next `zuvo:review` run will surface it.
