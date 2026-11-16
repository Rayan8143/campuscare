-- S2_C_runtime_negative_tests.sql
-- Run AFTER S2_B, connected as the Flask runtime account, with --force so every probe runs:
--   mysql --force --table -u complaint_app_v2_dev -p --database=college_complaints_v2_dev -e "source migrations/admin/S2_C_runtime_negative_tests.sql"
--
-- Every probe is designed to change NOTHING even if a control were missing:
--   * UPDATE / DELETE / INSERT probes use WHERE 1 = 0 (MySQL checks privileges before it
--     evaluates rows, so a missing privilege still raises the expected error);
--   * procedure probes use complaint_id = 0 and/or actors that are inactive right after
--     Stage 2 (every migrated user is inactive), so they fail validation inside their own
--     transaction and roll back.
-- Compare each "expect" line with the error printed right after it.

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

SELECT 'T16 expect ERROR 1644 "Complaint does not exist." (procedure runs as definer, no change)' AS probe;
CALL transition_complaint_status(0, 'Rejected', 1, 'S2_C probe');

SELECT 'T17 expect ERROR 1644 "Authenticated actor user ID is required."' AS probe;
CALL transition_complaint_status(1, 'Resolved', NULL, 'S2_C probe');

SELECT 'T18 expect ERROR 1644 "Invalid target status ..." (Escalated only via escalate_complaint)' AS probe;
CALL transition_complaint_status(1, 'Escalated', 1, 'S2_C probe');

SELECT 'T19 expect ERROR 1644 (validation or "Authorization denied"; migrated users are inactive)' AS probe;
CALL reassign_complaint(1, 1, 1, 'S2_C probe');

SELECT 'T20 expect ERROR 1644 (password hash format required; plaintext rejected)' AS probe;
CALL redeem_account_token(REPEAT('0', 64), 'plaintext-password', @uid);

SELECT 'T21 expect ERROR 1644 "Authenticated actor user ID is required." (submit_complaint)' AS probe;
CALL submit_complaint(NULL, 'STUDENT', 1, 'probe', 'probe', 'Other', 'Low', @cid);

SELECT 'T22 expect ERROR 1644 "Authorization denied: no active student profile ..." (inactive student actor)' AS probe;
SELECT MIN(user_id) INTO @probe_student_user FROM students;
CALL submit_complaint(@probe_student_user, 'STUDENT', 1, 'probe', 'probe', 'Other', 'Low', @cid);

SELECT 'T23 expect ERROR 1644 "Authorization denied ..." (a student profile cannot be used as EXTERNAL)' AS probe;
CALL submit_complaint(@probe_student_user, 'EXTERNAL', 1, 'probe', 'probe', 'Other', 'Low', @cid);

SELECT 'T24 expect ERROR 1644 "Invalid complaint category."' AS probe;
CALL submit_complaint(@probe_student_user, 'STUDENT', 1, 'probe', 'probe', 'NotACategory', 'Low', @cid);

SELECT 'T25 expect ERROR 1644 "Authenticated actor user ID is required to issue tokens."' AS probe;
CALL issue_account_token(1, REPEAT('a', 64), 'PASSWORD_RESET', 60, NULL);

SELECT 'T26 expect ERROR 1644 "Authorization denied: actor may not issue a token ..." (student -> other account)' AS probe;
SELECT MAX(user_id) INTO @probe_other_user FROM users WHERE user_id <> @probe_student_user;
CALL issue_account_token(@probe_other_user, REPEAT('a', 64), 'PASSWORD_RESET', 60, @probe_student_user);

SELECT 'T27 expect ERROR 1644 (state or authorization; inactive actor cannot request escalation)' AS probe;
CALL request_escalation(1, 1, 'S2_C probe');

SELECT 'T27b expect ERROR 1644 "Complaint ID and authenticated actor user ID are required." (R13)' AS probe;
CALL update_complaint_details(1, NULL, 'x', NULL, NULL, NULL, NULL);

SELECT 'T27c expect ERROR 1644 "Authorization denied: owner edits only while Submitted ..." (R13, inactive owner)' AS probe;
SELECT MIN(complaint_id) INTO @probe_own_cid FROM complaints WHERE complainant_user_id = @probe_student_user;
CALL update_complaint_details(@probe_own_cid, @probe_student_user, 'S2_C probe title', NULL, NULL, NULL, NULL);

SELECT 'T27d expect ERROR 1644 "Invalid complaint category." (R13)' AS probe;
CALL update_complaint_details(@probe_own_cid, @probe_student_user, NULL, NULL, 'NotACategory', NULL, NULL);

SELECT 'T28 expect ERROR 1044/1142 (no access to the protected original database)' AS probe;
SELECT COUNT(*) FROM college_complaints.complaints;

SELECT 'T29 expect a row count of 202 (views work with INVOKER security)' AS probe;
SELECT COUNT(*) AS complaint_details_rows FROM complaint_details;

SELECT 'T30 expect 202 / 155 (no probe changed any data)' AS probe;
SELECT (SELECT COUNT(*) FROM complaints) AS complaints, (SELECT COUNT(*) FROM complaint_history) AS history_rows;

-- -------------------------------------------------------------------------------------
-- CLI account section: run SEPARATELY, connected as cc_v2_dev_activation_cli, only after it
-- has been unlocked (guide Step 8). Paste these three statements; each must fail as stated.
--   CALL issue_account_token(1, REPEAT('a',64), 'ACTIVATION', 60, 1);  -- expect ERROR 1370
--   SELECT password_hash FROM users LIMIT 1;                           -- expect ERROR 1143
--   SELECT COUNT(*) FROM account_activations;                          -- expect ERROR 1142
-- -------------------------------------------------------------------------------------
