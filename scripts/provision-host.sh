#!/usr/bin/env bash
# provision-host.sh — make a machine's adversarial provider fleet explicit and fixable.
#
# The problem it solves: every host is hand-configured, and a missing or logged-out provider
# degrades a review to single-provider SILENTLY. `adversarial-review.sh --doctor` already probes
# liveness; what was missing is the other half — WHICH provider is missing, and the exact command
# to fix it, without hunting through docs/adversarial-providers.md each time.
#
# Read-only by default. It probes, reports, and prints remediation. It installs NOTHING unless you
# pass --install, and even then only locally: remote installs need per-host package managers and
# sudo, which is a footgun this script deliberately does not hold.
#
#   provision-host.sh                 probe this host, print the matrix + remediation
#   provision-host.sh --install       additionally run the install command for MISSING CLIs
#                                     (prompts per provider; never touches an installed one)
#   provision-host.sh --remote H [H…] run the read-only probe over SSH on each host
#   provision-host.sh --quiet         matrix only, no remediation prose (for cron/CI)
#
# Exit: 0 = at least 2 providers usable (real cross-model review possible)
#       1 = fewer than 2 usable — reviews on this host WILL be single-provider
#       2 = usage / probe could not run at all

set -uo pipefail

QUIET=false
DO_INSTALL=false
REMOTE_HOSTS=()

# Source-able: `. provision-host.sh` must define the functions WITHOUT probing. The probe takes a
# minute (five provider round-trips), so a test that sources this to check the remediation table
# would otherwise hang. Same guard as scripts/install.sh.
if [ "${BASH_SOURCE[0]:-$0}" != "${0}" ]; then
  ZUVO_PROVISION_SOURCED=1
else
  ZUVO_PROVISION_SOURCED=0
fi

while [ "$ZUVO_PROVISION_SOURCED" -eq 0 ] && [ $# -gt 0 ]; do
  case "$1" in
    --install) DO_INSTALL=true; shift ;;
    --quiet)   QUIET=true; shift ;;
    --remote)  shift; while [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; do REMOTE_HOSTS+=("$1"); shift; done ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "provision-host: unknown argument '$1' (try --help)" >&2; exit 2 ;;
  esac
done

# ── Remediation table ────────────────────────────────────────────────────────
# Sourced from docs/adversarial-providers.md — keep the two in step.
# A `case`, NOT a delimited string: two of these install commands are themselves pipelines
# (`curl … | bash`), so any single-character field separator gets eaten by the data. The first
# version used `|` and silently truncated agy's and cursor-agent's install commands, handing the
# user a broken instruction — the same class of bug as splitting a markdown row on a bare pipe.
fix_for() {
  local inst='' ver=''
  case "$1" in
    codex)
      inst='npm install -g @openai/codex'
      ver='codex   # first run: log in with ChatGPT' ;;
    agy)
      inst='curl -fsSL https://antigravity.google/cli/install.sh | bash'
      ver='sign in via the Antigravity app, then: agy -p "reply OK" --dangerously-skip-permissions' ;;
    cursor-agent)
      inst='curl https://cursor.com/install -fsS | bash'
      ver='cursor-agent login   # or: export CURSOR_API_KEY=<key>' ;;
    kimi)
      inst=''   # OAuth CLI, no one-liner
      ver='see docs/adversarial-providers.md, then: kimi -p "reply OK"' ;;
    claude)
      inst=''   # already present if you use Claude Code
      ver='claude --print "reply OK"' ;;
    *) return 1 ;;
  esac
  printf '      install: %s\n' "${inst:-(no one-liner — see docs/adversarial-providers.md)}"
  printf '      verify:  %s\n' "$ver"
}

# Install command alone, empty when there is no safe one-liner.
install_cmd_for() {
  case "$1" in
    codex)        printf 'npm install -g @openai/codex\n' ;;
    agy)          printf 'curl -fsSL https://antigravity.google/cli/install.sh | bash\n' ;;
    cursor-agent) printf 'curl https://cursor.com/install -fsS | bash\n' ;;
    *)            printf '\n' ;;
  esac
}

resolve_adversarial() {
  command -v adversarial-review 2>/dev/null && return 0
  local here; here="$(cd "$(dirname "$0")" && pwd)"
  [ -x "$here/adversarial-review.sh" ] && { printf '%s\n' "$here/adversarial-review.sh"; return 0; }
  ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh 2>/dev/null | head -1
}

[ "$ZUVO_PROVISION_SOURCED" -eq 1 ] && return 0 2>/dev/null

# ── Remote mode: probe only, never install ───────────────────────────────────
if [ "${#REMOTE_HOSTS[@]}" -gt 0 ]; then
  rc=0
  for h in "${REMOTE_HOSTS[@]}"; do
    echo "══ $h ══"
    # Probe with the host's OWN installed copy; shipping this script over would then need the
    # whole plugin there too. If zuvo is not installed on the host, say that plainly.
    out=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$h" \
      'AR=$(command -v adversarial-review 2>/dev/null || ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh 2>/dev/null | head -1); \
       [ -n "$AR" ] || { echo "ZUVO_NOT_INSTALLED"; exit 0; }; sh "$AR" --doctor 2>&1' 2>&1) || {
      echo "  UNREACHABLE (ssh failed)"; rc=1; continue; }
    case "$out" in
      *ZUVO_NOT_INSTALLED*) echo "  zuvo not installed on this host — nothing to probe"; rc=1 ;;
      *) printf '%s\n' "$out" | sed -n '/PROVIDER DOCTOR/,$p' | sed 's/^/  /' ;;
    esac
  done
  exit $rc
fi

# ── Local probe ──────────────────────────────────────────────────────────────
AR="$(resolve_adversarial)"
if [ -z "${AR:-}" ]; then
  echo "provision-host: adversarial-review.sh not found — run scripts/install.sh first." >&2
  exit 2
fi

echo "PROVISION — $(hostname -s 2>/dev/null || hostname)"
DOCTOR="$(sh "$AR" --doctor 2>&1)" || true
if ! printf '%s' "$DOCTOR" | grep -q 'PROVIDER DOCTOR'; then
  echo "provision-host: the provider probe produced no matrix. Raw output:" >&2
  printf '%s\n' "$DOCTOR" >&2
  exit 2
fi
printf '%s\n' "$DOCTOR" | sed -n '/PROVIDER DOCTOR/,$p'

USABLE="$(printf '%s' "$DOCTOR" | sed -n 's/.*usable providers:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -1)"
USABLE="${USABLE:-0}"

# Which known CLIs are absent from this machine entirely? The doctor only probes what it detects,
# so a CLI that was never installed is invisible there — that is exactly the silent degradation.
MISSING=()
for cli in codex agy cursor-agent kimi claude; do
  command -v "$cli" >/dev/null 2>&1 || MISSING+=("$cli")
done

if [ "$QUIET" = false ]; then
  if [ "${#MISSING[@]}" -gt 0 ]; then
    echo ""
    echo "  NOT INSTALLED on this host (${#MISSING[@]}): ${MISSING[*]}"
    echo "  Each absent CLI is one fewer independent reviewer. To add one:"
    for cli in "${MISSING[@]}"; do
      echo "    $cli"
      fix_for "$cli"
    done
  fi
  echo ""
  if [ "$USABLE" -ge 2 ]; then
    echo "  OK — $USABLE usable providers: real cross-model review is possible on this host."
  else
    echo "  DEGRADED — $USABLE usable provider(s). Every review here will be single-provider,"
    echo "  and a single-provider pass cannot catch what same-model review misses. Fix one above."
  fi
fi

# ── Optional local install (consent per provider) ────────────────────────────
if [ "$DO_INSTALL" = true ] && [ "${#MISSING[@]}" -gt 0 ]; then
  echo ""
  echo "--install: this runs third-party installers. Review each command before agreeing."
  for cli in "${MISSING[@]}"; do
    inst="$(install_cmd_for "$cli")"
    [ -n "$inst" ] || { echo "  $cli: no automatic install — see docs/adversarial-providers.md"; continue; }
    printf '  install %s? [%s] (y/N) ' "$cli" "$inst"
    read -r ans </dev/tty 2>/dev/null || ans=n
    case "$ans" in
      y|Y) sh -c "$inst" || echo "  $cli: install FAILED — see the output above" ;;
      *)   echo "  $cli: skipped" ;;
    esac
  done
  echo "  Installs do not log you in. Re-run without --install to confirm each provider now probes WORKING."
fi

[ "$USABLE" -ge 2 ] && exit 0 || exit 1
