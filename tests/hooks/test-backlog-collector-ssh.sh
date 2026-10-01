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

echo "=== sync, collector reachable but holds no token ==="
# ssh succeeded and printed nothing: a real answer, and the answer is "no token" — still no push.
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/ssh"
run_bl sync
[ "$rc" -ne 0 ] && ok "sync exits non-zero" || bad "sync exited 0 with an empty token"
grep -q 'no CODESIFT_COLLECTOR_TOKEN' "$TMP/err" && ok "the missing token is named" || bad "no named failure: $(cat "$TMP/err")"
[ ! -e "$TMP/zuvo/collect-ran" ] && ok "backlog-collect.py was not run with an empty token" \
  || bad "backlog-collect.py ran (token: [$(cat "$TMP/zuvo/collect-ran")])"

echo "=== pull, collector reachable with no data ==="
# A reachable collector with no backlog files yet is a real, empty answer — not a failure. The fake runs the
# remote command for real, with the collector's data dir pointed at an empty local one: `cat <dir>/*.jsonl`
# then fails as it does on a collector with no files, and only the command's own `|| true` makes that empty.
mkdir -p "$TMP/no-data"
cat > "$TMP/bin/ssh" <<EOF
#!/bin/sh
for a; do last="\$a"; done
exec /bin/sh -c "\$(printf '%s' "\$last" | sed 's#/home/gha/telemetry-collector/data/backlog#$TMP/no-data#g')"
EOF
run_bl pull
[ "$rc" -eq 0 ] && ok "an empty collector is not an error" || bad "pull failed on an empty collector: $(cat "$TMP/err")"
printf '{"host":"mac","repo":"r","item_id":"B-1","status":"open","text":"kept"}\n' > "$TMP/zuvo/backlog-index.jsonl"

echo "=== pull, no ssh client on PATH ==="
mkdir -p "$TMP/nossh"
env -u CODESIFT_COLLECTOR_TOKEN -u ZUVO_COLLECTOR_TOKEN PATH="$TMP/nossh" ZUVO_DIR="$TMP/zuvo" \
  ZUVO_COLLECTOR_SSH=fake-collector "$(command -v python3)" "$BL" pull > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && ok "pull exits non-zero" || bad "pull exited 0 with no ssh to run"
grep -q 'could not run ssh to the collector' "$TMP/err" && ok "the missing client is named" || bad "no named failure: $(cat "$TMP/err")"
[ "$(cat "$TMP/zuvo/backlog-index.jsonl")" = "$before" ] && ok "the index is unchanged" \
  || bad "pull rewrote the index to [$(cat "$TMP/zuvo/backlog-index.jsonl")]"

echo "=== pull, no collector configured ==="
mkdir -p "$TMP/home/.zuvo"
env -u CODESIFT_COLLECTOR_TOKEN -u ZUVO_COLLECTOR_TOKEN -u ZUVO_COLLECTOR_SSH PATH="$TMP/bin:$PATH" HOME="$TMP/home" \
  ZUVO_HOME="$TMP/home/.zuvo" ZUVO_DIR="$TMP/zuvo" python3 "$BL" pull > "$TMP/out" 2> "$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && ok "pull exits non-zero" || bad "pull exited 0 with no collector configured"
grep -q 'no collector host configured' "$TMP/err" && ok "the missing configuration is named" || bad "no named failure: $(cat "$TMP/err")"
[ "$(cat "$TMP/zuvo/backlog-index.jsonl")" = "$before" ] && ok "the index is unchanged" \
  || bad "pull rewrote the index to [$(cat "$TMP/zuvo/backlog-index.jsonl")]"

echo "=== a collector that does not answer in time ==="
# collector_ssh takes the timeout as an argument, so the timeout path is driven directly with 1 s against an
# ssh that hangs, instead of waiting out pull's 120 s.
printf '#!/bin/sh\nexec sleep 30\n' > "$TMP/bin/ssh"
to_out="$(PATH="$TMP/bin:$PATH" ZUVO_DIR="$TMP/zuvo" ZUVO_COLLECTOR_SSH=fake-collector python3 - "$BL" <<'PY' 2>&1
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("backlog", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("backlog", loader))
loader.exec_module(m)
try:
    out = m.collector_ssh("true", 1, "probe the timeout")
except SystemExit as e:
    print(f"EXIT {e.code}")
else:
    print(f"RETURNED {out!r}")
PY
)"
case "$to_out" in
  *"EXIT backlog: the collector fake-collector did not answer within 1s"*) ok "a timeout exits, named" ;;
  *) bad "a timeout: $to_out" ;;
esac

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
