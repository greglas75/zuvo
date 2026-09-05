#!/usr/bin/env bash
# NOTHING RUNS ON THE LAPTOP — ENFORCED, NOT DOCUMENTED.
#
# The rule "send test suites to the farm" has existed in CLAUDE.md for months
# and nothing checked it, so it held exactly as well as good intentions do.
# Measured on the workstation 2026-08-29: 109 test processes, 421% CPU, load 34
# — vitest, jest and STRYKER (mutation testing, the heaviest thing we run) — all
# started with a bare `npx …`, none through `rt`. The farm was idle enough at
# the same moment to have taken every one of them.
#
# The cost is not only a slow Mac. A saturated workstation makes every agent on
# it slower, which produces more timeouts, which produces more local fallbacks.
# That loop is what a person experiences as "the farm doesn't work".
#
# So this is a PreToolUse gate on Bash: a command that starts a test runner
# outside `rt` is refused, with the corrected command in the message so the
# agent can simply run it. It is a redirect, not a wall.
#
# ── 2026-09-05: TWO defects fixed, both found the same way — by failing ───────
#
# 1. IT WAS NEVER REGISTERED. This file was written on 2026-08-29 and no entry
#    for it existed in ~/.claude/settings.json, so it had never executed once.
#    A guard that is not wired up is a comment.
#
# 2. IT ONLY KNEW JS. `RUNNERS` was vitest/jest/stryker/playwright plus npx and
#    `npm test`. The global rule it enforces says, verbatim: "This is not a
#    JS-only rule. Any test command qualifies: vitest, jest, playwright,
#    `node --test`, a bash harness, a Makefile target, pytest."
#    On 2026-09-05 an agent ran `bash tests/run-all.sh` — a bash harness, ~9
#    minutes — SIX times on this laptop, twice concurrently, killing two tasks
#    on memory exhaustion, while the farm reported 0/17 slots used and 95% idle
#    CPU. Every one of those commands passes the old matcher untouched.
#    So the matcher now covers what the rule covers, not what one stack does.
#
# WHAT IT DELIBERATELY DOES NOT BLOCK, because a gate that cries wolf gets
# disabled:
#   * anything already going through `rt`
#   * anything running ON a farm host (ssh … 'npx vitest …') — that IS the farm
#   * merely MENTIONING a runner (grep jest, cat a config, edit a file)
#   * a syntax check (`bash -n foo.sh`) — it parses, it does not run
#   * dependency installs (`npm ci`, `npm install`) — often needed locally, and
#     the farm provisions its own
#   * wrapper/release scripts (dev-push.sh, release.sh, ship). They run a suite
#     internally, but blocking a release adds friction to the one flow that must
#     not get more of it. Use `ZUVO_SKIP_TESTS=1` after an `rt` run instead.
#   * a single spec run for interactive debugging is still a suite: it goes to
#     the farm too, and `rt --light` makes that cheap
#   * TF_ALLOW_LOCAL=1 as a deliberate, visible escape hatch
set -uo pipefail

_input=$(cat 2>/dev/null) || exit 0
[ -n "$_input" ] || exit 0

# Hard opt-out for the gate itself (debugging the gate).
case "${FARM_HOOK_OFF:-}" in ?*) exit 0 ;; esac

# The command, extracted without assuming jq is present.
_cmd=$(printf '%s' "$_input" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
print((d.get("tool_input") or {}).get("command","") or "")
' 2>/dev/null) || exit 0
[ -n "$_cmd" ] || exit 0

# Explicit opt-out, and the farm-side execution path.
case "${TF_ALLOW_LOCAL:-}" in ?*) exit 0 ;; esac
case "$_cmd" in
  *TF_ALLOW_LOCAL=*|*RT_LOCAL_OK=*) exit 0 ;;
  ssh\ *|*\|\ ssh\ *|*"; ssh "*|*"&& ssh "*) exit 0 ;;   # running it on a host, not here
esac

# Fail OPEN when the farm client is not installed: refusing a test run on a box
# that has no `rt` would leave no way to run tests at all.
command -v rt >/dev/null 2>&1 || exit 0

# A COMMAND WORD, NOT A SUBSTRING. `grep jest package.json` and `cat
# vitest.config.ts` must pass; only an actual invocation is refused. Split on
# the shell separators that start a new command and look at the head of each
# segment, skipping leading env assignments and `cd x &&` style prefixes.
_verdict=$(printf '%s' "$_cmd" | python3 -c '
import re, sys, os

cmd = sys.stdin.read()

# STRIP HEREDOC BODIES FIRST. A python/awk script passed inline is DATA, not a command
# sequence, and splitting it on `;` and newlines turns every mention of a runner name into a
# fake command head. Measured cost of not doing this: the gate refused `ps | grep vitest`, a
# repo-wide search for the word, and its own maintenance edits — and a gate that cries wolf is
# a gate somebody switches off.
cmd = re.sub(r"<<-?\s*[\"\x27]?(\w+)[\"\x27]?.*?^\1\s*$", " ", cmd, flags=re.S | re.M)
# Quoted argument bodies are data too (`grep -E \x27vitest|jest\x27`, `git commit -m "add tests"`).
cmd = re.sub(r"\x27[^\x27]*\x27", " ", cmd)
cmd = re.sub(r"\"[^\"]*\"", " ", cmd)

# Direct runner binaries: invoking one IS running a suite.
RUNNERS = {
    "vitest", "jest", "stryker", "playwright", "mocha", "ava", "cypress",
    "pytest", "phpunit", "tsc", "knip", "biome", "eslint",
}
# `<pm> run <script>`: only the script families the rule names (test/build/lint/typecheck).
RUN_SCRIPTS = ("test", "build", "lint", "typecheck", "type-check", "check", "e2e", "coverage")
PMS = {"npm", "yarn", "pnpm", "bun"}
# Task runners whose first argument decides.
TASK_SUBCMDS = {
    "make":   ("test", "check", "build", "lint", "typecheck", "coverage"),
    "cargo":  ("test", "build", "clippy", "bench"),
    "go":     ("test", "build", "vet"),
    "turbo":  ("test", "build", "lint", "typecheck", "check"),
    "gradle": ("test", "build", "check"),
    "gradlew":("test", "build", "check"),
    "mvn":    ("test", "verify", "package"),
    "dotnet": ("test", "build"),
    "composer": ("test",),
}

def looks_like_test_script(path):
    """A bash/sh harness. The rule names `a bash harness` explicitly, and it is what the
    2026-09-05 incident actually ran — six times, ~9 minutes each."""
    base = path.rsplit("/", 1)[-1]
    if re.search(r"(^|/)(tests?|spec|e2e)/", path):
        return True
    if re.match(r"^(test|spec|run-all|run-tests|check)[-_.]", base):
        return True
    if re.search(r"[-_.](test|tests|spec|suite)\.(sh|bash)$", base):
        return True
    if base in ("run-all.sh", "run-tests.sh", "test.sh", "tests.sh", "check.sh"):
        return True
    return False

# A BACKSLASH-NEWLINE IS ONE COMMAND, NOT TWO. Splitting on the raw newline turned the
# continuation of
#     git add a.md b.md \\
#         tests/hooks/x.sh
# into its own segment whose FIRST WORD is the test path — so the guard blocked a `git add`
# (2026-09-05). Naming a file is not running it, and a guard that cries wolf on staging is a
# guard people learn to route around.
cmd = re.sub(r"\\\n", " ", cmd)

segs = re.split(r"(?:&&|\|\||[;|]|\n)", cmd)
for seg in segs:
    words = seg.strip().split()
    i = 0
    # skip env assignments (FOO=bar)
    while i < len(words) and ("=" in words[i] and not words[i].startswith("-")):
        i += 1
    head = words[i:]
    if not head:
        continue
    w0 = head[0].rsplit("/", 1)[-1]

    # already on the farm
    if w0 in ("rt", "tf-run.sh", "tf-submit.sh"):
        continue
    # transparent prefixes — look past them (and past the argument cd/timeout consume)
    while w0 in ("cd", "time", "env", "nohup", "setsid", "timeout", "exec", "sudo"):
        head = head[2:] if w0 in ("cd", "timeout") else head[1:]
        if not head:
            break
        w0 = head[0].rsplit("/", 1)[-1]
    if not head:
        continue
    if w0 in ("rt", "tf-run.sh", "tf-submit.sh"):
        continue
    rest = head[1:]

    # `bash -n` parses without running — never a suite.
    if w0 in ("bash", "sh", "zsh") and any(a == "-n" for a in rest):
        continue

    # 1. a bash/sh harness, or a directly-executed test script
    if w0 in ("bash", "sh", "zsh"):
        target = next((a for a in rest if not a.startswith("-")), "")
        if target and looks_like_test_script(target):
            print(f"{w0} {target}"); sys.exit(0)
    elif w0.endswith((".sh", ".bash")) and looks_like_test_script(head[0]):
        print(head[0]); sys.exit(0)

    # 2. a runner binary, directly or via npx/dlx
    if w0 in ("npx", "bunx", "dlx"):
        first = next((a for a in rest if not a.startswith("-")), "")
        b = first.rsplit("/", 1)[-1]
        if b in RUNNERS:
            print(f"{w0} {first}"); sys.exit(0)
        if b in TASK_SUBCMDS:
            sub = rest[rest.index(first) + 1] if rest.index(first) + 1 < len(rest) else ""
            if sub in TASK_SUBCMDS[b]:
                print(f"{w0} {first} {sub}"); sys.exit(0)
        continue
    if w0 in RUNNERS:
        print(w0); sys.exit(0)

    # 3. package-manager scripts. `npm ci` / `npm install` are NOT this.
    if w0 in PMS:
        if not rest:
            continue
        sub = rest[0]
        if sub in ("ci", "install", "i", "add", "remove", "exec", "dlx", "why", "ls"):
            if sub in ("exec", "dlx"):
                nxt = rest[1].rsplit("/", 1)[-1] if len(rest) > 1 else ""
                if nxt in RUNNERS:
                    print(f"{w0} {sub} {nxt}"); sys.exit(0)
            continue
        if sub.startswith(RUN_SCRIPTS):
            print(f"{w0} {sub}"); sys.exit(0)
        if sub == "run" and len(rest) > 1 and rest[1].startswith(RUN_SCRIPTS):
            print(f"{w0} run {rest[1]}"); sys.exit(0)
        continue

    # 4. task runners decided by their first subcommand
    if w0 in TASK_SUBCMDS:
        sub = next((a for a in rest if not a.startswith("-")), "")
        if sub in TASK_SUBCMDS[w0]:
            print(f"{w0} {sub}"); sys.exit(0)
        continue

    # 5. `node --test`, `python -m pytest`
    if w0 in ("node",) and "--test" in rest:
        print("node --test"); sys.exit(0)
    if w0 in ("python", "python3") and "-m" in rest:
        j = rest.index("-m")
        if j + 1 < len(rest) and rest[j + 1].split(".")[0] in ("pytest", "unittest"):
            print(f"{w0} -m {rest[j+1]}"); sys.exit(0)
' 2>/dev/null) || exit 0

[ -n "$_verdict" ] || exit 0

# THE MESSAGE CARRIES THE FIX. A refusal that only says "no" costs the agent a
# round trip to work out what to do; one that hands back the corrected command
# costs nothing and gets followed.
{
  echo "BLOCKED: '$_verdict' would run the suite on this laptop."
  echo
  echo "The farm exists for exactly this. A saturated Mac slows every agent on it,"
  echo "which causes more farm timeouts, which causes more local fallbacks — that"
  echo "loop is what looks like 'the farm is broken'. Measured 2026-09-05: six full"
  echo "local suite runs, two concurrent, two background tasks killed on memory"
  echo "exhaustion — while the farm sat at 0/17 slots and 95% idle CPU."
  echo
  echo "Run it on the farm instead — same command, prefixed:"
  echo "    rt --light <your command>      # unit tests, type-check, lint, build"
  echo "    rt <your command>              # anything needing postgres/redis"
  echo
  echo "Farm noise (a 483s timeout, 'ssh 255') is a RETRY, not a reason to go local."
  echo
  echo "If this genuinely must run locally (farm unreachable, debugging the farm"
  echo "itself), say so explicitly with TF_ALLOW_LOCAL=1 in front of the command."
} >&2
exit 2
