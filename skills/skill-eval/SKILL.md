---
name: skill-eval
description: "Behavioral evaluator for zuvo skills. Runs a skill against its eval corpus (evals/<skill>.evals.json) in fresh executor sub-agents, grades each run transcript against the corpus assertions with an injection-hardened grader, and writes a per-assertion pass/fail report to zuvo/reports/. Supports old-vs-new comparison via --compare <ref>. Dev-only (needs the repo's evals/ + .git)."
---

# zuvo:skill-eval — Behavioral skill evaluator

Measure whether a skill's own instructions lead a competent agent to the correct
behavior. For each eval case in the skill's corpus, a fresh **executor** sub-agent
runs the skill against the case prompt; a fresh **grader** sub-agent then scores
that run's transcript against the case's assertions — judging only real tool calls,
never prose or marker text. The output is a per-assertion pass/fail report with
verbatim evidence, plus an optional old-vs-new score diff.

This skill is **dev-only**: it reads the repo's `evals/` corpus and (for `--compare`)
`.git` history, so it is deliberately NOT distributed into installed plugin caches.

---

## Argument Parsing

| Token | Meaning | Default |
|-------|---------|---------|
| `[skill-name]` | The skill to evaluate; resolves its corpus at `evals/<skill-name>.evals.json`. | required unless `--all-evals` |
| `--compare <ref>` | Also score the OLD version of the skill materialized from git `<ref>` and report an old-vs-new diff. | off (grade current version only) |
| `--all-evals` | Evaluate every `evals/*.evals.json` corpus in the repo, not just one skill. | off |
| `--dry-run` | Resolve + validate the corpus and print the plan (cases × assertions) without dispatching executors/graders. | off |

Parse `$ARGUMENTS`: the first non-flag token is `[skill-name]`; `--compare` consumes
the following token as `<ref>`. If neither `[skill-name]` nor `--all-evals` is given,
stop and ask which skill to evaluate (do not default to all).

---

## Mandatory File Loading

### Phase 0 — Bootstrap (load before any work)

```
CORE FILES LOADED:
  1. ../../shared/includes/eval-schema.md               -- READ/MISSING (corpus + grading + report contract)
  2. ../../shared/includes/report-output-location.md    -- READ/MISSING (canonical zuvo/ output dir)
  3. ../../shared/includes/env-compat.md                -- READ/MISSING (agent dispatch + path resolution)
  4. ../../shared/includes/codesift-setup.md            -- OPTIONAL/READ IF AVAILABLE
  5. ../../shared/includes/session-state.md             -- READ/MISSING (resume/report continuity)
  6. ../../shared/includes/run-logger.md                -- DEFERRED (completion)
```

Resolve these relative to this `skills/skill-eval/SKILL.md`. Degraded-mode rule:

- **`eval-schema.md` missing → HARD STOP** with `BLOCKED_NO_SCHEMA: eval-schema.md
  not found — the corpus schema + grading contract + injection hardening are
  undefined without it`. It is the trust anchor; a report produced without it would
  be trustless, so it is **never** degradable.
- **Any 1 OTHER core file missing** (env-compat / session-state / codesift) → proceed
  in degraded mode, note it in the report.
- **2+ other core files missing** → stop; the plugin installation is incomplete.

`eval-schema.md` is the source of truth for the corpus schema, the grading contract,
the transcript injection hardening, and the report-output convention. Do not
re-derive any of them here — this SKILL orchestrates; `eval-schema.md` specifies.

### Phase 0.2 — Dev-only precondition (fail closed)

skill-eval reads the repo's `evals/` corpus, so it is a dev-time tool. Before any
dispatch, confirm an `evals/` directory exists at the working-tree root. If it does
not, stop with `BLOCKED_DEV_ONLY: skill-eval needs an evals/ corpus in the working
tree — it is not runnable from an installed plugin cache`.

**Do NOT hard-require git here.** Git is used only where it is used, so a non-git
checkout still grades the current version: Phase 2 isolates each case with a `cp -R`
copy of the working tree (no git needed), and every git-specific step is **gated on git
presence** with a non-git fallback — `git remote remove` is skipped when there is no
`.git` (nothing to push to), and the `--all-evals` dedup key falls back to `sha256sum`
of the corpus when `git hash-object` is unavailable. `--compare` (Phase 4) degrades via
`GUARD_NO_GIT` when there is no git repo (it needs `git clone`/`git show`). Making git a
bootstrap hard-stop here would make that `GUARD_NO_GIT` path unreachable — so it is
deliberately left to Phase 4.

**Preflight the two hard tool dependencies (fail loud, never mid-pipeline).** Per the
`preflight-missing-tools` rule, a missing prerequisite must stop BEFORE dispatch, not
crash per-case and read as a behavioral failure:

- `command -v python3 >/dev/null 2>&1` — Phase 3 sanitization/nonce is `python3` (a
  de-facto repo dep: `validate-skills.sh`, the eval-schema test, and `install.sh` all
  use it). If absent, stop with `BLOCKED_NO_PYTHON: skill-eval needs python3 for
  transcript sanitization`.
- **Transcript-capture feasibility.** The grader scores real tool calls, so the run is
  worthless unless each executor's actual tool-call transcript can be captured (a
  parent agent that only sees a sub-agent's final prose would grade every assertion
  `false` by construction — the Task 6 spike used HAND-CRAFTED transcripts and never
  proved auto-capture). This is verified by the **concrete canary probe** at the start
  of Phase 2 (dispatch one throwaway executor that runs a known marker command, then
  assert the captured transcript contains that marker) — NOT by the orchestrator merely
  reasoning that capture "should" work. If the canary's marker is absent from the
  captured transcript, stop with `BLOCKED_NO_TRANSCRIPT_CAPTURE: cannot capture executor
  tool-call transcripts in this runtime — grading would be vacuous` rather than emitting
  an all-`false` report.

### Phase 0.1 — Retro checkpoint marker (run this bash at bootstrap)

```bash
# >>> zuvo:retro-marker  (skill-eval — passive checkpoint capture)
_RS=$(command -v retro-stub 2>/dev/null || ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/zuvo-home/retro-stub 2>/dev/null | head -1)
_ZH="${ZUVO_HOME:-$HOME/.zuvo}"
_RSK="${SKILL:-skill-eval}"
_RPR="${PROJECT:-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")}"
_RSHA=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
[ -n "$_RS" ] && "$_RS" --sweep >/dev/null 2>&1 || true
if mkdir -p "$_ZH/run-markers" 2>/dev/null; then
  { printf 'start_ts=%s\nskill=%s\nproject=%s\nsha7=%s\nbranch=%s\nsession_id=%s\nrepo_root=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_RSK" "$_RPR" "$_RSHA" \
      "$(git branch --show-current 2>/dev/null || echo -)" "${ZUVO_SESSION_ID:-$_RSHA}" \
      "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" \
      > "$_ZH/run-markers/$_RSK-$_RPR-$_RSHA-$$-$(date +%s).marker"; } 2>/dev/null || true
fi
# <<< zuvo:retro-marker
```

---

## Phase 1 — Resolve and load the corpus

0. **Compute `$RUN_ID` ONCE** with a single Bash call and reuse it for every filename in
   this run (baseline snapshot in Phase 4, reports in Phase 5) — never `$$`, which
   differs across the orchestrator's separate Bash tool-calls and would desync the
   filenames: `RUN_ID="$(date -u +%Y%m%d-%H%M%S)-$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')"`.
1. Resolve the target set: `[skill-name]` → `evals/<skill-name>.evals.json`; or with
   `--all-evals`, glob `evals/*.evals.json`. **Validate `[skill-name]` as strict
   kebab-case first** (`^[a-z0-9][a-z0-9-]*$`): reject `/`, `..`, whitespace, and shell
   metacharacters, and require the matching `skills/<skill-name>/` dir to exist. This
   name is interpolated into `git show "<ref>:skills/<skill>/SKILL.md"` and the
   `zuvo/context/skill-eval-baseline-<skill>-<run>.md` path (Phase 4), so an unsanitized
   name could traverse outside `zuvo/context/` or misresolve the git ref — reject it with
   `BLOCKED_BAD_SKILL_NAME` before any git/`--compare` step. Pass the ref and name to git
   as argv (`git show "$ref:skills/$skill/SKILL.md"`), never via shell string-building.
2. **Fail loud on a missing or malformed corpus.** If the file does not exist, stop
   with `BLOCKED_NO_CORPUS: evals/<skill>.evals.json not found — author it first (see
   eval-schema.md)`. If it exists, validate it against `eval-schema.md` (the same
   `tests/skill-suite/test-eval-corpus-schema.sh` structural rules: exact key sets,
   `skill_name` == stem, ≥2 evals, assertion-quality floor). A schema-invalid corpus
   stops with `BLOCKED_BAD_CORPUS: <first validation error>` — never grade against a
   corpus you could not validate.
3. Load `{skill_name, evals[]}`. Each eval carries `{id, prompt, expected_output,
   files, assertions}`.
4. On `--dry-run`: print `cases × assertions` per corpus and stop here (no dispatch).

---

## Phase 2 — Execute each eval case (executor sub-agents)

For each eval case, dispatch a **fresh** `agents/executor.md` sub-agent (no shared
context, no memory of other cases). See `env-compat.md` for the dispatch pattern. When
multi-agent dispatch is unavailable, fall back to running each case in a fresh
sub-context sequentially — the same per-case isolation + `BLOCKED_NO_ISOLATION` stop
apply; never skip cases and never run in the live checkout.

Give each executor: `skill_name`; the full text of the target skill's `SKILL.md` **read
from that executor's OWN workspace** (so a `--compare` baseline case gets the OLD text,
never the current tree's); the eval's `prompt`; its `files`; and — when the runtime
cannot auto-capture sub-agent tool calls — an explicit `ACTION_LOG=<path>` for the
executor to self-log to (executor.md "Action log"). Do **NOT** give it `expected_output`
or `assertions` — the executor must not know what it is graded on.

**Isolation (MANDATORY, fail-closed, PER-CASE).** Executors have unrestricted `Bash`, so
isolation is enforced by WHERE they run — in a fresh, fully-INDEPENDENT copy of the repo
(never a `git worktree`, which shares the parent's branch namespace + `.git/config`, so
an executor could `git branch -D`/checkout and mutate the developer's REAL repo). Each
case gets its own workspace under a single `mktemp -d` parent that an `EXIT` trap removes
(interrupts never orphan workspaces; no worktree metadata to leak), materialized by
revision then HARDENED (all four steps verified safe on an independent copy):

- **Current-version run (`TARGET_REF=HEAD`)** → copy the WORKING TREE **excluding heavy
  dep/build dirs** (`rsync -a --exclude=node_modules --exclude=.venv --exclude=dist
  --exclude=build --exclude=.next` or `cp -R` then prune) — a plain `cp -R` of a repo
  with a large `node_modules`/`.venv` would exhaust disk/inodes across `--all-evals`. A
  worktree/clone of HEAD would drop uncommitted/untracked edits, but skill-eval is run
  WHILE editing a skill — grade what is on disk.
- **Baseline run (`TARGET_REF=<ref>`, `--compare`)** → `git clone --local <root> <ws>`
  then `git -C <ws> checkout --detach <ref>` (own refs/config/branches — full namespace
  isolation; hardlinked objects, so cheap).
- **Then, in BOTH cases** (safe because the workspace `.git` is an independent copy, NOT
  shared): strip ONLY the graded corpus — `rm -f <ws>/evals/<skill>.evals.json` (NOT
  `rm -rf <ws>/evals`, which would break evaluating skill-eval itself, whose own run
  needs an `evals/` dir) so the executor cannot read the assertions it is graded on and
  cheat; and, WHEN in a git repo, remove ALL remotes
  (`for r in $(git -C <ws> remote); do git -C <ws> remote remove "$r"; done`) so a push
  cannot reach any real remote (edits only the copy's config). Strip any other file that
  would leak this skill's grading criteria.

**Materialize the eval's `fixtures` (AFTER hardening, BEFORE dispatch).** If the eval
carries a `fixtures[]` array (eval-schema.md → "Self-contained fixtures"), write each
`{path, content}` into the hardened workspace so the target the `prompt` names actually
exists on disk — without this, a corpus whose prompt references `src/services/order.service.ts`
(a file not in this repo) forces an all-`false` run that reflects a missing fixture, not
skill behavior. This step is fail-closed on path safety: for each fixture, resolve
`path` against the workspace root and **reject any `..`/absolute escape or glob
metacharacter** (`BLOCKED_BAD_FIXTURE` for that case) BEFORE writing — the executor gets
unrestricted `Bash`, but the orchestrator must never let a fixture `path` write outside the
disposable sandbox. `mkdir -p` the parent, then write `content` verbatim. Because the
workspace is already an independent copy, these writes never touch the developer's checkout:

```bash
# $WS = hardened workspace root; $FIXTURES_JSON = this eval's fixtures array (may be absent/empty)
python3 - "$WS" "$FIXTURES_JSON" <<'PY'
import json, os, sys
ws = os.path.realpath(sys.argv[1])
fixtures = json.loads(sys.argv[2] or "[]")
for k, fx in enumerate(fixtures):
    p = fx["path"]
    if os.path.isabs(p) or any(c in p for c in "*?[]"):
        sys.exit("BLOCKED_BAD_FIXTURE: fixtures[%d].path not a safe relative literal: %r" % (k, p))
    dest = os.path.realpath(os.path.join(ws, p))
    if dest != ws and not dest.startswith(ws + os.sep):
        sys.exit("BLOCKED_BAD_FIXTURE: fixtures[%d].path escapes the sandbox: %r" % (k, p))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w", encoding="utf-8") as f:
        f.write(fx["content"])
PY
```

Fresh-per-case is mandatory: if case 1 commits/mutates a file, case 2 must not inherit it
(cross-case bleed reads as a false regression). **Two distinct failure semantics, never
conflated:** if the *workspace cannot be created* (`cp`/`clone`/`checkout` fails) →
hard-stop `BLOCKED_NO_ISOLATION` (never run in the live checkout); if the executor is
provisioned but *returns non-zero / crashes* → record that case `executor-failed`,
re-dispatch once, then continue the batch.

**Capture (proven before the batch, with a REACHABLE fallback).** Write each executor's
tool-call log to a `TRANS_FILE` under `$WORK`. Phase 0.2's preflight is a real
**canary**, not prose, and it SELECTS the capture mode rather than only rejecting:
dispatch ONE throwaway executor that runs a command emitting a LARGE known payload with a
distinct marker at BOTH the START and the END (e.g. `echo CANARY_HEAD; printf 'x%.0s'
{1..5000}; echo CANARY_TAIL`). The canary passes only if the captured transcript contains
BOTH markers — a runtime that captures just the first N bytes (dropping large
`Bash`/`Write` payloads) would show `CANARY_HEAD` but not `CANARY_TAIL`, which must FAIL
the canary (reachability alone is not enough; the grader needs full tool-result
payloads). Try the runtime's auto-capture first; if either marker is missing, retry the
canary in **ACTION_LOG mode** (pass `ACTION_LOG=$TRANS_FILE`, the executor self-logs
structured records per executor.md). Only if BOTH auto-capture AND ACTION_LOG fail to
surface both markers do we hard-stop `BLOCKED_NO_TRANSCRIPT_CAPTURE`. The passing mode is
then used for every real case — so a non-auto-capture runtime DEGRADES to action-logging
instead of being unusable.

**Per-case status (never abort the batch on one bad case):** `ok`, `executor-failed`, or
(Phase 3) `grader-*` — all infra statuses carried to Phase 5, excluded from the
behavioral rate. Before its workspace is reclaimed, a NON-`ok`/failing case's raw
`TRANS_FILE` is copied to `zuvo/reports/skill-eval-<skill>-<run>-case<id>-transcript.txt`
so a developer can audit why the executor went off-track (the grader's short evidence
snippet alone is not debuggable).

**Fan-out bound.** `--all-evals` fans out over corpus × cases × 2 sub-agents — hundreds
of dispatches for 50+ skills. Process corpora **sequentially**, one fully graded before
the next; executor cases also run sequentially — the reason is bounded fan-out
(dispatch-slot / rate-limit budget), **not** filesystem racing (each case is already
isolated). In `--all-evals`, a single missing/malformed corpus is recorded as a
`skipped` corpus and the run CONTINUES (the `BLOCKED_*` halt applies only to
single-skill mode). Re-runs skip a corpus that already has a report for its OWN
deterministic key — a hash of the **evaluated bundle**: that skill's `SKILL.md` + its
`agents/*.md` + `evals/<skill>.evals.json`. It must include the skill files, not just the
corpus: a change to `skills/<skill>/SKILL.md` with an unchanged corpus is exactly what
you re-run to detect, so a corpus-only key would skip it and grade against stale results.
`KEY="<skill>-$( { git hash-object skills/<skill>/SKILL.md skills/<skill>/agents/*.md evals/<skill>.evals.json 2>/dev/null || cat skills/<skill>/SKILL.md skills/<skill>/agents/*.md evals/<skill>.evals.json 2>/dev/null | shasum -a 256; } | shasum -a 256 | cut -c1-12)"`
— `git hash-object` when available, else a `shasum` fallback so dedup also works in a
non-git checkout. Scoped per-corpus (never `git HEAD`, which invalidates all 50+ on any
unrelated commit; never a repo-wide hash, which collapses every corpus to one key).

---

## Phase 3 — Grade each transcript (grader sub-agents)

For each executor transcript, dispatch a **fresh** `agents/grader.md` sub-agent given
ONLY the filled scoring prompt — the case's `assertions` + `skill_name` + the
transcript wrapped in the random-nonce fence. The grader has no conversation history
and no tools (`tools: []`).

**Build the fenced transcript with a concrete Bash step — never "apply the regex
mentally."** Nonce generation and sanitization are string operations an LLM cannot
reliably perform on a large adversarial transcript in-context, so run them as code
(Python is a repo dependency; `install.sh`/`dev-push.sh` already rely on it):

`grader.md` ALREADY contains the fence (`<transcript-{NONCE}>{TRANSCRIPT}</transcript-{NONCE}>`),
so this step emits the `nonce` and the sanitized `transcript` **separately** as JSON —
it does NOT pre-wrap them (that would double-fence). The orchestrator parses the JSON
and substitutes `{NONCE}` and `{TRANSCRIPT}` into the template's existing fence:

```bash
# $TRANS_FILE = raw executor transcript; $SAN_FILE = output. Writes {"nonce","transcript"}
# to $SAN_FILE (a FILE, not stdout — a 120k-char JSON on stdout would be truncated by the
# orchestrator's Bash tool and break parsing). The orchestrator then READS $SAN_FILE.
python3 - "$TRANS_FILE" "$SAN_FILE" <<'PY'
import re, os, sys, json
# errors="replace" so binary/non-UTF-8 bytes (e.g. an executor cat-ing a compiled file)
# degrade gracefully instead of crashing the grader pipeline for that case.
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# (1) PER-BLOCK, CHAR-BASED truncation: cap each block by CHARACTER budget (not line
#     count) so a single giant one-line result (minified JS, base64, huge JSON) is also
#     bounded, and only that block's middle is elided — intermediate tool calls survive.
def cap(block, max_chars=16000):
    if len(block) <= max_chars: return block
    h = max_chars // 2
    return block[:h] + ("\n... [%d chars elided from this block] ...\n" % (len(block)-2*h)) + block[-h:]
# split on turn markers (keep them). Per-block capping ONLY when we actually recognized
# blocks (len>1); if the runtime uses a different marker format, parts==1 and per-block
# 16k capping would gut the whole run — so in that case we skip it and let ONLY the
# generous whole-transcript ceiling bound it head+tail.
parts = re.split(r'(?m)^(?=\[(?:assistant|tool_call|tool_result)\])', text)
if len(parts) > 1:
    text = "".join(cap(p) for p in parts)
text = cap(text, max_chars=120000)   # whole-transcript ceiling (format-agnostic backstop)
# (2) neutralize closing-fence lookalikes (case/ws/unclosed-tolerant) — eval-schema.md
text = re.sub(r'(?is)<\s*/\s*transcript[^>]*(?:>|$)', '<\\/transcript>', text)
# (3) unguessable per-run nonce (16 hex chars) — written SEPARATELY, not pre-wrapped
open(sys.argv[2], "w", encoding="utf-8").write(json.dumps({"nonce": os.urandom(8).hex(), "transcript": text}))
PY
```

Read `$SAN_FILE`, parse its JSON, then substitute its `nonce` into every `{NONCE}` and its `transcript`
into the single `{TRANSCRIPT}` in `grader.md`'s scoring prompt. Do NOT hand-craft the
fence in prose, and do NOT wrap the transcript twice. **If the sanitizer itself fails**
(no `$TRANS_FILE`, non-zero exit, or non-JSON output), record that case
`executor-failed` (an infra status) and continue — never abort the batch on one
sanitizer failure. (Authority for the sanitization + nonce rules: `eval-schema.md`
§"Transcript injection hardening".)

**Grader output + failure taxonomy.** The grader returns a JSON array — one object per
assertion, in input order: `{"text", "passed", "evidence"}`. When parsing, **tolerate a
markdown code fence** (LLMs often wrap bare JSON in ```json … ``` despite the
instruction) — strip a leading/trailing fence or extract the outermost `[ … ]` before
`json.loads`; only genuinely non-array output is malformed.

Pair objects to assertions **by position** (position is authoritative — the grader is
instructed to return verdicts in input order), and **cross-check for reordering
leniently**: compare each object's `text` to input assertion *i* under a NORMALIZED match
(collapse whitespace, ignore quote-escaping differences) OR a leading-prefix match — LLMs
echo long strings imperfectly, so a minor variance must NOT reject the run. Only a GROSS
mismatch (the position-*i* text clearly corresponds to a DIFFERENT assertion) flags a
reorder → `grader-malformed`. This catches genuine mis-pairing without false-malforming
on trivial echo drift. Record one status per case, never a silent drop:

- `graded` — a well-formed array of the right length whose `text` fields align by
  position with the input assertions.
- `grader-malformed` — length mismatch, positional `text` mismatch (reorder), or
  non-JSON even after fence-stripping. Re-dispatch **once**; if still malformed, record
  `grader-malformed` (do not guess verdicts).
- `grader-dispatch-failed` — the grader sub-agent never returned (dispatch error /
  timeout). Re-dispatch once, then record the failure.

`grader-malformed`, `grader-dispatch-failed`, and Phase 2's `executor-failed` are all
INFRA failures — carried into the report and accounted per Phase 5 (excluded from the
behavioral pass rate, reported separately) — they are findings, not omissions.

---

## Phase 4 — Comparison mode (`--compare <ref>`)

Materialize the OLD skill version and score it the same way, then diff the pass rates.
Two DISTINCT, both-reachable failure guards decide up front whether the comparison can
run — set `SKIP_COMPARE` and never fall through to the materialization on a guard hit
(a fall-through would write a zero-byte baseline and diff against a phantom run):

```bash
SKIP_COMPARE=""
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "GUARD_NO_GIT: skill-eval --compare needs a git repository here; grading the current version only, no old-vs-new diff"; SKIP_COMPARE=1
elif ! git cat-file -e "$ref:skills/$skill/SKILL.md" 2>/dev/null; then
  echo "GUARD_BAD_REF: skill-eval --compare could not read <ref>:skills/$skill/SKILL.md via git (bad ref, or the skill did not exist there); skipping the comparison, grading the current version only"; SKIP_COMPARE=1
fi
```

`GUARD_NO_GIT` is reachable because Phase 0.2 does not hard-require git; `GUARD_BAD_REF`
covers a bad ref OR a skill absent at that ref. Only when `SKIP_COMPARE` is empty do we
run the baseline — and it materializes the **complete** old bundle (not just `SKILL.md`:
behavior often lives in `agents/*.md` and relative `../../shared/includes/…` paths). This
is why the baseline reuses Phase 2's `new_workspace` with `TARGET_REF="$ref"`: each
baseline case is a `git clone --local` checked out at `<ref>`, so the WHOLE old tree
(SKILL.md + its agents + includes) resolves at natural depth — no separate worktree, no
`$BASE` path to collide across skills in `--all-evals`. `$RUN_ID` is computed ONCE at
Phase 1 (a single Bash call — not `$$`, which differs per orchestrator tool-call) and
reused for the baseline snapshot AND the Phase 5 report so filenames stay in lockstep:

```bash
if [ -z "$SKIP_COMPARE" ]; then
  mkdir -p zuvo/context                         # the redirect below fails if the dir is absent
  git archive "$ref" -- "skills/$skill" | tar -xO > "zuvo/context/skill-eval-baseline-$skill-$RUN_ID.txt" 2>/dev/null \
    || git show "$ref:skills/$skill/SKILL.md" > "zuvo/context/skill-eval-baseline-$skill-$RUN_ID.txt"  # whole OLD skill dir (SKILL.md + agents) as the audit record; SKILL.md-only fallback
  TARGET_REF="$ref"                             # re-run Phases 2-3: new_workspace clones+checks out $ref per case
  #   ... run the baseline pass ...            # (OLD SKILL.md + OLD agents graded from the clone at natural depth)
  TARGET_REF="HEAD"                             # restore for any subsequent current-version work
fi
```

If the clone/checkout of `<ref>` fails during the baseline pass (transient FS/permission,
unavailable object), that is a `BLOCKED_NO_ISOLATION` for the baseline case per Phase 2 —
recorded and the current-version run still completes; the comparison degrades to
"baseline unavailable", never a crash.

**Hold the measuring stick constant.** Both the old and new runs are graded against the
**current** `evals/<skill>.evals.json` corpus AND with skill-eval's OWN current
`executor.md`/`grader.md` — deliberately. Loading the OLD corpus (or old eval agents)
for the baseline would confound a change in the SKILL with a change in the CASES or the
grader, making the delta uninterpretable. The comparison answers exactly one question:
"does today's skill do better than the old skill on today's fixed benchmark?" So only
the target skill's own `SKILL.md`+agents differ between the two runs; everything else is
held at HEAD. Report `old <pass-rate> → new <pass-rate>` per assertion and overall; the
run-suffixed `zuvo/context/skill-eval-baseline-<skill>-<run>.md` snapshot records exactly
what was compared (a fixed path would let parallel/retried runs clobber the audit
record).

---

## Phase 5 — Report

**Pass-rate accounting (fixed + honest about the SOURCE of failure).** The behavioral
pass rate measures the SKILL, so it must not be polluted by evaluator infra failures:

- The **behavioral pass rate** = `passed-assertions / assertions-in-GRADED-cases`.
  Only `graded` cases are in the denominator — a skill evaluated during a rate-limit
  storm must NOT report a false regression because the GRADER timed out.
- **Infra failures** (`executor-failed`, `grader-dispatch-failed`, `grader-malformed`)
  are **excluded from that denominator** and reported SEPARATELY in a prominent
  "not graded (infra)" tally with counts per kind — never silently dropped, and never
  folded into the behavioral number.
- **Trustworthiness gate:** if not-graded cases exceed a threshold (default: >25% of
  cases, or ANY case in a corpus with <4 cases), the report headline is
  `RESULT: INCONCLUSIVE (<n>/<total> cases not graded — infra)`, not a pass rate — a
  10% behavioral rate computed from 1 of 10 graded cases is noise, and labelling it a
  regression would be dishonest.

Write to the canonical output dir (`report-output-location.md`) under `zuvo/reports/`,
using the SAME `$RUN_ID` computed once at Phase 1 (`<YYYYMMDD-HHMMSS>-<rand>` — one Bash
call, reused everywhere; NOT `$$`, which differs per orchestrator tool-call and would
desync the report filename from the Phase 4 baseline snapshot):

- `zuvo/reports/skill-eval-<skill>-<RUN_ID>.md` — human-facing: per-eval, per-assertion
  pass/fail + verbatim evidence, headline pass rate, the "not graded" list, and (with
  `--compare`) the old-vs-new diff.
- `zuvo/reports/skill-eval-<skill>-<RUN_ID>.json` — machine record: the graders' raw
  per-assertion arrays + run metadata (refs, nonce-fenced=true, per-case executor +
  grader status).

Print a `SKILL-EVAL COMPLETE` block: skill, cases, behavioral pass rate (or
`INCONCLUSIVE` per the trustworthiness gate), the not-graded (infra) tally by kind,
failing assertions (with the missing tool-call/artifact the grader named), and the
report paths. **For `--all-evals`, add an aggregate headline**: if more than 10% of
corpora came back `INCONCLUSIVE`, print `AGGREGATE: INCONCLUSIVE (<k>/<N> corpora not
trustworthy)` instead of a suite pass rate — one flaky-infra corpus must not be averaged
into a clean-looking suite number. Then append the run log via
`../../shared/includes/run-logger.md`.

---

## Notes

- **No approval gates.** Execute end-to-end; only `--dry-run` gates output.
- **Honest degradation.** Missing corpus / bad schema / non-git repo each stop or
  degrade with their OWN message — never a generic "failed". A grader that returns
  malformed JSON is a recorded finding, not a silently-dropped case.
- **Not a quality gate substitute.** skill-eval measures skill *behavior* against a
  corpus; it does not replace `zuvo:review` on production code.

## Known limitations (fail-closed, runtime-validated)

skill-eval depends on two runtime-specific mechanisms it cannot prove abstractly, so it
is designed to **fail closed** — block or degrade with a named status, never silently
produce a wrong result:

- **Transcript capture** varies by runtime (auto-captured sub-agent log vs. executor
  `ACTION_LOG`). The Phase 2 **canary** empirically selects a working mode before the
  batch and hard-stops `BLOCKED_NO_TRANSCRIPT_CAPTURE` if none works — so a run either
  grades on real captured tool calls or does not run.
- **Push prevention** is enforced by removing ALL remotes from each isolated workspace's
  OWN (copied/cloned, never shared) git config plus executor rule 3; a target skill's
  push step then fails harmlessly inside the sandbox. This is mechanical for the common
  case; a skill that re-adds a remote and pushes is out of scope.
- **Network isolation is NOT provided.** The executor has unrestricted `Bash`, so an
  instruction alone cannot stop a target skill's `curl`/API call from hitting a real
  endpoint — skill-eval is a behavioral evaluator, not a security sandbox. Skills with
  network-MUTATING steps (deploy webhooks, external writes) should be run under OS-level
  network isolation (`unshare -rn`, a container, or an offline box), or their
  network-mutating cases excluded from the corpus. This is stated, not silently assumed.

These are validated per-runtime by the canary + the isolation steps, not assumed. The
first real-repo use of `--compare` and of a non-auto-capture runtime should be smoke-run
once to confirm the selected paths behave as specified.
