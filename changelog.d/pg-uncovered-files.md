## `~/.zuvo/pg-uncovered-files` — the push hint's full list is a real command

- New helper `pg-uncovered-files <base>..<head>`, installed to `~/.zuvo/`: prints the production
  files in the range that no review artifact covers, for the repo of the current directory
  (`PG_REPO_ROOT` overrides). Its status is the gate library's: 0 computed (empty output = all
  covered), 2 could not compute (usage, not a repo, bad range, failing git, library not found),
  3 no production file in the range. An option-shaped, three-dot or `..`-less argument is a usage
  error, never handed to git.
- `pg_uncovered_files` now answers 2 for an unresolvable base or a failing `git diff`; both used to
  read as 3 ("no production files"). `pg_changed_production` returns 1 when its git call fails; its
  other callers keep treating that as an empty change set.
- When a blocked push has more than ten uncovered files, the "Full list" hint now prints
  `'$HOME/.zuvo/pg-uncovered-files' '<range>'` as an absolute path (`~/.zuvo` is not on `PATH`)
  when the helper and `~/.zuvo/pipeline-gate-lib.sh` are both installed, and otherwise
  `bash -c '. "$1" && pg_uncovered_files "$2"' _ '<lib>' '<range>'`. Both forms single-quote their
  arguments, so a ref name holding quotes or `$( )` is pasted inert.
- `install.sh` now puts `pipeline-gate-lib.sh` and `path-contain.sh` flat in `~/.zuvo/`, beside the
  helpers that load them. On a fresh machine `~/.zuvo/review-artifact-sync.sh` had no
  `path-contain.sh` next to it, so every mode, `--check` included, exited 2. A missing or stale
  copy of either file now counts toward INSTALL INCOMPLETE.
