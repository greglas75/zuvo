## seo-audit, a11y-audit: critical gates that default (static) mode can decide

- seo-audit: CG3 (HTTPS) is decided from source in the default mode: PASS on deploy/host config that enforces
  HTTPS, FAIL on an `http://` production site/canonical/base URL, otherwise `INSUFFICIENT DATA`. The agent's
  "no hardcoded `http://`" PASS criterion (which the skill itself forbade) is gone.
- seo-audit: the page profile now decides which critical gates apply (`seo-page-profile-registry.md`
  "Gate applicability"): an exempt gate is `N/A`, not FAIL. `app-shell` exempts CG1/2/4/5/6, `docs` exempts
  CG5 when no JSON-LD exists. Phase 0 resolves the profile when `--profile` is absent.
- a11y-audit: the A2/A4 gates are decided by evidence, not by a score threshold. Static analysis may FAIL on a
  proven violation (keyboard trap, positive `tabindex`, `outline: none` with no replacement, click-only
  element, a literal low-contrast colour pair); PASS needs live evidence (axe / keyboard audit); otherwise
  `CANNOT DETERMINE`, which is a coverage-gate FAIL (audit-postamble §1 row 3, `INCOMPLETE`). A proven keyboard
  trap is CRITICAL.
- a11y-audit: WCAG 2.2 table fixes: 2.5.8 is AA at 24x24 px (44x44 is AAA 2.5.5), 2.3.3 marked AAA, the `px`
  font-size check no longer claims 1.4.4, 2.4.11 / 2.5.7 / 3.2.6 / 3.3.7 / 3.3.8 added, level lists corrected.
- a11y-audit eval 2: A2/A4 are PASS only with live evidence.
