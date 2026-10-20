# Refactor-gate upgrades

The 2026-10-20 fleet reported a hook referring to removed zuvo `1.6.98`, repaired
by reinstalling from `1.6.100`. On inspection for this fix, that original hook had
already been overwritten. No surviving `1.6.98` reference was found in the common
or private Git hooks, the installed gate/library, or the relevant settings hooks.
The historical file containing that exact reference cannot be confirmed from the
remaining host files.

The original source defect is reproducible: before runtime dispatch,
`scripts/install-refactor-gate.sh` resolved its gate argument with `Path.resolve()`
and `hook_body()` wrote an absolute
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
hooks, symlinks and tracked hooks remain protected. Private refresh checks the
embedded template against its recorded digest AND verifies the complete
original-hook chain; exact legacy private wrappers migrate too. Ordinary edits
that invalidate the digest or chain are preserved with installer exit 2. The
self-contained digest detects accidental edits; it does not authenticate the
template. Deliberately editing it and recomputing the digest retains managed
ownership and permits a later refresh.

Every invocation tries the gate in `~/.zuvo/current`, then every zuvo
`installPath` record in `installed_plugins.json` in file order, then numeric
version directories newest first. Registry candidates must resolve to a direct
child of the zuvo marketplace cache; a registry-selected SHA directory is
eligible but does not participate in numeric version ordering. The registry
lookup does not choose by scope, enabled status or semantic version. Missing, stale,
unreadable or malformed metadata falls back to installed candidates. Other
harness installations provide a fallback when no Claude cache exists. The gate
must resolve inside its selected install; an individual gate symlink cannot
escape it. The explicit `~/.zuvo/current` pointer may select a source install
outside the cache. Candidate inspection/launch `OSError` (including
`PermissionError`) warns and falls through. Arguments,
pre-push stdin and the selected gate exit status are preserved.

Recursion detection scans all candidate lines for the dedicated
`# zuvo:refactor-runtime-dispatcher` header (or the exact original dispatcher
header); a long header cannot hide a copied dispatcher. Quoting the old marker
inside another comment does not skip a real gate. A copied dispatcher is skipped
and lookup continues to a real gate. No environment recursion flag disables dispatch.

The global installer checks ownership before copying the stable gate, including
before its bulk hook copy and chmod. Other top-level shell-hook copies and chmod skip
symlink/non-regular destinations too. It accepts exact known released bytes,
the current source gate/dispatcher, or bytes matching its own digest receipt
(`~/.claude/hooks/.refactor-safety-gate.sha256`). Foreign files, directories and
symlinks are skipped with a diagnostic; their bytes, targets and permissions
stay intact. Remove/move a foreign entry deliberately before opting into zuvo
ownership. Versioned cache installs continue to carry the real gate.
Receipts must be regular files owned by the invoking uid and must not be group-
or world-writable. Their checked metadata must match the fd-based identity
snapshot before digest authorization is accepted. The installer publishes old/new digest authorization before
replacing the hook, so a failed receipt write leaves the hook intact and a failed
hook replacement leaves authorization to retry either version. This records local
installer provenance; a user who controls their HOME can deliberately forge it.

The installer prefers the activated gate release's sibling dispatcher template.
It only tries installer-relative templates when invoked from an existing script
path, never from a bare shell name such as `sh -s`. Missing arguments/templates
report unavailable and exit 2 without a traceback. A managed wrapper follows the
template selected by that invocation; there is no monotonic revision or promise
to refuse a deliberate rollback. An old installer restored by sync can still
restore old behavior and must be repaired at its source.

Replacements prepare a temporary file in the destination directory. Immediately
before `os.replace`, an fd-based digest/metadata comparison checks the current
pathname against the opened inode, including ctime, mode and a final `lstat`.
Detected concurrent edits or symlink substitutions are preserved and the
installer exits 2. This is best effort, not compare-and-swap: an uncoordinated
writer can still change the pathname between that final inspection and rename.
The dispatcher likewise compares the opened gate's identity with a final `lstat`
immediately before path-based execution. That narrows inspection/execution races;
an uncoordinated writer can still replace the pathname after the final check.

`docs/pipeline.md` explicitly requires **Fail-OPEN** for unavailable gate code.
No usable install, missing Python, or an unresolvable HOME therefore prints a
stderr warning and allows the commit. Recursion only allows the commit if no
later usable gate remains. Resolution uses the invoking account's HOME; changing
HOME changes the installation search. This local guard is not a security
boundary against a user controlling Git's environment. The warning names the repair command:

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
rt --light bash tests/hooks/test-refactor-gate-review.sh
rt bash scripts/validate-skills.sh
LC_ALL=C rt --full --light bash tests/run-all.sh
# Read the authoritative completed verdict using the run id printed above:
LC_ALL=C rt --log <runid>
```

The upgrade regression first failed on the old installer (farm run
`1792514992-2598689-21421`, five failing checks). It installs from `1.6.98`, removes
that directory, and proves the new gate is executed rather than merely allowing
an ungated commit. It also covers push forwarding, legacy migration, numeric
ordering, stale metadata, the actual global installer and private worktree hooks.

## Sessions-host configuration mirrors

On the sessions host (`ryzen-old-1`), `ccsync` mirrors the Mac's
`~/.claude/hooks/` with deletions every five minutes. During verification it
restored the old global entry and installer and removed the new dispatcher.
The Codex script copies and local plugin-cache repairs survived. Reapplying a
host-only Claude repair therefore lasts only until the next mirror operation.
Apply the same backed-up repair on the Mac, the configuration source, as well.
Do not disable configuration sync or change Git's hook chain to hide this.
The source fix remains committed even when configuration mirroring restores an
older installed hook; the Mac must receive the fixed installer at merge/release.
