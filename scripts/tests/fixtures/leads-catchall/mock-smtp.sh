#!/usr/bin/env bash
# mock-smtp.sh — drop-in replacement for ZUVO_SMTP_PROBE_CMD during catch-all testing.
# usage: mock-smtp.sh <domain> <email_local@domain>
# exit 0 → accepted (250), exit 1 → rejected (5xx), exit 2 → timeout
#
# Domain-to-behavior map (test fixtures):
# - acme-catchall.test, wide-open.test, accepts-all.test → ALWAYS accept (catch-all)
# - strict.test, proper.test, exact.test → accept only known addresses; reject random

set -u
domain="${1:-}"
addr="${2:-}"

case "$domain" in
  acme-catchall.test|wide-open.test|accepts-all.test)
    # catch-all: accept everything
    echo "250 OK mocked catch-all accept"
    exit 0
    ;;
  strict.test|proper.test|exact.test)
    # strict: only accept a known whitelist
    case "$addr" in
      ceo@strict.test|cfo@proper.test|cto@exact.test)
        echo "250 OK mocked strict accept"
        exit 0
        ;;
      *)
        echo "550 no such user mocked strict reject"
        exit 1
        ;;
    esac
    ;;
  *)
    # Unknown domain → timeout
    echo "timeout mocked"
    exit 2
    ;;
esac
