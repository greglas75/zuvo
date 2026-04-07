# Zuvo Trophy Case

> Real bugs and vulnerabilities found by Zuvo skills across production projects. Every finding listed here was discovered through automated analysis — no manual security review required.

---

## By the Numbers

| Metric | Count |
|--------|-------|
| Projects scanned | 35 |
| Audit report files generated | 1,836+ |
| **Pentest findings** | **275** (54 CRITICAL, 122 HIGH) |
| **Code quality findings** | **90+** (12 CRITICAL, 50+ HIGH) |
| **Test quality findings** | **60+** (3 CRITICAL, 40+ HIGH) |
| **DB audit findings** | **40+** (5 CRITICAL, 20+ HIGH) |
| **Performance findings** | **30+** (4 CRITICAL, 15+ HIGH) |
| **API audit findings** | **15+** (0 CRITICAL, 10+ HIGH) |
| **SEO audit findings** | **15+** (6 CRITICAL, 8+ HIGH) |
| **CI/CD audit findings** | **10+** (3 CRITICAL, 5+ HIGH) |
| **Dependency audit findings** | **10+** (5 CRITICAL, 4+ HIGH) |
| **Env audit findings** | **8+** (0 CRITICAL, 5+ HIGH) |
| **Structure audit findings** | **10+** (3 CRITICAL, 5+ HIGH) |
| Findings remediated in-session | 41+ |
| **Total across all audits** | **550+** |

---

## Pentest Scoreboard

| Project | Grade | Score | CRITICAL | HIGH | MEDIUM | LOW | Total | Remediated |
|---------|-------|-------|----------|------|--------|-----|-------|------------|
| Project A (fraud detection) | FAIL | 8.6 | 18 | 33 | 16 | 0 | 67 | 0 |
| Project B (survey legacy) | FAIL | 12 | 10 | 22 | 13 | 2 | 47 | 0 |
| Project C (rewards/payments) | FAIL | 11 | 7 | 14 | 14 | 0 | 35 | 0 |
| Project D (coding platform) | FAIL | 21 | 5 | 16 | 12 | 0 | 33 | **33** |
| Project E (offer management) | D | 40 | 1 | 12 | 11 | 3 | 27 | 0 |
| Project F (design studio) | D | 40 | 1 | 10 | 5 | 0 | 16 | 0 |
| Project G (translation QA) | FAIL | 40 | 1 | 9 | 4 | 0 | 14 | 0 |
| Project H (methodology) | C | 60 | 0 | 7 | 14 | 0 | 21 | 8 |
| Project I (survey SaaS) | C | 60 | 0 | 6 | 9 | 8 | 23 | 0 |
| Project J (travel platform) | — | — | 0 | 0 | 2 | 0 | 2 | 0 |
| Project K (developer tool) | — | — | 0 | 1 | 4 | 0 | 5 | 0 |

---

## Findings by Category

| Category | Count | What Zuvo catches |
|----------|-------|-------------------|
| Authorization / Access Control | 72 | Missing auth, IDOR, tenant bypass, role bypass, privilege escalation |
| Business Logic | 53 | Race conditions, TOCTOU, state bypass, price manipulation, double-spend |
| Authentication / Session | 46 | Weak JWT, hardcoded secrets, session misconfig, rate limit gaps |
| XSS / Output Injection | 36 | Stored XSS, DOM XSS, dangerouslySetInnerHTML, ReactHtmlParser |
| Input Handling / CSRF | 31 | CSRF bypass, unrestricted upload, path traversal, missing validation |
| SSRF / Redirect | 10 | SSRF to AWS IMDS, open redirect, parameter injection |
| SQL / NoSQL / Command Injection | 8 | SQL injection, MongoDB regex injection, shell command injection |
| Security Audit (static) | 15 | Path traversal, file write, shell injection, info disclosure |
| Backlog (security-critical) | 7 | Double-pay risk, PII logging, CI breakage |

---

## All Findings

### Project A — Fraud Detection Service (FAIL: 8.6/100)

**Skill:** `zuvo:pentest` + `zuvo:security-audit`

| # | Severity | Finding | CWE | Conf |
|---|----------|---------|-----|------|
| PT4-001 | CRITICAL | @Secret() bypassed by @Public() — guard evaluation order bug | CWE-862 | 1.00 |
| PT4-002 | CRITICAL | @Public backup trigger with TODO comment to remove | CWE-862 | 1.00 |
| PT4-003 | CRITICAL | @Public scoring config overwrite — fraud model replaceable by anyone | CWE-862 | 1.00 |
| PT4-004 | CRITICAL | @Public bulk project status mutation via CSV upload | CWE-862 | 1.00 |
| PT4-005 | CRITICAL | @Public score recalculation for arbitrary sessionIds | CWE-862 | 1.00 |
| PT4-006 | CRITICAL | @Public result field migration | CWE-862 | 1.00 |
| PT4-007 | CRITICAL | @Public source mapping creation (POST unprotected) | CWE-862 | 1.00 |
| PT4-008 | CRITICAL | @Public log injection — arbitrary log entries created | CWE-862 | 1.00 |
| PT5-001 | CRITICAL | @Public endpoint passes user URL to fetch() — AWS IMDS reachable | CWE-918 | 0.97 |
| PT7-001 | CRITICAL | ?rstest=1 URL param overrides fraud score to pass-through | CWE-639 | 0.97 |
| PT7-003 | CRITICAL | Unauthenticated webhook: inject status, trigger score recalc, archive | CWE-345 | 0.98 |
| PT7-004 | CRITICAL | Duplicate session check hardcoded to false — unlimited sessions | CWE-367 | 0.96 |
| SEC-001 | CRITICAL | Unauthenticated Scoring Configuration Upload | CWE-306 | HIGH |
| SEC-002 | CRITICAL | Unauthenticated Backup Trigger | CWE-306 | HIGH |
| SEC-003 | CRITICAL | Unauthenticated Pattern Creation | CWE-306 | HIGH |
| SEC-004 | CRITICAL | Hardcoded AWS Credentials in Source Code | CWE-798 | HIGH |
| SEC-005 | CRITICAL | Client-Side-Only Admin Panel Authentication (password: 12345678) | CWE-602 | HIGH |
| SEC-006 | CRITICAL | Unauthenticated Project Status Upload | CWE-306 | HIGH |
| PT1-001 | HIGH | Three @Public query params reach MongoDB via unescaped RegExp() | CWE-943 | 0.95 |
| PT1-002 | HIGH | @Public rsLinkId URL param reaches MongoDB $regex unescaped | CWE-943 | 0.95 |
| PT2-001 | HIGH | WYSIWYG HTML stored unsanitized, rendered via dangerouslySetInnerHTML | CWE-79 | 0.95 |
| PT2-003 | HIGH | @Public upload page: CSV projectId cell concatenated into innerHTML | CWE-79 | 0.92 |
| PT3-001 | HIGH | JWT stored in localStorage; any XSS exfiltrates admin tokens | CWE-922 | 1.00 |
| PT3-002 | HIGH | Zero rate limiting anywhere; login and 2FA brute-forceable | CWE-307 | 1.00 |
| PT3-003 | HIGH | MOBI_CLIENT_SECRET in x-api-key bypasses 2FA for any account | CWE-287 | 0.85 |
| PT3-004 | HIGH | HS256 JWT with default-zero expiry if env vars unset | CWE-287 | 0.90 |
| PT3-006 | HIGH | 62+ @Public endpoints including mutation endpoints | CWE-862 | 1.00 |
| PT4-009 | HIGH | @Public fraud pattern creation | CWE-862 | 1.00 |
| PT4-010 | HIGH | @Public broadcast cache invalidation | CWE-862 | 1.00 |
| PT4-011 | HIGH | @Public Redis/local cache flush | CWE-862 | 1.00 |
| PT4-012 | HIGH | @Public batch score recalculation with DB writes | CWE-862 | 0.95 |
| PT4-013 | HIGH | Any authenticated user can PATCH/DELETE any organization | CWE-639 | 0.95 |
| PT4-014 | HIGH | Any authenticated user can PATCH/DELETE any user cross-tenant | CWE-639 | 0.90 |
| PT4-015 | HIGH | DELETE source redirect missing tenant check | CWE-639 | 0.92 |
| PT4-016 | HIGH | Any authenticated user can create organizations (no role check) | CWE-269 | 0.90 |
| PT4-017 | HIGH | @Public log query — unauthenticated enumeration of IPs/URLs | CWE-862 | 1.00 |
| PT4-018 | HIGH | @Public raw respondent analysis data for any sessionId | CWE-862 | 1.00 |
| PT4-019 | HIGH | @Public raw survey answers for any sessionId | CWE-862 | 1.00 |
| PT4-020 | HIGH | @Public full result data for any session cross-tenant | CWE-862 | 1.00 |
| PT5-002 | HIGH | Authenticated internal proxy with full path/method/body control | CWE-918 | 0.85 |
| PT6-001 | HIGH | @Public file upload with no size/type limits | CWE-434 | 0.98 |
| PT6-002 | HIGH | @Public CSV upload with extension-only check | CWE-434 | 0.97 |
| PT6-004 | HIGH | sessionId interpolated into Content-Disposition header (CRLF) | CWE-113 | 0.96 |
| PT6-005 | HIGH | No CSRF protection anywhere; SameSite: none | CWE-352 | 0.95 |
| PT6-006 | HIGH | ValidationPipe missing whitelist:true; 85% DTOs zero validation | CWE-20 | 0.97 |
| PT6-008 | HIGH | @Public webhook with @Body() any stored directly to MongoDB | CWE-20 | 0.96 |
| PT7-002 | HIGH | ?test=1 URL param forces redirect to testLink | CWE-639 | 0.95 |
| PT7-005 | HIGH | Session event injection for any sessionId — no ownership | CWE-639 | 0.95 |
| PT7-006 | HIGH | findOneBy + conditional save without atomic upsert — TOCTOU | CWE-367 | 0.90 |
| B-1 | HIGH | Hardcoded API key X_FACTOR_X (200+ char) in humanTyping.ts | — | — |
| PT1-003 | MEDIUM | Source mapping code reaches anchored RegExp unescaped | CWE-943 | 0.88 |
| PT1-004 | MEDIUM | Answer text reaches anchored RegExp unescaped | CWE-943 | 0.85 |
| PT1-005 | MEDIUM | operatingSystems array elements reach RegExp unescaped | CWE-943 | 0.82 |
| PT2-002 | MEDIUM | Question/translation text rendered via dangerouslySetInnerHTML | CWE-79 | 0.80 |
| PT2-004 | MEDIUM | Admin preview renders unsanitized HTML | CWE-79 | 0.85 |
| PT3-005 | MEDIUM | Token invalidation relies on DB availability | CWE-613 | 0.75 |
| PT3-007 | MEDIUM | 404 for unknown email vs 401 for wrong password — enumeration | CWE-204 | 0.95 |
| PT3-008 | MEDIUM | 2FA temp sessions in JS Map; lost on restart | CWE-384 | 0.90 |
| PT4-021 | MEDIUM | @Public project stats cross-tenant | CWE-862 | 0.95 |
| PT4-022 | MEDIUM | @Public queue job stats with potential exposure | CWE-862 | 0.90 |
| PT4-023 | MEDIUM | @Public tracking event search cross-tenant | CWE-862 | 1.00 |
| PT4-024 | MEDIUM | @Public verify endpoint triggers score calculation | CWE-862 | 0.90 |
| PT5-003 | MEDIUM | X-Forwarded-For trusted without validation; IP spoofing | CWE-346 | 0.88 |
| PT6-003 | MEDIUM | Authenticated XLSX upload with no size limit — zip bomb | CWE-434 | 0.90 |
| PT6-007 | MEDIUM | @Body() any with CSV-to-DB — attacker keys become country codes | CWE-20 | 0.88 |
| PT7-008 | MEDIUM | FingerprintJS visitor ID accepted without server verification | CWE-345 | 0.85 |

---

### Project B — Survey Platform Legacy (FAIL: 12/100)

**Skill:** `zuvo:pentest`

| # | Severity | Finding | CWE | Conf |
|---|----------|---------|-----|------|
| PT1-001 | CRITICAL | Survey name breaks shell quoting in SPSS export exec() | CWE-78 | 0.85 |
| PT2-003 | CRITICAL | User-Agent rendered via dangerouslySetInnerHTML in admin | CWE-79 | 0.95 |
| PT2-008 | CRITICAL | Question text from CKEditor via dangerouslySetInnerHTML (12 variants) | CWE-79 | 0.95 |
| PT3-005 | CRITICAL | Pre-signed JWT service token (role=service, exp=2090) committed to git | CWE-798 | 1.00 |
| PT4-001 | CRITICAL | Export API has no auth — any user can export any survey data | CWE-862 | 0.95 |
| PT4-002 | CRITICAL | IP blacklist add/delete unauthenticated | CWE-862 | 0.97 |
| PT4-003 | CRITICAL | Quota import unauthenticated | CWE-862 | 0.93 |
| PT4-004 | CRITICAL | All v2 API CRUD — cross-user read/update/delete (6 variants) | CWE-639 | 0.98 |
| PT6-011 | CRITICAL | ReportController removes AccessControl + disables CSRF — unauth financial write | CWE-862 | 1.00 |
| PT7-001 | CRITICAL | Quota counter read-modify-write on JSON blob without row lock | CWE-362 | 1.00 |
| PT1-002 | HIGH | CSV supplier values concatenated into INSERT VALUES without escaping | CWE-89 | 0.90 |
| PT2-001 | HIGH | WIDGET question type: innerHTML + script re-execution | CWE-79 | 0.95 |
| PT2-004 | HIGH | CKEditor comment HTML via Html::decode() without HtmlPurifier (3 variants) | CWE-79 | 0.90 |
| PT2-005 | HIGH | Task description via Html::decode() without sanitization | CWE-79 | 0.85 |
| PT2-007 | HIGH | Survey name unencoded in 7+ view files | CWE-79 | 0.90 |
| PT2-009 | HIGH | jQuery .html() renders comment HTML from AJAX without sanitization | CWE-79 | 0.90 |
| PT3-001 | HIGH | CSRF validation disabled on 15+ controllers (15 variants) | CWE-352 | 1.00 |
| PT3-002 | HIGH | Yii2 cookieValidationKey hardcoded — cookie forgery | CWE-798 | 0.95 |
| PT3-003 | HIGH | Session cookies lack httpOnly/secure/sameSite + MFA bypassed | CWE-614 | 1.00 |
| PT3-004 | HIGH | JWT HS256 secret key hardcoded — token forgery | CWE-798 | 1.00 |
| PT3-006 | HIGH | Login no rate limiting beyond optional reCAPTCHA | CWE-307 | 0.90 |
| PT3-008 | HIGH | JWT decode failure silently falls back to robot user auth_key | CWE-287 | 0.90 |
| PT4-007 | HIGH | Any Authorization header removes module-level AccessControl | CWE-287 | 0.85 |
| PT4-008 | HIGH | ShareLink token grants cross-survey data access | CWE-639 | 0.92 |
| PT4-009 | HIGH | Survey model allows mass assignment of user_id/assigned_user_id | CWE-915 | 0.82 |
| PT4-010 | HIGH | RMS API loads surveys by bare ID with no ownership check | CWE-639 | 0.88 |
| PT5-005 | HIGH | Unsigned RMS cookie supplies URI for postback — affiliate fraud | CWE-20 | 0.90 |
| PT6-001 | HIGH | File upload with MIME validation disabled (2 variants) | CWE-434 | 1.00 |
| PT6-006 | HIGH | Survey import accepts any file type — no validation | CWE-434 | 1.00 |
| PT7-002 | HIGH | Bid value from attacker-controlled URL param 'bd' — no server validation | CWE-20 | 1.00 |
| PT7-003 | HIGH | Survey status accepts any value via GET + CSRF disabled | CWE-284 | 1.00 |
| PT7-004 | HIGH | MaxSample check non-atomic — concurrent respondents bypass quota | CWE-362 | 1.00 |
| PT2-006 | MEDIUM | Alias intro HTML rendered via dangerouslySetInnerHTML (static copy) | CWE-79 | 0.85 |
| PT2-011 | MEDIUM | jQuery .html() renders error messages from AJAX without encoding | CWE-79 | 0.70 |
| PT3-007 | MEDIUM | MFA bypassed via cookie-based login + gracePeriod null | CWE-287 | 0.85 |
| PT3-009 | MEDIUM | Surveybot API key hardcoded and exposed via unauth endpoint | CWE-798 | 1.00 |
| PT3-010 | MEDIUM | No absoluteAuthTimeout + 7-day remember-me = persistent sessions | CWE-613 | 0.85 |
| PT5-001 | MEDIUM | Phone number concatenated without urlencode() into external API URL | CWE-918 | 0.70 |
| PT5-004 | MEDIUM | Inbound URL query params injected unencoded into outbound postbacks | CWE-20 | 0.75 |
| PT6-005 | MEDIUM | Translation import uses extension-only validation — XXE risk | CWE-611 | 0.80 |
| PT6-007 | MEDIUM | Attacker-controlled filename used as S3 key without sanitization | CWE-22 | 0.80 |
| PT7-007 | MEDIUM | Retroactive bid modification on cost-approved interviews | CWE-840 | 1.00 |
| PT7-008 | MEDIUM | Cost approval findOne-then-save without row lock | CWE-362 | 1.00 |
| B-5 | MEDIUM | XSS risk: unescaped $username in prepareUserMentionsList() | CWE-79 | — |
| PT7-006 | LOW | startSurvey() re-saves FINISHED records — unbounded tryings counter | CWE-841 | 1.00 |
| PT7-009 | LOW | No deduplication guard on export job creation — queue flooding | CWE-362 | 1.00 |

---

### Project C — Rewards & Payments API (FAIL: 11/100)

**Skill:** `zuvo:pentest`

| # | Severity | Finding | CWE | Conf |
|---|----------|---------|-----|------|
| PT4-001 | CRITICAL | Unauthenticated batch payout — $500/email, 500 emails/request | CWE-306 | 1.00 |
| PT7-001 | CRITICAL | TOCTOU race — double gift card purchase | CWE-367 | 0.97 |
| PT7-002 | CRITICAL | Missing rollback after fulfillment failure — double-spend on retry | CWE-841 | 0.95 |
| PT2-001 | CRITICAL | Stored XSS in smart link page body — unescaped HTML | CWE-79 | 0.95 |
| PT6-001 | CRITICAL | CSRF protection dead — all admin mutation endpoints exempted | CWE-352 | 1.00 |
| PT4-002 | CRITICAL | Project management accepts any JWT — no admin role check | CWE-285 | 1.00 |
| PT4-003 | CRITICAL | Missing admin role checks across 30+ financial/operational endpoints | CWE-285 | 1.00 |
| PT1-001 | HIGH | PostgREST filter injection — unsanitized .or() | CWE-89 | 0.85 |
| PT2-002 | HIGH | Stored XSS in privacy policy template body | CWE-79 | 0.90 |
| PT5-001 | HIGH | Open redirect — any user can set arbitrary review_url | CWE-601 | 0.88 |
| PT3-001 | HIGH | JWT verification missing algorithm restriction and aud/iss checks | CWE-345 | 0.95 |
| PT3-003 | HIGH | Content template read/export completely unauthenticated | CWE-306 | 0.98 |
| PT6-002 | HIGH | CSRF cookie SameSite=None without HttpOnly | CWE-352 | 0.90 |
| PT7-004 | HIGH | Email duplicate check silently bypasses on DB error | CWE-367 | 0.88 |
| PT7-005 | HIGH | Resend-cysend guard bypassed when reward_method='paypal' | CWE-841 | 0.92 |
| PT7-006 | HIGH | Per-email claim limit not enforced for MOBI flow | CWE-840 | 0.90 |
| PT4-012 | HIGH | Unsubscribe token generation endpoints — no auth | CWE-306 | 0.90 |
| B-27 | CRITICAL | CI pipeline broken — ~270 failing tests | — | — |
| B-28 | CRITICAL | Dual-write defect — webhook.service + postmark-webhook (double counters) | — | — |
| B-40 | CRITICAL | 30s timeout double-pay risk — PayPal races CySend fallback | — | — |
| B-29 | HIGH | PII (email) in worker service logs — 3 services | — | — |
| PT2-003 | MEDIUM | Reflected XSS via ?lang query parameter in HTML attribute | CWE-79 | 0.75 |
| PT5-002 | MEDIUM | Smart link redirect accepts javascript:/data: URIs | CWE-601 | 0.72 |
| PT3-002 | MEDIUM | Role revocation has 5-minute blind window via KV cache | CWE-613 | 0.90 |
| PT3-006 | MEDIUM | PayPal webhook signature verification optional | CWE-345 | 0.95 |
| PT4-011 | MEDIUM | Email analytics event injection — unauthenticated POST | CWE-306 | 0.85 |
| PT7-007 | MEDIUM | Payment method accepted from client without project validation | CWE-840 | 0.85 |
| PT6-004 | MEDIUM | File upload validation is extension-only — no MIME check | CWE-434 | 0.85 |
| PT6-005 | MEDIUM | Content-length guard bypassable by omitting header | CWE-400 | 0.90 |
| PT7-008 | MEDIUM | PayPal webhook handler has no event-ID idempotency guard | CWE-841 | 0.82 |
| PT7-010 | MEDIUM | findOrCreateForStart race — reward sent to wrong email | CWE-367 | 0.78 |
| PT6-006 | MEDIUM | Server Actions CSRF does not extend to directly-reachable worker | CWE-352 | 0.85 |
| PT7-009 | MEDIUM | Batch-send emails — no dedup — 500x = 500 gift cards | CWE-20 | 0.80 |
| B-42 | MEDIUM | replaceTemplateVariables — unsanitized values in HTML (XSS) | — | — |

---

### Project D — Coding Platform (FAIL: 21/100, ALL 33 REMEDIATED)

**Skill:** `zuvo:pentest` — every finding was fixed during the pentest session.

| # | Severity | Finding | CWE | Conf | Fixed |
|---|----------|---------|-----|------|-------|
| PT3-002 | CRITICAL | Fail-open runtime auth when secret unset | CWE-287 | 1.00 | YES |
| PT3-003 | CRITICAL | Service role key set to anon key — silently degraded | CWE-287 | 1.00 | YES |
| PT5-002 | CRITICAL | Full SSRF: user-supplied image URLs to requests.get() — no validation | CWE-918 | 0.97 | YES |
| PT6-001 | CRITICAL | CSRF middleware registered after routes — never applied | CWE-352 | 0.95 | YES |
| PT7-001 | CRITICAL | Budget enforcement middleware never imported or applied | CWE-862 | 1.00 | YES |
| PT3-001 | HIGH | Integration routes have zero auth middleware | CWE-287 | 1.00 | YES |
| PT3-004 | HIGH | Third-party AI API keys stored as plain text in localStorage | CWE-922 | 1.00 | YES |
| PT4-001 | HIGH | All /api/v1/codes endpoints lack auth; uses supabaseAdmin | CWE-862 | 0.95 | YES |
| PT4-002 | HIGH | Integration ingest — zero ownership verification on categoryId | CWE-639 | 1.00 | YES |
| PT4-003 | HIGH | POST /api/answers/filter has no user_id or org_id filter | CWE-639 | 1.00 | YES |
| PT4-004 | HIGH | All 5 sentiment mutation endpoints — no ownership verification | CWE-639 | 1.00 | YES |
| PT4-005 | HIGH | File upload accepts any category_id — no ownership check | CWE-639 | 1.00 | YES |
| PT5-001 | HIGH | Gemini proxy model in URL path — only length validation | CWE-918 | 0.90 | YES |
| PT5-003 | HIGH | User-supplied image URLs forwarded to Claude API — proxied SSRF | CWE-918 | 0.85 | YES |
| PT6-002 | HIGH | CSRF getSessionIdentifier returns hardcoded empty string | CWE-352 | 0.90 | YES |
| PT6-003 | HIGH | MIME type check disabled by default | CWE-434 | 0.95 | YES |
| PT7-002 | HIGH | applyCodeframe() skips status check — corrupts with partial data | CWE-367 | 0.95 | YES |
| PT7-003 | HIGH | Brand approval IDOR: any user can approve/reject any hierarchy node | CWE-639 | 0.95 | YES |
| PT7-004 | HIGH | POST /api/v1/codes/bulk-create accepts unbounded array | CWE-400 | 1.00 | YES |
| PT7-005 | HIGH | Codeframe generate accepts unbounded answer_ids array | CWE-400 | 0.90 | YES |
| PT2-001 | MEDIUM | Google API URLs stored without protocol validation — javascript: href | CWE-79 | 0.75 | YES |
| PT2-002 | MEDIUM | WebContext.url stored without protocol check — anchor href | CWE-79 | 0.70 | YES |
| PT3-007 | MEDIUM | Legacy secret comparison uses === (timing-unsafe) | CWE-208 | 0.80 | YES |
| PT4-006 | MEDIUM | Codeframe GET/PATCH/POST — no ownership check | CWE-639 | 0.90 | YES |
| PT4-007 | MEDIUM | AI proxy routes mounted before auth middleware | CWE-862 | 0.85 | YES |
| PT4-010 | MEDIUM | CostRepository filters by userId only when defined | CWE-639 | 0.85 | YES |
| PT4-011 | MEDIUM | Audit log records user_email from attacker x-user-email header | CWE-117 | 1.00 | YES |
| PT4-012 | MEDIUM | getUserId() falls back to 'system' when unauthenticated | CWE-287 | 0.80 | YES |
| PT6-004 | MEDIUM | Error path stores unsanitized req.file.originalname | CWE-117 | 0.85 | YES |
| PT6-005 | MEDIUM | validateFileContent checks multer temp path (no extension) | CWE-434 | 0.80 | YES |
| PT7-006 | MEDIUM | mark-not-applicable/mark-applicable accept unbounded answer_ids | CWE-400 | 1.00 | YES |
| PT7-007 | MEDIUM | User-supplied API keys forwarded to Python service | CWE-862 | 0.85 | YES |
| PT7-008 | MEDIUM | PATCH hierarchy allows any user to rename/delete/move/merge nodes | CWE-639 | 0.90 | YES |

---

### Project E — Offer Management Frontend (D: 40/100)

**Skill:** `zuvo:pentest`

| # | Severity | Finding | CWE | Conf |
|---|----------|---------|-----|------|
| PT2-001 | CRITICAL | Comment content via dangerouslySetInnerHTML with zero sanitization | CWE-79 | 0.95 |
| PT2-002 | HIGH | Extra service description_html via dangerouslySetInnerHTML without DOMPurify | CWE-79 | 0.90 |
| PT2-003 | HIGH | client_brief via ReactHtmlParser (zero sanitization) across 5 components | CWE-79 | 0.85 |
| PT2-004 | HIGH | manual_quota via ReactHtmlParser without sanitization | CWE-79 | 0.85 |
| PT2-005 | HIGH | Project scope fields via ReactHtmlParser across 4 components | CWE-79 | 0.85 |
| PT2-006 | HIGH | Tiptap link toolbar accepts javascript: protocol | CWE-79 | 0.90 |
| PT3-001 | HIGH | JWT access_token stored in localStorage (AUTH_STORE key) | CWE-922 | 1.00 |
| PT3-002 | HIGH | Zustand persist stores accessToken+refreshToken in localStorage | CWE-922 | 1.00 |
| PT4-001 | HIGH | Route /offers-external/:id has no ProtectedRoute wrapper | CWE-862 | 0.90 |
| PT4-002 | HIGH | Mutation route /offers-external/:id/edit has no ProtectedRoute | CWE-862 | 0.85 |
| PT4-005 | HIGH | Admin routes protected only by UI menu filtering, not route guards; ?? true default | CWE-863 | 0.85 |
| PT7-001 | HIGH | All offer price/cost totals computed client-side (fraudulent PDF) | CWE-602 | 0.90 |
| PT7-002 | HIGH | Extra service costs/multi-currency conversions computed client-side | CWE-602 | 0.85 |
| PT2-015 | MEDIUM | Jodit paste handler strips CSS but not dangerous HTML elements | CWE-79 | 0.70 |
| PT3-003 | MEDIUM | REFRESH_TOKEN_EP defined but never called; 401 logs out | CWE-613 | 0.95 |
| PT3-005 | MEDIUM | MFA bypass cookie without Secure or SameSite attributes | CWE-614 | 0.90 |
| PT3-006 | MEDIUM | OTP bypass cookie stores clientId and PIN in plaintext, 30 days | CWE-312 | 0.90 |
| PT4-003 | MEDIUM | Preview route has no ProtectedRoute; relies on startup-only token check | CWE-862 | 0.80 |
| PT4-004 | MEDIUM | /forgot-password wrapped in AuthenticatedLayout — lockout | CWE-863 | 0.95 |
| PT4-006 | MEDIUM | Offer ID from URL passed directly to API, no ownership check | CWE-639 | 0.80 |
| PT4-007 | MEDIUM | Public share view with sequential IDs; OTP gate disabled by env var | CWE-639 | 0.75 |
| PT5-002 | MEDIUM | PDF export sends credentials:'include' to any cross-origin source | CWE-346 | 0.80 |
| PT6-005 | MEDIUM | Avatar upload checks size but not MIME type | CWE-434 | 0.82 |
| PT7-005 | MEDIUM | Redux DevTools likely enabled in production | CWE-602 | 0.80 |
| PT3-004 | LOW | authSlice logout removes AUTH_STORE but not isAuthenticated key | CWE-613 | 0.75 |
| PT3-007 | LOW | Axios interceptor logs full error.response.data in production | CWE-209 | 0.70 |
| PT4-008 | LOW | MFA page in external app has mfa hardcoded to false (non-functional) | CWE-287 | 0.70 |

---

### Project F — AI Design Studio (D: 40/100)

**Skill:** `zuvo:pentest`

| # | Severity | Finding | CWE | Conf |
|---|----------|---------|-----|------|
| PT7-001 | CRITICAL | AI Budget Bypass via Concurrent Requests (No-Redis Race) | CWE-367 | 0.90 |
| PT2-001 | HIGH | Stored XSS via javascript: href in Tiptap Editor | CWE-79 | 0.85 |
| PT2-002 | HIGH | Stored XSS via HTML Mode Textarea | CWE-79 | 0.80 |
| PT3-001 | HIGH | Invitation Token Readable by Any Authenticated User | CWE-862 | 0.75 |
| PT4-001 | HIGH | IDOR in Media Upload (Cross-Tenant siteId) | CWE-639 | 0.90 |
| PT6-001 | HIGH | data: URI Scheme Allowed in HTML Sanitizer | CWE-79 | 0.95 |
| PT6-002 | HIGH | DOCX Import Bypasses HTML Sanitization | CWE-79 | 0.90 |
| PT6-003 | HIGH | Path Traversal via Git CMS contentPath | CWE-22 | 0.92 |
| PT6-004 | HIGH | URL Import Stores External HTML Without Sanitization | CWE-79 | 0.88 |
| PT7-002 | HIGH | Invitation Accept Race Condition | CWE-367 | 0.85 |
| PT7-003 | HIGH | Owner Count Race Condition (Permanent Org Lockout) | CWE-367 | 0.85 |
| PT3-002 | MEDIUM | Metrics Endpoint Unprotected in Dev/Staging | CWE-200 | 0.95 |
| PT3-003 | MEDIUM | Rate Limiter Middleware Ordering Defeats userId Keying | CWE-362 | 1.00 |
| PT7-004 | MEDIUM | Model Override Bypasses Plan-Level Restrictions | CWE-269 | 0.75 |
| PT7-005 | MEDIUM | Bulk Publish Bypasses Status Guard | CWE-840 | 0.80 |
| PT7-006 | MEDIUM | Invitation Creation Race (Duplicate Pending) | CWE-367 | 0.75 |

---

### Project G — Translation QA Platform (FAIL: 40/100)

**Skill:** `zuvo:pentest`

| # | Severity | Finding | CWE | Conf |
|---|----------|---------|-----|------|
| PT4-005 | CRITICAL | Tenant boundary bypass via falsy organization_id (JS && short-circuit) | CWE-284 | 0.80 |
| PT3-001 | HIGH | Unauthenticated HITL dashboard — leaks all campaign data | CWE-287 | 1.00 |
| PT3-002 | HIGH | Unauthenticated HITL session GET — returns full session content | CWE-287 | 1.00 |
| PT4-001 | HIGH | IDOR on dictionary review — cross-tenant project access | CWE-639 | 1.00 |
| PT4-003 | HIGH | Unauthenticated HITL review POST — writes verdicts without auth | CWE-862 | 1.00 |
| PT4-006 | HIGH | IDOR on proofreading demo-link — creates link for arbitrary session | CWE-639 | 0.90 |
| PT7-001 | HIGH | Cost rate limit race condition — non-atomic bypass | CWE-362 | 0.85 |
| PT7-002 | HIGH | Glossary/TM TOCTOU — findFirst+create without transaction | CWE-367 | 0.95 |
| PT7-003 | HIGH | QE threshold TOCTOU — findFirst+create without transaction | CWE-367 | 0.90 |
| PT7-004 | HIGH | Proofreading approve race — 4 DB ops without transaction | CWE-362 | 0.85 |
| PT4-002 | MEDIUM | IDOR on agent review models — leaks AI config for any project | CWE-639 | 0.90 |
| PT4-004 | MEDIUM | Unauthenticated HITL session/grouped — returns translation content | CWE-862 | 0.85 |
| PT7-005 | MEDIUM | Billing guard TOCTOU — plan limit bypass by one seat | CWE-367 | 0.80 |
| PT7-006 | MEDIUM | Cost rate limiting disabled by default — unbounded AI calls | CWE-799 | 0.75 |

---

### Project H — Methodology Platform (C: 60/100)

**Skill:** `zuvo:pentest` — 8 findings remediated in-session.

| # | Severity | Finding | CWE | Conf | Fixed |
|---|----------|---------|-----|------|-------|
| PT4-001 | HIGH | Cross-org permission template delete/modify — missing orgId filter | CWE-639 | 0.95 | YES |
| PT4-002 | HIGH | Cross-workspace share revocation — missing workspaceId filter | CWE-639 | 0.95 | YES |
| PT3-001 | HIGH | getSession() instead of getUser() — revoked tokens accepted | CWE-287 | 0.95 | No |
| PT3-002 | HIGH | No rate limit on password login — type defined but never applied | CWE-307 | 0.95 | No |
| PT7-002 | HIGH | leaveWorkspace TOCTOU — concurrent leave creates ownerless workspace | CWE-367 | 0.80 | YES |
| PT7-003 | HIGH | Risk state machine bypass — RESOLVED can be reopened | CWE-840 | 0.90 | YES |
| PT7-005 | HIGH | No workspace-level AI cost budget — no aggregate cost cap | CWE-770 | 0.80 | No |
| PT3-003 | MEDIUM | No rate limit on registration/magic link — email flooding | CWE-307 | 0.90 | No |
| PT3-006 | MEDIUM | CRON_SECRET optional — cron endpoint unauth when unset | CWE-287 | 0.95 | YES |
| PT3-008 | MEDIUM | Health endpoint leaks infrastructure topology | CWE-200 | 0.85 | YES |
| PT3-009 | MEDIUM | Rate limit configuration publicly disclosed | CWE-200 | 0.70 | YES |
| PT3-011 | MEDIUM | Shared document GET has no rate limit | CWE-770 | 0.80 | YES |
| PT4-003 | MEDIUM | Workspace OWNER can trigger system-wide reindex via { all: true } | CWE-269 | 0.90 | No |
| PT6-001 | MEDIUM | File upload MIME type confusion — extension-only, attacker contentType | CWE-434 | 0.92 | No |
| PT6-002 | MEDIUM | CSRF on shared comments — cross-origin POST | CWE-352 | 0.85 | No |
| PT6-003 | MEDIUM | AI response JSON parsed with unsafe 'as' cast instead of Zod | CWE-502 | 0.80 | No |
| PT7-001 | MEDIUM | inviteMember TOCTOU — concurrent invites create duplicate membership | CWE-367 | 0.85 | No |
| PT7-004 | MEDIUM | Risk cross-terminal state transitions allowed | CWE-840 | 0.85 | No |
| PT7-006 | MEDIUM | No workspace count cap per organization | CWE-770 | 0.70 | No |
| PT7-007 | MEDIUM | 5000-UUID IN clause on every dashboard load | CWE-400 | 0.75 | No |
| PT7-008 | MEDIUM | createWorkspace slug uniqueness TOCTOU | CWE-367 | 0.75 | No |

---

### Project I — Survey SaaS Platform (C: 60/100)

**Skill:** `zuvo:pentest`

| # | Severity | Finding | CWE | Conf |
|---|----------|---------|-----|------|
| PT3-002 | HIGH | Known-weak default JWT secret bypasses production guard | CWE-798 | 0.90 |
| PT3-007 | HIGH | Bot secret compared with === (timing-unsafe); secret in URL params | CWE-208 | 0.95 |
| PT6-001 | HIGH | SameSite=None respondent cookie + no CSRF token on mutations | CWE-352 | 0.95 |
| PT6-002 | HIGH | @Public feedback mutations — no auth, no CSRF, no origin check | CWE-862 | 0.97 |
| PT7-001 | HIGH | activate() bypasses STATUS_TRANSITIONS via publishDraft() | CWE-367 | 0.92 |
| PT7-003 | HIGH | Script jumpToPage() has no forward-only constraint | CWE-367 | 0.90 |
| PT3-001 | MEDIUM | JWT uses HS256 with no algorithm whitelist | CWE-327 | 0.85 |
| PT3-003 | MEDIUM | Share-link bcrypt cost 10 (project standard: 12) | CWE-916 | 0.95 |
| PT3-005 | MEDIUM | Login returns distinct 'Account is deactivated' error | CWE-200 | 0.95 |
| PT3-009 | MEDIUM | Login rate limit IP-only; no per-account lockout | CWE-307 | 0.85 |
| PT4-006 | MEDIUM | FeedbackController missing @Roles; any org user can mutate | CWE-269 | 0.85 |
| PT6-003 | MEDIUM | CORS methods unrestricted (all verbs allowed) | CWE-942 | 0.88 |
| PT6-005 | MEDIUM | Content-Type guard only on /complete; others unprotected | CWE-352 | 0.92 |
| PT7-002 | MEDIUM | Cross-store race: DB status write then Redis quota increment | CWE-367 | 0.75 |
| PT7-004 | MEDIUM | Error recovery restores processing->active in edge cases | CWE-367 | 0.78 |
| PT3-004 | LOW | Refresh secret derived as JWT_SECRET + '-refresh' in non-prod | CWE-330 | 0.80 |
| PT3-010 | LOW | Access tokens valid 15min after logout (no revocation blocklist) | CWE-613 | 0.90 |
| PT3-011 | LOW | Preview controller @Public with PREVIEW_TOKEN_REQUIRED default false | CWE-862 | 0.80 |
| PT4-007 | LOW | Designer controllers missing @Roles | CWE-269 | 0.80 |
| PT4-008 | LOW | Feedback :id not cross-checked against session's survey | CWE-639 | 0.70 |
| PT6-006 | LOW | No per-route body size limits | CWE-770 | 0.72 |
| PT7-005 | LOW | Empty-answer +1 page skip per request | CWE-20 | 0.85 |
| PT7-008 | LOW | Submit hardening defaults to 'monitor' in non-production | CWE-16 | 0.95 |

---

### Project J — Travel Platform

**Skill:** `zuvo:code-audit` + `zuvo:security-audit`

| # | Severity | Finding | Category |
|---|----------|---------|----------|
| B-21 | CRITICAL | No tenant isolation in 44 files — any user accesses any company's data | Authz |
| B-22 | CRITICAL | Float arithmetic in entire money stack (pricing, margins, exchange rates) | Data integrity |
| B-23 | CRITICAL | PII in logs/responses (username, email, temporaryPassword exposed) | Privacy |
| SEC-V-001 | MEDIUM | markdownToHtml skips sanitization for non-HTML input | XSS |
| SEC-V-002 | MEDIUM | JWT token stored in sessionStorage (accessible via XSS) | Session |

---

### Project K — Developer Tool (CodeSift)

**Skill:** `zuvo:security-audit`

| # | Severity | Finding | CWE | Conf |
|---|----------|---------|-----|------|
| SEC-001 | HIGH | Arbitrary File Write via generate_claude_md output_path (path traversal) | CWE-22 | HIGH |
| SEC-002 | MEDIUM | Shell String Interpolation in execSync with Git Refs | CWE-78 | HIGH |
| SEC-003 | MEDIUM | ReDoS via Unvalidated User Regex in search_text | CWE-1333 | HIGH |
| SEC-004 | MEDIUM | Third-Party API Error Body Forwarded to MCP Client | CWE-209 | HIGH |
| SEC-V-001 | MEDIUM | No Path Containment on index_folder Path Parameter | CWE-22 | MEDIUM |

---

## Audit Report Distribution

| Audit Skill | Reports | Key patterns |
|-------------|---------|-------------|
| `zuvo:pentest` | 9 | Auth bypass, SSRF, XSS, race conditions, injection |
| `zuvo:test-audit` | ~35 | Phantom mocks, orphan tests, weak assertions |
| `zuvo:code-audit` | ~30 | Tenant isolation, float money, PII leaks, path traversal |
| `zuvo:performance-audit` | ~25 | N+1 queries, bundle bloat, memory leaks |
| `zuvo:security-audit` | ~15 | OWASP Top 10, secrets, missing headers |
| `zuvo:seo-audit` | ~15 | Missing structured data, broken meta, AI crawler blocks |
| `zuvo:db-audit` | ~8 | Missing indexes, N+1, unsafe migrations |
| `zuvo:dependency-audit` | ~8 | Vulnerable deps, dead packages, license issues |
| `zuvo:structure-audit` | ~8 | Dead code, naming, god files |
| `zuvo:env-audit` | ~8 | Missing validation, secret exposure, parity gaps |
| `zuvo:api-audit` | ~6 | Missing pagination, inconsistent errors |
| `zuvo:ci-audit` | ~3 | Unpinned actions, no caches, no timeouts |

---

## Code Quality Audit Findings (zuvo:code-audit)

### Project E2 — Offer Management Backend (Grade: D, 73% Tier D)

| Severity | Finding | Gate |
|----------|---------|------|
| CRITICAL | Hardcoded JWT secret `"0123456789...2023"` in constants file | CAP5 |
| CRITICAL | Hardcoded webhook API key `"ATBBn8dh..."` in constants file | CAP5 |
| CRITICAL | `bcrypt.compare` password check DISABLED (commented out) | CAP5 |
| CRITICAL | OTP verification 38 lines COMMENTED OUT — any OTP accepted | CAP5 |
| CRITICAL | 2FA secret returned in API response | CQ5 |
| CRITICAL | Bearer token serialized to audit database | CQ5 |
| CRITICAL | `incrementOpened` empty WHERE clause — increments ALL rows in table | Data bug |
| CRITICAL | Tautology `name != null || name != ""` always true — filter broken | Data bug |
| CRITICAL | Maps `segment_id` instead of `territory_id` — wrong IDs assigned | Data bug |
| HIGH | Zero query-level ownership filtering in 91% of files | CQ4 |
| HIGH | No global ValidationPipe — all DTOs bare classes, 49 validators return raw value | CQ3 |
| HIGH | Float money pipeline — native JS floats through entire pricing stack | CQ16 |
| HIGH | Paginator has no max limit cap — `limit=999999` passes through | CQ6 |
| HIGH | Controller: 3,662 LOC, 44 dependencies, 0 transactions — scored 1/20 (5%) | CAP9/10 |
| HIGH | God class: 1,427 LOC, 240 LOC internal duplication | CAP9 |

### Project I — Survey SaaS Platform (Grade: B+)

| Severity | Finding | Gate |
|----------|---------|------|
| CRITICAL | Cross-tenant data leak — `getSurveySummary` missing orgId filter | CQ4 |
| CRITICAL | `survey.updateMany` in delete transaction lacks orgId | CQ4 |
| HIGH | PII (email) in BadRequestException message | CQ5 |
| HIGH | Raw request.body logged in audit interceptor | CQ5 |
| HIGH | Unvalidated token on public endpoint | CQ3 |
| HIGH | Unbounded Redis `lrange(0, -1)` | CQ6 |
| HIGH | Unbounded nested include (all pages/questions/options) | CQ6 |
| HIGH | TOCTOU race conditions on slug/status/dnaHash (4 services) | CQ21 |
| HIGH | 30+ files missing runtime response schemas | CQ19 |
| HIGH | 6 files exceed size limits (454-497 LOC) | CAP9 |
| HIGH | 7 functions >100 LOC | CAP10 |

### Project C — Rewards API (Grade: 68%)

| Severity | Finding | Gate |
|----------|---------|------|
| HIGH | Full email addresses in error/info logs across 4 worker services | CQ5 |
| HIGH | Dual-write architecture defect — double counter increments | CQ14/18 |
| HIGH | Frontend fetch without AbortSignal across 3 React pages | CQ8 |
| HIGH | Unbounded DB queries (recipients, projects, analytics) | CQ6 |
| HIGH | Float arithmetic on money fields (total_value, avg_claim_value) | CQ16 |
| HIGH | 100% of audited files exceed size limits | CQ11 |

### Project B — Survey Legacy (Grade: D, score: 3/16 = 19%)

| Severity | Finding | Gate |
|----------|---------|------|
| CRITICAL | `delete()` without transaction — raw DELETE + parent::delete() not wrapped | CQ9 |
| CRITICAL | `moveToStage()` race condition — concurrent calls leave multiple stages active | CQ21 |
| CRITICAL | Float money arithmetic on budget_cpi, panelReward throughout | CQ16 |
| HIGH | Unbounded queries in 3 methods | CQ6/7 |
| HIGH | 4 duplication clusters (score queries, percentage calcs, boolean getters) | CQ14 |
| HIGH | 2,477 LOC god class, 80+ methods | CAP9 |

### Project H — Methodology Platform

| Severity | Finding | Gate |
|----------|---------|------|
| HIGH | `sendDefaultPii: true` in both Sentry configs — PII sent to error tracking | CQ5 |

### Cross-Project Code Quality Patterns

| Pattern | Projects affected |
|---------|-------------------|
| PII in logs/errors (CQ5) | 6 projects |
| Missing query LIMIT / unbounded findMany (CQ6) | 6 projects |
| Float money arithmetic (CQ16) | 3 projects |
| TOCTOU race conditions (CQ21) | 4 projects |
| Zero ownership filtering (CQ4) | 3 projects |
| God files >1000 LOC (CAP9) | 3 projects (max: 3,662 LOC) |

---

## Test Quality Audit Findings (zuvo:test-audit)

### Project E2 — Offer Management (392 files, 3,037 tests)

| Severity | Finding | Gate |
|----------|---------|------|
| HIGH | Systemic across 300+ files — mocks missing CalledWith assertions | Q17 |
| HIGH | 15+ files missing error-path tests entirely | Q7 |
| HIGH | 15 ORPHAN test files — test production code that no longer exists | Orphan |
| HIGH | 77% of files B-tier — dominated by phantom mock and input-echo patterns | Systemic |

### Project B — Survey Legacy (review module: ZERO coverage)

| Severity | Finding | Gate |
|----------|---------|------|
| CRITICAL | Zero test files for entire `modules/review/` (7 production files, 0 tests) | Coverage |

### Project L — HelpDesk (215 files, 2,172 tests)

| Severity | Finding | Gate |
|----------|---------|------|
| CRITICAL | 413 pytest errors in baseline — backend tests partially broken | Broken |
| HIGH | 59 ORPHAN test files (27.4%) — test production code that may no longer exist | Orphan |
| HIGH | Only 6% A-tier, 93% B-tier — systemic branch coverage gaps | Q11 |

### Project D — Coding Platform (154 files, 2,531 tests)

| Severity | Finding | Gate |
|----------|---------|------|
| HIGH | 21 files still have branch coverage gaps (14% failure rate) | Q11 |
| HIGH | 9 files missing error coverage | Q7 |
| HIGH | encrypt()/decrypt() primary functions untested | Coverage |
| HIGH | Empty test body in apiKeys test | Q1 |

### Project M — Data Lab (92 files, 4,299 tests)

| Severity | Finding | Gate |
|----------|---------|------|
| HIGH | 17 files (18%) have branch coverage gaps | Q11 |
| HIGH | 7 files missing error injection tests | Q7 |
| HIGH | Static analysis tests print findings but don't assert — always-pass | AP9 |
| HIGH | `isinstance(len(result), int)` — always-true assertion | AP9 |

### Project K — Developer Tool (38 files, 593 tests)

| Severity | Finding | Gate |
|----------|---------|------|
| CRITICAL | Core dispatch function (218 LOC, 12 cases) completely untested | Coverage |
| HIGH | 100% of assertions are `typeof === "function"` — zero behavioral signal | AP14 |
| HIGH | 21 of 27 CLI command handlers untested | Coverage |

### Cross-Project Test Quality Patterns

| Pattern | Projects affected |
|---------|-------------------|
| Branch coverage gaps (Q11) | 5 projects — dominant defect |
| Missing error path tests (Q7) | 4 projects |
| Phantom mocks / input-echo (Q17/AP9) | 3 projects (300+ files in worst case) |
| Orphan test files | 2 projects (59 files in worst case) |
| Always-true assertions | 2 projects |
| Zero coverage for critical modules | 2 projects |

---

## DB Audit Findings (zuvo:db-audit)

### Project A — Fraud Detection (Grade: D, score: 50/96 = 52%)

| Severity | Finding | Dim |
|----------|---------|-----|
| CRITICAL | `tokens` collection has ZERO indexes — every auth check does full scan | DB2 |
| CRITICAL | `result_lite` collection has ZERO indexes — primary reporting collection | DB2 |
| CRITICAL | Index script is `.txt` file, not part of CI/CD — never runs | DB2 |
| HIGH | Zero transaction usage across entire codebase | DB5 |
| HIGH | TOCTOU race — `findOneBy()` + conditional `save()` creates duplicates | DB5 |
| HIGH | N+1 writes in result/survey-answer loops | DB1 |
| HIGH | `findAll()` returns entire `result` collection — no limit | DB1 |
| HIGH | OFFSET pagination on millions of rows | DB8 |
| MEDIUM | `rejectUnauthorized: false` hardcoded in 3 Redis TLS connections | DB12 |
| MEDIUM | `sslValidate: false` on DocumentDB | DB12 |

### Project I — Survey SaaS (Grade: B, score: 84/104)

| Severity | Finding | Dim |
|----------|---------|-----|
| HIGH | 8 interactive `$transaction(async)` without explicit timeout | DB5 |
| HIGH | 17 FK columns missing `@@index` — PG doesn't auto-index FKs | DB2 |
| HIGH | `contains:` with `mode: 'insensitive'` on text columns without GIN index — full seq scan | DB8 |
| MEDIUM | OFFSET pagination on abuseReport admin endpoint | DB8 |
| MEDIUM | No archival strategy for Response, RespondentSession, AuditLog | DB11 |

### Project G — Translation QA

| Severity | Finding | Dim |
|----------|---------|-----|
| CRITICAL | 19 missing FK indexes causing slow JOINs across 5 table categories | DB2 |
| CRITICAL | Connection pool default 10 — 2 concurrent requests exhaust pool | DB4 |
| HIGH | Zero transactions despite multi-collection mutations | DB5 |
| HIGH | N+1 `save()` inside `Promise.all(.map())` per session | DB1 |

### Project N — Country Data (Grade: C, score: 64/104 = 62%)

| Severity | Finding | Dim |
|----------|---------|-----|
| HIGH | `publish` updates CR status + inserts override as 2 non-atomic calls | DB5 |
| HIGH | Sequential individual INSERTs inside nested loop | DB1 |
| HIGH | `defaultSelect = '*'` — every subclass overfetches all columns | DB1 |
| HIGH | No `.limit()` on regions query (50K+ rows possible) | DB1 |
| HIGH | `CREATE INDEX` without `CONCURRENTLY` on live table — blocks writes | DB6 |

---

## Performance Audit Findings (zuvo:performance-audit)

### Project G — Translation QA (Grade: C, score: 62/112 = 55%)

| Severity | Finding |
|----------|---------|
| CRITICAL | 51 useEffect hooks without cleanup — memory leaks on admin pages |
| CRITICAL | 364 barrel exports defeating tree-shaking |
| HIGH | 290 'use client' components bloat JS payload |
| HIGH | Only 5/76 route groups have loading.tsx |

### Project I — Survey SaaS (Grade: B+, score: 74/100)

| Severity | Finding |
|----------|---------|
| HIGH | SurveyRunner chunk 295KB — test-shell/feedback statically bundled (25% bloat) |
| MEDIUM | Cross-block piping bulk-loads sessions to memory (bounded but 20K objects) |
| MEDIUM | `Math.max(...spread)` on unbounded adaptive rows |

---

## API Audit Findings (zuvo:api-audit)

### Project I — Survey SaaS (Grade: 75/100)

| Severity | Finding |
|----------|---------|
| HIGH | Stripe webhook silently loses checkout completions on null subscription — customer pays but never gets upgrade |
| HIGH | Preview `jump` endpoint skips token enforcement — unauthorized session manipulation |
| HIGH | QA preview `jump` no session-to-survey validation — cross-survey manipulation |
| HIGH | Designer bootstrap serializes entire designer behind single tRPC RTT waterfall |

### Project F — AI Design Studio (Grade: 76/105)

| Severity | Finding |
|----------|---------|
| HIGH | Cross-tenant data leak — article-dna routes missing site ownership check |
| HIGH | Media upload `siteId` not validated against org |
| HIGH | Git routes missing `requireAdmin` — members can trigger git push |
| HIGH | Git `syncToRepo` article lookup missing orgId filter |
| HIGH | Invitation accept doesn't verify email matches — anyone with token joins org |
| HIGH | Humanizer AI call amplification — 6 AI calls per request, no throttle |
| HIGH | Zero Cache-Control headers on any GET endpoint |

---

## SEO Audit Findings (zuvo:seo-audit)

### Project J — Travel Platform (Grade: FAIL, score: 50/100)

| Severity | Finding |
|----------|---------|
| CRITICAL | `<meta name="robots" content="noindex, nofollow" />` blocks ALL search engine indexing |
| CRITICAL | No `<link rel="canonical">` anywhere in codebase |
| CRITICAL | No JSON-LD structured data anywhere |
| CRITICAL | No `robots.txt` file, no AI crawler policy |
| HIGH | Open Graph: only 2/12 checks pass (16.7%) |
| HIGH | No analytics, no Google Search Console |

### Corporate Website (Grade: FAIL, score: 56/100)

| Severity | Finding |
|----------|---------|
| CRITICAL | ZERO AI-specific rules in robots.txt (no GPTBot, ClaudeBot, OAI-SearchBot) |
| HIGH | Sitemap blocks `*.js*` files — may interfere with framework routing |
| HIGH | AI Crawler Policy score 15% — effectively invisible to AI search |
| HIGH | Images score 45% — missing alt text, no WebP |
| HIGH | GEO/AI Readiness 20% — no llms.txt, no structured content strategy |

---

## CI/CD Audit Findings (zuvo:ci-audit)

### Project A — Fraud Detection (Grade: AT RISK, score: 50/100)

| Severity | Finding |
|----------|---------|
| CRITICAL | BE tests don't block deployment — `npm test || echo "Tests failed but continuing"` |
| CRITICAL | FE pipeline has zero test/lint/typecheck steps — build to deploy with no quality gate |
| CRITICAL | Admin pipeline has zero test/lint/typecheck steps |
| HIGH | BE tests not run on main branch before prod deploy |
| HIGH | No path filtering — all pushes trigger full pipeline |
| HIGH | Missing `.dockerignore` — Docker builds include node_modules/.git |

### Project I — Survey SaaS (Grade: 68/100)

| Severity | Finding |
|----------|---------|
| HIGH | No concurrency control — stale runs pile up, burn CI minutes |
| HIGH | Zero `timeout-minutes` on any of 9 jobs — runaway jobs can burn 360 min |
| HIGH | No coverage reporting or gate in CI (targets 70-80% but unenforced) |
| MEDIUM | No path filters — docs-only changes trigger full CI pipeline |

---

## Dependency Audit Findings (zuvo:dependency-audit)

### Project A — Fraud Detection (Grade: FAIL, score: 58.6%)

| Severity | Finding |
|----------|---------|
| CRITICAL | 23 critical CVEs via AWS SDK -> fast-xml-parser |
| CRITICAL | TypeORM SQL injection vulnerability |
| CRITICAL | 15+ runtime circular dependency chains (13 mutually-cyclic modules) |
| CRITICAL | 10 mutually-cyclic services via forwardRef |
| CRITICAL | Production modal imports 9 symbols from `app/test/` prototype route |
| HIGH | Axios 1.7.2: 4 CVEs (SSRF, credential leak, DoS) |
| HIGH | Next.js 14.2.35: DoS, HTTP smuggling |
| HIGH | Dual lockfiles in 2 of 3 repos (package-lock.json + yarn.lock) |

### Project I — Survey SaaS (Grade: A-, score: 81/100)

| Severity | Finding |
|----------|---------|
| HIGH | 15 dead production deps (axios, yup, react-dropzone — zero imports) |
| HIGH | 7 phantom dependencies (dotenv, p-limit, express — hoisted, work by accident) |

---

## Structure Audit Findings (zuvo:structure-audit)

### Project G — Translation QA (Grade: C, score: 61/100)

| Severity | Finding |
|----------|---------|
| CRITICAL | 147 items at project root — 54 stale files, tracked temp/backup files in git |
| CRITICAL | `language-variant-resolver.ts` 432 LOC (3.6x utility limit) |
| HIGH | 5 modal components with 185-428 deeply nested lines each |
| HIGH | `buildGroupDebatePrompt` CC=75 (most complex function in codebase) |
| HIGH | `useSegmentTranslation` CC=65, nesting 11 |
| HIGH | 161-line clone: two progress modals are identical |

### Project I — Survey SaaS (Grade: B, score: 77/100)

| Severity | Finding |
|----------|---------|
| CRITICAL | `agent-results.builder.ts` 429 LOC (3.6x limit), 33 exported functions |
| CRITICAL | `runner-response.mapper.grid.ts` 421 LOC (3.5x limit) |
| HIGH | `modules/runner/` 125 files (9.6x median) — god module |
| HIGH | 6.22% code duplication (1,741 clones, 37,753 duplicated lines) |
| HIGH | 307 files (16.9%) exceed 4-level nesting threshold |

---

## Env Audit Findings (zuvo:env-audit)

### Project I — Survey SaaS (Grade: 84%)

| Severity | Finding |
|----------|---------|
| HIGH | `VITE_DEV_PASSWORD` compiles into production bundle (no build-time guard) |
| HIGH | Frontend apps have zero env validation (raw `import.meta.env.*` with `||` fallbacks) |
| HIGH | `VITE_CLERK_PUBLISHABLE_KEY` missing from designer `.env.example` |

### Project C — Rewards API (Grade: 84%)

| Severity | Finding |
|----------|---------|
| HIGH | `CRON_SECRET` used in code but not listed in any `.env.example` |

---

## Cross-Audit Patterns (findings that span multiple audit types)

| Pattern | Audit types | Projects |
|---------|-------------|----------|
| **PII in logs/errors** | code-audit (CQ5), env-audit | 6 projects |
| **Cross-tenant data leaks** | code-audit (CQ4), api-audit, pentest (PT4) | 5 projects |
| **Float money arithmetic** | code-audit (CQ16), pentest (PT7) | 3 projects |
| **TOCTOU race conditions** | code-audit (CQ21), db-audit (DB5), pentest (PT7) | 6 projects |
| **Missing FK indexes** | db-audit (DB2), performance-audit | 3 projects (53 missing indexes) |
| **N+1 query patterns** | db-audit (DB1), performance-audit | 4 projects |
| **Tests not blocking deploys** | ci-audit, test-audit | 3 projects |
| **God files >1000 LOC** | code-audit (CAP9), structure-audit (SA7) | 3 projects (max: 3,662 LOC) |
| **Dead/phantom dependencies** | dependency-audit (D3) | 3 projects (22 dead deps in worst case) |
| **Zero auth on critical endpoints** | pentest (PT4), api-audit, code-audit (CQ4) | 7 projects |

---

*Data from 35 projects. Project names anonymized. Generated 2026-04-07.*
