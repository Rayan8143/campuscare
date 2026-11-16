"""
Migration: 006_data_backfill_and_sync.py
Purpose: Transactional DML migration backfilling users, activation tokens,
         role mappings, workflow assignments, complainant links, and legacy assignments.
Note: STRICTLY DML ONLY. Zero DDL statements are executed in this script.
"""

import os
import sys
import hashlib
import secrets
import datetime
import mysql.connector

def run_backfill(connection):
    cur = connection.cursor(dictionary=True)
    try:
        print("[006_data_backfill] Starting transactional DML backfill...")

        # 1. Preflight Email Collision Check
        cur.execute("""
            SELECT s.email, s.full_name AS student_name, st.full_name AS staff_name
            FROM students s
            INNER JOIN staff st ON LOWER(s.email) = LOWER(st.email)
        """)
        collisions = cur.fetchall()
        if collisions:
            raise RuntimeError(f"FATAL: Email collision detected between students and staff: {collisions}")
        print("  [✓] Preflight email collision check passed (0 collisions).")

        # 2. Backfill Students into `users` (is_active = FALSE)
        cur.execute("SELECT student_id, full_name, email FROM students ORDER BY student_id")
        students = cur.fetchall()

        student_user_map = {}
        for s in students:
            # Check if user already exists
            cur.execute("SELECT user_id FROM users WHERE email = %s", (s["email"],))
            existing = cur.fetchone()
            if existing:
                u_id = existing["user_id"]
            else:
                cur.execute("""
                    INSERT INTO users (username, email, password_hash, full_name, is_active)
                    VALUES (%s, %s, %s, %s, FALSE)
                """, (s["email"], s["email"], "LOCKED_PENDING_ACTIVATION", s["full_name"]))
                u_id = cur.lastrowid

            student_user_map[s["student_id"]] = u_id
            cur.execute("UPDATE students SET user_id = %s WHERE student_id = %s", (u_id, s["student_id"]))

            # Map STUDENT role (role_id = 1)
            cur.execute("""
                INSERT IGNORE INTO user_roles (user_id, role_id, is_active)
                VALUES (%s, 1, TRUE)
            """, (u_id,))

        print(f"  [✓] Provisioned {len(students)} student accounts in `users` (all inactive pending activation).")

        # 3. Backfill Staff into `users` (is_active = FALSE, verification_status = 'VERIFIED')
        cur.execute("SELECT staff_id, department_id, full_name, email FROM staff ORDER BY staff_id")
        staff_members = cur.fetchall()

        staff_user_map = {}
        for st in staff_members:
            cur.execute("SELECT user_id FROM users WHERE email = %s", (st["email"],))
            existing = cur.fetchone()
            if existing:
                u_id = existing["user_id"]
            else:
                cur.execute("""
                    INSERT INTO users (username, email, password_hash, full_name, is_active)
                    VALUES (%s, %s, %s, %s, FALSE)
                """, (st["email"], st["email"], "LOCKED_PENDING_ACTIVATION", st["full_name"]))
                u_id = cur.lastrowid

            staff_user_map[st["staff_id"]] = u_id
            cur.execute("""
                UPDATE staff 
                SET user_id = %s, verification_status = 'VERIFIED', is_active = FALSE 
                WHERE staff_id = %s
            """, (u_id, st["staff_id"]))

            # Map STAFF role (role_id = 3)
            cur.execute("""
                INSERT IGNORE INTO user_roles (user_id, role_id, is_active)
                VALUES (%s, 3, TRUE)
            """, (u_id,))

            # Map Level 1 workflow assignment (Frontline Staff)
            cur.execute("""
                INSERT IGNORE INTO staff_workflow_assignments 
                  (user_id, department_id, level_id, can_escalate, can_resolve)
                VALUES (%s, %s, 1, FALSE, TRUE)
            """, (u_id, st["department_id"]))

        print(f"  [✓] Provisioned {len(staff_members)} staff accounts in `users` (marked VERIFIED, login inactive).")
        print("  [i] Note: Account activation tokens are deferred to on-demand generation via `cli_activation.py` to prevent undelivered ghost tokens.")

        # 5. Synchronize `complaints.complainant_user_id` from student links
        cur.execute("""
            UPDATE complaints c
            JOIN students s ON c.student_id = s.student_id
            SET c.complainant_user_id = s.user_id
            WHERE c.complainant_user_id IS NULL
        """)
        print("  [✓] Synchronized `complaints.complainant_user_id` for all student complaints.")

        # 6. Backfill Legacy Active Assignments (assigned_by_user_id = NULL)
        cur.execute("""
            SELECT complaint_id, assigned_staff_id, department_id
            FROM complaints
            WHERE assigned_staff_id IS NOT NULL
        """)
        assigned_complaints = cur.fetchall()

        legacy_assign_count = 0
        for c in assigned_complaints:
            cur.execute("""
                SELECT assignment_id FROM complaint_assignments 
                WHERE complaint_id = %s AND is_active = TRUE
            """, (c["complaint_id"],))
            if not cur.fetchone():
                cur.execute("""
                    INSERT INTO complaint_assignments 
                      (complaint_id, assigned_staff_id, assigned_by_user_id, assignment_reason, is_active)
                    VALUES (%s, %s, NULL, 'Legacy assignment migrated from v1 baseline', TRUE)
                """, (c["complaint_id"], c["assigned_staff_id"]))
                legacy_assign_count += 1

        print(f"  [✓] Migrated {legacy_assign_count} legacy active assignments (assigned_by_user_id = NULL).")

        # 7. Post-DML Verification Checks (Before committing transaction)
        cur.execute("SELECT COUNT(*) AS cnt FROM complaints WHERE complainant_user_id IS NULL")
        null_complainants = cur.fetchone()["cnt"]
        if null_complainants > 0:
            raise RuntimeError(f"Integrity check failed: {null_complainants} complaints still have NULL complainant_user_id!")

        cur.execute("""
            SELECT COUNT(*) AS cnt 
            FROM complaints c
            JOIN students s ON c.student_id = s.student_id
            WHERE c.complainant_user_id <> s.user_id
        """)
        mismatched_complainants = cur.fetchone()["cnt"]
        if mismatched_complainants > 0:
            raise RuntimeError(f"Integrity check failed: {mismatched_complainants} complaints have mismatched user IDs!")

        cur.execute("""
            SELECT COUNT(*) AS cnt FROM complaint_assignments WHERE is_active = TRUE
        """)
        active_assignments = cur.fetchone()["cnt"]
        if active_assignments != len(assigned_complaints):
            raise RuntimeError(f"Assignment check failed: expected {len(assigned_complaints)} active assignments, got {active_assignments}!")

        connection.commit()
        print("  [✓] Transaction committed successfully. DML backfill complete.")

    except Exception:
        connection.rollback()
        print("  [X] Exception encountered. Transaction rolled back completely.")
        raise
    finally:
        cur.close()

if __name__ == "__main__":
    pwd = os.environ.get("DB_MIGRATOR_PASSWORD") or os.environ.get("MYSQL_ROOT_PWD")
    if not pwd:
        print("ERROR: DB_MIGRATOR_PASSWORD or MYSQL_ROOT_PWD required.")
        sys.exit(1)
    cnx = mysql.connector.connect(
        host="localhost",
        user="complaint_migrator_v2_dev",
        password=pwd,
        database="college_complaints_v2_dev"
    )
    run_backfill(cnx)
    cnx.close()
