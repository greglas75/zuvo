# Retrospective Protocol

> Shared include — structured agent reflection after execution skill completion.

## Gate Check

```
ALWAYS write the retrospective. The only exception is if you literally did
nothing (e.g., skill aborted immediately, or you ran 1-2 tool calls total).

Do NOT skip because the file was "simple" or the tier was THIN — simple files
often have the most interesting friction (mock strategy, missing templates).
If you have ANY insight about the skill, the tools, or the process — write it.

IF you used more than ~200 tool calls in this session:
  SET degraded_context = true (cap each answer to 2 sentences below)
```

**Do not summarize what you did. Reflect on the experience of doing it.** Status reports are not retrospectives. Each answer must reference a specific moment of friction or insight during the task, not a property of the final artifact.

## Structured Questions

Fill these sections. Fields 1-4: at least 1 must be non-empty and artifact-grounded. Fields 5-9: always required.

### Part A: Friction (at least 1 of fields 1-4 non-empty)

| # | Field | Prompt | Grounding |
|---|-------|--------|-----------|
| 1 | `unclear` | What instruction or section in the skill did you have to interpret or guess? | Must reference a phase number, section name, or include file |
| 2 | `missing_context` | What information did you need but had to discover yourself? | Must reference a file path, framework behavior, or dependency |
| 3 | `most_turns` | Which sub-task consumed the most iterations? What would have prevented it? | Must include a count (turns, attempts, or minutes) |
| 4 | `missing_template` | What code pattern did you need but had to invent from scratch? | Must include the pattern name or a 1-line description |

### Part B: Infrastructure Status (always required)

| # | Field | Fill with |
|---|-------|-----------|
| 5 | `infra_status` | Telemetry block (see template below). Every line is mandatory — write `N/A` or `skipped` for lines that don't apply, never omit a line. |

Telemetry block template (key=value, one per line):
```
platform: <claude|codex|antigravity|cursor> | writer: <model> | reviewer: <model> | routing: <ok|same-model-fallback|unknown-writer-model|routing-failed>
codesift: <indexed(Nsymbols)|not_indexed|transport_closed_after_N|unavailable|N/A>
paths: shared=<ok|missing:file> scripts=<ok|missing:file> rules=<ok|missing:file>
extension_check: <ok|.test.ts->.spec.ts(renamed)|N/A>
blind_audit: <clean:strict|clean:degraded|fix:N|rewrite|skipped|blocked_infra> | provider=<name> | exit=<code> | rows=<N> | FULL=<N> PARTIAL=<N> NONE=<N>
adversarial: pass1=<provider>(NC,NW,NI) [pass2=<provider>(NC,NW,NI)] | cross_provider=<true|false|single_provider> | timeout=<Ns>
q_gates: <N>/19 (Q7=<0|1> Q11=<0|1> Q13=<0|1> Q15=<0|1> Q17=<0|1>)
tests: <N>/<N> pass | extension=<.spec.ts|.test.ts>
status: <PASS|FAILED|BLOCKED_INFRA> | failure_cause=<none|blind-audit-timeout|prod-bug|...>
```

### Part C: Gaps and Proposals (always required)

| # | Field | Fill with |
|---|-------|-----------|
| 6 | `skill_gaps` | Bullet list: what was missing or broken in the skill/includes. Each must name a file or section. |
| 7 | `missing_tools` | Bullet list: what tools/scripts would have helped but don't exist. |
| 8 | `worked_well` | What in the skill saved you time or prevented mistakes? May reference specific include, phase, or template. |
| 9 | `change_proposals` | Write up to 5 proposals. Categories: token waste, missing templates, pipeline overhead, false positive rules, missing patterns, include loading, adversarial tuning, gate applicability, infrastructure. Each: `FILE: / SECTION: / CONTENT:` with paste-ready code. Include ranking table. |

**Structural grounding check:** Each non-empty answer in fields 1-4 MUST contain at least one of: a file path with extension (e.g., `app.ts`), a phase/step number (e.g., `Phase 3`), or a numeric count (e.g., `6 turns`). Answers without any of these tokens are treated as empty.

**CRITICAL: Printing answers is NOT enough.** After filling fields 1-9 above, you MUST execute the bash commands in the Append Commands section below to write data to `~/.zuvo/retros.log` and `~/.zuvo/retros.md`. If you skip the bash append, the retrospective is lost. The retro is not done until both files are written.

## TSV Emit

After filling the structured questions, emit a `RETRO:` line and append to the retro log.

### Field Resolution

```bash
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
BRANCH=$(git branch --show-current 2>/dev/null || echo "-")
SHA7=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

### TSV Format (17 fields, tab-separated)

```
RETRO: DATE\tSKILL\tPROJECT\tCODE_TYPE\tFRICTION_CATEGORY\tMISSING_TEMPLATE\tCONTEXT_GAP\tTURNS_WASTED\tTOOL_CALLS\tFILES_READ\tFILES_MODIFIED\tBRANCH\tSHA7\tBLIND_AUDIT\tADVERSARIAL\tCODESIFT\tROUTING_STATUS
```

| # | Field | Type | Values |
|---|-------|------|--------|
| 1 | DATE | ISO 8601 UTC | `2026-04-09T13:45:00Z` |
| 2 | SKILL | string | skill name without `zuvo:` prefix |
| 3 | PROJECT | string | basename of git root |
| 4 | CODE_TYPE | enum | `ORCHESTRATOR`, `DATA_SERVICE`, `PURE_FUNCTION`, `UI_COMPONENT`, `CONFIG`, `MIXED`, `OTHER` |
| 5 | FRICTION_CATEGORY | enum | `mock-strategy`, `ordering-template`, `context-missing`, `pipeline-heavy`, `framework-gotcha`, `unclear-instruction`, `skill-overhead`, `missing-pattern`, `false-positive-rule`, `scope-mismatch`, `infra-failure`, `abandoned`, `context-out`, `partial-recovery`, `no-friction`, `other`. **`no-friction` is ONLY valid if you have ZERO change proposals.** The last three (`abandoned`/`context-out`/`partial-recovery`) are **checkpoint-stub** values — see Checkpoint Stub Schema below. |
| 6 | MISSING_TEMPLATE | string (40 char max) | short description or `-` |
| 7 | CONTEXT_GAP | enum | `no-production-code`, `no-schema`, `no-env`, `no-test-fixture`, `no-framework-docs`, `none`, `other` |
| 8 | TURNS_WASTED | integer | Count retries, re-reads, false-positive deliberation, missing pattern invention, infra waits |
| 9 | TOOL_CALLS | integer | total tool calls in session (estimate) |
| 10 | FILES_READ | integer | distinct files read |
| 11 | FILES_MODIFIED | integer | files created or edited (include backlog, coverage, ALL touched files) |
| 12 | BRANCH | string | current git branch |
| 13 | SHA7 | string | short commit hash |
| 14 | BLIND_AUDIT | enum | `clean:strict`, `clean:degraded`, `fix:N`, `rewrite`, `skipped`, `blocked_infra`, `not_run` |
| 15 | ADVERSARIAL | enum | `clean`, `Nfindings`, `skipped`, `blocked`, `not_run`, `blocked:prod-bug` |
| 16 | CODESIFT | enum | `indexed`, `transport_closed`, `not_indexed`, `unavailable`, `N/A` |
| 17 | ROUTING_STATUS | enum | `ok`, `same-model-fallback`, `unknown-writer-model`, `routing-failed`, `N/A` |

### Canonical Full-Retro Predicate (single source of truth)

**Full retro** iff line starts `RETRO:` AND field 5 (FRICTION_CATEGORY) ∉
`{abandoned, context-out, partial-recovery}`; field 5 **in** that set ⇒
**checkpoint stub** (telemetry only). The `append-runlog` gate, `retro-stub`
idempotency, and `--sweep` all use exactly this predicate; the gate is satisfied
**only by a full retro** (an incomplete run never reaches the gate, so a stub
never gates). Coherence ("one session ⇒ one eventual retro") is enforced at
**WRITE time** by session-state `retro-session-id` (session-state.md Retro
State / plan Task 6) — it suppresses the duplicate before it is written, since
`retro-session-id` is **not** one of the 17 logged fields. Post-hoc dedup of
`retros.log` therefore keys only on in-line **SKILL+PROJECT+SHA7** (sufficient:
Task 6 already prevents the resume duplicate at write time; do NOT key on DATE
— midnight rollover). A later full retro supersedes a stub of the same key.

### Checkpoint Stub Schema

`retro-stub` emits this before the terminal retro on abandon/pause/context-out:
a 17-field `RETRO:` line, **every field enum-valid** (strict parsers must not
choke). Field 5 = `abandoned`/`context-out`/`partial-recovery`
(`ABANDONED`/`CONTEXT_OUT`/`PARTIAL`). Integer cols
(`TURNS_WASTED/TOOL_CALLS/FILES_*`) carry the **best-known count at interrupt**
(emitter passes real figures — a 50-turn abandon logs 50, never destructive
`0`; `0` only if truly unknown). Other unknown fields take their column's
**valid neutral**: `CODE_TYPE=OTHER`, `MISSING_TEMPLATE=-` (string; `-` ok),
`CONTEXT_GAP=none`, `BLIND_AUDIT=not_run`, `ADVERSARIAL=not_run`, `CODESIFT=N/A`
(`skipped` is NOT a CODESIFT value), `ROUTING_STATUS=N/A`. A later full retro
(same `retro-session-id`) supersedes the stub. SKILL/PROJECT/BRANCH/SHA7/DATE
populated so the predicate works.

## Markdown Emit

Append a section to the retro markdown file using this exact template:

```markdown
<!-- RETRO -->

## [DATE] [SKILL] [PROJECT] [TARGET_FILE]

### Telemetry
```
platform: ... | writer: ... | reviewer: ... | routing: ...
codesift: ...
paths: shared=... scripts=... rules=...
extension_check: ...
blind_audit: ... | provider=... | exit=... | rows=... | FULL=... PARTIAL=... NONE=...
adversarial: ... | cross_provider=... | timeout=...
q_gates: .../19 (Q7=... Q11=... Q13=... Q15=... Q17=...)
tests: .../... pass | extension=...
status: ... | failure_cause=...
```

### Friction
- **Unclear:** [field 1, or N/A]
- **Missing context:** [field 2, or N/A]
- **Most turns:** [field 3, or N/A]
- **Missing template:** [field 4, or N/A]

### Skill Gaps
- [bullet per gap — name the file/section that's missing or broken]

### Missing Tools
- [bullet per tool — what would have helped but doesn't exist]

### Worked Well
[field 8]

### Session Cost
- **Files read:** N
- **Files modified:** N
- **Tool calls:** N total (Read: N, Edit: N, Bash: N, ...)
- **Test runs:** N (pass: N, fail: N)
- **Adversarial passes:** N
- **Biggest waste:** [what consumed the most tokens/time for the least value]

### Change Proposals (ranked by impact, up to 5)

**1.** FILE: [path] | SECTION: [where]
CONTENT:
```
[paste-ready code or markdown to add]
```
RATIONALE: [which problem from above it solves]

(continue up to 5)

**Impact ranking:**

| # | Change | Token savings | Quality impact |
|---|--------|---------------|----------------|
| 1 | [short label] | ~NK/session | high/medium/low |
| 2 | ... | ... | ... |
```

If `degraded_context = true`, prefix the H2 header with `[DEGRADED-CONTEXT]` and cap each answer to 2 sentences.

## Append Commands

**Execute all bash variables and commands below in a single shell invocation.** Variables from Path Detection and Field Resolution must be available to the Append blocks.

### Path Detection

```bash
if [ -n "$CODEX_WORKSPACE" ] || ! mkdir -p ~/.zuvo 2>/dev/null || ! test -w ~/.zuvo; then
  RETRO_LOG="memory/zuvo-retros.log"
  RETRO_MD="memory/zuvo-retros.md"
else
  RETRO_LOG="$HOME/.zuvo/retros.log"
  RETRO_MD="$HOME/.zuvo/retros.md"
fi
```

### TSV Append + Rotation

```bash
# Create header if file doesn't exist (v2 schema: RETRO: prefix + 17 TSV fields).
# NOTE: the on-disk header includes a `RETRO:` token in column 1 because every
# data row begins with `RETRO:` followed by 16 TSV fields → 17 total columns
# (the `RETRO: ` prefix on the timestamp counts as field 1 of the awk parse).
if [ ! -f "$RETRO_LOG" ]; then
  echo "# v2-17col RETRO: DATE	SKILL	PROJECT	CODE_TYPE	FRICTION_CATEGORY	MISSING_TEMPLATE	CONTEXT_GAP	TURNS_WASTED	TOOL_CALLS	FILES_READ	FILES_MODIFIED	BRANCH	SHA7	BLIND_AUDIT	ADVERSARIAL	CODESIFT	ROUTING_STATUS" > "$RETRO_LOG"
fi

# === VALIDATION (added 2026-05-28 to close OPT-1 corruption gap) ===
# Reject malformed RETRO: lines BEFORE they hit retros.log. Historical
# contamination came from skills appending free-form notes or partial-column
# lines that the append-runlog gate then silently ignored (awk NF==17
# predicate matched nothing → looked like "no retro" → retro-gate failures).
# This validator catches the four observed failure modes:
#   1. Line not starting with `RETRO:`
#   2. NF != 17 (column count drift)
#   3. Empty SKILL ($2) or empty PROJECT ($3)
#   4. Embedded newlines (multi-line accidentally collapsed)
# Reject = print error to stderr + exit 2 (caller propagates the failure;
# the retro is NOT written; the next append-runlog will demand a clean retry).
RETRO_LINE="<tsv-line>"
if ! printf '%s' "$RETRO_LINE" | awk -F'\t' '
  BEGIN { ok=1 }
  NR>1 { print "validator: embedded newline in RETRO line — multi-line collapse?" > "/dev/stderr"; ok=0; exit }
  $1 !~ /^RETRO: / { print "validator: line does not start with `RETRO: ` prefix — refusing append" > "/dev/stderr"; ok=0 }
  NF != 17 { printf "validator: RETRO line has %d TSV fields, schema requires 17 (v2-17col)\n", NF > "/dev/stderr"; ok=0 }
  $2 == "" { print "validator: SKILL field (col 2) is empty" > "/dev/stderr"; ok=0 }
  $3 == "" { print "validator: PROJECT field (col 3) is empty" > "/dev/stderr"; ok=0 }
  END { exit (ok ? 0 : 2) }
'; then
  echo "RETRO_REJECTED: malformed line not appended to $RETRO_LOG" >&2
  echo "  Line: $RETRO_LINE" >&2
  echo "  Fix the field generation above, then re-run this Append block." >&2
  exit 2
fi

# Append the validated RETRO: line
echo "$RETRO_LINE" >> "$RETRO_LOG"

# Rotation: preserve header, keep last 100 data lines
LINE_COUNT=$(wc -l < "$RETRO_LOG")
if [ "$LINE_COUNT" -gt 101 ]; then
  head -1 "$RETRO_LOG" > "$RETRO_LOG.tmp.$$"
  tail -n 100 "$RETRO_LOG" >> "$RETRO_LOG.tmp.$$"
  mv "$RETRO_LOG.tmp.$$" "$RETRO_LOG"
fi
```

### Markdown Append + Rotation

```bash
# Append the markdown block (fill from the template above)
cat >> "$RETRO_MD" << 'RETRO_EOF'
<!-- RETRO -->

## ...filled template...
RETRO_EOF

# Hard cap (safety net): keep last 100 entries inline. Triggered only when
# rotate-retros has not been run recently — the canonical archival path is the
# date-based ~/.zuvo/rotate-retros helper (see Rotation Strategy below).
ENTRY_COUNT=$(grep -c '^<!-- RETRO -->' "$RETRO_MD" 2>/dev/null || echo 0)
if [ "$ENTRY_COUNT" -gt 100 ]; then
  awk '/^<!-- RETRO -->/{c++} c>=('"$ENTRY_COUNT"'-99){print}' "$RETRO_MD" > "$RETRO_MD.tmp.$$" && mv "$RETRO_MD.tmp.$$" "$RETRO_MD"
fi
```

### Rotation Strategy (added 2026-05-28 alongside OPT-4/OPT-5)

The inline cap above is a safety net — it preserves last-100 in a single file but discards anything older permanently. For real archival, use the dedicated helper installed by `scripts/install.sh`:

```bash
~/.zuvo/rotate-retros                    # dry-run (default; reports what would move)
~/.zuvo/rotate-retros --apply            # move entries older than 90 days to per-quarter archives
~/.zuvo/rotate-retros --apply --days 60  # custom threshold
```

Behavior: groups `<!-- RETRO -->` entries by quarter of their parsed ISO date and appends them to `~/.zuvo/retros-archive-YYYY-QN.md`, leaving only recent entries in `retros.md`. Idempotent — safe to re-run (each invocation adds a rotated-on marker). Entries without parseable dates are kept in place (never silently archived). The pre-rotation file is preserved as `retros.md.pre-rotate.<pid>` until the user verifies and deletes.

Run manually after multi-week sessions, or hook into a periodic schedule (e.g. zuvo:schedule). The retros.log file has its own count-based rotation built into the TSV Append block above and does not need this helper.

## Enforcement Rules

- At least 1 of fields 1-4 must have a non-empty, structurally grounded answer (contains file path, phase number, or numeric count)
- Field 5 (infra_status) telemetry block is always required — every line filled, `N/A` for non-applicable
- Field 6 (skill_gaps) is always required — at least 1 bullet or explicit "none found"
- Field 7 (missing_tools) is always required — at least 1 bullet or explicit "none needed"
- Field 9 (change_proposals) is always required — at least 1, up to 5, ranked by impact. Each must use `FILE: / SECTION: / CONTENT: / RATIONALE:` format
- No code snippets or user data values in any field — only file paths, error types, phase numbers, and structured signals

## Skill-Specific Gates

### ship — review-downgrade auto-friction

If the calling skill is `ship` AND the recorded `Review:` depth in `SHIP COMPLETE` is lower than the threshold table required for the computed `DIFF_LOC` (e.g., DIFF_LOC=4500 but Review depth was `light` or `none`, without `--fast` having been passed by the user), then the retrospective MUST:

1. Set `friction_category = skipped-review-rationalization` in the TSV line.
2. Field 1 (`unclear`) MUST contain at least one full sentence naming the exact rationalization that drove the downgrade (e.g., "Skipped Phase 2 full review at DIFF_LOC=4500 because each Tier 6/7/8 was reviewed during creation — violates ship Safety Rule 6"). Reference Phase 2 of `skills/ship/SKILL.md`.
3. Field 9 MUST include at least one Change Proposal targeting `skills/ship/SKILL.md` Phase 2 with a concrete tightening — generic "be more careful next time" entries do not satisfy this gate.

This gate exists because the agent that just shortcut the review is the same agent writing the retro, and absent forcing the entry will be omitted via the same rationalization that caused the shortcut.

## Postamble: Forced Evidence (REQUIRED)

**Printing the markdown emit and the TSV emit is NOT the retrospective. The retrospective is the file write.** After filling fields 1-9 and printing the markdown section, you MUST execute the Append Commands above as actual `Bash` tool calls, then print the postamble below with REAL stdout from `tail`. Pasting fabricated output is a falsification — it will be flagged by the next `zuvo:context-audit` run because the file mtime will not match.

```
RETRO POSTAMBLE
$ tail -1 ~/.zuvo/retros.log
<paste actual last line — must contain the DATE you set in Field Resolution>
$ grep -c '^<!-- RETRO -->' ~/.zuvo/retros.md
<paste integer count — must be ≥1 and incremented by 1 from session start>
$ stat -f '%Sm' ~/.zuvo/retros.md 2>/dev/null || stat -c '%y' ~/.zuvo/retros.md 2>/dev/null
<paste mtime — must be within the last few minutes of session wall clock>
```

If any of the three commands errors, the retrospective was not appended — re-execute the Append Commands block. Do not proceed to `append-runlog` until the postamble shows real output. The `append-runlog` wrapper will refuse the runs.log write anyway if `retros.log` lacks a matching SKILL+PROJECT entry, so skipping the postamble only delays the failure.
