# S2_E re-run package (stage2_logs/s2e_v2) — PREPARED, NOT EXECUTED

Canonical files are untouched: `migrations/*`, `migrations/admin/S2_B_post_migration_grants.sql`,
`migrations/admin/S2_E_decision_acceptance_tests.sql` (sha256 `4a3f5dab…7771`). The previous run's
evidence in `stage2_logs/s2e/` is preserved unchanged.

## Change log
| # | File | Change | Reason |
|---|---|---|---|
| 1 | `GRANT_patch_definer_execute.sql` (new) | 11 routine-level `GRANT EXECUTE … TO 'cc_v2_dev_routine_definer'@'localhost'`, each schema-qualified, plus read-only verification | All 17 routines are `DEFINER = cc_v2_dev_routine_definer@localhost`, `SQL SECURITY DEFINER`; MySQL requires the definer to hold EXECUTE on the routine. S2_B granted only the 6 helpers → 41 × ERROR 1370. No schema-wide EXECUTE, no other account, no unlock. |
| 2 | `S2_E_run_copy.sql` (new) | C1: insert only the reviewer's Level 2 membership (the officer's Level 1 row in its own department already exists from the 006 backfill, `can_escalate FALSE, can_resolve TRUE` — identical to the row that raised ERROR 1062). C2: fixture selection additionally asserts that officer row exists and that the reviewer has no Level 2 row yet. Nothing else changed. | Preserves the R16 separation-of-duties scenario (officer acting as Level 1 handler) without a duplicate insert. Check counts unchanged: 18 PASS rows + 16 × ERROR 1644 + 1 fixture row = 35. |
| 3 | `run_s2e_v2.py` (copy of `s2e/run_s2e.py`) | Runs the run copy; pins both the canonical S2_E checksum and the run-copy checksum; log name `phase6_S2E_v2_*`. | Canonical-file integrity + reviewed run copy only. |
| 4 | `phase6_root.py` (copy of `s2e/phase6_root.py`) | `grant_part()` strips `\r` before comparing grant snapshots. Outputs now go to `stage2_logs/s2e_v2/`. | Fixes the false "grants differ" STOP caused by CRLF vs LF (G0/G1 were byte-identical in content). Verified offline: real G0/G1 equal; a tampered G1 is still detected. |
| 5 | `root_readonly_checks.sql`, `s2e_snapshot.py` | Unchanged copies. | Self-contained package. |

## Execution order (each step stops on failure; no automatic retry or fallback)
| Step | Account | Exact command (PowerShell, project root) | Expected result |
|---|---|---|---|
| 1 Grant patch | root (password prompt) | `& 'C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe' -u root -p --table -e "source stage2_logs/s2e_v2/GRANT_patch_definer_execute.sql"` | 11 GRANTs, no errors; procs_priv per user: `cc_v2_dev_activation_cli` 2, `cc_v2_dev_routine_definer` **17**, `complaint_app_v2_dev` 10; definer `account_locked = Y` |
| 2 Baseline P0b | migrator | `python -I -B stage2_logs\s2e_v2\s2e_snapshot.py stage2_logs\s2e_v2\P0b_pre_s2e_snapshot.json` | Identical to the verified P0 (the patch changes no data) |
| 3 Prep (G0b + backups) | root (3 prompts) | `python -I -B stage2_logs\s2e_v2\phase6_root.py prep` | Preflight passes; new `admin_post_stage2_full_<ts>.sql` (17 routines) and `admin_post_stage2_restoreimage_<ts>.sql` (0 routines); G0b shows the 11 new definer EXECUTE rows |
| 4 Verify backups | — (file checks) | same verification as `s2e/backup_verification_20261116.log`, against P0b | sha256 recomputed; Dump completed; dev-schema header; no USE / CREATE DATABASE / `college_complaints`; 22 tables, 4 triggers, 4 views; row counts == P0b |
| 5 S2_E v2 | migrator | `python -I -B stage2_logs\s2e_v2\run_s2e_v2.py --confirm-target college_complaints_v2_dev` | fixture PASS; PASS rows F02, E01, E03, E05, E07, E10, E12, E14, E17, E19, E19b, E19c, E21, E21b, E24, E25, E27, E29 (18); exactly 16 × ERROR 1644; no 1370 / 1062; S2_E RESULT: PASS |
| 6 Restore | root (3 prompts) | `python -I -B stage2_logs\s2e_v2\phase6_root.py restore <restoreimage path> <restoreimage sha256>` | image checks OK; preflight OK; restore into existing schema (no DROP DATABASE); G1b == G0b |
| 7 Final verification | migrator | `python -I -B stage2_logs\s2e_v2\s2e_snapshot.py stage2_logs\s2e_v2\P1b_post_restore_snapshot.json` + comparison | 22 tables' counts and checksums == P0b; 4 AUTO_INCREMENT == P0b; 17 routines, 4 triggers, 4 views, 9 SUCCESS ledger rows == P0b; grants == G0b |

Step 6 runs even if step 5 fails (data must be restored), provided its own checks pass.

## Caveat
The public procedures have never executed successfully before (every earlier call stopped at
ERROR 1370). Step 5 is therefore their first real run; any further defect will surface as a FAIL
row or an unexpected error and is handled by the restore in step 6, then reported.

## Outstanding (unchanged)
S2_C T16–T27d and the CLI-account probes remain deferred, not passed. Phase 7 integration report pending.
