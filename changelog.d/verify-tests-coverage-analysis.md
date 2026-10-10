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
