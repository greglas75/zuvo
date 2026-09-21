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

# The archive (see "The Archive File") lives beside the REAL backlog, never beside a symlink to
# it. Measured 2026-09-18: six ~/DEV checkouts plus one project dir reach ONE canonical
# backlog.md through symlinks, and two of those directories are not git repos at all — so
# MAIN_ROOT degrades to `pwd` and `dirname $BACKLOG` is SIX different directories. Resolving here
# is what stops one archive becoming six. It is also why the helper writes onto the realpath: an
# atomic `os.replace()` onto the symlink would replace the link with a regular file and fork the
# 1.2 MB backlog into six copies — the 2026-07-19 incident, re-caused by the fix for it.
BACKLOG_REAL=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$BACKLOG")
ARCHIVE="$(dirname "$BACKLOG_REAL")/backlog-done.md"
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

2. **Check for duplicates in BOTH files.** The backlog namespace is two files: `$BACKLOG` (open)
   and `$ARCHIVE` (closed or deliberately withdrawn). An entry is defined in exactly one of them,
   never both.

   **The key.** The table above is the shape for a NEW file; every backlog in the fleet is `- [ ]`
   bullets with free-form `B-<slug>` ids, and 65% of open entries carry no id at all (measured:
   427 of 1211). So the key is computed, in this order:

   1. `id:<slug>` — the `B-<slug>`, lowercased, **only when the entry HEADS with it** (after
      `- [ ]`, `**`, `[`). A definition, not a mention: 44 `B-*` tokens appear in both files of the
      largest backlog and only 5 are definitions — the other 39 are `see B-X` prose references.
   2. `fp:<sha1[:12]>` — otherwise, over a normalized signature: the first path-looking token plus
      the 8 words that FOLLOW it, lowercased, with everything that appears only on closure stripped
      first (the checkbox, `FIXED`/`DONE`/`RESOLVED`/`CLOSED`/`WONTFIX`/`OBSOLETE` in any wrapper,
      commit shas, branch names, `PR #NNN`, `conf: NN`, dates).

   **The id is the only key that reliably survives closure.** Measured on the five entries that
   were in both files: the id matched 5/5, the content key 0/5 — because closing an entry rewrites
   its text into a description of the fix, often in another language. Two consequences, both
   binding: archiving assigns an id to any entry that lacks one, and a resolution is **appended**
   to the original problem text, never written over it.

   **Do the lookup:**

   ```bash
   ~/.zuvo/backlog-archive.py lookup --repo "$MAIN_ROOT" "<candidate text or B-id>"
   ```

   One verdict line, one exit code:

   | Verdict | exit | What you do |
   |---------|------|-------------|
   | `OPEN <key> <id> backlog.md:<line>` | 10 | Update THAT entry in place — bump `Seen`/`conf:`, update the date, raise the severity if the new evidence is worse, add the new source. Never a second entry. |
   | `ARCHIVED <key> <id> backlog-done.md:<line> section="<heading>"` | 11 | **REGRESSION, not a new finding.** Re-open under the SAME id with the back-link (form below). Never mint a new id. |
   | `ABSENT <key>` | 0 | Genuinely new. Append one entry with a fresh id. |

   If `~/.zuvo/` is absent (only the Claude Code install ships it) the check is still MANDATORY —
   do it with two greps, and grep the id or a distinctive PATH token, never a common word:

   ```bash
   grep -n "<id-or-distinctive-token>" "$BACKLOG"
   grep -n "<id-or-distinctive-token>" "$ARCHIVE"   # a missing file means ABSENT; do not create it
   ```

   Why "distinctive": entries average 620 bytes, so `grep export` across both files of the largest
   backlog returns 197 KB (~49k tokens) for ONE dedup check, while `grep operators.ts` returns
   3.4 KB. The helper costs ~40 tokens either way.

   **"I checked backlog.md" is not a check.** A candidate that exists only in the archive reads as
   ABSENT to a one-file check and comes back as new work under a new id — which is exactly how a
   closed 300-item archive turns itself back into an open backlog.

   **Re-opening an archived entry** — append to `$BACKLOG`, same id, one-way back-link:

   ```
   - [ ] B-<SAME-ID> [REGRESSION <date> — closed <prev-marker>, archived in backlog-done.md
     "<section heading>"] <original problem text, unchanged> | re-observed by <skill> | conf: NN
   ```

   The archive stays append-only: do not edit the archived entry to record the re-open. The link is
   one-way on purpose — a two-way link needs two writes and the second is the one that gets lost. A
   regression is louder than a first sighting: raise the severity one band and say REGRESSION in the
   report, not only in the backlog.

3. **Handle resolved items — ARCHIVE, never remove.** Move the entry out of `$BACKLOG` and append
   it verbatim to `$ARCHIVE` under a dated section:

   ```bash
   ~/.zuvo/backlog-archive.py archive --repo "$MAIN_ROOT" --dry-run   # always first
   ~/.zuvo/backlog-archive.py archive --repo "$MAIN_ROOT"
   ```

   By hand: tick the box (`- [x]`), append the resolution marker (`[FIXED <sha7>]`,
   `WONTFIX — <reason>`) to the existing text, cut the line, and append it UNCHANGED under
   `## Archived from backlog.md on <YYYY-MM-DD> (N completed items moved out)`.

   **Removing the entry is forbidden.** The rule this replaces had you drop the row outright and
   relied on git history to keep the record. That is false exactly where the cost is highest: in at
   least one repo `memory/backlog.md` is matched by `.gitignore`, so it has no git history, and the
   largest backlog in the fleet is a file outside any repository reached by symlink from six
   checkouts. A destroyed record is re-discovered by the next audit and re-filed as new work —
   the loop this protocol exists to stop.

   Do NOT archive an entry whose body still holds an unticked `[ ]` sub-item; split the open
   remainder into its own entry first. (Measured: three entries in one real archive carry
   `[ ] OPEN follow-up:` text that went out of sight with their resolved parent.)

## The Archive File

`backlog-done.md`, beside the REAL `backlog.md`. One per backlog. Append-only.

- **Sections:** the writer emits `## Archived from backlog.md on <date> (N completed items moved
  out)`. The reader accepts ANY `##` heading and reports it verbatim — real archives also carry
  `## CHUCKED (…)`, `## BPTO done/closed — …` and non-English headings, and quoting the heading is
  what makes them self-explaining without inventing a taxonomy.
- **Entries:** the original lines, byte-identical, `- [x]`-ticked. No reformatting, no renumbering.
- **Membership means "must not come back as new."** That covers resolved entries AND ones
  deliberately withdrawn. Which it was is in the heading, and the lookup prints it.
- **Out of the namespace:** `backlog-archive-<date>.md`, `backlog-removed-<date>.md`,
  `backlog-verified-stale-<date>.md`, `backlog.md.bak*`. Historical whole-file snapshots from before
  this rule; the lookup never consults them. Do not create new ones — they are snapshots of a file,
  not lists of closures, and merging them would report ARCHIVED for entries later re-opened and
  re-fixed.
- **The archive inherits the source's visibility.** If `git check-ignore memory/backlog.md` matches,
  the archive must be ignored too, and it inherits the source's file mode. Otherwise archiving
  publishes into git content that was deliberately untracked and 0600.

## When the same id is in both files

`backlog-archive.py verify` reports it and names each one; `~/.zuvo/append-runlog` refuses to log a
run that leaves the namespace inconsistent. Three outcomes, and the distinction matters because two
of them are NOT removals:

| what it is | how to tell | action |
|---|---|---|
| stale open copy | the archived copy declares the fix and describes the same defect | `backlog-archive.py drop-stale --id <ID>` |
| partial closure | the archived copy closes one part ("część A", "step 2") | say in the OPEN entry which part is left; leave both |
| genuine regression | it broke again after the fix | re-open per the REGRESSION form above; the pair is then legitimate and the gate exempts it |

`drop-stale` exists because "just remove the stale line" is riskier advice than it sounds: closing an
entry REWRITES it into a description of the fix, so the open copy is frequently the only place the
PROBLEM is stated. It therefore refuses unless the id is in both files AND the archived copy carries
a resolution marker, and it keeps the removed text in the archive as an indented quote — not as a
second `- [x]` definition, which the two-file check cannot see.

**An ordinal id is not an identity.** `B-1`, `B-70` are positions in a numbered batch and get reused;
two entries sharing one are two entries, not a duplicate. Identity keys off descriptive ids only
(`B-rev-sigterm-leak`, `B-20260913-KANO-…`), everything else keys off content.

## When to archive

**As soon as an entry is resolved — there is no threshold.** The backlog is the list of what is
LEFT; a finished entry sitting in it is disorder, independently of how many bytes it costs. The
archive is what makes that safe: the entry moves **verbatim**, so the history — including the
closing note that is often the only record of why the original recipe was wrong — is preserved
rather than deleted.

An earlier version of this section made archiving conditional on volume — roughly fifty closed
entries, or a hundred kilobytes of closed text, whichever came first. That measured the wrong
thing, and the result was measurable: two days after the archiver shipped,
**not one repo had used it**, no index existed anywhere in the fleet, and the only archive that
existed had been written by hand before the tool did. A rule that fires on a size threshold asks
someone to notice the threshold.

So it no longer depends on anyone noticing: **`~/.zuvo/append-runlog` archives automatically** at
the end of every run (opt-out `ZUVO_NO_AUTO_ARCHIVE=1`, which prints a WARN). It never blocks a
run — housekeeping that refuses to record finished work gets switched off, and rightly so.

**Two sections, because the evidence differs.** A resolved entry moves under
`## Archived from backlog.md on <date> (N completed items moved out)` when it records a resolution,
and under `(N ticked WITHOUT a recorded resolution — the reason was never written down; the tick is
the only evidence)` when it does not. The heading is the safeguard: a reader can always tell a
documented closure from a bare checkbox.

Until 2026-09-21 an unmarked tick was held back instead, on the argument that archiving it files away
a decision nobody recorded. Measured: **538 such entries in 17 files**, 182 in the largest. The rule
protected the record and lost the purpose — those 538 were finished items sitting in the list of what
is LEFT, indefinitely, waiting for notes nobody was going to write. The tick is itself a record that
someone judged the work done, and the missing reason is a pre-existing fact that moving the line does
not worsen.

Consequence to know: if you tick an entry and let a run finish before writing the why, it is archived
under the second heading. Write the resolution in the SAME edit as the tick, or add it in the archive
afterwards — `lookup` finds it there either way.

**One kind is still held back** and reported rather than moved:

| held back | why | how to release it |
|---|---|---|
| a live `[ ] ` sub-item inside a resolved entry | the open follow-up goes out of sight with its parent | split the follow-up into its own entry |

Ask the helper rather than eyeballing the file: `backlog-archive.py status` prints one line and
exits **12** when resolved work is still in `backlog.md`, **0** when it is clean.

## Concurrent writes

Archiving is the first read-modify-write-whole-file operation in this family; everything before it
appended. A lost update here loses hundreds of entries, not one line. The helper takes a portable
mkdir-atomic lock dir (`.backlog-archive.lock.d`, `ZUVO_LOCK_WAIT`, pid file, never steals a live
holder — the same primitive as `e2e-preflight` and `append-runlog`, because macOS ships no
`flock(1)`), writes a temp file beside the real backlog, verifies that every moved line is present
in the archive before either rename, and only then replaces the realpath. Serializing the many
*appending* writers is a separate, tracked problem (`B-backlog-flock`).

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
