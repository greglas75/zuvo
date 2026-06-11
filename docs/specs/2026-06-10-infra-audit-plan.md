# Implementation Plan: zuvo:infra-audit — Server/Infrastructure Security Audit

**Spec:** docs/specs/2026-06-10-infra-audit-spec.md
**spec_id:** 2026-06-10-infra-audit-1137
**planning_mode:** spec-driven
**source_of_truth:** approved spec
**plan_revision:** 3
**status:** Approved
**Created:** 2026-06-10
**Tasks:** 11
**Estimated complexity:** 6 complex / 5 standard

## Architecture Summary

The repo is a markdown-skill plugin (no app code). Deliverables: a new skill tree `skills/infra-audit/` (SKILL.md orchestrator + 4 analyst agents), one bash collector `scripts/infra-collect.sh`, two shared includes (`ssh-probe-protocol.md`, `infra-check-registry.md`), docker test fixtures under `tests/infra-suite/`, and additive wiring edits (router, severity vocabulary, output-location writers, install.sh, 4 manifest counts).

Data flow: `using-zuvo` routes → `infra-audit/SKILL.md` Phase 0 preflight (authorization gate, probes) → Phase 1 collector (`infra-collect.sh` per host → `bundle/<host>.json` per IC-3; failures → `bundle/<host>.phase0.json`) → Phase 2 four parallel `Explore` analysts (Read+Bash/jq over bundle slices → `findings/<host>.json` + `bundle_sha256`) → Phase 3 deterministic aggregation (registry severity, IC-6 CVE grep gate, UNGROUNDED-FINDING rejection, internal/external diff) → `$ZUVO_DIR/audits/infra-audit-<ts>/` (fleet-summary written LAST).

Verified repo facts: agents/-dir convention from `skills/geo-audit/` (dispatch block lines ~275-334); `install.sh` line 150 glob `cp scripts/*.sh` auto-distributes the collector for Claude Code, but Codex (~558-561) and Cursor (~730-733) copy named scripts only → explicit cp lines required; build-codex/cursor scripts auto-discover `skills/*/` and `skills/*/agents/*.md` — no build-script changes; manifest counts today: package.json=52, docs/skills.md=52(×2), .claude-plugin=53, using-zuvo banner=53, .codex-plugin=54; actual skill dirs=53; post-add target=54 everywhere; no docker-compose precedent anywhere in the repo (fixtures are the novel-infra spike).

## Technical Decisions

- **Two-stage include loading** (pentest model): Stage 1 `env-compat.md`, `no-pause-protocol.md`, `infra-check-registry.md`, `ssh-probe-protocol.md`; Stage 2 `backlog-protocol.md`, `run-logger.md`, `retrospective.md`, `report-output-location.md`. (Adds `no-pause-protocol`/`backlog-protocol` that the spec omitted but every comparator audit skill loads.)
- **Monolithic collector** (~500-600 lines, internal functions): repo precedent benchmark.sh=1038 / adversarial-review.sh=1379; a sourced lib would complicate Codex/Cursor named-script distribution. file-limits.md utility caps apply to TS app code, not these orchestration scripts — precedent governs. Implementation is split across three serialized tasks (CLI skeleton → core live collection → failure hardening → external leg) so a single failure domain never blocks all collector work.
- **jq = hard prerequisite** (benchmark.sh line 426 gate pattern); python3 only as text-parsing assistant (lynis `.dat`) with awk fallback — never a jq substitute.
- **Plain `.sh` assert runners** in `tests/infra-suite/` sourcing `tests/seo-suite/assert.sh` (hard-exit style), e2e driver on the geo-suite TOTAL_FAIL pattern so docker SKIPs don't fail the suite. No bats for the suite.
- **Agent frontmatter**: `name/description/model: sonnet/reasoning: false/tools: [Read, Bash]` (Bash for jq over bundle JSON), dispatch `type: Explore` per geo-audit + env-compat rate-limit fallback (`[MODE SWITCH] ×2 → single-agent`).
- **Fixtures**: `ubuntu:24.04` + thin Dockerfiles (seeded misconfigs explicit in sshd_config, reviewable), `serjs/go-socks5-proxy` (pinned digest) for the IC-4 proxy leg, docker compose v2 syntax.
- **install.sh**: add explicit `cp .../infra-collect.sh` lines to Codex + Cursor Step 7 blocks now (2-line change closes the silent multi-platform gap).
- **Analyst-pipeline spike inside Task 9** (adversarial finding, rev 3): before authoring the full SKILL.md, Task 9 dispatches ONE analyst against a real fixture bundle and runs a minimal aggregation pass — de-risks the LLM half of the pipeline before wiring and smoke harnesses, without adding an llm-manual task that execute could not gate deterministically.

## Quality Strategy

AC classification (QA): **static-assert** (no docker, no LLM): AC3, AC7, AC10 + all contract tests (registry schema, protocol sections, SKILL anchors, wiring). **docker-integration** (docker compose v2, SKIP loudly when absent): AC1 (collector half), AC2, AC4, AC5, AC6, AC8, AC9, AC-S2 (collector half). **llm-manual** (full skill run; captured as `zuvo/proofs/` artifacts at execute Phase Final): AC-S1, AC-S3, SMOKE1, SMOKE2, plus the skill-level halves of AC1/AC2/AC9/AC-S2.

CQ gates active on the collector: CQ3 (arg validation), CQ5 (IC-5 redaction = critical), CQ6/CQ7 (IC-9 bounded find/timeouts/wall-clock), CQ8 (IC-8 SSH flags, sanity markers, never-hang), CQ12 (timeouts as named constants), CQ14 (single `SSH_OPTS` / `SED_REDACT` constants). Q-gates that matter for shell asserts: Q7 (error paths: unreachable, bad args, dead proxy), Q11 (branches: dry-run/live, proxy/none, sudo/no-sudo, tool present/absent), Q13 (tests invoke `$ROOT_DIR/scripts/infra-collect.sh` directly), Q15 (jq asserts on values, not file-exists).

Top risks the plan encodes: (1) AC8 known_hosts poison MUST run under isolated `HOME=$(mktemp -d)` — never the real `~/.ssh` (Task 6); (2) docker tests SKIP (exit 0 + message) when docker absent (Task 1 helper guard); (3) seed-manifest drift → manifest embeds Dockerfile sha256 + static grep of each seeded value (Task 1); (4) jq assembly under `set -e` → per-check defensive `|| status=error` capture, tested with malformed tool output (Task 6); (5) nuclei tag allowlist asserted positively AND negatively (Task 7); (6) wall-clock guard uses `$SECONDS` + `WALL_CLOCK_LIMIT_S` test override (Task 6); (7) analyst-pipeline contract drift → Task 8 depends on the finalized bundle (Task 7) and Task 9 spikes one analyst on a real bundle before full SKILL.md authoring.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| AC1 | Fleet continuity (unreachable host doesn't abort) | requirement | Task 5 (collector half), Task 11 (skill-level via SMOKE1 harness) | skill loop is LLM-run at execute Phase Final |
| AC2 | Authorization gate precedes any connection | requirement | Task 2 (protocol), Task 9 (SKILL gate), Task 11 (harness check) | llm-manual half |
| AC3 | `--dry-run` emits no mutating commands | requirement | Task 4, Task 7 (nuclei tags) | static-assert |
| AC4 | No-sudo → `insufficient-data`, never ok | requirement | Task 5 | docker-integration |
| AC5 | Secret redaction total | requirement | Task 5 | docker-integration |
| AC6 | No CVE without tool evidence | requirement | Task 5 (collector emits none), Task 8 (agents IC-6 language), Task 9 (Phase 3 grep gate — explicit proof) | |
| AC7 | Collector standalone + schema-valid bundle | requirement | Task 4 (skeleton), Task 5 (full) | |
| AC8 | Host-key mismatch halts host, CRITICAL, phase0.json | requirement | Task 6 | TEST_HOME isolation mandatory |
| AC9 | DEGRADED coverage labeled structurally | requirement | Task 5/6 (bundle fields), Task 9 (report header) | |
| AC10 | Canonical output dir + consistent wiring/counts | requirement | Task 10 | static-assert |
| AC-S1 | ≥7/10 seeded issues detected | success | Task 1 (seed manifest), Task 9 (spike pre-read), Task 11 (scorecard harness) | llm-manual |
| AC-S2 | quick <3 min, full <15 min | success | Task 5 (collector half), Task 11 (skill-level timing — explicit proof) | |
| AC-S3 | ≤3 findings on hardened fixture | success | Task 1 (hardened fixture), Task 11 | llm-manual |
| SMOKE1 | Fleet audit end-to-end | requirement | Task 11 (+ Task 5 RED carries mocked e2e slice per rule 8b) | |
| SMOKE2 | Interrupt + resume round-trip | requirement | Task 11 (+ Task 9 resume-semantics anchors) | |
| D-IC | IC-1..IC-9 contracts encoded once, cited not restated | constraint | Tasks 2, 3, 4, 5, 6, 7, 9 | contract tests grep anchors |
| D-WIRE | Router/severity/output-location/install/manifests=54 | deliverable | Task 10 | |

## Review Trail

- Plan reviewer: revision 1 → ISSUES FOUND (7 items: T10 missing T7 dep; E10/E11/E12/DD-2 assertions absent; IC-7 positive/negative split; IC-3 stale-mismatch anchor). All fixed in revision 2.
- Plan reviewer: revision 2 → APPROVED (all 7 rev-1 fixes verified present; no new inconsistencies; DAG re-linted clean)
- Cross-model validation: partial (1/3 providers — cursor-agent returned; gemini timed out, codex-5.3 empty; reduced coverage). Findings on revision 2: 1 CRITICAL (LLM-pipeline de-risking deferred entirely to final task) + 5 WARNING + 1 INFO. Disposition in revision 3: CRITICAL → analyst-pipeline spike step added inside Task 9 (before full SKILL.md authoring); W1 → Task 8 (agents) now depends on Task 7 (finalized bundle incl. statuses/vantage); W2 → old Task 5 split into Task 5 (core live collection) + Task 6 (failure hardening), each with its own RED suite; W3 → explicit AC6 Phase-3 proof added to Task 9 and AC-S2 skill-level proof added to Task 11; W4 → all Verify steps strengthened with concrete expected predicates beyond `exit 0`; W5 → `[MODE SWITCH]` degraded-dispatch anchor added to Task 9 RED. INFO (Task 10 wiring size) → retained as one atomic task with justification; noted, no change. A second adversarial pass was not run: the two alternative providers were unavailable this run (timeout/empty), so `--exclude-last cursor-agent` would leave zero working providers.
- Plan reviewer: revision 3 → APPROVED (all 7 adversarial dispositions verified; renumber sweep clean: 11 tasks, 6 complex/5 standard, no dangling references; DAG re-linted clean)
- Status gate: Approved (user, 2026-06-11)

## Task Breakdown

### Task 1: Docker fixture spike — sshd containers, SOCKS proxy, seed manifest

**Files:** `tests/infra-suite/fixtures/docker-compose.yml`, `tests/infra-suite/fixtures/sshd-misconfigured/Dockerfile`, `tests/infra-suite/fixtures/sshd-misconfigured/sshd_config`, `tests/infra-suite/fixtures/sshd-hardened/Dockerfile`, `tests/infra-suite/fixtures/sshd-hardened/sshd_config`, `tests/infra-suite/fixtures/hosts-3.yaml`, `tests/infra-suite/fixtures/seed-manifest.md`, `tests/infra-suite/lib/docker-guard.sh`, `tests/infra-suite/test-infra-fixtures.sh` (fixture/data files don't count toward the 5-file boundary; production-equivalent files = compose + guard + test)
**Surface:** integration
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

This is the rule-14 feasibility spike: the repo has NO docker precedent; everything downstream (AC1/2/4/5/8, smoke) depends on these containers working.

- [ ] RED: write `tests/infra-suite/test-infra-fixtures.sh` (sources `tests/seo-suite/assert.sh` + new `lib/docker-guard.sh`). Asserts: compose config parses (`docker compose config -q`); both sshd containers build + start; `ssh -o BatchMode=yes -i <test-key> -p <mapped-port> audituser@127.0.0.1 true` succeeds against BOTH; misconfigured container has `PermitRootLogin yes` + `PasswordAuthentication yes` reachable via `sshd -T`; hardened container rejects root login; SOCKS proxy answers on 1080; every seeded value listed in `seed-manifest.md` greps in the fixture sources (drift gate); seed-manifest contains `# Dockerfile-sha256:` line matching `shasum -a 256` of the misconfigured Dockerfile. `docker-guard.sh` provides the SKIP guard: `command -v docker || { echo "SKIP: docker not available"; exit 0; }` + compose-v2 check. Test fails initially: no fixtures exist.
- [ ] GREEN: author fixtures. Misconfigured: `ubuntu:24.04` (pinned digest) + openssh-server + sudo + lynis preinstalled; sshd_config with the 10 seeded issues from spec AC-S1 (PermitRootLogin yes; PasswordAuthentication yes; no firewall; world-writable cron dir; `/opt/app/.env` with 5 known secret values; redis bound 0.0.0.0 no auth (config file present); stale-package marker; container runs as root; SUID copy of /bin/sh; no fail2ban); two users: `audituser` (passwordless sudo) and `nosudo` (no sudo) for AC4. Hardened: key-only, root login off, no exposed extras. `serjs/go-socks5-proxy` pinned by digest. `hosts-3.yaml` lists both containers (127.0.0.1 + mapped ports, per-host ssh_user/ssh_key) + one black-hole address (`192.0.2.1` TEST-NET — guaranteed unroutable) + `defaults.proxy: socks5://127.0.0.1:1080`. `seed-manifest.md` documents each seeded issue: id, dimension (IS#), fixture location, expected detection source.
- [ ] Verify: `bash tests/infra-suite/test-infra-fixtures.sh; echo "exit=$?"`
  Expected: `exit=0`; on docker hosts the output contains a PASS line for EACH of: compose-config, both ssh logins, misconfigured `permitrootlogin yes`, hardened root-rejection, proxy:1080, 10/10 seed greps, Dockerfile-sha match (≥16 PASS lines, zero FAIL); on dockerless hosts exactly one `SKIP: docker not available` line and `exit=0`
- [ ] Acceptance Proof:
  - AC-S1 (fixture leg):
    - Surface: integration
    - Proof: `grep -c '^| IS' tests/infra-suite/fixtures/seed-manifest.md` lists 10 seeded issues; for each, the documented literal value greps in its fixture source file; `shasum -a 256 tests/infra-suite/fixtures/sshd-misconfigured/Dockerfile` matches the manifest's recorded hash.
    - Expected: 10 rows; 10/10 greps hit; hash equal.
    - Artifact: `zuvo/proofs/task-1-ACS1-fixtures.txt`
  - AC-S3 (fixture leg):
    - Surface: integration
    - Proof: hardened container starts; `ssh ... root@... true` is rejected; `sshd -T` shows `permitrootlogin no` + `passwordauthentication no`.
    - Expected: root rejected; both directives present.
    - Artifact: `zuvo/proofs/task-1-ACS3-fixtures.txt`
- [ ] Commit: `add infra-suite docker fixtures: seeded-misconfigured + hardened sshd containers, SOCKS proxy, 3-host inventory, drift-gated seed manifest`

### Task 2: ssh-probe-protocol.md shared include

**Files:** `shared/includes/ssh-probe-protocol.md`, `tests/infra-suite/test-infra-protocol.sh`
**Surface:** docs
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: write `tests/infra-suite/test-infra-protocol.sh`: asserts file exists; all 6 normative section headers present (`Authorization Gate`, `SSH invariants`, `Privilege probe`, `Key-material ban`, `Host-key mismatch rule`, `Rate & timing rules`); IC-8 flag string verbatim (`-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes -o StrictHostKeyChecking=yes`); contains `--confirm-targets`; contains `privilege_mode` values `root|passwordless-sudo|limited-sudo|no-sudo`; states `[AUTO-DECISION]` never applies to target authorization; states `StrictHostKeyChecking` never disabled. Fails: file missing.
- [ ] GREEN: write the include per the spec's "ssh-probe-protocol.md section contract", structurally mirroring `shared/includes/live-probe-protocol.md` (title + blockquote + numbered sections, tables where applicable). Content sources: spec IC-8, DD-3, DD-10, E1-E5, `--confirm-targets` contract. This file is the runtime carrier of IC-8 for skill + agents.
- [ ] Verify: `bash tests/infra-suite/test-infra-protocol.sh; echo "exit=$?"`
  Expected: `exit=0` with a PASS line for each of the 9 assertion groups above (6 sections + IC-8 string + confirm-targets + privilege/auto-decision/strict-hostkey rules), zero FAIL lines
- [ ] Acceptance Proof:
  - AC2 (protocol leg):
    - Surface: docs
    - Proof: `grep -A3 'Authorization Gate' shared/includes/ssh-probe-protocol.md` shows host→IP→PTR display + explicit-confirm + block-on-decline + `--confirm-targets <sha256>` non-interactive rule.
    - Expected: all four elements present in section 1.
    - Artifact: `zuvo/proofs/task-2-AC2.txt`
- [ ] Commit: `add ssh-probe-protocol include: authorization gate, IC-8 SSH invariants, privilege probe, key-material ban as normative 6-section contract`

### Task 3: infra-check-registry.md shared include

**Files:** `shared/includes/infra-check-registry.md`, `tests/infra-suite/test-infra-registry.sh`
**Surface:** docs
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: write `tests/infra-suite/test-infra-registry.sh`: asserts header row is exactly `| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |`; ≥1 row for EVERY dimension IS1-IS12; every `check_id` matches `^IS([1-9]|1[0-2])-[a-z0-9-]+$`; every `default_severity` ∈ {CRITICAL,HIGH,MEDIUM,LOW}; no duplicate check_ids; contains the lynis default mapping note (`WARNING→MEDIUM`, `SUGGESTION→LOW`). Fails: file missing.
- [ ] GREEN: write the registry (~40 rows across IS1-IS12; format modeled on `geo-check-registry.md`). Each row: registry id matching `bundle.checks[].id` namespace, dimension, severity per spec DD-7, lynis test id or `-`, paste-ready remediation, CIS ref or `-`. Include the spec's example row `IS1-sshd-permitrootlogin | IS1 | CRITICAL | SSH-7408 | ... | CIS 5.2.8` verbatim. Preamble states the column order is normative (parsed by Phase 3 + analysts) and escalation above MEDIUM for lynis findings requires an explicit row.
- [ ] Verify: `bash tests/infra-suite/test-infra-registry.sh; echo "exit=$?"`
  Expected: `exit=0`; output reports the exact header match, `12/12 dimensions covered`, `0 duplicate check_ids`, `0 invalid severities`, zero FAIL lines
- [ ] Acceptance Proof:
  - D-IC (registry contract):
    - Surface: docs
    - Proof: registry test output + `grep -c '| IS' shared/includes/infra-check-registry.md` ≥ 40 across 12 dimensions.
    - Expected: schema test green; per-dimension coverage complete.
    - Artifact: `zuvo/proofs/task-3-DIC-registry.txt`
- [ ] Commit: `add infra-check-registry: normative check_id→severity→remediation→CIS mapping for IS1-IS12 with lynis severity defaults`

### Task 4: infra-collect.sh — CLI skeleton, preflight, dry-run, bundle writer

**Files:** `scripts/infra-collect.sh`, `tests/infra-suite/test-infra-collector-cli.sh`
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: write `tests/infra-suite/test-infra-collector-cli.sh` (no docker needed): missing `--host` → exit 1 + usage on stderr; malformed `--host` (`nouser`, `user@`) → exit 1; `--out` into unwritable parent → exit 1 before any connection; jq-absence gate present (grep for the `command -v jq` hard gate); `--dry-run --host u@192.0.2.1 --out /tmp/x.json` exits 0, prints every command it WOULD run, attempts zero connections (assert via `time` bound <2s and no `ssh` child), and the printed list greps clean of mutating patterns (`apt install|apt-get install|sysctl -w|chmod |chown |rm |mv |tee |> /etc`) after filtering lines targeting `/tmp/zuvo-`; every printed `ssh` line contains the full IC-8 flag string; every `find` line contains `-xdev`; static greps on the script: `SSH_OPTS=` constant defined once and interpolated (no duplicated flag literals), named timeout constants (`CHECK_TIMEOUT_S`, `TRIVY_TIMEOUT_S`, `CONNECT_TIMEOUT_S`, `WALL_CLOCK_LIMIT_S`), `SED_REDACT` constant. Fails: script missing.
- [ ] GREEN: create `scripts/infra-collect.sh` (`#!/usr/bin/env bash`, `set -euo pipefail`): while/case arg parsing for `--host user@addr[:port] --out <path> [--dry-run] [--no-install] [--run-id <id>] [--proxy <url>] [--quick] [--dimensions <list>] [--deep-scan] [--skip-external] [--external direct]`; CQ3 validation; jq gate (benchmark.sh line 426 pattern); constants block (CQ12/CQ14); command-dispatch layer where EVERY remote command flows through one `run_remote()` function that (a) in dry-run prints instead of executes, (b) always applies `$SSH_OPTS`, (c) wraps >30s commands in the nohup pattern (IC-8); bundle-writer producing the IC-3 skeleton (`host`, `collected_at` from `--run-id`/caller, `privilege_mode`, `tool_availability` incl. grype, `tools_installed_this_run`, `checks[]`, `external.vantage`); `phase0.json` writer (status, reason, stderr evidence) for preflight failures. No live check implementations yet — checks emit `skipped` placeholders in this task.
- [ ] Verify: `bash tests/infra-suite/test-infra-collector-cli.sh; echo "exit=$?"`
  Expected: `exit=0`; output reports PASS for each of: 3 invalid-arg rejections, jq-gate grep, dry-run zero-connection bound, 0 mutating-command matches, IC-8-flags-on-every-ssh-line, `-xdev`-on-every-find-line, all 5 named constants present; zero FAIL lines
- [ ] Acceptance Proof:
  - AC3:
    - Surface: config
    - Proof: `scripts/infra-collect.sh --dry-run --no-install --host u@192.0.2.1 --out /tmp/b.json | grep -vE '/tmp/zuvo-' | grep -cE 'apt(-get)? install|sysctl -w|chmod |chown |rm |mv |tee |> /etc'`
    - Expected: count 0; exit 0; consent-install block absent entirely under `--no-install`.
    - Artifact: `zuvo/proofs/task-4-AC3.txt`
  - AC7 (skeleton leg):
    - Surface: backend-logic
    - Proof: dry-run bundle skeleton validated by jq for required keys `host, privilege_mode, tool_availability, checks` and check ids matching `^IS([1-9]|1[0-2])-`.
    - Expected: jq assertions exit 0.
    - Artifact: `zuvo/proofs/task-4-AC7.txt`
- [ ] Commit: `add infra-collect.sh skeleton: validated CLI, single run_remote dispatch with IC-8 flags, dry-run path, IC-3 bundle/phase0 writers`

### Task 5: infra-collect.sh — core live collection (probes, battery, redaction, unreachable)

**Files:** `scripts/infra-collect.sh` (extend), `tests/infra-suite/test-infra-collector-live.sh`
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 1, Task 4 (same file as Tasks 4/6/7 — serialized per rule 13)
**Execution routing:** deep implementation tier

- [ ] RED: write `tests/infra-suite/test-infra-collector-live.sh` (docker-guarded). Scenarios: (a) IC-7 positive path: full run vs misconfigured fixture → bundle valid per IC-3 jq schema, `privilege_mode: passwordless-sudo`, lynis output contains `Hardening index` marker AND that check is NOT `error`; (b) run as `nosudo` user → every `needs_sudo==true` check has status `insufficient-data`, none `ok` (AC4); (c) the 5 seeded secret values grep to ZERO hits across bundle+report dir while `[REDACTED]` markers present (AC5); (d) black-hole host `192.0.2.1` → `phase0.json` with `UNREACHABLE`, exit 0, <10s (AC1 collector half, nc preflight); (e) `--no-install` on fixture missing trivy → affected checks `status: skipped`, `tool_availability.trivy: null` (AC9 bundle leg, AC6: grep bundle+raw for `CVE-` = 0). This RED doubles as the rule-8b mocked end-to-end smoke slice for SMOKE1 (single-host collect→bundle path).
- [ ] GREEN: implement the core internal check battery in `run_remote()` terms: privilege probe (`sudo -n true`), tool probe (`which lynis nmap trivy grype debsecan needrestart docker ss`), consent-install hook (skipped under `--no-install`), lynis `--cronjob` via nohup + `.dat` retrieval + awk/python3 parser, `sshd -T`, `ss -tulpn`, loopback nmap (`--top-ports 1000`, `-p-` under `--deep-scan`), sysctl/ufw/iptables reads, debsecan/needrestart, docker inspect + trivy (`--timeout 120s --skip-update`), pg/mysql/redis config reads, bounded `find` (`-xdev` + prune `/proc /sys /run`) for IS11/IS12; IC-5 `SED_REDACT` applied BEFORE every bundle/raw write; per-check `timeout $CHECK_TIMEOUT_S`; incremental bundle writes (resume-safe).
- [ ] Verify: `bash tests/infra-suite/test-infra-collector-live.sh; echo "exit=$?"`
  Expected: `exit=0`; output reports PASS for each scenario (a)-(e), including `secrets: 0/5 found`, `phase0: UNREACHABLE`, `needs_sudo: all insufficient-data`; zero FAIL lines (or single SKIP on dockerless hosts)
- [ ] Acceptance Proof:
  - AC4: Surface: integration | Proof: `jq '[.checks[] | select(.needs_sudo==true) | .status] | unique' bundle.json` on the nosudo run | Expected: `["insufficient-data"]` and report header `privilege_mode: no-sudo` | Artifact: `zuvo/proofs/task-5-AC4.json`
  - AC5: Surface: integration | Proof: `grep -rcF "<each-seeded-secret>" <run-dir>` per the 5 manifest values | Expected: 0/5 hits; `[REDACTED]` present | Artifact: `zuvo/proofs/task-5-AC5.txt`
  - AC1 (collector half): Surface: integration | Proof: black-hole run → `jq .status bundle/<host>.phase0.json` | Expected: `UNREACHABLE`, exit 0 | Artifact: `zuvo/proofs/task-5-AC1.txt`
  - AC6 (collector leg): Surface: integration | Proof: `grep -rc 'CVE-' <run-dir>` after `--no-install` run without scanners | Expected: 0 | Artifact: `zuvo/proofs/task-5-AC6.txt`
  - AC-S2 (collector half): Surface: integration | Proof: `time` quick-mode collect on fixture | Expected: <180s | Artifact: `zuvo/proofs/task-5-ACS2.txt`
- [ ] Commit: `implement infra-collect core live collection: privilege/tool probes, lynis/nmap/trivy battery with IC-7 positive path, IC-5 redaction-before-write, unreachable-host phase0 capture`

### Task 6: infra-collect.sh — failure hardening (host-key, malformed output, wall-clock, old lynis)

**Files:** `scripts/infra-collect.sh` (extend), `tests/infra-suite/test-infra-collector-hardening.sh`
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 1, Task 5 (same file — serialized per rule 13)
**Execution routing:** deep implementation tier

- [ ] RED: write `tests/infra-suite/test-infra-collector-hardening.sh` (docker-guarded; **sets `HOME=$(mktemp -d)` with trap cleanup — `# SAFETY` header comment; collector must honor `$HOME` for known_hosts — never the real `~/.ssh`**). Scenarios: (a) poisoned known_hosts for the fixture (in TEST_HOME) → `phase0.json` reason `host-key-mismatch`, zero post-handshake commands in container auth log (AC8); (b) IC-7 negative path: a probed command returns truncated/garbage output → that check `error` with `raw_ref`, bundle still valid JSON (defensive-jq under `set -e`); (c) `WALL_CLOCK_LIMIT_S=1` env override → remaining checks `skipped (wall-clock)` (IC-9, `$SECONDS`-based); (d) E12: PATH-shimmed `lynis --version` returning `2.6.x` → `tool_availability.lynis` records the version and lynis-sourced checks degrade with `DEGRADED (lynis 2.6.x < 3.0)` notation, manual-fallback checks still populate.
- [ ] GREEN: implement the hardening paths: host-key-mismatch detection from ssh stderr (`REMOTE HOST IDENTIFICATION HAS CHANGED`) → phase0.json fail-fast; per-check defensive capture `|| status=error` around every parser so one malformed output never aborts the bundle; `$SECONDS`-based wall-clock guard honoring `WALL_CLOCK_LIMIT_S` (test-only override documented in a comment); lynis version probe → `< 3.0` triggers the manual-fallback battery + DEGRADED notation.
- [ ] Verify: `bash tests/infra-suite/test-infra-collector-hardening.sh; echo "exit=$?"`
  Expected: `exit=0`; output reports PASS for scenarios (a)-(d) including `host-key-mismatch: fail-fast confirmed`, `bundle valid after malformed input`, `wall-clock skips applied`, `lynis 2.6.x → DEGRADED`; zero FAIL lines (or single SKIP on dockerless hosts)
- [ ] Acceptance Proof:
  - AC8: Surface: integration | Proof: poisoned TEST_HOME known_hosts run → `jq .reason bundle/<host>.phase0.json` + fixture auth-log grep | Expected: `host-key-mismatch`; no post-handshake commands | Artifact: `zuvo/proofs/task-6-AC8.txt`
  - AC9 (degradation leg): Surface: integration | Proof: lynis-2.6 shim run → `jq .tool_availability.lynis bundle.json` + grep `DEGRADED (lynis` in the bundle notes | Expected: version recorded, DEGRADED notation present | Artifact: `zuvo/proofs/task-6-AC9.txt`
  - D-IC (IC-9 wall-clock): Surface: integration | Proof: `WALL_CLOCK_LIMIT_S=1` run → `jq '[.checks[] | select(.status=="skipped") | .id] | length' bundle.json` | Expected: >0 skipped with wall-clock notation; bundle valid | Artifact: `zuvo/proofs/task-6-DIC-wallclock.txt`
- [ ] Commit: `harden infra-collect: host-key fail-fast, defensive per-check error capture, SECONDS wall-clock guard, lynis<3.0 degradation path`

### Task 7: infra-collect.sh — external vantage via proxy

**Files:** `scripts/infra-collect.sh` (extend), `tests/infra-suite/test-infra-collector-external.sh`
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 1, Task 6 (same file — serialized per rule 13)
**Execution routing:** deep implementation tier

- [ ] RED: write `tests/infra-suite/test-infra-collector-external.sh` (docker-guarded): (a) dry-run with `--proxy socks5://127.0.0.1:1080` prints `proxychains`-wrapped nmap (`-sT`) and testssl lines and `nuclei ... -proxy socks5://127.0.0.1:1080`; nuclei line contains EXACTLY `-tags exposures,misconfiguration,technologies,ssl,dns` AND `-exclude-tags intrusive,dos,fuzz,bruteforce,default-login`; negative asserts: no `-tags intrusive`, no bare nuclei without the allowlist (both directions); (b) live: with the SOCKS fixture up → `jq .external.vantage bundle.json` = `proxy`; (c) dead proxy (stopped container) → `vantage` = `failed`, internal checks unaffected; (d) no proxy + `--skip-external` → `vantage` = `none`; (e) proxychains-ng absent (PATH-masked) → `vantage` = `none` + preflight warning printed (IC-4). Fails: external leg unimplemented.
- [ ] GREEN: implement external leg per IC-4: proxy resolution order `--proxy` > hosts-yaml default (passed by caller) > `$ZUVO_SCAN_PROXY`; proxychains-ng wrapper for nmap `-sT` + testssl.sh (NEVER testssl native `--proxy` with SOCKS); nuclei native `-proxy` with the pinned tag allowlist as a named constant; `--external direct` path with `-T2 --max-rate 50` + abort threshold (3 consecutive refused → stop external, per DD-4); `external.vantage` enum `proxy|direct|none|failed` written per IC-3/IC-4.
- [ ] Verify: `bash tests/infra-suite/test-infra-collector-external.sh; echo "exit=$?"`
  Expected: `exit=0`; output reports PASS for scenarios (a)-(e) including the exact-allowlist match, all 5 excluded-tag negative asserts, and the vantage triple `proxy`/`failed`/`none`; zero FAIL lines (or single SKIP on dockerless hosts)
- [ ] Acceptance Proof:
  - AC3 (nuclei-tags leg): Surface: config | Proof: dry-run grep positive allowlist + negative excluded tags as in RED (a) | Expected: exact-match allowlist present, all 5 excluded tags absent | Artifact: `zuvo/proofs/task-7-AC3-nuclei.txt`
  - D-IC (IC-4 vantage contract): Surface: integration | Proof: three runs (proxy up / proxy dead / skip-external) → `jq .external.vantage` | Expected: `proxy` / `failed` / `none` | Artifact: `zuvo/proofs/task-7-DIC-vantage.txt`
- [ ] Commit: `add external vantage leg: proxychains nmap+testssl, nuclei pinned safe-tag allowlist, vantage enum with dead-proxy degradation`

### Task 8: Four analyst agent files

**Files:** `skills/infra-audit/agents/host-analyst.md`, `skills/infra-audit/agents/network-analyst.md`, `skills/infra-audit/agents/container-analyst.md`, `skills/infra-audit/agents/data-analyst.md`, `tests/infra-suite/test-infra-agents.sh`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 3 (agents cite the registry), Task 7 (agents encode jq contracts over the finalized bundle shape produced by the collector chain)
**Execution routing:** default implementation tier

- [ ] RED: write `tests/infra-suite/test-infra-agents.sh`: for each of the 4 files — exists; frontmatter has `name`, `model: sonnet`, `tools:` containing `Read` and `Bash`; body references `infra-check-registry.md` and `agent-preamble.md`; declares EXACTLY its assigned dimensions (host: IS1,IS2,IS5,IS6,IS7,IS11; network: IS3,IS4,IS8; container: IS9; data: IS10,IS12) and no other agent's; contains the grounding rule (`bundle.checks[].id` citation required, ungrounded findings rejected); contains the IC-6 rule (no CVE unless verbatim in raw tool output); data-analyst contains the E14 pgdsat dual-consent note; network-analyst contains the internal/external diff + `external.vantage` semantics (all four enum values). Fails: files missing.
- [ ] GREEN: write the 4 agents on the geo-audit agent template: role, input contract (path to `bundle/<host>.json` + its layer's check slice via jq), analysis procedure per dimension, output contract (`findings/<host>-<layer>.json`: array of `{check_id, severity_proposal, title, evidence, remediation_ref}` + `bundle_sha256`), hard rules (grounding, IC-6, severity only proposed — registry decides, never read `raw/`). jq examples in the agents use the REAL bundle fields shipped by Tasks 4-7 (status enum incl. `insufficient-data`/`skipped (wall-clock)`, `external.vantage` incl. `failed`).
- [ ] Verify: `bash tests/infra-suite/test-infra-agents.sh; echo "exit=$?"`
  Expected: `exit=0`; output reports `4/4 agents present`, `dimension assignment disjoint and complete (12/12)`, `grounding rule: 4/4`, `IC-6 rule: 4/4`; zero FAIL lines
- [ ] Acceptance Proof:
  - AC6 (agent leg): Surface: docs | Proof: `grep -l 'verbatim' skills/infra-audit/agents/*.md | wc -l` — IC-6 no-CVE-without-evidence rule present in all 4 | Expected: 4 | Artifact: `zuvo/proofs/task-8-AC6-agents.txt`
- [ ] Commit: `add 4 infra-audit analyst agents with disjoint IS-dimension assignments, bundle-grounding rule, and IC-6 CVE evidence rule`

### Task 9: skills/infra-audit/SKILL.md orchestrator (with analyst-pipeline spike)

**Files:** `skills/infra-audit/SKILL.md`, `tests/infra-suite/test-infra-skill-contract.sh`
**Surface:** docs
**Complexity:** complex
**Dependencies:** Task 2, Task 3, Task 7 (documents final collector flag surface), Task 8 (dispatches the agents; spike step runs one of them)
**Execution routing:** deep implementation tier

- [ ] SPIKE (always-run gate, rule 15 — execute FIRST, before GREEN): de-risk the LLM half of the pipeline. With Task 1 fixtures up, produce a real bundle via `infra-collect.sh` against the misconfigured container, then dispatch ONE analyst (host-analyst from Task 8) on it and run a minimal aggregation by hand: validate the findings JSON parses, every finding cites an existing `bundle.checks[].id`, `bundle_sha256` matches, and ≥1 seeded IS1/IS2 issue from `seed-manifest.md` surfaces as a finding. Print `[SPIKE: analyst-pipeline PASS]` or `[SPIKE: FAIL <reason>]` — on FAIL, fix the agent/bundle contract BEFORE writing the full SKILL.md. Artifact: `zuvo/proofs/task-9-spike.txt`.
- [ ] RED: write `tests/infra-suite/test-infra-skill-contract.sh`: frontmatter `name: infra-audit` + description listing all flags (`--host`, `--quick`, `--dimensions`, `--no-install`, `--dry-run`, `--resume`, `--proxy`, `--external direct`, `--skip-external`, `--deep-scan`, `--confirm-targets`); two-stage loading block with Stage 1 = env-compat, no-pause-protocol, infra-check-registry, ssh-probe-protocol and Stage 2 = backlog-protocol, run-logger, retrospective, report-output-location; Phase 0-3 section headers; authorization-gate section citing ssh-probe-protocol §1; dispatch block referencing all 4 `agents/*.md` AND the degraded-dispatch fallback anchor (`grep -q 'MODE SWITCH'` + `single-agent`); resume-semantics table with all 6 statuses incl. `bundle_sha256` stale-findings guard AND the mismatch rule (`grep -q 'mismatch.*forces re-analysis\|bundle_sha256.*mismatch'` — the mismatch→re-analysis behavior itself is llm-manual, exercised at SMOKE2); Phase 3 anchors: `UNGROUNDED-FINDING`, IC-6 CVE grep gate (`grep -q 'CVE-EVIDENCE-MISSING\|CVE.*grep gate\|CVE.*raw/'`), fleet-summary-written-LAST; IC-1 `ZUVO_DIR` resolution line; `coverage_mode: DEGRADED` labeling; E10 Alpine branch present (`grep -q 'alpine-release' && grep -q 'apk '`); E11 duplicate-IP dedup present (`grep -qi 'duplicate IP'` + merge/WARN language); DD-2 first-run scaffold present (`grep -qi 'scaffold'` near `hosts.yaml`); Tool Availability Block template; `Run:` line template + append-runlog wrapper; VALIDITY GATE block; retro-marker bash block. Fails: file missing.
- [ ] GREEN: write SKILL.md (~850-1000 lines; canonical structure from `skills/build/SKILL.md`, two-stage loading from pentest lines 86-114, dispatch from geo-audit lines 275-334, rate-limit fallback per env-compat incl. the `[MODE SWITCH] dispatch rate-limited ×2 → single-agent` rule). Encodes the spec's Phase 0-3 flow: argument parsing table; authorization gate (interactive + `--confirm-targets` non-interactive, abort on mismatch); gitignore preflight (DD-10); first-run `zuvo/infra/hosts.yaml` scaffold (DD-2); per-host probe sequence incl. duplicate-IP merge + `[WARN]` (E11) and Alpine detection → apk path, skip lynis (E10); consent gates (DD-3 + E14 pgdsat dual consent); collector invocation contract (`{plugin_root}/scripts/infra-collect.sh` with glob fallback path); Phase 2 dispatch (parallel, inline fallback) with the IC-3 `bundle_sha256` mismatch→re-analysis rule; Phase 3 deterministic aggregation rules incl. the IC-6 grep gate over `raw/` with `CVE-EVIDENCE-MISSING` rejection logging; edge-case table E1-E15 condensed; report templates (per-host header with `privilege_mode`/`coverage_mode`/vantage, fleet summary); state.json + resume; completion gates (retro → runlog → Run block).
- [ ] Verify: `bash tests/infra-suite/test-infra-skill-contract.sh; echo "exit=$?"`
  Expected: `exit=0`; output reports PASS for every anchor group: 11 flags, 4+4 stage includes, 4 phase headers, 4 agent refs + MODE SWITCH anchor, 6 resume statuses + mismatch rule, 3 Phase-3 anchors, E10/E11/DD-2 anchors, output/validity/run-line blocks; zero FAIL lines
- [ ] Acceptance Proof:
  - AC2 (skill leg): Surface: docs | Proof: grep the SKILL.md gate section — host→IP→PTR table, explicit confirm, decline → zero connections, `--confirm-targets` abort-on-mismatch | Expected: all four anchors present before any Phase 1 instruction | Artifact: `zuvo/proofs/task-9-AC2.txt`
  - AC6 (Phase 3 gate leg): Surface: docs | Proof: grep SKILL.md Phase 3 for the IC-6 enforcement: every CVE string in candidate findings is grepped against `raw/` tool output; misses are dropped + logged `CVE-EVIDENCE-MISSING` | Expected: both the grep-gate instruction and the rejection log marker present | Artifact: `zuvo/proofs/task-9-AC6-gate.txt`
  - AC9 (report leg): Surface: docs | Proof: grep report-template section for `coverage_mode: DEGRADED` + per-dimension fallback notes + Tool Availability Block | Expected: all present | Artifact: `zuvo/proofs/task-9-AC9.txt`
  - SMOKE2 (semantics leg): Surface: docs | Proof: grep resume table for all 6 statuses and `bundle_sha256` guard | Expected: 6 rows + guard | Artifact: `zuvo/proofs/task-9-SMOKE2-anchors.txt`
- [ ] Commit: `add zuvo:infra-audit orchestrator: 4-phase pipeline with authorization gate, consent-gated installs, parallel analysts with degraded-dispatch fallback, deterministic aggregation and resume (spiked against live fixture bundle)`

### Task 10: Wiring — router, vocab, output-location, install.sh, manifest counts

**Files:** `skills/using-zuvo/SKILL.md`, `shared/includes/severity-vocabulary.md`, `shared/includes/report-output-location.md`, `scripts/install.sh`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `package.json`, `docs/skills.md`, `tests/infra-suite/test-infra-wiring.sh`
**Surface:** config
**Complexity:** standard
**Dependencies:** Task 9 (routes to the skill; counts valid only after `skills/infra-audit/` exists)
**Execution routing:** default implementation tier

Oversized-by-count justification (rule 2): all eight edits are single-line additive changes that MUST land atomically — the whole point is count/row consistency across files; splitting reintroduces the 52/53/54 drift this task fixes. One test verifies all. (Adversarial INFO suggested reclassifying complex/splitting; retained as standard+atomic with this justification — each edit is a one-line additive row/count.)

- [ ] RED: write `tests/infra-suite/test-infra-wiring.sh`: routing row matching `zuvo:infra-audit` in using-zuvo Audit section + banner contains `54 skills`; severity-vocabulary has an `infra-audit` row mapping CRITICAL/HIGH/MEDIUM/LOW→S1/S2/S3/S4 (identical shape to security-audit row); report-output-location `audits/` writers line contains `infra-audit`; install.sh contains `infra-collect.sh` in BOTH the Codex and the Cursor named-copy blocks; the skill-count integers extracted from `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `package.json`, `docs/skills.md` (both places), and the using-zuvo banner are ALL equal to `ls skills/ | wc -l`. Fails on current state (counts 52/53/54, rows missing).
- [ ] GREEN: apply the eight single-line edits (counts → 54; new rows; two cp lines; docs/skills.md also gets the infra-audit table row in the Infra-audits category).
- [ ] Verify: `bash tests/infra-suite/test-infra-wiring.sh; echo "exit=$?"`
  Expected: `exit=0`; output reports PASS for: routing row, banner=54, severity row, writers row, 2 install.sh cp hits, and `counts: 6/6 equal to $(ls skills/ | wc -l)`; zero FAIL lines
- [ ] Acceptance Proof:
  - AC10:
    - Surface: docs
    - Proof: wiring test output; plus `git status --porcelain` after a fixture collector run shows no writes outside `zuvo/` except (at most) the one-time `.gitignore` append whose diff is exactly the `zuvo/` line.
    - Expected: all rows present; all counts equal; clean tree rule holds.
    - Artifact: `zuvo/proofs/task-10-AC10.txt`
  - D-WIRE: Surface: config | Proof: same test | Expected: exit 0 | Artifact: `zuvo/proofs/task-10-DWIRE.txt`
- [ ] Commit: `wire infra-audit: router row + banner, severity-vocabulary row, audits writers list, install.sh codex/cursor cp entries, reconcile all skill counts to 54`

### Task 11: Smoke harnesses + e2e driver (final task — authors the smoke runner artifacts)

**Files:** `tests/infra-suite/smoke-fleet-audit.sh`, `tests/infra-suite/smoke-resume.sh`, `tests/infra-suite/test-suite-e2e.sh`
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 1, Task 7, Task 8 (harness verifies the findings/bundle_sha256 structure the agents produce), Task 9, Task 10
**Execution routing:** default implementation tier

- [ ] RED: the smoke harnesses ARE the runnable proof artifacts (rule 8a). Run them before implementation: each must fail with a clear precondition message (no run-dir supplied / fixtures not up), exit 2 — proving they guard rather than vacuously pass. `test-suite-e2e.sh` listed-but-missing test files → driver reports them as FAIL.
- [ ] GREEN: `smoke-fleet-audit.sh <run-dir>`: docker-guarded; brings fixtures up; then VERIFIES a completed skill run's artifacts (the skill itself is invoked by the LLM at execute Phase Final, then this harness is pointed at the run dir): run dir matches IC-1 naming; per-host reports for both containers + `UNREACHABLE` entry for the black-hole host in fleet-summary; fleet-summary mtime newest (written last); bundles schema-valid; `findings/*.json` carry `bundle_sha256` matching `shasum` of their bundle; `external.vantage` = `proxy`; misconfigured host grade worse than hardened; `~/.zuvo/runs.log` tail contains an `infra-audit` line; zero seeded secrets grep in the run dir. `smoke-resume.sh <run-dir>`: verifies state.json all-final, exactly one fleet-summary, no duplicate per-host reports, `reported` hosts untouched (mtime) across the resumed run. `test-suite-e2e.sh`: geo-suite pattern (TOTAL_FAIL counter; SKIP≠FAIL) chaining all `test-infra-*.sh`.
- [ ] Verify: `bash tests/infra-suite/test-suite-e2e.sh; echo "exit=$?"`
  Expected: `exit=0`; per-test summary lists every `test-infra-*.sh` with PASS (or SKIP only for docker-dependent files on dockerless hosts); `TOTAL_FAIL=0`; both smoke harnesses, invoked without a run-dir, print their precondition usage and exit 2
- [ ] Acceptance Proof:
  - SMOKE1: Surface: integration | Proof: (at execute Phase Final) bring fixtures up → run the skill per SKILL.md against `tests/infra-suite/fixtures/hosts-3.yaml` with confirm → `bash tests/infra-suite/smoke-fleet-audit.sh <run-dir>` | Expected: harness exit 0, all invariants above hold | Artifact: `zuvo/proofs/smoke-fleet-audit.txt`
  - SMOKE2: Surface: integration | Proof: interrupt the run after host 1 `reported`, re-run with `--resume <run-dir>`, then `bash tests/infra-suite/smoke-resume.sh <run-dir>` | Expected: harness exit 0 | Artifact: `zuvo/proofs/smoke-resume.txt`
  - AC1 / AC-S1 / AC-S3 (skill-level legs): Surface: integration | Proof: same SMOKE1 run scored against `seed-manifest.md` (detection ≥7/10 on misconfigured; ≤3 findings none CRITICAL/HIGH on hardened; black-hole host UNREACHABLE with fleet continuing) | Expected: scorecard thresholds met | Artifact: `zuvo/proofs/infra-S1-scorecard.md`
  - AC-S2 (skill-level timing): Surface: integration | Proof: wall-clock the SMOKE1 run end-to-end (gate-wait excluded) and a `--quick` run of one fixture host; record both | Expected: quick < 180 s; full single-host segment < 900 s (per IC-9 nominal target; `--deep-scan` excluded) | Artifact: `zuvo/proofs/task-11-ACS2-timing.txt`
- [ ] Commit: `add infra smoke harnesses (fleet e2e + resume verification) and suite driver with docker SKIP semantics`

## Whole-feature Smoke Proofs

- **SMOKE1 — Fleet audit end-to-end on seeded fixtures**
  - Preconditions: docker compose v2; `tests/infra-suite/fixtures/` containers up (misconfigured + hardened sshd + SOCKS proxy); `tests/infra-suite/fixtures/hosts-3.yaml` (2 containers + 1 black-hole) ; proxy `socks5://127.0.0.1:1080`.
  - Proof: invoke `zuvo:infra-audit tests/infra-suite/fixtures/hosts-3.yaml`; confirm the gate; let collect → analyze → aggregate complete; then `bash tests/infra-suite/smoke-fleet-audit.sh <run-dir>`.
  - Expected: run dir per IC-1 with 2 host reports + fleet-summary (written last) + schema-valid bundles + sha-linked findings + state.json all-final; misconfigured grade worse than hardened; internal/external diff present with `vantage: proxy`; Run line in `~/.zuvo/runs.log`; retro entries written; zero seeded secrets in run dir.
  - Artifact: `zuvo/proofs/smoke-fleet-audit.txt`
- **SMOKE2 — Interrupt + resume round-trip**
  - Preconditions: SMOKE1 fixtures; a run killed after host 1 reaches `reported`.
  - Proof: re-invoke with `--resume <run-dir>`; then `bash tests/infra-suite/smoke-resume.sh <run-dir>`.
  - Expected: host 1 not re-collected (state `reported`, report mtime unchanged); host 2 completes; exactly one fleet-summary listing both + the unreachable host; no duplicate reports.
  - Artifact: `zuvo/proofs/smoke-resume.txt`

Rule 8b dual-allocation: SMOKE1's single-host collect→bundle slice runs (mocked, container-backed) inside Task 5's RED suite, and Task 9's SPIKE exercises the collect→analyst→aggregate slice on a live fixture bundle; SMOKE2's resume-semantics anchors are asserted in Task 9's RED contract test.
