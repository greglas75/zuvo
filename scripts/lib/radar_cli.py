"""Refactor Radar v2 CLI: DISCOVER first; explicit, validated REGISTER only."""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import datetime, timezone
import json
import math
from pathlib import Path
import re
import sys
from typing import Any

import radar_git as git
import radar_metrics as metrics
import radar_io
from radar_remote import safe_path

SCHEMA = 2
BUSY_TTL = 300
TYPES = {
    "EXTRACT_METHODS",
    "SPLIT_FILE",
    "GOD_CLASS",
    "SIMPLIFY",
    "DEDUPE",
    "BREAK_CIRCULAR",
    "HUB_SPLIT",
    "DELETE_DEAD",
    "COVER",
}


def read_text(path: Path) -> str:
    return radar_io.read_text(path, git.MAX_TOTAL)


def load_json(path: Path, label: str) -> dict:
    try:
        value = json.loads(read_text(path))
    except (OSError, UnicodeError, json.JSONDecodeError) as err:
        raise ValueError(f"{label}: cannot read valid JSON: {path}") from err
    if not isinstance(value, dict):
        raise ValueError(f"{label}: expected JSON object")
    return value


def integer(value: object, name: str, minimum: int = 0) -> int:
    if type(value) not in (int, str) or not re.fullmatch(r"[0-9]+", str(value)):
        raise ValueError(f"{name}: expected integer")
    number = int(str(value))
    if not minimum <= number <= 100_000:
        raise ValueError(f"{name}: outside {minimum}..100000")
    return number


def config(root: Path, explicit: str | None) -> tuple[dict, str | None]:
    selected = (
        Path(explicit).resolve()
        if explicit
        else next((p for p in [root / ".radar.json", root / "zuvo/radar.json"] if p.is_file()), None)
    )
    cfg = load_json(selected, "config") if selected else {}
    for key in ("noise", "ext", "source_roots", "exclude_paths"):
        if key in cfg and (
            not isinstance(cfg[key], list) or not all(isinstance(v, str) and v for v in cfg[key])
        ):
            raise ValueError(f"config.{key}: expected nonempty strings")
    for key in ("source_roots", "exclude_paths"):
        for path in cfg.get(key, []):
            safe_path(path)
    for pattern in cfg.get("noise", []):
        re.compile(pattern)
    for key, choices in {
        "profile": {"application", "tooling"},
        "remote": {"auto", "gh", "bb", "none"},
        "engine": {"builtin", "codesift"},
    }.items():
        if key in cfg and cfg[key] not in choices:
            raise ValueError(f"config.{key}: unsupported value")
    if not isinstance(cfg.get("critical", []), list):
        raise ValueError("config.critical: expected list")
    for rule in cfg.get("critical", []):
        if not isinstance(rule, dict) or not isinstance(rule.get("pattern"), str) or "k" not in rule:
            raise ValueError("config.critical: expected pattern and k")
        re.compile(rule["pattern"])
    for value in [cfg.get("k_default", 3), *(r["k"] for r in cfg.get("critical", []))]:
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 < value <= 10:
            raise ValueError("config criticality: expected finite K in (0,10]")
    for key in ("repo_id", "remote_name", "bb_repo", "gh_repo", "bb_user", "history_dir", "ref"):
        if key in cfg and (not isinstance(cfg[key], str) or not cfg[key]):
            raise ValueError(f"config.{key}: expected nonempty string")
    groups = cfg.get("families", [])
    if not isinstance(groups, list):
        raise ValueError("config.families: expected list")
    seen: set[str] = set()
    for group in groups:
        if (
            not isinstance(group, dict)
            or not isinstance(group.get("id"), str)
            or not isinstance(group.get("files"), list)
            or not group["files"]
        ):
            raise ValueError("config.families: expected id and nonempty files")
        for path in group["files"]:
            safe_path(path)
            if path in seen:
                raise ValueError("config.families: overlapping members")
            seen.add(path)
    promotions = cfg.get("promotion_branches", [])
    if not isinstance(promotions, list) or not all(
        isinstance(p, list) and len(p) == 2 and all(isinstance(s, str) and s for s in p) for p in promotions
    ):
        raise ValueError("config.promotion_branches: expected [head, base] pairs")
    return cfg, str(selected) if selected else None


def arguments(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in (
        "repo",
        "ref",
        "top",
        "min-cc",
        "since",
        "fresh-days",
        "engine",
        "config",
        "json",
        "queue",
        "history",
        "busy-file",
        "scope",
        "cutoff",
        "codesift-json",
        "capture-busy",
        "busy-snapshot",
        "decisions",
    ):
        parser.add_argument("--" + option)
    parser.add_argument("--mode", choices=["refactor", "tests"], default="refactor")
    for flag in ("quiet", "dry-run", "no-remote", "register", "record-snapshot"):
        parser.add_argument("--" + flag, action="store_true")
    return parser.parse_args(argv)


def cutoff_time(value: str | None) -> int:
    if value is None:
        return int(datetime.now(timezone.utc).timestamp())
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("--cutoff requires a timezone")
    return int(parsed.timestamp())


def busy_inputs(root: Path, sha: str, cfg: dict, args: argparse.Namespace) -> dict:
    busy = (
        load_json(Path(args.busy_snapshot), "busy snapshot")
        if args.busy_snapshot
        else git.collect_busy(root, sha, cfg, args.no_remote)
    )
    if (
        busy.get("schema") != 1
        or busy.get("sha") != sha
        or not isinstance(busy.get("repo_id"), str)
        or type(busy.get("complete")) is not bool
        or type(busy.get("captured_at")) is not int
        or not isinstance(busy.get("paths"), list)
        or not isinstance(busy.get("hints"), list)
        or not all(isinstance(h, str) for h in busy["hints"])
    ):
        raise ValueError("busy snapshot: invalid or source SHA mismatch")
    if busy["repo_id"] != git.repo_identity(root, cfg)[0]:
        raise ValueError("busy snapshot: repo identity mismatch; declare stable repo_id in the profile")
    busy["paths"] = sorted({safe_path(p) for p in busy["paths"]})
    for provider in ("local", "remote"):
        leaf = busy.get(provider)
        if (
            not isinstance(leaf, dict)
            or type(leaf.get("complete")) is not bool
            or not isinstance(leaf.get("paths"), list)
        ):
            raise ValueError("busy snapshot: missing provider completeness")
        busy["complete"] = busy["complete"] and leaf["complete"]
        busy["paths"] = sorted(set(busy["paths"]) | {safe_path(p) for p in leaf["paths"]})
    now = int(datetime.now(timezone.utc).timestamp())
    if not 0 <= now - busy["captured_at"] <= BUSY_TTL:
        busy.update(complete=False, stale=True, expired_paths=busy["paths"], paths=[])
        for provider in ("local", "remote"):
            busy[provider].update(complete=False, paths=[])
    if args.busy_file:
        busy["paths"] = sorted(
            set(busy["paths"])
            | {safe_path(p.rstrip("\r")) for p in read_text(Path(args.busy_file)).split("\n") if p}
        )
    return busy


def codesift(path: str | None, sha: str, repo_id: str, sources: list[str]) -> tuple[dict, str]:
    if not path:
        raise ValueError("--engine codesift requires --codesift-json with verified repo/SHA/completeness")
    envelope = load_json(Path(path), "CodeSift envelope")
    meta, functions = envelope.get("meta", {}), envelope.get("functions")
    if (
        not isinstance(meta, dict)
        or meta.get("sha") != sha
        or meta.get("repo") != repo_id
        or meta.get("complete") is not True
        or not isinstance(meta.get("version"), str)
        or not isinstance(functions, list)
        or meta.get("total_functions") != len(functions)
    ):
        raise ValueError("CodeSift envelope: stale identity or incomplete function census")
    per_file: dict[str, list] = {p: [] for p in sources}
    seen = set()
    for fn in functions:
        if not isinstance(fn, dict):
            raise ValueError("CodeSift envelope: malformed function")
        path = safe_path(fn.get("file"))
        if path not in per_file:
            raise ValueError("CodeSift envelope: file outside source census")
        row: dict[str, Any] = {
            key: integer(fn.get(field), "CodeSift " + field, minimum)
            for key, field, minimum in [
                ("cc", "cyclomatic_complexity", 1),
                ("line", "line", 1),
                ("lines", "lines", 1),
                ("nest", "max_nesting_depth", 0),
            ]
        }
        if not isinstance(fn.get("name"), str) or not fn["name"]:
            raise ValueError("CodeSift envelope: missing function name")
        row["name"] = fn["name"]
        identity = (path, row["line"], row["name"])
        if identity in seen:
            raise ValueError("CodeSift envelope: duplicate function")
        seen.add(identity)
        per_file[path].append(row)
    return per_file, meta["version"]


def write_artifact(path: Path, content: str) -> None:
    radar_io.write_artifact(path, content, git.MAX_TOTAL)


def previous(history: str | None, meta: dict) -> tuple[dict | None, str | None]:
    if not history or not Path(history).exists():
        return None, None
    matches = []
    for path in sorted(Path(history).glob("*.json")):
        old = load_json(path, "history")
        header = old.get("meta", {})
        keys = (
            "schema",
            "repo_id",
            "engine",
            "parser_version",
            "policy_version",
            "config_hash",
            "scope_hash",
            "mode",
        )
        if not isinstance(header, dict) or not all(header.get(k) == meta.get(k) for k in keys):
            continue
        if not isinstance(old.get("rows"), list) or not all(
            isinstance(r, dict) and isinstance(r.get("family"), str) for r in old["rows"]
        ):
            raise ValueError("history: malformed candidate rows")
        timestamp = header.get("cutoff_time")
        if type(timestamp) is not int:
            raise ValueError("history: cutoff must be an integer timestamp")
        if header.get("sha") != meta["sha"] and timestamp < meta["cutoff_time"]:
            matches.append((timestamp, str(path), old))
    latest = max(matches, key=lambda item: (item[0], item[1])) if matches else None
    return (latest[2], latest[1]) if latest else (None, None)


def queue_content(report: dict, decisions: dict, top: int) -> str:
    if decisions.get("input_fingerprint") != report["meta"]["input_fingerprint"]:
        raise ValueError("decisions: stale input fingerprint")
    selected = decisions.get("candidates")
    if not isinstance(selected, list) or not selected or len(selected) > top:
        raise ValueError("decisions: expected 1..top validated candidates")
    rows = {row["family"]: row for row in report["rows"]}
    output = [
        "# Refactor Batch -- " + report["meta"]["date"],
        "# Explicit REGISTER; not a reservation. Revalidate before execution.",
        "",
    ]
    written: set[str] = set()
    families: set[str] = set()
    for decision in selected:
        if not isinstance(decision, dict) or decision.get("family") not in rows:
            raise ValueError("decisions: candidate outside ranked scope")
        row = rows[decision["family"]]
        gates = decision.get("gates", {})
        scope = decision.get("write_scope")
        verification = decision.get("verification_scope")
        allowed_types = {"COVER"} if report["meta"]["mode"] == "tests" else TYPES - {"COVER"}
        if (
            row["availability"] != "FREE"
            or not isinstance(gates, dict)
            or any(gates.get(k) is not True for k in ("G1", "G2", "G3", "G4", "G5"))
            or decision.get("type") not in allowed_types
            or not isinstance(decision.get("evidence"), str)
            or not decision["evidence"].strip()
            or not isinstance(scope, list)
            or not scope
            or not all(isinstance(p, str) and p in row["files"] for p in scope)
            or not isinstance(verification, list)
            or not verification
            or not all(isinstance(v, str) and v.strip() for v in verification)
            or decision["family"] in families
            or any(i["file"] in row["files"] for i in report["meta"]["source_issues"])
            or set(scope).intersection(written)
        ):
            raise ValueError(
                "decisions: require measured FREE scope, G1-G5 evidence, verification_scope and no overlaps"
            )
        if any("|" in p for p in scope):
            raise ValueError("batch format cannot represent a path containing '|'")
        written.update(scope)
        families.add(decision["family"])
        batch_type = {"HUB_SPLIT": "SPLIT_FILE", "DEDUPE": "EXTRACT_METHODS"}.get(
            decision["type"], decision["type"]
        )
        output += [
            f"- [ ] {scope[0]} | {batch_type} | Score: {row['score_norm']:.2f}",
            "# intent=" + decision["type"],
            "# write_scope=" + json.dumps(scope, ensure_ascii=True),
            "# analysis_scope=" + json.dumps(row["files"], ensure_ascii=True),
            "# verification_scope=" + json.dumps(verification, ensure_ascii=True),
        ]
    return "\n".join(output) + "\n"


def options(args: argparse.Namespace, cfg: dict) -> dict:
    values: dict[str, Any] = {}
    for arg, key, default, low in [
        ("top", "top", 50, 1),
        ("since", "since_days", 180, 1),
        ("fresh_days", "fresh_days", 30, 0),
    ]:
        value = getattr(args, arg)
        values[key] = integer(value if value is not None else cfg.get(key, default), "--" + arg, low)
    minimum = args.min_cc if args.min_cc is not None else cfg.get("min_cc")
    values["min_cc"] = integer(minimum, "--min-cc") if minimum is not None else None
    values["engine"] = args.engine or cfg.get("engine", "builtin")
    values["scope"] = args.scope or "."
    values["cutoff"] = cutoff_time(args.cutoff)
    values["history"] = args.history or cfg.get("history_dir")
    if values["engine"] not in ("builtin", "codesift"):
        raise ValueError("--engine must be builtin|codesift")
    if values["scope"] != ".":
        safe_path(values["scope"])
    if args.queue and not args.register and not args.dry_run:
        raise ValueError("--queue requires --register and --decisions; discovery is read-only")
    if args.register and (not args.queue or not args.decisions):
        raise ValueError("--register requires --queue and --decisions")
    if args.record_snapshot and not values["history"]:
        raise ValueError("--record-snapshot requires --history")
    if args.capture_busy and (args.register or args.json or args.record_snapshot or args.busy_snapshot):
        raise ValueError("--capture-busy is a separate control-plane operation")
    return values


def source_inputs(root: Path, sha: str, cfg: dict, opts: dict, args: argparse.Namespace, busy: dict) -> dict:
    entries = git.tree(root, sha)
    sources, tests = metrics.classify(list(entries), cfg)
    if opts["scope"] != "." and not any(metrics.in_scope(p, opts["scope"]) for p in sources):
        raise ValueError("--scope does not select a production file")
    contents, issues = git.blobs(root, entries, sources + tests)
    measured, parse_issues = metrics.measure({p: contents[p] for p in sources if p in contents})
    parser_version = metrics.ENGINE_VERSION
    if opts["engine"] == "codesift":
        measured, parser_version = codesift(args.codesift_json, sha, busy["repo_id"], sources)
        parse_issues = []
    graph, unresolved = metrics.import_graph(contents, sources)
    commits = git.history(root, sha, opts["cutoff"], max(opts["since_days"], opts["fresh_days"]))
    return dict(
        opts,
        contents=contents,
        metrics=measured,
        graph=graph,
        sources=sources,
        tests=tests,
        commits=commits,
        busy=busy,
        cfg=cfg,
        mode=args.mode,
        issues=issues + parse_issues,
        parser_version=parser_version,
        unresolved=unresolved,
    )


def report_for(data: dict, sha: str, config_path: str | None) -> dict:
    rows, excluded, floor = metrics.rank(metrics.families(data["sources"], data["graph"], data["cfg"]), data)
    busy_key = {k: v for k, v in data["busy"].items() if k != "captured_at"}
    meta = dict(
        schema=SCHEMA,
        repo_id=data["busy"]["repo_id"],
        sha=sha,
        engine=data["engine"],
        parser_version=data["parser_version"],
        policy_version=metrics.POLICY_VERSION,
        config_path=config_path,
        config_hash=git.digest(data["cfg"]),
        scope=data["scope"],
        scope_hash=git.digest([data["scope"], data["sources"]]),
        cutoff_time=data["cutoff"],
        date=datetime.fromtimestamp(data["cutoff"], timezone.utc).isoformat().replace("+00:00", "Z"),
        since_days=data["since_days"],
        fresh_days=data["fresh_days"],
        min_cc=floor,
        mode=data["mode"],
        busy=data["busy"],
        population=len(rows) + len(excluded),
        source_files=len(data["sources"]),
        source_issues=data["issues"],
        measurement="estimated" if data["engine"] == "builtin" else "provided-codesift-envelope",
        graph="relative-import approximation; type-only/aliases need G5",
        unresolved_imports=data["unresolved"],
        excluded=dict(Counter(r["excluded"] for r in excluded)),
    )
    policy = [
        data[k]
        for k in (
            "scope",
            "sources",
            "cutoff",
            "since_days",
            "fresh_days",
            "engine",
            "parser_version",
            "mode",
            "top",
        )
    ]
    meta["input_fingerprint"] = git.digest(
        [sha, data["cfg"], floor, policy, metrics.POLICY_VERSION, busy_key, data["metrics"]]
    )
    old, meta["prev"] = previous(data["history"], meta)
    previous_families = {r["family"] for r in old["rows"]} if old else set()
    for row in rows:
        row["history"] = (
            "persistent" if row["family"] in previous_families else "new" if old else "unavailable"
        )
    return {"meta": meta, "rows": rows, "excluded_rows": excluded}


def artifacts(args: argparse.Namespace, opts: dict, report: dict) -> None:
    # Validate all requests before any artifact is written; discovery never appends a ledger.
    queue = (
        queue_content(report, load_json(Path(args.decisions), "decisions"), opts["top"])
        if args.register
        else None
    )
    if args.dry_run:
        return
    serialized = json.dumps(report, indent=2, sort_keys=True) + "\n"
    pending: list[tuple[Path, str]] = []
    if args.json:
        pending.append((Path(args.json), serialized))
    if args.record_snapshot:
        fingerprint = report["meta"]["input_fingerprint"]
        snapshot = Path(opts["history"]) / f"{opts['cutoff']}-{fingerprint}.json"
        # Immutable history keeps the first capture for this exact input, including its capture time.
        existing = load_json(snapshot, "snapshot") if snapshot.is_file() and not snapshot.is_symlink() else {}
        header = existing.get("meta", {})
        if not isinstance(header, dict):
            raise ValueError("snapshot: malformed metadata")
        if header.get("input_fingerprint") != fingerprint:
            pending.append((snapshot, serialized))
    if queue is not None:
        pending.append((Path(args.queue), queue))
    resolved = [p.resolve() for p, _ in pending]
    if len(set(resolved)) != len(resolved):
        raise ValueError("output paths must be distinct")
    for path, content in pending:
        if path.is_symlink() or (path.exists() and (not path.is_file() or read_text(path) != content)):
            raise ValueError(f"output already exists with different content: {path}")
    for path, content in pending:
        write_artifact(path, content)


def display(report: dict, top: int) -> None:
    meta = report["meta"]
    print(
        f"population: {meta['source_files']} source files / {meta['population']} families; "
        f"floor={meta['min_cc']}; excluded={meta['excluded']}",
        file=sys.stderr,
    )
    print(
        f"REFACTOR RADAR {meta['sha'][:9]} | {meta['engine']} ({meta['measurement']}) | "
        f"{meta['policy_version']}"
    )
    print(" #  score  availability  ΣCC    D  max nest  family (hypothesis, not READY)")
    for row in report["rows"][:top]:
        print(
            f"{row['rank']:2} {row['score_norm']:6.2f} {row['availability']:>13} "
            f"{row['sum']:4} {row['decisions']:4} {row['max']:4} {row['nest']:4}  {row['family']}"
        )


def run(args: argparse.Namespace, root: Path) -> dict:
    cfg, config_path = config(root, args.config)
    opts = options(args, cfg)
    sha = git.text(
        root, "rev-parse", "--verify", "--end-of-options", (args.ref or cfg.get("ref", "HEAD")) + "^{commit}"
    )
    busy = busy_inputs(root, sha, cfg, args)
    if args.capture_busy:
        if not args.dry_run:
            write_artifact(Path(args.capture_busy), json.dumps(busy, indent=2, sort_keys=True) + "\n")
        return {"busy": busy}
    report = report_for(source_inputs(root, sha, cfg, opts, args, busy), sha, config_path)
    artifacts(args, opts, report)
    if not args.quiet:
        display(report, opts["top"])
    return report


def main(argv: list[str] | None = None) -> int:
    args = arguments(argv)
    try:
        root = Path(git.text(Path(args.repo or "."), "rev-parse", "--show-toplevel")).resolve()
    except (ValueError, OSError):
        print("refactor-radar: not a git repo", file=sys.stderr)
        return 3
    try:
        run(args, root)
    except (ValueError, TypeError, KeyError, OSError, re.error) as err:
        print(f"refactor-radar: {err}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
