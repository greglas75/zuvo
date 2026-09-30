#!/usr/bin/env bash
#
# test-model-run.sh — ~/.zuvo/model-run (scripts/zuvo-home/model-run): ONE prompt through the routed
# cross-vendor reviewer, as an isolated subprocess (plan C Task 5,
# docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md; coverage rows G1 / G2 / K2 / K3; SMOKE-C2
# together with tests/hooks/test-install-wiring.sh, which proves the INSTALLED ~/.zuvo layout).
#
# Test level: MEDIUM — real subprocesses (model-run, the real router, the shared runner, GNU timeout),
# temp dirs, a temp git repo, spy clients, real timing (1 s budgets) and real signals. No network, no
# real model CLI, nothing outside the sandbox.
#
# What this pins:
#   A/B  a Claude host runs Codex with the registry primary at the registry's audit effort (K2: high),
#        read-only sandbox, isolated CODEX_HOME, neutral cwd (G1); a Codex host runs `claude -p` with the
#        registry's Opus reviewer, its effort and the access-read flags (G2); stdout is the answer, byte
#        for byte;
#   C    a route that is not `ok` runs NOTHING: exit 1 `status=unavailable route=<status>` (K3);
#   D    the client's stdin is the prompt file + every --append-file, byte for byte;
#   E    --require / --reject: an echoed prompt, an echoed AUTO TIER-D template, an answer with neither a
#        Tier line nor a filled AUTO TIER-D line → exit 3; a batch of ONLY AUTO TIER-D entries passes.
#        --out: only on exit 0; replaced by rename (a hard link to the old file keeps the old bytes), its
#        mode kept; a client streaming slowly is never seen half-written; a symlink, a FIFO or any other
#        non-regular --out is refused; answers with no final newline, a NUL, or a long text that merely
#        talks about login are passed through unchanged;
#   F    124 on a timeout — also when GNU timeout had to KILL a client that ignores TERM (137);
#   G-K  1 client missing / could not start, 3 auth (stdout OR stderr, on every no-usable-answer path) /
#        empty / invalid, 4 a client that RAN and failed;
#   L    2 usage (an unmappable --model, the --timeout grammar included) — every usage vector an array;
#        both --timeout boundaries (1 and 99999) are accepted AND reach the client's GNU timeout;
#   M/N  explicit --model; --access none; paths shaped like options (`-n`, `--help.md`, `-d/…`, a blank);
#   O    a stub router (its answer from a FILE): an `ok` naming the host's or the platform's own vendor, any
#        break of the byte-exact six-key contract, any of the six values outside its enum / id / writer-id
#        shape, an answer over 4 KB (even one whose first 4 KB are a valid record; 100 KB is reported as
#        oversized, not as the router's death), and a router that exits non-zero — each refusal asserted
#        with the route= that says where it came from;
#   P    the runner and the router are found sibling-first; a broken candidate is WARNed and the NEXT one
#        is proven used; a model-run opened from the CWD (a copy or a symlink) never sources the CWD's
#        runner or runs its router; no library / no router → exit 1;
#   R    a stub RUNNER: 124 before the client started; --out swapped for a link, a directory or a FIFO
#        during the run; --out's directory pinned when the arguments are checked (a link on the way moved
#        during the run does not move the answer); an answer file gone or unreadable → 4; a runner that
#        ignores TERM is torn down within a bounded time, also with a huge ZUVO_TIMEOUT_GRACE; a client
#        lookup diagnostic reaches stderr;
#   S-W  a failed stdout write is exit 4; no GNU timeout → exit 1 before anything runs; a codex CLI too old
#        for the model → route=cli-too-old (a new enough one runs); a destination mode that cannot be read
#        or applied → exit 4, --out untouched; a signal anywhere in the publish (from the temp file to the
#        rename) cannot undo `ok` nor leave a temp file; a directory swapped in at the rename is caught
#        after it — never `ok` for an unwritten --out;
#   Q    TERM / INT / HUP while the client runs (one that ignores TERM too): exit 128+n, ONE final
#        `status=error` line, the client gone, no temp file, no --out;
#   and after EVERY run: the read root is unchanged (a full file snapshot AND `git status --porcelain
#   --ignored`), TMPDIR is empty, and stderr ends in exactly one line of the full status grammar (none on
#   exit 2).
#
# Hermetic: every run is `env -i` with HOME / TMPDIR / CODEX_HOME in the sandbox, stdin from /dev/null,
# the clients are the fixture spy (tests/hooks/fixtures/model-subprocess/spy-cli) or a stub behind
# ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN, ZUVO_CODEX_APP_BIN=/nonexistent, no host signal and no credential
# variable unless the case sets one (env -i), and PATH=<shim>:/usr/bin:/bin (shim = links to the real GNU
# timeout / jq only). Every spy run is seeded with the exact bytes it answers; an unseeded client answers
# a marked UNSEEDED line. ZUVO_TEST_MODEL_RUN runs every case against ANOTHER model-run (to show a case
# is red there); it must sit in a repo-shaped tree (<root>/scripts/zuvo-home/) for --route to find a router.
#
# Run under both shells (bash 3.2 is macOS's /bin/bash):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/test-model-run.sh
#   TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/test-model-run.sh
set -uo pipefail
# Bytes, not characters, everywhere this file compares, sorts or classifies (tr, awk, sort, git output).
LC_ALL=C; export LC_ALL

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
# ok / bad / die / expect_eq / expect_has / expect_not_has / phys / assert_result
# shellcheck source=tests/lib/assert.sh
. "$ROOT/tests/lib/assert.sh"
# skip_block <what> <why> — dependent cases whose premise failed are NOT run, and that counts as a failure.
skip_block() { bad "$1 — NOT RUN: $2"; }
oneline() { tr '\n' '|' < "$1" 2>/dev/null; }
nlines() { awk 'END { print NR }' "$1" 2>/dev/null; }   # counts a last line without a newline too
# entries <dir> — the names in <dir>, dotfiles included, one per line, sorted; by glob, never by parsing ls.
entries() { ( shopt -s nullglob dotglob; for e in "$1"/*; do printf '%s\n' "${e##*/}"; done ) | sort; }
# last_byte <file> — the file's last byte as od prints it (\n for a newline, empty for an empty file).
last_byte() { tail -c 1 "$1" | od -An -c | tr -d ' '; }
fmode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
inode() { stat -c %i "$1" 2>/dev/null || stat -f %i "$1" 2>/dev/null; }
# expect_bytes <label> <file> <want-file> — byte for byte (cmp), never through $(cat …).
expect_bytes() {
  if cmp -s "$2" "$3"; then ok "$1"
  else bad "$1 — bytes differ: got [$(od -c "$2" 2>/dev/null | head -3 | tr '\n' ' ')] want [$(od -c "$3" | head -3 | tr '\n' ' ')]"; fi
}

MR="${ZUVO_TEST_MODEL_RUN:-$ROOT/scripts/zuvo-home/model-run}"
LIB="$ROOT/scripts/lib/model-subprocess.sh"
REG="$ROOT/shared/includes/model-registry.sh"
ROUTER="$ROOT/scripts/reviewer-model-route.sh"
FIXD="$ROOT/tests/hooks/fixtures/model-subprocess"
BATCH_PROMPT="$ROOT/shared/includes/test-audit-batch-prompt.md"
RBASH="$BASH"

echo "== model-run (bash $BASH_VERSION) =="
for _f in "$LIB" "$REG" "$ROUTER" "$FIXD/spy-cli" "$FIXD/codex-home/auth.json" "$BATCH_PROMPT"; do
  [ -f "$_f" ] || die "missing $_f"
done
[ -f "$MR" ] || die "model-run not found at $MR"
ok "model-run exists ($MR)"

# The registry values the routes must carry (K10: never literals in the router or in model-run), one
# variable per call, printed with %s. A registry that cannot be sourced, or an empty value, is fatal.
regval() { env -i /bin/bash -c '. "$1" || exit 97; n="$2"; v="${!n:-}"; [ -n "$v" ] || exit 98; printf "%s" "$v"' _ "$REG" "$1"; }
P_CODEX="$(regval ZUVO_MODEL_CODEX_PRIMARY)" || die "registry: ZUVO_MODEL_CODEX_PRIMARY (source failed or empty)"
E_CODEX="$(regval ZUVO_CODEX_EFFORT_AUDIT)" || die "registry: ZUVO_CODEX_EFFORT_AUDIT (source failed or empty)"
P_OPUS="$(regval ZUVO_MODEL_CLAUDE_REVIEWER_OPUS)" || die "registry: ZUVO_MODEL_CLAUDE_REVIEWER_OPUS (source failed or empty)"
E_OPUS="$(regval ZUVO_CLAUDE_REVIEWER_OPUS_EFFORT)" || die "registry: ZUVO_CLAUDE_REVIEWER_OPUS_EFFORT (source failed or empty)"
expect_eq "K2: the registry's audit effort for Codex is high" "high" "$E_CODEX"
expect_eq "G2: the registry's Opus reviewer is claude-opus-5-5 (the user decision, 2026-09-25)" "claude-opus-5-5" "$P_OPUS"

# ── sandbox ──────────────────────────────────────────────────────────────────
T="$(mktemp -d)" || die "mktemp -d failed"
[ -n "$T" ] && [ -d "$T" ] || die "mktemp -d returned no directory"
T="$(cd "$T" && pwd -P)" && [ -n "$T" ] || die "cannot resolve the sandbox path"
SPY="$T/spydir"; SPYB="$T/spyb"; H="$T/home"; TMPD="$T/tmp"; CH="$T/codex-home"; R="$T/repo"
PIDS="$T/spy-pids"; BGPIDS="$T/bg-pids"
# EXIT: every background job this file started (a watcher, a model-run under a signal case) is stopped
# when it is still OUR child; every recorded spy is stopped with its whole process group when its full
# (-ww, untruncated) command line still names THIS sandbox. Then the sandbox goes.
cleanup() {
  local p g cmd
  if [ -f "$BGPIDS" ]; then
    while IFS= read -r p; do
      case "$p" in ''|*[!0-9]*) continue ;; esac
      [ "$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')" = "$$" ] && kill -KILL "$p" 2>/dev/null
    done < "$BGPIDS"
  fi
  if [ -f "$PIDS" ]; then
    while read -r p g; do
      case "$p$g" in ''|*[!0-9]*) continue ;; esac
      cmd="$(ps -ww -o command= -p "$p" 2>/dev/null)" || continue
      case "$cmd" in *"$T/"*) kill -KILL -- "-$g" 2>/dev/null; kill -KILL "$p" 2>/dev/null ;; esac
    done < "$PIDS"
  fi
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$SPY" "$SPYB" "$H" "$TMPD" "$R" "$T/shim" "$T/githome" || die "cannot create the sandbox dirs"
TMPD="$(cd "$TMPD" && pwd -P)" || die "cannot resolve TMPDIR"
cp -R "$FIXD/codex-home" "$CH" || die "cannot copy the fixture CODEX_HOME"   # dummy auth.json + a hostile user config
for _c in codex claude; do cp "$FIXD/spy-cli" "$SPYB/$_c" && chmod +x "$SPYB/$_c" || die "cannot install the $_c spy"; done
# shellcheck source=tests/lib/hermetic-tools.sh
. "$ROOT/tests/lib/hermetic-tools.sh" || die "cannot load tests/lib/hermetic-tools.sh"
hermetic_link_tools "$T/shim" timeout:gtimeout jq || die "hermetic_link_tools failed"
[ -x "$T/shim/timeout" ] || die "GNU timeout (timeout or gtimeout) is required by the runner — brew install coreutils"
for _c in codex claude model-run; do [ ! -e "$T/shim/$_c" ] || die "the shim holds $_c"; done
REAL_TIMEOUT="$(cd "$T/shim" && pwd -P)/timeout"
REAL_STAT="$(command -v stat)" && REAL_CHMOD="$(command -v chmod)" && REAL_MV="$(command -v mv)" || die "stat / chmod / mv not found"
# The spy hashes its stdin with `shasum -a 256`; a host with only sha256sum gets a shasum stand-in on the
# run PATH that accepts -a 256 / -a256 / -b and refuses any other shape loudly.
if command -v shasum >/dev/null 2>&1; then sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum < "$1" | cut -d' ' -f1; }
  cat > "$T/shim/shasum" <<'SHASUM' || die "cannot write the shasum stand-in"
#!/bin/sh
# shasum stand-in over sha256sum: -a 256 | -a256 | -b only
while [ $# -gt 0 ]; do
  case "$1" in
    -a) [ "${2:-}" = 256 ] || { echo "shasum stand-in: only -a 256 is supported (got -a ${2:-})" >&2; exit 64; }; shift 2 ;;
    -a256|-b) shift ;;
    -*) echo "shasum stand-in: unsupported flag $1" >&2; exit 64 ;;
    *) break ;;
  esac
done
exec sha256sum "$@"
SHASUM
  chmod +x "$T/shim/shasum" || die "cannot chmod the shasum stand-in"
else die "neither shasum nor sha256sum is available"; fi

# The read root: a real git repo with a .gitignore. Every model-run below starts INSIDE it (unless a case
# names another CWD), so a stray write lands here. Unchanged means BOTH: a full snapshot of every entry
# (snapdir: its type, its name %q-quoted so a newline cannot split it, a file's size and sha256, a link's
# target; .git excluded) equals the one taken after setup, and `git status --porcelain --ignored` is empty
# with nothing on git's stderr. git runs under env -i (no GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE /
# GIT_CONFIG* from the caller), the C locale, a sandbox HOME, no system config, no hooks, no signing.
G() { env -i PATH="$PATH" LC_ALL=C HOME="$T/githome" XDG_CONFIG_HOME="$T/githome" GIT_CONFIG_NOSYSTEM=1 git -C "$R" \
        -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=t -c user.email=t@example.invalid "$@"; }
{ G init -q && printf 'export const x = 1;\n' > "$R/x.ts" && printf '*.log\ncache/\n' > "$R/.gitignore" \
  && G add x.ts .gitignore && G commit -q -m init; } >/dev/null 2>&1 || die "cannot build the read-root repo"
snapdir() { # snapdir <dir> [name-to-prune] — every entry below <dir>, one line each, sorted
  local d="$1" p
  ( cd "$d" && find . ${2:+-path "./$2" -prune -o} -print0 ) | while IFS= read -r -d '' p; do
    if [ -L "$d/$p" ]; then printf 'l %q -> %q\n' "$p" "$(readlink "$d/$p")"
    elif [ -f "$d/$p" ]; then printf 'f %q %s %s\n' "$p" "$(wc -c < "$d/$p" | tr -d ' ')" "$(sha "$d/$p")"
    elif [ -d "$d/$p" ]; then printf 'd %q\n' "$p"
    elif [ -p "$d/$p" ]; then printf 'p %q\n' "$p"
    elif [ -S "$d/$p" ]; then printf 's %q\n' "$p"
    else printf 'o %q\n' "$p"; fi
  done | sort
}
snap() { snapdir "$R" .git; }
SNAP0="$(snap)"
# HOME and CODEX_HOME of the default runs: model-run and the runner only READ them (the runner copies
# auth.json out of CODEX_HOME into its own temp dir; the spy writes only under SPY_DIR) — so no exception.
SNAPH0="$(snapdir "$H")"; SNAPCH0="$(snapdir "$CH")"
repo_state() { G status --porcelain --ignored --untracked-files=all 2> "$T/git.err"; }
repo_clean() {
  local s now; s="$(repo_state)"; now="$(snap)"
  if [ -z "$s" ] && [ ! -s "$T/git.err" ] && [ "$now" = "$SNAP0" ]; then ok "$1: read root unchanged (snapshot and git status --ignored)"
  else bad "$1: the read root changed — git [$(printf '%s' "$s" | tr '\n' ' ')] git-stderr [$(tr '\n' ' ' < "$T/git.err")] snapshot $([ "$now" = "$SNAP0" ] && echo same || echo DIFFERS)"; fi
  if [ "$(snapdir "$H")" = "$SNAPH0" ] && [ "$(snapdir "$CH")" = "$SNAPCH0" ]; then ok "$1: HOME and CODEX_HOME unchanged"
  else bad "$1: HOME or CODEX_HOME changed"; fi
}
: > "$R/stray.log"
{ [ -n "$(repo_state)" ] && [ "$(snap)" != "$SNAP0" ]; } || die "premise: a write to an IGNORED path is not seen by both checks — repo_clean would pass vacuously"
rm -f "$R/stray.log"
mkfifo "$R/stray.fifo" && ln -s x.ts "$R/stray.link" || die "cannot plant the snapshot premise entries"
_s="$(snap)"
case "$_s" in *'p ./stray.fifo'*) ;; *) die "premise: the snapshot does not record a FIFO" ;; esac
case "$_s" in *'l ./stray.link -> x.ts'*) ok "premise: the snapshot records a FIFO and a link with its target" ;;
  *) die "premise: the snapshot does not record a link target" ;; esac
rm -f "$R/stray.fifo" "$R/stray.link"
{ [ -z "$(repo_state)" ] && [ "$(snap)" = "$SNAP0" ]; } || die "premise: the read-root repo is not clean after setup"
ok "premise: repo_clean sees writes to ignored paths (git and the snapshot), and the repo starts clean"

# rec <name> <key> — every value of <key> in the spy's record; recj — the same joined with '|'.
rec() { awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }' "$SPY/$1.rec" 2>/dev/null; }
recj() { rec "$1" "$2" | awk '{ printf "%s%s", (NR > 1 ? "|" : ""), $0 } END { print "" }'; }
spy_ran() { if [ -s "$SPY/$1.rec" ]; then ok "$2: the $1 spy ran"; else bad "$2: the $1 spy never ran"; fi; }
spy_absent() { if [ -e "$SPY/$1.rec" ]; then bad "$2: the $1 spy WAS invoked"; else ok "$2: no $1 client invoked"; fi; }
no_client() { spy_absent codex "$1"; spy_absent claude "$1"; }
# under <path> <dir> — <path> is <dir> or below it, both sides canonical (pwd -P where the dir still
# exists; the spy's recorded pwd_P already is, and its temp dir is gone by the time this runs).
under() { case "$(phys "$1")/" in "$(phys "$2")"/*) return 0 ;; *) return 1 ;; esac; }
# note_pids — every spy of the last run that is STILL alive is recorded with its process group, for EXIT.
note_pids() {
  local n p g
  for n in codex claude; do
    p="$(rec "$n" pid)"; [ -n "$p" ] || continue
    g="$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')"
    [ -z "$g" ] || printf '%s %s\n' "$p" "$g" >> "$PIDS"
  done
}
# gone <pid> — true when the process no longer exists or is a zombie. wait_gone <pid> <secs> — bounded
# poll. expect_gone <label> <pid> <secs> — asserts it, and kills a leftover (and its group) on a failure.
gone() { local s; s="$(ps -o stat= -p "$1" 2>/dev/null)" || return 0; case "$s" in ''|*Z*) return 0 ;; esac; return 1; }
wait_gone() { local i=0; while ! gone "$1"; do [ "$i" -lt $(( $2 * 10 )) ] || return 1; sleep 0.1; i=$((i+1)); done; return 0; }
reap_leftover() { local g; g="$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ')"; [ -z "$g" ] || kill -KILL -- "-$g" 2>/dev/null; kill -KILL "$1" 2>/dev/null; }
expect_gone() {
  if [ -n "$2" ] && wait_gone "$2" "$3"; then ok "$1: the client is gone"
  else bad "$1: the client [$2] is still running"; [ -z "$2" ] || reap_leftover "$2"; fi
}
# The FULL status grammar; st <key> reads one field of the LAST stderr line only when that line has it.
SGRAM='^model-run: status=(ok|unavailable|invalid|empty|auth|timeout|error) client=(codex|claude)? model=[^ ]* effort=[^ ]* route=[^ ]*$'
st() {
  tail -n 1 "$T/e" 2>/dev/null | awk -v k="$1" -v re="$SGRAM" '
    $0 ~ re { n = split($0, f, " "); for (i = 2; i <= n; i++) { j = index(f[i], "="); if (substr(f[i], 1, j - 1) == k) { print substr(f[i], j + 1); found = 1 } } }
    END { if (!found) print "<no status line>" }'
}
nstatus() { awk -v re="$SGRAM" '$0 ~ re { n++ } END { print n + 0 }' "$T/e" 2>/dev/null; }   # full-grammar lines
nany() { awk 'index($0, "model-run: status=") == 1 { n++ } END { print n + 0 }' "$T/e" 2>/dev/null; }
last_is_status() { tail -n 1 "$T/e" 2>/dev/null | awk -v re="$SGRAM" '$0 ~ re { f = 1 } END { exit !f }'; }
# od_new <tag> — a fresh, unique, empty directory (mktemp -d) for one case's --out.
od_new() { mktemp -d "$T/out-$1.XXXXXX" || die "cannot create an out dir for $1"; }
only_file() { # only_file <label> <dir> <name>... — <dir> holds exactly those names (no temp, no stray, no dotfile)
  local l="$1" d="$2"; shift 2
  expect_eq "$l: the out dir holds exactly $*" "$(printf '%s\n' "$@" | sort | tr '\n' '/')" "$(entries "$d" | tr '\n' '/')"
}
dir_empty() { if [ -d "$2" ] && [ -z "$(entries "$2")" ]; then ok "$1: nothing written to the out dir (dotfiles included)"; else bad "$1: the out dir holds $(entries "$2" | tr '\n' ' ')"; fi; }
tmp_empty() { # tmp_empty <label> — TMPDIR still EXISTS and holds nothing
  if [ -d "$TMPD" ] && [ -z "$(entries "$TMPD")" ]; then ok "$1: TMPDIR left empty"
  else bad "$1: TMPDIR is gone or holds leftovers: $(entries "$TMPD" | tr '\n' ' ')"; fi
}

# seed <client> <line>... / seed_printf <client> <format> [args] / seed_file <client> <file> /
# seed_empty <client> — the exact bytes the NEXT run's <client> spy answers (seed_printf can end without a
# newline or carry a NUL). mr consumes the seeds; an unseeded client answers a marked UNSEEDED line.
seed() { local c="$1"; shift; printf '%s\n' "$@" > "$T/seed.$c" || die "cannot seed $c"; }
# shellcheck disable=SC2059  # the format IS the caller's byte recipe
seed_printf() { local c="$1" f="$2"; shift 2; printf "$f" "$@" > "$T/seed.$c" || die "cannot seed $c"; }
seed_file() { cp "$2" "$T/seed.$1" || die "cannot seed $1 from $2"; }
seed_empty() { : > "$T/seed.$1" || die "cannot seed $1"; }

# mr <label> [VAR=value ...] -- <model-run args...> — ONE run of $RUN_MR under env -i with stdin from
# /dev/null. One-shot settings, reset by every call: RUN_CWD (default: inside the read-root repo),
# RUN_EXEC=1 (execute $RUN_MR itself, through its shebang / PATH, instead of "$RBASH" "$RUN_MR"),
# MR_STDOUT=closed (stdout closed). RC = its status; stdout → $T/o, stderr → $T/e. Before: ALL spy state
# is cleared and the seeds applied. After, for EVERY run: the read root is unchanged, TMPDIR is empty, and
# stderr ends in exactly one full-grammar status line (none at all for a usage error, exit 2).
RUN_MR="$MR"; RUN_CWD=""; RUN_EXEC=0; MR_STDOUT=captured
mr() {
  local label="$1" envs=() c cmd cwd="${RUN_CWD:-$R}" ex="$RUN_EXEC" so="$MR_STDOUT"; shift
  RUN_CWD=""; RUN_EXEC=0; MR_STDOUT=captured
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  rm -f -- "${SPY:?}"/* "${SPY:?}"/.[!.]* "${SPY:?}"/..?*
  for c in codex claude; do
    if [ -f "$T/seed.$c" ]; then mv "$T/seed.$c" "$SPY/$c.reply" || die "cannot apply the $c seed"
    else printf 'UNSEEDED REPLY (%s)\n' "$label" > "$SPY/$c.reply" || die "cannot write the unseeded reply"; fi
  done
  if [ "$ex" = 1 ]; then cmd=("$RUN_MR"); else cmd=("$RBASH" "$RUN_MR"); fi
  RC=0
  if [ "$so" = closed ]; then
    ( cd "$cwd" && exec env -i HOME="$H" TMPDIR="$TMPD" CODEX_HOME="$CH" PATH="$T/shim:/usr/bin:/bin" SPY_DIR="$SPY" \
        ZUVO_CODEX_BIN="$SPYB/codex" ZUVO_CLAUDE_BIN="$SPYB/claude" ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_TIMEOUT_GRACE=1 \
        ${envs[@]+"${envs[@]}"} "${cmd[@]}" "$@" ) < /dev/null >&- 2> "$T/e" || RC=$?
    : > "$T/o"
  else
    ( cd "$cwd" && exec env -i HOME="$H" TMPDIR="$TMPD" CODEX_HOME="$CH" PATH="$T/shim:/usr/bin:/bin" SPY_DIR="$SPY" \
        ZUVO_CODEX_BIN="$SPYB/codex" ZUVO_CLAUDE_BIN="$SPYB/claude" ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_TIMEOUT_GRACE=1 \
        ${envs[@]+"${envs[@]}"} "${cmd[@]}" "$@" ) < /dev/null > "$T/o" 2> "$T/e" || RC=$?
  fi
  note_pids
  rm -f -- "${SPY:?}"/*.reply
  repo_clean "$label"
  tmp_empty "$label"
  if [ "$RC" -eq 2 ]; then
    expect_eq "$label: a usage error prints no status line" 0 "$(nany)"
  elif [ "$(nany)" = 1 ] && [ "$(nstatus)" = 1 ] && last_is_status; then
    ok "$label: stderr ends in exactly one full-grammar status line"
  else
    bad "$label: status-line contract broken (rc=$RC) — stderr: $(oneline "$T/e")"
  fi
}
expect_rc() { if [ "$RC" -eq "$2" ]; then ok "$1: exit $2"; else bad "$1: exit $RC, want $2 — stderr: $(oneline "$T/e")"; fi; }

printf 'Audit the files listed below.\n' > "$T/p.md"
READ=(--access read --read-root "$R")
REQ='^Tier: [ABCD]( |$)|^Red flags: .*-> AUTO TIER-D'
REJ='Tier: \[A/B/C/D\]|Red flags: \[AP13/AP14/AP16\]'
RR=(--require "$REQ" --reject "$REJ")

# ── A. Claude host → Codex (G1, K2) ──────────────────────────────────────────
echo "-- A. a Claude host is reviewed by Codex: registry primary, audit effort, read-only, isolated"
seed codex 'SPY ANSWER A' 'Tier: B'
mr "A" CLAUDECODE=1 SPY_STDERR="CLIENT-STDERR-MUST-NOT-SHOW" -- --route --mode audit "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "A" 0
expect_eq "A: the status line" "model-run: status=ok client=codex model=$P_CODEX effort=$E_CODEX route=cross-vendor" "$(tail -n 1 "$T/e")"
expect_eq "A: stderr is that ONE line and nothing else" 1 "$(nlines "$T/e")"
spy_ran codex "A"; spy_absent claude "A"
_cfg="$(recj codex config)"
expect_has "A: config model = registry primary" "model = \"$P_CODEX\"" "$_cfg"
expect_has "A: config model_reasoning_effort = high (K2)" "model_reasoning_effort = \"$E_CODEX\"" "$_cfg"
expect_has "A: config sandbox_mode = read-only" 'sandbox_mode = "read-only"' "$_cfg"
expect_has "A: config approval_policy = never" 'approval_policy = "never"' "$_cfg"
expect_not_has "A: none of the user's config (mcp_servers / its model)" "user-global-model" "$_cfg"
expect_eq "A: codex argv = exec, read-only sandbox, image viewer off" "exec|--skip-git-repo-check|-s|read-only|--disable|view_image" "$(recj codex arg)"
_ch="$(rec codex CODEX_HOME)"
if [ -n "$_ch" ] && [ "$_ch" != "$CH" ]; then ok "A: an isolated CODEX_HOME, not the user's"; else bad "A: CODEX_HOME [$_ch]"; fi
_pwd="$(rec codex pwd_P)"
if [ -n "$_pwd" ] && ! under "$_pwd" "$R" && ! under "$_pwd" "$ROOT" && under "$_pwd" "$TMPD"; then
  ok "A: neutral cwd (a runner temp dir, not the read root or the repo)"
else bad "A: the client ran in [$_pwd]"; fi
printf 'SPY ANSWER A\nTier: B\n' > "$T/want"; expect_bytes "A: stdout is the answer, byte for byte" "$T/o" "$T/want"
expect_not_has "A: the client's stderr is never shown" "CLIENT-STDERR" "$(cat "$T/e")"

# ── B. Codex host → claude -p (G2) ───────────────────────────────────────────
# zms_run_claude runs a none/read client in the runner's own temp dir ($TMPDIR/zms.*/cwd,
# model-subprocess.sh _zms_run_setup) — the same neutral-cwd guarantee as codex, so B asserts the same.
echo "-- B. a Codex host is reviewed by Opus 5.5 through claude -p, access read"
seed claude 'Tier: A'
mr "B" CODEX_SANDBOX=seatbelt -- --route --mode audit "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "B" 0
expect_eq "B: the status line" "model-run: status=ok client=claude model=$P_OPUS effort=$E_OPUS route=cross-vendor" "$(tail -n 1 "$T/e")"
spy_ran claude "B"; spy_absent codex "B"
_mcp="$(rec claude mcp_file)"
expect_eq "B: claude argv = --model <opus> --effort <e> + the access-read flags" \
  "--model|$P_OPUS|--effort|$E_OPUS|--print|--output-format|text|--tools|Read,Grep,Glob|--add-dir|$R|--safe-mode|--permission-prompts|none|--mcp-config|$_mcp|--strict-mcp-config|--no-session-persistence" \
  "$(recj claude arg)"
_pwd="$(rec claude pwd_P)"
if [ -n "$_pwd" ] && ! under "$_pwd" "$R" && ! under "$_pwd" "$ROOT" && under "$_pwd" "$TMPD"; then
  ok "B: neutral cwd (the claude runner's temp dir, not the read root or the repo)"
else bad "B: claude ran in [$_pwd]"; fi
printf 'Tier: A\n' > "$T/want"; expect_bytes "B: stdout is the answer, byte for byte" "$T/o" "$T/want"

# ── C. a route that is not ok runs nothing (K3) ──────────────────────────────
echo "-- C. a non-ok route: exit 1, status=unavailable route=<status>, no client"
# The router says cross-vendor-unavailable for a KNOWN writer whose cross-vendor CLI is missing (the
# in-family row it names instead — sonnet for an Opus writer — is exactly what model-run must not run),
# and unknown-writer-model when the writer is not known either.
_d="$(od_new c1)"
mr "C1" CLAUDECODE=1 CLAUDE_MODEL=opus ZUVO_CODEX_BIN=/nonexistent -- --route --mode audit "${READ[@]}" --prompt-file "$T/p.md" --out "$_d/c1.md"
expect_rc "C1" 1
expect_eq "C1: the status line" "model-run: status=unavailable client= model= effort= route=cross-vendor-unavailable" "$(tail -n 1 "$T/e")"
no_client "C1"; dir_empty "C1" "$_d"
expect_eq "C1: nothing on stdout (0 bytes)" 0 "$(wc -c < "$T/o" | tr -d ' ')"
mr "C2" CODEX_SANDBOX=seatbelt ZUVO_CODEX_MODEL="$P_CODEX" ZUVO_CLAUDE_BIN=/nonexistent -- --route --mode audit "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "C2" 1
expect_eq "C2: Codex host, claude missing" "model-run: status=unavailable client= model= effort= route=cross-vendor-unavailable" "$(tail -n 1 "$T/e")"
no_client "C2"
mr "C3" CLAUDECODE=1 ZUVO_CODEX_BIN=/nonexistent -- --route --mode audit "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "C3" 1
expect_eq "C3: Claude host, codex missing, writer unknown" "model-run: status=unavailable client= model= effort= route=unknown-writer-model" "$(tail -n 1 "$T/e")"
no_client "C3"

# ── D. stdin = prompt + append files, byte for byte ──────────────────────────
echo "-- D. --prompt-file + two --append-file = the client's stdin"
printf 'PROMPT HEAD, no trailing newline' > "$T/p1"
printf 'za\305\274\303\263\305\202\304\207 A1\n' > "$T/a1"
printf 'A2 tail\n\n' > "$T/a2"
cat "$T/p1" "$T/a1" "$T/a2" > "$T/cat"
_want="$(sha "$T/cat")"
if [ "${#_want}" -eq 64 ] && [ "$_want" != "$(sha "$T/p1")" ]; then
  ok "D: premise — the concatenation sha is real and differs from the prompt alone"
  seed codex 'Tier: A'
  mr "D" CLAUDECODE=1 -- --route "${READ[@]}" --prompt-file "$T/p1" --append-file "$T/a1" --append-file "$T/a2"
  expect_rc "D" 0
  expect_eq "D: stdin sha == sha(prompt ‖ a1 ‖ a2)" "$_want" "$(rec codex stdin_sha)"
  expect_eq "D: stdin bytes" "$(wc -c < "$T/cat" | tr -d ' ')" "$(rec codex stdin_bytes)"
  expect_eq "D: no --mode → no effort override (the client default)" "" "$(st effort)"
  expect_not_has "D: …and no model_reasoning_effort in config" "model_reasoning_effort" "$(recj codex config)"
else
  skip_block "D (stdin concatenation)" "the sha premise failed [$_want]"
fi

# ── E. --require / --reject (the test-audit anti-echo pair), --out, answer bytes ─
echo "-- E. --require / --reject; --out only on success, by rename, mode kept, never a non-regular file"
if grep -qF 'Tier: [A/B/C/D]' "$BATCH_PROMPT" && grep -qF 'Red flags: [AP13/AP14/AP16] -> AUTO TIER-D' "$BATCH_PROMPT"; then
  ok "E: premise — the real batch prompt holds both template lines"
  _d="$(od_new e1)"; seed_file codex "$BATCH_PROMPT"   # a client that echoes the batch prompt back
  mr "E1 echo" CLAUDECODE=1 -- --route --mode audit "${READ[@]}" --prompt-file "$BATCH_PROMPT" "${RR[@]}" --out "$_d/e1.md"
  expect_rc "E1 a client that echoes the batch prompt" 3
  expect_eq "E1: status=invalid" "invalid" "$(st status)"
  dir_empty "E1" "$_d"
  expect_eq "E1: nothing on stdout (0 bytes)" 0 "$(wc -c < "$T/o" | tr -d ' ')"
  _d="$(od_new e2)"; seed codex 'Red flags: [AP13/AP14/AP16] -> AUTO TIER-D'
  mr "E2 template" CLAUDECODE=1 -- --route "${READ[@]}" --prompt-file "$BATCH_PROMPT" "${RR[@]}" --out "$_d/e2.md"
  expect_rc "E2 an echo of the AUTO TIER-D template only" 3
  expect_eq "E2: status=invalid" "invalid" "$(st status)"
  dir_empty "E2" "$_d"
  printf '### tests/a.test.ts\nRed flags: AP13 -> AUTO TIER-D\n### tests/b.test.ts\nRed flags: AP14, AP16 -> AUTO TIER-D\n' > "$T/e4.want"
  _d="$(od_new e4)"; seed_file codex "$T/e4.want"
  mr "E4 all AUTO TIER-D" CLAUDECODE=1 -- --route --mode audit "${READ[@]}" --prompt-file "$BATCH_PROMPT" "${RR[@]}" --out "$_d/e4.md"
  expect_rc "E4 a legitimate batch of ONLY AUTO TIER-D short-format entries, on the real batch prompt" 0
  expect_bytes "E4: --out holds the answer, byte for byte" "$_d/e4.md" "$T/e4.want"
  only_file "E4" "$_d" e4.md
  expect_eq "E4: with --out, nothing on stdout (0 bytes)" 0 "$(wc -c < "$T/o" | tr -d ' ')"
else
  skip_block "E1, E2, E4 (the batch-prompt cases)" "the batch prompt lacks a template line — an echo would prove nothing"
fi
_d="$(od_new e3)"; seed codex 'I could not audit this batch.'
mr "E3 neither" CLAUDECODE=1 -- --route "${READ[@]}" --prompt-file "$T/p.md" "${RR[@]}" --out "$_d/e3.md"
expect_rc "E3 an answer with no Tier line and no filled AUTO TIER-D line" 3
expect_eq "E3: status=invalid" "invalid" "$(st status)"
dir_empty "E3" "$_d"
# E5: a client that STREAMS its answer in six chunks 0.3 s apart (each chunk it wrote is logged). Its
# control — the chunk and the log — is baked into the stub as file paths, never passed through model-run's
# environment. A watcher polls --out the whole time — each round it samples --out FIRST, then looks for the
# stop file — and it is joined (wait) before anything is asserted: whenever --out existed it was already
# the whole answer, the watcher saw the final file, and it ended on the stop file, not its cap.
mkdir -p "$T/streamb" || die "cannot create the streaming stub dir"
{ printf 'Tier: B (score 17/25)\n'; _i=0
  while [ "$_i" -lt 700 ]; do printf 'Q%04d: evidence line that pads the report to a realistic size ....\n' "$_i"; _i=$((_i+1)); done
} > "$T/e5.part"
: > "$T/e5.want"; for _i in 1 2 3 4 5 6; do cat "$T/e5.part" >> "$T/e5.want"; done
printf '#!/bin/sh\n# a codex stand-in that answers in six chunks, slowly, logging each chunk it wrote\ncase "${1:-}" in\n  --version) echo "codex-cli 0.156.1"; exit 0 ;;\n  exec) ;;\n  *) echo "streaming stub: unexpected argv: $*" >&2; exit 64 ;;\nesac\ncat > /dev/null\ni=0\nwhile [ "$i" -lt 6 ]; do cat "%s"; echo "chunk $i" >> "%s"; sleep 0.3; i=$((i+1)); done\n' \
  "$T/e5.part" "$T/e5.chunks" > "$T/streamb/codex" && chmod +x "$T/streamb/codex" || die "cannot write the streaming stub"
watch_out() { # <out> <stop-file> <want> <chunk-log> — "A <chunks written so far>" absent, F the full answer,
  # P anything else; STOP / CAP last
  local n=0
  while [ "$n" -lt 900 ]; do
    if [ -e "$1" ]; then if cmp -s "$1" "$3"; then echo F; else echo P; fi; else echo "A $(awk 'END { print NR }' "$4")"; fi
    if [ -e "$2" ]; then echo STOP; return 0; fi
    sleep 0.02; n=$((n+1))
  done
  echo CAP
}
_d="$(od_new e5)"; : > "$T/e5.chunks"
watch_out "$_d/e5.md" "$T/e5.stop" "$T/e5.want" "$T/e5.chunks" > "$T/e5.log" & _wp=$!; echo "$_wp" >> "$BGPIDS"
mr "E5 streamed answer" CLAUDECODE=1 ZUVO_CODEX_BIN="$T/streamb/codex" -- \
  --route --mode audit "${READ[@]}" --prompt-file "$T/p.md" "${RR[@]}" --out "$_d/e5.md"
sleep 0.3; : > "$T/e5.stop"; wait "$_wp"
expect_rc "E5 a valid full answer, streamed slowly" 0
expect_eq "E5: premise — the client really streamed six chunks" 6 "$(nlines "$T/e5.chunks")"
expect_bytes "E5: --out holds the whole answer" "$_d/e5.md" "$T/e5.want"
_np="$(awk '$0 == "P"' "$T/e5.log" | wc -l | tr -d ' ')"
_nf="$(awk '$0 == "F"' "$T/e5.log" | wc -l | tr -d ' ')"
# The premise comes from the stub's own loop, not from a sampling rate: the watcher must have found --out
# absent MID-stream (after chunk 1 and before chunk 6) at two different points of the stream at least.
# Two, not all five 0.3 s windows: each poll forks awk, and a loaded host may miss a window — that is the
# watcher's delay, not a defect of model-run; two distinct mid-stream counts still prove it watched while
# the client streamed, and the partial-sample check below is what model-run is judged by.
_seen="$(awk '$1 == "A" && $2 >= 1 && $2 <= 5 { s[$2] = 1 } END { n = 0; for (k in s) n++; print n }' "$T/e5.log")"
if [ "$_seen" -ge 2 ]; then ok "E5: premise — the watcher found --out absent at $_seen distinct points mid-stream (chunks 1..5)"
else bad "E5: premise — the watcher found --out absent at only $_seen distinct mid-stream point(s) (want >= 2): the case proves nothing"; fi
expect_eq "E5: the watcher never saw a partial --out" 0 "$_np"
if [ "$_nf" -ge 1 ]; then ok "E5: the watcher saw the final, complete --out ($_nf samples)"; else bad "E5: the watcher never saw the complete --out"; fi
expect_eq "E5: the watcher ended on the stop file, not its cap" STOP "$(tail -n 1 "$T/e5.log")"
only_file "E5" "$_d" e5.md
# E6: --out already exists (mode 0640) and a hard link holds its old bytes. A rename-based replace leaves
# the old inode — and so the link — untouched; rewriting the file in place would change the link too.
_d="$(od_new e6)"; printf 'OLD ANSWER\n' > "$_d/e6.md"; chmod 640 "$_d/e6.md"; ln "$_d/e6.md" "$_d/e6.hardlink" || die "cannot hard-link e6"   # same dir: never cross-filesystem
_ino="$(inode "$_d/e6.md")"
seed codex 'Tier: A (the new answer)'
mr "E6 replace" CLAUDECODE=1 -- --route "${READ[@]}" --prompt-file "$T/p.md" "${RR[@]}" --out "$_d/e6.md"
expect_rc "E6 an existing --out is replaced" 0
printf 'Tier: A (the new answer)\n' > "$T/want"; expect_bytes "E6: --out holds the new answer" "$_d/e6.md" "$T/want"
printf 'OLD ANSWER\n' > "$T/want"; expect_bytes "E6: a hard link to the OLD file still reads the old bytes (replaced by rename, never rewritten)" "$_d/e6.hardlink" "$T/want"
if [ -n "$_ino" ] && [ "$(inode "$_d/e6.md")" != "$_ino" ]; then ok "E6: --out is a new inode"; else bad "E6: --out kept inode $_ino"; fi
expect_eq "E6: the replacement keeps the existing file's mode" 640 "$(fmode "$_d/e6.md")"
only_file "E6" "$_d" e6.md e6.hardlink
# E7: a symlink or any other non-regular --out is refused before anything runs; what it points at stays.
printf 'OUTSIDE\n' > "$T/outside.txt"; _od="$(od_new outside-dir)"
_d="$(od_new e7)"; ln -s "$T/outside.txt" "$_d/to-file.md"; ln -s "$_od" "$_d/to-dir.md"; ln -s "$T/nonexistent" "$_d/dangling.md"
mkfifo "$_d/fifo.md" || die "cannot create a FIFO"
for _l in to-file to-dir dangling fifo; do
  seed codex 'Tier: A'
  mr "E7 --out a $_l" CLAUDECODE=1 -- --route "${READ[@]}" --prompt-file "$T/p.md" --out "$_d/$_l.md"
  expect_rc "E7 --out a $_l is refused" 2
  no_client "E7 ($_l)"
done
for _l in to-file to-dir dangling; do if [ -L "$_d/$_l.md" ]; then ok "E7 ($_l): the link is left as it was"; else bad "E7 ($_l): the link was replaced"; fi; done
if [ -p "$_d/fifo.md" ]; then ok "E7 (fifo): the FIFO is left as it was"; else bad "E7 (fifo): the FIFO was replaced"; fi
printf 'OUTSIDE\n' > "$T/want"; expect_bytes "E7: the file a link pointed at is unchanged" "$T/outside.txt" "$T/want"
dir_empty "E7: the directory a link pointed at" "$_od"
# E8: answers are passed through byte for byte — no final newline, a NUL byte — and a LONG answer that
# merely discusses login / unauthorized is an answer, not an auth error (the stub check is length-guarded).
seed_printf codex 'Tier: A (no final newline)'
mr "E8a no final newline" CLAUDECODE=1 -- --route "${READ[@]}" --prompt-file "$T/p.md" "${RR[@]}"
expect_rc "E8a an answer without a final newline" 0
printf 'Tier: A (no final newline)' > "$T/want"; expect_bytes "E8a: stdout is exactly the answer (no newline added)" "$T/o" "$T/want"
seed_printf codex 'Tier: B\n\000binary tail\n'
mr "E8b a NUL byte" CLAUDECODE=1 -- --route "${READ[@]}" --prompt-file "$T/p.md" "${RR[@]}"
expect_rc "E8b an answer with a NUL byte" 0
printf 'Tier: B\n\000binary tail\n' > "$T/want"; expect_bytes "E8b: stdout carries the NUL unchanged" "$T/o" "$T/want"
{ printf 'Tier: C (score 12/25)\n'; _i=0
  while [ "$_i" -lt 12 ]; do printf 'Finding %d: the login flow returns unauthorized when the token is stale; not logged in is untested.\n' "$_i"; _i=$((_i+1)); done
} > "$T/e8c.want"
seed_file codex "$T/e8c.want"
mr "E8c a long answer about login" CLAUDECODE=1 SPY_STDERR="warning: not logged in to the telemetry service" -- --route "${READ[@]}" --prompt-file "$T/p.md" "${RR[@]}"
expect_rc "E8c a long legitimate answer that discusses login / unauthorized" 0
expect_eq "E8c: status=ok, not auth" ok "$(st status)"
expect_bytes "E8c: stdout is the answer" "$T/o" "$T/e8c.want"

# ── F. timeout ───────────────────────────────────────────────────────────────
# 124 is GNU timeout's own status for "the budget fired" (a 30 s client that was waited out would have
# answered, exit 0), and the client being gone right after shows it was stopped there. One more guard, a
# ONE-SIDED ceiling from model-run's own bounds: budget (1 s) + grace (1 s, the ZUVO_TIMEOUT_GRACE every
# mr run gets) + RUNNER_CLEANUP_SLACK (read from model-run) + 5 s for a loaded host — 14 s today, against
# an expected ~2 s. A model-run that fired the budget and then still waited for something holding the
# answer pipe (a grandchild of the client) returns 124 too, only after ~30 s; one that added a further
# wait of its own beyond grace + slack would pass 14 s as well.
_slack="$(awk -F'[= ]' '/^readonly RUNNER_CLEANUP_SLACK=/ { print $3; exit }' "$MR")"
case "$_slack" in ""|*[!0-9]*) bad "F: RUNNER_CLEANUP_SLACK not read from $MR (got [$_slack]) — the ceiling falls back to 30 s"; _slack=23 ;; esac
F_CEIL=$((1 + 1 + _slack + 5))
unset _slack
echo "-- F. a client that outlives --timeout (budget 1 s, client 30 s)"
_d="$(od_new f)"; seed codex 'Tier: A'
_t0=$SECONDS
mr "F" CLAUDECODE=1 SPY_SLEEP=30 -- --route "${READ[@]}" --prompt-file "$T/p.md" --timeout 1 --out "$_d/f.md"
_el=$((SECONDS - _t0))
expect_rc "F stopped at the budget, not waited out" 124
if [ "$_el" -lt "$F_CEIL" ]; then ok "F: ended in ${_el}s, far inside the client's 30 s"; else bad "F: took ${_el}s — the 30 s client was waited out after the budget fired"; fi
expect_eq "F: status=timeout" "timeout" "$(st status)"
spy_ran codex "F"
expect_gone "F" "$(rec codex pid)" 5
dir_empty "F" "$_d"
# F2: a client that IGNORES TERM. No signal reaches model-run here: it is the RUNNER's GNU timeout that
# sends TERM at the budget and KILL after its grace, so the runner returns 137 with the budget used up —
# a timeout too (the 137 rule's true arm). model-run's own process-group teardown is exercised in R6 / Q.
seed codex 'Tier: A'
_t0=$SECONDS
mr "F2" CLAUDECODE=1 SPY_SLEEP=30 SPY_IGNORE_TERM=1 -- --route "${READ[@]}" --prompt-file "$T/p.md" --timeout 1
_el=$((SECONDS - _t0))
expect_rc "F2 a TERM-ignoring client KILLed after the budget (137)" 124
if [ "$_el" -lt "$F_CEIL" ]; then ok "F2: ended in ${_el}s, far inside the client's 30 s"; else bad "F2: took ${_el}s — the TERM-ignoring 30 s client was waited out"; fi
expect_eq "F2: status=timeout" "timeout" "$(st status)"
expect_gone "F2" "$(rec codex pid)" 5

# ── G. client missing / could not start ──────────────────────────────────────
echo "-- G. an explicit model whose CLI is missing, and a runner that cannot start the client"
mr "G1" ZUVO_CODEX_BIN=/nonexistent -- --model "$P_CODEX" --prompt-file "$T/p.md"
expect_rc "G1 codex missing" 1
expect_eq "G1: the status line" "model-run: status=unavailable client=codex model=$P_CODEX effort= route=explicit" "$(tail -n 1 "$T/e")"
no_client "G1"
mr "G2" ZUVO_CLAUDE_BIN=/nonexistent -- --model "$P_OPUS" --prompt-file "$T/p.md"
expect_rc "G2 claude missing" 1
expect_eq "G2: status=unavailable client=claude" "unavailable claude" "$(st status) $(st client)"
no_client "G2"
# No auth.json, and no OPENAI_API_KEY: mr runs model-run under `env -i`, so its environment is exactly
# the variables mr passes (HOME, TMPDIR, CODEX_HOME — here an empty dir — PATH, SPY_DIR, the ZUVO_* seams,
# CLAUDECODE) and nothing of the caller's. The runner refuses to START codex: unavailable, told apart from
# a client that ran and exited 2 (I2) by whether the client ever started.
mkdir -p "$T/codex-noauth"
mr "G3" CLAUDECODE=1 CODEX_HOME="$T/codex-noauth" -- --route "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "G3 the runner could not start codex (no credentials)" 1
expect_eq "G3: status=unavailable" "unavailable" "$(st status)"
expect_has "G3: the runner's own reason reaches stderr" "no auth.json" "$(cat "$T/e")"
no_client "G3"

# ── H. auth errors ───────────────────────────────────────────────────────────
echo "-- H. an auth error instead of an answer — on stdout, or on stderr behind any unusable answer"
_d="$(od_new h1)"; seed codex "$(printf 'Error: Not logged in \302\267 Please run /login')"
mr "H1" CLAUDECODE=1 -- --route "${READ[@]}" --prompt-file "$T/p.md" --out "$_d/h1.md"
expect_rc "H1 exit 0 with an auth stub on stdout" 3
expect_eq "H1: status=auth" "auth" "$(st status)"
dir_empty "H1" "$_d"
seed_empty codex
mr "H2" CLAUDECODE=1 SPY_EXIT=1 SPY_STDERR="Error: not logged in" -- --route "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "H2 exit 1 with an auth error on stderr" 3
expect_eq "H2: status=auth" "auth" "$(st status)"
seed_empty codex
mr "H3" CLAUDECODE=1 SPY_STDERR="Error: not logged in" -- --route "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "H3 exit 0, empty stdout, the auth error on stderr" 3
expect_eq "H3: status=auth, not empty" "auth" "$(st status)"
seed codex 'I cannot help with that.'
mr "H4" CLAUDECODE=1 SPY_STDERR="Please run /login" -- --route "${READ[@]}" --prompt-file "$T/p.md" "${RR[@]}"
expect_rc "H4 exit 0, an answer that misses --require, the auth error on stderr" 3
expect_eq "H4: status=auth, not invalid" "auth" "$(st status)"
seed codex 'Red flags: [AP13/AP14/AP16] -> AUTO TIER-D'
mr "H5" CLAUDECODE=1 SPY_STDERR="Please run /login" -- --route "${READ[@]}" --prompt-file "$T/p.md" "${RR[@]}"
expect_rc "H5 exit 0, an answer that hits --reject, the auth error on stderr (R6)" 3
expect_eq "H5: status=auth, not invalid" "auth" "$(st status)"

# ── I. a client that ran and failed (exit 4) ─────────────────────────────────
echo "-- I. a client that ran and failed: status=error, exit 4 (the caller falls back)"
_d="$(od_new i1)"; seed_empty codex
mr "I1" CLAUDECODE=1 SPY_EXIT=1 SPY_STDERR="boom: internal failure" -- --route "${READ[@]}" --prompt-file "$T/p.md" --out "$_d/i1.md"
expect_rc "I1 a client exiting 1" 4
expect_eq "I1: status=error client=codex" "error codex" "$(st status) $(st client)"
expect_not_has "I1: its stderr is not shown" "boom" "$(cat "$T/e")"
dir_empty "I1" "$_d"
seed codex 'Tier: A'
mr "I2" CLAUDECODE=1 SPY_EXIT=2 -- --route "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "I2 a client that STARTED and exited 2 (not the runner's could-not-start 2)" 4
spy_ran codex "I2"
seed codex 'Tier: A'
mr "I3" CLAUDECODE=1 SPY_EXIT=137 -- --route "${READ[@]}" --prompt-file "$T/p.md" --timeout 60
expect_rc "I3 a 137 long before the budget is a kill, not a timeout" 4
expect_eq "I3: status=error" "error" "$(st status)"
seed_empty claude
mr "I4" CODEX_SANDBOX=seatbelt SPY_EXIT=1 SPY_STDERR="API Error: Unable to connect to API (ConnectionRefused)" -- \
  --route --mode audit "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "I4 a nested claude -p that cannot reach its API (network-off codex sandbox)" 4
expect_eq "I4: status=error client=claude" "error claude" "$(st status) $(st client)"

# ── K. empty answer ──────────────────────────────────────────────────────────
echo "-- K. an empty answer"
seed_empty codex
mr "K1" CLAUDECODE=1 -- --route "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "K1 a truly empty answer (0 bytes)" 3
expect_eq "K1: status=empty" "empty" "$(st status)"
expect_eq "K1: nothing on stdout (0 bytes)" 0 "$(wc -c < "$T/o" | tr -d ' ')"
printf '  \n\t\n\n' > "$T/k2.reply"; seed_file codex "$T/k2.reply"
mr "K2" CLAUDECODE=1 -- --route "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "K2 whitespace only" 3
expect_eq "K2: status=empty" "empty" "$(st status)"

# ── L. usage errors (exit 2) — every vector a real argument array, on a Claude host with the codex spy
# armed, so a run that slipped through shows up as an invoked client ─────────
echo "-- L. usage errors: exit 2, nothing run; the --timeout boundaries reach the client"
: > "$T/not-a-dir"; _ld="$(od_new l-dir)"
lcase() { local label="$1"; shift; mr "L $label" CLAUDECODE=1 -- "$@"; expect_rc "L $label" 2; no_client "L $label"; }
lcase "no arguments"
lcase "--route and --model" --route --model "$P_CODEX" --prompt-file "$T/p.md"
lcase "neither --route nor --model" --prompt-file "$T/p.md"
lcase "no --prompt-file" --route
lcase "a missing prompt file" --route --prompt-file "$T/nonexistent"
lcase "a missing append file" --route --prompt-file "$T/p.md" --append-file "$T/nonexistent"
lcase "--access read without --read-root" --route --prompt-file "$T/p.md" --access read
lcase "--read-root that is not a directory" --route --prompt-file "$T/p.md" --access read --read-root "$T/not-a-dir"
lcase "--read-root without --access read" --route --prompt-file "$T/p.md" --read-root "$R"
lcase "--access agent" --route --prompt-file "$T/p.md" --access agent
lcase "an unknown --mode" --route --prompt-file "$T/p.md" --mode fast
lcase "--timeout 0 (below the grammar's minimum 1)" --route --prompt-file "$T/p.md" --timeout 0
lcase "--timeout 1.5" --route --prompt-file "$T/p.md" --timeout 1.5
lcase "--timeout 010 (a leading zero)" --route --prompt-file "$T/p.md" --timeout 010
lcase "--timeout 100000 (above the grammar's maximum 99999)" --route --prompt-file "$T/p.md" --timeout 100000
lcase "--timeout -5" --route --prompt-file "$T/p.md" --timeout -5
lcase "--timeout of blanks only" --route --prompt-file "$T/p.md" --timeout "  "
lcase "an invalid --require ERE" --route --prompt-file "$T/p.md" --require '(ab'
lcase "an invalid --reject ERE" --route --prompt-file "$T/p.md" --reject '[ab'
lcase "an empty --require (it would match everything)" --route --prompt-file "$T/p.md" --require ""
lcase "an empty --reject (it would reject everything)" --route --prompt-file "$T/p.md" --reject ""
lcase "--out in a missing directory" --route --prompt-file "$T/p.md" --out "$T/nonexistent/x.md"
lcase "--out that is a directory" --route --prompt-file "$T/p.md" --out "$_ld"
lcase "an unknown flag" --route --prompt-file "$T/p.md" --bogus
lcase "a flag with no value at the end" --route --prompt-file
lcase "an empty value" --route --prompt-file ""
lcase "--model outside the id charset" --model 'gpt-6-sol;touch' --prompt-file "$T/p.md"
lcase "a model id with a blank" --model "gpt 6" --prompt-file "$T/p.md"
lcase "--model no CLI serves (the orchestrator's carry-forward item #4: an unmappable --model is a usage error)" --model gemini-3.1-pro --prompt-file "$T/p.md"
lcase "--model gpt-oss (not the codex CLI)" --model gpt-oss-120b --prompt-file "$T/p.md"
# Both boundaries accepted — and handed on: a recording GNU timeout shows the budget the CLIENT got. The
# budget is read as timeout's DURATION operand (the first operand after its options, whatever they are),
# and the command it runs must be the codex spy.
mkdir -p "$T/tshim" || die "cannot create $T/tshim"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$TIMEOUT_LOG"\nexec "%s" "$@"\n' "$REAL_TIMEOUT" > "$T/tshim/timeout" && chmod +x "$T/tshim/timeout" \
  || die "cannot write the recording timeout"
tbudget() { # tbudget <log> <command> — the duration of every timeout call that ran <command>
  awk -v c="$2" '{ i = 1
    while (i <= NF) { if ($i == "-k" || $i == "-s" || $i == "--kill-after" || $i == "--signal") { i += 2; continue }
                      if ($i ~ /^-/) { i++; continue }; break }
    if ($(i + 1) == c) print $i }' "$1"
}
for _b in 1 99999; do
  : > "$T/timeout.log"; seed codex 'Tier: A'
  mr "L --timeout $_b is accepted" CLAUDECODE=1 PATH="$T/tshim:$T/shim:/usr/bin:/bin" TIMEOUT_LOG="$T/timeout.log" -- --route --prompt-file "$T/p.md" --timeout "$_b"
  expect_rc "L --timeout $_b is accepted" 0
  case " $(tbudget "$T/timeout.log" "$SPYB/codex" | tr '\n' ' ')" in
    *" $_b "*) ok "L --timeout $_b: the client ran under GNU timeout with a duration of exactly $_b s" ;;
    *) bad "L --timeout $_b: no client run under a $_b s duration — timeout calls: $(oneline "$T/timeout.log")" ;;
  esac
done

# ── M/N. explicit --model, --access none, option-shaped paths ────────────────
echo "-- M. --model <id>: the client from zms_client_for_model, route=explicit; N. --access none; N2. option-shaped paths"
seed codex 'Tier: C'
mr "M1" -- --model "$P_CODEX" --mode audit "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "M1" 0
expect_eq "M1: the status line" "model-run: status=ok client=codex model=$P_CODEX effort=$E_CODEX route=explicit" "$(tail -n 1 "$T/e")"
spy_ran codex "M1"
seed claude 'Tier: C'
mr "M2" -- --model "$P_OPUS" --mode audit --prompt-file "$T/p.md"
expect_rc "M2" 0
expect_eq "M2: the status line" "model-run: status=ok client=claude model=$P_OPUS effort=$E_OPUS route=explicit" "$(tail -n 1 "$T/e")"
expect_has "M2: --access none (the default) → no tools" "--tools||--safe-mode" "$(recj claude arg)"
seed codex 'Tier: C'
mr "N" CLAUDECODE=1 -- --route --prompt-file "$T/p.md"
expect_rc "N --access none on the codex route" 0
expect_eq "N: codex argv with every read primitive off" \
  "exec|--skip-git-repo-check|-s|read-only|--disable|shell_tool|--disable|unified_exec|--disable|view_image" "$(recj codex arg)"
# N2: relative paths that look like options — from their own CWD — are files, never flags (R5).
_nd="$(mktemp -d "$T/n2.XXXXXX")" || die "cannot create the N2 dir"
printf 'PROMPT FILE NAMED -p\n' > "$_nd/-p" && mkdir "$_nd/-d" || die "cannot build the N2 layout"
for _o in -n --help.md "with space.md" -d/answer.md; do
  seed codex 'Tier: A'
  RUN_CWD="$_nd"
  mr "N2 --out [$_o]" CLAUDECODE=1 -- --route --prompt-file -p --out "$_o"
  expect_rc "N2 --out [$_o]" 0
  printf 'Tier: A\n' > "$T/want"; expect_bytes "N2 [$_o]: the answer landed in [$_o]" "$_nd/$_o" "$T/want"
  expect_eq "N2 [$_o]: the client read the prompt FILE named -p" "$(sha "$_nd/-p")" "$(rec codex stdin_sha)"
done
only_file "N2: nothing else was written beside them (no temp file)" "$_nd" --help.md -d -n -p "with space.md"
only_file "N2: …nor in -d/" "$_nd/-d" answer.md
# N2b: an option-shaped --read-root (relative, from its own CWD) is a directory, never a flag: claude gets
# it — physical and absolute — as its --add-dir.
_nr="$(mktemp -d "$T/n2b.XXXXXX")" || die "cannot create the N2b dir"
printf 'Audit.\n' > "$_nr/prompt.md" && mkdir "$_nr/-d" "$_nr/-p" "$_nr/with space" || die "cannot build the N2b layout"
for _r in -d -p "with space"; do
  seed claude 'Tier: A'
  RUN_CWD="$_nr"
  mr "N2b --read-root [$_r]" CODEX_SANDBOX=seatbelt -- --route --access read --read-root "$_r" --prompt-file prompt.md
  expect_rc "N2b --read-root [$_r]" 0
  expect_has "N2b [$_r]: claude reads exactly that directory (--add-dir)" "--add-dir|$(phys "$_nr/$_r")|" "$(recj claude arg)"
done

# ── O. a stub router: same-vendor ok, and every break of the byte-exact contract ─────────────────
# The stub stands where model-run looks FIRST (beside itself), next to a copy of the real runner library;
# the registry comes from the stub HOME's ~/.zuvo. It prints the FILE $STUB_ROUTE_FILE (every good row
# ends with a newline, like the real router's printf), touches $STUB_ROUTE_MARK when given, and exits
# $STUB_ROUTE_EXIT (default 0).
echo "-- O. a stub router: same-vendor ok, malformed or oversized answers and a failing router are refused (exit 1, nothing run)"
S="$T/stub"; SH="$T/stubhome"
mkdir -p "$S/lib" "$SH/.zuvo" || die "cannot create the stub layout"
cp "$MR" "$S/model-run" || die "cannot copy model-run into the stub layout"
cp "$LIB" "$S/lib/model-subprocess.sh" || die "cannot copy the runner into the stub layout"
cp "$REG" "$SH/.zuvo/model-registry.sh" || die "cannot copy the registry into the stub HOME"
# Without STUB_ROUTE_EXIT the router IS cat (exec): a reader that stops early kills it with SIGPIPE, the
# way a real single-process writer dies — so an oversized answer shows what the reader did to the router.
printf '#!/bin/sh\n[ -z "${STUB_ROUTE_MARK:-}" ] || : > "$STUB_ROUTE_MARK"\n[ -n "${STUB_ROUTE_EXIT:-}" ] || exec cat "$STUB_ROUTE_FILE"\ncat "$STUB_ROUTE_FILE"\nexit "$STUB_ROUTE_EXIT"\n' > "$S/reviewer-model-route.sh" \
  || die "cannot write the stub router"
# rowf <file> <platform> <writer> <writer_lane> <reviewer_lane> <reviewer_model> <status> — a six-key answer, newline-terminated.
rowf() { local f="$1"; shift; printf 'platform=%s\nwriter_model=%s\nwriter_lane=%s\nreviewer_lane=%s\nreviewer_model=%s\nrouting_status=%s\n' "$@" > "$f" || die "cannot write $f"; }
RF="$T/routes"; mkdir -p "$RF" || die "cannot create $RF"
RUN_MR="$S/model-run"
rowf "$RF/o0" claude unknown unknown cross-vendor gpt-stub-x ok
# O0: a well-formed row. Its prompt is unique to THIS run, so the spy's stdin hash proves this run invoked it.
printf 'O0 control prompt %s-%s\n' "$$" "$RANDOM" > "$T/o0-prompt.md"
seed codex 'Tier: A'
mr "O0 control" HOME="$SH" CLAUDECODE=1 STUB_ROUTE_FILE="$RF/o0" -- --route --mode audit "${READ[@]}" --prompt-file "$T/o0-prompt.md"
expect_rc "O0 a well-formed cross-vendor ok row through the stub" 0
expect_eq "O0: the stub IS the router in use (its model id)" "model-run: status=ok client=codex model=gpt-stub-x effort=$E_CODEX route=cross-vendor" "$(tail -n 1 "$T/e")"
OSKIP=0
[ "$RC" -eq 0 ] || OSKIP=1
if [ "$(rec codex stdin_sha)" = "$(sha "$T/o0-prompt.md")" ]; then ok "O0: THIS run invoked the codex spy (its unique prompt reached it)"
else OSKIP=1; bad "O0: the codex spy did not receive this run's prompt"; fi
# The bad answers, each a file.
rowf "$RF/sv1" claude unknown unknown cross-vendor "$P_OPUS" ok
rowf "$RF/sv2" codex unknown unknown cross-vendor "$P_CODEX" ok
rowf "$RF/sv3" codex unknown unknown cross-vendor "$P_OPUS" ok
rowf "$RF/sv4" claude unknown unknown cross-vendor "$P_CODEX" ok
{ cat "$RF/o0"; printf 'reviewer_model=%s\n' "$P_CODEX"; } > "$RF/dup"
awk '!/^writer_lane=/' "$RF/o0" > "$RF/five"
sed 's/^writer_lane=/extra=/' "$RF/o0" > "$RF/extrakey"
awk '{ print } /^writer_model=/ { print "" }' "$RF/o0" > "$RF/blankinside"
{ cat "$RF/o0"; printf '\n'; } > "$RF/blank7"
rowf "$RF/emptyval" claude unknown "" cross-vendor gpt-stub-x ok
rowf "$RF/cr" claude unknown unknown "$(printf 'cross-vendor\r')" gpt-stub-x ok
rowf "$RF/nonascii" claude "$(printf 'opus\303\251')" unknown cross-vendor gpt-stub-x ok
{ printf 'platform=claude\nwriter_model=un\000known\n'; awk '!/^platform=|^writer_model=/' "$RF/o0"; } > "$RF/nul"
head -c "$(( $(wc -c < "$RF/o0") - 1 ))" "$RF/o0" > "$RF/nofinalnl"
rowf "$RF/charset" claude unknown unknown cross-vendor "gpt-6-sol;touch" ok
rowf "$RF/nocli" claude unknown unknown cross-vendor gemini-3.1-pro ok
rowf "$RF/cursor" cursor composer-2 strong_primary review-alt "$P_CODEX" ok
rowf "$RF/big" claude "$(awk 'BEGIN { while (n++ < 5000) printf "x" }')" unknown cross-vendor gpt-stub-x ok
# Over 4 KB although its first 4096 bytes are a VALID six-key record: the cap, not the parser, refuses it.
{ cat "$RF/o0"; awk 'BEGIN { while (n++ < 80) print "# padding line that takes the answer past four kilobytes ....." }'; } > "$RF/bigvalid"
# The cap is INCLUSIVE: a valid record of exactly 4096 bytes is used, one of 4097 is not (the writer id is
# padded to land on each size — the record stays the same six valid keys).
_ob=$(( $(wc -c < "$RF/o0") - 7 ))
rowf "$RF/edge4096" claude "$(awk -v n=$((4096 - _ob)) 'BEGIN { while (i++ < n) printf "x" }')" unknown cross-vendor gpt-stub-x ok
rowf "$RF/edge4097" claude "$(awk -v n=$((4097 - _ob)) 'BEGIN { while (i++ < n) printf "x" }')" unknown cross-vendor gpt-stub-x ok
# 100 KB — far more than a pipe holds.
{ cat "$RF/o0"; awk 'BEGIN { while (n++ < 1600) print "# padding line that takes the answer past a pipe buffer ......" }'; } > "$RF/huge"
sed 's/^platform=/Platform=/' "$RF/o0" > "$RF/keycase1"
sed 's/^platform=/PLATFORM=/' "$RF/o0" > "$RF/keycase2"
rowf "$RF/writer-shape" claude 'a;b' unknown cross-vendor gpt-stub-x ok
rowf "$RF/writer-lane" claude unknown zzz cross-vendor gpt-stub-x ok
rowf "$RF/platform-enum" claud unknown unknown cross-vendor gpt-stub-x ok
rowf "$RF/lane-enum" claude unknown unknown cross_vendor gpt-stub-x ok
rowf "$RF/status-enum" claude unknown unknown cross-vendor gpt-stub-x okay
# The router only ever says ok on claude/codex for the cross-vendor lane; an in-family lane under ok is a lie.
rowf "$RF/ok-in-family" claude unknown unknown review-alt gpt-stub-x ok
: > "$RF/empty"
# Premises: the byte-level cases really carry the byte they are about.
if ! LC_ALL=C tr -d '\r' < "$RF/cr" | cmp -s - "$RF/cr"; then ok "O: premise — the CR case holds a CR byte"; else bad "O: premise — no CR in $RF/cr"; OSKIP=1; fi
if ! LC_ALL=C tr -d '\000' < "$RF/nul" | cmp -s - "$RF/nul"; then ok "O: premise — the NUL case holds a NUL byte"; else bad "O: premise — no NUL in $RF/nul"; OSKIP=1; fi
if [ "$(tail -c 1 "$RF/nofinalnl" | od -An -c | tr -d ' ')" != '\n' ] && [ "$(tail -c 1 "$RF/o0" | od -An -c | tr -d ' ')" = '\n' ]; then
  ok "O: premise — the no-final-newline case ends without one (the control with one)"
else bad "O: premise — the final-newline fixtures are wrong"; OSKIP=1; fi
expect_eq "O: premise — the blank-7th-line case has 7 lines" 7 "$(nlines "$RF/blank7")"
if [ "$(wc -c < "$RF/big" | tr -d ' ')" -gt 4096 ]; then ok "O: premise — the oversized answer is over 4 KB"; else bad "O: premise — the oversized answer is not over 4 KB"; OSKIP=1; fi
if [ "$(wc -c < "$RF/bigvalid" | tr -d ' ')" -gt 4096 ] && head -c 4096 "$RF/bigvalid" | head -n 6 | cmp -s - "$RF/o0"; then
  ok "O: premise — the big-but-valid answer is over 4 KB and starts with the valid six-key record"
else bad "O: premise — the big-but-valid fixture is wrong"; OSKIP=1; fi
expect_eq "O: premise — the edge answers are 4096 and 4097 bytes" "4096 4097" "$(wc -c < "$RF/edge4096" | tr -d ' ') $(wc -c < "$RF/edge4097" | tr -d ' ')"
[ "$(wc -c < "$RF/edge4096" | tr -d ' ')" = 4096 ] || OSKIP=1
if [ "$(wc -c < "$RF/huge" | tr -d ' ')" -gt 65536 ]; then ok "O: premise — the huge answer is over 64 KB"; else bad "O: premise — the huge answer is not over 64 KB"; OSKIP=1; fi
# ocase <label> <route-file> <route> [VAR=value ...] — exit 1, unavailable, nothing run, no --out, and the
# refusal came from where it should: route=<route> (malformed: the validator; routing-failed: the router's
# exit or the size cap; same-vendor: the guard; for the last two the lane the router named).
ocase() {
  local label="$1" f="$2" want="$3" d; shift 3
  if [ "$OSKIP" -ne 0 ]; then skip_block "O $label" "the O0 control or a byte premise failed — the stub harness is not proven"; return 0; fi
  d="$(od_new o)"
  seed codex 'Tier: A'; seed claude 'Tier: A'
  mr "O $label" HOME="$SH" STUB_ROUTE_FILE="$f" "$@" -- --route --mode audit "${READ[@]}" --prompt-file "$T/p.md" --out "$d/o.md"
  expect_rc "O $label" 1
  expect_eq "O $label: status=unavailable route=$want" "unavailable $want" "$(st status) $(st route)"
  no_client "O $label"; dir_empty "O $label" "$d"
}
ocase "same vendor as the Claude host and platform" "$RF/sv1" same-vendor CLAUDECODE=1
ocase "same vendor as the platform, no host signal" "$RF/sv2" same-vendor
ocase "same vendor as the host, platform lies" "$RF/sv3" same-vendor CLAUDECODE=1
ocase "same vendor as the Codex host" "$RF/sv4" same-vendor CODEX_SANDBOX=seatbelt
ocase "seven lines (a duplicate key)" "$RF/dup" malformed CLAUDECODE=1
ocase "five lines (a key missing)" "$RF/five" malformed CLAUDECODE=1
ocase "an unknown key in place of one" "$RF/extrakey" malformed CLAUDECODE=1
ocase "a key in another case (Platform=)" "$RF/keycase1" malformed CLAUDECODE=1
ocase "a key in another case (PLATFORM=)" "$RF/keycase2" malformed CLAUDECODE=1
ocase "a blank line inside" "$RF/blankinside" malformed CLAUDECODE=1
ocase "a blank 7th line after six good ones" "$RF/blank7" malformed CLAUDECODE=1
ocase "an empty value" "$RF/emptyval" malformed CLAUDECODE=1
ocase "a CR in a value" "$RF/cr" malformed CLAUDECODE=1
ocase "a non-ASCII byte" "$RF/nonascii" malformed CLAUDECODE=1
ocase "a NUL byte — rejected, never stripped" "$RF/nul" malformed CLAUDECODE=1
ocase "no final newline" "$RF/nofinalnl" malformed CLAUDECODE=1
ocase "reviewer_model outside the id charset" "$RF/charset" malformed CLAUDECODE=1
ocase "writer_model not a writer id (a;b) (P8)" "$RF/writer-shape" malformed CLAUDECODE=1
ocase "writer_lane outside its enum (P8)" "$RF/writer-lane" malformed CLAUDECODE=1
ocase "platform outside its enum (P8)" "$RF/platform-enum" malformed CLAUDECODE=1
ocase "reviewer_lane outside its enum (P8)" "$RF/lane-enum" malformed CLAUDECODE=1
ocase "routing_status outside its enum (P8)" "$RF/status-enum" malformed CLAUDECODE=1
ocase "ok on claude with an in-family lane, not cross-vendor" "$RF/ok-in-family" malformed CLAUDECODE=1
ocase "an empty answer" "$RF/empty" malformed CLAUDECODE=1
ocase "reviewer_model no CLI serves" "$RF/nocli" cross-vendor CLAUDECODE=1
ocase "ok on a platform that is not claude/codex" "$RF/cursor" review-alt
ocase "an answer over 4 KB" "$RF/big" routing-failed CLAUDECODE=1
ocase "over 4 KB although its first 4096 bytes are a valid record" "$RF/bigvalid" routing-failed CLAUDECODE=1
ocase "a router that exits 3 after a good row" "$RF/o0" routing-failed CLAUDECODE=1 STUB_ROUTE_EXIT=3
ocase "a 100 KB answer" "$RF/huge" routing-failed CLAUDECODE=1
[ "$OSKIP" -ne 0 ] || expect_has "O …a 100 KB answer is reported as oversized, not as a router that died of the reader's SIGPIPE (P1)" "over 4 KB" "$(cat "$T/e")"
ocase "a valid answer of 4097 bytes, one over the cap" "$RF/edge4097" routing-failed CLAUDECODE=1
if [ "$OSKIP" -eq 0 ]; then
  seed codex 'Tier: A'
  mr "O a valid answer of exactly 4096 bytes" HOME="$SH" CLAUDECODE=1 STUB_ROUTE_FILE="$RF/edge4096" -- --route --mode audit "${READ[@]}" --prompt-file "$T/p.md"
  expect_rc "O a valid answer of exactly 4096 bytes is within the cap" 0
  expect_eq "O exactly 4096 bytes: status=ok route=cross-vendor" "ok cross-vendor" "$(st status) $(st route)"
fi
RUN_MR="$MR"

# ── P. discovery: sibling-first, the next candidate really used, never the CWD ───────────────────
echo "-- P. the shared runner and the router are found sibling-first; missing ones fail closed; never from the CWD"
mkdir -p "$T/norouter/lib" "$T/nolib" "$T/badlib/lib" "$T/emptyhome" || die "cannot create the discovery layouts"
cp "$MR" "$T/norouter/model-run" && cp "$LIB" "$T/norouter/lib/model-subprocess.sh" || die "cannot build the no-router layout"
RUN_MR="$T/norouter/model-run"
mr "P1 no router" HOME="$T/emptyhome" CLAUDECODE=1 -- --route --prompt-file "$T/p.md"
expect_rc "P1 no router beside model-run or in ~/.zuvo" 1
expect_eq "P1: status=unavailable route=no-router" "unavailable no-router" "$(st status) $(st route)"
no_client "P1"
cp "$MR" "$T/nolib/model-run" || die "cannot build the no-runner layout"
RUN_MR="$T/nolib/model-run"
mr "P2 no runner" HOME="$T/emptyhome" -- --model "$P_CODEX" --prompt-file "$T/p.md"
expect_rc "P2 no model-subprocess.sh anywhere" 1
expect_eq "P2: status=unavailable route=no-runner" "unavailable no-runner" "$(st status) $(st route)"
no_client "P2"
# P2b: the FLAT install layout (~/.zuvo holds model-run, the runner and the router) with no
# model-registry.sh. --mode audit has no effort to read: an explicit --model is refused before any client
# runs (never run at the client's default effort), and --route fails on the router's own sentinel.
FL="$T/flathome"; mkdir -p "$FL/.zuvo" || die "cannot create the flat layout"
cp "$MR" "$FL/.zuvo/model-run" && cp "$LIB" "$FL/.zuvo/model-subprocess.sh" && cp "$ROUTER" "$FL/.zuvo/reviewer-model-route.sh" \
  || die "cannot build the flat layout"
if [ ! -e "$FL/.zuvo/model-registry.sh" ]; then ok "P2b: premise — the flat layout has no model-registry.sh"; else bad "P2b: premise — a registry is present"; fi
RUN_MR="$FL/.zuvo/model-run"
mr "P2b --model --mode audit, no registry" HOME="$FL" -- --model "$P_CODEX" --mode audit --prompt-file "$T/p.md"
expect_rc "P2b --mode audit with no registry: no audit effort" 1
expect_eq "P2b: status=unavailable route=explicit, no effort" "unavailable explicit " "$(st status) $(st route) $(st effort)"
expect_has "P2b: the note says why" "no audit effort for codex" "$(cat "$T/e")"
no_client "P2b"
RUN_MR="$FL/.zuvo/model-run"
mr "P2c --route --mode audit, no registry" HOME="$FL" CLAUDECODE=1 -- --route --mode audit --prompt-file "$T/p.md"
expect_rc "P2c --route with no registry: the router's fail-closed sentinel" 1
expect_eq "P2c: status=unavailable route=routing-failed" "unavailable routing-failed" "$(st status) $(st route)"
no_client "P2c"
# P3: <dir>/lib/model-subprocess.sh loads nothing; the NEXT candidate in model-run's lookup order is the
# flat <dir>/model-subprocess.sh — a good runner that leaves a marker when it is sourced.
cp "$MR" "$T/badlib/model-run" || die "cannot build the broken-candidate layout"
printf ': # defines none of the runner functions\n' > "$T/badlib/lib/model-subprocess.sh" || die "cannot write the broken candidate"
{ cat "$LIB" && printf '\n: > "%s"\n' "$T/p3-good-sourced"; } > "$T/badlib/model-subprocess.sh" || die "cannot write the good candidate"
RUN_MR="$T/badlib/model-run"
seed codex 'Tier: A'
mr "P3 a broken first candidate" HOME="$T/emptyhome" -- --model "$P_CODEX" --prompt-file "$T/p.md"
expect_rc "P3 the next candidate serves" 0
expect_has "P3: the broken candidate is named" "WARN: $T/badlib/lib/model-subprocess.sh exists but did not load" "$(cat "$T/e")"
if [ -e "$T/p3-good-sourced" ]; then ok "P3: the next candidate (the flat runner beside model-run) was the one sourced"; else bad "P3: the good runner was never sourced"; fi
spy_ran codex "P3"
# P-M1*: $T/pathbin holds the real layout (model-run, lib/ with a marker, the real router); HOME has the
# registry the router needs and NO runner. A hostile CWD's lib/, flat runner and router each leave a marker
# when used.
PB="$T/pathbin"; H1="$T/m1home"
mkdir -p "$PB/lib" "$H1/.zuvo" || die "cannot create the M1 layout"
cp "$MR" "$PB/model-run" && chmod +x "$PB/model-run" && cp "$ROUTER" "$PB/reviewer-model-route.sh" \
  && { cat "$LIB" && printf '\n: > "%s"\n' "$T/m1-real-sourced"; } > "$PB/lib/model-subprocess.sh" \
  && cp "$REG" "$H1/.zuvo/model-registry.sh" || die "cannot build the PATH layout"
hostile() { # hostile <dir> — a CWD whose two runner candidates and router each leave their OWN marker
  mkdir -p "$1/lib" && printf ': > "%s"\n' "$T/hostile-lib-sourced" > "$1/lib/model-subprocess.sh" \
    && printf ': > "%s"\n' "$T/hostile-flat-sourced" > "$1/model-subprocess.sh" \
    && printf '#!/bin/sh\n: > "%s"\nprintf "platform=claude\\nwriter_model=unknown\\nwriter_lane=unknown\\nreviewer_lane=cross-vendor\\nreviewer_model=gpt-hostile\\nrouting_status=ok\\n"\n' "$T/hostile-router-ran" > "$1/reviewer-model-route.sh" \
    || die "cannot build the hostile CWD $1"
}
m1_clean() { rm -f "$T/hostile-lib-sourced" "$T/hostile-flat-sourced" "$T/hostile-router-ran" "$T/m1-real-sourced"; }
m1_check() { # <label> — nothing from the CWD was sourced or run; a failure names which candidate it was
  if [ ! -e "$T/hostile-lib-sourced" ]; then ok "$1: the CWD's lib/model-subprocess.sh was not sourced"; else bad "$1: the CWD's lib/model-subprocess.sh WAS SOURCED"; fi
  if [ ! -e "$T/hostile-flat-sourced" ]; then ok "$1: the CWD's flat model-subprocess.sh was not sourced"; else bad "$1: the CWD's flat model-subprocess.sh WAS SOURCED"; fi
  if [ ! -e "$T/hostile-router-ran" ]; then ok "$1: no router from the CWD was run"; else bad "$1: the CWD's reviewer-model-route.sh WAS RUN"; fi
}
HX="$T/hostile"; hostile "$HX"
m1_clean; seed codex 'Tier: A'
RUN_MR=model-run; RUN_CWD="$HX"
mr "P-M1a bash model-run, found on PATH" HOME="$H1" CLAUDECODE=1 PATH="$PB:$T/shim:/usr/bin:/bin" -- --route --prompt-file "$T/p.md"
expect_rc "P-M1a" 0
m1_check "P-M1a"
if [ -e "$T/m1-real-sourced" ]; then ok "P-M1a: the runner beside the real model-run (bash recorded its PATH location) was used"; else bad "P-M1a: the real sibling runner was not used"; fi
expect_eq "P-M1a: the real router routed it" "ok codex $P_CODEX" "$(st status) $(st client) $(st model)"
m1_clean; seed codex 'Tier: A'
RUN_MR=model-run; RUN_EXEC=1; RUN_CWD="$HX"
mr "P-M1b model-run executed through PATH" HOME="$H1" CLAUDECODE=1 PATH="$PB:$T/shim:/usr/bin:/bin" -- --route --prompt-file "$T/p.md"
expect_rc "P-M1b" 0
m1_check "P-M1b"
if [ -e "$T/m1-real-sourced" ]; then ok "P-M1b: the real sibling runner was used"; else bad "P-M1b: the real sibling runner was not used"; fi
# P-M1c: NO model-run on PATH; the CWD holds a COPY of the REAL model-run beside a hostile runner and router,
# so `bash model-run` opens the copy (bash tries the CWD first). That is meaningful: a bare name is exactly
# the case where model-run cannot know its own directory, so it resolves NOTHING from the CWD and takes its
# runner and router from ~/.zuvo only (M1) — here there is none, so it fails closed. (An explicit
# `./model-run` is a path: it chooses its own siblings, the normal sibling-first lookup.)
HX2="$T/hostile-copy"; hostile "$HX2"; cp "$MR" "$HX2/model-run" || die "cannot plant the model-run copy"
if ! env -i PATH="$T/shim:/usr/bin:/bin" /bin/bash -c 'type -P model-run' >/dev/null 2>&1; then ok "P-M1c: premise — no model-run on the run PATH"
else bad "P-M1c: premise — a model-run is on the run PATH"; fi
m1_clean; RUN_MR=model-run; RUN_CWD="$HX2"
mr "P-M1c bash model-run opening a copy in the CWD" HOME="$H1" CLAUDECODE=1 PATH="$T/shim:/usr/bin:/bin" -- --route --prompt-file "$T/p.md"
expect_rc "P-M1c fails closed" 1
m1_check "P-M1c"
expect_eq "P-M1c: status=unavailable route=no-runner" "unavailable no-runner" "$(st status) $(st route)"
no_client "P-M1c"
# P-M1d: the same, the CWD's model-run a SYMLINK to the real one (whose own directory has a good runner).
HX3="$T/hostile-link"; hostile "$HX3"; ln -s "$PB/model-run" "$HX3/model-run" || die "cannot plant the model-run symlink"
m1_clean; RUN_MR=model-run; RUN_CWD="$HX3"
mr "P-M1d bash model-run opening a symlink in the CWD" HOME="$H1" CLAUDECODE=1 PATH="$T/shim:/usr/bin:/bin" -- --route --prompt-file "$T/p.md"
expect_rc "P-M1d fails closed" 1
m1_check "P-M1d"
expect_eq "P-M1d: status=unavailable route=no-runner" "unavailable no-runner" "$(st status) $(st route)"
RUN_MR="$MR"

# ── R. a stub RUNNER (the real library + overrides of zms_run_codex / zms_client_available) ───────
echo "-- R. a stub runner: early timeout, --out swapped, answer file gone or unreadable, a runner that ignores TERM, a lookup diagnostic"
SLD="$T/stublib"; mkdir -p "$SLD/lib" || die "cannot create the stub-runner layout"
cp "$MR" "$SLD/model-run" || die "cannot copy model-run into the stub-runner layout"
{ cat "$LIB" && cat <<'STUBRUN'

# ── test stubs: zms_run_codex behaves as STUB_RUNNER says; zms_client_available fails when STUB_UNAVAIL ──
zms_client_available() {
  if [ -n "${STUB_UNAVAIL:-}" ]; then echo "model-subprocess: $STUB_UNAVAIL" >&2; return 1; fi
  return 0
}
zms_run_codex() {
  local errf=""
  while [ $# -gt 0 ]; do case "$1" in --stderr-file) errf="$2"; shift 2 ;; *) shift ;; esac; done
  case "${STUB_RUNNER:-}" in
    timeout-before-start) return 124 ;;
    # The client started, and GNU timeout had to KILL it (137) once the whole budget was used.
    killed-at-budget) : > "$errf"; sleep 1; return 137 ;;
    answer) : > "$errf"; printf 'Tier: A\n' ;;
    swap-link) : > "$errf"; rm -f "$STUB_OUT"; ln -s "$STUB_DIR" "$STUB_OUT"; printf 'Tier: A\n' ;;
    swap-dir)  : > "$errf"; rm -f "$STUB_OUT"; mkdir "$STUB_OUT"; printf 'Tier: A\n' ;;
    swap-fifo) : > "$errf"; rm -f "$STUB_OUT"; mkfifo "$STUB_OUT"; printf 'Tier: A\n' ;;
    retarget)  : > "$errf"; ln -sfn "$STUB_NEWTARGET" "$STUB_LINK"; printf 'Tier: A\n' ;;
    no-answer) : > "$errf"; rm -f -- "${errf%/*}/answer"; return 0 ;;
    unreadable-answer) : > "$errf"; printf 'Tier: A\n'; chmod -- 000 "${errf%/*}/answer"; return 0 ;;
    # Ignores TERM and would run for 45 s; STUB_DONE appears only if it was WAITED OUT instead of killed.
    # It also records the grace it was handed (the runner reads ZUVO_TIMEOUT_GRACE itself).
    stuck)
      trap '' TERM INT HUP; : > "$errf"; printf '%s\n' "${ZUVO_TIMEOUT_GRACE:-unset}" > "$STUB_DONE.grace"
      sleep 45 & echo "$!" > "$STUB_PIDFILE"; wait "$!"; : > "$STUB_DONE" ;;
    # The runner's worst-case EXIT trap: _zms_reap waits the grace, KILLs, waits up to 5 s more, THEN the
    # temp dir (with the auth.json copy) is removed. STUB_CLEANUP seconds of that, then the marker goes.
    slow-cleanup)
      : > "$errf"; : > "$STUB_MARK"; sleep 30 & s=$!
      trap 'kill "$s" 2>/dev/null; sleep "$STUB_CLEANUP"; rm -f "$STUB_MARK"; exit 143' TERM
      echo "$s" > "$STUB_PIDFILE"; wait "$s" ;;
    *) return 99 ;;
  esac
}
STUBRUN
} > "$SLD/lib/model-subprocess.sh" || die "cannot write the stub runner"
RUN_MR="$SLD/model-run"
mr "R1" STUB_RUNNER=timeout-before-start -- --model gpt-stub-x --prompt-file "$T/p.md"
expect_rc "R1 a runner timed out before the client wrote its stderr" 124
expect_eq "R1: status=timeout, not unavailable" "timeout" "$(st status)"
# R1b: a 137 whose elapsed time REACHES the budget (1 s of a 1 s budget) is a timeout, not a client error —
# the boundary is inclusive. Three runs: a clock tick can only make one of them longer, never shorter.
for _r1b in 1 2 3; do
  mr "R1b.$_r1b" STUB_RUNNER=killed-at-budget -- --model gpt-stub-x --prompt-file "$T/p.md" --timeout 1
  expect_rc "R1b.$_r1b a 137 after the whole 1 s budget is a timeout" 124
  expect_eq "R1b.$_r1b: status=timeout, not error" "timeout" "$(st status)"
done
_d="$(od_new r2)"; _ad="$(od_new attacker)"; printf 'OLD\n' > "$_d/r2.md"
mr "R2" STUB_RUNNER=swap-link STUB_OUT="$_d/r2.md" STUB_DIR="$_ad" -- --model gpt-stub-x --prompt-file "$T/p.md" --out "$_d/r2.md"
expect_rc "R2 --out became a link to a directory during the run" 4
expect_eq "R2: status=error" "error" "$(st status)"
dir_empty "R2: the linked directory" "$_ad"
if [ -L "$_d/r2.md" ]; then ok "R2: the link was not replaced"; else bad "R2: the link was replaced"; fi
only_file "R2" "$_d" r2.md
_d="$(od_new r3)"
mr "R3" STUB_RUNNER=swap-dir STUB_OUT="$_d/r3.md" -- --model gpt-stub-x --prompt-file "$T/p.md" --out "$_d/r3.md"
expect_rc "R3 --out became a directory during the run" 4
dir_empty "R3: the new directory" "$_d/r3.md"
only_file "R3" "$_d" r3.md
_d="$(od_new r3b)"; printf 'OLD\n' > "$_d/r3b.md"
mr "R3b" STUB_RUNNER=swap-fifo STUB_OUT="$_d/r3b.md" -- --model gpt-stub-x --prompt-file "$T/p.md" --out "$_d/r3b.md"
expect_rc "R3b --out became a FIFO during the run (P3)" 4
if [ -p "$_d/r3b.md" ]; then ok "R3b: the FIFO was not replaced"; else bad "R3b: the FIFO was replaced"; fi
only_file "R3b" "$_d" r3b.md
# R3c: --out's directory is reached through a link that is retargeted during the run. The directory was
# pinned (physically) when the arguments were checked: the answer lands where the link pointed THEN.
_pa="$(od_new pin-a)"; _pb="$(od_new pin-b)"; _pd="$(od_new pin)"; ln -s "$_pa" "$_pd/link" || die "cannot link the pinned dir"
mr "R3c" STUB_RUNNER=retarget STUB_LINK="$_pd/link" STUB_NEWTARGET="$_pb" -- --model gpt-stub-x --prompt-file "$T/p.md" --out "$_pd/link/x.md"
expect_rc "R3c the --out directory's link moved during the run (P5)" 0
printf 'Tier: A\n' > "$T/want"; expect_bytes "R3c: the answer landed in the directory pinned at the start" "$_pa/x.md" "$T/want"
dir_empty "R3c: the directory the link points to now" "$_pb"
# R3d: the rename REPORTS success but --out does not hold the answer (an mv that claims to have renamed onto
# --out and did nothing — the stand-in for anything that rewrites --out between the rename and the check).
# The content is verified after the rename, not only the file type: exit 4, never ok over the old bytes.
mkdir -p "$T/liarshim" || die "cannot create the lying-mv shim"
printf '#!/bin/sh\ncase "$1" in --version) exec /bin/mv "$@" ;; esac\ncase "$*" in *"$LIAR_OUT"*) exit 0 ;; esac\nexec /bin/mv "$@"\n' > "$T/liarshim/mv" \
  && chmod +x "$T/liarshim/mv" || die "cannot write the lying mv"
_d="$(od_new r3d)"; printf 'OLD\n' > "$_d/r3d.md"
mr "R3d" STUB_RUNNER=answer PATH="$T/liarshim:$T/shim:/usr/bin:/bin" LIAR_OUT="$_d/r3d.md" -- --model gpt-stub-x --prompt-file "$T/p.md" --out "$_d/r3d.md"
expect_rc "R3d an --out that does not hold the answer after a 'successful' rename" 4
expect_eq "R3d: status=error" "error" "$(st status)"
printf 'OLD\n' > "$T/want"; expect_bytes "R3d: --out still holds the old bytes" "$_d/r3d.md" "$T/want"
mr "R4" STUB_RUNNER=no-answer -- --model gpt-stub-x --prompt-file "$T/p.md"
expect_rc "R4 the answer file is gone when the runner returns (R3)" 4
expect_eq "R4: status=error, not empty" "error" "$(st status)"
# R5 rests on `chmod 000` making a file unreadable — which root can still read. Under euid 0 it is skipped
# with the reason printed; under any other euid it must hold.
if [ "$(id -u)" = 0 ]; then
  echo "  SKIP R5 — running as root (euid 0): a mode-000 file is still readable, the case cannot hold"
else
  mr "R5" STUB_RUNNER=unreadable-answer -- --model gpt-stub-x --prompt-file "$T/p.md"
  expect_rc "R5 the answer file is unreadable (R3)" 4
  expect_eq "R5: status=error, not empty" "error" "$(st status)"
fi
mr "R9" STUB_UNAVAIL="stub lookup diagnostic: codex not found" -- --model gpt-stub-x --prompt-file "$T/p.md"
expect_rc "R9 the client is unavailable" 1
expect_has "R9: the lookup's own diagnostic reaches stderr (before the status line)" "stub lookup diagnostic: codex not found" "$(sed '$d' "$T/e")"
# R6: a runner that ignores TERM (the whole job: it and its sleep). TERM to model-run must still end it
# after a bounded wait — the process group gets TERM, then KILL — and leave nothing behind. R6b: the same
# with ZUVO_TIMEOUT_GRACE=60 — stop()'s wait is clamped to 15 + 7 s, not 60 + 7 s. Proven by what happened
# to the runner, not by a stopwatch: the stub would run 45 s and then leave its done-marker. model-run
# exiting with the marker absent means its group was KILLed before that — a wait of grace + 7 s (8 s, or
# the clamped 22 s), never one that outlasted the runner (an unclamped 67 s would). The grace the runner
# was handed is recorded by the stub and compared, so the clamp's value is pinned as well.
stuck_case() { # stuck_case <label> <grace> <the grace the runner must be handed>
  local label="$1" g="$2" want="$3" rp sp rc=0 i=0
  rm -f "$T/stuck.pid" "$T/stuck.done" "$T/stuck.done.grace"
  ( cd "$R" && exec env -i HOME="$H" TMPDIR="$TMPD" PATH="$T/shim:/usr/bin:/bin" ZUVO_CODEX_BIN="$SPYB/codex" \
      ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_TIMEOUT_GRACE="$g" STUB_RUNNER=stuck STUB_PIDFILE="$T/stuck.pid" \
      STUB_DONE="$T/stuck.done" "$RBASH" "$SLD/model-run" --model gpt-stub-x --prompt-file "$T/p.md" ) < /dev/null > "$T/o" 2> "$T/e" &
  rp=$!; echo "$rp" >> "$BGPIDS"
  while [ ! -s "$T/stuck.pid" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i+1)); done
  sp="$(cat "$T/stuck.pid" 2>/dev/null)"
  if [ -z "$sp" ]; then bad "$label: premise — the stuck runner never started"; kill -KILL "$rp" 2>/dev/null; wait "$rp" 2>/dev/null; return 0; fi
  ok "$label: premise — the stuck runner is running (its sleep: pid $sp)"
  expect_eq "$label: the runner was handed the grace model-run itself waits by" "$want" "$(cat "$T/stuck.done.grace" 2>/dev/null)"
  kill -TERM "$rp" 2>/dev/null; wait "$rp" || rc=$?
  expect_eq "$label: model-run exits 143" 143 "$rc"
  if [ ! -e "$T/stuck.done" ]; then ok "$label: the runner was KILLed after the bounded wait — its 45 s were never waited out"
  else bad "$label: the runner ran to its end — the teardown waited on it instead of killing its group"; fi
  expect_gone "$label: the runner's sleep" "$sp" 5
  expect_eq "$label: the final line is status=error" "error" "$(st status)"
  expect_eq "$label: exactly one status line" 1 "$(nstatus)"
  tmp_empty "$label"
}
stuck_case "R6 (grace 1)" 1 1
stuck_case "R6b (grace 60, clamped to 15)" 60 15
# R6c: a runner whose cleanup takes the longest the real one can — its grace, then up to 5 s after the KILL
# (_zms_reap), then the temp dir goes. model-run must wait that out before it KILLs the runner's group, or
# the auth.json copy stays on disk. Grace 1, cleanup 1 + 5 s: the marker the stub removes LAST is the proof.
slow_cleanup_case() {
  local rp rc=0 i=0 mark="$T/r6c.mark"
  rm -f "$T/stuck.pid" "$mark"
  ( cd "$R" && exec env -i HOME="$H" TMPDIR="$TMPD" PATH="$T/shim:/usr/bin:/bin" ZUVO_CODEX_BIN="$SPYB/codex" \
      ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_TIMEOUT_GRACE=1 STUB_RUNNER=slow-cleanup STUB_CLEANUP=6 STUB_MARK="$mark" \
      STUB_PIDFILE="$T/stuck.pid" "$RBASH" "$SLD/model-run" --model gpt-stub-x --prompt-file "$T/p.md" ) < /dev/null > "$T/o" 2> "$T/e" &
  rp=$!; echo "$rp" >> "$BGPIDS"
  while [ ! -s "$T/stuck.pid" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i+1)); done
  if [ ! -s "$T/stuck.pid" ] || [ ! -e "$mark" ]; then
    bad "R6c: premise — the slow-cleanup runner never started"; kill -KILL "$rp" 2>/dev/null; wait "$rp" 2>/dev/null; return 0
  fi
  ok "R6c: premise — the slow-cleanup runner is running, its marker present"
  kill -TERM "$rp" 2>/dev/null; wait "$rp" || rc=$?
  expect_eq "R6c: model-run exits 143" 143 "$rc"
  if [ ! -e "$mark" ]; then ok "R6c: the runner's cleanup (grace + 5 s after KILL) finished before model-run's KILL"
  else bad "R6c: model-run KILLed the runner mid-cleanup — its marker (the temp dir with the auth copy) is still there"; fi
  expect_eq "R6c: the final line is status=error" "error" "$(st status)"
  tmp_empty "R6c"
}
slow_cleanup_case
RUN_MR="$MR"

# ── S. a failed stdout write ─────────────────────────────────────────────────
echo "-- S. the answer cannot be written to stdout"
seed codex 'Tier: A'
MR_STDOUT=closed
mr "S" CLAUDECODE=1 -- --route "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "S stdout closed" 4
expect_eq "S: status=error, not ok" "error" "$(st status)"

# ── T. no GNU timeout ────────────────────────────────────────────────────────
# The PATH holds every other tool model-run and the runner use, so the case can only fail for the one
# reason it is about. $S/model-run is the O-block copy of the model-run under test, beside the marker router.
echo "-- T. no GNU timeout on PATH: exit 1 before the router or any client runs"
NOTO="$T/notimeout-bin"; mkdir -p "$NOTO" || die "cannot create $NOTO"
hermetic_link_tools "$NOTO" awk basename cat chmod cmp cp cut date dirname env find grep head ln ls mkdir mktemp mv od ps \
  readlink rm sed sh sleep sort stat tail touch tr uniq wc || die "cannot link the tools for the no-timeout PATH"
if [ ! -e "$NOTO/timeout" ] && [ ! -e "$NOTO/gtimeout" ] && [ -x "$NOTO/mktemp" ] && [ -x "$NOTO/awk" ]; then
  ok "T: premise — the PATH has every tool but timeout / gtimeout"
  RUN_MR="$S/model-run"; rm -f "$T/t-router-ran"
  mr "T" HOME="$SH" CLAUDECODE=1 PATH="$NOTO" STUB_ROUTE_FILE="$RF/o0" STUB_ROUTE_MARK="$T/t-router-ran" -- --route --prompt-file "$T/p.md"
  RUN_MR="$MR"
  expect_rc "T no GNU timeout" 1
  expect_eq "T: the status line" "model-run: status=unavailable client= model= effort= route=no-timeout" "$(tail -n 1 "$T/e")"
  expect_eq "T: the one diagnostic before it" \
    "model-run: note: GNU timeout required (timeout or gtimeout on PATH; macOS: brew install coreutils) — nothing is run without a bound" "$(sed -n 1p "$T/e")"
  if [ ! -e "$T/t-router-ran" ]; then ok "T: the router was never run (nothing runs unbounded)"; else bad "T: the router RAN without a bound"; fi
  no_client "T"
else
  skip_block "T (no GNU timeout)" "the no-timeout PATH still holds one, or lacks a tool"
fi

# ── U. the codex CLI version guard ───────────────────────────────────────────
# The stand-in answers --version with $OLD_VERSION, hands `exec …` to the spy, and fails LOUDLY on any
# other argument shape — it never runs anything else.
echo "-- U. a codex CLI that cannot run the routed model: route=cli-too-old, never a silent downgrade; a new enough one runs"
mkdir -p "$T/oldcodex" || die "cannot create $T/oldcodex"
printf '#!/bin/sh\ncase "${1:-}" in\n  --version) echo "$OLD_VERSION"; exit 0 ;;\n  exec) exec "%s" "$@" ;;\n  *) echo "codex stand-in: unexpected argv: $*" >&2; exit 64 ;;\nesac\n' "$SPYB/codex" > "$T/oldcodex/codex" \
  && chmod +x "$T/oldcodex/codex" || die "cannot write the codex version stand-in"
for _v in "codex-cli 0.150.0" "no version here"; do
  seed codex 'Tier: A'
  mr "U [$_v]" CLAUDECODE=1 ZUVO_CODEX_BIN="$T/oldcodex/codex" OLD_VERSION="$_v" -- --route --mode audit "${READ[@]}" --prompt-file "$T/p.md"
  expect_rc "U [$_v]" 1
  expect_eq "U [$_v]: status=unavailable route=cli-too-old model=$P_CODEX" "unavailable cli-too-old $P_CODEX" "$(st status) $(st route) $(st model)"
  no_client "U [$_v]"
done
seed codex 'Tier: A'
mr "U [codex-cli 0.156.1]" CLAUDECODE=1 ZUVO_CODEX_BIN="$T/oldcodex/codex" OLD_VERSION="codex-cli 0.156.1" -- --route --mode audit "${READ[@]}" --prompt-file "$T/p.md"
expect_rc "U a codex CLI new enough for $P_CODEX runs normally" 0
expect_eq "U [0.156.1]: status=ok, the routed model unchanged" "ok cross-vendor $P_CODEX" "$(st status) $(st route) $(st model)"
spy_ran codex "U [0.156.1]"

# ── V. mode preservation fails closed ────────────────────────────────────────
# stat / chmod stand-ins that refuse only paths inside $FAIL_UNDER (the out dir) — the runner's own
# chmod of its temp CODEX_HOME still works.
echo "-- V. the destination's mode cannot be read or applied: exit 4, --out untouched"
for _t in stat chmod; do
  mkdir -p "$T/fail-$_t" || die "cannot create $T/fail-$_t"
  case "$_t" in stat) _real="$REAL_STAT" ;; *) _real="$REAL_CHMOD" ;; esac
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in "$FAIL_UNDER"/*) echo "%s stand-in: refusing $a" >&2; exit 1 ;; esac; done\nexec "%s" "$@"\n' "$_t" "$_real" > "$T/fail-$_t/$_t" \
    && chmod +x "$T/fail-$_t/$_t" || die "cannot write the $_t stand-in"
  _d="$(od_new "v-$_t")"; printf 'OLD ANSWER\n' > "$_d/v.md"; chmod 640 "$_d/v.md"
  seed codex 'Tier: A (new)'
  mr "V ($_t fails)" CLAUDECODE=1 PATH="$T/fail-$_t:$T/shim:/usr/bin:/bin" FAIL_UNDER="$_d" -- --route --prompt-file "$T/p.md" --out "$_d/v.md"
  expect_rc "V a $_t that fails on the destination (R4)" 4
  expect_eq "V ($_t): status=error" "error" "$(st status)"
  printf 'OLD ANSWER\n' > "$T/want"; expect_bytes "V ($_t): --out untouched" "$_d/v.md" "$T/want"
  expect_eq "V ($_t): its mode untouched" 640 "$(fmode "$_d/v.md")"
  only_file "V ($_t)" "$_d" v.md
done
# V2: TERM arrives while the publish is under way — between the temp file's creation and the rename. A
# stat stand-in, called while --out's mode is read, sends TERM to model-run itself: stat runs inside a
# command substitution, so it walks up its ancestors — stopping at THIS test shell ($SIG_STOP_AT), never
# above it — and signals the OUTERMOST one running $SIG_TARGET (the model-run under test; a forked subshell
# carries the same command line). Signals are ignored from before the temp file exists, so the run
# completes: ok, --out published, no .model-run.* temp left (P6).
mkdir -p "$T/sigstat" || die "cannot create $T/sigstat"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in "$SIG_UNDER"/*)\n  p=$PPID; top=""\n  while [ "${p:-1}" -gt 1 ] && [ "$p" != "$SIG_STOP_AT" ]; do case "$(ps -ww -o command= -p "$p" 2>/dev/null)" in *"$SIG_TARGET"*) top=$p ;; esac; p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d " "); done\n  [ -z "$top" ] || kill -TERM "$top"; sleep 0.3; break ;; esac; done\nexec "%s" "$@"\n' "$REAL_STAT" > "$T/sigstat/stat" \
  && chmod +x "$T/sigstat/stat" || die "cannot write the signalling stat stand-in"
_d="$(od_new v2)"; printf 'OLD ANSWER\n' > "$_d/v2.md"
seed codex 'Tier: A (published)'
mr "V2 TERM between the temp file and the rename" CLAUDECODE=1 PATH="$T/sigstat:$T/shim:/usr/bin:/bin" SIG_UNDER="$_d" SIG_TARGET="$MR" SIG_STOP_AT="$$" -- \
  --route --prompt-file "$T/p.md" --out "$_d/v2.md"
expect_rc "V2 a signal inside the publish window (P6)" 0
expect_eq "V2: status=ok" "ok" "$(st status)"
printf 'Tier: A (published)\n' > "$T/want"; expect_bytes "V2: --out is published" "$_d/v2.md" "$T/want"
only_file "V2: no temp file left behind" "$_d" v2.md

# ── W. a signal while --out is being published ───────────────────────────────
# An mv stand-in acts only when its DESTINATION operand (the last argument) is inside $W_OUT_DIR — the spy
# moves its own record with mv too, and `mv --version` must pass through. MV_MODE=term: it sends TERM to
# model-run (its parent), then does the real rename — the answer is published, so the run is ok; a late
# signal cannot turn it into status=error. MV_MODE=swapdir: it puts a DIRECTORY where --out goes right
# before the real rename — BSD mv then moves the temp INTO it and exits 0; the publish must be verified,
# reported as an error, and the stray temp removed (P4).
echo "-- W. publishing --out: a late signal does not undo ok; a directory swapped in is caught"
mkdir -p "$T/mvbin" || die "cannot create $T/mvbin"
printf '#!/bin/sh\nfor a in "$@"; do last="$a"; done\ncase "${last:-}" in\n  "$W_OUT_DIR"/*)\n    case "${MV_MODE:-}" in\n      term) kill -TERM "$PPID"; sleep 0.3 ;;\n      swapdir) rm -f "$last"; mkdir "$last" ;;\n    esac ;;\nesac\nexec "%s" "$@"\n' "$REAL_MV" > "$T/mvbin/mv" \
  && chmod +x "$T/mvbin/mv" || die "cannot write the mv stand-in"
_d="$(od_new w)"; seed codex 'Tier: A (published)'
mr "W" CLAUDECODE=1 PATH="$T/mvbin:$T/shim:/usr/bin:/bin" W_OUT_DIR="$_d" MV_MODE=term -- --route --prompt-file "$T/p.md" --out "$_d/w.md"
expect_rc "W TERM during the rename (R7)" 0
expect_eq "W: status=ok" "ok" "$(st status)"
printf 'Tier: A (published)\n' > "$T/want"; expect_bytes "W: --out is published" "$_d/w.md" "$T/want"
only_file "W" "$_d" w.md
_d="$(od_new w2)"; seed codex 'Tier: A (published)'
mr "W2" CLAUDECODE=1 PATH="$T/mvbin:$T/shim:/usr/bin:/bin" W_OUT_DIR="$_d" MV_MODE=swapdir -- --route --prompt-file "$T/p.md" --out "$_d/w2.md"
expect_rc "W2 a directory swapped in at the rename (P4)" 4
expect_eq "W2: status=error, never ok for an unwritten --out" "error" "$(st status)"
dir_empty "W2: the directory swapped in (the stray temp removed)" "$_d/w2.md"
only_file "W2" "$_d" w2.md

# ── Q. signals while the client runs ─────────────────────────────────────────
# model-run starts in the background with a client that sleeps 30 s; once the client's record exists the
# signal goes to model-run ALONE. model-run must exit 128+n with ONE final `status=error` line; TMPDIR is
# empty and no --out exists the moment it exits; the client is gone (a bounded, zombie-tolerant poll —
# a leftover is killed). INT and HUP go through perl, which resets the signal to its default before exec:
# a background job of a non-interactive shell starts with INT ignored, and a suite started under nohup
# (run-all detached on the farm) hands HUP down ignored — bash can neither trap nor receive a signal that
# was ignored when it started, so without the reset the case measures the launcher, not model-run.
echo "-- Q. TERM / INT / HUP while the client runs (and TERM with a client that ignores it)"
# Q0 (source lint — the window is a few instructions wide, no stub can hold a signal inside it): a signal
# between the runner's launch (`&`) and `rp=$!` would reach stop() with no runner pid, so the runner's
# group — the client with it — would outlive model-run. In run_client the handlers must RECORD a signal
# from before the launch until rp is set, then the real handlers come back and a recorded signal is acted
# on: pending traps (TERM, INT and HUP, each keeping the FIRST signal recorded) < launch < rp=$! <
# arm_signals < the pending check.
_q0="$(awk '/^run_client\(\) *\{/ { f = 1 } f && /^}/ { exit }
  f && /trap .\[ -n "\$pend" \] \|\| pend=143. TERM/ && !t { t = NR }
  f && /trap .\[ -n "\$pend" \] \|\| pend=130. INT/ && !n { n = NR }
  f && /trap .\[ -n "\$pend" \] \|\| pend=129. HUP/ && !h { h = NR }
  f && /"zms_run_\$client" .*&[[:space:]]*$/ && !b { b = NR }
  f && /^[[:space:]]*rp=\$!/ && !c { c = NR }
  f && /^[[:space:]]*arm_signals[[:space:]]*$/ && !d { d = NR }
  f && /\[ -z "\$pend" \] \|\| stop "\$pend"/ && !e { e = NR }
  END { a = t; if (n > a) a = n; if (h > a) a = h
        print (t && n && h && b && c && d && e && a < b && b < c && c < d && d < e) ? "ordered" : "TERM=" t " INT=" n " HUP=" h " b=" b " c=" c " d=" d " e=" e }' "$MR")"
expect_eq "Q0: TERM, INT or HUP between the runner's launch and rp=\$! is recorded (the first one kept) and acted on once rp is set" ordered "$_q0"
PERL="$(command -v perl 2>/dev/null || true)"
# Q0b: the recording handlers themselves, run: run_client's own trap line, then TERM, INT and HUP in that
# order — the first (TERM, 143) is what stop() is later called with. Started through perl with INT and HUP
# at their default, for the same reason as the Q cases below.
_q0line="$(awk '/^run_client\(\) *\{/ { f = 1 } f && /^}/ { exit } f && /trap .*pend=143.* TERM/ { print; exit }' "$MR")"
if [ -z "$_q0line" ]; then bad "Q0b: run_client has no recording TERM trap line"
elif [ -z "$PERL" ]; then skip_block "Q0b" "no perl to start the probe with SIGINT and SIGHUP at their default"
else
  # shellcheck disable=SC2016  # expanded by the probe shell
  _q0got="$("$PERL" -e '$SIG{INT} = $SIG{HUP} = "DEFAULT"; exec { $ARGV[0] } @ARGV; exit 127' "$RBASH" -c \
    'pend=""; eval "$1"; kill -TERM $$; kill -INT $$; kill -HUP $$; printf "%s" "$pend"' _ "$_q0line")"
  expect_eq "Q0b: TERM, then INT, then HUP before rp is set — the first signal (TERM, 143) is the one kept" 143 "$_q0got"
fi
unset _q0line _q0got
sigcase() { # sigcase <SIG> <want-exit> [VAR=value ...]
  local sig="$1" want="$2" d pid rc=0 sp i=0 pre=() extra=()
  shift 2; extra=("$@")
  rm -f -- "${SPY:?}"/* "${SPY:?}"/.[!.]*; printf 'Tier: A\n' > "$SPY/codex.reply"
  d="$(od_new "q-$sig")"
  case "$sig" in INT|HUP) pre=("$PERL" -e 'my $s = shift; $SIG{$s} = "DEFAULT"; exec { $ARGV[0] } @ARGV; exit 127' "$sig") ;; esac
  ( cd "$R" && exec ${pre[@]+"${pre[@]}"} env -i HOME="$H" TMPDIR="$TMPD" CODEX_HOME="$CH" PATH="$T/shim:/usr/bin:/bin" SPY_DIR="$SPY" SPY_SLEEP=30 \
      ZUVO_CODEX_BIN="$SPYB/codex" ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_TIMEOUT_GRACE=1 CLAUDECODE=1 ${extra[@]+"${extra[@]}"} \
      "$RBASH" "$MR" --route --access read --read-root "$R" --prompt-file "$T/p.md" --out "$d/q.md" ) < /dev/null > "$T/o" 2> "$T/e" &
  pid=$!; echo "$pid" >> "$BGPIDS"
  while [ ! -s "$SPY/codex.rec" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i+1)); done
  sp="$(rec codex pid)"; note_pids
  if [ -z "$sp" ]; then
    bad "Q $sig ${extra[*]:-}: premise — the client never started within 20 s (the case is not run)"
    kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 0
  fi
  ok "Q $sig ${extra[*]:-}: premise — the client is running (pid $sp)"
  kill -"$sig" "$pid" 2>/dev/null
  wait "$pid" || rc=$?
  expect_eq "Q $sig ${extra[*]:-}: model-run exits $want (128+n)" "$want" "$rc"
  tmp_empty "Q $sig ${extra[*]:-}: when model-run exits (the auth copy included)"
  dir_empty "Q $sig ${extra[*]:-}" "$d"
  expect_eq "Q $sig ${extra[*]:-}: exactly one status line" 1 "$(nstatus)"
  expect_eq "Q $sig ${extra[*]:-}: the final line is status=error (codex, $P_CODEX)" "error codex $P_CODEX" "$(st status) $(st client) $(st model)"
  expect_gone "Q $sig ${extra[*]:-}" "$sp" 5
  repo_clean "Q $sig ${extra[*]:-}"
}
sigcase TERM 143
if [ -n "$PERL" ]; then
  sigcase HUP 129
  sigcase INT 130
else
  skip_block "Q HUP" "no perl to start model-run with SIGHUP at its default"
  skip_block "Q INT" "no perl to start model-run with SIGINT at its default"
fi
sigcase TERM 143 SPY_IGNORE_TERM=1
# A large grace: model-run waits at most its clamped grace (15 s) + RUNNER_CLEANUP_SLACK (7 s) = 22 s before
# it KILLs the runner's group,
# so the runner must be handed that SAME clamped grace — with the raw 60 s its reap outlasts that wait, the
# KILL lands before its EXIT trap removes the temp dir holding the auth.json copy, and the client (in GNU
# timeout's own group, which the KILL does not reach) is left running.
sigcase TERM 143 SPY_IGNORE_TERM=1 ZUVO_TIMEOUT_GRACE=60

echo ""
assert_result
