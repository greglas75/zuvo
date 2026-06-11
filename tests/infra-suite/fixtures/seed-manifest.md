# Infra fixture seed manifest

Documents the 10 deliberately-seeded issues in the **sshd-misconfigured**
container. Each `literal value` below is an exact, greppable string that must
exist in its `fixture file` — the contract test (`test-infra-fixtures.sh`)
fails if any drifts. Paths are relative to `tests/infra-suite/fixtures/`.

The `Dockerfile-sha256` comment pins the misconfigured Dockerfile so silent
edits (e.g. dropping a seed) are caught.

# Dockerfile-sha256: 5cc16bca56476b7a740d1fff6c5862b4209f5bee83e644b41de2dc11acbecfb1

| IS# | seed-id | literal value | fixture file | expected detection source |
| --- | --- | --- | --- | --- |
| IS1 | permit-root-login | PermitRootLogin yes | sshd-misconfigured/sshd_config | sshd -T / config grep |
| IS1 | password-auth | PasswordAuthentication yes | sshd-misconfigured/sshd_config | sshd -T / config grep |
| IS5 | no-firewall | # SEED: no-firewall | sshd-misconfigured/Dockerfile | ufw/iptables status check |
| IS11 | world-writable-cron | chmod 777 /etc/cron.d | sshd-misconfigured/Dockerfile | filesystem perms scan |
| IS12 | leaked-secrets | zuvo-seed-jwt-4b8d | sshd-misconfigured/env.seed | secret scanner on /opt/app/.env |
| IS10 | redis-no-auth | bind 0.0.0.0 | sshd-misconfigured/redis.conf | redis.conf grep / port probe |
| IS6 | stale-packages | # SEED: stale-packages | sshd-misconfigured/Dockerfile | package freshness check |
| IS9 | runs-as-root | # SEED: runs-as-root | sshd-misconfigured/Dockerfile | container USER / runtime uid check |
| IS11 | suid-shell | chmod 4755 /usr/local/bin/seed-suid-sh | sshd-misconfigured/Dockerfile | SUID binary scan |
| IS7 | no-fail2ban | # SEED: no-fail2ban | sshd-misconfigured/Dockerfile | fail2ban presence check |
