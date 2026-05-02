---
name: backlog
description: Known improvements and ideas deferred from active work
type: project
---

## benchmark skill

### Round 4: adversarial review on tests

**What:** After Round 3 (providers write tests), add adversarial cross-review on the test files — each provider critiques other providers' tests. Author can fix. Meta-judge re-scores after adversarial. Adds `test_adversarial_delta` field to scorecards.

**Why:** User requested (2026-04-07). Mirrors Round 1 adversarial on code. Answers: does adversarial review improve test quality as much as it improves code quality? Are tests easier or harder to improve via cross-review?

**Scope:** New `--with-test-adversarial` flag (separate from `--with-adversarial` which applies to code only), or extend `--with-adversarial` to cover both rounds. Add `test_adversarial_delta` to benchmark-output-schema.md, leaderboard, and scorecards. New Round 4 phase in SKILL.md corpus mode extension.

### Token counting — actual vs estimated

**What:** Most providers return estimated token counts (`wc -w × 1.3`, flagged `~estimated`). Only Gemini API returns actual token counts via `usageMetadata`. If/when other CLIs expose token usage, wire it in.

**Why:** Cost calculations are approximate for CLI-based providers (Codex, Gemini CLI, Cursor, Claude CLI).

## 2026-04-17 zuvo:leads Task 1 (schema include)

- [ ] B-leads-T1-test-scope: `scripts/tests/leads-schema-structure.sh` greps are unscoped (not anchored to Data Model table range). If an enum value is removed from a field definition but still appears in prose elsewhere, the test passes false-green. Fix: use awk range `/^## Contact Record Fields/,/^## /` to extract the table, then grep within it. Source: adversarial task-1 round 2 WARNING.
- [ ] B-leads-T1-jsonl-ext: `.checkpoint-<slug>.json` stores JSONL but uses `.json` extension. Tooling that `JSON.parse`s the whole file will fail. Fix: rename convention to `.checkpoint-<slug>.jsonl` in `lead-output-schema.md` before v1 ships. Source: adversarial task-1 round 2 WARNING.
- [ ] B-leads-T1-casefold-perf: Casefold normalization via `python3 -c` subprocess spawn is correct but slow at scale (~10-50ms per record × 500 records = 5-25s). Fix: batch normalization in a single Python invocation (read records on stdin, emit keyed output). Source: adversarial task-1 round 2 WARNING.

## 2026-04-17 zuvo:leads Task 2 (source registry)

- [ ] B-leads-T2-urlencode: Query templates (`Nominatim city={geo}`, `WebSearch "{company_name}"`, crt.sh `q={domain}`) lack explicit URL-encoding rules. Geographies or names with spaces / `&` / `#` will fail. Fix: add a "URL-Encoding Convention" section; require percent-encoding before interpolation. Source: adversarial task-2 round 2 WARNING.
- [ ] B-leads-T2-macos-timeout: Registry examples use GNU `timeout` which is absent on macOS by default. Users must `brew install coreutils` or skill uses `gtimeout`. Fix: document alternative (bash `&`/`wait` pattern or `gtimeout` fallback detection). Source: adversarial task-2 WARNING.
- [ ] B-leads-T2-dig-missing-vs-no-mx: When `dig` is absent, skill labels emails `not-found`, conflating infra failure with domain truth. Fix: distinguish `email_confidence: unverified-tool-missing` from `not-found`. Source: adversarial task-2 WARNING.
- [ ] B-leads-T2-smtp-code-wrapper: `smtp_probe` returns boolean; callers needing 4xx/5xx distinction need a wrapper. Registry mentions this but doesn't show the wrapper. Fix: add `smtp_probe_code()` example returning the raw 3-digit code. Source: adversarial task-2 WARNING.
- [ ] B-leads-T2-registry-test-precision: `grep -Eq` alternations in structure test allow any single token to pass (e.g., ZUVO_GITHUB_TOKEN alone satisfies the GitHub rate-limit check even if 60/h and 5000/h were removed). Fix: split into 3 separate asserts. Source: adversarial task-2 WARNING.

## 2026-04-17 zuvo:leads Task 3 (company-finder agent)

- [ ] B-leads-T3-test-yaml-scope: `scripts/tests/leads-agent-company-finder-structure.sh` uses unscoped `grep -Fq` on frontmatter fields; malformed YAML (wrong keys, missing tokens, tokens in prose) could pass. Fix: parse YAML explicitly or scope greps between `---` delimiters. Pattern applies to ALL agent structure tests (T4, T5). Source: adversarial task-3 round 3 CRITICAL.

## 2026-04-17 zuvo:leads Task 4 (contact-extractor agent)

- [ ] B-leads-T4-tmp-ulid: Adversarial round 3 suggested ULID instead of PID+epoch for /tmp scratch path uniqueness. PID+epoch is sufficient (collision requires same PID + same second which is impossible for the same process). Consider ULID if clock-skew edge cases surface.
- [ ] B-leads-T4-test-yaml-scope: Inherited from T1/T3 — structure test uses unscoped greps. Address in a single follow-up PR that hardens all agent structure tests together.
- [ ] B-leads-T4-domain-canonicalization: Plan requires NFC-normalized domain but extractor doesn't explicitly document NFC step before interpolation. Add `domain=$(python3 -c 'import sys,unicodedata; print(unicodedata.normalize("NFC", sys.argv[1]))' "$domain")` normalization step before the RFC-1035 validation.

## 2026-04-17 zuvo:leads Task 5 (lead-validator agent)

- [ ] B-leads-T5-warn-8: 8 WARNING-level adversarial findings on round 1 (test precision, edge cases in GDPR fallback, EU/EEA list not including UK, name-confidence heuristic subjectivity). Address in cleanup pass before v1 ship.

## 2026-04-17 zuvo:leads Task 6 (SKILL.md orchestrator)

- [ ] B-leads-T6-warn-7: 7 WARNING-level adversarial findings (pseudocode shell quoting, ``to_epoch`` undefined helper, greying-timing of checkpoint flushes, Unicode casefold subprocess spawning in Phase 5 loop not batched, etc.). Address in cleanup PR before v1 ship.

# Review 2026-05-02 fc73d7b..a8cc812 — Pending findings

- [x] B-rev-2026-05-02-R3 [RECOMMENDED] rules/cq-checklist.md — two scoring formulas (N/A counts as 1 vs subtract N/A from 29). Adopt single explicit formula. confidence:70 — FIXED 2026-05-02 in zuvo-plugin working tree
- [x] B-rev-2026-05-02-R4 [RECOMMENDED] rules/cq-checklist.md CQ4 — client-side token validation may be misread as server-side substitute. Split into UX-only and security-MUST sections. confidence:55 — FIXED 2026-05-02 in zuvo-plugin working tree
- [x] B-rev-2026-05-02-R5 [RECOMMENDED] shared/includes/codesift-setup.md Step 2.5 — forbids second ToolSearch with no escape for mid-run discovery. Relax to ≤2 per session. confidence:60 — FIXED 2026-05-02 in zuvo-plugin working tree
- [x] B-rev-2026-05-02-R6 [below-threshold] codesift-setup hardcodes ToolSearch name; other MCP hosts differ. confidence:50 — FIXED 2026-05-02 in zuvo-plugin working tree
- [x] B-rev-2026-05-02-R7 [below-threshold] skills/review/SKILL.md Phase 3 no-approval-pauses lacks destructive-persistence preconditions. confidence:45 — FIXED 2026-05-02 in zuvo-plugin working tree
- [x] B-rev-2026-05-02-R8 [below-threshold] rules/cq-checklist.md CQ29 — `~/` example overloaded with home-dir meaning. Drop or narrow to tsconfig-configured aliases. confidence:50 — FIXED 2026-05-02 in zuvo-plugin working tree


# Adversarial pass-2 findings on docs/competitive-analysis.md (working tree content — author's market research, not fix-related)

- [ ] B-rev-2026-05-02-N1 [WARNING] competitive-analysis.md — Antigravity build target says `~/.gemini/AGENTS.md` but Gemini CLI natively reads `GEMINI.md`. Writes will silently fail. Source: gemini adversarial pass-2.
- [ ] B-rev-2026-05-02-N2 [WARNING] competitive-analysis.md — Deprecation plan for 21 skills based on `~/.zuvo/runs.log` is local-only data (single developer), not user telemetry. Risk: cutting features actual users rely on. Source: gemini adversarial pass-2.
- [ ] B-rev-2026-05-02-N3 [WARNING] competitive-analysis.md — agentskill.sh subset math impossible: 124K (Dev/Eng) + 39K (PM) = 163K but total platform = 107-110K. Hallucinated numbers. Source: gemini adversarial pass-2.
- [ ] B-rev-2026-05-02-N4 [WARNING] competitive-analysis.md — Task 28 proposes `zuvo:context-budget` as a skill but the feature requires intercepting other tools' outputs in-flight, which only hooks can do. Reclassify to hooks/. Source: gemini adversarial pass-2.
- [ ] B-rev-2026-05-02-N5 [INFO] competitive-analysis.md — Task 10e date "✅ DONE (2026-04-08)" but scope updated from 48→51 skills; the 3 new skills did not exist on April 8th. Either revert text to 48 or open new task for the 3. Source: gemini adversarial pass-2.
- [ ] B-rev-2026-05-02-N6 [INFO] competitive-analysis.md — Says superpowers grew "42K→150K (3.5x in 3 months)" but Apr-8 doc recorded them at 42K, so the 108K explosion happened in 3 weeks not 3 months. Highlight the velocity. Source: gemini adversarial pass-2.
