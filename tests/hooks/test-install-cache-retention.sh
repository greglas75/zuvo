#!/usr/bin/env bash
# The Claude installer removes old plugin version dirs (scripts/install.d/claude_cache.py). It used to
# keep only the 2 newest; on 2026-10-29 sessions on the sessions host that had started on 1.6.112 lost
# every plugin hook ("Plugin directory does not exist") once 1.6.114 and 1.6.115 had been installed,
# and four project-scope registry entries on the Mac pointed at dirs it had already deleted.
# Medium unit test: temporary filesystem only.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY="$ROOT/scripts/install.d/claude_cache.py"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
t_ok() { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
t_no() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

BASE="$TMP/cache/zuvo"; REG="$TMP/installed_plugins.json"
for v in 1.6.83 1.6.110 1.6.112 1.6.113 1.6.114 1.6.115; do
  mkdir -p "$BASE/$v/.claude-plugin"; printf '{}\n' > "$BASE/$v/.claude-plugin/plugin.json"
done
# A pid that is certainly dead: a finished child's.
sh -c 'exit 0' & DEAD=$!; wait "$DEAD"
mkdir -p "$BASE/1.6.112/.in_use" "$BASE/1.6.113/.in_use"
printf '{"pid":%s}\n' "$$" > "$BASE/1.6.112/.in_use/$$"
printf '{"pid":%s}\n' "$DEAD" > "$BASE/1.6.113/.in_use/$DEAD"
cat > "$REG" <<JSON
{"version": 2, "plugins": {"zuvo@zuvo-marketplace": [
  {"scope": "user", "installPath": "$BASE/1.6.115", "version": "1.6.115", "gitCommitSha": "old"},
  {"scope": "project", "projectPath": "/p/a", "installPath": "$BASE/1.6.110", "version": "1.6.110", "gitCommitSha": "old"},
  {"scope": "project", "projectPath": "/p/b", "installPath": "$BASE/1.6.50", "version": "1.6.50", "gitCommitSha": "old"}
]}}
JSON

python3 "$PY" registry "$REG" "$BASE" 1.6.115 newsha >/dev/null
paths="$(python3 -c 'import json,sys; print(" ".join(e["installPath"].rsplit("/",1)[1]+"@"+e["gitCommitSha"] for e in json.load(open(sys.argv[1]))["plugins"]["zuvo@zuvo-marketplace"]))' "$REG")"
if [ "$paths" = "1.6.115@newsha 1.6.110@newsha 1.6.115@newsha" ]; then
  t_ok "registry: an entry on a deleted dir is repointed to the current version, a live one stays"
else t_no "registry entries after heal: $paths"; fi

python3 "$PY" prune "$REG" "$BASE" 1.6.115 >/dev/null
left="$(ls "$BASE" | tr '\n' ' ')"
[ -d "$BASE/1.6.112" ] && t_ok "prune keeps a dir a live session started from, 3 releases back" \
  || t_no "the live session's dir was removed (left: $left)"
[ -d "$BASE/1.6.110" ] && t_ok "prune keeps a dir a registry entry names" \
  || t_no "a registry-named dir was removed (left: $left)"
[ ! -e "$BASE/1.6.113" ] && t_ok "prune removes a dir whose only marker is a dead pid's" \
  || t_no "a dead session's dir was kept (left: $left)"
[ ! -e "$BASE/1.6.83" ] && t_ok "prune removes an unused, unnamed dir" || t_no "an unused dir was kept (left: $left)"
[ -d "$BASE/1.6.114" ] && [ -d "$BASE/1.6.115" ] && t_ok "prune keeps the current and the newest other version" \
  || t_no "current/previous removed (left: $left)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
