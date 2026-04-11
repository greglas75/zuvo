# Express Defensive Patterns

Active when Express is detected in the project (`express` dependency, Express
router modules, or `req`/`res` middleware style). Not applicable to NestJS when
the framework router and decorators are the primary entrypoint.

---

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
