# CAMPUSCARE 2.0 – COMPREHENSIVE SYSTEM AUDIT & ARCHITECTURE SPECIFICATION

**Document Version:** 2.0.0-AUDIT  
**Audit Date:** November 14, 2026  
**Auditor:** Senior Full-Stack Engineer & Lead Database Architect  
**Project Workspace:** `c:\Users\rayan\Desktop\dbms_pbl`  
**Current Project Baseline:** CampusCare v1.0 (Academic Prototype)  
**Target Architecture:** CampusCare v2.0 (Multi-User, Role-Based Complaint Escalation & Resolution Verification Platform)  
**Status:** Audit & Architecture Specification (Zero Modifications to Existing Code or Database)

---

## EXECUTIVE SUMMARY

CampusCare was originally built as a Database Management Systems (DBMS) academic prototype demonstrating three-tier web application architecture, relational normalization (Boyce-Codd Normal Form / BCNF), active database rules (triggers), database views, transactions, concurrency control, and Data Control Language (DCL) permissions.

While the existing database layer is normalized, robust, and populated with **202 active demonstration complaints, 102 students, 15 staff members, 10 academic departments, 5 service departments, and 154 status history records**, the current application layer (`app.py` and `templates/index.html`) operates as an unauthenticated single-page demonstration dashboard. It suffers from critical architectural limitations:
1. **Absence of Authentication & Access Control:** Zero login, registration, or session-based authorization. Any anonymous visitor can view all complaints and arbitrarily alter complaint statuses.
2. **Monolithic Complainant Assumption:** Every complainant is presumed to be an enrolled student with an academic department. External campus community members (parents, visitors, vendors, contractors, alumni) cannot submit or track complaints.
3. **Unused Assignment Infrastructure:** Although `assigned_staff_id` exists in the database schema, `app.py` has zero logic to assign complaints, track staff workloads, or provide individualized staff queues.
4. **Missing Escalation & Verification Layers:** There is no mechanism for tier-based complaint escalation, reviewer supervision, or administrative verification of submitted resolutions.
5. **Divergence Between Application and Database Rules:** The database stored procedure `update_complaint_status` explicitly forbids reopening or altering final statuses (`Resolved` or `Rejected`), whereas `app.py` directly executes SQL statements bypassing this procedure and permitting arbitrary status transitions.

This audit report delivers a complete, non-destructive blueprint to upgrade CampusCare to version 2.0 without losing any of the 202 existing demonstration records, without modifying current database tables, and without breaking backward compatibility.

---

## TABLE OF CONTENTS
1. [Existing System Architecture Audit](#1-existing-system-architecture-audit)
2. [Existing Database Architecture & Integrity Audit](#2-existing-database-architecture--integrity-audit)
3. [Current Application Functionality & Defect Analysis](#3-current-application-functionality--defect-analysis)
4. [Identified Gaps & Missing Functionality](#4-identified-gaps--missing-functionality)
5. [Proposed CampusCare 2.0 Architecture](#5-proposed-campuscare-20-architecture)
6. [Recommended Database Schema Evolution & Safe Migration](#6-recommended-database-schema-evolution--safe-migration)
7. [User Interface Modernization Plan](#7-user-interface-modernization-plan)
8. [Comprehensive Implementation Roadmap](#8-comprehensive-implementation-roadmap)
9. [Risk Analysis, Safety Protocols & Rollback Strategies](#9-risk-analysis-safety-protocols--rollback-strategies)
10. [Acceptance Test Matrix](#10-acceptance-test-matrix)

---

## 1. EXISTING SYSTEM ARCHITECTURE AUDIT

### 1.1 Project Structure & File Inventory
The workspace contains a compact, lightweight Flask and MySQL project:

```
c:\Users\rayan\Desktop\dbms_pbl\
│
├── app.py                            # Flask application entry point (191 lines)
├── requirements.txt                  # Python dependencies (Flask 3.x, mysql-connector-python 9.x)
├── README.md                         # Deployment and setup documentation
├── static/
│   └── style.css                     # Custom responsive CSS stylesheet (minified, 2,928 bytes)
├── templates/
│   └── index.html                    # Single monolithic Jinja2 HTML template (21 lines, 3,875 bytes)
│
├── schema.sql                        # Legacy prototype DDL & seed script (21 lines)
├── schema_latest.sql                 # MySQL dump DDL, Views, Trigger & Stored Procedure (391 lines)
├── backup_before_v2.sql              # Active full snapshot: DDL + all 202 demo records (71,234 bytes)
├── college_complaints_backup.sql     # Baseline full backup (71,248 bytes)
└── CampusCare_DBMS_PBL_Report.pdf    # Comprehensive 45-page academic project documentation
```

### 1.2 Flask Entry Point & Application Flow
- **Entry point:** `app.py` runs a Flask development server (`app.run(debug=True)`) at `http://127.0.0.1:5000`.
- **Secret key configuration:** `app.secret_key = os.getenv("FLASK_SECRET_KEY", "local-demo-key")`. This key is currently used solely for Flask session cookies powering the `flash()` messaging system.
- **Database Connection Mechanism:** `connect_db()` function establishes a direct connection via `mysql.connector.connect()` on every incoming request. It does not utilize connection pooling (`mysql.connector.pooling.MySQLConnectionPool`).
- **Connection Configuration:**
  - `DB_HOST` (default: `localhost`)
  - `DB_USER` (default: `complaint_app`)
  - `DB_PASSWORD` (default: `""`)
  - `DB_NAME` (default: `college_complaints`)

### 1.3 Audit of Existing Flask Routes

| Route Path | HTTP Method | Handler Function | Operational Logic & Database Interaction | Current Security / Validation State |
| :--- | :--- | :--- | :--- | :--- |
| `/` | `GET` | `index()` | 1. Executes 3-table join (`complaints`, `students`, `departments`) ordered by `created_at DESC`.<br>2. Executes 3 `COUNT(*)` queries for total, opened (`Submitted`, `In Progress`), and `Resolved`.<br>3. Fetches service departments and academic departments for dropdown population.<br>4. Renders `index.html`. | **Public / Unprotected.** All complaints across all departments are exposed to any visitor. |
| `/complaints` | `POST` | `submit()` | 1. Extracts form parameters.<br>2. Validates non-empty fields, integer IDs, and hardcoded sets for category and priority.<br>3. Executes upsert into `students` table via `INSERT INTO students ... ON DUPLICATE KEY UPDATE`.<br>4. Retrieves `student_id` by email.<br>5. Inserts record into `complaints` with default status `Submitted` and NULL `assigned_staff_id`.<br>6. Commits transaction or rolls back on exception. Redirects to `/`. | **Anonymous Submission.** No verification of email ownership. Any visitor can submit complaints under any student's name/email. |
| `/complaints/<int:cid>/status` | `POST` | `update(cid)` | 1. Validates status against `{'Submitted', 'In Progress', 'Resolved', 'Rejected'}`.<br>2. Executes `UPDATE complaints SET status = %s, resolved_at = CASE WHEN %s = 'Resolved' THEN NOW() ELSE NULL END WHERE complaint_id = %s`.<br>3. Commits transaction; triggers `trg_complaint_status_history`.<br>4. Redirects to `/`. | **Critical Authorization Vulnerability.** No caller identity or authorization check. Anyone can change any complaint status. If `cid` does not exist, it silently redirects (0 rows affected). |

### 1.4 Frontend & Asset Audit
- **HTML Template (`templates/index.html`):**
  - Contains three primary UI sections: Stats Counter Strip (Total, Open, Resolved), "Submit an Issue" Form, and "All Complaints" Data Table.
  - The complaints table embeds an individual inline `<form>` inside the "Update" column for every row, allowing immediate status changes via a `<select>` dropdown and "Save" `<button>`.
  - Inline Client-Side Search: A 3-line vanilla JavaScript listener filters table rows by string matching against `tr.innerText`.
- **CSS Stylesheet (`static/style.css`):**
  - Modern typography using `system-ui` and Inter font stack.
  - Custom responsive layout with CSS Grid and media queries targeting screens under 680px.
  - Uses CSS custom properties for palette (`#29488f` primary blue, `#f3f6fb` slate background, `#e5f7ec` success green).

---

## 2. EXISTING DATABASE ARCHITECTURE & INTEGRITY AUDIT

### 2.1 Database Overview & Active Baseline
- **Database Engine:** MySQL 8.0.46 (InnoDB storage engine, UTF-8 `utf8mb4_unicode_ci`).
- **Active Snapshot Data (from `backup_before_v2.sql`):**
  - `academic_departments`: 10 rows
  - `departments`: 5 rows
  - `staff`: 15 rows
  - `students`: 102 rows
  - `complaints`: 202 rows (Complaints #1 through #202)
  - `complaint_history`: 154 rows

### 2.2 Schema Reconciliations & Discrepancies
An important reconciliation was discovered between the early prototype `schema.sql` and the active production database (`schema_latest.sql` / `backup_before_v2.sql` / `CampusCare_DBMS_PBL_Report.pdf`):
- In `schema.sql`, the `students` table had an unnormalized free-text column `department VARCHAR(100)` and no `academic_departments` table.
- In the active working database (`schema_latest.sql`), this was normalized into an independent `academic_departments` table with an integer foreign key `students.academic_department_id`, achieving Boyce-Codd Normal Form (BCNF). `app.py` reflects this normalized schema.
- **Audit Mandate:** All CampusCare 2.0 extensions must build upon `schema_latest.sql` and `backup_before_v2.sql`, preserving `academic_departments`.

### 2.3 Detailed Table Structure Audit

```
┌─────────────────────────┐       ┌──────────────────────┐
│  academic_departments   │       │     departments      │
├─────────────────────────┤       ├──────────────────────┤
│ academic_department_id* │       │ department_id*       │
│ department_name (UQ)    │       │ department_name (UQ) │
└────────────┬────────────┘       │ description          │
             │ 1                  └──────────┬───────────┘
             │                               │ 1
             │ N                             │
┌────────────┴────────────┐                  │ N
│        students         │       ┌──────────┴───────────┐
├─────────────────────────┤       │        staff         │
│ student_id*             │       ├──────────────────────┤
│ full_name               │       │ staff_id*            │
│ email (UQ)              │       │ department_id (FK)   │
│ phone                   │       │ full_name            │
│ academic_dept_id (FK)   │       │ email (UQ)           │
└────────────┬────────────┘       └──────────┬───────────┘
             │ 1                             │ 1 (optional)
             │                               │
             │ N                             │ N
┌────────────┴───────────────────────────────┴───────────┐
│                       complaints                       │
├────────────────────────────────────────────────────────┤
│ complaint_id*                                          │
│ student_id (FK)                                        │
│ department_id (FK)                                     │
│ assigned_staff_id (FK, NULL allowed)                   │
│ title                                                  │
│ description                                            │
│ category                                               │
│ priority ENUM('Low', 'Medium', 'High')                 │
│ status ENUM('Submitted','In Progress','Resolved','...') │
│ created_at TIMESTAMP                                   │
│ resolved_at DATETIME (NULL allowed)                    │
└────────────────────────────┬───────────────────────────┘
                             │ 1
                             │ N (Identifying / CASCADE)
┌────────────────────────────┴───────────────────────────┐
│                   complaint_history                    │
├────────────────────────────────────────────────────────┤
│ history_id*                                            │
│ complaint_id (FK, ON DELETE CASCADE)                   │
│ old_status                                             │
│ new_status                                             │
│ changed_at TIMESTAMP                                   │
│ remarks                                                │
└────────────────────────────────────────────────────────┘
```

#### Table: `academic_departments`
- `academic_department_id` INT AUTO_INCREMENT PRIMARY KEY
- `department_name` VARCHAR(100) NOT NULL UNIQUE
- *Existing Records:* 10 branches (CSE, CSE AIML, ECE, CSE DS, CSE CS, Mechanical, Civil, MBA, Pharmacy, ECE VLCS).

#### Table: `students`
- `student_id` INT AUTO_INCREMENT PRIMARY KEY
- `full_name` VARCHAR(100) NOT NULL
- `email` VARCHAR(120) NOT NULL UNIQUE
- `phone` VARCHAR(20) DEFAULT NULL
- `academic_department_id` INT NOT NULL (FK -> `academic_departments.academic_department_id`)
- *Existing Records:* 102 student records.

#### Table: `departments`
- `department_id` INT AUTO_INCREMENT PRIMARY KEY
- `department_name` VARCHAR(100) NOT NULL UNIQUE
- `description` VARCHAR(255) DEFAULT NULL
- *Existing Records:* 5 departments (1: Maintenance, 2: IT Support, 3: Hostel Office, 4: Laboratory, 5: Housekeeping).

#### Table: `staff`
- `staff_id` INT AUTO_INCREMENT PRIMARY KEY
- `department_id` INT NOT NULL (FK -> `departments.department_id`)
- `full_name` VARCHAR(100) NOT NULL
- `email` VARCHAR(120) NOT NULL UNIQUE
- *Existing Records:* 15 staff members distributed across the 5 service departments.

#### Table: `complaints`
- `complaint_id` INT AUTO_INCREMENT PRIMARY KEY
- `student_id` INT NOT NULL (FK -> `students.student_id`)
- `department_id` INT NOT NULL (FK -> `departments.department_id`)
- `assigned_staff_id` INT DEFAULT NULL (FK -> `staff.staff_id`)
- `title` VARCHAR(180) NOT NULL
- `description` TEXT NOT NULL
- `category` VARCHAR(50) NOT NULL
- `priority` ENUM('Low','Medium','High') NOT NULL DEFAULT 'Medium'
- `status` ENUM('Submitted','In Progress','Resolved','Rejected') NOT NULL DEFAULT 'Submitted'
- `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP (Indexed)
- `resolved_at` DATETIME DEFAULT NULL
- *Existing Records:* 202 complaints.

#### Table: `complaint_history`
- `history_id` INT AUTO_INCREMENT PRIMARY KEY
- `complaint_id` INT NOT NULL (FK -> `complaints.complaint_id` ON DELETE CASCADE)
- `old_status` VARCHAR(30) DEFAULT NULL
- `new_status` VARCHAR(30) NOT NULL
- `changed_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP
- `remarks` VARCHAR(255) DEFAULT NULL
- *Existing Records:* 154 historical transitions.

### 2.4 Existing Triggers, Views & Stored Procedures

#### 1. Trigger: `trg_complaint_status_history`
```sql
CREATE TRIGGER `trg_complaint_status_history` AFTER UPDATE ON `complaints` FOR EACH ROW 
BEGIN
    IF OLD.status <> NEW.status THEN
        INSERT INTO complaint_history(complaint_id, old_status, new_status, remarks) 
        VALUES (NEW.complaint_id, OLD.status, NEW.status, 'Status updated from dashboard');
    END IF;
END;
```
*Audit Observation:* This trigger intercepts all status updates on `complaints`. Because it automatically inserts into `complaint_history`, any application-level status transition logic in CampusCare 2.0 must be coordinated carefully to prevent double-inserting history entries.

#### 2. Stored Procedure: `update_complaint_status`
```sql
CREATE PROCEDURE `update_complaint_status`(
    IN p_complaint_id INT,
    IN p_new_status VARCHAR(30)
)
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_current_status VARCHAR(30);

    SELECT COUNT(*) INTO v_count FROM complaints WHERE complaint_id = p_complaint_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Complaint does not exist';
    ELSEIF p_new_status NOT IN ('Submitted', 'In Progress', 'Resolved', 'Rejected') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid complaint status';
    ELSE
        SELECT status INTO v_current_status FROM complaints WHERE complaint_id = p_complaint_id;
        IF v_current_status IN ('Resolved', 'Rejected') AND p_new_status <> v_current_status THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot change a final complaint status';
        ELSE
            UPDATE complaints
            SET status = p_new_status,
                resolved_at = CASE WHEN p_new_status = 'Resolved' THEN COALESCE(resolved_at, NOW()) ELSE NULL END
            WHERE complaint_id = p_complaint_id;
        END IF;
    END IF;
END;
```
*Audit Observation:* As revealed during testing in the PBL report, `app.py` bypassed this stored procedure and ran inline SQL instead, allowing reopening of resolved complaints.

#### 3. Database Views
1. `pending_complaints`: Filters `complaints` joined with `students` and `departments` where status is in `('Submitted', 'In Progress')`.
2. `complaint_details`: Full denormalized 4-table join including `academic_departments`.
3. `open_complaints`: `SELECT * FROM complaint_details WHERE status IN ('Submitted', 'In Progress')`.
4. `department_complaint_summary`: Aggregate query grouping by department with total, resolved, and pending counts.

---

## 3. CURRENT APPLICATION AUDIT & DEFECT ANALYSIS

### 3.1 Hardcoded Assumptions
1. **Complainant Identity Assumption:** `app.py` requires `student_name`, `email`, and `academic_department_id` on every complaint submission. Complainants cannot be faculty, administrative staff, parents, alumni, or external visitors.
2. **Category Hardcoding:** Categories are hardcoded in `app.py` as `{"Infrastructure", "Hostel", "Laboratory", "Network", "Cleanliness", "Other"}`. There is no category master table in MySQL.
3. **Department Hardcoding:** In `templates/index.html`, categories and priorities are hardcoded option tags rather than data-driven models.
4. **Single Global Namespace:** The application views all complaints in one unified table without scope filtering.

### 3.2 Vulnerability & Technical Debt Analysis
1. **Zero Access Control (OWASP Top 10 A01: Broken Access Control):**
   - No login session check on any route.
   - Any user can forge a `POST` request to `/complaints/<cid>/status` and alter any ticket's status.
2. **Missing CSRF Protection (OWASP A05: Security Misconfiguration):**
   - The status update form and submission form omit CSRF tokens. Any malicious website visited by a user could execute state-changing requests against CampusCare.
3. **Deprecated MySQL Syntax in Upsert:**
   - In `app.py`: `ON DUPLICATE KEY UPDATE full_name = VALUES(full_name), academic_department_id = VALUES(academic_department_id)`.
   - In MySQL 8.0.20+, the `VALUES()` function inside `ON DUPLICATE KEY UPDATE` is deprecated and produces warnings. It should use table row aliases (e.g., `AS new_val ON DUPLICATE KEY UPDATE full_name = new_val.full_name`).
4. **Unhandled Foreign Key Errors:**
   - Submitting an invalid `department_id` triggers an uncaught MySQL error 1452 resulting in an unhandled HTTP 500 error page.
5. **Silent Missing Record Failure:**
   - Calling `/complaints/999999/status` executes an `UPDATE` that matches 0 rows, raises no error, and redirects to `/` without informing the user.

---

## 4. MISSING FUNCTIONALITY SUMMARY

| Capability Area | CampusCare v1.0 (Current) | CampusCare v2.0 (Required) |
| :--- | :--- | :--- |
| **Authentication** | None (Anonymous open dashboard) | Multi-role session authentication with bcrypt password hashing |
| **Complainant Types** | Enrolled Students only | Students + External Users (Parents, Vendors, Visitors, Alumni) |
| **Submission Portals** | Single unified form requiring academic dept | Specialized student form & distinct external complainant form |
| **Staff Queue** | None (assigned staff column unused) | Dedicated staff work queue displaying assigned tickets |
| **Reviewer Oversight** | None | Department Reviewer queue for departmental oversight & triage |
| **Central Authority** | None | Dedicated `PRIMARY_COMPLAINT_OFFICER` with global authority |
| **Staff Verification** | None | Officer approval/rejection workflow for staff registrations |
| **Resolution Process** | Any visitor can flip status to `Resolved` | Staff submits resolution notes -> Status becomes `Resolution Pending Verification` -> Officer reviews and Approves or Returns |
| **Escalation Management** | None | Multi-tier escalation levels decoupled from job designations |
| **Audit & Actor Tracking** | Trigger logs static string 'Status updated from dashboard' | Exact `changed_by_user_id` logged for every assignment, status change, escalation, and verification |
| **Notifications** | None | In-app notification center for status changes, assignments, and returns |
| **Personalized Dashboards**| Single demo admin view for everyone | Tailored dashboards for Students, Externals, Staff, Reviewers, Primary Officer, and Admin |

---

## 5. PROPOSED CAMPUSCARE 2.0 ARCHITECTURE

### 5.1 Multi-User Authentication & RBAC Model
CampusCare 2.0 introduces a centralized `users` table linked to specialized profile tables. Server-side session management establishes identity, preventing client-side spoofing.

#### User Roles & Permission Matrix

```
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                                 CAMPUSCARE 2.0 RBAC MATRIX                             │
├──────────────────────────┬───────┬──────────┬───────┬──────────┬───────────────┬───────┤
│ Permission / Action      │Student│ External │ Staff │ Reviewer │Primary Officer│ Admin │
├──────────────────────────┼───────┼──────────┼───────┼──────────┼───────────────┼───────┤
│ Submit Student Complaint │   ✓   │    —     │   —   │    —     │       —       │   ✓   │
│ Submit External Complaint│   —   │    ✓     │   —   │    —     │       —       │   ✓   │
│ View Own Complaints      │   ✓   │    ✓     │   —   │    —     │       —       │   —   │
│ View Assigned Work Queue │   —   │    —     │   ✓   │    —     │       —       │   —   │
│ Investigate & Submit Res.│   —   │    —     │   ✓   │    —     │       —       │   —   │
│ Department Queue Triage  │   —   │    —     │   —   │    ✓     │       —       │   —   │
│ Department Reassignment  │   —   │    —     │   —   │    ✓     │       ✓       │   ✓   │
│ Escalate Complaint       │   —   │    —     │   ✓*  │    ✓     │       ✓       │   ✓   │
│ Verify Staff Accounts    │   —   │    —     │   —   │    —     │       ✓       │   —   │
│ Approve/Return Resolution│   —   │    —     │   —   │    —     │       ✓       │   —   │
│ Global Audit & Reports   │   —   │    —     │   —   │    —     │       ✓       │   ✓   │
│ System / Master Config   │   —   │    —     │   —   │    —     │       —       │   ✓   │
└──────────────────────────┴───────┴──────────┴───────┴──────────┴───────────────┴───────┘
*Subject to explicit workflow-level permissions.
```

### 5.2 Decoupling Staff Designation from Workflow Authority
> [!IMPORTANT]
> **CRITICAL ARCHITECTURAL PRINCIPLE:**  
> Job titles or employee designations (e.g., "Junior Technician", "Network Engineer", "Assistant Professor") must NEVER be used to infer workflow permissions or escalation handling capacity.

CampusCare 2.0 achieves strict decoupling via two independent constructs:
1. **Employment Designation:** Stored as an informational attribute in the `staff` profile (e.g., `designation = 'Electrician Grade I'`).
2. **Workflow Authority Mapping:** Stored in an explicit junction table `staff_workflow_assignments` linking `user_id` to `workflow_level_id` with specific capability flags (`can_escalate`, `can_resolve`, `department_scope`).
   - A staff member only receives tickets matching their active workflow level.
   - An escalation level change checks `staff_workflow_assignments`, completely ignoring employee job titles.

### 5.3 Primary Complaint Management Officer (`PRIMARY_COMPLAINT_OFFICER`)
CampusCare 2.0 defines a singleton application-level executive authority:
- **Designation Separation:** The Primary Officer role is an application capability assigned to a designated user account, not an inherent HR job title.
- **Single Active Officer Rule:** Enforced via a business rule / database constraint ensuring exactly one user holds the active Primary Officer assignment at any point in time.
- **Thirteen Core Executive Powers:**
  1. Complete global visibility across all 5 service departments.
  2. Inspection of all active and historical ticket assignments.
  3. Verification of newly registered staff accounts.
  4. Approval or rejection of staff account verification with audit logging.
  5. Immediate activation or deactivation of staff system access.
  6. Real-time monitoring of each staff member's workload and open ticket counts.
  7. Oversight of all staff investigation notes and status updates.
  8. Rigorous review of submitted resolutions.
  9. Formal returning of inadequate resolutions for reinvestigation with mandatory notes.
  10. Reassignment of complaints between staff members and across departments.
  11. Real-time review and intervention in escalation events.
  12. End-to-end audit trail inspection with complete actor provenance.
  13. Generation and export of staff-wise, category-wise, and department-wise KPI reports.

### 5.4 State Machine & Resolution Verification Workflow

```
   ┌────────────────────────────────────────────────────────┐
   │                   SUBMITTED (Level 1)                  │
   └───────────────────────────┬────────────────────────────┘
                               │ Staff assigned & starts work
                               ▼
   ┌────────────────────────────────────────────────────────┐
   │                      IN PROGRESS                       │
   └─────────────┬────────────────────────────┬─────────────┘
                 │                            │ Inability to resolve /
                 │ Staff finishes             │ SLA breach
                 │ investigation              ▼
                 │               ┌──────────────────────────┐
                 │               │        ESCALATED         │
                 │               │   (Level 2 / Level 3)    │
                 │               └────────────┬─────────────┘
                 │                            │ Re-investigated
                 ▼                            ▼
   ┌────────────────────────────────────────────────────────┐
   │           RESOLUTION PENDING VERIFICATION              │
   └───────────────────────────┬────────────────────────────┘
                               │
            ┌──────────────────┴──────────────────┐
            │ Primary Officer Review              │
            ▼                                     ▼
 [Officer Approves]                    [Officer Returns]
            │                                     │
            ▼                                     ▼
┌────────────────────────┐            ┌──────────────────────┐
│        RESOLVED        │            │     IN PROGRESS      │
│     (Final Status)     │            │(With Re-investigation│
└────────────────────────┘            │        Notes)        │
                                      └──────────────────────┘
```

#### Permitted Status Transitions & Authority Enforcement

| Current Status | Target Status | Permitted Actor | Prerequisite Conditions |
| :--- | :--- | :--- | :--- |
| `Submitted` | `In Progress` | Assigned Staff, Reviewer, Primary Officer | Complaint has assigned staff member. |
| `In Progress` | `Resolution Pending Verification` | Assigned Staff, Reviewer | Resolution notes provided; evidence uploaded/documented. |
| `In Progress` | `Escalated` | Assigned Staff (if authorized), Reviewer, Officer | Escalation reason recorded; target level specified. |
| `Escalated` | `In Progress` | Escalation Target Staff, Reviewer | Higher-tier staff acknowledges and begins investigation. |
| `Resolution Pending Verification` | `Resolved` | **Primary Complaint Management Officer ONLY** | Resolution evidence verified; officer comments recorded. |
| `Resolution Pending Verification` | `In Progress` (Returned) | **Primary Complaint Management Officer ONLY** | Re-investigation notes supplied explaining deficiency. |
| `Submitted` / `In Progress` | `Rejected` | Reviewer, Primary Complaint Officer | Justification provided (duplicate, out of scope, invalid). |

---

## 6. RECOMMENDED DATABASE SCHEMA EVOLUTION & SAFE MIGRATION

### 6.1 Database Design Philosophy: Additive-Only Evolution
To guarantee 100% preservation of the existing 202 demonstration complaints, 102 students, and 15 staff members, the database migration strategy is strictly **additive**:
- Zero existing columns will be dropped or renamed.
- Existing demonstration records will remain fully intact.
- New foreign keys added to existing tables will be nullable (`NULL allowed`) during migration.
- A deterministic data backfill script will automatically provision `users` accounts for all existing students and staff members so existing demonstration complaints are immediately claimable and viewable in v2.0.

### 6.2 New Tables Specification

#### 1. `users` (Core Authentication & Identity)
```sql
CREATE TABLE IF NOT EXISTS `users` (
  `user_id` INT AUTO_INCREMENT PRIMARY KEY,
  `username` VARCHAR(120) NOT NULL UNIQUE,
  `email` VARCHAR(120) NOT NULL UNIQUE,
  `password_hash` VARCHAR(255) NOT NULL,
  `full_name` VARCHAR(100) NOT NULL,
  `user_type` ENUM('STUDENT', 'EXTERNAL', 'STAFF', 'REVIEWER', 'PRIMARY_OFFICER', 'ADMIN') NOT NULL,
  `is_active` BOOLEAN NOT NULL DEFAULT TRUE,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX `idx_users_type_active` (`user_type`, `is_active`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

#### 2. `external_complainants` (Profile for Non-Student Users)
```sql
CREATE TABLE IF NOT EXISTS `external_complainants` (
  `external_id` INT AUTO_INCREMENT PRIMARY KEY,
  `user_id` INT NOT NULL UNIQUE,
  `affiliation_type` ENUM('Parent', 'Alumni', 'Vendor', 'Contractor', 'Visitor', 'Other') NOT NULL,
  `organization_name` VARCHAR(150) DEFAULT NULL,
  `phone` VARCHAR(20) NOT NULL,
  `address` VARCHAR(255) DEFAULT NULL,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

#### 3. `workflow_levels` (Escalation Hierarchy Definitions)
```sql
CREATE TABLE IF NOT EXISTS `workflow_levels` (
  `level_id` INT AUTO_INCREMENT PRIMARY KEY,
  `level_number` INT NOT NULL UNIQUE,
  `level_name` VARCHAR(60) NOT NULL UNIQUE,
  `description` VARCHAR(255) DEFAULT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Initial Seed Levels:
-- 1: Frontline Staff / Technician
-- 2: Department Reviewer / Supervisor
-- 3: Department Head (HOD)
-- 4: Primary Complaint Management Officer
```

#### 4. `staff_workflow_assignments` (Decoupled Workflow Authority)
```sql
CREATE TABLE IF NOT EXISTS `staff_workflow_assignments` (
  `assignment_id` INT AUTO_INCREMENT PRIMARY KEY,
  `user_id` INT NOT NULL,
  `department_id` INT NOT NULL,
  `level_id` INT NOT NULL,
  `can_escalate` BOOLEAN NOT NULL DEFAULT FALSE,
  `can_resolve` BOOLEAN NOT NULL DEFAULT TRUE,
  `assigned_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY `uk_user_dept_level` (`user_id`, `department_id`, `level_id`),
  FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE CASCADE,
  FOREIGN KEY (`department_id`) REFERENCES `departments`(`department_id`),
  FOREIGN KEY (`level_id`) REFERENCES `workflow_levels`(`level_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

#### 5. `complaint_assignments` (Assignment & Reassignment Audit Trail)
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
  INDEX `idx_active_staff_assignment` (`assigned_staff_id`, `is_active`),
  FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE CASCADE,
  FOREIGN KEY (`assigned_staff_id`) REFERENCES `staff`(`staff_id`),
  FOREIGN KEY (`assigned_by_user_id`) REFERENCES `users`(`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

#### 6. `complaint_escalations` (Escalation Event Audit Log)
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
  FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE CASCADE,
  FOREIGN KEY (`from_level_id`) REFERENCES `workflow_levels`(`level_id`),
  FOREIGN KEY (`to_level_id`) REFERENCES `workflow_levels`(`level_id`),
  FOREIGN KEY (`escalated_by_user_id`) REFERENCES `users`(`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

#### 7. `resolution_verifications` (Officer Review Log)
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
  FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE CASCADE,
  FOREIGN KEY (`submitted_by_staff_id`) REFERENCES `staff`(`staff_id`),
  FOREIGN KEY (`officer_user_id`) REFERENCES `users`(`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

#### 8. `notifications` (In-App Notification Center)
```sql
CREATE TABLE IF NOT EXISTS `notifications` (
  `notification_id` INT AUTO_INCREMENT PRIMARY KEY,
  `user_id` INT NOT NULL,
  `complaint_id` INT DEFAULT NULL,
  `title` VARCHAR(150) NOT NULL,
  `message` TEXT NOT NULL,
  `is_read` BOOLEAN NOT NULL DEFAULT FALSE,
  `created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  INDEX `idx_user_unread_notif` (`user_id`, `is_read`),
  FOREIGN KEY (`user_id`) REFERENCES `users`(`user_id`) ON DELETE CASCADE,
  FOREIGN KEY (`complaint_id`) REFERENCES `complaints`(`complaint_id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

### 6.3 Extensions to Existing Tables

#### Alterations to `students`:
- Add `user_id INT NULL UNIQUE` (FK -> `users.user_id`). Allows linking authenticated student login accounts to existing student records.

#### Alterations to `staff`:
- Add `user_id INT NULL UNIQUE` (FK -> `users.user_id`).
- Add `designation VARCHAR(100) NOT NULL DEFAULT 'Staff Member'`. (Employment designation, completely independent of workflow authority).
- Add `verification_status ENUM('PENDING', 'VERIFIED', 'REJECTED') NOT NULL DEFAULT 'PENDING'`.
- Add `verified_by_user_id INT NULL` (FK -> `users.user_id`).
- Add `verified_at DATETIME NULL`.
- Add `is_active BOOLEAN NOT NULL DEFAULT TRUE`.

#### Alterations to `complaints`:
- Modify `student_id` to allow `NULL` (so external user complaints do not require a student row).
- Add `external_id INT NULL` (FK -> `external_complainants.external_id`).
- Add `complainant_user_id INT NULL` (FK -> `users.user_id`, indexed for high-performance personal history queries).
- Add `current_level_id INT NOT NULL DEFAULT 1` (FK -> `workflow_levels.level_id`).
- Extend `status` ENUM to: `ENUM('Submitted', 'In Progress', 'Resolution Pending Verification', 'Resolved', 'Rejected')`.
- Add `resolution_notes TEXT NULL`.

#### Alterations to `complaint_history`:
- Add `changed_by_user_id INT NULL` (FK -> `users.user_id`).
- Add `action_type VARCHAR(40) NOT NULL DEFAULT 'STATUS_CHANGE'`.

### 6.4 Coordination with Existing Database Trigger
The active trigger `trg_complaint_status_history` fires automatically whenever `OLD.status <> NEW.status` and writes into `complaint_history` with the static remark `'Status updated from dashboard'`.

**Coexistence Strategy for CampusCare 2.0:**
To prevent duplicate history records when the application logs transitions:
1. The trigger can be updated in a controlled manner to read a session variable (e.g., `@app_current_user_id` and `@app_status_remarks`) using MySQL's `IFNULL(@app_current_user_id, NULL)` logic.
2. Alternatively, the application delegates the basic status transition recording to the trigger, while storing rich metadata (escalation reasons, reassignments, officer resolution reviews) in the specialized tables (`complaint_escalations`, `complaint_assignments`, `resolution_verifications`).
3. This guarantees zero duplication while capturing the complete audit history.

---

## 7. USER INTERFACE MODERNIZATION PLAN

### 7.1 Recommended UI Framework: Tabler UI
We strongly recommend **Tabler UI** (open-source, MIT license, built on top of Bootstrap 5).

#### Architectural Justification for Tabler UI over Plain Bootstrap or Custom CSS:
1. **100% Jinja2 & Flask Compatible:** Tabler operates using standard HTML5 and vanilla JavaScript/CSS. It requires zero Node.js build pipelines, webpack, or npm daemons during development.
2. **Pre-Built Dashboard Cards & Metric Strips:** Features turnkey UI components for KPI summary cards, workload progress bars, and alert badges.
3. **Native Chronological Timeline Component:** Includes an out-of-the-box vertical timeline layout (`tabler-timeline`), ideal for presenting the complaint life cycle, status transitions, staff comments, and resolution verification decisions.
4. **Mobile Responsiveness:** Features off-canvas mobile drawer navigation, responsive data tables, and touch-friendly controls.
5. **No Architectural Replacements:** Preserves Flask, Jinja2 templates, and the current static directory structure.

### 7.2 Page Layout & Component Specifications

#### A. Authentication Views (`templates/auth/`)
- `login.html`: Unified, clean login card with email and password fields, validation feedback, and password visibility toggle.
- `register.html`: Tabbed or segmented registration selector allowing user to register either as:
  - **Student Complainant:** Full name, university email, academic department dropdown, mobile phone number, password.
  - **External Complainant:** Full name, personal/work email, phone number, visitor category (Parent, Vendor, Visitor, Alumni), organization, password.
  - **Staff Member:** Full name, staff email, service department dropdown, employee designation (for informational profile), password. Note: Displays immediate notice that staff accounts require Primary Complaint Officer verification before access is unlocked.

#### B. Student Personal Dashboard (`templates/student/dashboard.html`)
- **KPI Metrics:** 4 summary cards showing Total Submitted, In Progress, Resolved, and Rejected complaints.
- **Action Strip:** Prominent "+ Lodge New Complaint" button navigating to the dedicated student submission form.
- **Private Complaint Registry:** Paginated table displaying only the authenticated student's complaints with columns: ID, Title, Category, Responsible Department, Priority Pill, Current Status Badge, Submission Date, and Action (`View Timeline`).

#### C. External Complainant Dashboard (`templates/external/dashboard.html`)
- Dedicated view identical in security and privacy to the student dashboard, displaying the external user's personal complaint history, current status counters, and full timeline views.

#### D. Staff Work Queue Dashboard (`templates/staff/dashboard.html`)
- **Queue Overview:** Assigned Tickets, Active Investigations, Awaiting Resolution Verification, Resolved by Staff.
- **Action Queue Table:** Shows complaints currently assigned to the logged-in staff member with priority color-coding, days open, and "Update Investigation" action button.
- **Investigation Modal / Drawer:** Allows staff to submit interim investigation notes, request escalation to Level 2 (if permitted), or submit resolution notes triggering transition to `Resolution Pending Verification`.

#### E. Department Reviewer Dashboard (`templates/reviewer/dashboard.html`)
- **Departmental Overview:** Real-time breakdown of all open complaints within the reviewer's department.
- **Triage & Assignment Panel:** Interface to assign unassigned complaints to specific department staff members.
- **Workload Balancing View:** Visual bar charts indicating current open ticket volume per department staff member.
- **Department Escalation Queue:** Review of tickets escalated from Level 1 frontline staff.

#### F. Primary Complaint Management Officer Dashboard (`templates/officer/dashboard.html`)
- **Central Oversight Panel:** High-level metrics across all 5 service departments (Maintenance, IT Support, Hostel Office, Laboratory, Housekeeping).
- **Staff Account Verification Desk:**
  - Table of pending staff registrations displaying Name, Department, Designation, and Registration Timestamp.
  - One-click "Approve Account" or "Reject Registration" buttons.
  - Staff workload and status toggle (Active / Deactivated).
- **Resolution Verification Queue:**
  - Dedicated table of all complaints in `Resolution Pending Verification` status.
  - Inspection modal showing student description, assigned staff notes, and submitted resolution.
  - Actions: **"Approve Resolution & Mark Resolved"** or **"Return to Staff for Further Investigation"** (requiring explanatory notes).
- **Global Assignment & Reassignment Desk:** Ability to reassign any complaint across departments and staff.
- **Department & Staff KPI Reports:** Exportable summary tables analyzing mean time to resolution (MTTR) and open backlogs.

#### G. Complaint Timeline & Audit Detail View (`templates/common/complaint_detail.html`)
- Universal detail view shared across roles (rendered according to permission level).
- Features a vertical Tabler timeline displaying:
  1. Ticket submission timestamp and original complaint details.
  2. Initial department assignment and staff assignment.
  3. Intermediate investigation notes.
  4. Escalation events (Level transitions, reasons, authorized user).
  5. Resolution submission by staff.
  6. Primary Complaint Officer review (Approval or Return event with notes).
  7. Final resolution timestamp.

---

## 8. COMPREHENSIVE IMPLEMENTATION ROADMAP

```
┌────────────────────────────────────────────────────────────────────────┐
│                   STAGED IMPLEMENTATION ROADMAP                        │
├─────────┬──────────────────────────────────────────────────────────────┤
│ STAGE 1 │ Database Evolution & Data Preservation Migration              │
│ STAGE 2 │ Authentication, Session Management & RBAC Framework          │
│ STAGE 3 │ Student & External Complainant Portals                       │
│ STAGE 4 │ Staff Assignment Engine & Individual Work Queues             │
│ STAGE 5 │ Escalation Hierarchy & Workflow Authority Decoupling         │
│ STAGE 6 │ Resolution Verification Workflow & In-App Notification Center│
│ STAGE 7 │ UI Modernization with Tabler UI & Template Modularization    │
│ STAGE 8 │ Rigorous End-to-End Acceptance Testing & Documentation       │
└─────────┴──────────────────────────────────────────────────────────────┘
```

### Stage 1: Database Architecture & Safe Data Migration
- **Objective:** Provision all new tables and columns while strictly preserving all 202 existing demonstration complaints and historical records.
- **Files to Create:**
  - `migrations/v2_migration.sql` (additive DDL script).
  - `migrations/v2_backfill_users.py` (idempotent migration script to create `users` records for existing 102 students and 15 staff).
- **Files Modified:** None (existing schema files left untouched as historical baselines).
- **New Tables Created:** `users`, `external_complainants`, `workflow_levels`, `staff_workflow_assignments`, `complaint_assignments`, `complaint_escalations`, `resolution_verifications`, `notifications`.
- **Migration Risks:** Breaking existing foreign key constraints or duplicate email collisions.
- **Mitigation:** Run migration inside a MySQL transaction with pre-validation checksum checks (`CHECKSUM TABLE`).
- **Acceptance Gate:** Checksums of existing tables match; row counts for complaints (202), students (102), staff (15), and complaint_history (154) remain identical.

### Stage 2: Authentication, Session Management & RBAC Framework
- **Objective:** Implement secure user registration, password hashing, session-based identity derivation, and route decorators for role authorization.
- **Files to Create:**
  - `auth.py` (Blueprint for `/login`, `/register`, `/logout`).
  - `security.py` (Password hashing utilities via `werkzeug.security`, RBAC decorators: `@login_required`, `@roles_accepted(*roles)`).
  - `templates/auth/login.html`, `templates/auth/register.html`.
- **Files Modified:** `app.py` (register authentication blueprint, configure secure session cookies).
- **Migration Risks:** Session fixation or insecure cookie configuration.
- **Mitigation:** Enforce `SESSION_COOKIE_HTTPONLY = True`, `SESSION_COOKIE_SAMESITE = 'Lax'`, and session regeneration on login.
- **Acceptance Gate:** Unauthenticated users attempting to access protected routes are redirected to `/login`; invalid credentials return clear error messages without leaking user enumeration.

### Stage 3: Student & External Complainant Portals
- **Objective:** Provide private, authenticated complaint history dashboards and dedicated submission forms for students and external community members.
- **Files to Create:**
  - `routes/student.py` (Student dashboard and submission handler).
  - `routes/external.py` (External user dashboard and submission handler).
  - `templates/student/dashboard.html`, `templates/student/new_complaint.html`.
  - `templates/external/dashboard.html`, `templates/external/new_complaint.html`.
- **Files Modified:** `app.py`.
- **Migration Risks:** Cross-user data leakage where Student A views complaints of Student B.
- **Mitigation:** The application derives identity strictly from `session['user_id']`, binding it via SQL parameterization (`WHERE complainant_user_id = %s`).
- **Acceptance Gate:** Student A is physically unable to query, view, or count complaints belonging to Student B.

### Stage 4: Staff Assignment Engine & Individual Work Queues
- **Objective:** Activate the dormant `assigned_staff_id` architecture and provide authenticated staff members with dedicated work queues.
- **Files to Create:**
  - `routes/staff.py` (Staff dashboard, investigation updates, work queue queries).
  - `templates/staff/dashboard.html`, `templates/staff/work_queue.html`.
- **Files Modified:** `app.py`.
- **Migration Risks:** Staff member modifying a complaint assigned to a colleague.
- **Mitigation:** The update handler enforces an ownership query: `SELECT complaint_id FROM complaints WHERE complaint_id = %s AND assigned_staff_id = %s`.
- **Acceptance Gate:** Staff member A cannot update or submit notes for a complaint assigned to Staff member B unless explicitly granted reviewer/reassignment privileges.

### Stage 5: Escalation Hierarchy & Workflow Authority Decoupling
- **Objective:** Implement multi-tier escalation management where authority is derived from `staff_workflow_assignments`, completely independent of job titles.
- **Files to Create:**
  - `routes/escalation.py` (Escalation request handler, department triage).
  - `templates/reviewer/dashboard.html`, `templates/reviewer/escalations.html`.
- **Files Modified:** `app.py`.
- **Migration Risks:** Conflating employment designation with workflow level.
- **Mitigation:** Strict database join against `staff_workflow_assignments` checking `can_escalate` and `level_id`.
- **Acceptance Gate:** A staff member with designation "Senior Engineer" but Level 1 workflow assignment cannot approve escalations or resolve Level 2 tickets.

### Stage 6: Resolution Verification Workflow & In-App Notification Center
- **Objective:** Establish the Primary Complaint Management Officer oversight desk, verification of submitted resolutions, and real-time in-app alerts.
- **Files to Create:**
  - `routes/officer.py` (Officer dashboard, staff account verification, resolution approval/return desk).
  - `services/notifications.py` (Notification dispatch service).
  - `templates/officer/dashboard.html`, `templates/officer/staff_monitor.html`, `templates/officer/resolution_queue.html`.
  - `templates/components/notification_dropdown.html`.
- **Files Modified:** `app.py`.
- **Migration Risks:** Race conditions during concurrent review or duplicate notifications.
- **Mitigation:** Wrap resolution verification and return actions in explicit database transactions with row-level locking (`FOR UPDATE`).
- **Acceptance Gate:** A complaint in `Resolution Pending Verification` can ONLY transition to `Resolved` through an approved officer verification action.

### Stage 7: UI Modernization with Tabler UI & Template Modularization
- **Objective:** Upgrade from the monolithic `templates/index.html` to a modular, responsive Tabler UI layout.
- **Files to Create:**
  - `templates/base.html` (Master layout, responsive navbar, notification bell, user profile avatar).
  - `templates/common/complaint_detail.html` (Vertical audit timeline).
  - Tabler CSS and JS vendor assets stored locally in `static/vendor/tabler/`.
- **Files Modified:** `static/style.css` (custom overrides only).
- **Migration Risks:** Broken styles or unresponsive layouts on mobile screens.
- **Mitigation:** Utilize Tabler's tested responsive grid and test against common viewport widths (375px, 768px, 1200px).
- **Acceptance Gate:** All forms, tables, and timelines render cleanly across mobile and desktop browsers.

### Stage 8: Rigorous End-to-End Acceptance Testing & Documentation
- **Objective:** Execute the comprehensive test suite verifying RBAC isolation, data integrity, and legacy record survival.
- **Files to Create:**
  - `tests/test_v2_rbac.py` (Pytest / Flask test client suite).
  - `tests/test_v2_workflow.py` (Workflow state machine test suite).
  - `CAMPUSCARE_V2_USER_MANUAL.md` (Operational user guide).
- **Files Modified:** `README.md` (updated setup and role instructions).
- **Acceptance Gate:** 100% of the 12 core acceptance tests pass with zero regressions.

---

## 9. RISK ANALYSIS, SAFETY PROTOCOLS & ROLLBACK STRATEGIES

### 9.1 Risk Analysis & Preventive Controls

| Risk Description | Severity | Impact | Mitigation & Preventive Protocol |
| :--- | :--- | :--- | :--- |
| **Demonstration Data Corruption** | Critical | Loss of 202 academic test complaints | Mandatory pre-migration cold backup (`backup_before_v2.sql`). Migration executes strictly additive DDL. |
| **Duplicate History Entries** | High | Trigger and app both inserting history rows | Refactor trigger to coordinate with application user context or isolate trigger to status updates while logging extended events in specialized tables. |
| **Client-Side Identity Forgery** | Critical | Student views or modifies peer's complaints | Identity strictly derived from server-side encrypted session cookies (`session['user_id']`). Never accept complainant IDs from URL or body parameters. |
| **Bypassing Workflow Authority** | High | Staff acts on ticket based on job title | RBAC checks query `staff_workflow_assignments`, ignoring job title strings. |
| **Deprecated MySQL Syntax** | Low | Warning logs in MySQL 8.0+ | Modernize all upsert queries using standard row-alias syntax (`AS new_row ON DUPLICATE KEY UPDATE`). |

### 9.2 Zero-Downtime Rollback Strategy
Should any anomaly occur during subsequent migration execution:
1. **Immediate Database Rollback:**
   ```sql
   DROP DATABASE IF EXISTS college_complaints;
   CREATE DATABASE college_complaints CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   USE college_complaints;
   SOURCE c:/Users/rayan/Desktop/dbms_pbl/backup_before_v2.sql;
   ```
2. **Application Reversion:** Revert `app.py` to the baseline v1.0 commit/file.
3. **Verification:** Confirm row counts match exactly: 202 complaints, 102 students, 15 staff, 154 history entries.

---

## 10. ACCEPTANCE TEST MATRIX

The table below outlines the 12 mandatory acceptance tests required to certify CampusCare 2.0 readiness:

| Test ID | Test Description | Target Role / Actor | Test Execution Steps | Expected Outcome | Pass Criteria |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **TC-01** | Student Privacy Isolation | Student A vs Student B | Log in as Student A; attempt to fetch `/complaints/<id>` belonging to Student B. | Server returns HTTP 403 Forbidden. | Zero cross-student data leakage. |
| **TC-02** | External User Isolation | External A vs External B | Log in as External User A; request dashboard and ticket details of External User B. | Server returns HTTP 403 Forbidden; ticket list shows only External A's records. | Strict ownership enforcement. |
| **TC-03** | Staff Queue Boundary | Staff A vs Staff B | Staff A attempts to update or post investigation notes on Staff B's assigned ticket. | Server returns HTTP 403 Forbidden; transaction rejected. | Staff confined to assigned tickets. |
| **TC-04** | Unauthorized Status Transition | Staff Member | Staff attempts to transition a ticket directly from `In Progress` to `Resolved`. | Server returns HTTP 400 Bad Request; requires submission for verification. | Direct resolution prohibited for staff. |
| **TC-05** | Unassigned Ticket Modification | Staff Member | Staff attempts status change on an unassigned ticket. | Server returns HTTP 403 Forbidden. | Only assignees/reviewers can update. |
| **TC-06** | Primary Officer Global Access | Primary Complaint Officer | Primary Officer requests complaints and assignments across all 5 departments. | Server returns HTTP 200 with complete cross-department data. | Global oversight verified. |
| **TC-07** | Staff Account Verification | Primary Complaint Officer | Newly registered staff attempts login (blocked as PENDING); Officer approves; staff logs in. | Unapproved login returns HTTP 403; approved login returns HTTP 200. | Staff access strictly gated. |
| **TC-08** | Resolution Review Workflow | Staff & Primary Officer | Staff submits resolution (`Pending Verification`); Officer reviews and returns for further investigation. | Ticket status returns to `In Progress` with return notes displayed on timeline. | Controlled verification loop verified. |
| **TC-09** | Actor Provenance Audit | All Roles | Perform status change, reassignment, and escalation; inspect `complaint_history` and audit tables. | Every event contains exact `changed_by_user_id` and timestamp. | Zero anonymous audit rows. |
| **TC-10** | Dashboard Metric Precision | Student Complainant | Fetch student dashboard counters and compare against `SELECT COUNT(*) WHERE complainant_user_id = %s`. | Displayed counters equal exact database count for that student. | Strict metric accuracy. |
| **TC-11** | Escalation Chain Tracking | Staff & Reviewer | Escalate ticket from Level 1 to Level 2 with reason; inspect timeline. | Timeline shows from_level, to_level, reason, actor, and timestamp. | Complete escalation history preserved. |
| **TC-12** | Demonstration Data Integrity | System Migration | Execute schema evolution and data backfill; query legacy records. | All 202 complaints, 102 students, and 154 history entries survive intact. | 100% legacy record preservation. |

---

## CONCLUSION & READINESS FOR IMPLEMENTATION

The CampusCare project has a solid, well-modeled relational foundation with Boyce-Codd Normal Form normalization and active database rules. However, the application layer currently lacks authentication, role separation, work queue routing, and verification controls.

The architecture and implementation plan specified in this audit document provides an additive, non-destructive upgrade path to CampusCare 2.0. It fulfills all mandatory functional and security requirements while guaranteeing the safety and preservation of all 202 existing demonstration records.

**AUDIT COMPLETE. STANDING BY FOR EXPLICIT USER APPROVAL BEFORE PROCEEDING TO IMPLEMENTATION.**

