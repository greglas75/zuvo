# Backlog Persistence Protocol

> How Zuvo skills persist findings, track tech debt, and manage the project backlog.

## Where the Backlog Lives

The backlog file is at `memory/backlog.md` under the **MAIN checkout root** — never inside a linked worktree. There is exactly ONE backlog per repository.

**Resolution (MANDATORY — worktree-safe):**

```bash
# Main-checkout root: first entry of `git worktree list` is ALWAYS the main worktree,
# even when CWD is a linked worktree. `--show-toplevel` alone is WRONG here — in a
# worktree it returns the worktree root and forks the backlog (field incident 2026-07-19:
# 17 diverged copies per repo).
MAIN_ROOT=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
[ -z "$MAIN_ROOT" ] && MAIN_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BACKLOG="$MAIN_ROOT/memory/backlog.md"
```

If `$MAIN_ROOT/memory/backlog.md` does not exist, create it with the template below. If you are in a linked worktree and a **local** `memory/backlog.md` exists there (legacy fork), do NOT write to it — write to the main copy; migrate any entries the local fork has that the main copy lacks (dedupe by Fingerprint), then note the migration in the run output.

This main-checkout anchor applies to the whole durable project-state family: `memory/backlog.md`, `memory/ideas.md`, `knowledge/*.jsonl`. Per-run pipeline state (`zuvo/plans`, `zuvo/contracts`, `zuvo/context`) stays worktree-local by design.

## Backlog Table Format

```markdown
# Tech Debt Backlog

| ID | Status | Fingerprint | File | Problem | Severity | Category | Source | Seen | Added |
|----|--------|-------------|------|---------|----------|----------|--------|------|-------|
| B-1 | OPEN | order.service.ts|CQ8|no-try-catch | order.service.ts:45 | Missing error handling on payment call | high | CQ | zuvo:review | 1 | 2026-03-27 |
```

Column definitions:
- **ID**: Sequential `B-{N}` identifier
- **Status**: `OPEN` or `RESOLVED`
- **Fingerprint**: `file|rule-id|signature` — used for deduplication
- **File**: File path with line number
- **Problem**: One-line description of the issue
- **Severity**: `critical`, `high`, `medium`, `low`
- **Category**: Rule family (CQ, Q, S, SA, DB, etc.)
- **Source**: Which skill or agent produced this finding
- **Seen**: How many times this finding has been observed
- **Added**: Date first recorded

## How to Persist Findings

For each finding that should be tracked:

1. **Compute the fingerprint**: `file_name|rule_id|short_signature`
   - `file_name`: Just the filename, not full path (e.g., `order.service.ts`)
   - `rule_id`: The gate or rule that was violated (e.g., `CQ8`, `Q11`, `S3`)
   - `short_signature`: 2-4 word description of the specific issue (e.g., `no-try-catch`, `missing-orgid-filter`)

2. **Check for duplicates**: Search the existing `Fingerprint` column for a match
   - **Match found**: Increment the `Seen` count. Update the date. If the new severity is higher than the existing one, upgrade it. Do not create a duplicate row.
   - **No match**: Append a new row with the next sequential `B-{N}` ID.

3. **Handle resolved items**: If any `OPEN` items in the backlog refer to files you just modified, and the issue is now fixed, delete the row entirely. Git history preserves the record. Do not change status to `RESOLVED` — just remove the row.

## Confidence-Based Routing

Every finding has a confidence level. Route based on confidence:

| Confidence | Action | Rationale |
|-----------|--------|-----------|
| 0-25% | Discard | Likely hallucination or insufficient evidence. Do not persist. |
| 26-50% | Persist to backlog only | Real enough to track but not confident enough to report. Mark as low-confidence in the Problem column. |
| 51-100% | Report AND persist to backlog | Actionable finding. Include in the skill's output report and record in the backlog. |

## Zero Silent Discards

This rule is absolute: no finding with confidence above 25% may be silently dropped. Every such finding must appear either in the report, in the backlog, or both.

If a finding is borderline (26-30%), annotate it: `(low confidence — verify manually)`. But it must still be recorded.

## When to Run This Protocol

- After every audit skill completes (code-audit, test-audit, security-audit, etc.)
- After review agents report findings
- After execute phase quality reviewers flag issues
- When the user runs `zuvo:backlog` to manage existing items

## What Does NOT Go to Backlog

- Findings with 0-25% confidence (discard as likely false)
- Style preferences without rule backing ("I'd prefer this naming")
- Suggestions for future enhancements without current violations
- Issues already fixed during the current session (no need to track what's already resolved)
