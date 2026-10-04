"""THE COMMAND SURFACE of `backlog-groom.py`: the argument parser, and nothing that acts.

Split out because the CLI module reached the 400-line default of `rules/file-limits.md` and the suite's
FL1 refuses that number in as many words ("extract a sibling rather than carrying it"). The seam is the
honest one: this file says what the commands TAKE, the entry point says what they DO. Shaving comments
off the acting code to stay under a limit would have traded the rationale that makes it reviewable for
a number, which is the opposite of what the limit is for.

WHAT IS NOT HERE, and will not be: a flag that weakens a control. `dispatch` carried `--seeds N`, an
unbounded `type=int` whose value was also the shortfall gate's own expectation, so `--seeds 2` produced
a two-seed chunk, no shortfall and a reported pass. An escape an agent can type is not a control; the
floor now lives inside `build_seeds` where no caller reaches past it.

THE UNDERSCORE IN THE NAME IS LOAD-BEARING, as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. This module imports no
parser, so it is outside the H19c pin-guard family by the derivation's own predicate — it holds no
`iter_entries` call and must not grow one.
"""
import argparse
import os
from typing import Callable, Dict

import zuvo_backlog_agent as za
import zuvo_backlog_queue as zq

Handler = Callable[[argparse.Namespace], int]


def build_parser(doc: str) -> argparse.ArgumentParser:
    """The whole command surface. `doc` is the entry point's `__doc__`, so `--help` stays its own."""
    ap = argparse.ArgumentParser(prog="backlog-groom.py", description=doc,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan", help="mint ids, decide the deterministic classes, write the queue")
    p.add_argument("--repo", default=os.getcwd())
    p.add_argument("--dry-run", action="store_true",
                   help="check every invariant and print the plan, writing nothing at all")
    p.add_argument("--chunk-bytes", type=int, default=zq.CHUNK_CAP)
    p.add_argument("--fleet", action="store_true",
                   help="verify READ-ONLY from ~/.zuvo/backlog-local.jsonl into "
                        "~/.zuvo/backlog-verdicts/<host>-<repo>.jsonl; no checkout is touched")
    d = sub.add_parser("dispatch", help="hand one chunk to the verifier lane, seeds mixed in")
    d.add_argument("--repo", default=os.getcwd())
    d.add_argument("--chunk", type=int, default=0)
    d.add_argument("--queue", default="")
    d.add_argument("--dry-run", action="store_true")
    g = sub.add_parser("ingest", help="check a verifier response and append only if nothing refused")
    g.add_argument("--repo", default=os.getcwd())
    g.add_argument("--dispatch", required=True)
    g.add_argument("--response", required=True)
    g.add_argument("--answers", default="")
    g.add_argument("--chunk", type=int, default=0)
    g.add_argument("--lane", default=za.LANE)
    g.add_argument("--dry-run", action="store_true")
    y = sub.add_parser("apply", help="refuse unless every entry is verified, then apply dispositions")
    y.add_argument("--repo", default=os.getcwd())
    y.add_argument("--dry-run", action="store_true",
                   help="run every gate and the helper's own dry runs, writing nothing at all")
    y.add_argument("--fleet", action="store_true",
                   help="REJECTED, naming the per-repo command: there is no fleet grooming "
                        "(decision 13). The flag exists so that asking is answered")
    r = sub.add_parser("render", help="write the groomed working document under $ZUVO_DIR/reports")
    r.add_argument("--repo", default=os.getcwd())
    r.add_argument("--partial", action="store_true",
                   help="render a partially verified backlog: stamps the coverage ratio and OMITS "
                        "the ranking section (decision 11)")
    r.add_argument("--dry-run", action="store_true")
    v = sub.add_parser("coverage", help="print the non-blocking verdict-coverage count; silent when "
                                       "every entry already carries a current verdict")
    v.add_argument("--repo", default=os.getcwd())
    return ap


def dispatch_to(handlers: Dict[str, Handler], doc: str) -> int:
    """Parse and run. The handler table is the ENTRY POINT's, so this module imports no command."""
    a = build_parser(doc).parse_args()
    return handlers[a.cmd](a)
