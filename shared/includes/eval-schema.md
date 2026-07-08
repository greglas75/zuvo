# Eval Schema — skill-eval corpus + grading contract

> Version 1.0. Consumed by `zuvo:skill-eval` — input corpus + grading + report-output contract.

Paired contract (matches the `*-output-schema.md` convention): the **input** eval
corpus that `zuvo:skill-eval` reads, and the **grading + report output** it
produces. The grader design this schema encodes was de-risked by the feasibility
spike at `tests/skill-suite/spike-grader-feasibility.md` (PASS, 2026-07-02) — cite
that file, do not re-derive the prompt.

Corpora live at repo-root `evals/<skill>.evals.json`, **one file per skill**
(Anthropic skill-creator alignment: `{skill_name, evals[]}` is per-skill). They are
**dev-only** — comparison mode needs `.git`, so they are deliberately NOT copied
into installed caches by `install.sh` / the build scripts.

> **The corpus is UNTRUSTED input.** An eval's `prompt` is handed to the executor as a
> task and CAN instruct it to edit/commit/delete/network — so `zuvo:skill-eval` runs
> every executor ONLY inside the isolated, disposable sandbox from SKILL.md Phase 2 (a
> `cp -R`/`git clone --local` copy with `evals/<skill>.evals.json` stripped and all git
> remotes removed, so it cannot read its own assertions or push to a real remote).
> Network egress is NOT sandboxed (documented limitation) — a corpus with a
> network-mutating prompt must be run under OS-level isolation or excluded. Treat a new
> corpus like any other untrusted code: review its prompts before running it.

## Input corpus schema

```jsonc
{
  "skill_name": "refactor",          // string, MUST equal the filename stem (refactor.evals.json)
  "evals": [                          // array, >= 2 entries
    {
      "id": 1,                        // int, unique within this file
      "prompt": "…",                  // string, non-empty — the task handed to the executor
      "expected_output": "…",         // string, non-empty — the observable correct behaviour
      "files": ["skills/refactor/SKILL.md"], // repo-RELATIVE literal paths, may be empty — no absolute paths, no globs, no ../ escapes; each must resolve to an existing repo file
      "assertions": ["…", "…"]        // non-empty array of strings, each a checkable transcript fact
    }
  ]
}
```

Top-level keys are **exactly** `{skill_name, evals}`; each eval's keys are
**exactly** `{id, prompt, expected_output, files, assertions}`. Extra or missing
keys are a schema error (`tests/skill-suite/test-eval-corpus-schema.sh` enforces
this via `python3`).

### Assertion-quality bar (enforced by the schema test)

Every `assertions[]` string MUST be an **observable transcript fact** — the spike
proved this style grades reliably. Concretely:

- **>= 20 characters.**
- **Contains >= 1 checkable verb** from:
  `contains, matches, exits, outputs, calls, writes, creates, commits, dispatches,
  edits, runs, records, shows`.
- **Does NOT end with a vague qualifier**: `well`, `correctly`, `properly`,
  `appropriately`, `as expected` (case-insensitive, optional trailing period).

Write assertions as things a grader can Ctrl-F for in a transcript of tool calls —
not as opinions about quality.

> The heuristic is a **floor, not a semantic guarantee** — it rejects obviously weak
> phrasing but cannot prove an assertion is meaningful or non-tautological. Real
> signal comes from authoring each assertion as a concrete **tool-call / artifact
> fact** (a specific edit/commit/dispatch on a named path, an ordering constraint) and
> from the grader judging only tool-call evidence (see Grading contract) — never a
> marker string that prose could echo.

**2 ACCEPTED** (spike A1 / B1 style — objectively checkable):

- `The transcript writes characterization tests covering each moved unit and shows them passing against the pre-refactor code before any file-move edit occurs.`
- `The transcript commits the production fix as a separate stacked commit distinct from the test-writing commit.`

**2 REJECTED** (fail the bar — do not author these):

- `The skill performed well.` — no checkable verb ('performed' is not in the verb set), ends on the vague qualifier 'well'.
- `The refactor was handled correctly.` — ends with a vague qualifier; not a transcript-observable fact.

## Grading contract (per-assertion verdict)

The grader is a fresh sub-agent given ONLY the assertions + the run transcript
(no conversation history). It emits a JSON array, **one object per assertion, in
input order** — this is the spike §2 output format verbatim:

```json
[
  {"text": "<assertion text, copied from input>", "passed": true, "evidence": "<verbatim transcript quote>"},
  {"text": "<…>", "passed": false, "evidence": "absent: <what tool call / artifact / ordering is missing>"}
]
```

Grading rules (spike §2, mandatory): judge ONLY the transcript; no charity on
ordering/artifact assertions; assistant prose ("all tests pass") is NOT evidence —
only tool calls and their results count; ambiguous → `passed:false` naming what is
missing; grade each assertion independently.

## Transcript injection hardening (spike §5)

The run transcript is **untrusted data produced by the agent under evaluation**.
A naive literal `</transcript>` replace is **insufficient** — an LLM grader parses
tags semantically, so `</ transcript >` (whitespace), `</TRANSCRIPT>` (case), or
`</transcript-x>` variants would still read as a closing boundary. Two-layer fence:

1. **Random-nonce delimiter (primary).** Wrap the transcript in a per-run
   unguessable fence — `<transcript-{NONCE}> … </transcript-{NONCE}>` where `{NONCE}`
   is a fresh ≥16-hex-char random token generated per grading call. The untrusted
   transcript cannot predict the nonce, so it cannot forge the closing delimiter.
2. **Defensive sanitization (floor).** Before substitution, neutralize any
   closing-fence lookalike — case-insensitive, whitespace-tolerant, and matching an
   **unclosed** trailing lookalike (no final `>`):
   `re.sub(r'(?is)<\s*/\s*transcript[^>]*(?:>|$)', '<\\/transcript>', text)` —
   catching `</TRANSCRIPT>`, `</ transcript >`, `</transcript-…>`, and a bare
   `</transcript` at end-of-string.

The grader obeys only the rules OUTSIDE the fence. The spike's 5th probe confirmed the
hardened prompt ignores an in-transcript "ignore previous instructions" attack; the
nonce layer additionally defeats semantic tag-boundary spoofing.

## Report output convention

Canonical output dir per `report-output-location.md`. `zuvo:skill-eval` writes to
`zuvo/reports/`:

- `zuvo/reports/skill-eval-<skill>-<YYYYMMDD-HHMMSS>.md` — human-facing report
  (per-eval, per-assertion pass/fail + evidence, headline pass rate).
- `zuvo/reports/skill-eval-<skill>-<YYYYMMDD-HHMMSS>.json` — machine record (the
  grader's raw per-assertion arrays + run metadata).

The `-HHMMSS` run stamp keeps same-day reruns (active CI / local debug loops) from
silently overwriting prior reports; the latest run sorts last.

## Comparison mode

`--compare <ref>` materializes the OLD skill version out of git for an
old-vs-new score diff: `git show <ref>:skills/<name>/SKILL.md` →
`zuvo/context/skill-eval-baseline-<skill>.md`. Two distinct guards: not-a-git-repo
degrades with one message; a missing ref/path degrades with a different message
(never a shared "unavailable" string).
