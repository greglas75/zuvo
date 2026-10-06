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
TMP="$(mktemp -d)"; trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

# The collector root the script under test uses — ONE source, so the fake below cannot drift from it.
CR="$(awk -F'"' '/^COLLECTOR_ROOT = /{print $2; exit}' "$BL")"
[ -n "$CR" ] && ok "COLLECTOR_ROOT read from the script ($CR)" || bad "no COLLECTOR_ROOT in $BL"
before='{"host":"mac","repo":"r","item_id":"B-1","status":"open","text":"kept"}'

# Every case starts from its OWN sandbox $C — a fresh index, ssh, env dir and push stand-in — so no case
# reads state an earlier one left (the suite used to share one $TMP and re-seed the index by hand between
# cases; one missed re-seed made every later "index unchanged" check compare against the wrong file).
new_case() { # new_case <title> -> $C
  echo "=== $1 ==="
  C="$(mktemp -d "$TMP/case.XXXXXX")"
  mkdir -p "$C/bin" "$C/zuvo" "$C/env"
  # An ssh that cannot connect: ssh's own failure status is 255.
  printf '#!/bin/sh\necho "ssh: connect to host fake-collector port 22: Connection refused" >&2\nexit 255\n' > "$C/bin/ssh"
  chmod +x "$C/bin/ssh"
  # backlog-collect.py stand-in: proves whether sync went on to push, and with which token.
  printf 'import os, sys\nopen(os.path.join(os.environ["ZUVO_DIR"], "collect-ran"), "w").write(os.environ.get("CODESIFT_COLLECTOR_TOKEN", ""))\nsys.exit(int(os.environ.get("FAKE_PUSH_RC", "0")))\n' \
    > "$C/zuvo/backlog-collect.py"
  printf '%s\n' "$before" > "$C/zuvo/backlog-index.jsonl"
}
index_kept() { [ "$(cat "$C/zuvo/backlog-index.jsonl")" = "$before" ]; }
index_now() { cat "$C/zuvo/backlog-index.jsonl"; }

# fake_collector <data-dir> <env-dir> — an ssh that runs the remote command for real, in bash, with the
# collector's paths mapped to local ones.
fake_collector() {
  cat > "$C/bin/ssh" <<EOF
#!/bin/sh
for a; do last="\$a"; done
exec bash -c "\$(printf '%s' "\$last" | sed -e 's#$CR/data/backlog#$1#g' \
  -e 's#$CR/collector.env#$2/collector.env#g')"
EOF
  chmod +x "$C/bin/ssh"
}

run_bl() { # run_bl <cmd> [VAR=value…] -> rc in $rc, stdout in $C/out, stderr in $C/err
  local cmd="$1"; shift
  env -u CODESIFT_COLLECTOR_TOKEN -u ZUVO_COLLECTOR_TOKEN PATH="$C/bin:$PATH" ZUVO_DIR="$C/zuvo" \
    ZUVO_COLLECTOR_SSH=fake-collector "$@" python3 "$BL" "$cmd" > "$C/out" 2> "$C/err"
  rc=$?
}

new_case "sync, collector unreachable"
run_bl sync
[ "$rc" -eq 1 ] && ok "sync exits 1" || bad "sync exited $rc after the token fetch failed"
grep -q 'ssh to the collector fake-collector, or the command it ran there, failed (exit 255: ssh: connect to host fake-collector port 22: Connection refused) — cannot fetch the collector token; nothing was changed' "$C/err" \
  && ok "the failure is named on stderr" || bad "no named failure: $(cat "$C/err")"
[ ! -e "$C/zuvo/collect-ran" ] && ok "backlog-collect.py was not run without a token" \
  || bad "backlog-collect.py ran (token: [$(cat "$C/zuvo/collect-ran")])"
index_kept && ok "the index is unchanged" || bad "sync rewrote the index"

new_case "pull, collector unreachable"
run_bl pull
[ "$rc" -eq 1 ] && ok "pull exits 1" || bad "pull exited $rc after ssh failed"
grep -q 'ssh to the collector fake-collector, or the command it ran there, failed (exit 255: ssh: connect to host fake-collector port 22: Connection refused) — cannot pull the fleet index; nothing was changed' "$C/err" \
  && ok "the failure is named on stderr" || bad "no named failure: $(cat "$C/err")"
index_kept && ok "the index is unchanged" \
  || bad "pull rewrote the index to [$(index_now)]"

new_case "sync, collector reachable but holds no token"
# ssh succeeded and printed nothing: a real answer, and the answer is "no token" — still no push.
printf '#!/bin/sh\nexit 0\n' > "$C/bin/ssh"
run_bl sync
[ "$rc" -eq 1 ] && ok "sync exits non-zero" || bad "sync exited 0 with an empty token"
grep -q 'no CODESIFT_COLLECTOR_TOKEN' "$C/err" && ok "the missing token is named" || bad "no named failure: $(cat "$C/err")"
[ ! -e "$C/zuvo/collect-ran" ] && ok "backlog-collect.py was not run with an empty token" \
  || bad "backlog-collect.py ran (token: [$(cat "$C/zuvo/collect-ran")])"

new_case "pull, collector reachable with no data"
# A reachable collector with no backlog files yet is a real, empty answer — not a failure. The fake runs the
# remote command for real, with the collector's data dir pointed at an empty local one: `cat <dir>/*.jsonl`
# then fails as it does on a collector with no files, and only the command's own `|| true` makes that empty.
mkdir -p "$C/no-data"
fake_collector "$C/no-data" "$C/env"
run_bl pull
[ "$rc" -eq 0 ] && ok "an empty collector is not an error" || bad "pull failed on an empty collector: $(cat "$C/err")"
# The answer is real, so the index now says what the fleet holds: nothing.
[ ! -s "$C/zuvo/backlog-index.jsonl" ] && ok "the index is rewritten to the fleet's zero items" \
  || bad "the index after an empty answer: [$(index_now)]"
grep -q '0 items from 0 host(s)' "$C/out" && ok "the summary reports 0 items from 0 hosts" || bad "summary: $(cat "$C/out")"

new_case "pull, collector reachable, its data dir missing"
# An installed collector has its data dir; the one way it goes missing is a wrong path — which is exactly how
# `sync` read "0 items from 0 host(s)" for three weeks after the collector moved. Missing is a named failure,
# and the index keeps what it held.
fake_collector "$C/never-created" "$C/env"
run_bl pull
[ "$rc" -eq 1 ] && ok "a missing data dir fails the pull" || bad "pull exited 0 with no data dir (reads as an idle fleet)"
grep -q 'does not exist on the collector' "$C/err" && ok "the missing dir is named" || bad "no named failure: $(cat "$C/err")"
index_kept && ok "the index is unchanged" \
  || bad "pull rewrote the index to [$(index_now)]"

new_case "sync on a host that may push but not read the data dir"
# The farm user cannot read the collector's data dir (gha:gha 750). Its push lands and the index is relayed from
# a host that can read it, so sync says so and exits 0 — while a bare `pull` there still fails by name.
mkdir -p "$C/locked-data"; printf 'CODESIFT_COLLECTOR_TOKEN=tok-lock\n' > "$C/env/collector.env"
chmod 000 "$C/locked-data"
if [ -r "$C/locked-data" ]; then
  echo "  [SKIP] chmod 000 leaves the dir readable under this account"
else
  fake_collector "$C/locked-data" "$C/env"
  run_bl sync
  [ "$rc" -eq 0 ] && ok "sync exits 0 on a push-only host" || bad "sync failed on a push-only host: $(cat "$C/err")"
  [ "$(cat "$C/zuvo/collect-ran" 2>/dev/null)" = tok-lock ] && ok "the push still ran" || bad "the push did not run"
  grep -q 'not refreshed on this host' "$C/out" && ok "sync says the index was not refreshed here" || bad "out: $(cat "$C/out")"
  index_kept && ok "the index is unchanged" \
    || bad "sync rewrote the index to [$(index_now)]"
  run_bl pull
  [ "$rc" -eq 1 ] && grep -q 'not readable by this user' "$C/err" && ok "a bare pull there still fails by name" \
    || bad "pull on an unreadable dir: rc=$rc $(cat "$C/err")"
fi
chmod 700 "$C/locked-data"

new_case "pull, collector reachable, a backlog file it cannot read"
# `cat <dir>/*.jsonl 2>/dev/null || true` turned a read error into an empty or partial answer, and pull rewrote
# the index from it — every host in the unread file dropped out of the fleet without a word.
mkdir -p "$C/bad-data"
printf '{"received_at":1,"payload":{"host":"vps","run_id":"r1","items":[{"host":"vps","repo":"x","item_id":"B-9","status":"open","text":"t"}]}}\n' \
  > "$C/bad-data/a.jsonl"
printf '{"received_at":1,"payload":{"host":"bot","run_id":"r1","items":[]}}\n' > "$C/bad-data/b.jsonl"
chmod 000 "$C/bad-data/b.jsonl"
if [ -r "$C/bad-data/b.jsonl" ]; then
  echo "  [SKIP] chmod 000 leaves the file readable under this account"
else
  fake_collector "$C/bad-data" "$C/env"
  run_bl pull
  [ "$rc" -eq 1 ] && ok "pull exits non-zero" || bad "pull exited 0 with an unreadable backlog file"
  grep -q 'failed (exit 1: gzip: .*b.jsonl.*) — cannot pull the fleet index; nothing was changed' "$C/err" \
    && ok "the unreadable file is named on stderr" || bad "no named failure: $(cat "$C/err")"
  index_kept && ok "the index is unchanged" \
    || bad "pull rewrote the index to [$(index_now)]"
fi
chmod 600 "$C/bad-data/b.jsonl"

new_case "sync, the data dir sits behind an ancestor this user cannot search"
# The farm user's real view of a 750 tree: the dir exists, but `[ -e ]` cannot see it. That is "cannot read",
# not "missing" — sync on such a host stays clean; a bare pull there fails as unreadable, not as moved.
printf 'CODESIFT_COLLECTOR_TOKEN=tok-anc\n' > "$C/env/collector.env"
mkdir -p "$C/anc/data"; chmod 000 "$C/anc"
if [ -x "$C/anc" ]; then
  echo "  [SKIP] chmod 000 leaves the ancestor searchable under this account"
else
  fake_collector "$C/anc/data" "$C/env"
  run_bl sync
  [ "$rc" -eq 0 ] && grep -q 'not refreshed on this host' "$C/out" && ok "sync treats a hidden data dir as unreadable, not missing" \
    || bad "sync behind an unsearchable ancestor: rc=$rc out=$(cat "$C/out") err=$(cat "$C/err")"
  run_bl pull
  [ "$rc" -eq 1 ] && grep -q 'not readable by this user' "$C/err" && ok "a bare pull says unreadable, not moved" \
    || bad "pull behind an unsearchable ancestor: rc=$rc $(cat "$C/err")"
fi
chmod 700 "$C/anc"

new_case "sync, the data path exists but is a file"
printf 'CODESIFT_COLLECTOR_TOKEN=tok-file\n' > "$C/env/collector.env"
printf 'x\n' > "$C/not-a-dir"
fake_collector "$C/not-a-dir" "$C/env"
run_bl sync
[ "$rc" -eq 1 ] && grep -q 'is not a directory' "$C/err" && ok "a non-directory data path fails even in sync" \
  || bad "sync with a file as the data dir: rc=$rc out=$(cat "$C/out") err=$(cat "$C/err")"
grep -q 'the push above did land' "$C/err" && ok "…and says the push had already landed" || bad "err: $(cat "$C/err")"
grep -q 'nothing was changed' "$C/err" && bad "a landed push reported as 'nothing was changed': $(cat "$C/err")" \
  || ok "…without also claiming nothing was changed"

new_case "sync, an ancestor of the data path is a file"
# `[ ! -x ]` on a FILE ancestor read as "unreadable", and sync exited 0 over a broken path.
printf 'CODESIFT_COLLECTOR_TOKEN=tok-file\n' > "$C/env/collector.env"
printf 'x\n' > "$C/not-a-dir"
fake_collector "$C/not-a-dir/data" "$C/env"
run_bl sync
[ "$rc" -eq 1 ] && grep -q 'not-a-dir is not a directory' "$C/err" && ok "a file ancestor fails sync, named" \
  || bad "sync under a file ancestor: rc=$rc out=$(cat "$C/out") err=$(cat "$C/err")"

new_case "sync, the data dir is a broken symlink"
printf 'CODESIFT_COLLECTOR_TOKEN=tok-link\n' > "$C/env/collector.env"
ln -s "$C/gone-target" "$C/dangling"
fake_collector "$C/dangling" "$C/env"
run_bl sync
[ "$rc" -eq 1 ] && grep -q 'is a broken symlink' "$C/err" && ok "a dangling data-dir link is named as such, not as moved" \
  || bad "sync with a dangling data dir: rc=$rc err=$(cat "$C/err")"

new_case "sync, the push itself fails"
printf 'CODESIFT_COLLECTOR_TOKEN=tok-push\n' > "$C/env/collector.env"
mkdir -p "$C/no-data"
fake_collector "$C/no-data" "$C/env"
run_bl sync FAKE_PUSH_RC=1
[ "$rc" -eq 1 ] && grep -q 'push (backlog-collect.py --push) failed' "$C/err" && ok "a failed push fails sync by name" \
  || bad "sync after a failed push: rc=$rc err=$(cat "$C/err")"
grep -q '^index:' "$C/out" && bad "an index was reported over a push that failed: $(cat "$C/out")" \
  || ok "no fresh-looking index is printed over a failed push"
index_kept && ok "the index is unchanged after a failed push" \
  || bad "a failed push rewrote the index to [$(index_now)]"

new_case "sync, collector reachable, its collector.env missing"
# `. collector.env; echo $TOKEN` went on after a failed `.` and echoed an empty token: the failure read as
# "the collector has no token in its collector.env" — a file that is not there.
mkdir -p "$C/no-data"
fake_collector "$C/no-data" "$C/no-env"
run_bl sync
[ "$rc" -eq 1 ] && ok "sync exits non-zero" || bad "sync exited 0 without a collector.env"
grep -q 'collector.env' "$C/err" && ok "the missing collector.env is named" || bad "no named failure: $(cat "$C/err")"
grep -q 'has no CODESIFT_COLLECTOR_TOKEN' "$C/err" && bad "a missing file reported as a missing token: $(cat "$C/err")" \
  || ok "not reported as a token missing from the file"
[ ! -e "$C/zuvo/collect-ran" ] && ok "backlog-collect.py was not run" \
  || bad "backlog-collect.py ran (token: [$(cat "$C/zuvo/collect-ran")])"

new_case "sync, collector reachable with a token"
printf 'CODESIFT_COLLECTOR_TOKEN=tok-927\n' > "$C/env/collector.env"
mkdir -p "$C/no-data"
fake_collector "$C/no-data" "$C/env"
run_bl sync
[ "$rc" -eq 0 ] && ok "sync exits 0" || bad "sync failed with a token: $(cat "$C/err")"
[ "$(cat "$C/zuvo/collect-ran" 2>/dev/null)" = tok-927 ] && ok "backlog-collect.py got the collector's token" \
  || bad "backlog-collect.py token: [$(cat "$C/zuvo/collect-ran" 2>/dev/null)]"
# The other name this host honours locally works on the collector too.
printf 'ZUVO_COLLECTOR_TOKEN=tok-zuvo\n' > "$C/env/collector.env"
rm -f "$C/zuvo/collect-ran"
run_bl sync
[ "$(cat "$C/zuvo/collect-ran" 2>/dev/null)" = tok-zuvo ] && ok "a collector.env with ZUVO_COLLECTOR_TOKEN is read too" \
  || bad "ZUVO_COLLECTOR_TOKEN on the collector: [$(cat "$C/zuvo/collect-ran" 2>/dev/null)] $(cat "$C/err")"

new_case "pull, no ssh client on PATH"
mkdir -p "$C/nossh"
env -u CODESIFT_COLLECTOR_TOKEN -u ZUVO_COLLECTOR_TOKEN PATH="$C/nossh" ZUVO_DIR="$C/zuvo" \
  ZUVO_COLLECTOR_SSH=fake-collector "$(command -v python3)" "$BL" pull > "$C/out" 2> "$C/err"; rc=$?
[ "$rc" -eq 1 ] && ok "pull exits non-zero" || bad "pull exited 0 with no ssh to run"
grep -q 'could not run ssh to the collector' "$C/err" && ok "the missing client is named" || bad "no named failure: $(cat "$C/err")"
index_kept && ok "the index is unchanged" \
  || bad "pull rewrote the index to [$(index_now)]"

new_case "pull, no collector configured"
mkdir -p "$C/home/.zuvo"
env -u CODESIFT_COLLECTOR_TOKEN -u ZUVO_COLLECTOR_TOKEN -u ZUVO_COLLECTOR_SSH PATH="$C/bin:$PATH" HOME="$C/home" \
  ZUVO_HOME="$C/home/.zuvo" ZUVO_DIR="$C/zuvo" python3 "$BL" pull > "$C/out" 2> "$C/err"; rc=$?
[ "$rc" -eq 1 ] && ok "pull exits non-zero" || bad "pull exited 0 with no collector configured"
grep -q 'no collector host configured' "$C/err" && ok "the missing configuration is named" || bad "no named failure: $(cat "$C/err")"
index_kept && ok "the index is unchanged" \
  || bad "pull rewrote the index to [$(index_now)]"

new_case "a collector that does not answer in time"
# collector_ssh takes the timeout as an argument, so the timeout path is driven directly with 1 s against an
# ssh that hangs, instead of waiting out pull's 120 s. The hang is a FIFO nobody ever writes: opening it for
# reading blocks for good, so the 1 s is the ONLY clock in this case — no race between two durations.
mkfifo "$C/never"
printf '#!/bin/sh\nexec cat "%s"\n' "$C/never" > "$C/bin/ssh"
to_out="$(PATH="$C/bin:$PATH" ZUVO_DIR="$C/zuvo" ZUVO_COLLECTOR_SSH=fake-collector python3 - "$BL" <<'PY' 2>&1
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

new_case "backlog-collect.py --push: its exit status says whether the push landed"
# push() reports a failed batch or a missing token as a STRING, and the script exited 0 regardless, so the
# returncode check in `backlog sync` never fired. The real script, sandboxed: no repos, a loopback collector
# that refuses connections.
BC="$ROOT/scripts/zuvo-home/backlog-collect.py"
mkdir -p "$TMP/bc/home" "$TMP/bc/roots"
run_bc() { # run_bc <token> [--push]
  env -u CODESIFT_COLLECTOR_TOKEN -u ZUVO_COLLECTOR_TOKEN HOME="$TMP/bc/home" ZUVO_DIR="$TMP/bc/zuvo" \
    ZUVO_BACKLOG_ROOTS="$TMP/bc/roots/*" ZUVO_BACKLOG_OUT="$TMP/bc/out.jsonl" \
    ZUVO_COLLECTOR_URL="http://127.0.0.1:9" ${1:+CODESIFT_COLLECTOR_TOKEN="$1"} \
    python3 "$BC" ${2:+"$2"} > "$TMP/bc/stdout" 2> "$TMP/bc/stderr"
  rc=$?
}
run_bc "" --push
[ "$rc" -eq 1 ] && grep -q 'skipped (no collector token)' "$TMP/bc/stdout" && ok "--push without a token exits non-zero" \
  || bad "--push without a token: rc=$rc $(cat "$TMP/bc/stdout" "$TMP/bc/stderr")"
run_bc tok-x --push
[ "$rc" -eq 1 ] && grep -q 'push failed on batch' "$TMP/bc/stdout" && ok "--push to a refusing collector exits non-zero" \
  || bad "--push to a refusing collector: rc=$rc $(cat "$TMP/bc/stdout" "$TMP/bc/stderr")"
run_bc ""
[ "$rc" -eq 0 ] && ok "no --push requested: exits 0" || bad "a snapshot-only run failed: rc=$rc $(cat "$TMP/bc/stderr")"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
