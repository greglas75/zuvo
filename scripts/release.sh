#!/usr/bin/env bash
# Alias for dev-push.sh — kept for backwards compatibility
# Usage: ./scripts/release.sh patch "description"
#        ./scripts/release.sh minor "description"
exec "$(dirname "$0")/dev-push.sh" "${2:-}" "${1:-patch}"
