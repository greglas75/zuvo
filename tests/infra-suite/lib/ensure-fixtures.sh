#!/usr/bin/env bash
# Sourceable helper that prepares non-committed build inputs for the sshd
# fixtures BEFORE `docker compose build`.
#
# Generates an ephemeral ed25519 keypair (private key NEVER committed — see the
# scoped .gitignore block) and stages its public half as `authorized_keys` in
# each sshd build context so the Dockerfiles can COPY it in.
#
# Idempotent: regenerates nothing if the key already exists.

ensure_fixtures() {
  local fixt_dir
  fixt_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../fixtures" && pwd)"
  local keys_dir="$fixt_dir/.keys"
  local key="$keys_dir/zuvo_test_key"

  mkdir -p "$keys_dir" \
    || { echo "ensure-fixtures: mkdir $keys_dir failed" >&2; return 1; }
  # Idempotency keys off the artifact actually consumed downstream — the PUBLIC
  # half ($key.pub), which is what gets staged into the build contexts. A bare
  # `$key` check would skip regeneration even if `.pub` had been deleted.
  if [ ! -f "$key.pub" ]; then
    rm -f "$key" "$key.pub"
    ssh-keygen -t ed25519 -N "" -C "zuvo-infra-fixture-test-only" -f "$key" >/dev/null \
      || { echo "ensure-fixtures: ssh-keygen ($key) failed" >&2; return 1; }
  fi

  # Stage the public key as authorized_keys in each sshd build context.
  local svc
  for svc in sshd-misconfigured sshd-hardened; do
    if [ -f "$key.pub" ]; then
      cp "$key.pub" "$fixt_dir/$svc/authorized_keys" \
        || { echo "ensure-fixtures: cp authorized_keys → $svc failed" >&2; return 1; }
    fi
  done
}
