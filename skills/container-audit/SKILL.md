---
name: container-audit
description: >
  Static Docker/container security audit across 6 dimensions (K1-K6): base image
  provenance and pinning, privilege and runtime hardening, secret and build-context
  hygiene, image minimalism and attack surface, known-vulnerability scan (Trivy/Grype),
  and compose/orchestration hardening. Static-first — parses Dockerfile, Containerfile,
  and docker-compose (incl. override/merge files) with zero Docker and zero network;
  the CVE dimension (K5) runs Trivy/Grype only when present, else degrades to N/A.
  Reserved dimensions K7-K10 (Kubernetes) activate behind --k8s. HEALTHY/NEEDS ATTENTION/AT RISK/CRITICAL grade
  with critical gates. Distinct from infra-audit (live host daemon over SSH) and
  ci-audit (Docker build speed in the pipeline).
  Switches: zuvo:container-audit full | [path] | --static | --scan | --dockerfile <p> | --compose <p> | --quick | --k8s | --persist-backlog
category: Infra audits
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - get_file_tree            # discover Dockerfile*, compose*, .dockerignore
    - search_text              # FROM / USER / COPY / ADD / ARG / ENV / mount patterns
    - search_patterns          # K2/K3/K6 anti-patterns
    - scan_secrets             # KEY — K3 secrets baked into ENV/ARG/layers
    - get_file_outline
    - audit_scan
---

# zuvo:container-audit

Audit container artifacts (Dockerfile, Containerfile, docker-compose) as **code** for
security defects — running as root, mutable `:latest` bases, secrets baked into layers,
bloated attack surface, known CVEs, and `docker.sock` mounts. Single-pass, read-only.

**When to use:** before shipping a Dockerized service, after editing a Dockerfile or
compose file, periodic container hardening review, pre-deploy gate.
**When NOT to use:** auditing the **live Docker daemon** on a remote host over SSH
(`zuvo:infra-audit` IS9); Docker **build speed / cache** in CI (`zuvo:ci-audit` CI8);
application-code vulnerabilities (`zuvo:security-audit`).

## Mandatory File Loading

Read every file below before starting. Print the checklist.

```
CORE FILES LOADED:
  1. ../../shared/includes/codesift-setup.md          -- [READ | MISSING -> STOP]
  2. ../../shared/includes/env-compat.md               -- [READ | MISSING -> STOP]
  3. ../../shared/includes/report-output-location.md   -- [READ | MISSING -> STOP]
  4. ../../shared/includes/severity-vocabulary.md      -- [READ | MISSING -> STOP]
  5. ../../shared/includes/run-logger.md               -- [READ | MISSING -> STOP]
  6. ../../shared/includes/retrospective.md            -- [READ | MISSING -> STOP]
```

If any file is MISSING, STOP. Do not proceed from memory.

---

## Argument Parsing

| Token | Behavior |
|-------|----------|
| _(empty)_ or `full` | All applicable dimensions, scope = project root |
| `[path]` | Scope to a directory (monorepo package / service) |
| `--static` | Force pure-static: skip live Trivy/Grype even if present (K5 via `trivy config` or N/A) |
| `--scan` | Force live CVE scan; missing scanner OR declined image pull → exit non-zero (`scan aborted`), never a silent downgrade |
| `--dockerfile <path>` | Audit a single Dockerfile |
| `--compose <path>` | Audit a single compose file |
| `--quick` | Critical gates only (K1 + K2 + K3) |
| `--k8s` | Activate reserved dimensions K7-K10 (Kubernetes manifest/RBAC/Pod-Security/network-policy) |
| `--persist-backlog` | Push findings to `zuvo:backlog` |

---

## Safety Gates

### GATE 1 -- Read-Only

The only write target is `zuvo/audits/`. FORBIDDEN: modifying any Dockerfile, compose, or
source file; **building, running, tagging, or pushing** images.

### GATE 2 -- Secret Censorship

Any secret value — from ANY source (an `ENV`/`ARG`/`.env`, a hardcoded literal in a `RUN`
command, a compose `environment:` entry, a scanned config) — is replaced with `***` before it
reaches the report. Variable NAMES may show; VALUES never. `.env.example` placeholders may
show as-is.

### GATE 3 -- Consent Before Any Image PULL

`trivy config` and the native Dockerfile/compose parse run freely (no pull). Before any
`trivy image <ref>` / `grype <ref>` that must PULL an image, prompt:
`Pull image <ref> to scan for CVEs? This performs network egress to <registry>. [y/N]` —
default DENY. In a **non-interactive / CI** context (no TTY, no way to answer) do NOT prompt —
treat it as an automatic DENY. Decline (or non-interactive) → default mode: K5 falls back to
`trivy config`/native with an annotation; `--scan` mode: exit non-zero. The prompt (or the
non-interactive auto-deny) and the outcome are logged.

### GATE 4 -- No Daemon / Socket Interaction

The audit never connects to `/var/run/docker.sock` or a remote daemon (that is
`zuvo:infra-audit`). Detecting a `docker.sock` **mount in a compose file** (K6) is static
text analysis, not a socket connection.

---

## MANDATORY TOOL CALLS — Container Audit Validity Gate

**INVALID if any tool below is skipped.** "DEFERRED", "N/A", `--quick` are NOT valid reasons.

| Tool | Trigger | Skip allowed? |
|------|---------|---------------|
| `get_file_tree` | Always | **NO** — discover Dockerfile*/compose*/.dockerignore |
| `search_text` | Always | **NO** — FROM/USER/COPY/ARG/ENV/mount scan |
| `search_patterns` | Always | **NO** — K2/K3/K6 anti-patterns |
| `scan_secrets` | Always | **NO** — K3 baked-secret detection |
| `audit_scan` | Always | **NO** — compound check |

The gate checks the CHECK was PERFORMED, not that a specific CodeSift tool was literally invoked.
When CodeSift is genuinely unavailable, the equivalent `Glob`/`Read`/`grep` fallback SATISFIES the
gate (record `scan_secrets: grep-fallback(<N> hits)`, `codesift: unavailable`). What is REJECTED is a
check silently NOT DONE: `scan_secrets: skipped`, `codesift: unavailable` used as an excuse to run
NO secret scan at all, or `retrospective: skipped`.

VERDICT vs logging: the audit VERDICT (PASS/WARN/FAIL/INCOMPLETE) is independent of the postamble
log-append. "`append-runlog` exit 0" below means the log wrapper returned 0 (append succeeded) — a
FAIL audit still appends its run line and returns 0 from the wrapper; the VERDICT is FAIL, not the
exit code. A `--scan` abort (GATE 3) exits BEFORE the postamble and does not write a run line.

POSTAMBLE (on a completed audit): report on disk → retro appended → `~/.zuvo/append-runlog` returns 0.
Every finding needs `path/to/file:LINE` (verify-audit gate).

```
Mandatory-tools-acknowledgment: I will run get_file_tree + search_text + search_patterns + scan_secrets + audit_scan (or their grep/Glob fallback if CodeSift is unavailable) for this container audit. Every finding will cite a `path/to/file:LINE` resolving in the current tree.
```

Degraded mode (CodeSift unavailable): fall back to `Glob`/`Read`/`grep` for artifact discovery and pattern scans; note `codesift=unavailable` in telemetry and proceed — the fallback satisfies the mandatory-tools gate (above), do NOT block.

---

## Phase 0: Detect and Scope

### 0.1 Target Resolution

Set `TARGET_ROOT` from arguments. All subsequent scans use this path.

### 0.2 Artifact Discovery

Enumerate container artifacts (use `get_file_tree`; cross-check with `git ls-files`):

| Pattern | Kind |
|---------|------|
| `Dockerfile*`, `*.dockerfile`, `Containerfile` | image build |
| `docker-compose*.y{a,}ml`, `compose*.y{a,}ml` | compose |
| `docker-compose.override.y{a,}ml`, `compose.override.y{a,}ml` | compose override (merged into effective config) |
| `.dockerignore` | build-context filter |
| `*.yaml`/`*.yml` under `k8s/`, `kubernetes/`, `manifests/` | Kubernetes (K7-K10, only when `--k8s`) |

If NO container artifacts are found → report "no container artifacts" and exit
`HEALTHY (N/A — nothing to audit)`. This is **not** a failure. Note: `get_file_tree` HAS run at
this point (that is how "none found" was determined, satisfying the mandatory-tools gate for it);
the remaining artifact-scanning tools (`search_text`/`search_patterns`/`scan_secrets` over
Dockerfiles) are vacuously N/A because there is nothing to scan — record them as
`N/A(no-artifacts)`, not `skipped`.

### 0.3 Scanner and Socket Detection

- `command -v trivy` / `command -v grype` → K5 mode (live vs N/A).
- Note Docker socket presence only to decide whether an image pull is even possible; never connect.

Print:

```
CONTAINER ARTIFACT INVENTORY
------------------------------------
Target:            [TARGET_ROOT]
Dockerfiles:       [N]
Compose files:     [N] (+ [N] override)
.dockerignore:     [present/absent]
K8s manifests:     [N] (audited only with --k8s)
CVE scanner:       [trivy | grype | none -> K5 N/A]
------------------------------------
```

---

## Phase 1: Dimension Analysis (K1-K6, + reserved K7-K10)

Single-pass inline execution. No sub-agents.

**Multi-stage scope rule:** runtime dimensions (K2, K4, K6) are judged on the **FINAL stage**
only — root/tools in a builder stage is fine. K1 (pinning) and K5 (CVE) apply to **every
EXTERNAL base ref in ALL stages** (a `FROM node:latest AS builder` is still pulled →
supply-chain risk). INTERNAL stage refs (`FROM builder`, where `builder` is a prior stage in
the same file) are exempt.

### K1: Base Image Provenance & Pinning -- Weight 15, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Base fully pinned | `@sha256:…` digest (immutable) | `:latest`, `:stable`, or no tag | CRITICAL |
| Version tag (no digest) | `node:20.11.1` — acceptable but MUTABLE (a tag can be re-pushed) | — | MEDIUM (recommend adding `@sha256:`) |
| Trusted registry | Official / org registry | Unknown/anonymous registry | HIGH |
| Every stage's external base | All pinned | A builder stage on `:latest` | HIGH |
| Var-interpolated `FROM $REG/img` | Resolvable + pinned | Unresolvable build-arg base | HIGH (flag, do not silent-pass) |

Only a `@sha256:` digest is truly immutable; a specific version tag is pinned-enough to clear the
critical gate but is flagged MEDIUM (recommend a digest). Critical gate: any final-image external base on `:latest`/`:stable`/no-tag → FAIL. The gate fires
on that FINDING; a K1 score of 0 also fires it but is not required.
rule_ids: `K1-latest-tag`, `K1-no-tag`, `K1-mutable-version-tag`, `K1-untrusted-registry`, `K1-unpinned-builder`.

### K2: Privilege & Runtime Hardening -- Weight 18, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Non-root user | `USER <non-root>` in final stage (or distroless `:nonroot`) | No `USER` → runs as root | CRITICAL |
| Compose `user:` override | absent, or a non-root uid | compose `user: root`/`user: "0"` overriding the image's non-root USER back to root | CRITICAL |
| Privileged (compose) | `privileged: false` / absent | `privileged: true` | CRITICAL |
| Capabilities (compose) | `cap_drop: [ALL]` + minimal `cap_add` | No cap_drop / `cap_add: [ALL]` | HIGH |
| no-new-privileges (compose) | `security_opt: [no-new-privileges:true]` | absent | MEDIUM |
| Read-only rootfs (compose) | `read_only: true` where feasible | writable rootfs unnecessarily | MEDIUM |

Distroless `:nonroot` variants satisfy the non-root check even without a `USER` line — do NOT
false-flag them. Critical gate: the image runs as root AND/OR `privileged: true` → FAIL. The gate fires on that
FINDING; a K2 score of 0 also fires it but is not required.
rule_ids: `K2-root-user`, `K2-privileged`, `K2-no-cap-drop`, `K2-no-new-privileges`.

### K3: Secret & Build-Context Hygiene -- Weight 18, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| No secret in ENV/ARG | Config-only ENV/ARG | `ENV API_KEY=…` / `ARG SECRET=…` baked to a layer | CRITICAL |
| Build secrets | `RUN --mount=type=secret` | secret passed via `ARG` (persisted in history) | CRITICAL |
| `.dockerignore` present | excludes `.env`, `.git`, keys | absent with a blind `COPY . .` | CRITICAL |
| No hardcoded creds | secrets via runtime env / manager | literal password/token in Dockerfile | CRITICAL |

K3 only flags ENV/ARG whose NAME matches secret patterns (`*KEY*`, `*SECRET*`, `*TOKEN*`,
`*PASSWORD*`, `*CRED*`), never benign build config (`VERSION`, `NODE_ENV`). Critical gate: any secret baked into the image, OR a blind `COPY . .` with no `.dockerignore`
→ FAIL. The gate fires on that FINDING; a K3 score of 0 also fires it but is not required.
rule_ids: `K3-secret-in-env`, `K3-secret-in-arg`, `K3-no-dockerignore`, `K3-hardcoded-cred`.

### K4: Image Minimalism & Attack Surface -- Weight 12

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Multi-stage | builder + slim runtime | single fat stage shipping build tools | HIGH |
| Minimal base | distroless / `-slim` / alpine | full `ubuntu`/`node` (non-slim) for runtime | MEDIUM |
| Package-manager cache | `--no-cache` / `rm -rf /var/lib/apt/lists` | apt/apk cache left in a layer | MEDIUM |
| No dev/debug tools in final | prod image has no `curl`/`nc`/shell (distroless) | debug tooling shipped to prod | MEDIUM |

rule_ids: `K4-no-multistage`, `K4-fat-base`, `K4-pkg-cache`, `K4-debug-tools`.

### K5: Known Vulnerability Scan -- Weight 15, Critical Gate (only when a scan actually ran)

The audit never BUILDS an image (GATE 1), so K5 scans the **declared base image(s)** and their OS
packages — the pullable `FROM` refs — NOT a final built image (which does not exist without a build).

- Scanner present → run `trivy config` (static Dockerfile/compose misconfig, invoked with
  `--skip-check-update`, no pull) and, with GATE-3 consent, `trivy image <base-ref>`/`grype <base-ref>`
  to scan the BASE image's CVEs. Parse findings from `--format json` — NEVER gate on the scanner's
  raw exit code (Trivy exits 1 on findings by design).
- Scanner absent OR pull declined OR non-interactive/CI (no consent possible) → **K5 = N/A
  (degraded)**, annotated, EXCLUDED from the denominator (see Scoring). Never a hard block.

Critical gate: applies ONLY when an image scan actually ran — a CRITICAL-severity CVE in the
**base image** triggers FAIL. `trivy config` misconfig findings alone (no image scan) do NOT trip
the gate. rule_ids: `K5-critical-cve`, `K5-high-cve`, `K5-config-misconfig`.

### K6: Compose & Orchestration Hardening -- Weight 12

Evaluate the **effective merged config** (base + `*.override.y*ml`) so an override cannot
silently re-introduce a risk the base avoided.

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Docker socket mount | absent | `/var/run/docker.sock` in `volumes:` | CRITICAL |
| Host network | absent | `network_mode: host` | HIGH |
| Resource limits | `mem_limit`/`cpus`/`deploy.resources` set | unbounded | MEDIUM |
| Healthcheck | `healthcheck:` present | absent | MEDIUM |
| Host namespaces | absent | `pid: host` / `ipc: host` | HIGH |
| Port binding | bound to loopback where private | needlessly on `0.0.0.0` | LOW |

rule_ids: `K6-docker-sock`, `K6-host-network`, `K6-no-limits`, `K6-no-healthcheck`, `K6-host-pid`.

### K7-K10: Kubernetes (RESERVED — `N/A (requires --k8s)` unless `--k8s`)

Registered so `--k8s`-off runs report them inert (excluded from the denominator) and a future
release can activate them additively without touching K1-K6:
- **K7** Manifest security (kubesec) · **K8** RBAC least-privilege · **K9** Pod Security
  Standards / admission · **K10** Network policies.

Without `--k8s` (or with no k8s manifests present): each is scored `N/A (requires --k8s)`,
excluded from the denominator, and emits ZERO findings.

**Current status: the K7-K10 CHECK LOGIC is not yet implemented** (DD4 — 0 k8s targets in the fleet
at ship time). Passing `--k8s` today prints `K7-K10: reserved — Kubernetes checks not yet
implemented in this release` and proceeds with K1-K6 only; it does NOT fabricate k8s findings. The
dimension slots exist so a future release adds the check logic additively without renumbering K1-K6.

---

## Phase 2: Scoring

```
K1 = [0-15]   Base Image Provenance & Pinning   (critical gate)
K2 = [0-18]   Privilege & Runtime Hardening      (critical gate)
K3 = [0-18]   Secret & Build-Context Hygiene     (critical gate)
K4 = [0-12]   Image Minimalism & Attack Surface
K5 = [0-15]   Known Vulnerability Scan           (critical gate when scan ran; N/A if no scanner)
K6 = [0-12]   Compose & Orchestration Hardening
K7-K10 = N/A (requires --k8s)
```

**Score = (sum of applicable dim scores) / (sum of applicable max weights) × 100.**
The denominator DROPS any dimension scored `N/A` — K5 when no scanner ran (denominator 90→75),
K6 when no compose file exists, K7-K10 always unless `--k8s`, and **K4/K5/K6 under `--quick`**
(which runs only the K1-K3 critical gates → denominator = 51). (Variable-denominator model, same
as `api-audit` D11=N/A — NOT env-audit's fixed denominator.) Under `--quick`, the score reflects
the critical-gate trio only; note `mode=quick (K1-K3)` in the report so the narrower denominator
is explicit.

**Critical gates fire on the FINDING, not on an aggregate score of zero.** Any one of these →
overall **FAIL**, whatever the dimension's numeric score:

| Gate | Fires on |
|------|----------|
| K1 | any `K1-latest-tag` / `K1-no-tag` finding on a **final-image** external base |
| K2 | any `K2-root-user` or `K2-privileged` finding (incl. a compose `user: root`/`"0"` override) |
| K3 | any CRITICAL-severity K3 finding (secret value reachable in image, ARG/ENV, or build context) |
| K5 | K5 actually ran AND a critical CVE is present |

Read literally as "the dimension scored 0", these gates would be nearly unreachable and the audit
would pass containers it exists to fail: K2 carries six checks across 18 points, so an image that
runs as **root** but sets `cap_drop: [ALL]`, `no-new-privileges` and `read_only: true` scores well
above zero — the root finding alone must FAIL it, and under a score-based reading it would not.
A dimension score of 0 remains sufficient to fire the gate; it is simply not necessary.

| Grade | Score |
|-------|-------|
| HEALTHY | ≥ 80% |
| NEEDS ATTENTION | ≥ 60% and < 80% |
| AT RISK | ≥ 40% and < 60% |
| CRITICAL | < 40% |

Bands are explicit inequalities because the variable denominator makes a fractional score the
norm, not the exception: 62/90 = 68.9% and 51/75 = 68% both land between the hyphenated `60–79`
and `80` bands, so a `60–79%` row would leave real scores ungraded (or silently rounded into a
different grade).

---

## Phase 3: Report

Save to: `zuvo/audits/container-audit-[YYYY-MM-DD].md` **and** `.json` — at the project root
(`zuvo/` resolves via `git rev-parse --show-toplevel`; override `$ZUVO_OUTPUT_DIR`. See
`../../shared/includes/report-output-location.md`).

### Markdown Report Structure

```markdown
# Container Security Audit Report

## Metadata
| Field | Value |
|-------|-------|
| Project | [name] |
| Date | [YYYY-MM-DD] |
| Scope | [TARGET_ROOT] |
| Dockerfiles / Compose | [N] / [N] |
| CVE scanner | [trivy | grype | none (K5 N/A)] |

## Executive Summary
**Score: [N] / 100** -- [HEALTHY / NEEDS ATTENTION / AT RISK / CRITICAL]
Critical gates: [PASS | FAIL — which]
| Metric | Count | (CRITICAL / HIGH / MEDIUM)

## Dimension Scores
| # | Dimension | Score | Max | Notes |
|---|-----------|-------|-----|-------|
| K1 | Base Image Provenance & Pinning | [N] | 15 | |
| K2 | Privilege & Runtime Hardening | [N] | 18 | |
| K3 | Secret & Build-Context Hygiene | [N] | 18 | |
| K4 | Image Minimalism & Attack Surface | [N] | 12 | |
| K5 | Known Vulnerability Scan | [N | N/A] | 15 | |
| K6 | Compose & Orchestration Hardening | [N] | 12 | |
| K7-K10 | Kubernetes | N/A | — | requires --k8s |
| **Total** | | **[N]** | **[applicable]** | |

## Findings (sorted by severity)
[Per finding: rule_id, dimension, severity, file:line, description, fix]

## Remediation Roadmap
### Quick Wins (< 1 hour)
### Short-term (1 day)
### Medium-term (1 week)
```

### JSON Findings (for a future container-fix consumer)

Write `zuvo/audits/container-audit-[YYYY-MM-DD].json` — write a `.tmp` then atomic-rename:

```json
{
  "score": 0,
  "grade": "CRITICAL",
  "critical_gate": "FAIL",
  "dimensions": { "K1": 0, "K2": 0, "K3": 0, "K4": 0, "K5": "N/A", "K6": 0 },
  "findings": [
    { "dimension": "K2", "severity": "CRITICAL", "file": "Dockerfile", "line": 1,
      "rule_id": "K2-root-user", "message": "image runs as root (no USER)", "fix": "add `USER node`" }
  ]
}
```

### Report Validation

- Dimension scores sum to the applicable total; denominator excludes N/A dims.
- Finding counts match the Executive Summary.
- No actual secret values appear anywhere (Gate 2).

---

## Phase 4: Next-Step Routing

```
RECOMMENDED NEXT ACTION
------------------------------------
K3 CRITICAL (secret baked)     -> zuvo:security-audit --static
K5 CRITICAL CVEs               -> zuvo:dependency-audit
K1=0 (mutable base)            -> pin FROM to a digest
K2=0 (root/privileged)         -> add USER + drop privileged
Score < 60%                    -> fix critical gates, re-audit
Score >= 80%                   -> schedule next audit in 3 months
------------------------------------
```

---

## CONTAINER-AUDIT COMPLETE

Score: [N] / 100 -- [grade]
Artifacts: [N Dockerfiles] / [N compose] | CVE scanner: [trivy | grype | none]
Dimensions: [N scored] | Critical gates: [PASS/FAIL]
Findings: [N critical] / [N total]

### Validity Gate (REQUIRED — print BEFORE Run line, AFTER retro append + append-runlog)

```
VALIDITY GATE
  artifacts_found: dockerfiles=<N> compose=<N>
  required_tool_calls:
    get_file_tree: [<N> | NOT_CALLED — VIOLATES_TRIGGER]
    search_text: [<N> | NOT_CALLED — VIOLATES_TRIGGER]
    search_patterns: [<N> | NOT_CALLED — VIOLATES_TRIGGER]
    scan_secrets: [<N> hits | NOT_CALLED — VIOLATES_TRIGGER]
    audit_scan: [<N> | NOT_CALLED — VIOLATES_TRIGGER]
  k5_mode: [scanned(trivy) | scanned(grype) | N/A(no-scanner) | N/A(pull-declined)]
  postamble:
    report_md: [written | NOT_WRITTEN]
    report_json: [written | NOT_WRITTEN]
    retros_log_appended: [yes(bytes_added=N) | NOT_APPENDED]
    retros_md_appended: [yes(entry_count=N) | NOT_APPENDED]
    verify_audit_pass: [yes(<verified>/<total>) | NOT_RUN | REJECTED]
  gate_status: [PASS | FAIL — <which gates missing>]
```

If `gate_status = FAIL` → VERDICT = INCOMPLETE.

Append the Run line via the retro-gated wrapper (NOT direct `>> runs.log`):

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Run: <ISO-8601-Z>	container-audit	<project>	<N-critical>	<N-total>	<VERDICT>	-	<N>-dimensions	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`. Gate check → structured questions →
TSV emit → markdown append. If gate check skips: print "RETRO: skipped (trivial session)".

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log
file path resolved per `run-logger.md`.

VERDICT: **FAIL** if any critical GATE trips OR ≥4 critical findings; **WARN** if 1-3 critical
findings and no gate tripped; **PASS** if 0 critical findings. (A tripped critical gate always wins
over the finding-count band — one tripped K2 is FAIL, not WARN.)

A gate "trips" per the **Gate / Fires on** table above — on the FINDING, not on `Kn=0`. Do not
restate the trip condition here as `K1=0 OR K2=0 OR K3=0`: that is the score-based reading the
table exists to replace, and it makes the gates nearly unreachable (K2 spreads six checks over 18
points, so a root-running privileged container still scores well above 0 and would pass the very
gate meant to fail it). One table, one place — this line points at it.

---

## Execution Notes

- Single-pass inline execution, no sub-agents required (like `env-audit`).
- Static dimensions (K1-K4, K6) need zero Docker and zero network — CI-safe.
- K5 is the only network-touching dimension and is consent-gated (GATE 3); absent scanner →
  N/A, never a block.
- Multi-stage: runtime dims judge the final stage; pinning/CVE cover every external base.
- Monorepos: use `[path]` to scope to one service.
- `--k8s` activates the K7-K10 registry slots; check logic is reserved (not yet implemented) — a
  `--k8s` run today prints the reserved notice and audits K1-K6 only.
- K6 merged-config evaluation covers the conventional `*.override.y*ml` file. An explicit
  multi-file merge (`docker compose -f a.yml -f b.yml`) is NOT auto-discovered — a known limitation;
  pass the specific file via `--compose` to audit it directly.
- K3 flags secret-shaped ENV/ARG by NAME pattern; `scan_secrets` (value-shaped detection) runs in
  parallel and catches secrets whose variable name does not match the pattern.
