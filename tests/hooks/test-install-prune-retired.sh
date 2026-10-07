#!/usr/bin/env bash
# The installer removes what a release no longer ships (scripts/install.d/copy.sh: prune_absent,
# prune_retired_skills). Before it, the Claude cache and ~/.codex/skills only ever gained files:
# zuvo:survey-translation-qa left the repo on 2026-09-18 (89612afa) and its copy — with its stqa*.py
# scripts — kept loading beside the live skill in tgm-utilities until it was deleted by hand on
# 2026-10-06. Medium unit test: temporary filesystem only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
# shellcheck disable=SC1090
. "$ROOT/scripts/install.sh" >"$TMP/source.out" 2>&1 || exit 1

PASS=0; FAIL=0
t_ok() { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
t_no() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
skill() { mkdir -p "$1/$2"; printf -- '---\nname: %s\n---\n\n%s\n' "$2" "$3" > "$1/$2/SKILL.md"; }

# ── prune_absent: a destination zuvo alone writes ────────────────────────────────────────────────
SRC="$TMP/repo"; DST="$TMP/cache"
skill "$SRC/skills" build "# zuvo:build -- Scoped feature development"
skill "$DST/skills" build "# zuvo:build -- an older copy"
skill "$DST/skills" survey-translation-qa "# zuvo:survey-translation-qa"
mkdir -p "$SRC/scripts" "$DST/scripts"
printf 'x\n' > "$SRC/scripts/adversarial-review.sh"; printf 'old\n' > "$DST/scripts/adversarial-review.sh"
printf 'x\n' > "$DST/scripts/stqa.sh"; printf 'x\n' > "$DST/scripts/stqa_checks.py"
mkdir -p "$DST/scripts/lib"                       # a directory is not a file: kind f leaves it
OUTSIDE="$TMP/outside"; mkdir -p "$OUTSIDE/keep"; printf 'x\n' > "$OUTSIDE/keep/data"
ln -s "$OUTSIDE/keep" "$DST/skills/linked"        # a symlinked directory is never followed

out="$(prune_absent skills "$SRC/skills" "$DST/skills" d)"
if [ ! -e "$DST/skills/survey-translation-qa" ] && [ -f "$DST/skills/build/SKILL.md" ]; then
  t_ok "a retired skill directory goes, a shipped one stays"
else t_no "skills after prune: $(ls "$DST/skills" | tr '\n' ' ')"; fi
if [ -L "$DST/skills/linked" ] && [ -f "$OUTSIDE/keep/data" ]; then
  t_ok "a symlinked directory is neither followed nor removed"
else t_no "the symlinked directory or its target was touched"; fi
[[ "$out" == *"pruned 1 retired skills"* ]] && t_ok "the prune is reported" || t_no "no report: [$out]"

prune_absent scripts "$SRC/scripts" "$DST/scripts" f >/dev/null
if [ ! -e "$DST/scripts/stqa.sh" ] && [ ! -e "$DST/scripts/stqa_checks.py" ] \
   && [ -f "$DST/scripts/adversarial-review.sh" ] && [ -d "$DST/scripts/lib" ]; then
  t_ok "retired scripts go; shipped scripts and subdirectories stay"
else t_no "scripts after prune: $(ls "$DST/scripts" | tr '\n' ' ')"; fi

EMPTY="$TMP/empty"; mkdir -p "$EMPTY"
prune_absent skills "$EMPTY" "$DST/skills" d >/dev/null
prune_absent skills "$TMP/no-such-dir" "$DST/skills" d >/dev/null
if [ -f "$DST/skills/build/SKILL.md" ]; then
  t_ok "an empty or missing source prunes nothing (a broken checkout must not empty the cache)"
else t_no "an empty source emptied the destination"; fi

rc=0; prune_absent skills "$SRC/skills" "$TMP/no-such-dst" d >/dev/null || rc=$?
[ "$rc" -eq 0 ] && t_ok "a missing destination is not an error" || t_no "missing destination returned $rc"

# ── prune_retired_skills: ~/.codex/skills, shared with the user and other packages ───────────────
CX="$HOME/.codex/skills"; DIST="$TMP/dist/skills"
skill "$DIST" build "# zuvo:build -- Scoped feature development"
skill "$CX" build "# zuvo:build -- an older copy"
skill "$CX" survey-translation-qa "# zuvo:survey-translation-qa"
skill "$CX" content-optimize "# zuvo:content-optimize -- renamed long ago"
skill "$CX" my-own-skill "# My own skill"
skill "$CX" zuvo-notes "# zuvo:zuvo-notes-extra"            # a prefix of another name is not a match
skill "$CX" tgm-survey "# tgm-utilities:survey-translation-qa"  # same skill, another package

out="$(prune_retired_skills "$CX" "$DIST" "$CX")"
if [ ! -e "$CX/survey-translation-qa" ] && [ ! -e "$CX/content-optimize" ]; then
  t_ok "zuvo skills the release no longer ships are pruned from the shared directory"
else t_no "retired zuvo skills survived: $(ls "$CX" | tr '\n' ' ')"; fi
if [ -f "$CX/build/SKILL.md" ] && [ -f "$CX/my-own-skill/SKILL.md" ] && [ -f "$CX/zuvo-notes/SKILL.md" ] \
   && [ -f "$CX/tgm-survey/SKILL.md" ]; then
  t_ok "shipped skills and everyone else's skills are left alone"
else t_no "a skill that is not a retired zuvo skill was removed: $(ls "$CX" | tr '\n' ' ')"; fi
[[ "$out" == *"pruned 2 retired zuvo skill(s)"* ]] && t_ok "the shared-dir prune is reported" || t_no "no report: [$out]"

rm -rf "$DIST"; mkdir -p "$DIST"
skill "$CX" another-retired "# zuvo:another-retired"
prune_retired_skills "$CX" "$DIST" "$CX" >/dev/null
[ -d "$CX/build" ] && [ -d "$CX/another-retired" ] \
  && t_ok "an empty build prunes nothing from the shared directory" \
  || t_no "an empty dist pruned the shared directory"

# ── guards: symlinked destination, partial source, a heading that is not the first ───────────────
LINKED="$TMP/linked-cache"; ln -s "$DST/skills" "$LINKED"
skill "$DST/skills" retired-x "# zuvo:retired-x"
prune_absent skills "$SRC/skills" "$LINKED" d >/dev/null
[ -d "$DST/skills/retired-x" ] && t_ok "a symlinked destination is refused, nothing behind it removed" \
  || t_no "pruning went through a symlinked destination"
rm -rf "$DST/skills/retired-x"

BIG="$TMP/big"; for s in keep one two three four five; do skill "$BIG" "$s" "# zuvo:$s"; done
ONLY="$TMP/only"; skill "$ONLY" keep "# zuvo:keep"
out="$(prune_absent skills "$ONLY" "$BIG" d 2>&1)"
if [ -d "$BIG/five" ] && [[ "$out" == *"partial source"* ]]; then
  t_ok "removing most of the destination is refused as a partial source"
else t_no "a partial source pruned the destination: $(ls "$BIG" | tr '\n' ' ') [$out]"; fi

skill "$CX" late-heading "# My notes
# zuvo:late-heading"
skill "$CX" "a.b" "# zuvo:aXb"
mkdir -p "$TMP/dist/skills2/build"
prune_retired_skills "$CX" "$TMP/dist/skills2" "$CX" >/dev/null 2>&1
if [ -d "$CX/late-heading" ] && [ -d "$CX/a.b" ]; then
  t_ok "only a FIRST heading reading exactly # zuvo:<name> marks a skill as zuvo's (no pattern from a dir name)"
else t_no "a non-zuvo skill was removed: $(ls "$CX" | tr '\n' ' ')"; fi

# ── wiring: the copies that only add are followed by a prune ─────────────────────────────────────
CL="$ROOT/scripts/install.d/claude.sh"; CO="$ROOT/scripts/install.d/codex.sh"
p_line="$(grep -n 'prune_absent "skills"' "$CL" | head -1 | cut -d: -f1)"
c_line="$(grep -n 'cp_warn "skills/\$skill_name"' "$CL" | head -1 | cut -d: -f1)"
if [ -n "$p_line" ] && [ -n "$c_line" ] && [ "$p_line" -gt "$c_line" ]; then
  t_ok "install_claude prunes the cache only after it has copied the skills"
else t_no "install_claude: prune not after the skill copy (prune line ${p_line:-none}, copy line ${c_line:-none})"; fi
missing=""
for tree in scripts scripts/lib scripts/install.d rules shared/includes bin; do
  grep -q "prune_absent \"$tree\"" "$CL" || missing="$missing $tree"
done
[ -z "$missing" ] && t_ok "install_claude prunes scripts, scripts/lib, scripts/install.d, rules, shared/includes and bin" \
  || t_no "install_claude does not prune:$missing"
pc="$(grep -n 'prune_retired_skills "\$HOME/.codex/skills"' "$CO" | cut -d: -f1)"
cc="$(grep -n 'cp -r "\$DIST"/skills/\* "\$HOME/.codex/skills/"' "$CO" | head -1 | cut -d: -f1)"
if [ -n "$pc" ] && [ -n "$cc" ] && [ "$pc" -gt "$cc" ] && grep -q 'prune_absent "Codex plugin-cache skills"' "$CO"; then
  t_ok "install_codex prunes ~/.codex/skills (after its copy) and the Codex plugin cache"
else t_no "install_codex is missing a prune or prunes before copying (prune ${pc:-none}, copy ${cc:-none})"; fi

printf '  --- install prune retired: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
