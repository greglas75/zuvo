#!/bin/bash
# Post-commit hook: adds new commit to review-backlog.md in Claude memory dir.
#
# Install per-project:
#   cp ~/.claude/scripts/post-commit-review-backlog.sh .git/hooks/post-commit
#   chmod +x .git/hooks/post-commit
#
# Or append to existing .git/hooks/post-commit:
#   echo 'bash ~/.claude/scripts/post-commit-review-backlog.sh' >> .git/hooks/post-commit
#
# The hook computes the Claude memory directory from the project root path.
# Format: ~/.claude/projects/<sanitized-project-path>/memory/review-backlog.md

# Don't block commits if this fails
set +e

# Compute Claude memory directory from project root
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
SANITIZED="$(echo "$PROJECT_ROOT" | tr '/' '-')"
MEMORY_DIR="$HOME/.claude/projects/${SANITIZED}/memory"
BACKLOG="$MEMORY_DIR/review-backlog.md"

# Get commit info
HASH=$(git rev-parse --short HEAD 2>/dev/null) || exit 0
FULL_HASH=$(git rev-parse HEAD 2>/dev/null) || exit 0
MESSAGE=$(git log -1 --format='%s' HEAD 2>/dev/null) || exit 0
AUTHOR=$(git log -1 --format='%an' HEAD 2>/dev/null) || exit 0
DATE=$(git log -1 --format='%ci' HEAD 2>/dev/null | cut -d' ' -f1) || exit 0
STAT=$(git diff --stat HEAD~1..HEAD 2>/dev/null | tail -1 | sed 's/^ *//' ) || STAT=""

# Create backlog file if it doesn't exist
if [ ! -f "$BACKLOG" ]; then
  mkdir -p "$MEMORY_DIR"
  cat > "$BACKLOG" << 'EOF'
# Review Backlog

Commits pending review. Managed by post-commit hook + /review skill.

## Unreviewed

EOF
fi

# Add to backlog if not already there (e.g., skip on amend)
BACKLOG_DONE=0
if grep -q "^- \[ \] ${HASH} " "$BACKLOG" 2>/dev/null; then
  BACKLOG_DONE=1
fi

if [ "$BACKLOG_DONE" -eq 0 ]; then
# Insert new entry after "## Unreviewed" + blank line
export CCT_HASH="$HASH"
export CCT_MSG="$MESSAGE"
TEMP=$(mktemp)

awk '
  /^## Unreviewed$/ { found=1; print; next }
  found && !inserted && /^$/ {
    print
    print "- [ ] " ENVIRON["CCT_HASH"] " " ENVIRON["CCT_MSG"]
    inserted=1
    next
  }
  found && !inserted && /^- / {
    print "- [ ] " ENVIRON["CCT_HASH"] " " ENVIRON["CCT_MSG"]
    inserted=1
  }
  { print }
  END {
    if (found && !inserted)
      print "- [ ] " ENVIRON["CCT_HASH"] " " ENVIRON["CCT_MSG"]
  }
' "$BACKLOG" > "$TEMP" && mv "$TEMP" "$BACKLOG"
fi  # BACKLOG_DONE

# ── Part 2: Project-local docs/review-queue.md (in-repo, visible) ──

QUEUE="$PROJECT_ROOT/docs/review-queue.md"

# Only write if docs/ dir exists (opt-in per project — create docs/ to enable)
if [ -d "$PROJECT_ROOT/docs" ]; then

  # Create queue file if it doesn't exist
  if [ ! -f "$QUEUE" ]; then
    cat > "$QUEUE" << 'QEOF'
# Review Queue

Commits pending review. Auto-managed:
- post-commit hook → adds new commits
- `/review` after audit → removes reviewed commits
- `/review mark-reviewed` → removes in bulk

QEOF
  fi

  # Only add if NOT already reviewed, NOT already in queue, and NOT a
  # commit that only touches the queue file itself (would create an
  # infinite append→modify→commit→append loop).
  CHANGED_FILES=$(git show --name-only --format='' "$FULL_HASH" 2>/dev/null | grep -v '^$' | sort -u)
  if git tag --points-at "$FULL_HASH" 2>/dev/null | grep -q '^review'; then
    : # already reviewed — don't add
  elif grep -q "${HASH}" "$QUEUE" 2>/dev/null; then
    : # already in queue
  elif [ "$CHANGED_FILES" = "docs/review-queue.md" ]; then
    : # commit only updates the queue itself — skip to avoid self-referential loop
  else
    echo "- ${HASH} (${DATE}) ${MESSAGE}" >> "$QUEUE"
  fi

fi

exit 0
