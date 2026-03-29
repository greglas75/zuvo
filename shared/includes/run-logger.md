# Run Logger

> Shared include — referenced by skills that should log their execution.

## When to Log

Log at the END of every skill run, after all work is done. One line per run.

## Log File

Use an environment-aware log path:

- Claude Code: `~/.zuvo/runs.log`
- Codex CLI (local): `~/.zuvo/runs.log`
- Codex App (cloud): `memory/zuvo-runs.log`
- If `~/.zuvo/` is not writable: use the project-local fallback path

Detection:
- if `CODEX_WORKSPACE` is set, or
- if `~/.zuvo/` is not writable

then use the project-local path.

## Format

Single-line TSV (tab-separated), one entry per run:

```
DATE\tSKILL\tPROJECT\tCQ_SCORE\tQ_SCORE\tVERDICT\tTASKS\tDURATION\tNOTES
```

| Field | Value | Example |
|-------|-------|---------|
| DATE | ISO 8601 timestamp | `2026-03-27T14:30:00` |
| SKILL | Skill name without namespace | `build` |
| PROJECT | Project directory basename | `tgm-survey-platform` |
| CQ_SCORE | CQ score if evaluated, `-` if not | `18/22` |
| Q_SCORE | Q score if evaluated, `-` if not | `15/17` |
| VERDICT | PASS, WARN, FAIL, BLOCKED, ABORTED, or `-` | `PASS` |
| TASKS | Number of tasks completed (for pipeline/build), `-` for audits | `4` |
| DURATION | Phases completed or task count | `5-phase` |
| NOTES | One-line summary, max 80 chars | `added user export with CSV` |

## How to Log

At the end of the skill, resolve the log path first, then append one line.
Do not hardcode `~/.zuvo/runs.log` in skills that run in multiple environments.

Or if Bash is unavailable, use Write tool to append.

## Path Resolution (reference)

See the environment-aware log path table in the "Log File" section above. The canonical resolution logic:

```bash
if [ -n "$CODEX_WORKSPACE" ] || ! mkdir -p ~/.zuvo 2>/dev/null; then
  LOG_PATH="memory/zuvo-runs.log"
else
  LOG_PATH="$HOME/.zuvo/runs.log"
fi
```

## What NOT to Log

- Do not log failed skill invocations (wrong skill routed, user cancelled immediately)
- Do not log partial runs where no work was done
- Do not include file paths, code snippets, or sensitive data in NOTES
- Do not send data anywhere — this is a local file only

## Reading the Log

Users can view their history. Use the resolved log path (see "Log File" above):

```bash
# Resolve path first (same logic as writing)
LOG_PATH="$HOME/.zuvo/runs.log"
[ -n "$CODEX_WORKSPACE" ] && LOG_PATH="memory/zuvo-runs.log"

# Last 20 runs
tail -20 "$LOG_PATH"

# Runs for a specific project
grep "tgm-survey" "$LOG_PATH"

# Only failures
grep "FAIL" "$LOG_PATH"

# CQ scores over time
grep "build" "$LOG_PATH" | cut -f4
```
