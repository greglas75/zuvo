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
#   review-artifact-sync.sh --check [<checkout>] [--slug <substr>]
#       Lint memory/reviews/*.md in the checkout (default: cwd's repo) —
#       all artifacts, or only those whose filename contains <substr> (use
#       right after writing an artifact to validate JUST that pair; a slug
#       matching nothing FAILs, never a silent pass). Checks: marker present,
#       range: parseable, files: comma-separated, adversarial: line present,
#       proof file resolves and holds >=2 'REVIEW BY:' lines (or 1 + an honest
#       single-provider note). Exit 0 = no FAILs (warnings ok), exit 1 = at
#       least one FAIL, exit 2 = usage error.
#
#   review-artifact-sync.sh --from <src-checkout> --to <dst-checkout> [--slug <substr>]
#       Copy artifact+proof PAIRS from src to dst (all marker-bearing artifacts,
#       or only those whose filename contains <substr>). Preserves mtimes.
#       Never overwrites a file with DIFFERENT content at the destination
#       (identical content = silent skip). Lints each copied artifact at dst.
set -uo pipefail

MODE=""
SRC=""
DST=""
SLUG=""

usage() { sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; }

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

# lint_artifact <repo-root> <artifact-path> → prints OK/WARN/FAIL lines; returns 1 on FAIL
lint_artifact() {
  local root="$1" art="$2" name ok=0
  name="${art#"$root"/}"

  if ! grep -q '<!-- zuvo-review -->' "$art" 2>/dev/null; then
    echo "FAIL $name: missing '<!-- zuvo-review -->' marker — the gate skips this artifact entirely"
    return 1
  fi

  local range files ref
  range="$(sed -n 's/^range:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
  files="$(sed -n 's/^files:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
  ref="$(sed -n 's/^[[:space:]]*adversarial:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
  [ -n "$ref" ] || ref="$(sed -n 's/^[[:space:]]*adv-proof:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"

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

  if [ -z "$ref" ]; then
    echo "WARN $name: no adversarial: proof line — post-cutoff artifacts without it grant no coverage locally"
    return 0
  fi
  case "$ref" in
    /*) echo "FAIL $name: proof path '$ref' is absolute — the gate rejects it"; return 1 ;;
  esac
  # Real traversal only: a path SEGMENT equal to `..`. A range-named proof
  # (`fd57e11..fc0c83e-adversarial.txt`) is one segment containing dots — matching the bare
  # substring `..` rejected every artifact following the skill's own naming convention.
  case "/$ref" in
    */../*|*/..) echo "FAIL $name: proof path '$ref' escapes the repo (.. traversal) — the gate rejects it"; return 1 ;;
  esac
  if [ ! -f "$root/$ref" ]; then
    echo "WARN $name: proof '$ref' not present in THIS checkout — pair incomplete here; sync it or pushes from here won't count this artifact"
    return 0
  fi
  local n
  n="$(grep -c 'REVIEW BY:' "$root/$ref" 2>/dev/null | head -1)"; n="${n:-0}"
  if [ "$n" -ge 2 ]; then
    ok=1
  elif [ "$n" -ge 1 ] && grep -qiE 'single.provider|1 of|provider timed out|only.*provider' "$root/$ref" 2>/dev/null; then
    ok=1
  fi
  if [ "$ok" -ne 1 ]; then
    echo "FAIL $name: proof '$ref' has $n 'REVIEW BY:' line(s) and no single-provider note — proof-of-work will reject it"
    return 1
  fi
  echo "OK   $name (proof: $ref, REVIEW BY x$n)"
  return 0
}

do_check() {
  local root arts found=0
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
    local name ref
    name="$(basename "$art")"
    if [ -n "$SLUG" ]; then
      case "$name" in *"$SLUG"*) : ;; *) continue ;; esac
    fi
    grep -q '<!-- zuvo-review -->' "$art" 2>/dev/null || continue   # only machine artifacts travel

    if ! copy_preserving "$art" "$droot/memory/reviews/$name"; then
      fail=1; continue
    fi

    ref="$(sed -n 's/^[[:space:]]*adversarial:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
    [ -n "$ref" ] || ref="$(sed -n 's/^[[:space:]]*adv-proof:[[:space:]]*//p' "$art" 2>/dev/null | head -1)"
    if [ -n "$ref" ]; then
      # Segment-based containment, same rule as lint_artifact() above and
      # pg_artifact_proven(). The leading "/" on the second case is load-bearing:
      # without it, `../x` and a bare `..` match NEITHER `*/../*` (needs a slash
      # before the dots) NOR `*/..`, fall through to the default branch, and get
      # copied to a path outside both checkouts. `../../x` happens to still match,
      # which is why a two-segment test case hides the bug. Verified by
      # tests/hooks/test-proof-path-containment.sh (do_sync cases).
      case "$ref" in
        /*) echo "WARN $name: proof path '$ref' is absolute — artifact copied, proof NOT"; copied=$((copied + 1)); lint_artifact "$droot" "$droot/memory/reviews/$name" || fail=1; continue ;;
      esac
      case "/$ref" in
        */../*|*/..) echo "WARN $name: proof path '$ref' escapes the repo — artifact copied, proof NOT" ;;
        *)
          if [ -f "$sroot/$ref" ]; then
            copy_preserving "$sroot/$ref" "$droot/$ref" || fail=1
          else
            echo "WARN $name: proof '$ref' missing in SOURCE too — copied the artifact, but coverage will need the proof"
          fi ;;
      esac
    fi
    copied=$((copied + 1))
    lint_artifact "$droot" "$droot/memory/reviews/$name" || fail=1
  done

  echo "SYNCED: $copied artifact pair(s) from $sroot to $droot"
  exit "$fail"
}

case "$MODE" in
  check) do_check ;;
  sync)
    [ -n "$SRC" ] && [ -n "$DST" ] || { echo "--from and --to are both required" >&2; usage >&2; exit 2; }
    do_sync ;;
  *) usage >&2; exit 2 ;;
esac
