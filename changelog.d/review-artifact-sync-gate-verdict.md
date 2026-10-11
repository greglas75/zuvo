## `review-artifact-sync.sh --check` answers with the push gate's own verdict, and every cited proof travels

- `--check` applies `pg_artifact_proof_verdict` from the gate library to every proof an artifact cites
  (`adversarial:` and `adv-proof:` lines, comma lists). It FAILs (exit 1) whenever the push gate would
  refuse the artifact: no proof line, a missing, truncated, blind-audit or weak proof, prose instead of
  a path, too many refs, or a path out of the repo. Each FAIL line names the ref and the reason. These
  used to pass, or were only a WARN. A grandfathered artifact is `OK` with no proof, as at the gate.
- `--from/--to` copies every cited proof and exits 1 when the gate at the destination would refuse a
  copied artifact, a cited proof missing at the source included.
- `--archive` keys each proof by its repo-relative path (`proofs/<artifact-stem>/<ref>`), so two
  proofs that share a basename no longer collide. `adv-proof:` and comma-listed proofs are archived
  too. `--restore` reads that key first. An archive written before this change still restores the
  artifact's first `adversarial:` proof, and that file is never offered to another ref with the same
  basename.
- The script loads the gate library from beside itself (`~/.zuvo`, a host's `lib/`, the repo layout),
  then from `~/.claude/hooks/lib`. The first readable copy wins, and there is no environment override.
  Without the library every mode but `--help` exits 2 ("cannot compute the gate's verdict"), where it
  used to fall back to its own weaker lint.
