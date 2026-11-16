-- Migration: 001_core_rbac_schema.sql
-- Purpose : Normalized identity + RBAC tables, activation-token ledger, external profiles.
-- Type    : DDL only (implicit commits). No DML.
-- Idempotency: CREATE TABLE IF NOT EXISTS; the runner additionally asserts that none of
--              these tables exist before the first run (a pre-existing table of a
--              different shape would otherwise be silently accepted).
--
-- Claude Stage 2 corrections (see STAGE2_CLAUDE_REVIEW.md, section 001):
--   * users.password_hash is NULLABLE. NULL means "no password has ever been set".
--     The previous sentinel string 'LOCKED_PENDING_ACTIVATION' was a fake hash that
--     Werkzeug's check_password_hash() raises on (HTTP 500 instead of a clean denial).
--   * chk_users_active_requires_password: an account cannot be active without a password.
--   * Redundant idx_users_email removed (the UNIQUE key already indexes email).
--   * account_activations redesigned: purpose, used_at, revoked_at instead of the single
--     ambiguous is_used flag (it conflated "consumed" with "invalidated"); a stored
--     generated column + UNIQUE key guarantees at most ONE live token per user;
--     token_hash is ascii_bin and CHECK-ed to be 64 lowercase hex characters.
--   * account_activations.user_id FK has no CASCADE (MySQL forbids CASCADE on the base
--     column of a stored generated column; users are never hard-deleted anyway).

SET NAMES utf8mb4;
SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

CREATE TABLE IF NOT EXISTS `roles` (
  `role_id`     INT AUTO_INCREMENT PRIMARY KEY,
  `role_name`   VARCHAR(50)  NOT NULL,
  `description` VARCHAR(255) DEFAULT NULL,
  UNIQUE KEY `uq_roles_name` (`role_name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `permissions` (
  `permission_id`  INT AUTO_INCREMENT PRIMARY KEY,
  `permission_key` VARCHAR(100) NOT NULL,
  `module`         VARCHAR(50)  NOT NULL,
  `description`    VARCHAR(255) DEFAULT NULL,
  UNIQUE KEY `uq_permissions_key` (`permission_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `role_permissions` (
  `role_id`       INT NOT NULL,
  `permission_id` INT NOT NULL,
  PRIMARY KEY (`role_id`, `permission_id`),
  CONSTRAINT `fk_role_permissions_role`       FOREIGN KEY (`role_id`)       REFERENCES `roles`(`role_id`)             ON DELETE CASCADE,
  CONSTRAINT `fk_role_permissions_permission` FOREIGN KEY (`permission_id`) REFERENCES `permissions`(`permission_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `users` (
  `user_id`       INT AUTO_INCREMENT PRIMARY KEY,
  `username`      VARCHAR(120) NOT NULL,
  `email`         VARCHAR(120) NOT NULL,
  `password_hash` VARCHAR(255) NULL DEFAULT NULL,      -- NULL = no password set yet (never a placeholder)
  `full_name`     VARCHAR(100) NOT NULL,
  `is_active`     BOOLEAN      NOT NULL DEFAULT FALSE,
  `created_at`    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY `uq_users_username` (`username`),
  UNIQUE KEY `uq_users_email` (`email`),               -- utf8mb4_unicode_ci => case-insensitive uniqueness
  KEY `idx_users_active` (`is_active`),
  CONSTRAINT `chk_users_active_requires_password` CHECK (`is_active` = FALSE OR `password_hash` IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `user_roles` (
  `user_id`     INT       NOT NULL,
  `role_id`     INT       NOT NULL,
  `assigned_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `is_active`   BOOLEAN   NOT NULL DEFAULT TRUE,
  PRIMARY KEY (`user_id`, `role_id`),
  KEY `idx_user_roles_active` (`user_id`, `is_active`),
  KEY `idx_user_roles_role` (`role_id`),
  CONSTRAINT `fk_user_roles_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE CASCADE,
  CONSTRAINT `fk_user_roles_role` FOREIGN KEY (`role_id`) REFERENCES `roles`(`role_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Activation / password-reset token ledger. Only SHA-256 hex digests are stored.
-- Lifecycle: issued (live) -> used (used_at set) | revoked (revoked_at set) | expired (expires_at passed).
-- All timestamps in this table are UTC (written with UTC_TIMESTAMP() by the procedures in 008).
CREATE TABLE IF NOT EXISTS `account_activations` (
  `activation_id` INT AUTO_INCREMENT PRIMARY KEY,
  `user_id`       INT NOT NULL,
  `purpose`       ENUM('ACTIVATION', 'PASSWORD_RESET') NOT NULL DEFAULT 'ACTIVATION',
  `token_hash`    CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  `created_at`    DATETIME NOT NULL DEFAULT (UTC_TIMESTAMP()),
  `expires_at`    DATETIME NOT NULL,
  `used_at`       DATETIME NULL DEFAULT NULL,
  `revoked_at`    DATETIME NULL DEFAULT NULL,
  `live_user_id`  INT GENERATED ALWAYS AS (
                    CASE WHEN `used_at` IS NULL AND `revoked_at` IS NULL THEN `user_id` ELSE NULL END
                  ) STORED,
  UNIQUE KEY `uq_activation_token_hash` (`token_hash`),
  UNIQUE KEY `uq_activation_one_live_token_per_user` (`live_user_id`),
  KEY `idx_activation_user` (`user_id`),
  CONSTRAINT `chk_activation_token_hash_hex` CHECK (`token_hash` REGEXP '^[0-9a-f]{64}$'),
  CONSTRAINT `chk_activation_single_terminal_state` CHECK (`used_at` IS NULL OR `revoked_at` IS NULL),
  CONSTRAINT `chk_activation_expiry_after_creation` CHECK (`expires_at` > `created_at`),
  CONSTRAINT `fk_activation_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `external_complainants` (
  `external_id`       INT AUTO_INCREMENT PRIMARY KEY,
  `user_id`           INT NOT NULL,
  `affiliation_type`  ENUM('Parent', 'Alumni', 'Vendor', 'Contractor', 'Visitor', 'Other') NOT NULL,
  `organization_name` VARCHAR(150) DEFAULT NULL,
  `phone`             VARCHAR(20)  NOT NULL,
  `address`           VARCHAR(255) DEFAULT NULL,
  `created_at`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY `uq_external_user` (`user_id`),
  CONSTRAINT `fk_external_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
