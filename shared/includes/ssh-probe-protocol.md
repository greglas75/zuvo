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

### Canonical `--confirm-targets <sha256>` serialization

The sha256 passed to `--confirm-targets` is computed over a **canonical target list** with
this exact, deterministic serialization:

- One line per host: `name<TAB>resolved-ip<TAB>ssh-port` (fields separated by a single TAB).
- `resolved-ip` is normalized text: IPv4 as dotted-quad; IPv6 in RFC 5952 canonical form
  (lowercase hex, `::` compression, no zone-id). Dual-stack hosts hash the address family
  the audit will actually connect over (prefer IPv4 when both resolve), so the same host
  cannot hash differently across resolvers/tooling.
- Lines sorted by `name` under `LC_ALL=C` (byte-order, locale-stable).
- Exactly one trailing newline at the end of the list (no trailing blank lines).
- The sha256 is taken over those bytes verbatim.
- **DNS TOCTOU is closed by recompute-and-abort:** the run re-resolves every name at
  execution time, rebuilds the canonical list, and ABORTS on any hash mismatch — a DNS
  flip between dry-run and run can therefore only cause a safe abort, never an audit of
  an unreviewed address. The audit then connects to the exact `resolved-ip` it hashed
  (not the name) **with `-o HostKeyAlias=<name>`**, so `known_hosts` verification still
  matches the entry recorded under the hostname (and the §2 first-contact bootstrap via
  `ssh-keyscan -H <host>` stays consistent with runtime verification).
- **Dynamic/load-balanced DNS aborts by design** (accepted trade-off): audited servers are
  stable hosts; a name that resolves differently between confirm and run is exactly what
  must stop the audit. Fleets behind round-robin DNS should pin `address` to a literal IP
  in the inventory — then no DNS is involved at all.

`--dry-run` prints this canonical list **and** its sha256 so the user can copy the hash
directly into a subsequent non-interactive `--confirm-targets <sha256>` invocation. A
non-interactive run recomputes the canonical list and ABORTS on any hash mismatch (per the
Authorization Gate table above).

## 2. SSH invariants

Every `ssh` invocation MUST use the following flag string verbatim (IC-8):

```
-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes -o StrictHostKeyChecking=yes
```

- `BatchMode=yes` prevents interactive password prompts and fails fast on key-auth errors.
- `StrictHostKeyChecking=yes` is **explicit** so a weakening entry in operator `~/.ssh/config`
  (`accept-new`/`no`) can never silently apply to audited hosts — see §5.
- **First contact:** with `=yes`, a host whose key is not yet in `known_hosts` fails the
  connection (this is correct — never auto-accept). The operator adds the key BEFORE the
  first audit: verify the fingerprint out-of-band (provider console / `ssh-keygen -lf` on
  the host), then `ssh-keyscan -H <host> >> ~/.ssh/known_hosts` or connect manually once.
  Phase 0 reports such hosts as `SKIPPED — host-key-unknown (first contact)` with this
  instruction; it never weakens the flag to make first contact "work".
- The IC-8 flag string itself MUST appear in every `ssh` invocation byte-for-byte; do not
  re-type, split, or reorder the five `-o` options.
- Commands expected to run longer than 30 seconds are wrapped in nohup with a **deterministic
  completion marker** — the command's exit code is written to a `.rc` sidecar file, and
  retrieval polls for that `.rc` file (bounded) rather than guessing completion by PID:

```bash
# ONCE per host, at collection-session start (NOT per check): claim the run dir
# ATOMICALLY. mkdir(2) without -p returns EEXIST for ANY existing path — including
# a pre-planted symlink — so a guessable run-id cannot be hijacked; we refuse and
# fail closed. Mode 700 keeps other local users out.
mkdir -m 700 /tmp/zuvo-<run-id> || { echo 'run dir exists — refusing'; exit 1; }

# PER CHECK: the inner command is bounded SERVER-SIDE with IC-9's per-check timeout,
# so a check orphaned by a dropped SSH session self-kills instead of leaking forever:
nohup sh -c 'timeout <CHECK_TIMEOUT_S> <cmd> > /tmp/zuvo-<run-id>/<check>.out 2>&1; echo $? > /tmp/zuvo-<run-id>/<check>.rc' \
  < /dev/null > /dev/null 2>&1 &
# … retrieval polls (bounded) for /tmp/zuvo-<run-id>/<check>.rc; the .rc file's
#   appearance marks completion and its contents are the command's exit code
#   (124 = server-side timeout per coreutils convention).
```

  - The `mkdir` claim happens exactly once per host per run — every subsequent check
    writes into the already-claimed dir; a per-check `mkdir` would self-collide.
  - The outer `< /dev/null > /dev/null 2>&1` is mandatory — an unredirected stream on the
    backgrounded command holds the SSH session open indefinitely.
  - `<cmd>` placeholders are **static, predefined battery commands only** — never interpolate
    host-derived or user-supplied strings into the quoted command (quote-injection hazard).
    Dynamic values (paths, ports) go through validated variables in the collector, not into
    this template.

Long checks run concurrently under nohup; per-check timeouts do not stack linearly
(per IC-9's per-host 30-min wall clock guarantee).

**Secure host-key posture does not depend on operator `~/.ssh/config`.** The skill treats
`StrictHostKeyChecking` at its secure default. Any config-level weakening
(`StrictHostKeyChecking no` or `accept-new`) applied to an audited host counts as
**disabled** and violates this protocol — see §5.

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

The `ssh` invocation whose stderr is parsed for this string MUST run under `LC_ALL=C`
(e.g. `LC_ALL=C ssh …`) so the `REMOTE HOST IDENTIFICATION HAS CHANGED` match is
locale-stable and not defeated by a translated client locale.

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
not via `~/.ssh/config` overrides injected by this skill, and **not via a pre-existing
operator `~/.ssh/config`**: a `StrictHostKeyChecking no` or `accept-new` entry matching an
audited host counts as disabled and violates this protocol regardless of who wrote it.
Auto-accepting an unknown or changed key is a man-in-the-middle risk that outweighs any
audit convenience.

## 6. Rate & timing rules

### External vantage (IC-4)

External scanning runs through the configured proxy when available:

| Tool | Proxy mechanism |
|------|----------------|
| `nmap` (external leg) | `proxychains-ng` — handles SOCKS5 and HTTP transparently |
| `testssl.sh` (external leg) | `proxychains-ng` — NOT testssl's native `--proxy` (HTTP-CONNECT only; incompatible with SOCKS proxies) |
| `nuclei` | native `-proxy` flag (supports `socks5://` and `http://`) |

Because `proxychains` can only hook the `connect()` syscall (TCP), `nmap` run through the
proxy MUST use TCP connect scan (`-sT`) — never SYN (`-sS`) or UDP scans, whose raw sockets
bypass the proxy entirely and would scan from the real source IP.

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
