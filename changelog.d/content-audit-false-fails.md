## content-audit: stop failing legitimate content

- Every content check except `bom-present`, `encoding-mismatch`, `unclosed-code` and `unlabeled-code-block`
  now skips fenced blocks, inline code and code-valued frontmatter, so a PHP tutorial no longer trips the
  blocking `php-tag` gate.
- NBSP, ZWJ/ZWNJ and mojibake follow the language and script of the text: French and Polish NBSP,
  ZWJ in emoji and Indic/Arabic-script text, and `Ã` before a space in Portuguese/Vietnamese capitals are
  not reported. The mojibake tables no longer map a bare `Ä` (so `Äpfel` is not rewritten to `čpfel`) or
  the shared `â€"` form.
- Ambiguous typography (every NBSP and zero-width character, U+FFFD, `..`, `,,` in quote languages, a double
  space after a sentence stop, quote style, an unconfirmed mojibake candidate) is reported with
  `fix_type: null`; `content-fix` only edits the flagged span, re-checked under the current rules, and no
  longer rewrites `..` or deletes U+FFFD. Mojibake repair values are written as code points so the Codex/
  Antigravity builds cannot fold the dashes to ASCII.
- The three content agents get Bash (read-only) because their instructions already call `file --mime-encoding`, `xxd`,
  `git log`, `curl -I` and `aspell`.
- `img-404-live`, `link-external-dead` and `link-external-redirect` are `N/A` without `--live-url`
  (`--check-external`): never `FAIL`, not scored, not a blocking gate, not `PROVISIONAL`.
- New eval 3 in `evals/content-audit.evals.json` pins the false-positive controls.
