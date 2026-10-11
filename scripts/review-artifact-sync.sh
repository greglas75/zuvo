#!/usr/bin/env bash
#
# review-artifact-sync.sh — move review artifacts BETWEEN checkouts as PAIRS,
# and lint artifact headers against the gate parser's actual expectations.
#
# Why this exists (2026-07-31 incident, six data-lab refactor PRs): review
# coverage is two files — the memory/reviews/*.md artifact AND the proof file
# its `adversarial:` header references (zuvo/proofs/..., gitignored). Both are
# per-checkout. A worktree pipeline writes them in the worktree; a push from
# the main checkout then sees nothing, and copying only the .md still fails
# proof-of-work. Diagnosed as "review never happened" twice. It had happened.
#
# Usage:
#   review-artifact-sync.sh --archive [<checkout>] [--slug <substr>]
#       Copy every artifact AND every proof it cites to ~/.zuvo/review-archive/<repo>/
#       (proofs/<artifact-stem>/<repo-relative proof path>) — outside every checkout,
#       so the pair survives `git worktree remove`. Run it right after a review.
#
#   review-artifact-sync.sh --restore [<checkout>] [--slug <substr>]
#       Put archived proofs back wherever an artifact cites a proof that is missing
#       in this checkout (archives written before path keys: the first proof only).
#
#   review-artifact-sync.sh --check [<checkout>] [--slug <substr>]
#       Lint memory/reviews/*.md in the checkout (default: cwd's repo) — all
#       artifacts, or only those whose filename contains <substr> (a slug matching
#       nothing FAILs). Checks the marker, range: and a comma-separated files:,
#       then applies the push gate's own proof verdict to every cited proof
#       (adversarial:/adv-proof: lines, comma lists): FAIL whenever the gate would
#       refuse the artifact — no proof line, a missing, truncated, blind-audit or
#       weak proof, prose, or a path out of the repo. Exit 0 = no FAILs,
#       1 = at least one FAIL, 2 = usage error or the gate library is missing.
#
#   review-artifact-sync.sh --from <src-checkout> --to <dst-checkout> [--slug <substr>]
#       Copy artifact+proof PAIRS from src to dst (marker-bearing artifacts, or only
#       those whose filename contains <substr>), every cited proof included.
#       Preserves mtimes, never overwrites DIFFERENT content, then runs --check on
#       each copied artifact at dst (exit 1 if the gate there would refuse one).

# The usage text is the comment header: line 3 up to the first line that is not a comment.
usage() { awk 'NR < 3 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"; }

# --help needs no paths, so it answers before the library guard below.
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# The gate's own library, never from an env override; lib/ is the Codex/Cursor install layout.
_ras_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
unset PG_LIB_LOADED
# This CLI answers for the LOCAL gate: the CI waiver for absent proofs belongs to the CI entry script,
# and an inherited cutoff would grandfather every artifact into OK.
unset PG_PROOF_OPTIONAL PG_REVIEW_PROOF_CUTOFF
for _ras_c in "$_ras_dir/pipeline-gate-lib.sh" "$_ras_dir/lib/pipeline-gate-lib.sh" \
              "$_ras_dir/../hooks/lib/pipeline-gate-lib.sh" "$HOME/.claude/hooks/lib/pipeline-gate-lib.sh"; do
  if [ -r "$_ras_c" ]; then
    # shellcheck source=/dev/null
    . "$_ras_c"; break
  fi
done
if [ "${PG_LIB_LOADED:-}" != 1 ] || ! command -v path_contained >/dev/null 2>&1 \
   || ! command -v pg_artifact_proof_verdict >/dev/null 2>&1 \
   || ! command -v pg_artifact_proof_refs >/dev/null 2>&1 \
   || ! command -v pg_proof_ref_is_prose >/dev/null 2>&1 || ! command -v _pgl_clean >/dev/null 2>&1; then
  echo "review-artifact-sync: cannot compute the gate's verdict — pipeline-gate-lib.sh (with path-contain.sh) not found beside this script or in ~/.claude/hooks/lib; reinstall zuvo" >&2
  exit 2
fi

set -uo pipefail

MODE=""
SRC=""
DST=""
SLUG=""

# `shift 2` with one arg left FAILS and leaves $# unchanged — and this script runs
# without `set -e`, so the failure is swallowed and the same case arm re-matches
# forever. `--from` with no value used to hang with zero output, in the very script
# the push gate prints as its remediation command. Require the value explicitly.
need_value() {
  [ "$2" -ge 2 ] || { echo "Missing value for $1" >&2; usage >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check"; shift; [ $# -gt 0 ] && [ "${1#--}" = "$1" ] && { SRC="$1"; shift; } ;;
    --from)  need_value "$1" "$#"; MODE="${MODE:-sync}"; SRC="$2"; shift 2 ;;
    --to)    need_value "$1" "$#"; DST="$2"; shift 2 ;;
    --slug)  need_value "$1" "$#"; SLUG="$2"; shift 2 ;;
    --archive) MODE="archive"; shift; [ $# -gt 0 ] && [ "${1#--}" = "$1" ] && { SRC="$1"; shift; } ;;
    --restore) MODE="restore"; shift; [ $# -gt 0 ] && [ "${1#--}" = "$1" ] && { DST="$1"; shift; } ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# --check inspects the current checkout; --from/--to are the sync-mode pair. Silently
# ignoring --to under --check made a wrong command look like a passing check. --slug IS
# valid with --check (field retro 2026-08-02: post-run validation wants to lint ONLY the
# artifact this run just wrote, not re-print every historical artifact in the checkout).
if [ "$MODE" = "check" ] && [ -n "$DST" ]; then
  echo "--check does not take --to (it inspects one checkout; use --slug to narrow)" >&2
  usage >&2; exit 2
fi

fail=0

resolve_root() {
  # repo toplevel of a dir (accepts the toplevel itself or any subdir)
  ( cd "$1" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null ) || return 1
}

# read_refs <artifact> <name> — every proof ref the gate reads, into REFS. A header the gate
# refuses as a whole (unreadable, over the ref caps) is named here instead of counting 0 proofs.
read_refs() {
  local rc=0
  REFS="$(pg_artifact_proof_refs "$1" 2>/dev/null)" || rc=$?
  _pgl_clean "$2"
  case "$rc" in
    0) return 0 ;;
    2) echo "WARN $_PGL_CLEAN: proof header over the gate's caps (refs, comma items or characters) — its proofs are skipped; the gate refuses it" ;;
    *) echo "WARN $_PGL_CLEAN: artifact unreadable — its proofs are skipped" ;;
  esac
  REFS=""; return 1
}

# lint_artifact <repo-root> <artifact-path> → prints OK/FAIL lines; returns 1 on FAIL
lint_artifact() {
  local root="$1" art="$2" name
  _pgl_clean "${art#"$root"/}"; name="$_PGL_CLEAN"

  if ! grep -q '<!-- zuvo-review -->' "$art" 2>/dev/null; then
    echo "FAIL $name: missing '<!-- zuvo-review -->' marker — the gate skips this artifact entirely"
    return 1
  fi

  local range files
  range="$(sed -n 's/^range:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
  files="$(sed -n 's/^files:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"

  case "$range" in
    *..*) : ;;
    *) echo "FAIL $name: range: header missing or not '<base>..<head>'"; return 1 ;;
  esac

  if [ -z "$files" ]; then
    echo "FAIL $name: files: header missing (or use 'files: *' for whole-range)"
    return 1
  fi
  case "$files" in
    '*'|*,*) : ;;
    *" "*)
      echo "FAIL $name: files: is SPACE-separated — the gate splits on commas only, so no file can ever match"
      return 1 ;;
  esac

  lint_proofs "$root" "$art" "$name"
}

# proof_reason <token> <ref> <detail> — why the gate refuses one proof ref, and the repair.
proof_reason() {
  case "$1" in
    no-ref) echo "no adversarial: proof line ($3) — post-cutoff artifacts without one grant no coverage" ;;
    too-many-refs) echo "cites too many proofs ($3) — the gate refuses the artifact" ;;
    not-a-path) echo "adversarial: value '$2' is prose, not a proof path — cite the saved adversarial output file" ;;
    no-containment) echo "the containment check is not installed beside the gate library ($3) — reinstall zuvo" ;;
    escapes) echo "proof path '$2' escapes the repo (absolute, .. segment, or a symlink out) — the gate rejects it" ;;
    missing) echo "proof '$2' is not in THIS checkout — the gate refuses it here; sync the pair (--from <checkout> --to .) or --restore" ;;
    truncated) echo "proof '$2' is truncated ($3) — the reviewers never saw the whole change; re-run the review" ;;
    blind-audit) echo "proof '$2' is a blind-audit record, not a review — cite the review's own adversarial output" ;;
    weak) echo "proof '$2' is weak: $3 — proof-of-work will reject it" ;;
    unreadable) echo "proof '$2' cannot be read — fix its permissions so the gate can count its REVIEW BY: lines" ;;
    scan-error) echo "proof '$2' could not be scanned ($3) — the gate grants nothing it cannot verify; re-save the proof" ;;
    *) echo "proof '$2' refused: $1 ($3)" ;;
  esac
}

# lint_proofs <root> <artifact> <name> — the push gate's proof verdict, one FAIL line per refused
# ref. Called directly, not through the gate's memo, whose locals are unbound under `set -u`.
lint_proofs() {
  local root="$1" art="$2" name out rc=0 rest line tok ref det ok="" nbad=0
  _pgl_clean "$3"; name="$_PGL_CLEAN"
  out="$(pg_artifact_proof_verdict "$root" "$art" 2>/dev/null)" || rc=$?
  rest="$out$_PGL_NL"
  while [ -n "$rest" ]; do
    line="${rest%%"$_PGL_NL"*}"; rest="${rest#*"$_PGL_NL"}"
    [ -n "$line" ] || continue
    tok="${line%%"$_PGL_TAB"*}"; line="${line#*"$_PGL_TAB"}"
    ref="${line%%"$_PGL_TAB"*}"; det="${line#*"$_PGL_TAB"}"
    _pgl_clean "$ref"; ref="$_PGL_CLEAN"; _pgl_clean "$det"; det="$_PGL_CLEAN"
    case "$tok" in
      grandfathered) ok="grandfathered: $det" ;;
      proven) ok="${ok:-proof: }${ok:+, }$ref" ;;
      missing-optional) ok="${ok:-proof: }${ok:+, }$ref [$det]" ;;
      *) nbad=$((nbad + 1)); echo "FAIL $name: $(proof_reason "$tok" "$ref" "$det")" ;;
    esac
  done
  # Fail closed on any disagreement between the rc and the lines: a refusal must never print OK.
  if [ "$rc" -ne 0 ] || [ "$nbad" -gt 0 ] || [ -z "$ok" ]; then
    [ "$nbad" -gt 0 ] || echo "FAIL $name: the gate refuses this artifact's proof (verdict rc=$rc, no reason reported)"
    return 1
  fi
  echo "OK   $name ($ok)"
}

do_check() {
  local root found=0
  root="$(resolve_root "${SRC:-.}")" || { echo "Not a git checkout: ${SRC:-.}" >&2; exit 2; }
  for art in "$root"/memory/reviews/*.md; do
    [ -e "$art" ] || continue
    if [ -n "$SLUG" ]; then
      case "$(basename "$art")" in *"$SLUG"*) : ;; *) continue ;; esac
    fi
    found=1
    lint_artifact "$root" "$art" || fail=1
  done
  if [ "$found" -ne 1 ]; then
    if [ -n "$SLUG" ]; then
      # A slug that matches nothing must FAIL: post-run validation citing a typo'd
      # slug would otherwise print nothing and exit 0 — a passing-looking no-op.
      echo "FAIL: no artifact matching --slug '$SLUG' under $root/memory/reviews/" >&2
      exit 1
    fi
    echo "No artifacts under $root/memory/reviews/"
  fi
  exit "$fail"
}

# copy_preserving <src-file> <dst-file> → 0 copied/identical, 1 conflict
copy_preserving() {
  local s="$1" d="$2"
  if [ -e "$d" ]; then
    if cmp -s "$s" "$d"; then
      return 0                              # identical — nothing to do
    fi
    echo "CONFLICT: $d exists with DIFFERENT content — not overwriting (resolve by hand)" >&2
    return 1
  fi
  mkdir -p "$(dirname "$d")" && cp -p "$s" "$d"
}

do_sync() {
  local sroot droot copied=0
  sroot="$(resolve_root "$SRC")" || { echo "Not a git checkout: $SRC" >&2; exit 2; }
  droot="$(resolve_root "$DST")" || { echo "Not a git checkout: $DST" >&2; exit 2; }
  [ "$sroot" = "$droot" ] && { echo "--from and --to resolve to the same checkout: $sroot" >&2; exit 2; }

  for art in "$sroot"/memory/reviews/*.md; do
    [ -e "$art" ] || continue
    local name rest ref shown
    name="$(basename "$art")"
    if [ -n "$SLUG" ]; then
      case "$name" in *"$SLUG"*) : ;; *) continue ;; esac
    fi
    grep -q '<!-- zuvo-review -->' "$art" 2>/dev/null || continue   # only machine artifacts travel

    if ! copy_preserving "$art" "$droot/memory/reviews/$name"; then
      fail=1; continue
    fi

    # Every ref the gate reads. Prose copies nothing; the lint below names it.
    read_refs "$art" "$name" || true
    rest="$REFS$_PGL_NL"
    while [ -n "$rest" ]; do
      ref="${rest%%"$_PGL_NL"*}"; rest="${rest#*"$_PGL_NL"}"
      [ -n "$ref" ] && proof_ref_is_path "$ref" || continue
      _pgl_clean "$ref"; shown="$_PGL_CLEAN"
      # BOTH roots: the proof is READ from $sroot and WRITTEN to $droot, and a symlink in either
      # carries the copy out of its checkout.
      if ! path_contained "$sroot" "$ref" || ! path_contained "$droot" "$ref"; then
        echo "WARN $name: proof path '$shown' escapes the repo (absolute, .. segment, or a symlink out) — artifact copied, proof NOT"
      elif [ -f "$sroot/$ref" ]; then
        copy_preserving "$sroot/$ref" "$droot/$ref" || fail=1
      else
        echo "WARN $name: proof '$shown' missing in SOURCE too — copied the artifact, but coverage will need the proof"
      fi
    done
    copied=$((copied + 1))
    lint_artifact "$droot" "$droot/memory/reviews/$name" || fail=1
  done

  echo "SYNCED: $copied artifact pair(s) from $sroot to $droot"
  exit "$fail"
}

# ─────────────────────────────────────────────────────────────────────────────────────────────
# ARCHIVE / RESTORE — the durable half, added 2026-09-18 after measuring what --from/--to cannot
# reach.
#
# `--from/--to` moves a pair between checkouts that BOTH still exist. That is the 2026-07-31
# incident, and it is real, but it is not the common one. Measured on tgm-survey-platform: of 168
# artifacts whose `adversarial:` header pointed at a missing proof, a search across 243 checkouts
# and 3811 proof filenames found **3**. The other 165 were gone — written in a worktree that was
# later removed, and `zuvo/` is gitignored, so the proof left with the directory. No sync can
# recover those; the review happened and its evidence no longer exists anywhere on the machine.
#
# So the fix is not better recovery, it is not losing them: keep a copy OUTSIDE every checkout.
# $ZUVO_ARCHIVE (default ~/.zuvo/review-archive/<repo>/) is HOME-local, survives `worktree remove`,
# and is the one place a proof can be found again after its worktree is gone.
ARCHIVE_ROOT="${ZUVO_REVIEW_ARCHIVE:-$HOME/.zuvo/review-archive}"

# An `adversarial:` header is supposed to be a repo-relative PATH. Some are prose — a whole run
# narrative ("--multi; pass1 32 chunks exit 0; …"). The gate cannot resolve those either, so they
# grant no coverage, and `basename` reads a leading `--` as an option and dies. Recognise them.
proof_ref_is_path() {
  case "$1" in ''|-*) return 1 ;; esac
  ! pg_proof_ref_is_prose "$1"
}

archive_dir_for() {                       # one directory per repo, by the main checkout's name
  local root="$1" common
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$common" ] || common="$root/.git"
  printf '%s/%s' "$ARCHIVE_ROOT" "$(basename "$(dirname "$common")")"
}

do_archive() {
  local root adir art name rest ref a=0 n=0 miss=0 prose=0
  root="$(resolve_root "${SRC:-$PWD}")" || return 2
  adir="$(archive_dir_for "$root")"
  for art in "$root"/memory/reviews/*.md; do
    [ -f "$art" ] || continue
    name="$(basename "$art")"
    case "$name" in *"${SLUG}"*) : ;; *) [ -n "$SLUG" ] && continue ;; esac
    copy_preserving "$art" "$adir/reviews/$name" || true
    a=$((a + 1))
    # Keyed by the ARTIFACT and the proof's repo-relative path: proof basenames are not unique,
    # within one artifact or across runs, and a shared key would let --restore hand an artifact
    # somebody else's proof. path_contained before the read: this runs unattended from the
    # PostToolUse hook on header text an agent wrote.
    read_refs "$art" "$name" || true
    rest="$REFS$_PGL_NL"
    while [ -n "$rest" ]; do
      ref="${rest%%"$_PGL_NL"*}"; rest="${rest#*"$_PGL_NL"}"
      [ -n "$ref" ] || continue
      if proof_ref_is_path "$ref" && path_contained "$root" "$ref" && [ -f "$root/$ref" ]; then
        copy_preserving "$root/$ref" "$adir/proofs/${name%.md}/$ref" || true
        n=$((n + 1))
      elif ! proof_ref_is_path "$ref"; then
        prose=$((prose + 1))               # header holds a narrative, not a path
      else
        miss=$((miss + 1))                 # already dangling here — nothing to archive
      fi
    done
  done
  echo "archived to $adir: $a artifact(s), $n proof(s); $miss proof ref(s) ALREADY missing"
  [ "$miss" -eq 0 ] || echo "  (those $miss cannot be recovered by any sync — their proof is gone)"
  [ "$prose" -eq 0 ] || echo "  $prose ref(s) are PROSE instead of a path — the gate cannot resolve those, fix the header"
}

do_restore() {
  local root adir art name stem rest ref legacy src n=0 nf=0
  root="$(resolve_root "${DST:-$PWD}")" || return 2
  adir="$(archive_dir_for "$root")"
  [ -d "$adir" ] || { echo "no archive at $adir — nothing to restore" >&2; return 1; }
  for art in "$root"/memory/reviews/*.md; do
    [ -f "$art" ] || continue
    name="$(basename "$art")"; stem="${name%.md}"
    case "$name" in *"${SLUG}"*) : ;; *) [ -n "$SLUG" ] && continue ;; esac
    read_refs "$art" "$name" || true
    # Archives written before path keys hold <stem>/<basename> of the first ref only, so that file is
    # offered to that ref alone — never to another ref sharing its basename. Taken from the cleaned
    # refs, so a CRLF or backticked header still matches.
    legacy="${REFS%%"$_PGL_NL"*}"
    rest="$REFS$_PGL_NL"
    while [ -n "$rest" ]; do
      ref="${rest%%"$_PGL_NL"*}"; rest="${rest#*"$_PGL_NL"}"
      [ -n "$ref" ] || continue
      # Write side of the containment guard — this COPIES INTO $root/$ref.
      proof_ref_is_path "$ref" && path_contained "$root" "$ref" && [ ! -f "$root/$ref" ] || continue
      src=""
      if [ -f "$adir/proofs/$stem/$ref" ]; then
        src="$adir/proofs/$stem/$ref"
      elif [ "$ref" = "$legacy" ] && [ -f "$adir/proofs/$stem/$(basename -- "$ref")" ]; then
        src="$adir/proofs/$stem/$(basename -- "$ref")"
      fi
      if [ -n "$src" ]; then
        mkdir -p "$root/$(dirname -- "$ref")" && cp -p "$src" "$root/$ref" && n=$((n + 1))
      else
        nf=$((nf + 1))
      fi
    done
  done
  echo "restored $n proof(s) into $root; $nf still missing from the archive too"
}

case "$MODE" in
  check) do_check ;;
  archive) do_archive ;;
  restore) do_restore ;;
  sync)
    [ -n "$SRC" ] && [ -n "$DST" ] || { echo "--from and --to are both required" >&2; usage >&2; exit 2; }
    do_sync ;;
  *) usage >&2; exit 2 ;;
esac
