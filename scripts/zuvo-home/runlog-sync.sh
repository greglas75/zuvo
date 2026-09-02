#!/bin/bash
# Mac runs.log/retros.log telemetry -> collector /ingest/zuvo (full-detail, secret-gated).
# Fetch the token from the VPS collector (same source as `~/.zuvo/backlog`); no local secret.
ZH="${ZUVO_HOME:-$HOME/.zuvo}"
. "$(dirname "$0")/zuvo-collector-host.sh"
. "$(dirname "$0")/portable.sh" 2>/dev/null || true
zuvo_collector_host || exit 0
VPS="$ZUVO_COLLECTOR_SSH"
TOK="${CODESIFT_COLLECTOR_TOKEN:-}"
# stderr is KEPT, not discarded. The collector moved from /home/gha to /opt, i.e. from a user
# directory to a system one with stricter permissions — and with `2>/dev/null` a
# "Permission denied" on collector.env is indistinguishable from "no token configured".
# Both produce an empty $TOK and both exit 0, so the sync would stop working permanently
# and silently. A telemetry uploader that fails quietly is worse than one that fails loudly:
# nobody notices for weeks, and the gap looks like "a quiet period" in the data.
_tok_err=$(mktemp)
[ -n "$TOK" ] || TOK=$(ssh -o ConnectTimeout=10 "$VPS" '. /opt/telemetry-collector/collector.env; echo $CODESIFT_COLLECTOR_TOKEN' 2>"$_tok_err")
if [ -z "$TOK" ] && [ -s "$_tok_err" ]; then
  echo "runlog-sync: could not read the collector token from $VPS:" >&2
  head -3 "$_tok_err" >&2
fi
rm -f "$_tok_err"
[ -n "$TOK" ] || { echo "$(date -u +%FT%TZ) no token — skip"; exit 0; }
# /usr/bin/python3 is an absolute path that does not exist on Windows (and not on every Linux).
PY_BIN="$(zuvo_python)" || exit 0
CODESIFT_COLLECTOR_TOKEN="$TOK" $PY_BIN "$ZH/runlog-collect.py" --push
