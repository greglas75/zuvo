"""Bounded local I/O and atomic, no-clobber report publication (POSIX hosts)."""

from __future__ import annotations

import os
from pathlib import Path
import stat
import subprocess
import tempfile


def command(
    argv: list[str], root: Path, *, limit: int, timeout: int, input_bytes: bytes | None = None
) -> bytes:
    """Spool stdout, not RAM; only read it after enforcing the byte limit.

    The timeout bounds process lifetime. Temporary disk usage is not quota-enforced;
    providers/git are installed local executables, not an arbitrary code sandbox.
    Never echo their stderr or argv because those can contain credentials.
    """
    try:
        with tempfile.TemporaryFile() as output:
            proc = subprocess.run(
                argv, cwd=root, input=input_bytes, stdout=output, stderr=subprocess.DEVNULL, timeout=timeout
            )
            if proc.returncode or output.tell() > limit:
                raise ValueError(f"{Path(argv[0]).name}: failed or response exceeded limit")
            output.seek(0)
            return output.read(limit + 1)
    except (OSError, subprocess.TimeoutExpired) as err:
        raise ValueError(f"{Path(argv[0]).name}: unavailable or timed out") from err


def read_text(path: Path, limit: int) -> str:
    """Read regular UTF-8 files only, with a byte cap enforced on the open descriptor."""
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW), "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError(f"expected a regular file: {path}")
        body = source.read(limit + 1)
    if len(body) > limit:
        raise ValueError(f"input exceeds byte limit: {path}")
    return body.decode("utf-8")


def write_artifact(path: Path, content: str, limit: int) -> None:
    """Atomic exclusive publication; an interrupted write cannot poison history."""
    if len(content.encode("utf-8")) > limit:
        raise ValueError(f"output exceeds byte limit: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=".radar-", delete=False
        ) as target:
            temporary = Path(target.name)
            target.write(content)
            target.flush()
            os.fsync(target.fileno())
        os.link(temporary, path)  # Never overwrite an entry from a competing writer.
    except FileExistsError as err:
        if path.is_file() and not path.is_symlink() and read_text(path, limit) == content:
            return
        raise ValueError(f"output already exists with different content: {path}") from err
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
