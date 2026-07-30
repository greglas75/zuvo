#!/usr/bin/env bash
# Task 3 — e2e-preflight helper. Covers the two subcommands:
#   probe            → exactly one of READY | GENERATE_ONLY | BOOTSTRAP_REQUIRED on stdout
#   coverage-upsert  → markdown-table registry row upsert keyed by flow id (atomic)
# Every probe scenario runs with a canary `npx` first on PATH: the helper must NEVER
# shell out to npx (that would silently install Playwright on a user's machine).
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/zuvo-home/e2e-preflight"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$HELPER" ] || bad "helper missing or not executable: $HELPER"

# ── npx canary: a stub that records any invocation ────────────────────────────
STUB="$TMP/stubbin"; mkdir -p "$STUB"
CANARY="$TMP/npx-canary"
cat > "$STUB/npx" <<EOF
#!/bin/sh
echo "npx invoked: \$*" >> "$CANARY"
exit 0
EOF
chmod +x "$STUB/npx"

probe() {  # probe <dir> <browsers-path> ; stdout captured, stderr → $TMP/err
  PATH="$STUB:$PATH" PLAYWRIGHT_BROWSERS_PATH="$2" bash "$HELPER" probe "$1" 2>"$TMP/err"
}

# ── (1) full fixture → READY ──────────────────────────────────────────────────
P_FULL="$TMP/p-full"
mkdir -p "$P_FULL/node_modules/@playwright/test" "$P_FULL/node_modules/.bin"
: > "$P_FULL/playwright.config.ts"
cat > "$P_FULL/node_modules/.bin/playwright" <<'EOF'
#!/bin/sh
echo "Version 1.55.0"
EOF
chmod +x "$P_FULL/node_modules/.bin/playwright"
BROWSERS="$TMP/browsers"; mkdir -p "$BROWSERS/chromium-1187"

out=$(probe "$P_FULL" "$BROWSERS"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "READY" ]; then
  pass "(1) full fixture → READY (exit 0)"
else
  bad "(1) expected READY/0, got '$out'/$rc"
fi

# ── (2) config + declared devDep, no node_modules → BOOTSTRAP_REQUIRED ────────
P_DECL="$TMP/p-declared"; mkdir -p "$P_DECL"
: > "$P_DECL/playwright.config.ts"
cat > "$P_DECL/package.json" <<'EOF'
{ "name": "x", "devDependencies": { "@playwright/test": "^1.55.0" } }
EOF
out=$(probe "$P_DECL" "$BROWSERS"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "BOOTSTRAP_REQUIRED" ]; then
  pass "(2) declared dep, no binary → BOOTSTRAP_REQUIRED (exit 0)"
else
  bad "(2) expected BOOTSTRAP_REQUIRED/0, got '$out'/$rc"
fi

# ── (3) empty dir → GENERATE_ONLY ─────────────────────────────────────────────
P_EMPTY="$TMP/p-empty"; mkdir -p "$P_EMPTY"
out=$(probe "$P_EMPTY" "$BROWSERS"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "GENERATE_ONLY" ]; then
  pass "(3) empty project → GENERATE_ONLY (exit 0)"
else
  bad "(3) expected GENERATE_ONLY/0, got '$out'/$rc"
fi

# ── (4) binary present, browser cache empty → GENERATE_ONLY + stderr reason ───
EMPTY_BROWSERS="$TMP/browsers-empty"; mkdir -p "$EMPTY_BROWSERS"
out=$(probe "$P_FULL" "$EMPTY_BROWSERS"); rc=$?
reason=$(cat "$TMP/err" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && [ "$out" = "GENERATE_ONLY" ] && [ -n "$reason" ]; then
  case "$reason" in
    *rowser*) pass "(4) empty browser cache → GENERATE_ONLY + reason on stderr" ;;
    *) bad "(4) stderr reason does not mention browsers: '$reason'" ;;
  esac
else
  bad "(4) expected GENERATE_ONLY/0 + stderr, got '$out'/$rc stderr='$reason'"
fi

# ── (4b) binary present but BROKEN (exits 1) → "not runnable" + non-READY ─────
P_BROKEN="$TMP/p-broken"
mkdir -p "$P_BROKEN/node_modules/@playwright/test" "$P_BROKEN/node_modules/.bin"
: > "$P_BROKEN/playwright.config.ts"
cat > "$P_BROKEN/node_modules/.bin/playwright" <<'EOF'
#!/bin/sh
echo "broken install" >&2
exit 1
EOF
chmod +x "$P_BROKEN/node_modules/.bin/playwright"
out=$(probe "$P_BROKEN" "$BROWSERS"); rc=$?
reason=$(cat "$TMP/err" 2>/dev/null || true)
ok=1
[ "$rc" -eq 0 ] || ok=0
[ "$out" = "BOOTSTRAP_REQUIRED" ] || ok=0
[ "$out" != "READY" ] || ok=0
case "$reason" in *"not runnable"*) ;; *) ok=0 ;; esac
if [ "$ok" -eq 1 ]; then
  pass "(4b) broken local binary → 'not runnable' on stderr + BOOTSTRAP_REQUIRED (never READY)"
else
  bad "(4b) expected BOOTSTRAP_REQUIRED/0 + 'not runnable' stderr, got '$out'/$rc stderr='$reason'"
fi

# ── (4c) negative-READY symmetry: runnable + browsers, but no config/dep/devDep ─
P_BARE="$TMP/p-bare"
mkdir -p "$P_BARE/node_modules/.bin"
cat > "$P_BARE/node_modules/.bin/playwright" <<'EOF'
#!/bin/sh
echo "Version 1.55.0"
EOF
chmod +x "$P_BARE/node_modules/.bin/playwright"
out=$(probe "$P_BARE" "$BROWSERS"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" != "READY" ] && [ "$out" = "GENERATE_ONLY" ]; then
  pass "(4c) runnable+browsers but no config/dep/devDep → GENERATE_ONLY, NOT READY"
else
  bad "(4c) expected GENERATE_ONLY/0 (not READY), got '$out'/$rc"
fi

# ── (4d) HANGING binary → bounded (~5s) and classified not-runnable ───────────
# A half-installed playwright can block forever on `--version`; the probe must
# never inherit that hang (macOS has no timeout(1), hence the poll+kill).
P_HANG="$TMP/p-hang"
mkdir -p "$P_HANG/node_modules/@playwright/test" "$P_HANG/node_modules/.bin"
: > "$P_HANG/playwright.config.ts"
cat > "$P_HANG/node_modules/.bin/playwright" <<'EOF'
#!/bin/sh
sleep 30
EOF
chmod +x "$P_HANG/node_modules/.bin/playwright"
# private TMPDIR: the cleanup assertion in (4d2) must observe ONLY this probe.
# Globbing the shared $TMPDIR made it race with any other process's probe.
PROBE_TMP="$TMP/probe-tmp"; mkdir -p "$PROBE_TMP"
t0=$(date +%s)
out=$(PATH="$STUB:$PATH" PLAYWRIGHT_BROWSERS_PATH="$BROWSERS" TMPDIR="$PROBE_TMP" \
      bash "$HELPER" probe "$P_HANG" 2>"$TMP/err"); rc=$?
t1=$(date +%s)
elapsed=$(( t1 - t0 ))
reason=$(cat "$TMP/err" 2>/dev/null || true)
ok=1
[ "$rc" -eq 0 ] || ok=0
[ "$out" = "BOOTSTRAP_REQUIRED" ] || ok=0
[ "$elapsed" -lt 15 ] || ok=0
case "$reason" in *"not runnable"*) ;; *) ok=0 ;; esac
if [ "$ok" -eq 1 ]; then
  pass "(4d) hanging playwright --version → killed in ${elapsed}s, BOOTSTRAP_REQUIRED, 'not runnable' on stderr"
else
  bad "(4d) expected BOOTSTRAP_REQUIRED/0 within ~5s, got '$out'/$rc after ${elapsed}s stderr='$reason'"
fi

# ── (4d2) …and the killed process tree leaves NO survivor behind ──────────────
# (the fixture path is passed through the environment so this probe of `ps`
#  cannot match its own command line)
sleep 1
export HANGPATH="$P_HANG"
survivors=$(ps -Ao command= 2>/dev/null | awk 'index($0, ENVIRON["HANGPATH"]) > 0 { n++ } END { print n+0 }')
strays=$(ls -a "$PROBE_TMP" 2>/dev/null | awk '$0 != "." && $0 != ".." { n++ } END { print n+0 }')
if [ "$survivors" = "0" ] && [ "$strays" = "0" ]; then
  pass "(4d2) timed-out probe leaves no surviving process and no stray temp dir"
else
  bad "(4d2) survivors=$survivors stray temp dirs=$strays"
fi

# ── (4d3) 3-DEEP hung process tree → every level dies ─────────────────────────
# Playwright is a node script that spawns helpers; killing only the backgrounded
# shell left the real workers running.  The recursive killer must also not clash
# with itself (its own pid/signal vars have to be function-local).
P_TREE="$TMP/p-tree"
mkdir -p "$P_TREE/node_modules/@playwright/test" "$P_TREE/node_modules/.bin"
: > "$P_TREE/playwright.config.ts"
TREEPIDS="$TMP/tree.pids"; : > "$TREEPIDS"
cat > "$P_TREE/l3" <<EOF
#!/bin/sh
echo \$\$ >> "$TREEPIDS"
sleep 45
EOF
cat > "$P_TREE/l2" <<EOF
#!/bin/sh
echo \$\$ >> "$TREEPIDS"
"$P_TREE/l3" &
sleep 45
EOF
cat > "$P_TREE/node_modules/.bin/playwright" <<EOF
#!/bin/sh
echo \$\$ >> "$TREEPIDS"
"$P_TREE/l2" &
sleep 45
EOF
chmod +x "$P_TREE/l3" "$P_TREE/l2" "$P_TREE/node_modules/.bin/playwright"
out=$(probe "$P_TREE" "$BROWSERS"); rc=$?
sleep 1
tree_recorded=$(awk 'END { print NR+0 }' "$TREEPIDS")
tree_alive=0
while read -r tp; do
  [ -n "$tp" ] || continue
  kill -0 "$tp" 2>/dev/null && tree_alive=$((tree_alive + 1))
done < "$TREEPIDS"
if [ "$rc" -eq 0 ] && [ "$out" = "BOOTSTRAP_REQUIRED" ] && [ "$tree_recorded" -ge 3 ] && [ "$tree_alive" -eq 0 ]; then
  pass "(4d3) 3-deep hung tree: all $tree_recorded levels killed, none survived"
else
  bad "(4d3) rc=$rc out='$out' recorded=$tree_recorded still-alive=$tree_alive (want 3+ recorded, 0 alive)"
fi

# ── (4d4) the timed-out child is REAPED, not left a zombie ────────────────────
tmo_body=$(awk '/^_playwright_version_rc\(\) \{/,/^\}/' "$HELPER")
tmo_tail=$(printf '%s\n' "$tmo_body" | awk '/_kill_tree .* KILL/,0')
case "$tmo_tail" in
  *wait*) pass "(4d4) timeout path waits on the background job (no zombie left)" ;;
  *) bad "(4d4) timeout path kills without waiting — the child stays a zombie" ;;
esac

# ── (4d5) private temp dir unavailable → exit 2, no invented fallback path ────
# (a guessable \$TMPDIR/e2e-preflight.\$\$ would be pre-creatable by anyone)
NOMKTEMP="$TMP/nomktemp"; mkdir -p "$NOMKTEMP"
cat > "$NOMKTEMP/mktemp" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$NOMKTEMP/mktemp"
out=$(PATH="$NOMKTEMP:$STUB:$PATH" PLAYWRIGHT_BROWSERS_PATH="$BROWSERS" bash "$HELPER" probe "$P_FULL" 2>"$TMP/err4d5"); rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ] && [ -s "$TMP/err4d5" ]; then
  pass "(4d5) mktemp -d failure → exit 2 with a reason, no stdout token, no guessable fallback"
else
  bad "(4d5) expected exit 2 + empty stdout, got '$out'/$rc err='$(cat "$TMP/err4d5")'"
fi

# ── (4h) RELATIVE \$PLAYWRIGHT_BROWSERS_PATH resolves against the PROBED dir ───
P_REL="$TMP/p-rel"
mkdir -p "$P_REL/node_modules/@playwright/test" "$P_REL/node_modules/.bin" "$P_REL/rel-browsers/chromium-1187"
: > "$P_REL/playwright.config.ts"
cp "$P_FULL/node_modules/.bin/playwright" "$P_REL/node_modules/.bin/playwright"
out=$(probe "$P_REL" "rel-browsers"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "READY" ]; then
  pass "(4h) relative PLAYWRIGHT_BROWSERS_PATH resolved against the probed project → READY"
else
  bad "(4h) expected READY/0 for a relative browsers path, got '$out'/$rc"
fi

# ── (4h2) …and NOT against the caller's cwd (decoy cache next to the caller) ──
P_REL2="$TMP/p-rel-nobrowsers"
mkdir -p "$P_REL2/node_modules/@playwright/test" "$P_REL2/node_modules/.bin"
: > "$P_REL2/playwright.config.ts"
cp "$P_FULL/node_modules/.bin/playwright" "$P_REL2/node_modules/.bin/playwright"
DECOY="$TMP/decoy"; mkdir -p "$DECOY/rel-browsers/chromium-1187"
out=$(cd "$DECOY" && PATH="$STUB:$PATH" PLAYWRIGHT_BROWSERS_PATH="rel-browsers" bash "$HELPER" probe "$P_REL2" 2>"$TMP/err4h2"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "GENERATE_ONLY" ]; then
  pass "(4h2) relative browsers path is NOT resolved against the caller cwd (decoy ignored)"
else
  bad "(4h2) expected GENERATE_ONLY/0 (decoy cache must not count), got '$out'/$rc"
fi

# ── (4e) devDep detection is scoped to dependency maps, not the whole file ────
P_MENTION="$TMP/p-mention"; mkdir -p "$P_MENTION"
cat > "$P_MENTION/package.json" <<'EOF'
{
  "name": "x",
  "description": "utilities that pair well with \"@playwright/test\" fixtures",
  "scripts": { "note": "echo see \"@playwright/test\" docs" },
  "dependencies": { "left-pad": "^1.0.0" }
}
EOF
out=$(probe "$P_MENTION" "$BROWSERS"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "GENERATE_ONLY" ]; then
  pass "(4e) '@playwright/test' only in a description/script string → NOT counted as declared"
else
  bad "(4e) expected GENERATE_ONLY/0 (substring match must not count), got '$out'/$rc"
fi

# ── (4e2) real devDependencies entry IS still detected ────────────────────────
out=$(probe "$P_DECL" "$BROWSERS"); rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "BOOTSTRAP_REQUIRED" ]; then
  pass "(4e2) genuine devDependencies entry still detected after scoping"
else
  bad "(4e2) expected BOOTSTRAP_REQUIRED/0, got '$out'/$rc"
fi

# ── (4f) nonexistent path → exit 2 + stderr, NO state token on stdout ─────────
out=$(probe "$TMP/does-not-exist-at-all" "$BROWSERS"); rc=$?
reason=$(cat "$TMP/err" 2>/dev/null || true)
if [ "$rc" -eq 2 ] && [ -z "$out" ] && [ -n "$reason" ]; then
  pass "(4f) probe on a nonexistent path → exit 2, empty stdout, reason on stderr"
else
  bad "(4f) expected exit 2 + empty stdout, got '$out'/$rc stderr='$reason'"
fi

# ── (4g) path that is a FILE, not a directory → exit 2 ────────────────────────
: > "$TMP/not-a-dir"
out=$(probe "$TMP/not-a-dir" "$BROWSERS"); rc=$?
reason=$(cat "$TMP/err" 2>/dev/null || true)
if [ "$rc" -eq 2 ] && [ -z "$out" ] && [ -n "$reason" ]; then
  pass "(4g) probe on a non-directory → exit 2, empty stdout, reason on stderr"
else
  bad "(4g) expected exit 2 + empty stdout, got '$out'/$rc stderr='$reason'"
fi

# ── (5) npx canary: helper never shells out to npx ────────────────────────────
if [ ! -e "$CANARY" ]; then
  pass "(5) npx never invoked across all probe scenarios"
else
  bad "(5) helper shelled out to npx: $(cat "$CANARY")"
fi

# ── (6) unknown subcommand → usage on stderr + exit 2 ─────────────────────────
out=$(bash "$HELPER" bogus-subcommand 2>"$TMP/err6"); rc=$?
u6=$(cat "$TMP/err6" 2>/dev/null || true)
if [ "$rc" -eq 2 ] && [ -n "$u6" ]; then
  pass "(6) unknown subcommand → usage + exit 2"
else
  bad "(6) expected exit 2 + stderr usage, got '$out'/$rc stderr='$u6'"
fi

# ── (6b) -h/--help → help text on STDOUT, nothing on stderr, exit 0 ───────────
h_out=$(bash "$HELPER" -h 2>"$TMP/err6b"); rc=$?
h_err=$(cat "$TMP/err6b" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && [ -n "$h_out" ] && [ ! -s "$TMP/err6b" ]; then
  pass "(6b) -h → non-empty stdout, empty stderr, exit 0"
else
  bad "(6b) expected help on stdout/exit 0/empty stderr, got rc=$rc stdout='$h_out' stderr='$h_err'"
fi

# ── coverage-upsert ───────────────────────────────────────────────────────────
REGDIR="$TMP/reg"; mkdir -p "$REGDIR"
R1="$REGDIR/e2e-coverage.md"

row_count() { awk -F'|' -v f="$2" 'NF>2 { c=$2; gsub(/^[ \t]+|[ \t]+$/,"",c); if (c==f) n++ } END { print n+0 }' "$1"; }
row_for()   { awk -F'|' -v f="$2" 'NF>2 { c=$2; gsub(/^[ \t]+|[ \t]+$/,"",c); if (c==f) { print; exit } }' "$1"; }
header_of() { awk '/^[[:space:]]*\|/ && /Flow ID/ { print; exit }' "$1"; }

# (7) absent registry → created with State column + row
bash "$HELPER" coverage-upsert --file "$R1" --flow login --state GENERATED \
  --spec e2e/login.spec.ts --score 8 --confidence high >/dev/null 2>"$TMP/err7"; rc=$?
hdr=$(header_of "$R1" 2>/dev/null || true)
if [ "$rc" -eq 0 ] && [ -f "$R1" ] && [ "$(row_count "$R1" login)" = "1" ]; then
  case "$hdr" in
    *State*) pass "(7) absent registry → created, header has State, row present" ;;
    *) bad "(7) created header lacks State column: '$hdr'" ;;
  esac
else
  bad "(7) create failed rc=$rc rows=$(row_count "$R1" login 2>/dev/null) err=$(cat "$TMP/err7")"
fi

# (7b) a value containing BACKSLASHES round-trips verbatim (awk -v would eat it:
#      `e2e\flows\login.spec.ts` → formfeed + "lows..."; ENVIRON[] must not).
R_BS="$REGDIR/backslash.md"
BSPEC='e2e\flows\login.spec.ts'
bash "$HELPER" coverage-upsert --file "$R_BS" --flow winflow --state GENERATED \
  --spec "$BSPEC" >/dev/null 2>"$TMP/err7b"; rc=$?
hit=$(BS="$BSPEC" awk 'index($0, ENVIRON["BS"]) > 0 { n++ } END { print n+0 }' "$R_BS" 2>/dev/null || echo 0)
if [ "$rc" -eq 0 ] && [ "$hit" = "1" ]; then
  pass "(7b) backslash-bearing --spec written VERBATIM (no awk -v escape processing)"
else
  bad "(7b) backslash spec mangled: rc=$rc hits=$hit row='$(row_for "$R_BS" winflow 2>/dev/null)'"
fi

# (8) same flow, new state → still exactly one row, new state written
bash "$HELPER" coverage-upsert --file "$R1" --flow login --state VERIFIED_LOCAL >/dev/null 2>&1; rc=$?
r=$(row_for "$R1" login)
if [ "$rc" -eq 0 ] && [ "$(row_count "$R1" login)" = "1" ]; then
  case "$r" in
    *VERIFIED_LOCAL*) pass "(8) re-upsert same flow → one row, state updated" ;;
    *) bad "(8) state not updated: '$r'" ;;
  esac
else
  bad "(8) re-upsert produced $(row_count "$R1" login) rows (rc=$rc)"
fi

# (9) different flow → appended, both rows present
bash "$HELPER" coverage-upsert --file "$R1" --flow checkout --state BLOCKED >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(row_count "$R1" login)" = "1" ] && [ "$(row_count "$R1" checkout)" = "1" ]; then
  pass "(9) second flow appended, both rows present"
else
  bad "(9) expected login+checkout rows, got login=$(row_count "$R1" login) checkout=$(row_count "$R1" checkout) rc=$rc"
fi

# (10) malformed registry → exit 2, file byte-identical
R_BAD="$REGDIR/bad.md"
cat > "$R_BAD" <<'EOF'
Some prose that is definitely not a markdown table.
Another line without any pipes at all.
EOF
cp "$R_BAD" "$TMP/bad.orig"
bash "$HELPER" coverage-upsert --file "$R_BAD" --flow login --state GENERATED >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && cmp -s "$R_BAD" "$TMP/bad.orig"; then
  pass "(10) malformed registry → exit 2, file unmodified"
else
  bad "(10) expected exit 2 + unmodified, got rc=$rc (diff: $(cmp "$R_BAD" "$TMP/bad.orig" 2>&1))"
fi

# (10b) header present but NO separator row → exit 2, file byte-identical
R_NOSEP="$REGDIR/nosep.md"
cat > "$R_NOSEP" <<'EOF'
# E2E Coverage Registry

| Flow ID | Name | Score | Confidence | Status | Spec File | Last Updated | State |
| signup | Sign up | 7 | high | GENERATED | e2e/signup.spec.ts | 2026-07-01 | GENERATED |
EOF
cp "$R_NOSEP" "$TMP/nosep.orig"
bash "$HELPER" coverage-upsert --file "$R_NOSEP" --flow login --state GENERATED >/dev/null 2>"$TMP/err10b"; rc=$?
if [ "$rc" -eq 2 ] && cmp -s "$R_NOSEP" "$TMP/nosep.orig" && [ -s "$TMP/err10b" ]; then
  pass "(10b) header without separator row → exit 2, file unmodified"
else
  bad "(10b) expected exit 2 + unmodified, got rc=$rc (diff: $(cmp "$R_NOSEP" "$TMP/nosep.orig" 2>&1))"
fi

# (10c) a real table but with NO Flow ID column → exit 2, file byte-identical
# (the previous fixture here was `|Flow ID` + `|---|`, asserted to be "column-less".
#  That was the `split() - 2` off-by-one: it is a valid 1-column table — see (10d).)
R_NOCOL="$REGDIR/nocol.md"
printf '| Name | Score |\n|------|-------|\n| login | 7 |\n' > "$R_NOCOL"
cp "$R_NOCOL" "$TMP/nocol.orig"
bash "$HELPER" coverage-upsert --file "$R_NOCOL" --flow login --state GENERATED >/dev/null 2>"$TMP/err10c"; rc=$?
if [ "$rc" -eq 2 ] && cmp -s "$R_NOCOL" "$TMP/nocol.orig" && [ -s "$TMP/err10c" ]; then
  pass "(10c) table without a Flow ID column → exit 2, file unmodified"
else
  bad "(10c) expected exit 2 + unmodified, got rc=$rc err='$(cat "$TMP/err10c")'"
fi

# (10d) header WITHOUT a trailing pipe (valid markdown) → column count is right,
#       so the existing row is updated in place instead of mis-indexed/appended
R_NOTRAIL="$REGDIR/no-trailing-pipe.md"
printf '| Flow ID | Name | State\n|---------|------|------\n| login | Login page | GENERATED\n' > "$R_NOTRAIL"
bash "$HELPER" coverage-upsert --file "$R_NOTRAIL" --flow login --state FAILED >/dev/null 2>"$TMP/err10d"; rc=$?
nt_rows=$(row_count "$R_NOTRAIL" login)
nt_row=$(row_for "$R_NOTRAIL" login)
ok=1
[ "$rc" -eq 0 ] || ok=0
[ "$nt_rows" = "1" ] || ok=0
case "$nt_row" in *FAILED*) ;; *) ok=0 ;; esac
case "$nt_row" in *"Login page"*) ;; *) ok=0 ;; esac
if [ "$ok" -eq 1 ]; then
  pass "(10d) header without a trailing pipe → correct column count, in-place update"
else
  bad "(10d) expected 1 updated row, got rows=$nt_rows rc=$rc row='$nt_row' err='$(cat "$TMP/err10d")'"
fi

# (10e) --file that exists but is a DIRECTORY → exit 2 before any write
R_DIRPATH="$REGDIR/registry-as-dir.md"
mkdir -p "$R_DIRPATH"
bash "$HELPER" coverage-upsert --file "$R_DIRPATH" --flow login --state GENERATED >/dev/null 2>"$TMP/err10e"; rc=$?
inside=$(ls -A "$R_DIRPATH" 2>/dev/null | awk 'END{print NR+0}')
if [ "$rc" -eq 2 ] && [ -s "$TMP/err10e" ] && [ -d "$R_DIRPATH" ] && [ "$inside" = "0" ]; then
  pass "(10e) --file is a directory → exit 2, nothing moved inside it"
else
  bad "(10e) expected exit 2 + empty dir, got rc=$rc entries=$inside err='$(cat "$TMP/err10e")'"
fi

# (10e2) --file is a SYMLINK → exit 2, the symlink and its target are untouched
R_TARGET="$REGDIR/symlink-target.md"
R_LINK="$REGDIR/symlink.md"
bash "$HELPER" coverage-upsert --file "$R_TARGET" --flow seed --state GENERATED >/dev/null 2>&1
cp "$R_TARGET" "$TMP/symlink-target.orig"
ln -sf "$R_TARGET" "$R_LINK"
bash "$HELPER" coverage-upsert --file "$R_LINK" --flow login --state GENERATED >/dev/null 2>"$TMP/err10e2"; rc=$?
if [ "$rc" -eq 2 ] && [ -s "$TMP/err10e2" ] && [ -L "$R_LINK" ] && cmp -s "$R_TARGET" "$TMP/symlink-target.orig"; then
  pass "(10e2) --file is a symlink → exit 2, never written through, target unchanged"
else
  bad "(10e2) expected exit 2 + untouched target, got rc=$rc err='$(cat "$TMP/err10e2")'"
fi

# (10e3) the non-regular-path check is ALSO made under the lock (TOCTOU): the
#        pre-lock check can be overtaken between the two, and `_upsert_locked`
#        deciding on `[ ! -f ]` alone would mv the temp file INTO a directory.
locked_body=$(awk '/^_upsert_locked\(\) \{/,/^\}/' "$HELPER")
case "$locked_body" in
  *_registry_path_ok*) pass "(10e3) _upsert_locked re-validates the registry path under the lock" ;;
  *) bad "(10e3) _upsert_locked does not re-check the path — pre-lock check alone is a TOCTOU gap" ;;
esac

# (10e4) work files are unpredictable and cleaned up (a guessable `$file.tmp.$$`
#        next to the registry could be pre-planted as a symlink)
R_TMPCHK="$REGDIR/tmpcheck.md"
bash "$HELPER" coverage-upsert --file "$R_TMPCHK" --flow one --state GENERATED >/dev/null 2>&1
bash "$HELPER" coverage-upsert --file "$R_TMPCHK" --flow two --state GENERATED >/dev/null 2>&1
bash "$HELPER" coverage-upsert --file "$R_NOCOL" --flow x --state GENERATED >/dev/null 2>&1   # exit-2 path
residue=$(ls -a "$REGDIR" 2>/dev/null | awk '/\.tmp\.[0-9]+$|^\.e2e-cov\./ { n++ } END { print n+0 }')
if [ "$residue" = "0" ]; then
  pass "(10e4) no predictable/leftover work files in the registry directory"
else
  bad "(10e4) $residue work file(s) left behind: $(ls -a "$REGDIR" | awk '/\.tmp\.[0-9]+$|^\.e2e-cov\./')"
fi

# (10e5) the registry's mode survives the atomic replace (mktemp gives 0600)
R_MODE="$REGDIR/mode.md"
bash "$HELPER" coverage-upsert --file "$R_MODE" --flow one --state GENERATED >/dev/null 2>&1
mode_fresh=$(stat -f %Lp "$R_MODE" 2>/dev/null || stat -c %a "$R_MODE" 2>/dev/null)
chmod 640 "$R_MODE"
bash "$HELPER" coverage-upsert --file "$R_MODE" --flow two --state GENERATED >/dev/null 2>&1
mode_after=$(stat -f %Lp "$R_MODE" 2>/dev/null || stat -c %a "$R_MODE" 2>/dev/null)
if [ "$mode_after" = "640" ] && [ "$mode_fresh" != "600" ]; then
  pass "(10e5) registry mode preserved across the replace (fresh=$mode_fresh, kept=$mode_after)"
else
  bad "(10e5) mode wrong: fresh=$mode_fresh (must not be 600) after-chmod-640=$mode_after (want 640)"
fi

# (10f) the coverage table ENDS at the first non-pipe line: prose and a second,
#       unrelated table after it must be left byte-identical
R_MULTI="$REGDIR/multi-table.md"
cat > "$R_MULTI" <<'EOF'
# E2E Coverage Registry

| Flow ID | Name | State |
|---------|------|-------|
| login | Login | GENERATED |

Notes: the table below is an unrelated appendix, not coverage data.

| Flow ID | Meaning |
|---------|---------|
| login | must NOT be touched by the upsert |
EOF
awk 'NR > 5' "$R_MULTI" > "$TMP/multi.tail.orig"
bash "$HELPER" coverage-upsert --file "$R_MULTI" --flow login --state FAILED >/dev/null 2>"$TMP/err10f"; rc=$?
awk 'NR > 5' "$R_MULTI" > "$TMP/multi.tail.new"
first_row=$(awk 'NR == 5' "$R_MULTI")
ok=1
[ "$rc" -eq 0 ] || ok=0
cmp -s "$TMP/multi.tail.orig" "$TMP/multi.tail.new" || ok=0
case "$first_row" in *FAILED*) ;; *) ok=0 ;; esac
[ "$(awk 'END{print NR}' "$R_MULTI")" = "11" ] || ok=0     # no row appended anywhere
if [ "$ok" -eq 1 ]; then
  pass "(10f) prose + second table after the coverage table left byte-identical, only row 5 updated"
else
  bad "(10f) rc=$rc row5='$first_row' lines=$(awk 'END{print NR}' "$R_MULTI") tail-diff: $(cmp "$TMP/multi.tail.orig" "$TMP/multi.tail.new" 2>&1)"
fi

# (10g) CRLF registry (Git Bash / Windows edit) → row matched in place, no
#       duplicate, and the file keeps its CRLF line endings
R_CRLF="$REGDIR/crlf.md"
printf '# E2E Coverage Registry\r\n\r\n| Flow ID | Name | State |\r\n|---------|------|-------|\r\n| login | Login | GENERATED |\r\n' > "$R_CRLF"
bash "$HELPER" coverage-upsert --file "$R_CRLF" --flow login --state FAILED >/dev/null 2>"$TMP/err10g"; rc=$?
crlf_rows=$(row_count "$R_CRLF" login)
crlf_lines=$(awk 'END{print NR}' "$R_CRLF")
crlf_cr=$(awk '/\r$/{n++} END{print n+0}' "$R_CRLF")
crlf_row=$(row_for "$R_CRLF" login)
ok=1
[ "$rc" -eq 0 ] || ok=0
[ "$crlf_rows" = "1" ] || ok=0
[ "$crlf_lines" = "5" ] || ok=0
[ "$crlf_cr" = "$crlf_lines" ] || ok=0
case "$crlf_row" in *FAILED*) ;; *) ok=0 ;; esac
if [ "$ok" -eq 1 ]; then
  pass "(10g) CRLF registry → matched in place (no duplicate) and every line still ends CRLF"
else
  bad "(10g) rc=$rc rows=$crlf_rows lines=$crlf_lines cr=$crlf_cr row='$crlf_row'"
fi

# (11) legacy-header migration (once), legacy rows preserved byte-for-byte
R_LEG="$REGDIR/legacy.md"
cat > "$R_LEG" <<'EOF'
# E2E Coverage Registry

| Flow ID | Name | Score | Confidence | Status | Spec File | Last Updated |
|---------|------|-------|------------|--------|-----------|--------------|
| signup | Sign up | 7 | high | GENERATED | e2e/signup.spec.ts | 2026-07-01 |
| search | Search | 5 | medium | PLANNED | e2e/search.spec.ts | 2026-07-02 |
EOF
LEG_ROW1='| signup | Sign up | 7 | high | GENERATED | e2e/signup.spec.ts | 2026-07-01 |'
LEG_ROW2='| search | Search | 5 | medium | PLANNED | e2e/search.spec.ts | 2026-07-02 |'
# After migration the header gains a column, so every legacy row is padded with
# ONE trailing placeholder cell — content preserved verbatim, table still valid.
LEG_ROW1_MIG="$LEG_ROW1 - |"
LEG_ROW2_MIG="$LEG_ROW2 - |"
bash "$HELPER" coverage-upsert --file "$R_LEG" --flow login --state VALIDATED_LIVE >/dev/null 2>&1; rc=$?
hdr1=$(header_of "$R_LEG")
keep1=$(awk -v r="$LEG_ROW1_MIG" '$0==r{n++} END{print n+0}' "$R_LEG")
keep2=$(awk -v r="$LEG_ROW2_MIG" '$0==r{n++} END{print n+0}' "$R_LEG")
ok=1
[ "$rc" -eq 0 ] || ok=0
case "$hdr1" in *State*) ;; *) ok=0 ;; esac
[ "$keep1" = "1" ] && [ "$keep2" = "1" ] || ok=0
[ "$(row_count "$R_LEG" login)" = "1" ] || ok=0
if [ "$ok" -eq 1 ]; then
  pass "(11a) legacy header migrated, legacy row content preserved + padded, new row added"
else
  bad "(11a) migration wrong: rc=$rc hdr='$hdr1' keep=$keep1/$keep2 login=$(row_count "$R_LEG" login)"
fi

bash "$HELPER" coverage-upsert --file "$R_LEG" --flow login --state FAILED >/dev/null 2>&1
hdr2=$(header_of "$R_LEG")
mig2=0
case "$hdr2" in *State*) mig2=1 ;; esac
if [ "$hdr1" = "$hdr2" ] && [ "$mig2" -eq 1 ]; then
  pass "(11b) second upsert does not rewrite the header again"
else
  bad "(11b) header rewritten twice: '$hdr1' → '$hdr2'"
fi

# (11c) legacy header with DIFFERENTLY-NAMED columns: names are preserved
#       verbatim (never relabelled to the canonical set) and every data row ends
#       up with the same cell count as the header.
R_LEG2="$REGDIR/legacy-names.md"
cat > "$R_LEG2" <<'EOF'
# E2E Coverage Registry

| Flow ID | Title | Score | Confidence | Status | Spec | Updated |
|---------|-------|-------|------------|--------|------|---------|
| signup | Sign up | 7 | high | GENERATED | e2e/signup.spec.ts | 2026-07-01 |
| search | Search | 5 | medium | PLANNED | e2e/search.spec.ts | 2026-07-02 |
EOF
bash "$HELPER" coverage-upsert --file "$R_LEG2" --flow login --state GENERATED >/dev/null 2>"$TMP/err11c"; rc=$?
hdr3=$(header_of "$R_LEG2")
# every pipe row (except the separator) must have the header's cell count
mismatch=$(awk -F'|' '
  /^[[:space:]]*\|/ {
    if ($0 ~ /^[[:space:]]*\|[-: |]+\|[[:space:]]*$/) next
    if (h == 0) { h = NF; next }
    if (NF != h) n++
  }
  END { print n+0 }' "$R_LEG2")
ok=1
[ "$rc" -eq 0 ] || ok=0
case "$hdr3" in *"| Title |"*) ;; *) ok=0 ;; esac
case "$hdr3" in *"| Updated |"*) ;; *) ok=0 ;; esac
case "$hdr3" in *Name*) ok=0 ;; esac          # must NOT be relabelled to the canonical names
case "$hdr3" in *"Last Updated"*) ok=0 ;; esac
case "$hdr3" in *"| State |"*) ;; *) ok=0 ;; esac
[ "$mismatch" = "0" ] || ok=0
[ "$(row_count "$R_LEG2" login)" = "1" ] || ok=0
if [ "$ok" -eq 1 ]; then
  pass "(11c) legacy column names preserved verbatim, State appended, all rows padded to header width"
else
  bad "(11c) migration relabelled or left ragged rows: rc=$rc hdr='$hdr3' ragged=$mismatch login=$(row_count "$R_LEG2" login)"
fi

# (11d) reordered header: Flow ID is NOT the first data column → the match must
#       use the resolved header index, not a hardcoded column 2.
R_REORD="$REGDIR/reordered.md"
cat > "$R_REORD" <<'EOF'
# E2E Coverage Registry

| Name | Flow ID | State | Score |
|------|---------|-------|-------|
| Login page | login | GENERATED | 7 |
| Checkout | checkout | GENERATED | 4 |
EOF
bash "$HELPER" coverage-upsert --file "$R_REORD" --flow login --state FAILED >/dev/null 2>"$TMP/err11d"; rc=$?
reord_count=$(awk -F'|' 'NF>2 { c=$3; gsub(/^[ \t]+|[ \t]+$/,"",c); if (c=="login") n++ } END { print n+0 }' "$R_REORD")
reord_row=$(awk -F'|' 'NF>2 { c=$3; gsub(/^[ \t]+|[ \t]+$/,"",c); if (c=="login") { print; exit } }' "$R_REORD")
ok=1
[ "$rc" -eq 0 ] || ok=0
[ "$reord_count" = "1" ] || ok=0
case "$reord_row" in *FAILED*) ;; *) ok=0 ;; esac
case "$reord_row" in *"Login page"*) ;; *) ok=0 ;; esac
if [ "$ok" -eq 1 ]; then
  pass "(11d) Flow ID outside column 1 → row updated in place (no duplicate appended)"
else
  bad "(11d) expected 1 in-place update, got rows=$reord_count rc=$rc row='$reord_row'"
fi

# (11e) pre-existing DUPLICATE rows for one flow id collapse to a single row
R_DUP="$REGDIR/dupes.md"
cat > "$R_DUP" <<'EOF'
# E2E Coverage Registry

| Flow ID | Name | State |
|---------|------|-------|
| dup | first | GENERATED |
| other | keep me | GENERATED |
| dup | second | GENERATED |
EOF
bash "$HELPER" coverage-upsert --file "$R_DUP" --flow dup --state FAILED >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ "$(row_count "$R_DUP" dup)" = "1" ] && [ "$(row_count "$R_DUP" other)" = "1" ]; then
  pass "(11e) duplicate rows for one flow id collapse to exactly one, other rows untouched"
else
  bad "(11e) expected dup=1 other=1, got dup=$(row_count "$R_DUP" dup) other=$(row_count "$R_DUP" other) rc=$rc"
fi

# (11f) input validation — CR / LF / TAB / '|' / non-numeric score are rejected
#       BEFORE the registry is opened and BEFORE the lock is taken.
R_VAL="$REGDIR/validate.md"
bash "$HELPER" coverage-upsert --file "$R_VAL" --flow seed --state GENERATED >/dev/null 2>&1
cp "$R_VAL" "$TMP/validate.orig"
VAL_LOCK="$REGDIR/.validate.md.lock.d"

val_reject() {  # val_reject <label> <args...>
  _vr_label="$1"; shift
  bash "$HELPER" coverage-upsert "$@" >/dev/null 2>"$TMP/errval"; _vr_rc=$?
  if [ "$_vr_rc" -eq 2 ] && cmp -s "$R_VAL" "$TMP/validate.orig" && [ -s "$TMP/errval" ] && [ ! -d "$VAL_LOCK" ]; then
    pass "$_vr_label"
  else
    bad "$_vr_label — rc=$_vr_rc lock_dir=$([ -d "$VAL_LOCK" ] && echo yes || echo no) err='$(cat "$TMP/errval" 2>/dev/null)'"
  fi
}

val_reject "(11f1) --flow containing a newline → exit 2, registry unmodified, no lock dir" \
  --file "$R_VAL" --flow "$(printf 'a\nb')" --state GENERATED
val_reject "(11f2) --spec containing a carriage return → exit 2, registry unmodified" \
  --file "$R_VAL" --flow seed --state GENERATED --spec "$(printf 'e2e/a.spec.ts\r')"
val_reject "(11f3) --confidence containing a tab → exit 2, registry unmodified" \
  --file "$R_VAL" --flow seed --state GENERATED --confidence "$(printf 'hi\tgh')"
val_reject "(11f4) --score 'abc' (non-numeric) → exit 2, registry unmodified" \
  --file "$R_VAL" --flow seed --state GENERATED --score abc
val_reject "(11f5) --flow containing '|' → exit 2 (never silently rewritten to '/')" \
  --file "$R_VAL" --flow 'a|b' --state GENERATED
val_reject "(11f6) whitespace-only --flow → exit 2 (would normalize to an empty key)" \
  --file "$R_VAL" --flow '   ' --state GENERATED
val_reject "(11f7) tab-only --flow → exit 2" \
  --file "$R_VAL" --flow "$(printf '\t')" --state GENERATED
# every cell value is treated alike — '|' is rejected, never silently rewritten
val_reject "(11f8) --spec containing '|' → exit 2 (not quietly rewritten to '/')" \
  --file "$R_VAL" --flow seed --state GENERATED --spec 'e2e/a|b.spec.ts'
val_reject "(11f9) --confidence containing '|' → exit 2" \
  --file "$R_VAL" --flow seed --state GENERATED --confidence 'hi|gh'

# (11g) a legal flow id at the edge of the validation set round-trips and
#       updates IN PLACE on the second upsert (one normalized value, one row).
EDGE_FLOW='auth/login-2fa (eu)'
bash "$HELPER" coverage-upsert --file "$R_VAL" --flow "$EDGE_FLOW" --state GENERATED >/dev/null 2>&1
bash "$HELPER" coverage-upsert --file "$R_VAL" --flow "$EDGE_FLOW" --state FAILED >/dev/null 2>&1; rc=$?
edge_rows=$(row_count "$R_VAL" "$EDGE_FLOW")
edge_row=$(row_for "$R_VAL" "$EDGE_FLOW")
if [ "$rc" -eq 0 ] && [ "$edge_rows" = "1" ]; then
  case "$edge_row" in
    *FAILED*) pass "(11g) punctuation-bearing flow id round-trips and updates in place (single row)" ;;
    *) bad "(11g) state not updated for '$EDGE_FLOW': '$edge_row'" ;;
  esac
else
  bad "(11g) expected exactly 1 row for '$EDGE_FLOW', got $edge_rows (rc=$rc)"
fi

# (12) state enum round-trip + rejection of an unknown state
R_ENUM="$REGDIR/enum.md"
enum_ok=1
for s in GENERATED STATIC_CHECKED VERIFIED_LOCAL VALIDATED_LIVE BLOCKED FAILED; do
  bash "$HELPER" coverage-upsert --file "$R_ENUM" --flow enum --state "$s" >/dev/null 2>&1 || enum_ok=0
  r=$(row_for "$R_ENUM" enum)
  case "$r" in *"$s"*) ;; *) enum_ok=0; bad "(12) state $s not written verbatim: '$r'" ;; esac
done
[ "$enum_ok" -eq 1 ] && pass "(12a) every valid state accepted and written verbatim"

cp "$R_ENUM" "$TMP/enum.orig"
bash "$HELPER" coverage-upsert --file "$R_ENUM" --flow enum --state BOGUS >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && cmp -s "$R_ENUM" "$TMP/enum.orig"; then
  pass "(12b) --state BOGUS → exit 2, file unmodified"
else
  bad "(12b) expected exit 2 + unmodified, got rc=$rc"
fi

# (13) unknown flag → usage + exit 2
bash "$HELPER" coverage-upsert --file "$R_ENUM" --flow enum --state FAILED --nope 1 >/dev/null 2>"$TMP/err13"; rc=$?
if [ "$rc" -eq 2 ] && [ -s "$TMP/err13" ]; then
  pass "(13) unknown flag → usage + exit 2"
else
  bad "(13) expected exit 2 + stderr, got rc=$rc"
fi

# (13b/c/d) each required flag omitted → usage on stderr + exit 2
bash "$HELPER" coverage-upsert --flow enum --state FAILED >/dev/null 2>"$TMP/err13b"; rc=$?
if [ "$rc" -eq 2 ] && [ -s "$TMP/err13b" ]; then
  pass "(13b) missing --file → usage on stderr + exit 2"
else
  bad "(13b) expected exit 2 + stderr, got rc=$rc err='$(cat "$TMP/err13b" 2>/dev/null)'"
fi

R_REQ="$REGDIR/required.md"
bash "$HELPER" coverage-upsert --file "$R_REQ" --state FAILED >/dev/null 2>"$TMP/err13c"; rc=$?
if [ "$rc" -eq 2 ] && [ -s "$TMP/err13c" ] && [ ! -f "$R_REQ" ]; then
  pass "(13c) missing --flow → usage on stderr + exit 2, no registry created"
else
  bad "(13c) expected exit 2 + stderr + no file, got rc=$rc err='$(cat "$TMP/err13c" 2>/dev/null)'"
fi

bash "$HELPER" coverage-upsert --file "$R_REQ" --flow enum >/dev/null 2>"$TMP/err13d"; rc=$?
if [ "$rc" -eq 2 ] && [ -s "$TMP/err13d" ] && [ ! -f "$R_REQ" ]; then
  pass "(13d) missing --state → usage on stderr + exit 2, no registry created"
else
  bad "(13d) expected exit 2 + stderr + no file, got rc=$rc err='$(cat "$TMP/err13d" 2>/dev/null)'"
fi

# (13e) DETERMINISTIC: the signal handler reports the truth on both sides of the
#       atomic mv.  The old trap was `_lock_release; exit 2` unconditionally, so
#       a TERM landing after the write reported failure for a completed upsert.
sig_src=$(awk '/^_upsert_on_signal\(\) \{/,/^\}/' "$HELPER")
if [ -n "$sig_src" ]; then
  ( eval "$sig_src"; _lock_release() { :; }; UPSERT_DONE=1; _upsert_on_signal ) >/dev/null 2>&1
  rc_done=$?
  ( eval "$sig_src"; _lock_release() { :; }; UPSERT_DONE=0; _upsert_on_signal ) >/dev/null 2>&1
  rc_pending=$?
  if [ "$rc_done" -eq 0 ] && [ "$rc_pending" -eq 2 ]; then
    pass "(13e) signal handler: write landed → exit 0, write not landed → exit 2"
  else
    bad "(13e) handler decision wrong: done→$rc_done (want 0), pending→$rc_pending (want 2)"
  fi
else
  bad "(13e) could not extract _upsert_on_signal from $HELPER"
fi

# (13f) END-TO-END property: a real TERM during a real upsert must never yield
#       "exit 2 + row present" (nor "exit 0 + row absent").  The delay grid is
#       CALIBRATED against a measured upsert, otherwise every sample lands long
#       before the write and the probe is vacuous (measured: ~250ms per upsert,
#       so the original fixed 1-25ms grid never reached the window at all).
R_CAL="$REGDIR/calibrate.md"
cal_t0=$(date +%s)
for i in 1 2 3 4 5 6; do
  bash "$HELPER" coverage-upsert --file "$R_CAL" --flow cal --state GENERATED >/dev/null 2>&1
done
cal_t1=$(date +%s)
SIG_D=$(awk -v s=$(( cal_t1 - cal_t0 )) 'BEGIN { d = s / 6; if (d < 0.02) d = 0.02; printf "%.3f", d }')
sig_violation=""; sig_runs=0; sig_landed=0
for f in 0.5 0.7 0.85 0.95 1.05 1.25; do
  d=$(awk -v D="$SIG_D" -v f="$f" 'BEGIN { printf "%.3f", D * f }')
  R_SIG="$REGDIR/sig-$f.md"
  bash "$HELPER" coverage-upsert --file "$R_SIG" --flow seed --state GENERATED >/dev/null 2>&1
  bash "$HELPER" coverage-upsert --file "$R_SIG" --flow victim --state VERIFIED_LOCAL >/dev/null 2>&1 &
  sig_pid=$!
  sleep "$d"
  kill -TERM "$sig_pid" 2>/dev/null
  wait "$sig_pid" 2>/dev/null; sig_rc=$?
  sig_runs=$((sig_runs + 1))
  sig_rows=$(row_count "$R_SIG" victim 2>/dev/null || echo 0)
  [ "$sig_rows" != "0" ] && sig_landed=$((sig_landed + 1))
  if [ "$sig_rc" -eq 2 ] && [ "$sig_rows" != "0" ]; then
    sig_violation="$sig_violation [delay=$d rc=2 but row PRESENT]"
  fi
  if [ "$sig_rc" -eq 0 ] && [ "$sig_rows" = "0" ]; then
    sig_violation="$sig_violation [delay=$d rc=0 but row MISSING]"
  fi
done
if [ -z "$sig_violation" ] && [ "$sig_runs" -eq 6 ]; then
  pass "(13f) TERM during upsert: status never contradicts the registry ($sig_runs samples around ${SIG_D}s, $sig_landed writes landed)"
else
  bad "(13f) signal handler lied:$sig_violation"
fi

# (14) write-lock is released on EVERY exit path — no lock dirs left behind
leftover=""
for d in "$REGDIR"/*.lock.d "$REGDIR"/.*.lock.d; do
  [ -d "$d" ] && leftover="$leftover $d"
done
leftover="${leftover# }"
if [ -z "$leftover" ]; then
  pass "(14) no leftover lock dirs after ok + exit-2 upserts"
else
  bad "(14) leftover lock dirs: $leftover"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
