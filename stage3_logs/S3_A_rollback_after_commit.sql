-- CampusCare 2.0 – Stage 3 / S3_A reversal AFTER COMMIT. NOT EXECUTED. Root, interactive.
-- Removes exactly the 5 rows S3_A creates and nothing else. Use ONLY if S3_A was committed and
-- the officer has NOT yet been appointed (after S3_B, 109's admin role is referenced by
-- primary_officer_assignment.assigned_by_user_id only as a user FK, so this stays valid, but
-- then also review S3_B before reverting).
-- Full alternative: restore the pre-S3_A backup image.

START TRANSACTION;

-- EXPECT: 3 rows affected
DELETE ur FROM college_complaints_v2_dev.user_roles ur
  JOIN college_complaints_v2_dev.roles r ON r.role_id = ur.role_id
 WHERE (ur.user_id IN (114, 115) AND r.role_name = 'DEPARTMENT_REVIEWER')
    OR (ur.user_id = 109 AND r.role_name = 'SYSTEM_ADMIN');

-- EXPECT: 2 rows affected
DELETE FROM college_complaints_v2_dev.staff_workflow_assignments
 WHERE (user_id = 114 AND department_id = 4 AND level_id = 2)
    OR (user_id = 115 AND department_id = 4 AND level_id = 3);

-- EXPECT 0 and 0
SELECT COUNT(*) AS level2_3_memberships FROM college_complaints_v2_dev.staff_workflow_assignments WHERE level_id > 1;
SELECT COUNT(*) AS reviewer_admin_roles
  FROM college_complaints_v2_dev.user_roles ur JOIN college_complaints_v2_dev.roles r ON r.role_id = ur.role_id
 WHERE r.role_name IN ('DEPARTMENT_REVIEWER', 'SYSTEM_ADMIN');

SELECT 'TRANSACTION STILL OPEN: COMMIT; if the counts match, otherwise ROLLBACK;' AS next_step;
