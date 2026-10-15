---
name: backlog
description: >
  Manage the project's tech debt backlog. Add, list, fix, wontfix, delete,
  prioritize, and suggest batch actions on tracked issues, run by the user
  to manage accumulated debt (skills file their findings through
  ~/.zuvo/backlog-add themselves, never through this skill). Modes: list [category], add [description], fix B-<id>,
  wontfix B-<id> [reason], delete B-<id>, stats, prioritize, suggest, and the
  three grooming modes verify, groom and doc (whether each entry is still true,
  the dispositions that follow, and the ranked working document).
category: Utility
---

# zuvo:backlog — Tech Debt Management

Add (through `~/.zuvo/backlog-add`), list, and manage backlog items. The backlog tracks technical debt discovered by audit skills, review agents, and manual entries.

**Backlog location:** `memory/backlog.md`, resolved per `../../shared/includes/backlog-protocol.md` ("Where the Backlog Lives"): when git tracks it in the checkout you are in, that checkout's copy is the backlog for its branch; otherwise it lives at the **MAIN checkout root**. The helper applies the rule — `~/.zuvo/backlog-archive.py path --repo "$PWD"` prints the path — and every helper call below takes `--repo "$PWD"`. By hand, copy the protocol's whole resolution block (its fallback is mandatory: without it a non-git CWD yields an empty root and re-forks the backlog).

For an UNTRACKED backlog, NEVER create or write a `memory/backlog.md` inside a linked worktree — one backlog per repository. If `memory/` does not exist at the resolved root, create it. If the file does not exist, create it from the template at the bottom of this skill. If a legacy untracked worktree-local copy exists, merge its unique entries (by the dedup key defined in `../../shared/includes/backlog-protocol.md`) into the main copy before proceeding.

**Scope:** Managing the tech debt backlog -- viewing, adding, resolving, prioritizing, and suggesting batch actions.
**Out of scope:** Actually fixing the issues (use `zuvo:fix-tests`, `zuvo:refactor`, or the suggested command from `suggest` mode).

## Argument Parsing

| Input | Action |
|-------|--------|
| _(empty)_ or `list` | Show all OPEN items as a summary table |
| `list category:[x]` | Show OPEN items filtered by category (code/test/arch/dep/doc/infra; an entry `backlog-add` wrote is matched by its class, [Tech Debt Categories](#tech-debt-categories)) |
| `list all` | Show all items including RESOLVED and WONTFIX |
| `add` | Interactive: ask what to file, then file it with one `backlog-add` call ([Adding Items](#adding-items)) |
| `add [description]` | Parse the description and file it with one `backlog-add` call ([Adding Items](#adding-items)) |
| `fix B-<id>` | Mark item as RESOLVED |
| `wontfix B-<id> [reason]` | Mark item as WONTFIX with reason |
| `delete B-<id>` | Remove item (show details, ask confirmation) |
| `delete B-<id> --force` | Remove without confirmation |
| `archive [--dry-run]` | Move ticked, resolution-marked entries to `memory/backlog-done.md` |
| `regression B-<id>` | Re-open an archived entry under the same id (lookup said ARCHIVED) |
| `stats` | Show counts by severity and category |
| `prioritize` | Score and rank all OPEN items by urgency |
| `suggest` | Group items by pattern, propose batch fix commands |
| `verify` | Decide whether every entry is still TRUE, before anything is closed, ranked, grouped or rendered — see [Mode: verify](#mode-verify) |
| `groom [--dry-run]` | Apply the dispositions those verdicts license; refuses on partial verification — see [Mode: groom](#mode-groom) |
| `doc [--partial]` | Render the groomed working document under `zuvo/reports/` — see [Mode: doc](#mode-doc) |

### The three mode words, and the commands they actually run

`verify`, `groom` and `doc` are **this skill's** words. The helper underneath has different ones:
`scripts/zuvo-home/backlog-groom.py --help` is the authority, and it answers
`{plan, dispatch, ingest, apply, render, coverage}`. The mapping lives **here, once** — a second copy
is two names drifting apart:

| Mode | Runs | Phase section |
|------|------|---------------|
| `verify` | `plan`, then `dispatch` + `ingest` once per chunk | [Mode: verify](#mode-verify) |
| `groom` | `apply` | [Mode: groom](#mode-groom) |
| `doc` | `render` | [Mode: doc](#mode-doc) |

`coverage` is not a mode: it is the read-only count `~/.zuvo/append-runlog` prints at the end of a run
**when a verdict ledger exists and is short** — never otherwise, because an unverified backlog is the
steady state in most repos and a line on every run is a line nobody reads. Nobody types it.

**`verify --fleet` and `groom --fleet` are not commands and never were.** The plan that commissioned
this feature named them four times each. `plan --fleet` is the read-only fleet verification (it reads
`~/.zuvo/backlog-local.jsonl` and writes only under `~/.zuvo/`), and `apply --fleet` is **rejected by
design** — grooming needs each repo's own lock, realpath, ignore status and `backlog-done.md`, and
doing that across 88 checkouts is the 2026-07-19 fork-the-backlog incident with 88x the blast radius.
Use the mode word with a person and the real command at a shell; never invent a third name for either.

## Mode: verify

**Nothing is closed, ranked, grouped or rendered until every entry carries a verdict backed by an
evidence line.** Not a sample — the whole set. Read
`../../shared/includes/backlog-grooming.md` first; it holds the closed five-token vocabulary, the
four evidence shapes, the ledger schema and the fan-out contract, and this file deliberately does not
paraphrase any of them.

```bash
backlog-groom.py plan --repo . [--dry-run]       # mint, decide the deterministic classes, queue the rest
backlog-groom.py dispatch --repo . --chunk N     # hand ONE chunk to the lane, seeds mixed in
backlog-groom.py ingest --repo . --dispatch <D> --response <R>
```

`plan --fleet` is the read-only variant: it verifies from the collector's snapshot, writes
`~/.zuvo/backlog-verdicts/<host>-<repo>.jsonl`, and touches no checkout. Its rows carry
`source=index` because the snapshot truncates each entry at 400 characters, and a disposition on such
a row is refused rather than performed.

A verdict survives between runs: it expires with the entry's **text**, not with the clock. So a
second `verify` over an unchanged backlog dispatches nothing at all, and the resolution marker `groom`
itself writes costs nothing either.

## Mode: groom

```bash
backlog-groom.py apply --repo . [--dry-run]
```

`apply` **refuses** unless every entry carries a current verdict, naming the shortfall by id and
exiting outside `{0,1,2,10,11,12}`. That refusal is the mechanism behind the rule above; it is not a
warning to read past. It writes nothing to `memory/backlog.md` — closures are delegated to
`backlog-archive.py archive` / `drop-stale`, ordering stays in the ledger and the rendered document,
and where no helper will act the entry is reported `no-remedy` with its reason rather than a false
`archived`.

`apply --fleet` is rejected naming the per-repo command, before the repo is even resolved.

## Mode: doc

```bash
backlog-groom.py render --repo . [--partial]
```

The working document — clustered by theme, ranked by the `prioritize` score above, with per-cluster
batch commands and an explicit not-verifiable section — lands under `zuvo/reports/`. It **refuses**
below full coverage unless `--partial`, which stamps the coverage ratio into the header, omits the
ranking entirely, and names the entries it did not render. Its header carries the source backlog's
`sha256`, the coverage count and the generating version, plus the command that re-checks all three, so
a reader can tell from the document alone whether it still describes the file.

---

## The verification lane (`agents/backlog-verifier.md`)

Deciding whether an entry is **still true** is not one of the modes above, and it is not done inline.
It is dispatched, one byte-capped CHUNK at a time, to `agents/backlog-verifier.md` — a read-only lane
that returns one verdict and one evidence line per row.

The orchestration is in `scripts/zuvo-home/backlog-groom.py`, never in this file's prose:

| Step | Command |
|------|---------|
| mint, decide the deterministic classes, write the queue | `backlog-groom.py plan --repo . [--dry-run]` |
| hand one chunk to the lane, seeds mixed in | `backlog-groom.py dispatch --repo . --chunk N` |
| check the response and append only if nothing refused | `backlog-groom.py ingest --repo . --dispatch <D> --response <R>` |

Read `../../shared/includes/backlog-grooming.md` before using any of them. Two things about this lane
that are easy to get wrong and expensive to get wrong:

- **A chunk is all-or-nothing.** `ingest` writes ledger rows only when the rejection list is empty. One
  bad record writes zero rows for every row the lane got right, so the check after a run is the
  ledger's **byte count**, not the presence of one verdict.
- **The four mechanical controls do not validate a verdict.** Shape, resolvability and keyword overlap
  establish that the evidence is well-formed and points at a real line — they cannot say the verdict is
  correct. Only the seeded known-answers measure judgement, on K=4 rows per chunk. Never report a lane
  result as verified or cross-checked.

Dispatch follows `../../shared/includes/execution-policy.md` through env-compat. Reuse existing
authorization within that policy; session restrictions take precedence. Run each required gate
and report its actual independence or an unmet requirement.

**Inline verification is NOT a substitute for the lane.** Deciding the rows yourself and recording the
result as if the lane had run is the substitution `no-gate-substitution` describes: it produces verdicts
with no `agent:` provenance for the cross-model spot check to select on, and it bypasses controls (a)-(d)
entirely while reporting that they ran. If the harness genuinely cannot dispatch, say so and record the
rows as unverified — `groom` then refuses, which is the correct outcome rather than a blocked one.

---

## Mandatory File Loading

### PHASE 0 — Bootstrap (before reading the backlog)

`env-compat.md` is here for one measured reason: this skill scans repositories and waits on the
commands that do it, and it accounted for **485 of 11,690 Codex poll calls** while referencing that
include nowhere — so the "do not enter the poll loop" rule could not reach it however well written.
Each poll re-sends the whole context (~108K tokens median) to learn one bit.


```
  1. ../../shared/includes/codesift-setup.md      -- [READ | MISSING -> WARN]
  2. ../../shared/includes/backlog-protocol.md    -- [READ | MISSING -> STOP] (the file format is the contract)
  3. ../../shared/includes/env-compat.md          -- [READ | MISSING -> WARN] (waiting rule; see below)
  4. ../../shared/includes/backlog-grooming.md    -- [READ for verify/groom/doc | MISSING -> STOP for those three modes]
```

`retrospective.md` and `run-logger.md` are END-of-run includes — they are loaded at completion, not here.

## Run Logging

Read `../../shared/includes/run-logger.md` for log format and file path resolution.
Read `../../shared/includes/retrospective.md` for log format and file path resolution.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for initialization.

**Key tools for this skill:**

| Command | Task | CodeSift tool | Fallback |
|---------|------|--------------|----------|
| suggest | Find undiscovered TODO/FIXME debt | `search_text(repo, query="TODO\|FIXME\|HACK", regex=true)` | Grep |
| suggest | Context around TODO markers | `find_and_show(repo, query=<function>, include_refs=true)` | Read the file |
| prioritize | Count references to affected function | `find_references(repo, symbol_name=<fn>)` | Skip (score from description only) |
| prioritize | Blast radius of recent items | `impact_analysis(repo, since="HEAD~10", depth=2)` | Skip |
| fix | Find related code when planning a fix | `search_symbols(repo, query=<keyword>)` | Grep |
| fix | Batch-read related functions | `get_symbols(repo, symbol_ids=[...])` | Multiple Read calls |

---

## Backlog Schema

All interactions use these columns:

| Column | Description | Set by |
|--------|-------------|--------|
| ID | `B-<id>`, minted by `backlog-add` | Auto |
| Status | OPEN, RESOLVED, WONTFIX | Auto (default: OPEN) |
| Fingerprint | Dedup key (see format below) | Auto |
| File | File path | Required |
| Problem | Short description | Required |
| Severity | CRITICAL, HIGH, MEDIUM, LOW | Required |
| Category | Code, Test, Architecture, Dependency, Documentation, Infrastructure | Legacy rows only; an entry `backlog-add` writes has none and is mapped from its `[<CLASS>]` ([Tech Debt Categories](#tech-debt-categories)) |
| Source | Which skill added it | Auto |
| Seen | Occurrence count | Auto |
| Added | Date first added (YYYY-MM-DD) | Auto |

### Fingerprint Formats

- From audit skills: `file|rule_id|signature` (e.g., `auth.service.ts|cq8|missing-try-catch`)
- From test audit: `file|pattern_id|signature` (e.g., `auth.test.ts|p-41|loading-only`)
- Manual add: `file|manual|first-3-words-slugified` (e.g., `auth.ts|manual|missing-rate-limiting`)

All fingerprint components are lowercase, trimmed, with leading `./` stripped from paths.

### Listing View (compact)

Default view shows: `ID | Severity | File | Problem | Seen`

---

## Adding Items

Every item the user adds is one `~/.zuvo/backlog-add` call, made per "Persisting a finding: backlog-add"
and "Filing from a skill" in `../../shared/includes/backlog-protocol.md`. The helper mints the id, runs
the duplicate check across `backlog.md`, `backlog-done.md` and the findings ledger, and writes. In this
add flow the skill never mints an id, runs the lookup or appends a line itself.

1. From the description (or by asking, in interactive mode), take:
   - **Site:** the file and line. A code defect the user describes without naming a file: ask for the
     file. With the file known, find the line by reading the file and confirm the defect is at it; when
     the line cannot be verified that way, ask the user for it. Never guess a line. Only a process or
     decision item (a gate, a follow-up, an open question) has no file.
   - **Class:** `BUG` only when the user states both the input and the wrong result; otherwise `CQ`, or
     the class the item plainly is (`SEC`, `PERF`, ...); `PROCESS` for a process or decision item. The
     Auto-Inference keywords are hints, never a substitute for the input and the wrong result.
   - **Confidence:** derived from what the user stated and what this run checked, never a fixed number:
     the cited line read and the defect seen there, or the behaviour reproduced → 80-95; stated by the
     user but not checked → 50-75.
   - **Title** in one sentence, and a severity when the description implies one (Auto-Inference Rules).
2. File it with `--source user`, one call per item. The user's words are free text, so every `"$X"`
   argument below is assigned just before the call, one assignment per value, as "Filing from a skill"
   says (the form works in bash 3.2 and zsh):

   ```bash
   read -r -d '' T <<'ZUVO_TXT' || true
   <the title, verbatim>
   ZUVO_TXT
   read -r -d '' F <<'ZUVO_TXT' || true
   <the file path, repo-relative>
   ZUVO_TXT
   read -r -d '' A <<'ZUVO_TXT' || true
   <the anchor, copied from the cited line>
   ZUVO_TXT
   read -r -d '' S <<'ZUVO_TXT' || true
   <the slug, a process or decision item only>
   ZUVO_TXT
   ```

   - `BUG`, `SEC`, `DATA`: `~/.zuvo/backlog-add --repo "$PWD" --class <C> --conf <N> --source user --file "$F" --line <n> --anchor "$A" --title "$T" [--severity <level>]`
   - any other class with a file: `~/.zuvo/backlog-add --repo "$PWD" --class <C> --conf <N> --source user --file "$F" --line <n> --title "$T" [--severity <level>]`
   - a process or decision item: `~/.zuvo/backlog-add --repo "$PWD" --class PROCESS --conf <N> --source user --target "subject:$S" --title "$T" [--severity <level>]`, where `S` is a slug of the title: kebab-case, ASCII `[a-z0-9-]` only (transliterate letters such as `ł` or `ą`, drop any other character), cut to 40 characters. A title with no ASCII letters or digits leaves it empty, and `backlog-add` refuses an empty target: ask the user for a slug

   Prefix the call with `ZUVO_BACKLOG_ADMIT=1` only when the user ran this `add` mode themselves in this
   message: their request for the item is the explicit request the override exists for, so a `CQ` or
   `PROCESS` item lands in the backlog instead of only the ledger. Never when a skill or an agent invokes
   this mode, and never for an item the user did not ask to file.
3. Report the verdict `backlog-add` printed: the B-id it filed or bumped, REGRESSION for `REOPENED`, the
   F-id for a ledger record. A refusal is corrected only when the input was mistyped (a path, a line,
   the anchor text) and then resubmitted once; never by changing `--class` or `--conf` to get past a
   bar. Anything else is reported as `NOT PERSISTED (<reason>)`. Never append the item by hand.

### Batch Add

If the user provides several items (numbered list, bullets, or comma-separated), file each with its own
`backlog-add` call in one pass, without pausing for confirmation, then show one summary table: item,
class, site and the verdict each call printed.

### Auto-Inference Rules

Do not ask per-item for batch adds, except for the file of a code defect that names none, or a line
that reading the file cannot verify. Infer the
rest; the keywords are hints:

- **Class:** a wrong behaviour stated with its input (`returns`, `crashes`, `loses`, `wrong`) -> `BUG`; a process or decision item -> `PROCESS`; otherwise `CQ`.
- **Severity** (`--severity`): `race condition`, `security`, `data loss` -> `high`. `any type`, `missing test` -> `medium`. `typo`, `naming` -> `low`.
- **Source:** `user`
- The id, `seen` and the date are set by `backlog-add`.

---

## Resolving Items

`fix` and `wontfix` record the resolution on the entry and then ARCHIVE it. Neither removes the
record: the archive is what lets a later sighting be recognised as a regression instead of being
re-filed as new work.

Finding the entry a mode acts on, or answering "is this already known?" without filing anything, is
the lookup across **both** files — run it, do not re-implement it:
`~/.zuvo/backlog-archive.py lookup --repo "$PWD" "<B-id or candidate text>"`. It answers `OPEN` (exit 10),
`ARCHIVED` (exit 11: the `regression` path), `ABSENT` (exit 0), or `NO-SIGNATURE` (exit 13: the query keys
on nothing — empty, or stripped to nothing as resolution markers; nothing was looked up, so rewrite it to
name the file and the defect, or pass the B-id). Checking only `backlog.md` is not a check: an entry that
exists solely in `backlog-done.md` reads as ABSENT.

- `fix B-<id>`: verify exists (error if not), tick the box and **append** `[FIXED <sha7>]` to the
  existing text — never write over the problem description, because the description is what the
  content key is computed from.
- `wontfix B-<id> [reason]`: verify exists, tick the box and append `WONTFIX — <reason>`.
- `archive [--dry-run]`: move every ticked, marker-carrying entry into `backlog-done.md` via
  `~/.zuvo/backlog-archive.py archive --repo "$PWD"`. Entries holding a live `[ ]` sub-item are
  refused, not moved — split them first.
- `regression B-<id>`: the `ARCHIVED` path of the lookup. Re-open under the same id with the
  back-link, severity one band higher, and the word REGRESSION in the report.
- `delete B-<id>`: destructive and rarely right. Print "this destroys the record — `archive` is what
  you want", show the item, ask "Delete? (y/n)". With `--force`, skip the confirmation only.

**Never archive by hand.** `~/.zuvo/backlog-archive.py archive` does it — with a lock, byte conservation, minted ids and the git-tracking refusal. What a hand-written archive breaks, and the measured incident behind the rule, are in `backlog-protocol.md` → "Archiving is done by the helper, never by hand" (kept there once rather than paraphrased here).

**Order, not growth control:** archive; never prune. A resolved entry does not stay in the open
backlog — it moves verbatim to `backlog-done.md`, so the record survives. There is **no size
threshold**: one resolved entry is already reason enough, and `~/.zuvo/append-runlog` does the move
automatically at the end of every run. `backlog-archive.py status` answers "is anything done still
sitting here?" — exit 12 yes, 0 no. A tick with no resolution marker also moves, into a section whose
heading says the reason was never recorded; only an entry with a live `[ ]` sub-item is held back.
See "When to archive" in the protocol.

---

## Listing Items

Default (`list`): show OPEN items only.

```
TECH DEBT BACKLOG -- [project name]
-----
| ID   | Severity | File                    | Problem                  | Seen |
|------|----------|-------------------------|--------------------------|------|
| B-1  | MEDIUM   | auth.service.ts         | catch(err: any)          | 3x   |
| B-2  | HIGH     | payout.service.ts       | Race condition in claim  | 1x   |
-----
OPEN: X items (C: _, H: _, M: _, L: _)
```

---

## Stats

```
BACKLOG STATS
-----
OPEN:      X items
  CRITICAL:  _
  HIGH:      _
  MEDIUM:    _
  LOW:       _

By category:
  Code: _  Test: _  Architecture: _
  Dependency: _  Documentation: _  Infrastructure: _

Top files (by item count, top 5):
  1. services/payout.service.ts (3 items)
  2. handlers/webhook.ts (2 items)
-----
```

---

## Prioritize

Score each OPEN item to produce a ranked list. The scoring formula:

```
Priority Score = (Impact + Risk) x (6 - Effort)
```

| Dimension | 1 | 3 | 5 |
|-----------|---|---|---|
| Impact | Rarely slows work | Sometimes blocks development | Slows the team every day |
| Risk | Nice to have | Regressions possible | Security or data loss risk |
| Effort | Multiple days | About a week | A month or more |

Score range: 2 (low priority) to 50 (fix immediately).

**What `doc` DERIVES, and the one thing it cannot.** The rendered document computes all three dimensions
from the bytes — Impact from the entry's declared severity word, Risk from a small named vocabulary in
its own text, Effort from its block size — and says so in the table's own caveat. When a dimension's
vocabulary is absent the answer is the **neutral 3**, for Risk exactly as for Impact. Risk is never a
copy of Impact: it was, and a `critical` entry naming no risk at all then printed Risk 5, indistinguishable
from one that says "data loss", while the score counted one signal twice. A derived score is a reading
order, not an assessment — the table above is what a HUMAN means by these dimensions.

**CodeSift-enhanced scoring:** When indexed, use `find_references(repo, symbol_name=<function>)` to count callers. Higher reference count means larger blast radius, which increases Impact and Risk scores.

Output:

```
PRIORITIZED BACKLOG
-----
| Rank | ID   | Score | Impact | Risk | Effort | Problem               |
|------|------|-------|--------|------|--------|-----------------------|
| 1    | B-2  | 40    | 5      | 5    | 2      | Race condition payout |
| 2    | B-1  | 24    | 4      | 4    | 3      | catch(err: any)       |
-----
```

---

## Suggest

Analyze all OPEN items by pattern and propose batch actions.

**CodeSift-enhanced discovery:** Before analyzing existing items, scan for undiscovered debt:
- `search_text(repo, query="TODO|FIXME|HACK|WORKAROUND", regex=true)` to find inline markers not yet tracked
- Cross-reference with existing fingerprints to avoid duplicates
- If CodeSift unavailable, analyze only existing backlog items

### Pattern Matching

| Condition | Suggested action |
|-----------|-----------------|
| 3+ items with the same CQ gate failure | `zuvo:code-audit [files]` or direct batch fix |
| 3+ items from test-audit with same pattern ID | `zuvo:fix-tests --pattern [ID] [path]` |
| 3+ items in the same module | `zuvo:refactor [module]` |
| 5+ low-tier items | `zuvo:code-audit --deep [path]` |
| No OPEN items | "Backlog is clear. Consider a periodic audit." |

If multiple patterns match the same items, show all matching suggestions.

Output:

```
BACKLOG SUGGESTIONS
-----
Pattern: CQ8=0 in 5 files          -> zuvo:code-audit src/services/
Pattern: P-41 in 4 test files       -> zuvo:fix-tests --pattern P-41 src/
Hotspot: offer.service.ts (6 items) -> zuvo:refactor src/offer/offer.service.ts
-----
```

---

## Error Handling

| Situation | Response |
|-----------|----------|
| `fix B-99` but B-99 not found | "B-99 not found. Run `zuvo:backlog list` to see current items." |
| `list` but backlog is empty | "Backlog is empty. Use the `add` mode to track issues." |
| `add` with vague description (no file) | Ask for the file and the specific problem; only a process or decision item is filed without one, as `PROCESS` (Adding Items) |
| `prioritize` with 0-1 items | "Only N item(s) -- no ranking needed." |
| `suggest` with 0 items | "Backlog is clear. Consider scheduling a periodic audit." |

---

## Tech Debt Categories

| Alias | Category | Examples |
|-------|----------|----------|
| code | Code | Duplicated logic, magic numbers, any-types |
| arch | Architecture | Wrong data store, monolith boundaries |
| test | Test | Low coverage, flaky tests, missing integration tests |
| dep | Dependency | Outdated libraries, CVEs, unmaintained packages |
| doc | Documentation | Missing runbooks, outdated READMEs |
| infra | Infrastructure | Manual deploys, no monitoring, missing IaC |

An entry `backlog-add` writes carries no Category column: its line holds the class in brackets after
the location (`- [ ] B-<id> <path>:<line> — [<CLASS>] <title> | …`). `list category:[x]` and `stats`
read a legacy table row's Category column as written, and map an entry `backlog-add` wrote by that
class:

| Class | Category |
|-------|----------|
| `BUG`, `SEC`, `DATA`, `DUP`, `CPLX`, `SIZE`, `PERF`, `DEAD`, `READ`, `CQ` | code |
| `TEST-GAP`, `MUTATION` | test |
| `PROCESS`, `ADVISORY` | none: shown by an unfiltered `list` only |

No class maps to arch, dep, doc or infra; those filters match legacy rows only.

---

## Completion

After completing any action, print:

```
BACKLOG COMPLETE
-----
Action: [list | add | fix | wontfix | delete | stats | prioritize | suggest | verify | groom | doc]
Run: <ISO-8601-Z>	backlog	<project>	-	-	<VERDICT>	-	<DURATION>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

`<DURATION>`: use the action label (`list`, `add`, `fix`, `wontfix`, `delete`, `stats`, `prioritize`,
`suggest`, `verify`, `groom`, or `doc`).

---

## Backlog Template

When `memory/backlog.md` does not exist, create it from this template:

```markdown
# Tech Debt Backlog

> Maintained by zuvo:review, zuvo:build, zuvo:code-audit, zuvo:test-audit, zuvo:write-tests, zuvo:fix-tests, zuvo:backlog.

| ID | Status | Fingerprint | File | Problem | Severity | Category | Source | Seen | Added |
|----|--------|-------------|------|---------|----------|----------|--------|------|-------|
```
