-- S2_D_integrity_tests_rolled_back.sql
-- Run AFTER S2_B, connected as the MIGRATOR (it holds UPDATE/INSERT, so these probes reach
-- the triggers and constraints instead of stopping at the privilege layer):
--   mysql --force -u complaint_migrator_v2_dev -p --database=college_complaints_v2_dev < migrations/admin/S2_D_integrity_tests_rolled_back.sql
--
-- Everything runs inside ONE transaction that is ROLLED BACK at the end. Each probe is
-- expected to fail; a failed statement inside a transaction does not end the transaction.
-- Side effect even on success: InnoDB AUTO_INCREMENT counters may skip values.
-- complaint_history count must be identical before and after (last two SELECTs).

SELECT COUNT(*) AS history_rows_before FROM complaint_history;

START TRANSACTION;

SELECT MIN(complaint_id) INTO @probe_cid FROM complaints WHERE status IN ('Submitted', 'In Progress') AND is_deleted = FALSE;
SELECT MIN(complaint_id) INTO @probe_assigned FROM complaints WHERE assigned_staff_id IS NOT NULL;
SELECT MIN(staff_id) INTO @probe_staff FROM staff;
SELECT @probe_cid AS probe_complaint, @probe_assigned AS probe_assigned_complaint, @probe_staff AS probe_staff;

SELECT 'D01 expect ERROR 1644 "Direct UPDATE of complaints.status is prohibited" (accident guard)' AS probe;
SET @app_status_transition_authorized = NULL;
UPDATE complaints SET status = 'Rejected' WHERE complaint_id = @probe_cid;

SELECT 'D02 expect ERROR 1644 (assigned_staff_id must match the active ledger row)' AS probe;
UPDATE complaints SET assigned_staff_id = NULL WHERE complaint_id = @probe_assigned;

SELECT 'D03 expect ERROR 1644 (current_level_id must match the escalation ledger)' AS probe;
UPDATE complaints SET current_level_id = 4 WHERE complaint_id = @probe_cid;

SELECT 'D04 expect ERROR 1644 (complainant_user_id cannot be altered)' AS probe;
UPDATE complaints SET complainant_user_id = complainant_user_id + 1 WHERE complaint_id = @probe_cid;

SELECT 'D05 expect ERROR 1644 (archiving requires deleted_by_user_id / deleted_at)' AS probe;
UPDATE complaints SET is_deleted = TRUE WHERE complaint_id = @probe_cid;

SELECT 'D06 expect ERROR 1062 on uq_single_active_assignment (second active assignment)' AS probe;
INSERT INTO complaint_assignments (complaint_id, assigned_staff_id, assignment_source, assigned_at, is_active)
SELECT @probe_assigned, @probe_staff, 'LEGACY_IMPORT', NULL, TRUE;

SELECT 'D07 expect ERROR 3819 chk_assignment_actor_required (WORKFLOW row without actor)' AS probe;
INSERT INTO complaint_assignments (complaint_id, assigned_staff_id, assignment_source, assigned_at, unassigned_at, is_active)
SELECT @probe_cid, @probe_staff, 'WORKFLOW', NOW(), NOW(), FALSE;

SELECT 'D08 expect ERROR 1644 (student_id does not belong to complainant_user_id)' AS probe;
INSERT INTO complaints (student_id, complainant_user_id, department_id, title, description, category, priority)
SELECT s.student_id, (SELECT MAX(user_id) FROM users WHERE user_id <> s.user_id), 1, 'probe', 'probe', 'Other', 'Low'
  FROM students s ORDER BY s.student_id LIMIT 1;

SELECT 'D09 expect ERROR 1644 (complainant_user_id cannot be null)' AS probe;
INSERT INTO complaints (student_id, complainant_user_id, department_id, title, description, category, priority)
SELECT MIN(student_id), NULL, 1, 'probe', 'probe', 'Other', 'Low' FROM students;

SELECT 'D10 expect ERROR 1644 (new complaints must start Submitted / unassigned / Level 1)' AS probe;
INSERT INTO complaints (student_id, complainant_user_id, department_id, title, description, category, priority, status)
SELECT s.student_id, s.user_id, 1, 'probe', 'probe', 'Other', 'Low', 'Resolved' FROM students s ORDER BY s.student_id LIMIT 1;

SELECT 'D11 expect ERROR 3819 chk_singleton_single_row' AS probe;
INSERT INTO primary_officer_assignment (singleton_id, user_id, assigned_by_user_id, transition_reason)
SELECT 2, MIN(user_id), MIN(user_id), 'probe' FROM users;

SELECT 'D12 expect ERROR 3819 chk_swa_level_not_officer_tier (Level 4 is singleton-only)' AS probe;
INSERT INTO staff_workflow_assignments (user_id, department_id, level_id) SELECT MIN(user_id), 1, 4 FROM users;

SELECT 'D13 expect ERROR 3819 chk_users_active_requires_password' AS probe;
UPDATE users SET is_active = TRUE WHERE user_id = (SELECT * FROM (SELECT MIN(user_id) FROM users) t);

SELECT 'D14 expect ERROR 1406 or 3819 (token hash must be 64 lowercase hex)' AS probe;
INSERT INTO account_activations (user_id, token_hash, expires_at)
SELECT MIN(user_id), REPEAT('Z', 64), UTC_TIMESTAMP() + INTERVAL 1 DAY FROM users;

ROLLBACK;

SELECT COUNT(*) AS history_rows_after FROM complaint_history;
SELECT COUNT(*) AS officer_rows_after FROM primary_officer_assignment;
