-- Migration: 000_schema_migrations.sql
-- Purpose : Create the migration audit ledger in college_complaints_v2_dev.
-- Type    : DDL only (implicit commit).
-- Idempotency: CREATE TABLE IF NOT EXISTS. The runner also refuses to proceed
--              when a FAILED row exists or a recorded checksum differs from the file.
-- Reviewed by Claude (Stage 2 static review): unchanged in substance; session
-- settings made explicit so every file runs under the same character set / sql_mode.

SET NAMES utf8mb4;
SET SESSION sql_mode = 'ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION';

CREATE TABLE IF NOT EXISTS `schema_migrations` (
  `migration_id`      INT AUTO_INCREMENT PRIMARY KEY,
  `version`           VARCHAR(50)  NOT NULL,
  `script_name`       VARCHAR(150) NOT NULL,
  `checksum_sha256`   CHAR(64)     NOT NULL,
  `applied_by`        VARCHAR(100) NOT NULL,
  `applied_at`        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `execution_time_ms` INT          NOT NULL,
  `status`            ENUM('SUCCESS', 'FAILED') NOT NULL,
  UNIQUE KEY `uq_schema_migrations_version` (`version`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
