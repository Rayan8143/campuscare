-- Migration: 000_schema_migrations.sql
-- Purpose: Create migration audit ledger table in college_complaints_v2_dev

CREATE TABLE IF NOT EXISTS `schema_migrations` (
  `migration_id` INT AUTO_INCREMENT PRIMARY KEY,
  `version` VARCHAR(50) NOT NULL UNIQUE,
  `script_name` VARCHAR(150) NOT NULL,
  `checksum_sha256` CHAR(64) NOT NULL,
  `applied_by` VARCHAR(100) NOT NULL,
  `applied_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `execution_time_ms` INT NOT NULL,
  `status` ENUM('SUCCESS', 'FAILED') NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
