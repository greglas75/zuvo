# Regression Fence — proving a file set is byte-identical to a base

> A **regression fence** is a declared set of paths that MUST come out of the work byte-identical
> to the base commit, proven mechanically at every verification step. It converts "I did not
> change the existing behaviour" from a claim into a check.

Load this when a run needs to *prove* something was left alone: a refactor claiming behavioural
equivalence, a feature whose flag-off path must be untouched, or a review triaging which findings
belong to the diff.

## Why it exists

Agents assert "existing tests unchanged" and "moved verbatim" constantly, and those assertions are
exactly the ones nobody verifies — they read as procedural boilerplate. Five retros across three
projects in one week independently hand-rolled this same mechanism (`FENCE_FILES`/`FENCE_CHECK`
invented from scratch in one, a base-blob comparison in another) because no include described it.

## The check

```bash
BASE="$(git merge-base origin/main HEAD)"     # or the PR base / PRE_REFACTOR_SHA

# Whole-set form — fastest, use when the fence is a directory or glob
git diff --quiet "$BASE"..HEAD -- tests/ || {
  echo "FENCE VIOLATED: $(git diff --name-only "$BASE"..HEAD -- tests/ | tr '\n' ' ')"; exit 1; }

# Per-file form — use when the fence is an explicit list, or you need to report which file moved.
# Compares BLOB HASHES, so it is exact: identical content is the same hash regardless of path,
# mtime, or how the file got there.
for f in $FENCE_FILES; do
  # --verify --quiet is REQUIRED, not stylistic: plain `git rev-parse "HEAD:missing"` exits 128
  # but still ECHOES the input string to stdout, even with 2>/dev/null — so a naive
  # `$(git rev-parse ... || echo MISSING)` captures BOTH lines and the comparison silently
  # becomes garbage, missing the deletion it was meant to catch.
  b0="$(git rev-parse --verify --quiet "$BASE:$f" || echo MISSING_BASE)"
  b1="$(git rev-parse --verify --quiet "HEAD:$f"  || echo MISSING_HEAD)"
  [ "$b0" = "$b1" ] || echo "FENCE VIOLATED: $f ($b0 -> $b1)"
done
```

`MISSING_HEAD` means the file was deleted, `MISSING_BASE` that it is new — both are violations of a
fence, and both are invisible to a naive "diff is empty" check that only looks at surviving files.

## The rule that makes it honest

**Declare the fence BEFORE the work starts, and record it in the run's contract or plan.** A fence
derived afterwards from "whatever happens to be unchanged" proves nothing — it is the diff wearing
a different hat. The fence is a prediction; verifying it is the test of that prediction.

Print it once when declared, then re-verify at EVERY verification step, not only at the end:

```
[FENCE] base=<sha7> paths=<n> — declared at <phase>
[FENCE] verified: <n>/<n> byte-identical
```

## Where it plugs in

| Caller | Fence is | Violation means |
|--------|----------|-----------------|
| `zuvo:refactor` | files the plan marked MOVED_VERBATIM, plus the pre-existing test suite | The move was not behaviour-preserving — the claim in `prove.characterization` is false |
| `zuvo:execute` / `zuvo:build` | the flag-off path, or suites the change must not touch | An acceptance criterion asserted "unchanged when the flag is off" and the code changed anyway |
| `zuvo:review` | files outside the reviewed scope fence | Scope expanded past what was reviewed |

## Using it to triage findings

A fenced file is *unchanged by this work*, so a finding against it is **pre-existing debt, not a
defect of this diff** — record it as such rather than scoring it against the change (this is the
`audit_scan` fencing rule in `zuvo:review`, and the MOVED_VERBATIM rule in `zuvo:refactor`).

Two exceptions, both about causality rather than file membership:

- A finding in a fenced file that this diff *caused* — a caller broken by a changed signature, a
  consumer of a removed export — is IN scope. The file being unchanged is what makes it a
  regression rather than pre-existing debt.
- A fenced file whose behaviour changed **without** its bytes changing (its dependency moved, a
  config it reads was edited) is not covered by the fence at all. The fence proves byte identity,
  not behavioural identity — say so rather than implying the stronger guarantee.

## Honest limits

The fence is a git-level check: it proves content, not behaviour. It cannot see a change in a
transitive dependency, a schema migration, or an environment variable. It is strong evidence for
"this file was left alone" and no evidence at all for "this file still does the same thing" —
that is what the characterization tests are for.
