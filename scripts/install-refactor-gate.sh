#!/bin/sh
# Activate both refactor hooks without replacing user hooks or changing Git config.
# Exit 0 means both are wired; exit 2 means installation is unavailable/incomplete.
# Python is also a prerequisite of the refactor gate itself.
exec python3 - "$@" <<'PY'
import hashlib
import os
from pathlib import Path
import shlex
import subprocess
import sys

# Exact identities, not a marker that an unrelated/broken script can contain.
# Refresh these when changing hooks/git-dispatch/{pre-commit,pre-push}; the install
# tests exercise those actual files. Keep identities here because installed copies
# of this helper do not carry the source tree.
DISPATCHERS = {
    "pre-commit": "8f25f773333a7260941ed570c563fd84ebf4d766e92fc8d59bdd8dcd14270128",
    "pre-push": "b6c1d00a0f9f16e300e9d9750a09df109ec42977cd00b669f59264b2d2be5416",
}


def unavailable(message):
    print(f"[refactor-gate] unavailable: {message}")
    return False


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL).decode().strip()


def usable(path):
    return path.is_file() and os.access(path, os.X_OK)


def hook_body(gate, mode):
    # exec propagates failure, including a gate removed after installation.
    return ("#!/bin/sh\n# >>> zuvo:refactor-gate\n"
            f"exec {shlex.quote(str(gate))} {mode} \"$@\"\n"
            "# <<< zuvo:refactor-gate\n")


def dispatcher(path, mode):
    target = path
    for _ in range(8):
        if not target.is_symlink():
            break
        link = Path(os.readlink(target))
        target = link if link.is_absolute() else target.parent / link
    # Match the dispatcher's own resolution limit; a longer chain fails open there.
    return (not target.is_symlink() and usable(path)
            and hashlib.sha256(path.read_bytes()).hexdigest() == DISPATCHERS[mode])


def install(path, gate, mode, writable):
    expected = hook_body(gate, mode)
    if path.exists() or path.is_symlink():
        if usable(path) and path.read_text() == expected:
            print(f"[refactor-gate] active {mode} -> {path}")
            return True
        return unavailable(f"existing {path} is not a usable hook for this gate; preserved")
    if not writable:
        return unavailable(f"{path} is outside repository-owned hooks or is version-controlled; preserved")
    path.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation also preserves a hook created concurrently with this run.
    with path.open("x") as stream:
        stream.write(expected)
    path.chmod(0o755)
    if not usable(path):
        return unavailable(f"{path} is not executable")
    print(f"[refactor-gate] installed {mode} -> {path}")
    return True


def main():
    if len(sys.argv) < 2 or not sys.argv[1] or not Path(sys.argv[1]).is_absolute():
        return unavailable("an absolute gate path is required")
    gate = Path(sys.argv[1]).resolve()
    if not usable(gate):
        return unavailable(f"gate is missing or not executable: {gate}")
    if len(sys.argv) > 2:
        os.chdir(sys.argv[2])
    if git("rev-parse", "--is-inside-work-tree") != "true":
        return unavailable("a working tree is required")
    root = Path(git("rev-parse", "--show-toplevel")).resolve()
    os.chdir(root)
    common = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    local = (common / "hooks").resolve()
    effective_path = Path(git("rev-parse", "--path-format=absolute", "--git-path", "hooks"))
    effective = effective_path.resolve()
    # --git-path canonicalizes symlinks. Retain the configured spelling to protect
    # tracked links on the path Git selected, without statting every tracked file.
    configured = subprocess.run(["git", "config", "--path", "--get", "core.hooksPath"],
                                capture_output=True, text=True, check=False)
    selected_path = effective_path
    if configured.returncode == 0 and configured.stdout.rstrip("\n"):
        selected_path = Path(configured.stdout.rstrip("\n"))
        if not selected_path.is_absolute():
            selected_path = root / selected_path
    ownership = {}

    def owned(directory):
        if directory in ownership:
            return ownership[directory]
        # A symlink under .git/hooks pointing into a shared directory isn't owned.
        internal = directory == common / "hooks" or root in directory.parents
        candidates = [directory]
        if directory == effective:
            # Check only symlinks on the selected hook path, including ancestors. A
            # tracked hooksPath link must not disguise an untracked destination.
            candidates.extend(p for p in (selected_path, *selected_path.parents)
                              if root in p.parents and p.is_symlink())
        pathspecs = [":(literal)" + str(p.relative_to(root))
                     for p in candidates if root in p.parents]
        versioned = bool(pathspecs and subprocess.check_output(
            ["git", "ls-files", "-z", "--", *pathspecs]))
        ownership[directory] = internal and not versioned
        return ownership[directory]

    success = True
    for mode in DISPATCHERS:
        try:
            active = effective / mode
            if dispatcher(active, mode):
                # Always install the local exec wrapper: the shared dispatcher skips a
                # missing sibling gate, so its presence today cannot guarantee enforcement
                # after a partial update/removal. It chains common hooks in linked worktrees.
                # Do not recurse into itself, or mutate the shared dispatcher directory.
                if local == effective or (local / mode).resolve() == active.resolve():
                    success = unavailable(f"dispatcher {active} cannot chain a separate local guard; preserved") and success
                    continue
                success = install(local / mode, gate, mode, owned(local)) and success
            else:
                success = install(active, gate, mode, owned(effective)) and success
        except (OSError, UnicodeError, RuntimeError) as exc:
            success = unavailable(f"{mode}: {exc}") and success
    return success


try:
    sys.exit(0 if main() else 2)
except (OSError, subprocess.SubprocessError, RuntimeError) as exc:
    unavailable(str(exc))
    sys.exit(2)
PY
