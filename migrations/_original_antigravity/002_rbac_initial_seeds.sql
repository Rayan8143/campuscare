-- Migration: 002_rbac_initial_seeds.sql
-- Purpose: Seed standard roles, granular permissions, and role-permission mappings
-- Note: Transactional DML; safe to execute within a single transaction

START TRANSACTION;

-- 1. Standard Roles
INSERT INTO `roles` (`role_id`, `role_name`, `description`) VALUES
(1, 'STUDENT', 'Enrolled student complainant'),
(2, 'EXTERNAL_USER', 'External campus community member (parent, visitor, vendor, alumni)'),
(3, 'STAFF', 'Department staff member handling assigned complaint investigations'),
(4, 'DEPARTMENT_REVIEWER', 'Department supervisory authority for ticket triage, delegation, and review'),
(5, 'PRIMARY_COMPLAINT_OFFICER', 'Global complaint oversight, executive escalation tier, and exclusive resolution verifier'),
(6, 'SYSTEM_ADMIN', 'Master system configuration, user provisioning, and role assignment')
ON DUPLICATE KEY UPDATE `description` = VALUES(`description`);

-- 2. Granular Permissions
INSERT INTO `permissions` (`permission_id`, `permission_key`, `module`, `description`) VALUES
-- Complaint Submission & Tracking
(1, 'complaint:submit_student', 'complaint', 'Submit complaint as authenticated student'),
(2, 'complaint:submit_external', 'complaint', 'Submit complaint as authenticated external user'),
(3, 'complaint:view_own', 'complaint', 'View own submitted complaints and timeline'),
(4, 'complaint:withdraw_own', 'complaint', 'Withdraw or cancel own pending complaint'),
-- Staff Operations
(5, 'complaint:view_assigned', 'staff', 'View complaints assigned to self'),
(6, 'complaint:update_investigation', 'staff', 'Add investigation notes to assigned complaint'),
(7, 'complaint:submit_resolution', 'staff', 'Submit resolution notes for verification'),
(8, 'complaint:request_escalation', 'staff', 'Request escalation to higher workflow tier'),
-- Department Reviewer Operations
(9, 'complaint:view_department_queue', 'reviewer', 'View all complaints under assigned department'),
(10, 'complaint:assign_staff', 'reviewer', 'Assign unassigned department complaint to staff'),
(11, 'complaint:reassign_staff', 'reviewer', 'Reassign department complaint between staff'),
(12, 'complaint:reject', 'reviewer', 'Reject invalid or out-of-scope complaint with reason'),
(13, 'complaint:escalate_tier', 'reviewer', 'Approve and execute workflow level escalation'),
-- Primary Complaint Officer Operations
(14, 'complaint:view_all', 'officer', 'Global visibility across all department complaints'),
(15, 'complaint:reassign_global', 'officer', 'Reassign complaint across departments and staff'),
(16, 'complaint:verify_resolution', 'officer', 'Approve resolution or return for reinvestigation'),
(17, 'staff:verify_account', 'officer', 'Verify, approve, or reject staff account registration'),
(18, 'staff:toggle_active', 'officer', 'Activate or deactivate staff system access'),
(19, 'report:view_global', 'officer', 'Generate cross-departmental and staff KPI reports'),
-- System Administration
(20, 'system:manage_users', 'admin', 'Manage user accounts and credentials'),
(21, 'system:manage_roles', 'admin', 'Assign and revoke user roles'),
(22, 'system:manage_workflow', 'admin', 'Configure workflow levels and authority mappings'),
(23, 'system:view_audit_logs', 'admin', 'Inspect immutable audit logs and history ledgers'),
(24, 'system:manage_departments', 'admin', 'Manage academic and service departments')
ON DUPLICATE KEY UPDATE `description` = VALUES(`description`);

-- 3. Role-Permission Mappings
-- STUDENT Permissions (1, 3, 4)
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(1, 1), (1, 3), (1, 4);

-- EXTERNAL_USER Permissions (2, 3, 4)
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(2, 2), (2, 3), (2, 4);

-- STAFF Permissions (5, 6, 7, 8)
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(3, 5), (3, 6), (3, 7), (3, 8);

-- DEPARTMENT_REVIEWER Permissions (5, 6, 7, 8, 9, 10, 11, 12, 13)
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(4, 5), (4, 6), (4, 7), (4, 8), (4, 9), (4, 10), (4, 11), (4, 12), (4, 13);

-- PRIMARY_COMPLAINT_OFFICER Permissions (3, 5, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 23)
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(5, 3), (5, 5), (5, 9), (5, 10), (5, 11), (5, 12), (5, 13), (5, 14), (5, 15), (5, 16), (5, 17), (5, 18), (5, 19), (5, 23);

-- SYSTEM_ADMIN Permissions (All permissions 1..24)
INSERT IGNORE INTO `role_permissions` (`role_id`, `permission_id`) VALUES
(6, 1), (6, 2), (6, 3), (6, 4), (6, 5), (6, 6), (6, 7), (6, 8), (6, 9), (6, 10),
(6, 11), (6, 12), (6, 13), (6, 14), (6, 15), (6, 16), (6, 17), (6, 18), (6, 19), (6, 20),
(6, 21), (6, 22), (6, 23), (6, 24);

COMMIT;
