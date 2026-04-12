# Payload Conventions

Active when Payload is detected (`payload.config.*`, collection configs, or Payload imports). Not applicable to non-Payload projects.

---

## Access Control

- Every collection and global that mutates data must have explicit access-control callbacks.
- Access callbacks must scope by the authenticated user, org, or tenant. Returning `true` broadly is a security smell.
- Admin-only operations must not rely on UI hiding alone; enforce access in the server config.

## Hooks and Validation

- `beforeValidate`, `beforeChange`, and `afterRead` hooks must validate and normalize user-controlled fields.
- Hook code must not trust sibling fields without schema or runtime validation.
- Upload metadata and filenames must be validated server-side.

## Preview and Draft Safety

- Preview URLs must be signed or authenticated.
- Draft mode toggles must not be exposed to unauthenticated users.
- Rich text or custom admin components rendering HTML must sanitize before raw output.

## Pentest Focus

- Collection access callbacks returning broad access
- Upload filename/path handling
- Preview URL open redirects
- Hooks mutating privileged fields without auth checks
- Admin custom components rendering unsafe HTML

## Astro Integration Overlay

- Preview URLs passed into Astro routes must be signed and validated on both sides.
- Payload rich text rendered in Astro must stay sanitized through markdown / component bridges.
- Collection access rules must match Astro route exposure, not just Payload admin behavior.
