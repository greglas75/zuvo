---
name: survey-translation-qa
description: >
  Byte-level and linguistic QA of a translated survey questionnaire exported from a survey
  platform (xlsx with Global Id / Export Variable / Original Text / Translated Text), producing
  a corrections workbook an apply-script can consume, re-verifying revised exports, and checking
  pasted platform views. Use whenever the user asks to check, review, assess, re-check or
  re-verify a translation, a "wersja", a proofread version, an export, a translation file, or a
  pasted platform/mobi view of a questionnaire, or asks for "poprawki", a corrections file, a
  residual list, or a GO/NO-GO for fieldwork — even if the request is a two-word "oceń to" with
  an xlsx attached. Modes: A initial review, B re-verification, C platform-view check.
category: Content
---

# zuvo:survey-translation-qa

Check a translated questionnaire against its source, deliver a corrections workbook whose value
column an apply-script writes verbatim, and say whether the language may go to field.

**Scope:** translation QA of a platform export — byte-level integrity, linguistic review,
severity tiers, the corrections workbook, cross-model adversarial review, re-verification rounds,
pasted platform views.
**Out of scope:** translating or rewriting the questionnaire, editing the source (EN) column,
changing the questionnaire design, writing to the survey platform or its database. This skill
reads exports and produces files; the platform's own import path applies them.

| Mode | Trigger | Output |
|---|---|---|
| **A — initial review** | first export of a language | `{project}_{LANG}_QA_Corrections.xlsx` + adversarial file + chat verdict |
| **B — re-verification** | a revised export after corrections / proofreading | residual workbook `_R2`, `_R3`, … (open items only) + adversarial file + chat verdict |
| **C — platform-view check** | pasted text or screenshot from the platform editor | chat verdict only; names the artifact needed to close the rest; no adversarial pass |

Run the scripts, don't eyeball. Read `references/workbook-contract.md` before writing any row,
`references/platform-pitfalls.md` before Mode C or when an export looks "different", and
`references/adversarial-review.md` before delivering any workbook — no workbook leaves without the
cross-model pass described there.

## Argument Parsing

| Input | Meaning |
|-------|---------|
| _(one xlsx path)_ | Mode A on that export |
| _(two xlsx paths)_ | Mode B: older export first, revised export second |
| pasted text / screenshot, no file | Mode C |
| `--previous <old.xlsx>` | explicit previous export for Mode B |
| `--workbook <QA.xlsx>` | the prior round's corrections workbook (Mode B classification) |
| `--script <key>` | target script for the integrity and value checks: `el cyr ar he hy ka th ja ko zh latin` (default `latin`) |
| `--lang <CODE>` / `--project <NAME>` | file-naming parts; inferred from the export name when absent |
| `--round N` | round number for `_R{N}` naming (default: next after the prior workbook) |
| `--font <name>` | house font for the deliverables, overriding the per-script choice |

There is no flag that skips the adversarial pass. Mode C has none by definition; a round whose
workbook holds only LOW and FLAG rows may skip it, and the verdict must say so.

---

## Mandatory File Loading

Dispatch follows `../../shared/includes/execution-policy.md` through env-compat. Reuse existing
authorization within that policy; session restrictions take precedence. **Invoking this skill IS
the request for the Phase 4b cross-family pass**, so a session-level "do not spawn agents unless
asked" does not cancel it — what a restriction can change is who runs it, never whether it ran. A
round whose adversarial pass did not happen is reported UNREVIEWED, never as a satisfied gate.

### PHASE 0 — Bootstrap (before touching a file)

```
  1. ../../shared/includes/env-compat.md             -- [READ | MISSING -> STOP] (every command here is bash with $ZUVO_BASE)
  2. ../../shared/includes/execution-policy.md       -- [READ | MISSING -> STOP] (authorizes the Phase 4b hand-off)
  3. ../../shared/includes/severity-vocabulary.md    -- [READ | MISSING -> WARN] (tier <-> S1-S4 mapping for cross-skill findings)
  4. ../../shared/includes/report-output-location.md -- [READ | MISSING -> WARN] (see the exception below)
  5. ../../shared/includes/terminal-state.md         -- [READ | MISSING -> WARN] (no verdict over a pending adversarial pass)
  6. ../../shared/includes/knowledge-prime.md        -- [READ if knowledge/*.jsonl exists | else SKIP] (termbase + POLICY decisions from earlier rounds)
```

### DEFERRED — at completion

```
  7. ../../shared/includes/knowledge-curate.md       -- [READ at completion | MISSING -> degraded] (persist termbase + POLICY decisions)
  8. ../../shared/includes/run-logger.md             -- [READ at completion]
  9. ../../shared/includes/retrospective.md          -- [READ at completion]
```

### This skill's own references (not optional, phase-gated)

| File | When | Missing |
|---|---|---|
| `references/workbook-contract.md` | before writing any workbook row | STOP — the column contract is the deliverable |
| `references/adversarial-review.md` | before delivering any Mode A/B workbook | STOP — no workbook ships on one model's word |
| `references/platform-pitfalls.md` | Mode C, or any export that looks "different" | WARN |

**Output-location exception, deliberate:** the client deliverables (`*_QA_Corrections*.xlsx`,
`*_QA_Adversarial_*.xlsx`, their summaries) are written **next to the export under review**, not
under `zuvo/` — they leave the machine as attachments and a QA folder per project is how the
client files them. Run log, retro and any internal notes follow `report-output-location.md`
normally. Do not "fix" this by moving the workbooks.

---

## Running the scripts

Resolve the install root once, then use absolute paths (`env-compat.md`):

```bash
ZUVO_BASE="$(~/.zuvo/zuvo-base)"
STQA="$ZUVO_BASE/scripts/stqa.sh"

bash "$STQA" integrity <export.xlsx> --script el
bash "$STQA" diff <old.xlsx> <new.xlsx>
bash "$STQA" verify <old.xlsx> <new.xlsx> --workbook <prior_QA.xlsx> --script el
bash "$STQA" simulate <export.xlsx> --workbook <QA.xlsx> --out patched.xlsx --script el
bash "$STQA" reconcile --export <export> --primary <QA.xlsx> --adversarial <ADV.xlsx> \
     --decisions decisions.json --out <QA.xlsx> --script el --adversary "<model>"
bash "$STQA" adversary --project ACME --lang EL --script el --round 2 \
     --export new.xlsx --workbook ACME_EL_QA_Corrections_R2.xlsx --verdict verdict.txt
bash "$STQA" fonts --list                 # what each script resolves to on this machine
bash "$STQA" selfcheck                    # 55 assertions over the whole contract; run after editing a script
bash "$STQA" py -c 'from stqa_workbook import QABook; …'
```

The first run bootstraps a private venv with `openpyxl` in `~/.zuvo/stqa-venv` (needs network
once); later runs are offline, which is what lets a sandboxed adversary run the same checks. Add
`--json` for machine-readable output and `--strict` to `diff` / `verify` / `simulate` for exit 1
on a blocking result (a real source change; a workbook that introduces issues, is stale, or names
keys the export lacks). Rows whose Export Variable is empty or repeated are addressed as
`<Global Id>::<Export Variable>`.

---

## Phase 0 — Load and orient

- Sheet columns: `Global Id | Export Variable | Question Label | Original Text | Translated Text | Original Image Title | Translated Image Title`.
- Key = (`Global Id`, `Export Variable`). Question rows carry `Question Label`; option rows
  (`…-aN`) and statement rows (`0|qid|sid`, `…-sN`) do not — derive the parent label.
- Two exporters exist and represent the same master differently:
  *mobi-1590* (normalized: `&nbsp;` → U+00A0, `<br />\n` → `<br/>`, hidden questions omitted) and
  *Translation File* (raw stored HTML: entities kept, `<br />` + newline, plus `-e1` slots,
  empty-EV `…|0` rows, hidden questions `hidS6`/`hidden css`, `<br />` option labels). Compare
  like with like; never diff across exporters without normalising.
- Identify the version: diff against the previous export when there is one. If the user pastes
  text instead of a file, that is Mode C, not Mode A/B.

## Phase 1 — Byte-level integrity (script)

`bash "$STQA" integrity <export.xlsx> --script el` prints, per column:

- NBSP (U+00A0), NNBSP, thin/zero-width spaces, BOM, tabs — **chars and cells**; keep the totals,
  later rounds are compared against them.
- leading/trailing/double spaces, non-NFC text.
- homoglyphs: Latin letters inside target-script tokens, any Cyrillic; Latin-token inventory of
  the target (this *is* the English-jargon list — brand names, `online`, `PLAY`, `VLTs`, `bookmaker` …).
- tag parity source↔target after normalising `<br>`/`<br/>`/`<br />`; placeholder parity `{{…}}`;
  number parity; entity inventory (`&nbsp;`, `&quot;` …).
- cells containing `<style>`/`<script>`: byte-identical to the source after the first line, or
  identical after whitespace normalisation if deliberately one-lined. Any `<br` or `&…;` inside
  `<style>` = the CSS is dead (every selector and declaration after it becomes invalid).
- empty targets where the source has text; target == source for non-numeric cells.
- grid identity: the same source string appearing in several grids (S6 / Q1 / Q2 pattern) must be
  byte-identical in the target; parallel batteries (Q6x1/x2/x3 pattern) must have identical stems
  and byte-identical anchors; recurring instructions ("Select all that apply", "Other (please
  state)", "Don't know", "Prefer not to say") must be identical across all occurrences.

## Phase 2 — Linguistic and consistency review

Read every cell against its source. Look for, in this order of importance:

1. **Meaning changes, grammar and orthography visible to respondents** — a dropped accent on an
   interrogative (`Που` vs `Πού`), a truncated verb, a wrong case. Check the first question first;
   it is the one every respondent sees.
2. **Untranslated fragments** left in the source language (`Play hall`, `Play halls`), and glosses
   that existed for the source reader only (`(praktoreio)`) — drop them.
3. **Number and currency localisation** — thousands/decimal separators and symbol position follow
   the target locale (`€1,000` reads as one euro in a comma-decimal locale → `1.000 €`). Ranges:
   one convention for the whole scale.
4. **Termbase** — build it while reading: every recurring domain term and every recurring
   instruction has exactly one rendering, including inside one cell (do not translate one jargon
   term and keep its sibling in English in the same option). "physical venues", "brand", "shop",
   "gaming hall", "bookmaker", "payouts", "prizes", "range" are the usual offenders. Brand-name
   script (Latin `OPAP` vs `ΟΠΑΠ`) is a **policy** decision when it is consistent, not an error —
   FLAG it, do not "fix" it.
5. **Parallel structures** — options of one question that share a source phrase ("I am, or have
   been, registered") must share the target phrase; "Move some spend from X to Y" ×3 must keep the
   same syntax.
6. **Neutrality and register** — a legal term that also reads as "exploits" in an intro preceding
   an opinion question; bureaucratic nominalisations where the source is plain; colloquial terms
   respondents actually use (`φρουτάκια`, `μπουκ`) are a client decision → FLAG with the
   alternative as an exact value.
7. **Source defects** (stray `<br>`, trailing `&nbsp;`, scales with no 0 %, transliterated brand
   names in the EN master) → FLAG only; translation rounds never touch the source.
8. Note 3–5 things the translator did well (localized calques, correct geography, regulatory
   terminology, inclusive forms, intact markup). They go in the chat verdict.

## Phase 3 — Severity tiers

| Tier | Meaning | Examples from practice |
|---|---|---|
| **CRITICAL** | data-corrupting or master-corrupting | reversed/altered brackets; wrong numbers; label mismatch between a definition and its attribution question; **source column modified by a translation round**; respondent-visible raw code |
| **HIGH** | respondent-visible errors and broken constructions | grammar/orthography errors; meaning changes; untranslated fragments; number format that changes the reading; broken `<style>`; stem or anchor divergence in a parallel battery |
| **MEDIUM** | consistency and syntax | termbase violations; grid rows not byte-identical (incl. NBSP-only differences); recurring-instruction variants; awkward or ambiguous syntax; neutrality in intros; a term adopted in some sibling cells but not others |
| **LOW** | typography | NBSP in a single cell; casing of a brand; asymmetric articles; orthographic convention mixes; optional clarity rewrites |
| **FLAG** | report only | source defects (`SOURCE→`), design questions (`DESIGN:`), policy choices (`POLICY:`), accepted decisions worth recording (`INFO:`) |

CRITICAL and HIGH block field launch. MEDIUM is cleared in the same round by script. LOW never
blocks. When the tier is arguable, pick the higher one and say why in Comment; never lower a tier
to reduce churn. Cross-skill mapping (`severity-vocabulary.md`): CRITICAL + HIGH → S1, MEDIUM →
S2, LOW → S3, FLAG → S4.

## Phase 4 — The corrections workbook

Build it with `stqa_workbook.QABook` (import it, call `add()` / `flag()`, then `write()`); it
applies the formatting and refuses to save a workbook that breaks the contract. Full contract in
`references/workbook-contract.md`. The non-negotiables:

- One sheet; columns exactly
  `# | Severity | Category | Global Id | Export Variable | Q Label | Original Text (EN) | Current Translation | Proposed Correction | Comment`.
- **`Proposed Correction` is the exact final value of the target cell, or empty.** Nothing else,
  ever: no prose, no instructions, no column references, no `—`, no `(see comment)`. An
  apply-script writes this column into the export verbatim.
- Empty `Proposed Correction` means "no change to the target"; the row's action lives in `Comment`,
  opening with `SOURCE→ <exact col D value>`, `POLICY:`, `DESIGN:` or `INFO:`.
- One row per affected cell, real Global Id + Export Variable from the export; no synthetic
  "global" rows. A global note attaches to the first affected stem-level row.
- `Comment` opens with the minimal diff and a gloss the reader can understand without the target
  language: `CHANGE: "old fragment" → "new fragment"` (NBSP shown as `{NBSP}`), `EN: "…" → "…"`,
  then the reason, then history last (`untouched in R2`, `introduced in R3`, `regressed in R4`).
- Sort CRITICAL → FLAG, number rows, header white bold on `1F4E79`, severity fills
  `C00000`/`ED7D31`/`FFC000`/`A9D08E`/`8EA9DB`, thin `D9D9D9` borders, wrap, top-aligned, freeze
  `A2`, autofilter. RTL target → `horizontal="right"`, `readingOrder=2` on both translation
  columns, and the sheet itself right-to-left.
- **The font is chosen for the target script, never assumed** — `stqa_fonts.py` picks it and
  `write()` refuses to save a workbook with a cell in anything else, the Normal style included.
  Arial covers Latin, Greek, Cyrillic, Hebrew and Arabic; Thai needs Tahoma, Japanese Yu Gothic,
  Korean Malgun Gothic, Chinese Microsoft YaHei (11 pt — those scripts are unreadable at 10).
  Excel does not fall back like a browser: the wrong font is not "a bit off", it is boxes, and a
  client who does not read the target language cannot tell a box from a translation error. Show
  NBSP in a Comment as `{NBSP}` — no Office font has a glyph for `⍽` (U+237D), so the marker the
  reader was supposed to notice was itself a box. A house font goes in as `font=` / `--font`.
- Name `{project}_{LANG}_QA_Corrections.xlsx`; re-verification rounds append `_R2`, `_R3` …
  Present the file.

## Phase 4b — Adversarial review (mandatory before delivery)

A second model from the **other family** attacks the workbook before the human sees it. This is
not the code-review adversarial loop (`adversarial-loop.md`, which fans a diff out to text
providers): the artifact here is a binary workbook plus its export, so the round goes to an
agentic CLI that can open files and run the same scripts.

1. Hand the adversary the export(s), the workbook (all rows) and the chat verdict — not the
   reasoning. Use the prompt in `references/adversarial-review.md`. In a terminal agent there is
   no model switch inside the session, so run `bash "$STQA" adversary --project … --lang … --script … --round N --export … --workbook … --verdict …`
   — it hands the round to a cross-family agentic CLI (primary Claude/Fable → `codex`, i.e. GPT;
   fallbacks `agy`, `kimi`) in a scratch copy and returns the adversarial file, named after the
   model the CLIENT reports rather than the one the model claims to be. Use the strongest tier the
   client offers (`--model`). If no cross-family client answers (exit 3/4) the round is
   **UNREVIEWED**: say so in the verdict line, and a workbook with CRITICAL/HIGH rows does not
   ship as GO.
2. The adversary reproduces every number with the scripts, runs `simulate` (applies the workbook
   to a copy of the export and re-runs integrity: anything new is an error the workbook would
   introduce), attacks every proposal as text, reads the whole export for misses, disputes
   severities both ways and audits the contract. It builds the file itself with
   `stqa_adversarial.AdvBook`: `{project}_{LANG}_QA_Adversarial_R{n}_{model}.xlsx`, one verdict per
   primary row — CONFIRM / DISPUTE / DROP / ADD — evidence first, exact values only. `write()`
   refuses a missing verdict, a contract breach, a hedged Argument or a wrong font.
3. Reconcile with `bash "$STQA" reconcile` and a `decisions.json` (one accept/reject **with a
   reason** per DROP / DISPUTE / ADD; the script refuses silent discards, decisions that name no
   row, reasons that are empty, and an adversarial file that leaves a primary row silent).
   Accepted changes are applied, every Comment gets an `ADV (<model>): …` line, and the result is
   re-checked against the column contract and the font rule. No majority vote — evidence decides.
   Unresolved disagreements go to the human with both arguments and block delivery only if
   CRITICAL/HIGH.
4. Deliver the reconciled workbook and the adversarial file together; the chat verdict adds
   `Adversarial review (<model>): N confirmed / N disputed / N added / N dropped; unresolved: …`
   and restates GO/NO-GO after reconciliation. Mode C has no adversarial pass — say so.

## Phase 5 — Re-verification (Mode B)

`bash "$STQA" verify <old.xlsx> <new.xlsx> --workbook <prior_QA.xlsx> --script el`

1. Assert keys align (report rows only in old / only in new). **Diff column D first**; any change
   is CRITICAL unless it matches a `SOURCE→` row. Remember the exporter difference — a source that
   only differs by `&nbsp;` vs U+00A0 or `<br />\n` vs `<br/>` is the same master.
2. Classify every prior row: **closed clean** (target byte-equals Proposed; `SOURCE→` rows close
   on column D) / **partial** (core fixed, residue remains — e.g. term aligned but gloss dropped,
   fix applied with an NBSP) / **untouched** / **regressed**. "Acceptably resolved" counts as
   closed when the change differs from the proposal but is a consistent native choice; say so.
3. Map every changed cell to a prior row. Unmapped cells are unsolicited edits — review each fresh
   (improvement / neutral / regression) and check they were applied to *all* sibling cells: a term
   changed in two of three grid rows is a new MEDIUM, not a fix.
4. Regression hunt is mandatory: recount NBSP chars/cells against Phase 1 totals; scan every
   changed cell for new whitespace, punctuation, quote-style, entity or script changes. Rich-text
   editors inject NBSPs — if the count rises, recommend a scripted column-E cleanup on import
   instead of another manual round (keep the NBSP that mirrors the source before a `{{placeholder}}`).
5. Recognise the two apply-side signatures: **markup cells skipped** (every untouched cell contains
   `<`, `{{` or NBSP → the script cannot handle them; apply manually) and **sheet-wide replace**
   (source overwritten exactly where source == target in the previous round → the apply step must
   write column E by key only).
6. Deliver the residual workbook (open items only, severity = current state, history in Comment)
   and the verdict.

## Phase 6 — Platform view (Mode C)

A paste or screenshot verifies wording and punctuation only. Say so. Whitespace and homoglyph
status are not verifiable (the clipboard normalises whitespace; lookalikes are indistinguishable).
Close what can be closed, list what cannot, name the artifact (a fresh export) that closes the
rest. Details and the CKEditor failure modes are in `references/platform-pitfalls.md`; the short
version:

- the editor's **Source** dialog is the truth for structure (tags, newlines), not for bytes;
- the WYSIWYG strips `<style>` and keeps its text (respondents would see raw CSS); pasting
  multi-line text applies nl2br and puts `<br />` inside `<style>`; both kill the layout — cells
  with `<style>` are imported, never edited;
- the rendered listing strips tags in question fields but not in answer fields, so a missing
  `<style>` in the listing is not evidence either way;
- hidden-CSS questions are absent from translator exports and their target is empty — expect
  source fallback, verify once in the preview of the question they lay out.

## Chat verdict (≤300 words, in the user's language)

**Initial review:** one-line verdict (translator quality vs evidence of a revision pass) →
blockers → error classes with counts → positives → release recommendation (which tiers block).

**Re-verification:** fix-rate (clean / partial / untouched / regressed) → regressions by name →
NBSP delta → remaining blockers → GO / NO-GO with the exact artifact needed for sign-off.

**Platform view:** closed on wording → not applied → new findings → not verifiable from a paste →
artifact needed.

Every Mode A/B verdict ends with the adversarial line (model, counts, unresolved) and the GO/NO-GO
restated after reconciliation. Never narrate tooling ("I loaded the file with openpyxl"). Lead
with the finding.

## Anti-patterns (each of these cost a round)

- Prose or instructions in `Proposed Correction` (`SOURCE (col D) → revert…`, `(master: strip
  NBSP…)`, `—`). The column is the cell.
- A comment that records history ("untouched in R2, skipped by the script") instead of the change;
  the reader does not read the target language and cannot spot five changed words in a
  150-character cell.
- Treating a consistent Latin brand name as an error; treating a native proofreader's consistent
  term change as a regression instead of updating the termbase.
- A deny-list tuned to the last mistake. The rule is structural: a target-cell value in the target
  script, or nothing — and a value byte-equal to the source cell is always legitimate.
- Trusting one exporter's source column over the platform; trusting a paste for bytes.
- Changing only one of three parallel options and calling the term "harmonised".
- Delivering a workbook whose target cells are boxes on the reader's machine, or a `⍽` NBSP marker
  no Office font can draw — the file looked fine on the writer's screen.
- Delivering a workbook that only one model has read; treating an adversary's CONFIRM column as
  optional ("silence is confirmation"); resolving a dispute by which model is bigger instead of by
  evidence.
- Writing the corrections into the platform or its database from here. This skill emits the patch;
  the platform's import path owns the write, its validation, its audit trail and its rollback.

---

## Completion

After the verdict is delivered, print:

```
SURVEY TRANSLATION QA COMPLETE
-----
Mode: [A initial | B re-verification R{N} | C platform view]
Findings: CRITICAL {n} / HIGH {n} / MEDIUM {n} / LOW {n} / FLAG {n}
Adversarial: {model} — {n} confirmed / {n} disputed / {n} added / {n} dropped | none (Mode C) | UNREVIEWED (no cross-family client)
Deliverables: <paths, next to the export>
Field decision: GO | NO-GO — <the artifact that closes it>
Run: <ISO-8601-Z>	survey-translation-qa	<project>	-	-	<VERDICT>	<rows>	<mode>	<NOTES>	<BRANCH>	<SHA7>	AUTO	-
-----
```


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log
file path resolved per `run-logger.md`.

`<VERDICT>` maps the field decision onto the run-log vocabulary: GO → `PASS`, GO with LOW/FLAG
rows outstanding → `WARN`, NO-GO → `FAIL`, adversarial pass impossible (no cross-family client) →
`BLOCKED`, run abandoned → `ABORTED`. `<rows>` is the workbook row count, `<mode>` is `A`, `B-R{N}`
or `C`, and `<NOTES>` carries the one-line field decision (max 80 chars, no tabs).

Then run the knowledge-curation protocol from `knowledge-curate.md`: the termbase entries, POLICY
decisions and accepted native choices from this round are what the next round must not re-litigate.
