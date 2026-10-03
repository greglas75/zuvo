# Comment pass

The comment pass keeps the comments a run writes **short and true**. A comment earns its place
when it says something the code cannot: WHY the code is shaped this way, an invariant, a gotcha, a
contract. History — dates, incidents, measurements, "previously …" — belongs in the commit message,
an ADR, a runbook or the retro, where it does not rot next to code that has moved on. A comment that
contradicts its code misleads an agent more than a human, because the agent trusts it.

The pass is deterministic: `~/.zuvo/comment-audit` audits only the lines a change **authored** and
fails (rc 1) on narration, on comment-heavy changes and on comment blocks longer than their code.
Skills run it in-run (procedure: `shared/includes/comment-pass.md`); the semantic counterpart — does
a comment's claim match the code — is item 12 of the adversarial code review.

## What it measures

**Authored lines** are the added lines minus the **carried** ones: an added line whose
whitespace-normalized text matches a removed line anywhere in the whole diff (other files and
untracked files included, one-to-one) was moved, not written. Only comment lines holding a word
character count.

| Kind | Rule | Affects rc |
|---|---|---|
| `D` density | authored comment lines / (authored comment + authored code); checked when the file has at least `ZUVO_COMMENT_MIN_LINES` (20) authored lines; breach when strictly above `ZUVO_COMMENT_MAX_DENSITY` (0.30). Whole-file density is reported, never gated. | yes |
| `N` narration | a narrative marker in authored comment text (comments, docstrings, trailing comments); one finding per block, the first family in table order wins | yes |
| `L` long block | a comment block of at least `ZUVO_COMMENT_BLOCK_MIN` (4) word lines that is longer than the code it describes | yes |
| `C` claim | a quantitative claim, printed as `CHECK path:line "<text>"` for a test or a rewrite | no |

**N families.** Before matching, path-like tokens, backticked spans and quoted literals are removed,
so a pointer (`see docs/…`), a commit SHA or a ticket key is never a marker — a pointer is what a
moved comment leaves behind. Matching is case-insensitive unless noted.

| Family | Markers |
|---|---|
| `N-date` | ISO `2026-09` / `2026-09-14`; month name or 3-letter month + year (`Jan 2026`, `Sept. 2026`) |
| `N-history` | previously, formerly, originally, used to, until recently, at the time, back then, historically, we changed/switched/moved/replaced/removed, was changed/replaced/removed/introduced, changed/switched/migrated from, in the old/previous version/code/implementation |
| `N-incident` | post-mortem, postmortem, hotfix; incident/outage followed within 300 characters by a date or an issue number `#123` |
| `N-measured` | a capitalized `Measured on/at/over/across/by` (case-sensitive: a sentence that reports a measurement), `(measured on/at/over/across/by`, benchmark(ed) showed/shows/on, we saw/observed/measured, empirically |
| `N-pl` | wcześniej, poprzednio, incydent…, zmierzon… (not when followed by `w <path>`) |

`comment-audit --help` prints the exact patterns.

**L, the described code.** A block is a maximal run of comment-only lines; it is in scope when at
least half of its word lines are authored. The code it describes is:

- for a docstring, or a block right above a `def`/`class`/`function`/`func` signature (decorators
  skipped), the definition body;
- otherwise the code run after it (one blank line skipped), up to the next blank or comment line —
  or, when the run's first line leaves a bracket open (`it('…', () => {`, `const f = (x) => {`,
  `f() {`, `x = dict(`), through the line that closes it, whichever is longer. Brackets are counted
  on code only: quoted strings on the line and its trailing comment are removed first. A bracket
  that never closes is no construct, and the code run alone is measured.

Exempt from `L` (never from `N`): the **file header** — the first comment block when only the prelude
(shebang, polyglot line, `<?php`, `package`) precedes it, or the prelude and import lines with a
blank line (or the end of the file) after the block — and blocks whose first line starts with
`Oracle:` or `dual-oracle` (rules/testing.md asks for them). Import lines are `import …`,
`from x import …`, one-line `export * from` / `export { … } from`, `const … = require(…)`,
Ruby `require` / `require_relative`, PHP `use A\B;`, and shell `source file` / `. file`; a
multi-line `import {` / `from x import (` runs to its closing bracket.

**C claims:** number + unit (`ms`, `s`, `sec`, `min`, `h`, `KB`, `MB`, `GB`, `retries`, `attempts`,
`times`), a percentage, `within|at most|at least|up to <n>`, `guarantee(s|d)`. Bare `always` and
`never` are not claims.

**Pragmas are code**, never comments: `@ts-expect-error`, `@ts-ignore`, `@ts-nocheck`,
`eslint-disable…`, `eslint-enable`, `prettier-ignore`, `istanbul ignore`, `c8 ignore`,
`@vitest-environment`, `@jest-environment`, `/// <reference`, `//go:build`, `//go:generate`,
`//nolint`, `# noqa`, `# type: ignore`, `# pragma: no cover`, `# shellcheck`, `# -*- coding`,
`# fmt: off|on`, `@phpstan-`, `@psalm-`.

**Languages:** python (`.py`, or a python shebang/polyglot), the hash family (`.sh .bash .zsh
.bats`, sh shebangs), ruby (`.rb .rake`), and the c family (`.js .mjs .cjs .jsx .ts .tsx .mts .cts
.go .php`). Anything else (`.md .json .yaml .vue .svelte .astro` …) is reported `n/a`. A file over
2 MB is `n/a (too large)`.

**Finding ids** are content-keyed: `N:<path>:<sha1(block text)[:8]>`, `L:<path>:<sha1[:8]>`,
`D:<path>`. Line numbers are printed but are not part of the id.

## Usage

```bash
comment-audit [--base REF | --range A..B] [--files PATH ...] [--justify 'ID=REASON' ...] [--json]
comment-audit --trend [--days N | --since YYYY-MM-DD] [--project NAME] [--markdown]
```

| Option | Meaning |
|---|---|
| `--base REF` | working tree + index against `REF` (default `HEAD`), a commit or a tree such as the empty tree (`git hash-object -t tree /dev/null`); untracked, non-ignored files count as fully added; an unborn `HEAD` compares against the empty tree |
| `--range A..B` | `A` (a commit, or a tree such as the empty tree) against commit `B`; post-images are read from `B`, never from the working tree |
| `--files PATH ...` | audit only these paths (relative to the cwd). Skills always pass it; carried lines still come from the whole diff |
| `--justify 'ID=REASON'` | keep one finding (see below) |
| `--json` | one JSON object instead of the table |
| `--trend` | density and findings per project from the ledger |

There are no threshold, skip, warn-only or no-ledger flags: thresholds come only from the environment.

## Environment

| Variable | Default | Valid |
|---|---|---|
| `ZUVO_COMMENT_MAX_DENSITY` | 0.30 | float, 0 < x ≤ 1 |
| `ZUVO_COMMENT_MIN_LINES` | 20 | integer ≥ 1 |
| `ZUVO_COMMENT_BLOCK_MIN` | 4 | integer ≥ 2 |
| `ZUVO_COMMENT_JUSTIFY_MAX` | 2 | integer ≥ 0 |
| `ZUVO_COMMENT_AUDIT_LOG` | `${ZUVO_HOME:-$HOME/.zuvo}/comment-audit.log` | path |

An empty variable is unset; an invalid one is rc 2. Every run prints
`thresholds: density=0.30(default) min_lines=20(default) block=4(default) justify_max=2(default)`;
when any threshold comes from the environment, both machine lines carry `env=<NAMES>`.

## Exit codes

| rc | Meaning |
|---|---|
| 0 | clean: no unjustified finding (also when every file is `n/a` or `unchanged`) |
| 1 | at least one unjustified `D`/`N`/`L` finding, or a justification over the cap |
| 2 | usage, environment, git or ledger error, a `--files` path that cannot be read, a python older than 3.8 (the polyglot header checks before any import), or any internal error — never a breach |
| 127 | no `python3` or `python` on `PATH` (from the polyglot header) |

## Output

A table `FILE LANG AUTH_CODE AUTH_CMT DENSITY FILE_DENS N L C VERDICT`, then one line per finding
`path:line RULE ID "<first 60 chars>" -> <hint>`, the `CHECK` lines, `WARN stale justification <id>`
lines, one `WARN unchanged <path>: base wrong or file not changed by this run` per file in scope that
the diff does not touch, the `NOTE` lines below, the `thresholds:` line, and the two machine lines,
always last:

```
RESULT: comment-pass PASS|BREACH|N/A run=<id> files=<n> findings=<m> justified=<k>[ env=<NAMES>] unchanged=<u>
comment_pass: run=<id> files=<n> max_density=<x|-> narrative=<n> long=<n> density_breaches=<n> claims=<n> justified=<k> verdict=<pass|breach|n/a>[ env=<NAMES>] unchanged=<u>
```

`unchanged=<u>` is always the last field: an `N/A` with `unchanged=` above 0 means the base hides the
run's lines (a wrong base), not that nothing was written.

Under `--base`, untracked files compete for carried lines whenever the diff removes a line. A file
`--files` names is always read for that; every other untracked file is read within a 64 MB budget,
and the files past it print `NOTE carried pool truncated: <n> untracked files not read (budget)` (their
lines then count as authored, never as carried). Only the rows whose text matches a removed line are
kept in memory. An untracked file outside `--files` that cannot be read prints
`NOTE skipped unreadable <path>: <reason>` and does not fail the run; without `--files` it is also a
row with the verdict `n/a (unreadable)`. A path `--files` names that cannot be read is rc 2.

The run id is `<UTC yyyymmddTHHMMSSZ>-<pid>`. Skills paste the `comment_pass:` line into the retro
narrative. A file's verdict is `pass`, `breach`, `justified`, `unchanged`, `deleted`, `n/a` or
`n/a (<reason>)`.

`--json` prints one object and nothing else on stdout: `run, base, range, thresholds{name:{value,
source}}, files[{path, lang, authored_code, authored_comment, carried, density, file_density, verdict,
degraded, findings[{id, rule, sub, line, text, hint}], claims[{line, text}]}], justified[{id, reason}],
rejected[{id, why}], stale[id], verdict, rc, retro_line`.

## Ledger

Every run appends one TSV row per audited file to `ZUVO_COMMENT_AUDIT_LOG` — in one `write()`,
`O_APPEND`, under `flock` where available. The file starts with `# comment-audit ledger schema=1` and
a header; the 21 columns are:

`date run project head7 base7 file lang authored_code authored_comment carried density file_density
narrative long claims density_breach justified verdict blob thresholds notes`

`project` is the basename of the main checkout (a linked worktree reports its main checkout), `blob`
the `git hash-object` of the audited post-image, `notes` the accepted justifications. Readers keep
only rows whose first column is a timestamp. A ledger that cannot be written is rc 2: a pass with no
row is not proof of a run.

## `--trend`

```
$ comment-audit --trend --days 30
trend: since=2026-09-02T19:25:33Z project=* rows=62788 skipped=0 ledger=…/comment-audit.log
PROJECT              RUNS  FILES  GATED  DENS_P50  DENS_P90  FILE_P50  AUTH_CMT  D     N     L     JUSTIFIED
repo-01              2     84     52     0.057     0.207     0.071     332       2     14    0     0
```

One row per project: runs, measured files, files with a gated density, authored-density p50/p90,
whole-file density p50, authored comment lines, finding counts and justifications. `--since` takes
a UTC day, `--project` filters, `--markdown` prints a Markdown table.

## Justification

`--justify 'ID=REASON'` keeps one finding. The id is split after its 8-hex hash (a path may hold
`=`); the reason needs at least 20 characters, and tabs, CR, LF and `|` in it become spaces.
Justifications are accepted in argument order up to `ZUVO_COMMENT_JUSTIFY_MAX`; the rest are
rejected and the run is rc 1. An id that matches no current finding prints
`WARN stale justification <id>` and uses no slot; a second justification of the same id is rejected
without breaching. Accepted ids appear in the table, JSON, the ledger `notes` and both machine lines
(`justified=<k>`). There is no inline suppression marker and no repo-level justification file —
justify rarely, and only what a reader of the code needs.

## Known limits

- In sh, a `#` at word start inside backticks is read as code.
- A multi-line JSX attribute string marks the file `degraded`.
- Ruby `puts %w[a #b]` reads the `%` as modulo.
- A continuation line after `cat <<EOF \` is read as heredoc body.
- PHP HTML `<!-- -->` outside `<?php` counts as markup (code), not as a comment.
- Bracket counting (the decorator skip, multi-line imports, the construct measure of `L`) removes
  quoted strings line by line only: a string that spans lines (a template literal, a triple-quoted
  or heredoc string) still counts its brackets.
- Import lines not recognised, so the block after them is measured, not exempt: PHP `namespace`,
  `require_once` and `include`; a multi-line `export { … } from`; an import continued with a
  backslash; Rust-style `use a::b;`.
- An issue number anchors `N-incident`, so a hex colour such as `#000` within 300 characters after
  "incident" is read as one — an accepted false positive; justify it.
- Quoted literals are removed line by line, so a quote that wraps onto the next line keeps its
  words: a line ending in `"we saw …` whose closing quote is on the next line reads as `N-measured`.
- `N-date` cannot tell a date that is data from a date that is history: a test oracle such as
  `3 Mar 2021` and a format example in non-ASCII quotes (`„2024-01-31”`) are flagged — justify them.
- `wcześniej` also means "earlier" in a comparison of time, not only "previously".
- `L` undercounts the code when a comment heads the rest of a test body that blank lines split, a
  section header covers several functions, or a python `try:`/`if:` body holds a comment line.
- `--range` fails closed (rc 2) on a changed path that contains a newline.
- A `degraded` file (the scanner fell back to a simpler reader) is judged like any other; read a
  breach on a degraded file with that in mind.
- Working-tree blob ids hash the raw bytes (no clean filters), so they can differ from the id git
  would store.

## Baseline, 2026-10-02

Measured on the sessions host, read-only, with the shipped patterns (after the calibration below):
every main checkout of the owner's workspace with a commit in the last 30 days (linked worktrees
skipped), each with `--range "<base>..HEAD"`, base = `git rev-list -1 --before='30 days ago' HEAD`,
and a scratch ledger. Private repositories are anonymized as `repo-NN`. **files** = files with a
measured verdict; **dens p50/p90** over files with ≥ 20 authored lines; **over 0.30** = breaching
files / gated files; **N/100** = N findings per 100 authored comment lines; **file dens p50** =
whole-file density.

<!-- baseline:start -->
| repo | date | head7 | files | dens p50 | dens p90 | over 0.30 | N/100 | L | file dens p50 |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| repo-01 | 2026-10-02 | e24d841 | 42 | 0.06 | 0.21 | 1/26 | 4.2 | 0 | 0.07 |
| repo-02 | 2026-10-02 | 4dfdc7c | 24 | 0.05 | 0.15 | 0/14 | 0.8 | 1 | 0.03 |
| repo-03 | 2026-10-02 | ff63024 | 49 | 0.05 | 0.23 | 2/33 | 0.0 | 1 | 0.05 |
| repo-04 | 2026-10-02 | 3be6117 | 51 | 0.06 | 0.19 | 1/32 | 0.5 | 0 | 0.05 |
| repo-05 | 2026-10-02 | ed2c9c0 | 2 | 0.19 | 0.59 | 1/2 | 2.2 | 4 | 0.23 |
| repo-06 | 2026-10-02 | 2521510 | 105 | 0.07 | 0.29 | 2/47 | 0.6 | 4 | 0.05 |
| repo-07 | 2026-10-02 | 95e26a5 | 10819 | 0.08 | 0.32 | 866/7576 | 1.8 | 2142 | 0.05 |
| repo-08 | 2026-10-02 | 3e06214 | 224 | 0.14 | 0.32 | 19/170 | 0.9 | 199 | 0.10 |
| repo-09 | 2026-10-02 | 40ac6cd | 987 | 0.30 | 0.61 | 467/936 | 0.9 | 2330 | 0.30 |
| repo-10 | 2026-10-02 | 348032f | 2306 | 0.02 | 0.31 | 140/1336 | 1.8 | 323 | 0.03 |
| repo-11 | 2026-10-02 | 91eb105 | 68 | 0.08 | 0.21 | 0/45 | 1.6 | 0 | 0.06 |
| repo-12 | 2026-10-02 | ce1b64a | 59 | 0.09 | 0.19 | 1/36 | 1.3 | 0 | 0.06 |
| zuvo-plugin | 2026-10-02 | ac46164 | 220 | 0.23 | 0.50 | 65/174 | 2.3 | 351 | 0.23 |
| repo-13 | 2026-10-02 | c4a10c7 | 10 | 0.16 | 0.39 | 3/10 | 3.4 | 0 | 0.16 |
| repo-14 | 2026-10-02 | 71e55e0 | 203 | 0.15 | 0.34 | 27/187 | 0.4 | 93 | 0.15 |
| repo-15 | 2026-10-02 | 1e2eebe | 109 | 0.05 | 0.12 | 0/85 | 1.6 | 5 | 0.06 |
<!-- baseline:end -->

`repo-13`, `repo-14` and `repo-15` have their whole history inside the window, so their base is the
empty tree. Two rows (`repo-07`, `repo-10`) are clones of the same repository on different
branches, so they overlap. Every run took 30 s or less.

For the 13 repositories measured before the calibration, the first run gave 3049 N and 6278 L
findings; the shipped patterns give 2951 N and 5355 L. The three empty-base repositories, measured
afterwards, add 44 N (32 `N-date`, 12 `N-history`) and 98 L — under 3% of any family, so the
precision below stands without a new sample. Counting brackets on code only (strings and trailing
comments removed, an unclosed bracket falling back to the code run) added back 11 L across three of
the repositories; the table shows those counts.

## Calibration, 2026-10-02

Findings from the first baseline were sampled across the 13 repositories it covered (seeded,
stratified by repo, deduplicated across the two clones; the "as shipped" re-samples landed in 6 of
them) and judged by reading each comment in context. True for `N`:
the marked words narrate something that belongs in git history, an ADR or a runbook. True for `L`:
the block really is longer than the code it describes. A family under 70% precision was narrowed,
with the false positives added as test fixtures first, and the baseline above was re-measured.

<!-- precision:start -->
| family | sampled | true | precision |
|---|---:|---:|---:|
| N-date | 32 | 28 | 88% |
| N-history | 24 | 21 | 88% |
| N-measured | 32 | 18 | 56% |
| N-incident | 12 | 0 | 0% |
| N-pl | 26 | 22 | 85% |
| L | 40 | 24 | 60% |
| N-measured, as shipped | 20 | 20 | 100% |
| L, as shipped | 24 | 18 | 75% |
| N-incident, as shipped | 0 | 0 | no finding in the re-measured baseline |
<!-- precision:end -->

The "as shipped" rows are fresh samples from the re-measured baseline, not the first sample re-read.

`no longer`, a candidate for `N-history`, was checked and not added: of 20 comment rows sampled
from the 660 that say it in the files this window touched, 7 (35%) narrate a change; the rest state
a runtime fact (a record that no longer exists, a value that no longer matches).

[DECISION: rule-calibration] → changed: N-incident, N-measured, L

- **N-incident** (0 of 12). `field run|failure|report|data` is everyday vocabulary in survey
  research (fieldwork reports and field data, not field failures), and requirement or backlog ids
  near a hypothetical outage or a "not an incident" remark anchored the rest. Removed: the
  `field …` alternative and the `[A-Z]+-\d+` anchor. Kept: post-mortem, hotfix, and incident/outage
  with a date or `#123`.
- **N-measured** (18 of 32). Inline `measured on|over|by` mostly defines a metric or a computation
  (how a gap or a duration is measured, "`end_lineno` MEASURED by `entry_block`"), and `turned out`
  describes the outcome a value represents: 3 of 9 true. Narrowed to a capitalized
  `Measured on|at|over|across|by` and the parenthesised form; `turned out|it turns out` removed. The
  true ones report a measurement: "Measured across 33 scored runs on one file: …", or a
  parenthesised note that a failure was measured on CI.
- **L** (24 of 40). The described code was undercounted: a block above `it('…', () => {`,
  `describe(…)`, an arrow function or `try {` was compared with the first lines up to a blank, and a
  test file's description right after its imports was compared with the first statement. Now a
  bracket left open on the first code line extends the described code to its closing line, and the
  first block after the imports is the file header when a blank line follows it. Typical true
  findings: a 15-line docstring over a 5-line function, 7 lines over a one-line constant, 4 lines
  over one entry in a list.
- **Unchanged.** `N-date` false positives are data dates: a date computed in a test oracle and a
  format example in `„…”` quotes; true ones carry provenance (an audit or an observation with its
  date, "since <date> …"). `N-history` false positives describe present semantics (a URL that "was
  removed" on purpose, "can be changed from"); true ones tell how the code used to be ("it used to
  be `timeout 1 head -c 1`"). `N-pl` false positives use `wcześniej` as "earlier in time" (an event
  a second earlier); true ones are "Zmierzone: …" results and "Wcześniej …" history.
