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
: "${PREFLIGHT_TIMEOUT_S:=5}"      # TCP reachability preflight (nc -zw5; faster than ssh connect, AC1)
: "${WALL_CLOCK_LIMIT_S:=1800}"    # per-host 30-min wall clock (full mode)
: "${POLL_SLACK_S:=15}"           # extra seconds past CHECK_TIMEOUT_S to poll for .rc sidecar

# SECURITY (timeout-injection guard): every timeout constant above is env-
# overridable AND interpolated verbatim into remote/local command strings
# (e.g. `timeout ${CHECK_TIMEOUT_S} sh`, `trivy --timeout ${TRIVY_TIMEOUT_S}s`).
# A non-integer override (`CHECK_TIMEOUT_S='1; rm -rf /'`) would break out of the
# command and execute arbitrary code. Assert each is a bare positive integer
# (1+ digits, no sign/space/metachars) right here, before any use. Fail loud.
for _tvar in CHECK_TIMEOUT_S TRIVY_TIMEOUT_S CONNECT_TIMEOUT_S PREFLIGHT_TIMEOUT_S WALL_CLOCK_LIMIT_S POLL_SLACK_S; do
  # Indirect expansion (bash 3.2 `${!var}`), NOT eval — eval would EXECUTE any
  # metacharacters in a hostile env value BEFORE the integer check could reject it,
  # turning the injection guard into an injection vector.
  _tval="${!_tvar}"
  if ! printf '%s' "$_tval" | grep -Eq '^[0-9]+$'; then
    echo "ERROR: $_tvar must be a non-negative integer (got: '$_tval')" >&2
    exit 1
  fi
done
unset _tvar _tval

# IC-5 redaction. Case-insensitive sed program (TWO rules, joined by `;`):
#
# RULE 1 (key=value / key:value) — any KEY whose name CONTAINS a sensitive word
# (password/passwd/secret/token/apikey/privatekey/credential/database_url/
# redis_url/connection_string) — anywhere in the key token, so e.g.
# AWS_SECRET_ACCESS_KEY and DB_PASSWORD both match — has its VALUE replaced with
# [REDACTED]. Matches `key = value` / `key: value` / `KEY=value`. The leading key
# token `[A-Za-z0-9_.-]*<word>[A-Za-z0-9_.-]*` is captured and preserved; only the
# value after the first `:`/`=` separator is redacted.
#
# RULE 2 (redis-config space separator) — redis.conf carries auth secrets as
# `requirepass <value>` and `masterauth <value>` with a SPACE separator (no `:`/`=`),
# AND neither key contains a RULE-1 sensitive substring ("requirepass" has no
# "password"; "masterauth" has none). RULE 1 therefore misses them entirely. RULE 2
# is a dedicated, line-anchored redaction: a line that begins (after optional
# whitespace) with `requirepass`/`masterauth` followed by whitespace has the rest of
# the line ([REDACTED]). The line anchor `^[[:space:]]*` prevents redacting the word
# when it appears mid-sentence in prose/log output — only genuine config directives.
#
# BEFORE the value is written to the bundle or any raw file, so analysts never see
# secrets. Verify: a redis.conf line `requirepass zuvo-seed-redispw-2e6f` →
# `requirepass [REDACTED]`.
#
# LIMITATION (line-oriented): sed processes ONE line at a time, and the value
# pattern ends at end-of-line. A MULTI-LINE secret value (e.g. a PEM-encoded RSA
# private key spanning many lines) only has its FIRST line redacted; subsequent
# lines are not matched. Single-line `KEY=value` secrets (the common .env / conf
# shape) ARE fully redacted. Do not rely on this for multi-line key material.
SED_REDACT='s/(([A-Za-z0-9_.-]*(password|passwd|secret|token|api[_-]?key|private[_-]?key|credential|DATABASE_URL|REDIS_URL|connection[_-]?string)[A-Za-z0-9_.-]*)[[:space:]]*[:=][[:space:]]*).*/\1[REDACTED]/Ig;s/^([[:space:]]*(requirepass|masterauth)[[:space:]]+).*/\1[REDACTED]/Ig'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CQ14: single-source tool_availability default object. Both write_bundle (dry-run
# skeleton) and _write_live_bundle (live incremental) merge against this constant so
# the tool list is defined exactly once here, not duplicated at two call sites.
TOOL_AVAIL_DEFAULTS='{"lynis":null,"nmap":null,"trivy":null,"grype":null,"debsecan":null,"needrestart":null,"docker":null,"ss":null}'

# IC-4 nuclei template enforcement. The collector invokes nuclei ONLY with this
# pinned allowlist — defined ONCE here as named constants (CQ14 single-source) so
# the AC3 dry-run audit can assert no other tag set ever appears. v2's active
# categories are opt-in by design; the safe set is exposure/misconfig/recon only,
# and the excluded set bars every intrusive / DoS / brute / fuzz / default-login
# template class. NEVER reconstruct these inline — always interpolate the consts.
NUCLEI_SAFE_TAGS='exposures,misconfiguration,technologies,ssl,dns'
NUCLEI_EXCLUDE_TAGS='intrusive,dos,fuzz,bruteforce,default-login'

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
  --raw-dir <path>          Directory for redacted raw tool output (raw_ref targets)
  --ssh-key <path>          Identity file for ssh -i (the inventory ssh_key PATH; §4)
  --known-hosts <path>      UserKnownHostsFile for host-key verification (StrictHostKeyChecking stays =yes)

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
RAW_DIR=""
SSH_KEY=""
KNOWN_HOSTS=""

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
    --raw-dir)     _need_val --raw-dir $#; RAW_DIR="$2"; shift 2 ;;
    --ssh-key)     _need_val --ssh-key $#; SSH_KEY="$2"; shift 2 ;;
    --known-hosts) _need_val --known-hosts $#; KNOWN_HOSTS="$2"; shift 2 ;;
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

# --raw-dir: default beside --out (so analysts can resolve raw_ref). Created
# fresh per run; redacted raw tool output lands here (never the unredacted form).
if [ -z "$RAW_DIR" ]; then
  RAW_DIR="${OUT%.json}-raw"
fi
# Validate --raw-dir charset (lands in no remote command; local path only, but
# keep it sane). Create it eagerly (live mode) so writers never race on it.
if ! printf '%s' "$RAW_DIR" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
  echo "ERROR: malformed --raw-dir '$RAW_DIR'" >&2
  exit 1
fi
# Reject path traversal: a `..` component (e.g. `../../sensitive/out-raw`) would
# let redacted-but-sensitive raw output be written outside the audit workspace.
case "/$RAW_DIR/" in
  */../*)
    echo "ERROR: --raw-dir must not contain '..' path components: $RAW_DIR" >&2
    exit 1
    ;;
esac

# --known-hosts charset validation (CQ3). The value is word-split into the ssh
# command line as `-o UserKnownHostsFile=<value>` via $SSH_ID_OPTS; an
# unvalidated path with embedded spaces or shell metacharacters (e.g.
# `--known-hosts '/tmp/x -oProxyCommand=...'`) would inject additional ssh
# flags. Restrict to the same safe charset as --raw-dir: alphanumeric + . _ / -
if [ -n "$KNOWN_HOSTS" ] && ! printf '%s' "$KNOWN_HOSTS" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
  echo "ERROR: malformed --known-hosts '$KNOWN_HOSTS' (allowed: A-Z a-z 0-9 . _ / -)" >&2
  usage
  exit 1
fi

# IC-4 external-scan proxy resolution + validation. Resolution order:
#   --proxy flag  >  $ZUVO_SCAN_PROXY env  (hosts-yaml default is passed by the
#   caller as --proxy, so it folds into the flag tier). Whichever wins becomes
#   $PROXY for the rest of the run.
: "${ZUVO_SCAN_PROXY:=}"
if [ -z "$PROXY" ] && [ -n "$ZUVO_SCAN_PROXY" ]; then
  PROXY="$ZUVO_SCAN_PROXY"
fi

# SECURITY (CQ3 / injection guard): $PROXY is interpolated verbatim into external
# command strings (`proxychains4 ... `, `nuclei -proxy $PROXY ...`) and into the
# IC-4 proxychains.conf. An unvalidated value with shell metacharacters or spaces
# (e.g. `socks5://h:1 -tags intrusive` or `; rm -rf /`) would break out of the
# command / inject extra nuclei flags, defeating the pinned allowlist. Restrict to
# a strict URL charset: scheme ∈ {socks5,socks4,http}, host = safe hostname/IPv4
# charset, port = bare integer. Reject anything else, fail loud (exit 1).
if [ -n "$PROXY" ] && ! printf '%s' "$PROXY" | grep -Eq '^(socks5|socks4|http)://[A-Za-z0-9._-]+:[0-9]+$'; then
  echo "ERROR: malformed --proxy '$PROXY' (expected (socks5|socks4|http)://host:port)" >&2
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

# Validate SSH_ADDR charset (CQ3 / injection guard). The --host addr regex
# `[^@:[:space:]]+` is permissive — it admits shell metacharacters (`;`, `$`,
# backtick, `(`, `/`) that would break out of the reachability preflight
# (`/dev/tcp/$SSH_ADDR/$SSH_PORT`) and any other string the addr lands in.
# Restrict to a strict hostname / IPv4 charset: letters, digits, dot, hyphen,
# underscore. Anything else is rejected before SSH_ADDR is ever used.
if ! printf '%s' "$SSH_USER" | grep -Eq '^[A-Za-z0-9._-]+$'; then
  echo "ERROR: --host user '$SSH_USER' has invalid characters (allowed: letters, digits, . _ -)" >&2
  usage
  exit 1
fi
if ! printf '%s' "$SSH_ADDR" | grep -Eq '^[A-Za-z0-9._-]+$'; then
  echo "ERROR: --host address '$SSH_ADDR' contains illegal characters (allowed: A-Z a-z 0-9 . _ -)" >&2
  usage
  exit 1
fi

# Bundle host name = address (collector audits a single ad-hoc host).
HOST_NAME="$SSH_ADDR"

REMOTE_RUN_DIR="/tmp/${RUN_ID}"

# Identity / known-hosts options, kept SEPARATE from the IC-8 $SSH_OPTS constant
# (which must appear verbatim exactly once). The collector receives only PATHS
# here — it never reads key material (ssh-probe-protocol §4); ssh resolves -i.
# StrictHostKeyChecking is never weakened; --known-hosts only RELOCATES the
# verification file (needed because ssh on macOS resolves ~ via getpwuid, not
# $HOME, so an isolated known_hosts can't be supplied via HOME alone).
# SSH_ID_OPTS is a bash ARRAY, not a word-split string. Each option and its
# argument is a SEPARATE element, so a key/known-hosts PATH containing spaces or
# a leading `-` can NEVER be re-parsed by ssh as an injected flag (SSH option
# injection). Expanded as `"${SSH_ID_OPTS[@]}"` at every ssh call site. Bash 3.2
# supports indexed arrays, so this stays macOS-system-bash compatible.
SSH_ID_OPTS=()
if [ -n "$SSH_KEY" ]; then
  # Charset validation (injection guard, parallels --known-hosts). An unvalidated
  # path with spaces or a leading `-` basename (e.g. `-oProxyCommand=evil`) would
  # be treated by ssh as flags. Restrict to the safe path charset.
  if ! printf '%s' "$SSH_KEY" | grep -Eq '^[A-Za-z0-9._/-]+$'; then
    echo "ERROR: malformed --ssh-key '$SSH_KEY' (allowed: A-Z a-z 0-9 . _ / -)" >&2
    usage
    exit 1
  fi
  # Forbid a leading `-` on the basename: `-oProxyCommand=x` or `dir/-flag` would
  # let ssh parse the identity path as an option even though it passed charset.
  _ssh_key_base="${SSH_KEY##*/}"
  case "$_ssh_key_base" in
    -*)
      echo "ERROR: --ssh-key basename must not begin with '-': $SSH_KEY" >&2
      usage
      exit 1
      ;;
  esac
  unset _ssh_key_base
  if [ ! -f "$SSH_KEY" ]; then
    echo "ERROR: --ssh-key path does not exist: $SSH_KEY" >&2
    exit 1
  fi
  SSH_ID_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
fi
if [ -n "$KNOWN_HOSTS" ]; then
  SSH_ID_OPTS+=(-o "UserKnownHostsFile=$KNOWN_HOSTS")
fi

# ===========================================================================
# run_remote() — SINGLE dispatch point for every remote command (IC-8).
#
#   run_remote <check-id> <short|long> -- <remote command...>
#
#   short → bounded `timeout` ssh; output captured to stdout, exit code via $?.
#   long  → command may exceed 30s → wrapped in the nohup pattern
#           (ssh-probe-protocol §2: server-side timeout + .rc sidecar +
#           stream redirection), then retrieval polls the .rc file and the
#           captured .out is streamed back to stdout.
#
# In --dry-run it PRINTS the full ssh command line it WOULD run (IC-8 flags + the
# remote command, including `--` and `-xdev`) and returns 0 without connecting —
# this printed form is the CLI-test contract surface (Task 4).
#
# QUOTE-SAFE TRANSPORT (B-infra-collect-nohup-quote-transport):
# The inner battery command is NEVER string-embedded into a remote `sh -c '...'`.
# Instead it is base64-encoded on the collector and decoded+exec'd on the target
# (`base64 -d | sh`). A single quote inside an awk/sed/find battery command —
# which abound — therefore cannot terminate any wrapper. Verified by the live
# suite (IS2 `awk '($3==0){print $1}'`).
# ===========================================================================

# Tracks whether the per-host run dir has been claimed (mkdir once per run).
RUN_DIR_CLAIMED=false

# SUDO_PREFIX is set per-check by _collect_battery_json: empty, or the literal
# `sudo -n ` when the check needs_sudo AND privilege_mode grants passwordless
# sudo. It is prepended to the REMOTE INTERPRETER (`sudo -n sh`), so the entire
# decoded battery script runs as root — compound commands and all — without any
# per-command quoting (the base64 transport keeps the script itself inert).
SUDO_PREFIX=""

run_remote() {
  local check_id="$1"; shift
  local mode="$1"; shift
  # consume the literal "--" separator
  if [ "${1:-}" = "--" ]; then shift; fi
  local remote_cmd="$*"

  if [ "$DRY_RUN" = true ]; then
    # Preview the HUMAN-READABLE ssh form (IC-8 flags + the literal battery
    # command). For `long` mode also show the nohup wrapper shape so the dry-run
    # makes the run-dir + sidecar visible. The printed form is what the CLI test
    # greps for the IC-8 flag string and `-xdev` on find lines.
    if [ "$mode" = "long" ]; then
      _dry_print "$check_id" \
        "nohup sh -c 'base64 -d <<EOF | timeout ${CHECK_TIMEOUT_S} sh > ${REMOTE_RUN_DIR}/${check_id}.out 2>&1; echo \$? > ${REMOTE_RUN_DIR}/${check_id}.rc' & : ${remote_cmd}"
    else
      _dry_print "$check_id" "timeout ${CHECK_TIMEOUT_S} sh -c : ${remote_cmd}"
    fi
    return 0
  fi

  if [ "$mode" = "long" ]; then
    # The run dir is claimed ONCE, eagerly, by collect_live() before the battery
    # loop — NOT lazily here. run_remote runs inside `raw="$(run_remote …)"`
    # command-substitution subshells, so a `RUN_DIR_CLAIMED=true` set here would
    # be lost when the subshell exits, making every long check after the first
    # re-claim the (now-existing) dir and fail closed. Eager claim in the parent
    # shell avoids that entirely.
    _ssh_exec_long "$check_id" "$remote_cmd"
  else
    _ssh_exec_short "$remote_cmd"
  fi
}

# Dry-run pretty-printer: emits one `ssh <IC-8 flags> -- dest <cmd>` line so the
# CLI test can grep the verbatim IC-8 string, the `--` guard, and `-xdev`.
_dry_print() {
  local check_id="$1" remote_cmd="$2"
  printf '[DRY-RUN] WOULD run (%s): LC_ALL=C ssh %s -p %s -- %s@%s %s\n' \
    "$check_id" "$SSH_OPTS" "$SSH_PORT" "$SSH_USER" "$SSH_ADDR" "$remote_cmd"
}

# Claim the per-host scratch dir exactly once (atomic; fail-closed on EEXIST).
# Live path MUST fail closed: a failed `mkdir -m 700` (EEXIST/symlink/perm) means
# the run dir was hijacked or unwritable; per ssh-probe-protocol §2 we emit a
# phase0 bundle (reason `run-dir-claim-failed` + captured stderr) and exit 1 —
# never silently continue into checks that would write into an unclaimed dir.
_claim_run_dir() {
  local claim="mkdir -m 700 ${REMOTE_RUN_DIR} || { echo 'run dir exists — refusing'; exit 1; }"
  local claim_err claim_rc
  claim_err="$(_ssh_raw "$claim" 2>&1 >/dev/null)"
  claim_rc=$?
  if [ "$claim_rc" -ne 0 ]; then
    local redacted_err
    redacted_err="$(printf '%s' "$claim_err" | LC_ALL=C sed -E "$SED_REDACT")"
    phase0_writer "FAILED" "run-dir-claim-failed" "$redacted_err"
    echo "ERROR: run-dir claim failed (rc=$claim_rc) on $HOST_NAME — see phase0 bundle: $OUT" >&2
    exit 1
  fi
}

# _ssh_raw — lowest-level ssh dispatch for a literal (non-base64) control string.
# Used only for fixed control commands the collector itself constructs (run-dir
# claim, .rc poll, .out fetch). Every battery command goes via the base64 path.
# `--` ends ssh option parsing before the destination (option-injection guard).
# The full IC-8 flag string ($SSH_OPTS) is applied here — one of exactly two ssh
# call sites, both interpolating the single SSH_OPTS constant.
_ssh_raw() {
  local remote_cmd="$1"
  # `< /dev/null`: never inherit the caller's stdin. The battery is driven by a
  # `while read` loop reading a heredoc; an ssh that read THAT stdin would drain
  # the remaining battery rows and silently truncate the run after the first
  # long check. Control commands carry no stdin payload, so closing it is safe.
  # $SSH_OPTS stays word-split (it is the trusted IC-8 constant). SSH_ID_OPTS is
  # an array expanded with the empty-safe `${arr[@]+...}` idiom (bash 3.2 + set -u
  # errors on a bare `"${arr[@]}"` when the array is empty) so key/known-hosts
  # paths remain single args, immune to word-splitting / option injection.
  LC_ALL=C ssh $SSH_OPTS ${SSH_ID_OPTS[@]+"${SSH_ID_OPTS[@]}"} -p "$SSH_PORT" -- "$SSH_USER@$SSH_ADDR" "$remote_cmd" < /dev/null
}

# _ssh_b64 — QUOTE-SAFE transport: base64-encode the inner command locally, ship
# it as stdin, decode it and run it AS A SCRIPT under `sh` on the target. Because
# the battery command becomes `sh`'s stdin script (not a shell-string argument),
# pipes / semicolons / single quotes inside it are completely inert during
# transport — the remote control string (`base64 -d | timeout N sh`) is constant
# and quote-free. This is the only mechanism that runs battery commands.
#
#   $1 = inner command (a full /bin/sh script; may be compound, may quote)
#   $2 = "nohup-wrap" (optional) → don't run inline; emit a launcher that detaches
#        the script under nohup with a server-side timeout and an .rc sidecar (§2).
_ssh_b64() {
  local inner="$1"
  printf '%s' "$inner" | base64 \
    | LC_ALL=C ssh $SSH_OPTS ${SSH_ID_OPTS[@]+"${SSH_ID_OPTS[@]}"} -p "$SSH_PORT" -- "$SSH_USER@$SSH_ADDR" \
        "base64 -d | timeout ${CHECK_TIMEOUT_S} ${SUDO_PREFIX}sh"
}

# Short check: the decoded script runs inline under a server-side timeout.
# stdout is the (raw) command output; caller redacts before persisting.
_ssh_exec_short() {
  local remote_cmd="$1"
  _ssh_b64 "$remote_cmd" 2>/dev/null
}

# Long check (ssh-probe-protocol §2). Two CLEANLY SEPARATED round trips:
#   1. ship the battery command to a remote .cmd file via the base64 transport —
#      a plain `base64 -d > cmd_f` with NO backgrounding (so the quote-safe
#      stdin pipe and process detachment never interfere with each other);
#   2. a second, CONSTANT control command launches `cmd_f` under nohup with a
#      server-side timeout + .rc sidecar — the launcher embeds only filenames
#      and the timeout (no battery command), so its single quotes are inert.
# Retrieval then polls (bounded) for the .rc completion marker and streams the
# captured .out back.
_ssh_exec_long() {
  local check_id="$1" remote_cmd="$2"
  local out_f="${REMOTE_RUN_DIR}/${check_id}.out"
  local rc_f="${REMOTE_RUN_DIR}/${check_id}.rc"
  local cmd_f="${REMOTE_RUN_DIR}/${check_id}.cmd"

  # 1. Materialize the battery command remotely (quote-safe; no `&`).
  printf '%s' "$remote_cmd" | base64 \
    | LC_ALL=C ssh $SSH_OPTS ${SSH_ID_OPTS[@]+"${SSH_ID_OPTS[@]}"} -p "$SSH_PORT" -- "$SSH_USER@$SSH_ADDR" \
        "base64 -d > ${cmd_f}" >/dev/null 2>&1 || true

  # 2. Launch under nohup with the .rc sidecar. Control string is constant
  #    (filenames + timeout + optional sudo) — battery command not embedded.
  local launcher="nohup sh -c 'timeout ${CHECK_TIMEOUT_S} ${SUDO_PREFIX}sh ${cmd_f} > ${out_f} 2>&1; echo \$? > ${rc_f}' < /dev/null > /dev/null 2>&1 &"
  _ssh_raw "$launcher" >/dev/null 2>&1 || true

  # Poll (bounded by CHECK_TIMEOUT_S + slack) for the .rc completion marker.
  local waited=0 poll_max=$((CHECK_TIMEOUT_S + POLL_SLACK_S))
  while [ "$waited" -lt "$poll_max" ]; do
    if _ssh_raw "test -f ${rc_f}" >/dev/null 2>&1; then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done
  # Stream the captured output back (may be empty if the check produced nothing).
  _ssh_raw "cat ${out_f} 2>/dev/null" 2>/dev/null || true
}

# ===========================================================================
# Check battery declaration.
#
# One entry per representative check, parsed as:
#   id | dimension | needs_sudo | mode | tool | cmd
#
#   mode = short|long  (long = lynis/nmap/trivy class, >30s → nohup §2).
#   tool = `-` for a check requiring no special tool (always runnable when the
#          host has a POSIX shell + coreutils), otherwise the tool that MUST be
#          present in tool_availability for the check to run. When that tool is
#          absent (and not installed — e.g. --no-install) the check is `skipped`
#          (AC9), and crucially NO CVE string is ever fabricated (AC6).
#
# The cmd is a STATIC predefined battery command (never host- or user-
# interpolated — ssh-probe-protocol §2). The cmd CAN contain single quotes
# (awk/find/sed); the base64 transport in run_remote keeps that quote-safe.
#
# IDs are drawn EXACTLY from infra-check-registry.md; ≥1 per IS1..IS12.
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
# Column layout (parsed by `read -r id dim needs_sudo mode tool match_re cmd`):
#   id | dimension | needs_sudo | mode | tool | match_re | cmd
# Columns 1-6 are pipe-free; `cmd` (column 7) absorbs all remaining text and MAY
# contain embedded `|` (shell pipelines) — `read` with 7 names assigns the rest
# to the final variable, so embedded pipes in `cmd` stay intact.
#
# Column 5 (tool): `lynis`/`trivy`/`ss`/`docker`/... must exist in
# tool_availability for the row to run; `-` = always runnable.
#
# Column 6 (match_re) — DETERMINISTIC FINDING CLASSIFIER (DD-5, DD-8, IC-3):
#   The collector DETECTS; the LLM only interprets. A case-insensitive POSIX
#   extended regex evaluated against the redacted evidence. If it MATCHES, the
#   check status becomes `finding` (the misconfiguration is present); if it does
#   NOT match (and the check ran cleanly with its IC-7 sanity marker), status
#   stays `ok`. `-` = no positive-match rule (informational/listener checks the
#   analyst reads as evidence). The regex is a STATIC, internally-authored
#   pattern — never host- or user-derived — so it is safe to evaluate against
#   attacker-influenced evidence with `grep -iE` (no eval; evidence is data).
#   Because the battery is `|`-delimited, a match_re MUST NOT contain a literal
#   `|`; ERE alternation is written with the placeholder `~~` (translated back to
#   `|` by _classify_finding immediately before the grep).
battery() {
  cat <<EOF
IS1-sshd-permitrootlogin|IS1|true|short|-|permitrootlogin[[:space:]]+(yes~~prohibit-password~~without-password)|sshd -T 2>/dev/null | grep -i permitrootlogin || grep -i '^[[:space:]]*permitrootlogin' /etc/ssh/sshd_config
IS1-lynis-hardening|IS1|true|long|lynis|hardening index[[:space:]]*:?[[:space:]]*([0-5][0-9]~~[0-9])([^0-9]~~\$)|lynis audit system --quick --no-colors 2>/dev/null | grep -i 'Hardening index'; HI=\$(grep -i '^hardening_index=' /var/log/lynis-report.dat 2>/dev/null | head -1 | cut -d= -f2); [ -n "\$HI" ] && echo "Hardening index : \$HI"
IS2-uid0-nonroot|IS2|false|short|-|UID0-EXTRA|awk -F: '(\$3==0){print \$1}' /etc/passwd | awk 'BEGIN{x=0} \$0!="root"{x=1} END{if(x)print "UID0-EXTRA: non-root uid-0 account present"}' ; awk -F: '(\$3==0){print \$1}' /etc/passwd
IS3-unexpected-listener|IS3|false|short|ss|-|ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null
IS4-weak-protocols|IS4|false|short|-|-|echo 'IS4-EXTERNAL-ONLY: TLS protocol/cipher inspection requires an external vantage (testssl) — not covered by the internal battery'
IS5-ufw-disabled|IS5|true|short|-|inactive~~disabled~~no-firewall-tool~~Chain INPUT \(policy ACCEPT|ufw status verbose 2>/dev/null || iptables -L -n 2>/dev/null || echo 'no-firewall-tool'
IS6-security-updates-pending|IS6|true|long|debsecan|CVE-[0-9]{4}-[0-9]+|debsecan --suite "\$(lsb_release -cs 2>/dev/null)" --format detail 2>/dev/null
IS7-fail2ban-missing|IS7|false|short|-|inactive~~failed~~not-found|systemctl is-active fail2ban 2>/dev/null || echo inactive
IS8-exposed-admin-panel|IS8|false|short|-|:(8080~~8443~~9000~~3000)([^0-9]~~\$)|ss -tlnp 2>/dev/null | grep -iE ':(80|443|8080|8443|9000|3000)\b' || echo 'no-web-listener'
IS9-socket-world-readable|IS9|true|short|-|^.{7}rw|ls -l /var/run/docker.sock 2>/dev/null || echo 'no-docker-socket'
IS9-image-critical-cve|IS9|true|long|trivy|CVE-[0-9]{4}-[0-9]+|img=\$(docker ps --format '{{.Image}}' 2>/dev/null | head -1); [ -n "\$img" ] && trivy image --timeout ${TRIVY_TIMEOUT_S}s --skip-update --severity CRITICAL --quiet -- "\$img" 2>/dev/null
IS10-redis-no-auth|IS10|true|short|-|bind[[:space:]]+0\.0\.0\.0~~protected-mode[[:space:]]+no~~no-requirepass|if [ -f /etc/redis/redis.conf ]; then grep -iE '^[[:space:]]*(requirepass|bind|protected-mode)' /etc/redis/redis.conf 2>/dev/null; grep -qiE '^[[:space:]]*requirepass[[:space:]]' /etc/redis/redis.conf 2>/dev/null || echo 'no-requirepass'; else echo 'no-redis-conf'; fi
IS11-suid-unexpected|IS11|true|long|-|/usr/local/~~^/tmp/~~/home/~~/opt/|find / -xdev -path /proc -prune -o -path /sys -prune -o -path /run -prune -o -perm -4000 -type f -print 2>/dev/null
IS12-world-readable-env|IS12|true|long|-|world-readable secret file|find / -xdev -path /proc -prune -o -path /sys -prune -o -path /run -prune -o -name '.env' -perm /044 -type f -print 2>/dev/null | while read -r f; do perms=\$(stat -c '%a %n' "\$f" 2>/dev/null || stat -f '%Lp %N' "\$f" 2>/dev/null); n=\$(grep -cE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "\$f" 2>/dev/null); echo "== world-readable secret file: \$perms (keys: \${n:-0}) =="; grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*' "\$f" 2>/dev/null | sed 's/^[[:space:]]*//'; done
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
# Dry-run bundle writer — IC-3 skeleton with `skipped` placeholders (no live
# collection). Live collection happens in collect_live() below.
# ===========================================================================

# Helper: build the checks[] JSON array from the in-scope battery entries
# (skeleton placeholders, for --dry-run only). Prints JSON to stdout.
_build_checks_json() {
  local checks_json="[]"
  local id dim needs_sudo mode tool match_re cmd
  while IFS='|' read -r id dim needs_sudo mode tool match_re cmd; do
    [ -z "$id" ] && continue
    _dimension_in_scope "$dim" || continue
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

  # IC-4: the skeleton records the SAME resolved external vantage as the live path.
  # With no --proxy and no `--external direct` this is `none` (the CLI-test
  # contract for the default dry-run); a proxy/direct run reflects the real state.
  _resolve_vantage
  local vantage="$EXTERNAL_VANTAGE"
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
    --argjson tool_defaults "$TOOL_AVAIL_DEFAULTS" \
    '{
      host: $host,
      collected_at: $collected_at,
      privilege_mode: $privilege_mode,
      os: { id: null, version: null, kernel: null },
      tool_availability: $tool_defaults,
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
# External vantage leg (Task 7 / IC-4).
#
# The external view scans the host's PUBLIC attack surface from the operator's
# laptop, routed through a user-supplied proxy so a fail2ban ban lands on the
# proxy IP, not the SSH management IP (DD-4). Per-tool mechanism:
#   - nmap (-sT TCP connect) + testssl.sh  → wrapped in proxychains-ng
#     (handles SOCKS5/HTTP transparently; testssl's native --proxy is
#      HTTP-CONNECT-only, so it is NEVER used with a SOCKS proxy).
#   - nuclei → its native `-proxy` (supports socks5://, http://), invoked ONLY
#     with the pinned $NUCLEI_SAFE_TAGS / $NUCLEI_EXCLUDE_TAGS allowlist.
#
# vantage state machine (external.vantage ∈ proxy|direct|none|failed):
#   --skip-external                         → none
#   no proxy AND not `--external direct`    → none
#   `--external direct`                     → direct (-T2 --max-rate 50 + abort
#                                             after 3 consecutive refused, DD-4)
#   proxy set, proxychains-ng absent        → none + preflight warning (IC-4)
#   proxy set, proxychains-ng present,
#       proxy unreachable                   → failed
#   proxy set, proxychains-ng present,
#       proxy reachable                     → proxy
# ===========================================================================

# Module-level external state, consumed by the bundle writers.
EXTERNAL_VANTAGE="none"
# The host being scanned externally = the SSH address (the public surface of the
# host under audit). No user/port interpolation beyond the already-validated addr.
EXTERNAL_TARGET="$SSH_ADDR"

# Detect a proxychains-ng binary. Prints the binary NAME on stdout (one of
# proxychains4 / proxychains-ng / proxychains, in preference order) and returns 0
# when found; prints nothing and returns 1 when none is on PATH (IC-4 degrade).
_detect_proxychains() {
  local b
  for b in proxychains4 proxychains-ng proxychains; do
    if command -v "$b" >/dev/null 2>&1; then
      printf '%s' "$b"
      return 0
    fi
  done
  return 1
}

# Reachability of the proxy endpoint (parse host:port out of the validated URL).
# Returns 0 reachable, 1 not. Reuses the same bounded nc/timeout probe shape as
# _reachable. Host/port are passed as POSITIONAL ARGS, never interpolated into a
# shell string (defense-in-depth; both already pass the strict --proxy charset).
_proxy_reachable() {
  local hostport rest phost pport
  hostport="${PROXY#*://}"          # strip scheme
  phost="${hostport%:*}"
  pport="${hostport##*:}"
  local tmo=""
  if command -v timeout >/dev/null 2>&1; then tmo="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then tmo="gtimeout"; fi
  if command -v nc >/dev/null 2>&1; then
    if [ -n "$tmo" ]; then
      "$tmo" "$PREFLIGHT_TIMEOUT_S" nc -z "$phost" "$pport" >/dev/null 2>&1
      return $?
    fi
    if nc -h 2>&1 | grep -q -- '-G'; then
      nc -G "$PREFLIGHT_TIMEOUT_S" -z "$phost" "$pport" >/dev/null 2>&1
      return $?
    fi
    nc -z -w "$PREFLIGHT_TIMEOUT_S" "$phost" "$pport" >/dev/null 2>&1
    return $?
  fi
  if [ -n "$tmo" ]; then
    "$tmo" "$PREFLIGHT_TIMEOUT_S" bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$phost" "$pport" >/dev/null 2>&1
  else
    ( exec 3<>"/dev/tcp/$phost/$pport" ) >/dev/null 2>&1
  fi
}

# Resolve EXTERNAL_VANTAGE from flags + proxy state. Pure decision logic; emits a
# preflight warning to stderr on the proxychains-absent degrade path (IC-4). Sets
# EXTERNAL_VANTAGE. Idempotent — safe to call from dry-run and live.
_resolve_vantage() {
  if [ "$SKIP_EXTERNAL" = true ]; then
    EXTERNAL_VANTAGE="none"
    return 0
  fi
  if [ -z "$PROXY" ]; then
    if [ "$EXTERNAL_MODE" = "direct" ]; then
      EXTERNAL_VANTAGE="direct"
    else
      EXTERNAL_VANTAGE="none"
    fi
    return 0
  fi
  # Proxy configured: require proxychains-ng for the nmap/testssl legs (IC-4).
  if ! _detect_proxychains >/dev/null 2>&1; then
    echo "WARN: proxychains-ng not found on PATH — external vantage degraded to 'none' (IC-4). Install proxychains-ng to enable proxied external scans." >&2
    EXTERNAL_VANTAGE="none"
    return 0
  fi
  # In --dry-run we never open a socket — assume the proxy would be used so the
  # command preview is emitted; live mode probes reachability below.
  if [ "$DRY_RUN" = true ]; then
    EXTERNAL_VANTAGE="proxy"
    return 0
  fi
  if _proxy_reachable; then
    EXTERNAL_VANTAGE="proxy"
  else
    echo "WARN: external proxy $PROXY unreachable — external vantage 'failed' (internal checks unaffected)" >&2
    EXTERNAL_VANTAGE="failed"
  fi
}

# Dry-run preview of the external command battery (DD-9). Prints the proxychains-
# wrapped nmap (-sT) + testssl.sh lines and the nuclei native-`-proxy` line with
# the pinned allowlist, exactly as they WOULD run. Emitted only when the resolved
# vantage actually performs external scanning (proxy or direct).
preview_external() {
  _resolve_vantage
  if [ "$EXTERNAL_VANTAGE" = "none" ] || [ "$EXTERNAL_VANTAGE" = "failed" ]; then
    printf '[DRY-RUN] external vantage=%s — no external scan commands (IC-4)\n' "$EXTERNAL_VANTAGE"
    return 0
  fi
  if [ "$EXTERNAL_VANTAGE" = "direct" ]; then
    # DD-4 direct mode: polite timing + abort threshold; no proxychains wrapper.
    printf '[DRY-RUN] WOULD run (external-nmap, direct): nmap -sT -T2 --max-rate 50 -- %s\n' "$EXTERNAL_TARGET"
    printf '[DRY-RUN] WOULD run (external-testssl, direct): testssl.sh --quiet -- %s\n' "$EXTERNAL_TARGET"
    printf '[DRY-RUN] WOULD run (external-nuclei, direct): nuclei -target %s -tags %s -exclude-tags %s\n' \
      "$EXTERNAL_TARGET" "$NUCLEI_SAFE_TAGS" "$NUCLEI_EXCLUDE_TAGS"
    printf '[DRY-RUN] direct mode aborts after 3 consecutive connection-refused (DD-4)\n'
    return 0
  fi
  # proxy mode: nmap + testssl via proxychains-ng; nuclei via native -proxy.
  local pc; pc="$(_detect_proxychains)"
  printf '[DRY-RUN] WOULD run (external-nmap, proxy): %s nmap -sT -- %s\n' "$pc" "$EXTERNAL_TARGET"
  printf '[DRY-RUN] WOULD run (external-testssl, proxy): %s testssl.sh --quiet -- %s\n' "$pc" "$EXTERNAL_TARGET"
  printf '[DRY-RUN] WOULD run (external-nuclei, proxy): nuclei -target %s -proxy %s -tags %s -exclude-tags %s\n' \
    "$EXTERNAL_TARGET" "$PROXY" "$NUCLEI_SAFE_TAGS" "$NUCLEI_EXCLUDE_TAGS"
}

# ===========================================================================
# Live collection (Task 5).
# ===========================================================================

# Module-level state populated by the live probes, consumed by collect_live().
PRIVILEGE_MODE="insufficient-data"
# Space-separated list of tools detected present (`command -v` hit). Bash-3.2
# compatible — no associative arrays.
TOOLS_PRESENT=""
# JSON object built incrementally for tool_availability.
TOOL_AVAIL_JSON='{}'

# E12 lynis-version state. _probe_tools resolves the remote lynis version into
# this (empty if lynis absent / version unparsed). When non-empty AND < 3.0, the
# bundle records the version STRING in tool_availability.lynis (not bare true)
# and every lynis-sourced check is tagged `DEGRADED (lynis <ver> < 3.0)` while
# its manual fallback (config reads) still runs (E12). LYNIS_DEGRADED is the
# precomputed boolean; LYNIS_DEGRADE_NOTE the verbatim notation appended to
# affected check evidence.
LYNIS_VERSION=""
LYNIS_DEGRADED=false
LYNIS_DEGRADE_NOTE=""

# IC-7 sanity markers (DD-8): a check whose tool output MUST contain a minimum
# marker to count as a successful parse. Missing marker ⇒ status `error` +
# raw_ref (never silently `ok`). Keyed by check id; `-` / unset = no mandatory
# marker (most checks are config greps where empty output is a legitimate
# answer). Bash-3.2: case lookup, not an associative array.
_sanity_marker() {
  case "$1" in
    IS1-lynis-hardening) printf 'Hardening index' ;;
    *) printf '' ;;
  esac
}

# E12 / DD-8: which checks draw their primary evidence from lynis (so they are
# the ones degraded when lynis < 3.0). Keyed by check id.
_check_is_lynis_sourced() {
  case "$1" in
    IS1-lynis-hardening) return 0 ;;
    *) return 1 ;;
  esac
}

# Test-only fault-injection hook (IC-7 negative path coverage). ZUVO_FORCE_ERROR_CHECK
# is a comma-separated list of check ids whose output is treated as missing its
# sanity marker, forcing status `error` + raw_ref — exercising the defensive
# per-check capture without a flaky truncated transport. NEVER set in production;
# the default-empty value is inert. Documented for the hardening suite (Task 6).
: "${ZUVO_FORCE_ERROR_CHECK:=}"
_check_force_error() {
  [ -z "$ZUVO_FORCE_ERROR_CHECK" ] && return 1
  case ",$ZUVO_FORCE_ERROR_CHECK," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# Reachability preflight (AC1). Fast bounded TCP probe BEFORE any ssh handshake
# so a black-hole host fails in ~$CONNECT_TIMEOUT_S instead of waiting out the
# OS connect timeout (and the ssh ConnectTimeout chain). Returns 0 reachable,
# 1 unreachable.
#
# Portability: BSD `nc -w` (macOS) is only the POST-connect idle timeout, NOT the
# connect timeout — a black-hole address would hang for ~75s. So the probe is
# wrapped in a HARD wall-clock `timeout`/`gtimeout` of $CONNECT_TIMEOUT_S, which
# bounds connect on every platform. Without a timeout binary we fall back to
# BSD nc's `-G` connect-timeout (GNU/Linux nc lacks `-G`, but there `-w` already
# bounds connect, so the plain `nc -w` path applies).
_reachable() {
  local tmo=""
  if command -v timeout >/dev/null 2>&1; then tmo="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then tmo="gtimeout"; fi

  if command -v nc >/dev/null 2>&1; then
    if [ -n "$tmo" ]; then
      "$tmo" "$PREFLIGHT_TIMEOUT_S" nc -z "$SSH_ADDR" "$SSH_PORT" >/dev/null 2>&1
      return $?
    fi
    # No timeout binary: try BSD `-G` connect timeout, else plain `-w`.
    if nc -h 2>&1 | grep -q -- '-G'; then
      nc -G "$PREFLIGHT_TIMEOUT_S" -z "$SSH_ADDR" "$SSH_PORT" >/dev/null 2>&1
      return $?
    fi
    nc -z -w "$PREFLIGHT_TIMEOUT_S" "$SSH_ADDR" "$SSH_PORT" >/dev/null 2>&1
    return $?
  fi

  # No nc → bounded /dev/tcp attempt (bash builtin). SSH_ADDR/SSH_PORT are
  # passed as POSITIONAL ARGS ($1/$2), never interpolated into the shell string,
  # so even if validation were bypassed the addr/port cannot break out of the
  # `exec` (defense-in-depth; injection guard). Both vars are already strictly
  # validated above (addr `^[A-Za-z0-9._-]+$`, port integer 1-65535).
  if [ -n "$tmo" ]; then
    "$tmo" "$PREFLIGHT_TIMEOUT_S" bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$SSH_ADDR" "$SSH_PORT" >/dev/null 2>&1
  else
    ( exec 3<>"/dev/tcp/$SSH_ADDR/$SSH_PORT" ) >/dev/null 2>&1
  fi
}

# Privilege probe (ssh-probe-protocol §3). Determines privilege_mode from a
# single round trip: uid, sudo binary presence, and `sudo -n true` outcome.
_probe_privilege() {
  local probe
  # Prints three tokens: <uid> <has-sudo:0|1> <sudo-n-rc>
  probe='id -u; command -v sudo >/dev/null 2>&1 && echo 1 || echo 0; sudo -n true >/dev/null 2>&1 && echo 0 || echo 1'
  local out uid has_sudo sudo_rc
  out="$(_ssh_exec_short "$probe" || true)"
  uid="$(printf '%s\n' "$out" | sed -n '1p')"
  has_sudo="$(printf '%s\n' "$out" | sed -n '2p')"
  sudo_rc="$(printf '%s\n' "$out" | sed -n '3p')"
  if [ "${uid:-x}" = "0" ]; then
    PRIVILEGE_MODE="root"
  elif [ "${sudo_rc:-1}" = "0" ]; then
    PRIVILEGE_MODE="passwordless-sudo"
  elif [ "${has_sudo:-0}" = "1" ]; then
    PRIVILEGE_MODE="limited-sudo"
  else
    PRIVILEGE_MODE="no-sudo"
  fi
}

# Tool probe — one round trip resolves availability for every tool the battery
# and IC-6 care about. Populates TOOLS_PRESENT + TOOL_AVAIL_JSON. A tool that is
# absent records JSON null; present records its version string (best-effort) or
# `true`. NEVER fabricates a tool that is not there (AC6/AC9 foundation).
_probe_tools() {
  local tools="lynis nmap trivy grype debsecan needrestart docker ss"
  local probe="for t in $tools; do if command -v \$t >/dev/null 2>&1; then echo \"\$t=present\"; else echo \"\$t=absent\"; fi; done"
  local out
  out="$(_ssh_exec_short "$probe" || true)"
  local t state
  TOOL_AVAIL_JSON='{}'
  for t in $tools; do
    state="$(printf '%s\n' "$out" | grep "^${t}=" | head -1 | cut -d= -f2)"
    if [ "$state" = "present" ]; then
      TOOLS_PRESENT="$TOOLS_PRESENT $t"
      TOOL_AVAIL_JSON="$(printf '%s' "$TOOL_AVAIL_JSON" | jq --arg t "$t" '. + {($t): true}')"
    else
      TOOL_AVAIL_JSON="$(printf '%s' "$TOOL_AVAIL_JSON" | jq --arg t "$t" '. + {($t): null}')"
    fi
  done

  # E12: if lynis is present, resolve its version. A version < 3.0 records the
  # version STRING in tool_availability.lynis and flips LYNIS_DEGRADED so
  # lynis-sourced checks fall back to manual reads + the DEGRADED notation. A
  # version ≥ 3.0 keeps the plain `true` already recorded above (no degradation).
  if _tool_present lynis; then
    _probe_lynis_version
  fi
}

# E12 lynis version probe (one extra round trip, only when lynis is present).
# Parses the numeric `X.Y[.Z]` from `lynis --version` (stderr/stdout vary across
# releases). On a clean parse with major.minor < 3.0 → degrade: record the
# version string in tool_availability.lynis and set the DEGRADED notation.
_probe_lynis_version() {
  local raw ver major minor
  raw="$(_ssh_exec_short 'lynis --version 2>&1 || lynis show version 2>&1' || true)"
  # Extract the FIRST dotted numeric token (e.g. `lynis 2.6.8` → 2.6.8).
  ver="$(printf '%s\n' "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
  [ -z "$ver" ] && return 0
  LYNIS_VERSION="$ver"
  major="${ver%%.*}"
  minor="${ver#*.}"; minor="${minor%%.*}"
  # Force base-10 (10#) so a leading-zero minor is not read as octal.
  if [ "$((10#${major:-0}))" -lt 3 ]; then
    LYNIS_DEGRADED=true
    LYNIS_DEGRADE_NOTE="DEGRADED (lynis ${ver} < 3.0)"
    # Record the version STRING (not bare true) so analysts/report can show it.
    TOOL_AVAIL_JSON="$(printf '%s' "$TOOL_AVAIL_JSON" | jq --arg v "$ver" '. + {lynis: $v}')"
    echo "WARN: lynis ${ver} < 3.0 on ${HOST_NAME} — lynis-sourced checks DEGRADED (manual fallback)" >&2
  fi
  unset major minor
}

# Is <tool> present? (`-` always present.)
_tool_present() {
  local tool="$1"
  [ "$tool" = "-" ] && return 0
  case " $TOOLS_PRESENT " in *" $tool "*) return 0 ;; *) return 1 ;; esac
}

# Persist a check's raw output (redacted) to --raw-dir and return the raw_ref
# (relative filename) on stdout, or empty if no raw dir / empty output.
_persist_raw() {
  local check_id="$1" content="$2"
  [ -z "$content" ] && { printf ''; return 0; }
  mkdir -p "$RAW_DIR" 2>/dev/null || true
  local f="$RAW_DIR/${check_id}.raw"
  # IC-5: redact BEFORE write — analysts/raw consumers never see secret values.
  printf '%s\n' "$content" | LC_ALL=C sed -E "$SED_REDACT" > "$f" 2>/dev/null || true
  printf '%s' "${check_id}.raw"
}

# IC-7 sanity-marker enforcement helper. Sets status/evidence (caller's locals)
# if the marker is absent or the ZUVO_FORCE_ERROR_CHECK hook fires.
# Args: <id> <raw_output> <status_nameref_var> <evidence_nameref_var>
# Uses indirect assignment via printf+read pattern (bash 3.2 safe).
_apply_marker_guard() {
  local _id="$1" _raw="$2" _sv="$3" _ev="$4"
  local _marker
  _marker="$(_sanity_marker "$_id")"
  if _check_force_error "$_id"; then
    printf -v "$_sv" '%s' 'error'
    printf -v "$_ev" '%s' 'IC-7: forced error (ZUVO_FORCE_ERROR_CHECK) — sanity marker treated as missing; see raw_ref'
  elif [ -n "$_marker" ]; then
    # A grep inside an if-condition is exempt from set -e; 2>/dev/null suppresses
    # transport errors.
    if printf '%s' "$_raw" | grep -qF -- "$_marker" 2>/dev/null; then
      : # marker present — keep current status
    else
      # $_marker is a static, internally-generated marker — safe to expand into
      # a normal-quoted string. No eval (which would execute $_raw-derived data).
      local _msg="IC-7: expected sanity marker '$_marker' absent from output — parse failed (see raw_ref)"
      printf -v "$_sv" '%s' 'error'
      printf -v "$_ev" '%s' "$_msg"
    fi
  fi
}

# E12: lynis-degraded notation. Mutates source/evidence (caller's locals) when
# lynis is older than 3.0 and this check is lynis-sourced.
# Args: <id> <source_nameref_var> <evidence_nameref_var>
_maybe_degrade_lynis_evidence() {
  local _id="$1" _sv="$2" _ev="$3"
  if [ "$LYNIS_DEGRADED" = true ] && _check_is_lynis_sourced "$_id"; then
    # Read the current evidence via indirect expansion (NOT eval — the evidence
    # holds redacted-but-still-attacker-influenced remote output), prepend note.
    local _cur_ev="${!_ev}"
    printf -v "$_sv" '%s' 'fallback'
    printf -v "$_ev" '%s' "${LYNIS_DEGRADE_NOTE}: ${_cur_ev}"
  fi
}

# DD-5 / DD-8 / IC-3 deterministic finding classifier. The collector DETECTS;
# the LLM only interprets. Given the battery row's `match_re` (column 6) and the
# already-redacted evidence, mark the check `status: finding` when the regex
# matches — but NEVER override a terminal diagnostic verdict (error / fallback /
# insufficient-data / skipped), which carry their own meaning and must not be
# silently turned into a finding. `match_re == -` means "no positive-match rule"
# (the check is informational; the analyst reads its evidence). The regex is a
# STATIC, internally-authored pattern (never host/user-derived), so evaluating it
# against attacker-influenced evidence with `grep -iE` is safe — evidence is data,
# there is no eval. Empty evidence never matches (DD-8: empty output ≠ finding,
# and certainly ≠ ok when a sanity marker is missing — that path is `error`).
# Args: <match_re> <status_nameref_var> <evidence_nameref_var>
_classify_finding() {
  local _re="$1" _sv="$2" _ev="$3"
  [ -z "$_re" ] && return 0
  [ "$_re" = "-" ] && return 0
  local _cur_status="${!_sv}"
  case "$_cur_status" in
    ok) : ;;                 # only a clean `ok` is eligible to become `finding`
    *) return 0 ;;           # error/fallback/insufficient-data/skipped untouched
  esac
  local _cur_ev="${!_ev}"
  [ -z "$_cur_ev" ] && return 0
  # The battery is `|`-delimited, so a `match_re` can never contain a literal `|`
  # (it would be parsed as a column break). ERE alternation is therefore written
  # with the two-char placeholder `~~` in the battery and translated back to `|`
  # here, immediately before the grep. `~~` is not a metacharacter and does not
  # occur in any battery evidence, so the substitution is unambiguous.
  local _re_grep="${_re//\~\~/|}"
  if printf '%s' "$_cur_ev" | grep -qiE -- "$_re_grep" 2>/dev/null; then
    printf -v "$_sv" '%s' 'finding'
  fi
}

# Live execution branch: sets SUDO_PREFIX, runs the remote command, captures
# raw output, redacts into evidence, persists raw_ref, then delegates to
# _apply_marker_guard, _classify_finding (DD-5), and _maybe_degrade_lynis_evidence.
# Args: <id> <mode> <needs_sudo> <status_var> <evidence_var> <raw_ref_var> <match_re>
# Reads cmd from the caller's local $cmd; writes SUDO_PREFIX (reset after).
_exec_and_assess() {
  local _id="$1" _mode="$2" _ns="$3" _sv="$4" _ev="$5" _rv="$6" _match_re="${7:-}"
  SUDO_PREFIX=""
  [ "$_ns" = "true" ] && [ "$PRIVILEGE_MODE" = "passwordless-sudo" ] && SUDO_PREFIX="sudo -n "
  local _raw
  if [ "$_mode" = "long" ]; then
    _raw="$(run_remote "$_id" long -- "$cmd" || true)"
  else
    _raw="$(run_remote "$_id" short -- "$cmd" || true)"
  fi
  SUDO_PREFIX=""
  # IC-5: redact BEFORE the value becomes bundle evidence. Compute into a local
  # via normal command substitution, then assign with printf -v — $_raw (hostile
  # remote output) NEVER enters an eval string, so $(...)/backticks in it are data.
  local _red; _red="$(printf '%s' "$_raw" | LC_ALL=C sed -E "$SED_REDACT" | head -c 4000)"
  printf -v "$_ev" '%s' "$_red"
  # DD-5: persist raw first so an error verdict still carries a raw_ref.
  local _rr; _rr="$(_persist_raw "$_id" "$_raw")"
  printf -v "$_rv" '%s' "$_rr"
  _apply_marker_guard "$_id" "$_raw" "$_sv" "$_ev"
  # Empty short output is benign — record it rather than leaving evidence blank.
  local _cur_status="${!_sv}"
  if [ "$_cur_status" != "error" ] && [ -z "$_raw" ] && [ "$_mode" = "short" ]; then
    printf -v "$_ev" '%s' '(no output)'
  fi
  # DD-5/DD-8/IC-3: deterministic finding classification on the redacted evidence
  # (runs BEFORE lynis-degrade so a real hardening-index finding is preserved as a
  # `finding` even when the lynis-degrade note later annotates the evidence string).
  _classify_finding "$_match_re" "$_sv" "$_ev"
  _maybe_degrade_lynis_evidence "$_id" "source" "$_ev"
}

# Execute one battery row and append its check object to checks_json (passed by
# name). Handles needs_sudo / tool-absent / live-exec + jq append in one place.
# Prints nothing; sets the caller's `checks_json` variable via printf into a
# local and echoes the updated JSON — caller captures with $(...).
#
# Args: <id> <dim> <needs_sudo> <mode> <tool> <match_re> <cmd> <unprivileged_flag> <cur_json>
# Stdout: updated checks_json array (caller replaces its own variable).
_run_single_check() {
  local id="$1" dim="$2" needs_sudo="$3" mode="$4" tool="$5" match_re="$6" cmd="$7"
  local unprivileged="$8"
  local cur_json="$9"

  local status evidence source raw_ref
  status="ok"; evidence=""; source="manual"; raw_ref=""
  [ "$tool" != "-" ] && source="$tool"

  if [ "$id" = "IS4-weak-protocols" ]; then
    # IS4 TLS protocol/cipher inspection is an EXTERNAL-vantage check (testssl):
    # it cannot be assessed from inside the host battery. Emit `skipped` (NOT a
    # masquerading `ok` from a dummy probe) so the analyst/report shows IS4 as
    # not-internally-covered. The real check runs on the external leg — backlog
    # B-infra-collect-external-live-execution.
    status="skipped"
    evidence="IS4 TLS requires external vantage (testssl) — see external leg (not covered by internal battery)"
  elif [ "$needs_sudo" = "true" ] && [ "$unprivileged" = true ]; then
    # AC4 / §3: needs_sudo check without privilege is insufficient-data, never ok.
    status="insufficient-data"
    evidence="needs sudo; privilege_mode=$PRIVILEGE_MODE"
  elif ! _tool_present "$tool"; then
    # AC9: required tool absent (and not installed) → skipped, no fabrication (AC6).
    status="skipped"
    evidence="required tool '$tool' not available (tool_availability.$tool=null)"
  else
    _exec_and_assess "$id" "$mode" "$needs_sudo" "status" "evidence" "raw_ref" "$match_re"
  fi

  local raw_ref_json="null"
  [ -n "$raw_ref" ] && raw_ref_json="$(printf '%s' "$raw_ref" | jq -R '.')"

  printf '%s' "$cur_json" | jq \
    --arg id "$id" \
    --arg dim "$dim" \
    --arg status "$status" \
    --arg evidence "$evidence" \
    --arg source "$source" \
    --argjson raw_ref "$raw_ref_json" \
    --argjson needs_sudo "$needs_sudo" \
    '. + [{
      id: $id,
      dimension: $dim,
      status: $status,
      evidence: $evidence,
      source: $source,
      raw_ref: $raw_ref,
      needs_sudo: $needs_sudo
    }]'
}

# Run the full in-scope battery live, emitting one check object per row. Prints
# the checks[] JSON array to stdout. Each row:
#   - needs_sudo && unprivileged   → insufficient-data (AC4; never ok)
#   - required tool absent          → skipped (AC9; never fabricates evidence)
#   - otherwise run, capture+redact → ok (or error on transport failure)
_collect_battery_json() {
  local checks_json="[]"
  local id dim needs_sudo mode tool match_re cmd
  local unprivileged=false
  case "$PRIVILEGE_MODE" in limited-sudo|no-sudo|insufficient-data) unprivileged=true ;; esac

  # Read the WHOLE battery into an indexed array FIRST, then iterate by index —
  # NOT a `while read` over a heredoc. A heredoc-fed loop keeps the row list live
  # on the loop's stdin; any ssh that inherited that fd would drain the remaining
  # rows and silently truncate the run after the first check that opened an ssh
  # on stdin. Index iteration leaves no live fd for a remote command to consume.
  local battery_arr=()
  local _l
  while IFS= read -r _l; do
    [ -n "$_l" ] && battery_arr+=("$_l")
  done <<BATTERY
$(battery)
BATTERY

  local _i
  for _i in "${!battery_arr[@]}"; do
    IFS='|' read -r id dim needs_sudo mode tool match_re cmd <<LINE
${battery_arr[$_i]}
LINE
    [ -z "$id" ] && continue
    _dimension_in_scope "$dim" || continue

    # IC-9 wall-clock guard. `$SECONDS` (shell-builtin elapsed seconds since the
    # collector started — NOT `date` arithmetic; subshells inherit it) bounds the
    # worst case. Once the per-host budget is breached, every REMAINING in-scope
    # check is emitted as `skipped` with a wall-clock note (dimension DEGRADED)
    # rather than run — so the bundle stays complete and valid but the tail does
    # not extend the run. --deep-scan is excluded from this budget by the caller
    # (it raises WALL_CLOCK_LIMIT_S out of band); the default 1800s is the spec's.
    if [ "$SECONDS" -ge "$WALL_CLOCK_LIMIT_S" ]; then
      checks_json="$(_append_wallclock_skip "$id" "$dim" "$needs_sudo" "$checks_json")"
      _write_live_bundle "$checks_json"
      continue
    fi

    checks_json="$(_run_single_check "$id" "$dim" "$needs_sudo" "$mode" "$tool" "$match_re" "$cmd" "$unprivileged" "$checks_json")"
    # Incremental write: re-render the bundle after each check (resume-safe).
    _write_live_bundle "$checks_json"
  done
  printf '%s' "$checks_json"
}

# IC-9: append a `skipped` check object carrying the wall-clock note. Used when
# the per-host wall clock ($SECONDS ≥ WALL_CLOCK_LIMIT_S) is breached — remaining
# checks are recorded skipped rather than run (dimension DEGRADED), never hung.
_append_wallclock_skip() {
  local id="$1" dim="$2" needs_sudo="$3" cur_json="$4"
  printf '%s' "$cur_json" | jq \
    --arg id "$id" \
    --arg dim "$dim" \
    --arg evidence "skipped (wall-clock): per-host budget ${WALL_CLOCK_LIMIT_S}s exceeded before this check ran (IC-9; dimension DEGRADED)" \
    --argjson needs_sudo "$needs_sudo" \
    '. + [{
      id: $id,
      dimension: $dim,
      status: "skipped",
      evidence: $evidence,
      source: "wall-clock",
      raw_ref: null,
      needs_sudo: $needs_sudo
    }]'
}

# Assemble + write the live IC-3 bundle from an (in-progress) checks[] array.
_write_live_bundle() {
  local checks_json="$1"
  local proxy_json="null"
  [ -n "$PROXY" ] && proxy_json="$(printf '%s' "$PROXY" | jq -R '.')"

  jq -n \
    --arg host "$HOST_NAME" \
    --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg privilege_mode "$PRIVILEGE_MODE" \
    --arg vantage "$EXTERNAL_VANTAGE" \
    --argjson tool_availability "$TOOL_AVAIL_JSON" \
    --argjson tool_defaults "$TOOL_AVAIL_DEFAULTS" \
    --argjson proxy_used "$proxy_json" \
    --argjson checks "$checks_json" \
    '{
      host: $host,
      collected_at: $collected_at,
      privilege_mode: $privilege_mode,
      os: { id: null, version: null, kernel: null },
      tool_availability: ($tool_defaults + $tool_availability),
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

# Top-level live collection driver.
collect_live() {
  # AC1: reachability preflight BEFORE any ssh handshake. Unreachable → phase0
  # UNREACHABLE + exit 0 (fleet continuity — the orchestrator keeps going).
  if ! _reachable; then
    phase0_writer "UNREACHABLE" "tcp-preflight-failed" \
      "nc -zw5 ${SSH_ADDR}:${SSH_PORT} failed (host did not accept a TCP connection)"
    echo "INFO: $HOST_NAME unreachable (tcp preflight) — phase0 bundle written: $OUT" >&2
    exit 0
  fi

  # Host-key mismatch fail-fast (§5): a probe handshake captures ssh stderr; the
  # canonical mismatch string halts the host with a phase0 bundle (AC8 — full
  # detection logic is hardened in Task 6, but the fail-fast hook lives here so
  # the first live handshake is the one that catches it).
  local hs_err
  hs_err="$(LC_ALL=C _ssh_raw "true" 2>&1 >/dev/null | head -c 4000 || true)"
  if printf '%s' "$hs_err" | grep -q 'REMOTE HOST IDENTIFICATION HAS CHANGED'; then
    local red
    red="$(printf '%s' "$hs_err" | LC_ALL=C sed -E "$SED_REDACT")"
    phase0_writer "FAILED" "host-key-mismatch" "$red"
    echo "ERROR: host-key mismatch on $HOST_NAME — phase0 bundle written: $OUT" >&2
    echo "       Recover: ssh-keygen -R $SSH_ADDR  (then verify the new key out-of-band)" >&2
    exit 0
  fi

  mkdir -p "$RAW_DIR" 2>/dev/null || true

  _probe_privilege
  _probe_tools
  # IC-4: resolve the external vantage ONCE here (before the battery loop) so the
  # incremental _write_live_bundle calls all record the same external.vantage.
  # A dead/absent proxy degrades vantage but NEVER disrupts the internal battery
  # below — the internal and external legs are independent.
  _resolve_vantage
  maybe_consent_install

  # Claim the remote run dir ONCE here in the parent shell (ssh-probe-protocol
  # §2), before the battery loop — the long-check nohup/.rc sidecars live in it.
  # Done eagerly (not lazily inside run_remote's subshell) so the claim survives.
  if [ "$RUN_DIR_CLAIMED" = false ]; then
    _claim_run_dir
    RUN_DIR_CLAIMED=true
  fi

  local checks_json
  checks_json="$(_collect_battery_json)"
  # Final bundle render (collect_battery already wrote incrementally, but render
  # once more to guarantee the complete array is the last write).
  _write_live_bundle "$checks_json"
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
  local id dim needs_sudo mode tool match_re cmd
  while IFS='|' read -r id dim needs_sudo mode tool match_re cmd; do
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
    # External (proxy) leg preview — proxychains nmap/testssl + nuclei (IC-4).
    preview_external
    # Bundle skeleton is still written so downstream tooling can validate IC-3.
    write_bundle
    printf '[DRY-RUN] bundle skeleton written: %s\n' "$OUT"
    exit 0
  fi

  # Live path: reachability preflight → privilege/tool probes → battery →
  # incremental IC-3 bundle (Task 5). Unreachable/host-key-mismatch hosts write a
  # phase0 bundle and exit 0/0 so the fleet run continues (AC1/AC8).
  collect_live
  exit 0
}

main
