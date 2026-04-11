---
name: presentation
description: >
  Generate PowerPoint (PPTX) presentations from a topic, outline, or content
  file. Creates professional slides using python-pptx with consistent
  theming and typography. Modes: [topic] (from scratch), from [file] (from
  markdown), --slides N, --theme dark|light|corporate, --outline-only,
  --out [path], --lang [code].
---

# zuvo:presentation — PowerPoint Generator

Generate professional PPTX presentations from a topic description, outline, or existing content file. Uses python-pptx to produce slides with consistent design, speaker notes, and visual variety.

**Requires:** `python-pptx` (`pip install python-pptx`)

**Scope:** Generating slide decks from topics or content files.
**Out of scope:** Editing existing PPTX files, complex data visualizations (charts, graphs), image generation.

## Run Logging

Read `../../shared/includes/run-logger.md` for log format and file path resolution.
Read `../../shared/includes/retrospective.md` for log format and file path resolution.

## Argument Parsing

| Argument | Behavior |
|----------|----------|
| `[topic]` | Plan outline from scratch, generate slides |
| `from [file]` | Build slides from existing markdown or text file |
| `--slides N` | Target slide count (default: 10) |
| `--theme dark\|light\|corporate` | Color theme (default: corporate) |
| `--out [path]` | Output path (default: ./[topic-slug].pptx) |
| `--outline-only` | Generate outline for approval, do not create PPTX |
| `--lang [code]` | Content language (default: same as topic input) |

Examples:

```
zuvo:presentation "Q1 2026 Product Review"
zuvo:presentation from docs/architecture.md --slides 8
zuvo:presentation "Security Audit Results" --outline-only
zuvo:presentation "Quarterly Report" --lang pl --theme dark
```

---

## Phase 1: Content Planning

### 1.1 Determine Source

| Input | Action |
|-------|--------|
| Topic string | Plan outline from scratch (1.2) |
| `from [file]` | Read file, extract sections as slide candidates (1.3) |

### 1.2 Plan from Topic

Generate a structured outline. Each slide needs:

```
Slide [N]: [Type]
  Title: [slide title]
  Content: [bullets or description]
  Speaker notes: [optional context]
```

**Slide types:**

| Type | Use for |
|------|---------|
| TITLE | Opening -- presentation title, subtitle, date |
| SECTION | Section divider -- large title, minimal content |
| CONTENT | Standard -- title + bullet points (max 6 bullets) |
| TWO_COLUMN | Comparison, before/after, pros/cons |
| QUOTE | Key insight, important statement |
| METRICS | Numbers, KPIs, statistics (2-4 big numbers) |
| TIMELINE | Process steps, roadmap, milestones (3-6 items) |
| IMAGE_PLACEHOLDER | Slide with image area + caption (user fills later) |
| SUMMARY | Key takeaways (3-5 points) |
| CLOSING | Thank you, Q&A, contact info |

**Structure rules:**
- Always start with TITLE, always end with SUMMARY + CLOSING
- Max 6 bullets per CONTENT slide, max 15 words per bullet
- Insert a SECTION divider every 4-5 content slides
- Include at least one METRICS or QUOTE slide for visual variety
- Speaker notes carry context that does not belong on the slide itself

### 1.3 Plan from File

Read the source file. Map sections to slides:

| Markdown element | Slide type |
|-----------------|------------|
| `# Heading` | TITLE or SECTION |
| `## Heading` | CONTENT slide title |
| Bullet lists | Slide bullets (split if more than 6) |
| Tables | TWO_COLUMN or METRICS |
| Code blocks | CONTENT with monospace note |
| Blockquotes | QUOTE |

If the file has more than 15 sections and `--slides` is set, merge related sections to fit.

### 1.4 Outline Approval

- `--outline-only`: print outline and STOP
- Interactive environment: print outline, ask `Proceed? (y / edit / n)`
- Non-interactive: proceed automatically

---

## Phase 2: Theme Configuration

### Color Themes

| Theme | Background | Text | Accent | Accent 2 | Subtitle |
|-------|-----------|------|--------|----------|----------|
| light | #FFFFFF | #1A1A2E | #0066CC | #00A86B | #6B7280 |
| dark | #1A1A2E | #F0F0F0 | #4DA6FF | #66D9A5 | #9CA3AF |
| corporate | #FFFFFF | #2D3748 | #1A365D | #C05621 | #718096 |

### Typography

```
Title slides:    Calibri 36pt Bold
Section slides:  Calibri 32pt Bold
Slide titles:    Calibri 28pt Bold
Body text:       Calibri 18pt
Bullets:         Calibri 16pt
Speaker notes:   Calibri 12pt
Metrics:         Calibri 48pt Bold
Quotes:          Calibri 24pt Italic
Captions:        Calibri 11pt (subtitle color)
```

### Layout (16:9 widescreen, inches)

```
Slide: 13.333 x 7.5
Margins: left 0.8, right 0.8, top 1.2 (below title), bottom 0.6
Title Y: 0.4, height 0.8
Content Y: 1.4, width 11.733, height 5.5
Column gap: 0.4 (TWO_COLUMN)
Footer Y: 7.0
```

---

## Phase 3: Generate PPTX

### 3.1 Write Python Script

Generate `scripts/generate_presentation.py` with the planned outline and theme embedded. The script uses python-pptx to build each slide programmatically.

**Script includes:**
- Theme constants (colors, fonts, dimensions)
- Helper functions: `set_slide_bg`, `add_textbox`, `add_bullets`, `add_accent_bar`
- Slide builder functions: one per slide type (build_title_slide, build_content_slide, build_metrics_slide, etc.)
- Main function that creates the presentation and calls builders in sequence

Each builder function receives the specific content for that slide (title, bullets, metrics values, etc.) and applies the theme consistently.

### 3.2 Execute

```bash
python3 scripts/generate_presentation.py
```

Verify:

```bash
ls -la [output_path]
python3 -c "from pptx import Presentation; p = Presentation('[output_path]'); print(f'Slides: {len(p.slides)}')"
```

### 3.3 Cleanup

If user interaction is available, ask whether to keep the script. If not available, keep it (useful for re-generation and manual editing).

---

## Phase 4: Output

### Summary

```
PRESENTATION CREATED
-----
File:   [output_path]
Slides: [N]
Theme:  [theme name]
Size:   [file size]

Slide overview:
  1. [TITLE]       -- [title text]
  2. [CONTENT]     -- [title text]
  3. [METRICS]     -- [title text]
  ...

Script: scripts/generate_presentation.py
Run: <ISO-8601-Z>	presentation	<project>	-	-	<VERDICT>	-	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

`<DURATION>`: use `N-slides` (number of slides generated).

### Post-Generation Tips

```
To modify:
  Edit scripts/generate_presentation.py and re-run
  Add images: open in PowerPoint, replace IMAGE_PLACEHOLDER slides
  Change theme: edit THEME dict in script, re-run
```

---

## Content Quality Rules

1. Max 6 bullets per slide -- split if more
2. Max 15 words per bullet -- concise, not sentences
3. One idea per slide -- if the title needs "and", split it
4. Visual variety -- alternate CONTENT with METRICS, QUOTE, TWO_COLUMN
5. Speaker notes for detail -- put context in notes, not on the slide
6. No walls of text -- shorten any bullet that exceeds 2 rendered lines
7. Consistent language -- match the language of the topic input

---

## Error Handling

| Error | Action |
|-------|--------|
| python-pptx not installed | Print `pip install python-pptx` and stop |
| Output path not writable | Fall back to ./presentation.pptx |
| Script execution fails | Show error, keep script for debugging |
| `from [file]` -- file not found | Print error, ask for correct path |
