-- Migration: 003_workflow_and_singleton.sql
-- Purpose: Create workflow tiers, decoupled workflow assignments, singleton Primary Officer table, and transfer procedure

-- 1. Deterministic Workflow Tiers Master Table
CREATE TABLE IF NOT EXISTS `workflow_levels` (
  `level_id` INT PRIMARY KEY,
  `level_number` INT NOT NULL UNIQUE,
  `level_name` VARCHAR(60) NOT NULL UNIQUE,
  `description` VARCHAR(255) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Deterministic Seeding: IDs 1 through 4 are fixed
INSERT INTO `workflow_levels` (`level_id`, `level_number`, `level_name`, `description`) VALUES
(1, 1, 'Level 1: Frontline Staff', 'Operational investigation and direct resolution by assigned department staff'),
(2, 2, 'Level 2: Department Reviewer', 'Supervisory oversight, triage, department reassignment, and initial escalation'),
(3, 3, 'Level 3: Department Head', 'Institutional escalation for unresolvable departmental issues or SLA breaches'),
(4, 4, 'Level 4: Primary Complaint Officer', 'Highest executive authority, exclusive resolution verification, and global intervention')
ON DUPLICATE KEY UPDATE 
  `level_name` = VALUES(`level_name`), 
  `description` = VALUES(`description`);

-- 2. Staff Workflow Assignments (Decoupled from job designations)
CREATE TABLE IF NOT EXISTS `staff_workflow_assignments` (
  `assignment_id` INT AUTO_INCREMENT PRIMARY KEY,
  `user_id` INT NOT NULL,
  `department_id` INT NOT NULL,
  `level_id` INT NOT NULL,
  `can_escalate` BOOLEAN NOT NULL DEFAULT FALSE,
  `can_resolve` BOOLEAN NOT NULL DEFAULT TRUE,
  `assigned_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY `uk_staff_workflow_mapping` (`user_id`, `department_id`, `level_id`),
  FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE CASCADE,
  FOREIGN KEY (`department_id`) REFERENCES `departments`(`department_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`level_id`) REFERENCES `workflow_levels`(`level_id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 3. Primary Officer Singleton Authority Table
CREATE TABLE IF NOT EXISTS `primary_officer_assignment` (
  `singleton_id` TINYINT PRIMARY KEY DEFAULT 1,
  `user_id` INT NOT NULL,
  `assigned_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  `assigned_by_user_id` INT NOT NULL,
  `previous_officer_user_id` INT NULL,
  `transition_reason` VARCHAR(255) DEFAULT 'Initial Bootstrap',
  CONSTRAINT `chk_singleton_single_row` CHECK (`singleton_id` = 1),
  FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`assigned_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`previous_officer_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 4. Primary Officer Executive Transfer History
CREATE TABLE IF NOT EXISTS `primary_officer_history` (
  `history_id` INT AUTO_INCREMENT PRIMARY KEY,
  `officer_user_id` INT NOT NULL,
  `appointed_by_user_id` INT NOT NULL,
  `started_at` DATETIME NOT NULL,
  `ended_at` DATETIME NOT NULL,
  `transition_reason` VARCHAR(255) NOT NULL,
  FOREIGN KEY (`officer_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`appointed_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 5. Stored Procedure: transfer_primary_officer
DROP PROCEDURE IF EXISTS `transfer_primary_officer`;
DELIMITER $$
CREATE PROCEDURE `transfer_primary_officer`(
    IN p_new_officer_user_id INT,
    IN p_acting_admin_user_id INT,
    IN p_reason VARCHAR(255)
)
BEGIN
    DECLARE v_current_officer_user_id INT;
    DECLARE v_current_started_at TIMESTAMP;
    DECLARE v_officer_role_id INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT role_id INTO v_officer_role_id FROM roles WHERE role_name = 'PRIMARY_COMPLAINT_OFFICER';

    -- Check if singleton row exists
    IF EXISTS (SELECT 1 FROM primary_officer_assignment WHERE singleton_id = 1) THEN
        SELECT user_id, assigned_at 
        INTO v_current_officer_user_id, v_current_started_at
        FROM primary_officer_assignment 
        WHERE singleton_id = 1 
        FOR UPDATE;

        IF v_current_officer_user_id IS NOT NULL THEN
            -- Archive previous officer tenure
            INSERT INTO primary_officer_history (
                officer_user_id, appointed_by_user_id, started_at, ended_at, transition_reason
            ) VALUES (
                v_current_officer_user_id, p_acting_admin_user_id, v_current_started_at, NOW(), p_reason
            );

            -- Deactivate role for previous officer
            UPDATE user_roles 
            SET is_active = FALSE 
            WHERE user_id = v_current_officer_user_id AND role_id = v_officer_role_id;
        END IF;

        -- Update singleton record
        UPDATE primary_officer_assignment
        SET user_id = p_new_officer_user_id,
            assigned_by_user_id = p_acting_admin_user_id,
            previous_officer_user_id = v_current_officer_user_id,
            transition_reason = p_reason,
            assigned_at = NOW()
        WHERE singleton_id = 1;
    ELSE
        -- Initial insertion of singleton row
        INSERT INTO primary_officer_assignment (
            singleton_id, user_id, assigned_by_user_id, previous_officer_user_id, transition_reason
        ) VALUES (
            1, p_new_officer_user_id, p_acting_admin_user_id, NULL, p_reason
        );
    END IF;

    -- Activate role for new officer
    INSERT INTO user_roles (user_id, role_id, is_active)
    VALUES (p_new_officer_user_id, v_officer_role_id, TRUE)
    ON DUPLICATE KEY UPDATE is_active = TRUE;

    COMMIT;
END$$
DELIMITER ;
