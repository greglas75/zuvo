#!/usr/bin/env bash
# Tests ~/.zuvo/alloc-report-stem (scripts/zuvo-home/alloc-report-stem): the report stem a skill
# writes its .md/.json/.report.json under. Each row names the overwrite or escape it prevents.
set -u
export GIT_CONFIG_GLOBAL=/dev/null
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
H="$ROOT/scripts/zuvo-home/alloc-report-stem"
TMP="$(mktemp -d)"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
D=2026-10-10

# fresh_dir NAME: an empty audits dir per case, so no row sees another row's files.
fresh_dir() { mkdir -p "$TMP/$1" && printf '%s' "$TMP/$1"; }
# stem DIR SCOPE [extra args...]: the basename the helper allocates, or "rc=N" on failure.
stem() {
  local dir="$1" scope="$2" out rc; shift 2
  out=$(bash "$H" --dir "$dir" --prefix mutation-test --scope "$scope" --date "$D" "$@" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] || { printf 'rc=%s' "$rc"; return; }
  printf '%s' "${out##*/}"
}

echo "=== the skill calls it by path: a non-executable helper is 'permission denied' at report time ==="
[ -x "$H" ] && ok "helper is executable" || bad "helper missing or not executable: $H"

echo "=== slug: scope text becomes a safe, bounded filename part ==="
long="$(printf 'a%.0s' $(seq 1 59))/$(printf 'b%.0s' $(seq 1 140))"
a59="$(printf 'a%.0s' $(seq 1 59))"
# scope | expected basename | bug it catches
row=0
while IFS='|' read -r scope want why; do
  row=$((row + 1))
  got=$(stem "$(fresh_dir "slug-$row")" "$scope")
  [ "$got" = "$want" ] && ok "$why" || bad "$why: scope '$scope' gave '$got', want '$want'"
done <<EOF
src/Foo Bar.ts|mutation-test-$D-src-foo-bar-ts|path separators and spaces must not reach the filename
zażółć/ąę.ts|mutation-test-$D-za-ts|non-ASCII bytes must not reach the filename (LC_ALL=C)
../../etc|mutation-test-$D-etc|a scope of ../ must not move the report out of the audits dir
|mutation-test-$D-all|an empty scope must still yield a name, not a trailing dash
---|mutation-test-$D-all|a scope of only separators must not yield an empty slug
branch-feat/RD-1040_x|mutation-test-$D-branch-feat-rd-1040-x|the branch scope keeps its words, lowercased
$long|mutation-test-$D-$a59|a 200-char scope is cut to 60 with no dangling dash
EOF

echo "=== collisions: a second same-day run never overwrites the first ==="
dir=$(fresh_dir coll-md)
: > "$dir/mutation-test-$D-src-x-ts.md"
got=$(stem "$dir" src/x.ts)
[ "$got" = "mutation-test-$D-src-x-ts-2" ] && ok "an existing .md moves the next run to -2" \
  || bad "existing .md: got '$got'"
dir=$(fresh_dir coll-json)
: > "$dir/mutation-test-$D-src-x-ts.json"
got=$(stem "$dir" src/x.ts)
[ "$got" = "mutation-test-$D-src-x-ts-2" ] \
  && ok "a sibling .json alone also moves the next run to -2 (else its .json is overwritten)" \
  || bad "existing .json only: got '$got' — the second session would overwrite the first's .json"
dir=$(fresh_dir coll-own)
got=$(stem "$dir" src/x.ts)
[ -f "$dir/$got.md" ] && ok "the allocated stem's first extension exists on return (the claim is held)" \
  || bad "no claim file $got.md — a concurrent run could take the same stem"
dir=$(fresh_dir coll-ext)
: > "$dir/mutation-test-$D-src-x-ts.csv"
got=$(stem "$dir" src/x.ts --ext .csv,.txt)
[ "$got" = "mutation-test-$D-src-x-ts-2" ] && ok "--ext replaces the sibling set it checks" \
  || bad "--ext .csv,.txt with an existing .csv: got '$got'"
[ -f "$dir/$got.csv" ] && ok "with no .md in --ext the first entry is the claim" \
  || bad "--ext .csv,.txt left no claim file $got.csv"
# Callers listing the extensions in another order must still race for the same claim file.
dir=$(fresh_dir claim-order)
got=$(stem "$dir" src/x.ts --ext .json,.report.json,.md)
[ -f "$dir/$got.md" ] && [ ! -e "$dir/$got.json" ] \
  && ok "the claim is .md whatever the --ext order (two orders cannot hold one stem twice)" \
  || bad "--ext .json,.report.json,.md claimed '$(ls "$dir" | tr '\n' ' ')', want only $got.md"

echo "=== concurrency: 8 runs at once get 8 different stems ==="
dir=$(fresh_dir conc)
for i in 1 2 3 4 5 6 7 8; do
  bash "$H" --dir "$dir" --prefix mutation-test --scope src/x.ts --date "$D" > "$TMP/conc.$i" 2>/dev/null &
done
wait
distinct=$(cat "$TMP"/conc.* 2>/dev/null | awk 'NF' | sort -u | wc -l | tr -d ' ')
[ "$distinct" = "8" ] && ok "8 concurrent runs allocated 8 distinct stems" \
  || bad "8 concurrent runs allocated $distinct distinct stem(s) — two runs share one report"

echo "=== exhaustion and bad input fail closed ==="
dir=$(fresh_dir full)
: > "$dir/mutation-test-$D-src-x-ts.md"
for n in $(seq 2 99); do : > "$dir/mutation-test-$D-src-x-ts-$n.md"; done
bash "$H" --dir "$dir" --prefix mutation-test --scope src/x.ts --date "$D" >/dev/null 2>&1
rc=$?
[ "$rc" = "1" ] && ok "99 taken stems exit 1 instead of overwriting one" || bad "99 taken: rc=$rc, want 1"
[ ! -e "$dir/mutation-test-$D-src-x-ts-100.md" ] && ok "no -100 stem is created past the cap" \
  || bad "the 99-attempt cap was exceeded"

ro=$(fresh_dir ro); chmod 555 "$ro"
dir=$(fresh_dir args)
# args | expected rc | bug it catches
while IFS='|' read -r args want why; do
  # shellcheck disable=SC2086  # word-split the table cell into arguments on purpose
  bash "$H" $args >/dev/null 2>&1
  rc=$?
  [ "$rc" = "$want" ] && ok "$why" || bad "$why: rc=$rc, want $want (args: $args)"
done <<EOF
--dir $dir --prefix mutation-test --scope x --date 2026-13-01|2|month 13 is not a date
--dir $dir --prefix mutation-test --scope x --date 26-10-10|2|a two-digit year is not a date
--dir $dir --prefix mutation-test --scope x --date 2026/10/10|2|a slash date would add a path level
--dir $dir --prefix mutation-test --scope x --date 2026-10-10x|2|trailing junk after the date is rejected
--dir $dir --prefix mutation-test --scope x --date 2026-02-31|2|an impossible calendar day is not a date
--dir $TMP/nope --prefix mutation-test --scope x|2|a missing dir is an error, not a silent mkdir elsewhere
--dir $dir/../full/mutation-test-$D-src-x-ts.md --prefix mutation-test --scope x|2|a file passed as --dir is rejected
--dir $dir --prefix ../evil --scope x|2|a prefix with a path must not escape the dir
--dir $dir --prefix mutation-test --scope x --ext .md,../x|2|an extension with a path must not escape the dir
--dir $dir --prefix mutation-test --scope x --ext .json,../evil|2|a path extension after a valid one is still rejected
--dir $dir --prefix mutation-test|2|a missing --scope is a usage error
--dir $dir --prefix mutation-test --scope|2|a trailing value flag is a usage error, not a hang
--dir $dir --prefix mutation-test --scope x --bogus|2|an unknown flag is a usage error
EOF
if [ -w "$ro" ]; then
  echo "  - SKIP unwritable-dir row: this user can write a 555 dir (root)"
else
  bash "$H" --dir "$ro" --prefix mutation-test --scope x --date "$D" >/dev/null 2>&1
  rc=$?
  [ "$rc" = "2" ] && ok "the -w precheck refuses an unwritable dir (exit 2) instead of looping over 99 stems" \
    || bad "unwritable dir: rc=$rc, want 2"
fi
nx=$(fresh_dir nosearch); chmod 200 "$nx"
if [ -x "$nx" ]; then
  echo "  - SKIP unsearchable-dir row: this user can search a 200 dir (root)"
else
  bash "$H" --dir "$nx" --prefix mutation-test --scope x --date "$D" >/dev/null 2>&1
  rc=$?
  [ "$rc" = "2" ] && ok "a writable but unsearchable dir exits 2 (sibling checks there would all read 'absent')" \
    || bad "mode-200 dir: rc=$rc, want 2"
fi

echo "=== a calendar validator is found even where date has neither -j nor -d ==="
real_date=$(command -v date); real_py=$(command -v python3); bash_bin=$(command -v bash)
for b in nodate nopy; do
  mkdir -p "$TMP/$b"
  printf '#!/bin/sh\ncase "$1" in -j|-d) exit 1 ;; esac\nexec %s "$@"\n' "$real_date" > "$TMP/$b/date"
  chmod +x "$TMP/$b/date"; ln -s "$(command -v tr)" "$TMP/$b/tr"
done
ln -s "$real_py" "$TMP/nodate/python3"
dir=$(fresh_dir pydate)
PATH="$TMP/nodate" "$bash_bin" "$H" --dir "$dir" --prefix mutation-test --scope x --date 2026-02-31 >/dev/null 2>&1
rc=$?
[ "$rc" = "2" ] && ok "python strptime rejects 2026-02-31 when date cannot" || bad "python validator: rc=$rc, want 2"
PATH="$TMP/nopy" "$bash_bin" "$H" --dir "$dir" --prefix mutation-test --scope x --date 2026-10-11 >/dev/null 2>&1
rc=$?
[ "$rc" = "0" ] && ok "with no calendar validator a well-shaped date is still accepted (degrade, not block)" \
  || bad "no validator, 2026-10-11: rc=$rc, want 0"
PATH="$TMP/nopy" "$bash_bin" "$H" --dir "$dir" --prefix mutation-test --scope x --date 2026-13-01 >/dev/null 2>&1
rc=$?
[ "$rc" = "2" ] && ok "with no calendar validator the shape check still rejects month 13" \
  || bad "no validator, 2026-13-01: rc=$rc, want 2"

echo "=== the default date is the local day ==="
dir=$(fresh_dir today)
before=$(date +%F)
got=$(bash "$H" --dir "$dir" --prefix mutation-test --scope x 2>/dev/null)
after=$(date +%F)
# Either side of the run, so a run that crosses midnight is not a false failure.
case "${got##*/}" in
  "mutation-test-$before-x"|"mutation-test-$after-x") ok "no --date uses local date +%F" ;;
  *) bad "default date: got '${got##*/}', want the local day $before or $after" ;;
esac
[ "$got" = "$dir/${got##*/}" ] && ok "the printed stem is the dir joined with the name (\$STEM.md lands in --dir)" \
  || bad "printed stem '$got' is not under '$dir'"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
