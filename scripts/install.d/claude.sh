#!/usr/bin/env bash
# scripts/install.d/claude.sh — part of scripts/install.sh, which sources it; not runnable alone.
# Claude Code: the plugin-cache sync (install_claude) and the reviewer-lane rewrite it applies
# to every cache dir (materialize/validate_claude_reviewer_lanes).

# materialize_claude_reviewer_lanes <cache-root> — resolve the reviewer LANE an agent names as its
# model (`model: review-primary` / `model: review-alt`) to the tier label Claude Code's Agent tool
# takes (opus / sonnet). ONLY there: the `model:` key inside the leading `---` block of
# skills/*/agents/*.md (plan C Task 3), with the strict rewriter of lib/reviewer-lanes.sh.
#
# Everywhere else these words are the ROUTER's lane names: reviewer-model-route.sh answers
# `reviewer_lane=review-alt` or `reviewer_lane=cross-vendor`, and test-reviewer-routing.md,
# env-compat.md, session-state.md, execute and retro quote them to say what to do with that answer.
# This used to rewrite every .md in skills/, shared/includes/ and rules/, so the installed copy of each
# of those documents said `sonnet` where the router it documents says `review-alt`.
#
# skills/*/agents/*.md is every agent file there is (no nested agent dirs). Anything the strict
# rewriter does not take — a lane elsewhere, or in a spelling it does not parse — is left for
# validate_claude_reviewer_lanes, whose independent lenient scan fails the install on it.
# Each file is rewritten atomically; the first one that cannot be stops the install, named, and is
# left exactly as it was. Symlinks under skills/ must stay inside it (the scans' rule): checked BEFORE
# any file is rewritten, so a refused link leaves the cache as it was. And an unmatched glob is no
# success: the repo ships its agents as skills/*/agents/*.md, so a cache with none is incomplete.
materialize_claude_reviewer_lanes() {
  local target_root="$1"
  local file
  local n=0

  if [[ ! -d "$target_root/skills" ]]; then
    fail "Required Claude cache dir missing: $target_root/skills"
    return 1
  fi
  if ! zrl_links_inside "$target_root/skills"; then
    fail "Refusing the symlinks named above under $target_root/skills — the install stops here"
    return 1
  fi
  for file in "$target_root"/skills/*/agents/*.md; do
    [[ -f "$file" ]] || continue
    n=$((n + 1))
    if ! zrl_rewrite_lanes_file opus sonnet "$file"; then
      fail "Could not resolve the reviewer lanes in $file — the install stops here"
      return 1
    fi
  done
  if [[ "$n" -eq 0 ]]; then
    fail "No agent file under $target_root/skills/*/agents/ — the cache is incomplete, not clean"
    return 1
  fi
}

# validate_claude_reviewer_lanes <cache-root> — no frontmatter model key under skills/, shared/ or
# rules/ may still name a route word: that is a model setting the harness cannot resolve. The lenient
# scan of lib/reviewer-lanes.sh, independent of the rewriter's grammar and wider than its reach (any
# frontmatter, a BOM, indentation, blanks before the colon or after `---`, quotes, any case, and
# cross-vendor & co as well as the two lanes), so what the rewriter could not take fails the install
# here instead of shipping. Prose is not checked: the words are the router's there, and must survive.
validate_claude_reviewer_lanes() {
  local target_root="$1"
  local dir
  local refs

  for dir in "$target_root/skills" "$target_root/shared" "$target_root/rules"; do
    if [[ ! -d "$dir" ]]; then
      fail "Required Claude cache dir missing during validation: $dir"
      return 1
    fi
  done

  # Fail closed: a scan that could not run has not shown the cache is clean. What it HAD found before it
  # stopped is still shown, so a real lane is not hidden behind the unreadable file.
  if ! refs=$(zrl_scan_md "$target_root/skills" "$target_root/shared" "$target_root/rules"); then
    fail "Could not scan the Claude cache for unresolved reviewer lanes: $target_root"
    if [[ -n "$refs" ]]; then
      echo "     lanes it had found before it stopped:"
      zrl_show_refs "$refs" "       "
    else
      echo "     (it had found none before it stopped)"
    fi
    return 1
  fi
  if [[ -n "$refs" ]]; then
    fail "Abstract reviewer lanes remain in Claude cache: $(zrl_count_refs "$refs") leftover lane reference(s) (a route word as a frontmatter model):"
    zrl_show_refs "$refs" "     "
    return 1
  fi
  return 0
}

# =======================================
# CLAUDE CODE
# =======================================
install_claude() {
  echo ""
  echo "======================================"
  echo "  CLAUDE CODE"
  echo "======================================"

  # Find the cache directory
  CACHE_BASE="$HOME/.claude/plugins/cache/zuvo-marketplace/zuvo"
  if [[ ! -d "$CACHE_BASE" ]]; then
    fail "Plugin cache not found at $CACHE_BASE"
    echo "     Run first: claude plugin install zuvo (from zuvo-marketplace)"
    return 1
  fi

  # Ensure a cache dir exists for the CURRENT version.
  # ATOMIC creation: Claude Code discovers a version dir by its existence, and dev-push points
  # installPath at it BEFORE this sync runs — so a version dir that is mkdir'd empty and
  # populated later has a window where a concurrent session loads it with EMPTY shared/includes
  # and rules → skills run degraded (the 2026-07-05 report: a parallel plan run fell back to
  # SKILL.md + project rules). Build the dir under a temp name, fully seeded from an existing
  # populated cache dir (upgrade) or bare structure (fresh install), then rename(2) it into
  # place so it NEVER appears half-populated. The sync loop below then updates it in place
  # (overwrite — never empties it).
  local current_version="$VERSION"
  if [[ ! -d "$CACHE_BASE/$current_version" ]]; then
    echo "  Creating cache dir for v${current_version} (atomic)..."
    local _seed="" _d _tmp="$CACHE_BASE/.$current_version.tmp.$$"
    rm -rf "$_tmp"
    # Pick the first NON-hidden existing cache dir as the seed. Filter hidden dirs
    # by BASENAME — the old `ls | grep -v '/\.'` matched "/." anywhere in the
    # ABSOLUTE path, and $HOME/.claude/... always contains "/.": it filtered every
    # candidate, grep exited 1, and `set -euo pipefail` killed the whole install at
    # this line (the real root cause of the 2026-07-08 RELEASE_EXIT=1 incidents —
    # dev-push's old Step 6 grep pipeline then masked it). No pipeline: no set -e hazard.
    for _d in "$CACHE_BASE"/*/; do
      [[ -d "$_d" ]] || continue
      case "$(basename "$_d")" in .*) continue ;; esac
      _seed="${_d%/}"
      break
    done
    if [[ -n "$_seed" ]]; then
      cp -R "${_seed%/}" "$_tmp" 2>/dev/null || mkdir -p "$_tmp"
    else
      mkdir -p "$_tmp"/skills "$_tmp"/shared/includes "$_tmp"/rules "$_tmp"/scripts "$_tmp"/bin "$_tmp"/docs
    fi
    if [[ -d "$CACHE_BASE/$current_version" ]]; then
      rm -rf "$_tmp"                                     # lost a race to another installer — fine
    else
      mv "$_tmp" "$CACHE_BASE/$current_version" 2>/dev/null || { rm -rf "$_tmp"; mkdir -p "$CACHE_BASE/$current_version"/skills "$CACHE_BASE/$current_version"/shared/includes "$CACHE_BASE/$current_version"/rules; }
    fi
  fi

  # Sync to ALL existing cache dirs (Claude Code may have version + SHA dirs)
  CACHE_DIRS=$(ls -d "$CACHE_BASE"/*/ 2>/dev/null)
  if [[ -z "$CACHE_DIRS" ]]; then
    fail "No cache directories in $CACHE_BASE"
    return 1
  fi

  for CACHE_DIR in $CACHE_DIRS; do
    DIR_NAME=$(basename "$CACHE_DIR")
    echo "  Syncing: $DIR_NAME"

    # Copy skills (new + updated), resolve {plugin_root} to actual cache path
    for skill_dir in "$ZUVO_DIR"/skills/*/; do
      skill_name=$(basename "$skill_dir")
      # Never carry a test fixture out of the repo. tests/skill-suite/test-references-guards.sh
      # creates skills/tmp-refguard-$$-test/ inside the real tree (B-REFGUARD); an install that
      # overlaps a running guard test — or follows a killed one — copied it into the cache, where
      # it persisted indefinitely. Found in BOTH 1.6.52 and 1.6.53 on 2026-08-03 and removed by
      # hand. Skipping `tmp-*` makes the leak impossible regardless of timing.
      case "$skill_name" in tmp-*) continue ;; esac
      mkdir -p "$CACHE_DIR/skills/$skill_name"
      cp_warn "skills/$skill_name" -r "$skill_dir"* "$CACHE_DIR/skills/$skill_name/"
    done
    # Replace {plugin_root} placeholder with actual resolved path in all skill files
    local resolved_root="${CACHE_DIR%/}"
    # `find -exec` cannot call the sed_i shell function, so use the portable -i.<suffix> form
    # directly and sweep the backups. The old `sed -i ''` here was BSD-only AND swallowed by
    # `|| true`, so on Git Bash the install "succeeded" with {plugin_root} never substituted.
    find "$CACHE_DIR/skills" -name "*.md" -exec \
      sed -i.zbak "s|{plugin_root}|${resolved_root}|g" {} + 2>/dev/null || true
    find "$CACHE_DIR/skills" -name "*.md.zbak" -delete 2>/dev/null || true
    # Clean up any orphan files at skills/ root level
    rm -f "$CACHE_DIR/skills/SKILL.md" 2>/dev/null || true
    rm -rf "$CACHE_DIR/skills/agents" 2>/dev/null || true

    # Strip non-Claude-Code platform blocks (CODEX, CURSOR, ANTIGRAVITY)
    # Each block is delimited by <!-- PLATFORM:X --> ... <!-- /PLATFORM:X -->
    find "$CACHE_DIR/skills" -name "*.md" -exec \
      sed_i -e '/<!-- PLATFORM:CODEX -->/,/<!-- \/PLATFORM:CODEX -->/d' \
                -e '/<!-- PLATFORM:CURSOR -->/,/<!-- \/PLATFORM:CURSOR -->/d' \
                -e '/<!-- PLATFORM:ANTIGRAVITY -->/,/<!-- \/PLATFORM:ANTIGRAVITY -->/d' \
                  -e '/<!-- PLATFORM:KIMI -->/,/<!-- \/PLATFORM:KIMI -->/d' \
                {} + 2>/dev/null || true

    # Copy shared includes
    if [[ -d "$ZUVO_DIR/shared/includes" ]] && [[ -d "$CACHE_DIR/shared/includes" ]]; then
      cp_warn "shared/includes" -R "$ZUVO_DIR"/shared/includes/. "$CACHE_DIR/shared/includes/"
      # Strip non-Claude-Code platform blocks from shared includes too
      find "$CACHE_DIR/shared/includes" -name "*.md" -exec \
        sed_i -e '/<!-- PLATFORM:CODEX -->/,/<!-- \/PLATFORM:CODEX -->/d' \
                  -e '/<!-- PLATFORM:CURSOR -->/,/<!-- \/PLATFORM:CURSOR -->/d' \
                  -e '/<!-- PLATFORM:ANTIGRAVITY -->/,/<!-- \/PLATFORM:ANTIGRAVITY -->/d' \
                  -e '/<!-- PLATFORM:KIMI -->/,/<!-- \/PLATFORM:KIMI -->/d' \
                  {} + 2>/dev/null || true
    fi

    # Copy rules
    if [[ -d "$ZUVO_DIR/rules" ]] && [[ -d "$CACHE_DIR/rules" ]]; then
      cp_warn "rules" "$ZUVO_DIR"/rules/*.md "$CACHE_DIR/rules/"
    fi

    # Copy scripts (adversarial-review.sh, etc.). *.py too — test-coverage-gate.py
    # is the write-tests executable gate; a *.sh-only copy silently shipped a skill
    # that calls a nonexistent validator (caught 2026-07-31). scripts/lib/ rides
    # along for anything that sources it — FIRST: adversarial-review.sh looks for its
    # runner in the sibling lib/, and a review starting mid-install must not run the
    # new driver before its library is there. Through install_runner_lib, like every
    # other host: atomic and content-verified per file, a miss counted for INSTALL
    # INCOMPLETE (a `cp -R` here was neither, and its failure was only a WARN line).
    # scripts/lib/ holds regular files only — the helper ships those, no subdirectories.
    # `|| :` — the miss is counted; it must not abort the other cache dirs under set -e.
    if [[ -d "$ZUVO_DIR/scripts" ]]; then
      mkdir -p "$CACHE_DIR/scripts"
      install_runner_lib "claude cache $DIR_NAME (runner lib)" "$ZUVO_DIR/scripts/lib" "${CACHE_DIR%/}/scripts" || :
      cp_warn "scripts/*.sh" "$ZUVO_DIR"/scripts/*.sh "$CACHE_DIR/scripts/"
      # The install.sh just copied loads its code from scripts/install.d/; without the modules beside
      # it the cached copy is an installer that refuses to start.
      mkdir -p "$CACHE_DIR/scripts/install.d"
      cp_warn "scripts/install.d" "$ZUVO_DIR"/scripts/install.d/*.sh "$CACHE_DIR/scripts/install.d/"
      cp_warn "scripts/*.py" "$ZUVO_DIR"/scripts/*.py "$CACHE_DIR/scripts/"
      chmod +x "$CACHE_DIR"/scripts/*.sh "$CACHE_DIR"/scripts/*.py 2>/dev/null || true
    fi

    # Copy the VERSION marker to the target root AND skills/ — so ANY install,
    # including a bare skills-only fleet deploy with no manifest, is version-
    # identifiable (`cat <root>/VERSION` or `cat <root>/skills/VERSION`).
    if [[ -f "$ZUVO_DIR/VERSION" ]]; then
      cp_warn "VERSION" "$ZUVO_DIR/VERSION" "$CACHE_DIR/VERSION"
      mkdir -p "$CACHE_DIR/skills"
      cp_warn "skills/VERSION" "$ZUVO_DIR/VERSION" "$CACHE_DIR/skills/VERSION"
    fi

    # Copy the Claude Code plugin manifest. The Codex targets have had this since
    # forever (see the .codex-plugin copies in install.d/codex.sh); the Claude cache never
    # did, so every cache dir kept whatever manifest Claude Code itself wrote when
    # it created that directory — and nothing refreshed it afterwards.
    # Measured 2026-08-03 while verifying the v1.6.54 install (backlog
    # B-INSTALL-CLAUDE-MANIFEST): after installing 1.6.54, the manifest inside the
    # 1.6.53 cache dir still declared 1.6.16, and the one inside 1.6.54 declared
    # 1.6.47. Skills still load (everything else here IS synced to every cache
    # dir), so this is metadata drift rather than a load failure — which is
    # exactly why it survived ~40 releases unnoticed.
    # NB the drift is not visible in a dir Claude Code has just created for a
    # fresh version: it writes a correct manifest at creation time, and only
    # later installs into that same dir leave it behind. Guarded by
    # test-install-wiring.sh (9).
    if [[ -f "$ZUVO_DIR/.claude-plugin/plugin.json" ]]; then
      mkdir -p "$CACHE_DIR/.claude-plugin"
      # WARN, not a silent `|| true`. The seven sibling copies in this loop
      # swallow their failures, and that convention is precisely how this
      # manifest went stale for ~40 releases without a signal. A copy that fails
      # here leaves the drift this block exists to fix, so a failed run must at
      # least SAY so — otherwise "install.sh reported OK" answers a question it
      # never actually checked.
      cp "$ZUVO_DIR/.claude-plugin/plugin.json" "$CACHE_DIR/.claude-plugin/plugin.json" 2>/dev/null \
        || echo "  WARN: could not refresh $CACHE_DIR/.claude-plugin/plugin.json — its version/skill-count metadata stays stale" >&2
    fi

    # Copy bin/ (CLI wrappers — Claude Code adds {plugin_root}/bin to PATH)
    if [[ -d "$ZUVO_DIR/bin" ]]; then
      mkdir -p "$CACHE_DIR/bin"
      cp_warn "bin" "$ZUVO_DIR"/bin/* "$CACHE_DIR/bin/"
      chmod +x "$CACHE_DIR"/bin/* 2>/dev/null || true
    fi

    # Copy hooks — FULL tree incl. hooks/lib/ (recursive) so the pipeline-gate
    # lib reaches the cache, plus the CI script + git shim + CI workflow template.
    if [[ -d "$ZUVO_DIR/hooks" ]]; then
      install_hook_tree "$CACHE_DIR/hooks"
      install_pipeline_artifacts "$CACHE_DIR"
    fi

    # Copy docs — the WHOLE tree, subdirectories included.
    #
    # This used to be `docs/*.md`, which refreshes only the top level and leaves
    # docs/specs/, docs/runbook/ and docs/adr/ frozen at whatever version first created
    # them. A stale doc in the cache is not inert: agents read the cache, and
    # docs/specs/2026-04-09-retrospective-feedback-loop-spec.md carried a runnable
    # "prune retros.log to the last 100 rows" block that kept being executed for a month
    # after the source stopped shipping it (six truncations, 2026-08-17..2026-09-17).
    # Fixing a doc in the repo has to mean fixing the copy agents actually read.
    # A merge is not enough either: `cp -R` refreshes and adds, but never REMOVES, so a doc
    # deleted from the repo lives on in the cache and keeps being read. That is the same
    # failure as the stale copy above, one step later — the retros.log truncation recipe was
    # eventually deleted from the spec, and a merge-only sync would have kept serving it.
    # Replace the tree rather than merging into it.
    # `cp_warn` warns but ALWAYS returns 0 (by design — one failed copy must not abort the
    # install), so it cannot drive the rollback below: branching on it would delete the backup
    # on exactly the failure it exists to survive. Call `cp` directly here and read its status.
    if [[ -d "$ZUVO_DIR/docs" ]]; then
      rm -rf "$CACHE_DIR/docs.zuvo-old.$$" 2>/dev/null || true
      if [[ -d "$CACHE_DIR/docs" ]] && ! mv "$CACHE_DIR/docs" "$CACHE_DIR/docs.zuvo-old.$$" 2>/dev/null; then
        cp_warn "docs" -R "$ZUVO_DIR"/docs/. "$CACHE_DIR/docs/"   # cannot swap: merge and warn
      else
        mkdir -p "$CACHE_DIR/docs"
        if cp -R "$ZUVO_DIR"/docs/. "$CACHE_DIR/docs/" 2>/dev/null; then
          rm -rf "$CACHE_DIR/docs.zuvo-old.$$" 2>/dev/null || true
        else
          # Never leave the cache without docs because a copy failed mid-way.
          rm -rf "$CACHE_DIR/docs" 2>/dev/null || true
          mv "$CACHE_DIR/docs.zuvo-old.$$" "$CACHE_DIR/docs" 2>/dev/null || true
          INSTALL_COPY_WARNINGS=$((INSTALL_COPY_WARNINGS + 1))
          echo "  WARN: docs — copy FAILED; kept the previous cached docs tree" >&2
        fi
      fi
    fi

    materialize_claude_reviewer_lanes "$CACHE_DIR" || return 1
    validate_claude_reviewer_lanes "$CACHE_DIR" || return 1

    SKILL_COUNT=$(ls -d "$CACHE_DIR/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
    ok "$DIR_NAME -- $SKILL_COUNT skills"
  done

  # Fix stale SHA in installed_plugins.json (Claude Code cache bug workaround)
  local plugins_json="$HOME/.claude/plugins/installed_plugins.json"
  if [[ -f "$plugins_json" ]]; then
    local current_sha
    current_sha=$(cd "$ZUVO_DIR" && git rev-parse --verify -q HEAD 2>/dev/null || echo "")
    if [[ -n "$current_sha" ]]; then
      python3 -c "
import json, sys
sha = sys.argv[1]
with open(sys.argv[2]) as f:
    data = json.load(f)
changed = False
for entry in data.get('plugins', {}).get('zuvo@zuvo-marketplace', []):
    if entry.get('gitCommitSha') != sha:
        entry['gitCommitSha'] = sha
        changed = True
if changed:
    with open(sys.argv[2], 'w') as f:
        json.dump(data, f, indent=2)
    print('  \u2713 Fixed stale SHA in installed_plugins.json')
" "$current_sha" "$plugins_json" 2>/dev/null || true
    fi
  fi

  # Remove old cache dirs but KEEP the 2 newest versions (current + the most-recent
  # previous). A live session bakes CLAUDE_PLUGIN_ROOT to whatever version was current
  # when it STARTED; deleting that dir mid-run 404s all its plugin hooks (the
  # 2026-05-31 regression — releasing 1.3.112 while a 1.3.111 session was live broke
  # its hooks with "Plugin directory does not exist"). Keeping the previous version
  # lets that session run until the user restarts it onto the current one. Truly-stale
  # dirs (2+ behind) still get cleaned to avoid version PATH confusion.
  local keep_versions
  local _v_names=""
  for _v in "$CACHE_BASE"/*/; do
    [ -d "$_v" ] || continue
    _v_names="$_v_names$(basename "$_v")\n"
  done
  keep_versions=$(printf '%b' "$_v_names" | grep -v '^$' | sort -V | tail -2)
  for old_dir in "$CACHE_BASE"/*/; do
    local dir_name
    dir_name=$(basename "$old_dir")
    if ! printf '%s\n' "$keep_versions" | grep -qx "$dir_name"; then
      rm -rf "$old_dir"
      echo "  Removed old cache: $dir_name (kept current + previous)"
    fi
  done

  ok "Claude Code updated"
}
