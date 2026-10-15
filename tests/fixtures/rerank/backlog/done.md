# Backlog — done

## Archived 2026-10-06

- [x] B-20261005-CP-R-A2 A2 (30) zuvo_comment_scan.py:236-237: the PHP heredoc close row is not rescanned, so `EOT; // c` loses its comment. When php mode closes the heredoc, run `_scan` from the end of the delimiter. [FIXED fa403ffb]
- [x] B-20260927-REFGLOB-WARNING [P4][diagnostics][conf 100] [FIXED 6db03a36 — RD-1039: `[ -e ] || [ -L ] || continue` in all three loops; a dangling contract symlink is still reported]
