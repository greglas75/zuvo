# Hardened sshd fixture for zuvo:infra-audit — the negative control.
# Same base image (pinned by digest), but a tight posture: only audituser, no
# root login, no password auth, no extra services.
FROM ubuntu@sha256:786a8b558f7be160c6c8c4a54f9a57274f3b4fb1491cf65146521ae77ff1dc54

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /run/sshd

# Only audituser exists here, with passwordless sudo for the audit account.
RUN useradd -m -s /bin/bash audituser \
    && echo 'audituser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/audituser \
    && chmod 0440 /etc/sudoers.d/audituser

COPY authorized_keys /tmp/authorized_keys
RUN install -d -m 700 -o audituser -g audituser /home/audituser/.ssh \
    && install -m 600 -o audituser -g audituser /tmp/authorized_keys /home/audituser/.ssh/authorized_keys \
    && rm -f /tmp/authorized_keys

# Hardened sshd config.
COPY sshd_config /etc/ssh/sshd_config

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
