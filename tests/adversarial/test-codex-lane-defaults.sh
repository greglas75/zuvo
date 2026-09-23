#!/usr/bin/env bash
# test-codex-lane-defaults.sh — the codex lanes' model, their effort dial, and the CLI guard.
#
# Three things here are only ever exercised on a host, which is why they get a test instead:
#
# 1. EFFORT IS PER-LANE. The two lanes deliberately run different dials (sol at `none`, luna at
#    `medium`) because the 2026-09-23 benchmark found the dial runs BACKWARDS for panel value:
#    sol at `medium` scored 100% precision and contributed zero defects the rest of the set
#    misses. A single global effort would collapse both lanes onto one setting and quietly undo
#    that result — the run would still succeed, which is what makes it worth pinning.
#
# 2. THE CLI GUARD IS A CHAIN. gpt-6 ids need codex CLI >=0.156; on an older CLI they fail as an
#    opaque 400 that reads like an ACCOUNT problem ("not supported when using Codex with a
#    ChatGPT account") — a diagnosis that was actually made, out loud, and was wrong. The guard
#    downgrades gpt-6 -> gpt-5.6-sol -> gpt-5.5, and a chain that stops one rung short is
#    invisible: it just picks a model that also fails.
#
# 3. An unparsable version must count as TOO OLD. Wrongly downgrading a new CLI costs one
#    generation; wrongly keeping a new id on an old CLI costs EVERY review.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1

CLTMP="$HERE/.tmp/codexlane.$$"; mkdir -p "$CLTMP/bin"
cleanup_cl() { rm -rf "$CLTMP"; }
trap cleanup_cl EXIT

# The guard shells out to `codex --version`. A fake one lets us test every rung without owning
# five CLI installs — and without the test depending on whichever version this host happens to
# have, which would make it pass or fail for reasons that are not the code.
fake_codex() { # fake_codex <version-string-or-empty>
  if [ -z "$1" ]; then
    printf '#!/bin/sh\nexit 1\n' > "$CLTMP/bin/codex"
  else
    printf '#!/bin/sh\necho "codex-cli %s"\n' "$1" > "$CLTMP/bin/codex"
  fi
  chmod +x "$CLTMP/bin/codex"
}

guard() { # guard <model> -> what the guard resolves it to
  PATH="$CLTMP/bin:$PATH" bash -c '
    eval "$(sed -n "/^codex_cli_guard()/,/^}/p" "$1")"
    codex_cli_guard "$2" TEST_OVERRIDE' _ "$ADV" "$1" 2>/dev/null
}

# ─── 1. a current CLI keeps the benchmarked ids ───────────────────────────
start_test "cx.1 codex CLI 0.156 runs the gpt-6 ids unchanged"
fake_codex "0.156.1"
assert_eq "gpt-6-sol"  "$(guard gpt-6-sol)"  "gpt-6-sol survives on a current CLI"
assert_eq "gpt-6-luna" "$(guard gpt-6-luna)" "gpt-6-luna survives on a current CLI"

# ─── 2. an older CLI downgrades ONE rung, not to the floor ────────────────
start_test "cx.2 CLI 0.150 downgrades gpt-6 to gpt-5.6-sol (which it can run)"
fake_codex "0.150.0"
assert_eq "gpt-5.6-sol" "$(guard gpt-6-sol)" "one rung down, not straight to the floor"

# ─── 3. THE CHAIN: a CLI too old for BOTH must reach the floor ────────────
# This is the rung that a hand-written guard forgets. 0.140 cannot run gpt-6 (needs 156) and
# cannot run gpt-5.6 either (needs 144), so stopping at gpt-5.6-sol would pick a second model
# that also fails — and report success while doing it.
start_test "cx.3 CLI 0.140 falls all the way through to gpt-5.5"
fake_codex "0.140.0"
assert_eq "gpt-5.5" "$(guard gpt-6-sol)"   "gpt-6 -> gpt-5.6-sol -> gpt-5.5"
assert_eq "gpt-5.5" "$(guard gpt-5.6-sol)" "gpt-5.6 -> gpt-5.5 directly"

# ─── 4. an unparsable version counts as too old ───────────────────────────
start_test "cx.4 a CLI whose version cannot be read is treated as too old"
fake_codex ""
assert_eq "gpt-5.5" "$(guard gpt-6-sol)" "no version -> safest model, not the newest"

# ─── 5. a model outside the guarded families passes through untouched ─────
start_test "cx.5 an unguarded model id is returned as-is"
fake_codex "0.156.1"
assert_eq "gpt-5.5" "$(guard gpt-5.5)" "gpt-5.5 is not downgraded by its own fallback rule"

# ─── 6. the lanes carry the benchmarked defaults ──────────────────────────
start_test "cx.6 lane defaults match the 2026-09-23 benchmark"
REG="$ROOT/shared/includes/model-registry.sh"
assert_contains "$(cat "$REG")" 'ZUVO_MODEL_CODEX_PRIMARY:-gpt-6-sol'   "primary lane = gpt-6-sol"
assert_contains "$(cat "$REG")" 'ZUVO_MODEL_CODEX_ALT:-gpt-6-luna'      "alt lane = gpt-6-luna"
assert_contains "$(cat "$REG")" 'ZUVO_CODEX_EFFORT_PRIMARY:-none'       "primary effort = none"
assert_contains "$(cat "$REG")" 'ZUVO_CODEX_EFFORT_ALT:-medium'         "alt effort = medium"

# ─── 7. the two efforts are INDEPENDENT, not one global ───────────────────
# The wrappers must read a per-lane variable first. If both collapsed onto ZUVO_CODEX_EFFORT the
# reviews would still run — with the wrong dial on one lane and nothing to show for it.
start_test "cx.7 each lane reads its own effort variable"
src=$(cat "$ADV")
assert_contains "$src" 'ZUVO_CODEX_EFFORT_PRIMARY:-${ZUVO_CODEX_EFFORT:-none}'   "primary: own var, then global, then none"
assert_contains "$src" 'ZUVO_CODEX_EFFORT_ALT:-${ZUVO_CODEX_EFFORT:-medium}'     "alt: own var, then global, then medium"
