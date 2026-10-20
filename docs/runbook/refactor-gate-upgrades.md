# Refactor-gate upgrades

The 2026-10-20 fleet reported a hook referring to removed zuvo `1.6.98`, repaired
by reinstalling from `1.6.100`. On inspection for this fix, that original hook had
already been overwritten. No surviving `1.6.98` reference was found in the common
or private Git hooks, the installed gate/library, or the relevant settings hooks.
The historical file containing that exact reference cannot be confirmed from the
remaining host files.

The source defect is reproducible: `scripts/install-refactor-gate.sh` resolves
its gate argument with `Path.resolve()` and `hook_body()` writes an absolute
`exec <gate> pre-commit "$@"`. `chained_body()` writes the same absolute gate into
worktree-private hooks. Passing a plugin gate embeds this version-specific path:

```
$HOME/.claude/plugins/cache/zuvo-marketplace/zuvo/1.6.98/hooks/refactor-safety-gate.sh
```

After cache eviction removes `1.6.98`, the shell returns 127 before any gate code
runs. Git refuses the commit. A common hook affects all linked worktrees using it;
private wrappers retain the same defect independently. Reinstalling a wrapper
with another version-specific path only postpones the next failure.

At inspection time the common tgm pre-commit block called the regular file
`$HOME/.claude/hooks/refactor-safety-gate.sh`; this was not a symlink and its lib
was a regular sibling file. The pre-push and sampled private worktree wrappers
called `$HOME/.codex/scripts/refactor-safety-gate.sh`. Neither path was pinned.
`installed_plugins.json` selected cache `1.6.102`, with `1.6.101` also present;
`$HOME/.zuvo/current` did not exist. No refactor settings.json hook was registered.

## Resolution and failure policy

The global Claude hook now installs `hooks/refactor-gate-dispatch.sh` under the
stable name `~/.claude/hooks/refactor-safety-gate.sh`. Cache-origin repository
hooks embed the same dispatcher, including private wrappers. They need neither
the original installer nor its cache directory after activation. Exact legacy
cache wrappers can be migrated by rerunning the current installer; unrelated
hooks, symlinks and tracked hooks remain protected.

Every invocation tries the gate in `~/.zuvo/current`, then the active zuvo entry
in `installed_plugins.json`, then numeric version directories newest first.
SHA cache siblings do not participate in version ordering. Missing, stale,
unreadable or malformed metadata falls back to installed candidates. Other
harness installations provide a fallback when no Claude cache exists. Arguments,
pre-push stdin and the selected gate exit status are preserved.

`docs/pipeline.md` explicitly requires **Fail-OPEN** for unavailable gate code.
No usable install, missing Python, or dispatcher recursion therefore prints a
stderr warning and allows the commit. The warning names the repair command:

```sh
claude plugin install zuvo@zuvo-marketplace
```

An actual gate rejection still blocks. Explicit custom gates outside the plugin
cache retain their existing missing-file rejection policy. This change does not
mask application errors inside an executable gate or validate a release before
it becomes active.

## Verification

```sh
rt --light bash tests/hooks/test-refactor-gate-upgrade.sh
rt --light bash tests/hooks/test-refactor-gate-install.sh
rt bash scripts/validate-skills.sh
rt bash tests/run-all.sh
```

The upgrade regression first failed on the old installer (farm run
`1792514992-2598689-21421`, five failing checks). It installs from `1.6.98`, removes
that directory, and proves the new gate is executed rather than merely allowing
an ungated commit. It also covers push forwarding, legacy migration, numeric
ordering, stale metadata, the actual global installer and private worktree hooks.
