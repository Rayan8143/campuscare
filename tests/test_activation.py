"""Activation flow tests. NO database access: the procedure call is replaced by a recorder, the
start-up guard is skipped, and no session identity is loaded. Nothing is issued or redeemed.

Run:  python tests/test_activation.py
"""
import hashlib
import io
import logging
import re
import secrets
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import campuscare.blueprints.auth as auth  # noqa: E402
from campuscare import create_app  # noqa: E402
from campuscare.db import WorkflowError  # noqa: E402
from campuscare.logsafety import RedactSecretsFilter  # noqa: E402

RESULTS = []
CALLS = []
REFUSE = {"on": False}


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond)))
    print(f"{'PASS' if cond else 'FAIL'}  {name}{('  — ' + detail) if detail and not cond else ''}")


def fake_call(name, args):
    CALLS.append((name, list(args)))
    if REFUSE["on"]:
        raise WorkflowError("Invalid or expired token.")
    return list(args)


def csrf_of(client):
    r = client.get("/activate")
    return re.search(rb'name="csrf_token" value="([^"]+)"', r.data).group(1).decode(), r


def main():
    auth.call_procedure = fake_call
    app = create_app(verify_db=False)
    app.testing = True
    log_buf = io.StringIO()
    handler = logging.StreamHandler(log_buf)
    handler.addFilter(RedactSecretsFilter())
    for name in ("", "werkzeug", "campuscare", "campuscare.db"):
        logging.getLogger(name).addHandler(handler)
    logging.getLogger().setLevel(logging.DEBUG)

    raw = secrets.token_urlsafe(32)               # same shape as cli_activation.py codes
    good_pw = "correct-horse-12"
    c = app.test_client()
    csrf, page = csrf_of(c)

    # 1. GET cannot redeem
    CALLS.clear()
    r = c.get(f"/activate?token={raw}")
    check("GET with token in URL: no procedure call", not CALLS)
    check("GET with token in URL: redirected to bare /activate", r.status_code == 302 and r.headers["Location"].endswith("/activate"))
    r = c.get(f"/activate?token={raw}", follow_redirects=True)
    check("GET with token in URL: code not echoed in page", raw.encode() not in r.data)
    check("GET form posts to /activate with CSRF field", b'method="post"' in page.data and b'name="csrf_token"' in page.data)
    check("form does not pre-fill the code", b'name="token" required' in page.data and b'value="' + raw.encode() not in page.data)

    # 2. Only POST is accepted; query-string tokens are refused even on POST
    CALLS.clear()
    r = c.post(f"/activate?token={raw}", data={"csrf_token": csrf, "password": good_pw, "password2": good_pw})
    check("POST with token in URL refused without procedure call", r.status_code == 400 and not CALLS)
    for method in ("put", "patch", "delete"):
        r = getattr(c, method)("/activate", data={"csrf_token": csrf, "token": raw})
        check(f"{method.upper()} /activate not allowed", r.status_code == 405)
    CALLS.clear()
    r = c.post("/activate", data={"csrf_token": csrf, "token": raw, "password": good_pw, "password2": good_pw})
    check("POST with code in form body: redeemed, redirect to login", r.status_code == 302 and "/login" in r.headers["Location"])
    name, args = CALLS[0] if CALLS else (None, [None, None])
    check("only redeem_account_token called", name == "redeem_account_token" and len(CALLS) == 1)
    check("SHA-256 of code sent (identical to CLI hashing)", args[0] == hashlib.sha256(raw.encode("ascii")).hexdigest())
    check("scrypt password hash sent", isinstance(args[1], str) and args[1].startswith("scrypt:"))
    check("raw code and raw password never passed to the database", raw not in map(str, args) and good_pw not in map(str, args))

    # 3. CSRF
    CALLS.clear()
    r = c.post("/activate", data={"token": raw, "password": good_pw, "password2": good_pw})
    check("POST without CSRF token rejected (400), no call", r.status_code == 400 and not CALLS)
    r = c.post("/activate", data={"csrf_token": "forged", "token": raw, "password": good_pw, "password2": good_pw})
    check("POST with invalid CSRF token rejected (400), no call", r.status_code == 400 and not CALLS)
    other = app.test_client()
    r = other.post("/activate", data={"csrf_token": csrf, "token": raw, "password": good_pw, "password2": good_pw})
    check("CSRF token from another session rejected", r.status_code == 400 and not CALLS)

    # 4. Password policy = 12 everywhere
    sys.path.insert(0, str(ROOT))
    import cli_activation
    check("Flask minimum equals CLI minimum (12)", auth.MIN_PASSWORD_LENGTH == cli_activation.MIN_PASSWORD_LENGTH == 12)
    CALLS.clear()
    r = c.post("/activate", data={"csrf_token": csrf, "token": raw, "password": "x" * 11, "password2": "x" * 11})
    check("11-character password refused before any call", r.status_code == 400 and not CALLS and b"at least 12" in r.data)
    r = c.post("/activate", data={"csrf_token": csrf, "token": raw, "password": "x" * 12, "password2": "y" * 12})
    check("mismatched passwords refused", r.status_code == 400 and not CALLS)
    r = c.post("/activate", data={"csrf_token": csrf, "token": raw, "password": "x" * 12, "password2": "x" * 12})
    check("12-character password accepted", r.status_code == 302 and len(CALLS) == 1)
    check("shared policy helper used for 11/12 chars",
          auth.password_policy_error("a" * 11, "a" * 11) and auth.password_policy_error("a" * 12, "a" * 12) is None)
    check("form enforces minlength=12 client-side", page.data.count(b'minlength="12"') == 2)

    # Generic errors
    REFUSE["on"] = True
    for label, tok in (("expired/used/unknown code", raw), ("non-ASCII code", "tökën"), ("empty code", ""), ("oversized code", "a" * 201)):
        CALLS.clear()
        r = c.post("/activate", data={"csrf_token": csrf, "token": tok, "password": good_pw, "password2": good_pw})
        check(f"{label}: generic message, 400", r.status_code == 400 and auth.INVALID_CODE_MESSAGE.encode() in r.data)
        check(f"{label}: code not echoed back", (not tok) or tok.encode("utf-8") not in r.data)
    REFUSE["on"] = False

    # 5. Logs
    logging.getLogger("werkzeug").info('%s - - [x] "%s" %s %s', "127.0.0.1", f"GET /activate?token={raw} HTTP/1.1", "302", "-")
    logging.getLogger("werkzeug").info('"%s" %s', f"GET /login?next=/x&token={raw} HTTP/1.1", "200")
    logs = log_buf.getvalue()
    check("raw code absent from all captured application/access logs", raw not in logs, logs[-300:])
    check("access-log line redacted", "/activate?[REDACTED]" in logs)
    check("raw password absent from logs", good_pw not in logs)

    for name in ("", "werkzeug", "campuscare", "campuscare.db"):
        logging.getLogger(name).removeHandler(handler)
    failed = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    return failed


def test_activation():
    assert not main()


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
