---
name: load-test
description: >
  Dynamic performance testing under load. Discovers API endpoints, generates
  load test scripts (k6, Artillery, Playwright, ab), executes smoke/load/stress/spike/soak
  scenarios, and reports p50/p95/p99 latency, error rates, and throughput. Supports
  baseline establishment and regression comparison. Complements zuvo:performance-audit
  (static analysis) with actual runtime measurements.
  Switches: zuvo:load-test [endpoint or path] | --tool [k6|artillery|playwright|ab] | --scenario [smoke|load|stress|spike|soak] | --users [N] | --duration [Ns|Nm] | --baseline | --compare | --generate-only
---

# zuvo:load-test — Dynamic Performance Load Testing

Generate and execute load tests against API endpoints. Measure latency, throughput,
and error rates under realistic traffic patterns. Every result includes percentile
breakdowns and threshold verdicts so the team can ship with confidence.

**Scope:** API load testing, endpoint stress testing, performance baseline
establishment, regression detection via before/after comparison.
**Out of scope:** Static code analysis (`zuvo:performance-audit`), monitoring
live production (`zuvo:canary`), fixing performance issues (`zuvo:build`),
database query optimization (`zuvo:db-audit`).

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Flag | Effect |
|------|--------|
| `[endpoint or path]` | Specific endpoint (e.g., `/api/users`) or directory to discover endpoints in |
| `--tool [k6\|artillery\|playwright\|ab]` | Load testing tool to use (default: auto-detect) |
| `--scenario [smoke\|load\|stress\|spike\|soak]` | Run a single scenario instead of the default set |
| `--users [N]` | Concurrent virtual users for load scenario (default: 50) |
| `--duration [Ns\|Nm]` | Test duration per scenario (default: 30s) |
| `--baseline` | Save results to `memory/perf-baseline.json` as the performance baseline |
| `--compare` | Compare results against the existing baseline in `memory/perf-baseline.json` |
| `--generate-only` | Generate test scripts without executing them |

Flags can be combined: `zuvo:load-test /api/users --tool k6 --scenario stress --users 100 --baseline`

Default behavior (no flags): auto-detect tool, discover all endpoints, run smoke + load + stress.

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch patterns,
path resolution, and progress tracking across Claude Code, Codex, and Cursor.

**Interaction behavior is governed entirely by env-compat.md.** This skill does
not override env-compat defaults.

**Agent dispatch model:** This skill uses **inline prompt dispatch** — all logic
is embedded in the phases below. No separate `agents/*.md` files.

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for the full initialization
sequence.

Use CodeSift to discover route definitions, controller files, and middleware chains.
After generating any test script files, update the index: `index_file(path="/absolute/path/to/file")`

## Mandatory File Reading

Before starting work, read each file below. Print the checklist with status.

```
CORE FILES LOADED:
  1. {plugin_root}/shared/includes/codesift-setup.md   -- READ/MISSING
  2. {plugin_root}/shared/includes/env-compat.md        -- READ/MISSING
  3. {plugin_root}/shared/includes/auto-docs.md         -- READ/MISSING
  4. {plugin_root}/shared/includes/session-memory.md    -- READ/MISSING
```

Where `{plugin_root}` is resolved per `env-compat.md`.

**If any CORE file is MISSING:** Proceed in degraded mode. Note in Phase 4 output.

---

## Scenario Definitions

Each scenario models a different traffic pattern. Default run executes smoke, load,
and stress in sequence.

| Scenario | Virtual Users | Duration | Purpose |
|----------|--------------|----------|---------|
| `smoke` | 1 | 10s | Verify endpoints respond correctly under zero contention |
| `load` | N (default 50) | 30s | Simulate expected production traffic |
| `stress` | 2×N (default 100) | 60s | Find the breaking point and saturation behavior |
| `spike` | 0 → N → 0 | 30s | Test auto-scaling and recovery under sudden bursts |
| `soak` | N/2 (default 25) | 5m | Detect memory leaks, connection exhaustion, GC pressure |

The `--users` flag sets N. The `--duration` flag overrides the default duration for
all scenarios except soak (which always runs at least 5m unless explicitly overridden).

---

## Phase 0: Discover Endpoints

**Goal:** Build a map of every testable endpoint in the project.

1. **Detect API framework** — identify the routing layer:
   - Node.js: Express (`app.get/post/...`, `router.*`), Fastify (`fastify.route`), NestJS (`@Get/@Post` decorators), Hono
   - Python: Django (`urlpatterns`), FastAPI (`@app.get`), Flask (`@app.route`)
   - Ruby: Rails (`routes.rb`, `resources`)
   - Go: Gin, Echo, Chi, net/http
   - If CodeSift is available, use `search_symbols` for router/controller decorators
   - If CodeSift is unavailable, use file search for common route patterns

2. **Classify each endpoint:**
   ```
   ENDPOINT MAP:
     Method  Path                Auth    Category     Priority
     GET     /api/health         none    infra        low
     POST    /api/auth/login     none    auth         critical
     GET     /api/users          token   read         medium
     POST    /api/orders         token   transaction  critical
     GET     /api/search?q=      none    search       high
   ```

3. **Identify critical flows** — endpoints with the highest traffic or revenue impact:
   - Authentication (login, token refresh)
   - Search (often highest traffic)
   - Checkout / transactions (highest revenue impact)
   - File upload / download (highest resource consumption)

4. **If specific endpoint provided via arguments:** skip discovery, validate the
   endpoint exists, and proceed with that single endpoint.

Print: `ENDPOINTS: [N] discovered ([N] critical, [N] auth-protected)`

---

## Phase 1: Generate Load Scripts

**Goal:** Produce executable load test scripts for all target endpoints and scenarios.

### Step 1.1: Tool Selection

Detect available load testing tools in this priority order:

| Priority | Tool | Detection | Install hint |
|----------|------|-----------|-------------|
| 1 | k6 | `which k6` | `brew install k6` or `go install go.k6.io/k6@latest` |
| 2 | Artillery | `which artillery` or `npx artillery` | `npm install -g artillery` |
| 3 | Playwright | `npx playwright --version` | `npm install -D @playwright/test` |
| 4 | ab (Apache Bench) | `which ab` | `apt install apache2-utils` or `brew install httpd` |

If `--tool` is specified, use that tool. If specified tool is not installed, print
the install command and proceed with `--generate-only` behavior.

If NO tool is detected and `--tool` is not specified: generate k6 scripts (most
portable) and print install instructions. Automatically enable `--generate-only`.

### Step 1.2: Script Generation

For each endpoint × scenario combination, generate a test script containing:

1. **Configuration block** — virtual users, duration, thresholds
2. **Auth setup** — if endpoint requires auth:
   - Look for existing test fixtures, factories, or seed data
   - Generate a setup function that obtains a valid token/session
   - Parameterize credentials (never hardcode secrets)
3. **Test data** — realistic payloads:
   - For POST/PUT: derive payload shape from request validation schemas, types, or existing tests
   - For GET with params: generate representative query strings
   - Use data from existing fixtures/factories when available
4. **Assertions per request:**
   - Status code (2xx expected)
   - Response time < threshold (p95 < 500ms default)
   - Response body structure (optional, for smoke only)
5. **Scenario configuration:**
   - Smoke: 1 VU, 10s, strict thresholds
   - Load: N VUs, ramping over 10s, sustain, ramp down
   - Stress: 2N VUs, aggressive ramp, sustain at peak
   - Spike: instant ramp to N, hold 5s, drop to 0
   - Soak: N/2 VUs, 5m sustained

Save scripts to: `tests/load/` (create directory if needed).

Print: `SCRIPTS: [N] test scripts generated for [tool]`

If `--generate-only`: skip to Phase 4 output.

---

## Phase 2: Execute Tests

**Goal:** Run each scenario and capture raw metrics.

### Execution Order

Run scenarios sequentially to avoid interference:

1. **Smoke** — validates endpoints are alive before heavier tests
2. **Load** — expected traffic pattern
3. **Stress** — find the ceiling
4. _(spike and soak only if explicitly requested via `--scenario`)_

### Per-Scenario Capture

For each scenario, capture:

| Metric | Description |
|--------|-------------|
| p50 latency | Median response time in ms |
| p95 latency | 95th percentile response time in ms |
| p99 latency | 99th percentile response time in ms |
| Error rate | Percentage of non-2xx responses |
| Throughput | Requests per second (sustained average) |
| Peak throughput | Maximum rps observed in any 1s window |
| Response size | Average response body size in bytes |
| Connection errors | TCP/TLS failures (distinct from HTTP errors) |

### Error Handling

- If a scenario has **>5% error rate**: flag with a warning, continue to next scenario.
  Do not abort — partial data is more useful than no data.
- If a scenario **fails to start** (tool crash, port conflict): log the error,
  skip that scenario, continue with remaining scenarios.
- If **all scenarios fail**: report the failure reason and exit with diagnostic suggestions.

Print progress per scenario:
```
SCENARIO: smoke [RUNNING] → 1 VU, 10s
SCENARIO: smoke [DONE] → p95=45ms, errors=0%, rps=120
SCENARIO: load  [RUNNING] → 50 VUs, 30s
SCENARIO: load  [DONE] → p95=180ms, errors=0.2%, rps=850
SCENARIO: stress [RUNNING] → 100 VUs, 60s
SCENARIO: stress [DONE] → p95=420ms, errors=3.1%, rps=1200
```

---

## Phase 3: Analyze Results

**Goal:** Interpret raw metrics against thresholds and detect regressions.

### Step 3.1: Threshold Evaluation

Evaluate each endpoint × scenario against these thresholds:

| Metric | Good | Warning | Critical |
|--------|------|---------|----------|
| p95 latency | <200ms | 200–500ms | >500ms |
| p99 latency | <500ms | 500ms–1s | >1s |
| Error rate | <1% | 1–5% | >5% |
| Throughput | >100 rps | 50–100 rps | <50 rps |

Assign each metric a verdict: `PASS`, `WARN`, or `FAIL`.

### Step 3.2: Baseline Comparison (if `--compare`)

Read `memory/perf-baseline.json`. For each metric on each endpoint:

- **Regression:** metric is >20% worse than baseline → flag as `REGRESSION`
- **Improvement:** metric is >20% better than baseline → note as `IMPROVED`
- **Stable:** within 20% → `STABLE`

Print comparison table:
```
BASELINE COMPARISON:
  Endpoint            Metric      Baseline    Current     Delta     Verdict
  POST /api/orders    p95         120ms       180ms       +50%      REGRESSION
  GET  /api/users     p95         90ms        70ms        -22%      IMPROVED
  GET  /api/search    error_rate  0.5%        0.8%        +60%      REGRESSION
  POST /api/auth      throughput  200 rps     210 rps     +5%       STABLE
```

### Step 3.3: Bottleneck Identification

Rank endpoints by severity across all scenarios:

1. **Slowest endpoint** — highest p95 under load
2. **Least reliable** — highest error rate under load
3. **Heaviest response** — largest average response size
4. **Worst scaling** — largest p95 increase from smoke → stress (ratio)

For each bottleneck, suggest a likely root cause:
- High latency + low error rate → slow query or external call
- High error rate at high concurrency → connection pool exhaustion or rate limiting
- Large response → missing pagination or unnecessary data inclusion
- Poor scaling ratio → synchronous bottleneck or lock contention

### Step 3.4: Baseline Save (if `--baseline`)

Write results to `memory/perf-baseline.json` with structure:
```json
{
  "timestamp": "ISO-8601",
  "tool": "k6",
  "endpoints": {
    "GET /api/users": {
      "smoke":  { "p50": 12, "p95": 25, "p99": 40, "error_rate": 0, "rps": 150 },
      "load":   { "p50": 45, "p95": 90, "p99": 150, "error_rate": 0.1, "rps": 850 },
      "stress": { "p50": 120, "p95": 280, "p99": 450, "error_rate": 1.2, "rps": 1100 }
    }
  }
}
```

---

## Phase 4: Report

Save results to `docs/load-test-results.md` with:

1. **Summary table** — all endpoints, all scenarios, all metrics
2. **Threshold verdicts** — color-coded PASS/WARN/FAIL per metric
3. **Baseline comparison** — if `--compare` was used
4. **Bottleneck analysis** — ranked list with root cause suggestions
5. **Recommendations** — concrete next steps (ordered by impact)
6. **Generated scripts** — file paths for re-running tests

Print the output block:

```
LOAD TEST COMPLETE
  Endpoints:  [N] tested ([N] critical flows)
  Tool:       [k6/artillery/playwright/ab]
  Scenarios:  smoke [PASS/WARN/FAIL], load [PASS/WARN/FAIL], stress [PASS/WARN/FAIL]
  p95:        [smoke]ms / [load]ms / [stress]ms
  Error rate: [smoke]% / [load]% / [stress]%
  Throughput: [load] rps (peak: [stress] rps)
  Bottleneck: [endpoint] — [reason]
  Baseline:   [saved/compared/none]
  Report:     docs/load-test-results.md
  Scripts:    tests/load/
```

If `--generate-only` was active, adjust the output:
```
LOAD TEST COMPLETE (generate-only)
  Endpoints:  [N] targeted ([N] critical flows)
  Tool:       [k6/artillery/playwright/ab]
  Scripts:    [N] generated in tests/load/
  Next step:  Install [tool], then run: [command to execute]
```

---

## Auto-Docs

Read `{plugin_root}/shared/includes/auto-docs.md` for the full protocol.

**This skill updates:**

| File | Update |
|------|--------|
| `docs/project-journal.md` | Log: load test run, endpoints tested, key findings |

Do NOT update `docs/architecture.md` or `docs/api-changelog.md` — this skill
does not modify code or API surfaces.

---

## Session Memory

Read `{plugin_root}/shared/includes/session-memory.md` for the full protocol.

**Update `memory/project-state.md`** with:
- Last load test date and scenario results
- Baseline status (exists / stale / missing)
- Any regressions detected
- Bottleneck endpoints flagged for follow-up

---

## Run Log

Append one line to `memory/zuvo-runs.log` per `{plugin_root}/shared/includes/run-logger.md`.

| Field | Value |
|-------|-------|
| SKILL | `load-test` |
| VERDICT | `PASS` if all metrics PASS, `WARN` if any WARN, `FAIL` if any FAIL |
| NOTES | Scenarios run, endpoint count, worst metric, baseline action |
