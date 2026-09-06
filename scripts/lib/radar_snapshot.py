"""Portable, data-only farm inputs; no Git checkout or credentials on the worker."""

import json
from pathlib import Path
import re

import radar_git as git
import radar_io
from radar_remote import safe_path

VERSION = 1


def prepare(directory: Path, data: dict, sha: str, config_path: str | None) -> None:
    if directory.is_symlink() or (
        directory.exists() and (not directory.is_dir() or any(directory.iterdir()))
    ):
        raise ValueError("--prepare-farm requires a new or empty directory")
    # Only our own installed modules, never source-repo scripts or a repository's .git/config.
    library = Path(__file__).resolve().parent
    files = {"refactor-radar.sh": library.parent / "refactor-radar.sh"}
    files.update({"lib/" + path.name: path for path in sorted(library.glob("radar_*.py"))})
    payload = dict(version=VERSION, sha=sha, config_path=config_path, data=data)
    envelope = dict(payload=payload, checksum=git.digest(payload))
    serialized = json.dumps(envelope, ensure_ascii=True, separators=(",", ":")) + "\n"
    if len(serialized.encode()) > git.MAX_TOTAL:
        raise ValueError("farm input exceeds byte budget; narrow source_roots")
    for name, path in files.items():
        radar_io.write_artifact(directory / name, radar_io.read_text(path, git.MAX_TOTAL), git.MAX_TOTAL)
    # Completion marker is published last; partial preparations must not be dispatched.
    radar_io.write_artifact(directory / "input.json", serialized, git.MAX_TOTAL)


def load(path: Path) -> tuple[dict, str, str | None]:
    envelope = json.loads(radar_io.read_text(path, git.MAX_TOTAL))
    if not isinstance(envelope, dict) or not isinstance(envelope.get("payload"), dict):
        raise ValueError("farm input: invalid envelope")
    payload = envelope["payload"]
    if payload.get("version") != VERSION or envelope.get("checksum") != git.digest(payload):
        raise ValueError("farm input: version/checksum mismatch")
    sha, data = payload.get("sha"), payload.get("data")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40,64}", sha) or not isinstance(data, dict):
        raise ValueError("farm input: missing source identity")
    if payload.get("config_path") is not None and not isinstance(payload["config_path"], str):
        raise ValueError("farm input: invalid config path metadata")
    busy = data.get("busy")
    if not isinstance(busy, dict) or busy.get("sha") != sha or not isinstance(busy.get("repo_id"), str):
        raise ValueError("farm input: availability identity mismatch")
    if not isinstance(data.get("cfg"), dict) or data.get("engine") not in ("builtin", "codesift"):
        raise ValueError("farm input: invalid profile or engine")
    if data.get("mode") not in ("refactor", "tests") or not isinstance(data.get("scope"), str):
        raise ValueError("farm input: invalid mode or scope")
    for key in ("cutoff", "since_days", "fresh_days", "top"):
        if type(data.get(key)) is not int or (key != "cutoff" and data[key] < 0):
            raise ValueError("farm input: invalid numeric options")
    if "min_cc" not in data or (
        data["min_cc"] is not None and (type(data["min_cc"]) is not int or not 0 <= data["min_cc"] <= 100_000)
    ):
        raise ValueError("farm input: invalid complexity floor")
    commits = data.get("commits")
    if not isinstance(commits, list):
        raise ValueError("farm input: invalid history")
    for commit in commits:
        if (
            not isinstance(commit, dict)
            or not isinstance(commit.get("files"), list)
            or type(commit.get("epoch")) is not int
            or not isinstance(commit.get("id"), str)
            or commit.get("kind") not in ("fix", "feat", "refactor", "test", "style", "unknown")
        ):
            raise ValueError("farm input: invalid commit")
        for name in commit["files"]:
            safe_path(name)
    for key in ("sources", "tests"):
        values = data.get(key)
        if (
            not isinstance(values, list)
            or len(values) > git.MAX_FILES
            or not all(isinstance(v, str) for v in values)
            or len(set(values)) != len(values)
        ):
            raise ValueError("farm input: invalid file census")
        for name in values:
            safe_path(name)
    if set(data["sources"]) & set(data["tests"]):
        raise ValueError("farm input: sources/tests overlap")
    selected = set(data["sources"] + data["tests"])
    contents = data.get("contents")
    if not isinstance(contents, dict) or set(contents) - selected:
        raise ValueError("farm input: content outside file census")
    for name, text in contents.items():
        safe_path(name)
        if not isinstance(text, str) or len(text.encode()) > git.MAX_BLOB:
            raise ValueError("farm input: invalid source blob")
    issues = data.get("issues")
    if not isinstance(issues, list) or not all(
        isinstance(item, dict) and isinstance(item.get("file"), str) and isinstance(item.get("reason"), str)
        for item in issues
    ):
        raise ValueError("farm input: invalid source issues")
    for item in issues:
        if safe_path(item["file"]) not in selected:
            raise ValueError("farm input: issue outside file census")
    if selected - set(contents) - {item["file"] for item in issues}:
        raise ValueError("farm input: missing source without an explicit issue")
    if "history" not in data or data["history"] is not None:
        raise ValueError("farm input cannot reference host history paths")
    if data["engine"] == "codesift":
        validate_metrics(data)
    return data, sha, payload.get("config_path")


def validate_metrics(data: dict) -> None:
    """Imported CodeSift values are data, not a request to measure source on this host."""
    values = data.get("metrics")
    if (
        not isinstance(values, dict)
        or set(values) != set(data["sources"])
        or not isinstance(data.get("parser_version"), str)
        or not data["parser_version"]
    ):
        raise ValueError("farm input: invalid CodeSift metrics or version")
    for functions in values.values():
        if not isinstance(functions, list):
            raise ValueError("farm input: invalid CodeSift functions")
        for fn in functions:
            if (
                not isinstance(fn, dict)
                or not isinstance(fn.get("name"), str)
                or not fn["name"]
                or any(
                    type(fn.get(key)) is not int or not minimum <= fn[key] <= 100_000
                    for key, minimum in [("cc", 1), ("line", 1), ("lines", 1), ("nest", 0)]
                )
            ):
                raise ValueError("farm input: invalid CodeSift function")
