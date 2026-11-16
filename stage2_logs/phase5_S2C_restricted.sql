-- Restricted subset of migrations/admin/S2_C_runtime_negative_tests.sql (T01-T15, T28-T30); extracted verbatim; canonical file unchanged.
SELECT 'T01 expect ERROR 1142 (no UPDATE privilege on complaints at all) EVEN WITH the session marker set TRUE' AS probe;
SET @app_status_transition_authorized = TRUE;
UPDATE complaints SET status = 'Resolved' WHERE 1 = 0;
SET @app_status_transition_authorized = NULL;

SELECT 'T02 expect ERROR 1142 (assigned_staff_id)' AS probe;
UPDATE complaints SET assigned_staff_id = NULL WHERE 1 = 0;

SELECT 'T03 expect ERROR 1142 (current_level_id)' AS probe;
UPDATE complaints SET current_level_id = 4 WHERE 1 = 0;

SELECT 'T04 expect ERROR 1142 (complainant_user_id)' AS probe;
UPDATE complaints SET complainant_user_id = 1 WHERE 1 = 0;

SELECT 'T05 expect ERROR 1142 (is_deleted)' AS probe;
UPDATE complaints SET is_deleted = TRUE WHERE 1 = 0;

SELECT 'T06 expect ERROR 1142 (resolved_at)' AS probe;
UPDATE complaints SET resolved_at = NOW() WHERE 1 = 0;

SELECT 'T06b expect ERROR 1142 (R13: no direct detail editing; use update_complaint_details)' AS probe;
UPDATE complaints SET title = 'x', description = 'x' WHERE 1 = 0;

SELECT 'T07 expect ERROR 1142 (INSERT denied on complaint_assignments: ledger cannot be bypassed)' AS probe;
INSERT INTO complaint_assignments (complaint_id, assigned_staff_id) SELECT 0, 0 FROM DUAL WHERE 1 = 0;

SELECT 'T08 expect ERROR 1142 (complaint_history is append-only via triggers/procedures)' AS probe;
UPDATE complaint_history SET remarks = 'x' WHERE 1 = 0;

SELECT 'T09 expect ERROR 1142 (DELETE denied on complaint_history)' AS probe;
DELETE FROM complaint_history WHERE 1 = 0;

SELECT 'T10 expect ERROR 1142 (no access to token hashes)' AS probe;
SELECT COUNT(*) FROM account_activations;

SELECT 'T11 expect ERROR 1142 (cannot self-assign roles)' AS probe;
INSERT INTO user_roles (user_id, role_id) SELECT 0, 0 FROM DUAL WHERE 1 = 0;

SELECT 'T12 expect ERROR 1142 (cannot write the officer singleton directly)' AS probe;
UPDATE primary_officer_assignment SET user_id = 0 WHERE 1 = 0;

SELECT 'T13 expect ERROR 1142 (no direct INSERT on complaints: client-supplied complainant_user_id impossible)' AS probe;
INSERT INTO complaints (student_id, complainant_user_id, department_id, title, description, category, priority)
SELECT 0, 0, 0, 'x', 'x', 'Other', 'Low' FROM DUAL WHERE 1 = 0;

SELECT 'T14 expect ERROR 1370 (internal helpers not executable by runtime)' AS probe;
CALL cc_auth_has_permission(1, 'complaint:view_all', @ok);
CALL cc_auth_staff_eligible(1, 1, 1, FALSE, FALSE, @ok);
CALL cc_token_issue_core(1, REPEAT('a', 64), 'ACTIVATION', 60);

SELECT 'T15 expect ERROR 1370 (dev-only operator issuance never granted to Flask)' AS probe;
CALL issue_account_token_operator(1, REPEAT('a', 64), 'ACTIVATION', 60);

SELECT 'T28 expect ERROR 1044/1142 (no access to the protected original database)' AS probe;
SELECT COUNT(*) FROM college_complaints.complaints;

SELECT 'T29 expect a row count of 202 (views work with INVOKER security)' AS probe;
SELECT COUNT(*) AS complaint_details_rows FROM complaint_details;

SELECT 'T30 expect 202 / 155 (no probe changed any data)' AS probe;
SELECT (SELECT COUNT(*) FROM complaints) AS complaints, (SELECT COUNT(*) FROM complaint_history) AS history_rows;
