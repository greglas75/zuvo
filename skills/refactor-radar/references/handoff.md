# Compact refactor handoff

Read when writing or consuming `report.md`. Its purpose is to let the next agent pick up
the selected change without repeating discovery, while retaining execution safety checks.

## One short header, then the ranked list

Header: canonical repo ID, immutable source SHA, analysis time, requested/handed-off/pending
counts, discovery JSON link and one line for shared limitations (e.g. PR availability UNKNOWN;
tests inspected, not executed). Do not repeat these caveats under every candidate.

Use a numbered list of compact cards, normally four short lines after the title, roughly
60–100 words per item excluding paths. This is a readability target, not permission to omit
a critical invariant. Render short filenames as link labels when the exact targets are long.
Paths must resolve unambiguously to the source repo, not relative to the report subdirectory.

```markdown
1. **src/cache.ts :: resolve — EXTRACT_METHODS · TEST_FIRST · risk M**
   - Change: isolate key construction from lookup; inconsistent key handling caused misses.
   - Watch: keep key version/field order; fatal results must not be cached; flush pending writes.
   - Tests: tests/cache.spec.ts :: cache_hit — assert zero executions; add fatal/no-write case.
   - Scope/evidence: edit src/cache.ts + named spec only; caller src/runner.ts :: run.
```

The example is illustrative, not a finding. For each real card:

- **Title/change:** actual file and symbol, one intervention and the confirmed reason for it.
  A family spanning dozens of files is analysis context, never an implicit write scope.
- **Watch:** one to three source-specific invariants, ordering/error/concurrency traps, or
  explicit non-goals. "No behavior changes", "run tests", "watch cycles" alone are not hints.
  Name the actual invariant or edge. A fix that tightens validation is not a silent refactor.
- **Tests:** exact spec and test name/assertion (or source-SHA line locator), plus the concrete
  missing case to add first. A filename alone or test/source LOC ratio is not verification.
  With no existing tests, label the planned spec as NEW and name the cases to characterize;
  this is TEST_FIRST, not a claim that a test or passing result already exists.
- **Scope/evidence:** exact permitted edit files and a caller/registration proving use;
  name relevant shared dependencies, boundary configs or another card's ID when needed.
  These references define what must be rechecked on reuse. Keep a decisive metric only if it
  changes the action; retain the complete function/family baseline in the linked JSON row.

All handed-off items receive these hints, not only the first five. If evidence for a field is
missing, investigate it within the agreed budget or move the item to **Pending validation**:
one line with its path and the exact unresolved question. Pending/BUSY/EXCLUDED items are not
counted as actionable handoffs. Unknown availability can be stated once in the header and
keeps candidates conditional; it does not erase their already established technical findings.
Do not invent extra rows, metrics, test names or ownership just to fill the requested count.

## Reuse instead of starting over

Include this short instruction once in the saved list: "Reuse these findings after a scoped
diff from the recorded SHA; refresh availability and changed evidence, not the whole radar."

When a user supplies a saved list:

1. If they request formatting only, transform the existing findings without scanning or
   inventing fresh validation. Preserve their original SHA, limitations and missing evidence.
2. For resumed selection/execution, verify repo identity and that the recorded SHA exists.
   Compare that SHA to current HEAD **and** staged/unstaged/untracked state for the selected
   card's source, tests, callers, dependencies and relevant resolver/build configuration.
   Check current references locally to catch new callers outside the old list. A changed HEAD
   or elapsed time alone does not justify redoing repository-wide metrics/ranking.
3. If the relevant evidence is unchanged, reuse the reason, proposed seam, invariants and
   baseline. Read the current target and referenced tests; do not redo the whole G1–G5 census.
   If something changed, revalidate only the affected findings. Missing SHA/scope evidence
   requires targeted verification, not pretending that the old findings are proven current.
4. Always refresh temporary PR/worktree/CONTRACT collisions and check current user exclusions.
   Reuse of analysis is not permission to execute and not a test PASS. Characterization on
   current code, execution CONTRACT, review, targeted tests and applicable repo gates remain.

Success is specific to the intervention: SIMPLIFY reduces the agreed decisions/nesting;
SPLIT improves ownership without worsening coupling; DEDUPE removes one repeated invariant;
BREAK_CIRCULAR removes the named runtime edge; deletion needs non-use and owner-intent proof.
Never substitute an arbitrary percentage CC reduction for these goals.
