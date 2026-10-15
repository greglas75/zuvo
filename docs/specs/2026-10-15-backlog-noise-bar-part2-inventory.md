# Backlog noise bar, part 2: write-site inventory

Companion to `2026-10-15-backlog-noise-bar-part2-plan.md`. Measured on origin/main `9e510823` (line numbers are at that commit and drift as tasks land; quotes are the stable key). Produced by the plan's Architect pass; the Tech Lead's canonical sentences (plan §Technical Decisions) say what each site becomes.

## Write-site inventory

**Verdicts**

- `WRITE`: a write site to rewire.
- `WRITE*`: a hand delete or hand edit of backlog rows.
- `POLICY`: a statement about what reaches the backlog. Rewire the wording.
- `OUT`: a report or summary line or checklist item that counts backlogged items. Re-express it as verdict counts, B- and F- ids, and NOT PERSISTED.
- `AGENT`: agent prose that should say "return, don't persist".
- `OK-AGENT`: already returns per the preamble.
- `DELEG`: delegates to `drive-by-findings.md`, which already conforms. Optional rewording ("backlog the …" → "record via backlog-add").
- `READ`, `GROOM`, `FORMAT` and `NOT`: not a site. `NOT` covers negations, history and names.

**Caller.** O = orchestrator (the skill run itself), S = sub-agent, U = the user via the backlog skill.

**Classes** are the likely `--class` values. `→L` means it lands in the ledger only, under the bar table. **Source** is the `--source` value.

### Batch 1: central includes and the backlog skill (5 files)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `shared/includes/severity-vocabulary.md:40` | "When writing findings to `memory/backlog.md`, always record the canonical level (S1-S4)" | WRITE (doc rule) | O | (`--severity` mapping) | caller |
| `shared/includes/quality-gates.md:189` | "Persist to backlog if not fixed in this session." | WRITE | O | CQ→L (BUG when input→wrong output) | caller |
| `shared/includes/no-pause-protocol.md:48` | "persist the decision to the backlog with both options" | WRITE | O | PROCESS→L `subject:` | caller |
| `shared/includes/followup-ideas.md:14` | "debt / findings go to backlog, never here" | POLICY | O | n/a | n/a |
| `skills/backlog/SKILL.md:33`, `:235-252`, `:259-266` | "`add [description]` … add to backlog"; "Determine the next `B-{N}` ID" … "ABSENT … append a new entry"; "Source: `manual`" | WRITE (the user's own add path) | U | any | `user`. `ZUVO_BACKLOG_ADMIT=1` only on the user's explicit request for that finding. Never when another skill invokes `zuvo:backlog add`. |
| `skills/backlog/SKILL.md:7-8, 34-39, 202-225, 276-300, 469-476` | fix/wontfix/delete/regression/archive, schema, template | GROOM/FORMAT (allowlist) | U | | |

### Batch 2: test includes (5 files)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `test-quality-gate.md:44` | "so the calling skill backlogs them" | WRITE | O | TEST-GAP→L (BUG via `--missing-assertion` on changed lines) | caller |
| `test-quality-gate.md:63-64` | "backlog each file with its tier + failing Q-gates (`backlog-protocol.md`)" | WRITE | O | TEST-GAP/CQ→L | caller |
| `test-bugfix-protocol.md:23` | "never a silent backlog row" | NOT (negation) | | | |
| `test-bugfix-protocol.md:24` | "Backlog only if the user declines." | WRITE | O | PROCESS→L | caller |
| `test-bugfix-protocol.md:53-54` | "Only genuinely out-of-scope or user-declined items remain in `memory/backlog.md`" | POLICY | O | BUG | caller |
| `test-blocklist.md:9`, `:11` | "skip file + backlog item"; "add backlog item" | WRITE | O | TEST-GAP→L | caller |
| `test-code-types-core.md:91` | "record it as the top backlog item" | WRITE | O | PROCESS→L `subject:type-tests-not-enforced` | write-tests |
| `blind-coverage-audit.md:116` | "backlog it only if the project needs stronger fallback observability" | WRITE | O | TEST-GAP→L | write-tests |

### Batch 3: refactor include and references (5 files)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `shared/includes/refactor-reference.md:371` | "8. **Backlog:** Persist ONLY out-of-scope-fence items and declined decisions" | WRITE | O | BUG/CQ, PROCESS | refactor |
| `refactor-reference.md:435` | "RECOMMENDED/NIT go to the backlog" (via review) | POLICY | O (review) | CQ→L | review |
| `references/completion.md:69-71` | "Persist to `memory/backlog.md`. Fingerprint: `file\|rule-id\|signature`. Source: `zuvo:refactor` or `zuvo:refactor/cq-auditor`" | WRITE (core; the source is invalid today) | O | BUG/CQ/PROCESS | refactor |
| `completion.md:9` | "everything Phase 4 writes (… backlog …) is LOCAL telemetry — never stage it" | POLICY: conflicts with "stage exactly `wrote=`" | O | | |
| `completion.md:174`, `:175` | "a NAMED backlog entry"; "WARN + per-file backlog" | OUT (checklist) | O | TEST-GAP→L | refactor |
| `completion.md:187` | "an adversarial pass that … backlogs them … is BLOCKED(unsafe)" | NOT (prohibition; a guard false positive) | | | |
| `completion.md:124` | drive-by | DELEG | | | drive-by:refactor |
| `references/remediation.md:20`, `:21` | "Backlog with file:line — genuinely out of this contract's reach"; decision "…backlog" | WRITE | O | BUG/CQ; PROCESS | refactor |
| `remediation.md:91` | "Out-of-scope-fence items → backlog (Phase 4)" | WRITE | O | BUG/CQ | refactor |
| `remediation.md:133` (`:137` prove token pinned) | "only **named** in the backlog" | WRITE | O | TEST-GAP→L | refactor |
| `remediation.md:145`, `:159`, `:223` | "WARN + per-module backlog entry"; "per-file backlog"; "a per-file backlog entry naming each" | WRITE | O | TEST-GAP / MUTATION→L | refactor |
| `remediation.md:65`, `:197` | "no cap, no backlog" (pinned); "backlog-instead-of-fix drift" | NOT | | | |
| `references/review.md:189` | "Backlog with file:line" | WRITE | O | BUG/CQ | refactor |
| `references/review.md:193` | "The old … → backlog rule is gone" | NOT | | | |
| `references/transformation.md:169` | "go to the backlog — deferral is a fix-SCOPE decision" | WRITE | O | BUG/CQ/PROCESS | refactor |

### Batch 4: agents and the refactor tail (3 files)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `skills/refactor/references/planning.md:120` | "update the doc in-fence or backlog it" | WRITE | O | DEAD/PROCESS→L | refactor |
| `planning.md:146` (`:148` NOT) | "record it in the commit body and the backlog" | WRITE | O | PROCESS→L | refactor |
| `skills/refactor/agents/cq-auditor.md:167-170`, `:184` | "[DEFER-classified discrepancies …] - [severity] file_path:line — description (confidence: N%)"; "DEFER … Goes into BACKLOG ITEMS section" | AGENT (format drift; class CQ is not a drive-by tag) | S | CQ | refactor |
| `skills/review/agents/confidence-rescorer.md:47`, `:61`, `:78-84`, `:96-108`, `:117` | "Path to backlog file"; "the orchestrator writes to backlog after Phase 4"; "Backlog Tag `[low-confidence]`/`[below-threshold]`"; "Do not discard any finding — all go to either report or backlog" | AGENT (vocabulary: 0-25 now DISCARDED, 26-50 → ledger) | S | | |
| brainstorm agents (`business-analyst.md:260`, `code-explorer.md:194`, `domain-researcher.md:181`, `spec-reviewer.md:236`), `refactor/agents/dependency-mapper.md:115`, `existing-code-scanner.md:105`, `review/agents/{cq,structure}-auditor.md:107`, `behavior-auditor.md:118` | "### BACKLOG ITEMS [Issues outside scope, or "None"]" | OK-AGENT (format via preamble) | S | drive-by tags | drive-by:<skill> |
| `skills/backlog/agents/backlog-verifier.md` | read-only grooming lane | GROOM (allowlist) | | | |

### Batch 5: build, execute, debug (3 files; plan and brainstorm are DELEG only)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `build:408` | "backlog the question for the user" | WRITE | O | PROCESS→L | build |
| `build:443` | "backlog the blocked dependency" | WRITE | O | PROCESS→L | build |
| `build:559`, `:568` | auditor prompt "DEFER (backlog)" (S); "**DEFER:** Persist to backlog in Phase 4.4." (Phase 4.4 is a stale reference: it is 4.5) | AGENT + WRITE | S→O | CQ/BUG/SEC | build |
| `build:705` | "If fix is larger, add to backlog with specific file:line." | WRITE (adversarial boilerplate ×7) | O | BUG/CQ | build |
| `build:710` | "If not, add it to backlog with file:line." | WRITE (boilerplate ×6) | O | BUG/SEC/CQ | drive-by:build? (decision) |
| `build:712-724` | §4.5: "persist to `memory/backlog.md`: `- B-{N} \| {file}:{line} \| … seen:1 …`", "increment `seen:N`", "Discard: confidence < 25", "25-50 are tracked" | WRITE (core) | O | CQ/BUG/SEC | build |
| `build:764` | "Below-A after the cap → WARN + per-file backlog" | WRITE | O | TEST-GAP→L | build |
| `build:848`, `:865` | "[ ] Backlog updated …"; "Backlog: [N items persisted \| "none"]" | OUT | O | | |
| `build:628`; `build:204`, `:215`; `build:772` | "no cap, no backlog" (pinned); reads; drive-by | NOT; READ; DELEG | | | |
| `execute:253` | "Check `memory/backlog.md`" | READ | | | |
| `execute:358`, `:380`, `:965-1044` | `backlog-adds` telemetry | OUT (field name pinned) | O | | |
| `execute:402` | "New work → `memory/backlog.md` (with a one-line reason)" | WRITE (follow-up work, not a finding) | O | PROCESS→L (decision) | execute |
| `execute:543`, `:544` | "Persist to backlog after task completion."; "Add to backlog as a follow-up task." | WRITE | O (from implementer S) | CQ/READ; PROCESS | execute |
| `execute:685`, `:722` | "safest reversible default + backlog"; "log the rule-mismatch to backlog … backlog both positions" | WRITE | O | PROCESS→L | execute |
| `execute:718` | "backlog it as pre-existing" | WRITE | O | BUG/CQ | execute or drive-by:execute |
| `execute:805`, `:812` | "is a backlog candidate (persist via `backlog-protocol.md`)"; "persisted to backlog" | WRITE | O | BUG/SEC/CQ | execute / drive-by:execute |
| `execute:824` | "fingerprint (`file\|rule-id\|signature`, same scheme as Backlog Persistence)" | POLICY (the loop key refers to a scheme that is going away) | O | | |
| `execute:1191-1193` | "WARN + per-file backlog" | WRITE | O | TEST-GAP→L | execute |
| `execute:1349-1350` | "### Backlog Items Added [list any new items persisted to backlog]" | OUT | O | | |
| `execute:1413-1424` | §Backlog Persistence: "Compute fingerprint … Check for duplicates … Route by confidence (0-25 discard, 26-50 backlog only, 51+ report and backlog)" | WRITE (core) | O | CQ/BUG/SEC/PROCESS | execute |
| `execute:1470`, `:1476`, `:1563-1565` | checklist; "every finding with confidence above 25% is persisted" | OUT / POLICY | O | | |
| `execute:737`, `:1399` | "no cap, no backlog" (pinned); drive-by | NOT; DELEG | | | |
| `debug:373`, `:378` | adversarial boilerplate | WRITE | O | BUG/CQ | debug / drive-by:debug |
| `debug:488-497` | "dedup and the backlog location per … 'Where the Backlog Lives' … Entries carry `source: drive-by:debug` (formerly `debug/[date]`)" | WRITE (half-conforming) | O | drive-by tags | drive-by:debug |
| `debug:630`, `:651` | checklist; "Backlog: [N items added]" | OUT | | | |
| `plan:614`, `brainstorm:667` | drive-by | DELEG | | | drive-by:plan / brainstorm |

### Batch 6: review, receive-review, ship (3 files)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `review:190`, `:199` | "`new` … Backlog/merge-base resolution"; "`memory/backlog.md` unchecked entries -> oldest entry's parent hash" | READ (stale: the retired review queue) | | | |
| `review:227` | "NIT + structural-refactor RECOMMENDED → backlog (not force-applied)" | POLICY | O | CQ / CPLX/SIZE/DUP→L | review |
| `review:232`, `:1476`, `:1484-1490`, `:1497` | "`tag` … Remove reviewed commits from backlog"; "Read `memory/backlog.md` … If yes, remove the line"; "After tagging, clean `memory/backlog.md`" | WRITE* (hand REMOVAL from `memory/backlog.md` by the retired review-queue path, not a finding write) | O | | decision: repoint or delete |
| `review:379` | "backlog them separately rather than scoring them against this diff" | WRITE | O | drive-by tags | drive-by:review |
| `review:862` | "persist it to backlog with a concrete resolution recipe" | WRITE | O | CPLX/SIZE/DUP→L (the recipe goes in `--fix`, capped at 300 characters) | review |
| `review:876-882`, `:888`, `:894` | Disposition "Backlog Tag `[low-confidence]`/`[below-threshold]`"; "All backlog writes happen AFTER Phase 4"; "writing to backlog" | POLICY | O | | |
| `review:939-946` | "Persist ALL findings to `memory/backlog.md`: Excluded findings (0-50): backlog with `[low-confidence]` … Unfixed …: backlog. Pre-existing issues: backlog. Deduplicate by fingerprint" | WRITE (core) | O | BUG/SEC/DATA/CQ/CPLX/SIZE/DUP/PERF | review; pre-existing → drive-by:review? |
| `review:1061-1062` | "[ ] Backlog persistence ran (memory/backlog.md updated or explicitly N/A)"; "No localized RECOMMENDED silently backlogged" | OUT | | | |
| `review:1176-1178`, `:1250-1254`, `:1268-1270`, `:1274-1280`, `:1335` | `backlog_deferral … <B-id>`; "deferred to backlog (<B-id>)"; "DEFERRED to backlog: … B-<id> — defer-reason"; "Backlog-deferral whitelist"; "Record applied vs deferred (backlog IDs)" | POLICY/OUT (ids become F- for CQ/NIT: the drift gate is keyed on B-ids) | O | | |
| `review:1186`, `:1192`, `:1200`, `:1208`, `:1217` | "add a backlog item `B-review-incomplete-<date>`"; "`B-review-escape-hatch-<date>`"; "`B-review-revalidate-<date>`"; "`B-review-tier2-skip-<date>`"; "backlog the elapsed time" | WRITE | O | PROCESS→L `subject:` | review |
| `review:1314`, `:1334`, `:1431` | "those go to backlog"; "residual non-CRITICAL → backlog"; "Backlog persistence: unfixed items from FIX-BLOCKING" | WRITE | O | CQ/BUG | review |
| `review:886`, `:1330`, `:1391`, `:1020` | history; "no backlog" (pinned); "not in the backlog"; drive-by | NOT / DELEG | | | |
| `receive-review:69-71` | "routes non-localized WARNINGs to backlog; instructing a backlog write without the protocol…" | POLICY (load rationale) | | | |
| `receive-review:235`, `:242` | adversarial boilerplate | WRITE | O | BUG/CQ | receive-review / drive-by:receive-review |
| `ship:427` | "print `[SHIP] pre-existing failures carried: <list>`, write them to `memory/backlog.md`" | WRITE | O | BUG (anchor at the test line) / PROCESS | ship |
| `ship:833-835`, `:839` | "otherwise record it in `memory/backlog.md` with the finding text"; "**NIT** → backlog or ignore, silently is fine"; "<n> backlogged" | WRITE + OUT ("silently is fine" contradicts Zero Silent Discards for conf > 25) | O | CQ/BUG | ship |

### Batch 7: test skills (4 files; mutation-test:1177 is NOT)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `write-tests:255`, `:266` | "mark file `FAILED`, backlog the environment issue"; "run-level ENV blocker — backlog" | WRITE | O | PROCESS→L | write-tests |
| `write-tests:312` | "Unconsolidatable overlap → `FAILED` + backlog `duplicate…`" | WRITE | O | DUP→L | write-tests |
| `write-tests:318` | "print `[EXTRACT] …` and backlog the extraction" | WRITE | O | CQ→L | write-tests |
| `write-tests:499` | "Errors in the production file are printed as context and backlogged" | WRITE | O | BUG/CQ | write-tests / drive-by |
| `write-tests:762`, `:805`, `:806`, `:809` | "skip after backlog"; "WARNING >10 lines \| Backlog with file:line"; "rejection requires backlog entry"; "`FAILED` + backlog" | WRITE | O | PROCESS; BUG/CQ; SEC/CQ; BUG/TEST-GAP | write-tests |
| `write-tests:844` | "1. **Backlog persistence:** unfixed out-of-scope issues → `memory/backlog.md`" | WRITE (core) | O | BUG/CQ | write-tests |
| `write-tests:866`, `:906`, `:959` | "WARN + backlog"; checklist; "Skip (already backlogged)" | WRITE / OUT | O | TEST-GAP→L | write-tests |
| `write-tests:440`, `:582`, `:845` | "Backlogging a fixable bug is not a valid exit"; "tracked in the backlog" (zuvo's own); drive-by | NOT; NOT (guard false positive); DELEG | | | |
| `fix-tests:292`, `:300` | "parking it in the backlog throws away…"; "Never a silent backlog row." | NOT | | | |
| `fix-tests:305` | "`memory/backlog.md` receives only what is genuinely out-of-scope or user-declined." | POLICY | O | | |
| `fix-tests:338`, `:343` | adversarial boilerplate | WRITE | O | BUG/CQ | fix-tests |
| `fix-tests:364-368` | "Persist any production bugs … or files that could not be fixed automatically, to `memory/backlog.md`." | WRITE (core) | O | BUG; PROCESS→L | fix-tests |
| `fix-tests:401`, `:403`, `:413` | checklist; "Bugs discovered: [N] (see backlog)" | OUT | | | |
| `write-e2e:204` | "WARNING — fix if localized (< 10 lines), else backlog with file:line" | WRITE | O | BUG/CQ | write-e2e |
| `write-e2e:248` | "Below-A after the cap → WARN + per-file backlog" | WRITE | O | TEST-GAP→L | write-e2e |
| `test-audit:73` | "`--read-only` … skip Phases 4-6 (coverage.md/backlog.md writes)" | POLICY (flag doc) | | | |
| `test-audit:621-634` | "Persist findings to `memory/backlog.md`: 1. Read … If missing, create with template. 2. … Dedup: existing = increment `Seen`. 3. Delete resolved items. … Source: `test-audit/{date}`" | WRITE (core) + WRITE* (delete); the source is invalid today | O | TEST-GAP/MUTATION/CQ→L (BUG via `--missing-assertion`) | test-audit |
| `test-audit:641-643`, `:685` | "backlog.md updated: [N] entries ([N] new, [N] deduped)"; checklist | OUT | | | |

### Batch 8: code audits (5 files)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `code-audit:690`, `:720` | checklist; "add a backlog item `B-code-audit-incomplete-<date>`" | OUT; WRITE | O | PROCESS→L | code-audit |
| `code-audit:746-764` | "Persist findings to `memory/backlog.md`: Read … create with template … Fingerprint `file\|CQ-id\|signature` … New = append `B-{N}` … Delete resolved items … Tier A: … Delete any open backlog items for Tier A files." | WRITE (core) + WRITE* | O | CQ→L; SEC (CQ4/CQ5/CAP6); BUG when concrete | code-audit |
| `api-audit:495-505` | "When active, persist findings (confidence 26+) to `memory/backlog.md`: Read … create … Dedup: increment `Seen` … Delete resolved items" | WRITE (opt-in) + WRITE* | O | SEC (D9 auth) / BUG / CQ | api-audit |
| `security-audit:64`, `:75`, `:85` | "`--persist-backlog` Emit backlog entries for CRITICAL/HIGH"; "AND persisted to backlog"; "N v2 findings reported + backlogged" | POLICY/OUT | O | SEC | security-audit |
| `security-audit:858-866` | "When active, persist CRITICAL and HIGH findings to `memory/backlog.md`: Fingerprint `file\|dimension\|endpoint`" | WRITE (opt-in) | O | SEC (from conf 26) | security-audit |
| `security-audit:955-957` | "add backlog item `B-security-audit-incomplete-<date>`" | WRITE | O | PROCESS→L | security-audit |
| `structure-audit:561-565`, `:650` | "For HIGH and CRITICAL findings, persist to `memory/backlog.md` … Fingerprint `file\|SA-dimension\|check-id`"; "`B-structure-audit-incomplete`" | WRITE | O | SIZE/DUP/CPLX/DEAD/CQ→L; PROCESS→L | structure-audit |
| `db-audit:147`, `:191`, `:1122` | "add a backlog item: `[BLOCKER] db-audit needs <tool>…`"; "Add the gap to the backlog as `B-db-audit-incomplete-<date>`"; "add a backlog item" | WRITE | O | PROCESS→L | db-audit |
| `db-audit:1026-1027` | "## Backlog Entries [/backlog add commands for HIGH+ findings]" | WRITE (suggested) | O | PERF→L / DATA / SEC / BUG | db-audit |
| `db-audit:977`, `:1039`, `:1077` | PLANNED reads; checklist | READ; OUT | | | |

### Batch 9: web and content audits and fixes (5 files)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `seo-audit:11`, `:141`, `:165`, `:737-746` | "`--persist-backlog` \| Persist prioritized findings to `memory/backlog.md`"; "Emit entries to `memory/backlog.md` … Fingerprint `{file}\|{dimension}\|{check}` … Deduplicate" | WRITE (opt-in) | O | CQ/ADVISORY→L; BUG/SEC (live) | seo-audit |
| `seo-fix:529`, `:534` | adversarial boilerplate | WRITE | O | BUG/CQ | seo-fix |
| `seo-fix:652-669` | "FIXED \| Remove row by fingerprint"; "NEEDS_REVIEW \| If exists: increment `Seen`. If new: add as OPEN"; "MANUAL/OUT_OF_SCOPE/NO_TEMPLATE \| Add as OPEN" | WRITE + WRITE* | O | CQ/PROCESS→L | seo-fix |
| `geo-audit:134`, `:158`, `:744-755` | same shape as seo-audit | WRITE (opt-in) | O | CQ/ADVISORY→L | geo-audit |
| `geo-fix:492`, `:499`, `:604-623` | boilerplate; the same table, plus "ALREADY_APPLIED_BY_SEO_FIX \| No backlog action" | WRITE + WRITE* | O | CQ/PROCESS→L | geo-fix |
| `content-audit:10`, `:79`, `:97`, `:471-482` | "`--persist-backlog` \| Append findings to memory/backlog.md"; "FAIL (blocking) \| Add as OPEN …"; "ADVISORY \| Add as OPEN" | WRITE (opt-in) | O | CQ→L; ADVISORY→L | content-audit |

### Batch 10: other audits (5 files)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `content-fix:76`, `:362-372` | "`memory/backlog.md` for backlog updates"; "FIXED \| Remove row by fingerprint"; "NEEDS_REVIEW … increment `Seen` … add as OPEN"; "MANUAL \| Add as OPEN" | WRITE + WRITE* | O | CQ/PROCESS→L | content-fix |
| `a11y-audit:72`, `:570-579` | "If `--persist-backlog` is set **or CRITICAL findings exist**: … persist to `memory/backlog.md`: `- B-{N} \| {file}:{line} \| A11Y-{NNN} …`"; "increment `seen:N`" | WRITE (automatic on CRITICAL) | O | BUG (A2 keyboard trap, A5 form) / CQ→L | a11y-audit |
| `architecture:560-568` | "persist actionable items to `memory/backlog.md` … Zero risks may be silently discarded … they must reach the backlog" | WRITE | O | PROCESS→L `subject:` (ADR consequences, open questions); CPLX/DUP/SIZE→L | architecture |
| `pentest:775-781` | "suggest a backlog entry: `zuvo:backlog add "PT3-001: …" --severity HIGH --source pentest --dimension PT3`" | WRITE (suggested; the flags do not exist) | O | SEC `--target` URL/host | pentest |
| `performance-audit:609-616` | "propose a backlog entry: `/backlog add PERF-D7: N+1 …`" | WRITE (suggested) | O | PERF→L / BUG | performance-audit |

### Batch 11: flag-only audits (2 files)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `container-audit:13`, `:72` | "`--persist-backlog` \| Push findings to `zuvo:backlog`" (no phase body) | WRITE (flag only) | O | SEC/CQ | container-audit |
| `infra-audit:105` | "backlog-protocol.md -- [READ \| MISSING] (findings → backlog entries)" (no body). The load is pinned by `tests/infra-suite/test-infra-skill-contract.sh:91`. | POLICY | O | SEC/BUG `--target` host | infra-audit |

### Batch 12: added in plan revision 2 (plan reviewer)

| Site | Quote | Verdict | Caller | Classes | Source |
|---|---|---|---|---|---|
| `skills/content-expand/SKILL.md:276` | "Persist findings per `backlog-protocol.md`." | WRITE (by reference; guard-blind) | O | CQ/ADVISORY→L; `--target <url>` for a live page | content-expand |
| `skills/content-expand/SKILL.md:75` | "`--light` \| Skip reporting, backlog, knowledge curation." | POLICY (flag doc) | O | | |

### Not sites

- **GROOM, FORMAT and allowlist:**
  - `backlog-protocol.md` (whole file; the guard asserts that the "Persisting a finding" section and its "Never append a finding to `memory/backlog.md` by hand" sentence exist)
  - `backlog-grooming.md`
  - `backlog-verifier.md`
  - `skills/backlog/SKILL.md` maintenance sections
- **READ:**
  - `retro:132-141`, `:463-581`
  - `using-zuvo:110`, `:162`, `:213`
  - `knowledge-prime:23`, `knowledge-curate:6`
- **NOT (negations, history, names):**
  - `comment-pass:68`, `:133` (pinned "never backlog")
  - `ui-design-team:351` "P2 -- BACKLOG" (a report tier label; no write)
  - `adversarial-loop:336` (verdict vocabulary)
  - `ssh-probe-protocol:86`, `test-code-types-php:172` (backlog ids as history)
  - `run-logger:130`, `retrospective:104`, `session-state:197` (telemetry definition, pinned), `fix-output-schema:5`
- **Totals:**
  - WRITE, WRITE* and POLICY: ≈118 units in **43 files** (28 SKILL.md, 10 includes, 5 refactor references).
  - AGENT: 2 files.
  - OK-AGENT: 9 files.
  - OUT lines: ≈30.

## Existing tests that pin phrases a rewire could break

| Pinned phrase / token | Where it lives | Test file:line |
|---|---|---|
| `'rc 1' 'no backlog' 'The one exception is the exit valve'` | comment-pass blocks: `build:628`, `execute:737`, `review:1330`, refactor `remediation.md:65`, … | `tests/skill-suite/test-comment-pass-wiring.sh:133` |
| `never backlog` | `shared/includes/comment-pass.md:68` | `test-comment-pass-wiring.sh:185-186` |
| `backlog-adds` (int, `-1` sentinel), `TT_BACKLOG_ADDS` | `execute:358`, `:380`, `:965-1044`; `session-state.md:197` | `tests/skill-suite/test-task-telemetry-contract.sh:527`, `:675-678`, `:785`, `:867`, `:1025`, `:1083`, `:1931` |
| `fixed:2/backlog:4`, `1fixed,1backlogged`, `backlogged:3` (refactor CONTRACT disposition) | refactor references / CONTRACT | `tests/hooks/test-refactor-safety-gate.sh:91-100` |
| `7/5:2-backlogged-out-of-fence` (`prove.split_coverage`) | `remediation.md:137` | `tests/hooks/test-refactor-v4-prove-gate.sh:120-121` |
| The include names `backlog-done.md`, `ARCHIVED`, `ABSENT`, `REGRESSION`, `verbatim`; it must NOT contain `delete the row entirely` (include AND `skills/backlog/SKILL.md`), `Fingerprint column`, `>= 50 resolved`, `100 KB of resolved text` | `backlog-protocol.md`, backlog SKILL | `tests/hooks/test-backlog-archive-dedup.sh:37-49`, `:296-303` |
| The Verdict, Exit, Class, Refusal and Argument tables, and the Confidence-Based Routing bands | `backlog-protocol.md` §Persisting… and §Confidence-Based Routing | `tests/hooks/test-backlog-add-contract.sh` (C1-C4; bad-pr probe `--pr abc` at `:417`) |
| The `## The '## B-id' heading dialect` section | `backlog-protocol.md` | `tests/hooks/test-backlog-headings.sh:1144`, `:2061-2079` |
| `backlog-verdicts.jsonl`, `inherits the source's visibility`, `is False` | `backlog-protocol.md` | `tests/hooks/test-backlog-grooming.sh:1002-1012` |
| No grooming verdict token (STALE-FIXED …) in `severity-vocabulary.md` | `severity-vocabulary.md` (when editing l.40) | `test-backlog-grooming.sh:468` |
| `backlog-protocol.md` referenced as a Stage-2 include | `infra-audit` | `tests/infra-suite/test-infra-skill-contract.sh:91` |
| `appended by hand`, `backlog-add`, `warning, not a gate` | the hook, not prose | `tests/hooks/test-backlog-hand-append-warn.sh` |

Not pinned (verified by searching `tests/` and `scripts/validate-*`): the adversarial boilerplate ("fix if localized", "Pre-existing … NOT a reason"), `--persist-backlog`, `B-{N}`, `[low-confidence]`/`[below-threshold]`, `B-review-*`, `Backlog Items Added`, `v2-grace … backlogged`, `[SHIP] findings dispositioned`, the `Drive-by:` line, and all seo/geo/content tables. `evals/{review,write-tests,refactor}.evals.json` mention "deferring to the backlog" in assertions, but `run-all` does not run evals.

