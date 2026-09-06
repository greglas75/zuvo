# Radar through rt (file-only mirrors and linked worktrees supported)

The laptop collects Git objects/history and current collisions. The farm computes complexity,
imports, module families and ranking. The worker itself needs only Python 3 and the exported
bundle, not `.git` or app services. `rt` may still perform its normal repository dependency
setup. A queue is a wait; failure never authorizes a local measurement retry.

## Prepare a private job

First allocate the durable local report directory using the output-root/unique-directory
setup in SKILL.md, without executing its small-repo scanner command. Keep this destination
separate from JOB_DIR; deleting a completed staging job must not delete the deliverables.

Use the verified absolute RADAR/REPO_ROOT from SKILL.md. The directory is inside the selected
repo so `rt` can mirror it. It must be new or empty. Keep it out of commits. `--prepare-farm`
is an explicit staging operation, not part of a strictly artifact-free discovery request.
This is operator-owned private input: the checksum detects corruption, not malicious rewriting.
Use the authorized SSH transport and check the report's repo ID/SHA against the intended job.

```bash
JOB_DIR="$(mktemp -d "$REPO_ROOT/radar-farm-XXXXXX")"
bash "$RADAR" --repo "$REPO_ROOT" --ref "$SOURCE_SHA" --top 20 \
  --prepare-farm "$JOB_DIR" --timings
JOB_REL="${JOB_DIR#"$REPO_ROOT"/}"
```

Pass the requested scope/mode/engine/cutoff/profile to preparation; the worker freezes those
choices. A CodeSift run also passes its verified `--codesift-json` at preparation. Do not create
an envelope asserting completeness merely to select that engine. The successful preparation
validates and copies supplied CodeSift values; it does not run CodeSift or builtin measurement.
It publishes `input.json` LAST. If absent, do not dispatch a partially prepared job.

## Dispatch and collect

```bash
cd "$REPO_ROOT"
# Verify staging is visible to the mirror; do not force-add generated source to git.
git ls-files --others --exclude-standard -- "$JOB_REL/input.json"
rt --light --full --keep-artifacts bash "$JOB_REL/refactor-radar.sh" \
  --snapshot "$JOB_REL/input.json" --execution farm \
  --json "test-results/radar/report.json" --timings
```

Check the first command actually lists `input.json`; if project ignore rules hide it, choose
a visible private staging location or the farm's documented explicit transfer mechanism.
Do not disable `rt`'s ignore check or rely on files that exist only on the laptop.

Consume the runner's command, SHA in the radar output, phase times and real exit code. Retrieve
the report with `rt --artifacts <runid> <new-retrieval-directory>` **before starting semantic
validation**. `--keep-artifacts` preserves successful outputs on the worker; it does not copy
them back to the user's project. Locate the returned `test-results/radar/report.json`, check
its repo ID/SHA, and publish its unchanged bytes as `discovery.json` in the durable local
run directory from SKILL.md (or the user's explicit `--json` destination), refusing overwrite.
Write `report.md` there too; partial/UNKNOWN results are saved, not discarded.
Do not claim completion while the only copy is on the farm or in a disposable staging job.
Keep local artifact links for the exact report and do not paste the complete function/path census
into the chat. The table is a shortlist, not a replacement for evidence in the JSON.

For a detached run use the installed `rt` help's `--notify`/`--wait` interface. Do not repeatedly
poll or start another scan because the first is queued. The default 300s scanner deadline starts
on worker execution, not while waiting in the farm queue. On timeout there is NO complete report.
`--execution farm` does not offload anything by itself. It requires Linux and the pinned
`TF_RELEASE_DIR/tf-run.sh` context exported by `rt`. Never spoof that context to bypass the
laptop guard. This prevents accidental misuse, not a hostile operator; it is not host authentication.
Large snapshot replays also require this verified execution context.

Local `history_dir` from the profile is omitted with a warning: this version does not transport
trend snapshots. Rows say `history=unavailable`. Explicit `--history` is rejected during preparation.

Availability expires after 300s even in a queued job. Expired observations become UNKNOWN and
their paths stop excluding candidates. Code/history remain valid. Recollect local worktree/PR
and active CONTRACT evidence before any READY/REGISTER/EXECUTE decision; a farm result never
proves that the laptop's current worktrees are free.

## Cleanup and limits

Report the exact staging and retrieved-report paths. After retrieval and when no runner uses
the job, remove only that task-owned staging directory (recoverably when available); never
prune user worktrees or a repository root. Honour requests to retain diagnostic inputs.

Preparation exports only selected committed source/test content, not a live build environment.
The builtin graph remains an approximation; missing alias/type-only resolution is still G5 work.
It does not synchronize a live CodeSift MCP index, run tests of the target app or install tools.
