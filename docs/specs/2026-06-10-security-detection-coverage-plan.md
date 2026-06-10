# Implementation Plan: Security Detection Coverage — pentest + security-audit

**Spec:** docs/specs/2026-06-10-security-detection-coverage-spec.md
**spec_id:** 2026-06-10-security-detection-coverage-0457
**planning_mode:** spec-driven
**source_of_truth:** approved spec
**plan_revision:** 2
**status:** Reviewed
**Created:** 2026-06-10
**Tasks:** 18
**Estimated complexity:** 12 standard / 6 complex (registry-wide + cross-skill edits)

## Architecture Summary

The unit of work is **markdown skill files + shared registries + a fixture corpus + two shell validators** — no application code. Component boundaries (from the spec's Integration Points):

- **Shared substrate** = `shared/includes/pentest-{finding,source-sink,safe-pattern}-registry.md` (single source of vuln-class truth, IC-1). Both skills read it.
- **Consumers** = `skills/pentest/SKILL.md`, `skills/security-audit/SKILL.md`.
- **Stack model** = `pentest-stack-{profiles,detection}.md`.
- **Validators** = `scripts/validate-pentest-output.sh` (already enforces the IC-2 surface gate) + a new `tests/security-corpus/run.sh`.
- **Proof corpus** = `tests/security-corpus/<class>/{vulnerable,clean}/` + `manifest.json`.

Dependency direction: registries (leaf) ← skills ← corpus/validators (verify the whole). The corpus harness is built first because it is the proof mechanism for every later task.

## Technical Decisions

- **Registry rows are additive** — new `finding_type`s never alter existing rows (Backward Compatibility, protected surfaces).
- **Depth gain = invoking CodeSift `trace_call_chain`/`find_references`**, seeded by registry sinks — NOT "markdown gives dataflow" (adversarial CRITICAL #3 / DD-1).
- **Two coverage metrics, cleanly separated:** IC-2 `surface_coverage` (structural, gating) vs IC-5 `class_coverage` (advisory, never gates). Missing tools/profiles lower IC-5 only.
- **Same-file sibling serialization (rule 13):** tasks editing `pentest-source-sink-registry.md` (T3, T12, T13, T14) are chained, never parallel.
- **Fixtures excluded from the 5-file boundary** (rule 2) — counted separately per task.

## Quality Strategy

- Every detection task is proven against a **vulnerable + clean twin** fixture (true-positive AND false-positive control). A clean-twin trip is a release blocker (Edge Cases).
- Risk hotspots: the `validate-pentest-output.sh` edit (T5) and coverage-gate parity (T16) touch gating logic — both get `complex` tier + their own RED that feeds a known-bad input and asserts rejection.
- CQ watch: shell validators stay <100 lines (file-limits); registry edits are data, not logic.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| AC1 | New classes detected on vulnerable fixtures | requirement | T2, T3, T6, T7, T14 | classification + seeds + fixtures |
| AC2 | No new class fires on clean twin | requirement | T4, T6, T7 | safe-pattern downgrade |
| AC3 | security-audit invokes CodeSift trace (not grep-only) | requirement | T8 | depth via real tools |
| AC4 | gitleaks scans git history | requirement | T9 | drop `--no-git` |
| AC5 | Java/Spring + Kotlin get source/sink seeds | requirement | T12, T13, T14 | stack profiles |
| AC6 | Missing scanners degrade loudly, don't fail run | requirement | T10, T11, T16 | IC-4→IC-5, not IC-2 |
| AC7 | sec-audit can't pass over un-enumerated surface | requirement | T16 | coverage-gate parity |
| AC-S1 | ≥10 net-new TP classes, zero regression | success | T18 | benchmark |
| AC-S2 | FP rate non-increasing | success | T18 | clean-twin corpus |
| SMOKE1 | E2E coverage benchmark, reconciled | smoke | **T18** (proof owner); T1, T15 supporting infra | proof in T18 Acceptance block; T1 carries the infra-smoke |
| G-DD3 | Real scanners w/ graceful degradation | deliverable | T9 (AC4), T10 (G-DD3 proof), T11 (G-DD3 proof) | explicit G-DD3 proof blocks in T10+T11 |
| G-DD5 | Cross-skill reconciliation | deliverable | T15 | IC-3 key |
| G-BC | CI/CD grace (`--strict-v2`) | constraint | T17 | warning-only one release |
| G-VAL | Validator enforces new schema | deliverable | T5 | finding_type→CWE + corpus 1:1 |

## Review Trail
- Phase 1: **direct (rate-limit fallback)** — sub-agent dispatch unreliable under an active Anthropic rate-limit storm (8 watchdog auto-resumes this session; 2 brainstorm agents died). Per plan skill's documented exception, Team Lead performed Phase 1 inline, grounded in the just-authored approved spec + the Capability Cartographer map. plan-reviewer + cross-model still run.
- Plan reviewer: revision 1 → inline review (no issues; storm made Sonnet dispatch unreliable) → revision 2 re-checked inline + deterministic DAG lint APPROVED.
- Cross-model validation: rev 1 → `adversarial-review --mode plan` 2026-06-10T05:15Z, status **partial** (gemini; codex empty, host claude excluded). 2 CRITICAL + 4 WARNING, all dispositioned in rev 2:
  - CRITICAL #1 (same-file concurrent edits) → FIXED: serialized security-audit chain T8→T9→T11→T16→T17, pentest chain T10→T15→T17, dedup-scoring T15→T16.
  - CRITICAL #2 (T8 verification theater — prompt-grep) → FIXED: T8 Verify is now behavioral (runtime trace_call_chain in run-log + finding), plus a de-risking spike sub-step (WARNING #4 folded).
  - WARNING #3 (AC orphans G-DD3/SMOKE1) → FIXED: explicit G-DD3 proof blocks in T10/T11; matrix marks T18 the SMOKE1 proof owner.
  - WARNING #5 (T14 bloat) → DISPOSITION: kept combined with justification (GraphQL+serverless edit the same two files, splitting adds serialization for no isolation gain).
  - WARNING #6 (T5 no bypass) → FIXED: `ZUVO_SKIP_PENTEST_VALIDATOR` emergency toggle.
  - Pass 2 cross-model NOT re-run: rate-limit storm + the fixes are mechanical/unambiguous; deterministic DAG re-lint substitutes for the dependency-correctness check a 2nd pass would do.
- Status gate: Reviewed (awaiting user approval).

## Task Breakdown

### Task 1: Corpus harness + manifest schema
**Files:** `tests/security-corpus/run.sh`, `tests/security-corpus/manifest.json`, `tests/security-corpus/README.md`
**Surface:** integration
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: `tests/security-corpus/run.test.sh` asserts the runner EXITS NONZERO when a manifest entry names a fixture that produces no finding of its expected `finding_type`, and EXITS ZERO when every manifest entry's vulnerable fixture yields its finding and every clean twin yields none.
- [ ] GREEN: `run.sh` reads `manifest.json` (`[{class, finding_type, vulnerable_path, clean_path, stack}]`), invokes the skill per fixture, greps the emitted findings.json for the expected `finding_type`; asserts present-on-vulnerable, absent-on-clean. `manifest.json` seeded with the 11 class stubs. README documents the add-a-class contract (each fixture carries a one-line exploit note).
- [ ] Verify: `bash tests/security-corpus/run.test.sh; echo rc=$?`
  Expected: `rc=0` (self-test passes with a seeded pass+fail fixture pair)
- [ ] Acceptance Proof:
  - SMOKE1 (infra): Surface integration — Proof: `bash tests/security-corpus/run.sh --self-test` — Expected: harness detects an injected false-negative and false-positive — Artifact: `zuvo/proofs/task-1-smoke-infra.txt`
- [ ] Commit: `test(security-corpus): fixture harness + manifest schema for detection proofs`

### Task 2: New finding_type rows (11 classes)
**Files:** `shared/includes/pentest-finding-registry.md`
**Surface:** docs
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default

- [ ] RED: `tests/security-corpus/registry.test.sh` asserts all 11 `finding_type`s (`xxe, prototype_pollution, redos, graphql_introspection, graphql_depth_unbounded, ldap_injection, insecure_deserialization, mass_assignment, ssji, jwt_weak, xss_dom`) appear with a non-null CWE and a `probe_template_id` (may be `static-only`).
- [ ] GREEN: add the 11 rows per the spec Data Model table (CWE-611/1321/1333/200/770/90/502/915/94/347/79). Preserve all 32 existing rows unchanged.
- [ ] Verify: `bash tests/security-corpus/registry.test.sh && grep -c 'CWE-' shared/includes/pentest-finding-registry.md`
  Expected: test passes; CWE count increased by ≥11
- [ ] Acceptance Proof:
  - AC1: Surface docs — Proof: grep each finding_type + its CWE in the registry — Expected: 11/11 present, non-null CWE — Artifact: `zuvo/proofs/task-2-ac1-classes.txt`
- [ ] Commit: `feat(pentest-registry): add 11 vuln-class finding_types (XXE, proto-pollution, ReDoS, GraphQL, LDAP, deser, mass-assign, SSJI, JWT, DOM-XSS)`

### Task 3: Source/sink seeds for the 11 classes
**Files:** `shared/includes/pentest-source-sink-registry.md`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 2
**Execution routing:** default

- [ ] RED: extend `registry.test.sh` to assert each new `finding_type` has ≥1 language-tagged sink seed (e.g. XXE→`DocumentBuilderFactory`/`lxml.etree`; proto-pollution→recursive-merge into `__proto__`; LDAP→filter concat; deser→`pickle.loads`/`yaml.load`/`unserialize`/`ObjectInputStream`).
- [ ] GREEN: add seed rows, each tagged with its stack(s). Cite finding_type keys from Task 2 (IC-1), do not redefine classes.
- [ ] Verify: `bash tests/security-corpus/registry.test.sh`
  Expected: pass — every class has a sink seed
- [ ] Acceptance Proof:
  - AC1: Surface docs — Proof: grep sink seeds per class — Expected: ≥1 per class — Artifact: `zuvo/proofs/task-3-ac1-seeds.txt`
- [ ] Commit: `feat(pentest-registry): source/sink seeds for the 11 new vuln classes`

### Task 4: Safe-patterns for new classes
**Files:** `shared/includes/pentest-safe-pattern-registry.md`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 2
**Execution routing:** default

- [ ] RED: extend `registry.test.sh` to assert each new-class `safe_patterns` id referenced in Task 2 (`SP-XML-DISABLE-DTD`, `SP-JS-NULL-PROTO`, `SP-RE2`, `SP-GQL-INTROSPECT-OFF`, `SP-LDAP-ESCAPE`, `SP-DESER-ALLOWLIST`, `SP-DTO-ALLOWLIST`, `SP-NO-DYNAMIC-EVAL`, `SP-JWT-VERIFY-ALG`, `SP-DOM-SAFE-SINK`) resolves to a row here.
- [ ] GREEN: add the safe-pattern rows (the defended form that downgrades a raw sink match). Existing 65 rows unchanged.
- [ ] Verify: `bash tests/security-corpus/registry.test.sh`
  Expected: pass — every referenced SP id resolves
- [ ] Acceptance Proof:
  - AC2: Surface docs — Proof: grep each SP id — Expected: all resolve; clean-twin downgrade enabled — Artifact: `zuvo/proofs/task-4-ac2-safepatterns.txt`
- [ ] Commit: `feat(pentest-registry): safe-pattern downgrades for the 11 new vuln classes`

### Task 5: Validator — finding_type→CWE completeness + corpus↔registry 1:1
**Files:** `scripts/validate-pentest-output.sh`
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 1, Task 2
**Execution routing:** deep implementation tier

- [ ] RED: add cases to a `scripts/validate-pentest-output.test.sh`: (a) findings.json with a known finding_type but null/unknown CWE → `INVALID`; (b) a registry class with no corpus fixture → `INVALID` ("class X has no fixture"); (c) a well-formed payload → `PASS`.
- [ ] GREEN: extend the validator to cross-check every `findings[].type` against the registry CWE map, and assert a 1:1 between registry classes and `manifest.json` entries. Keep <100 lines added; reuse the existing python-in-heredoc block. **Add an emergency bypass (adversarial WARNING #6): `ZUVO_SKIP_PENTEST_VALIDATOR=1` short-circuits the new checks with a loud `[VALIDATOR BYPASSED]` stderr line, so a validator-environment edge case can never hard-block a pipeline with no escape hatch.**
- [ ] Verify: `bash scripts/validate-pentest-output.test.sh; echo rc=$?`
  Expected: `rc=0` (all three cases behave as asserted)
- [ ] Acceptance Proof:
  - G-VAL: Surface backend-logic — Proof: run the three test payloads — Expected: 2 INVALID, 1 PASS — Artifact: `zuvo/proofs/task-5-validator.txt`
- [ ] Commit: `feat(validate-pentest): enforce finding_type→CWE map + corpus↔registry 1:1`

### Task 6: Fixtures — 5 total-blind-spot classes
**Files:** `tests/security-corpus/{xxe,prototype_pollution,redos,graphql,ldap_injection}/{vulnerable,clean}/*` (fixtures), `tests/security-corpus/manifest.json`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 1, Task 2, Task 3
**Execution routing:** default
**Fixture count:** 10 vulnerable + 10 clean (excluded from 5-file boundary); 1 production-ish edit (manifest)

- [ ] RED: manifest entries for these 5 classes; `run.sh` over them must FAIL before fixtures exist (no finding) and PASS after (each vulnerable→finding, each clean→none).
- [ ] GREEN: minimal vulnerable sample + clean twin per class, each carrying a one-line exploit note (e.g. XXE: external-entity in `lxml.parse`; proto-pollution: `merge(req.body)` into `{}`; ReDoS: nested-quantifier regex on user input; GraphQL: introspection enabled + no depth limit; LDAP: filter string concat).
- [ ] Verify: `bash tests/security-corpus/run.sh --classes xxe,prototype_pollution,redos,graphql,ldap_injection; echo rc=$?`
  Expected: `rc=0`
- [ ] Acceptance Proof:
  - AC1: Surface integration — Proof: run pentest on each vulnerable fixture — Expected: mapped finding_type emitted (5/5) — Artifact: `zuvo/proofs/task-6-ac1.json`
  - AC2: Surface integration — Proof: run on each clean twin — Expected: 0 findings of that type — Artifact: `zuvo/proofs/task-6-ac2.json`
- [ ] Commit: `test(security-corpus): vulnerable+clean fixtures for XXE, proto-pollution, ReDoS, GraphQL, LDAP`

### Task 7: Fixtures — 5 detect-but-can't-classify classes
**Files:** `tests/security-corpus/{insecure_deserialization,mass_assignment,ssji,jwt_weak,xss_dom}/{vulnerable,clean}/*`, `tests/security-corpus/manifest.json`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 1, Task 2, Task 3, Task 6
**Execution routing:** default
**Fixture count:** 10 vulnerable + 10 clean; manifest edit (serialized after T6 — same file, rule 13)

- [ ] RED: manifest entries for the 5 classes; `run.sh` FAILs pre-fixture, PASSes post.
- [ ] GREEN: vulnerable + clean twin per class (deser: `pickle.loads(user)`; mass-assign: `User.create(req.body)` vs allowlist DTO; SSJI: `vm.runInContext(user)`; JWT: `jwt.decode(t, verify=False)` / `alg:none`; DOM-XSS: `el.innerHTML = location.hash`).
- [ ] Verify: `bash tests/security-corpus/run.sh --classes insecure_deserialization,mass_assignment,ssji,jwt_weak,xss_dom; echo rc=$?`
  Expected: `rc=0`
- [ ] Acceptance Proof:
  - AC1: Surface integration — Proof: pentest on each vulnerable fixture — Expected: 5/5 detected — Artifact: `zuvo/proofs/task-7-ac1.json`
  - AC2: Surface integration — Proof: each clean twin — Expected: 0 false positives — Artifact: `zuvo/proofs/task-7-ac2.json`
- [ ] Commit: `test(security-corpus): fixtures for deser, mass-assign, SSJI, JWT, DOM-XSS`

### Task 8: security-audit reads shared registry + invokes CodeSift trace
**Files:** `skills/security-audit/SKILL.md`
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 2, Task 3
**Execution routing:** deep implementation tier

- [ ] RED (spike first — de-risks the core uncertainty, rule 14): before rewriting S1/S2/S3, run a one-fixture spike that drives security-audit over the `trace_required:true` indirect-dataflow fixture and asserts the run log shows an actual `trace_call_chain` tool call. If the model won't invoke the tool from the registry seed, STOP and reshape (cheaper here than at T18). Then: post-change run calls `trace_call_chain`/`find_references` and reports the finding; a captured grep-only baseline does not; CodeSift-unavailable → `IC-4 DEGRADED` line (no false "dataflow" claim).
- [ ] GREEN: add the 3 registries to security-audit Mandatory File Loading; rewrite S1/S2/S3 to cite registry `finding_type`s and invoke the CodeSift trace tools seeded by registry sinks, replacing the inline grep+read-function lists. Preserve existing dimension gates.
- [ ] Verify (behavioral, not prompt-grep — adversarial CRITICAL #2): run `zuvo:security-audit` on the indirect-dataflow fixture and assert the captured run/tool log contains a real `trace_call_chain` invocation AND the finding is reported — `grep -q 'trace_call_chain' zuvo/proofs/task-8-runlog.txt && jq -e '.findings[]|select(.type=="sql_injection")' zuvo/proofs/task-8-ac3.json`
  Expected: exit 0 — the tool was actually called at runtime and the finding emitted (grepping the SKILL markdown is NOT sufficient evidence)
- [ ] Acceptance Proof:
  - AC3: Surface integration — Proof: run security-audit on the indirect-dataflow fixture (CodeSift present) and assert detection; absent → degraded line — Expected: detected w/ trace; explicit degrade w/o — Artifact: `zuvo/proofs/task-8-ac3.json`
- [ ] Commit: `feat(security-audit): read shared vuln registry + invoke CodeSift trace in S1/S2/S3`

### Task 9: gitleaks scans git history
**Files:** `skills/security-audit/SKILL.md`
**Surface:** config
**Complexity:** standard
**Dependencies:** Task 1, Task 8
**Execution routing:** default
**Note:** edits `security-audit/SKILL.md` — serialized after T8 (same file, rule 13).

- [ ] RED: a corpus git repo with a secret added in commit N, removed in N+1; assert S7 reports it WITH the historical commit; assert the invocation no longer contains `--no-git`.
- [ ] GREEN: change `gitleaks detect --source . --report-format json --no-git` → drop `--no-git`, add `--redact`; update the S7 narrative to state history is scanned.
- [ ] Verify: `grep -n 'gitleaks' skills/security-audit/SKILL.md | grep -v 'no-git' && ! grep -q 'no-git' <(grep gitleaks skills/security-audit/SKILL.md)`
  Expected: gitleaks present, `--no-git` absent
- [ ] Acceptance Proof:
  - AC4: Surface integration — Proof: run S7 on the committed-then-deleted-secret repo — Expected: historical secret found w/ commit ref — Artifact: `zuvo/proofs/task-9-ac4.json`
- [ ] Commit: `fix(security-audit): scan git history for secrets (drop gitleaks --no-git, add --redact)`

### Task 10: SCA in pentest + lockfile preflight
**Files:** `skills/pentest/SKILL.md`
**Surface:** config
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default

- [ ] RED: (a) an un-built fixture tree (no lockfile) → pentest emits `DEGRADED: SCA skipped — no resolved dependency tree`, NOT a false "0 vulns"; (b) a tree with a known-vuln pinned dep + lockfile → an SCA finding.
- [ ] GREEN: add an SCA step to pentest (npm/pip-audit) guarded by a lockfile/dependency-tree preflight (`package-lock.json|pnpm-lock.yaml|poetry.lock|requirements.txt`); absent → degraded line feeding IC-5, never IC-2.
- [ ] Verify: `grep -n 'pip-audit\|npm audit\|lockfile\|DEGRADED: SCA' skills/pentest/SKILL.md`
  Expected: SCA step + preflight present
- [ ] Acceptance Proof:
  - AC6 (SCA part): Surface integration — Proof: run on un-built then built fixture — Expected: degraded (no false 0); finding on built — Artifact: `zuvo/proofs/task-10-ac6-sca.json`
  - G-DD3: Surface integration — Proof: assert the SCA scanner ran with graceful degradation (degraded line on absence, real finding on presence) — Expected: graceful-degradation deliverable demonstrated — Artifact: `zuvo/proofs/task-10-gdd3.txt`
- [ ] Commit: `feat(pentest): SCA dimension with lockfile preflight + degraded labeling`

### Task 11: IaC/container scanners in security-audit S14
**Files:** `skills/security-audit/SKILL.md`
**Surface:** config
**Complexity:** complex
**Dependencies:** Task 9
**Execution routing:** deep implementation tier
**Note:** edits `security-audit/SKILL.md` — serialized after T9 (same file, rule 13).

- [ ] RED: (a) `checkov`/`tfsec`/`trivy`/`dockle` absent → explicit `DEGRADED: <tool> not installed` line, IC-5 class_coverage lowered, IC-2 surface gate UNAFFECTED; (b) tool present + a bad Dockerfile (root USER, unpinned base) → S14 finding.
- [ ] GREEN: add availability detection + invocation for the four scanners to S14 with IC-4 degraded labeling that feeds IC-5 only.
- [ ] Verify: `grep -n 'checkov\|tfsec\|trivy\|dockle\|DEGRADED' skills/security-audit/SKILL.md`
  Expected: four scanners wired with degraded labeling
- [ ] Acceptance Proof:
  - AC6: Surface integration — Proof: run S14 with scanners absent then present — Expected: degraded line + IC-2 unaffected; finding when present — Artifact: `zuvo/proofs/task-11-ac6-iac.json`
  - G-DD3: Surface integration — Proof: assert each of the 4 IaC/container scanners degrades gracefully (absence → labeled, presence → finding) — Expected: graceful-degradation deliverable demonstrated — Artifact: `zuvo/proofs/task-11-gdd3.txt`
- [ ] Commit: `feat(security-audit): wire checkov/tfsec/trivy/dockle into S14 with degraded labeling`

### Task 12: Java/Spring stack profile
**Files:** `shared/includes/pentest-stack-detection.md`, `shared/includes/pentest-stack-profiles.md`, `shared/includes/pentest-source-sink-registry.md`, `shared/includes/pentest-safe-pattern-registry.md`
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 2, Task 3, Task 4
**Execution routing:** deep implementation tier
**Note:** edits `source-sink-registry.md` + `safe-pattern-registry.md` — serialized after T3/T4 (same files, rule 13)

- [ ] RED: a Spring fixture with `@RequestMapping` source → JPA/JDBC string-concat sink; assert pentest detects SQLi via PT1 with the Spring profile ACTIVE (manifest `stack:java-spring`), not a generic-grep degraded note.
- [ ] GREEN: add Java/Spring detection signal (`pom.xml`/`build.gradle` + `org.springframework`), a stack-profiles entry, source seeds (`@RequestMapping`/`@PathVariable`/`@RequestParam`), sink seeds (JPA concat, `JdbcTemplate`, `Statement`), safe-pattern (`@PreAuthorize`, parameterized `?`).
- [ ] Verify: `grep -ric 'spring' shared/includes/pentest-stack-profiles.md shared/includes/pentest-source-sink-registry.md`
  Expected: Spring rows present in both
- [ ] Acceptance Proof:
  - AC5: Surface integration — Proof: run pentest on the Spring fixture — Expected: SQLi via PT1, profile active (no degrade note) — Artifact: `zuvo/proofs/task-12-ac5-spring.json`
- [ ] Commit: `feat(pentest-stack): Java/Spring profile — sources, sinks, @PreAuthorize safe-pattern`

### Task 13: Kotlin/Ktor stack profile
**Files:** `shared/includes/pentest-stack-detection.md`, `shared/includes/pentest-stack-profiles.md`, `shared/includes/pentest-source-sink-registry.md`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 12
**Execution routing:** default
**Note:** serialized after T12 (same registry files, rule 13). Kotlin CodeSift tools already wired in pentest SKILL — only the registry rows are missing.

- [ ] RED: a Kotlin/Ktor fixture (`call.receive()` source → raw SQL sink); assert profile active + finding (manifest `stack:kotlin-ktor`).
- [ ] GREEN: add Kotlin detection (`build.gradle.kts` + `io.ktor`), profile entry, source seeds (`call.receive`/`call.parameters`), sink seeds (Exposed raw SQL, JDBC).
- [ ] Verify: `grep -ric 'kotlin\|ktor' shared/includes/pentest-stack-profiles.md shared/includes/pentest-source-sink-registry.md`
  Expected: Kotlin rows present
- [ ] Acceptance Proof:
  - AC5: Surface integration — Proof: run pentest on the Kotlin fixture — Expected: profile active + finding — Artifact: `zuvo/proofs/task-13-ac5-kotlin.json`
- [ ] Commit: `feat(pentest-stack): Kotlin/Ktor profile (fills empty registries; tools already wired)`

### Task 14: GraphQL resolver model + serverless event sources
**Files:** `shared/includes/pentest-stack-detection.md`, `shared/includes/pentest-source-sink-registry.md`, `tests/security-corpus/graphql/*`
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 13
**Execution routing:** deep implementation tier
**Note:** serialized after T13 (same registry files). GraphQL fixture extends the corpus from T6.
**Split disposition (adversarial WARNING #5):** kept combined deliberately — GraphQL resolver sources and serverless event sources both add "new entry-point source models" to the SAME two files (`source-sink-registry.md`, `stack-detection.md`), so splitting them produces two same-file-serialized tasks (rule 13) with no parallelism gain and extra ordering overhead. They are inseparable by file, not bundled by convenience. If GraphQL hits edge-case complications at execute, split then — the serverless half has no dependents until T18.

- [ ] RED: a GraphQL fixture with introspection enabled + no depth limit → `graphql_introspection` + `graphql_depth_unbounded` findings; a serverless handler with `event.body`/`event.queryStringParameters` traced as a taint source to a sink.
- [ ] GREEN: add GraphQL detection (schema/`buildSchema`/`@Resolver`) with resolver-arg sources + introspection/depth sinks; add serverless event-source seeds (Lambda/CF Workers/Vercel `event.*`/`request` handlers).
- [ ] Verify: `grep -ric 'graphql\|resolver\|event.body\|queryStringParameters' shared/includes/pentest-source-sink-registry.md shared/includes/pentest-stack-detection.md`
  Expected: GraphQL + serverless seeds present
- [ ] Acceptance Proof:
  - AC1 (graphql): Surface integration — Proof: pentest on GraphQL fixture — Expected: introspection+depth findings — Artifact: `zuvo/proofs/task-14-ac1-graphql.json`
  - AC5: Surface integration — Proof: serverless handler source traced — Expected: event source → sink chain — Artifact: `zuvo/proofs/task-14-ac5-serverless.json`
- [ ] Commit: `feat(pentest-stack): GraphQL resolver model + serverless event-source seeds`

### Task 15: Cross-skill finding reconciliation (IC-3)
**Files:** `shared/includes/pentest-dedup-scoring.md`, `skills/pentest/SKILL.md`
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 2, Task 8, Task 10
**Execution routing:** deep implementation tier
**Note:** edits `pentest/SKILL.md` — serialized after T10 (same file, rule 13); also edits `dedup-scoring.md` (serialized before T16).

- [ ] RED: a fixture where pentest and security-audit both report the same `{cwe,file,sink}` issue; assert the merged output has ONE finding (higher confidence wins); assert two DISTINCT sources into the same sink stay TWO findings (key includes `source_symbol_or_entry_route`).
- [ ] GREEN: define the IC-3 canonical key `{cwe, file, sink_symbol, source_symbol_or_entry_route}` and the merge rule in `pentest-dedup-scoring.md`; reference it from pentest's `--from-audit` consumption path.
- [ ] Verify: `grep -n 'source_symbol_or_entry_route\|canonical key' shared/includes/pentest-dedup-scoring.md`
  Expected: IC-3 key documented with the source component
- [ ] Acceptance Proof:
  - G-DD5: Surface integration — Proof: run both skills on the dup fixture — Expected: 1 merged finding; distinct-source case stays 2 — Artifact: `zuvo/proofs/task-15-reconcile.json`
- [ ] Commit: `feat(security): cross-skill finding reconciliation via {cwe,file,sink,source} canonical key`

### Task 16: Coverage-gate parity in security-audit (IC-2 surface / IC-5 class)
**Files:** `skills/security-audit/SKILL.md`, `shared/includes/pentest-dedup-scoring.md`
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 11, Task 15
**Execution routing:** deep implementation tier
**Note:** edits `security-audit/SKILL.md` (after T11) + `dedup-scoring.md` (after T15) — both serialized, rule 13.

- [ ] RED: (a) a multi-route fixture enumerated <90% of entry points → `VERDICT=INCOMPLETE`, grade capped FAIL (IC-2); (b) a run at 100% entry-point enumeration but with missing scanners → NOT incomplete, only IC-5 `class_coverage` lowered.
- [ ] GREEN: port the IC-2 surface-coverage gate to security-audit (denominator = entry points only); add the IC-5 `class_coverage` advisory metric to its summary; wire IC-4 degraded tools into IC-5, never IC-2.
- [ ] Verify: `grep -n 'surface_coverage\|class_coverage\|VERDICT=INCOMPLETE\|coverage_gate' skills/security-audit/SKILL.md`
  Expected: both metrics + the gate present
- [ ] Acceptance Proof:
  - AC7: Surface integration — Proof: under-enumerated-surface run — Expected: INCOMPLETE/FAIL — Artifact: `zuvo/proofs/task-16-ac7.json`
  - AC6: Surface integration — Proof: full-surface + missing-tools run — Expected: NOT incomplete, IC-5 lowered — Artifact: `zuvo/proofs/task-16-ac6.json`
- [ ] Commit: `feat(security-audit): coverage-gate parity — IC-2 surface gate vs IC-5 class advisory`

### Task 17: `--strict-v2` flag + warning-only grace for new classes
**Files:** `skills/security-audit/SKILL.md`, `skills/pentest/SKILL.md`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 2, Task 8, Task 15, Task 16
**Execution routing:** default
**Note:** edits `security-audit/SKILL.md` (after T16) + `pentest/SKILL.md` (after T15) — both serialized, rule 13.

- [ ] RED: (a) default run on a fixture with a new-class HIGH → the new class is reported but NOT counted in the HIGH/CRITICAL gate total (warning-only); (b) `--strict-v2` → it IS counted.
- [ ] GREEN: add `--strict-v2` flag parsing + a "new classes warning-only for one minor release" rule to both skills' argument tables and scoring; document the grace window.
- [ ] Verify: `grep -n 'strict-v2\|warning-only' skills/security-audit/SKILL.md skills/pentest/SKILL.md`
  Expected: flag + grace rule in both
- [ ] Acceptance Proof:
  - G-BC: Surface integration — Proof: default vs `--strict-v2` on a new-class fixture — Expected: warning-only by default, gated under flag — Artifact: `zuvo/proofs/task-17-bc.json`
- [ ] Commit: `feat(security): --strict-v2 flag + one-release warning-only grace for new vuln classes`

### Task 18: Whole-feature smoke runner (coverage benchmark)
**Files:** `tests/security-corpus/smoke-coverage-benchmark.sh`, `zuvo/proofs/.gitkeep`
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 1, Task 5, Task 6, Task 7, Task 8, Task 9, Task 10, Task 11, Task 12, Task 13, Task 14, Task 15, Task 16, Task 17
**Execution routing:** deep implementation tier

- [ ] RED: the smoke script runs `zuvo:security-audit` then `zuvo:pentest --from-audit` over the FULL corpus, collects the union of findings, diffs against the planted-vuln manifest; assert every planted vuln detected by ≥1 skill, each appears ONCE after IC-3 reconciliation, surface gate PASS (full enumeration), and the post-vs-baseline true-positive class count is ≥10 with zero regressions.
- [ ] GREEN: author `smoke-coverage-benchmark.sh` that drives both skills, reconciles, and computes the TP/FP deltas vs a captured baseline.
- [ ] Verify: `bash tests/security-corpus/smoke-coverage-benchmark.sh; echo rc=$?`
  Expected: `rc=0` — manifest fully covered, reconciled, ≥10 net-new classes, 0 regressions, FP non-increasing
- [ ] Acceptance Proof:
  - SMOKE1: Surface integration — Proof: full-corpus E2E benchmark — Expected: every planted vuln found once; surface gate PASS — Artifact: `zuvo/proofs/smoke-coverage-benchmark.json`
  - AC-S1: Surface integration — Proof: TP class count post vs baseline — Expected: ≥10 net-new, 0 regressions — Artifact: `zuvo/reports/sec-coverage-benchmark.md`
  - AC-S2: Surface integration — Proof: clean-twin FP count post ≤ baseline — Expected: non-increasing — Artifact: `zuvo/reports/sec-fp-rate.md`
- [ ] Commit: `test(security-corpus): whole-feature coverage benchmark smoke runner`

## Whole-feature Smoke Proofs

- **SMOKE1 — End-to-end coverage benchmark across both skills on the reference corpus.**
  - Preconditions: `tests/security-corpus/` built (T1, T6, T7, T14); scanners installed; both skills installed via `./scripts/install.sh`.
  - Proof: `bash tests/security-corpus/smoke-coverage-benchmark.sh` — runs `zuvo:security-audit` then `zuvo:pentest --from-audit` on the full corpus; collects union of findings; diffs against the planted-vuln manifest.
  - Expected: every planted vuln detected by ≥1 skill; IC-3 reconciliation merges duplicates so each appears once; surface gate PASS only because the full surface was enumerated.
  - Artifact: `zuvo/proofs/smoke-coverage-benchmark.json`
  - Authored by: Task 18. Mapped RED sub-suite: Task 18 RED (full mocked E2E exercise).
