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

- [DONE 2026-08-17] 1 [CLOSED 2026-08-17 — both silent fall-throughs (absent helper, no report found) now WARN 'SKIPPED (not passed)'. Deliberately non-blocking: review writes to memory/reviews/, which this lookup does not scan. tests/adversarial/test-audit-verify-visibility.sh pins both WARNs AND that a failing verification still exits 2.] [TRIAGE 2026-08-16: STILL-REAL. append-runlog's `[ -x verify-audit ]` still fails open silently; code unchanged since d25d2e4. Live policy decision, not a closed disposition.] [security] scripts/zuvo-home/append-runlog | rule:adversarial-T1-preexisting | sig:verify-audit-fail-open
  The audit-content gate uses `if [ -x "$ZUVO_BIN/verify-audit" ]` which FAILS OPEN: audit/review/pentest runs silently skip finding-content verification when verify-audit is absent or non-executable. Pre-existing (identical `[ -x $HOME/.zuvo/verify-audit ]` semantics before the ZUVO_HOME change; NOT introduced by 2026-05-18 retro-checkpoint Task 1). Fixing requires a policy decision: make verify-audit MANDATORY for audit-class skills (regresses optional/partial installs that install.sh intentionally warns-and-skips) vs keep optional. Out of Task-1 scope. confidence:70 source:adversarial-task-1 iter2 (codex+cursor, high-conf)

- [DONE 2026-08-16] 2 [CLOSED 2026-08-16 (triage) — the dedup model this entry asks for IS what ships today (retrospective.md:121-124); its own 2026-05-18 disposition still holds and nothing regressed.] [docs] shared/includes/retrospective.md | rule:adversarial-T2-residual | sig:retro-doc-WARN-INFO
  Task 2 adversarial final run: 8 WARNING + 3 INFO residual (test-robustness nits, prose-precision, speculative parser-strictness). Substantive contracts green. Dedup-key CRITICAL oscillated date<->sha<->session-id across 5 iters; root-resolved (write-time coherence via session-state Task 6; post-hoc dedup keys in-line SKILL+PROJECT+SHA7). DISPOSITION: accepted per user (BLOCKED_ADVERSARIAL_LOOP, 2026-05-18) — Release-Gate model, not infinite loop. Revisit only if a real downstream parser breaks. confidence:35 source:adversarial-task-2

- [DONE 2026-08-16] 3 [CLOSED 2026-08-16 (triage) — premise is false today: append-retro explicitly SHARES retro-stub's lock ($ZUVO_HOME/.retro.lock.d), and retrospective.md no longer hand-appends to retros.log at all. Closed by the append-retro centralization (3691263).] [reliability] shared/includes/retrospective.md + scripts/zuvo-home/{retro-stub,append-runlog} | rule:adversarial-T3-rotation-clobber | sig:retros-log-no-cross-writer-lock
  retros.log rotation (head+tail>tmp; mv) can clobber a concurrent external append because retro-stub's mkdir-lock is NOT shared by the other writers (retrospective.md bash append, append-runlog). PRE-EXISTING: retro-stub mirrors retrospective.md's canonical rotation pattern; it does not worsen it. Proper fix = a unified retros.log write-lock convention across ALL three writers — cross-cutting, out of Task 3 scope (scope-creep guard). confidence:55 source:adversarial-task-3 iter2

- B-4 [TRIAGE 2026-08-16: unchanged, self-disposed accepted invariant (confidence 30). Candidate for docs, not backlog.] [reliability] scripts/zuvo-home/retro-stub | rule:adversarial-T3-residual | sig:retro-stub-WARN
  Task 3 adversarial iter3: 0 CRITICAL, 5 WARNING + 2 INFO residual (lock-steal theoretical TOCTOU on mtime path — mitigated by pid-liveness + ms critical section + atomic mkdir, documented invariant; minor portability/edge nits). Substantive contracts green 17/17. Accept per Step-7b non-critical-with-backlog. confidence:30 source:adversarial-task-3

- B-5 [TRIAGE 2026-08-16: unchanged, self-disposed accepted invariant. Candidate for docs, not backlog.] [reliability] scripts/zuvo-home/append-runlog | rule:adversarial-T4-residual | sig:t4-WARN-INFO
  Task 4 adversarial: 4 distinct CONVERGING CRITICAL fixes (lock OR-liveness, pid-write-fail, rmdir busy-spin, TSV column-drift) -> iter5 0 CRITICAL. Residual 3W/3I = theoretical (PID reuse window; lexicographic ISO compare assumes canonical Z-format [enforced by all writers]; schema-version drift assertion). Lock+match now correct-by-construction. Accept per Step-7b non-critical+backlog; cap exceeded JUSTIFIED (distinct converging fixes, not oscillation — contrast B-2 Task 2). confidence:30 source:adversarial-task-4

- B-6 [TRIAGE 2026-08-16: unchanged, self-disposed accepted invariant. Candidate for docs, not backlog.] [reliability] scripts/zuvo-home/retro-stub | rule:adversarial-T5 | sig:t5-residual-and-refuted-FP
  Task 5 --sweep adversarial: iter1 CRITICAL (marker deleted on lock-busy -> orphan telemetry lost) FIXED + T5.e regression guard. iter2 CRITICAL (rc=$? in if/else else-branch == 0 not 3) EMPIRICALLY REFUTED: direct test `if f(return 3); else rc=$?` -> rc=3, and T5.e (asserts rc!=0 on lock-busy) passes — reviewer misread bash if/else $? semantics; no code defect. Residual 4W/2I theoretical. confidence:25 source:adversarial-task-5

- [DONE 2026-08-16] 7 [CLOSED 2026-08-16 (triage) — session-state.md still documents the stable retro-session-id / no-cross-run-dedup model this entry says iter3 landed. Fix held; entry was never marked.] [docs] shared/includes/session-state.md + tests/adversarial/test-session-retro-carry.sh | rule:adversarial-T6-residual | sig:t6-WARN
  Task 6 adversarial: iter1 CRITICAL (test discarded retro-stub status) FIXED; iter2 2 CRITICAL (retro-session-id == resuming-session always-fails; cross-run dedup data-loss) FIXED -> aligned to Task 2 canonical run-identity model; iter3 0 CRITICAL. Residual 3W/2I: absolute-vs-delta line budget, handcrafted-log parity, permissive substring scoping, temp cleanup on early-fail. 'Fields in HTML comments' = EXISTING execution-state.md convention (session-id/status same), by-design not a defect. Accept per Step-7b. confidence:25 source:adversarial-task-6

- B-8 [TRIAGE 2026-08-16: unchanged, self-disposed accepted invariant. Candidate for docs, not backlog.] [reliability] scripts/zuvo-home/retro-stub + skills/{brainstorm,plan,execute}/SKILL.md | rule:adversarial-T7-residual | sig:t7-bounded
  Task 7 adversarial: iter1 2C (session-id $$ / marker-before-sweep) + iter2 2C (filename collision / sweep-active-run) FIXED (unique marker filename, sweep-first, grace window, full-retro precheck); confirmatory 1C = doc over-promise FIXED (best-effort prose) + friction tr|sed -> explicit case + GRACE numeric guard. Residual WARN/INFO: NF==17 column dependency (consistent w/ B-5 Task4 disposition — canonical format enforced by all writers), $_RPR basename not sanitized (git-toplevel-controlled, low risk), start_ts non-canonical-format fallback (all zuvo writers emit canonical Z). Bounded/by-design. confidence:25 source:adversarial-task-7

- [DONE 2026-08-17] 9 [CLOSED 7c5833e — install_zuvo_home on every dispatch branch. Measured in an isolated HOME: `install.sh codex` went from 0 helpers to 29. Structural per-branch regression test added.] [TRIAGE 2026-08-16: STILL-REAL, verified at install.sh:1583-1587 — claude/codex/cursor/antigravity/kimi branches all omit install_zuvo_home; only both|all calls it. Open since v1.3.109.] [distribution] scripts/install.sh | rule:install-platform-dispatch-gap | sig:zuvo-home-not-in-platform-only
  PRE-EXISTING (not introduced by retro-checkpoint): install_zuvo_home (installs append-runlog/verify-audit/compute-preload/retro-stub into shared ~/.zuvo) is only invoked in the `both|all` dispatch — `./scripts/install.sh claude|codex|cursor` alone does NOT install any ~/.zuvo helper. Canonical docs use `./scripts/install.sh` (=all) + dev-push.sh so it works in practice; platform-only subcommands are a latent gap affecting ALL zuvo-home helpers equally. Fix = call install_zuvo_home from each platform branch too (separate decision, affects append-runlog distribution). confidence:55 source:adversarial-task-8-verification

- B-10 [TRIAGE 2026-08-16: unchanged, self-disposed style nit (confidence 20). Candidate for docs, not backlog.] [config] scripts/install.sh + tests/adversarial/test-install-retro-stub.sh | rule:adversarial-T8-residual | sig:t8-WARN
  Task 8 adversarial: 0 CRITICAL, residual 7W/7I (gemini+cursor) — test-design/style nits (grep scoping, dry-run only exercises the clause not full function, cp-overwrite semantics consistent w/ other zuvo-home helpers). Install clause mirrors the proven append-runlog pattern exactly. Pre-existing platform-only-dispatch gap tracked B-9. Accept per Step-7b non-critical+backlog. confidence:20 source:adversarial-task-8

- B-11 [TRIAGE 2026-08-16: unchanged. NB its `grep -c ... 2>/dev/null) || true` is the CORRECT form — NOT the `|| echo 0` trap fixed today in e4c11ab/fcdc673; it only looks similar.] [docs] skills/context-audit/SKILL.md | rule:adversarial-T9-residual | sig:t9-WARN
  Task 9 adversarial: 0 CRITICAL, 4W/2I (cursor) — test-design/style nits (fenced-block grep scoping, fixture parity, tail-5 recency window). Block is a clean ZUVO_HOME-aware SKIP: parser with no-skip-log degrade + clean grep -c capture. Accept per Step-7b non-critical+backlog. confidence:20 source:adversarial-task-9

- [B-seccorpus-1] tests/security-corpus/run.sh — provenance is string-based (path-boundary match + --require-provenance). A deliberately fabricated .meta.source_fixture string still passes. v2: optional content-hash binding (hash fixture dir, compare to a recorded digest). Real threat (stale/copied/omitted findings) already covered. Source: execute Task 1 adversarial rounds 3-5 (relooped). conf: 40
- [B-seccorpus-3] pentest-source-sink-registry.md — new-class sink/source regex seeds are advisory discovery starting points (registry header: 'start with these before semantic escalation'). 5 adversarial rounds tightened the major over-broad tokens (graphql mitigations, dom-xss dangerouslySetInnerHTML, env./ctx./context. non-taint, jsonwebtoken import, yaml SafeLoader lookahead, JSON.parse.reviver, __reduce__). Residual regex-precision nitpicks on advisory seeds → defer; the safe-pattern layer (Task 4) is the real false-positive control. conf: 30
- [B-seccorpus-4] pentest-safe-pattern-registry.md — new-class safe-pattern match_signals: adversarial pushes for ever-stricter sufficiency proofs per signal. Per Registry Rule 2 safe-patterns are trace-governed DOWNGRADES not auto-excludes (the trace must still show the defense covers the active path), so residual sufficiency-pedantry is bounded. Primary defense per class is now required (filter-escape for LDAP, entity-disable for XXE, depth/complexity for GQL, same-sink guard for deser). conf: 30
- [B-secaudit-1] security-audit S1/S2/S3 registry-seeded trace: 6 adversarial rounds hardened (reachability-not-taint honesty, degraded-mode HIGH for local flows, registry-MISSING fallback, stage-1b degradable, step-6 dimension-only degraded). Round-6 CRITICAL (codesift-setup.md not loaded) was a diff-scope FP — it's loaded at line 84. conf: 25
- [B-secaudit-3] security-audit S14 IaC scanner block: advisory snippet; hardened (output-keyed scan helper not exit-code, JSON validation, recursive .tf detection, IC-4/IC-5 degraded labeling). Residual adversarial nitpicks (repo-root scan scope/exclusions, multiple-lockfile loop, stderr handling) are doc-snippet refinements the agent adapts. conf: 25
- [B-seccorpus-6] Kotlin/Ktor sink seed: adversarial repeatedly flags regex 'unbalanced' — empirically false (compiles, balanced depth 0, matches fixture); a markdown double-escape (\( / \|) artifact. Profile prose lists more sinks than the seed regex by design (seeds are discovery starting points per registry header). conf: 20
- [B-secaudit-4] IC-3 cross-skill reconciliation: 6 adversarial rounds specified a subtle merge algo (evidence-merge both records, fail-closed source component, disposition-conflict→needs_review not auto-severe, two-axis status-vs-severity separation, SKILL.md cross-ref, provisional-severity-in-needs-verification). Logic now well-specified; further rounds are presentation nuance. conf: 20
- [B-secaudit-5] security-audit coverage-gate parity (IC-2/IC-5): 4 adversarial rounds specified it (immutable+additive Phase-0 entry-point snapshot, no denominator-gaming, gate_status folds surface_gate, N=0→N/A non-failing, breadth-not-depth, client-surface still audited). Residual unbounded refinements (perfect discovery impossible) clarified as best-effort. conf: 20
- [B-secaudit-6] v2-class warning-only grace: adversarial flags the grace itself (HIGH v2 findings excluded from gate). This is the PLAN-MANDATED trade-off (plan WARNING #5: CI-safety) — [POST-CAP: DEFERRED] accepted per plan Review Trail. Mitigations: findings still reported+backlogged, --strict-v2 enforces now, time-boxed to 1.4.x→1.5.0. Residual --quick/score-cap wording aligned. conf: 20

## B-infra-collect-nohup-quote-transport — DONE (already implemented; entry was stale)
- **Closed:** 2026-08-18. `_ssh_exec_long()` has carried the quote-safe transport since Task 5:
  the battery command is shipped to a remote `.cmd` file over a `base64 -d > cmd_f` pipe with no
  backgrounding, and a SECOND, CONSTANT launcher (`nohup sh -c 'timeout … sh ${cmd_f} …'`) embeds
  only filenames and the timeout. No battery text ever enters a `sh -c '…'` string, so its quotes
  are inert. Verified at scripts/infra-collect.sh:583-606.
- **Source:** zuvo:execute Task 4 adversarial round 2 (deferred to Task 5 live-wiring)
- **File:** scripts/infra-collect.sh — run_remote() long-mode nohup wrapper
- **Issue:** `sh -c '...'` string-embeds the inner battery command; a single quote (awk/sed are full of them) would terminate the wrapper. NOT exploitable at skeleton stage (live long-path stubbed; dry-run only prints).
- **Fix owner:** Task 5 MUST replace string-embedding with quote-safe transport (base64-decode inner cmd on target, or remote temp script) BEFORE activating live execution.
- **Confidence:** 60 (real latent, gated by §2 static rule, no current exploit path)

## B-infra-collect-value-heuristic-redaction — DONE
- **Closed:** 2026-08-18. SED_REDACT gained a value-shape pass, so a generically-named secret
  (`FOO=ghp_…`) no longer leaves the host verbatim. Two rules: vendor token PREFIXES (ghp_/AKIA/
  xoxb-/JWT/…), matched by issuer rather than entropy; and long opaque values after `=`/`:`.
- **The constraint was not adding a rule, it was not DESTROYING EVIDENCE.** A plain ">=32 chars of
  base64 alphabet" rule eats every lowercase-hex sha256 digest, image ref and checksum in trivy/
  docker/nmap output — gutting the bundle the collector exists to produce. sed -E has no lookahead,
  so it is three passes: mark candidates with a sentinel, UNMARK pure lowercase hex, redact what
  remains. The unmark must require the hex run to reach a non-alphabet char or end-of-line;
  without that boundary it unmarks on a leading `a` and every secret beginning with a hex
  character walks straight back out (caught by mutation probe, now assertion 19/20).
- **Test:** tests/infra-suite/test-infra-redaction.sh, 20 assertions — 8 redaction, 9 EVIDENCE
  PRESERVATION, sentinel non-leakage, and the two boundary cases. Registered in the infra
  aggregator. Mutation-probed: 7 fail on the pre-fix constant, 3 on removing the anchor.
- **Source:** zuvo:execute Task 5 adversarial security round 4 (deferred — IC-5 design trade-off)
- **File:** scripts/infra-collect.sh SED_REDACT
- **Issue:** Keyword-based redaction (IC-5 spec design) only fires when the KEY NAME contains a sensitive substring; a generically-named secret (`FOO=abc123`) in an arbitrary config would leak verbatim.
- **Mitigation already in place:** IS12 (the .env reader) emits key NAMES only, never values — the dominant leak path is structurally closed. Other battery checks read only known-schema config files (sshd_config/sysctl/ufw have no secret fields; redis requirepass+masterauth explicitly covered).
- **v2 fix:** add a value-heuristic redaction pass (high-entropy / token-shaped values) on top of keyword redaction; tune false-positive rate against real config corpus.
- **Confidence:** 50 (real residual, structurally mitigated where it matters; spec-sanctioned keyword model)


## B-infra-collect-multi-container-cve — DONE
- **Closed:** 2026-08-18. IS9-image-critical-cve now enumerates `docker ps --format '{{.Image}}'
  | sort -u` and scans every distinct running image, not `head -1`.
- **The bound is the interesting part.** Unbounded, N images x TRIVY_TIMEOUT_S overruns
  CHECK_TIMEOUT_S and the check returns truncated — which in the bundle is indistinguishable from
  full coverage, i.e. the same blindness one layer up. So `IS9_MAX_IMAGES` (default 8, integer-
  guarded with the other timeout constants) caps it, and when the cap bites the evidence emits
  `IS9-IMAGE-SCAN-CAPPED: stopped after N of M distinct images` with the REAL total.
- Evidence markers: `IS9-IMAGE: <ref>` per block (so CVEs are attributable per image),
  `IS9-IMAGE-SCAN-FAILED: <ref>` (per-image gap, loop continues), `IS9-NO-RUNNING-CONTAINERS`.
  container-analyst.md gained a marker table and the rule that only a scan with no CVE lines AND
  no CAPPED/FAILED marker supports "no CRITICAL image CVEs on this host".
- **Test:** tests/infra-suite/test-infra-is9-multi-image.sh, 10 assertions, stub docker/trivy on
  PATH. Mutation-probed: 9 fail on the old `head -1` row, 2 on silencing the cap line.
- **Source:** zuvo:execute Task 9 adversarial (deferred — v1 scope boundary, not a bug)
- **File:** scripts/infra-collect.sh IS9-image-critical-cve
- **Issue:** The IS9 docker CVE check audits a single container image, not all running containers — partial coverage (correct for what it scans, incomplete fleet-wide).
- **v2 fix:** enumerate `docker ps -q` and run trivy per image; aggregate per-container findings.
- **Confidence:** 55 (coverage limitation, results correct for the scanned image)

## B-install-sh-copy-verification — DONE
- **Closed:** 2026-08-18. The `|| true` STAYS (a partial install must not abort the other four
  hosts) — the CLAIM is what gets checked. New `verify_copied <label> <src> <dst> <name…>` runs
  after each host's copy block; `ok "Scripts installed"` is now conditional on it, and a final
  summary exits 1 naming every path that did not arrive.
- **The rule is narrow on purpose: assert the destination only when the SOURCE exists.** A file
  absent from the repo was never meant to be copied, so it cannot raise a false alarm — and a
  verifier that cries wolf on optional files is one that gets ignored, then deleted. Uses `-s`
  rather than `-e`: `cp` can create the target and then fail, and a 0-byte file is a failed copy.
- **Live proof, not just unit:** truncated + chmod a-w on ~/.codex/scripts/benchmark.sh → install
  exits 1, prints `codex scripts: /Users/greglas/.codex/scripts/benchmark.sh`, drops that block's
  ✓ (3 "Scripts installed" lines instead of 4) and still completes the other three hosts.
- **Test:** tests/hooks/test-install-copy-verification.sh, 18 assertions. Mutation-probed: 2 fail
  on `-s`→`-e`, 2 on removing the source-exists guard, 1 on making the summary exit 0.
- **Note on the test itself:** it SOURCES install.sh, which defines its own `ok()`. The first cut
  named its helper `ok()` too and the source silently replaced it — every assertion printed a green
  tick and incremented nothing, so a fully passing run summarised as PASS=1. Helpers are `t_ok`/
  `t_no` now. A test whose counter the subject can overwrite cannot report on the subject.
- **Source:** zuvo:execute Task 10 adversarial (pre-existing convention, repo-wide)
- **File:** scripts/install.sh Codex/Cursor Step 7 script-copy blocks
- **Issue:** ALL named-script cp lines (benchmark.sh, adversarial-review.sh, reviewer-model-route.sh, blind-audit-codex.sh, infra-collect.sh) use `cp ... 2>/dev/null || true`, so a missing/failed copy still prints "Scripts installed". Task 10 conformed to this convention for infra-collect.sh; the gap is pre-existing and repo-wide.
- **v2 fix:** add a post-copy verification loop asserting each expected script exists at its dest; warn/exit on any missing. Repo-wide (not infra-audit-specific).
- **Confidence:** 50 (pre-existing convention; `|| true` is intentional install robustness, but silent-fail masks real breakage)

## B-noverify-hardening — DONE (2 of 3 closed; the third was never a bug)
- **Closed:** 2026-08-18.
  1. **git alias USAGE — CLOSED.** Both `hooks/block-no-verify.sh` and `scripts/git-noverify-shim.sh`
     resolve `git config --get alias.<sub>` for a non-gated subcommand and re-scan the expansion.
     Measured: `git yolo -m x` (alias.yolo = commit --no-verify) was rc=0, now blocks in both.
     The two deferral reasons are handled, not accepted: recursion is bounded by a depth limit AND
     a seen-set (aliases chain legitimately and can be circular; a hang here wedges every Bash tool
     call and every git command, which is worse than the bypass), latency by skipping builtin names
     — git never lets an alias shadow a builtin, so that skip is free and not a security decision.
     `!shell` aliases are scanned as text; stated as weaker.
  2. **quoted flag — NOT A BUG.** `git commit "--no-verify"` does not evade the parser: xargs
     tokenizes quote-aware and the quotes are gone before the scan. Measured rc=2 for both quote
     styles at HEAD, i.e. the backlog entry was wrong. Both forms are now pinned by tests so the
     claim cannot be re-filed, and so a future tokenizer change that DOES break it gets caught.
  3. **commit-gate mtime TOCTOU — CLOSED.** Note the entry's own framing was wrong too: the
     execute-run half of that gate BLOCKS (only `pipeline_nudge` is advisory). It compared the
     artifact mtime against the newest staged PATH in the working tree, while a commit stages BLOBS
     FROM THE INDEX — different things. `adversarial-review.sh` now records `reviewed_blob=<oid>`
     per reviewed file and the gate requires every staged blob to be one of them; artifacts without
     those lines keep the mtime path so pre-existing ones do not break on day one.
     `--abbrev=40` on the raw diff is load-bearing: git abbreviates OIDs to 7 chars by default
     while `git hash-object` prints 40, and without it the gate blocks EVERY commit.
- **Tests:** tests/hooks/test-noverify-alias.sh (24 assertions, both layers on one fixture repo so
  they cannot diverge; probes: 12 fail without the fix, 2 without the cycle guard) and
  tests/hooks/test-noverify-content-binding.sh (8 assertions incl. a live proof the pre-fix gate
  accepted the same fixture; probes: 1 fail on dropping --abbrev=40, 2 on removing the recorder).
- **Date:** 2026-06-28
- **Source:** zuvo:review aggregate (Phase Final-2) of pipeline-entry enforcement; adversarial=gemini.
- **Scope:** `hooks/block-no-verify.sh`, `scripts/git-noverify-shim.sh`, `hooks/pre-commit-adversarial-gate.sh`.
- **Residual bypasses of the `--no-verify` best-effort layer** (CI is the unbypassable backstop; see docs/pipeline.md "Known bypasses"):
  1. git aliases — resolve `git config --get alias.<sub>` before validating the subcommand (recursion-guarded).
  2. quoted flag in command-string hook — `git commit "--no-verify"` evades the string parser (the PATH-shim already catches it via real argv); a quote-aware tokenizer would close it.
  3. commit-gate mtime TOCTOU — switch the freshness check from working-tree mtime to staged blob-hash comparison (`git ls-files -s`) recorded at review time.
- **Why deferred:** structural hardening of a layer the architecture defines as best-effort; not a guarantee gap. Real complexity (subprocess alias resolution, blob-hash tracking) for marginal local gain. Route via `zuvo:refactor`/`zuvo:build` when prioritized.

## B-driftguard-bounded-age — DONE
- **Closed:** 2026-08-18. Both state-drift guards in `hooks/pre-commit-adversarial-gate.sh` asked
  `ls "$CTX_DIR"/adversarial-task-*.txt` — does ANY artifact exist. That is a fail-safe with no
  expiry: one file from a run that finished weeks ago disables it permanently, and the longer a
  repo is used the likelier such a file is to exist. New `_recent_artifact_exists` bounds the match
  by the SAME `$GATE_GRACE` window that decides whether the marker is live, so both halves of the
  comparison age together instead of one being immortal.
- Measured: live marker + a 2020-dated artifact → the unbounded variant returns 0, the bounded one
  blocks; a freshly touched artifact still passes (so it is not just a gate that always blocks).
- **Test:** assertions 9-12 of tests/hooks/test-noverify-content-binding.sh.
- **Note on how the "before" case is proven:** the pre-fix gate is DERIVED BY MUTATION of the
  current file, not fetched from `HEAD:`. The first cut read HEAD, which is right exactly until the
  fix is committed — after that HEAD carries the fix, the assertion compares the gate with itself
  and reports the bypass as unreproducible. An assertion that expires the moment the work lands is
  worse than none. Both "was it real" assertions in that file now mutate instead.
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

- [DONE 2026-08-17] gate-1 [CLOSED 2026-08-17 — pre-commit-adversarial-gate.sh now sources refactor-gate-lib and reads status via _ap_status instead of grepping the HTML-comment dialect literally, so plain-dialect execution-state.md files (roughly half of live runs) are no longer invisible to it. Degrades to the old literal grep only if the lib is missing, so an absent lib falls back to previous behaviour rather than to no check.] [TRIAGE 2026-08-16: STILL-REAL at line 76, literal single-dialect grep; refactor-gate-lib's dual-dialect _ap_status sits unused next door.] | hooks/pre-commit-adversarial-gate.sh:76 | stale-dialect | Greps the literal `<!-- status: in-progress -->` but real execution-state.md files are ~50/50 plain vs HTML-comment, so it misses roughly half of live runs. Use `_ap_status` from refactor-gate-lib.sh (both dialects). Found while fixing the same class in plan_execute_gate_check. | seen:1 | confidence:90 | source:build | 2026-07-22
- [DONE 2026-08-16] gate-2 [CLOSED — 6d114f2: ZUVO_AI_RUN + ANTIGRAVITY_SESSION_ID added to pg_is_agent_env, plus a set-comparison drift guard in test-pipeline-gate-lib.sh. Triage promoted this from 'drift' to MUST-FIX after tracing the consequence: pre-push-gate.sh:42 exempts whatever pg_is_agent_env calls human, so a ZUVO_AI_RUN=1 run (refactor's own marker) skipped the pipeline gate outright.] | hooks/lib/pipeline-gate-lib.sh:325 | drift | `pg_is_agent_env` (bash, 13 vars) and `_is_agent_env` (POSIX, 15 vars) are separate hand-maintained lists. refactor-gate-lib now has a test-side drift guard; pipeline-gate-lib has none. Cannot share code (bash ${!var} vs POSIX). | seen:1 | confidence:80 | source:build | 2026-07-22
- [DONE 2026-08-17] gate-3 [CLOSED 2026-08-17 — diagnosed and fixed; the smoke test was stale in TWO independent ways and the entry named neither correctly. (a) G4 'covering artifact' wrote an artifact with no `adversarial:` line, which stopped granting coverage when the proof-of-work layer landed 2026-07-23 (pg_artifact_proven demands >=2 REVIEW BY lines on any post-cutoff artifact). Fixture now writes a REAL proof, so the smoke covers the proof layer instead of grandfathering it off. (b) G3 asserted the Stop gate exits 2, but its DEFAULT became warn-only (exit 0 + message) on 2026-07-10 after a 3-line icon swap triggered a ~20-minute adversarial review of the whole un-pushed pile; ZUVO_STOP_NUDGE_EXIT=2 restores blocking. Both halves now pinned — asserting only the override would let a silent revert of the default pass unnoticed. Also noted while tracing: on a repo with NO remote whose current branch IS the default branch, pg_mergebase_range yields a degenerate HEAD..HEAD and the Stop nudge goes silent. Not fixed here (it is a design question about what 'unreviewed scope' means with no reference point, not a stale assertion) — recorded so the next look starts from the mechanism. SMOKE PASS restored, first time since July.] [TRIAGE 2026-08-16: REPRODUCED LIVE — `bash tests/hooks/smoke-pipeline-entry.sh` fails G3 'Stop nudge' on a clean tree right now.] | tests/hooks/smoke-pipeline-entry.sh | pre-existing-fail | G3 "Stop nudge" fails on a clean tree, independent of the gate work (verified by stashing). Not a regression; needs its own diagnosis. | seen:1 | confidence:95 | source:build | 2026-07-22
- [DONE 2026-08-17] gate-4 [CLOSED 2026-08-17 — inspect() now counts PATH-SHAPED tokens separately and emits a third verdict. Pure paths -> ARMED with the real count; mixed -> ARMED-PARTIAL showing '2 of 3' plus how many tokens are prose; prose-only -> BLIND rather than a confidently wrong ARMED. Discriminator is whitespace in the token, which only became clean after B-gate-5 stripped inline annotations upstream — before that, `svc.ts (modify - line 559)` would have been misread as prose. All three verdict consumers updated (doctor-one, sweep counter, sweep printer). Regressions verified against the pre-fix script: mixed and prose-only both reported ARMED there.] [TRIAGE 2026-08-16: STILL-REAL, _expand_plan_files has no path-shape filter.] | scripts/zuvo-phase.sh:inspect | false-confidence | `**Files:**` lines written as prose (6 repos share one such spec) are counted as declared paths, so doctor reports ARMED with a file count the gate cannot actually match. Consider an ARMED-PARTIAL verdict for non-path-shaped tokens. | seen:1 | confidence:70 | source:test-audit | 2026-07-22
- [DONE 2026-08-17] gate-5 [CLOSED 2026-08-17 — two halves, both needed. (a) the tokenizer now tracks () depth alongside {}, so a comma inside an inline annotation no longer splits the entry. (b) a TRAILING parenthetical annotation is stripped from the emitted token — keeping the commas was only half the job, because `svc.ts (modify - line 559, extract helper)` is still not a path and matches no changed file, so the declared entry stayed invisible either way. Trailing-only and whitespace-anchored, so a real path with glued parens (`weird/name(v2).ts`) is untouched, which the regression pins. Direction of change: MORE declared files now resolve, i.e. the gate moves toward blocking, which is the way it is meant to fail. Probed against the old lib: the annotated entry splits into two non-paths there.] [TRIAGE 2026-08-16: STILL-REAL, awk tracks {} depth only; comma inside () still splits. Fail-open only.] | hooks/lib/refactor-gate-lib.sh:_expand_plan_files | parser-limit | Parenthetical annotations containing commas (136 real occurrences, e.g. `svc.ts (modify — line 559, ...)`) fragment the token stream. Fail-open only (never a false BLOCK). Track `()` depth like `{}`. | seen:1 | confidence:75 | source:test-audit | 2026-07-22
- [DONE 2026-08-17] gate-6 [MOVED TO DOCS 2026-08-17 — docs/pipeline.md 'Accepted invariants'. Not a defect and never was: the entry restated what refactor-gate-lib.sh already narrates in more detail at _execute_run_live. Kept as a documented property of the gate, removed from a queue of things to do.] [TRIAGE 2026-08-16: STILL-REAL but self-described non-bug, and refactor-gate-lib.sh:740-800 now narrates the same threat model in MORE detail than this entry. RECOMMEND: delete from backlog, fold one sentence into docs/pipeline.md 'Known bypasses'.] | hooks/lib/refactor-gate-lib.sh:_execute_run_live | threat-model | Corroboration artifacts (execution-state.md, run-markers) are unauthenticated files any agent could write. Now bounded by freshness + plan-identity + repo-scoping, but not forgery-proof. This gate is a guardrail against drift, not a security boundary (ZUVO_ALLOW_ADHOC is a sanctioned escape). A non-forgeable marker (session nonce written by zuvo:execute) would need a protocol change across 5 skills. | seen:1 | confidence:60 | source:adversarial | 2026-07-22
- [DONE 2026-08-17] gate-7 [CLOSED 2026-08-17 — _ap_field's PLAIN-dialect branch was anchored to column 0 while the comment branch already tolerated leading whitespace, so `  status: pending` matched neither and fail-opened. Anchor relaxed to ^[[:space:]]*. Probed: indented dialect went from [] to [in-progress]; tabbed form covered too.] [TRIAGE 2026-08-16: STILL-REAL — _ap_field's plain-dialect regex is ^$2: with no leading-whitespace tolerance while the comment-dialect branch allows it.] | hooks/lib/refactor-gate-lib.sh:_ap_field | parser-limit | An indented `  status: pending` matches neither dialect (anchored to line start) and fail-opens. Third real-world variant of the dialect class. | seen:1 | confidence:65 | source:cq-audit | 2026-07-22
- [DONE 2026-08-17] gate-8 [CLOSED 2026-08-17 — but NOT by extracting a fifth copy, which is what the entry proposed. tests/lib/human-env.sh DERIVES the var list from pg_is_agent_env + _is_agent_env, so a variable added to either detector is unset by every gate test automatically and a fixture/library mismatch stops being a state that can exist. That matters because the copies had NOT drifted from each other — the LIBRARIES drifted (B-gate-2, a live pre-push bypass), and a frozen fixture cannot notice that: it keeps unsetting the old set while every test keeps passing. Derived list verified byte-identical to the literal one (15 vars) before swapping. Probed both ways: a new library var appears in the fixture with no test edit, and unreadable libs fall back to the literal set with a loud warning rather than to an empty env that would make every human-bypass assertion pass for the wrong reason. Count corrected: FOUR files, not three.] [TRIAGE 2026-08-16: WORSE THAN FILED — the 15-var HUMAN fixture is now copy-pasted in FOUR test files (was 3), still with no programmatic guard. NB the drift guard added in 6d114f2 covers the LIBRARY lists, not these fixtures.] | tests/hooks/*.sh | maintenance | The 15-var HUMAN fixture array is copy-pasted in 3 test files. Drift guard exists only in test-plan-execute-gate.sh. Factor into a shared fixture. | seen:1 | confidence:70 | source:test-audit | 2026-07-22
- [DONE 2026-08-17] gate-9 [CLOSED 748f013 — heredoc bodies stripped before tokenizing, only when the delimiter actually closes; 6 regressions, probed against the pre-fix hook (exactly the 2 defect cases fail there).] [TRIAGE 2026-08-16: REPRODUCED, and NARROWER than filed. Probed through the real interface (JSON on stdin, .tool_input.command) with controls: real --no-verify blocks (rc2, correct), plain commit passes, `-n` inside a QUOTED -m message passes (already handled by quote-aware tokenization — the entry blamed this wrongly), `-n` inside a HEREDOC body with -F - BLOCKS a legitimate commit. Only the heredoc half is the defect.] | hooks/block-no-verify.sh | false-positive | Skanuje CAŁĄ komendę, więc `-n` wewnątrz TREŚCI wiadomości commita (`git commit -F -` z heredoc zawierającym `tail -n 100`) czyta jako flagę --no-verify i blokuje legalny commit. Powtórzone 2x dzisiaj. Powinien parsować tylko argumenty git, nie treść heredoc/-F. | seen:1 | confidence:95 | source:build | 2026-07-22

- [DONE 2026-08-17] lock-toctou [MOVED TO DOCS 2026-08-17 — docs/pipeline.md 'Accepted invariants'. The entry itself said it is not fixable without breaking mutual exclusion against append-retro. Pure record-keeping with no action attached; it belongs beside the lock it describes, not in a backlog.] [TRIAGE 2026-08-16: unchanged, and the entry itself says NOT fixable without breaking mutual exclusion. RECOMMEND: move to a known-limitations note beside the .retro.lock.d docs; it is pure record-keeping with no action attached.] | scripts/zuvo-home/sanitize-retros:acquire_lock/release_lock | accepted-invariant | Dir-lock (mkdir) has a theoretical TOCTOU between stale-check and break, and between ownership-check and rmdir. Same limitation as append-retro/rotate-retros/backlog fleet-wide. Mitigated by pid-liveness + atomic mkdir + ms critical section. NOT fixable with flock without breaking mutual exclusion against append-retro (must share the SAME dir-lock). Documented invariant, not a live defect. | seen:1 | confidence:30 | source:adversarial | 2026-07-26

- B-polyglot-docstring [TRIAGE 2026-08-16: STILL-REAL — ast.get_docstring() empirically returns the exec shim for all 8 files; no __doc__ consumer exists anywhere, so still inert.] | scripts/zuvo-home/{backlog-collect,runlog-collect,backlog-consolidate,profile-session,retro-mine}.py + compute-preload, digest-proposals, sanitize-retros, verify-audit | latent-trap | The polyglot `''''exec ...'''` header becomes the module's FIRST statement, so it silently becomes `__doc__` and detaches the real docstring one line below. Inert today — a repo-wide grep found no `__doc__` / `argparse(description=__doc__)` consumer — but `scripts/zuvo-home/backlog` DID get the compensating fix and these 8 did not. Recipe: apply the `USAGE = """..."""` + `sys.exit(USAGE)` pattern from scripts/zuvo-home/backlog:195, or add a one-line comment noting the trade-off, so a future `--help` does not print the exec shim. defer-reason: NIT | seen:1 | confidence:80 | source:review | 2026-07-30
- [DONE 2026-08-17] dispatched-count-dup [CLOSED 2026-08-17 — extracted `dispatched_count()` beside suspended_seconds(); both call sites (now :2395 and :2517, drifted from the recorded 2057/2179) use it. Never a correctness bug — the two branches are mutually exclusive — but it was the one leftover from the change that extracted adversarial_log_row / preserve_failure_evidence / suspended_seconds for exactly this reason. bats suite green.] [TRIAGE 2026-08-16: STILL-REAL, lines drifted 2057/2179 -> 2388/2510.] | scripts/adversarial-review.sh:2057,2179 | duplication | `DISPATCHED_COUNT=$(echo "$DISPATCHED_LIST" | wc -w | tr -d ' ')` appears byte-identically in the all-failed branch and the success-path status derivation. Mutually exclusive at runtime, so not a correctness issue — but inconsistent with the rest of the same change, which extracted `adversarial_log_row` / `preserve_failure_evidence` / `suspended_seconds` specifically to kill duplication. Recipe: extract `dispatched_count()` next to `suspended_seconds()`. defer-reason: NIT | seen:1 | confidence:30 | source:review | 2026-07-30

## B-REFGUARD — DONE
**Closed:** 2026-08-18. The suite now builds its fixture in a SANDBOX: a copy of the repo in
`mktemp -d` (excluding .git/dist/zuvo, ~14 MB, ~1 s), validated via `validate-skills.sh --root`,
which already existed. The fixture never touches the real tree.
**The earlier "accepted, do not re-raise" disposition was wrong on both of its claims.** It said the
failure mode is "a false FAIL, never a deletion" — but the fixture ESCAPED THE REPO through
install.sh into the plugin cache under two versions at once. And it said a copied tree "would
forfeit exactly the real-repo coverage (D) exists to provide" — it does not: the sandbox IS this
repo's content, so (D) still validates every real skill and include. What is given up is only that
the validator runs at the literal repo path, which no assertion depends on.
**Proven:** 40 polls across a full run found the fixture in `skills/` zero times, dir count stayed
57, and two CONCURRENT runs both PASS (the ~4-min stall case).
**Backstop for debris from any other source:** `install.sh` refuses to run when `skills/tmp-*`
exists. Deliberately ONE check before any build rather than a filter in each of the five copy
loops — a guard repeated five times is five places to forget the sixth path. Verified: exits 1
naming the directory, and installs normally once removed. Asserted in
tests/hooks/test-install-copy-verification.sh (backstop exists, precedes the first copy, and does
not fire on a clean tree).
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

## B-ADV-TRUNC — DONE
**Closed:** 2026-08-18. Recipe part 2 (chunk instead of drop) had already landed and removes most
of the exposure — truncation now only happens where there is nothing to split on (`--mode tests`,
a single file over the cap, chunking disabled). Part 1 is now done too, twice over:
- **exit 4** — review completed but does NOT cover the whole change. Documented in the script
  header and in `adversarial-loop.md`'s exit table, with an explicit warning that 4 is the code
  that *looks* like success. Verified it propagates through chunk aggregation as well.
- **`pg_artifact_proven` refuses `input_truncated=true`** — the defence that does not depend on any
  call-site having checked the code. `REVIEW BY:` markers attest that providers RAN, not that they
  saw the whole change; counting markers alone granted full coverage to the 2026-07-31 review that
  omitted the patch's largest file.
**The bats suite was pinning the bug.** `truncates code-mode input exceeding 30000 chars` asserted
`status -eq 0` — a green test guaranteeing the exact behaviour that made a partial review look
complete. Changed to 4 with the reason written next to it, so it reads as a contract change rather
than a broken test.
**Test:** tests/hooks/test-adversarial-truncation.sh, 11 assertions — including that a normal-sized
review still exits 0 (otherwise the whole fleet would start returning 4) and that the partial
review's findings are still delivered (4 means incomplete, not failed).
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

## B-SHELLCHECK — DONE
**Closed:** 2026-08-18. The blocker in this entry ("shellcheck is not installed on this machine")
no longer holds — 0.11.0 is on PATH — so the rules land with a gate that actually runs locally.
- `.shellcheckrc` added, with a written reason per disable. The disables are IDIOMS THIS REPO USES
  DELIBERATELY (SC2015 `a && b || c` in test harnesses ~983 hits, SC2016 single-quoted `$` in awk
  programs, SC2181 `rc=$?` after capturing output / branching on specific codes, SC2012, SC1090/1091
  runtime-resolved sources, SC2088 literal `~/` in user-facing messages). 1702 findings → 226.
- **3 real errors fixed** — two comment lines whose first word was the linter's name, which
  shellcheck parses as a DIRECTIVE and hard-fails on (SC1073, stopping analysis of the rest of the
  file), and `"$pat[[:space:]]"` read as an array subscript (SC1087). I wrote the same
  first-word-directive bug into my own fix comment and the gate caught it immediately.
- `tests/hooks/test-shellcheck.sh`: errors gated at HARD ZERO; warnings RATCHETED at 102, the number
  written in the open at the top of the file rather than hidden in a baseline. A ratchet is the only
  honest way to adopt a linter on 273 existing files — fixing 102 warnings in one untested diff is
  worse than stopping the debt growing while it is paid down. Loud SKIP when shellcheck is absent.
- **Corpus selection was the subtle part:** keying on the shebang alone pulls in the POLYGLOT
  sh/python helpers in scripts/zuvo-home/ (`#!/bin/sh`, re-exec python3 on line 8). shellcheck then
  lints Python as shell and reports 52 "errors", every one false — and enough noise to make the 3
  real ones invisible. Documented in the test and in docs/runbook/testing.md.
- Mutation-probed: reintroducing the SC1087 fails the error gate; adding one unquoted-expansion
  script fails the ratchet.
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

## B-UPSERT-AWK-LEN — CLOSED as ACCEPTED (not fixed, deliberately)
**Disposition:** 2026-08-18. This entry documents its own verdict: an embedded AWK program is a DSL
block rather than sprawling bash control flow, both branches are individually commented, the
overlap falls ~15 lines short of the CQ14 repeated-block threshold, and **no correctness issue was
found**. It has sat at confidence 70 with defer-reason NIT and seen:1 since 2026-07-31.
**Closing it rather than leaving it open is the point.** A queue of things nobody intends to do is
where a real item goes to hide — B-gate-2, a LIVE pre-push bypass, was buried under exactly this
kind of entry for weeks. The fix direction (lift the AWK into a heredoc constant, collapse the two
branches into one parameterised write path) is recorded in the file itself as a comment for whoever
next grows it; it does not need a backlog slot to stay true.
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

## B-ORIGIN-TOCTOU — DONE
**Closed:** 2026-08-18, and mostly by work that had already landed. The wording the entry attacks
("LOCAL means it actually resolves to a local destination", a check-time answer stated as a durable
property) is gone: `live-validation.md` now opens with "LOCAL is a destination, not a name",
carries an explicit **"Resolution is a pre-flight heuristic, not a guarantee (TOCTOU)"** paragraph,
names DNS rebinding, requires re-classification on EVERY navigation and per redirect hop, and
forbids reusing a cached verdict (commits b67766e, 327cff3). The enforcing layer is request-level:
E2E-Q4's allowed-host list, a critical gate, inspects every real request including redirects and
background calls.
**What this session added — the one thing still overstated.** Request-level enforcement matches
`url.hostname`, i.e. NAMES, not addresses. It closes "the run walked off to a host nobody
authorized" (the case that happens) and not "an authorized name resolved somewhere new". Claiming
otherwise would repeat, one layer down, exactly the error the section is about. Documented, along
with the pinning tool that DOES exist — Chromium's `--host-resolver-rules="MAP <host> <ip>"` — and
why it is not the default: it defeats load-balanced/multi-A-record hosts, diverges from how the app
is really reached, and a wrong pin looks like an outage.
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
- [DONE 2026-08-17] envcompat-platform-list [CLOSED 2026-08-17 — 15 SKILL.md blurbs + docs/configuration.md:45 fixed. SKILL.md now says 'across all supported platforms' rather than enumerating, so platform six cannot re-drift it; configuration.md keeps the explicit list since it is a reference table. The 10 occurrences under docs/specs/ were LEFT — dated April specs are point-in-time records and rewriting them would falsify the record.] [TRIAGE 2026-08-16: WORSE — recount confirms 16 sites (15 SKILL.md + docs/configuration.md:45), but env-compat.md now documents FIVE platforms after Kimi landed (ac0070d), so the stale phrase is missing two, not one.] | docs/configuration.md:45 + 15 SKILL.md env-compat blurbs | doc-drift | 15 sites describe env-compat.md as "Claude Code, Codex, and Cursor" while it documents 4 platforms (Antigravity missing). Mechanical sweep or replace with "all supported platforms" so the 15x copy-paste can't drift again. defer-reason: below-threshold(38) | seen:1 | confidence:38 | source:review | 2026-08-01
- B-content-expand-schema | shared/includes/article-output-schema.md + skills/content-expand/SKILL.md | contract-gap | article-output-schema hardcodes skill:"write-article" and lacks content-expand's before/after scores, changes[], voice_delta; content-expand:269 still writes "per article-output-schema.md". Recipe: generalize the skill field, add an optional content-expand object, wire Phase 5 emission — or restore a dedicated schema updated to CURRENT flags (--dry-run/--skip-research, not the deleted --apply/skip_benchmark draft). defer-reason: structural-refactor (multi-file) | seen:1 | confidence:58 | source:review | 2026-08-01
- B-reviewer-missing-include-guard | skills/{plan/agents/plan-reviewer,write-tests/agents/test-quality-reviewer,execute/agents/quality-reviewer,write-article/agents/anti-slop-reviewer}.md | resilience | Reviewer agents mandate include reads but define no missing-file behavior; an LLM agent proceeds and reviews against hallucinated criteria. Recipe: one line each — "If any required include is missing, stop and report [BLOCKED] missing <path> instead of reviewing." defer-reason: below-threshold(38) | seen:1 | confidence:38 | source:review | 2026-08-01
- B-writetests-phase1-skip-marker | skills/write-tests/SKILL.md:122 | ambiguity | Phase 1 table row for test-code-types-core.md says Full with no marker while Phase 0.5 note says its read IS that load; also no missing-file rule for the Phase 0.5 classification read (classify-from-memory is forbidden but undefined on missing file). Recipe: mark row "Full (loaded @ Phase 0.5 — do not re-read)" + extend the include-integrity STOP rule to the 0.5 read. defer-reason: below-threshold(42) | seen:1 | confidence:42 | source:review | 2026-08-01
- [DONE 2026-08-17] validator-placeholder-prefix [CLOSED 2026-08-17 — the STATIC prefix before a placeholder is now stat-ed as a directory. Only two placeholder includes exist in the tree (both …/banned-vocabulary/languages/<resolved-lang>.md, at ../../ and ../../../ depth), and a typo in that prefix was exactly as fatal and exactly as silent as a dangling include: the skill resolves nothing at runtime and degrades without a word. Probed by misspelling `languages` -> `langauges`: caught, with the offending path named.] [TRIAGE 2026-08-16: STILL-REAL, line drifted 232 -> 284.] | scripts/validate-skills.sh:232 | enhancement | Placeholder include paths (<resolved-lang>.md, {stack}.md) deliberately unmatched; a typo in the STATIC prefix before the placeholder is never linted. Recipe: match up to first < or { and verify the directory exists. defer-reason: NIT | seen:1 | confidence:32 | source:review | 2026-08-01
- [DONE 2026-08-17] codex-registry-note [CLOSED 2026-08-17 — header now states the file is DESCRIPTIVE and that build-codex-skills.sh does not read it (it enumerates skills/*/agents/*.md directly). docs/configuration.md already said this from the other side; the asymmetry was that a reader holding a file called a 'manifest' reasonably assumes it is an input.] | shared/includes/codex-agent-registry.md:1 | doc-asymmetry | docs/configuration.md now says the build script does NOT read this manifest, but the file itself doesn't carry that warning; an editor may expect TOML output to change. Recipe: one header line "Descriptive manifest — build-codex-skills.sh does NOT read this file; keep in sync by hand." defer-reason: below-threshold(30) | seen:1 | confidence:30 | source:review | 2026-08-01
- B-gate-cq41-cq42 | shared/includes/gate-registry.md | gate-addition | Two approved-by-audit gate additions deferred because they change the family size ("CQ1-CQ40" appears in banners/manifests/website): CQ41 = public-token endpoint security extracted from CQ4's second half (conditional critical; CQ4 keeps tenant scoping only), CQ42 = comment/doc truthfulness (comments state facts the code implements; proven twice this week). Recipe: add both rows, regen, sweep CQ1-CQ40 prose mentions (grep 'CQ1-CQ40'), bump using-zuvo banner + plugin descriptions + website. defer-reason: structural-refactor (multi-file) | seen:1 | confidence:75 | source:gate-audit | 2026-08-01
- B-cap30-js-family | shared/includes/gate-registry.md + rules/typescript.md | gate-addition | CAP30+ JS/TS detector-backed subfamily mirroring CAP20-29's ruff pattern, keyed to the fleet's canonical Biome config (noFocusedTests already covered by AP31; add noFloatingPromises, noDelete, noThenProperty escalations, naive new Date(string) TZ math, bare JSON.parse). Needs rule curation against ~/DEV/uptime/biome.json. defer-reason: structural-refactor (multi-file) | seen:1 | confidence:60 | source:gate-audit | 2026-08-01
- B-e2eq11-diagnostics | skills/write-e2e/references/quality-gates.md | gate-addition | E2E-Q11 candidate: failure diagnostics configured (trace/screenshot/video-on-failure in playwright config; auto-fixable Yes). Changes the "ten gates"/10-of-10 wording in the reference + SKILL. defer-reason: structural-refactor (multi-file) | seen:1 | confidence:55 | source:gate-audit | 2026-08-01
- B-express-astro-depth | rules/express.md + rules/astro.md | content-growth | Express got E5 semantics + 3 concrete patterns and Astro got an Actions section (2026-08-01), but both remain thin vs fleet weight: express lacks helmet/CSRF middleware examples and rate-limit wiring; astro is security-only under a "Conventions" title (no component/content-collection/hydration conventions, no Astro 5 Server Islands). defer-reason: NIT | seen:1 | confidence:50 | source:rules-audit | 2026-08-01
- B-cq38-js-resources | shared/includes/gate-registry.md | gate-wording | Node/TS resource release beyond listeners/timers (fs handles, undici bodies, manually acquired pool clients) sits between CQ22 and CQ38's stack scope — extend CQ22 with a JS clause or add js to CQ38's scope with carve-outs. defer-reason: NIT | seen:1 | confidence:45 | source:gate-audit | 2026-08-01
- [DONE 2026-08-17] website-gate-counts [CLOSED 2026-08-17 — and the drift was FAR wider than this entry recorded: not 2 files but ELEVEN (build, execute, debug, review, write-tests, refactor, architecture, tests-performance, _schema, test-audit, code-audit), 99 stale range references in total. The entry named only the two a human noticed. Root cause of the invisibility fixed too: tests/gates/test-gate-consistency.sh scanned --include='*.md' over rules/shared/docs/skills/README/CLAUDE and never looked at website/ or at *.yaml at all. Both added; probed by reverting one range and confirming the guard names the exact lines.] [TRIAGE 2026-08-16: STILL-REAL, numbers reconfirmed against gen-gate-copies.py (live CQ=40 Q=25 CAP=29 AP=32 vs website Q1-Q17/AP1-AP26/CQ1-CQ29).] | website/skills/test-audit.yaml + code-audit.yaml | doc-drift | Website YAMLs predate two gate expansions: test-audit says "AP1-AP26"/"17 quality gates and 26 anti-patterns", code-audit says "CQ1-CQ29" — live counts are AP1-AP32 / Q1-Q25 / CQ1-CQ40. Pre-existing (months), surfaced by the a3b0068..HEAD review sweep. Recipe: sync counts, and consider adding website/skills/*.yaml to test-gate-consistency's stale-range sweep (also extend it to prose counts "N anti-patterns" — the guard only matches range patterns, which is how "30 anti-patterns" slipped). defer-reason: NIT | seen:1 | confidence:85 | source:review | 2026-08-01
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
- B-skillmd-size-policy [TRIAGE 2026-08-16: still an open DECISION, and the number grew — execute/SKILL.md 1501 -> 1539L.] | skills/*/SKILL.md (execute is 1501L, +259 this range) | policy | NO rule is being violated — `rules/file-limits.md` is explicitly TS/NestJS/React-calibrated and does not govern markdown SKILL.md files, and the only per-file bound in the repo is write-e2e's bespoke body-line test. So there is nothing to fix, only something to DECIDE: either give validate-skills a generous SKILL.md ceiling with a documented rationale, or state in file-limits.md/CLAUDE.md that SKILL.md files are exempt by design. defer-reason: repo-wide policy decision for the maintainer, genuinely outside this diff's fence | seen:1 | confidence:75 | source:review-struct | 2026-08-03
- B-retro-stub-t64-flaky [TRIAGE 2026-08-16: CANNOT-VERIFY, and the recorded ROOT CAUSE does not match the code — the test already parameterizes ZUVO_HOME to a fresh mktemp -d and retro-stub derives every stateful path from it, so 'leftover markers under ~/.zuvo/run-markers' cannot be the mechanism. 5 consecutive clean runs. Treat a future look as re-diagnosis, NOT apply-the-recipe-as-written.] | tests/adversarial/test-session-retro-carry.sh :: T6.4 | flaky-test | "no new stub added (full retro supersedes — idempotent)" fails intermittently: observed RED mid-review, and RED at the BASE commit 50eeeaf when run against an extracted base tree, then GREEN on a later run of the same unchanged file. So it is state-dependent (leftover markers under ~/.zuvo/run-markers), not a regression from this range — this range touched only the BASE line-budget constant in that file, and `scripts/zuvo-home/retro-stub` (the code under test) is not in 50eeeaf..23a207a at all. Recipe: make the case hermetic w.r.t. $ZUVO_HOME rather than reading the real one. defer-reason: pre-existing debt, out of fence — belongs to whatever last touched retro-stub | seen:2 | confidence:80 | source:review-cq, refactor | 2026-08-03 | re-seen 2026-10-05 (zuvo:refactor dedc3165, found_while_verifying OUT-1): RED at base 634bad5a in a clean worktree, together with tests/adversarial/test-retro-stub.sh T3.3 — reproducible there, not intermittent. Hypothesis recorded then: retro-stub computes the SHA7 in a different cwd than the one the test seeds. Re-diagnose from that, not from the ~/.zuvo/run-markers recipe above.
- [DONE 2026-08-17] devpush-marketplace-dirty-tree [CLOSED 2026-08-17 — EXIT/INT/TERM trap added around the Step-0b rewrite, disarmed the moment Step 4 commits (before the push, so a failed push cannot roll a committed count back out of the tree). Bounded twice so an irreversible `git checkout --` is safe: it fires only if THIS run rewrote, and only if the marketplace tree was clean beforehand — a user with pre-existing local marketplace edits gets a warning and no restore, because destroying their work to tidy ours would be a worse bug than the one being fixed. Simulated both paths: clean tree -> 2 dirty files -> 0 after the trap; dirty tree -> untouched, user edit intact. The sub-issues this entry also listed (orphaned mkstemp, no rollback on the second file) were already mitigated by 07df2a2's stage-then-commit design, so only the primary CRITICAL remained.] [TRIAGE 2026-08-16: core defect UNCHANGED (Step 0b still rewrites the sibling marketplace tree without committing; no trap anywhere in the script; the failure message at :299 still says 'Step 4 commits it'). The sub-issues it lists (orphaned mkstemp, no rollback on the second file) WERE mitigated by 07df2a2's stage-then-commit design. So: still MUST-FIX, but narrower than filed.] | scripts/dev-push.sh Step 0b (~55-97) vs Step 4 | crash-safety | FOUR providers independently (codex, cursor, kimi, claude — kimi and claude rated it CRITICAL). Step 0b rewrites the SIBLING marketplace working tree but does not commit it; the commit lands only at Step 4. Any failure or interrupt in Steps 1-3 leaves the marketplace repo dirty, and the next run's mandatory `git pull --rebase` then fails on a dirty tree — a trap that needs manual recovery in a repo the user was told is self-healing. Related, same area: an orphaned `.zuvo-count-*` mkstemp file after a kill, and no rollback if `os.replace` fails on the second of two staged files. Recipe: either commit the count fix immediately in Step 0b as its own commit, or register a trap that restores the marketplace tree on any non-zero exit before Step 4. defer-reason: NOT localized — changing where the marketplace commit happens reorders dev-push's push/rollback contract and needs its own RED test against the 32-assertion gate suite; that is a scoped change, not a review-loop edit | seen:1 | confidence:90 | source:review-adversarial | 2026-08-03

## B-CQ40-METALINTER — DONE (all three recipe steps)
**Closed:** 2026-08-18. ruff, mypy and shellcheck are all installed now, so the rules land with
gates that run locally rather than speaking only through CI.
1. **`pyproject.toml`** with `[tool.ruff]` + `[tool.mypy]`. `line-length = 110` was chosen FROM THE
   CODE (p50 40 chars, p90 91, p99 108): the default 88 flags 565 lines, almost all prose-width
   comments this repo uses deliberately — and a rule nobody will ever action trains people to
   ignore the linter. Ignores are per-rule with reasons: E701/E702 (compact parse loops), E402
   (FORCED by the polyglot sh/python re-exec line preceding every import), SIM115, E741,
   and mypy's `var-annotated` (7 of 9 first-run errors were "annotate this empty list", which
   restates the next three lines).
2. **`.shellcheckrc`** + the shell gate — done in the same session, see B-SHELLCHECK.
3. **Wired as optional-tool checks** — `tests/hooks/test-python-lint.sh` and
   `tests/hooks/test-shellcheck.sh`, both SKIP-if-absent, both auto-discovered by run-all.
**ruff: 713 → 46** (config + 20 safe autofixes: unused imports, one-line import groups, f-strings
without placeholders). Ratcheted at 46. **mypy: HARD ZERO** — it earned that by finding a real one
on its first run: `retro-mine.py` bound the name `backlogs` to 6-tuples and then rebound it to
5-tuples, which ran correctly and read as a bug at the unpack 20 lines later. Renamed to
`backlog_rows`; that rename then exposed a SECOND thing — the final summary `print` still counted
the unmerged list and would have contradicted the table right above it. Both fixed, and the run's
output diffed byte-identical against HEAD.
**Corpus selection matters here too:** the extensionless POLYGLOT helpers in scripts/zuvo-home/ are
most of this repo's Python and a `*.py` glob misses them. mypy is scoped to `*.py` (it resolves
module names from paths and cannot handle the polyglots) — a tooling limit, not a reason to skip
what it can check.
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

## B-PATH-CONTAIN-SHARED-FN — DONE (all four recipe steps)
**Closed:** 2026-08-18. `hooks/lib/path-contain.sh` exports `path_contained <root> <ref>` and all
three call sites use it — pg_artifact_proven, lint_artifact, do_sync. The inline `case` blocks are
gone (asserted, not assumed: the test counts them and fails if one returns).
- Lives in `hooks/lib/` rather than `scripts/lib/` because pipeline-gate-lib.sh is installed to
  `~/.claude/hooks/lib/` and resolves siblings by `dirname`. install.sh copies it next to
  review-artifact-sync.sh in the codex and cursor trees too, and `verify_copied` now checks it —
  so a failed copy is loud instead of turning up later as a refused sync.
- **A missing helper REJECTS.** pipeline-gate-lib.sh is fail-open by design, but not about
  containment, where failing open means accepting the traversal. review-artifact-sync.sh exits 2.
  Both probed: unset `path_contained` → rejected; delete the installed file → sync refuses (rc=2).
- **Step 4 done: the check is CANONICAL, not just lexical.** A symlinked directory walks out of the
  repo with no `..` anywhere in the path, so the two `case` blocks could not see it. Only applied
  when the target EXISTS — which is the only time it is read or copied, so a not-yet-synced proof
  still falls back to the lexical verdict instead of being rejected for absence. Canonicalization
  is realpath → python3 → `cd`+`pwd -P`, because `realpath` is not universal and `readlink -f` is
  GNU-only.
- **Step 3 done, and it mattered:** the test carried its own `contained()` "extracted verbatim in
  shape from the lib" — a FOURTH copy. A copy cannot catch the rule drifting, which is precisely
  how d568825's miss stayed green. It now sources the real function, keeps the end-to-end do_sync
  case (sourcing proves the FUNCTION, only the script proves the CALL SITE), and adds an assertion
  that both production files call `path_contained`.
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

## B-INSTALL-CLAUDE-MANIFEST — RESOLVED 2026-08-04 (install.sh + test-install-wiring.sh case 9)
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

RESOLUTION: steps 1 and 2 done. Step 3 answered: Cursor and Antigravity load from
skills directories and carry no plugin manifest, so there is nothing to sync there —
only Claude (was missing, now fixed) and Codex (already had it) have one. Measured
after the fix: both cache dirs report 1.6.55 / 57 skills, matching package.json.

## B-INSTALL-COPY-IDIOM — DONE
**Closed:** 2026-08-18. `cp_warn <label> <cp-args…>` replaces all TEN swallowing copies in
install_claude()'s cache loop (the entry counted 8; there were 10).
**The swallow was the point, not the duplication.** `cp … 2>/dev/null || true` is the mechanism
that let the Claude plugin manifest go stale for ~40 releases with no signal.
**`|| true` semantics are PRESERVED:** cp_warn always returns 0, so a failed copy does not abort
the remaining cache dirs or the other four hosts. What changed is that it stops being invisible.
**An unmatched glob is not a failure** — same rule as verify_copied.
**Proven live:** deleting the cache's rules/*.md and chmod a-w on the directory produced
`WARN: rules — copy FAILED` plus the summary line; a clean install stays silent at exit 0. The
first probe attempt was wrong — chmod alone does not stop `cp` overwriting EXISTING files.
**Test:** assertions 22-28 of tests/hooks/test-install-copy-verification.sh. One subtlety pinned in
both helper and test: `x=$(cp_warn …)` runs it in a SUBSHELL, so the counter increments there and
the summary reports 0 — every call site must be a plain statement.
Surfaced by: zuvo:review of 17fa746..1313b59 (2026-08-04), CQ-4 + confirmed by 2 adversarial providers.
`install_claude()` repeats the same shape eight times inside its `for CACHE_DIR` loop
(scripts/install.sh:253, 264, 272, 283, 303, 309, 317, 323): `cp ... 2>/dev/null || true`.
CQ14(b) is met literally (same structural pattern 5+ times). More importantly the swallow IS the
mechanism that let the Claude manifest go stale for ~40 releases with no signal — install.sh
prints OK whether or not any given copy happened.
The manifest copy (the one this range added) was fixed to WARN; the other seven were left.
Recipe: extract `copy_if_exists <src> <dst> <label>` that does the guard + copy + a WARN on
failure, then replace all eight call sites with it. That fixes the duplication and the silent
swallow in one place instead of eight.
defer-reason: pre-existing (7 of the 8 predate this range) + it rewrites the copy path of a
release-critical installer, which wants its own RED test against test-install-wiring.sh rather
than a review-loop edit. | seen:1 | confidence:85 | source:review-cq | 2026-08-04

## B-RETRO-GATE-THIRD-STATE — two skills behave exempt from the retro gate without being listed
Surfaced by: audit of the 17 never-deep-read skills (2026-08-06).
`~/.zuvo/append-runlog` line 185 hard-codes the exemption by skill name:
`using-zuvo|backlog|benchmark|agent-benchmark|deploy|canary|worktree`. `retro` and
`skill-eval` are NOT on it, yet neither loads `retrospective.md` and neither calls
`append-runlog` — they append directly, which `run-logger.md` permits only by implication
("For any skill that LOADS retrospective.md, do NOT append directly"). So there is an
undocumented third state: not exempt, not full-retro. It works today and fails hard the
moment either skill is routed through the wrapper — `RETRO_REQUIRED`, exit 2, runs.log not
written, with nothing in the skill explaining why.
Defer-reason: NOT size — this is a contract decision about which skills owe a retro, and it
changes the behaviour of a shared gate. Picking an answer unilaterally (adding two names to
an exemption list) while a parallel session is active in this checkout is how the drift
these gates exist to prevent gets introduced.
Recipe:
  1. Decide the contract: does a skill that produces no code owe a retro? `retro` mines
     retros and `skill-eval` writes a checkpoint stub (`zuvo:retro-marker`), so both already
     participate in the loop differently from the 7 exempt ones.
  2. Whichever way it goes, make it ONE list: the helper's `case` and run-logger.md's prose
     must be generated from or checked against each other — today they are two hand-kept
     copies that already disagree by two entries.
  3. Add a test asserting every skills/*/SKILL.md either loads retrospective.md, or appears
     in the exemption list. That check is what would have caught this.

## B-BATS-GROUP-ROTTED — 4 .bats suites broken since ~v1.3.83, hidden by an optional-tool skip **[DONE 2026-08-11, commit 6811a6a — all four green, 26 tests repaired]**
> Closing note: the diagnosis here was right about the trap and slightly off about the cause.
> `reviewer-model-route` was not an output-shape divergence — the tests inherited the AMBIENT
> host markers (`CLAUDECODE=1`), so they asserted `platform=codex` while the harness forced
> `platform=claude`. Same class in `blind-audit-codex` (its claude case was unpassable from
> inside Claude Code) and in `isolated_path()`, which appended `/opt/homebrew/bin` where the
> REAL codex lives. Repairing them surfaced a genuine defect: `gpt-5.6-sol`
> (ZUVO_MODEL_CODEX_PRIMARY) was missing from the router table, so the default Codex model
> fell back to same-model review of its own work.
Surfaced 2026-08-10 when `bats` (1.14.0) appeared on PATH and `tests/run-all.sh` stopped
printing `SKIP: scripts/tests/*.bats (bats not installed — group skipped)`.
Failing: adversarial-review.bats, blind-audit-codex.bats, reviewer-model-builds.bats,
reviewer-model-route.bats. reviewer-model-route.bats reports 5 `not ok` — the same 5 at
HEAD and at v1.6.65, so this predates the current work entirely; the file was last touched
at v1.3.83. Sample failure: `assert_line "platform=codex"` — the resolver's output shape and
the test's expectation have diverged, on both sides of every recent release.
This is the SECOND instance of the same trap: `test-install-wiring.sh` already documents
shellcheck activating latently on 2026-08-02 and turning an unchanged installer into 4 FAILs
that blocked an unrelated release. An optional-tool SKIP is not neutral — it lets a suite rot
silently and then detonates on whoever installs the tool next.
Defer-reason: NOT size — the fix needs a decision about whether the resolver or the tests are
right (its output shape changed deliberately at some point), and that is separate work from
the release it is currently blocking.
Recipe:
  1. Diff `scripts/zuvo-home/reviewer-model-route` (or wherever the resolver lives) output
     against what the .bats files assert. Decide which is canonical.
  2. Fix the losing side; re-run all four suites under bats 1.14.
  3. Then close the CLASS, not just the instance: make `run-all.sh` print optional-tool skips
     into the RESULT line (e.g. `SKIP=1 (bats)`), so "green" never silently means "green
     minus a group nobody ran". A skipped group that no one can see is how both of these rotted.

## B-MODEL-ID-FANOUT — Codex model ids live in 3-4 independent tables
Surfaced 2026-08-11 by the review of origin/main..HEAD (STRUCT-1, confidence 85). `model-registry.sh`
names the lanes; `reviewer-model-route.sh` re-types the reviewer literals in its `case` arms and says
in its own header it is "intentionally NOT wired to" the registry; `build-codex-skills.sh` has a THIRD
independent hardcode (`map_model()`, `replace_reviewer_lane_refs_codex()`) plus a fourth inside its
`validate_dist` grep. Two drift instances were found in ONE range: `gpt-5.6-sol` missing from the
router (the registry's own primary self-reviewed), and `gpt-5.5` dispatched while absent from the
registry entirely. Patching arms one at a time cannot stop the next one.
Recipe: (1) resolve the router's Codex reviewer literals from `ZUVO_MODEL_CODEX_*`; (2) replace
`build-codex-skills.sh`'s `map_model()`/`replace_reviewer_lane_refs_codex()` pairings with a call into
the router or a shared sourcing of the registry; (3) once unified, `reviewer-model-builds.bats`'s
membership check becomes a true regression lock rather than a same-generation coincidence.
`structural-refactor (multi-file)`
[xv-followup-note 2026-09-25] docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md (Plan C, Technical Decisions "Out of scope"): this is exactly the `map_model` drift the plan refused to touch — evidence from that plan is that the whole Codex-dist fallback, including Plan C's own cross-vendor fallback there, maps through `map_model()` to `gpt-5.4`. Not duplicated as a new entry; recorded here per Plan C Task 9. IMPORTANT for whoever closes this entry: the Recipe above (unify `map_model()`/`replace_reviewer_lane_refs_codex()` into the router or a shared registry sourcing) is a structural fix for the DRIFT — it does NOT, by itself, cover or re-decide the specific `sonnet`→`gpt-5.4` Codex-dist fallback mapping. Unifying the lookup can carry that same `gpt-5.4` value forward unchanged; do not treat closing this entry as having reviewed or fixed that fallback value — it needs its own explicit decision.

## B-INSTALL-WIRING-BEHAVIORAL — checks (10)/(10b) assert on install.sh's source text, not its behaviour
Surfaced 2026-08-11 (STRUCT-4, confidence 60). Check (9) in the same file carries the documented lesson
("PLACEMENT is the property, not 'does cp work'") and uses awk do/done depth tracking; (10)/(10b) are
plain greps and only prove `AG_SKILLS` is ASSIGNED the right value, not that the `cp -r` loop uses it.
Unlike (9)'s live-cache case, a temp-`$HOME` invocation here would NOT pass vacuously, so the
behavioural option is available and unused.
Recipe: (1) source install.sh (already done for check (2)), export `HOME="$TMP"`, invoke
`install_antigravity`; (2) assert files land in `$TMP/.gemini/config/skills/<name>/` and that
`$TMP/.gemini/antigravity/skills/` is absent afterwards; (3) keep (10c) as a source-grep — it targets a
`sed` rewrite pattern, where text is the correct layer.

## B-REVIEW-INCOMPLETE-2026-08-11 — self-review of origin/main..HEAD could not complete its mandated gates **[CLOSED 2026-08-12 — superseded, not resolved]**
> My review stayed INCOMPLETE and I never wrote a coverage artifact — that part was correct and
> stands. What I got wrong was the consequence: I said "the push stays blocked". It did not. A
> DIFFERENT agent ran a complete self-review of d143e71..c2a7723 — a range that contains all four
> of my commits — with a real proof (zuvo/proofs/d143e71..f5afce4-adversarial.txt, 953 lines, 19
> REVIEW BY markers across 5 providers). That artifact legitimately unblocked the push, and v1.6.68
> shipped with my two CRITICAL fixes in it. So the work IS covered; it is simply not covered by ME.
> Worth keeping as a record: on a repo with concurrent agents, "my gate failed" does not imply "the
> change is ungated" — check for an overlapping artifact before asserting a block.
2 of 3 TIER-3 audit sub-agents stalled (600s watchdog, no recovery) and the re-dispatched anti-tautology
auditor died on the session token limit (resets 06:00 Europe/Warsaw). On SELF-REVIEW the skill allows NO
degraded path for sub-agents, so the verdict is INCOMPLETE and NO content-keyed coverage artifact was
written — the push stays blocked, which is the correct outcome rather than a convenience.
What DID run and hold: all mandatory CodeSift calls; the Structure Auditor (5 findings); adversarial
`--multi` across 4 providers x 3 chunks (kimi empty), which found and got fixed 2 CRITICALs.
Re-run after 06:00: `/zuvo:review origin/main..HEAD`.
[xv-followup-note 2026-09-25] docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md (Plan C, Technical Decisions "Out of scope"): this entry is the OPPOSITE symptom, not the one Plan C's follow-up refers to — here the watchdog stalls with NO recovery (correctly leaves the review INCOMPLETE); Plan C's 2026-09-25 run instead hit repeated FALSE RESUMEs while a skill was correctly waiting on a background agent. That case is tracked separately as `B-20260928-XV-WATCHDOG-FALSE-RESUME`, not here.

## B-DIST-BUILD-RACE — DONE
**Closed:** 2026-08-18. The four builders now read `DIST="${ZUVO_DIST_ROOT:-$PLUGIN_DIR/dist}/<p>"`,
`tests/lib/dist-build.sh` honours the same variable, and `reviewer-model-builds.bats` gives itself a
per-file `mktemp -d` root. Unset, the path is exactly what it was, so install.sh is untouched.
**The cache layer added earlier did NOT fix this**, though its header claimed the ground: it made
builds fast, but every one still wrote to the SAME `$ROOT/dist`, and the `rm -rf` in the bats
setup() is the collision itself. Verified by hammering the shared tree (8 build+delete cycles) in
parallel with the bats file: all 3 tests pass, where before the rm would fail with "Directory not
empty" and every test in the file went red for a reason unrelated to the code under test.
**⚠ THIS FIX DESTROYED THE REPOSITORY ONCE — read before touching the teardown.** The first cut kept
one variable and cleaned up with `rm -rf "$(dirname "$ZUVO_DIST_ROOT")"`. A mutation probe then set
`ZUVO_DIST_ROOT="$REPO_ROOT/dist"` to show the race returning — so `dirname` was the repository, and
`teardown_file` deleted the entire checkout including `.git`. Recovered from the APFS local snapshot
`com.apple.TimeMachine.2026-08-18-202058.local` (mounted read-only with `mount_apfs -s <snap>
/System/Volumes/Data`), losing nothing but a few minutes of uncommitted work.
Two rules came out of it, both now encoded in the file:
  1. **Never compute an `rm -rf` target with `dirname`** (or any walk UP from a variable). Delete
     the exact path you created, held in its own variable.
  2. **A cleanup must be able to prove what it is deleting.** `teardown_file` refuses anything not
     under `/tmp`, `/var/folders` or `$TMPDIR` and says so instead of removing it.
Surfaced 2026-08-11. `scripts/tests/reviewer-model-builds.bats` setup does `rm -rf $REPO_ROOT/dist/*`
while another agent's build writes into the same tree; the rm fails with "Directory not empty" and every
test in the file then fails for a reason unrelated to the code under test. This produced TWO wrong
conclusions in one session (a bisect that blamed an innocent registry change, and an earlier "regression"
that was not one) — both only caught by re-running in a git worktree with its own dist/.
Recipe: give the bats suite a per-run dist dir (`DIST=$(mktemp -d)` passed to the build scripts) instead
of the shared `$REPO_ROOT/dist`, so concurrent runs cannot collide.

## B-AG-SKILL-DELETE-BY-NAME — Antigravity install rm -rf's third-party skills that share a zuvo name **[DONE 2026-08-11 — marker-based ownership, tests/hooks/test-antigravity-skill-ownership.sh]**
Surfaced 2026-08-11 by the self-review of d143e71..c2a7723 (CQ auditor #6/#7 + adversarial ×2, independently).
`scripts/install.sh:1060` narrowed the old unconditional wipe to a per-name delete — a real improvement —
but it still matches purely by basename against `~/.gemini/config/skills/`, which the same commit's comment
establishes is Antigravity's SHARED customization root. Several zuvo skill names are generic words
(`review`, `docs`, `debug`, `design`, `backlog`), so a user's or another tool's same-named skill is silently
deleted on every install. Second half of the same gap: a skill zuvo renames or drops in a future release is
never pruned, because the loop only targets names present in TODAY's `$DIST/skills/*` (this repo does rename
skills — `content-optimize` → `content-expand`).
Not fixed in that range: it predates it (`b592c62`), and the fix is a behaviour change to install, not a
correction of the range under review.
Recipe: copy the pattern `install_codex()` already uses at `scripts/install.sh:738-756` — it prunes by the
`zuvo:` ownership marker it writes into every TOML and never touches the user's own agents. Write an
equivalent marker into each installed Antigravity skill dir, delete only marked dirs, and prune marked dirs
whose name is absent from the current dist (which fixes the rename leak in the same pass).

## B-LIST-PROVIDERS-UNFILTERED — the SSOT provider API hands back the host's own client
Surfaced 2026-08-11 by the self-review of d143e71..c2a7723 (CQ auditor #3).
`--list-providers` (`scripts/adversarial-review.sh:1127`) was added so client detection lives in ONE place,
but its early-exit runs `detect_providers()` raw and returns BEFORE the `EXCLUDE_PROVIDER` filter, so it
reports the host's own client as available. `reviewer-preflight.sh` does not self-review only because it
keeps a second, independently-maintained HOST_EXCLUDE block — i.e. the duplication the API was meant to
retire is what currently makes the API safe to use. Any future consumer that trusts it will self-review.
Recipe: apply host exclusion inside the `--list-providers` branch before printing, then delete
`reviewer-preflight.sh`'s HOST_EXCLUDE block so there is genuinely one implementation. Two related gaps to
close in the same pass: preflight re-validates each name with `command -v` (`scripts/reviewer-preflight.sh:150`),
which discards the `/Applications/Codex.app` fallback the API exists to surface; and its fail-safe list
(line 145) omits `cursor-agent`/`kimi`, which its own CANARY dispatcher already knows how to run.

## B-PREFLIGHT-API-PROVIDERS — `command -v` gate structurally excludes every non-binary provider
Surfaced 2026-08-11 by the behavior auditor of the d143e71..c2a7723 self-review (the third independent
finding pointing at the SAME line, after CQ #9 and the Codex.app case).
`scripts/reviewer-preflight.sh:150` gates every candidate on `command -v "$candidate"`. Three provider
kinds fail that check while being genuinely usable, and `adversarial-review.sh --list-providers` — the
API preflight was rewired to trust — already reports all three as available:
  - `kimi-api`   — curl call gated on MOONSHOT_API_KEY (`scripts/adversarial-review.sh:1136,1586`), not a binary
  - `codestral`  — curl call gated on CODESTRAL_API_KEY (`scripts/adversarial-review.sh:1469`), not a binary
  - `codex`      — may live at /Applications/Codex.app/Contents/Resources/codex, off PATH
So preflight under-reports available cross-model reviewers relative to what adversarial can actually
reach — the exact failure `f5a8a10` set out to fix ("the blind audit could reach fewer reviewers than
adversarial on the same machine"), for the providers that commit did not account for.

**Do NOT fix by only relaxing the gate.** The canary `case` at `scripts/reviewer-preflight.sh:179-209`
has NO default arm, so an unknown candidate falls through with an empty `$tmpout`, fails the marker grep,
and is skipped. Making these candidates without canary arms means that when one of them is the ONLY
candidate, preflight reports `canary-failed` and caps the run at `clean:degraded` — strictly worse than
today's silent exclusion. Verified by reading; not fixed here because writing the two curl canary arms
needs live MOONSHOT_API_KEY / CODESTRAL_API_KEY credentials to test, which this machine does not have.

Recipe, in this order:
1. Add canary arms for `kimi-api` and `codestral` mirroring `run_kimi_api` / `run_codestral` in
   `scripts/adversarial-review.sh` (curl + jq extract), each returning the marker or empty.
2. Add an explicit `*)` arm that records `canary: no probe for <provider>` instead of falling through
   silently — an un-probeable candidate must be visible, not indistinguishable from a failed one.
3. Only then, skip the `command -v` re-check for names that came from `--list-providers` (keep it for
   the hardcoded fallback list at line 145, where nothing did detection). That list also omits
   `cursor-agent`/`kimi`, which the canary already supports — widen it in the same pass.
4. Dedupe `DETECTED`: `sed 's/-[0-9][0-9.]*$//'` maps `codex-5.3` AND `codex-5.4` to `codex`, so a spark
   host probes the same client twice for an identical result.

- [DONE 2026-08-17] 12 [CLOSED 2026-08-17 — pg_files_covered now compares ENTRY BY ENTRY instead of substring-matching a re-joined ',a,b,c,' string. Probed both directions: the never-reviewed `src/a,b.js` no longer reads as covered by neighbours `src/a` and `b.js` (rc 0 -> 1), and every legitimate case is untouched (plain match, non-match, the ADV-4 filename-with-spaces pair, wildcard, multi-file all-covered and one-missing). Residual kept deliberately: the files: header is comma-separated so a comma path still cannot be EXPRESSED there — it is now simply never covered, which demands a fresh review instead of granting a false one.] [correctness] hooks/lib/pipeline-gate-lib.sh :: pg_files_covered (lines ~221-236) | rule:comma-split-ambiguity | sig:files-list-comma-in-path
  PRE-EXISTING (untouched by the ship coverage-reuse change; surfaced by its CQ audit). `pg_files_covered` normalizes an artifact's `files:` line by splitting on commas and rejoining as `,a,b,c,`, then substring-matches `,$f,`. A real path containing a comma makes that lossy: an artifact listing `src/a` and `b.js,src/other.js` normalizes to `,src/a,b.js,src/other.js,`, so a never-reviewed file literally named `src/a,b.js` matches and reads as COVERED. Reachable through pg_range_reviewed (pre-push gate) since long before, and now also through pg_uncovered_files → ship's `reused` row, which is why it is worth recording rather than shrugging at. VERIFIED 2026-08-16 by direct probe, no longer theoretical: `pg_files_covered "src/a,b.js" "src/a, b.js,src/other.js"` returns 0 (covered) for a file no artifact ever listed, while an unrelated `src/zzz` correctly returns 1. Still requires a comma in a real tracked path, so likelihood stays low — but the mechanism is now demonstrated rather than argued, which raises it from DEFER-maybe to DEFER-definitely-fix. Proper fix: match on NUL- or newline-delimited entries instead of a comma-joined string, or reject/escape commas at artifact-write time in review-artifact.md. confidence:60 source:build-ship-coverage-reuse (re-verified 2026-08-16)

- [DONE 2026-08-17] 13 [CLOSED 2026-08-17 — `local _pap_root _pap_art _pap_mt _pap_ref _pap_n` added. Harmless in practice (each is reassigned before use) but the library is SOURCED into a live hook shell so the names persisted in the caller, and the identical omission one function away (delc/art_base) was already fixed during the coverage-reuse extraction. Verified: both are <unset> in the caller after a call.] [maintainability] hooks/lib/pipeline-gate-lib.sh :: pg_artifact_proven (lines ~278-331) | rule:missing-local-decls | sig:pap-vars-global
  PRE-EXISTING. `pg_artifact_proven` assigns `_pap_root`/`_pap_art`/`_pap_mt`/`_pap_ref`/`_pap_n` without `local`, so they leak into the shell that sourced the lib (a live hook process). Harmless today — every one is reassigned before use on each call — but the same omission in pg_range_reviewed (`delc`, `art_base`) was real enough to be worth fixing during the coverage-reuse extraction, and this is the same class one function away. VERIFIED 2026-08-16: after one call, `_pap_root` and `_pap_n` are set in the CALLING shell (probe: unset before, `/Users/greglas/DEV/zuvo-plugin` and `3` after). The `_pap_` prefix is deliberate POSIX-style namespacing, so the fix is either adding `local` (the file already assumes bash elsewhere) or documenting the convention. confidence:20 source:build-ship-coverage-reuse

- B-14 [correctness] hooks/lib/pipeline-gate-lib.sh :: pg_changed_production | rule:unusable-exit-status | sig:pcp-rc-meaningless
  PRE-EXISTING, surfaced by the adversarial pass on the ship coverage-reuse change. `pg_changed_production`'s exit status carries no information, so no caller can tell "the enumeration failed" from "there are genuinely no production files". MECHANISM CORRECTED 2026-08-16 — the first recording of this entry (and the commit message citing it) blamed "the last `read` hitting EOF", which is WRONG. The real cause: a `while` loop returns the status of the last command its BODY ran, and the body is `[ -n "$f" ] && pg_is_production "$f" && printf ...`. So the exit status is a fact about whether the LAST file in the diff happens to be a production file. Measured 4/4 against real ranges: last file scripts/reviewer-model-route.sh (production) -> rc 0; last file memory/backlog.md -> rc 1; docs/pipeline.md -> rc 1; tests/hooks/test-pipeline-gate-lib.sh -> rc 1. A bad range returns 0 (loop body never ran), an empty range returns 1 (its own guard). The status is therefore not merely uninformative, it is content-dependent NOISE that flips with the alphabetical tail of the change set — which is worse, because it looks stable across repeated runs on the same commit. Consequence today is safe in both callers by luck of direction, not design: `pg_range_reviewed` maps an empty result to "not covered" (blocks, i.e. more review) and `pg_uncovered_files` maps it to rc 3 (ship reviews the whole range). The adversarial reviewer proposed keying rc 2 off `pg_changed_production`'s status — that fix is ACTIVELY WRONG and must not be applied as written: it would classify every successful enumeration as an error and force full review always, silently disabling the reuse path. A real fix has to make the function's own status meaningful first (capture git's status before the pipeline, or write to a temp file and check), which touches all four gates that source it — hence its own change, not a rider on this one. confidence:45 source:build-ship-coverage-reuse-adversarial

- B-15 [correctness] hooks/lib/pipeline-gate-lib.sh :: pg_file_covered_by_any (@unpushed deletion branch) | rule:sentinel-commit-set-mismatch | sig:unpushed-delc-vs-changed-production
  PRE-EXISTING (byte-identical to the pre-refactor inline loop). For an `@unpushed..<tip>` range, the deleting commit is resolved with `git log --diff-filter=D … "$tip" --not --remotes`, while `pg_changed_production` enumerates the same range with `git log --format= --name-only -z -c "$tip" --not --remotes`. The adversarial pass flagged that the two commit sets may diverge (the `-c` combined-diff retention in one and not the other), which would make a deletion appear in the change set while its `delc` resolves to empty — i.e. reported uncovered even when a reviewing artifact exists. NOT REPRODUCED 2026-08-16. Built the shape most likely to expose it: a bare repo + un-pushed feature branch where a merge CONFLICT is resolved by DELETING the contested file in the merge commit itself. `pg_changed_production "@unpushed..HEAD"` reported src/doomed.sh, and the delc resolution (`git log --diff-filter=D --no-renames -c HEAD --not --remotes`) returned the merge commit correctly — the two commit sets agreed. So the hypothesised divergence does not occur in the combined-diff/merge-deletion case. Downgraded, not closed: one shape was tested, not all, and no test constructs a case where they SHOULD differ. Worth a targeted fixture before anyone touches sentinel handling. confidence:15 source:build-ship-coverage-reuse-adversarial (fixture built 2026-08-16, divergence not reproduced)

- [DONE 2026-08-16] 16 [correctness] scripts/build-antigravity-skills.sh:365-378 | rule:platform-block-leak | sig:antigravity-no-strip
  MUST-FIX, VERIFIED ON DISK. build-antigravity-skills.sh has NO platform-block stripping at all (`grep -c PLATFORM` = 0; codex 11, cursor 6, kimi 9), so the installed ~/.gemini/antigravity/shared/includes/env-compat.md carries 3x PLATFORM:CODEX, 2x PLATFORM:CURSOR, 2x PLATFORM:KIMI and 2x unwrapped PLATFORM:ANTIGRAVITY. An Antigravity agent therefore reads Codex's "single-agent hard rule" and degrades itself although Antigravity has full dispatch — silent, since every skill still runs, just weaker. Pre-existing for CODEX/CURSOR; the Kimi diff updated the strip list in TWO of three sibling builders and left the third with no mechanism. Fix: add strip_platform_blocks to Antigravity's pipelines, or extract per B-19 which closes it as a side effect. confidence:95 source:review-kimi-build-target

- [DONE 2026-08-16] 17 [correctness] scripts/install.sh:1509-1522 | rule:unvalidated-config-write | sig:tomllib-modulenotfound-pass
  MUST-FIX. The config.toml hook merge validates with tomllib, but `except ModuleNotFoundError: pass` falls straight through to os.replace() — so on any interpreter older than 3.11 the merged file is written UNVALIDATED, with no warning. The inline justification ("the block is generated, not hand-edited") covers only the template half of `merged`; the other half is the user's existing config, parsed by hand-rolled BEGIN/END line matching and malformable independently. CLAUDE.md states the requirement absolutely: install.sh must REFUSE to write a config.toml that would not parse, because a corrupt one breaks the Kimi CLI itself. Fix: treat ModuleNotFoundError as un-provable — abort with the existing "hook merge aborted" message, or add a structural check. confidence:85 source:review-kimi-build-target

- [DONE 2026-08-16] 18 [reliability] scripts/install.sh:1405-1406,1430 | rule:non-atomic-rename | sig:mktemp-not-colocated
  MUST-FIX (5-min fix). `kimi_manifest_tmp=$(mktemp)` lands in $TMPDIR, commonly a different filesystem from $HOME, so the later `mv -f` to $KIMI_AGENT_MANIFEST degrades to copy+unlink. An interruption leaves .zuvo-agents — the file deciding which agents zuvo may prune or overwrite — torn. The same file already does this correctly twice (install.sh:440-444 and :1044, both co-located, both commented "mv within one filesystem is atomic"). The empty-manifest guard at :1424-1428 protects a zero-write run, not a partial write. Fix: mktemp "$KIMI_AGENTS/.zuvo-agents.XXXXXX". confidence:80 source:review-kimi-build-target

- B-19 [maintainability] scripts/build-{kimi,cursor,codex,antigravity}-skills.sh | rule:CQ14-fourway-duplication | sig:build-scripts-copy-paste
  STRUCTURAL (zuvo:refactor territory — deliberately not merge-blocking). normalize_unicode() (16L) and get_skill_prefix() (8L) are BYTE-IDENTICAL across all four builders; the ToolSearch-neutralization sed block (6L) and the frontmatter AWK state machine (10L) are byte-identical kimi<->cursor. Zero platform variance. build-kimi-skills.sh:230 documents the duplication rather than removing it. The cost already materialized in the diff that surfaced it: one new PLATFORM:KIMI marker required synchronized edits in three files and the fourth was missed — that miss IS B-16. RECIPE: create scripts/lib/skill-build-common.sh beside the precedented scripts/lib/portable.sh with normalize_unicode(), get_skill_prefix(), replace_paths_generic(root, home_var[, skills_root]), strip_platform_blocks(keep_platform) generalized from Kimi's copy (the most complete of the three), validate_no_residual(dist, pattern, label); swap all four builders to sourced calls (wires stripping into Antigravity for the first time); add one bats test asserting identical output for a fixture. Do NOT extract adapt_tool_names / adapt_subagent_types / replace_model_refs / agent emission — genuinely different per-platform tool contracts and output topologies. Cites: kimi 59-76/231-238/203-208/254-263, cursor 31-48/122-129/100-105/145-154, codex 45-62/187-194/120-125/292-299. confidence:95 source:review-kimi-build-target

- [DONE 2026-08-16] 20 [portability] scripts/build-kimi-skills.sh:778,782 | rule:quoted-multiword-interpreter | sig:kimi-py-py3-fallback
  RECOMMENDED. `"$KIMI_PY"` is quoted as ONE token, but scripts/lib/portable.sh:68-69 documents that zuvo_python can return the two-word string "py -3" on Windows. Bash then execs a file literally named `py -3`. scripts/zuvo-home/runlog-sync.sh:14 leaves $PY_BIN unquoted for exactly this reason. Effect: on Windows/Git-Bash with only the py launcher, hooks-schema validation throws a spurious build failure on valid TOML and blocks the whole Kimi target. Fix: unquote, or read -ra into an array. confidence:80 source:review-kimi-build-target

- [DONE 2026-08-16] 21 [correctness] scripts/reviewer-model-route.sh:230-233 | rule:shadowed-case-arm | sig:kimi-k2.7-code-unreachable
  RECOMMENDED, found independently by two auditors. `kimi-k2.[0-9]*` in arm 1 matches `kimi-k2.` + `7` + `-code`, and bash case takes the first match, so the explicit `kimi-k2.7-code` literal in arm 2 is unreachable — that model is classified strong_alt instead of strong_primary. Contained to the diagnostic writer_lane field (reviewer_model resolves via a separate block), but telemetry and test-reviewer-routing.md read it. No bats case covers this input, which is why it shipped untested. Fix: reorder the arms, or narrow arm 1 to kimi-k2.[0-8]*. confidence:78 source:review-kimi-build-target

- [DONE 2026-08-16] 22 [safety] scripts/install.sh:1317,1443,1449 | rule:unguarded-env-path-delete | sig:kimi-code-home-rmrf
  RECOMMENDED. KIMI_CODE_HOME is honored with no validation beyond "is a directory", then `rm -rf "$KIMI_HOME/shared"` and `"$KIMI_HOME/rules"` delete two very common directory names at whatever path it points to. Everywhere else in the same function the diff adds marker/manifest provenance-keying specifically to avoid deleting non-zuvo content; shared/ and rules/ are the one part with none. Mirrors install_antigravity() faithfully, but Antigravity has no home-dir env override, so Kimi is the first place the pattern meets a user-settable path. Fix: require minimal evidence the dir is genuinely Kimi's home, or overlay with mkdir -p + cp -r instead of wipe-then-recreate. confidence:55 source:review-kimi-build-target

- [DONE 2026-08-16] 23 [reliability] scripts/install.sh:1395-1402 | rule:prune-before-dist-check | sig:kimi-agent-prune-ordering
  RECOMMENDED (reachability corrected DOWN from the adversarial pass's CRITICAL during triage). The agent prune loop deletes every manifest entry absent from $DIST/agents/ before anything confirms the dist is populated. The author defended the MANIFEST against exactly this case 20 lines later (:1424, "no agents in dist — kept the previous agent manifest"), so a successful build emitting zero agents was considered reachable — but the files above are undefended. Not CRITICAL because build failure IS gated at install.sh:1328 and build-kimi-skills.sh carries its own agents-lost-in-transform validation, so it needs a build that exits 0 having produced nothing. Fix: `if [[ -f "$MANIFEST" ]] && ls "$DIST"/agents/*.md >/dev/null 2>&1; then`. confidence:45 source:review-kimi-build-target

- B-24 [tooling] repo-wide *.sh | rule:CQ40-no-shellcheck | sig:no-shellcheck-config
  DEFER, systemic. No .shellcheckrc anywhere and no CI workflow invoking shellcheck, so CQ40 scores 0 for every bash file in a repo that is majority bash. Both real defects found in the ship coverage-reuse build (a nonexistent git flag, cross-shell variable assumptions) and several here (quoted multi-word interpreter, shadowed case arm) are exactly what shellcheck reports. confidence:60 source:review-kimi-build-target

## B-PROFILE-DEDUP — DONE
**Closed:** 2026-08-18, both defects.
1. **Identity is now the ARTIFACT.** `profile-session.py --run-key <transcript> [start] [end]`
   hashes the transcript's REALPATH plus the window bounds — the inputs that determine the answer —
   and nothing about the caller. The shared retro key (`skill+project+sha7`) is left alone: for
   almost every other skill `project` IS part of identity, and changing it globally would break
   them. This is a profile-session problem and it is fixed there.
2. **The guard runs BEFORE the analysis.** Phase 0.5 checks
   `$ZUVO_DIR/reports/profile-session-<key>.md` and early-exits naming the file, with `--force` to
   override. The old write-time check saved a line in a log, not the 25-45 minutes. A report is now
   an artifact with a path, so the exit hands back the actual file rather than saying a matching
   retro "exists" somewhere.
**Verified:** the key is stable across cwd (the actual bug), follows realpath through a symlink
alias, differs per transcript, changes with a window bound, and needs no readable file — which is
what makes it cheap enough to run first.
**Test:** assertions 14-21 of tests/hooks/test-profile-session-tokens.sh.
**Harness bug found while writing it:** the new block called `t_ok`/`t_no`, which that file does not
define. bash printed "command not found", returned 127, and the counters never moved — 11 broken
assertions summarised as **FAIL=0**. The file now defines `command_not_found_handle` so a misspelled
helper is a hard failure. `set -u` does not catch this class.
**Found:** 2026-08-18, after eight separate reports of the SAME rollout
(`rollout-2026-08-16T22-26-56-01a00b2e-….jsonl`, RShieldBE PR #404/#413 `watchLoop`) were handed in
for triage. Every one reached the same numbers (25:40:49 wall / 6:34:55 active / mutation 10-10).
**Evidence:** `~/.zuvo/runs.log` records **12 `profile-session` runs on 2026-08-18** — 03:54, 03:56,
07:20, 07:30, 08:48, 09:21, 09:45, 10:19, 10:21, 10:54, 11:13 — with at least eight naming the same
transcript. At 25–45 min of agent work and millions of (mostly cached) tokens each, that is hours of
duplicated analysis in a single day, still running while this was written.
**Root cause:** the idempotency key is `skill/project/SHA`, and `project` is derived from the
directory the skill was invoked in — not from the data being analysed. The one rollout was logged as
`mutation-data-flush-final`, `rs_be`, `tgm-survey-platform`, `ResearchShieldNew` and
`mutation-data-flush-profile-detailed`: five different "projects" for one input file, so the key never
matches and every run looks new. This also explains the contradictory self-reports — some runs print
"append-retro correctly performed an idempotent no-op", others do the full analysis, purely depending
on which worktree the invocation came from.
**Second defect, independent of the key:** even on a key hit the guard fires at the retro WRITE, i.e.
after the whole analysis has run. It saves a line in a file, not the work.
**Recipe:**
1. Key on the analysed artifact, not the caller: `hash(rollout path) + cutoff start/end`. A transcript
   is the same transcript regardless of which worktree the agent happened to sit in. Keep `project` as
   a display field; it is a property of the invocation site, never of the artifact's identity.
2. Check BEFORE the analysis, not at write time: early-exit with a pointer to the existing report and
   an explicit `--force` to override, so a deliberate re-profile is still possible.
3. While at it, treat a report as an artifact with a path so the early exit can name it, rather than
   telling the caller a matching retro "exists" somewhere.
defer-reason: none — this is a live cost leak, not deferred debt; filed here because it was found while
triaging farm reports in another repo | seen:8 | confidence:98 | source:field-report | 2026-08-18

- B-25 | shared/includes/ | duplicate-procedure | Consent-gated tool install is written out THREE times now
  and shared nowhere: `skills/infra-audit/SKILL.md` (DD-3, per-host consent + `apt remove` logging),
  `skills/write-e2e/SKILL.md` (`--no-install` / `ZUVO_E2E_NO_BOOTSTRAP=1`), and now
  `skills/mutation-test/SKILL.md` § 0.1c. All three follow the identical shape — offer, print the
  uninstall command, consent, log what was written, degrade loudly on decline — and the third was
  deliberately worded to parallel the first so extraction is mechanical. Extract to
  `shared/includes/tool-install-consent.md` and have all three load it. Not done in this change
  because it would drag two unrelated skills into the fence.
  defer-reason: out-of-fence — needs edits to infra-audit + write-e2e, which this build did not touch
  | seen:1 | confidence:85 | source:build | 2026-08-18

- B-26 | shared/includes/severity-vocabulary.md | missing-definition | `DEGRADED` appears 40+ times
  across skills as the canonical "tool absent, run continues on fallbacks" marker, but no shared
  include defines it — it is a de-facto convention, not a registered vocabulary, so nothing catches
  drift between `DEGRADED (reason)`, `[DEGRADED: reason]` and `coverage_mode: DEGRADED`. Add a
  "Degradation states" section to severity-vocabulary.md, explicitly distinct from S1-S4 severity
  (a DEGRADED run can still report S1 findings).
  defer-reason: out-of-fence — registry edit unrelated to mutation runners | seen:1 | confidence:80 | source:build | 2026-08-18

- B-28 | scripts/zuvo-home/{backlog-collect,runlog-collect}.py:24,44,29,49 | hardcoded-host |
  `tests/hooks/test-retro-loop-docs.sh` FAILs on these two files (`hardcoded IP in ...`): both carry
  `http://100.103.91.24:5599` as the `ZUVO_COLLECTOR_URL` default, while `runlog-sync.sh` was already
  migrated to the shared host resolver and PASSes the same two assertions. The gate is therefore red
  on every run and has been normalised as background noise, which is how a real regression would hide.
  Fix: route both through the same resolver `runlog-sync.sh` uses, keeping the env override.
  Verified pre-existing: identical FAIL on a clean `git worktree add --detach HEAD` checkout.
  defer-reason: out-of-fence — this build touched retro-mine/fleet-retro-pull/append-retro, not the
  collector clients | seen:2 | confidence:95 | source:build, refactor | 2026-08-29
  re-seen 2026-10-05 (zuvo:refactor dedc3165): the same two files are also the two
  `(8) versioned helper names a host address` FAILs of `tests/hooks/test-install-wiring.sh`, red at
  634bad5a; the refactor's characterization package had to allow-list them as known base-commit reds.
  main@6e098f3d no longer carries the literal address in backlog-collect.py — verify both suites green
  there and close this entry with the commit that fixed it.

- B-29 | scripts/zuvo-home/log-ideas | hang-on-trailing-flag |
  `tests/hooks/test-log-ideas.sh` FAILs: `log-ideas --skill build --count` (trailing flag, no value)
  HANGS instead of exiting. The suite's own sibling cases (`--count`, `--project`, `--count 3 --skill`)
  all pass, so the argument loop handles a bare trailing flag correctly everywhere except this pairing.
  log-ideas is called at the end of build/execute/refactor runs as a best-effort receipt, so a hang
  there stalls a finished pipeline for no benefit — it is documented as "never fails a skill", and a
  hang is worse than a failure.
  Verified pre-existing: identical FAIL on a clean `git worktree add --detach HEAD` checkout.
  defer-reason: out-of-fence — this build touched retro-mine/fleet-retro-pull/append-retro, not
  log-ideas | seen:1 | confidence:95 | source:build | 2026-08-29

- B-27 | skills/*/SKILL.md | missing-check | Nothing verifies that an intra-file section cross-reference
  ("see 0.1d", "(4.2c)") resolves to a real heading in the same SKILL.md. This build shipped exactly
  that defect — `--break` cited a non-existent 4.1b — and it was caught by an audit agent, not a test.
  A ~15-line checker in validate-skills.sh (collect `^#{2,4} (Phase )?N.Nx` headings, flag references
  that miss) would make it mechanical. Note the false-positive classes to exclude: version numbers,
  timings, and JSON values.
  defer-reason: out-of-fence — new check belongs in validate-skills.sh, not in a skill | seen:1 | confidence:90 | source:build | 2026-08-18

- [ ] B-SHIP-POSTMERGE-REF-FILTER — `zuvo:ship` post-merge enumeration filters runs by commit SHA
  alone, which does not prove a returned run is a post-merge run on the TARGET BRANCH. A run
  created for another ref or event that shares the SHA satisfies the enumeration, and once any
  rows exist the empty-read safeguard no longer applies — so the target-branch workflow can still
  be un-dispatched while ship counts the surface as covered. Fix: validate each run's
  `headBranch`/`event`/`createdAt` against the merge before counting it. Surfaced by adversarial
  pass 3 of the bc07cbe..7954760 review (WARNING, confidence medium); deferred at the
  `adversarial-loop.md` 3-pass cap with no CRITICAL outstanding. [defer-reason: NIT]

## B-adv-artifact-missing — 8 skills run adversarial with no `--artifact`, so truncation has no backstop
**Found:** 2026-08-19, TIER 3 self-review of bc07cbe..f84e5f5 (behavior auditor, confidence 85).
`skills/{debug,content-fix,geo-fix,seo-fix,content-migration,write-e2e,fix-tests,receive-review}/SKILL.md`
pipe their patch into `adversarial-review` with no `--artifact` flag and no exit-code capture
(`skills/write-tests/SKILL.md` redirects to a plain `zuvo/review.txt`). Because they write no proof
file, `pg_artifact_proven` has nothing to inspect — so a review truncated by the char cap is
end-to-end indistinguishable from a clean one. The build/execute/review skills are NOT affected:
they pass `--artifact`, so the content-keyed gate catches it at push time.
**Why deferred:** 9 SKILL.md files, and the right fix is one shared snippet in
`shared/includes/adversarial-loop.md` that every call site inlines — a template change, not nine
edits. defer-reason: structural-refactor (multi-file). Pre-existing (predates exit code 4; the new
code makes it *detectable*, it did not create it).
**Recipe:** (1) add the canonical `--artifact "zuvo/proofs/<skill>-<slug>-adversarial.txt"` form to
the loop include's pasteable block; (2) update the 9 skills to the new block; (3) assert in
`tests/hooks/` that every SKILL.md invoking adversarial-review passes `--artifact`.

## B-reviewed-blob-legacy-window — content binding is skipped forever for artifacts without `reviewed_blob=`
**Found:** 2026-08-19, adversarial (cursor-agent, CRITICAL, confidence high).
`hooks/pre-commit-adversarial-gate.sh` requires every staged blob to be a recorded `reviewed_blob=`
— but only when the artifact HAS such lines. Artifacts in the old format skip the check entirely
and fall back to the mtime comparison. That backward-compatibility was deliberate (day-one
blocking of every pre-existing artifact would have been worse) and it has no expiry, so an
old-format artifact is a permanent bypass of the content binding.
**Why deferred:** the fix is a migration POLICY, not a patch — bound it by artifact mtime against a
cutoff date, or require `reviewed_blob` once the staged paths changed after the artifact was
written. Picking a cutoff unilaterally while a parallel session works in this checkout is the drift
these gates exist to prevent. defer-reason: structural-refactor (multi-file).

## B-infra-hex-secret-residue — lowercase-hex secrets survive SED_REDACT by construction
**Found:** 2026-08-19, adversarial (cursor-agent, WARNING, confidence high).
Rule B2 unmarks pure lowercase-hex runs so sha256 digests, git SHAs and checksums are preserved in
trivy/docker evidence. A secret that happens to be lowercase hex (`BACKUP_KEY=deadbeef…`) is
therefore never redacted by the value-shape rule. It IS still caught when its key name matches the
keyword rule; only generically-named hex secrets slip.
**Disposition:** documented trade-off, not a defect — the alternative destroys the evidence the
collector exists to gather. defer-reason: NIT. Revisit only if a real corpus shows hex-form secrets
under generic key names.

## B-profile-session-extract — token accounting sits inline at module scope
**Found:** 2026-08-19, structure auditor (confidence 48 — below the 51 report threshold).
`scripts/zuvo-home/profile-session.py:139-172` and `:262-289` add ~70 lines of accounting logic at
module scope with single-letter temporaries; `extract_token_usage()` and `attribute_polling()`
would also make them unit-testable rather than only reachable through a subprocess.
defer-reason: NIT.

## B-blocknoverify-fmt — one-line case arm with embedded runs of spaces
**Found:** 2026-08-19, structure auditor (confidence 55).
`hooks/block-no-verify.sh:111` is a 268-char single line with literal 4-space runs around `|`,
where the sibling `scripts/git-noverify-shim.sh:121-124` uses a backslash-continued 3-line wrap.
Verified NOT a behavioural difference (case-pattern whitespace is insignificant to the shell).
defer-reason: NIT.

## B-review-tier2-skip-2026-08-19 — CLEARED 2026-08-19
**Resolution:** the independent CQ/Q pass WAS run (4 agents, batched ~10 files each after the
full-scope prompts kept dying on API 403). It found things the lead's inline pass had missed, which
is the honest measure of what the 403s cost:
  - `adversarial-review.sh` recorded `reviewed_blob=` for EVERY dirty file, not the reviewed ones —
    so under `--files <subset>` an unrelated dirty file was whitelisted through the content-binding
    gate. Reproduced; fixed.
  - the `!shell` alias branch never checked `-n`, git commit's exact equivalent of `--no-verify` —
    `!git commit -n -m sneaky` passed BOTH layers. Reproduced (commit created); fixed.
  - `install.sh`'s debris check used a bare `exit 1` above the main-run guard, so `source
    scripts/install.sh` with debris present killed the SOURCING shell — and the test that sources
    it would have died rather than failed one assertion. Reproduced; fixed.
  - `_recent_artifact_exists` accepted a FUTURE mtime as recent (negative age is always <= grace),
    so one `touch -d @9999999999` decoy satisfied the guard forever. Reproduced; fixed.
  - `retro-mine.py --days` and `backlog open --repo` crashed with IndexError on a missing value
    (both cron/CLI paths); `backlog-consolidate.py` had `TODAY = "2026-07-19"` hardcoded, which
    silently disabled its own backup-before-rewrite step on every later run. All fixed.
  - a bats test asserting model sanitization set `ZUVO_CODEX_MODEL`, which the script reads ZERO
    times, and had no positive control — it passed whether the code worked, was deleted, or never
    ran. Repointed at the real variable and given a control; mutation-probed red.
**Dropped after repro:** the alias seen-set reset, the `case`-pattern whitespace claim (twice), the
sentinel-injection claim (the repro used pure hex — the documented residue, not injection), and
dist-build's "does not pass ZUVO_DIST_ROOT".
**Regression caught by the suite:** the `-n` fix initially REPLACED the whole `!shell` branch and
dropped the abbreviation handling a parallel session had added. Extended instead of rewritten; both
properties now hold together, with `--no-verbose` still not over-blocked.

## (closed) B-review-tier2-skip-2026-08-19 — TIER 3 self-review completed without 2 of its 4 mandated agents
**Found:** 2026-08-19, Validity Gate of the bc07cbe..3170213 review.
`cq_auditor` was dispatched TWICE and both runs died with `API Error: 403 Request not allowed —
Please run /login`; `confidence_rescorer` was never dispatched and the lead scored confidence
inline. `structure_auditor` returned in full and a narrowed `behavior_auditor` returned the
exit-code-4 blast-radius analysis, so coverage was partial, not absent — and adversarial ran to
completion (3 passes, 5 providers, 31 REVIEW BY lines, no truncation), which is the cross-model
independence the sub-agents also exist to provide.
**Per the skill's own rule this is `gate_status = FAIL` and VERDICT `INCOMPLETE`**, with no degraded
path on a self-review. Recording it rather than rounding it up: the CQ1-CQ40 sweep over all 28
production files was NOT performed by an independent agent — the lead ran the CRITICAL gates
(CQ3/4/5/6/8/14, Q7/11/13/15/17) inline and mechanically, and found two real things that way
(CQ8: two new swallows added; CQ14: 4 occurrences, correctly under the 5+ threshold).
**To clear:** re-run `zuvo:review origin/main..HEAD --report-only` when dispatch is healthy and
diff the finding sets. If the independent CQ pass surfaces nothing new, downgrade this entry to a
telemetry note; if it does, that is the measure of what the 403s cost.
**Related gap this exposed:** the Validity Gate has values for NOT_DISPATCHED (a choice) and
NO_RETURN (silence) but none for "dispatched, harness returned a terminal API error", so harness
flakiness is indistinguishable from a lead that skipped its agents. Proposal filed in the retro.


---

## B-wt-ledger-escaping — run-ledger value lines have no escaping rule
**From:** zuvo:review 346c00f..0306ae4 (write-tests resume patch), adversarial pass 3, WARNING.
**Where:** `skills/write-tests/SKILL.md`, Auto-mode context boundary — the ledger's indent-block
value format ("key alone on its line, each value line indented two spaces, ending at the next
unindented key").
**Problem:** a value line that itself begins with two spaces is indistinguishable from a
continuation line. Affects `queue:`, `baseline_failures:`, `exemplars:` — the three multi-line keys.
An exemplar excerpt copied from an indented block is the realistic trigger.
**Defer reason:** structural-refactor (the honest fix is a real serialization decision — fenced
blocks, or a JSON sidecar like the coverage manifest — not a one-line patch).
**Recipe:** give the ledger the same treatment `coverage-manifest-schema.md` got: a fenced schema
block with explicit field types, or make it `run-<date>-<slug>.json` and drop the ad-hoc format.

## B-wt-basename-collision — coverage manifests and contracts are keyed on basename
**From:** same review, adversarial pass 2, WARNING. **PRE-EXISTING** — predates this diff.
**Where:** `shared/includes/coverage-manifest-schema.md` — `$ZUVO_DIR/contracts/<production-basename>.coverage.json`
(and now the sibling `<basename>.contract.md`).
**Problem:** two production files sharing a basename in different directories (`user/index.ts` and
`order/index.ts`, or two `service.ts`) write to the SAME manifest path. The second overwrites the
first, and `--resume` would then verify a sha256 belonging to a different file — which the hash
check catches, but only by refusing, never by resolving.
**Defer reason:** structural-refactor (multi-file: schema, write-tests, test-coverage-gate.py all
resolve this path).
**Recipe:** key on the repo-relative path with separators flattened (`src-user-index.ts.coverage.json`)
or on a short path hash; migrate readers in `scripts/test-coverage-gate.py` and
`shared/includes/test-inventory-protocol.md` in the same change.

## B-wt-metrics-ambiguity — test-metrics.md formulas are themselves under-specified
**From:** zuvo:review 346c00f..HEAD, adversarial pass 4 (covering pass), WARNING+INFO.
**Where:** `shared/includes/test-metrics.md` — KILL_RATE row, FRESH_TOKENS row, preamble.
**Problem:** the file exists to end definitional drift and carries two of its own.
(a) KILL_RATE says "killed / executed from the MUTATION PROBES table" AND "native runner present ->
score_triaged" — two different sources with no precedence rule when both exist.
(b) FRESH_TOKENS excludes cached input, which is right for cost but makes the number
non-comparable across sessions with different cache-hit rates; that caveat is not stated.
**Defer reason:** NIT-adjacent but genuinely needs a decision, not a wording tweak.
**Recipe:** state precedence explicitly (native score_triaged WINS when a native run produced a
number; the probe table is the fallback), and add one line on FRESH_TOKENS comparability.

## B-wt-contract-unvalidated — resume trusts contract.md, which no validator checks
**From:** same review, adversarial pass 4, WARNING.
**Where:** `shared/includes/coverage-manifest-schema.md` ("The gate validates the manifest only")
vs `skills/write-tests/SKILL.md` Phase 0 step 0, which reads classification out of the contract.
**Problem:** `production_sha256` proves the production file is unchanged; nothing proves the
contract is well-formed or self-consistent, yet a MATCH resume takes its classification as
authoritative and skips re-deriving it. A truncated contract (the exact artifact an interrupted
run leaves behind) resumes as if valid.
**Defer reason:** structural-refactor — the fix belongs in `scripts/test-coverage-gate.py`
(a `validate --phase contract` mode), not in prose.
**Recipe:** add a contract validator phase asserting the six sections plus the classification line
are present, and make step 0's MATCH path require it to exit 0 before trusting the contract.

## tooling debt surfaced by the poll-cost review (2026-08-26)

### CQ40 — no lint job in CI, only a ratchet in the test suite

**What:** `ruff` runs through `tests/hooks/test-python-lint.sh` against a hardcoded ratchet (46
findings). There is no `.github/workflows` lint job; `ci/` holds only the pipeline-entry gate.

**Why it is not urgent:** the ratchet works — it caught a `B904` that the poll-cost review had just
introduced, at 47 vs 46, and the fix went in before the commit landed. What it cannot do is fail
before the whole suite runs, and it cannot report which change raised the number without a diff.

**Scope:** one workflow calling the same ruff invocation the test uses, so the two cannot drift.
Repo-wide and pre-existing; scored CQ40=0 on all three files in that review for this one reason.

**Defer-reason:** out-of-fence (CI configuration, not the reviewed diff).

### 34 unused module-level symbols in scripts/zuvo-home/backlog-collect.py

**What:** `audit_scan` CQ13 reports 34 exported-but-unreferenced symbols in that one file — `ROOTS`,
`DATE_RE`, `ID_RE`, `SEV_RE`, `DONE_SECTION`, `OPEN_SECTION`, `TEMPLATE_RE`, `RESOLVED_MARKERS`,
`is_resolved_inline`, `valid_date`, and 24 more.

**Why it is here rather than in that review:** the file is outside the reviewed file set and the diff
did not cause any of it. Scoring it against that change would have made the CQ number describe the
repository instead of the change — the fence exists for exactly this.

**Scope:** confirm each is genuinely unused (a module-level constant read only inside its own file is
a false positive for "exported"), then delete or make private.

**Defer-reason:** out-of-fence (pre-existing debt in an untouched file).

## B-reprobe-test-helper-dedup — extract a `run_reprobe()` helper in the gate test

**What:** `tests/gates/test-retro-friction-helpers.sh` repeats
`( cd "$RP" && bash "$REPROBE" … >/dev/null 2>&1 ); [ "$?" -eq N ]` for ten cases, differing only in
flags and expected exit code (Q9's 3+ threshold).

**Why it matters:** copy-paste drift — a future case that forgets the `>/dev/null 2>&1` redirection
or the subshell changes what `$?` reads, and the assertion then measures the wrong command.

**Why not fixed in-run:** the ten assertions were each verified to read the intended exit code
(the subshell's last command), and restructuring a passing safety suite mid-fix-loop trades a real
risk for a cosmetic gain. Do it as its own change, with the suite green before and after.

**Defer-reason:** NIT (test-file readability, no behavioural gap).

## B-radar-test-cli-inventory — complete the radar branch/error evidence

**File:** tests/gates/test_refactor_radar.py:604 (codex/refactor-radar-hardening).
**Fingerprint:** test_refactor_radar.py|Q7-Q11|radar-exhaustive-evidence
**Source:** build/test-audit, 2026-09-06; seen:1; confidence:90; severity:medium; tier:C.
**What:** 68 tests pass as a paired suite, but Q7/Q11 exhaustiveness is not proven. Finish
the production-first branch/error inventory for prunable worktrees, source census/blob limits
and malformed git records. Separate small provider cases from medium CLI fixtures (Q20),
add missing mock argument assertions (Q3) and versioned sanitized API contracts (Q23).
**Defer-reason:** bounded follow-up test campaign; no strict tier-A claim in the current repair.

## B-radar-test-contract-inventory — complete contract and history negative paths

**File:** tests/gates/test_radar_contract.py:19 (codex/refactor-radar-hardening).
**Fingerprint:** test_radar_contract.py|Q7-Q11|radar-contract-evidence
**Source:** build/test-audit, 2026-09-06; seen:1; confidence:90; severity:medium; tier:C.
**What:** Current exact tests cover registration, CodeSift envelopes, fork promotions and
bounded/atomic I/O. Finish all compatible-history/error branches, provider contract artifacts
(Q23) and transport argument assertions (Q3); retain current positive/negative assertions.
**Defer-reason:** bounded follow-up test campaign; no native/full mutation score is claimed.

## B-radar-bundle-retention — distinguish failed bundles from retained releases

**File:** scripts/install.sh:570 (codex/refactor-radar-hardening).
**Fingerprint:** install.sh|resource-hygiene|radar-bundle-retention
**Source:** build/adversarial-review, 2026-09-06; seen:1; confidence:90; severity:low.
**What:** Installation atomically publishes a complete bundle and preserves old versions,
but failed staging directories and superseded releases can accumulate. Add failure-only
cleanup of installer-owned temporary entries; design retention with running-session/rollback
constraints before deleting successful bundles. Do not reuse whole-cache cleanup.
**Defer-reason:** non-local cleanup/retention change; current failure preserves the active bundle.

## B-radar-secret-io — keep the optional Keychain token out of the stdout spool

**File:** scripts/lib/radar_remote.py:164 and scripts/lib/radar_io.py:22 (codex/refactor-radar-hardening).
**Fingerprint:** radar_remote.py|secret-io|keychain-temporary-spool
**Source:** build/adversarial-review, 2026-09-06; seen:1; confidence:95; severity:low.
**What:** The shared command reader caps memory by spooling stdout to a private anonymous
temporary file. That also applies to the optional macOS Keychain fallback, so the token is
not memory-only, although no report/stderr serialization occurs and the file is closed.
Add a dedicated bounded-memory secret reader with timeout/size/error/redaction tests; keep
large git/provider output spooled. Existing RADAR_BB_TOKEN input avoids this subprocess path.
**Defer-reason:** separate secret-reader contract; limitation disclosed, no fleet install performed.

## B-radar-perf-followup — typed boundaries and measured test debt

**File:** scripts/lib/radar_cli.py:72, scripts/lib/radar_snapshot.py:34, tests/gates/test_radar_performance.py:1 (d3cb784).
**Fingerprint:** radar_cli.py|quality-followup|typed-dicts-and-patch-gate
**Source:** debug/2026-09-06; confidence:90; severity:low.
**What:** The farm/performance fix passes 97 tests and gives index/runtime/snapshot 100% line/branch coverage, but CLI is 88% and metrics 90%. Consolidates B-radar-test-cli-inventory and B-radar-test-contract-inventory: add full typed input models, split the long snapshot validator/CLI by responsibility, separate pure/integration test levels, assert transport mock arguments and add an actual server-side patch coverage gate. No native mutation score is available for d3cb784; run that as a scoped test-strength campaign before asserting Q21.
**Defer-reason:** broader type/test/CI campaign, not necessary to move CPU work off the laptop; detailed evidence in ~/.codex/outputs/refactor-radar-performance-20260906/review.md.

## B-install-source-side-effect — sourcing installer refreshes sleep guard

**File:** scripts/install.sh:2106 (fa7a654).
**Fingerprint:** install.sh|scope-isolation|top-level-sleep-guard
**Source:** debug/2026-09-06; confidence:95; severity:medium.
**What:** The sleep-guard install block lives after the main BASH_SOURCE guard. Sourcing this supposedly sourceable installer to call only install_refactor_radar_bundle also copies ~/.zuvo/zuvo-sleep-guard.zsh and can edit ~/.zshenv. In this run the existing .zshenv marker prevented an edit and the copied guard matches current main. Move the block under the main guard, cover side-effect-free source, and expose an explicit scoped skill installer with per-skill provenance.
**Defer-reason:** installer/hook lifecycle is outside the radar measurement fix; no unrelated hook implementation changed.

## B-radar-debug-baseline-gates — three earlier full-suite failures

**Files:** tests/hooks/test-dogfood-wired.sh; tests/hooks/test-verify-audit-citations.sh; tests/benchmark-suite/test-benchmark-smoke.sh.
**Fingerprint:** tests/run-all.sh|baseline-failures|radar-debug-20260906
**Source:** debug/2026-09-06; confidence:95; severity:medium.
**What:** Both clean c8aff96 baseline (rt 1788680872-48816-7402) and radar fix full run (1788688666-3903-8251) end PASS=119 FAIL=3 SKIP=4. Dogfood live-repo activation is absent (hp=''); citation gate fails extensionless/current-SHA cases; benchmark smoke exits 129. Diagnose these separately; a matching baseline proves no new failure, not a green repository.
**Defer-reason:** unchanged failures outside files touched by the performance fix. Use rt; no local full-suite fallback.

## B-prepush-gate-merge-commit-range — pre-push gate counts a merge commit's remote content as unreviewed

**File:** hooks/pre-push-gate.sh (range from git stdin `<remote_sha>..<local_sha>`); hooks/lib/pipeline-gate-lib.sh (`pg_unpushed_range` already has the `--not --remotes` sentinel).
**Fingerprint:** pre-push-gate.sh|range|merge-commit-two-dot
**Source:** review/2026-09-15 (tgm-survey-platform fix/stryker-config-unify push); confidence:95; severity:high.
**What:** Pushing `26ae6572` (merge of bitbucket/develop into a 4-commit branch, one conflict-resolved file) was BLOCKED with 867 "never reviewed" files — the two-dot diff `3217ba83..26ae6572` includes everything develop brought, although all of it is already on the remote and reviewed in its own PRs. Only the human `ZUVO_ALLOW_ADHOC=1` escape gets past it, so every "merge develop to resolve a stale PR" now needs a human at the keyboard.
**Fix:** for an explicit stdin range, derive the file set from `git log -c --not --remotes <local_sha>` (the same walk the `@unpushed` sentinel uses) or restrict the two-dot diff to first-parent-new commits — content reachable from any remote ref must never count as unpushed. Add a test in tests/hooks/ with a merge commit whose second parent is a remote-tracking ref.
**Defer-reason:** found mid-review of another repo; gate change needs its own test run (tests/hooks) and release.

---

### B-REWAKE-ATOMIC — the rewake counters are a non-atomic read/modify/write
**File:** hooks/zuvo-rewake-on-failure.sh (counter read at :97-98, increments at :127-128/:144-145, window check at :163)
**Fingerprint:** zuvo-rewake-on-failure.sh|concurrency|check-then-write
**Source:** review/2026-09-18 (214704f..8c50347); confidence:70; severity:medium.
**What:** Two concurrent StopFailure hooks for the same session both read the counters before either writes, so both can pass the lifetime cap and both can pass the `$sid.window` dedup — two sleeps, two wakes in one reset window. The caps still bound the flood in practice (StopFailure is serialized per session today), which is why this is not a MUST-FIX.
**Fix:** take an `mkdir "$cdir/$sid.lock"` lock around read-increment-write, release it on every exit path at the existing `_sweep` call sites, and fall through unlocked after a short timeout so a stale lock can never disable the watchdog.
**Defer-reason:** structural-refactor (multi-file) — a locking protocol across three call sites plus its own concurrency test, not an edit.


- [ ] B-20260922-BACKLOG-GATES-DOUBLE-PARSE [P3][performance][conf 55]
**Fingerprint:** append-runlog+backlog-archive.py|performance|two-full-parses-per-run
**Source:** review/2026-09-22 (5e2fe64..5c6b472), behaviour audit BEHAV-5; confidence:55; severity:low.
**What:** Every skill run now parses BOTH backlog files TWICE — once for the namespace gate (`verify`) and once inside `archive`'s own pre-check — and neither consults the `.backlog-index.tsv` that `index` builds. Fleet backlogs are 1.2-1.8 MB / 500+ entries, and the gates were deliberately moved above the retro-gate exemptions, so this cost is now paid by every run in every repo with a backlog, including the ones that can have no violation.
**Fix:** one python invocation that verifies and archives in the same process, reusing the `op`/`dn` maps `undeclared_pairs` already built (an `--and-archive` mode on `verify`, or `archive --already-verified` called only from `append-runlog`); measure a 1.8 MB backlog before and after so the claim is a number, not an assumption.
**Defer-reason:** structural-refactor (multi-file) — changes the bash gate block and the python CLI contract together, plus a measurement; not an edit.

- [ ] B-20260922-CMD-ARCHIVE-FUNCTION-LENGTH [P3][structure][conf 55]
**Fingerprint:** backlog-archive.py|structure|cmd_archive-91L-cmd_drop_stale-83L
**Source:** review/2026-09-22 (5e2fe64..5c6b472), structure audit STRUCT-1/STRUCT-2; confidence:55; severity:low.
**What:** `cmd_archive` measures 91 logical lines and `cmd_drop_stale` 83, against this repo's own 50-line function limit (`rules/file-limits.md`, "other stacks" carry-over). Both mix precondition validation, partitioning, dry-run reporting and the locked write in one body.
**Fix:** extract `_validate_archive_preconditions(real, archive)`, `_partition_movable(marked, unmarked, text)` and `_write_archive_sections(sections, real, archive)`; `cmd_archive` becomes a ~25-line orchestrator. `all_keys_index()` was already extracted in this review (the duplicated part of STRUCT-2).
**Defer-reason:** structural-refactor — this function was rewritten from scratch in THIS session precisely because four scripted patches left a dead duplicate of it that the suite could not see, and the stdlib guard for that (`test-python-no-shadowed-defs.sh`) is one run old. Splitting it again in the same session, by script, is the exact sequence that produced the defect. Do it as its own change with the gate green before and after.

- [ ] B-20260922-VERIFY-TESTS-MAIN-LENGTH [P3][structure][conf 55]
**Fingerprint:** scripts/zuvo-home/verify-tests|structure|main-443L-two-extraction-seams
**Source:** review/2026-09-22 (f43957a..e9add848), structure audit STRUCT-2; confidence:55; severity:low.
**What:** `main()` grew from ~328 to ~443 logical lines across this range (`b7c7567f` + `e9add848`) — budget/gate-round wiring, the receipt/gate reordering and the exception guards all went into the body, while the rest of the new logic was properly extracted into named helpers. The file itself is 1818 lines against this repo's 400L target / 800L auto-fail (`rules/file-limits.md`), but that breach is PRE-EXISTING (1488 lines before this range) and is not what this entry is for.
**Fix:** two self-contained seams inside the block this range already touched, in order: (1) `_print_refusal(prod, root, st, budget_n, time_budget_n, prev, manifest_path)` for the early-refusal short-circuit, (2) `_print_verdict(rc, ...)` for the end-of-run block that branches on `rc` and prints one of four VERDICT blocks. Together ~150 of main()'s 443 lines, no behaviour change. The third part of STRUCT-1 — the duplicated gate-round hint — was already extracted in this review as `print_gate_round_hint()`, so both targets now call one function.
**Defer-reason:** structural-refactor (multi-file in effect) — it is a pure-motion change to the entry point of the helper that every write-tests run depends on, and this session already changed that function's control flow twice. Move it on its own, with `tests/hooks/test-verify-tests.sh` green before and after, so a motion bug cannot hide behind a behaviour change.

- [ ] B-20260922-VERIFY-TESTS-BUDGET-ZERO [P4][correctness][conf 55]
**Fingerprint:** scripts/zuvo-home/verify-tests|correctness|budget-zero-falsy-fallback
**Source:** review/2026-09-22 (f43957a..e9add848), behaviour audit backlog item; confidence:55; severity:low.
**What:** `base_budget = st.get("budget") or a.budget` treats a STORED `0` as falsy and silently falls back to the CLI default, so `--budget 0` does not mean "no pass limit" the way `--time-budget 0` means "no clock". PRE-EXISTING — the same `or` was there before this range under the name `budget_n`; this range only renamed it.
**Fix:** use an explicit `is None` check, and decide deliberately whether `--budget 0` is "unlimited" (matching `--time-budget 0`) or should be rejected at parse time. Whichever, say so in `--help`, because the two flags currently read as symmetric and are not.
**Defer-reason:** NIT — no run passes `--budget 0` today; the asymmetry is a documentation-and-parse question, not a defect in the paths anything exercises.

- [ ] B-20260922-GATE-ROUND-ARTIFACT-EVIDENCE [P2][correctness][conf 70]
**Fingerprint:** scripts/zuvo-home/verify-tests|correctness|gate-round-evidence-is-hash-delta-not-gate-artifact
**Source:** review/2026-09-22 (f43957a..8b4c0379), CQ audit finding 4 + adversarial chunk C; confidence:70; severity:medium.
**What:** `--gate-round` now requires a spec to differ from the receipt, which closed the "four typed names take the budget from 3 to 11" hole. But the evidence is a raw sha256 delta: a cosmetic edit (a blank line, a reworded docblock) satisfies it, and `stamp_receipt` re-stamps on every green pass, so the evidence resets each round. The guarantee is "a round costs a test edit", NOT "a round costs a gate having run" — SKILL.md now says so explicitly instead of overclaiming.
**Fix:** two steps, in order. (1) Cheap and strictly better: have `stamp_receipt` record `spec_normhash` alongside `spec_sha256` (`test-coverage-gate.py normhash --file <t>` already exists and is what Step 3.5's freshness guard uses), and compare normhash in `specs_changed_since_receipt` — whitespace/comment-only edits stop minting rounds. Document the new receipt field in `shared/includes/coverage-manifest-schema.md`. (2) Stronger, if (1) proves insufficient: require the named gate's own artifact and check it is newer than the receipt epoch — `adversarial` → a `zuvo/proofs/*-adversarial.txt` with ≥2 `REVIEW BY:` lines, `test-audit` → the test-quality report path, `fix-in-run` → a commit touching the production file. Keep the closed-set names either way.
**Defer-reason:** structural-refactor (multi-file) — (1) changes the receipt schema, its documented include, and the gate helper together, and every existing manifest's receipt lacks the new field, so it needs a missing-field-means-"unknown, refuse" migration path. Not an edit, and this session has already changed that code path three times.

## B-20260924-ZUVO-PUSH-26-REVIEW-LEADS — LIVE (unverified)

Adversarial review of origin/main..main (26 commits, pushed 2026-09-24 on the owner's request; proof zuvo/proofs/723ca83-push-26-commits.txt, artifact memory/reviews/723ca83..9856395-push-26-commits.md). CRITICAL leads, not yet reproduced:
- FILE: scripts/adversarial-review.sh:1744
- ISSUE: `provider_model()` does not handle the newly added `qwen` provider, causing model resolution to return empty and ignoring `ZUVO_QWEN_MODEL`.
- FILE: scripts/adversarial-review.sh:1412-1416
- ISSUE: `QWEN_CODE=1` host detection only runs if no earlier host provider checks match, allowing self-review with the qwen lane when running inside Qwen Code plus another detected IDE/tool.
- FILE: scripts/adversarial-review.sh:414-416
- ISSUE: Documented baseUrl validation for the qwen lane (to prevent per-token billing) is not implemented anywhere in the code.
- FILE: scripts/adversarial-review.sh:1949‑1955
- ISSUE: `model_reasoning_effort` is written to `config.toml` directly from the unvalidated `effort` argument / `ZUVO_CODEX_EFFORT*` environment variables.
- FILE: scripts/adversarial-review.sh:2090-2091
- ISSUE: Default effort `none` for primary lane is not in the documented valid set (`minimal|low|medium|high|xhigh|max`), likely causing codex to reject or ignore the setting.
- FILE: scripts/adversarial-review.sh:~1849 (codex_cli_guard function)
- ISSUE: codex_cli_guard checks version of wrong codex executable
- FILE: scripts/adversarial-review.sh:~2036 (run_codex function)
- ISSUE: Unvalidated JSON_TMPDIR leads to writes to root directory
- FILE: scripts/adversarial-review.sh:~1849 (codex_cli_guard version check)
- ISSUE: Version check only applies to codex CLI major version 0
- FILE: scripts/adversarial-review.sh:2385
- ISSUE: Exit status is ignored when output JSON is present, allowing crashed or aborted runs to return stale reviews from previous invocations.
- FILE: scripts/adversarial-review.sh:2385
- ISSUE: `env -u` only unsets `OPENAI_*` variables, leaving `DASHSCOPE_*` variables active to silently bypass the plan billing guard.
- SUGGESTED FIX: Only apply the notice check if the text does not contain review markers (e.g., `! [[ "$text" =~ (SEVERITY|FINDING|ISSUE|NO ISSUES FOUND) ]]`).
- FILE: scripts/adversarial-review.sh:2448-2450
- ISSUE: Arbitrary file read via `ZUVO_QWEN_SETTINGS` environment variable
- FILE: scripts/adversarial-review.sh:2385-2390 (run_qwen)
- ISSUE: Environment variables QWEN_BASE_URL and QWEN_API_KEY are not cleared, allowing override of plan endpoint and key.
- FILE: scripts/adversarial-review.sh:2360-2365 (_qwen_plan_guard)
- ISSUE: TOCTOU race between guard reading settings.json and qwen CLI reading the same file.
- FILE: scripts/adversarial-review.sh:run_kimi (around agent file creation)
- ISSUE: No error checking on Kimi agent file creation, allowing fallback to default agent with shell execution tools
- FILE: scripts/test-coverage-gate.py:580
- ISSUE: `$visibility` set by property/constant modifiers bleeds across statement boundaries into methods omitting `public`.
- FILE: scripts/test-coverage-gate.py:568
- ISSUE: Instantiating an anonymous class inside an abstract class or trait permanently sets `$exposeProtected` to `false`.
- FILE: scripts/test-coverage-gate.py:line ≈ 630 (inside `extract_php`)
- ISSUE: `expose_protected` is computed once per file (`bool(PHP_FALLBACK_EXPOSES_PROTECTED.search(source))`) and then applied to all functions in that file, even those belonging to concrete classes. This causes protected methods in non‑abs
- FILE: scripts/test-coverage-gate.py:line ≈ 617 (fallback regex block)
- ISSUE: `PHP_FALLBACK_METHOD` regex is applied to the raw source without first stripping comments or string literals, so it can match the word “function” inside a comment, doc‑block, or string and emit a spurious symbol.
- FILE: scripts/test-coverage-gate.py (PHP tokenizer embedded in Python string, around line 562-577)
- ISSUE: Visibility state leaks from property declarations to subsequent method declarations, causing protected methods to be incorrectly inventoried in non-abstract classes.
- FILE: scripts/test-coverage-gate.py:631
- ISSUE: Fallback PHP symbol extraction uses per-file `expose_protected` flag instead of per-class, breaking consistency with the tokenizer path.
- FILE: scripts/test-coverage-gate.py:580 (PHP tokenizer loop)
- ISSUE: Tokenizer path leaks visibility modifiers from non-function constructs (properties, constants) to subsequent methods without explicit visibility.
- FILE: scripts/zuvo-home/append-retro:254
- ISSUE: Substring search across entire cumulative `$RETRO_MD` silently drops new narratives matching historical entries or boilerplate.
- ATTACK VECTOR: `python3 -c '... in open(sys.argv[2]).read()'` checks whether the raw content of `$MD_FILE` appears anywhere in `$RETRO_MD`. Because `$RETRO_MD` is an append-only log accumulating past runs across all commits, any audit pro
- FILE: scripts/zuvo-home/append-retro:251‑259
- ISSUE: TOCTOU race – the script checks whether the MD block is already present with a Python command, then separately appends it with `cat`. Between the check and the append another concurrent process could append the same block, resultin
- FILE: scripts/zuvo-home/append-retro:252
- ISSUE: Substring check (`in`) instead of exact equality for retro block deduplication
- FILE: scripts/zuvo-home/append-retro:248-257
- ISSUE: No locking around the append operation, enabling race conditions on concurrent runs
-    FILE: scripts/zuvo-home/append-retro:252-258
-    ISSUE: Python exit code ambiguity causes incorrect appends on runtime errors
-    FILE: scripts/zuvo-home/append-retro:252-260
-    ISSUE: Non-atomic check-then-append leads to concurrent duplicate appends
-    FILE: scripts/zuvo-home/append-retro:250,252-260
-    ISSUE: TOCTOU race conditions on MD_FILE/RETRO_MD allow unauthorized content injection
-    ATTACK VECTOR: Between `[ -f "$MD_FILE" ]`/`[ -s "$MD_FILE" ]` checks and subsequent reads/appends, an attacker can replace MD_FILE with a symlink to sensitive files (e.g., /etc/passwd), leading to unauthorized content being appended t
- FILE: scripts/zuvo-home/reconcile-proposals.py:194-196
- ISSUE: Passing `ref=None` directly into `subprocess.run` raises an unhandled `TypeError` when `--ref` is omitted during write runs (`--apply`).
- FILE: scripts/zuvo-home/reconcile-proposals.py:167,240-244
- ISSUE: Refusals and mark failures are silently swallowed without propagating a non-zero exit code from `main()`.
- FILE: scripts/zuvo-home/reconcile-proposals.py:237
- ISSUE: Missing subprocess timeout allows indefinite hang if HELPER blocks
- FILE: scripts/zuvo-home/reconcile-proposals.py:apply_verdict
- ISSUE: `tgt` from deserialized TSV (`rowfile or target`) is passed unchecked to `known_sections()` and `HELPER --mark --file`
- FILE: scripts/zuvo-home/verify-tests:401
- ISSUE: Passing both suite and full spec path to `codecept run` causes test file lookup failure.
- FILE: scripts/zuvo-home/verify-tests:337
- ISSUE: `PHP_INI_SCAN_DIR` replaces compile-time directory without leading/trailing separator, unloading all core/shared extensions.
- FILE: scripts/zuvo-home/verify-tests:line:378-384 (context)
- ISSUE: Command duplication leading to execution failure in Codeception pipeline
- FILE: scripts/zuvo-home/verify-tests (codecept_suite function, around line 280)
- ISSUE: Relative path resolution in `codecept_suite` depends on the current working directory, causing incorrect suite detection when the script is run from a directory other than the project root.
- FILE: scripts/zuvo-home/verify-tests (php_coverage_env, around new code after line ~300)
- ISSUE: `php_coverage_env()` calls `glob.glob(...)` but the diff only adds `import shlex`, not `import glob`, to the import block shown.
- FILE: scripts/zuvo-home/verify-tests
- ISSUE: rc==0 unconditionally reports PASS even when zero tests were parsed
- FILE: scripts/zuvo-home/verify-tests:540
- ISSUE: `php_coverage_env()` is never passed to `run()`, causing coverage drivers (pcov/xdebug) to fail to load
- FILE: scripts/zuvo-home/verify-tests:557
- ISSUE: Per-class regex misses indented class names produced by php-code-coverage, permanently failing coverage gates
- FILE: scripts/zuvo-home/verify-tests:607
- ISSUE: Subdirectory test runner `runner["cwd"]` is ignored in favor of `cwd=root`, breaking monorepo setups
- FILE: scripts/zuvo-home/verify-tests:560
- ISSUE: Undefined `_Grp` helper causes `NameError` crash when `per_class` regex matches
-     FILE: scripts/zuvo-home/verify-tests:coverage_codecept (codecept_cmd call)
-     ISSUE: Unescaped YAML interpolation enables coverage include parameter pollution
-     FILE: scripts/zuvo-home/verify-tests:coverage_codecept (fallback lines/methods regex)
-     ISSUE: Fallback coverage regex matches first `Lines:`/`Methods:` line, not the Summary block
- FILE: scripts/zuvo-home/verify-tests:541
- ISSUE: `rc` from the codecept run is captured but never checked — a failing/erroring test run can still pass the coverage gate.
- FILE: scripts/zuvo-home/verify-tests (mutation_infection → record_survivors)
- ISSUE: PASS/FAIL is driven only by the parsed `survivors` list, not by Infection’s summary counts (`escaped`, `noc`).
- FILE: scripts/zuvo-home/verify-tests (~timeout handling before `record_survivors`)
- ISSUE: Runs where every mutant times out can still PASS: `decided == 0`, `survivors` empty, gap text only.
- FILE: scripts/zuvo-home/verify-tests:1161
- ISSUE: Aborted or crashing Infection runs silently pass quality gates
- FILE: scripts/zuvo-home/verify-tests:1194
- ISSUE: 100% mutant timeout rate results in false positive PASS
- FILE: scripts/zuvo-home/verify-tests:1074
- ISSUE: Gate passes when escaped mutants exist if stdout regex parsing fails
- FILE: scripts/zuvo-home/verify-tests
- ISSUE: Unhandled ValueError in regex parsing causes script crash on non-standard Infection output
- FILE: scripts/zuvo-home/verify-tests
- ISSUE: Missing cleanup for Stryker runner introduced in refactored block
- FILE: scripts/zuvo-home/verify-tests: (mutation_infection function, mutant path check)
- ISSUE: Mutant path matching uses case-sensitive unanchored string suffix matching, leading to false positives/negatives.
- FILE: shared/includes/model-registry.sh:80
- ISSUE: Automatic CLI downgrade in `codex_cli_guard()` will fail when invoking fallback models with `ZUVO_CODEX_EFFORT_PRIMARY="none"`.
- FILE: shared/includes/model-registry.sh:137
- ISSUE: Model variables contain shell metacharacters (spaces, parentheses) without sanitization
- FILE: shared/includes/model‑registry.sh:94 (line where `ZUVO_MODEL_CODEX_REVIEW_ALT` is set)
- ISSUE: Truncated variable expansion – the assignment `ZUVO_MODEL_CODEX_REVIEW_ALT="${ZUVO_MODEL_CODEX_REVIEW_ALT:-$ZUVO_MODEL_CODEX_AL` is syntactically invalid (missing `T}` and closing quote).
- FILE: shared/includes/model-registry.sh:280
- ISSUE: Default for ZUVO_MODEL_KIMI_CLI changed from empty (defer to CLI default) to hardcoded "kimi-code/k3-256k", breaking existing setups
**How to apply:** reproduce each against the current tree before fixing — several contradict each other (e.g. two about the codex version guard); treat them as review leads, not defects.

**Reproduced and CLOSED 2026-09-24** (each was reproduced against the tree first, then fixed with a
test that fails on the pre-fix code — see `tests/skill-suite/test-coverage-gate-php-surface.sh` and
`tests/hooks/test-verify-tests.sh`):

| Lead | Verdict | Where |
|---|---|---|
| `test-coverage-gate.py:568` anonymous class clears `$exposeProtected` for the rest of the file | REAL, fixed | `T_NEW` look-behind skips the anon `T_CLASS` without touching the flag |
| `test-coverage-gate.py:~630` fallback `expose_protected` computed per FILE, not per class | REAL, fixed | `PHP_FALLBACK_CLASSISH` + `exposes_protected_at(offset)`; a trait beside a plain class no longer inventories the class's protected methods |
| `verify-tests` `record_survivors` PASS driven only by the survivor list (`decided == 0` passes) | REAL, fixed | zero-verdict guard: `decided <= 0` → FAIL with an explicit "nothing was measured" gap |
| `verify-tests:1194` 100% mutant timeout rate reports PASS | REAL, fixed | same guard; timeouts were already excluded from the score, but the empty survivor list still read green |
| Stryker path scores a timeout as a kill (the JS twin of the Infection rule, NOT in the lead list) | REAL, fixed | `decided = killed + survived + noc`; timeouts reported separately as "no verdict, excluded" |
| `adversarial-review.sh` evidence prune is the one unguarded command under `set -e` | REAL, fixed | `\|\| true` — a prune losing a race killed the script before it wrote the diagnostic that path exists to produce |

Everything above this table is still LIVE and unverified. Two of the remaining leads are known to be
wrong as stated (`php_coverage_env` "missing `import glob`" — `verify-tests:68` imports it at module
level; `model-registry.sh:94` "truncated assignment" — the assignment is at line 100, complete, and
`bash -n` is clean, so the truncation was in the reviewer's own line wrapping), but
they have not been individually dispositioned, so treat the list as leads, not as a defect count.

## B-20260924-ADVERSARIAL-CHUNK-DRIVER-COMMAND-NOT-FOUND — LIVE

`adversarial-review.sh` (zuvo 1.6.80 cache) failed one chunk of a 3-chunk multi review with `line 3792: first successful provider: command not found` after two providers failed/timed out (byteplus-alt timeout, muse empty) — the aggregate exit became 127 and that chunk's files were NOT reviewed. Seen 2026-09-24 on tgm-survey-platform test/cva-e2e-0924 (chunk 2/3, 27 890 chars). A string is being executed as a command on the partial-failure path.
**How to apply:** find line ~3792 in the released script (and the repo copy), reproduce with two failing providers in one chunk, fix the quoting/eval, and make a failed chunk re-run instead of silently dropping coverage.

## B-20260925-ADV-LEDGER-PARTIAL-KILL — LIVE (reproduced by reading, not by running)

Found reviewing 4953148a for push coverage (proof zuvo/proofs/parallel-4953148-f3c31b1.txt, 5
providers, 22 findings). NOT this session's code — left for that work's owner rather than edited
underneath them.

**What:** 4953148a split `provider_outcomes=none` into `none` (nothing ran) and `interrupted`
(killed with a non-empty `DISPATCHED_LIST`), which is right. The PARTIAL case is still ambiguous:
if provider A returns and provider B is still in flight when an outer `timeout`, a reaped process
group or Ctrl-C arrives, `PROVIDER_OUTCOMES` is non-empty, the first branch fires, and the ledger
records A's verdict as though the run completed. A lane diagnosed from that row still mistakes
partial coverage for a full verdict — the same misdiagnosis the commit set out to end, in the
case most likely to occur (one slow provider is exactly what an outer timeout kills).

**Fix:** the two reviewers converged on the same shape — compare the dispatch list against the
outcomes rather than testing outcomes for emptiness. If `DISPATCHED_LIST` names a provider absent
from `PROVIDER_OUTCOMES`, the run was cut short: record the partial outcomes AND the marker
(`provider_outcomes=<partial>,interrupted`), so the row states both what was collected and that
something was not. Empty outcomes keep today's two branches.

**Also worth the owner's eye** (same proof, not reproduced here):
`tests/adversarial/test-failure-evidence-meta.sh` fe.3 accepts ANY non-`none` outcome as success,
so it cannot distinguish `interrupted` from a malformed value; fe.4 asserts the `none` branch by
grepping the SOURCE for the printf rather than executing it, which passes against a file that no
longer runs that branch; and the kill test's synchronisation is timing-based and can leak the
`mock-hang` process.

**Note on wiring:** the commit message says the new test is "wired into the default gate". It is
picked up by `tests/adversarial/run.sh` (which globs `test-*.sh`), but the default runner only
invokes that driver under `SCOPE=full` (`tests/run-all.sh:184-187`), so the default scope does
not execute it. The adversarial suite was therefore run separately for this push.

<!-- refactor-radar run on tgm-panel @497126674, 2026-09-25 (report: tgm-access zuvo/reports/refactor-radar-20260925T151251Z-rhohKW) -->
- [ ] B-20260925-RADAR-BB-CENSUS-ONE-404 [P2][correctness][conf 90]
**Fingerprint:** scripts/lib/radar_remote.py|correctness|bb-census-fails-whole-on-one-diffstat-404
**Source:** refactor-radar/2026-09-25 tgm-panel; severity:medium.
**What:** `bitbucket()` fetches every open PR's diffstat in one loop, so a single `HTTPError` aborts the census: `bb: PR census incomplete (HTTPError)`, every row gets `availability=UNKNOWN`, and 21 good PRs are lost with it. On tgm-panel the cause was two 2021 zombie PRs (#123, #494) whose source branches are gone, so diffstat returns 404. The error message does not name the PR either.
**Fix:** catch per PR and record `{"id": n, "error": "404"}` in `evidence["errors"]`. Keep the other PRs' paths. Mark the census incomplete only for that PR's unknown paths, not all rows. Optionally add a profile `pr_stale_days` so PRs untouched for N days become hints instead of BUSY.

- [ ] B-20260925-RADAR-COVERAGE-PCOV-CASE-LABELS [P3][false-positive][conf 80]
**Fingerprint:** scripts/lib/radar_coverage.py|false-positive|pcov-case-labels-and-signatures-count-as-missed
**Source:** refactor-radar/2026-09-25 tgm-panel; severity:low.
**What:** in the coverage lane, PHP clover from pcov reports `case` labels and the lines of multi-line constructor signatures as `stmt` lines with count 0. They inflate `missed`: `models/transactions/TransactionBuilder.php` ranked #97 with 26 "missed" statements, and all 26 are `case` labels in heavily tested methods. The `payouts/Domain/Exceptions/*` 2-line misses are signature lines.
**Fix:** at minimum, say so in `references/contract.md` under "Measured coverage". Better, for PHP drop `stmt` lines whose source text matches `^\s*(case\b.*|default)\s*:` and continuation lines of a signature before counting.

- [ ] B-20260925-RADAR-COVERAGE-UNRELEASED [P3][release][conf 95]
**Fingerprint:** scripts/refactor-radar.sh|release|coverage-lane-not-in-installed-bundle
**Source:** refactor-radar/2026-09-25; severity:low.
**What:** `--mode tests --coverage` exists only on the unpushed branch `feat/radar-measured-coverage` (3f86f35, worktree `~/DEV/zuvo-plugin-worktrees/radar-coverage`). The installed `~/.zuvo/refactor-radar/current` has no `--coverage`, so the skill's Phase 1 "resolve the installed bundle first" rule points at a script without the feature. Its own test-audit also flagged `test_radar_coverage.py` for a tier-A re-audit.
**Fix:** finish the re-audit, merge, push and reinstall the bundle. Until then, SKILL.md tests mode should say that a missing `--coverage` means an unreleased feature, not UNKNOWN coverage.

- [ ] B-20260925-RADAR-UNCOVERED-METHODS [P4][feature][conf 60]
**Fingerprint:** scripts/lib/radar_coverage.py|feature|no-per-row-uncovered-methods
**Source:** refactor-radar/2026-09-25; severity:low.
**What:** a coverage row gives only file-level `covered/statements`. Every G4 validation needed to know which methods are uncovered, so I derived it ad hoc from the clover `type="method"` lines, and the same would be needed on every run. Separately, `meta.config_path` records an absolute local scratchpad path, which is not portable and leaks the host layout.
**Fix:** add `coverage.files[*].uncovered_methods: {name: [lines]}` from the clover method lines. Record the config hash plus basename, not the absolute path.

- [ ] B-20260925-APPEND-RUNLOG-DATELESS-LINE [P2][correctness][conf 90]
**Fingerprint:** scripts/zuvo-home/append-runlog|correctness|dateless-line-first-field-overwritten
**Source:** refactor-radar/2026-09-25 end-of-run logging; severity:medium.
**What:** `run-logger.md` says the wrapper "stamps `date -u` when absent". A 12-field line WITHOUT the DATE field (`refactor-radar\ttgm-access\t…`) came back as `2026-09-25T16:12:43Z\ttgm-access\t…`: the SKILL field was REPLACED by the date instead of the date being prepended. The line then failed `12 TSV fields, runs.log schema requires 13` and was NOT appended. A retry with an explicit date worked. Doc and code disagree.
**Fix:** when field 1 is not ISO-8601, prepend the date instead of overwriting, or reject with "field 1 must be DATE" and fix the doc sentence.

- [ ] B-20260925-APPEND-RUNLOG-INCLUDES-AUTO [P4][telemetry][conf 80]
**Fingerprint:** scripts/zuvo-home/append-runlog|telemetry|includes-auto-ambiguous-trackers
**Source:** refactor-radar/2026-09-25; severity:low.
**What:** `INCLUDES=AUTO` gave up with `98 include trackers in /tmp — cannot tell which belongs to this run; INCLUDES left as -`. With several concurrent sessions this is the normal state, so AUTO effectively always yields `-`, and no skill sets `ZUVO_INCLUDES_FILE`.
**Fix:** key the tracker file by session id (the hook knows it) and let append-runlog pick the current session's file. Also prune trackers older than a day.
**Re-observed:** 2026-10-03, zuvo:refactor 1f022802 on zuvo-plugin — `36 include trackers in /tmp`, INCLUDES left as `-` (seen:2).

- [ ] B-20260925-BACKLOG-HELPER-TABLE-FORMAT [P2][correctness][conf 90]
**Fingerprint:** scripts/zuvo-home/backlog-archive.py|correctness|table-format-backlogs-invisible
**Source:** backlog/2026-09-25 (adding 24 rows to tgm-panel); severity:medium.
**What:** `backlog-archive.py` parses only `- [ ]` bullet entries. tgm-panel (`| B-462 | HIGH | … |`, ~460 rows) and i9-farma keep the backlog as the protocol's own TABLE template. `verify --repo ~/DEV/tgmdev-tgm-panel` prints `OK disjoint: 0 open, 0 archived`, and `lookup "B-462"` returns ABSENT for a row that exists. The mandatory dedup step therefore passes every candidate as new on table backlogs, the exact duplicate-filing the protocol exists to stop.
**Fix:** parse table rows (`^\| B-[\w-]+ \|`) as entries, with the id from column 1 and the content key from the File and Finding/Problem columns. Or refuse with "table format not supported, dedup manually" instead of a false ABSENT.

## B-20260925-SHIP-BITBUCKET-PUSH-ONLY — ship has no terminal state for a non-GitHub PR the user must not merge

**File:** skills/ship/SKILL.md (Phase 0 step 2, Phase 4 Step 4, Completion Gate "PR flow only").
**Fingerprint:** ship/SKILL.md|terminal-state|non-github-no-merge
**Source:** zuvo:ship run 2026-09-25 (tgmdev-tgm-panel, PANEL-1502, PR #1396 on Bitbucket); severity:medium.
**What:** The user asked to "push without merge" to an existing Bitbucket PR. Ship's only outcomes for that shape are `SHIP INCOMPLETE: branch pushed, PR not created (non-GitHub forge)` (false — the PR exists) or a merge (forbidden by the user). The run had to be logged as WARN with a hand-written note. The CI verdict is also unreachable: the Bitbucket build status needs a token (here from 1Password) that ship does not know about.
**Fix:** A `PR_OPEN_BY_USER` terminal state, read from the invocation (not an agent-typable flag): branch pushed, existing PR found via the forge API (Bitbucket `pullrequests?q=source.branch.name=…`), its build statuses read and reported. Plus a forge adapter for Bitbucket PR lookup/status next to the `gh` path.
**Defer-reason:** found while shipping another repo.

## B-20260925-ZMS-RUN-SIX-JOBS — `_zms_run` is six responsibilities in one 120-line function

**File:** scripts/lib/model-subprocess.sh:417-565
**Fingerprint:** scripts/lib/model-subprocess.sh|structural-refactor|zms-run-god-function
**Source:** zuvo:review of 06abc33..23fe52b, Structure Auditor STRUCT-1; severity:medium.
**What:** ~120 executable lines against the repo's 50-line limit, mixing argument parsing, four independent validation categories (model, access+read-root, timeout, prompt/stderr files), timeout- and client-binary resolution, temp-dir and trap lifecycle, per-client argv construction (codex and claude branches each with their own arrays), and process launch/wait.
**Fix:** extract `_zms_parse_run_args`, `_zms_validate_run_args`, `_zms_build_codex_args`, `_zms_build_claude_args`; leave `_zms_run` as orchestration. tests/hooks/test-adversarial-lane-golden.sh already pins the observable behaviour byte-for-byte against golden fixtures, so the refactor is protected before it starts.
**Defer-reason:** structural-refactor (multi-site) — zuvo:refactor territory, not an unrelated diff's fix loop.

## B-20260925-TIMEOUT-BIN-TWO-COPIES — timeout detection exists twice with diverging capability

**File:** scripts/adversarial-review.sh:100-103 vs scripts/lib/model-subprocess.sh:203-205
**Fingerprint:** scripts/adversarial-review.sh|duplication|timeout-bin-diverged
**Source:** zuvo:review of 06abc33..23fe52b, Structure Auditor STRUCT-2; severity:medium.
**What:** the driver hard-codes the literal `timeout` (both to probe `-k` support and to invoke), while the library's `_zms_timeout_bin` falls back to `gtimeout`. Post-refactor the codex and claude lanes therefore tolerate a gtimeout-only PATH and agy / cursor-agent / muse / kimi / mock do not. Two independently-typed answers to "is a timeout wrapper available and under what name", with nothing keeping them equal — the exact duplication the library was created to remove, surviving in the half nobody extracted. Not introduced by that refactor: the driver's side is pre-existing, the library only widened the other one.
**Fix:** expose `zms_timeout_bin` as public and route the driver's six other call sites through it; or state in the lane table why only codex/claude get the wider fallback.
**Defer-reason:** structural-refactor (multi-site) — six call sites across two files.

## B-20260925-ADV-CHUNK-TRUNCATES-SINGLE-FILE — the driver truncates an oversized single file instead of splitting it, and the gate blames the wrong thing

**File:** scripts/adversarial-review.sh (chunker), hooks/lib/pipeline-gate-lib.sh (pg_artifact_proven)
**Fingerprint:** scripts/adversarial-review.sh|correctness|single-file-truncation-and-misleading-gate
**Source:** zuvo:review of 06abc33..23fe52b — three adversarial attempts needed before a clean proof; severity:high.
**What:** the chunker splits on `diff --git` file boundaries. A single file whose diff exceeds ZUVO_ADV_MAX_CHARS has no boundary to split on and is TRUNCATED, recording `input_truncated=true` and exit 4. Measured on this range: whole-range pass 32 reviews / 3 truncations; per-file pass 42 / 2 (adversarial-review.sh at 37 KB and model-subprocess.sh at 34 KB each truncated on their own); only a hand-built hunk split reached 55 reviews / 0 truncations. A truncated pass says nothing about the files it never sent, yet its artifact carries the same "REVIEW BY:" lines as a complete one.
Two diagnostics point away from the cause. `pg_artifact_proven` rejects on the truncation marker BEFORE it counts providers, but the refusal reads `<2 'REVIEW BY:' lines` — so a proof with 32 providers is reported as having fewer than two. And `review-artifact-sync.sh --check` called the same file `OK (REVIEW BY x55)` while the push gate refused it: two readers of one artifact giving opposite answers, which is what finally forced reading the gate's source.
**Fix:** hunk-split inside the chunker when one file exceeds the cap; for a NEW file (one `@@ -0,0 +1,N @@` hunk, no boundary at all — the documented staircase in adversarial-loop.md stops at hunk boundaries and does not cover this) split the hunk body and recompute the header. Make the gate's message name the truncation and list the omitted files. Make the two readers agree, or have the lenient one say which check it does not perform.
**Defer-reason:** tooling fix outside the reviewed diff; worked around by hand this run.

## B-20260925-CODEX-READ-ACCESS-UNENFORCED — `--access read` bounds claude but not codex

**File:** scripts/lib/model-subprocess.sh (access mode case, codex branch)
**Fingerprint:** scripts/lib/model-subprocess.sh|security|codex-read-root-advisory
**Source:** zuvo:review of 06abc33..23fe52b, adversarial CRITICAL (the one of eight that survived triage); severity:medium.
**What:** `--access read` validates `--read-root` carefully — required, must be a directory, resolved absolute AND physical with CDPATH cleared so a symlink or a relative redirect cannot move the boundary. Then the codex branch cannot enforce it: `read) args+=(-s read-only --disable view_image)` with the comment `# the shell stays; --read-root is advisory`. Claude's branch passes `--add-dir`, which the client does enforce. So the same flag means "bounded" for one client and "read-only, unbounded" for the other. Disclosed in the code, and no caller in this range relies on it (the lanes use `--access agent`) — but a future caller reading the flag name has no reason to expect the asymmetry.
**Fix:** either give codex an equivalent boundary when the CLI grows one, or rename/split the mode so the weaker guarantee is visible at the call site (`--access read-unbounded` for codex), and say so in the access-mode table.
**Defer-reason:** not introduced by this diff; needs a decision about the mode's contract, not a patch.

## B-20260925-BYTE-IDENTICAL-EDGE-UNLISTED — a behaviour difference outside the refactor's own "intended differences" list

**File:** scripts/lib/model-subprocess.sh:468-471
**Fingerprint:** scripts/lib/model-subprocess.sh|correctness|timeout-missing-exit-code-change
**Source:** zuvo:review of 06abc33..23fe52b, Structure Auditor STRUCT-5; severity:low.
**What:** commit 58d77d98 claims the extracted runners are byte-identical to the inline versions and lists five intended differences. Verified — argv order, CODEX_HOME scoping, prompt delivery and cwd all match, and the five are real. One difference is not on the list: with no GNU `timeout` and no `gtimeout` anywhere, the old inline path failed at invocation with `timeout: command not found` (127); `_zms_run` now detects the missing binary up front and exits 2 with its own diagnostic. Both end in lane failure, so nothing breaks — but a claim of byte-identical with an unlisted exception is the kind of small untruth that makes the next reader trust the list less. Reachable on stock macOS, which ships no `timeout`.
**Fix:** add it to the commit's list in the file header, or map the missing-binary case back to 127.
**Defer-reason:** documentation of an already-verified claim; no behaviour at risk.

## B-20260925-ZMS-GATE-DISAGREEMENT — two functions disagree about whether a Codex host has anything to exclude

**File:** scripts/adversarial-review.sh:1392 (detect_host_platform) vs :1543 (client_available)
**Fingerprint:** scripts/adversarial-review.sh|correctness|zms-loaded-gate-inconsistency
**Source:** zuvo:review of 06abc33..23fe52b, Structure Auditor STRUCT-4; severity:low.
**What:** the host-exclusion branch is gated on `[[ -n "$ZMS_LOADED" ]] && zms_is_codex_host`, justified in-code as "there is nothing to exclude" when the library is missing. But `client_available codex` falls back to a bare `command -v codex` when `ZMS_LOADED` is empty, so codex-5.3 CAN still be listed in that state — it just fails later via `runner_ready` (exit 2). Net effect is fail-loud, not silent self-review, so nothing is exploitable; the two functions simply hold opposite beliefs about the same premise. `zms_is_codex_host` is pure environment inspection and costs nothing to run, so the gate buys nothing either.
**Fix:** drop `client_available`'s degraded PATH fallback for codex (matching the "nothing works" premise), or make the host-signal check independent of `ZMS_LOADED`.
**Defer-reason:** degrades safely; touching either side changes lane availability and deserves its own diff.

## B-20260925-WRITE-TESTS-EMPTY-VS-INFRA — `empty` routes write-tests into a degraded reviewer when the cause was infrastructure

**File:** skills/write-tests/SKILL.md (Step 3 primary path), shared/includes/test-reviewer-routing.md
**Fingerprint:** skills/write-tests/SKILL.md|correctness|empty-conflated-with-no-provider
**Source:** observed 2026-09-23/25 while diagnosing the codex lane; severity:medium.
**What:** the fallback into the same-environment reviewers (`adversarial-test-reviewer`, `blind-coverage-auditor`) triggers on "primary path missing/empty". This session proved `empty` does not mean "no provider answered": a dead local CodeSift daemon plus `required = true` in the repo's `.codex/config.toml` made the codex lane return empty on 19 of 20 runs with a fully working account and model. An infrastructure failure therefore silently downgrades the run to a same-model reviewer, correctly LABELLED degraded but chosen for the wrong reason — the case `cross-model-review-clients` warns about ("never downgrade on a preflight exit alone"). The neutral-cwd fix removed this particular trigger; the conflation remains.
**Fix:** distinguish "the driver reported no usable provider" (exit 3 / empty PROVIDERS) from "providers were dispatched and something killed them" — the driver now records `interrupted` and `dispatched=` in its failure meta, so the signal exists. Route the second to `BLOCKED_INFRA` with the reason, not to fallback-local.
**Defer-reason:** asked the user, no decision yet; touches the routing contract, not a one-line fix.

## B-20260925-ADVLOG-LINE1-STALE — the ledger's first line still advertises the old schema

**File:** ~/.zuvo/adversarial.log (data), scripts/adversarial-review.sh init_log_header
**Fingerprint:** scripts/adversarial-review.sh|correctness|adversarial-log-line1-stale
**Source:** observed 2026-09-23 while aggregating the ledger; severity:low.
**What:** the live ledger's line 1 is the 14-column header it was created with, while its rows carry 17 fields. The appended `#schema` marker is now correct (the sentinel fix) and self-heals, but nothing rewrites line 1 — deliberately, because parallel runs hold the inode open. A reader taking line 1 as the schema maps `provider` onto `outcome`; that is exactly how an aggregation of this file produced "every lane failed 100% of its runs" in this session.
**Fix:** have the readers prefer the last `#schema` line over line 1, and say so where the format is documented. Rewriting line 1 stays off the table for the reason already in the code.
**Defer-reason:** the marker makes the file self-describing for anyone who reads it; the trap is for readers who do not.

## B-20260925-CODESIFT-AGENTS-SILENT-DEGRADE — two write-tests agents lose their main tools without saying so

**File:** skills/write-tests/agents/blind-coverage-auditor.md, skills/write-tests/agents/adversarial-test-reviewer.md
**Fingerprint:** skills/write-tests/agents|correctness|codesift-absent-silent-degrade
**Source:** observed 2026-09-25 (CodeSift daemon on 127.0.0.1:7077 dead for the whole session); severity:medium.
**What:** both agents declare the full `mcp__codesift__*` set in `tools:` because answering "is this behaviour covered" needs every branch and every caller, not one file. When the daemon is down they fall back to Read/Grep/Glob and still produce a verdict, with nothing in their output saying the coverage claim was made without the tools it was designed around. A coverage audit that could not enumerate callers is not the same audit, and reads identically.
**Fix:** have each agent record a `codesift: available | degraded(<reason>)` line in its report, and have the caller propagate it into the coverage verdict rather than absorbing it.
**Defer-reason:** agent-contract change; wants doing once for all CodeSift-dependent agents, not twice here.

## B-20260925-CODEX-SMALL-STALE — the Codex small tier still names the previous generation

**File:** shared/includes/model-registry.sh (ZUVO_MODEL_CODEX_SMALL)
**Fingerprint:** shared/includes/model-registry.sh|maintenance|codex-small-tier-stale
**Source:** noticed 2026-09-25 while repointing the codex lanes to GPT-6; severity:low.
**What:** `ZUVO_MODEL_CODEX_SMALL` is `gpt-5.6-luna` — what the Codex build resolves an abstract `haiku` agent to. `gpt-6-luna` is a generation newer and half the price ($0.10/$0.50 vs the 5.6 family), and the lanes moved. Not a defect: the 5.6 id still answers on this account, and the small tier serves a different consumer than the adversarial lanes, so it was left alone rather than swept along.
**Fix:** probe `gpt-6-luna` as the small tier and repoint if it answers; it is already proven on this account by the codex-5.4 lane.
**Defer-reason:** different consumer from the lanes this session measured; raised with the user, no decision.

## B-20260925-ADV-TRUNC-LOCKFILE-BLOCKS-PUSH — a truncated lockfile chunk voids the whole adversarial proof

**File:** scripts/adversarial-review.sh (`--diff`), hooks/lib/pipeline-gate-lib.sh:380
**Fingerprint:** scripts/adversarial-review.sh|gate|lockfile-truncation-voids-proof
**Source:** tgm-panel PANEL-1500 push, 2026-09-24; severity:medium.
**What:** `--diff origin/develop` fed the 98K-char `composer.lock` diff in as its own chunk; it was cut to 30K (`input_truncated=true`) and the pre-push gate then rejected the WHOLE proof ("<2 REVIEW BY") for all 10 production files, though they were reviewed untruncated in other chunks. The error text names the wrong cause — the proof had 20 REVIEW BY lines.
**Fix:** exclude lockfiles (composer.lock, package-lock.json, yarn.lock, pnpm-lock.yaml) from `--diff` by default, or record truncation per chunk/file so the gate voids only the truncated files; name `input_truncated` in the gate message.
**Workaround used:** pipe `git diff … -- . ':(exclude)composer.lock' ':(exclude)package-lock.json'` on stdin.

## B-20260925-ADV-KILLED-CHUNK-COUNTS-AS-REVIEWED — a run killed mid-way still grants coverage for its unrun chunk

**File:** scripts/adversarial-review.sh (artifact writing), hooks/lib/pipeline-gate-lib.sh (proof check)
**Fingerprint:** scripts/adversarial-review.sh|gate|killed-run-partial-proof
**Source:** tgm-panel PANEL-1500, 2026-09-24; severity:medium.
**What:** a 3-chunk run killed by the caller's `timeout 900` left a proof with chunks 1-2 only (9 REVIEW BY lines, `input_truncated=false`) and nothing saying chunk 3 never ran. Chunk 3 held `widgets/JoditEditor.php` — the core file — and the gate would have accepted it as reviewed. Found only by grepping which files the findings cited.
**Fix:** write `chunks_planned=` / `chunks_done=` (or the per-chunk file list) up front and have the gate treat a proof with done < planned as covering only the done chunks' files.

## B-20260925-ARCHIVE-CONFLICT-ON-RE-REVIEW — `--archive` refuses an artifact updated by a later review pass

**File:** scripts/zuvo-home/review-artifact-sync.sh (--archive)
**Fingerprint:** review-artifact-sync.sh|archive|conflict-on-updated-artifact
**Source:** 2026-09-24; severity:low.
**What:** after a second adversarial pass updated the same `memory/reviews/<range>.md` (new `adversarial:` path), `--archive` printed `CONFLICT … not overwriting (resolve by hand)` — the ordinary re-review flow always hits this, and the archive silently keeps the stale header pointing at the superseded proof.
**Fix:** overwrite when the new artifact is a strict superset / newer mtime from the same checkout, keep the old one as `.prev`.

## B-20260925-APPEND-RETRO-ENUM-DISCOVERY — valid values surface one rejection at a time

**File:** scripts/zuvo-home/append-retro, append-runlog
**Fingerprint:** append-retro|usability|enum-values-on-failure-only
**Source:** 2026-09-24; severity:low.
**What:** `append-retro --help` → "unknown arg"; wrong `--code-type`, then `--blind-audit`, then `--adversarial` each rejected in a separate run (3 round-trips; only code-type lists its valid values up front). `append-runlog --help` is treated as a run line ("2 TSV fields … NOT appended").
**Fix:** support `--help` in both; validate every field before exiting and print each invalid field WITH its allowed values in one pass.

## B-20260925-ADV-LOG-NO-HOST — the adversarial ledger does not record the host, so lane choices cannot be audited

**File:** scripts/adversarial-review.sh (LOG_HEADER / row writer)
**Fingerprint:** scripts/adversarial-review.sh|observability|ledger-has-no-host-column
**Source:** 2026-09-25 session (claude-lane Opus/Sonnet analysis); severity:low.
**What:** `~/.zuvo/adversarial.log` has model, provider, outcome and project but not `HOST_PROVIDER`. Asked "how many of the 850 Sonnet reviews were launched from Codex and could have used Opus?", the ledger cannot answer; neither can it show how often host self-exclusion removed kimi/codex/agy.
**Fix:** append a `host` column (column 18) through the same schema-marker path as column 17; empty = no host detected.

## B-20260925-ADV-QWEN-THINKING-NOT-LANE-CONTROLLED — qwen lane speed depends on the owner's ~/.qwen/settings.json

**File:** scripts/adversarial-review.sh (run_qwen)
**Fingerprint:** scripts/adversarial-review.sh|qwen|thinking-mode-not-controlled-by-lane
**Source:** 2026-09-25 production ledger; severity:medium.
**What:** qwen3.8-flash WITH thinking timed out at 500 s on 3 of 4 real 24-30k-char diffs (bench average 229 s on smaller inputs — bench time was read as production time). Thinking is set per model in `~/.qwen/settings.json` (`generationConfig.extra_body.enable_thinking`), not by the lane, so the lane's speed is whatever the interactive setup says. Without thinking, a bare prompt makes the model call a tool at once and `--max-tool-calls 0` aborts (exit 55); the lane's no-tools trailer is what keeps it working (52 s, 7 findings on the 24k diff).
**Measured 2026-09-25 (`tp-qwen3.8-flash-nt`, Fable judge):** without thinking the lane is fast (50 s average) but 5 of 20 reviews aborted with exit 55 — the model called a tool despite the no-tools trailer — and on the 13 inputs both variants answered, REAL fell from 63 to 44 and precision from 71% to 57%. So no-thinking is not a fix. With thinking, a trivial prompt took 266 s the same evening, which puts part of the latency on the API side, not the CLI.
**Fix:** a direct Token Plan API lane (B-20260925-ADV-QWEN-CLI-OVERHEAD) removes the tool aborts; it does not remove thinking latency, so it only makes sense with a per-lane timeout that keeps a slow qwen from setting the run's wall clock. Until then the lane stays off in the owner's ~/.zshenv. Also: `run_qwen` reports exit 55 as "no parsable result" — name it ("model attempted a tool call").

## B-20260925-ADV-QWEN-CLI-OVERHEAD — the qwen lane pays ~12.5k input tokens of Qwen Code scaffolding per review

**File:** scripts/adversarial-review.sh (run_qwen)
**Fingerprint:** scripts/adversarial-review.sh|qwen|cli-system-prompt-overhead
**Source:** 2026-09-23 smoke test of all Token Plan models; severity:low.
**What:** every `qwen -p` call carries ~12.5k input tokens of the CLI's own system prompt and tool schemas before the diff, and the CLI's tools are what caused 13/200 "workspace is empty" non-reviews (fixed in d72752e4). The CLI route was chosen because Coding Plan forbids scripted key use; the owner's plan is Token Plan, whose docs carry no such clause.
**Fix:** a curl lane on `token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1` via `run_openrouter` (BytePlus pattern, same plan-host guard) — no tools, no scaffolding, thinking set in the request.

## B-20260925-ADV-BYTEPLUS-GLM-TIMEOUTS — glm-5.3-flash times out on 35% of calls

**File:** scripts/adversarial-review.sh (byteplus lane), ~/.zuvo/adversarial.log
**Fingerprint:** scripts/adversarial-review.sh|byteplus|glm-53-flash-timeouts
**Source:** 24 h ledger to 2026-09-25; severity:medium.
**What:** byteplus (glm-5.3-flash): 57 timeouts in 161 calls, median 220 s, slowest lane in 127 runs, benched at the time of checking. The model is good on the bench (95% precision, 15 defects unique in the set) — the problem is latency under the 500 s cap, not quality.
**Fix:** measure it with thinking off / a lower reasoning setting, or give it a shorter per-lane timeout so it stops setting the run's wall clock.

## B-20260925-ADV-PINNED-LANE-BENCHED — a pinned lane on the bench leaves its slot to chance

**File:** scripts/adversarial-review.sh (fan-out pin + provider bench)
**Fingerprint:** scripts/adversarial-review.sh|fanout|pinned-lane-benched
**Source:** 2026-09-25 `--doctor`; severity:medium.
**What:** agy (pinned) was benched after 8 consecutive empty answers (24 h: 22 timeouts + 12 empties in 464 calls). While a pinned lane is benched, its slot goes back to the random draw with no notice that the highest-marginal reviewer is missing from every run.
**Fix:** when a pinned lane is benched, say so in the run header and the artifact, and consider promoting the next pin candidate (cursor-agent is pinned beside it since 190a01b1).

## B-20260925-ADV-CODEX-SOL-LOW-YIELD — codex-5.3 (gpt-6-sol/none) returns a bare "NO ISSUES FOUND" 30% of the time

**File:** shared/includes/model-registry.sh (ZUVO_CODEX_EFFORT_PRIMARY), ~/.zuvo/adversarial.log
**Fingerprint:** model-registry.sh|codex|sol-low-marginal-yield
**Source:** 24 h ledger to 2026-09-25 + 2026-09-23 effort bench; severity:low.
**What:** 351 calls, 100% ok but 30% are a 17-char "NO ISSUES FOUND.", 1.7 findings per review, 5 defects unique on the bench. Raising effort makes it worse (medium: 100% precision, 0 unique) — the registry already documents "the effort dial runs backwards". xhigh/max never measured.
**Fix:** decision, not code: keep it as the cheap high-precision voice, or drop it from the draw so its slot goes to a higher-marginal lane.

## B-20260925-ADV-KIMI-HOST-PATH-FALSE-POSITIVE — ~/.kimi-code/bin on PATH marks any shell as a Kimi host

**File:** scripts/adversarial-review.sh (detect_host_platform)
**Fingerprint:** scripts/adversarial-review.sh|host|kimi-path-false-positive
**Source:** 2026-09-25 `--doctor` from a Claude Code session; severity:low.
**What:** the documented, accepted false positive fired in practice: this Claude Code session's PATH contains `~/.kimi-code/bin`, so the driver reported "Host detected: kimi" and excluded both kimi lanes. Any agent session with that PATH loses the kimi reviewer silently (kimi also hit its plan quota 11× in the same 24 h).
**Fix:** check a Kimi-specific process ancestor or env first; fall back to PATH only when no other host matched (CLAUDECODE already identifies this case).

## B-20260925-ADV-LANE-FAIL-NO-REASON — a claude lane failure can leave an empty stderr

**File:** scripts/lib/model-subprocess.sh (zms_run_claude), scripts/adversarial-review.sh (run_claude)
**Fingerprint:** model-subprocess.sh|observability|claude-exit1-empty-stderr
**Source:** 2026-09-25 `--doctor` under `env -i`; severity:low.
**What:** with a stripped environment the claude lane exited 1 with an empty `err_claude.txt` — the failure evidence says nothing about why (likely missing USER/TMPDIR for the CLI's auth). The same call works in a normal environment, so this bites only unusual hosts, where diagnosis matters most.
**Fix:** when the child's stderr is empty, record its exit code, the argv (minus the prompt) and the env keys it lacked into the evidence file.

## B-20260925-TESTS-ADV-PREEXISTING-REDS — 8 adversarial tests red on a clean HEAD — DONE 2026-10-02

**Closed 2026-10-02 (fix/adv-reds-and-lint):** every case named below is green on 14d05ff3 —
test-input-chunking 23/23, test-hard-timeout-and-suspend 27/27, test-artifact-provenance 34/34,
"PROJECT self-resolves" PASS; the full `tests/adversarial/run.sh` is 1022/1022. The reds that
remained on that HEAD were different ones, each fixed at its cause: test-kimi-effort (12) and
qwen qw.8 (1) — the runner's `~/.kimi-code/bin` login-PATH entry read as a Kimi Code host, plus a
real ordering bug where that PATH probe shadowed `QWEN_CODE=1`; test-session-retro-carry T6.3 —
8a99e5f3 grew session-state.md by the reviewer-route map without re-baselining the ratchet.

**File:** tests/adversarial/test-input-chunking.sh, test-hard-timeout-and-suspend.sh, test-artifact-provenance.sh
**Fingerprint:** tests/adversarial|reds|ck11-ht7-prov6-preexisting
**Source:** 2026-09-23/25, reproduced on a clean HEAD worktree via rt; severity:medium.
**What:** CK.11/CK.12/CK.13 (doc-mode chunking at h2 / content lost / fenced headings), HT.7 (expects 16 columns, ledger has 17), PROV.6 and PROV.11 (known-finding block / type-variant rule missing from the prompt), "PROJECT self-resolves to git basename". A further 21 installer/retro/watchdog reds appear under `rt` only and match the runbook's farm-environment note, but were not re-verified locally.
**Fix:** triage each: stale assertion (HT.7 after column 17) vs. real regression (PROV.6/11, CK.*).

## B-20260925-BENCH-JUDGE-MODEL-LEAKS — judge-model.sh still drops unparsable verdicts and leaks MCP servers

**File:** ~/.zuvo/bench/judge-model.sh (bench harness, see docs/runbook/model-benchmark.md)
**Fingerprint:** judge-model.sh|bench|no-raw-save-and-mcp-orphans
**Source:** 2026-09-24 benchmark; severity:medium.
**What:** judge-lane.sh was fixed this session (raw response saved before parsing; `--strict-mcp-config` with an empty list). The Opus judge `judge-model.sh` has neither: an unparsable answer (e.g. "session limit") is discarded after being paid for, and every `claude -p` starts the owner's MCP servers — sentry-mcp orphans reached ~30 GB RAM in one judging wave.
**Fix:** port both changes; better, make judge-model.sh a thin wrapper over judge-lane.sh with JUDGE_MODEL set.

## B-20260925-BENCH-VERDICTS-NO-JUDGE — verdict files do not say which model judged them

**File:** ~/.zuvo/bench/judge2/verdicts-*.tsv, judge-lane.sh, judge-model.sh
**Fingerprint:** judge-lane.sh|bench|verdicts-lack-judge-model
**Source:** 2026-09-25 88-model comparison; severity:low.
**What:** Opus- and Fable-judged verdicts sit side by side with nothing recording the judge, so the comparison table had to mark ~40 rows "O/F (unknown)". Cross-judge comparisons are therefore approximate by construction.
**Fix:** add a `judge` column (or a sidecar `.judge` file per label) written by both judge scripts.

## B-20260925-BENCH-REFERENCE-SET-STALE — evaluate-model.py's "NEW" is measured against lanes that no longer run

**File:** ~/.zuvo/bench/evaluate-model.py (OTHERS)
**Fingerprint:** evaluate-model.py|bench|others-set-not-current-lanes
**Source:** 2026-09-25; severity:low.
**What:** OTHERS = {cursor-agent, codex-5.3, gpt-5.4, kimi, z-ai/glm-5.3, qwen/qwen3.8-flash} — a historical set, not the lanes the driver runs today. Marginal coverage against the CURRENT set (286 defects) ranks candidates differently (e.g. claude-opus-5-5-high 40 -> 24, gemini-3.8-flash 32 -> 16).
**Fix:** derive the reference set from `--list-providers` + provider_model mapping, and report both columns.

## B-20260925-BENCH-PARALLEL-REDO-RACE — parallel redos of one model rewrite the same results file

**File:** ~/.zuvo/bench/subs/finish-qwen-bench.sh, run-qwen-bench.sh
**Fingerprint:** finish-qwen-bench.sh|bench|shared-tmp-rewrite-race
**Source:** 2026-09-24; severity:low.
**What:** 8 concurrent redos of `tp-deepseek-v4-flash-0731` each rewrote `results-<label>.tsv` through the same `.tmp` name: the header and 12 rows were lost (rebuilt from logs; corrupt copy in `subs/redo-old/`). A hand-sharded worker also wrote a row with an empty input id.
**Fix:** one writer per results file (append-only rows from workers, dedupe at read time) or a mkdir lock around the rewrite.

## B-20260925-BENCH-JUDGE-NO-BUDGET — the judge runs into the Claude session limit mid-wave

**File:** ~/.zuvo/bench/judge-lane.sh
**Fingerprint:** judge-lane.sh|bench|no-subscription-budget-check
**Source:** 2026-09-24 (twice: "resets 4am", "resets 1pm"); severity:low.
**What:** 29 of the judge's answers were the subscription-limit notice. Raw saving makes the retry free, but the wave keeps calling for minutes after the first limit answer, and the judge also iterates `judge2/raw/` as if it were a packet ("[brak] raw").
**Fix:** stop the wave on the first limit notice and print the reset time; skip non-packet dirs (require `CODE.diff`).

## 2026-09-27 Plan A (shared reviewer runner) — deferred and out-of-fence findings

Source: zuvo:execute Plan A (docs/specs/2026-09-25-reviewer-subprocess-foundation-plan.md) per-task
adversarial passes, the Phase Final test audit (zuvo/audits/test-quality-audit-2026-09-25-plan-a.md)
and the aggregate zuvo:review (memory/reviews/2026-09-27-plan-a-aggregate.md). Everything inside
Plan A's fence was fixed in-run (eefd0d09, 8f2d4f58, de5d937a); these are the design limits and the
pre-existing debt the passes surfaced outside it.

- [ ] B-20260927-ZMS-ESCAPED-DESCENDANT [P2][design-limit][conf 90]
**Fingerprint:** scripts/lib/model-subprocess.sh|design-limit|term-ignoring-descendant-leaves-process-group
**What:** a TERM-ignoring descendant that leaves the timeout's process group (setsid, re-parented to 1) survives TERM and budget expiry with real GNU timeout; `_zms_reap`'s ppid walk cannot reach a re-parented process. Documented at the `_zms_reap` comment.
**Fix:** a containment mechanism beyond process groups — a cgroup (Linux, `systemd-run --scope`) or a session/job leader that owns the tree — with a test that plants a setsid'd TERM-ignoring grandchild.

- [ ] B-20260927-CLAUDE-REVIEWER-MODEL-AUTHOR [P2][correctness][conf 80]
**Fingerprint:** scripts/adversarial-review.sh|correctness|claude-reviewer-model-assumes-opus-author
**What:** `claude_reviewer_model` treats an unset CLAUDE_MODEL as an Opus author (a Sonnet/Haiku session then gets a same-tier reviewer), and cursor-agent/agy hosts as non-Claude authors although they often run Claude models. Logic moved verbatim from 7907fe70.
**Fix:** Plan C (docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md) — route on the honest writer model from the router, not on CLAUDE_MODEL presence.

- [ ] B-20260927-CODEX-READ-NOT-CONFINED [P2][security][conf 90]
**Fingerprint:** scripts/lib/model-subprocess.sh|security|codex-read-access-not-confined
**What:** `zms_run_codex --access read` validates `--read-root` but never hands it to the client: the read-only sandbox blocks WRITES, not reads, so the shell tool can `cat` any file (probe P6, 2026-09-25). Only claude `read` is confined (`--add-dir`).
**Fix:** Plan C's test-audit batches must not rely on the root for codex; confine by content (prompt carries the files) or a real FS sandbox; keep the ADVISORY wording in the library header until then.

- [ ] B-20260927-CODEX-OAUTH-REFRESH-DISCARDED [P3][correctness][conf 70]
**Fingerprint:** scripts/lib/model-subprocess.sh|correctness|isolated-codex-home-discards-token-refresh
**What:** the isolated CODEX_HOME gets a COPY of auth.json; a token refresh during the run is written to the copy and discarded, so a long run can leave the user's real auth.json with a rotated-out refresh token (pre-existing in the driver's run_codex for months).
**Fix:** after the run, copy auth.json back iff it changed and the source is unchanged since the copy (compare mtime/hash), under a lock.

- [ ] B-20260927-TOML-MODEL-QUOTES [P4][correctness][conf 60]
**Fingerprint:** scripts/lib/model-subprocess.sh|correctness|toml-model-parse-keeps-quotes
**What:** `zms_codex_host_model` (and the driver's former sed) keep single quotes and trailing whitespace from `model = 'x' ` in config.toml.
**Fix:** strip both quote styles and trailing whitespace/comments; add rows to host_model_case.

- [ ] B-20260927-AUTH-STUB-SHORT-GENUINE [P4][false-positive][conf 50]
**Fingerprint:** scripts/lib/model-subprocess.sh|false-positive|short-genuine-review-mentioning-unauthorized
**What:** `zms_is_auth_stub` flags a genuine review under 600 bytes that mentions "unauthorized"/"requires login" (e.g. a finding about an auth check) as an auth failure.
**Fix:** require the token near the start of the output or in a known CLI error shape, not anywhere in the text.

- [ ] B-20260927-ADV-RUNSH-PREEXISTING-FAILS [P2][test][conf 95]
**Fingerprint:** tests/adversarial/run.sh|test|30-failing-assertions-at-head
**What:** the full `tests/adversarial/run.sh` suite has ~30 failing assertions across 9 files at HEAD before Plan A (incl. test-artifact-provenance PROV.6/PROV.11); test-install-retro-stub / test-install-verify-plan-dag / test-stall-watchdog extract `install_zuvo_home` alone and fail 4 more (T8.1, T2.1, T2.4, watchdog install). run-all.sh does not run this suite, so nothing is red.
**Seen again:** clean `8aa1bac1` (`rt` 1790523629-85742-388) and the final test-writing branch (`rt` 1790531693-81264-18976) each had the same 30 failing assertion messages; diff of the two failure sets was empty. The branch added 70 passing assertions.
**Fix:** triage per file (stale expectation vs real regression); make the install extractions source install.sh's helpers they now need; then add run.sh to run-all or CI.
**Seen again:** refactor branch `a2c56421`, `rt` run `1790541299-35538-22342`: 768 assertions, 29 failed. The current 29 failure messages are an exact subset of the prior 30; T3.4 was green this time, so no new regression was found and that one case may also be intermittent.
**Seen again:** Plan B review 2026-09-28: HT.7 in tests/adversarial/test-hard-timeout-and-suspend.sh:162-171 expects 16 log columns, but the log row has had 17 since before `0edeb0c2` (LOG_HEADER printf in scripts/adversarial-review.sh); fails identically at HEAD and at the Plan B base, so it is one of the pre-existing failures, not a Plan B regression.

- [ ] B-20260927-ADV-BATS-GAPS [P3][test][conf 85]
**Fingerprint:** scripts/tests/adversarial-review.bats|test|untested-flags-and-weak-failure-cases
**What:** no case for the exit-5 no-material gate, `--doctor`, `--exclude`/`--exclude-last`, `--known-finding`, `--append-artifact`, `--no-chunk`; "exits 2 when stdin is empty" feeds `echo ''` (one newline), never zero bytes; the multi-mode failure cases (~:405-425) do not assert the failing provider was dispatched; the real `sleep 10` timeout case is a flake risk under farm load.
**Fix:** add the missing cases with spies; `printf ''` for empty stdin; assert each failing lane's dispatch marker; drive the timeout with a fake clock or a short ZUVO_* budget.

- [ ] B-20260927-ROUTER-GAPS [P4][test][conf 70]
**Fingerprint:** scripts/reviewer-model-route.sh|test|antigravity-wildcard-arms-and-fallback-dup
**What:** the antigravity wildcard arms have no case; the cursor/kimi cross-vendor fallback loops are near-identical ~12-line blocks.
**Fix:** add route.bats rows for the wildcard arms; fold the two loops into one helper.

- [ ] B-20260927-INSTALL-UNCOVERED [P2][test][conf 95]
**Fingerprint:** scripts/install.sh|test|install-claude-home-and-adoption-matrix-uncovered
**Source:** `zuvo:write-tests` strict blind audit (96 owned rows, verdict FIX) and `zuvo:test-audit` A2, 2026-09-28. The new Claude-home and atomic-file tests close the older settings/merge and chmod/mv claims; they are no longer open gaps.
**What:** The remaining host adoption/prune paths are untested, particularly Kimi's `KIMI_CODE_HOME` refusal before deleting `shared/` and `rules/`, Cursor duplicate cleanup, Claude cache pruning and docs rollback, Codex TOML pruning, and Antigravity ownership/collision handling. Config writes to Codex, Gemini and `.zshenv` also lack behavioral coverage. `cp_warn` arity/flag/absent-source handling and the whole-install `INSTALL_COPY_WARNINGS>0` branch remain Q7/Q11 gaps (`scripts/install.sh:128-136,2382-2388`); non-Git source and an empty revision stamp remain gaps in the downgrade guard (`:38-41`). Smaller uncovered paths are itemized in `zuvo/context/blind-audit-install-postfix.out` of worktree `codex/install-sh-8868`.
**Fix:** Use isolated HOME fixtures for the destructive host paths and config writes, including a foreign Kimi directory with sentinel `shared/` and `rules/`; exercise the missing `cp_warn` inputs and a real warning dispatch; test non-Git and empty-stamp fallback behavior. Re-run the strict blind audit and executable shell coverage gate when available.

- [ ] B-20260927-SMOKE-HARNESS-SELFTESTS [P4][test][conf 60]
**Fingerprint:** tests/hooks/smoke-*.sh|test|smoke-harness-link-logic-untested
**What:** only smoke-reviewer-subprocess.sh has a self-test of its link/suite/verdict logic (test-smoke-reviewer-subprocess.sh); the other smoke-*.sh harnesses can go vacuous unnoticed.
**Fix:** make them sourceable the same way and add a synthetic self-test each, or share one harness library.

- [ ] B-20260927-WARN-SNIPPET-SECRET-ECHO [P4][security][conf 30]
**Fingerprint:** scripts/adversarial-review.sh|security|lane-warn-quotes-cli-stderr
**What:** `lane_failed_warn` prints up to 300 bytes of a failing CLI's own stderr (sanitised, capped); a CLI that echoes a credential in an error would put it on the terminal and in logs. Strictly better than the old unbounded `head -1`.
**Fix:** redact key-shaped tokens (sk-…, Bearer …, 32+ hex/base64 runs) before quoting.

- [ ] B-20260927-DRIVER-INSTALL-SIZE [P4][structure][conf 40]
**Fingerprint:** scripts/adversarial-review.sh|structure|driver-and-installer-oversized
**What:** scripts/adversarial-review.sh (~4300 lines) and scripts/install.sh (~2400 lines) are far past any file-size limit (pre-existing); every review of them needs hunk-split chunks.
**Fix:** zuvo:refactor — split per concern (lanes, chunking, artifact, ledger; per-host installers) behind the existing tests.

<!-- zuvo:refactor-radar run 2026-09-27 on tgm-survey-platform (develop eff5f2c9c2, scopes apps/runner + apps/api/src/modules/runner); report tgm-survey-platform/zuvo/reports/refactor-radar-20260927T112023Z-NNfIyL/ -->
- [ ] B-20260927-RADAR-BB-DIFFSTAT-SAME-HOST-302 [P2][correctness][conf 90]
**Fingerprint:** scripts/lib/radar_remote.py|availability|refuses-same-host-diffstat-redirect
**What:** `NoRedirect` (radar_remote.py:73) refuses every 30x. Bitbucket `GET /pullrequests/<id>/diffstat` answers 302 to `…/diffstat/<ws>/<repo>:<range>` on the SAME host and repo prefix, so on Bitbucket repos the PR census is ALWAYS incomplete (`bb: PR census incomplete (HTTPError)`, `busy.remote.paths = []`). Seen 2026-09-18, 09-20 and 09-27 on tgmdev/rdesigner. A hand census that followed only same-host/same-repo redirects got 14 PRs / 448 paths / 0 errors.
**Fix:** follow a redirect only when scheme is https, host is unchanged and the path stays under `/2.0/repositories/<ws>/<repo>/`; cap hops at 3; keep refusing everything else. Regression test with a stub server returning that exact 302.

- [ ] B-20260927-RADAR-BUSY-COUNTS-LANDED-CONTENT [P2][precision][conf 85]
**Fingerprint:** scripts/lib/radar_git.py|availability|busy-includes-paths-already-on-ref
**What:** `local_busy` (radar_git.py:162) marks every path a worktree changed since its merge-base as busy, even when the worktree's blob is IDENTICAL to the ref's (work already squash-merged). With 275 worktrees it excluded 535 families across two scopes, including the top candidates; a blob-vs-ref recheck found 0 pending holders for most of them (`maxdiff-page-navigation`, `useAutopilot`, `useHeatmapGestures`, `answerStorage`).
**Fix:** for each (worktree, path) compare `ls-tree <wt-HEAD> -- p` (or `hash-object` for dirty paths) with `ls-tree <ref> -- p`; equal → not busy. Record the worktree's last-commit age as a hint.

- [ ] B-20260927-RADAR-PREPARE-FARM-60S-DEFAULT [P3][DX][conf 80]
**Fingerprint:** scripts/lib/radar_cli.py|timeout|local-default-too-small-for-prepare
**What:** `--timeout` defaults to 60 s outside `--snapshot` (radar_cli.py:592). The availability phase alone took 112 s with 275 worktrees (135 s with 365 on 09-20), so the documented `--prepare-farm` command in farm.md aborts with "scan deadline exceeded" before publishing input.json — on exactly the repos that need the farm.
**Fix:** give `--prepare-farm` its own default (e.g. 1200 s) or exclude availability collection from the local deadline; update the farm.md example.

- [ ] B-20260927-RADAR-TESTS-MODE-NO-COVERAGE-INPUT [P3][feature][conf 70]
**Fingerprint:** skills/refactor-radar/SKILL.md|tests-mode|coverage-always-null
**What:** `--mode tests` ranks by the complexity lane and leaves `coverage: null`, so COVER candidates are high-ΣCC families. Measured on tgm: the top API rows were 95–98% branch-covered, while the real gaps (IDB storage 21% lines, nested display-logic groups never executed) were low-ΣCC. The agent had to run coverage on the farm and hand-join it.
**Fix:** accept `--coverage-json <vitest|istanbul json-summary>` (validated SHA/scope), fill per-family `coverage`, and rank the tests lane by uncovered branches × K × √(fix+1).

- [ ] B-20260927-RADAR-SCOPE-SINGLE-PATH [P4][DX][conf 50]
**Fingerprint:** scripts/lib/radar_cli.py|args|scope-accepts-one-path
**What:** `--scope` takes one path. A basename like `runner` maps to two dirs in a monorepo (app + API module), forcing two preparations (2 × 127 MB input.json, two availability passes) and two discovery JSONs where SKILL.md expects one `discovery.json`.
**Fix:** accept repeated `--scope`; document the multi-scope output naming.

<!-- zuvo:refactor-radar run 2026-09-27 on tgm-survey-platform, apps/api tests mode (develop eff5f2c9c2); report tgm-survey-platform/zuvo/reports/refactor-radar-20260927T112015Z-h0RdFi/. Deduplicated against 608bb31b. -->
- [ ] B-20260927-RADAR-FARM-RETRIEVAL-UNVERIFIED-DIR [P3][DX][conf 60]
**Fingerprint:** skills/refactor-radar/references/farm.md|farm|output-dir-may-not-be-collected
**What:** farm.md tells the worker to write `--json test-results/radar/report.json` and fetch it with `rt --artifacts`. That worked from one checkout, but from a develop worktree whose `.tf.json` declares `artifact_dirs: ["zuvo/proofs"]` rt returned ONLY `zuvo/proofs` (plus "rescued undeclared artifacts" under it): two green coverage runs written to `test-results/` came back empty. Whether the radar JSON comes back therefore depends on the target repo's manifest, and the skill finds out only after the run.
**Fix:** in farm.md, write the report under a directory the repo's manifest collects (read `artifact_dirs`), or have the worker also print a checksum + byte count so an empty retrieval is detected immediately; state "retrieval failed → rerun with a collected dir", never "scan failed".

- [ ] B-20260927-RADAR-PREPARE-FARM-DIR-AT-REPO-ROOT [P4][hygiene][conf 60]
**Fingerprint:** skills/refactor-radar/references/farm.md|staging|job-dir-in-repo-root
**What:** the documented `JOB_DIR="$(mktemp -d "$REPO_ROOT/radar-farm-XXXXXX")"` puts a 100+ MB untracked, deliberately NOT ignored directory at the repository root (it must be visible to the rt mirror). Repos with root-hygiene rules (tgm: "NEVER create files at project root") flag it, and any `git add` of the root sweeps it in; an interrupted session leaves it behind.
**Fix:** a dedicated staging path the skill documents per repo (e.g. `.radar-farm/<id>` with an rt explicit-transfer or a manifest entry), plus cleanup in the completion checklist even on failure.

- [ ] B-20260927-RADAR-LOCAL-BUSY-ERRORS-ANONYMOUS [P4][diagnostics][conf 70]
**Fingerprint:** scripts/lib/radar_git.py|availability|errors-without-worktree-path
**What:** `busy.local.errors` held 4 × "worktree unavailable; consult PR/contract before release" with no worktree path or reason, so the operator cannot tell which checkout failed or why (prunable? permission? detached?). `complete=false` then has no actionable cause.
**Fix:** include the worktree path (repo-relative or `~`-prefixed) and the failing git command's exit class in each error.

- [ ] B-20260927-RADAR-BB-CENSUS-VALUEERROR [P3][correctness][conf 50]
**Fingerprint:** scripts/lib/radar_remote.py|availability|bb-census-valueerror
**What:** on 2026-09-27 the Bitbucket census failed with `bb: PR census incomplete (ValueError)` — not the `HTTPError` of B-20260927-RADAR-BB-DIFFSTAT-SAME-HOST-302 — both in `--prepare-farm` and in `--capture-busy`. The same 14 open PRs / 448 paths were collected by hand with the keychain token and redirects followed, so auth and data were fine. The exception class alone does not say which step failed.
**Fix:** reproduce with `--capture-busy` on tgm, log the failing URL class and exception message (sanitised); check whether the 302 fix alone resolves it before treating it as separate.

## B-20260927-EXECUTE-STATE-COLLISION — `zuvo:execute` has no guard against a second run owning `execution-state.md`

[reliability] skills/execute/SKILL.md (Session State Initialization) + shared/includes/session-state.md | rule:observed-in-run | sig:execute-state-single-writer

`zuvo:execute`'s Session Recovery Check reads `zuvo/context/execution-state.md` and branches on
`status:` alone. It never compares the file's `plan:` field against the plan it was asked to run. So
when a second execute run starts in a repo where another is mid-flight, it reads `status: in-progress`,
enters *resume mode for somebody else's plan*, or — if it takes the normal path — rewrites the file at
Session State Initialization and destroys the other run's only resume point.

Measured 2026-09-27: a `zuvo:plan` run wrote `zuvo/plans/active-plan.md` for
`2026-09-27-backlog-heading-entries-plan.md` at 13:52Z while `execution-state.md` (13:29Z) held
`2026-09-25-blind-audit-panel-plan.md` at `next-task: 4` of 10, with 3 tasks committed
(fea5250c, 5507c3a3, 35b9d7cf) and two live `adversarial-review` PIDs. The pointer clobber happened
silently; nothing warned. `scripts/zuvo-phase.sh status` *does* report `evidence: live execute run`,
so the signal exists and neither skill consults it.

Fix: at Session Recovery Check, if `execution-state.md` has `status: in-progress` and its `plan:`
differs from the plan being executed, stop with a new `BLOCKED_STATE_OWNED_BY_OTHER_RUN` rather than
resuming or overwriting — and have `zuvo:plan` refuse to repoint `active-plan.md` while
`zuvo-phase.sh status` reports a live execute run, or at minimum back up what it replaces.
A worktree is NOT the general answer: for a plan whose subject is `memory/backlog.md` itself, a linked
worktree re-creates the 2026-07-19 fork incident (backlog-protocol.md:14-29).
confidence:95 source:observed-directly-in-run

## 2026-09-27 verify-tests test and mutation run

- [ ] B-20260927-WRITETESTS-PYTHON-VERIFIER [P3][test-infra][conf 100]
**Fingerprint:** scripts/zuvo-home/verify-tests|test-infra|python-verification-cannot-finish
**Source:** zuvo:write-tests on `scripts/zuvo-home/verify-tests`, branch `codex/verify-tests-7364`.
**What:** `detect_runner` selects pytest for the extensionless Python helper although this dependency-free repo runs shell wrappers and stdlib unittest. The farm needed a temporary pytest install to execute the helper; `check_mutation` then returned `SKIP` for pytest. The gate permits that SKIP, but the helper cannot report the measured score from the separate `tf-ablate` run (22/22 mutants). Step 2.5's actual blocker was the 348 unmapped inventory rows and Q7/Q11, tracked in the next entry; runner integration remains a distinct tooling gap.
**Fix:** add an explicit stdlib-unittest runner path and a verified external mutation receipt (with source/spec hashes and report validation), or wire an equivalent Python runner into the helper; cover both paths with executable tests before promising full `write-tests` support for Python helpers.

- [ ] B-20260927-VERIFY-TESTS-INVENTORY [P2][test-debt][conf 100]
**Fingerprint:** scripts/zuvo-home/verify-tests|q11|348-inventory-rows-unmapped
**Source:** zuvo:write-tests inventory and executable gate, 2026-09-28, farm run `1790529153-35032-2512`.
**What:** The current AST inventory of `scripts/zuvo-home/verify-tests` contains 53 public entry points and 348 owned rows. The new split suite has 38 passing test methods plus existing shell tests, but the manifest still has no row-level evidence map; the executable final gate reported 403 violations, including `Q7=0` and `Q11=0`. The skill explicitly calls for splitting a production file above 60 rows. Important remaining groups include runner configuration fallbacks, malformed coverage reports, mutation restore/debris failures, and CLI grant/refund paths. Passing unit and mutation samples do not establish full surface coverage.
**Fix:** split the large helper by responsibility, continue the frozen inventory, add behavioral tests for uncovered groups, map each row to a unique test declaration, and rerun the executable final gate until `Uncovered owned rows: 0` and Q7/Q11 pass. Keep the current run `BLOCKED_INCOMPLETE` until then.

- [ ] B-20260927-TFABLATE-PYBYTECODE [P2][test-infra][conf 100]
**Fingerprint:** i9-farma/server/tf-ablate.py|mutation|same-size-python-mutant-stale-pyc
**Source:** zuvo:mutation-test, farm runs `1790525178-44830-23425` and `1790525401-68946-32415`.
**What:** The first Python ablation reported `MUT-005` and `MUT-006` as SURVIVED although the new tests asserted those exact nonzero-exit branches. Repeating the same mutants with `PYTHONDONTWRITEBYTECODE=1` killed both. The worktree tests now compile the extensionless source directly, but `tf-ablate` can still reuse a sandbox's `__pycache__` when another Python suite loads a same-size mutant within the timestamp window.
**Fix:** for the Python runner, disable bytecode writes in every control and mutant subprocess or clear module bytecode between them; add a same-size mutation fixture that fails if stale bytecode is executed.

- [ ] B-20260927-CODESIFT-POLYGLOT [P3][test-infra][conf 90]
**Fingerprint:** scripts/zuvo-home/verify-tests|codesift|extensionless-polyglot-zero-symbols
**Source:** zuvo:write-tests CodeSift probe, linked worktree indexed as `local/zuvo@zuvo-plugin1`.
**What:** CodeSift indexed the linked worktree but returned `(no symbols)` for `scripts/zuvo-home/verify-tests`, while the repository's Python AST extractor found 53 public symbols. That makes CodeSift discovery and reference analysis unavailable for this supported sh/Python helper shape, forcing native fallback despite a healthy index.
**Fix:** teach CodeSift's file classifier the `''''exec` polyglot marker or make the skill's index step declare this exact parser gap and use the AST extractor directly.

- [ ] B-20260927-REFGLOB-WARNING [P4][diagnostics][conf 100]
**Fingerprint:** hooks/lib/refactor-gate-lib.sh|diagnostics|unmatched-contract-glob-warning
**Source:** every commit in `codex/verify-tests-7364` printed `zuvo contract: unreadable or non-contract: zuvo/contracts/refactor-*.json` twice.
**What:** `refactor_gate_check` iterates a literal `refactor-*.json` when the contracts directory exists but no matching file does. It sends that literal to the structural reader and prints an error-looking warning on successful unrelated commits.
**Fix:** guard each `refactor-*.json` loop with `[ -f "$c" ] || continue` (and the corresponding variable names in sibling loops), then test a contracts directory with zero matching files.

- [ ] B-20260928-TEST-AUDIT-REVIEWER-ROUTING [P3][test-infra][conf 100]
**Fingerprint:** skills/test-audit/SKILL.md|reviewer|codex-gpt-5.4-http-400
**Source:** `zuvo:test-audit` on the verifier test files; report `zuvo/audits/test-quality-audit-2026-09-27-verify-tests.md`.
**What:** The skill's prescribed `gpt-5.4` independent reviewer could not start on this Codex account (HTTP 400). The source-backed audit fixed all six findings, but its formal validity gate remains incomplete because that reviewer did not run. CodeSift reference queries also returned partial results; the separate polyglot issue above tracks its zero-symbol behavior.
**Fix:** route the audit reviewer through an account-supported independent model after preflight, record the actual provider and a failed-route reason, then verify the fallback still satisfies the audit's independence rule.

## 2026-09-28 refactor gate test and mutation run

- [ ] B-20260928-WRITETESTS-SHELL [P2][test-infra][conf 100]
**Fingerprint:** scripts/test-coverage-gate.py|stack|shell-target-unsupported
**Source:** `zuvo:write-tests hooks/lib/refactor-gate-lib.sh`, commit `9baea11d`.
**What:** `test-coverage-gate.py extract --production hooks/lib/refactor-gate-lib.sh` exits 2 with `unsupported production-file language`; `verify-tests` also has no shell stack or bash runner. The frozen inventory and executable receipt required by the full `write-tests` gate cannot be produced for this repo's primary source language. The run therefore remains `BLOCKED_DEGRADED` despite green shell tests and mutation probes.
**Fix:** add shell function/boundary extraction, a documented bash test mapping and verifier runner, then prove the manifest and receipt paths on a shell fixture.

- [ ] B-20260928-TFABLATE-SHELL [P3][test-infra][conf 100]
**Fingerprint:** i9-farma/server/tf-ablate.py|runner|shell-tests-unsupported
**Source:** `zuvo:mutation-test`, farm runs `1790527425-51002-27929` and `1790529068-99799-13055`.
**What:** the farm's `tf-ablate` accepts Jest, Vitest, pytest and Codeception, but no shell test runner. This repo has no native shell mutation tool; pytest is absent on the farm (`1790523018-84628-31082`). This run needed a task-specific sandboxed shell ablation runner to measure 53 planned mutants across six files. Its 100% score covers that explicit plan, not exhaustive native enumeration.
**Fix:** add a shell runner to `tf-ablate` with explicit `.sh` specs, green unmutated controls, process-group reaping, byte restoration and artifact rescue; integrate its report into the standard `mutation-test` path.
**Seen again:** 2026-09-29, hook-perf session (b0e65d51) — worked around without a farm change: a pytest shim (`tests/mutation/bash_suite_shim.py`) wraps each bash suite as one pytest test, and the job builds a local venv (`uv venv -q --clear .venv` + pytest) so tf-ablate's pytest runner can drive it (plans `tests/mutation/hooks-plan*.json`; adversarial suites through `tests/adversarial/run.sh`). It caught a vacuous test, so the route works — but `skills/mutation-test/SKILL.md` still has no shell-suite recipe, and every run re-derives it.

- [ ] B-20260928-REFACTOR-GATE-Q11 [P2][test-debt][conf 100]
**Fingerprint:** hooks/lib/refactor-gate-lib.sh|q11|blind-audit-partial-branches
**Source:** strict blind audit passes 1–2 in `zuvo:write-tests`, 2026-09-27.
**What:** the second production-first blind audit still returned `FIX` after new tests closed future execution-state, terminal-stage and v6 reader-result gaps. Remaining owned paths include missing-reader fallback, multiple active contract fences, legacy execution state, symlink normalization, and several fail-open parser cases. The `.sh` executable coverage gate cannot certify these rows, so `write-tests` cannot honestly report COMPLETE.
**Fix:** extend the existing responsibility-split shell suites with behavioral assertions for the remaining audit rows, then re-run a strict blind audit and an executable shell inventory gate when available.

- [ ] B-20260928-REFACTOR-STATE-Q7Q11 [P2][test-debt][conf 95]
**Fingerprint:** hooks/lib/refactor-state.py|q7q11|evidence-assessment-inputs
**Source:** `zuvo:test-audit` report `zuvo/audits/test-quality-audit-2026-09-27.md`.
**What:** the new state-reader cases plus existing suites leave malformed/duplicate-key contract inputs, recursive current-assessment failures, and v6 evidence run/hash validation without branch and negative-path assertions. The scoped audit assigns the reader suite Tier C with Q7=0 and Q11=0; the 53-mutant sample does not exhaust those paths.
**Fix:** split reader tests by parser, assessment and evidence validation, assert real CLI outcomes for malformed inputs, and re-audit Q7/Q11 against the union of covering suites.

- [ ] B-20260928-REFACTOR-CONTRACT-Q7Q11 [P2][test-debt][conf 95]
**Fingerprint:** scripts/zuvo-home/refactor-contract|q7q11|uncovered-cli-commands
**Source:** `zuvo:test-audit` report `zuvo/audits/test-quality-audit-2026-09-27.md`.
**What:** `test-refactor-contract.sh` covers list, stage, prove, baseline and recheck, including the two mutation survivors closed in this run, but has no assertions for the public `show`, `check`, `regression`, `set` and `append` command branches. The scoped audit assigns Tier C with Q7=0 and Q11=0 for this broader CLI surface.
**Fix:** add command-specific positive and invalid-input tests for those five entry points, then re-audit the complete CLI surface.

- [ ] B-20260928-REFACTOR-READER-EXIT2 [P3][correctness][conf 95]
**Fingerprint:** hooks/lib/refactor-gate-lib.sh|error|v6-reader-error-blocks
**Source:** cross-provider review of the refactor gate test pair, 2026-09-27; confirmed in the `evidence`/`quality` shell branches.
**What:** the v6 gates use `_refactor_state ... evidence || blocked=1` and the same form for `quality`. The reader distinguishes a proof failure (exit 1) from unavailable/invalid reader infrastructure (exit 2), but both currently block a commit or push. That contradicts the library's documented fail-open policy for internal errors.
**Fix:** test reader exit 1 and exit 2 separately, block on failed proof, and disclose/fail open on unavailable infrastructure if the fail-open contract remains intended.

- [ ] B-20260928-REFACTOR-WONTFIX [P3][correctness][conf 95]
**Fingerprint:** hooks/lib/refactor-gate-lib.sh|logic|wontfix-triggers-regression-red
**Source:** cross-provider review, confirmed by the v3 `case "$fd" in *fix*)` pattern.
**What:** a legacy v3 disposition such as `wontfix` or `no_fixes_needed` matches `*fix*`, so the gate demands a demonstrated red regression even though no fix was applied. It can false-block commits for a full TTL window.
**Fix:** match explicit applied-fix tokens or use the structural `fixes` result for legacy contracts, with negative fixtures for `wontfix` and `no_fixes_needed`.

- [ ] B-20260928-REFACTOR-DOTDOT-REPORT [P3][correctness][conf 100]
**Fingerprint:** hooks/lib/refactor-gate-lib.sh|path|dotdot-report-filename-rejected
**Source:** cross-provider review, confirmed at the pre-push report-path `case` checks.
**What:** `*..*` rejects any report path containing two consecutive dots, including a safe repo-relative filename such as `zuvo/audits/test-audit-base..head.json`. The check treats a filename as path traversal and can false-block a valid review or mutation artifact.
**Fix:** reject `..` path components (`..`, `../*`, `*/..`, `*/../*`) while allowing double dots within a filename; add both acceptance and traversal cases.

- [ ] B-20260928-FULL-SUITE-CHILD [P3][test-infra][conf 100]
**Fingerprint:** tests/run-all.sh|process|one-child-left-after-suite
**Source:** farm runs `1790527873-41358-23725` and `1790529459-44372-12654`, each `RESULT: PASS=148 FAIL=0 SKIP=6`.
**What:** after the two green full-suite runs, the farm reported `test.scope still held 1 process(es)` and then `2 process(es) after the job ended`, and killed the children. The logs did not identify which test launched them, so the suite's process cleanup is incomplete even though the farm contained the leak.
**Fix:** capture the remaining PID/command in a diagnostic farm run, identify its spawning test, and make that test reap its child before exit.
**Seen again:** `rt` full battery `1790540440-76115-12425` finished PASS=144/FAIL=0/SKIP=6 but farm reaped 1 residual process. The direct adversarial harness `1790541299-35538-22342` left 6 residual processes after 768 assertions, narrowing the likely source to its child cases.

- [ ] B-20260928-FARM-LINT-SKIPS [P3][test-infra][conf 100]
**Fingerprint:** tests/run-all.sh|environment|farm-lint-tools-missing
**Source:** farm runs `1790527873-41358-23725` and `1790529459-44372-12654`.
**What:** the six full-suite skips include Python lint because neither ruff nor mypy is installed and shell lint because shellcheck is absent on the farm. Local `shellcheck -S error` passed for the changed shell files, but the farm's green full-suite result does not certify the repository-wide lint gates.
**Fix:** provision the documented static analyzers in the farm runtime or route those gates through a pinned tool image, then require their own summaries before treating the full battery as complete.
**Seen again:** `rt` full battery `1790540440-76115-12425` still reported six skips, so the passing run does not establish full lint coverage.

- [ ] B-20260928-REFACTOR-TEST-LEVELS [P3][test-debt][conf 95]
**Fingerprint:** tests/hooks|q20|refactor-suite-levels-undeclared
**Source:** `zuvo:test-audit` report `zuvo/audits/test-quality-audit-2026-09-27.md`.
**What:** all 16 scoped hook suites lack an explicit small/medium/large test-level declaration, so the audit assigns Q20=0 across the set. The suites run successfully, but their intended execution tier and cost are undocumented.
**Fix:** define the suite levels once in the test runbook or alongside the runner's suite mapping and make each scoped test's level discoverable by the audit.

- [ ] B-20260928-REFACTOR-PROPERTY-TESTS [P3][test-debt][conf 95]
**Fingerprint:** tests/hooks|q22|pure-refactor-helpers-no-generated-inputs
**Source:** `zuvo:test-audit` report `zuvo/audits/test-quality-audit-2026-09-27.md`.
**What:** the marker, mtime, human-env and artifact-kind helper suites have no generated-input invariant test with a recorded seed (Q22=0). The fixed examples exercise representative values but do not probe broader value classes.
**Fix:** add seeded generated-input invariants for these pure helpers and keep the seed in failure output for reproduction.

- [ ] B-20260928-STAT-TEST-MULTILINE [P3][test-debt][conf 90]
**Fingerprint:** tests/hooks/test-stat-portability.sh|assertion|multiline-bsd-first-guard
**Source:** `zuvo:test-audit` report `zuvo/audits/test-quality-audit-2026-09-27.md`.
**What:** the BSD-first source-order guard sees both `stat` forms only if they occur on the same line; a multiline recurrence could evade that structural assertion. The functional GNU, BSD and fallback cases still pass, so this is a narrow guard gap.
**Fix:** parse the source-order check across lines or replace it with a functional stub that fails when the BSD form is attempted first.

## 2026-09-28 installer test audit follow-ups

- [ ] B-20260928-INSTALL-RETRO-AP3 [P2][test][conf 100]
**Fingerprint:** tests/adversarial/test-install-retro-stub.sh|AP3|manual-retro-stub-copy
**Source:** `zuvo:test-audit` on `scripts/install.sh`, 2026-09-28.
**What:** T8.4 at `tests/adversarial/test-install-retro-stub.sh:60-64` copies and chmods `retro-stub` itself. It can pass if the production installation clause is removed. The existing adversarial-suite backlog entry concerns failing runs, not this vacuous assertion.
**Fix:** Invoke the real `install_zuvo_home` path in an isolated HOME and assert the installed file's bytes, executable mode and result.

- [ ] B-20260928-INSTALL-ANTIGRAVITY-VACUOUS [P2][test][conf 100]
**Fingerprint:** tests/hooks/test-antigravity-skill-ownership.sh|Q11|setup-skips-or-swallows-install
**Source:** `zuvo:test-audit` on `scripts/install.sh`, 2026-09-28.
**What:** Lines 29-36 print PASS and skip behavior if the builder is absent; line 79 suppresses a sourcing error with `|| true`; line 85 discards the first install result. Ownership cases can therefore pass without a successful installation.
**Fix:** Make missing builder, sourcing failure and first-install failure fail setup; retain the existing ownership assertions against the real installed files.

- [ ] B-20260928-INSTALL-SMOKE-HOME [P3][test][conf 95]
**Fingerprint:** tests/smoke-write-e2e-v2.sh|Q11|real-home-allows-stale-install-state
**Source:** `zuvo:test-audit` on `scripts/install.sh`, 2026-09-28.
**What:** SMOKE4 at lines 332-449 runs the installer in the ambient HOME and then checks installed paths that may predate the run. Prior files can mask a missing current copy. This differs from the existing smoke-harness self-test entry, which tracks harness logic generally.
**Fix:** Run SMOKE4 in a disposable HOME and assert newly written bytes and paths; prove a no-op installer fails its self-test.

- [ ] B-20260928-INSTALL-CPWARN-FIXTURE [P3][test][conf 95]
**Fingerprint:** tests/hooks/test-install-copy-verification.sh|Q18|chmod-permission-fixture-nondeterministic
**Source:** `zuvo:test-audit` on `scripts/install.sh`, 2026-09-28.
**What:** Lines 199-214 rely on `chmod a-w` to make `cp` fail. A privileged process or filesystem with different permission semantics may still write and make the assertion unreliable.
**Fix:** Inject a deterministic failing `cp` shim, assert its invocation, warning counter and continuation to later copies.

## 2026-09-28 adversarial review test and mutation run

- [ ] B-20260928-ADV-INSTALL-COPY-VERIFY-INTERMITTENT [P2][test][conf 90]
**Fingerprint:** tests/hooks/test-install-copy-verification.sh|test|intermittent-fail-summary-exit
**Source:** clean `8aa1bac1` farm baseline `1790522438-14855-28916` versus branch full battery `1790528045-84850-30035`.
**What:** the clean baseline ended `PASS=142 FAIL=1 SKIP=6`; the failing child said `FAIL summary does not exit non-zero`. The branch did not edit the installer or that test, yet the later battery ended `PASS=143 FAIL=0 SKIP=6`. This is an observed intermittent failure; its cause is unverified.
**Fix:** reproduce the child repeatedly on one fixed farm image and capture its fixture state, then isolate the environment or shared state that changes the summary assertion.

- [ ] B-20260928-ADV-MISSING-SPACED-PATH [P3][input][conf 95]
**Fingerprint:** scripts/adversarial-review.sh|files|missing-spaced-path-ambiguous
**Source:** this session's `--files` parser review, line 713 in branch `codex/adversarial-review-sh-77643`.
**What:** an existing path containing spaces is resolved by the longest-match scan, but a missing path containing spaces in a space-separated `--files` list cannot be distinguished from several missing paths. The guard reports one missing path per word. Callers can currently use `--file` or newline-separated input to avoid ambiguity.
**Fix:** define an unambiguous list transport for callers, then make the diagnostic preserve the supplied path boundary.

- [ ] B-20260928-ADV-CODESIFT-AUDIT-BUSY [P2][test-infra][conf 100]
**Fingerprint:** skills/test-audit/SKILL.md|codesift|mandatory-tools-unavailable-under-heap-pressure
**Source:** final `zuvo:test-audit` attempt in this session, linked worktree `codex/adversarial-review-sh-77643`.
**What:** CodeSift reported heap 14516–15198/16384 MB and refused `find_dead_code`/`find_clones`; a later outline call failed at MCP transport. `test-audit` requires these calls, so its formal validity gate could not finish despite an independent read-only test-quality review.
**Fix:** make index residency/capacity observable before mandatory audit dispatch and provide a retry or an explicitly degraded tool-backed path; rerun the formal audit when CodeSift has room.

- [ ] B-20260928-ADV-CAP-WALLCLOCK [P3][test][conf 95]
**Fingerprint:** tests/adversarial/test-provider-fanout-cap.sh|q18|auth-refusal-wallclock-bound
**Source:** independent final test-quality review, lines 358–365.
**What:** the auth-refusal case asserts a wall-clock duration below eight seconds. Farm contention can fail this assertion without a behavioral regression.
**Fix:** assert the retry or timeout branch using a deterministic mock signal or clock rather than elapsed wall time.

- [ ] B-20260928-ADV-CAP-SERVER-LIFETIME [P3][test][conf 90]
**Fingerprint:** tests/adversarial/test-provider-fanout-cap.sh|q19|background-server-not-reaped
**Source:** independent final test-quality review, lines 323–357.
**What:** provider-cap cases start Python HTTP servers that sleep for 90 seconds and close file descriptor 9 without explicitly waiting for or terminating the server processes. They can outlive the test and consume farm capacity.
**Fix:** capture each server PID and reap it in a trap, then assert no child remains after the case.

- [ ] B-20260928-ADV-BATS-FARM [P3][test-infra][conf 100]
**Fingerprint:** scripts/tests/adversarial-review.bats|environment|bats-absent-on-farm
**Source:** `rt --light bats scripts/tests/adversarial-review.bats`, run `1790525336-97275-12912`.
**What:** the farm returned exit 127 because `bats` is unavailable, so the existing Bats corpus was not executed in this run. The Bash harness and repository full battery did execute.
**Fix:** provision Bats in the farm image or add a pinned test profile that executes the corpus.

## 2026-09-28 adversarial-review refactor residuals

- [ ] B-20260928-ADVR-CLI-ARITY [P2][code][conf 100]
**Fingerprint:** scripts/adversarial-review.sh|cq3|valued-options-missing-arity
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:316: Valued flags read $2 without checking argument count; missing values trigger Bash nounset instead of the documented usage error.
**Fix:** Check $# before each valued option, emit flag-specific usage and exit 2; test every missing value.

- [ ] B-20260928-ADVR-CODESTRAL-ARGV [P1][security][conf 95]
**Fingerprint:** scripts/adversarial-review.sh|cq5|codestral-token-in-process-argv
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:2885: Codestral bearer credential is passed in curl command arguments and is visible to process inspection.
**Fix:** Move the header to a 0600 curl config or another non-argv channel and assert no secret appears in the process command line.

- [ ] B-20260928-ADVR-OPENROUTER-RAWLOG [P2][security][conf 95]
**Fingerprint:** scripts/adversarial-review.sh|cq8|raw-upstream-body-in-warning
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:3034: OpenRouter 2xx refusal and API-error diagnostics quote raw upstream bytes into stderr; control/bidi text can forge logs and sensitive content can be exposed.
**Fix:** Sanitize and bound diagnostics as the non-2xx branch does; test C0/C1, bidi and credential-shaped payloads.

- [ ] B-20260928-ADVR-UNBOUNDED-CURL [P2][reliability][conf 90]
**Fingerprint:** scripts/adversarial-review.sh|cq6|unbounded-curl-response-variable
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:3172: The full curl response is captured in a shell variable before any cap, so a large upstream body can exhaust memory.
**Fix:** Cap response bytes at ingress and reject oversized bodies with a distinct outcome.

- [ ] B-20260928-ADVR-API-SHAPE [P2][correctness][conf 90]
**Fingerprint:** scripts/adversarial-review.sh|cq19|api-response-shape-unvalidated
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:3021: OpenRouter response fields are probed with jq without an expected-shape validation step; schema drift becomes an undifferentiated empty response.
**Fix:** Validate choices/message/content shape before decoding and report malformed responses distinctly.

- [ ] B-20260928-ADVR-LEDGER-RACE [P2][reliability][conf 85]
**Fingerprint:** scripts/adversarial-review.sh|cq21|health-ledger-read-compute-mv-race
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:4160: Concurrent review invocations can lose provider-health updates in a read/compute/mv sequence.
**Fix:** Make read, update and replace share a process lock or use an atomic append/event ledger; test two concurrent writers.

- [ ] B-20260928-ADVR-AUTH-CACHE-TTL [P3][correctness][conf 85]
**Fingerprint:** scripts/adversarial-review.sh|cq23|auth-failure-cache-no-ttl
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:1977: The repo-keyed auth-failure cache has no TTL or periodic re-probe while other providers remain usable; a restored login may stay excluded.
**Fix:** Expire cache entries or re-probe on bounded intervals; assert restored credentials re-enter selection.

- [ ] B-20260928-ADVR-OUTBOUND-URL [P2][security][conf 85]
**Fingerprint:** scripts/adversarial-review.sh|cq31|api-base-url-no-allowlist
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:3173: Environment-selected API base URLs reach curl without scheme/host allowlisting; the BytePlus path check only protects billing.
**Fix:** Validate HTTPS and an explicit host allowlist at each vendor boundary, with refusal tests.

- [ ] B-20260928-ADVR-OR-QUOTA-LABEL [P3][correctness][conf 95]
**Fingerprint:** scripts/adversarial-review.sh|outcome|openrouter-quota-recorded-empty
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:3031: A short OpenRouter quota/insufficient-credits reply is rejected but recorded as empty, so provider health treats credit exhaustion as an output failure.
**Fix:** Set a quota marker before returning and assert provider_outcomes=openrouter:quota.

- [ ] B-20260928-ADVR-OR-LANE-WARN [P4][diagnostics][conf 95]
**Fingerprint:** scripts/adversarial-review.sh|logging|openrouter-short-warning-hardcodes-lane
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:3034: The short refusal warning hardcodes openrouter even when the same decoder serves a BytePlus lane.
**Fix:** Use the passed lane label in the warning; assert a BytePlus refusal names BytePlus.

- [ ] B-20260928-ADVR-STATUS-FILE [P2][correctness][conf 95]
**Fingerprint:** scripts/adversarial-review.sh|status|invalid-parallel-status-unvalidated
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:4039: Parallel status files are read without numeric validation; empty/whitespace/corrupt contents can disagree between string success and arithmetic timeout checks.
**Fix:** Validate one canonical 0..255 status immediately after reading and classify invalid/missing separately; add malformed-file tests.

- [ ] B-20260928-ADVR-AUTH-EXIT [P3][correctness][conf 90]
**Fingerprint:** scripts/adversarial-review.sh|outcome|nonzero-auth-differs-by-mode
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:4046: Multi mode classifies an auth stub even on nonzero exit, while single mode checks auth only after exit 0; the same CLI refusal gets different cache and health treatment.
**Fix:** Choose one auth rule for both dispatch paths and test auth text with exit 1 in each mode.

- [ ] B-20260928-ADVR-NONZERO-LABEL [P3][product-decision][conf 90]
**Fingerprint:** scripts/adversarial-review.sh|outcome|nonzero-body-labelled-empty
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:4072: After rejecting a nonzero provider body, outcome empty still conflates a crash with a genuinely empty response; this matches the existing taxonomy but misleads diagnosis.
**Fix:** Decide whether to add a failed/nonzero outcome and update health, logs, schemas and callers together.

- [ ] B-20260928-ADVR-KIMI-CURLCFG-MODE [P2][security][conf 90]
**Fingerprint:** scripts/adversarial-review.sh|secrets|kimi-curl-config-mode-window
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:3242: Kimi writes an API key to a curl config file before chmod 600, leaving a mode window under a permissive umask.
**Fix:** Apply umask 077 before creating the file and test its mode at creation time.

- [ ] B-20260928-ADVR-PARSER-DUP [P4][structure][conf 85]
**Fingerprint:** scripts/adversarial-review.sh|cq14|openrouter-kimi-error-guards-duplicated
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/adversarial-review.sh:3029: OpenRouter and Kimi API duplicate length-gated content/error classification, so refusal updates can diverge.
**Fix:** Extract a shared policy after pinning both vendors’ accepted/refused response shapes.

- [ ] B-20260928-ADVR-REFCONTRACT-SUMMARY [P3][tooling][conf 100]
**Fingerprint:** scripts/zuvo-home/refactor-contract|parser|bash-summary-format-unsupported
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/zuvo-home/refactor-contract: The contract baseline parser does not recognize the repository Bash harness SUMMARY: N run, N passed, N failed format despite the skill claiming it does; a temporary RESULT adapter was needed.
**Fix:** Parse the Bash SUMMARY format directly and test positive, zero-run, malformed and failed counts.

- [ ] B-20260928-ADVR-REFGATE-INSTALL [P3][tooling][conf 100]
**Fingerprint:** scripts/install-refactor-gate.sh|hooks|tracked-hooks-declared-unusable
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** scripts/install-refactor-gate.sh: Gate installer exits 2 for the repository’s tracked .githooks/pre-commit/pre-push even though they chain the repo safety gates, so activation telemetry falsely reports unavailable.
**Fix:** Recognize the tracked dispatch hooks or give an actionable reason without changing their ownership; add a repo fixture.

- [ ] B-20260928-ADVR-CODESIFT-PY-CALL [P3][tooling][conf 100]
**Fingerprint:** skills/test-audit/SKILL.md|codesift|python-specific-tools-not-callable
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** skills/test-audit/SKILL.md: During this audit six generic CodeSift calls worked but revealed Python-specific tool handles raised TypeError: is not a function, leaving stack-specific checks unavailable.
**Fix:** Fix deferred tool exposure or preflight tool callability and record a precise degraded mode; test the Python lane.

- [ ] B-20260928-ADVR-TEST-EXIT-ORACLE [P3][test][conf 95]
**Fingerprint:** tests/adversarial/test-adversarial-no-material.sh|q11|non-target-exit-accepted
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** tests/adversarial/test-adversarial-no-material.sh: No-material and plan-budget tests accept any exit other than 5 or 7, so unrelated crashes can pass their negative path.
**Fix:** Assert the exact exit code and diagnostic for each case; include the plan-budget sister suite.

- [ ] B-20260928-ADVR-TEST-BYTEPLUS-NET [P2][test][conf 100]
**Fingerprint:** tests/adversarial/test-byteplus-billing-guard.sh|q11|allowed-path-live-network-vacuous-success
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** tests/adversarial/test-byteplus-billing-guard.sh:67: The allowed-plan branch can reach real curl/network with a fake key, then passes on assert_eq ok ok when the guard word is absent.
**Fix:** Use a fake curl that records URL, headers and body; require a dispatch marker and exact success response.

- [ ] B-20260928-ADVR-TEST-RUNNER-BRANCH [P3][test][conf 95]
**Fingerprint:** tests/hooks/test-adversarial-runner-summary.sh|q11|runner-modes-uncovered
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** tests/hooks/test-adversarial-runner-summary.sh: Runner-summary tests miss --list, unknown name, zero discovery, multi-selection and failed child summary; a broken harness can still look healthy.
**Fix:** Add hermetic positive/negative fixtures for each mode and a nonzero child with a forged summary.

- [ ] B-20260928-ADVR-TEST-CURL-ARGS [P3][test][conf 95]
**Fingerprint:** tests/adversarial/test-openrouter-response.sh|q3|fake-curl-request-unasserted
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** tests/adversarial/test-openrouter-response.sh:12: The fake curl supplies response fixtures but never checks the request URL, auth header or JSON body, so wrong outbound requests can pass response-decoding tests.
**Fix:** Record curl argv/config and stdin in the fake, then assert vendor endpoint, model and credential transport without a real network.

- [ ] B-20260928-ADVR-TEST-ONESEC [P3][test][conf 95]
**Fingerprint:** tests/adversarial/test-provider-outcome-refactor-regression.sh|q18|one-second-timeout-flake
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** tests/adversarial/test-provider-outcome-refactor-regression.sh:10: OC.5 and OC.9 use a real 1-second timeout alongside a success mock; under farm contention the healthy lane can time out too.
**Fix:** Use a deterministic timeout shim or more generous healthy-lane budget with a controlled failing clock.

- [ ] B-20260928-ADVR-TEST-TRUNC-GUARD [P3][test][conf 90]
**Fingerprint:** tests/hooks/test-adversarial-truncation.sh|ap9|hardcoded-exclusion-list-always-true
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** tests/hooks/test-adversarial-truncation.sh:71: The truncation test checks a hard-coded provider exclusion list rather than the production value, allowing an always-true PASS.
**Fix:** Assert the produced exclusion set from the driver invocation and prove a wrong exclusion mutant goes red.

- [ ] B-20260928-ADVR-TEST-HARDTIME-SCHEMA [P3][test][conf 90]
**Fingerprint:** tests/adversarial/test-hard-timeout-and-suspend.sh|q4|sixteen-vs-seventeen-log-fields
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** tests/adversarial/test-hard-timeout-and-suspend.sh:145: A test expects 16 log fields while the driver schema now has 17; its baseline run is already red.
**Fix:** Update the assertion to the current schema only after verifying every field and retain a regression for column drift.

- [ ] B-20260928-ADVR-TEST-SMOKE-STATUS [P3][test][conf 90]
**Fingerprint:** tests/adversarial/test-smoke-all.sh|q4|rotation-status-fallback
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** tests/adversarial/test-smoke-all.sh:43: The rotation assertion falls back to .status if its intended field is missing, so it can pass without verifying rotation.
**Fix:** Assert the required rotation field directly and fail when absent.

- [ ] B-20260928-ADVR-TEST-BACKCOMP-JSON [P3][test][conf 90]
**Fingerprint:** tests/adversarial/test-backward-compat.sh|q4|empty-or-nonjson-output-passes
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** tests/adversarial/test-backward-compat.sh:12: Compatibility checks can pass on empty or non-JSON output because they do not first require a parsed result.
**Fix:** Assert valid JSON and a required result field before checking backwards-compatible values.

- [ ] B-20260928-ADVR-TEST-EXCLUDE-ZERO [P3][test][conf 90]
**Fingerprint:** tests/hooks/test-adversarial-exclude-set.sh|q11|zero-providers-still-passes
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** tests/hooks/test-adversarial-exclude-set.sh: Exclude-set test can report PASS with no providers available or no assertions executed.
**Fix:** Require positive setup and a nonzero assertion count, then verify the exact excluded provider set.

- [ ] B-20260928-ADVR-TEST-CLAUDE-DRYRUN [P3][test][conf 85]
**Fingerprint:** tests/hooks/test-claude-reviewer-model.sh|q11|dry-run-cli-invocation-unchecked
**Source:** zuvo:refactor scripts/adversarial-review.sh + zuvo:test-audit, 2026-09-28; refactor a2c56421; CQ report zuvo/reports/refactor/refactor-dedc3165-cq-post.json; test report zuvo/audits/test-quality-audit-2026-09-28.md.
**What:** tests/hooks/test-claude-reviewer-model.sh: Claude bench dry-run test does not assert that the model CLI was never invoked.
**Fix:** Add a spy CLI invocation marker and require it remains absent in dry-run cases.

- [ ] B-20260928-ADVR-LEGACY-REVIEWS [P3][review-infra][conf 100]
**Fingerprint:** memory/reviews|proof|legacy-artifacts-missing-marker-or-proof
**Source:** `zuvo:refactor` review-artifact sync check on the main checkout, 2026-09-28.
**What:** `~/.zuvo/review-artifact-sync.sh --check` accepted the new `8aa1bac..a2c5642-adversarial-review-refactor.md` pair, but exited 1 on older main-checkout artifacts: several lack `<!-- zuvo-review -->`, some lack an `adversarial:` proof line, and `2026-07-08-skill-testing-selfreview.md` has space-separated `files:`. Those artifacts grant no local content-keyed review coverage.
**Fix:** inventory and repair only artifacts whose original review proof can be recovered; leave unrecoverable artifacts marked invalid and require a fresh review when their files next change. Add a repository check that reports invalid legacy artifacts separately from a new pair's status.

<!-- zuvo:review Plan B aggregate (blind-audit panel), 2026-09-28; report memory/reviews/2026-09-28-plan-b.md -->

- [ ] B-20260928-BAP-LIB-SPLIT [P2][structure][conf 90]
**Fingerprint:** scripts/lib/blind-audit-panel.sh|structure|library-at-400-line-budget-driver-owns-panel-decisions
**Source:** zuvo:review of Plan B (STRUCT-1..4, CQ-BACKLOG-3, ADV-A60, ADV-A65), 2026-09-28.
**What:** the panel library is exactly at its 400-executable-line budget, and three panel decisions still live in the driver: the host→vendor map (scripts/adversarial-review.sh:1645-1648, beside the library's own `bap_vendor_excluded` at scripts/lib/blind-audit-panel.sh:563), the codex effort knob `blind_audit_codex_effort` (scripts/adversarial-review.sh:2323), and the isolation-critical agy prompt prefix `BA_AGY_PREFIX` (scripts/adversarial-review.sh:635). `bap_merge` is one ~125-line awk program (scripts/lib/blind-audit-panel.sh:341). Two confirmed NITs wait on the room: a size pre-check before the whole-file read in `bap_build_prompt` (:129, ADV-A60), and a NUL check on the reply in `bap_validate` (:278, ADV-A65).
**Fix:** a dedicated refactor (not in Plan C's approved scope, which never touches this library) — split the library into panel + lanes, move the three driver-owned decisions into it behind the existing suites, then land A60/A65 with RED-first tests.

- [ ] B-20260928-ROUTE-PLATFORM-NOVALUE [P3][correctness][conf 90]
**Fingerprint:** scripts/reviewer-model-route.sh|correctness|platform-flag-without-value-exits-silently
**What:** `--platform` / `--writer-model` given as the last argument run `shift 2` with one argument left (scripts/reviewer-model-route.sh:34-40); under `set -e` the router exits 1 with no message. tests/hooks/test-cursor-reviewer-routing.sh pins the current behavior.
**Fix:** refuse a missing value with a usage error (exit 2) and update the pinned case — handed to Plan C Task 1, which rewrites this router.

- [ ] B-20260928-ADV-PROVIDER-SYNC-TERM [P3][correctness][conf 70]
**Fingerprint:** scripts/adversarial-review.sh|correctness|provider-flag-sync-dispatch-defers-term-trap
**What:** pre-existing: `--provider` (scripts/adversarial-review.sh:355) forces synchronous dispatch, so bash defers the TERM trap (:3995) until the foreground CLI returns — a watchdog or caller TERM is not acted on promptly in that mode.
**Fix:** dispatch the single-provider lane in the background and `wait`, as the multi-lane path does, so the trap runs immediately.

- [ ] B-20260928-ADV-HEALTH-LEDGER-RACE [P4][correctness][conf 40]
**Fingerprint:** scripts/adversarial-review.sh|correctness|provider-health-ledger-concurrent-writers
**What:** pre-existing: `record_provider_health` (scripts/adversarial-review.sh:4254) rewrites the shared health ledger without a lock; concurrent reviews can lose each other's rows.
**Fix:** append-only rows or a mkdir-lock around the rewrite, with a two-writer test.

- [ ] B-20260928-SHELLCHECK-NOT-IN-CI [P3][ci][conf 80]
**Fingerprint:** ci/zuvo-pipeline-entry.yml|ci|shellcheck-ratchet-local-only
**What:** the shellcheck ratchet (tests/hooks/test-shellcheck.sh) runs only locally through run-all; no CI job runs it, so a push can land new warnings. A CI-config change affects pipelines on push, so it needs the owner's decision.
**Fix:** add a shellcheck job (or run-all's fast scope) to the CI workflow once the owner approves the CI change.

- [ ] B-20260928-STAT-PORTABILITY-SCOPE [P4][test][conf 80]
**Fingerprint:** tests/hooks/test-stat-portability.sh|test|tests-dir-not-scanned
**What:** the portability guard scans only hooks/ and scripts/zuvo-home/ (tests/hooks/test-stat-portability.sh:82); a GNU-first `stat` in a test file slipped through until the Plan B review caught it (P2-102).
**Fix:** extend the scan to tests/ (hooks, skill-suite, adversarial, lib) and fix whatever pre-existing hits it surfaces.

- [ ] B-20260928-PREFLIGHT-TEST-SCANNER [P4][test][conf 55]
**Fingerprint:** tests/hooks/test-reviewer-preflight-isolation.sh|test|comment-strip-not-quote-aware
**What:** pre-existing: the static scan strips `#…` textually (tests/hooks/test-reviewer-preflight-isolation.sh:309-325), so a token after a quoted ` #` on a code line is missed (ADV-C44/45/46/54); (17d) in tests/hooks/test-install-wiring.sh has no negative control proving the protocol came from ~/.zuvo (ADV-C28).
**Fix:** strip comments with a quote-aware awk scanner (or `bash -n`-based token walk); add a perturbed-source negative control to (17d).

- [ ] B-20260928-PREFLIGHT-TEST-REAUDIT [P3][test][conf 90]
**Fingerprint:** tests/hooks/test-reviewer-preflight-isolation.sh|test-audit|reaudit-owed-after-cap
**What:** the Plan B test-quality gate ended WARN: this file was fixed after the 2-iteration cap (a79676ab) and then changed heavily again in the review fix rounds (8efbecb2, fd51ec53 and the pass-3 round), so its tier-A score is not current.
**Fix:** `zuvo:test-audit tests/hooks/test-reviewer-preflight-isolation.sh --deep` and fix what it finds.
**Seen 2026-10-05:** re-audited by the adversarial-review split's test-quality gate (zuvo/audits/test-quality-audit-2026-10-05.md
in that worktree; in-family claude/sonnet fallback): C, 19/20 (95%) but Q11=0 — `ZUVO_PREFLIGHT_NO_CANARY=1` (scripts/reviewer-preflight.sh:124)
and the `ZUVO_BLIND_AUDIT_EFFORT` override (:660) are exercised by no test. Fix: two cases beside "11. --no-canary" (:1575) — the
env switch asserting `spy_not_ran`, the override asserting the effort the codex spy records. Out of the split's behavior scope.

## Plan C — out-of-scope follow-ups (plan 2026-09-25, recorded 2026-09-28)

- [ ] [xv-followup] B-20260928-XV-OTHER-SKILLS-ROUTING [P2][routing][conf 100]
**Fingerprint:** skills|scope|other-7-skills-not-cross-vendor-routed
**Source:** docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md, Technical Decisions "Out of scope" + Task 9 (K13). Verified in-repo: `git show --stat 199cdbe2` — that commit touched exactly 8 SKILL.md files (api-audit, code-audit, execute, refactor, review, security-audit, test-audit, ui-design-team); test-audit is the one already routed by Plan C Task 7/Task 8, leaving exactly these 7 unrouted. Confidence kept at 100 on that verification, not the plan text alone.
**What:** Plan C (Task 8) wires the cross-vendor reviewer route (Claude writer -> Codex reviewer, Codex writer -> Opus reviewer) into `test-audit` only — one of the 8 skills commit `199cdbe2` touched. The other 7 of those 8 skills still pick their reviewer the old way: refactor, review, execute, security-audit, code-audit, api-audit, ui-design-team.
**Fix:** repeat Plan C's Task 1/Task 2 pattern (route call + consumer docs/telemetry enum) for each of the 7 skills, one skill or a small batch at a time, behind its own RED case.

- [ ] [xv-followup] B-20260928-XV-CURSOR-LANE-AUTO-LOG [P3][correctness][conf 90]
**Fingerprint:** cursor-lane|correctness|requests-composer-2.5-fast-logs-auto
**Source:** docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md, Technical Decisions "Out of scope" (architect defect 6).
**What:** the cursor reviewer lane requests model `composer-2.5-fast` but its own log line records `auto`, so the log cannot be used to confirm which model actually ran.
**Fix:** find where the cursor lane's log line is written and have it log the model the `cursor-agent` CLI itself reports having used, when the CLI's output exposes one; when it does not, mark that row `model=unverified` rather than echoing back the requested id — the requested id is already known from the dispatch call and re-logging it would not confirm anything. Add a case pinning both the reported-model and the unverified-fallback path.

- [ ] [xv-followup] B-20260928-XV-REGISTRY-HOME-FIRST [P2][security][conf 90]
**Fingerprint:** driver-registry-lookup|precedence|zuvo-home-before-repo-copy
**Source:** docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md, Technical Decisions "Out of scope".
**What:** the driver's model-registry lookup reads `~/.zuvo` (the installed/HOME copy) before the repo copy. A stale or tampered `~/.zuvo` registry silently wins over the checked-in one the running repo actually ships, with no log line saying which file was actually used.
**Fix:** first decide, as a deliberate call, whether `~/.zuvo` winning is an intentional per-machine override or a security risk to close (it may be intentional — installs are meant to let `~/.zuvo` carry local state) — do not presume "flip the order" is correct without that decision. Whichever way it's decided, implement the precedence explicitly (not as an accidental side effect of lookup order) and log a line naming the exact registry file actually used on every run. Add a case with divergent repo/`~/.zuvo` registries asserting both which one wins and that the log line names it.

- [ ] [xv-followup] B-20260928-XV-AGENT-MODE-SAFE-MODE [P2][security][conf 90]
**Fingerprint:** scripts/lib/model-subprocess.sh|security|agent-access-drops-safe-mode-or-uses-danger-full-access
**Source:** docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md, Technical Decisions "Out of scope". Current state verified in-repo, 2026-09-28.
**What:** per-`--access`-level flags, precisely, for both vendors. Claude (`else` branch, scripts/lib/model-subprocess.sh:576-587): `none` (scripts/lib/model-subprocess.sh:583) passes `--tools "" --safe-mode --mcp-config "$mcp" --strict-mcp-config --no-session-persistence`; `read` (scripts/lib/model-subprocess.sh:584-585) passes `--tools "Read,Grep,Glob" --add-dir "$root" --safe-mode --permission-prompts none --mcp-config "$mcp" --strict-mcp-config --no-session-persistence`; `agent` (scripts/lib/model-subprocess.sh:586) passes only `--mcp-config "$mcp" --strict-mcp-config --dangerously-skip-permissions`. So: only the `agent` level passes `--dangerously-skip-permissions` (scripts/lib/model-subprocess.sh:586) — the other two levels never do. `agent` also drops `--tools` (no tool restriction at all, scripts/lib/model-subprocess.sh:586), `--safe-mode` (carried by `none` and `read` at scripts/lib/model-subprocess.sh:583 and :584, absent from :586), and `--no-session-persistence` (also carried by `none` and `read` at scripts/lib/model-subprocess.sh:583 and :585, absent from :586). Additionally, `agent` clears `cwd` outright (`cwd=""`, scripts/lib/model-subprocess.sh:586), so the neutral-tmp-cwd step at scripts/lib/model-subprocess.sh:589-593 (used by `none`/`read`, whose default is `cwd="$tmp/cwd"` at scripts/lib/model-subprocess.sh:558) is skipped for Claude's `agent` level — it runs in whatever directory the caller already had. Codex (`if` branch, scripts/lib/model-subprocess.sh:559-575): the CLI case arms add `-s read-only --disable shell_tool --disable unified_exec --disable view_image` for `none` (scripts/lib/model-subprocess.sh:572), `-s read-only --disable view_image` for `read` (scripts/lib/model-subprocess.sh:573, shell tool stays enabled), and no extra CLI flags for `agent` (scripts/lib/model-subprocess.sh:574); the actual sandboxing for Codex lives one layer up, in the isolated `CODEX_HOME` built by `zms_codex_home` (scripts/lib/model-subprocess.sh:559-563), whose `sandbox_mode` is `read-only` for `none`/`read` and `danger-full-access` for `agent` (scripts/lib/model-subprocess.sh:562). Codex `agent` also sets `cwd="$home"` (scripts/lib/model-subprocess.sh:574) — it runs with cwd = the isolated `CODEX_HOME` directory itself, not the neutral `$tmp/cwd` that `none`/`read` use. Net: for both vendors, `agent` access is the one level that drops the restriction the other two carry — Claude via `--dangerously-skip-permissions` replacing `--safe-mode`/`--tools`/`--no-session-persistence`, Codex via `sandbox_mode = "danger-full-access"` replacing `read-only`. Plan C deliberately left both as-is to avoid destabilizing the routing work; hardening needs re-benchmarking (tightening either surface can change lane behavior/latency, possibly breaking the shell-tool-needed use cases `agent` access exists for).
**Fix:** re-benchmark the claude/codex agent-mode lanes with Claude's `agent` arm (scripts/lib/model-subprocess.sh:586) adding `--safe-mode` (if compatible with `--dangerously-skip-permissions`) or an equivalent tool restriction, and Codex's `agent` arm (scripts/lib/model-subprocess.sh:562) scoped down from `danger-full-access` toward `workspace-write` or narrower; land the hardening only once the benchmark shows no regression, per `docs/runbook/model-benchmark.md`.

- [ ] [xv-followup] B-20260928-XV-BLIND-AUDIT-TOPUP [P3][reliability][conf 85]
**Fingerprint:** scripts/lib/blind-audit-panel.sh|reliability|no-topup-round-when-lt-2-valid-answers
**Source:** docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md, Technical Decisions "Out of scope".
**What:** the blind-audit panel has no top-up round: when fewer than 2 panelist answers come back valid, the panel proceeds (or fails) on whatever it has instead of dispatching replacement panelists to reach a minimum of 2.
**Fix:** add a top-up round to `scripts/lib/blind-audit-panel.sh` that re-dispatches to an additional eligible candidate — beyond the lanes already dispatched — when valid-answer count is below 2 AND a spare eligible candidate exists. RED fixture: at least 4 eligible candidates, 3 of them dispatched as the initial panel, 2 of those 3 answers invalid (valid=1 < 2) -> the top-up round dispatches a 4th lane from the spare candidate pool. Also assert the edge case: with no spare candidate available (e.g. exactly 3 eligible candidates total, all 3 already dispatched), the run stays degraded exactly as it does today — the top-up must not invent a phantom dispatch.

- [ ] [xv-followup] B-20260928-XV-MODEL-RUN-FANOUT [P4][tooling][conf 80]
**Fingerprint:** model-run|scope|fanout-mode-deferred-to-adoption
**Source:** docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md, Technical Decisions "Out of scope".
**What:** `model-run` currently dispatches to a single routed reviewer; a fan-out mode (dispatch to several reviewers at once, similar to the adversarial multi-provider lanes) was deliberately deferred until more skills adopt `model-run`.
**Fix:** once a second/third skill adopts `model-run` for its reviewer dispatch, add a fan-out mode reusing the existing parallel-batch-plus-`wait` pattern (CQ22) rather than each adopting skill re-implementing its own fan-out.

- [ ] [xv-followup] B-20260928-XV-WATCHDOG-FALSE-RESUME [P3][reliability][conf 70]
**Fingerprint:** stall-recovery-watchdog|reliability|false-resume-while-waiting-on-background-agent
**Source:** docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md, Technical Decisions "Out of scope"; observed during the 2026-09-25 Plan C run.
**What:** the stall watchdog reports RESUME while the orchestrator is legitimately waiting on a background sub-agent — not actually stalled. The 2026-09-25 Plan C execution run got repeated false RESUMEs from this. Opposite symptom from `B-REVIEW-INCOMPLETE-2026-08-11` (watchdog stalls with no recovery); that entry is not this defect.
**Fix:** transcript mtime alone is not a liveness criterion — a sub-agent inside one long model call or tool call can write nothing to its transcript for minutes while still legitimately working. Define the states explicitly, not as one mtime check: (1) finished and delivered a result -> not a stall, no watchdog action; (2) process exited without delivering a result -> escalate; (3) process still running AND transcript advanced within the grace window -> alive, no RESUME; (4) process still running AND transcript has NOT advanced past the grace window -> escalate (hung) — if the transcript was never written at all, anchor the window at the agent's spawn time, not at "no timestamp = infinite grace". The grace window must be configurable (not hardcoded), sized from observed long tool-call/model-call durations; 15 min is an example default, not a fixed constant. Do NOT have the orchestrator unconditionally touch the heartbeat merely because it is waiting on a sub-agent: that would mask state (4) and suppress the escalation it needs. Two cases in the same change: the actual RED case is (3) — no false RESUME while a live agent's process is running and its transcript advances within the grace window; states (1)/(2)/(4) escalating (or not) correctly is a regression guard to assert alongside it, not itself the RED case.

## B-20260927-PARSE-CQ11-470 — `zuvo_backlog_parse.py` crossed the 400-line module limit; the split is feasible and was deferred on scope, not on impossibility

[maintainability] scripts/zuvo-home/zuvo_backlog_parse.py | rule:CQ11 | sig:parse-module-over-400

Measured at PR 1 Task 1, FINAL (commit 4eaa707d): **358 → 701 raw lines / 173 → 274 `ast.stmt`**.
(An earlier revision of this entry recorded 358→470 and a review mid-round saw 567 — both were
snapshots taken before the last two fix rounds landed. ~140 of the growth is comment and docstring
prose in this file's house style, not statements.)

Original measurement, kept for the record: **358 → 470 raw lines / 173 → 225 `ast.stmt`**, against the 400-line default
for Python modules in `rules/file-limits.md:257` (800 is the automatic CQ11 FAIL, so this is over the
default and under the hard fail). The file was compliant before this task. Every function is within
its limit — `iter_entries` ~37 executable lines, and the four new private helpers (`_requested_kinds`
9, `_body_kinds` 8, `_body_status` 7, `_heading_entry` 19) are all well under 30.

**The implementer's justification was wrong and is not the reason this is deferred.** It argued the
flattened `~/.zuvo/` layout forbids splitting because `import zuvo_backlog_parse` must resolve as one
module. Both reviewers disproved it independently and identically: `backlog-archive.py:35` and
`backlog-collect.py` each do `sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))` then a
plain same-directory sibling import — and `scripts/install.sh` (~:826) flattens every file from
`scripts/zuvo-home/` into that one directory. **This plan's own Task 5 relies on exactly that
mechanism** to add a sibling `zuvo_backlog_io.py`. So a sibling `zuvo_backlog_kinds.py` holding
`KIND_*`, `DEFAULT_KINDS`, `_requested_kinds`, `_body_kinds`, `_body_status` and `_heading_entry`
would resolve identically and bring the module back under 400.

Deferred for one reason only: a module split is outside Task 1's frozen scope (execute's SCOPE-FREEZE
rule), and the same plan's Decision 8 already set the precedent of recording an overage with its
numbers rather than widening a task — it does so for `backlog-archive.py` at
`docs/specs/2026-09-27-backlog-heading-entries-plan.md:124`. Recording it here keeps the two
consistent. This is a real defect with a known, proven-cheap fix, not an accepted invariant.

Function lengths are all compliant after Task 1's final round (`_iter_entries` 27 stmt, `_heading_line` 22,
`_heading_entry` 22 — under the 30-line private-helper limit); only the MODULE size is over.

Fix: extract the kind/heading helpers into `scripts/zuvo-home/zuvo_backlog_kinds.py`; no call site
changes, since consumers import `zuvo_backlog_parse` and the names stay re-exported. Verify with
`rt --light bash tests/hooks/test-backlog-headings.sh` + `test-backlog-archive-dedup.sh` unedited, and
the local ruff/mypy gate.
confidence:95 source:task-1-quality-review + task-1-spec-review (converging, both with the disproof)

## B-20260927-CNFH-NEVER-COUNTED — the mandatory `command_not_found_handle` typo guard has never incremented FAIL, in any suite, on any bash

[reliability] tests/hooks/*.sh (the whole suite family, starting with test-backlog-archive-dedup.sh) | rule:false-green | sig:cnfh-subshell-fail-lost

Measured 2026-09-27 on bash 5.3.15 with a minimal probe:

    FAIL=0
    command_not_found_handle(){ echo "handler fired: $1"; FAIL=$((FAIL+1)); return 127; }
    definitely_not_a_command_xyz 2>/dev/null
    -> handler FIRES and prints, and FAIL is still 0.

Bash runs the handler in a subshell, so the `FAIL=$((FAIL+1))` inside it is discarded. The guard
therefore produces a visible line and a 127 exit status, and **counts nothing**. A suite whose helper
name is misspelled in a bare call still prints `RESULT: … FAIL=0` and exits 0. It happens to be
partially covered when the misspelled call sits in an `if` condition, because the `else` branch fires
the suite's own `no()` — but that is the assertion working, not the guard.

This convention is documented as the protection against exactly that class of false green, is copied
across the `tests/hooks/` family, and was mandated verbatim in this plan's own Quality Strategy. Two
adversarial providers (agy, kimi) found it independently in the same round; the probe above is the
orchestrator's own confirmation, not their report.

Separately and additionally: `command_not_found_handle` is **bash 4+**. On `/bin/bash` 3.2.57 (the
macOS default) it does not exist at all, so on that interpreter the guard is absent rather than
merely ineffective — and `tests/hooks/test-backlog-headings.sh` was measured to also fail H7/H8 under
bash 3.2 because 3.2 mis-parses nested double quotes inside `$(py "…")`. The suite family is de facto
bash-4-only while the repo's stated convention is bash-3.2 compatibility.

Fix: persist the evidence across the subshell boundary — have the handler append to a marker file
under the suite's temp dir and turn a non-empty marker into a real FAIL at RESULT time. PR 1 does this
for `test-backlog-headings.sh` only, because `test-backlog-archive-dedup.sh` must stay byte-identical
while it is the regression gate for that PR. Every other suite in the family still needs it, and the
bash-4 requirement should be stated once, centrally, rather than rediscovered per suite.
confidence:98 source:orchestrator probe + agy + kimi (converging, adversarial pass 2)

## B-20260928-VERIFY-HEADING-BLIND — the two-file namespace check cannot see a heading id in both files

[reliability] scripts/zuvo-home/backlog-archive.py (undeclared_pairs / cmd_verify) | rule:adversarial-task-2 | sig:verify-checkbox-only-namespace

`cmd_verify` and `undeclared_pairs` index both files with `kinds=(zb.KIND_CHECKBOX,)` — deliberately,
because they sit on the write/gate side of PR 1's read/write boundary. But `lookup` and `cmd_index` now
resolve heading entries, so the namespace question they answer is narrower than the namespace the
lookup actually spans: **a heading id present in BOTH `backlog.md` and `backlog-done.md` is never
flagged as a violation**, while the same situation with a checkbox id is.

Latent, not live: measured 2026-09-27 across all fleet backlogs, there are **0** heading entries in any
`backlog-done.md`. It becomes reachable the moment PR 1 Task 4's `ZUVO_BACKLOG_HEADING_ARCHIVE` path
archives the first heading entry, and `append-runlog` turns a `verify` violation into exit 2 — so the
first heading archived into a file that already holds that id would produce a namespace inconsistency
nothing reports.

Found by `muse` in the Task 2 adversarial round. The fix is NOT to widen the write paths: make only the
**read-only** disjointness check heading-inclusive, keeping every rewrite checkbox-only, and add the
cross-dialect case (a checkbox id in one file, the same id as a heading in the other).
confidence:85 source:adversarial-task-2 (muse)

## B-20260928-INDEX-UNLOCKED-SNAPSHOT — cmd_index reads backlog and archive without the archive lock

[reliability] scripts/zuvo-home/backlog-archive.py (cmd_index) | rule:adversarial-task-2 | sig:index-mixed-snapshot

`cmd_index` reads `backlog.md` and `backlog-done.md` in two separate unlocked reads and publishes
`.backlog-index.tsv` from the pair. `cmd_archive` writes the archive first and the open file second, so
an index built between those two renames publishes a **mixed snapshot**: an entry counted in both
files, or in neither. Pre-existing — this task only widened which kinds the index covers, it did not
change the locking — and the same class as the comment already at `cmd_verify`, which takes the lock
for exactly this reason and falls back to an unlocked read only when the lock cannot be had.

Fix: take the archive lock around both reads, or re-stat both files after the reads and refuse to
publish when either moved. Note the index is advisory (nothing gates on it), which is why this is a
correctness wart rather than an outage.
confidence:80 source:adversarial-task-2 (codex-5.3)

## B-20260928-ARCHIVE-OVERLAP-DEADLOCK — two consecutive indented ticked children make a repo unable to archive anything, ever

[reliability] scripts/zuvo-home/backlog-archive.py (cmd_archive line accounting) + zuvo_backlog_block.py (entry_block, bullet dialect) | rule:adversarial-task-4 | sig:archive-overlap-accounting-mismatch

Found while building PR 1 Task 4 and **reproduced against the UNMODIFIED archiver**, so it is
pre-existing and independent of the heading dialect. Two consecutive *indented* ticked children
(`  - [x] …` twice in a row) produce overlapping `entry_block` ranges for the bullet dialect. The
overlap trips `cmd_archive`'s own line-accounting invariant, which fails **closed**:
`internal: line accounting mismatch` and the whole run is refused.

Consequence is larger than it first looks: the refusal is not scoped to the offending pair. A repo whose
backlog contains that shape **never archives anything at all** — every resolved entry in it stays in the
open file indefinitely, and `status` keeps reporting them as overdue, which reads as "nobody ran the
archiver" rather than "the archiver cannot run here". Fail-closed is the right instinct and is why this
never corrupted a file; the cost is a silent, permanent stall.

Out of PR 1's fence: the defect is in the BULLET dialect's boundary handling, while PR 1 Task 3 rewrote
the HEADING boundary and deliberately kept bullet behaviour byte-identical (asserted). Fixing it means
touching the bullet span rule, which every one of the 32 dedup-suite assertion groups pins.

The fail-closed half is now pinned by a test in `tests/hooks/test-backlog-headings.sh` (Task 4), so a
future change cannot turn the refusal into a silent partial move — that is the dangerous direction.

Fix: make `entry_block` yield non-overlapping ranges for consecutive indented ticked children, then
assert per-entry span disjointness across the whole file rather than only checking line accounting at
move time. Verify with the 32-group dedup suite unedited.
confidence:95 source:task-4 implementation, reproduced on the unmodified archiver

## B-20260928-HEADING-GATE-PROCESS-GLOBAL — the heading-archive gate is process-global, so one `export` enables it in all 88 checkouts

[reliability] scripts/zuvo-home/zuvo_backlog_heading.py (the ZUVO_BACKLOG_HEADING_ARCHIVE gate) | rule:adversarial-task-4 | sig:heading-gate-no-repo-opt-in

PR 1 Task 4 gates heading archiving behind `ZUVO_BACKLOG_HEADING_ARCHIVE=1`, and the gate is strict
about its value — measured: unset / `0` / `2` / `true` / `11` all leave it closed, only the literal `1`
opens it. That strictness is deliberate, because a well-meaning `=true` would otherwise enable a write
path across the fleet.

What it does NOT have is a per-repo opt-in. The variable is process-global, so a single `export` in a
shell profile, a CI job definition or an agent harness enables heading archiving in **every** checkout
that process touches — and `append-runlog` runs `backlog-archive.py archive --repo "$PWD"` on every
skill run in every repo, so the blast radius is all 88. The design intends a deliberate, temporary,
operator-supervised enablement; nothing enforces the "temporary" or the "this repo".

Raised by `muse` in the Task 4 adversarial round. Out of PR 1's fence: changing the gate's shape after
four tasks were built and reviewed against it would invalidate the pin guard's env-gated category and
the default-off byte assertions.

Fix: require a repo-local marker alongside the env var (e.g. a `memory/.backlog-heading-archive` file,
or a `backlog-protocol.md`-registered per-repo flag), so enabling it is an explicit act in the repo
whose file is about to be rewritten — and consider having `install.sh`/`append-runlog` scrub the
variable so an inherited environment cannot carry it into an unrelated repo.
confidence:80 source:adversarial-task-4 (muse)

## B-20260928-ARCHIVE-CQ11-722 — `backlog-archive.py` is still over the 400-line module default after Task 5's io split; the two oversized functions are fixed, the module is not

[maintainability] scripts/zuvo-home/backlog-archive.py | rule:CQ11 | sig:archive-module-over-400

Measured at PR 1 Task 5, with `tests/hooks/test-backlog-headings.sh` (H24c) printing the same numbers
on every run so this cannot go quiet:

| | before (945f48ed) | after |
|---|---|---|
| `backlog-archive.py` RAW lines | **763** | **722** |
| `backlog-archive.py` `ast.stmt` | 401 | 337 |
| `cmd_archive` RAW / BODY | 145 / **95** | 71 / **41** |
| `cmd_drop_stale` RAW / BODY | 99 / **62** | 65 / **39** |
| `zuvo_backlog_io.py` RAW / `ast.stmt` | — | 181 / 100 |

`rules/file-limits.md:252-260` gates a Python **module** on RAW lines — 400 default, 800 the automatic
CQ11 FAIL — and a **function** on BODY lines (public ≤ 50, private ≤ 30; signature, docstring,
comments and blank lines excluded). So the FUNCTION half of this file's CQ11 debt is CLOSED: both
commands are now inside 50, the seven private helpers Task 5 extracted measure 6-17 body lines each,
and no other function in either module crosses its limit. `ast.stmt` is recorded as an observation
only — `rules/file-limits.md` never mentions it and it is not a gate.

What is NOT closed is the module: **722 raw, 322 over the 400 default** and 78 under the hard fail.
The io split removed 41 net raw lines rather than the ~120 it moved, because each of the four sibling
modules carries its house-style justification in prose and the archiver gained docstrings for seven
new helpers. That is the honest accounting: the split bought a 763→722 module plus a 181-line sibling,
and it was worth doing for the FUNCTION gate and the two-layout import contract, not for the module
count.

**What remains extractable, measured, not estimated** — and deliberately not understated, because an
earlier entry in this plan (`B-20260927-PARSE-CQ11-470`) recorded a "the flattened layout forbids a
sibling" justification that two reviewers disproved, and Task 5 then created that sibling twice over:

1. **the READ-DIALECT block — 68 raw lines** (`LOOKUP_KINDS`, `_lookup_kinds()` and the comment block
   stating why the read dialect is spelled out rather than derived). Self-contained, one concern, and
   a natural `zuvo_backlog_kinds.py`-shaped sibling. The catch is a REAL one and is why this is a
   backlog entry and not a fifth extraction inside Task 5: `tests/hooks/test-backlog-headings.sh`
   H14b/H14c quote `LOOKUP_KINDS`' exact text out of THIS file (`mkmut`'s `EXPLICIT`/`DERIVED`
   constants) and assert that the contract fires on the READ path and not at import. Moving it is a
   test-and-code change, not a motion.
2. **`classify()` — 61 raw lines.** It is classification POLICY, and `zuvo_backlog_heading.py` already
   owns the heading half of exactly that policy. Moving it keeps the family's pin totals at 7/2/1
   (H19c asserts them over the family, not per file), so it is admissible — but it moves a PINNED
   `iter_entries` site between modules, so the per-file expectations in H14 and H19c move with it.

Both together are ~129 raw lines, so even doing both leaves the module near 590: **under 400 is not
reachable by extraction alone.** 131 of the 722 lines are comment-only and 84 are blank, which is this
codebase's documented house style and not slack to be reclaimed. Getting genuinely under 400 means
splitting the ten `cmd_*` entry points across modules (a reporting module for `status`/`verify` output,
a settle module for `drop-stale`) — an architecture change with its own review, which is what this
entry is asking for rather than another round of extraction.

Also closed by Task 5, and recorded here because its own entry is left open on purpose:
`B-20260922-CMD-ARCHIVE-FUNCTION-LENGTH` (`cmd_archive-91L-cmd_drop_stale-83L`) asked for exactly
these two extractions and is satisfied — `_partition_movable`, `_print_dry_run`,
`_refuse_tracked_archive`, `_entry_block_to_move`, `_build_sections`, `_write_archive_sections`,
`_keys_for_ids` and `_settle_targets` are its `_validate…`/`_partition…`/`_write…` seams under measured
names. Its checkbox is deliberately NOT ticked yet: a ticked entry is archivable, and this plan's
SMOKE1 compares `status`'s open count and `memory/backlog.md`'s sha256 against a baseline taken after
Task 5 commits. Tick it when the smoke runner has its baseline, not before.

confidence:95 source:task-5 measurement (tests/hooks/test-backlog-headings.sh H24c, printed every run)

## B-20260928-RT-SKIPS-LINT-GATES — routing the python-lint and shellcheck gates through `rt` makes them exit 0 without running; the plan's own Verify line does this

[testing] docs/specs/2026-09-27-backlog-heading-entries-plan.md, docs/runbook/testing.md | rule:Q9 | sig:rt-skips-lint-gate

Measured 2026-09-28 during PR 1 Task 5. `rt --light bash tests/hooks/test-python-lint.sh` exits **0**
on waw-tf while printing, into the part of the stream `rt` hides by default:

    SKIP: neither ruff nor mypy installed - the Python lint gate did NOT run.

The farm image carries neither `ruff` nor `mypy` nor `shellcheck`, so three gates that exist to be
hard — mypy at zero errors, the ruff ratchet, the shellcheck warning ratchet — are skipped, and the
suite reports success. `rt` hides the SKIP line behind `N line(s) hidden`, so the only thing an agent
sees is `tf: exit 0`. Task 5's own run hit this: the gates that decide whether a brand-new module's
type annotations are real were never executed, and the first reading was GREEN.

This is not an agent mistake. **Task 5's Verify line in the plan names `rt --light` for this suite**,
and `docs/runbook/testing.md` does not say which of the five commands the farm cannot run. Every
earlier task in this plan ran the same command and got the same false green; it went unnoticed
because those tasks had no new `.py` file whose annotations had never been checked.

Two independent defects, and the ordering matters — fixing only the second leaves the trap armed:

1. **The suites exit 0 when their own tool is missing.** A lint gate that cannot find its linter must
   FAIL, not skip: this is the `^SKIP:`-as-false-green class this very plan spent Task 1 removing from
   `run_one()`. Proposed: exit non-zero unless `ZUVO_LINT_TOOLS_OPTIONAL=1` is set, so a host that
   genuinely lacks the tool opts out explicitly and attributably, instead of every host opting out
   silently. `run-all.sh` aggregating them as SKIP is then correct behaviour rather than a mask.
2. **The routing is wrong and is written down.** `docs/runbook/testing.md` should state, per command,
   whether it runs on the farm — and `~/.claude/hooks/farm-no-local-tests.sh` should not push a
   suite to a host that cannot run it. The honest split today: headings / dedup / run-all on the
   farm, python-lint and shellcheck **locally** (ruff 0.15.20, mypy 2.1.0, shellcheck 0.11.0 are all
   present on the Mac and absent on waw-tf).

Cheapest real fix for (2) alone: install the three tools on the farm image, which removes the
divergence rather than documenting it. That is one `apt`/`brew` line per farm host and it makes
`rt --light` correct for all five commands — worth checking before writing per-command routing prose
that will drift.

Until either lands, the rule for this repo is: **a green from `rt` on a lint suite is not evidence.**
Read `rt --log <runid>` and look for `SKIP:`, or run those two suites locally with
`TF_ALLOW_LOCAL=1`.

- [ ] B-20260928-RT-SKIPS-LINT-GATES make a missing linter FAIL rather than SKIP, and fix the routing
      (install the tools on the farm, or document the per-command split) so a lint gate cannot report
      success without running

confidence:100 source:task-5 measurement (rt --log 1790562894-18183-30547 vs the same suite locally)

## B-20260928-IO-PREEXISTING-DATALOSS — SIX data-safety defects in the backlog io layer, all PRE-EXISTING and now visible in one place; four of them can lose a user's text and two of those defeat an existing guard

[reliability] scripts/zuvo-home/zuvo_backlog_io.py, scripts/zuvo-home/backlog-archive.py | rule:CQ14 | sig:backlog-io-datasafety

Surfaced by Task 5's cross-model adversarial round (5 providers), which reviewed `resolve`/`read`/
`is_ignored`/`Lock`/`atomic_write` for the first time because Task 5 moved them into their own module
and so put them in a diff. **Every one is pre-existing, and that is measured, not assumed:** the five
moved definitions are BYTE-IDENTICAL to their text at the plan base `e565df29` (compared by AST
extraction, not by eye), and `if ln not in new_archive` sits at `e565df29:backlog-archive.py:504`.
Task 5's contract was a verbatim move with zero behaviour change — the dedup suite staying
byte-identical at 138/0 is the assertion that it was one — so fixing these inside that commit would
have destroyed the only property that made the refactor reviewable. Deferred on FENCE, not on size.

**1. `read()` uses `errors="replace"` — silent, permanent corruption.** (3 providers, CRITICAL.)
A backlog containing one non-UTF-8 byte — a Latin-1 smart quote, a multibyte character truncated by
an earlier interrupted write — is read "successfully" with that byte replaced by U+FFFD, then written
back by `atomic_write`. The original bytes are gone, no error is raised, and because entry keys are
content-derived the replacement can also change a key and quietly break `verify`/`drop-stale`
matching. The fail-open that exists to keep `cmd_status` from tracebacking on a MISSING file is here
silently mutating an EXISTING one. Fix: `errors="strict"`, catch `UnicodeDecodeError`, refuse the run
naming the file and byte offset. Note the blast radius before changing it: `read()` is on the
`cmd_status` path that `append-runlog` runs in every repo on the machine, so a hard failure there
must still not gate a skill run.

**2. The archive conservation check is substring-based, not line-based.** (3 providers, CRITICAL.)
`if ln not in new_archive` searches the WHOLE archive string, so a moved line that is a substring of
any other archive line — or a blank line, or a short duplicate — satisfies the check even when its
block was never appended. The source copy is then deleted anyway. This is the guard that exists to
make "the text was moved, not lost" true, and it can pass while text is lost. Fix: compare
`collections.Counter` of the moved lines against the archive's added lines, per line, and refuse on
any shortfall.

**3. `atomic_write`'s temp file is predictable and follows symlinks.** (2 providers, CRITICAL.)
`.{basename}.tmp.{pid}` opened with plain `open(tmp, "w")` — no `O_EXCL`, no `O_NOFOLLOW`. A local
user who can write the directory can pre-plant a symlink at the predicted name and have the archiver
truncate the target as the invoking user. Two same-pid writers also collide on the one name. Fix:
`tempfile.mkstemp(dir=d, prefix=...)` or `os.open` with `O_CREAT|O_EXCL|O_NOFOLLOW`, chmod, fsync,
then `os.replace`. Lower real-world exposure than 1 and 2 (the directory is a repo's `memory/`), but
the fix is four lines and removes the class.

**4. `Lock`'s stale reclaim is a TOCTOU window.** (1 provider, CRITICAL.) `_stale()` decides, then
`_force_release()` acts — between them another process can legitimately take the lock, and that
process's lock is the one deleted. Also flagged: a missing/truncated pid file makes `_stale()` true
after `STALE_LOCK_S` regardless of liveness. Fix: re-read the pid file and the lock dir's mtime
immediately before `_force_release()` and abort the reclaim if either moved.

**5. The archive and the backlog are written by TWO sequential `atomic_write` calls with no rollback.**
(1 provider, CRITICAL.) `atomic_write(archive, ...)` then `atomic_write(real, ...)` — pre-existing at
`e565df29:510-511` and `:610-611`, unchanged at `:498-499` and `:684-685`. If the second fails (disk
full, permissions, OOM kill, SIGKILL in the window) every moved entry exists in BOTH files: exactly the
"same id in both files" state this module's `verify` gate and `_partition_movable` exist to catch, so
the next run hard-blocks — or, through the heading blind spot recorded in
`B-20260928-VERIFY-HEADING-BLIND`, splits the namespace silently. Each write is atomic; the PAIR is
not, and the in-function comment already concedes the conservation checks prove "nothing was lost,
never that nothing was duplicated" — duplication being precisely what this window produces. Fix: on a
failure of the second write, truncate the archive back by the appended bytes and re-raise; at minimum
print a recovery instruction naming the appended section header.

**6. `drop-stale` never checks the OPEN entry's status, so a REOPENED entry is dropped as a stale
duplicate.** (1 provider, CRITICAL.) `_settle_targets` (pre-existing logic, identical in
`e565df29:cmd_drop_stale`) approves removal on `arch_all[key].status == "done"` plus a resolution
marker in the ARCHIVED body, and never asks whether the open copy is still ticked. Untick an entry to
reopen it and the open block is deleted while the archive keeps the old closure — active work
disappears. This is not hypothetical in this codebase: Task 1 added `REOPEN_RE` to heading status
precisely because reopening is a real, modelled state. Fix: refuse unless the open copy is also
resolved, or the two bodies still describe the same item, with a message that names the divergence.

REFINEMENT to 2, from the untruncated re-review: the fix is not merely line-aware counting — the check
must run against `appended` (the bytes this operation adds), not `new_archive` (the whole file). A
moved line that already exists in the OLD archive satisfies `ln in new_archive` even when `appended`
came out empty, so the entry is deleted from the open backlog having been added to nothing.

REJECTED BY MEASUREMENT, recorded so they are not re-filed: `is_ignored()` does NOT crash on a
non-git directory — `sh()` (`zuvo_backlog_parse.py:157-167`) returns `""` on any failure, catches
`OSError`/`SubprocessError` and carries `timeout=15`, so `"" != "true"` returns `None` exactly as the
docstring says. Three providers could not see `sh()` because it lives in the parser, which their
chunk did not contain. (The `git check-ignore` call does lack a `timeout=`; minor, pre-existing, fold
it into 1-4.)

Six defects, one file, all pre-existing; 1, 2, 5 and 6 can each destroy a user's text, and 2 and 5
defeat the very guards written to prevent exactly that.

- [ ] B-20260928-IO-PREEXISTING-DATALOSS fix 2, 5 and 6 first (each defeats an existing safety guard),
      then 1, then 3 and 4; each needs a test that fails before the fix — for 1 a fixture with a real
      non-UTF-8 byte, for 2 a moved line already present in the old archive with `appended` forced
      empty, for 5 a second `atomic_write` made to raise, for 6 an entry ticked in the archive and
      unticked in the open file

confidence:95 source:adversarial-task-5 (5 providers; pre-existing status verified by AST comparison against e565df29)

## 2026-09-29 zuvo:review — integrate/codex-batch-0928 (structural findings, recipes)

- [ ] B-20260929-ADV-REVIEW-SPLIT [P3][structural-refactor][conf 90]
**Fingerprint:** scripts/adversarial-review.sh|CQ11|god-file-top-level
**Source:** zuvo:review structure auditor, 2026-09-29 (4790 lines, 59% top-level; +533 in this range).
**What:** The blind-audit wiring (~:632-851) and the provider detection / run_* lanes live inline in the driver.
**Fix:** Move the blind-audit wiring into scripts/lib/blind-audit-panel.sh, then detect_providers and the run_* lanes into scripts/lib/adv-providers.sh (sourced beside the driver like model-subprocess.sh). Target < 2500 lines. Defer-reason: structural-refactor (multi-file).

- [ ] B-20260929-PREFLIGHT-SECTIONS [P3][structural-refactor][conf 75]
**Fingerprint:** scripts/reviewer-preflight.sh|CQ11|top-level-sections
**Source:** zuvo:review structure auditor, 2026-09-29 (224 -> 917 lines; ~500 lines of top-level sections).
**Fix:** Convert the route (1/1a), panel (2) and canary (3) sections into functions (pf_route, pf_panel, pf_canary) so each is testable alone. Defer-reason: structural-refactor (multi-file: tests move with it).

- [ ] B-20260929-INSTALL-ZUVO-HOME-SPLIT [P3][structural-refactor][conf 80]
**Fingerprint:** scripts/install.sh|CQ11|install_zuvo_home-260L
**Source:** zuvo:review structure auditor, 2026-09-29.
**Fix:** Extract `_zuvo_home_install_or_drop <label> <src> <dst> <detail>` from the four install-or-drop-stale blocks, then split install_zuvo_home by artefact class. Defer-reason: structural-refactor (multi-file: test-install-* fixtures).

- [ ] B-20260929-ZMS-LOCATOR-COPIES [P4][structural-refactor][conf 60]
**Fingerprint:** scripts/adversarial-review.sh,scripts/reviewer-preflight.sh,scripts/zuvo-home/model-run|CQ14|zms-locator-loop
**Source:** zuvo:review structure auditor, 2026-09-29.
**What:** The locate-and-validate loop for model-subprocess.sh exists three times; it cannot live in the library it locates (bootstrap).
**Fix:** Pin the three loops with a byte-identity test (normalising the function list), or generate them from one template at build. Defer-reason: structural-refactor (multi-file).

- [ ] B-20260929-CODEX-LANE-REPORTER [P4][structural-refactor][conf 45]
**Fingerprint:** scripts/build-codex-skills.sh|CQ14|own-lane-scan-reporter
**Source:** zuvo:review structure auditor, 2026-09-29.
**Fix:** Give zrl_scan_and_report_lanes a --toml mode and replace the Codex build's bespoke reporter (~:1035-1082). Defer-reason: structural-refactor (multi-file).

- [ ] B-20260929-PREPUSH-FASTPATH-SUBSTRING [P3][security][conf 55]
**Fingerprint:** hooks/pre-push-gate.sh|gate|legacy-substring-git-push
**Source:** adversarial passes, 2026-09-29 — pre-existing (gate_legacy had the same `*"git push"*` predicate before this range), so not fixed in the integration.
**What:** The PreToolUse layer only engages on the literal `git push`; `git -C dir push`, `git -c x push` and quote-concatenated forms skip it. The git-native pre-push hook still gates the actual push.
**Fix:** Match push the way block-no-verify.sh does (strip quotes/backslashes, tokenize, find the subcommand after git's global options), keeping the fast path a superset.
**Seen again:** 2026-10-05 (hook-perf session leftovers) — re-verified on main 6e098f3d: the b0e65d51 JSON fast path (:30-33) kept the same literal predicate, so `git -C . push origin main` and `git  push` (two spaces) still exit before the gate. Where a repo-local `core.hooksPath` (Husky) bypasses the global dispatcher, this layer is the ONLY local block.

## B-20260929-MANIFEST-AGENT-COUNT-STALE — the three manifests claim "26 specialized agents" against 49 real unique names, and nothing gates the number

[maintainability] .claude-plugin/plugin.json, .codex-plugin/plugin.json, package.json | rule:CQ14 | sig:manifest-agent-count

MEASURED 2026-09-29, before Task 3 of the backlog-grooming plan added its own agent file:

    find skills -path '*/agents/*.md' | wc -l                                     -> 50
    find skills -path '*/agents/*.md' -exec basename {} .md \; | sort -u | wc -l  -> 48

and after it: **51 files, 49 unique names**. All three manifests carry the identical string
`"58 skills and 26 specialized agents"`. The skill half is right and is GATED —
`scripts/validate-skills.sh`'s `count-consistency` check derives 58 from `skills/` and blocks a
release on a stale one. The agent half is wrong by nearly a factor of two and is gated by NOTHING, in
any of the three files, which is why it drifted from 26 to 48 unmarked while the number beside it
stayed correct.

**Not fixed in passing, deliberately.** Task 3 added one agent file and updated `CLAUDE.md`'s own
"50 agent files, 48 unique names" line, which is the claim its change actually moved. Editing the
three manifests in the same commit would have put an unrelated, ungated, ~2x correction inside a diff
whose reviewable property is that it adds a verifier lane — and a wrong number quietly becoming a
right number is exactly the kind of change that should be attributable to someone who checked it.

Fix: extend `count-consistency` to derive the agent count the same way it derives the skill count
(unique basenames under `skills/*/agents/`, not file count — `cq-auditor` and `spec-reviewer` each
exist twice with DIFFERENT content and are two files, one name), then correct all three manifests in
the commit that adds the gate. Without the gate the fix is worth one release.

confidence:100 source:task-3-backlog-grooming (both counts derived from the tree, not read from a document)

## Plan C aggregate review — pre-existing and out-of-fence follow-ups (zuvo:review, recorded 2026-10-01)

Everything the review found INSIDE the Plan C fence was fixed in-run (fix commits 3f330a5a..ebd37217). These are
the items that predate Plan C or sit outside its fence; report: memory/reviews/ (Plan C aggregate, 2026-10-01).

- [ ] [xv-review] B-20261001-XV-INSTALL-HOST-INSTALLER-DUP [P3][maintainability][conf 85] [structural-refactor (multi-file)]
**Fingerprint:** scripts/install.sh|CQ14|host-installers-share-17-25-line-blocks
**Source:** Plan C aggregate review, CQ auditor CQ-4 (pre-existing, not changed by Plan C).
**What:** `install_codex`, `install_cursor`, `install_antigravity` and `install_kimi` share 17-25-line normalised blocks (difflib: codex-cursor 25+13+10, every other pair 17-18); `install_kimi` is 185 lines, `install_claude` 155, `install_codex` 156, `install_antigravity` 146 against the 50-line function limit.
**Re-measured 2026-10-05** at 6e098f3d, after the install.sh split into scripts/install.d/ and the provenance fixes (non-blank, non-comment lines per function): `install_cursor` 202 (cursor.sh:8), `install_kimi` 187 (kimi.sh:15), `install_codex` 183 (codex.sh:9), `install_claude` 163 (claude.sh:92), `install_antigravity` 148 (antigravity.sh:9), `install_zuvo_home` 130 (zuvo-home.sh:88), `check_cross_providers` 53 (install.sh:238) — all grew; the split moved them verbatim and decomposed only `install_claude_home`. Seen again by zuvo:refactor 1f022802 (seen:2).
**Fix:** 1) extract the shared "build dist → verify → copy skills/agents/shared → record provenance" sequence into `install_dist <target> <build-script> <dest-root>`; 2) keep only each host's genuinely different step (Kimi's config.toml hooks merge, Codex TOML agents) in its own function; 3) prove with tests/hooks/test-install-wiring.sh unchanged plus a byte-identical install into two scratch HOMEs before/after.

- [ ] [xv-review] B-20261001-XV-BUILD-PREEXISTING-SHELL [P3][reliability][conf 60]
**Fingerprint:** scripts/build-*-skills.sh|reliability|preexisting-unchecked-pipeline-and-patterns
**Source:** Plan C aggregate review, adversarial pass 1 (ADV-8, ADV-28, ADV-29, ADV-32), classified PRE-EXISTING by the re-scorer (Plan C only prepended normalisation around these lines).
**What:** four older patterns in the dist builds: a `... > "$dst"` pipeline whose status is not checked (build-antigravity-skills.sh, agent adapt), `rules/*.md` loops without a `[ -f ] || continue` guard in the Cursor build (Kimi has it), `grep -cE "^\s+- (Write|Edit)"` relying on BSD grep accepting `\s` (Cursor and Codex), and unanchored `model: sonnet|opus|haiku` rewrites in the Kimi build.
**Fix:** one pass over the four builds: check the pipeline status, add the `-f` guard, use `[[:space:]]`, anchor the rewrites to the frontmatter key; RED case per item in scripts/tests/reviewer-model-builds.bats.

- [ ] [xv-review] B-20261001-XV-TESTAUDIT-RUBRIC-PREEXISTING [P3][correctness][conf 70]
**Fingerprint:** shared/includes/test-audit-batch-prompt.md|correctness|auto-tier-d-set-and-q21-selection
**Source:** Plan C aggregate review, adversarial pass 1 (ADV-104, ADV-109, ADV-111); these rubric defects predate the include's extraction (3bbfce42 moved the text unchanged).
**Update 2026-10-05:** the AP13 half of "the red flags are JS-only" is fixed in 6a1dbebb (AP13 counts each runner's own assertions); the AUTO TIER-D set mismatch (AP31) and the Q21 selection rule below are still open.
**What:** the AUTO TIER-D red-flag set named at the top of the prompt and the one used in the SHORT format disagree (AP31); Q21 evidence selection contradicts the scoring rule a few lines below; the red flags are JS-only, so bash and pytest suites land in Tier D for lack of a matching idiom.
**Fix:** decide one AUTO TIER-D set and reference it from both places; rewrite the Q21 rule to match the scoring; add language-neutral forms of the red flags (bash `ok`/`bad` helpers, pytest `assert`) and a dispatch-test case per language. Note the machine contract (`Tier: A-D|INCOMPLETE`, the DONE gate) is already consistent — this is rubric content only.

- [ ] [xv-review] B-20261001-XV-CODEX-LOCK-OWNER [P3][reliability][conf 60]
**Fingerprint:** scripts/zuvo-home/test-audit-batch|reliability|lock-owner-ppid-unverified-on-codex
**Source:** Plan C Task 8 acceptance + aggregate review.
**What:** test-audit 1a passes `--owner "$PPID"` so the run lock names the harness process. That holds on Claude Code (verified live). On a Codex host each tool call may get a fresh parent; the design makes that STOP the group call rather than run unprotected, but no run on a real Codex host has confirmed which of the two happens.
**Fix:** one live test-audit run from Codex CLI on a two-file target; record whether the group call runs or STOPs; if it STOPs, pass a session-stable owner (the Codex session id from the environment) instead of `$PPID`.

- [ ] [xv-review] B-20261001-XV-CODEX-EXEC-HOST-SIGNALS [P3][correctness][conf 55]
**Fingerprint:** scripts/lib/model-subprocess.sh|correctness|codex-exec-shell-lacks-host-signals
**Source:** Plan C execution notes (Tasks 5 and 8).
**What:** a shell started by `codex exec` does not carry the four signals `zms_is_codex_host` checks, so a nested route from inside a Codex exec run can classify its writer as unknown instead of Codex.
**Fix:** measure which variables `codex exec` actually exports (a one-shot `env` dump through the real CLI, owner-run), then extend `zms_is_codex_host` with the one that is stable, plus a test with that environment.

- [ ] [xv-review] B-20261001-XV-DIST-BUILD-FRESH-NONATOMIC [P3][reliability][conf 60]
**Fingerprint:** tests/lib/dist-build.sh|reliability|fresh-publishes-non-atomically
**Source:** Plan C execution notes (Task 4).
**What:** `tests/lib/dist-build.sh --fresh` removes and rebuilds the cached dist in place, so a concurrent suite reading the cache can see a half-built dist.
**Fix:** build into a sibling temp dir and `mv` it over the cache path (atomic rename), keeping the old one until the rename succeeds; a test with two concurrent `--fresh` calls.

- [ ] [xv-review] B-20261001-XV-NO-CI [P2][infra][conf 90]
**Fingerprint:** .github/workflows|CQ40|no-ci-for-the-shell-suites
**Source:** Plan C aggregate review (CQ auditor, CQ40); see also ci/zuvo-pipeline-entry.yml, which exists but is not enabled.
**What:** the repo has no CI workflow; tests/run-all.sh runs only where someone runs it, so a red like the python-lint ratchet reaches main unnoticed.
**Fix:** a workflow on the self-hosted runners that runs validate-skills, gate-consistency and run-all (bats via `npx --yes bats@1.11.0`), plus enabling the pipeline-entry gate — an owner decision (runner capacity, which branches).

- [ ] [xv-review] B-20261001-XV-RETRO-PY-TYPEHINTS [P4][style][conf 40] [NIT]
**Fingerprint:** skills/retro/SKILL.md|CQ2|embedded-python-without-type-hints
**Source:** Plan C aggregate review, CQ auditor CQ-13 (pre-existing style; the Plan C `route_key` follows it).
**What:** the python embedded in skills/retro/SKILL.md (`enum_str`, `gate_status`, `route_key`, `strategy_bucket`) has no type hints.
**Fix:** add hints in one pass when the block is next edited; no behaviour change.

## Test quality after the install.sh refactor — below-A test files (zuvo:refactor 1f022802, test-quality gate WARN, recorded 2026-10-05)

Report: zuvo/audits/test-quality-audit-2026-10-05-install-refactor.md (35 files; first pass A1 B3 C30 INCOMPLETE1). The gate ran its two fix→re-audit
iterations on the files covering CHANGED behavior; test-installer-sources.sh reached A and test-install-cross-providers.sh B. The rest stay below A.

- [ ] [test-audit] B-20261005-TQ-INSTALL-CHANGED-REMAINDER [P3][test-quality][conf 80]
**Fingerprint:** tests/hooks/test-install-*|Q7,Q11,Q19,Q20|below-A-after-two-iterations
**Source:** zuvo:refactor 1f022802 Phase 3.6 Step 1 (test-quality gate), re-audit 2 by codex/gpt-6-sol.
**What:** files covering behavior the refactor and its fixes changed, still below A after the cap (tier, failing Q-gates of the final audit):
  - `tests/hooks/test-install-entry.sh` — C (-), fails Q3,Q7,Q11
  - `tests/hooks/test-install-claude-home.sh` — C (-), fails Q2,Q3,Q7,Q11
  - `tests/hooks/test-install-claude-home-flow.sh` — C (-), fails Q2,Q6,Q7,Q11,Q19,Q20
  - `tests/lib/install-manifest.sh` — C (-), fails Q4,Q10,Q11,Q15,Q20
  - `tests/hooks/test-install-host-ownership.sh` — C (-), fails Q3,Q7,Q11
  - `tests/hooks/test-install-cross-providers.sh` — B (-), fails Q3,Q4,Q20,Q23
  - `tests/hooks/test-install-copy-verification.sh` — B (-), fails Q4,Q9,Q10,Q18,Q19,Q20
  - `tests/hooks/test-install-downgrade-guard.sh` — B (-), fails Q2,Q6,Q9,Q19
  - `tests/hooks/test-farm-guard-vendored.sh` — C (-), fails Q3,Q4,Q7,Q11,Q18,Q20,Q22
  - `tests/hooks/test-install-wiring.sh` — B (-), fails Q6,Q9,Q10,Q19
  - `tests/mutation/test_install_copy_verification_mutation.py` — C (-), fails Q7,Q8,Q11,Q12,Q18,Q20
**Fix:** the critical branches the final re-audit named in changed code were closed after it (entry 12c, host-ownership 1j/1k, claude-home 20) — re-audit those files first. What remains is mostly structure: order-independent fixtures (Q19), declared test level (Q20), exact rather than lower-bound counts (Q4/AP27), the flow file's shared HOME/SETTINGS, cursor.sh:206 (script-copy verification at the cursor call site), and install-manifest.sh as a tool (its verdict is the fence diff, not its in-file counts).

- [ ] [test-audit] B-20261005-TQ-INSTALL-PREEXISTING [P3][test-quality][conf 75]
**Fingerprint:** tests/*|Q7,Q11|preexisting-suites-in-install-refactor-scope
**Source:** same audit; these files cover code the refactor did NOT change (moved verbatim, only re-pointed at the module text, or out of the fence), so the gate reports them instead of rewriting them.
**What:** first-pass tier and failing Q-gates:
  - `tests/hooks/test-plugin-enable-guard.sh` — C (10/18), fails Q2,Q6,Q7,Q10,Q11,Q16,Q19,Q20
  - `tests/hooks/test-global-dispatch.sh` — C (11/19), fails Q3,Q4,Q7,Q11,Q18,Q20
  - `tests/skill-suite/test-adversarial-stable-path.sh` — C (6/17), fails Q4,Q7,Q8,Q10,Q11,Q12,Q13,Q14,Q16,Q17,Q20
  - `tests/adversarial/test-install-retro-stub.sh` — C (11/17), fails Q7,Q8,Q11,Q12,Q16,Q20
  - `tests/adversarial/test-install-verify-plan-dag.sh` — C (11/17), fails Q7,Q8,Q11,Q12,Q16,Q20
  - `tests/adversarial/test-stall-watchdog.sh` — C (12/17), fails Q7,Q11,Q18,Q20
  - `tests/hooks/bootstrap-activation-cases.py` — C (11/19), fails Q1,Q3,Q6,Q7,Q11,Q20
  - `tests/hooks/test-codex-poll-guard.sh` — C (16/20), fails Q7,Q11,Q20,Q23
  - `tests/hooks/test-agents-md-blocks.sh` — C (14/19), fails Q4,Q7,Q11,Q12,Q20
  - `tests/hooks/test-kimi-build.sh` — C (13/20), fails Q4,Q7,Q10,Q11,Q20,Q23
  - `tests/hooks/test-antigravity-skill-ownership.sh` — C (14/20), fails Q4,Q7,Q11,Q20,Q23
  - `tests/hooks/test-retro-loop-docs.sh` — C (16/20), fails Q4,Q7,Q12,Q20
  - `tests/hooks/test-hooks-wiring.sh` — C (14/18), fails Q4,Q7,Q8,Q20
  - `tests/hooks/test-backlog-headings.sh` — C (13/17), fails Q4,Q7,Q11,Q20
  - `tests/hooks/test-dist-build-cache.sh` — C (13/19), fails Q3,Q4,Q7,Q11,Q19,Q20
  - `tests/infra-suite/test-infra-wiring.sh` — C (6/17), fails Q4,Q7,Q8,Q11,Q12,Q13,Q14,Q15,Q16,Q17,Q20
  - `scripts/tests/reviewer-model-builds.bats` — C (14/21), fails Q3,Q4,Q7,Q11,Q18,Q22
  - `tests/gates/test_radar_contract.py` — C (15/21), fails Q2,Q3,Q7,Q9,Q11,Q23
  - `tests/gates/test_refactor_radar.py` — C (17/20), fails Q7,Q11,Q23
  - `tests/hooks/test-build-review-patch.sh` — C (13/18), fails Q9,Q11,Q19,Q20
  - `tests/hooks/workflow-economy-cases.py` — C (10/17), fails Q2,Q7,Q8,Q11,Q20
**Fix:** per file, the report's "Top gaps" column — mostly missing negative and branch cases of their production files (Q7/Q11), shared fixtures (Q19) and undeclared levels (Q20). The radar suites, build-review-patch and load-includes (no dedicated suite exists, though load-includes:47-51 names one) are the largest gaps.

## B-20261002-NORMALISE-STRIPS-GLOBALLY `strip_resolution_markers` deletes dates, shas and `*` ANYWHERE, so two entries differing only in a deadline are one entry

`zuvo_backlog_parse.py:285-301` applies `DATE_RE`, `_SHA_RE` (`\b[0-9a-f]{7,40}\b`, case-insensitive)
and `text.replace("*", " ")` to the WHOLE body, not to the closure clause. Measured here with the
shipped functions — both `text_sha` AND `entry_key` collapse each pair:

| a | b | text_sha | entry_key |
|---|---|---|---|
| `… src/a.ts by 2026-01-01` | `… src/a.ts by 2031-12-31` | SAME | SAME |
| `revert commit src/a.ts deadbeef now` | `… cafebabe now` | SAME | SAME |
| `the **critical** race in src/a.ts` | `the critical race in src/a.ts` | SAME | SAME |
| `the defaced banner in src/a.ts` | `the banner in src/a.ts` | SAME | SAME |

`normalize_signature:312` calls it, and `entry_key` calls `normalize_signature`, so this is the
IDENTITY function: a verdict is reused free when the deadline, the target commit or the emphasis
changed, and two entries that differ only in a date collide as duplicates. Ordinary words made of
`[a-f0-9]` (`defaced`, `effaced`, `facade`) are stripped from the hashed text as well.

WHY IT IS NOT FIXED IN THE GROOMING BRANCH, and this is a fix-SCOPE reason rather than a size one:
changing the normalisation rotates every `fp:` key in every repo and every archive at once. Each
`memory/backlog-verdicts.jsonl` row is keyed on today's output, so the first run after such a change
reports every entry unverified and every archived twin unmatched — a data migration, not a code edit.
The fix therefore owes a migration: anchor the stripping to the closure tail (`resolution_marker_pos`
already computes the position) AND a one-off re-key pass over existing ledgers, with the old key kept
as an alias for one release so `keys_for` bridges it exactly as it already bridges the pre-mint key.

- [ ] B-20261002-NORMALISE-STRIPS-GLOBALLY anchor marker-stripping to the closure tail, add the
      re-key migration and keep the old key as a `keys_for` alias for one release; the RED is the
      four pairs above, which must stop sharing a key

confidence:97 source:pr2-behaviour-audit + own measurement 2026-10-02

## B-20261002-SEED-NOT-IN-FILE control (d)'s seeds are indistinguishable in the DISPATCH but not against the repository

`zuvo_backlog_seedshape.py` now holds the dispatch-level property, and the suite enumerates it (W6b,
smoke A3b: no field value, shared affix or derived property partitions a chunk into its seed rows, over
all 10 chunks of this repo). That is the strongest claim the current design can make, and it is not the
whole claim a reader might assume: **a verifier that greps `backlog.md` for each row's id finds every
real row and no seed**, because a seed is not in the file. No field fixes that — it is a property of
synthesising rows at all — so the limit is stated in that module's docstring and in
`shared/includes/backlog-grooming.md` rather than papered over.

Closing it needs a design decision, not a patch. The two candidates: (a) draw seeds from entries that
are genuinely present and withhold their recorded closure instead of synthesising text, which costs the
`STILL-REAL` half; (b) hand the lane a snapshot in which seed rows DO appear, which makes absence
undecidable but means writing a file the repo does not have.

- [ ] B-20261002-SEED-NOT-IN-FILE decide between seeds drawn from present entries and a snapshot the
      lane reads, then make (d) hold against the repository and not only against the dispatch

confidence:92 source:pr2-structure-audit + own measurement 2026-10-02

## B-20261002-ARCHIVE-CHECK-THEN-ACT the archive scope oracle and the archive run are two subprocesses, each taking the lock separately

`zuvo_backlog_closure.py` runs `archive --dry-run`, validates the count in `_scope_or_refuse`, then runs
`archive` — two invocations, each taking and releasing `zio.Lock` on its own, so nothing holds the
backlog between the approval and the action. In this repo's own stated environment (six `~/DEV`
checkouts through symlinks onto one canonical backlog, plus parallel agents) another writer can tick an
entry in that window, and the whole-file `archive` then closes an entry no verdict licensed — precisely
what `_scope_or_refuse` exists to prevent.

NOT reproduced as a race; filed as the hypothesis it is. The fix is blocked on the helper: the
archiver's own lock reclaim at 30 s makes holding `zio.Lock` around both calls re-entrancy-unsafe, so it
needs either an inherited-lock/`--skip-lock` path in `backlog-archive.py` or an expected-set digest the
archiver re-verifies under its own lock.

SECOND FINDING, SAME MECHANISM (adversarial, 2026-10-02): the scope check compares only the COUNT, so a
SWAP passes — an unlicensed ticked entry replacing a licensed one the archiver held back has the same
cardinality. Comparing identities was tried in the grooming branch and reverted on measurement: the dry
run names an id-less entry `- (no id) line 5:` while the caller knows it as `fp:00d183281395`, so the two
identity spaces do not join for exactly the entries that have no id, and `(no id)` is not unique among
several; line numbers do not join either, because `drop-stale` runs first and shifts them. Both halves
need the same thing — a stable key the archiver emits or accepts.

- [ ] B-20261002-ARCHIVE-CHECK-THEN-ACT give `backlog-archive.py` an expected-set digest (or an
      inherited lock) so the approved set and the archived set are the same set under one lock, AND so
      the scope oracle can compare identities instead of a cardinality

confidence:68 source:pr2-behaviour-audit (hypothesis, not executed as a race)

## B-20261002-MINT-INVALIDATES-TEXTSHA minting an id into an entry re-verifies it, because `text_sha` sees the id as new text

Measured with the shipped functions on a real parse (the first attempt used a hand-built body WITH the
`- [ ] ` prefix and got the wrong answer — `keys_for` looked broken when it is not):

```
pre  body 'the loader drops a newline in src/a.ts:12'
     keys ['fp:b41fb83b9a20']                         text_sha f53c9faedfc9cdac
post body 'B-A20261002-f53c9f the loader drops a newline in src/a.ts:12'
     keys ['fp:b41fb83b9a20', 'id:b-a20261002-f53c9f'] text_sha 34639a74b2b20cb4
SHARED KEY ['fp:b41fb83b9a20']   text_sha equal: False
```

`keys_for` DOES bridge the mint (`MINTED_ID_RE` recovers the pre-mint content key), so identity survives.
`text_sha` does not: `strip_resolution_markers` has no reason to remove a minted id, so the hash changes.
`plan_reuse` keys on `(key, text_sha)`, so a just-minted entry lands in **reverify** rather than **reuse**
— `plan` mints and then immediately marks what it minted for re-verification, which is the opposite of
what the reuse design is for. Conservative, not unsafe.

NOT fixed in the grooming branch: making `text_sha` strip `MINTED_ID_RE` changes every existing
`text_sha`, so the first run after it re-verifies the whole backlog once. It also does not bite THIS repo
at all — all 263 mint-set entries are the bullet dialect and `mintable` is 0 of them — so the cost of
getting it wrong is paid by checkbox-dialect repos that have no coverage here yet.

- [ ] B-20261002-MINT-INVALIDATES-TEXTSHA strip `MINTED_ID_RE` in `text_sha` (not in `entry_key` — see
      B-20261002-NORMALISE-STRIPS-GLOBALLY for why that one is a migration), with a fixture in the
      CHECKBOX dialect so the RED is a just-minted entry landing in `reuse` instead of `reverify`

confidence:95 source:adversarial-task-pr2 (#03) + own measurement 2026-10-02

## 2026-10-02 — PR 2 adversarial claims REJECTED BY MEASUREMENT (recorded so they are not re-filed)

- **"the polyglot header passes the literal `$ @`, so argv is lost"** — the header is `"$0" "$@"`.
  One provider transcribed it with a space and built a CRITICAL on the transcription. Every CLI
  invocation in two suites passes arguments correctly.
- **"`evidence_locations` absorbs the preceding prose into the path and misses every location after
  the first"** — measured: `at src/foo.py:12` -> `[('src/foo.py', 12)]`; `see src/a.ts:3 and
  src/b.ts:9` -> both.
- **"`keys_for` can return an empty list, so `keys[0]` raises"** — measured over `''`, `'   '`,
  `'- [ ]'`, `'x'`: always at least one key.
- **"a queue row with no `chunk` is silently excluded from dispatch and never verified"** — `chunk:
  None` is the DESIGNED state for a row the deterministic pre-pass already decided; `queue_row`
  writes a row per entry so the queue's length IS `entry_count`, and `assign_chunks` numbers only
  what still needs a verifier. A guard refusing it was written and the dogfood lane rejected it in
  one run (2 legitimate rows). Reverted; the comment at that line now records why.
- **the archive scope oracle comparing identities instead of a count** — the finding is real but the
  fix is not available here; folded into B-20261002-ARCHIVE-CHECK-THEN-ACT with the measurement.

## 2026-10-04 backlog collector — accepted adversarial findings (merge of origin/main, PR #16)

- [ ] B-20261004-PULL-STREAM-SSH: `collector_ssh(binary=True)` runs `subprocess.run(capture_output=True)`,
  so the WHOLE gzipped namespace is in memory before `_decompress_bounded` can apply `PULL_MAX_BYTES`
  — the cap bounds the decompressed payload, not the capture. Why it is deferred rather than fixed:
  at the measured 35.2 MB namespace the blob is ~7 MB, and any honest growth large enough to matter
  decompresses past 512 MB and is refused BY NAME long before memory is the limit; reaching an OOM
  needs gigabytes compressed, i.e. tens of GB of incompressible data in the collector's data dir,
  which requires control of the collector host. Fix: `Popen`, read stdout in bounded chunks, feed
  each chunk to an incremental decompressor (`_decompress_bounded` already is one — it would take an
  iterable instead of a blob), kill ssh past either cap. Do it with a test per case, including a
  multi-member gzip whose member boundary falls inside a chunk: this is the one path where a subtle
  bug publishes a SHORT index rather than an error. Same change removes
  B-20261004-DECODE-TWICE. Source: adversarial PR#16 CRITICAL/medium (openrouter-4), accepted with
  the measurement above.
- [ ] B-20261004-DECODE-TWICE: `_decode_payload`'s bad-UTF-8 branch decompresses the payload a SECOND
  time to count the offending records, and `raw.split(b"\n")` materialises every line. It runs only
  on the refusal path and buys the operator a count plus a `grep` they can run on the collector, so
  it stays; but on a constrained host the diagnostic itself can be OOM-killed, turning a named
  refusal into an anonymous `Killed` — the exact outcome the function exists to prevent. Fix with
  B-20261004-PULL-STREAM-SSH, or report the `UnicodeDecodeError.start` offset from the first pass
  instead of rescanning. Source: adversarial PR#16 INFO/medium (kimi).

confidence:90 source:adversarial-merge-main-host-id (5 providers, 30 severity records) — proof
zuvo/proofs/merge-main-host-id-f3b86e6c.txt, artifact
memory/reviews/7079545..f4035cb-merge-main-host-id.md

## 2026-10-05 session sweep — what the local-main merge / red-suite / align session left behind

Everything this session saw and did not fix: rejected-as-out-of-scope, deferred for budget, or not
noticed until the sweep. Each entry says which. Session pushes: 85b19024, d979fca9, 7f2b7fa8.

- [ ] B-20261005-PARTIAL-RUN-WINS [P2][correctness][conf 70]
  **Fingerprint:** scripts/zuvo-home/backlog|pull|newest-run-not-complete
  **What:** `pull()` keeps the run with the newest `received_at` per host
  (scripts/zuvo-home/backlog:313) and never checks that ALL its batches arrived. A push that fails on
  batch k/N (scripts/zuvo-home/backlog-collect.py:240) or is killed by sync's 300 s timeout
  (scripts/zuvo-home/backlog:354) leaves batches 1..k-1 under a NEW run_id with newer timestamps, so
  the next pull serves that host's backlog TRUNCATED and reports success. Every payload already
  carries `batch`/`batches`.
  **Why deferred:** seen while triaging adversarial pass 3 (cursor-agent: a timeout leaves the
  landing ambiguous); only the message was fixed. Not verified whether the collector server drops
  incomplete runs — check that first (conf 70 for that reason).
  **Fix:** per (host, run) count distinct `batch` values and treat the run as complete only when the
  count equals `batches`; pick the newest COMPLETE run per host and name hosts whose newest run is
  incomplete. RED test: two runs for one host, the newer one missing a batch.

- [ ] B-20261005-FULL-SUITE-AFTER-MERGES [P2][verification][conf 95]
  **What:** d979fca9 and 7f2b7fa8 went to origin/main checked only by the targeted suites
  (backlog-collector-ssh, runlog-collect, backlog-headings, archive-dedup, python-lint, shellcheck).
  The full suite (tests/run-all) did not run after either merge, although this session's own retro
  (2026-10-02) recorded that targeted verification missed two regressions only the full suite found.
  **Why deferred:** time; the merged files were disjoint from the suites skipped.
  **Fix:** the full suite through `rt` on current main; triage any red with docs/runbook/testing.md §5.

- [ ] B-20261005-REVIEW-DEGRADED-NO-CODESIFT [P3][verification][conf 90]
  **What:** the review of the local-main merge (memory/reviews/2026-10-03-merge-local-main.md) ran
  with CodeSift disconnected: review_diff, changed_symbols, impact_analysis, scan_secrets and
  search_patterns were replaced by a manual diff read + ruff + shellcheck. The report says so, but
  those mandatory checks never ran on 85b19024..7f2b7fa8 for scripts/zuvo-home/backlog and
  backlog-collect.py.
  **Fix:** with CodeSift up, `review_diff` + `scan_secrets` + `search_patterns` over
  85b19024..7f2b7fa8 for those two files; file anything new.

- [ ] B-20261005-EFE4C5B5-UNREVIEWED [P3][verification][conf 80]
  **What:** efe4c5b5 (stable collector host tag) went out in 7f2b7fa8 below the gate threshold
  (2 files, ~50 lines) with only a diff read: no zuvo:review, no adversarial pass, and at the time no
  test of the ZUVO_HOST_TAG -> ~/.zuvo/host-id -> gethostname() precedence in either collector.
  Later host-id commits from another session (889fc39e, ea9f5206, f4035cbf) reworked this code.
  **Fix:** confirm memory/reviews/7079545..f4035cb-merge-main-host-id.md covers the original
  behaviour; if the precedence is untested, add the test.

- [ ] B-20261005-PUSH-ONLY-STALENESS [P3][observability][conf 75]
  **What:** on a push-only host `sync` exits 0 with "index: not refreshed on this host"
  (scripts/zuvo-home/backlog:376) on every run, forever. Cron output is discarded, so if the data
  dir's permissions regress the local index goes stale silently — a softer replay of the 3-week
  "0 items" incident. Raised by kimi (pass 3, INFO), not acted on.
  **Fix:** print the local index age beside the message, and warn loudly (or fail) past a threshold,
  e.g. no refresh for 7 days.

- [ ] B-20261005-PULL-GLOB-ARGMAX [P4][scalability][conf 60]
  **What:** the remote pull expands every `*.jsonl` into one argv for gzip
  (scripts/zuvo-home/backlog:285). Past ARG_MAX it fails with E2BIG — by name, never as a short
  index. Rejected twice this session as "pre-existing, the fleet is a handful of files".
  **Fix:** not `find | xargs cat | gzip` (it loses the read status — see the comment at that line);
  gzip per file appended to one stream, with a status check per file.

- [ ] B-20261005-COLLECTOR-ENV-SOURCED [P4][security-hardening][conf 50]
  **What:** the token fetch sources `collector.env` on the collector (scripts/zuvo-home/backlog:341),
  so any shell in that file runs as the ssh user; DATA and COLLECTOR_ENV are also interpolated into
  the remote command unquoted. Rejected this session as "by design, operator-owned constants" — an
  injection needs write access to the collector, so this is hardening, not a hole.
  **Fix:** read the value with `sed -n 's/^CODESIFT_COLLECTOR_TOKEN=//p'` (then the ZUVO_ name)
  instead of sourcing; `shlex.quote` both paths.

- [ ] B-20261005-CHMOD-TESTS-SKIP-AS-ROOT [P4][test-coverage][conf 70]
  **What:** the three unreadable-dir cases in tests/hooks/test-backlog-collector-ssh.sh
  (:100, :125, :141) SKIP when chmod 000 is not honoured (root, some filesystems); the push-only
  branch and the ancestor walk then go untested while the suite still says ALL PASS.
  **Fix:** count SKIPs into the result line, or drive the unreadable branch through the fake ssh
  stub (return UNREADABLE_RC directly) so it never depends on the account.

- [ ] B-20261005-GATE-PATCH-ID-TWINS [P3][gate][conf 80]
  **What:** at push the pipeline-entry gate counted 26bef0d5/0eba8782 as unreviewed although their
  content was byte-identical to origin's already-reviewed 99035e07/a7224dc0. It cleared only after
  copying another session's artifact (85b1902..a7224dc-stryker-diff-scope.md) into the pushing
  worktree.
  **Fix:** in hooks/lib/pipeline-gate-lib.sh treat a commit whose `git patch-id --stable` matches a
  commit already on the remote as covered; test with a cherry-picked twin.

- [ ] B-20261005-TRACKED-TEST-TMP [P3][hygiene][conf 90]
  **What:** 164 files under tests/adversarial/.tmp/ are tracked in git and rewritten by every test
  run, so the main checkout is permanently dirty and every session must step around them by hand.
  **Fix:** `git rm -r --cached tests/adversarial/.tmp` + a .gitignore entry, after confirming no test
  reads a committed fixture from there (move any that do to tests/fixtures/).

- [ ] B-20261005-APPEND-RETRO-ENUMS [P4][telemetry][conf 70]
  **What:** ~/.zuvo/append-retro rejected `--code-type=INFRA_SCRIPT` and `--adversarial=4passes`, so
  the retro for review@d979fca was filed as ORCHESTRATOR / "9findings" — an approximation: four
  passes produced about 30 severity records, ~12 fixed, the rest rejected. Retro mining reads the
  wrong shape for shell/infra reviews.
  **Fix:** a SCRIPT/INFRA code type and a multi-pass adversarial form (`Npasses:Mfindings`) in
  scripts/zuvo-home/append-retro and the append-runlog gate together.

confidence:85 source:session-sweep-2026-10-05 (collected from the merge-main review report, the four adversarial passes' rejected lists, and the session retros)

## 2026-10-05 adversarial lanes — left open by the OpenRouter / lane-rename / empty-response session

Source: interactive session 2026-10-04/05 (two read-only investigation agents over `~/.zuvo/adversarial.log`
on the Mac and the synced ryzen-dev copy, plus live canaries). Entries planned in
`docs/specs/2026-10-04-adversarial-lane-rename-plan.md` name their task; that plan is approved but NOT
executed yet, so these stay open until its tasks land.

### Planned in the lane-rename plan (execute not started)

- [ ] B-20261005-LANE-RENAME-PLAN-EXECUTE: `docs/specs/2026-10-04-adversarial-lane-rename-plan.md`
  (rev 5, 9 tasks) was approved by the user on 2026-10-05, but its header still says `status: Reviewed`,
  `zuvo/plans/active-plan.md` was not written and `zuvo:execute` never started — the session was
  interrupted while the user asked whether execute touches `scripts/adversarial-review.sh` (it does, in
  Tasks 1/3/4/5/7). Open question for the owner: run it in a separate worktree (recommended — other
  agents edit that file in the shared checkout) or in main. Fix: set `status: Approved`, write the
  active-plan pointer, run `zuvo:execute`. | severity: high | category: Architecture | conf: 100
- [ ] B-20261005-LANE-NAMES-CONFUSING: lane ids name stale model versions — `codex-5.3` runs `gpt-6-sol`,
  `codex-5.4` runs `gpt-6-luna`; `openrouter-alt`/`byteplus-alt` hide the slot number. User-approved
  scheme: vendor, numbered only when the vendor has >1 lane (`codex-1/-2`, `cursor`, `byteplus-1..3`,
  `openrouter-1..4`), old names kept as input aliases. ~46 sites in `scripts/adversarial-review.sh`,
  ~250 repo-wide. Plan Tasks 2, 3, 5, 6, 8. | severity: medium | category: Code | conf: 100
- [ ] B-20261005-CURSOR-MODEL-MISLABEL: `scripts/adversarial-review.sh` `run_cursor_agent` (:2853) runs
  `${ZUVO_CURSOR_MODEL:-composer-2.5-fast}` while `provider_model` (:2405) logs
  `${ZUVO_CURSOR_MODEL:-${ZUVO_MODEL_CURSOR:-auto}}` and the registry says `auto` — 13,885 calls are
  logged as `auto` but ran composer-2.5-fast; the 09-09 switch to `auto` never took effect. Plan Task 7
  (runner reads `provider_model`, registry `composer-2.5-fast`) + Task 6 (stats relabels history).
  | severity: medium | category: Code | conf: 95
- [ ] B-20261005-REFUSALS-LOGGED-EMPTY: `scripts/adversarial-review.sh` `record_provider_failure_outcome`
  (:4446) falls through to `empty` for vendor refusals: cursor "You're out of usage. Switch to Auto" /
  "Cannot use this model" (exit 1, ~7 s), muse HTTP 429 "Subscription quota exhausted… resets at <ISO>",
  agy "Authentication required"/"Please sign in", kimi "re-login required"/"no refresh_token", and agy
  cooldown-only skips (0 s). Effects: dashboard "empty" counts inflated, only the soft 45-min cooldown,
  muse retried while its quota is gone. All 445 composer "empties" of 09-06..08 were this. Plan Task 4.
  | severity: medium | category: Code | conf: 95
- [ ] B-20261005-ALL-FAIL-NO-LANE-ROWS: when every provider fails, `scripts/adversarial-review.sh` (:4772)
  logs one `none / all-failed` row and no per-lane rows, and `adversarial-stats` skips `none` — so a host
  where every lane fails (e.g. ryzen-dev agy+kimi unauthenticated) is invisible in stats. Plan Task 4
  (`log_lane_rows` on the all-fail path, skipped on `suspended`). | severity: medium | category: Code | conf: 90
- [ ] B-20261005-AGY-FALLBACK-OPUS46-RETIRED: agy quota-fallback default `Claude Opus 4.6 (Thinking)`
  (`scripts/adversarial-review.sh` :3005, `shared/includes/model-registry.sh` :196, usage :582–585) is no
  longer offered by `agy models` (only Opus/Sonnet 5.5). Default must be "no fallback"; the test
  `tests/adversarial/test-agy-quota-fallback.sh` masks the driver default via `${FB-…}`. Plan Task 7.
  | severity: medium | category: Code | conf: 95
- [ ] B-20261005-BENCHMARK-GPT54-DEFAULT: `scripts/benchmark.sh:225` falls back to retired `gpt-5.4` for
  `ZUVO_MODEL_CODEX_ALT` when the registry does not load (single candidate path :40–41). Plan Task 7
  (use `gpt-6-luna` = registry, plus an equality test). | severity: low | category: Code | conf: 95
- [ ] B-20261005-TESTS-WRITE-REAL-ADV-LOG: tests write mock-lane rows (`mock-success`, `mock-gemini`,
  `mock-fail`, …) into the REAL `~/.zuvo/adversarial.log` — ~9.7k rows on the Mac.
  `tests/adversarial/run.sh` exports only `ADV_TEST_HOME`; non-isolated: test-smoke-all, test-d1..d4,
  test-backward-compat, test-provider-fanout-cap, test-artifact-provenance,
  test-provider-bench-cooldown (+ partial test-codex-lane-defaults, test-observability-log);
  `tests/hooks/test-noverify-content-binding.sh`, `test-adversarial-truncation.sh`;
  `tests/skill-suite/test-adversarial-flag-contract.sh`. Plan Task 1 (harness routing + row guard
  mirroring `findings_log_rows` :4853). | severity: medium | category: Test | conf: 95

### Not in any plan

- [ ] B-20261005-ADV-LOG-HISTORIC-MOCK-ROWS: even after the isolation fix the ~9.7k mock rows already in
  the Mac `~/.zuvo/adversarial.log` stay. `adversarial-stats` drops runs that used a `mock-*` lane, but
  every other reader (`--effectiveness`, ad-hoc mining, the hub collector) must re-implement that
  filter. Decide: one-time purge (log is append-only by design — needs a deliberate exception) or a
  shared reader-side filter. | severity: low | category: Infrastructure | conf: 80
- [ ] B-20261005-HUB-COLLECTOR-LANE-ALIASES: the hub page `zuvo-plugin/adversarial-stats`
  (`~/DEV/tgm-mockup/projects/zuvo-plugin/adversarial-stats/collect.py`, separate repo) — USER REQUEST
  NOT DONE: (a) drop the dead rows `codex-5.4 / gpt-5.4` (222 calls, 0% — model retired, last call
  09-08) and `agy / Claude Opus 4.6 (Thinking)` (2,134 calls, 2.2%); (b) map old lane names to new once
  the rename lands (same table as `LANE_ALIASES`), or history splits; (c) show a last-7-days failure
  rate next to all-time — all-time overstates problems already fixed (Flash High, byteplus-alt, kimi k3,
  openrouter qwen/glm-5.3, gpt-5.4). Plan Rollout step 2. | severity: medium | category: Infrastructure | conf: 95
- [ ] B-20261005-AGY-RYZEN-NOT-SIGNED-IN: agy on ryzen-dev is not signed in — "Authentication required",
  `agy models` → "Please sign in"; 1,915/1,915 agy calls there in the last week failed after ~120 s each
  (~60 s login wait per model), logged under the retired fallback name. OWNER ACTION: log agy in on
  ryzen-dev (an agent must not run logins). | severity: high | category: Infrastructure | conf: 95
- [ ] B-20261005-KIMI-RYZEN-RELOGIN: kimi on ryzen-dev fails 34% — canary 2026-10-04: "Token … has no
  refresh_token; re-login required". OWNER ACTION: kimi login on ryzen-dev. | severity: high |
  category: Infrastructure | conf: 95
- [ ] B-20261005-MUSE-QUOTA-RECHECK: muse failed 100% on both hosts since 2026-10-01 — HTTP 429
  "Subscription quota exhausted… resets at 2026-10-05T00:00:00Z". Verify it answers again after the
  reset; if the quota burns out weekly, lower muse's share of reviews. | severity: low |
  category: Infrastructure | conf: 90
- [ ] B-20261005-AGY-CONCURRENCY-TIMEOUTS: agy Gemini 3.8 Flash (Medium) timeouts at the 500 s budget
  depend on parallel agy calls on the same host — 3% with no other agy call running, 16% with 8+;
  input size is not a factor (40–60k inputs 2–6%). Cap concurrent agy calls per host
  (`scripts/adversarial-review.sh`, fan-out/pin logic). | severity: medium | category: Code | conf: 75
- [ ] B-20261005-GLM53FLASH-TIMEOUT-BY-SIZE: lane `byteplus` (glm-5.3-flash) 15–18% timeouts: even
  successes take 266 s median / 417 s p90; timeouts 7% under 10k chars, 24% at 25–30k, 33% over 60k.
  A bigger budget does not fit the run deadline — smaller chunks or lower reasoning for this lane.
  | severity: medium | category: Code | conf: 80
- [ ] B-20261005-FAILURE-EVIDENCE-ONLY-ALL-FAIL: `preserve_failure_evidence`
  (`scripts/adversarial-review.sh` :4274) keeps a lane's stderr only when the WHOLE run produced zero
  reviews, for 7 days. A lane failing inside an otherwise successful run leaves no stderr, so the
  2026-10-04 diagnoses of the Flash (High) 300 s cluster and the cursor refusals before 09-27 were
  inferred, not read. Keep per-lane stderr for failed lanes in every run (bounded size). |
  severity: medium | category: Code | conf: 85
- [ ] B-20261005-REFUSAL-TEXT-DRIFT: the planned classifier (plan Task 4) matches fixed vendor strings;
  when cursor/muse/agy/kimi reword a refusal, it silently falls back to `empty` again. Add drift
  detection (e.g. stats flags a lane whose `empty` rate jumps while its exit-1/short-duration pattern
  persists) or a periodic canary. | severity: low | category: Code | conf: 60
- [ ] B-20261005-MERCURY-PREVIEW-DELISTED: lane `openrouter-3` defaults to
  `inception/mercury-2.5-preview`, which is no longer in the OpenRouter model catalog (2026-10-04); it
  still answered that day (alias), but can stop without notice. GA `inception/mercury-2.5` (added
  09-09, $0.04/$0.15) was never benchmarked. Bench it with `~/.zuvo/bench/bench-model.sh or
  inception/mercury-2.5`, then switch `ZUVO_MODEL_OPENROUTER_3` in `shared/includes/model-registry.sh`.
  Do NOT disable the lane (cheap-coverage rule). | severity: medium | category: Dependency | conf: 90
- [ ] B-20261005-OPENROUTER-NEW-MODELS-UNBENCHED: OpenRouter models added since the last OpenRouter
  bench (2026-09-09) and never benchmarked for adversarial coverage — cheap: xiaomi/mimo-v2.6-flash,
  mimo-v2.6-pro, nex-agi/nex-n2.5-pro + -mini, upstage/solar-mini4, z-ai/glm-5.3-flashx,
  inclusionai/ling-3.1-flash, cohere/command-a-plus; costlier: x-ai/grok-4.7,
  qwen/qwen3.8-max-prime, z-ai/glm-5.3-prime, aion-labs/aion-3.5, sakana/fugu-max, fireworks/ember-1.
  Skip stealth/free models (provider may log the diffs) without owner consent. The owner was asked
  whether to run the first batch and has not answered. Run sequentially on a frozen driver copy; the
  Opus judge uses the Claude subscription. | severity: low | category: Dependency | conf: 90
- [ ] B-20261005-DEEPSEEK-V41-NO-ACTIVE-LANE: deepseek-v4.1-flash was benchmarked via the Alibaba
  Token Plan on 2026-09-24 (`~/.zuvo/bench/subs/tp-deepseek-v4.1-flash`, 20/20), but no active lane runs
  it: the `qwen` Token Plan lane runs qwen3.8-flash, and `openrouter-alt` (off by default) points at the
  same model through PAID OpenRouter. Decide from the bench's marginal coverage whether to add a Token
  Plan deepseek lane. | severity: low | category: Infrastructure | conf: 80
- [ ] B-20261005-CODEX-AGENT-REGISTRY-GPT54: `shared/includes/codex-agent-registry.md:15-16` still
  documents `haiku->gpt-5.4-mini, sonnet->gpt-5.4, opus->gpt-5.5` — gpt-5.4 and gpt-5.4-mini are
  retired (HTTP 400 on the ChatGPT account per `model-registry.sh` :46). Check whether anything still
  reads this mapping; update it to the registry tiers. | severity: medium | category: Documentation | conf: 70
- [ ] B-20261005-ADV-TMP-TRACKED-DIRTY: `tests/adversarial/.tmp/*` (cap*.err, health-*.tsv, prov/*.md,
  zuvo-home/adversarial.log, …) is tracked in git and rewritten by every adversarial test run — 43 files
  were dirty at session start, and a broad `git add` would commit test output. Untrack and gitignore
  `.tmp/`. | severity: low | category: Test | conf: 90
- [ ] B-20261005-PLAYWRIGHT-MCP-UNTRACKED: `.playwright-mcp/` (Playwright MCP session output) sits
  untracked at the repo root; add it to `.gitignore`. | severity: low | category: Infrastructure | conf: 90
- [ ] B-20261005-WATCHDOG-RESUME-ON-USER-WAIT: the stall watchdog (`shared/includes/stall-recovery.md`,
  used by `zuvo:plan`) answers RESUME whenever the heartbeat is older than 150 s — during a long
  foreground sub-agent run (the plan's Opus agents take 4–6 min) and while the plan waits for the
  user's approval. This session had to `touch` the heartbeat by hand on every tick and set
  `status: halted` to stop a RESUME re-prompting the user. Needs a distinct "waiting on user/agent"
  state that the check treats as ALIVE. | severity: medium | category: Code | conf: 90
- [ ] B-20261005-STALL-RECOVERY-HEARTBEAT-PATH: `shared/includes/stall-recovery.md` ARM snippet writes
  the heartbeat to `<root>/.zuvo/context/<skill>.heartbeat`, while its own prose, the plan skill and
  `report-output-location.md` use the visible `zuvo/context/`. A skill following the snippet and a
  check following the prose look at different files. | severity: medium | category: Documentation | conf: 85
- [ ] B-20261005-FARM-HOOK-HEREDOC-FP: `~/.claude/hooks/farm-no-local-tests.sh` (outside this repo —
  source repo to confirm, likely i9-farma) blocked a `python3 - <<EOF` heredoc that only carried test
  commands as STRING DATA (plan text being edited) as "shell substitution <test command>". Worked
  around by writing the script to a file. The detector should not scan heredoc bodies fed to an
  interpreter. | severity: low | category: Infrastructure | conf: 85
- [ ] B-20261005-CODESIFT-HOOK-NON-REPO-GREP: the CodeSift PreToolUse hook blocks `grep`/`rg` whenever
  the CWD repo is indexed, even when the paths searched are outside it (`~/.zuvo/bench`,
  `~/.zuvo/adversarial.log`), where CodeSift cannot help. Worked around with python. The hook should
  look at the target paths, not only the CWD. Outside this repo (CodeSift hook). | severity: low |
  category: Infrastructure | conf: 85

## 2026-10-05 adversarial findings ledger + fleet review statistics — skipped, deferred and out-of-scope items (session 549960ea)

Recorded at the user's request: everything this session left unfixed — on purpose, by accident, for
time, or because it was outside the work. Evidence: ~/.zuvo/adversarial.log and adversarial-failures/
on the Mac, ryzen-dev, ryzen-tf (gha) and waw-tf (gha); hub page zuvo-plugin/ai-usage.

- [ ] B-20261005-VERDICT-COVERAGE [P1][adversarial-loop] — precision on the findings ledger rests on ~1%
  of findings: since 2026-10-03 on ryzen-dev 411 reviews raised 6,214 unique findings and agents
  recorded verdicts for 175. Step 4.9 (`shared/includes/adversarial-loop.md`, `adversarial-loop-docs.md`)
  says "every finding" but agents record only what they acted on. Fix: make the verdict call part of the
  same step that prints the fix policy (one batch with `deferred` as the default for every untouched id),
  and have `append-runlog`/the retro gate check that a run's `--json` ids got verdicts.
  source:session-549960ea | confidence:90 | 2026-10-05
- [ ] B-20261005-FINGERPRINT-PER-MODEL [P2][scripts/adversarial-review.sh JSON prompt] — the finding id is
  `<file>:<line>:<the model's own keywords>`, so the same bug from five lanes is five unrelated ids
  (6,214 unique of 6,228 rows): a verdict credits one lane, cross-lane agreement is invisible. Fix: a
  canonical key (normalized file + line bucket + defect class from a closed list), or cluster ids by
  file:line in `--effectiveness`. confidence:85 | 2026-10-05
- [ ] B-20261005-CI-NO-VERDICTS [P2][other repo: rdesigner scripts/ci/ai-review-verdict.mjs] — CI reviews
  (rdesigner ai-review on ryzen-tf/waw-tf, ~11k findings/week) never record a verdict; precision must
  exclude them or the verdict step must record what it blocked/passed. The hub page now lets the host
  filter separate them. confidence:85 | 2026-10-05
- [ ] B-20261005-RECORD-CROSS-HOST [P3][scripts/adversarial-review.sh --record-disposition] — the
  "unknown id" check reads only the LOCAL ledger, so a finding raised on ryzen-dev cannot be
  dispositioned from the Mac (exit 1). Needs an explicit `--allow-unmatched` or a synced ledger.
  confidence:80 | 2026-10-05
- [ ] B-20261005-LEDGER-BASENAME-ROWS [P3][~/.zuvo/adversarial-findings.log on the Mac] — 59 rows
  (41 tgm-survey-platform, 18 zuvo-plugin) written 2026-09-30 ~15:00Z by an intermediate build that keyed
  the project by basename; no verdict can ever join them. Delete or rekey to the absolute path.
  confidence:95 | 2026-10-05
- [ ] B-20261005-EFFECTIVENESS-NO-WINDOW [P3][scripts/adversarial-review.sh --effectiveness] — no date
  filter (`--since`); the report is always all-time. confidence:90 | 2026-10-05
- [ ] B-20261005-ALL-FAIL-LOGS-NONE [P1][scripts/adversarial-review.sh all-fail path] — a run in which no
  lane answered logs ONE `none` row; which lanes failed and why is only in adversarial-failures/. Planned
  as Task 4 of docs/specs/2026-10-04-adversarial-lane-rename-plan.md (not executed: it collides with the
  in-flight refactor/adversarial-review-split on ryzen-dev — sequence the two). confidence:95 | 2026-10-05
- [ ] B-20261005-TESTS-WRITE-REAL-LOGS [P1][tests/adversarial, tests/hooks] — test suites write to the
  real ~/.zuvo: ~9,300 test runs in 35 days across the Mac, ryzen-dev, every CI host (zuvo-update's
  admission suite in zuvo-main-<sha>.tmp clones) and the farm (/home/tf); mock lanes, the fake
  OpenRouter key ("bad key"), a fake 502, fake CLIs under real lane names on few-character diffs, their
  failure-evidence dirs, and one test record (model "m") in the real ~/.qwen/usage_record.jsonl.
  Planned as Task 1 of the lane-rename plan for the run log; the evidence dirs and ~/.qwen need the same
  isolation. The ai-usage page filters them by heuristics meanwhile. confidence:95 | 2026-10-05
- [ ] B-20261005-CLAUDE-LANE-ERROR-TEXT [P1][scripts/lib/model-subprocess.sh zms_run_claude / run_claude] —
  a failing claude lane leaves only "claude failed (exit 1)" in provider_claude.stderr; claude's own
  message is dropped. 978 CI reviews on ryzen-tf failed this way (2 s each, in multi-hour windows —
  looks like a usage limit) and none can be classified. Not in the lane-rename plan's DC list: add it to
  Task 4's classification. confidence:90 | 2026-10-05
- [ ] B-20261005-AGY-OPUS-FALLBACK [P2][shared/includes/model-registry.sh ZUVO_MODEL_AGY_FALLBACK] — the
  agy fallback "Claude Opus 4.6 (Thinking)" answered 0 of 2,074 calls in a week (and `agy models` no
  longer lists it). User asked to remove it. Planned as Task 7 of the lane-rename plan. confidence:95 | 2026-10-05
- [ ] B-20261005-PIN-UNHEALTHY-LANE [P2][scripts/adversarial-review.sh ZUVO_REVIEW_PIN_PROVIDERS] — pinned
  lanes (agy, cursor-agent) take a slot in every review even when failing: agy on ryzen-dev was not
  logged in for a week and still occupied 1 of 5 slots each run (and on the Mac ran in only 18% of
  reviews, so its slot went to random lanes). A pin should yield while its lane is benched or failing auth.
  confidence:85 | 2026-10-05
- [ ] B-20261005-MUSE-NO-OPT-IN [P2][scripts/adversarial-review.sh detect_providers :2166] — muse joins the
  pool whenever the CLI is on PATH (no ZUVO_ADV_MUSE flag, unlike OpenRouter/BytePlus/qwen); Mac reviews
  used it in 64% of runs and exhausted the Muse subscription that the Mac and ryzen-dev share (429 until
  2026-10-05 00:00Z). Decision pending with the user: opt-in flag or an env exclusion. confidence:90 | 2026-10-05
- [ ] B-20261005-NO-ENV-LANE-EXCLUDE [P3][scripts/adversarial-review.sh] — no environment variable excludes
  a lane fleet-wide (only per-call `--exclude`). confidence:85 | 2026-10-05
- [ ] B-20261005-LANE-CONFIG-DRIFT [P2][fleet] — lane opt-ins live in per-host shell files (Mac ~/.zshenv,
  ryzen-dev ~/.config/cc-remote/env, CI gha env): OpenRouter was silently off on the Mac 09-25..10-01 and
  on ryzen-dev until 10-04 (key file missing too). One fleet lane config shipped by install.sh /
  i9-farma, and `--doctor` listing "enabled here, missing there", would have shown it. confidence:85 | 2026-10-05
- [ ] B-20261005-INSTALL-SHIPS-DIRTY-TREE [P2][scripts/install.sh] — install.sh copies the working tree
  including other agents' uncommitted edits: this session's unfinished first ledger version went live
  for every session on 2026-09-30 ~14:57Z through someone else's install. Install from HEAD (git archive)
  or warn on uncommitted files under scripts/ shared/ skills/. confidence:85 | 2026-10-05
- [ ] B-20261005-LOG-PROJECT-BASENAME [P3][scripts/adversarial-review.sh LOG_PROJECT] — adversarial.log keys
  the project by the repo root's basename ("build" for every rdesigner CI job, worktree names elsewhere)
  while the findings ledger uses the main checkout's absolute path; the two cannot be joined.
  confidence:85 | 2026-10-05
- [ ] B-20261005-TEST-GATE-POSTCAP [P3][shared/includes/test-quality-gate.md, test-audit-batch-prompt.md] —
  the gate has no path between "WARN + backlog" and a self-rated PASS for a one-case fix the auditor
  itself prescribed after the 2-iteration cap; and pass 1 should require a complete reachable-branch
  inventory with lines (three passes each surfaced branches the previous one had not listed).
  confidence:80 | 2026-10-05
- [ ] B-20261005-ADV-SUITE-PREEXISTING-REDS [P2][tests/adversarial] — on 2026-09-30, identical on the base
  commit: PROV.6, PROV.11 (test-artifact-provenance.sh), HT.7 (test-hard-timeout-and-suspend.sh),
  CK.11–13 (test-input-chunking.sh); 23 more reds in the same run (retro/watchdog/install tests) were NOT
  checked against the base. confidence:90 | 2026-10-05
- [ ] B-20261005-RUNALL-UNTRIAGED-REDS [P3][tests/hooks, tests/skill-suite] — run-all 2026-09-30:
  test-model-run.sh (100 KB answer reported as SIGPIPE, not oversize), test-reviewer-lanes.sh,
  test-test-audit-subprocess-dispatch.sh (farm: "no git repository … cannot prove X8") — all under other
  agents' uncommitted edits at the time, never triaged. confidence:70 | 2026-10-05
- [ ] B-20261005-FLAG-CONTRACT-COMMENTS [P3][tests/skill-suite/test-adversarial-flag-contract.sh] — the arm
  scanner counts `shift` inside comments within an arm and ends an arm at any `;;` (an inner case broke
  it once this session); strip comments / parse arms structurally. confidence:70 | 2026-10-05
- [ ] B-20261005-CI-RYZEN-CLAUDE-QUOTA [P1][other repos: rdesigner scripts/ci/bb-ai-review.sh, i9-farma] —
  on ryzen-tf the gha Claude login hits limit windows (10-02 17–18, 10-03 03, 10-04 07–10 and 14 UTC):
  978 of 12,216 CI reviews (8%) got no review at all, because the step sends a PR to ONE lane. waw-tf
  was unaffected. Fix: per-host accounts or a concurrency cap, and a fallback lane in bb-ai-review.sh.
  confidence:85 | 2026-10-05
- [ ] B-20261005-OWNER-LOGINS [P2][owner action] — kimi on ryzen-dev needs a re-login ("no refresh_token",
  lane-rename plan DC-3); Muse quota is shared by the Mac and ryzen-dev (one account). agy on ryzen-dev was
  logged in 2026-10-04 13:27Z. confidence:90 | 2026-10-05

## 2026-10-05 adversarial benchmark (17 candidates) + model-bench page — what the session found, skipped or deferred

Session: 2026-10-04/05 benchmark of 17 reviewer candidates (16 via OpenRouter, grok-4.7 via the cursor
login) on the 20-diff corpus, Opus judge, plus the hub page zuvo-plugin/model-bench. Everything below was
either found and not fixed, fixed only outside git, or consciously left out.

- [ ] B-20261005-BENCH-MUSE13-JUDGED-ON-WRONG-FILES [HIGH][bench][conf 70]: `meta/muse-spark-1.3` (judged
  2026-09-05) may have been scored on another label's answers. The old `judge-model.sh` picked the raw file with
  `ls "$SAFE"-*-"$id".txt | head -1`, and `or/raw/` also holds `meta_muse-spark-1.3-contributor-…` files, which
  sort BEFORE `-fail-`/`-ok-`. The same glob made `inception/mercury-2.5` see `-preview` files and
  `aion-labs/aion-3.5` see `-mini` files (both caught and fixed 2026-10-04 before judging). Fix: check which file
  each `verdicts-meta_muse-spark-1.3.tsv` packet came from (compare finding text), re-judge with the fixed judge,
  re-run `evaluate-model.py`; the model-bench page then needs `build.py`. Source: session scan 2026-10-05.
- [ ] B-20261005-BENCH-TRAILING-NO-ISSUES-UNJUDGED [MEDIUM][bench][conf 90]: the old judge skipped any answer that
  contained a line starting `NO ISSUES FOUND`, even after real findings (mercury-2.5 appends it after 3 findings).
  9 packets in older sessions were never judged for that reason: minimax-m2.7 (1788097281-9996), minimax-m2.5
  (1788097281-9996, 1788097410-31705), tp-glm-5.2 (1788094825-87461, 1788096892-49590, 1788097361-16842),
  muse-spark-1.2 (1788097361-16842), nemotron-3-nano-30b-a3b (1788094825-87461, 1788097416-32992). Their published
  scores are undercounted. Fix: re-run `judge-model.sh <label>` for those 6 labels (it judges only missing packets;
  tp-* use judge-lane.sh / Fable to keep the judge constant), then rebuild the page. Source: session scan.
- [ ] B-20261005-BENCH-HARNESS-OUTSIDE-GIT [MEDIUM][bench][conf 85]: every harness fix of this session lives only in
  HOME-local `~/.zuvo/bench` — unreviewed, unversioned, lost on a machine move: `judge-model.sh` (exact
  `<label>-{ok,fail}-<id>` file, clean = NO ISSUES *without* any SEVERITY), `evaluate-model.py` (same exact glob in
  the missed-review counter), `subs/run-lane.sh` (`ADV=` override for a frozen driver). The OR runner fixes exist
  only in the one-off copy `or/.bench-1004.py`; `or/bench.py` itself still (a) builds prompts with the LIVE repo
  driver (runbook pitfall 1), (b) crashes because `~/.zuvo/adversarial-inputs/*.diff` no longer exist (needs the
  `judge2/<id>/CODE.diff` fallback), (c) retries a 900 s timeout 4 times as "transient" (`JSONDecodeError` after
  903 s) — ~1 h per timed-out call for nex-n2.5-pro, (d) runs 4 workers. Also: `evaluate-model.py kimi` reads
  `verdicts-kimi.tsv` (09-24) while OTHERS uses the round-1 packet `kimi`, so that label is compared with itself.
  Fix: move the harness (minus the corpus) into the repo, e.g. `scripts/bench/`, port the fixes, test the judge's
  file selection and clean-detection. Source: session.
- [ ] B-20261005-BENCH-MIXED-JUDGES-IN-UNION [MEDIUM][bench][conf 60]: the model-bench page's decision number
  (defects a reviewer adds over the production set) unions verdicts from different judges and sessions — round-1
  packet verdicts (Opus), `judge-model.sh` (Opus 5) and `judge-lane.sh` (Fable 5.1, all tp-*). The slug vocabulary
  is shared per packet, but nobody verified that two judges give the same defect the same slug; a mismatch counts
  one defect twice and inflates "adds". Fix: sample tp-* vs Opus-judged packets for slug agreement, or re-judge
  the production lanes with one judge. Source: session.
- [ ] B-20261005-BENCH-RUNBOOK-STALE [MEDIUM][doc][conf 90]: `docs/runbook/model-benchmark.md` has no row for the
  2026-10-04 session and none of its pitfalls: exact raw-file names (glob collision above), findings followed by
  `NO ISSUES FOUND`, CLI outputs wrapped in the driver header, an empty answer with 0/0 token usage = provider
  failure (re-run, not a model result), `sakana/*` 403 "not available in your region", the deleted
  `adversarial-inputs` diffs, and the model-bench page + `build.py` as the place results are read. Source: session.
- [ ] B-20261005-BENCH-SINGLE-RUN-NO-RERUN [MEDIUM][bench][conf 85]: the 2026-10-04 ranking is ONE run; the runbook
  noise is ±10 marginal defects, and the reference set was not re-measured the same day. Top candidates that need a
  same-day second run before any lane decision: mimo-v2.6-flash (+23 / 92% / $0.0063), aion-3.5 (+20), fugu-max
  (+19), grok-4.7-high (+19 / 95%), glm-5.3-flashx (+18). Source: session.
- [ ] B-20261005-BENCH-UNMEASURED-CONFIGS [MEDIUM][bench][conf 85]: measured badly or not at all: (1) the two
  production BytePlus lanes — `byteplus` glm-5.3-flash and `byteplus-3` dola-seed-2.0-code (3489 calls / 7 days
  together) — have no BytePlus measurement; the page approximates them with the same model via OpenRouter, while
  `subs/results-glm-5.3-flash-byteplus.tsv` and `subs/results-dola-seed-2.0-code.tsv` exist and were never judged;
  (2) aion-3.5-mini and nex-n2.5-mini burned the whole output budget on reasoning (32k / 131k tokens, empty answer on
  14 and 17 of 20) — a `reasoning.effort=low` run was offered and not done; (3) grok-4.7 measured only at `high`
  (637 s/diff, 2 timeouts), not medium/fast; (4) fugu-max packet 1788097416-32992 missing after the regional 403;
  (5) OpenRouter cost per review is understated for models with timeouts (no usage is returned for a timed-out
  call, e.g. nex-n2.5-pro 9/20). Source: session.
- [ ] B-20261005-ADV-LANE-DECISIONS-PENDING [MEDIUM][config][conf 70]: lineup findings shown on the model-bench page,
  no decision taken (owner's call; do B-20261005-BENCH-SINGLE-RUN-NO-RERUN first). Contribution = defects the
  production set loses without the lane: `codex-5.3` (gpt-6-sol, effort none; 3427 calls / 7 days — the busiest
  lane) contributes 3, within noise; same-class swap candidate grok-4.7-high via the cursor login (+14 net, but
  ~11 min/diff). `openrouter-4` gpt-oss-120b contributes 6 at 32% precision; swap candidate mimo-v2.6-flash
  (+10 net, $0.0063/review). `openrouter-3` mercury-2.5-preview contributes 7 at 28% — memory cheap-coverage-lanes
  says ask before disabling. `qwen` lane: qwen3.8-max would add +22 over production vs today's qwen3.8-flash. A
  change follows the runbook "Recording a decision" (model-registry.sh comment table, driver fallbacks,
  docs/adversarial-providers.md, lane test). Source: model-bench page 2026-10-05.
- [ ] B-20261005-ADVLOG-HEADER-MISMATCH [MEDIUM][code][conf 80]: `~/.zuvo/adversarial.log` header has 14 columns
  (`date run_id mode provider model input_chars …`) but recent rows have 17 fields with the MODEL in column 4 and
  the PROVIDER in column 14 — the header no longer describes the rows. Reading by header gives wrong numbers
  (see docs/runbook/operating.md §10). Found by `build.py`, which had to hard-code positions. Fix the header writer
  in `scripts/adversarial-review.sh` (or version the format) and the readers that trust the header.
  Source: session.
- [ ] B-20261005-ADVLOG-NO-EFFORT [LOW][code][conf 75]: the adversarial log has no reasoning-effort column, so any
  report of "what runs in production" must assume the registry default (sol none, luna medium, kimi high, Opus high);
  an env override in one shell is invisible. Add effort to the log row. Source: session (model-bench build.py).
- [ ] B-20261005-UI-DESIGN-TEAM-DISPATCH-BLOCKED [MEDIUM][skill][conf 90]: `skills/ui-design-team/SKILL.md` Step 2
  agent prompts name no CodeSift tool, and the global subagent hook rejects general-purpose prompts without one —
  all 4 specialist dispatches failed on the first try. Same class likely in every skill that dispatches read-only
  general-purpose reviewers on non-code targets (check the class, not just this skill). Two more retro proposals
  from that run: a "decision audit" in Agent 1 for dashboards (one baseline per metric; recommendations the data
  supports), and a rebuild path in Step 5 when P0s are structural. Source: retro ui-design-team / tgm-mockup
  2026-10-04.
- [ ] B-20261005-FARM-HOOK-FALSE-POSITIVES [LOW][hooks][conf 85]: `hooks/farm-no-local-tests.sh` blocked two
  non-test commands this session: `npm view … version` / `npm install -g @qwen-code/qwen-code@latest`
  ("ambiguous package-manager command") and a `python3 - <<'P'` heredoc whose payload contained JS template text
  `${…}` ("shell substitution <test command>"). Workarounds cost extra turns (patch scripts written to files).
  Fix: treat `npm view|install -g|outdated` as non-test, and do not pattern-match inside quoted heredoc bodies.
  Source: session.

## Session leftovers — install.sh refactor 1f022802 and the review-queue removal (recorded 2026-10-05)

What one session skipped, worked around, or found outside its fence. The refactor's own fixes, its
test-quality remainder (B-20261005-TQ-INSTALL-*) and the host-installer size debt
(B-20261001-XV-INSTALL-HOST-INSTALLER-DUP, re-measured) are recorded elsewhere.

- [ ] B-20261005-FARM-GUARD-FALSE-POSITIVES [P3][guard-false-positive][conf 85]
**Fingerprint:** hooks/farm-no-local-tests.sh|guard|substitution-scan-before-rt-and-heredoc-data
**Source:** zuvo:refactor 1f022802 session, 2026-10-03..05 — four blocks of commands that ran nothing locally.
**What:** the inline checker (hooks/farm-no-local-tests.sh:120-160) scans every `$(…)`/backtick in the WHOLE
command before it looks at the command head or strips data heredocs, so it blocks: (a) `rt --full --light bash -c
'…out=$(timeout 900 python3 -m pytest …)…'` — already farm-routed; (b) `cat > file <<'EOF' … $(… pytest …) … EOF`
— the heredoc body is DATA written to a file, but the substitution loop runs before the heredoc strip; (c) a
`python3 - <<'PYEOF'` that only appends prose (this very entry) mentioning such a substitution; (d) `npm root -g` —
reported as `npm <ambiguous package-manager command>` although it only prints a path. The workaround each time was to
move the text into a file via the Write tool and pass it as `bash -c "$(cat file)"`, which the guard cannot see —
the false positives train agents into the exact pattern that defeats the guard.
**Fix:** skip the substitution/heredoc scan when the command head is `rt`/`tf`; strip non-executable heredoc bodies
(`cat >`, `tee`, `python3 -`…) BEFORE the substitution scan, as the comment above the heredoc loop already intends;
allow read-only npm verbs (`root`, `prefix`, `config get`, `view`, `ls`). RED case per item in
tests/hooks/test-farm-guard-vendored.sh.

- [ ] B-20261005-EVIDENCE-SNAPSHOT-UNTRACKED [P3][workflow][conf 80]
**Fingerprint:** scripts/zuvo-home/workflow_evidence.py|workflow|snapshot-hashes-foreign-untracked-files
**Source:** zuvo:refactor 1f022802 — the commit gate BLOCKed with "stale snapshot" before each of 4 commits.
**What:** `snapshot()` (workflow_evidence.py:20, used by refactor-contract and hooks/lib/refactor-state.py:293) hashes
`git ls-files --cached --others --exclude-standard`, so ANY untracked file another process writes invalidates every
recorded run: the review-queue post-commit hook rewrote docs/review-queue.md after each commit, and `.playwright-mcp/`
or another session's draft in docs/specs/ do the same. Each time, the fix was a full `recheck` of a passing suite.
**Fix:** hash tracked files plus only the untracked files inside the contract's scope fence (or the command's
`--scope`), and when a snapshot is stale print WHICH path changed, so a foreign file is visible as the cause.
**Seen:** 2 — re-seen 2026-10-05 by zuvo:refactor dedc3165, in `recheck`: a run whose suite matched the baseline
exactly (51 passed, rc 0) but whose snapshot changed during the run is reported as "DRIFT — the suite does not do
what the baseline recorded" — a regression that is not there; the reason is visible only inside
`evidence.characterization_after`. `recheck` needs the same named-path message, kept apart from a count or exit
drift. There the changed files were TRACKED (B-20261005-ADV-TMP-TRACKED), so scoping the hash to untracked files in
the fence would not have prevented that case — only naming the paths would have explained it.

- [ ] B-20261005-ADV-TESTS-NOT-STANDALONE [P3][test-harness][conf 95]
**Fingerprint:** tests/adversarial/test-*.sh|harness|standalone-run-exits-127-silently
**Source:** zuvo:refactor 1f022802 — this session reported `test-stall-watchdog.sh` as a "pre-existing red (rc 127)"
for two days; it was the harness, not the test.
**What:** the files call `start_test`/`assert_eq`/`rc_of`, which only tests/adversarial/run.sh defines. Running one file
with plain bash (locally or through rt) prints `start_test: command not found` per case and exits 127; through
`tests/adversarial/run.sh test-stall-watchdog test-install-retro-stub test-install-verify-plan-dag` the same files are
35/35 green (farm, 2026-10-05).
**Fix:** a 3-line guard at the top of each test (or one sourced lib): when `start_test` is undefined, either source the
harness or print "run via: tests/adversarial/run.sh <name>" to stderr and exit 2. Exit 2 with a hint, never 127.

- [ ] B-20261005-ADV-TMP-TRACKED [P3][hygiene][conf 85]
**Fingerprint:** tests/adversarial/.tmp|hygiene|ignored-dir-holds-164-tracked-files
**Source:** observed in this checkout's `git status` throughout the session.
**What:** .gitignore:32 ignores `tests/adversarial/.tmp/`, yet 164 files under it are tracked, so every adversarial test
run leaves dozens of them modified (cap*.err, prov/*.md, health-*.tsv, *.log). That noise hides real changes in
`git status`, and `scripts/dev-push.sh` runs `git add -A` — it would commit whatever the last test run wrote.
**Fix:** confirm no test reads a COMMITTED fixture from .tmp (run.sh recreates empty.txt itself), then
`git rm -r --cached tests/adversarial/.tmp` in one commit; the ignore rule then holds.
**Seen:** 2 — re-seen 2026-10-05 by zuvo:refactor dedc3165: `refactor-contract recheck` recorded a fully
green characterization re-run (51/51, rc 0) as DRIFT, because an interrupted earlier run had left these files
modified and this run's cleanup restored them (`stable: False`); that refactor's characterization script resets
the directory after every run to compensate. 43 of them were modified in the main checkout at the time.

- [ ] B-20261005-REFACTOR-CQAFTER-EXAMPLE [P4][skill-docs][conf 80]
**Fingerprint:** skills/refactor/references/completion.md|docs|cq-after-example-fails-verifier
**Source:** zuvo:refactor 1f022802 retro proposal 3 — two `cq_after` writes rejected by `refactor-contract check`.
**What:** the example under "Update Contract State" does not show a baseline-debt WARN, and the verifier
(hooks/lib/refactor-state.py `assessment_errors`) rejects shapes an agent naturally writes: a list of gate names under a
non-metadata key ("expected an assessment object or collection"), an empty list under any key but
`critical_failures`, and any status outside PASS / CONDITIONAL PASS / WARN / COMPLETE / N/A (e.g. `DEGRADED`).
**Fix:** add the accepted example — `{"status":"WARN: refactor delta = baseline debt only","score":"…",
"critical_failures":[],"notes":"<baseline gates + full report path>","applicability_review":{"status":"WARN: same-model
review",…}}` — and one sentence: put baseline gate lists in `notes`.

- [ ] B-20261005-REFACTOR-TQ-UNSCORED-RULE [P4][skill-docs][conf 75]
**Fingerprint:** skills/refactor/references/remediation.md|docs|test-quality-unscored-files-no-rule
**Source:** zuvo:refactor 1f022802 retro proposal 4. The AP13 cause is fixed (6a1dbebb); the gap stays for any file the
rubric cannot score.
**What:** Phase 3.6 Step 1 has no rule for a test-audit report with UNSCORED files, and `prove.test_quality` accepts
only PASS/WARN/N/A — an agent is pushed to write WARN for a fix loop that never ran.
**Fix:** "Files the report marks INCOMPLETE: leave prove.test_quality unset, record test_quality_assessment.status =
INCOMPLETE with the reason, re-score before the fix loop."

- [ ] B-20261005-CONTRACT-SET-NO-DRYRUN [P4][tooling][conf 60]
**Fingerprint:** scripts/zuvo-home/refactor-contract|tooling|set-has-no-validate-only
**Source:** zuvo:refactor 1f022802 retro.
**What:** `refactor-contract set <key> <json>` writes any shape; the rejection appears only at `check`, after the run
has moved on.
**Fix:** run `assessment_errors` on the candidate value inside `set` for `cq_after`/`q_after`/`test_quality_assessment`
and refuse (or `--validate-only`) with the same messages `check` prints.

- [ ] B-20261005-LEDGER-REPORTED-AT-COMPLETE [P4][tooling][conf 70]
**Fingerprint:** scripts/zuvo-home/refactor-contract|tooling|ledger-reported-survives-complete
**Source:** zuvo:refactor 1f022802 — contract COMPLETE, `check` exit 0.
**What:** the run's findings ledger (zuvo/reports/refactor/1f022802-findings.json) still holds 20 entries with
disposition `reported` — first-pass findings that later fix commits (4f319747, 69a8888c) resolved — and nothing
requires a terminal disposition before COMPLETE. A reader of the ledger cannot tell open from superseded.
**Fix:** `check` refuses COMPLETE while any entry is `reported`/`open`; the fix-recording step marks the findings a fix
group supersedes (`superseded-by:<fix group>`).

- [ ] B-20261005-CODESIFT-FRICTION-EXTERNAL [P4][external][conf 60]
**Fingerprint:** codesift-mcp|external|alternation-timeouts-grep-hook
**Source:** this session; codesift-mcp is a separate project — recorded here so zuvo's codesift-setup.md can note it.
**What:** `search_text` treats `a|b` literally (zero hits, no hint); nearly every search reports "semantic pass exceeded
4000ms and was abandoned"; the PreToolUse hook blocks a Bash command that greps paths OUTSIDE the repo
(`~/.claude/hooks`) because the same command `cd`s into the indexed repo; the index went stale after a merge of 150
commits until `index_folder` was run by hand.
**Fix:** report upstream; in shared/includes/codesift-setup.md say that alternation needs separate calls.
**Seen again:** 2026-10-05 (hook-perf session, 2026-09-27..10-05) — three more: (a) the `codesift precheck-bash` hook refuses grep/find/rg even when the CodeSift MCP server failed to connect that session (CONNECT_TIMEOUT 2026-09-27) — neither tool usable, worked around with `git grep`/awk; the hook should step aside when the server is not connected. (b) `describe_tools(reveal=true)` returns `reveal_ineffective` on a host that caches its tool list at session start, so zuvo:review's mandatory review_diff/changed_symbols/diff_outline/scan_secrets were absent-in-build and substituted — codesift-setup.md should make that a planned substitution, not a per-skill surprise. (c) `search_text` with `file_pattern="skills/**/agents/*.md"` failed with `Cannot find module …/codesift-v0.19.1/dist/register-tool-loaders.js` while other patterns worked.

## 2026-10-05 adversarial-review split (refactor dedc3165) — left open: deferred, out of scope, or not done yet

- [ ] B-20261005-ADV-SPLIT-UNFINISHED: branch `refactor/adversarial-review-split` (worktree
  `~/DEV/zuvo-plugin-worktrees/adversarial-review-split`, contract `zuvo/contracts/refactor-dedc3165.json`)
  is NOT pushed and NOT merged. State on 2026-10-06: the refactor contract is COMPLETE (`check` PASS;
  quality WARN, mutation 45/45). origin/main 88c7f160 was merged in at ba08d815: main's driver hunks were
  ported into the modules, and the branch's installer code moved into scripts/install.d/. The merge was
  checked with the 51-suite characterization package and run-all, and tests/lib/install-manifest.sh shows
  the same installer effect as main plus the driver modules. The p12 cross-model review of the merge and
  the comment pass was fixed at b4ebc456 (21 findings fixed, 44 rejected with reasons, in the findings
  ledger). Left: the p13 review of that fix delta, the push-gate review artifact, then push, PR and merge.
  Push needs the owner's go-ahead. Tick when the branch is merged.
  | conf: 100 | source: zuvo:refactor | seen:2 | 2026-10-05
- [ ] B-20261006-FANOUT-RANKED-MESSAGE: ar_cap_fanout (scripts/lib/adversarial-providers.sh; the same code is
  on main in the monolithic driver) prints "sampled at random" and "pinned: …, rest sampled at random"
  under ZUVO_REVIEW_PROVIDER_PICK=ranked, which keeps the first N in ranking order and ignores the pins.
  Its hint then suggests `ZUVO_REVIEW_PROVIDER_PICK=ranked` to someone already using it. Fix: one message
  per pick mode ("N of M, ranked — the first N kept"), with the CAP.4b-4e and pin expectations in
  tests/adversarial/test-provider-fanout-cap.sh updated to match. Found while checking the split's p12
  review; it was left alone because the refactor preserves behaviour. | conf: 90 | source: zuvo:refactor
  (p12 verification) | seen:1 | 2026-10-06
- [ ] B-20261006-FARM-HZ4-NO-NPM: farm host hz4-tf fails every `rt` run of a repo with a package-lock.json
  with INFRA_DEPS (`tf-phase: npm: command not found`, node v18.19.1, exit 24), even when package.json
  declares no dependencies. zuvo-plugin has such a lock (3cbddee0). Three runs from one worktree failed
  there in a row; the same run passed on hz3-tf (node v24) with `TF_HOST=hz3-tf`. Fix in i9-farma: npm on
  hz4-tf, or the broker skipping the deps phase when package.json declares no dependencies. |
  conf: 95 | source: zuvo:refactor (merge check) | seen:2 | 2026-10-06
- [ ] B-20261006-NONASCII-BLANK-ANSWER: result_has_text (scripts/lib/adversarial-dispatch.sh) treats ASCII
  whitespace as blank (fixed b4ebc456 for CR/FF/VT), but an answer of only non-ASCII whitespace (NBSP,
  U+2003, an ideographic space) still counts as a review. It was left on purpose: no lane has been seen to
  answer that way. Fix if one does: strip the UTF-8 encodings of the Unicode space separators before the test.
  | conf: 60 | source: zuvo:refactor (p12) | seen:1 | 2026-10-06
- [ ] B-20261005-FARM-HOOK-HOOK-SUITES: hooks/farm-no-local-tests.sh sends every `bash tests/...` to `rt`,
  while docs/runbook/testing.md §5 says this repo's tests/hooks suites are NOT a valid signal on the farm
  (they read real git state, ~/.claude, ~/.zuvo and gitignored memory/reviews/). Its opt-out must begin
  the whole command and refuses separators and substitutions, so one hook suite that needs a `cd` or a
  tool on PATH (test-shellcheck with zuvo/context/bin/shellcheck) cannot be run in one line — it took a
  wrapper script. Fix: route by suite (hook suites local, as the runbook says) or let the opt-out ride on
  the test command itself. Same routing problem as B-20260928-RT-SKIPS-LINT-GATES; the guard's
  false positives on substitutions and heredocs are B-20261005-FARM-GUARD-FALSE-POSITIVES. | conf: 90 |
  source: zuvo:refactor | seen:1 | 2026-10-05
- [ ] B-20261005-BLIND-AUDIT-SAME-MODEL: the split's blind coverage audit is recorded as
  `prove.blind_audit = clean:degraded:same-model,no-machine-checks` — no other-vendor lane and no machine
  checks. Re-run it with at least two vendors over the eleven modules before calling their coverage
  independently audited. | conf: 80 | source: zuvo:refactor | seen:1 | 2026-10-05
- [ ] B-20261005-STAMP-WRITER-FAILS-UNDRIVEN: `install_adv_module_stamp` (scripts/install.sh on the split
  branch; install.d/copy.sh after the merge): its own `mktemp` failure and the failed `install_file_atomic`
  of the stamp are never driven. test-install-wiring (12s) drives a module that fails to copy, one blocked
  in both sets, one missing from the source, an indented AR_MODULES and the write order — not the stamp
  writer failing. Fix: a (12s) case per branch (a failing mktemp shim; a stamp destination that cannot be
  replaced), asserting the counted miss and that the driver refuses that set. | conf: 85 |
  source: zuvo:refactor (TQ-3 residue) | seen:1 | 2026-10-05
- [ ] B-20261005-GOLDEN-CHFLAGS-SKIP: tests/hooks/test-adversarial-lane-golden.sh case 5c(5) — a result
  file `rm` cannot remove — skips wherever `chflags` is absent (:809-811), i.e. on every Linux host: the
  sessions host and the whole farm. It runs only on macOS. Fix: a Linux path (the result file inside a
  directory made read-only, or `chattr +i` where permitted). | conf: 90 | source: zuvo:refactor (TQ-11
  residue) | seen:1 | 2026-10-05
- [ ] B-20261005-SHELL-METRICS: two refactor gates have no shell tooling. CodeSift `analyze_complexity`
  returns "no functions found" for .sh, so the split's prove.complexity_before/reduced were measured with
  an unversioned ad-hoc script (function and top-level bodies, branch tokens); and no bash line/branch
  coverage tool (kcov, bashcov) is installed, so Q25 and the refactor skill's "transitive coverage must be
  measured" rule cannot be met for shell targets. Fix: a versioned shell metrics helper the refactor skill
  names for .sh; kcov on the farm image. | conf: 80 | source: zuvo:refactor | seen:1 | 2026-10-05
- [ ] B-20261005-TQ11-RESIDUE (verify before fixing — the audit's line numbers are at f77cd2fe): from the
  split's test-quality audit TQ-11 (pre-existing debt in suites the branch modified), the items the
  follow-up test commits did not cover: test-artifact-provenance.sh conditional assertions (AP2) beyond
  PROV.17; test-adversarial-lane-golden.sh never drives the claude lane's timeout (124) path. | conf: 60 |
  source: zuvo:refactor (TQ-11) | seen:1 | 2026-10-05
- [ ] B-20261005-LANE-OUTPUT-UNCAPPED: scripts/lib/adversarial-dispatch.sh — a lane's stdout is written to its
  result file with no size bound while it runs (`dispatch_provider … > result_<lane>.txt`, and in --single the
  same); LANE_ANSWER_MAX_BYTES (2 MiB) is applied only after the lane exits. A runaway or hostile client can fill
  the disk for up to its whole timeout. Older than the split (634bad5a wrote it the same way; --single used to
  hold it in memory). Fix: stream the capture through `head -c $((LANE_ANSWER_MAX_BYTES + 1))` and treat the
  extra byte as "cut". Found by the split's cross-model pass p6 (P6-023), verified, deferred: it changes how
  every lane's output is captured, which is its own change with its own tests. | conf: 85 |
  source: zuvo:refactor (p6) | seen:1 | 2026-10-05
- [ ] B-20261005-MAIN-RED-HOSTID-IP: tests/hooks/test-install-wiring.sh (8) "versioned helper names a host
  address" FAILs on scripts/zuvo-home/zuvo_host_id.py — red on a clean main checkout (40a17543): its comments
  quote a measured LAN address (`192.168.0.124`, lines 11 and 114) as an example of an unstable host name.
  The rule exists so no versioned helper carries a fleet address; write it as `192.168.x.y`. Found while
  verifying the adversarial-review split's merge of main, outside its fence. | conf: 95 |
  source: zuvo:refactor (merge verification) | seen:2 | 2026-10-05
  Re-observed 2026-10-05 by zuvo:build (review-queue retirement): the same address also turns
  tests/hooks/test-retro-loop-docs.sh red ("hardcoded IP in zuvo_host_id.py") — two of the three files a full farm
  `tests/run-all.sh` fails on main; B-28's backlog-collect.py/runlog-collect.py no longer trip check (8), so B-28 may
  be closeable once test-retro-loop-docs is re-checked.
- [ ] B-20261005-MAIN-RED-SC2010: tests/hooks/test-shellcheck.sh is red on a clean main checkout (40a17543):
  one new warning against a ratchet of 0 — tests/hooks/test-install-host-ownership.sh:388 (SC2010,
  `ls -A "$H/.codex" | grep -v '^hooks.json$'`). Fix with a glob or
  `find "$H/.codex" -mindepth 1 -maxdepth 1 ! -name hooks.json`. Found while verifying the adversarial-review
  split's merge of main, outside its fence. | conf: 95 | source: zuvo:refactor (merge verification) | seen:1
  | 2026-10-05

## 2026-10-05 — hook-performance session leftovers (b0e65d51..f251e424: deliberate skips, out-of-fence findings, unreviewed landings)

Recorded at the user's request: everything the 2026-09-27..10-02 session skipped on purpose, missed, ran out of time for, or found outside its fence. Every behavioural claim below was RE-VERIFIED on main 6e098f3d on 2026-10-05; three were already filed today and got a `Seen again` line instead (B-20260929-PREPUSH-FASTPATH-SUBSTRING, B-20261005-REVIEW-QUEUE-STILL-WRITTEN, B-20261005-CODESIFT-FRICTION-EXTERNAL; plus B-20260928-TFABLATE-SHELL); items that no longer reproduced were dropped (the `test-install-copy-verification.sh` SIGPIPE flake — already fixed; a heredoc false positive in the farm guard — did not reproduce in the filed shape).

- [ ] B-20261005-SUBAGENT-GIT-ISOLATION [P1][skill-infra][conf 95]
**Fingerprint:** skills/review/agents/cq-auditor.md|git-isolation|global-config-write
**Source:** `zuvo:review` 2026-09-29 (hook-perf), CQ auditor sub-agent. Forensics: `~/.gitconfig` mtime 03:33:24Z, the auditor's `gitproof2.sh` written 03:33:23Z.
**What:** a dispatched auditor proved bypasses against real git in a throwaway repo, but one probe line was `git config --global core.hooksPath -l --dry-run` (git config has no `--dry-run`). It appended `hooksPath = -l` as a SECOND global value; git uses the last one, so the global zuvo pre-push/pre-commit dispatch was silently disabled machine-wide for hours, and the next `install.sh` died with "cannot overwrite multiple values". The script's cleanup only unset the LOCAL config. No agent prompt asks for isolation: `skills/*/agents/*.md` mention `GIT_CONFIG_GLOBAL` 0 times (the test suites isolate; ad-hoc proof scripts do not).
**Fix:** fix the class, not one file — every agent prompt that may execute git (review cq-auditor / behavior-auditor / confidence-rescorer, write-tests and refactor auditors, any "prove it against real git" lane) gets `export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1` (or a temp HOME) and a ban on `--global`/`--system` writes. Add a cheap invariant the lead (or a SubagentStop hook) checks after each agent returns: `git config --global --get-all core.hooksPath` prints exactly one value.

- [ ] B-20261005-VERIFY-AUDIT-VACUOUS-PASS [P2][tooling][conf 95]
**Fingerprint:** scripts/zuvo-home/verify-audit|parser|unparsed-findings-pass
**Source:** `zuvo:review` 2026-09-29; re-verified 2026-10-05.
**What:** a report whose findings are written `R-1 [MUST-FIX] …` (not `### R-1`, `**R-1 —**` or `- R-1`) gets `OK: … no finding sections detected (informational report)` and rc 0 — re-verified with a MUST-FIX finding citing `hooks/block-no-verify.sh:9999`, a line that does not exist. The empty-parse guard (verify-audit:240-280) fires only on a MUST-FIX *heading*. `skills/review/SKILL.md` never states the header shape verify-audit parses, so a review in that shape passes append-runlog's audit-content gate having verified nothing.
**Fix:** exit 2 when the text carries MUST-FIX/RECOMMENDED tokens or `R-<n>` finding lines but zero findings parsed ("findings present but none parsed — use `### R-N` headers"); document the `### R-N [SEVERITY] title` + `File: path:LINE` + `Verified-against: <sha>` shape in review Phase 3 "Report Persistence".

- [ ] B-20261005-INSTALL-CODEX-SYMLINK-PARTIAL [P2][install][conf 95]
**Fingerprint:** scripts/install.d/codex.sh|copy|symlinked-shared-includes-aborts-install
**Source:** install on the sessions host (ryzen-tf) 2026-10-01, rc=1.
**What:** `mkdir -p ~/.codex/shared/includes; cp -r "$DIST"/shared/* ~/.codex/shared/` fails with `cp: cannot overwrite non-directory … with directory` when `~/.codex/shared/includes` is a symlink. One existed (created by hand 2026-09-29, pointing at the Claude plugin cache's includes — Claude-flavoured `../../` paths, wrong for Codex). install.sh then exits mid-run: Claude Code done, Codex partial, Cursor / Antigravity / Kimi / zuvo-home never ran — targets left on mixed versions. Resolved on that host by removing the symlink by hand.
**Fix:** before writing, check each copy destination: replace a symlink/non-directory that zuvo owns (log it), or refuse up front naming the path — never die halfway. Add a sandbox-HOME case with a symlinked `~/.codex/shared/includes` (tests/lib/install-manifest.sh).

- [ ] B-20261005-PLUGIN-CACHE-STALE [P2][install][conf 60]
**Fingerprint:** scripts/install.d/claude.sh|cache|plugin-cache-not-refreshed
**Source:** sessions host (ryzen-tf) 2026-10-01.
**What:** `~/.zuvo` stamped 23fbad98 (installed 2026-09-30) and `~/.claude/hooks/block-no-verify.sh` was that version, but the directory Claude Code actually loads (`installed_plugins.json` installPath = `cache/zuvo-marketplace/zuvo/1.6.80`) still held 2026-09-27 files — the pre-fix hooks with the quote-split and empty-value bypasses ran on every Bash call for ~4 days. Root cause NOT established (that install's log is gone); candidate: the run that stamped 23fbad98 skipped or silently failed the Claude Code section.
**Fix:** after copying, compare hashes of `hooks/` between the source and EVERY cache dir including installPath; mismatch = INSTALL INCOMPLETE. Reproduce with a read-only or missing cache dir in a sandbox HOME.

- [ ] B-20261005-INSTALL-HOOKS-CP-IN-PLACE [P3][install][conf 80]
**Fingerprint:** scripts/install.d/hooks.sh|copy|in-place-overwrite-running-scripts
**Source:** hook-perf session 2026-09-28 (flagged, not fixed).
**What:** `install_hook_tree` (scripts/install.d/hooks.sh:13) copies `hooks/*.sh`, `hooks/lib/*` and `run-hook.cmd` with plain `cp` onto existing files — same inode, truncate+write. bash reads a running script by byte offset (docs/runbook/operating.md), so a hook mid-execution during an install resumes at a stale offset in the new content. Before b0e65d51 Stop/pre-commit gates ran for minutes, so the window was real (6 were running during one install).
**Fix:** copy to `<dst>.tmp.$$` then `mv -f` (atomic rename, new inode — running processes keep the old file) for every hook destination, including the `~/.claude/hooks` copies.

- [ ] B-20261005-FARM-GUARD-TESTS-SH-FP [P3][code][conf 95]
**Fingerprint:** hooks/farm-no-local-tests.sh|matcher|tests-sh-filename-false-positive
**Source:** hit 3x during the hook-perf session; re-verified 2026-10-05.
**What:** (a) `bash -c 'git diff -- hooks/block-no-verify.sh hooks/farm-no-local-tests.sh | wc -c'` is refused as `bash -c <test command>` — `nested_has_suite`'s `\b(bash|sh|zsh|dash)\s+[^;&|\n]*(tests?|run-all|run-tests|check)\.(sh|bash)\b` matches the `sh` ending `block-no-verify.sh ` followed by a filename ending in `-tests.sh`; (b) running the guard itself (`bash hooks/farm-no-local-tests.sh < payload.json`) is refused because `looks_like_test_script` matches `-tests.sh`. Both block legitimate diagnostics of this very hook.
Sibling of B-20261005-FARM-GUARD-FALSE-POSITIVES (substitution/heredoc scan) — a different matcher, a separate fix.
**Fix:** in `nested_has_suite` require the shell word to be a command head (start, or after a separator/`-c`), not any `sh` token; exempt the guard's own path; add both commands as allow cases in tests/hooks/test-farm-guard-vendored.sh.

- [ ] B-20261005-GATE-KNOWLEDGE-JSONL [P3][gate][conf 85]
**Fingerprint:** hooks/lib/pipeline-gate-lib.sh|classifier|knowledge-jsonl-production
**Source:** pushes blocked during the hook-perf session (2026-09-28..10-01).
**What:** `pg_is_production` (:99) excludes `*.json`/`*.yaml`/`*.toml` but not `*.jsonl`, so `knowledge/{decisions,gotchas,patterns}.jsonl` — data appended by knowledge-curate — count as production: pushes were blocked on them 3 times in the session (each a one-line curated append), and they inflate the substantial-file count.
**Fix:** decide deliberately: exempt `knowledge/*.jsonl` (data written by a reviewed helper) or keep it gated and say why in the classifier comment; add a classify test either way.

- [ ] B-20261005-UNREVIEWED-LANDINGS [P3][review][conf 90]
**Fingerprint:** hooks/lib/pipeline-gate-lib.sh|review|landed-below-threshold-unreviewed
**Source:** this session's 2026-10-02 push (a7224dc0..f251e424).
**What:** three commits reached origin/main BELOW the pipeline-entry threshold (2 production files, ~40 lines) and therefore with no `zuvo:review` artifact: ce3fc358 (the gate classifier now exempts `.zuvo/*` from review — a policy change to what the gate sees; authored 2026-09-23 on an orphaned branch), 62ce6dbe (`ZUVO_REVIEW_ACCESS` in scripts/adversarial-review.sh — reviewer-lane access) and f251e424 (lane-golden contract update). Tests were green (gate-lib 142/0, review-access 13/13, lane-golden 205/0, adversarial subset 70/70) — legal to push, not reviewed. Note the `.zuvo/` exemption lets anything placed under `.zuvo/` skip review (same class as the existing `zuvo/*`).
**Fix:** `zuvo:review a7224dc0..f251e424` (TIER 1, one `--multi` pass), and write the content-keyed artifact.

- [ ] B-20261005-BNV-MULTILINE-OVERBLOCK [P4][code][conf 90]
**Fingerprint:** hooks/block-no-verify.sh|tokenizer|newline-not-connector
**Source:** `zuvo:review` 2026-09-29 R-10 (accepted NIT); re-verified 2026-10-05.
**What:** xargs flattens newlines, so the hooksPath read/write scan does not stop at a line break: `git config --get core.hooksPath` followed on the NEXT line by any command is BLOCKED (rc 2; the `&&` form is allowed). Safe direction, and identical to the behaviour before b0e65d51.
**Fix:** only with a newline-aware tokenizer that preserves `\`-continuations — naively turning newlines into `;` makes `git commit \<NL>--no-verify` a bypass.

- [ ] B-20261005-BNV-EXPANSION-RESIDUE [P4][docs][conf 90]
**Fingerprint:** docs/pipeline.md|known-bypasses|ansi-c-and-parameter-expansion
**Source:** adversarial pass 3 of the 2026-09-29 review; re-verified 2026-10-05.
**What:** block-no-verify does not expand shell syntax, so `$'\x67it' commit --no-verify` and `x=; g${x}it commit --no-verify` are ALLOWED (rc 0; identical before b0e65d51). Expected for a best-effort string parser (the git PATH-shim sees real argv), but docs/pipeline.md "Known bypasses of the `--no-verify` defense layer" does not list these two shapes.
**Fix:** add both to that list (no code change), or state that the shim is the layer that covers them.

- [ ] B-20261005-DOUBLE-GATE-PER-PUSH [P4][perf][conf 70]
**Fingerprint:** hooks/pre-push-gate.sh|perf|evaluated-twice-per-push
**Source:** user's profiling report 2026-09-27; kept deliberately in the hook-perf work.
**What:** an agent `git push` evaluates the coverage gate twice — PreToolUse (`gate_legacy`, @unpushed..HEAD) and the git-native pre-push via the global dispatcher (`gate_native`, @unpushed..<sha>) — same verdict on a fast-forward. Kept on purpose (independent layers for Codex/Husky), and cheap since b0e65d51 (~1 s each with the header cache): cost, not correctness.
**Fix (optional):** let the native hook reuse a PreToolUse verdict keyed on (tip sha, remote-refs hash, artifact-index fingerprint) for a short window.

- [ ] B-20261005-HOOK-FILES-CQ11 [P4][arch][conf 80]
**Fingerprint:** hooks/block-no-verify.sh|CQ11|oversized-hook-files
**Source:** CQ auditor, `zuvo:review` 2026-09-29.
**What:** block-no-verify.sh 476 lines (`violates_segment` ~120); farm-no-local-tests.sh 450 lines, ~280 of them embedded python; route-suite-through-verify.sh 285 lines, mostly an embedded python heredoc. Embedded python is neither linted nor unit-tested as python, and the farm guard's bash `_fw` word list duplicates its python RUNNERS/PMS/TASK_SUBCMDS (kept in sync only by a test).
**Fix (structural-refactor, zuvo:refactor):** move each python matcher to `hooks/lib/<name>.py` with unit tests; split `violates_segment` per subcommand; keep the bash fast paths in front.

- [ ] B-20261005-TRACK-INCLUDES-TMP [P4][security][conf 60]
**Fingerprint:** hooks/track-includes.sh|CQ31|predictable-tmp-path
**Source:** CQ auditor, `zuvo:review` 2026-09-29 (only traversal was fixed then).
**What:** appends to `/tmp/zuvo-includes-${session_id}.txt` — a predictable path in a world-writable dir; another local user could pre-create it as a symlink and redirect the append. Low on single-user machines, real on shared farm/session hosts.
**Fix:** a per-user directory (`${TMPDIR:-/tmp}/zuvo-$(id -u)/` mode 700, or `~/.zuvo/includes/`), updating run-logger.md's reader in the same change.

- [ ] B-20261005-GATE-ENGINE-ODD-FILENAMES [P4][code][conf 60]
**Fingerprint:** hooks/lib/pipeline-gate-lib.sh|engine|newline-us-tab-filenames
**Source:** design note of the batched coverage engine (b0e65d51).
**What:** the engine passes artifact paths one per line and records with `\037` separators: an artifact filename containing a newline or `\037` is silently skipped (never read — cannot grant coverage, the safe direction); a path with a TAB is never cached (re-read every run). Changed-file paths with a newline were already unsupported upstream.
**Fix:** document as a known limit, or NUL-delimit the artifact list (BWK awk has no portable `RS="\0"` — needs care).

## Session leftovers — the review-queue retirement (zuvo:build, recorded 2026-10-05)

- [ ] B-20261005-RQ-TGM-PULSE-TRACKED [P4][cleanup][conf 95]
**Fingerprint:** tgm-pulse/docs/review-queue.md|cleanup|tracked-review-queue-left
**Source:** the review-queue retirement (branch chore/retire-review-queue), its cleanup on ryzen-old-1.
**What:** `~/DEV/tgm-pulse/docs/review-queue.md` is TRACKED in that repository, so the installer's cleanup keeps it
(it deletes only untracked files) and names it once. It is the same dead artifact as the 234 untracked copies it removed.
**Fix:** `git rm docs/review-queue.md` in tgm-pulse through that repository's normal PR flow.

- [ ] B-20261005-RQ-BROKEN-WORKTREE [P4][cleanup][conf 70]
**Fingerprint:** tgm-survey-platform-worktrees|cleanup|queue-in-dir-git-does-not-own
**Source:** same cleanup run.
**What:** `~/DEV/tgm-survey-platform-worktrees/vw-dk-control-preflight-1003/docs/review-queue.md` was kept as "not at
the root of a git work tree": the directory is no longer a working worktree (pruned or broken), so git cannot say
whether the file is tracked.
**Fix:** check whether that worktree directory still holds anything of value; if not, remove the directory (and
`git worktree prune` in tgm-survey-platform). The queue file goes with it.

- [ ] B-20261005-RQ-OTHER-MACHINES [P4][cleanup][conf 80]
**Fingerprint:** scripts/install.d/retire_review_queue.py|cleanup|runs-on-next-install-per-machine
**Source:** same change.
**What:** the cleanup runs inside `install.sh`, so the Mac (and any other machine with the old hook) is cleaned on its
next install only. Until then its ~/.claude/hooks/post-commit keeps writing queue files, and ccsync can lay the Mac's
untracked `docs/review-queue.md` copies into this host's checkouts again — where no memory file points at them any more,
so the host's own cleanup will not find them.
**Fix:** after the next install on the Mac, re-run `python3 scripts/install.d/retire_review_queue.py "$HOME" --dry-run`
on both machines; if copies came back on the host, delete the untracked generated ones in `~/DEV/*/docs/`.

- [ ] B-20261005-FARM-HZ4-NO-NPM [P3][external][conf 90]
**Fingerprint:** i9-farma|hz4-tf|npm-missing-INFRA_DEPS
**Source:** rt runs from the zuvo-plugin-wt-retire-rq worktree, 2026-10-05 (runs 1791197958-1353386-5881 and the retry).
**What:** two consecutive `rt --full --light python3 -c …` jobs landed on hz4-tf and died before the command with
`tf-phase: line 3: npm: command not found` → `INFRA_FAILURE=INFRA_DEPS`, exit 24 — for a repo whose package.json
declares no dependencies. The same job on ryzen-tf passed, as did earlier jobs on hz3-tf; both jobs that hz4-tf got failed this way.
**Fix (i9-farma, not this repo):** install node/npm on hz4-tf (or take it out of rotation), and skip the dependency
install entirely when package.json declares no dependencies — the runner already notes that case.

- [ ] B-20261005-TA-DISPATCH-RED-ON-FARM [P3][test-red][conf 90]
**Fingerprint:** tests/skill-suite/test-test-audit-subprocess-dispatch.sh|farm|needs-git-and-local-scratch
**Source:** full `tests/run-all.sh` on the farm, 2026-10-05; the same two failures at the unchanged base (40a17543,
run 1791198467-1736507-11751), so not caused by the change that ran it.
**What:** on the farm the suite fails twice: `refusing to remove an unexpected scratch path: /scratch/tf/t/<id>/tmp.<x>`
(its cleanup guard does not know the farm's scratch root) and `Phase 3b vs <sha>: no git repository at
/home/tf/jobs/<job> — cannot prove X8 (not skipped)` (the farm mirror is not a git checkout). Every full run on the farm
is therefore red, which hides real regressions in the same suite.
**Fix:** allow the farm scratch root (or `$TMPDIR`) in the cleanup guard, and make the X8 proof SKIP — loudly, by name —
when there is no git repository, as the other git-dependent suites do (memory reference_farm_has_no_bats: the farm also
has no bats).

- [ ] B-20261005-RQ-RETIRE-SUNSET [P4][cleanup][conf 85]
**Fingerprint:** scripts/install.d/retire_review_queue.py|cleanup|one-off-retirement-runs-every-install
**Source:** the review-queue retirement (1c23d67d), its final adversarial pass (a reviewer asked for a completion
marker; declined, see below).
**What:** `install_claude_home` runs the retirement on every install, on purpose: other machines clean themselves
on their next install, and ccsync can re-lay a Mac's untracked queue files onto the host after the host cleaned. Once
every machine has installed a release containing it and `python3 scripts/install.d/retire_review_queue.py "$HOME"
--dry-run` reports nothing to remove on each, the step is dead weight on every install.
**Fix:** after that check (not before ~2026-11), delete `_claude_home_retire_review_queue`, the helper, its test and
the fixture in one commit; keep the changelog entry.

- [ ] B-20261005-FARM-MIRROR-KEEPS-DELETED [P2][external][conf 90]
**Fingerprint:** i9-farma|delta-mirror|deleted-files-not-pruned
**Source:** test-quality gate of the review-queue retirement, 2026-10-05 — farm runs 1791200788-3132181-25044 and
1791200805-3147069-17594 on ryzen-tf, diagnosed by read-only run 1791200828-3163519-18267.
**What:** ryzen-tf's delta mirror of the zuvo-plugin-wt-retire-rq worktree still held
`scripts/claude-home/scripts/post-commit-review-backlog.sh` after the commit that deleted it (not in `git ls-files`,
not in the worktree). Two checks that asserted the file's absence went red there and green on hz2/hz3. Beyond false
reds, a deleted `tests/**/test-*.sh` would keep RUNNING on that host (run-all globs the tree), and a deleted module
could still be sourced — results that no longer describe the commit.
**Fix (i9-farma, not this repo):** make the delta sync prune paths absent from `git ls-files` (rsync --delete
against the listed set, or a manifest diff); add a check that the mirror's file list equals the client's.

- [ ] [test-audit] B-20261005-TQ-RETIRE-SUITE-STRUCTURE [P3][test-quality][conf 80]
**Fingerprint:** tests/hooks/test-retire-review-queue.sh|Q3,Q5,Q20,AP2|below-A-after-two-iterations
**Source:** zuvo:build (review-queue retirement) Phase 4.6b test-quality gate — WARN; report
zuvo/audits/test-quality-audit-2026-10-05-retire-review-queue.md (in the worktree; pair archived in ~/.zuvo/review-archive).
**What:** the cross-vendor re-audit (codex/gpt-6-sol) left the suite at C 16/22 on Q7/Q11 after two fix iterations; the
three branches it named were covered afterwards (case 40, acc79189, unscored). Still open: the monkeypatched
dependencies in cases 10, 37, 38, 40 are not checked for their arguments or for non-calls (Q3/Q5); the direct
helper probes (cases 10, 23, 24, 29, 30, 34, 37-40) sit in a suite declared MEDIUM (Q20); the permission cases
7, 11, 17 skip under root and case 21 gates its assertions on its own setup (AP2).
**Fix:** move the helper probes into a SMALL-level `tests/hooks/retire-review-queue-units.py` with recorded call
arguments; give 7/11/17 a forced-failure twin like case 38 so root runs assert them too; re-audit both files.

- [ ] [test-audit] B-20261005-TQ-PGL-PRODUCTION-ARMS [P3][test-quality][conf 85]
**Fingerprint:** tests/hooks/test-pipeline-gate-lib.sh|Q11,Q9,AP27|production-arms-unfed
**Source:** zuvo:refactor (adversarial-review split) Phase 3.6 test-quality gate, 2026-10-05 — report
zuvo/audits/test-quality-audit-2026-10-05.md in worktree adversarial-review-split (in-family claude/sonnet fallback).
**What:** C, 14/19 (73.7%), Q11=0: the `*.lock` arm of `pg_is_production` (hooks/lib/pipeline-gate-lib.sh:109) and the `*.toml`/`*.yml`
members of :108 are never fed, so dropping any of them leaves the suite green. Also Q9 (the `<!-- zuvo-review -->` artifact heredoc
open-coded 25+ times, e.g. :227, :245, :609, :1193), AP27 (range assertions where the count is exact: :436-438, :455-457, :473-475),
Q19 (UCT/BAT blocks chain one artifact), Q20 (no declared test level). Out of the split's behavior scope (the branch does not change
pipeline-gate-lib.sh).
**Fix:** add `yarn.lock`, `a.toml`, `b.yml` to the classify list (:87-90); a `write_art` helper; pin the exact churn numbers.

- [ ] [test-audit] B-20261005-TQ-STATS-BRANCHES [P3][test-quality][conf 85]
**Fingerprint:** tests/hooks/test-adversarial-stats.sh|Q11,Q22|count-fallback-percentile-untested
**Source:** zuvo:refactor (adversarial-review split) Phase 3.6 test-quality gate, 2026-10-05 — same report (in-family fallback).
**What:** C, 15/18 (83%), Q11=0 for scripts/zuvo-home/adversarial-stats: count()'s ValueError/AttributeError arm (:93-95), the `?`
fallbacks for an empty model (:168) and outcome (:171), SKIP_LANES `none`/empty (:66, :164), `len(cols) <= C_PROJECT` with --project
(:166), percentile for 1 and for 3+ values (only a 2-value group is asserted, test :58). Q22: no property test for the pure units
(percentile, seconds, count, billing_for). The branch changed two lines of that script (the log path); these branches are older.
**Fix:** a fixture log with a garbage findings cell, an empty model and outcome, a `none` lane and 1/3/5/10 durations; assert the exact
P50/P90 and `-` cells.

- [ ] [test-audit] B-20261006-ADV-SPLIT-TQ-WARN [P2][test-quality][conf 85]
**Fingerprint:** tests/{adversarial,hooks,skill-suite}/*adversarial*|Q7,Q11,Q18|gate-warn-after-cap
**Source:** zuvo:refactor (adversarial-review split, contract refactor-dedc3165) Phase 3.6 Step 1 — `[GATE: test-quality]
WARN`; reports zuvo/audits/test-quality-audit-2026-10-0{5,6}.md and the per-batch answers under zuvo/audits/test-audit-details/
in the worktree adversarial-review-split.
**What:** after two fix iterations the cross-vendor re-audit (codex/gpt-6-sol, all 21 files) left 1 A, 3 B, 17 C — the C's by
Q7/Q11 scored against the WHOLE module each suite exercises (functions other suites own), not consistently (a B file with
thirteen module functions listed as untested kept Q11=1). A third, un-re-audited round (T3 commit) then closed every
slice-specific gap the auditor named. Still open by design or by cost: real-clock bounds in hardening F14/F16/F17/F21/F28/F36,
input-chunking CK.20, d1-no-retry D1.1-D1.4, outcome-classification/-refactor-regression timeouts, blind-audit G2 (Q18/AP26 —
control-run calibrated, not fake-clocked); module-private function calls in hardening; the Linux-only loud SKIPs (below).
**Fix:** re-audit the 21 files once the test-audit Q11 scope is fixed (B-20261006-TA-Q11-MODULE-WIDE), then move the
remaining real-clock cases to the fake `date`/`sleep` shims test-openrouter-response.sh and test-d1-no-retry.sh now use.

- [ ] [zuvo:test-audit] B-20261006-TA-Q11-MODULE-WIDE [P2][skill][conf 80]
**Fingerprint:** shared/includes/test-audit-batch-prompt.md|Q11|module-wide-scoring
**Source:** the adversarial-review split's re-audit, 2026-10-06 (Phase 3b review of zuvo/audits/test-quality-audit-2026-10-06.md
confirmed the inconsistency from four lanes).
**What:** the cross-vendor batch auditor scores Q7/Q11 against every function of the production FILE a suite is paired with,
so a suite written for one slice of a 900-line module is C for functions sibling suites own — and applies it unevenly. Phase
0.3's suite-aware grouping only helps when the siblings are in the same batch, which a file-list scope (the Test Quality
Gate) rarely gives.
**Fix:** the prompt should score Q7/Q11 on the slice the suite targets (its own header / the functions it calls) and credit
branches other suites in the repo cover (the auditor may grep tests/); record module-wide gaps separately, not as Q11=0.

- [ ] [security] B-20261006-BASH-SOURCE-0-FALLBACK [P3][scripts][conf 80]
**Fingerprint:** scripts|bash-source-0|cwd-as-script-dir-under-bash-s
**Source:** zuvo:refactor (adversarial-review split), third test round — fixed in the driver and reviewer-model-route.sh (C13).
**What:** `${BASH_SOURCE[0]:-$0}` falls back to $0 when a script is read from stdin (`bash -s`), and $0 is then the shell's
own name: the bare-name arm (`[ -f "$PWD/$src" ]`) makes the CWD the script directory when it holds a file called `bash`,
and `dirname "bash"` is `.` — the CWD — outright. Every file that then sources a sibling would source it from the repository
under review. Same idiom, outside the split's fence: scripts/lib/model-subprocess.sh, scripts/lib/reviewer-lanes.sh,
scripts/reviewer-preflight.sh, scripts/blind-audit-codex.sh, scripts/zuvo-home/model-run, scripts/zuvo-pipeline-entry-ci.sh,
scripts/review-artifact-sync.sh, scripts/benchmark.sh, scripts/dev-push.sh, scripts/build-{codex,cursor,antigravity,kimi}-skills.sh,
scripts/install.sh, hooks/lib/pipeline-gate-lib.sh, hooks/{pre-push-gate,pre-commit-adversarial-gate,zuvo-stop-pipeline-gate,
zuvo-archive-review-artifact,control-block-bench-gate}.sh. (provision-host.sh and test-audit-batch use it only to tell
sourced from executed — harmless.) Reachable only when such a script is piped into bash in a directory the attacker controls.
**Fix:** the C13 form: `src="${BASH_SOURCE[0]:-}"; [ -n "${BASH_VERSION:-}" ] || src="$0"`, and refuse when it is empty; a
test per family like hardening F46.

- [ ] B-20261006-PROMPT-AUTHOR-CLAUDE [P4][prompt][conf 70]
**Fingerprint:** scripts/lib/adversarial-prompt.sh|code-mode|author-hardcoded-claude
**Source:** zuvo:refactor (adversarial-review split), third test round (finding outside its suite's slice).
**What:** the code-mode review prompt says "The code was written by an AI assistant (Claude)" (adversarial-prompt.sh, ~:333)
whatever the host — on a Codex host the author is GPT and the claude lane's Opus reviewer is told otherwise.
**Fix (a decision):** name the detected writer (the router's writer_model) or drop the vendor. Either changes the prompt bytes,
so tests/hooks/fixtures/adversarial-lane-golden/*.rec must be re-recorded (stdin hash) — not done inside the refactor.

- [ ] B-20261006-LINUX-LOUD-SKIPS [P4][test][conf 75]
**Fingerprint:** tests/hooks/test-adversarial-{lane-golden,blind-audit}.sh|skip|linux-dark-gates
**Source:** zuvo:refactor (adversarial-review split), third test round (AP2: silent skips made loud).
**What:** test-adversarial-lane-golden 5c(5) (no chflags) and test-adversarial-blind-audit's locale cases (no de_DE/fr_FR
locales) now print column-0 `SKIP:` lines on Linux hosts such as ryzen-dev; dev-push.sh's dark-gate check stops on them unless
ZUVO_ALLOW_DARK_GATES=1. On the Mac both run.
**Fix:** generate the locales on the Linux hosts (`locale-gen de_DE.UTF-8 fr_FR.UTF-8`), and give 5c(5) a Linux form
(chattr +i needs root — or keep it Mac-only and say so in the dark-gate allow-list).
