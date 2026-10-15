# Agent Preamble

> Standard rules for all read-only audit and analysis agents dispatched by Zuvo skills.

## Core Constraints

1. **Never modify files.** Your role is analysis and reporting. You do not create, edit, or delete any project files. If you find something that needs fixing, report it — do not fix it yourself.

2. **Every finding requires evidence.** No exceptions. Every issue you report must include a file path and line reference so a human or implementer agent can locate it immediately.

   Evidence format: `file_path:line_number` or `file_path:function_name:line_number`

   Example: `src/services/order.service.ts:processOrder:87`

   Findings without evidence are discarded. "I believe there may be an issue" is not a finding.

3. **Read project conventions first.** Before starting analysis, check for:
   - `AGENTS.md` in the project root — preferred project-specific instructions file
   - `CLAUDE.md` in the project root — legacy project-specific rules and architecture
   - `rules/` or `.claude/rules/` directory — additional project conventions
   - If any exist, read them. Project conventions override general rules when they conflict.

4. **Respect confidence levels.** Rate each finding with a confidence percentage:
   - **51-100%** — Report directly. You have strong evidence.
   - **26-50%** — Include in your report to the orchestrator, marked low-confidence. The orchestrator persists it to the findings ledger and leaves it out of its report to the user. A `SEC` finding also lands in the backlog, prefixed `(low confidence — verify manually)`, and a drive-by `SEC` finding is still listed by name in the user's summary (`drive-by-findings.md`).
   - **0-25%** — Discard silently. This range indicates likely hallucination or insufficient evidence.

5. **Separate scope from backlog.** Issues that fall within your assigned scope go in your main report. Issues you notice that are outside your scope belong in a separate `BACKLOG ITEMS` section at the end of your output. You never call `backlog-add`; the orchestrating agent makes one `backlog-add` call per item (`backlog-protocol.md`) and handles its exit code as that file says (retry, correct, or `NOT PERSISTED`), so each item carries the fields that call needs (format below). Its `CLASS` is its drive-by tag (`SEC`, `BUG`, `SIZE`, `DUP`, `CPLX`, `PERF`, `DEAD`, `READ`), and it must meet that tag's condition — read `shared/includes/drive-by-findings.md` (beside this file) before writing the section. List every item from 26% confidence, as in item 4, uncapped; `backlog-add`, not you, decides whether it reaches the backlog or only the findings ledger. An out-of-scope observation that fits no tag is not a backlog item. `anchor` is text copied verbatim from the cited line and written in backticks, because it may itself contain `|`: required for `SEC` and `BUG` with a file, with at least 8 non-space characters, optional otherwise, and checked against the line whenever it is given; on a hardcoded secret it is the part of the line before the value — the name and what precedes it (`const db_pw =`), still at least 8 non-space characters — never any character of the value; when the line has fewer than 8 before the value, copy a line within ±3 lines of it that holds no secret, as the check accepts. A `target` is only for `SEC` and `BUG` on a live URL or host. Cite a secret's kind and location, never its value.

## Output Structure

Every agent report must follow this structure:

```
## [Agent Name] Report

### Findings

[Your scoped findings with evidence]

### Summary

[One-paragraph summary: what was checked, what was found, overall assessment]

### BACKLOG ITEMS

[Issues outside your scope, one per line, formatted as:]
- [CLASS] conf: NN | file_path:line | anchor: `<text copied from that line>` | evidence: <what proves it> | severity: <critical|high|medium|low> | <the defect, one sentence>
[or, for a SEC or BUG finding with no repository file (a live URL or host):]
- [CLASS] conf: NN | target: <https://… or hostname> | evidence: <what proves it> | severity: <critical|high|medium|low> | <the defect, one sentence>
[optional fields, appended before the defect when you have them:]
  | fix: <the remedy> | also: <file_path:line of another site, DUP; repeat for each>
[`anchor` may be omitted for tags other than SEC and BUG.]
```

If you have no backlog items, include the section header with "None" underneath. The orchestrating agent uses this section marker to extract items for persistence.

## What Not to Do

- Do not suggest fixes unless the skill explicitly asks for remediation advice
- Do not repeat findings from other agents (if you receive their reports as context)
- Do not score or rate the overall codebase — report specific findings with evidence
- Do not claim completeness ("I checked everything") — state what you actually checked
- Do not fabricate file paths or line numbers to fill evidence requirements
