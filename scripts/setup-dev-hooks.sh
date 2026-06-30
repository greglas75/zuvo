#!/bin/sh
# setup-dev-hooks.sh — activate the tracked .githooks/ dir for THIS repo (the one per-clone
# opt-in: core.hooksPath lives in .git/config, which git cannot version). After this, the repo's
# own pushes/commits run the pipeline-entry + work gates — zuvo dogfooding its own gates.
# Idempotent. Fail-open: never errors the dev's setup.
set -u
R=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "[dev-hooks] not a git repo — skip"; exit 0; }
[ -d "$R/.githooks" ] || { echo "[dev-hooks] no .githooks/ dir in this repo — skip"; exit 0; }
chmod +x "$R/.githooks/"* 2>/dev/null || true
cur=$(git -C "$R" config --get core.hooksPath 2>/dev/null || true)
if [ "$cur" = ".githooks" ]; then
  echo "[dev-hooks] core.hooksPath already .githooks (idempotent — nothing to do)"
  exit 0
fi
git -C "$R" config core.hooksPath .githooks || { echo "[dev-hooks] could not set core.hooksPath — skip (fail-open)"; exit 0; }
echo "[dev-hooks] core.hooksPath=.githooks set — this repo's commits/pushes are now gated (pipeline-entry + work-gate)"
[ -n "$cur" ] && echo "[dev-hooks] note: replaced prior core.hooksPath='$cur'"
exit 0
