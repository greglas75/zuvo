# Go Conventions

Active when Go is detected (`go.mod`, `.go` files, or Go packages). Not applicable to non-Go projects.

---

## Request Handling

- Validate all query params, path params, JSON bodies, headers, and multipart inputs before use.
- Do not trust router-bound params without format checks.
- Use request-scoped contexts with timeouts for external calls.

## Data and Output Safety

- Prefer parameterized queries. Never concatenate SQL with request data.
- Prefer `html/template` for HTML output; treat `template.HTML` as a dangerous sink.
- Validate redirect targets and response headers derived from request input.

## Files and Commands

- Normalize file paths before reads, writes, deletes, or archive extraction.
- `exec.Command` arguments must never be assembled directly from untrusted strings.
- Validate uploads by size and content type server-side.

## Pentest Focus

- `db.Query*`, `Exec*`, and raw SQL builders
- `template.HTML` and custom HTML responses
- redirects and header reflection
- file handling and archive extraction
- middleware/auth gaps in handler chains

## gin / echo / chi Overlays

### gin

- `ShouldBind*` without validator coverage is not sufficient validation.
- Verify middleware order for auth, recovery, rate limiting, and tenant context.
- Treat `c.Redirect`, file helpers, and header reflection as sink boundaries.

### echo

- `Bind()` must be paired with explicit validation.
- Check middleware stacking and custom context auth propagation.
- Review file upload, file serve, and redirect helpers for traversal and open redirect issues.

### chi

- Manual param parsing is common; validate all params and IDs explicitly.
- Review router groups and middleware composition for accidentally public mutation routes.
- Tenant/resource auth often lives in middleware plus handler checks; verify both.
