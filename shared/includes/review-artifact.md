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
adversarial: zuvo/proofs/<slug>-adversarial.txt   # REQUIRED (see Proof-of-work) — real cross-model run
verdict: APPROVE|CHANGES|MUST-FIX-FOUND|RECOMMENDED-FOUND|PASS
-->
```

- `range:` — the full (non-abbreviated) `<base>..<head>` the review covered.
- `files:` — comma-separated reviewed **production** files, OR a single `*` meaning the whole range.
- `adversarial:` — path (repo-relative) to the adversarial run's saved output. **Required for any
  artifact written on/after 2026-07-23** — see Proof-of-work below.
- `verdict:` — the review/build/execute outcome.

## Proof-of-work (REQUIRED for coverage — content-key alone is not enough)

The content-key proves an artifact is **fresh** (its reviewed content is what is shipped), NOT
that a review **happened**. A fabricated artifact — `range: <base>..HEAD`, `files: *`, the
marker, and zero actual review — passes the content-key trivially, because its head *is* the
push head so every blob matches itself. This was demonstrated and done in the field. So the
artifact must also cite a real cross-model adversarial run, the most expensive thing to fake
here (it shells out to external provider CLIs).

**How to satisfy it (the skill already runs adversarial — just SAVE the output):**

```bash
# When you run the mandatory adversarial pass, save it with --artifact:
git diff <range> | adversarial-review --multi --mode code --artifact "zuvo/proofs/<slug>-adversarial.txt"
# then put that path in the header:
#   adversarial: zuvo/proofs/<slug>-adversarial.txt
```

`hooks/lib/pipeline-gate-lib.sh :: pg_artifact_proven` verifies, for any artifact newer than
`PG_REVIEW_PROOF_CUTOFF` (2026-07-23T00:00:00Z), that the referenced file **resolves inside the
repo** (no `..` traversal, no absolute path) and holds **≥2 `REVIEW BY:` provider lines** (a
genuine multi-model run). A genuine single-provider machine still produces a file with **one**
`REVIEW BY:` line plus a single-provider note — that is accepted too. The bare literal
`single_provider_only` with **no file** is NOT accepted: that was a "type the magic words"
shortcut. An artifact that fails this does not grant coverage, exactly as if it had no marker.

**Honest limits (this is a guardrail, not a security boundary — extends B-gate-6).**
- The referenced file is still agent-writable, so coverage is not *unforgeable* — this only
  raises the cost of a fake from one text edit to fabricating a convincing multi-provider
  transcript (an overtly dishonest act).
- Enforced **forward-only**: every artifact already on disk predates the cutoff and is
  grandfathered, so rollout false-blocks nobody (measured: 0 proofless post-cutoff artifacts
  back unpushed work).
- Grandfathering keys on the artifact **file mtime**, which does not survive `git clone`. In
  repos that COMMIT their review artifacts (memory/reviews tracked), a fresh clone stamps every
  file with "now" → legacy artifacts look post-cutoff. On CI this is handled — the CI entry
  script sets `PG_PROOF_OPTIONAL=1`, degrading an absent proof to the content-key backstop
  (proof files are gitignored and absent server-side anyway; **the proof-of-work is a LOCAL
  anti-fabrication layer, CI stays content-key as before**). A local fresh clone of such a repo
  is the one residual false-block; the escape is a fresh review or `ZUVO_ALLOW_ADHOC=1`.
- `touch -t` backdating a new artifact under the cutoff evades it — filesystem forgery, the same
  category this layer never claimed to defend against.

**Coverage is content-keyed by file CONTENT (blob), not by commit range.** A change is covered
iff EVERY changed production file's CURRENT content was reviewed by some artifact: file `F`
(current blob `B`) is covered by artifact `A` iff `F` is in `A`'s `files:` set (or `files: *`)
AND `F`'s blob at `A`'s reviewed head (the `<head>` of its `range:`) equals `B`. Consequences:
- **"review already ran in the producing pipeline"** (`write-tests`/`build`/`execute`/`review`
  all write this artifact on success) → the file's content is already reviewed → **no
  redundant standalone review** is demanded.
- **multi-agent shared branch:** a push passes iff EVERY file in it was reviewed by SOME
  pipeline — regardless of which agent authored which commit. A contaminated `merge-base..HEAD`
  range does NOT force re-reviewing other agents' already-reviewed work.
- **no permanent whitelist:** re-editing a reviewed file changes its blob, so the old artifact
  (different content) no longer covers it — a fresh review is required.
- **the incident still caught:** a genuinely freelanced file (raw `Edit`/`Write`, no pipeline)
  has unreviewed content → not covered → blocked.

After the header, the normal human-readable report body follows.

## When each skill writes it

| Skill | When | Notes |
|-------|------|-------|
| `zuvo:review` | Report Persistence (Phase 3), on completion | Already writes a `memory/reviews/` report — this just standardizes the header + content-keyed name. |
| `zuvo:build`  | Phase 4, **only after** verify + acceptance pass | Skip on any FAIL/BLOCKED. |
| `zuvo:execute`| Phase Final-2, **only after** the aggregate review passes | Skip on BLOCKED/abort. |
