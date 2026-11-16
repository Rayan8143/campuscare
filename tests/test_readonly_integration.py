"""READ-ONLY integration tests against college_complaints_v2_dev as complaint_app_v2_dev.

No row is written: every account in the sandbox is still inactive (no password), so the
real login path is exercised only for refusal, and role pages are rendered through a
test-only identity loader that reads real profiles but skips the is_active check.
Workflow POSTs are only sent where the Flask layer must refuse them *before* any
procedure call (403/404/400), which is asserted.

Run:  python -m pytest -q tests/test_readonly_integration.py   (or: python tests/test_readonly_integration.py)
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import campuscare.security as sec  # noqa: E402
from campuscare import create_app  # noqa: E402
from campuscare.db import call_procedure, get_db, one, query  # noqa: E402

RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond), detail))
    print(f"{'PASS' if cond else 'FAIL'}  {name}{('  — ' + detail) if detail and not cond else ''}")


_real_load = sec.load_identity


def _load_ignoring_inactive(uid):
    from campuscare.security import Identity
    user = one("SELECT user_id, username, email, full_name, is_active FROM users WHERE user_id = %s", (uid,))
    if not user:
        return None
    user = dict(user, is_active=True)
    orig_one = sec.one
    sec.one = lambda sql, p=(): user if sql.startswith("SELECT user_id, username") else orig_one(sql, p)
    try:
        return _real_load(uid)
    finally:
        sec.one = orig_one


def client_as(app, uid):
    c = app.test_client()
    with c.session_transaction() as s:
        s["uid"] = uid
        s["seen"] = 10 ** 10
        s["csrf"] = "test-token"
    return c


def main():
    app = create_app()
    app.testing = True
    sec.load_identity = _load_ignoring_inactive

    with app.app_context():
        cur = get_db().cursor()
        cur.execute("SELECT DATABASE(), CURRENT_USER()")
        dbname, acct = cur.fetchone(); cur.close()
        check("guard: connected database", dbname == "college_complaints_v2_dev", dbname)
        check("guard: connected account", acct == "complaint_app_v2_dev@localhost", acct)
        try:
            call_procedure("cc_auth_is_primary_officer", [1, 0]); ok = False
        except Exception as e:  # noqa: BLE001
            ok = "not permitted" in str(e)
        check("db: non-allow-listed procedure blocked in Python", ok)
        try:
            from campuscare.db import execute_notification_write
            execute_notification_write("UPDATE complaints SET status='Resolved' WHERE 1=0", ()); ok = False
        except Exception as e:  # noqa: BLE001
            ok = "limited to notifications" in str(e)
        check("db: direct complaint write blocked in Python", ok)
        student = one("SELECT s.user_id FROM students s JOIN complaints c ON c.complainant_user_id = s.user_id LIMIT 1")
        student2 = one("SELECT s.user_id FROM students s WHERE s.user_id <> %s LIMIT 1", (student["user_id"],))
        staff = one("SELECT st.user_id, st.staff_id, st.department_id FROM staff st JOIN staff_workflow_assignments w "
                    "ON w.user_id = st.user_id WHERE EXISTS (SELECT 1 FROM complaints c WHERE c.assigned_staff_id = st.staff_id) LIMIT 1")
        own_c = one("SELECT complaint_id FROM complaints WHERE complainant_user_id = %s AND is_deleted = FALSE LIMIT 1", (student["user_id"],))
        other_c = one("SELECT complaint_id FROM complaints WHERE complainant_user_id <> %s AND is_deleted = FALSE "
                      "AND (assigned_staff_id IS NULL OR assigned_staff_id <> %s) LIMIT 1", (student["user_id"], staff["staff_id"]))
        assigned_c = one("SELECT complaint_id, status FROM complaints WHERE assigned_staff_id = %s AND is_deleted = FALSE LIMIT 1", (staff["staff_id"],))
        n_hist = one("SELECT COUNT(*) n FROM complaint_history")["n"]
        n_notif = one("SELECT COUNT(*) n FROM notifications")["n"]
        n_status = query("SELECT status, COUNT(*) n FROM complaints GROUP BY status ORDER BY status")

    anon = app.test_client()
    r = anon.get("/")
    check("anon: dashboard redirects to login", r.status_code == 302 and "/login" in r.headers["Location"])
    r = anon.get("/login")
    check("anon: login page renders", r.status_code == 200 and b"Sign in" in r.data)
    check("headers: nosniff + frame deny", r.headers.get("X-Content-Type-Options") == "nosniff" and r.headers.get("X-Frame-Options") == "DENY")
    token = re.search(rb'name="csrf_token" value="([^"]+)"', r.data).group(1).decode()
    r = anon.post("/login", data={"username": "x", "password": "y"})
    check("csrf: POST without token rejected", r.status_code == 400)
    r = anon.post("/login", data={"csrf_token": token, "username": "nobody@example.invalid", "password": "wrong"})
    check("login: unknown user refused generically", r.status_code == 401 and b"Invalid credentials" in r.data)
    with app.app_context():
        uname = one("SELECT username FROM users WHERE user_id = %s", (student["user_id"],))["username"]
    r = anon.post("/login", data={"csrf_token": token, "username": uname, "password": "anything-at-all"})
    check("login: inactive/unactivated account refused", r.status_code == 401)
    r = anon.post("/activate", data={"csrf_token": token, "token": "bogus", "password": "abcdefghijkl", "password2": "abcdefghijkl"})
    check("activation: invalid token refused (generic message)", r.status_code == 400 and b"invalid, expired or already used" in r.data)
    check("no secrets in pages", b"password_hash" not in r.data and b"scrypt:" not in r.data)

    # Student
    s = client_as(app, student["user_id"])
    r = s.get("/")
    check("student: dashboard renders", r.status_code == 200 and b"New complaint" in r.data, str(r.status_code))
    r = s.get(f"/complaints/{own_c['complaint_id']}")
    check("student: own complaint visible", r.status_code == 200)
    r = s.get(f"/complaints/{other_c['complaint_id']}")
    check("student: other's complaint hidden (404)", r.status_code == 404)
    r = s.get("/complaints/?scope=all")
    check("student: scope=all falls back to own", r.status_code == 200 and b"All complaints" not in r.data)
    r = s.get("/reports/")
    check("student: reports forbidden", r.status_code == 403)
    r = s.post(f"/complaints/{own_c['complaint_id']}/action", data={"csrf_token": "test-token", "action": "verify", "decision": "approve"})
    check("student: cannot verify (403 before DB)", r.status_code == 403)
    r = s.post(f"/complaints/{other_c['complaint_id']}/action", data={"csrf_token": "test-token", "action": "edit_own"})
    check("student: cannot act on other's complaint (404)", r.status_code == 404)
    r = s.get("/activate")
    check("signed-in: /activate redirects to dashboard (no blank page)", r.status_code == 302 and r.headers["Location"].endswith("/"))
    r = s.post("/activate", data={"csrf_token": "test-token", "token": "x", "password": "a" * 12, "password2": "a" * 12})
    check("signed-in: activation POST refused without procedure call", r.status_code == 302)
    r = s.get("/complaints/new")
    check("student: submission form renders", r.status_code == 200 and b"Responsible department" in r.data)

    # Another student cannot see first student's complaint
    s2 = client_as(app, student2["user_id"])
    r = s2.get(f"/complaints/{own_c['complaint_id']}")
    check("ownership: second student gets 404", r.status_code == 404 or own_c is None)

    # Staff L1
    st = client_as(app, staff["user_id"])
    r = st.get("/")
    check("staff: L1 dashboard renders", r.status_code == 200 and b"investigation queue" in r.data, str(r.status_code))
    r = st.get(f"/complaints/{assigned_c['complaint_id']}")
    check("staff: assigned complaint visible", r.status_code == 200)
    check("staff: no assign/reject/verify controls", b'value="assign"' not in r.data and b'value="reject"' not in r.data and b'value="verify"' not in r.data)
    r = st.get(f"/complaints/{other_c['complaint_id']}")
    check("staff: unassigned complaint of others hidden", r.status_code == 404)
    r = st.get("/complaints/new")
    check("staff: cannot submit complaints", r.status_code == 403)
    r = st.post(f"/complaints/{assigned_c['complaint_id']}/action", data={"csrf_token": "test-token", "action": "escalate", "to_level_id": "4", "reason": "x"})
    check("staff: cannot escalate tier (403 before DB)", r.status_code == 403)
    r = st.post(f"/complaints/{assigned_c['complaint_id']}/action", data={"csrf_token": "test-token", "action": "archive", "reason": "x"})
    check("staff: cannot archive (403 before DB)", r.status_code == 403)
    r = st.get("/reports/")
    check("staff L1: reports forbidden", r.status_code == 403)
    for path in ("/complaints/", "/complaints/?scope=assigned&status=open", "/notifications/"):
        check(f"staff: GET {path}", st.get(path).status_code == 200)

    # Officer/reviewer/head identities cannot be rendered: none exist in the sandbox.
    with app.app_context():
        lv = query("SELECT level_id, COUNT(*) n FROM staff_workflow_assignments GROUP BY level_id")
        off = one("SELECT COUNT(*) n FROM primary_officer_assignment")["n"]
    check("data: L2/L3 memberships present (needed to render reviewer/head dashboards)",
          any(x["level_id"] >= 2 for x in lv), f"levels present: {[x['level_id'] for x in lv]}")
    check("data: Primary officer appointed (needed to render officer dashboard)", off > 0, "0 officer rows")

    # Template rendering for higher roles using an IN-MEMORY identity (not database data; the DB
    # procedures would refuse any action by these synthetic identities). Read-only GETs only.
    def synth(kind):
        def loader(uid):
            ident = _load_ignoring_inactive(uid)
            if ident is None:
                return None
            if kind == "officer":
                ident.is_officer = True
                ident.permissions |= {"complaint:view_all", "complaint:verify_resolution", "report:view_global",
                                      "complaint:reassign_global", "complaint:soft_delete"}
            else:
                lvl = 3 if kind == "head" else 2
                ident.memberships = [{"department_id": staff["department_id"], "department_name": "Dept",
                                      "level_id": lvl, "level_number": lvl, "level_name": f"Level {lvl}",
                                      "can_escalate": 1, "can_resolve": 1}]
                ident.permissions |= {"complaint:view_department_queue", "complaint:assign_staff", "complaint:reject",
                                      "complaint:escalate_tier"}
            return ident
        return loader
    for kind, marker in (("reviewer", b"Review desk"), ("head", b"Department head overview"), ("officer", b"Institution overview")):
        sec.load_identity = synth(kind)
        cl = client_as(app, staff["user_id"])
        r = cl.get("/")
        check(f"render (in-memory {kind}): dashboard", r.status_code == 200 and marker in r.data, str(r.status_code))
        check(f"render (in-memory {kind}): reports", cl.get("/reports/").status_code == 200)
        r = cl.get(f"/complaints/{other_c['complaint_id'] if kind == 'officer' else assigned_c['complaint_id']}")
        check(f"render (in-memory {kind}): complaint detail with action panel", r.status_code == 200 and b"Actions" in r.data)
    sec.load_identity = _load_ignoring_inactive

    # Nothing changed
    with app.app_context():
        check("no writes: history unchanged", one("SELECT COUNT(*) n FROM complaint_history")["n"] == n_hist)
        check("no writes: notifications unchanged", one("SELECT COUNT(*) n FROM notifications")["n"] == n_notif)
        check("no writes: status distribution unchanged",
              query("SELECT status, COUNT(*) n FROM complaints GROUP BY status ORDER BY status") == n_status)

    sec.load_identity = _real_load
    failed = [n for n, ok, _ in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    return failed


def test_readonly_integration():
    failed = main()
    data_gaps = {"data: L2/L3 memberships present (needed to render reviewer/head dashboards)",
                 "data: Primary officer appointed (needed to render officer dashboard)"}
    assert not [f for f in failed if f not in data_gaps], failed


if __name__ == "__main__":
    main()
