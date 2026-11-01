# Bounded agent brief

Give one agent one coherent task, a self-contained brief and the required governing instructions.
Parent history is optional only with a stated need; do not split work into microtasks to fit a budget.
The 1–2k-token size aim is a soft target; required instructions and contracts always win. Record
a reason when exceeding a measured target. Use usage for tokens; otherwise report bytes without
claiming a token count. Never drop a contract to fit.

```text
task_id: <stable ID; action and authorized stage>
file ownership: <exact allowed paths, read-only inputs and exclusions; shared-work warning>
acceptance: <observable outcome, relevant behaviors/contracts, required verification and failure handling>
dependencies: <prerequisites, their state and existing contract/baseline/artifact references>
repo/ref: <absolute checkout, branch and exact source SHA; relevant working-tree snapshot hashes>
owner constraints: <required rules or retained rule bodies; authorization limits and runner/review policy>
proof paths: <existing evidence inputs and required outputs, commands/run IDs/digests; unknowns>
```

Resolve referenced inputs once. A reviewer receives the changed scope, related contracts and actual
proofs. A fresh worker reads required referenced instruction bodies itself; the parent’s retained-
body receipt is not transferable. Skip a reload only while the entire body remains in the receiving
agent’s own context, identified by realpath + SHA-256 + context_generation. Start that agent’s new
generation at entry and after compaction, then reload required bodies. A path or receipt alone
does not prove retention; the authoritative retention contract is [evidence-reuse.md](evidence-reuse.md).

Apply [evidence-reuse.md](evidence-reuse.md) using the existing `workflow_evidence.py`; do not build
a second cache. The cached successful run records `key_before` and `key_after`; for a reuse
decision, compute the current key and require `key_before == key_after == current_key`. The
artifact digest and requested scope must match, and the evidence must cover the gate. Unknown
identities, failed runs, partial checks and queue timeouts do not qualify. Report `reused:<artifact>`.
Keep required independent review and publication gates; no second parent retrospective.

For the pilot, freeze a versioned `protocol_ref` independently of each task's `brief_sha256`.
Record both in the schema-v1 attempt. Send exactly the chosen control/candidate brief to each new
session, retaining identical installed plugin version and governing rules in both arms. Select
preserved control briefs for future sessions on rollback. Do not install candidate includes
globally. Byte reductions alone do not establish token savings or startup effects.
