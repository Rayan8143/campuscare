-- GRANT_patch_definer_execute.sql  - additive correction to S2_B (S2_B itself is NOT modified or re-run)
-- Run ONCE as the local MySQL admin. Targets only college_complaints_v2_dev.
--
-- Finding (S2_E run 2026-11-16 10:58, 41 x ERROR 1370): every SQL SECURITY DEFINER procedure
-- requires its DEFINER account to hold EXECUTE on that procedure. All 17 routines are defined by
-- 'cc_v2_dev_routine_definer'@'localhost' with SQL SECURITY DEFINER. S2_B granted that account
-- EXECUTE on the 6 internal helpers only; the 11 public procedures below are missing.
-- Scope: exactly these 11 routine-level grants. No schema-wide EXECUTE, no other account, no
-- account unlock, no other privilege. The definer stays ACCOUNT LOCKed.

GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`escalate_complaint`           TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`issue_account_token`          TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`issue_account_token_operator` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`reassign_complaint`           TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`redeem_account_token`         TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`request_escalation`           TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`soft_delete_complaint`        TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`submit_complaint`             TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`transfer_primary_officer`     TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`transition_complaint_status`  TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`update_complaint_details`     TO 'cc_v2_dev_routine_definer'@'localhost';

-- Read-only verification (expected: 17 rows for the definer, 10 runtime, 2 CLI = 29; definer locked)
SELECT User, COUNT(*) AS routine_grants FROM mysql.procs_priv
 WHERE Db = 'college_complaints_v2_dev' GROUP BY User ORDER BY User;
SELECT Routine_name, Proc_priv FROM mysql.procs_priv
 WHERE Db = 'college_complaints_v2_dev' AND User = 'cc_v2_dev_routine_definer' ORDER BY Routine_name;
SELECT user, host, account_locked FROM mysql.user WHERE user = 'cc_v2_dev_routine_definer';
