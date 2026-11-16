"""
Migration: 006_data_backfill_and_sync.py
Purpose  : One transactional DML backfill:
             * one inactive `users` row per student and per staff member (no password),
             * STUDENT / STAFF role mappings,
             * Level 1 workflow membership for each legacy staff member,
             * complaints.complainant_user_id from the student link,
             * one LEGACY_IMPORT ledger row per currently assigned complaint.
Type     : STRICTLY DML. No DDL is executed (DDL would implicitly commit the transaction).

This module is executed by migrations/run_migrations.py, which passes its own connection
and a `before_commit` callback that writes the schema_migrations ledger row INSIDE the
same transaction. The backfill and its ledger entry therefore commit atomically.
Running this file directly is refused, because that would bypass the ledger, the
checkpoint and the pre/post assertions.

Claude Stage 2 corrections (see STAGE2_CLAUDE_REVIEW.md, section 006):
  * Precondition: `users` must be empty and no student/staff may already be linked.
    The previous "reuse an existing user with the same email" path could silently attach
    a student to an unrelated pre-existing account on a re-run.
  * No placeholder password: password_hash stays NULL until a verified activation token
    is redeemed (previously the fake hash 'LOCKED_PENDING_ACTIVATION' was stored).
  * Legacy assignments are written with assignment_source='LEGACY_IMPORT',
    assigned_by_user_id=NULL and assigned_at=NULL: neither the original actor nor the
    original time is known, so neither is invented.
  * Legacy staff: verification_status='VERIFIED' and staff.is_active=TRUE (they are the
    staff currently holding the 200 baseline assignments); users.is_active stays FALSE,
    so nobody can log in until activation. verified_by_user_id / verified_at stay NULL
    (no verifier is invented). See the review for this assumption.
  * Hard count assertions against the verified Stage 1 baseline before COMMIT.
  * ASCII-only output: the previous check-mark characters raise UnicodeEncodeError on a
    Windows cp1252 pipe, which would have rolled the whole backfill back.
  * Collision report prints counts only (no e-mail addresses in migration logs).
  * Removed the MYSQL_ROOT_PWD fallback: root credentials are never used by migrations.
"""

import sys

# Verified Stage 1 baseline (college_complaints_v2_dev). The runner also checks these
# before any migration runs. Mismatches abort; records are never deleted to "fit".
EXPECTED = {
    "students": 102,
    "staff": 15,
    "complaints": 202,
    "assigned_complaints": 200,
    "unassigned_complaints": 2,
}

LEGACY_ASSIGNMENT_REASON = "Legacy assignment imported from v1 baseline (original actor and time unknown)"


def _scalar(cur, sql, params=None):
    cur.execute(sql, params or ())
    row = cur.fetchone()
    return list(row.values())[0] if isinstance(row, dict) else row[0]


def _assert_equal(label, actual, expected):
    if actual != expected:
        raise RuntimeError(f"Assertion failed: {label}: expected {expected}, found {actual}")
    print(f"  [OK] {label}: {actual}")


def run_backfill(connection, before_commit=None):
    """Run the backfill in a single transaction on `connection`.

    `before_commit(cursor)` is called after all assertions pass and before COMMIT, so the
    caller can write its ledger row atomically with the data.
    """
    if connection.in_transaction:
        raise RuntimeError("006 must start on a connection with no open transaction.")
    connection.start_transaction(isolation_level="REPEATABLE READ")

    cur = connection.cursor(dictionary=True)
    try:
        print("[006] Starting transactional DML backfill")

        # ---- Preconditions -------------------------------------------------------------
        _assert_equal("users rows before backfill", _scalar(cur, "SELECT COUNT(*) FROM users"), 0)
        _assert_equal("students already linked", _scalar(cur, "SELECT COUNT(*) FROM students WHERE user_id IS NOT NULL"), 0)
        _assert_equal("staff already linked", _scalar(cur, "SELECT COUNT(*) FROM staff WHERE user_id IS NOT NULL"), 0)
        _assert_equal("complaint_assignments rows before backfill", _scalar(cur, "SELECT COUNT(*) FROM complaint_assignments"), 0)
        _assert_equal("students", _scalar(cur, "SELECT COUNT(*) FROM students"), EXPECTED["students"])
        _assert_equal("staff", _scalar(cur, "SELECT COUNT(*) FROM staff"), EXPECTED["staff"])
        _assert_equal("complaints", _scalar(cur, "SELECT COUNT(*) FROM complaints"), EXPECTED["complaints"])
        _assert_equal("complaints without student_id", _scalar(cur, "SELECT COUNT(*) FROM complaints WHERE student_id IS NULL"), 0)

        collisions = _scalar(cur, """
            SELECT COUNT(*) FROM students s
            JOIN staff st ON LOWER(TRIM(s.email)) = LOWER(TRIM(st.email))
        """)
        if collisions:
            raise RuntimeError(f"{collisions} e-mail address(es) exist in both students and staff; "
                               "resolve manually before migrating (identities are never merged automatically).")
        print("  [OK] student/staff e-mail collision check: 0")

        # ---- Role ids (resolved by name, not assumed) ---------------------------------
        cur.execute("SELECT role_id, role_name FROM roles WHERE role_name IN ('STUDENT', 'STAFF')")
        role_ids = {r["role_name"]: r["role_id"] for r in cur.fetchall()}
        if set(role_ids) != {"STUDENT", "STAFF"}:
            raise RuntimeError("Roles STUDENT/STAFF missing; migration 002 has not been applied.")

        # ---- Students -> users ----------------------------------------------------------
        cur.execute("SELECT student_id, full_name, email FROM students ORDER BY student_id")
        students = cur.fetchall()
        for s in students:
            cur.execute(
                "INSERT INTO users (username, email, password_hash, full_name, is_active) "
                "VALUES (%s, %s, NULL, %s, FALSE)",
                (s["email"], s["email"], s["full_name"]),
            )
            user_id = cur.lastrowid
            cur.execute("UPDATE students SET user_id = %s WHERE student_id = %s", (user_id, s["student_id"]))
            cur.execute("INSERT INTO user_roles (user_id, role_id, is_active) VALUES (%s, %s, TRUE)",
                        (user_id, role_ids["STUDENT"]))
        print(f"  [OK] provisioned {len(students)} student users (inactive, no password)")

        # ---- Staff -> users -------------------------------------------------------------
        cur.execute("SELECT staff_id, department_id, full_name, email FROM staff ORDER BY staff_id")
        staff_members = cur.fetchall()
        for st in staff_members:
            cur.execute(
                "INSERT INTO users (username, email, password_hash, full_name, is_active) "
                "VALUES (%s, %s, NULL, %s, FALSE)",
                (st["email"], st["email"], st["full_name"]),
            )
            user_id = cur.lastrowid
            cur.execute(
                "UPDATE staff SET user_id = %s, verification_status = 'VERIFIED', is_active = TRUE "
                "WHERE staff_id = %s",
                (user_id, st["staff_id"]),
            )
            cur.execute("INSERT INTO user_roles (user_id, role_id, is_active) VALUES (%s, %s, TRUE)",
                        (user_id, role_ids["STAFF"]))
            cur.execute(
                "INSERT INTO staff_workflow_assignments (user_id, department_id, level_id, can_escalate, can_resolve) "
                "VALUES (%s, %s, 1, FALSE, TRUE)",
                (user_id, st["department_id"]),
            )
        print(f"  [OK] provisioned {len(staff_members)} staff users (VERIFIED legacy staff, login inactive, Level 1 membership)")
        print("  [i] No activation tokens are created here; use cli_activation.py on demand.")

        # ---- complaints.complainant_user_id -------------------------------------------
        cur.execute("""
            UPDATE complaints c
            JOIN students s ON c.student_id = s.student_id
            SET c.complainant_user_id = s.user_id
            WHERE c.complainant_user_id IS NULL
        """)
        print(f"  [OK] complainant_user_id set on {cur.rowcount} complaints")

        # ---- Legacy assignments -> ledger (actor and time unknown => NULL) -------------
        cur.execute("""
            INSERT INTO complaint_assignments
                (complaint_id, assigned_staff_id, assigned_by_user_id, assignment_source,
                 assignment_reason, assigned_at, is_active)
            SELECT c.complaint_id, c.assigned_staff_id, NULL, 'LEGACY_IMPORT', %s, NULL, TRUE
            FROM complaints c
            WHERE c.assigned_staff_id IS NOT NULL
            ORDER BY c.complaint_id
        """, (LEGACY_ASSIGNMENT_REASON,))
        print(f"  [OK] imported {cur.rowcount} legacy active assignments (assigned_by_user_id = NULL)")

        # ---- Post-DML assertions (inside the transaction) ------------------------------
        n_users = EXPECTED["students"] + EXPECTED["staff"]
        _assert_equal("users", _scalar(cur, "SELECT COUNT(*) FROM users"), n_users)
        _assert_equal("active users", _scalar(cur, "SELECT COUNT(*) FROM users WHERE is_active = TRUE"), 0)
        _assert_equal("users with a password hash", _scalar(cur, "SELECT COUNT(*) FROM users WHERE password_hash IS NOT NULL"), 0)
        _assert_equal("user_roles", _scalar(cur, "SELECT COUNT(*) FROM user_roles"), n_users)
        _assert_equal("staff_workflow_assignments", _scalar(cur, "SELECT COUNT(*) FROM staff_workflow_assignments"), EXPECTED["staff"])
        _assert_equal("unlinked students", _scalar(cur, "SELECT COUNT(*) FROM students WHERE user_id IS NULL"), 0)
        _assert_equal("unlinked staff", _scalar(cur, "SELECT COUNT(*) FROM staff WHERE user_id IS NULL"), 0)
        _assert_equal("complaints with NULL complainant_user_id",
                      _scalar(cur, "SELECT COUNT(*) FROM complaints WHERE complainant_user_id IS NULL"), 0)
        _assert_equal("complainant/student mismatches", _scalar(cur, """
            SELECT COUNT(*) FROM complaints c JOIN students s ON c.student_id = s.student_id
            WHERE NOT (c.complainant_user_id <=> s.user_id)
        """), 0)
        _assert_equal("active ledger assignments", _scalar(cur, "SELECT COUNT(*) FROM complaint_assignments WHERE is_active = TRUE"),
                      EXPECTED["assigned_complaints"])
        _assert_equal("unassigned complaints",
                      _scalar(cur, "SELECT COUNT(*) FROM complaints WHERE assigned_staff_id IS NULL"),
                      EXPECTED["unassigned_complaints"])
        _assert_equal("cache/ledger mismatches", _scalar(cur, """
            SELECT COUNT(*) FROM complaints c
            LEFT JOIN complaint_assignments ca ON ca.active_complaint_id = c.complaint_id
            WHERE NOT (c.assigned_staff_id <=> ca.assigned_staff_id)
        """), 0)
        _assert_equal("ledger rows with an invented actor", _scalar(cur, """
            SELECT COUNT(*) FROM complaint_assignments
            WHERE assignment_source = 'LEGACY_IMPORT' AND (assigned_by_user_id IS NOT NULL OR assigned_at IS NOT NULL)
        """), 0)

        if before_commit is not None:
            before_commit(cur)

        connection.commit()
        print("  [OK] transaction committed")

    except Exception:
        connection.rollback()
        print("  [X] exception: transaction rolled back, no 006 changes persisted")
        raise
    finally:
        cur.close()


if __name__ == "__main__":
    print("Refusing to run 006 directly: execute it through migrations/run_migrations.py so the "
          "checkpoint, ledger and assertions apply.", file=sys.stderr)
    sys.exit(2)
