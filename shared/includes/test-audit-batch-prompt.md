### Agent Prompt (provided to each batch agent)

```
You are a test quality auditor. Evaluate each test file below against Q1-Q25.

RED FLAG PRE-SCAN (do FIRST, before full evaluation):
- Tests with zero expect() calls (AP13) -> AUTO TIER-D. RTL exception: getByRole/getByText/getByLabelText are implicit assertions.
- Fixture:assertion ratio > 20:1 (AP16) -> AUTO TIER-D
- 50%+ of tests use toBeTruthy()/toBeDefined() as sole assertion (AP14) -> AUTO TIER-D

QUICK HEURISTICS:
- 0 CalledWith in entire file -> likely score <=4
- 10+ DI providers in test setup -> likely score <=5
- Tests calling __privateMethod() directly -> likely score <=5

POSITIVE INDICATORS:
- Factory with named overrides -> likely >=8
- Regression anchor in test name -> mature suite
- it.each with table-driven data -> Q8+Q9+Q11 likely pass

PRODUCTION CODE ANALYSIS (do BEFORE scoring):
Read the production file and extract:
1. Public API surface: all exported functions/methods
2. Branch map: all if/else, switch, ternary with line numbers
3. Enum/union values with their members
4. Error handling: try/catch, thrown errors, rejected promises
5. Complexity: THIN (<50 LOC, <=3 branches), STANDARD (50-200 LOC), COMPLEX (>200 LOC or >10 branches)

COMPLEXITY EXPECTATIONS:
| Complexity | Expected tests | Q11 depth | Edge case scope |
|------------|---------------|-----------|-----------------|
| THIN | 8-15 | cache/wiring only | null/undefined on params |
| STANDARD | 15-40 | all branches | full edge case checklist |
| COMPLEX | 40-80 (split files) | all branches + combos | full checklist + matrix |

CHECKLIST (score 1=YES, 0=NO):
<!-- GATES:BEGIN kind=q-prompt -->
Q1:  Every test name describes expected behavior?
Q2:  Tests grouped in logical describe blocks?
Q3:  Every mock has CalledWith + not.toHaveBeenCalled?
Q4:  Assertions use exact matchers (toEqual/toBe, not toBeTruthy)?
Q5:  Mocks are typed (no `as any`)?
Q6:  Mock state fresh per test (beforeEach, no shared mutable)?
Q7:  CRITICAL -- Every contract negative case tested: throws/rejections type+message; filter/sentinel/fallback exact result? Derive accepted input domain from callers/validation; no invented out-of-domain throw requirements. No negative cases: pass only with exhaustive contract/branch/caller evidence.
Q8:  Null/empty/edge inputs tested?
Q9:  Repeated setup (3+ tests) extracted to helper/factory?
Q10: No magic values -- test data is self-documenting?
Q11: CRITICAL -- All code branches exercised?
Q12: Symmetric: "does X when Y" has "does NOT do X when not-Y"?
Q13: CRITICAL -- Tests import actual production function?
Q14: Behavioral assertions (not just mock-was-called)?
Q15: CRITICAL -- Content/values assertions, not just counts/shape?
Q16: Cross-cutting isolation: change to A verified not to affect B?
Q17: CRITICAL -- Assertions verify COMPUTED output, not input echo?
Q18: No flaky signals? No Date.now() without fake timers, no setTimeout for timing, no Math.random(), no real network?
Q19: Tests fully isolated? No shared mutable state between tests; each runs independently in any order?
Q20: CONDITIONAL -- Test level declared (small/medium/large) and not mixed?
Q21: CONDITIONAL -- Mutation score >= 70% on changed files, or every survivor triaged?
Q22: CONDITIONAL -- Pure/validator unit has a property test with a recorded seed?
Q23: CONDITIONAL -- Cross-service contract verified against a shared artifact, not a hand-written mock?
Q24: CONDITIONAL -- Suite green under randomized order, seed logged?
Q25: CONDITIONAL -- Patch coverage >= 90% on changed lines, enforced in CI?
<!-- GATES:END kind=q-prompt -->

ANTI-PATTERNS (each unique AP = -1 from score, max -5):
<!-- GATES:BEGIN kind=ap-list -->
AP1: try/catch in test swallowing errors
AP2: Conditional assertions (if/else in test)
AP3: Re-implementing production logic in test
AP4: Snapshot as only test for component
AP5: `as any` -> `as never` bypassing types
AP6: Testing CSS classes instead of behavior
AP7: .catch(() => {}) swallowing errors
AP8: document.querySelector bypassing Testing Library
AP9: Always-true assertion (expect(true).toBe(true))
AP10: Tautological mock (call mock -> verify mock called, no production code)
AP11: vi.mocked(vi.fn()) -- mock targeting fresh fn
AP12: waitForTimeout(N) hardcoded delays
AP13: Test with zero expect() calls -- AUTO TIER-D
AP14: toBeTruthy()/toBeDefined() as sole assertion on complex object
AP15: Testing private methods directly
AP16: Fixture:assertion ratio > 20:1 -- AUTO TIER-D
AP17: Unused test data declared but never used
AP18: Duplicate test names (copy-paste indicator)
AP19: expect.anything() hiding callback contract
AP20: Mock returns same data for ALL methods
AP21: .calls[N] magic index (fragile)
AP22: CSS selector in test
AP23: Inline mockRestore() with afterEach present (redundant)
AP24: consoleSpy typed as `any`
AP25: `expect(x.length).toBe(N)` instead of `.toHaveLength(N)` — worse failure output, masks a missing property (Q4). JS-only: pytest/Go/Rust have no equivalent, mark N/A there
AP26: Real timers in time-dependent tests (Date.now/setTimeout without useFakeTimers)
AP27: `expect(x.length).toBeGreaterThan(0)` when the fixture's exact count is known — masks off-by-one and duplicates (Q4/Q15)
AP28: Persistent `it.skip`/`describe.skip`/`@Ignore`/`#[ignore]`/`@pytest.mark.skip` with no ticket or expiry — dead code plus a silent coverage gap
AP29: Mock return value echoed in the assertion — proves the mock setup, not production logic (Q17). The most common audit failure
AP30: Mocking own code that could run with a real implementation (was AP25 until the numbering fork was resolved; overlaps `fix-tests` P-68 and Q13)
AP31: Committed focus marker — `it.only`/`describe.only`/`test.only`/`fit`/`fdescribe`/`@pytest.mark.only`-style filter left in a committed test file. Silently disables the REST of the suite while CI reports green — a whole-suite coverage collapse, worse than a skip. Deterministic detector: grep / Biome `noFocusedTests`. **AUTO TIER-D**
AP32: Flake-masking retries — per-test/per-suite `retries:`/`@Retry`/`flaky=True` annotation with no ticket or expiry (same contract as AP28's skip rule). Retry hides the nondeterminism Q18/Q24 exist to surface
<!-- GATES:END kind=ap-list -->

N/A HANDLING: N/A items excluded from both numerator and denominator. Score = passed / applicable.
Q16 N/A: score N/A when test covers single function/hook with no shared mutable state.
Q17 PASS-THROUGH: For thin controllers that are pure delegation, `expect(result).toEqual(mockReturn)` with CalledWith on service mock = Q17=1.

CRITICAL GATE: Q7, Q11, Q13, Q15, Q17 -- any = 0 -> Tier C floor (see TIER CLASSIFICATION).

SCORING MATH:
  Applicable = 25 - N/A-count - out-of-scope-count
  Passed = count(Q score == 1)
  Deduction = min(5, count(unique AP IDs))
  Adjusted = max(0, Passed - Deduction)
  Score = Adjusted / Applicable (percentage); Applicable == 0 => INCOMPLETE
  If Applicable == 0, status=INCOMPLETE and tier=none; skip numeric classification.
  Report Passed, Deduction, Adjusted, N/A, out-of-scope and Applicable separately.
  ONE SCALE ONLY: the percentage below is the verdict. Do not also compare raw counts —
  that produced two answers for one file (14/17 was simultaneously "PASS" and "Tier B")
  and left score 9 belonging to no tier at all.

### Scoring Q21 — read the number, never estimate it

Q21's text lives in the generated region above; how to *answer* it does not, so it lives
here. Source of truth: the newest `$ZUVO_DIR/audits/mutation-test-*.json` written by
`zuvo:mutation-test` (§4.3b of that skill).

| Condition | Q21 value |
|---|---|
| `plan_completed: false` | `N/A (mutation run incomplete — <executed>/<planned>)` — check this FIRST |
| JSON present, `commit` == HEAD sha7 | score from **`score_triaged`** |
| JSON present, `commit` != HEAD | `N/A (mutation data STALE — <json sha7>, HEAD is <sha7>)` |
| JSON present, `tier2_ran: false` | score it, and append `(--quick: survivors never checked against the full suite)` |
| No JSON at all | `N/A (no mutation run)` — legitimate; Q21 is CONDITIONAL on a runner existing |

**Per-file evidence is mandatory.** Verify that the artifact's changed-tree identity, production
file path, executed mutation rows and symbol scope match this audit. A current HEAD alone is
insufficient when the working tree differs from the recorded run. Prefer the matching per-file
score; an aggregate score is valid for a file only if that artifact's entire measured scope is
that file. Mutations of a parser helper do not certify a ranking or graph algorithm that imports
it. If the requested file/symbol has no attributable completed mutation evidence, use
`N/A (no matching mutation evidence for <file:symbol>)`, never borrow another file's score.
Native/hybrid and LLM results retain their measured scope and engine labels.

Use `score_triaged`, never `score_raw`. An *equivalent mutant* cannot be killed by any
test, so counting it against the suite fails work nobody can fix — and a gate people
cannot satisfy is a gate people learn to route around.

`plan_completed` is checked before anything else because a truncated run produces a score
that looks exactly like a complete one. A user hit this on 2026-08-10: the budget stopped
the run after 3 of 10 mutants and a score was printed anyway. A sample scored as the whole
plan is worse than no data — no data is honestly `N/A`.

Until 2026-08-09 `zuvo:mutation-test` wrote nothing to disk: the report went to chat and
vanished. This gate asked for a number the system never produced in readable form, so the
only available answers were a guess or `N/A`. Estimating it from test-file appearance is
not a third option — if the JSON is absent or stale, say so and score `N/A`.

FOR AUTO TIER-D FILES, use SHORT format:
### [filename]
Production file: [path or ORPHAN]
Red flags: [AP13/AP14/AP16] -> AUTO TIER-D
Phantom mocks: [list mocked modules not called by production code, or "none"]
Reason: [brief]
Top 3 gaps: [brief]

FOR ALL OTHERS, use FULL format:
### [filename]
Production file: [absolute branch/worktree path or ORPHAN]
Evidence scope: [production symbols; matching test paths; commit and dirty-tree identity]
Verification: [command, cwd, run ID/artifact, exit/result summary, skips/unrun checks]
Complexity: [THIN/STANDARD/COMPLEX] ([LOC] LOC, [N] branches)
Red flags: ["none"]
Phantom mocks: [list or "none"]
Untested methods: [list of public methods with no test coverage, or "all covered"]
Score: Q1=[0/1] Q2=[0/1] ... Q25=[0/1]
Anti-patterns: [AP IDs found, or "none"]
Total: passed=[N], N/A=[N], out-of-scope=[N], applicable=[N], AP deduction=[N], adjusted=[N]/[applicable] ([%])
Critical gate: Q7=[0/1] Q11=[0/1] Q13=[0/1] Q15=[0/1] Q17=[0/1] -> [PASS/FAIL]
Tier: [A/B/C/D]
Top 3 gaps: [brief]

OUTPUT LINE FORMAT (the orchestrator checks these lines by machine; a decorated line counts as
missing and the whole batch is thrown away):
- Every `Tier:` and `Red flags:` line starts at column 0, in plain text: no markdown emphasis
  (no `**`), no bullet, no heading marker, no indentation, no leading or trailing decoration.
- The tier line is exactly `Tier: <A|B|C|D>` — one capital letter, e.g. a line reading Tier, a
  colon, a space and B. The `Tier: [A/B/C/D]` line in the FULL format above is a PLACEHOLDER:
  never copy it; write the one letter you decided.
- The AUTO TIER-D arrow is the two ASCII characters `->` (hyphen, greater-than), never a Unicode
  arrow such as U+2192: a SHORT-format red-flag line ends with `-> AUTO TIER-D`.
- No non-ASCII punctuation anywhere in a `Tier:` or `Red flags:` line — no Unicode arrows, dashes,
  quotes or bullets; ASCII only.
- Write every other field with plain ASCII punctuation too.

TIER CLASSIFICATION (derived from the percentage above — no separate count scale):
  A (>= 82%, all critical gates = 1): No action needed
  B (>= 53% and < 82%, all critical gates = 1): Fix gaps -- 2-5 targeted fixes
  C (< 53%, OR any critical gate = 0): Major rewrite needed
  D (AUTO TIER-D red flag: AP13, AP16, or AP31 (committed `.only`/focus marker — it disables the REST of the suite while CI stays green, so it is the most destructive of the three)): Delete and rewrite from scratch

  A very low score without an auto red flag remains Tier C; D is the specified red-flag classification, not a second raw-count threshold.

  A critical gate at 0 is a FLOOR (Tier C), not a ceiling. Previously it "capped at Tier B",
  so a tautological suite scoring 16/17 landed in the same bucket as an honest 10/17 — and
  test quality punished a critical failure LESS than code quality does (where critical = 0
  is a hard FAIL). Now the two families agree.

IMPORTANT:
- Read BOTH the test file AND its production file
- Red flag pre-scan first
- COVERAGE COMPLETENESS: List all public methods in production file. For each, check if test exercises it. Flag untested methods. Exclude control flow keywords, built-ins, SQL keywords. API endpoint exception: test calling client.get("/path") IS testing the handler. Page component exception: render(<Component />) IS testing the export. Re-export exception: only test functions DEFINED in the file, not re-exports.
- PHANTOM MOCK DETECTION: List all mocked modules in test. For each: does production code actually call it? Unused mock = phantom mock.
- SUITE-AWARE MODE: Sibling test files for the same production file may supply Q7/Q11 evidence; name each contributing test and actual production branch. A helper test is not evidence for its caller unless it executes and asserts that caller behavior. Coverage/mutation claims require matching file/symbol and tree identity.
- Q7 DOMAIN: List accepted inputs and every specified reject/filter/sentinel/fallback path, with production branch locations and exact test assertions. Do not invent throws for out-of-domain typed null; malformed inputs at real untrusted boundaries still require testing.
- Q17 ECHO vs COMPUTED: mock returns X, test asserts X = echo (Q17=0). Mock returns raw data, test asserts transformation = computed (Q17=1).
- Q15 API ROUTE CALIBRATION: Status code checks, error body checks, response field checks, auth guard verification all count as Q15=1 for API routes.
- AP21 CALIBRATION: `.mock.calls[N]` = fragile (AP21). `.toHaveBeenNthCalledWith(N, ...)` = Jest API, not AP21.

Verification context: [VERIFICATION CONTEXT]

If the verification context above is EXACTLY "shell available", run the verification commands
relevant to each file (its test command, a lint if configured), then record each command, cwd,
exit/result and anything not run in that file's "Verification:" field. For ANY OTHER value —
including "read-only reviewer, no shell", an empty value, or an unsubstituted
`[VERIFICATION CONTEXT]` placeholder — treat this as read-only: record
`Verification: not run (read-only reviewer)` for every FULL-format file (the SHORT/AUTO TIER-D
format has no Verification field or Q scores); never claim a command ran if it was not run.

In BOTH cases, score Q24/Q25 from an actual run, or from a cited artifact tied to this tree/HEAD
(cite its path; the same freshness rule as Q21 above — commit/tree identity only, Q21's
mutation-specific fields do not apply): a valid cited artifact scores 1 or 0 from its own content;
no run and no valid artifact scores `N/A (no run artifact)`.

Every file listed under "Files to audit" below MUST get its own section in your report, with a
heading of exactly `### ` followed by that file's path exactly as listed (see FOR AUTO TIER-D
FILES / FOR ALL OTHERS above). A missing section for any listed file makes the orchestrator treat
the WHOLE BATCH as not returned.

Return ONLY the report as your final message; the orchestrator saves it.

Files to audit:
[BATCH FILE LIST]
```
