#!/usr/bin/env python3
"""evaluate-model.py <label> [reference-label]

Scores one candidate for an adversarial-review lane. The deciding number is NOT a head-to-head
against another model but MARGINAL COVERAGE over the rest of the set: a model that finds a lot,
but only what the others already find, adds nothing, because the set catches those anyway.

The scope is always ALL corpus packets. Counting only the packets where the model answered
flatters it for the ones it failed on (that inflated 3.8 Flash by 3 packets, 2026-09-05).

Reads $BENCH_HOME (default ~/.zuvo/bench): judge2/verdicts-<label>.tsv (judge.sh), the round-1
collective packet verdicts judge2/<id>/VERDICT_{OPUS,TOPUP}.tsv, and the raw answers in
or/raw/ and subs/ for the missed-review count.
"""
import csv
import glob
import os
import re
import sys

BENCH = os.path.expanduser(os.environ.get("BENCH_HOME", "~/.zuvo/bench"))
PKG = os.path.join(BENCH, "judge2")
OTHERS = {"cursor-agent", "codex-5.3", "gpt-5.4", "kimi", "z-ai/glm-5.3", "qwen/qwen3.8-flash"}
PACKET_SOURCES = ("VERDICT_OPUS.tsv", "VERDICT_TOPUP.tsv")

# The driver wraps every CLI-lane answer in a report header/footer. A wrapped "NO ISSUES FOUND."
# is ~490 bytes and does not START with the phrase, so testing the raw file counted it as a real
# review — sol/luna showed 0 empty answers instead of 4-9 of 20 (2026-10-05).
WRAPPER = re.compile(r"^(=+|CROSS-PROVIDER.*|Providers:.*|Mode:.*|Input size:.*|Date:.*|"
                     r"END OF CROSS-PROVIDER.*)\s*$")
NO_ISSUES = re.compile(r"^\s*NO ISSUES FOUND", re.I | re.M)
# A finding: a `SEVERITY:` line, or a line that LEADS with CRITICAL/WARNING (`**CRITICAL …`,
# `[WARNING]`, `- CRITICAL:`). Same rule as judge.sh — nemotron writes no SEVERITY header at all.
FINDING = re.compile(r"SEVERITY[*\s]*:|^[\s>*#_-]*\[?(?:CRITICAL|WARNING)\]?(?:[*\s:\u2014-]|$)", re.I | re.M)


def safe(label):
    return label.replace("/", "_")


def packet_ids():
    return sorted(d for d in os.listdir(PKG) if re.match(r"^\d{10}-\d+$", d)) if os.path.isdir(PKG) else []


def read_tsv(path):
    try:
        with open(path, newline="") as fh:
            return list(csv.reader(fh, delimiter="\t"))
    except OSError:
        return []


def from_packets(keep):
    """REAL (packet, defect_id), the FALSE_POSITIVE count and the packets with any verdict, from the
    round-1 collective packet verdicts (columns: model severity verdict speculative defect_id reason)."""
    real, fp, packets = set(), 0, set()
    for src in PACKET_SOURCES:
        for f in glob.glob(os.path.join(PKG, "*", src)):
            pid = os.path.basename(os.path.dirname(f))
            for r in read_tsv(f):
                if len(r) < 5 or r[0] == "model" or not keep(r[0]):
                    continue
                packets.add(pid)
                if r[2].strip() == "REAL" and r[4].strip() not in ("-", ""):
                    real.add((pid, r[4].strip()))
                elif r[2].strip() == "FALSE_POSITIVE":
                    fp += 1
    return real, fp, packets


def from_verdicts(label):
    """REAL set, FALSE_POSITIVE count and judged-packet count from judge.sh output."""
    real, fp, packets = set(), 0, set()
    for r in read_tsv(os.path.join(PKG, f"verdicts-{safe(label)}.tsv")):
        if len(r) < 5 or r[0] == "input":
            continue
        verdict, slug = r[3].strip(), r[4].strip()
        packets.add(r[0].strip())
        if verdict == "REAL" and slug not in ("-", ""):
            real.add((r[0].strip(), slug))
        elif verdict == "FALSE_POSITIVE":
            fp += 1
    return real, fp, len(packets)


def defects(label):
    real, fp, n = from_verdicts(label)
    if n:                                               # judge.sh output exists — it is the source
        return real, fp, n
    real, fp, packets = from_packets(lambda m: m == label)   # judged in round 1 only
    return real, fp, len(packets)


def answer_files(label):
    """This label's answer per packet: or/raw/<SAFE>-{ok,fail}-<id>.txt, else subs/<label>-<id>.out.
    Exact names only — `<label>-*` also matched neighbouring labels (aion-3.5 → aion-3.5-mini)."""
    out = []
    for pid in packet_ids():
        cands = [os.path.join(BENCH, "or", "raw", f"{safe(label)}-{g}-{pid}.txt") for g in ("ok", "fail")]
        cands.append(os.path.join(BENCH, "subs", f"{label}-{pid}.out"))
        hit = next((c for c in cands if os.path.exists(c)), None)
        if hit:
            out.append(hit)
    return out


def is_missed(text):
    """An empty answer, or an explicit "no issues" with no finding at all (driver wrapper removed)."""
    body = "\n".join(l for l in text.splitlines() if not WRAPPER.match(l.strip())).strip()
    if FINDING.search(body):
        return False
    return len(body) < 120 or bool(NO_ISSUES.search(body))


# MISSED REVIEWS. Measured 2026-09-09: every packet of this corpus has confirmed real defects
# (the poorest has 4), so "NO ISSUES FOUND" here is ALWAYS a false negative. Without this column a
# model that refuses to analyse looks BEST: zero findings, zero false positives, 100% precision.
def infra_failures(label):
    """Packets whose LAST OpenRouter row is an error that is not a timeout (429, 403 region, 5xx):
    the request never produced the model's answer, so it is not the model's miss."""
    latest = {}
    try:
        with open(os.path.join(BENCH, "or", "results.tsv"), errors="ignore") as fh:
            for line in fh:
                f = line.rstrip("\n").split("\t")
                if len(f) >= 8 and f[0] == label:
                    latest[f[2]] = f
    except OSError:
        return set()
    bad = set()
    for pid, f in latest.items():
        try:
            secs = float(f[7] or 0)
        except ValueError:
            secs = 0.0
        if f[4].startswith("err") and secs < 880:
            bad.add(pid)
    return bad


def missed_reviews(label):
    files = answer_files(label)
    if not files:
        return None
    infra = infra_failures(label)
    miss = skipped = 0
    for f in files:
        pid = re.sub(r"\.(txt|out)$", "", os.path.basename(f)).rsplit("-", 2)
        pid = "-".join(pid[-2:])
        if pid in infra:
            skipped += 1
            continue
        try:
            with open(f, errors="ignore") as fh:
                miss += is_missed(fh.read())
        except OSError:
            continue
    return miss, len(files) - skipped, skipped


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    label = argv[1]
    ref = argv[2] if len(argv) > 2 else None
    n_packets = len(packet_ids())
    # The reference set never contains the candidate: "kimi" judged again later was being
    # compared with its own round-1 verdicts and showed almost no marginal coverage.
    others, _, _ = from_packets(lambda m: m in OTHERS and m != label)
    cand, cand_fp, cand_inputs = defects(label)

    print(f"Kandydat: {label}")
    mr = missed_reviews(label)
    if mr and mr[1] == 0:
        print(f"  przegapione review  : — (wszystkie {mr[2]} odpowiedzi to błędy infrastruktury)")
    if mr and mr[1] > 0:
        c, tot, infra = mr
        if tot < 5:
            note = f"  (n={tot} — za malo, zeby cokolwiek wnioskowac)"
        elif c / tot > 0.30:
            note = "  <-- ODMAWIA ANALIZY"
        elif c:
            note = "  (kazde jedno to przegapiony defekt)"
        else:
            note = ""
        print(f"  przegapione review  : {c}/{tot} ({100 * c / tot:.0f}%){note}")
        if infra:
            print(f"  błędy infrastruktury: {infra} (nie liczone jako przegapione — powtórz je)")
    print(f"  wsadow z werdyktami : {cand_inputs}/{n_packets}")
    tot = len(cand) + cand_fp
    if tot:
        print(f"  REAL / FP           : {len(cand)} / {cand_fp}   precyzja {100 * len(cand) / tot:.0f}%")
    else:
        print("  brak werdyktow — czy judge.sh dla tej etykiety juz biegl?")
    print()
    print(f"Pozostali providerzy znajduja: {len(others)} defektow")
    print(f"  z tego kandydat dokłada NOWE: {len(cand - others)}   <-- realny wklad")
    print(f"  zestaw z kandydatem         : {len(others | cand)}")
    if ref:
        rd, _, _ = defects(ref)
        print(f"\nOdniesienie: {ref}")
        print(f"  nowe ponad reszte : {len(rd - others)}")
        print(f"  zestaw            : {len(others | rd)}")
        print(f"\nROZNICA zestawu ({label} - {ref}): {len(others | cand) - len(others | rd):+d}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
