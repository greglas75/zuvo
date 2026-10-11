#!/usr/bin/env bash
# zuvo_backlog_io.backlog_root / resolve — which memory/backlog.md a checkout's backlog tools use
# (shared/includes/backlog-protocol.md "Where the Backlog Lives"): a TRACKED backlog belongs to the
# checkout it is in, a linked worktree included; an untracked one (ignored, absent from git, a symlink
# to the canonical file) is the ONE copy at the main checkout. Real repositories with real linked
# worktrees, built under mktemp — one fresh fixture per case — because the farm's own mirror is not a
# git checkout and cannot show the rule.
#
# Level: medium — temporary git repositories, python3, the archive CLI; no network, no sleep.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ZH="$ROOT/scripts/zuvo-home"
TMP="$(cd "$(mktemp -d)" && pwd -P)" || exit 1   # physical path: git reports /private/var on macOS, not /var
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" ZUVO_DIR="$TMP/zuvo" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset ZUVO_HOST_TAG ZUVO_BACKLOG_ROOTS ZUVO_OUTPUT_DIR
mkdir -p "$HOME" "$ZUVO_DIR"

PASS=0; FAIL=0
t_ok() { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
t_no() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }
command_not_found_handle() { echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL + 1)); return 127; }

# fixture <name> <tracked|ignored|symlink> — a repo at $TMP/<name> with a linked worktree at
# $TMP/<name>-wt (branch wt). tracked: memory/backlog.md committed. ignored: memory/ in .gitignore,
# the file only in the main checkout. symlink: memory/backlog.md committed as a link to a canonical
# file outside the repo ($TMP/<name>-canonical.md). Returns 1 when any git step fails.
fixture() {
  local d="$TMP/$1"
  git init -q -b main "$d" && mkdir -p "$d/memory" || return 1
  case "$2" in
    tracked) printf '# Backlog\n\n- [ ] B-main-1 open in main\n' > "$d/memory/backlog.md"
             git -C "$d" add memory/backlog.md || return 1 ;;
    ignored) printf 'memory/\n' > "$d/.gitignore"; printf '# Backlog\n\n- [ ] B-main-1 open in main\n' > "$d/memory/backlog.md"
             git -C "$d" add .gitignore || return 1 ;;
    symlink) printf '# Backlog\n\n- [ ] B-canon-1 canonical\n' > "$TMP/$1-canonical.md"
             ln -s "$TMP/$1-canonical.md" "$d/memory/backlog.md"; git -C "$d" add memory/backlog.md || return 1 ;;
  esac
  git -C "$d" commit -q -m init && git -C "$d" worktree add -q -b wt "$TMP/$1-wt" 2>/dev/null
}
need() { fixture "$@" || t_no "harness: fixture $1 ($2) could not be built — the case below proves nothing"; }
# io <python expression over zio and r> <repo dir> — evaluated with this checkout's zuvo_backlog_io.
io() { python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import zuvo_backlog_io as zio; r = sys.argv[3]; print(eval(sys.argv[2]))' "$ZH" "$1" "$2"; }
sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
# groom_load <repo> — backlog-groom's load(): "<root>|<real backlog path>".
groom_load() { python3 -c 'import sys,importlib.util; sys.path.insert(0, sys.argv[1]); s=importlib.util.spec_from_file_location("groom", sys.argv[1]+"/backlog-groom.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); l=m.load(sys.argv[2]); print(l.root, l.real, sep="|")' "$ZH" "$1" 2>&1; }

echo "== tracked backlog: each checkout uses its own copy =="
need t1 tracked; mkdir -p "$TMP/t1-wt/sub/dir"
got_wt="$(io 'zio.resolve(r)[0]' "$TMP/t1-wt")"; got_sub="$(io 'zio.resolve(r)[0]' "$TMP/t1-wt/sub/dir")"
got_main="$(io 'zio.resolve(r)[0]' "$TMP/t1")"; got_root="$(io 'zio.backlog_root(r)' "$TMP/t1-wt")"
if [ "$got_wt" = "$TMP/t1-wt/memory/backlog.md" ] && [ "$got_sub" = "$TMP/t1-wt/memory/backlog.md" ] \
   && [ "$got_main" = "$TMP/t1/memory/backlog.md" ] && [ "$got_root" = "$TMP/t1-wt" ]; then
  t_ok "a linked worktree (and a subdir of it) resolves to its own tracked backlog; the main checkout to its own"
else t_no "tracked: wt=[$got_wt] sub=[$got_sub] main=[$got_main] root=[$got_root]"; fi

rc=0; pth="$(python3 "$ZH/backlog-archive.py" path --repo "$TMP/t1-wt" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$pth" | sed -n 's/^declared //p')" = "$TMP/t1-wt/memory/backlog.md" ] \
   && [ "$(printf '%s\n' "$pth" | awk '$1 == "archive" {print $2}')" = "$TMP/t1-wt/memory/backlog-done.md" ]; then
  t_ok "backlog-archive.py path --repo <worktree> (the protocol's entry point) prints the worktree's backlog and archive"
else t_no "path command: rc=$rc out=[$pth]"; fi

echo "== untracked backlog: one copy at the main checkout =="
need i1 ignored
got="$(io 'zio.resolve(r)[0]' "$TMP/i1-wt")"; tr_none="$(io 'zio.tracked_root(r)' "$TMP/i1-wt")"
if [ "$got" = "$TMP/i1/memory/backlog.md" ] && [ "$tr_none" = None ]; then
  t_ok "an ignored backlog resolves to the main checkout from a linked worktree (the one-backlog rule is unchanged)"
else t_no "ignored: resolved=[$got] tracked_root=[$tr_none]"; fi

need s1 symlink
got_real="$(io 'zio.resolve(r)[1]' "$TMP/s1-wt")"; got_decl="$(io 'zio.resolve(r)[0]' "$TMP/s1-wt")"
if [ "$got_decl" = "$TMP/s1/memory/backlog.md" ] && [ "$got_real" = "$TMP/s1-canonical.md" ]; then
  t_ok "a committed symlink to the canonical file keeps the shared rule: the main checkout's link, written onto its target"
else t_no "symlink: declared=[$got_decl] real=[$got_real]"; fi

need t2 tracked
git -C "$TMP/t2-wt" rm -q memory/backlog.md && git -C "$TMP/t2-wt" commit -q -m "drop the backlog on this branch"
got="$(io 'zio.resolve(r)[0]' "$TMP/t2-wt")"
if [ "$got" = "$TMP/t2/memory/backlog.md" ]; then
  t_ok "a branch that no longer tracks the file falls back to the main checkout"
else t_no "untracked on the branch: resolved=[$got]"; fi

need t3 tracked; rm -f "$TMP/t3-wt/memory/backlog.md"   # still in the index: the branch is mid-change
main_before="$(sha "$TMP/t3/memory/backlog.md")"
got="$(io 'zio.resolve(r)[0]' "$TMP/t3-wt")"
rc=0; st="$(python3 "$ZH/backlog-archive.py" status --repo "$TMP/t3-wt" 2>&1)" || rc=$?
if [ "$got" = "$TMP/t3-wt/memory/backlog.md" ] && [ "$rc" -eq 0 ] && [[ "$st" == *"no backlog"* ]] \
   && [ "$(sha "$TMP/t3/memory/backlog.md")" = "$main_before" ]; then
  t_ok "a tracked file deleted only on disk still belongs to the worktree: it reports no backlog, never the main checkout's"
else t_no "tracked but deleted on disk: resolved=[$got] status rc=$rc [$st]"; fi

mkdir -p "$TMP/plain/memory"
got="$(io 'zio.resolve(r)[0]' "$TMP/plain")"; tr_none="$(io 'zio.tracked_root(r)' "$TMP/plain")"
if [ "$got" = "$TMP/plain/memory/backlog.md" ] && [ "$tr_none" = None ]; then
  t_ok "outside any git repository the directory itself is the root (no git is no tracking)"
else t_no "no git: resolved=[$got] tracked_root=[$tr_none]"; fi

echo "== archive from a linked worktree touches only that worktree =="
need t4 tracked
printf '# Backlog\n\n- [ ] B-wt-open still open\n- [x] B-wt-done fixed here [FIXED abc1234]\n' > "$TMP/t4-wt/memory/backlog.md"
printf '# Backlog\n\n- [ ] B-main-open open in main\n- [x] B-main-done another session ticked this [FIXED def5678]\n' > "$TMP/t4/memory/backlog.md"
main_before="$(sha "$TMP/t4/memory/backlog.md")"
rc=0; out="$(python3 "$ZH/backlog-archive.py" archive --repo "$TMP/t4-wt" --min-resolved 1 2>&1)" || rc=$?
wt_bl="$(cat "$TMP/t4-wt/memory/backlog.md")"; wt_done="$(cat "$TMP/t4-wt/memory/backlog-done.md" 2>/dev/null)"
if [ "$rc" -eq 0 ] && [[ "$wt_done" == *"- [x] B-wt-done fixed here [FIXED abc1234]"* ]] && [[ "$wt_bl" != *B-wt-done* ]] \
   && [[ "$wt_bl" == *"- [ ] B-wt-open still open"* ]] && [ "$(sha "$TMP/t4/memory/backlog.md")" = "$main_before" ] \
   && [ ! -e "$TMP/t4/memory/backlog-done.md" ]; then
  t_ok "archive --repo <worktree> moves the worktree's resolved entry into its own backlog-done.md; the main checkout is byte-unchanged"
else t_no "archive from worktree: rc=$rc out=[$out] main-done=$([ -e "$TMP/t4/memory/backlog-done.md" ] && echo created || echo absent)"; fi
rc=0; st="$(python3 "$ZH/backlog-archive.py" status --repo "$TMP/t4" 2>&1)" || rc=$?
if [ "$rc" -eq 12 ] && [[ "$st" == *"$TMP/t4/memory/backlog.md: 1 resolved"* ]]; then
  t_ok "status --repo <main> still reports the main checkout's own resolved entry (rc 12), untouched by the worktree's archive"
else t_no "main status: rc=$rc out=[$st]"; fi

echo "== backlog-groom loads the same tree =="
need t5 tracked; need i5 ignored
got_t="$(groom_load "$TMP/t5-wt")"; got_i="$(groom_load "$TMP/i5-wt")"
if [ "$got_t" = "$TMP/t5-wt|$TMP/t5-wt/memory/backlog.md" ] && [ "$got_i" = "$TMP/i5|$TMP/i5/memory/backlog.md" ]; then
  t_ok "groom's root (verdict citations resolve against it) is the tree whose backlog it loaded: the worktree when tracked, the main checkout when not"
else t_no "groom load: tracked=[$got_t] untracked=[$got_i]"; fi

echo "== the fleet collector =="
# Main checkouts are counted; a tracked worktree copy is branch content (silent); an untracked one is a stray.
need t6 tracked; need i6 ignored
printf '# Backlog\n\n- [ ] B-wt-only only on the branch\n' > "$TMP/t6-wt/memory/backlog.md"
mkdir -p "$TMP/i6-wt/memory"; printf '# Backlog\n\n- [ ] B-fork-1 a local fork\n' > "$TMP/i6-wt/memory/backlog.md"
got="$(cd "$TMP" && ZUVO_BACKLOG_ROOTS="$TMP/t6:$TMP/t6-wt:$TMP/i6:$TMP/i6-wt" python3 -c 'import sys,importlib.util,collections; sys.path.insert(0, sys.argv[1]); s=importlib.util.spec_from_file_location("collect", sys.argv[1]+"/backlog-collect.py"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); r,st=m.collect(); c=collections.Counter(x["repo_path"] for x in r); print(sorted(c.items()), st)' "$ZH" 2>&1)"
want="[('$TMP/i6', 1), ('$TMP/t6', 1)] ['$TMP/i6-wt']"
if [ "$got" = "$want" ]; then
  t_ok "the collector counts each main checkout once (1 item each), stays silent on the tracked worktree copy, and reports the untracked one as a stray"
else t_no "collector: got [$got] want [$want]"; fi

printf '  --- backlog resolve worktree: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
