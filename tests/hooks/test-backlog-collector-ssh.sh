#!/usr/bin/env bash
# Tests scripts/zuvo-home/backlog — what `sync` and `pull` do when the collector cannot be reached.
#
# Both read the collector over ssh. Neither looked at how ssh ended: `sync` exported whatever came
# back (an EMPTY token after a failed connection) to backlog-collect.py, which then pushed with no
# credential; `pull` treated the empty output of a failed connection as "the fleet has no backlog"
# and REWROTE the local index to zero items. A collector that cannot be reached must leave the index
# as it was and say so by name, with a non-zero exit.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BL="$ROOT/scripts/zuvo-home/backlog"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

mkdir -p "$TMP/bin" "$TMP/zuvo"
# An ssh that cannot connect: ssh's own failure status is 255.
printf '#!/bin/sh\necho "ssh: connect to host fake-collector port 22: Connection refused" >&2\nexit 255\n' > "$TMP/bin/ssh"
chmod +x "$TMP/bin/ssh"
# backlog-collect.py stand-in: proves whether sync went on to push.
printf 'import os\nopen(os.path.join(os.environ["ZUVO_DIR"], "collect-ran"), "w").write(os.environ.get("CODESIFT_COLLECTOR_TOKEN", ""))\n' \
  > "$TMP/zuvo/backlog-collect.py"
printf '{"host":"mac","repo":"r","item_id":"B-1","status":"open","text":"kept"}\n' > "$TMP/zuvo/backlog-index.jsonl"
before="$(cat "$TMP/zuvo/backlog-index.jsonl")"

run_bl() { # run_bl <cmd> -> rc in $rc, stderr in $TMP/err
  env -u CODESIFT_COLLECTOR_TOKEN -u ZUVO_COLLECTOR_TOKEN PATH="$TMP/bin:$PATH" ZUVO_DIR="$TMP/zuvo" \
    ZUVO_COLLECTOR_SSH=fake-collector python3 "$BL" "$1" > "$TMP/out" 2> "$TMP/err"
  rc=$?
}

echo "=== sync, collector unreachable ==="
run_bl sync
[ "$rc" -ne 0 ] && ok "sync exits non-zero" || bad "sync exited 0 after the token fetch failed"
grep -q 'collector' "$TMP/err" && ok "the failure is named on stderr" || bad "no named failure: $(cat "$TMP/err")"
[ ! -e "$TMP/zuvo/collect-ran" ] && ok "backlog-collect.py was not run without a token" \
  || bad "backlog-collect.py ran (token: [$(cat "$TMP/zuvo/collect-ran")])"
[ "$(cat "$TMP/zuvo/backlog-index.jsonl")" = "$before" ] && ok "the index is unchanged" || bad "sync rewrote the index"

echo "=== pull, collector unreachable ==="
run_bl pull
[ "$rc" -ne 0 ] && ok "pull exits non-zero" || bad "pull exited 0 after ssh failed"
grep -q 'collector' "$TMP/err" && ok "the failure is named on stderr" || bad "no named failure: $(cat "$TMP/err")"
[ "$(cat "$TMP/zuvo/backlog-index.jsonl")" = "$before" ] && ok "the index is unchanged" \
  || bad "pull rewrote the index to [$(cat "$TMP/zuvo/backlog-index.jsonl")]"

echo "=== pull, collector reachable with no data ==="
# A reachable collector with no backlog files yet is a real, empty answer — not a failure.
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/ssh"
run_bl pull
[ "$rc" -eq 0 ] && ok "an empty collector is not an error" || bad "pull failed on an empty collector: $(cat "$TMP/err")"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
