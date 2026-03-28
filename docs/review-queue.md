# Review Queue

Commits pending review. Auto-managed:
- post-commit hook → adds new commits
- `/review` after audit → removes reviewed commits
- `/review mark-reviewed` → removes in bulk

- 44bb650 (2026-03-27) docs: add full documentation — getting started, pipeline, skills, quality gates, codesift, config
- ba7bd78 (2026-03-27) feat: release script + auto-update docs
- 134d770 (2026-03-27) docs: update review queue
- ff47480 (2026-03-27) feat: run logger — centralized skill usage log at ~/.zuvo/runs.log
- 2876e97 (2026-03-28) feat: add Codex platform compatibility layer
- 61b87e4 (2026-03-28) fix: clean Claude-specific refs from Codex build output
- e88f760 (2026-03-28) fix: preserve YAML multiline descriptions in Codex build
- f8370c3 (2026-03-28) fix: improve skill clarity and Codex compatibility
- 381696e (2026-03-28) feat: prefix all Codex skill names with zuvo-
- 1f1b352 (2026-03-28) fix: prefix descriptions with "Zuvo --" instead of changing names
- 88a6d97 (2026-03-28) feat: add 16 defensive code patterns to CQ rules
- 1df1411 (2026-03-28) feat: add defensive patterns for PHP, Python, and React
- e66787a (2026-03-28) docs: update CodeSift tools, quality gates AP25-29, pattern count
- 37cfebd (2026-03-28) feat: update write-tests skill + review queue
- 92d4486 (2026-03-28) docs: add docs-website-sync spec and plan
