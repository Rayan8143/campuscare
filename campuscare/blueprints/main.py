"""Personalised dashboards. The dashboard is chosen from the server-side identity only."""
from flask import Blueprint, g, render_template

from .. import services as S
from ..db import query
from ..security import login_required

bp = Blueprint("main", __name__)


@bp.route("/")
@login_required
def dashboard():
    ident = g.identity
    cat = ident.category
    ctx = {"category": cat}

    if cat in ("student", "external"):
        where, params = "complainant_user_id = %s", [ident.user_id]
        ctx.update(counts=S.status_counts(where, params),
                   recent=S.list_complaints(ident, "own", limit=6),
                   feed=S.recent_activity("cd.complainant_user_id = %s", [ident.user_id], 8))
        return render_template("dashboards/complainant.html", **ctx)

    if cat == "staff":
        where, params = "assigned_staff_id = %s", [ident.staff_id]
        ctx.update(counts=S.status_counts(where, params),
                   queue=S.list_complaints(ident, "assigned", status="open", limit=10),
                   feed=S.recent_activity("cd.assigned_staff_id = %s", [ident.staff_id], 8),
                   avg_days=S.avg_resolution_days(where, params))
        return render_template("dashboards/staff.html", **ctx)

    if cat in ("reviewer", "head"):
        depts = ident.queue_departments()
        ph = ",".join(["%s"] * len(depts))
        where = f"department_id IN ({ph})"
        ctx.update(counts=S.status_counts(where, depts),
                   unassigned=[c for c in S.list_complaints(ident, "queue", status="open", limit=200)
                               if c["assigned_staff_id"] is None][:10],
                   escalated=S.list_complaints(ident, "queue", status="Escalated", limit=10),
                   mine=S.list_complaints(ident, "assigned", status="open", limit=8) if ident.staff_id else [],
                   workload=S.workload(depts),
                   by_priority=S.counts_by("priority", where + " AND status IN ('Submitted','In Progress','Escalated')", depts),
                   trend=S.monthly_trend(where, depts),
                   feed=S.recent_activity(f"cd.department_id IN ({ph})", depts, 10),
                   avg_days=S.avg_resolution_days(where, depts))
        return render_template("dashboards/department.html", **ctx)

    if cat in ("officer", "admin"):
        ctx.update(counts=S.status_counts(),
                   pending_verification=S.list_complaints(ident, "all", status="Resolution Pending Verification", limit=10)
                   if ident.is_officer else [],
                   level4=[c for c in S.list_complaints(ident, "all", status="open", limit=500)
                           if c["current_level_name"] and S.level_number(c["current_level_id"]) >= 4][:10]
                   if ident.is_officer else [],
                   summary=query("SELECT department_name, total_complaints, resolved_complaints, pending_complaints "
                                 "FROM department_complaint_summary ORDER BY total_complaints DESC"),
                   by_category=S.counts_by("category"),
                   by_level=S.counts_by("current_level_name", "status IN ('Submitted','In Progress','Escalated','Resolution Pending Verification')"),
                   trend=S.monthly_trend(),
                   feed=S.recent_activity(limit=12),
                   avg_days=S.avg_resolution_days())
        return render_template("dashboards/officer.html", **ctx)

    return render_template("dashboards/empty.html", **ctx)
