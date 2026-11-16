"""READ-ONLY verification for the #59 resolution-verification demo.
Baseline (before any action): history 164, notifications 10, resolution_verifications 0;
#59 In Progress, level 1, dept 4, staff 4 (user 106), complainant 19, assignment 59 active.
Usage: python stage3_logs/verify_59.py submitted|approved"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campuscare import create_app  # noqa: E402
from campuscare.db import one, query  # noqa: E402

phase = sys.argv[1]
res = []


def check(name, cond, detail=""):
    res.append(bool(cond))
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  — {detail}" if detail and not cond else ""))


with create_app().app_context():
    c = one("SELECT status, current_level_id, department_id, assigned_staff_id, resolved_at, is_deleted FROM complaints WHERE complaint_id = 59")
    want = "Resolution Pending Verification" if phase == "submitted" else "Resolved"
    check(f"#59 status = {want}", c["status"] == want, c["status"])
    check("#59 level 1, dept 4, staff 4, not archived",
          (c["current_level_id"], c["department_id"], c["assigned_staff_id"], c["is_deleted"]) == (1, 4, 4, 0), str(c))
    check("resolved_at set only when approved", (c["resolved_at"] is not None) == (phase == "approved"))
    a = query("SELECT assignment_id, assigned_staff_id FROM complaint_assignments WHERE complaint_id = 59 AND is_active")
    check("assignment 59 (staff 4) still the only active assignment", a == [{"assignment_id": 59, "assigned_staff_id": 4}], str(a))

    h = query("SELECT action_type, old_status, new_status, changed_by_user_id FROM complaint_history WHERE complaint_id = 59 ORDER BY history_id")
    new = h[1:]
    exp = [("RESOLUTION_SUBMITTED", "In Progress", "Resolution Pending Verification", 106)]
    if phase == "approved":
        exp.append(("RESOLUTION_APPROVED", "Resolution Pending Verification", "Resolved", 108))
    got = [(r["action_type"], r["old_status"], r["new_status"], r["changed_by_user_id"]) for r in new]
    check(f"{len(exp)} new #59 history row(s) with expected action/actor", got == exp, str(got))
    check("total history", one("SELECT COUNT(*) n FROM complaint_history")["n"] == 164 + len(exp))

    v = query("SELECT submitted_by_staff_id, decision, officer_user_id, reviewed_at, resolution_notes FROM resolution_verifications WHERE complaint_id = 59")
    check("exactly one verification record (all tables)", len(v) == 1 and one("SELECT COUNT(*) n FROM resolution_verifications")["n"] == 1, str(v))
    if v:
        r = v[0]
        if phase == "submitted":
            check("verification PENDING, submitted by staff 4, notes present",
                  r["decision"] == "PENDING" and r["submitted_by_staff_id"] == 4 and r["officer_user_id"] is None and r["resolution_notes"])
        else:
            check("verification APPROVED by officer 108, reviewed_at set, submitter staff 4",
                  r["decision"] == "APPROVED" and r["officer_user_id"] == 108 and r["reviewed_at"] and r["submitted_by_staff_id"] == 4, str(r))

    n = query("SELECT user_id, title FROM notifications WHERE complaint_id = 59 ORDER BY notification_id")
    exp_n = [108] + ([19] if phase == "approved" else [])
    check(f"notifications for #59 to {exp_n}", [x["user_id"] for x in n] == exp_n, str(n))
    check("total notifications", one("SELECT COUNT(*) n FROM notifications")["n"] == 10 + len(exp_n))

    c14 = one("SELECT status, resolved_at FROM complaints WHERE complaint_id = 14")
    check("#14 still Resolved", c14["status"] == "Resolved" and c14["resolved_at"] is not None)
print(f"\n{sum(res)}/{len(res)} passed")
