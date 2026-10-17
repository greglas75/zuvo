#!/usr/bin/env bash
# release-tag.sh <tag> <commit> — create a release tag, SSH-signed when this machine has a release key.
# release-autoinstall installs only tags signed by a key in its machine's ~/.zuvo/release-signers, so an
# unsigned tag ships but installs nowhere by itself.
#
# Key: $ZUVO_RELEASE_SIGNING_KEY, else ~/.ssh/zuvo-release-signing.pub (its private half beside it).
# Exit: 0 signed tag created; 3 no key here, unsigned tag created (WARN on stderr);
#       1 a key is configured but signing failed — NO tag, git's error on stderr; 2 usage.
set -uo pipefail

if [[ $# -ne 2 || -z "$1" || -z "$2" ]]; then
  echo "usage: release-tag.sh <tag> <commit>" >&2
  exit 2
fi
tag="$1" commit="$2"
if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! git rev-parse -q --verify "${commit}^{commit}" >/dev/null; then
  echo "usage: release-tag.sh vX.Y.Z <commit> — got '$tag' '$commit'" >&2
  exit 2
fi
key="${ZUVO_RELEASE_SIGNING_KEY:-$HOME/.ssh/zuvo-release-signing.pub}"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "ERROR: $tag already exists — left as it is" >&2   # the failure path below deletes only its own tag
  exit 1
fi

if [[ -f "$key" ]]; then
  # A configured key that fails to sign never degrades to an unsigned tag: that would look like a release.
  # git can report success with no usable private key: the tag counts only once it verifies.
  signers="$(mktemp)"
  printf 'release namespaces="git" %s\n' "$(cat "$key")" > "$signers"
  if git -c gpg.format=ssh -c user.signingkey="$key" tag -s -m "zuvo $tag" "$tag" "$commit" &&
     git -c gpg.ssh.allowedSignersFile="$signers" verify-tag "$tag" >/dev/null 2>&1; then
    rm -f "$signers"
    echo "signed $tag with $key"
    exit 0
  fi
  rm -f "$signers"
  git tag -d "$tag" >/dev/null 2>&1
  echo "ERROR: signing $tag with $key failed — no tag created" >&2
  exit 1
fi
echo "WARN: no release signing key ($key) — $tag is UNSIGNED" >&2
echo "WARN: machines running release-autoinstall will not install $tag (docs/runbook/release-signing.md)" >&2
git tag "$tag" "$commit" || exit 1
exit 3
