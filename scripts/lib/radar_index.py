"""Run-local reverse indexes; never cache mutable availability across scans."""

from collections import defaultdict
import re


def build(inputs: dict) -> dict:
    incoming: dict[str, set[str]] = defaultdict(set)
    commits: dict[str, set[int]] = defaultdict(set)
    tests: dict[str, set[str]] = defaultdict(set)
    for source, targets in inputs["graph"].items():
        for target in targets:
            incoming[target].add(source)
    for index, commit in enumerate(inputs["commits"]):
        for path in commit["files"]:
            commits[path].add(index)
    for path in inputs["tests"]:
        tests[re.sub(r"\.(test|spec)\.", ".", path)].add(path)
    return dict(
        sources=set(inputs["sources"]),
        test_set=set(inputs["tests"]),
        incoming=incoming,
        commits=commits,
        tests=tests,
        loc={
            p: sum(bool(line.strip()) for line in text.splitlines()) for p, text in inputs["contents"].items()
        },
    )


def related(members: list[str], inputs: dict, index: dict) -> tuple[list[dict], list[str], list[str]]:
    commit_ids: set[int] = set()
    incoming: set[str] = set()
    tests: set[str] = set()
    for path in members:
        commit_ids.update(index["commits"].get(path, ()))
        incoming.update(index["incoming"].get(path, ()))
        tests.update(index["tests"].get(path, ()))
    tests.update(incoming & index["test_set"])
    importers = sorted((incoming & index["sources"]) - set(members))
    # Preserve Git's original order and count a family-touching commit only once.
    return [inputs["commits"][i] for i in sorted(commit_ids)], sorted(tests), importers
