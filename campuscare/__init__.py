"""CampusCare 2.0 application factory."""
import logging

from flask import Flask, g, render_template, request

from . import db
from .config import Config
from .security import csrf_token, init_request_identity, verify_csrf

STATUS_BADGES = {"Submitted": "blue", "In Progress": "azure", "Escalated": "orange",
                 "Resolution Pending Verification": "purple", "Resolved": "green", "Rejected": "red"}
PRIORITY_BADGES = {"High": "red", "Medium": "yellow", "Low": "secondary"}


def create_app(config=None, verify_db=True):
    cfg = config or Config.from_environment()
    app = Flask(__name__)
    app.config.update(cfg.flask_mapping())
    app.config["CAMPUSCARE"] = cfg
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    from . import logsafety
    logsafety.install()

    from .blueprints import auth, complaints, main, notifications, reports
    for bp in (auth.bp, main.bp, complaints.bp, notifications.bp, reports.bp):
        app.register_blueprint(bp)

    app.teardown_appcontext(db.close_db)

    @app.before_request
    def _before():
        if request.endpoint == "static":
            return
        verify_csrf()
        init_request_identity()

    @app.after_request
    def _headers(resp):
        resp.headers.setdefault("X-Content-Type-Options", "nosniff")
        resp.headers.setdefault("X-Frame-Options", "DENY")
        resp.headers.setdefault("Referrer-Policy", "same-origin")
        if request.endpoint != "static":
            resp.headers.setdefault("Cache-Control", "no-store")
        return resp

    @app.context_processor
    def _ctx():
        from .services import unread_count
        ident = g.get("identity")
        return {"identity": ident, "csrf_token": csrf_token, "STATUS_BADGES": STATUS_BADGES,
                "PRIORITY_BADGES": PRIORITY_BADGES,
                "unread": unread_count(ident.user_id) if ident else 0}

    @app.template_filter("dt")
    def _dt(v, fmt="%d %b %Y, %H:%M"):
        return v.strftime(fmt) if v else "—"

    for code in (400, 403, 404, 405, 429):
        app.register_error_handler(code, lambda e, c=code: (render_template("errors/error.html", code=c, error=e), c))

    @app.errorhandler(db.DatabaseGuardError)
    def _guard(_e):
        return render_template("errors/error.html", code=503, error=None,
                               message="The database connection failed its safety check."), 503

    @app.errorhandler(db.DataAccessError)
    def _dae(e):
        return render_template("errors/error.html", code=500, error=None, message=str(e)), 500

    @app.errorhandler(500)
    def _500(_e):
        return render_template("errors/error.html", code=500, error=None,
                               message="Something went wrong. The error has been logged."), 500

    if verify_db:
        db.verify_startup(app)
    return app
