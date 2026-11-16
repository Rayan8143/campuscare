# S2_D bundle change log

Canonical `migrations/admin/S2_D_integrity_tests_rolled_back.sql` is never modified
(sha256 `c3d82dd23f39f54b8139c38893c5645651f54a3cc9074dfdd5231fd8320bfac2`). Nothing in this bundle
has been executed.

## Revision 1 (vs canonical)
USE pin; `SET SESSION autocommit = 0`; START TRANSACTION / ROLLBACK kept; `--skip-reconnect`;
`@gate` on every mutating probe; non-NULL fixtures; D13 via inactive NULL-hash user (no derived
table); 22-table count+CHECKSUM snapshots; AUTO_INCREMENT of 4 tables; D14 label 3819; PowerShell-
safe launch via harness; P1 DELETE-denial (grant-proven); P2 read-only cross-database denial.

## Revision 2
| # | Request | Change |
|---|---|---|
| 1 | InnoDB preflight | Harness phase 3c checks ENGINE of the 7 tables; missing/non-InnoDB aborts before the client starts. |
| 2 | Stronger fixtures | Run copy: `@probe_cid` must be Submitted, non-archived, Level 1; `@probe_assigned` must match its active ledger row; `@probe_dept` replaces literal 1; ten `@chk_*` validity counts feed `@gate`, reported in `S2D_FIXTURE_CHECKS`. Harness phase 3d re-runs the same checks read-only (plus "exactly one active assignment" for D06) and aborts before launch on any failure. |
| 3 | Protections preserved | autocommit = 0, START TRANSACTION, explicit ROLLBACK, `--skip-reconnect`; still no COMMIT/DDL/GRANT/REVOKE/account/CALL. |
| 4 | Strict failure rules | FATAL codes extended (3572 NOWAIT lock, 3024 timeout); any `Warning` line fails; `S2D_FIXTURE_CHECKS` must equal the expected vector; client timeout (300 s, process killed) fails; PASS only if every phase is clean — matching checksums alone never pass. |
| 5 | Session settlement | Run copy reports `CONNECTION_ID()`. Harness phase 6 waits until that server session leaves PROCESSLIST (or, if the id is unknown, every other migrator session); after 120 s it KILLs its own-account connection and waits again; then proves release with read-only `SELECT ... FOR UPDATE NOWAIT` on the probe rows (rolled back). Unproven settlement => FAIL and no rollback claim. |
| 6 | Snapshots | 22-table snapshot and 4 AUTO_INCREMENT comparisons unchanged. |

## Revision 3 (final safety modification)
| # | Request | Change |
|---|---|---|
| 1 | Remove automatic KILL | All `KILL CONNECTION` logic deleted from `run_s2d.py`; the harness never terminates any session. |
| 2 | Monitor exact id | Only the `CONNECTION_ID()` emitted in the run copy's `S2D_PRECHECK` row is monitored (`information_schema.PROCESSLIST WHERE ID = <id>`). |
| 3 | No guessing | If the id is not captured, the run fails with `SESSION_ID_NOT_CAPTURED`; the former "all other migrator sessions" fallback is removed. |
| 4 | 120 s wait | `SETTLE_TIMEOUT_S = 120` for the session to disappear (and again for the NOWAIT lock proof). |
| 5 | Failure reason | Session still present => FAIL `SESSION_TERMINATION_UNCONFIRMED` (also used if probe rows remain locked). |
| 6 | No success claim | A settlement failure stops the harness: no output analysis verdict, no final snapshot, no rollback success, no PASS. |
| 7 | Manual verification | Every settlement failure logs `MANUAL ADMINISTRATOR VERIFICATION REQUIRED` and no final snapshot is taken or presented as proof. Client stdout/stderr are now logged before settlement so they are preserved for that review. |
| 8 | Preserved | Strict output checks, 16-code ordered matching, 22-table COUNT + CHECKSUM snapshots, 4 AUTO_INCREMENT comparisons, pinned canonical and run-copy checksums, InnoDB and fixture preflights. |

The run copy `S2_D_run_copy.sql` is **unchanged** in revision 3 (it already emits `CONNECTION_ID()`), so its pinned checksum stays valid.
