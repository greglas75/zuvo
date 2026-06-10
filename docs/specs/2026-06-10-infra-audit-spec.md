# zuvo:infra-audit — Server / Infrastructure Security Audit — Design Specification

> **spec_id:** 2026-06-10-infra-audit-1137
> **topic:** Server & infrastructure security audit skill (live hosts over SSH)
> **status:** Approved
> **created_at:** 2026-06-10T11:37:47Z
> **reviewed_at:** 2026-06-10T11:52:00Z
> **approved_at:** 2026-06-10T12:05:00Z
> **approval_mode:** interactive
> **adversarial_review:** warnings (2 runs; run1 partial 2/3 providers — codex empty; run2 provider-rotated via --exclude-last gemini; all findings fixed or rejected with evidence)
> **author:** zuvo:brainstorm

## Problem Statement

Zuvo has six security-adjacent skills (`security-audit` S1–S15, `pentest` PT1–PT7, `db-audit` DB1–DB13, `env-audit`, `dependency-audit`, `ci-audit`) — all of them operate on **application code in a repo**. None of them can answer the question the user actually asked: *"is my server secure?"* — the live host's SSH configuration, open ports, firewall effectiveness, TLS certificates, outdated OS packages, running services, Docker daemon, and database servers as deployed infrastructure are a confirmed coverage gap (verified by grep across all skills: zero `ssh`/`nmap`/`lynis`/host-audit usage).

The approved spec `2026-06-10-security-detection-coverage-spec.md` does NOT overlap: it improves app-code vulnerability detection and wires IaC scanners against **repo-resident config files** (security-audit S14). This spec covers the orthogonal space: **target-host live analysis via SSH plus external exposure verification**.

Who is affected: the user runs production VPS boxes (Ubuntu + nginx + Docker + databases). Without this skill, server security is checked ad-hoc or not at all. What happens if we do nothing: misconfigurations (password-auth SSH, databases bound to 0.0.0.0, expired certs, years-old packages) remain invisible until exploited.

Authorization context: defensive auditing of servers the user owns. The skill enforces an explicit per-target authorization gate.

## Design Decisions

- **DD-1 — Single skill `zuvo:infra-audit`** with 12 dimensions IS1–IS12 and scope flags, not a skill family. Mirrors `db-audit` (13 dims + subset flags). Remediation (`infra-fix`) deferred to v2. *(User decision, Phase 2 Q1.)*
- **DD-2 — Target source: inventory file + `--host` flag.** `zuvo/infra/hosts.yaml` is the source of truth for fleet audits; `--host user@ip[:port]` audits a single server without a file. Multi-host with per-host verdict from v1. *(User decision, Q2.)*
- **DD-3 — Missing tools on target: propose installation with a per-host consent gate.** If the user declines (or passes `--no-install`), the affected dimension runs manual fallbacks and is labeled `DEGRADED`. Every install is logged in the report with its uninstall command. *(User decision, Q3.)*
- **DD-4 — Dual-vantage port scanning, external leg through the user's proxy.** Internal view always (`ss -tulpn` + `nmap` from the server's loopback via SSH); external view from the laptop **routed through a user-supplied proxy** (tool-specific mechanisms per IC-4). For the proxied external leg, a fail2ban ban hits the proxy IP, not the SSH management IP — lockout risk is removed **for that leg**; `--external direct` retains residual lockout risk and therefore enforces polite timing plus an abort threshold (stop external scanning after 3 consecutive connection-refused/ban signals). The diff of the two views is the firewall-effectiveness proof. No proxy configured → ask: direct external scan at polite timing, or internal-only. *(User decision, Q4 — user has a proxy available.)*
- **DD-5 — Architecture: deterministic collector + parallel LLM analysts** (Approach A). A collector script (`scripts/infra-collect.sh`) gathers everything per host in one SSH session into a normalized JSON bundle; parallel analyst agents each see only their layer's normalized findings; deterministic dedup/scoring/report assembly. The LLM **interprets, never detects** — the convergent lesson from PentestGPT/CAI/Strix prior art. Normalization uses **thin per-tool parsers**: JSON-native tools (nmap -oX→xml, testssl/nuclei/trivy JSON) parsed with `jq`/`python3`; text tools (lynis `.dat` key=value, debsecan lines) with awk/python3 helpers. Raw outputs are ALWAYS preserved under `raw/`; a parser failure marks the affected checks `error` with a `raw_ref` pointer — never silent corruption, never raw dumps into LLM context. *(User decision, Group 1.)*
- **DD-6 — No CVE without tool evidence.** A CVE identifier may appear in output only if it appears verbatim in trivy/grype/debsecan/`apt`-advisory output (per Integration Contract IC-6). LLM version-string→CVE mapping is forbidden (Ubuntu backports make it wrong).
- **DD-7 — Severity only via registry.** `shared/includes/infra-check-registry.md` maps check IDs → canonical severity (per `severity-vocabulary.md`) → remediation template → CIS reference. Lynis WARNING→MEDIUM, SUGGESTION→LOW by default; escalation only through registry entries.
- **DD-8 — Empty output ≠ PASS.** Every tool has a minimum-output sanity marker (per IC-7). Missing marker → dimension `DEGRADED` or check `insufficient-data`, never `ok`.
- **DD-9 — Read-only with one consented exception (DD-3).** No command that mutates server state outside `/tmp` and consented installs. `--dry-run` prints every SSH command without executing.
- **DD-10 — Secrets hygiene.** Pre-flight: `zuvo/` must be in `.gitignore` before any write (append + warn if missing). All config-dump values matching the redaction pattern (IC-5) become `[REDACTED]`. SSH private key material never read, logged, or stored.

## Solution Overview

```
zuvo:infra-audit [hosts.yaml | --host user@ip]
 │
 ├─ Phase 0  PREFLIGHT (laptop)
 │   inventory parse → dedup IPs → resolve IP+PTR per host
 │   → AUTHORIZATION GATE (show host→IP→PTR list, require explicit confirm)
 │   → gitignore check → per-host: nc -zw5 reachability, ssh probe,
 │     privilege probe (sudo -n true), remote tool probe (which lynis nmap trivy grype …)
 │   → per-host consent gate for missing-tool installation (unless --no-install)
 │   → a host failing Phase 0 writes bundle/<host>.phase0.json (status, reason,
 │     stderr evidence) so Phase 3 still renders its per-host report
 │
 ├─ Phase 1  COLLECT (deterministic, scripts/infra-collect.sh, per host, parallelizable)
 │   one SSH session; long scans via nohup → /tmp/zuvo-<run-id>/ → retrieved
 │   internal: lynis --cronjob, ss -tulpn, nmap loopback, sshd_config -T, sysctl,
 │             ufw/iptables, debsecan, needrestart, docker inspect/bench, trivy,
 │             pg/mysql/redis config queries, SUID/world-writable scan
 │   external (via proxy, IC-4): proxychains nmap -sT, proxychains testssl.sh, nuclei -proxy (safe tags)
 │   → normalize EVERYTHING into bundle.json per host (IC-3 schema); raw outputs kept
 │     as files, never fed to LLM
 │
 ├─ Phase 2  ANALYZE (parallel LLM analyst agents, per layer)
 │   host-analyst (IS1,IS2,IS5,IS6,IS7,IS11) · network-analyst (IS3,IS4,IS8)
 │   container-analyst (IS9) · data-analyst (IS10,IS12)
 │   each receives only its layer's normalized findings + registry; every emitted
 │   finding MUST cite an existing bundle.checks[].id (grounding rule, IC-3) —
 │   Phase 3 rejects unmapped findings as UNGROUNDED-FINDING; analyst output
 │   persisted as findings/<host>.json with the source bundle's sha256
 │
 ├─ Phase 3  AGGREGATE (deterministic)
 │   dedup by canonical key → severity via registry → internal/external diff
 │   (firewall verdict) → per-host report + fleet-summary.md (written LAST)
 │
 └─ Output  zuvo/audits/infra-audit-<YYYY-MM-DD-HHMM>/<host>.md + fleet-summary.md
            + bundle/ + state.json (resume support) · Run line → ~/.zuvo/runs.log
```

### Dimensions

| ID | Dimension | Primary sources |
|----|-----------|-----------------|
| IS1 | SSH hardening (sshd_config: PermitRootLogin, PasswordAuthentication, MaxAuthTries, algorithms) | lynis, `sshd -T` |
| IS2 | Accounts & auth (uid-0 accounts, sudoers, inactive users, PAM policy) | lynis, /etc reads |
| IS3 | Network exposure — dual-vantage (listeners vs external visibility, firewall diff) | ss, nmap (loopback + via-proxy) |
| IS4 | TLS & certificates (protocols, ciphers, expiry, chain) | testssl.sh via proxy |
| IS5 | Firewall & kernel net (ufw/nftables rules, sysctl: forwarding, SYN cookies, ICMP) | ufw/iptables, sysctl |
| IS6 | Patch posture (CVE exposure of installed packages, kernel age, pending restarts) | debsecan, needrestart, trivy fs |
| IS7 | Logging & intrusion detection (auditd, journald/rsyslog, fail2ban, log retention) | lynis, systemctl |
| IS8 | Deployed web services (exposed panels, misconfigs, known-CVE templates — safe tags only) | nuclei via proxy |
| IS9 | Docker (daemon config, socket perms, containers as root, image CVEs) | docker inspect, Docker Bench, trivy image |
| IS10 | Database servers (pg_hba/listen_addresses/SSL; MySQL & Redis bind/auth/TLS checklists; pgdsat per E14 dual consent) | SSH queries, pgdsat |
| IS11 | Filesystem & kernel hardening (SUID/SGID, world-writable, /tmp noexec, ASLR, AppArmor) | lynis, find (bounded per IC-9) |
| IS12 | Secrets hygiene on host (world-readable .env/credentials, keys in home dirs, history leaks) | find (bounded per IC-9) + redacted pattern scan |

`--quick` = IS1 + IS3 (internal only) + IS4. Full = all applicable (dimensions auto-skip when surface absent, e.g. IS9 without Docker → `N/A`).

## Detailed Design

### Data Model

**`zuvo/infra/hosts.yaml`** (inventory; created by user or scaffolded by skill on first run):

```yaml
defaults:
  ssh_user: deploy
  ssh_port: 22
  proxy: socks5://127.0.0.1:1080   # external-scan proxy; overridable per host / $ZUVO_SCAN_PROXY
hosts:
  - name: web01                    # required, unique
    address: 203.0.113.10          # required (IP or DNS name)
    ssh_user: root                 # optional, overrides defaults
    ssh_port: 22                   # optional
    ssh_key: ~/.ssh/id_ed25519    # optional (else ssh config/agent)
    jump_host: bastion.example.com # optional → ProxyJump
    roles: [web, docker, postgres] # optional hints for dimension targeting
    external_fqdn: example.com     # optional; target for IS4/IS8 external checks
```

Constraints: `name` unique; two entries resolving to the same IP are merged with `[WARN] duplicate IP`. No password fields — password auth must be pre-configured in `~/.ssh/config`/agent; the skill never prompts for or stores SSH passwords.

**Per-host bundle (`bundle/<host>.json`)** — collector output, the only thing analysts read (IC-3):

```json
{
  "host": "web01", "collected_at": "ISO-8601Z",
  "privilege_mode": "root|passwordless-sudo|limited-sudo|no-sudo",
  "os": {"id": "ubuntu", "version": "24.04", "kernel": "..."},
  "tool_availability": {"lynis": "3.1.1", "nmap": null, "trivy": "0.55", "grype": null, "...": "..."},
  "tools_installed_this_run": ["lynis"],
  "checks": [
    {"id": "IS1-sshd-permitrootlogin", "dimension": "IS1",
     "status": "ok|finding|insufficient-data|skipped|error",
     "evidence": "permitrootlogin yes", "source": "sshd -T", "raw_ref": "raw/sshd-T.txt",
     "needs_sudo": false}
  ],
  "external": {"vantage": "proxy|direct|none|failed", "proxy_used": "socks5://…",
               "open_ports": [...], "tls": {...}, "nuclei_findings": [...]}
}
```

**`state.json`** (per run dir): `hosts: {<name>: {status: pending|collecting|analyzed|reported|unreachable|failed, completed_checks: [...]}}` — drives `--resume`.

**Resume semantics** (`--resume <run-dir>`, per host status):

| status | action on resume |
|--------|------------------|
| `pending` | run full collection + analysis + report |
| `collecting` | re-run collection from scratch for that host (idempotent — partial bundle overwritten; `completed_checks` uses the same IDs as `bundle.checks[].id` but a partial collect is never trusted) |
| `analyzed` | skip collection AND analysis when `findings/<host>.json` exists AND its `bundle_sha256` matches the current bundle (IC-3 stale-findings guard); otherwise re-run analysis from the bundle |
| `reported` | skip entirely; report file untouched |
| `unreachable` / `failed` | retry from `pending` (the cause may have been fixed) |

fleet-summary is regenerated from per-host reports at the end of every resumed run (it is always written last, per Solution Overview).

### API Surface (skill argument parsing)

| Argument | Meaning |
|----------|---------|
| `[path/to/hosts.yaml]` | fleet audit from inventory (default: `zuvo/infra/hosts.yaml` if present) |
| `--host user@addr[:port]` | single ad-hoc host, no inventory needed |
| `--quick` | IS1+IS3(internal)+IS4 only, <3 min/host target |
| `--dimensions IS1,IS3,…` | explicit dimension subset |
| `--no-install` | hard read-only: never offer tool installation |
| `--dry-run` | print every SSH/local command without executing; no connections beyond DNS |
| `--resume <run-dir>` | continue an interrupted run from state.json |
| `--proxy <url>` | external-scan proxy override (else hosts.yaml `defaults.proxy`, else `$ZUVO_SCAN_PROXY`) |
| `--external direct` | explicit opt-in to proxyless external scan (polite timing enforced) |
| `--skip-external` | internal vantage only |
| `--deep-scan` | nmap `-p-` instead of `--top-ports 1000` |
| `--confirm-targets <sha256>` | non-interactive authorization: hash of the resolved target list (printed by a prior `--dry-run`); REQUIRED for any non-interactive run — without it, a non-interactive run ABORTS at the gate (the gate never auto-approves targets) |

### Integration Contract

- **IC-1 — Run directory** = `$ZUVO_DIR/audits/infra-audit-<YYYY-MM-DD-HHMM>/` where `ZUVO_DIR="${ZUVO_OUTPUT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/zuvo}"` (per `report-output-location.md`). All sections referencing output cite IC-1.
- **IC-2 — Host status vocabulary** = `OK | DEGRADED | UNREACHABLE | FAILED | SKIPPED` (host outcome level); check status = `ok | finding | insufficient-data | skipped | error`. Used identically in bundle, per-host reports, and fleet-summary. `state.json` uses a separate workflow-status set (`pending|collecting|analyzed|reported|unreachable|failed`, defined in the Resume semantics table) — process states drive `--resume`; outcome states populate reports.
- **IC-3 — Bundle schema** as in Data Model; collector is the only writer, analysts are read-only consumers; `raw_ref` files never enter LLM context. **Grounding rule**: every analyst finding must cite an existing `bundle.checks[].id`; Phase 3 drops unmapped findings with an `UNGROUNDED-FINDING` log line. `findings/<host>.json` records `bundle_sha256` of the bundle it was derived from; a mismatch at aggregation or resume time forces re-analysis (stale-findings guard).
- **IC-4 — External vantage rule**: external scanning runs through `proxy` when configured. Per-tool mechanism: **nmap and testssl.sh via proxychains-ng** (handles SOCKS5 and HTTP transparently; testssl's native `--proxy` is HTTP-CONNECT-only, so it is NOT used with SOCKS proxies); **nuclei via native `-proxy`** (supports `socks5://` and `http://` schemes). proxychains-ng missing on the laptop → external vantage = `none` with an explicit preflight warning. `direct` only on explicit `--external direct` with `-T2 --max-rate 50` + abort threshold per DD-4; otherwise external = `none` and the IS3 firewall verdict is `rules-only`. Vantage values recorded in `external.vantage` = `proxy | direct | none | failed`. SOCKS limitation: TCP connect scans only — no SYN, no UDP (documented in report header). **nuclei template enforcement**: the collector invokes nuclei ONLY with the pinned allowlist `-tags exposures,misconfiguration,technologies,ssl,dns -exclude-tags intrusive,dos,fuzz,bruteforce,default-login`; the AC3 dry-run command audit asserts no other nuclei tag set appears (v2's active categories are opt-in by design, per Out of Scope).
- **IC-5 — Redaction pattern** = case-insensitive `password|passwd|secret|token|api[_-]?key|private[_-]?key|DATABASE_URL|REDIS_URL|connection[_-]?string` → value replaced by `[REDACTED]` at collector level (before bundle write, so analysts never see secrets).
- **IC-6 — CVE evidence rule**: `CVE-\d{4}-\d+` allowed in any output artifact only when the same string exists in `raw/` tool output from trivy, grype, debsecan, or apt advisories. Enforced by a grep gate in Phase 3.
- **IC-7 — Tool sanity markers**: lynis → `Hardening index`; nmap → `Nmap done`; testssl.sh → JSON parses + `serviceDetected`; debsecan → ≥1 line or explicit empty marker; missing marker ⇒ check `error`, dimension `DEGRADED`.
- **IC-8 — SSH invariants**: every ssh invocation uses `-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes`; `StrictHostKeyChecking` never disabled; commands expected >30s wrapped in `nohup … > /tmp/zuvo-<run-id>/<check>.out` + retrieval.
- **IC-9 — Collection safety bounds**: every filesystem-walking command is bounded — `find` always runs with `-xdev` and prunes `/proc`, `/sys`, `/run` (network mounts and pseudo-filesystems would otherwise hang IS11/IS12 indefinitely). Every remote check has a timeout: default 300 s per check, trivy 120 s (`--timeout 120s --skip-update` when DB cached), nmap loopback `--top-ports 1000` unless `--deep-scan`. Long checks run **concurrently** under nohup (IC-8), so per-check timeouts do NOT stack linearly; additionally a **per-host wall clock of 30 min (full mode)** bounds the worst case — on breach, remaining checks → `skipped (wall-clock)`, dimension `DEGRADED`. `--deep-scan` (`-p-`) is explicitly EXCLUDED from the AC-S2 timing SLA and from the 30-min wall clock. Timed-out checks → status `error`, dimension `DEGRADED` — never a hung run. AC-S2's <15 min is the **nominal fixture target**; the wall clock is the architectural worst-case guarantee.

### Interaction Contract

Not applicable — no cross-cutting changes to how the agent speaks, classifies, routes, or formats output outside this skill. The skill follows existing audit-report conventions (Tool Availability Block, severity vocabulary, Run line).

### Integration Points

| File | Change |
|------|--------|
| `skills/infra-audit/SKILL.md` | NEW — orchestrator (phases above) |
| `skills/infra-audit/agents/{host,network,container,data}-analyst.md` | NEW — 4 analyst agents |
| `scripts/infra-collect.sh` | NEW — deterministic collector (testable standalone) |
| `shared/includes/infra-check-registry.md` | NEW — check registry (row schema below) |
| `shared/includes/ssh-probe-protocol.md` | NEW — SSH-mode safety protocol (section contract below); parallels `live-probe-protocol.md` |
| `skills/using-zuvo/SKILL.md` | routing row (Audit section) + banner count 53→54 |
| `shared/includes/severity-vocabulary.md` | one mapping row for infra-audit: vocabulary is `CRITICAL/HIGH/MEDIUM/LOW` mapping **identically to security-audit's row** (S1/S2/S3/S4 respectively) — both describe live security risk, so canonical cross-skill queries ("all S1 findings") and future `pentest --from-infra-audit` chaining stay consistent |
| `shared/includes/report-output-location.md` | add infra-audit to `audits/` writers list |
| `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `package.json`, `docs/skills.md` | reconcile skill counts (today inconsistent 52/53/54) |
| Standard completion includes | SKILL.md loads `run-logger.md` + `retrospective.md` per skill conventions (canonical template: `skills/build/SKILL.md`) — Run line + retro entries cited by SMOKE1 come from these, no new wiring |

Build scripts (`build-codex-skills.sh`, `build-cursor-skills.sh`) auto-discover `skills/*/` — no changes needed.

**`infra-check-registry.md` row schema** (mandatory columns; Phase 3 aggregation, analyst agents, and the IC-6 gate all parse this layout — do not reorder or rename):

```markdown
| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS1-sshd-permitrootlogin | IS1 | CRITICAL | SSH-7408 | Set `PermitRootLogin no` in /etc/ssh/sshd_config, then `sshd -t && systemctl reload sshd` | CIS 5.2.8 |
```

- `check_id` matches `^IS([1-9]|1[0-2])-[a-z0-9-]+$` and equals `bundle.checks[].id` (IC-3).
- `default_severity` ∈ `CRITICAL|HIGH|MEDIUM|LOW` (per the severity-vocabulary row above). Lynis defaults: test-IDs not explicitly listed map WARNING→MEDIUM, SUGGESTION→LOW (DD-7); escalation above MEDIUM requires an explicit registry row.
- `lynis_test_id` may be `-` for non-lynis checks.

**`ssh-probe-protocol.md` section contract** (minimum required sections — prose left to the implementer, structure is normative):

1. **Authorization Gate** — host→IP→PTR table display + explicit confirm requirement; block on decline (zero connections after "n"). Non-interactive runs: confirmation ONLY via `--confirm-targets <sha256>` matching the resolved target list; mismatch or absence → ABORT. `[AUTO-DECISION]` semantics never apply to target authorization (they apply only to low-risk defaults like E13's skip-external).
2. **SSH invariants** — verbatim restatement of IC-8 flags (this include is the runtime carrier of IC-8 for skill + agents).
3. **Privilege probe** — `sudo -n true` decision tree → `privilege_mode` values `root|passwordless-sudo|limited-sudo|no-sudo`; `needs_sudo` checks become `insufficient-data` when unprivileged.
4. **Key-material ban** — SSH private keys and passwords never read, logged, stored, or echoed; no password prompting.
5. **Host-key mismatch rule** — halt host, CRITICAL finding, manual `ssh-keygen -R` instruction; never auto-accept or disable `StrictHostKeyChecking`.
6. **Rate & timing rules** — external vantage per IC-4; consent-gated installs per DD-3.

### Edge Cases

| # | Case | Handling |
|---|------|----------|
| E1 | SSH key auth fails / password-only host | `BatchMode=yes` fails fast → host `SKIPPED — key-auth-failed`; never prompt for/store passwords; user pre-configures ssh agent/config |
| E2 | Jump host required | `jump_host` → `-o ProxyJump=`; jump unreachable → `UNREACHABLE — jump-host-failed` |
| E3 | No sudo | Phase 0 `sudo -n true` probe; `privilege_mode` recorded; `needs_sudo` checks → `insufficient-data`, NEVER ok |
| E4 | Host key mismatch | CRITICAL finding `HOST-KEY-MISMATCH`, halt that host, instruct manual `ssh-keygen -R`; never auto-accept. Recorded via `bundle/<host>.phase0.json` so the per-host report renders despite no collection (per Solution Overview Phase 0) |
| E5 | Unreachable / typo'd address | `nc -zw5` preflight → `UNREACHABLE`, fleet continues; authorization gate already showed IP+PTR so typos are surfaced before any probe |
| E6 | Missing remote tools | DD-3 consent gate → install or fallback matrix (lynis→manual config reads; nmap→`ss -tulpn`; trivy→`docker inspect` only) + `DEGRADED` |
| E7 | Long scans / dropped session | IC-8 nohup pattern; incremental bundle writes; `--resume` from state.json |
| E8 | fail2ban / IDS | External leg via proxy (DD-4) — ban hits proxy IP; internal leg via SSH loopback is IDS-invisible; `--external direct` enforces `-T2 --max-rate 50` |
| E9 | Secrets in collected configs | IC-5 redaction at collector level + gitignore preflight (DD-10) |
| E10 | Alpine / containers as targets | `/etc/alpine-release` detection → skip lynis, use `apk` checks; containers audited via `docker exec` from host, not SSH |
| E11 | Duplicate inventory IPs | merge + `[WARN]`, audit once |
| E12 | lynis < 3.0 | version probe → manual fallback + `DEGRADED (lynis vX < 3.0)` |
| E13 | No proxy configured but external checks requested | ask once: `--external direct` (polite) or `--skip-external`; in non-interactive mode default to skip-external `[AUTO-DECISION]` (target authorization is NEVER auto-decided — see ssh-probe-protocol §1 / `--confirm-targets`) |
| E15 | IS4 target when `external_fqdn` absent | IS4 needs a TLS endpoint name; if the host entry has no `external_fqdn` and `address` is a bare IP, IS4 = `insufficient-data (no external_fqdn)` — never silently skipped or guessed from nginx configs |
| E14 | pgdsat (IS10) | pgdsat executes **ON the target host via SSH, as the `postgres` OS user** (its designed mode — works against localhost-bound PostgreSQL; no laptop-direct DB connection ever). It requires BOTH the DD-3 install consent AND a separate query-consent confirmation (it runs SQL against the live database, beyond passive config reads); declining either → IS10 runs SSH-only config reads + checklist queries, labeled `DEGRADED (pgdsat declined)` |

### Failure Modes

#### SSH connection layer

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| Host key changed after re-provisioning | ssh exit≠0 + `REMOTE HOST IDENTIFICATION HAS CHANGED` on stderr | single host | host report: `FAILED — host-key-mismatch` + CRITICAL finding | user runs `ssh-keygen -R`, re-runs with `--resume` | fail-fast before any command — no partial bundle | immediate |
| Session drop mid-lynis (idle timeout) | retrieved output missing IC-7 marker / zero bytes | one check category on one host | check `error`, dimension `DEGRADED` | `--resume` re-runs interrupted category | completed checks already in bundle remain valid | on command return |
| sudo requires password | `sudo -n true` exits non-zero in Phase 0 | all `needs_sudo` checks on host | report header `privilege_mode: limited-sudo/no-sudo`; checks `insufficient-data` | user grants passwordless sudo for audit cmds, re-runs | unprivileged checks unaffected | Phase 0 (before audit) |
| Port 22 filtered from current network | `nc -zw5` fails | single host | `UNREACHABLE — port-filtered` | re-run from network with access / fix firewall | no writes for host | ≤5 s |

**Cost-benefit:** Frequency: occasional × Severity: high (silent false negatives if undetected) → Mitigation cost: trivial (probes + markers) → **Decision: Mitigate**

#### Remote scanner tools (lynis/nmap/trivy/nuclei/testssl)

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| Tool absent and install declined | Phase 0 `which` probe | one or more dimensions | `coverage_mode: DEGRADED` + per-dimension fallback note | fallback matrix (E6) runs automatically | fallback checks marked `source: fallback` | Phase 0 |
| trivy hangs pulling DB/large image | no output after `--timeout 120s` | IS9 CVE sub-checks only | `SKIPPED — trivy-timeout` | re-run later with cached DB (`--skip-update`) | other IS9 checks proceed independently | 120 s |
| nuclei template false positives | analyst cross-checks against IC-7 evidence | IS8 findings | findings carry `confidence` field; unverified → MEDIUM max | `--verify` follow-up in v2 | none | analysis phase |
| Tool install fails after consent (apt error/no network) | apt exit≠0 | same as absent-tool | consent gate result logged; dimension `DEGRADED` | manual install, `--resume` | `tools_installed_this_run` records only successes | immediate |
| Configured proxy unreachable/refusing (dead SOCKS, auth failure, wrong scheme) | proxychains/nuclei connect error on first external check | IS3 external leg, IS4, IS8 | `external.vantage: failed` recorded; IS3 firewall verdict downgraded to `rules-only`; IS4/IS8 `DEGRADED (proxy-failed)`; report suggests fixing proxy or `--skip-external` | re-run external legs after proxy fix (`--resume`) | internal-vantage results unaffected | first external check (seconds) |

**Cost-benefit:** Frequency: occasional × Severity: medium (reduced coverage, clearly labeled) → Mitigation cost: trivial (timeouts + fallback matrix exist) → **Decision: Mitigate**

#### LLM analysis layer

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| Empty scanner output read as "no issues" | IC-7 sanity markers at collector level | would be whole dimension | impossible to mark ok without marker — becomes `DEGRADED` | n/a (prevented structurally) | none | collect phase |
| Hallucinated CVE from version strings | IC-6 grep gate in Phase 3 | CVE-bearing findings | finding rejected + logged `CVE-EVIDENCE-MISSING` | analyst re-dispatched without CVE claim | report never contains unevidenced CVEs | aggregation phase |
| Severity inflation (lynis suggestions → CRITICAL) | severity assigned only via registry lookup (DD-7) | report trust | n/a — analyst proposes, registry decides | registry update if genuinely missing | deterministic severity | aggregation phase |
| Analyst agent dispatch rate-limited ×2 | Agent tool error | one layer's analysis | `[MODE SWITCH] → inline analysis` per env-compat | inline single-agent fallback with checkpoint marker | same bundle input → same findings shape | immediate |

**Cost-benefit:** Frequency: frequent (LLM failure modes are the norm, not the exception) × Severity: high (report credibility) → Mitigation cost: moderate (registry + gates) → **Decision: Mitigate**

#### Report writing & persistence

| Scenario | Detection | Impact Radius | User Symptom | Recovery | Data Consistency | Detection Lag |
|----------|-----------|---------------|--------------|----------|------------------|---------------|
| Crash before all hosts complete | state.json shows non-final statuses | fleet summary | fleet-summary absent (written LAST by design); per-host reports present for finished hosts | `--resume <run-dir>` | per-host reports immutable once written | immediate on inspection |
| `zuvo/` not gitignored | preflight grep of `.gitignore` | credential leak risk | warning + auto-append before any write | n/a (prevented) | none | Phase 0 |
| Re-run collides with old report dir | timestamped dirs (IC-1) | none | new dir per run; `--resume` appends to its own dir only | n/a | old runs immutable | n/a |

**Cost-benefit:** Frequency: occasional × Severity: high (incomplete report read as complete; secret leak) → Mitigation cost: trivial → **Decision: Mitigate**

## Acceptance Criteria

**Ship criteria:**

- **AC1 — Fleet continuity: an unreachable host does not abort the run.**
  - Surface: `integration`
  - Proof: fixture inventory with 3 hosts (2 reachable seeded containers + 1 black-hole address); run `zuvo:infra-audit fixtures/hosts-3.yaml`; inspect run dir.
  - Expected: 2 complete per-host reports; third host `UNREACHABLE` in fleet-summary; skill completes without crash.
  - Artifact: `zuvo/proofs/infra-AC1.txt` (run-dir listing + fleet-summary excerpt)
- **AC2 — Authorization gate precedes any connection.**
  - Surface: `integration`
  - Proof: run against fixture with confirmation declined ("n"); capture transcript + fixture sshd auth log.
  - Expected: gate printed host→IP→PTR table; after "n": zero SSH connection attempts in fixture auth log; no run-dir writes beyond nothing.
  - Artifact: `zuvo/proofs/infra-AC2.txt`
- **AC3 — Read-only: `--dry-run` emits no mutating commands.**
  - Surface: `config`
  - Proof: `--dry-run` on fixture inventory; grep emitted command list for mutating patterns (`apt install|apt-get install|sysctl -w|chmod|chown|rm |mv |tee |> /etc`) **after filtering out lines whose write/cleanup target is under `/tmp/zuvo-*`** (the run's own scratch dir is legitimate); the consent-gated install block must be absent entirely in `--no-install --dry-run`.
  - Expected: zero matches; every command listed is read-only or writes only under `/tmp/zuvo-*`.
  - Artifact: `zuvo/proofs/infra-AC3.txt`
- **AC4 — No-sudo target yields `insufficient-data`, never PASS.**
  - Surface: `integration`
  - Proof: run against fixture container whose SSH user has no sudo; jq over bundle: `.checks[] | select(.needs_sudo==true) | .status`.
  - Expected: all `needs_sudo` checks have status `insufficient-data`; report header `privilege_mode: no-sudo`; none reported as ok.
  - Artifact: `zuvo/proofs/infra-AC4.json`
- **AC5 — Secret redaction is total.**
  - Surface: `integration`
  - Proof: fixture seeds 5 known secret values in `/etc/environment`, `.env`, redis.conf; after full run, grep run dir (reports + bundles) for each seeded value.
  - Expected: 0/5 values present; `[REDACTED]` markers present at their locations.
  - Artifact: `zuvo/proofs/infra-AC5.txt`
- **AC6 — No CVE without tool evidence.**
  - Surface: `integration`
  - Proof: run on fixture with trivy/grype/debsecan absent and `--no-install`; grep all reports for `CVE-`.
  - Expected: zero CVE identifiers in report; coverage notes direct user to install scanners.
  - Artifact: `zuvo/proofs/infra-AC6.txt`
- **AC7 — Collector is independently testable and schema-valid.**
  - Surface: `backend-logic`
  - Proof: `scripts/infra-collect.sh --host <fixture> --out /tmp/b.json`; validate with jq against IC-3 required keys (`host, privilege_mode, tool_availability, checks[].id/dimension/status/source`).
  - Expected: exit 0; jq schema assertions pass; every check id matches `^IS([1-9]|1[0-2])-`.
  - Artifact: `zuvo/proofs/infra-AC7.txt`
- **AC8 — Host-key mismatch halts that host with CRITICAL.**
  - Surface: `integration`
  - Proof: poison local known_hosts entry for fixture; run; inspect host report + auth log.
  - Expected: host `FAILED — host-key-mismatch`; CRITICAL finding present in the per-host report (rendered from `bundle/<host>.phase0.json` per E4); no post-handshake commands executed on fixture.
  - Artifact: `zuvo/proofs/infra-AC8.txt`
- **AC9 — Degraded coverage is labeled, structurally.**
  - Surface: `integration`
  - Proof: run with `--no-install` on a minimal fixture (no lynis/nmap/trivy); grep host report header.
  - Expected: `coverage_mode: DEGRADED` + per-dimension fallback notes; Tool Availability Block lists each missing tool.
  - Artifact: `zuvo/proofs/infra-AC9.txt`
- **AC10 — Output lands only under the canonical run dir (IC-1) and routing/manifest updates are consistent.**
  - Surface: `docs`
  - Proof: post-run `git status` shows no writes outside `zuvo/` (gitignored) — with ONE documented exemption: the first-run one-time `.gitignore` append from DD-10 (assert its diff is exactly the `zuvo/` line); grep `using-zuvo` routing row, severity-vocabulary row, report-output-location row; compare skill counts across the 4 manifest files.
  - Expected: all rows present; all four counts equal; `.gitignore` diff (if any) is the single `zuvo/` line.
  - Artifact: `zuvo/proofs/infra-AC10.txt`

**Success criteria:**

- **AC-S1 — Seeded-issue detection rate ≥ 7/10.**
  - Surface: `integration`
  - Proof: fixture container seeded with 10 documented misconfigurations (PermitRootLogin yes; PasswordAuthentication yes; no firewall; world-writable cron dir; secret-bearing .env; redis bound 0.0.0.0 no auth; stale packages; container as root; SUID copy of /bin/sh; no fail2ban); full run; score findings against the seed manifest.
  - Expected: ≥7/10 seeded issues appear as findings with correct dimension; misses only where the needed tool was deliberately absent.
  - Artifact: `zuvo/proofs/infra-S1-scorecard.md`
- **AC-S2 — `--quick` completes in < 3 min/host; full single-host run < 15 min.**
  - Surface: `integration`
  - Proof: `time` both modes against one fixture host (excluding gate wait). Fixture preconditions for the timing claim: ≤2 docker images on target, no `--deep-scan` (excluded from this SLA per IC-9), trivy DB pre-cached.
  - Expected: quick < 180 s, full < 900 s; per-check timeouts (IC-9) guarantee bounded worst case.
  - Artifact: `zuvo/proofs/infra-S2-timing.txt`
- **AC-S3 — False-positive discipline on a hardened fixture.**
  - Surface: `integration`
  - Proof: second fixture hardened per CIS L1 basics (key-only SSH, root login off, ufw default-deny, no exposed DB); full run; count findings by severity.
  - Expected: ≤3 findings total, none CRITICAL/HIGH.
  - Artifact: `zuvo/proofs/infra-S3-fp.txt`

## Whole-feature Smoke Proofs

- **SMOKE1 — Fleet audit end-to-end on seeded fixtures**
  - Preconditions: docker compose with 2 fixture sshd containers (one misconfigured, one hardened) + hosts.yaml listing both plus 1 unreachable address; local SOCKS proxy container for the external leg.
  - Proof: invoke `zuvo:infra-audit fixtures/hosts-3.yaml`; confirm gate; let full pipeline run (collect → analysts → aggregate).
  - Expected: run dir per IC-1 with 2 host reports + fleet-summary (written last) + bundles + state.json all-final; misconfigured host grade worse than hardened host; internal/external diff section present with proxy vantage recorded; Run line appended to `~/.zuvo/runs.log`; retro entries written.
  - Artifact: `zuvo/proofs/smoke-fleet-audit.txt`
- **SMOKE2 — Interrupt + resume round-trip**
  - Preconditions: SMOKE1 fixtures; kill the run after host 1 reaches `reported`.
  - Proof: re-invoke with `--resume <run-dir>`.
  - Expected: host 1 not re-collected (state.json `reported`); host 2 completes; fleet-summary generated once, listing both; no duplicate report files.
  - Artifact: `zuvo/proofs/smoke-resume.txt`

## Validation Methodology

Proof runners: bash, jq, docker (+ docker compose for fixtures), ssh (to fixture containers on localhost ports), grep, time. Infrastructure prerequisites: `fixtures/` with two container definitions (misconfigured + hardened, both running sshd with key auth for a test key), a seed manifest documenting the 10 planted issues, and a local SOCKS proxy container (e.g. a minimal ssh -D or microsocks) to exercise IC-4 without external infrastructure. Per-AC proofs above are the inventory; the fixtures are a build prerequisite for implementation, not an afterthought. Real-VPS validation is a manual "first real run" after implementation approval — never part of automated proofs.

## Rollback Strategy

The skill changes no server state except consented tool installs (DD-3), each logged in the report with its uninstall command (`apt remove lynis`). Kill switch: `--no-install` (hard read-only) and simply not invoking the skill — there is no daemon, cron, or persistent agent. Local artifacts are timestamped immutable directories under IC-1; removing the skill (delete `skills/infra-audit/`, revert routing/manifest rows) fully de-installs with no data migration. Reports already produced remain readable standalone.

## Backward Compatibility

Purely additive: no existing skill, include, or schema is modified beyond additive registry rows and skill-count strings. `pentest`/`security-audit`/`db-audit` semantics unchanged; the boundary is documented in the routing table ("live server/host security" → infra-audit; "IaC config in repo" → security-audit S14; "DB as data layer" → db-audit). No migration path needed — first run scaffolds `zuvo/infra/hosts.yaml` if absent.

## Out of Scope

### Deferred to v2

- **`zuvo:infra-fix`** — consent-gated remediation (separate skill; SSH-lockout-safe apply pattern: sshd -t + keepalive session). Rationale: audit value ships independently; remediation carries the highest operational risk.
- **Cloud control-plane posture** (Prowler/ScoutSuite for AWS/GCP) — user's fleet is VPS-first.
- **nuclei `--verify` active confirmation** of IS8 findings; **`default-credentials` / `exploit` template categories** — opt-in active testing belongs with v2 alongside pentest integration.
- **`pentest --from-infra-audit` chaining** (import infra findings as pentest starting points).
- **Windows / BSD targets** — Linux (Debian-family + Alpine detection) only in v1.

### Permanently out of scope

- Automatic remediation without per-change consent (lockout risk is unbounded).
- Scanning targets not present in the confirmed inventory/`--host` (no auto-discovery of adjacent hosts — scope-creep is a documented LLM-agent failure mode).
- Storing SSH passwords or private key material anywhere.

## Open Questions

None — all design questions were resolved interactively in Phase 2 (see Design Decisions DD-1…DD-10).

## Adversarial Review

Two cross-model runs (cap per `adversarial-loop-docs.md`), host `claude` self-excluded.

**Run 1** — `status: partial (2/3 providers)`: gemini + cursor-agent returned; codex-5.3 failed/empty (not a timeout; `timeout_count: 0`). Coverage reduced accordingly.
- Rejected as false positive: gemini's "hallucinated file path in `--host` syntax" — its own CLI mangled `user@ip` into a file reference; grep confirmed the spec reads `--host user@ip[:port]` / `user@addr[:port]` throughout.
- Fixed: collector parsing brittleness (DD-5 thin per-tool parsers, raw always kept, parse failure → `error`); unbounded `find` (IC-9 `-xdev` + prunes); Phase-0 failures now write `bundle/<host>.phase0.json` so failed hosts still get reports (E4/AC8); resume `analyzed` skip-analysis path; AC3 `/tmp/zuvo-*` exemption; grype added to probe/tool_availability (IC-6 consistency); pgdsat corrected to run ON the host via SSH as `postgres` (E14); per-tool proxy mechanisms (IC-4: proxychains-ng for nmap+testssl, native `-proxy` for nuclei); proxy-failure failure-mode row (`external.vantage: failed`); DD-4 lockout claim softened to the proxied leg + direct-mode abort threshold; SMOKE1 retro expectation grounded in run-logger/retrospective includes row.

**Run 2** — `--exclude-last gemini` (provider rotation). All residual findings classified per the post-cap protocol as **(a) fixed before approval**:
- DD-10/AC10 contradiction → AC10 now exempts the single one-time `.gitignore` append (asserted to be exactly the `zuvo/` line).
- AC-S2 vs IC-9 stacked-timeout math → IC-9 now states concurrent long checks + a 30-min per-host wall clock (worst-case guarantee), AC-S2 <15 min is the nominal fixture target.
- E13 "async mode" vs interactive-only gate → new `--confirm-targets <sha256>` non-interactive contract; target authorization is never `[AUTO-DECISION]` (ssh-probe-protocol §1).
- nuclei tag enforcement → pinned allowlist `-tags exposures,misconfiguration,technologies,ssl,dns -exclude-tags intrusive,dos,fuzz,bruteforce,default-login` in IC-4, audited by AC3.
- Stale-findings on resume → `findings/<host>.json` carries `bundle_sha256`; mismatch forces re-analysis (IC-3).
- `--quick` IS4 without `external_fqdn` → E15: `insufficient-data (no external_fqdn)`, never guessed.
- Analyst grounding → IC-3 grounding rule: every finding cites a `bundle.checks[].id`; Phase 3 drops `UNGROUNDED-FINDING`s.

No residual CRITICAL remains unaddressed; no novel architectural concern surfaced in run 2 (all findings were consistency-tightening of decisions already made), so no third pass is warranted.
