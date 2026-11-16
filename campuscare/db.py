"""Centralised, guarded database access for the runtime account.

* One connection per request (flask.g), autocommit ON: every stored procedure manages its own
  transaction, and START TRANSACTION inside a procedure would implicitly commit caller work.
* Connection guard: every new connection must report DATABASE() == college_complaints_v2_dev and
  CURRENT_USER() == complaint_app_v2_dev@localhost, otherwise it is closed and the request fails.
* Writes to complaint data happen ONLY through the allow-listed stored procedures. The only direct
  writes the runtime account holds are notification columns (see repositories.notifications).
* All statements are parameterised. Errors are logged by code only; procedure SIGNAL messages
  (SQLSTATE 45000 / errno 1644) are authored by us and safe to show to the user.
"""
import logging

import mysql.connector
from flask import current_app, g

from .config import REQUIRED_DATABASE, REQUIRED_DB_USER

log = logging.getLogger("campuscare.db")

ALLOWED_PROCEDURES = {
    "submit_complaint", "update_complaint_details", "transition_complaint_status", "escalate_complaint",
    "request_escalation", "reassign_complaint", "soft_delete_complaint", "transfer_primary_officer",
    "issue_account_token", "redeem_account_token",
}


class DatabaseGuardError(RuntimeError):
    """The connection is not the expected sandbox/account. Never recoverable per request."""


class WorkflowError(Exception):
    """A business rule refused the operation (procedure SIGNAL). Message is user-safe."""


class DataAccessError(Exception):
    """Any other database failure. Message is generic."""


def _open():
    cfg = current_app.config["CAMPUSCARE"]
    cnx = mysql.connector.connect(host=cfg.DB_HOST, port=cfg.DB_PORT, user=cfg.DB_USER, password=cfg.DB_PASSWORD,
                                  database=cfg.DB_NAME, autocommit=True, charset="utf8mb4",
                                  collation="utf8mb4_unicode_ci", connection_timeout=10)
    cur = cnx.cursor()
    try:
        cur.execute("SELECT DATABASE(), CURRENT_USER()")
        database, account = cur.fetchone()
    finally:
        cur.close()
    if database != REQUIRED_DATABASE or account != f"{REQUIRED_DB_USER}@localhost":
        cnx.close()
        log.critical("connection guard rejected database=%s account=%s", database, account)
        raise DatabaseGuardError("Database connection guard failed.")
    return cnx


def get_db():
    if "db" not in g:
        g.db = _open()
    return g.db


def close_db(_exc=None):
    cnx = g.pop("db", None)
    if cnx is not None:
        try:
            cnx.close()
        except Exception:  # noqa: BLE001
            pass


def query(sql, params=()):
    cur = get_db().cursor(dictionary=True)
    try:
        cur.execute(sql, params)
        return cur.fetchall()
    except mysql.connector.Error as exc:
        log.error("query failed errno=%s", getattr(exc, "errno", None))
        raise DataAccessError("The data could not be loaded.") from exc
    finally:
        cur.close()


def one(sql, params=()):
    rows = query(sql, params)
    return rows[0] if rows else None


def scalar(sql, params=()):
    row = one(sql, params)
    return next(iter(row.values())) if row else None


def execute_notification_write(sql, params):
    """The only non-procedure write path (notifications columns granted to the runtime account)."""
    if not sql.lstrip().upper().startswith(("INSERT INTO NOTIFICATIONS", "UPDATE NOTIFICATIONS")):
        raise DataAccessError("Direct writes are limited to notifications.")
    cur = get_db().cursor()
    try:
        cur.execute(sql, params)
        return cur.rowcount
    except mysql.connector.Error as exc:
        log.error("notification write failed errno=%s", getattr(exc, "errno", None))
        raise DataAccessError("The notification could not be saved.") from exc
    finally:
        cur.close()


def call_procedure(name, args):
    """Call an allow-listed stored procedure; returns the argument list (OUT values filled in)."""
    if name not in ALLOWED_PROCEDURES:
        raise DataAccessError("Operation not permitted.")
    cnx = get_db()
    if cnx.in_transaction:
        raise DataAccessError("Procedures must be called outside an open transaction.")
    cur = cnx.cursor()
    try:
        result = cur.callproc(name, args)
        for _ in cur.stored_results():
            pass
        return list(result)
    except mysql.connector.Error as exc:
        errno = getattr(exc, "errno", None)
        if errno == 1644:
            log.info("procedure %s refused: %s", name, exc.msg)
            raise WorkflowError(exc.msg) from exc
        log.error("procedure %s failed errno=%s", name, errno)
        raise DataAccessError("The operation could not be completed.") from exc
    finally:
        cur.close()


def verify_startup(app):
    """Fail fast at start-up if the guard cannot be satisfied."""
    with app.app_context():
        try:
            get_db()
        finally:
            close_db()
