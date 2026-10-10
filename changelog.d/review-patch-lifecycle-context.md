## Review patches show a script's trap and cleanup definitions beside its changed hunks

- `build-review-patch` now appends, after the last hunk of a tracked shell script, the script's
  lifecycle definitions that the hunks do not already show: every `trap` line, then the bodies of
  functions a `trap` names as its handler, then those of cleanup-named functions (`cleanup`,
  `teardown`, `on_exit`, `stop`, alone or joined with `_`). A reviewer of a hunk that starts a
  background job can now see whether anything reaps it.
- A shell script is a file whose shebang names `sh`, `bash`, `zsh`, `ksh` or `dash` (directly or
  through `env`), whatever its extension; a file without a shebang counts when its name ends in
  `.sh`, `.bash`, `.zsh` or `.ksh`. A shebang naming another interpreter wins over a `.sh` name.
- The block is triggered by what the script defines, not by what the hunk changes; a script with
  background jobs but no trap or cleanup gets none. New files (the whole file is in the hunk
  already), symlinks, submodules and post-images that are not regular files never get one.
- Shape: `=== CONTEXT: <path> - lifecycle definitions outside the changed hunks (unchanged;
  reference only, NOT part of this diff) ===`, then `<line>: <text>` lines, then
  `=== END CONTEXT ===`. No line in it can be read as diff content or a file boundary, and
  `git apply` ignores it. At most 40 lines per function and 80 lines / 4000 characters per file,
  with a `... N more ...` line saying what was left out; trap lines are kept first, so the caps
  cut function bodies before trap registrations. The adversarial driver repeats the block in
  every part when it splits that file at its hunks.
- The helper's own `git diff` calls now fix the `a/` and `b/` prefixes, so `diff.noprefix` or
  `diff.mnemonicPrefix` in the user's config no longer changes the patch headers. With the default
  config the output is unchanged.
- `ZUVO_REVIEW_PATCH_NO_CONTEXT=1` (exactly `1`) turns the blocks off. If a post-image cannot be
  read, a block cannot fit the character cap, or the annotation fails, that file's block (or every
  block) is left out with a warning on stderr; exit codes are unchanged.
