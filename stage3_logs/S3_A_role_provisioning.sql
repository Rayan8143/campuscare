-- =====================================================================================
-- CampusCare 2.0 – Stage 3 / S3_A: Level 2, Level 3 and bootstrap-administrator provisioning
-- REVIEWED DRAFT (r2). NOT EXECUTED. Target: college_complaints_v2_dev ONLY; every table is
-- schema-qualified. Run as root in an INTERACTIVE mysql session after a fresh backup:
--     mysql> source stage3_logs/S3_A_role_provisioning.sql
--     ... compare every result with the EXPECT comments ...
--     mysql> COMMIT;      -- only if every EXPECT matches
--     mysql> ROLLBACK;    -- otherwise (nothing is kept)
-- The script deliberately ends with the transaction OPEN. Closing the client without COMMIT
-- also rolls back.
--
-- Writes (and nothing else):
--   user_roles                 : (114, DEPARTMENT_REVIEWER) (115, DEPARTMENT_REVIEWER) (109, SYSTEM_ADMIN)
--   staff_workflow_assignments : (114, dept 4, level 2, esc, res) (115, dept 4, level 3, esc, res)
-- Never touched: users, staff, students, complaints, complaint_history, complaint_assignments,
-- existing roles/memberships, user 106 (Level 1), user 4 (student). No triggers exist on the two
-- written tables (the only triggers are on complaints).
-- Every INSERT is an INSERT ... SELECT gated on the eligibility facts, so a wrong ID or a changed
-- profile inserts 0 rows instead of a bad row; a duplicate fails on the table's PK/UNIQUE key.
-- =====================================================================================

-- ---------- PRE-CHECKS (read-only) ----------
SELECT 'PRE identity' AS step, DATABASE() AS db, CURRENT_USER() AS account;

-- EXPECT 4 rows: 108 dept1, 109 dept1, 114 dept4, 115 dept4; all VERIFIED, active=1, user_active=1
--   (activation happens BEFORE this script in the approved order; user_active may be 0 if you
--    choose to provision first - roles/memberships do not require an active account)
SELECT st.user_id, st.staff_id, st.full_name, st.department_id, st.verification_status, st.is_active,
       u.is_active AS user_active
  FROM college_complaints_v2_dev.staff st JOIN college_complaints_v2_dev.users u ON u.user_id = st.user_id
 WHERE st.user_id IN (108, 109, 114, 115) ORDER BY st.user_id;

-- EXPECT 0 (no level 2/3 memberships exist yet)
SELECT COUNT(*) AS pre_level2_3_memberships FROM college_complaints_v2_dev.staff_workflow_assignments WHERE level_id > 1;
-- EXPECT 0 (nobody holds reviewer/admin/officer)
SELECT COUNT(*) AS pre_privileged_roles
  FROM college_complaints_v2_dev.user_roles ur JOIN college_complaints_v2_dev.roles r ON r.role_id = ur.role_id
 WHERE r.role_name IN ('DEPARTMENT_REVIEWER', 'SYSTEM_ADMIN', 'PRIMARY_COMPLAINT_OFFICER');
-- EXPECT level_id 2 -> level_number 2, level_id 3 -> level_number 3
SELECT level_id, level_number, level_name FROM college_complaints_v2_dev.workflow_levels WHERE level_id IN (2, 3);
-- Baseline of untouched data (note these values; POST must be identical)
SELECT (SELECT COUNT(*) FROM college_complaints_v2_dev.user_roles)                 AS user_roles_rows,
       (SELECT COUNT(*) FROM college_complaints_v2_dev.staff_workflow_assignments) AS membership_rows,
       (SELECT COUNT(*) FROM college_complaints_v2_dev.complaints)                 AS complaints,
       (SELECT COUNT(*) FROM college_complaints_v2_dev.complaint_history)          AS history_rows,
       (SELECT COUNT(*) FROM college_complaints_v2_dev.complaint_assignments)      AS assignment_rows;

START TRANSACTION;

-- ---------- 1. DEPARTMENT_REVIEWER for 114 (Level 2) and 115 (Level 3) ----------
-- Eligible only if: Laboratory (dept 4) staff, VERIFIED, active, not a student/external, and
-- already holding an active STAFF role (kept: assignee eligibility at L1-3 requires it).
-- EXPECT: Query OK, 2 rows affected
INSERT INTO college_complaints_v2_dev.user_roles (user_id, role_id, is_active)
SELECT st.user_id, r.role_id, TRUE
  FROM college_complaints_v2_dev.staff st
  JOIN college_complaints_v2_dev.roles r ON r.role_name = 'DEPARTMENT_REVIEWER'
 WHERE st.user_id IN (114, 115)
   AND st.department_id = 4 AND st.verification_status = 'VERIFIED' AND st.is_active = TRUE
   AND NOT EXISTS (SELECT 1 FROM college_complaints_v2_dev.students s WHERE s.user_id = st.user_id)
   AND NOT EXISTS (SELECT 1 FROM college_complaints_v2_dev.external_complainants e WHERE e.user_id = st.user_id)
   AND EXISTS (SELECT 1 FROM college_complaints_v2_dev.user_roles ur2
                 JOIN college_complaints_v2_dev.roles r2 ON r2.role_id = ur2.role_id AND r2.role_name = 'STAFF'
                WHERE ur2.user_id = st.user_id AND ur2.is_active = TRUE);

-- ---------- 2. Exact workflow memberships, Laboratory department ----------
-- level_id 2 = Department Reviewer, level_id 3 = Department Head (verified above).
-- can_escalate TRUE: required by escalate_complaint (department authority with escalate flag).
-- can_resolve  TRUE: may SUBMIT a resolution when assigned; approval stays officer-only.
-- EXPECT: Query OK, 2 rows affected
INSERT INTO college_complaints_v2_dev.staff_workflow_assignments
       (user_id, department_id, level_id, can_escalate, can_resolve)
SELECT v.user_id, 4, v.level_id, TRUE, TRUE
  FROM (SELECT 114 AS user_id, 2 AS level_id UNION ALL SELECT 115, 3) v
  JOIN college_complaints_v2_dev.staff st
    ON st.user_id = v.user_id AND st.department_id = 4
   AND st.verification_status = 'VERIFIED' AND st.is_active = TRUE;

-- ---------- 3. SYSTEM_ADMIN for 109 (bootstrap actor for transfer_primary_officer only) ----------
-- SYSTEM_ADMIN is the only role holding system:manage_roles. It carries NO complaint-workflow
-- write permission (seed 002: oversight + administration only). Deactivate after the
-- appointment (S3_C). EXPECT: Query OK, 1 row affected
INSERT INTO college_complaints_v2_dev.user_roles (user_id, role_id, is_active)
SELECT st.user_id, r.role_id, TRUE
  FROM college_complaints_v2_dev.staff st
  JOIN college_complaints_v2_dev.roles r ON r.role_name = 'SYSTEM_ADMIN'
 WHERE st.user_id = 109 AND st.verification_status = 'VERIFIED' AND st.is_active = TRUE
   AND st.user_id NOT IN (108, 114, 115, 106, 4);

-- ---------- POST-CHECKS (inside the open transaction) ----------
-- EXPECT exactly 6 rows (3 new + 3 pre-existing STAFF):
--   109 STAFF 1 | 109 SYSTEM_ADMIN 1 | 114 DEPARTMENT_REVIEWER 1 | 114 STAFF 1 | 115 DEPARTMENT_REVIEWER 1 | 115 STAFF 1
SELECT ur.user_id, r.role_name, ur.is_active
  FROM college_complaints_v2_dev.user_roles ur JOIN college_complaints_v2_dev.roles r ON r.role_id = ur.role_id
 WHERE ur.user_id IN (109, 114, 115) ORDER BY ur.user_id, r.role_name;
-- EXPECT exactly 2 rows: 114 dept4 level2 esc1 res1 | 115 dept4 level3 esc1 res1
SELECT user_id, department_id, level_id, can_escalate, can_resolve
  FROM college_complaints_v2_dev.staff_workflow_assignments WHERE level_id > 1 ORDER BY user_id;
-- EXPECT unchanged: user 106 = STAFF only + dept4 L1; user 4 = STUDENT only; 108 = STAFF only
SELECT ur.user_id, GROUP_CONCAT(r.role_name ORDER BY r.role_name) AS roles
  FROM college_complaints_v2_dev.user_roles ur JOIN college_complaints_v2_dev.roles r ON r.role_id = ur.role_id
 WHERE ur.user_id IN (4, 106, 108) AND ur.is_active = TRUE GROUP BY ur.user_id ORDER BY ur.user_id;
-- EXPECT: user_roles_rows = baseline + 3, membership_rows = baseline + 2, the other three identical
SELECT (SELECT COUNT(*) FROM college_complaints_v2_dev.user_roles)                 AS user_roles_rows,
       (SELECT COUNT(*) FROM college_complaints_v2_dev.staff_workflow_assignments) AS membership_rows,
       (SELECT COUNT(*) FROM college_complaints_v2_dev.complaints)                 AS complaints,
       (SELECT COUNT(*) FROM college_complaints_v2_dev.complaint_history)          AS history_rows,
       (SELECT COUNT(*) FROM college_complaints_v2_dev.complaint_assignments)      AS assignment_rows;

SELECT 'TRANSACTION STILL OPEN: type COMMIT; only if every EXPECT matched, otherwise ROLLBACK;' AS next_step;
