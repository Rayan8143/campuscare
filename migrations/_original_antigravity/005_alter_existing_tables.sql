-- Migration: 005_alter_existing_tables.sql
-- Purpose: Schema extensions to students, staff, complaints, and complaint_history
-- Note: complainant_user_id is added as nullable here; enforced NOT NULL in 007 after backfill

-- 1. Alter students table: add user_id
ALTER TABLE `students`
  ADD COLUMN `user_id` INT NULL UNIQUE AFTER `academic_department_id`,
  ADD CONSTRAINT `fk_students_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT;

-- 2. Alter staff table: add user_id, designation, verification fields
ALTER TABLE `staff`
  ADD COLUMN `user_id` INT NULL UNIQUE AFTER `department_id`,
  ADD COLUMN `designation` VARCHAR(100) NOT NULL DEFAULT 'Staff Member' AFTER `full_name`,
  ADD COLUMN `verification_status` ENUM('PENDING', 'VERIFIED', 'REJECTED') NOT NULL DEFAULT 'PENDING' AFTER `email`,
  ADD COLUMN `verified_by_user_id` INT NULL AFTER `verification_status`,
  ADD COLUMN `verified_at` DATETIME NULL AFTER `verified_by_user_id`,
  ADD COLUMN `is_active` BOOLEAN NOT NULL DEFAULT FALSE AFTER `verified_at`,
  ADD CONSTRAINT `fk_staff_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  ADD CONSTRAINT `fk_staff_verified_by` FOREIGN KEY (`verified_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT;

-- 3. Alter complaints table:
-- Modify student_id to allow NULL (for external complaints)
ALTER TABLE `complaints` MODIFY COLUMN `student_id` INT NULL;

-- Add external link, complainant user link (nullable for backfill), workflow tier, soft delete
ALTER TABLE `complaints`
  ADD COLUMN `external_id` INT NULL AFTER `student_id`,
  ADD COLUMN `complainant_user_id` INT NULL AFTER `external_id`,
  ADD COLUMN `current_level_id` INT NOT NULL DEFAULT 1 AFTER `assigned_staff_id`,
  ADD COLUMN `is_deleted` BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN `deleted_at` DATETIME NULL,
  ADD COLUMN `deleted_by_user_id` INT NULL,
  ADD CONSTRAINT `fk_complaints_external` FOREIGN KEY (`external_id`) REFERENCES `external_complainants`(`external_id`) ON DELETE RESTRICT,
  ADD CONSTRAINT `fk_complaints_complainant` FOREIGN KEY (`complainant_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  ADD CONSTRAINT `fk_complaints_workflow_level` FOREIGN KEY (`current_level_id`) REFERENCES `workflow_levels`(`level_id`) ON DELETE RESTRICT,
  ADD CONSTRAINT `fk_complaints_deleted_by` FOREIGN KEY (`deleted_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT;

-- Extend status ENUM to include all workflow states
ALTER TABLE `complaints`
  MODIFY COLUMN `status` ENUM(
    'Submitted',
    'In Progress',
    'Escalated',
    'Resolution Pending Verification',
    'Resolved',
    'Rejected'
  ) NOT NULL DEFAULT 'Submitted';

-- Enforce mutual exclusivity of student vs external complainant
ALTER TABLE `complaints`
  ADD CONSTRAINT `chk_complaint_complainant_type`
  CHECK (
    (`student_id` IS NOT NULL AND `external_id` IS NULL) OR
    (`student_id` IS NULL AND `external_id` IS NOT NULL)
  );

-- 4. Alter complaint_history table:
-- Dynamic introspection of foreign key to drop CASCADE safely
SET @fk_name = (
  SELECT CONSTRAINT_NAME 
  FROM information_schema.TABLE_CONSTRAINTS 
  WHERE TABLE_SCHEMA = DATABASE() 
    AND TABLE_NAME = 'complaint_history' 
    AND CONSTRAINT_TYPE = 'FOREIGN KEY' 
  LIMIT 1
);

SET @drop_fk_stmt = CONCAT('ALTER TABLE `complaint_history` DROP FOREIGN KEY `', @fk_name, '`;');
PREPARE stmt_drop_fk FROM @drop_fk_stmt;
EXECUTE stmt_drop_fk;
DEALLOCATE PREPARE stmt_drop_fk;

-- Add replacement foreign key with ON DELETE RESTRICT
ALTER TABLE `complaint_history`
  ADD CONSTRAINT `fk_complaint_history_complaint`
  FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE RESTRICT;

-- Add actor tracking and action type
ALTER TABLE `complaint_history`
  ADD COLUMN `changed_by_user_id` INT NULL AFTER `changed_at`,
  ADD COLUMN `action_type` VARCHAR(40) NOT NULL DEFAULT 'STATUS_CHANGE' AFTER `changed_by_user_id`,
  ADD CONSTRAINT `fk_complaint_history_user` FOREIGN KEY (`changed_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT;
