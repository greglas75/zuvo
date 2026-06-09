# Report Output Location (canonical)

**Single source of truth for where zuvo writes project-local output.** Every skill that
writes a report, audit, plan, contract, or state artifact resolves its destination through
this include so that **all zuvo output lands in one visible folder at the project root** —
never scattered into whichever subfolder happened to be the scope argument.

## Resolution

```sh
# Resolve once, near the start of any skill that writes output.
ZUVO_DIR="${ZUVO_OUTPUT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/zuvo}"
mkdir -p "$ZUVO_DIR"
```

- **Anchored to the project root**, not `$PWD` and not the scoped path. Auditing
  `src/payments/` writes to `<project-root>/zuvo/…`, not `src/payments/zuvo/…`.
- `git rev-parse --show-toplevel` finds the repo root. Fallback to `pwd` for non-git trees.
- **Override:** export `ZUVO_OUTPUT_DIR=/abs/path` (CI, monorepo package, custom location).
  When set, it is used verbatim — no `/zuvo` suffix is appended, so point it at the exact
  directory you want.
- **Visible by design.** The folder is `zuvo/` (not `.zuvo/`) so it is not hidden on macOS
  Finder / `ls`. Add `zuvo/` to `.gitignore` if these artifacts should not be committed.

## Canonical subfolder map

All paths are under `$ZUVO_DIR` (default `<project-root>/zuvo/`):

| Subfolder | Contents | Written by |
|-----------|----------|------------|
| `audits/` | Audit reports (`.md` + `.json`), tier reports, per-finding artifacts | code-audit, security-audit, api-audit, performance-audit, db-audit, ci-audit, env-audit, dependency-audit, structure-audit, test-audit, seo-audit, geo-audit, content-audit, a11y-audit, design-review, architecture (review mode), pentest (bundle under `audits/pentest/`) |
| `reports/` | Non-audit generated reports | canary, content-migration, benchmark, agent-benchmark, retro, release-docs |
| `plans/` | Implementation plans, task DAGs | plan, build, execute, brainstorm |
| `contracts/` | Refactor CONTRACT files | refactor |
| `context/` | Session state, execution state, adversarial-review artifacts, acceptance proofs | execute, review, build, write-tests, session-state, adversarial gate |
| (root of `$ZUVO_DIR`) | `project-profile.json`, `profile-overrides/`, `knowledge/` | project-profile-protocol, knowledge store |

Fix skills (seo-fix, geo-fix, content-fix, content-expand) **read** their input audit JSON
from `$ZUVO_DIR/audits/`.

## What this does NOT cover

- `~/.zuvo/` (HOME) — the global zuvo home: `runs.log`, `retros.{md,log}`, `append-runlog`,
  `verify-audit`, `compute-preload`. That is **machine-global**, not project-local, and is
  unaffected by this include. Never rewrite `~/.zuvo/` or `$HOME/.zuvo/` paths.
- `docs/` — human-authored project documentation (README, ADRs, runbooks, specs, API docs,
  incidents) stays in the conventional visible `docs/` tree. zuvo does not relocate it.

## Backward compatibility

Readers (e.g. `~/.zuvo/append-runlog`, the pre-commit adversarial gate, fix skills locating a
prior audit) check `$ZUVO_DIR/…` first, then fall back to the legacy `audits/`,
`audit-results/`, and `.zuvo/` locations so in-flight projects do not break mid-migration.
