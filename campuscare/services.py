"""Read models, object-level authorization and workflow actions.

Reads use the INVOKER views (complaint_details / open_complaints / department_complaint_summary)
and the granted tables. Every write is a stored-procedure call; Python checks here decide what the
UI offers and refuse obviously forbidden requests early, while the procedures remain authoritative.
"""
from flask import g

from .db import call_procedure, execute_notification_write, one, query, scalar

CATEGORIES = ["Infrastructure", "Hostel", "Laboratory", "Network", "Cleanliness", "Other"]
PRIORITIES = ["Low", "Medium", "High"]
STATUSES = ["Submitted", "In Progress", "Escalated", "Resolution Pending Verification", "Resolved", "Rejected"]
OPEN_STATUSES = ("Submitted", "In Progress", "Escalated", "Resolution Pending Verification")
FINAL_STATUSES = ("Resolved", "Rejected")

LIST_COLUMNS = ("complaint_id, title, category, priority, status, current_level_id, current_level_name, created_at, "
                "resolved_at, complainant_user_id, complainant_type, complainant_name, department_id, "
                "responsible_department, assigned_staff_id, assigned_staff_name")


# --- scoping -------------------------------------------------------------------------------
def scope_clause(ident, scope):
    """SQL predicate + params limiting complaint_details rows to what the identity may see."""
    if scope == "all" and (ident.can("complaint:view_all") or ident.is_officer):
        return "1=1", []
    if scope == "queue":
        depts = ident.queue_departments()
        if not depts or not ident.can("complaint:view_department_queue"):
            return "1=0", []
        return f"department_id IN ({','.join(['%s'] * len(depts))})", depts
    if scope == "assigned":
        if not ident.staff_id or not ident.can("complaint:view_assigned"):
            return "1=0", []
        return "assigned_staff_id = %s", [ident.staff_id]
    if scope == "own":
        if not (ident.can("complaint:view_own")):
            return "1=0", []
        return "complainant_user_id = %s", [ident.user_id]
    return "1=0", []


def default_scope(ident):
    if ident.is_officer or ident.can("complaint:view_all"):
        return "all"
    if ident.queue_departments():
        return "queue"
    if ident.staff_id:
        return "assigned"
    return "own"


def available_scopes(ident):
    out = []
    if ident.can("complaint:view_own") and (ident.student or ident.external):
        out.append(("own", "My complaints"))
    if ident.staff_id and ident.can("complaint:view_assigned"):
        out.append(("assigned", "Assigned to me"))
    if ident.queue_departments() and ident.can("complaint:view_department_queue"):
        out.append(("queue", "Department queue"))
    if ident.is_officer or ident.can("complaint:view_all"):
        out.append(("all", "All complaints"))
    return out


def list_complaints(ident, scope, status=None, priority=None, department=None, search=None, limit=200):
    where, params = scope_clause(ident, scope)
    clauses = [where]
    if status in STATUSES:
        clauses.append("status = %s"); params.append(status)
    elif status == "open":
        clauses.append("status IN ('Submitted','In Progress','Escalated','Resolution Pending Verification')")
    if priority in PRIORITIES:
        clauses.append("priority = %s"); params.append(priority)
    if department and str(department).isdigit():
        clauses.append("department_id = %s"); params.append(int(department))
    if search:
        clauses.append("(title LIKE %s OR CAST(complaint_id AS CHAR) = %s)")
        params += [f"%{search[:80]}%", search[:12]]
    sql = (f"SELECT {LIST_COLUMNS} FROM complaint_details WHERE {' AND '.join(clauses)} "
           f"ORDER BY FIELD(priority,'High','Medium','Low'), created_at DESC LIMIT %s")
    return query(sql, params + [int(limit)])


def can_view(ident, c):
    if c is None:
        return False
    if ident.is_officer or ident.can("complaint:view_all"):
        return True
    if c["complainant_user_id"] == ident.user_id and ident.can("complaint:view_own"):
        return True
    if ident.staff_id and c["assigned_staff_id"] == ident.staff_id and ident.can("complaint:view_assigned"):
        return True
    if c["department_id"] in ident.queue_departments() and ident.can("complaint:view_department_queue"):
        return True
    return False


def get_complaint(complaint_id):
    return one("SELECT * FROM complaint_details WHERE complaint_id = %s", (complaint_id,))


def level_number(level_id):
    return scalar("SELECT level_number FROM workflow_levels WHERE level_id = %s", (level_id,))


def timeline(complaint_id):
    return query("SELECT h.history_id, h.old_status, h.new_status, h.changed_at, h.action_type, h.remarks, "
                 "u.full_name AS actor_name FROM complaint_history h "
                 "LEFT JOIN users u ON u.user_id = h.changed_by_user_id "
                 "WHERE h.complaint_id = %s ORDER BY h.changed_at, h.history_id", (complaint_id,))


def assignments(complaint_id):
    return query("SELECT a.assignment_id, a.assigned_at, a.unassigned_at, a.is_active, a.assignment_source, "
                 "a.assignment_reason, s.full_name AS staff_name, s.designation, u.full_name AS assigned_by "
                 "FROM complaint_assignments a JOIN staff s ON s.staff_id = a.assigned_staff_id "
                 "LEFT JOIN users u ON u.user_id = a.assigned_by_user_id "
                 "WHERE a.complaint_id = %s ORDER BY a.assigned_at DESC, a.assignment_id DESC", (complaint_id,))


def escalations(complaint_id):
    return query("SELECT e.escalated_at, e.escalation_reason, fl.level_name AS from_level, tl.level_name AS to_level, "
                 "u.full_name AS actor_name FROM complaint_escalations e "
                 "JOIN workflow_levels fl ON fl.level_id = e.from_level_id "
                 "JOIN workflow_levels tl ON tl.level_id = e.to_level_id "
                 "LEFT JOIN users u ON u.user_id = e.escalated_by_user_id "
                 "WHERE e.complaint_id = %s ORDER BY e.escalated_at", (complaint_id,))


def verifications(complaint_id):
    return query("SELECT v.verification_id, v.submitted_at, v.resolution_notes, v.decision, v.officer_remarks, "
                 "v.reviewed_at, s.full_name AS submitted_by, s.user_id AS submitter_user_id, "
                 "u.full_name AS officer_name FROM resolution_verifications v "
                 "JOIN staff s ON s.staff_id = v.submitted_by_staff_id "
                 "LEFT JOIN users u ON u.user_id = v.officer_user_id "
                 "WHERE v.complaint_id = %s ORDER BY v.submitted_at DESC", (complaint_id,))


def eligible_assignees(c):
    """Staff who could receive the complaint at its current level (procedure re-validates)."""
    lvl = level_number(c["current_level_id"])
    if lvl >= 4:
        return query("SELECT s.staff_id, s.full_name, s.designation, d.department_name FROM primary_officer_assignment p "
                     "JOIN staff s ON s.user_id = p.user_id JOIN departments d ON d.department_id = s.department_id")
    return query("SELECT s.staff_id, s.full_name, s.designation, d.department_name, swa.can_resolve, swa.can_escalate "
                 "FROM staff_workflow_assignments swa JOIN staff s ON s.user_id = swa.user_id "
                 "JOIN users u ON u.user_id = s.user_id JOIN departments d ON d.department_id = s.department_id "
                 "WHERE swa.department_id = %s AND swa.level_id = %s AND s.department_id = swa.department_id "
                 "AND s.is_active = TRUE AND s.verification_status = 'VERIFIED' AND u.is_active = TRUE "
                 "AND EXISTS (SELECT 1 FROM user_roles ur JOIN roles r ON r.role_id = ur.role_id "
                 "            WHERE ur.user_id = s.user_id AND ur.is_active = TRUE AND r.role_name = 'STAFF') "
                 "ORDER BY s.full_name", (c["department_id"], c["current_level_id"]))


def available_actions(ident, c):
    """Which workflow actions to offer. Mirrors the procedure rules; the database has the final say."""
    acts = set()
    if c["is_deleted"]:
        return acts
    status = c["status"]
    lvl = level_number(c["current_level_id"])
    dept = c["department_id"]
    is_owner = c["complainant_user_id"] == ident.user_id
    is_assignee = bool(ident.staff_id) and c["assigned_staff_id"] == ident.staff_id
    membership = ident.membership_for(dept, c["current_level_id"])
    dept_authority = any(m["department_id"] == dept and m["level_number"] >= max(2, lvl) for m in ident.memberships)
    officer = ident.is_officer

    if status in FINAL_STATUSES:
        return acts
    if is_owner and status == "Submitted" and ident.can("complaint:edit_own"):
        acts.add("edit_own")
    if (officer or dept_authority) and ident.can("complaint:edit_details"):
        acts.add("edit_details")
    if is_assignee and status in ("Submitted", "Escalated") and ident.can("complaint:update_investigation") \
            and (membership or (officer and lvl >= 4)):
        acts.add("accept")
    if is_assignee and status == "In Progress" and membership and membership["can_resolve"] \
            and ident.can("complaint:submit_resolution") and lvl < 4:
        acts.add("submit_resolution")
    if is_assignee and status in ("In Progress", "Submitted") and membership and membership["can_escalate"] \
            and ident.can("complaint:request_escalation") and lvl < 4:
        acts.add("request_escalation")
    if status in ("Submitted", "In Progress", "Escalated") and ident.can("complaint:escalate_tier") \
            and lvl < 4 and (officer or dept_authority):
        acts.add("escalate")
    if status in ("Submitted", "In Progress", "Escalated") and ident.can("complaint:reject") and (officer or dept_authority):
        acts.add("reject")
    if status in ("Submitted", "In Progress", "Escalated"):
        if officer and ident.can("complaint:reassign_global"):
            acts.add("assign")
        elif dept_authority and (ident.can("complaint:assign_staff") or ident.can("complaint:reassign_staff")):
            acts.add("assign")
    if status == "Resolution Pending Verification" and officer and ident.can("complaint:verify_resolution"):
        acts.add("verify")
    if status == "In Progress" and lvl >= 4 and officer and is_assignee and ident.can("complaint:verify_resolution"):
        acts.add("final_decision")
    if officer and ident.can("complaint:soft_delete"):
        acts.add("archive")
    return acts


# --- writes (procedures only) ----------------------------------------------------------------
def submit(ident, ctype, department_id, title, description, category, priority):
    out = call_procedure("submit_complaint", [ident.user_id, ctype, department_id, title, description,
                                              category, priority, 0])
    return out[-1]


def transition(ident, cid, new_status, remarks):
    call_procedure("transition_complaint_status", [cid, new_status, ident.user_id, remarks or None])


def escalate(ident, cid, to_level_id, reason):
    call_procedure("escalate_complaint", [cid, to_level_id, ident.user_id, reason])


def request_escalation(ident, cid, reason):
    call_procedure("request_escalation", [cid, ident.user_id, reason])


def reassign(ident, cid, staff_id, reason):
    call_procedure("reassign_complaint", [cid, staff_id, ident.user_id, reason])


def update_details(ident, cid, title, description, category, priority, reason):
    call_procedure("update_complaint_details", [cid, ident.user_id, title or None, description or None,
                                                category or None, priority or None, reason or None])


def archive(ident, cid, reason):
    call_procedure("soft_delete_complaint", [cid, ident.user_id, reason])


# --- notifications -------------------------------------------------------------------------
def notify(user_id, complaint_id, title, message):
    if not user_id or user_id == getattr(g.get("identity"), "user_id", None):
        return
    try:
        execute_notification_write(
            "INSERT INTO notifications (user_id, complaint_id, title, message) VALUES (%s, %s, %s, %s)",
            (user_id, complaint_id, title[:150], message[:2000]))
    except Exception:  # noqa: BLE001  notification failure must not undo a committed workflow action
        pass


def staff_user_id(staff_id):
    return scalar("SELECT user_id FROM staff WHERE staff_id = %s", (staff_id,)) if staff_id else None


def officer_user_id():
    return scalar("SELECT user_id FROM primary_officer_assignment LIMIT 1")


def department_authorities(department_id, min_level):
    return [r["user_id"] for r in query(
        "SELECT DISTINCT swa.user_id FROM staff_workflow_assignments swa JOIN workflow_levels wl "
        "ON wl.level_id = swa.level_id WHERE swa.department_id = %s AND wl.level_number >= %s",
        (department_id, min_level))]


def unread_count(user_id):
    return scalar("SELECT COUNT(*) AS n FROM notifications WHERE user_id = %s AND is_read = FALSE", (user_id,)) or 0


# --- statistics ----------------------------------------------------------------------------
def status_counts(where="1=1", params=()):
    rows = query(f"SELECT status, COUNT(*) AS n FROM complaint_details WHERE {where} GROUP BY status", params)
    counts = {s: 0 for s in STATUSES}
    counts.update({r["status"]: r["n"] for r in rows})
    return counts


def counts_by(column, where="1=1", params=()):
    assert column in ("priority", "category", "responsible_department", "current_level_name")
    return query(f"SELECT {column} AS label, COUNT(*) AS n FROM complaint_details WHERE {where} "
                 f"GROUP BY {column} ORDER BY n DESC", params)


def monthly_trend(where="1=1", params=(), months=6):
    return query(f"SELECT DATE_FORMAT(created_at, '%Y-%m') AS ym, COUNT(*) AS n, "
                 f"SUM(status = 'Resolved') AS resolved FROM complaint_details WHERE {where} "
                 f"AND created_at >= DATE_SUB(CURDATE(), INTERVAL {int(months)} MONTH) GROUP BY ym ORDER BY ym",
                 params)


def recent_activity(where="1=1", params=(), limit=12):
    return query(f"SELECT h.complaint_id, h.action_type, h.new_status, h.changed_at, h.remarks, u.full_name AS actor_name, "
                 f"cd.title FROM complaint_history h JOIN complaint_details cd ON cd.complaint_id = h.complaint_id "
                 f"LEFT JOIN users u ON u.user_id = h.changed_by_user_id WHERE {where} "
                 f"ORDER BY h.changed_at DESC, h.history_id DESC LIMIT %s", list(params) + [int(limit)])


def workload(department_ids=None):
    sql = ("SELECT s.staff_id, s.full_name, s.designation, d.department_name, "
           "SUM(c.status IN ('Submitted','In Progress','Escalated','Resolution Pending Verification')) AS open_n, "
           "SUM(c.status = 'Resolved') AS resolved_n FROM staff s JOIN departments d ON d.department_id = s.department_id "
           "LEFT JOIN complaint_details c ON c.assigned_staff_id = s.staff_id WHERE s.is_active = TRUE ")
    params = []
    if department_ids is not None:
        if not department_ids:
            return []
        sql += f"AND s.department_id IN ({','.join(['%s'] * len(department_ids))}) "
        params = list(department_ids)
    return query(sql + "GROUP BY s.staff_id, s.full_name, s.designation, d.department_name ORDER BY open_n DESC", params)


def avg_resolution_days(where="1=1", params=()):
    v = scalar(f"SELECT ROUND(AVG(TIMESTAMPDIFF(HOUR, created_at, resolved_at))/24, 1) AS d FROM complaint_details "
               f"WHERE {where} AND status = 'Resolved' AND resolved_at IS NOT NULL", params)
    return float(v) if v is not None else None
