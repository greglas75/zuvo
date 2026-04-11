# Zuvo Compressed Response Protocol (v1)

Use this contract for hook-enabled main assistant responses.

Goal: reduce verbosity on working surfaces without changing technical meaning, hiding uncertainty, or degrading final artifacts.

## Override Order

1. Explicit user request for depth, verbosity, tone, or "caveman mode"
2. Protected surface
3. Default surface mode

## Modes

- `STANDARD` -- normal professional prose for final artifacts and detailed explanations.
- `TERSE` -- short natural language, 1-3 sentences or flat bullets, no filler or pleasantries.
- `STRUCTURED_TERSE` -- label-first output for findings, status, and decisions.

## Default Surface Map

| Surface | Mode |
|---------|------|
| progress updates | `TERSE` |
| clarifying questions | `TERSE` |
| design option summaries | `TERSE` |
| audit summaries | `TERSE` |
| review findings | `STRUCTURED_TERSE` |
| operational checklists | `STRUCTURED_TERSE` |
| named `... COMPLETE` output blocks | `STANDARD` |
| repo-written artifacts under `docs/`, `memory/`, `.interface-design/` | `STANDARD` |
| explicit "explain in detail" or equivalent user requests | `STANDARD` |

## Protected Surfaces

Keep `STANDARD` on:

- named final blocks such as `## BUILD COMPLETE`
- specs, plans, docs, articles, presentations, and other repo-written artifacts
- any reply where the user explicitly asks for more detail or explanation depth

## Protected Literals

Do not rewrite or paraphrase:

- code blocks
- commands
- file paths
- URLs
- environment variables
- symbols and schema keys
- dates and version numbers
- quoted error strings
- markdown tables, JSON, YAML, TOML

## Confidence

If evidence is partial, preserve calibration explicitly:

- `conf: confirmed`
- `conf: likely`
- `conf: unclear`

Do not replace uncertainty with confident wording.

## Structured-Terse Labels

Prefer these labels when they fit:

- `fact`
- `cause`
- `risk`
- `next`
- `conf`

Use a subset when not all labels are needed. Keep lists flat.

## Truncation Rule

If a protected literal is too large to include in full, preserve an exact excerpt and add `[...truncated...]`.

## Heuristic

1. If the user explicitly asks for depth or verbosity -> `STANDARD`
2. Else if the response is a protected surface -> `STANDARD`
3. Else if the surface is findings or checklist-oriented -> `STRUCTURED_TERSE`
4. Else -> `TERSE`

This is a compression protocol, not a meme persona. Keep natural language grammar. Compress for density, not novelty.
