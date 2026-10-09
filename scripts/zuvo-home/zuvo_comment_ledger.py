"""The comment-audit ledger: one TSV row per audited file per run, and the --trend report read from it."""
from __future__ import annotations

import contextlib
import datetime as dt
import errno
import hashlib
import os
import re
import time
from collections import Counter, defaultdict
from stat import S_ISREG
from typing import IO, Iterable, Iterator, Mapping, NamedTuple, Optional, Sequence, Tuple

import zuvo_comment_rules as rules

try:
    import fcntl
except ImportError:
    fcntl = None  # type: ignore[assignment]

LOG_ENV, HOME_ENV, LOG_NAME = "ZUVO_COMMENT_AUDIT_LOG", "ZUVO_HOME", "comment-audit.log"
SCHEMA_VERSION = "1"
SCHEMA_PREFIX = "# comment-audit ledger"
SCHEMA = f"{SCHEMA_PREFIX} schema={SCHEMA_VERSION}"
COLUMNS = ("date", "run", "project", "head7", "base7", "file", "lang", "authored_code", "authored_comment",
           "carried", "density", "file_density", "narrative", "long", "claims", "density_breach", "justified",
           "verdict", "blob", "thresholds", "notes")
METRICS = COLUMNS[COLUMNS.index("authored_code"):COLUMNS.index("verdict")]
RATIOS = ("density", "file_density")
COUNTS = tuple(name for name in METRICS if name not in RATIOS)
SUMMED = ("authored_comment", "density_breach", "narrative", "long", "justified")
NONE, SHORT_SHA = "-", 7
OBJECT_FORMATS = ("sha1", "sha256")
NO_LOCK = {errno.ENOLCK, errno.EOPNOTSUPP, errno.ENOSYS, getattr(errno, "ENOTSUP", errno.EOPNOTSUPP)}
BUSY = {errno.EWOULDBLOCK, errno.EAGAIN}
LOCK_WAIT, LOCK_POLL = 30.0, 0.05
OPEN_FLAGS = sum(getattr(os, flag, 0) for flag in ("O_NOFOLLOW", "O_NONBLOCK", "O_BINARY"))
RUN = re.compile(r"\d{4}(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])T([01]\d|2[0-3])[0-5]\d[0-5]\dZ-\d+", re.ASCII)
ROW_DATE = re.compile(r"\d{4}-\d\d-\d\dT", re.ASCII)
SINCE = re.compile(r"(\d{4})-(\d\d)-(\d\d)", re.ASCII)
STAMP = "%Y-%m-%dT%H:%M:%SZ"
DAYS_DEFAULT, DAYS_MAX = 30, 3650
SKILL = re.compile(r"[a-z0-9][a-z0-9-]{0,39}", re.ASCII)
SKILL_NOTE, DEGRADED_NOTE, TREND_BY = "skill=", "degraded", ("project", "skill")
MARKDOWN = re.compile(r"([\\`*_\[\]#|<>$&])")
TREND_HEADER = ("PROJECT", "RUNS", "FILES", "GATED", "DENS_P50", "DENS_P90", "FILE_P50", "AUTH_CMT", "D", "N",
                "L", "JUSTIFIED")

Origin = NamedTuple("Origin", [("project", str), ("head7", str), ("base7", str), ("fmt", str)])
Entry = Tuple[str, str, str, Optional[rules.FileResult], str]
Stat = NamedTuple("Stat", [("project", str), ("run", str), ("measured", bool), ("density", Optional[float]),
                           ("file_density", Optional[float]), ("sums", Tuple[int, ...]), ("skill", str)])
TrendOptions = NamedTuple("TrendOptions", [("days", Optional[int]), ("since", Optional[str]),
                                           ("project", Optional[str]), ("markdown", bool), ("by", str)])


def ledger_path(environ: Mapping[str, str]) -> str:
    """ZUVO_COMMENT_AUDIT_LOG, else comment-audit.log in ZUVO_HOME or $HOME/.zuvo; an empty value is unset."""
    if environ.get(LOG_ENV):
        return environ[LOG_ENV]
    home = environ.get("HOME") or os.path.expanduser("~")
    return os.path.join(environ.get(HOME_ENV) or os.path.join(home, ".zuvo"), LOG_NAME)


def origin(top: str, common_dir: str, fmt: str, head: str, base: str) -> Origin:
    """The project is the main checkout's directory, so a linked worktree reports its repository's name."""
    common = os.path.realpath(os.path.join(top, common_dir))
    main = os.path.dirname(common) if os.path.basename(common) == ".git" else top
    return Origin(os.path.basename(main), head[:SHORT_SHA] or NONE, base[:SHORT_SHA] or NONE,
                  fmt if fmt in OBJECT_FORMATS else OBJECT_FORMATS[0])


def blob_id(data: bytes, fmt: str) -> str:
    """The id `git hash-object --no-filters` gives these bytes."""
    digest = hashlib.new(fmt)
    digest.update(b"blob %d\0" % len(data))
    digest.update(data)
    return digest.hexdigest()


def escape(text: str) -> str:
    """Every character `str.isprintable()` rejects as \\xNN, \\uNNNN or \\UNNNNNNNN: the Unicode Other categories
    (controls; format characters such as bidi, zero-width and tag marks; surrogates; private and unassigned code
    points) and the Separators but ' '. A surrogate-escaped byte is its own \\xNN. A letter or symbol that merely
    looks blank (U+3164, U+2800) is printable and kept."""
    if text.isprintable():
        return text
    return "".join(char if char.isprintable() else _code(ord(char)) for char in text)


def _code(point: int) -> str:
    point -= 0xDC00 if 0xDC80 <= point <= 0xDCFF else 0
    return f"\\x{point:02x}" if point < 0x100 else f"\\u{point:04x}" if point < 0x10000 else f"\\U{point:08x}"


def _cell(text: str) -> str:
    return escape(text) or NONE


def ratio(value: float | None) -> str:
    return NONE if value is None else f"{value:.3f}"


def _metrics(result: rules.FileResult, accepted: Mapping[str, str]) -> tuple[list[str], list[str]]:
    seen = Counter(finding.rule for finding in result.findings)
    kept = [f"{finding.id}={accepted[finding.id]}" for finding in result.findings if finding.id in accepted]
    numbers = [result.authored_code, result.authored_comment, result.carried, ratio(result.density),
               ratio(result.file_density), seen[rules.NARRATIVE_RULE], seen[rules.LONG_RULE],
               len(result.claims), seen[rules.DENSITY_RULE], len(kept)]
    return [str(number) for number in numbers], kept


def format_rows(run: str, where: Origin, thresholds: str, entries: Iterable[Entry],
                accepted: Mapping[str, str], skill: str = "") -> list[str]:
    """One TSV line per entry; a `n/a (reason)` verdict is stored as `n/a`, the whole verdict going to notes,
    after `skill=<name>` when the calling skill named itself and before `degraded` when the scanner fell back to its
    simpler reader. ValueError when `run` is not
    `yyyymmddTHHMMSSZ-pid` or `skill` is not a lowercase skill name."""
    if not RUN.fullmatch(run):
        raise ValueError(f"run id {run!r} is not yyyymmddTHHMMSSZ-pid")
    if skill and not SKILL.fullmatch(skill):
        raise ValueError(f"--skill {skill!r}: expected a lowercase skill name (a-z, 0-9, '-', at most 40)")
    named = [SKILL_NOTE + skill] if skill else []
    date = f"{run[0:4]}-{run[4:6]}-{run[6:8]}T{run[9:11]}:{run[11:13]}:{run[13:15]}Z"
    lines = []
    for path, verdict, lang, result, blob in entries:
        kind, _, reason = verdict.partition(" ")
        metrics, notes = _metrics(result, accepted) if result is not None else ([NONE] * len(METRICS), [])
        degraded = [DEGRADED_NOTE] if result is not None and result.degraded else []
        cells = [date, run, where.project, where.head7, where.base7, path, lang, *metrics, kind, blob,
                 thresholds, "|".join(named + ([verdict] if reason else []) + degraded + notes)]
        lines.append("\t".join(_cell(cell) for cell in cells))
    return lines


def _open(path: str, flags: int) -> int:
    """A descriptor on a regular file; a FIFO, device, directory or, with O_NOFOLLOW, a symlink is refused."""
    fd = os.open(path, flags | OPEN_FLAGS, 0o644)
    if not S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError(errno.EINVAL, "not a regular file")
    return fd


def _lock(fd: int) -> bool:
    """An exclusive flock retried for LOCK_WAIT seconds; False where fcntl or the filesystem has no flock."""
    if fcntl is None:
        return False
    operation = fcntl.LOCK_EX | fcntl.LOCK_NB
    deadline = time.monotonic() + LOCK_WAIT
    while True:
        try:
            fcntl.flock(fd, operation)
            return True
        except OSError as exc:
            if exc.errno in NO_LOCK:
                return False
            if exc.errno not in BUSY:
                raise
            if time.monotonic() >= deadline:
                raise OSError(exc.errno, "ledger is locked by another run") from exc
        time.sleep(LOCK_POLL)


def _foreign(first: str) -> str | None:
    """Why a ledger starting with the line `first` cannot take or yield schema-1 rows, or None; file text in
    the reason is escaped."""
    if first == SCHEMA:
        return None
    if not first.startswith(SCHEMA_PREFIX):
        return "not a comment-audit ledger"
    return f"unsupported ledger header '{escape(first)}', this comment-audit reads '{SCHEMA}'"


def _lead(fd: int, size: int) -> bytes:
    """A newline when a non-empty ledger does not end in one; ValueError when it is not a schema-1 ledger."""
    os.lseek(fd, 0, os.SEEK_SET)
    problem = _foreign(os.read(fd, len(SCHEMA) + 64).split(b"\n")[0].decode("utf-8", "replace").rstrip("\r"))
    if problem:
        raise ValueError(problem)
    os.lseek(fd, size - 1, os.SEEK_SET)
    return b"" if os.read(fd, 1) == b"\n" else b"\n"


def append(lines: Sequence[str], path: str) -> None:
    """All lines in one O_APPEND write. Holding an exclusive flock, the header check and the write are atomic
    against other runs, and a failed or short write is truncated away; where flock is missing or unsupported,
    each run is still one append, but a torn write stays and two runs on an empty ledger can both write the
    header. A torn tail gets a newline first, so new rows never fuse with it. OSError when the file cannot be
    written or stays locked; ValueError when it is not a schema-1 ledger."""
    if os.path.dirname(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = _open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT)
    try:
        locked = _lock(fd)
        size = os.fstat(fd).st_size
        head = [SCHEMA, "\t".join(COLUMNS)] if size == 0 else []
        lead = _lead(fd, size) if size else b""
        data = lead + "".join(f"{line}\n" for line in [*head, *lines]).encode("utf-8", "backslashreplace")
        try:
            written = os.write(fd, data)
            if written != len(data):
                raise OSError(errno.EIO, f"wrote {written} of {len(data)} bytes")
        except OSError:
            if locked:
                os.ftruncate(fd, size)
            raise
    finally:
        os.close(fd)


def window_start(days: int | None, since: str | None, now: dt.datetime) -> str:
    """The first UTC timestamp in the window: --since is 00:00:00Z of that day, --days N is now minus N days
    of 24 hours (default 30). ValueError for a naive `now`."""
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("now must be timezone-aware")
    if since is not None:
        match = SINCE.fullmatch(since)
        try:
            day = dt.date(*map(int, match.groups())) if match else None
        except ValueError:
            day = None
        if day is None:
            raise ValueError(f"--since {since!r}: expected YYYY-MM-DD")
        return f"{day.isoformat()}T00:00:00Z"
    count = DAYS_DEFAULT if days is None else days
    if not 1 <= count <= DAYS_MAX:
        raise ValueError(f"--days {count}: expected 1-{DAYS_MAX}")
    return (now.astimezone(dt.timezone.utc) - dt.timedelta(days=count)).strftime(STAMP)


def _stat(cells: list[str]) -> Stat | None:
    if len(cells) != len(COLUMNS):
        return None
    row = {name: cells[index] for index, name in enumerate(COLUMNS)}
    try:
        counts = {name: 0 if row[name] == NONE else int(row[name]) for name in COUNTS}
        ratios = [None if row[name] == NONE else float(row[name]) for name in RATIOS]
    except ValueError:
        return None
    if min(counts.values()) < 0 or any(ratio is not None and not 0 <= ratio <= 1 for ratio in ratios):
        return None
    measured = any(row[name] != NONE for name in METRICS)
    sums = tuple(counts[name] for name in SUMMED)
    first = row["notes"].split("|", 1)[0]       # format_rows writes skill=NAME first, and only there
    name = first[len(SKILL_NOTE):] if first.startswith(SKILL_NOTE) else ""
    skill = name if SKILL.fullmatch(name) else ""
    return Stat(row["project"], row["run"], measured, ratios[0], ratios[1], sums, skill)


def read_rows(handle: IO[bytes]) -> Iterator[tuple[str, Stat | None]]:
    """(date, row) for each line whose first cell is a date; the row is None when the line cannot be read.
    ValueError when the first line is a comment-audit ledger header other than the schema-1 line."""
    for number, raw in enumerate(handle):
        line = raw.decode("utf-8", "replace").rstrip("\r\n")
        problem = _foreign(line) if number == 0 and line.startswith(SCHEMA_PREFIX) else None
        if problem:
            raise ValueError(problem)
        cells = line.split("\t")
        if ROW_DATE.match(cells[0]):
            yield cells[0], _stat(cells)


def _percentile(values: list[float], pct: int) -> float | None:
    ordered = sorted(values)
    return ordered[(pct * len(ordered) + 99) // 100 - 1] if ordered else None


def _summary(name: str, stats: list[Stat]) -> tuple[str, ...]:
    gated = [stat.density for stat in stats if stat.density is not None]
    whole = [stat.file_density for stat in stats if stat.file_density is not None]
    sums = [sum(stat.sums[index] for stat in stats) for index in range(len(SUMMED))]
    return (_cell(name), str(len({stat.run for stat in stats})), str(sum(stat.measured for stat in stats)),
            str(len(gated)),
            ratio(_percentile(gated, 50)), ratio(_percentile(gated, 90)), ratio(_percentile(whole, 50)),
            *map(str, sums))


def trend(dated: Iterable[tuple[str, Stat | None]], since: str, project: str | None,
          by: str = "project") -> tuple[list[tuple[str, ...]], int, int]:
    """Rows per project (or per calling skill, `-` for runs that named none) sorted by name, the number of rows
    used, and the malformed rows in the window. `project` is the stored (escaped) name; a malformed row has no
    project to filter on, so it counts as skipped under any `project`. ValueError for a `by` other than
    project or skill."""
    if by not in TREND_BY:
        raise ValueError(f"--by {by!r}: expected one of {', '.join(TREND_BY)}")
    groups: dict[str, list[Stat]] = defaultdict(list)
    skipped = 0
    for date, stat in dated:
        if date < since:
            continue
        if stat is None:
            skipped += 1
        elif project is None or stat.project == project:
            groups[(stat.skill or NONE) if by == "skill" else stat.project].append(stat)
    table = [_summary(name, stats) for name, stats in sorted(groups.items())]
    return table, sum(len(stats) for stats in groups.values()), skipped


def render_trend(table: list[tuple[str, ...]], header: str, markdown: bool, first: str = "PROJECT") -> str:
    head = (first, *TREND_HEADER[1:])
    if markdown:
        header = MARKDOWN.sub(r"\\\1", header)
    if not table:
        return f"{header}\n(no rows)\n"
    if markdown:
        cells = [head, *((MARKDOWN.sub(r"\\\1", row[0]), *row[1:]) for row in table)]
        lines = ["| " + " | ".join(row) + " |" for row in cells]
        lines.insert(1, "|---|" + "---:|" * (len(TREND_HEADER) - 1))
        return "\n".join([header, "", *lines]) + "\n"
    rows = [head, *table]
    widths = [max(len(row[col]) for row in rows) for col in range(len(TREND_HEADER))]
    lines = ["  ".join(row[col].ljust(widths[col]) for col in range(len(widths))).rstrip() for row in rows]
    return "\n".join([header, *lines]) + "\n"


def trend_report(path: str, options: TrendOptions, now: dt.datetime) -> str:
    """The --trend output. ValueError for a bad window or schema; OSError when an existing ledger cannot be
    read."""
    if options.project == "":
        raise ValueError("--project: empty project name")
    if options.by not in TREND_BY:
        raise ValueError(f"--by {options.by!r}: expected one of {', '.join(TREND_BY)}")
    start = window_start(options.days, options.since, now)
    table: list[tuple[str, ...]] = []
    rows = skipped = 0
    with contextlib.suppress(FileNotFoundError), os.fdopen(_open(path, os.O_RDONLY), "rb") as handle:
        wanted = None if options.project is None else escape(options.project)  # names are stored escaped
        table, rows, skipped = trend(read_rows(handle), start, wanted, options.by)
    project = "*" if options.project is None else escape(options.project)
    by = "" if options.by == "project" else f" by={options.by}"
    header = f"trend: since={start} project={project}{by} rows={rows} skipped={skipped} ledger={_cell(path)}"
    return render_trend(table, header, options.markdown, options.by.upper())
