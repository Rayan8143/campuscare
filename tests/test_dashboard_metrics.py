"""READ-ONLY regression tests for dashboard statistics (no database writes).

* Student metric invariant: Total = Active + Resolved + Rejected, cards match the database,
  and every number is limited to the signed-in complainant.
* Department / officer open-metric labels state what they include.

Run:  python tests/test_dashboard_metrics.py
"""
import html
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import campuscare.security as sec  # noqa: E402
from campuscare import create_app  # noqa: E402
from campuscare.db import one, query  # noqa: E402
from test_readonly_integration import _load_ignoring_inactive, client_as  # noqa: E402

RESULTS = []
ACTIVE = ("Submitted", "In Progress", "Escalated", "Resolution Pending Verification")


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond)))
    print(f"{'PASS' if cond else 'FAIL'}  {name}{('  — ' + detail) if detail and not cond else ''}")


def cards(page):
    """{label: (value, hint)} for every stat card on the page."""
    out = {}
    for m in re.finditer(r'cc-stat-value">([^<]*)</div><div class="text-secondary small">([^<]*)</div>\s*'
                         r'(?:<div class="small text-muted">([^<]*)</div>)?', page):
        out[html.unescape(m.group(2))] = (html.unescape(m.group(1)), html.unescape(m.group(3) or ""))
    return out


def db_counts(uid):
    rows = query("SELECT status, COUNT(*) n FROM complaint_details WHERE complainant_user_id = %s GROUP BY status", (uid,))
    return {r["status"]: r["n"] for r in rows}


def main():
    real_loader = sec.load_identity
    app = create_app()
    app.testing = True
    with app.app_context():
        n_hist = one("SELECT COUNT(*) n FROM complaint_history")["n"]
        students = [r["user_id"] for r in query(
            "SELECT DISTINCT s.user_id FROM students s JOIN complaints c ON c.complainant_user_id = s.user_id "
            "WHERE c.is_deleted = FALSE ORDER BY s.user_id LIMIT 12")]
        staff = one("SELECT st.user_id, st.department_id FROM staff st JOIN staff_workflow_assignments w ON w.user_id = st.user_id LIMIT 1")
        expected4 = db_counts(4)

    # 1. Student ID 4 with the REAL identity loader (the account is active)
    page = client_as(app, 4).get("/").get_data(as_text=True)
    c = cards(page)
    shown = {k: c.get(k, ("?",))[0] for k in ("Total complaints", "Active complaints", "Resolved", "Rejected")}
    check("student 4: exactly the four exclusive cards", set(c) == set(shown), str(list(c)))
    check("student 4: Total 3 | Active 1 | Resolved 2 | Rejected 0",
          shown == {"Total complaints": "3", "Active complaints": "1", "Resolved": "2", "Rejected": "0"}, str(shown))
    check("student 4: cards match database", int(shown["Total complaints"]) == sum(expected4.values())
          and int(shown["Resolved"]) == expected4.get("Resolved", 0))
    check("student 4: active breakdown names the active status", c.get("Active complaints", ("", ""))[1] == "1 in progress",
          c.get("Active complaints", ("", ""))[1])
    check("student 4: old overlapping 'Open'/'In progress' cards removed", "Open" not in c and "In progress" not in c)

    # 2. Invariant + ownership for every student with complaints (in-memory loader skips is_active only)
    sec.load_identity = _load_ignoring_inactive
    for uid in students:
        c = cards(client_as(app, uid).get("/").get_data(as_text=True))
        with app.app_context():
            db = db_counts(uid)
        t, a, r, j = (int(c[k][0]) for k in ("Total complaints", "Active complaints", "Resolved", "Rejected"))
        check(f"student {uid}: Total = Active + Resolved + Rejected ({t} = {a} + {r} + {j})", t == a + r + j)
        check(f"student {uid}: numbers equal own DB rows only",
              t == sum(db.values()) and a == sum(db.get(s, 0) for s in ACTIVE) and r == db.get("Resolved", 0)
              and j == db.get("Rejected", 0), f"db={db}")
        hint = c["Active complaints"][1]
        parts = dict(reversed(p.split(" ", 1)) for p in hint.split(" · ")) if hint != "none active" else {}
        check(f"student {uid}: breakdown sums to Active", sum(int(v) for v in parts.values()) == a, hint)
    sec.load_identity = real_loader

    # 3. Ownership filters in code unchanged
    src = (Path(__file__).resolve().parent.parent / "campuscare" / "blueprints" / "main.py").read_text(encoding="utf-8")
    check("code: student counts filtered by session user", 'where, params = "complainant_user_id = %s", [ident.user_id]' in src)
    check("code: student activity filtered by session user", 'S.recent_activity("cd.complainant_user_id = %s", [ident.user_id], 8)' in src)
    check("code: student list uses own scope", 'S.list_complaints(ident, "own", limit=6)' in src)

    # 4. Department / officer labels (in-memory identities, read-only GETs)
    def synth(kind):
        def loader(uid):
            ident = _load_ignoring_inactive(uid)
            if kind == "officer":
                ident.is_officer = True
                ident.permissions |= {"complaint:view_all", "complaint:verify_resolution", "report:view_global"}
            else:
                ident.memberships = [{"department_id": staff["department_id"], "department_name": "Dept", "level_id": 2,
                                      "level_number": 2, "level_name": "Level 2", "can_escalate": 1, "can_resolve": 1}]
                ident.permissions |= {"complaint:view_department_queue"}
            return ident
        return loader
    sec.load_identity = synth("reviewer")
    c = cards(client_as(app, staff["user_id"]).get("/").get_data(as_text=True))
    with app.app_context():
        d = query("SELECT status, COUNT(*) n FROM complaint_details WHERE department_id = %s GROUP BY status", (staff["department_id"],))
    d = {r["status"]: r["n"] for r in d}
    check("department: label 'Open (including escalated)'", "Open (including escalated)" in c and "Open in queue" not in c, str(list(c)))
    check("department: value = Submitted + In Progress + Escalated",
          int(c["Open (including escalated)"][0]) == sum(d.get(s, 0) for s in ("Submitted", "In Progress", "Escalated")))
    sec.load_identity = synth("officer")
    c = cards(client_as(app, staff["user_id"]).get("/").get_data(as_text=True))
    with app.app_context():
        o = {r["status"]: r["n"] for r in query("SELECT status, COUNT(*) n FROM complaint_details GROUP BY status")}
    lbl = "Open (incl. escalated & pending verification)"
    check("officer: label names escalated and pending verification", lbl in c and "Open complaints" not in c, str(list(c)))
    check("officer: value = all four active statuses", int(c[lbl][0]) == sum(o.get(s, 0) for s in ACTIVE))
    sec.load_identity = real_loader

    with app.app_context():
        check("no writes: history unchanged", one("SELECT COUNT(*) n FROM complaint_history")["n"] == n_hist)

    failed = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    return failed


def test_dashboard_metrics():
    assert not main()


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
