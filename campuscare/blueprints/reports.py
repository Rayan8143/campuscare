"""Department and institution reporting. Scope is derived from the identity, never from the request."""
from flask import Blueprint, abort, g, render_template

from .. import services as S
from ..db import query
from ..security import login_required

bp = Blueprint("reports", __name__, url_prefix="/reports")


@bp.route("/")
@login_required
def index():
    ident = g.identity
    if ident.is_officer or ident.can("report:view_global"):
        where, params, title = "1=1", [], "Institution-wide report"
        depts = None
        summary = query("SELECT department_name, total_complaints, resolved_complaints, pending_complaints "
                        "FROM department_complaint_summary ORDER BY total_complaints DESC")
    elif ident.queue_departments():
        depts = ident.queue_departments()
        ph = ",".join(["%s"] * len(depts))
        where, params, title = f"department_id IN ({ph})", depts, "Department report"
        names = {m["department_name"] for m in ident.memberships if m["department_id"] in depts}
        summary = [r for r in query("SELECT department_name, total_complaints, resolved_complaints, pending_complaints "
                                    "FROM department_complaint_summary") if r["department_name"] in names]
    else:
        abort(403)
    return render_template("reports/index.html", title=title, summary=summary,
                           counts=S.status_counts(where, params), by_category=S.counts_by("category", where, params),
                           by_priority=S.counts_by("priority", where, params), trend=S.monthly_trend(where, params, 12),
                           workload=S.workload(depts), avg_days=S.avg_resolution_days(where, params),
                           feed=S.recent_activity(where.replace("department_id", "cd.department_id"), params, 25))
