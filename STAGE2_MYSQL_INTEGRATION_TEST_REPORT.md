# CampusCare 2.0 – Stage 2 MySQL Integration Test Report

**Server:** MySQL 8.0.46, localhost (`LAPTOP-8NBG0GUS:3306`).
**Target:** `college_complaints_v2_dev` (development sandbox only).
**Period:** 2026-11-15 23:49 – 2026-11-16 11:49.

All results below come from logs in `stage2_logs/`, `stage2_logs/s2e/` and `stage2_logs/s2e_v2/`. No result has been inferred.

**Legend:** **PASS** means verified by actual MySQL output. **FAIL** means the run failed and the cause was identified. **DEFERRED** means the test was not executed.

---

## 1. Baseline and backups
- **Read-only preflight:** PASS (`phase1_preflight_*.log`).
  - **Baseline counts:** 10 academic departments, 5 departments, 15 staff, 102 students, 202 complaints and 155 history rows.
  - **Assignments:** 200 complaints assigned, 2 unassigned.
  - **Student FK:** `complaints_ibfk_1` (`student_id`) is NO ACTION, compatible with the new CHECK.
  - **Protected database:** neither the migrator nor the runtime account can see `college_complaints`.
- **Backups:** every file is new and timestamped, and none was overwritten.

| Backup | Purpose | SHA-256 |
|---|---|---|
| `backups/stage2/admin_pre_stage2_20261115_235001.sql` | Pre-Stage-2 full recovery image | `f75a1645…9c27` |
| `backups/stage2/admin_post_stage2_full_20261116_113029.sql` | Post-migration full archive (17 routines) | `fb1c2e50…598d9d` |
| `backups/stage2/admin_post_stage2_restoreimage_20261116_113029.sql` | Post-migration restore image (no routines) | `4b67ee5a…d633ff` |

The earlier post-migration pair (`…_105439`) was used for the first S2_E run, which failed (section 5).

## 2. Migrations 000–008: PASS
| Step | Result |
|---|---|
| 000–007 | PASS on the first run. Every pre- and post-assertion passed. Output only showed MySQL deprecation notes (1287, `VALUES()`) |
| 008, first attempt | **FAIL**: `ERROR 1227 … SYSTEM_USER` while dropping the root-owned v1 procedure. 008 had changed nothing |
| S2_A2 fallback | Approved and schema-qualified. It removed exactly the 6 root-owned legacy objects. Every table checksum was unchanged |
| 008 retry | PASS. The ledger records 000–008 as SUCCESS |

**Post-migration state:**
- **Tables:** 22 (16 new).
- **Seed data:** 6 roles, 27 permissions, 4 workflow levels.
- **Users:** 117 inactive users with no password, and 117 role mappings.
- **Assignments:** 200 legacy assignments with a NULL actor; 2 complaints unassigned.
- **Integrity:** 0 complaints with a NULL complainant, and 0 mismatches between the assignment cache and the ledger.
- **Objects:** 17 procedures under `cc_v2_dev_routine_definer`, 4 triggers under `cc_v2_dev_trigger_definer`, and 4 views using `SQL SECURITY INVOKER`.
- **Specification difference:** the approved design seeds 27 permissions and installs 4 triggers, not the 24 and 3 given in the original handover brief.

## 3. Grants (S2_B) and correction
- **S2_B:** applied with no errors.
  - The runtime account's schema-wide grant was revoked. It has no INSERT or UPDATE on `complaints`, and EXECUTE on 10 procedures.
  - The migrator's temporary SET_USER_ID was revoked.
- **Defect found by S2_E (first run):** 41 × `ERROR 1370`. Every procedure runs as its definer, and MySQL requires that definer to hold EXECUTE on the procedure itself. S2_B had granted the definer EXECUTE only on the 6 internal helpers.
- **Correction:** `stage2_logs/s2e_v2/GRANT_patch_definer_execute.sql` adds 11 routine-level, schema-qualified grants and nothing else. Result: PASS.

**Final routine grants:** `cc_v2_dev_routine_definer` 17, `complaint_app_v2_dev` 10, `cc_v2_dev_activation_cli` 2.

## 4. Security tests
### S2_C: restricted run PASS, procedure probes DEFERRED
- **Executed:** 18 probes as `complaint_app_v2_dev`: T01–T13, T14–T15 and T28–T30. All passed.
- **Results:**
  - direct status, assignment, level, complainant, archive and detail updates were denied (1142);
  - direct INSERTs into `complaints`, the assignment ledger and `user_roles` were denied (1142);
  - token hashes are unreadable (1142);
  - the internal helpers and the operator procedure are not executable (1370);
  - `college_complaints` is not readable (1142).
- **Data:** every one of the 22 tables kept identical row counts and checksums.
- **DEFERRED:** T16–T27d (procedure-level probes) and the CLI-account probes (they need the CLI account unlocked).

### History-trigger check: PASS
- **Account:** root, inside a single transaction that was rolled back.
- **Result:** one status change produced exactly 1 history row.
- **After the rollback:** the row and the table checksums were restored and verified.

### S2_D: PASS
- **Run:** once, as `complaint_migrator_v2_dev`, using the corrected bundle.
- **Pre-checks:** InnoDB engines, test-data validity, `--skip-reconnect` and autocommit set to 0.
- **Results:** all **16** probes returned their expected code, in order: P1, P2, then D01–D14 (1142, 1142, 1644 ×5, 1062, 3819, 1644 ×3, 3819 ×4).
- **Session:** connection 57 was confirmed ended, with no row locks remaining.
- **Data:** all 22 tables unchanged. The `complaint_assignments` counter moved from 256 to 257; that is a counter gap left by the probe, not changed data.

## 5. S2_E acceptance tests (decisions R13–R16)
| Run | Result |
|---|---|
| S2_E, first run | **FAIL**: 41 × 1370 (the grant defect above) and 1 × 1062 (a duplicate officer Level 1 membership in the test data). The sandbox was then restored and verified against P0 and G0 |
| S2_E v2 (run copy: duplicate insert removed, test-data assertions added) | **PASS**: **35/35** checks. The fixture-selection row, 18/18 PASS rows (F02, E01–E29) and exactly 16/16 `1644` refusals. No unexpected errors (`phase6_S2E_v2_20261116_114308.log`) |

The canonical S2_E file was not modified.

## 6. Restore verification: PASS
- **Method:** the restore image was loaded into the existing schema. `DROP DATABASE` was not used. The image checksum, its safety checks and a root privilege check passed first.
- **P1b = P0b:**
  - **All 22 tables:** identical row counts and checksums (202 complaints, 155 history rows, 200 assignments, 117 users and 117 role mappings).
  - **Auto-increment counters:** 203 / 257 / 16 / 1, identical.
  - **Objects and ledger:** 17 routines, 4 triggers, 4 views and 9 SUCCESS ledger rows, identical.
  - **Test data:** none left. Escalations, verifications, officer records and tokens are all 0.
- **G1b = G0b:** identical for all five accounts, comparing the two snapshot files with carriage returns removed.

## 7. Accounts and lock state
| Account | Locked | Key privileges (verified with SHOW GRANTS) |
|---|---|---|
| `complaint_migrator_v2_dev` | N | 14 schema privileges on the dev schema; no DELETE, no SET_USER_ID |
| `complaint_app_v2_dev` | N | SELECT on 20 tables and 4 views; INSERT and UPDATE only on notification columns; EXECUTE on 10 procedures |
| `cc_v2_dev_routine_definer` | **Y** | Table- and column-level DML needed by the procedures; LOCK TABLES; EXECUTE on 17 routines |
| `cc_v2_dev_trigger_definer` | **Y** | TRIGGER and SELECT on `complaints`; SELECT on 4 lookup tables; INSERT on history |
| `cc_v2_dev_activation_cli` | **Y** | Column-limited reads; EXECUTE on 2 procedures |

**No account has any privilege on `college_complaints`.**

## 8. Original database
`college_complaints` was **never modified**:
- every write statement was schema-qualified to `college_complaints_v2_dev`, or ran with that database selected;
- the protected database is invisible to both application accounts, and the only probe that read from it was refused;
- no backup or restore targeted it.

## 9. Limitations and outstanding items
1. **E18** was refused by the separation-of-duties rule (its actor was also the submitter), so it **did not isolate the officer-only verification rule**. That rule is enforced in the code, but it has no dedicated test yet.
2. **Deferred tests** remain unverified: S2_C T16–T27d and the CLI-account probes.
3. **The grant-comparison driver** (`phase6_root.py`, `grant_part()`) has a line-ending defect: it reported "grants differ" twice when the grants were identical. Its verdict **must not be trusted until it is corrected**. The equality claims in this report rest on direct file comparison.
4. **The definer EXECUTE correction** lives in a separate patch file. S2_B should be updated to include it before any future fresh deployment.

## 10. Conclusion
**Passed:**
- migrations 000–008, including the approved S2_A2 fallback;
- S2_B, together with the 11-procedure grant correction;
- the restricted S2_C run (18 probes);
- the history-trigger check;
- S2_D (16/16);
- S2_E v2 (35/35);
- the restore, verified against both P0b and G0b.

**Deferred (not passed):**
- S2_C T16–T27d;
- the CLI-account probes;
- a dedicated test for the officer-only verification rule.

The development database is in a verified post-migration state. Stage 3 has not been started.
