#!/usr/bin/env bash
# fleet-retro-pull.py fetch() — the one SSH that pulls the collector namespace, gzipped.
#
# Medium integration test: the real fetch() runs against an `ssh` stub on PATH that executes the
# remote command with bash against a throwaway "collector" directory (REMOTE_DATA is pointed at it).
# Nothing leaves the machine. What it guards:
#   - a read failure on the collector (missing data dir, unreadable file) is a FAILED pull (None,
#     named on stderr), never an rc-0 empty or partial namespace — `cat … | gzip` reported gzip's
#     status, so both used to look like success and the fleet view silently stopped advancing;
#   - an empty data dir is a legitimate empty pull (""), and files arrive in sorted order;
#   - zero bytes with rc 0, and a corrupt stream (valid gzip header, damaged deflate body →
#     zlib.error, which is not an OSError), are named faults, not tracebacks.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/scripts/zuvo-home/fleet-retro-pull.py"
TMP="$(mktemp -d)"; trap 'chmod -R u+rw "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/data"

# ssh stub: the remote command is the last argument; run it locally through /bin/sh, the way the
# collector's login shell would (fetch() must not depend on that shell being bash).
# SSH_STUB_MODE replaces it with a canned answer for the transport-fault cases; SSH_STUB_VANISH names
# a file the `sort` shim deletes after the listing — a file rotated away between find and cat.
mkdir -p "$TMP/remote-bin"
cat > "$TMP/bin/ssh" <<SH
#!/usr/bin/env bash
for a; do last="\$a"; done
case "\${SSH_STUB_MODE:-run}" in
  empty)   exit 0 ;;
  corrupt) printf '\037\213\010\000\000\000\000\000\000\003garbage-not-deflate'; exit 0 ;;
  *)       echo "Warning: Permanently added 'collector' to the list of known hosts." >&2
           PATH="$TMP/remote-bin:\$PATH" exec /bin/sh -c "\$last" ;;
esac
SH
# Through a file, not $(…): the listing is NUL-separated (sort -z) and bash drops NULs from a
# command substitution.
cat > "$TMP/remote-bin/sort" <<'SH'
#!/usr/bin/env bash
buf="$(mktemp)" || exit 1
command -p sort "$@" > "$buf" || { rm -f -- "$buf"; exit 1; }
[ -z "${SSH_STUB_VANISH:-}" ] || rm -f -- "$SSH_STUB_VANISH"
cat -- "$buf"; rm -f -- "$buf"
SH
chmod +x "$TMP/bin/ssh" "$TMP/remote-bin/sort"

PATH="$TMP/bin:$PATH" python3 - "$SRC" "$TMP/data" <<'PY'
import io, os, sys, contextlib

src, data = sys.argv[1], sys.argv[2]
g = {"__name__": "stub"}
exec(compile(open(src, encoding="utf-8").read(), src, "exec"), g)
g["REMOTE_DATA"] = data
fails = []

def check(cond, msg):
    print(("  ✓ " if cond else "  ✗ ") + msg)
    if not cond:
        fails.append(msg)

def recs(out):
    """The non-blank lines, as the parser reads them (it skips the blank line after each file)."""
    return None if out is None else [l for l in out.splitlines() if l.strip()]

def run(mode="run"):
    os.environ["SSH_STUB_MODE"] = mode
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        out = g["fetch"]("stub@collector")
    return out, err.getvalue()

with open(os.path.join(data, "b.jsonl"), "w") as fh:
    fh.write('{"n": 2}\n')
with open(os.path.join(data, "a.jsonl"), "w") as fh:
    fh.write('{"n": 1}\n')
with open(os.path.join(data, "ignore.txt"), "w") as fh:
    fh.write("not a namespace file\n")
out, err = run()
check(recs(out) == ['{"n": 1}', '{"n": 2}'], "readable files arrive whole, in sorted order, *.jsonl only")
check(out == '{"n": 1}\n\n{"n": 2}\n\n', "exact stream: each file, then exactly one separating newline")
check("Permanently added" not in err, "ssh's own stderr (host-key notice) is not relayed as a pull note")

# The old glob's file set: a symlinked *.jsonl is followed, a dotfile is not; a missing final newline
# must not glue two records into one unparseable line.
outside = os.path.join(os.path.dirname(data), "linked-target")
with open(outside, "w") as fh:
    fh.write('{"n": 9}\n')
os.symlink(outside, os.path.join(data, "z.jsonl"))
with open(os.path.join(data, ".hidden.jsonl"), "w") as fh:
    fh.write('{"n": "hidden"}\n')
with open(os.path.join(data, "aa.jsonl"), "w") as fh:
    fh.write('{"n": 0}')            # no final newline
out, _ = run()
check(recs(out) == ['{"n": 1}', '{"n": 0}', '{"n": 2}', '{"n": 9}'],
      "glob semantics kept: symlink followed, dotfile skipped, newline-less file not glued to the next")

# A file rotated away between the listing and the read is gone, not a failed read.
os.environ["SSH_STUB_VANISH"] = os.path.join(data, "b.jsonl")
out, err = run()
os.environ.pop("SSH_STUB_VANISH")
check(recs(out) == ['{"n": 1}', '{"n": 0}', '{"n": 9}'] and "vanished before it was read" in err,
      "a file that vanishes after find is skipped AND named; the rest of the namespace still arrives")
for f in ("z.jsonl", ".hidden.jsonl", "aa.jsonl"):
    os.remove(os.path.join(data, f))

bad = os.path.join(data, "c.jsonl")
with open(bad, "w") as fh:
    fh.write('{"n": 3}\n')
os.chmod(bad, 0)
readable = os.access(bad, os.R_OK)
out, err = run()
os.chmod(bad, 0o644)
if readable:
    print("  - SKIP unreadable-file case: chmod 0 does not lock this user out (root?)")
else:
    check(out is None and "failed" in err,
          "an unreadable file fails the pull (None, named) instead of a silent partial namespace")

for f in os.listdir(data):
    os.remove(os.path.join(data, f))
out, err = run()
check(out == "" and err == "", "an empty data dir is a legitimate empty pull, not an error")

os.rmdir(data)
out, err = run()
check(out is None and "failed" in err, "a missing data dir fails the pull instead of reading as empty")
os.makedirs(data)

out, err = run("empty")
check(out is None and "no payload" in err, "zero bytes with rc 0 is a fault (gzip never writes nothing)")

out, err = run("corrupt")
check(out is None and "could not decompress" in err,
      "a damaged deflate body (zlib.error) is a named fault, not a traceback")

print("RESULT: PASS=%d FAIL=%d" % (10 - len(fails) - (1 if readable else 0), len(fails)))
sys.exit(1 if fails else 0)
PY
