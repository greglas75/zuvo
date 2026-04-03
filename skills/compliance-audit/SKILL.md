---
name: compliance-audit
description: "Regulatory compliance audit from code analysis. Checks GDPR, PCI-DSS, HIPAA, and SOC 2 requirements by scanning for data handling patterns, consent mechanisms, encryption, audit trails, and access controls. Produces a compliance report with gap analysis and remediation priorities."
---

# zuvo:compliance-audit — Regulatory Compliance from Code

Audit codebase against regulatory frameworks by analyzing how data is collected, stored, processed, and deleted. Not a security vulnerability scan (`zuvo:security-audit`) — this checks whether code meets **legal and regulatory requirements**.

**Scope:** GDPR, PCI-DSS, HIPAA, SOC 2 compliance checking from static code analysis.
**Out of scope:** Technical security vulnerabilities (`zuvo:security-audit`), penetration testing (`zuvo:pentest`), threat modeling (`zuvo:threat-model`), organizational policy review (requires human auditor).

## Argument Parsing

Parse `$ARGUMENTS`:

| Flag | Effect |
|------|--------|
| `[regulation]` | Specific regulation: `gdpr`, `pci-dss`, `hipaa`, `soc2`, `all` (default: auto-detect) |
| `--scope [path]` | Limit audit to directory |
| `--depth [quick\|standard\|deep]` | Analysis depth (default: standard) |
| `--output [path]` | Report path (default: `docs/compliance-audit.md`) |

---

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

---

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for the full initialization sequence.

**Compliance-specific CodeSift usage:**

| Task | CodeSift tool | Fallback |
|------|--------------|----------|
| Find data collection points | `search_symbols(repo, query="create\|register\|signup", kind="function")` | Grep |
| Find PII fields | `search_text(repo, query="email\|phone\|address\|ssn\|dob", file_pattern="*.{ts,py}")` | Grep |
| Trace data flow | `trace_call_chain(repo, symbol_name, direction="down", depth=3)` | Manual read |
| Find payment code | `search_text(repo, query="stripe\|paypal\|braintree\|card\|payment", file_pattern="*.{ts,py}")` | Grep |
| Find encryption usage | `search_text(repo, query="encrypt\|hash\|bcrypt\|crypto\|cipher", file_pattern="*.{ts,py}")` | Grep |
| Find logging calls | `search_text(repo, query="logger\\.\|console\\.\|logging\\.", file_pattern="*.{ts,py}")` | Grep |

---

## Mandatory File Reading

```
CORE FILES LOADED:
  1. {plugin_root}/shared/includes/auto-docs.md       -- READ/MISSING
  2. {plugin_root}/shared/includes/session-memory.md   -- READ/MISSING
  3. {plugin_root}/shared/includes/backlog-protocol.md -- READ/MISSING
```

---

## Regulation Check Definitions

### GDPR (12 checks — G1-G12)

| # | Gate | What to find in code |
|---|------|---------------------|
| G1 | Consent Collection | User data collection has consent mechanism (checkbox, explicit opt-in, consent API) |
| G2 | Right to Access | Data export endpoint exists (GET /user/data, account download) |
| G3 | Right to Deletion | Data erasure endpoint or soft-delete with PII removal (DELETE /user, anonymize function) |
| G4 | Data Portability | Export in machine-readable format (JSON/CSV download) |
| G5 | Privacy Policy | Privacy policy URL referenced in registration/signup flow |
| G6 | Cookie Consent | Cookie banner or consent mechanism for non-essential cookies |
| G7 | Data Retention | TTL on PII, scheduled cleanup job, or retention policy enforcement |
| G8 | Purpose Limitation | Data usage matches collection purpose (no hidden tracking beyond stated use) |
| G9 | Data Minimization | Only necessary fields collected (no SSN for email signup, no excessive form fields) |
| G10 | Breach Notification | Incident response mechanism, data breach detection logging |
| G11 | Cross-Border Transfer | Safeguards for data leaving EU (region checks, adequacy decisions, SCCs) |
| G12 | DPO Contact | Data Protection Officer contact accessible in app or policy |

### PCI-DSS (8 checks — P1-P8)

| # | Gate | What to find |
|---|------|-------------|
| P1 | No Card Storage | Credit card numbers NEVER stored in database (only tokenized via gateway) |
| P2 | Certified Gateway | Payment via certified provider (Stripe, Braintree, Adyen, Square — not custom) |
| P3 | No Cards in Logs | Card numbers absent from all log output, error messages, stack traces, debug output |
| P4 | TLS Everywhere | Payment endpoints enforce HTTPS, no HTTP fallback for sensitive data |
| P5 | Encryption at Rest | Sensitive payment data encrypted in database (token storage, not plaintext) |
| P6 | Access Control | Payment operations require authentication + authorization + role check |
| P7 | Audit Trail | Payment transactions logged: who, what, when, amount, status, idempotency key |
| P8 | Key Management | API keys and payment secrets not hardcoded — env vars, vault, or secret manager |

### HIPAA (8 checks — H1-H8)

| # | Gate | What to find |
|---|------|-------------|
| H1 | PHI Encryption at Rest | Protected Health Information encrypted in database (column-level or disk-level) |
| H2 | PHI in Transit | PHI only transmitted over TLS, no plaintext HTTP for health data |
| H3 | Access Audit Trail | All PHI access logged with user ID, timestamp, action, resource |
| H4 | Minimum Necessary | PHI access scoped to minimum needed (field-level permissions, not full record) |
| H5 | Authentication | Multi-factor authentication for PHI-accessing roles |
| H6 | Session Timeout | Automatic logoff for sessions accessing PHI (idle timeout configured) |
| H7 | Integrity Controls | PHI modifications tracked (audit log, version history, change detection) |
| H8 | BAA References | Business Associate Agreement requirements referenced in vendor integrations |

### SOC 2 (8 checks — SC1-SC8)

| # | Gate | What to find |
|---|------|-------------|
| SC1 | Access Controls | Role-based access control implemented (RBAC, permissions, guards) |
| SC2 | Change Management | Git workflow with PR reviews, CI/CD pipeline, no direct-to-prod pushes |
| SC3 | System Monitoring | Health endpoints, error tracking integration, uptime monitoring |
| SC4 | Incident Response | Incident procedures documented or logging/alerting for incidents |
| SC5 | Data Encryption | Encryption at rest (database) and in transit (TLS/HTTPS enforced) |
| SC6 | Availability | Redundancy indicators: load balancer config, replica sets, failover, backup procedures |
| SC7 | Confidentiality | Data classification, access restrictions per classification level |
| SC8 | Processing Integrity | Input validation on all boundaries, output verification, data consistency checks |

---

## Phase 0: Detect Applicable Regulations

Auto-detect which regulations apply based on code patterns:

| Signal | Regulation |
|--------|-----------|
| Payment code (Stripe, PayPal, card processing) | PCI-DSS |
| Health data models (patient, diagnosis, prescription, PHI) | HIPAA |
| User PII collection (email, name, address forms) | GDPR |
| SaaS patterns (multi-tenant, subscription, API keys) | SOC 2 |
| EU locale/i18n, GDPR references in code/docs | GDPR |

If specific regulation passed as argument: use that, skip detection.

Print:
```
REGULATIONS DETECTED: [list]
  PCI-DSS: payment code found in src/services/payment.ts
  GDPR: user registration with PII in src/auth/register.ts
  SOC 2: multi-tenant SaaS with RBAC in src/auth/guards/
```

---

## Phase 1: Sensitive Data Inventory

Map all sensitive data in the codebase:

### 1.1: Data Collection Points
- Forms, API endpoints that accept user input
- Registration, profile update, payment, contact forms
- File uploads, webhook receivers

### 1.2: Data Storage Locations
- Database tables/collections with PII columns
- Cache entries with user data
- File storage (uploads, exports, logs)
- Session stores

### 1.3: Data Processing
- Services that transform, aggregate, or analyze user data
- Background jobs processing PII
- Analytics/tracking code

### 1.4: Data Output
- API responses returning user data
- Email templates with PII
- Log statements with user context
- Export/download features
- Third-party integrations receiving user data

Print:
```
DATA INVENTORY
  PII fields:       [N] types (email, name, address, phone, ...)
  Collection:       [N] endpoints
  Storage:          [N] tables/collections, [N] cache keys
  Processing:       [N] services
  Output:           [N] API responses, [N] integrations
```

---

## Phase 2: Compliance Check

### Depth Scaling

| Depth | Checks | Evidence |
|-------|--------|----------|
| `quick` | Critical gates only (G1-G3, P1-P3, H1-H3, SC1-SC2) | Pattern match, no deep trace |
| `standard` | All gates | Pattern match + 1-level trace |
| `deep` | All gates + data flow tracing | Full trace from collection to deletion |

### 2.1: Run All Applicable Checks

For each regulation detected, evaluate every gate:

| Status | Meaning | Criteria |
|--------|---------|----------|
| **COMPLIANT** | Requirement met | Code evidence found (file:line) |
| **PARTIAL** | Partially implemented | Some implementation but incomplete |
| **NON-COMPLIANT** | Missing | No implementation found |
| **N/A** | Not applicable | Precondition not met (no payment = P1-P8 N/A) |

For each check, document:
- Status
- Evidence (file:line for COMPLIANT, description of gap for NON-COMPLIANT)
- Remediation suggestion (for NON-COMPLIANT and PARTIAL)

### 2.2: Per-Regulation Summary

```
GDPR: 9/12 PARTIAL
  COMPLIANT:     G1✓ G2✓ G4✓ G5✓ G6✓ G8✓ G9✓ G10✓ G12✓
  NON-COMPLIANT: G3✗ (no deletion endpoint) G7✗ (no retention policy)
  PARTIAL:       G11△ (region detection exists but no transfer safeguards)
```

---

## Phase 3: Risk Assessment

### 3.1: Overall Compliance Rating

Per regulation:
- **COMPLIANT**: All gates pass (100%)
- **MOSTLY COMPLIANT**: 1-2 non-critical gaps (>80%)
- **PARTIAL**: Multiple gaps but core functionality exists (50-80%)
- **NON-COMPLIANT**: Critical gaps or missing core requirements (<50%)

### 3.2: Legal Exposure

Identify critical gaps that create legal risk:
- **GDPR**: Missing G3 (deletion) = potential fine up to 4% annual revenue
- **PCI-DSS**: P1 fail (card storage) = certification loss
- **HIPAA**: H1 fail (PHI unencrypted) = breach notification required
- **SOC 2**: SC1 fail (no access controls) = audit failure

### 3.3: Priority Matrix

| Priority | Criteria | Action |
|----------|---------|--------|
| **P0** | Legal exposure, critical gaps | Fix this sprint |
| **P1** | Compliance gaps, moderate risk | Fix next sprint |
| **P2** | Best practice gaps, low risk | Plan for quarter |

---

## Phase 4: Generate Report

Save to `--output` path (default: `docs/compliance-audit.md`):

```markdown
# Compliance Audit Report

**Date:** YYYY-MM-DD
**Scope:** [path or full project]
**Depth:** [quick/standard/deep]
**Regulations:** [list]

## Executive Summary

[2-3 sentences: overall posture, critical gaps, top recommendation]

## Data Inventory

[PII types, storage locations, data flows]

## Compliance Results

### GDPR
| # | Gate | Status | Evidence / Gap |
|---|------|--------|---------------|
| G1 | Consent | COMPLIANT | auth/register.ts:34 — consent checkbox |
| G3 | Deletion | NON-COMPLIANT | No deletion endpoint found |
...

### PCI-DSS
...

## Risk Assessment

| Regulation | Rating | Critical Gaps |
|-----------|--------|---------------|
| GDPR | PARTIAL | G3 deletion, G7 retention |
| PCI-DSS | COMPLIANT | — |

## Remediation Plan

| # | Gap | Regulation | Priority | Effort | Suggested Fix |
|---|-----|-----------|----------|--------|---------------|
| 1 | No data deletion endpoint | GDPR G3 | P0 | 4h | Add DELETE /api/user with PII scrubbing |
| 2 | No retention policy | GDPR G7 | P1 | 2h | Add TTL or scheduled cleanup job |

## Recommendations

[Ordered list]
```

---

## Phase 5: Create Action Items

1. Add P0 and P1 gaps to `memory/backlog.md` as high-severity entries
2. For each gap, suggest remediation skill:

| Gap type | Recommended skill |
|----------|------------------|
| Missing endpoint (deletion, export) | `zuvo:build` |
| Missing encryption | `zuvo:security-audit` → `zuvo:build` |
| Missing audit trail | `zuvo:build` with OBS gates |
| Architecture change needed | `zuvo:architecture` |

---

## Output Block

```
----------------------------------------------------
COMPLIANCE AUDIT COMPLETE
  Regulations: [list]
  GDPR:        [N/12] [COMPLIANT/PARTIAL/NON-COMPLIANT]
  PCI-DSS:     [N/8] [status]
  HIPAA:       [N/8] [status] (or N/A)
  SOC 2:       [N/8] [status] (or N/A)
  PII fields:  [N] types across [N] storage locations
  Critical:    [N] gaps ([list])
  Backlog:     [N] items added
  Report:      docs/compliance-audit.md
----------------------------------------------------
```

---

## Auto-Docs

After output block, update per `{plugin_root}/shared/includes/auto-docs.md`:

- **project-journal.md**: Log compliance audit scope, regulations checked, overall ratings, critical gaps.
- **architecture.md**: Update if data flow or privacy architecture documented.

---

## Session Memory

After Auto-Docs, update `memory/project-state.md` per `{plugin_root}/shared/includes/session-memory.md`:

- **Recent Activity**: Prepend entry with regulations checked and compliance rating.

---

## Run Log

Log this run to `memory/zuvo-runs.log` per `{plugin_root}/shared/includes/run-logger.md`:

| Field | Value |
|-------|-------|
| SKILL | `compliance-audit` |
| CQ_SCORE | `-` |
| Q_SCORE | `-` |
| VERDICT | COMPLIANT / PARTIAL / NON-COMPLIANT (worst regulation) |
| TASKS | Number of checks evaluated |
| DURATION | `quick` / `standard` / `deep` |
| NOTES | `[regulations]: [N] gaps ([N] critical)` (max 80 chars) |

---

## Next-Action Routing

| Finding | Recommended action |
|---------|--------------------|
| Missing endpoints (deletion, export) | `zuvo:build` to implement |
| Encryption gaps | `zuvo:security-audit` for detailed fix |
| Architecture concerns | `zuvo:architecture` for redesign |
| Need deeper security testing | `zuvo:pentest` |
| Want threat analysis first | `zuvo:threat-model` |
