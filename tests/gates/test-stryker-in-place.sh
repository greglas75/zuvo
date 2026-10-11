#!/usr/bin/env bash
# Behaviour tests for the in-place mode of scripts/stryker-scoped-config.sh and the restore in
# scripts/stryker-run-watchdog.sh.
#
# Why: TypeScript 7 (the native port) has no JS `parseConfigFileTextToJson`, and Stryker's sandbox tsconfig
# preprocessor calls it, so every sandboxed run on such a project dies before its first mutant
# (`ts.parseConfigFileTextToJson is not a function`). Retros 2026-10-09/10 rebuilt the same workaround by
# hand dozens of times: `inPlace: true` plus a `tsconfigFile` that does not exist. In place, Stryker writes
# into the working tree, and a run the watchdog kills cannot restore it: the watchdog must.
#
# Each case builds a throwaway repo with a stand-in `typescript` package; nothing touches this checkout.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STRYKER="$ROOT/scripts/stryker-scoped-config.sh"
WD="$ROOT/scripts/stryker-run-watchdog.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }
for tool in node git python3 timeout; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP: %s not installed — nothing was tested\n' "$tool"; exit 0; }
done
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { printf 'SKIP: bash %s < 4 — the watchdog refuses it; nothing was tested\n' "$BASH_VERSION"; exit 0; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
kv() { sed -n "s/^$2=//p" <<<"$1" | head -1; }
# A config key as JSON, or `absent`.
cfg_key() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d[sys.argv[2]]) if sys.argv[2] in d else "absent")' "$1" "$2"; }

# A repo whose src/a.ts changed on a branch, with a stand-in typescript package.
# $2 = with-api | without-api | none (no typescript package at all).
fixture() {
  local r="$TMP/$1" ts="$2"
  git init -q -b main "$r" && git -C "$r" config user.email t@t && git -C "$r" config user.name t \
    && git -C "$r" config commit.gpgsign false || return 1
  printf '{"name":"t","devDependencies":{"vitest":"^2.0.0"}}\n' > "$r/package.json"
  printf 'node_modules/\n' > "$r/.gitignore"
  mkdir -p "$r/src" && printf 'export const a = 1;\n' > "$r/src/a.ts" && printf 'import "./a";\n' > "$r/src/a.test.ts"
  printf 'export default {};\n' > "$r/vitest.config.ts"
  printf '{"compilerOptions":{}}\n' > "$r/tsconfig.json"  # so a sentinel that named a real file would be caught
  git -C "$r" add -A && git -C "$r" commit -qm init && git -C "$r" checkout -qb feature
  printf 'export const a = 2;\n' > "$r/src/a.ts" && git -C "$r" commit -qam change
  case "$ts" in
    none) ;;
    *) mkdir -p "$r/node_modules/typescript"
       printf '{"name":"typescript","version":"%s","main":"index.js"}\n' "$([ "$ts" = with-api ] && echo 5.6.3 || echo 7.0.0)" \
         > "$r/node_modules/typescript/package.json"
       if [ "$ts" = with-api ]; then
         printf 'module.exports = { version: "5.6.3", parseConfigFileTextToJson: () => ({}) };\n'
       else
         printf 'module.exports = { version: "7.0.0" };\n'
       fi > "$r/node_modules/typescript/index.js" ;;
  esac
}
scope() { (cd "$TMP/$1" && bash "$STRYKER" --diff main --runner vitest "${@:2}" 2>"$TMP/$1.err"); }

# ── 1. TypeScript without the preprocessor API: in place, preprocessor off, the watchdog told the files ──
fixture ts7 without-api || { bad "fixture ts7"; echo "SOME FAILED"; exit 1; }
out="$(scope ts7)"; rc=$?
cfg="$(kv "$out" config_path)"
list="$TMP/ts7/$(kv "$out" run_command | sed -n 's/.*--in-place-files \.\/\([^ ]*\).*/\1/p')"
if [ "$rc" -eq 0 ] && [ "$(cfg_key "$cfg" inPlace)" = true ] && [ "$(cfg_key "$cfg" tsconfigFile)" != absent ] \
   && [ ! -e "$TMP/ts7/$(cfg_key "$cfg" tsconfigFile | tr -d '"')" ] \
   && [ "$(kv "$out" in_place)" = true ] && [ "$(kv "$out" in_place_reason)" = "typescript 7.0.0 has no parseConfigFileTextToJson" ] \
   && [ "$(cat "$list" 2>/dev/null)" = "src/a.ts" ]; then
  pass "typescript 7 (no parseConfigFileTextToJson): inPlace true, tsconfigFile names a missing file, the watchdog gets the scoped file list"
else
  bad "typescript 7: rc=$rc inPlace=$(cfg_key "$cfg" inPlace) tsconfigFile=$(cfg_key "$cfg" tsconfigFile) in_place=$(kv "$out" in_place) reason=[$(kv "$out" in_place_reason)] list=[$(cat "$list" 2>/dev/null)] err=$(head -c 300 "$TMP/ts7.err")"
fi

# ── 2. TypeScript with the API, or none at all: the sandbox, untouched ──────────────────────────────
for kind in with-api none; do
  fixture "ok-$kind" "$kind" || { bad "fixture ok-$kind"; continue; }
  out="$(scope "ok-$kind")"; rc=$?; cfg="$(kv "$out" config_path)"
  if [ "$rc" -eq 0 ] && [ "$(cfg_key "$cfg" inPlace)" = absent ] && [ "$(cfg_key "$cfg" tsconfigFile)" = absent ] \
     && [ "$(kv "$out" in_place)" = false ] && [[ "$(kv "$out" run_command)" != *--in-place-files* ]]; then
    pass "typescript $kind: sandboxed as before (no inPlace, no tsconfigFile, no --in-place-files)"
  else
    bad "typescript $kind: rc=$rc inPlace=$(cfg_key "$cfg" inPlace) tsconfigFile=$(cfg_key "$cfg" tsconfigFile) in_place=$(kv "$out" in_place)"
  fi
done

# ── 2b. the TypeScript Stryker itself imports decides: core carries its own 7 next to a project 5 ───────
fixture core-ts7 with-api || bad "fixture core-ts7"
C="$TMP/core-ts7/node_modules/@stryker-mutator/core"; mkdir -p "$C/node_modules/typescript"
printf '{"name":"@stryker-mutator/core","version":"10.0.0"}\n' > "$C/package.json"
printf '{"name":"typescript","version":"7.0.0","main":"index.js"}\n' > "$C/node_modules/typescript/package.json"
printf 'module.exports = { version: "7.0.0" };\n' > "$C/node_modules/typescript/index.js"
out="$(scope core-ts7)"
[ "$(kv "$out" in_place)" = true ] && [ "$(kv "$out" in_place_reason)" = "typescript 7.0.0 has no parseConfigFileTextToJson" ] \
  && pass "the TypeScript resolved from @stryker-mutator/core decides, not the project's own 5" \
  || bad "core-ts7: in_place=$(kv "$out" in_place) reason=[$(kv "$out" in_place_reason)]"

# ── 3. the switches: --in-place on a healthy TypeScript keeps its preprocessor; --no-in-place wins ────
out="$(scope ok-with-api --in-place)"; cfg="$(kv "$out" config_path)"
[ "$(cfg_key "$cfg" inPlace)" = true ] && [ "$(cfg_key "$cfg" tsconfigFile)" = absent ] && [ "$(kv "$out" in_place_reason)" = "--in-place" ] \
  && pass "--in-place: in place, the working preprocessor left on" \
  || bad "--in-place: inPlace=$(cfg_key "$cfg" inPlace) tsconfigFile=$(cfg_key "$cfg" tsconfigFile) reason=[$(kv "$out" in_place_reason)]"
out="$(scope ts7 --in-place --no-in-place)"; rc=$?
[ "$rc" -eq 2 ] && grep -q 'contradict' "$TMP/ts7.err" && pass "--in-place with --no-in-place: usage error 2" \
  || bad "--in-place --no-in-place: rc=$rc err=[$(head -c 200 "$TMP/ts7.err")]"
out="$(scope ts7 --no-in-place)"; cfg="$(kv "$out" config_path)"
[ "$(cfg_key "$cfg" inPlace)" = absent ] && [ "$(kv "$out" in_place)" = false ] \
  && pass "--no-in-place: sandboxed even on typescript 7 (the caller's call)" \
  || bad "--no-in-place: inPlace=$(cfg_key "$cfg" inPlace) in_place=$(kv "$out" in_place)"

# ── 4. the watchdog puts back what a killed in-place run left instrumented — and nothing else ────────
W="$TMP/wd"; mkdir -p "$W"
printf 'export const a = 1;\n' > "$W/a.ts"; chmod 640 "$W/a.ts"
printf 'export const b = 1;\n' > "$W/b.ts"
printf 'a.ts\nb.ts\nmissing.ts\n' > "$W/list"
# The "run": instruments a.ts like Stryker does, edits b.ts by hand (no marker), then hangs without progress.
(cd "$W" && timeout -s KILL 40 bash "$WD" --idle-timeout 2 --in-place-files list -- \
  sh -c 'printf "function stryMutAct_9fa48(){}\n" >> a.ts; printf "export const b = 2;\n" > b.ts; echo started; sleep 30') \
  >"$TMP/wd.out" 2>"$TMP/wd.err"; rc=$?
if [ "$rc" -eq 124 ] && [ "$(cat "$W/a.ts")" = "export const a = 1;" ] && [ "$(stat -c %a "$W/a.ts" 2>/dev/null || stat -f %Lp "$W/a.ts")" = 640 ] \
   && grep -q 'restored a.ts' "$TMP/wd.err" && [ "$(cat "$W/b.ts")" = "export const b = 2;" ] && ! grep -q 'restored b.ts' "$TMP/wd.err" \
   && grep -q 'not backed up: missing.ts' "$TMP/wd.err"; then
  pass "killed in-place run: the instrumented file is restored with its mode and named; a hand edit without the marker is kept; a listed file that does not exist is named"
else
  bad "killed in-place run: rc=$rc a=[$(cat "$W/a.ts")] b=[$(cat "$W/b.ts")] err=[$(head -c 300 "$TMP/wd.err")]"
fi
# A run that restores its own files (a clean Stryker exit) leaves the watchdog nothing to do.
printf 'export const a = 1;\n' > "$W/a.ts"
(cd "$W" && timeout -s KILL 40 bash "$WD" --idle-timeout 5 --in-place-files list -- \
  sh -c 'cp a.ts a.bak; printf "function stryMutAct_9fa48(){}\n" >> a.ts; mv a.bak a.ts; echo done') >"$TMP/wd2.out" 2>"$TMP/wd2.err"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q restored "$TMP/wd2.err" && [ "$(cat "$W/a.ts")" = "export const a = 1;" ] \
  && pass "clean in-place run: exit 0, nothing restored, nothing said" \
  || bad "clean in-place run: rc=$rc err=[$(cat "$TMP/wd2.err")]"
printf 'export const c = 1;\nfunction stryMutAct_9fa48(){}\n' > "$W/c.ts"; printf 'c.ts\n' > "$W/list-c"
(cd "$W" && timeout -s KILL 20 bash "$WD" --in-place-files list-c -- true) >/dev/null 2>"$TMP/wd4.err"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'c.ts is instrumented already' "$TMP/wd4.err" \
  && pass "a listed file instrumented before the run (an earlier killed run): named, since this copy cannot restore it" \
  || bad "pre-instrumented file: rc=$rc err=[$(cat "$TMP/wd4.err")]"
(cd "$W" && timeout -s KILL 20 bash "$WD" --in-place-files nope -- true) >/dev/null 2>"$TMP/wd3.err"; rc=$?
[ "$rc" -eq 125 ] && grep -q -- '--in-place-files: no such readable file' "$TMP/wd3.err" \
  && pass "--in-place-files naming no file: usage error 125 before anything runs" \
  || bad "--in-place-files missing list: rc=$rc err=[$(cat "$TMP/wd3.err")]"

if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOME FAILED"; fi
exit "$fail"
