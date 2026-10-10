## mutation-test: report names that never overwrite

- New helper `~/.zuvo/alloc-report-stem --dir D --prefix P --scope S` allocates one stem for a
  report's `.md`, `.json` and `.report.json`. The stem carries the scope
  (`mutation-test-<date>-<scope-slug>`), moves to `-2` … `-99` when ANY sibling file already
  exists, and claims the name with an exclusive create, so two runs on the same day — sequential or
  parallel — never write over each other. The claim is always `.md` when it is in `--ext`, whatever
  the order. `--date` must be a real calendar day (local by default; checked by BSD date, GNU date
  or python strptime). Exit 1 when all 99 are taken, 2 on bad input or an unusable dir.
- `zuvo:mutation-test` §4.3b calls it instead of describing the name in prose, and stops when the
  helper is missing rather than falling back to a hand-picked name. Scope is the path argument,
  `full`, `branch-<branch>`, or `head-<sha7>` on a detached HEAD — in the filename only; the JSON
  `scope` stays the `[path]` or `full`, and a new `report_stem` field carries the stem. The stem is
  recorded in the run's state file so only `continue` reuses it, and a run that stops before its
  report is written releases the claim when every sibling file is still empty.
- Previously the name was left to prose ("auto-increment `-2`, `-3`"), so a second same-day
  session could take the bare `mutation-test-<date>` name and overwrite the first session's
  artifacts — the ones Q21 reads.
