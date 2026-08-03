# Testing & Verification Runbook

How to verify this repo — before a commit, before a release, and on the periodic deep audit.
Written 2026-08-01 after the MD/gate/rules/pattern-doc audit sweep, so that sweep is repeatable
instead of a one-off.

**The rule this repo runs on:** a check that only says "no errors" proves nothing about what it
did not look at. Every layer below states what it CANNOT catch, and the periodic audit exists
precisely for that residue.

---

## 0. Prerequisites (check once per machine)

```bash
python3 --version        # required — validators, generator, coverage gate
rg --version             # required by tests/seo-suite (its absence FAILED the suite silently once)
jq --version             # adversarial JSON mode
bats --version           # OPTIONAL — scripts/tests/*.bats group SKIPs without it (not a failure)
shellcheck --version     # OPTIONAL — not wired into CI (see CQ40 gap in the backlog)
ls ~/.zuvo/{append-runlog,append-retro,verify-audit,compute-preload}   # telemetry + gates
adversarial-review --help | head -3     # cross-model review CLI
```

A missing optional tool must be reported in the run summary, never silently absorbed. `bats`
absent is a legitimate SKIP; `rg` absent is a broken run that LOOKS like a test failure.

---

## 1. The five commands (in this order, always)

| # | Command | Time | What it proves |
|---|---------|------|----------------|
| 1 | `bash scripts/validate-skills.sh` | ~10 s | Structural lint: frontmatter, H1, argument tables, mandatory-file-loading blocks, **include-path integrity** (existence + canonical depth), **count consistency** across 8 files, gate-region freshness |
| 2 | `python3 scripts/gen-gate-copies.py` | ~1 s | Every GENERATED gate region matches the registry (no `--write` = read-only check; prints `N stale`) |
| 3 | `bash tests/gates/test-gate-consistency.sh` | ~5 s | Gate-family invariants: contiguous IDs, no hand-maintained copy outside the registry, no stale `AP1-APnn` range claims, percentage-not-count thresholds, criticality vocabulary, CAP9↔CQ11 paired limits |
| 4 | `python3 scripts/audit-registry-integrity.py` | ~1 s | Cross-registry referential integrity: pentest probes ↔ finding types ↔ safe patterns, check↔fix pairing, severity-vocabulary rows |
| 4b | `python3 scripts/verify-review-claims.py --claims <artifact> --anchor <range>` | ~1 s | Review's Validity Gate claims (sub-agent dispatches, adversarial passes, self-review `--multi`) against the HARNESS-written session transcript — the only check that can catch a typed-but-not-done gate |
| 5 | `bash tests/run-all.sh` | ~6-10 min | The 60-child suite (hooks, seo/geo/pentest/infra/benchmark/skill suites). `RESULT: PASS=n FAIL=0` is the only acceptable outcome |

Anything that edits a gate: run 1→2→3. Anything that edits a registry: add 4. Anything else: 1 then 5.

```bash
# One-liner for "am I clean right now"
bash scripts/validate-skills.sh && python3 scripts/gen-gate-copies.py \
  && bash tests/gates/test-gate-consistency.sh \
  && python3 scripts/audit-registry-integrity.py --strict && bash tests/run-all.sh
```

**Container-starting tests need patience, not a timeout.** `tests/infra-suite/*` brings up Docker
fixtures on fixed loopback ports. Run them in the background and WAIT; a timeout kills the script
and orphans the containers, and the next run then fails on a port conflict that looks like a flake.
If you must stop one, run the compose `down -v --remove-orphans` shown in §5 afterwards.

**Scope switch:** `ZUVO_TEST_SCOPE=full bash tests/run-all.sh` adds `tests/adversarial/run.sh`
(hits real provider CLIs — slow, needs auth). Default `fast` is what you run per change.

---

## 2. Per-change-type checklist

| You changed… | Run | Also |
|---|---|---|
| A gate row in `shared/includes/gate-registry.md` | 1→2 (`--write`)→3 | Sweep prose ranges: `grep -rn 'CQ1-CQ40\|Q1-Q25\|CAP1-CAP29\|AP1-AP32' --include='*.md' .` — the range guard catches ranges, **not** prose counts like "30 anti-patterns" (that one shipped) |
| A skill (`skills/*/SKILL.md`) | 1, 5 | `bash scripts/build-codex-skills.sh "$PWD"` — the Codex build fails on Claude-Code-only tool names the validator does not check |
| A check/fix registry or the pentest family | 1, **4**, 5 | `--strict` in the pre-commit loop: an unreachable fix type or a dangling probe id is invisible to every other check |
| A shared include | 1, 5 | Check its loaders: `grep -rln '<filename>' skills/ shared/` — an include nobody loads is dead weight |
| A rules file | 1, 5 | Verify at least one stack-detection table routes to it (`skills/{review,using-zuvo,refactor,security-audit}/SKILL.md`) |
| Adding a skill | The 8-place checklist in `CLAUDE.md` → then 1, 5 | `count-consistency: OK (N)` must show the new N |
| A hook / `scripts/*.sh` | `bash -n <file>`, 5 | Hook tests live in `tests/hooks/`; add one for new behavior |
| Anything shipped to users | all five + `./scripts/install.sh` | Restart the client app AFTER install completes (Codex indexes skills at launch) |

---

## 3. Review gate (before push)

This repo gates its own pushes on review coverage (`hooks/lib/pipeline-gate-lib.sh`). A change of
≥3 production files or ≥150 lines needs a review artifact whose content key matches the pushed
blobs:

```bash
/zuvo:review <base>..<head>          # writes memory/reviews/<base7>..<head7>-<slug>.md + proof
scripts/review-artifact-sync.sh --check      # lints the artifact header before you rely on it
```

The artifact needs a real `adversarial:` proof file with ≥2 `REVIEW BY:` provider lines —
`zuvo/context/` or `zuvo/proofs/`. An artifact without its proof reads to the gate exactly like
"never reviewed".

---

## 4. Periodic deep audit (quarterly, or after a big feature wave)

The suite verifies STRUCTURE. It cannot verify that a document tells the truth. That is this
section — the procedure that produced the 2026-08-01 sweep, in repeatable form.

### 4.1 Scope inventory

```bash
git ls-files '*.md' | awk -F/ '{print $1}' | sort | uniq -c | sort -rn
ls rules/*.md | wc -l ; ls shared/includes/*.md | wc -l ; ls skills/*/SKILL.md | wc -l
```

Audit in four batches, one agent each (they are independent; run in parallel):
1. **Core quality** — `rules/cq-*.md`, `file-limits.md`, `security.md`
2. **Testing** — `rules/testing.md` + the `shared/includes/test-*.md` family + `q-scoring-protocol.md`
3. **Stacks** — `rules/{python,php,yii2,nestjs,express,go,rust,dotnet,ruby,astro,payload,sanity,typescript,react-nextjs}.md`
4. **Registries & examples** — pentest family, seo/geo/content/infra check+fix registries, `write-e2e/references/*`

### 4.2 The five questions each agent answers per file

1. **Purpose-fit** — one clear job? content that belongs elsewhere?
2. **Correctness for the current year** — deprecated/removed APIs (this is where PHPUnit 12's
   removed `addMethods()` and Express 5's changed async-error semantics surfaced), version-stale
   claims, wrong facts.
3. **Does every example implement its own prose?** ← the highest-yield question in the whole
   procedure. Two of the most serious findings of the last sweep came from it (a path-traversal
   example that realpath'd the wrong directory; a mock guide whose rule contradicted its own
   snippet). Grep and row-counting cannot find this class.
4. **Duplication / drift** — same content in two files that load together, or two copies that
   have diverged (one has a fix the other never got).
5. **Load path** — who reads this file? An authoritative document nobody loads is as broken as a
   missing one, and a pointer into a file the tier SKIPs is worse (it looks correct).

### 4.3 Mechanical integrity checks

```bash
python3 scripts/audit-registry-integrity.py            # human output, exit 0
python3 scripts/audit-registry-integrity.py --strict   # exit 1 on any finding (use in CI/gates)
```

Checks that the suite structurally cannot: every `probe_template_id` the pentest finding map
references is defined (and vice versa), every `finding_type` used by a safe-pattern row exists,
every seo/geo/content fix type is emittable by at least one check row (deliberate
manual-escalation types are allowlisted in the script, not silently ignored), and every skill
that cites `severity-vocabulary.md` has a row in it. Each of those was a real defect on
2026-08-01 — 11 dangling probes, 2 undefined finding types, 4 unreachable geo fix types with
~140 lines of dead templates, 4 missing severity rows.

```bash
python3 scripts/check-skill-structure.py --verbose     # per-skill, run 1 already calls it silently
```

Two classes that reading the files does NOT catch, both proven on real defects. A code fence
closed in the WRONG PLACE still passes a parity count of ```` ``` ````, and that hid eight skills
whose `### Retrospective (REQUIRED)` section sat inside the completion block's fence — rendering
as sample output to print rather than an instruction to follow. Those are the exact steps the
retro-gate enforces, so a skill could reach COMPLETE with all three log files empty. Separately,
a duplicate ordinal in a Mandatory File Loading list is cosmetic, but it hid four skills printing
a file as READ that their prose never told the agent to open — one of them `no-pause-protocol.md`,
the HARD rule against mid-batch pauses. Both are locked by `tests/gates/test-skill-structure.sh`,
which also pins the false-positive classes (template headings inside a fence are legitimate).

### 4.4 Output

Write findings to `zuvo/reports/<topic>-audit-YYYY-MM-DD.md` with a prioritized change plan
(the three from this sweep are the template: `gate-audit-`, `rules-audit-`, `pattern-docs-audit-`).
Implement in small batches, each verified by §1 and committed separately, then review the whole
range with `/zuvo:review` and fix what the providers find.

---

## 5. Failure triage

| Symptom | Almost always means |
|---|---|
| `include-integrity` ERROR | A path with the wrong depth. `agents/` and `references/` files sit 3 levels deep → `../../../`; `SKILL.md` sits 2 → `../../` |
| `count-consistency` ERROR | A skill count changed and one of the 8 places was missed (README's intro line was the blind spot until it got its own check) |
| `gate-registry: stale` | A generated region was hand-edited, or the registry changed without `gen-gate-copies.py --write` |
| `stale gate range(s) claimed` | A family grew and a `AP1-APnn`-style claim was left behind |
| `hand-maintained gate table outside the registry` | A table of ≥12 gate-ID rows appeared outside a GENERATED region — split it or move it into the registry |
| seo-suite fails at "Shared Registries" | `rg` is not installed (see §0) — an environment failure wearing a test failure's clothes |
| infra-suite: `Bind for 127.0.0.1:220x failed: port is already allocated` | An EARLIER run of this suite was killed (timeout, Ctrl-C, harness stop) and its containers outlived the script. **Never kill a container-starting test with a timeout** — the script dies, the containers do not. Clean with `cd tests/infra-suite/fixtures && docker compose -p zuvo-infra-fixtures down -v --remove-orphans`, then re-run. Misreading this as a pre-existing baseline is the trap: it presents as a flaky Docker test and is actually your own debris (happened 2026-08-02, and was written into a commit message as "pre-existing" before being diagnosed). |
| `test-suite-e2e.sh` FAILs in the suite but PASSes standalone | Two different things hide behind that one child, and they need opposite responses. **Attribute before you label** (2026-08-03): `test-infra-collector-hardening.sh` fails identically at the previous commit — deterministic and pre-existing, NOT flaky. `test-infra-collector-live.sh` passes 2/2 standalone and fails under the full suite (lynis emits no `Hardening index` marker) — context-dependent on suite load. Calling the whole child "flaky" because the standalone run was green is wrong on the first half. Attribute with `git worktree add --detach /tmp/base-check HEAD~1` and run the same child there (§6b); a standalone pass alone proves nothing. |
| A dozen `tests/hooks/*` children FAIL under `rt` (i9 farm) but PASS locally | **Do not run this repo's hook tests on the farm.** Measured 2026-08-03: `rt bash tests/run-all.sh` reported 13 failures in 108 s; every one of them passed standalone both at HEAD and at the previous commit. The hook suite asserts on real git state, `~/.claude`, `~/.zuvo` and gitignored `memory/reviews/` artifacts, none of which the farm's delta mirror carries — so gates that should see a covered range see an unreviewed one and cases like `(d1) small should pass` fail. This is an environment mismatch wearing a regression's clothes, and it is the reason a farm run of the FULL suite here is not a valid green/red signal. `rt` stays correct for the parts of the suite that are pure file analysis. Attribute the same way as the row above before believing any farm failure. |
| `smoke-skill-testing.sh` step 1 FATAL, children green | It re-runs the whole suite; a concurrent session committing mid-run races it. Re-run on a quiet tree |
| Suite green, behavior wrong in the client | The install/cache path, not the code: `./scripts/install.sh`, then restart the app; verify `installPath` in `installed_plugins.json` |

---

## 6. Cadence

| Frequency | Action |
|---|---|
| Every change | §1 (commands 1 + 5; add 2-4 for gate/registry edits) |
| Every push of ≥3 files / ≥150 lines | §3 review artifact + proof |
| Every release | All five + `bash scripts/build-codex-skills.sh` + `./scripts/release.sh` (which re-runs the suite) |
| Quarterly / post-feature-wave | §4 deep audit, one report per batch |
| When a retro repeats a theme 3× | Audit that specific area early — the retro loop (`docs/retro-learning-loop.md`) is the trigger, not the calendar |

---

## 6b. Never test an old commit by checking it out in a shared checkout

To answer "did this fail before my work?", the obvious move is `git stash && git checkout <old>
&& run && git checkout - && git stash pop`. **Do not.** This repo regularly has a second agent
session working in the same tree (it happened three times on 2026-08-02). That sequence stashes
THEIR uncommitted work, makes their files vanish from disk for the duration, and relies on a clean
pop. It worked when I did it — and it was luck, not method.

Use a throwaway worktree instead; it touches nothing:

```bash
git worktree add /tmp/base-check <old-sha>
( cd /tmp/base-check && bash tests/<the-one-test>.sh ); echo "exit=$?"
git worktree remove --force /tmp/base-check
```

## 7. What none of this catches (stated, not hidden)

- **Self-attested review fields other than the three verified ones.** `verify-review-claims.py`
  checks dispatches, adversarial passes and the self-review `--multi` rule against the transcript.
  The per-gate CQ/Q scores, confidence numbers, severities and every `N/A` justification remain
  the agent's word. Anchor the check on a value the WORK produced (a post-work SHA, the artifact
  filename) — the transcript contains the conversation, so an anchor you merely discussed matches
  itself.

- **Behavioral quality of the skills themselves.** The suite checks contracts and structure; only
  `zuvo:skill-eval` (against `evals/*.evals.json`, 24 corpora) measures whether a skill actually
  does its job on a real task.
- **Prose that is well-formed and wrong.** Only the §4 audit, and only via question 3.
- **Cross-session interference.** Two agents committing to this repo at once produce ranges that
  contain each other's work — check `git log` before treating a finding as yours (that happened
  twice during the 2026-08-01 sweep).
- **Anything on the user's machine after install.** The cache/`installPath` layer is verified by
  restarting the client, not by this suite.
