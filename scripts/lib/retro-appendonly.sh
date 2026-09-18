# retro-appendonly.sh — filesystem-level append-only protection for ~/.zuvo/retros.{log,md}
#
# WHY THIS EXISTS
# ---------------
# Between 2026-08-17 and 2026-09-17 retros.log was truncated to ~101 rows six times
# (422->101, 464->101, 519->101, 1525->101, 2678->101, 3789->101, 3929->99), twice taking
# retros.md with it. The recipe was a runnable `head -1 + tail -n 100 + mv` block that survived
# in docs/specs/2026-04-09-retrospective-feedback-loop-spec.md — deleted 2026-09-17 — and shipped
# inside the plugin cache on all five platforms, where any agent could read and execute it.
#
# The WRITER was never identified, and the forensics job cannot identify it: it is triggered by
# launchd WatchPaths with ThrottleInterval=10, so it samples the process table up to ten seconds
# after the change, while `head+tail+mv` completes in milliseconds. Measured: in three of the six
# incidents its "suspects" table is EMPTY, in the rest it holds only unrelated processes. A guard
# that depends on naming the culprit was never going to work.
#
# So this guard does not care who writes. `chflags uappnd` makes the kernel refuse every write
# that is not an append. Measured on this exact recipe:
#
#     >> append (how append-retro writes)      -> permitted
#     : > file                                 -> operation not permitted
#     head -1 f > t; tail -n 100 f >> t; mv t f -> mv: rename t to f: Operation not permitted
#     rm file                                  -> operation not permitted
#
# The truncation stops being a silent data loss and becomes an error naming the file.
#
# THE TRAP THIS CARRIES
# ---------------------
# The flag lives on the INODE, so every legitimate atomic replace (rotate-retros, sanitize-retros,
# and append-retro's own shrink auto-recovery — all of them `mv` a rebuilt file into place)
# DROPS it. A rewriter that lifts the flag and forgets to re-arm leaves the file unprotected while
# everything still looks healthy: exactly the failure mode this whole guard exists to prevent.
# That is why re-arming goes through zuvo_ao_arm in a trap, and why install.sh re-arms on every
# run rather than only on first install.
#
# PLATFORM
# --------
# chflags is BSD/macOS. Linux's equivalent (`chattr +a`) requires root, which no zuvo helper has,
# so on Linux these functions are silent no-ops and the append path is unchanged. Every function
# FAILS OPEN: a chflags that errors must never prevent a retro from being written. Losing the
# protection costs history; blocking the write costs the same history plus the run's record of it.

# zuvo_ao_supported — 0 when this platform can enforce the flag.
zuvo_ao_supported() {
  [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v chflags >/dev/null 2>&1
}

# zuvo_ao_arm FILE… — turn protection ON. No-op off Darwin, never fatal.
zuvo_ao_arm() {
  zuvo_ao_supported || return 0
  for _ao_f in "$@"; do
    [ -f "$_ao_f" ] && chflags uappnd "$_ao_f" 2>/dev/null
  done
  unset _ao_f
  return 0
}

# zuvo_ao_lift FILE… — turn protection OFF for a legitimate rewrite. Pair with zuvo_ao_arm in a
# trap, never bare: a rewrite that dies between the two leaves the file writable by anything.
zuvo_ao_lift() {
  zuvo_ao_supported || return 0
  for _ao_f in "$@"; do
    [ -f "$_ao_f" ] && chflags nouappnd "$_ao_f" 2>/dev/null
  done
  unset _ao_f
  return 0
}

# zuvo_ao_is_armed FILE — 0 when FILE currently carries the flag. Off Darwin: always 1 (not armed),
# because claiming protection a platform cannot provide is worse than having none.
zuvo_ao_is_armed() {
  zuvo_ao_supported || return 1
  [ -f "$1" ] || return 1
  ls -lO "$1" 2>/dev/null | grep -q uappnd
}

# zuvo_ao_rewrite FILE CMD… — run CMD with protection lifted and re-arm whatever ends up at FILE,
# including on failure or interrupt. CMD is responsible for the atomic replace itself.
zuvo_ao_rewrite() {
  _ao_target="$1"; shift
  zuvo_ao_lift "$_ao_target"
  # The trap covers INT/TERM as well as the normal path: a rotation killed halfway must not leave
  # the file bare. RETURN is not used — it is bash-only and these helpers run under /bin/sh too.
  trap 'zuvo_ao_arm "$_ao_target"' INT TERM
  "$@"
  _ao_rc=$?
  trap - INT TERM
  zuvo_ao_arm "$_ao_target"
  unset _ao_target
  return $_ao_rc
}
