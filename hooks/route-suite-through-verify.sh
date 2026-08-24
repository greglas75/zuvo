#!/usr/bin/env bash
# route-suite-through-verify — send a hand-run test command through the instrument instead.
#
# WHY THIS IS A HOOK AND NOT A SENTENCE IN THE SKILL
#
# Measured across the write-tests benchmark corpus: 5 of 15 runs on the newest arm ever produced a
# verification verdict at all. The rest wrote a suite, ran it by hand with `npx vitest run <spec>`,
# saw green, and finished. Two rewordings of the instruction had already failed to change that, and
# a `Stop` hook cannot help because Stop hooks do not fire under `claude -p` (measured directly, in
# a container, before this was written). `PreToolUse` does fire there — that is the whole reason
# this layer exists at this level.
#
# The runs were not being lazy. Running the suite is the natural next action after writing it, and
# nothing stopped them doing it the direct way. So this makes the direct way go through the
# instrument rather than asking anyone to remember.
#
# SCOPE — deliberately the narrowest thing that covers the measured failure
#
# It fires ONLY when all of these hold:
#   * the command is a bare test-runner invocation (vitest / jest / pytest / node --test),
#   * it names a spec file that a zuvo coverage manifest DECLARES in its test_files,
#   * that manifest has no verification receipt yet, or the receipt is stale for this spec.
#
# So: no manifest, no interference. Receipt already valid, no interference. Any other command, any
# other repo, no interference. A test command that names nothing zuvo tracks is none of its
# business.
#
# FAIL-OPEN everywhere. A hook that guesses wrong about someone's test command is worse than one
# that misses a case: unparseable JSON, no python3, no manifest directory, an unreadable manifest,
# any error at all — exit 0 and get out of the way.
#
# Escape: ZUVO_ALLOW_BARE_TESTS=1. An environment variable a human sets, not a flag an agent can
# type into the command it was already trying to run — that distinction is why `--reset-budget`
# had to be closed and why `--budget 999` had to be closed after it.

set -uo pipefail

[ "${ZUVO_ALLOW_BARE_TESTS:-}" = "1" ] && exit 0

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# stderr must reach the agent — it IS the redirect message — and exit 2 must survive, or the hook
# can never block. `2>/dev/null || exit 0` did both wrongs at once: it discarded the message and
# swallowed the blocking status, leaving a hook that looked installed and did nothing.
set +e
python3 - "$INPUT" <<'PY'

import json
import os
import re
import sys

ALLOW = 0        # let the command run
BLOCK = 2        # PreToolUse: block and feed stderr back to the agent


def bail():
    sys.exit(ALLOW)


try:
    payload = json.loads(sys.argv[1])
except Exception:
    bail()

if (payload.get("tool_name") or payload.get("tool") or "") != "Bash":
    bail()
cmd = ((payload.get("tool_input") or {}).get("command") or "").strip()
if not cmd:
    bail()

# A bare runner invocation, not a wrapper. `~/.zuvo/verify-tests` runs vitest itself, and blocking
# the instrument for being the thing it instruments would be a loop with no exit.
if "verify-tests" in cmd:
    bail()
# Measured against a real run rather than guessed: the first version of this pattern missed the
# very command it was written for. The agent did not type `npx vitest` — it typed
#
#   cd apps/designer
#   timeout 100 node --max-old-space-size=8192 ./node_modules/vitest/vitest.mjs run <spec>
#
# which breaks the pattern twice over: the separator before it is a NEWLINE, not one of `;&|`, and
# the runner is reached through a path rather than through npx. Both are the normal shape of a
# real invocation, not an edge case — a memory flag and a `cd` are what you write when the suite
# is big enough to need tests in the first place.
RUNNER = re.compile(
    r"(?:^|[;&|\n]\s*)"                                   # start, a separator, OR a new line
    r"(?:\S+\s+)*?"                                       # timeout 100 / env VAR=1 / node <flags>
    r"(?:\S*/)?"                                          # ./node_modules/.bin/, /usr/local/bin/
    r"(vitest|jest|pytest)(?:\.m?[cj]s)?\b"                # vitest, vitest.mjs, jest.js
    r"|(?:^|[;&|\n]\s*)(?:\S+\s+)*?node\s+--test\b")
if not RUNNER.search(cmd):
    bail()

cwd = payload.get("cwd") or os.getcwd()


def git_root(start):
    d = os.path.abspath(start)
    while True:
        if os.path.isdir(os.path.join(d, ".git")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return os.path.abspath(start)
        d = parent


root = git_root(cwd)
contracts = os.path.join(os.environ.get("ZUVO_OUTPUT_DIR") or os.path.join(root, "zuvo"),
                         "contracts")
if not os.path.isdir(contracts):
    bail()

# Which spec files does the command name? Only paths that actually exist matter; a bare `vitest`
# with no arguments runs the whole suite and is not the hand-verification this is about.
# A `cd` INSIDE the command changes what the spec path is relative to, and the tool's own cwd is
# not it. Measured, again, on a real run:
#
#   cd /home/coding-agent/workspace/apps/api && npx vitest run src/modules/runner/x.spec.ts
#
# `src/modules/...` exists under apps/api and does not exist under the workspace root, so resolving
# against cwd alone finds nothing and the hook passes a command it was written to catch. In a
# monorepo the `cd` is not optional — it is how you reach the package that owns the config.
bases = [cwd, root]
for target in re.findall(r"(?:^|[;&|\n]\s*)cd\s+([^\s;&|]+)", cmd):
    target = os.path.expanduser(target)
    bases.append(target if os.path.isabs(target) else os.path.join(cwd, target))

tokens = re.findall(r"[\w./@~-]+", cmd)
named = set()
for t in tokens:
    if not re.search(r"\.(spec|test)\.[cm]?[jt]sx?$|_test\.py$|test_[\w-]+\.py$", t):
        continue
    for cand in [os.path.join(b, t) for b in bases] + [t]:
        if os.path.isfile(cand):
            named.add(os.path.realpath(cand))
            break
if not named:
    bail()


def sha256(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


for entry in sorted(os.listdir(contracts)):
    if not entry.endswith(".coverage.json"):
        continue
    man_path = os.path.join(contracts, entry)
    try:
        with open(man_path, encoding="utf-8") as fh:
            man = json.load(fh)
    except Exception:
        continue

    declared = {}
    for rel in (man.get("test_files") or []):
        for cand in (os.path.join(root, rel), os.path.join(contracts, rel)):
            if os.path.isfile(cand):
                declared[os.path.realpath(cand)] = rel
                break
    hit = named & set(declared)
    if not hit:
        continue

    # The manifest tracks this spec. Is it already measured, in its CURRENT state?
    receipt = man.get("verification") if isinstance(man.get("verification"), dict) else None
    recorded = (receipt or {}).get("spec_sha256") or {}
    covered = True
    for abs_path in hit:
        rel = declared[abs_path]
        want = recorded.get(rel)
        if want is None:
            want = next((v for k, v in recorded.items()
                         if os.path.realpath(os.path.join(root, k)) == abs_path), None)
        try:
            if want is None or want != sha256(abs_path):
                covered = False
                break
        except OSError:
            covered = False
            break
    if covered:
        bail()          # already measured as it stands — nothing to route

    rel_man = os.path.relpath(man_path, root)
    sys.stderr.write(
        "zuvo: this spec is tracked by %s, and running it bare only tells you it is green.\n"
        "Use the instrument instead — it runs this same suite plus the coverage gate, scoped\n"
        "coverage and the mutation runner in ONE pass, and records what it measured:\n\n"
        "  ~/.zuvo/verify-tests --manifest %s\n\n"
        "Give the tool call a timeout of 600000. Measured on the benchmark: runs that never\n"
        "reached this command finished at the no-skill control's score on two of five files.\n"
        "If you really need a bare run (debugging one case), set ZUVO_ALLOW_BARE_TESTS=1.\n"
        % (rel_man, rel_man))
    sys.exit(BLOCK)

bail()
PY
rc=$?
set -e
# Only 2 is meaningful to PreToolUse. Anything else — a python crash, a missing interpreter, an
# unhandled exception — must not become a block: this hook sits in front of every Bash call the
# agent makes, so its failure mode has to be silence.
[ "$rc" = 2 ] && exit 2
exit 0
