-- Migration: 003_workflow_and_singleton.sql
-- Purpose : Workflow tiers, decoupled workflow memberships, Primary Officer singleton and history.
-- Type    : DDL (implicit commits) followed by ONE explicit DML transaction (workflow_levels seed).
--           The seed is deterministic and idempotent, so it never needs to roll back with the DDL.
--
-- Claude Stage 2 corrections (see STAGE2_CLAUDE_REVIEW.md, section 003):
--   * transfer_primary_officer MOVED to 008 so every routine is created in one place with
--     an explicit restricted DEFINER. (The 003 version had no actor validation, recorded
--     the wrong appointer in history, and checked for the singleton row without a lock.)
--   * staff_workflow_assignments: level_id restricted to 1..3. Level 4 authority belongs
--     exclusively to the primary_officer_assignment singleton, never to a membership row,
--     so it cannot be granted by inserting a membership.
--   * primary_officer_history now records who appointed the officer AND who ended the
--     tenure, with separate appointment/end reasons (previously the person ending the
--     tenure was stored as "appointed_by").
--   * FKs on columns used in CHECK constraints are declared without an explicit referential
--     action (InnoDB default = NO ACTION, semantically RESTRICT) to stay clear of MySQL's
--     "CHECK column used in FK referential action" restriction (ER 3823).

SET NAMES utf8mb4;
SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

-- 1. Workflow tier master table (IDs are fixed: level_id = level_number)
CREATE TABLE IF NOT EXISTS `workflow_levels` (
  `level_id`     INT          NOT NULL PRIMARY KEY,
  `level_number` INT          NOT NULL,
  `level_name`   VARCHAR(60)  NOT NULL,
  `description`  VARCHAR(255) DEFAULT NULL,
  UNIQUE KEY `uq_workflow_level_number` (`level_number`),
  UNIQUE KEY `uq_workflow_level_name` (`level_name`),
  CONSTRAINT `chk_workflow_level_range` CHECK (`level_number` BETWEEN 1 AND 4)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 2. Staff workflow memberships (independent of employment designation)
--    A row grants department-scoped workflow authority at levels 1..3.
CREATE TABLE IF NOT EXISTS `staff_workflow_assignments` (
  `assignment_id` INT AUTO_INCREMENT PRIMARY KEY,
  `user_id`       INT       NOT NULL,
  `department_id` INT       NOT NULL,
  `level_id`      INT       NOT NULL,
  `can_escalate`  BOOLEAN   NOT NULL DEFAULT FALSE,
  `can_resolve`   BOOLEAN   NOT NULL DEFAULT TRUE,   -- may SUBMIT a resolution; final approval is officer-only
  `assigned_at`   TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY `uk_staff_workflow_mapping` (`user_id`, `department_id`, `level_id`),
  KEY `idx_swa_department_level` (`department_id`, `level_id`),
  CONSTRAINT `chk_swa_level_not_officer_tier` CHECK (`level_id` BETWEEN 1 AND 3),
  CONSTRAINT `fk_swa_user`       FOREIGN KEY (`user_id`)       REFERENCES `users`(`user_id`) ON DELETE CASCADE,
  CONSTRAINT `fk_swa_department` FOREIGN KEY (`department_id`) REFERENCES `departments`(`department_id`) ON DELETE RESTRICT,
  CONSTRAINT `fk_swa_level`      FOREIGN KEY (`level_id`)      REFERENCES `workflow_levels`(`level_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 3. Primary Officer singleton: the PK plus CHECK(singleton_id = 1) make a second row impossible.
--    The table starts EMPTY; the first appointment (bootstrap) is made by transfer_primary_officer.
CREATE TABLE IF NOT EXISTS `primary_officer_assignment` (
  `singleton_id`             TINYINT      NOT NULL DEFAULT 1,
  `user_id`                  INT          NOT NULL,
  `assigned_at`              DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `assigned_by_user_id`      INT          NOT NULL,
  `previous_officer_user_id` INT          NULL,
  `transition_reason`        VARCHAR(255) NOT NULL,
  PRIMARY KEY (`singleton_id`),
  CONSTRAINT `chk_singleton_single_row` CHECK (`singleton_id` = 1),
  CONSTRAINT `fk_poa_user`        FOREIGN KEY (`user_id`)                  REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  CONSTRAINT `fk_poa_assigned_by` FOREIGN KEY (`assigned_by_user_id`)      REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  CONSTRAINT `fk_poa_previous`    FOREIGN KEY (`previous_officer_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 4. Primary Officer tenure history (one row per ENDED tenure; the current tenure lives in the singleton)
CREATE TABLE IF NOT EXISTS `primary_officer_history` (
  `history_id`           INT AUTO_INCREMENT PRIMARY KEY,
  `officer_user_id`      INT          NOT NULL,
  `appointed_by_user_id` INT          NOT NULL,
  `appointment_reason`   VARCHAR(255) NOT NULL,
  `started_at`           DATETIME     NOT NULL,
  `ended_at`             DATETIME     NOT NULL,
  `ended_by_user_id`     INT          NOT NULL,
  `end_reason`           VARCHAR(255) NOT NULL,
  KEY `idx_poh_officer` (`officer_user_id`),
  CONSTRAINT `chk_poh_tenure_order` CHECK (`ended_at` >= `started_at`),
  CONSTRAINT `fk_poh_officer`      FOREIGN KEY (`officer_user_id`)      REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  CONSTRAINT `fk_poh_appointed_by` FOREIGN KEY (`appointed_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  CONSTRAINT `fk_poh_ended_by`     FOREIGN KEY (`ended_by_user_id`)     REFERENCES `users`(`user_id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 5. Deterministic seed of the four workflow tiers (transactional DML, after all DDL above)
START TRANSACTION;

INSERT INTO `workflow_levels` (`level_id`, `level_number`, `level_name`, `description`) VALUES
(1, 1, 'Level 1: Frontline Staff',          'Operational investigation and direct resolution work by assigned department staff'),
(2, 2, 'Level 2: Department Reviewer',      'Supervisory oversight, triage, department reassignment and initial escalation'),
(3, 3, 'Level 3: Department Head',          'Institutional escalation for unresolvable departmental issues or SLA breaches'),
(4, 4, 'Level 4: Primary Complaint Officer','Highest authority (singleton officer only), exclusive resolution verification and global intervention')
ON DUPLICATE KEY UPDATE
  `level_number` = VALUES(`level_number`),
  `level_name`   = VALUES(`level_name`),
  `description`  = VALUES(`description`);

COMMIT;
