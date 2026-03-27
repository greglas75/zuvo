# Run Logger

> Shared include — referenced by skills that should log their execution.

## When to Log

Log at the END of every skill run, after all work is done. One line per run.

## Log File

Append to `~/.zuvo/runs.log`. Create the directory and file if they don't exist.

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

At the end of the skill, append one line:

```bash
mkdir -p ~/.zuvo
echo "2026-03-27T14:30:00\tbuild\tmy-project\t18/22\t15/17\tPASS\t4\t5-phase\tadded user export" >> ~/.zuvo/runs.log
```

Or if Bash is unavailable, use Write tool to append.

## What NOT to Log

- Do not log failed skill invocations (wrong skill routed, user cancelled immediately)
- Do not log partial runs where no work was done
- Do not include file paths, code snippets, or sensitive data in NOTES
- Do not send data anywhere — this is a local file only

## Reading the Log

Users can view their history:

```bash
# Last 20 runs
tail -20 ~/.zuvo/runs.log

# Runs for a specific project
grep "tgm-survey" ~/.zuvo/runs.log

# Only failures
grep "FAIL" ~/.zuvo/runs.log

# CQ scores over time
grep "build" ~/.zuvo/runs.log | cut -f4
```
