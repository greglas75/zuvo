#!/usr/bin/env bash
# sync-popebot.sh — Mac <-> ThePopeBot bots zuvo-state sync (single-SSH tar pipes, fast).
# Bot HOMEs are host bind-mounts: /root/bot/data/workspaces/workspace-* -> /home/coding-agent,
# so files landed on the host appear inside containers with no Docker changes.
set -u
. "$(dirname "$0")/zuvo-collector-host.sh"
zuvo_collector_host || exit 0
VPS="$ZUVO_COLLECTOR_SSH"
WSROOT="/root/bot/data/workspaces"
LOCAL_REMOTE="$HOME/.zuvo/remote/popebot"
mkdir -p "$LOCAL_REMOTE"

# 0) aggregate ideas from all Mac repos
AGG=$(mktemp)
{
  echo "# Aggregated memory/ideas.md from Mac projects ($(date -u +%F))"
  for f in "$HOME"/DEV/*/memory/ideas.md "$HOME"/DEV/*/*/memory/ideas.md; do
    [ -f "$f" ] || continue
    proj=${f#"$HOME"/DEV/}; proj=${proj%%/memory/*}
    echo; echo "## $proj"; grep '^-' "$f" 2>/dev/null | tail -20
  done
} > "$AGG"

# 1) PUSH: one tar with mac state + helpers -> VPS fans it out to every workspace
STAGE=$(mktemp -d); mkdir -p "$STAGE/mac" "$STAGE/helpers"
for f in retros.md retros.log runs.log; do cp "$HOME/.zuvo/$f" "$STAGE/mac/" 2>/dev/null; done
cp "$AGG" "$STAGE/mac/ideas-aggregate.md"
for h in append-retro append-runlog retro-stub verify-audit profile-session.py; do
  cp "$HOME/.zuvo/$h" "$STAGE/helpers/" 2>/dev/null
done
tar -C "$STAGE" -czf - . | ssh -o ConnectTimeout=10 "$VPS" '
  T=$(mktemp -d) && tar -C "$T" -xzf - || exit 1
  for WS in '"$WSROOT"'/workspace-*; do
    [ -d "$WS" ] || continue
    mkdir -p "$WS/.zuvo/remote/mac"
    cp "$T"/mac/* "$WS/.zuvo/remote/mac/" 2>/dev/null
    for h in "$T"/helpers/*; do
      b=$(basename "$h")
      [ -e "$WS/.zuvo/$b" ] || { cp "$h" "$WS/.zuvo/$b" && chmod +x "$WS/.zuvo/$b"; }
    done
  done
  rm -rf "$T"
  ls -d '"$WSROOT"'/workspace-* | wc -l
' > /tmp/zuvo-sync-ws-count 2>/dev/null || { echo "SYNC FAIL: push"; rm -rf "$STAGE" "$AGG"; exit 1; }

# 2) PULL: one tar of every workspace's own zuvo logs -> ~/.zuvo/remote/popebot/<id>/
ssh "$VPS" '
  cd '"$WSROOT"' || exit 0
  FILES=""
  for WS in workspace-*; do
    for f in retros.log retros.md runs.log; do
      [ -f "$WS/.zuvo/$f" ] && FILES="$FILES $WS/.zuvo/$f"
    done
    # repo-level ideas/backlog z projektów botow (workspace/<repo>/memory/*.md, 2 poziomy)
    for m in "$WS"/workspace/memory/ideas.md "$WS"/workspace/memory/backlog.md              "$WS"/workspace/*/memory/ideas.md "$WS"/workspace/*/memory/backlog.md; do
      [ -f "$m" ] && FILES="$FILES $m"
    done
  done
  [ -n "$FILES" ] && tar -czf - $FILES || tar -czf - --files-from /dev/null
' | tar -C "$LOCAL_REMOTE" -xzf - 2>/dev/null
# normalize: workspace-<id>/{.zuvo/*, workspace/**} -> <id>/{*, repos/**}
for d in "$LOCAL_REMOTE"/workspace-*; do
  [ -d "$d" ] || continue
  id=${d##*/workspace-}; mkdir -p "$LOCAL_REMOTE/$id"
  [ -d "$d/.zuvo" ] && mv "$d/.zuvo/"* "$LOCAL_REMOTE/$id/" 2>/dev/null
  [ -d "$d/workspace" ] && mkdir -p "$LOCAL_REMOTE/$id/repos" && cp -R "$d/workspace/." "$LOCAL_REMOTE/$id/repos/" 2>/dev/null
  rm -rf "$d"
done
rm -rf "$STAGE" "$AGG"
echo "SYNC OK: $(cat /tmp/zuvo-sync-ws-count 2>/dev/null || echo '?') workspaces @ $(date -u +%H:%MZ)"
