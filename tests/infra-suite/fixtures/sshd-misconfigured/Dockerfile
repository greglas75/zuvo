# Misconfigured sshd fixture for zuvo:infra-audit — TEST-ONLY, deliberately weak.
# Pinned by digest for reproducibility (ubuntu:24.04 as of 2026-06-11).
FROM ubuntu@sha256:786a8b558f7be160c6c8c4a54f9a57274f3b4fb1491cf65146521ae77ff1dc54

ENV DEBIAN_FRONTEND=noninteractive

# SEED: stale-packages — deliberately do NOT run `apt-get upgrade`, leaving the
# base image's packages at their (potentially outdated) shipped versions.
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo lynis cron redis-server \
    && rm -rf /var/lib/apt/lists/*

# SEED: no-firewall — no ufw/iptables/nftables installed or configured.
# SEED: no-fail2ban — fail2ban is intentionally absent (no brute-force defense).

RUN mkdir -p /run/sshd

# Two users that share the SAME test public key.
#   audituser — passwordless sudo (the audit account)
#   nosudo    — no sudo rights at all
RUN useradd -m -s /bin/bash audituser \
    && useradd -m -s /bin/bash nosudo \
    && echo 'audituser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/audituser \
    && chmod 0440 /etc/sudoers.d/audituser

# Install the shared authorized_keys (staged by ensure-fixtures.sh) for both.
COPY authorized_keys /tmp/authorized_keys
RUN install -d -m 700 -o audituser -g audituser /home/audituser/.ssh \
    && install -m 600 -o audituser -g audituser /tmp/authorized_keys /home/audituser/.ssh/authorized_keys \
    && install -d -m 700 -o nosudo -g nosudo /home/nosudo/.ssh \
    && install -m 600 -o nosudo -g nosudo /tmp/authorized_keys /home/nosudo/.ssh/authorized_keys \
    && rm -f /tmp/authorized_keys

# Weak sshd config (PermitRootLogin yes, PasswordAuthentication yes).
COPY sshd_config /etc/ssh/sshd_config

# IS10 — Redis bound to all interfaces with no requirepass.
COPY redis.conf /etc/redis/redis.conf

# IS12 — secrets file world-readable on disk.
COPY env.seed /opt/app/.env
RUN chmod 644 /opt/app/.env

# IS11 — world-writable cron directory (777) and a SUID copy of /bin/sh.
RUN chmod 777 /etc/cron.d \
    && cp /bin/sh /usr/local/bin/seed-suid-sh \
    && chmod 4755 /usr/local/bin/seed-suid-sh

# Entrypoint: start the seeded background services (cron + redis) BEFORE sshd so
# the misconfigurations they represent (world-writable cron dir, no-auth redis on
# 0.0.0.0:6379) are actually LIVE and probeable at runtime, then hand PID 1 to
# sshd in the foreground.
RUN printf '%s\n' \
        '#!/bin/sh' \
        'set -e' \
        'service cron start' \
        'redis-server /etc/redis/redis.conf --daemonize yes' \
        'exec /usr/sbin/sshd -D -e' \
        > /usr/local/bin/seed-entrypoint.sh \
    && chmod 0755 /usr/local/bin/seed-entrypoint.sh

EXPOSE 22
# SEED: runs-as-root — no USER directive; sshd (and cron + redis) run as root.
ENTRYPOINT ["/usr/local/bin/seed-entrypoint.sh"]
