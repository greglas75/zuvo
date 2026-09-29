## The blind coverage audit is a 3-provider isolated panel

- `adversarial-review.sh --mode blind-audit --production <file> --test <file>` runs the blind
  coverage audit as a panel: `agy` pinned plus two random lanes from those whose isolation is
  proven (no repo, tool or MCP access). The host's whole vendor is excluded, and
  `ZUVO_BLIND_AUDIT_ALLOWLIST` can only narrow the set.
- Whole files go in one prompt, never chunked or truncated. Byte gates refuse oversize input
  (exit 6), and a lane whose argv cannot carry the prompt is dropped.
- Each answer is validated as a strict block (anchored, anti-echo); an invalid answer counts as
  that lane failing. The merge takes the worst verdict and the union of uncovered rows with
  attribution. A strict result needs at least 2 valid answers; 1 valid answer is `degraded`
  (exit 3) and none is exit 2.
- The whole run is bounded by a 585 s ceiling that `ZUVO_RUN_DEADLINE` cannot raise. Codex runs
  at `effort=high` (`ZUVO_BLIND_AUDIT_EFFORT`).
- Blind-audit rows and proofs never count as an adversarial review. `pg_artifact_proven` and the
  post-skill hook refuse them. A blind-audit input failure never benches a lane.
- `blind-audit-codex.sh` is now a thin back-compat wrapper over the panel. `install.sh` ships the
  panel library and protocol next to `~/.zuvo/adversarial-review`. `reviewer-preflight.sh` probes
  exactly the panel's candidates. write-tests Step 3.5 audits through the panel.
- Fixed along the way, in every mode:
  - A negative or digit-less `ZUVO_RUN_DEADLINE` no longer disables the whole-run watchdog.
  - Numeric knobs are read as decimal, never as octal.
  - The proof gate reads a proof once and recognises only a real header, so a review quoting a
    header no longer false-refuses and CRLF truncated proofs are refused.
  - The preflight panel listing is bounded even without GNU `timeout`.
