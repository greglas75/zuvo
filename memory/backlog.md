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
- [x] - [B-seccorpus-2] tests/security-corpus/registry.test.sh — test robustness: column-scope the CWE assert, detect duplicate finding_type rows, replace substring seed-grep with anchored match, single-source the safe-pattern list from registry rows. Source: execute Task 2 adversarial (6 WARNING, 0 CRITICAL). conf: 35
- [B-seccorpus-3] pentest-source-sink-registry.md — new-class sink/source regex seeds are advisory discovery starting points (registry header: 'start with these before semantic escalation'). 5 adversarial rounds tightened the major over-broad tokens (graphql mitigations, dom-xss dangerouslySetInnerHTML, env./ctx./context. non-taint, jsonwebtoken import, yaml SafeLoader lookahead, JSON.parse.reviver, __reduce__). Residual regex-precision nitpicks on advisory seeds → defer; the safe-pattern layer (Task 4) is the real false-positive control. conf: 30
- [B-seccorpus-4] pentest-safe-pattern-registry.md — new-class safe-pattern match_signals: adversarial pushes for ever-stricter sufficiency proofs per signal. Per Registry Rule 2 safe-patterns are trace-governed DOWNGRADES not auto-excludes (the trace must still show the defense covers the active path), so residual sufficiency-pedantry is bounded. Primary defense per class is now required (filter-escape for LDAP, entity-disable for XXE, depth/complexity for GQL, same-sink guard for deser). conf: 30
- [x] - [B-seccorpus-5] tests/security-corpus/*/clean twins — adversarial WARNINGs for robustness beyond each target class (graphql NODE_ENV gating + complexity, xxe parse-budget, redos type-guard, ldap empty-string). Twins correctly defend their OWN class (corpus contract); broader hardening deferred. conf: 25
- [B-secaudit-1] security-audit S1/S2/S3 registry-seeded trace: 6 adversarial rounds hardened (reachability-not-taint honesty, degraded-mode HIGH for local flows, registry-MISSING fallback, stage-1b degradable, step-6 dimension-only degraded). Round-6 CRITICAL (codesift-setup.md not loaded) was a diff-scope FP — it's loaded at line 84. conf: 25
- [x] - [B-secaudit-2] pentest SCA preflight (0.5b): snippet is advisory; 4 adversarial rounds fixed real bugs (lockfile-specific tool, exit-non-zero-means-vulns-not-failure, pip-audit env-vs-lockfile, requirements unpinned). Residual: per-lockfile loop in polyglot trees left to agent. conf: 25
- [B-secaudit-3] security-audit S14 IaC scanner block: advisory snippet; hardened (output-keyed scan helper not exit-code, JSON validation, recursive .tf detection, IC-4/IC-5 degraded labeling). Residual adversarial nitpicks (repo-root scan scope/exclusions, multiple-lockfile loop, stderr handling) are doc-snippet refinements the agent adapts. conf: 25
- [B-seccorpus-6] Kotlin/Ktor sink seed: adversarial repeatedly flags regex 'unbalanced' — empirically false (compiles, balanced depth 0, matches fixture); a markdown double-escape (\( / \|) artifact. Profile prose lists more sinks than the seed regex by design (seeds are discovery starting points per registry header). conf: 20
- [x] - [B-seccorpus-7] GraphQL/serverless detection heuristics: adversarial WARNINGs — 'type Query' matches TS aliases, handler.ts matches *-handler.ts, resolver-args misses destructured {args}. Detection signals are heuristic + agent-confirmed (overlay needs corroborating signals like ApolloServer/serverless.yml). conf: 25
- [B-secaudit-4] IC-3 cross-skill reconciliation: 6 adversarial rounds specified a subtle merge algo (evidence-merge both records, fail-closed source component, disposition-conflict→needs_review not auto-severe, two-axis status-vs-severity separation, SKILL.md cross-ref, provisional-severity-in-needs-verification). Logic now well-specified; further rounds are presentation nuance. conf: 20
- [B-secaudit-5] security-audit coverage-gate parity (IC-2/IC-5): 4 adversarial rounds specified it (immutable+additive Phase-0 entry-point snapshot, no denominator-gaming, gate_status folds surface_gate, N=0→N/A non-failing, breadth-not-depth, client-surface still audited). Residual unbounded refinements (perfect discovery impossible) clarified as best-effort. conf: 20
- [B-secaudit-6] v2-class warning-only grace: adversarial flags the grace itself (HIGH v2 findings excluded from gate). This is the PLAN-MANDATED trade-off (plan WARNING #5: CI-safety) — [POST-CAP: DEFERRED] accepted per plan Review Trail. Mitigations: findings still reported+backlogged, --strict-v2 enforces now, time-boxed to 1.4.x→1.5.0. Residual --quick/score-cap wording aligned. conf: 20
- [x] - [B-review-1] validate-pentest-output.sh — PENTEST_REGISTRY/PENTEST_MANIFEST env-overridable (test affordance) is also a prod-path override; low risk (local CI script, attacker would need env control) but consider a test-only guard. Source: zuvo:review self-review F4. conf: 35

## B-infra-collect-nohup-quote-transport
- **Source:** zuvo:execute Task 4 adversarial round 2 (deferred to Task 5 live-wiring)
- **File:** scripts/infra-collect.sh — run_remote() long-mode nohup wrapper
- **Issue:** `sh -c '...'` string-embeds the inner battery command; a single quote (awk/sed are full of them) would terminate the wrapper. NOT exploitable at skeleton stage (live long-path stubbed; dry-run only prints).
- **Fix owner:** Task 5 MUST replace string-embedding with quote-safe transport (base64-decode inner cmd on target, or remote temp script) BEFORE activating live execution.
- **Confidence:** 60 (real latent, gated by §2 static rule, no current exploit path)

## B-infra-collect-value-heuristic-redaction
- **Source:** zuvo:execute Task 5 adversarial security round 4 (deferred — IC-5 design trade-off)
- **File:** scripts/infra-collect.sh SED_REDACT
- **Issue:** Keyword-based redaction (IC-5 spec design) only fires when the KEY NAME contains a sensitive substring; a generically-named secret (`FOO=abc123`) in an arbitrary config would leak verbatim.
- **Mitigation already in place:** IS12 (the .env reader) emits key NAMES only, never values — the dominant leak path is structurally closed. Other battery checks read only known-schema config files (sshd_config/sysctl/ufw have no secret fields; redis requirepass+masterauth explicitly covered).
- **v2 fix:** add a value-heuristic redaction pass (high-entropy / token-shaped values) on top of keyword redaction; tune false-positive rate against real config corpus.
- **Confidence:** 50 (real residual, structurally mitigated where it matters; spec-sanctioned keyword model)


## B-infra-collect-multi-container-cve
- **Source:** zuvo:execute Task 9 adversarial (deferred — v1 scope boundary, not a bug)
- **File:** scripts/infra-collect.sh IS9-image-critical-cve
- **Issue:** The IS9 docker CVE check audits a single container image, not all running containers — partial coverage (correct for what it scans, incomplete fleet-wide).
- **v2 fix:** enumerate `docker ps -q` and run trivy per image; aggregate per-container findings.
- **Confidence:** 55 (coverage limitation, results correct for the scanned image)

## B-install-sh-copy-verification
- **Source:** zuvo:execute Task 10 adversarial (pre-existing convention, repo-wide)
- **File:** scripts/install.sh Codex/Cursor Step 7 script-copy blocks
- **Issue:** ALL named-script cp lines (benchmark.sh, adversarial-review.sh, reviewer-model-route.sh, blind-audit-codex.sh, infra-collect.sh) use `cp ... 2>/dev/null || true`, so a missing/failed copy still prints "Scripts installed". Task 10 conformed to this convention for infra-collect.sh; the gap is pre-existing and repo-wide.
- **v2 fix:** add a post-copy verification loop asserting each expected script exists at its dest; warn/exit on any missing. Repo-wide (not infra-audit-specific).
- **Confidence:** 50 (pre-existing convention; `|| true` is intentional install robustness, but silent-fail masks real breakage)

## B-noverify-hardening (RECOMMENDED, deferred — best-effort layer)
- **Date:** 2026-06-28
- **Source:** zuvo:review aggregate (Phase Final-2) of pipeline-entry enforcement; adversarial=gemini.
- **Scope:** `hooks/block-no-verify.sh`, `scripts/git-noverify-shim.sh`, `hooks/pre-commit-adversarial-gate.sh`.
- **Residual bypasses of the `--no-verify` best-effort layer** (CI is the unbypassable backstop; see docs/pipeline.md "Known bypasses"):
  1. git aliases — resolve `git config --get alias.<sub>` before validating the subcommand (recursion-guarded).
  2. quoted flag in command-string hook — `git commit "--no-verify"` evades the string parser (the PATH-shim already catches it via real argv); a quote-aware tokenizer would close it.
  3. commit-gate mtime TOCTOU — switch the freshness check from working-tree mtime to staged blob-hash comparison (`git ls-files -s`) recorded at review time.
- **Why deferred:** structural hardening of a layer the architecture defines as best-effort; not a guarantee gap. Real complexity (subprocess alias resolution, blob-hash tracking) for marginal local gain. Route via `zuvo:refactor`/`zuvo:build` when prioritized.

## B-driftguard-bounded-age (RECOMMENDED, deferred — pre-existing best-effort)
- **Date:** 2026-06-28  **Source:** fresh aggregate review (gemini R3-6).
- **File:** `hooks/pre-commit-adversarial-gate.sh` adversarial_gate state-drift guard.
- **Issue:** when execution-state.md is missing, the guard checks `ls adversarial-task-*.txt` (any artifact) — an ancient unrelated artifact neuters the fail-safe indefinitely.
- **Fix:** bound the artifact match to the `$GATE_GRACE` window via `find -mtime`, or match the artifact to the current `$active_exec_marker`. Pre-existing legacy logic; best-effort.

- [ ] B-refactor-gate-nul | hooks/lib/refactor-gate-lib.sh | newline/control-char in a staged filename can split the newline-IFS file list and miss a scope_fence match (gate bypass). OUT-OF-THREAT-MODEL for now: the gate is process-discipline for cooperating agents, not a security boundary vs. crafted filenames (ZUVO_ALLOW_ADHOC=1 / human-bypass / fail-open already exist). Recipe: switch entry enumeration to `git ... --name-only -z --no-renames` (NUL) and do membership via `printf '%s' "$staged_nul" | grep -zqxF -- "$fence_entry"` per scope_fence entry (POSIX `read -d ''` is non-portable). Source: zuvo:review self-review of v1.4.0 (adversarial codex-5.3). Severity: CRITICAL-on-correctness / LOW-in-threat-model.

- [ ] B-plan-gate-fileformat | hooks/lib/refactor-gate-lib.sh | plan_execute_gate_check parses **Files:** only at column 0, one-line comma-separated, and space-splits plan-file tokens — indented/bulleted/multiline Files lists or filenames with spaces are missed (fail-open). LOW: the plan author controls the plan doc format (template is column-0 **Files:**). Recipe: parse Files across the task block (not just `^**Files:**`), and match plan tokens against staged via exact line compare (NUL-safe). Source: zuvo:execute Task 2 adversarial (codex/gemini). Severity: WARNING.
- [ ] B-plan-gate-format-variance | hooks/lib/refactor-gate-lib.sh | plan_execute_gate_check matches git-canonical repo-relative paths from the inline `**Files:** a, b` template format; a plan written with basenames, `./`-prefixes, or a markdown bullet-list **Files:** fails OPEN (not gated). SAFE direction (fail-open by design); the gate handles the zuvo:plan template. Recipe: normalise paths (strip ./, basename-fallback) + parse bullet-list Files blocks. Source: zuvo:execute Task 2 adversarial passes 3-4. Severity: WARNING (plan-accepted fail-open).
- [ ] B-adversarial-single-cli-host | scripts/adversarial-review.sh | gemini/cursor-agent hosts still auto-exclude the whole vendor (they review with the same model as the host IDE, no opposite-model runner like claude/codex). On a single-CLI gemini-only or cursor-only machine, EXCLUDE leaves ZERO providers. Recipe: give gemini/cursor an opposite-model runner OR fall back to a cross-vendor provider before zeroing out. Source: zuvo:review behavior-auditor Point 5 (pre-existing, not this diff). Severity: RECOMMENDED.

## [obs] run-all.sh full/fast scope requires healthy Docker infra fixtures (2026-07-02)
- **Where:** `tests/infra-suite/test-suite-e2e.sh` (aggregated by `tests/run-all.sh`, added Task 4).
- **Symptom:** `docker compose up --wait failed for fixtures` (sshd-misconfigured / sshd-hardened) when the Docker daemon is up but the fixtures can't reach healthy in this env → `run-all.sh` returns FAIL=1 in BOTH fast and full scope.
- **Impact:** `dev-push.sh` Step 0 test-gate (Task 5) will block in any environment where these Docker fixtures can't build/health-check, unless `ZUVO_SKIP_TESTS=1`.
- **Not a Task 7 regression** — Task 7 (eval corpus + eval-schema + skill-suite test) touches nothing infra/docker.
- **Decision (out-of-fence for skill-testing plan):** consider gating the Docker-dependent infra e2e behind a `full`-only + docker-available guard so `fast` scope stays dependency-light. Owner/timing TBD.

## [obs] agent-count prose drift across manifests + CLAUDE.md (2026-07-03)
Manifests (.claude-plugin/.codex-plugin/package.json) say "26 specialized agents";
CLAUDE.md says "(28 agents)" / project guide implies ~48 agent files. Pre-existing
drift surfaced by Task-9 (skill-eval registration) adversarial review; deliberately
LEFT UNTOUCHED per the plan (Task 9 fence = skill count only). Needs a canonical agent
count reconciled across all 3 manifests + CLAUDE.md, ideally derived from an actual
`skills/*/agents/*.md` scan. Not blocking; tracked here.

## [obs] auto-derive advertised skill/agent counts at build (2026-07-03)
Task-9 adversarial (codex#5) noted counts are hand-maintained across 6+ files. The
validate-skills.sh count-consistency checker already fails the build on drift (the
real guardrail), but generating the advertised counts from a `skills/` directory scan
during install/build would remove the manual step entirely. Enhancement, not a defect.
- [ ] B-infra-e2e-nc-portability | tests/infra-suite (test-infra-collector-live.sh scenario d) | The black-hole preflight assertion "nc -zw5 192.0.2.1 fails fast <10s" takes 1034s on macOS — BSD `nc -w` does not enforce the connect timeout the way GNU nc does, so the fail-fast preflight hangs. Pre-existing, environment-specific (0 relation to the gate rewrite), blocks run-all Step 0 on macOS. Recipe: replace `nc -zw5` in the collector preflight with a portable connect-timeout (e.g. `nc -G5` on BSD / `timeout 5 nc`, or a bash /dev/tcp + `&`+kill guard). Source: 2026-07-09 v1.6.5 release run-all. Severity: WARNING (test portability).
- [ ] B-backlog-flock | shared/includes/backlog-protocol.md:14 + all backlog-writing skills | [structural-refactor (multi-file)] MAIN-checkout backlog is now multi-writer (every worktree + concurrent agents) with no locking — lost updates/corruption possible under concurrent runs. Recipe: (1) add a "Concurrent writes" section to backlog-protocol.md mandating `flock "$MAIN_ROOT/memory/.backlog.lock"` (Linux) / `mkdir`-spinlock (portable macOS) around read-modify-write; (2) provide a tiny `~/.zuvo/backlog-append` helper that serializes appends; (3) point the 10+ writer skills at the helper instead of inline read/write. Source: 2026-07-20 review R-21 (codex+agy independent). Severity: WARNING. Confidence: 72.
- [ ] B-review-kimi-jq-midstream | scripts/adversarial-review.sh:1053 | [below-threshold] jq aborts remaining JSONL stream on one malformed line (2>/dev/null hides it) → truncated-but-nonempty review passes guards. Theoretical: kimi-code emits valid JSONL. Recipe: per-line tolerant pass or check jq exit code. Source: 2026-07-20 review R-13. Confidence: 42.
- [ ] B-review-bare-repo-mainroot | shared/includes/backlog-protocol.md:12 | [below-threshold] "first worktree-list entry is ALWAYS main" — for a BARE base clone the first entry is the bare dir; state files would land inside it (still exactly ONE location, so dedup goal holds). Add a caveat sentence + bare-marker guard if any fleet base clone goes bare. Source: 2026-07-20 review R-5/F5. Confidence: 40.
- [ ] B-review-kimiapi-empty-model | scripts/adversarial-review.sh:1072 | [below-threshold] sanitized model can reduce to "" only via deliberate all-invalid-chars env override; guard if touched again. Source: 2026-07-20 review R-19. Confidence: 45.
- [ ] B-adversarial-curl-failwithbody | scripts/adversarial-review.sh (run_codestral:~949, run_gemini_api:~991) | [NIT] pre-existing providers still use curl -sf which discards HTTP-error bodies (kimi-api fixed 2026-07-20 by dropping -f); when convenient switch fleet-wide to --fail-with-body (curl>=7.76) or drop -f + rely on error-body guards. Source: 2026-07-20 review R-6/F6. Confidence: 58.

- B-gate-1 | hooks/pre-commit-adversarial-gate.sh:76 | stale-dialect | Greps the literal `<!-- status: in-progress -->` but real execution-state.md files are ~50/50 plain vs HTML-comment, so it misses roughly half of live runs. Use `_ap_status` from refactor-gate-lib.sh (both dialects). Found while fixing the same class in plan_execute_gate_check. | seen:1 | confidence:90 | source:build | 2026-07-22
- B-gate-2 | hooks/lib/pipeline-gate-lib.sh:325 | drift | `pg_is_agent_env` (bash, 13 vars) and `_is_agent_env` (POSIX, 15 vars) are separate hand-maintained lists. refactor-gate-lib now has a test-side drift guard; pipeline-gate-lib has none. Cannot share code (bash ${!var} vs POSIX). | seen:1 | confidence:80 | source:build | 2026-07-22
- B-gate-3 | tests/hooks/smoke-pipeline-entry.sh | pre-existing-fail | G3 "Stop nudge" fails on a clean tree, independent of the gate work (verified by stashing). Not a regression; needs its own diagnosis. | seen:1 | confidence:95 | source:build | 2026-07-22
- B-gate-4 | scripts/zuvo-phase.sh:inspect | false-confidence | `**Files:**` lines written as prose (6 repos share one such spec) are counted as declared paths, so doctor reports ARMED with a file count the gate cannot actually match. Consider an ARMED-PARTIAL verdict for non-path-shaped tokens. | seen:1 | confidence:70 | source:test-audit | 2026-07-22
- B-gate-5 | hooks/lib/refactor-gate-lib.sh:_expand_plan_files | parser-limit | Parenthetical annotations containing commas (136 real occurrences, e.g. `svc.ts (modify — line 559, ...)`) fragment the token stream. Fail-open only (never a false BLOCK). Track `()` depth like `{}`. | seen:1 | confidence:75 | source:test-audit | 2026-07-22
- B-gate-6 | hooks/lib/refactor-gate-lib.sh:_execute_run_live | threat-model | Corroboration artifacts (execution-state.md, run-markers) are unauthenticated files any agent could write. Now bounded by freshness + plan-identity + repo-scoping, but not forgery-proof. This gate is a guardrail against drift, not a security boundary (ZUVO_ALLOW_ADHOC is a sanctioned escape). A non-forgeable marker (session nonce written by zuvo:execute) would need a protocol change across 5 skills. | seen:1 | confidence:60 | source:adversarial | 2026-07-22
- B-gate-7 | hooks/lib/refactor-gate-lib.sh:_ap_field | parser-limit | An indented `  status: pending` matches neither dialect (anchored to line start) and fail-opens. Third real-world variant of the dialect class. | seen:1 | confidence:65 | source:cq-audit | 2026-07-22
- B-gate-8 | tests/hooks/*.sh | maintenance | The 15-var HUMAN fixture array is copy-pasted in 3 test files. Drift guard exists only in test-plan-execute-gate.sh. Factor into a shared fixture. | seen:1 | confidence:70 | source:test-audit | 2026-07-22
- B-gate-9 | hooks/block-no-verify.sh | false-positive | Skanuje CAŁĄ komendę, więc `-n` wewnątrz TREŚCI wiadomości commita (`git commit -F -` z heredoc zawierającym `tail -n 100`) czyta jako flagę --no-verify i blokuje legalny commit. Powtórzone 2x dzisiaj. Powinien parsować tylko argumenty git, nie treść heredoc/-F. | seen:1 | confidence:95 | source:build | 2026-07-22

- B-lock-toctou | scripts/zuvo-home/sanitize-retros:acquire_lock/release_lock | accepted-invariant | Dir-lock (mkdir) has a theoretical TOCTOU between stale-check and break, and between ownership-check and rmdir. Same limitation as append-retro/rotate-retros/backlog fleet-wide. Mitigated by pid-liveness + atomic mkdir + ms critical section. NOT fixable with flock without breaking mutual exclusion against append-retro (must share the SAME dir-lock). Documented invariant, not a live defect. | seen:1 | confidence:30 | source:adversarial | 2026-07-26

- B-polyglot-docstring | scripts/zuvo-home/{backlog-collect,runlog-collect,backlog-consolidate,profile-session,retro-mine}.py + compute-preload, digest-proposals, sanitize-retros, verify-audit | latent-trap | The polyglot `''''exec ...'''` header becomes the module's FIRST statement, so it silently becomes `__doc__` and detaches the real docstring one line below. Inert today — a repo-wide grep found no `__doc__` / `argparse(description=__doc__)` consumer — but `scripts/zuvo-home/backlog` DID get the compensating fix and these 8 did not. Recipe: apply the `USAGE = """..."""` + `sys.exit(USAGE)` pattern from scripts/zuvo-home/backlog:195, or add a one-line comment noting the trade-off, so a future `--help` does not print the exec shim. defer-reason: NIT | seen:1 | confidence:80 | source:review | 2026-07-30
- B-dispatched-count-dup | scripts/adversarial-review.sh:2057,2179 | duplication | `DISPATCHED_COUNT=$(echo "$DISPATCHED_LIST" | wc -w | tr -d ' ')` appears byte-identically in the all-failed branch and the success-path status derivation. Mutually exclusive at runtime, so not a correctness issue — but inconsistent with the rest of the same change, which extracted `adversarial_log_row` / `preserve_failure_evidence` / `suspended_seconds` specifically to kill duplication. Recipe: extract `dispatched_count()` next to `suspended_seconds()`. defer-reason: NIT | seen:1 | confidence:30 | source:review | 2026-07-30

## B-REFGUARD — test-references-guards fixtures live inside the real skills/ tree
**Found:** 2026-07-31, during the write-e2e V2 execute run (surfaced by a concurrent-agent stall).
**Issue:** `tests/skill-suite/test-references-guards.sh` creates `skills/tmp-refguard-$$-test/` inside the
real repo. Two concurrent runs collide (~4 min stall observed), and while a fixture exists a concurrent
`validate-skills.sh` sees a foreign skill dir and can mis-count `count-consistency`.
**Why it was accepted:** the test contract-tests a WHOLE-REPO validator, so it needs a fixture the real
validator can see. PID-unique naming + an existence guard removed the deletion risk; the residue is a
false FAIL / mis-count under parallel agents, never a false PASS.
**Escapes the repo entirely (observed 2026-08-03).** The residue is not confined to a false FAIL.
`install.sh` copies `skills/*` into every install target, so an `install.sh` that overlaps a running
guard test — or that follows a killed one — carries the fixture out of the repo and leaves it there
permanently. Found `tmp-refguard-56836-test` and `tmp-refguard-82399-test` sitting in the Claude Code
plugin cache under BOTH `zuvo/1.6.52/skills/` and `zuvo/1.6.53/skills/` (4 directories), long after the
test that made them had finished. They are inert, but they inflate the installed skill count (59 dirs
against 57 in source) and would be read by anything that enumerates the cache. Removed by hand.
**Fix direction:** run the validator against a copied tree (a `--root` option) so fixtures can live in
`mktemp -d` outside the repo — that removes the last shared-state coupling without losing real-repo
coverage, and closes the escape path above at the same time. Until then, `install.sh` could refuse to
copy a `skills/tmp-*` directory — a one-line guard that makes the leak impossible regardless of timing.

## B-ADV-TRUNC — a truncated adversarial review is reported as a complete one
**Found:** 2026-07-31, reviewing the Task 8 patch (50583 chars) during the write-e2e V2 execute run.
**Issue:** `scripts/adversarial-review.sh:394` caps input at `MAX_CHARS=30000`, trims back to a
whole-file boundary and drops the remaining files with only a stderr `WARN: input truncated ... (omitted: …)`.
The Task 8 run silently dropped `website/skills/write-e2e.yaml` — the single largest change in the
patch — yet exited 0 with a normal verdict. Every one of the 12 `adversarial-loop.md` call-sites keys
its gate on the exit code alone, so a partially-reviewed patch reports as fully reviewed.
**Why this matters more since 2026-07-30:** `build-review-patch` (Task 1) made call-sites feed the
review a *correct, complete* patch including untracked files. Bigger, more complete inputs make the
30000-char ceiling far easier to hit, so the P0 fix increased exposure to this one. The failure mode
is the same class the P0 addressed: a gate that looks green over work it never saw.
**Recipe (two parts, either alone is an improvement):**
1. Make truncation impossible to ignore downstream: emit a `TRUNCATED` marker into the verdict body
   and set a distinct exit code (or `input_truncated=true` in a machine-readable status line the
   call-site block checks), so a call-site cannot report a complete review over a trimmed input.
2. Chunk instead of drop: split at file boundaries into N ≤ MAX_CHARS batches, dispatch each, and
   merge the findings — cost scales with patch size but coverage stops depending on patch size.
**Workaround in use meanwhile:** split the patch by hand (`build-review-patch <subset>`) and run one
pass per batch — that is what Task 8 did after catching the WARN.
defer-reason: SCOPE — pre-existing in a 2000-line shared script on 12 call-sites; a fix belongs in its
own task with its own tests, not folded into a docs-sync task | seen:1 | confidence:95 | source:execute-run | 2026-07-31

## B-SKILLPAGES-RED — RESOLVED 2026-07-31 — validate-skill-pages.sh was red on main since 440f2fc
**Resolution:** fixed in the same session it was filed, because Task 10's SMOKE3 asserts this
validator exits 0 and a permanently-red validator would have forced that assertion to be watered
down. All four defects below are closed, plus a FIFTH found while fixing them:
5. **The cross-reference check could not fail the run.** Its `while read` loop was fed by a PIPE, so
   it ran in a subshell and every `ERRORS=$((ERRORS + 1))` inside it was discarded — the script
   printed `FAIL: … references unknown slug: …` and `PASS: All 41 skill YAML files validated
   successfully` in the same run and exited 0. Verified by mutation before and after. This is the
   same false-green class as the P0 this whole plan was written to close, sitting inside the
   validator that was supposed to catch page rot. Now fed by process substitution so the loop runs
   in the current shell.
Retained below as the record of what was wrong and why it went unnoticed for so long.

## B-SKILLPAGES-RED (original entry) — scripts/validate-skill-pages.sh has been red on main since 440f2fc
**Found:** 2026-07-31 (write-e2e V2 execute run). **Not caused by that run** — verified by running the
validator at `b79dad2` (the pre-work commit) and diffing the FAIL sets: byte-identical, 6 failures both
before and after. A permanently-red validator gates nothing, which is how the four defects below
accumulated unnoticed.
**Four independent defects:**
1. `EXPECTED_COUNT=39` (line 8) while 41 pages exist — `geo-audit` and `geo-fix` pages were added by
   440f2fc without bumping the constant.
2. `ALLOW_LIST` (line 98) omits `geo-audit` and `geo-fix`, so the two pages' mutual cross-references
   are reported as unknown slugs — the pages are correct, the list is stale.
3. `geo-audit.yaml` meta.description is 156 chars and `geo-fix.yaml` is 160 (max 155). Real content
   violations; both need a trim.
4. **Validator design flaw:** line 85 `grep "  description:"` is UNANCHORED, so it matches any line
   containing two spaces before `description:` — including argument- and mode-level descriptions
   nested deeper in the file. Two skills legitimately sharing a mode description (e.g. "Apply only
   fixes of the specified fix_type categories") therefore trip the uniqueness check, which was only
   ever meant to police `meta.description`. Anchor it: `grep -h '^  description:'`.
**Note:** the replica of these rules in `tests/skill-suite/test-write-e2e-contract.sh` (14h) already
uses the anchored form, so it is stricter and more correct than the validator it mirrors — fixing
defect 4 brings the validator up to the test, not the other way round.
**Fix direction:** one commit — bump the count, extend the allow-list, trim the two descriptions,
anchor the grep — then assert the validator exits 0 in `tests/` so it can never rot red again.
defer-reason: SCOPE — four defects in another component (validator + two geo pages) with a design
decision in defect 4; discovered during, but unrelated to, the write-e2e V2 plan | seen:1 |
confidence:95 | source:execute-run | 2026-07-31

## B-SHELLCHECK — CQ40 scores 0 on every bash file in the repo; no linter is configured
**Found:** 2026-07-31, TIER 3 CQ audit of the write-e2e V2 range (b79dad2..17ba54b), confidence 90.
**Issue:** nothing lints the repo's shell. There is no `.shellcheckrc`, no CI job runs shellcheck
(`ci/` holds only the opt-in `zuvo-pipeline-entry.yml`, which is not even copied into
`.github/workflows/`), and the only `shellcheck` strings in the tree are three inline
`# shellcheck source=/dev/null` suppressions plus a spec note recording that it is not installed.
Per CQ40's own wording ("No config present = 0 — that is the point of the gate") every bash file
in this repo scores CQ40=0, including the two new ones this range added.
**Why it matters more now:** `build-review-patch` and `e2e-preflight` are exactly the shell class
shellcheck is good at — path containment, symlink refusal, `trap` quoting, locking, and unquoted
expansions (SC2086/SC2064). The zsh word-splitting trap that bit this very session (an unquoted
list arriving as ONE argument) is the same family.
**Why it was NOT fixed in the loop that found it:** shellcheck is not installed on this machine
(`command -v shellcheck` → not found). Adding a config and a CI job for a linter that cannot be run
locally would mean committing rules whose output nobody has seen, and discovering the findings for
the first time in CI across 9 files. The blocker is tool absence, not scope.
**Fix direction:** install shellcheck → run it over `scripts/**`, `hooks/**`, `tests/**` and read
the real output → add `.shellcheckrc` pinning the severity floor and any deliberate suppressions
(with reasons) → fix what it finds → only then wire a CI job, so the job starts green.
defer-reason: SCOPE — repo-wide tooling addition across 9+ bash files, blocked on a tool that is
not installed | seen:1 | confidence:90 | source:review | 2026-07-31

## B-UPSERT-AWK-LEN — e2e-preflight upsert helpers exceed the 50-line function guideline
**Found:** 2026-07-31, TIER 3 CQ audit (CQ11), confidence 70.
**Issue:** `scripts/zuvo-home/e2e-preflight:534` `upsert_awk()` is a one-line bash wrapper around a
151-line embedded AWK program, and `_upsert_locked()` at :466 runs 61 lines across two near-symmetric
create-vs-update branches doing the same trap/mv dance.
**Why it is a NIT and not a defect:** an embedded AWK program is a DSL block, not sprawling bash
control flow, and the audit confirmed both branches are individually commented and their overlap
falls ~15 lines short of the CQ14 repeated-block threshold. No correctness issue was found.
**Fix direction:** if this file grows further, lift the AWK program into a heredoc constant and
collapse the two branches into one parameterised write path.
defer-reason: NIT | seen:1 | confidence:70 | source:review | 2026-07-31

## B-ORIGIN-TOCTOU — the origin gate classifies once, but requests resolve DNS again later
**Found:** 2026-07-31, adversarial review of the write-e2e V2 website page (kimi, low confidence —
but the mechanism is sound and the wording it attacks is ours).
**Issue:** `zuvo:write-e2e`'s Phase 0.5 origin gate classifies the resolved base URL as
LOCAL/STAGING/EXTERNAL_UNKNOWN once, and `--allow-destructive` / `--allow-external-origin` consent is
recorded against THAT classification. The requests happen later and re-resolve the hostname. With a
hostname under operator or attacker influence — rebinding-capable DNS, a VPN-managed corp name,
`/etc/hosts` edited between the gate and the run — a name that classified LOCAL can point elsewhere
when the mutating request is actually sent. Consent was then granted for one origin and spent on
another. The skill's own wording ("LOCAL means it actually resolves to a local destination") states a
check-time answer as if it were a durable property.
**Scale of the real risk:** low for the dominant case (a developer's own machine, `localhost`, a
literal IP — none of which re-resolve to anything surprising), higher for the STAGING path where
hostnames are corporate and DNS is managed elsewhere.
**Fix direction:** resolve once and pin — connect to the resolved IP with Host/SNI preserved — or
re-classify per request and abort on a mismatch with the classification consent was granted against.
Either way, soften the prose to say what the check actually proves.
defer-reason: SCOPE — needs a design decision (pin-vs-recheck) and touches the origin gate's consent
model, not a docs sync | seen:1 | confidence:60 | source:review | 2026-07-31

## B-E2EQ2-CONFLATED — E2E-Q2 fuses two independently-failing properties under one ID
**Found:** 2026-07-31, adversarial review of the write-e2e V2 website page (kimi, INFO).
**Issue:** E2E-Q2 is "test independence AND unique data". They fail for unrelated reasons — a spec can
be order-dependent with perfectly unique data, or collision-prone while being fully independent — but
the gate emits ONE evidence line. The write-e2e contract is "one evidence line per gate; a missing
line means NOT RUN", so a single line cannot say which half was actually checked, which is precisely
the auditability the ten-gate design is sold on.
**Fix direction:** either split into two gates (renumbering the family — the expensive option, and it
would ripple into the eval corpus, the registry summary and the website page), or keep one ID and
require the evidence line to name both halves explicitly (cheap, and enough to restore auditability).
Prefer the second unless the family is being renumbered for another reason anyway.
defer-reason: NIT — auditability improvement, no false PASS today | seen:1 | confidence:70 |
source:review | 2026-07-31
- B-envcompat-platform-list | docs/configuration.md:45 + 15 SKILL.md env-compat blurbs | doc-drift | 15 sites describe env-compat.md as "Claude Code, Codex, and Cursor" while it documents 4 platforms (Antigravity missing). Mechanical sweep or replace with "all supported platforms" so the 15x copy-paste can't drift again. defer-reason: below-threshold(38) | seen:1 | confidence:38 | source:review | 2026-08-01
- B-content-expand-schema | shared/includes/article-output-schema.md + skills/content-expand/SKILL.md | contract-gap | article-output-schema hardcodes skill:"write-article" and lacks content-expand's before/after scores, changes[], voice_delta; content-expand:269 still writes "per article-output-schema.md". Recipe: generalize the skill field, add an optional content-expand object, wire Phase 5 emission — or restore a dedicated schema updated to CURRENT flags (--dry-run/--skip-research, not the deleted --apply/skip_benchmark draft). defer-reason: structural-refactor (multi-file) | seen:1 | confidence:58 | source:review | 2026-08-01
- B-reviewer-missing-include-guard | skills/{plan/agents/plan-reviewer,write-tests/agents/test-quality-reviewer,execute/agents/quality-reviewer,write-article/agents/anti-slop-reviewer}.md | resilience | Reviewer agents mandate include reads but define no missing-file behavior; an LLM agent proceeds and reviews against hallucinated criteria. Recipe: one line each — "If any required include is missing, stop and report [BLOCKED] missing <path> instead of reviewing." defer-reason: below-threshold(38) | seen:1 | confidence:38 | source:review | 2026-08-01
- B-writetests-phase1-skip-marker | skills/write-tests/SKILL.md:122 | ambiguity | Phase 1 table row for test-code-types-core.md says Full with no marker while Phase 0.5 note says its read IS that load; also no missing-file rule for the Phase 0.5 classification read (classify-from-memory is forbidden but undefined on missing file). Recipe: mark row "Full (loaded @ Phase 0.5 — do not re-read)" + extend the include-integrity STOP rule to the 0.5 read. defer-reason: below-threshold(42) | seen:1 | confidence:42 | source:review | 2026-08-01
- B-validator-placeholder-prefix | scripts/validate-skills.sh:232 | enhancement | Placeholder include paths (<resolved-lang>.md, {stack}.md) deliberately unmatched; a typo in the STATIC prefix before the placeholder is never linted. Recipe: match up to first < or { and verify the directory exists. defer-reason: NIT | seen:1 | confidence:32 | source:review | 2026-08-01
- B-codex-registry-note | shared/includes/codex-agent-registry.md:1 | doc-asymmetry | docs/configuration.md now says the build script does NOT read this manifest, but the file itself doesn't carry that warning; an editor may expect TOML output to change. Recipe: one header line "Descriptive manifest — build-codex-skills.sh does NOT read this file; keep in sync by hand." defer-reason: below-threshold(30) | seen:1 | confidence:30 | source:review | 2026-08-01
- B-gate-cq41-cq42 | shared/includes/gate-registry.md | gate-addition | Two approved-by-audit gate additions deferred because they change the family size ("CQ1-CQ40" appears in banners/manifests/website): CQ41 = public-token endpoint security extracted from CQ4's second half (conditional critical; CQ4 keeps tenant scoping only), CQ42 = comment/doc truthfulness (comments state facts the code implements; proven twice this week). Recipe: add both rows, regen, sweep CQ1-CQ40 prose mentions (grep 'CQ1-CQ40'), bump using-zuvo banner + plugin descriptions + website. defer-reason: structural-refactor (multi-file) | seen:1 | confidence:75 | source:gate-audit | 2026-08-01
- B-cap30-js-family | shared/includes/gate-registry.md + rules/typescript.md | gate-addition | CAP30+ JS/TS detector-backed subfamily mirroring CAP20-29's ruff pattern, keyed to the fleet's canonical Biome config (noFocusedTests already covered by AP31; add noFloatingPromises, noDelete, noThenProperty escalations, naive new Date(string) TZ math, bare JSON.parse). Needs rule curation against ~/DEV/uptime/biome.json. defer-reason: structural-refactor (multi-file) | seen:1 | confidence:60 | source:gate-audit | 2026-08-01
- B-e2eq11-diagnostics | skills/write-e2e/references/quality-gates.md | gate-addition | E2E-Q11 candidate: failure diagnostics configured (trace/screenshot/video-on-failure in playwright config; auto-fixable Yes). Changes the "ten gates"/10-of-10 wording in the reference + SKILL. defer-reason: structural-refactor (multi-file) | seen:1 | confidence:55 | source:gate-audit | 2026-08-01
- B-express-astro-depth | rules/express.md + rules/astro.md | content-growth | Express got E5 semantics + 3 concrete patterns and Astro got an Actions section (2026-08-01), but both remain thin vs fleet weight: express lacks helmet/CSRF middleware examples and rate-limit wiring; astro is security-only under a "Conventions" title (no component/content-collection/hydration conventions, no Astro 5 Server Islands). defer-reason: NIT | seen:1 | confidence:50 | source:rules-audit | 2026-08-01
- B-cq38-js-resources | shared/includes/gate-registry.md | gate-wording | Node/TS resource release beyond listeners/timers (fs handles, undici bodies, manually acquired pool clients) sits between CQ22 and CQ38's stack scope — extend CQ22 with a JS clause or add js to CQ38's scope with carve-outs. defer-reason: NIT | seen:1 | confidence:45 | source:gate-audit | 2026-08-01
- B-website-gate-counts | website/skills/test-audit.yaml + code-audit.yaml | doc-drift | Website YAMLs predate two gate expansions: test-audit says "AP1-AP26"/"17 quality gates and 26 anti-patterns", code-audit says "CQ1-CQ29" — live counts are AP1-AP32 / Q1-Q25 / CQ1-CQ40. Pre-existing (months), surfaced by the a3b0068..HEAD review sweep. Recipe: sync counts, and consider adding website/skills/*.yaml to test-gate-consistency's stale-range sweep (also extend it to prose counts "N anti-patterns" — the guard only matches range patterns, which is how "30 anti-patterns" slipped). defer-reason: NIT | seen:1 | confidence:85 | source:review | 2026-08-01
- B-pentest-java-kotlin-rules | shared/includes/pentest-stack-detection.md:89-108 | half-finished-stack | Conditional Rule Loading has no Java/Kotlin row and rules/java.md + rules/kotlin.md do not exist, while stack detection AND full pentest-stack-profiles entries for Java/Spring + Kotlin/Ktor DO exist. Phase 0.2 step 6 ("load matching rule files") has nothing to load for those stacks. Recipe: author rules/java.md + rules/kotlin.md at go.md/rust.md depth (~50L each, template shape), add both rows to the detection table + the fleet stack tables. defer-reason: below-threshold(45 — fleet has no Java/Kotlin repo today) | seen:1 | confidence:90 | source:pattern-docs-audit | 2026-08-01
- B-seo-bot-registry-currency | shared/includes/seo-bot-registry.md | currency | Tier coverage asymmetric: Meta has a training-tier entry (meta-externalagent) but no user-proxy counterpart, unlike OpenAI/Anthropic/Perplexity which have training/search/user-proxy; newer entrants (xAI, Mistral, others) unverified. Needs a LIVE check against published crawler docs + robots directives, not a desk edit. Recipe: fetch each vendor's crawler doc page, reconcile bot_key list, keep the tier vocabulary. defer-reason: NIT | seen:1 | confidence:60 | source:pattern-docs-audit | 2026-08-01

## shellcheck warning cleanup — installer + build scripts
- **Source:** release-gate incident 2026-08-02 (shellcheck installed 11:55 activated a latent strict path in test-install-wiring (7))
- **Scope:** scripts/install.sh, build-codex-skills.sh, build-antigravity-skills.sh, build-cursor-skills.sh — default-severity shellcheck findings (SC2115, SC2011, SC2012, SC2088, SC1091...)
- **Done when:** all four pass plain `shellcheck` (no severity filter); then tighten test-install-wiring (7) back from --severity=error to default
- **Priority:** MEDIUM (style/robustness, no known functional defect)

## Deferred by the 50eeeaf..23a207a aggregate review (2026-08-03)
Everything localized from that review was fixed in-run (commit 7646368). These four
are the only items that genuinely left the fence — each with the concrete reason.

- B-validate-check-categories-extract | scripts/validate-skills.sh:717-788 | readability | `check_categories()` is 72 lines doing five things (file/table presence, malformed-row reporting, duplicate-label reporting, per-file Count comparison, per-skill membership loop) over shared state `all_labels`/`tables`/`present`. Nowhere near the ~150L hard-fail line and no gate fails today; the cost is that a sixth consumer has to read the whole body to find the hook point. Recipe: extract the per-skill loop (everything after `all_labels=...`) into `check_skill_categories "$all_labels"`. defer-reason: NIT (style/readability, zero functional impact) | seen:1 | confidence:70 | source:review-cq | 2026-08-03
- B-skillmd-size-policy | skills/*/SKILL.md (execute is 1501L, +259 this range) | policy | NO rule is being violated — `rules/file-limits.md` is explicitly TS/NestJS/React-calibrated and does not govern markdown SKILL.md files, and the only per-file bound in the repo is write-e2e's bespoke body-line test. So there is nothing to fix, only something to DECIDE: either give validate-skills a generous SKILL.md ceiling with a documented rationale, or state in file-limits.md/CLAUDE.md that SKILL.md files are exempt by design. defer-reason: repo-wide policy decision for the maintainer, genuinely outside this diff's fence | seen:1 | confidence:75 | source:review-struct | 2026-08-03
- B-retro-stub-t64-flaky | tests/adversarial/test-session-retro-carry.sh :: T6.4 | flaky-test | "no new stub added (full retro supersedes — idempotent)" fails intermittently: observed RED mid-review, and RED at the BASE commit 50eeeaf when run against an extracted base tree, then GREEN on a later run of the same unchanged file. So it is state-dependent (leftover markers under ~/.zuvo/run-markers), not a regression from this range — this range touched only the BASE line-budget constant in that file, and `scripts/zuvo-home/retro-stub` (the code under test) is not in 50eeeaf..23a207a at all. Recipe: make the case hermetic w.r.t. $ZUVO_HOME rather than reading the real one. defer-reason: pre-existing debt, out of fence — belongs to whatever last touched retro-stub | seen:1 | confidence:80 | source:review-cq | 2026-08-03
- B-devpush-marketplace-dirty-tree | scripts/dev-push.sh Step 0b (~55-97) vs Step 4 | crash-safety | FOUR providers independently (codex, cursor, kimi, claude — kimi and claude rated it CRITICAL). Step 0b rewrites the SIBLING marketplace working tree but does not commit it; the commit lands only at Step 4. Any failure or interrupt in Steps 1-3 leaves the marketplace repo dirty, and the next run's mandatory `git pull --rebase` then fails on a dirty tree — a trap that needs manual recovery in a repo the user was told is self-healing. Related, same area: an orphaned `.zuvo-count-*` mkstemp file after a kill, and no rollback if `os.replace` fails on the second of two staged files. Recipe: either commit the count fix immediately in Step 0b as its own commit, or register a trap that restores the marketplace tree on any non-zero exit before Step 4. defer-reason: NOT localized — changing where the marketplace commit happens reorders dev-push's push/rollback contract and needs its own RED test against the 32-assertion gate suite; that is a scoped change, not a review-loop edit | seen:1 | confidence:90 | source:review-adversarial | 2026-08-03

## B-CQ40-METALINTER — no meta-linter configured repo-wide (CQ40=0)
Surfaced by: zuvo:review v1.6.53..HEAD (CQ auditor, 2026-08-03). Pre-existing, repo-wide.
`find` for pyproject.toml / ruff.toml / .flake8 / .shellcheckrc returns nothing, and no
workflow invokes ruff/mypy/shellcheck. gate-registry.md CQ40 says "No config present = 0 —
that is the point of the gate". This release added ~520 lines of new unlinted Python
(check-skill-structure.py, verify-review-claims.py) plus shell, roughly doubling the surface.
Defer-reason: structural-refactor (multi-file) — new config files + CI wiring, not a
single-file fix.
Recipe:
  1. Add `pyproject.toml` with `[tool.ruff]` (select E,F,B,SIM) and `[tool.mypy]` for scripts/.
  2. Add `.shellcheckrc`; run `shellcheck scripts/*.sh hooks/**/*.sh tests/**/*.sh`.
  3. Wire both into scripts/validate-skills.sh as an optional-tool check (SKIP-if-absent,
     like the existing bats group) so a missing binary is a SKIP, not a false failure.

## B-PATH-CONTAIN-SHARED-FN — the containment rule lives in 3 copies
Surfaced by: zuvo:review v1.6.53..HEAD (CQ-1 root cause, 2026-08-03).
The absolute + `..`-segment proof-path check is implemented three times:
hooks/lib/pipeline-gate-lib.sh::pg_artifact_proven, scripts/review-artifact-sync.sh::lint_artifact,
and ::do_sync. d568825 fixed two and missed the third, which reopened a real traversal
(fixed in 9df7c06). Fixing the instance does not fix the shape.
Defer-reason: structural-refactor (multi-file).
Recipe:
  1. Create scripts/lib/path-contain.sh exporting `path_contained <ref>` (0=safe, 1=reject),
     carrying the leading-slash comment that explains why `../x` needs the prefix.
  2. Source it from all three call sites; delete the inline case blocks.
  3. Point tests/hooks/test-proof-path-containment.sh at the shared function AND keep the
     end-to-end do_sync case — the re-implementation trap is what hid the drift.
  4. While there: make the shared helper CANONICAL, not lexical. `case` segment matching is
     defeated by a symlink — a ref with no `..` at all can still resolve outside the repo.
     `realpath -e -- "$root/$ref"` and require the result to be prefixed by `realpath "$root"`.
     Raised by the cross-provider pass on the fix diff (2026-08-03); deferred with the rest of
     this item because it belongs in the one shared function, not a fourth inline copy.

## B-INSTALL-CLAUDE-MANIFEST — install.sh never refreshes the Claude Code cache manifest
Surfaced by: zuvo:ship v1.6.54 post-merge verification (2026-08-03).
`scripts/install.sh` copies `.codex-plugin/plugin.json` into the Codex targets (lines ~767,
~801) but has NO equivalent copy of `.claude-plugin/plugin.json` into
`~/.claude/plugins/cache/zuvo-marketplace/zuvo/<version>/`. Measured after installing
v1.6.54: the manifest inside cache dir 1.6.53 still declared version 1.6.16, and inside
1.6.54 it declared 1.6.47 — each frozen at whatever Claude Code itself wrote when it
created that directory. Skills still load (install.sh does sync skills/, scripts/, rules/,
shared/ to every cache dir), so this is metadata drift, not a load failure — but the
plugin's advertised version and skill count in that manifest have been wrong for
~40 releases and nobody noticed, which is exactly the shape of the count-consistency bugs
this release fixed elsewhere.
Defer-reason: NOT deferred for size — deferred because it is an unreviewed change to the
install path made minutes after merging v1.6.54, and shipping it without review would
contradict the gate discipline this release is about. Next session, first item.
Recipe:
  1. In install.sh's Claude Code loop, after the scripts/ copy: create
     `$CACHE_DIR/.claude-plugin/` and copy `$ZUVO_DIR/.claude-plugin/plugin.json` into it.
  2. Add an assertion to tests/hooks/test-install-wiring.sh: after a simulated install, the
     cache manifest's `version` equals package.json's `version`. That is the check whose
     absence let this sit for 40 releases.
  3. Check whether the Cursor and Antigravity targets have the same omission.
