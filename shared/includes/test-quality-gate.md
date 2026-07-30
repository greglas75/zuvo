# Test Quality Gate — audit touched tests to tier A (via zuvo:test-audit)

**Why this exists.** The in-run Q1-Q25 self-evals (refactor Phase 2/3, execute quality-reviewer)
are the same model scoring its own output in the same context — and field runs still shipped weak
tests (user observation 2026-07-30: "te testy wychodzą słabe"). This gate dispatches the REAL
`zuvo:test-audit` skill — an independent, tiered A/B/C/D audit with anti-pattern detection — on the
tests the run touched, then FIXES everything below tier A in-run, before the run may claim complete.

**NO-SUBSTITUTION.** An inline Q1-Q25 re-read, a "quick self-rescoring pass", or "the quality
reviewer already scored these" is NOT this gate — that is the exact self-scoring that produced the
weak tests. The gate is the literal `Skill(skill="zuvo:test-audit", …)` dispatch, and its proof is
the report the audit skill writes under `zuvo/audits/` (only that skill writes there). A
`[GATE: test-quality] PASS` without a real on-disk report path is a substituted gate → INVALID.

## Inputs (set by the calling skill)

- `TEST_SCOPE` — the test files in scope. Union of:
  1. every test file this run **created or modified** (characterization/pin-down tests, new unit
     tests, updated specs), and
  2. every **pre-existing** test file that covers a production file this run touched — co-located
     `.test.*` / `.spec.*` / `__tests__/*`, or found via grep/`find_references` for imports of the
     touched production files. (These are the "already weak before we got here" tests the user
     wants raised, not just the ones we wrote.)
  **NEVER the whole suite** — this is a touched-surface gate, not `test-audit all`. E2E files stay
  out unless the run itself wrote them.
- `FIX_COMMIT_PREFIX` — e.g. `test(<refactor-scope>):` or `test(plan):`.

## Sequence

1. **Empty scope** → print `[GATE: test-quality] N/A (no test files in scope)` and return. (A run
   that touched production but has NO covering tests anywhere should have been caught by the
   calling skill's own coverage gate — do not silently use N/A to dodge that.)
2. **Dispatch the real skill:**
   ```
   Skill(skill="zuvo:test-audit", args="<TEST_SCOPE files, space-separated> --deep --read-only --commit=off")
   ```
   `--read-only` because the CALLING skill owns fixes and commits (its own commit gates apply);
   `--deep` because the fix loop needs per-finding evidence, not binary triage.
3. **Read per-file tiers from the report.** Target: **tier A per file**.
   - All A → print `[GATE: test-quality] PASS tier=A files=<N> report=<zuvo/audits/…>` — done.
   - Any file below A → **fix in-run**: apply the audit's per-finding fixes. When a file is
     systemically bad (tier C/D, multiple critical Q-gates at 0), REWRITE the file rather than
     stacking patches on bad tests (per `feedback_rewrite_vs_add_tests`). Re-run the affected
     suites green, then commit separately: `<FIX_COMMIT_PREFIX> raise test quality to A (<files>)`.
4. **Re-audit ONLY the fixed files** (same dispatch, narrowed args). **Max 2 fix→re-audit
   iterations.**
5. **After the cap:** any file still below A → do NOT loop further and do NOT claim PASS. Print
   `[GATE: test-quality] WARN worst=<tier> below-A=<file list> report=<path>` and backlog each
   file with its tier + failing Q-gates (`backlog-protocol.md`). Never silently accept; never
   relabel WARN as PASS.

## Ordering + safety rules

- **Run AFTER behavior is proven** — after the refactor/fix commits (refactor) or after smoke
  proofs (execute). Improving a characterization test BEFORE the move would destroy the
  green-on-old lock the refactor's safety rests on.
- **Strengthening only.** A "fix" that deletes or weakens an assertion to reach tier A is the
  anti-pattern this gate exists to stop. If an assertion fails after strengthening, that is a
  surfaced PRODUCTION finding → route it to the calling skill's remediation path (refactor Phase
  3.5 / execute implementer re-dispatch), not a test edit.
- **This gate edits test files only.** Production files are out of its reach by construction.
- **Suites green after every iteration** (targeted scope, compared against the session baseline —
  pre-existing reds stay pre-existing).
- **Telemetry:** record `test_quality=<PASS|WARN|N/A>:<worst tier>:<report path>` in the run's
  contract/telemetry so retros can see the gate ran and what it found.
