"""scripts/zuvo-home/zuvo_backlog_admit.py — the admission bars, validation and fingerprint of
`backlog-add`, all pure. Every row is named after the defect it catches: a misroute (debt leaking into
the backlog, a real defect parked in the ledger), a refusal that should not happen or should, or an id
that splits one finding in two or merges two into one.
"""

import dataclasses
import os
import re
import sys
import unittest
from typing import Any, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "scripts", "zuvo-home"))
import zuvo_backlog_admit as adm  # noqa: E402
import zuvo_backlog_parse as zb  # noqa: E402

# The class vocabulary as the skills spell it, retyped here so a class dropped from the module fails.
ALL_CLASSES = ("BUG", "SEC", "DATA", "DUP", "CPLX", "SIZE", "PERF", "DEAD", "READ", "CQ",
               "TEST-GAP", "MUTATION", "PROCESS", "ADVISORY")
REPORT_ONLY = ("DUP", "CPLX", "SIZE", "PERF", "DEAD", "READ", "CQ", "TEST-GAP", "MUTATION", "PROCESS")
LOW_PREFIX = "(low confidence — verify manually) "
CHANGED = frozenset({42})
URL = "https://api.example.com/v1/orders"

BASE = adm.Finding(cls="BUG", conf=85, source="review", title="total is NaN when the cart is empty",
                   file="src/cart.ts", line=42, anchor="const total = sum(cart.items)")


def f(**over: Any) -> adm.Finding:
    return dataclasses.replace(BASE, **over)


def tgt(target: str, **over: Any) -> adm.Finding:
    """A finding that cites a target instead of a file."""
    return f(file=None, line=None, anchor=None, target=target, **over)


def gap(cls: str = "TEST-GAP", conf: int = 85, line: int = 42) -> adm.Finding:
    return f(cls=cls, conf=conf, line=line, anchor=None,
             missing_assertion="expect(total).toBe(0) for an empty cart")


def route(finding: adm.Finding, forced: bool = False) -> Tuple[str, str, str]:
    d = adm.decide(finding, CHANGED, forced)
    return (d.route, d.reason, d.cls)


class BarsTests(unittest.TestCase):
    ROWS = [(f"{c} at 25 written although below the floor", f(cls=c, conf=25),
             ("discarded", "below-floor", c)) for c in ALL_CLASSES] + [
        ("SEC at 26 dropped by an off-by-one on the floor", f(cls="SEC", conf=26),
         ("backlog", "admitted", "SEC")),
        ("BUG at 26 discarded instead of kept as data", f(conf=26), ("ledger", "conf-below-80", "BUG")),
        ("CPLX at 26 lost at the floor", f(cls="CPLX", conf=26), ("ledger", "class-report-only", "CPLX")),
        ("BUG at 79 admitted (`>` vs `>=` on the 80 bar)", f(conf=79), ("ledger", "conf-below-80", "BUG")),
        ("BUG at 80 parked in the ledger", f(conf=80), ("backlog", "admitted", "BUG")),
        ("DATA at 79 admitted (DATA bar off by one)", f(cls="DATA", conf=79),
         ("ledger", "conf-below-80", "DATA")),
        ("DATA at 80 parked (DATA not treated as a backlog class)", f(cls="DATA", conf=80),
         ("backlog", "admitted", "DATA")),
        ("SEC at 50 held to the BUG bar and parked", f(cls="SEC", conf=50), ("backlog", "admitted", "SEC")),
        ("ADVISORY at 95 leaks into the backlog", f(cls="ADVISORY", conf=95),
         ("ledger", "advisory", "ADVISORY")),
    ] + [(f"{c} at 95 leaks debt into the backlog", f(cls=c, conf=95),
          ("ledger", "class-report-only", c)) for c in REPORT_ONLY]

    def test_each_class_routes_by_its_bar(self):
        for name, finding, want in self.ROWS:
            with self.subTest(name):
                self.assertEqual(want, route(finding))

    def test_sec_below_51_is_prefixed_and_51_is_not(self):
        rows = [("SEC at 50 lands without the low-confidence warning", 50, LOW_PREFIX + BASE.title),
                ("SEC at 51 stamped low-confidence (off by one on SEC_LOW)", 51, BASE.title)]
        for name, conf, want in rows:
            with self.subTest(name):
                self.assertEqual(want, adm.decide(f(cls="SEC", conf=conf), CHANGED, False).title)


class TargetRoutingTests(unittest.TestCase):
    ROWS = [
        ("URL-target BUG with evidence parked because it has no anchor",
         tgt(URL, evidence="500 on GET with an empty body"), ("backlog", "admitted", "BUG")),
        ("subject:review-incomplete PROCESS filed as a ticket",
         tgt("subject:review-incomplete", cls="PROCESS"), ("ledger", "class-report-only", "PROCESS")),
        ("bare-host SEC from infra-audit parked", tgt("db.internal:5432", cls="SEC", evidence="port open"),
         ("backlog", "admitted", "SEC")),
    ]

    def test_target_findings_follow_the_normal_bars(self):
        for name, finding, want in self.ROWS:
            with self.subTest(name):
                self.assertEqual(want, route(finding))


class TargetKindTests(unittest.TestCase):
    ROWS = [
        ("None crashes `.strip()` instead of naming no shape", None, None),
        ("empty text read as a bare host", "", None),
        ("padding around a host refused (the shape is read after stripping)", " db.internal:5432 ", "host"),
        ("pipe in a URL (it matches the URL shape) accepted: opens a backlog column", URL + "/a|b", None),
        ("control character in a URL (it matches the URL shape) accepted", URL + "/a\x01b", None),
        ("URL whose host urlsplit cannot read named a url", "https://[::1/x", None),
        ("URL not recognised", URL, "url"),
        ("subject not recognised", "subject:review-incomplete", "subject"),
    ]

    def test_target_kind_names_the_one_shape_or_none(self):
        for name, target, want in self.ROWS:
            with self.subTest(name):
                self.assertEqual(want, adm.target_kind(target))


class PromotionAndPrecedenceTests(unittest.TestCase):
    ROWS = [
        ("forced BUG at 20 written: the env override lifted the floor", f(conf=20), True,
         ("discarded", "below-floor", "BUG")),
        ("forced CPLX at 60 left in the ledger: override ignored", f(cls="CPLX", conf=60), True,
         ("backlog", "forced", "CPLX")),
        ("forced finding with a bad conf written: override skipped validation", f(conf="85.0"), True,
         ("refused", "bad-conf", "")),
        ("refusal echoes the raw unvalidated class", f(cls="<script>"), False,
         ("refused", "unknown-class", "")),
        ("CLI text line `\"42\"` looked up as text, so a gap on a changed line is not promoted",
         dataclasses.replace(gap(), line="42"), False, ("backlog", "promoted", "BUG")),
        ("forced BUG at 90 marked forced although it passed its bar", f(conf=90), True,
         ("backlog", "admitted", "BUG")),
        ("TEST-GAP with a named assertion on a changed line at 85 not promoted", gap(), False,
         ("backlog", "promoted", "BUG")),
        ("TEST-GAP off the diff at 85 promoted (old gap filed as a defect)", gap(line=7), False,
         ("ledger", "mutation-not-on-changed-line", "TEST-GAP")),
        ("MUTATION on a changed line at 85 not promoted", gap(cls="MUTATION"), False,
         ("backlog", "promoted", "BUG")),
        ("MUTATION on a changed line at 70 promoted (promotion skips the 80 bar)",
         gap(cls="MUTATION", conf=70), False, ("ledger", "conf-below-80", "MUTATION")),
        ("TEST-GAP at 79 promoted (`>` vs `>=` on the promotion bar)", gap(conf=79), False,
         ("ledger", "conf-below-80", "TEST-GAP")),
        ("TEST-GAP at 80 parked (promotion bar off by one)", gap(conf=80), False,
         ("backlog", "promoted", "BUG")),
        ("TEST-GAP without a named assertion promoted on the changed line alone",
         f(cls="TEST-GAP", conf=95, anchor=None), False, ("ledger", "class-report-only", "TEST-GAP")),
        ("BUG with --missing-assertion accepted (meaningless combination)",
         f(missing_assertion="expect(x)"), False, ("refused", "bad-combination", "")),
        ("CQ at 95 filed as a ticket (gate debt in the backlog)", f(cls="CQ", conf=95), False,
         ("ledger", "class-report-only", "CQ")),
    ]

    def test_precedence_validation_then_floor_then_force_then_bars(self):
        for name, finding, forced, want in self.ROWS:
            with self.subTest(name):
                self.assertEqual(want, route(finding, forced))

    def test_forced_flag_marks_only_an_actual_override(self):
        # a record that bypassed the bars must be identifiable; one that passed them must not
        self.assertEqual((True, False), (adm.decide(f(cls="CPLX", conf=60), CHANGED, True).forced,
                                         adm.decide(f(conf=90), CHANGED, True).forced))

    def test_promoted_gap_carries_the_f_id_it_had_in_the_ledger(self):
        # re-fingerprinting a promoted gap as BUG (in `fingerprint` or in `b_id`) gives the backlog entry
        # a hash its own earlier ledger row does not carry, and the backlog <-> ledger link breaks
        parked, promoted = gap(conf=70), gap()
        decision = adm.decide(promoted, CHANGED, False)
        bid = adm.b_id(promoted, decision, adm.fingerprint(promoted))
        as_bug = adm.fingerprint(dataclasses.replace(promoted, cls="BUG"))
        self.assertEqual(("ledger", "BUG"), (adm.decide(parked, CHANGED, False).route, decision.cls))
        self.assertEqual(("F-998de96b35b3", "B-cart-BUG-998de96b"), (adm.fingerprint(parked), bid))
        self.assertNotEqual(as_bug, adm.fingerprint(parked))


SECRET_AKIA = "AKIA" + "ABCDEFGHIJKLMNOP"
SECRET_GHP = "ghp_" + "a1b2c3d4e5" * 4
SECRET_KEY = "-----BEGIN RSA " + "PRIVATE KEY-----"
SECRET_SLACK = "xoxb-" + "1234567890-abcdef"
SECRET_SK = "sk-" + "Ab12" * 6
# 35 chars ending in "-": a pattern closed by a word boundary would miss it
SECRET_GOOGLE = "AIza" + "Ab1_x" * 6 + "Ab1_-"
SECRET_STRIPE = "sk_live_" + "Ab12" * 4
SECRET_STRIPE_RK = "rk_live_" + "Ab12" * 4
SECRET_GH_PAT = "github_pat_" + "Ab1_" * 6
SECRET_GITLAB = "glpat-" + "Ab1_-" * 4
SECRET_SLACK_APP = "xoxa-" + "2"
SECRET_SK_LOWER = "sk-" + "ab12" * 6


class ValidationTests(unittest.TestCase):
    ROWS = [
        ("well-formed BUG refused (over-strict validation)", BASE, None),
        ("lowercase class accepted", f(cls="bug"), "unknown-class"),
        ("empty class accepted", f(cls=""), "missing-field:class"),
        ("absent conf reported as bad-conf instead of missing", f(conf=None), "missing-field:conf"),
        ("blank conf reported as bad-conf instead of missing", f(conf="  "), "missing-field:conf"),
        ("float-looking conf accepted", f(conf="85.0"), "bad-conf"),
        ("float conf read as 85", f(conf=85.0), "bad-conf"),
        ("negative conf accepted", f(conf=-1), "bad-conf"),
        ("conf above 100 accepted", f(conf=101), "bad-conf"),
        ("bool conf read as 1", f(conf=True), "bad-conf"),
        ("the CLI's string conf refused", f(conf="85"), None),
        ("drive-by source refused", f(source="drive-by:x"), None),
        ("`user` source refused", f(source="user"), None),
        ("capitalised source accepted", f(source="Drive-by:x"), "bad-source"),
        ("empty drive-by name accepted", f(source="drive-by:"), "bad-source"),
        ("blank source reported as bad-source instead of missing", f(source="  "), "missing-field:source"),
        ("blank title accepted", f(title="  "), "missing-field:title"),
        ("control-character title accepted (renders as an empty entry)", f(title="\x00\t\x07"),
         "missing-field:title"),
        ("file and target both reported as missing instead of mutually exclusive",
         f(target=URL, evidence="500 on GET"), "bad-combination"),
        ("neither file nor target accepted", f(file=None), "missing-field:file-or-target"),
        ("parent-dir path accepted", f(file="../x.ts"), "path-outside-repo"),
        ("absolute path reached the bars", f(file="/etc/passwd"), "path-outside-repo"),
        ("repo root `.` accepted as a file", f(file="."), "path-outside-repo"),
        ("file without a line accepted", f(line=None), "missing-field:line"),
        ("line 0 accepted", f(line=0), "line-out-of-range"),
        ("the CLI's string line refused", f(line="12"), None),
        ("blank line text reported as out of range instead of missing", f(line="  "), "missing-field:line"),
        ("non-numeric line crashed validate", f(line="abc"), "line-out-of-range"),
        ("float line crashed validate or was truncated", f(line=12.0), "line-out-of-range"),
        ("bool line read as line 1", f(line=True), "line-out-of-range"),
        ("Arabic-Indic digits read as line 12 (`\\d` is Unicode)", f(line="\u0661\u0662"),
         "line-out-of-range"),
        ("Arabic-Indic digits read as conf 85 (`\\d` is Unicode)", f(conf="\u0668\u0665"), "bad-conf"),
        ("int line past the 9-digit text cap accepted", f(line=10 ** 9), "line-out-of-range"),
        ("largest 9-digit int line refused (int cap off by one)", f(line=999_999_999), None),
        ("number as source crashed `.strip()`", f(source=5), "bad-field:source"),
        ("number as title crashed `.strip()`", f(title=7), "bad-field:title"),
        ("number as path crashed the path checks", f(file=3), "bad-field:file"),
        ("list as class crashed the set lookup", f(cls=["BUG"]), "bad-field:cls"),
        ("number as evidence crashed the secret scan", f(evidence=1), "bad-field:evidence"),
        ("number as target crashed the target checks", f(file=None, line=None, anchor=None, target=5),
         "bad-field:target"),
        ("number as anchor crashed the anchor length check", f(anchor=12), "bad-field:anchor"),
        ("list as fix crashed the secret scan", f(fix=["patch"]), "bad-field:fix"),
        ("number as severity crashed the secret scan", f(severity=3), "bad-field:severity"),
        ("number as missing assertion crashed the promotion check",
         dataclasses.replace(gap(), missing_assertion=0), "bad-field:missing_assertion"),
        ("a non-UTF-8 argv byte (a lone surrogate) passed validation and failed only at the ledger write",
         dataclasses.replace(gap(), missing_assertion="bad\udcffbyte"), "bad-field:missing_assertion"),
        ("a non-UTF-8 argv byte in the anchor passed validation", f(anchor="if total \udcff> limit:"),
         "bad-field:anchor"),
        ("leading space kept in the path", f(file=" src/cart.ts"), "bad-path"),
        ("trailing space kept in the path", f(file="src/cart.ts "), "bad-path"),
        ("pipe in the path splits the rendered line", f(file="src/a|b.ts"), "bad-path"),
        ("newline in the path splits the rendered line", f(file="src/a\nb.ts"), "bad-path"),
        ("U+2028 in the path splits the rendered line", f(file="src/a\u2028b.ts"), "bad-path"),
        ("BUG without an anchor accepted", f(anchor=None), "missing-field:anchor"),
        ("anchor too short to locate one line accepted", f(anchor="a = b;"), "missing-field:anchor"),
        ("report-only class forced to carry an anchor", f(cls="CPLX", anchor=None), None),
        ("URL BUG with evidence refused for lacking an anchor", tgt(URL, evidence="500 on GET"), None),
        ("URL BUG without evidence accepted", tgt(URL), "missing-field:evidence"),
        ("host SEC refused", tgt("db.internal:5432", cls="SEC", evidence="port open"), None),
        ("malformed target accepted", tgt("two words", evidence="x"), "bad-target"),
        ("URL with a port and no host accepted", tgt("https://:80/", evidence="e"), "bad-target"),
        ("URL host never held to the bare-host shape", tgt("https://foo\\bar.com/x", evidence="e"),
         "bad-target"),
        ("IPv6 URL refused by the hostname check", tgt("https://[::1]/x", evidence="e"), None),
        ("IPv4 host refused as a non-hostname", tgt("192.168.1.1:22", cls="SEC", evidence="e"), None),
        ("bare-host port past 65535 accepted", tgt("db.internal:99999", cls="SEC", evidence="e"),
         "bad-target"),
        ("bare-host port 65535 refused (port range off by one)",
         tgt("db.internal:65535", cls="SEC", evidence="e"), None),
        ("pipe in a URL target opens a column", tgt(URL + "/a|b", evidence="e"), "bad-target"),
        ("control character in a URL target stored", tgt(URL + "/a\x01b", evidence="e"), "bad-target"),
        ("unclosed IPv6 host accepted, then urlsplit raises in the stem", tgt("https://[::1/x", evidence="e"),
         "bad-target"),
        ("unreadable port accepted, then urlsplit raises", tgt("https://example.com:99999/x", evidence="e"),
         "bad-target"),
        ("credentials in a URL target stored", tgt("https://user:pw@api.example.com/x", evidence="e"),
         "secret-like-value"),
        ("credentials in a host target stored", tgt("admin:hunter2@db.internal", cls="SEC", evidence="e"),
         "secret-like-value"),
        ("`@` inside the password hides the URL credentials",
         tgt("https://user:p@ss@api.example.com/", evidence="e"), "secret-like-value"),
        ("subject BUG accepted", tgt("subject:x"), "bad-combination"),
        ("subject PROCESS refused", tgt("subject:review-incomplete", cls="PROCESS"), None),
        ("URL PROCESS accepted", tgt(URL, cls="PROCESS", evidence="x"), "bad-combination"),
        ("AWS key in the title stored", f(title="leaks " + SECRET_AKIA), "secret-like-value"),
        ("GitHub token in evidence stored", f(evidence="token " + SECRET_GHP), "secret-like-value"),
        ("private key in the fix stored", f(fix=SECRET_KEY), "secret-like-value"),
        ("Slack token in the anchor stored", f(anchor="const t = '" + SECRET_SLACK + "'"),
         "secret-like-value"),
        ("API key in the missing assertion stored",
         dataclasses.replace(gap(), missing_assertion="expect " + SECRET_SK), "secret-like-value"),
        ("Google API key stored", f(evidence="key=" + SECRET_GOOGLE), "secret-like-value"),
        ("Stripe secret key stored", f(fix="rotate " + SECRET_STRIPE), "secret-like-value"),
        ("Stripe restricted key stored", f(title="leaks " + SECRET_STRIPE_RK), "secret-like-value"),
        ("fine-grained GitHub token stored", f(evidence=SECRET_GH_PAT), "secret-like-value"),
        ("GitLab token stored", f(evidence="token " + SECRET_GITLAB), "secret-like-value"),
        ("Slack app token stored", f(title="uses " + SECRET_SLACK_APP), "secret-like-value"),
        ("AWS key in the path stored", f(file="src/" + SECRET_AKIA + ".ts"), "secret-like-value"),
        ("GitHub token in the severity stored", f(severity="high " + SECRET_GHP), "secret-like-value"),
        ("lowercase sk- key passes the source shape and is stored", f(source=SECRET_SK_LOWER),
         "secret-like-value"),
        ("`risk_live_` read as a Stripe key", f(title="risk_live_dashboard_settings_v2 is stale"), None),
        ("`risk-based` read as an sk- key", f(title="risk-based retry is wrong"), None),
        ("`task-runner` read as an sk- key", f(evidence="task-runner exits 0"), None),
        ("`desk-top` read as an sk- key", f(fix="rename desk-top layout"), None),
    ]

    def test_validate_names_the_refusal(self):
        for name, finding, want in self.ROWS:
            with self.subTest(name):
                self.assertEqual(want, adm.validate(finding))

    def test_parse_conf_reads_cli_text(self):
        rows = [("padded CLI text refused", " 85 ", 85), ("zero read as absent", "0", 0),
                ("plain int altered", 100, 100), ("float read as 85", 85.0, None)]
        for name, raw, want in rows:
            with self.subTest(name):
                self.assertEqual(want, adm.parse_conf(raw))


class ReasonVocabularyTests(unittest.TestCase):
    # A reason outside the closed sets would land in the ledger as a value no reader knows.
    ROUTED = [(name, finding, forced) for name, finding, forced, want in
              [(n, x, False, w) for n, x, w in BarsTests.ROWS + TargetRoutingTests.ROWS]
              + PromotionAndPrecedenceTests.ROWS if want[0] != "refused"]
    REFUSED = [(name, want) for name, _finding, want in ValidationTests.ROWS if want]

    def test_every_routing_reason_is_in_reasons(self):
        for name, finding, forced in self.ROUTED:
            with self.subTest(name):
                self.assertIn(adm.decide(finding, CHANGED, forced).reason, adm.REASONS)

    def test_every_refusal_is_in_refusals(self):
        for name, reason in self.REFUSED:
            with self.subTest(name):
                self.assertIn(reason.split(":", 1)[0], adm.REFUSALS)


class CleanTextTests(unittest.TestCase):
    ROWS = [
        ("newline splits the backlog line", "a\nb", 50, "a b"),
        ("CRLF leaves a carriage return", "a\r\nb", 50, "a b"),
        ("tab survives into the rendered field", "a\tb", 50, "a b"),
        ("NUL survives into the rendered field", "a\x00b", 50, "a b"),
        ("pipe splits a field", "Map<K> | <V>", 50, "Map<K> \\| <V>"),
        ("pre-escaped `\\|` left with a bare backslash (re-opens the column)", "a \\| b", 50, "a \\\\\\| b"),
        ("trailing backslash escapes the separator after the field", "C:\\dir\\", 50, "C:\\\\dir\\\\"),
        ("lone backslash escapes the separator after the field", "\\", 50, "\\\\"),
        ("U+2028 splits the backlog line", "a\u2028b", 50, "a b"),
        ("U+2029 splits the backlog line", "a\u2029b", 50, "a b"),
        ("NEL (U+0085) splits the backlog line", "a\u0085b", 50, "a b"),
        ("over-length text kept whole", "x" * 250, 200, "x" * 199 + "…"),
        ("cut inside an escape leaves a dangling backslash", "a" * 198 + "|b" * 5, 200, "a" * 198 + "\\|…"),
        ("None crashes the renderer", None, 10, ""),
    ]

    def test_clean_text_makes_one_safe_field(self):
        for name, raw, cap, want in self.ROWS:
            with self.subTest(name):
                self.assertEqual(want, adm.clean_text(raw, cap))

    SEPARATOR_ROWS = [
        ("`a\\|b`", "a\\|b"),
        ("trailing backslash", "path\\"),
        ("lone backslash", "\\"),
        ("backslash run ending in a pipe", "\\\\\\|"),
        ("cap lands inside a backslash run", "x\\" * 150),
        ("cap lands inside a pipe run", "|" * 300),
    ]

    def test_rendered_field_never_opens_a_column_or_escapes_the_separator(self):
        # an unescaped `|` splits the field; an odd trailing run of `\` escapes the ` | ` that follows
        for name, raw in self.SEPARATOR_ROWS:
            with self.subTest(name):
                out = adm.clean_text(raw, adm.TITLE_CAP)
                self.assertIsNone(re.search(r"(?:^|[^\\])(?:\\\\)*\|", out))
                self.assertIsNone(re.search(r"(?:^|[^\\])\\(?:\\\\)*$", out))

    def test_decision_title_is_cleaned(self):
        # a raw title with a newline would render as two backlog lines
        self.assertEqual("one two \\| three", adm.decide(f(title="one\ntwo | three"), CHANGED, False).title)


TITLED = f(cls="CPLX", anchor=None)


class FingerprintTests(unittest.TestCase):
    SAME = [
        ("`./src/a.ts` and `src/a.ts` split one finding", f(file="./src/cart.ts"), BASE),
        ("the line number moved the id", f(line=99), BASE),
        ("closure markers split the id once ticked", dataclasses.replace(
            TITLED, title=TITLED.title + " DONE PR #12 2026-10-01"), TITLED),
        ("a ticked Cyrillic title split (title words matched as ASCII only)",
         dataclasses.replace(TITLED, title="Пустая корзина падает DONE"),
         dataclasses.replace(TITLED, title="Пустая корзина падает")),
        ("two skills' paraphrases of one BUG split", f(title="cart total becomes NaN"), BASE),
        ("anchor whitespace/case split the id", f(anchor="  CONST total =  sum(cart.items) "), BASE),
        ("SEC low-confidence prefix hashed", tgt("subject:auth", cls="SEC", conf=30),
         tgt("subject:auth", cls="SEC", conf=70)),
        ("target trailing slash or case split the id", tgt("https://Example.com/x/", evidence="e"),
         tgt("https://example.com/x", evidence="e")),
    ]
    DIFFERENT = [
        ("same basename in two directories merged", f(file="lib/cart.ts"), BASE),
        ("two BUGs on one file merged", f(anchor="if (cart.items) return total"), BASE),
        ("class left out of the key", dataclasses.replace(TITLED, cls="DUP"), TITLED),
        ("Cyrillic title collapsed to `CLASS|path|`",
         dataclasses.replace(TITLED, title="Пустая корзина падает"),
         dataclasses.replace(TITLED, title="Сумма заказа неверна")),
        ("wordless title hashed as an empty string", dataclasses.replace(TITLED, title="!!!"),
         dataclasses.replace(TITLED, title="???")),
    ]

    def test_one_defect_one_id(self):
        for name, a, b in self.SAME:
            with self.subTest(name):
                self.assertEqual(adm.fingerprint(b), adm.fingerprint(a))

    def test_two_defects_two_ids(self):
        for name, a, b in self.DIFFERENT:
            with self.subTest(name):
                self.assertNotEqual(adm.fingerprint(b), adm.fingerprint(a))

    def test_f_id_shape(self):
        # a malformed F-id breaks the backlog ↔ ledger cross-link
        self.assertRegex(adm.fingerprint(BASE), r"^F-[0-9a-f]{12}$")


class BIdTests(unittest.TestCase):
    # Literal ids: the hash tail is the first 8 hex of the finding's F-id, pinned so a changed key or
    # a b_id hashing anything but `fp` (the ledger link) fails here rather than being re-derived.
    ROWS = [
        ("dotted file name cut at the first dot", f(file="src/index.test.ts"), "B-index.test-BUG-bdbb90e7"),
        ("dotfile stem emptied", f(file=".env"), "B-.env-BUG-82e6652b"),
        ("extensionless file name dropped", f(file="Makefile"), "B-Makefile-BUG-168dd26e"),
        ("non-ASCII stem kept or emptied", f(file="src/ü.ts"), "B-file-BUG-b41941d6"),
        ("URL target stemmed on its path instead of its host",
         tgt("https://Api.Example.com/x", evidence="e"), "B-api.example.com-BUG-19e1c4e6"),
        ("bare-host target stemmed with its port", tgt("db.internal:5432", cls="SEC", evidence="port open"),
         "B-db.internal-SEC-eb01df2f"),
        ("IPv6 URL target crashes the stem instead of reducing `::1` to `1`",
         tgt("https://[::1]/x", evidence="e"), "B-1-BUG-80957004"),
        ("subject target stemmed with its `subject:` prefix",
         tgt("subject:review-incomplete", cls="PROCESS"), "B-review-incomplete-PROCESS-0e8ef327"),
    ]

    def test_b_id_is_a_descriptive_definition_id(self):
        # an id the parser reads as ordinal or minted would key on content and duplicate forever
        for name, finding, want in self.ROWS:
            with self.subTest(name):
                bid = adm.b_id(finding, adm.decide(finding, CHANGED, False), adm.fingerprint(finding))
                self.assertEqual(want, bid)
                self.assertEqual(bid, zb.DEF_ID_RE.match("- [ ] " + bid + " src/x.ts:1").group(1))
                self.assertIsNone(zb.ORDINAL_ID_RE.match(bid))
                self.assertIsNone(zb.MINTED_ID_RE.match(bid + " x"))

    def test_b_id_refuses_a_value_that_is_not_an_f_id(self):
        # passing the B-id or a raw hash would mint an id the ledger cannot link back
        with self.assertRaisesRegex(ValueError, r"^b_id: 'B-cart-BUG-1234' is not an F-id \(F- \+ 12 hex\)$"):
            adm.b_id(BASE, adm.decide(BASE, CHANGED, False), "B-cart-BUG-1234")


if __name__ == "__main__":
    unittest.main()
