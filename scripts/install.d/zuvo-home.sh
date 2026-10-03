#!/usr/bin/env bash
# scripts/install.d/zuvo-home.sh — part of scripts/install.sh, which sources it; not runnable alone.
# ~/.zuvo: the helpers every skill calls by absolute path, the refactor-radar bundle, and the
# pruning of helpers the repo no longer ships.

# =======================================
# ZUVO HOME ($HOME/.zuvo)
# Forcing-function scripts that gate run-log writes on retrospective presence.
# Independent of plugin host (Claude Code / Codex / Cursor) — installed once
# per machine, called from every skill that loads run-logger.md.
# =======================================
install_refactor_radar_bundle() {
  # Publish a complete bundle, not five independently overwritten live files. Old bundles
  # remain usable by running sessions; no whole-cache or other-agent files are replaced here.
  local target="${1:-$HOME/.zuvo/refactor-radar}" bundle entry relative
  if [[ -L "$target" ]]; then
    fail "refactor-radar target must not be a symlink"; return 1
  fi
  if [[ -e "$target/current" && ! -L "$target/current" ]]; then
    fail "refactor-radar current is not a managed symlink"; return 1
  fi
  mkdir -p "$target" || return 1
  bundle="$(mktemp -d "$target/bundle.XXXXXX")" || return 1
  mkdir "$bundle/lib" || return 1
  for entry in "$ZUVO_DIR/scripts/refactor-radar.sh" "$ZUVO_DIR/scripts/lib"/radar_*.py; do
    relative="${entry#"$ZUVO_DIR/scripts/"}"
    cp "$entry" "$bundle/$relative" || return 1
    cmp -s "$entry" "$bundle/$relative" || return 1
  done
  ln -s "${bundle##*/}" "$target/.current.$$" || return 1
  python3 -c 'import os,sys; os.replace(sys.argv[1], sys.argv[2])' \
    "$target/.current.$$" "$target/current" || return 1
  ok "refactor-radar bundle installed ($target/current)"
}

# _zuvo_home_drop_stale <label> <path> <source> — <path> is a candidate the ~/.zuvo driver (or a
# library it loads) may read, and its own installer already reported a failure: <source>'s bytes did
# NOT land at <path> this run. Left as it was, an OLDER copy at <path> — a regular file or a symlink
# whose content differs from <source> — is worse than no file at all: it is silently loaded as if it
# were current. Two concrete cases this generalises from one (model-subprocess.sh, Plan A): a stale
# ~/.zuvo/lib/model-subprocess.sh shadows a fresh flat one and keeps serving an OLD runner; a stale
# ~/.zuvo/blind-coverage-audit.md is read by the blind-audit panel library as a DIFFERENT protocol than
# the one it validates answers against, so every answer comes back invalid — while the install only
# said "failed". Removing the stale copy turns that into a LOUD failure (no file to fall back on)
# instead of a silent mismatch. `rm -f` on a symlink removes the LINK itself, never writing through it.
# A copy that already matches <source> (the reported failure was elsewhere, or a concurrent install won)
# is left alone — status 0, nothing to do. Best effort: when the stale copy cannot be removed (a
# read-only directory), that is said loudly and named in the summary; the caller's miss stays counted
# either way. `cmp -s` exits 1 for "differs" but 2 for "could not compare" (<source> missing or
# unreadable — a broken checkout, not staleness): only exit 1 means stale. Exit 2 KEEPS the file (a
# file that might still be exactly right is not deleted on a guess) and says loudly that staleness
# could not be determined, rather than silently discarding it as if it had been proven stale.
# Status 0 nothing stale / removed, 1 a stale copy survives (removed-but-failed OR undetermined).
_zuvo_home_drop_stale() {
  local label="$1" path="$2" source="$3" _cmp_rc=0
  { [ -L "$path" ] || [ -f "$path" ]; } || return 0
  # ADV-A53: a DANGLING symlink (the link exists, its target does not) can never be "already
  # correct" — cmp against it always fails to read the target (the same non-1 exit the
  # "undetermined, keep + fail loud" branch below is FOR), but there is nothing ambiguous here:
  # remove it unconditionally rather than treating "definitely broken" as "could not tell".
  if [ -L "$path" ] && [ ! -e "$path" ]; then
    if rm -f "$path" 2>/dev/null && [ ! -e "$path" ] && [ ! -L "$path" ]; then
      warn "removed the DANGLING symlink $path — a loud failure now, not a silently broken $label, serves the ~/.zuvo driver"
      return 0
    fi
    INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      stale $label: $path — a dangling symlink could not be removed; the ~/.zuvo driver may still load it"
    fail "a DANGLING symlink at $path could not be removed — the ~/.zuvo driver may still try to load it as the current $label (remove it by hand)"
    return 1
  fi
  cmp -s "$source" "$path" && return 0 || _cmp_rc=$?
  if [ "$_cmp_rc" -ne 1 ]; then
    INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      stale $label: $path — could not compare against $source (cmp exit $_cmp_rc); left in place, staleness undetermined"
    fail "could not tell whether $path (the $label) is stale — cmp against $source exited $_cmp_rc (a missing or unreadable source?); left in place rather than guessed at"
    return 1
  fi
  if rm -f "$path" 2>/dev/null && [ ! -e "$path" ] && [ ! -L "$path" ]; then
    warn "removed the STALE $path — a loud failure now, not a silently stale $label, serves the ~/.zuvo driver"
    return 0
  fi
  INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      stale $label: $path — could not be removed; the ~/.zuvo driver may still load it"
  fail "a STALE $path could not be removed — the ~/.zuvo driver may still load it as the current $label (remove it by hand)"
  return 1
}

install_zuvo_home() {
  echo ""
  echo "======================================"
  echo "  ZUVO HOME (~/.zuvo)"
  echo "======================================"

  mkdir -p "$HOME/.zuvo"

  if ! install_refactor_radar_bundle; then
    INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + 1))
    INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL} refactor-radar bundle"
  fi

  # The shared codex/claude reviewer runner (scripts/lib/model-subprocess.sh) — BEFORE the loop below
  # installs ~/.zuvo/adversarial-review, so a review starting mid-install never runs the new driver
  # without it. Two places, both verified, both atomic, a miss counted for INSTALL INCOMPLETE:
  #   ~/.zuvo/lib/ — every regular file of scripts/lib/, through the same helper as the hosts. The
  #     driver looks here FIRST (<dir>/lib/ → <dir>/ → ~/.zuvo/), so a stale copy here (an older
  #     install, a manual copy) silently shadowed the fresh flat one on every review; now this
  #     candidate is always the fresh one.
  #   ~/.zuvo/model-subprocess.sh — the flat copy: the last candidate of EVERY driver, which is what
  #     an already-installed host driver with no lib/ of its own resolves.
  # Both statuses are captured (a miss is counted by the step that failed, and must not abort the
  # rest of the install under the main run's set -e), and the ✓ names only what really installed:
  # the first version discarded the lib status and claimed ~/.zuvo/lib/ even when all of it failed.
  local _zlib_ok=1 _zms_ok=1 _zms_reason
  install_runner_lib "zuvo home (runner lib)" "$ZUVO_DIR/scripts/lib" "$HOME/.zuvo" || _zlib_ok=0
  if ! _zms_reason="$(install_file_atomic "$ZUVO_DIR/scripts/lib/model-subprocess.sh" "$HOME/.zuvo/model-subprocess.sh")"; then
    _zms_ok=0
    INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + 1))
    INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      shared reviewer runner: $HOME/.zuvo/model-subprocess.sh — $_zms_reason"
    fail "model-subprocess.sh (the shared codex/claude runner) did NOT install to ~/.zuvo ($_zms_reason) — drivers that fall back to it lose their codex and claude lanes"
  fi
  if [ "$_zlib_ok" -eq 1 ] && [ "$_zms_ok" -eq 1 ]; then
    ok "model-subprocess.sh installed (~/.zuvo/model-subprocess.sh + ~/.zuvo/lib/)"
  elif [ "$_zlib_ok" -eq 1 ]; then
    ok "shared libraries installed (~/.zuvo/lib/ only; the flat ~/.zuvo/model-subprocess.sh failed, above)"
  else
    # _zlib_ok=0 here, whether or not _zms_ok — independent of the flat copy's own outcome, so the
    # sweep below runs EITHER way. The original two-armed elif dropped the "both failed" combination
    # entirely (no ok/fail line, no sweep); this is the fix.
    [ "$_zms_ok" -eq 1 ] && ok "model-subprocess.sh installed (~/.zuvo/model-subprocess.sh only)"
    fail "~/.zuvo/lib/ did NOT fully install (the libraries named above) — the ~/.zuvo driver, and every library it loads, looks there FIRST"
    # named + said above; must not abort the rest under set -e. EVERY regular file of scripts/lib/,
    # not only model-subprocess.sh: a stale ~/.zuvo/lib/blind-audit-panel.sh (or any other library)
    # would shadow its fresh flat fallback exactly the way a stale ~/.zuvo/lib/model-subprocess.sh
    # once did — one loop, one message per file actually removed. model-subprocess.sh keeps its
    # historical "runner" label (existing messages/tests name it); every other file is a "library".
    local _zlib_src _zlib_label
    for _zlib_src in "$ZUVO_DIR"/scripts/lib/*; do
      [ -f "$_zlib_src" ] || continue
      case "${_zlib_src##*/}" in
        model-subprocess.sh) _zlib_label="runner" ;;
        *) _zlib_label="library" ;;
      esac
      _zuvo_home_drop_stale "$_zlib_label" "$HOME/.zuvo/lib/${_zlib_src##*/}" "$_zlib_src" || :
    done
  fi

  # blind-coverage-audit.md (the STRICT protocol) and the FLAT ~/.zuvo/blind-audit-panel.sh (the
  # library's own second candidate) — both needed for the blind-audit panel to run standalone from the
  # installed ~/.zuvo/adversarial-review (docs/specs/2026-09-25-blind-audit-panel-plan.md, Task 7).
  # scripts/lib/blind-audit-panel.sh already reaches ~/.zuvo/lib/ through install_runner_lib above (it
  # ships every regular file of scripts/lib/, and the driver's ~/.zuvo/lib/ candidate is checked
  # first) — but two more copies are needed:
  #   - the PROTOCOL is a shared/includes/ file, outside scripts/lib/, so it needs its own copy here.
  #     bap_find_protocol (scripts/lib/blind-audit-panel.sh) falls back to
  #     $HOME/.zuvo/blind-coverage-audit.md — its LAST candidate, nothing further — only when the
  #     driver's own <driver_dir>/../shared/includes/ candidate does not qualify (it requires
  #     <driver_dir>/../skills to exist), exactly the case for ~/.zuvo/adversarial-review, installed
  #     flat with no ../skills beside it;
  #   - the FLAT ~/.zuvo/blind-audit-panel.sh mirrors model-subprocess.sh's own <dir>/lib/ -> <dir>/ ->
  #     ~/.zuvo/ lookup order: when ~/.zuvo/lib/ fails to install (the model-subprocess.sh C-5 scenario
  #     above), model-subprocess.sh still has its flat fallback here, but without this copy the panel
  #     library would not, and --mode blind-audit would break exactly where model-subprocess.sh does not.
  # A FAILED install of either must not leave an OLDER copy in place: the driver would silently load a
  # stale protocol that no longer matches the panel library's validator (every answer invalid) or a
  # stale library, while the install only said "failed" — _zuvo_home_drop_stale removes it so the
  # failure stays loud (no protocol/library to fall back on) instead of silently wrong.
  local _zproto_reason
  if ! _zproto_reason="$(install_file_atomic "$ZUVO_DIR/shared/includes/blind-coverage-audit.md" "$HOME/.zuvo/blind-coverage-audit.md")"; then
    INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + 1))
    INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      blind-audit protocol: $HOME/.zuvo/blind-coverage-audit.md — $_zproto_reason"
    fail "blind-coverage-audit.md (the blind-audit panel's protocol) did NOT install to ~/.zuvo ($_zproto_reason) — the installed driver's --mode blind-audit has no protocol to fall back to"
    _zuvo_home_drop_stale "blind-audit protocol" "$HOME/.zuvo/blind-coverage-audit.md" "$ZUVO_DIR/shared/includes/blind-coverage-audit.md" || :
  else
    ok "blind-coverage-audit.md installed (~/.zuvo/blind-coverage-audit.md — blind-audit panel protocol)"
  fi
  local _zbap_reason
  if ! _zbap_reason="$(install_file_atomic "$ZUVO_DIR/scripts/lib/blind-audit-panel.sh" "$HOME/.zuvo/blind-audit-panel.sh")"; then
    INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + 1))
    INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      blind-audit panel library (flat): $HOME/.zuvo/blind-audit-panel.sh — $_zbap_reason"
    fail "blind-audit-panel.sh (flat) did NOT install to ~/.zuvo ($_zbap_reason) — if ~/.zuvo/lib/ also fails, --mode blind-audit has no library left to fall back to"
    _zuvo_home_drop_stale "blind-audit panel library" "$HOME/.zuvo/blind-audit-panel.sh" "$ZUVO_DIR/scripts/lib/blind-audit-panel.sh" || :
  else
    ok "blind-audit-panel.sh installed (~/.zuvo/blind-audit-panel.sh — flat fallback for the panel library)"
  fi

  # Install EVERY helper in scripts/zuvo-home/ — a loop, not a per-file block. The explicit list
  # this replaces had silently drifted: retro-mine.py, retro-mine-weekly.sh and rotate-retros-cron.sh
  # were versioned in the repo but never installed, so a fresh machine got the file in git and
  # nothing in ~/.zuvo. Adding a helper must not require remembering to add an install block.
  local _installed=0 _skipped=0
  # `scripts/adversarial-review.sh` is appended to the loop's input even though it
  # does not live in scripts/zuvo-home/ — it is also shipped as bin/adversarial-review,
  # so it cannot simply be moved. It belongs in ~/.zuvo/ for the same reason every
  # helper here does, and its absence was a real fleet-wide outage:
  #
  # Claude Code puts {installPath}/bin on PATH ONCE, at session start. A release
  # creates a new cache dir and removes the old one, so every session that was open
  # across a release has a PATH entry pointing at a deleted directory and
  # `adversarial-review` becomes "command not found" mid-run. Measured 2026-08-05
  # after four same-day releases (1.6.53 -> .57): a live session's PATH still held
  # .../zuvo/1.6.53/bin while only 1.6.56 and 1.6.57 existed on disk. That is the
  # "adversarial doesn't work" agents were reporting — not a provider problem.
  #
  # ~/.zuvo/ is version-independent, which is exactly why append-runlog,
  # build-review-patch and verify-plan-dag already live here and never break this way.
  # review-artifact-sync.sh joins them for the same reason, one level up: it is the documented
  # remedy when the pre-push gate blocks because the review pair lives in another checkout, and
  # every skill that names it used a REPO-RELATIVE path (`scripts/review-artifact-sync.sh`). That
  # path exists only inside zuvo-plugin — in the repo the agent is actually shipping, the
  # remediation command a blocked run prints did not exist. It keeps its `.sh` (callers use it).
  # shared/includes/model-registry.sh joins the list for the same reason adversarial-review.sh
  # did: ~/.zuvo/adversarial-review resolves the registry relative to ITSELF, so on that layout
  # `../shared/includes/` is ~/shared/includes/ — a path that has never existed. The registry was
  # therefore never loaded on the path that actually runs, and every model id came from the
  # in-script fallbacks. Editing model-registry.sh alone changed nothing at runtime, silently,
  # because a missing include is skipped rather than reported.
  # (scripts/lib/model-subprocess.sh, the driver's runner, is installed ABOVE, before this loop.)
  # scripts/reviewer-model-route.sh joins the list for ~/.zuvo/model-run (plan C Task 5; itself a
  # scripts/zuvo-home helper): model-run looks for the router BESIDE itself, and in ~/.zuvo that is
  # here. Installed flat, the router finds its runner in ~/.zuvo/lib/ and its registry as
  # ~/.zuvo/model-registry.sh — both installed by this function. The pair is cmp-verified below.
  for _src in "$ZUVO_DIR"/scripts/zuvo-home/* "$ZUVO_DIR"/scripts/adversarial-review.sh \
              "$ZUVO_DIR"/scripts/review-artifact-sync.sh "$ZUVO_DIR"/scripts/reviewer-model-route.sh \
              "$ZUVO_DIR"/hooks/lib/refactor-state.py \
              "$ZUVO_DIR"/hooks/lib/refactor-gate-lib.sh "$ZUVO_DIR"/hooks/lib/agent-env.sh \
              "$ZUVO_DIR"/shared/includes/model-registry.sh; do
    [[ -f "$_src" ]] || continue
    local _name; _name="$(basename "$_src")"
    case "$_name" in *.pyc|__pycache__|.*) continue ;; esac
    # Installed WITHOUT the .sh, matching how every skill and the bin wrapper name
    # it. The other *.sh helpers in zuvo-home keep their extension (callers use it),
    # so this is a targeted rename, not a blanket strip.
    [[ "$_name" == "adversarial-review.sh" ]] && _name="adversarial-review"
    # Copy to a temp name and mv into place: `cp` over a LIVE executable truncates it first, so a
    # helper running from cron at that moment reads a half-written file. mv within one filesystem
    # is atomic. (Not a regression from the loop — the per-file blocks used a plain cp too — but
    # cheap to get right while the code is being touched.)
    if cp "$_src" "$HOME/.zuvo/.$_name.tmp.$$" 2>/dev/null; then
      # Executable bit follows the SOURCE, not a blanket +x. chmod'ing every regular file turned
      # any future data/README dropped into scripts/zuvo-home/ into a runnable user command.
      if [[ -x "$_src" ]]; then chmod +x "$HOME/.zuvo/.$_name.tmp.$$" 2>/dev/null || true; fi
      mv -f "$HOME/.zuvo/.$_name.tmp.$$" "$HOME/.zuvo/$_name" 2>/dev/null || {
        rm -f "$HOME/.zuvo/.$_name.tmp.$$" 2>/dev/null
        warn "$_name not installed (~/.zuvo/$_name) — atomic replace failed"
        _skipped=$((_skipped + 1)); continue
      }
      # Per-helper line, not just a count: the install log is how you find out WHICH helper
      # failed to land. Dropping it for a tidy summary lost real information (and an outcome
      # test caught it), so the loop keeps the same message shape the per-file blocks emitted.
      ok "$_name installed (~/.zuvo/$_name)"
      _installed=$((_installed + 1))
    else
      warn "$_name not installed (~/.zuvo/$_name) — copy failed"
      _skipped=$((_skipped + 1))
    fi
  done
  # refactor-contract resolves its reader and check gate beside itself. These canonical
  # dependencies must travel with every helper install, including Codex-only installs;
  # falling back to another platform's older hooks silently revives obsolete checks.
  for _name in refactor-state.py refactor-gate-lib.sh agent-env.sh; do
    if ! cmp -s "$ZUVO_DIR/hooks/lib/$_name" "$HOME/.zuvo/$_name"; then
      INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + 1))
      INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL} refactor-contract dependency: $HOME/.zuvo/$_name"
      fail "refactor-contract dependency $_name did not match the canonical source"
    fi
  done
  # ~/.zuvo/model-run, the router it calls, the registry that router reads its ids from, and the
  # test-audit batch script that runs model-run must be the CURRENT set. The loop above only warns on a
  # failed copy; here a mismatch is counted for INSTALL INCOMPLETE, and a stale copy is removed — an old
  # router answers from its old routing table and an old registry hands it old model ids, the very
  # thing model-run exists to replace, while a missing one fails loudly: model-run answers
  # status=unavailable (route=no-router, or routing-failed without a registry) into the caller's
  # labelled fallback, and a missing batch script is "command not found", never an older dispatch.
  # (The router's runner library is verified where it is installed, above: install_runner_lib for
  # ~/.zuvo/lib/ and install_file_atomic for the flat ~/.zuvo/model-subprocess.sh both cmp the copy.)
  local _mr_pair _mr_src _mr_dst
  for _mr_pair in scripts/reviewer-model-route.sh:reviewer-model-route.sh scripts/zuvo-home/model-run:model-run \
                  shared/includes/model-registry.sh:model-registry.sh \
                  scripts/zuvo-home/test-audit-batch:test-audit-batch; do
    _mr_src="$ZUVO_DIR/${_mr_pair%%:*}"; _mr_dst="$HOME/.zuvo/${_mr_pair#*:}"
    if ! cmp -s "$_mr_src" "$_mr_dst"; then
      INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + 1))
      INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      cross-vendor reviewer: $_mr_dst — does not match ${_mr_pair%%:*}"
      fail "~/.zuvo/${_mr_pair#*:} did not install byte-identical to ${_mr_pair%%:*} — ~/.zuvo/model-run --route cannot run the current route"
      _zuvo_home_drop_stale "cross-vendor reviewer (${_mr_pair#*:})" "$_mr_dst" "$_mr_src" || :
    fi
  done
  if [[ "$_skipped" -gt 0 ]]; then
    ok "$_installed zuvo-home helpers installed to ~/.zuvo/ ($_skipped skipped)"
  else
    ok "$_installed zuvo-home helpers installed to ~/.zuvo/"
  fi

  # portable.sh must sit NEXT TO the helpers: retro-mine-weekly.sh / rotate-retros-cron.sh /
  # runlog-sync.sh source it as "$(dirname "$0")/portable.sh" to resolve a Python 3 interpreter,
  # and `python3` is not a command on Windows.
  if [[ -f "$ZUVO_DIR/scripts/lib/portable.sh" ]]; then
    cp "$ZUVO_DIR/scripts/lib/portable.sh" "$HOME/.zuvo/.portable.sh.tmp.$$" 2>/dev/null \
      && mv -f "$HOME/.zuvo/.portable.sh.tmp.$$" "$HOME/.zuvo/portable.sh" \
      && ok "portable.sh installed (~/.zuvo/portable.sh — sed_i + zuvo_python)"
  fi

  # retro-appendonly.sh sits NEXT TO the helpers for the same reason portable.sh does:
  # append-retro / rotate-retros source it as "$(dirname "$0")/retro-appendonly.sh".
  if [[ -f "$ZUVO_DIR/scripts/lib/retro-appendonly.sh" ]]; then
    cp "$ZUVO_DIR/scripts/lib/retro-appendonly.sh" "$HOME/.zuvo/.retro-appendonly.sh.tmp.$$" 2>/dev/null \
      && mv -f "$HOME/.zuvo/.retro-appendonly.sh.tmp.$$" "$HOME/.zuvo/retro-appendonly.sh" \
      && ok "retro-appendonly.sh installed (~/.zuvo/retro-appendonly.sh)"
  fi

  # ARM the append-only flag on the retro files, on EVERY install — not just the first.
  #
  # Between 2026-08-17 and 2026-09-17 retros.log was truncated to ~101 rows six times by a writer
  # the forensics job structurally cannot name (it samples the process table up to 10s late, while
  # `head+tail+mv` takes milliseconds; in three of the six incidents its suspects table is empty).
  # `chflags uappnd` does not need to know the writer: the kernel refuses every non-append write,
  # so the recipe fails with an error naming the file instead of silently destroying history.
  #
  # Re-arming every run is the point. The flag is on the inode, so each legitimate atomic replace
  # drops it; a one-shot install would leave the protection quietly off after the first rotation.
  # append-retro re-arms on every append for the same reason. macOS only — Linux's `chattr +a`
  # needs root, which no zuvo helper has — and it never fails the install.
  if [[ "$(uname -s)" == "Darwin" ]] && command -v chflags >/dev/null 2>&1; then
    _armed=0
    for _rf in "$HOME/.zuvo/retros.log" "$HOME/.zuvo/retros.md"; do
      [[ -f "$_rf" ]] && chflags uappnd "$_rf" 2>/dev/null && _armed=$((_armed + 1))
    done
    [[ "$_armed" -gt 0 ]] && ok "retro files armed append-only ($_armed file(s) — uappnd)"
  fi

  # Local, NEVER-versioned config for host-coupled helpers (collector SSH target). Created empty
  # so the file exists to edit; the helpers fail loudly with instructions when it has no host.
  if [[ ! -f "$HOME/.zuvo/collector.conf" ]]; then
    cat > "$HOME/.zuvo/collector.conf" <<'CONF'
# ~/.zuvo/collector.conf — machine-local, NOT in git (it names a private host).
# Set this to the telemetry collector's SSH target to enable backlog/runlog/popebot sync.
# ZUVO_COLLECTOR_SSH=user@host
CONF
    chmod 600 "$HOME/.zuvo/collector.conf"
    ok "collector.conf stub created (~/.zuvo/collector.conf — set ZUVO_COLLECTOR_SSH to enable sync)"
  fi

  # B-9 (v1.3.109): per-platform `zuvo-home` subcommand is a pre-existing gap
  # affecting ALL zuvo-home helpers equally; out of scope for v1.3.110.
  # NOTE: ~/.zuvo is the SHARED cross-platform helper dir. These zuvo-home
  # helpers (incl. retro-stub) reach Claude/Codex/Cursor via THIS function
  # only — build-codex-skills.sh / build-cursor-skills.sh deliberately do NOT
  # copy scripts/zuvo-home (verified). install_zuvo_home runs in the default
  # `all`/`both` dispatch (the documented canonical install). Do not add a
  # zuvo-home copy to the per-platform build scripts.
}
