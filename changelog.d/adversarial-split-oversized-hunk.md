## One hunk over the adversarial cap is split at its lines instead of being cut

- A NEW file over the cap (30000 characters in code mode) is a single `@@ -0,0 +1,N @@` hunk, so the
  hunk split had nothing to cut at: its part was truncated, the run exited 4 and recorded
  `input_truncated=true`. The result was deterministic, so a harness that retries a truncated review
  re-ran the same exit-4 review forever (16 runs on 2026-10-20 on five tickets).
- A hunk over the chunk budget is now cut at its line boundaries into sub-hunks that each fit. Every
  sub-hunk is a valid hunk: its `@@ -a,b +c,d @@` header is recomputed from the lines it holds (context
  lines count on both sides, `-` on the old, `+` on the new; a `\ No newline at end of file` marker
  stays with the line before it) and keeps the hunk's section heading, so `file:line` citations stay
  right. Every part repeats the file's diff header and its `=== CONTEXT:` block, as before. Added-only
  and mixed hunks are both split.
- One file of one oversized hunk now chunks on its own; it used to need a second file or hunk.
- A chunk's note names the hunk part it holds ("hunk 2 part 1/3 of 4 of <path>").
- Exit 4 from the chunker is now left for a single LINE over the cap, a `--files` section over the cap,
  a file header or trailer too big to leave room for a sub-hunk, and an explicit `--no-chunk`.
