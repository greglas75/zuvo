# Zuvo Trophy Case

> Real bugs and vulnerabilities found by Zuvo skills across production projects. Every finding listed here was discovered through automated analysis — no manual security review required.

---

## By the Numbers

| Metric | Count |
|--------|-------|
| Projects audited | 35 |
| Pentest findings (total) | 267 |
| CRITICAL findings | 37 |
| HIGH findings | 122 |
| Audit report files generated | 1,836+ |
| Findings remediated in-session | 33+ |

---

## Penetration Test Results (zuvo:pentest)

9 projects. 267 findings. 6 received a FAIL grade.

| Project | Grade | Score | CRITICAL | HIGH | MEDIUM | LOW | Total |
|---------|-------|-------|----------|------|--------|-----|-------|
| Project A (fraud detection) | FAIL | 8.6 | 12 | 31 | 16 | 0 | 59 |
| Project B (survey platform) | FAIL | 12 | 10 | 22 | 11 | 2 | 45 |
| Project C (rewards/payments) | FAIL | 11 | 7 | 10 | 12 | 0 | 29 |
| Project D (coding platform) | FAIL | 21 | 5 | 15 | 13 | 0 | 33 |
| Project E (offer management) | D | 40 | 1 | 12 | 11 | 3 | 27 |
| Project F (design studio) | D | 40 | 1 | 10 | 5 | 0 | 16 |
| Project G (translation QA) | FAIL | 40 | 1 | 9 | 4 | 0 | 14 |
| Project H (methodology) | C | 60 | 0 | 7 | 14 | 0 | 21 |
| Project I (survey SaaS) | C | 60 | 0 | 6 | 9 | 8 | 23 |

---

## Top 20 Findings

### CRITICAL — Authentication & Authorization

**1. Unauthenticated Batch Payout — $500/email, 500 emails/request**
- Skill: `zuvo:pentest` | CWE-306 | Confidence: 1.0
- A financial API endpoint accepted batch payout requests with zero authentication. Any HTTP client could trigger gift card purchases worth up to $250,000 per request.

**2. Unauthenticated Fraud Model Replacement**
- Skill: `zuvo:pentest` | CWE-862 | Confidence: 1.0
- A `@Public` endpoint allowed anyone to overwrite the fraud detection scoring model. An attacker could replace the model to let all fraudulent transactions pass.

**3. Unauthenticated Data Export**
- Skill: `zuvo:pentest` | CWE-862 | Confidence: 0.95
- Export API with zero authentication allowed any unauthenticated user to export any survey dataset.

**4. 62+ Public Mutation Endpoints on Auth Service**
- Skill: `zuvo:pentest` | CWE-862 | Confidence: 1.0
- A fraud detection service exposed 62+ endpoints as `@Public`, including mutation endpoints that could archive projects, inject scores, and modify configurations.

**5. AI Budget Middleware Never Applied**
- Skill: `zuvo:pentest` | CWE-862 | Confidence: 1.0
- Budget enforcement middleware existed in the codebase but was never imported or applied to any route. Users had unlimited AI API access.

### CRITICAL — Injection & SSRF

**6. SSRF to AWS Instance Metadata (IMDS)**
- Skill: `zuvo:pentest` | CWE-918 | Confidence: 0.97
- User-supplied URLs passed directly to `fetch()` with no validation. Attacker could reach AWS metadata service (169.254.169.254) to steal IAM credentials.

**7. Command Injection via Survey Name**
- Skill: `zuvo:pentest` | CWE-78 | Confidence: 0.85
- Survey names with single-quotes broke shell quoting in an SPSS export `exec()` call, enabling arbitrary command execution on the server.

**8. Stored XSS in 12+ React Components**
- Skill: `zuvo:pentest` | CWE-79 | Confidence: 0.95
- CKEditor content rendered via `dangerouslySetInnerHTML` across 12+ components. Any survey creator could inject scripts executed by all respondents.

### CRITICAL — Race Conditions & Logic Bugs

**9. Double Gift Card Purchase (TOCTOU)**
- Skill: `zuvo:pentest` | CWE-367 | Confidence: 0.97
- Concurrent requests both passed `validateClaimable()` and both purchased gift cards. A single reward could be claimed multiple times.

**10. Fraud Score Bypass via URL Parameter**
- Skill: `zuvo:pentest` | CWE-639 | Confidence: 0.97
- A `?rstest=1` URL parameter overrode the fraud score to pass-through, completely bypassing all fraud detection for any transaction.

**11. CSRF Protection Dead Code**
- Skill: `zuvo:pentest` | CWE-352 | Confidence: 1.0
- `PUBLIC_ENDPOINTS` list exempted every admin path using `startsWith()` matching, effectively disabling CSRF on all administrative operations.

**12. 4 Concurrent Race Conditions in One Service**
- Skill: `zuvo:pentest` | CWE-367 | Confidence: 0.8-0.97
- A translation QA platform had TOCTOU vulnerabilities on glossary entries, translation memory, QE threshold updates, and proofreading approval — all exploitable via concurrent requests.

### CRITICAL — Secrets & Credentials

**13. Hardcoded JWT Token (exp=2090) in Source Control**
- Skill: `zuvo:pentest` | CWE-798 | Confidence: 1.0
- A pre-signed JWT service token with `role=service` and expiry year 2090 was committed to git. Anyone with repo access had permanent service-level access.

**14. Fail-Open Runtime Auth**
- Skill: `zuvo:pentest` | CWE-862 | Confidence: 1.0
- If the auth secret was unset (empty env var), the middleware authorized ALL requests. A misconfigured deployment would have zero authentication.

### CRITICAL — Tenant Isolation

**15. No Tenant Isolation in 44 Files**
- Skill: `zuvo:code-audit` | Confidence: HIGH
- A travel platform had zero tenant checks across 44 files. Any authenticated user could access any company's bookings, customers, and financial data.

**16. Tenant Boundary Bypass via Falsy organization_id**
- Skill: `zuvo:pentest` | CWE-284 | Confidence: 0.8
- JavaScript `&&` short-circuit evaluation on empty string bypassed tenant isolation. An empty `organization_id` returned data across all tenants.

**17. Cross-Tenant Leak on Public Endpoints**
- Skill: `zuvo:pentest` | CWE-200 | Confidence: HIGH
- OG image and QR code endpoints lacked tenant filters, exposing contest data across organizations.

### HIGH — Data Integrity

**18. Float Arithmetic in Entire Money Stack**
- Skill: `zuvo:code-audit` | Confidence: HIGH
- Pricing, margins, and exchange rates all used floating-point arithmetic instead of fixed-point. Rounding errors accumulated across calculations.

**19. PII in Logs and API Responses**
- Skill: `zuvo:code-audit` | Confidence: HIGH
- Username, email, and `temporaryPassword` fields exposed in API responses and written to application logs.

**20. Path Traversal via Storage Service**
- Skill: `zuvo:code-audit` | CWE-22 | Confidence: HIGH
- `os.path.join()` called without `..` validation, allowing directory traversal to read/write arbitrary files on the server.

---

## Finding Categories

| Category | Findings | Skills that caught them |
|----------|----------|----------------------|
| Missing auth / broken authz | ~50+ | pentest, security-audit, code-audit |
| Stored XSS / DOM XSS | ~30+ | pentest, security-audit |
| IDOR / tenant bypass | ~15+ | pentest, code-audit |
| TOCTOU / race conditions | ~15+ | pentest, security-audit |
| SSRF | 4 | pentest |
| CSRF disabled/bypassed | 5+ | pentest, security-audit |
| Command/SQL injection | 3 | pentest |
| Hardcoded secrets | 2+ | pentest, env-audit |

---

## Audit Coverage

| Audit Skill | Reports Generated | Key Patterns Found |
|-------------|-------------------|-------------------|
| `zuvo:pentest` | 9 | Auth bypass, SSRF, XSS, race conditions, injection |
| `zuvo:code-audit` | ~30 | Tenant isolation, float money, PII leaks, path traversal |
| `zuvo:test-audit` | ~35 | Phantom mocks, orphan tests, weak assertions, missing coverage |
| `zuvo:performance-audit` | ~25 | N+1 queries, bundle bloat, memory leaks, missing indexes |
| `zuvo:security-audit` | ~15 | OWASP Top 10, secrets in env, missing headers, auth gaps |
| `zuvo:seo-audit` | ~15 | Missing structured data, broken meta tags, AI crawler blocks |
| `zuvo:db-audit` | ~8 | Missing indexes, N+1 patterns, unsafe migrations |
| `zuvo:dependency-audit` | ~8 | Vulnerable deps, dead packages, license conflicts |
| `zuvo:structure-audit` | ~8 | Dead code, naming inconsistencies, god files |
| `zuvo:env-audit` | ~8 | Missing validation, secret exposure, env parity gaps |
| `zuvo:api-audit` | ~6 | Missing pagination, inconsistent errors, missing rate limits |
| `zuvo:ci-audit` | ~3 | Unpinned actions, missing caches, no timeout guards |

---

## Remediation

- **33 pentest findings remediated in a single session** (Project D — all findings fixed, verified, and committed during the zuvo:pentest run)
- Multiple projects had findings auto-persisted to the backlog via `zuvo:backlog` for structured follow-up
- Security-critical findings triggered immediate `zuvo:build` tasks for remediation

---

*Data collected from 35 projects across ~/DEV. Findings anonymized for publication. Generated 2026-04-07.*
