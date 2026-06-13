---
name: infra-audit
description: "Server / infrastructure security audit of LIVE hosts over SSH (12 dimensions IS1-IS12: SSH hardening, accounts, network exposure, TLS, firewall, patch posture, logging, web services, Docker, databases, filesystem, host secrets). Deterministic collector + parallel LLM analysts; dual-vantage (internal SSH + external via proxy); per-target authorization gate; consent-gated tool installs; read-only with one consented exception. Flags: --host user@addr[:port] (single ad-hoc host), --quick (IS1+IS3+IS4, <3 min/host), --dimensions IS1,IS3,… (explicit subset), --no-install (hard read-only), --dry-run (print commands, no connections), --resume <run-dir> (continue interrupted run), --proxy <url> (external-scan proxy), --external direct (proxyless external scan, polite timing), --skip-external (internal vantage only), --deep-scan (nmap -p- full port sweep), --confirm-targets <sha256> (non-interactive authorization)."
codesift_tools:
  always:
    - plan_turn
    - index_status
  by_stack: {}
---

# zuvo:infra-audit

> Audit the security of LIVE servers/infrastructure the user owns, over SSH, plus
> external exposure verification through a proxy. This is the orthogonal companion
> to `security-audit` (repo-resident IaC config), `db-audit` (DB as a data layer),
> and `pentest` (app-code exploitability). Routing boundary: **"is my server
> secure?" → infra-audit**.
>
> Architecture (DD-5): a **deterministic collector** (`scripts/infra-collect.sh`)
> gathers everything per host into a normalized JSON bundle; **parallel LLM
> analysts** each see only their layer's normalized findings; **deterministic**
> dedup/scoring/report assembly. The LLM **interprets, never detects**.

## Argument Parsing

| Argument | Meaning |
|----------|---------|
| `[path/to/hosts.yaml]` | Fleet audit from inventory (default: `zuvo/infra/hosts.yaml` if present) |
| `--host user@addr[:port]` | Single ad-hoc host, no inventory file needed |
| `--quick` | IS1 + IS3 (internal) + IS4 only; < 3 min/host target |
| `--dimensions IS1,IS3,…` | Explicit dimension subset |
| `--no-install` | Hard read-only: never offer tool installation (disables the DD-3 gate) |
| `--dry-run` | Print every SSH/local command without executing; no connections beyond DNS |
| `--resume <run-dir>` | Continue an interrupted run from `state.json` |
| `--proxy <url>` | External-scan proxy override (else hosts.yaml `defaults.proxy`, else `$ZUVO_SCAN_PROXY`) |
| `--scan-via <ssh-target>` | Run the external leg FROM this SSH host via portable nc/openssl/curl (no nmap/testssl/nuclei/proxychains; **macOS-safe**; a real internet vantage). Highest external-vantage priority. Else hosts.yaml `defaults.scan_via`, else `$ZUVO_SCAN_VIA` |
| `--external direct` | Explicit opt-in to a proxyless external scan (polite timing `-T2 --max-rate 50`) |
| `--skip-external` | Internal vantage only (no external leg) |
| `--deep-scan` | nmap `-p-` instead of `--top-ports 1000` (EXCLUDED from the AC-S2 timing SLA + 30-min wall clock) |
| `--confirm-targets <sha256>` | Non-interactive authorization: sha256 of the resolved target list printed by a prior `--dry-run`. REQUIRED for any non-interactive run — without it the run ABORTS at the gate (targets are never auto-approved) |

Parse flags first. `--host` and a `hosts.yaml` path are mutually-complete: exactly
one target source must resolve. `--quick` and `--dimensions` are mutually
exclusive (error if both). `--resume <run-dir>` overrides target resolution from
the run's own `state.json`.

Variable mapping for flags that the collector invocation threads through:

| Flag | Variable set |
|------|-------------|
| `--external <mode>` (e.g. `--external direct`) | `EXTERNAL_MODE=<mode>` |
| `--skip-external` | `SKIP_EXTERNAL=1` |
| `--proxy <url>` | `proxy=<url>` (overrides hosts.yaml/env) |
| `--scan-via <ssh-target>` | `SCAN_VIA=<ssh-target>` (overrides hosts.yaml `defaults.scan_via` / `$ZUVO_SCAN_VIA`) |
| `--quick` | `QUICK=1` |
| `--dimensions <list>` | `DIMENSIONS=<list>` |
| `--no-install` | `NO_INSTALL=1` |
| `--deep-scan` | `DEEP_SCAN=1` |

`--external <mode>` and `--skip-external` are mutually exclusive; error if both supplied.

## Dimensions (IS1-IS12)

| ID | Dimension | Analyst |
|----|-----------|---------|
| IS1 | SSH hardening (sshd_config) | host-analyst |
| IS2 | Accounts & auth | host-analyst |
| IS3 | Network exposure — dual-vantage | network-analyst |
| IS4 | TLS & certificates | network-analyst |
| IS5 | Firewall & kernel net | host-analyst |
| IS6 | Patch posture | host-analyst |
| IS7 | Logging & intrusion detection | host-analyst |
| IS8 | Deployed web services (safe tags only) | network-analyst |
| IS9 | Docker | container-analyst |
| IS10 | Database servers | data-analyst |
| IS11 | Filesystem & kernel hardening | host-analyst |
| IS12 | Secrets hygiene on host | data-analyst |

`--quick` = IS1 + IS3 (internal only) + IS4. Full = all applicable; dimensions
auto-skip when the surface is absent (e.g. IS9 without Docker → `N/A`).

---

## Mandatory File Loading

Read in **two stages** (pentest model). Stage 1 before Phase 0; Stage 2 before
Phase 3 (report writing). STOP if any Stage 1 file is missing.

### Stage 1 — Before starting (STOP if any missing)

```text
CORE FILES LOADED:
  1. ../../shared/includes/env-compat.md           -- [READ | MISSING -> STOP]   (dispatch + [MODE SWITCH] rate-limit fallback)
  2. ../../shared/includes/no-pause-protocol.md     -- [READ | MISSING -> STOP]   (HARD: no mid-loop pauses across hosts/dimensions)
  3. ../../shared/includes/infra-check-registry.md  -- [READ | MISSING -> STOP]   (check_id → severity → remediation → CIS; Phase 3 authority)
  4. ../../shared/includes/ssh-probe-protocol.md    -- [READ | MISSING -> STOP]   (IC-8 SSH invariants; authorization gate §1; runtime carrier)
```

If any Stage 1 file is missing, STOP.

### Stage 2 — Before Phase 3 (report writing)

```text
  5. ../../shared/includes/backlog-protocol.md       -- [READ | MISSING]   (findings → backlog entries)
  6. ../../shared/includes/run-logger.md             -- [READ | MISSING]   (Run: line + append-runlog)
  7. ../../shared/includes/retrospective.md          -- [READ | MISSING]   (RETRO: marker + retros.log/.md append)
  8. ../../shared/includes/report-output-location.md -- [READ | MISSING]   (canonical $ZUVO_DIR — output MUST go to zuvo/audits/)
```

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch, path resolution,
the `[AUTO-DECISION]` non-interactive contract, and the `[MODE SWITCH]` rate-limit
fallback. Sub-agent dispatch is Claude-Code-native; Codex/Cursor/Antigravity run
the analysts sequentially inline (no spawning) — see the Phase 2 dispatch block.

### Mandatory acknowledgment (REQUIRED — print verbatim before Phase 0)

```
This audit connects to LIVE servers over SSH. It is read-only (one consented
exception: DD-3 tool installs). No target is contacted before the authorization
gate (ssh-probe-protocol §1) is explicitly confirmed. Secrets are redacted at the
collector (IC-5); SSH private key material is never read or stored (ssh-probe-
protocol §4).
```

---

## Phase 0 — PREFLIGHT (laptop, before any SSH connection)

Phase 0 runs entirely on the laptop. **No SSH connection opens until the
Authorization Gate is explicitly confirmed.**

### Phase 0.0 — retro-marker (passive checkpoint capture)

Emit a passive run marker so an API-error-killed run is still attributable. This
is a fire-and-forget bash block — never block the audit on it.

```bash
# >>> zuvo:retro-marker  (infra-audit — passive checkpoint capture)
_RS=$(command -v retro-stub 2>/dev/null || ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/zuvo-home/retro-stub 2>/dev/null | head -1)
_ZH="${ZUVO_HOME:-$HOME/.zuvo}"
_RSK="${SKILL:-infra-audit}"
_RPR="${PROJECT:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}"
_RSHA=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
[ -n "$_RS" ] && "$_RS" --sweep >/dev/null 2>&1 || true
if mkdir -p "$_ZH/run-markers" 2>/dev/null; then
  { printf 'start_ts=%s\nskill=%s\nproject=%s\nsha7=%s\nbranch=%s\nsession_id=%s\nrepo_root=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_RSK" "$_RPR" "$_RSHA" \
      "$(git branch --show-current 2>/dev/null || echo -)" "${ZUVO_SESSION_ID:-$_RSHA}" \
      "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" ; } \
      > "$_ZH/run-markers/$_RSK-$_RPR-$_RSHA-$$-$(date +%s).marker" 2>/dev/null || true
fi
# <<< zuvo:retro-marker
```

### Phase 0.1 — Resolve the output directory (IC-1)

Resolve the canonical run directory per `report-output-location.md`:

```bash
ZUVO_DIR="${ZUVO_OUTPUT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/zuvo}"
RUN_TS="$(date -u +%Y-%m-%d-%H%M)"
RUN_DIR="$ZUVO_DIR/audits/infra-audit-$RUN_TS"     # IC-1
mkdir -p "$RUN_DIR/bundle" "$RUN_DIR/raw" "$RUN_DIR/findings"
```

On `--resume <run-dir>`, set `RUN_DIR` to the supplied dir instead and DO NOT
re-timestamp (resume appends to its own dir only).

**Implicit resume after an interrupted run (StopFailure / watchdog auto-resume).**
The collector is invoked from an orchestrator turn that can die on an API
error / rate-limit; the StopFailure watchdog then re-invokes `zuvo:infra-audit`
**fresh, with the same args** — without `--resume`. A naive fresh run would mint
a NEW timestamped `RUN_DIR` and re-collect every host from zero, discarding the
bundles the interrupted run already wrote (observed 2026-06-12: 7 auto-resumes).
So BEFORE minting a new `RUN_DIR`, detect an in-progress run and adopt it:

```bash
# Implicit-resume detection: the most-recent infra-audit run whose state.json
# still has a host NOT in a terminal status (reported|unreachable|failed) is an
# unfinished run — adopt its dir instead of creating a new one. A fresh first
# run (no such dir) falls through to the new-RUN_DIR mint above.
# NOTE: iterate via a glob (NOT `$(ls)`) — a `for x in $(ls)` word-splits on
# whitespace/glob chars in dir names. The glob yields one safe word per match;
# pick the newest by mtime without parsing `ls`.
if [ -z "${RESUME_DIR:-}" ]; then   # only when --resume was NOT passed explicitly
  _now="$(date +%s)"; _fresh_window=1800   # 30 min — the crash-recovery window
  _newest=""; _newest_mt=0
  for _d in "$ZUVO_DIR"/audits/infra-audit-*/; do
    [ -d "$_d" ] && [ -f "${_d}state.json" ] || continue
    _mt="$(stat -c %Y "${_d}state.json" 2>/dev/null || stat -f %m "${_d}state.json" 2>/dev/null || echo 0)"
    # FRESHNESS BOUND: only auto-adopt a run whose state.json changed within the
    # last 30 min — a genuine StopFailure/watchdog resume fires minutes after the
    # kill. An OLDER unfinished run is NOT silently adopted (that would return
    # stale results, or trust a poisoned/abandoned dir); the user gets a fresh run
    # and can resume the old one explicitly with `--resume <dir>`.
    [ $((_now - _mt)) -le "$_fresh_window" ] || continue
    if jq -e '[.hosts[]?|select(.status|IN("reported","unreachable","failed")|not)]|length>0' \
         "${_d}state.json" >/dev/null 2>&1; then
      [ "$_mt" -gt "$_newest_mt" ] && { _newest_mt="$_mt"; _newest="${_d%/}"; }
    fi
  done
  if [ -n "$_newest" ]; then
    RUN_DIR="$_newest"
    echo "[RESUME] adopting recent in-progress run $RUN_DIR (interrupted <30m ago) — skipping completed hosts"
  fi
fi
```

On adoption, a per-host skip additionally **validates the bundle at the gate**
before trusting `collection_complete: true`: the bundle must be valid JSON whose
`.host` matches the inventory entry and whose `bundle_sha256` (recomputed) is
self-consistent. A bundle that fails validation re-collects from scratch — the
`collection_complete` flag is a convenience signal, not a security boundary
(everything under `zuvo/` is local user state; a local attacker who can write it
already has the access the audit would report).

Then in Phase 0.6 / Phase 1, **per-host idempotency:** skip any host whose
`state.json` status is already `reported` (its report is immutable) or whose
`bundle/<host>.json` has `collection_complete == true` (an unambiguous flag the
collector sets ONLY on its final, fully-scanned write — NEVER infer "done" from
a non-empty `checks[]`; an early/partial checkpoint has `collection_complete:
false` and an empty/partial `checks[]` is NOT a clean result). A host whose
bundle is absent or `collection_complete: false` re-collects from scratch (a
partial bundle is never trusted — the resume table). This makes every auto-resume
idempotent: finished hosts are not re-audited, the unfinished one continues.
Write/update `state.json` after EACH host transitions (`collecting → analyzed →
reported`) so the next auto-resume sees accurate progress.

### Phase 0.2 — Secrets-hygiene preflight (DD-10)

Before writing ANY file under `zuvo/`, confirm `zuvo/` is gitignored. If missing,
append the single line `zuvo/` with a warning. This gate runs BEFORE any SSH
connection — a git secrets leak must be prevented before collection begins.

```bash
GITIGNORE="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.gitignore"
if ! { [ -f "$GITIGNORE" ] && grep -qE '^/?zuvo/?$' "$GITIGNORE"; }; then
  printf 'zuvo/\n' >> "$GITIGNORE"
  echo "[WARN] DD-10: appended 'zuvo/' to .gitignore (was not gitignored) — audit output must never be committed"
fi
```

The ONLY write outside `RUN_DIR` permitted by the whole run is this one-time
`zuvo/` line (AC10 exemption).

### Phase 0.3 — Target source resolution + first-run scaffold (DD-2)

| Source | Action |
|--------|--------|
| `--host user@addr[:port]` | Single ad-hoc host; no inventory file. |
| `[path/to/hosts.yaml]` | Parse the supplied inventory. |
| neither, default | Use `zuvo/infra/hosts.yaml` if present. |
| neither, and `zuvo/infra/hosts.yaml` ABSENT | **First-run scaffold (DD-2):** write a commented `zuvo/infra/hosts.yaml` template (the Data Model schema below), print "scaffolded zuvo/infra/hosts.yaml — edit it and re-run", and EXIT. Never invent hosts. |

**hosts.yaml scaffold (DD-2)** — written verbatim on first run when no inventory exists:

```yaml
# zuvo:infra-audit inventory — edit then re-run `zuvo:infra-audit`.
defaults:
  ssh_user: deploy
  ssh_port: 22
  # External-vantage source (pick ONE; scan_via takes precedence). scan_via is the
  # recommended + macOS-safe option: the external leg runs FROM this SSH host using
  # portable nc/openssl/curl — no proxychains, no local scanner install. proxy is the
  # SOCKS/HTTP path (needs proxychains-ng; does NOT work on macOS due to SIP).
  scan_via: bastion.example.com    # ssh target to scan from; overridable per host / $ZUVO_SCAN_VIA
  # proxy: socks5://127.0.0.1:1080 # alt external-scan proxy; overridable / $ZUVO_SCAN_PROXY
hosts:
  - name: web01                    # required, unique
    address: 203.0.113.10          # required (IP or DNS name)
    # ssh_user: root               # optional, overrides defaults
    # ssh_port: 22                 # optional
    # ssh_key: ~/.ssh/id_ed25519   # optional (else ssh config/agent); path only — key never read
    # jump_host: bastion.example.com  # optional → ProxyJump
    # roles: [web, docker, postgres]  # optional hints for dimension targeting
    # external_fqdn: example.com   # optional; target for IS4/IS8 external checks
```

### Phase 0.4 — Inventory parse, dedup, resolve (E11)

Parse the inventory into a host list (`name`, `address`, `ssh_user`, `ssh_port`,
`ssh_key`, `jump_host`, `roles`, `external_fqdn`). Then:

1. Resolve each `address` → IP and reverse PTR.
2. **Duplicate-IP dedup (E11):** if two entries resolve to the **same IP**, MERGE
   them into one target and print `[WARN] duplicate IP <ip> — entries <a>,<b> merged; audited once`. Audit the merged host exactly once.
3. `name` must be unique (error on collision).
4. No password fields exist in the schema; password auth must be pre-configured
   in `~/.ssh/config`/agent. The skill never prompts for or stores SSH passwords
   (ssh-probe-protocol §4).

### Phase 0.5 — AUTHORIZATION GATE (ssh-probe-protocol §1) — BLOCKING

This gate **precedes any SSH connection**. Display the resolved target list as a
host→IP→PTR table and require explicit confirmation. Follow
`ssh-probe-protocol.md` §1 exactly.

```
AUTHORIZATION GATE — these LIVE hosts will be audited over SSH:

  name     resolved-ip      PTR (reverse DNS)        ssh
  web01    203.0.113.10     web01.example.com.       deploy@203.0.113.10:22
  db01     203.0.113.20     db01.example.com.        deploy@203.0.113.20:22

Confirm you OWN and are AUTHORIZED to audit every host above. Connect? [y/N]
```

| Scenario | Action |
|----------|--------|
| User confirms ("y") | Proceed to Phase 0.6 (per-host probes). |
| User declines ("n" / anything not "y") | **ABORT** — zero SSH connections opened, no run-dir writes beyond the Phase 0.1 mkdir + DD-10 line. |
| Non-interactive run | Authorization ONLY via `--confirm-targets <sha256>` matching the sha256 of the resolved target list (canonical serialization per ssh-probe-protocol §1). |
| `--confirm-targets` absent OR hash mismatch (non-interactive) | **ABORT immediately** — re-resolve, recompute the canonical hash, and abort on any mismatch (DNS-TOCTOU recompute-and-abort). Target authorization is NEVER `[AUTO-DECISION]`. |

`--dry-run` prints the canonical target list AND its sha256 so the user can copy
the hash into a subsequent `--confirm-targets <sha256>` invocation. `[AUTO-DECISION]`
applies ONLY to low-risk defaults (E13 skip-external when no proxy), never to
target authorization.

### Phase 0.6 — Per-host probe sequence

For each authorized host, in order (a host failing any step writes
`bundle/<host>.phase0.json` so Phase 3 still renders its per-host report — E4/AC8):

1. **Reachability (E5):** `nc -zw5 <ip> <port>`. Fail → `phase0.json` status
   `UNREACHABLE`, fleet CONTINUES (AC1).
2. **SSH probe (E1):** connect with the IC-8 flag string (ssh-probe-protocol §2).
   `BatchMode=yes` fails fast on key-auth failure → `SKIPPED — key-auth-failed`,
   never prompt for a password. Host-key unknown (first contact) →
   `SKIPPED — host-key-unknown` with the `ssh-keyscan` instruction.
3. **Host-key mismatch (E4):** `LC_ALL=C` ssh; if stderr carries
   `REMOTE HOST IDENTIFICATION HAS CHANGED` → halt this host, write
   `phase0.json` reason `host-key-mismatch` with a CRITICAL `HOST-KEY-MISMATCH`
   finding, print `ssh-keygen -R <address>`. Fleet continues.
4. **Privilege probe (E3 / §3):** `sudo -n true` → `privilege_mode`
   `root | passwordless-sudo | limited-sudo | no-sudo`. `needs_sudo` checks become
   `insufficient-data` when unprivileged (never `ok`).
5. **OS detection (E10 — Alpine branch):** read `/etc/os-release`; if
   `/etc/alpine-release` exists → Alpine path: **skip lynis**, use `apk`-based
   checks (`apk version`, `apk info`) for patch posture, label lynis-sourced
   dimensions `DEGRADED (alpine — lynis N/A)`. Containers-as-targets are audited
   via `docker exec` from the host, not SSH.
6. **Remote tool probe:** `which lynis nmap trivy grype debsecan needrestart docker ss`
   → populate `tool_availability` (records absent tools as `null`).
7. **Consent-gated install (DD-3 / E14):** for each missing tool, unless
   `--no-install`, offer installation with a **per-host consent gate**. Consent →
   install logged with its uninstall command (`apt remove <tool>`); decline or
   `--no-install` → affected dimension runs manual fallbacks, labeled `DEGRADED`.
   **pgdsat dual consent (E14):** pgdsat (IS10) requires BOTH the DD-3 install
   consent AND a separate query-consent (it runs SQL against the live DB);
   declining either → IS10 runs SSH-only config reads + checklist, labeled
   `DEGRADED (pgdsat declined)`. pgdsat runs ON the host as the `postgres` OS user
   over SSH (never a laptop-direct DB connection).

`state.json` for each host: `pending → collecting` as Phase 1 begins.

---

## Phase 1 — COLLECT (deterministic, scripts/infra-collect.sh, per host)

The collector is the **only** writer of the bundle; analysts are read-only
consumers. One SSH session per host; long scans run via nohup with a `.rc`
completion marker (ssh-probe-protocol §2). Secrets are redacted at the collector
BEFORE any bundle/raw write (IC-5). Raw outputs are preserved under `raw/` and
NEVER fed to the LLM.

### Collector invocation contract

Resolve the collector path with a glob fallback (Claude Code distributes it via
`install.sh`'s `cp scripts/*.sh`; the install-root path differs per platform):

```bash
COLLECTOR="$(command -v infra-collect.sh 2>/dev/null \
  || ls "{plugin_root}/scripts/infra-collect.sh" 2>/dev/null \
  || ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/infra-collect.sh 2>/dev/null \
  || ls ~/.codex/scripts/infra-collect.sh ~/.cursor/scripts/infra-collect.sh 2>/dev/null | head -1)"
[ -n "$COLLECTOR" ] || { echo "ERROR: infra-collect.sh not found (install.sh not run?)"; exit 1; }
```

Invoke per host, passing `ssh_key` / `known_hosts` / `proxy` resolved from
`hosts.yaml` (DD-2 schema). The collector applies the IC-8 SSH invariants itself.

```bash
"$COLLECTOR" \
  --host "$ssh_user@$ip:$ssh_port" \
  --ssh-key "$ssh_key" \                  # path only — key material never read (§4)
  --known-hosts "$known_hosts" \          # StrictHostKeyChecking stays =yes
  ${proxy:+--proxy "$proxy"} \            # IC-4: resolved --proxy > hosts.yaml default > $ZUVO_SCAN_PROXY
  ${scan_via:+--scan-via "$scan_via"} \   # IC-4: external leg from a remote SSH host (portable nc/openssl/curl; macOS-safe). resolved --scan-via > defaults.scan_via > $ZUVO_SCAN_VIA
  ${QUICK:+--quick} \
  ${DIMENSIONS:+--dimensions "$DIMENSIONS"} \
  ${NO_INSTALL:+--no-install} \
  ${DEEP_SCAN:+--deep-scan} \
  ${SKIP_EXTERNAL:+--skip-external} \
  ${EXTERNAL_MODE:+--external "$EXTERNAL_MODE"} \
  ${external_fqdn:+--external-target "$external_fqdn"} \   # IC-4: public surface scanned externally (else bare addr)
  --run-id "$RUN_ID" \
  --out "$RUN_DIR/bundle/$name.json" \
  --raw-dir "$RUN_DIR/raw"
```

The collector emits the IC-3 bundle: `host`, `collected_at`, `privilege_mode`,
`os`, `tool_availability` (incl. grype), `tools_installed_this_run`, `checks[]`
(each `{id, dimension, status, evidence, source, raw_ref, needs_sudo}`), and
`external.vantage`. **The collector DETECTS** — it classifies each check into
`ok | finding | insufficient-data | skipped | error` deterministically (DD-5/DD-8;
empty output ≠ PASS). On preflight failure it writes `bundle/<host>.phase0.json`.

`state.json`: host `collecting → analyzed`-eligible once the bundle is written.
Incremental bundle writes make the collect step resume-safe.

---

## Phase 2 — ANALYZE (parallel LLM analyst agents, per layer)

Dispatch the four analysts **in parallel**. Each receives ONLY its layer's
normalized bundle slice + the registry; each emits findings grounded on existing
`bundle.checks[].id` (IC-3) and records `bundle_sha256` of the source bundle.

### Analyst dimension grouping

| Agent | File | Dimensions |
|-------|------|-----------|
| Host Analyst | `agents/host-analyst.md` | IS1, IS2, IS5, IS6, IS7, IS11 |
| Network Analyst | `agents/network-analyst.md` | IS3, IS4, IS8 |
| Container Analyst | `agents/container-analyst.md` | IS9 |
| Data Analyst | `agents/data-analyst.md` | IS10, IS12 |

### Agent dispatch

Refer to `../../shared/includes/env-compat.md` for dispatch patterns per
environment.

**Claude Code (primary):** use the Agent tool to run all four in parallel, once
per host bundle:

```
Agent 1: Host Analyst
  model: "sonnet"
  type: "Explore"
  instructions: read agents/host-analyst.md
  input: path to bundle/<host>.json + the registry; writes findings/<host>-host.json

Agent 2: Network Analyst
  model: "sonnet"
  type: "Explore"
  instructions: read agents/network-analyst.md
  input: path to bundle/<host>.json + the registry; writes findings/<host>-network.json

Agent 3: Container Analyst
  model: "sonnet"
  type: "Explore"
  instructions: read agents/container-analyst.md
  input: path to bundle/<host>.json + the registry; writes findings/<host>-container.json

Agent 4: Data Analyst
  model: "sonnet"
  type: "Explore"
  instructions: read agents/data-analyst.md
  input: path to bundle/<host>.json + the registry; writes findings/<host>-data.json
```

<!-- PLATFORM:CODEX -->
**Codex:** define TOML agents per env-compat.md patterns; each runs in a
read-only sandbox referencing `agents/<name>.md`.
<!-- /PLATFORM:CODEX -->

<!-- PLATFORM:CURSOR -->
**Cursor / Antigravity:** no agent spawning. Execute each analyst's procedure
sequentially yourself, reading `agents/<name>.md`, preserving the identical
`findings/<host>-<layer>.json` output format.
<!-- /PLATFORM:CURSOR -->

### Degraded-dispatch fallback (env-compat)

**Consecutive dispatch rate-limits = agent failure.** If sub-agent dispatch
returns a rate-limit / overloaded / quota error **twice in a row** for the same
host's analysis stage, print `[MODE SWITCH] dispatch rate-limited ×2 → single-agent`,
record reason `same-model-fallback`/`rate-limited`, and execute that host's four
analyst roles **inline** (single-agent) per the checkpoint protocol. Do NOT spin
retrying a rate-limited dispatch — fall back and keep moving (`no-pause-protocol`).

**Already in a storm → go inline immediately (don't prolong it).** If THIS run
has already been auto-resumed by the StopFailure watchdog (i.e. you entered via a
watchdog `RESUME`, or you've seen ≥1 API-error/rate-limit auto-resume this run),
do NOT attempt the parallel 4-agent dispatch at all for the remaining hosts —
print `[MODE SWITCH] mid-storm → single-agent inline (skip dispatch)` and run the
analysts inline from the first host. Dispatching N×4 sub-agents into an active
rate-limit storm just extends it; inline analysis over the already-written
bundles is deterministic (severity is registry-driven — DD-7) and completes
without burning more dispatch quota. This is the observed-2026-06-12 recovery
path: 7 auto-resumes, recovered by inline analysis over the checkpointed bundles.

### bundle_sha256 stale-findings guard (IC-3)

Each `findings/<host>-<layer>.json` records the `bundle_sha256` of the bundle it
was derived from. At aggregation OR resume time, if `bundle_sha256` does **not**
match the current bundle's `shasum -a 256`, the findings are stale — the
**mismatch forces re-analysis** of that bundle (re-dispatch the analyst). Findings
whose sha matches are trusted as-is.

`state.json`: host `analyzed` once all four findings files exist with matching sha.

---

## Phase 3 — AGGREGATE (deterministic)

> Load Stage 2 includes before writing any report file.

Phase 3 is **deterministic** — no LLM scoring. Collate the four findings files per
host, then per the registry.

### Phase 3.1 — Grounding gate (IC-3)

Every analyst finding MUST cite an existing `bundle.checks[].id`. Drop any finding
whose `check_id` is not present in that host's bundle, logging it:

```
UNGROUNDED-FINDING dropped: <check_id> (host <name>) — not in bundle.checks[]
```

### Phase 3.2 — IC-6 CVE grep gate

For every candidate finding, every `CVE-\d{4}-\d+` string it carries MUST appear
**verbatim** in that host's `raw/` tool output (trivy/grype/debsecan/apt). Grep
the raw dir; a CVE with no raw evidence is stripped and logged:

```bash
for cve in $(printf '%s\n' "$finding_cves" | grep -oE 'CVE-[0-9]{4}-[0-9]+' | sort -u); do
  if ! grep -rqF "$cve" "$RUN_DIR/raw/"; then
    echo "CVE-EVIDENCE-MISSING dropped: $cve (host $name) — not in raw/ tool output"
    # strip $cve from the finding; LLM version→CVE mapping is forbidden (IC-6/DD-6)
  fi
done
```

### Phase 3.3 — Severity via registry (DD-7)

Severity is assigned ONLY by `infra-check-registry.md` lookup keyed on `check_id`.
The analyst PROPOSED a severity; the registry DECIDES. Lynis defaults: WARNING →
MEDIUM, SUGGESTION → LOW; escalation above MEDIUM requires an explicit registry
row. Map to the unified vocabulary per `severity-vocabulary.md`
(CRITICAL/HIGH/MEDIUM/LOW → S1/S2/S3/S4, identical to security-audit).

### Phase 3.4 — Internal/external diff (firewall verdict)

Diff the internal listeners (`ss -tulpn` / loopback nmap) against the external
vantage view (`external.open_ports`). The diff is the firewall-effectiveness
proof. Verdict per `external.vantage`:

| vantage | IS3 firewall verdict |
|---------|----------------------|
| `proxy` / `direct` | full diff: ports visible externally but not intended → finding |
| `none` | `rules-only` (rules read but not externally verified) |
| `failed` | `rules-only`, IS4/IS8 `DEGRADED (proxy-failed)` |

The collector's `external` block is:
`external: { vantage, proxy_used, open_ports, tls, nuclei_findings, notes }`.
`notes` is an array of degradation/abort messages (tool-absent skips, the DD-4
zero-open-ports nuclei abort, proxy/refused notes) — the network-analyst surfaces
them so reduced external coverage is visible in the IS3/IS4/IS8 verdict, never
silently masked by an empty `open_ports`/`tls`/`nuclei_findings`.

### Phase 3.5 — Per-host report → fleet-summary written LAST

Write each per-host report (`<host>.md` + `<host>.json`) FIRST, then assemble
`fleet-summary.md` **LAST** (a crash mid-run leaves no fleet-summary — its absence
signals an incomplete run; per-host reports are immutable once written).

```bash
# fleet-summary is written AFTER every per-host report exists (written LAST).
write_fleet_summary "$RUN_DIR"/*.md > "$RUN_DIR/fleet-summary.md"
```

`state.json`: host `analyzed → reported` after its per-host report is written.

### Per-host report header template

```markdown
# infra-audit — <host>  (<resolved-ip>)
- host_status: OK | DEGRADED | UNREACHABLE | FAILED | SKIPPED
- privilege_mode: root | passwordless-sudo | limited-sudo | no-sudo
- coverage_mode: FULL | DEGRADED            # DEGRADED when any tool absent/declined/wall-clock
- external.vantage: proxy | direct | none | failed
- collected_at: <ISO-8601Z>   bundle_sha256: <sha>

## Tool Availability Block
| tool | available | source |
|------|-----------|--------|
| lynis | 3.1.1 | host | … |       # each missing tool listed; DEGRADED dimensions note their fallback

## Findings (severity via registry)
| severity | check_id | dimension | evidence | remediation (CIS) |
| ... |

## Coverage notes
- per-dimension fallback notes for every DEGRADED dimension
```

When any tool is absent / install declined / wall-clock-skipped, the per-host
header MUST carry `coverage_mode: DEGRADED` (AC9) and the Tool Availability Block
MUST list every missing tool with its per-dimension fallback note. A fully-covered
host gets `coverage_mode: FULL`.

### Fleet-summary template

```markdown
# infra-audit fleet-summary  (<RUN_TS>)
| host | status | grade | critical | high | vantage | coverage_mode |
|------|--------|-------|----------|------|---------|---------------|
| web01 | OK | B | 0 | 2 | proxy | FULL |
| db01  | UNREACHABLE | - | - | - | - | - |     # unreachable hosts still listed (AC1)
```

---

## Resume Semantics (`--resume <run-dir>`)

`state.json` workflow status per host drives resume. Process states
(`pending|collecting|analyzed|reported|unreachable|failed`) are distinct from the
outcome vocabulary (`OK|DEGRADED|UNREACHABLE|FAILED|SKIPPED`, IC-2).

| status | action on resume |
|--------|------------------|
| `pending` | run full collection + analysis + report |
| `collecting` | re-run collection from scratch (idempotent; a partial bundle is never trusted — overwrite) |
| `analyzed` | skip collection AND analysis ONLY when all four `findings/<host>-<layer>.json` files exist AND each file's `bundle_sha256` matches the current bundle (IC-3 stale-findings guard); on any `bundle_sha256` mismatch the mismatch forces re-analysis from the bundle |
| `reported` | skip entirely; the per-host report file is untouched (mtime unchanged) |
| `unreachable` | retry from `pending` (the cause may have been fixed) |
| `failed` | retry from `pending` (the cause may have been fixed) |

`fleet-summary.md` is regenerated from per-host reports at the end of every
resumed run (always written LAST).

---

## Edge Cases (E1-E15, condensed)

| # | Case | Handling |
|---|------|----------|
| E1 | Key auth fails / password-only host | `BatchMode=yes` fails fast → `SKIPPED — key-auth-failed`; never prompt/store passwords |
| E2 | Jump host required | `jump_host` → `-o ProxyJump=`; jump unreachable → `UNREACHABLE — jump-host-failed` |
| E3 | No sudo | `sudo -n true` probe; `needs_sudo` checks → `insufficient-data`, never `ok` (AC4) |
| E4 | Host-key mismatch | CRITICAL `HOST-KEY-MISMATCH`, halt host, `phase0.json`, manual `ssh-keygen -R`; never auto-accept |
| E5 | Unreachable / typo'd address | `nc -zw5` preflight → `UNREACHABLE`, fleet continues (AC1) |
| E6 | Missing remote tools | DD-3 consent gate → install or fallback matrix + `DEGRADED` |
| E7 | Long scans / dropped session | IC-8 nohup `.rc` marker; incremental bundle; `--resume` |
| E8 | fail2ban / IDS | External leg via `scan_via` (ban hits the scan host's IP, not the operator's) or proxy; `--external direct` → `-T2 --max-rate 50` + abort threshold |
| E9 | Secrets in collected configs | IC-5 redaction at collector + DD-10 gitignore preflight |
| E10 | Alpine / containers as targets | `/etc/alpine-release` detection → skip lynis, use `apk` checks; containers via `docker exec` |
| E11 | Duplicate inventory IPs | merge + `[WARN] duplicate IP`, audit once |
| E12 | lynis < 3.0 | version probe → manual fallback + `DEGRADED (lynis vX < 3.0)` |
| E13 | No external vantage configured | **Dual-vantage is the default** when a vantage resolves (`scan_via` / `proxy`): the skill runs internal AND external automatically. With NONE configured: ask once → `--scan-via <ssh-host>` (recommended, macOS-safe), `--external direct` (polite proxyless), or `--skip-external`; non-interactive → skip-external `[AUTO-DECISION]` (targets are NEVER auto-decided). On macOS a bare `--proxy` is steered to `--scan-via` (proxychains cannot inject under SIP). |
| E14 | pgdsat (IS10) | runs ON host as `postgres` via SSH; requires BOTH install consent AND query consent; decline either → `DEGRADED (pgdsat declined)` |
| E15 | IS4 with no `external_fqdn` (bare IP) | IS4 = `insufficient-data (no external_fqdn)` — never guessed from nginx configs |

---

## Completion gates (in order: retro → runlog → Run block)

### VALIDITY GATE (REQUIRED — print BEFORE the Run line, AFTER retro append + append-runlog)

```
VALIDITY GATE
  collector_runs: [<N hosts> | NOT_RUN]
  authorization_gate: [confirmed-interactive | confirm-targets-sha-matched | DECLINED-ABORT]
  grounding_gate: [UNGROUNDED-FINDING dropped=<N>]
  cve_gate: [CVE-EVIDENCE-MISSING dropped=<N>]
  fleet_summary_written_last: [yes | NO]
  postamble:
    retros_log_appended: [yes(bytes_added=N) | NOT_APPENDED]
    retros_md_appended: [yes(entry_count=N) | NOT_APPENDED]
  gate_status: [PASS | FAIL]
```

If `gate_status = FAIL` → VERDICT = INCOMPLETE.

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`: gate check → structured
questions → `RETRO:` TSV emit → `retros.log` + `retros.md` append. If the gate
check skips: print `RETRO: skipped (trivial session)` and proceed. The retro is
not done until both files are written.

### Run line — append via the retro-gated wrapper (NOT direct `>> runs.log`)

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Run: <ISO-8601-Z>	infra-audit	<project>	<N-critical>	<N-total>	<VERDICT>	<N-hosts>	<dimensions-mode>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>

VERDICT: PASS (0 critical findings across the fleet), WARN (1-3 critical), FAIL (4+ critical).

---

## INFRA-AUDIT COMPLETE

```
INFRA-AUDIT COMPLETE
Fleet: <N hosts> audited (<N OK> / <N DEGRADED> / <N UNREACHABLE> / <N FAILED>)
Findings: <N critical> / <N high> / <N total>  | Vantage: <proxy|direct|none|failed>
Run dir: zuvo/audits/infra-audit-<RUN_TS>/  (fleet-summary written last)
Result: PASS | WARN | FAIL
```

If fixable findings were detected, suggest the v2 follow-up:

```
Suggested next step (v2): zuvo:infra-fix is not yet available — remediation is
manual. Each per-host report lists the registry remediation + CIS reference and
(for consented installs) the exact uninstall command.
```
