# Sanity Conventions

Active when Sanity is detected (`sanity.config.*`, schema files, or Sanity imports). Not applicable to non-Sanity projects.

---

## Studio and Schema Safety

- Schema validation must exist for privileged fields, URLs, slugs, and rich-content blocks.
- Custom studio inputs and actions must not render raw HTML from untrusted content.
- Preview configuration must not allow arbitrary external redirect targets.

## Webhooks and Preview

- Webhook endpoints must validate shared secrets or signatures using timing-safe comparison.
- Preview handlers must require signed tokens or authenticated sessions.
- GROQ query params from requests must be validated before interpolation.

## Asset and Content Handling

- Asset proxy or download handlers must validate path and URL inputs.
- Portable Text custom renderers must escape or sanitize embedded HTML.
- Public preview endpoints must not leak draft or cross-tenant content.

## Pentest Focus

- Preview URL builders
- Webhook signature validation
- GROQ queries assembled from user input
- Custom studio inputs and actions
- Draft-content exposure paths

## Astro Integration Overlay

- Preview secrets must be validated before Sanity draft content is rendered in Astro.
- GROQ-backed Astro routes must validate slug and query params before interpolation.
- Portable Text custom blocks rendered through Astro components must not bypass sanitization.
