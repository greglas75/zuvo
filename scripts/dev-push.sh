#!/bin/bash
# One command to rule them all: version bump + commit + push + tag + marketplace + install
#
# Usage:
#   ./scripts/dev-push.sh "description"           # patch bump (default)
#   ./scripts/dev-push.sh "description" minor      # minor bump
#   ./scripts/dev-push.sh                          # patch bump, auto-message
#
# What it does (in order):
#   1. Bump version in package.json, plugin.json files, using-zuvo banner
#   2. Stage all + commit
#   3. Push to origin + tag
#   4. Update marketplace SHA + push marketplace
#   5. Update local installed_plugins.json SHA
#   6. Install to Claude Code + Codex + Cursor + Antigravity + Kimi Code
#      (all five via scripts/install.sh's `all` target — this script never enumerates
#      them itself, so a new build target is picked up without editing this file)
#
# After running: just restart Claude Code.

set -euo pipefail

ZUVO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Portable primitives (sed_i, zuvo_python) — Windows/Git-Bash is a supported target and
# the BSD-only `sed -i ''` it replaces breaks there. See scripts/lib/portable.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/portable.sh"

MARKETPLACE_DIR="${ZUVO_DIR}/../zuvo-marketplace"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; exit 1; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }

# --- Args ---
MSG="${1:-}"
BUMP="${2:-patch}"

# Validate marketplace exists
if [[ ! -d "$MARKETPLACE_DIR/.claude-plugin" ]]; then
  fail "Marketplace repo not found at $MARKETPLACE_DIR"
fi

# >>> zuvo:test-gate  (Step 0: run the aggregate suite before ANY mutation)
if [[ "${ZUVO_SKIP_TESTS:-}" != "1" ]]; then
  bash "$ZUVO_DIR/tests/run-all.sh" || fail "Tests failed — fix or ZUVO_SKIP_TESTS=1 to bypass (logged)"
  ok "Step 0: test suite green"
else
  warn "Step 0 SKIPPED (ZUVO_SKIP_TESTS=1)"
fi
# <<< zuvo:test-gate

# CRASH SAFETY (B-devpush-marketplace-dirty-tree). This rewrites a SIBLING repo, and the commit
# that carries it only happens at Step 4 — after the tag push. Any failure or Ctrl-C in between
# used to leave the marketplace tree dirty, and Step 0b's `git pull --rebase` above is now
# deliberately fail-CLOSED, so the NEXT run dead-ends on that dirt and needs hand recovery. In a
# repo this script advertises as self-healing, that is the worst possible resting state.
#
# Only the files WE rewrote are restored, and only when the tree was clean before we touched it.
# If the user already had local marketplace edits, restoring would destroy them — so in that case
# the trap deliberately does nothing and says so. `git checkout --` is irreversible; it is only
# safe here because both conditions above bound it to changes this script itself just made.
MKT_WAS_CLEAN=0
[ -z "$(git -C "$MARKETPLACE_DIR" status --porcelain 2>/dev/null)" ] && MKT_WAS_CLEAN=1
MKT_REWROTE=0
_mkt_restore() {
  _rc=$?
  # rc=0 means the script finished; Step 4 disarms on the success path, so reaching here with 0
  # and the flag still set means an early clean exit that never committed. Reverting then would
  # be right, but reverting on a SUCCESSFUL full run would silently undo a published count — so
  # the status is checked explicitly rather than inferred from the flag alone.
  [ "$MKT_REWROTE" -eq 1 ] || return 0
  [ "$_rc" -ne 0 ] || { warn "clean exit before Step 4 with the rewrite uncommitted — reverting $MARKETPLACE_DIR"; }
  if [ "$MKT_WAS_CLEAN" -ne 1 ]; then
    warn "marketplace tree had pre-existing local changes — leaving it untouched (restore by hand if needed)"
    return 0
  fi
  git -C "$MARKETPLACE_DIR" checkout -- .claude-plugin/marketplace.json README.md 2>/dev/null \
    && warn "run ended rc=$_rc before Step 4 — reverted the marketplace count rewrite so the next run starts clean" \
    || warn "run ended rc=$_rc before Step 4 — could NOT revert $MARKETPLACE_DIR; check it by hand"
}
trap _mkt_restore EXIT INT TERM

# >>> zuvo:marketplace-count  (Step 0b: rewrite + verify the sibling marketplace's skill count)
# The marketplace is a SEPARATE repo, so scripts/validate-skills.sh — which knows
# only this repo's count locations — structurally cannot see its "<N> skills"
# strings. They rotted unnoticed: .claude-plugin/marketplace.json said 51 and
# README.md said 49 while the real count was 57. Both are user-visible product
# metadata on the marketplace listing.
#
# WHY HERE (before Step 1, after the Step-0 suite): Step 4 runs AFTER
# `git push origin main` + `git push --tags`, so a `fail` there would leave an
# irrecoverable half-shipped release. It sits just after the test gate rather
# than at the marketplace-dir check above so that the Step-0 "no mutation before
# a green suite" invariant still holds — this block writes to the sibling repo.
#
# WHY IT REWRITES INSTEAD OF ASSERTING: a mismatch-only pre-flight would dead-end
# on the real 51/49 — Step 4 would never run, nothing would ever be rewritten, and
# dev-push.sh would be unusable until someone hand-edited the marketplace. Step
# 4's existing `git add -A` + commit + push carries this rewrite; no new commit or
# push path is introduced here.
#
# WHY THE PULL IS HERE, NOT ONLY IN STEP 4: Step 4's own `git pull --rebase`
# runs BEFORE its `git add -A`, so on a self-heal run the marketplace tree is
# already dirty by then and that rebase is deterministically refused — silently,
# via its `|| true` — leaving the unprotected `git push --quiet` to hard-fail a
# release whose tag is already pushed. Pulling here, on a still-clean tree, makes
# Step 4's pull a harmless no-op.
#
# WHY THAT PULL FAILS CLOSED (no `|| true`): Step 4 can tolerate a refused pull
# because all it then does is substitute a SHA it computed itself. This block is
# different in kind — it rewrites CONTENT from a value computed in another repo,
# and Step 4 afterwards commits and pushes whatever it produced. On a failed pull
# (offline, diverged, rebase in progress) the rewrite would land on a stale base
# and Step 4 would publish it over the remote, clobbering it. A blocked release
# is strictly better than a published wrong count, so an unsynced checkout is
# never mutated. Positioned before the tag push, so failing here cannot half-ship.
#
# python3, not sed: `sed` exits 0 whether or not it substituted, so a renamed key
# or a moved string would silently no-op (precedent: Step 5 below,
# validate-skills.sh). The pattern is deliberately narrow — the adjacent
# "26 specialized agents" and the plugin-level "category": "development" key must
# stay byte-identical. Not best-effort (`&& ok … || warn …` like Step 5): a
# missing installed_plugins.json must not fail a release, but stale user-visible
# metadata in a repo this script already treats as mandatory is not in that class.
git -C "$MARKETPLACE_DIR" pull --rebase --quiet \
  || fail "Could not sync $MARKETPLACE_DIR (git pull --rebase failed — offline, diverged, or a rebase in progress). Sync that repo by hand, then re-run. Refusing to rewrite an unsynced checkout: Step 4 would commit and push that stale base over the remote."
MKT_SKILL_COUNT="$(bash "$ZUVO_DIR/scripts/validate-skills.sh" --print-count)" \
  || fail "Could not read the skill count — run: bash scripts/validate-skills.sh --print-count"
case "$MKT_SKILL_COUNT" in
  ''|*[!0-9]*)
    fail "validate-skills.sh --print-count returned '${MKT_SKILL_COUNT}' (not an integer) — refusing to rewrite $MARKETPLACE_DIR" ;;
  0*)
    # `057` and `0` are digit-only but not canonical counts; writing either into
    # user-visible metadata is a silent corruption, so reject rather than coerce.
    fail "validate-skills.sh --print-count returned '${MKT_SKILL_COUNT}' (zero or a leading zero — not a canonical count) — refusing to rewrite $MARKETPLACE_DIR" ;;
esac
# The python source is read into a variable and passed with `-c`, NOT written as
# `$(python3 - <<'PY' … PY)`. Bash scans the body of a command substitution for
# quote characters even inside a QUOTED heredoc, so one apostrophe in a python
# comment there breaks the parse of this entire script. `read` sits outside any
# substitution, so the body is opaque to the parser and future edits are safe.
# (`read -d ''` exits 1 at EOF when no NUL is found — hence the `|| true`.)
IFS= read -r -d '' MKT_COUNT_PY <<'PY' || true
import os
import re
import stat
import sys
import tempfile

root, want = sys.argv[1], sys.argv[2]

# EXPLICIT ALLOWLIST, not a recursive walk. A walk over the whole marketplace
# tree rewrote far more than the two metadata strings it exists to fix: it
# descended into every doc (a historical changelog line such as "grew from 49
# skills" becomes history corruption), could follow a symlink out of the repo, and
# treated an unreadable file as "nothing to rewrite" — letting a stale survivor
# hide behind a read error. These two files are the ONLY ones that carry the
# count; if the marketplace ever renames them the release must STOP, not
# quietly publish a stale number, so a missing entry is a hard failure below.
ALLOWLIST = ('.claude-plugin/marketplace.json', 'README.md')

# "<digits> skills" ONLY — never "<digits> specialized agents", never a bare
# number. Matched case-insensitively so a capitalised "57 Skills" cannot slip
# past unverified; the canonical strings are lowercase, and the original casing
# of the matched word is preserved in the replacement.
#
# The (?<![\d.]) lookbehind exists because a plain \b let the pattern match the
# TAIL of a decimal: in "1.5 skills", \b sits between "." and "5", so "5 skills"
# matched and would have been rewritten to "57 skills", producing "1.57 skills".
# Refusing to start a match immediately after a digit or a dot kills that whole
# class (version strings, "10.5 skills", "v2.3 skills") at the regex level.
PAT = re.compile(r'(?<![\d.])(\d+) (skills)\b', re.I)


def rewrite(match):
    # Substitute ONLY a count that actually differs. An occurrence that already
    # equals `want` is returned byte-identical, which makes idempotence
    # structural instead of incidental.
    if match.group(1) == want:
        return match.group(0)
    return '%s %s' % (want, match.group(2))


# PASS 1 — read everything, compute every intended edit, and prove the whole set
# can be written. Nothing is written until this pass is clean, so a problem on
# the second file cannot leave the first one already rewritten.
problems = []
edits = []

for rel in ALLOWLIST:
    path = os.path.join(root, rel)
    if os.path.islink(path):
        problems.append('%s is a symlink — refusing to write through it' % rel)
        continue
    if not os.path.exists(path):
        problems.append('%s is MISSING (renamed or moved?) — the count cannot be verified' % rel)
        continue
    if not os.path.isfile(path):
        problems.append('%s is not a regular file' % rel)
        continue
    try:
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        problems.append('%s could not be read (%s)' % (rel, exc))
        continue
    if not PAT.search(text):
        problems.append('%s contains no "<N> skills" string — the count location moved' % rel)
        continue
    # EXACTLY ONE rewritable occurrence, or STOP. The allowlist narrowed which
    # FILES may be touched; it says nothing about which occurrence INSIDE one of
    # them is the metadata. A genuinely historical line — "grew from 49 skills"
    # in README.md — is indistinguishable from the live count by pattern alone,
    # and rewriting it corrupts prose that was never wrong. Rewriting is only
    # provably correct when there is a single count to rewrite; two or more
    # disagreeing occurrences make the choice a guess, so the release stops and
    # a human disambiguates. (Occurrences already equal to `want` are ignored
    # here: they need no decision, which is what makes the mixed
    # "49 skills today, 57 skills after" case still resolvable.)
    stale = [m for m in PAT.finditer(text) if m.group(1) != want]
    if len(stale) > 1:
        where = ', '.join(
            'line %d ("%s %s")' % (text.count('\n', 0, m.start()) + 1, m.group(1), m.group(2))
            for m in stale)
        problems.append(
            '%s has %d differing "<N> skills" occurrences (%s) — refusing to guess which one is '
            'the metadata; correct the live count by hand (or reword the historical ones), then re-run'
            % (rel, len(stale), where))
        continue
    fixed = PAT.sub(rewrite, text)
    if fixed == text:
        continue
    if not os.access(path, os.W_OK) or not os.access(os.path.dirname(path), os.W_OK):
        problems.append('%s needs the count corrected but is not writable' % rel)
        continue
    edits.append((rel, path, fixed))

if problems:
    print('; '.join(problems))
    sys.exit(1)

# PASS 2 — STAGE EVERYTHING, THEN COMMIT. Two sub-phases:
#   2a STAGE  — for every edit, write a temp file in the SAME directory as its
#               target, flush + fsync + chmod it. Nothing is renamed yet.
#   2b COMMIT — only once EVERY temp exists, run the os.replace() calls
#               back-to-back with no other work between them.
#
# WHY, and what this does NOT buy. The previous shape wrote and renamed one file
# at a time, so an error anywhere in the second file's read/encode/write/fsync/
# chmod path left the FIRST file already rewritten: a half-updated marketplace,
# dirty in git. That dirty tree is not merely untidy — the pre-flight above pulls
# fail-closed, so the NEXT run's `git pull --rebase` refuses on the unstaged
# changes and every subsequent release is blocked until a human intervenes. The
# two hardenings deadlock with each other exactly there. Staging first removes
# that: any failure before 2b leaves ZERO targets modified (the temps are
# unlinked) and the marketplace stays clean, so the next run still pulls.
#
# There is NO true cross-file atomicity here and none is achievable without a
# transactional filesystem — POSIX has no multi-file commit, so a crash BETWEEN
# the two os.replace() calls still leaves one file new and one old. What changed
# is the size of that window: it is now two adjacent metadata-only renames rather
# than an arbitrary amount of I/O, and the only thing that can still land in it
# is a process/host death, not an ordinary error.
staged = []
cur_rel = None
cur_tmp = None
try:
    for rel, path, fixed in edits:
        cur_rel, cur_tmp = rel, None
        fd, cur_tmp = tempfile.mkstemp(prefix='.zuvo-count-', dir=os.path.dirname(path))
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            fh.write(fixed)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(cur_tmp, stat.S_IMODE(os.stat(path).st_mode))  # mkstemp is 0600
        staged.append((rel, path, cur_tmp))
        cur_tmp = None
except (OSError, UnicodeError) as exc:
    leftovers = [t for _r, _p, t in staged]
    if cur_tmp is not None:
        leftovers.append(cur_tmp)
    for leftover in leftovers:
        try:
            os.unlink(leftover)
        except OSError:
            pass
    print('%s could not be staged (%s) — NO marketplace file was modified' % (cur_rel, exc))
    sys.exit(1)

for rel, path, tmp in staged:
    try:
        os.replace(tmp, path)
    except OSError as exc:
        # Reachable only if a rename fails after its temp was already written —
        # rare, and the one case where a partial rewrite can survive. Say so, so
        # nobody debugs a wedged next run from a clean-looking error message.
        print('%s could not be committed (%s) — an earlier file in the set may already be '
              'rewritten; check `git -C <marketplace> status` before re-running' % (rel, exc))
        sys.exit(1)

# PASS 3 — re-read and verify. Redundant by construction, kept as the backstop
# that a survivor can never be reported as a success.
survivors = []
for rel in ALLOWLIST:
    path = os.path.join(root, rel)
    try:
        with open(path, encoding='utf-8') as fh:
            text = fh.read()
    except (OSError, UnicodeDecodeError) as exc:
        survivors.append('%s could not be re-read for verification (%s)' % (rel, exc))
        continue
    found = False
    for match in PAT.finditer(text):
        found = True
        if match.group(1) != want:
            survivors.append('%s (says "%s %s")' % (rel, match.group(1), match.group(2)))
    if not found:
        survivors.append('%s (no "<N> skills" string after rewrite)' % rel)

if survivors:
    print('; '.join(sorted(set(survivors))))
    sys.exit(1)
PY
# Armed BEFORE the rewrite, not after. The python below writes TWO files; if it wrote the first
# and failed on the second, a flag set afterwards would still read 0 and the trap would skip the
# exact case it exists for. Arming early is free: if nothing was written, `git checkout --` on
# unmodified files is a no-op.
MKT_REWROTE=1
MKT_DIAG="$(python3 -c "$MKT_COUNT_PY" "$MARKETPLACE_DIR" "$MKT_SKILL_COUNT")" \
  || fail "Marketplace skill count sync FAILED: ${MKT_DIAG:-<no detail>} — fix by hand in $MARKETPLACE_DIR (Step 4 commits it), then re-run"
ok "Step 0b: marketplace skill count synced (${MKT_SKILL_COUNT} skills)"
# <<< zuvo:marketplace-count
# The trap brackets the fence rather than living inside it: the gate suite EXTRACTS this fenced
# block and runs it standalone, so a trap armed within would fire when the extracted block ends
# and revert the rewrite the suite then asserts on. Crash-safety of the whole script is not part
# of the count-rewrite unit. (MKT_REWROTE is armed inside, before the write — see there.)

# ═══════════════════════════════════════
# Step 1: Version bump
# ═══════════════════════════════════════
cd "$ZUVO_DIR"
CURRENT_VERSION=$(grep '"version"' package.json | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
  *) echo "Usage: $0 \"message\" [patch|minor|major]"; exit 1 ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
echo ""
echo "══════════════════════════════════════"
echo "  zuvo v${CURRENT_VERSION} → v${NEW_VERSION} (${BUMP})"
echo "══════════════════════════════════════"
echo ""

# Update version in all files
sed_i "s/\"version\": \"${CURRENT_VERSION}\"/\"version\": \"${NEW_VERSION}\"/" package.json
sed_i "s/\"version\": \"${CURRENT_VERSION}\"/\"version\": \"${NEW_VERSION}\"/" .claude-plugin/plugin.json
sed_i "s/\"version\": \"${CURRENT_VERSION}\"/\"version\": \"${NEW_VERSION}\"/" .codex-plugin/plugin.json
# Update version banner in skill router
sed_i "s/Zuvo v${CURRENT_VERSION}/Zuvo v${NEW_VERSION}/" skills/using-zuvo/SKILL.md 2>/dev/null || true
# Machine-readable VERSION marker — the ONE file that survives a bare skills-only
# deploy (e.g. a synced fleet bot that has no package.json/plugin.json to read).
# install.sh copies it into every target root AND skills/, so any install can be
# version-identified with `cat .../VERSION` or `cat .../skills/VERSION`.
printf '%s\n' "${NEW_VERSION}" > VERSION
ok "Version bumped: v${NEW_VERSION} (VERSION file + manifests + banner)"

# ═══════════════════════════════════════
# Step 2: Commit
# ═══════════════════════════════════════
if [[ -z "$MSG" ]]; then
  MSG="release v${NEW_VERSION}"
fi

git add -A
if git diff --cached --quiet 2>/dev/null; then
  echo "  No changes to commit."
else
  git commit -m "release: v${NEW_VERSION} — ${MSG}"
  ok "Committed: v${NEW_VERSION} — ${MSG}"
fi

# ═══════════════════════════════════════
# Step 3: Push + tag
# ═══════════════════════════════════════
git push origin main 2>&1 | tail -1
git tag "v${NEW_VERSION}" 2>/dev/null || true
git push --tags 2>/dev/null || true

NEW_SHA=$(git rev-parse HEAD)
ok "Pushed + tagged v${NEW_VERSION} (${NEW_SHA:0:7})"

# ═══════════════════════════════════════
# Step 3b: GitHub Release (2026-08-02)
# ═══════════════════════════════════════
# Tags alone are invisible on the Releases page — v1.6.52 was the first ever
# formal Release and had to be hand-authored. Notes = the non-release commit
# subjects since the previous tag. Best-effort by design: a missing `gh`, no
# auth, or an API blip must never fail a release whose tag is already pushed
# (the release object can be created by hand later). `gh release create` on an
# EXISTING tag attaches to it and creates nothing new.
if command -v gh >/dev/null 2>&1; then
  PREV_TAG=$(git describe --tags --abbrev=0 "v${NEW_VERSION}^" 2>/dev/null || true)
  if [ -n "$PREV_TAG" ]; then
    REL_NOTES=$(git log --format='- %s' "${PREV_TAG}..v${NEW_VERSION}" | grep -v '^- release:' || true)
  else
    REL_NOTES=""
  fi
  [ -n "$REL_NOTES" ] || REL_NOTES="- ${MSG}"
  REL_NOTES="${REL_NOTES}

## Install / update
\`\`\`bash
claude plugin marketplace add greglas75/zuvo-marketplace   # first install
claude plugin install zuvo
# update: claude plugin marketplace update zuvo-marketplace && claude plugin update zuvo@zuvo-marketplace
\`\`\`
Then restart Claude Code (and the Codex app — it indexes skills at launch)."
  if gh release view "v${NEW_VERSION}" >/dev/null 2>&1; then
    ok "GitHub Release v${NEW_VERSION} already exists — skipped"
  elif gh release create "v${NEW_VERSION}" \
        --title "v${NEW_VERSION} — ${MSG}" \
        --notes "$REL_NOTES" >/dev/null 2>&1; then
    ok "GitHub Release created: https://github.com/greglas75/zuvo/releases/tag/v${NEW_VERSION}"
  else
    warn "GitHub Release creation failed (tag is pushed; create by hand: gh release create v${NEW_VERSION})"
  fi
else
  warn "gh not installed — no GitHub Release object (tag v${NEW_VERSION} is pushed)"
fi

# ═══════════════════════════════════════
# Step 4: Update marketplace
# ═══════════════════════════════════════
cd "$MARKETPLACE_DIR"
git pull --rebase --quiet 2>/dev/null || true
sed_i "s/\"sha\": \"[a-f0-9]*\"/\"sha\": \"${NEW_SHA}\"/" .claude-plugin/marketplace.json
git add -A
git commit -m "bump: zuvo v${NEW_VERSION} (${NEW_SHA:0:7})" --quiet
# The rewrite is now IN a commit, so there is nothing left to revert — disarm before the push,
# because a failed push must not roll the committed count back out of the working tree.
MKT_REWROTE=0
trap - EXIT INT TERM
git push --quiet
ok "Marketplace updated → v${NEW_VERSION} (${NEW_SHA:0:7})"

# ═══════════════════════════════════════
# Step 5: Update local installed_plugins.json
# ═══════════════════════════════════════
cd "$ZUVO_DIR"
PLUGINS_JSON="$HOME/.claude/plugins/installed_plugins.json"
NEW_INSTALL_PATH="$HOME/.claude/plugins/cache/zuvo-marketplace/zuvo/${NEW_VERSION}"
if [[ -f "$PLUGINS_JSON" ]]; then
  # CRITICAL: update installPath + version, NOT just gitCommitSha. Claude Code
  # loads hooks/skills from `installPath` — if only the SHA moves, the running
  # plugin stays frozen at the OLD version dir (the 2026-05-31 bug where three
  # watchdog releases never took effect because installPath stayed at 1.3.107
  # while only gitCommitSha advanced). install.sh has already populated the new
  # version dir by this point, so pointing installPath at it is safe.
  python3 -c "
import json
path = '$PLUGINS_JSON'
sha = '$NEW_SHA'
ver = '$NEW_VERSION'
ipath = '$NEW_INSTALL_PATH'
with open(path) as f:
    data = json.load(f)
for name, entries in data.get('plugins', {}).items():
    if 'zuvo' in name.lower():
        for e in entries:
            e['gitCommitSha'] = sha
            e['version'] = ver
            e['installPath'] = ipath
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null && ok "installed_plugins.json updated → installPath+version+sha = v${NEW_VERSION}" || warn "Could not update installed_plugins.json"
else
  warn "installed_plugins.json not found"
fi

# ═══════════════════════════════════════
# Step 6: Install to all platforms
# ═══════════════════════════════════════
# NOT a bare grep pipeline: under `set -euo pipefail` a filter grep with zero
# matches exits 1 and aborted the script HERE — skipping Step 7 (enable) and
# Step 8 (installPath self-heal), the exact cause of the 2026-07-08 v1.6.2/3
# "RELEASE_EXIT=1 + installPath not loadable" incident. Capture install.sh's
# real exit code, print the filtered summary best-effort, and fail ONLY on a
# genuine install.sh failure.
_install_rc=0
_install_out="$(bash scripts/install.sh 2>&1)" || _install_rc=$?
printf '%s\n' "$_install_out" | grep -E "✓|✗|DONE|======" || true
[ "$_install_rc" -eq 0 ] || fail "install.sh failed (rc=$_install_rc) — full output above is filtered; re-run: bash scripts/install.sh"

# ═══════════════════════════════════════
# Step 7: Re-assert plugin enabled (prevents the recurring "skills not visible"
# bug where a plugin update/reinstall cycle leaves zuvo DISABLED in
# ~/.claude/settings.json enabledPlugins, and nothing turns it back on — the
# 2026-06-15 "znowu nie widać skili" incident). Idempotent; no-op if already on.
# ═══════════════════════════════════════
if command -v claude >/dev/null 2>&1; then
  _en=$(claude plugin enable zuvo@zuvo-marketplace 2>&1 || true)
  if printf '%s' "$_en" | grep -qiE "enabled|already"; then
    ok "Plugin enabled (zuvo@zuvo-marketplace)"
  else
    warn "Could not enable plugin — check: claude plugin list"
  fi
fi

# ═══════════════════════════════════════
# Step 8: Verify installPath is LOADABLE; self-heal if not.
# Root cause of the recurring "znowu nie widać skili" (2026-06-15): Step 5
# repoints installPath to the new version dir, but install.sh populates that dir
# with content subdirs ONLY (no .claude-plugin/plugin.json, no .git) — so Claude
# Code cannot load it. The old frozen-installPath bug masked this by keeping the
# pointer on the original complete clone. Here we detect the incomplete dir and
# force a real clone (uninstall+install — `update` no-ops once the version is
# already recorded), which is the only thing that produces a loadable dir.
# ═══════════════════════════════════════
if command -v claude >/dev/null 2>&1; then
  if [[ -f "$NEW_INSTALL_PATH/.claude-plugin/plugin.json" ]]; then
    ok "installPath loadable (.claude-plugin/plugin.json present)"
  else
    warn "installPath incomplete ($NEW_INSTALL_PATH has no .claude-plugin/plugin.json) — forcing clean reinstall"
    # CRITICAL: refresh the LOCAL marketplace cache to the SHA we just pushed in
    # Step 4 FIRST. `claude plugin install` clones from the local marketplace
    # cache, NOT from GitHub — and Step 4 only pushed the marketplace repo, it
    # did not refresh this machine's cache. Without this, the reinstall clones
    # the PREVIOUS SHA and silently installs the prior version (the 2026-06-18
    # v1.3.119 race: self-heal produced a loadable dir but it was v1.3.118).
    claude plugin marketplace update zuvo-marketplace >/dev/null 2>&1 || true
    claude plugin uninstall zuvo@zuvo-marketplace >/dev/null 2>&1 || true
    if claude plugin install zuvo@zuvo-marketplace >/dev/null 2>&1; then
      claude plugin enable zuvo@zuvo-marketplace >/dev/null 2>&1 || true
      ok "Clean reinstall → loadable plugin"
    else
      warn "Clean reinstall failed — run manually: claude plugin uninstall zuvo@zuvo-marketplace && claude plugin install zuvo@zuvo-marketplace"
    fi
  fi
fi

echo ""
echo "══════════════════════════════════════"
echo "  RELEASE COMPLETE"
echo "══════════════════════════════════════"
echo "  Version: v${NEW_VERSION}"
echo "  SHA:     ${NEW_SHA:0:7}"
echo "  Action:  restart Claude Code, THEN run the check below"
echo ""
# Step 7 enabled the plugin, and a Claude Code that was RUNNING during this release can
# still persist its own older view of ~/.claude/settings.json afterwards and undo it — the
# CLI writes the file, the app owns it. Nothing this script does can win that race, so make
# it visible instead of silent. Measured 2026-08-12: a release reported "✓ Plugin enabled",
# and after the restart `claude plugin list` showed DISABLED in both scopes, with every
# skill invisible. Same class as the Codex "app indexes at LAUNCH" gotcha in CLAUDE.md.
echo "  ── after the restart, verify (one command) ──"
echo "     claude plugin list | grep -A3 zuvo"
echo "     Expect: Status: ✔ enabled. If it says ✘ disabled, the running app clobbered"
echo "     the enable — fix with:  claude plugin enable zuvo@zuvo-marketplace"
echo ""
