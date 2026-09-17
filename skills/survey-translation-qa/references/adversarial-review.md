# Adversarial review (second model, other family)

A corrections workbook is never delivered on one model's word. A second model from the
other family attacks it before the human sees it. The attacker's job is to find what the
primary got wrong — false positives, false negatives, wrong severities, contract breaches,
claims the artifacts do not support — not to re-do the review.

## Routing (fixed)

| Primary QA run on | Adversarial review run on |
|---|---|
| GPT Astra (any tier) | **Fable 5.1 Max** |
| Fable (any tier) | **Astra Max** |

Never the same family for both passes; always the Max tier for the adversary. Record both
model names in the chat verdict and in the adversarial file name.

## When

- Mandatory before delivering a workbook in Mode A and Mode B.
- Skipped for Mode C (no file to attack); the Mode C verdict must say "no adversarial pass".
- Optional for a round whose workbook contains only LOW and FLAG rows — say so if skipped.

## How to run it

In a chat session, hand the files to the other-family model directly. In a terminal agent there
is no model switch inside the session, so the round goes out through a cross-family CLI:

```bash
bash "$STQA" adversary --project ACME --lang EL --script el --round 2 \
    --export new.xlsx [--previous old.xlsx] --workbook ACME_EL_QA_Corrections_R2.xlsx \
    --verdict verdict.txt [--client codex|agy|kimi] [--model <id>]
```

It copies the inputs into a scratch directory (the originals are never touched), writes the prompt
below into it, runs the client, and copies the adversarial file and its summary next to the
workbook — named after the model the CLIENT reports, not the one the model calls itself. Exit 3 =
no cross-family client on PATH, exit 4 = the client produced no file; both mean the round is
UNREVIEWED and a CRITICAL/HIGH workbook does not ship as GO.

## What the adversary receives

1. The export(s) under review (and the previous export in Mode B).
2. The primary's workbook — every row, including FLAG and INFO rows.
3. The primary's chat verdict (the claims to attack).
4. This skill (same rules, same scripts).

Not the primary's reasoning, drafts or transcript. Independence is the point.

## Procedure

**1. Reproduce the numbers.** Run `"$STQA" integrity` (and `diff`/`verify` in Mode B)
yourself. Every count in the primary's verdict (rows, NBSP chars/cells, fix-rate,
regressions, grid identity) must match your run. A mismatch is either a script defect or a
file mix-up — report it before anything else.

**2. Simulate the apply.** `"$STQA" simulate <export> --workbook <QA.xlsx> --out patched.xlsx --script <xx>`
applies the workbook to a copy of the export and re-runs integrity. Anything under
`NEW_issues_introduced_by_workbook`, `NEW_grid_mismatches`, `stale_rows` or
`keys_not_in_export` is a defect of the workbook itself and is reported as **DROP** or
**DISPUTE** with the evidence. The NBSP count after simulation must be the mirrored-placeholder
count only.

**3. Attack every proposal as text.** For each non-FLAG row: back-translate the proposed value
and check it against `Original Text`; check grammar, agreement, accents, register; check it
against the termbase the primary itself established (a proposal that uses a term the
workbook standardises differently elsewhere is a **DISPUTE**); check that sibling cells
(grid rows, parallel options, recurring instructions) received the same proposal — a term
fixed in two of three siblings is a **DISPUTE** on the third. Check the CHANGE line matches the
actual diff and the EN gloss is faithful.

**4. Hunt false negatives.** Read the whole export, not a sample. Priority order: the first
question; numeric and currency cells; cells with HTML, `{{placeholders}}` or `<style>`;
every grid and parallel battery; recurring instructions; intros preceding opinion
questions; brand names and jargon. Anything real that is not in the workbook is an **ADD**
with a full-contract row (exact value, CHANGE, EN gloss, severity argued).

**5. Dispute severities** in both directions. Under-rating to avoid churn and over-rating
to look thorough are both findings. Cite the tier definition.

**6. Attack the verdict's claims.** "Source column changed" — is it the master or an exporter
difference (`&nbsp;` vs U+00A0, `<br />\n` vs `<br/>`)? "Grid identical" — byte-identical or
after normalisation? "GO" — does any CRITICAL/HIGH remain open? Each unsupported claim is a
**DISPUTE** against the verdict, referenced as row `V`.

**7. Contract audit.** Any row with prose in `Proposed Correction`, a synthetic Global Id,
an empty value without a prefixed Comment, a missing CHANGE/gloss, an NBSP in a value, a
script switch — **DROP** or **DISPUTE** (contract).

## Output — the adversarial file (built with `scripts/stqa_adversarial.py`)

The adversary prepares the Excel itself, with `AdvBook` — never by hand. `write()` refuses
a file in which any primary row lacks a verdict, a value breaks the contract, or an
Argument is thin.

```python
from stqa_adversarial import AdvBook
adv = AdvBook(export, primary_workbook, script="el", primary_model="GPT Astra", adversary_model="Fable 5.1 Max")
adv.confirm(1, "Reproduced NBSP 22→1 in simulate; proposal grammatical; termbase-consistent.")
adv.dispute(7, severity="HIGH", argument="Stem divergence in a parallel battery is HIGH by the tier table.")
adv.dispute(12, proposed="<exact value>", argument="<evidence>")
adv.drop(19, "simulate: NEW_issues_introduced_by_workbook lists this cell (NBSP in value).")
adv.add("MEDIUM", "Grid identity", "p3-q10-a51", argument="a26/a38 got 'σε', a51 did not.", repl=[("(όχι OPAP", "(όχι σε OPAP")], gloss="EN: …")
adv.verdict_dispute("GO", "HIGH #4 is still open — GO is not supported by the workbook.")
adv.write(f"{project}_{LANG}_QA_Adversarial_R{n}_Fable-5.1-Max.xlsx")
```

`{project}_{LANG}_QA_Adversarial_R{n}_{adversary-model}.xlsx`, one sheet, columns exactly:

`# | Verdict | Ref # | Severity (adversary) | Global Id | Export Variable | Q Label | Original Text (EN) | Current Translation | Primary Proposed | Adversary Proposed | Argument`

- `Verdict` ∈ **CONFIRM** (row stands as is), **DISPUTE** (row stands but value or severity
  is wrong — `Adversary Proposed` holds the corrected exact value or is empty when only the
  severity is disputed), **DROP** (row must go — proposal introduces an error, duplicates,
  or breaches the contract), **ADD** (a finding the primary missed; `Ref #` empty).
- `Ref #` = the primary workbook's row number; `V` for a verdict claim.
- `Adversary Proposed` follows the same contract as `Proposed Correction`: exact target-cell
  value or empty. Never prose.
- `Argument` opens with the evidence: the source text, the grammar rule, the byte, the
  termbase entry, the simulate output line. One paragraph; no hedging words.
- Sort: DROP → DISPUTE → ADD → CONFIRM. Every primary row appears exactly once (CONFIRM rows
  too — silence is not confirmation). Same formatting as the corrections workbook, the font rule
  included (`references/workbook-contract.md` → Formatting): the adversarial file is read by the
  same client and a boxed cell there is just as unreadable. Verdict fills: DROP `C00000` white
  bold, DISPUTE `ED7D31`, ADD `FFC000`, CONFIRM `A9D08E`.
- `AdvBook` also refuses a hedge outside a quotation (`maybe`, `seems`, `arguably`, …): the
  Argument is evidence, and the primary's own wording belongs in quotation marks.

Chat summary from the adversary (≤200 words): counts per verdict → the three most
consequential findings → whether the primary's GO/NO-GO survives.

## Reconciliation (done by the primary, or by the human if the models disagree)

Run `scripts/stqa_reconcile.py` with a `decisions.json` that has one entry per DROP / DISPUTE /
ADD row of the adversarial file, keyed by that file's `#`:

```
bash "$STQA" reconcile --export <export> --primary <QA_Rn.xlsx> --adversarial <QA_Adversarial_Rn_X.xlsx> \
    --decisions decisions.json --out <QA_Rn.xlsx> --script el --adversary "Fable 5.1 Max"
{"1": {"decision": "accept", "reason": "simulate shows NBSP introduced"},
 "3": {"decision": "reject", "reason": "source says 'use'; 'visit' is a meaning change"}}
```

The script refuses to run if any non-CONFIRM row has no decision, if a decision names a row the
adversarial file does not have, if a decision carries no reason, if the adversarial file leaves a
primary row silent, applies accepted values /
severities / additions / deletions, appends `ADV (<model>): confirmed | accepted — … |
rejected — … | added — …` to every Comment, and re-runs the full column-contract check on
the result. It prints what was dropped, added, rejected and how the verdict claims were
decided — paste that into the chat verdict.

- Every DROP / DISPUTE / ADD is resolved explicitly: **accept** or **reject** with a reason
  that cites evidence. No silent discards; no majority vote — evidence decides.
- An ADD accepted becomes a normal row; a DROP accepted deletes the row and the deletion is
  listed in the chat verdict.
- Unresolved disagreements (both sides cite evidence) are handed to the human with both
  arguments verbatim and a recommendation. They block delivery only if CRITICAL/HIGH.
- The delivered workbook is the reconciled one; the adversarial file is delivered alongside
  it. The chat verdict adds one line:
  `Adversarial review (<model>): N confirmed / N disputed / N added / N dropped; unresolved: …`
  and the GO/NO-GO is restated after reconciliation.

## Prompt template for the adversary

```
You are the adversarial reviewer for a survey translation QA round. Your job is to break the
attached corrections workbook, not to redo the review. Read the skill `survey-translation-qa`
and follow references/adversarial-review.md exactly.

Inputs: export(s) <files>, primary workbook <file>, primary verdict <text>.
Language: <xx>. Primary model: <name>. You are: <name>.

Steps: reproduce the numbers with scripts/stqa_checks.py; simulate the apply; attack every
proposal as text; read the whole export for misses; dispute severities both ways; attack
each claim in the verdict; audit the contract.

Deliver: {project}_{LANG}_QA_Adversarial_R{n}_<your-model>.xlsx, built with
scripts/stqa_adversarial.py (AdvBook), with the 12-column schema
(every primary row appears once, CONFIRM included) and a ≤200-word summary. Exact values
only in "Adversary Proposed"; evidence first in "Argument". Do not soften findings; do not
invent findings to look busy — an all-CONFIRM file with reproduced numbers is a valid result.
```
