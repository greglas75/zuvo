---
name: retro
description: >
  Engineering retrospective from git metrics. Reports deployment frequency,
  release cycle span, churn hotspots, backlog health. Outputs narrative report
  with 3+ actionable items. Flags: --since, --path, explicit range argument.
category: Release
---

# zuvo:retro

Generate an engineering retrospective from git history, backlog state, and skill usage trends. Produces a narrative report with actionable items.

**Scope:** Post-release or periodic retrospective covering shipping velocity, code churn, backlog health, and quality trends.
**Out of scope:** Actually fixing issues (use the suggested zuvo commands in the Actionable Items section).

## Argument Parsing

| Input | Action |
|-------|--------|
| _(empty)_ | Auto-detect window from `memory/last-ship.json` or last two git tags |
| `<range>` | Explicit git range, e.g., `v1.0.0..v1.2.0` |
| `--since <tag>` | Start of retrospective window (open-ended, through HEAD) |
| `--path <dir>` | Scope git analysis to a subdirectory (required for monorepos) |

---

## Environment Compatibility

**Dispatch is already authorized — do not ask, do not downgrade.** Invoking this skill IS the
request for every agent and gate it mandates, so a session rule about unprompted Agent use does not
apply here. Only a harness with NO dispatch capability takes the documented single-agent fallback,
and it still runs every gate inline — see `../../shared/includes/env-compat.md`. Skipping a mandated
agent and self-scoring the result is a substituted gate, not a degraded run.

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across all supported platforms.

## Mandatory File Loading

```
CORE FILES LOADED:
  1. ../../shared/includes/env-compat.md    -- READ
  2. ../../shared/includes/run-logger.md    -- READ
```

Both files must be read before proceeding. If either is missing, note "DEGRADED -- [file] unavailable" in the report and continue with reduced capability.

---

## Phase 0: Window Detection

Determine the retrospective window in this priority order:

1. **Explicit argument** — if `<range>` was provided (e.g., `v1.0.0..v1.2.0`), use it directly.
2. **`--since <tag>`** — if provided, window is `<tag>..HEAD`. No `--until` flag is defined.
3. **`memory/last-ship.json`** — read the file if it exists. Use the `range` field (SHA-based, e.g., `"abc1234..def5678"`). If the artifact uses a legacy version-based range, fall back to it.
4. **Last two git tags** — run `git describe --tags --abbrev=0` twice (with `--exclude` on first result) to derive `<prev-tag>..<latest-tag>`.
5. **Fallback** — if fewer than two tags exist, use the last 30 commits: derive range as `HEAD~30..HEAD`.

**Count commits in window:**
```bash
git log --oneline <range> | wc -l
```

### Edge Case E13 — Insufficient History

If commit count is **< 10**: output "Insufficient history for statistical metrics" and produce a qualitative-only report. Skip Phases 1 and 3 (no git metrics, no skill trends to aggregate). Use Phase 2 (backlog health) as the sole data source. Still produce Phase 4 actionable items and Phase 5 report.

### Edge Case E14 — Monorepo Detection

Check for monorepo signals in the project root:
- `turbo.json`
- `nx.json`
- `pnpm-workspace.yaml`

If any of these files exist AND no `--path` argument was provided:
1. First, try auto-detection: run `git diff --name-only <range>` and extract unique top-level directories matching workspace package paths.
2. If only ONE package was touched: auto-scope to that package with `[AUTO-DECISION]: scoped to <package>`.
3. If multiple packages were touched:
   - **Interactive:** list the affected packages and ask the user to pick one or confirm full-repo analysis.
   - **Non-interactive:** `[AUTO-DECISION]: monorepo detected, analyzing all affected packages. Results may be noisy — re-run with --path for focused analysis.` Proceed with full-repo analysis.

If `--path` was provided: scope all `git log` commands with `-- <path>` and note the scope in the report.

---

## Phase 1: Git Metrics

Run these commands against the resolved `<range>` (append `-- <path>` if `--path` was provided).

### Deployment Frequency

Count **release tags** within the window, not arbitrary tags.

**Counting method:**
```bash
git tag --sort=creatordate --merged HEAD | grep -E '^v[0-9]' | while read tag; do
  TAG_DATE=$(git log -1 --format="%ai" "$tag")
  # keep only tags whose date falls within the window
done
```

Priority for identifying release tags:
1. Tags matching a semver-like pattern (`v*.*.*`, `v[0-9]*`)
2. Tags referenced by `memory/last-ship.json` (`newTag`, `previousTag`) — cross-reference, not sole source
3. If no release tag pattern can be identified, report:
   `Deployment frequency unavailable — no reliable release tag pattern detected`

Ignore unrelated tags (experimental, package-local, scratch tags). `memory/last-ship.json` covers only the most recent release; for multi-release windows, the git tag scan is the primary data source.

### Release Cycle Span

Estimate the time span covered by the release window:
```bash
git log --format="%ai %H" <range>
```
Use the earliest commit date in the window as the start and the latest tag date as the end. Report as: N days (earliest commit → latest tag). Note: this is the window span, not per-PR lead time — exact branch-to-merge lead time requires per-PR analysis with `gh pr list`.

### Churn Hotspots

Find the top 5 most-changed files in the window:
```bash
git log --name-only --pretty=format: <range> | sort | uniq -c | sort -rn | head -5
```
Git, deliberately — not CodeSift `analyze_hotspots`. A retrospective must run on any
checkout, including one with no index and no MCP server, and churn-by-commit-count is
exactly what this section reports. The frontmatter used to declare `analyze_hotspots` as
"KEY" alongside nine other tools that no step ever called; `compute-preload` reads that
field, so it was instructing agents to load ten tools for a skill that uses none.
Filter out empty lines. Report as a ranked list: filename (N changes).

---

## Phase 2: Backlog Health

Read `memory/backlog.md` if it exists — at the MAIN checkout root, resolved per `../../shared/includes/backlog-protocol.md` "Where the Backlog Lives" (in a linked worktree a CWD-relative read silently sees no backlog).

If the file **does not exist**: note "No backlog tracked. Run `zuvo:review` or `zuvo:code-audit` to populate." Skip all backlog metrics.

If the file **exists**, count:
- **Open items** — rows where Status = `OPEN`
- **Critical items** — OPEN rows where Severity = `CRITICAL`
- **Resolved in window** — rows where Status = `RESOLVED` and the Resolved/Updated date (not Added date) falls within the window. If backlog.md has no Resolved date column, skip this metric and note: "Resolved-in-window metric unavailable — backlog lacks Resolved date column."
- **Added in window** — rows where Added date falls within the retrospective window

Also identify the oldest unresolved item (earliest Added date among OPEN rows) and report its ID and age in days.

---

## Phase 3: Skill Usage Trends

Read the skill usage log using the environment-aware path from `run-logger.md` (primary: `~/.zuvo/runs.log`, Codex App fallback: `memory/zuvo-runs.log`).

If the file **does not exist** at either path: note "No skill usage history found." Skip this section.

If the file **exists**, parse each line by splitting on tab characters (`\t`):

- **Lines with 10 tab characters (11 fields):** populate all fields:
  ```
  DATE  SKILL  PROJECT  CQ_SCORE  Q_SCORE  VERDICT  TASKS  DURATION  NOTES  BRANCH  HEAD_SHA7
  ```
- **Lines with 8 tab characters (9 fields):** populate the first 9 fields as above, treat BRANCH and HEAD_SHA7 as `-`
- **Lines that match neither pattern** (e.g., pipe-delimited legacy entries like `2026-03-31T05:20:44Z | SKILL: brainstorm | ...`): skip silently

**DATE parsing:** handle both `T...Z` (with Z suffix) and `T...` (without Z) formats as UTC.

Filter to entries where:
- `PROJECT` matches the current project directory basename
- `DATE` falls within the retrospective window

From the filtered entries, aggregate:
- **Most-used skills** — rank by frequency
- **Average CQ score** — parse `CQ_SCORE` field, skip `-` entries, average the numerator/denominator separately
- **Average Q score** — same approach as CQ
- **Pass/fail ratio** — count PASS vs FAIL vs WARN verdicts
- **Branch distribution:** [branch: N runs, ...] (e.g., `main: 8, feature/x: 2`) — only display when at least one 11-field entry exists in the filtered window

---

## Phase 3b: Per-Task Telemetry (optional)

Read the per-task telemetry file `zuvo:execute` appends at Step 9b — one JSON line per finished
task, schema documented in `../../shared/includes/session-state.md` →
`zuvo/context/task-telemetry.jsonl`. This is a project-local, per-task counterpart to Phase 3's
HOME-global `~/.zuvo/runs.log`: gate-failure counts, reviewer-route distribution, and retry hotspots
that Phase 3's one-line-per-run log cannot surface.

Resolve the file the same way the writer does: `$ZUVO_OUTPUT_DIR`, else `<git root>/zuvo`, then
`context/task-telemetry.jsonl` under it — no `pwd` fallback (deliberately removed from the writer;
do not reintroduce one here). **No project-name filter** — unlike `runs.log` (shared across every
project on the machine), this file is project-local by construction, so filtering would be wrong,
not merely redundant.

If the file **does not exist**: note "No per-task telemetry found." Skip this section — the same
degradation shape Phase 3 already uses for a missing `runs.log`.

If the file **exists**, parse it line by line. A blank or whitespace-only physical line — the normal
trailing newline of an append-only file, not a corrupt one — is not a record and is excluded from
BOTH counts below; every **non-blank** line is then either fully counted in `records=` or fully
counted in `skipped=`, never dropped in between. A kill between `write` and `fsync` can leave a
truncated trailing line, and this file is never rewritten to repair one (see `session-state.md`'s
"Reader contract").

Three corruption shapes must each become a *counted* skip, because each of them aborts a naive
reader **outside** a `try` that wraps only `json.loads`, and an abort discards every record already
parsed — uncounted in both `records=` and `skipped=`, which is precisely the silent data loss the
Reader contract forbids:

1. **Unparseable text** — plain garbage; `json.loads` raises `ValueError`.
2. **Valid JSON that is not an object** — `null`, a bare number, `[]`. These parse *fine* and then
   raise `AttributeError` at the first `.get`, so the guard must wrap the whole per-line body, not
   just the parse, and must reject a non-`dict` explicitly.
3. **A truncated multi-byte UTF-8 tail** — the exact "crash between `write` and `fsync`" case. Text
   mode decodes **eagerly**, so `UnicodeDecodeError` is raised by the *iteration itself*, before any
   per-line `try` is reached. Read the file in **binary** and decode each line defensively.

Reading is also this reader's own responsibility, not the shell's: an unreadable/vanished path and
any other failure are reported by the reader with its partial counts intact. The `|| echo "[WARN]"`
tail stays as a last resort, not the normal error path.

From the well-formed records, aggregate:
- **Gate-failure counts** — a gate field (`spec-review`, `quality-review`, `adversarial`) lands in one
  of three states, never a plain pass/fail: **failed** (present, a string, and not the passing
  value), **missing** (absent, `null`, or any non-string JSON value — a bool/number/nested object
  stringified into `"True"`/`"3"` is malformed input, not a real verdict, and must never be compared
  as one), or passing. `gate-failures=` counts only the **failed** state; `gate-missing=` reports the
  missing state **separately**, so a pre-schema or truncated record can never inflate the failure
  tally. The `PASS` prefix match on `quality-review`/`adversarial` is **case-sensitive by contract** —
  the writer always emits the literal uppercase form, so a lowercased value is itself a sign of a
  hand-edited or corrupt record and must fail, not silently pass.
- **Reviewer-route distribution** — tally by `reviewer-route` (`review-primary`, `review-alt`,
  `same-model-fallback`, `routing-failed`).
- **Implementer-status tally** (blocked/skipped reasons) — tally by `implementer-status` (`DONE`,
  `DONE_WITH_CONCERNS`, `NEEDS_CONTEXT`, `BLOCKED`).
- **Failure-strategy distribution** — bucketed into `halt`, `skip-and-continue`, `degraded`,
  `unknown` and `missing`. Two rules matter here:
  - **`missing` is its own bucket, never folded into `halt`.** The writer always emits the field, so
    an absent one means an OLD or CORRUPT record — reporting it as `halt` would present silence as a
    deliberate decision.
  - **`degraded:<desc>` collapses to one `degraded` bucket**, with
    `degraded-distinct-descriptions=<N>` printed alongside — **capped** at 64 distinct descriptions
    tracked for that count; past the cap, further distinct text is tallied as an approximate
    `(+N more)` overflow instead of growing the tracked set without bound. `<desc>` is free text;
    keying the tally by it yields one entry per task on a long run — a distribution with no signal.

```bash
# >>> zuvo:retro-telemetry
RT_DIR="${ZUVO_OUTPUT_DIR:-}"
if [ -z "$RT_DIR" ]; then
  _RT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$_RT_ROOT" ]; then RT_DIR="$_RT_ROOT/zuvo"; fi
fi
RT_PATH="${RT_DIR:+$RT_DIR/context/task-telemetry.jsonl}"
if [ -z "$RT_PATH" ] || [ ! -f "$RT_PATH" ]; then
  echo "No per-task telemetry found."
else
  python3 - "$RT_PATH" <<'PY' \
    || echo "[WARN] per-task telemetry read failed — continuing (diagnostic, never a gate)"
import json, sys

# SCHEMA SSOT — every `F_* = "<key>"` below is a telemetry field name this reader
# touches, and they are declared HERE, once. Case (y) of tests/skill-suite/test-
# task-telemetry-contract.sh checks these literals against the
# `zuvo:telemetry-schema` table in shared/includes/session-state.md — the same
# discipline the WRITER's `K = [...]` follows, but as CONTAINMENT rather than the
# writer's equality diff, because this reader deliberately touches only a subset
# of the documented keys. Without that check a schema rename is invisible here:
# `rec.get(key, default)` never raises on a renamed key, so retro would report
# 100% gate failure forever and nothing would say so. Never inline a field name at
# a use site — the test forbids a literal `.get("<key>"` here for that reason.
F_SPEC = "spec-review"
F_QUALITY = "quality-review"
F_ADVERSARIAL = "adversarial"
F_ROUTE = "reviewer-route"
F_STATUS = "implementer-status"
F_STRATEGY = "failure-strategy"

# Bound on distinct free-text `degraded:<desc>` tails tracked for the
# degraded-distinct-descriptions count below. Free text is author-controlled
# and a long-lived file could carry many distinct ones; past this many the
# reader stops trying to dedup exactly and reports the remainder as an
# approximate "+N more" overflow instead of growing the tracked set forever.
DEGRADED_DESC_CAP = 64

path = sys.argv[1]
n = 0
skipped = 0
gate = {F_SPEC: 0, F_QUALITY: 0, F_ADVERSARIAL: 0}
gate_missing = {F_SPEC: 0, F_QUALITY: 0, F_ADVERSARIAL: 0}
reviewer_route = {}
implementer_status = {}
failure_strategy = {}
degraded_descs = set()
degraded_overflow = 0


def bump(tally, key):
    tally[key] = tally.get(key, 0) + 1


def enum_str(rec, key):
    val = rec.get(key)
    return val if isinstance(val, str) and val else "unknown"


def gate_status(rec, key, mode):
    # Same isinstance/non-empty guard as strategy_bucket() below: an ABSENT
    # field and a non-string field (a bool/int/nested value that str() would
    # otherwise stringify into a fake "True"/"3" verdict) are BOTH "missing",
    # never "failed" — a pre-schema or truncated record must not inflate the
    # failure tally, and a non-string value must never be compared as a verdict.
    val = rec.get(key)
    if not isinstance(val, str) or not val:
        return "missing"
    if mode == "exact":
        return "passed" if val == "COMPLIANT" else "failed"
    # mode == "prefix": case-sensitive BY CONTRACT, not an oversight — the
    # writer always emits the literal uppercase "PASS ..." form (schema in
    # session-state.md), so a lowercased/mixed-case value is itself a sign of
    # a hand-edited or corrupt record and must fail, never silently pass.
    return "passed" if val.startswith("PASS") else "failed"


def strategy_bucket(rec):
    # An ABSENT failure-strategy is NOT a declared `halt`: the writer always emits
    # the field, so absence means an old or corrupt record. `missing` keeps silence
    # from being reported as a decision. `degraded:<desc>` is BUCKETED rather than
    # keyed by its free-text description (one key per task is not a distribution);
    # the distinct-description count is printed alongside so variety is not lost.
    val = rec.get(F_STRATEGY)
    if not isinstance(val, str) or not val:
        return "missing", None
    if val in ("halt", "skip-and-continue"):
        return val, None
    if val.startswith("degraded:"):
        return "degraded", val[len("degraded:"):]
    return "unknown", None


def emit():
    print("records=%d skipped=%d" % (n, skipped))
    print("gate-failures spec-review=%d quality-review=%d adversarial=%d"
          % (gate[F_SPEC], gate[F_QUALITY], gate[F_ADVERSARIAL]))
    print("gate-missing spec-review=%d quality-review=%d adversarial=%d"
          % (gate_missing[F_SPEC], gate_missing[F_QUALITY], gate_missing[F_ADVERSARIAL]))
    print("reviewer-route " + " ".join("%s=%d" % kv for kv in sorted(reviewer_route.items())))
    print("implementer-status " + " ".join("%s=%d" % kv for kv in sorted(implementer_status.items())))
    strategies = " ".join("%s=%d" % kv for kv in sorted(failure_strategy.items()))
    if degraded_descs:
        strategies += " degraded-distinct-descriptions=%d" % len(degraded_descs)
        if degraded_overflow:
            strategies += " (+%d more)" % degraded_overflow
    print("failure-strategy " + strategies)


try:
    # Binary, deliberately: a text-mode `for raw in fh` decodes EAGERLY, so a
    # truncated multi-byte tail raises UnicodeDecodeError from the ITERATION —
    # outside any per-line try — and kills the read after records already counted.
    fh = open(path, "rb")
except OSError as exc:
    # This reader owns its errors. Falling through to the shell's `|| echo` would
    # discard the counts entirely and say nothing about which path failed.
    print("per-task telemetry unreadable (%s) — skipping" % (exc,))
    print("records=0 skipped=0")
    sys.exit(0)

try:
    with fh:
        for raw in fh:
            # The WHOLE per-line body is guarded, not just the parse: valid JSON
            # that is not an object (`null`, `3`, `[]`) parses fine and then raises
            # AttributeError at the first `.get`. Values are computed into locals
            # first and committed only afterwards, so a line can never land in
            # BOTH records= and skipped=.
            try:
                line = raw.decode("utf-8", "replace").strip()
                if not line:
                    # A blank/whitespace-only physical line is NOT a record —
                    # the normal trailing newline of an append-only file, not
                    # a corrupt one. Excluded from BOTH records= and skipped=
                    # on purpose: the Reader contract counts every REAL line
                    # into one bucket or the other, and a blank line is not a
                    # real line to begin with.
                    continue
                rec = json.loads(line)
                if not isinstance(rec, dict):
                    raise ValueError("record is not a JSON object")
                spec_status = gate_status(rec, F_SPEC, "exact")
                quality_status = gate_status(rec, F_QUALITY, "prefix")
                adversarial_status = gate_status(rec, F_ADVERSARIAL, "prefix")
                route = enum_str(rec, F_ROUTE)
                status = enum_str(rec, F_STATUS)
                strategy, desc = strategy_bucket(rec)
            except Exception:
                skipped += 1
                continue
            n += 1
            if spec_status == "failed":
                gate[F_SPEC] += 1
            elif spec_status == "missing":
                gate_missing[F_SPEC] += 1
            if quality_status == "failed":
                gate[F_QUALITY] += 1
            elif quality_status == "missing":
                gate_missing[F_QUALITY] += 1
            if adversarial_status == "failed":
                gate[F_ADVERSARIAL] += 1
            elif adversarial_status == "missing":
                gate_missing[F_ADVERSARIAL] += 1
            bump(reviewer_route, route)
            bump(implementer_status, status)
            bump(failure_strategy, strategy)
            if desc is not None:
                if desc in degraded_descs or len(degraded_descs) < DEGRADED_DESC_CAP:
                    degraded_descs.add(desc)
                else:
                    degraded_overflow += 1
except Exception as exc:
    # A read that dies mid-file still reports what it already aggregated. Partial
    # results plus the skip count beat the shell fallback's total silence.
    print("per-task telemetry read aborted after %d records (%s)" % (n, exc))

emit()
sys.exit(0)
PY
fi
# <<< zuvo:retro-telemetry
```

---

## Phase 4: Actionable Items

Generate **at least 3** specific, actionable items. Each item must:
- Reference a **specific file, directory, or backlog item** (not generic advice)
- Include a **specific zuvo command**
- State the **reason** derived from the data

### Derivation rules (priority order):

1. **High-churn files** — for each file in the churn hotspot list with N ≥ 5 changes: check whether a corresponding test file exists. If no test file found: `zuvo:write-tests <file>` with reason "high-churn, N changes, no test coverage found".
2. **Churn instability** — for files with N ≥ 5 changes that already have tests: `zuvo:refactor <file>` with reason "N changes suggest instability or unclear responsibilities".
3. **Critical backlog items** — for each OPEN CRITICAL item: `zuvo:backlog fix <ID>` with reason "critical debt item open N days".
4. **Old open items** — if oldest open item is > 14 days: `zuvo:backlog prioritize` with reason "oldest item open N days, prioritization overdue".
5. **Low CQ scores** — if average CQ score < 79% of applicable: `zuvo:code-audit <top-churn-directory>` with reason "CQ average below the 79% threshold".
6. **Low Q scores** — if average Q score < 53% of applicable: `zuvo:write-tests <top-churn-directory>` with reason "Q average below the 53% threshold suggests test quality gaps".

If fewer than 3 items can be derived from the data, supplement with: "Run `zuvo:code-audit .` to establish a quality baseline" or "Run `zuvo:test-audit .` to identify test gaps."

---

## Phase 5: Report and Output

### Write Report File

Create the report using a readable suffix:
- Prefer tag-based names when `previousTag` / `newTag` are known:
  `zuvo/reports/retro-YYYY-MM-DD-<previousTag>_<newTag>.md`
- Otherwise fall back to a shortened SHA-based suffix (first 7 chars of `baseSha` and `releaseCommitSha` from `last-ship.json`):
  `zuvo/reports/retro-YYYY-MM-DD-<baseSha7>_<releaseCommitSha7>.md`

This prevents collisions and keeps filenames readable. If `zuvo/reports/` does not exist, create it.

Use this exact structure:

```markdown
# Engineering Retrospective — YYYY-MM-DD

## Summary
[Tweetable one-liner: period, commits, releases, key metric]

## Shipping Velocity
- **Window:** <range> (<N> days, <N> commits)
- **Deployment frequency:** N releases in period (frequency: 1 per X days)
- **Release cycle span:** N days (earliest commit → latest tag)
- **Commits:** N total, N/day average

## Churn Hotspots
[Top 5 most-changed files with change count. Note if test file was found for each.]

| Rank | File | Changes | Has Tests |
|------|------|---------|-----------|
| 1 | src/orders/service.ts | 12 | No |
| 2 | src/auth/guard.ts | 8 | Yes |

## Backlog Health
- **Open items:** N (N critical, N high)
- **Added this period:** N
- **Resolved this period:** N
- **Oldest unresolved:** [item ID] — open N days

## Quality Trends
- **CQ scores:** avg N/<applicable> ([N runs in period], or "no runs.log data")
- **Q scores:** avg N/<applicable> ([N runs in period], or "no runs.log data")
- **Most-used skills:** [skill1 (N runs), skill2 (N runs)]
- **Pass/fail ratio:** N PASS, N WARN, N FAIL

## Actionable Items
1. `zuvo:write-tests src/orders/` — high-churn (12 changes), no test file found
2. `zuvo:refactor src/auth/guard.ts` — 8 changes suggest instability
3. `zuvo:backlog fix BD-007` — critical debt item open 21 days

## Comparison vs Prior Retro
[Delta table or "First retro — run again next period for trends"]
```

### Prior Retro Comparison

Check for existing `zuvo/reports/retro-*.md` files. If one or more exist, compare with the most recent:

| Metric | Prior | Current | Delta |
|--------|-------|---------|-------|
| Deployment frequency | N/period | N/period | +/-N |
| Release cycle span | N days | N days | +/-N days |
| Open backlog items | N | N | +/-N |
| Avg CQ score | N/<applicable> | N/<applicable> | +/-N |
| Avg Q score | N/<applicable> | N/<applicable> | +/-N |

If no prior retro exists: note "First retro — run again next period for trends."

### Terminal Output Block

Print the RETRO COMPLETE block after writing the report:

```
RETRO COMPLETE
  Window:      v1.1.0..v1.2.0 (14 days, 47 commits)
  Releases:    2 in period (frequency: 1 per week)
  Cycle span:  14 days (earliest commit → latest tag)
  Hotspots:    src/orders/service.ts (12 changes), src/auth/guard.ts (8 changes)
  Backlog:     +5 added, -3 resolved, 12 open (2 critical)
  Report:      zuvo/reports/retro-2026-03-28-v1.1.0_v1.2.0.md

  Actions:
  1. zuvo:write-tests src/orders/ — high-churn, low coverage
  2. zuvo:refactor src/auth/guard.ts — 8 changes suggest instability
  3. zuvo:backlog fix BD-007 — critical debt item open 21 days

  Run: <ISO-8601-Z>	retro	<project>	-	-	<VERDICT>	-	6-phase	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>

  After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.
```

If E13 (insufficient history) was triggered, show:

```
RETRO COMPLETE [QUALITATIVE ONLY — <10 commits in window]
  Window:      HEAD~30..HEAD (fallback — fewer than 10 commits found)
  Backlog:     +N added, -N resolved, N open (N critical)
  Report:      zuvo/reports/retro-YYYY-MM-DD-<suffix>.md

  Actions:
  1. [derived from backlog only]

  Run: <ISO-8601-Z>	retro	<project>	-	-	<VERDICT>	-	qualitative	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>

  After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.
```

