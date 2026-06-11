# Scanner Invocation Protocol (exit-code trap)

> Canonical rule for invoking security/SCA/lint scanners from any skill. Loaded by
> pentest, security-audit, dependency-audit, ci-audit. Closes the recurring
> "exit-code trap" bug (bit pentest Task 10 + security-audit Task 11).

## The trap

**A security scanner exits NON-ZERO precisely WHEN IT FINDS ISSUES — that is a SUCCESSFUL
scan, not a tool failure.** Treating non-zero as failure does the worst possible thing: it
**hides real findings** behind a "DEGRADED / tool failed" message.

Affected tools (all exit non-zero on findings): `npm audit`, `pnpm audit`, `yarn npm audit`,
`pip-audit`, `osv-scanner`, `checkov`, `tfsec`, `trivy`, `dockle`, `gitleaks detect`, `semgrep`,
`bandit`, `safety`. The bug is the pattern `scanner ... || echo "DEGRADED: failed"` — on a repo
WITH vulnerabilities the scanner exits 1, the `||` fires, and the vulns are reported as a tool
failure instead of findings.

## The rule

**Key the degraded decision on whether the tool produced usable (valid-JSON) OUTPUT, never on its
exit code.** Capture stdout, validate it parses, and only call it DEGRADED when the output is
empty / non-JSON (genuine tool failure: not installed, crashed, no resolved dependency tree).

```bash
# run_scanner <cmd...> — prints JSON output on a real scan (vulns or none),
# returns 1 only on genuine failure (empty / unparseable output). Exit code of the
# tool itself is IGNORED (non-zero == found issues == success).
run_scanner() {
  OUT="$("$@" 2>/dev/null)"
  if [ -n "$OUT" ] && printf '%s' "$OUT" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
    printf '%s\n' "$OUT"; return 0          # valid output → SUCCESS (parse the findings)
  fi
  return 1                                  # empty / non-JSON → genuine failure → DEGRADED
}

# Correct usage — DEGRADED fires only on real failure, never on "found vulns":
run_scanner npm audit --json        || echo "DEGRADED: npm audit produced no output (need node_modules? npm ci)"
run_scanner osv-scanner --format json --lockfile "$LOCK" || echo "DEGRADED: osv-scanner produced no output for $LOCK"
run_scanner checkov -d . -o json    || echo "DEGRADED: checkov not installed / no IaC"
```

## Wrong vs right (the one-line diff that matters)

```bash
# WRONG — a repo with vulnerabilities reports them as a tool failure:
trivy fs --format json . 2>/dev/null || echo "DEGRADED: trivy failed"

# RIGHT — vulns are findings; DEGRADED only when no usable output:
run_scanner trivy fs --format json . || echo "DEGRADED: trivy not installed"
```

## Notes

- Some tools need a built/resolved tree (`npm audit` needs `node_modules`; `pip-audit` without `-r`
  audits the installed env). A lockfile/dependency preflight before invoking is the right place to
  detect "no resolved tree" — that IS a real DEGRADED, distinct from the exit-code trap.
- Degraded scanner output reduces **class/breadth coverage** (advisory), never the structural
  surface-enumeration gate (see the IC-2/IC-5 split where the consuming skill defines coverage gates).
