# Backlog Grooming: verdicts, evidence, the ledger, and the fan-out contract

> Load with `../../shared/includes/backlog-protocol.md`, never instead of it. The protocol says how an
> entry is FILED and CLOSED. This file says how it is **verified** — whether the thing it describes is
> still true — and nothing here licenses a write the protocol forbids.

**`verify`, `groom` and `doc` below are the SKILL's mode words, not commands.** The CLI is
`{plan, dispatch, ingest, apply, render, coverage}` — `backlog-groom.py --help` is the authority — and
`skills/backlog/SKILL.md` ("The three mode words") holds the mapping, once: `verify` is
`plan` + `dispatch` + `ingest`, `groom` is `apply`, `doc` is `render`. The plan that commissioned this
feature wrote `verify --fleet` and `groom --fleet` as commands four times each and neither has ever
existed; read a mode word here as a phase, never as something to type.

**The binding rule, verbatim from the user:** *"wszystkie ma najpierw zweryfikować."* Verification
covers the **whole** set, never a sample. Nothing is **closed, ranked, grouped or rendered** until it
carries a verdict backed by an evidence line. Deterministic classes still carry evidence; they skip
only the model's judgement, never the evidence.

The single write that legitimately precedes the gate is **minting an id** for an entry that has none:
it is none of the four forbidden verbs and it is count-neutral (a minted entry was already one of the
N). Everything else waits.

**A content-keyed entry does NOT need an id to carry a verdict, and the claim that it does was measured
false.** `keys_for` gives such an entry a first-class `fp:<12hex>` key, the ledger's `_KEY_RE` accepts
`fp:` as first-class, and `plan_reuse` keys staleness on **(key, text_sha)** — on content, never on an
id. Measured on this repo: the mint set is 263 entries and `mint_into` refuses **all 263** of them,
because every one is the BULLET dialect and that refusal is a deliberate, separately-pinned contract.
Verification therefore proceeds on `fp:` keys and no id is written into a tracked file to satisfy a
premise measurement refuted. What an `fp:` key actually costs, measured per edit:

| edit to the entry | key | `text_sha` | outcome |
|---|---|---|---|
| a leading `[DONE <date> <sha>]` marker — what resolution does | kept | **kept** | **reused, zero dispatch** |
| prose appended outside the 8-word window | kept | moves | re-verify; the row stays reachable |
| the path changed, or one of the 8 words after it | **rotates** | moves | rotate + a **named** orphan |

So resolution is free, later prose costs one re-verify, and a verdict is lost only when the entry's
subject changes. Both halves have to be said: the broad claim overstates the cost and the narrow one
alone hides it.

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
concurrent. Not by entry count: measured on this repo, **317 KB over 494 entries** averages 0.6 KB, but
one section holds **117 entries in 13 KB** while a single heading entry runs to **17.7 KB** — so a
count-based split produces a 40 KB agent, and 8 of 9 sub-agents measurably jammed on 90-180 KB chunks. A
1-line block cannot under-measure, because the measurement is bytes and not lines. **An entry is never
split mid-entry**; a section is split when it has to be.

Derive those four numbers before quoting them. The entry count moves on every run that appends to the
backlog — it has been quoted as 387, 330, 402 and 483 in this feature's own documents, and it is 494
today.

## The agent contract

The lane is `skills/backlog/agents/backlog-verifier.md`, dispatched one CHUNK at a time.

Input rows: `{id, keys, text_sha, raw_text, section, cited_paths}` — written by
`backlog-groom.py dispatch` to `$ZUVO_DIR/context/backlog-dispatch-<n>.jsonl`. Output: **exactly one
record per input row**, `{key, verdict, evidence}` as JSONL, where `key` is the row's `keys[0]` copied
byte for byte. Read-only — Read/Grep/Glob/CodeSift, no Edit, no Write, no commit.

`text_sha` travels INTO the agent and is never read back OUT of its answer: the orchestrator takes
`id`, `keys` and `text_sha` from the dispatch when it builds the ledger row. A responder that restated
the sha of the text it judged would turn staleness from a measurement into a claim.

**A chunk is all-or-nothing.** `ingest` returns ledger rows only when the rejection list is EMPTY —
never the clean half of a response that failed a control. Appending the half that passed would record
judgements next to an unexplained hole, so the assertion to make is the ledger's **byte count** before
and after, not the absence of one row.

Conservation is checked three ways, because two of them can be satisfied by a wrong answer:

1. count equality against the dispatched queue;
2. key-set equality;
3. `len(set(keys_returned)) == len(rows_dispatched)` — **without this a merged pair passes a count
   check**.

A missing row is an agent FAILURE, never an implicit verdict. Nothing is appended to the ledger from a
response that fails any of the three.

**Honest note on (3).** It cannot fail while (1) and (2) both hold: if all N dispatched keys appear
among N records, no key can appear twice. It is run and reported separately because it names the
MULTIPLICITY — *which* id was answered twice — where (2) names only the ABSENCE, and a re-dispatch
decision needs both. Reporting (3) as an independent guarantee would overstate it.

**Two rows answering to one key is a refusal BEFORE dispatch**, not a puzzle at ingest. Measured: 0
collisions in today's 414-row dispatch, because the deterministic duplicate class already decided every
colliding entry and a row carrying a verdict is not dispatched. That is a property of the pre-pass, not
a law — a duplicate row whose evidence was refused as unresolvable carries no verdict and would arrive
beside its twin — so `DISPATCH-AMBIGUOUS` is checked rather than assumed.

## The four mechanical controls — and what they cannot do

| # | Control | Checks |
|---|---|---|
| (a) | shape | the verdict is one of the five; exactly one evidence line; `STILL-REAL` without a `path:line` is INVALID |
| (b) | resolvability | the cited path exists at the verified commit and has at least that many lines |
| (c) | keyword overlap | re-read the cited line **±5**; the cited basename equals `normalize_signature`'s basename, plus **≥2** of its 8 content words case-folded in the window |
| (d) | seeded known-answers | K=4 per chunk from what this repo records — 2 provably fixed, 2 provably still real. A miss in **either** direction re-dispatches the chunk |

**`NOT-VERIFIABLE` is exempt from (b) and (c) in the CODE, not only in the prose.** It owes (a): a
reason, one line. A verifier required to produce a resolvable citation for "the repo does not answer
this" produces a resolvable citation for something, and the cheapest one is a guessed `STILL-REAL`.

**(c) has four recorded modes, and a pass rate quoted without the split is a number about a different
control.** Measured on this repo's 494 entries:

| mode | when | measured |
|---|---|---|
| `full` | basename equality **and** >=2 of the 8 signature words in the window | 156 entries have a path token in their signature |
| `words-only` | the entry's signature has **no** path token, so only the words half can be asked — requiring a basename the entry never named would teach the verifier to invent one | 338 entries |
| `archive-proof` | a `STALE-FIXED` row citing `backlog-done.md`, the second shape the table above permits for that verdict. The words half still runs, against the ARCHIVE's window, so the cited archive line is shown to be about *this* entry | — |
| `n/a:…` | out of scope, or the signature holds fewer than **2** content words, which makes ">=2 of 8" unsatisfiable rather than failed | 20 entries |

A `STILL-REAL` row citing the archive is **not** `archive-proof` and stays a basename rejection: that
verdict means the defect is in the tree today, so the archive cannot be what shows it.

**Control (d)'s seeds are indistinguishable or they gate nothing.** A seed row carries exactly the
queue's field set, the expected verdict lives in a separate answer file the agent is never pointed at,
and the dispatch is INTERLEAVED by a stable hash — sorting by key would park every seed in one block,
because a seed's `fp:ffff…` key sorts after every real `fp:` key. The closed seeds are built from
archived entries with their resolution markers **stripped**: verbatim, the marker makes the answer
legible from the seed's own text and (d) degrades into a reading test. **A seed SHORTFALL is a refusal,
never a smaller K** — a chunk dispatched with two seeds instead of four is an under-gated chunk that
reads identically to a gated one, so a repo with no recorded closures cannot self-seed and must be
given its seeds explicitly.

**(c) catches fabrication, not misjudgement.** Say it plainly and do not let a report imply otherwise:
citing the very line the entry names satisfies (c) while the verdict is still wrong. (c) is also scoped
to the verdicts that cite a **production path** — `STILL-REAL` and `STALE-FIXED`. `STALE-OBSOLETE` cites
a *backlog* line by construction, so its basename can never equal the missing path's and (c) would
reject every correct row; it gets its own control instead (the cited backlog line must name the path,
and the path must be absent at the verified commit).

**Two further limits of (c), both measured, both of which a report must not paper over.** The window and
the signature are compared as WORD SETS, tokenised on `[a-z0-9]+` — the first implementation asked
`word in haystack`, a substring test, and `on` is inside `function`, `is` is inside `exists` and `a` is
inside almost everything, so a window of ordinary TypeScript scored 2 hits for an entry it had nothing
to do with. And even tokenised, `normalize_signature` does not drop stop-words: `the`, `is`, `no` and
`on` count toward the two. A window of prose about nearly anything contains two of them. **(c) checks
that a citation lands somewhere plausibly ABOUT the entry; it is not a similarity score**, and raising
the threshold is a change to the plan's own number rather than a tidy-up.

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

At ingest the vocabulary is closed too, because a caller greps it to decide whether to re-dispatch —
a free-form reason makes "which control refused this chunk" unanswerable:

| Code | Condition |
|---|---|
| `COUNT` | record count differs from the dispatched row count |
| `KEYSET` | a dispatched row was not answered |
| `MULTIPLICITY` | fewer distinct keys than rows — the merged pair |
| `UNKNOWN-KEY` | a record names a key nobody dispatched |
| `SHAPE` | control (a), including everything `validate_row` rejects |
| `UNRESOLVABLE` | control (b) |
| `OVERLAP` | control (c) |
| `SEED-MISS` | control (d), in either direction |
| `DISPATCH-AMBIGUOUS` | two dispatched rows answer to one key — refused before a model is paid for it |
| `SEED-SHORTFALL` | the chunk could not be fully seeded, so it is not dispatched |
