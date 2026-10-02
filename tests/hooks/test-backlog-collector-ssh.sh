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
printf 'import os, sys\nopen(os.path.join(os.environ["ZUVO_DIR"], "collect-ran"), "w").write(os.environ.get("CODESIFT_COLLECTOR_TOKEN", ""))\nsys.exit(int(os.environ.get("FAKE_PUSH_RC", "0")))\n' \
  > "$TMP/zuvo/backlog-collect.py"
# The collector root the script under test uses — ONE source, so the fake below cannot drift from it.
CR="$(awk -F'"' '/^COLLECTOR_ROOT = /{print $2; exit}' "$BL")"
[ -n "$CR" ] && ok "COLLECTOR_ROOT read from the script ($CR)" || bad "no COLLECTOR_ROOT in $BL"
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
# fake_collector <data-dir> <env-dir> — an ssh that runs the remote command for real, in bash (whose `.` of a
# missing file reports and carries on, the lenient case), with the collector's paths mapped to local ones.
fake_collector() {
  cat > "$TMP/bin/ssh" <<EOF
#!/bin/sh
for a; do last="\$a"; done
exec bash -c "\$(printf '%s' "\$last" | sed -e 's#$CR/data/backlog#$1#g' \
  -e 's#$CR/collector.env#$2/collector.env#g')"
EOF
}
mkdir -p "$TMP/no-data" "$TMP/env"
fake_collector "$TMP/no-data" "$TMP/env"
run_bl pull
[ "$rc" -eq 0 ] && ok "an empty collector is not an error" || bad "pull failed on an empty collector: $(cat "$TMP/err")"
# The answer is real, so the index now says what the fleet holds: nothing.
[ ! -s "$TMP/zuvo/backlog-index.jsonl" ] && ok "the index is rewritten to the fleet's zero items" \
  || bad "the index after an empty answer: [$(cat "$TMP/zuvo/backlog-index.jsonl")]"
grep -q '0 items from 0 host(s)' "$TMP/out" && ok "the summary reports 0 items from 0 hosts" || bad "summary: $(cat "$TMP/out")"
printf '{"host":"mac","repo":"r","item_id":"B-1","status":"open","text":"kept"}\n' > "$TMP/zuvo/backlog-index.jsonl"

echo "=== pull, collector reachable, its data dir missing ==="
# An installed collector has its data dir; the one way it goes missing is a wrong path — which is exactly how
# `sync` read "0 items from 0 host(s)" for three weeks after the collector moved. Missing is a named failure,
# and the index keeps what it held.
fake_collector "$TMP/never-created" "$TMP/env"
run_bl pull
[ "$rc" -ne 0 ] && ok "a missing data dir fails the pull" || bad "pull exited 0 with no data dir (reads as an idle fleet)"
grep -q 'does not exist on the collector' "$TMP/err" && ok "the missing dir is named" || bad "no named failure: $(cat "$TMP/err")"
[ "$(cat "$TMP/zuvo/backlog-index.jsonl")" = "$before" ] && ok "the index is unchanged" \
  || bad "pull rewrote the index to [$(cat "$TMP/zuvo/backlog-index.jsonl")]"
printf '{"host":"mac","repo":"r","item_id":"B-1","status":"open","text":"kept"}\n' > "$TMP/zuvo/backlog-index.jsonl"

echo "=== sync on a host that may push but not read the data dir ==="
# The farm user cannot read the collector's data dir (gha:gha 750). Its push lands and the index is relayed from
# a host that can read it, so sync says so and exits 0 — while a bare `pull` there still fails by name.
mkdir -p "$TMP/locked-data"; printf 'CODESIFT_COLLECTOR_TOKEN=tok-lock\n' > "$TMP/env/collector.env"
chmod 000 "$TMP/locked-data"
if [ -r "$TMP/locked-data" ]; then
  echo "  [SKIP] chmod 000 leaves the dir readable under this account"
else
  fake_collector "$TMP/locked-data" "$TMP/env"
  rm -f "$TMP/zuvo/collect-ran"
  run_bl sync
  [ "$rc" -eq 0 ] && ok "sync exits 0 on a push-only host" || bad "sync failed on a push-only host: $(cat "$TMP/err")"
  [ "$(cat "$TMP/zuvo/collect-ran" 2>/dev/null)" = tok-lock ] && ok "the push still ran" || bad "the push did not run"
  grep -q 'not refreshed on this host' "$TMP/out" && ok "sync says the index was not refreshed here" || bad "out: $(cat "$TMP/out")"
  [ "$(cat "$TMP/zuvo/backlog-index.jsonl")" = "$before" ] && ok "the index is unchanged" \
    || bad "sync rewrote the index to [$(cat "$TMP/zuvo/backlog-index.jsonl")]"
  run_bl pull
  [ "$rc" -ne 0 ] && grep -q 'not readable by this user' "$TMP/err" && ok "a bare pull there still fails by name" \
    || bad "pull on an unreadable dir: rc=$rc $(cat "$TMP/err")"
fi
chmod 700 "$TMP/locked-data"

echo "=== pull, collector reachable, a backlog file it cannot read ==="
# `cat <dir>/*.jsonl 2>/dev/null || true` turned a read error into an empty or partial answer, and pull rewrote
# the index from it — every host in the unread file dropped out of the fleet without a word.
mkdir -p "$TMP/bad-data"
printf '{"received_at":1,"payload":{"host":"vps","run_id":"r1","items":[{"host":"vps","repo":"x","item_id":"B-9","status":"open","text":"t"}]}}\n' \
  > "$TMP/bad-data/a.jsonl"
printf '{"received_at":1,"payload":{"host":"bot","run_id":"r1","items":[]}}\n' > "$TMP/bad-data/b.jsonl"
chmod 000 "$TMP/bad-data/b.jsonl"
if [ -r "$TMP/bad-data/b.jsonl" ]; then
  echo "  [SKIP] chmod 000 leaves the file readable under this account"
else
  fake_collector "$TMP/bad-data" "$TMP/env"
  run_bl pull
  [ "$rc" -ne 0 ] && ok "pull exits non-zero" || bad "pull exited 0 with an unreadable backlog file"
  grep -q 'collector' "$TMP/err" && ok "the failure is named on stderr" || bad "no named failure: $(cat "$TMP/err")"
  [ "$(cat "$TMP/zuvo/backlog-index.jsonl")" = "$before" ] && ok "the index is unchanged" \
    || bad "pull rewrote the index to [$(cat "$TMP/zuvo/backlog-index.jsonl")]"
fi
chmod 600 "$TMP/bad-data/b.jsonl"

echo "=== sync, the data dir sits behind an ancestor this user cannot search ==="
# The farm user's real view of a 750 tree: the dir exists, but `[ -e ]` cannot see it. That is "cannot read",
# not "missing" — sync on such a host stays clean; a bare pull there fails as unreadable, not as moved.
mkdir -p "$TMP/anc/data"; chmod 000 "$TMP/anc"
if [ -x "$TMP/anc" ]; then
  echo "  [SKIP] chmod 000 leaves the ancestor searchable under this account"
else
  fake_collector "$TMP/anc/data" "$TMP/env"
  run_bl sync
  [ "$rc" -eq 0 ] && grep -q 'not refreshed on this host' "$TMP/out" && ok "sync treats a hidden data dir as unreadable, not missing" \
    || bad "sync behind an unsearchable ancestor: rc=$rc out=$(cat "$TMP/out") err=$(cat "$TMP/err")"
  run_bl pull
  [ "$rc" -ne 0 ] && grep -q 'not readable by this user' "$TMP/err" && ok "a bare pull says unreadable, not moved" \
    || bad "pull behind an unsearchable ancestor: rc=$rc $(cat "$TMP/err")"
fi
chmod 700 "$TMP/anc"

echo "=== sync, the data path exists but is a file ==="
printf 'x\n' > "$TMP/not-a-dir"
fake_collector "$TMP/not-a-dir" "$TMP/env"
run_bl sync
[ "$rc" -ne 0 ] && grep -q 'is not a directory' "$TMP/err" && ok "a non-directory data path fails even in sync" \
  || bad "sync with a file as the data dir: rc=$rc out=$(cat "$TMP/out") err=$(cat "$TMP/err")"
grep -q 'the push above did land' "$TMP/err" && ok "…and says the push had already landed" || bad "err: $(cat "$TMP/err")"

echo "=== sync, the push itself fails ==="
fake_collector "$TMP/no-data" "$TMP/env"
FAKE_PUSH_RC=1; export FAKE_PUSH_RC
run_bl sync
unset FAKE_PUSH_RC
[ "$rc" -ne 0 ] && grep -q 'push (backlog-collect.py --push) failed' "$TMP/err" && ok "a failed push fails sync by name" \
  || bad "sync after a failed push: rc=$rc err=$(cat "$TMP/err")"
grep -q '^index:' "$TMP/out" && bad "an index was reported over a push that failed: $(cat "$TMP/out")" \
  || ok "no fresh-looking index is printed over a failed push"
[ "$(cat "$TMP/zuvo/backlog-index.jsonl")" = "$before" ] && ok "the index is unchanged after a failed push" \
  || bad "a failed push rewrote the index to [$(cat "$TMP/zuvo/backlog-index.jsonl")]"

echo "=== sync, collector reachable, its collector.env missing ==="
# `. collector.env; echo $TOKEN` went on after a failed `.` and echoed an empty token: the failure read as
# "the collector has no token in its collector.env" — a file that is not there.
fake_collector "$TMP/no-data" "$TMP/no-env"
rm -f "$TMP/zuvo/collect-ran"
run_bl sync
[ "$rc" -ne 0 ] && ok "sync exits non-zero" || bad "sync exited 0 without a collector.env"
grep -q 'collector.env' "$TMP/err" && ok "the missing collector.env is named" || bad "no named failure: $(cat "$TMP/err")"
grep -q 'has no CODESIFT_COLLECTOR_TOKEN' "$TMP/err" && bad "a missing file reported as a missing token: $(cat "$TMP/err")" \
  || ok "not reported as a token missing from the file"
[ ! -e "$TMP/zuvo/collect-ran" ] && ok "backlog-collect.py was not run" \
  || bad "backlog-collect.py ran (token: [$(cat "$TMP/zuvo/collect-ran")])"

echo "=== sync, collector reachable with a token ==="
printf 'CODESIFT_COLLECTOR_TOKEN=tok-927\n' > "$TMP/env/collector.env"
fake_collector "$TMP/no-data" "$TMP/env"
rm -f "$TMP/zuvo/collect-ran"
run_bl sync
[ "$rc" -eq 0 ] && ok "sync exits 0" || bad "sync failed with a token: $(cat "$TMP/err")"
[ "$(cat "$TMP/zuvo/collect-ran" 2>/dev/null)" = tok-927 ] && ok "backlog-collect.py got the collector's token" \
  || bad "backlog-collect.py token: [$(cat "$TMP/zuvo/collect-ran" 2>/dev/null)]"
# The other name this host honours locally works on the collector too.
printf 'ZUVO_COLLECTOR_TOKEN=tok-zuvo\n' > "$TMP/env/collector.env"
rm -f "$TMP/zuvo/collect-ran"
run_bl sync
[ "$(cat "$TMP/zuvo/collect-ran" 2>/dev/null)" = tok-zuvo ] && ok "a collector.env with ZUVO_COLLECTOR_TOKEN is read too" \
  || bad "ZUVO_COLLECTOR_TOKEN on the collector: [$(cat "$TMP/zuvo/collect-ran" 2>/dev/null)] $(cat "$TMP/err")"
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
