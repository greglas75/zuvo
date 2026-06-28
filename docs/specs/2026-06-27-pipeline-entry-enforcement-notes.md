# Pipeline-Entry Enforcement — Spike + Contract Notes (Task 1)

Resolves every cross-harness/CI/parse unknown the rev3 plan depends on, BEFORE Tasks 4–11 build on them. One VERDICT line per question (a–h), each with a fallback where the answer is "no/unsupported". Grounded in the actual repo state probed 2026-06-27.

## Probed environment facts (2026-06-27)

- default branch: `main` (`git symbolic-ref refs/remotes/origin/HEAD` → main)
- `.github/workflows/`: **none** — CI gate (Task 5) is greenfield; its template is the repo's first workflow.
- `hooks/hooks.antigravity.json` top-level keys: `SessionStart`, `BeforeTool` — **no PreToolUse, no Stop** (confirms reviewer H-1).
- `hooks/hooks.codex.json`: `SessionStart`, `PreToolUse(Bash)`, `PostToolUse(Read)` — **no Stop**.
- `hooks/hooks.json` (Claude): has a `Stop` array (currently `zuvo-rewake-reset`) and `~/.claude/settings.json` separately registers `zuvo-stop-retro-sweep.sh`.
- `tests/`: exists (adversarial, fixtures, security-corpus, …) but **no `tests/hooks/`** — plan creates it. No npm test runner (`package.json` scripts `{}`) → tests run as `bash tests/hooks/<f>.sh`.
- `shellcheck`: **NOT installed**; `jq`: installed.

## Contract VERDICTs

**(a) Production-file classifier — VERDICT:** a path is "production" unless it matches any of: `tests/`, `**/__tests__/`, `*.test.*`, `*.spec.*`, `docs/`, `*.md`, `*.json`, `*.ya?ml`, `*.toml`, `.*rc`, `*.lock`, `zuvo/`. Fallback: when classification is ambiguous, count it as production (fail toward enforcement) EXCEPT the gate as a whole still fails-open on errors.

**(b) Substantial — VERDICT:** `git diff --shortstat <range>` → block-eligible iff `(files_changed ≥ ZUVO_GATE_MIN_FILES)` OR `(added+deleted ≥ ZUVO_GATE_MIN_LINES)`, counting production files only. Defaults `ZUVO_GATE_MIN_FILES=3`, `ZUVO_GATE_MIN_LINES=150`, env-overridable. Counts add+del (not just additions). Fallback: if `--shortstat` unparseable → not-substantial (fail-open).

**(c) Review-artifact schema — VERDICT:** path `memory/reviews/<base7>..<head7>-<slug>.md`. Machine-readable header (first lines):
```
<!-- zuvo-review -->
range: <base_sha>..<head_sha>
files: path/one.ts, path/two.ts        # union of reviewed files (or `*` = whole range)
verdict: APPROVE|CHANGES|...
-->
```
`pg_range_reviewed(<range>)` = TRUE iff a review artifact exists whose `range` contains the change's commits OR whose `files` set ⊇ the change's production files. An UNRELATED artifact (covers other files only) is NOT coverage. Written on SUCCESS only (crash → no artifact → no coverage). Fallback: header missing/unparseable → reviewed=unknown→non-block (fail-open) locally; CI treats unknown as NOT-reviewed (fail-closed server-side, since CI is the guarantee).

**(d) pre-push stdin contract — VERDICT:** git feeds the pre-push hook one line per ref on stdin: `<local_ref> <local_sha> <remote_ref> <remote_sha>`. Deleted ref → `local_sha` all-zeros (skip). New branch (no remote) → `remote_sha` all-zeros → range = `git merge-base <local_sha> <default-branch>`..`<local_sha>`. Normal update → range = `<remote_sha>..<local_sha>`. Fallback: empty/garbled stdin → evaluate nothing, exit 0 (fail-open).

**(e) CI provider + escape — VERDICT:** GitHub Actions is the primary, shipped target (`ci/zuvo-pipeline-entry.yml` template invoking `scripts/zuvo-pipeline-entry-ci.sh`); repo is greenfield so no merge conflict with existing CI. Range from `GITHUB_BASE_REF`/`GITHUB_SHA` (PR) or push `before`..`after`. **Escape = PR label `zuvo:adhoc-approved`** (read from `GITHUB_*` event JSON) — human-applied only; an agent cannot self-apply a label, so it cannot self-exempt the unbypassable layer. GitLab/others: documented as detection-level (provide the check script; user wires their own CI step). Fallback: unknown CI env → script computes range from `merge-base HEAD origin/<default>` and runs the same check.

**(f) commit/Stop nudge range — VERDICT:** nudges compute `git merge-base HEAD <default-branch>..HEAD` + working tree — **NOT a session-base SHA** (the rev2 fragility). Nudges are **best-effort and NON-load-bearing**: the guarantee is pre-push + CI. Therefore Stop exit-2 efficacy is NOT required for correctness — see (g).

**(g) Does Claude Code Stop hook block on exit 2? — VERDICT: YES (Claude Code only).** Per Claude Code hooks docs + this session's research (zarar.dev): a Stop hook returning exit 2 blocks the stop and feeds stderr back to the agent; `stop_hook_active` guards the loop. So on Claude Code the Stop-gate (Task 7) emits exit 2 to actively force review. **Codex + Antigravity have NO Stop hook** (probed above) → the Stop nudge does not run there; pre-push + CI are their net (commit-gate nudge runs on Codex via PreToolUse). Cursor inherits the Claude cache wiring. Fallback (if exit-2 ever stops blocking): Task 7 degrades to a loud stderr nudge (exit 0) — acceptable because it was never the guarantee.

**(h) Agent-env detection (human-exemption) — VERDICT:** treat as an AGENT invocation iff any of these env vars is set: `CLAUDE_*` (e.g. `CLAUDECODE`, `CLAUDE_PLUGIN_ROOT`), `CODEX_*` (`CODEX_WORKSPACE`), `CURSOR_*`, `GEMINI_*`/antigravity markers, or `ZUVO_AGENT=1`. No agent var set → HUMAN → pre-push gate and PATH-shim pass through transparently (G6/G8). Fallback: detection inconclusive → treat as human (pass-through) for the PATH-shim (never break a human's git), but the hook-based gates already only fire inside agent tool-calls so the question is moot there.

## Robust git-command parse rule (for block-no-verify + commit-gate)

Skip global options before the subcommand: `-c <k=v>`, `-C <dir>`, `--git-dir=…`, `--work-tree=…`, `--namespace=…`, `-c`, `--exec-path…`, `-p`/`--paginate`/`-P`. The first non-option token is the subcommand. `--no-verify` rejected on commit/push/merge/cherry-pick/rebase/am; `-n` rejected ONLY when subcommand == `commit` (it is `--dry-run` for push/add).

## Tooling degradations recorded

- **shellcheck absent** → Verify steps that called `shellcheck` degrade to `bash -n <file>` (syntax check) + the behavior test; record `[DEGRADED: shellcheck unavailable — bash -n used]`. Recommend documenting shellcheck as an optional dev dep.
- **no test runner** → hook tests run as `bash tests/hooks/<file>.sh`; each prints `ALL PASS`/`SMOKE PASS` and exits non-zero on failure.

## Single-Stop-registration decision (resolves H-2)

Register the Stop nudge in **plugin `hooks/hooks.json` `Stop`** (alongside `zuvo-rewake-reset`), `async:false` so exit 2 is honored — NOT additionally in `~/.claude/settings.json`. Rationale: plugin `hooks.json` is the versioned, install-synced source; `settings.json` registration (used by retro-sweep) is a separate legacy path. One site = no double-fire. Task 10 owns it; Task 11 install must NOT also register it.

## Human checkpoint

VERDICTS above are the foundation for Tasks 4–11. Interactive execute STOPS here for user confirmation before the build tasks proceed.
