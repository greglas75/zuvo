# Changelog Style Guide

Standards for CHANGELOG.md entries across all Zuvo skills. Based on [Keep a Changelog](https://keepachangelog.com/).

---

## Format

```markdown
# Changelog

All notable changes to this project will be documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- New user export endpoint with CSV format (#134)

## [1.4.0] — 2026-04-03

### Breaking
- Removed `GET /api/v1/users` — use `GET /api/v2/users` instead (#128)

### Added
- User export with CSV and JSON formats (#134)
- Rate limiting on authentication endpoints (#131)

### Changed
- Order service extracted from monolithic controller (#130)
- Updated Stripe SDK from v12 to v14 (#129)

### Fixed
- Null pointer in discount calculation for zero-quantity orders (#133)
- Race condition in concurrent payment processing (#132)

### Deprecated
- `GET /api/v1/orders` — will be removed in v2.0 (#135)

### Security
- Patched XSS vulnerability in search input (#136)
```

---

## Section Order

Sections MUST appear in this order (omit empty sections):

1. **Breaking** — backward-incompatible changes (triggers major version bump)
2. **Added** — new features
3. **Changed** — changes to existing functionality
4. **Fixed** — bug fixes
5. **Deprecated** — features marked for future removal
6. **Removed** — features removed in this release
7. **Security** — vulnerability fixes
8. **Performance** — performance improvements (optional, can go under Changed)

---

## Entry Rules

### Writing Entries

| Rule | Good | Bad |
|------|------|-----|
| Sentence case, no period | `Add user export endpoint` | `added user export endpoint.` |
| Start with verb | `Fix null pointer in discount` | `Null pointer in discount was fixed` |
| Reference issue/PR | `Add rate limiting (#131)` | `Add rate limiting` |
| One entry per logical change | `Add CSV and JSON export formats` | Two entries for same feature |
| User-facing language | `Fix payment failures for discounted orders` | `Guard against null in PaymentService.process()` |
| No file paths | `Fix discount calculation` | `Fix src/services/payment.ts:142` |

### Commit → Section Classification

| Commit prefix | Section | Example |
|---------------|---------|---------|
| `feat:` | Added | `feat: add user export` → Added |
| `fix:` | Fixed | `fix: null in discount` → Fixed |
| `refactor:` | Changed | `refactor: extract order service` → Changed |
| `perf:` | Performance / Changed | `perf: batch DB queries` → Changed |
| `docs:` | _(skip — not user-facing)_ | |
| `chore:` | _(skip — not user-facing)_ | |
| `test:` | _(skip — not user-facing)_ | |
| `ci:` | _(skip — not user-facing)_ | |
| `BREAKING CHANGE:` in body | Breaking | Always top section |
| `feat!:` or `fix!:` | Breaking + Added/Fixed | Both sections |
| No prefix | Changed | Fallback |

### Breaking Changes

A change is breaking when:
- API endpoint removed or renamed
- Request/response schema changed incompatibly
- Environment variable renamed or removed
- Database migration requires manual data fixup
- Public function signature changed

**Detection in commits:**
- `BREAKING CHANGE:` in commit body (conventional commits standard)
- `!` after type: `feat!:`, `fix!:`, `refactor!:`
- Words in message: "remove", "rename", "drop", "migrate from"

**Formatting:**
```markdown
### Breaking
- Remove `GET /api/v1/users` — use `GET /api/v2/users` instead (#128)
  - Migration: update all clients to use v2 endpoint
  - Deprecation notice was in v1.3.0 changelog
```

Always include migration instructions for breaking changes.

---

## Unreleased Section

Between releases, changes accumulate in `## [Unreleased]`:

```markdown
## [Unreleased]

### Added
- New feature in progress

## [1.4.0] — 2026-04-03
...
```

When `zuvo:ship` runs, it renames `[Unreleased]` to `[version] — date` and creates a fresh `[Unreleased]` section.

Skills that modify code (`build`, `refactor`, `hotfix`, `execute`) MAY add entries to `[Unreleased]` if the change is user-facing. Internal refactors, test changes, and CI updates should NOT create changelog entries.

---

## Validation Checklist

After generating a changelog section, verify:

```
CHANGELOG VALIDATION:
  [ ] All commits in range represented (or intentionally skipped with reason)
  [ ] Section order correct (Breaking → Added → Changed → Fixed → ...)
  [ ] No empty sections included
  [ ] Breaking changes have migration instructions
  [ ] Issue/PR references present where applicable
  [ ] Entries are user-facing (no internal implementation details)
  [ ] Valid Markdown syntax
  [ ] Date format: YYYY-MM-DD
  [ ] Version follows semver
```

---

## api-changelog.md vs CHANGELOG.md

These are **separate files** with different purposes:

| | `CHANGELOG.md` | `docs/api-changelog.md` |
|---|---|---|
| **Audience** | End users, stakeholders | Developers, API consumers |
| **Updated by** | `zuvo:ship`, `zuvo:docs changelog` | Auto-docs (any skill that changes APIs) |
| **Format** | Keep a Changelog (sections by version) | Append-only log (one entry per change) |
| **Content** | User-facing features, fixes, breaking changes | API endpoints, schemas, contracts |
| **Frequency** | Per release | Per skill run that changes API surface |

**Cross-reference rule:** Every entry in `api-changelog.md` that represents a user-facing change should have a corresponding entry in `CHANGELOG.md` at release time. `zuvo:release-docs` should verify this.
