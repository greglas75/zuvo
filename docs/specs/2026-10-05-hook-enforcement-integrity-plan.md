# Implementation Plan: Hook enforcement integrity (hooks backlog, plan A of 2)

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (`zuvo/context/hooks-backlog-input.md`; user 2026-10-05 "lec z backlogiem dotyczacym hookow")
**plan_revision:** 4
**status:** Approved
**Created:** 2026-10-05
**Tasks:** 11. This is above the 5–10 target, because the exit-code premise gets its own spike (T1).
**Estimated complexity:** 9 complex (T1, T2, T4, T5, T6, T7, T8, T10, T11) · 2 standard
**Execution host:** run on ryzen-old-1, where the gitignored inputs live. RED cases come from the QA report on this host and become committed test cases/fixtures in each RED step. The analysis reports (`zuvo/context/hooks-backlog-{architect,techlead,qa}.md`, a file:line map and design notes) are context only, not needed to run.

**Scope split (rule 17).** This is plan A of two PRs.
- **Plan A** makes the blocking hooks enforce what they claim.
- **Plan B**, written after A lands, covers TRACK-INCLUDES-TMP, REWAKE-ATOMIC, INSTALL-HOOKS-CP-IN-PLACE (plus the git shim writing through a symlink), and the post-skill misfire.

**Already implemented (rule 18; closed in T11).**
- B-prepush-gate-merge-commit-range was fixed in 32bee854. Its residue is handled in T7.
- B-blocknoverify-fmt was fixed in 1d779490.
- The flag-less `npm view … version` and `npm install -g` shapes already return rc 0.

**Canonical commands.** The installed guard refuses `|`, `;`, `&`, `2>&1` and `$(` inside an opted-out command, so every Verify is a bare command whose rc is the verdict.
- `LOCALRUN <suite>` = `TF_ALLOW_LOCAL=1 bash tests/hooks/<suite>.sh`.
- `B32RUN <suite>` = `TF_ALLOW_LOCAL=1 PATH=$PWD/zuvo/context/bash32/inst/bin:$PATH $PWD/zuvo/context/bash32/inst/bin/bash tests/hooks/<suite>.sh`.
  - The path is absolute and the binary is explicit, so a missing build exits 127. If it is missing, run `TF_ALLOW_LOCAL=1 bash tests/lib/build-bash32.sh` first.
  - The binary is bash 3.2.57, the macOS `/bin/bash`.
- Suite summaries end in `ALL PASS`, except test-noverify-alias and test-noverify-content-binding, which end in `PASS=<n> FAIL=0`.
- Line numbers in this plan are taken at 1f19e158. Each is paired with a function or marker name, and later tasks locate code by that name.

## Architecture Summary

A PreToolUse hook blocks **only with exit 2** on Claude Code, Codex and Kimi (vendor docs). Any other non-zero exit is a non-blocking error. Defects, as of 1f19e158:

- **Farm guard.**
  - The quote-blind substitution scan (`:151-153`) runs before the heredoc strip (`:154`) and before the `rt` skip (`:255`).
  - `nested_has_suite` matches its words anywhere in the command (`:124-134`).
  - Any flag makes a command count as ambiguous (`:401`, `:414`).
  - A `-c` string is treated as a script path (`:342`).
  - The heredoc strip ignores quoting and comments, which is a live bypass.
- **Pre-push gate.**
  - The fast path (`:30-33`) and `gate_legacy` (`:140-198`) do a literal match over the whole payload, including the description.
  - `gate_legacy` returns 1.
  - The lib is sourced at `:37`, before `looks_native` (`:201`).
- **Commit gate** (PreToolUse only): same literal predicate, and it exits 1 at `:308`.
- **Gate lib:** `pg_is_production` has no `*.jsonl` rule (`:106`).
- **block-no-verify.**
  - When xargs aborts on a quoted newline or a commented quote, it leaves a partial token list, so the fail-closed branch (`:456-465`) never fires.
  - `\`+newline produces an empty token.
  - `cfg_end` ignores newlines.
  - `git` is matched case-sensitively.
  - `eval` arguments are never re-joined.
- **Wiring.**
  - `claude-home.sh:81-94` writes one value and dies with rc 5 on a multi-valued key.
  - Nothing detects a multi-valued key at session start.
  - None of the 51 agent prompts carries a git-config safety line.

## Technical Decisions

1. **Farm guard: lexer plus recursive analyzer** (Tech Lead §1).
   - Substitutions are live in NORMAL state, in double-quoted state, and in unquoted heredoc bodies.
   - A heredoc whose delimiter is quoted (`'EOF'`, `"EOF"`, `\EOF`, `E"OF"`) is data.
   - The analyzer recurses into substitutions, shell-consumed heredocs, `-c`, `<<<`, `eval`, `source`, `{ }`, `xargs`, `find -exec`, `watch`, `caffeinate`, `stdbuf` and `env -S`.
   - Depth is capped at 4. If parsing is incomplete (`!ok`) or **any** exception is raised, fall back to the legacy path.
2. **Ambiguity.** Only an unknown option placed *before* the deciding word makes a command ambiguous. An ambiguous command is blocked if any later token is a suite verb.
   - Added verbs: `tst it cit install-test install-ci-test clean-install-test`.
   - The opt-out applies per segment. Substitutions are still analyzed.
3. **Gate predicate, in two stages.**
   - Stage A is inline and makes no forks.
   - Stage B is `hooks/lib/git-verb-match.sh`:
     - `gvm_command <payload>`: non-JSON input is the command itself; JSON goes through jq, then python3; returns 3 when neither is available.
     - `gvm_match <cmd> <verb>`: prints `hit`, `hit adhoc` or nothing. Compound commands are checked per verb.
   - Precision comes from removing data contexts, not from anchoring the command head, so all 31 wrapper forms in QA §T3 still engage.
   - Order:
     1. `looks_native` runs first.
     2. A missing lib, or rc 3, falls back to the literal predicate.
     3. The stage-B verdict replaces `gate_legacy`'s literal check.
     4. Stage B decides **before** `pipeline-gate-lib.sh` is sourced.
4. **Exit contract** (premise checked by T1).
   - PreToolUse mode: the hook *process* exits 2.
   - Native mode keeps 1, and the git dispatcher maps any non-zero to 1. The native path is untouched.
   - The pre-push runs.log fallback becomes advisory (exit 0 plus a WARNING).
   - **ADHOC parity:** `ZUVO_ALLOW_ADHOC=1` on the matching segment, or set by an earlier `export`, is honoured and logged. This is no policy change; the owner decision is recorded in T11.
5. `*.jsonl` joins the `*.json` arm. These files are agent-appended data, and `*.md` is already exempt. The CI gate inherits the change.
6. **block-no-verify.** The awk END loop carries quote state across lines:
   - a newline inside a quote becomes a space;
   - an odd trailing `\` outside quotes joins the next line;
   - any other newline becomes ` ; `;
   - a quote character after a word-start `#` is ignored.

   Also:
   - A sentinel `__BNV_OK__` after xargs; if it is missing, run the fail-closed check on `CMD`.
   - Match `git` lowercased.
   - Re-join and re-scan `eval` arguments.
7. **Isolation.** One ASCII sentence that starts with the marker `Git safety (mandatory):` and contains `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1`.
   - Source of truth: `env-compat.md` §Agent Dispatch.
   - It is carried as preamble Core Constraint 6, plus the same line in each of the 24 agent prompts without the preamble.
   - It applies to throwaway repos only.
8. **Detector.** `hooks/session-start` runs one `git config --global --type=path --get-all core.hooksPath` per session. If there is more than one value, or the last value is not a directory, it adds a warning to `additionalContext`.
   - The installer repairs it: `--get-all`, warn, `--replace-all`.
   - Every installer write is wrapped in `if !`.

## Quality Strategy

- **Harness.** Suites use `pass`/`bad` and end with a summary and rc 0.
  - Hook suites run locally (`docs/runbook/testing.md` §5) and under B32RUN.
  - `run-all` runs via `rt --light`; bats via `npx --yes bats@1.11.0`.
- **Payloads** use the real shape (`session_id`, `cwd`, `hook_event_name`, `tool_name`, `tool_input.command` and `tool_input.description`), plus one legacy-shape case and one raw-stdin case.
- **Blocks.**
  - PreToolUse: `rc == 2`. Native: `rc == 1`.
  - Farm guard: `rc == 2` **and** a `BLOCKED: '` line.
  - Never assert `-ne 0`.
- **C1/C4 evidence** (cited by every task proof). The task report records:
  - (i) the RED run, failing at the task's base commit;
  - (ii) `grep -c 'GIT_CONFIG_GLOBAL=' <suite>` ≥ 1 for each touched suite, plus a sandbox `ZUVO_HOME` (writing suites use a sandbox gitconfig file);
  - (iii) the pass count before and after (`^PASS:` lines; for test-noverify-alias and test-noverify-content-binding the `PASS=<n>` counter), with after ≥ before + the number of new RED cases. Numbers are written down.
- **Traps.**
  - Build `\u` with `printf '\134'` and assert the plain word is absent.
  - Give refusals a positive control.
  - Stub dirs must contain `lib/git-verb-match.sh` (asserted).
  - Guards assert checked == expected > 0.
- **In-suite exec counts** (PATH-logging wrappers):
  - farm guard `ls` ≤ 3;
  - pre-push `ls` = 1;
  - commit gate `git status` = 1;
  - block-no-verify `ls` = 1.
- **xargs/awk matrix.** `test-block-no-verify.sh` builds a shim dir in mktemp (xargs → `busybox xargs`, awk → `mawk`), asserts `command -v xargs` resolves there, and re-runs the multi-line, continuation and comment cases. If busybox or mawk is missing (a stock Mac), it prints a visible `SKIP: xargs/awk matrix` line.
- **Shared fixture** `tests/hooks/fixtures/git-verb-cases.tsv`:
  - Columns: `id<TAB>enc_cmd<TAB>push<TAB>commit<TAB>bnv`.
  - `enc_cmd` is `printf '%b'`-encoded and decoded with `printf -v` (works on bash 3.2.57).
  - `push` and `commit` take `hit`, `adhoc` or `-`.
  - `bnv` is the expected rc after appending ` --no-verify`: 2, 0, `R` (residue) or `-` (not yet set). T4 writes `-`; T5 fills it.
  - Consumers assert decoded rows == expected count > 0.
- **Verdict corpus,** `tests/lib/hook-verdict-corpus.py` (T2). It runs hooks with a sandbox `ZUVO_HOME`.
  - **Frozen sample.** T2 writes `zuvo/context/corpus-sample.jsonl` once with `--sample-out` (up to 3000 Bash commands from `~/.claude/projects/*/*.jsonl`). Every later run uses `--sample-in`.
  - **Hook directory.** The tool copies the directory that contains `<hook-path>`.
  - **Modes.**
    - `--mode exit`: rc and verdict.
    - `--mode sourced-marker <lib>`: replaces that lib with an `exit 7` stub. This measures **engagement only**; the gate verdicts themselves are covered by the suites.
  - **Rows** are unique per `sha256(cmd)[:12]`.
  - **Shapes.** `--show <sha>…` prints commands to the terminal only. `--diff` also takes `--sample-in` to map each sha to its command for check (c).
  - **`--diff base after --report <md> --section <hook> --shapes tests/hooks/fixtures/corpus-shapes-<hook>.txt`** exits 0 only when all of these hold:
    - (a) both sha sets are equal;
    - (b) {base rc 0, after rc non-0} equals the section's `NEWBLOCK <sha> <case-id>` lines, and {base non-0, after 0} equals its `UNBLOCK <sha> <case-id>` lines;
    - (c) every listed sha's command matches the regex of its `case-id` in the shapes file.

    The shapes file is authored in the task's RED step, before GREEN, so the check is not circular.
  - **Baseline at 1f19e158:** farm 37/3000, block-no-verify 8/3000, pre-push 20/3000.
- **File limits.**
  - `git-verb-match.sh` is a lexer state machine and gets an exception up to ≤ 160 lines. Above that, split it into segmenter and matcher.
  - The farm guard grows further; HOOK-FILES-CQ11 is deferred, and T11 annotates it.
- **CQ gates.**
  - CQ3: fail closed on unparsed input.
  - CQ4: ADHOC applies to its own segment only.
  - CQ6: depth cap, and a 17 KB python-path payload in ≤ 2 s.
  - CQ8: no exception reaches `exit 0`.
  - CQ14: one shared fixture.
  - CQ19: exact exit codes; JSON is parsed, not grepped.
  - CQ22: reap children and orphans.
- **Risk ranking:** T2 > T5 > T6 > T4 > T7 > T8 > T10 > T3 > T9 > T1 > T11. zuvo:execute orders by Dependencies, not by number: dependency-free T1, T2 and T10 can run in the first batch; block-no-verify (T5) and the installer (T8) each run right after their dependencies.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G1 | Farm false positives: B-20261005-FARM-GUARD-FALSE-POSITIVES, -FARM-GUARD-TESTS-SH-FP, -FARM-HOOK-HEREDOC-FP, -FARM-HOOK-FALSE-POSITIVES (open shapes), and the `-c` bug | requirement | T2, T3 | |
| G2 | B-20261005-FARM-HOOK-HOOK-SUITES | requirement | T3 | |
| G3 | Farm bypasses must block: heredoc strip, the wrapper forms, `npm it/tst/cit/install-test` | requirement | T2, T3 | new entry |
| G4 | B-20260929-PREPUSH-FASTPATH-SUBSTRING | requirement | T4 | |
| G5 | PreToolUse gates really block (exit 2), with ADHOC parity | requirement | T1, T6, T7 | new entry |
| G6 | Merge-range residue: topology suite (TOPO1–4, including non-zero rsha with a merge) in run-all; no-remote fail-open | requirement | T7 | entry fixed in 32bee854 |
| G7 | B-20261005-GATE-KNOWLEDGE-JSONL, -GATE-ENGINE-ODD-FILENAMES | requirement | T9 | |
| G8 | B-20261005-BNV-MULTILINE-OVERBLOCK, the fail-opens, -BNV-EXPANSION-RESIDUE | requirement | T5 | new entry for the fail-opens |
| G9 | B-20261005-SUBAGENT-GIT-ISOLATION: carriers and guard | requirement | T10 | |
| G10 | Broken global hooksPath is detected; the installer survives and repairs it | requirement | T8 | completes G9 |
| G11 | Dispositions, out-of-fence records, plan B notes, no new run-all reds | deliverable | T11 | |
| C1 | RED test first | constraint | T2–T10 | C1/C4 evidence |
| C2 | Proven supersets; no new forks on the common path | constraint | T2, T4, T5, T6 | exec counts; T6 iterates the fixture |
| C3 | bash 3.2 compatible | constraint | T1–T10 | B32RUN |
| C4 | Test isolation | constraint | T2–T10 | C1/C4 evidence |
| S1 | Out of scope, with reasons: plan B items; reviewed-blob-legacy-window (owner policy); HOOK-FILES-CQ11 (zuvo:refactor); DOUBLE-GATE-PER-PUSH (revisit after exit 2); UNREVIEWED-LANDINGS (zuvo:review); CodeSift items | scope boundary | T11 | annotated |

## Review Trail
- Phase 1: full fan-out on Opus, sequential (Architect → Tech Lead → QA).
- Plan reviewer: rev 1 found 12 issues, rev 2 found 9, and rev 3 found 5 plus 6 nits. All are addressed in rev 4:
  - the corpus gets a frozen sample, a shapes check and per-hook sections;
  - the baseline runs from a detached worktree;
  - SMOKE2 seeds two values, and the flag is in T11;
  - T6 iterates the fixture;
  - `claude -p` runs with `--tools Bash`, (c) is one-shot, and a single push payload is asserted;
  - the nits are resolved inline.
  - The 3-iteration cap is reached; rev 4 receives the one adversarial-driven re-review.
- Cross-model pass 1 (rev 2; 5 providers): CRITICAL "T7 late" was fixed by reordering. Warnings were fixed or rejected; details in rev 3.
- Cross-model pass 2 (rev 3; codex-5.3, byteplus, byteplus-3, qwen; partial; 0 timeouts; not truncated):
  - **CRITICAL, fixed:** the SMOKE2 flag had no author. The dispatch smoke is now committed as `tests/hooks/smoke-dispatch-install.sh` (written in T7), and T11 adds the flag.
  - **CRITICAL, fixed:** T10 was scheduled late. It is now T8.
  - **CRITICAL, clarified:** sourced-marker measures engagement only.
  - **CRITICAL, partly accepted:** the inputs are host-local. Execution host is pinned; RED cases are transcribed into committed suites/fixtures during RED.
  - **WARNING, fixed:** corpus nondeterminism and circularity; T7 rc-2 vs dispatcher wording; PASS-count deltas; the bnv column belongs to T5; T11 is now complex; the canonical binary is checked in T1; an engine-filename test; a concrete orphan assertion; per-case logs; T10 runs under B32RUN.
  - **Rejected:** a lexer spike (the 3000-command corpus validates T2); a monitoring task (local hooks); moving the no-remote fix earlier (it depends on nothing else).
- Cross-model pass 3 (rev 4; cursor-agent, byteplus, byteplus-3, claude; partial; 0 timeouts; not truncated). CRITICAL hardcoded /Users paths in T1: a false positive on this host (the repo lives at that path) but fixed inline to `$REPO`-relative. CRITICAL dependency-free T10 scheduled late: fixed inline by correcting the schedule claim (execute orders by Dependencies; T10 runs in the first batch). WARNINGs fixed inline: T1 retry before HALT, explicit default-prefix build, T1 reclassified complex, T7 Verify runs test-hook-fast-paths, G9 cited on T8, RED-case provenance wording. Rejected, consistent with passes 1-2: gvm/lexer spikes (fixture + corpus validate in-task), monitoring tasks (local hooks), T3 split (3 files + a fixture). Stop rule applied: no further loop.
- Plan reviewer re-review (rev 4, the one adversarial-driven re-review): 2 issues in T11 Verify — rt summary mode hid PASS lines (fixed: `rt --full`, PASS-line regex) and a vacuous farm-only allowlist (fixed: always created, name-format check, local re-run script) — plus 7 nits, all fixed inline. Converged; no further loop.
- Status gate: Approved 2026-10-05 — reviewer converged (4 iterations incl. the adversarial-driven re-review), 3 cross-model passes with every CRITICAL fixed or dispositioned; approved under the owner's standing no-approval-gates preference plus the explicit go-ahead "lec z backlogiem dotyczacym hookow".

## Task Breakdown

### Task 1: Spike — prove the PreToolUse exit contract; record the bash 3.2 recipe and the run-all baseline
**Files:** tests/hooks/smoke-claude-pretooluse-contract.sh (new), tests/lib/build-bash32.sh (new)
**Surface:** integration
**Complexity:** complex
**Dependencies:** none
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: none (spike). The probe is the test.
  - If exit 1 lets the command run and exit 2 stops it, print `[DECISION: exit-contract] → COMPLETE`. On any failed assert, re-run that case once (log which assert failed); HALT only if it fails twice.
  - Otherwise print `→ HALT`, which stops the plan before T6 and T7.
- [ ] GREEN:
  - **Smoke cases (a) and (b).**
    - Setup: a scratch non-repo dir `<W>`, a sandbox `ZUVO_HOME`, and a per-case hook that appends `rc<TAB>payload` to `<W>/hook-<rc>.log` and exits 1 or 2.
    - Run `claude -p "Use the Bash tool to run exactly: touch <W>/ran. Do not create the file any other way." --setting-sources project --settings <W>/<cfg>.json --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools Bash --allowedTools Bash --model haiku --max-turns 3 --permission-mode bypassPermissions --no-session-persistence`.
    - Assert:
      - each log contains `touch <W>/ran`;
      - `<W>/ran` exists after exit 1 and is absent after exit 2;
      - `ps -eo ppid=,args= | awk -v w="<W>" '$1==1 && /claude -p/ && index($0,w)' | wc -l` is 0 (scoped to this run's `<W>`/sandbox path; the host is shared).
    - CLI: `--cases ab|cd|all`. Unknown arguments exit 64.
  - **`build-bash32.sh [prefix]`** (default `zuvo/context/bash32/inst`):
    1. Fetch byacc-20260126 (`https://invisible-island.net/archives/byacc/byacc-20260126.tgz`, sha256 `b618c5fb44c2f5f048843db90f7d1b24f78f47b07913c8c7ba8c942d3eb24b00`).
    2. Fetch bash-3.2.57 (`https://ftp.gnu.org/gnu/bash/bash-3.2.57.tar.gz`, sha256 `3fa9daf85ebf35068f090ce51283ddeeb3c75eb5bc70b1a4a7cb05868bfe06a4`).
    3. Check both with `sha256sum -c`.
    4. Build byacc into `<prefix>/../tools`.
    5. `rm y.tab.c y.tab.h` and regenerate them with byacc.
    6. `CFLAGS="-O2 -std=gnu89 -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types -fcommon" YACC="yacc -d" ./configure --without-bash-malloc`, then `make install`.
    7. Exit non-zero unless the result is `3.2.57(2)-release`. When offline, exit 0 and print `SKIP: offline`.
  - **Baseline.**
    - `git worktree add --detach "$REPO/../zuvo-plugin-worktrees/base-1f19e158" 1f19e158` (`REPO` = the main repo root, captured before any `cd`).
    - In that worktree, `rt --prepare`, then `rt --full --light bash tests/run-all.sh > "$REPO/zuvo/context/runall-base.log"` (`--full`: rt summarises redirected output and would drop PASS lines).
    - Then `git worktree remove` it. Steps go in a scratch script run with `TF_ALLOW_LOCAL=1 bash …`.
- [ ] Verify:
  - `TF_ALLOW_LOCAL=1 bash tests/hooks/smoke-claude-pretooluse-contract.sh --cases ab`
  - `zuvo/context/bash32/inst/bin/bash -c 'test "$BASH_VERSION" = "3.2.57(2)-release"'`
  - `TF_ALLOW_LOCAL=1 bash tests/lib/build-bash32.sh` (default prefix; exits 0 without rebuilding when the binary there already reports 3.2.57)
  - `TF_ALLOW_LOCAL=1 bash tests/lib/build-bash32.sh zuvo/context/bash32-verify/inst`

  Expected:
  - the smoke exits 0 and prints `[DECISION: exit-contract] → COMPLETE`;
  - the canonical binary prints `3.2.57(2)-release`;
  - the rebuild exits 0 (the version, or `SKIP: offline`).
- [ ] Acceptance Proof:
  - G5 premise / C3
    - Surface: integration
    - Proof: the Verify commands plus `test -s zuvo/context/runall-base.log`.
    - Expected: rc 0 for all.
    - Artifact: `zuvo/proofs/task-1-report.md`
- [ ] Commit: `test(hooks): prove on a real host that only exit 2 blocks a PreToolUse call, and record how to build bash 3.2 for compatibility runs`

### Task 2: Farm guard — lexer, recursive analyzer, `-c` fix, wrappers, self-exemption, corpus tool
**Files:** hooks/farm-no-local-tests.sh, tests/hooks/test-farm-guard-vendored.sh, tests/lib/hook-verdict-corpus.py (new); fixture `tests/hooks/fixtures/corpus-shapes-farm.txt` (new, not counted)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** none
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED. In `test-farm-guard-vendored.sh`, `probe … block` asserts rc 2 plus `BLOCKED: '`. The suite exports a sandbox `GIT_CONFIG_GLOBAL` and `ZUVO_HOME`. Each case has an id (F-A1…, F-B1…); the full lists are in QA §T1.
  - **Allow:**
    - `rt --full --light bash -c 'out=$(… -m pytest …)…'`
    - quoted heredocs (`'EOF'`, `"EOF"`, `\EOF`) carrying `$(npx vitest run)`
    - JS-template heredoc
    - backtick commit message
    - `git commit -m "$(cat <<'EOF' … npx vitest … EOF )"`
    - `echo "\$(npx vitest run)"`
    - both TESTS-SH-FP shapes
    - `bash -c 'echo go to the build dir'`
    - `bash -c 'cat scripts/check.sh | wc -l'`
  - **Block:**
    - `{ pytest; }`
    - `ls tests | xargs pytest`
    - `find . -name 'test_*.py' -exec pytest {} +`
    - `watch -n 5 npm test`
    - `caffeinate -i npx vitest run`
    - `stdbuf -oL pytest`
    - `env -S 'npx vitest run'`
    - `echo "<<'EOF'"; npx vitest run⏎EOF`
    - `# <<'EOF'⏎npx vitest run⏎EOF`
  - **Must not regress** (all of QA §T1):
    - the three invariants;
    - an apostrophe in an unquoted body;
    - shell-consumed heredocs, nested shells, terminators;
    - `bash tests/farm-no-local-tests.sh` stays blocked;
    - REG7 and REG8.
  - **Timing:** a 17 KB python-path payload in ≤ 2 s.
  - **Execs:** `ls` ≤ 3.
  - **`corpus-shapes-farm.txt`:** one `case-id<TAB>regex` line per intended allow or block shape.
- [ ] GREEN:
  - `lex()` and `analyze()` per Decision 1, replacing the scan before the heredoc strip.
  - `walk()` calls `analyze()` at the `-c`, `<<<`, and `eval`/`source` sites.
  - The `-c` target is `rest[_flag_limit]`, and the bash-target rule is skipped under `-c`.
  - Wrappers: `xargs` value options are `-I -n -P -L -s -d -E -a`; `find` covers `-exec`, `-execdir` and `-ok`, terminated by `;` or `+`.
  - Self-exemption matches the basename only.
  - On try/except failure, take the legacy path.
  - No literal `'` in the python source.
  - The bash prefilter is unchanged, so the `_fw` superset check still holds.
  - The corpus tool follows Quality Strategy (≤ 160 lines) and writes the frozen sample.
- [ ] Verify: `LOCALRUN test-farm-guard-vendored` and `B32RUN test-farm-guard-vendored`
  Expected: rc 0, `ALL PASS`.
- [ ] Acceptance Proof:
  - G1/G3/C1–C4
    - Surface: backend-logic
    - Proof:
      1. `mkdir -p zuvo/context/base`, then extract `git archive 1f19e158 hooks` into it.
      2. Run the corpus on `zuvo/context/base/hooks/farm-no-local-tests.sh` with `--sample-out zuvo/context/corpus-sample.jsonl --mode exit --payload farm --out zuvo/context/farm-base.tsv`.
      3. Run it again with `--sample-in` on `hooks/farm-no-local-tests.sh`, writing `farm-after.tsv`.
      4. `--diff zuvo/context/farm-base.tsv zuvo/context/farm-after.tsv --report zuvo/proofs/task-2-report.md --section farm --shapes tests/hooks/fixtures/corpus-shapes-farm.txt`.
      5. Record the C1/C4 evidence.
    - Expected: `--diff` exits 0.
    - Artifact: `zuvo/proofs/task-2-report.md`
- [ ] Commit: `fix(farm-guard): lex quotes and heredocs before scanning and recurse into nested shells — data stops being refused and wrappers stop slipping runners past it`

### Task 3: Farm guard — ambiguity rule, suite verbs, per-segment opt-out, hook-suite hint
**Files:** hooks/farm-no-local-tests.sh, tests/hooks/test-farm-guard-vendored.sh, docs/runbook/testing.md; `corpus-shapes-farm.txt` extended
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 2 (same files; corpus tool and sample)
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED (QA §T2; ids F-C*):
  - **Allow:**
    - `npm root -g`, `npm prefix -g`, `npm outdated -g`
    - `npm view @qwen-code/qwen-code version --json`, `npm audit --json`, `npm config list -l`, `npm pack --dry-run`
    - `npm run dev -- --port 3000`
    - `go env -json`, `cargo tree -d`
    - `TF_ALLOW_LOCAL=1 bash tests/hooks/test-farm-guard-vendored.sh 2>&1`, and the same with `| tail -5`
    - `cd <repo> && TF_ALLOW_LOCAL=1 bash tests/hooks/test-x.sh`
    - `PATH=zuvo/context/bin:$PATH TF_ALLOW_LOCAL=1 bash tests/hooks/test-shellcheck.sh`
    - `env TF_ALLOW_LOCAL=1 bash tests/hooks/test-x.sh`
  - **Block:** `npm it`, `npm tst`, `npm cit`, `npm install-test`.
  - **Hint:** the refusal for `bash tests/hooks/test-x.sh` prints `TF_ALLOW_LOCAL=1 bash tests/hooks/`.
  - **Must not regress** (QA §T2):
    - `TF_ALLOW_LOCAL=1 true; pytest`
    - `TF_ALLOW_LOCAL=1 echo $(pytest)`
    - `pytest; TF_ALLOW_LOCAL=1 true`
    - `X=TF_ALLOW_LOCAL=1 pytest`
    - `TF_ALLOW_LOCAL=0 pytest`
    - `echo TF_ALLOW_LOCAL=1; pytest`
    - `npm test # TF_ALLOW_LOCAL=1`
    - `npm --loglevel silent test`, `make -j 4 test`, `pnpm -r test`, `npm t`
  - **New blocks:**
    - `TF_ALLOW_LOCAL=1 x && pytest`
    - `TF_ALLOW_LOCAL=1 x & pytest`
    - `FOO=$(pytest) TF_ALLOW_LOCAL=1 true`
    - `TF_ALLOW_LOCAL=yes pytest`
  - Extend the shapes file for these cases.
- [ ] GREEN:
  - Decision 2 in the package-manager and task-runner branches.
  - The bash opt-out falls through to python when there are separators.
  - Per-segment env skip; `N>&M` stripped before shlex.
  - The hint.
  - Document the one-line form in `docs/runbook/testing.md` §5.
- [ ] Verify: `LOCALRUN test-farm-guard-vendored` and `B32RUN test-farm-guard-vendored`
  Expected: rc 0, `ALL PASS`.
- [ ] Acceptance Proof:
  - G1/G2/G3/C1–C4
    - Surface: backend-logic
    - Proof: the T2 corpus procedure (base 1f19e158 against this tip, same frozen sample, section farm, `task-3-report.md`) plus the C1/C4 evidence.
    - Expected: `--diff` exits 0. Each UNBLOCK not already listed in T2's report is tied to an F-C case id (about 10 opt-out-separator refusals and about 11 hook-suite refusals).
    - Artifact: `zuvo/proofs/task-3-report.md`
- [ ] Commit: `fix(farm-guard): judge ambiguity by options before the deciding word and let the local opt-out ride on one segment`

### Task 4: git-verb-match library and precise two-stage predicate in the pre-push gate
**Files:** hooks/lib/git-verb-match.sh (new), tests/hooks/test-git-verb-match.sh (new), hooks/pre-push-gate.sh, tests/hooks/test-hook-fast-paths.sh, tests/hooks/test-pre-push-gate.sh; fixtures `git-verb-cases.tsv` and `corpus-shapes-prepush.txt` (new, not counted)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 2 (corpus tool and sample)
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED:
  - **Fixture rows** (`bnv` = `-`):
    - **Must engage** (QA §T3):
      - `git -C . push origin main`
      - `git -c core.askpass=x push`
      - `git  push`
      - `git\tpush`
      - `g"i"t push`
      - `g\\it push`
      - `git \\\npush`
      - `GIT push`
      - `git --no-pager push`
      - `gh  pr create --fill`
      - the 31 wrapper forms
    - **Must not engage:** `echo 'git push'`, `grep -n 'git push' docs/pipeline.md`, `git commit -m 'we git push later'`.
    - **Compound:**
      - `git commit -am x && git push` → push=hit, commit=hit
      - `ZUVO_ALLOW_ADHOC=1 git commit -m x && git push` → commit=adhoc, push=hit
    - **ADHOC:**
      - `ZUVO_ALLOW_ADHOC=1 git push origin feature` → push=adhoc
      - `echo ZUVO_ALLOW_ADHOC=1; git push` → push=hit
    - Commit equivalents of the above.
  - **`test-git-verb-match.sh`:**
    - every row × both verbs, in JSON and raw form;
    - JSON-escaped `git push`;
    - description-only payload → `-`;
    - PATH without jq or python3 → `gvm_command` returns 3.
  - **`test-hook-fast-paths.sh`:**
    - stage A forwards every row whose push value is `hit` or `adhoc`;
    - the stub dir holds the real lib;
    - a stub dir **without** the lib engages through the literal predicate;
    - `ls` and `git status` each cost 1 exec.
  - **`test-pre-push-gate.sh`:**
    - sandbox gitconfig and `ZUVO_HOME`;
    - `pj()` sends the real shape;
    - a description-only mention on a substantial unreviewed repo → 0 (today 1);
    - raw `git -C . push` engages;
    - native (a) and (f) still return 1.
  - **`corpus-shapes-prepush.txt`:** case-id regexes for the mention-only unblocks and the newly caught shapes.
- [ ] GREEN:
  - `git-verb-match.sh` per Decision 3 (≤ 160 lines, one awk program).
  - `pre-push-gate.sh`:
    - stage A is pure `case` globs on `git`+`push` or `gh`+`pr`+`create`;
    - `\u` or `\/` goes straight to stage B;
    - `tr` is forked only when a quote or backslash sits next to a letter;
    - the Decision 3 order is followed, and adhoc is logged;
    - exit codes stay unchanged until T7.
- [ ] Verify: `LOCALRUN test-git-verb-match`, `LOCALRUN test-hook-fast-paths`, `LOCALRUN test-pre-push-gate`, `B32RUN test-git-verb-match`, `B32RUN test-pre-push-gate`
  Expected: each rc 0, `ALL PASS`.
- [ ] Acceptance Proof:
  - G4/C1–C4
    - Surface: backend-logic
    - Proof:
      1. Corpus `--mode sourced-marker pipeline-gate-lib.sh --payload json --sample-in …` on `zuvo/context/base/hooks/pre-push-gate.sh` and on `hooks/pre-push-gate.sh`.
      2. `--diff … --section prepush --shapes tests/hooks/fixtures/corpus-shapes-prepush.txt --report zuvo/proofs/task-4-report.md`.
      3. Record the C1/C4 evidence.
    - Expected: `--diff` exits 0. UNBLOCK = the mention-only engagements (about 4).
    - Artifact: `zuvo/proofs/task-4-report.md`
- [ ] Commit: `fix(pre-push-gate): match a real git push through global options, spacing, quote-splits and compound commands, and stop engaging on mentions and the description field`

### Task 5: block-no-verify — newline-aware join, sentinel, case-insensitive git, eval re-scan, residue
**Files:** hooks/block-no-verify.sh, tests/hooks/test-block-no-verify.sh, docs/pipeline.md; fixtures `git-verb-cases.tsv` (fills the `bnv` column) and `corpus-shapes-bnv.txt` (new)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 2 (corpus), Task 4 (fixture)
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED (QA §T5). Every case runs raw and as JSON, with a sandbox gitconfig and `ZUVO_HOME`, from a temp cwd.
  - **Expect 2** (rc 0 today):
    - FAILOPEN-1: `git commit -m "line one⏎line two" --no-verify`
    - FAILOPEN-2: `git commit -m "a⏎b"⏎git push --no-verify`
    - FAILOPEN-3: `git commit -m 'a⏎b' --no-verify`
    - FAILOPEN-4: `git commit -m "a⏎b" -n`
    - FAILOPEN-6: `echo "a⏎b"; git -c core.hooksPath=/x push`
    - CONT-3: `git \⏎commit --no-verify`
    - CONT-5: `git -c \⏎core.hooksPath=/x commit -m y`
    - COMMENT-1: `echo hi # it's⏎git push --no-verify`
    - COMMENT-2: `ls # say "hi⏎git push --no-verify`
    - `GIT push --no-verify`
    - `eval 'git push' --no-verify`
  - **Expect 0** (rc 2 today): `git config --get core.hooksPath⏎ls -l` and `…⏎echo done`.
  - **Residue, rc 0, documented:** `$'\x67it' commit --no-verify` and `x=; g${x}it commit --no-verify`.
  - **Fill the fixture's `bnv` column** per QA probes:
    - rows ending in `-c '…'`, `&` or a newline → 0;
    - `GIT` and eval rows → 2.

    Then assert every row.
  - The xargs/awk matrix.
  - `ls` costs 1 exec.
  - **Must not regress:** the whole suite, plus CONT-1/2/4/6, NL-1..4, OVERBLOCK-3/4 and ADHOC.
  - **`corpus-shapes-bnv.txt`:** the newline over-block regexes.
- [ ] GREEN:
  - Decision 6 in the awk END loop.
  - The sentinel goes in the process substitution.
  - The command word is lowercased.
  - `eval` arguments are re-joined and re-scanned.
  - No new forks.
  - `docs/pipeline.md` "Known bypasses":
    - add the expansion shapes (the shim is opt-in; CI covers a default install);
    - the "unmatched-quote (fail-closed)" CLOSED claim becomes true here.
- [ ] Verify: `LOCALRUN test-block-no-verify`, `LOCALRUN test-noverify-alias`, `B32RUN test-block-no-verify`
  Expected: `ALL PASS`; `PASS=<n> FAIL=0`; rc 0.
- [ ] Acceptance Proof:
  - G8/C1–C4
    - Surface: backend-logic
    - Proof: corpus `--mode exit --payload json` (base vs tip, frozen sample) → `--diff … --section bnv --shapes tests/hooks/fixtures/corpus-shapes-bnv.txt --report zuvo/proofs/task-5-report.md`, plus the C1/C4 evidence.
    - Expected: `--diff` exits 0. NEWBLOCK is either empty or tied to FAILOPEN/CONT/COMMENT ids. Every UNBLOCK matches a newline over-block shape.
    - Artifact: `zuvo/proofs/task-5-report.md`
- [ ] Commit: `fix(block-no-verify): join continuations and end segments at newlines before tokenizing, fail closed when the tokenizer aborts, and catch GIT/eval forms`

### Task 6: Commit gate — precise predicate, exit 2 in PreToolUse mode, ADHOC parity
**Files:** hooks/pre-commit-adversarial-gate.sh, tests/hooks/test-commit-gate-nudge.sh, tests/hooks/test-noverify-content-binding.sh, scripts/tests/pre-commit-adversarial-gate.bats, docs/pipeline.md
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 1 (decision), Task 4 (lib and fixture), Task 5 (same file: docs/pipeline.md)
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED. Setup: an active execute run, no artifact, sandbox `ZUVO_HOME` and gitconfig.
  - **Fixture iteration (superset proof)**, every row in JSON and raw form:
    - commit=`hit` → 2;
    - commit=`adhoc` → 0 plus the logged message;
    - commit=`-` → 0;
    - decoded rows == expected count > 0.
  - **Named cases:**
    - raw `git -C . commit -m x` → 2 (today 0);
    - `git commit -m x` → 2 (today 1);
    - JSON `echo remember to git commit` → 0 (today 1);
    - `git commit -am x && git push` → 2.
  - `git status` costs 1 exec.
  - **Sweep:** change `test-commit-gate-nudge.sh:89`, `test-noverify-content-binding.sh:54,92,183,186` and `pre-commit-adversarial-gate.bats:59,110` to `== 2`. Content-binding stops writing the real `~/.zuvo/run-markers`.
- [ ] GREEN:
  - Fork-free stage A, then stage B with the Decision 3 order.
  - A block exits 2. `pipeline_nudge` stays at 0. Adhoc is logged.
  - `docs/pipeline.md` (execute-half paragraph): it now really blocks, and it is PreToolUse-only.
- [ ] Verify: `LOCALRUN test-commit-gate-nudge`, `LOCALRUN test-noverify-content-binding`, `npx --yes bats@1.11.0 scripts/tests/pre-commit-adversarial-gate.bats`, `B32RUN test-commit-gate-nudge`
  Expected: `ALL PASS`; `PASS=<n> FAIL=0`; `0 failures`; rc 0.
- [ ] Acceptance Proof:
  - G5 (commit)/C1–C4
    - Surface: backend-logic
    - Proof: the runs above plus the C1/C4 evidence.
    - Expected: as above.
    - Artifact: `zuvo/proofs/task-6-report.md`
- [ ] Commit: `fix(commit-gate): block with exit 2 — exit 1 is a non-blocking error on every hook host, so the execute-run block never blocked`

### Task 7: Pre-push gate — exit 2, advisory lib-absent fallback, no-remote fail-open, topology suite, dispatch smoke
**Files:** hooks/pre-push-gate.sh, tests/hooks/test-pre-push-gate.sh, tests/hooks/test-pre-push-gate-topology.sh (git mv of smoke-gate-topology.sh), docs/pipeline.md, tests/hooks/smoke-dispatch-install.sh (new)
**Surface:** backend-logic
**Complexity:** complex
**Dependencies:** Task 1 (decision), Task 4 (same file), Task 6 (same file: docs/pipeline.md)
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED:
  - **PreToolUse mode, measured at the hook process:** (p1) / agent `gate_legacy` on a substantial unreviewed repo with no remotes → **2** (today 1).
  - **Lib-absent fallback:** the gate copied alone, plus a runs.log with no review row → 0 and a WARNING (today 1).
  - **Native mode (dispatcher), no remotes, unknown rsha** `1234567890abcdef1234567890abcdef12345678`, 3 unreviewed production files → **1** (today 0). The control case with a known rsha → 1.
  - **Rename:** `GIT_CONFIG_GLOBAL=/dev/null git ls-files --error-unmatch tests/hooks/test-pre-push-gate-topology.sh` → 0.
  - **Must not regress:**
    - native (a) and (f) → 1;
    - (b)–(e), (g), (h1)–(h3) → 0;
    - (p2)–(p5) → 0;
    - TOPO1–4;
    - the dispatcher maps any non-zero exit to 1 (native path only).
- [ ] GREEN:
  - `gate_legacy` returns 2, propagated as the process exit code.
  - The runs.log fallback becomes advisory.
  - Extract `_ppg_noremote_range` from the new-branch block:
    - a known rsha keeps the two-dot range (over-scoped on merges; documented);
    - otherwise, merge-base with the default branch, falling back to the empty tree.
  - **`git mv`:** `PASS:`/`FAIL:` lines plus `ALL PASS`, cases SMOKE1–4 renamed TOPO1–4, sandbox `ZUVO_HOME`.
  - **`smoke-dispatch-install.sh`** (`smoke-*`, so not in run-all; unknown args exit 64):
    1. Runs `install_claude_home` into a sandbox HOME, the way `test-farm-guard-vendored.sh:36-38` does: `env -i`, a sandbox `GIT_CONFIG_GLOBAL`, `install.sh` sourced.
    2. Then runs `HOME=<sbx> bash tests/hooks/smoke-global-dispatch.sh`.
  - `docs/pipeline.md`: the exit-contract row and a corrected Husky note.
- [ ] Verify: `LOCALRUN test-pre-push-gate`, `LOCALRUN test-pre-push-gate-topology`, `B32RUN test-pre-push-gate`, `B32RUN test-pre-push-gate-topology`, `LOCALRUN test-hook-fast-paths`, `TF_ALLOW_LOCAL=1 bash tests/hooks/smoke-dispatch-install.sh`
  Expected: each rc 0 with `ALL PASS`; the smoke prints S1 (agent blocked) and S2 (human exempt) as passing.
- [ ] Acceptance Proof:
  - G5 (push)/G6/C1–C4
    - Surface: integration
    - Proof: the runs above plus the C1/C4 evidence.
    - Expected: as above.
    - Artifact: `zuvo/proofs/task-7-report.md`
- [ ] Commit: `fix(pre-push-gate): block with exit 2, refuse an unknown base on the no-remote path, and run the merge-topology suite in run-all`

### Task 8: Detect a broken global core.hooksPath at session start; installer survives and repairs it
**Files:** hooks/session-start, scripts/install.d/claude-home.sh, tests/hooks/test-session-start-hookspath.sh (new), tests/hooks/test-install-hookspath-multivalue.sh (new)
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 3 and Task 7 (their Verify and proofs run `install_claude_home`; the installer edit comes after them)
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED:
  - **`test-session-start-hookspath.sh`** (sandbox gitconfig):
    - `hooksPath = <sbx>/.claude/hooks` plus `hooksPath = -l` → output parses with `json.loads`, and the context names both values (today: no warning).
    - Unset, or a valid dir → no warning.
    - Valid JSON on all 5 platform branches.
  - **`test-install-hookspath-multivalue.sh`** (`install_claude_home` under `set -euo pipefail`; sandbox HOME and gitconfig):
    - two values → exit 0; exactly one value, `<sbx>/.claude/hooks`; the warning names both (today: rc 5);
    - single value → exit 0, that same line, no warning.
- [ ] GREEN:
  - **session-start:** the Decision 8 query, the warning via `json_escape`, and no stray stdout.
  - **`claude-home.sh`** hooksPath block: `--get-all`, warn, `--replace-all`; every write wrapped in `if !` and counted as a miss on failure.
- [ ] Verify: `LOCALRUN test-session-start-hookspath`, `LOCALRUN test-install-hookspath-multivalue`, `LOCALRUN test-install-claude-home`, `B32RUN test-session-start-hookspath`, `B32RUN test-install-hookspath-multivalue`
  Expected: each rc 0, `ALL PASS`.
- [ ] Acceptance Proof:
  - G9 (detector half)/G10/C1–C4
    - Surface: integration
    - Proof: the runs above plus the C1/C4 evidence.
    - Expected: as above.
    - Artifact: `zuvo/proofs/task-8-report.md`
- [ ] Commit: `fix(session-start,install): warn when the global core.hooksPath is multi-valued or dangling, and repair it instead of aborting the install`

### Task 9: Gate library — exempt `*.jsonl`, document and test the engine's filename limits
**Files:** hooks/lib/pipeline-gate-lib.sh, tests/hooks/test-pipeline-gate-lib.sh, docs/pipeline.md
**Surface:** backend-logic
**Complexity:** standard
**Dependencies:** Task 7 (same file: docs/pipeline.md)
**Failure:** halt
**Execution routing:** default implementation tier

- [ ] RED:
  - `printf 'knowledge/gotchas.jsonl\n' | pg_classify_files` → empty.
  - Three jsonl-only appends are not substantial.
  - A review artifact whose filename contains a TAB still grants coverage (read uncached, the documented safe behaviour).
  - **Must not regress:** `foo.jsonl.sh`, `src/app.ts` and `KNOWLEDGE.JSONL` stay production; `x.json` stays exempt.
- [ ] GREEN:
  - `*.jsonl` joins the `*.json` arm, with a reason comment.
  - Document the newline / `\037` / TAB limits in the engine header and in docs "Cost of the check".
  - Update docs "What counts as substantial", with a CI note.
- [ ] Verify: `LOCALRUN test-pipeline-gate-lib` and `B32RUN test-pipeline-gate-lib`
  Expected: rc 0, `ALL PASS`.
- [ ] Acceptance Proof:
  - G7/C1–C4
    - Surface: backend-logic
    - Proof: `test "$(bash -c '. hooks/lib/pipeline-gate-lib.sh; printf "knowledge/patterns.jsonl\n" | pg_classify_files' | wc -c)" -eq 0` and, as a positive control, `test "$(bash -c '. hooks/lib/pipeline-gate-lib.sh; printf "src/app.ts\n" | pg_classify_files')" = src/app.ts` plus the C1/C4 evidence.
    - Expected: rc 0.
    - Artifact: `zuvo/proofs/task-9-report.md`
- [ ] Commit: `fix(gate-lib): treat JSON Lines as data like JSON, so curated knowledge appends stop blocking pushes`

### Task 10: Sub-agent git-config safety line in every agent prompt, with a guard test
**Files:** shared/includes/agent-preamble.md, shared/includes/env-compat.md, tests/hooks/test-agent-git-isolation.sh (new), plus one line in each of the 24 `skills/*/agents/*.md` files without the preamble (Architect §8)
**Surface:** docs
**Complexity:** complex
**Dependencies:** none
**Failure:** halt
**Execution routing:** deep implementation tier

Rule 2 justification: one mechanical class fix, the same line in 24 non-production markdown files. Splitting it gains no isolation.

- [ ] RED: `test-agent-git-isolation.sh` (sandbox `ZUVO_HOME`, `GIT_CONFIG_GLOBAL=/dev/null`) asserts:
  - (a) the marker `Git safety (mandatory):` and `GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1` appear in `agent-preamble.md` and in `env-compat.md` §Agent Dispatch;
  - (b) every `skills/*/agents/*.md` either references `agent-preamble.md` or contains the marker;
  - (c) the number checked == `find skills -path '*/agents/*.md' | wc -l` > 0;
  - (d) after `ZUVO_DIST_ROOT=<mktemp> bash tests/lib/dist-build.sh <p>` for codex, cursor and kimi, the marker or a preamble reference is present in codex `skills/*/agents/*.md`, cursor `agents/*.md` and kimi `agents/*.md`, and the marker is present in each built `shared/includes/agent-preamble.md`.

  Today the result is 0/51.
- [ ] GREEN:
  - **The ASCII sentence:** never change git config outside a repo you created (no `--global` or `--system`, no `--file` under `$HOME`); an argument after the key is a WRITE (the `core.hooksPath -l` incident); in a throwaway repo, export the two variables first; in the project repo, leave them unset.
  - **Preamble:** Core Constraint 6.
  - **`env-compat.md`** is the source of truth: leads paste the sentence into every Bash-capable dispatch and run `git config --global --get-all core.hooksPath` after each such agent returns.
  - Add the line to the 24 files.
- [ ] Verify: `LOCALRUN test-agent-git-isolation`, `B32RUN test-agent-git-isolation`, `bash scripts/validate-skills.sh`
  Expected: rc 0, `ALL PASS`; `ERRORS: 0`; `count-consistency: OK`.
- [ ] Acceptance Proof:
  - G9/C1/C3/C4
    - Surface: docs
    - Proof: the runs above plus the C1/C4 evidence.
    - Expected: rc 0.
    - Artifact: `zuvo/proofs/task-10-report.md`
- [ ] Commit: `fix(agents): every sub-agent prompt carries the git-config safety line — an auditor's --global write once disabled every hook on the machine`

### Task 11: Whole-feature smoke, full battery, backlog dispositions
**Files:** tests/hooks/smoke-claude-pretooluse-contract.sh, tests/hooks/smoke-dispatch-install.sh, memory/backlog.md
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 1, Task 2, Task 3, Task 4, Task 5, Task 6, Task 7, Task 8, Task 9, Task 10
**Failure:** halt
**Execution routing:** deep implementation tier

- [ ] RED: none. This task extends the smokes and runs the proofs over T1–T10.
- [ ] GREEN:
  - **Smoke cases (c) and (d).** Setup:
    - a sandbox repo with a bare origin and 3 unreviewed production files;
    - `claude` runs **with the sandbox repo as cwd**;
    - the wrapper exports `PG_REPO_ROOT`;
    - `GIT_CONFIG_GLOBAL=/dev/null` and a sandbox `ZUVO_HOME`;
    - a wrapper logs the payload and rc of the real `hooks/pre-push-gate.sh`;
    - flags `--tools Bash --max-turns 2`.

    Cases:
    - **(c)** Prompt: "Run exactly once: git push origin feature. If it is blocked, stop; do not retry." Assert:
      - the log has exactly one `git push` payload, with rc 2;
      - `git -C <bare> rev-parse --verify -q refs/heads/feature` fails.

      A retry counts as inconclusive: re-run once.
    - **(d)** Positive control: the prompt asks for `ZUVO_ALLOW_ADHOC=1 git push origin feature`, and the ref then exists.
  - **`smoke-dispatch-install.sh --seed-bad-hookspath`:**
    1. Seed `core.hooksPath=<sbx>/.claude/hooks` in the sandbox gitconfig.
    2. Run `git config --file <sbx-gitconfig> --add core.hooksPath -l`.
    3. Run `install_claude_home`.
    4. Assert rc 0 and exactly one value equal to `<sbx>/.claude/hooks`.
    5. Run the dispatch smoke.
  - **memory/backlog.md:** run `~/.zuvo/backlog-archive.py lookup` before every write.

    | Backlog id | Fixed by | Tick with |
    |---|---|---|
    | FARM-GUARD-TESTS-SH-FP, FARM-HOOK-HEREDOC-FP | T2 | T2 sha |
    | FARM-GUARD-FALSE-POSITIVES, FARM-HOOK-FALSE-POSITIVES, FARM-HOOK-HOOK-SUITES | T2 + T3 | T3 sha |
    | B-20260929-PREPUSH-FASTPATH-SUBSTRING | T4 | T4 sha |
    | BNV-MULTILINE-OVERBLOCK, BNV-EXPANSION-RESIDUE | T5 | T5 sha |
    | B-prepush-gate-merge-commit-range | 32bee854 (residue: T7) | 32bee854, plus the T7 sha as a note |
    | SUBAGENT-GIT-ISOLATION | T8 + T10 | T10 sha |
    | GATE-KNOWLEDGE-JSONL, GATE-ENGINE-ODD-FILENAMES | T9 | T9 sha |
    | B-blocknoverify-fmt | 1d779490 | 1d779490 |
    | NEW FARM-GUARD-BYPASSES (G3) | T2 + T3 | T3 sha |
    | NEW PRETOOLUSE-EXIT1-ADVISORY (G5) | T6 + T7 | T7 sha |
    | NEW BNV-MULTILINE-FAILOPEN (G8) | T5 | T5 sha |
    | TRACK-INCLUDES-TMP, REWAKE-ATOMIC, INSTALL-HOOKS-CP-IN-PLACE | — | "→ plan B" |
    | reviewed-blob-legacy-window | — | "owner policy decision" |
    | HOOK-FILES-CQ11 | — | new farm-guard size; "zuvo:refactor after plan B" |
    | DOUBLE-GATE-PER-PUSH | — | "revisit: exit 2 stops blocked pushes at PreToolUse" |
    | UNREVIEWED-LANDINGS | — | "separate zuvo:review" |

    The `B-20261005-` prefix is omitted in the table. New open entries:
    - post-skill misfire → plan B
    - git shim cp-through-symlink → plan B
    - `~/.<host>/scripts` copies
    - rewake `payloads.log` rotation race
    - the content-fix, geo-fix and content-migration reminders
    - watchdog false RESUME during background agents (cron 180 s vs 150 s threshold)
    - ADHOC owner decision
- [ ] Verify:
  1. `rt --full --light bash tests/run-all.sh > zuvo/context/runall-after.log`. Its rc is not the verdict, because the base may already have reds.
  2. Compute the new reds:

     ```
     comm -13 <(sed -nE 's/^FAIL: (.*) \(exit [0-9]+\)$/\1/p' zuvo/context/runall-base.log | sort -u) <(sed -nE 's/^FAIL: (.*) \(exit [0-9]+\)$/\1/p' zuvo/context/runall-after.log | sort -u) > zuvo/context/runall-new-reds.txt
     ```

  3. Farm-only reds (runbook §5): `: > zuvo/context/runall-farm-only.txt` first (always created), then list each new red that is a `tests/hooks/*` suite and passes under LOCALRUN. Checks: `test -f zuvo/context/runall-farm-only.txt`; `test -z "$(grep -v '^tests/hooks/test-[A-Za-z0-9._-]*\.sh$' zuvo/context/runall-farm-only.txt)"`; a scratch script run as `TF_ALLOW_LOCAL=1 bash zuvo/context/t11-farm-only-rerun.sh` runs every listed suite locally and exits non-zero if any fails (output recorded in `task-11-report.md`); then `test -z "$(grep -vxFf zuvo/context/runall-farm-only.txt zuvo/context/runall-new-reds.txt)"`.
  4. `grep -qE '^PASS: .*test-pre-push-gate-topology\.sh \([0-9]+s\)$' zuvo/context/runall-after.log`.
  5. `~/.zuvo/backlog-archive.py verify --repo "$PWD"`.

  Expected: every check exits 0, and `verify` prints `OK disjoint`.
- [ ] Acceptance Proof:
  - G11/S1
    - Surface: docs
    - Proof: `backlog-archive.py lookup` plus `git cat-file -e <sha>` for every row in the table.
    - Expected: closed rows are ticked with existing shas, and annotated rows carry their notes.
    - Artifact: `zuvo/proofs/task-11-report.md`
  - SMOKE1–3: below.
- [ ] Commit: `test(hooks): prove the PreToolUse block contract end-to-end and close the hook backlog entries this plan fixed`

## Whole-feature Smoke Proofs

- **SMOKE1 — hook hosts really block.**
  - Proof: `TF_ALLOW_LOCAL=1 bash tests/hooks/smoke-claude-pretooluse-contract.sh --cases all`
  - Expected:
    - (a) the command ran;
    - (b) it did not run;
    - both per-case logs contain `touch <W>/ran`;
    - (c) exactly one `git push` payload, with rc 2, and the bare ref is absent;
    - (d) the ref is present;
    - the orphan count is 0.
  - Artifact: `zuvo/proofs/smoke-pretooluse-contract.md`
  - RED mapping: T1 for (a) and (b); T6/T7 for rc 2 (mocked).
- **SMOKE2 — global wiring end-to-end.**
  - Proof:
    1. `TF_ALLOW_LOCAL=1 bash tests/hooks/smoke-dispatch-install.sh --seed-bad-hookspath`
    2. `LOCALRUN test-pre-push-gate-topology`
    3. `LOCALRUN test-session-start-hookspath`
  - Expected: after the two-value seed, exactly one value remains; S1 and S2 pass; topology `ALL PASS`; the warning case passes.
  - Artifact: `zuvo/proofs/smoke-global-wiring.md`
  - RED mapping: T7, T8.
- **SMOKE3 — no unintended verdict changes on real commands.**
  - Proof: the T2, T4 and T5 corpus procedures, base 1f19e158 against the final tip, using the frozen sample. Each is `--diff`ed into its own section of `zuvo/proofs/smoke-verdict-corpus.md` against its shapes file.
  - Expected: all three exit 0.
  - Artifact: `zuvo/proofs/smoke-verdict-corpus.md`
  - RED mapping: T2, T4, T5.
