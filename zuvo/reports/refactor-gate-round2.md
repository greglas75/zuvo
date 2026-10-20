# Refactor gate round-two review

Branch: `fix/refactor-gate-version-independent-hook`. Starting HEAD: `beb23b11`.
Input: `zuvo/proofs/refactor-gate-hook-adversarial.txt`, read in full.
No pushes, history rewrites, or hook bypasses are authorized.

The receive-review workflow is applied. Required codesift-setup, run-logger,
retrospective, knowledge-prime, knowledge-curate and backlog-protocol includes
were loaded. CodeSift was explicitly indexed for this worktree; after its
single-file updater returned `skipped=true`, current source was checked directly.
The relevant knowledge entry was `gotcha-bash-source-0-fallback-cwd-20261006`.

## Original findings

IDs below are verbatim from the supplied review. Test names refer to
`tests/hooks/test-refactor-gate-review.sh`, unless the upgrade suite is named.

| Severity / ID | Disposition and concrete evidence |
| --- | --- |
| CRITICAL `install-refactor-gate.sh:369:private-wrapper-unrefreshable` | **Fixed.** `refreshable_hook(body, mode, origin)` now recognizes private digest wrappers and exact legacy chains; private publication uses it instead of accepting any matching header. The recognition test failed before the change. The upgrade suite refreshes both private modes to a changed template, migrates both legacy wrappers after deletion of their cache, preserves customized bodies, and invokes the surviving gate after another cache eviction. The original claim overstated the defect: ordinary private reinstalls already used `publish_private`, rather than the common-hook refresh branch. |
| WARNING `hooks.sh:32:global-gate-symlink-overwrite` | **Fixed.** The bulk copy and chmod exclude the global stable gate. Only a dedicated ownership-checked installer may replace it. `test_global_install_preserves_foreign_symlink_and_target` failed before the change and now protects both the link and its target. |
| WARNING `install-refactor-gate.sh:370:hook-refresh-check-replace-race` | **Fixed within the requested best-effort contract.** Identity is read through an fd opened without following symlinks, compared with metadata and a final pathname `lstat` immediately before replacement. The symlink-swap regression failed before the fix. No atomic compare-and-swap guarantee is claimed; the remaining final-check/rename window is documented. |
| WARNING `refactor-gate-dispatch.sh:37:metadata-path-exec-trust` | **Fixed.** Registry roots must resolve to a direct child of the zuvo cache, and the gate must resolve inside that install at its expected relative path. Both foreign-registry and escaped-gate tests returned foreign exit 97 before the fix. |
| WARNING `refactor-gate-dispatch.sh:45:dispatcher-recursion-marker-bypass` | **Fixed.** All lines are checked for an exact dedicated dispatcher header, with the original exact header retained for compatibility. The padded-dispatcher test timed out before the fix; it now falls through to a rejecting real gate. A separate regression protects real gates that quote the old marker in explanatory text. |
| WARNING `install-refactor-gate.sh:16:argless-invocation-indexerror` | **Rejected as a claim about the supplied revision.** The shell always passes `$0` as the Python argument before `pop(1)`; a no-argument public invocation already returned 2 with `absolute gate path is required`. The pre-fix farm run proves this. The initializer is additionally defensive against an absent internal script argument. |
| WARNING `install-refactor-gate.sh:393:refresh-replace-toctou` | **Fixed for the race, rejected for the alleged uncaught exception.** Same fd/path fix as the other race finding. The existing outer handler already catches `RuntimeError`, reports unavailable, and exits 2; it was present at `beb23b11`. |
| WARNING `hooks.sh:31:global-gate-clobber` | **Fixed.** Foreign regular files are skipped before copying or chmod. `test_global_install_preserves_foreign_file_and_permissions` failed before the fix; it asserts both original bytes and mode 0600. Exact released hashes, current source bytes, or a protected digest receipt identify managed files. |
| WARNING `install-refactor-gate.sh:304:symlink-home-misclassification` | **Rejected for the public installer path.** `main()` resolves the gate argument before calling `cached_gate`, while `cached_gate` resolves the cache root. Both operands are canonical there. The pre-fix symlinked-HOME/cache-eviction integration test already executes the replacement gate and returns 23. |
| WARNING `refactor-gate-dispatch.sh:59:fail-open-home-dependent-resolution` | **Fixed for the unhandled HOME error; policy change rejected.** `Path.home()` failure now warns and exits 0. The test returned 1/traceback before the fix. HOME intentionally selects the invoking user's installs; a user controlling their Git environment is outside this local guard's trust boundary. No concrete bypass of an available gate under the selected HOME was demonstrated. |
| WARNING `install-refactor-gate.sh:16:installer-dollar0-cwd-template-embedded` | **Fixed.** The gate release's sibling template is preferred. Installer-relative templates require an actual script path; bare shell names cannot make cwd authoritative. The stdin-install test executed the repository's malicious exit-97 template before the fix and now executes the installed gate. |
| WARNING `install-refactor-gate.sh:350:private-wrapper-legacy-not-migrated` | **Fixed/explicitly verified.** Exact legacy private commit and push bodies are recognized, including their original-hook chain and push stdin forwarding. The upgrade suite seeds both wrappers with the already removed 1.6.98 path and verifies migration. The earlier generic-header publication already allowed ordinary legacy private migration; it lacked exact ownership validation and this regression proof. |
| WARNING `install-refactor-gate.sh:325:dispatcher-template-downgrade-no-version-order` | **Rejected as a requested monotonic-version policy.** The activated release's template now takes precedence, including over a cwd or installer-sibling template (the stdin test pins precedence). Deliberately invoking an older installer/template remains a supported local rollback; monotonic revision checks would not constrain already installed old code that ignores them. The runbook states this limit and the continuing need to repair stale sync sources. |
| INFO `refactor-gate-upgrades.md:43:unreadable-metadata-fallback-claim` | **Rejected as a code defect; documented precisely.** Candidate inspection was already inside `except OSError` at the supplied revision. The injected `PermissionError` test passes before and after the fixes, preserving the next gate's exit 23. |
| INFO `refactor-gate-dispatch.sh:44:256-byte-marker-truncation` | **Fixed.** Same long-header recursion regression and exact-line scan as the WARNING above. |
| INFO `test-refactor-gate-upgrade.sh:114:vacuous-dispatch-active-env-test` | **Fixed.** Removed the unused variable test/unset; recursion is tested by executing a padded copied dispatcher and proving fallthrough to a real rejecting gate. |
| INFO `install-refactor-gate.sh:325:valueerror-dispatcher-missing-uncaught` | **Rejected for the supplied revision.** The outer handler already catches `ValueError`. The isolated installer/missing-template test passes on pre-fix code with exit 2, an unavailable message, and no traceback. |
| INFO `refactor-gate-upgrades.md:44:active-entry-claim-vs-all-records` | **Fixed.** The runbook now states registry file order, eligible registry-selected SHA paths, numeric-only cache ordering, and no scope/enabled/version selection. |

## Follow-up cross-model findings

The security review ran over two complete file-boundary chunks with Codex-5.3,
ZAI and Claude. Qwen was unavailable because of provider quota. Both chunks
completed without input truncation; provider availability is reported as partial.

| ID | Disposition and evidence |
| --- | --- |
| `install-refactor-gate.sh:442:untrusted-receipt-authorizes-overwrite` | **Fixed.** Receipts must be regular, owned by the invoking uid, and not writable by group/other. The writable-receipt test failed before the protection. |
| `refactor-gate-dispatch.sh:49:untrusted-install-path-execution` | **Rejected.** The user-owned installed plugin is trusted executable code. This resolver constrains candidate location and catches individual gate escapes; it does not authenticate plugin publishers or defend against a user deliberately replacing their own cache/registry. The runbook states that boundary. The foreign-registry and cache-symlink regressions pin the required constraints. |
| `install-refactor-gate.sh:441:uncaught-runtimeerror-traceback` | **Rejected.** The final CLI handler catches `RuntimeError` for all `main()` branches, including global installation. The handler is not inside the function because it is shared by every entry mode. |
| `refactor-gate-dispatch.sh:47:harness-symlink-containment-bypass` | **Rejected.** An individual gate link changes the resolved gate, not its parent root. `test_harness_file_symlink_cannot_escape_its_install` rejects a foreign exit-97 Codex gate and invokes the Cursor gate (23); it passed before the follow-up changes as well. |
| `refactor-gate-dispatch.sh:44:toctou-check-exec-symlink` | **Fixed within the same best-effort policy.** Compare the opened gate's metadata with a final `lstat` immediately before exec. Swapping the file after opening previously executed foreign exit 97; it now warns and invokes the next gate. The remaining final-check/exec window is documented. |
| `install-refactor-gate.sh:451:receipt-blesses-foreign-overwrite` | **Fixed for unsafe receipts; same-user forgery remains outside the trust boundary.** Owner/mode checks reject unsafe receipts, and every successful managed replacement prints its destination. A protected receipt matching unchanged managed bytes is the intended upgrade provenance; requiring approval on every receipt-based update would defeat automatic upgrades. |
| `refactor-gate-dispatch.sh:68:whole-file-marker-scan-failopen` | **Fixed.** Exact dedicated header lines replace substring matching. The quoted-marker regression returned fail-open 0 before the fix instead of executing the rejecting gate. |
| `refactor-gate-dispatch.sh:60:symlinked-gate-skipped-failopen` | **Rejected.** Skipping an individual gate symlink that escapes its install is the user's explicit requirement. An explicit `~/.zuvo/current` directory pointer supports source installs; the existing current-pointer test exercises it. |
| `install-refactor-gate.sh:441:receipt-written-after-hook-stale` | **Fixed.** Receipt validation/publication precedes hook replacement and records both the prior and next digest. The foreign-receipt regression showed a partial hook overwrite before this fix; it now preserves the hook. The shared outer exception handler returns 2. |
| `refactor-gate-dispatch.sh:31:registry-file-order-downgrade` | **Rejected as a policy change.** Explicit registry paths precede numeric fallback so an installed selection/rollback is honored; sorting all cache versions first could activate an unselected release. Registry ordering and stale-entry consequences are now documented. |

The final follow-up review again covered both complete file-boundary chunks with
the same three available models. Its remaining findings were handled as follows:

| ID | Disposition and evidence |
| --- | --- |
| `install-refactor-gate.sh:463:unvalidated-receipt-digest-authorization` | **Rejected.** Membership is compared to a real SHA-256 hex digest from `file_identity`, so malformed receipt lines cannot authorize a hook. A protected, uid-owned receipt is the local installer's provenance record. A user deliberately forging an otherwise valid receipt controls this trust domain already; this is documented rather than presented as authentication. |
| `refactor-gate-dispatch.sh:64:path-exec-race-after-check` | **Rejected as a demand to eliminate the documented residual race.** A final fd/path identity comparison now immediately precedes exec. `/proc/self/fd/N` is Linux-specific and changes the script's `$0` to an fd path, breaking `refactor-safety-gate.sh`'s sibling `lib/refactor-gate-lib.sh` resolution; Python's non-inheritable fd also closes on exec by default. Retain the portable best-effort policy explicitly authorized by the user. |
| `refactor-gate-dispatch.sh:85:path-execv-toctou` | **Rejected for the same documented limit.** The post-open swap regression now falls through to the next real gate. No atomic pathname execution claim is made. |
| `hooks.sh:21:cp-follows-foreign-symlinks` | **Fixed.** Other shell-hook copies skip symlink/non-regular destinations and chmod skips them too. The foreign `zuvo-plugin-enable-guard.sh` link/target/mode regression failed before the fix. |
| `install-refactor-gate.sh:455:receipt-toctou-trust` | **Fixed.** The stat record that passed the uid/mode check must match the fd-based identity snapshot (inode, size, mtime, ctime and mode). The test changes mode after the trust check but before the identity snapshot; it previously authorized an overwrite and now preserves the foreign hook. |
| `install-refactor-gate.sh:446:unguarded-oserror-traceback` | **Rejected.** `except (OSError, UnicodeError, ValueError, subprocess.SubprocessError, RuntimeError)` wraps all of `main()`, including the global installer. The suggested inner catch duplicates the existing outer handler. |
| `refactor-gate-dispatch.sh:81:lstat-fstat-symlink-gate-skipped-failopen` | **Rejected.** The premise is false: `gate.resolve().relative_to(resolved_root)` must equal the expected lexical relative path, so a `hooks/gate -> ../shared/gate` candidate is rejected before the fd check. Individual file links to other paths are intentionally excluded; explicit install-directory pointers remain supported. Both cache and harness escape regressions prove rejection. |
| `refactor-gate-dispatch.sh:75:exact-line-recursion-no-guard` | **Fixed for whitespace variants.** Header lines are normalized with `strip()` across the whole file. The long-header regression now also puts trailing spaces/tabs on both current and legacy headers; it timed out before normalization. Arbitrarily rewritten executable code is outside marker identity recognition. No environment flag can skip a real gate. |
| `install-refactor-gate.sh:405:private-digest-self-attested` | **Fixed documentation.** The runbook says this is a self-contained consistency check, not template authentication. Deliberately changing the embedded template and its digest retains managed ownership; ordinary checksum/chain-breaking edits are preserved. |

## Test evidence

- Initial pre-fix run `1792520146-90672-2822`: 14 tests, 7 failures and 2 errors. The four disputed installer/permission/HOME-alias cases already passed.
- Follow-up pre-fix run `1792520814-995804-23857`: 19 tests, 4 failures demonstrating unsafe receipt handling, post-open gate replacement and marker false positives. Original regressions passed.
- Upgrade run `1792520854-1029929-5162`: `ALL PASS`, including both private modes, legacy migration, foreign edits and cache eviction.
- Follow-up red run `1792521213-1404108-24657`: 17 tests, 2 failures (post-open replacement and quoted-marker handling).
- Green run `1792521363-1566072-15372`: all 19 regressions pass.
- Validator/installer run `1792521119-1299977-29852`: skill validation (`ERRORS: 0 WARNINGS: 0`), generated gates (`0 stale`), gate consistency (`ALL PASS`), strict registry integrity (`OK`), existing installer suite (`ALL PASS`), and Python no-shadowed-defs (`PASS=2 FAIL=0`).
- Final-edge red run `1792521903-2079980-17851`: 21 tests, 2 failures and 1 timeout/error (bulk-copy symlink, post-trust receipt change, whitespace recursion headers). An earlier attempt `1792521797-1972155-11547` exposed that the receipt fixture needed an explicit 0644 mode under the farm's group-writable umask; the later run reproduces the actual overwrite.
- Full run `1792521423-1622873-82` was deliberately cancelled (exit 130) after the final edge fixes became necessary. It is not counted as a pass/fail verdict for the final version, and the replacement full run was started only after cancellation completed.

Commit `9054f9ac` records the first verified fixes, upgrade tests and runbook.

- Final regression run `1792522208-2401636-18737`: `Ran 21 tests`, `OK`, farm `exit 0`. The final receipt-change, bulk-copy and whitespace-header cases pass alongside the original regressions.
- Commit `bccc206a` records the final edge fixes and all 21 regression cases.
- Host repair applied on `ryzen-old-1`, with source fingerprints checked after every copy. Backups: `/Users/greglas/.zuvo/backups/refactor-gate-round2-20261020T185633Z`. The global Claude entry, installer/template copies in Claude/Codex, and the installed 1.6.102/1.6.103 caches were repaired. The real Codex gate/library were not changed. Receipt: `zuvo/proofs/refactor-gate-round2-host-repair.json`.
- All 37 finding IDs from the supplied review and the two follow-up reviews have fixed/rejected dispositions recorded by one `adversarial-review --record-disposition ...` call. No finding is deferred and there are no backlog writes.

The first completed replacement battery was run `1792522845-2950442-7958` (detached transport
to survive a lost tool session); its command is `bash tests/run-all.sh` with
`LC_ALL=C`, `--full` output and `--light`. An earlier replacement client vanished
before farm confirmation during the interrupted tool session; it had no recorded
run id or active client and is not counted as a test result. Both completed
battery verdicts below were retrieved with `LC_ALL=C rt --log <runid>`.
Shell syntax and whitespace checks pass locally;
this shell/embedded-Python change has no TypeScript or standalone typed-Python
type-check target.

The first completed battery (`1792522845-2950442-7958`) returned **exit 1**:
`RESULT: PASS=219 FAIL=1 SKIP=6` (1689 seconds). The only failing child was
`tests/skill-suite/test-test-audit-subprocess-dispatch.sh`: its X8 check requires
`e6c2bedda3e576c2b7fbe6715df8d74ab3cbbf3a:skills/test-audit/SKILL.md`, while the
farm snapshot had no Git repository. The local object exists and contains the
same pinned Phase 3b line. This is a farm transport limitation: `rt` only syncs
Git metadata with `"git": "full"`, and explicitly skips a linked worktree's
`.git` file even with that option.

Verification therefore uses a disposable, non-shared clone at
`/tmp/zuvo-refactor-round2-gitfarm.LfihYj`, HEAD
`f5e38cdbab89e291cb37a410511bc5353f5b021a`, containing the exact committed product
tree plus a staged transport-only `.tf.json` with `{"git":"full"}`. No timeout,
memory, source, test or assertion is changed. Both the local clone and its full
Git object store contain the X8 baseline. The failing child is rerun first in
farm run `1792524674-765245-2637`: **exit 0, 310 passed, 0 failed**, including
`PASS: Phase 3b adversarial-review line is byte-identical to e6c2bedd… (X8)`.
A Git-aware full battery completed after that result: detached run
`1792524791-852335-6806`, using `LC_ALL=C rt --full --light bash tests/run-all.sh`
with detached/notify transport in the verification clone. It returned **exit 0**
in 2173 seconds. The authoritative log, retrieved with
`LC_ALL=C rt --log 1792524791-852335-6806`, ends:

```text
=== zuvo test run (scope: fast) ===
RESULT: PASS=221 FAIL=0 SKIP=5
ALL PASSED (SKIPs do not count as failures)
tf: exit 0  [queue 1s · setup 342ms · deps 2s · test 2173s]
```

The requested command runs the repository's default `fast` scope; `rt --full`
means full output. The five skipped groups require unavailable ruff/mypy,
shellcheck, zsh, Bats, or macOS `chflags`. No skip was added to resolve X8.
The original no-Git failure remains in the verdict receipt alongside the
successful Git-aware result: `zuvo/proofs/refactor-gate-round2-battery-verdict.txt`.

The installed-hook repair was reapplied after the completed battery and every
installed file's SHA-256 was checked against source. Claude's mirrored template
had disappeared and its installer/global gate needed repair again; the Codex
and cache copies remained current. Final backups:
`/Users/greglas/.zuvo/backups/refactor-gate-round2-20261020T200955Z`.
The first backups at `...20261020T185633Z` are retained too. The final manifest
is `zuvo/proofs/refactor-gate-round2-host-repair.json`; this repairs the host,
while the Mac source of ccsync still requires the eventual source update.
Transport receipt: `zuvo/proofs/refactor-gate-round2-gitfarm.json`.

## Remaining limits

Warn and exit 0 when no usable zuvo install is found is retained, per the explicit
user instruction and `docs/pipeline.md`. Real gate rejection statuses still
propagate. HOME, user-owned plugin/cache code and protected provenance receipts
are trusted local configuration. Final identity checks narrow, but do not
eliminate, uncoordinated pathname races. A pre-fix installer restored by ccsync
can still restore old behavior; it must be repaired at the configuration source.
