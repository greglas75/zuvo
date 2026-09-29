#!/usr/bin/env bash
# Every tracked bash script PARSES (`bash -n`) — the floor under the lint gate.
#
# test-shellcheck.sh is the real lint, but it SKIPs where shellcheck is not installed, and so it said
# nothing on 2026-09-29 when a comment containing an apostrophe landed inside the single-quoted awk
# program of scripts/lib/reviewer-lanes.sh: the file stopped parsing, sourcing it defined only half of
# its functions, and every dist build and install.sh would have died at load. `bash -n` needs nothing
# but bash, so this gate runs everywhere.
#
# Corpus: tracked *.sh, plus tracked extensionless files under scripts/ and hooks/ whose shebang names
# bash or sh (the ~/.zuvo helpers in scripts/zuvo-home/ are extensionless). Python helpers are skipped
# by their shebang.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
cd "$ROOT" || { echo "FAIL: cannot cd to $ROOT"; exit 1; }
export GIT_CONFIG_GLOBAL=/dev/null

# The corpus: `git ls-files` in a checkout; a plain file walk where there is no .git (the farm runs a
# synced mirror without one — the first version of this gate checked nothing there and said so).
list_corpus() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files
  else
    find . \( -name .git -o -name node_modules -o -name dist -o -name zuvo -o -name .tmp \) -prune -o -type f -print \
      | sed 's|^\./||'
  fi
}

PASS=0; FAIL=0; BAD=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in
    *.sh) ;;
    scripts/*|hooks/*)
      case "$f" in */*.*) continue ;; esac
      head -1 "$f" 2>/dev/null | grep -qE '^#!.*\b(bash|sh)\b' || continue ;;
    *) continue ;;
  esac
  if err="$(bash -n "$f" 2>&1)"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    BAD="${BAD}
  FAIL $f: $(printf '%s' "$err" | head -2 | tr '\n' ' ')"
  fi
done < <(list_corpus)

[ -n "$BAD" ] && printf '%s\n' "$BAD"
echo "--- shell parse: PASS=$PASS FAIL=$FAIL"
[ "$PASS" -gt 0 ] || { echo "FAIL: no script was checked — the corpus query found nothing"; exit 1; }
[ "$FAIL" -eq 0 ]
