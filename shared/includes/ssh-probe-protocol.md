# SSH Probe Protocol

> Shared safety rules for skills that connect to live servers over SSH (`zuvo:infra-audit`).
> Parallels `live-probe-protocol.md`. Referenced by `skills/infra-audit/SKILL.md` and all
> infra analyst agents. This include is the runtime carrier of IC-8.

## 1. Authorization Gate

Every run MUST display the resolved target list as a host→IP→PTR table and require
explicit confirmation before opening any SSH connection.

| Scenario | Action |
|----------|--------|
| User confirms ("y") | Proceed with SSH connections |
| User declines ("n") | ABORT — zero SSH connections opened, no run-dir writes |
| Non-interactive run | ONLY via `--confirm-targets <sha256>` matching the sha256 of the resolved target list printed by a prior `--dry-run` |
| `--confirm-targets` absent or hash mismatch | ABORT immediately — target authorization is never auto-approved |

`[AUTO-DECISION]` semantics **never** apply to target authorization. `[AUTO-DECISION]`
applies only to low-risk defaults (e.g. E13's skip-external when no proxy is configured).
Connecting to a target host requires explicit human confirmation every time.

## 2. SSH invariants

Every `ssh` invocation MUST use the following flag string verbatim (IC-8):

```
-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes
```

- `BatchMode=yes` prevents interactive password prompts and fails fast on key-auth errors.
- `StrictHostKeyChecking` is **never** disabled — see §5.
- Commands expected to run longer than 30 seconds are wrapped in nohup and redirected:

```bash
nohup <command> > /tmp/zuvo-<run-id>/<check>.out 2>&1 &
# … retrieve output after completion
```

Long checks run concurrently under nohup; per-check timeouts do not stack linearly
(per IC-9's per-host 30-min wall clock guarantee).

## 3. Privilege probe

Phase 0 runs `sudo -n true` on each target host to determine privilege level before
any audit check executes.

| Result | `privilege_mode` recorded |
|--------|--------------------------|
| SSH user is `root` (uid 0) | `root` |
| `sudo -n true` exits 0 | `passwordless-sudo` |
| `sudo -n true` exits non-zero, sudo binary present | `limited-sudo` |
| `sudo` binary absent | `no-sudo` |

Decision tree outcome is stored in `bundle/<host>.json` as `privilege_mode`.

Any check with `needs_sudo: true` becomes `status: insufficient-data` when
`privilege_mode` is `limited-sudo` or `no-sudo`. These checks are **never** reported as
`ok` without privilege evidence — per E3 and AC4, `needs_sudo` checks have exactly
two valid terminal states when unprivileged: `insufficient-data` or `skipped`.

## 4. Key-material ban

SSH private keys and passwords are never read, logged, stored, or echoed at any point.

| Prohibited action | Notes |
|-------------------|-------|
| Reading private key files (e.g. `~/.ssh/id_*`) into any variable or log | The inventory `ssh_key` field holds only the **path** used by the ssh `-i` flag |
| Prompting for or storing SSH passwords | `BatchMode=yes` (§2) prevents interactive prompts; password fields are never added to inventory |
| Logging `SSH_AUTH_SOCK`, agent socket contents, or forwarded agent state | — |
| Echoing key material into reports, bundles, or `/tmp/zuvo-*` output files | IC-5 redaction covers config-dump values; key material never enters collection at all |

The inventory schema has no password fields (per `hosts.yaml` definition). Pre-configured
ssh-agent or `~/.ssh/config` settings are the only password-equivalent mechanisms supported.

## 5. Host-key mismatch rule

If `ssh` exits with `REMOTE HOST IDENTIFICATION HAS CHANGED` on stderr:

1. **Halt that host immediately** — no further commands execute on it.
2. Emit a CRITICAL finding with id `HOST-KEY-MISMATCH` in `bundle/<host>.phase0.json`
   (so the per-host report renders even with no collection data — per E4/AC8).
3. Print the manual recovery instruction:
   ```
   ssh-keygen -R <address>
   ```
   and ask the user to verify the new host key out-of-band before re-running.
4. Fleet run continues with remaining hosts; the mismatched host status is `FAILED — host-key-mismatch`.

`StrictHostKeyChecking` is **never** disabled — not via `-o StrictHostKeyChecking=no`,
not via `~/.ssh/config` overrides injected by this skill. Auto-accepting an unknown or
changed key is a man-in-the-middle risk that outweighs any audit convenience.

## 6. Rate & timing rules

### External vantage (IC-4)

External scanning runs through the configured proxy when available:

| Tool | Proxy mechanism |
|------|----------------|
| `nmap` (external leg) | `proxychains-ng` — handles SOCKS5 and HTTP transparently |
| `testssl.sh` (external leg) | `proxychains-ng` — NOT testssl's native `--proxy` (HTTP-CONNECT only; incompatible with SOCKS proxies) |
| `nuclei` | native `-proxy` flag (supports `socks5://` and `http://`) |

`--external direct` is an explicit user opt-in; it enforces `-T2 --max-rate 50` polite
timing and aborts the external leg after 3 consecutive connection-refused or ban signals
(DD-4). Without a proxy and without `--external direct`, external vantage = `none` and
the IS3 firewall verdict is `rules-only`.

### Consent-gated tool installation (DD-3)

Missing tools on a target host are offered for installation with a **per-host consent gate**:

- Consent given → install logged in the report with its uninstall command (`apt remove <tool>`).
- Consent declined OR `--no-install` passed → affected dimension runs manual fallbacks and
  is labeled `DEGRADED`.
- `--no-install` disables the gate entirely (hard read-only mode).

### Secrets hygiene preflight (DD-10)

Before writing any file under `zuvo/`, Phase 0 checks that `zuvo/` appears in `.gitignore`.
If missing, the line is appended automatically with a warning. This gate runs before any
SSH connection — a secrets leak via git must be prevented before collection begins.
