-- Migration: 004_assignment_and_audit.sql
-- Purpose : Canonical assignment ledger, escalation ledger, resolution-verification ledger,
--           in-app notifications.
-- Type    : DDL only (implicit commits). No DML.
--
-- Claude Stage 2 corrections (see STAGE2_CLAUDE_REVIEW.md, section 004):
--   * reassign_complaint MOVED to 008 (explicit restricted DEFINER; the 004 version had no
--     authorization, department, staff-eligibility, state or locking checks).
--   * complaint_assignments:
--       - assignment_source ('LEGACY_IMPORT' | 'WORKFLOW') + CHECK: every WORKFLOW row must
--         carry assigned_by_user_id AND assigned_at. Only legacy imported rows may have a
--         NULL actor -> "all new assignments require an authenticated actor" is enforced by
--         the schema, not only by procedure code.
--       - assigned_at is NULL for legacy rows: the original v1 assignment time is unknown
--         and must not be fabricated. recorded_at records when the ledger row was written.
--       - unassigned_by_user_id records who ended an assignment.
--       - CHECK keeps is_active and unassigned_at consistent.
--       - The generated-column unique index (uq_single_active_assignment) is unchanged in
--         principle: active_complaint_id = complaint_id when active, NULL otherwise;
--         NULLs are not unique-checked, so unlimited inactive history rows are allowed but
--         a second active row for the same complaint fails with ER_DUP_ENTRY (1062).
--   * complaint_escalations: CHECK from_level_id <> to_level_id (direction is validated by
--     escalate_complaint using level_number).
--   * resolution_verifications: generated pending_complaint_id + UNIQUE => at most one
--     PENDING verification per complaint; CHECK keeps decision/officer/reviewed_at consistent.
--   * FKs on CHECK-referenced or generated-column base columns are declared without an
--     explicit referential action (InnoDB default NO ACTION == RESTRICT).

SET NAMES utf8mb4;
SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

-- 1. Canonical assignment ledger
CREATE TABLE IF NOT EXISTS `complaint_assignments` (
  `assignment_id`         INT AUTO_INCREMENT PRIMARY KEY,
  `complaint_id`          INT          NOT NULL,
  `assigned_staff_id`     INT          NOT NULL,
  `assigned_by_user_id`   INT          NULL,        -- NULL only for assignment_source = 'LEGACY_IMPORT'
  `assignment_source`     ENUM('LEGACY_IMPORT', 'WORKFLOW') NOT NULL DEFAULT 'WORKFLOW',
  `assignment_reason`     VARCHAR(255) DEFAULT NULL,
  `assigned_at`           DATETIME     NULL DEFAULT NULL,   -- NULL only for legacy rows (time unknown)
  `recorded_at`           TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `unassigned_at`         DATETIME     NULL DEFAULT NULL,
  `unassigned_by_user_id` INT          NULL DEFAULT NULL,
  `is_active`             BOOLEAN      NOT NULL DEFAULT TRUE,
  `active_complaint_id`   INT GENERATED ALWAYS AS (
                            CASE WHEN `is_active` = TRUE THEN `complaint_id` ELSE NULL END
                          ) STORED,
  UNIQUE KEY `uq_single_active_assignment` (`active_complaint_id`),
  KEY `idx_assignments_complaint` (`complaint_id`, `assignment_id`),
  KEY `idx_assignments_staff_active` (`assigned_staff_id`, `is_active`),
  CONSTRAINT `chk_assignment_actor_required`
    CHECK (`assignment_source` = 'LEGACY_IMPORT'
           OR (`assigned_by_user_id` IS NOT NULL AND `assigned_at` IS NOT NULL)),
  CONSTRAINT `chk_assignment_active_state`
    CHECK ((`is_active` = TRUE  AND `unassigned_at` IS NULL)
        OR (`is_active` = FALSE AND `unassigned_at` IS NOT NULL)),
  CONSTRAINT `fk_assignment_complaint`     FOREIGN KEY (`complaint_id`)          REFERENCES `complaints`(`complaint_id`),
  CONSTRAINT `fk_assignment_staff`         FOREIGN KEY (`assigned_staff_id`)     REFERENCES `staff`(`staff_id`),
  CONSTRAINT `fk_assignment_assigned_by`   FOREIGN KEY (`assigned_by_user_id`)   REFERENCES `users`(`user_id`),
  CONSTRAINT `fk_assignment_unassigned_by` FOREIGN KEY (`unassigned_by_user_id`) REFERENCES `users`(`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 2. Escalation ledger (append-only; written only by escalate_complaint)
CREATE TABLE IF NOT EXISTS `complaint_escalations` (
  `escalation_id`        INT AUTO_INCREMENT PRIMARY KEY,
  `complaint_id`         INT       NOT NULL,
  `from_level_id`        INT       NOT NULL,
  `to_level_id`          INT       NOT NULL,
  `escalated_by_user_id` INT       NOT NULL,
  `escalation_reason`    TEXT      NOT NULL,
  `action_taken`         TEXT      DEFAULT NULL,
  `escalated_at`         TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY `idx_escalations_complaint` (`complaint_id`, `escalation_id`),
  CONSTRAINT `chk_escalation_changes_level` CHECK (`from_level_id` <> `to_level_id`),
  CONSTRAINT `fk_escalation_complaint` FOREIGN KEY (`complaint_id`)         REFERENCES `complaints`(`complaint_id`),
  CONSTRAINT `fk_escalation_from`      FOREIGN KEY (`from_level_id`)        REFERENCES `workflow_levels`(`level_id`),
  CONSTRAINT `fk_escalation_to`        FOREIGN KEY (`to_level_id`)          REFERENCES `workflow_levels`(`level_id`),
  CONSTRAINT `fk_escalation_actor`     FOREIGN KEY (`escalated_by_user_id`) REFERENCES `users`(`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 3. Resolution verification ledger (written only by transition_complaint_status)
CREATE TABLE IF NOT EXISTS `resolution_verifications` (
  `verification_id`       INT AUTO_INCREMENT PRIMARY KEY,
  `complaint_id`          INT       NOT NULL,
  `submitted_by_staff_id` INT       NOT NULL,
  `resolution_notes`      TEXT      NOT NULL,
  `officer_user_id`       INT       DEFAULT NULL,
  `decision`              ENUM('PENDING', 'APPROVED', 'RETURNED') NOT NULL DEFAULT 'PENDING',
  `officer_remarks`       TEXT      DEFAULT NULL,
  `submitted_at`          TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `reviewed_at`           DATETIME  DEFAULT NULL,
  `pending_complaint_id`  INT GENERATED ALWAYS AS (
                            CASE WHEN `decision` = 'PENDING' THEN `complaint_id` ELSE NULL END
                          ) STORED,
  UNIQUE KEY `uq_single_pending_verification` (`pending_complaint_id`),
  KEY `idx_verifications_complaint` (`complaint_id`, `verification_id`),
  CONSTRAINT `chk_verification_decision_state`
    CHECK ((`decision` = 'PENDING'  AND `officer_user_id` IS NULL     AND `reviewed_at` IS NULL)
        OR (`decision` <> 'PENDING' AND `officer_user_id` IS NOT NULL AND `reviewed_at` IS NOT NULL)),
  CONSTRAINT `fk_verification_complaint` FOREIGN KEY (`complaint_id`)          REFERENCES `complaints`(`complaint_id`),
  CONSTRAINT `fk_verification_staff`     FOREIGN KEY (`submitted_by_staff_id`) REFERENCES `staff`(`staff_id`),
  CONSTRAINT `fk_verification_officer`   FOREIGN KEY (`officer_user_id`)       REFERENCES `users`(`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- 4. In-app notifications
CREATE TABLE IF NOT EXISTS `notifications` (
  `notification_id` INT AUTO_INCREMENT PRIMARY KEY,
  `user_id`         INT          NOT NULL,
  `complaint_id`    INT          DEFAULT NULL,
  `title`           VARCHAR(150) NOT NULL,
  `message`         TEXT         NOT NULL,
  `is_read`         BOOLEAN      NOT NULL DEFAULT FALSE,
  `created_at`      TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY `idx_notif_user_unread` (`user_id`, `is_read`),
  CONSTRAINT `fk_notification_user`      FOREIGN KEY (`user_id`)      REFERENCES `users`(`user_id`) ON DELETE CASCADE,
  CONSTRAINT `fk_notification_complaint` FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
