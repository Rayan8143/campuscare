-- S2_B_post_migration_grants.sql
-- Run ONCE as a MySQL administrative account AFTER run_migrations.py has applied 000-008.
-- NOT executed by run_migrations.py. Only `college_complaints_v2_dev` is referenced.
-- Rationale for every grant: STAGE2_SECURITY_GRANTS.md.

-- =====================================================================================
-- 1. Routine definer: exactly what the procedures in 008 read and write.
-- =====================================================================================
GRANT SELECT ON `college_complaints_v2_dev`.`workflow_levels`           TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`staff`                      TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`roles`                      TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`permissions`                TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`role_permissions`           TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`staff_workflow_assignments` TO 'cc_v2_dev_routine_definer'@'localhost';

GRANT SELECT ON `college_complaints_v2_dev`.`departments`           TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`students`              TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`external_complainants` TO 'cc_v2_dev_routine_definer'@'localhost';

GRANT SELECT,
      INSERT (`student_id`, `external_id`, `complainant_user_id`, `department_id`,
              `title`, `description`, `category`, `priority`),
      UPDATE (`status`, `resolved_at`, `assigned_staff_id`, `department_id`, `current_level_id`,
              `is_deleted`, `deleted_at`, `deleted_by_user_id`,
              `title`, `description`, `category`, `priority`)
   ON `college_complaints_v2_dev`.`complaints` TO 'cc_v2_dev_routine_definer'@'localhost';

GRANT SELECT ON `college_complaints_v2_dev`.`complaint_assignments` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT INSERT ON `college_complaints_v2_dev`.`complaint_assignments` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT UPDATE (`is_active`, `unassigned_at`, `unassigned_by_user_id`)
   ON `college_complaints_v2_dev`.`complaint_assignments` TO 'cc_v2_dev_routine_definer'@'localhost';

GRANT INSERT ON `college_complaints_v2_dev`.`complaint_history`     TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT INSERT ON `college_complaints_v2_dev`.`complaint_escalations` TO 'cc_v2_dev_routine_definer'@'localhost';

GRANT SELECT ON `college_complaints_v2_dev`.`resolution_verifications` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT INSERT ON `college_complaints_v2_dev`.`resolution_verifications` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT UPDATE (`decision`, `officer_user_id`, `officer_remarks`, `reviewed_at`)
   ON `college_complaints_v2_dev`.`resolution_verifications` TO 'cc_v2_dev_routine_definer'@'localhost';

-- primary_officer_assignment: SELECT (singleton read, FOR UPDATE lock), INSERT (initial
-- bootstrap row in transfer_primary_officer), column UPDATE (transfer). R5: INSERT is stated
-- as its own statement so the bootstrap privilege is explicit.
GRANT SELECT ON `college_complaints_v2_dev`.`primary_officer_assignment` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT INSERT ON `college_complaints_v2_dev`.`primary_officer_assignment` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT UPDATE (`user_id`, `assigned_by_user_id`, `previous_officer_user_id`, `transition_reason`, `assigned_at`)
   ON `college_complaints_v2_dev`.`primary_officer_assignment` TO 'cc_v2_dev_routine_definer'@'localhost';

GRANT INSERT ON `college_complaints_v2_dev`.`primary_officer_history` TO 'cc_v2_dev_routine_definer'@'localhost';

GRANT SELECT ON `college_complaints_v2_dev`.`user_roles` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT INSERT ON `college_complaints_v2_dev`.`user_roles` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT UPDATE (`is_active`, `assigned_at`)
   ON `college_complaints_v2_dev`.`user_roles` TO 'cc_v2_dev_routine_definer'@'localhost';

GRANT SELECT, UPDATE (`password_hash`, `is_active`)
   ON `college_complaints_v2_dev`.`users` TO 'cc_v2_dev_routine_definer'@'localhost';

GRANT SELECT ON `college_complaints_v2_dev`.`account_activations` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT INSERT ON `college_complaints_v2_dev`.`account_activations` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT UPDATE (`revoked_at`, `used_at`)
   ON `college_complaints_v2_dev`.`account_activations` TO 'cc_v2_dev_routine_definer'@'localhost';

-- Locking reads (MySQL 8.0.22+):
--   * SELECT ... FOR SHARE  requires SELECT only (used on: staff, in reassign_complaint).
--   * SELECT ... FOR UPDATE requires SELECT plus at least one of UPDATE, DELETE or LOCK TABLES
--     on the locked table (used on: complaints, users, primary_officer_assignment,
--     account_activations). This account holds COLUMN-level UPDATE on each of those tables;
--     whether column-level UPDATE satisfies the FOR UPDATE check is not documented, so a
--     schema-level LOCK TABLES grant is added as a precaution (LOCK TABLES has no table-level
--     form). It adds no reachable capability: the account is ACCOUNT LOCKed, so nobody can log
--     in to issue LOCK TABLES, and no routine contains LOCK TABLES. If execution evidence shows
--     column-level UPDATE suffices, this grant can be revoked.
GRANT LOCK TABLES ON `college_complaints_v2_dev`.* TO 'cc_v2_dev_routine_definer'@'localhost';

-- Internal helpers are called by the public procedures, which run as this definer.
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`cc_auth_has_permission`       TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`cc_auth_is_primary_officer`   TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`cc_auth_department_authority` TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`cc_auth_is_assigned_staff`    TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`cc_auth_staff_eligible`       TO 'cc_v2_dev_routine_definer'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`cc_token_issue_core`          TO 'cc_v2_dev_routine_definer'@'localhost';

-- =====================================================================================
-- 2. Trigger definer: TRIGGER + SELECT on the subject table (OLD./NEW. references), the
--    lookups the triggers perform, and INSERT into the history table.
-- =====================================================================================
GRANT TRIGGER, SELECT ON `college_complaints_v2_dev`.`complaints`         TO 'cc_v2_dev_trigger_definer'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`students`                    TO 'cc_v2_dev_trigger_definer'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`external_complainants`       TO 'cc_v2_dev_trigger_definer'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`complaint_assignments`       TO 'cc_v2_dev_trigger_definer'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`complaint_escalations`       TO 'cc_v2_dev_trigger_definer'@'localhost';
GRANT INSERT ON `college_complaints_v2_dev`.`complaint_history`           TO 'cc_v2_dev_trigger_definer'@'localhost';

-- =====================================================================================
-- 3. Flask runtime account: remove the schema-wide grant (schema-level UPDATE cannot be
--    narrowed by column-level REVOKE), then grant least privilege explicitly.
-- =====================================================================================
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'complaint_app_v2_dev'@'localhost';

-- 3a. Read access (not schema_migrations, not account_activations)
GRANT SELECT ON `college_complaints_v2_dev`.`academic_departments`       TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`departments`                TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`students`                   TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`staff`                      TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`complaints`                 TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`complaint_history`          TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`roles`                      TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`permissions`                TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`role_permissions`           TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`users`                      TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`user_roles`                 TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`external_complainants`      TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`workflow_levels`            TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`staff_workflow_assignments` TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`primary_officer_assignment` TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`primary_officer_history`    TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`complaint_assignments`      TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`complaint_escalations`      TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`resolution_verifications`   TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`notifications`              TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`complaint_details`            TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`open_complaints`              TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`pending_complaints`           TO 'complaint_app_v2_dev'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`department_complaint_summary` TO 'complaint_app_v2_dev'@'localhost';

-- 3b. NO INSERT and NO UPDATE on complaints (revision 3, decision R13): creation goes through
--     submit_complaint and detail edits through update_complaint_details, both of which derive
--     authority from the authenticated actor; workflow columns change only via procedures.

-- 3c. Notifications
GRANT INSERT (`user_id`, `complaint_id`, `title`, `message`)
   ON `college_complaints_v2_dev`.`notifications` TO 'complaint_app_v2_dev'@'localhost';
GRANT UPDATE (`is_read`)
   ON `college_complaints_v2_dev`.`notifications` TO 'complaint_app_v2_dev'@'localhost';

-- 3d. Explicitly required procedures only (helpers cc_auth_* / cc_token_issue_core and the
--     dev-only issue_account_token_operator are NOT granted)
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`submit_complaint`            TO 'complaint_app_v2_dev'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`request_escalation`          TO 'complaint_app_v2_dev'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`update_complaint_details`    TO 'complaint_app_v2_dev'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`transition_complaint_status` TO 'complaint_app_v2_dev'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`escalate_complaint`          TO 'complaint_app_v2_dev'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`reassign_complaint`          TO 'complaint_app_v2_dev'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`soft_delete_complaint`       TO 'complaint_app_v2_dev'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`transfer_primary_officer`    TO 'complaint_app_v2_dev'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`issue_account_token`         TO 'complaint_app_v2_dev'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`redeem_account_token`        TO 'complaint_app_v2_dev'@'localhost';

-- =====================================================================================
-- 3e. Development activation CLI account (cli_activation.py only; never used by Flask).
--     Operator issuance, redemption, and the minimal reads for --list-pending / e-mail lookup.
--     No access to password hashes or token hashes.
-- =====================================================================================
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'cc_v2_dev_activation_cli'@'localhost';
GRANT SELECT (`user_id`, `email`, `full_name`, `is_active`)
   ON `college_complaints_v2_dev`.`users` TO 'cc_v2_dev_activation_cli'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`user_roles` TO 'cc_v2_dev_activation_cli'@'localhost';
GRANT SELECT ON `college_complaints_v2_dev`.`roles`      TO 'cc_v2_dev_activation_cli'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`issue_account_token_operator` TO 'cc_v2_dev_activation_cli'@'localhost';
GRANT EXECUTE ON PROCEDURE `college_complaints_v2_dev`.`redeem_account_token`         TO 'cc_v2_dev_activation_cli'@'localhost';

-- =====================================================================================
-- 4. Remove the migrator's temporary definer-impersonation privilege. (automatic_sp_privileges
--    adds per-routine EXECUTE/ALTER ROUTINE only when the creator lacks them; the migrator
--    holds both at schema level, so no per-routine grants should appear. The runner's grant
--    allowlist tolerates such lines only for this schema and only EXECUTE / ALTER ROUTINE.)
-- =====================================================================================
REVOKE SET_USER_ID ON *.* FROM 'complaint_migrator_v2_dev'@'localhost';

-- =====================================================================================
-- 5. Verification (read-only): inspect before running S2_C / S2_D.
-- =====================================================================================
SHOW GRANTS FOR 'complaint_app_v2_dev'@'localhost';
SHOW GRANTS FOR 'complaint_migrator_v2_dev'@'localhost';
SHOW GRANTS FOR 'cc_v2_dev_routine_definer'@'localhost';
SHOW GRANTS FOR 'cc_v2_dev_trigger_definer'@'localhost';
SHOW GRANTS FOR 'cc_v2_dev_activation_cli'@'localhost';

SELECT ROUTINE_NAME, DEFINER, SECURITY_TYPE
  FROM information_schema.ROUTINES
 WHERE ROUTINE_SCHEMA = 'college_complaints_v2_dev'
 ORDER BY ROUTINE_NAME;
SELECT TRIGGER_NAME, EVENT_MANIPULATION, ACTION_TIMING, DEFINER
  FROM information_schema.TRIGGERS
 WHERE TRIGGER_SCHEMA = 'college_complaints_v2_dev'
 ORDER BY TRIGGER_NAME;
SELECT TABLE_NAME, SECURITY_TYPE, DEFINER
  FROM information_schema.VIEWS
 WHERE TABLE_SCHEMA = 'college_complaints_v2_dev'
 ORDER BY TABLE_NAME;
