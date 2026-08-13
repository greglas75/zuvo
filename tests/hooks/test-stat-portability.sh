#!/usr/bin/env bash
# `stat` probe ORDER across the gate libs — the bug that made every refactor gate a no-op on Linux.
#
# `stat -f` means two different things:
#     BSD/macOS : -f <format>        -> `stat -f %m file` prints the mtime
#     GNU/Linux : -f = --file-system -> `stat -f %m file` prints a FILESYSTEM field, exit 0
# So a `stat -f %m || stat -c %Y` chain SUCCEEDS on Linux and returns a non-mtime value; the `||`
# fallback never fires. That value then lands in `$((now - mt))`, which under a caller's `set -e`
# aborts the hook before any prove check runs. Net effect: the refactor safety gate was dead on the
# entire self-hosted runner fleet (Ubuntu) while being 20/20 green on the author's Mac.
#
# This suite runs on macOS and still pins the Linux behaviour, by shadowing `stat` on PATH with a
# fake that mimics each platform. Four libs carried the BSD-first form; the last case guards the
# CLASS so a fifth cannot quietly appear.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/refactor-gate-lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

GNU_MTIME=1700000000
FS_NOISE=4096                      # what GNU's --file-system prints instead of an mtime
mkfake(){ # $1 = gnu | bsd | none
  mkdir -p "$TMP/bin"
  case "$1" in
    gnu) cat > "$TMP/bin/stat" <<EOF
#!/bin/sh
case "\$1" in
  -c) echo $GNU_MTIME; exit 0 ;;
  -f) echo $FS_NOISE; exit 0 ;;      # GNU: --file-system, succeeds, WRONG number
esac
exit 1
EOF
    ;;
    bsd) cat > "$TMP/bin/stat" <<EOF
#!/bin/sh
case "\$1" in
  -f) echo $GNU_MTIME; exit 0 ;;     # BSD: -f <format>, this IS the mtime
  -c) exit 1 ;;                      # BSD has no -c
esac
exit 1
EOF
    ;;
    none) cat > "$TMP/bin/stat" <<'EOF'
#!/bin/sh
exit 1
EOF
    ;;
  esac
  chmod +x "$TMP/bin/stat"
}
callmtime(){ PATH="$TMP/bin:$PATH" sh -c '. "$1"; _mtime "$2" "$3"' _ "$LIB" "$TMP/f" 999; }

: > "$TMP/f"
echo "=== _mtime probe order ==="

# THE REGRESSION. Under GNU semantics the BSD probe succeeds with a filesystem value; anything
# that returns FS_NOISE here is the Linux-dead-gate bug.
mkfake gnu
got=$(callmtime)
[ "$got" = "$GNU_MTIME" ] && ok "GNU host: returns the mtime ($got), not the filesystem value" \
  || bad "GNU host: got '$got', expected $GNU_MTIME — BSD-first probe is back, gate is dead on Linux"

mkfake bsd
got=$(callmtime)
[ "$got" = "$GNU_MTIME" ] && ok "BSD host: still returns the mtime ($got)" \
  || bad "BSD host: got '$got' — the GNU-first reorder broke macOS"

# Neither probe works: the default must come back, and it must be digits, because the caller
# feeds it straight into arithmetic.
mkfake none
got=$(callmtime)
[ "$got" = "999" ] && ok "no usable stat: falls back to the supplied default" || bad "fallback returned '$got', expected 999"
case "$got" in ''|*[!0-9]*) bad "fallback is not digits-only ('$got') — arithmetic can still abort" ;;
  *) ok "output is digits-only in every branch (safe for \$(( )))" ;; esac

# CLASS GUARD. Four libs had this inverted; catching the fifth is the point of the file.
echo "=== class guard: no BSD-first stat probe anywhere ==="
offenders=""
for f in "$ROOT"/hooks/*.sh "$ROOT"/hooks/lib/*.sh "$ROOT"/scripts/zuvo-home/append-runlog "$ROOT"/scripts/zuvo-home/append-retro; do
  [ -f "$f" ] || continue
  hits=$(awk '
    /stat -f ?%[mz]/ && /stat (-c %[Ys]|--printf)/ {
      bsd = index($0, "stat -f")
      gnu = index($0, "stat -c"); if (gnu == 0) gnu = index($0, "stat --printf")
      if (bsd < gnu) print FILENAME ":" FNR
    }' "$f" 2>/dev/null)
  [ -n "$hits" ] && offenders="$offenders $hits"
done
if [ -z "$offenders" ]; then ok "every stat chain probes GNU before BSD"
else bad "BSD-first stat probe reintroduced at:$offenders"; fi

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
