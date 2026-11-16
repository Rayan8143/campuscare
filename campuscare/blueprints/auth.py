"""Login, logout and account activation."""
import hashlib
import time

from flask import Blueprint, current_app, flash, g, redirect, render_template, request, session, url_for
from werkzeug.security import check_password_hash, generate_password_hash

from ..db import WorkflowError, call_procedure, one

bp = Blueprint("auth", __name__)

_attempts = {}   # (ip, username) -> [count, first_ts]; in-process throttle for the dev server
_DUMMY_HASH = generate_password_hash("not-a-real-password", method="scrypt")


def _throttled(key):
    cfg = current_app.config["CAMPUSCARE"]
    count, first = _attempts.get(key, (0, 0))
    if count and time.time() - first > cfg.LOGIN_LOCKOUT_SECONDS:
        _attempts.pop(key, None)
        return False
    return count >= cfg.LOGIN_MAX_ATTEMPTS


def _record_failure(key):
    count, first = _attempts.get(key, (0, time.time()))
    _attempts[key] = (count + 1, first)


def _safe_next(target):
    return target if target and target.startswith("/") and not target.startswith("//") else None


@bp.route("/login", methods=["GET", "POST"])
def login():
    if g.get("identity"):
        return redirect(url_for("main.dashboard"))
    if request.method == "POST":
        username = request.form.get("username", "").strip()[:100]
        password = request.form.get("password", "")
        key = (request.remote_addr, username.lower())
        if _throttled(key):
            flash("Too many failed attempts. Try again in a few minutes.", "danger")
            return render_template("auth/login.html", username=username), 429
        user = one("SELECT user_id, password_hash, is_active FROM users WHERE username = %s OR email = %s",
                   (username, username))
        stored = user["password_hash"] if user and user["password_hash"] else _DUMMY_HASH
        valid = check_password_hash(stored, password) and user is not None and bool(user["password_hash"])
        if not valid or not user["is_active"]:
            _record_failure(key)
            flash("Invalid credentials or the account is not active.", "danger")
            return render_template("auth/login.html", username=username), 401
        has_role = one("SELECT 1 AS ok FROM user_roles WHERE user_id = %s AND is_active = TRUE LIMIT 1",
                       (user["user_id"],))
        if not has_role:
            flash("Your account has no active role. Contact the administrator.", "warning")
            return render_template("auth/login.html", username=username), 403
        _attempts.pop(key, None)
        session.clear()                      # prevent session fixation
        session.permanent = True
        session["uid"] = user["user_id"]
        session["seen"] = int(time.time())
        return redirect(_safe_next(request.args.get("next")) or url_for("main.dashboard"))
    return render_template("auth/login.html", username="")


@bp.route("/logout", methods=["POST"])
def logout():
    session.clear()
    flash("You have been signed out.", "info")
    return redirect(url_for("auth.login"))


MIN_PASSWORD_LENGTH = 12          # matches cli_activation.py; the one policy for every password-setting flow
MAX_PASSWORD_LENGTH = 256
INVALID_CODE_MESSAGE = "The activation code is invalid, expired or already used."


def password_policy_error(password, confirm):
    """Shared validation for every flow that sets a password. Returns a message or None."""
    if password != confirm:
        return "The passwords do not match."
    if len(password) < MIN_PASSWORD_LENGTH:
        return f"The password must be at least {MIN_PASSWORD_LENGTH} characters."
    if len(password) > MAX_PASSWORD_LENGTH:
        return f"The password must be at most {MAX_PASSWORD_LENGTH} characters."
    return None


def _token_hash(raw):
    """SHA-256 hex digest of the code, exactly as cli_activation.py computes it; None if malformed."""
    if not raw or len(raw) > 200:
        return None
    try:
        return hashlib.sha256(raw.encode("ascii")).hexdigest()
    except UnicodeEncodeError:
        return None


@bp.route("/activate", methods=["GET"])
def activate():
    """Show the activation form. A code is NEVER accepted from the URL: any query string is
    discarded by redirecting to the bare path (keeps it out of history and Referer headers)."""
    if request.query_string:
        return redirect(url_for("auth.activate"))
    if g.get("identity"):
        flash("Sign out first to activate a different account.", "warning")
        return redirect(url_for("main.dashboard"))
    return render_template("auth/activate.html", min_length=MIN_PASSWORD_LENGTH)


@bp.route("/activate", methods=["POST"])
def activate_submit():
    """Redeem a one-time code (CSRF verified globally in before_request). Raw code and password
    are never logged, echoed back or stored; only their hashes reach the database."""
    def fail(message):
        flash(message, "danger")
        return render_template("auth/activate.html", min_length=MIN_PASSWORD_LENGTH), 400

    if g.get("identity"):
        flash("Sign out first to activate a different account.", "warning")
        return redirect(url_for("main.dashboard"))
    if request.args:
        return fail(INVALID_CODE_MESSAGE)
    error = password_policy_error(request.form.get("password", ""), request.form.get("password2", ""))
    if error:
        return fail(error)
    token_hash = _token_hash(request.form.get("token", "").strip())
    if token_hash is None:
        return fail(INVALID_CODE_MESSAGE)
    try:
        call_procedure("redeem_account_token",
                       [token_hash, generate_password_hash(request.form["password"], method="scrypt"), 0])
    except WorkflowError:
        return fail(INVALID_CODE_MESSAGE)
    flash("Your password has been set. You can now sign in.", "success")
    return redirect(url_for("auth.login"))
