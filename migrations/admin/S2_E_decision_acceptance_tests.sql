-- S2_E_decision_acceptance_tests.sql  -  acceptance tests for decisions R13, R14, R15, R16
--
-- !!! THIS SCRIPT MODIFIES DATA IN college_complaints_v2_dev !!!
-- The procedures commit their own transactions, so these tests cannot be rolled back.
-- Mandatory bracket (STAGE2_EXECUTION_GUIDE.md, Step 6b):
--   1. admin takes a POST-STAGE-2 backup (backups\stage2\admin_post_stage2_<stamp>.sql);
--   2. run this script as the migrator with --force:
--        mysql --force --table -u complaint_migrator_v2_dev -p --database=college_complaints_v2_dev -e "source migrations/admin/S2_E_decision_acceptance_tests.sql"
--   3. admin restores that post-Stage-2 backup (drop + recreate + restore), then --preflight.
-- Never run it against college_complaints (the script names no other database).
--
-- Fixtures (all reverted by step 3): six existing migrated users are activated with a RANDOM,
-- non-reproducible password hash (no usable password exists for them); one staff user gets
-- DEPARTMENT_REVIEWER + a Level 2 membership, one gets SYSTEM_ADMIN, one is bootstrapped as
-- Primary Officer; three test complaints are submitted. No existing record is deleted.
--
-- Reading the output: rows labelled PASS/FAIL are self-checking; lines "expect ERROR 1644"
-- must be followed by exactly that error. Any FAIL, or a missing expected error, fails the run.

SELECT 'S2_E START - data-modifying acceptance tests (restore the post-Stage-2 backup afterwards)' AS notice;

-- =====================================================================================
-- Fixture selection
-- =====================================================================================
SELECT department_id INTO @dept FROM staff GROUP BY department_id HAVING COUNT(*) >= 2
 ORDER BY COUNT(*) DESC, department_id LIMIT 1;
SELECT MIN(staff_id) INTO @staffA FROM staff WHERE department_id = @dept;
SELECT MIN(staff_id) INTO @staffR FROM staff WHERE department_id = @dept AND staff_id > @staffA;
SELECT MIN(staff_id) INTO @staffO FROM staff WHERE department_id <> @dept;
SELECT MIN(staff_id) INTO @staffD FROM staff WHERE department_id <> @dept AND staff_id > @staffO;
SELECT department_id INTO @deptO FROM staff WHERE staff_id = @staffO;
SELECT user_id INTO @uA FROM staff WHERE staff_id = @staffA;
SELECT user_id INTO @uR FROM staff WHERE staff_id = @staffR;
SELECT user_id INTO @uO FROM staff WHERE staff_id = @staffO;
SELECT user_id INTO @uD FROM staff WHERE staff_id = @staffD;
SELECT MIN(user_id) INTO @uS  FROM students;
SELECT MIN(user_id) INTO @uS2 FROM students WHERE user_id > @uS;
SELECT IF(@dept IS NULL OR @staffA IS NULL OR @staffR IS NULL OR @staffO IS NULL OR @staffD IS NULL
          OR @uS IS NULL OR @uS2 IS NULL, 'FAIL fixture selection', 'PASS fixture selection') AS result,
       @dept AS dept, @staffA AS staffA_L1, @staffR AS staffR_reviewer, @staffO AS staffO_officer, @staffD AS staffD_admin;

-- Activate six accounts with a random, unusable hash (test-only; reverted by the restore).
SET @fx_hash = CONCAT('scrypt:32768:8:1$', HEX(RANDOM_BYTES(8)), '$', SHA2(RANDOM_BYTES(32), 256));
UPDATE users SET password_hash = @fx_hash, is_active = TRUE WHERE user_id IN (@uA, @uR, @uO, @uD, @uS, @uS2);
SET @fx_hash = NULL;

INSERT INTO user_roles (user_id, role_id, is_active)
SELECT @uR, role_id, TRUE FROM roles WHERE role_name = 'DEPARTMENT_REVIEWER'
ON DUPLICATE KEY UPDATE is_active = TRUE;
INSERT INTO user_roles (user_id, role_id, is_active)
SELECT @uD, role_id, TRUE FROM roles WHERE role_name = 'SYSTEM_ADMIN'
ON DUPLICATE KEY UPDATE is_active = TRUE;
INSERT INTO staff_workflow_assignments (user_id, department_id, level_id, can_escalate, can_resolve)
VALUES (@uR, @dept, 2, TRUE, TRUE),     -- reviewer: exact Level 2 member of @dept
       (@uO, @deptO, 1, FALSE, TRUE);   -- officer also a Level 1 member (separation-of-duties test)

SELECT 'F01 expect ERROR 1644 (student account cannot become Primary Officer)' AS probe;
CALL transfer_primary_officer(@uS, @uD, 'S2_E: must be rejected');
CALL transfer_primary_officer(@uO, @uD, 'S2_E bootstrap');
SELECT IF((SELECT user_id FROM primary_officer_assignment WHERE singleton_id = 1) = @uO,
          'PASS F02 officer bootstrapped', 'FAIL F02 officer bootstrap') AS result;

-- =====================================================================================
-- R13 - complaint detail editing
-- =====================================================================================
CALL submit_complaint(@uS, 'STUDENT', @dept, 'S2_E complaint 1', 'S2_E description 1', 'Other', 'Low', @c1);
SELECT IF(@c1 IS NOT NULL AND (SELECT complainant_user_id FROM complaints WHERE complaint_id = @c1) = @uS,
          'PASS E01 submit derives complainant from actor', 'FAIL E01') AS result;

SELECT 'E02 expect ERROR 1644 (another student cannot edit this complaint)' AS probe;
CALL update_complaint_details(@c1, @uS2, 'hijacked', NULL, NULL, NULL, NULL);

CALL update_complaint_details(@c1, @uS, 'S2_E complaint 1 (edited)', NULL, NULL, 'Medium', NULL);
SELECT IF((SELECT title FROM complaints WHERE complaint_id = @c1) = 'S2_E complaint 1 (edited)'
          AND EXISTS (SELECT 1 FROM complaint_history WHERE complaint_id = @c1 AND action_type = 'DETAILS_EDITED'
                       AND changed_by_user_id = @uS AND changed_at IS NOT NULL
                       AND remarks LIKE 'Fields: title,priority (complainant edit)%'),
          'PASS E03 owner edit while Submitted, audited (editor, time, fields)', 'FAIL E03') AS result;

SELECT 'E04 expect ERROR 1644 (staff without edit permission cannot edit)' AS probe;
CALL update_complaint_details(@c1, @uA, 'staff edit', NULL, NULL, NULL, NULL);

-- =====================================================================================
-- R14 - exact-level handling, separate permissions
-- =====================================================================================
CALL reassign_complaint(@c1, @staffA, @uR, 'S2_E assign to Level 1 staff');
SELECT IF((SELECT assigned_staff_id FROM complaints WHERE complaint_id = @c1) = @staffA,
          'PASS E05 reviewer assigns (assignment permission)', 'FAIL E05') AS result;

SELECT 'E06 expect ERROR 1644 (supervisor cannot accept on the assignee''s behalf)' AS probe;
CALL transition_complaint_status(@c1, 'In Progress', @uR, 'S2_E');

CALL transition_complaint_status(@c1, 'In Progress', @uA, 'S2_E accepted');
SELECT IF((SELECT status FROM complaints WHERE complaint_id = @c1) = 'In Progress'
          AND EXISTS (SELECT 1 FROM complaint_history WHERE complaint_id = @c1
                       AND action_type = 'ASSIGNMENT_ACCEPTED' AND changed_by_user_id = @uA),
          'PASS E07 eligible assignee accepts (investigation permission)', 'FAIL E07') AS result;

SELECT 'E08 expect ERROR 1644 (R13: owner edits blocked once investigation accepted)' AS probe;
CALL update_complaint_details(@c1, @uS, 'late owner edit', NULL, NULL, NULL, NULL);

SELECT 'E09 expect ERROR 1644 (supervisory edit requires a reason)' AS probe;
CALL update_complaint_details(@c1, @uR, NULL, NULL, 'Infrastructure', NULL, NULL);
CALL update_complaint_details(@c1, @uR, NULL, NULL, 'Infrastructure', NULL, 'S2_E category correction');
SELECT IF(EXISTS (SELECT 1 FROM complaint_history WHERE complaint_id = @c1 AND action_type = 'DETAILS_EDITED'
                   AND changed_by_user_id = @uR AND remarks LIKE 'Fields: category (supervisory edit); reason: S2_E%'),
          'PASS E10 supervisory edit with reason, audited', 'FAIL E10') AS result;

SELECT 'E11 expect ERROR 1644 (escalation request needs can_escalate on the exact membership)' AS probe;
CALL request_escalation(@c1, @uA, 'S2_E request without can_escalate');
UPDATE staff_workflow_assignments SET can_escalate = TRUE
 WHERE user_id = @uA AND department_id = @dept AND level_id = 1;
CALL request_escalation(@c1, @uA, 'S2_E request with can_escalate');
SELECT IF(EXISTS (SELECT 1 FROM complaint_history WHERE complaint_id = @c1
                   AND action_type = 'ESCALATION_REQUESTED' AND changed_by_user_id = @uA),
          'PASS E12 escalation request recorded', 'FAIL E12') AS result;

SELECT 'E13 expect ERROR 1644 (requesting is not executing: staff lacks escalate_tier)' AS probe;
CALL escalate_complaint(@c1, 2, @uA, 'S2_E');

-- =====================================================================================
-- R15 - escalation closes the assignment; new-level member must be assigned and accept
-- =====================================================================================
CALL escalate_complaint(@c1, 2, @uR, 'S2_E needs Level 2 review');
SELECT IF((SELECT status FROM complaints WHERE complaint_id = @c1) = 'Escalated'
          AND (SELECT current_level_id FROM complaints WHERE complaint_id = @c1) = 2
          AND (SELECT assigned_staff_id FROM complaints WHERE complaint_id = @c1) IS NULL
          AND NOT EXISTS (SELECT 1 FROM complaint_assignments WHERE complaint_id = @c1 AND is_active = TRUE)
          AND EXISTS (SELECT 1 FROM complaint_assignments WHERE complaint_id = @c1 AND assigned_staff_id = @staffA
                       AND is_active = FALSE AND unassigned_by_user_id = @uR)
          AND EXISTS (SELECT 1 FROM complaint_escalations WHERE complaint_id = @c1 AND from_level_id = 1
                       AND to_level_id = 2 AND escalated_by_user_id = @uR
                       AND escalation_reason = 'S2_E needs Level 2 review'),
          'PASS E14 escalation: reason+actor recorded, level updated, assignment closed, awaiting assignment',
          'FAIL E14') AS result;

SELECT 'E15 expect ERROR 1644 (previous assignee can no longer resume)' AS probe;
CALL transition_complaint_status(@c1, 'In Progress', @uA, 'S2_E');

SELECT 'E16 expect ERROR 1644 (R14: Level 1 member cannot be assigned at Level 2)' AS probe;
CALL reassign_complaint(@c1, @staffA, @uR, 'S2_E reassign L1 member at L2');

CALL reassign_complaint(@c1, @staffR, @uR, 'S2_E assign Level 2 member');
CALL transition_complaint_status(@c1, 'In Progress', @uR, 'S2_E Level 2 accepted');
SELECT IF((SELECT status FROM complaints WHERE complaint_id = @c1) = 'In Progress'
          AND (SELECT assigned_staff_id FROM complaints WHERE complaint_id = @c1) = @staffR
          AND EXISTS (SELECT 1 FROM complaint_history WHERE complaint_id = @c1 AND action_type = 'ESCALATION_ACCEPTED')
          AND (SELECT COUNT(*) FROM complaint_assignments WHERE complaint_id = @c1) = 2,
          'PASS E17 new-level assignee accepted; full assignment trail kept', 'FAIL E17') AS result;

-- =====================================================================================
-- R16 - separation of duties
-- =====================================================================================
CALL transition_complaint_status(@c1, 'Resolution Pending Verification', @uR, 'S2_E resolution notes');
SELECT 'E18 expect ERROR 1644 (only the Primary Officer verifies)' AS probe;
CALL transition_complaint_status(@c1, 'Resolved', @uR, 'S2_E self approval attempt');
CALL transition_complaint_status(@c1, 'Resolved', @uO, 'S2_E approved');
SELECT IF((SELECT status FROM complaints WHERE complaint_id = @c1) = 'Resolved'
          AND EXISTS (SELECT 1 FROM resolution_verifications WHERE complaint_id = @c1 AND decision = 'APPROVED'
                       AND officer_user_id = @uO AND submitted_by_staff_id = @staffR),
          'PASS E19 staff submits, officer approves', 'FAIL E19') AS result;

-- Combined roles: the officer also holds an active STAFF role and inherits its permissions
-- (union of active roles), so as a Level 1 handler it CAN submit, but can NOT approve its own
-- submission; it must return it (or officer authority must be transferred).
SELECT IF(EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.role_id = ur.role_id
                   WHERE ur.user_id = @uO AND ur.is_active = TRUE AND r.role_name = 'STAFF')
          AND EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.role_id = ur.role_id
                       WHERE ur.user_id = @uO AND ur.is_active = TRUE AND r.role_name = 'PRIMARY_COMPLAINT_OFFICER'),
          'PASS E19b officer holds active STAFF + PRIMARY_COMPLAINT_OFFICER roles (combined permissions)',
          'FAIL E19b') AS result;
CALL submit_complaint(@uS, 'STUDENT', @deptO, 'S2_E complaint 3', 'S2_E description 3', 'Other', 'Low', @c3);
CALL reassign_complaint(@c3, @staffO, @uO, 'S2_E officer handles as Level 1 member');
CALL transition_complaint_status(@c3, 'In Progress', @uO, 'S2_E');
CALL transition_complaint_status(@c3, 'Resolution Pending Verification', @uO, 'S2_E officer-submitted notes');
SELECT IF((SELECT status FROM complaints WHERE complaint_id = @c3) = 'Resolution Pending Verification'
          AND EXISTS (SELECT 1 FROM resolution_verifications WHERE complaint_id = @c3
                       AND decision = 'PENDING' AND submitted_by_staff_id = @staffO),
          'PASS E19c officer submitted via inherited STAFF permission (exact L1 membership, can_resolve)',
          'FAIL E19c') AS result;
SELECT 'E20 expect ERROR 1644 "Separation of duties: ..." (officer cannot approve own submission)' AS probe;
CALL transition_complaint_status(@c3, 'Resolved', @uO, 'S2_E self approval');
SELECT IF((SELECT status FROM complaints WHERE complaint_id = @c3) = 'Resolution Pending Verification',
          'PASS E21 self-approval blocked, complaint still pending verification', 'FAIL E21') AS result;
CALL transition_complaint_status(@c3, 'In Progress', @uO, 'S2_E returned: cannot self-approve');
SELECT IF((SELECT status FROM complaints WHERE complaint_id = @c3) = 'In Progress'
          AND EXISTS (SELECT 1 FROM resolution_verifications WHERE complaint_id = @c3
                       AND decision = 'RETURNED' AND officer_user_id = @uO)
          AND NOT EXISTS (SELECT 1 FROM resolution_verifications WHERE complaint_id = @c3 AND decision = 'APPROVED'),
          'PASS E21b officer may only RETURN its own submission; nothing approved', 'FAIL E21b') AS result;

-- Level 4: the officer's final decision is recorded honestly, not as a verification.
CALL submit_complaint(@uS, 'STUDENT', @dept, 'S2_E complaint 2', 'S2_E description 2', 'Other', 'High', @c2);
CALL reassign_complaint(@c2, @staffA, @uR, 'S2_E assign');
CALL transition_complaint_status(@c2, 'In Progress', @uA, 'S2_E');
CALL escalate_complaint(@c2, 4, @uO, 'S2_E executive intervention');
SELECT 'E22 expect ERROR 1644 (a reviewer cannot assign at Level 4)' AS probe;
CALL reassign_complaint(@c2, @staffO, @uR, 'S2_E');
CALL reassign_complaint(@c2, @staffO, @uO, 'S2_E officer takes Level 4');
SELECT 'E23 expect ERROR 1644 (former Level 1 assignee cannot act at Level 4)' AS probe;
CALL transition_complaint_status(@c2, 'In Progress', @uA, 'S2_E');
CALL transition_complaint_status(@c2, 'In Progress', @uO, 'S2_E officer accepts Level 4');
CALL transition_complaint_status(@c2, 'Resolved', @uO, 'S2_E executive determination');
SELECT IF((SELECT status FROM complaints WHERE complaint_id = @c2) = 'Resolved'
          AND (SELECT department_id FROM complaints WHERE complaint_id = @c2) = @dept
          AND EXISTS (SELECT 1 FROM complaint_history WHERE complaint_id = @c2
                       AND action_type = 'OFFICER_FINAL_DECISION' AND changed_by_user_id = @uO
                       AND changed_at IS NOT NULL
                       AND remarks = 'Decision: Resolved. Reason: S2_E executive determination')
          AND NOT EXISTS (SELECT 1 FROM resolution_verifications WHERE complaint_id = @c2),
          'PASS E24 OFFICER_FINAL_DECISION recorded (decision, reason, actor, time); no fake verification',
          'FAIL E24') AS result;

-- =====================================================================================
-- Revision 4 - inactive staff can never receive an assignment
-- =====================================================================================
SELECT MIN(staff_id) INTO @staffX FROM staff WHERE staff_id NOT IN (@staffA, @staffR, @staffO, @staffD);
SELECT department_id, user_id INTO @deptX, @uX FROM staff WHERE staff_id = @staffX;
SELECT IF(@staffX IS NOT NULL
          AND (SELECT is_active FROM users WHERE user_id = @uX) = FALSE
          AND EXISTS (SELECT 1 FROM staff WHERE staff_id = @staffX AND is_active = TRUE AND verification_status = 'VERIFIED')
          AND EXISTS (SELECT 1 FROM staff_workflow_assignments WHERE user_id = @uX AND department_id = @deptX AND level_id = 1),
          'PASS E25 precondition: X has an active VERIFIED profile + Level 1 membership but an INACTIVE account',
          'FAIL E25 precondition') AS result;

CALL submit_complaint(@uS, 'STUDENT', @deptX, 'S2_E complaint 4', 'S2_E description 4', 'Other', 'Low', @c4);
SELECT 'E26 expect ERROR 1644 "Target staff not eligible: inactive account/role ..." (inactive users account)' AS probe;
CALL reassign_complaint(@c4, @staffX, @uO, 'S2_E assign inactive account');
SELECT IF((SELECT assigned_staff_id FROM complaints WHERE complaint_id = @c4) IS NULL
          AND NOT EXISTS (SELECT 1 FROM complaint_assignments WHERE complaint_id = @c4),
          'PASS E27 inactive account received no assignment and no ledger row', 'FAIL E27') AS result;

-- Active account and VERIFIED profile, but the STAFF role is deactivated.
UPDATE user_roles ur JOIN roles r ON r.role_id = ur.role_id
   SET ur.is_active = FALSE
 WHERE ur.user_id = @uA AND r.role_name = 'STAFF';
SELECT 'E28 expect ERROR 1644 "Target staff not eligible: inactive account/role ..." (inactive STAFF role)' AS probe;
CALL reassign_complaint(@c4, @staffA, @uO, 'S2_E assign inactive-role staff');
SELECT IF((SELECT assigned_staff_id FROM complaints WHERE complaint_id = @c4) IS NULL
          AND NOT EXISTS (SELECT 1 FROM complaint_assignments WHERE complaint_id = @c4),
          'PASS E29 staff with inactive STAFF role received no assignment', 'FAIL E29') AS result;
UPDATE user_roles ur JOIN roles r ON r.role_id = ur.role_id
   SET ur.is_active = TRUE
 WHERE ur.user_id = @uA AND r.role_name = 'STAFF';

-- =====================================================================================
-- Summary (data is reverted afterwards by restoring the post-Stage-2 backup)
-- =====================================================================================
SELECT (SELECT COUNT(*) FROM complaints) AS complaints_now_expect_206,
       (SELECT COUNT(*) FROM complaint_history WHERE complaint_id IN (@c1, @c2, @c3, @c4)) AS test_history_rows,
       (SELECT COUNT(*) FROM complaints c LEFT JOIN complaint_assignments ca ON ca.active_complaint_id = c.complaint_id
         WHERE NOT (c.assigned_staff_id <=> ca.assigned_staff_id)) AS cache_ledger_mismatches_expect_0;
SELECT 'S2_E END - now RESTORE the post-Stage-2 backup (guide Step 6b)' AS notice;
