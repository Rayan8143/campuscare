-- S2_D_run_copy.sql  (revision 2)  -  corrected RUN COPY of migrations/admin/S2_D_integrity_tests_rolled_back.sql
-- Canonical file (unchanged): sha256 c3d82dd23f39f54b8139c38893c5645651f54a3cc9074dfdd5231fd8320bfac2
-- Execute ONLY through stage2_logs/s2d_bundle/run_s2d.py, which performs read-only InnoDB and
-- fixture preflights and aborts BEFORE launching the client if any check fails.
-- Account: complaint_migrator_v2_dev. Target: college_complaints_v2_dev.
-- Future command (PowerShell; do not run without approval):
--   python -I -B stage2_logs\s2d_bundle\run_s2d.py --confirm-target college_complaints_v2_dev
--
-- Safety design (unchanged from revision 1, strengthened gate):
--   * USE pins the schema. SET SESSION autocommit = 0 before the transaction. --skip-reconnect.
--   * @gate = 1 only if account, schema and autocommit are correct AND every fixture passes its
--     validity check (not merely non-NULL). Every mutating probe carries "@gate = 1".
--   * No DDL, GRANT, REVOKE, account statement, CALL, LOCK TABLES, TRUNCATE or COMMIT anywhere.

USE `college_complaints_v2_dev`;

SET SESSION autocommit = 0;

-- ---------------------------------------------------------------- fixtures (read-only)
-- D01/D03/D04/D05/D07: a Submitted, non-archived, Level 1 complaint
SELECT MIN(complaint_id) INTO @probe_cid FROM complaints
 WHERE status = 'Submitted' AND is_deleted = FALSE AND current_level_id = 1;
-- D02/D06: a complaint whose cached assignee equals its ACTIVE ledger row
SELECT MIN(c.complaint_id) INTO @probe_assigned
  FROM complaints c JOIN complaint_assignments ca
    ON ca.active_complaint_id = c.complaint_id AND ca.assigned_staff_id = c.assigned_staff_id
 WHERE c.assigned_staff_id IS NOT NULL;
-- D06/D07: an existing staff member
SELECT MIN(staff_id) INTO @probe_staff FROM staff;
-- D13 (+ D11, D12, D14 user FK): inactive user with NULL password_hash
SELECT MIN(user_id) INTO @probe_user FROM users WHERE is_active = FALSE AND password_hash IS NULL;
-- D08/D09/D10: a student linked to a user, a distinct alternate user, an existing department
SELECT MIN(student_id) INTO @probe_student FROM students WHERE user_id IS NOT NULL;
SELECT user_id INTO @probe_student_user FROM students WHERE student_id = @probe_student;
SELECT MAX(user_id) INTO @probe_other_user FROM users WHERE user_id <> @probe_student_user;
SELECT MIN(department_id) INTO @probe_dept FROM departments;

-- ---------------------------------------------------------------- validity checks (read-only)
SET @chk_cid      = (SELECT COUNT(*) FROM complaints WHERE complaint_id = @probe_cid
                      AND status = 'Submitted' AND is_deleted = FALSE AND current_level_id = 1);
SET @chk_assigned = (SELECT COUNT(*) FROM complaints c JOIN complaint_assignments ca
                       ON ca.active_complaint_id = c.complaint_id AND ca.assigned_staff_id = c.assigned_staff_id
                      WHERE c.complaint_id = @probe_assigned);
SET @chk_staff    = (SELECT COUNT(*) FROM staff WHERE staff_id = @probe_staff);
SET @chk_student  = (SELECT COUNT(*) FROM students s JOIN users u ON u.user_id = s.user_id
                      WHERE s.student_id = @probe_student AND s.user_id = @probe_student_user);
SET @chk_other    = (SELECT COUNT(*) FROM users WHERE user_id = @probe_other_user
                      AND @probe_other_user <> @probe_student_user);
SET @chk_user     = (SELECT COUNT(*) FROM users WHERE user_id = @probe_user
                      AND is_active = FALSE AND password_hash IS NULL);
SET @chk_dept     = (SELECT COUNT(*) FROM departments WHERE department_id = @probe_dept);
SET @chk_level4   = (SELECT COUNT(*) FROM workflow_levels WHERE level_id = 4);
SET @chk_officer  = (SELECT COUNT(*) FROM primary_officer_assignment WHERE singleton_id = 2);
SET @chk_swa4     = (SELECT COUNT(*) FROM staff_workflow_assignments
                      WHERE user_id = @probe_user AND department_id = @probe_dept AND level_id = 4);

SET @gate = IF(CURRENT_USER() = 'complaint_migrator_v2_dev@localhost'
               AND DATABASE() = 'college_complaints_v2_dev'
               AND @@SESSION.autocommit = 0
               AND @chk_cid = 1 AND @chk_assigned = 1 AND @chk_staff = 1 AND @chk_student = 1
               AND @chk_other = 1 AND @chk_user = 1 AND @chk_dept = 1 AND @chk_level4 = 1
               AND @chk_officer = 0 AND @chk_swa4 = 0, 1, NULL);

SELECT 'S2D_PRECHECK' AS marker, CURRENT_USER() AS current_user_, DATABASE() AS database_,
       @@SESSION.autocommit AS autocommit_, @gate AS gate, CONNECTION_ID() AS connection_id,
       @probe_cid AS probe_cid, @probe_assigned AS probe_assigned, @probe_staff AS probe_staff,
       @probe_user AS probe_user, @probe_student AS probe_student,
       @probe_student_user AS probe_student_user, @probe_other_user AS probe_other_user,
       @probe_dept AS probe_dept;

SELECT 'S2D_FIXTURE_CHECKS' AS marker, @chk_cid AS cid, @chk_assigned AS assigned, @chk_staff AS staff,
       @chk_student AS student, @chk_other AS other_user, @chk_user AS d13_user, @chk_dept AS dept,
       @chk_level4 AS level4, @chk_officer AS officer2_rows, @chk_swa4 AS swa_l4_rows;

SELECT 'S2D_COUNTS_BEFORE' AS marker,
       (SELECT COUNT(*) FROM complaints) AS complaints, (SELECT COUNT(*) FROM complaint_history) AS history,
       (SELECT COUNT(*) FROM complaint_assignments) AS assignments, (SELECT COUNT(*) FROM users) AS users,
       (SELECT COUNT(*) FROM users WHERE is_active = TRUE) AS active_users,
       (SELECT COUNT(*) FROM staff_workflow_assignments) AS swa,
       (SELECT COUNT(*) FROM account_activations) AS activations,
       (SELECT COUNT(*) FROM primary_officer_assignment) AS officer_rows;

-- ---------------------------------------------------------------- migrator privilege probes
SELECT 'P1 expect ERROR 1142 (migrator has no DELETE privilege)' AS probe;
DELETE FROM complaints WHERE 1 = 0 AND @gate = 1;

SELECT 'P2 expect ERROR 1044 or 1142 (protected database not accessible; read-only probe)' AS probe;
SELECT COUNT(*) FROM `college_complaints`.`complaints`;

-- ---------------------------------------------------------------- integrity probes
START TRANSACTION;

SELECT 'D01 expect ERROR 1644 "Direct UPDATE of complaints.status is prohibited" (accident guard)' AS probe;
SET @app_status_transition_authorized = NULL;
UPDATE complaints SET status = 'Rejected' WHERE complaint_id = @probe_cid AND @gate = 1;

SELECT 'D02 expect ERROR 1644 (assigned_staff_id must match the active ledger row)' AS probe;
UPDATE complaints SET assigned_staff_id = NULL WHERE complaint_id = @probe_assigned AND @gate = 1;

SELECT 'D03 expect ERROR 1644 (current_level_id must match the escalation ledger)' AS probe;
UPDATE complaints SET current_level_id = 4 WHERE complaint_id = @probe_cid AND @gate = 1;

SELECT 'D04 expect ERROR 1644 (complainant_user_id cannot be altered)' AS probe;
UPDATE complaints SET complainant_user_id = complainant_user_id + 1 WHERE complaint_id = @probe_cid AND @gate = 1;

SELECT 'D05 expect ERROR 1644 (archiving requires deleted_by_user_id / deleted_at)' AS probe;
UPDATE complaints SET is_deleted = TRUE WHERE complaint_id = @probe_cid AND @gate = 1;

SELECT 'D06 expect ERROR 1062 on uq_single_active_assignment (second active assignment)' AS probe;
INSERT INTO complaint_assignments (complaint_id, assigned_staff_id, assignment_source, assigned_at, is_active)
SELECT @probe_assigned, @probe_staff, 'LEGACY_IMPORT', NULL, TRUE FROM DUAL WHERE @gate = 1;

SELECT 'D07 expect ERROR 3819 chk_assignment_actor_required (WORKFLOW row without actor)' AS probe;
INSERT INTO complaint_assignments (complaint_id, assigned_staff_id, assignment_source, assigned_at, unassigned_at, is_active)
SELECT @probe_cid, @probe_staff, 'WORKFLOW', NOW(), NOW(), FALSE FROM DUAL WHERE @gate = 1;

SELECT 'D08 expect ERROR 1644 (student_id does not belong to complainant_user_id)' AS probe;
INSERT INTO complaints (student_id, complainant_user_id, department_id, title, description, category, priority)
SELECT @probe_student, @probe_other_user, @probe_dept, 'probe', 'probe', 'Other', 'Low' FROM DUAL WHERE @gate = 1;

SELECT 'D09 expect ERROR 1644 (complainant_user_id cannot be null)' AS probe;
INSERT INTO complaints (student_id, complainant_user_id, department_id, title, description, category, priority)
SELECT @probe_student, NULL, @probe_dept, 'probe', 'probe', 'Other', 'Low' FROM DUAL WHERE @gate = 1;

SELECT 'D10 expect ERROR 1644 (new complaints must start Submitted / unassigned / Level 1)' AS probe;
INSERT INTO complaints (student_id, complainant_user_id, department_id, title, description, category, priority, status)
SELECT @probe_student, @probe_student_user, @probe_dept, 'probe', 'probe', 'Other', 'Low', 'Resolved' FROM DUAL WHERE @gate = 1;

SELECT 'D11 expect ERROR 3819 chk_singleton_single_row' AS probe;
INSERT INTO primary_officer_assignment (singleton_id, user_id, assigned_by_user_id, transition_reason)
SELECT 2, @probe_user, @probe_user, 'probe' FROM DUAL WHERE @gate = 1;

SELECT 'D12 expect ERROR 3819 chk_swa_level_not_officer_tier (Level 4 is singleton-only)' AS probe;
INSERT INTO staff_workflow_assignments (user_id, department_id, level_id)
SELECT @probe_user, @probe_dept, 4 FROM DUAL WHERE @gate = 1;

SELECT 'D13 expect ERROR 3819 chk_users_active_requires_password (inactive user with NULL password_hash)' AS probe;
UPDATE users SET is_active = TRUE WHERE user_id = @probe_user AND password_hash IS NULL AND @gate = 1;

SELECT 'D14 expect ERROR 3819 chk_activation_token_hash_hex (token hash must be 64 lowercase hex)' AS probe;
INSERT INTO account_activations (user_id, token_hash, expires_at)
SELECT @probe_user, REPEAT('Z', 64), UTC_TIMESTAMP() + INTERVAL 1 DAY FROM DUAL WHERE @gate = 1;

ROLLBACK;

SELECT 'S2D_ROLLBACK_DONE' AS marker, @@SESSION.autocommit AS autocommit_after;

SELECT 'S2D_COUNTS_AFTER' AS marker,
       (SELECT COUNT(*) FROM complaints) AS complaints, (SELECT COUNT(*) FROM complaint_history) AS history,
       (SELECT COUNT(*) FROM complaint_assignments) AS assignments, (SELECT COUNT(*) FROM users) AS users,
       (SELECT COUNT(*) FROM users WHERE is_active = TRUE) AS active_users,
       (SELECT COUNT(*) FROM staff_workflow_assignments) AS swa,
       (SELECT COUNT(*) FROM account_activations) AS activations,
       (SELECT COUNT(*) FROM primary_officer_assignment) AS officer_rows;

ROLLBACK;
SELECT 'S2D_END' AS marker;
