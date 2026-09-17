# Corrections workbook — column contract

The workbook is consumed by two readers: a script that writes column I into the export,
and a person who does not read the target language. Every rule below exists because one of
them was burned.

## Columns (exactly, in this order)

`# | Severity | Category | Global Id | Export Variable | Q Label | Original Text (EN) | Current Translation | Proposed Correction | Comment`

- `Global Id`, `Export Variable`, `Original Text (EN)`, `Current Translation` are copied
  from the export verbatim (bytes included — NBSPs stay NBSPs in `Current Translation`).
- `Q Label` = the question's label (S3, Q6x2 …) also on option/statement rows.

## Column I — `Proposed Correction`

1. Holds **only** the exact final value of `Translated Text` for that cell — byte-applicable.
2. Empty = this row requires no change to column E.
3. Never: prose, instructions, column references, `—`, `-`, `n/a`, `(see comment)`,
   "revert", "keep", "master", "source", "target", "script", "global", arrows.
4. A value byte-equal to the source cell (`Original Text`) is always legitimate — that is
   how mirrored markup, CSS and untranslatable labels are proposed.
5. If `Current Translation` contains target-script letters, so must the value (a value that
   switches script is prose, not a translation). Exempt: values equal to the source cell.
6. No NBSP in a value except where it mirrors an NBSP the source has before a
   `{{placeholder}}`.
7. FLAG rows may carry an exact alternative value (adoptable by relabeling the severity) or
   stay empty. The apply step never applies FLAG rows.
8. Non-FLAG rows never carry a value equal to `Current Translation`.

## Rows that act on something other than column E

Keep column I empty and open `Comment` with a machine-readable prefix carrying the exact
value where there is one:

- `SOURCE→ <exact column D value>` — source defect or source overwrite. One row per cell.
  Closes in re-verification when column D byte-equals the value.
- `POLICY: …` — a client/termbase decision (brand script, jargon left in English).
- `DESIGN: …` — questionnaire design (missing 0 % option, CSS in translatable text).
- `INFO: …` — a decision taken, recorded so the next round does not reopen it.

## Rows

- One row per affected cell. Never bundle several Global Ids in one row; never create rows
  without a real key from the export.
- Two rows for the same cell are fine when one is a value (e.g. MEDIUM) and the other a
  FLAG with an alternative value or a `SOURCE→` note.
- A global note (e.g. "OPAP is Latin in 21 cells") attaches to the first stem-level cell
  that contains it, and to the chat verdict.

## Column J — `Comment` structure

```
CHANGE: "<old fragment>" → "<new fragment>"
EN: "<gloss of old>" → "<gloss of new>"
<reason — why it matters for the respondent or the data>
<history — untouched in R2 / introduced in R3 / regressed in R4 / closed clean in R4, re-opened by …>
```

- Fragment = the changed span widened to word boundaries; never the whole cell. Show NBSP as
  `{NBSP}`. For `SOURCE→` rows: `CHANGE (col D): "<current>" → "<required>"`.
- The EN gloss is mandatory for every value change; "EN: same text; NBSP → space" is a
  valid gloss.
- For a FLAG value equal to the source cell:
  `CHANGE: "" → "(= Original Text (EN) verbatim, N chars)"`.
- Process notes (which script skipped what) go last, after the reason.

## Apply contract (for the script that consumes the workbook)

Apply iff `Severity ≠ FLAG` AND column I non-empty AND column I ≠ column H. Locate the
target row by (`Global Id`, `Export Variable`) and write **column E only** — never a
sheet-wide find/replace (it overwrites the source wherever source == target), never columns
D/F/G. Cells containing HTML, `{{placeholders}}` or NBSP are in scope; if the script cannot
handle them it must report them, not skip silently.

## Self-check before saving (assert, do not warn)

a. every (`Global Id`, `Export Variable`) exists in the export;
b. non-empty column I ≠ source cell contains no `→` and no meta-vocabulary as a whole word
   (`master source target col column columns revert keep remove strip mirror see comment
   global script apply n/a tbd`), case-insensitive;
c. column I is never a bare dash/placeholder;
d. target-script rule (I.5 above);
e. every empty column I has a Comment starting with `SOURCE→` / `POLICY:` / `DESIGN:` / `INFO:`;
f. no non-FLAG row has column I == column H;
g. every row with a value change has a Comment starting with `CHANGE`;
h. no NBSP in column I except the mirrored one before a placeholder.
i. every non-FLAG value change carries an `EN:` gloss line;
j. every cell — the header and the Normal style included — is in the font `scripts/stqa_fonts.py`
   resolved for the target script, and that font is proven to contain every codepoint written.

`stqa_workbook.QABook.write()` asserts a–j; `stqa_adversarial.AdvBook.write()` applies b–d, h
and j to `Adversary Proposed`. Rows whose Export Variable is empty or repeated (Translation File
exporter: `…|0` rows) are addressed in both builders as `<Global Id>::<Export Variable>`.

The deny-list (b) is a backstop; the rule is (d) + (e): a target-cell value or nothing.

## Formatting

The font comes from `scripts/stqa_fonts.py`, not from habit: Arial 10 pt for Latin, Greek, Cyrillic,
Hebrew and Arabic; Tahoma for Thai, Yu Gothic for Japanese, Malgun Gothic for Korean, Microsoft
YaHei for Chinese, all at 11 pt. The first candidate per script is the one that ships with Office
on Windows and macOS, because the reader's machine is the one that has to draw the glyphs; local
font files are only ever used to disprove a candidate. `write()` refuses to save a file with a
cell in another font, and a house font is passed as `font=` / `--font`. NBSP appears in Comments as
`{NBSP}`, never `⍽` (U+237D) — no Office font draws that character. Header bold white on `1F4E79`; Severity fills CRITICAL `C00000`
(white bold text), HIGH `ED7D31`, MEDIUM `FFC000`, LOW `A9D08E`, FLAG `8EA9DB`; thin `D9D9D9`
borders; wrap text, vertical top; `freeze_panes = "A2"`; autofilter over the full range;
widths roughly `5, 11, 34, 20, 16, 9, 48, 52, 52, 70`. RTL target language: `horizontal="right"`
and `readingOrder=2` on `Current Translation` and `Proposed Correction`. Sort
CRITICAL → HIGH → MEDIUM → LOW → FLAG, then number.

## Naming

`{project}_{LANG}_QA_Corrections.xlsx`; re-verification rounds append `_R2`, `_R3` … where
the number is the round of the *export* being verified. Overwrite the same round's file when
correcting the workbook itself; say so in chat.
