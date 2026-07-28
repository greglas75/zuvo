#!/usr/bin/env python3
"""Expand shared/includes/gate-registry.md into the GENERATED regions of its consumers.

The gate definitions used to live in 4-6 hand-maintained copies each. They drifted: CQ14 lost
three of its four clauses in the audit prompt, CQ28 was inverted in 7 places, four Q gates carried
the wrong labels, and adding one gate meant ~30 edits across 27 files (which is why CQ29 shipped
with six places still saying 28).

This makes the registry the only place a gate is defined. Every consumer carries a region:

    <!-- GATES:BEGIN kind=cq-table -->
    ...generated, do not edit by hand...
    <!-- GATES:END kind=cq-table -->

Self-containment is preserved on purpose: the text is INLINED into each skill, so a sub-agent
still reads exactly one file. This is a build-time source, not a runtime indirection.

Usage:
  python3 scripts/gen-gate-copies.py            # check only; exit 1 if any region is stale
  python3 scripts/gen-gate-copies.py --write    # rewrite stale regions in place
  python3 scripts/gen-gate-copies.py --list     # show the regions found and their kinds
"""
import os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGISTRY = os.path.join(ROOT, "shared/includes/gate-registry.md")
# Accept kind=x, kind="x" and kind='x' — a quoted attribute that silently failed to match would
# leave the region unrecognised, i.e. unverified, which is worse than a hard error.
BEGIN = re.compile(r'<!--\s*GATES:BEGIN\s+kind=["\']?([a-z0-9-]+)["\']?\s*-->')
END = re.compile(r'<!--\s*GATES:END\s+kind=["\']?([a-z0-9-]+)["\']?\s*-->')


def split_cells(row):
    r"""Split a markdown table row on unescaped pipes that are NOT inside a `code span`.

    A naive row.split("|") corrupts any gate whose text contains a pipe — `a \| b`, a union type,
    or a shell example. No gate needs one today, which is exactly why it would be a silent
    landmine: the first gate that does would have its text truncated and its short form filled
    with the tail, with nothing to notice.
    """
    cells, buf, tick, i = [], [], False, 0
    while i < len(row):
        c = row[i]
        if c == "\\" and i + 1 < len(row) and row[i + 1] == "|":
            buf.append("|"); i += 2; continue          # escaped pipe -> literal
        if c == "`":
            tick = not tick
        if c == "|" and not tick:
            cells.append("".join(buf).strip()); buf = []; i += 1; continue
        buf.append(c); i += 1
    cells.append("".join(buf).strip())
    return cells


def parse_registry(path=REGISTRY, strict=True):
    """Return {'CQ': [...], 'Q': [...], 'CAP': [...], 'AP': [...]} of dicts, in ID order.

    strict=True raises on anything that would silently produce a WRONG generated region:
    a malformed row, a duplicate ID, or a gap in the numbering. Dropping such a row quietly is
    how a gate disappears from every consumer at once.
    """
    out = {"CQ": [], "Q": [], "CAP": [], "AP": []}
    problems, seen = [], set()
    # No errors="replace": a mojibaked registry must fail loudly, not propagate corruption
    # into six files.
    with open(path, encoding="utf-8") as fh:
        raw = fh.read()
    for lineno, line in enumerate(raw.split("\n"), 1):
        line = line.rstrip()
        m = re.match(r'^\s*\|\s*(CQ|CAP|AP|Q)(\d+)\s*\|(.*)\|\s*$', line)
        if not m:
            continue
        fam, num = m.group(1), int(m.group(2))
        key = (fam, num)
        if key in seen:
            problems.append(f"line {lineno}: duplicate {fam}{num} — a gate may be defined once")
            continue          # skip, so it does not also trip the contiguity check with a confusing message
        seen.add(key)
        cells = split_cells(m.group(3))
        expected = {"CQ": 5, "Q": 3, "CAP": 2, "AP": 1}[fam]   # CQ: domain, crit, scope, text, short
        if len(cells) != expected:
            # Too FEW means a column is missing. Too MANY means an unescaped '|' inside the text
            # split one cell into two — the silent-corruption case, where the gate's text is
            # truncated and its short form is filled with the tail. Both are hard errors.
            problems.append(
                f"line {lineno}: {fam}{num} has {len(cells)} cell(s), expected exactly {expected}"
                + (" — an unescaped '|' in the text must be written as '\\|' or wrapped in `backticks`"
                   if len(cells) > expected else " — a column is missing"))
            continue
        if fam == "CQ" and len(cells) >= 5:
            out["CQ"].append({"id": f"CQ{num}", "n": num, "domain": cells[0],
                              "crit": cells[1], "scope": cells[2], "text": cells[3], "short": cells[4]})
        elif fam == "Q" and len(cells) >= 3:
            out["Q"].append({"id": f"Q{num}", "n": num, "crit": cells[0],
                             "text": cells[1], "short": cells[2]})
        elif fam == "CAP" and len(cells) >= 2:
            out["CAP"].append({"id": f"CAP{num}", "n": num, "text": cells[0], "sev": cells[1]})
        elif fam == "AP" and len(cells) >= 1:
            out["AP"].append({"id": f"AP{num}", "n": num, "text": cells[0]})
    for k in out:
        out[k].sort(key=lambda g: g["n"])
        nums = [g["n"] for g in out[k]]
        if nums and nums != list(range(1, len(nums) + 1)):
            missing = sorted(set(range(1, max(nums) + 1)) - set(nums))
            problems.append(f"{k} numbering is not contiguous 1..{max(nums)} — missing {missing}")
    if problems and strict:
        raise SystemExit("gate-registry.md is malformed:\n  " + "\n  ".join(problems))
    return out


def esc(s):
    """Escape pipes when emitting INTO a markdown table, so a gate text containing '|'
    cannot break the generated table's column structure."""
    return re.sub(r'(?<!\\)\|', r'\\|', s)


def _crit_prefix(crit):
    if crit.startswith("critical"):
        return "**CRITICAL** — "
    if crit.startswith("conditional"):
        return "**CONDITIONAL** — "
    return ""


def _scope_suffix(scope):
    """Stack-scoped gates must SAY so, or an auditor cannot tell 'does not apply to this project'
    (out-of-scope, free) from 'applies but not here' (N/A, budgeted)."""
    if not scope or scope == "universal":
        return ""
    stacks = scope.split(":", 1)[1] if ":" in scope else scope
    return f" *(stack: {stacks} — `out-of-scope` on any other stack)*"


def _crit_short(crit):
    if crit.startswith("critical"):
        return "CRITICAL -- "
    if crit.startswith("conditional"):
        return "CONDITIONAL -- "
    return ""


# ---- renderers: kind -> lines ------------------------------------------------------------
def r_cq_table(g):
    out = ["| Gate | Domain | Check |", "|------|--------|-------|"]
    out += [f"| {x['id']} | {esc(x['domain'])} | {_crit_prefix(x['crit'])}{esc(x['text'])}"
            f"{_scope_suffix(x.get('scope', ''))} |" for x in g["CQ"]]
    return out


def r_q_table(g):
    out = ["| Gate | Check |", "|------|-------|"]
    out += [f"| {x['id']} | {_crit_prefix(x['crit'])}{esc(x['text'])} |" for x in g["Q"]]
    return out


def r_cq_prompt(g):
    w = max(len(x["id"]) for x in g["CQ"]) + 1
    return [f"{(x['id'] + ':').ljust(w)} {_crit_short(x['crit'])}{x['short']}"
            + (f"  [stack: {x['scope'].split(':', 1)[1]}]" if x.get("scope", "universal") != "universal" else "")
            for x in g["CQ"]]


def r_q_prompt(g):
    w = max(len(x["id"]) for x in g["Q"]) + 1
    return [f"{(x['id'] + ':').ljust(w)} {_crit_short(x['crit'])}{x['short']}" for x in g["Q"]]


def r_cap_list(g):
    return [f"{x['id']}: {x['text']} -- {x['sev']}" for x in g["CAP"]]


def r_ap_list(g):
    return [f"{x['id']}: {x['text']}" for x in g["AP"]]


def r_cq_critical(g):
    always = [x["id"] for x in g["CQ"] if x["crit"].startswith("critical")]
    cond = [x for x in g["CQ"] if x["crit"].startswith("conditional")]
    out = [f"**Always-on critical gates:** {', '.join(always)} — any scored 0 triggers an immediate FAIL.",
           "", "**Conditional critical gates** (critical only when the trigger holds):"]
    out += [f"- **{x['id']}** — critical when {x['crit'].split(':', 1)[1].strip()}" for x in cond]
    return out


def r_q_critical(g):
    crit = [x["id"] for x in g["Q"] if x["crit"].startswith("critical")]
    out = ["These gates are absolute pass/fail. Any critical gate at 0 = FAIL regardless of total score.", ""]
    out += [f"{x['id']:<4}— {x['text']}" for x in g["Q"] if x["crit"].startswith("critical")]
    out += ["", f"({len(crit)} critical gates: {', '.join(crit)})"]
    return out


def r_counts(g):
    return [f"CQ1-CQ{len(g['CQ'])} ({len(g['CQ'])} code-quality gates), "
            f"Q1-Q{len(g['Q'])} ({len(g['Q'])} test-quality gates), "
            f"CAP1-CAP{len(g['CAP'])} ({len(g['CAP'])} code anti-patterns), "
            f"AP1-AP{len(g['AP'])} ({len(g['AP'])} test anti-patterns)."]


RENDERERS = {
    "cq-table": r_cq_table, "q-table": r_q_table,
    "cq-prompt": r_cq_prompt, "q-prompt": r_q_prompt,
    "cap-list": r_cap_list, "ap-list": r_ap_list,
    "cq-critical": r_cq_critical, "q-critical": r_q_critical,
    "counts": r_counts,
}


def process(path, gates, write=False):
    """Return (n_regions, n_stale). Rewrites the file when write=True and something is stale."""
    try:
        src = open(path, errors="replace").read()
    except OSError:
        return (0, 0)
    lines = src.split("\n")
    out, i, n, stale = [], 0, 0, 0
    while i < len(lines):
        mb = BEGIN.search(lines[i])
        if not mb:
            out.append(lines[i]); i += 1; continue
        kind = mb.group(1)
        # find the matching END
        j = i + 1
        while j < len(lines):
            me = END.search(lines[j])
            if me:
                if me.group(1) != kind:
                    raise SystemExit(f"{path}: GATES:BEGIN kind={kind} closed by kind={me.group(1)}")
                break
            j += 1
        if j >= len(lines):
            raise SystemExit(f"{path}: unterminated GATES:BEGIN kind={kind}")
        if kind not in RENDERERS:
            raise SystemExit(f"{path}: unknown region kind '{kind}' (known: {', '.join(sorted(RENDERERS))})")
        n += 1
        current = lines[i + 1:j]
        fresh = RENDERERS[kind](gates)
        if current != fresh:
            stale += 1
        out.append(lines[i])
        out.extend(fresh if write else current)
        out.append(lines[j])
        i = j + 1
    if write and stale:
        open(path, "w").write("\n".join(out))
    return (n, stale)


def consumers():
    """Every tracked .md that carries at least one region."""
    found = []
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in (".git", "node_modules", "dist", "zuvo")]
        for f in files:
            if not f.endswith(".md"):
                continue
            p = os.path.join(base, f)
            if p == REGISTRY:
                continue
            try:
                if "GATES:BEGIN" in open(p, errors="replace").read():
                    found.append(p)
            except OSError:
                pass
    return sorted(found)


def main():
    write = "--write" in sys.argv
    gates = parse_registry()
    if not gates["CQ"]:
        print("gen-gate-copies: registry has no CQ rows — refusing to write empty regions", file=sys.stderr)
        return 2
    files = consumers()
    if "--list" in sys.argv:
        for p in files:
            src = open(p, errors="replace").read()
            print(f"  {os.path.relpath(p, ROOT)}: {', '.join(sorted(set(BEGIN.findall(src))))}")
        return 0
    total_r = total_s = 0
    for p in files:
        n, s = process(p, gates, write)
        total_r += n; total_s += s
        if s:
            print(f"  {'rewrote' if write else 'STALE  '} {os.path.relpath(p, ROOT)} ({s}/{n} region(s))")
    print(f"gen-gate-copies: {len(files)} file(s), {total_r} region(s), {total_s} stale"
          f"{' — rewritten' if (write and total_s) else ''}")
    print(f"  registry: CQ={len(gates['CQ'])} Q={len(gates['Q'])} CAP={len(gates['CAP'])} AP={len(gates['AP'])}")
    if total_s and not write:
        print("  run: python3 scripts/gen-gate-copies.py --write", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
