## The review queue is retired, and each install cleans up after it

- `scripts/claude-home/scripts/post-commit-review-backlog.sh` is gone. Called from
  `~/.claude/hooks/post-commit`, it appended every commit to
  `~/.claude/projects/<repo>/memory/review-backlog.md` and to an untracked `docs/review-queue.md`
  in every repository with a `docs/` directory. Nothing read either file: review coverage is
  content-keyed (`memory/reviews/`). One workstation held 5,000+ of the first and 230+ of the second.
- `install.sh` no longer copies anything into `~/.claude/scripts` from `scripts/claude-home/`.
  Instead, every install runs `scripts/install.d/retire_review_queue.py`, which removes:
  - the one line that ran it from `~/.claude/hooks/post-commit`, when the script it runs is zuvo's —
    every other byte, the file's mode and a symlink to it are kept (zuvo did not write that dispatcher,
    and it still chains each repository's own post-commit hook). Where dropping the line would leave the
    file unparseable or empty, the line becomes the no-op `:`; a line that continues the one before it is
    left alone;
  - the installed copy of the script, when it is zuvo's and nothing calls it any more — a dispatcher line
    the cleanup does not recognise, or a repository's own post-commit hook that still calls it, keeps it
    (and is named), so no commit runs a missing file;
  - each generated memory backlog, and the `docs/review-queue.md` of the repository it was written
    for — only files still exactly in the script's format, not symlinks, and (for the queue) not
    tracked by git.
- Everything is copied into `~/.zuvo/archive/review-queue-retired-<UTC time>-<pid>.tar.gz` first and
  verified by content; when that fails nothing is deleted, and each file is judged again just before it
  goes. Kept files are named with the reason (edited by hand, tracked in git, a symlink), and a
  repository whose own post-commit hook still calls the script is reported, never edited.
  `python3 scripts/install.d/retire_review_queue.py "$HOME" --dry-run` lists what would go.
- The cleanup never stops an install: without python3, or when it fails, it warns once.
  `ZUVO_KEEP_REVIEW_QUEUE=1` skips it.
