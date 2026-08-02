#!/usr/bin/env bash
# test-dev-push-gate.sh — Task 5: dev-push.sh Step-0 test gate.
#
# RED-first: authored BEFORE the `# >>> zuvo:test-gate` fenced block is inserted
# into scripts/dev-push.sh. Until the gate exists, the structural + behavioral
# assertions below fail loudly (intended RED evidence); once the gate is added,
# every assertion must pass.
#
# Asserts:
#   (a) STRUCTURAL — the fenced gate block exists and its start line sits AFTER
#                    the marketplace-dir check and BEFORE `# Step 1` AND before
#                    the first `cd "$ZUVO_DIR"` (no mutation runs before it).
#   (b) SYNTAX     — `bash -n scripts/dev-push.sh` passes.
#   (c) DIRECTION  — the gate guards on `!= "1"` applied to ZUVO_SKIP_TESTS
#                    (run-by-default, skip only on explicit opt-in — not inverted).
#   (d) BEHAVIORAL — extract the fenced block body and run it hermetically against
#                    a stub tests/run-all.sh + stub fail/warn/ok:
#                       (i)   no skip + failing suite  → non-zero exit + FAIL-CALLED
#                       (ii)  ZUVO_SKIP_TESTS=1        → exit 0 + WARN-CALLED (bypass)
#                       (iii) passing suite, no skip   → exit 0, no FAIL-CALLED
#   (e) PURITY     — running this test never mutates the repo working tree.
#
# Also asserts the `# >>> zuvo:marketplace-count` pre-flight block (Task 3), which
# rewrites-then-verifies the `<N> skills` strings in the SIBLING zuvo-marketplace
# repo — a 9th count location scripts/validate-skills.sh structurally cannot see:
#   (f.a) SELF-HEAL — a stub marketplace saying `51 skills` / `49 skills` with a
#                     stub `--print-count` of 57 ends up reading `57 skills` in
#                     BOTH files, and the block exits 0 (it heals; it never
#                     dead-ends on a mismatch).
#   (f.b) ORDERING  — the fence starts strictly BEFORE the first `git push origin
#                     main`; a fail after that push is an unrecoverable half-ship.
#   (f.c) NEAR-MISS — the adjacent `26 specialized agents` and the plugin-level
#                     `"category": "development"` key are byte-unchanged (asserted
#                     as a whole-file cmp against a count-only substitution).
#   (f.d) SURVIVOR  — an occurrence the rewrite cannot fix (read-only file) makes
#                     the block exit non-zero via fail(), naming that file.
#   (f.e) IDEMPOTENT— a second run over an already-correct marketplace is a no-op
#                     that also exits 0.
#
# The block was hardened after a cross-model adversarial review. These cases pin
# each fix; (f.f)–(f.m) are RED against the pre-hardening block, and (f.n) guards
# the substitution callback against a regression that version could not exhibit
# (it matched case-sensitively, so it had nothing to preserve):
#   (f.f) PULL      — a failed `git pull --rebase` ABORTS. Previously `|| true`
#                     swallowed it, the rewrite landed on a stale base, and Step 4
#                     committed + pushed that over the marketplace remote.
#   (f.g) ALLOWLIST — only .claude-plugin/marketplace.json and README.md are
#                     eligible. The old recursive os.walk rewrote every file in
#                     the tree, corrupting historical counts in a changelog.
#   (f.h) SYMLINK   — an allowlisted path that is a symlink is fatal; the old walk
#                     would write through it, potentially outside the repo.
#   (f.i) MISSING   — a renamed/moved count location is fatal, not a silent skip.
#   (f.j) MOVED     — an allowlisted file with no `<N> skills` string at all is
#                     fatal (the key moved); the old walk simply found nothing.
#   (f.k) NO-PARTIAL— writes happen only after every file has been read and
#                     checked, so a failure cannot leave one file rewritten and
#                     another not. Writes are atomic (temp file + os.replace), so
#                     an interrupted run cannot truncate marketplace.json.
#   (f.l) ZERO      — `057` is rejected; the old digit-only check accepted it.
#   (f.m) CASE      — `49 Skills` is matched case-insensitively and corrected with
#                     its original casing preserved.
#   (f.n) CALLBACK  — a match already equal to the wanted count is returned
#                     byte-identical (idempotence is structural, and casing of an
#                     already-correct occurrence is never mangled).
#
# A second adversarial pass found three more holes; (f.o)–(f.q) pin those fixes:
#   (f.o) DIR-PERM  — unwritability simulated at the DIRECTORY level (chmod 555 on
#                     the parent), not only via the target file's mode bits. POSIX
#                     rename() ignores the target's mode, so (f.d)/(f.k) actually
#                     depend on the block's os.access(W_OK) PRECHECK; this case
#                     stays RED even if that precheck is ever refactored away,
#                     because the temp file itself cannot be created.
#   (f.p) AMBIGUOUS — an allowlisted file carrying TWO differing counts (a live
#                     one plus a historical "grew from 49 skills") is fatal and
#                     names the file and the line numbers. The allowlist narrowed
#                     WHICH FILES may be rewritten; it never made the choice of
#                     WHICH OCCURRENCE semantically correct.
#   (f.q) DECIMAL   — "1.5 skills" is not a "5 skills" match. The old \b let the
#                     pattern start on the tail of a decimal and would have
#                     produced "1.57 skills".
#
# Harness invariants these cases depend on (all of them were previously weaker
# than they looked, so several assertions could pass without proving anything):
#   * both runners execute the extracted block under the SAME `set -euo pipefail`
#     that scripts/dev-push.sh declares before it — otherwise the test runs the
#     block with semantics production never uses;
#   * fence extraction requires exactly one >>>/<<< pair per fence;
#   * SKIP counts as FAILURE unless ALLOW_SKIP=1 — a safety case that silently
#     skips is a safety case that is not tested;
#   * every marketplace fixture is a real git repo WITH a real upstream, so the
#     block's `git pull --rebase` genuinely runs on the success path (the stub
#     fabricates only the FAILURE code) and git state is part of every snapshot.
#
# awk-fence extraction idiom adapted from tests/adversarial/test-skill-retro-wiring.sh
# (T7.3); mktemp+trap fixture idiom from tests/hooks/test-pipeline-gate-lib.sh.
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/dev-push.sh"

# HERMETIC GIT — every `git` this test runs (directly, and the real git the stub
# below delegates to) ignores the developer's ~/.gitconfig and /etc/gitconfig.
# Without this the throwaway fixture repos inherit the user's GLOBAL git settings,
# and this machine sets a global hook path: a fixture's own baseline commit then
# fired the user's real post-commit hook, which dropped `docs/review-queue.md`
# into the fixture. That left the fixture permanently dirty, and since the block's
# `git pull --rebase` is now REAL and fail-closed, half the cases below aborted on
# the pull and never reached the behaviour they exist to assert. Isolating the
# config also neutralises global commit.gpgsign, init.templateDir and aliases.
# (Fixture identity is configured locally in init_mkt_repo, so commits still work.)
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }
# A skipped SAFETY case reports success it never earned: every skip here guards a
# "must refuse to write" path, and on a box where the fixture cannot be made
# unwritable (root, or an exotic filesystem) the old skip() left the suite green
# while those paths went unexercised. Skipping is now a failure by default;
# ALLOW_SKIP=1 is the explicit, visible opt-out for such a box.
skip() {
  if [ "${ALLOW_SKIP:-0}" = "1" ]; then
    printf 'SKIP: %s (ALLOW_SKIP=1)\n' "$1"
  else
    printf 'FAIL (skipped safety case; set ALLOW_SKIP=1 to permit): %s\n' "$1"; fail=1
  fi
}

# Shell options scripts/dev-push.sh declares BEFORE either fenced block. Both
# extracted-block runners are prefixed with these: without them the test executes
# the block under different semantics than production (no -e, no -u, no
# pipefail), which can hide a real failure — e.g. an unset variable that would
# abort the release merely expands to empty here. Asserted against the script
# below, so the two can never silently drift apart.
SET_OPTS='set -euo pipefail'

# (e) baseline: capture the repo working-tree state up front; re-check at the end.
GIT_BEFORE="$( (cd "$ROOT" && git status --porcelain) 2>/dev/null )"

# throwaway fixtures: ONE mktemp root, every fixture is a subdir, cleanup is a
# single quoted `rm -rf "$TMP_ROOT"` — spaced-TMPDIR-safe by construction (no
# word-splitting over a space-separated path list). INT/TERM traps exit
# explicitly so an abort request terminates instead of resuming past cleanup.
TMP_ROOT="$(mktemp -d)"
_cleanup() { rm -rf "$TMP_ROOT"; }
trap _cleanup EXIT
trap '_cleanup; exit 1' INT TERM
FIX_FAIL="$TMP_ROOT/fail"
FIX_OK="$TMP_ROOT/ok"

if [ ! -f "$SCRIPT" ]; then
  bad "scripts/dev-push.sh not found at $SCRIPT"
  echo "SOME FAILED"; exit 1
fi

# ── fence markers: EXACTLY ONE PAIR, correctly ordered ────────────────────────
# `head -1` on each marker independently could pair a `>>>` with a `<<<` that
# belongs to a different (duplicated, or half-deleted) fence, and the awk
# extractor would then capture the wrong span — possibly real release commands.
# marker_lines() returns every line number for a marker; the pair is accepted
# only when there is exactly one of each AND the end follows the start.
marker_lines() { grep -Fn "$1" "$2" 2>/dev/null | cut -d: -f1; }
marker_count() { marker_lines "$1" "$2" | grep -c . ; }

fence_pair() {  # $1 = fence name, $2 = file → echoes "START END", rc 1 if unusable
  local _s _e _ns _ne
  _ns="$(marker_count "# >>> $1" "$2")"
  _ne="$(marker_count "# <<< $1" "$2")"
  if [ "$_ns" -ne 1 ] || [ "$_ne" -ne 1 ]; then
    printf 'MARKERS %s start=%s end=%s\n' "$1" "$_ns" "$_ne"
    return 1
  fi
  _s="$(marker_lines "# >>> $1" "$2")"
  # first `<<<` strictly after the `>>>` (with exactly one of each this is that
  # one; the filter is kept so the contract is expressed, not assumed)
  _e="$(marker_lines "# <<< $1" "$2" | awk -v s="$_s" '$1 > s {print; exit}')"
  [ -n "$_e" ] || { printf 'MARKERS %s end-before-start\n' "$1"; return 1; }
  printf '%s %s\n' "$_s" "$_e"
}

GATE_PAIR="$(fence_pair 'zuvo:test-gate' "$SCRIPT")" || true
GATE_START="$(printf '%s' "$GATE_PAIR" | grep -E '^[0-9]+ [0-9]+$' | cut -d' ' -f1)"
GATE_END="$(printf '%s' "$GATE_PAIR" | grep -E '^[0-9]+ [0-9]+$' | cut -d' ' -f2)"

# ── other line numbers (grep -F: fixed-string anchors, no regex surprises) ─────
MKT_LINE="$(grep -Fn 'Marketplace repo not found' "$SCRIPT" | head -1 | cut -d: -f1)"
STEP1_LINE="$(grep -Fn '# Step 1' "$SCRIPT" | head -1 | cut -d: -f1)"
CD_LINE="$(grep -Fn 'cd "$ZUVO_DIR"' "$SCRIPT" | head -1 | cut -d: -f1)"
SET_LINE="$(grep -Fn "$SET_OPTS" "$SCRIPT" | head -1 | cut -d: -f1)"

# ── (a) STRUCTURAL ────────────────────────────────────────────────────────────
if [ -n "$GATE_START" ] && [ -n "$GATE_END" ]; then
  pass "(a) fenced gate block present, exactly one >>>/<<< pair (lines $GATE_START/$GATE_END)"
else
  bad "(a) fenced gate block MISSING or not exactly one >>>/<<< pair — fence_pair said [$GATE_PAIR]"
fi

# The runners below prepend $SET_OPTS; that is only faithful if dev-push.sh really
# declares those options, and declares them BEFORE the fence.
if [ -n "$SET_LINE" ] && [ -n "$GATE_START" ] && [ "$SET_LINE" -lt "$GATE_START" ]; then
  pass "(a) dev-push.sh declares '$SET_OPTS' (line $SET_LINE) before the gate fence — runners mirror it"
else
  bad "(a) dev-push.sh must declare '$SET_OPTS' before the gate fence (set=$SET_LINE gate=$GATE_START); the runners' prefix would no longer match production"
fi

if [ -n "$GATE_START" ] && [ -n "$MKT_LINE" ] && [ "$GATE_START" -gt "$MKT_LINE" ]; then
  pass "(a) gate ($GATE_START) is AFTER the marketplace-dir check ($MKT_LINE)"
else
  bad "(a) gate ($GATE_START) must be AFTER marketplace check ($MKT_LINE)"
fi

if [ -n "$GATE_START" ] && [ -n "$STEP1_LINE" ] && [ "$GATE_START" -lt "$STEP1_LINE" ]; then
  pass "(a) gate ($GATE_START) is BEFORE '# Step 1' ($STEP1_LINE)"
else
  bad "(a) gate ($GATE_START) must be BEFORE '# Step 1' ($STEP1_LINE)"
fi

if [ -n "$GATE_START" ] && [ -n "$CD_LINE" ] && [ "$GATE_START" -lt "$CD_LINE" ]; then
  pass "(a) gate ($GATE_START) is BEFORE first cd \"\$ZUVO_DIR\" ($CD_LINE) — no mutation precedes it"
else
  bad "(a) gate ($GATE_START) must be BEFORE first cd \"\$ZUVO_DIR\" ($CD_LINE)"
fi

# ── (b) SYNTAX ────────────────────────────────────────────────────────────────
if bash -n "$SCRIPT" 2>/dev/null; then
  pass "(b) bash -n scripts/dev-push.sh passes"
else
  bad "(b) bash -n scripts/dev-push.sh FAILED"
fi

# ── HARD GUARD: never extract/execute an unbounded block ─────────────────────
# A missing/misordered end marker would make the awk below capture the REST of
# dev-push.sh — real release commands (push, tag, marketplace) — into the
# executed stub context. The structural failures above already recorded the RED
# evidence; stop here so the behavioral section is unreachable unless BOTH
# markers exist and the end marker follows the start marker.
if [ -z "$GATE_START" ] || [ -z "$GATE_END" ] || [ "$GATE_END" -le "$GATE_START" ]; then
  bad "gate markers absent/misordered (>>> '$GATE_START' <<< '$GATE_END') — refusing block extraction/execution"
  echo "----"
  echo "SOME FAILED"
  exit 1
fi

# ── extract the fenced block body (markers excluded) ──────────────────────────
BLOCK="$(awk '/# >>> zuvo:test-gate/{f=1;next} /# <<< zuvo:test-gate/{exit} f{print}' "$SCRIPT")"

# ── (c) CONDITIONAL DIRECTION ─────────────────────────────────────────────────
# Comment-stripped view: a trailing `# != "1"` comment must NOT satisfy this —
# only operational code counts. (Behavioral (d) verifies direction at runtime;
# this is the plan-mandated textual non-inversion check, made comment-proof.)
BLOCK_CODE="$(printf '%s\n' "$BLOCK" | sed 's/#.*$//')"
if [ -n "$BLOCK" ] && printf '%s\n' "$BLOCK_CODE" | grep -F 'ZUVO_SKIP_TESTS' | grep -Fq '!= "1"'; then
  pass "(c) gate guards ZUVO_SKIP_TESTS with != \"1\" (run-by-default, non-inverted)"
else
  bad "(c) gate must apply != \"1\" to ZUVO_SKIP_TESTS (block=[$BLOCK])"
fi

# ── (d) BEHAVIORAL: run the extracted block hermetically ──────────────────────
# stub run-all.sh: one fixture ZUVO_DIR whose suite fails, one whose suite passes.
mkdir -p "$FIX_FAIL/tests" "$FIX_OK/tests"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FIX_FAIL/tests/run-all.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX_OK/tests/run-all.sh"
chmod +x "$FIX_FAIL/tests/run-all.sh" "$FIX_OK/tests/run-all.sh"

# runner = production shell options + stub fail/warn/ok + the extracted block
# body. fail() exits 1 like the real helper; warn()/ok() are observable no-ops.
RUNNER="$TMP_ROOT/runner.sh"
{
  printf '%s\n' "$SET_OPTS"
  printf '%s\n' 'fail() { echo "FAIL-CALLED"; exit 1; }'
  printf '%s\n' 'warn() { echo "WARN-CALLED"; }'
  printf '%s\n' 'ok()   { echo "OK-CALLED"; }'
  printf '%s\n' "$BLOCK"
} > "$RUNNER"

# (d.i) no skip + failing suite → fail() fires: non-zero exit AND FAIL-CALLED
out_i="$(env -u ZUVO_SKIP_TESTS ZUVO_DIR="$FIX_FAIL" bash "$RUNNER" 2>&1)"; rc_i=$?
if [ "$rc_i" -ne 0 ] && printf '%s\n' "$out_i" | grep -Fq 'FAIL-CALLED'; then
  pass "(d.i) no-skip + failing suite → block fails via fail() (exit $rc_i, FAIL-CALLED)"
else
  bad "(d.i) expected non-zero exit + FAIL-CALLED; got rc=$rc_i out=[$out_i]"
fi

# (d.ii) ZUVO_SKIP_TESTS=1 → skip path: exit 0, WARN-CALLED, suite never invoked
out_ii="$(ZUVO_DIR="$FIX_FAIL" ZUVO_SKIP_TESTS=1 bash "$RUNNER" 2>&1)"; rc_ii=$?
if [ "$rc_ii" -eq 0 ] \
   && printf '%s\n' "$out_ii" | grep -Fq 'WARN-CALLED' \
   && ! printf '%s\n' "$out_ii" | grep -Fq 'FAIL-CALLED'; then
  pass "(d.ii) ZUVO_SKIP_TESTS=1 → bypass (exit 0, WARN-CALLED, failing suite skipped)"
else
  bad "(d.ii) expected exit 0 + WARN-CALLED + no FAIL-CALLED; got rc=$rc_ii out=[$out_ii]"
fi

# (d.iii) passing suite, no skip → exit 0, no FAIL-CALLED
out_iii="$(env -u ZUVO_SKIP_TESTS ZUVO_DIR="$FIX_OK" bash "$RUNNER" 2>&1)"; rc_iii=$?
if [ "$rc_iii" -eq 0 ] && ! printf '%s\n' "$out_iii" | grep -Fq 'FAIL-CALLED'; then
  pass "(d.iii) passing suite, no skip → exit 0, no FAIL-CALLED"
else
  bad "(d.iii) expected exit 0 + no FAIL-CALLED; got rc=$rc_iii out=[$out_iii]"
fi

# ── (f) MARKETPLACE COUNT: the `# >>> zuvo:marketplace-count` pre-flight ──────
MC_PAIR="$(fence_pair 'zuvo:marketplace-count' "$SCRIPT")" || true
MC_START="$(printf '%s' "$MC_PAIR" | grep -E '^[0-9]+ [0-9]+$' | cut -d' ' -f1)"
MC_END="$(printf '%s' "$MC_PAIR" | grep -E '^[0-9]+ [0-9]+$' | cut -d' ' -f2)"
# first OPERATIONAL push, ANCHORED — not filtered after the fact. The block's own
# rationale comments contain the literal `git push origin main`, and so does the
# file header; a post-hoc `grep -v ':[[:space:]]*#'` only removed the ones whose
# comment marker happened to be the first non-space character, so an indented or
# mid-line mention still matched and made this ordering assertion trivially true.
# Requiring the command at the START of the line (optionally indented) and
# followed by whitespace or EOL is the property we actually mean.
PUSH_LINE="$(grep -nE '^[[:space:]]*git push origin main([[:space:]]|$)' "$SCRIPT" | head -1 | cut -d: -f1)"

if [ -n "$MC_START" ] && [ -n "$MC_END" ] && [ "$MC_END" -gt "$MC_START" ]; then
  pass "(f) fenced marketplace-count block present, exactly one >>>/<<< pair (lines $MC_START/$MC_END)"
  MC_OK=1
else
  bad "(f) fenced marketplace-count block MISSING or not exactly one >>>/<<< pair — fence_pair said [$MC_PAIR]; refusing block extraction/execution"
  MC_OK=0
fi

if [ -n "$SET_LINE" ] && [ -n "$MC_START" ] && [ "$SET_LINE" -lt "$MC_START" ]; then
  pass "(f) '$SET_OPTS' (line $SET_LINE) precedes the marketplace-count fence — runner mirrors production"
else
  bad "(f) '$SET_OPTS' must precede the marketplace-count fence (set=$SET_LINE fence=$MC_START)"
fi

# (f.b) ORDERING — must precede the first push; a fail after it is unrecoverable.
if [ -n "$MC_START" ] && [ -n "$PUSH_LINE" ] && [ "$MC_START" -lt "$PUSH_LINE" ]; then
  pass "(f.b) marketplace-count fence ($MC_START) precedes first 'git push origin main' ($PUSH_LINE)"
else
  bad "(f.b) marketplace-count fence ($MC_START) must precede first 'git push origin main' ($PUSH_LINE)"
fi

if [ "$MC_OK" -eq 1 ]; then
  MC_BLOCK="$(awk '/# >>> zuvo:marketplace-count/{f=1;next} /# <<< zuvo:marketplace-count/{exit} f{print}' "$SCRIPT")"

  # ── `git` stub: fabricates ONLY the failure code ────────────────────────────
  # The block FAILS CLOSED on a refused `git pull --rebase`. The previous stub
  # short-circuited `pull` on BOTH paths — `exit 0` without touching git — so no
  # fixture ever ran a real pull, git state never entered any snapshot, and a
  # block that (say) pulled the wrong directory would still have passed.
  #
  # Now: rc=0 → `exec` the real git and let the pull actually happen (every
  # fixture is a real repo with a real local upstream, so it succeeds and is a
  # genuine no-op); rc≠0 → return that code without running git, which is the
  # only thing a fixture cannot produce for itself. Everything that is not `pull`
  # always delegates to the real git.
  #
  # The subcommand is found by PARSING past git's global options (`-C <dir>`,
  # `-c k=v`, `--git-dir=…`) instead of comparing argv elements, so a `pull`
  # appearing as the VALUE of an option can never be mistaken for the
  # subcommand. An argv shape the parser does not understand is recorded and
  # refused rather than guessed at — asserted at the end of the (f) section.
  REAL_GIT="$(command -v git)"
  STUB_BIN="$TMP_ROOT/bin"
  GIT_STUB_LOG="$TMP_ROOT/git-stub.log"
  : > "$GIT_STUB_LOG"
  mkdir -p "$STUB_BIN"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'GIT_STUB_LOG=%s\n' "$GIT_STUB_LOG"
    printf 'SANDBOX=%s\n' "$TMP_ROOT"
    # Parse a COPY of argv. `shift`ing the real positional parameters and then
    # `exec`ing "$@" drops the leading `-C <dir>` — the delegated git would run
    # against the CURRENT directory, i.e. the developer's own checkout, and
    # `git pull --rebase` would execute there. Never mutate argv here.
    printf '%s\n' 'argv=("$@"); n=${#argv[@]}; i=0; sub=""; repo=""'
    printf '%s\n' 'while [ "$i" -lt "$n" ]; do'
    printf '%s\n' '  a="${argv[$i]}"'
    printf '%s\n' '  case "$a" in'
    printf '%s\n' '    -C) repo="${argv[$((i+1))]:-}"; i=$((i+2)) ;;'
    printf '%s\n' '    -c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix) i=$((i+2)) ;;'
    printf '%s\n' '    --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--super-prefix=*) i=$((i+1)) ;;'
    printf '%s\n' '    -*) i=$((i+1)) ;;'
    printf '%s\n' '    *) sub="$a"; break ;;'
    printf '%s\n' '  esac'
    printf '%s\n' 'done'
    printf '%s\n' 'if [ -z "$sub" ]; then'
    printf '%s\n' '  printf "UNRECOGNISED no-subcommand | %s\\n" "$*" >> "$GIT_STUB_LOG"'
    printf '%s\n' '  echo "git stub: could not identify a subcommand in: $*" >&2'
    printf '%s\n' '  exit 111'
    printf '%s\n' 'fi'
    # Hard sandbox: a delegated git must operate inside the throwaway fixture
    # root. Anything else is a harness bug, and delegating it would run a real
    # git command against a real repository.
    printf '%s\n' 'case "$repo" in'
    printf '%s\n' '  "$SANDBOX"/*) : ;;'
    printf '%s\n' '  *)'
    printf '%s\n' '    printf "UNRECOGNISED outside-sandbox repo=%s | %s\\n" "$repo" "$*" >> "$GIT_STUB_LOG"'
    printf '%s\n' '    echo "git stub: refusing to run git outside $SANDBOX (repo=$repo): $*" >&2'
    printf '%s\n' '    exit 111 ;;'
    printf '%s\n' 'esac'
    printf '%s\n' 'printf "SUB %s | %s\\n" "$sub" "$*" >> "$GIT_STUB_LOG"'
    printf '%s\n' 'if [ "$sub" = "pull" ] && [ "${ZUVO_TEST_GIT_PULL_RC:-0}" != "0" ]; then'
    printf '%s\n' '  printf "PULL-FORCED-FAIL %s\\n" "${ZUVO_TEST_GIT_PULL_RC}" >> "$GIT_STUB_LOG"'
    printf '%s\n' '  exit "${ZUVO_TEST_GIT_PULL_RC}"'
    printf '%s\n' 'fi'
    printf 'exec %s "$@"\n' "$REAL_GIT"
  } > "$STUB_BIN/git"
  chmod +x "$STUB_BIN/git"

  # ── fixture repos: real git, real upstream ──────────────────────────────────
  # Every marketplace fixture must be a real repo, or a `git -C <fixture> …`
  # resolves against whatever enclosing checkout happens to contain $TMPDIR — the
  # command would then report on, and could act on, a repo the test does not own.
  # `git init … || true` (the old form) hid exactly that: a fixture whose init
  # failed silently tested nothing. Each step's exit code is checked, and a real
  # bare upstream is created + pushed so `git pull --rebase` succeeds for real.
  init_mkt_repo() {  # $1 = fixture dir
    git -C "$1" init --quiet >/dev/null 2>&1 || return 1
    git -C "$1" config user.email 'zuvo-test@example.invalid' >/dev/null 2>&1 || return 1
    git -C "$1" config user.name 'zuvo test' >/dev/null 2>&1 || return 1
    git -C "$1" config commit.gpgsign false >/dev/null 2>&1 || return 1
    git -C "$1" add -A >/dev/null 2>&1 || return 1
    git -C "$1" commit -qm 'fixture baseline' >/dev/null 2>&1 || return 1
    git init --quiet --bare "${1}.origin" >/dev/null 2>&1 || return 1
    git -C "$1" remote add origin "${1}.origin" >/dev/null 2>&1 || return 1
    git -C "$1" push -q -u origin HEAD >/dev/null 2>&1 || return 1
    return 0
  }
  require_repo() {  # abort the whole test rather than run against a broken fixture
    if ! init_mkt_repo "$1"; then
      bad "fixture setup: could not initialise git repo + upstream at $1 — refusing to run marketplace cases against a non-repo"
      echo "----"; echo "SOME FAILED"; exit 1
    fi
  }
  commit_fixture() {  # make a rewritten fixture clean again, as Step 4 does in production
    if [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]; then
      git -C "$1" add -A >/dev/null 2>&1 || return 1
      git -C "$1" commit -qm 'fixture: after pre-flight run' >/dev/null 2>&1 || return 1
    fi
    return 0
  }
  # Any case that edits a fixture AFTER mk_stale_mkt has committed its baseline
  # must seal it: the block's pull is real, and `git pull --rebase` refuses on a
  # dirty tree, so an unsealed fixture would fail on the pull and never reach the
  # behaviour the case exists to assert.
  seal_fixture() { commit_fixture "$1" || bad "fixture setup: could not commit tailored fixture $1"; }

  # fixture builder: today's REAL staleness (51 in marketplace.json, 49 in
  # README.md) PLUS two files that are NOT on the allowlist — a changelog whose
  # historical counts are content, not metadata, and an unrelated doc. Both must
  # come out byte-identical: that is the discriminator the old os.walk failed.
  MK_FILES='.claude-plugin/marketplace.json README.md CHANGELOG.md docs/legacy.md'
  mk_stale_mkt() {
    mkdir -p "$1/.claude-plugin" "$1/docs"
    printf '%s\n' '{ "description": "51 skills, 26 specialized agents", "category": "development" }' \
      > "$1/.claude-plugin/marketplace.json"
    printf '49 skills, 26 specialized agents\n' > "$1/README.md"
    printf 'v1.0 shipped 49 skills; today it is 57 skills.\n' > "$1/CHANGELOG.md"
    printf 'legacy note: 49 skills\n' > "$1/docs/legacy.md"
    require_repo "$1"
  }
  # git state is part of every snapshot: a failure path that leaves the
  # marketplace dirty (or moves HEAD) is exactly what wedges the NEXT run's
  # fail-closed pull, and a files-only comparison cannot see it.
  git_snap() { git -C "$1" rev-parse HEAD 2>&1; git -C "$1" status --porcelain 2>&1; }
  snap_mkt() {  # $1 = fixture dir, $2 = snapshot dir
    mkdir -p "$2/.claude-plugin" "$2/docs"
    for _f in $MK_FILES; do cp "$1/$_f" "$2/$_f"; done
    git_snap "$1" > "$2.gitsnap"
  }
  same_mkt() {  # $1 = fixture dir, $2 = snapshot dir — files AND git state identical
    for _f in $MK_FILES; do
      cmp -s "$1/$_f" "$2/$_f" || return 1
    done
    [ "$(git_snap "$1")" = "$(cat "$2.gitsnap")" ] || return 1
    return 0
  }

  # stub ZUVO_DIR: validate-skills.sh --print-count prints exactly 57.
  STUB_ZUVO="$TMP_ROOT/zuvo"
  mkdir -p "$STUB_ZUVO/scripts"
  printf '#!/usr/bin/env bash\necho 57\n' > "$STUB_ZUVO/scripts/validate-skills.sh"
  chmod +x "$STUB_ZUVO/scripts/validate-skills.sh"

  # stub marketplace: today's REAL staleness — 51 in marketplace.json, 49 in
  # README.md — with the near-miss neighbours that must not be touched.
  MKT="$TMP_ROOT/mkt"
  mkdir -p "$MKT/.claude-plugin"
  cat > "$MKT/.claude-plugin/marketplace.json" <<'JSON'
{
  "name": "zuvo-marketplace",
  "plugins": [
    {
      "name": "zuvo",
      "description": "51 skills, 26 specialized agents, quality gates, knowledge store",
      "category": "development",
      "source": { "source": "github", "repo": "greglas75/zuvo", "sha": "0123456789abcdef" }
    }
  ]
}
JSON
  printf '## What you get\n\n49 skills, 26 specialized agents, quality gates, session recovery.\n' > "$MKT/README.md"
  # a real repo WITH an upstream, so `git -C … pull` can never walk up into an
  # enclosing checkout and the block's pull genuinely runs
  require_repo "$MKT"
  cp -R "$MKT/.claude-plugin/marketplace.json" "$TMP_ROOT/orig-marketplace.json"
  cp -R "$MKT/README.md" "$TMP_ROOT/orig-README.md"

  MC_RUNNER="$TMP_ROOT/mc-runner.sh"
  {
    printf '%s\n' "$SET_OPTS"
    printf '%s\n' 'fail() { echo "FAIL-CALLED: $1"; exit 1; }'
    printf '%s\n' 'warn() { echo "WARN-CALLED: $1"; }'
    printf '%s\n' 'ok()   { echo "OK-CALLED: $1"; }'
    printf '%s\n' "$MC_BLOCK"
  } > "$MC_RUNNER"

  # occurrences, NOT lines: `grep -c` counts matching LINES, so two "57 skills"
  # on one line counted as 1 and a duplicated rewrite would have looked correct.
  count_occ() { grep -o -F "$1" "$2" 2>/dev/null | grep -c . ; }

  # (f.a) SELF-HEAL: stale 51/49 → both files read 57, block exits 0.
  out_f="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT" bash "$MC_RUNNER" 2>&1)"; rc_f=$?
  if [ "$rc_f" -eq 0 ] \
     && [ "$(count_occ '57 skills' "$MKT/.claude-plugin/marketplace.json")" -eq 1 ] \
     && [ "$(count_occ '57 skills' "$MKT/README.md")" -eq 1 ] \
     && ! grep -Fq '51 skills' "$MKT/.claude-plugin/marketplace.json" \
     && ! grep -Fq '49 skills' "$MKT/README.md"; then
    pass "(f.a) stale 51/49 marketplace self-healed to 57 in BOTH files (exit $rc_f)"
  else
    bad "(f.a) expected exit 0 + '57 skills' in both files; got rc=$rc_f out=[$out_f]"
  fi

  # (f.c) NEAR-MISS: whole-file cmp against a count-ONLY substitution proves that
  # '26 specialized agents' and '"category": "development"' are byte-unchanged.
  sed 's/51 skills/57 skills/' "$TMP_ROOT/orig-marketplace.json" > "$TMP_ROOT/exp-marketplace.json"
  sed 's/49 skills/57 skills/' "$TMP_ROOT/orig-README.md"        > "$TMP_ROOT/exp-README.md"
  if cmp -s "$TMP_ROOT/exp-marketplace.json" "$MKT/.claude-plugin/marketplace.json" \
     && cmp -s "$TMP_ROOT/exp-README.md" "$MKT/README.md" \
     && grep -Fq '26 specialized agents' "$MKT/.claude-plugin/marketplace.json" \
     && grep -Fq '26 specialized agents' "$MKT/README.md" \
     && grep -Fq '"category": "development"' "$MKT/.claude-plugin/marketplace.json"; then
    pass "(f.c) only the count changed — '26 specialized agents' + \"category\" byte-unchanged"
  else
    bad "(f.c) rewrite altered more than the count: $(diff "$TMP_ROOT/exp-marketplace.json" "$MKT/.claude-plugin/marketplace.json"; diff "$TMP_ROOT/exp-README.md" "$MKT/README.md")"
  fi

  # (f.e) IDEMPOTENT: second run over an already-correct marketplace is a no-op.
  cp "$MKT/.claude-plugin/marketplace.json" "$TMP_ROOT/pass1-marketplace.json"
  cp "$MKT/README.md" "$TMP_ROOT/pass1-README.md"
  # The pull is REAL now, and `git pull --rebase` refuses on a dirty tree — which
  # is precisely the deadlock the staged-then-committed write exists to avoid.
  # Production reaches its second run through Step 4's commit, so the fixture
  # commits here too; skipping it would test the wedged state, not idempotence.
  commit_fixture "$MKT" || bad "(f.e) fixture commit failed for $MKT"
  out_g="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT" bash "$MC_RUNNER" 2>&1)"; rc_g=$?
  if [ "$rc_g" -eq 0 ] \
     && cmp -s "$TMP_ROOT/pass1-marketplace.json" "$MKT/.claude-plugin/marketplace.json" \
     && cmp -s "$TMP_ROOT/pass1-README.md" "$MKT/README.md"; then
    pass "(f.e) second run over a correct marketplace is a no-op that exits 0"
  else
    bad "(f.e) expected exit 0 + byte-identical files; got rc=$rc_g out=[$out_g]"
  fi

  # (f.d) SURVIVOR: an occurrence the rewrite cannot fix → non-zero + named file.
  MKT2="$TMP_ROOT/mkt-ro"
  mkdir -p "$MKT2/.claude-plugin"
  printf '{ "description": "57 skills, 26 specialized agents" }\n' > "$MKT2/.claude-plugin/marketplace.json"
  printf '49 skills, 26 specialized agents\n' > "$MKT2/README.md"
  require_repo "$MKT2"
  chmod 444 "$MKT2/README.md"
  # side-effect-free probe: `[ -w ]` never touches the fixture, and an append
  # probe would emit a bare shell redirection error that no `2>/dev/null` on the
  # command itself can suppress.
  if [ "$(id -u)" = "0" ] || [ -w "$MKT2/README.md" ]; then
    skip "(f.d) cannot make a file unwritable in this environment (root?) — survivor case not exercised"
  else
    out_h="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT2" bash "$MC_RUNNER" 2>&1)"; rc_h=$?
    if [ "$rc_h" -ne 0 ] \
       && printf '%s\n' "$out_h" | grep -Fq 'FAIL-CALLED' \
       && printf '%s\n' "$out_h" | grep -Fq 'README.md'; then
      pass "(f.d) surviving '<N> skills' occurrence → fail() naming the file (exit $rc_h)"
    else
      bad "(f.d) expected non-zero + FAIL-CALLED naming README.md; got rc=$rc_h out=[$out_h]"
    fi
  fi
  chmod 644 "$MKT2/README.md" 2>/dev/null || true

  # ── (f.f) CRITICAL: a failed `git pull --rebase` must ABORT, not rewrite ─────
  # Pre-fix the pull was `… 2>/dev/null || true`, so an offline/diverged/mid-
  # rebase marketplace was rewritten on a STALE base and Step 4 then committed
  # and pushed it — clobbering the remote of a repo the user publishes from.
  MKT_PULL="$TMP_ROOT/mkt-pullfail"; mk_stale_mkt "$MKT_PULL"
  snap_mkt "$MKT_PULL" "$TMP_ROOT/snap-pullfail"
  out_p="$(PATH="$STUB_BIN:$PATH" ZUVO_TEST_GIT_PULL_RC=1 ZUVO_DIR="$STUB_ZUVO" \
           MARKETPLACE_DIR="$MKT_PULL" bash "$MC_RUNNER" 2>&1)"; rc_p=$?
  if [ "$rc_p" -ne 0 ] \
     && printf '%s\n' "$out_p" | grep -Fq 'FAIL-CALLED' \
     && printf '%s\n' "$out_p" | grep -Fq "$MKT_PULL" \
     && same_mkt "$MKT_PULL" "$TMP_ROOT/snap-pullfail"; then
    pass "(f.f) failed pull → fail() naming \$MARKETPLACE_DIR, marketplace byte-unchanged (exit $rc_p)"
  else
    bad "(f.f) expected non-zero + FAIL-CALLED naming $MKT_PULL + zero mutation; got rc=$rc_p out=[$out_p]"
  fi

  # ── (f.g) ALLOWLIST: only the two metadata files are eligible ───────────────
  # The old recursive os.walk rewrote EVERY file under the marketplace tree, so
  # a changelog line and an unrelated doc were silently overwritten with the
  # current count. Both must now survive byte-identical.
  MKT3="$TMP_ROOT/mkt-allow"; mk_stale_mkt "$MKT3"
  cp "$MKT3/CHANGELOG.md" "$TMP_ROOT/orig-CHANGELOG.md"
  cp "$MKT3/docs/legacy.md" "$TMP_ROOT/orig-legacy.md"
  out_al="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT3" \
            bash "$MC_RUNNER" 2>&1)"; rc_al=$?
  if [ "$rc_al" -eq 0 ] \
     && grep -Fq '57 skills' "$MKT3/.claude-plugin/marketplace.json" \
     && grep -Fq '57 skills' "$MKT3/README.md" \
     && cmp -s "$TMP_ROOT/orig-CHANGELOG.md" "$MKT3/CHANGELOG.md" \
     && cmp -s "$TMP_ROOT/orig-legacy.md" "$MKT3/docs/legacy.md"; then
    pass "(f.g) allowlist honoured — CHANGELOG.md + docs/legacy.md untouched while both metadata files corrected"
  else
    bad "(f.g) expected the 2 allowlisted files fixed and non-allowlisted files untouched; got rc=$rc_al out=[$out_al] changelog=[$(cat "$MKT3/CHANGELOG.md")] legacy=[$(cat "$MKT3/docs/legacy.md")]"
  fi

  # ── (f.h) SYMLINK: never write THROUGH a link (it can escape the repo) ──────
  MKT4="$TMP_ROOT/mkt-symlink"; mk_stale_mkt "$MKT4"
  OUTSIDE="$TMP_ROOT/outside-README.md"
  printf '49 skills, 26 specialized agents\n' > "$OUTSIDE"
  cp "$OUTSIDE" "$TMP_ROOT/orig-outside.md"
  rm -f "$MKT4/README.md"; ln -s "$OUTSIDE" "$MKT4/README.md"
  seal_fixture "$MKT4"
  cp "$MKT4/.claude-plugin/marketplace.json" "$TMP_ROOT/orig-symlink-mkt.json"
  out_sl="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT4" \
            bash "$MC_RUNNER" 2>&1)"; rc_sl=$?
  if [ "$rc_sl" -ne 0 ] \
     && printf '%s\n' "$out_sl" | grep -Fq 'FAIL-CALLED' \
     && printf '%s\n' "$out_sl" | grep -Fq 'README.md' \
     && cmp -s "$TMP_ROOT/orig-outside.md" "$OUTSIDE" \
     && cmp -s "$TMP_ROOT/orig-symlink-mkt.json" "$MKT4/.claude-plugin/marketplace.json"; then
    pass "(f.h) symlinked allowlist entry → fail(), link target outside the repo untouched (exit $rc_sl)"
  else
    bad "(f.h) expected non-zero + FAIL-CALLED naming README.md + untouched target; got rc=$rc_sl out=[$out_sl]"
  fi

  # ── (f.i) MISSING: a renamed count location must STOP the release ───────────
  MKT5="$TMP_ROOT/mkt-missing"; mk_stale_mkt "$MKT5"
  mv "$MKT5/README.md" "$MKT5/README.markdown"
  seal_fixture "$MKT5"
  cp "$MKT5/.claude-plugin/marketplace.json" "$TMP_ROOT/orig-missing-mkt.json"
  out_ms="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT5" \
            bash "$MC_RUNNER" 2>&1)"; rc_ms=$?
  if [ "$rc_ms" -ne 0 ] \
     && printf '%s\n' "$out_ms" | grep -Fq 'FAIL-CALLED' \
     && printf '%s\n' "$out_ms" | grep -Fq 'README.md' \
     && cmp -s "$TMP_ROOT/orig-missing-mkt.json" "$MKT5/.claude-plugin/marketplace.json"; then
    pass "(f.i) missing allowlist entry → fail() naming README.md, nothing written (exit $rc_ms)"
  else
    bad "(f.i) expected non-zero + FAIL-CALLED naming README.md + no write; got rc=$rc_ms out=[$out_ms]"
  fi

  # ── (f.j) MOVED STRING: file present but the count string is gone ───────────
  MKT6="$TMP_ROOT/mkt-nostring"; mk_stale_mkt "$MKT6"
  printf '%s\n' '{ "description": "26 specialized agents", "category": "development" }' \
    > "$MKT6/.claude-plugin/marketplace.json"
  seal_fixture "$MKT6"
  cp "$MKT6/README.md" "$TMP_ROOT/orig-nostring-README.md"
  out_nx="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT6" \
            bash "$MC_RUNNER" 2>&1)"; rc_nx=$?
  if [ "$rc_nx" -ne 0 ] \
     && printf '%s\n' "$out_nx" | grep -Fq 'FAIL-CALLED' \
     && printf '%s\n' "$out_nx" | grep -Fq 'marketplace.json' \
     && cmp -s "$TMP_ROOT/orig-nostring-README.md" "$MKT6/README.md"; then
    pass "(f.j) allowlisted file with no '<N> skills' string → fail(), nothing written (exit $rc_nx)"
  else
    bad "(f.j) expected non-zero + FAIL-CALLED naming marketplace.json + no write; got rc=$rc_nx out=[$out_nx]"
  fi

  # ── (f.k) NO PARTIAL MUTATION: pass 1 decides, pass 2 writes ────────────────
  # BOTH files are stale and README.md is unwritable. The old code wrote while
  # scanning, so marketplace.json was already rewritten by the time README.md
  # blew up. Two-pass means neither file is touched.
  MKT7="$TMP_ROOT/mkt-partial"; mk_stale_mkt "$MKT7"
  snap_mkt "$MKT7" "$TMP_ROOT/snap-partial"
  chmod 444 "$MKT7/README.md"
  if [ "$(id -u)" = "0" ] || [ -w "$MKT7/README.md" ]; then
    skip "(f.k) cannot make a file unwritable in this environment (root?) — partial-mutation case not exercised"
  else
    out_pm="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT7" \
              bash "$MC_RUNNER" 2>&1)"; rc_pm=$?
    if [ "$rc_pm" -ne 0 ] \
       && printf '%s\n' "$out_pm" | grep -Fq 'FAIL-CALLED' \
       && printf '%s\n' "$out_pm" | grep -Fq 'README.md' \
       && same_mkt "$MKT7" "$TMP_ROOT/snap-partial"; then
      pass "(f.k) unwritable README.md → fatal naming it, marketplace.json NOT partially rewritten (exit $rc_pm)"
    else
      bad "(f.k) expected non-zero + fatal naming README.md + zero mutation; got rc=$rc_pm out=[$out_pm]"
    fi
  fi
  chmod 644 "$MKT7/README.md" 2>/dev/null || true

  # ── (f.l) LEADING ZERO: '057' is digit-only but not a canonical count ───────
  STUB_ZERO="$TMP_ROOT/zuvo-zero"
  mkdir -p "$STUB_ZERO/scripts"
  printf '#!/usr/bin/env bash\necho 057\n' > "$STUB_ZERO/scripts/validate-skills.sh"
  chmod +x "$STUB_ZERO/scripts/validate-skills.sh"
  MKT8="$TMP_ROOT/mkt-zero"; mk_stale_mkt "$MKT8"
  snap_mkt "$MKT8" "$TMP_ROOT/snap-zero"
  out_lz="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZERO" MARKETPLACE_DIR="$MKT8" \
            bash "$MC_RUNNER" 2>&1)"; rc_lz=$?
  if [ "$rc_lz" -ne 0 ] \
     && printf '%s\n' "$out_lz" | grep -Fq 'FAIL-CALLED' \
     && printf '%s\n' "$out_lz" | grep -Fq '057' \
     && same_mkt "$MKT8" "$TMP_ROOT/snap-zero"; then
    pass "(f.l) --print-count '057' rejected before any write (exit $rc_lz)"
  else
    bad "(f.l) expected non-zero + FAIL-CALLED naming '057' + zero mutation; got rc=$rc_lz out=[$out_lz]"
  fi

  # ── (f.m) CASE: a capitalised variant is corrected, its casing preserved ────
  MKT9="$TMP_ROOT/mkt-case"; mk_stale_mkt "$MKT9"
  printf '49 Skills, 26 specialized agents\n' > "$MKT9/README.md"
  seal_fixture "$MKT9"
  out_cs="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT9" \
            bash "$MC_RUNNER" 2>&1)"; rc_cs=$?
  if [ "$rc_cs" -eq 0 ] \
     && grep -Fq '57 Skills' "$MKT9/README.md" \
     && ! grep -Fq '49 Skills' "$MKT9/README.md" \
     && ! grep -Fq '57 skills' "$MKT9/README.md"; then
    pass "(f.m) '49 Skills' → '57 Skills' — matched case-insensitively, original casing preserved"
  else
    bad "(f.m) expected exit 0 + '57 Skills' (casing preserved); got rc=$rc_cs out=[$out_cs] readme=[$(cat "$MKT9/README.md")]"
  fi

  # ── (f.n) EQUAL-COUNT MATCHES ARE RETURNED UNCHANGED ────────────────────────
  # The substitution callback returns a match whose digits already equal `want`
  # byte-identical, so idempotence is structural rather than incidental. The
  # already-correct occurrence here is CAPITALISED on purpose: case-insensitive
  # matching without the callback would rewrite "57 Skills" to "57 skills" and
  # silently mangle casing it was never asked to touch.
  MKT10="$TMP_ROOT/mkt-mixed"; mk_stale_mkt "$MKT10"
  printf '49 skills today, 57 Skills after this release.\n' > "$MKT10/README.md"
  seal_fixture "$MKT10"
  out_r1="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT10" \
            bash "$MC_RUNNER" 2>&1)"; rc_r1=$?
  cp "$MKT10/README.md" "$TMP_ROOT/mixed-pass1-README.md"
  cp "$MKT10/.claude-plugin/marketplace.json" "$TMP_ROOT/mixed-pass1.json"
  commit_fixture "$MKT10" || bad "(f.n) fixture commit failed for $MKT10"
  out_r2="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT10" \
            bash "$MC_RUNNER" 2>&1)"; rc_r2=$?
  if [ "$rc_r1" -eq 0 ] && [ "$rc_r2" -eq 0 ] \
     && [ "$(cat "$MKT10/README.md")" = "57 skills today, 57 Skills after this release." ] \
     && cmp -s "$TMP_ROOT/mixed-pass1-README.md" "$MKT10/README.md" \
     && cmp -s "$TMP_ROOT/mixed-pass1.json" "$MKT10/.claude-plugin/marketplace.json"; then
    pass "(f.n) mixed correct/stale counts converge and the second run is byte-identical"
  else
    bad "(f.n) expected convergence + byte-identical rerun; got rc1=$rc_r1 rc2=$rc_r2 out1=[$out_r1] out2=[$out_r2] readme=[$(cat "$MKT10/README.md")]"
  fi

  # ── (f.o) DIRECTORY-LEVEL UNWRITABILITY ─────────────────────────────────────
  # (f.d)/(f.k) make the TARGET FILE mode 444 — but POSIX rename() consults the
  # DIRECTORY's permissions, not the target's, so os.replace() over a 444 file
  # succeeds. Those two cases therefore prove only that the block's os.access()
  # precheck fires; drop that precheck in a refactor and they would go green
  # while the block happily rewrote a read-only file. Here the PARENT DIRECTORY
  # of README.md is 555, so the write is impossible at the filesystem level: the
  # temp file cannot even be created. marketplace.json lives in a different,
  # writable directory and is stale, so this also re-proves the staged-then-
  # committed invariant — a failure on the second target leaves the first one
  # untouched instead of half-rewriting the marketplace.
  MKT11="$TMP_ROOT/mkt-dirperm"; mk_stale_mkt "$MKT11"
  snap_mkt "$MKT11" "$TMP_ROOT/snap-dirperm"
  chmod 555 "$MKT11"
  if [ "$(id -u)" = "0" ] || [ -w "$MKT11" ]; then
    chmod 755 "$MKT11" 2>/dev/null || true
    skip "(f.o) cannot make a directory unwritable in this environment (root?) — dir-permission case not exercised"
  else
    out_dp="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT11" \
              bash "$MC_RUNNER" 2>&1)"; rc_dp=$?
    chmod 755 "$MKT11" 2>/dev/null || true
    if [ "$rc_dp" -ne 0 ] \
       && printf '%s\n' "$out_dp" | grep -Fq 'FAIL-CALLED' \
       && printf '%s\n' "$out_dp" | grep -Fq 'README.md' \
       && same_mkt "$MKT11" "$TMP_ROOT/snap-dirperm" \
       && [ -z "$(ls -A "$MKT11"/.zuvo-count-* "$MKT11"/.claude-plugin/.zuvo-count-* 2>/dev/null)" ]; then
      pass "(f.o) unwritable PARENT DIRECTORY → fatal naming README.md, marketplace.json untouched, no temp files left (exit $rc_dp)"
    else
      bad "(f.o) expected non-zero + fatal naming README.md + zero mutation + no leftover temps; got rc=$rc_dp out=[$out_dp]"
    fi
  fi

  # ── (f.p) AMBIGUOUS FILE: two DIFFERING counts in one allowlisted file ──────
  # The allowlist stopped the rewrite from descending into a changelog, but it
  # could not tell which occurrence INSIDE an allowlisted file is the metadata.
  # A README that says "grew from 49 skills to 51 skills" would have had BOTH
  # rewritten to 57, corrupting a historical statement that was never wrong.
  # Two or more disagreeing occurrences must be fatal, and the message must name
  # the file and the line numbers so a human can disambiguate.
  MKT12="$TMP_ROOT/mkt-ambiguous"; mk_stale_mkt "$MKT12"
  printf '# zuvo\n\nWe grew from 49 skills at launch.\n\nToday: 51 skills, 26 specialized agents.\n' \
    > "$MKT12/README.md"
  seal_fixture "$MKT12"
  snap_mkt "$MKT12" "$TMP_ROOT/snap-ambiguous"
  out_am="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT12" \
            bash "$MC_RUNNER" 2>&1)"; rc_am=$?
  if [ "$rc_am" -ne 0 ] \
     && printf '%s\n' "$out_am" | grep -Fq 'FAIL-CALLED' \
     && printf '%s\n' "$out_am" | grep -Fq 'README.md' \
     && printf '%s\n' "$out_am" | grep -Eq 'line 3' \
     && printf '%s\n' "$out_am" | grep -Eq 'line 5' \
     && same_mkt "$MKT12" "$TMP_ROOT/snap-ambiguous"; then
    pass "(f.p) two differing counts in README.md → fatal naming the file and lines 3+5, nothing written (exit $rc_am)"
  else
    bad "(f.p) expected non-zero + fatal naming README.md and both line numbers + zero mutation; got rc=$rc_am out=[$out_am] readme=[$(cat "$MKT12/README.md")]"
  fi

  # ── (f.q) DECIMAL BOUNDARY: "1.5 skills" is not a "5 skills" match ──────────
  # `\b(\d+) (skills)\b` matched the TAIL of a decimal — the \b between "." and
  # "5" let "5 skills" match inside "1.5 skills", which the rewrite turned into
  # "1.57 skills". The lookbehind kills it. The file still carries exactly ONE
  # genuine stale count, so the run must SUCCEED and leave the decimal alone
  # (a false match would additionally trip the ambiguity guard from (f.p) — the
  # exit-0 assertion is what distinguishes "not matched" from "matched twice").
  MKT13="$TMP_ROOT/mkt-decimal"; mk_stale_mkt "$MKT13"
  printf 'Bundle v1.5 skills pack.\n\n49 skills, 26 specialized agents\n' > "$MKT13/README.md"
  seal_fixture "$MKT13"
  out_dc="$(PATH="$STUB_BIN:$PATH" ZUVO_DIR="$STUB_ZUVO" MARKETPLACE_DIR="$MKT13" \
            bash "$MC_RUNNER" 2>&1)"; rc_dc=$?
  if [ "$rc_dc" -eq 0 ] \
     && grep -Fq 'v1.5 skills' "$MKT13/README.md" \
     && ! grep -Fq '1.57 skills' "$MKT13/README.md" \
     && [ "$(count_occ '57 skills' "$MKT13/README.md")" -eq 1 ] \
     && ! grep -Fq '49 skills' "$MKT13/README.md"; then
    pass "(f.q) 'v1.5 skills' left intact while the real '49 skills' became '57 skills' (exit $rc_dc)"
  else
    bad "(f.q) expected exit 0 + untouched 'v1.5 skills' + one '57 skills'; got rc=$rc_dc out=[$out_dc] readme=[$(cat "$MKT13/README.md")]"
  fi

  # ── git stub sanity: the block's pull was really seen, and never guessed at ──
  # Both halves matter. An UNRECOGNISED line means the stub could not identify a
  # subcommand and refused rather than delegating blind — that is a harness bug
  # that would silently mis-stub git. Zero recorded `pull` invocations would mean
  # the fail-closed pull assertions above never exercised the pull at all.
  if ! grep -q '^UNRECOGNISED ' "$GIT_STUB_LOG"; then
    pass "(f) git stub parsed every invocation (no UNRECOGNISED argv shapes)"
  else
    bad "(f) git stub could not parse some invocations: [$(grep '^UNRECOGNISED ' "$GIT_STUB_LOG")]"
  fi
  if [ "$(grep -c '^SUB pull ' "$GIT_STUB_LOG")" -gt 0 ] \
     && [ "$(grep -c '^PULL-FORCED-FAIL ' "$GIT_STUB_LOG")" -gt 0 ]; then
    pass "(f) real 'git pull --rebase' ran on the success path ($(grep -c '^SUB pull ' "$GIT_STUB_LOG")×) and was forced to fail only where intended ($(grep -c '^PULL-FORCED-FAIL ' "$GIT_STUB_LOG")×)"
  else
    bad "(f) expected both real pulls and forced pull failures in the stub log; got pulls=$(grep -c '^SUB pull ' "$GIT_STUB_LOG") forced=$(grep -c '^PULL-FORCED-FAIL ' "$GIT_STUB_LOG")"
  fi
fi

# ── (e) PURITY: the repo working tree is untouched by this test ───────────────
GIT_AFTER="$( (cd "$ROOT" && git status --porcelain) 2>/dev/null )"
if [ "$GIT_BEFORE" = "$GIT_AFTER" ]; then
  pass "(e) repo working tree unchanged by test run"
else
  bad "(e) test mutated the repo — before=[$GIT_BEFORE] after=[$GIT_AFTER]"
fi

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME FAILED"
  exit 1
fi
