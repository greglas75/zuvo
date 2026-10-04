"""THE REJECTION VOCABULARY of the verifier lane: the closed code set, `Reject`, `Result`, `Row`.

Extracted from `zuvo_backlog_agent.py` when that module reached 430 raw lines against the 400-line
default in `rules/file-limits.md`. It is the seam the dependency graph was already asking for: control
(c) belongs with the evidence resolution it calls (`zuvo_backlog_verdicts`), and could not move there
while the vocabulary it returns lived in the module that imports it — that is an import cycle, not a
layering preference. One module holding the shared vocabulary breaks it; nothing here imports anything
of this family, so nothing can.

A CLOSED CODE SET, because a caller greps for these. A free-form reason string makes "which control
refused this chunk" unanswerable, which is the question a re-dispatch decision asks.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. This module imports no
parser, so the H19c pin-guard family excludes it by the derivation's own predicate; it holds no
`iter_entries` call and must not grow one.
"""
from typing import Any, Dict, List, NamedTuple, Tuple

Row = Dict[str, Any]                 # a queue row; typing it tighter would be fiction, as in the
                                     # siblings that say so of their own
LANE = "agent:backlog-verifier"      # `_BY_RE`'s `agent:<lane>` half — the provenance the cross-model
                                     # spot check selects on
WINDOW = 5                           # control (c)'s ±5 lines. An exact-line assert would reject
                                     # CORRECT evidence: a fabricated number is usually close, and a
                                     # true one drifts by an edit above it
MIN_WORDS = 2                        # ≥2 of the signature's 8 content words

# The rejection vocabulary, closed, because a caller greps for these. A free-form reason string makes
# "which control refused this chunk" unanswerable, which is the question a re-dispatch decision asks.
R_COUNT = "COUNT"
R_KEYSET = "KEYSET"
R_MULTIPLICITY = "MULTIPLICITY"
R_UNKNOWN = "UNKNOWN-KEY"
R_SHAPE = "SHAPE"
R_UNRESOLVABLE = "UNRESOLVABLE"
R_OVERLAP = "OVERLAP"
R_SEED = "SEED-MISS"
R_AMBIGUOUS = "DISPATCH-AMBIGUOUS"
R_SEED_SHORT = "SEED-SHORTFALL"
REJECTS: Tuple[str, ...] = (R_COUNT, R_KEYSET, R_MULTIPLICITY, R_UNKNOWN, R_SHAPE, R_UNRESOLVABLE,
                            R_OVERLAP, R_SEED, R_AMBIGUOUS, R_SEED_SHORT)


class Reject(NamedTuple):
    """One refusal, naming the SUBJECT it is about. `subject` is an entry id or a seed key, never a
    row index: a reader has to be able to find the offending row in a 25 KB dispatch."""

    code: str
    subject: str
    why: str

    def __str__(self) -> str:
        return "%s %s: %s" % (self.code, self.subject, self.why)


class Result(NamedTuple):
    """`rows` is EMPTY whenever `rejects` is not — see the module docstring. `controls` records the
    per-row (c) mode so the pass rate can never be quoted without its denominator."""

    rows: List[Row]
    rejects: List[Reject]
    controls: List[str]
