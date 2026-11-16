from flask import Blueprint, flash, g, redirect, render_template, request, url_for

from ..db import execute_notification_write, query
from ..security import login_required

bp = Blueprint("notifications", __name__, url_prefix="/notifications")


@bp.route("/")
@login_required
def index():
    rows = query("SELECT notification_id, complaint_id, title, message, is_read, created_at FROM notifications "
                 "WHERE user_id = %s ORDER BY created_at DESC, notification_id DESC LIMIT 100", (g.identity.user_id,))
    return render_template("notifications/list.html", rows=rows)


@bp.route("/read", methods=["POST"])
@login_required
def mark_read():
    nid = request.form.get("notification_id", "")
    if nid == "all":
        execute_notification_write("UPDATE notifications SET is_read = TRUE WHERE user_id = %s AND is_read = FALSE",
                                   (g.identity.user_id,))
    elif nid.isdigit():
        # user_id predicate: a user can only mark their own notifications
        execute_notification_write("UPDATE notifications SET is_read = TRUE WHERE notification_id = %s AND user_id = %s",
                                   (int(nid), g.identity.user_id))
    flash("Notifications updated.", "info")
    return redirect(request.form.get("back") if (request.form.get("back") or "").startswith("/")
                    and not request.form.get("back", "").startswith("//") else url_for("notifications.index"))
