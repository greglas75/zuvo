#!/usr/bin/env bash
# Behaviour tests for scripts/stryker-scoped-config.sh's DIFF-LINE scoping (decision 6 in its header).
#
# Why: on 2026-10-02 a farm mutation campaign mutated 204 WHOLE files = 33,367 lines for a branch
# that had changed 2,880 of them (8%); 97 of the 204 files were not changed by the branch at all,
# and `ignoreStatic: false` let static mutants eat 71-83% of the run time. It ran 15+ hours. Every
# assertion below guards one way of drifting back to that: whole files by default, unchanged files
# kept from a --files-from list, static mutants re-enabled, or a diff parser that a hunk line can
# fool into scoping the wrong file.
#
# Each case builds a throwaway git repo; nothing touches this checkout.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STRYKER="$ROOT/scripts/stryker-scoped-config.sh"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# A missing tool is a SKIP (run-all.sh reads a leading `SKIP:` line), never an "ALL PASSED".
for tool in node git python3; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP: %s not installed — nothing was tested\n' "$tool"; exit 0; }
done
[ -f "$STRYKER" ] || { bad "missing scripts/stryker-scoped-config.sh"; echo "SOME FAILED"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

kv() { sed -n "s/^$2=//p" <<<"$1" | head -1; }

# The generated config's `mutate` array, one entry per line, in order.
mutate_of() { python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["mutate"]))' "$1"; }
cfg_key() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))[sys.argv[2]]; print(json.dumps(v))' "$1" "$2"; }

mkrepo() {
  git init -q -b main "$1" && git -C "$1" config user.email t@t && git -C "$1" config user.name t \
    && git -C "$1" config commit.gpgsign false
}
commit() { git -C "$1" add -A && git -C "$1" commit -qm "$2" >/dev/null; }
# N numbered lines `export const <p>K = K;`
numbered() { local i=1; while [ "$i" -le "$2" ]; do printf 'export const %s%d = %d;\n' "$1" "$i" "$i"; i=$((i + 1)); done; }
# Replace line N of a file (portable: no sed -i, which differs between BSD and GNU).
setline() { awk -v n="$2" -v r="$3" 'NR == n { $0 = r } 1' "$1" > "$1.tmp" && mv "$1.tmp" "$1"; }

# ── fixture: main → feature with committed, uncommitted and untracked changes ────────────────
R="$TMP/repo"
mkrepo "$R" || { bad "could not create the fixture repo"; echo "SOME FAILED"; exit 1; }
printf '{"name":"t","devDependencies":{"vitest":"^2.0.0"}}\n' > "$R/package.json"
mkdir -p "$R/src" "$R/app/[id]"
numbered a 10 > "$R/src/a.ts"
numbered b 10 > "$R/src/b.ts"
numbered c 3  > "$R/src/c.ts"
printf 'import { a1 } from "./a";\n' > "$R/src/a.test.ts"
printf 'export const page = 1;\n' > "$R/app/[id]/page.tsx"
printf '# readme\n' > "$R/README.md"
commit "$R" init
git -C "$R" checkout -q -b feature
setline "$R/src/a.ts" 3 'export const a3 = 33;'
setline "$R/src/a.ts" 7 'export const a7 = 77;'
setline "$R/src/a.ts" 8 'export const a8 = 88;'
# A hunk line that LOOKS like a file header: `+++ b/evil.ts` once git prefixes the `+`.
printf '++ b/evil.ts\n' >> "$R/src/a.ts"
numbered n 4 > "$R/src/new.ts"
printf '// touched\n' >> "$R/src/a.test.ts"
printf 'export const page = 2;\n' > "$R/app/[id]/page.tsx"
mkdir -p "$R/app/[slug]"
printf 'export const slug = 1;\n' > "$R/app/[slug]/page.tsx"
printf '# changed\n' >> "$R/README.md"
commit "$R" feature
setline "$R/src/b.ts" 5 'export const b5 = 55;'           # uncommitted, tracked
numbered u 2 > "$R/src/untracked.ts"                       # untracked, not ignored

# ── 1. default = changed lines ───────────────────────────────────────────────
out="$(cd "$R" && bash "$STRYKER" 2>"$TMP/err1")"; rc=$?
cfg="$(kv "$out" config_path)"
if [ "$rc" -eq 0 ] && [ -f "$cfg" ]; then
  got="$(mutate_of "$cfg" | tr '\n' ' ')"
  want='app/[[]slug[]]/page.tsx src/a.ts:3-3 src/a.ts:7-8 src/a.ts:11-11 src/b.ts:5-5 src/new.ts src/untracked.ts '
  [ "$got" = "$want" ] \
    && pass "default: one line range per hunk, added/untracked files whole, nothing else" \
    || bad "default mutate set wrong:\n      got:  $got\n      want: $want"
  case "$got" in *src/c.ts*) bad "default: an UNCHANGED file was mutated" ;; *) pass "default: unchanged file not mutated" ;; esac
  case "$got" in *a.test.ts*|*README*) bad "default: a test/doc file reached the mutate set" ;; *) pass "default: test and non-source files excluded" ;; esac
  case "$got" in *evil.ts*) bad "default: a hunk line was parsed as a file header (evil.ts in scope)" ;; *) pass "default: hunk content cannot impersonate a file header" ;; esac
  case "$got" in *src/b.ts:5-5*) pass "default: uncommitted working-tree change included" ;; *) bad "default: uncommitted change to src/b.ts missing" ;; esac
  [ "$(kv "$out" scope_mode)" = "changed-lines" ] && pass "default: scope_mode=changed-lines" \
    || bad "default: scope_mode=$(kv "$out" scope_mode)"
  case "$(kv "$out" diff_base)" in main@*) pass "default: base detected as the local default branch" ;;
    *) bad "default: diff_base=$(kv "$out" diff_base), want main@<sha>" ;; esac
else
  bad "default run failed (rc=$rc): $(cat "$TMP/err1")"
fi

# Decision 3: static mutants ignored by default, and the only coverage mode Stryker accepts with it.
if [ -f "${cfg:-}" ]; then
  [ "$(cfg_key "$cfg" ignoreStatic)" = "true" ] && [ "$(cfg_key "$cfg" coverageAnalysis)" = '"perTest"' ] \
    && pass "default: ignoreStatic=true with coverageAnalysis=perTest" \
    || bad "default: ignoreStatic=$(cfg_key "$cfg" ignoreStatic) coverageAnalysis=$(cfg_key "$cfg" coverageAnalysis)"
  [ "$(kv "$out" ignore_static)" = "true" ] && pass "default: ignore_static=true reported" || bad "default: ignore_static not reported true"
fi

# A modified glob-character path cannot take a Stryker range: dropped LOUDLY, never silently —
# and on STDOUT too, because that is the stream a caller captures.
if grep -q 'DROPPED app/\[id\]/page.tsx' "$TMP/err1"; then
  pass "glob path: modified [id] file dropped with a named stderr line"
else
  bad "glob path: no DROPPED line for app/[id]/page.tsx"
fi
[ "$(kv "$out" dropped_count)" = "1" ] && [ "$(kv "$out" dropped_file)" = 'glob-path:app/[id]/page.tsx' ] \
  && pass "glob path: dropped_count/dropped_file reported on stdout" \
  || bad "glob path: stdout dropped_count=$(kv "$out" dropped_count) dropped_file=$(kv "$out" dropped_file)"
[ "$(kv "$out" file_count)" = "5" ] && pass "default: file_count=5 (a.ts b.ts new.ts untracked.ts [slug])" \
  || bad "default: file_count=$(kv "$out" file_count), want 5"
# The one-line summary the owner asked for: files, ranges, mutated vs changed lines.
summary="$(grep 'scope=changed-lines' "$TMP/err1" | head -1)"
case "$summary" in
  *files=*line_ranges=*mutated_lines=*changed_lines=*) pass "summary line on stderr: $summary" ;;
  *) bad "no summary line on stderr: $(cat "$TMP/err1")" ;;
esac
# changed: a.ts 4 + b.ts 1 + new.ts 4 + untracked.ts 2 + [slug] 1 + [id] 1 = 13; [id] is dropped.
[ "$(kv "$out" mutated_lines)" = "12" ] && [ "$(kv "$out" changed_lines)" = "13" ] \
  && pass "line accounting: 12 mutated of 13 changed (the dropped glob file is the gap)" \
  || bad "line accounting: mutated=$(kv "$out" mutated_lines) changed=$(kv "$out" changed_lines), want 12/13"

# ── 2. explicit --diff gives the same scope ─────────────────────────────────
out2="$(cd "$R" && bash "$STRYKER" --diff main 2>/dev/null)"
if [ -f "$(kv "$out2" config_path)" ] && [ "$(mutate_of "$(kv "$out2" config_path)")" = "$(mutate_of "$cfg")" ]; then
  pass "--diff main matches the detected default"
else
  bad "--diff main produced a different scope"
fi
(cd "$R" && bash "$STRYKER" --diff no-such-ref >/dev/null 2>&1); rc=$?
[ "$rc" -eq 4 ] && pass "--diff to an unknown ref → exit 4" || bad "--diff unknown ref gave rc=$rc, want 4"

# ── 3. --files-from is INTERSECTED with the diff ────────────────────────────
printf 'src/a.ts\nsrc/c.ts\nsrc/a.test.ts\n' > "$TMP/list.txt"
out3="$(cd "$R" && bash "$STRYKER" --files-from "$TMP/list.txt" 2>"$TMP/err3")"; rc=$?
cfg3="$(kv "$out3" config_path)"
if [ "$rc" -eq 0 ] && [ -f "$cfg3" ]; then
  got="$(mutate_of "$cfg3" | tr '\n' ' ')"
  [ "$got" = 'src/a.ts:3-3 src/a.ts:7-8 src/a.ts:11-11 ' ] \
    && pass "--files-from: changed file narrowed to its hunks; other changed files not added" \
    || bad "--files-from mutate set: $got"
  grep -q 'dropped: src/c.ts (unchanged' "$TMP/err3" \
    && pass "--files-from: unchanged file dropped and NAMED on stderr" \
    || bad "--files-from: no stderr line naming src/c.ts as dropped: $(cat "$TMP/err3")"
  grep -q 'dropped: src/a.test.ts' "$TMP/err3" \
    && pass "--files-from: listed test file dropped and named" \
    || bad "--files-from: src/a.test.ts not reported as dropped"
  drops="$(sed -n 's/^dropped_file=//p' <<<"$out3" | tr '\n' ' ')"
  [ "$(kv "$out3" dropped_count)" = "2" ] && [ "$drops" = 'unchanged:src/c.ts not-source:src/a.test.ts ' ] \
    && pass "--files-from: both drops reported on stdout with their reason" \
    || bad "--files-from: stdout drops '$drops' (count $(kv "$out3" dropped_count))"
else
  bad "--files-from run failed (rc=$rc): $(cat "$TMP/err3")"
fi

printf 'src/c.ts\n' > "$TMP/unchanged.txt"
rm -f "$R"/.stryker-scoped-*.conf.json
(cd "$R" && bash "$STRYKER" --files-from "$TMP/unchanged.txt" >/dev/null 2>&1); rc=$?
n_cfg="$(find "$R" -maxdepth 1 -name '.stryker-scoped-*.conf.json' | wc -l | tr -d ' ')"
[ "$rc" -eq 3 ] && [ "$n_cfg" = "0" ] \
  && pass "--files-from with only unchanged files → exit 3, no config written" \
  || bad "only-unchanged list gave rc=$rc and $n_cfg configs (want 3 and 0)"

: > "$TMP/empty.txt"
(cd "$R" && bash "$STRYKER" --files-from "$TMP/empty.txt" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] && pass "empty --files-from list → usage error, not a silent whole-branch scope" \
  || bad "empty --files-from gave rc=$rc, want 2"

# ── 4. --whole-files is the explicit opt-out and restores the old behaviour ──
out4="$(cd "$R" && bash "$STRYKER" --whole-files --files-from "$TMP/list.txt" 2>"$TMP/err4")"; rc=$?
cfg4="$(kv "$out4" config_path)"
if [ "$rc" -eq 0 ] && [ -f "$cfg4" ]; then
  [ "$(mutate_of "$cfg4" | tr '\n' ' ')" = 'src/a.ts src/c.ts src/a.test.ts ' ] \
    && pass "--whole-files: listed files mutated whole, unfiltered (old behaviour)" \
    || bad "--whole-files mutate set: $(mutate_of "$cfg4" | tr '\n' ' ')"
  grep -q 'NOT the default' "$TMP/err4" && pass "--whole-files: warns that it is not the default" \
    || bad "--whole-files: no 'NOT the default' warning"
  grep -q 'unchanged: src/c.ts' "$TMP/err4" && pass "--whole-files: names the unchanged files it mutates anyway" \
    || bad "--whole-files: unchanged src/c.ts not named"
  [ "$(kv "$out4" scope_mode)" = "whole-files" ] && pass "--whole-files: scope_mode=whole-files" \
    || bad "--whole-files: scope_mode=$(kv "$out4" scope_mode)"
else
  bad "--whole-files run failed (rc=$rc): $(cat "$TMP/err4")"
fi

# ── 5. static mutants: opt-out flag, and the combination Stryker rejects ────
out5="$(cd "$R" && bash "$STRYKER" --include-static 2>/dev/null)"
cfg5="$(kv "$out5" config_path)"
if [ -f "$cfg5" ] && [ "$(cfg_key "$cfg5" ignoreStatic)" = "false" ] && [ "$(cfg_key "$cfg5" coverageAnalysis)" = '"off"' ]; then
  pass "--include-static: ignoreStatic=false and coverageAnalysis falls back to off"
else
  bad "--include-static: ignoreStatic=$(cfg_key "${cfg5:-/dev/null}" ignoreStatic 2>/dev/null) coverage=$(cfg_key "${cfg5:-/dev/null}" coverageAnalysis 2>/dev/null)"
fi
(cd "$R" && bash "$STRYKER" --coverage off >/dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] && pass "--coverage off without --include-static → exit 2 (Stryker would refuse at startup)" \
  || bad "--coverage off with ignoreStatic gave rc=$rc, want 2"

# ── 6. nothing changed → exit 3, no config ──────────────────────────────────
C="$TMP/clean"
mkrepo "$C" && numbered x 3 > "$C/x.ts" && commit "$C" init && git -C "$C" checkout -q -b same
(cd "$C" && bash "$STRYKER" >/dev/null 2>"$TMP/err6"); rc=$?
[ "$rc" -eq 3 ] && pass "no changed lines → exit 3 (an empty mutate set would score 100%)" \
  || bad "no changes gave rc=$rc, want 3: $(cat "$TMP/err6")"

# ── 7. the NEAREST default branch is the base ───────────────────────────────
# origin/HEAD → origin/main, but the branch was cut from origin/develop, which carries its own
# change to d.ts. Diffing against main would put develop's work in this branch's scope. Local
# main stays at the root, so falling back to local branches would fail this case too.
N="$TMP/nearest"
mkrepo "$N" && numbered m 3 > "$N/m.ts" && commit "$N" init
m0="$(git -C "$N" rev-parse HEAD)"
git -C "$N" checkout -q -b develop
numbered d 3 > "$N/d.ts" && commit "$N" develop-work
d1="$(git -C "$N" rev-parse HEAD)"
git -C "$N" remote add origin "$TMP/no-such-remote"
git -C "$N" update-ref refs/remotes/origin/main "$m0"
git -C "$N" update-ref refs/remotes/origin/develop "$d1"
git -C "$N" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$N" checkout -q -b feature
git -C "$N" branch -q -D develop
setline "$N/m.ts" 2 'export const m2 = 22;' && commit "$N" feature-work
out7="$(cd "$N" && bash "$STRYKER" 2>/dev/null)"
case "$(kv "$out7" diff_base)" in
  origin/develop@*) pass "base: nearest default branch (origin/develop) chosen over origin/HEAD (main)" ;;
  *) bad "base: diff_base=$(kv "$out7" diff_base), want origin/develop@<sha>" ;;
esac
if [ -f "$(kv "$out7" config_path)" ]; then
  [ "$(mutate_of "$(kv "$out7" config_path)" | tr '\n' ' ')" = 'm.ts:2-2 ' ] \
    && pass "base: develop's own change (d.ts) is not in the branch scope" \
    || bad "base: mutate set $(mutate_of "$(kv "$out7" config_path)" | tr '\n' ' ')"
fi

# ── 8. --repo pointing at a monorepo package scopes the diff to it ──────────
M="$TMP/mono"
mkrepo "$M" && mkdir -p "$M/packages/p/src" "$M/packages/q/src"
numbered p 4 > "$M/packages/p/src/x.ts" && numbered q 4 > "$M/packages/q/src/y.ts" && commit "$M" init
git -C "$M" checkout -q -b feature
setline "$M/packages/p/src/x.ts" 2 'export const p2 = 22;'
setline "$M/packages/q/src/y.ts" 3 'export const q3 = 33;'
commit "$M" feature
out8="$(bash "$STRYKER" --repo "$M/packages/p" 2>/dev/null)"
if [ -f "$(kv "$out8" config_path)" ]; then
  [ "$(mutate_of "$(kv "$out8" config_path)" | tr '\n' ' ')" = 'src/x.ts:2-2 ' ] \
    && pass "--repo <package>: entries relative to the package, other packages excluded" \
    || bad "--repo <package>: mutate set $(mutate_of "$(kv "$out8" config_path)" | tr '\n' ' ')"
else
  bad "--repo <package>: no config produced"
fi

# ── 9. outside git: fail closed by default, whole files only on request ─────
P="$TMP/nogit"
mkdir -p "$P/src" && numbered z 2 > "$P/src/z.ts"
(cd "$P" && bash "$STRYKER" --repo "$P" --file src/z.ts >/dev/null 2>&1); rc=$?
[ "$rc" -eq 4 ] && pass "non-git repo: changed-lines scope refuses (exit 4) instead of guessing" \
  || bad "non-git repo gave rc=$rc, want 4"
out9="$(bash "$STRYKER" --repo "$P" --whole-files --file src/z.ts 2>/dev/null)"
[ "$(kv "$out9" changed_lines)" = "unknown" ] && [ "$(kv "$out9" mutate_count)" = "1" ] \
  && pass "non-git repo + --whole-files: works, changed_lines=unknown" \
  || bad "non-git repo + --whole-files: mutate_count=$(kv "$out9" mutate_count) changed_lines=$(kv "$out9" changed_lines)"

# ── 10. a path with a space: git appends a TAB to its ---/+++ header line ───
S="$TMP/space"
mkrepo "$S" && mkdir -p "$S/src/my dir" && numbered s 3 > "$S/src/my dir/x y.ts" && commit "$S" init
git -C "$S" checkout -q -b feature
setline "$S/src/my dir/x y.ts" 2 'export const s2 = 22;' && commit "$S" feature
out10="$(cd "$S" && bash "$STRYKER" 2>/dev/null)"
if [ -f "$(kv "$out10" config_path)" ] \
   && [ "$(mutate_of "$(kv "$out10" config_path)")" = 'src/my dir/x y.ts:2-2' ]; then
  pass "path with a space: header TAB stripped, file stays in scope"
else
  bad "path with a space lost from the scope (rc/out: $(kv "$out10" mutate_count))"
fi

if [ "$fail" = 0 ]; then echo "ALL PASSED"; exit 0; else echo "SOME FAILED"; exit 1; fi
