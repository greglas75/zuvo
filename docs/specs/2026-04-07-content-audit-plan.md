# Implementation Plan: Content Audit & Fix Skills

**Spec:** docs/specs/2026-04-07-content-audit-spec.md
**spec_id:** 2026-04-07-content-audit-1057
**plan_revision:** 1
**status:** Approved
**Created:** 2026-04-07
**Tasks:** 10
**Estimated complexity:** all standard (markdown files, no code)

## Architecture Summary

All deliverables are markdown files. No TypeScript, Python, or npm dependencies.
The architecture copies the proven `seo-audit` / `seo-fix` pair:

- **Shared registries** (`shared/includes/`) define canonical check slugs and
  fix types — consumed by both audit and fix skills
- **Skill files** (`skills/*/SKILL.md`) define the orchestration workflow
- **Agent files** (`skills/*/agents/*.md`) define per-agent analysis instructions
- **Live-probe protocol** extracted from seo-audit inline rules into shared include

Zero blast radius to existing skills. All new files. Only modifications are
routing table update, skill counts, and seo-audit live-probe extraction.

## Technical Decisions

- **Pattern:** Copy `seo-audit` structure exactly (frontmatter, phases, agent
  dispatch, adversarial review, output schema, run logger)
- **Reference files:** `seo-audit/SKILL.md` (orchestrator), `seo-technical.md`
  (agent pattern), `seo-check-registry.md` (registry pattern),
  `seo-fix-registry.md` (fix registry pattern), `seo-fix/SKILL.md` (fix skill)
- **No new dependencies:** All files are markdown
- **Verification:** Shell script grep tests + `install.sh` + skill load check

## Quality Strategy

- Each file is verified by grepping for required structural elements
  (frontmatter fields, mandatory sections, check slugs, phase headings)
- `install.sh` validates all files copy correctly to all platforms
- Adversarial review validates the final skill output
- Contract consistency: check slugs in registry must match slugs in agent files

## Task Breakdown

### Task 1: Create content-check-registry.md
**Files:** `shared/includes/content-check-registry.md`
**Complexity:** standard
**Dependencies:** none

- [ ] RED: File must contain all 48 check slugs from spec CC1-CC8 in the exact
  table format of `seo-check-registry.md`: columns `check_slug`, `Check`,
  `owner_agent`, `layer`, `enforcement`, `evidence_mode`, `fix_type`. Must have
  dimension headers CC1-CC8 and a Summary table with counts.
- [ ] GREEN: Create `shared/includes/content-check-registry.md` with:
  - Header matching seo-check-registry.md style
  - Semantic notes on seo-audit boundary (what content-audit does NOT check)
  - 8 dimension sections (CC1-CC8) with check tables from spec
  - Summary table: check counts per dimension, total, blocking checks count
  - Template pattern exclusion list (`{...}`, `{{ }}`, `<% %>`)
- [ ] Verify: `grep -c 'check_slug' shared/includes/content-check-registry.md`
  Expected: 8 (one header row per dimension)
  `grep -c '|.*|.*|.*|.*|' shared/includes/content-check-registry.md | head -1`
  Expected: >=56 (48 checks + 8 headers)
- [ ] Acceptance: Spec AC#2 (check slugs from registry), AC#7 (template patterns documented)
- [ ] Commit: `feat: add content-check-registry with 48 checks across CC1-CC8`

### Task 2: Create content-fix-registry.md
**Files:** `shared/includes/content-fix-registry.md`
**Complexity:** standard
**Dependencies:** Task 1

- [ ] RED: File must contain all 5 fix_types from spec (`encoding-strip`,
  `encoding-mojibake`, `markdown-fix`, `artifact-remove`, `typography-fix`)
  with safety classification, ETA, target platforms, expanded fix contracts,
  and validation rules. Must follow `seo-fix-registry.md` structure exactly.
- [ ] GREEN: Create `shared/includes/content-fix-registry.md` with:
  - Fix Inventory table (5 fix_types with safety, ETA)
  - Safety Classification table (per-framework if applicable, else universal)
  - Fix Parameters Schema table
  - Expanded Fix Contracts for each fix_type:
    - `encoding-strip`: NBSP→space, ZWS removal, BOM removal, soft-hyphen
    - `encoding-mojibake`: mojibake signature table (all encodings from spec D5)
    - `markdown-fix`: close unclosed italic, remove orphan `\`, fix split italic
    - `artifact-remove`: Joomla paths, WP shortcodes, PHP tags, legacy HTML, WYSIWYG
    - `typography-fix`: double spaces, double punctuation
  - Confidence scale
- [ ] Verify: `grep -c 'encoding-strip\|encoding-mojibake\|markdown-fix\|artifact-remove\|typography-fix' shared/includes/content-fix-registry.md`
  Expected: >=10 (each appears in inventory + contracts)
- [ ] Acceptance: Spec AC#9 (SAFE vs MODERATE distinction)
- [ ] Commit: `feat: add content-fix-registry with 5 fix types and mojibake patterns`

### Task 3: Extract live-probe-protocol.md from seo-audit
**Files:** `shared/includes/live-probe-protocol.md`, `skills/seo-audit/SKILL.md` (modify)
**Complexity:** standard
**Dependencies:** none

- [ ] RED: New shared include must contain rate limiting rules (2 req/s
  internal, 1 req/s external), pause/halt thresholds (3x429, 3x5xx), user
  consent gate, and GET/HEAD only constraint. seo-audit must reference the
  include instead of inline rules.
- [ ] GREEN:
  - Read seo-audit/SKILL.md, find the inline live-probe rules section
  - Extract to `shared/includes/live-probe-protocol.md` with:
    - Rate limiting table (internal/external)
    - Error threshold escalation (429 pause, 5xx halt)
    - Consent gate (require user confirmation for production URLs)
    - HTTP method restriction (GET/HEAD only)
  - In seo-audit/SKILL.md: replace inline rules with
    `../../shared/includes/live-probe-protocol.md` reference
  - Verify no behavior change — same rules, just extracted
- [ ] Verify: `grep 'live-probe-protocol' skills/seo-audit/SKILL.md`
  Expected: at least 1 match (reference to the shared include)
  `grep '2 req/s' shared/includes/live-probe-protocol.md`
  Expected: 1 match
  Regression check — verify all critical rules exist in shared include:
  `grep -c '429\|5xx\|GET.*HEAD\|1 req/s\|2 req/s' shared/includes/live-probe-protocol.md`
  Expected: >=4 (all rate-limit rules present)
- [ ] Acceptance: Spec D8 (shared live-probe protocol), spec integration points
- [ ] Commit: `refactor: extract live-probe-protocol from seo-audit into shared include`

### Task 4: Create content-audit SKILL.md
**Files:** `skills/content-audit/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1, Task 3

- [ ] RED: Skill file must have: YAML frontmatter (name, description), mandatory
  file loading checklist (8 files from spec), argument parsing table, Phase 0-5
  workflow, agent dispatch instructions, scoring model, report template, run
  logger line. Must follow `seo-audit/SKILL.md` structure.
- [ ] GREEN: Create `skills/content-audit/SKILL.md` with:
  - Frontmatter: name `content-audit`, description from spec
  - Scope / Out of scope (referencing seo-audit boundary)
  - Mandatory File Loading (8 files from spec section)
  - Arguments table (from spec)
  - Phase 0: Discovery (framework detection, content path auto-detection
    cascade, **language detection cascade from spec D4** (5 steps: frontmatter
    lang → directory name → site config → HTML lang attr → fallback unknown),
    file manifest rules, binary skip). Include `--profile <type>` argument.
  - Phase 1: Agent dispatch (3 parallel agents: content-encoding, content-links,
    content-prose — with model, type, input, dimensions)
  - Phase 2: Merge & Score (dedup, dimension scores, grade A/B/C/D, blocking
    gate cap)
  - Phase 3: Adversarial review (`--mode audit`)
  - Phase 4: Report (markdown + JSON output, templates)
  - Phase 5: Backlog (optional `--persist-backlog`)
  - Edge case handling table from spec
  - `--quick` mode definition (grep-only, skip CC4/CC7/CC8)
  - Run log line template
- [ ] Verify: `grep -c 'Phase' skills/content-audit/SKILL.md`
  Expected: >=6
  `grep 'content-check-registry' skills/content-audit/SKILL.md`
  Expected: 1+ matches
- [ ] Acceptance: Spec AC#2 (finding format), AC#3 (JSON schema), AC#4 (report path), AC#5 (--quick mode), AC#6 (--live-url), AC#8 (binary skip). Agent-level ACs (#1, #7) owned by Tasks 5-7.
- [ ] Commit: `feat: add content-audit skill — 8 dimensions, 48 checks, 3 agents`

### Task 5: Create content-encoding agent
**Files:** `skills/content-audit/agents/content-encoding.md`
**Complexity:** standard
**Dependencies:** Task 1, Task 4

- [ ] RED: Agent file must have: YAML frontmatter (name, model: sonnet, tools),
  dimensions CC1+CC2+CC3, check tables with grep patterns for each check,
  search strategies (CodeSift + fallback), finding output format.
- [ ] GREEN: Create `skills/content-audit/agents/content-encoding.md` with:
  - Frontmatter: model sonnet, tools Read/Grep/Glob
  - CC1 Encoding Quality: grep patterns for NBSP (`\xC2\xA0`), ZWS
    (`\u200B`), BOM, mojibake signatures table (full table from spec D5
    covering Latin-1, Windows-1252, ISO-8859-2, ISO-8859-9), replacement char,
    soft hyphens. `file -i` for encoding detection.
  - CC2 Markdown Syntax: regex patterns for unclosed `*`/`_`, split italic,
    orphan `\`, unclosed code blocks, malformed links/images, unlabeled code
    blocks. Stack-aware `\` handling (Hugo vs GFM).
  - CC3 Migration Artifacts: regex patterns for Joomla paths, WP shortcodes,
    PHP tags, legacy HTML, WYSIWYG inline styles, template unexpanded,
    CMS internal URLs.
  - Template syntax exclusion rules (strip `{...}`, `{{ }}`, `<% %>`)
  - Finding output format matching audit-output-schema.md
- [ ] Verify: `grep -c 'check_slug\|Ä…\|Ã³\|encoding' skills/content-audit/agents/content-encoding.md`
  Expected: >=10
- [ ] Acceptance: Spec AC#1 (NBSP, ZWS, broken italic, mojibake), AC#7 (template stripping), Should-have#3 (mojibake encodings)
- [ ] Commit: `feat: add content-encoding agent — CC1 encoding, CC2 markdown, CC3 artifacts`

### Task 6: Create content-links agent
**Files:** `skills/content-audit/agents/content-links.md`
**Complexity:** standard
**Dependencies:** Task 1, Task 3, Task 4

- [ ] RED: Agent file must have: CC5 image integrity checks with path resolution
  logic, CC6 link integrity checks with anchor validation, live-probe reference,
  finding output format.
- [ ] GREEN: Create `skills/content-audit/agents/content-links.md` with:
  - Frontmatter: model sonnet, tools Read/Grep/Glob
  - CC5 Image Integrity: extract `![alt](path)` and `<img src=` patterns,
    resolve relative paths via Glob, framework-relative path handling
    (`@/`, `~/` → POTENTIAL_RISK), alt text quality check (filename-as-alt,
    single word, non-descriptive), file size check, spaces in paths.
    Live mode: HTTP HEAD for 404 check.
  - CC6 Link Integrity: extract `[text](path)` and `href=` patterns,
    resolve internal links against file tree, anchor validation (extract
    headings from target file, normalize to IDs, compare with fragment),
    live mode for external links (rate limited per live-probe-protocol),
    redirect chain detection, mailto validation, empty href detection.
  - Reference to `live-probe-protocol.md` for rate limiting
  - Finding output format
- [ ] Verify: `grep -c 'img-path-broken\|link-internal-broken\|link-anchor-broken' skills/content-audit/agents/content-links.md`
  Expected: >=3
- [ ] Acceptance: Spec AC#1 (broken image paths), AC#6 (live-url), Edge-case#4 (anchor validation)
- [ ] Commit: `feat: add content-links agent — CC5 images, CC6 links, anchor validation`

### Task 7: Create content-prose agent
**Files:** `skills/content-audit/agents/content-prose.md`
**Complexity:** standard
**Dependencies:** Task 1, Task 4

- [ ] RED: Agent file must have: CC4 frontmatter quality checks, CC7 content
  completeness checks, CC8 spelling/typography checks, language detection
  reference, finding output format.
- [ ] GREEN: Create `skills/content-audit/agents/content-prose.md` with:
  - Frontmatter: model sonnet, tools Read/Grep/Glob
  - CC4 Frontmatter Quality: YAML parsing, required fields check (title,
    description, date), empty values, future dates, encoding artifacts in
    frontmatter strings. Template expression stripping for YAML values.
    Note: fm-title-missing and fm-description-missing are advisory (seo-audit
    owns SEO effectiveness).
  - CC7 Content Completeness: empty files (frontmatter-only), draft files
    committed, duplicate paragraph detection (LLM-judged, capped at 50
    files), orphan files (not linked from nav/content), stale content
    (>2 years with no git modification).
  - CC8 Spelling & Typography: diacritics corruption for detected language,
    double spaces (outside code blocks), double punctuation, optional
    aspell/hunspell integration (capability-gated), inconsistent quotes.
    Language detection cascade reference.
  - Finding output format
- [ ] Verify: `grep -c 'fm-yaml-malformed\|content-empty\|typo-diacritics' skills/content-audit/agents/content-prose.md`
  Expected: >=3
- [ ] Acceptance: Should-have#1 (language detection), Should-have#2 (frontmatter encoding), Should-have#4 (duplicate bounded)
- [ ] Commit: `feat: add content-prose agent — CC4 frontmatter, CC7 completeness, CC8 spelling`

### Task 8: Create content-fix SKILL.md
**Files:** `skills/content-fix/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1, Task 2

- [ ] RED: Skill file must have: YAML frontmatter, mandatory file loading (7
  files), arguments table, safety gates (3 gates), Phase 0-5 workflow,
  fix application logic per fix_type, build verification, adversarial review,
  report template, output naming convention, run logger.
- [ ] GREEN: Create `skills/content-fix/SKILL.md` following `seo-fix/SKILL.md`
  pattern with:
  - Frontmatter: name `content-fix`, description from spec
  - Mandatory File Loading (7 files from spec)
  - Safety Gates (GATE 1 write scope, GATE 2 dirty file, GATE 3 stale audit)
  - Arguments table (default, --auto, --dry-run, --finding, --fix-type, json-path)
  - Phase 0: Load findings (locate JSON, validate schema, check freshness)
  - Phase 1: Detect framework & classify fixes by safety tier
  - Phase 2: Apply fixes:
    - SAFE auto-applied: encoding-strip, markdown-fix, typography-fix
    - MODERATE with --auto: encoding-mojibake, artifact-remove
    - MANUAL: never auto-applied, advisory output only
  - Phase 3: Build verification
  - Phase 4: Adversarial review (`--mode code` on diff)
  - Phase 5: Report + backlog update
  - Output: `audit-results/content-fix-YYYY-MM-DD.{md,json}`
  - Run log line
- [ ] Verify: `grep -c 'Phase' skills/content-fix/SKILL.md`
  Expected: >=6
  `grep 'encoding-strip\|encoding-mojibake' skills/content-fix/SKILL.md`
  Expected: >=2
- [ ] Acceptance: Spec AC#9 (SAFE without confirmation, MODERATE with --auto), AC#10 (build verification)
- [ ] Commit: `feat: add content-fix skill — 5 fix types, safety gates, build verification`

### Task 9: Update routing, counts, and metadata
**Files:** `skills/using-zuvo/SKILL.md`, `docs/skills.md`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `package.json`
**Complexity:** standard
**Dependencies:** Task 4, Task 8

- [ ] RED: using-zuvo routing table must include `content-audit` and
  `content-fix`. Skill counts must be 41 everywhere. Version banner must
  say 41 skills.
- [ ] GREEN:
  - `skills/using-zuvo/SKILL.md`:
    - Update version banner: `39 skills` → `41 skills`
    - Add to Priority 3 Audit table: `| Audit content quality (encoding, links, formatting) | \`zuvo:content-audit\` |`
    - Add to Priority 2 Task table: `| Fix content audit findings | \`zuvo:content-fix\` |`
  - `docs/skills.md`:
    - Update header: `39 skills` → `41 skills`
    - Add content-audit and content-fix rows to appropriate category table
    - Update category count table
  - `.claude-plugin/plugin.json`: Update description `39 skills` → `41 skills`
  - `.codex-plugin/plugin.json`: Same update
  - `package.json`: No skill count in this file (version only), skip
- [ ] Verify: `grep -r '41 skills' skills/using-zuvo/SKILL.md docs/skills.md .claude-plugin/plugin.json .codex-plugin/plugin.json`
  Expected: 4 matches (one per file)
  `grep 'content-audit' skills/using-zuvo/SKILL.md`
  Expected: 1+ matches
- [ ] Acceptance: Spec integration points (routing, counts)
- [ ] Commit: `feat: register content-audit + content-fix — 41 skills total`

### Task 10: Install, verify, and commit
**Files:** none (verification only)
**Complexity:** standard
**Dependencies:** Task 1-9

- [ ] RED: `install.sh` must complete without errors. All 41 skills must be
  listed. content-audit and content-fix must appear in cache directories.
- [ ] GREEN:
  - Run `./scripts/install.sh`
  - Verify output shows 41 skills for Claude Code, Codex, Cursor
  - Verify content-audit and content-fix files exist in cache
  - Run any existing seo-audit contract tests to confirm no regression
    from live-probe extraction
- [ ] Verify: `./scripts/install.sh 2>&1 | grep '41 skills'`
  Expected: 3 matches (Claude Code, Codex, Cursor)
  `ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/skills/content-audit/SKILL.md`
  Expected: file exists
- [ ] Acceptance: All spec acceptance criteria verified end-to-end
- [ ] Commit: (no commit — verification only, prior tasks already committed)
