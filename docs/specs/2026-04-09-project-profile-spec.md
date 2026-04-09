# Project Profile — Design Specification

> **spec_id:** 2026-04-09-project-profile-1507
> **topic:** Deterministic project convention analysis via CodeSift + shared profile for all zuvo skills
> **status:** Approved
> **created_at:** 2026-04-09T15:07:00Z
> **approved_at:** 2026-04-09T15:30:00Z
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

Every zuvo skill that needs to know about the project's stack, conventions, or patterns re-detects them independently. At least 25 skills duplicate stack detection logic (reading `package.json`, `tsconfig.json`, etc.) with no shared protocol. This duplication wastes tokens, creates divergence (skill A may detect "Hono" while skill B detects "TypeScript"), and — critically — provides no framework-specific convention data.

The `write-tests` skill needs to know concrete values (middleware chain order, rate limit parameters, auth boundary matrix) to generate high-quality ORCHESTRATOR tests. Currently, these values are hardcoded in `test-code-types.md` from one project (tgmcontest). Every other project gets generic checklists.

Without a shared, deterministic project understanding:
- Test generation is generic, not project-specific (quality ceiling ~8/10 instead of ~9.5/10)
- Each skill invocation pays token cost for inline stack detection
- Convention drift between skills is invisible
- Adding framework awareness to a new skill requires re-implementing detection from scratch

## Design Decisions

### DD1: Separation of concerns — CodeSift extracts facts, skills interpret prose

**Chosen:** Strict separation. CodeSift (Python, AST-based) extracts deterministic facts into structured JSON. Zuvo skills (LLM) read JSON and generate human-readable checklists and prose.

**Rejected:** LLM-powered extraction (Variant B/C from brainstorm). Four critical hidden costs:
1. **Recurring token cost** — ~$2-3 per project scan, every time. Deterministic extractors have zero marginal cost.
2. **Non-deterministic output** — same file produces different results across runs. Debugging and regression testing become impossible.
3. **Silent failure on unknown frameworks** — LLM produces plausible-sounding but wrong checklists. Python extractors fail loudly: "cannot parse, unknown pattern."
4. **Cross-file reasoning weakness** — multi-file convention extraction (rate limit in `app.ts` bound to path in `routes/contests.ts`) is where LLMs are weakest. AST cross-referencing is deterministic.

**Why this matters:** The profile is consumed by every skill in the ecosystem. Non-deterministic or silently-wrong data propagates errors across all 49 skills.

### DD2: Tiered file classification, not exhaustive

**Chosen:** Three tiers — critical (full detail, handful of files), important (path + type + metrics, dozens), routine (aggregate counts only, hundreds compressed to ~5 lines).

**Rejected:** Exhaustive per-file classification.
- 300-500 files in a typical project → 10K+ line JSON, 90% boilerplate
- Invalidates on every new file addition
- Overwhelms skills that parse it with irrelevant noise
- Communicates inventory, not hierarchy

Tier assignment is deterministic via Python heuristics: entry points + security boundaries → critical; services + controllers → important; utils + types → routine.

### DD3: Profile is additive to existing `.zuvo/` infrastructure

**Chosen:** `.zuvo/project-profile.json` coexists with existing `.zuvo/context/project-context.md`. The old file remains for backward compatibility until all skills are migrated (Phase 3). No migration required for existing `.zuvo/` users.

**Rejected:** Replacing `project-context.md` immediately. Too risky — `execute` and `plan` skills depend on it. Dual-source period is explicitly bounded: old file deprecated after Phase 3 completion.

### DD4: Composable profile with user overrides

**Chosen:** CodeSift generates base profile. User can create `.zuvo/profile-overrides.json` to correct misdetections or add project-specific wisdom. Merge logic: overrides take precedence per-key. Known gotchas from `.zuvo/gotchas.md` are a separate user-editable channel.

**Why:** Auto-detection will be wrong sometimes. Overrides prevent users from either editing generated files (overwritten on regeneration) or filing bug reports for project-specific edge cases.

### DD5: Phased delivery with Day 0 validation script

**Chosen:** Validation script (`compare-checklists.py`) is a Day 0 prerequisite before Phase 1A starts. It defines REQUIRED_INVARIANTS as regex patterns against the tgmcontest ORCHESTRATOR checklist. This prevents "works in demo, breaks in real use" — success is quantified from day 1.

**Rejected:** "Validate manually after MVP." Same problem as ad-hoc agent feedback — subjective, non-replicable, non-trackable.

## Solution Overview

```
CodeSift MCP Server (Python)
├── analyze_project(repo) → JSON
│   ├── stack_detector.py (generic, all projects)
│   ├── file_classifier.py (tiered, all projects)
│   ├── dependency_analyzer.py (hub/leaf/orphan detection)
│   ├── test_convention_detector.py (generic, all projects)
│   └── extractors/
│       ├── hono_extractor.py (Phase 1A)
│       ├── nestjs_extractor.py (Phase 2)
│       ├── react_extractor.py (Phase 3)
│       └── generic_extractor.py (fallback)
└── Output: structured JSON with file:line evidence

Zuvo Plugin (Markdown)
├── shared/includes/project-profile-protocol.md (loading protocol)
├── skills/write-tests/SKILL.md (first consumer)
├── skills/execute/SKILL.md (first generator, Phase 1B/2)
└── .zuvo/project-profile.json (cached per project)

Data Flow:
  Skill Phase 0 → protocol.md → read .zuvo/project-profile.json
    → if missing/stale → call CodeSift analyze_project()
    → write .zuvo/project-profile.json
    → return profile to skill
    → skill uses conventions for test planning / stack-aware behavior
```

## Detailed Design

### Data Model — Profile Schema v1.0

```json
{
  "version": "1.0",
  "generated_at": "2026-04-09T10:30:00Z",
  "generated_by": {
    "tool": "codesift",
    "tool_version": "2.3.1",
    "extractor_versions": {
      "hono": "1.2.0",
      "stack_detector": "1.0.0",
      "file_classifier": "1.0.0"
    }
  },
  "compatible_with": ">=1.0, <2.0",
  "status": "complete | partial | failed",

  "identity": {
    "project_name": "tgmcontest",
    "project_type": "monorepo | single",
    "workspace_root": "/Users/greglas/DEV/tgmcontest",
    "git_remote": "github.com/greglas/tgmcontest",
    "detected_from": ["package.json:name", "git config"]
  },

  "stack": {
    "framework": "hono",
    "framework_version": "4.12.1",
    "language": "typescript",
    "language_version": "5.3",
    "test_runner": "vitest",
    "package_manager": "pnpm",
    "monorepo": {
      "tool": "turborepo",
      "workspaces": ["apps/*", "packages/*"]
    }
  },

  "file_classifications": {
    "critical": [
      {
        "path": "apps/api/src/app.ts",
        "code_type": "ORCHESTRATOR",
        "reason": "Main Hono app with middleware composition",
        "dependents_count": 0,
        "has_tests": true
      }
    ],
    "important": [
      {
        "path": "apps/api/src/services/contest.service.ts",
        "code_type": "SERVICE",
        "dependents_count": 8,
        "has_tests": true
      }
    ],
    "routine": {
      "count": 127,
      "by_type": {
        "PURE": 89,
        "TYPE_DEF": 23,
        "CONSTANT": 15
      }
    }
  },

  "dependency_graph": {
    "entry_points": ["apps/api/src/index.ts", "apps/web/src/main.tsx"],
    "hub_modules": [
      {
        "path": "apps/api/src/middleware/auth.js",
        "imported_by_count": 14,
        "depth_from_entry": 2
      }
    ],
    "leaf_modules": ["apps/api/src/utils/constants.ts"],
    "circular_dependencies": [],
    "orphan_files": ["apps/api/src/old/deprecated.ts"]
  },

  "conventions": {
    "middleware_chains": [
      {
        "scope": "global",
        "file": "apps/api/src/app.ts",
        "chain": [
          {"name": "requestId", "line": 28, "order": 1},
          {"name": "errorHandler", "line": 29, "order": 2},
          {"name": "corsMiddleware", "line": 30, "order": 3},
          {"name": "dbMiddleware", "line": 31, "order": 4}
        ]
      },
      {
        "scope": "admin",
        "file": "apps/api/src/app.ts",
        "chain": [
          {"name": "clerkAuth", "line": 35, "order": 1},
          {"name": "tenantResolver", "line": 36, "order": 2}
        ]
      }
    ],
    "rate_limits": [
      {
        "file": "apps/api/src/app.ts",
        "line": 46,
        "max": 3,
        "window": 3600,
        "applied_to_path": "/api/contests/:slug/register",
        "method": "POST"
      }
    ],
    "route_mounts": [
      {
        "file": "apps/api/src/app.ts",
        "line": 36,
        "mount_path": "/api/admin/contests",
        "imported_from": "./routes/admin/contests/index.js",
        "exported_as": "default"
      }
    ],
    "auth_patterns": {
      "auth_middleware": "clerkAuth",
      "groups": {
        "admin": {"requires_auth": true, "middleware": ["clerkAuth", "tenantResolver"]},
        "public": {"requires_auth": false, "middleware": ["publicTenantResolver"]},
        "webhook": {"requires_auth": false, "middleware": []},
        "health": {"requires_auth": false, "middleware": []}
      }
    },
    "workspaces": {
      "apps/api": {
        "framework": "hono",
        "middleware_chains": ["(same structure as root conventions)"],
        "rate_limits": [],
        "route_mounts": [],
        "auth_patterns": {}
      },
      "apps/web": {
        "framework": "react",
        "component_patterns": {}
      }
    }
  },

  "test_conventions": {
    "mock_style": "vi.mock",
    "uses_vi_hoisted": true,
    "assertion_library": "vitest",
    "file_patterns": ["*.test.ts", "*.spec.ts"],
    "describe_style": "nested",
    "setup_patterns": ["beforeEach with vi.clearAllMocks"],
    "db_test_pattern": "transaction rollback"
  },

  "known_gotchas": {
    "auto_detected": [
      {
        "gotcha": "Hono compose catches downstream errors at dispatch level",
        "detected_from": "codesift pattern match: error propagation in middleware",
        "evidence": ["apps/api/src/middleware/error.js:12"],
        "workaround": "Use app.onError() instead of middleware try/catch"
      }
    ],
    "user_documented": {
      "path": ".zuvo/gotchas.md",
      "last_updated": null,
      "count": 0
    }
  },

  "generation_metadata": {
    "files_analyzed": 312,
    "files_skipped": 45,
    "skip_reasons": {
      "binary": 12,
      "too_large": 3,
      "parse_error": 30
    },
    "duration_ms": 1847
  }
}
```

**Tier assignment heuristics (deterministic Python):**

| Tier | Criteria |
|------|----------|
| Critical | Entry points (`app.ts`, `main.ts`, `server.ts`, `index.ts` at app root); files in `*/middleware/*`, `*/security/*`, `*/auth/*`, `*/crypto/*`; hub nodes with >N unique importers; files exporting `app`, `server`, `handler` |
| Important | Files in `*/services/*`, `*/controllers/*`, `*/routes/*`; files exporting >3 public functions/classes; files with external I/O imports (DB, API, FS); files with business logic patterns |
| Routine | Files in `*/utils/*`, `*/helpers/*`, `*/constants/*`, `*/types/*`; pure function files; type definition files; re-export barrel files |

### API Surface — CodeSift MCP Tool

```python
@mcp_tool
def analyze_project(repo_id: str, force: bool = False) -> dict:
    """
    Analyze a repository to extract stack, conventions, file classifications,
    dependency graph, test conventions, and known gotchas.
    
    Returns structured JSON conforming to project-profile schema v1.0.
    Convention-level facts (middleware chains, rate limits, route mounts, auth patterns)
    include file:line evidence. Stack-level facts (framework, language) include
    detection source (e.g., "package.json:dependencies.hono") but not line numbers.
    
    Args:
        repo_id: Repository identifier from list_repos()
        force: If True, ignore cached results and re-analyze
    
    Returns:
        dict with status: "complete" | "partial" | "failed"
        Partial results include populated sections with missing sections absent.
    """
```

Per-framework extractors are internal to CodeSift — not exposed as separate MCP tools. `analyze_project()` auto-detects the framework and dispatches the appropriate extractor.

**Error contract:**

| Scenario | Behavior | Minimum fields in response |
|----------|----------|---------------------------|
| Success (all extractors ran) | Returns dict, `status: "complete"` | All 8 sections populated |
| Partial (some extractors failed/timed out) | Returns dict, `status: "partial"` | `version`, `generated_at`, `generated_by`, `status`, `generation_metadata` + whichever sections succeeded. Missing sections are absent (not null). |
| Failed (cannot analyze at all) | Returns dict, `status: "failed"` | `version`, `generated_at`, `generated_by`, `status`, `generation_metadata` with `skip_reasons` explaining why. No content sections. |
| Unrecoverable (invalid `repo_id`, crash) | Raises MCP error (exception, not dict) | Standard MCP error response. Loading protocol Step 8 catches this and falls to Step 9. |

The loading protocol distinguishes: dict with `status: "failed"` → write to disk as a marker, skip to Step 9 (legacy). MCP exception → do not write, skip to Step 9.

**Additional tool for version checking:**

```python
@mcp_tool
def get_extractor_versions() -> dict:
    """
    Return current extractor versions without triggering analysis.
    Used by the loading protocol to check if cached profile was generated
    by an older extractor version (cache invalidation trigger #5).
    
    Returns:
        {"hono": "1.2.0", "stack_detector": "1.0.0", "file_classifier": "1.0.0", ...}
    """
```

This is a fast metadata call (~1ms). Without it, the only way to check extractor versions would be to run `analyze_project()` — defeating the purpose of cache invalidation.

### Integration Points

**1. New shared include: `shared/includes/project-profile-protocol.md`**

**Phase 1A minimal protocol (3 steps):**

This is what ships first. The full 12-step protocol (below) replaces it in Phase 1B.

```
Step 0: Check ZUVO_USE_PROFILE env var — if "false", skip to Step 3 immediately.
Step 1: Try to read .zuvo/project-profile.json. If missing or JSON parse error → Step 2.
        If valid → check mtime of package.json and main entry point against generated_at. If newer → Step 2.
        If fresh → return profile.
Step 2: If CodeSift available → call analyze_project(repo) → write result to .zuvo/project-profile.json → return profile.
        If CodeSift unavailable → Step 3.
Step 3: Fall back to inline stack detection (current per-skill behavior). Set degraded flag.
```

No locking, no sanity checks, no partial status handling, no overrides merge. These are Phase 1B additions. The 3-step protocol is intentionally compatible with the 12-step expansion — Steps 1-3 above map to Steps 2/7-8/9 of the full protocol.

**Phase 1B full protocol (12 steps):**

The 12-step loading protocol consumed by all skills at Phase 0:

```
Step 0:  Check ZUVO_USE_PROFILE env var — if "false", skip EVERYTHING below, use legacy inline detection. Return immediately.
Step 1:  Acquire lock .zuvo/.profile.lock (timeout 30s, stale PID check)
Step 2:  Try to read .zuvo/project-profile.json
Step 3:  If parse fails → log to .zuvo/profile-errors.log, treat as missing (→ Step 7)
Step 4:  If valid → sanity check (required sections exist, critical not empty, metadata sensible)
Step 5:  If sanity fails → log, treat as missing (→ Step 7)
Step 6:  If valid + sane → check version compatibility (compatible_with field)
Step 7:  If incompatible OR missing → check CodeSift availability
Step 8:  If CodeSift available → call analyze_project() → write profile → go to Step 10
Step 9:  If CodeSift unavailable → inline stack detection (current behavior), set degraded flag → Step 12
Step 10: Check profile status field: complete → Step 11; partial → Step 11 with degraded flag; failed → Step 9
Step 11: If --no-cache flag set by skill → discard loaded profile, go to Step 7 (force regeneration via analyze_project(force=True))
Step 12: Release lock, return profile (or degraded flag)
```

**Cache invalidation (5 triggers, checked at Step 2 with 50ms budget):**

| # | Trigger | Check |
|---|---------|-------|
| 1 | Critical files | mtime of `package.json`, `tsconfig.json`, `vitest.config.*`, entry points > `generated_at` |
| 2 | Middleware dirs | mtime of any `*/middleware/` directory > `generated_at` |
| 3 | Recent tests | mtime of 5 most recent `*.test.*` files > `generated_at` |
| 4 | User overrides | mtime of `.zuvo/profile-overrides.json` > `generated_at` |
| 5 | Extractor version | `generated_by.extractor_versions` differs from current CodeSift versions |

If budget (50ms) exhausted before all checks complete → accept profile as fresh (optimistic). Log warning for next run if async check finds staleness.

**`--no-cache` flag:** Skills that support profile regeneration accept `--no-cache` as an argument (added to their Argument Parsing table). The protocol receives this as a boolean input. When set:
- Phase 1A: Skip Step 1 entirely, go directly to Step 2 (regenerate)
- Phase 1B: Step 11 discards loaded profile and forces regeneration via `analyze_project(force=True)`
- Example: `zuvo:write-tests app.ts --no-cache` regenerates profile before test planning

**2. Skill modifications:**

`skills/write-tests/SKILL.md` Phase 0 Step 2 becomes:
```
2. **Project profile:** Load project profile per project-profile-protocol.md.
   If profile.conventions exists for this file's framework:
     - Use convention values for ORCHESTRATOR test planning
     - Generate checklist from profile facts (middleware names, rate limit values, auth boundaries)
   If profile unavailable or partial:
     - Use generic test-code-types.md patterns (current behavior)
```

**3. Profile overrides merge:**

When `.zuvo/profile-overrides.json` exists, merge after loading base profile:
- Overrides take precedence per-key (deep merge)
- Override keys set to `null` delete the corresponding base key
- Merged result is NOT written back to profile (base stays regeneratable)

**Overrides schema:** The overrides file is a **sparse subset** of the full profile schema. Any key path from the profile schema is valid. Only include keys you want to change — omitted keys inherit from the generated profile.

```json
// .zuvo/profile-overrides.json — example
{
  "stack": {
    "framework": "hono-custom-fork"
  },
  "file_classifications": {
    "critical": [
      {
        "path": "apps/api/src/worker.ts",
        "code_type": "ORCHESTRATOR",
        "reason": "Manual override: background job orchestrator"
      }
    ]
  },
  "known_gotchas": {
    "user_documented": {
      "path": ".zuvo/gotchas.md"
    }
  }
}
```

Merge rules:
- Scalar values: override replaces base (`"hono-custom-fork"` replaces `"hono"`)
- Objects: deep merge recursively (only specified nested keys are replaced)
- Arrays: override **appends** to base (e.g., adding a critical file does not remove existing critical files). To replace an array entirely, set the key to the full replacement array.
- `null` value: deletes the key from base (`"orphan_files": null` removes orphan_files from dependency_graph)

### Edge Cases

| Edge case | Category | Handling |
|-----------|----------|----------|
| **No framework detected** | Data | `status: "partial"`, `stack.framework: null`. Skills fall back to generic detection. |
| **Monorepo with mixed frameworks** | Data | Single profile at monorepo root. `stack` reflects dominant/root framework. Per-workspace stacks and conventions nested under `conventions.workspaces[workspace_name]`. Skills match file path against `stack.monorepo.workspaces` patterns to find the relevant workspace conventions. |
| **No test files in project** | Data | `test_conventions` section populated with `null` values. Skills skip convention-based test planning. |
| **CodeSift index not ready** | Timing | `analyze_project()` triggers index if needed (existing CodeSift behavior). May add ~3-8s latency on first run. |
| **Large repo analysis timeout** | Timing | CodeSift has internal timeouts. Returns `status: "partial"` with whatever was extracted before timeout. |
| **Stale cache after code changes** | Timing | 5-trigger invalidation detects most changes. `--no-cache` flag for manual force. |
| **Concurrent skill execution** | Timing | Lock file `.zuvo/.profile.lock` with PID. Second skill waits up to 30s, then uses stale/missing path. Stale lock (dead PID) auto-cleaned. |
| **Corrupted JSON** | Integration | Parse failure → log to `.zuvo/profile-errors.log` → regenerate silently. |
| **CodeSift unavailable** | Integration | Degraded flag set. Skill uses legacy inline detection. Warning on first occurrence per session. |
| **Framework misidentified** | Detection | User creates `.zuvo/profile-overrides.json` with correct `stack.framework`. Override takes precedence on next load. |
| **Extractor version mismatch** | Detection | Trigger 5 detects version difference → regeneration with updated extractor. |
| **ZUVO_USE_PROFILE=false** | Rollback | All skills skip profile loading entirely. Legacy behavior restored. No errors. |

## Acceptance Criteria

### Functional (must pass for ship)

1. `analyze_project()` correctly detects Hono + TypeScript + Vitest + pnpm from tgmcontest
2. File classification produces tiered output with `app.ts` in critical tier as ORCHESTRATOR
3. Hono extractor finds all middleware chains with correct ordering and `file:line` evidence
4. Hono extractor finds all rate limit registrations with `max`, `window`, `applied_to_path`
5. Hono extractor finds all route mounts with `mount_path` and `imported_from`
6. Auth boundary detection identifies admin/public/webhook/health groups with correct middleware lists
7. Profile written to `.zuvo/project-profile.json` with valid schema v1.0
8. `write-tests` successfully loads profile and uses conventions for ORCHESTRATOR test planning
9. Profile regenerates when `package.json` mtime is newer than `generated_at`
10. Profile regenerates when entry point (`app.ts`) mtime is newer than `generated_at`
11. Degraded mode works: skill falls back to inline detection when CodeSift unavailable
12. Lock file prevents concurrent regeneration corruption
13. Corrupted JSON triggers silent regeneration (not crash), logged to `profile-errors.log`
14. `--no-cache` flag forces full regeneration regardless of staleness
15. `.zuvo/profile-overrides.json` merged into generated profile, overrides take precedence
16. Generation metadata includes `files_analyzed`, `duration_ms`, `skip_reasons`
17. `status: "partial"` returned when framework detection fails, with available sections populated

### Quality (must pass for success)

Quality criteria #18-20 involve non-deterministic LLM output. Measured as: **N=5 runs on same commit, median value must meet threshold.**

18. Auto-generated test (using profile) for tgmcontest `app.ts`: median Q score >= 16/19 across 5 runs, without adversarial passes. Deterministic proxy: generated test file covers all REQUIRED_INVARIANTS categories from Day 0 script.
19. Time to write tests for second ORCHESTRATOR file in same project: median <= 50% of median time without profile (same 5-run protocol, same file, same commit)
20. Profile loading adds < 2000 tokens to skill context (deterministic — measured by profile JSON size, not LLM variance)
21. Auto-generated checklist achieves >= 80% invariant coverage measured by `validation/compare-checklists.py` against `REQUIRED_INVARIANTS_TGMCONTEST_ORCHESTRATOR` (30+ invariants: middleware order, per-route mounts, auth boundary matrix, per-path rate limit binding, all 6 rate limit values)
22. Profile loads from cache on second skill invocation in < 100ms (no regeneration)

### Rollback

23. Setting `ZUVO_USE_PROFILE=false` disables profile loading globally; all skills revert to legacy behavior with no errors

## Out of Scope

### Permanently out of scope

- Real-time profile updates via file watcher (mtime check at skill startup is sufficient)
- Server-side profile sync across machines (profile is local cache, regenerated per machine)
- Extractors for PHP/Composer (no active projects)

### Deferred to v2

- Cross-project analysis (comparing conventions across repos) — requires aggregation infrastructure
- Auto-fixing convention violations — requires authoring capability in CodeSift
- GUI/dashboard for profile visualization — low priority, not discarded
- Python/FastAPI extractor — defer until demand from active projects
- Astro extractor — defer until demand (Astro projects are content sites, less convention-heavy)

## Open Questions

1. ~~**Monorepo workspace granularity**~~ **RESOLVED:** Single file at monorepo root with per-workspace sections inside `conventions`. Rationale: the loading protocol assumes a single path (`.zuvo/project-profile.json`), `execute` generates one file, and per-workspace files would require workspace detection in every skill's Phase 0. The profile's `stack` section reflects the dominant/root framework; workspace-specific stacks and conventions are nested under `conventions.workspaces[workspace_name]`. Skills that operate on a specific workspace file can look up that workspace's conventions by matching the file path against `stack.monorepo.workspaces` patterns.

2. **Profile TTL fallback:** If all 5 invalidation triggers pass (profile looks fresh) but the profile is >7 days old, should there be an age-based staleness threshold as a safety net? Or trust the triggers completely?

3. **`execute` skill integration timing:** Should `execute` generate the profile during its Stack Detection phase (Phase 1B candidate) or should profile generation remain a lazy-init concern of the loading protocol only?

## Phasing

### Day 0: Validation Script (prerequisite, ~4-6 hours)

Before any implementation begins:
- Write `validation/compare-checklists.py` with `REQUIRED_INVARIANTS_TGMCONTEST_ORCHESTRATOR`
- 30+ regex patterns covering the categories below
- This is the success criterion for Phase 1A — not an afterthought

**Script interface:**

```
# Invocation
python validation/compare-checklists.py <checklist_file>

# Output (JSON to stdout, exit code 0 on success, 1 on failure)
{
  "total_required": 32,
  "matched": 28,
  "unmatched": ["rate_limit_5_3600_path_binding", "webhook_no_auth_negative", ...],
  "extra_invariants": 3,
  "score": 0.875,
  "pass": true
}

# Exit code: 0 if score >= 0.80, 1 otherwise
```

**Required invariant categories (each category contains multiple regex patterns):**

| Category | Example invariants | Minimum count |
|----------|-------------------|---------------|
| Middleware order | `callOrder.*toEqual.*requestId.*errorHandler.*corsMiddleware.*dbMiddleware` | 4 (one per route group) |
| Route mounting | `app\.route.*\/api\/admin\/contests` for each mounted route | 1 per route module |
| Rate limit factory | `rateLimit.*toHaveBeenCalledWith.*3.*3600` for each rate limit | 6 (one per registration) |
| Rate limit path binding | Request to path, check callOrder contains `rateLimit(max/window)` | 6 (one per registration) |
| Auth boundary positive | `callOrder.*toContain.*clerkAuth` for admin routes | 2 (admin + public tenant) |
| Auth boundary negative | `callOrder.*not\.toContain.*clerkAuth` for public/webhook/health | 3 (one per non-auth group) |
| 404 unknown path | Request to unknown path returns 404 | 1 |
| Health endpoint | Health check returns 200 | 1 |

The invariant list itself is the Day 0 deliverable — the categories above anchor what must be covered. Exact patterns are derived from tgmcontest `app.ts` source.

### Phase 1A: Core MVP (5 working days)

**CodeSift (separate repo):**
- Generic stack detector (`stack_detector.py`)
- Generic file classifier (`file_classifier.py`) with tiered heuristics
- Hono extractor (`hono_extractor.py`) — middleware chains, rate limits, route mounts, auth patterns
- `analyze_project()` MCP tool wiring
- Profile schema v1.0 with 4 core sections: `stack`, `file_classifications`, `conventions`, `generation_metadata`

**Zuvo plugin:**
- `shared/includes/project-profile-protocol.md` — minimal 3-step protocol (read, fall back, regenerate)
- `skills/write-tests/SKILL.md` — Phase 0 integration with profile consumption
- Fallback flag: if profile unavailable, use legacy detection (no degradation for users without CodeSift)

**Validation:** Run on tgmcontest `app.ts`. `compare-checklists.py` score >= 80%.

### Phase 1B: Production Hardening (3-5 working days)

- Schema extended to all 8 sections: `identity`, `dependency_graph`, `test_conventions`, `known_gotchas`
- Loading protocol extended to full 12 steps (lock file, sanity checks, corruption recovery, partial status)
- 5-trigger cache invalidation with 50ms budget
- `.zuvo/profile-overrides.json` merge logic
- `ZUVO_USE_PROFILE=false` rollback mechanism
- Migration metrics logging
- Optional: `execute` skill integration (if Phase 1A validation passes)

### Phase 2: Ecosystem Integration (after Phase 1B validation)

- Migrate `execute` skill to generate profile during initialization (if not done in 1B)
- NestJS extractor (~2 days)
- Migrate `refactor` + `review` skills to consume profile
- Fallback flag remains active (2-version deprecation window)

### Phase 3: Full Coverage

- React, Next.js extractors (~2 days each)
- Migrate remaining Tier 2/3 skills (incremental, one skill per release)
- Remove fallback flags after 2 stable releases with profile
- Deprecate `.zuvo/context/project-context.md` stack field (keep file for execution state)
- Migration helper script for users with existing `.zuvo/` directories

## Backward Compatibility

- `.zuvo/context/project-context.md` remains unchanged through Phase 2. New profile is additive.
- Skills with profile integration maintain legacy fallback for 2 versions minimum.
- After Phase 3, `project-context.md` `stack` field is deprecated (execution state fields remain).
- No migration required for existing `.zuvo/` users — profile is a new file alongside existing infrastructure.
- `.zuvo/project-profile.json` is machine-local cache (contains absolute paths in `identity.workspace_root`). It MUST be gitignored. The existing `.zuvo/` gitignore rule (added by `execute` skill) already covers this. Phase 1A setup verifies `.zuvo/` is in `.gitignore`.

## Rollback Strategy

| Scenario | Action |
|----------|--------|
| Profile has critical bug | Set `ZUVO_USE_PROFILE=false` → all skills revert to legacy |
| Single skill regression | Delete `.zuvo/project-profile.json` → skill regenerates or falls back |
| CodeSift extractor regression | Profile regenerates with corrected extractor on next run |
| Schema migration needed | `compatible_with` field triggers auto-regeneration when schema version changes |
