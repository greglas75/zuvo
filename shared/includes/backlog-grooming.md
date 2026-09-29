# Backlog Grooming: verdicts, evidence, the ledger, and the fan-out contract

> Load with `../../shared/includes/backlog-protocol.md`, never instead of it. The protocol says how an
> entry is FILED and CLOSED. This file says how it is **verified** — whether the thing it describes is
> still true — and nothing here licenses a write the protocol forbids.

**The binding rule, verbatim from the user:** *"wszystkie ma najpierw zweryfikować."* Verification
covers the **whole** set, never a sample. Nothing is **closed, ranked, grouped or rendered** until it
carries a verdict backed by an evidence line. Deterministic classes still carry evidence; they skip
only the model's judgement, never the evidence.

The single write that legitimately precedes the gate is **minting an id** for an entry that has none:
it is none of the four forbidden verbs, it is count-neutral (a minted entry was already one of the N),
and a content-keyed entry cannot carry a stable verdict until it has an id. Everything else waits.

## The verdict vocabulary — closed at five

| Verdict | Means | Leads to |
|---|---|---|
| `STILL-REAL` | the defect is present in the tree today | kept |
| `STALE-FIXED` | it was fixed; the fix is in the tree or the archive | archived (by the helper) |
| `STALE-OBSOLETE` | the subject is gone — the file, module or feature no longer exists | dropped (by the helper) |
| `DUPLICATE-OF` | another entry describes the same thing | **reported**, never merged |
| `NOT-VERIFIABLE` | cannot be decided from the repo as it stands | kept, with the reason |

**These five are NOT severity levels and they do not belong in
`../../shared/includes/severity-vocabulary.md`.** That file maps *impact* — how bad. This maps
*existence* — whether it is still there. An entry has both, independently: a `STILL-REAL` nit and a
`STALE-FIXED` blocker are both ordinary. `scripts/audit-registry-integrity.py` validates the severity
file's mapping rows, so folding these in would fail there, and a test asserts they stayed out.

**`NOT-VERIFIABLE` is cheap and legitimate.** Say it whenever the repo does not answer. A verifier that
feels pressure to look thorough guesses `STILL-REAL`, and a guessed `STILL-REAL` is invisible: it keeps
an entry that should have closed, for ever, with an evidence line that resolves.

**`DUPLICATE-OF` is a report, not a licence to merge.** `backlog-protocol.md` is explicit that two
entries sharing a key are two entries — ordinal ids get reused, and a key-deduping rewriter destroys
real entries. Duplicates are disambiguated by minting distinct ids.

## The four evidence shapes

Every verdict carries exactly one evidence line, and the shape is dictated by the verdict:

| Verdict | Evidence shape | Why that shape |
|---|---|---|
| `STILL-REAL` | `<production path>:<line>` plus the words that show it | the verdict that keeps an entry alive must point at the code that keeps it alive. **Without a `path:line` the row is INVALID**, not weak |
| `STALE-FIXED` | `<production path>:<line>` of the fix, or `backlog-done.md:<line> section="…"` when the archive is the proof | it leads to a destructive disposition, so it is the one verdict cross-checked against a second model |
| `STALE-OBSOLETE` | `backlog.md:<line> "<path>" does not exist` — the citation resolves to the **backlog line that names the missing path**, with the absence stated in the text | a citation of the missing path itself could not resolve, so the resolvability check would reject every correct row. The path's absence is checked separately |
| `DUPLICATE-OF` | the other entry's `id:`/`fp:` key, plus both line numbers | the key rides in the **evidence**, not in the verdict field: the vocabulary is closed at five tokens and a verdict carrying a variable payload cannot be validated against a closed set |

`NOT-VERIFIABLE` carries a reason in prose and may cite nothing resolvable. That is the honest case.

## The ledger

`memory/backlog-verdicts.jsonl`, beside the **real** `backlog.md`, one JSON object per line, append-only.
Written and read only through `scripts/zuvo-home/zuvo_backlog_ledger.py` — never by hand, for the same
reason `backlog-done.md` is never hand-written.

| Field | Content |
|---|---|
| `id` | the entry's id at verification time |
| `keys` | `sorted(zb.keys_for(body, ident))` — the pre-mint content key travels with the post-mint one |
| `text_sha` | `sha1(zb.strip_resolution_markers(body))`, 40 lowercase hex |
| `verdict` | one of the five, exactly |
| `evidence` | one non-empty line, in the shape above |
| `verified_at` | aware-UTC ISO stamp |
| `verified_by` | `deterministic:<class>` or `agent:<lane>` |
| `disposition` | `pending` \| `archived` \| `dropped` \| `kept` \| `no-remedy` — written by `groom`, never by `verify`; optional, defaults to `pending` |

**`text_sha` is the invalidation key, so there is no TTL.** A verdict does not expire with the clock, it
expires with the text. It is taken over `strip_resolution_markers(body)` because *closing* an entry
rewrites it — the marker, the commit sha, the PR number and the date all arrive with the closure — and a
verdict must not be invalidated by the very edit that proves it.

**Incrementality (`plan_reuse`), and the defect it exists to catch:**

| Case | Action |
|---|---|
| a key resolves **and** `text_sha` matches | **reuse, zero dispatch** |
| a key resolves, `text_sha` differs | re-verify |
| no row resolves for an entry | verify it, as new |
| a **row** resolves to no entry | **a named defect** — never a silent drop |

The last row is the whole point. A ledger row whose keys reach no entry means the entry was normalised
without an id being minted for it, so its content key rotated and the verdict was orphaned. Dropping
such rows quietly makes the ledger look healthiest at exactly the moment it stopped working.

**Everything fails closed, and the direction is not symmetric.** A corrupt line read as "verified"
closes an entry nobody examined; read as "unverified" it produces a refusal someone then looks at. So a
truncated final line (no terminating newline), unparseable JSON, and a row that misses the schema all
become named defects whose rows are absent from the read — and the entries they described read
**unverified**. `no-remedy` exists for the same reason: "there is nothing this tool can perform here"
must be reported as itself, never as a false `archived`.

**Placement.** The ledger inherits the backlog's git-ignore status **and** its file mode. A ledger that
would be git-TRACKED beside a git-IGNORED backlog is **refused**, naming the ledger and the two lines to
add to `.gitignore` beside it — publishing judgements about untracked content publishes the content.
`is_ignored()` answers `None` outside a git repository (the canonical backlog lives there) and "unknown"
must never masquerade as "tracked".

**Writes.** Under `zuvo_backlog_io`'s `Lock`, through `atomic_write`, re-reading under the lock. A lock
this process cannot take exits non-zero **having written nothing**. An invalid incoming row is refused
*before* the lock. Nothing repairs a bad line: a truncated tail is only terminated so it cannot swallow
the row appended after it, and it still does not parse, so it still reads unverified.

## Chunking the fan-out

Chunk by **block bytes**, using each entry's `end_lineno`, capped at **~25 KB per agent**, 4-8
concurrent. Not by entry count: 220 KB over ~387 entries averages 0.6 KB, but one section here holds
117 entries in 15.8 KB while a single entry runs to 12 KB — a count-based split produces a 40 KB agent,
and 8 of 9 sub-agents measurably jammed on 90-180 KB chunks. A 1-line block cannot under-measure,
because the measurement is bytes and not lines. **An entry is never split mid-entry**; a section is
split when it has to be.

## The agent contract

Input rows: `{id, keys, text_sha, raw_text, section, cited_paths}`. Output: **exactly one record per
input row**, with one verdict and one evidence line. Read-only — Read/Grep/Glob/CodeSift, no Edit, no
Write, no commit.

Conservation is checked three ways, because two of them can be satisfied by a wrong answer:

1. count equality against the dispatched queue;
2. key-set equality;
3. `len(set(keys_returned)) == len(rows_dispatched)` — **without this a merged pair passes a count
   check**.

A missing row is an agent FAILURE, never an implicit verdict. Nothing is appended to the ledger from a
response that fails any of the three.

## The four mechanical controls — and what they cannot do

| # | Control | Checks |
|---|---|---|
| (a) | shape | the verdict is one of the five; exactly one evidence line; `STILL-REAL` without a `path:line` is INVALID |
| (b) | resolvability | the cited path exists at the verified commit and has at least that many lines |
| (c) | keyword overlap | re-read the cited line **±5**; the cited basename equals `normalize_signature`'s basename, plus **≥2** of its 8 content words case-folded in the window |
| (d) | seeded known-answers | K=4 per chunk from git history — 2 provably fixed, 2 provably still real. A miss in **either** direction re-dispatches the chunk |

**(c) catches fabrication, not misjudgement.** Say it plainly and do not let a report imply otherwise:
citing the very line the entry names satisfies (c) while the verdict is still wrong. (c) is also scoped
to the verdicts that cite a **production path** — `STILL-REAL` and `STALE-FIXED`. `STALE-OBSOLETE` cites
a *backlog* line by construction, so its basename can never equal the missing path's and (c) would
reject every correct row; it gets its own control instead (the cited backlog line must name the path,
and the path must be absent at the verified commit).

Only **(d)** measures judgement, and a fifth control — an asymmetric cross-model spot check on ~10% of
`STALE-FIXED` rows, the one verdict leading to a destructive disposition — demotes a disagreed row to
`NOT-VERIFIABLE`. **Neither (a)-(c) nor their sum may be reported as verdict validation.**

Idempotence is asserted about the **reuse path** — an unchanged entry is not re-dispatched; a
one-character edit rotates `text_sha` and *is* re-dispatched — never about byte-identity of model
output, which would be flaky by construction.

## Refusals, so they are recognisable

| Refusal | Condition |
|---|---|
| tracked ledger beside an ignored backlog | `is_ignored(backlog)` and `is_ignored(ledger) is False` |
| invalid incoming row | any schema problem, reported in full, **before** the lock |
| lock held | exits non-zero, zero bytes written |
| partial verification, at `groom` | `verified != entry_count` — names the shortfall by id |
| partial verification, at `doc` | same, unless `--partial`, which stamps the coverage ratio and **omits the ranking** |
| a disposition on a fleet row | `source=index` rows are truncated at 400 chars and cannot be acted on |
