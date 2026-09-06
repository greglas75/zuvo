# Refactor Radar: data and execution contract

## CLI and profiles (schema 2)

Entry: `scripts/refactor-radar.sh`, POSIX host (macOS/Linux), Python 3.11+ stdlib and git; no npm dependency or CodeSift
CLI is required. The installed, cross-platform entry is
`~/.zuvo/refactor-radar/current/refactor-radar.sh`. The installer publishes a complete bundle
atomically and retains older bundles for running sessions. Resolve real absolute paths before
invoking it. A checkout wrapper and its `lib/radar_*.py` modules must travel together.

The script accepts `--repo`, `--scope`, `--ref`, `--cutoff`, `--top`, `--since`, `--fresh-days`,
`--min-cc`, `--mode`, `--engine`, `--config`, `--json`, `--history`, `--record-snapshot`,
`--no-remote`, `--busy-file`, `--capture-busy`, `--busy-snapshot`, `--codesift-json`,
`--register`, `--decisions`, `--queue`, `--dry-run`, `--quiet`, `--prepare-farm`, `--snapshot`,
`--execution local|farm`, `--timeout`, `--timings`. `--validate` and `--no-save` are agent-side only.
Exit 0: completed; 2: invalid input/output or failed census; 3: not a git repository.

Profiles load from explicit `--config`, otherwise `.radar.json`, then `zuvo/radar.json`.
CLI values win, including zero where allowed. Example (proposal, never auto-written):

```json
{
  "repo_id": "product/example",
  "profile": "application",
  "source_roots": ["apps", "packages"],
  "exclude_paths": ["apps/api/src/already-owned.ts"],
  "critical": [{"pattern": "auth|submission|tenant", "k": 5}],
  "k_default": 3,
  "remote": "gh",
  "gh_repo": "owner/product",
  "remote_name": "origin",
  "promotion_branches": [["develop", "main"]],
  "since_days": 180,
  "fresh_days": 30,
  "top": 50
}
```

K is finite, (0,10], first matching critical rule wins; default is 3, not a guessed auth regex.
`profile: tooling` retains production scripts. Additional fields: `noise` (regex list), `ext`
(extension list), `min_cc`, `engine`, `ref`, `history_dir`, `families` (`id`, exact `files`).
Declared families must be disjoint and contained in the source census. User exclusions are
exact paths, not ambiguous basenames. Candidate file sets may extend a narrow scope to keep
a whole family; the source/graph census stays repo-wide. Limits cannot be bypassed by scope.

Builtin estimates cover TS/JS/PHP/Kotlin; Python uses stdlib AST. Reported N, ΣCC and D refer
to detected functions, not top-level executable code. The regex engine can miss expression
arrows or complex signatures and treats brace depth as nesting. Do not use it as a strict
success gate or an inter-language comparison. Syntax failures, symlinks, oversized/non-UTF8
source are explicit issues; affected rows cannot REGISTER. Limits: 100,000 tree entries,
400 KB/source blob, 128 MB selected blobs/input JSON. No fallback to dirty disk.

Family proposals require a relative-import edge plus naming/layout evidence, or explicit
membership. This is not semantic proof; inspect it at G3. The graph omits Python/PHP/Kotlin
resolution and does not resolve TS aliases or distinguish type-only edges. Fan-in counts
unique external production files, not repeated edges/tests. Test files are deduplicated.
`test_loc_ratio` is descriptive, **coverage is null** unless an independent report is used
by the agent. The tests mode deliberately does not call that ratio coverage.

The full JSON contains all in-scope ranked/excluded rows; `--top` limits the display and
maximum registration size. The default P80 floor screens only the complexity lane. Show
other lanes separately, including unmeasured candidates, instead of forcing them through it.

## Report persistence vs registration

The skill saves DISCOVER results by default; the low-level CLI remains explicit-output and
the skill passes `--json` for it. Use the canonical output root plus a unique
`reports/refactor-radar-<UTC>-<unique>/` directory. Save `discovery.json` immediately after
measurement and `report.md` for the agent's evidence, decisions and raw top-N appendix.
An explicit `--json` overrides only the raw JSON destination; link it from the Markdown.
Neither file is an executable queue, an approved decision contract or a history snapshot.
No REGISTER approval is required for these deliverables. Do not silently overwrite earlier
reports, update a `latest` alias, or change an active queue.

UNKNOWN availability, zero READY and partial validation still produce saved reports. Keep
the unmodified scanner JSON separate from semantic judgments; a shortened chat summary
does not replace either artifact. Read back both files before claiming completion. On scanner
failure retain a diagnostic Markdown report, not a fabricated or partial census presented as
complete. An explicit no-file-write/chat-only request or `--dry-run` suppresses these writes.

## Stable code vs temporary availability

The commit is resolved once, and every production/test file is batch-read by blob OID.
Churn uses unique non-merge commits within the absolute cutoff/window; conventional labels
are proxies and renames are not followed. Source identity is declared `repo_id`, otherwise
credential-stripped, protocol-normalized authoritative remote, otherwise common git directory (NOT worktree).
SSH/SCP/HTTPS remotes for the same host/path share identity. The no-remote fallback is local-only:
declare `repo_id` for portable farm use, moved clones or aliases across hosts. A missing explicit
`remote_name` is an error, never silent re-identification.

Availability is a timestamped observation, not a lock. Collect all local detached/named
worktree committed diffs from merge-base, staged/unstaged paths and untracked paths. Retain
names as hints only. A missing/prunable checkout yields UNKNOWN; deletion of a clean live
worktree leaves no durable name exclusion. Existing PRs/CONTRACTs must still be checked.

GitHub lookup names `owner/repo` explicitly and paginates PRs and file lists (including
renames). At its 3,000-file limit, treat completeness as unknown. Bitbucket paginates OPEN
PRs and diffstat, including old/new paths; authenticated next URLs must stay on the same
HTTPS API host and repo prefix, and redirects are refused. Both cap at 50 pages, 8 MB/page;
CLI timeout 30s, HTTP timeout 20s. Failure keeps known collisions and reports sanitized errors.
These limits are safety bounds, not evidence of absence. Auto remote prefers `bitbucket`
over `origin`; explicit `remote_name`/`gh_repo`/`bb_repo` remove ambiguity. Only configured
promotion branch pairs are excluded from PR collisions, and only when both branches belong to
the authoritative repository. A fork's identical branch name is not a promotion. Auto-detection
uses the exact parsed host, not a URL substring.

Bitbucket auth uses existing `RADAR_BB_TOKEN` + `bb_user`, or the existing macOS
`bitbucket-api-token` keychain entry. Never print secrets, call login flows or mutate auth.
`--no-remote` means UNKNOWN. `remote: none` explicitly declares PRs not applicable and can
be complete. It must not be set merely to get FREE rows. Active CONTRACTs remain agent-side.

Preferred farm workflow: [farm.md](farm.md), using a portable `--prepare-farm` input. It needs
no Git metadata on the worker. Preparation copies committed source/test blobs, bounded history,
profile and availability; no metrics or import graph are computed locally. It does not copy
`.git`, untracked files, `.env`, provider tokens or node_modules. Treat staged source as private.
The snapshot is operator-owned input with a checksum for accidental corruption, NOT an
authenticated attestation against malicious rewriting. Only run worker code prepared from the
verified Zuvo installation. Replay is DISCOVER-only and does not load host history paths.
Profile `history_dir` is omitted with a warning (`history=unavailable`); explicit `--history`
is incompatible with preparation. Large replay also requires `--execution farm`, used through
`rt`; the CLI checks Linux plus the runner's pinned-release context (an accidental-bypass
guard, not host authentication). This flag is not an offloading mechanism.

Legacy alternative for a farm with an actual Git checkout: run `--capture-busy <new-json>` locally, then
transfer that authorized metadata with the source to the farm and pass `--busy-snapshot`.
Do not upload it elsewhere; it includes private paths and PR identities. The farm also needs
an actual git object database/history for the chosen SHA; a file-only rt mirror is insufficient.
Check this prerequisite before running the scan; the control JSON supplies availability, not code/history.
The snapshot must
match repo ID/SHA and include both provider completeness records. Its validity is 300 seconds;
stale/future snapshots yield UNKNOWN. Expired paths remain diagnostic evidence, not BUSY
exclusions; an explicit current `--busy-file` still applies. Recollect before REGISTER/EXECUTE. Farm clones alone
cannot prove the local machine is free. Availability changes can change the execution
shortlist even when fixed-SHA complexity/churn metrics replay identically.

## CodeSift adapter

Use observed MCP schemas with the repo required by local rules. Do not invent a CLI or
import a truncated top-results list as a full census. The selection procedure is:

1. Inspect index identity, scope and freshness once. Prefer verified CodeSift measurements.
2. Refresh a stale index when the current user/project policy permits it, targeting only the
   intended checkout. A blanket historical "already indexed, never refresh" rule may be stale;
   surface it for correction, do not silently override a still-explicit prohibition.
3. A shared main-checkout refresh still cannot attest another branch or a frozen historical SHA.
   Require matching source/revision and complete pagination/census before exporting metrics.
4. If that evidence is unavailable, explain why and use the builtin engine ON THE FARM.
   CodeSift may still help validate individual findings after checking their source at the frozen SHA.

Indexing is real work wherever the server runs. Verify its host before starting a large refresh;
`rt` does not automatically move an MCP server to the farm. An unknown hosting location is not
permission to launch a laptop-wide reindex. There is no built-in MCP collector in the Python CLI.
For `--engine codesift`,
provide `--codesift-json` with an attested envelope:

```json
{
  "meta": {"repo": "product/example", "sha": "FULL_COMMIT_SHA", "complete": true,
           "version": "observed-tool-version", "total_functions": 1},
  "functions": [{"file": "src/example.ts", "name": "example", "line": 3, "lines": 12,
                 "cyclomatic_complexity": 4, "max_nesting_depth": 2}]
}
```

The collector must actually verify source SHA, pagination, filters, total and scope before
attesting `complete`. The script validates shape/identity/duplicate rows, not the truth of
an external index. Missing metadata → agent chooses an explicit farm fallback, never fabricate it.
The CodeSift path does not run builtin complexity measurement first.
Max nesting is measured independently of the maximum-CC function. History cannot mix engines,
versions, schema, policy, profile or scope. A new candidate gets no persistence penalty.

## REGISTER and history

DISCOVER never produces an executable queue implicitly. Preserve its JSON and create an
explicit decision file only when asked to register work:

```json
{
  "input_fingerprint": "EXACT_FINGERPRINT_FROM_DISCOVERY",
  "candidates": [{
    "family": "src/example",
    "type": "SIMPLIFY",
    "write_scope": ["src/example.ts"],
    "verification_scope": ["test: route errors and successful response"],
    "gates": {"G1": true, "G2": true, "G3": true, "G4": true, "G5": true},
    "evidence": "Actual entrypoint/caller, reservation, cohesion, assertions and seam evidence"
  }]
}
```

Run with the **same** SHA/cutoff/profile/scope/mode/top/measurement and current collision
evidence, adding `--register --decisions <file> --queue <new-file>`. Fingerprint or gate mismatch
refuses the queue. Write scopes must be nonempty, disjoint family subsets; one decision per
family. Gates are human/agent attestations, not a substitute for their evidence. Queue format
remains `- [ ] path | TYPE | Score: 0.NN` with scope comments; no shell commands are executed.
HUB_SPLIT is serialized as SPLIT_FILE and DEDUPE as EXTRACT_METHODS, preserving intent in
a comment: the downstream refactor runner uses those canonical types.
The score is the raw discovery normalization, not the agent's priority judgment. The consumer
must use the complete approved order/scopes; the first path is only an entry point.

`--history` reads compatible earlier snapshots; `--record-snapshot` explicitly saves one.
Snapshot filenames use cutoff + input fingerprint and keep the first capture of that exact
input. JSON/queue outputs refuse different existing content and symlinks. A concurrent writer
is never truncated: publish complete temporary files with an atomic exclusive link. A failed
publication leaves no partial JSON in history; corrupt history diagnostics identify the file.
This is not a transactional reservation database. A fingerprint also
binds mode/top and measured functions. Changed provider evidence invalidates old decisions.
The latest compatible earlier different-SHA snapshot supplies descriptive new/persistent state;
no automatic rename/split lineage or historical cooldown is inferred. Corrupt compatible
history fails visibly. Schema-1 history/queues remain untouched; rerun discovery for schema 2.

## Local I/O boundary

Configuration and explicit output directories are trusted operator input; this is not a sandbox
for hostile repositories or concurrent same-user tampering. Regular-file reads enforce the byte
limit on the descriptor, not a prior size check; devices/FIFOs and leaf symlinks are refused.
Git/CLI stdout is spooled to temporary disk before a capped read (128 MB git, 8 MB provider),
with 90s/30s subprocess timeouts and discarded stderr. CLI work is additionally bounded by a
whole-run wall deadline: 60s for local control/small scans, 300s for snapshot workers, configurable
with `--timeout`. Expiry aborts without a completed analysis; retry on the farm, not by dropping files.
`--timings` reports availability/git-input/measure/graph/rank durations on stderr, outside the
deterministic report fingerprint. Temporary disk itself has no quota. Use a disposable
constrained host for untrusted corpora. Run-local reverse indexes are discarded after each scan;
they never cache collision evidence across runs.
The optional macOS Keychain subprocess uses that same private temporary spool, so its token
is not memory-only. Existing `RADAR_BB_TOKEN` input avoids this subprocess path; never put
credentials in repository URLs or output artifacts. A dedicated secret reader remains follow-up.
Explicit standard ports are not normalized during provider auto-detection: use an explicit
provider and canonical `gh_repo`/`bb_repo` if this conservatively yields UNKNOWN.

## Design basis and remaining work

Use [relative churn research](https://www.microsoft.com/en-us/research/publication/use-of-relative-code-churn-measures-to-predict-system-defect-density/)
as support for change-pressure signals, not validation of this exact score. Refactoring is
multidimensional ([Microsoft study](https://www.microsoft.com/en-us/research/publication/an-empirical-study-of-refactoring-challenges-and-benefits-at-microsoft/));
the ranking weights require project outcomes to calibrate. Keep semantic correctness distinct
from metric improvements ([SWE-Refactor](https://arxiv.org/html/2602.03712v1)).

Useful existing adapters: [dependency-cruiser](https://github.com/sverweij/dependency-cruiser/blob/main/doc/cli.md)
supports metrics output; [Knip production mode](https://knip.dev/features/production-mode) needs
correct entrypoints; [Stryker incremental mode](https://stryker-mutator.io/docs/stryker-js/incremental/)
needs invalidation for changed configuration/dependencies, not blind reuse.
PR pagination limits: [GitHub](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests-files),
[Bitbucket](https://developer.atlassian.com/cloud/bitbucket/rest/api-group-pullrequests/).

Deferred, not delivered: automatic fleet scheduler, durable reservation service, full AST/
alias graphs, rename/split lineage, calibrated ROI, telemetry correlation and broad empirical
skill evaluation. Pilot on an app, a backend and a tools repo; measure precision@20, reasons
for rejection, time-to-validate and actual post-refactor benefit before changing weights.
