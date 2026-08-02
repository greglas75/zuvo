# zuvo:container-audit — Design Specification

> **spec_id:** 2026-08-02-container-audit-1204
> **topic:** container-audit skill (static Docker/compose/image security audit)
> **status:** Approved
> **created_at:** 2026-08-02T12:04:59Z
> **reviewed_at:** 2026-08-02T12:04:59Z
> **approved_at:** 2026-08-02T13:17:39Z
> **approval_mode:** interactive
> **adversarial_review:** partial (3/5 providers — warnings resolved in-spec)
> **author:** zuvo:brainstorm

## Problem Statement

~27 of the user's 64 repos ship Docker (`tgm-survey-platform`, `QuotasMobi`, `codesift-mcp`,
`tgmcontest`, `Rewards-API`, `coding-ui`, `uptime`, `thepopebot`, …) but zuvo has **no static
container-security audit**. The only container coverage today is:
- `infra-audit` IS9 — audits the **live Docker daemon on a remote host over SSH** (runtime posture,
  consent-gated). Not the Dockerfile/compose source in the repo.
- `ci-audit` CI8 — Docker **build optimization** in the pipeline (cache/layers), not security.

Nothing audits the **Dockerfile / docker-compose / image as code**: running as root, `:latest`
mutable bases, secrets baked into layers, bloated attack surface, known CVEs, `docker.sock` mounts.
These are among the highest-severity, most common container defects and they are invisible to every
current zuvo skill. Doing nothing leaves a whole production surface unreviewed across a third of the
fleet.

Kubernetes is intentionally excluded: the fleet scan found **0 repos with k8s manifests**. Building
k8s dimensions now would be dead code (YAGNI). The skill is designed modular so a future `--k8s`
flag adds manifest/RBAC/Pod-Security dimensions additively when a target ever appears.

## Design Decisions

- **DD1 — Standalone skill `zuvo:container-audit` (57th skill).** [User-approved] Clean identity:
  static audit of container artifacts in the repo. Not folded into `infra-audit` (SSH-live-host
  identity + consent/security model would be muddied) or `ci-audit` (pipeline-scope, not image
  security). Cost accepted: skill count wiring in 8 places per CLAUDE.md + `count-consistency` test.
- **DD2 — Static-first with optional live Trivy/Grype.** [User-approved] K1–K4 and K6 are pure
  static parse of Dockerfile/compose (zero Docker, zero network → CI-safe). K5 (CVE scan) runs
  Trivy/Grype **only when present**; absent → K5=N/A with explicit degraded annotation, never a
  hard block. Mirrors the `security-audit --live-url` / `env-audit` graceful-degradation pattern.
- **DD3 — Six dimensions K1–K6, weighted, with critical gates** (below). [AUTO-DECISION] Mirrors the
  `env-audit` canonical audit shape (dimensions + weights + critical gates + validity gate + tiered
  A/B/C/D report + next-step routing). Rationale: consistency with the existing audit family; the
  reviewer/telemetry/report tooling already understands this shape. Alt considered: freeform
  checklist — rejected (no scoring, no gate enforcement, inconsistent with family).
- **DD4 — Modular dimension registry so `--k8s` is additive.** [AUTO-DECISION] Phase 0 detects
  artifact types; dimensions absent from the target are scored `N/A` and excluded from the
  denominator. **Precedent: `api-audit` D11=N/A** when no OpenAPI spec exists (a genuine
  variable-denominator model). NOTE: `env-audit` uses a *fixed* `sum/80` denominator and does NOT
  exclude N/A dims — this skill deliberately follows api-audit's variable-denominator model, not
  env-audit's. K7–K10 (k8s) ship later behind `--k8s` without touching K1–K6. Rationale: 0 current
  k8s targets; avoid dead code; keep the door open.
- **DD5 — Read-only, consent-gated network.** [AUTO-DECISION] Audit never builds, runs, pushes, or
  **pulls** an image without explicit consent (a pull is network egress + can execute registry
  redirects). The **truly zero-network layer is the native Dockerfile/compose parse (K1–K4/K6)**.
  `trivy image`/`grype <ref>` that must pull an image are consent-gated. `trivy config` (static
  Dockerfile/compose misconfig, no image pull) is the default live layer when trivy is present — but
  it may fetch its checks/policy bundle on first run, so it is invoked with `--skip-check-update` (or
  a pre-cached bundle) to keep the default run offline; a stale/empty bundle degrades K5 to native
  parse with an annotation, never a hard fail.
- **DD6 — Reference corpus is domain input, not copied prose.** [AUTO-DECISION] Checklists distilled
  from the Apache-2.0 `mukul975/Anthropic-Cybersecurity-Skills` container-security skills (ideas, not
  text). No prose copied → no NOTICE/attribution obligation triggered; if any verbatim text is later
  reused, add attribution.

## Solution Overview

`zuvo:container-audit` is a single-pass, dimension-scored, read-only audit that:

1. **Phase 0 — Detect & scope.** Discover container artifacts: `Dockerfile*`, `Containerfile`,
   `*.dockerfile`, `docker-compose*.y{a,}ml`, `compose*.y{a,}ml`, `.dockerignore`, **and compose
   override/merge files** (`docker-compose.override.y{a,}ml`, `compose.override.y{a,}ml`). If none
   found → report "no container artifacts" and exit HEALTHY-N/A (not a failure). Detect scanner
   availability (`trivy`, `grype`) and Docker socket presence for K5 mode selection. K6 evaluates the
   **effective merged compose config** (base + override) so an override cannot silently re-introduce
   `privileged`, host networking, or a `docker.sock` mount that the base file avoided.
2. **Phase 1 — Dimension analysis K1–K6** (static parse + optional live K5).
3. **Phase 2 — Scoring** with critical gates.
4. **Phase 3 — Tiered report** (A/B/C/D) to `zuvo/audits/container-audit-[YYYY-MM-DD].md` (+ `.json`
   for a future `container-fix` consumer).
5. **Phase 4 — Next-step routing** (e.g. K3 critical → `zuvo:security-audit --static`; K5 CVEs →
   `zuvo:dependency-audit`).

### Dimensions

| Dim | Name | Weight | Critical gate | What it checks (static) |
|-----|------|--------|---------------|--------------------------|
| K1 | Base Image Provenance & Pinning | 15 | K1=0 → FAIL | `FROM` pinned to `@sha256` digest or specific version (not `:latest`/`:stable`/no-tag); trusted registry; no mutable-tag bases |
| K2 | Privilege & Runtime Hardening | 18 | K2=0 → FAIL | `USER` non-root present (image not running as root); compose `privileged:false`, `cap_drop:[ALL]`, `security_opt: no-new-privileges`, `read_only` where feasible |
| K3 | Secret & Build-Context Hygiene | 18 | K3=0 → FAIL | No secrets in `ENV`/`ARG` baked to layers; `.dockerignore` excludes `.env`/`.git`/keys; no blind `COPY . .` without `.dockerignore`; no hardcoded creds; build secrets via `--mount=type=secret` not `ARG` |
| K4 | Image Minimalism & Attack Surface | 12 | — | Multi-stage build; minimal/distroless/slim base; package-manager cache cleaned; no dev/debug tools (curl, nc, shell) in final stage |
| K5 | Known Vulnerability Scan | 15 | critical CVE → FAIL (only when scan ran) | Trivy/Grype CVE scan of base+deps; `trivy config` misconfig. Absent scanner → **N/A (degraded)**, excluded from denominator |
| K6 | Compose & Orchestration Hardening | 12 | — | No `/var/run/docker.sock` mount; no `network_mode: host`; resource limits (mem/cpu); `healthcheck` present; no host PID/IPC; ports not needlessly bound to `0.0.0.0` |

**Score = (sum of applicable dim scores) / (sum of applicable max weights) × 100.**
Denominator drops any dimension scored `N/A` (K5 when no scanner; any dim with no matching artifact).

**Critical gates:** K1=0 OR K2=0 OR K3=0 OR (K5 ran AND critical CVE present) → overall **FAIL**.

| Grade | Score |
|-------|-------|
| HEALTHY | ≥ 80% |
| NEEDS ATTENTION | 60–79% |
| AT RISK | 40–59% |
| CRITICAL | < 40% |

### Future `--k8s` (out of scope now, additive later)

K7 manifest security (kubesec), K8 RBAC least-privilege, K9 Pod Security Standards / admission,
K10 network policies. Registered in the dimension table as `N/A (not requested)` until `--k8s` +
detected manifests activate them. Distilled checklist source already identified (mukul975 k8s skills).

## Detailed Design

### Data Model

No persistent schema. Outputs:
- `zuvo/audits/container-audit-[YYYY-MM-DD].md` — human report.
- `zuvo/audits/container-audit-[YYYY-MM-DD].json` — machine findings `{dimension, severity, file,
  line, rule_id, message, fix}` for a future `container-fix` skill (parity with seo/geo/content-audit).

### API Surface

Skill flags (Argument Parsing table in SKILL.md):

| Token | Behavior |
|-------|----------|
| _(empty)_ or `full` | All applicable dimensions, scope = repo root |
| `[path]` | Scope to a dir (monorepo package) |
| `--static` | Force pure-static: skip live Trivy/Grype even if present (K5 via `trivy config` only, or N/A) |
| `--scan` | Force live CVE scan. If scanner/Docker missing → loud preflight, **exit non-zero (`scan aborted: no scanner`)**, no silent downgrade. If an image PULL is needed and consent is declined → **exit non-zero (`scan aborted: pull declined`)**, no silent fallback to `trivy config`. (Contrast default mode, which degrades silently to N/A — `--scan` is the explicit "fail if I can't really scan" contract.) |
| `--dockerfile <path>` | Audit one Dockerfile |
| `--compose <path>` | Audit one compose file |
| `--quick` | Critical gates only (K1+K2+K3) |
| `--k8s` | (future) enable K7–K10 |
| `--persist-backlog` | Push findings to `zuvo:backlog` |

### Integration Points

- `shared/includes/`: `codesift-setup.md`, `env-compat.md`, `run-logger.md`, `retrospective.md`,
  `report-output-location.md`, `severity-vocabulary.md` — same loading contract as `env-audit`.
- CodeSift: `get_file_tree` (discover artifacts), `search_text` (FROM/USER/COPY/ARG/mount patterns),
  `scan_secrets` (K3), `search_patterns` (anti-patterns). Degraded mode → Read/Glob/grep fallback.
- Routing OUT: K3 → `zuvo:security-audit --static`; K5 CVEs → `zuvo:dependency-audit`;
  `--persist-backlog` → `zuvo:backlog`.
- Boundary IN (documented in "When NOT to use"): live remote host daemon → `zuvo:infra-audit`;
  CI Docker build speed → `zuvo:ci-audit`.
- **8-place count wiring (CLAUDE.md "Adding a skill"):** `skills/container-audit/SKILL.md`;
  `skills/using-zuvo/SKILL.md` (routing row + `| 57 skills |` banner); `.claude-plugin/plugin.json`,
  `.codex-plugin/plugin.json` (×2), `package.json`; `docs/skills.md` (row + category-count + Total);
  `CLAUDE.md` (three count spots + category table — Infra audits 6→7); `README.md` intro line;
  `install.sh` builds all four targets; `validate-skills.sh` `count-consistency: OK (57)` + `run-all.sh`.

### Safety Gates (enforces IC-3)

- **GATE 1 — Read-only.** Only write target is `zuvo/audits/`. FORBIDDEN: modifying any Dockerfile/
  compose/source; building, running, tagging, or pushing images.
- **GATE 2 — Secret censorship.** Any secret value surfaced from an `ENV`/`ARG`/`.env` is replaced
  with `***` before it reaches the report (variable NAMES may show; VALUES never). Applied by the
  report-writer pre-write pass (see Failure Modes → Report output writer).
- **GATE 3 — Consent before any image PULL (IC-3).** `trivy config` and native parse run freely (no
  pull). Before any `trivy image <ref>` / `grype <ref>` that must pull, prompt:
  `Pull image <ref> to scan for CVEs? This performs network egress to <registry>. [y/N]`. Default
  DENY. Decline → default mode: K5 falls back to native/`trivy config` with annotation; `--scan`
  mode: exit non-zero per API Surface. The prompt text and the y/N outcome are written to the run log.
- **GATE 4 — No daemon/socket interaction.** The audit never connects to `/var/run/docker.sock` or a
  remote daemon; that surface belongs to `zuvo:infra-audit`. Detecting a `docker.sock` **mount in a
  compose file** (K6) is static text analysis, not a socket connection.

### Validity Gate (pass/fail conditions — referenced by SMOKE1)

The audit is **INVALID** (VERDICT = INCOMPLETE, distinct from a healthy/at-risk score) if any hold:
- A **primary** artifact (a Dockerfile or compose file that IS present) was left unparsed with no
  "skipped — unparseable" note in the report.
- A dimension is scored a number but its required tool/parse did not run (e.g. K3 numeric without the
  `scan_secrets`/secret-pattern pass having executed).
- K5 ran a scanner but the result was neither parsed into findings nor annotated `partial/N/A`.
- The report was not written to `zuvo/audits/` (or its documented fallback) — analysis without a
  persisted artifact does not count.
- The run-log line was not appended via `~/.zuvo/append-runlog`.
Otherwise the Validity Gate is **PASS** and the numeric grade (HEALTHY/…/CRITICAL) stands on its own.
This mirrors `env-audit`'s Validity-Gate contract (mandatory tool calls + postamble).

### Interaction Contract

Not applicable — no cross-cutting agent-behavior change. This adds a new audit skill; it does not
alter how the assistant speaks, classifies, routes, or formats existing output.

### Integration Contract

- **IC-1 — Score denominator = Σ(applicable max weights).** A dimension scored `N/A` (no matching
  artifact, or K5 with no scanner) is removed from BOTH numerator and denominator. Cited by Scoring,
  K5 degraded path, `--k8s` future dims, and AC4/AC6.
- **IC-2 — Critical-gate set = {K1=0, K2=0, K3=0, K5-critical-CVE-when-scan-ran}.** Any triggers
  overall FAIL. Cited by Scoring, Failure Modes, AC3, Validity Gate.
- **IC-3 — Live scan requires consent for any image PULL.** `trivy config` (no pull) runs freely when
  trivy present; `trivy image`/`grype <ref>` needing a pull is consent-gated. Cited by Safety Gates,
  K5, DD5, Failure Modes.

### Edge Cases

| Edge case | Handling |
|-----------|----------|
| No container artifacts in repo | Report "no artifacts", exit `HEALTHY (N/A — nothing to audit)`, not FAIL |
| Multiple Dockerfiles (mono-repo, per-service) | Audit each; report per-file; worst critical gate governs overall verdict |
| Multi-stage build — runtime dims | Only the FINAL stage governs K2/K4/K6 (root/tools in a builder stage is fine); intermediate stages exempt from runtime dims |
| Multi-stage build — K1 pinning scope | K1 applies to **every EXTERNAL base ref in ALL stages** (a `FROM node:latest AS builder` is still pulled → supply-chain risk → must be pinned). Only INTERNAL stage refs (`FROM builder`, where `builder` is a prior stage in this file) are exempt — they resolve to an already-checked stage |
| Base image is another local build stage (`FROM builder`) | Resolve the stage graph; skip pin/CVE checks on internal refs, apply them to each stage's ultimate external base |
| `.dockerignore` absent but no `COPY . .` | K3 not auto-critical; flag as HIGH (recommend `.dockerignore`) |
| Distroless/scratch base (no shell, no USER support) | K2 satisfied via distroless `nonroot` variant; do not false-flag "no USER" when base is `:nonroot` |
| `docker-compose` with `env_file:` referencing real `.env` | K3 checks `.env` is gitignored + dockerignored, not its contents (secret censorship, Gate 2) |
| ARG used for non-secret build config (VERSION) | Not flagged; K3 only flags ARG/ENV whose NAME matches secret patterns (KEY/SECRET/TOKEN/PASSWORD) |
| Podman `Containerfile` | Treated identically to Dockerfile |
| Compose override re-introduces a risk | K6 scores the effective merged config (base + `*.override.y*ml`); a hardened base undone by an override is flagged against the override file:line, worst value governs |

### Failure Modes

#### Static Dockerfile/compose parser

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| Malformed/uparseable Dockerfile | parse exception per file | that file's dims | "Dockerfile X unparseable — skipped, listed in report" | Skip file, score others, note in report | Report notes gap | Immediate |
| Heredoc / complex `RUN` with embedded secret | regex miss on multiline | K3 false-negative | Secret not flagged | `scan_secrets` second pass over full file text catches most; note residual risk | N/A | Immediate |
| Unusual base ref (`FROM $REGISTRY/img`) with build ARG | var-interpolated FROM | K1 can't resolve | "Base image uses build-arg — pin manually" advisory | Flag as HIGH unresolved, not silent pass | N/A | Immediate |

#### Trivy/Grype live scanner (K5)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| Scanner not installed | `command -v trivy/grype` empty | K5 only | "K5: N/A (no scanner) — install trivy for CVE coverage" | K5=N/A, denominator drops 15 (IC-1) | Score valid over K1–K4/K6 | Immediate |
| `trivy image` needs pull, no consent | consent prompt declined | K5 CVE depth | "K5 limited to `trivy config` (static) — image pull declined" | Fall back to `trivy config` misconfig only | N/A | Immediate |
| Scanner times out (>120s) | timeout wrapper | K5 only | "K5: partial (scanner timeout)" | K5 marked partial, note coverage reduced | Report flags partial | 120s |
| Scanner returns non-zero on real CVEs | exit-code polarity (trivy exits 1 when `--exit-code 1` set on finding) | K5 scoring | correct — findings parsed from JSON not exit code | Parse `--format json`, never gate on raw `$?` | N/A | Immediate |

#### CodeSift dependency

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| CodeSift unavailable | tool-probe per `codesift-setup.md` | discovery speed | "Degraded mode — grep/Glob fallback" | Read/Glob/grep for artifacts + patterns | Same findings, slower | Immediate |
| `get_file_tree` misses artifact in ignored dir | cross-check with `git ls-files` | K-coverage | artifact silently unaudited | Also enumerate via `git ls-files '*Dockerfile*' 'compose*'` | Report lists all files scanned | Immediate |

#### Report output writer

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| `zuvo/audits/` not writable | write error | report persistence | "Cannot write report to zuvo/audits — printing inline" | Fall back to legacy `audits/` then stdout per `report-output-location.md` | Analysis intact, not persisted | Immediate |
| Partial write (interrupted) | post-write size/parse check | `.json` consumer | future `container-fix` reads truncated json | Write `.tmp` then atomic rename; consumer validates before use | `.json` either complete or absent | Immediate |
| Secret value would appear in report | Gate-2 censor pass before write | report content | none (censored) | Replace matched secret values with `***` prior to write | No secret persisted | Immediate |

**Cost-benefit:** static-parse failures (rare, ~1–2%) degrade one file's score with a visible note →
mitigate (skip+note). Scanner absence (common) → mitigate (N/A + denominator drop, IC-1). Consent
decline → accept (static fallback is a valid narrower result).

## Acceptance Criteria

**Ship criteria:**

- **AC1 — The skill file exists and passes the repo's skill validator.**
  - Surface: `docs`
  - Proof: `bash scripts/validate-skills.sh 2>&1 | grep -E 'container-audit'`
  - Expected: `PASS container-audit` (frontmatter, `# zuvo:container-audit`, Argument Parsing,
    Mandatory File Loading, phases, named completion block, run-log append all present)
  - Artifact: `zuvo/proofs/task-1-report.md`
- **AC2 — Skill count is consistent at 57 across all 8 wiring points.**
  - Surface: `config`
  - Proof: `bash scripts/validate-skills.sh 2>&1 | grep count-consistency && bash tests/run-all.sh`
  - Expected: `count-consistency: OK (57)` and `tests/run-all.sh` exits 0
  - Artifact: `zuvo/proofs/task-2-report.md`
- **AC3 — A deliberately bad Dockerfile trips all three static critical gates.**
  - Surface: `integration`
  - Proof: run `zuvo:container-audit --dockerfile tests/fixtures/container/bad.Dockerfile` (base
    `FROM node:latest`, no `USER`, `ENV API_KEY=sk-live-xxxx`, blind `COPY . .`, no `.dockerignore`)
  - Expected: report contains K1 CRITICAL (`:latest` unpinned), K2 CRITICAL (runs as root), K3
    CRITICAL (secret in ENV); overall verdict FAIL per IC-2
  - Artifact: `zuvo/proofs/task-3-report.md`
- **AC4 — Degraded mode: no scanner → K5=N/A, skill still completes with a valid score.**
  - Surface: `integration`
  - Proof: run with `PATH` stripped of `trivy`/`grype` against the fixture repo
  - Expected: report shows `K5: N/A (scanner unavailable)`; score computed over K1–K4/K6 with
    denominator = 75 (IC-1); skill exits with a verdict, not an error
  - Artifact: `zuvo/proofs/task-4-report.md`
- **AC5 — A hardened Dockerfile scores HEALTHY with zero criticals.**
  - Surface: `integration`
  - Proof: run on `tests/fixtures/container/good.Dockerfile` (distroless `nonroot`, `FROM ...@sha256:`,
    multi-stage, `.dockerignore` present, no baked secrets) + a hardened `docker-compose.yml`
  - Expected: 0 critical findings, score ≥ 80% (HEALTHY), no critical gate tripped
  - Artifact: `zuvo/proofs/task-5-report.md`
- **AC6 — k8s dimensions are inert without `--k8s`.**
  - Surface: `config`
  - Proof: run default (no `--k8s`) on a repo containing a `*.yaml` k8s manifest fixture
  - Expected: K7–K10 reported `N/A (not requested)`, excluded from denominator (IC-1); no k8s
    findings emitted; score identical to a run without the manifest present
  - Artifact: `zuvo/proofs/task-6-report.md`

**Success criteria:**

- **AC-S1 — Detects ≥ 90% of seeded misconfigs in a labeled fixture corpus.**
  - Surface: `integration`
  - Proof: `tests/fixtures/container/labeled/` holds ≥ 10 Dockerfiles/compose files each with a known
    labeled defect (`# EXPECT: K2-root`, `# EXPECT: K6-docker-sock`, …); a harness compares emitted
    `rule_id`s to labels
  - Expected: recall ≥ 90% (≥ 9/10), zero false-criticals on the 2 clean control fixtures
  - Artifact: `zuvo/proofs/container-corpus-recall.md`
- **AC-S2 — Produces actionable, cited findings on a real target.**
  - Surface: `integration`
  - Proof: run against `${ZUVO_CONTAINER_TARGET:-tests/fixtures/container/real-sample/}` — CI and
    other machines use the **vendored fixture clone** (a checked-in, de-secreted copy of a real
    Dockerfile+compose, e.g. sampled from QuotasMobi); a developer may point `ZUVO_CONTAINER_TARGET`
    at a live checkout (`~/DEV/QuotasMobi`) for an ad-hoc run. `run-all.sh` uses the fixture default
    so the criterion is host-independent.
  - Expected: every finding cites `path/to/file:LINE` resolving in the scanned tree; ≥ 1 actionable
    fix; no secret values leaked in the report (Gate 2)
  - Artifact: `zuvo/proofs/container-real-target.md`

## Whole-feature Smoke Proofs

- **SMOKE1 — Full audit round-trip on a mixed fixture repo.**
  - Preconditions: `tests/fixtures/container/repo/` with one multi-stage `Dockerfile` + one
    `docker-compose.yml` + `.dockerignore`
  - Proof: run `zuvo:container-audit tests/fixtures/container/repo/` end-to-end
  - Expected: report written to `zuvo/audits/container-audit-<date>.md` + `.json`; all 6 dims scored
    or N/A; critical-gate section present; Validity Gate = PASS; run-log line appended
  - Artifact: `zuvo/proofs/smoke-container-roundtrip.md`

## Validation Methodology

Runners: `bash` (validator, run-all), the skill itself run via the harness against fixtures, and a
small label-compare script for AC-S1. Prerequisites: fixture files under `tests/fixtures/container/`
(created by `zuvo:execute`) — `bad.Dockerfile`, `good.Dockerfile`, a hardened `docker-compose.yml`,
the labeled corpus `labeled/`, a mixed `repo/`, and a **vendored de-secreted `real-sample/`** used by
AC-S2 (overridable via `ZUVO_CONTAINER_TARGET`); optional `trivy`/`grype` on PATH for the non-degraded
K5 path (AC5/AC-S2). No test DB or dev server needed — all surfaces are file-static or skill-integration.

## Rollback Strategy

- Kill switch: the skill is additive and opt-in (invoked explicitly). Removing it = revert the skill
  dir + the 8 count edits; nothing else depends on it at runtime.
- Fallback behavior: none needed — no existing flow calls it.
- Data preservation: only writes under `zuvo/audits/` (read-only elsewhere); rollback leaves prior
  audit reports intact.

## Backward Compatibility

- Skill count moves 56 → 57; every count assertion is derived from `skills/` (per CLAUDE.md note) so
  `count-consistency` stays green once the 8 manual strings are updated in the same commit.
- `install.sh` Codex build fails on Claude-Code-only tool names (`Task`, `run_in_background`) —
  SKILL.md must use platform-neutral tool references, verified by running the Codex build.
- No change to any existing skill's behavior, output, or routing table beyond adding one row.
- Category table in CLAUDE.md/docs: "Infra audits" 6 → 7.

## Out of Scope

### Deferred to v2
- `--k8s` dimensions (K7–K10): 0 current targets; ship when a k8s manifest appears in the fleet.
- `zuvo:container-fix` companion (apply-fixes from the `.json`): parity with seo-fix/geo-fix, later.
- Live remote-host image inventory: that is `infra-audit`'s domain.

### Permanently out of scope
- Auditing the live Docker **daemon** on a remote host → `zuvo:infra-audit` IS9.
- Docker **build performance/caching** in CI → `zuvo:ci-audit` CI8.
- Building/running/pushing images (this skill is read-only; pulls are consent-gated only).

## Open Questions

None blocking. (Adversarial review may add items here.)

## Adversarial Review

`adversarial-review --json --mode spec` ran 2026-08-02T12:10Z. **Status: partial** — 3/5 providers
returned (`codex-5.3`/gpt-5.6-sol, `cursor-agent`/composer-2.5-fast, `claude`/claude-sonnet-5 = ok;
`gemini`/agy + `kimi` = empty). **Zero CRITICAL.** All findings WARNING or factual; every one resolved
in-spec this round (no residual carried to Open Questions):

| Finding | Provider | Disposition |
|---------|----------|-------------|
| DD4 cited a *fabricated* env-audit "ENV-N/A" denominator precedent (env-audit is fixed `sum/80`) | claude | **FIXED** — re-cited `api-audit` D11=N/A (real variable-denominator precedent); added explicit note that env-audit is fixed-denominator |
| `trivy config` claimed "no network" but it fetches a checks bundle by default | claude | **FIXED** — DD5 now: native parse is the zero-network layer; `trivy config` invoked with `--skip-check-update`; stale bundle → annotated degrade |
| Multi-stage K1 pinning scope contradiction | claude | **FIXED** — K1 now explicitly covers every EXTERNAL base in ALL stages (incl. builder, supply-chain); internal stage refs exempt; runtime dims (K2/K4/K6) = final stage only |
| K6 missing compose override/merge-file handling | claude | **FIXED** — Phase 0 discovers `*.override.y*ml`; K6 scores the effective merged config; edge case added |
| `--scan` consent-decline outcome underspecified (silent fallback risk) | codex-5.3 | **FIXED** — `--scan` exits non-zero on no-scanner and on pull-decline; contrasted with default silent-degrade |
| SMOKE1 references an undefined "Validity Gate" | codex-5.3 | **FIXED** — added `### Validity Gate` with explicit INVALID conditions |
| IC-3 cites a nonexistent "Safety Gates" section | codex-5.3 | **FIXED** — added `### Safety Gates` (GATE 1–4) enforcing IC-3 |
| AC-S2 depended on host-specific `~/DEV/QuotasMobi` | codex-5.3 | **FIXED** — pinned to vendored fixture default via `${ZUVO_CONTAINER_TARGET:-tests/fixtures/container/real-sample/}` |

Coverage note: `partial` means 2 providers (gemini, kimi) returned empty, so cross-model diversity was
3-wide, not 5. Given zero CRITICAL and full in-spec resolution of every WARNING, this converges without
a second pass (per `adversarial-loop-docs.md` 2-run cap; no novel architectural concern surfaced).

### Second pass — 2026-08-02, `zuvo:review` on `fd57e11..fc0c83e` (OPEN — resolve before implementing)

The spec was re-reviewed as part of the commit range that introduced it (`--mode code`, chunked,
providers `codex-5.3` + `cursor-agent` + `claude`). These are **not** resolved in-spec: they are
design decisions the implementer must make, recorded here rather than dropped. Nothing below blocks
the range from merging — the skill does not exist yet — but each is a defect if it reaches the build.

| # | Finding | Why it matters |
|---|---------|----------------|
| 1 | Effective-compose merge covers only `*.override.y*ml` | Misses `COMPOSE_FILE` multi-file stacks, `docker-compose.prod.yml`, `extends`, and profiles — the "effective config" K2/K6 score would not be the one that runs in production |
| 2 | "Merged config" is specified as a YAML deep-merge | Compose replaces most list values wholesale rather than appending, and interpolates `${VAR}`; a hand-rolled merge silently yields a different config than `docker compose config` |
| 3 | K2 treats a missing final-stage `USER` as root | Ignores a `USER` inherited from base-image metadata — false CRITICAL on images that already drop privileges |
| 4 | K1 accepts a version tag as "pinned" | Registry tags are mutable; `node:20.11.0` can be re-pushed. Either accept it and stop claiming mutable refs are rejected, or require a digest |
| 5 | K5 promises to scan the resulting image's dependencies | The skill never builds an image and does not define how a Dockerfile maps to an existing image ref |
| 6 | `--static` allows `trivy config`, DD5's offline guarantee rests on `--skip-check-update` | `--static` never mandates that flag, so "pure-static" can still hit the network |
| 7 | K3 flags only `KEY/SECRET/TOKEN/PASSWORD` names; Gate 2 censors any surfaced secret value | Two different thresholds for the same concept — a value censored as secret can still pass K3 |
| 8 | Report filename is date-only | Two audits on one day overwrite each other; no run disambiguator |
| 9 | GATE 3's consent prompt has no non-interactive contract | A cron/CI/agent run hits a `[y/N]` on a closed stdin with unspecified behavior |
| 10 | GATE 3 logs the raw image `<ref>` | A ref can embed registry credentials; the log has no sanitization rule |
| 11 | Scoring is ambiguous between numeric dimension scores and binary critical gates | "sum of applicable dim scores" vs "K1=0 → FAIL"; unclear when only some of several base refs are unpinned |
| 12 | AC-S2 vendors a de-secreted copy of an internal repo's Dockerfile/compose | The fixture ships inside a publicly distributed plugin — "de-secreted" is a manual step with no gate behind it |
| 13 | Distroless/scratch edge case groups "no USER support" with "`:nonroot` variant satisfies K2" | Reads as a blanket K2 exemption for all distroless bases |
