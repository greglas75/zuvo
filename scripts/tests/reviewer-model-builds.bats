#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

# PER-FILE dist root (B-DIST-BUILD-RACE). The wipe below is necessary — every assertion must run
# against files THIS test's build materialized, never a tree left by a sibling — but wiping the
# SHARED $REPO_ROOT/dist is what made it a race: test-install-wiring.sh and test-kimi-build.sh
# build into the same tree, so this setup() could truncate a directory another file was asserting
# against. Red about twice in ten suite runs, and it produced two wrong conclusions in one session
# (a bisect that blamed an innocent registry change, and a "regression" that was not one) — both
# only caught by re-running in a git worktree with its own dist/.
#
# The builders now honour ZUVO_DIST_ROOT, so this file gets its own directory and the wipe touches
# nothing anyone else can see. Unset elsewhere, the default is the historical $REPO_ROOT/dist.
setup_file() {
  # TWO variables on purpose. ZUVO_DIST_SANDBOX is the directory this file created and is the ONLY
  # thing teardown removes; ZUVO_DIST_ROOT is where the builders write, INSIDE it.
  #
  # The first cut kept only ZUVO_DIST_ROOT and cleaned up with `rm -rf "$(dirname "$ZUVO_DIST_ROOT")"`.
  # That is a delete target computed by walking UP from a variable, and on 2026-08-18 a probe set
  # ZUVO_DIST_ROOT="$REPO_ROOT/dist" — so dirname was the repository, and teardown_file DELETED THE
  # WHOLE CHECKOUT, .git included. Recovered from an APFS local snapshot. Never derive an `rm -rf`
  # target with dirname; delete the exact path you created, and verify it is the one you created.
  ZUVO_DIST_SANDBOX="$(mktemp -d)"
  # A failed mktemp leaves this empty, which makes ZUVO_DIST_ROOT="/dist" — an absolute path the
  # builders would create and the setup() wipe would target. In a file whose teardown has already
  # destroyed this repository once, an unchecked mktemp is not a style point.
  [ -n "$ZUVO_DIST_SANDBOX" ] && [ -d "$ZUVO_DIST_SANDBOX" ] || {
    echo "setup_file: mktemp -d failed — refusing to run with an unset sandbox" >&2
    return 1
  }
  ZUVO_DIST_ROOT="$ZUVO_DIST_SANDBOX/dist"
  export ZUVO_DIST_SANDBOX ZUVO_DIST_ROOT
  mkdir -p "$ZUVO_DIST_ROOT"
}

teardown_file() {
  # Belt and braces on the guard above: remove it only if it still looks like the mktemp directory
  # this file made. A cleanup that cannot prove what it is deleting does not run.
  # The `$TMPDIR` arm is GONE, and its absence is the whole point. Written as
  #     /tmp/*|/var/folders/*|"${TMPDIR%/}"/*
  # an UNSET TMPDIR makes the third pattern `/*`, which matches every absolute path — so the guard
  # written specifically to stop this teardown deleting the repository would have permitted exactly
  # that. Verified: with `env -u TMPDIR`, ZUVO_DIST_SANDBOX=<repo root> MATCHED. Found by the
  # adversarial pass over the commit that added the guard, hours after the unguarded version had
  # already destroyed this checkout once.
  #
  # A guard whose safety depends on an environment variable being set is not a guard. These two
  # literal prefixes are where `mktemp -d` puts things on macOS and Linux; anything else is refused
  # out loud rather than removed.
  case "${ZUVO_DIST_SANDBOX:-}" in
    /tmp/*|/var/folders/*) [ -d "$ZUVO_DIST_SANDBOX" ] && rm -rf "$ZUVO_DIST_SANDBOX" ;;
    *) echo "teardown_file: refusing to remove unexpected sandbox '${ZUVO_DIST_SANDBOX:-}'" >&2 ;;
  esac
}

setup() {
  rm -rf "$ZUVO_DIST_ROOT/codex" "$ZUVO_DIST_ROOT/cursor" "$ZUVO_DIST_ROOT/antigravity"
}

# ── The two guards above, FORCED ────────────────────────────────────────────────────────────────
# Both exist because of the 2026-08-18 whole-checkout deletion, and neither ran on a normal suite
# run: mktemp always succeeds and the sandbox always sits under a mktemp prefix. The cases at the
# end of this file drive them with the inputs they exist for. Each call runs inside bats' `run`
# subshell, so the file-level sandbox that teardown_file removes for real is never touched.
#
# The probe for "an existing directory outside /tmp and /var/folders" has to live somewhere real
# and absolute: a mktemp dir under the checkout's gitignored .zuvo/ (physical path — a checkout
# reached through /tmp → /private/tmp is still outside the literal prefixes). It is removed by
# teardown() below, which deletes only a path of exactly that shape.
GUARD_PROBE=""
GUARD_PARENT_CREATED=""
guard_parent() { printf '%s/.zuvo' "$(cd "$REPO_ROOT" && pwd -P)"; }
make_guard_probe() {
  local parent
  parent="$(guard_parent)"
  if [ ! -d "$parent" ]; then mkdir "$parent" && GUARD_PARENT_CREATED="$parent"; fi
  GUARD_PROBE="$(mktemp -d "$parent/guard-probe.XXXXXX")"
  if [ -z "$GUARD_PROBE" ] || [ ! -d "$GUARD_PROBE" ]; then
    echo "make_guard_probe: mktemp -d under $parent failed" >&2
    return 1
  fi
  case "$GUARD_PROBE" in
    /tmp/*|/var/folders/*) skip "this checkout lives under a mktemp prefix ($GUARD_PROBE): no outside path to probe with" ;;
  esac
  echo keep > "$GUARD_PROBE/sentinel"
}
teardown() {
  case "${GUARD_PROBE:-}" in
    "$(guard_parent)"/guard-probe.?*) rm -rf -- "$GUARD_PROBE" ;;
  esac
  if [ -n "${GUARD_PARENT_CREATED:-}" ]; then rmdir -- "$GUARD_PARENT_CREATED" 2>/dev/null || true; fi
  GUARD_PROBE=""; GUARD_PARENT_CREATED=""
}
# output_has <text> — a failing assertion that prints what it looked at ([[ ]] alone is not an
# errexit trigger on every bash bats may run under).
output_has() {
  case "$output" in *"$1"*) return 0 ;; esac
  printf 'expected output to contain: %s\nactual output: %s\n' "$1" "$output" >&2
  return 1
}
output_lacks() {
  case "$output" in *"$1"*) printf 'output must not contain: %s\nactual output: %s\n' "$1" "$output" >&2; return 1 ;; esac
  return 0
}
# teardown_as <TMPDIR value | unset> <sandbox> — teardown_file against that sandbox.
teardown_as() {
  if [ "$1" = unset ]; then unset TMPDIR; else TMPDIR="$1"; export TMPDIR; fi
  ZUVO_DIST_SANDBOX="$2"
  teardown_file
}
# teardown_rm_spy <sandbox> — teardown_file with `rm` replaced by a recorder, TMPDIR unset: for
# targets a regressed guard would really delete (the repository itself), nothing can be removed.
# Recorded twice over: the shell function catches a bare `rm`, and a recording `rm` first on PATH
# catches `command rm`, which skips functions. Only an absolute path (/bin/rm) gets past both — which is
# why the test below proves the recorder intercepts BEFORE it hands teardown_file a dangerous target.
teardown_rm_spy() {
  unset TMPDIR
  mkdir -p "$BATS_TEST_TMPDIR/rm-spy"
  printf '#!/bin/sh\nprintf "RM-CALLED %%s\\n" "$*"\n' > "$BATS_TEST_TMPDIR/rm-spy/rm"
  chmod +x "$BATS_TEST_TMPDIR/rm-spy/rm"
  PATH="$BATS_TEST_TMPDIR/rm-spy:$PATH"
  rm() { printf 'RM-CALLED %s\n' "$*"; }
  ZUVO_DIST_SANDBOX="$1"
  teardown_file
}
# setup_file_with_shims <dir> — setup_file with <dir> first on PATH and no sandbox inherited;
# reports what it left in the two variables.
setup_file_with_shims() {
  local rc=0
  PATH="$1:$PATH"
  unset ZUVO_DIST_SANDBOX ZUVO_DIST_ROOT
  setup_file || rc=$?
  echo "AFTER sandbox=[${ZUVO_DIST_SANDBOX:-}] root=[${ZUVO_DIST_ROOT:-}]"
  return "$rc"
}

@test "Codex build materializes reviewer lanes to concrete models" {
  run bash "$REPO_ROOT/tests/lib/dist-build.sh" codex
  [ "$status" -eq 0 ]

  local primary="$ZUVO_DIST_ROOT/codex/agents/write-tests-blind-coverage-auditor.toml"
  local alt="$ZUVO_DIST_ROOT/codex/agents/write-tests-blind-coverage-auditor-alt.toml"
  local fallback_primary="$ZUVO_DIST_ROOT/codex/agents/write-tests-adversarial-test-reviewer.toml"
  local fallback_alt="$ZUVO_DIST_ROOT/codex/agents/write-tests-adversarial-test-reviewer-alt.toml"

  [ -f "$primary" ]
  [ -f "$alt" ]
  [ -f "$fallback_primary" ]
  [ -f "$fallback_alt" ]
  run rg -n 'review-primary|review-alt' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 1 ]
  # DERIVE the expected models from the router instead of hardcoding them. The old
  # literals ("gpt-5.4" / "gpt-5.3-codex") were a FOURTH copy of the model list,
  # alongside model-registry.sh, the router table and the build itself — and
  # gpt-5.3-codex had already left the registry a generation earlier, so this
  # asserted a pairing that could no longer be produced. What is worth pinning is
  # that the BUILD and the ROUTER agree; a model rename should move both together
  # or fail here, not be re-typed in a third place.
  # Strip EVERY host marker, not just two. reviewer-model-route.sh picks the reviewer from
  # the detected HOST, so an ambient ANTIGRAVITY_SESSION_ID / VSCODE_GIT_ASKPASS_MAIN makes
  # these two probes answer with Gemini or Claude ids and the Codex assertions below fail —
  # the test's result would depend on WHICH IDE ran the suite. reviewer-model-route.bats:14
  # already strips the full set; this file stripped a subset until 2026-08-11.
  # The last three -u are the Codex Desktop signals the router now reads (zms_is_codex_host).
  # -u CLAUDE_MODEL / -u CODEX_MODEL: the router checks the Claude branch BEFORE the Codex
  # branch, so an ambient CLAUDE_MODEL (e.g. from whatever agent runs this suite) misroutes
  # every case here to platform=claude regardless of ZUVO_CODEX_MODEL. CODEX_MODEL is unused
  # by this router directly but cleared for the same who-ran-it independence as everywhere
  # else in this pair of files. PATH is pinned rather than inherited: the Codex branch this
  # helper exercises needs nothing on PATH (no external command runs before routing_status is
  # decided — see the router's own PATH=/nonexistent comment), so a narrow, explicit PATH
  # proves that rather than assuming it.
  # --fallback + ZUVO_CLAUDE_BIN=/nonexistent (plan C Task 1): a Codex host now routes CROSS-VENDOR to
  # Opus whenever a `claude` is installed, which is not what the Codex build materializes — the build's
  # agent lanes are the SAME-VENDOR pair. --fallback asks the router for exactly that in-family row,
  # whatever is installed on the machine running the suite; the seams are pinned so neither a claude on
  # /usr/bin (the farm ships one) nor the Codex app can decide it.
  route_codex() {
    env -u CLAUDECODE -u CLAUDE_MODEL -u CODEX_MODEL -u CODEX_SANDBOX -u ANTIGRAVITY_SESSION_ID \
        -u VSCODE_GIT_ASKPASS_MAIN -u CLAUDE_CODE_ENTRYPOINT \
        -u CODEX_SHELL -u CODEX_INTERNAL_ORIGINATOR_OVERRIDE -u __CFBundleIdentifier \
        "ZUVO_CODEX_MODEL=$1" ZUVO_CLAUDE_BIN=/nonexistent ZUVO_CODEX_BIN=/nonexistent \
        ZUVO_CODEX_APP_BIN=/nonexistent PATH=/usr/bin:/bin \
        bash "$REPO_ROOT/scripts/reviewer-model-route.sh" --fallback | sed -n 's/^reviewer_model=//p'
  }
  local want_primary want_alt
  want_primary="$(route_codex gpt-5.5)"
  want_alt="$(route_codex gpt-5.4)"
  [ -n "$want_primary" ]
  [ -n "$want_alt" ]
  [ "$want_primary" != "$want_alt" ]   # a build that collapsed both lanes to one model is broken
  run rg -n "model = \"$want_primary\"" "$primary" "$fallback_primary"
  [ "$status" -eq 0 ]
  run rg -n "model = \"$want_alt\"" "$alt" "$fallback_alt"
  [ "$status" -eq 0 ]

  # ANCHOR TO THE REGISTRY, not only to router<->build self-consistency. Deriving both
  # sides from the router proves those two agree, but says nothing about whether either
  # matches model-registry.sh — the actual source of truth. One find-and-replace typo
  # applied to the router AND the build together would keep them agreeing while both
  # drifted off the registry, and the check above would still pass. That is the narrow
  # circularity this closes: every model the build emits must be a model the registry
  # actually names.
  local reg_known
  # shellcheck disable=SC1091
  reg_known="$(bash -c '. "$1"/shared/includes/model-registry.sh
      printf "%s %s %s" "$ZUVO_MODEL_CODEX_PRIMARY" "$ZUVO_MODEL_CODEX_ALT" "$ZUVO_MODEL_CODEX_REVIEW_ALT"' _ "$REPO_ROOT")"
  [ -n "${reg_known// /}" ]
  # Membership, not positional equality: the registry names the LANES, the router decides
  # which lane reviews which writer, so pinning want_primary=="$reg_primary" would
  # over-specify routing policy and break on a legitimate lane swap. What must hold is
  # that the build cannot emit a model the registry has never heard of — the check that
  # caught gpt-5.5 being dispatched while absent from the "single source of model ids".
  [[ " $reg_known " == *" $want_primary "* ]] || false
  [[ " $reg_known " == *" $want_alt "* ]] || false
}

@test "Cursor build degrades both reviewer lanes to inherit" {
  run bash "$REPO_ROOT/tests/lib/dist-build.sh" cursor
  [ "$status" -eq 0 ]

  local primary="$ZUVO_DIST_ROOT/cursor/agents/write-tests-blind-coverage-auditor.md"
  local alt="$ZUVO_DIST_ROOT/cursor/agents/write-tests-blind-coverage-auditor-alt.md"
  local fallback_primary="$ZUVO_DIST_ROOT/cursor/agents/write-tests-adversarial-test-reviewer.md"
  local fallback_alt="$ZUVO_DIST_ROOT/cursor/agents/write-tests-adversarial-test-reviewer-alt.md"

  [ -f "$primary" ]
  [ -f "$alt" ]
  [ -f "$fallback_primary" ]
  [ -f "$fallback_alt" ]
  run rg -n 'review-primary|review-alt' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 1 ]
  run rg -n '^model: inherit$' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 0 ]
}

@test "Antigravity build materializes reviewer lanes to Gemini tiers" {
  run bash "$REPO_ROOT/tests/lib/dist-build.sh" antigravity
  [ "$status" -eq 0 ]

  local primary="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/blind-coverage-auditor.md"
  local alt="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/blind-coverage-auditor-alt.md"
  local fallback_primary="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/adversarial-test-reviewer.md"
  local fallback_alt="$ZUVO_DIST_ROOT/antigravity/skills/write-tests/agents/adversarial-test-reviewer-alt.md"

  [ -f "$primary" ]
  [ -f "$alt" ]
  [ -f "$fallback_primary" ]
  [ -f "$fallback_alt" ]
  run rg -n 'review-primary|review-alt' "$primary" "$alt" "$fallback_primary" "$fallback_alt"
  [ "$status" -eq 1 ]
  run rg -n '^model: gemini-3.1-pro-high$' "$primary" "$fallback_primary"
  [ "$status" -eq 0 ]
  run rg -n '^model: gemini-3.1-pro-low$' "$alt" "$fallback_alt"
  [ "$status" -eq 0 ]
}

@test "teardown_file guard: an existing sandbox outside /tmp and /var/folders is refused and survives (TMPDIR unset, or pointing at it)" {
  make_guard_probe
  # TMPDIR unset: the exact environment in which the removed `"${TMPDIR%/}"/*` arm became `/*`.
  run teardown_as unset "$GUARD_PROBE"
  [ "$status" -eq 0 ]
  output_has "teardown_file: refusing to remove unexpected sandbox '$GUARD_PROBE'"
  [ -f "$GUARD_PROBE/sentinel" ]
  # TMPDIR pointing at the probe's parent: the guard must not trust TMPDIR in either direction.
  run teardown_as "${GUARD_PROBE%/*}" "$GUARD_PROBE"
  [ "$status" -eq 0 ]
  output_has "teardown_file: refusing to remove unexpected sandbox '$GUARD_PROBE'"
  [ -f "$GUARD_PROBE/sentinel" ]
}

@test "teardown_file guard: the repository, its dist and .git, /, a relative path and an empty value are never removed" {
  local target ctl
  # Control FIRST: the recorder DOES see the removal of a sandbox under a mktemp prefix, so the
  # RM-CALLED checks below are able to fail. First, because it is the only proof the recorder
  # intercepts at all: were teardown_file's rm respelled past it AND the guard regressed, the loop
  # below would really delete the checkout — a control run after it would report that too late.
  ctl="$(mktemp -d /tmp/zuvo-guard-ctl.XXXXXX)"
  run teardown_rm_spy "$ctl"
  command rm -rf -- "$ctl"
  output_has "RM-CALLED -rf $ctl" || return 1
  output_lacks "refusing to remove" || return 1
  for target in "$REPO_ROOT" "$REPO_ROOT/dist" "$REPO_ROOT/.git" / dist ""; do
    run teardown_rm_spy "$target"
    [ "$status" -eq 0 ]
    output_has "teardown_file: refusing to remove unexpected sandbox '$target'"
    output_lacks "RM-CALLED"
  done
}

@test "setup_file guard: a failing mktemp -d, or one naming no directory, fails closed and creates nothing" {
  local shim="$BATS_TEST_TMPDIR/shim" calls="$BATS_TEST_TMPDIR/mkdir.calls" variant
  mkdir -p "$shim"
  # mkdir RECORDS instead of creating: a setup_file that got past its guard would `mkdir -p /dist`.
  printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$calls" > "$shim/mkdir"
  chmod +x "$shim/mkdir"
  for variant in 'exit 1' 'exit 0' 'echo /nonexistent/zuvo-dist-sandbox'; do
    printf '#!/bin/sh\n%s\n' "$variant" > "$shim/mktemp"
    chmod +x "$shim/mktemp"
    run setup_file_with_shims "$shim"
    [ "$status" -ne 0 ]
    output_has "setup_file: mktemp -d failed — refusing to run with an unset sandbox"
    output_has "root=[]"
    [ ! -e "$calls" ]
  done
}
