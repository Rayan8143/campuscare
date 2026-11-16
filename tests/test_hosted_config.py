"""Offline tests for the hosted-database guards. No database connection.
Run: python tests/test_hosted_config.py"""
import base64
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campuscare import config as C  # noqa: E402
from campuscare import db  # noqa: E402

RES = []


def check(name, cond, detail=""):
    RES.append(bool(cond))
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  — {detail}" if detail and not cond else ""))


BASE = {"DB_NAME": "college_complaints_v2_dev", "DB_USER": "complaint_app_v2_dev", "DB_PASSWORD": "x" * 12,
        "FLASK_SECRET_KEY": "s" * 32, "DB_HOST": "localhost", "DB_PORT": "3306"}
KEYS = list(BASE) + ["DB_SSL_CA", "TRUST_PROXY"]


def cfg(**over):
    saved = {k: os.environ.get(k) for k in KEYS}
    try:
        for k in KEYS:
            os.environ.pop(k, None)
        os.environ.update({**BASE, **over})
        return C.Config.from_environment()
    finally:
        for k, v in saved.items():
            os.environ.pop(k, None)
            if v is not None:
                os.environ[k] = v


def refused(**over):
    try:
        cfg(**over)
        return None
    except C.ConfigError as e:
        return str(e)


CA = base64.b64encode(b"-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n").decode()
check("local host still accepted, not hosted", cfg().DB_SSL_CA_B64 == "")
check("random remote host refused", refused(DB_HOST="db.example.com", DB_SSL_CA=CA) is not None)
check("lookalike host refused", refused(DB_HOST="evil-aivencloud.com", DB_SSL_CA=CA) is not None)
check("aiven host without CA refused", "DB_SSL_CA" in (refused(DB_HOST="mysql-x.a.aivencloud.com") or ""))
check("aiven host with CA accepted", cfg(DB_HOST="mysql-x.a.aivencloud.com", DB_SSL_CA=CA).DB_SSL_CA_B64 == CA)
check("wrong database still refused", refused(DB_NAME="college_complaints") is not None)
check("wrong user still refused", refused(DB_USER="root") is not None)
check("weak secret still refused", refused(FLASK_SECRET_KEY="short") is not None)
check("TRUST_PROXY off by default, on when set", not cfg().TRUST_PROXY and cfg(TRUST_PROXY="1").TRUST_PROXY)
check("local account must be @localhost", db._account_ok("complaint_app_v2_dev@localhost", False)
      and not db._account_ok("complaint_app_v2_dev@%", False))
check("hosted account must be @%", db._account_ok("complaint_app_v2_dev@%", True)
      and not db._account_ok("complaint_app_v2_dev@localhost", True))
check("other accounts refused (root, avnadmin)", not any(db._account_ok(a, h) for a in ("root@localhost", "avnadmin@%", "avnadmin@localhost") for h in (True, False)))
print(f"\n{sum(RES)}/{len(RES)} passed")
sys.exit(0 if all(RES) else 1)
