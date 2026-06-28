# Content-Keyed Review Artifact (pipeline-entry signal)

**Written by `zuvo:review`, `zuvo:build`, and `zuvo:execute` on SUCCESSFUL completion only.**
A crashed / aborted / early-exit run writes **nothing** — a failed run must never grant
pipeline coverage (crash-safe by construction).

This artifact is the content-keyed signal the pipeline-entry gates read
(`hooks/lib/pipeline-gate-lib.sh` → `pg_range_reviewed`). The gates ask **"is THIS
range / file-set reviewed?"**, not "did a pipeline run recently" — so the path encodes the
reviewed commit range and the header records the exact files. There is **no whitelist**:
a review of files X never grants coverage to unrelated files Y.

## Path

```
memory/reviews/<base7>..<head7>-<slug>.md
```

- `<base7>` — short (7-char) SHA of the **merge-base with the default branch** (range start)
- `<head7>` — short (7-char) SHA of `HEAD` at completion (range end)
- `<slug>`  — kebab-case feature / scope slug

Compute the range worktree-safe (ALWAYS pass `-C "$repo_root"` so it resolves identically
from any checkout of the repo):

```bash
repo_root=$(git rev-parse --show-toplevel)
default_branch=$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main)
base=$(git -C "$repo_root" merge-base HEAD "$default_branch" 2>/dev/null || git -C "$repo_root" rev-parse HEAD)
head=$(git -C "$repo_root" rev-parse HEAD)
base7=$(git -C "$repo_root" rev-parse --short "$base"); head7=$(git -C "$repo_root" rev-parse --short "$head")
art="memory/reviews/${base7}..${head7}-<slug>.md"
```

## Machine-readable header (the FIRST lines of the file)

```
<!-- zuvo-review -->
range: <base_sha>..<head_sha>
files: path/one.ts, path/two.ts        # union of reviewed production files (or `*` = whole range)
verdict: APPROVE|CHANGES|MUST-FIX-FOUND|RECOMMENDED-FOUND|PASS
-->
```

- `range:` — the full (non-abbreviated) `<base>..<head>` the review covered.
- `files:` — comma-separated reviewed **production** files, OR a single `*` meaning the whole range.
- `verdict:` — the review/build/execute outcome.

`pg_range_reviewed(<change-range>)` returns TRUE iff some artifact's `range` **contains** the
change's commits OR its `files` set **⊇** the change's production files. An UNRELATED artifact
(covers other files only) is NOT coverage.

After the header, the normal human-readable report body follows.

## When each skill writes it

| Skill | When | Notes |
|-------|------|-------|
| `zuvo:review` | Report Persistence (Phase 3), on completion | Already writes a `memory/reviews/` report — this just standardizes the header + content-keyed name. |
| `zuvo:build`  | Phase 4, **only after** verify + acceptance pass | Skip on any FAIL/BLOCKED. |
| `zuvo:execute`| Phase Final-2, **only after** the aggregate review passes | Skip on BLOCKED/abort. |
