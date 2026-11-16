"""READ-ONLY post-action verification for the first acceptance test (complaint #14, actor user 106).
Runs as complaint_app_v2_dev through the app's guarded connection. Writes nothing.

Baseline (captured 2026-11-16, before the action):
  complaints by status: Submitted 53, In Progress 60, Resolved 72, Rejected 17 (total 202)
  complaint_history: 155 rows (max history_id 156); #14 has no history rows
  notifications: 0 rows
  #14: Submitted, High, Laboratory dept 4, level 1, assigned staff 4 (user 106), complainant user 54
  #14 assignment: assignment_id 14, staff 4, active, LEGACY_IMPORT

Run:  python stage3_logs/verify_accept_14.py
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campuscare import create_app  # noqa: E402
from campuscare.db import one, query  # noqa: E402

RESULTS = []


def check(name, cond, detail=""):
    RESULTS.append(bool(cond))
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  — {detail}" if not cond and detail else ""))


app = create_app(verify_db=True)
with app.app_context():
    c = one("SELECT status, priority, department_id, current_level_id, assigned_staff_id, resolved_at, is_deleted "
            "FROM complaints WHERE complaint_id = 14")
    check("#14 status is In Progress", c["status"] == "In Progress", str(c))
    check("#14 level, department, assignee, priority unchanged",
          (c["current_level_id"], c["department_id"], c["assigned_staff_id"], c["priority"]) == (1, 4, 4, "High"), str(c))
    check("#14 not resolved, not archived", c["resolved_at"] is None and not c["is_deleted"])

    h = query("SELECT history_id, old_status, new_status, action_type, changed_by_user_id, remarks "
              "FROM complaint_history WHERE complaint_id = 14 ORDER BY history_id")
    check("#14 has exactly one new history row", len(h) == 1, str(h))
    if h:
        r = h[0]
        check("history: Submitted -> In Progress", (r["old_status"], r["new_status"]) == ("Submitted", "In Progress"), str(r))
        check("history: action ASSIGNMENT_ACCEPTED", r["action_type"] == "ASSIGNMENT_ACCEPTED", r["action_type"])
        check("history: attributed to user 106", r["changed_by_user_id"] == 106, str(r["changed_by_user_id"]))
        print(f"      remarks: {r['remarks']!r}")

    a = query("SELECT assignment_id, assigned_staff_id, is_active FROM complaint_assignments WHERE complaint_id = 14")
    check("assignment ledger unchanged (id 14, staff 4, active)",
          a == [{"assignment_id": 14, "assigned_staff_id": 4, "is_active": 1}], str(a))

    n = query("SELECT user_id, complaint_id, title, is_read FROM notifications")
    check("exactly one notification, to complainant 54 about #14",
          len(n) == 1 and n[0]["user_id"] == 54 and n[0]["complaint_id"] == 14 and not n[0]["is_read"], str(n))

    check("total history rows = 156", one("SELECT COUNT(*) n FROM complaint_history")["n"] == 156)
    st = {r["status"]: r["n"] for r in query("SELECT status, COUNT(*) n FROM complaints GROUP BY status")}
    check("status totals: Submitted 52, In Progress 61, Resolved 72, Rejected 17",
          st == {"Submitted": 52, "In Progress": 61, "Resolved": 72, "Rejected": 17}, str(st))
    check("no escalations / verifications created",
          one("SELECT COUNT(*) n FROM complaint_escalations")["n"] == 0
          and one("SELECT COUNT(*) n FROM resolution_verifications")["n"] == 0)

print(f"\n{sum(RESULTS)}/{len(RESULTS)} passed")
