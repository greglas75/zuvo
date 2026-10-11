# Comment Pass — keep the comments this run wrote short and true

**Why.** A comment earns its place when it says what the code cannot: why it is shaped this way.
History next to code rots as the code moves on, and a comment that contradicts its code misleads an
agent more than a human, because the agent trusts it. This pass runs `~/.zuvo/comment-audit` over
the lines THIS run wrote and fixes what it finds in-run, before the work is staged.

## What the helper judges

Only **authored** lines count: added lines minus lines carried (moved) from anywhere in the diff.

| Rule | Finding | rc |
|---|---|---|
| `D` density | authored comment / (comment + code) above 0.30, on a file with at least 20 authored lines | 1 |
| `N` narration | a date, history, incident or measurement marker in authored comment text | 1 |
| `L` long block | a comment block of 4+ lines longer than the code it describes | 1 |
| `C` claim | a quantitative claim, printed as `CHECK path:line "<text>"` | never |

Thresholds are the defaults; every run's `thresholds:` line shows their source. A pointer
(`see docs/…`), a commit SHA or a ticket key is never narration. The file header and blocks that
open with `Oracle:` or `dual-oracle` are exempt from `L`, not from `N`. Unaudited languages
(Markdown, JSON, YAML …) report `n/a`. Exact patterns: `~/.zuvo/comment-audit --help`; full
reference: `docs/comment-pass.md` in the zuvo repository.

## What to do with each comment

| Kind | Which comments | Action |
|---|---|---|
| **KEEP** | the non-obvious WHY, a constraint or invariant, a pitfall, a contract; the `Oracle:` / `dual-oracle` and derivation comments rules/testing.md asks tests to carry; what CQ13 calls explanatory comments, API examples and documented workarounds | keep; shorten only to clear `D` or `L` |
| **MOVE** | history: dates, incidents, measurements, how the code used to be | into the commit message this skill is about to write (a runbook only when that file is itself in scope, and so audited too); leave at most a one-line `see <path>` pointer |
| **DELETE** | a comment that restates the code next to it; commented-out code (CQ13 dead code) | delete |
| **TEST-OR-GO** | QUANTITATIVE claims only — a number with a unit, `within` / `at most` / `at least <n>`, `guarantee` — every `CHECK` line | add a test that pins the number, or take the number out of the comment; bare "always" and "never" are not claims |

**CQ13 and this pass.** CQ13 in the gate registry already rules commented-out code dead code and
protects explanatory comments, API examples and documented workarounds. This pass neither restates
nor redefines it: it measures what CQ13 does not — how much of what a run wrote is comment,
narration, blocks that outweigh their code — and makes the fix part of the run. Report them apart.

## Inputs (set by the calling skill)

- `COMMENT_BASE` — the commit HEAD pointed at before the run's first write (or the skill's snapshot
  of a dirty tree); in an unborn repository the empty tree (`git hash-object -t tree /dev/null`).
  It equals `HEAD` until the run commits; after that `HEAD` hides its lines (they report `unchanged`).
  The skill prints the resolved value once and passes that literal: a shell variable dies on resume.
- `COMMENT_SCOPE` — every file this run created or modified, production and test, as paths from the
  repository root. Mechanical, never from memory: the skill's own record of written files, CHECKED
  against `git status --porcelain --untracked-files=all` (plus `git diff --name-only "$COMMENT_BASE"`
  once committed); porcelain C-quotes paths with special characters, so compare them unquoted (the
  helper accepts C-quoted paths), and a rename record `R old -> new` lists both paths. A recorded
  path git does not list is a wrong record — find the missing write — unless it is gitignored, or
  the run deleted it or reverted it to the base: such a path drops out of the scope, because it has
  nothing to audit. Git never adds paths: a listed path the run did not write (pre-existing WIP)
  stays out, while pre-existing edits inside a scoped file count as authored lines unless the base
  is a snapshot. Every file a fix creates or edits (a new test, a test TEST-OR-GO extends) joins it.

## Sequence

1. **Nothing written** — the record is empty and git confirms it → print
   `[GATE: comment-pass] N/A (no files written)` and return.
2. **One run over the whole scope**, from the repository root, each path quoted on its own:
   ```bash
   rc=0; ~/.zuvo/comment-audit --base "$COMMENT_BASE" --files "<path-1>" "<path-2>" --skill <skill> || rc=$?
   ```
   `<skill>` is the calling skill's name (`build`, `execute`, `review`, `refactor`, …); the ledger records it
   so `--trend --by skill` can say which skill ran it. It prints the table, findings, `CHECK` lines and, last, `RESULT: comment-pass …` and `comment_pass: …`.
3. **rc 1** → fix every finding per the table (MOVE, DELETE, cut a block to its WHY) and re-run the
   SAME command over the grown scope until rc 0; the exit valve below is the one exception. There is
   no iteration cap: a breach is fixed in-run, never backlog it and never hand it to a later skill.
   rc 1 only ever means findings (or a justification over the cap): the helper maps every error to
   rc 2, so a crash never reads as a breach.
4. **rc 0** → before any marker:
   - Settle every `CHECK` claim the run printed, rc 0 included, by TEST-OR-GO, then re-run step 2.
     A claim is settled once a test pins the number or the number is gone from the comment; a
     settled line may print again, so settle each claim once and list it in the final report as
     `CHECK settled: <file:line> test|removed|softened`.
   - `unchanged=` above 0 (a `WARN unchanged <path>` line each) means the base is wrong and blocks N/A
     and PASS alike: fix `COMMENT_BASE` and re-run, unless the path is shown not written (it leaves the scope).
   - The run must have a ledger row for every path in `COMMENT_SCOPE` (`ledger_path`: the env path,
     else `ZUVO_HOME`, else `~/.zuvo`); list the run's paths and compare them with the scope list:
     ```bash
     awk -F'\t' -v r="<id>" '$2==r {print $6}' "${ZUVO_COMMENT_AUDIT_LOG:-${ZUVO_HOME:-$HOME/.zuvo}/comment-audit.log}" | sort -u
     ```
     No row → the pass did not run: `[GATE: comment-pass] BLOCKED rc=0 no ledger row for run=<id>`.
     A scoped path without a row → the run missed part of the scope: re-run step 2 over the full
     scope. A PASS printed without this check is INVALID.
   - If the pass changed anything but comment lines (a test, code), re-run the calling skill's
     verification for those files.
   Then print the marker from the `RESULT:` line; `RESULT: comment-pass N/A` (no file in an audited
   language changed) prints `[GATE: comment-pass] N/A (run=<id> no audited source)`.
5. **Any other rc** → the invocation failed, not the comments — 2: a path outside the repository, a
   directory, a missing file, an unknown ref, an invalid environment value, an unwritable ledger;
   127: the helper or python is missing. Fix the invocation and re-run, or print
   `[GATE: comment-pass] BLOCKED rc=<n> <reason>`; the calling skill may not report completion.
6. **Recheck before staging.** If any file was changed or created after the last clean run, run
   step 2 again over the grown scope before `git add`; the marker carries the new run id.

**Justification is rare, bounded and true.** Only for a finding a reader of the code needs as it
stands — a date that is test data, a format example — never to keep history: re-run step 2 with
`--justify 'ID=REASON'` added per id (the id the helper printed, a reason of 20+ characters). The
reason lands in the ledger notes, so it must be true. At most `ZUVO_COMMENT_JUSTIFY_MAX` (default 2)
are accepted; any more make the run rc 1.

**Exit valve.** Findings that cannot be fixed without harming the code and exceed the justification
cap stop the run for a human: print `[GATE: comment-pass] BLOCKED rc=1 ids=<id,…> <reason>`.

## Marker

```
[GATE: comment-pass] PASS run=<id> files=<n> justified=<k>[ ids=<id,…>][ env=<NAMES>]
[GATE: comment-pass] N/A (<reason>)
[GATE: comment-pass] BLOCKED rc=<n> <reason>
```

- `run`, `files` and `justified` come from the `RESULT:` line of the last clean run; `ids=` lists
  the accepted justifications when `k` > 0; `env=` is copied from the machine line.
- These three are the only values. A breach has no marker of its own: it is fixed, then PASS.
- A PASS whose run id has no row in the ledger is INVALID.
- The agent never sets `ZUVO_COMMENT_*`. When the helper reports `env=`, a human set one: copy
  `env=<NAMES>` into the marker, which has no reason slot, and give that human's reason in the final
  report and the retro line; when the reason is unknown, ask the user or print BLOCKED.

**NO-SUBSTITUTION.** The gate is the helper's run, and its proof is the run id in the ledger. "I read
the comments and they look fine", "the diff adds few comments", "checked by hand", "ran it on the
files with findings", "the helper is missing, so I reviewed manually" — each is a substituted gate
→ INVALID. A missing helper is `BLOCKED rc=127 …`, never a hand check.

## Never

- Never set `ZUVO_COMMENT_*`: thresholds and the ledger path belong to the human running the session.
- Never split the scope into several runs, and never narrow it to the files that breach.
- Never edit carried comments — lines the run moved, which the helper does not judge.
- Never edit a file outside `COMMENT_SCOPE` to satisfy the helper; a file a fix creates or edits joins it first.
- Never park a finding in a backlog; the exit valve is the only way out without a fix.

## Freshness of other gates

A comment-only edit made by this pass after a cross-model review does not re-trigger that review:
the review judged the code, and the code did not change. An edit that changes code or adds a test
follows the calling skill's own re-review rule.

The blind-audit normhash ignores COMMENTS ONLY for python, php and the c-family (JS, TS, Go) — never
a python docstring, which is a string. In sh, bash, bats and ruby files, and for any docstring edit,
a change after the blind audit voids its CLEAN: re-run it per the calling skill's re-review rule,
or run this pass BEFORE the blind audit.

## Telemetry

- Paste the helper's last `comment_pass:` line verbatim into the retro's Telemetry block, on the line
  after `status:` — the markdown retro only; `retros.log` keeps its columns.
- Trend across runs and projects: `~/.zuvo/comment-audit --trend --days 30`; per calling skill: add `--by skill`.
- Semantic counterpart: adversarial code review item 12 checks a comment's claim against the code.
