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

# A registry that exists but does not parse (a half-written file, a concurrent writer) says nothing
# about which dirs it names: pruning on it would delete dirs project entries still load.
B2="$TMP/c2/zuvo"; R2="$TMP/c2/installed_plugins.json"
for v in 1.6.90 1.6.114 1.6.115; do mkdir -p "$B2/$v/.claude-plugin"; printf '{}\n' > "$B2/$v/.claude-plugin/plugin.json"; done
printf '{"version": 2, "plugins": {"zuvo@zuvo-marketplace": [{"installPath": "%s/1.6.90"' "$B2" > "$R2"
python3 "$PY" prune "$R2" "$B2" 1.6.115 >/dev/null 2>&1; rc=$?
[ -d "$B2/1.6.90" ] && [ "$rc" -ne 0 ] && t_ok "prune removes nothing and fails when the registry does not parse" \
  || t_no "unparseable registry: rc=$rc, left: $(ls "$B2" | tr '\n' ' ')"
rm -f "$R2"
python3 "$PY" prune "$R2" "$B2" 1.6.115 >/dev/null; rc=$?
[ ! -e "$B2/1.6.90" ] && [ "$rc" -eq 0 ] && t_ok "prune treats a missing registry as naming no dir" \
  || t_no "missing registry: rc=$rc, left: $(ls "$B2" | tr '\n' ' ')"

# Marker names: only a plain pid counts. A name that is not one (a temp file, a pid too large for
# os.kill) must neither crash the prune nor be read as "process 0" (os.kill(0, 0) signals the group).
B3="$TMP/c3/zuvo"
for v in 1.6.91 1.6.92 1.6.93 1.6.114 1.6.115; do mkdir -p "$B3/$v/.claude-plugin/" "$B3/$v/.in_use"; printf '{}\n' > "$B3/$v/.claude-plugin/plugin.json"; done
: > "$B3/1.6.91/.in_use/0"
: > "$B3/1.6.92/.in_use/99999999999999999999"
: > "$B3/1.6.93/.in_use/$DEAD.tmp"
python3 "$PY" prune "$TMP/c3/none.json" "$B3" 1.6.115 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$B3/1.6.91" ] && [ ! -e "$B3/1.6.93" ] \
  && t_ok "prune ignores marker names that are not a pid (0, a temp-file suffix)" \
  || t_no "marker names: rc=$rc, left: $(ls "$B3" | tr '\n' ' ')"

# A SHA-named dir (Claude Code creates them beside the version dirs) sorts after every version and
# must not take the newest-other slot from the real previous version.
B4="$TMP/c4/zuvo"
for v in 1.6.113 1.6.114 1.6.115 564a269f; do mkdir -p "$B4/$v/.claude-plugin"; printf '{}\n' > "$B4/$v/.claude-plugin/plugin.json"; done
python3 "$PY" prune "$TMP/c4/none.json" "$B4" 1.6.115 >/dev/null
[ -d "$B4/1.6.114" ] && [ ! -e "$B4/1.6.113" ] && t_ok "prune keeps the newest other VERSION, not a SHA-named dir" \
  || t_no "newest-other floor: left: $(ls "$B4" | tr '\n' ' ')"

# registry only repoints entries that live in this cache; a dev checkout elsewhere is the user's.
R5="$TMP/c5.json"
printf '{"plugins": {"zuvo@zuvo-marketplace": ["junk", {"scope": "local", "installPath": "%s/gone-dev-checkout"}]}}\n' "$TMP" > "$R5"
python3 "$PY" registry "$R5" "$BASE" 1.6.115 "" >/dev/null 2>&1; rc=$?
p5="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plugins"]["zuvo@zuvo-marketplace"][1]["installPath"])' "$R5")"
[ "$rc" -eq 0 ] && [ "$p5" = "$TMP/gone-dev-checkout" ] \
  && t_ok "registry skips a non-object entry and leaves an installPath outside the cache alone" \
  || t_no "registry outside cache: rc=$rc path=$p5"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
