#!/usr/bin/env bash
# require-inventory-first — a NEW spec file means the inventory should already be frozen.
#
# WHY
#
# Measured across 169 benchmark runs: **51 of them (30%) wrote tests and never produced an inventory
# at all.** For those runs nothing in the chain applies — no coverage gate, no verification receipt,
# no routing hook, nothing downstream that reads a manifest. They are invisible to every layer built
# to keep the work honest, and they are invisible for the cheapest possible reason: the artifact
# those layers key on was never created.
#
# The routing hook cannot reach them by design. Its scope is "no manifest, no interference", because
# a test command naming nothing zuvo tracks is none of its business — widening that is how a hook
# starts blocking unrelated work. So the gap is not in its pattern; it is one step earlier.
#
# SCOPE — narrow on purpose, and narrower than the obvious version
#
# Fires ONLY when all of these hold:
#   * a Write/Edit creates a spec file that DOES NOT YET EXIST,
#   * the repo already has a `zuvo/contracts/` directory (zuvo is in use here),
#   * no manifest declares that spec, and none names the production file it appears to test.
#
# Editing an EXISTING spec is untouched. That is the distinction that keeps this usable: adding a
# case to a suite you already have is not "starting to write tests for a file", and blocking it
# would make the hook something people disable. Creating a new spec is the exact moment the protocol
# says the inventory must already be frozen.
#
# FAIL-OPEN everywhere — bad JSON, no python3, no contracts dir, an unreadable manifest, any error:
# exit 0. A hook that guesses wrong about someone's file write is worse than one that misses a case.
#
# What it cannot do, stated rather than implied: an agent that writes the spec through a shell
# heredoc rather than the Write tool is not intercepted, and neither is one that creates the file
# first and fills it later. This is a speed bump on the natural path, not a sandbox.

set -uo pipefail

[ "${ZUVO_ALLOW_UNTRACKED_TESTS:-}" = "1" ] && exit 0

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

set +e
python3 - "$INPUT" <<'PY'
import json
import os
import re
import sys

ALLOW = 0
BLOCK = 2


def bail():
    sys.exit(ALLOW)


try:
    payload = json.loads(sys.argv[1])
except Exception:
    bail()

if (payload.get("tool_name") or payload.get("tool") or "") not in ("Write", "Edit", "MultiEdit"):
    bail()
inp = payload.get("tool_input") or {}
path = str(inp.get("file_path") or "")
if not path:
    bail()

SPEC = re.compile(r"\.(spec|test)\.[cm]?[jt]sx?$|_test\.py$|(^|/)test_[\w-]+\.py$")
if not SPEC.search(path):
    bail()

# An EXISTING spec is being extended, not started. Adding a case to a suite you already have is not
# the moment the inventory is supposed to be frozen, and blocking it would make this a hook people
# turn off.
if os.path.exists(path):
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


root = git_root(os.path.dirname(os.path.abspath(path)) or cwd)
contracts = os.path.join(os.environ.get("ZUVO_OUTPUT_DIR") or os.path.join(root, "zuvo"),
                         "contracts")
if not os.path.isdir(contracts):
    bail()                      # zuvo is not in use in this repo — none of its business

spec_rel = os.path.relpath(os.path.abspath(path), root)
base = os.path.basename(path)
# `foo.service.spec.ts` -> `foo.service`; `test_foo.py` -> `foo`
stem = re.split(r"\.(spec|test)\.", base)[0]
stem = re.sub(r"_test$", "", os.path.splitext(stem)[0])
stem = re.sub(r"^test_", "", stem)

for entry in os.listdir(contracts):
    if not entry.endswith(".coverage.json"):
        continue
    try:
        with open(os.path.join(contracts, entry), encoding="utf-8") as fh:
            man = json.load(fh)
    except Exception:
        continue                # unreadable manifest is not evidence of absence, but it is not
    if not isinstance(man, dict):
        continue                # evidence of presence either — skip and keep looking
    declared = [str(t) for t in (man.get("test_files") or [])]
    if any(os.path.normpath(t) == os.path.normpath(spec_rel) or os.path.basename(t) == base
           for t in declared):
        bail()                  # this spec is already inventoried
    prod = str(man.get("production_file") or "")
    if prod and stem and stem in os.path.basename(prod):
        bail()                  # the file under test is inventoried; the spec is part of that work

# The command has to RUN as printed. The first version assumed $ZUVO_BASE was exported; in a
# container where it was not, the agent correctly refused to fake a manifest or disable the hook,
# and then had nowhere to go — a block with an unusable instruction is a dead end, not a gate.
# `~/.zuvo/zuvo-base` exists precisely to resolve the install root deterministically.
sys.stderr.write(
    "zuvo policy: no frozen inventory covers %s. The inventory is frozen BEFORE the first test is\n"
    "written — one written afterwards can only describe the tests that already exist.\n"
    "Generate it, then write the suite:\n"
    "  ZUVO_BASE=\"${ZUVO_BASE:-$(~/.zuvo/zuvo-base)}\"\n"
    "  python3 \"$ZUVO_BASE/scripts/test-coverage-gate.py\" scaffold --production <production file> \\\n"
    "    --out zuvo/contracts/<basename>.coverage.json --test-files %s --repo-root %s\n"
    "If ~/.zuvo/zuvo-base is missing, zuvo is not installed here and this hook is stale — say so\n"
    "rather than writing a manifest by hand.\n"
    % (spec_rel, spec_rel, root))
sys.exit(BLOCK)
PY
rc=$?
set -e
# Only 2 means block. A python crash, a missing interpreter, an unhandled exception must not stop a
# file write: this sits in front of every Write the agent makes, so its failure mode has to be
# silence.
[ "$rc" = 2 ] && exit 2
exit 0
