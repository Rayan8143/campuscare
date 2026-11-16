-- Migration: 005_alter_existing_tables.sql
-- Purpose : Extend students, staff, complaints and complaint_history.
-- Type    : DDL only. Exactly ONE ALTER TABLE statement per table.
--           MySQL 8.0 InnoDB DDL is atomic per statement, so each table is either fully
--           migrated or untouched; a failure can never leave a half-altered table
--           (e.g. complaint_history with its old FK dropped but the new FK missing).
-- Idempotency: ALTER ... ADD COLUMN has no IF NOT EXISTS in MySQL 8.0. The runner
--              therefore asserts BEFORE this file that none of the new columns exist and
--              that complaint_history_ibfk_1 (ON DELETE CASCADE) is present, and halts on
--              any partial state with instructions to restore the checkpoint.
-- Note    : complainant_user_id is nullable here; 006 backfills it and 007 enforces NOT NULL.
--
-- Claude Stage 2 corrections (see STAGE2_CLAUDE_REVIEW.md, section 005):
--   * CRITICAL: complaint_history.old_status/new_status widened VARCHAR(30) -> VARCHAR(40).
--     'Resolution Pending Verification' is 31 characters; under STRICT_TRANS_TABLES every
--     transition into or out of that status would have failed with "Data too long".
--   * The legacy FK is dropped BY NAME (complaint_history_ibfk_1, verified in the Stage 1
--     baseline dump). The previous INFORMATION_SCHEMA lookup took "the first FK, LIMIT 1"
--     with no filter, which on any re-run could pick and drop the wrong constraint, and
--     produced a NULL statement (PREPARE error) when no FK existed.
--   * staff.designation is NULLABLE with no default: the real designation of the 15 legacy
--     staff is unknown and must not be fabricated as 'Staff Member'. Designation is
--     informational only and carries no workflow authority.
--   * complaints.external_id FK declared without explicit referential action because the
--     column is used in chk_complaint_complainant_type (InnoDB default == RESTRICT).
--   * Revision 4 - existing student FK inspected (baseline dump
--     college_complaints_baseline_20261114_185854.sql, line 119):
--       CONSTRAINT `complaints_ibfk_1` FOREIGN KEY (`student_id`) REFERENCES `students` (`student_id`)
--     It has NO ON DELETE / ON UPDATE clause, i.e. NO ACTION (behaves as RESTRICT), which is
--     compatible with a CHECK on student_id. It is therefore KEPT unchanged; no FK replacement
--     is needed and every existing student relationship is preserved. MODIFY ... NULL below
--     changes only nullability, not the FK. The runner re-verifies the live DELETE_RULE /
--     UPDATE_RULE before this file runs and halts if either is CASCADE / SET NULL / SET DEFAULT.
--   * complaints: added index for the department work queue.

SET NAMES utf8mb4;
SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

-- 1. students: link to users
ALTER TABLE `students`
  ADD COLUMN `user_id` INT NULL AFTER `academic_department_id`,
  ADD UNIQUE KEY `uq_students_user` (`user_id`),
  ADD CONSTRAINT `fk_students_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT;

-- 2. staff: link to users, informational designation, verification lifecycle, access flag
ALTER TABLE `staff`
  ADD COLUMN `user_id`             INT NULL AFTER `department_id`,
  ADD COLUMN `designation`         VARCHAR(100) NULL DEFAULT NULL AFTER `full_name`,
  ADD COLUMN `verification_status` ENUM('PENDING', 'VERIFIED', 'REJECTED') NOT NULL DEFAULT 'PENDING' AFTER `email`,
  ADD COLUMN `verified_by_user_id` INT NULL AFTER `verification_status`,
  ADD COLUMN `verified_at`         DATETIME NULL AFTER `verified_by_user_id`,
  ADD COLUMN `is_active`           BOOLEAN NOT NULL DEFAULT FALSE AFTER `verified_at`,
  ADD UNIQUE KEY `uq_staff_user` (`user_id`),
  ADD CONSTRAINT `fk_staff_user`        FOREIGN KEY (`user_id`)             REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  ADD CONSTRAINT `fk_staff_verified_by` FOREIGN KEY (`verified_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT;

-- 3. complaints: nullable student link, external link, complainant user, workflow tier,
--    soft delete, extended status domain, complainant-type exclusivity.
ALTER TABLE `complaints`
  MODIFY COLUMN `student_id` INT NULL,
  ADD COLUMN `external_id`         INT NULL AFTER `student_id`,
  ADD COLUMN `complainant_user_id` INT NULL AFTER `external_id`,
  ADD COLUMN `current_level_id`    INT NOT NULL DEFAULT 1 AFTER `assigned_staff_id`,
  ADD COLUMN `is_deleted`          BOOLEAN  NOT NULL DEFAULT FALSE,
  ADD COLUMN `deleted_at`          DATETIME NULL DEFAULT NULL,
  ADD COLUMN `deleted_by_user_id`  INT      NULL DEFAULT NULL,
  MODIFY COLUMN `status` ENUM(
    'Submitted',
    'In Progress',
    'Escalated',
    'Resolution Pending Verification',
    'Resolved',
    'Rejected'
  ) NOT NULL DEFAULT 'Submitted',
  ADD KEY `idx_complaints_dept_queue` (`department_id`, `is_deleted`, `status`),
  ADD CONSTRAINT `fk_complaints_external`       FOREIGN KEY (`external_id`)         REFERENCES `external_complainants`(`external_id`),
  ADD CONSTRAINT `fk_complaints_complainant`    FOREIGN KEY (`complainant_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  ADD CONSTRAINT `fk_complaints_workflow_level` FOREIGN KEY (`current_level_id`)    REFERENCES `workflow_levels`(`level_id`) ON DELETE RESTRICT,
  ADD CONSTRAINT `fk_complaints_deleted_by`     FOREIGN KEY (`deleted_by_user_id`)  REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  ADD CONSTRAINT `chk_complaint_complainant_type` CHECK (
    (`student_id` IS NOT NULL AND `external_id` IS NULL) OR
    (`student_id` IS NULL     AND `external_id` IS NOT NULL)
  );

-- 4. complaint_history: replace ON DELETE CASCADE with RESTRICT (audit must survive),
--    widen status columns, add actor attribution and action type. Single atomic ALTER.
--    MySQL only supports DROP FOREIGN KEY + ADD FOREIGN KEY in the same statement with
--    ALGORITHM=INPLACE, and INPLACE FK creation requires foreign_key_checks = 0 for this
--    session. That is safe here: every existing complaint_history.complaint_id is already
--    guaranteed valid by the FK being replaced, and changed_by_user_id is a new all-NULL
--    column. ALGORITHM=INPLACE is explicit so MySQL errors out (changing nothing) rather
--    than silently choosing another algorithm. The runner verifies both FKs afterwards.
SET SESSION foreign_key_checks = 0;
ALTER TABLE `complaint_history`
  ALGORITHM = INPLACE,
  DROP FOREIGN KEY `complaint_history_ibfk_1`,
  MODIFY COLUMN `old_status` VARCHAR(40) NULL DEFAULT NULL,
  MODIFY COLUMN `new_status` VARCHAR(40) NOT NULL,
  ADD COLUMN `changed_by_user_id` INT NULL AFTER `changed_at`,
  ADD COLUMN `action_type` VARCHAR(40) NOT NULL DEFAULT 'STATUS_CHANGE' AFTER `changed_by_user_id`,
  ADD CONSTRAINT `fk_complaint_history_complaint` FOREIGN KEY (`complaint_id`)       REFERENCES `complaints`(`complaint_id`) ON DELETE RESTRICT,
  ADD CONSTRAINT `fk_complaint_history_user`      FOREIGN KEY (`changed_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT;

SET SESSION foreign_key_checks = 1;
