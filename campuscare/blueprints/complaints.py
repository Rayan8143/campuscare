"""Complaint list, detail, submission and workflow actions (all writes via stored procedures)."""
from flask import Blueprint, abort, flash, g, redirect, render_template, request, url_for

from .. import services as S
from ..db import DataAccessError, WorkflowError, query
from ..security import login_required

bp = Blueprint("complaints", __name__, url_prefix="/complaints")


def _text(name, maxlen, required=True):
    v = (request.form.get(name) or "").strip()
    if required and not v:
        raise WorkflowError(f"{name.replace('_', ' ').capitalize()} is required.")
    if len(v) > maxlen:
        raise WorkflowError(f"{name.replace('_', ' ').capitalize()} must be at most {maxlen} characters.")
    return v


def _load_visible(cid):
    c = S.get_complaint(cid)
    if not S.can_view(g.identity, c):
        abort(404)       # do not reveal whether an inaccessible complaint exists
    return c


@bp.route("/")
@login_required
def index():
    ident = g.identity
    scopes = S.available_scopes(ident)
    scope = request.args.get("scope") or S.default_scope(ident)
    if scope not in {s for s, _ in scopes}:
        scope = scopes[0][0] if scopes else "own"
    rows = S.list_complaints(ident, scope, status=request.args.get("status"), priority=request.args.get("priority"),
                             department=request.args.get("department"), search=(request.args.get("q") or "").strip())
    departments = query("SELECT department_id, department_name FROM departments ORDER BY department_name")
    return render_template("complaints/list.html", rows=rows, scopes=scopes, scope=scope, departments=departments,
                           statuses=S.STATUSES, priorities=S.PRIORITIES, args=request.args)


@bp.route("/new", methods=["GET", "POST"])
@login_required
def new():
    ident = g.identity
    if ident.student and ident.can("complaint:submit_student"):
        ctype = "STUDENT"
    elif ident.external and ident.can("complaint:submit_external"):
        ctype = "EXTERNAL"
    else:
        abort(403)
    departments = query("SELECT department_id, department_name, description FROM departments ORDER BY department_name")
    if request.method == "POST":
        try:
            title = _text("title", 180)
            description = _text("description", 5000)
            category = request.form.get("category")
            priority = request.form.get("priority")
            dept = request.form.get("department_id", "")
            if category not in S.CATEGORIES or priority not in S.PRIORITIES or not dept.isdigit():
                raise WorkflowError("Please choose a valid department, category and priority.")
            cid = S.submit(ident, ctype, int(dept), title, description, category, priority)
            for uid in S.department_authorities(int(dept), 2):
                S.notify(uid, cid, "New complaint in your department", f"#{cid}: {title}")
            flash(f"Complaint #{cid} submitted. You can track its progress here.", "success")
            return redirect(url_for("complaints.detail", cid=cid))
        except WorkflowError as e:
            flash(str(e), "danger")
        except DataAccessError as e:
            flash(str(e), "danger")
    return render_template("complaints/new.html", departments=departments, categories=S.CATEGORIES,
                           priorities=S.PRIORITIES, form=request.form)


@bp.route("/<int:cid>")
@login_required
def detail(cid):
    ident = g.identity
    c = _load_visible(cid)
    acts = S.available_actions(ident, c)
    lvl = S.level_number(c["current_level_id"])
    internal = bool(ident.staff_id) or ident.is_officer
    levels = query("SELECT level_id, level_number, level_name FROM workflow_levels WHERE level_number > %s "
                   "ORDER BY level_number", (lvl,))
    if not ident.is_officer:
        levels = levels[:1]       # department authorities may only escalate one level up
    return render_template("complaints/detail.html", c=c, acts=acts, level=lvl, levels=levels,
                           timeline=S.timeline(cid), assignments=S.assignments(cid) if internal else [],
                           escalations=S.escalations(cid), verifications=S.verifications(cid) if internal else [],
                           assignees=S.eligible_assignees(c) if "assign" in acts else [],
                           categories=S.CATEGORIES, priorities=S.PRIORITIES, internal=internal)


@bp.route("/<int:cid>/action", methods=["POST"])
@login_required
def action(cid):
    ident = g.identity
    c = _load_visible(cid)
    act = request.form.get("action", "")
    if act not in S.available_actions(ident, c):
        abort(403)
    owner = c["complainant_user_id"]
    assignee_uid = S.staff_user_id(c["assigned_staff_id"])
    try:
        if act == "accept":
            S.transition(ident, cid, "In Progress", _text("remarks", 255, required=False))
            S.notify(owner, cid, "Work has started", f"Complaint #{cid} is now being worked on.")
            msg = "You accepted the complaint."
        elif act == "submit_resolution":
            S.transition(ident, cid, "Resolution Pending Verification", _text("remarks", 255))
            S.notify(S.officer_user_id(), cid, "Resolution awaiting verification", f"#{cid}: {c['title']}")
            msg = "Resolution submitted for officer verification."
        elif act == "verify":
            decision = request.form.get("decision")
            remarks = _text("remarks", 200 if decision == "approve" else 255, required=decision == "return")
            if decision == "approve":
                S.transition(ident, cid, "Resolved", remarks)
                S.notify(owner, cid, "Complaint resolved", f"Complaint #{cid} has been resolved.")
                msg = "Resolution approved."
            elif decision == "return":
                S.transition(ident, cid, "In Progress", remarks)
                S.notify(assignee_uid, cid, "Resolution returned", f"#{cid}: {remarks}")
                msg = "Resolution returned to the assignee."
            else:
                raise WorkflowError("Choose approve or return.")
        elif act == "final_decision":
            S.transition(ident, cid, "Resolved", _text("remarks", 200))
            S.notify(owner, cid, "Final decision recorded", f"Complaint #{cid} has been resolved by the officer.")
            msg = "Final decision recorded."
        elif act == "reject":
            S.transition(ident, cid, "Rejected", _text("remarks", 200 if S.level_number(c["current_level_id"]) >= 4 else 255))
            S.notify(owner, cid, "Complaint rejected", f"Complaint #{cid} was rejected.")
            msg = "Complaint rejected."
        elif act == "assign":
            staff_id = request.form.get("staff_id", "")
            if not staff_id.isdigit():
                raise WorkflowError("Choose a staff member.")
            S.reassign(ident, cid, int(staff_id), _text("reason", 255))
            S.notify(S.staff_user_id(int(staff_id)), cid, "Complaint assigned to you", f"#{cid}: {c['title']}")
            msg = "Assignment updated."
        elif act == "escalate":
            to_level = request.form.get("to_level_id", "")
            if not to_level.isdigit():
                raise WorkflowError("Choose the target level.")
            S.escalate(ident, cid, int(to_level), _text("reason", 1000))
            S.notify(owner, cid, "Complaint escalated", f"Complaint #{cid} moved to a higher review level.")
            S.notify(assignee_uid, cid, "Complaint escalated", f"#{cid} was escalated; your assignment has closed.")
            lvl = S.level_number(int(to_level))
            targets = [S.officer_user_id()] if lvl and lvl >= 4 else S.department_authorities(c["department_id"], lvl or 2)
            for uid in targets:
                S.notify(uid, cid, "Escalated complaint needs assignment", f"#{cid}: {c['title']}")
            msg = "Complaint escalated. It now needs assignment at the new level."
        elif act == "request_escalation":
            S.request_escalation(ident, cid, _text("reason", 255))
            for uid in S.department_authorities(c["department_id"], S.level_number(c["current_level_id"]) + 1):
                S.notify(uid, cid, "Escalation requested", f"#{cid}: {c['title']}")
            msg = "Escalation request recorded for your supervisors."
        elif act in ("edit_own", "edit_details"):
            title = _text("title", 180, required=False)
            description = _text("description", 5000, required=False)
            category = request.form.get("category") or None
            priority = request.form.get("priority") or None
            if category and category not in S.CATEGORIES or priority and priority not in S.PRIORITIES:
                raise WorkflowError("Invalid category or priority.")
            reason = _text("reason", 150, required=False) if act == "edit_details" else None
            S.update_details(ident, cid, title if title != c["title"] else None,
                             description if description != c["description"] else None,
                             category if category != c["category"] else None,
                             priority if priority != c["priority"] else None, reason)
            msg = "Complaint details updated."
        elif act == "archive":
            S.archive(ident, cid, _text("reason", 255))
            flash("Complaint archived.", "success")
            return redirect(url_for("complaints.index"))
        else:
            abort(400)
        flash(msg, "success")
    except (WorkflowError, DataAccessError) as e:
        flash(str(e), "danger")
    return redirect(url_for("complaints.detail", cid=cid))
