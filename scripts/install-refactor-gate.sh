#!/bin/sh
# Activate refactor hooks without replacing user hooks or shared Git configuration.
# Exit 0 means both are wired; exit 2 means installation is unavailable/incomplete.
# Python is also a prerequisite of the refactor gate itself.
exec python3 - "$0" "$@" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile

INSTALLER = sys.argv.pop(1) if len(sys.argv) > 1 else ""

# Exact pre-dispatch global gate and first dispatcher shipped by this installer.
# New installations also record a digest receipt to recognize later revisions.
LEGACY_GLOBAL_GATES = {
    "1c94c2bf85ec11ff32e61d869ea5f3f582b509bcb8b68cb02268bba31b5a6d43",
    "7eede029774d61d7c141ca0281c8dd51b9f861d5c7e1d6407bff249bfe4c2e4a",
}

# Exact identities, not a marker that an unrelated/broken script can contain.
# Refresh these when changing hooks/git-dispatch/{pre-commit,pre-push}; the install
# tests exercise those actual files. Keep identities here because installed copies
# of this helper do not carry the source tree.
DISPATCHERS = {
    "pre-commit": "2f4e9512e11d9558bf56df3535e23eb968a4a76dac6f7a6ed47d22f50f805f43",
    "pre-push": "b6c1d00a0f9f16e300e9d9750a09df109ec42977cd00b669f59264b2d2be5416",
}

# Forward standard hooks even if installed in the original directory later.
OTHER_HOOKS = """applypatch-msg pre-applypatch post-applypatch pre-merge-commit
prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge
pre-receive update proc-receive post-receive post-update reference-transaction
push-to-checkout pre-auto-gc post-rewrite sendemail-validate fsmonitor-watchman
p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit post-index-change""".split()


def legacy_forwarding_body(origin, mode):
    original = shlex.quote(str(origin / mode))
    return f'#!/bin/sh\nif [ -x {original} ]; then exec {original} "$@"; fi\n'


def forwarding_body(origin, mode):
    return "#!/bin/sh\n# zuvo:private-refactor-forward\n" + legacy_forwarding_body(origin, mode)[10:]


def chained_body(gate, origin, mode):
    setup, check = gate_command(gate, mode)
    return private_body(origin, mode, setup, check)


def private_body(origin, mode, setup, check):
    original = shlex.quote(str(origin / mode))
    prefix = "#!/bin/sh\n# zuvo:private-refactor-gate\n" + setup
    if mode == "pre-push":
        return (prefix + 'refs=$(mktemp) || exit 2\n'
                'trap \'rm -f "$refs"\' EXIT\n'
                'trap \'exit 2\' HUP INT TERM\n'
                'cat > "$refs" || exit 2\n'
                f'{check} < "$refs" || exit $?\n'
                f'if [ -x {original} ]; then {original} "$@" < "$refs"; else exit 0; fi\n')
    return (prefix + f"{check} </dev/null || exit $?\n"
            f'if [ -x {original} ]; then exec {original} "$@"; fi\n')


def read_origin(record):
    raw = record.read_text()
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        # Migrate the first release's one-line record. It could not represent a newline path.
        if raw.endswith("\n") and "\n" not in raw[:-1]:
            value = raw[:-1]
        else:
            raise ValueError("private hook origin record is malformed") from None
    if not isinstance(value, str) or not value:
        raise ValueError("private hook origin record is not a path")
    return Path(value)


def installer_owned(path, origin, mode):
    if path.is_symlink() or not path.is_file():
        return False
    body = path.read_text()
    if mode in DISPATCHERS:
        return refreshable_hook(body, mode, origin)
    return (body.startswith("#!/bin/sh\n# zuvo:private-refactor-forward\n")
            or body == legacy_forwarding_body(origin, mode))


def file_identity(path):
    try:
        named = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(named.st_mode):
        raise RuntimeError(f"hook is not a regular file: {path}; preserved")

    def metadata(value):
        return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns,
                value.st_ctime_ns, value.st_mode)

    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise RuntimeError(f"hook is not a regular file: {path}; preserved")
        digest = hashlib.sha256(stream.read()).hexdigest()
        after = os.fstat(stream.fileno())
    # Compare the pathname to the opened inode as the final inspection. Following
    # a substituted symlink here would hide the swap, even with identical bytes.
    if (metadata(named) != metadata(before) or metadata(before) != metadata(after)
            or metadata(after) != metadata(path.lstat())):
        raise RuntimeError(f"concurrent change while reading {path}; preserved")
    return (*metadata(after), digest)


def rollback_publication(state):
    private, transaction = state["private"], state["transaction"]
    if state["created"]:
        # It is complete and may already have been observed through a briefly-active config.
        # Leave it as a managed inactive artifact; a later install can reuse or refresh it.
        shutil.rmtree(transaction)
        return
    else:
        backup = transaction / "backup"
        conflicts = []
        for name in reversed(state["replaced"]):
            target = private / name
            saved = backup / name
            if file_identity(target) != state["after"][name]:
                conflicts.append(str(target))
                continue
            if saved.exists():
                os.replace(saved, target)
            elif target.exists() or target.is_symlink():
                target.unlink()
        if conflicts:
            raise RuntimeError(
                "concurrent private hook changes preserved; recovery backup remains at %s: %s"
                % (backup, ", ".join(conflicts))
            )
    shutil.rmtree(transaction)


def finish_publication(state):
    shutil.rmtree(state["transaction"])


def publish_private(private, gitdir, origin, bodies):
    """Publish complete fresh dirs or atomically replace owned files in a live hooks dir."""
    transaction = Path(tempfile.mkdtemp(prefix="zuvo-hook-install-", dir=gitdir))
    prepared = transaction / "prepared"
    backup = transaction / "backup"
    prepared.mkdir()
    backup.mkdir()
    state = {
        "private": private, "transaction": transaction, "created": False,
        "replaced": [], "before": {}, "after": {},
    }
    try:
        for mode, body in bodies.items():
            hook = private / mode
            if (hook.exists() or hook.is_symlink()) and not installer_owned(hook, origin, mode):
                shutil.rmtree(transaction)
                return None, f"private hook {hook} is not installer-owned; preserved"
            target = prepared / mode
            target.write_text(body)
            target.chmod(0o755)
        (prepared / "origin").write_text(json.dumps(str(origin), ensure_ascii=False) + "\n")
        if not private.exists():
            prepared.rename(private)
            state["created"] = True
            return state, None

        for name in (*bodies, "origin"):
            current = private / name
            before = file_identity(current)
            if current.exists() or current.is_symlink():
                if current.is_symlink() or not current.is_file():
                    shutil.rmtree(transaction)
                    return None, f"private hook {current} is unmanaged; preserved"
                if name == "origin":
                    if read_origin(current) != origin:
                        shutil.rmtree(transaction)
                        return None, f"private hook origin changed at {current}; preserved"
                elif not installer_owned(current, origin, name):
                    shutil.rmtree(transaction)
                    return None, f"private hook {current} is not installer-owned; preserved"
                if file_identity(current) != before:
                    raise RuntimeError(f"concurrent private hook change at {current}; preserved")
                shutil.copy2(current, backup / name)
                if file_identity(current) != before:
                    raise RuntimeError(f"concurrent private hook change at {current}; preserved")
            state["before"][name] = before
        try:
            for name in (*bodies, "origin"):
                current = private / name
                if file_identity(current) != state["before"][name]:
                    raise RuntimeError(f"concurrent private hook change at {current}; preserved")
                os.replace(prepared / name, private / name)
                state["replaced"].append(name)
                state["after"][name] = file_identity(private / name)
        except Exception:
            rollback_publication(state)
            raise
        return state, None
    except Exception:
        if transaction.exists():
            shutil.rmtree(transaction)
        raise


def config_snapshot(gitdir):
    config = gitdir / "config.worktree"
    if not config.exists():
        return {"exists": False, "data": b"", "mode": 0o600}
    if config.is_symlink() or not config.is_file():
        raise RuntimeError(f"worktree config is not a regular file: {config}")
    before = config.stat()
    data = config.read_bytes()
    after = config.stat()
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
        raise RuntimeError("worktree config changed concurrently; preserved")
    return {"exists": True, "data": data, "mode": before.st_mode & 0o777}


def restore_config_snapshot(gitdir, previous, installed):
    config = gitdir / "config.worktree"
    current = config_snapshot(gitdir)
    if current != installed:
        raise RuntimeError("worktree config changed concurrently after installation; preserved")
    if not previous["exists"]:
        config.unlink()
        return
    fd, temporary = tempfile.mkstemp(prefix=".config.worktree-", dir=gitdir)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(previous["data"])
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, previous["mode"])
        os.replace(temporary, config)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def rollback_install(publication, gitdir, previous, installed=None):
    errors = []
    if installed is not None:
        try:
            restore_config_snapshot(gitdir, previous, installed)
        except Exception as exc:
            errors.append(str(exc))
    try:
        rollback_publication(publication)
    except Exception as exc:
        errors.append(str(exc))
    if errors:
        raise RuntimeError("; ".join(errors))


def private_install(gate, gitdir, effective):
    """Layer the gate before the known dispatcher, only for this linked worktree."""
    private = gitdir / "zuvo-refactor-hooks"
    if private.is_symlink():
        return unavailable(f"private hooks path is a symlink: {private}; preserved")
    if private.exists():
        record = private / "origin"
        if record.is_symlink() or not record.is_file():
            return unavailable(f"unmanaged private hooks directory: {private}; preserved")
        origin = read_origin(record)
        if not origin.is_absolute() or origin == private or effective not in (private, origin):
            return unavailable("private hook origin no longer matches effective configuration")
    else:
        origin = effective
    if not all(dispatcher(origin / mode, mode) for mode in DISPATCHERS):
        return unavailable("private activation requires the recognized original dispatchers")
    bodies = {mode: chained_body(gate, origin, mode) for mode in DISPATCHERS}
    forward = set(OTHER_HOOKS) | {p.name for p in origin.iterdir() if not p.is_dir()}
    forward -= set(DISPATCHERS) | {"origin"}
    bodies.update({name: forwarding_body(origin, name) for name in forward})
    publication, error = publish_private(private, gitdir, origin, bodies)
    if publication is None:
        return unavailable(error)
    for mode, body in bodies.items():
        hook = private / mode
        if hook.is_symlink() or not usable(hook) or hook.read_text() != body:
            rollback_publication(publication)
            return unavailable(f"private hook {hook} differs; preserved")
    previous = config_snapshot(gitdir)
    try:
        subprocess.run(
            ["git", "config", "--worktree", "--replace-all", "core.hooksPath", str(private)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception:
        # Git config writes through its own lock. If it did not report success, preserve any
        # different config as a concurrent change and independently restore the hook files.
        rollback_publication(publication)
        raise
    installed = config_snapshot(gitdir)
    if Path(git("rev-parse", "--path-format=absolute", "--git-path", "hooks")).resolve() != private:
        rollback_install(publication, gitdir, previous, installed)
        return unavailable("another configuration overrides worktree core.hooksPath")
    finish_publication(publication)
    print(f"[refactor-gate] active private hooks -> {private}; original chain -> {origin}")
    return True


def unavailable(message):
    print(f"[refactor-gate] unavailable: {message}")
    return False


def git(*args):
    return subprocess.check_output(["git", *args], stderr=subprocess.DEVNULL).decode().strip()


def usable(path):
    return path.is_file() and os.access(path, os.X_OK)


def cached_gate(gate):
    cache = Path.home() / ".claude/plugins/cache/zuvo-marketplace/zuvo"
    try:
        parts = gate.relative_to(cache.resolve()).parts
    except ValueError:
        return False
    return len(parts) == 3 and parts[1:] == ("hooks", "refactor-safety-gate.sh")


def gate_command(gate, mode):
    if not cached_gate(gate):
        # Explicit custom gates retain their existing missing-file rejection policy.
        return "", f"{shlex.quote(str(gate))} {mode} \"$@\""
    # Embed the dispatcher, so neither its file nor the installer has to survive
    # cache eviction. The subshell preserves the private wrapper original-hook chain.
    body = dispatcher_template(gate)
    digest = hashlib.sha256(body.encode()).hexdigest()
    setup = (f"# zuvo:runtime-dispatch-sha256={digest}\n"
             "zuvo_refactor_gate() (\n" + body + "\n)\n")
    return setup, f"zuvo_refactor_gate {mode} \"$@\""


def dispatcher_template(gate):
    # The activated release owns the template. A bare $0 from `sh -s` is a
    # shell name, never authority to read siblings from the target repository.
    candidates = [gate.parent / "refactor-gate-dispatch.sh"]
    installer = Path(INSTALLER)
    if INSTALLER and (installer.is_absolute() or len(installer.parts) > 1) and installer.is_file():
        installer = installer.resolve()
        candidates.extend((installer.parent / "refactor-gate-dispatch.sh",
                           installer.parent.parent / "hooks/refactor-gate-dispatch.sh"))
    for template in candidates:
        if template.is_file():
            return template.read_text()
    raise ValueError("runtime dispatcher missing; rerun the current zuvo installer")


def hook_body(gate, mode):
    setup, check = gate_command(gate, mode)
    if not setup:
        check = "exec " + check
    return ("#!/bin/sh\n# >>> zuvo:refactor-gate\n"
            f"{setup}{check}\n"
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


def refreshable_hook(body, mode, origin=None):
    if origin is None:
        prefix = "#!/bin/sh\n# >>> zuvo:refactor-gate\n# zuvo:runtime-dispatch-sha256="
        suffix = f'\n)\nzuvo_refactor_gate {mode} "$@"\n# <<< zuvo:refactor-gate\n'
    else:
        header = "#!/bin/sh\n# zuvo:private-refactor-gate\n"
        prefix = header + "# zuvo:runtime-dispatch-sha256="
        tail = private_body(origin, mode, "", f'zuvo_refactor_gate {mode} "$@"')[len(header):]
        suffix = "\n)\n" + tail
    if body.startswith(prefix) and body.endswith(suffix):
        digest, separator, template = body[len(prefix):-len(suffix)].partition("\nzuvo_refactor_gate() (\n")
        return bool(separator) and hashlib.sha256(template.encode()).hexdigest() == digest
    lines = body.splitlines()
    if origin is not None:
        # Exact pre-dispatch chained_body output, including the original hook
        # and pre-push stdin forwarding. Marker-only or edited bodies are refused.
        try:
            words = shlex.split(lines[2 if mode == "pre-commit" else 6])
        except (ValueError, IndexError):
            return False
        if not words or not Path(words[0]).is_absolute():
            return False
        check = f'{shlex.quote(words[0])} {mode} "$@"'
        return body == private_body(origin, mode, "", check)
    if len(lines) != 4:
        return False
    try:
        words = shlex.split(lines[2])
    except ValueError:
        return False
    return (len(words) == 4 and words[0] == "exec" and words[2:] == [mode, "$@"]
            and cached_gate(Path(words[1]))
            and body == ("#!/bin/sh\n# >>> zuvo:refactor-gate\n"
                         f"exec {shlex.quote(words[1])} {mode} \"$@\"\n"
                         "# <<< zuvo:refactor-gate\n"))


def refresh_hook(path, expected, identity, mode=0o755):
    fd, temporary = tempfile.mkstemp(prefix=".refactor-gate-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(expected)
        os.chmod(temporary, mode)
        # Best effort: the final fd/path comparison is immediately before the
        # rename. An uncoordinated writer can still race the last lstat/replace.
        if file_identity(path) != identity:
            raise RuntimeError(f"concurrent hook change at {path}; preserved")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def install_global_dispatch(path, gate):
    body = dispatcher_template(gate)
    digest = hashlib.sha256(body.encode()).hexdigest()
    receipt = path.with_name(".refactor-safety-gate.sha256")
    if path.is_symlink() or (path.exists() and not path.is_file()):
        return unavailable(f"foreign global hook {path}; preserved")
    identity = file_identity(path)
    known = LEGACY_GLOBAL_GATES | {digest, hashlib.sha256(gate.read_bytes()).hexdigest()}
    receipt_identity = None
    if receipt.exists() or receipt.is_symlink():
        if receipt.is_symlink() or not receipt.is_file():
            return unavailable(f"foreign digest receipt {receipt}; hook preserved")
        status = receipt.stat()
        if status.st_uid != os.geteuid() or status.st_mode & 0o022:
            return unavailable(f"untrusted digest receipt {receipt}; hook preserved")
        receipt_identity = file_identity(receipt)
        checked = (status.st_dev, status.st_ino, status.st_size, status.st_mtime_ns,
                   status.st_ctime_ns, status.st_mode)
        if receipt_identity is None or receipt_identity[:-1] != checked:
            return unavailable(f"digest receipt changed after its trust check: {receipt}; hook preserved")
        known.update(receipt.read_text().splitlines())
    if identity is not None and identity[-1] not in known:
        return unavailable(f"foreign global hook {path}; preserved")
    # Publish authorization for BOTH possible versions first. If either rename
    # fails, the next installer can still recognize the old or new managed hook.
    authorized = {digest} | ({identity[-1]} if identity is not None else set())
    refresh_hook(receipt, "\n".join(sorted(authorized)) + "\n", receipt_identity, mode=0o644)
    refresh_hook(path, body, identity)
    print(f"[refactor-gate] active global dispatcher -> {path}")
    return True


def install(path, gate, mode, writable):
    expected = hook_body(gate, mode)
    if path.exists() or path.is_symlink():
        if usable(path) and path.read_text() == expected:
            print(f"[refactor-gate] active {mode} -> {path}")
            return True
        # Refresh only a digest-verified dispatcher or an exact old cache wrapper,
        # never a user hook that merely contains our marker.
        if writable and not path.is_symlink() and usable(path) and cached_gate(gate):
            identity = file_identity(path)
            body = path.read_text()
            if refreshable_hook(body, mode):
                refresh_hook(path, expected, identity)
                print(f"[refactor-gate] upgraded managed {mode} -> {path}")
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
    if len(sys.argv) == 4 and sys.argv[1] == "--global-dispatch":
        path, gate = (Path(value) for value in sys.argv[2:])
        if not path.is_absolute() or not gate.is_absolute():
            return unavailable("absolute global hook and source gate paths are required")
        return install_global_dispatch(path, gate)
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
    gitdir = Path(git("rev-parse", "--absolute-git-dir")).resolve()
    worktree_config = subprocess.run(
        ["git", "config", "--bool", "--get", "extensions.worktreeConfig"],
        capture_output=True, text=True, check=False)
    if (gitdir != common and worktree_config.stdout.strip() == "true"
            and (effective == gitdir / "zuvo-refactor-hooks"
                 or all(dispatcher(effective / mode, mode) for mode in DISPATCHERS))):
        return private_install(gate, gitdir, effective)
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
except (OSError, UnicodeError, ValueError, subprocess.SubprocessError, RuntimeError) as exc:
    unavailable(str(exc))
    sys.exit(2)
PY
