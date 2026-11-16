-- Migration: 002_rbac_initial_seeds.sql
-- Purpose : Seed roles, permissions and role-permission mappings.
-- Type    : Transactional DML only (single explicit transaction).
-- Idempotency: deterministic primary keys + ON DUPLICATE KEY UPDATE / INSERT IGNORE.
--
-- Claude Stage 2 corrections (see STAGE2_CLAUDE_REVIEW.md, section 002):
--   * SYSTEM_ADMIN no longer receives complaint-workflow permissions. It previously held
--     ALL permissions, including complaint:verify_resolution, which contradicted the
--     "officer-only resolution verification" requirement and mixed configuration
--     authority with workflow authority. SYSTEM_ADMIN keeps administration, audit and
--     read-only oversight permissions only.
--   * PRIMARY_COMPLAINT_OFFICER no longer holds complaint:view_own (it is a complainant
--     permission; least privilege).
--   * New permissions 25 complaint:soft_delete (officer), 26 complaint:edit_own
--     (student, external) and 27 complaint:edit_details (reviewer, officer), used by 008.
--     (Revision 3: the former 26 complaint:triage was removed - per decision R15 only the
--     eligible ASSIGNEE accepts a complaint into investigation; supervisors assign.)
--   * A role holding a permission is NOT sufficient on its own: the procedures in 008 also
--     require department workflow membership (staff_workflow_assignments), the active
--     complaint assignment, or the Primary Officer singleton, as appropriate.

SET NAMES utf8mb4;
SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

START TRANSACTION;

-- 1. Roles
INSERT INTO `roles` (`role_id`, `role_name`, `description`) VALUES
(1, 'STUDENT',                   'Enrolled student complainant'),
(2, 'EXTERNAL_USER',             'External campus community member (parent, visitor, vendor, alumni)'),
(3, 'STAFF',                     'Department staff member handling assigned complaint investigations'),
(4, 'DEPARTMENT_REVIEWER',       'Department supervisory authority for triage, delegation and escalation (scope comes from workflow membership)'),
(5, 'PRIMARY_COMPLAINT_OFFICER', 'Global complaint oversight, Level 4 authority and exclusive resolution verifier (authority comes from the singleton table)'),
(6, 'SYSTEM_ADMIN',              'System configuration, user provisioning and role assignment; not part of the complaint workflow')
ON DUPLICATE KEY UPDATE `role_name` = VALUES(`role_name`), `description` = VALUES(`description`);

-- 2. Permissions
INSERT INTO `permissions` (`permission_id`, `permission_key`, `module`, `description`) VALUES
-- Complainant
(1,  'complaint:submit_student',        'complaint', 'Submit complaint as authenticated student'),
(2,  'complaint:submit_external',       'complaint', 'Submit complaint as authenticated external user'),
(3,  'complaint:view_own',              'complaint', 'View own submitted complaints and timeline'),
(4,  'complaint:withdraw_own',          'complaint', 'Withdraw or cancel own pending complaint (no DB workflow path yet; see review)'),
-- Staff
(5,  'complaint:view_assigned',         'staff',     'View complaints assigned to self'),
(6,  'complaint:update_investigation',  'staff',     'Start investigation / add notes on own assigned complaint'),
(7,  'complaint:submit_resolution',     'staff',     'Submit resolution notes for officer verification'),
(8,  'complaint:request_escalation',    'staff',     'Request escalation to a higher workflow tier (request only; execution needs escalate_tier)'),
-- Department reviewer
(9,  'complaint:view_department_queue', 'reviewer',  'View complaints of departments where the user holds workflow membership'),
(10, 'complaint:assign_staff',          'reviewer',  'Assign an unassigned department complaint to staff'),
(11, 'complaint:reassign_staff',        'reviewer',  'Reassign a department complaint between staff of the same department'),
(12, 'complaint:reject',                'reviewer',  'Reject invalid or out-of-scope complaint with reason'),
(13, 'complaint:escalate_tier',         'reviewer',  'Execute a workflow level escalation'),
-- Primary Complaint Officer
(14, 'complaint:view_all',              'officer',   'Global visibility across all department complaints'),
(15, 'complaint:reassign_global',       'officer',   'Reassign complaint across departments and staff'),
(16, 'complaint:verify_resolution',     'officer',   'Approve resolution or return for reinvestigation'),
(17, 'staff:verify_account',            'officer',   'Verify, approve, or reject staff account registration'),
(18, 'staff:toggle_active',             'officer',   'Activate or deactivate staff system access'),
(19, 'report:view_global',              'officer',   'Generate cross-departmental and staff KPI reports'),
-- System administration
(20, 'system:manage_users',             'admin',     'Manage user accounts'),
(21, 'system:manage_roles',             'admin',     'Assign and revoke user roles; appoint the Primary Officer'),
(22, 'system:manage_workflow',          'admin',     'Configure workflow levels and workflow memberships'),
(23, 'system:view_audit_logs',          'admin',     'Inspect audit logs and history ledgers'),
(24, 'system:manage_departments',       'admin',     'Manage academic and service departments'),
-- Added by Stage 2 review (required by 008 procedures)
(25, 'complaint:soft_delete',           'officer',   'Archive (soft-delete) a complaint; audit records are retained'),
(26, 'complaint:edit_own',              'complaint', 'Edit title/description/category/priority of own complaint while still Submitted'),
(27, 'complaint:edit_details',          'reviewer',  'Supervisory correction of complaint details (department scope, or global for the officer); reason required')
ON DUPLICATE KEY UPDATE `permission_key` = VALUES(`permission_key`),
                        `module`         = VALUES(`module`),
                        `description`    = VALUES(`description`);

-- 3. Role-permission mappings
-- Permission families (R14): VIEW 3/5/9/14 | INVESTIGATION 6 | ASSIGNMENT 10/11/15 |
-- ESCALATION 8 (request) / 13 (execute) | RESOLUTION SUBMISSION 7 | FINAL VERIFICATION 16 |
-- DETAIL EDITING 26 (own) / 27 (supervisory). Each is checked separately by the procedures,
-- always together with workflow membership / assignment / singleton - never designation.

-- STUDENT: 1, 3, 4, 26
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(1, 1), (1, 3), (1, 4), (1, 26);

-- EXTERNAL_USER: 2, 3, 4, 26
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(2, 2), (2, 3), (2, 4), (2, 26);

-- STAFF: 5, 6, 7, 8
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(3, 5), (3, 6), (3, 7), (3, 8);

-- DEPARTMENT_REVIEWER: 5-13, 27
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(4, 5), (4, 6), (4, 7), (4, 8), (4, 9), (4, 10), (4, 11), (4, 12), (4, 13), (4, 27);

-- PRIMARY_COMPLAINT_OFFICER: 5, 6, 9-19, 23, 25, 27
-- (6 lets the officer accept and investigate Level 4 complaints assigned to their own profile.
--  7 submit_resolution is not in THIS role. ROLE INHERITANCE: permissions are the UNION of all
--  of a user's ACTIVE roles. The officer must be staff, so an officer who also holds an active
--  STAFF role inherits 7 from it; assigned to a Level 1-3 complaint with an exact membership
--  carrying can_resolve, the officer CAN submit a resolution. Under R16 the officer can never
--  approve that own submission: it must be returned, or approved after officer authority is
--  transferred to another person.)
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(5, 5), (5, 6), (5, 9), (5, 10), (5, 11), (5, 12), (5, 13), (5, 14), (5, 15), (5, 16),
(5, 17), (5, 18), (5, 19), (5, 23), (5, 25), (5, 27);

-- SYSTEM_ADMIN: 14, 19, 20-24 (no workflow-changing permissions)
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(6, 14), (6, 19), (6, 20), (6, 21), (6, 22), (6, 23), (6, 24);

COMMIT;
