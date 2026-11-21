## infra-audit: unreachable hosts never pass, evidence is per host, consent and resume are scoped, remediation is lock-out safe

- An unreachable, failed, skipped or partially collected host is unassessed. It is never scored or counted clean and fails the Validity Gate (`hosts_assessed=<N>/<total>`), so the run is `INCOMPLETE` unless 4+ critical findings already prove `FAIL`.
- The collector writes raw output to `raw/<host>/` and the CVE gate greps only that host's directory (before, hosts shared one `raw/` and could confirm each other's CVEs). Patch-posture claims cite the host's own evidence.
- The authorization gate and the `--confirm-targets` hash cover every contacted endpoint: jump host, `--scan-via` host, proxy and external scan targets. One not confirmed is never contacted. Hosts sharing an IP on different ports are no longer merged.
- `--resume` and implicit adoption continue only when the target set, dimensions and flags match the `scope` stored in `state.json`; otherwise `RESUME-REFUSED: <field> differs`.
- Registry remediation: `ufw allow <ssh-port>` precedes every `ufw default deny`/`ufw enable`; SSH changes are tested with a new login; Postgres `listen_addresses` needs a restart; the history template rotates the secret first; `md5`, `apt-get upgrade -y` and enforce-all AppArmor are gone.
