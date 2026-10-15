# Backlog Persistence Protocol

> How Zuvo skills persist findings, track tech debt, and manage the project backlog.

## Where the Backlog Lives

The backlog file is `memory/backlog.md`. Which copy is THE backlog depends on whether git tracks it:

- **Tracked** — git tracks `memory/backlog.md` in the checkout you are in, as a regular file (not a
  symlink). That checkout's copy is the backlog for its branch: read, write and archive it there; it
  reaches main through the branch's merge like every other tracked file. A linked worktree's tracked copy
  is not a fork — the main checkout's working copy belongs to whatever is checked out there. Track
  `memory/backlog-done.md` beside it, or entries the archive moves stay in the worktree.
- **Untracked** — `memory/` ignored, not in git, or `memory/backlog.md` a symlink to the canonical file.
  There is exactly ONE backlog per repository, under the **MAIN checkout root**, never inside a linked
  worktree.

**Resolution (MANDATORY — worktree-safe).** `~/.zuvo/backlog-archive.py path --repo "$R"` applies this
rule (`zuvo_backlog_io.backlog_root`) and prints the `declared`, `real` and `archive` paths; the helper
calls below take `--repo "$R"` and resolve the same way. `R` is the repository root, assigned in the same
shell call as "The repository root" in "Filing from a skill" says; never `$PWD`, which the harness resets. By hand:

```bash
BACKLOG_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -z "$BACKLOG_ROOT" ] || ! git -C "$BACKLOG_ROOT" ls-files --error-unmatch -- memory/backlog.md >/dev/null 2>&1 \
   || [ -L "$BACKLOG_ROOT/memory/backlog.md" ]; then
  # Untracked: the main-checkout root. The first entry of `git worktree list` is ALWAYS the main
  # worktree, even when CWD is a linked worktree; `--show-toplevel` alone would fork an untracked
  # backlog (field incident 2026-07-19: 17 diverged copies per repo).
  BACKLOG_ROOT=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  [ -z "$BACKLOG_ROOT" ] && BACKLOG_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
BACKLOG="$BACKLOG_ROOT/memory/backlog.md"

# The archive (see "The Archive File") lives beside the REAL backlog, never beside a symlink to
# it. Measured 2026-09-18: six ~/DEV checkouts plus one project dir reach ONE canonical
# backlog.md through symlinks, and two of those directories are not git repos at all — so
# BACKLOG_ROOT degrades to `pwd` and `dirname $BACKLOG` is SIX different directories. Resolving here
# is what stops one archive becoming six. It is also why the helper writes onto the realpath: an
# atomic `os.replace()` onto the symlink would replace the link with a regular file and fork the
# 1.2 MB backlog into six copies — the 2026-07-19 incident, re-caused by the fix for it.
BACKLOG_REAL=$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$BACKLOG")
ARCHIVE="$(dirname "$BACKLOG_REAL")/backlog-done.md"
```

If `$BACKLOG` does not exist, create it with the template below. If the backlog is untracked, you are in a linked worktree, and an **untracked local** `memory/backlog.md` exists there (legacy fork), do NOT write to it — write to the main copy; migrate any entries the local fork has that the main copy lacks (dedupe by Fingerprint), then note the migration in the run output.

The main-checkout anchor is also the rule for the rest of the durable project-state family, `memory/ideas.md` and `knowledge/*.jsonl`, tracked or not (the tracked exception above is the backlog's and its `backlog-done.md`'s only). Per-run pipeline state (`zuvo/plans`, `zuvo/contracts`, `zuvo/context`) stays worktree-local by design.

## Persisting a finding: backlog-add

`~/.zuvo/backlog-add` is the one way a skill persists a finding: one call per finding, made by the
skill itself (the orchestrator, when it dispatched agents; a sub-agent reports its findings and never
calls it). Under one lock
it checks the cited code, decides the route, dedupes against both backlog files and the findings
ledger, and writes. Never append a finding to `memory/backlog.md` by hand: a hand append skips the
bars, the dedupe and the lock.

**Why.** A downstream intake files every open entry in `memory/backlog.md` as a ticket, so the file
must hold only work that becomes one. Measured on 2026-10-12: of 2,951 open zuvo-written entries the
intake retired, 1,345 were noise, 866 were already fixed and 740 cited files absent from the default
branch. So only BUG, SEC and DATA findings that clear their bar reach the backlog. Every other finding
at conf ≥ 26 is still kept, as data, in the findings ledger, where reports such as a duplicate-code
map are built from what has accumulated instead of from a fresh scan.

```bash
R='/abs/path/of/the/repository/root'   # same shell call as the command; "Filing from a skill"
~/.zuvo/backlog-add --repo "$R" --class BUG --conf 85 --source review \
  --file src/cart.ts --line 42 --anchor 'if (total > limit) {' \
  --title 'checkout accepts a total equal to the limit' \
  --evidence 'limit=100, total=100 passes; the order rules say strictly below' \
  --fix 'compare with >=' --severity high
```

| Argument | Required | What it carries |
|----------|----------|-----------------|
| `--class` | yes | one class from the bar table below |
| `--conf` | yes | an integer 0-100 |
| `--source` | yes | exactly `^(drive-by:)?[a-z0-9-]+$`: the skill's name (`review`, not `zuvo:review`), `drive-by:<skill>`, or `user` |
| `--title` | yes | the defect in one sentence (cut at 200 characters) |
| `--file`, `--line` | these, or `--target` | the cited site, repo-relative; the file must exist in the work tree |
| `--anchor` | BUG, SEC, DATA with `--file`; optional otherwise | text copied from the cited line, at least 8 non-space characters for BUG, SEC and DATA; when given, it must appear within ±3 lines of `--line`, whitespace-insensitive. On a hardcoded secret, copy the part before the value — the name and what precedes it (`AWS_SECRET_KEY =`, `const db_pw =`), still 8 non-space characters — never any character of the value; when the line has fewer than 8 before the value, copy a line within ±3 that holds no secret |
| `--target` | instead of `--file` | for a finding with no repository file: an `http(s)://` URL (stored without its query and fragment) or a hostname (any class; the bars still route it), or `subject:<slug>` (PROCESS, SEC only) |
| `--evidence` | with a URL or host target | what proves it (cut at 600) |
| `--fix`, `--severity` | no | the remedy (cut at 300); `critical`, `high`, `medium` or `low` |
| `--missing-assertion` | TEST-GAP, MUTATION only | the assertion the tests lack |
| `--also PATH:LINE` | no, repeatable | another site of the same finding (DUP) |
| `--pr N` | no | the PR to tag with (1–6 digits); `ZUVO_BACKLOG_PR` does the same |
| `--dry-run`, `--json` | no | write nothing and print the verdict it would give, with ` dry-run` appended (and `wrote=-` on the verdicts that carry `wrote=`); print the verdict as one JSON object |
| `--repo` | no, but a skill always passes `"$R"` | the checkout to file in; an existing directory inside a git work tree, resolved to that work tree's top level (a subdirectory works). Left out, it is the current directory, which the harness resets between Bash calls ("Filing from a skill") |

**The cited code must hold now.** "Holds" means the file exists in the work tree and the anchor is at
the line. Files the run created count, because skills write before they commit. A deleted file is
refused, and so is an anchor that is gone, which is how a finding fixed earlier in the same run is
kept out of the backlog. Such a refusal is not an input mistake: once a re-read confirms the code
changed, the finding is resolved and is neither filed nor reported as not persisted.

### Where a finding goes

Precedence, in this order:

1. Validation: a refusal is final.
2. The floor: below conf 26 a finding is discarded (`below-floor`; nothing is written), forced or not.
3. `ZUVO_BACKLOG_ADMIT=1` in the environment sends any class at conf ≥ 26 to the backlog. It is set
   only on the user's explicit request for a specific finding: the user sets it, or an agent sets it
   on the one call for the finding the user's own message asked to have filed. An agent never sets it
   on its own judgement. The one skill text that names it is the backlog skill's `add` mode, and only
   for the item the user's own message asked it to file; no other skill instructs it. Nothing in the shell can tell who typed it, so
   what keeps it honest is that every use stays visible. A first sighting it forces records
   `forced: true` and reason `forced`. A forced re-sighting of a finding already in the ledger records
   a status patch whose `note` is `forced (natural: <the reason the bars gave>)`, which the fold keeps
   as the record's note; the record's own `forced` and `reason` stay those of its first sighting. The
   `--json` verdict carries `forced: true` either way.
4. The bar table:

| Class | Backlog bar | Below the bar: ledger reason |
|-------|-------------|------------------------------|
| `SEC` | conf ≥ 26; below 51 the title is prefixed `(low confidence — verify manually)` | none, the floor discards |
| `BUG`, `DATA` | conf ≥ 80, and the anchor holds at the line | `conf-below-80` |
| `TEST-GAP`, `MUTATION` with `--missing-assertion` | conf ≥ 80, and the cited production line is in the branch diff (merge-base with the default branch to the work tree; an untracked file counts as changed). It lands as class BUG | `conf-below-80`, `mutation-not-on-changed-line` |
| `DUP`, `CPLX`, `SIZE`, `PERF`, `DEAD`, `READ`, `CQ`, `PROCESS`, and `TEST-GAP`, `MUTATION` without `--missing-assertion` | never: report-only | `class-report-only` |
| `ADVISORY` | never | `advisory` |

The ledger record's `reason` says which way it went: `admitted` (cleared its bar), `promoted` (a gap
that landed as BUG), `forced` (the env override), `branch-untaggable` (see the tag below), or the
ledger reason in the table. A promoted gap keeps the identity it had in the ledger, because the
identity is computed with its original class.

**CQ and Q gate findings are class `CQ`**, which stays in the ledger. File one as `BUG` only when you
can state the concrete input or state that produces the wrong output:

- `CQ`: "processOrder has no try/catch around the payment call" (CQ8). A rule is broken; no wrong
  output is named.
- `BUG`: "a declined card leaves the order in PAID: the payment error escapes before the status
  rollback at order.service.ts:91". Input, then the wrong state.

**The tag.** On a branch other than the default, the entry ends with `[pr:N]` (from `--pr`,
`ZUVO_BACKLOG_PR`, or the open PR `gh` finds on a github.com remote) or `[branch:<name>]`. The intake
takes a PR number of 1–6 digits, no leading zero; a branch name of 1–200 characters, all in
`[A-Za-z0-9._/-]`. It holds a tagged entry until that PR or branch merges and retires it when the PR
is declined, so a finding about unmerged code is never ticketed early. A PR `gh` reports past 6 digits
counts as no PR, so the entry waits as `[branch:<name>]`. A branch name with a character outside that
set, or longer than 200 characters, and no PR cannot be tagged: a non-SEC finding then stays in the
ledger (`branch-untaggable`), and a SEC finding lands untagged so it is ticketed at once. The name is never
rewritten, because a rewritten name resolves to no branch. A detached HEAD that is not on the default
branch has no name to tag with: it takes `--pr`, else it is untaggable too. The PR lookup asks `gh`
only on a github.com remote; with no `gh`, `gh` not authenticated, any other remote or
`ZUVO_PR_LOOKUP=0`, the tag is `[branch:<name>]`. On the default branch there is no tag. The default
branch is `ZUVO_DEFAULT_BRANCH`, else `origin/HEAD`, else `main`; set the variable where the
integration branch is `develop`, or entries filed there carry `[branch:develop]` and wait.

**The dedupe is done for you.** A finding's identity is `F-` plus 12 hex characters. For BUG, SEC and
DATA with an anchor it covers the class, the path and the normalised anchor, so two skills that
paraphrase one defect on the same code file one entry. For every other finding it covers the class,
the path and the first 8 words of the title. A `--target` finding uses the target, lowercased and
without a trailing `/`, where the path would be. The line number is never part of it.

Under the lock, `backlog-add` runs the `lookup` described in "How to Persist Findings" at most twice.
First on the entry's B-id: an open entry is bumped in place (`seen`, `conf`, date, sources); an
archived one is re-opened in the REGRESSION form. Only when that answers ABSENT, a second time on the
text a hand-written entry would start with, `<path>:<line> — <title>`: an open match is linked in the
ledger and its text is left alone (`BUMPED … legacy`); anything else appends a new entry. The line it
writes (a `--target` finding puts the target where `<path>:<line>` is):

```
- [ ] B-<stem>-<CLASS>-<fp8> <path>:<line> — [<CLASS>] <title> | evidence: <how> | fix: <fix> | severity: <sev> | source: <src> | conf: NN | seen: N | ledger: F-<12> | <YYYY-MM-DD> [pr:N]
```

### Verdicts and exit codes

One line on stdout; `--json` prints the same fields as one object, and `--dry-run` appends ` dry-run`.
A dry run writes nothing, so every verdict that carries `wrote=` shows `wrote=-`; `DISCARDED` and
`REFUSED` carry no `wrote=` at all.

| Verdict | Exit | What you do |
|---------|------|-------------|
| `ACCEPTED backlog <B> ledger=<F> wrote=<paths>` | 0 | Report it as filed under `<B>`. |
| `BUMPED backlog <B> seen=<n> ledger=<F> [legacy] wrote=<paths>` | 0 | A re-sighting of `<B>`. `legacy`: a hand-written entry was linked, not edited. A legacy entry with no id is named by its lookup key, `fp:<hex>`, in the line and in the `--json` `backlog` field, and the ledger record keeps no link to it; never treat `<B>` as a B-id without checking. |
| `REOPENED backlog <B> regression ledger=<F> wrote=<paths>` | 0 | Say REGRESSION in the report, not only in the backlog. |
| `LEDGER <F> reason=<r> wrote=<paths>` | 0 | Kept as data, not in the backlog. It is in the report when the report's own rules put it there. |
| `LEDGER-BUMPED <F> seen=<n> wrote=<paths>` | 0 | A re-sighting of a ledger record. |
| `DISCARDED below-floor` | 0 | Nothing written: under 26 is not a finding. |
| `REFUSED <reason>` | 3 | Correct the input (the refusal table below). |

| Exit | Means | What you do |
|------|-------|-------------|
| 0 | one of the six verdicts above `REFUSED` | Stage what `wrote=` lists. |
| 1 | lock timeout, IO error, `render-invisible`, lookup failure or incomplete install; stderr names which. Nothing was written, except after an IO error during the ledger append, when stderr names the backlog path already written as `wrote=` | If stderr says `failed after writing: wrote=<paths>`, the backlog entry exists and only its ledger record is missing: do not retry (a retry counts a second sighting); report it as filed, stage the listed paths, and the next sighting writes the record. Otherwise retry once after 2 s. If it fails again, list the finding in the report under `NOT PERSISTED (backlog-add exit 1)`. `render-invisible` (the rendered line would not parse back as one open entry) and an incomplete install fail the same way on the retry. |
| 2 | usage error: the call itself is malformed, or `--repo` is not a directory inside a git work tree | Fix the call. If you cannot, `NOT PERSISTED (backlog-add exit 2)`. |
| 3 | `REFUSED <reason>`: the input does not conform, and resubmitting it unchanged cannot help | An input mistake: correct it and resubmit once, otherwise list it under `NOT PERSISTED (REFUSED <reason>)`. Some refusals are not input mistakes, and the refusal table says what to do instead: `anchor-not-at-line` and `file-not-in-worktree` after a re-read, and the repository's visibility refusals. |

**`wrote=`** lists the repo-relative paths written that git does not ignore. A skill that commits
stages exactly those (`git add -- <paths>`); `wrote=-` means nothing to stage, as in a repo that
ignores `memory/`. Staging a path the verdict does not list is how an ignored file gets committed.

**The helper is missing** (only the Claude Code install ships `~/.zuvo/`): list every finding in the
report under `NOT PERSISTED (backlog-add missing)`. Never fall back to a hand append: without the bars,
the dedupe and the lock it files exactly the entries the intake has to retire.

| Refusal | What to correct |
|---------|-----------------|
| `missing-field:<f>` | Supply `<f>`: `class`, `conf`, `source`, `title`, `line`, `anchor`, `evidence`, or `file-or-target` (exactly one of `--file` and `--target`). |
| `bad-field:<f>` | A programmatic caller passed a non-text value. |
| `unknown-class` | Use a class from the bar table. |
| `bad-conf` | An integer 0-100. |
| `bad-source` | A lowercase skill name, `drive-by:<skill>`, or `user`. |
| `bad-target` | An `http(s)://` URL, a hostname, or `subject:<slug>`. |
| `bad-path` | `--file` with a control character, a `\|` or surrounding spaces; an `--also` without `:LINE`. |
| `bad-pr` | `--pr` or `ZUVO_BACKLOG_PR` must be a PR number of 1–6 digits, no leading zero. |
| `bad-combination` | `--file` with `--target`; `--missing-assertion` on a class other than TEST-GAP or MUTATION, or together with `--target`; `subject:` on a class other than PROCESS or SEC (a URL or host takes any class). |
| `path-outside-repo` | The path leaves the repository (`..`, an absolute path elsewhere, a symlink out). |
| `file-not-in-worktree` | The file does not exist in the work tree. If the path is right, the code is gone: nothing is filed or reported as not persisted. If the path was mistyped, correct it. |
| `line-out-of-range` | `--line` is not a positive integer, or is past the end of the file (an `--also` line too). |
| `anchor-not-at-line` | Re-read the code before deciding. If the defect is gone, it was fixed: nothing is filed or reported as not persisted. If it moved, resubmit with the new line. |
| `secret-like-value` | A field holds a credential shape (cloud or API key, token, private key). Cite its kind and location, never the value. |
| `tracked-findings-beside-ignored-backlog` | A property of the repository, not of the call: every call gets it until `memory/findings/` is ignored as the backlog already is. The remedy is the `.gitignore` recipe on stderr, and applying it is the user's decision, not the skill's. Do not resubmit; report the recipe once and every finding of the run under `NOT PERSISTED (REFUSED tracked-findings-beside-ignored-backlog)`. |
| `findings-visibility-unknown` | git could not say whether the ledger would be tracked (a git error or timeout; stderr has it). A repository state too: resubmit once at most, then report as above. |

### The findings ledger

`memory/findings/` sits beside the REAL backlog, by the same location rule, and holds one JSONL
segment per day, branch and host. Separate segments mean parallel branches and machines never write
one file, so a tracked ledger merges without conflicts. It is append-only: a finding's first sighting
is a full record, each later one a sighting line, and a change of status or backlog link a patch;
readers fold them. Field names follow the duplicate-code map's where the two overlap. The intake never
reads the ledger; reports do.

A repo that ignores its backlog file by file must ignore the ledger too: add `/memory/findings/` to
`.gitignore`. The ledger quotes every finding it keeps, so a tracked one would publish what the
ignored backlog keeps private; `backlog-add` refuses to write it.

**Known limits.**

- The text lookup computes a key from the candidate text and compares it with each entry's key. An
  entry the archive gave a minted id is keyed by that id, so the text never matches it, and an
  archived hand-written entry is only ever found by its id. The first `backlog-add` sighting of an
  issue filed by hand before can therefore file one new entry beside the old one.
- The tag says which branch saw a finding, not which branch introduced it. A defect in code the
  branch never changed, seen from that branch and filed with its tag, is held with the branch's PR
  and retired with it if that PR is declined, until a later sighting files it again.
- Only credential shapes are refused. PII such as an e-mail address is not scanned: keep it out of
  titles and evidence yourself.

## Filing from a skill

How a skill turns each situation into one `backlog-add` call. The bars, the dedupe, the tag and the
exit handling are the ones in "Persisting a finding: backlog-add"; this table only says which class,
source and location a skill passes. `<skill>` is the skill's own name (`review`, not `zuvo:review`).
Every call carries `--repo "$R"`, never `--repo "$PWD"`: `R` is the absolute path of the repository root the
run works in (in a linked worktree, the worktree's root), assigned in the same shell call as the command
("The repository root" below). The harness resets the shell's working directory between Bash calls, back to
the session's primary directory, so a `$PWD` read in a later call can name another checkout and the finding
is filed there, silently. Every free-text or externally sourced value is a double-quoted
variable assigned before the call (`"$T"`, `"$A"`, `"$E"`, `"$U"`, `"$F"`, `"$M"`: "Free text goes through a
variable" below); `<C>`, `<N>`, `<n>` and `<skill>` are fixed words or numbers the skill fills in.

| Situation | Class | Source | Location |
|-----------|-------|--------|----------|
| A finding in a file the run is editing, which the run defers | its class: `BUG` only when it names the input and the wrong output, else `CQ` or the class the finding is | `<skill>` | `--file "$F" --line <n> --anchor "$A"` (the location rule below) |
| A finding in a file the run is not editing | its class | `drive-by:<skill>` (`drive-by-findings.md`) | `--file "$F" --line <n> --anchor "$A"` (the location rule below) |
| A finding on a live page or host, with no repository file causing it | any class; the bars still route it, so a report-only class stays in the ledger | `<skill>` | `--target "$U" --evidence "$E"`, `U` a URL or a host (the location rule below) |
| A validity-gate item: an incomplete run, a skipped tier, an escape hatch taken | `PROCESS`, `--conf 90` | `<skill>` | `--target subject:<skill>-<gate>`, with no date in it and the gate's fixed title on every run, so a repeat bumps the one record (`LEDGER-BUMPED seen=N`); kept in the ledger only |
| A deferred decision, or follow-up work the run will not do | `PROCESS`, `--conf 90` | `<skill>` | `--target subject:<skill>-decision-<slug>`; the question as the title, both options in `--evidence "$E"` |
| A NIT at ship time | `CQ` | `ship` | `--file "$F" --line <n>`; it is recorded (the ledger keeps it), never ignored silently |
| An item the user files through the backlog skill's `add` mode | `BUG` when the user states the input and the wrong result, else `CQ`; `PROCESS` with `--target subject:<slug>` only for a process or decision item (for a code defect, the file and a verified line: the backlog skill's "Adding Items") | `user` | as the item says; `ZUVO_BACKLOG_ADMIT=1` only when the user invoked that mode in their own message |
| A finding this run fixed | none: no call | none | an open entry it resolved is closed (sentence 4 below) |
| A skill that commits after filing | none | none | it stages exactly the `wrote=` paths `backlog-add` printed, and nothing else |
| A source written `zuvo:refactor` or `zuvo:refactor/cq-auditor` | as the finding is | `refactor`; the agent's name goes in `--evidence` | as the finding is |
| A source written `test-audit/{date}` | as the finding is | `test-audit` | as the finding is |
| A source written `manual` | as the item is | `user` | as the item is |
| A source written `debug/[date]` | as the finding is | `drive-by:debug` | as the finding is |
| A source written `source:build` in a hand-written entry template | as the finding is | `build`; the template is gone | as the finding is |
| A black-box pentest finding, on a live target (formerly suggested as `--source pentest --dimension PT<n>`) | `SEC` | `pentest` | `~/.zuvo/backlog-add --repo "$R" --class SEC --conf <N> --source pentest --target "$U" --evidence "$E" --title "PT<n>: $T"`. `backlog-add` has no `--dimension` argument: the dimension lives in the title's `PT<n>:` prefix |
| A white-box pentest finding, traced to a file and line | `SEC` | `pentest` | `~/.zuvo/backlog-add --repo "$R" --class SEC --conf <N> --source pentest --file "$F" --line <n> --anchor "$A" --title "PT<n>: $T"`; the dimension again in the `PT<n>:` prefix |

**The location rule.** A record names either a file or a target, never both (`bad-combination`).

- A **file** record takes `--file` and `--line`. `--anchor` is required on a BUG, SEC or DATA file
  record (at least 8 non-space characters, refused `missing-field:anchor` otherwise); on any class,
  an anchor that is given must appear within ±3 lines of `--line`.
- A **whole-file** finding (a below-A test file, a skipped or blocklisted file, a file-wide CQ or Q
  violation, a file over its size limit, a missing test file for a source file) is a file record that
  cites `--line 1`, and its title starts "Whole file: …". Line 1 is the convention for "the whole
  file", never a guess at a location. A class with no anchor requirement (CQ, TEST-GAP, SIZE, …)
  passes no `--anchor`. A whole-file BUG, SEC or DATA needs an anchor within ±3 lines of its line, so
  it is filed at the line that shows the defect, not at line 1.
- A **target** record has no line, so no anchor is checked. A URL or host target needs `--evidence`
  (refused `missing-field:evidence` without it), whatever the class; a `subject:` target (PROCESS or
  SEC only) needs neither. Pass no `--anchor` with a target: on BUG, SEC and DATA a given anchor
  replaces the title as the record's identity, and nothing checks it.

**Free text goes through a variable.** A title, evidence, fix, anchor, file path or target taken from
a live page, a tool's output, a pentest response or the user's own words can hold a `'`, a `"` or a
`$(`, which ends a quoted argument or runs a command. Assign every `"$X"` argument of the call just
before it, one assignment per value, from a quoted heredoc, and pass the variable in double quotes;
never splice such text into single quotes. This form works in bash 3.2 (macOS `/bin/bash`, which
mis-parses quotes inside a heredoc nested in `$(…)`, so `T=$(cat <<'ZUVO_TXT' …)` is not used) and
in zsh:

```bash
read -r -d '' T <<'ZUVO_TXT' || true
<the title, verbatim>
ZUVO_TXT
read -r -d '' A <<'ZUVO_TXT' || true
<the anchor, copied from the cited line>
ZUVO_TXT
```

`read` drops leading and trailing whitespace and keeps everything else byte for byte; `|| true`
because `read -d ''` returns 1 at the end of the heredoc. The same two lines set `E`, `U`, `F` and `M` (the assertion the tests lack, for `--missing-assertion`).
The text must not hold a line that is exactly `ZUVO_TXT`.

**The repository root.** `R` is not free text, so it does not use the heredoc. Assign it in the SAME shell
call as the `backlog-add` command, like the other variables, as a single-quoted literal of the absolute
path of the repository root the run works in (`R='/abs/path/of/repo'`; a linked worktree's own root; a path
that holds a `'` uses the heredoc form above) or as `R=$(git -C '/abs/path/of/repo' rev-parse --show-toplevel)`.
Never `$PWD`, `$(pwd)` or the shell's current directory: it can be reset between calls, and a value assigned
in an earlier call is gone. The helper checks `--repo` is an existing directory inside a git work tree
(otherwise exit 2) and resolves it to that work tree's top level itself, so a subdirectory of the root
also works; the branch tag, the backlog and the ledger are those of that checkout. Without `--repo` it
files into whatever the current directory is, the very trap above.

**A process item keeps its first title.** Its identity is the class, the `subject:` target and the
first 8 words of the title, so pass the same title on every run (name the gate, not this run's
circumstances): a repeat then only bumps `seen` on the one record. A reason that changes from run to
run goes in that run's report, not in the ledger.

The sentences below are the text skills cite, `<skill>` replaced by the skill's name. Each command is
one code span, so it can be run as written once the variables are assigned and the placeholders
filled.

1. **Generic write.** Record it with `~/.zuvo/backlog-add --repo "$R" --class <C> --conf <N> --source <skill> --file "$F" --line <n> --anchor "$A" --title "$T"` (one call per finding; `backlog-protocol.md` "Persisting a finding"; `--anchor` is required on a BUG, SEC or DATA file record). The helper decides whether it reaches `memory/backlog.md` or only the findings ledger; report the B- or F-id it prints. On a non-zero exit act on the protocol's exit table; a finding still not persisted is listed under `NOT PERSISTED (<reason>)`, never appended by hand.
2. **Adversarial review.**
   - **WARNING**: fix if localized (< 10 lines). Otherwise record it with `~/.zuvo/backlog-add --repo "$R" --class <C> --conf <N> --source <skill> --file "$F" --line <n> --anchor "$A" --title "$T"` (`--anchor` is required on a BUG, SEC or DATA file record; `backlog-protocol.md` "Persisting a finding").
   - "Pre-existing" is NOT a reason to skip a finding. If the issue is in a file you are already editing, fix it now. If not, record it with `~/.zuvo/backlog-add --repo "$R" --class <C> --conf <N> --source drive-by:<skill> --file "$F" --line <n> --anchor "$A" --title "$T"` (`--anchor` is required on a BUG, SEC or DATA file record; `drive-by-findings.md`). The adversarial review found a real problem: don't dismiss it just because it existed before your changes.
3. **Process item.** Record it as a process item: `~/.zuvo/backlog-add --repo "$R" --class PROCESS --conf 90 --source <skill> --target subject:<skill>-<gate> --title "$T"`, with `T` the gate's fixed title, the same words on every run (`backlog-protocol.md` "Filing from a skill"). It is kept in the findings ledger, not ticketed; name its F-id in the report, with this run's reason, which never goes in the title. A deferred decision uses `subject:<skill>-decision-<slug>`, the question as the title and both options in `--evidence "$E"`.
4. **Closing, not removing.** Do not call `backlog-add` for a finding this run fixed. An open backlog entry the run resolved is closed, never removed: tick it and append its resolution marker (`[FIXED <sha7>]`) as `backlog-protocol.md` "How to Persist Findings" step 3 says; the archive helper moves it ("Archiving is done by the helper, never by hand"). For an audit's tier score: a Tier A score does not prove any one defect is gone: close only an entry whose cited code this run re-read and found fixed.

## Backlog Table Format

The template a new backlog file starts from. `backlog-add` writes its own checkbox line (above)
whatever format the file already uses, so `archive`, `verify` and `drop-stale` work on every entry it
files.

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
- **Category**: Rule family (CQ, Q, S, SA, DB, etc.); a drive-by entry uses its tag (SEC, BUG,
  SIZE, DUP, CPLX, PERF, DEAD, READ)
- **Source**: Which skill or agent produced this finding. An observation outside the task's fence
  carries the token `drive-by:<skill>` — the exact rule is in `drive-by-findings.md` step 2
- **Seen**: How many times this finding has been observed
- **Added**: Date first recorded

## How to Persist Findings

For each finding that should be tracked:

1. **Call `backlog-add`** ("Persisting a finding: backlog-add" above). It computes the finding's
   identity, runs the duplicate check below under its lock, and writes the entry or the ledger record.
   Do not compute a fingerprint or append an entry yourself.

2. **The duplicate check covers BOTH files.** `backlog-add` runs it for every finding; grooming,
   `zuvo:backlog` and anyone asking "is this already known?" run the same lookup by hand. The backlog
   namespace is two files: `$BACKLOG` (open) and `$ARCHIVE` (closed or deliberately withdrawn). An
   entry is defined in exactly one of them, never both.

   **The key.** The table above is the shape for a NEW file; every backlog in the fleet is `- [ ]`
   bullets with free-form `B-<slug>` ids, and 65% of open entries carry no id at all (measured:
   427 of 1211). So the key is computed, in this order:

   1. `id:<slug>` — the `B-<slug>`, lowercased, **only when the entry HEADS with it** (after
      `- [ ]`, `**`, `[`, or the `#`s of an ATX heading — see "The '## B-id' heading dialect" below).
      A definition, not a mention: 44 `B-*` tokens appear in both files of the largest backlog and
      only 5 are definitions — the other 39 are `see B-X` prose references.
   2. `fp:<sha1[:12]>` — otherwise, over a normalized signature: the first path-looking token plus
      the 8 words that FOLLOW it, lowercased, with everything that appears only on closure stripped
      first (the checkbox, `FIXED`/`DONE`/`RESOLVED`/`CLOSED`/`WONTFIX`/`OBSOLETE` in any wrapper,
      commit shas, branch names, `PR #NNN`, `conf: NN`, dates).

   **The id is the only key that reliably survives closure.** Measured on the five entries that
   were in both files: the id matched 5/5, the content key 0/5 — because closing an entry rewrites
   its text into a description of the fix, often in another language. Two consequences, both
   binding: archiving assigns an id to any entry that lacks one, and a resolution is **appended**
   to the original problem text, never written over it.

   **The lookup:**

   ```bash
   ~/.zuvo/backlog-archive.py lookup --repo "$R" "<candidate text or B-id>"
   ```

   One verdict line, one exit code, and what follows from it. `backlog-add` acts on the same verdicts
   with two differences: a bump never raises the severity, and an OPEN entry not in its own format (a
   hand-written one) is linked in the ledger and never edited at all.

   | Verdict | exit | What follows |
   |---------|------|--------------|
   | `OPEN <key> <id> backlog.md:<line>` | 10 | Update THAT entry in place — bump `Seen`/`conf:`, update the date, raise the severity if the new evidence is worse, add the new source. Never a second entry. |
   | `ARCHIVED <key> <id> backlog-done.md:<line> section="<heading>"` | 11 | **REGRESSION, not a new finding.** Re-open under the SAME id with the back-link (form below). Never mint a new id. |
   | `ABSENT <key>` | 0 | Genuinely new. Append one entry with a fresh id. |
   | `NO-SIGNATURE <query>` | 13 | The candidate has no words to key on — it is empty, or everything in it was stripped as a resolution marker (`**Closed:** 2026-08-18.`). Nothing was looked up. Fix the candidate text, or pass the B-id. Filing it as new would create an entry the next lookup cannot find either. |

   If `~/.zuvo/` is absent (only the Claude Code install ships it), there is no `backlog-add` either,
   so a finding is reported as not persisted rather than appended. The question "is this already
   known?" is still answered in BOTH files — with two greps, on the id or a distinctive PATH token,
   never a common word:

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

   **Re-opening an archived entry** — append to `$BACKLOG`, same id, one-way back-link. This is the
   form `backlog-add` writes on `ARCHIVED`:

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
   ~/.zuvo/backlog-archive.py archive --repo "$R" --dry-run   # always first
   ~/.zuvo/backlog-archive.py archive --repo "$R"
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

## The '## B-id' heading dialect

An entry is not always a bullet. Backlogs in this fleet also record a whole entry as an **ATX
heading plus prose** — `## B-driftguard-bounded-age — DONE`, then the paragraphs, file lists and
recipes under it. That is a definition, not a mention, and the lookup resolves it.

**What makes a heading an entry: the id, and nothing else.** A heading at any level `#`..`######`
is an entry exactly when the text after the `#`s is **id-shaped** — it HEADS with a `B-<slug>`, by
the same definition-vs-mention rule as item 1 of "The key" above. The rule is deliberately anchored
on the id so that it can only ever UNDER-cover: a heading that looks like an entry but carries no id
stays a non-entry (measured: 20 of 102 headings in this repo's own backlog), and a helper that
rewrites a tracked file under a lock is far better off missing an entry than inventing one. Four
shapes are therefore NOT definitions, and each has bitten: `## (closed) B-x` (parenthesised — a
mention), an **indented** `  ## B-x` (prose about an entry, inside a list), `## B-x <field> | <value>`
(a TEMPLATE documenting the format), and `## Archived from backlog.md on <date>` (the archive's own
section heading).

**Status comes from the END of the line, not the front.** These headings close with their marker —
`## B-x — DONE b9767b6a` — so the prefix-anchored test that reads a `- [x]` bullet sees nothing
(measured: 24 of 84 id-shaped headings carry a trailing marker, 0 carry a leading one). A **later**
`REGRESSION` marker outranks an earlier resolution and the entry reads OPEN again, which is the
re-open form this protocol already documents; the LAST marker on the line wins, so an entry that was
closed, re-opened and genuinely re-resolved is closed again.

**The boundary rule: reads see headings, writes do not.**

| command | sees a `#`-heading entry | why |
|---|---|---|
| `lookup`, `index` | YES | they answer "is this already known?" and neither writes the backlog. This is the whole point: answering ABSENT about an entry sitting in the file is what sends the next audit to re-file it as new. |
| `verify`, `drop-stale` | NO — checkbox entries only, always | they gate a run on an exit code, and no flag changes that |
| `archive`, `status` | NO **by default**; YES with `ZUVO_BACKLOG_HEADING_ARCHIVE=1` | they rewrite a tracked file, so the dialect they admit is opt-in — see the gate below |

The asymmetry is deliberate and it is not timidity. `install.sh` copies these helpers into the
machine-global `~/.zuvo/`, and `append-runlog` runs `backlog-archive.py archive` at the end of every
skill run **in every repo** — so a heading-admitting archiver starts rewriting tracked backlogs
across every checkout on the machine the moment it is installed, with no run having asked it to
(measured: 170-216 marker-carrying open heading entries fleet-wide). Moving a heading entry also
needs a block boundary the bullet path does not: a heading's extent ends at the next heading of its
own level or shallower **or** at the next flush-left checkbox entry, because the four independent
`- [ ]` entries that follow one such block in this repo's backlog are siblings, not continuation —
and a line-level conservation check cannot tell mis-attribution from a clean move.

So each of those four write and gate paths names `kinds=(zb.KIND_CHECKBOX,)` at its own call site
in `backlog-archive.py`, spelled out rather than defaulted, and `tests/hooks/test-backlog-headings.sh`
asserts the count of pinned sites mechanically — a new write path cannot join by omission.

**The one exception, and the reason it is opt-in.** `ZUVO_BACKLOG_HEADING_ARCHIVE=1` (exact string;
`0`, `true`, `2` and unset all mean off) lets `archive` move a **resolved** heading entry. It is the
family's only `iter_entries` call that may ask for `KIND_HEADING`, it lives in
`zuvo_backlog_heading.py` rather than in the archiver, and the mechanical guard above asserts exactly
one such site so a second cannot appear quietly.

Two things to know before setting it, neither of them theoretical:

- **It is process-global, so it is repo-global.** One `export` in a shell enables heading writes for
  every `backlog-archive.py` invocation that shell makes — and `append-runlog` invokes it in whatever
  repo the run happens to be in. There is no per-repo scoping today. Filed as
  `B-20260928-HEADING-GATE-PROCESS-GLOBAL`; until it is closed, set the variable **per command**
  (`ZUVO_BACKLOG_HEADING_ARCHIVE=1 backlog-archive.py archive --repo …`), never with `export`.
- **Run `archive --dry-run` first and read the count.** The gate changes which entries are movable, and
  a heading block carries its nested children with it. `--dry-run` prints `would move N`; if N is
  larger than the entries you meant to settle, the boundary is including something you did not intend.

**Consequences while the gate is OFF — which is the default and the state to assume.** A resolved
`#`-heading entry is found by `lookup` (so it is never re-filed) but is not archived, does not appear in
`status`, and cannot be settled with `drop-stale`:
tick it into a `- [x]` bullet, or close it by hand, if it must move. `verify` likewise does not
report a heading id that is defined in both files — the two-file disjointness gate is about the
checkbox namespace only.

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

**Every sibling beside the backlog inherits that visibility, and there are five of them.** The
refusal is per FILE, so a user who follows a message naming only some of them ends up with the rest
tracked — and the two ledgers are the ones that quote entry text:

| beside the real `backlog.md` | what it holds | `.gitignore` line, when the backlog is ignored |
|---|---|---|
| `backlog-done.md` | closed entries, verbatim | `/memory/backlog-done.md` |
| `backlog-verdicts.jsonl` | the **verdict ledger** — one judgement per line, with the evidence and the entry's `text_sha`; see `backlog-grooming.md` | `/memory/backlog-verdicts.jsonl` |
| `.backlog-archive.lock.d/` | the cross-process lock | `/memory/.backlog-archive.lock.d/` |
| `.backlog-index.tsv` | the lookup index | `/memory/.backlog-index.tsv` |
| `findings/` | the **findings ledger** — one JSONL segment per day, branch and host, holding every finding `backlog-add` kept; see "Persisting a finding: backlog-add" | `/memory/findings/` |

`backlog-archive.py archive` refuses to create a git-TRACKED archive beside a git-IGNORED backlog, and
`zuvo_backlog_ledger.py` refuses the same way for the verdict ledger, **naming the verdict ledger** in
its message.
`backlog-add` refuses a tracked `findings/` beside an ignored backlog, exit 3
`REFUSED tracked-findings-beside-ignored-backlog`, and prints the `.gitignore` lines to add.
None of these refusals is advice: each exits non-zero having written nothing. `is_ignored()` answers `None`
outside a git repository — the canonical backlog lives there — and "unknown" must never read as
"tracked", which is why both tests are `is False` and not a bare falsy check.

The verdict ledger is undated and is not `.md`, deliberately: it is structurally unable to be mistaken for one
of the banned whole-file snapshots above (`backlog-verified-stale-<date>.md` is literally one of them).
A snapshot is a copy of a file; the ledger is a list of judgements ABOUT one.

## Archiving is done by the helper, never by hand

`~/.zuvo/backlog-archive.py archive` is the only sanctioned way to move entries. Do NOT edit the two
files to do it, even when the edit looks trivial.

Measured, on 2026-09-21 at 18:49, in tgm-pulse: something other than the helper wrote that archive.
It copied the helper's heading format, counted LINES as items ("106 completed items moved out" for
three entries), and replaced the existing sections — including the quoted open copies a previous
`drop-stale` had preserved. A hand-written archive also has no lock, no byte conservation, no refusal
when the archive would be git-tracked beside an ignored backlog, and no id minted for an entry that
has none, so the next `lookup` for it misses.

The helper is one command and it prints what it did. Reach for it even for a single entry.

## When the same id is in both files

`backlog-archive.py verify` reports it and names each one; `~/.zuvo/append-runlog` refuses to log a
run that leaves the namespace inconsistent. Three outcomes, and the distinction matters because two
of them are NOT removals:

| what it is | how to tell | action |
|---|---|---|
| stale open copy | the archived copy declares the fix and describes the same defect | `backlog-archive.py drop-stale --id <ID>` |
| partial closure | the archived copy closes one part ("część A", "step 2") | mark the OPEN entry with the word `PARTIAL` (upper case, not part of an id) starting within its first 300 characters AND state `Remaining: <what is left>` anywhere in it; leave both — the gate exempts the pair only when both are there |
| genuine regression | it broke again after the fix | re-open per the REGRESSION form above; the pair is then legitimate and the gate exempts it |

`drop-stale` exists because "just remove the stale line" is riskier advice than it sounds: closing an
entry REWRITES it into a description of the fix, so the open copy is frequently the only place the
PROBLEM is stated. It therefore refuses unless the id is in both files AND the archived copy carries
a resolution marker, and it keeps the removed text in the archive as an indented quote — not as a
second `- [x]` definition, which the two-file check cannot see. It also refuses an open copy that
declares a REGRESSION or a PARTIAL closure: that copy is the live definition and the archived `[x]`
the stale one, so removing it would file live work as done. `groom apply` reports such an entry as
`no-remedy` instead of asking `drop-stale` for it.

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
in the archive before either rename, and only then replaces the realpath.

`backlog-add` holds the same lock across its lookups, its backlog write and its ledger append, so two
runs filing one finding at the same moment produce one entry and a sighting, never two entries. That
closes `B-backlog-flock` for every finding filed through it. A writer that still appends by hand is
not serialized, which is one more reason the protocol forbids it.

## Confidence-Based Routing

Every finding has a confidence level. It decides whether the finding is in the skill's report to the
user; the class bars in "Persisting a finding: backlog-add" decide whether it reaches the backlog or
only the findings ledger. The skill passes every finding at 26% or more to `backlog-add`, including
the 26-50% ones its sub-agents reported to it: a sub-agent's report goes to the orchestrator, and this
table is about what the orchestrator then shows the user.

| Confidence | In the report to the user | Where `backlog-add` keeps it | Rationale |
|-----------|---------------------------|------------------------------|-----------|
| 0-25% | no | nowhere (`DISCARDED below-floor`) | Likely hallucination or insufficient evidence. |
| 26-50% | no (a drive-by SEC finding is still listed by name, per `drive-by-findings.md`) | the findings ledger; a SEC finding also lands in the backlog, prefixed `(low confidence — verify manually)` | Real enough to keep as data, not confident enough to report. |
| 51-100% | yes | the backlog when its class clears its bar, the findings ledger otherwise | Actionable: reported, and ticketed when it is a defect. |

## Zero Silent Discards

This rule is absolute: no finding with confidence above 25% may be silently dropped. Every such finding reaches the findings ledger or the report, usually both.

A finding `backlog-add` did not persist (`NOT PERSISTED (…)`: refused and not correctable, a failed retry, or the helper missing) must be in the report, with that reason. That is the one case where the report is the only record, so leaving it out loses the finding.

A finding the code no longer supports is not dropped, it is resolved: when `backlog-add` refuses it with `anchor-not-at-line` or `file-not-in-worktree` and a re-read confirms the code changed, it is neither filed nor reported as not persisted.

## When to Run This Protocol

- After every audit skill completes (code-audit, test-audit, security-audit, etc.)
- After review agents report findings
- After execute phase quality reviewers flag issues
- When the user runs `zuvo:backlog` to manage existing items

## What Does NOT Go to Backlog

- Findings with 0-25% confidence (discarded as likely false)
- Findings whose class does not clear its bar: the report-only classes, ADVISORY, and BUG or DATA
  below 80%. They go to the findings ledger; `backlog-add` routes them there. Only the user's explicit
  request for that specific finding overrides it (`ZUVO_BACKLOG_ADMIT=1`, see "Where a finding goes"),
  never an agent's own judgement
- Style preferences without rule backing ("I'd prefer this naming")
- Suggestions for future enhancements without current violations
- Issues already fixed during the current session (no need to track what's already resolved;
  `backlog-add` refuses one whose anchor is gone with `anchor-not-at-line`)
