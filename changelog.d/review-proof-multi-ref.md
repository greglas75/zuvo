## A review artifact may cite several proofs, and every one must pass

- The header of a `memory/reviews/` artifact may now cite more than one adversarial proof: repeated
  `adversarial:` (or `adv-proof:`) lines, a comma list, or both. Only the header block counts — the
  contiguous non-blank block holding the first such line — so a retrospective
  `adversarial: pass1=… | …` line further down is no longer read as a path.
- Each proof is checked on its own: one truncated, blind-audit, weak, escaping or missing proof
  refuses the whole artifact. Before, only the first `adversarial:` line was read, so a truncated
  second proof went unchecked, and a comma list was taken as one (missing) path.
- Under `PG_PROOF_OPTIONAL=1` (CI) an absent proof is still waived, but a present one is checked, an
  empty item (`adversarial: ,`) no longer counts as an absent proof, and a value that is prose rather
  than a path (spaces, `;`, `(`, `|`) is refused whole instead of waived. A header may cite at most
  16 proofs in at most 64 comma items and 4096 characters; more is refused, so an oversized header
  cannot stall a gate.
- `pg_artifact_proof_verdict <root> <artifact>` (in `hooks/lib/pipeline-gate-lib.sh`) prints the
  verdict per proof with its reason; `pg_artifact_proven` is now a wrapper over it. The push gate's
  explanation of a blocked file uses the same reason, so a truncated proof is reported as truncated,
  not as "<2 'REVIEW BY:' lines".
