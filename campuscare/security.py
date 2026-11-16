"""Session identity, CSRF and authorization decorators.

The session stores only the user_id and a CSRF token. Roles, permissions, profiles, workflow
memberships and officer status are reloaded from the database on every request, so a revoked
role or deactivated account takes effect immediately. Nothing the browser submits is trusted
for identity; MySQL procedures re-check every rule server-side as a second line of defence.
"""
import hmac
import secrets
import time
from functools import wraps

from flask import abort, flash, g, redirect, request, session, url_for

from .db import one, query


class Identity:
    def __init__(self, user, roles, permissions, student, external, staff, memberships, is_officer):
        self.user_id = user["user_id"]
        self.username = user["username"]
        self.full_name = user["full_name"]
        self.email = user["email"]
        self.roles = roles
        self.permissions = permissions
        self.student = student
        self.external = external
        self.staff = staff
        self.memberships = memberships          # list of {department_id, department_name, level_id, level_number, ...}
        self.is_officer = is_officer

    # --- convenience ---------------------------------------------------------------------
    def can(self, permission_key):
        return permission_key in self.permissions

    def has_role(self, role_name):
        return role_name in self.roles

    @property
    def staff_id(self):
        return self.staff["staff_id"] if self.staff else None

    @property
    def max_level(self):
        if self.is_officer:
            return 4
        return max((m["level_number"] for m in self.memberships), default=0)

    def queue_departments(self):
        """Departments whose queue this user may see: workflow membership at level >= 2."""
        return sorted({m["department_id"] for m in self.memberships if m["level_number"] >= 2})

    def membership_for(self, department_id, level_id):
        for m in self.memberships:
            if m["department_id"] == department_id and m["level_id"] == level_id:
                return m
        return None

    @property
    def category(self):
        if self.is_officer:
            return "officer"
        if self.has_role("SYSTEM_ADMIN"):
            return "admin"
        if self.staff:
            lvl = self.max_level
            return {3: "head", 2: "reviewer"}.get(lvl, "staff")
        if self.student:
            return "student"
        if self.external:
            return "external"
        return "unknown"

    @property
    def category_label(self):
        return {"officer": "Primary Complaint Officer · Level 4", "admin": "System Administrator",
                "head": "Department Head · Level 3", "reviewer": "Department Reviewer · Level 2",
                "staff": "Staff · Level 1", "student": "Student", "external": "External Complainant",
                "unknown": "User"}[self.category]


def load_identity(user_id):
    user = one("SELECT user_id, username, email, full_name, is_active FROM users WHERE user_id = %s", (user_id,))
    if not user or not user["is_active"]:
        return None
    roles = {r["role_name"] for r in query(
        "SELECT r.role_name FROM user_roles ur JOIN roles r ON r.role_id = ur.role_id "
        "WHERE ur.user_id = %s AND ur.is_active = TRUE", (user_id,))}
    if not roles:
        return None
    perms = {r["permission_key"] for r in query(
        "SELECT DISTINCT p.permission_key FROM user_roles ur "
        "JOIN role_permissions rp ON rp.role_id = ur.role_id "
        "JOIN permissions p ON p.permission_id = rp.permission_id "
        "WHERE ur.user_id = %s AND ur.is_active = TRUE", (user_id,))}
    student = one("SELECT s.student_id, s.full_name, s.email, s.phone, s.academic_department_id, "
                  "a.department_name AS academic_department FROM students s "
                  "LEFT JOIN academic_departments a ON a.academic_department_id = s.academic_department_id "
                  "WHERE s.user_id = %s", (user_id,))
    external = one("SELECT external_id, affiliation_type, organization_name, phone FROM external_complainants "
                   "WHERE user_id = %s", (user_id,))
    staff = one("SELECT st.staff_id, st.department_id, d.department_name, st.designation, st.is_active, "
                "st.verification_status FROM staff st JOIN departments d ON d.department_id = st.department_id "
                "WHERE st.user_id = %s AND st.is_active = TRUE AND st.verification_status = 'VERIFIED'", (user_id,))
    memberships = query(
        "SELECT swa.department_id, d.department_name, swa.level_id, wl.level_number, wl.level_name, "
        "swa.can_escalate, swa.can_resolve FROM staff_workflow_assignments swa "
        "JOIN workflow_levels wl ON wl.level_id = swa.level_id "
        "JOIN departments d ON d.department_id = swa.department_id "
        "WHERE swa.user_id = %s ORDER BY wl.level_number DESC, d.department_name", (user_id,)) if staff else []
    officer = one("SELECT user_id FROM primary_officer_assignment WHERE user_id = %s", (user_id,))
    return Identity(user, roles, perms, student, external, staff, memberships,
                    bool(officer) and "PRIMARY_COMPLAINT_OFFICER" in roles)


def init_request_identity():
    g.identity = None
    uid = session.get("uid")
    if uid is None:
        return
    last = session.get("seen", 0)
    from flask import current_app
    idle = current_app.permanent_session_lifetime.total_seconds()
    if time.time() - last > idle:
        session.clear()
        flash("Your session expired. Please sign in again.", "warning")
        return
    identity = load_identity(uid)
    if identity is None:
        session.clear()
        return
    session["seen"] = int(time.time())
    g.identity = identity


# --- CSRF --------------------------------------------------------------------------------
def csrf_token():
    tok = session.get("csrf")
    if not tok:
        tok = session["csrf"] = secrets.token_urlsafe(32)
    return tok


def verify_csrf():
    if request.method in ("POST", "PUT", "PATCH", "DELETE"):
        sent = request.form.get("csrf_token") or request.headers.get("X-CSRF-Token", "")
        if not sent or not hmac.compare_digest(sent, session.get("csrf", "")):
            abort(400, description="The form expired or was tampered with. Please reload and try again.")


# --- decorators --------------------------------------------------------------------------
def login_required(view):
    @wraps(view)
    def wrapped(*a, **kw):
        if g.get("identity") is None:
            return redirect(url_for("auth.login", next=request.path))
        return view(*a, **kw)
    return wrapped


def permission_required(*keys, any_of=True):
    """Require one (default) or all of the given permission keys."""
    def deco(view):
        @wraps(view)
        @login_required
        def wrapped(*a, **kw):
            ident = g.identity
            ok = any(ident.can(k) for k in keys) if any_of else all(ident.can(k) for k in keys)
            if not ok:
                abort(403)
            return view(*a, **kw)
        return wrapped
    return deco


def officer_required(view):
    @wraps(view)
    @login_required
    def wrapped(*a, **kw):
        if not g.identity.is_officer:
            abort(403)
        return view(*a, **kw)
    return wrapped
