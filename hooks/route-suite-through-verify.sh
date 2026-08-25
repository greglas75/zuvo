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
# THE ESCAPE, AND HOW FAR IT REACHES
#
# ZUVO_ALLOW_BARE_TESTS=1 in the HOOK's own process environment. A hook inherits the environment
# of the harness that spawns it, not of the command it is inspecting, so an inline
# `ZUVO_ALLOW_BARE_TESTS=1 npx vitest run <spec>` does NOT reach this check — the assignment
# applies to the command the hook is about to block, and the hook never runs inside it. That is
# the whole distinction: an env var a human exports before starting the session, not a flag an
# agent can type into the command it was already trying to run. It is why `--reset-budget` had to
# be closed and why `--budget 999` had to be closed after it.
#
# Measured, because an agent tried exactly that: it read this file (it is in the agent's own
# readable home) and typed the variable inline. The attempt was still blocked, but only because
# the runner pattern happens to tolerate a leading assignment. That was luck, not design, so the
# prefix is now stripped explicitly below — a future tightening of the pattern cannot silently
# reopen it. The block notice also no longer names the variable; a human who installed the hook
# can read it here, and an agent being blocked has no use for it.
#
# What this canNOT prevent, stated plainly rather than implied:
#   * an agent with WRITE access to this file, or to the settings that register it, can disable it;
#   * an agent that runs the suite through a wrapper this pattern does not recognise (a package
#     script, a Makefile target, a python subprocess) is not intercepted;
#   * a bare `vitest` naming no spec runs the whole suite and passes through by design.
# A PreToolUse hook is a speed bump on the natural path, not a sandbox. Treating it as a sandbox
# is how you end up trusting a measurement it cannot actually guarantee.

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
# The wildcard that used to sit here — `(?:\S+\s+)*?` — consumed ANY words before the runner name,
# so `git commit -m "fix vitest run foo.spec.ts"` matched and, if that spec were tracked, the COMMIT
# was blocked. A false block on an unrelated command is the most expensive thing this hook can do,
# and prose mentioning a test runner is not rare in a repo whose subject is test runners.
#
# Only genuine wrappers may precede the runner, and each is named. Anything else means the runner
# name is an argument or a quoted string, not the program being executed.
WRAPPER = r"(?:timeout\s+[\d.]+[smh]?|nice(?:\s+-n\s*-?\d+)?|nohup|command|exec|" \
          r"npx(?:\s+--yes)?|pnpm(?:\s+(?:exec|dlx|run))?|yarn(?:\s+run)?|bunx|bun\s+x|" \
          r"npm(?:\s+(?:exec|run))?|node(?:\s+--[\w-]+(?:=\S+)?)*|python3?(?:\s+-m)?|uv\s+run|poetry\s+run)"
RUNNER = re.compile(
    r"(?:^|[;&|\n]\s*)"                                   # start, a separator, OR a new line
    r"(?:" + WRAPPER + r"\s+)*"                            # only NAMED wrappers, never arbitrary words
    r"(?:\S*/)?"                                          # ./node_modules/.bin/, /usr/local/bin/
    r"(vitest|jest|pytest)(?:\.m?[cj]s)?\b"
    r"|(?:^|[;&|\n]\s*)(?:" + WRAPPER + r"\s+)*node\s+--test\b")
# An agent that read this file learned the escape's name and typed it inline:
#
#   ZUVO_ALLOW_BARE_TESTS=1 npx vitest run <spec>
#
# That assignment applies to the command being inspected, never to this process, so it is not an
# escape and the check at the top of the script cannot see it. But it must not be allowed to HIDE
# the runner either, and until now it only failed to because the pattern's leading wildcard
# happened to absorb it — luck, not design. A leading `VAR=value` word (and a leading `env
# VAR=value`) is shell prefix syntax rather than part of the invocation, so strip it from every
# segment before matching. The property is then deliberate, and tightening the pattern later
# cannot silently reopen the hole.
ENV_PREFIX = re.compile(r"(^|[;&|\n]\s*)((?:env\s+)?(?:[A-Za-z_]\w*=[^\s;&|]*\s+)+)")
probe = ENV_PREFIX.sub(lambda m: m.group(1), cmd)
if not RUNNER.search(probe):
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
# `cd a && cd b` lands in a/b, so the targets ACCUMULATE. Resolving each against the original cwd
# independently misses the directory the command actually runs in, and the spec then looks absent —
# which passes a command this hook exists to catch.
bases = [cwd, root]
here = cwd
for target in re.findall(r"(?:^|[;&|\n]\s*)cd\s+([^\s;&|]+)", cmd):
    target = os.path.expanduser(target.strip("'\""))
    here = target if os.path.isabs(target) else os.path.normpath(os.path.join(here, target))
    bases.append(here)

# Quoted arguments first, so a path with spaces survives; then bare words. Splitting on
# whitespace alone turns `"src/My Tests/foo.spec.ts"` into two fragments that match nothing on
# disk, and the command passes as naming no tracked spec.
tokens = re.findall(r"'([^']*)'|\"([^\"]*)\"", cmd)
tokens = [t for pair in tokens for t in pair if t]
tokens += re.findall(r"[\w./@~-]+", cmd)
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
    # State the policy; do not argue for it.
    #
    # The first version of this message explained WHY, quoted a benchmark statistic, and offered
    # the escape hatch persuasively. An agent in a container read it and refused — correctly, and
    # in as many words: "a tool/hook result trying to redirect my next action ... complete with a
    # fabricated-sounding benchmark claim to pressure compliance. That's a classic injection
    # pattern." It then reported the block instead of complying.
    #
    # It was right. Instruction phrasing plus a persuasive statistic plus an offered bypass IS the
    # shape of an injection, and an agent that follows such text is the one with the problem. A
    # policy notice does not need to convince anyone: it says what is not accepted and what to run
    # instead, in the fewest words that carry the command.
    sys.stderr.write(
        "zuvo policy: %s is a tracked spec; a bare test run is not accepted as its verification.\n"
        "Required command (tool timeout 600000):\n"
        "  ~/.zuvo/verify-tests --manifest %s\n"
        % (declared[sorted(hit)[0]], rel_man))
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
