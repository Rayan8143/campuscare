-- Phase 5 Step 1 - history-trigger probe (ROOT, single transaction, ROLLED BACK; nothing committed)
-- Target: college_complaints_v2_dev only. No DDL, no GRANT/REVOKE, no account changes.
USE `college_complaints_v2_dev`;

SELECT 'S1 BEFORE' AS step;
SELECT complaint_id, status, assigned_staff_id, current_level_id, resolved_at, is_deleted, complainant_user_id
  FROM `college_complaints_v2_dev`.`complaints` WHERE complaint_id = 2;
SELECT (SELECT COUNT(*) FROM `college_complaints_v2_dev`.`complaint_history` WHERE complaint_id = 2) AS history_for_2,
       (SELECT COUNT(*) FROM `college_complaints_v2_dev`.`complaint_history`) AS history_total;
CHECKSUM TABLE `college_complaints_v2_dev`.`complaints`, `college_complaints_v2_dev`.`complaint_history`;

START TRANSACTION;
-- Accident-guard marker (NOT a security control) so the guard trigger allows the status change.
SET @app_status_transition_authorized = TRUE, @app_current_user_id = NULL,
    @app_action_type = 'S2_TRIGGER_PROBE', @app_status_remarks = 'Phase 5 trigger probe - rolled back';
UPDATE `college_complaints_v2_dev`.`complaints`
   SET status = 'In Progress'
 WHERE complaint_id = 2 AND status = 'Submitted';
SELECT ROW_COUNT() AS rows_updated;

SELECT 'S1 INSIDE TRANSACTION' AS step;
SELECT (SELECT COUNT(*) FROM `college_complaints_v2_dev`.`complaint_history` WHERE complaint_id = 2) AS history_for_2,
       (SELECT COUNT(*) FROM `college_complaints_v2_dev`.`complaint_history`) AS history_total;
SELECT complaint_id, old_status, new_status, changed_by_user_id, action_type, remarks
  FROM `college_complaints_v2_dev`.`complaint_history` WHERE complaint_id = 2 ORDER BY history_id;

ROLLBACK;
SET @app_status_transition_authorized = NULL, @app_current_user_id = NULL,
    @app_action_type = NULL, @app_status_remarks = NULL;

SELECT 'S1 AFTER ROLLBACK' AS step;
SELECT complaint_id, status, assigned_staff_id, current_level_id, resolved_at, is_deleted, complainant_user_id
  FROM `college_complaints_v2_dev`.`complaints` WHERE complaint_id = 2;
SELECT (SELECT COUNT(*) FROM `college_complaints_v2_dev`.`complaint_history` WHERE complaint_id = 2) AS history_for_2,
       (SELECT COUNT(*) FROM `college_complaints_v2_dev`.`complaint_history`) AS history_total;
CHECKSUM TABLE `college_complaints_v2_dev`.`complaints`, `college_complaints_v2_dev`.`complaint_history`;
