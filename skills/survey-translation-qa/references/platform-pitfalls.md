# Platform, editor and exporter pitfalls

Everything here was observed on the TGM survey platform (CKEditor 4 translation editor,
two xlsx exporters). Assume other platforms behave the same until proven otherwise.

## Two exporters, one master

| | mobi-1590 export | Translation File export |
|---|---|---|
| NBSP in source | decoded to U+00A0 | kept as `&nbsp;` |
| line breaks | `<br/><br/><em>` | `<br />\n<br />\n<em>` (raw stored HTML) |
| `<br>` vs `<br/>` | normalised | as stored |
| hidden questions (`hidS6`, `hidden css`) | omitted | present, target empty |
| `-e1` slots, `…|0` empty-EV rows, `<br />` option labels | omitted | present, empty |
| row count (this project) | 280 | 321 |

- Normalise before diffing across exporters: `&nbsp;`↔U+00A0, `<br />\n`↔`<br/>`, `<br>`↔`<br/>`.
- The mobi-1590 exports once showed a source column that the master never had (Greek
  number format in three EN cells). A source column that differs from the platform is an
  exporter problem — report it, do not "fix" the master.
- Hidden-CSS questions are not offered to translators; their translated text is empty.
  Expect the platform to render the source; verify once in the preview of the question
  the CSS lays out. Keep the source CSS verbatim as a FLAG value in case it does not.

## CKEditor (translation editor)

- **ACF strips `<style>`** when a cell is loaded into the WYSIWYG and keeps its text
  content. Opening such a cell and pressing OK turns the CSS into visible text under the
  question. Cells with `<style>`/`<script>` are imported from xlsx, never edited.
- **nl2br on paste**: pasting multi-line text into the WYSIWYG converts every newline to
  `<br />`, including inside `<style>`. The browser does not parse HTML inside `<style>`,
  so `<br />` reaches the CSS parser: every selector starts with `<br />` → invalid → the
  whole rule is dropped; every declaration is preceded by `<br />` → invalid → dropped.
  Result: the block is syntactically present and functionally dead (0 rules survive —
  verified with tinycss2).
- **Entities inside `<style>`** are not decoded by the browser: `content: &quot;%&quot;`
  is as dead as `<br />`. Quotes inside CSS must be literal `"`.
- The **Source dialog** shows the stored HTML: tags, newlines, quotes. It does not show
  NBSP vs space, and after OK the content passes through ACF again — reopen Source to
  confirm the tags survived before saving.
- **NBSP injection**: any manual edit through the editor (or a paste from Word/browser)
  can insert U+00A0 between words. Signature: every NBSP cell is a cell the person edited.
  Recommend one scripted normalisation of column E on import; keep the NBSP that mirrors
  the source before `{{placeholder}}`.

## Rendered listing ("Update Translation" page)

- Question fields are rendered with tags stripped but text kept — a `<style>` block shows
  as CSS text in the *source* column. The *translated* field of the same question hides
  the block entirely. Absence in the listing therefore proves nothing.
- Answer fields show tags literally (`<br>`, `<br/>`).
- The "Edited by … <date>" header may predate the content; refresh before exporting.

## Apply-script signatures (seen in re-verification)

- **Markup cells skipped**: the set of untouched cells equals the set of cells containing
  `<`, `{{` or NBSP. The script cannot write them; apply those manually, byte-checked.
- **Sheet-wide replace**: the source column changes exactly in cells where source == target
  in the previous round (numeric ranges, brand names). The script replaced by string over
  the whole sheet instead of writing column E by key.

## CSS inside translatable text

Layout CSS that lives in a question's text is translated 96 times and can be broken by any
translator with an editor. Recommend moving it to a hidden-CSS question (language-
independent) — record as `DESIGN:` on the affected cell every round until it happens.
