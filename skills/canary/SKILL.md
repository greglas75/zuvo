---
name: canary
description: >
  Post-deploy monitoring with browser or degraded HTTP mode. Checks console errors,
  performance, page load. Configurable duration (1m-30m) and interval.
  Reports HEALTHY/DEGRADED/BROKEN. Flags: --duration, --interval, --quick, --max-errors.
---

# zuvo:canary

Monitor production after deployment. Browser-based or HTTP-only health checks with configurable duration.

## Argument Parsing

| Argument | Effect |
|---|---|
| `<url>` | Production URL to monitor (REQUIRED) |
| `--duration <time>` | Monitoring duration (default: 10m, range: 1m-30m) |
| `--interval <time>` | Check interval (default: 60s) |
| `--quick` | Single health check, no loop |
| `--max-errors <n>` | Error threshold for FAIL verdict (default: 3) |

## Mandatory File Loading

Before starting any phase, read these shared includes:

```
INCLUDES LOADED:
  1. ../../shared/includes/env-compat.md     — READ
  2. ../../shared/includes/run-logger.md     — READ
```

---

## Phase 0: Setup

### Step 1: Validate URL

If no URL argument is provided, STOP immediately:

```
URL is required. Usage: zuvo:canary https://myapp.com
```

### Step 2: Detect Browser Tools

Use `ToolSearch` to check for `mcp__playwright__*` or `mcp__chrome-devtools__*` tools:

- If found: set `MODE=full` (browser-based checks available)
- If not found: set `MODE=degraded`. Print:

  ```
  [DEGRADED: no browser tools] — running HTTP-only checks. Console errors and screenshots unavailable.
  ```

### Step 3: Check Environment (per env-compat.md)

If running in Codex or Cursor (non-interactive environment):

- Force `--quick` behavior (single check, no polling loop).
- Print:

  ```
  [AUTO-DECISION]: one-shot mode — polling loop not available in this environment.
  ```

### Step 4: Parse Arguments

Parse `--duration` and `--interval`. Validate duration range (1m–30m inclusive). If duration is outside this range, stop with:

```
--duration must be between 1m and 30m. Got: <value>
```

Defaults:
- `--duration`: 10m
- `--interval`: 60s
- `--max-errors`: 3

---

## Phase 1: Platform Context (optional)

Read `../../shared/includes/platform-detection.md` and follow the detection algorithm.

If a platform is detected, note its health check command. This is supplementary — the primary check is always the URL-based approach in Phase 2. Platform detection may provide additional commands (e.g., `fly status`) that can supplement the HTTP check.

---

## Phase 2: Monitoring Loop

### One-shot mode

If `--quick` is passed, or non-interactive environment was detected in Phase 0: run exactly ONE check cycle, then proceed to Phase 3.

### Loop mode

Otherwise: run one check cycle every `--interval` seconds, for the total `--duration`. Track cumulative error count across all checks.

### Check Cycle — Full Mode (Playwright or Chrome DevTools available)

1. Navigate to URL:
   - Playwright: `mcp__playwright__browser_navigate(url=<url>)`
   - Chrome DevTools: `mcp__chrome-devtools__navigate_page(url=<url>)`

2. Check HTTP status: expect 200. Non-200 = CRITICAL alert.

3. Capture console errors:
   - Playwright: `mcp__playwright__browser_console_messages()`
   - Chrome DevTools: `mcp__chrome-devtools__list_console_messages()`

   Record error-level entries. Each new Error-level console message = HIGH alert. Accumulate total error count.

4. Measure page load time. Response time >10s = MEDIUM alert.

5. Take screenshot: save to `audit-results/canary-{ISO-timestamp}/check-{N}.png`
   - Playwright: `mcp__playwright__browser_take_screenshot(path=...)`
   - Chrome DevTools: `mcp__chrome-devtools__take_screenshot(path=...)`
   - ISO-timestamp format: `YYYY-MM-DDTHHMM` (e.g., `2026-03-28T1430`)

### Check Cycle — Degraded Mode (HTTP only)

1. Run:
   ```bash
   curl -s -o /dev/null -w "%{http_code} %{time_total}" <url>
   ```

2. Check HTTP status: expect 200. Non-200 = CRITICAL alert.

3. Record response time. Response time >10s = MEDIUM alert.

4. No console error capture. No screenshots.

### Alert Conditions (per check)

| Condition | Severity |
|---|---|
| Page load failure (non-200 HTTP status) | CRITICAL |
| New console errors (Error level) | HIGH |
| Response time >10s | MEDIUM |

---

## Phase 3: Output

### Step 1: Determine Verdict

After all check cycles complete, assess the cumulative results:

- **HEALTHY:** All checks returned 200, console errors at or below `--max-errors` threshold, no critical failures.
- **DEGRADED:** No critical failures (all 200s), but warnings present — slow response times, minor console warnings, or console error count approaching `--max-errors` threshold.
- **BROKEN:** Any of the following: page load failure (non-200), critical console errors observed, or cumulative console error count exceeds `--max-errors` threshold.

### Step 2: Rollback Suggestion (BROKEN verdict only)

If verdict is BROKEN, print:

```
Suggested next step: zuvo:deploy rollback — revert to previous stable deployment.
```

Also reference the platform-specific rollback command from Phase 1 if a platform was detected.

### Step 3: Baseline Comparison

Check if prior canary runs exist in `audit-results/canary-*/`. If found, compare average response time against the prior run's average and compute a percentage delta for the performance line.

If no prior run exists, omit the baseline comparison from the Performance line.

### Step 4: Print CANARY COMPLETE Block

```
CANARY COMPLETE
  URL:         <url>
  Duration:    <duration> (<N> checks)
  Mode:        full (Playwright available) | degraded (HTTP-only)
  Console:     <N> errors, <N> warnings
  Performance: avg <N>s (baseline: <N>s, +<N>%) | avg <N>s (no baseline)
  Screenshots: audit-results/canary-<ISO-timestamp>/  [full mode only — omit in degraded mode]
  Verdict:     HEALTHY | DEGRADED | BROKEN
```

### Step 5: Append Run Log

Append a run log entry per `../../shared/includes/run-logger.md`.

---

## Edge Cases

| # | Condition | Handling |
|---|---|---|
| E11 | No browser MCP tools available | Degraded mode — HTTP-only. Annotate `[DEGRADED: no browser tools]`. |
| E12 | Non-interactive environment (Codex, Cursor) | Force one-shot mode. Annotate `[AUTO-DECISION]: one-shot mode`. |
| — | URL is missing | STOP with "URL is required" message. |
| — | Duration outside 1m–30m | STOP with range validation error. |
| — | First canary run (no baseline) | Omit baseline comparison from Performance line. |
| — | Screenshot directory doesn't exist | Create `audit-results/canary-{ISO-timestamp}/` before writing. |
