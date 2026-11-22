## `zuvo:review` live-test defects fixed (three-model run: Sonnet 5.5, Codex Sol, Gemini Hydrogen)

- Skill: the severity rule now fences scope (a defect in code the diff does not touch is NIT/backlog, a
  defect on a changed line keeps its severity); verdict vocabulary is defined once (Run line vs artifact
  `verdict:`); the verify-audit example uses the finding shape the script parses; a harness that cannot
  write `.git` ends as `syntax-only` + WARN instead of a crash; Antigravity CLI is documented as having
  sub-agents; the Phase 0.5/0.6 cross-references and the closing-commit paths were corrected. The skill
  is not longer than before: history paragraphs were cut.
- `review-artifact-sync.sh` and the archive hook honour `ZUVO_HOME`; `--check` skips unmarked dated
  narrative reports.
- `verify-audit` parses a bare `R-1 [TAG]` header and rejects a "0 findings" pass over a transcript that has
  tagged findings.
- `compute-preload --lang` stops a root `package.json` from forcing the stack of a php/python/kotlin repo.
- `verify-review-claims.py` answers UNKNOWN for a transcript in no known format instead of a false
  DISAGREEMENT.
- `build-review-patch` leaves `zuvo/` and `memory/reviews/` untracked files out of the patch.
- `log-ideas --help` prints usage and writes no receipt.
