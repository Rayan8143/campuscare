"""
CampusCare 2.0 - local development account activation helper (sandbox only).

Usage
  python cli_activation.py --list-pending
  python cli_activation.py --email <user_email> [--purpose activation|password-reset] [--ttl-minutes N] [--code-file PATH]
  python cli_activation.py --redeem            (prompts for the token and the new password)

Account and environment safety (enforced before any connection is attempted):
  * Connects ONLY as the dedicated development issuer account cc_v2_dev_activation_cli,
    read from DB_ACTIVATION_USER / DB_ACTIVATION_PASSWORD. It is not the Flask runtime
    account; it holds only EXECUTE on issue_account_token_operator / redeem_account_token
    and column-limited reads on users/user_roles/roles (no password or token hashes).
  * DB_NAME must be college_complaints_v2_dev and DB_HOST must be local
    (localhost / 127.0.0.1 / ::1); anything else aborts. The database name is passed
    explicitly and no other schema is ever referenced.
  * Credentials are never printed, logged or echoed.

Token lifecycle (enforced in the database, migration 008):
  1. A fresh 256-bit token is generated with `secrets`; only its SHA-256 hex digest is sent
     to MySQL. The raw token is never stored.
  2. Issuing revokes every previously issued, still-live token of that user; the schema
     allows only one live token per user.
  3. Tokens expire (default 48 h, max 7 days), evaluated in UTC by MySQL.
  4. A password can only be set by redeeming a valid, unexpired, unrevoked, unused token;
     the account is activated in the same transaction and the token marked used.
  5. Activation is refused for unverified/deactivated staff, users without an active role,
     and accounts that already have a password.

Output hygiene: the raw code is shown once on this terminal (or written to a NEW file with
--code-file, which never overwrites an existing file). No URL containing the code is ever built:
the user pastes it into the /activate form (POST + CSRF). The code is never logged, never passed
on the command line and never sent to MySQL (only its SHA-256 digest is); the migration runner
never invokes this tool.
Passwords are read with getpass; only their Werkzeug scrypt hash leaves this process.
"""

import argparse
import getpass
import hashlib
import os
import secrets
import sys
from pathlib import Path

TARGET_DATABASE = "college_complaints_v2_dev"
ISSUER_ACCOUNT = "cc_v2_dev_activation_cli"
ALLOWED_HOSTS = {"localhost", "127.0.0.1", "::1"}
ENV_FILE = Path(__file__).resolve().parent / ".env.development"
MIN_PASSWORD_LENGTH = 12


def load_env():
    if not ENV_FILE.exists():
        return
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ.setdefault(key.strip(), value)


def connection_settings():
    """Validate the environment WITHOUT connecting and without printing any secret."""
    database = os.getenv("DB_NAME", "")
    host = os.getenv("DB_HOST", "localhost")
    user = os.getenv("DB_ACTIVATION_USER", "")
    password = os.getenv("DB_ACTIVATION_PASSWORD", "")
    if database != TARGET_DATABASE:
        raise SystemExit(f"Refusing to run: DB_NAME must be {TARGET_DATABASE}.")
    if host not in ALLOWED_HOSTS:
        raise SystemExit("Refusing to run: DB_HOST must be a local address.")
    if user != ISSUER_ACCOUNT:
        raise SystemExit(f"Refusing to run: DB_ACTIVATION_USER must be {ISSUER_ACCOUNT} "
                         "(the Flask runtime and migrator accounts are never used by this tool).")
    if not password:
        raise SystemExit("Refusing to run: DB_ACTIVATION_PASSWORD is not set.")
    return {"host": host, "port": int(os.getenv("DB_PORT", "3306")), "user": user,
            "password": password, "database": database}


def get_db():
    import mysql.connector

    s = connection_settings()
    # autocommit=True: the procedures manage their own transactions, and a caller-side open
    # transaction would be implicitly committed by START TRANSACTION inside them.
    cnx = mysql.connector.connect(
        host=s["host"], port=s["port"], user=s["user"], password=s["password"],
        database=s["database"], autocommit=True, charset="utf8mb4", collation="utf8mb4_unicode_ci",
    )
    cur = cnx.cursor()
    try:
        cur.execute("SELECT DATABASE(), CURRENT_USER()")
        db_name, account = cur.fetchone()
    finally:
        cur.close()
    if db_name != TARGET_DATABASE or not str(account).startswith(ISSUER_ACCOUNT + "@"):
        cnx.close()
        raise SystemExit("Refusing to continue: connected database/account is not the expected sandbox issuer.")
    return cnx


def db_error_message(exc):
    return getattr(exc, "msg", None) or type(exc).__name__


def list_pending():
    db = get_db()
    cur = db.cursor(dictionary=True)
    try:
        cur.execute("""
            SELECT u.user_id, u.email, u.full_name,
                   GROUP_CONCAT(r.role_name ORDER BY r.role_name SEPARATOR ',') AS roles
              FROM users u
              LEFT JOIN user_roles ur ON ur.user_id = u.user_id AND ur.is_active = TRUE
              LEFT JOIN roles r ON r.role_id = ur.role_id
             WHERE u.is_active = FALSE
             GROUP BY u.user_id, u.email, u.full_name
             ORDER BY u.user_id
        """)
        rows = cur.fetchall()
    finally:
        cur.close()
        db.close()
    print(f"\n--- Inactive accounts ({len(rows)}) ---")
    for r in rows:
        print(f"  [ID {r['user_id']:4d}] {r['email']:<36} | {r['full_name']:<28} | {r['roles'] or 'NO ACTIVE ROLE'}")


CODE_FILE_SUFFIX = ".activation-code"     # ignored by .gitignore; any other name is refused
SYSTEM32 = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32"
SID_SYSTEM = "S-1-5-18"
SID_ADMINISTRATORS = "S-1-5-32-544"


def _run(exe, *args):
    import subprocess
    return subprocess.run([str(SYSTEM32 / exe), *args], capture_output=True, text=True, timeout=30)


def current_user_sid():
    r = _run("whoami.exe", "/user", "/fo", "csv", "/nh")
    sid = r.stdout.strip().rsplit(",", 1)[-1].strip().strip('"') if r.returncode == 0 else ""
    if not sid.startswith("S-1-5-"):
        raise OSError("could not determine the current user's SID")
    return sid


def restrict_acl_windows(path):
    """Replace the file's DACL: remove inheritance and grant Full control only to the current
    user, SYSTEM and Administrators (by SID, so it works on any Windows display language).
    Then read it back with icacls and require exactly those three explicit entries."""
    user_sid = current_user_sid()
    r = _run("icacls.exe", str(path), "/inheritance:r",
             "/grant:r", f"*{user_sid}:(F)", f"*{SID_SYSTEM}:(F)", f"*{SID_ADMINISTRATORS}:(F)")
    if r.returncode != 0:
        raise OSError("icacls could not set the file ACL")
    verify_acl_windows(path, user_sid)


def acl_entries(path):
    """Return the ACE lines icacls reports for one file (principal:(rights))."""
    r = _run("icacls.exe", str(path))
    if r.returncode != 0:
        raise OSError("icacls could not read the file ACL")
    text = r.stdout.replace(str(path), "", 1)
    return [ln.strip() for ln in text.splitlines() if ":" in ln and "(" in ln and "processed" not in ln]


def verify_acl_windows(path, user_sid=None):
    user_sid = user_sid or current_user_sid()
    names = {_sid_to_name(s).lower() for s in (user_sid, SID_SYSTEM, SID_ADMINISTRATORS)}
    entries = acl_entries(path)
    principals = {e.rsplit(":", 1)[0].lower() for e in entries}
    if len(entries) != 3 or principals != names or any("(I)" in e for e in entries):
        raise OSError("code file ACL is not restricted to the current user, SYSTEM and Administrators")
    return entries


def _sid_to_name(sid):
    import ctypes
    from ctypes import wintypes
    advapi = ctypes.WinDLL("advapi32", use_last_error=True)
    psid = ctypes.c_void_p()
    if not advapi.ConvertStringSidToSidW(sid, ctypes.byref(psid)):
        raise OSError("invalid SID")
    try:
        name, dom = ctypes.create_unicode_buffer(256), ctypes.create_unicode_buffer(256)
        n, d, use = wintypes.DWORD(256), wintypes.DWORD(256), wintypes.DWORD()
        if not advapi.LookupAccountSidW(None, psid, name, ctypes.byref(n), dom, ctypes.byref(d), ctypes.byref(use)):
            raise OSError("SID lookup failed")
        return f"{dom.value}\\{name.value}" if dom.value else name.value
    finally:
        ctypes.windll.kernel32.LocalFree(psid)


def reserve_code_file(code_file):
    """Create the code file EMPTY and exclusively (never overwrites), lock its ACL and verify it,
    all BEFORE any code is generated or issued. Returns the path; raises on any failure."""
    path = Path(code_file)
    if not path.name.endswith(CODE_FILE_SUFFIX) or path.name == CODE_FILE_SUFFIX:
        raise ValueError(f"code file name must end with {CODE_FILE_SUFFIX} (git-ignored)")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)   # FileExistsError if present
    os.close(fd)
    try:
        if os.name == "nt":
            restrict_acl_windows(path)
    except Exception:
        path.unlink(missing_ok=True)
        raise
    return path


def issue_token(email, purpose, ttl_minutes, code_file):
    db_purpose = {"activation": "ACTIVATION", "password-reset": "PASSWORD_RESET"}[purpose]
    reserved = None
    if code_file:
        try:
            reserved = reserve_code_file(code_file)
        except FileExistsError:
            print("ERROR: code file already exists; refusing to overwrite it.", file=sys.stderr)
            return 1
        except (OSError, ValueError) as exc:
            print(f"ERROR: code file not created: {exc}", file=sys.stderr)
            return 1
    raw_token = secrets.token_urlsafe(32)                      # 256 bits of entropy
    token_hash = hashlib.sha256(raw_token.encode("ascii")).hexdigest()

    def discard_reserved():
        if reserved is not None:
            reserved.unlink(missing_ok=True)

    try:
        db = get_db()
    except BaseException:
        discard_reserved()
        raise
    cur = db.cursor(dictionary=True)
    try:
        cur.execute("SELECT user_id, full_name FROM users WHERE email = %s", (email,))
        user = cur.fetchone()
        if not user:
            print("ERROR: no user with that e-mail address.", file=sys.stderr)
            discard_reserved()
            return 1
        cur.callproc("issue_account_token_operator", (user["user_id"], token_hash, db_purpose, ttl_minutes))
    except Exception as exc:  # mysql.connector.Error; message comes from the procedure
        print(f"ERROR: token not issued: {db_error_message(exc)}", file=sys.stderr)
        discard_reserved()
        return 1
    finally:
        cur.close()
        db.close()

    # The page address carries NO code: the user pastes the code into the form (POST + CSRF).
    form_url = os.getenv("APP_BASE_URL", "http://localhost:5000").rstrip("/") + "/activate"

    print(f"\nCode issued for user {user['user_id']} ({user['full_name']}); "
          f"purpose {db_purpose}; valid for {ttl_minutes} minutes; all earlier live codes revoked.")
    print(f"Redeem by opening {form_url} and pasting the code into the form.")
    if reserved is not None:
        # The file was created by us, is empty and already ACL-restricted; re-verify before writing.
        try:
            if reserved.stat().st_size != 0:
                raise OSError("reserved code file was modified")
            if os.name == "nt":
                verify_acl_windows(reserved)
            with open(reserved, "r+", encoding="utf-8") as fh:
                fh.write(raw_token + "\n")
        except OSError as exc:
            print(f"ERROR: code not written ({exc}). The issued code is unusable; issue a new one.",
                  file=sys.stderr)
            return 1
        print(f"Code written to {reserved} (owner, SYSTEM and Administrators only; deliver it privately, "
              f"then delete the file).")
    else:
        print("One-time activation code (shown once; never paste into URLs, logs or tickets):")
        print(f"  {raw_token}")
    del raw_token
    return 0


def redeem():
    try:
        from werkzeug.security import generate_password_hash
    except ImportError:
        print("ERROR: werkzeug (installed with Flask) is required for --redeem.", file=sys.stderr)
        return 1

    connection_settings()  # fail fast on a bad environment before prompting
    raw_token = getpass.getpass("Token (input hidden): ").strip()
    password = getpass.getpass(f"New password (min {MIN_PASSWORD_LENGTH} characters): ")
    if password != getpass.getpass("Repeat new password: "):
        print("ERROR: passwords do not match.", file=sys.stderr)
        return 1
    if len(password) < MIN_PASSWORD_LENGTH:
        print("ERROR: password too short.", file=sys.stderr)
        return 1

    try:
        token_hash = hashlib.sha256(raw_token.encode("ascii")).hexdigest()
    except UnicodeEncodeError:
        print("ERROR: invalid token.", file=sys.stderr)
        return 1
    password_hash = generate_password_hash(password, method="scrypt")
    del password, raw_token

    db = get_db()
    cur = db.cursor()
    try:
        result = cur.callproc("redeem_account_token", (token_hash, password_hash, 0))
    except Exception as exc:
        print(f"ERROR: {db_error_message(exc)}", file=sys.stderr)
        return 1
    finally:
        cur.close()
        db.close()
    print(f"Account {result[2]} activated / password set. The token can no longer be used.")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="CampusCare 2.0 account activation CLI (development sandbox)")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--email", help="issue a token for this user")
    group.add_argument("--list-pending", action="store_true", help="list inactive accounts")
    group.add_argument("--redeem", action="store_true", help="redeem a token and set a password")
    parser.add_argument("--purpose", choices=["activation", "password-reset"], default="activation")
    parser.add_argument("--ttl-minutes", type=int, default=48 * 60, help="token lifetime (5..10080, default 2880)")
    parser.add_argument("--code-file", help="write the code to this NEW file (name must end with .activation-code; NTFS ACL: you, SYSTEM, Administrators)")
    args = parser.parse_args(argv)

    load_env()
    if args.list_pending:
        list_pending()
        return 0
    if args.redeem:
        return redeem()
    if not 5 <= args.ttl_minutes <= 10080:
        parser.error("--ttl-minutes must be between 5 and 10080")
    return issue_token(args.email, args.purpose, args.ttl_minutes, args.code_file)


if __name__ == "__main__":
    sys.exit(main())
