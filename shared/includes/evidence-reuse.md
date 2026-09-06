# Reuse verified evidence for the current inputs

A nested stage receives the parent's contract path, execution policy, behavior/symbol scope,
baseline, current source/test snapshot, coverage, mutation and review artifacts. Resolve these
once; do not restart discovery, invent a new target or emit a second parent retrospective.
Standalone skills still perform their normal discovery and completion logging.

For test, mutation and quality evidence, compute a key before and after the run:

```bash
~/.zuvo/workflow_evidence.py --command '<exact command>' --scope <files> \
  --toolchain '<actual versions + dependency cache identity>' \
  --environment '<runner image/config/service revision>'
```

The helper hashes tracked and nonignored source inputs (including tests, config and lockfiles),
command, scope, checkout, toolchain and environment identity. Zuvo outputs and review receipts are
excluded. Unknown identities, mutable external services, dependencies outside this checkout,
untracked ignored source or symlink targets require separate content identities in `environment`;
without them reuse is unavailable. This is conservative invalidation, not a dependency analyzer.

A receipt records `key_before`, `key_after`, command, scope, exit status, artifact path and digest.
Reuse only when both keys equal the newly measured key, the artifact exists with the same digest,
the run finished successfully, and the evidence covers the requested checks. A valid key says
nothing about completeness of a test or correctness of a reviewer. Partial results, queue timeouts,
missing coverage and an unrun provider never satisfy a gate. Report `reused:<artifact>` explicitly.

Formatting runs before final snapshots and review. Any later source, test, dependency or config
change invalidates affected evidence. Keep content-keyed review artifacts in the existing
`memory/reviews/` format (`review-artifact.md`); this receipt does not replace its provider or
range requirements. Publish still follows the repository's required final verification battery.

## Loading instructions once

Reuse an include only while its entire contents remain in the current context, identified by
**realpath + SHA-256 + context_generation**. A file path or disk ledger alone does not prove that
the model retained its contents. After compaction start a new generation and reload needed rules.
`load-includes <skill> --files ... --generation <id>` returns the content and a receipt. On a later call,
pass that receipt with `--retained <receipt.json>` only if those complete bodies remain available
in context. Changed content, new generation or absent receipt reloads. `--manifest-only` never
claims a body was loaded. Do not read every phase reference up front.

## Behavior scope and extraction

Record the symbols/contracts being changed as well as the file fence. In `preserve_behavior`, fix
introduced regressions; retain severity/evidence for genuine pre-existing unrelated findings and
record them as `out-of-behavior-scope`, not false-positive. Critical unresolved risks remain visible
and block release where the project's policy requires. `refactor_and_fix` may fix authorized
existing defects, with an actual red→green regression proof for each applied finding.

`EXTRACT_IDENTICAL` is an evidence strategy, not a waiver: prove identical function bodies and
inputs before extraction, keep caller-specific mappings separate, characterize both consumers
before/after, exercise the helper's boundaries, check side effects/cycles and review the final diff.
If any proof fails, use the ordinary characterization path. Keep the current independent reviewer
and provider requirements; do not reduce them from LOC or a single cheap example.
