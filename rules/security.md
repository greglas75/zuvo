# Security Standards

Stack-independent security requirements. OWASP-aligned.

---

## Boundary Input Validation

- **Validate at every system boundary:** API endpoints, form submissions, webhooks, URL parameters
- **Use schema validation** (Zod, Joi, or equivalent) on all incoming data
- **Server-side validation is mandatory** — client-side validation is a UX convenience, not a security control
- **Sanitize before rendering** — especially user-generated HTML content

## Cross-Site Scripting (XSS)

```typescript
// NEVER — render unsanitized user content
<div dangerouslySetInnerHTML={{ __html: userInput }} />

// ALWAYS — sanitize with a proven library
import DOMPurify from "isomorphic-dompurify";
const clean = DOMPurify.sanitize(html, {
  ALLOWED_TAGS: ["b", "i", "em", "strong", "a"],
  ALLOWED_ATTR: ["href"],
});
```

- React auto-escapes JSX expressions, but `dangerouslySetInnerHTML` bypasses this protection
- Template literals in HTML contexts (email templates, iframe srcDoc) require manual escaping
- User content containing backticks must be escaped when rendered inside template literals

## Server-Side Request Forgery (SSRF)

- **Allowlist external hosts** — user input must never control the full URL without validation
- **Block private IP ranges** in outbound requests: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `127.0.0.0/8`
- **Block dangerous protocols**: `file://`, `gopher://`, `dict://`, `ftp://` — allow only `https://`
- **Parse URLs** using `new URL()` before making requests — never concatenate user input into URL strings
- **Set timeouts** on all outbound HTTP requests to prevent SSRF-based denial of service

```typescript
// NEVER — fetch user-controlled URL directly
const response = await fetch(userInput);

// ALWAYS — validate against allowlist
const url = new URL(userInput);
if (!ALLOWED_HOSTS.includes(url.hostname)) throw new Error("Host not allowed");
if (url.protocol !== "https:") throw new Error("Only HTTPS allowed");
```

## Path Traversal

- **Never use user input directly in file paths** — map IDs/keys to stored paths instead
- **Normalize paths** with `path.resolve()` or `path.normalize()` and verify containment within the allowed directory
- **Block `..` sequences** in any user-supplied path component
- **Prefer database-stored references** (file ID → storage path) over user-supplied filenames

```typescript
// NEVER — path from user input
const filePath = path.join(uploadDir, req.params.filename);

// ALWAYS — normalize and verify containment
const resolved = path.resolve(uploadDir, req.params.filename);
if (!resolved.startsWith(path.resolve(uploadDir))) throw new Error("Path traversal");
```

## File Upload Security

- **Limit file size server-side** (not just client-side) — enforce in middleware (e.g., 10MB cap)
- **Validate MIME type by reading file magic bytes** — never trust Content-Type header
- **Generate random filenames server-side** — never use the original filename
- **Store uploads outside web root** — serve via signed URLs or proxy endpoint
- **Scan for malware** for user uploads in high-risk contexts (e.g., ClamAV)
- **Restrict allowed file types** to explicit allowlist (e.g., `.jpg`, `.png`, `.pdf`)

## SQL Injection

- **Never use raw SQL with string concatenation**
- Use parameterized queries or ORM/query builders
- If raw SQL is unavoidable: use parameterized placeholders (`$1`, `$2`), never string interpolation

## Environment Variables and Secrets

```bash
# MUST be in .gitignore
.env
.env.local
.env.production
*.key
*.pem
secrets/

# NEVER ignore .env.example (commit it as documentation)
!.env.example
```

- **Validate env vars at startup** (fail fast with clear error messages)
- **Never hardcode secrets** in source code
- **Never expose server secrets to client** (no `NEXT_PUBLIC_` for API keys, no `VITE_` for server tokens)
- **Never commit .env files** — if leaked, rotate ALL secrets immediately

## Authentication and Authorization

- Verify auth on EVERY mutation endpoint and server action
- Use middleware for auth checks where possible (not per-handler)
- Validate JWT signatures — decoding alone is insufficient
- Store auth tokens in httpOnly, Secure, SameSite cookies (not localStorage)
- **Cookie auth pattern**: `SameSite=Lax` (or `Strict`) + CSRF token (double-submit or synchronizer token) for state-changing requests
- **Bearer token pattern**: hold in memory (not localStorage), send via `Authorization` header, never in URL params
- Rate limit auth endpoints (login, register, password reset)

## API Security Checklist

- [ ] Rate limiting: auth endpoints (5/min), public endpoints (throttled or behind secret), AI/export endpoints (rate proportional to cost)
- [ ] CORS whitelist (production domains only, never `*`)
- [ ] Security headers (Helmet, CSP, HSTS)
- [ ] Input validation on all endpoints (Zod/schema)
- [ ] CSRF protection for mutations
- [ ] No sensitive data in URL params or logs — mask tokens, passwords, emails, IPs
- [ ] Database RLS policies on all tables (if using Supabase/Postgres)

## Threat Model: Controls and Required Tests

| Threat | Control | Required Test |
|--------|---------|---------------|
| XSS | DOMPurify / auto-escape | Render user HTML → verify sanitized output |
| SQL injection | Parameterized queries / ORM | Pass `'; DROP TABLE--` → verify no raw execution |
| SSRF | Host allowlist + protocol check | Pass `http://169.254.169.254` → verify 400/blocked |
| Path traversal | `path.resolve` + containment check | Pass `../../etc/passwd` → verify 400 |
| Auth bypass | Middleware auth check | Request without token → verify 401 |
| Tenant isolation | orgId/ownerId filter | Request with wrong orgId → verify 403 + `service.not.toHaveBeenCalled()` |
| CSRF | SameSite cookie + CSRF token | POST without CSRF token → verify 403 |
| Rate limiting | Rate limiter middleware | N+1 requests → verify 429 |
| File upload abuse | Size limit + MIME check | Upload 50MB / `.exe` → verify rejected |
| Log leakage | PII masking | Trigger error with PII → verify logs are masked |

## Cryptographic Randomness

- **Never use `Math.random()` for tokens, secrets, or security-sensitive IDs** — use `crypto.randomUUID()`, `crypto.getRandomValues()`, or `crypto.randomBytes()`
- **Never use predictable seeds** for session IDs or CSRF tokens
- Python: use `secrets` module, not `random`

## Deserialization Safety

- **Never `eval()` or `new Function()` on untrusted input**
- **Never `pickle.loads()` on untrusted data** (Python) — use JSON or schema-validated formats
- **`JSON.parse()` on external input** must be followed by schema validation

## Security Event Logging

- **Log all failed authentication attempts** with IP, timestamp, username (not password)
- **Log authorization failures** (403s) with user ID, resource, action
- **Rate limit and alert** on repeated auth failures from same IP or user

## Dependency Security

- Run `npm audit` / `pip audit` on a regular schedule
- Update dependencies with known CVEs promptly
- Prefer well-maintained packages with active security response teams
- Lock dependency versions (lockfile committed to repo)
