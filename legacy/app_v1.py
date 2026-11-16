import os

from flask import Flask, flash, redirect, render_template, request, url_for
import mysql.connector

app = Flask(__name__)
app.secret_key = os.getenv("FLASK_SECRET_KEY", "local-demo-key")


def connect_db():
    return mysql.connector.connect(
        host=os.getenv("DB_HOST", "localhost"),
        user=os.getenv("DB_USER", "complaint_app"),
        password=os.getenv("DB_PASSWORD", ""),
        database=os.getenv("DB_NAME", "college_complaints"),
    )


@app.route("/")
def index():
    db = connect_db()
    cur = db.cursor(dictionary=True)
    try:
        cur.execute("""
            SELECT c.complaint_id, c.title, c.description, c.category,
                   c.priority, c.status, c.created_at,
                   s.full_name AS student_name,
                   d.department_name
            FROM complaints c
            JOIN students s ON c.student_id = s.student_id
            JOIN departments d ON c.department_id = d.department_id
            ORDER BY c.created_at DESC
        """)
        complaints = cur.fetchall()

        cur.execute("SELECT COUNT(*) AS n FROM complaints")
        total = cur.fetchone()["n"]

        cur.execute("""
            SELECT COUNT(*) AS n
            FROM complaints
            WHERE status IN ('Submitted', 'In Progress')
        """)
        opened = cur.fetchone()["n"]

        cur.execute("SELECT COUNT(*) AS n FROM complaints WHERE status = 'Resolved'")
        resolved = cur.fetchone()["n"]

        # Departments responsible for handling complaints.
        cur.execute("""
            SELECT department_id, department_name
            FROM departments
            ORDER BY department_name
        """)
        departments = cur.fetchall()

        # Academic departments that students can select for their profile.
        cur.execute("""
            SELECT academic_department_id, department_name
            FROM academic_departments
            ORDER BY department_name
        """)
        academic_departments = cur.fetchall()

        return render_template(
            "index.html",
            complaints=complaints,
            total=total,
            opened=opened,
            resolved=resolved,
            departments=departments,
            academic_departments=academic_departments,
        )
    finally:
        cur.close()
        db.close()


@app.route("/complaints", methods=["POST"])
def submit():
    form = request.form

    student_name = form.get("student_name", "").strip()
    student_email = (form.get("email") or form.get("student_email", "")).strip()
    academic_department_id = form.get("academic_department_id", "").strip()
    department_id = form.get("department_id", "").strip()
    title = form.get("title", "").strip()
    description = form.get("description", "").strip()
    category = form.get("category", "").strip()
    priority = form.get("priority", "Medium").strip()

    if not all([
        student_name,
        student_email,
        academic_department_id,
        department_id,
        title,
        description,
        category,
    ]):
        return "Please fill in all required fields.", 400

    try:
        academic_department_id = int(academic_department_id)
        department_id = int(department_id)
    except ValueError:
        return "Invalid department selection.", 400

    if priority not in {"Low", "Medium", "High"}:
        return "Invalid priority.", 400

    if category not in {
        "Infrastructure", "Hostel", "Laboratory", "Network", "Cleanliness", "Other"
    }:
        return "Invalid complaint category.", 400

    db = connect_db()
    cur = db.cursor()
    try:
        # Insert a new student, or update the existing student identified by email.
        # The academic department is now stored through its foreign key.
        cur.execute("""
            INSERT INTO students (full_name, email, academic_department_id)
            VALUES (%s, %s, %s)
            ON DUPLICATE KEY UPDATE
                full_name = VALUES(full_name),
                academic_department_id = VALUES(academic_department_id)
        """, (student_name, student_email, academic_department_id))

        cur.execute(
            "SELECT student_id FROM students WHERE email = %s",
            (student_email,),
        )
        student_row = cur.fetchone()
        if student_row is None:
            raise RuntimeError("Student record could not be retrieved after saving.")
        student_id = student_row[0]

        cur.execute("""
            INSERT INTO complaints
                (student_id, department_id, title, description, category, priority)
            VALUES (%s, %s, %s, %s, %s, %s)
        """, (
            student_id,
            department_id,
            title,
            description,
            category,
            priority,
        ))

        db.commit()
        flash("Complaint submitted successfully.")
    except Exception:
        db.rollback()
        raise
    finally:
        cur.close()
        db.close()

    return redirect(url_for("index"))


@app.route("/complaints/<int:cid>/status", methods=["POST"])
def update(cid):
    status = request.form.get("status", "")
    if status not in {"Submitted", "In Progress", "Resolved", "Rejected"}:
        return "Invalid status", 400

    db = connect_db()
    cur = db.cursor()
    try:
        cur.execute("""
            UPDATE complaints
            SET status = %s,
                resolved_at = CASE WHEN %s = 'Resolved' THEN NOW() ELSE NULL END
            WHERE complaint_id = %s
        """, (status, status, cid))
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        cur.close()
        db.close()

    return redirect(url_for("index"))


if __name__ == "__main__":
    app.run(debug=True)
