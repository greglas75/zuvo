#!/bin/bash
# Mac runs.log/retros.log telemetry -> collector /ingest/zuvo (full-detail, secret-gated).
# Fetch the token from the VPS collector (same source as `~/.zuvo/backlog`); no local secret.
ZH="${ZUVO_HOME:-$HOME/.zuvo}"
VPS="${ZUVO_COLLECTOR_SSH:-root@100.110.133.83}"
TOK="${CODESIFT_COLLECTOR_TOKEN:-}"
[ -n "$TOK" ] || TOK=$(ssh -o ConnectTimeout=10 "$VPS" '. /home/gha/telemetry-collector/collector.env; echo $CODESIFT_COLLECTOR_TOKEN' 2>/dev/null)
[ -n "$TOK" ] || { echo "$(date -u +%FT%TZ) no token — skip"; exit 0; }
CODESIFT_COLLECTOR_TOKEN="$TOK" /usr/bin/python3 "$ZH/runlog-collect.py" --push
