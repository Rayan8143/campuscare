# CAMPUSCARE 2.0 – REVISED SYSTEM AUDIT & ARCHITECTURAL SPECIFICATION

**Document Version:** 2.1.0-REVISED  
**Audit Date:** November 14, 2026  
**Auditor:** Senior Full-Stack Engineer & Lead Database Architect  
**Project Workspace:** `c:\Users\rayan\Desktop\dbms_pbl`  
**Current Production Database:** `college_complaints` (Frozen & Protected Baseline)  
**Target Development Database:** `college_complaints_v2_dev` (Isolated Migration & Engineering Sandbox)  
**Status:** Architecture Revision Complete · Zero Code or Database Modifications Executed

---

## EXECUTIVE SUMMARY & MANDATORY AUDIT DIRECTIVES

Following review of the initial system audit, this revised architectural specification introduces critical corrections across ten vital dimensions of CampusCare 2.0:

1. **Strict Production Database Preservation:** The original `college_complaints` database is designated as a protected, read-only baseline. Initial development and migration execution occur exclusively in a dedicated sandbox database: `college_complaints_v2_dev`. All previously proposed destructive rollback commands (`DROP DATABASE IF EXISTS college_complaints`) are permanently rescinded.
2. **Realistic MySQL 8.0 Migration Strategy:** Corrects the flawed assumption of wrapping schema DDL in a single rollbackable transaction. MySQL 8.0 DDL statements trigger implicit commits. The revised strategy utilizes ordered, checkpointed migration scripts, schema version tracking, idempotency guards, and rigorous verification gates.
3. **Reconciled Status State Machine & Decoupled Workflow Tiers:** Reconciles the visible complaint status ENUM (`Submitted`, `In Progress`, `Escalated`, `Resolution Pending Verification`, `Resolved`, `Rejected`) with multi-tier workflow handling levels (`Level 1` through `Level 4`), guaranteeing that workflow progression and status changes are governed by strict transition guards.
4. **Normalized RBAC Architecture:** Replaces the flat role model with a fully normalized 5-table RBAC system (`users`, `roles`, `permissions`, `user_roles`, `role_permissions`). Establishes a secure bootstrap protocol, restricts public registration, and enforces the singleton constraint for the `PRIMARY_COMPLAINT_OFFICER`.
5. **Canonical Assignment Architecture:** Designates `complaint_assignments` as the canonical historical ledger, enforces a strict single-active-assignee business rule, and defines transactional synchronization for `complaints.assigned_staff_id`.
6. **Complainant Type & Identity Integrity:** Establishes mutual exclusivity and strict ownership between student profiles, external profiles, and authenticated user accounts, guaranteeing that legacy student records are preserved without corruption.
7. **Immutable Audit Retention & Trigger Coordination:** Eliminates cascade deletion vulnerabilities by enforcing `ON DELETE RESTRICT` and soft-delete patterns. Coordinates MySQL triggers with application context via safely managed connection-scoped session variables to eliminate double-logging.
8. **End-to-End Security Architecture:** Incorporates robust CSRF protection, Argon2id/bcrypt password hashing, rate limiting, secure session management, and a tokenized, non-default onboarding workflow for existing demonstration users.
9. **Reconciliation of Database Baseline Counts:** Reconciles historical report metrics with the active demonstration dataset (202 complaints, 102 students, 15 staff, 156 history entries), guaranteeing zero record truncation.
10. **Expanded Acceptance Testing:** Outlines twelve rigorous acceptance tests covering role isolation, verification gates, assignment integrity, and zero-loss migration.

---

## TABLE OF CONTENTS
1. [Database Preservation & Dual-Environment Architecture](#1-database-preservation--dual-environment-architecture)
2. [MySQL 8.0 DDL & Migration Strategy](#2-mysql-80-ddl--migration-strategy)
3. [Complaint Status State Machine & Workflow Tiers](#3-complaint-status-state-machine--workflow-tiers)
4. [Normalized RBAC & Primary Officer Architecture](#4-normalized-rbac--primary-officer-architecture)
5. [Complaint Assignment Consistency & Canonical Ledger](#5-complaint-assignment-consistency--canonical-ledger)
6. [Complainant Type Integrity & Profile Relationships](#6-complainant-type-integrity--profile-relationships)
7. [Immutable Audit Trail Retention & Trigger Coordination](#7-immutable-audit-trail-retention--trigger-coordination)
8. [Comprehensive Application & Infrastructure Security](#8-comprehensive-application--infrastructure-security)
9. [Baseline Database Count Reconciliation](#9-baseline-database-count-reconciliation)
10. [Expanded Acceptance Test Plan](#10-expanded-acceptance-test-plan)
11. [Revised Staged Implementation Roadmap](#11-revised-staged-implementation-roadmap)

---

## 1. DATABASE PRESERVATION & DUAL-ENVIRONMENT ARCHITECTURE

### 1.1 Strict Isolation Principle
The live database `college_complaints` holds the academic demonstration baseline. Modifying or testing schema alterations directly against this database risks unrecoverable data loss or corrupted table states.

**Policy:**
- The existing database `college_complaints` remains **100% read-only and untouched** throughout development.
- A completely distinct database named `college_complaints_v2_dev` will be instantiated for all development, migration testing, schema validation, and functional verification.
- Flask configuration in the development environment will point exclusively to `DB_NAME=college_complaints_v2_dev`.
- Transition of the production database `college_complaints` will only occur after full acceptance test certification and explicit user authorization.

### 1.2 Five-Step Development Environment Provisioning Procedure

```
┌────────────────────────────────────────────────────────────────────────┐
│             DEV ENVIRONMENT PROVISIONING & DATA PRESERVATION           │
├────────────────────────────────────────────────────────────────────────┤
│ Step 1: Pre-Migration Baseline Verification (Read-Only Audit)          │
│ Step 2: Forensic Timestamped Backup of Original Database              │
│ Step 3: Creation & Restoration of Development Database Sandbox         │
│ Step 4: Bitwise & Relational Validation of Restored Sandbox            │
│ Step 5: Sandbox Connection Configuration for Development               │
└────────────────────────────────────────────────────────────────────────┘
```

#### Step 1: Baseline Verification (Read-Only Audit)
Before taking a backup, execute read-only queries against `college_complaints` to capture baseline metrics:
```sql
USE college_complaints;
SELECT 'academic_departments' AS tbl, COUNT(*) AS cnt FROM academic_departments
UNION ALL SELECT 'departments', COUNT(*) FROM departments
UNION ALL SELECT 'staff', COUNT(*) FROM staff
UNION ALL SELECT 'students', COUNT(*) FROM students
UNION ALL SELECT 'complaints', COUNT(*) FROM complaints
UNION ALL SELECT 'complaint_history', COUNT(*) FROM complaint_history;
```
*Expected Baseline:* 10 academic departments, 5 departments, 15 staff, 102 students, 202 complaints, 156 complaint history records.

#### Step 2: Forensic Logical Backup
Generate a logical snapshot with routines, triggers, and single-transaction consistency:
```bash
mysqldump -u root -p --single-transaction --routines --triggers --events \
  --default-character-set=utf8mb4 --result-file="backup_before_v2_frozen.sql" \
  college_complaints
```

#### Step 3: Development Database Creation & Restoration
Create the isolated sandbox database and load the baseline snapshot:
```sql
CREATE DATABASE IF NOT EXISTS college_complaints_v2_dev 
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
```
```bash
mysql -u root -p college_complaints_v2_dev < backup_before_v2_frozen.sql
```

#### Step 4: Bitwise & Relational Validation
Verify that the restored sandbox matches the original byte-for-byte:
```sql
CHECKSUM TABLE 
  college_complaints.academic_departments, college_complaints_v2_dev.academic_departments,
  college_complaints.departments, college_complaints_v2_dev.departments,
  college_complaints.staff, college_complaints_v2_dev.staff,
  college_complaints.students, college_complaints_v2_dev.students,
  college_complaints.complaints, college_complaints_v2_dev.complaints,
  college_complaints.complaint_history, college_complaints_v2_dev.complaint_history;
```
Every pair of checksums must be strictly identical.

#### Step 5: Sandbox Development Configuration
Set local environment variables to target only the development sandbox:
```cmd
set DB_NAME=college_complaints_v2_dev
set FLASK_ENV=development
```

### 1.3 Permanent Rescission of Destructive Rollback Instructions
> [!CAUTION]
> **RESCINDED DIRECTIVE:**  
> The previous audit report included the command:  
> `DROP DATABASE IF EXISTS college_complaints;`  
> **This instruction is permanently rescinded and prohibited.**  
> Under no circumstances will automated scripts, rollback procedures, or migration runners issue a `DROP DATABASE` or `TRUNCATE` command against `college_complaints`.

If a migration in the development environment fails, only `college_complaints_v2_dev` may be re-initialized from `backup_before_v2_frozen.sql`.

---

## 2. MYSQL 8.0 DDL & MIGRATION STRATEGY

### 2.1 The Implicit Commit Reality in MySQL 8.0
In MySQL (InnoDB engine), Data Definition Language (DDL) operations—including `CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`, `CREATE INDEX`, and `DROP INDEX`—trigger an **implicit commit**. Any open transaction is committed immediately prior to and immediately after executing a DDL statement.

Therefore:
- **It is technically impossible to execute an entire multi-table schema migration within a single `START TRANSACTION ... ROLLBACK` block in MySQL.**
- A schema migration script that alters table columns and fails midway cannot be rolled back via SQL `ROLLBACK`.
- **Architectural Solution:** CampusCare 2.0 separates DDL operations from transactional DML operations, utilizing an ordered, checkpointed migration architecture with explicit forward-migration scripts and reverse-migration ("down") scripts.

### 2.2 Ordered Migration Architecture & Version Tracking
All schema evolutions are managed through a dedicated audit table:

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

### 2.3 Migration Stages & Script Breakdown

| Stage | Script Identifier | Operation Type | Purpose & Scope | Verification Checkpoint |
| :--- | :--- | :--- | :--- | :--- |
| **00** | `000_schema_migrations.sql` | Non-Transactional DDL | Creates `schema_migrations` ledger. | Table exists. |
| **01** | `001_core_rbac_schema.sql` | Non-Transactional DDL | Creates `users`, `roles`, `permissions`, `user_roles`, `role_permissions`, `external_complainants`. | 6 new tables present; FKs verified. |
| **02** | `002_rbac_initial_seeds.sql` | **Transactional DML** | Seeds default roles (`STUDENT`, `EXTERNAL`, `STAFF`, etc.) and system permissions. | 6 roles, 24 permissions seeded; committed atomically. |
| **03** | `003_workflow_escalation_schema.sql` | Non-Transactional DDL | Creates `workflow_levels`, `staff_workflow_assignments`, `complaint_escalations`. | Tables created; level constraints active. |
| **04** | `004_complaint_schema_extensions.sql` | Non-Transactional DDL | Modifies `complaints` (add `current_level_id`, `complainant_user_id`, `external_id`, extend status ENUM; make `student_id` NULL allowed). Modifies `staff` and `students` (add `user_id`). | `complaints` column structure updated; row count remains 202. |
| **05** | `005_assignment_and_verification_schema.sql` | Non-Transactional DDL | Creates `complaint_assignments`, `resolution_verifications`, `notifications`. | Tables created; single-active-assignment constraint active. |
| **06** | `006_data_backfill_and_consistency.py` | **Transactional DML** | Generates `users` accounts for 102 existing students and 15 staff members; synchronizes `complaints.complainant_user_id`; populates initial `complaint_assignments` from existing `assigned_staff_id`. | Atomically commits user mappings; 0 orphan records. |
| **07** | `007_triggers_and_views_update.sql` | Non-Transactional DDL | Updates trigger `trg_complaint_status_history` to support session variables; updates views `pending_complaints`, `complaint_details`. | Trigger and views compile without warnings. |

### 2.4 Idempotency & Checkpoint Recovery
1. **Idempotent Guards:** Every DDL script uses `CREATE TABLE IF NOT EXISTS` or queries `information_schema.COLUMNS` before executing `ALTER TABLE ADD COLUMN`.
2. **Pre-Stage Snapshot:** Before executing each migration script against `college_complaints_v2_dev`, a named snapshot is captured:
   ```bash
   mysqldump -u root -p college_complaints_v2_dev > checkpoint_pre_004.sql
   ```
3. **Recovery Procedure:** If script `004` encounters an error, the engineer restores `checkpoint_pre_004.sql`, inspects the migration log, and fixes the script before re-running.

---

## 3. COMPLAINT STATUS STATE MACHINE & WORKFLOW TIERS

### 3.1 Reconciled Status ENUM
The `complaints.status` column is redefined as:
```sql
status ENUM(
  'Submitted',
  'In Progress',
  'Escalated',
  'Resolution Pending Verification',
  'Resolved',
  'Rejected'
) NOT NULL DEFAULT 'Submitted'
```

### 3.2 Decoupling Visible Status from Workflow Handling Level
A core architectural flaw in basic ticketing systems is conflating the complaint status with the operational level of authority handling it.

In CampusCare 2.0:
- **Visible Complaint Status (`status`):** Communicates the macro life-cycle state to the complainant and dashboard (e.g., `In Progress`).
- **Workflow Tier Level (`current_level_id`):** An independent foreign key referencing `workflow_levels.level_id`:
  - `Level 1`: Frontline Staff / Technician
  - `Level 2`: Department Reviewer / Supervisor
  - `Level 3`: Department Head (HOD)
  - `Level 4`: Primary Complaint Management Officer

*Example:* A complaint can have status `In Progress` while being investigated at `Level 1` by a technician. If escalated, its status becomes `Escalated`, its tier updates to `Level 2`, and once the Level 2 supervisor begins review, its status transitions back to `In Progress` at `Level 2`.

### 3.3 Detailed State Transition Matrix

```
                          ┌──────────────────────────┐
                          │        SUBMITTED         │
                          │        (Level 1)         │
                          └─────────────┬────────────┘
                                        │
                    ┌───────────────────┼───────────────────┐
                    │ Staff Assign /    │ Reject (Invalid)  │
                    │ Acknowledge       ▼                   │
                    │            ┌─────────────┐            │
                    ▼            │  REJECTED   │            │
             ┌─────────────┐     │   (Final)   │            │
             │ IN PROGRESS │     └─────────────┘            │
             │  (Level 1)  │                                │
             └──────┬──────┘                                │
                    │                                       │
     ┌──────────────┴──────────────┐                        │
     │ Unresolved / SLA Breach     │ Staff Submits          │
     ▼                             │ Resolution             │
┌───────────┐                      ▼                        │
│ ESCALATED │           ┌───────────────────────┐           │
│ (Level 2) │           │  RESOLUTION PENDING   │           │
└─────┬─────┘           │     VERIFICATION      │           │
      │ Acknowledge     └───────────┬───────────┘           │
      ▼                             │                       │
┌─────────────┐       ┌─────────────┴─────────────┐         │
│ IN PROGRESS │       │ Officer Review            │         │
│  (Level 2)  │       ▼                           ▼         │
└──────┬──────┘ ┌───────────┐             ┌─────────────┐   │
       │        │ RESOLVED  │             │ IN PROGRESS │   │
       └────────┤  (Final)  │             │ (Returned)  ├───┘
   (Submits Res)└───────────┘             └─────────────┘
```

| Source Status | Target Status | Authorized Actor | Prerequisites & Mandatory Inputs | System Side-Effects |
| :--- | :--- | :--- | :--- | :--- |
| `Submitted` | `In Progress` | Assigned Staff, Dept Reviewer, Primary Officer | Active staff assignment must exist. | Sets investigation start time; sends complainant notification. |
| `Submitted` | `Rejected` | Dept Reviewer, Primary Officer | Mandatory rejection reason entered. | Complaint finalized; marks active assignment unassigned. |
| `In Progress` | `Escalated` | Assigned Staff (if authorized), Reviewer, Officer | Mandatory escalation justification; target level specified (`current_level_id + 1`). | Inserts `complaint_escalations` record; increments `current_level_id`; alerts target level staff. |
| `Escalated` | `In Progress` | Higher-Tier Assignee, Reviewer, Officer | Higher-tier staff member accepts assignment. | Reassigns ticket to higher-tier handler; sets assignment record. |
| `In Progress` | `Resolution Pending Verification` | Assigned Staff, Dept Reviewer | Mandatory resolution notes; description of corrective actions. | Transitions status; inserts `resolution_verifications` row (`decision='PENDING'`); alerts Primary Officer. |
| `Resolution Pending Verification` | `Resolved` | **Primary Complaint Management Officer ONLY** | Officer verifies resolution quality; enters approval remarks. | Updates `resolution_verifications` (`decision='APPROVED'`); sets `complaints.resolved_at = NOW()`; finalizes ticket. |
| `Resolution Pending Verification` | `In Progress` | **Primary Complaint Management Officer ONLY** | Officer rejects resolution; enters mandatory reinvestigation notes. | Updates `resolution_verifications` (`decision='RETURNED'`); alerts assigned staff of deficiencies. |

### 3.4 Multi-Layer Enforcement Protocol
1. **Database Stored Procedure Guard:** All status changes must pass through an updated stored procedure `transition_complaint_status(cid, new_status, actor_user_id, remarks)`. If an unauthorized transition is attempted, it signals SQLSTATE `'45000'`.
2. **Flask Service-Layer Validator:** The application layer validates user permissions and complaint ownership before executing database operations.

---

## 4. NORMALIZED RBAC & PRIMARY OFFICER DESIGN

### 4.1 Normalized 5-Table RBAC Schema
CampusCare 2.0 rejects flat, inflexible role flags in favor of a normalized, extensible structure:

```
┌──────────────┐       ┌──────────────┐       ┌──────────────┐
│    users     │       │  user_roles  │       │    roles     │
├──────────────┤       ├──────────────┤       ├──────────────┤
│ user_id*     │1     N│ user_id (FK) │N     1│ role_id*     │
│ username     ├───────┤ role_id (FK) ├───────┤ role_name    │
│ email        │       │ is_active    │       │ description  │
│ password_hash│       └──────────────┘       └──────┬───────┘
└──────────────┘                                     │ 1
                                                     │ N
┌──────────────┐       ┌──────────────────┐          │
│ permissions  │1     N│ role_permissions │          │
├──────────────┤       ├──────────────────┤          │
│ permission_id├───────┤ permission_id(FK)│          │
│ name         │       │ role_id (FK)     ├──────────┘
│ module       │       └──────────────────┘
└──────────────┘
```

#### DDL Definitions:
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
  FOREIGN KEY (`role_id`) REFERENCES `roles`(`role_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

### 4.2 Standard Seed Roles & Permission Mapping
- `STUDENT`: `complaint:submit_student`, `complaint:view_own`, `complaint:withdraw_own`.
- `EXTERNAL_USER`: `complaint:submit_external`, `complaint:view_own`.
- `STAFF`: `complaint:view_assigned`, `complaint:update_investigation`, `complaint:submit_resolution`, `complaint:request_escalation`.
- `DEPARTMENT_REVIEWER`: All `STAFF` permissions + `complaint:view_department_queue`, `complaint:assign_staff`, `complaint:reassign_staff`, `complaint:reject`, `complaint:escalate_tier`.
- `PRIMARY_COMPLAINT_OFFICER`: Global cross-department oversight, `complaint:view_all`, `complaint:reassign_global`, `complaint:verify_resolution`, `staff:verify_account`, `staff:toggle_active`, `report:view_global`.
- `SYSTEM_ADMIN`: Master system configuration, `system:manage_users`, `system:manage_roles`, `system:view_audit_logs`.

### 4.3 Public Registration Security Policy
> [!IMPORTANT]
> **REGISTRATION PRIVILEGE RESTRICTION:**  
> The public `/register` endpoint strictly prohibits the selection of privileged roles (`ADMIN`, `REVIEWER`, `PRIMARY_COMPLAINT_OFFICER`).

- If the registration form receives a payload requesting a privileged role, the request is immediately rejected with HTTP 400 (`"Invalid role requested."`).
- Public registration accepts only:
  1. `STUDENT`: Requires active student credentials, verified against college records.
  2. `EXTERNAL`: For visitors, parents, vendors, alumni.
  3. `STAFF_APPLICANT`: Creates a user with `user_type = 'STAFF'`, but sets `verification_status = 'PENDING'` and leaves `user_roles` unassigned. The user cannot access any complaint routes until explicitly approved by the Primary Officer.

### 4.4 Safe One-Time Initial Bootstrap CLI
To prevent security holes from hardcoded demo credentials, provisioning the initial `SYSTEM_ADMIN` and `PRIMARY_COMPLAINT_OFFICER` is handled via an idempotent, interactive Flask CLI command:

```bash
flask bootstrap-system --admin-email admin@campuscare.local --officer-email officer@campuscare.local
```
- **Operational Logic:**
  1. Checks if a user with `PRIMARY_OFFICER` or `SYSTEM_ADMIN` already exists in `user_roles`.
  2. If found, aborts with `"System is already bootstrapped."`
  3. Prompts securely for high-entropy passwords (or generates 16-character cryptographically secure temporary tokens).
  4. Hashes credentials using Argon2id/bcrypt.
  5. Creates records in `users` and assigns appropriate role mappings in `user_roles`.
  6. Prints an audit record to standard out with the setup timestamp.

### 4.5 Single Active Primary Officer Constraint
To enforce the business rule that **exactly one active Primary Complaint Management Officer exists at any given time**:
- **Database Trigger / Constraint:**
  ```sql
  DELIMITER $$
  CREATE TRIGGER `trg_enforce_single_primary_officer`
  BEFORE INSERT ON `user_roles` FOR EACH ROW
  BEGIN
    DECLARE v_officer_role_id INT;
    DECLARE v_active_officer_count INT;

    SELECT role_id INTO v_officer_role_id FROM roles WHERE role_name = 'PRIMARY_COMPLAINT_OFFICER';

    IF NEW.role_id = v_officer_role_id AND NEW.is_active = TRUE THEN
      SELECT COUNT(*) INTO v_active_officer_count 
      FROM user_roles 
      WHERE role_id = v_officer_role_id AND is_active = TRUE;

      IF v_active_officer_count > 0 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Violation: Exactly one active Primary Complaint Officer is permitted.';
      END IF;
    END IF;
  END$$
  DELIMITER ;
  ```
- Any succession or transfer of the Primary Officer role requires deactivating the incumbent record (`is_active = FALSE`) before activating the successor record.

---

## 5. COMPLAINT ASSIGNMENT CONSISTENCY & CANONICAL LEDGER

### 5.1 Canonical Source of Truth vs. Cached Assignee
To eliminate data anomalies and maintain high query performance:
1. **Canonical Ledger (`complaint_assignments`):** The definitive, historical source of truth for all assignment lifecycles. Every assignment, reassignment, and unassignment inserts a historical record.
2. **Denormalized Pointer (`complaints.assigned_staff_id`):** A fast-lookup cache used by standard index views to eliminate excessive subqueries.

### 5.2 Single Active Assignment Constraint
To prevent race conditions where a complaint is mistakenly assigned to multiple staff members simultaneously:
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
  -- Foreign Keys
  FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`assigned_staff_id`) REFERENCES `staff`(`staff_id`) ON DELETE RESTRICT,
  FOREIGN KEY (`assigned_by_user_id`) REFERENCES `users`(`user_id`) ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

**Constraint Enforcement:**
A trigger or partial unique index guarantees that for any given `complaint_id`, there is at most one record where `is_active = TRUE`:
```sql
DELIMITER $$
CREATE TRIGGER `trg_prevent_duplicate_active_assignment`
BEFORE INSERT ON `complaint_assignments` FOR EACH ROW
BEGIN
  IF NEW.is_active = TRUE THEN
    IF EXISTS (
      SELECT 1 FROM complaint_assignments 
      WHERE complaint_id = NEW.complaint_id AND is_active = TRUE
    ) THEN
      SIGNAL SQLSTATE '45000' 
      SET MESSAGE_TEXT = 'Complaint already has an active staff assignment.';
    END IF;
  END IF;
END$$
DELIMITER ;
```

### 5.3 Transactional Synchronization Procedure
Whenever a complaint is assigned or reassigned, the operation executes within a strict transaction:
```sql
-- Reassignment Transaction Example:
START TRANSACTION;
  -- 1. Inactivate existing active assignment
  UPDATE complaint_assignments 
  SET is_active = FALSE, unassigned_at = NOW() 
  WHERE complaint_id = p_complaint_id AND is_active = TRUE;

  -- 2. Insert new canonical assignment record
  INSERT INTO complaint_assignments 
    (complaint_id, assigned_staff_id, assigned_by_user_id, assignment_reason, is_active)
  VALUES 
    (p_complaint_id, p_new_staff_id, p_actor_user_id, p_reason, TRUE);

  -- 3. Synchronize cached assignee in complaints table
  UPDATE complaints 
  SET assigned_staff_id = p_new_staff_id 
  WHERE complaint_id = p_complaint_id;
COMMIT;
```

---

## 6. COMPLAINANT TYPE INTEGRITY & PROFILE RELATIONSHIPS

### 6.1 Relationship Architecture
To accommodate external community members while preserving all 102 existing student records and their 202 complaints:

```
                  ┌───────────────┐
                  │     users     │
                  ├───────────────┤
                  │ user_id*      │
                  │ user_type     │
                  └───────┬───────┘
                          │ 1
        ┌─────────────────┴─────────────────┐
        │ 1                                 │ 1
        ▼                                   ▼
┌───────────────┐                   ┌───────────────────────┐
│   students    │                   │ external_complainants │
├───────────────┤                   ├───────────────────────┤
│ student_id*   │                   │ external_id*          │
│ user_id (FK)  │                   │ user_id (FK)          │
│ full_name     │                   │ affiliation_type      │
│ academic_dept │                   │ organization_name     │
└───────┬───────┘                   └───────────┬───────────┘
        │ 1                                     │ 1
        │                                       │
        │ N (optional)                          │ N (optional)
        └───────────────────┬───────────────────┘
                            ▼
                ┌───────────────────────┐
                │      complaints       │
                ├───────────────────────┤
                │ complaint_id*         │
                │ complainant_user_id(FK)│ (Mandatory: points to users)
                │ student_id (FK, NULL) │ (Optional: points to students)
                │ external_id (FK,NULL) │ (Optional: points to external)
                └───────────────────────┘
```

### 6.2 Mutual Exclusivity & Ownership Integrity
To prevent corrupt combinations (such as a ticket linked to both a student and an external user, or a student ID belonging to User A linked to a complainant ID of User B):

1. **Table-Level CHECK Constraint:**
   ```sql
   ALTER TABLE `complaints`
   ADD CONSTRAINT `chk_complainant_mutual_exclusivity`
   CHECK (
     (`student_id` IS NOT NULL AND `external_id` IS NULL) OR
     (`student_id` IS NULL AND `external_id` IS NOT NULL)
   );
   ```

2. **Cross-Table Identity Validation Trigger:**
   ```sql
   DELIMITER $$
   CREATE TRIGGER `trg_validate_complaint_identity`
   BEFORE INSERT ON `complaints` FOR EACH ROW
   BEGIN
     DECLARE v_student_user_id INT;
     DECLARE v_external_user_id INT;

     IF NEW.student_id IS NOT NULL THEN
       SELECT user_id INTO v_student_user_id FROM students WHERE student_id = NEW.student_id;
       IF v_student_user_id IS NULL OR v_student_user_id <> NEW.complainant_user_id THEN
         SIGNAL SQLSTATE '45000' 
         SET MESSAGE_TEXT = 'Integrity violation: student_id does not belong to complainant_user_id.';
       END IF;
     END IF;

     IF NEW.external_id IS NOT NULL THEN
       SELECT user_id INTO v_external_user_id FROM external_complainants WHERE external_id = NEW.external_id;
       IF v_external_user_id IS NULL OR v_external_user_id <> NEW.complainant_user_id THEN
         SIGNAL SQLSTATE '45000' 
         SET MESSAGE_TEXT = 'Integrity violation: external_id does not belong to complainant_user_id.';
       END IF;
     END IF;
   END$$
   DELIMITER ;
   ```

---

## 7. IMMUTABLE AUDIT TRAIL RETENTION & TRIGGER COORDINATION

### 7.1 Elimination of Cascade Deletion & Audit Retention Policy
In CampusCare v1.0, `complaint_history` defined `FOREIGN KEY (complaint_id) REFERENCES complaints(complaint_id) ON DELETE CASCADE`. If a complaint was deleted, its entire history vanished.

**CampusCare 2.0 Audit Protection Rules:**
1. **No Cascade Deletion of Audit Logs:** All foreign keys on audit tables (`complaint_history`, `complaint_assignments`, `complaint_escalations`, `resolution_verifications`) are configured with `ON DELETE RESTRICT`.
2. **Soft-Deletion Pattern for Complaints:** Complaints are never physically deleted from the database. A complaint table extension adds:
   ```sql
   ALTER TABLE `complaints`
   ADD COLUMN `is_deleted` BOOLEAN NOT NULL DEFAULT FALSE,
   ADD COLUMN `deleted_at` DATETIME DEFAULT NULL,
   ADD COLUMN `deleted_by_user_id` INT DEFAULT NULL,
   ADD CONSTRAINT `fk_complaints_deleted_by` FOREIGN KEY (`deleted_by_user_id`) REFERENCES `users`(`user_id`);
   ```
3. Normal application views append `WHERE c.is_deleted = FALSE`.
4. Only System Administrators and Primary Officers have access to view soft-deleted tickets in an Archival Review Desk.

### 7.2 Coordinating `trg_complaint_status_history` with Application Logging
In v1.0, the trigger wrote the hardcoded remark `'Status updated from dashboard'` with no actor ID.

**Coordinated Session-Variable Architecture:**
To capture the exact user ID and remarks without modifying the basic trigger mechanism:
1. When Flask initiates a database connection to update a complaint, it sets session-scoped variables:
   ```python
   cur.execute("SET @app_user_id = %s, @app_remarks = %s, @app_action = %s;", 
               (current_user.id, remarks, action_type))
   ```
2. The revised trigger reads these variables:
   ```sql
   DELIMITER $$
   CREATE TRIGGER `trg_complaint_status_history_v2` AFTER UPDATE ON `complaints` FOR EACH ROW
   BEGIN
     IF OLD.status <> NEW.status THEN
       INSERT INTO complaint_history (
         complaint_id,
         old_status,
         new_status,
         changed_at,
         changed_by_user_id,
         remarks
       ) VALUES (
         NEW.complaint_id,
         OLD.status,
         NEW.status,
         NOW(),
         @app_user_id,
         COALESCE(@app_remarks, 'Status updated via application workflow')
       );
     END IF;
   END$$
   DELIMITER ;
   ```
3. **Connection Teardown / Cleanup:** Inside a Python context manager `try ... finally` block, the session variables are cleared immediately upon request completion:
   ```python
   try:
       # Execute status update
       ...
   finally:
       cur.execute("SET @app_user_id = NULL, @app_remarks = NULL, @app_action = NULL;")
   ```
4. **Zero Double-Logging:** The application layer does **not** insert into `complaint_history`. Status transitions are recorded exclusively by the trigger, while specialized domain events (reassignments, escalations, resolution reviews) are inserted into their own dedicated audit tables.

---

## 8. COMPREHENSIVE APPLICATION & INFRASTRUCTURE SECURITY

### 8.1 Defensive Security Architecture

| Threat / Vulnerability | Vector | CampusCare 2.0 Countermeasure | Implementation Mechanism |
| :--- | :--- | :--- | :--- |
| **CSRF** | Forged POST requests | Synchronizer Token Pattern | Flask-WTF / CSRFProtect. All forms embed `<input type="hidden" name="csrf_token" value="{{ csrf_token() }}">`. |
| **Weak Password Storage**| Credential database dump | Cryptographic Password Hashing | Argon2id (or bcrypt with work factor 12) via `werkzeug.security.generate_password_hash`. |
| **Session Hijacking** | Cookie theft / XSS | Secure Session Cookies | `SESSION_COOKIE_HTTPONLY = True`, `SESSION_COOKIE_SAMESITE = 'Lax'`, session ID regenerated on login. |
| **Brute Force Attacks** | Password guessing | IP & User Rate Limiting | Flask-Limiter: 5 failed login attempts per minute results in temporary IP/account lockout. |
| **SQL Injection** | Dynamic SQL strings | Strict Query Parameterization | 100% of queries use MySQL connector `%s` binding. Zero string formatting/f-strings. |
| **Stored & Reflected XSS**| Malicious text injection | Auto-Escaping & CSP | Jinja2 autoescaping enabled by default; Content-Security-Policy headers restricting script sources. |
| **Attachment Malware** | Future file uploads | Multi-Stage File Sanitation | File extension whitelist (`.pdf`, `.jpg`, `.png`), magic byte inspection via `python-magic`, UUID file renaming, storage outside webroot. |
| **Audit Log Tampering** | Rogue actor deletes log | MySQL DCL Privilege Restriction | Application DB user is granted `SELECT, INSERT` on history tables; `UPDATE` and `DELETE` privileges are strictly withheld. |

### 8.2 Safe Account Onboarding for Existing Demonstration Users
> [!CAUTION]
> **PROHIBITION OF INSECURE SHARED PASSWORDS:**  
> The 102 existing students and 15 staff members must NEVER be assigned an insecure shared default password (e.g., `"password123"`).

**Dual-Track Onboarding Strategy:**
1. **Production / Academic Staging Workflow (Secure Tokenized Activation):**
   - The migration backfill script populates `users` records with `password_hash = 'LOCKED_PENDING_ACTIVATION'` and `is_active = FALSE`.
   - Generates an `account_activations` record with a cryptographically secure 32-byte token and a 48-hour expiration.
   - Users activate their account by visiting `/activate?token=...` and establishing their private password.
2. **Local Academic Demonstration & Grading Mode:**
   - For offline evaluation or academic review where automated testing against pre-existing accounts is required, a dedicated Flask CLI command is provided:
     ```bash
     flask seed-eval-passwords --confirm
     ```
   - This command explicitly assigns distinct, documented credentials for evaluation personas (e.g., `officer@campuscare.local`, `staff1@example.edu`, `student1@example.edu`), printing a prominent warning that this mode is strictly for local grading.

---

## 9. BASELINE DATABASE COUNT RECONCILIATION

### 9.1 Forensic Reconciliation of Data Counts
The difference in figures between the academic documentation and the database backup files is reconciled as follows:

1. **Initial Report Drafting Snapshot (PBL Report Chapters 1–5):**
   - Early text in `CampusCare_DBMS_PBL_Report.pdf` references an initial baseline of **201 complaints and 45 students**.
2. **Test Client Execution Runs (PBL Report Chapter 7, Tests T01–T27):**
   - The test client runs documented in Section 7.3 executed 27 live tests against the running database, resulting in the creation of additional test complaints (e.g., complaint #202, student #102 'rohith').
3. **Final Frozen Backup (`backup_before_v2.sql`):**
   - Dumped on **November 14, 2026 at 14:25:12**, this snapshot captures the exact terminal state following the PBL test suite:

```
┌────────────────────────────────────────────────────────────────────────┐
│              EXACT BASELINE COUNTS IN BACKUP_BEFORE_V2.SQL             │
├──────────────────────────────┬─────────────────────────────────────────┤
│ Table Name                   │ Verified Row Count                      │
├──────────────────────────────┼─────────────────────────────────────────┤
│ `academic_departments`       │ 10 rows (IDs: 1 to 10)                  │
│ `departments`                │ 5 rows (IDs: 1 to 5)                    │
│ `staff`                      │ 15 rows (IDs: 1 to 15)                  │
│ `students`                   │ 102 rows (IDs: 1 to 102)                │
│ `complaints`                 │ 202 rows (IDs: 1 to 202)                │
│ `complaint_history`          │ 156 rows (IDs: 1 to 156)                │
└──────────────────────────────┴─────────────────────────────────────────┘
```

### 9.2 Non-Destructive Preservation Mandate
- **All 202 complaints, 102 students, 15 staff members, and 156 history rows will be preserved.**
- Under no circumstances will test complaints #201 or #202, or students #101 or #102, be deleted or truncated to artificially match earlier draft documentation.
- The development sandbox `college_complaints_v2_dev` will be restored directly from `backup_before_v2.sql`.

---

## 10. EXPANDED ACCEPTANCE TEST PLAN

The following twelve test cases must pass on `college_complaints_v2_dev` before the v2.0 upgrade is certified:

```
┌────────────────────────────────────────────────────────────────────────┐
│                   ACCEPTANCE TEST VERIFICATION MATRIX                  │
├───────┬────────────────────────────────────────────────────────────────┤
│ TC-01 │ Student Privacy & Cross-User Isolation                         │
│ TC-02 │ External Complainant Privacy & Profile Isolation               │
│ TC-03 │ Staff Queue Boundary & Unauthorized Modification Guard         │
│ TC-04 │ Single Active Primary Officer Enforcement                      │
│ TC-05 │ Public Registration Privilege Escalation Prevention            │
│ TC-06 │ Complainant Identity & Cross-Table Ownership Integrity         │
│ TC-07 │ Single Active Assignment & Reassignment History Integrity      │
│ TC-08 │ Escalation Hierarchy & Workflow Level Decoupling               │
│ TC-09 │ Resolution Verification Loop (Officer-Only Approval/Return)    │
│ TC-10 │ Audit Trail Retention & Non-Cascade Invariance                 │
│ TC-11 │ CSRF Protection & Injection Prevention                         │
│ TC-12 │ 100% Demonstration Record Preservation & Checksum Invariance   │
└───────┴────────────────────────────────────────────────────────────────┘
```

### Test Case Specifications

#### TC-01: Student Privacy & Ownership Isolation
- **Action:** Authenticate as Student A (`student1@example.edu`). Send `GET /complaints/2` (belonging to Student B).
- **Expected:** HTTP 403 Forbidden. Student dashboard counters reflect only Student A's complaints.

#### TC-02: External Complainant Privacy & Profile Isolation
- **Action:** Authenticate as External User A. Attempt to view External User B's ticket.
- **Expected:** HTTP 403 Forbidden. External complaint form validates external profile fields; requires no academic department.

#### TC-03: Staff Work Queue Boundaries
- **Action:** Authenticate as Staff Member A. Send `POST /complaints/<cid>/update` on a ticket assigned to Staff Member B.
- **Expected:** HTTP 403 Forbidden. Staff A cannot alter status or add investigation notes to tickets outside their assignment.

#### TC-04: Single Active Primary Officer Enforcement
- **Action:** Attempt to insert a second active `PRIMARY_COMPLAINT_OFFICER` into `user_roles`.
- **Expected:** Database trigger `trg_enforce_single_primary_officer` aborts with SQLSTATE `'45000'`.

#### TC-05: Public Registration Privilege Escalation Prevention
- **Action:** Submit `POST /register` with payload parameter `role=ADMIN` or `role=PRIMARY_COMPLAINT_OFFICER`.
- **Expected:** HTTP 400 Bad Request. System refuses registration; no privileged account is created.

#### TC-06: Complainant Identity Integrity
- **Action:** Attempt to insert a complaint record linking `student_id = 1` with a `complainant_user_id` belonging to a different user.
- **Expected:** Database trigger `trg_validate_complaint_identity` rejects the statement with SQLSTATE `'45000'`.

#### TC-07: Single Active Assignment & Canonical History
- **Action:** Assign a complaint to Staff A, then reassign to Staff B.
- **Expected:** Exactly one row in `complaint_assignments` has `is_active = TRUE`. Previous assignment has `is_active = FALSE` and `unassigned_at` populated. `complaints.assigned_staff_id` equals Staff B.

#### TC-08: Escalation Hierarchy Decoupling
- **Action:** Staff member with designation "Senior Lab Technician" but Level 1 workflow assignment attempts to approve a Level 2 escalation.
- **Expected:** HTTP 403 Forbidden. Workflow authority is evaluated against `staff_workflow_assignments`, ignoring job title.

#### TC-09: Resolution Verification Loop
- **Action:** Staff member marks complaint `Resolution Pending Verification`. Primary Officer logs in and executes `Return for Investigation` with notes.
- **Expected:** Ticket status reverts to `In Progress`. Complainant timeline shows officer remarks. Ticket cannot transition to `Resolved` without Primary Officer approval.

#### TC-10: Audit Trail Retention & Non-Cascade Invariance
- **Action:** Soft-delete a complaint record. Query `complaint_history`, `complaint_assignments`, and `complaint_escalations`.
- **Expected:** All audit records remain intact. Attempting a hard SQL `DELETE` triggers a foreign key restriction (`RESTRICT`).

#### TC-11: CSRF & Parameter Tampering Protection
- **Action:** Submit `POST /complaints/1/status` without a valid CSRF token.
- **Expected:** HTTP 400 Bad Request (CSRF token missing or invalid).

#### TC-12: Zero-Loss Migration & Checksum Invariance
- **Action:** Execute the complete migration pipeline on `college_complaints_v2_dev`.
- **Expected:** Row counts for legacy data match baseline: 10 academic departments, 5 departments, 15 staff, 102 students, 202 complaints, 156 history records.

---

## 11. REVISED STAGED IMPLEMENTATION ROADMAP

```
┌────────────────────────────────────────────────────────────────────────┐
│                   REVISED STAGED IMPLEMENTATION ROADMAP                │
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
- Instantiate and restore `college_complaints_v2_dev`.
- Validate identical table checksums.
- Lock `college_complaints` permissions to read-only during development.

### Stage 2: Checkpointed Database Migration on Development Sandbox
- Deploy `schema_migrations` tracking table.
- Apply ordered migration scripts `001` through `007` against `college_complaints_v2_dev`.
- Run `006_data_backfill_and_consistency.py` to provision user accounts for existing 102 students and 15 staff.
- Execute checkpoint validations.

### Stage 3: Core Identity, Normalized RBAC & Secure Bootstrap Service
- Implement `security.py` (Argon2id hashing, session security, CSRF protection, rate limiting).
- Build `auth.py` Blueprint (`/login`, `/logout`, `/register`, `/activate`).
- Implement CLI command `flask bootstrap-system`.
- Build RBAC authorization decorators (`@permission_required`, `@ownership_required`).

### Stage 4: Complainant Portals (Student & External Workflows)
- Create student dashboard (`/student/dashboard`) and student complaint submission route.
- Create external complainant dashboard (`/external/dashboard`) and specialized external submission route.
- Implement server-side identity derivation strictly from `session['user_id']`.

### Stage 5: Staff Work Queues, Canonical Assignments & Department Triage
- Implement staff personal work queue dashboard (`/staff/dashboard`).
- Build canonical assignment management service managing `complaint_assignments` and cached `assigned_staff_id`.
- Build Department Reviewer triage desk for ticket delegation.

### Stage 6: Multi-Tier Escalation Engine & Decoupled Workflow Authority
- Implement workflow level evaluator based strictly on `staff_workflow_assignments`.
- Build escalation dispatch handler with mandatory justification logging.
- Implement Level 2/3 supervisor review interfaces.

### Stage 7: Resolution Verification Desk, Notifications & Tabler UI
- Build Primary Complaint Management Officer dashboard:
  - Staff account verification desk (approve/reject/toggle).
  - Resolution verification queue (Approve -> `Resolved` / Return -> `In Progress`).
  - Cross-department performance metrics.
- Implement in-app notification center.
- Implement Tabler UI components across all views with interactive audit timelines.

### Stage 8: Full Acceptance Certification & Production Cutover Runbook
- Execute automated acceptance test suite (TC-01 through TC-12) against `college_complaints_v2_dev`.
- Prepare final cutover migration documentation.
- Present certified test results for explicit user approval prior to production rollout.

---

## CONCLUSION

This revised audit and architecture document provides an architecturally sound, secure, and non-destructive blueprint for CampusCare 2.0. By isolating all initial work to `college_complaints_v2_dev`, accounting for MySQL 8.0 implicit commit behavior, normalizing RBAC, and decoupling workflow tiers from employment designations, the proposed architecture guarantees complete security, strict privacy, and zero data loss.

**File Saved:** [CAMPUSCARE_V2_AUDIT_REVISED.md](file:///c:/Users/rayan/Desktop/dbms_pbl/CAMPUSCARE_V2_AUDIT_REVISED.md)  
**Status:** Audit Revision Complete · No code or database changes executed.  
**Standing by for explicit user approval before proceeding to implementation.**

