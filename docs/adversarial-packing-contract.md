# Review input packing contract

Zuvo owns `zuvo-packing/1`: one partitioner is used for real dispatch and the
provider-free `adversarial-review --chunk-plan --json` operation. The caller passes
the same input, mode, context, locale, environment overrides and chunk controls to
both operations. Planning invokes no provider, spends no review quota, and writes
no review evidence. Planning rejects other exclusive operations (dry-run, doctor,
provider listing, ledger disposition/effectiveness and blind audit). A plan is an estimate of payloads per lane on the first attempt;
it is not a review verdict or a count of retries.

The input collector retains its existing normalization and maximum-input guard.
Activation and final truncation use Bash character counts under the effective
locale. A small multibyte input may exceed the byte cap without activating
chunking. Preserve that behavior: the reserve applies only after chunk activation.
Code mode defaults to a 30000 character cap and a 500 byte chunk-note reserve;
consumers must read the plan rather than copy these values. Document modes keep
their existing cap and fence-aware boundaries. Child and no-chunk guards still
prevent recursive packing.

Once activated, the partitioner packs serialized UTF-8 bytes in canonical section order,
including newlines, repeated diff headers and lifecycle context trailers. Equal to
the payload byte budget fits; greater starts another chunk. Multi-hunk diff
sections split at hunks and, when necessary, at body-line boundaries with
recomputed sub-hunk coordinates, repeating their header/trailer. This preserves
the current canonical splitter released before this contract. An indivisible
oversized line or a `--files` section stays whole; the ordinary truncation function
then determines precisely what is reviewed. Failed splitting retains the original
section. Incomplete/truncated or unreviewable chunks must never be described as
complete coverage.

Current canonical omission policy also applies before packing: oversized removed
content and added test-fixture lines receive explicit omission markers. Added
ordinary code is never silently omitted. The plan reports omission and unsplittable
notes; either condition makes its full-coverage `complete` flag false even if the
normal reviewer can proceed under the existing omission policy.

The JSON report includes schema and contract versions, effective mode and cap,
chunk reserve and payload byte budget, normalized-input identity, ordered chunk
byte sizes, actual normalized review-input identities, hunk headers and coverage
flags. Per-chunk reviewability reuses the ordinary child material guard before
truncation, including refusal of a blank document preamble. A refused chunk has a
prospective review-input identity and is never counted as complete coverage.
`normalized_input` identifies the collected input before omission; chunk and
review-input identities identify the later prepared payloads. Repeated headers,
sub-hunk coordinates and omission markers mean concatenating chunks is not an
inverse transformation. Context trailers are not counted as input hunks until the next canonical file
header; an unescaped diff header always starts a new section in the existing
input protocol. Document/`--files` examples are not real input hunks. The `hunks`
inventory describes the planned chunk before truncation; the truncation flag and
review-input identity disclose incomplete coverage.
Hunk coordinates refer to the input supplied to Zuvo; a consumer may prepare
that diff before planning but must dispatch exactly the same prepared input.

The review host owns release installation and resolving a driver once per job.
Planning and dispatch use that frozen executable/module set; a later job may adopt
a newer compatible release. Never pin the stable launcher permanently to an old
release or patch an installed cache as canonical source.

The platform owns its 40-chunk CI and 120-chunk host policy, two required vendor
lanes and model policy. A too-large plan starts no provider and produces the
existing NOT_REVIEWED / complete:false result. Unsupported planning or failure is
logged as unavailable and follows the existing normal-review fallback; consumers
must not manufacture a guessed count or PASS.

Conformance tests use controlled provider executables and compare the actual
review input bytes to the plan, including non-ASCII text, activation versus packing,
whole-hunk and sub-hunk splitting, explicit omission, truncation and provider-free side effects. Run through the
farm: `rt bash tests/hooks/test-adversarial-packing-plan.sh`.

The existing dispatcher has separate backlogged limits: mixed Markdown fence
tracking, lexical part ordering at 1000+ chunks, and byte-truncated long filenames
in descriptive hunk notes. This contract preserves those dispatch semantics;
ordered JSON chunks describe actual dispatch order, including that inherited limit.
Very large diagnostic note ledgers can also exceed process argument limits;
planning then fails nonzero and the caller follows its unavailable-planning path.
None of these cases permits treating a missing plan as a successful review.
