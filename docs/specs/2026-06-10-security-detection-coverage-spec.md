# Security Detection Coverage — Maximizing pentest + security-audit Findings — Design Specification

> **spec_id:** 2026-06-10-security-detection-coverage-0457
> **topic:** Improve zuvo:pentest + zuvo:security-audit to detect maximally many security problems
> **status:** Approved
> **created_at:** 2026-06-10T04:57:11Z
> **reviewed_at:** 2026-06-10T05:03:00Z
> **approved_at:** 2026-06-10T05:08:00Z
> **approval_mode:** interactive
> **adversarial_review:** partial (1/3 providers — gemini; codex-5.3 empty, host claude auto-excluded)
> **author:** zuvo:brainstorm

## Problem Statement

The two security skills — `zuvo:pentest` (white/black-box, source-to-sink, PT1–PT8) and `zuvo:security-audit` (static posture, S1–S15) — leave detectable, high-severity vulnerability classes undetected, detect the **same** class at **two different depths** depending on which skill runs, and never reconcile findings with each other. The user's goal: maximize the number of real security problems these skills catch.

**Who is affected:** every repo run through either skill — most acutely the QuotasMobi pentest (this session) that emitted a falsely-complete report after the 7-agent dispatch rate-limited and the inline fallback narrowed to high-signal sinks (`~/.zuvo/retros.md`, 2026-06-09 pentest entry; fixed in coverage-gate commit `5814c2d`).

**What happens if we do nothing:** whole vulnerability classes (XXE, prototype pollution, ReDoS, GraphQL-specific, LDAP injection) remain total blind spots; classes that are *seen but not classified* (insecure deserialization, mass assignment, SSJI, JWT flaws, DOM-XSS) keep surfacing as un-actionable grep noise; Java/Spring and Kotlin codebases silently degrade to generic grep because their pentest registries are empty; and secrets deleted from the working tree but live in git history are never found (gitleaks runs `--no-git`).

> **Evidence provenance.** Phase-1 dispatched 3 explorers. The **Capability Cartographer** completed (full capability map, cited to file:line — the backbone of this spec). The **External Best-Practice Researcher** and **Evidence Miner** both died on an API rate-limit storm (0 output). Per `env-compat.md` (rate-limit ×2 → inline) those two streams were completed inline: best-practice from author knowledge (OWASP ASVS, CWE Top 25, Semgrep/CodeQL dataflow categories), and evidence from retro/runlog greps already pulled this session. **Status: Draft (incomplete — external best-practice and evidence streams are inline, not independently agent-verified).** Claims sourced to author knowledge are marked `[inline]`; claims sourced to the Cartographer are cited to file:line.

## Design Decisions

### DD-1 — Shared detection substrate over per-skill patching *(recommended, chosen)*

The two skills duplicate ~10 vulnerability classes (SQLi, XSS, SSRF, IDOR, auth, business-logic, secrets, headers, file-upload, deser) at different depths and **never cross-reference** (Cartographer §3: "the two skills never cross-reference each other's findings — a pentest HIGH and a security-audit MEDIUM for the same canonical issue won't dedup"). Rather than add missing classes to each skill independently (duplicating effort and depth divergence), make both skills consume **one shared vulnerability-class substrate**: the existing `pentest-finding-registry.md` + `pentest-source-sink-registry.md` + `pentest-safe-pattern-registry.md`, generalized so `security-audit` reads them too. Every new class added to the registry is then instantly available to BOTH skills at the SAME depth.

- **Why:** highest leverage — fixes the method-quality gap and the blind-spots in one place. Adding XXE once gives both skills XXE. **Crucially, the depth gain is not "markdown makes the LLM a dataflow engine"** (adversarial CRITICAL #3): security-audit's S1/S2/S3 currently stop at grep + read-the-surrounding-function, while pentest's PT1/PT2/PT5 *invoke CodeSift `trace_call_chain` + `find_references`* — real index-backed tools — seeded by the registry's sink list. The shared substrate's job is to make security-audit **invoke those same CodeSift trace tools**, seeded by the same sinks. The depth comes from running the tools pentest already runs, not from reading registry text. Where CodeSift is unavailable, both skills degrade identically to grep+read-function and say so (IC-4).
- **Trade-off:** larger blast radius (touches both skills' loading + a shared schema). Mitigated by phasing (registry first, consumers second) and the fixture corpus (DD-4) catching regressions.
- **Alternatives:** (B) patch each skill independently — rejected: perpetuates depth divergence and double maintenance. (C) merge the two skills into one — rejected: they have legitimately different modes (exploit verification vs static posture/compliance) and different gates; the user wants both improved, not one deleted.

### DD-2 — Fill blind spots as first-class finding_types, not grep seeds

Total blind spots (XXE, prototype pollution, ReDoS, GraphQL, LDAP injection) and "detect-but-can't-classify" classes (insecure deserialization → CWE-502, mass assignment → CWE-915, SSJI, JWT flaws → CWE-347/345, DOM-XSS → CWE-79) each get: a `finding_type` + CWE + `probe_template_id` in the finding registry, source/sink seeds in the source-sink registry, and where applicable a safe-pattern for downgrade. Grep-only detection (no `finding_type`) is the root cause of un-actionable noise (Cartographer §5).

### DD-3 — Real scanners with graceful degradation, not agent eyeballing

Three tooling gaps depend on the agent visually inspecting instead of running a scanner (Cartographer §5/§"Tooling gap"):
- **Secrets in git history:** drop `--no-git` from the gitleaks invocation (`security-audit/SKILL.md:280`) so committed-then-deleted secrets are found. Add `--redact`.
- **SCA in pentest:** pentest has no SCA outside the CMS overlay; a non-CMS app run through `zuvo:pentest` alone never gets `npm audit`/`pip-audit`. Add an SCA step (or a hard cross-skill handoff that fails the coverage gate if SCA never ran).
- **IaC / container misconfig:** wire `checkov` / `tfsec` / `trivy` / `dockle` into security-audit S14 with availability detection and explicit degraded-mode labeling (per `preflight-missing-tools` memory — warn loudly, never silently skip).

### DD-4 — A vulnerable-fixture regression corpus is the proof of "detects more"

"Maximize detection" is only verifiable against ground truth. Build `tests/security-corpus/` — one minimal intentionally-vulnerable sample per class (and a clean twin per class for false-positive control). The acceptance proof runs the skill against the corpus and asserts each planted vuln is found and each clean twin is not flagged. This is the deterministic contract that every coverage addition must pass and that prevents future regressions. `[inline: standard SAST benchmark practice — cf. OWASP Benchmark, Semgrep test fixtures]`

### DD-5 — Cross-skill finding reconciliation via the existing severity vocabulary

`severity-vocabulary.md:42-48` already maps pentest's 0–100 onto sec-audit's HIGH/MEDIUM/LOW, but nothing uses it across skills. Define a shared canonical-key (reuse pentest's canonical-key dedup) so that when both skills run (e.g. via the audit→pentest chain), findings for the same `{cwe, file, sink}` merge into one, taking the higher confidence. Prevents double-reporting and surfaces the strongest evidence.

### DD-6 — Coverage-gate parity

The pentest coverage gate (commit `5814c2d`: enumerate the full attack surface or VERDICT=INCOMPLETE) has no equivalent in security-audit, which gates per-dimension but never on "did we enumerate every entry point." Port the same hard attack-surface-enumeration gate to security-audit so it cannot emit a passing grade over an un-enumerated surface either. This also closes the systemic theme behind the whole session (`[inline]`: refactor coverage-gate `7562899`, pentest `5814c2d`, plan Phase-1 rate-limit retro — "skills silently degrade under rate-limit and claim completion").

## Solution Overview

A **shared vulnerability-class substrate** (registries) consumed by both skills, expanded to cover today's blind spots, backed by **real scanners** for the three tooling gaps, proven by a **vulnerable-fixture corpus**, and protected by **coverage-gate parity** so neither skill can claim completion over an un-enumerated surface. Cross-skill **reconciliation** merges duplicate findings.

Delivered in 5 sequenced phases (P1 highest leverage first):

```
P1 Registry expansion + fixture corpus   → fills blind spots, proves detection (DD-2, DD-4)
P2 security-audit reads shared registry   → ends depth divergence (DD-1)
P3 Real scanners (git-history, SCA, IaC)  → ends agent-eyeballing gaps (DD-3)
P4 Stack profiles (Java/Spring, Kotlin,   → ends silent degradation (Cartographer §6)
   GraphQL resolver model, serverless)
P5 Cross-skill reconciliation + coverage  → dedup + completion integrity (DD-5, DD-6)
   gate parity
```

Each phase is independently shippable and independently proven by the corpus.

## Detailed Design

### Data Model

**Shared finding-class registry entry** (extends existing `pentest-finding-registry.md` row schema; new rows):

| finding_type | cwe | owasp | probe_template_id | default_severity | safe_patterns |
|--------------|-----|-------|-------------------|------------------|---------------|
| `xxe` | CWE-611 | A05:2021 | probe-xxe-entity | HIGH | `SP-XML-DISABLE-DTD` |
| `prototype_pollution` | CWE-1321 | A08:2021 | probe-proto-merge | HIGH | `SP-JS-NULL-PROTO`, `SP-JS-FREEZE` |
| `redos` | CWE-1333 | — | probe-redos-backtrack | MEDIUM | `SP-RE-LINEAR`, `SP-RE2` |
| `graphql_introspection` | CWE-200 | A05:2021 | probe-gql-introspect | MEDIUM | `SP-GQL-INTROSPECT-OFF` |
| `graphql_depth_unbounded` | CWE-770 | A05:2021 | probe-gql-depth | MEDIUM | `SP-GQL-DEPTH-LIMIT` |
| `ldap_injection` | CWE-90 | A03:2021 | probe-ldap-filter | HIGH | `SP-LDAP-ESCAPE` |
| `insecure_deserialization` | CWE-502 | A08:2021 | probe-deser | CRITICAL | `SP-DESER-ALLOWLIST` |
| `mass_assignment` | CWE-915 | A08:2021 | probe-mass-assign | HIGH | `SP-RUBY-STRONG-PARAMS`, `SP-DTO-ALLOWLIST` |
| `ssji` | CWE-94 | A03:2021 | probe-ssji-vm | HIGH | `SP-NO-DYNAMIC-EVAL` |
| `jwt_weak` | CWE-347 / CWE-345 | A02:2021 | probe-jwt-verify | HIGH | `SP-JWT-VERIFY-ALG` |
| `xss_dom` | CWE-79 | A03:2021 | probe-dom-xss | MEDIUM | `SP-DOM-SAFE-SINK` |

**Source/sink seeds** added to `pentest-source-sink-registry.md` for each (e.g. XXE sinks: `DocumentBuilderFactory`, `SAXParser`, `lxml.etree` w/o `resolve_entities=False`, `libxml_disable_entity_loader`; proto-pollution sinks: recursive `merge`/`extend`/`Object.assign` into `__proto__`/`constructor`; LDAP sinks: `ldap.search`/filter concatenation; deser sinks per language: `pickle.loads`, `yaml.load`, `Marshal.load`, `unserialize`, `ObjectInputStream`, `JsonConvert.DeserializeObject<object>`).

### API Surface

No code APIs (markdown skills). The "interface" is the registry row schema (above) and the skill→registry loading contract: `security-audit/SKILL.md` Mandatory File Loading gains the three pentest registries; its S1/S2/S3 detection phases cite registry `finding_type`s instead of inline grep lists.

### Integration Points

- `shared/includes/pentest-finding-registry.md`, `pentest-source-sink-registry.md`, `pentest-safe-pattern-registry.md` — new rows (P1).
- `shared/includes/pentest-stack-profiles.md` + `pentest-stack-detection.md` — Java/Spring, Kotlin/Ktor, GraphQL, serverless profiles (P4).
- `skills/security-audit/SKILL.md` — load shared registries (P2); drop gitleaks `--no-git` and add IaC scanners (P3); coverage-gate parity (P5).
- `skills/pentest/SKILL.md` — add SCA step (P3); cross-skill reconciliation note (P5).
- `scripts/validate-pentest-output.sh` — already enforces coverage gate (`5814c2d`); extend to validate new finding_type→CWE mapping completeness (P1).
- `tests/security-corpus/` — new fixture corpus + a runner script (P1).
- Docs/counters: `rules/security.md` threat table, `docs/skills.md`, plugin.json counts if dimension labels change.

### Interaction Contract

This feature changes how the security skills **classify and gate** findings (a cross-cutting behavioral change), so the contract is defined:
- **Target surfaces:** finding classification (new `finding_type`s), detection depth (sec-audit grep → registry dataflow), completion gating (coverage-gate parity).
- **Protected surfaces:** existing pentest PT1–PT8 behavior and gates MUST NOT regress; existing finding_types keep their CWE/severity; the pentest coverage gate from `5814c2d` is unchanged.
- **Override order:** a class-specific safe-pattern downgrade still wins over a raw sink match (existing pentest semantics), applied identically in both skills.
- **Validation signal:** the fixture corpus (DD-4) — every new class detected on the vulnerable twin, none flagged on the clean twin.
- **Rollback boundary:** per-phase; reverting a phase's commits removes its registry rows / scanner calls without touching prior phases.

### Integration Contract

- **IC-1** — Shared registry path: the three files under `shared/includes/pentest-*registry.md` are the single source of vulnerability-class truth; both skills cite `finding_type` keys from IC-1, never re-define classes inline.
- **IC-2** — **Surface** coverage gate (structural): `surface_gate = PASS` only when `surface_coverage_pct ≥ 0.90` AND every un-enumerated entry point carries a reason_code, where the denominator is **attack-surface entry points only** (routes/handlers/actions/sinks reachable from the scope inventory) — NOT vulnerability classes and NOT tool availability. Per `5814c2d` / `pentest-dedup-scoring.md`. Security-audit's ported gate (P5) cites IC-2 verbatim. *(Adversarial CRITICAL #1/#2: the gate denominator is purely structural; missing tools and unmodeled classes must NOT enter it, or fresh environments would deterministically fail.)*
- **IC-3** — Severity reconciliation: cross-skill merge uses `severity-vocabulary.md:42-48` mapping; canonical key = `{cwe, file, sink_symbol, source_symbol_or_entry_route}`. The source/entry component is mandatory so two distinct user inputs reaching the same sink in one file remain **two** findings, not one. All reconciliation references cite IC-3. *(Adversarial WARNING #4.)*
- **IC-4** — Degraded-tool labeling (advisory, NOT a gate input): any scanner (gitleaks/checkov/tfsec/trivy/dockle/npm-audit/pip-audit) that is absent emits an explicit `DEGRADED: <tool> not installed — <class> coverage reduced` line and lowers **IC-5 class_coverage** only. It does **NOT** count against IC-2's surface gate and never fails the run by itself. Silent skipping remains forbidden.
- **IC-5** — **Class** coverage (advisory metric, never a hard gate): `class_coverage` = fraction of in-scope vulnerability classes actually checked (reduced by IC-4 degraded tools and by stacks with no profile). Reported in the summary and the report body so the user sees what was *not* checked, but it does not block a passing grade — only IC-2's structural surface gate does. This is the clean separation the adversarial review demanded: enumerate-your-surface is a blocker; tool/class breadth is a disclosed-quality signal.

### Edge Cases

| Edge case | Handling |
|-----------|----------|
| New finding_type lacks a probe template | Allowed for static-only classes (e.g. `redos`); `probe_template_id` may be `static-only`, but a CWE is mandatory — validator (P1) rejects a row with null CWE. |
| Language has no sink primitive for a class (e.g. prototype pollution in Python) | Registry seeds are language-tagged; class is `status=excluded` with reason `no_sink_primitives` for that stack — affects IC-5 class_coverage only (documented), never the IC-2 surface gate. |
| A class is both seen by pentest trace and sec-audit | IC-3 reconciliation merges to one finding, higher confidence wins. |
| Clean-twin fixture trips a finding (false positive) | Corpus runner FAILs the phase — false positives are a release blocker, not just false negatives. |
| Stack with no profile after P4 (e.g. Elixir) | Generic grep fallback, explicitly labeled `DEGRADED: no stack profile for <stack>`; lowers IC-5 class_coverage, does not fail IC-2 surface gate. |

### Failure Modes

#### Shared registry (consumed by both skills)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| Registry row has CWE typo / unknown CWE | validator (P1) cross-checks against CWE allowlist | classification of that class in both skills | finding shows wrong/blank CWE | validator fails CI before merge | none — caught pre-merge | immediate |
| security-audit loads registry but a row's stack tag missing | corpus run on that stack misses the class | one class on one stack | false negative on corpus | corpus FAIL blocks phase | none | immediate (corpus) |
| Registry grows large → token cost in skill load | context-metrics trend | both skills' load time | slower skill start | lazy-load registries per detected stack (existing pattern) | none | gradual |

#### Real scanners (gitleaks history / SCA / IaC)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| Scanner not installed | `which <tool>` preflight | that class's IC-5 class_coverage | `DEGRADED: <tool> not installed` line; IC-5 lowered, IC-2 surface gate unaffected | install tool, re-run | none | immediate |
| **SCA run on un-built tree (no lockfile / no node_modules / no venv)** (adversarial WARNING #6) | preflight asserts lockfile present (`package-lock.json`/`pnpm-lock.yaml`/`poetry.lock`/`requirements.txt`) before invoking npm/pip-audit | SCA class only | `DEGRADED: SCA skipped — no resolved dependency tree (lockfile absent)` | user installs deps / commits lockfile | none — no false "0 vulns" | immediate |
| gitleaks history scan slow on huge repo | wall-clock > threshold | secrets dimension only | long S7 phase | `--max-target-megabytes` cap + note | none | during run |
| IaC scanner emits different JSON schema across versions | parse error caught | S14 only | S14 falls back to checklist | pin recommended version in docs; degrade to manual | none | immediate |

#### Fixture corpus runner

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| Corpus fixture itself is not actually vulnerable | peer review + the skill reporting "no finding" on a "vulnerable" twin | one class's proof validity | phase appears to pass falsely | require each fixture to carry a one-line exploit note reviewed at add time | none | review-time |
| Skill flags clean twin (false positive) | corpus runner diff | that class | phase FAIL | tighten safe-pattern / sink specificity | none | immediate |
| Corpus drifts from registry (class added w/o fixture) | runner asserts 1:1 registry↔fixture coverage | completeness | runner FAIL: "class X has no fixture" | add fixture | none | immediate |

### Acceptance Criteria

**Ship criteria** (must pass for release — deterministic):

- **AC1 — Every new vulnerability class in DD-2 is detected on its vulnerable fixture.**
  - Surface: `docs` (skill markdown) → verified via `integration` (run skill on corpus)
  - Proof: run `zuvo:pentest tests/security-corpus/<class>/vulnerable/` for each new class; assert a finding with the mapped `finding_type` + CWE is emitted.
  - Expected: 11/11 new classes (xxe, prototype_pollution, redos, graphql_introspection, graphql_depth_unbounded, ldap_injection, insecure_deserialization, mass_assignment, ssji, jwt_weak, xss_dom) detected.
  - Artifact: `zuvo/proofs/ac1-new-class-detection.json`

- **AC2 — No new class fires on its clean twin (false-positive control).**
  - Surface: `integration`
  - Proof: run the skill on `tests/security-corpus/<class>/clean/`; assert NO finding of that `finding_type`.
  - Expected: 0 false positives across all clean twins.
  - Artifact: `zuvo/proofs/ac2-clean-twin.json`

- **AC3 — security-audit invokes CodeSift trace tools (registry-seeded source-to-sink), not grep-only — and detects an indirect-dataflow fixture pentest already catches.**
  - Surface: `integration`
  - Proof: on a fixture where the sink is reached through an indirect call chain (sink token not adjacent to the source), assert security-audit (post-P2) calls `trace_call_chain`/`find_references` and reports the finding; assert the pre-P2 grep baseline did not. With CodeSift unavailable, assert security-audit emits the IC-4 degraded line instead of a false claim.
  - Expected: indirect-dataflow fixture detected by security-audit after P2 when CodeSift present; explicit degrade when absent. *(No "dataflow by markdown" claim — capability is gated on the real tool being callable.)*
  - Artifact: `zuvo/proofs/ac3-trace-depth.json`

- **AC4 — gitleaks scans git history (a secret committed-then-deleted is found).**
  - Surface: `integration`
  - Proof: corpus repo with a secret added in commit N and removed in commit N+1; run security-audit S7; assert the secret is reported with its historical commit.
  - Expected: historical secret found; `--no-git` absent from the invocation.
  - Artifact: `zuvo/proofs/ac4-git-history-secret.json`

- **AC5 — Java/Spring and Kotlin codebases get source/sink seeds, not generic grep.**
  - Surface: `integration`
  - Proof: run pentest on a Spring fixture with a `@RequestMapping` source → JPA concat sink; assert SQLi found via PT1 with the Spring profile loaded (not a generic-grep degraded note).
  - Expected: Spring + Kotlin fixtures detected with stack profile active.
  - Artifact: `zuvo/proofs/ac5-stack-profile.json`

- **AC6 — Missing scanners degrade loudly (advisory), and do NOT by themselves fail the run.**
  - Surface: `integration`
  - Proof: run security-audit with `checkov`/`gitleaks` absent from PATH; assert an explicit `DEGRADED: <tool> not installed` line per IC-4, that `class_coverage` (IC-5) drops, and that `surface_gate` (IC-2) is **unaffected** — a fresh environment with no IaC tools still produces a valid (non-INCOMPLETE) run.
  - Expected: degraded lines present; IC-5 reflects the gap; IC-2 gate not failed by tool absence. *(Adversarial CRITICAL #2.)*
  - Artifact: `zuvo/proofs/ac6-degraded-labeling.json`

- **AC7 — security-audit cannot emit a passing grade over an un-enumerated attack SURFACE (coverage-gate parity).**
  - Surface: `integration`
  - Proof: run security-audit on a multi-route fixture but constrain it to enumerate < 90% of **entry points**; assert VERDICT=INCOMPLETE and grade capped at FAIL (IC-2). Separately assert that a run covering 100% of entry points but with missing scanners is NOT marked INCOMPLETE (only IC-5 lowered).
  - Expected: INCOMPLETE on under-enumerated surface (mirrors pentest `5814c2d`); NOT incomplete merely from missing tools.
  - Artifact: `zuvo/proofs/ac7-coverage-parity.json`

**Success criteria** (value validation — measurable):

- **AC-S1 — Net new true positives on a held-out vulnerable app.**
  - Surface: `integration`
  - Proof: run both skills before vs after all phases on a fixed vulnerable reference app (e.g. OWASP Juice Shop / DVWA-style corpus); count distinct true-positive classes.
  - Expected: ≥ 10 additional distinct vulnerability classes detected post-change vs baseline; **zero regressions** (every class found before is still found).
  - Artifact: `zuvo/reports/sec-coverage-benchmark.md`

- **AC-S2 — False-positive rate does not increase.**
  - Surface: `integration`
  - Proof: clean-twin corpus FP count after ≤ FP count before.
  - Expected: FP rate non-increasing.
  - Artifact: `zuvo/reports/sec-fp-rate.md`

## Whole-feature Smoke Proofs

- **SMOKE1 — End-to-end coverage benchmark across both skills on the reference corpus.**
  - Preconditions: `tests/security-corpus/` built; scanners installed; both skills installed via `./scripts/install.sh`.
  - Proof: run `zuvo:security-audit` then `zuvo:pentest --from-audit` on the full corpus; collect the union of findings; diff against the planted-vuln manifest.
  - Expected: every planted vuln in the manifest detected by at least one skill; cross-skill reconciliation (IC-3) merges duplicates so each planted vuln appears once; coverage gate PASS only because the full surface was enumerated.
  - Artifact: `zuvo/proofs/smoke-coverage-benchmark.json`

## Validation Methodology

Runners: the two skills themselves (invoked on fixtures), `jq` for findings.json assertions, a `tests/security-corpus/run.sh` harness that maps each fixture to its expected `finding_type`. Prerequisites: scanners (`gitleaks`, `npm`/`pip-audit`, `checkov`/`tfsec`/`trivy`/`dockle`) installed for non-degraded runs; the corpus fixtures; `./scripts/install.sh` so the edited skills load. The corpus + harness is itself a P1 deliverable (validation tooling is a prerequisite, not a byproduct).

## Rollback Strategy

Per-phase git revert. Each phase = its own commit(s); reverting removes that phase's registry rows / scanner calls / profiles without affecting earlier phases. Kill switch: the shared registry is loaded by reference — reverting `security-audit/SKILL.md`'s load lines returns it to inline grep behavior while leaving pentest untouched. No persistent state, no migration; the only "data" is markdown + fixtures.

## Backward Compatibility

- Existing pentest finding_types, CWEs, severities, and the `5814c2d` coverage gate are unchanged (Interaction Contract "protected surfaces").
- New `finding_type`s are additive — older findings.json consumers ignore unknown types.
- security-audit's switch to registry-seeded CodeSift tracing (P2) may **increase** finding counts on the same repo; this is intended (more detection). **Mitigation for CI/CD gates (adversarial WARNING #5):** the new vulnerability classes (DD-2) ship **warning-only for one minor release** — reported but not counted toward the HIGH/CRITICAL gate total unless `--strict-v2` is passed — so users with "zero HIGH" CI gates are not broken on update. The grace window and the flag are documented in `release-docs`. After one release the classes graduate to full gate weight.
- `validate-pentest-output.sh` schema stays backward compatible (new fields optional until P1 lands the validator update).

## Out of Scope

### Deferred to v2
- Full DAST/runtime exploitation beyond pentest's existing `--verify-live` (request smuggling, cache poisoning, OAuth flow fuzzing) — needs a live target harness.
- Memory-safety classes (C/C++ buffer overflow, use-after-free) — different analysis paradigm.
- A unified single security skill (DD-1 alternative C) — the two-skill split is retained.

### Permanently out of scope
- Bundling/shipping the scanners themselves — they remain optional external tools with degraded-mode fallback (IC-4).
- Cloud-account live scanning (AWS/GCP API enumeration) — out of a code-analysis skill's remit.

## Open Questions

- **OQ-1** (owned by `zuvo:plan`): exact reference app for AC-S1 — bundle a small in-repo corpus vs depend on an external vulnerable app (Juice Shop)? In-repo is deterministic and offline; external is more realistic. Recommend in-repo corpus.
- **OQ-2** (inline-stream gap): the External Best-Practice and Evidence agents rate-limited; re-run them when quota recovers to confirm no high-value class is missing from DD-2 (e.g. HTTP request smuggling, CORS-with-credentials, OAuth PKCE downgrade). Does not block P1.
- **OQ-3:** phase ordering — is P4 (stack profiles) higher priority than P3 (scanners) for your actual repos? If your targets are Java/Spring-heavy, swap P3↔P4.

## Adversarial Review

Ran `adversarial-review --mode spec --single` 2026-06-10T05:02:51Z. Host `claude` auto-excluded (self-review prevention); `codex-5.3` returned empty; **gemini** returned a full verdict → `status: partial` (1/3 providers). External CLI was the resilient independent check during an Anthropic-side rate-limit storm that killed 2 of 3 Phase-1 agents.

**3 CRITICAL — all fixed in this revision:**
1. *Coverage metric corruption* — IC-2 (attack-surface routes) and IC-4 (missing scanners) mixed denominators, making the 90% gate meaningless. **Fixed:** split into IC-2 `surface_coverage` (structural, gating) vs IC-5 `class_coverage` (advisory, non-gating).
2. *Missing tools permanently fail the gate* — fresh environments without checkov/trivy would deterministically fail ≥0.90. **Fixed:** IC-4 now feeds IC-5 only; AC6/AC7 assert tool absence never marks a run INCOMPLETE.
3. *Hallucinated dataflow capability* — AC3/DD-1 implied reading markdown gives an LLM a dataflow engine. **Fixed:** depth gain re-attributed to *invoking CodeSift `trace_call_chain`/`find_references`* (real index-backed tools pentest already uses); explicit grep-degrade when CodeSift absent.

**3 WARNING — all resolved:**
4. *Over-aggressive dedup* — `{cwe,file,sink}` would merge distinct sources. **Fixed:** IC-3 key now includes `source_symbol_or_entry_route`.
5. *CI/CD breakage from new HIGHs* — **Fixed:** new classes ship warning-only for one minor release unless `--strict-v2`; documented in release-docs.
6. *SCA needs a built tree* — **Fixed:** Failure Modes adds a lockfile/dependency-tree preflight; degrades instead of emitting false "0 vulns".

**Residual / not re-run:** pass 2 not executed (rate-limit storm; the 3 CRITICALs were first-pass design flaws with unambiguous fixes, and a self-consistency sweep reconciled all coverage references to the IC-2/IC-5 split). OQ-2 still holds: the External-Best-Practice and Evidence agent streams were inline, not independently verified — re-run when quota recovers to confirm no high-value class (HTTP request smuggling, CORS-with-credentials, OAuth PKCE) is missing from DD-2. This is why status is **Reviewed**, not auto-approved.
