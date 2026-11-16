"""Provision the hosted Aiven MySQL as an exact copy of the local sandbox (college_complaints_v2_dev ONLY).

Why not the migration runner: it is hard-wired to localhost, and Aiven's admin (avnadmin) lacks
SET_USER_ID, so it cannot create routines owned by another account. Instead each definer account
(cc_v2_dev_routine_definer / cc_v2_dev_trigger_definer) is created, briefly allowed to log in, creates
its OWN objects, then is locked again - the same ownership as locally, with host '%' instead of 'localhost'.

Inputs : .env.aiven (admin password), aiven_ca.pem, backups/aiven/{data,routines,triggers}_<stamp>.sql
Usage  : python stage3_logs/aiven_provision.py <stamp>            (provision; refuses if the DB exists)
         python stage3_logs/aiven_provision.py <stamp> --reset    (drop ONLY this DB and these 4 accounts)
Secrets: random passwords are generated in memory; the runtime app password is appended to .env.aiven
         (git-ignored) and never printed. Definer/CLI passwords are discarded; those accounts end LOCKED.
"""
import os
import re
import secrets
import subprocess
import sys
import tempfile
from pathlib import Path

import mysql.connector

ROOT = Path(__file__).resolve().parent.parent
MYSQL = r"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"
DB = "college_complaints_v2_dev"
ROUTINE_DEFINER, TRIGGER_DEFINER = "cc_v2_dev_routine_definer", "cc_v2_dev_trigger_definer"
APP, CLI = "complaint_app_v2_dev", "cc_v2_dev_activation_cli"
OUR_ACCOUNTS = (ROUTINE_DEFINER, TRIGGER_DEFINER, APP, CLI)
ENV_PATH = ROOT / ".env.aiven"


def load_env():
    env = {}
    for line in ENV_PATH.read_text(encoding="utf-8").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    if not env.get("DB_ADMIN_PASSWORD"):
        sys.exit("STOP: DB_ADMIN_PASSWORD is empty in .env.aiven")
    if not env["DB_ADMIN_HOST"].endswith(".aivencloud.com"):
        sys.exit("STOP: not an Aiven host")
    return env


ENV = load_env()
CA = str(ROOT / ENV.get("DB_ADMIN_CA_FILE", "aiven_ca.pem"))
if not Path(CA).exists():
    sys.exit("STOP: aiven_ca.pem missing")


def connect(user, password, database=None):
    return mysql.connector.connect(host=ENV["DB_ADMIN_HOST"], port=int(ENV["DB_ADMIN_PORT"]), user=user, password=password,
                                   database=database, ssl_ca=CA, ssl_verify_cert=True, ssl_verify_identity=True,
                                   autocommit=True, connection_timeout=20)


def admin(database=None):
    return connect(ENV["DB_ADMIN_USER"], ENV["DB_ADMIN_PASSWORD"], database)


def run_client(user, password, sql_path_or_text, database=DB):
    """Run a SQL file/text through the mysql client (handles DELIMITER blocks). Password via a temp option file."""
    fd, opt = tempfile.mkstemp(prefix="cc_aiven_", suffix=".cnf")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(f"[client]\nhost={ENV['DB_ADMIN_HOST']}\nport={ENV['DB_ADMIN_PORT']}\nuser={user}\npassword={password}\n"
                     f"ssl-mode=VERIFY_IDENTITY\nssl-ca={CA.replace(chr(92), '/')}\ndefault-character-set=utf8mb4\n")
        r = subprocess.run([MYSQL, f"--defaults-extra-file={opt}", f"--database={database}", "--batch"],
                           input=sql_path_or_text, capture_output=True, text=True, encoding="utf-8")
    finally:
        try:
            os.remove(opt)
        except OSError:
            pass
    if r.returncode != 0:
        raise RuntimeError("mysql client failed: " + (r.stderr or "").replace(password, "***")[:600])


def reset():
    c = admin(); cur = c.cursor()
    cur.execute(f"DROP DATABASE IF EXISTS `{DB}`")
    for a in OUR_ACCOUNTS:
        cur.execute(f"DROP USER IF EXISTS '{a}'@'%'")
    print(f"reset done: database {DB} and accounts {OUR_ACCOUNTS} dropped (Aiven only)")


def grant_statements():
    """GRANT/REVOKE statements for our four accounts from the reviewed S2_B + the definer-EXECUTE patch."""
    out = []
    for f in (ROOT / "migrations/admin/S2_B_post_migration_grants.sql", ROOT / "stage2_logs/s2e_v2/GRANT_patch_definer_execute.sql"):
        text = re.sub(r"--[^\n]*", "", f.read_text(encoding="utf-8"))
        for m in re.finditer(r"\b(GRANT|REVOKE)\b.*?;", text, re.S | re.I):
            s = m.group(0).rstrip(";")
            if "complaint_migrator" in s or not any(a in s for a in OUR_ACCOUNTS):
                continue
            if re.search(r"\*\.\*", s) or "SET_USER_ID" in s:
                continue
            if re.match(r"REVOKE\s+ALL\s+PRIVILEGES", s, re.I):
                continue          # no-op on freshly created accounts, and Aiven's admin may not touch the mysql schema
            out.append(s.replace("'localhost'", "'%'"))
    return out


def main():
    stamp = sys.argv[1]
    if "--reset" in sys.argv:
        return reset()
    paths = {k: ROOT / f"backups/aiven/{k}_{stamp}.sql" for k in ("data", "routines", "triggers")}
    for k, p in paths.items():
        if not p.exists():
            sys.exit(f"STOP: {p} missing")
    data = paths["data"].read_text(encoding="utf-8")
    routines = paths["routines"].read_text(encoding="utf-8")
    triggers = paths["triggers"].read_text(encoding="utf-8")
    assert data.count("CREATE TABLE") == 22, "data dump: expected 22 tables"
    assert len(re.findall(r"CREATE DEFINER=`" + ROUTINE_DEFINER + r"`@`localhost` PROCEDURE", routines)) == 17, "expected 17 procedures"
    assert len(re.findall(r"DEFINER=`" + TRIGGER_DEFINER + r"`@`localhost`", triggers)) == 4, "expected 4 triggers"
    assert "college_complaints`" not in re.sub(r"college_complaints_v2_dev", "", data + routines + triggers), "protected DB referenced"

    # --- rewrite definers: routines/triggers -> '%'; views -> invoker security without a named definer
    data = re.sub(r"/\*!50013 DEFINER=`[^`]+`@`[^`]+` SQL SECURITY INVOKER \*/", "/*!50013 SQL SECURITY INVOKER */", data)
    routines = routines.replace(f"`{ROUTINE_DEFINER}`@`localhost`", f"`{ROUTINE_DEFINER}`@`%`")
    triggers = triggers.replace(f"`{TRIGGER_DEFINER}`@`localhost`", f"`{TRIGGER_DEFINER}`@`%`")
    assert "@`localhost`" not in data + routines + triggers, "a localhost definer remains"

    c = admin(); cur = c.cursor()
    cur.execute("SHOW DATABASES")
    if DB in [r[0] for r in cur.fetchall()]:
        sys.exit(f"STOP: {DB} already exists on Aiven. Use --reset to drop it (and only it) first.")

    pw = {a: secrets.token_urlsafe(24) for a in OUR_ACCOUNTS}
    print("[1/7] database and accounts")
    cur.execute(f"CREATE DATABASE `{DB}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
    for a in (ROUTINE_DEFINER, TRIGGER_DEFINER, APP):
        cur.execute(f"CREATE USER '{a}'@'%' IDENTIFIED BY '{pw[a]}'")
    cur.execute(f"CREATE USER '{CLI}'@'%' IDENTIFIED BY '{pw[CLI]}' ACCOUNT LOCK")

    print("[2/7] tables, data and views (as admin)")
    run_client(ENV["DB_ADMIN_USER"], ENV["DB_ADMIN_PASSWORD"], data)

    print("[3/7] table grants (reviewed S2_B, host '%'); procedure grants follow once the procedures exist")
    stmts = grant_statements()
    table_grants = [s for s in stmts if "ON PROCEDURE" not in s.upper()]
    proc_grants = [s for s in stmts if "ON PROCEDURE" in s.upper()]
    for s in table_grants:
        cur.execute(s)
    cur.execute(f"GRANT CREATE ROUTINE, ALTER ROUTINE ON `{DB}`.* TO '{ROUTINE_DEFINER}'@'%'")      # temporary, revoked below
    print(f"      {len(table_grants)} table-level statements applied, {len(proc_grants)} procedure grants pending")

    print("[4/7] routines (created by the routine definer itself)")
    cur.execute(f"ALTER USER '{ROUTINE_DEFINER}'@'%' ACCOUNT UNLOCK")
    run_client(ROUTINE_DEFINER, pw[ROUTINE_DEFINER], routines)

    print("[5/7] triggers (created by the trigger definer itself)")
    cur.execute(f"ALTER USER '{TRIGGER_DEFINER}'@'%' ACCOUNT UNLOCK")
    run_client(TRIGGER_DEFINER, pw[TRIGGER_DEFINER], triggers)

    print("[6/7] procedure grants, revoke temporary privileges, lock definer and CLI accounts")
    for s in proc_grants:
        cur.execute(s)
    cur.execute(f"REVOKE CREATE ROUTINE, ALTER ROUTINE ON `{DB}`.* FROM '{ROUTINE_DEFINER}'@'%'")
    cur.execute(f"SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = '{DB}'")
    for (name,) in cur.fetchall():
        try:                                                                  # auto-granted to the creator; not in the local design
            cur.execute(f"REVOKE ALTER ROUTINE ON PROCEDURE `{DB}`.`{name}` FROM '{ROUTINE_DEFINER}'@'%'")
        except mysql.connector.Error:
            pass
    for a in (ROUTINE_DEFINER, TRIGGER_DEFINER, CLI):
        cur.execute(f"ALTER USER '{a}'@'%' ACCOUNT LOCK")
    pw[ROUTINE_DEFINER] = pw[TRIGGER_DEFINER] = pw[CLI] = None

    print("[7/7] runtime account password saved to .env.aiven (never printed)")
    with open(ENV_PATH, "a", encoding="utf-8") as fh:
        fh.write(f"\nDB_APP_USER={APP}\nDB_APP_PASSWORD={pw[APP]}\n")
    print("PROVISIONED. Next: python stage3_logs/aiven_verify.py")


if __name__ == "__main__":
    try:
        main()
    except (AssertionError, RuntimeError, mysql.connector.Error) as e:
        print("FAILED:", str(e)[:700])
        print("The partial hosted copy can be removed with:  python stage3_logs/aiven_provision.py <stamp> --reset")
        sys.exit(1)
