# infra-suite — test suite for `zuvo:infra-audit`

Tests and Docker fixtures for the server/infrastructure security audit skill.
This is the only suite in the repo with **Docker fixtures** — read the
prerequisites before running.

## Prerequisites

| Tool | Required for | Install |
|------|--------------|---------|
| `jq` | every collector test (bundle JSON) | `brew install jq` / `apt install jq` |
| Docker + Compose v2 | the docker-integration tests + smoke harnesses | Docker Desktop, or `docker` + `docker-compose-plugin` |
| `proxychains-ng` | the external-vantage test scenarios (a–c) | `brew install proxychains-ng` (optional — those scenarios SKIP cleanly without it) |

**Tests degrade, never break, when a tool is absent.** Each docker-dependent
test sources `lib/docker-guard.sh` and prints `SKIP: docker not available`
(exit 0) when Docker is missing. The e2e driver counts SKIP separately from
FAIL — a dockerless CI run is green, not red.

## Layout

```
tests/infra-suite/
├── lib/
│   ├── docker-guard.sh        # SKIP guard: no-docker → exit 0 with message
│   └── ensure-fixtures.sh     # generates the ephemeral SSH test keypair, stages pubkeys
├── fixtures/
│   ├── docker-compose.yml     # 3 services, loopback-bound (digest-pinned images)
│   ├── sshd-misconfigured/    # ubuntu sshd with 10 seeded misconfigurations
│   ├── sshd-hardened/         # CIS-basic hardened control (key-only, root off, ufw)
│   ├── socks-proxy/           # serjs/go-socks5-proxy for the external (IC-4) leg
│   ├── hosts-3.yaml           # inventory: misconfigured(2201) + hardened(2202) + black-hole
│   └── seed-manifest.md       # the 10 seeded issues, drift-gated by Dockerfile sha256
├── test-infra-*.sh            # 10 contract/integration tests (run by the e2e driver)
├── smoke-fleet-audit.sh       # SMOKE1 verifier — Phase-Final-only (needs a real run dir)
├── smoke-resume.sh            # SMOKE2 verifier — Phase-Final-only
└── test-suite-e2e.sh          # chains all test-infra-*.sh (geo-suite TOTAL_FAIL pattern)
```

The SSH private key is **generated at runtime** by `ensure-fixtures.sh` and is
git-ignored — no key material is ever committed. `StrictHostKeyChecking=yes`
is enforced everywhere; the tests use an isolated `known_hosts`, never `~/.ssh`.

## Running

```bash
# Full suite (static tests run anywhere; docker tests run when Docker is up):
bash tests/infra-suite/test-suite-e2e.sh

# A single test:
bash tests/infra-suite/test-infra-collector-live.sh

# Bring fixtures up / tear down manually:
cd tests/infra-suite && bash lib/ensure-fixtures.sh
docker compose -p zuvo-infra-fixtures -f fixtures/docker-compose.yml up -d --build --wait
docker compose -p zuvo-infra-fixtures -f fixtures/docker-compose.yml down -v
```

## Smoke proofs (SMOKE1 / SMOKE2) — Phase-Final only

`smoke-fleet-audit.sh` and `smoke-resume.sh` are **verifiers, not runners** —
they are NOT part of the e2e driver because they need a completed run directory.
The skill itself is LLM-driven; produce a run dir first, then point the harness at it:

```bash
# 1. Bring fixtures up (see above).
# 2. Run the skill (in Claude Code):
#      /zuvo:infra-audit tests/infra-suite/fixtures/hosts-3.yaml
#    → writes zuvo/audits/infra-audit-<YYYY-MM-DD-HHMM>/
# 3. Verify the completed run:
bash tests/infra-suite/smoke-fleet-audit.sh zuvo/audits/infra-audit-<ts>
# 4. For resume (SMOKE2): interrupt after host 1 reaches `reported`, re-run with
#    --resume, then:
bash tests/infra-suite/smoke-resume.sh zuvo/audits/infra-audit-<ts>
```

Both harnesses exit 2 with a usage message if invoked without a run-dir argument.

## What the fixtures seed

`sshd-misconfigured` deliberately ships 10 findable issues (documented in
`seed-manifest.md`): root login enabled, password auth, no firewall, world-writable
cron dir, world-readable `.env` with fake `zuvo-seed-*` secrets, redis bound to
`0.0.0.0` with no auth, stale packages, container-as-root, a SUID `/bin/sh` copy,
and no fail2ban. The seed manifest is pinned to the Dockerfile's sha256 — editing
the Dockerfile without updating the manifest fails `test-infra-fixtures.sh` (drift gate).

`sshd-hardened` is the negative control: key-only SSH, `PermitRootLogin no`,
`PasswordAuthentication no`, `MaxAuthTries 3` — a correctly-configured host should
produce ≤3 findings, none CRITICAL/HIGH.
