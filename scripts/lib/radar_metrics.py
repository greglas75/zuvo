"""Versioned discovery heuristics, not execution priorities or coverage estimates."""

from __future__ import annotations

import ast
from collections import Counter, defaultdict
import math
import posixpath
import re

ENGINE_VERSION = "python-ast-v1/clike-regex-v2"
POLICY_VERSION = "discovery-v2"
EXTENSIONS = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "php", "kt"]
NOISE = re.compile(
    r"(^|/)(node_modules|vendor|dist|build|out|coverage|playwright-report|test-results|"
    r"\.worktrees|worktrees|handoff|\.turbo|\.next|__pycache__|generated|gen|docs|"
    r"migrations|seeds?|fixtures?|__mocks__|__snapshots__|zuvo)/|\.(min|d)\.[^.]+$|^prisma/seed-"
)
TEST = re.compile(r"\.(test|spec|stories|e2e)\.[^.]+$|(^|/)(tests?|__tests__|e2e)/|(^|/)test_[^/]+\.py$")
LITERALS = re.compile(
    r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\\n])*"|\'(?:\\.|[^\'\\\n])*\'|`(?:\\.|[^`\\])*`', re.S
)
DECISIONS = re.compile(r"\b(if|for|foreach|while|case|catch|when)\b|&&|\|\||\?\?|\?(?![.:])")
# Kept dependency-free deliberately. TS types, templates, regex literals and anonymous
# expression arrows make this an ESTIMATE, never an AST census or a refactor success gate.
FUNCTIONS = re.compile(
    r"\bfunction\s*\*?\s*([A-Za-z_$][\w$]*)?\s*\([^()]{0,400}(?:\([^()]{0,200}\)[^()]{0,400}){0,6}\)\s*(?::\s*[^{;=]{0,120})?\s*\{|"
    r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]{0,80})?=\s*(?:async\s*)?(?:\([^()]{0,400}\)|[A-Za-z_$][\w$]*)\s*(?::\s*[^=;{]{0,80})?=>\s*\{|"
    r"(?:^|[\s;{}])(?:(?:public|private|protected|static|async|override|fun|suspend|export|default)\s+)*([A-Za-z_$][\w$]*)\s*(?:<[^>]{0,80}>)?\s*\([^()]{0,400}\)\s*(?::\s*[^{;=]{0,120})?\s*\{|"
    r"(?:\([^()]{0,400}\)|[A-Za-z_$][\w$]*)\s*=>\s*\{",
    re.M,
)
KEYWORDS = {"if", "for", "while", "switch", "catch", "return", "else", "do", "try", "when", "foreach", "with"}
IMPORT = re.compile(r"(?:\bfrom\s*|\bimport\s*(?:\(\s*)?|\brequire\s*\(\s*)['\"]([^'\"]+)['\"]")


def blank(text: str) -> str:
    return "".join("\n" if c == "\n" else " " for c in text)


def classify(paths: list[str], cfg: dict) -> tuple[list[str], list[str]]:
    sources, tests = [], []
    noise = [re.compile(p) for p in cfg.get("noise", [])]
    roots = cfg.get("source_roots", [])
    for path in paths:
        if path.rsplit(".", 1)[-1] not in cfg.get("ext", EXTENSIONS) or NOISE.search(path):
            continue
        if TEST.search(path):
            tests.append(path)
        elif (
            not any(p.search(path) for p in noise)
            and (cfg.get("profile") == "tooling" or not path.startswith("scripts/"))
            and (not roots or any(in_scope(path, root) for root in roots))
        ):
            sources.append(path)
    return sorted(sources), sorted(tests)


def in_scope(path: str, scope: str) -> bool:
    return scope == "." or path == scope or path.startswith(scope.rstrip("/") + "/")


def clike(text: str) -> list[dict]:
    cleaned = LITERALS.sub(lambda m: blank(m.group()), text)
    closes, stack = {}, []
    for i, char in enumerate(cleaned):
        if char == "{":
            stack.append(i)
        elif char == "}" and stack:
            closes[stack.pop()] = i
    spans = []
    for match in FUNCTIONS.finditer(cleaned):
        name = next((g for g in match.groups() if g), "<anonymous>")
        start = match.end() - 1
        if name not in KEYWORDS and start in closes:
            spans.append((start, closes[start], name))
    rows = []
    for index, (start, end, name) in enumerate(spans):
        body = cleaned[start + 1 : end]
        cursor = start
        # Exclude direct children exactly once; descendants belong to their own row.
        for child_start, child_end, _ in spans[index + 1 :]:
            if child_start > end:
                break
            if child_start > cursor:
                offset, length = child_start - start - 1, child_end - child_start + 1
                body = body[:offset] + blank(body[offset : offset + length]) + body[offset + length :]
                cursor = child_end
        depth = nesting = 0
        for char in body:
            if char == "{":
                depth += 1
                nesting = max(depth, nesting)
            elif char == "}":
                depth -= 1
        rows.append(
            {
                "name": name,
                "cc": 1 + len(DECISIONS.findall(body)),
                "nest": nesting,
                "line": cleaned.count("\n", 0, start) + 1,
                "lines": body.count("\n") + 1,
            }
        )
    return rows


def python_functions(text: str) -> list[dict]:
    parsed = ast.parse(text)
    function_types = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)
    branches = (ast.If, ast.For, ast.AsyncFor, ast.While, ast.ExceptHandler, ast.IfExp, ast.comprehension)

    def decisions(node: ast.AST, depth: int = 0) -> tuple[int, int]:
        if isinstance(node, function_types + (ast.ClassDef,)):
            return 0, depth
        cost = int(isinstance(node, branches))
        if isinstance(node, ast.BoolOp):
            cost += len(node.values) - 1
        if isinstance(node, ast.comprehension):
            cost += len(node.ifs)
        if isinstance(node, ast.match_case):
            # A bare wildcard/capture is default; guarded/default cases still branch.
            cost += int(
                not isinstance(node.pattern, ast.MatchAs)
                or node.pattern.pattern is not None
                or node.guard is not None
            )
        nesting = depth + int(isinstance(node, branches))
        totals = [decisions(child, nesting) for child in ast.iter_child_nodes(node)]
        return cost + sum(c for c, _ in totals), max([nesting, *(d for _, d in totals)])

    rows = []
    for node in ast.walk(parsed):
        if not isinstance(node, function_types):
            continue
        body = node.body if isinstance(node.body, list) else [node.body]
        measured = [decisions(child) for child in body]
        rows.append(
            {
                "name": getattr(node, "name", "<lambda>"),
                "cc": 1 + sum(c for c, _ in measured),
                "nest": max([0, *(n for _, n in measured)]),
                "line": node.lineno,
                "lines": (node.end_lineno or node.lineno) - node.lineno + 1,
            }
        )
    return sorted(rows, key=lambda row: (row["line"], row["name"]))


def measure(contents: dict[str, str]) -> tuple[dict[str, list[dict]], list[dict]]:
    metrics, issues = {}, []
    for path, source in contents.items():
        try:
            metrics[path] = python_functions(source) if path.endswith(".py") else clike(source)
        except (SyntaxError, RecursionError):
            issues.append({"file": path, "reason": "parser failed"})
            metrics[path] = []
    return metrics, issues


def import_graph(contents: dict[str, str], sources: list[str]) -> tuple[dict[str, set[str]], list[dict]]:
    index = set(sources)
    graph: dict[str, set[str]] = defaultdict(set)
    unresolved = []
    for path, source in contents.items():
        if path.endswith((".py", ".php", ".kt")):
            continue
        code = LITERALS.sub(
            lambda m: blank(m.group()) if m.group().startswith(("//", "/*")) else m.group(), source
        )
        for spec in IMPORT.findall(code):
            if not spec.startswith("."):
                unresolved.append({"file": path, "specifier": spec, "kind": "external-or-alias"})
                continue
            target = posixpath.normpath(posixpath.join(posixpath.dirname(path), spec))
            base = re.sub(r"\.(m?js|cjs)$", "", target)
            candidates = (
                [target] + [f"{base}.{e}" for e in EXTENSIONS] + [f"{target}/index.{e}" for e in EXTENSIONS]
            )
            resolved = next((candidate for candidate in candidates if candidate in index), None)
            if resolved:
                graph[path].add(resolved)
            else:
                unresolved.append({"file": path, "specifier": spec, "kind": "unresolved-relative"})
    return graph, unresolved


def stem(path: str) -> str:
    return posixpath.basename(path).split(".")[0]


def related(a: str, b: str) -> bool:
    adir, bdir = posixpath.dirname(a), posixpath.dirname(b)
    return (
        (adir == bdir and stem(a) == stem(b))
        or bdir == posixpath.join(adir, stem(a))
        or adir == posixpath.join(bdir, stem(b))
    )


def families(sources: list[str], graph: dict[str, set[str]], cfg: dict) -> list[dict]:
    owners = {p: p for p in sources}
    evidence: list[tuple[str, str, str]] = []

    def owner(path: str) -> str:
        while owners[path] != path:
            owners[path] = owners[owners[path]]
            path = owners[path]
        return path

    def join(a: str, b: str, reason: str) -> None:
        left, right = sorted((owner(a), owner(b)))
        owners[right] = left
        evidence.append((a, b, reason))

    for path in sources:
        for target in sorted(graph.get(path, set())):
            if related(path, target):
                join(path, target, "relative-import + naming/layout (needs G3 validation)")
    for group in cfg.get("families", []):
        members = group["files"]
        if not all(p in owners for p in members):
            raise ValueError("declared family member outside production census")
        for member in members[1:]:
            join(members[0], member, "declared:" + group["id"])
    groups: dict[str, list[str]] = defaultdict(list)
    for path in sources:
        groups[owner(path)].append(path)
    return [
        {"files": sorted(members), "evidence": [e for e in evidence if e[0] in members]}
        for members in groups.values()
    ]


def criticality(members: list[str], cfg: dict) -> float:
    for rule in cfg.get("critical", []):
        if any(re.search(rule["pattern"], path, re.I) for path in members):
            return float(rule["k"])
    return float(cfg.get("k_default", 3))


def candidate(group: dict, inputs: dict) -> dict:
    members = group["files"]
    contents, metrics, graph = inputs["contents"], inputs["metrics"], inputs["graph"]
    functions = [dict(fn, file=path) for path in members for fn in metrics.get(path, [])]
    worst = max(
        functions,
        key=lambda f: (f["cc"], f["file"], f["line"]),
        default={"cc": 0, "name": "unmeasured", "file": members[0], "lines": 0},
    )
    sigma = sum(fn["cc"] for fn in functions)
    all_commits = [c for c in inputs["commits"] if set(c["files"]).intersection(members)]
    commits = [c for c in all_commits if c["epoch"] >= inputs["cutoff"] - inputs["since_days"] * 86400]
    fix = sum(c["kind"] == "fix" for c in commits)
    fresh = max((c["epoch"] for c in all_commits if c["kind"] == "refactor"), default=0)
    test_paths = sorted(
        {
            t
            for t in inputs["tests"]
            if set(graph.get(t, set())).intersection(members)
            or any(re.sub(r"\.(test|spec)\.", ".", t) == p for p in members)
        }
    )
    loc = sum(sum(bool(line.strip()) for line in contents.get(p, "").splitlines()) for p in members)
    test_loc = sum(sum(bool(line.strip()) for line in contents.get(t, "").splitlines()) for t in test_paths)
    importers = sorted(
        p
        for p, targets in graph.items()
        if p in inputs["sources"] and p not in members and set(targets).intersection(members)
    )
    hints = [
        h
        for h in inputs["busy"]["hints"]
        if any(len(stem(p)) >= 6 and stem(p).lower() in h.lower() for p in members)
    ]
    busy_paths = sorted(set(members).intersection(inputs["busy"]["paths"]))
    availability = "BUSY" if busy_paths else "FREE" if inputs["busy"]["complete"] and not hints else "UNKNOWN"
    key = min(members, key=lambda p: (len(p), p)).rsplit(".", 1)[0]
    k = criticality(members, inputs["cfg"])
    nesting = max((f["nest"] for f in functions), default=0)
    rtype = (
        "COVER"
        if inputs["mode"] == "tests"
        else "SIMPLIFY"
        if worst["cc"] >= 20 or nesting >= 6
        else "SPLIT_FILE"
        if len(functions) >= 10
        else "EXTRACT_METHODS"
    )
    return dict(
        family=key,
        files=members,
        family_evidence=group["evidence"],
        n_files=len(members),
        sum=sigma,
        decisions=sigma - len(functions),
        n=len(functions),
        max=worst["cc"],
        max_fn=worst["name"],
        max_file=worst["file"],
        max_fn_lines=worst["lines"],
        nest=nesting,
        functions=functions,
        loc=loc,
        fix=fix,
        feat=sum(c["kind"] == "feat" for c in commits),
        ref=sum(c["kind"] == "refactor" for c in commits),
        unknown_churn=sum(c["kind"] == "unknown" for c in commits),
        k=k,
        r=1.0,
        history="unavailable",
        fan_in=len(importers),
        importers=importers,
        test_files=test_paths,
        test_loc_ratio=round(test_loc / loc, 2) if loc else None,
        coverage=None,
        fresh=bool(fresh and inputs["cutoff"] - fresh < inputs["fresh_days"] * 86400),
        fresh_at=fresh or None,
        availability=availability,
        busy_paths=busy_paths,
        reservation_hints=hints,
        rtype=rtype,
        score=round(sigma * math.sqrt(fix + 1) * k, 6),
        status="OBSERVE",
        excluded=None,
    )


def rank(groups: list[dict], inputs: dict) -> tuple[list[dict], list[dict], int]:
    rows = [candidate(g, inputs) for g in groups if any(in_scope(p, inputs["scope"]) for p in g["files"])]
    identities = Counter(row["family"] for row in rows)
    for row in rows:
        if identities[row["family"]] > 1:
            row["family"] = min(row["files"], key=lambda p: (len(p), p))
    sums = sorted(r["sum"] for r in rows)
    floor = inputs["min_cc"]
    if floor is None:
        floor = sums[min(len(sums) - 1, int(0.8 * len(sums)))] if sums else 0
    for row in rows:
        if set(row["files"]).intersection(inputs["cfg"].get("exclude_paths", [])):
            row["excluded"] = "user"
        elif row["busy_paths"]:
            row["excluded"] = "busy:diff"
        elif row["sum"] < floor:
            row["excluded"] = "below-floor"
        row["status"] = (
            "BUSY"
            if row["availability"] == "BUSY"
            else "EXCLUDED"
            if row["excluded"] == "user"
            else "OBSERVE"
        )
    ranked = sorted((r for r in rows if not r["excluded"]), key=lambda r: (-r["score"], r["family"]))
    for number, row in enumerate(ranked, 1):
        row.update(rank=number, score_norm=round(row["score"] / (ranked[0]["score"] or 1), 2))
    return ranked, [r for r in rows if r["excluded"]], floor
