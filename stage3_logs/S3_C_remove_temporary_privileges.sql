-- S3_C: disable temporary/conflicting roles after the officer appointment. Root, interactive.
-- Disables (is_active = FALSE), never deletes. Leaves the transaction OPEN for COMMIT/ROLLBACK.
--   109 SYSTEM_ADMIN -> off     (bootstrap actor no longer needed)
--   108 STAFF        -> off     (officer can no longer be a Level 1-3 assignee; the Level 1
--                                membership row is kept for audit and becomes ineffective)
-- Preconditions enforced by the WHERE clauses: the officer singleton must point to 108.

SELECT 'PRE' AS step, poa.user_id AS officer, poa.assigned_by_user_id AS appointed_by
  FROM college_complaints_v2_dev.primary_officer_assignment poa;   -- EXPECT 108 / 109

START TRANSACTION;

-- EXPECT 1 row affected
UPDATE college_complaints_v2_dev.user_roles ur
  JOIN college_complaints_v2_dev.roles r ON r.role_id = ur.role_id AND r.role_name = 'SYSTEM_ADMIN'
   SET ur.is_active = FALSE
 WHERE ur.user_id = 109 AND ur.is_active = TRUE
   AND EXISTS (SELECT 1 FROM college_complaints_v2_dev.primary_officer_assignment p WHERE p.user_id = 108);

-- EXPECT 1 row affected
UPDATE college_complaints_v2_dev.user_roles ur
  JOIN college_complaints_v2_dev.roles r ON r.role_id = ur.role_id AND r.role_name = 'STAFF'
   SET ur.is_active = FALSE
 WHERE ur.user_id = 108 AND ur.is_active = TRUE
   AND EXISTS (SELECT 1 FROM college_complaints_v2_dev.primary_officer_assignment p WHERE p.user_id = 108);

-- EXPECT: 108 PRIMARY_COMPLAINT_OFFICER 1, STAFF 0 | 109 STAFF 1, SYSTEM_ADMIN 0 |
--         114 and 115 DEPARTMENT_REVIEWER 1, STAFF 1 | 106 STAFF 1 | 4 STUDENT 1
SELECT ur.user_id, r.role_name, ur.is_active
  FROM college_complaints_v2_dev.user_roles ur JOIN college_complaints_v2_dev.roles r ON r.role_id = ur.role_id
 WHERE ur.user_id IN (4, 106, 108, 109, 114, 115) ORDER BY ur.user_id, r.role_name;
-- EXPECT 17 memberships (unchanged), 202 complaints
SELECT (SELECT COUNT(*) FROM college_complaints_v2_dev.staff_workflow_assignments) AS memberships,
       (SELECT COUNT(*) FROM college_complaints_v2_dev.complaints) AS complaints;
SELECT 'TRANSACTION STILL OPEN: COMMIT; if every EXPECT matched, otherwise ROLLBACK;' AS next_step;
