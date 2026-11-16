# CAMPUSCARE 2.0 – FINAL SYSTEM AUDIT & ARCHITECTURAL SPECIFICATION

**Document Version:** 2.2.0-FINAL  
**Audit Date:** November 14, 2026  
**Auditor:** Senior Full-Stack Engineer & Principal Database Architect  
**Project Workspace:** `c:\Users\rayan\Desktop\dbms_pbl`  
**Production Database:** `college_complaints` (Protected, Frozen Academic Baseline)  
**Development Sandbox:** `college_complaints_v2_dev` (Isolated Engineering Database)  
**Status:** Architecture Specification Finalized · STRICTLY PLANNING ONLY · Zero Code or Database Changes Executed

---

## EXECUTIVE SUMMARY & AUDIT DIRECTIVES

This document constitutes the final, authoritative architecture specification (Version 2.2) for the CampusCare 2.0 upgrade. It resolves all feedback and technical edge cases identified during architectural reviews:

1. **Complete Database Migration Inventory:** Provides full, ready-to-run DDL for every proposed table, column extension, audit ledger, and foreign key constraint, including `account_activations`, soft-delete tracking, actor attribution, and staff verification.
2. **Deterministic Primary Officer Singleton:** Replaces trigger-based uniqueness with an immutable database-enforced singleton authority table (`primary_officer_assignment`) and a transactional transfer protocol that eliminates concurrency race conditions and update vulnerabilities.
3. **Database-Enforced Active Assignment Uniqueness:** Implements conditional uniqueness via a generated column (`active_complaint_id`) paired with a `UNIQUE` index on `complaint_assignments`, preventing duplicate active assignees across concurrent inserts and updates.
4. **Clean Trigger Replacement Runbook:** Mandates the explicit removal of the legacy `trg_complaint_status_history` trigger prior to installing the enhanced context-aware trigger, preventing duplicate audit entries.
5. **Authoritative Normalized RBAC:** Completely removes the obsolete `users.user_type` column to establish `user_roles` as the single source of truth. Formalizes a clear onboarding and verification lifecycle for staff applicants.
6. **Multi-Faceted Primary Officer Scope:** Explicitly delineates the Primary Complaint Management Officer's roles as Global Oversight Authority, Exclusive Resolution Verifier, Highest Escalation Authority (Workflow Level 4), and Master Reassignment Authority.
7. **Comprehensive Complainant Identity Integrity:** Extends cross-table ownership validation triggers to cover both `BEFORE INSERT` and `BEFORE UPDATE` events on `complaints`.
8. **Accurate Cryptographic Password Hashing:** Formally clarifies password hashing mechanisms, leveraging Werkzeug 3.x's built-in memory-hard `scrypt` algorithm (zero new dependencies) while documenting optional `argon2-cffi` integration.
9. **Precise Backup & Environment Validation:** Replaces colloquial "byte-for-byte" terminology with formal consistency verification protocols spanning schema definitions, table checksums, row counts, views, triggers, and routines.
10. **Environment Isolation & Guardrails:** Configures a dedicated, unprivileged MySQL user (`complaint_app_v2_dev`) restricted strictly to the development sandbox, accompanied by a Python application-level startup guard preventing connections to `college_complaints`.
11. **Expanded Acceptance Test Suite:** Expands the test matrix to cover role deactivation, concurrent singleton collisions, assignment update constraints, trigger replacement deduplication, and migration recovery.
12. **Feature Classification:** Clearly categorizes capabilities into Completed Baseline (v1.0), Core Upgrades (v2.0), and Deferred Enhancements (Future).

---

## 1. FEATURE CLASSIFICATION TAXONOMY

To prevent architectural scope creep and distinguish existing investments from upcoming deliverables, features are partitioned into three distinct tiers:

```
┌────────────────────────────────────────────────────────────────────────┐
│                   CAMPUSCARE FEATURE CLASSIFICATION                    │
├────────────────────────────────────────────────────────────────────────┤
│ TIER A: COMPLETED BASELINE FEATURES (v1.0 Academic Prototype)          │
│ • BCNF normalized schema (students, departments, complaints, etc.)     │
│ • Unauthenticated single-page complaint intake & dashboard             │
│ • Basic status updates (Submitted -> In Progress -> Resolved/Rejected) │
│ • Legacy status history trigger (static text attribution)              │
│ • Parameterized SQL query execution (%s placeholders)                  │
│ • Base analytical views (pending_complaints, complaint_details, etc.)  │
├────────────────────────────────────────────────────────────────────────┤
│ TIER B: PROPOSED CORE FEATURES (CampusCare 2.0 Required Scope)         │
│ • Dual-environment database isolation (dev sandbox vs protected prod)  │
│ • Normalized 5-table RBAC (users, roles, permissions, user_roles, etc.)│
│ • Dedicated Primary Complaint Management Officer singleton authority   │
│ • Separation of staff job designation from workflow handling tiers     │
│ • Independent student and external complainant portals                 │
│ • Dedicated staff personal work queues & investigation update desks    │
│ • Multi-tier escalation engine (Levels 1 to 4)                         │
│ • Controlled resolution verification loop (Staff submit -> Officer OK) │
│ • Canonical assignment history with single-active-assignee constraint  │
│ • Soft deletion and immutable, append-only audit ledgers               │
│ • Werkzeug scrypt password hashing & tokenized account activation      │
│ • Session security, CSRF protection, and rate limiting                 │
│ • Tabler UI redesign with interactive vertical history timelines       │
├────────────────────────────────────────────────────────────────────────┤
│ TIER C: OPTIONAL FUTURE ENHANCEMENTS (Deferred / Post-v2.0)            │
│ • Multi-factor authentication (TOTP via Google Authenticator)          │
│ • Outbound SMTP email notifications and SMS gateway integration        │
│ • Binary file attachment intake with magic-byte scanning and S3 storage│
│ • Redis-backed distributed session store and rate-limiting cache       │
│ • Automated SLA breach escalation chron jobs (Celery / cron daemon)    │
│ • Full-text Elasticsearch indexing for complaint search                │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 2. PRODUCTION PRESERVATION & DEV ENVIRONMENT ISOLATION

### 2.1 Environmental Boundary Architecture
The existing database `college_complaints` constitutes an untouchable academic demonstration baseline. Development, testing, and migration rehearsals are isolated within `college_complaints_v2_dev`.

```
┌──────────────────────────────────────┐       ┌──────────────────────────────────────┐
│         PRODUCTION ENVIRONMENT       │       │        DEVELOPMENT SANDBOX           │
├──────────────────────────────────────┤       ├──────────────────────────────────────┤
│ Database: college_complaints         │       │ Database: college_complaints_v2_dev  │
│ Access: READ-ONLY (Frozen Baseline)  │       │ Access: FULL DDL/DML (Migration Test)│
│ User: complaint_app                  │       │ User: complaint_app_v2_dev           │
│ Scope: Academic Demonstration Only   │       │ Scope: Active Engineering & QA       │
└──────────────────────────────────────┘       └──────────────────────────────────────┘
                   │                                              ▲
                   │ Logical mysqldump                            │ Restored Snapshot
                   └──────────────────────────────────────────────┘
```

### 2.2 Dedicated Development MySQL Account
A dedicated MySQL user account is provisioned exclusively for the development database:

```sql
-- Executed once by MySQL Root during sandbox provisioning:
CREATE USER IF NOT EXISTS 'complaint_app_v2_dev'@'localhost' IDENTIFIED BY 'DevSecurePass2026!';
GRANT ALL PRIVILEGES ON `college_complaints_v2_dev`.* TO 'complaint_app_v2_dev'@'localhost';
REVOKE ALL PRIVILEGES ON `college_complaints`.* FROM 'complaint_app_v2_dev'@'localhost';
FLUSH PRIVILEGES;
```
*Security Guarantee:* The development credentials have zero access permissions on `college_complaints`. Any accidental configuration error results in an immediate MySQL access denied error (`ERROR 1044/1142`), physically protecting production.

### 2.3 Application-Level Startup Guard
To prevent human error when launching Flask, an environmental guardrail is embedded into `connect_db()`:

```python
import os

def connect_db():
    env = os.getenv("FLASK_ENV", "development")
    db_name = os.getenv("DB_NAME", "college_complaints_v2_dev")
    
    # Startup Guardrail: Prevent running dev mode against production
    if env == "development" and db_name == "college_complaints":
        raise RuntimeError(
            "CRITICAL SECURITY HALT: FLASK_ENV='development' is targeting the protected "
            "production database 'college_complaints'. Aborting to prevent accidental modification. "
            "Set DB_NAME='college_complaints_v2_dev'."
        )
        
    return mysql.connector.connect(
        host=os.getenv("DB_HOST", "localhost"),
        user=os.getenv("DB_USER", "complaint_app_v2_dev"),
        password=os.getenv("DB_PASSWORD", "DevSecurePass2026!"),
        database=db_name,
    )
```

### 2.4 Forensic Sandbox Provisioning & Rigorous Verification Protocol

```bash
# Step 1: Logical snapshot of baseline production
mysqldump -u root -p --single-transaction --routines --triggers --events \
  --default-character-set=utf8mb4 --result-file="backup_before_v2_frozen.sql" \
  college_complaints

# Step 2: Create development sandbox
mysql -u root -p -e "CREATE DATABASE IF NOT EXISTS college_complaints_v2_dev CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# Step 3: Populate development sandbox
mysql -u root -p college_complaints_v2_dev < backup_before_v2_frozen.sql
```

#### Verification Protocol (Schema, Rows, Consistency & Routines):
1. **Row Count Verification:**
   ```sql
   SELECT 'complaints' AS tbl, COUNT(*) AS cnt FROM college_complaints_v2_dev.complaints
   UNION ALL SELECT 'students', COUNT(*) FROM college_complaints_v2_dev.students
   UNION ALL SELECT 'staff', COUNT(*) FROM college_complaints_v2_dev.staff
   UNION ALL SELECT 'departments', COUNT(*) FROM college_complaints_v2_dev.departments
   UNION ALL SELECT 'academic_departments', COUNT(*) FROM college_complaints_v2_dev.academic_departments
   UNION ALL SELECT 'complaint_history', COUNT(*) FROM college_complaints_v2_dev.complaint_history;
   ```
   *Expected:* 202 complaints, 102 students, 15 staff, 5 departments, 10 academic departments, 156 history entries.
2. **Structural Consistency Check (`CHECKSUM TABLE`):**
   ```sql
   CHECKSUM TABLE 
     college_complaints.complaints, college_complaints_v2_dev.complaints,
     college_complaints.students, college_complaints_v2_dev.students,
     college_complaints.complaint_history, college_complaints_v2_dev.complaint_history;
   ```
   *Expectation:* Checksum values match algorithmically across tables.
3. **Database Object Parity Check:**
   Verify counts of Views (4), Triggers (1), and Stored Procedures (1) match in `information_schema`:
   ```sql
   SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = 'college_complaints_v2_dev';
   SELECT TRIGGER_NAME FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = 'college_complaints_v2_dev';
   SELECT TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA = 'college_complaints_v2_dev';
   ```

---

## 3. REALISTIC MYSQL MIGRATION FRAMEWORK

### 3.1 Non-Transactional DDL Handling
In MySQL 8.0, DDL operations execute outside transactional rollbacks. To handle this safely:
- Migrations are decoupled into granular, numbered `.sql` and `.py` files.
- Forward schema updates use idempotent checks (`IF NOT EXISTS`, column existence checks).
- An explicit checkpoint backup of `college_complaints_v2_dev` is taken prior to each stage.
- If stage `N` fails, the sandbox is restored to `checkpoint_pre_N.sql`, correcting issues without messy manual rollbacks.

### 3.2 Complete Database Migration Inventory & DDL

#### Table 1: `schema_migrations` (Version Audit Ledger)
```sql
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
```

#### Table 2: `users` (Core Identity)
*Note: `user_type` column is permanently eliminated in favor of normalized `user_roles`.*
```sql
CREATE TABLE IF NOT EXISTS `users` (
  `user_id` INT AUTO_INCREMENT PRIMARY KEY,
  `username` VARCHAR(120) NOT NULL UNIQUE,
  `email` VARCHAR(120) NOT NULL UNIQUE,
  `password_hash` VARCHAR(255) NOT NULL,
  `full_name` VARCHAR(100) NOT NULL,
  `is_active` BOOLEAN NOT NULL DEFAULT FALSE,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX `idx_users_email` (`email`),
  INDEX `idx_users_active` (`is_active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

#### Table 3: `account_activations` (Tokenized Onboarding)
```sql
CREATE TABLE IF NOT EXISTS `account_activations` (
  `activation_id` INT AUTO_INCREMENT PRIMARY KEY,
  `user_id` INT NOT NULL,
  `token_hash` CHAR(64) NOT NULL UNIQUE,
  `expires_at` DATETIME NOT NULL,
  `is_used` BOOLEAN NOT NULL DEFAULT FALSE,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE CASCADE,
  INDEX `idx_activation_token` (`token_hash`, `is_used`, `expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

#### Table 4: `roles` & Table 5: `permissions`
```sql
CREATE TABLE IF NOT EXISTS `roles` (
  `role_id` INT AUTO_INCREMENT PRIMARY KEY,
  `role_name` VARCHAR(50) NOT NULL UNIQUE,
  `description` VARCHAR(255) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `permissions` (
  `permission_id` INT AUTO_INCREMENT PRIMARY KEY,
  `permission_key` VARCHAR(100) NOT NULL UNIQUE,
  `module` VARCHAR(50) NOT NULL,
  `description` VARCHAR(255) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

#### Table 6: `role_permissions` & Table 7: `user_roles`
```sql
CREATE TABLE IF NOT EXISTS `role_permissions` (
  `role_id` INT NOT NULL,
  `permission_id` INT NOT NULL,
  PRIMARY KEY (`role_id`, `permission_id`),
  FOREIGN KEY (`role_id`) REFERENCES `roles`(`role_id`) ON DELETE CASCADE,
  FOREIGN KEY (`permission_id`) REFERENCES `permissions`(`permission_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `user_roles` (
  `user_id` INT NOT NULL,
  `role_id` INT NOT NULL,
  `assigned_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  `is_active` BOOLEAN NOT NULL DEFAULT TRUE,
  PRIMARY KEY (`user_id`, `role_id`),
  FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE CASCADE,
  FOREIGN KEY (`role_id`) REFERENCES `roles`(`role_id`) ON DELETE CASCADE,
  INDEX `idx_user_roles_active` (`user_id`, `is_active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

#### Table 8: `external_complainants` (Non-Student Profiles)
```sql
CREATE TABLE IF NOT EXISTS `external_complainants` (
  `external_id` INT AUTO_INCREMENT PRIMARY KEY,
  `user_id` INT NOT NULL UNIQUE,
  `affiliation_type` ENUM('Parent', 'Alumni', 'Vendor', 'Contractor', 'Visitor', 'Other') NOT NULL,
  `organization_name` VARCHAR(150) DEFAULT NULL,
  `phone` VARCHAR(20) NOT NULL,
  `address` VARCHAR(255) DEFAULT NULL,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

#### Table 9: `workflow_levels` (Escalation Hierarchy Master)
```sql
CREATE TABLE IF NOT EXISTS `workflow_levels` (
  `level_id` INT AUTO_INCREMENT PRIMARY KEY,
  `level_number` INT NOT NULL UNIQUE,
  `level_name` VARCHAR(60) NOT NULL UNIQUE,
  `description` VARCHAR(255) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Standard Seed Levels:
-- 1: Frontline Staff / Technician
-- 2: Department Reviewer / Supervisor
-- 3: Department Head (HOD)
-- 4: Primary Complaint Management Officer
```

#### Table 10: `staff_workflow_assignments` (Decoupled Workflow Authorization)
```sql
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
```

#### Table 11: `primary_officer_assignment` (Deterministic Singleton Authority Table)
```sql
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
```

#### Table 12: `primary_officer_history` (Executive Transfer Audit)
```sql
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
```

#### Table 13: `complaint_assignments` (Canonical Assignment Ledger with Generated Uniqueness)
```sql
CREATE TABLE IF NOT EXISTS `complaint_assignments` (
  `assignment_id` INT AUTO_INCREMENT PRIMARY KEY,
  `complaint_id` INT NOT NULL,
  `assigned_staff_id` INT NOT NULL,
  `assigned_by_user_id` INT NOT NULL,
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
```

#### Table 14: `complaint_escalations` (Escalation Event Ledger)
```sql
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
```

#### Table 15: `resolution_verifications` (Officer Review Ledger)
```sql
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
```

#### Table 16: `notifications` (In-App Notification Center)
```sql
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
```

### 3.3 Alterations to Existing Tables

#### Alterations to `students`:
```sql
ALTER TABLE `students`
  ADD COLUMN `user_id` INT NULL UNIQUE AFTER `academic_department_id`,
  ADD CONSTRAINT `fk_students_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT;
```

#### Alterations to `staff`:
```sql
ALTER TABLE `staff`
  ADD COLUMN `user_id` INT NULL UNIQUE AFTER `department_id`,
  ADD COLUMN `designation` VARCHAR(100) NOT NULL DEFAULT 'Staff Member' AFTER `full_name`,
  ADD COLUMN `verification_status` ENUM('PENDING', 'VERIFIED', 'REJECTED') NOT NULL DEFAULT 'PENDING' AFTER `email`,
  ADD COLUMN `verified_by_user_id` INT NULL AFTER `verification_status`,
  ADD COLUMN `verified_at` DATETIME NULL AFTER `verified_by_user_id`,
  ADD COLUMN `is_active` BOOLEAN NOT NULL DEFAULT FALSE AFTER `verified_at`,
  ADD CONSTRAINT `fk_staff_user` FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT,
  ADD CONSTRAINT `fk_staff_verified_by` FOREIGN KEY (`verified_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT;
```

#### Alterations to `complaints`:
```sql
-- 1. Modify student_id to allow NULL (enables external complaints)
ALTER TABLE `complaints` MODIFY COLUMN `student_id` INT NULL;

-- 2. Add external link, complainant user link, workflow tier, soft delete columns
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

-- 3. Extend status ENUM to include all workflow states
ALTER TABLE `complaints`
  MODIFY COLUMN `status` ENUM(
    'Submitted',
    'In Progress',
    'Escalated',
    'Resolution Pending Verification',
    'Resolved',
    'Rejected'
  ) NOT NULL DEFAULT 'Submitted';

-- 4. Enforce mutual exclusivity of student vs external complainant
ALTER TABLE `complaints`
  ADD CONSTRAINT `chk_complaint_complainant_type`
  CHECK (
    (`student_id` IS NOT NULL AND `external_id` IS NULL) OR
    (`student_id` IS NULL AND `external_id` IS NOT NULL)
  );
```

#### Alterations to `complaint_history`:
```sql
-- 1. Remove dangerous ON DELETE CASCADE
ALTER TABLE `complaint_history` DROP FOREIGN KEY `complaint_history_ibfk_1`;
ALTER TABLE `complaint_history`
  ADD CONSTRAINT `fk_complaint_history_complaint`
  FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE RESTRICT;

-- 2. Add actor attribution and action type
ALTER TABLE `complaint_history`
  ADD COLUMN `changed_by_user_id` INT NULL AFTER `changed_at`,
  ADD COLUMN `action_type` VARCHAR(40) NOT NULL DEFAULT 'STATUS_CHANGE' AFTER `changed_by_user_id`,
  ADD CONSTRAINT `fk_complaint_history_user` FOREIGN KEY (`changed_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT;
```

---

## 4. PRIMARY OFFICER SINGLETON & TRANSFER PROCESS

### 4.1 Guaranteed Uniqueness via Singleton Table
Trigger checks on `BEFORE INSERT` fail to prevent race conditions during concurrent inserts and do not protect against `UPDATE` statements. CampusCare 2.0 uses an architectural pattern:
- The table `primary_officer_assignment` has a primary key `singleton_id TINYINT DEFAULT 1` constrained by `CHECK (singleton_id = 1)`.
- It is physically impossible for more than one row to exist in this table.
- A query to find the active officer executes instantly: `SELECT user_id FROM primary_officer_assignment WHERE singleton_id = 1`.

### 4.2 Safe Officer-Transfer Transactional Protocol
Transferring executive authority from Officer A to Officer B is executed within an ACID transaction:

```sql
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

    -- 1. Retrieve current incumbent details
    SELECT user_id, assigned_at 
    INTO v_current_officer_user_id, v_current_started_at
    FROM primary_officer_assignment 
    WHERE singleton_id = 1 
    FOR UPDATE;

    SELECT role_id INTO v_officer_role_id FROM roles WHERE role_name = 'PRIMARY_COMPLAINT_OFFICER';

    -- 2. Archive tenure in primary_officer_history
    IF v_current_officer_user_id IS NOT NULL THEN
        INSERT INTO primary_officer_history (
            officer_user_id, appointed_by_user_id, started_at, ended_at, transition_reason
        ) VALUES (
            v_current_officer_user_id, p_acting_admin_user_id, v_current_started_at, NOW(), p_reason
        );

        -- Deactivate incumbent role in user_roles
        UPDATE user_roles 
        SET is_active = FALSE 
        WHERE user_id = v_current_officer_user_id AND role_id = v_officer_role_id;
    END IF;

    -- 3. Update the singleton table with new officer
    UPDATE primary_officer_assignment
    SET user_id = p_new_officer_user_id,
        assigned_by_user_id = p_acting_admin_user_id,
        previous_officer_user_id = v_current_officer_user_id,
        transition_reason = p_reason,
        assigned_at = NOW()
    WHERE singleton_id = 1;

    -- 4. Activate new officer role in user_roles
    INSERT INTO user_roles (user_id, role_id, is_active)
    VALUES (p_new_officer_user_id, v_officer_role_id, TRUE)
    ON DUPLICATE KEY UPDATE is_active = TRUE;

    COMMIT;
END$$
DELIMITER ;
```

---

## 5. ROBUST ACTIVE ASSIGNMENT CONSTRAINT

### 5.1 Generated Column + Unique Index Architecture
To enforce that **each complaint has at most one active primary staff assignment**:
- In MySQL, `NULL` values are ignored by `UNIQUE` constraints (multiple rows may store `NULL`).
- In `complaint_assignments`, a stored generated column is defined:
  ```sql
  `active_complaint_id` INT GENERATED ALWAYS AS (
    CASE WHEN `is_active` = TRUE THEN `complaint_id` ELSE NULL END
  ) STORED
  ```
- A `UNIQUE KEY (active_complaint_id)` is applied.
- When `is_active = FALSE`, the column evaluates to `NULL` (unlimited inactive historical rows allowed).
- When `is_active = TRUE`, the column evaluates to `complaint_id`. Any attempt to insert or update a second row with `is_active = TRUE` for the same `complaint_id` triggers immediate MySQL error `1062 (Duplicate entry for key 'uq_single_active_assignment')`.
- This functions under high concurrency and during batch updates without race conditions.

### 5.2 Transactional Synchronization with Cached Assignee
Whenever an assignment change occurs, `complaints.assigned_staff_id` is updated in the same transaction:

```sql
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

    -- 3. Synchronize cached pointer
    UPDATE complaints
    SET assigned_staff_id = p_new_staff_id
    WHERE complaint_id = p_complaint_id;

    COMMIT;
END$$
DELIMITER ;
```

---

## 6. CLEAN TRIGGER REPLACEMENT RUNBOOK

### 6.1 Avoiding Duplicate History Records
The baseline database has an active trigger `trg_complaint_status_history` that inserts a history row on `AFTER UPDATE ON complaints`.

If a new trigger `trg_complaint_status_history_v2` is installed alongside it:
1. Every status update produces **two duplicate history rows** in `complaint_history`.
2. The legacy trigger writes `'Status updated from dashboard'` with `changed_by_user_id = NULL`.
3. The new trigger writes the actor-attributed record.

### 6.2 Explicit Drop-and-Replace Migration Script (`007_triggers_and_views_update.sql`)
```sql
USE college_complaints_v2_dev;

-- Step 1: Explicitly remove the legacy trigger
DROP TRIGGER IF EXISTS `trg_complaint_status_history`;

-- Step 2: Install the upgraded, session-aware trigger with identical original name
DELIMITER $$
CREATE TRIGGER `trg_complaint_status_history` AFTER UPDATE ON `complaints` FOR EACH ROW
BEGIN
  IF OLD.status <> NEW.status THEN
    INSERT INTO complaint_history (
      complaint_id,
      old_status,
      new_status,
      changed_at,
      changed_by_user_id,
      action_type,
      remarks
    ) VALUES (
      NEW.complaint_id,
      OLD.status,
      NEW.status,
      NOW(),
      @app_current_user_id,
      COALESCE(@app_action_type, 'STATUS_CHANGE'),
      COALESCE(@app_status_remarks, 'Status updated via application workflow')
    );
  END IF;
END$$
DELIMITER ;
```
*Guarantee:* By dropping the trigger first and preserving the canonical trigger name, duplicate history entries are completely prevented.

---

## 7. AUTHORITATIVE RBAC & STAFF ONBOARDING LIFECYCLE

### 7.1 Single Source of Truth: `user_roles`
The legacy `users.user_type` column is removed. A user's operational role is determined strictly through `user_roles` joined with `roles` and `permissions`.

### 7.2 Staff Applicant Onboarding Lifecycle
To maintain strict access control without compromising usability:

```
┌────────────────────────┐
│  Public Registration   │ User submits: Full Name, Staff Email, Dept, Designation
└───────────┬────────────┘
            ▼
┌────────────────────────┐
│  Pending Verification  │ • users.is_active = FALSE
│      (Applicant)       │ • staff.verification_status = 'PENDING'
└───────────┬────────────┘ • Zero roles in user_roles (Login Blocked)
            │
            ├───────────────────────────────────────────────┐
            │ Officer Reviews at Verification Desk          │ Officer Rejects
            ▼                                               ▼
┌────────────────────────┐                      ┌────────────────────────┐
│   VERIFIED & ACTIVE    │                      │        REJECTED        │
├────────────────────────┤                      ├────────────────────────┤
│ • staff.status=VERIFIED│                      │ • staff.status=REJECTED│
│ • users.is_active=TRUE │                      │ • users.is_active=FALSE│
│ • user_roles: 'STAFF'  │                      │ • Access Denied        │
│ • Level 1 Workflow Map │                      └────────────────────────┘
└────────────────────────┘
```

1. **Self-Registration:** An applicant signs up under `/register/staff`. A record is created in `users` (`is_active = FALSE`) and in `staff` (`verification_status = 'PENDING'`). No role is granted.
2. **Officer Inspection:** The Primary Officer opens the Staff Verification Panel on their dashboard, viewing pending applicants.
3. **Approval Action:** The Officer clicks "Approve". Inside a single transaction:
   - `staff.verification_status = 'VERIFIED'`
   - `staff.verified_by_user_id = officer_user_id`
   - `staff.verified_at = NOW()`
   - `users.is_active = TRUE`
   - Row inserted into `user_roles` (`role_name = 'STAFF'`)
   - Initial Level 1 record inserted into `staff_workflow_assignments`
4. **Rejection Action:** The Officer clicks "Reject" with notes. `staff.verification_status = 'REJECTED'`, and access remains permanently blocked.

---

## 8. PRIMARY COMPLAINT MANAGEMENT OFFICER OPERATIONAL SPECIFICATION

### 8.1 Multi-Faceted Authority Model
The Primary Complaint Management Officer operates across four distinct roles:

```
┌────────────────────────────────────────────────────────────────────────┐
│             PRIMARY COMPLAINT MANAGEMENT OFFICER POWERS                │
├────────────────────────────────┬───────────────────────────────────────┤
│ 1. GLOBAL OVERSIGHT AUTHORITY  │ • Unrestricted visibility across all  │
│                                │   5 service departments               │
│                                │ • Access to complete audit logs       │
│                                │ • Real-time staff workload metrics    │
├────────────────────────────────┼───────────────────────────────────────┤
│ 2. EXCLUSIVE RESOLUTION        │ • SOLE authority who can approve      │
│    VERIFIER                    │   resolutions into final 'Resolved'   │
│                                │ • Formal authority to return tickets  │
│                                │   to 'In Progress' with rework notes  │
├────────────────────────────────┼───────────────────────────────────────┤
│ 3. HIGHEST ESCALATION TIER     │ • Operates as Workflow Level 4        │
│    (Workflow Level 4)          │ • Handles disputes unresolved by HODs │
│                                │   (Level 3) or inter-department stalls│
├────────────────────────────────┼───────────────────────────────────────┤
│ 4. MASTER REASSIGNMENT         │ • Can reassign any complaint across   │
│    AUTHORITY                   │   departments or staff at any stage   │
│                                │ • Verifies and approves staff accounts│
└────────────────────────────────┴───────────────────────────────────────┘
```

### 8.2 Explicit Permissions & State Transitions
- **Verification Authority:** Only the Primary Officer can execute:
  `Resolution Pending Verification` ➔ `Resolved` (Approved)
  `Resolution Pending Verification` ➔ `In Progress` (Returned for Reinvestigation)
- **Escalation Authority:** Can receive escalations from Level 3 (`Department Head`), or intervene on Level 1/2 tickets.
- **Independence from Designation:** An officer might hold an employment designation such as "Senior Administrative Officer" or "Dean of Student Affairs", but their workflow authority derives exclusively from `primary_officer_assignment`.

---

## 9. COMPLAINANT IDENTITY INTEGRITY (INSERT & UPDATE)

To prevent cross-account identity spoofing during both creation and subsequent editing, dual triggers enforce ownership on `complaints`:

```sql
DELIMITER $$
-- Trigger 1: On INSERT
CREATE TRIGGER `trg_validate_complaint_identity_insert`
BEFORE INSERT ON `complaints` FOR EACH ROW
BEGIN
  DECLARE v_student_user_id INT;
  DECLARE v_external_user_id INT;

  IF NEW.student_id IS NOT NULL THEN
    SELECT user_id INTO v_student_user_id FROM students WHERE student_id = NEW.student_id;
    IF v_student_user_id IS NULL OR v_student_user_id <> NEW.complainant_user_id THEN
      SIGNAL SQLSTATE '45000' 
      SET MESSAGE_TEXT = 'Integrity Error: student_id does not belong to complainant_user_id.';
    END IF;
  END IF;

  IF NEW.external_id IS NOT NULL THEN
    SELECT user_id INTO v_external_user_id FROM external_complainants WHERE external_id = NEW.external_id;
    IF v_external_user_id IS NULL OR v_external_user_id <> NEW.complainant_user_id THEN
      SIGNAL SQLSTATE '45000' 
      SET MESSAGE_TEXT = 'Integrity Error: external_id does not belong to complainant_user_id.';
    END IF;
  END IF;
END$$

-- Trigger 2: On UPDATE
CREATE TRIGGER `trg_validate_complaint_identity_update`
BEFORE UPDATE ON `complaints` FOR EACH ROW
BEGIN
  DECLARE v_student_user_id INT;
  DECLARE v_external_user_id INT;

  -- Complainant user ID is immutable once created
  IF NEW.complainant_user_id <> OLD.complainant_user_id THEN
    SIGNAL SQLSTATE '45000'
    SET MESSAGE_TEXT = 'Security Violation: complainant_user_id cannot be altered.';
  END IF;

  IF NEW.student_id IS NOT NULL THEN
    SELECT user_id INTO v_student_user_id FROM students WHERE student_id = NEW.student_id;
    IF v_student_user_id IS NULL OR v_student_user_id <> NEW.complainant_user_id THEN
      SIGNAL SQLSTATE '45000' 
      SET MESSAGE_TEXT = 'Integrity Error: student_id does not belong to complainant_user_id.';
    END IF;
  END IF;

  IF NEW.external_id IS NOT NULL THEN
    SELECT user_id INTO v_external_user_id FROM external_complainants WHERE external_id = NEW.external_id;
    IF v_external_user_id IS NULL OR v_external_user_id <> NEW.complainant_user_id THEN
      SIGNAL SQLSTATE '45000' 
      SET MESSAGE_TEXT = 'Integrity Error: external_id does not belong to complainant_user_id.';
    END IF;
  END IF;
END$$
DELIMITER ;
```

---

## 10. ACCURATE CRYPTOGRAPHIC PASSWORD HASHING

### 10.1 Technical Correction: Werkzeug vs Argon2id
The previous audit incorrectly stated that Werkzeug's `generate_password_hash` provides Argon2id natively. In Werkzeug 3.x:
- Built-in algorithms: `scrypt` (default since Werkzeug 2.3), `pbkdf2:sha256`.
- `scrypt` is an industry-standard, memory-hard key derivation function recommended by NIST and OWASP.

### 10.2 Hashing Specification
1. **Primary Standard (Zero Extra Dependencies):**
   CampusCare 2.0 uses Werkzeug's native `scrypt` implementation:
   ```python
   from werkzeug.security import generate_password_hash, check_password_hash

   # Generates: scrypt:32768:8:1$<salt>$<hash>
   password_hash = generate_password_hash(raw_password, method="scrypt")
   is_valid = check_password_hash(password_hash, candidate_password)
   ```
2. **Optional Argon2id Implementation:**
   If Argon2id is explicitly mandated by organizational policy, add `argon2-cffi>=23.1.0` to `requirements.txt`:
   ```python
   from argon2 import PasswordHasher
   ph = PasswordHasher(time_cost=2, memory_cost=65536, parallelism=1)
   password_hash = ph.hash(raw_password)
   ph.verify(password_hash, candidate_password)
   ```

---

## 11. EXPANDED ACCEPTANCE TEST MATRIX

The certified test suite includes eighteen comprehensive acceptance tests:

| Test ID | Test Category | Execution Scenario | Expected Result | Pass Criteria |
| :--- | :--- | :--- | :--- | :--- |
| **TC-01** | Privacy Isolation | Student A fetches Student B's complaint URL. | HTTP 403 Forbidden. | Cross-student data inaccessible. |
| **TC-02** | External Isolation | External A requests External B's complaint history. | HTTP 403 Forbidden. | Cross-external data inaccessible. |
| **TC-03** | Queue Boundaries | Staff A attempts to update Staff B's assigned ticket. | HTTP 403 Forbidden. | Staff restricted to assigned tickets. |
| **TC-04** | Role Activation | Inactive user attempts login. | HTTP 403 Forbidden ("Account Pending Verification"). | Inactive accounts cannot authenticate. |
| **TC-05** | Officer Uniqueness (INSERT)| Concurrent thread attempts second active officer. | Second thread aborted with primary key violation. | Exactly one row in `primary_officer_assignment`. |
| **TC-06** | Officer Uniqueness (UPDATE)| Attempt to update singleton ID to 2 or insert row. | CHECK constraint violation (`singleton_id = 1`). | Singleton pattern cannot be bypassed. |
| **TC-07** | Registration Escalation | Form submitted with `role=ADMIN` or `role=OFFICER`. | HTTP 400 Bad Request. | Privileged roles cannot be self-registered. |
| **TC-08** | Identity Integrity (INSERT)| Insert complaint with mismatched `student_id` & `user_id`. | Trigger aborts with SQLSTATE `'45000'`. | Complainant mismatch rejected. |
| **TC-09** | Identity Integrity (UPDATE)| Update complaint to change `complainant_user_id`. | Trigger aborts with SQLSTATE `'45000'`. | Complainant ID is immutable. |
| **TC-10** | Assignment Uniqueness (INSERT)| Insert two active assignments for same complaint. | MySQL Error 1062 on `uq_single_active_assignment`. | Concurrent duplicate assignment impossible. |
| **TC-11** | Assignment Uniqueness (UPDATE)| Update an inactive assignment to `is_active = TRUE`. | MySQL Error 1062 on `uq_single_active_assignment`. | Cannot reactivate without deactivating incumbent. |
| **TC-12** | Assignment Sync | Reassign complaint via procedure. | `complaints.assigned_staff_id` equals new staff ID. | Cached pointer matches active ledger row. |
| **TC-13** | Trigger Replacement | Update status on complaint. Check history count. | Exactly one new row in `complaint_history`. | Zero duplicate history entries. |
| **TC-14** | Resolution Verification | Staff attempts direct transition to `Resolved`. | Rejected by service layer. | Must pass through `Resolution Pending Verification`.|
| **TC-15** | Officer Verification Only | Department Reviewer attempts to approve resolution. | HTTP 403 Forbidden. | Only Primary Officer can approve resolution. |
| **TC-16** | Audit Retention | Soft-delete a complaint; query history tables. | History, escalations, and verifications intact. | Zero audit cascade loss. |
| **TC-17** | CSRF Protection | Submit state-changing POST without CSRF token. | HTTP 400 Bad Request (CSRF token missing). | Request rejected prior to processing. |
| **TC-18** | Migration Recovery | Intentionally fail DDL Stage 4; restore snapshot. | Sandbox restored cleanly to checkpoint state. | Safe migration retry demonstrated. |

---

## 12. REVISED STAGED IMPLEMENTATION ROADMAP

```
┌────────────────────────────────────────────────────────────────────────┐
│                   STAGED IMPLEMENTATION ROADMAP                        │
├─────────┬──────────────────────────────────────────────────────────────┤
│ STAGE 1 │ Dual-Environment Provisioning & Read-Only Baseline Freeze    │
│ STAGE 2 │ Checkpointed Database Migration on Development Sandbox       │
│ STAGE 3 │ Core Identity, Normalized RBAC & Secure Bootstrap Service    │
│ STAGE 4 │ Complainant Portals (Student & External Workflows)           │
│ STAGE 5 │ Staff Work Queues, Canonical Assignments & Department Triage │
│ STAGE 6 │ Multi-Tier Escalation Engine & Decoupled Workflow Authority  │
│ STAGE 7 │ Resolution Verification Desk, Notifications & Tabler UI      │
│ STAGE 8 │ Full Acceptance Certification & Production Cutover Runbook   │
└─────────┴──────────────────────────────────────────────────────────────┘
```

### Stage 1: Dual-Environment Provisioning & Read-Only Baseline Freeze
- Create `backup_before_v2_frozen.sql` from `college_complaints`.
- Provision `college_complaints_v2_dev` and create unprivileged user `complaint_app_v2_dev`.
- Verify schema parity, row counts, and checksum consistency.
- Implement startup guard in `connect_db()`.

### Stage 2: Checkpointed Database Migration on Development Sandbox
- Deploy `schema_migrations` ledger.
- Apply migration scripts `001` through `007` with pre-stage checkpoint snapshots.
- Execute `006_data_backfill_and_consistency.py` to provision user accounts for existing 102 students and 15 staff members.
- Drop legacy trigger `trg_complaint_status_history` and install upgraded session-aware trigger.

### Stage 3: Core Identity, Normalized RBAC & Secure Bootstrap Service
- Implement `security.py` using Werkzeug's `scrypt` hashing, session hardening, and CSRF protection.
- Implement `auth.py` Blueprint (`/login`, `/register`, `/logout`, `/activate`).
- Implement CLI command `flask bootstrap-system` to initialize Admin and Primary Officer.
- Implement RBAC decorators (`@permission_required`, `@ownership_required`).

### Stage 4: Complainant Portals (Student & External Workflows)
- Create student dashboard (`/student/dashboard`) and student complaint submission route.
- Create external complainant dashboard (`/external/dashboard`) and external submission route.
- Enforce strict server-side identity binding via `session['user_id']`.

### Stage 5: Staff Work Queues, Canonical Assignments & Department Triage
- Implement staff personal work queue dashboard (`/staff/dashboard`).
- Implement canonical assignment management service synchronizing `complaint_assignments` and cached `assigned_staff_id`.
- Build Department Reviewer triage desk for ticket delegation.

### Stage 6: Multi-Tier Escalation Engine & Decoupled Workflow Authority
- Implement workflow evaluator based on `staff_workflow_assignments`.
- Build escalation dispatch handler with mandatory justification logging.
- Implement Level 2/3 supervisor review interfaces.

### Stage 7: Resolution Verification Desk, Notifications & Tabler UI
- Build Primary Complaint Management Officer dashboard:
  - Staff account verification desk (approve/reject/toggle).
  - Resolution verification queue (Approve -> `Resolved` / Return -> `In Progress`).
  - Cross-department performance metrics.
- Implement in-app notification center.
- Integrate Tabler UI components across all views with interactive audit timelines.

### Stage 8: Full Acceptance Certification & Production Cutover Runbook
- Execute automated acceptance test suite (TC-01 through TC-18) against `college_complaints_v2_dev`.
- Prepare final production cutover runbook.
- Present certified test results for explicit user approval prior to production rollout.

---

## CONCLUSION

The CampusCare 2.0 architecture specification is finalized. It incorporates database-enforced singleton authority, generated column assignment constraints, non-transactional DDL management, clean trigger replacement, accurate cryptographic standards, and strict dual-environment isolation.

**File Saved:** [CAMPUSCARE_V2_AUDIT_FINAL.md](file:///c:/Users/rayan/Desktop/dbms_pbl/CAMPUSCARE_V2_AUDIT_FINAL.md)  
**Status:** Architecture Specification Finalized · STRICTLY PLANNING ONLY.  
**Standing by for explicit user approval before proceeding to implementation.**

