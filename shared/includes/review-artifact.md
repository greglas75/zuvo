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
git diff <range> | ~/.zuvo/adversarial-review --multi --mode code --artifact "zuvo/proofs/<slug>-adversarial.txt"
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

## Who READS it — the gates, and `zuvo:ship`'s review scoping

For a long time the artifact had exactly one reader: the pipeline-entry gates, asking a yes/no
question at push time (`pg_range_reviewed`). `zuvo:ship` Phase 2 is the second reader, and it asks a
different question — *which* files still need review — via `pg_uncovered_files` in the same library.

This matters because ship was the largest duplicated cost in the pipeline. Ship *wrote* an artifact
and *diagnosed* artifacts when the push gate blocked, but never *consulted* one when deciding review
depth: it scaled purely on `DIFF_LOC` over the whole range, so a release made minutes after a
`zuvo:refactor` re-ran `review-light` + `zuvo:review` (TIER 2/3) + a `--multi` adversarial pass over
content that already had all three, plus its own proof. Measured on a 2026-08-16 session: four full
pipelines over one set of changes.

The rule ship applies:

| `pg_uncovered_files` result | Ship's review |
|-----------------------------|---------------|
| rc 0, empty | `reused` — no reviewer runs; the covering artifacts are printed per file as evidence |
| rc 0, non-empty | scoped to those files only (`partial:<n>-files`) |
| rc 2 (could not compute) | full depth over the whole range |
| rc 3 (no production files) | full depth over the whole range |

Three properties make this a scoping decision rather than an escape hatch, and all three are
load-bearing:

- **It is derived, not declared.** There is no `zuvo:ship` flag that expresses reuse. The only way
  to reach the `reused` row is to genuinely hold the reviewed content, because the answer comes
  from comparing blobs on disk.
- **Empty output is ambiguous, so ship reads the CODE.** rc 2 (a missing library, an unresolvable
  range) prints nothing, exactly like "all covered". Collapsing them would turn an infrastructure
  failure into a skipped review — which is why `pg_uncovered_files` signals through the exit status
  and never through emptiness alone.
- **The reader can invalidate its own coverage.** Any fix ship applies after measuring changes that
  file's blob and drops its coverage. Ship re-computes after its fix steps; a file the run edited
  can never be reported `reused`.

What ship does NOT reuse, and never will: the secret scan (unconditional on every path), the full
test suite and build on the final HEAD, base freshness against the target branch, the push-gate
preflight, CI, and the merge. Those are integration checks about *this* release, not statements
about file content, so no artifact can stand in for them.

**Worktrees make this the failure case to get right.** The artifact and its proof are a per-checkout
PAIR (see below), and the canonical shape of the problem is a refactor run in a worktree followed by
a ship — precisely the case the reuse path exists for. If ship treated an absent pair as "never
reviewed", it would fall back to a full review in exactly the scenario that motivated the feature.
So ship attempts `~/.zuvo/review-artifact-sync.sh --from <other checkout> --to <here>` across the
repo's other worktrees and re-computes once before accepting any file as uncovered.

## The artifact and its proof are a PAIR (worktrees / multiple checkouts)

Coverage is TWO files: the `memory/reviews/*.md` artifact AND the proof file its
`adversarial:` header references. Both are per-checkout (`zuvo/proofs/` is
gitignored even where `memory/reviews/` is tracked). Consequences, learned from
a real incident (2026-07-31 — six worktree-pipeline refactors read as "never
reviewed" because their pairs lived only in the worktrees):

- **A pipeline running in a worktree writes the pair to the MAIN checkout too**
  (worktree-safe protocol) — a pair that exists only in a disposable worktree
  dies with it.
- **Never copy the `.md` alone** between checkouts: without its proof the gate
  rejects the artifact whole, which looks identical to "review never happened".
  Move pairs with `~/.zuvo/review-artifact-sync.sh --from <src> --to <dst>`.
  **Use the `~/.zuvo/` path, not `scripts/…`** — the repo-relative form resolves only inside
  zuvo-plugin itself, so in the repo you are actually shipping the remediation command a blocked
  push prints does not exist. `install.sh` puts the helper in `~/.zuvo/` alongside
  `adversarial-review` for exactly that reason (Codex/Cursor/Antigravity builds get their own
  absolute copies under `~/.codex/scripts/`, `~/.cursor/scripts/`, `~/.gemini/antigravity/scripts/`).
- **After writing an artifact, lint it:** `~/.zuvo/review-artifact-sync.sh
  --check` catches the malformed headers the gate otherwise skips silently —
  missing `<!-- zuvo-review -->` marker, space-separated `files:` (the parser
  splits on commas ONLY), missing/weak proof.
- When a push is blocked, the gate prints a per-file reason
  (`pg_explain_uncovered`): proof-missing, stale-content, marker-missing, and
  no-artifact each have a DIFFERENT fix — only the last one means re-review.

## Provisional form (reviewed edits not yet committed)

When a run completes its review while the reviewed **production edits are still uncommitted**
(no-commit session, "I'll commit later"), the normal form is a lie waiting to happen: `HEAD`
does not contain the reviewed blobs, so the artifact either fails the content-key silently or
tempts a fabricated range. Write the PROVISIONAL form instead — honest, machine-checkable, and
deliberately **coverage-inert** until upgraded:

```
memory/reviews/<base7>..worktree-<slug>.md
```

```
<!-- zuvo-review -->
status: PROVISIONAL
range: <base_sha>..WORKTREE
files: path/one.ts, path/two.ts
blobs: path/one.ts=<git hash-object of the WORKING-TREE file>, path/two.ts=<...>
adversarial: zuvo/proofs/<slug>-adversarial.txt
verdict: APPROVE|CHANGES|...
-->
```

- `blobs:` — `git hash-object <path>` of each reviewed working-tree file at review time.
  This is what was actually reviewed, recorded in the same currency (blob SHA) the gates use.
- A PROVISIONAL artifact **grants no pipeline coverage** — by construction: its `range:` head
  is not a commit, so `pg_range_reviewed` never matches it. That is intended, not a bug.
  Gates parse only the headers they know; the extra lines are ignored.

**Upgrade (after the edits are committed):** verify each recorded blob still matches —
`git rev-parse <head>:<path>` must equal the `blobs:` entry for every file. All match → rewrite
the artifact to the normal form (`<base7>..<head7>-<slug>.md`, real `range:`, drop `status:` and
`blobs:`). Any mismatch means the file changed AFTER the review — the artifact is stale; a fresh
review is required, never a silent upgrade. An abandoned PROVISIONAL artifact expires harmlessly
(it never granted anything).

## When each skill writes it

| Skill | When | Notes |
|-------|------|-------|
| `zuvo:review` | Report Persistence (Phase 3), on completion | Already writes a `memory/reviews/` report — this just standardizes the header + content-keyed name. |
| `zuvo:build`  | Phase 4, **only after** verify + acceptance pass | Skip on any FAIL/BLOCKED. |
| `zuvo:execute`| Phase Final-2, **only after** the aggregate review passes | Skip on BLOCKED/abort. |
| `zuvo:refactor` | Phase 4, **only after** Prove (blind audit + adversarial) and the repository gates pass | List only the production files inside the CONTRACT's scope fence — a refactor's artifact must not claim coverage for files it never touched. Two commits (pure move + fix) are one artifact spanning both. Skip on BLOCKED/unsafe. |
