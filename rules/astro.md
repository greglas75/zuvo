# Astro Conventions

Active when Astro is detected (`astro.config.*`, `.astro` files, or Astro packages). Not applicable to non-Astro projects.

---

## Rendering and Content Safety

- Astro escapes expressions by default. Any raw HTML insertion must be treated as a sink.
- Markdown, CMS content, and frontmatter-derived rich content must be sanitized before raw rendering.
- Redirect targets must be relative-only or allowlisted.

## Server Endpoints and Middleware

- Validate all params and query values in Astro endpoints under `src/pages/api` or server routes.
- Middleware must not forward arbitrary `Origin`, `Host`, or `X-Forwarded-*` values without validation.
- Preview and draft-mode endpoints require signed tokens or equivalent auth checks.

## Islands and Client Hydration

- Do not pass secrets or server-only tokens into hydrated island props.
- User-controlled data rendered inside islands must remain escaped or sanitized before HTML rendering.
- Client-side redirects derived from user input must be allowlisted.

## Pentest Focus

- Raw HTML rendering in `.astro` templates
- Preview URL construction and open redirects
- SSR middleware reflecting headers or cookies
- API endpoints missing auth or CSRF protection
- Content collection schemas missing validation for dangerous fields

## Astro + Payload / Sanity Overlay

- Preview routes must validate both the Astro-side secret and the CMS-side preview token.
- Draft-mode data must never be serialized into hydrated island props.
- Rich content from Payload or Sanity must be sanitized before any raw HTML bridge in `.astro`.
- Cache invalidation or webhook endpoints must validate signatures and scope affected content correctly.
