## `zuvo:review` live-test defects fixed (three-model run: Sonnet 5.5, Codex Sol, Gemini Hydrogen)

- Skill: the severity rule now fences scope (a defect on lines the diff did not add or change, moved or
  extracted code counting as unchanged, is tier NIT with its true severity named and goes to the backlog,
  and overrides the CQ critical-gate bypass; a defect on a changed line keeps its severity); verdict
  vocabulary is defined once (Run line vs artifact `verdict:`; a failed gate is `FAIL` with NOTES
  `INCOMPLETE` and writes no content-keyed artifact, and neither does a run with no commit); the
  verify-audit example uses the finding shape the script parses; a harness that cannot write `.git` ends
  as `syntax-only` + WARN instead of a crash; Antigravity CLI is documented as having sub-agents; staged
  scope diffs with `--cached`; the Phase 0.5/0.6 cross-references and the closing-commit paths were
  corrected. The skill has fewer lines and words than before: history paragraphs were cut.
- `review-artifact-sync.sh` and the archive hook honour `ZUVO_HOME`; `--check` skips unmarked dated
  narrative reports.
- `verify-audit` parses a bare `R-1 [TAG]` header and rejects a report that has a tagged finding line it
  could not parse (a clean zero-finding report still passes).
- `compute-preload --lang` (comma-separated, validated) stops a root `package.json` from forcing the stack of a php/python/kotlin repo.
- `verify-review-claims.py` answers UNKNOWN for a transcript in no known format instead of a false
  DISAGREEMENT.
- `build-review-patch` leaves `zuvo/` and `memory/reviews/` untracked files out of the patch.
- `log-ideas --help` prints usage and writes no receipt.
