#!/bin/bash
# Mac runs.log/retros.log telemetry -> collector /ingest/zuvo (full-detail, secret-gated).
# Fetch the token from the VPS collector (same source as `~/.zuvo/backlog`); no local secret.
ZH="${ZUVO_HOME:-$HOME/.zuvo}"
. "$(dirname "$0")/zuvo-collector-host.sh"
. "$(dirname "$0")/portable.sh" 2>/dev/null || true
zuvo_collector_host || exit 0
VPS="$ZUVO_COLLECTOR_SSH"
TOK="${CODESIFT_COLLECTOR_TOKEN:-}"
[ -n "$TOK" ] || TOK=$(ssh -o ConnectTimeout=10 "$VPS" '. /home/gha/telemetry-collector/collector.env; echo $CODESIFT_COLLECTOR_TOKEN' 2>/dev/null)
[ -n "$TOK" ] || { echo "$(date -u +%FT%TZ) no token — skip"; exit 0; }
# /usr/bin/python3 is an absolute path that does not exist on Windows (and not on every Linux).
PY_BIN="$(zuvo_python)" || exit 0
CODESIFT_COLLECTOR_TOKEN="$TOK" $PY_BIN "$ZH/runlog-collect.py" --push
