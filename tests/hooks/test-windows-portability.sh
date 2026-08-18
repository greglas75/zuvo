#!/usr/bin/env bash
# test-windows-portability.sh — Windows (Git Bash) is a supported target; these are the four
# things that silently break there. Each assertion below corresponds to a failure REPRODUCED on
# this repo before it was fixed, not to a hypothetical.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0; ok(){ printf '  ✓ %s\n' "$1"; }; bad(){ printf '  ✗ %s\n' "$1"; fail=$((fail+1)); }

echo "=== 1. line endings: a CRLF checkout makes every script a syntax error ==="
# Reproduced: converting zuvo-collector-host.sh to CRLF yields
#   syntax error near unexpected token `{'
# Git for Windows defaults to core.autocrlf=true, so without .gitattributes this is the state
# EVERY Windows clone starts in — including the git hooks, i.e. the quality gates.
[ -f "$ROOT/.gitattributes" ] && ok ".gitattributes exists" || bad ".gitattributes missing — Windows clones get CRLF scripts"
grep -qE '^\* text=auto eol=lf' "$ROOT/.gitattributes" 2>/dev/null \
  && ok "repo-wide LF normalisation declared" || bad "no repo-wide eol=lf rule"
for pat in '\*\.sh' '\*\.py' 'hooks/\*' 'scripts/zuvo-home/\*'; do
  # ${pat} braces are load-bearing: `$pat[` reads as an array subscript (SC1087) — a lint error and
  # a genuine ambiguity for a human. (Note: a comment line whose FIRST word is the linter's name is
  # parsed as a directive and errors as SC1073 — which is exactly what the first draft of this
  # comment did, and what the sibling fix in test-install-wiring.sh was about.)
  grep -qE "^${pat}[[:space:]]+text eol=lf" "$ROOT/.gitattributes" 2>/dev/null \
    && ok "explicit LF rule for $pat" || bad "no explicit LF rule for $pat"
done
# Plain batch keeps CRLF, but the POLYGLOT must stay LF: bash reads it on every hook invocation
# on macOS/Linux and does not tolerate CRLF (reproduced — "line 37: : command not found"). An
# earlier draft pinned *.cmd wholesale to CRLF and would have broken every hook on macOS.
grep -qE '^\*\.cmd[[:space:]]+text eol=crlf' "$ROOT/.gitattributes" 2>/dev/null \
  && ok "*.cmd pinned to CRLF (cmd.exe requirement)" || bad "*.cmd not pinned to CRLF"
grep -qE '^hooks/run-hook\.cmd[[:space:]]+text eol=lf' "$ROOT/.gitattributes" 2>/dev/null \
  && ok "run-hook.cmd exempted back to LF (bash reads it on every hook)" \
  || bad "run-hook.cmd would ship CRLF — that breaks every hook on macOS/Linux"
# The batch half must stay single-line, or it would need CRLF again.
if awk '/^BATCH_GUARD$/{exit} /^(if|where)/{ if ($0 ~ /\($/) bad=1 } END{exit bad?1:0}' "$ROOT/hooks/run-hook.cmd"; then
  ok "batch conditionals are single-line (LF-safe for cmd.exe)"
else
  bad "run-hook.cmd has a multi-line ( block — that reintroduces the CRLF requirement"
fi
# And bash must actually be able to run it.
_rt="$(mktemp -d)"; cp "$ROOT/hooks/run-hook.cmd" "$_rt/"
printf '#!/usr/bin/env bash\necho RUNHOOK_OK\n' > "$_rt/probe.sh"
out=$(bash "$_rt/run-hook.cmd" probe.sh 2>&1)
[ "$out" = "RUNHOOK_OK" ] && ok "bash executes the polyglot and reaches the hook" \
                          || bad "polyglot broken under bash: $out"
rm -rf "$_rt"
# And the tree must actually be clean under those rules.
if command -v git >/dev/null 2>&1; then
  dirty=$(cd "$ROOT" && git ls-files --eol 2>/dev/null | awk '$1=="i/crlf" && $3!="attr/-text"' | wc -l | tr -d ' ')
  [ "${dirty:-0}" = "0" ] && ok "no unintended CRLF blobs in the index" \
                          || bad "$dirty file(s) stored CRLF without an explicit -text pin"
fi

echo "=== 2. hooks: bash may not be on PATH, only run-hook.cmd can find it ==="
# `bash "…/x.sh"` needs bash on PATH; Git for Windows' "Git Bash only" install does not add it.
# run-hook.cmd probes C:\Program Files\Git\bin\bash.exe. Before this, 10 of 11 hooks bypassed it.
if command -v jq >/dev/null 2>&1; then
  direct=$(jq -r '[.hooks[][] | .hooks[] | .command | select(startswith("bash "))] | length' "$ROOT/hooks/hooks.json")
  [ "$direct" = "0" ] && ok "no Claude hook calls bash directly" \
                      || bad "$direct hook(s) assume bash on PATH"
else
  bad "jq missing — cannot verify hook wiring"
fi

echo "=== 3. sed -i '': BSD-only, dies on GNU/busybox ==="
# Verified: `sed -i '' 's/a/b/' f` on debian/alpine → "No such file or directory", exit 1.
# Two of the 22 sites were swallowed by `|| true`, so install.sh would report success while
# leaving {plugin_root} unsubstituted.
# Count CODE only. The fix's own comments explain what was removed and name the old pattern —
# a whole-file grep flags those and reports a fix as unfixed (the false-positive class this repo
# keeps hitting). `grep -v '^\s*#'` is not enough either: a trailing comment on a code line is
# fine, so anchor on the line STARTING with the command.
n=$(cd "$ROOT" && git grep -n "sed -i ''" -- scripts 2>/dev/null \
    | awk -F: '{ $1=""; $2=""; sub(/^  /,""); if ($0 !~ /^[[:space:]]*#/) print }' | wc -l | tr -d ' ')
[ "${n:-0}" = "0" ] && ok "no BSD-only sed -i '' in scripts/ code (comments excluded)" \
                    || bad "$n code line(s) still use the BSD-only sed -i ''"
[ -f "$ROOT/scripts/lib/portable.sh" ] && ok "scripts/lib/portable.sh present" || bad "portable.sh missing"

# sed_i must behave: edit, clean its backup, and RESTORE the file when sed fails.
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/portable.sh"
T="$(mktemp -d)"
printf 'aaa\n' > "$T/f"
sed_i 's/a/b/' "$T/f" >/dev/null 2>&1
[ "$(cat "$T/f")" = "baa" ] && ok "sed_i edits in place" || bad "sed_i did not edit"
[ ! -f "$T/f.zbak" ] && ok "sed_i removes its backup on success" || bad "sed_i left a .zbak behind"
printf 'original\n' > "$T/g"
sed_i 's/[/' "$T/g" >/dev/null 2>&1
[ "$(cat "$T/g")" = "original" ] && ok "sed_i restores the file when sed fails" \
                                 || bad "sed_i left a half-written file: $(cat "$T/g")"
sed_i 's/a/b/' "$T/does-not-exist" >/dev/null 2>&1
[ "$?" = "2" ] && ok "sed_i rejects a missing file (exit 2)" || bad "sed_i did not reject a missing file"

echo "=== 4. python3 is not a command on Windows ==="
# python.org installs `python` and `py`; Git Bash ships neither. 83 bare `python3` calls existed
# with zero fallbacks, including /usr/bin/python3 (an absolute path absent on Windows entirely).
m=$(cd "$ROOT" && git grep -n '/usr/bin/python3' -- scripts hooks 2>/dev/null \
    | awk -F: '{ $1=""; $2=""; sub(/^  /,""); if ($0 !~ /^[[:space:]]*#/) print }' | wc -l | tr -d ' ')
[ "${m:-0}" = "0" ] && ok "no hardcoded /usr/bin/python3 in code (comments excluded)" \
                    || bad "$m code line(s) hardcode /usr/bin/python3 (absent on Windows)"
# The resolver must find a 3.x interpreter under a PATH that has `python` but no `python3`.
PB="$T/bin"; mkdir -p "$PB"
real="$(command -v python3 || command -v python)"
ln -sf "$real" "$PB/python"
STUB="$T/stub"; mkdir -p "$STUB"
for b in sh bash env sed grep cat printf uname; do
  p="$(command -v $b 2>/dev/null)" && ln -sf "$p" "$STUB/$b" 2>/dev/null
done
got=$(PATH="$PB:$STUB" bash -c '. '"$ROOT"'/scripts/lib/portable.sh; zuvo_python' 2>/dev/null)
[ "$got" = "python" ] && ok "zuvo_python falls back to \`python\` when python3 is absent" \
                      || bad "zuvo_python returned '$got' with only \`python\` on PATH"
if PATH="$STUB" bash -c '. '"$ROOT"'/scripts/lib/portable.sh; zuvo_python' >/dev/null 2>&1; then
  bad "zuvo_python succeeded with no interpreter at all"
else
  ok "zuvo_python fails loudly when no Python 3 exists"
fi
# Every runtime script that uses $PY_BIN must actually define it.
for f in "$ROOT"/scripts/zuvo-home/*.sh; do
  grep -q 'PY_BIN' "$f" 2>/dev/null || continue
  grep -q 'zuvo_python' "$f" 2>/dev/null \
    && ok "$(basename "$f") resolves PY_BIN before use" \
    || bad "$(basename "$f") uses \$PY_BIN without resolving it"
done
# Shebangs: `#!/usr/bin/env python3` dies on Windows the same way (verified:
# "env: python3: No such file or directory"), and a shell function cannot be put in a shebang.
# Every Python helper therefore carries a sh/python polyglot header that re-execs with whatever
# Python 3 exists. Skills invoke these directly (compute-preload 19x, verify-audit 6x), so a
# shebang that only resolves python3 is a runtime failure, not a developer inconvenience.
echo "  -- python helpers must not depend on a literal python3 shebang --"
for f in "$ROOT"/scripts/zuvo-home/*; do
  [ -f "$f" ] || continue
  head -1 "$f" | grep -q '^#!.*python3$' || continue
  bad "$(basename "$f") still has a bare python3 shebang"
done
poly=$(grep -l 'command -v python3 || command -v python' "$ROOT"/scripts/zuvo-home/* 2>/dev/null | wc -l | tr -d ' ')
[ "${poly:-0}" -ge 10 ] && ok "$poly Python helpers carry the polyglot header" \
                        || bad "only $poly helper(s) carry the polyglot header (expected >=10)"

# The header must work in all three invocation modes AND with python3 absent.
PB2="$T/pybin"; mkdir -p "$PB2"; ln -sf "$real" "$PB2/python"
probe="$T/probe-poly"
# Take everything up to and including the exec line, located by NUMBER. Matching it by pattern
# needs four literal quotes inside nested shell quoting; a wrong count silently matches nothing
# and copies the WHOLE helper into the probe, which then fails for unrelated reasons and reads
# as "polyglot broken" — a false negative that cost a debugging round here.
hdr_end=$(grep -n 'exec "$(command -v python3' "$ROOT/scripts/zuvo-home/verify-audit" | head -1 | cut -d: -f1)
{ head -n "${hdr_end:-8}" "$ROOT/scripts/zuvo-home/verify-audit"
  printf 'import sys\nprint("POLY_OK")\n'; } > "$probe"
chmod +x "$probe"
[ "$(bash "$probe" 2>&1)" = "POLY_OK" ] && ok "polyglot runs under sh" || bad "polyglot broken under sh"
[ "$(PATH="$PB2:$STUB" "$probe" 2>&1)" = "POLY_OK" ] \
  && ok "polyglot runs with NO python3 on PATH" \
  || bad "polyglot fails when python3 is absent — the whole point of the header"
# And every converted helper must still be valid Python.
for f in "$ROOT"/scripts/zuvo-home/*; do
  [ -f "$f" ] || continue
  grep -q 'command -v python3 || command -v python' "$f" 2>/dev/null || continue
  "$real" -c "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$f" 2>/dev/null \
    || bad "$(basename "$f") no longer parses as Python"
done
ok "all polyglot helpers still parse as Python"

rm -rf "$T"

echo "=== RESULT ==="; [ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fail FAILED"; exit 1; }
