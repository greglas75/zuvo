# SEO Page Profile Registry

> Shared page-profile heuristics for `seo-audit`.
> Profiles tune D9/D10 content and GEO expectations and decide which critical
> gates apply. A gate that applies is never weakened.

## Profile Rules

- D9/D10 checks are `scored` by default unless the profile explicitly downgrades
  them to `advisory` or `N/A`.
- Profiles may downgrade heuristic checks, but they never upgrade a non-blocking
  check into a blocking gate.
- If the content source is inaccessible in the repo, the agent may further
  downgrade D9/D10 results to `advisory` or `N/A`.

### `marketing`

- Thin-content threshold: `250` words for primary pages.
- Answer-first expectation: `required`
- E-E-A-T expectation: `medium`
- Freshness sensitivity: `medium`
- D9 enforcement: `scored`
- D10 enforcement: `scored`
- Notes: Landing pages can be concise, but they must surface the main promise
  quickly and expose authorship or company trust signals when claims are strong.

### `docs`

- Thin-content threshold: `120` words per doc page or section.
- Answer-first expectation: `required`
- E-E-A-T expectation: `medium`
- Freshness sensitivity: `low`
- D9 enforcement: `scored`
- D10 enforcement: `scored`
- Notes: Concise reference pages are acceptable if they are clearly structured,
  chunkable, and linked into the documentation graph.

### `blog`

- Thin-content threshold: `500` words.
- Answer-first expectation: `required`
- E-E-A-T expectation: `high`
- Freshness sensitivity: `medium`
- D9 enforcement: `scored`
- D10 enforcement: `scored`
- Notes: Editorial pages are held to the highest content standard for summary,
  citation readiness, and authorship/freshness signals.

### `ecommerce`

- Thin-content threshold: `150` words excluding structured specs.
- Answer-first expectation: `required`
- E-E-A-T expectation: `high`
- Freshness sensitivity: `high`
- D9 enforcement: `scored`
- D10 enforcement: `advisory`
- Notes: Product detail pages may rely on spec tables and merchandising blocks,
  so D10 heuristics should guide rather than dominate scoring.

### `app-shell`

- Thin-content threshold: `50` words.
- Answer-first expectation: `N/A`
- E-E-A-T expectation: `advisory`
- Freshness sensitivity: `low`
- D9 enforcement: `N/A`
- D10 enforcement: `advisory`
- Notes: Logged-in shells, dashboards, and utility wrappers should not be
  punished like editorial pages. Structure and crawlability still matter.

## Gate applicability

A gate a profile exempts is `N/A`, not FAIL and not PROVISIONAL (`seo-audit` Phase 4.1). Every other cell: the gate applies in full.

| Gate | marketing | blog | ecommerce | docs | app-shell |
|------|-----------|------|-----------|------|-----------|
| CG1 sitemap | applies | applies | applies | applies | N/A |
| CG2 Googlebot not blocked | applies | applies | applies | applies | N/A |
| CG3 HTTPS | applies | applies | applies | applies | applies |
| CG4 canonical | applies | applies | applies | applies | N/A |
| CG5 JSON-LD SSR | applies | applies | applies | only when JSON-LD exists | N/A |
| CG6 AI crawler policy | applies | applies | applies | applies | N/A |

`app-shell` is a logged-in shell: nothing in it is meant to be indexed, so
sitemap, canonical, JSON-LD and crawler policy have no subject (`robots-exists`
stays a scored check). `docs` sites rarely carry JSON-LD; its absence is the scored
`json-ld-present` check, while client-only JSON-LD that exists still fails CG5.
