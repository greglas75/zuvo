# Express Defensive Patterns

Active when Express is detected in the project (`express` dependency, Express
router modules, or `req`/`res` middleware style). Not applicable to NestJS when
the framework router and decorators are the primary entrypoint.

---

## Express 5 vs 4 — async error semantics (behavior change)

- **Express 5**: a rejected promise in a route handler is auto-forwarded to error middleware —
  `app.get('/x', async () => { throw new Error('boom') })` reaches your error handler.
- **Express 4**: the same rejection is SILENTLY swallowed (request hangs until client timeout)
  unless every async handler is wrapped (`asyncHandler`/try-catch-next). Check the installed
  major before removing wrappers — and never remove them in a codebase that still runs 4.
- Either major: exactly ONE error-handling middleware signature `(err, req, res, next)`,
  registered LAST; it must not leak `err.message`/stack to the client (CQ5, CAP17).

## Concrete Express patterns

```typescript
// Body size cap (CQ6): default json limit is 100kb — set it explicitly per API shape
app.use(express.json({ limit: '100kb' }));

// Open redirect (CQ31): never res.redirect(req.query.next) — allowlist relative paths
const next = String(req.query.next ?? '/');
res.redirect(next.startsWith('/') && !next.startsWith('//') ? next : '/');

// Trust proxy before rate limiting by IP — else every client shares the LB's IP
app.set('trust proxy', 1);
```

## Input Validation

- Validate `req.body`, `req.query`, `req.params`, headers, and cookies before
  reaching business logic.
- Prefer Zod, Joi, celebrate, or equivalent middleware over ad hoc checks.
- Reject unknown fields on security-sensitive endpoints.

```typescript
// NEVER
app.post('/users', async (req, res) => createUser(req.body));

// ALWAYS
app.post('/users', validateBody(createUserSchema), async (req, res) => createUser(req.body));
```

## Authorization and Scoping

- Middleware auth alone is not enough. Enforce resource ownership or tenant
  scope inside handlers or services.
- Use `res.locals` or typed request augmentation for trusted auth context.
- Reject cross-tenant access before loading or mutating the resource.

## Redirects and Headers

- Never pass user input directly to `res.redirect()` or `res.set()`.
- Use relative-only redirects or explicit allowlists.
- Normalize and validate header values before reflection.

## File and Process Safety

- Resolve paths against a fixed base directory before file access.
- Never pass raw request data into `child_process`, shell helpers, or archive
  extraction.
- Upload handlers must enforce MIME, extension, size, and storage location.

## SSRF and Outbound Fetches

- Validate protocol and host allowlists before any outbound fetch to a
  user-controlled URL.
- Deny loopback, RFC1918, link-local, and metadata addresses after DNS
  resolution.
- Set connect and total request timeouts.

## Session and CSRF

- Cookie-authenticated state-changing routes need CSRF protection or strict
  Origin/Referer checks.
- Rotate session identifiers on privilege changes and login.
- Mark cookies `HttpOnly`, `Secure`, and with deliberate `SameSite`.

## Safe Patterns

- Zod/Joi/celebrate validation middleware
- explicit relative-only redirect wrappers
- per-resource authorization inside handler/service layer
- signed webhook validation using server-derived secrets and timing-safe compare
