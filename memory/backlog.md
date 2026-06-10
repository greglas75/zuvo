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

# Adversarial pass-2 findings on docs/competitive-analysis.md (working tree content — author's market research, not fix-related)

- [ ] B-rev-2026-05-02-N1 [WARNING] competitive-analysis.md — Antigravity build target says `~/.gemini/AGENTS.md` but Gemini CLI natively reads `GEMINI.md`. Writes will silently fail. Source: gemini adversarial pass-2.
- [ ] B-rev-2026-05-02-N2 [WARNING] competitive-analysis.md — Deprecation plan for 21 skills based on `~/.zuvo/runs.log` is local-only data (single developer), not user telemetry. Risk: cutting features actual users rely on. Source: gemini adversarial pass-2.
- [ ] B-rev-2026-05-02-N3 [WARNING] competitive-analysis.md — agentskill.sh subset math impossible: 124K (Dev/Eng) + 39K (PM) = 163K but total platform = 107-110K. Hallucinated numbers. Source: gemini adversarial pass-2.
- [ ] B-rev-2026-05-02-N4 [WARNING] competitive-analysis.md — Task 28 proposes `zuvo:context-budget` as a skill but the feature requires intercepting other tools' outputs in-flight, which only hooks can do. Reclassify to hooks/. Source: gemini adversarial pass-2.
- [ ] B-rev-2026-05-02-N5 [INFO] competitive-analysis.md — Task 10e date "✅ DONE (2026-04-08)" but scope updated from 48→51 skills; the 3 new skills did not exist on April 8th. Either revert text to 48 or open new task for the 3. Source: gemini adversarial pass-2.
- [ ] B-rev-2026-05-02-N6 [INFO] competitive-analysis.md — Says superpowers grew "42K→150K (3.5x in 3 months)" but Apr-8 doc recorded them at 42K, so the 108K explosion happened in 3 weeks not 3 months. Highlight the velocity. Source: gemini adversarial pass-2.

- B-1 [security] scripts/zuvo-home/append-runlog | rule:adversarial-T1-preexisting | sig:verify-audit-fail-open
  The audit-content gate uses `if [ -x "$ZUVO_BIN/verify-audit" ]` which FAILS OPEN: audit/review/pentest runs silently skip finding-content verification when verify-audit is absent or non-executable. Pre-existing (identical `[ -x $HOME/.zuvo/verify-audit ]` semantics before the ZUVO_HOME change; NOT introduced by 2026-05-18 retro-checkpoint Task 1). Fixing requires a policy decision: make verify-audit MANDATORY for audit-class skills (regresses optional/partial installs that install.sh intentionally warns-and-skips) vs keep optional. Out of Task-1 scope. confidence:70 source:adversarial-task-1 iter2 (codex+cursor, high-conf)

- B-2 [docs] shared/includes/retrospective.md | rule:adversarial-T2-residual | sig:retro-doc-WARN-INFO
  Task 2 adversarial final run: 8 WARNING + 3 INFO residual (test-robustness nits, prose-precision, speculative parser-strictness). Substantive contracts green. Dedup-key CRITICAL oscillated date<->sha<->session-id across 5 iters; root-resolved (write-time coherence via session-state Task 6; post-hoc dedup keys in-line SKILL+PROJECT+SHA7). DISPOSITION: accepted per user (BLOCKED_ADVERSARIAL_LOOP, 2026-05-18) — Release-Gate model, not infinite loop. Revisit only if a real downstream parser breaks. confidence:35 source:adversarial-task-2

- B-3 [reliability] shared/includes/retrospective.md + scripts/zuvo-home/{retro-stub,append-runlog} | rule:adversarial-T3-rotation-clobber | sig:retros-log-no-cross-writer-lock
  retros.log rotation (head+tail>tmp; mv) can clobber a concurrent external append because retro-stub's mkdir-lock is NOT shared by the other writers (retrospective.md bash append, append-runlog). PRE-EXISTING: retro-stub mirrors retrospective.md's canonical rotation pattern; it does not worsen it. Proper fix = a unified retros.log write-lock convention across ALL three writers — cross-cutting, out of Task 3 scope (scope-creep guard). confidence:55 source:adversarial-task-3 iter2

- B-4 [reliability] scripts/zuvo-home/retro-stub | rule:adversarial-T3-residual | sig:retro-stub-WARN
  Task 3 adversarial iter3: 0 CRITICAL, 5 WARNING + 2 INFO residual (lock-steal theoretical TOCTOU on mtime path — mitigated by pid-liveness + ms critical section + atomic mkdir, documented invariant; minor portability/edge nits). Substantive contracts green 17/17. Accept per Step-7b non-critical-with-backlog. confidence:30 source:adversarial-task-3

- B-5 [reliability] scripts/zuvo-home/append-runlog | rule:adversarial-T4-residual | sig:t4-WARN-INFO
  Task 4 adversarial: 4 distinct CONVERGING CRITICAL fixes (lock OR-liveness, pid-write-fail, rmdir busy-spin, TSV column-drift) -> iter5 0 CRITICAL. Residual 3W/3I = theoretical (PID reuse window; lexicographic ISO compare assumes canonical Z-format [enforced by all writers]; schema-version drift assertion). Lock+match now correct-by-construction. Accept per Step-7b non-critical+backlog; cap exceeded JUSTIFIED (distinct converging fixes, not oscillation — contrast B-2 Task 2). confidence:30 source:adversarial-task-4

- B-6 [reliability] scripts/zuvo-home/retro-stub | rule:adversarial-T5 | sig:t5-residual-and-refuted-FP
  Task 5 --sweep adversarial: iter1 CRITICAL (marker deleted on lock-busy -> orphan telemetry lost) FIXED + T5.e regression guard. iter2 CRITICAL (rc=$? in if/else else-branch == 0 not 3) EMPIRICALLY REFUTED: direct test `if f(return 3); else rc=$?` -> rc=3, and T5.e (asserts rc!=0 on lock-busy) passes — reviewer misread bash if/else $? semantics; no code defect. Residual 4W/2I theoretical. confidence:25 source:adversarial-task-5

- B-7 [docs] shared/includes/session-state.md + tests/adversarial/test-session-retro-carry.sh | rule:adversarial-T6-residual | sig:t6-WARN
  Task 6 adversarial: iter1 CRITICAL (test discarded retro-stub status) FIXED; iter2 2 CRITICAL (retro-session-id == resuming-session always-fails; cross-run dedup data-loss) FIXED -> aligned to Task 2 canonical run-identity model; iter3 0 CRITICAL. Residual 3W/2I: absolute-vs-delta line budget, handcrafted-log parity, permissive substring scoping, temp cleanup on early-fail. 'Fields in HTML comments' = EXISTING execution-state.md convention (session-id/status same), by-design not a defect. Accept per Step-7b. confidence:25 source:adversarial-task-6

- B-8 [reliability] scripts/zuvo-home/retro-stub + skills/{brainstorm,plan,execute}/SKILL.md | rule:adversarial-T7-residual | sig:t7-bounded
  Task 7 adversarial: iter1 2C (session-id $$ / marker-before-sweep) + iter2 2C (filename collision / sweep-active-run) FIXED (unique marker filename, sweep-first, grace window, full-retro precheck); confirmatory 1C = doc over-promise FIXED (best-effort prose) + friction tr|sed -> explicit case + GRACE numeric guard. Residual WARN/INFO: NF==17 column dependency (consistent w/ B-5 Task4 disposition — canonical format enforced by all writers), $_RPR basename not sanitized (git-toplevel-controlled, low risk), start_ts non-canonical-format fallback (all zuvo writers emit canonical Z). Bounded/by-design. confidence:25 source:adversarial-task-7

- B-9 [distribution] scripts/install.sh | rule:install-platform-dispatch-gap | sig:zuvo-home-not-in-platform-only
  PRE-EXISTING (not introduced by retro-checkpoint): install_zuvo_home (installs append-runlog/verify-audit/compute-preload/retro-stub into shared ~/.zuvo) is only invoked in the `both|all` dispatch — `./scripts/install.sh claude|codex|cursor` alone does NOT install any ~/.zuvo helper. Canonical docs use `./scripts/install.sh` (=all) + dev-push.sh so it works in practice; platform-only subcommands are a latent gap affecting ALL zuvo-home helpers equally. Fix = call install_zuvo_home from each platform branch too (separate decision, affects append-runlog distribution). confidence:55 source:adversarial-task-8-verification

- B-10 [config] scripts/install.sh + tests/adversarial/test-install-retro-stub.sh | rule:adversarial-T8-residual | sig:t8-WARN
  Task 8 adversarial: 0 CRITICAL, residual 7W/7I (gemini+cursor) — test-design/style nits (grep scoping, dry-run only exercises the clause not full function, cp-overwrite semantics consistent w/ other zuvo-home helpers). Install clause mirrors the proven append-runlog pattern exactly. Pre-existing platform-only-dispatch gap tracked B-9. Accept per Step-7b non-critical+backlog. confidence:20 source:adversarial-task-8

- B-11 [docs] skills/context-audit/SKILL.md | rule:adversarial-T9-residual | sig:t9-WARN
  Task 9 adversarial: 0 CRITICAL, 4W/2I (cursor) — test-design/style nits (fenced-block grep scoping, fixture parity, tail-5 recency window). Block is a clean ZUVO_HOME-aware SKIP: parser with no-skip-log degrade + clean grep -c capture. Accept per Step-7b non-critical+backlog. confidence:20 source:adversarial-task-9

- [B-seccorpus-1] tests/security-corpus/run.sh — provenance is string-based (path-boundary match + --require-provenance). A deliberately fabricated .meta.source_fixture string still passes. v2: optional content-hash binding (hash fixture dir, compare to a recorded digest). Real threat (stale/copied/omitted findings) already covered. Source: execute Task 1 adversarial rounds 3-5 (relooped). conf: 40
