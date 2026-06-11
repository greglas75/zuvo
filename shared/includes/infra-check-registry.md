# Infra Check Registry

> Single source of truth for all check IDs used in `infra-audit` findings.
> Analyst agents MUST use these exact IDs in `bundle.checks[].id` and findings.
> Phase 3 aggregation parses this table to resolve `default_severity` and `remediation_template`.
>
> **Column order is NORMATIVE** — parsed by Phase 3 aggregation and analyst agents.
> Do NOT reorder or rename columns.

## Lynis Default Severity Mapping (DD-7)

Lynis test IDs NOT explicitly listed in this registry map by default:
- `WARNING` → `MEDIUM`
- `SUGGESTION` → `LOW`
- Escalation above MEDIUM requires an explicit registry row with `default_severity` = `HIGH` or `CRITICAL`.

## IS1 — SSH Hardening

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS1-sshd-permitrootlogin | IS1 | CRITICAL | SSH-7408 | Set `PermitRootLogin no` in /etc/ssh/sshd_config, then `sshd -t && systemctl reload sshd` | CIS 5.2.8 |
| IS1-sshd-passwordauthentication | IS1 | HIGH | SSH-7408 | Set `PasswordAuthentication no` in /etc/ssh/sshd_config, then `sshd -t && systemctl reload sshd` | CIS 5.2.9 |
| IS1-sshd-maxauthtries | IS1 | MEDIUM | SSH-7408 | Set `MaxAuthTries 4` (or lower) in /etc/ssh/sshd_config, then `sshd -t && systemctl reload sshd` | CIS 5.2.7 |
| IS1-sshd-x11forwarding | IS1 | MEDIUM | SSH-7408 | Set `X11Forwarding no` in /etc/ssh/sshd_config, then `sshd -t && systemctl reload sshd` | CIS 5.2.6 |
| IS1-sshd-protocol-algos | IS1 | HIGH | - | Remove weak KEX/ciphers/MACs from sshd_config; run `ssh-audit localhost` to verify; reload: `systemctl reload sshd` | CIS 5.2.16 |

## IS2 — Accounts & Auth

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS2-uid0-nonroot | IS2 | CRITICAL | - | Audit with `awk -F: '($3==0){print}' /etc/passwd`; remove or lock any non-root UID-0 account: `usermod -L <user>` | CIS 6.2.5 |
| IS2-sudoers-nopasswd-all | IS2 | HIGH | - | Remove `NOPASSWD:ALL` from /etc/sudoers and /etc/sudoers.d/*; use specific command allowlists instead | CIS 5.3.7 |
| IS2-inactive-accounts | IS2 | MEDIUM | - | Lock accounts inactive >90 days: `usermod -L <user>`; set inactive lock: `useradd -D -f 30` | CIS 5.4.1.4 |
| IS2-pam-pwquality | IS2 | MEDIUM | - | Install libpam-pwquality and configure minlen=14, dcredit=-1, ucredit=-1 in /etc/security/pwquality.conf | CIS 5.3.1 |

## IS3 — Network Exposure

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS3-unexpected-listener | IS3 | HIGH | - | Identify with `ss -tulpn`; stop unexpected service: `systemctl stop <service> && systemctl disable <service>` | CIS 2.2 |
| IS3-db-bound-public | IS3 | CRITICAL | - | Bind database listener to 127.0.0.1 or a private IP; e.g. PostgreSQL: set `listen_addresses = '127.0.0.1'` in postgresql.conf, reload | CIS 2.2 |
| IS3-firewall-diff-mismatch | IS3 | HIGH | - | Reconcile internal (`ss -tulpn`) vs external scan results; add DROP/REJECT rules for unexpected open ports: `ufw deny <port>` | - |

## IS4 — TLS & Certificates

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS4-cert-expired | IS4 | CRITICAL | - | Renew certificate immediately: `certbot renew --force-renewal`; verify with `openssl s_client -connect host:443 </dev/null 2>&1 \| grep 'notAfter'` | - |
| IS4-cert-expiring-30d | IS4 | HIGH | - | Renew certificate before expiry: `certbot renew`; configure cron/timer for auto-renewal | - |
| IS4-weak-protocols | IS4 | HIGH | - | Disable SSLv3/TLS 1.0/1.1 in web server config (nginx: `ssl_protocols TLSv1.2 TLSv1.3;`); reload service | CIS 2.2.7 |
| IS4-weak-ciphers | IS4 | HIGH | - | Remove weak cipher suites (RC4, DES, EXPORT) from TLS config; use `ssl_ciphers ECDHE+AESGCM:DHE+AESGCM:!aNULL` in nginx | CIS 2.2.7 |

## IS5 — Firewall & Kernel Network

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS5-ufw-disabled | IS5 | HIGH | FIRE-4508 | Enable firewall: `ufw enable`; verify status: `ufw status verbose` | CIS 3.4.1 |
| IS5-default-allow-incoming | IS5 | CRITICAL | - | Set default deny incoming: `ufw default deny incoming && ufw allow <required-ports> && ufw enable` | CIS 3.4.2 |
| IS5-ip-forwarding-on | IS5 | MEDIUM | - | Disable IP forwarding unless required: `sysctl -w net.ipv4.ip_forward=0`; persist in /etc/sysctl.d/99-hardening.conf | CIS 3.1.1 |
| IS5-syncookies-off | IS5 | HIGH | - | Enable SYN cookies: `sysctl -w net.ipv4.tcp_syncookies=1`; persist in /etc/sysctl.d/99-hardening.conf | CIS 3.2.8 |

## IS6 — Patch Posture

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS6-security-updates-pending | IS6 | HIGH | - | Apply security updates: `apt-get update && apt-get upgrade -y`; check with `apt list --upgradable 2>/dev/null \| grep security` | CIS 1.8.1 |
| IS6-kernel-reboot-required | IS6 | MEDIUM | - | Reboot to apply new kernel: schedule maintenance window and `reboot`; verify after: `uname -r` | - |
| IS6-eol-distro | IS6 | CRITICAL | - | Upgrade to a supported OS release; see Ubuntu upgrade: `do-release-upgrade` (test in staging first) | - |
| IS6-unattended-upgrades-off | IS6 | MEDIUM | - | Enable unattended security updates: `apt-get install -y unattended-upgrades && dpkg-reconfigure unattended-upgrades` | CIS 1.8.2 |

## IS7 — Logging & Intrusion Detection

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS7-auditd-missing | IS7 | MEDIUM | - | Install and enable auditd: `apt-get install -y auditd && systemctl enable auditd --now`; configure rules in /etc/audit/rules.d/ | CIS 4.1.1 |
| IS7-fail2ban-missing | IS7 | MEDIUM | - | Install and enable fail2ban: `apt-get install -y fail2ban && systemctl enable fail2ban --now`; configure /etc/fail2ban/jail.local | - |
| IS7-log-retention-short | IS7 | LOW | - | Set journal retention: add `SystemMaxUse=2G` and `MaxRetentionSec=90day` to /etc/systemd/journald.conf; restart journald | CIS 4.2.2 |
| IS7-rsyslog-off | IS7 | MEDIUM | - | Enable rsyslog: `systemctl enable rsyslog --now`; verify logs flow to /var/log/syslog | CIS 4.2.1 |

## IS8 — Deployed Web Services

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS8-exposed-admin-panel | IS8 | HIGH | - | Restrict admin panel access by IP (nginx: `allow <mgmt-ip>; deny all;` inside location block) or move behind VPN | - |
| IS8-known-cve-template-hit | IS8 | HIGH | - | Apply vendor patch or workaround for identified CVE; verify with `nuclei -id <template-id>` after patching | - |
| IS8-missing-security-headers | IS8 | LOW | - | Add to nginx: `add_header X-Frame-Options SAMEORIGIN; add_header X-Content-Type-Options nosniff; add_header Referrer-Policy no-referrer-when-downgrade;` | - |

## IS9 — Docker

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS9-socket-world-readable | IS9 | CRITICAL | - | Restrict Docker socket: `chmod 660 /var/run/docker.sock && chgrp docker /var/run/docker.sock`; remove world-readable bits | CIS 2.2 |
| IS9-container-as-root | IS9 | MEDIUM | - | Add `USER <nonroot>` directive to Dockerfile; or set `user: "1000:1000"` in docker-compose.yml | - |
| IS9-image-critical-cve | IS9 | HIGH | - | Rebuild image from a patched base (e.g. `FROM ubuntu:24.04`) and redeploy; re-scan with `trivy image <name>` | - |
| IS9-privileged-container | IS9 | CRITICAL | - | Remove `--privileged` flag from docker run / privileged: true from compose; grant only specific capabilities with `--cap-add` | - |

## IS10 — Database Servers

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS10-redis-no-auth | IS10 | CRITICAL | - | Set `requirepass <strong-password>` in /etc/redis/redis.conf; restart: `systemctl restart redis` | - |
| IS10-redis-bound-public | IS10 | CRITICAL | - | Bind Redis to localhost: set `bind 127.0.0.1` in /etc/redis/redis.conf; restart: `systemctl restart redis` | - |
| IS10-pg-trust-auth | IS10 | CRITICAL | - | Replace `trust` with `scram-sha-256` or `md5` in /etc/postgresql/*/main/pg_hba.conf; reload: `systemctl reload postgresql` | CIS DB 1.3.1 |
| IS10-pg-listen-all | IS10 | HIGH | - | Restrict PostgreSQL listener: set `listen_addresses = '127.0.0.1'` in postgresql.conf; reload postgresql | - |
| IS10-mysql-anonymous-user | IS10 | HIGH | - | Remove anonymous MySQL users: `DELETE FROM mysql.user WHERE User=''; FLUSH PRIVILEGES;` | CIS DB 3.1 |

## IS11 — Filesystem & Kernel Hardening

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS11-suid-unexpected | IS11 | HIGH | - | Remove unexpected SUID bit: `chmod u-s <path>`; audit with `find / -xdev -perm -4000 -type f 2>/dev/null` | CIS 6.1.11 |
| IS11-world-writable-dir | IS11 | MEDIUM | - | Remove world-writable on non-tmp paths: `chmod o-w <path>`; audit with `find / -xdev -perm -0002 -type d 2>/dev/null` | CIS 6.1.10 |
| IS11-tmp-noexec-missing | IS11 | LOW | - | Mount /tmp with noexec: add `noexec` to /tmp entry in /etc/fstab (or systemd override for tmp.mount), then `mount -o remount,noexec /tmp` | CIS 1.1.3 |
| IS11-apparmor-disabled | IS11 | MEDIUM | - | Enable AppArmor: `systemctl enable apparmor --now`; enforce profiles: `aa-enforce /etc/apparmor.d/*` | CIS 1.6.1 |

## IS12 — Secrets Hygiene on Host

| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |
|----------|-----------|------------------|---------------|----------------------|---------|
| IS12-world-readable-env | IS12 | CRITICAL | - | Restrict .env file permissions: `chmod 600 /path/to/.env && chown <app-user>:<app-user> /path/to/.env` | - |
| IS12-secrets-in-history | IS12 | HIGH | - | Clear shell history: `history -c && > ~/.bash_history`; configure `HISTCONTROL=ignorespace` and set `HISTSIZE=0` for service accounts | - |
| IS12-key-in-homedir-world-readable | IS12 | HIGH | - | Restrict key file permissions: `chmod 600 ~/.ssh/id_* && chmod 700 ~/.ssh`; audit with `find ~ -name '*.pem' -o -name '*.key' -perm /044 2>/dev/null` | - |
