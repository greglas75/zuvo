#!/usr/bin/env bash
#
# infra-collect.sh — deterministic per-host infrastructure collector for
# zuvo:infra-audit. Connects to ONE host over SSH, runs a read-only check
# battery, and writes a normalized IC-3 bundle JSON. The LLM analysts read the
# bundle; they never see raw tool output or run commands themselves.
#
# This is the Task-4 SKELETON stage: CLI parsing + validation, the single
# run_remote() dispatch point, the --dry-run command preview, and the IC-3
# bundle/phase0 writers. Live check implementations (lynis/nmap/trivy/...) land
# in Tasks 5-7; for now every check emits a `skipped` placeholder.
#
# Contracts encoded here (cited, not restated — see the spec):
#   IC-3  bundle schema           IC-5  redaction (SED_REDACT)
#   IC-8  SSH invariants (SSH_OPTS, nohup pattern via ssh-probe-protocol §2)
#   IC-9  collection safety bounds (-xdev finds, named timeout constants)
#   DD-3  consent-gated installs (suppressed under --no-install)
#   DD-9  read-only / --dry-run prints every command without executing
#
# Portable to bash 3.2 (macOS system bash) — no associative arrays, no ${v,,}.
#
set -euo pipefail

# ===========================================================================
# Constants (CQ12 named-timeout / CQ14 single-source — no duplicated literals)
# ===========================================================================

# IC-8 SSH invariants. Defined ONCE here and interpolated everywhere via
# $SSH_OPTS — never re-typed, split, or reordered (ssh-probe-protocol §2).
SSH_OPTS='-o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o BatchMode=yes -o StrictHostKeyChecking=yes'

# IC-9 collection-safety bounds (timeouts in seconds). Env-overridable so the
# hardening test suite can force a tiny wall clock; defaults are the spec's.
: "${CHECK_TIMEOUT_S:=300}"        # default per-check server-side timeout
: "${TRIVY_TIMEOUT_S:=120}"        # trivy --timeout 120s --skip-update
: "${CONNECT_TIMEOUT_S:=10}"       # ssh ConnectTimeout (mirrors SSH_OPTS)
: "${WALL_CLOCK_LIMIT_S:=1800}"    # per-host 30-min wall clock (full mode)

# IC-5 redaction. Case-insensitive sed program: any KEY matching the pattern
# has its VALUE replaced with [REDACTED] BEFORE the value is written to the
# bundle or any raw file, so analysts never see secrets. Applied to every
# config-dump line of the form `key = value` / `key: value` / `KEY=value`.
SED_REDACT='s/((password|passwd|secret|token|api[_-]?key|private[_-]?key|DATABASE_URL|REDIS_URL|connection[_-]?string)[[:space:]]*[:=][[:space:]]*).*/\1[REDACTED]/Ig'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ===========================================================================
# Usage
# ===========================================================================

usage() {
  cat >&2 <<'EOF'
Usage: infra-collect.sh --host user@addr[:port] --out <path> [options]

Required:
  --host user@addr[:port]   Target host (SSH user@address, optional :port)
  --out <path>              Bundle JSON output path (IC-3)

Options:
  --dry-run                 Print every command WOULD run; open no connections (DD-9)
  --no-install              Hard read-only; never offer tool installation (DD-3)
  --run-id <id>             Run identifier (default: zuvo-<epoch>-<pid>)
  --proxy <url>             External-scan proxy override (IC-4)
  --quick                   IS1 + IS3 (internal) + IS4 only
  --dimensions <list>       Comma-separated dimension subset (e.g. IS1,IS3,IS9)
  --deep-scan               nmap -p- instead of --top-ports 1000 (IC-9)
  --skip-external           Internal vantage only
  --external <mode>         External vantage mode (direct)

Reads no SSH private key material (ssh-probe-protocol §4). StrictHostKeyChecking
is never disabled. See docs/specs/2026-06-10-infra-audit-spec.md.
EOF
}

# ===========================================================================
# Argument parsing (CQ3 validation)
# ===========================================================================

HOST=""
OUT=""
DRY_RUN=false
NO_INSTALL=false
RUN_ID=""
PROXY=""
QUICK=false
DIMENSIONS=""
DEEP_SCAN=false
SKIP_EXTERNAL=false
EXTERNAL_MODE=""

# A value-taking flag passed as the LAST argument leaves $# at 1; a bare `shift 2`
# would then fail and — under `set -e` — exit the script silently with no usage.
# `_need_val` asserts a value is present and emits a clear usage error instead.
_need_val() {
  if [ "$2" -lt 2 ]; then
    echo "ERROR: $1 requires a value" >&2
    usage
    exit 1
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host)        _need_val --host $#; HOST="$2"; shift 2 ;;
    --out)         _need_val --out $#; OUT="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --no-install)  NO_INSTALL=true; shift ;;
    --run-id)      _need_val --run-id $#; RUN_ID="$2"; shift 2 ;;
    --proxy)       _need_val --proxy $#; PROXY="$2"; shift 2 ;;
    --quick)       QUICK=true; shift ;;
    --dimensions)  _need_val --dimensions $#; DIMENSIONS="$2"; shift 2 ;;
    --deep-scan)   DEEP_SCAN=true; shift ;;
    --skip-external) SKIP_EXTERNAL=true; shift ;;
    --external)    _need_val --external $#; EXTERNAL_MODE="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# --host required
if [ -z "$HOST" ]; then
  echo "ERROR: --host is required" >&2
  usage
  exit 1
fi

# --host format: user@addr[:port]  (CQ3). No spaces, no second @, optional :port.
# The user part MUST begin with an alphanumeric/dot/underscore — a leading `-`
# would let the whole `user@addr` destination be parsed by ssh as an option
# (SSH option injection, e.g. `-oProxyCommand=...`). The `--` end-of-options
# guard in every ssh invocation is the second layer; this regex is the first.
if ! printf '%s' "$HOST" | grep -Eq '^[A-Za-z0-9._][^@[:space:]]*@[^@:[:space:]]+(:[0-9]+)?$'; then
  echo "ERROR: malformed --host '$HOST' (expected user@addr[:port])" >&2
  usage
  exit 1
fi

# --out required
if [ -z "$OUT" ]; then
  echo "ERROR: --out is required" >&2
  usage
  exit 1
fi

# --out parent dir must exist and be writable (CQ3) — checked BEFORE any
# connection so a bad path fails fast, never mid-collection.
OUT_PARENT="$(dirname "$OUT")"
if [ ! -d "$OUT_PARENT" ]; then
  echo "ERROR: --out parent directory does not exist: $OUT_PARENT" >&2
  exit 1
fi
if [ ! -w "$OUT_PARENT" ]; then
  echo "ERROR: --out parent directory not writable: $OUT_PARENT" >&2
  exit 1
fi

# Default run-id
if [ -z "$RUN_ID" ]; then
  RUN_ID="zuvo-$(date +%s)-$$"
fi

# Validate --run-id charset (CQ3). RUN_ID lands inside remote `sh -c` command
# strings and REMOTE_RUN_DIR; an unconstrained value is remote command injection
# (e.g. `--run-id 'x;touch /tmp/pwn'`). Restrict to a safe charset + bounded
# length. The default-generated id (`zuvo-<epoch>-<pid>`) trivially satisfies it.
if ! printf '%s' "$RUN_ID" | grep -Eq '^[A-Za-z0-9._-]{1,64}$'; then
  echo "ERROR: malformed --run-id '$RUN_ID' (allowed: A-Z a-z 0-9 . _ - ; 1-64 chars)" >&2
  usage
  exit 1
fi

# ===========================================================================
# Hard prerequisite: jq (benchmark.sh line 426 pattern)
# ===========================================================================

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required. Install: brew install jq" >&2; exit 1; }

# ===========================================================================
# Derived host fields
# ===========================================================================

SSH_USER="${HOST%@*}"
HOST_REST="${HOST#*@}"          # addr[:port]
if printf '%s' "$HOST_REST" | grep -Eq ':[0-9]+$'; then
  SSH_ADDR="${HOST_REST%:*}"
  SSH_PORT="${HOST_REST##*:}"
else
  SSH_ADDR="$HOST_REST"
  SSH_PORT="22"
fi

# Validate SSH port range 1-65535 (CQ3). Force base-10 (10#) so a value with a
# leading zero (e.g. `:08`) is not parsed as octal — an invalid octal like `08`
# would otherwise make `[ "08" -lt 1 ]` emit a (silenced) error and return 2,
# evaluating the whole guard as false and BYPASSING the range check.
if [ "$((10#$SSH_PORT))" -lt 1 ] || [ "$((10#$SSH_PORT))" -gt 65535 ]; then
  echo "ERROR: --host port '$SSH_PORT' is out of range (must be 1-65535)" >&2
  usage
  exit 1
fi

# Bundle host name = address (collector audits a single ad-hoc host).
HOST_NAME="$SSH_ADDR"

REMOTE_RUN_DIR="/tmp/${RUN_ID}"

# ===========================================================================
# run_remote() — SINGLE dispatch point for every remote command (IC-8).
#
#   run_remote <check-id> <long?> -- <remote command...>
#
#   <long?>: "long" → command may exceed 30s → wrapped in the nohup pattern
#            (ssh-probe-protocol §2: server-side timeout + .rc sidecar +
#            stream redirection). Anything else → plain bounded ssh.
#
# In --dry-run it PRINTS the full command line it WOULD run (including the ssh
# + IC-8 prefix) and returns without connecting. Live execution is a minimal
# stub at this skeleton stage (checks emit `skipped` placeholders); the dry-run
# preview is the contract surface Task 4 must satisfy.
# ===========================================================================

# Tracks whether the per-host run dir has been claimed (mkdir once per run).
RUN_DIR_CLAIMED=false

run_remote() {
  local check_id="$1"; shift
  local mode="$1"; shift
  # consume the literal "--" separator
  if [ "${1:-}" = "--" ]; then shift; fi
  local remote_cmd="$*"

  if [ "$mode" = "long" ]; then
    # ssh-probe-protocol §2: claim the run dir ONCE per host (atomic mkdir),
    # then run the bounded inner command under nohup with a .rc sidecar.
    if [ "$RUN_DIR_CLAIMED" = false ]; then
      _claim_run_dir
      RUN_DIR_CLAIMED=true
    fi
    local wrapped
    wrapped="nohup sh -c 'timeout ${CHECK_TIMEOUT_S} ${remote_cmd} > ${REMOTE_RUN_DIR}/${check_id}.out 2>&1; echo \$? > ${REMOTE_RUN_DIR}/${check_id}.rc' < /dev/null > /dev/null 2>&1 &"
    _ssh_exec "$check_id" "$wrapped"
  else
    _ssh_exec "$check_id" "timeout ${CHECK_TIMEOUT_S} ${remote_cmd}"
  fi
}

# Claim the per-host scratch dir exactly once (atomic; fail-closed on EEXIST).
# Live path MUST fail closed: a failed `mkdir -m 700` (EEXIST/symlink/perm) means
# the run dir was hijacked or unwritable; per ssh-probe-protocol §2 we emit a
# phase0 bundle (reason `run-dir-claim-failed` + captured stderr) and exit 1 —
# never silently continue into checks that would write into an unclaimed dir.
_claim_run_dir() {
  local claim="mkdir -m 700 ${REMOTE_RUN_DIR} || { echo 'run dir exists — refusing'; exit 1; }"
  if [ "$DRY_RUN" = true ]; then
    printf '[DRY-RUN] WOULD run (run-dir claim): LC_ALL=C ssh %s -p %s -- %s@%s %s\n' \
      "$SSH_OPTS" "$SSH_PORT" "$SSH_USER" "$SSH_ADDR" "$claim"
  else
    local claim_err claim_rc
    claim_err="$(LC_ALL=C ssh $SSH_OPTS -p "$SSH_PORT" -- "$SSH_USER@$SSH_ADDR" "$claim" 2>&1 >/dev/null)"
    claim_rc=$?
    if [ "$claim_rc" -ne 0 ]; then
      local redacted_err
      redacted_err="$(printf '%s' "$claim_err" | LC_ALL=C sed -E "$SED_REDACT")"
      phase0_writer "FAILED" "run-dir-claim-failed" "$redacted_err"
      echo "ERROR: run-dir claim failed (rc=$claim_rc) on $HOST_NAME — see phase0 bundle: $OUT" >&2
      exit 1
    fi
  fi
}

# Lowest-level ssh dispatch — every remote command flows through here so the
# IC-8 flag string is applied in exactly one place.
_ssh_exec() {
  local check_id="$1"; shift
  local remote_cmd="$1"
  if [ "$DRY_RUN" = true ]; then
    printf '[DRY-RUN] WOULD run (%s): LC_ALL=C ssh %s -p %s -- %s@%s %s\n' \
      "$check_id" "$SSH_OPTS" "$SSH_PORT" "$SSH_USER" "$SSH_ADDR" "$remote_cmd"
    return 0
  fi
  # Live path is a minimal stub at the skeleton stage — checks emit `skipped`
  # placeholders, so the live battery is not yet wired. Tasks 5-7 implement it.
  # `--` ends ssh option parsing before the destination (SSH option-injection guard).
  LC_ALL=C ssh $SSH_OPTS -p "$SSH_PORT" -- "$SSH_USER@$SSH_ADDR" "$remote_cmd" 2>/dev/null || true
}

# ===========================================================================
# Check battery declaration.
#
# One entry per representative check, parsed as: id|dimension|needs_sudo|mode|cmd
# `mode` = short|long. The cmd is a STATIC predefined battery command (never
# host- or user-interpolated — ssh-probe-protocol §2). Tasks 5-7 flesh out the
# real parsing/normalization; here each becomes a `skipped` placeholder, and in
# --dry-run the command line is previewed via run_remote().
#
# IDs are drawn from the infra-check-registry.md namespace; ≥1 per IS1..IS12.
# ===========================================================================

# Quick mode = IS1 + IS3 + IS4 only.
QUICK_DIMS="IS1 IS3 IS4"

# Returns 0 if the dimension is in scope for this run.
_dimension_in_scope() {
  local dim="$1"
  if [ "$QUICK" = true ]; then
    case " $QUICK_DIMS " in *" $dim "*) return 0 ;; *) return 1 ;; esac
  fi
  if [ -n "$DIMENSIONS" ]; then
    case ",$DIMENSIONS," in *",$dim,"*) return 0 ;; *) return 1 ;; esac
  fi
  return 0
}

# The battery. find lines carry -xdev + pseudo-fs prunes (IC-9). sshd/ss/etc
# are static. `long` = lynis/nmap/trivy class (>30s → nohup).
battery() {
  cat <<EOF
IS1-sshd-permitrootlogin|IS1|true|short|sshd -T | grep -i permitrootlogin
IS2-uid0-nonroot|IS2|false|short|awk -F: '(\$3==0){print \$1}' /etc/passwd
IS3-unexpected-listener|IS3|false|short|ss -tulpn
IS4-weak-protocols|IS4|false|long|true
IS5-ufw-disabled|IS5|true|short|ufw status verbose
IS6-security-updates-pending|IS6|true|long|debsecan --suite \$(lsb_release -cs) --format detail
IS7-fail2ban-missing|IS7|false|short|systemctl is-active fail2ban
IS8-exposed-admin-panel|IS8|false|long|true
IS9-socket-world-readable|IS9|true|short|ls -l /var/run/docker.sock
IS10-redis-no-auth|IS10|true|short|redis-cli CONFIG GET requirepass
IS11-suid-unexpected|IS11|true|long|find / -xdev -path /proc -prune -o -path /sys -prune -o -path /run -prune -o -perm -4000 -type f -print
IS12-world-readable-env|IS12|true|long|find / -xdev -path /proc -prune -o -path /sys -prune -o -path /run -prune -o -name '.env' -perm /044 -type f -print
EOF
}

# ===========================================================================
# Phase-0 writer — for preflight failures (unreachable, host-key mismatch,
# auth failure). Writes bundle/<host>.phase0.json so Phase 3 still renders a
# per-host report (E4/AC8). Status/reason/stderr-evidence triple.
# ===========================================================================

phase0_writer() {
  local status="$1"      # UNREACHABLE | FAILED | SKIPPED
  local reason="$2"      # machine reason, e.g. host-key-mismatch
  local stderr_ev="$3"   # captured stderr evidence (redacted)
  local out="${4:-$OUT}"
  jq -n \
    --arg host "$HOST_NAME" \
    --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg stderr_ev "$stderr_ev" \
    '{
      host: $host,
      collected_at: $collected_at,
      status: $status,
      reason: $reason,
      stderr_evidence: $stderr_ev
    }' > "$out" || { echo "ERROR: failed to write phase0 bundle: $out" >&2; exit 1; }
}

# ===========================================================================
# Bundle writer — assembles the IC-3 skeleton. checks[] = the full battery as
# `skipped` placeholders at this stage. tool_availability includes grype
# (IC-6 consistency). external.vantage = none.
# ===========================================================================

# Helper: build the checks[] JSON array from the in-scope battery entries.
# Prints the resulting JSON to stdout.
_build_checks_json() {
  local checks_json="[]"
  local id dim needs_sudo mode cmd
  while IFS='|' read -r id dim needs_sudo mode cmd; do
    [ -z "$id" ] && continue
    if ! _dimension_in_scope "$dim"; then
      continue
    fi
    checks_json="$(printf '%s' "$checks_json" | jq \
      --arg id "$id" \
      --arg dim "$dim" \
      --argjson needs_sudo "$needs_sudo" \
      '. + [{
        id: $id,
        dimension: $dim,
        status: "skipped",
        evidence: null,
        source: "skeleton",
        raw_ref: null,
        needs_sudo: $needs_sudo
      }]')"
  done <<EOF
$(battery)
EOF
  printf '%s' "$checks_json"
}

write_bundle() {
  local checks_json
  checks_json="$(_build_checks_json)"

  # External vantage: skeleton never connects → none.
  local vantage="none"
  local proxy_json="null"
  if [ -n "$PROXY" ]; then
    proxy_json="$(printf '%s' "$PROXY" | jq -R '.')"
  fi

  jq -n \
    --arg host "$HOST_NAME" \
    --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg privilege_mode "insufficient-data" \
    --arg vantage "$vantage" \
    --argjson proxy_used "$proxy_json" \
    --argjson checks "$checks_json" \
    '{
      host: $host,
      collected_at: $collected_at,
      privilege_mode: $privilege_mode,
      os: { id: null, version: null, kernel: null },
      tool_availability: {
        lynis: null, nmap: null, trivy: null, grype: null,
        debsecan: null, needrestart: null, docker: null, ss: null
      },
      tools_installed_this_run: [],
      checks: $checks,
      external: {
        vantage: $vantage,
        proxy_used: $proxy_used,
        open_ports: [],
        tls: {},
        nuclei_findings: []
      }
    }' > "$OUT" || { echo "ERROR: failed to write bundle: $OUT" >&2; exit 1; }
}

# ===========================================================================
# Main flow
# ===========================================================================

# DD-3 consent-gated install hook. Suppressed entirely under --no-install
# (hard read-only). At the skeleton stage live installs are not wired; the
# point is that the consent block NEVER prints under --no-install.
maybe_consent_install() {
  if [ "$NO_INSTALL" = true ]; then
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    printf '[DRY-RUN] consent-install gate ACTIVE (per-host; declined → DEGRADED)\n'
  fi
  # Live install wiring lands in Task 5.
}

# Preview every command the run WOULD execute (dry-run dispatch through
# run_remote so the IC-8 prefix and bounds are exercised exactly as live).
preview_battery() {
  local id dim needs_sudo mode cmd
  while IFS='|' read -r id dim needs_sudo mode cmd; do
    [ -z "$id" ] && continue
    _dimension_in_scope "$dim" || continue
    run_remote "$id" "$mode" -- "$cmd"
  done <<EOF
$(battery)
EOF
}

main() {
  if [ "$DRY_RUN" = true ]; then
    printf '[DRY-RUN] infra-collect.sh — host=%s run-id=%s (no connections will be opened)\n' \
      "$HOST" "$RUN_ID"
    # Privilege probe preview.
    run_remote "privilege-probe" short -- "sudo -n true"
    # Consent-install gate preview (absent under --no-install).
    maybe_consent_install
    # Battery preview — every ssh/find line is emitted here.
    preview_battery
    # Bundle skeleton is still written so downstream tooling can validate IC-3.
    write_bundle
    printf '[DRY-RUN] bundle skeleton written: %s\n' "$OUT"
    exit 0
  fi

  # Live path (skeleton): write the IC-3 bundle with `skipped` placeholders.
  # The real check battery is implemented in Tasks 5-7.
  write_bundle
  exit 0
}

main
