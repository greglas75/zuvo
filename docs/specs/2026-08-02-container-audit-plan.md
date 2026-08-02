# Implementation Plan: zuvo:container-audit (57th skill)

**Spec:** docs/specs/2026-08-02-container-audit-spec.md
**spec_id:** 2026-08-02-container-audit-1204
**planning_mode:** spec-driven
**source_of_truth:** approved spec
**plan_revision:** 3
**status:** Approved
**Created:** 2026-08-02
**Approved:** 2026-08-02T14:30:59Z
**Tasks:** 4
**Estimated complexity:** 1 complex (skill file + atomic count wiring) + 3 standard (fixtures, eval corpus, smoke)

## Architecture Summary

A zuvo audit skill is a **markdown instruction file executed by the LLM agent**, not runnable code.
`skills/container-audit/SKILL.md` is the single production artifact, authored to the `env-audit`
canonical shape (Mandatory File Loading → Argument Parsing → Safety Gates → mandatory-tools gate →
Phase 0 detect/scope → Phase 1 dimensions K1-K6 (+ reserved K7-K10) → Phase 2 scoring → Phase 3
report .md+.json → Phase 4 routing → Validity Gate → retro/run-log). Behavior is verified NOT by unit
tests but by (a) the deterministic structural validator `scripts/validate-skills.sh` and (b) a
behavioral **eval corpus** `evals/container-audit.evals.json` run through `zuvo:skill-eval` in fresh
executor sub-agents (established pattern — skill-eval-campaign). Fixtures under
`tests/fixtures/container/` are the inputs the eval corpus consumes.

**Revision-2 architecture fixes (from cross-model adversarial rev-1):**
- The 57th skill dir and the 8-place count bump land in **ONE commit** (Task 1) — the count-consistency
  test derives 57 from `skills/` on disk, so a skill-dir commit without the count bump leaves
  `tests/run-all.sh` RED. They are inseparable and must be atomic (was the rev-1 count-red CRITICAL).
- The skill's dimension registry **reserves K7-K10 as `N/A (requires --k8s)`** so the AC6 `k8s-inert`
  eval has real dimensions to assert N/A against (rev-1 CRITICAL: eval referenced K7-K10 the skill
  never declared).
- **Codex-build compatibility is verified in Task 1** (earliest point the skill exists), not deferred
  to the last task — it was the explicitly-identified failure risk (TD3) and rule 14 puts the riskiest
  cross-boundary check first.

Component/dependency direction:
```
Task1: skills/container-audit/SKILL.md (K1-K6 + reserved K7-K10) + 8-place count bump + codex-build ✓
Task2: tests/fixtures/container/* (incl. k8s-sample/ manifest)
   └──▶ Task3: evals/container-audit.evals.json ──(zuvo:skill-eval)──▶ AC3-AC6, AC-S1/S2
        └──▶ Task4: SMOKE1 round-trip runnable proof
```

## Technical Decisions

- **TD1 — Model on `skills/env-audit/SKILL.md`** (closest output-shape). NOTE: env-audit uses a FIXED
  `sum/80` denominator; container-audit uses api-audit's VARIABLE denominator (spec IC-1) — do NOT copy
  env-audit's scoring math (brainstorm retro proposal #1: verify cited claims against the file).
- **TD2 — Behavioral verification via eval corpus, not bash asserts.** `zuvo:skill-eval` runs the skill
  against `evals/container-audit.evals.json` and grades transcripts. Verify steps do the cheap
  structural check (schema/fields); Acceptance Proofs do the behavioral check (run skill-eval) — the
  acceptance-proof-protocol Verify-vs-Proof split.
- **TD3 — Platform-neutral tool references only.** `build-codex-skills.sh` FAILS on Claude-Code-only
  tool names (`Task`, `run_in_background`). Single-pass inline like env-audit; verified in Task 1.
- **TD4 — `.json` findings output is part of Task 1** (Phase 3), schema
  `{dimension,severity,file,line,rule_id,message,fix}` — parity for a future `container-fix`.
- **TD5 — Reserved-dimension registry.** K7-K10 appear in the skill's dimension table as
  `N/A (requires --k8s)` with no check logic yet (DD4 modularity), so scoring (IC-1) already excludes
  them and AC6 can assert their inert N/A state.

## Quality Strategy

- Structural gate: `bash scripts/validate-skills.sh` → `PASS container-audit` + `count-consistency: OK (57)`.
- Suite gate: `bash tests/run-all.sh` green.
- Codex-build gate: `bash scripts/build-codex-skills.sh` exit 0, no tool-name rejection (Task 1, early).
- Behavioral gate: `zuvo:skill-eval container-audit` per-assertion pass.
- **Recall loop (AC-S1):** recall is only measurable once the skill (T1) + labeled fixtures (T2) exist,
  so it cannot be a pre-spike; if Task 3 measures < 90%, the fix routes BACK to Task 1's K1-K6 detection
  rules (the plan's built-in remediation loop, stated here so a miss is not treated as a new blocker).
- Risk areas: count drift (mitigated: atomic Task 1 + count-consistency); Codex tool-name rejection
  (mitigated: TD3 + Task-1 build check); distroless `nonroot` K2 false-flag (mitigated: clean control
  fixture in `labeled/`).

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| AC1 | Skill file passes validator | requirement | Task 1 | structural |
| AC2 | Count consistent at 57 (8 places) | requirement | Task 1 | atomic with skill dir |
| AC3 | Bad Dockerfile trips K1/K2/K3 criticals | requirement | Task 3 | eval; needs T1+T2 |
| AC4 | No scanner → K5=N/A, valid score | requirement | Task 3 | eval; degraded mode |
| AC5 | Hardened Dockerfile → HEALTHY, 0 crit | requirement | Task 3 | eval; needs T2 good fixture |
| AC6 | k8s dims (K7-K10) inert without --k8s | requirement | Task 3 | eval; needs T1 reserved dims + T2 k8s fixture |
| AC-S1 | ≥90% recall on labeled corpus | success | Task 3 | eval; loops to T1 on miss |
| AC-S2 | Cited findings on real target | success | Task 3 | eval; real-sample/ + ZUVO_CONTAINER_TARGET |
| SMOKE1 | Full audit round-trip on fixture repo | smoke | Task 4 | runnable proof + report post-check |
| D1 | skills/container-audit/SKILL.md (+ .json) | deliverable | Task 1 | TD4 |
| D2 | tests/fixtures/container/* (+ k8s-sample) | deliverable | Task 2 | |
| D3 | 8-place count wiring + Infra 6→7 | deliverable | Task 1 | atomic |
| D4 | evals/container-audit.evals.json | deliverable | Task 3 | |
| D5 | Codex-build compatibility | constraint | Task 1 | TD3, early |

## Review Trail
- Deterministic DAG lint: rev-1 PASS (5 tasks) → rev-2/rev-3 PASS (4 tasks, 0 violations)
- Plan reviewer (inline): rev-1 APPROVED → rev-3 APPROVED (re-checked after cheap-fix edits)
- Cross-model validation:
  - Pass 1 (rev-1, codex-5.3+cursor-agent+claude): **5 CRITICAL + 8 WARNING** — all fixed in rev-2
    (count-red→atomic Task 1; K7-K10 reserved registry; k8s-sample fixture; codex-build moved early).
  - Pass 2 (rev-2, cursor-agent+claude, `--exclude-last codex-5.3`): **1 CRITICAL + 8 WARNING**.
    - CRITICAL `recall-risk-scheduled-late` (AC-S1 ≥90% recall measurable only in Task 3):
      **ACCEPTED TRADE-OFF** — detection recall is inherently unmeasurable before the detector (Task 1)
      and labeled corpus (Task 2) exist; a pre-spike would just be a miniature of T1+T2. Mitigated by
      the documented T3→T1 recall loop (Quality Strategy) + running `labeled-recall` as a first-class
      T3 case. Re-raise of the rev-1 recall WARNING, not a novel architectural concern → converged per
      `adversarial-loop-docs.md` post-cap classification (no pass 3).
    - WARNINGs fixed in rev-3: codex-gate broad-`error` grep → exit-code + tool-name tokens only;
      Task 4 smoke Verify → assert ALL six K1-K6 (loop, not any-match); added `scanner-present` +
      `no-artifacts` eval cases; rule_id catalog declared as shared contract (Task 1) cited by T2 labels
      + T3 assertions.
    - WARNINGs accepted/documented: Task 1 structural-only gate for behavioral ACs (inherent TD2 split —
      markdown skill, behavior verified in T3); Task 2 "standard" at 14 files (fixtures exempt rule-2);
      D1-D4 deliverable rows proven by each task's file-existence Verify, not a separate AC bullet.
- Status gate: Reviewed (awaiting user approval → Approved)
- `[BUDGET: 2 plan-review cross-model passes — residual 1 CRITICAL dispositioned as accepted trade-off, not re-looped]`

## Task Breakdown

### Task 1: Skill file + reserved-dimension registry + atomic count bump + Codex-build gate
**Files:** `skills/container-audit/SKILL.md` (new); count locations: `skills/using-zuvo/SKILL.md`,
`.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `package.json`, `docs/skills.md`,
`CLAUDE.md`, `README.md`
**Surface:** docs
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier
**Rule-2 justification:** 8 files but ATOMIC and inseparable — `count-consistency` derives 57 from the
`skills/` dir the moment the skill file exists, so `tests/run-all.sh` is RED until the 7 count strings
move 56→57 in the SAME commit. Splitting would ship a red tree (rev-1 count-red CRITICAL). One commit.

- [ ] RED (docs/config — structural gate is the test): before authoring, the validator does not know the
  skill and count is 56: `bash scripts/validate-skills.sh 2>&1 | grep -E 'container-audit|count-consistency'`
  → expect no `container-audit` line and `OK (56)` (the RED baseline).
- [ ] GREEN:
  - Author `skills/container-audit/SKILL.md` on the env-audit skeleton: frontmatter (`name`,
    `description` with flags `full|[path]|--static|--scan|--dockerfile|--compose|--quick|--k8s|--persist-backlog`,
    `codesift_tools`), `# zuvo:container-audit`, Argument Parsing, Mandatory File Loading, Safety Gates
    GATE 1-4, mandatory-tools gate, Phase 0 discovery (incl. `*.override.y*ml` merged config + scanner
    detect), Phase 1 dimensions **K1-K6** (checks/weights 15/18/18/12/15/12/critical gates) **plus a
    reserved dimension block K7-K10 = `N/A (requires --k8s)`** (TD5, no check logic yet), Phase 2 scoring
    (variable denominator IC-1 — NOT env-audit's fixed math), Phase 3 report `.md` + `.json` (TD4),
    Phase 4 routing, Validity Gate, `CONTAINER-AUDIT COMPLETE` block, run-log append. Platform-neutral
    tool refs only (TD3). **Define the rule_id catalog here** (`K<n>-<slug>`, e.g. `K1-latest-tag`,
    `K2-root-user`, `K3-secret-in-env`, `K6-docker-sock`) — this is the shared contract that Task 2's
    `# EXPECT:` fixture labels and Task 3's eval assertions both cite; a label/rule_id mismatch surfaces
    deterministically in Task 3's `labeled-recall` case, never silently.
  - Bump every count 56→57: `using-zuvo` banner + routing row; `docs/skills.md` row + Infra-audits
    category 6→7 + Total; `CLAUDE.md` "skill definitions (57 total)" + "## Skill categories (57 total)"
    + Infra audits 6→7; both plugin.json descriptions; `package.json`; `README.md` intro.
- [ ] Verify: `bash scripts/validate-skills.sh 2>&1 | grep -E 'PASS container-audit|count-consistency: OK \(57\)' | wc -l | grep -qx 2 && bash tests/run-all.sh >/dev/null 2>&1 && echo "structural+suite OK"; bash scripts/build-codex-skills.sh >/tmp/cb.log 2>&1; rc=$?; { [ $rc -eq 0 ] && ! grep -qiE 'run_in_background|Task tool|invalid tool|unknown tool' /tmp/cb.log; } && echo "codex-build OK" || { echo "codex-build FAIL"; cat /tmp/cb.log; }`
  Expected: `structural+suite OK` AND `codex-build OK`. Gate is exit-code (`rc=0`) + Claude-only-tool-name tokens ONLY — a benign log line containing "error" does not fail it (rev-2 WARNING: broad `error` grep).
- [ ] Acceptance Proof:
  - AC1:
    - Surface: docs
    - Proof: `bash scripts/validate-skills.sh 2>&1 | grep 'container-audit'`
    - Expected: `PASS container-audit`
    - Artifact: `zuvo/proofs/task-1-report.md`
  - AC2:
    - Surface: config
    - Proof: `bash scripts/validate-skills.sh 2>&1 | grep count-consistency; bash tests/run-all.sh; echo "exit=$?"`
    - Expected: `count-consistency: OK (57)` and `exit=0`
    - Artifact: `zuvo/proofs/task-1-report.md`
  - D5 (Codex-build constraint):
    - Surface: integration
    - Proof: `bash scripts/build-codex-skills.sh; echo "rc=$?"` + grep the log for tool-name errors
    - Expected: `rc=0`, no `run_in_background`/`Task` rejection
    - Artifact: `zuvo/proofs/task-1-report.md`
- [ ] Commit: `feat(container-audit): add K1-K6 Docker/compose security skill + wire count 56→57 (57th)`

### Task 2: Fixture corpus `tests/fixtures/container/` (incl. k8s manifest)
**Files (all static fixtures — exempt from the rule-2 boundary):** `bad.Dockerfile`, `good.Dockerfile`,
`docker-compose.yml`, `docker-compose.override.yml`, `.dockerignore`, `labeled/*` (≥12: ≥10 defective
with `# EXPECT: K<n>-<slug>` + 2 clean controls incl. a distroless `nonroot` control),
`repo/` (multi-stage Dockerfile + compose + `.dockerignore`), `real-sample/` (vendored de-secreted),
**`k8s-sample/deploy.yaml`** (a Kubernetes manifest so the AC6 `k8s-inert` case has a real manifest present)
**Surface:** config
**Complexity:** standard (14 fixture files but all trivial static content; fixtures do not count toward the rule-2 production-file boundary)
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: `test ! -d tests/fixtures/container && echo 'absent (expected RED)'`.
- [ ] GREEN: create the fixtures with the exact defects the ACs assert:
  - `bad.Dockerfile`: `FROM node:latest`, no `USER`, `ENV API_KEY=sk-live-xxxx`, blind `COPY . .`, no `.dockerignore` → K1/K2/K3 criticals (AC3).
  - `good.Dockerfile`: multi-stage, `FROM gcr.io/distroless/nodejs:nonroot@sha256:…`, no baked secret, paired `.dockerignore` (excludes `.env`,`.git`) → HEALTHY (AC5).
  - `docker-compose.yml` hardened (limits, healthcheck, no docker.sock) + `docker-compose.override.yml` re-introducing `privileged: true` + `/var/run/docker.sock` mount → K6 flags merged config.
  - `labeled/` ≥10 defective (root, :latest, docker-sock, host-network, ARG secret, missing healthcheck, no multi-stage, unpinned digest, host PID, no cap_drop) each `# EXPECT: K<n>-<slug>` + 2 clean controls `# EXPECT: none` (one distroless `nonroot` — K2 false-flag guard) → AC-S1.
  - `repo/` multi-stage Dockerfile + hardened compose + `.dockerignore` → SMOKE1.
  - `real-sample/` de-secreted real Dockerfile+compose (secret values scrubbed to `***`) → AC-S2 default.
  - `k8s-sample/deploy.yaml` a minimal Deployment manifest → present so AC6 can prove K7-K10 stay N/A without `--k8s`.
- [ ] Verify: `for p in bad.Dockerfile good.Dockerfile docker-compose.override.yml labeled repo real-sample k8s-sample/deploy.yaml; do test -e "tests/fixtures/container/$p" || { echo "MISSING $p"; exit 1; }; done; test $(grep -rl '# EXPECT:' tests/fixtures/container/labeled | wc -l) -ge 12 && echo "fixtures OK"`
  Expected: `fixtures OK` (all present incl. k8s manifest, ≥12 labeled entries).
- [ ] Acceptance Proof:
  - fixture-integrity (underpins AC3/AC5/AC6/AC-S1/AC-S2/SMOKE1):
    - Surface: config
    - Proof: `grep -rl '# EXPECT:' tests/fixtures/container/labeled | wc -l; test -f tests/fixtures/container/k8s-sample/deploy.yaml && echo k8s-ok`
    - Expected: ≥ 12 and `k8s-ok`
    - Artifact: `zuvo/proofs/task-2-report.md`
- [ ] Commit: `test(container-audit): fixture corpus (bad/good/override/labeled/repo/real-sample/k8s)`

### Task 3: Behavioral eval corpus `evals/container-audit.evals.json`
**Files:** `evals/container-audit.evals.json` (new)
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 1 (skill under test + reserved K7-K10), Task 2 (fixtures incl. k8s-sample)
**Execution routing:** default implementation tier

- [ ] RED: `test ! -f evals/container-audit.evals.json && echo 'no corpus (expected RED)'`.
- [ ] GREEN: author eval cases (schema per existing `evals/*.evals.json`), each with a fixture `input`
  path + assertions:
  - `bad-dockerfile-criticals` → `bad.Dockerfile`; assert K1/K2/K3 CRITICAL + verdict FAIL (AC3).
  - `degraded-no-scanner` → trivy/grype absent; assert `K5: N/A (scanner unavailable)`, denominator 75, completes with verdict (AC4).
  - `hardened-healthy` → `good.Dockerfile` + hardened compose; assert 0 criticals, ≥80 HEALTHY (AC5).
  - `k8s-inert` → default (no `--k8s`) on a scope containing `k8s-sample/deploy.yaml`; assert K7-K10 `N/A (requires --k8s)`, excluded from denominator, zero k8s findings (AC6).
  - `labeled-recall` → `labeled/`; assert `rule_id` coverage ≥90% of `# EXPECT:` labels + zero false-criticals on the 2 controls (AC-S1).
  - `real-target-cited` → `${ZUVO_CONTAINER_TARGET:-tests/fixtures/container/real-sample/}`; assert every finding cites `file:LINE`, ≥1 fix, no secret values (AC-S2, Gate 2).
  - `repo-roundtrip` → `repo/`; assert all 6 dims scored-or-N/A + report written (feeds SMOKE1's RED so a cross-task regression surfaces here, not only at Phase Final).
  - `scanner-present` → `bad.Dockerfile` with Trivy/Grype ON PATH; assert K5 runs (not N/A) and denominator = 90, so the non-degraded K5 path is exercised, not only the degraded one (rev-2 WARNING: scanner-present path uncovered).
  - `no-artifacts` → an empty dir; assert "no container artifacts" + exit `HEALTHY (N/A)`, not FAIL (spec edge case + Validity Gate; rev-2 WARNING: empty-repo path uncovered).
- [ ] Verify: `python3 -c "import json,sys; d=json.load(open('evals/container-audit.evals.json')); cs=d['cases']; ids={c['id'] for c in cs}; need={'bad-dockerfile-criticals','degraded-no-scanner','scanner-present','hardened-healthy','k8s-inert','labeled-recall','real-target-cited','repo-roundtrip','no-artifacts'}; ok=need<=ids and all(c.get('input') is not None and c.get('assertions') for c in cs); sys.exit(0 if ok else 1)"`
  Expected: exit 0 (valid JSON; all 9 case ids present; every case has an `input` + non-empty `assertions`).
- [ ] Acceptance Proof (behavioral — fresh executor sub-agents via skill-eval):
  - AC3/AC4/AC5/AC6/AC-S1/AC-S2:
    - Surface: integration
    - Proof: `zuvo:skill-eval container-audit` (grades each case transcript against its assertions)
    - Expected: per-assertion PASS for all cases; AC-S1 recall ≥90%. On AC-S1 miss → route back to Task 1 K1-K6 rules (Quality Strategy recall loop).
    - Artifact: `zuvo/proofs/task-3-report.md` + `zuvo/reports/<skill-eval output>`
- [ ] Commit: `test(container-audit): behavioral eval corpus (AC3-AC6, AC-S1/S2, roundtrip)`

### Task 4: Whole-feature smoke — runnable round-trip proof
**Files:** `zuvo/proofs/smoke-container-roundtrip.md` (runner + captured evidence)
**Surface:** integration
**Dependencies:** Task 1, Task 2, Task 3
**Complexity:** standard
**Execution routing:** default implementation tier

- [ ] RED: no smoke evidence yet — `test ! -f zuvo/proofs/smoke-container-roundtrip.md && echo 'no smoke proof (expected RED)'`. (The `repo-roundtrip` eval case in Task 3 already fails first if the round-trip regresses.)
- [ ] GREEN: run `zuvo:container-audit tests/fixtures/container/repo/` end-to-end; capture the produced
  report path + the deterministic post-checks below into `zuvo/proofs/smoke-container-roundtrip.md`.
- [ ] Verify (deterministic post-check on the produced report — not just "ran"):
  `R=$(ls -t zuvo/audits/container-audit-*.md | head -1); ok=1; grep -q 'Validity Gate' "$R" || ok=0; for d in K1 K2 K3 K4 K5 K6; do grep -q "$d" "$R" || ok=0; done; test -f "${R%.md}.json" || ok=0; tail -3 ~/.zuvo/runs.log | grep -q container-audit || ok=0; [ $ok -eq 1 ] && echo "SMOKE1 OK" || echo "SMOKE1 FAIL"`
  Expected: `SMOKE1 OK` — report has Validity Gate + **ALL six** dims K1-K6 (loop, not any-match) + sibling `.json` + run-log line appended.
- [ ] Acceptance Proof:
  - SMOKE1:
    - Surface: integration
    - Proof: run `zuvo:container-audit tests/fixtures/container/repo/` then the Verify post-check above
    - Expected: report at `zuvo/audits/container-audit-<date>.md` + `.json`; all 6 dims scored/N/A; Validity Gate PASS; run-log appended
    - Artifact: `zuvo/proofs/smoke-container-roundtrip.md`
- [ ] Commit: `test(container-audit): whole-feature smoke round-trip proof`

## Whole-feature Smoke Proofs

- **SMOKE1 — Full audit round-trip on the mixed fixture repo.**
  - Preconditions: `tests/fixtures/container/repo/` (multi-stage Dockerfile + docker-compose.yml + .dockerignore), created in Task 2.
  - Proof: run `zuvo:container-audit tests/fixtures/container/repo/` end-to-end, then the deterministic post-check in Task 4 Verify.
  - Expected: report written to `zuvo/audits/container-audit-<date>.md` + `.json`; all 6 dims scored or N/A; critical-gate section present; Validity Gate = PASS; run-log line appended.
  - Artifact: `zuvo/proofs/smoke-container-roundtrip.md`
  - RED mapping: Task 3's `repo-roundtrip` eval case runs the same `repo/` path (surfaces a cross-task round-trip regression during execute, not only at Phase Final); Task 4 authors the runnable proof + report post-check.
