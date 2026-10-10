## One file over the adversarial cap is split at its hunks instead of being cut

- `adversarial-review.sh` used to chunk oversized input only at file boundaries, so a diff of a single
  file over the cap (30000 characters in code mode) was truncated: its tail hunks reached no reviewer,
  the run exited 4 and the proof recorded `input_truncated=true`, which the push gate refuses.
- A diff section over the chunk budget with two or more hunks is now split at its `@@` hunk headers.
  Every part repeats the file's diff header (`diff --git`, `---`, `+++`) and the file's
  `=== CONTEXT: … ===` block, if it has one, and holds as many whole hunks as fit. Each chunk's note
  says which hunks it holds ("hunks 1-2 of 3 of <path>", at most 400 characters).
- Input that is one diff file with two or more hunks now chunks, where it used to need two files.
- A single hunk larger than the cap still gets a part of its own, which is truncated and recorded as
  `input_truncated=true` (exit 4). The other hunks are reviewed whole.
- `--files` sections are never split: an `@@ ` line inside a file's text is content, not a hunk.
