## verify-tests: coverageAnalysis is a choice, it is recorded, and perTest survivors say they are unconfirmed

- `verify-tests` hardcoded Stryker's `coverageAnalysis: perTest`. Under perTest, Stryker cannot link
  module-level code to a test, so some mutants reported as survivors are false. Nothing in the
  verdict or in `survivors.json` said so.
- New flag `--coverage-analysis off|all|perTest`. Without the flag, `ZUVO_VERIFY_COVERAGE_ANALYSIS`
  sets the mode, and the default is `perTest`. An invalid env value (the spelling is case-sensitive,
  so `pertest` is invalid) exits 2 before any work starts.
- The mode goes into the Stryker config. `off` and `all` each keep their own incremental cache,
  `<manifest>.stryker-incremental.<mode>.json`, so results measured under one mode are never reused
  under another. `perTest` keeps the old file name.
- A measured mutation line (PASS or FAIL), and so the manifest receipt, now ends with
  `[coverageAnalysis=<mode>]`, or `[coverageAnalysis=n/a (infection)]` for PHP. SKIP and ERROR
  lines carry no mode. The receipt reader checks only the prefix, so nothing else changes.
- `survivors.json` is now `zuvo-survivors/v2`. It keeps `count` and `obligation`, and adds:
  - a top-level `coverage_analysis`;
  - per row: `id`, `location`, `original` and `confirmation`. `original` is the exact replaced
    text, cut from the report's source using Stryker's 1-based UTF-16 columns. It is null when it
    cannot be cut exactly or is longer than 400 characters.
  - `replacement` is now the exact text, or null when it is over 400 characters. It used to be
    cut to 160 characters.
  - `confirmation` is `unconfirmed` under perTest, `not-required` under off and all, and `n/a` for
    Infection.
- Each perTest survivor gap now ends with the full reprobe command:
  `~/.zuvo/mutation-survivor-reprobe.sh --file … --original … --mutated … --test-cmd … --label <id>`.
  The values come from `survivors.json`. When the report has no exact text for a survivor, the gap
  says it cannot be reprobed from the report. Unconfirmed survivors still FAIL.
- `survivors.json` is written atomically. A failed write is now a gap that gives the error; it
  used to be silently dropped.
- `install.sh` now installs `scripts/mutation-survivor-reprobe.sh` into `~/.zuvo/` and checks the
  copy byte for byte, because the survivor gaps point to it.
- New mode `verify-tests --manifest <m> --record-reprobe <file|->` reads the KEY=VALUE output of
  `mutation-survivor-reprobe.sh`, one or more blocks, and matches each `label` to a row `id` in
  `<m>.survivors.json`. Only an `unconfirmed` row moves: SURVIVED with `restored=yes` sets
  `confirmed`; KILLED with `restored=yes` sets `refuted` and the note "killed by physical reprobe —
  a perTest false survivor; triage it"; ERROR or `restored=no` keeps `unconfirmed` and records the
  reason, and `restored=no` also prints a WARNING that the production file was left mutated. A row
  that is `not-required`, `n/a` or already labelled is reported and left as it is.
- Exit 0 when every label matched; 3 when the labels were written but a block reports
  `restored=no` (the production file still holds a mutant); 1 on an unknown label or a block whose `file=` is not the run's
  production file (nothing is written); 2 on unusable input: a block without a valid `verdict` or
  `restored`, the same label twice, input over 1 MiB, or a missing `survivors.json`. Input is read
  as bytes and decoded as UTF-8 with replacement, from a file or stdin. The file is rewritten
  atomically. `survivors.json` gains a top-level `production_file` (repo-relative) for that check.
- Only the label moves. The receipt, the pass state and each row's status are untouched, so a
  refuted survivor still fails the mutation check until it is triaged. Every mutation run rewrites
  `survivors.json` — a clean run writes it with `count: 0` — so a reprobe cannot relabel a survivor
  an earlier run left behind. A relative `file=` resolves against the repo root.
