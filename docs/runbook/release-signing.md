# Release signing

`release-autoinstall` runs a release's `install.sh` on every machine that enabled it, with no person in
the loop. It installs only a tag that is on `origin/main` **and** carries an SSH signature by a key the
machine trusts. Push access alone is not enough.

## The two halves

| Where | File | Holds |
|---|---|---|
| a machine that releases | `~/.ssh/zuvo-release-signing` (+ `.pub`) | its private release key |
| every machine that auto-installs | `~/.zuvo/release-signers` | the trusted public keys (`allowed_signers` format) |

`release-signers` lives outside the repository on purpose. A list kept in the repo could be edited by
anyone who can push, which is exactly the trust the signature replaces.

`dev-push.sh` / `release.sh` sign the tag through `scripts/release-tag.sh` when the key exists (or
`ZUVO_RELEASE_SIGNING_KEY` points at another `.pub`). Without a key the tag is created unsigned with a
WARN: it ships, and no machine installs it by itself.

## Add a releasing machine

```bash
ssh-keygen -t ed25519 -N "" -C "zuvo-release@$(hostname -s)" -f ~/.ssh/zuvo-release-signing
cat ~/.ssh/zuvo-release-signing.pub
```

Then, on **every** auto-installing machine, append one line to `~/.zuvo/release-signers`:

```
zuvo-release@<host> namespaces="git" ssh-ed25519 AAAA… zuvo-release@<host>
```

Carry the public key between machines over a channel you trust (your own shell, a password manager).
A key that arrives in a pull request or a chat message is not a trust anchor.

## Check

```bash
git -C ~/.zuvo/release-src -c gpg.ssh.allowedSignersFile=$HOME/.zuvo/release-signers verify-tag vX.Y.Z
~/.zuvo/release-autoinstall --status
```

The log names every tag it skipped and why: `not on origin/main` or `no valid signature`.

## Revoke a key

Delete its line from `~/.zuvo/release-signers` on every machine, and its private key on the machine
that held it. Tags it signed stay installed but are no longer picked.
