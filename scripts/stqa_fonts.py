#!/usr/bin/env python3
"""Which font every delivered workbook is written in — and the proof it renders the target script.

    stqa.sh fonts --list                 what each script resolves to on this machine
    stqa.sh fonts el "Πού κατοικείτε;"   resolve one script + text, print the evidence

Why this file exists. Excel applies ONE font per cell and does not fall back the way a browser
does: a cell in Calibri holding Thai, Khmer or kana renders as boxes for the reader, and a cell
in a Latin-only font holding CJK picks whatever face the reader's Excel substitutes — often a
mismatched size or the wrong regional glyph variants. The deliverable is read by a client who
does not speak the target language, so a tofu box is indistinguishable from a translation error.

Policy, in order:

1. Per script, a curated candidate list. First entry = the font that ships with Office on both
   Windows and macOS and covers that script, so the READER has it. That is the only machine whose
   fonts matter.
2. Local font files are used only to DISPROVE a candidate, never to reorder the list. If the first
   candidate is installed here and misses a codepoint we are about to write, drop to the next; if
   it is not installed here, keep it and say the choice is unverified. Picking a locally installed
   face over the curated one would optimise for this Mac and hand the reader a font they lack.
3. If every candidate that IS installed here has gaps, `resolve` raises. A workbook is not
   delivered in a font proven to show boxes; pass `font=` to overrule with a house font.

No third-party dependency: the sfnt tables (`name`, `cmap`) are parsed here with `struct`.
"""
import bisect
import os
import struct
import sys


class ContractError(AssertionError):
    """A delivery-contract breach: a workbook that must not be saved.

    It subclasses AssertionError so every existing `except AssertionError` (the selfcheck
    harness, and any caller written against the old behaviour) keeps working — while
    `require()` below RAISES it instead of asserting. The whole contract used to be bare
    `assert`s, which `python -O` / PYTHONOPTIMIZE=1 removes: the font proof, the column
    contract and the adversarial-verdict checks all silently vanished under an optimized
    interpreter, and a workbook with tofu boxes or a placeholder value would have saved
    exactly like a correct one. The guarantee has to survive the interpreter flag.
    """


def require(cond, msg):
    """`assert cond, msg` that -O cannot strip."""
    if not cond:
        raise ContractError(msg)

# ── candidates per script key of qa_checks.SCRIPTS ───────────────────────────────────────────
# First = ships with Office on Windows AND macOS and covers the script. Later = OS fallbacks.
FONTS = {
    "latin": ("Arial", "Calibri", "Helvetica", "DejaVu Sans"),
    "el":    ("Arial", "Calibri", "DejaVu Sans"),
    "cyr":   ("Arial", "Calibri", "DejaVu Sans"),
    "he":    ("Arial", "Tahoma", "Times New Roman", "DejaVu Sans"),
    "ar":    ("Arial", "Tahoma", "Arial Unicode MS", "Geeza Pro"),
    "hy":    ("Sylfaen", "Arial Unicode MS", "Noto Sans Armenian", "DejaVu Sans"),
    "ka":    ("Sylfaen", "Arial Unicode MS", "Noto Sans Georgian", "DejaVu Sans"),
    "th":    ("Tahoma", "Leelawadee UI", "Arial Unicode MS", "Thonburi", "Noto Sans Thai"),
    "ja":    ("Yu Gothic", "MS PGothic", "Hiragino Sans", "Arial Unicode MS", "Noto Sans JP"),
    "ko":    ("Malgun Gothic", "Apple SD Gothic Neo", "Arial Unicode MS", "Noto Sans KR"),
    "zh":    ("Microsoft YaHei", "PingFang SC", "SimSun", "Arial Unicode MS", "Noto Sans SC"),
}
SIZE = 10
SIZES = {"ja": 11, "ko": 11, "zh": 11, "th": 11}      # these scripts are unreadable at 10 pt
FONT_DIRS = (
    "/Applications/Microsoft Excel.app/Contents/Resources/DFonts",   # what the reader's Excel ships
    "/System/Library/Fonts", "/System/Library/Fonts/Supplemental", "/Library/Fonts",
    "~/Library/Fonts", "/usr/share/fonts", "/usr/local/share/fonts", "~/.fonts",
    "~/.local/share/fonts", "C:/Windows/Fonts",
)
EXT = (".ttf", ".otf", ".ttc", ".otc", ".TTF", ".OTF", ".TTC")
# Codepoints no font needs a glyph for: renderers substitute or render nothing.
IGNORE = {0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x00A0, 0x00AD, 0x200B, 0x200C, 0x200D,
          0x2028, 0x2029, 0x2060, 0xFEFF,
          # Bidi controls. Arabic and Hebrew text carries these routinely and no font needs a
          # glyph for them; without this a correct RTL workbook was reported as uncoverable and
          # the font search walked past a font that renders the script perfectly well.
          0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
          0x2066, 0x2067, 0x2068, 0x2069}


class Coverage:
    """Codepoints a font file maps to a real glyph, as sorted ranges."""

    def __init__(self, ranges, path):
        self.path = path
        self._starts, self._ends = [], []
        for a, b in sorted(ranges):
            if self._ends and a <= self._ends[-1] + 1:
                self._ends[-1] = max(self._ends[-1], b)
            else:
                self._starts.append(a); self._ends.append(b)

    def __contains__(self, cp):
        i = bisect.bisect_right(self._starts, cp) - 1
        return i >= 0 and cp <= self._ends[i]

    def gaps(self, text):
        """Codepoints of `text` this font cannot render, in first-seen order."""
        out = []
        for ch in text:
            cp = ord(ch)
            if cp in IGNORE or cp in self or cp in out: continue
            out.append(cp)
        return out


# ── sfnt parsing ─────────────────────────────────────────────────────────────────────────────
def _fonts_in(fh):
    """Table directories in one file: a plain sfnt has one, a TrueType collection several."""
    fh.seek(0)
    if fh.read(4) == b"ttcf":
        fh.seek(8); n = struct.unpack(">I", fh.read(4))[0]
        offsets = struct.unpack(f">{n}I", fh.read(4 * n))
    else:
        offsets = (0,)
    out = []
    for off in offsets:
        fh.seek(off + 4)
        num = struct.unpack(">H", fh.read(2))[0]
        fh.seek(off + 12)
        tabs = {}
        for _ in range(num):
            tag, _cks, toff, tlen = struct.unpack(">4sIII", fh.read(16))
            tabs[tag.decode("latin-1").strip()] = (toff, tlen)
        out.append(tabs)
    return out


def _families(fh, tabs):
    """(lowercase family names from name IDs 1/16, subfamily from name ID 2)."""
    if "name" not in tabs: return set(), ""
    off, _ = tabs["name"]
    fh.seek(off)
    fmt, count, str_off = struct.unpack(">HHH", fh.read(6))
    recs = [struct.unpack(">HHHHHH", fh.read(12)) for _ in range(count)]
    names, subfamily = set(), ""
    for plat, enc, _lang, nid, ln, noff in recs:
        if nid not in (1, 2, 16): continue
        fh.seek(off + str_off + noff)
        raw = fh.read(ln)
        try:
            wide = plat == 3 or (plat == 0 and enc != 0)
            txt = raw.decode("utf-16-be") if wide else raw.decode("mac-roman")
        except (UnicodeDecodeError, LookupError):
            continue
        if not txt.strip(): continue
        if nid == 2: subfamily = subfamily or txt.strip().lower()
        else: names.add(txt.strip().lower())
    return names, subfamily


def _cmap(fh, tabs):
    """Coverage ranges from the best available cmap subtable."""
    if "cmap" not in tabs: return []
    base, _ = tabs["cmap"]
    fh.seek(base)
    _ver, n = struct.unpack(">HH", fh.read(4))
    subs = [struct.unpack(">HHI", fh.read(8)) for _ in range(n)]
    PREF = {(3, 10): 0, (0, 4): 1, (0, 6): 1, (3, 1): 2, (0, 3): 3}      # format 12 first, then BMP
    ranked = sorted(subs, key=lambda s: PREF.get((s[0], s[1]), 9))
    ranges = []
    for _plat, _enc, off in ranked:
        fh.seek(base + off)
        fmt = struct.unpack(">H", fh.read(2))[0]
        if fmt == 4:
            _ln, _lang, segx2 = struct.unpack(">HHH", fh.read(6))
            seg = segx2 // 2
            fh.read(6)
            ends = struct.unpack(f">{seg}H", fh.read(segx2))
            fh.read(2)
            starts = struct.unpack(f">{seg}H", fh.read(segx2))
            deltas = struct.unpack(f">{seg}h", fh.read(segx2))
            ros = struct.unpack(f">{seg}H", fh.read(segx2))
            glyph_area = fh.read(max(0, _ln - (fh.tell() - (base + off))))
            for i in range(seg):
                a, b = starts[i], ends[i]
                if a == 0xFFFF: continue
                if ros[i] == 0:
                    lo = None
                    for cp in range(a, b + 1):
                        gid = (cp + deltas[i]) & 0xFFFF
                        if gid and lo is None: lo = cp
                        elif not gid and lo is not None: ranges.append((lo, cp - 1)); lo = None
                    if lo is not None: ranges.append((lo, b))
                else:
                    # spec: glyphIdArray[i*2 + idRangeOffset[i] + 2*(cp-start) - segCount*2]
                    lo = None
                    for cp in range(a, b + 1):
                        idx = i * 2 + ros[i] + (cp - a) * 2 - segx2
                        gid = 0
                        if 0 <= idx + 1 < len(glyph_area):
                            gid = struct.unpack(">H", glyph_area[idx:idx + 2])[0]
                        if gid and lo is None: lo = cp
                        elif not gid and lo is not None: ranges.append((lo, cp - 1)); lo = None
                    if lo is not None: ranges.append((lo, b))
            if ranges: return ranges
        elif fmt == 12:
            fh.read(10)
            ngroups = struct.unpack(">I", fh.read(4))[0]
            for _ in range(ngroups):
                a, b, gid = struct.unpack(">III", fh.read(12))
                if gid: ranges.append((a, b))
            if ranges: return ranges
        elif fmt == 6:
            _ln, _lang, first, cnt = struct.unpack(">HHHH", fh.read(8))
            gids = struct.unpack(f">{cnt}H", fh.read(cnt * 2))
            ranges += [(first + i, first + i) for i, g in enumerate(gids) if g]
            if ranges: return ranges
    return ranges


_INDEX = None       # lowercase family name -> file path


def index(rescan=False):
    """Family name -> font file for every font installed on this machine (name tables only)."""
    global _INDEX
    if _INDEX is not None and not rescan: return _INDEX
    _INDEX = {}
    for d in FONT_DIRS:
        d = os.path.expanduser(d)
        if not os.path.isdir(d): continue
        for root, _dirs, files in os.walk(d):
            for fn in files:
                if not fn.endswith(EXT): continue
                p = os.path.join(root, fn)
                try:
                    with open(p, "rb") as fh:
                        for tabs in _fonts_in(fh):
                            fams, sub = _families(fh, tabs)
                            regular = sub in ("", "regular", "book", "light")
                            for fam in fams:
                                # a Regular face wins over the bold/italic file of the same family:
                                # same cmap, but the path is the evidence printed to the human
                                if regular or fam not in _INDEX: _INDEX[fam] = p
                except (OSError, struct.error, ValueError):
                    continue
    return _INDEX


_COV = {}


def coverage(family):
    """Coverage of an installed family, or None when this machine does not have it."""
    key = family.lower()
    if key in _COV: return _COV[key]
    path = index().get(key)
    cov = None
    if path:
        try:
            with open(path, "rb") as fh:
                for tabs in _fonts_in(fh):
                    if key in _families(fh, tabs)[0]:
                        cov = Coverage(_cmap(fh, tabs), path); break
        except (OSError, struct.error, ValueError):
            cov = None
    _COV[key] = cov
    return cov


class FontError(RuntimeError):
    """Every candidate installed here is proven to miss glyphs the workbook needs."""


def resolve(script="latin", texts=(), font=None, size=None):
    """(name, size, note) for a deliverable in `script` containing `texts`.

    `font` overrules the table (house font); the note still reports any gap found locally.
    Raises FontError when every locally installed candidate misses a needed codepoint.
    """
    text = "".join(t for t in texts if t)
    pt = size or SIZES.get(script, SIZE)
    if font:
        cov = coverage(font)
        if cov is None: return font, pt, f"{font} {pt}pt — forced, not installed here (unverified)"
        gaps = cov.gaps(text)
        note = (f"{font} {pt}pt — forced; MISSING {_fmt(gaps)}" if gaps
                else f"{font} {pt}pt — forced, covers the text")
        return font, pt, note
    # An unknown script key used to fall through to the Latin candidates, which then "covered"
    # the text only because nothing non-Latin was checked — a silent wrong answer where the
    # caller asked about a script this module does not know.
    if script not in FONTS:
        raise FontError(f"unknown script key {script!r} — known keys: {', '.join(sorted(FONTS))}")
    tried = []
    for cand in FONTS[script]:
        cov = coverage(cand)
        if cov is None:
            why = f"; rejected here: {', '.join(tried)}" if tried else ""
            return cand, pt, f"{cand} {pt}pt — ships with Office, not installed here so unverified{why}"
        gaps = cov.gaps(text)
        if not gaps:
            why = f"; rejected: {', '.join(tried)}" if tried else ""
            how = "installed here, no text to check" if not text else f"verified against {cov.path}"
            return cand, pt, f"{cand} {pt}pt — {how}{why}"
        tried.append(f"{cand} misses {_fmt(gaps)}")
    raise FontError(f"no font for script {script!r} renders this workbook: {'; '.join(tried)}. "
                    f"Install one of {', '.join(FONTS.get(script, ()))} or pass font=<house font>.")


def _fmt(gaps, n=6):
    out = ", ".join(f"U+{cp:04X} {chr(cp)!r}" for cp in gaps[:n])
    return out + (f" (+{len(gaps) - n} more)" if len(gaps) > n else "")


def set_default(wb, name, size):
    """Make `name` the workbook's Normal style, so a cell nobody styled — and a row the reader
    adds later — is not silently Calibri."""
    from openpyxl.styles import Font
    try:
        wb._named_styles["Normal"].font = Font(name=name, size=size)
    except (KeyError, TypeError, AttributeError):
        for st in getattr(wb, "_named_styles", []):
            if getattr(st, "name", "") == "Normal": st.font = Font(name=name, size=size)


def assert_workbook(wb, name, size=None):
    """Refuse to save a deliverable with a cell in another font. Cheap, and it is the check that
    survives a future edit to the styling code: a new column that forgets the font dies here."""
    bad = []
    for ws in wb.worksheets:
        for row in ws.iter_rows():
            for c in row:
                if c.value is None and (c.font is None or c.font.name is None): continue
                if c.font is None or c.font.name != name:
                    bad.append(f"{ws.title}!{c.coordinate}={getattr(c.font, 'name', None)!r}")
                elif size and c.font.size not in (None, size):
                    bad.append(f"{ws.title}!{c.coordinate} size={c.font.size}")
    require(not bad, f"cells not in {name} {size or ''}pt: {bad[:8]}{' …' if len(bad) > 8 else ''}")
    normal = None
    for st in getattr(wb, "_named_styles", []):
        if getattr(st, "name", "") == "Normal": normal = st
    # `require()` is a call, so its message is built BEFORE the condition is judged — unlike
    # `assert`, which only builds it on failure. A message that dereferences the very thing the
    # condition guards against therefore crashes on the PASSING path: this one raised
    # AttributeError on every workbook with no Normal style. Guard the dereference explicitly.
    if normal is not None:
        require(normal.font.name == name,
                f"workbook default style is {normal.font.name!r}, not {name!r} — unstyled cells would render in it")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"): print(__doc__); return 0
    if argv[0] == "--list":
        print(f"{'script':7} {'font':22} note")
        for sc in FONTS:
            try:
                n, pt, note = resolve(sc)
                print(f"{sc:7} {n + ' ' + str(pt) + 'pt':22} {note.split(' — ', 1)[1]}")
            except FontError as e:
                print(f"{sc:7} {'—':22} {e}")
        return 0
    script, text = argv[0], (argv[1] if len(argv) > 1 else "")
    try:
        n, pt, note = resolve(script, [text])
        print(note)
        cov = coverage(n)
        if cov and text: print(f"gaps: {_fmt(cov.gaps(text)) or 'none'}")
        return 0
    except FontError as e:
        print(e, file=sys.stderr); return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
