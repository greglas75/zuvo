# Implementation Plan: write-article + content-expand friction fixes

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (33-day usage analysis: 485 invocations total. write-article: 97 runs / 47 retro entries with explicit Friction section. content-expand: 77 runs / 22 retro entries with Friction section. The "~96%" figure quoted in the original brief was the rate of runs producing ANY retro at all (including pure-PASS retros), not the rate of runs with explicit friction. The actionable rate is **~48% for write-article (47/97), ~29% for content-expand (22/77)**. Both numbers are still high enough to justify this work.)
**plan_revision:** 2
**status:** Reviewed
**Created:** 2026-04-30
**Tasks:** 9
**Estimated complexity:** 7 standard, 2 complex

---

## Architecture Summary

Two SKILL.md files at `skills/write-article/SKILL.md` (290 LOC) and `skills/content-expand/SKILL.md` (258 LOC). Both are markdown-only artifacts: the "code" is prescriptive instructions executed by the harness LLM. No runtime, no tests, no build.

Shared dependencies (read by both at runtime via `../../shared/includes/`):
- `banned-vocabulary/core.md` + `banned-vocabulary/languages/<lang>.md` (split layout) — but installs may only ship `banned-vocabulary.md` (monolithic compat loader)
- `adversarial-loop-docs.md` (cross-model review protocol)
- `article-output-schema.md` / `content-expand-output-schema.md` (JSON contract)
- `env-compat.md` (subagent dispatch routing)
- `run-logger.md` (TSV emission)

External integration: `adversarial-review.sh` (Bash, host-aware provider selection).

**Verification model:** since these are skill files, "verify" = grep/regex assertions against the SKILL.md text + dry-run invocation against a real corpus from `tgm-payload`. No unit tests. Cross-model validation of the SKILL.md changes runs through `adversarial-review.sh --mode audit`.

## Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Compat fallback strategy | Try split first, fall back to monolithic, log `bv-mode: split\|monolithic` | 4 retros cite this exact friction; monolithic is the actual install state on Codex distribution |
| Locale resolution order | `--lang` → `data/parsed/<lang>-<CC>.{json,yaml}` glob → `content/articles/<lang>-<CC>/` glob → ask once → fallback `en` | Mirrors retro guidance; deterministic and grep-able |
| Sidecar JSON naming | If input file is `<slug>.md`, sidecar is `<slug>.json` (same dir, same basename). Only fall back to dated `YYYY-MM-DD-<slug>.json` when output goes to `output/articles/` default | Sibling-locale convention seen across `tgm-payload/content/articles/*` |
| --light mode | Skip Phase 4.3 (adversarial), skip JSON sidecar, skip retro markdown append (still emit TSV), skip OG/schema regeneration when frontmatter already supplies them | Mirror content-expand `--light` semantics for symmetry |
| Reviewer model pin | Add `model: sonnet` explicitly to anti-slop-reviewer dispatch in both skills, matching v1.3.98 pattern | Eliminates `writer: unknown / reviewer: unknown` telemetry holes |
| Adversarial timeout wrapper | Wrap with `timeout 120 ...` in the documented bash recipe; existing skip-on-124 logic already in place | Codex retros show timeout is the dominant adversarial failure mode |
| Meta length post-serialize check | Inline regex check after frontmatter YAML is assembled, not during PQ7 (which runs on the draft string) | Retro: 136-char description shipped because PQ7 ran pre-serialize |
| Telemetry NOTES enrichment | Append `wm:<writer-model>\|rm:<reviewer-model>` to NOTES in run-logger emission for both skills | Future retros need this to evaluate whether the model pin actually worked |

## Quality Strategy

These are documentation/instruction edits. Quality gates:

- **Grep assertions** — every change is detectable by a fixed regex against the SKILL.md.
- **Smoke run** — after each task, run the affected skill once on a small real input (`tgm-payload` FAQ pattern, COMPACT mode) and inspect the SETUP block + telemetry line.
- **Cross-model SKILL.md review** — at end of plan, run `adversarial-review.sh --mode audit` over the two changed SKILL.md files to catch instruction conflicts, internal contradictions, and missing-args coverage.
- **Retro regression check** — after deploy via `./scripts/dev-push.sh`, run the friction-rate query on `~/.zuvo/runs.log` 7 days after deploy. Single primary gate (others demoted to advisory):
  - Window: 7 calendar days from deploy timestamp
  - Minimum sample: 20 invocations across both skills (else extend window until N>=20, max 14 days)
  - Pass condition: write-article actionable friction rate <= 25% (down from 47/97 = 48% baseline) AND content-expand <= 15% (down from 22/77 = 29% baseline)
  - Measurement query (paste into terminal post-deploy):
    ```bash
    DEPLOY_TS="2026-04-30T00:00:00Z"   # set after dev-push completes
    awk -F'\t' -v cutoff="$DEPLOY_TS" '$1 > cutoff && ($2=="write-article" || $2=="content-expand") {print $2}' ~/.zuvo/runs.log | sort | uniq -c
    # then count retros with explicit "### Friction" subsection in same window:
    awk -v cutoff="$DEPLOY_TS" '/^## /{ts=$2; in_block=1; has_friction=0} in_block && /^### Friction/{has_friction=1} /^<!-- RETRO -->/{ if (in_block && ts>cutoff && has_friction) print ts; in_block=0 }' ~/.zuvo/retros.md | wc -l
    ```
  - Sample selection: NO cherry-picking. Use the full window's invocations across all locales/topics/--light/no-light variants.

Risk areas:
- Locale resolution heuristic could mis-resolve when both `data/parsed/` and `content/articles/` exist but disagree. Mitigation: prefer `content/articles/` if both present (sibling-locale convention is stronger evidence than data files which can be stale).
- --light mode dropping retro markdown append could mask future regressions. Mitigation: TSV row still emitted to `runs.log`, only retro markdown is skipped.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G1 | Schema-driven output (rigid YAML/JSON for output paths, FAQ, reports) | goal | Task 4, Task 5, Task 8 | Three sub-targets: sidecar naming, --light determinism, meta length validation |
| G2 | Force `model: sonnet` in adversarial dispatch | goal | Task 7 | |
| G3 | Add `--light` mode to write-article | goal | Task 6 | content-expand already has it (parity task) |
| G4 | Better frontmatter / banned-vocab detection (cache, fail loud) | goal | Task 1, Task 2 | Compat fallback (P1) + locale auto-resolution (P4) |
| G5 | Monitor adversarial timeouts post-v1.3.93 | goal | Task 3, Task 9 | Wrapper recipe + telemetry enrichment |
| C1 | banned-vocabulary path mismatch (split vs monolithic) | constraint | Task 1 | 4 retros |
| C2 | unknown writer/reviewer model in routing | constraint | Task 7, Task 9 | telemetry holes |
| C3 | sidecar JSON ambiguity | constraint | Task 4 | retro: prefer fixed name |
| C4 | locale resolution from country only | constraint | Task 2 | retro: probe data/parsed first |
| C5 | --site-dir auto-create when missing | constraint | Task 5 | retro: bs-BA, fr-SN |
| C6 | pipeline-heavy on small edits | constraint | Task 6 | usage: 9 events |
| C7 | adversarial timeout on long markdown | constraint | Task 3 | --mode article exists; needs OS timeout wrapper |
| C8 | meta description length post-serialize miss | constraint | Task 8 | retro: 136-char description |
| C9 | telemetry NOTES doesn't carry model identity | constraint | Task 9 | enables future retro analysis |

## Review Trail

- Plan reviewer: skipped (degraded — local synthesis instead of 3-agent dispatch; rationale documented in Phase 1 console output)
- Cross-model validation rev 1 (codex-5.3 + gemini + cursor-agent, mode=audit): 3 CRITICAL + 4 actionable WARNING findings
  - Gemini CRIT: Task 3 timeout wrapper exits 0 on ALL non-zero (not just 124) → FIXED in rev 2 (branch on `$? -eq 124`)
  - Gemini CRIT: Task 4/5 conflict — new site-dirs have no siblings → JSON would orphan to `output/articles/` → FIXED in rev 2 (Task 4 rule: `--site-dir` set always wins; sibling check is fallback only)
  - Cursor CRIT: Task 9 RED requires non-unknown wm:/rm: but GREEN allows unknown → FIXED in rev 2 (RED relaxed to "non-empty markers"; non-unknown gated only on `rm:`)
  - Codex WARN: baseline 96% vs 47/97=48% → FIXED in rev 2 (baseline corrected in source_of_truth + Quality Strategy)
  - Codex WARN: no reproducible measurement → FIXED in rev 2 (concrete `awk` query added to Post-merge §4)
  - Cursor WARN: Task 2 doesn't encode content/articles > data/parsed precedence → FIXED in rev 2
  - Cursor WARN: mixed monitoring windows (10 runs / 1 wk / 7 days) → FIXED in rev 2 (single primary gate: 7-day window, N>=20)
- Known concerns (not fixed, INFO/non-blocking):
  - Codex INFO: grep verifies wording not behavior — accepted; these are docs-only edits
  - Cursor INFO: hardcoded `/Users/greglas/DEV/zuvo-plugin` paths in Verify blocks — accepted for plan artifact (single-author plan); replace at execute time
  - Gemini WARN: meta-length fails open instead of blocking publication — accepted; cosmetic SEO defect should not block content shipping (logged as WARNING per design)
- Cross-model validation rev 2: deferred until execute-time; rev 1 fixes are deterministic edits to a planning doc with no runtime
- Status gate: Reviewed (cross-model + revision applied; awaiting user approval to promote to Approved)

---

## Task Breakdown

### Task 1: Banned-vocabulary compat fallback in both skills

**Files:**
- `skills/write-article/SKILL.md` (Mandatory File Loading + Phase 0)
- `skills/content-expand/SKILL.md` (Mandatory File Loading + Phase 0)

**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: docs-only edit. No test code. Acceptance is a grep assertion (see Verify).
- [ ] GREEN:
  Replace items 3+4 of `Mandatory File Loading` in `write-article/SKILL.md` with a try-split-then-fallback block that (a) attempts `banned-vocabulary/core.md` + `banned-vocabulary/languages/<lang>.md`, (b) falls back to `banned-vocabulary.md` if either is missing, (c) logs `bv-mode: split` or `bv-mode: monolithic` in the SETUP block, (d) keeps STOP behavior only when neither is found.
  Replicate the same pattern in `content-expand/SKILL.md` items 3 + 0.1.5.
  Add a new `EC-WA-13` (and matching `EC-CE-XX`) entry tagged `compat-fallback` so the behavior is referenceable.
- [ ] Verify:
  ```bash
  grep -E "bv-mode:|compat-fallback|banned-vocabulary\.md" /Users/greglas/DEV/zuvo-plugin/skills/write-article/SKILL.md /Users/greglas/DEV/zuvo-plugin/skills/content-expand/SKILL.md | wc -l
  ```
  Expected: at least `6` (3 markers × 2 files).
- [ ] Acceptance: G4, C1
- [ ] Commit: `write-article + content-expand: banned-vocabulary compat fallback (split → monolithic) — fixes EC-WA-13 / EC-CE-08 from 4 retros`

### Task 2: Locale auto-resolution from project signals (write-article)

**Files:**
- `skills/write-article/SKILL.md` (Phase 0 step 3, before vague-topic gate)

**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: docs-only edit. Acceptance is grep + dry-run telemetry inspection.
- [ ] GREEN:
  Insert a new Phase 0 sub-step `3a. Locale auto-resolution` BEFORE the existing language file resolution (current step 3). Order:
  1. If `--lang` given → use it.
  2. Else if topic mentions a country → resolve in this strict precedence:
     a. Glob `content/articles/*-<CC>/` first. If exactly one locale matches → use it (signal: `content/articles`).
     b. Only if no `content/articles/` match: glob `data/parsed/*-<CC>.{json,yaml}`. If exactly one matches → use it (signal: `data/parsed`).
     c. If `content/articles/` returns 2+: list them and ask once. Do NOT fall through to `data/parsed/` — sibling-locale evidence is authoritative once it exists.
     d. If `data/parsed/` returns 2+ AND no `content/articles/` match: list them and ask once.
  3. Else fall through to existing English fallback.
  Surface the resolved locale + signal source (`signal: --lang | content/articles | data/parsed | default-en`) in the SETUP block.

  **Precedence rationale:** `content/articles/` represents *shipped* articles authored by humans; their locale convention is the project's source of truth. `data/parsed/` is upstream payment/payload data which may be stale or include locales never published. The risk-section warning about "stale data/parsed signals" is encoded in this ordering.
- [ ] Verify:
  ```bash
  grep -nE "Locale auto-resolution|signal: --lang|data/parsed|content/articles" /Users/greglas/DEV/zuvo-plugin/skills/write-article/SKILL.md
  ```
  Expected: at least 4 hits; the new sub-step labeled `3a.` exists before line that currently resolves the language file.
- [ ] Acceptance: G4, C4
- [ ] Commit: `write-article: locale auto-resolution from data/parsed/ + content/articles/ before vague-topic gate`

### Task 3: Adversarial timeout wrapper recipe

**Files:**
- `skills/write-article/SKILL.md` (Phase 4.3)
- `skills/content-expand/SKILL.md` (Phase 2.7)
- `shared/includes/adversarial-loop-docs.md` (add explicit recipe block)

**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: docs-only edit.
- [ ] GREEN:
  In both SKILL.md files, replace the bare `adversarial-review --json --mode article --files "..."` recipe with the wrapped form that branches on the actual exit status (do NOT swallow non-timeout failures):
  ```
  timeout 120 adversarial-review --json --mode article --files "<path>"
  rc=$?
  if [ $rc -eq 124 ]; then
    echo '{"status":"timeout","budget":120}'
    # treat as SKIPPED per existing skill rule; do NOT block publication
  elif [ $rc -ne 0 ]; then
    echo "{\"status\":\"error\",\"exit\":$rc}" >&2
    # propagate genuine failures: surface as WARNING, do NOT mask as timeout
    exit $rc
  fi
  ```
  Genuine non-timeout adversarial failures (e.g., script crash, malformed JSON, no provider) MUST NOT be silently downgraded to "timeout" — that would mask actionable errors. Only `exit 124` maps to the documented timeout-skip path.
  In `adversarial-loop-docs.md`, add a dedicated `## Long-form artifact wrapper` section documenting the 120s budget, why it exists (write-article + content-expand markdown is long), and the strict `exit 124` → `status: timeout` mapping (vs other non-zero → propagate).
- [ ] Verify:
  ```bash
  grep -nE "timeout 120 adversarial-review|exit 124|Long-form artifact wrapper" /Users/greglas/DEV/zuvo-plugin/skills/write-article/SKILL.md /Users/greglas/DEV/zuvo-plugin/skills/content-expand/SKILL.md /Users/greglas/DEV/zuvo-plugin/shared/includes/adversarial-loop-docs.md
  ```
  Expected: at least `5` matches (wrapper in both skills + section header + 2 references).
- [ ] Acceptance: G5, C7
- [ ] Commit: `write-article + content-expand: wrap adversarial review in 120s OS timeout — Codex/Cursor retros show timeout is dominant failure`

### Task 4: Sidecar JSON naming convention

**Files:**
- `skills/write-article/SKILL.md` (Phase 5.5)
- `skills/content-expand/SKILL.md` (Phase 2.4 + Phase 3 reporting)

**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: docs-only edit.
- [ ] GREEN:
  In `write-article` Phase 5.5, replace the bare `output/articles/YYYY-MM-DD-{slug}.json` rule with this strict precedence (NOT contingent on siblings existing — Task 5 may have just created an empty `--site-dir`, which would orphan the JSON to the default path otherwise):
  - If `--site-dir` is set → ALWAYS write the sidecar to `{site-dir}/{md-basename}.json`, regardless of whether siblings exist. The sibling check is a *naming* hint (basename should match), not a *location* gate.
  - Naming convention inside `--site-dir`:
    - If at least one sibling `.json` matches an existing `.md` basename → use `{md-basename}.json` (sibling pattern).
    - Else → use `{md-basename}.json` anyway as the default — this establishes the convention for new locale folders that Task 5 just created.
  - Only when `--site-dir` is NOT set: fall back to default `output/articles/YYYY-MM-DD-{slug}.json`.
  In `content-expand` Phase 3 / report-write step, add explicit rule: report sidecar always matches input filename (`<basename>.content-expand.json` next to source) when `--site-dir` is set; never invent a dated sidecar that diverges from the source's existing convention.
  Add `EC-WA-14` / `EC-CE-09` entries tagged `sidecar-naming`.
- [ ] Verify:
  ```bash
  grep -nE "sidecar-naming|EC-WA-14|EC-CE-09|basename\.json|basename\}\.json" /Users/greglas/DEV/zuvo-plugin/skills/write-article/SKILL.md /Users/greglas/DEV/zuvo-plugin/skills/content-expand/SKILL.md
  ```
  Expected: at least `4` hits.
- [ ] Acceptance: G1, C3
- [ ] Commit: `write-article + content-expand: sibling-basename JSON sidecar convention when site-dir present`

### Task 5: --site-dir auto-create when missing

**Files:**
- `skills/write-article/SKILL.md` (Phase 5.4 Save File)

**Complexity:** standard
**Dependencies:** Task 4 (paths must be settled before mkdir logic lands)
**Execution routing:** default implementation tier

- [ ] RED: docs-only edit.
- [ ] GREEN:
  In Phase 5.4, before the write step, add an explicit instruction: "If `--site-dir` does not yet exist as a directory: create it with `mkdir -p <site-dir>` and emit `INFO: site-dir created at <path>`. Do NOT silently fall back to `output/articles/`." Reference rationale: new locale launches.
- [ ] Verify:
  ```bash
  grep -nE "mkdir -p|site-dir created|new locale launches" /Users/greglas/DEV/zuvo-plugin/skills/write-article/SKILL.md
  ```
  Expected: at least `3` hits.
- [ ] Acceptance: G1, C5
- [ ] Commit: `write-article: auto-create --site-dir for new locale launches instead of falling back to output/articles/`

### Task 6: --light mode for write-article

**Files:**
- `skills/write-article/SKILL.md` (Arguments table + Phase 4.3 + Phase 5.5 + retro section)

**Complexity:** complex
**Dependencies:** Task 4 (sidecar logic), Task 7 (model pin must be in place before --light bypasses adversarial)
**Execution routing:** deep implementation tier

- [ ] RED: docs-only edit. Acceptance is dry-run smoke test on a real COMPACT article.
- [ ] GREEN:
  Add to Arguments table: `| --light | Skip adversarial review, JSON sidecar, retro markdown append, knowledge curation. TSV row to runs.log still emitted. Use for fast COMPACT/single-FAQ generation. |`
  Phase 4.3: prepend "If `--light`: skip this phase. Record `Adversarial review: skipped (--light)` and continue."
  Phase 5.5: prepend "If `--light`: skip JSON sidecar."
  Retrospective section: prepend "If `--light`: skip markdown append. Still emit the single TSV line to `runs.log` so usage analytics see the run."
  Add `EC-WA-15` tagged `light-mode` describing the skip set explicitly.
  In COMPACT block (Phase 0 step 9), note that `--length < 800` does NOT auto-imply `--light` — they are independent flags.
- [ ] Verify:
  ```bash
  grep -nE "^\| --light |Adversarial review: skipped \(--light\)|EC-WA-15|light-mode" /Users/greglas/DEV/zuvo-plugin/skills/write-article/SKILL.md
  ```
  Expected: at least `4` hits including the new arguments-table row.
- [ ] Acceptance: G3, C6
- [ ] Commit: `write-article: --light mode (skip adversarial/sidecar/retro markdown) for fast single-FAQ runs — pipeline parity with content-expand`

### Task 7: Pin model: sonnet on anti-slop-reviewer dispatch (both skills)

**Files:**
- `skills/write-article/SKILL.md` (Phase 4.1)
- `skills/content-expand/SKILL.md` (Phase 2.5)

**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: docs-only edit.
- [ ] GREEN:
  In `write-article` Phase 4.1, the dispatch block already says `model: sonnet` — verify and ADD an explicit "Do NOT inherit parent context model — force sonnet to avoid 1M-context billing on a read-only review" comment line. (The block exists, but per v1.3.98 release notes this skill was NOT in the batch of 8 that received explicit pinning; align it with the post-1.3.98 pattern.)
  In `content-expand` Phase 2.5, the dispatch is implicit (just "Dispatch anti-slop-reviewer agent"). Replace with the same structured block used in write-article 4.1 with explicit `model: sonnet` + "Do NOT inherit parent context model" comment.
- [ ] Verify:
  ```bash
  grep -nE "model: sonnet|Do NOT inherit parent context model" /Users/greglas/DEV/zuvo-plugin/skills/write-article/SKILL.md /Users/greglas/DEV/zuvo-plugin/skills/content-expand/SKILL.md
  ```
  Expected: at least `4` hits across the two files.
- [ ] Acceptance: G2, C2
- [ ] Commit: `write-article + content-expand: explicit model: sonnet on anti-slop-reviewer dispatch — matches v1.3.98 pattern`

### Task 8: Meta description post-serialize length check

**Files:**
- `skills/write-article/SKILL.md` (Phase 5.2 Frontmatter)

**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: docs-only edit.
- [ ] GREEN:
  After the existing Phase 5.2 frontmatter rules, add a post-serialize validation step:
  ```
  After the frontmatter YAML is assembled, count the actual serialized length of `description`:
  - If < 140 or > 160 chars: regenerate the description once with the corrected target band, log `meta-length: regenerated <old>→<new>`.
  - If still outside band on second attempt: emit `WARNING: meta description length <N> outside 140-160 band` and proceed (do not block).
  ```
  Cross-link from PQ7 in `prose-quality-registry.md` if PQ7 references the pre-serialize variant.
- [ ] Verify:
  ```bash
  grep -nE "meta-length: regenerated|140-160|140 or > 160|post-serialize" /Users/greglas/DEV/zuvo-plugin/skills/write-article/SKILL.md
  ```
  Expected: at least `2` hits.
- [ ] Acceptance: G1, C8
- [ ] Commit: `write-article: post-serialize meta description length check (140-160 band) with one regenerate retry`

### Task 9: Telemetry NOTES carries writer/reviewer model identity

**Files:**
- `skills/write-article/SKILL.md` (ARTICLE COMPLETE block + Run: line)
- `skills/content-expand/SKILL.md` (CONTENT-EXPAND COMPLETE block)
- `shared/includes/run-logger.md` (document the new NOTES suffix convention if not already present)

**Complexity:** complex
**Dependencies:** Task 7 (pin must land first; otherwise we'd log `unknown` for reviewer)
**Execution routing:** deep implementation tier

- [ ] RED: docs-only edit. Acceptance: the next 5 real runs after deploy MUST show non-empty `wm:` and `rm:` markers in `~/.zuvo/runs.log` (literal value `unknown` IS allowed for `wm:` when the harness does not expose its model identifier — that is itself a useful telemetry signal). `rm:` MUST be a concrete value (`sonnet`, `opus-4.7`, or `skipped` for `--light`); `rm:unknown` is a regression.
- [ ] GREEN:
  Update both COMPLETE blocks so the NOTES field appends `|wm:<writer-model>|rm:<reviewer-model>` after the existing topic summary. Examples in the SKILL.md should show:
  ```
  NOTES: [STANDARD] Bosnia FAQ paid surveys|wm:opus-4.7-1m|rm:sonnet
  ```
  In `run-logger.md`, document `wm:` and `rm:` as reserved suffixes within NOTES, separated by `|`. NOTES char budget remains 80 for the prose part; suffixes are appended without counting against that budget.
  Resolution rules:
  - `wm:` = the active orchestrator model (read from harness env if exposed: `CLAUDE_MODEL`, `CODEX_MODEL`, `GEMINI_MODEL`, or fall back to literal `unknown`). `unknown` is acceptable AS LONG AS the marker itself is present and non-empty — it documents the harness gap.
  - `rm:` = the model pinned in Task 7. MUST be one of: `sonnet`, `opus-4.7`, `skipped` (when `--light` bypasses adversarial). Literal `rm:unknown` is a regression and counts as a deploy-verification failure (see RED).
- [ ] Verify:
  ```bash
  grep -nE "wm:|rm:|writer-model|reviewer-model" /Users/greglas/DEV/zuvo-plugin/skills/write-article/SKILL.md /Users/greglas/DEV/zuvo-plugin/skills/content-expand/SKILL.md /Users/greglas/DEV/zuvo-plugin/shared/includes/run-logger.md
  ```
  Expected: at least `6` hits across 3 files.
  Post-deploy smoke (manual, after `./scripts/dev-push.sh`):
  ```bash
  tail -10 ~/.zuvo/runs.log | grep -E "(write-article|content-expand)" | grep -oE "wm:[^|]+|rm:[^|]+" | sort -u
  ```
  Expected: shows actual model identifiers, not blank.
- [ ] Acceptance: G5, C2, C9
- [ ] Commit: `write-article + content-expand: telemetry NOTES carries wm:/rm: suffixes for retro analytics — closes routing: unknown gap`

---

## Post-merge verification (not a task, but mandatory before marking plan COMPLETE)

After all 9 tasks merged + `./scripts/dev-push.sh "fixes from 2026-04-30 plan"`:

1. Run write-article on a real `tgm-payload` FAQ pattern (e.g., a missing locale like `et-EE`) in COMPACT mode WITHOUT `--light`. Inspect SETUP block for `bv-mode:`, `signal:`, locale resolution. Expected: `signal: content/articles` if `et-EE/` exists, else `signal: data/parsed`.
2. Run write-article on the same pattern WITH `--light`. Verify: no `<basename>.json` sidecar created, no new `<!-- RETRO -->` block in `~/.zuvo/retros.md`, but a TSV row IS appended to `~/.zuvo/runs.log` with `wm:<model>|rm:skipped` suffix.
3. Run content-expand on an existing article that already has a `.json` sibling. Verify the report sidecar `<basename>.content-expand.json` is written next to the source, NOT to `output/articles/`.
4. **Authoritative pass/fail gate** (single primary check): 7 days after deploy, run the friction-rate query from Quality Strategy on `~/.zuvo/runs.log`. Pass when:
   - N >= 20 invocations across both skills
   - write-article actionable friction rate <= 25% (down from 48%)
   - content-expand actionable friction rate <= 15% (down from 29%)
   - Both numbers reported as `before:after:delta` (e.g., `write-article 48%:22%:-26pp`)
   If gate fails: open a follow-up retro and a v1.4.x revision plan. Do NOT silently extend the window or cherry-pick subsamples.

## Out of scope (deferred)

- Cache-on-disk frontmatter detection (mentioned in user brief, but Phase 0 currently re-detects per run — caching needs a separate spec because cache key + invalidation is non-trivial; raise as a separate brainstorm).
- Splitting --light into `--no-adversarial` / `--no-sidecar` / `--no-retro` granular flags. Defer until --light usage data shows people want partial skipping.
- Migrating banned-vocabulary entirely to monolithic and dropping the split layout. Bigger change; needs deprecation plan for downstream consumers.
