# Test Economics — Frozen Metric Definitions (quality / cost / speed)

> Why this file exists: 2026-08-18, three profilers analyzed ONE transcript and produced three
> truths — gross 203,519,738 vs 203,284,665; polling lower bound 9.4% vs 10.8% vs 22.5%; targeted
> mutation runs 23 vs 23 vs 15. Every divergence was definitional, not measurement error. A metric
> used in any zuvo report MUST cite the formula below; restating or re-deriving a formula in a
> report is a defect. Label every number M/D/E/U (house convention).

## Axis 1 — QUALITY (per production file; aggregate per task)

| Metric | Frozen formula |
|---|---|
| KILL_RATE | killed / executed from the MUTATION PROBES table (native runner present → `score_triaged`, never `score_raw`). A wrapper/infra failure is `NOT_EXECUTED` and is EXCLUDED from the denominator — it is not killed and not survived. |
| NEG_COVERAGE | discriminant axes with ≥1 ASSERTED negative ÷ total axes (TYPE_CONTRACT unions + matched family axes). Token negatives (one per file) do not count an axis covered. |
| UNCLASSIFIED_RATE | files recording `unmatched_shape` ÷ files processed. This number falling via TABLE GROWTH is progress; falling via silent defaults is regression. |
| ECHO_COUNT | AP29 instances (mock return value echoed in the assertion — proves the mock setup, not production logic) in delivered specs. Target: 0. |
| TIER_DIST | test-audit A/B/C/D percentages, suite-aware. |

## Axis 2 — COST (per delivered test file; aggregate per task)

| Metric | Frozen formula |
|---|---|
| FRESH_TOKENS | `(input − cached_input) + output_total`, where `output_total` INCLUDES reasoning tokens. Gross is reported alongside, never as the headline. |
| TURNS | model calls inside the task window. |
| POLLING_CALL | a model call whose immediately-preceding tool result is a status/queue/watch output (`rt --attach/--queue/--log/--stats`, `gh run watch/view`, `gh pr checks/view`, status `gh api`, `write_stdin` into a watch, `sleep`) showing NO state change vs the previous poll of the same subject. First observation of a new state is NOT a polling call. |
| TASK_WINDOW | start = first tool call naming the target; end = final `task_complete` or last artifact write. Away/session gaps excluded ONLY via profiler markers. |
| MANDATORY_LOAD_KB | bytes of files a skill requires reading before the first target-file read, measured per skill version. |

## Axis 3 — SPEED

| Metric | Frozen formula |
|---|---|
| ACTIVE_MIN | wall − away − stall; stall = gap >10 min inside a session with zero tool calls. |
| EXEC_MIN | sum of RUNNER-REPORTED durations only (suite seconds from the runner's own summary). Queue, mirror, setup excluded. |
| QUEUE_MIN | reported separately; never folded into any verdict about compute performance. |
| PER_FILE_WALL | write-tests: `[CLASSIFIED]` print → that file's completion block. |

Consumers (each loads this file explicitly — a consumer that does not load it cannot honour the
formulas): `write-tests` (DEFERRED D4, completion block), `test-audit` (report), `profile-session`
(cost/speed axes). Reference this file; never restate formulas.
