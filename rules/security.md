# Security Standards

Stack-independent security requirements. OWASP-aligned.

---

## Boundary Input Validation — CQ3

- **Validate at every system boundary:** API endpoints, form submissions, webhooks, URL parameters
- **Use schema validation** (Zod, Joi, or equivalent) on all incoming data
- **Server-side validation is mandatory** — client-side validation is a UX convenience, not a security control
- **Sanitize before rendering** — especially user-generated HTML content

## Cross-Site Scripting (XSS) — CQ5, CAP6

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

## Server-Side Request Forgery (SSRF) — CQ31(d)

- **Allowlist external hosts** — user input must never control the full URL without validation
- **Block private IP ranges** in outbound requests — IPv4 AND IPv6 (an IPv4-only list is the
  classic bypass): `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`,
  `127.0.0.0/8`, `100.64.0.0/10` (CGNAT — used for cloud metadata on some providers), and
  `::1`, `fc00::/7` (ULA), `fe80::/10` (link-local), `::ffff:0:0/96` (IPv4-mapped — `::ffff:169.254.169.254` reaches the metadata endpoint through a v6-only check)
- **Re-validate after redirects** — an allowlisted host that 302s to an internal IP defeats the
  allowlist. Either disable redirects (`redirect: "error"` / `maxRedirects: 0`) or re-run the
  full host+IP validation on EVERY hop before following it
- **Resolve DNS and check the IP, not just the hostname** where feasible — a hostname can pass
  the allowlist and resolve to a private address (DNS rebinding); pin the resolved IP for the
  actual request
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

## Path Traversal — CQ31(a)

- **Never use user input directly in file paths** — map IDs/keys to stored paths instead
- **Normalize paths** with `path.resolve()` or `path.normalize()` and verify containment within the allowed directory
- **Block `..` sequences** in any user-supplied path component
- **Prefer database-stored references** (file ID → storage path) over user-supplied filenames
- **Symlinks escape a string-level check** — `realpath` the PARENT directory before the
  containment compare (the target itself may not exist yet), and open with `O_NOFOLLOW` where
  the platform supports it. A resolved-string check alone passes a symlink that points outside
  the base dir. (Full worked pattern incl. the symlink variant: `cq-patterns.md` → "Path
  traversal — validate before join/resolve".)

```typescript
// NEVER — path from user input
const filePath = path.join(uploadDir, req.params.filename);

// ALWAYS — string-level containment FIRST, then symlink-level via the TARGET's parent realpath
const base = await fs.promises.realpath(path.resolve(uploadDir));
const resolved = path.resolve(base, req.params.filename);
const rel = path.relative(base, resolved);
// segment compare — bare startsWith("..") also rejects a legit file named "..config";
// startsWith(baseDir) alone would pass /uploads-evil for base /uploads
if (rel === ".." || rel.startsWith(".." + path.sep) || path.isAbsolute(rel)) throw new Error("Path traversal");
// Symlink escape: a link INSIDE base can point outside — realpath the TARGET'S PARENT
// (not just base; the target itself may not exist yet) and re-run the compare:
const realParent = await fs.promises.realpath(path.dirname(resolved));
const relReal = path.relative(base, path.join(realParent, path.basename(resolved)));
if (relReal === ".." || relReal.startsWith(".." + path.sep) || path.isAbsolute(relReal)) throw new Error("Symlink escape");
// Open with O_NOFOLLOW where supported; note this remains check-then-use (see cq-patterns.md).
```

## File Upload Security — CQ31

- **Limit file size server-side** (not just client-side) — enforce in middleware (e.g., 10MB cap)
- **Validate MIME type by reading file magic bytes** — never trust Content-Type header
- **Generate random filenames server-side** — never use the original filename
- **Store uploads outside web root** — serve via signed URLs or proxy endpoint
- **Scan for malware** for user uploads in high-risk contexts (e.g., ClamAV)
- **Restrict allowed file types** to explicit allowlist (e.g., `.jpg`, `.png`, `.pdf`)

## SQL Injection — CAP8

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

## Authentication and Authorization — CQ4, CQ34

- Verify auth on EVERY mutation endpoint and server action
- Use middleware for auth checks where possible (not per-handler)
- Validate JWT signatures — decoding alone is insufficient
- Store auth tokens in httpOnly, Secure, SameSite cookies (not localStorage)
- **Cookie auth pattern**: `SameSite=Lax` (or `Strict`) + CSRF token (double-submit or synchronizer token) for state-changing requests
- **Bearer token pattern**: hold in memory (not localStorage), send via `Authorization` header, never in URL params
- Rate limit auth endpoints (login, register, password reset)

## Token Transport — CQ30

- **Never accept auth-bearing tokens via query params** — URL parameters leak into access logs, browser history, copied URLs, and `Referer` headers
- Preferred transport for bearer-style secrets: `Authorization` header or explicit `x-*-token` header
- Preferred transport for browser sessions: signed, httpOnly, Secure cookies
- Flag these patterns for review: `@Query('*token*')`, `?token=`, `?preview_token=`, `?api_key=`
- Public lookup IDs are not the same thing as auth tokens — only exempt values that are explicitly non-secret and non-authenticating

```typescript
// NEVER — token in query params
@Get("preview")
preview(@Query("preview_token") token: string) {}

// ALWAYS — token in header
@Get("preview")
preview(@Headers("x-preview-token") token: string) {}
```

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
| Credential leakage via URL | Header/cookie token transport | Request with `?token=` / `?preview_token=` → verify rejected |
| Tenant isolation | orgId/ownerId filter | Request with wrong orgId → verify 403 + `service.not.toHaveBeenCalled()` |
| CSRF | SameSite cookie + CSRF token | POST without CSRF token → verify 403 |
| Rate limiting | Rate limiter middleware | N+1 requests → verify 429 |
| File upload abuse | Size limit + MIME check | Upload 50MB / `.exe` → verify rejected |
| Log leakage | PII masking | Trigger error with PII → verify logs are masked |

## Cryptographic Randomness — CQ33

- **Never use `Math.random()` for tokens, secrets, or security-sensitive IDs** — use `crypto.randomUUID()`, `crypto.getRandomValues()`, or `crypto.randomBytes()`
- **Never use predictable seeds** for session IDs or CSRF tokens
- Python: use `secrets` module, not `random`

## Credential Storage — CQ33

- **Passwords/credentials: argon2id (preferred) or bcrypt with cost ≥ 12** — never a bare
  SHA-1/SHA-256/MD5, salted or not; fast hashes are brute-forceable by design
- **Never roll your own KDF or comparison** — use the library's verify function (it is
  constant-time); see `cq-patterns.md` → "Timing-safe secret comparison (CQ33)" for API-token
  comparison, which is a different case from password verification
- **API tokens/secrets stored server-side**: store a hash (SHA-256 of the token is acceptable
  HERE — tokens are high-entropy, unlike passwords), never the plaintext
- **Rehash on login when the cost parameter is below current policy** — cost params are config,
  not constants baked at signup time

## Deserialization Safety — CQ31(c), CAP25

- **Never `eval()` or `new Function()` on untrusted input**
- **Never `pickle.loads()` on untrusted data** (Python) — use JSON or schema-validated formats
- **`JSON.parse()` on external input** must be followed by schema validation

## Security Event Logging

- **Log all failed authentication attempts** with IP, timestamp, username (not password)
- **Log authorization failures** (403s) with user ID, resource, action
- **Rate limit and alert** on repeated auth failures from same IP or user

## Dependency Security — CQ32

- Run `npm audit` / `pip audit` on a regular schedule
- Update dependencies with known CVEs promptly
- Prefer well-maintained packages with active security response teams
- Lock dependency versions (lockfile committed to repo)
