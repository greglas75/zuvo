# Platform Detection

> Shared include — referenced by skills that need to detect the project's deployment platform, deploy CLI, health check, and rollback commands.

## Platform Detection Table

| File/pattern | Platform | Deploy CLI | Health check |
|---|---|---|---|
| `vercel.json` or `.vercel/` | Vercel | `vercel --prod` | `curl` prod URL |
| `fly.toml` | Fly.io | `fly deploy` | `fly status` |
| `netlify.toml` | Netlify | `netlify deploy --prod` | `curl` prod URL |
| `railway.json` or `railway.toml` | Railway | `railway up` | `curl` prod URL |
| `render.yaml` | Render | webhook (no CLI deploy) | `curl` prod URL |
| `.github/workflows/*deploy*` | GitHub Actions | `gh workflow run` | `gh run view` |
| None detected | Unknown | manual instructions | manual |

## Detection Algorithm

1. **Scan project root for platform config files.** Check in the priority order listed in the table above (top row first). Record ALL detected platforms, but use the FIRST match as the primary platform. Priority: explicit platform file > GitHub Actions workflow > unknown.

2. **If multiple config files are detected, use the first match in priority order.** Log all detected platforms for the user's awareness so they can override if the primary detection is wrong. Example: a project with both `vercel.json` and `.github/workflows/deploy.yml` resolves to Vercel as primary.

3. **Verify whether automated deploy is available for the detected platform.**
   - Check whether the required CLI is installed and usable.
   - If the CLI is unavailable, **do not downgrade the platform to `unknown`**.
   - Keep the detected platform, set `cli: null`, and mark deployment as manual or webhook-driven for this environment.
   - Special case: for GitHub Actions, check `gh auth status` instead of `which gh`.

4. **If only `.github/workflows/*deploy*` matched** (no explicit platform config file): read the workflow YAML file. Extract the deploy job name and trigger event. Use `gh workflow run <workflow-name>` as the deploy command and `gh run view` for status polling. If multiple deploy workflows exist, present the list and ask the user to pick (or use `[AUTO-DECISION]: first workflow` in non-interactive environments).

5. **Special case: Render.** If `render.yaml` is the primary detection, there is no CLI deploy command. Prompt the user for their deploy hook URL via `AskUserQuestion`. In non-interactive environments (Codex, Cursor, Antigravity), skip automated deploy with `[AUTO-DECISION]: no Render CLI available` and print manual instructions.

## Output Object

After running the algorithm, the calling skill receives a result with these fields:

```
platform:    "vercel" | "fly" | "netlify" | "railway" | "render" | "github-actions" | "unknown"
cli:         "<deploy command>" | null
cliAvailable: true | false
deployMode:  "cli" | "webhook" | "manual"
healthCmd:   "<health check command>" | null
rollbackCmd: "<rollback command>" | null
```

## Rollback Commands

| Platform | Rollback command | Notes |
|---|---|---|
| Vercel | `vercel rollback` | Rolls back to previous deployment |
| Fly.io | `fly deploy --image <previous>` | Requires previous image ref from `fly releases` |
| Netlify | `netlify deploy --prod --dir <prev-deploy>` | Or rollback via Netlify dashboard |
| Railway | `railway up --detach` + redeploy previous | No native rollback CLI |
| GitHub Actions | `gh run rerun <run-id>` | Re-run previous successful workflow |
| Unknown / manual | `git revert <merge-sha> && git push` | Git-native fallback |

## Usage

Skills that need platform detection read this file and follow the algorithm above. Currently used by: `zuvo:deploy` and `zuvo:canary`.
