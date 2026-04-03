---
name: deploy
description: >
  Deploy to production and verify health. Reads ship state, merges PR if applicable,
  detects platform (Vercel/Fly/Netlify/Railway/Render/GHA), waits for CI, triggers
  deploy, runs health check, offers rollback on failure.
  Flags: --url, --skip-ci-wait, --skip-health, #<number>.
---

# zuvo:deploy

Deploy to production and verify health. Merge, deploy, check, rollback if needed.

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Argument | Effect |
|----------|--------|
| _(no flags)_ | Auto-detect from `memory/last-ship.json` or git tags |
| `--url <url>` | Override production URL for health check |
| `--skip-ci-wait` | Don't wait for CI (manual check) |
| `--skip-health` | Skip health check after deploy |
| `--health-path <path>` | Path to check instead of root (e.g., `/health`, `/api/status`) |
| `--expect-status <code>` | Expected HTTP status code (default: 200) |
| `#<number>` | Specific PR number to merge (overrides last-ship.json PR) |

Flags can be combined: `zuvo:deploy --url https://myapp.com --skip-ci-wait`

## Mandatory File Loading

Read each file below using the Read tool. Print the checklist with status before proceeding. Do not proceed from memory.

```
CORE FILES LOADED:
  1. {plugin_root}/shared/includes/env-compat.md          — READ/MISSING
  2. {plugin_root}/shared/includes/run-logger.md           — READ/MISSING
  3. {plugin_root}/shared/includes/platform-detection.md   — READ/MISSING
```

If any file is missing: proceed in degraded mode. Note which files are unavailable in the Phase 7 output.

---

## SAFETY RULES

**Read these before executing any phase. Violations are non-recoverable.**

1. **NEVER** use `git push --force` or `git push -f`. Under no circumstances.
2. **NEVER** auto-rollback without user consent. Always present the rollback command and let the user decide whether to execute it.
3. **NEVER** push to a remote repository without explicit user confirmation. In non-interactive environments (Codex, Cursor): skip the push step entirely and state that pushing is a separate manual step (per env-compat.md hard rule).

---

## Phase 0: Read Ship State

1. **Read `memory/last-ship.json`** if it exists. Extract: `version`, `newTag`, `previousTag`, `baseSha`, `releaseCommitSha`, `range` (SHA-based), `branch`, `flow` (`"direct"` or `"pr"`), `pr` (number or null), `targetBranch`, `tagPushed` (boolean), `pushed` (boolean). If the artifact uses legacy fields (`tag` instead of `newTag`, `headSha` instead of `releaseCommitSha`, version-based `range`), fall back to those with a warning. If `branch` is missing, detect it via `git branch --show-current`.
   - If `pushed` is `false` (commit/branch was not pushed to remote):
     - **Interactive:** Ask: "Release commit was not pushed. Push `<branch>` to origin now?" If yes: `git push origin <branch>`. If no: STOP — cannot deploy unpushed code.
     - **Non-interactive:** STOP. Print: `Cannot deploy — release commit was not pushed. Run manually: git push origin <branch>`
   - If `tagPushed` is `false` (tag created locally but not pushed):
     - **Interactive:** Ask: "Tag `v<version>` was created locally but not pushed. Push now?" If yes: `git push origin v<version>`. If no: continue.
     - **Non-interactive:** `[AUTO-DECISION]: tag push skipped in non-interactive environment. Push manually: git push origin v<version>`

2. **If `memory/last-ship.json` does not exist:** fall back to `git describe --tags --abbrev=0`. Use the result as the version/tag. Set `flow` to `"direct"`, `pr` to `null`.

3. **If `#<number>` argument was provided:** override the PR number, regardless of `last-ship.json`. Set `flow` to `"pr"`.

4. **Detect default branch and check GitHub CLI:**
   ```bash
   DEFAULT_BRANCH=$(gh repo view --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null \
     || git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' \
     || echo main)
   gh auth status
   ```
   - Use `targetBranch` from `last-ship.json` if available; otherwise use `DEFAULT_BRANCH`.
   - If `gh auth status` fails or `gh` is not installed: set `GH_AVAILABLE=false`. PR merge, CI checks, and GHA deploy will be skipped with manual instructions printed instead.

5. **If `GH_AVAILABLE=false`:**
   - If `flow` is `"pr"`: STOP automated PR deployment. Print:
     ```
     GitHub CLI unavailable — cannot inspect, merge, or verify PR flow automatically.
     Manual steps:
       1. Verify PR #<number> is approved and mergeable
       2. Merge it manually into <default-branch>
       3. Re-run `zuvo:deploy` after merge, or deploy manually on your platform
     ```
     Set deploy verdict to `PARTIAL` and proceed directly to Phase 7 output.
   - If `flow` is `"direct"`: CI wait (Phase 4) will be skipped — platform detection is not yet available at this point, so assume CI check is manual. Print a warning that CI verification is manual in this run.

---

## Phase 1: Pre-merge Checks (PR flow only)

**Skip this entire phase if `flow` is `"direct"`.**

1. **Verify PR exists and is open:** `gh pr view <number> --json state`
   - If state is not `"OPEN"`: STOP. "PR #<number> is not open (state: <state>). Cannot deploy a closed or merged PR."

2. **Check mergeability (E8):** `gh pr view <number> --json mergeable`
   - If not mergeable: STOP. "PR #<number> has merge conflicts. Resolve conflicts and re-run `zuvo:deploy`."

3. **Check base branch CI status (E7):** `gh run list --branch <default-branch> --limit 1 --json status,conclusion`
   - If failing: WARN. "CI is currently failing on the base branch (not caused by your changes). Proceed with merge anyway, or investigate first?" In non-interactive: `[AUTO-DECISION]: base CI failing, proceeding with merge`.

4. **Check PR CI status:** `gh pr checks <number> --json name,state,conclusion`
   - Required checks failing: STOP. "Required CI checks are failing on PR #<number>."
   - Checks pending: proceed to Phase 2 (CI wait handles it after merge).
   - All checks pass: proceed to Phase 2.

---

## Phase 2: Merge (PR flow only)

**Skip this entire phase if `flow` is `"direct"`.**

1. **Confirmation gate:** Merging is irreversible. Require explicit confirmation before proceeding:
   - **Interactive (Claude Code, Codex CLI):** Ask: "Ready to merge PR #<number> into <default-branch> via squash? This cannot be undone."
   - **Non-interactive (Codex App, Cursor):** Skip merge entirely. Print:
     ```
     [NON-INTERACTIVE] Merge skipped — requires interactive confirmation.
     Run manually: gh pr merge <number> --squash --delete-branch
     ```
     Set deploy verdict to `PARTIAL`. Skip Phases 3-6 — proceed to Phase 7 output.

2. **Merge the PR:** `gh pr merge <number> --squash --delete-branch`

3. **If merge fails:** STOP. Do not retry. "Merge failed for PR #<number>. Investigate the error above and retry manually."

4. **Record the merge commit SHA** for CI matching in Phase 4: `git fetch origin <default-branch> && git rev-parse origin/<default-branch>`

---

## Phase 3: Platform Detection

1. **Read `{plugin_root}/shared/includes/platform-detection.md`** and follow the 5-step detection algorithm described there:
   - Step 1: Scan project root for platform config files in priority order.
   - Step 2: If multiple detected, use first match; log all.
   - Step 3: Verify CLI availability. If missing, keep platform but set `cli: null`.
   - Step 4: GHA-only special case — parse workflow YAML.
   - Step 5: Render special case — no CLI, prompt for webhook URL.

2. **Record the full detection result** (all fields from platform-detection.md output object):
   ```
   platform:     "<detected platform>"
   cli:          "<deploy command>" or null
   cliAvailable: true | false
   deployMode:   "cli" | "webhook" | "manual"
   healthCmd:    "<health check command>" or null
   rollbackCmd:  "<rollback command>" or null
   ```

3. **Print the result to the user:** "Detected platform: **<platform>** (from `<config-file>`)"

4. **If `cliAvailable` is `false`** (platform detected but CLI not installed):
   - If `deployMode` is `"webhook"`: prompt for webhook URL and trigger it. Proceed to Phase 6 (health check).
   - If `deployMode` is `"manual"`: print platform-specific manual deployment instructions. Set deploy verdict to `PARTIAL`. Skip Phases 4, 5, and 6 — proceed directly to Phase 7 output.

5. **If no platform detected (E9):** Print a manual deployment checklist:
   ```
   No deployment platform detected. Manual deployment required:
     1. Verify the merge commit is on the target branch
     2. Deploy using your project's deployment process
     3. Verify production health at your production URL
     4. Run: zuvo:canary <url> (optional post-deploy monitoring)
   ```
   Set deploy verdict to `PARTIAL`. Skip Phases 4, 5, and 6 — proceed directly to Phase 7 output.

---

## Phase 4: CI Wait

**If `--skip-ci-wait` was passed:** skip this phase. Print: "CI wait skipped (--skip-ci-wait flag)."

**If `GH_AVAILABLE=false`:** Skip this phase. Print: "gh CLI unavailable — cannot check CI status. Verify CI manually before proceeding."

1. **Find the CI run:** `gh run list --branch <default-branch> --limit 5 --json headSha,status,conclusion,databaseId`

2. **Match by SHA** from the merge commit (Phase 2 step 4) or the latest commit on the default branch (direct flow).

3. **If already complete:** `conclusion: "success"` — proceed. `conclusion: "failure"` — STOP. "CI failed after merge. Investigate before deploying."

4. **If still in progress:** poll every 30 seconds with `gh run view <run-id> --json status,conclusion`.

5. **Timeout: 15 minutes.** If CI has not completed:
   - **Interactive environment:** Present 3 options:
     - **(A)** Wait 15 more minutes
     - **(B)** Skip CI check and proceed to deploy
     - **(C)** Abort deployment
   - **Non-interactive environment:** `[AUTO-DECISION]: CI wait timeout after 15m. Proceeding to deploy.`

---

## Phase 5: Deploy

1. **Run the deploy command** from the platform detection result (e.g., `vercel --prod`, `fly deploy`, `netlify deploy --prod`).

2. **Wait for deployment to complete:**
   - **Vercel / Netlify:** Wait 60 seconds (auto-deploy on push).
   - **Fly.io:** Poll `fly status --app <app>` until running.
   - **GitHub Actions:** Poll `gh run view <run-id>` until complete.
   - **Railway:** `railway status` or wait 60 seconds.

3. **If deploy fails:** STOP. Print error. Offer rollback (do NOT auto-execute):
   ```
   Deploy command failed. To rollback:
     <rollbackCmd from platform detection>
   Run this command to rollback, or investigate further.
   ```

---

## Phase 6: Health Check

**If `--skip-health` was passed:** skip this phase. Print: "Health check skipped (--skip-health flag)."

1. **Determine the production URL:**
   - `--url <url>` provided: use it.
   - Platform has a known URL (from detection, config, or deploy output): use it.
   - Otherwise: ask the user. Non-interactive: `[AUTO-DECISION]: no production URL available, skipping health check`.

2. **Build a normalized `healthUrl`:**
   - If `--health-path` is omitted: use `<url>`.
   - If `--health-path` is a full URL: use it verbatim.
   - Otherwise join `<url>` and `--health-path` with exactly one slash.
   - **Never** concatenate blindly; normalize duplicate or missing slashes first.

3. **Run the health check:**
   ```bash
   curl -s -o /dev/null -w "%{http_code} %{time_total}" <healthUrl>
   ```
   - Run up to 3 attempts with 5-second intervals on non-200 responses (transient failures during deploy rollout are common).
   - If `--expect-status` was provided: use that instead of 200.

4. **Interpret the result** (from the last successful attempt, or last attempt if all failed):
   - **Expected status + time < 10s:** PASS.
   - **Expected status + time >= 10s:** WARN. "Response is slow (<time>s). Consider investigating."
   - **Non-expected status after 3 attempts:** FAIL.

5. **If FAIL (E10):** Present rollback option. Do NOT auto-execute.
   ```
   Health check FAILED (HTTP <status>, <time>s).
   To rollback, run:
     <rollbackCmd from platform detection>
   Run this command to rollback, or investigate further.
   ```

---

## Phase 7: Output

### 1. Print DEPLOY COMPLETE block

```
DEPLOY COMPLETE
  Version:     v<version>
  Platform:    <platform> (detected from <config-file>)
  CI:          PASS / SKIP / TIMEOUT (<details>)
  Deploy:      SUCCESS / PARTIAL / FAILED
  Health:      PASS / WARN / FAIL / SKIP (HTTP <status>, <time>s)
  URL:         <production-url>

  Next: zuvo:canary <url> (optional monitoring)
```

### 2. Run logger

Append a run log entry per `{plugin_root}/shared/includes/run-logger.md`:

```
<ISO-8601>\tdeploy\t<project>\t-\t-\t<PASS|WARN|PARTIAL|FAIL>\t-\t7-phase\tv<version> <platform> <health-verdict>
```

---

## Edge Cases Summary

| Edge | Scenario | Handling |
|------|----------|----------|
| E7 | CI failing on base branch | WARN — user decides whether to proceed with merge |
| E8 | PR has merge conflicts | STOP — "Resolve conflicts and re-run zuvo:deploy" |
| E9 | No deployment platform detected | Manual checklist, set verdict to PARTIAL, skip Phases 4-6 |
| E10 | Health check fails after deploy | Offer rollback command, do NOT auto-execute |
| E15/DD7 | `tagPushed: false` in last-ship.json | Push tag first (interactive confirmation) or skip (non-interactive) |
