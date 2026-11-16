-- Migration: 004_assignment_and_audit.sql
-- Purpose: Create canonical assignment ledger with generated column uniqueness, escalations, verifications, and notifications
-- Note: assigned_by_user_id allows NULL for legacy migrated rows, but procedure requires non-null for new assignments

-- 1. Canonical Assignment Ledger
CREATE TABLE IF NOT EXISTS `complaint_assignments` (
  `assignment_id` INT AUTO_INCREMENT PRIMARY KEY,
  `complaint_id` INT NOT NULL,
  `assigned_staff_id` INT NOT NULL,
  `assigned_by_user_id` INT NULL, -- NULL allowed for legacy migrated rows
  `assignment_reason` VARCHAR(255) DEFAULT NULL,
  `assigned_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `unassigned_at` DATETIME DEFAULT NULL,
  `is_active` BOOLEAN NOT NULL DEFAULT TRUE,
  -- Deterministic Conditional Uniqueness:
  `active_complaint_id` INT GENERATED ALWAYS AS (
    CASE WHEN `is_active` = TRUE THEN `complaint_id` ELSE NULL END
  ) STORED,
  UNIQUE KEY `uq_single_active_assignment` (`active_complaint_id`),
  FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`assigned_staff_id`) REFERENCES `staff`(`staff_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`assigned_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  INDEX `idx_assignments_staff_active` (`assigned_staff_id`, `is_active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 2. Complaint Escalations Log
CREATE TABLE IF NOT EXISTS `complaint_escalations` (
  `escalation_id` INT AUTO_INCREMENT PRIMARY KEY,
  `complaint_id` INT NOT NULL,
  `from_level_id` INT NOT NULL,
  `to_level_id` INT NOT NULL,
  `escalated_by_user_id` INT NOT NULL,
  `escalation_reason` TEXT NOT NULL,
  `action_taken` TEXT DEFAULT NULL,
  `escalated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`from_level_id`) REFERENCES `workflow_levels`(`level_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`to_level_id`) REFERENCES `workflow_levels`(`level_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`escalated_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 3. Resolution Verification Ledger
CREATE TABLE IF NOT EXISTS `resolution_verifications` (
  `verification_id` INT AUTO_INCREMENT PRIMARY KEY,
  `complaint_id` INT NOT NULL,
  `submitted_by_staff_id` INT NOT NULL,
  `resolution_notes` TEXT NOT NULL,
  `officer_user_id` INT DEFAULT NULL,
  `decision` ENUM('PENDING', 'APPROVED', 'RETURNED') NOT NULL DEFAULT 'PENDING',
  `officer_remarks` TEXT DEFAULT NULL,
  `submitted_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `reviewed_at` DATETIME DEFAULT NULL,
  FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`submitted_by_staff_id`) REFERENCES `staff`(`staff_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`officer_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 4. In-App Notifications Center
CREATE TABLE IF NOT EXISTS `notifications` (
  `notification_id` INT AUTO_INCREMENT PRIMARY KEY,
  `user_id` INT NOT NULL,
  `complaint_id` INT DEFAULT NULL,
  `title` VARCHAR(150) NOT NULL,
  `message` TEXT NOT NULL,
  `is_read` BOOLEAN NOT NULL DEFAULT FALSE,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX `idx_notif_user_unread` (`user_id`, `is_read`),
  FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE CASCADE,
  FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 5. Stored Procedure: reassign_complaint (Requires authenticated user for all new assignments)
DROP PROCEDURE IF EXISTS `reassign_complaint`;
DELIMITER $$
CREATE PROCEDURE `reassign_complaint`(
    IN p_complaint_id INT,
    IN p_new_staff_id INT,
    IN p_acting_user_id INT,
    IN p_reason VARCHAR(255)
)
BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- Strict validation: authenticated assigning actor is mandatory for new assignments
    IF p_acting_user_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Authenticated user ID is required for reassignments.';
    END IF;

    START TRANSACTION;

    -- 1. Deactivate existing active assignment
    UPDATE complaint_assignments
    SET is_active = FALSE, unassigned_at = NOW()
    WHERE complaint_id = p_complaint_id AND is_active = TRUE;

    -- 2. Insert new active assignment (protected by uq_single_active_assignment)
    INSERT INTO complaint_assignments (
        complaint_id, assigned_staff_id, assigned_by_user_id, assignment_reason, is_active
    ) VALUES (
        p_complaint_id, p_new_staff_id, p_acting_user_id, p_reason, TRUE
    );

    -- 3. Synchronize cached pointer in complaints table
    UPDATE complaints
    SET assigned_staff_id = p_new_staff_id
    WHERE complaint_id = p_complaint_id;

    COMMIT;
END$$
DELIMITER ;
