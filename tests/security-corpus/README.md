# Security Detection Corpus

Ground-truth fixtures that prove `zuvo:pentest` + `zuvo:security-audit` actually
detect each vulnerability class — and don't false-positive on safe code.

## Why a scorer, not a runner

`zuvo:pentest` and `zuvo:security-audit` are **LLM skills, not CLIs** — a shell
script cannot invoke them deterministically. So the proof is split:

1. **Skill-run step (agent/manual):** run the skill on a fixture and save its
   `findings.json` as `<findings_dir>/<class>-vulnerable.json` and
   `<findings_dir>/<class>-clean.json`.
2. **Scorer step (deterministic):** `run.sh` reads `manifest.json` and asserts,
   per class, that the vulnerable twin's findings contain the expected
   `finding_type` and the clean twin's do not.

The deterministic half is what gates CI; the LLM half produces its input.

## Layout

```
manifest.json                 class → finding_type + fixture paths (single source of truth)
run.sh                        the scorer  (run.sh --findings <dir> [--classes a,b] | --self-test)
run.test.sh                   meta-test: proves the scorer catches FN + FP
<class>/vulnerable/...        intentionally-vulnerable sample (carries an exploit_note)
<class>/clean/...             safe twin — same shape, defended
```

## Adding a class (the contract)

1. Add a row to `manifest.json` with `class`, `finding_type` (must exist in
   `shared/includes/pentest-finding-registry.md`), `vulnerable_path`,
   `clean_path`, `stack`, and a one-line `exploit_note`.
2. Create `<class>/vulnerable/` (must be genuinely exploitable) and
   `<class>/clean/` (the defended twin).
3. The validator (`scripts/validate-pentest-output.sh`, Task 5) enforces a 1:1
   between registry classes and manifest entries — a class with no fixture fails.

## findings.json schema the scorer expects

Each `<class>-{vulnerable,clean}.json` must be a valid skill findings document with a
`findings` array. The scorer matches the expected class under **either** `.type` **or**
`.finding_type` on each finding (skills may use either key). An unreadable or non-JSON
findings file FAILS its class — it is never silently treated as "clean".

**One findings file per class, even when two classes share a fixture dir.** E.g.
`graphql_introspection` and `graphql_depth_unbounded` both live under `graphql/`, but the
skill-run step must emit `graphql_introspection-vulnerable.json` AND
`graphql_depth_unbounded-vulnerable.json` separately so neither overwrites the other.

### Provenance (anti-fake-green)

Each findings file SHOULD carry `.meta.source_fixture` = the fixture path the skill actually
scanned. The scorer matches it against the manifest path at a **path boundary** (so
`xxe/vulnerable_FAKE` does not satisfy `xxe/vulnerable`). A present-but-wrong source always
FAILS. Absent provenance **warns** by default (so incremental task work isn't blocked) but
**FAILS under `--require-provenance`** — which the CI gate and the Task 18 smoke benchmark run,
closing the hole where a hand-written findings.json could pass CI without the skill ever
running.

## Run

```bash
bash tests/security-corpus/run.sh --self-test          # scorer logic meta-check
bash tests/security-corpus/run.sh --findings <dir>     # score a real skill-run dump
bash tests/security-corpus/run.test.sh                 # meta-test (CI)
```
