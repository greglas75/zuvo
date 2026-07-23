# Follow-up ideas (optional — ZERO ceremony, but leave a receipt)

Canonical "Follow-up ideas" step, shared by every skill that has one (build, review, execute,
refactor, brainstorm). The CALLER substitutes its own skill name for `<skill>` below.

If genuinely new IDEAS surfaced this session — feature possibilities, "we could also X", better
approaches for later — append ONE line each to `memory/ideas.md` **at the MAIN checkout root**
(worktree-safe resolution per `backlog-protocol.md`; create if missing):

```
- [YYYY-MM-DD] [<skill>] <idea> — <one-line context>
```

Ideas ONLY: debt / findings go to backlog, never here. This file is read by `knowledge-prime`
so future sessions see it.

**Then, whether or not anything surfaced, record the receipt — this is the one non-optional
part** (it is what makes the step's silence auditable without ever forcing an idea):

```bash
~/.zuvo/log-ideas --skill <skill> --count <N>   # N = ideas appended this session; 0 is normal and honest
```

Why the receipt: the step is deliberately un-gated, so before this, a near-empty `ideas.md`
across many sessions was ambiguous — did the step run and honestly yield nothing (expected for
heads-down execute/refactor sessions), or did the agent just skip it silently? The receipt
answers that in `~/.zuvo/ideas.log` (`tail ~/.zuvo/ideas.log`) at zero cost and with **zero
pressure to invent ideas** — recording `--count 0` is the correct, common outcome. Do NOT
manufacture ideas to make the count non-zero; a truthful 0 is the point.
