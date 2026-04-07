# Content Fix Registry (shared between content-audit agents and content-fix)

> Single source of truth for `fix_type` identifiers, safety classifications,
> validation rules, and expanded fix contracts.
> Both `content-audit` agents (producers) and `content-fix` (consumer) MUST use
> this registry.
> If a `fix_type` is not listed here, it is not auto-fixable.

## Fix Inventory

| fix_type | Description | Fixable? | Safety | eta_minutes |
|----------|-------------|----------|--------|-------------|
| `encoding-strip` | Replace NBSP→space, remove ZWS/BOM/soft-hyphens | Yes | SAFE | 5 |
| `encoding-mojibake` | Replace garbled multi-byte sequences with correct characters | Yes | MODERATE | 10 |
| `markdown-fix` | Close unclosed italic, remove orphan `\` lines, fix split italic | Yes | SAFE | 5 |
| `artifact-remove` | Remove legacy CMS tags, shortcodes, PHP fragments, deprecated HTML | Yes | MODERATE | 10 |
| `typography-fix` | Collapse double spaces, fix double punctuation | Yes | SAFE | 5 |

**Audit agents:** For checks that result in `FAIL`, set `fix_type` to the
matching value above. If no fix type matches, set `fix_type: null`.

**content-fix:** Only processes findings where `fix_type` is in the fixable rows
above.

## Safety Classification

| fix_type | Safety | Rationale |
|----------|--------|-----------|
| `encoding-strip` | SAFE | Mechanical removal of invisible characters. No semantic change. |
| `encoding-mojibake` | MODERATE | Requires pattern confidence. Garbled sequences could be intentional (code examples showing encoding corruption). |
| `markdown-fix` | SAFE | Closes unclosed formatting at paragraph boundaries. Minimal semantic risk. |
| `artifact-remove` | MODERATE | Removes CMS-specific markup. Could remove intentional legacy content if misidentified. |
| `typography-fix` | SAFE | Mechanical whitespace/punctuation normalization. |

## Fix Parameters Schema

| fix_type | Required params | Optional params |
|----------|-----------------|-----------------|
| `encoding-strip` | -- | `target_chars` (which chars to strip: `nbsp`, `zws`, `bom`, `soft-hyphen`, `all`) |
| `encoding-mojibake` | -- | `source_encoding` (auto-detect or specify: `latin1`, `windows-1252`, `iso-8859-2`, `iso-8859-9`) |
| `markdown-fix` | -- | `fix_backslash` (boolean, default true for Hugo, false for GFM targets) |
| `artifact-remove` | -- | `artifact_types` (which types: `joomla`, `wordpress`, `php`, `legacy-html`, `wysiwyg`, `all`) |
| `typography-fix` | -- | `preserve_ellipsis` (boolean, default true — don't collapse `...` to `.`) |

## Expanded Fix Contracts

### `encoding-strip`

- **Target characters:**
  - U+00A0 (NBSP) → U+0020 (regular space)
  - U+200B (zero-width space) → remove
  - U+200C (zero-width non-joiner) → remove
  - U+200D (zero-width joiner) → remove
  - U+FEFF (BOM / zero-width no-break space) → remove
  - U+00AD (soft hyphen) → remove
  - U+FFFD (replacement character) → remove (flag for manual review)
- **Scope:** Body content AND frontmatter string fields
- **Exclusions:** Do not modify content inside fenced code blocks (` ``` `)
- **Validation:** After fix, grep for target characters — expect 0 matches

### `encoding-mojibake`

- **Mojibake signature table:** Replace garbled byte sequences with correct
  characters. Each entry maps a corrupted form to the original character and
  the source encoding that caused the corruption.

  **Latin-1 / Windows-1252 → UTF-8 corruption:**

  | Corrupted | Original | Char |
  |-----------|----------|------|
  | `Ã©` | `é` | e-acute |
  | `Ã¨` | `è` | e-grave |
  | `Ã¡` | `á` | a-acute |
  | `Ã ` | `à` | a-grave |
  | `Ã³` | `ó` | o-acute |
  | `Ã²` | `ò` | o-grave |
  | `Ã¼` | `ü` | u-umlaut |
  | `Ã¶` | `ö` | o-umlaut |
  | `Ã¤` | `ä` | a-umlaut |
  | `Ã±` | `ñ` | n-tilde |
  | `Ã§` | `ç` | c-cedilla |
  | `Ãª` | `ê` | e-circumflex |
  | `Ã®` | `î` | i-circumflex |
  | `Ã¢` | `â` | a-circumflex |
  | `Ã´` | `ô` | o-circumflex |
  | `Ã»` | `û` | u-circumflex |
  | `Ã¯` | `ï` | i-diaeresis |
  | `Â£` | `£` | pound sign |
  | `Â©` | `©` | copyright |
  | `Â®` | `®` | registered |
  | `Â°` | `°` | degree |
  | `Â»` | `»` | right guillemet |
  | `Â«` | `«` | left guillemet |
  | `â€"` | `–` | en-dash |
  | `â€"` | `—` | em-dash |
  | `â€™` | `'` | right single quote |
  | `â€˜` | `'` | left single quote |
  | `â€œ` | `"` | left double quote |
  | `â€` | `"` | right double quote |
  | `â€¢` | `•` | bullet |
  | `â€¦` | `…` | ellipsis |

  **ISO-8859-2 (Central European) → UTF-8 corruption:**

  | Corrupted | Original | Char | Language |
  |-----------|----------|------|----------|
  | `Ä…` | `ą` | a-ogonek | Polish |
  | `Ä™` | `ę` | e-ogonek | Polish |
  | `Å›` | `ś` | s-acute | Polish |
  | `Å¼` | `ż` | z-dot | Polish |
  | `Åº` | `ź` | z-acute | Polish |
  | `Å‚` | `ł` | l-stroke | Polish |
  | `Å„` | `ń` | n-acute | Polish |
  | `Ä‡` | `ć` | c-acute | Polish |
  | `Å¡` | `š` | s-caron | Czech/Slovak |
  | `Å¾` | `ž` | z-caron | Czech/Slovak |
  | `Ä` | `č` | c-caron | Czech/Slovak |
  | `Å™` | `ř` | r-caron | Czech |
  | `Å¯` | `ů` | u-ring | Czech |
  | `Ä'` | `đ` | d-stroke | Croatian |

  **ISO-8859-9 (Turkish) → UTF-8 corruption:**

  | Corrupted | Original | Char |
  |-----------|----------|------|
  | `Ä±` | `ı` | dotless i |
  | `ÅŸ` | `ş` | s-cedilla |
  | `Ä` | `ğ` | g-breve |
  | `Ã¶` | `ö` | o-umlaut |
  | `Ã¼` | `ü` | u-umlaut |
  | `Ã§` | `ç` | c-cedilla |

- **Validation:** After fix, grep for all corrupted forms — expect 0 matches
- **Caveat:** Code examples or documentation about encoding issues may contain
  intentional mojibake sequences. Before fixing, check if the match is inside
  a fenced code block — if so, skip.

### `markdown-fix`

- **Broken italic:** Find unclosed `*` or `_` at paragraph end (line followed
  by blank line or EOF where the line has an odd count of `*` or `_` outside
  code spans). Close by appending the matching marker.
- **Split italic:** Find `* *text*` patterns (space between opening marker and
  content). Remove the extra space: `*text*`.
- **Orphan backslash:** Find lines containing only `\` (with optional
  whitespace). Remove the line. **Stack-aware:** skip this fix for projects
  targeting GFM renderers where `\` is a hard line break. Detect via
  `hugo.toml` (Hugo/Goldmark → fix) vs other stacks (skip by default,
  override with `fix_backslash=true`).
- **Validation:** Visual diff review — markdown rendering should not change
  semantics.

### `artifact-remove`

- **Joomla paths:** `/images/stories/`, `index.php?option=com_` patterns.
  **Cannot be auto-fixed** — target path is unknown. Always mark as
  `NEEDS_REVIEW` with evidence, even in `--auto` mode. The finding carries
  `fix_type: artifact-remove` for categorization but the actual Joomla path
  sub-type is excluded from automatic application.
- **WordPress shortcodes:** Remove `[caption]...[/caption]`,
  `[gallery ids="..."]`, `[embed]...[/embed]`. Extract inner content where
  applicable (caption text, embed URL).
- **PHP tags:** Remove `<?php ... ?>` and `<?= ... ?>` blocks from content
  files. These are always artifacts in markdown/HTML content files.
- **Legacy HTML:** Remove `<font ...>...</font>` (keep inner text),
  `<center>...</center>` (keep inner text), remove `align="..."` attributes.
- **WYSIWYG inline styles:** Remove `style="..."` attributes longer than 50
  characters (editor-generated CSS). Preserve shorter style attributes that
  may be intentional.
- **Validation:** After removal, verify the file still parses as valid
  markdown. Check that inner content was preserved where applicable.

### `typography-fix`

- **Double spaces:** Replace 2+ consecutive spaces with single space in prose
  lines. Do NOT modify inside code blocks, code spans, or markdown tables.
- **Double punctuation:** Replace `..` with `.` (but NOT `...` which is a
  valid ellipsis), `,,` with `,`, `;;` with `;`.
  Do NOT modify `!!` (may be intentional emphasis) or `??` (may be intentional).
- **Validation:** Grep for double spaces and double punctuation — expect 0
  matches outside code blocks.

## Confidence Scale

Assigned by audit agents per finding:

| Level | When |
|-------|------|
| HIGH | Direct evidence in source code (`file:line`, raw content match) |
| MEDIUM | Inferred from pattern or convention but not directly observed |
| LOW | Heuristic or absence-based inference |
