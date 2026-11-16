"""Offline tests for cli_activation.py. NO MySQL connection: get_db() is replaced by a fake that
records every SQL statement and procedure call. No code is issued and no account is touched.

Run:  python tests/test_cli_activation.py
"""
import contextlib
import hashlib
import io
import logging
import os
import subprocess
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import cli_activation as cli  # noqa: E402

RESULTS = []
DB_LOG = {"connects": 0, "sql": [], "procs": []}


def check(name, cond, detail=""):
    RESULTS.append((name, bool(cond)))
    print(f"{'PASS' if cond else 'FAIL'}  {name}{('  — ' + detail) if detail and not cond else ''}")


class FakeCursor:
    def __init__(self):
        self._row = None

    def execute(self, sql, params=()):
        DB_LOG["sql"].append((sql, tuple(params)))
        self._row = {"user_id": 42, "full_name": "Test Student"}

    def fetchone(self):
        return self._row

    def callproc(self, name, args):
        DB_LOG["procs"].append((name, tuple(args)))
        return list(args)

    def close(self):
        pass


class FakeDB:
    def cursor(self, dictionary=False):
        return FakeCursor()

    def close(self):
        pass


def fake_get_db():
    DB_LOG["connects"] += 1
    return FakeDB()


def run_issue(code_file=None, purpose="activation", ttl=60):
    for k in ("sql", "procs"):
        DB_LOG[k].clear()
    DB_LOG["connects"] = 0
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = cli.issue_token("student@example.invalid", purpose, ttl, code_file)
    return rc, out.getvalue(), err.getvalue()


def main():
    cli.get_db = fake_get_db
    log_buf = io.StringIO()
    handler = logging.StreamHandler(log_buf)
    logging.getLogger().addHandler(handler)
    logging.getLogger().setLevel(logging.DEBUG)

    # Terminal output format
    rc, out, err = run_issue()
    m = re.search(r"One-time activation code[^\n]*\n  (\S+)\n", out)
    code = m.group(1) if m else ""
    check("terminal: exit 0", rc == 0, err)
    check("terminal: code printed on its own line", bool(m))
    check("terminal: code has CLI shape (token_urlsafe(32), 43 chars)", re.fullmatch(r"[A-Za-z0-9_-]{43}", code) is not None, code)
    check("terminal: no URL contains the code", not re.search(r"https?://\S*" + re.escape(code), out) if code else False)
    check("terminal: no token= query parameter anywhere", "token=" not in out and "?" not in out)
    check("terminal: points to bare /activate form", "/activate and pasting the code into the form" in out)
    check("terminal: nothing on stderr", err == "")

    # Hashing / database calls
    name, args = DB_LOG["procs"][0] if DB_LOG["procs"] else (None, ())
    check("db: exactly one procedure call, issue_account_token_operator", len(DB_LOG["procs"]) == 1 and name == "issue_account_token_operator")
    check("db: SHA-256 hex digest of the code sent", args[1:2] == (hashlib.sha256(code.encode("ascii")).hexdigest(),))
    check("db: purpose and TTL passed unchanged", args[2:] == ("ACTIVATION", 60))
    flat = " ".join(s for s, _ in DB_LOG["sql"]) + " " + repr(DB_LOG["sql"]) + repr(DB_LOG["procs"])
    check("db: raw code never in SQL text, parameters or procedure args", code not in flat)
    check("db: password-reset purpose mapping preserved", run_issue(purpose="password-reset")[0] == 0 and DB_LOG["procs"][0][1][2] == "PASSWORD_RESET")
    rc1, out1, _ = run_issue(); rc2, out2, _ = run_issue()
    c1 = re.search(r"\n  (\S+)\n", out1).group(1); c2 = re.search(r"\n  (\S+)\n", out2).group(1)
    check("codes are fresh per issue", c1 != c2)

    with tempfile.TemporaryDirectory() as tmp:
        # --code-file writes only the code to a NEW file
        target = Path(tmp) / "student.activation-code"
        rc, out, err = run_issue(code_file=str(target))
        written = target.read_text(encoding="utf-8") if target.exists() else ""
        fcode = written.strip()
        check("code-file: exit 0 and file created", rc == 0 and target.exists(), err)
        check("code-file: contains only the code + newline", re.fullmatch(r"[A-Za-z0-9_-]{43}\n", written) is not None, repr(written[:60]))
        check("code-file: no URL or token= in file", "http" not in written and "token=" not in written)
        check("code-file: code NOT printed to terminal", fcode and fcode not in out)
        check("code-file: hash in DB matches file code", DB_LOG["procs"][0][1][1] == hashlib.sha256(fcode.encode("ascii")).hexdigest())

        # Existing file is never overwritten, and nothing is issued
        existing = Path(tmp) / "existing.activation-code"
        existing.write_text("ORIGINAL CONTENT\n", encoding="utf-8")
        rc, out, err = run_issue(code_file=str(existing))
        check("existing file: refused with exit 1", rc == 1 and "already exists" in err)
        check("existing file: content unchanged", existing.read_text(encoding="utf-8") == "ORIGINAL CONTENT\n")
        check("existing file: no database connection or code issued", DB_LOG["connects"] == 0 and not DB_LOG["procs"])

        # Reserved file tampered with before the code is written -> refuse, never overwrite
        racy = Path(tmp) / "racy.activation-code"
        real_callproc = FakeCursor.callproc
        def callproc_then_tamper(self, n, a):
            with open(racy, "a", encoding="utf-8") as fh:
                fh.write("TAMPER\n")
            return real_callproc(self, n, a)
        FakeCursor.callproc = callproc_then_tamper
        rc, out, err = run_issue(code_file=str(racy))
        FakeCursor.callproc = real_callproc
        check("tamper: modified reserved file is not overwritten", rc == 1 and racy.read_text(encoding="utf-8") == "TAMPER\n")
        check("tamper: code not printed when write fails", not re.search(r"\n  [A-Za-z0-9_-]{43}\n", out))

        # File naming rule (git-ignored suffix)
        bad = Path(tmp) / "code.txt"
        rc, out, err = run_issue(code_file=str(bad))
        check("naming: non-.activation-code file refused before any DB connection",
              rc == 1 and not bad.exists() and DB_LOG["connects"] == 0 and ".activation-code" in err)

        # Failure after reservation removes the empty reserved file
        failing = Path(tmp) / "fail.activation-code"
        def boom(self, n, a):
            raise RuntimeError("refused")
        FakeCursor.callproc = boom
        rc, out, err = run_issue(code_file=str(failing))
        FakeCursor.callproc = real_callproc
        check("issue failure: reserved file removed, no code shown", rc == 1 and not failing.exists() and "  " not in out)

        # NTFS ACL (real icacls, real file system)
        if os.name == "nt":
            entries = cli.acl_entries(target)
            raw_icacls = subprocess.run([str(cli.SYSTEM32 / "icacls.exe"), str(target)], capture_output=True, text=True).stdout
            print("      icacls:", " | ".join(entries))
            check("acl: exactly 3 entries", len(entries) == 3, raw_icacls)
            check("acl: no inherited entries ((I) absent)", all("(I)" not in e for e in entries), raw_icacls)
            want = {cli._sid_to_name(x).lower() for x in (cli.current_user_sid(), cli.SID_SYSTEM, cli.SID_ADMINISTRATORS)}
            check("acl: principals = current user, SYSTEM, Administrators", {e.rsplit(":", 1)[0].lower() for e in entries} == want)
            check("acl: no Users / Authenticated Users / Everyone", not any(re.search(r"(?i)\\(Users|Authenticated Users)\b|Everyone", e.rsplit(":", 1)[0]) for e in entries), raw_icacls)
            check("acl: each entry is Full control", all(e.endswith("(F)") for e in entries))
            check("acl: verify_acl_windows accepts the locked file", bool(cli.verify_acl_windows(target)))
            loose = Path(tmp) / "loose.activation-code"
            loose.write_text("", encoding="utf-8")       # inherits the temp folder's ACL
            try:
                cli.verify_acl_windows(loose); rejected = False
            except OSError:
                rejected = True
            check("acl: verifier rejects a file with the default inherited ACL", rejected)
            check("acl: os.open 0o600 alone is NOT sufficient (inherited ACL present)", "(I)" in " ".join(cli.acl_entries(loose)))
            # restore access so TemporaryDirectory can clean up (we own the files)
        else:
            check("acl: skipped (not Windows)", True)

    # Git exclusion
    gi = (ROOT / ".gitignore").read_text(encoding="utf-8").splitlines()
    check("gitignore: *.activation-code excluded", "*.activation-code" in gi)
    check("gitignore: activation_codes/ excluded", "activation_codes/" in gi)

    # Argument surface: no URL option, no code on the command line
    parser_help = io.StringIO()
    with contextlib.redirect_stdout(parser_help), contextlib.suppress(SystemExit):
        cli.main(["--help"])
    h = parser_help.getvalue()
    check("argparse: --code-file present, --link-file removed", "--code-file" in h and "--link-file" not in h)
    check("argparse: no option accepts a code/token value", not re.search(r"--(token|code)\b(?!-file)", h))
    with contextlib.redirect_stderr(io.StringIO()), contextlib.suppress(SystemExit):
        try:
            cli.main(["--email", "x@example.invalid", "--link-file", "a.txt"]); rejected = False
        except SystemExit:
            rejected = True
    check("argparse: legacy --link-file rejected", rejected)

    # Redeem path still prompts with getpass (never argv) and keeps hashing
    src = (ROOT / "cli_activation.py").read_text(encoding="utf-8")
    check("redeem: code read via getpass (hidden prompt)", 'getpass.getpass("Token (input hidden): ")' in src)
    check("redeem: SHA-256 + scrypt preserved", 'hashlib.sha256(raw_token.encode("ascii")).hexdigest()' in src
          and 'generate_password_hash(password, method="scrypt")' in src)
    check("source: no activation URL with a query parameter is constructed", "?token=" not in src and "reset-password" not in src)
    check("source: TTL bounds 5..10080 preserved", "5 <= args.ttl_minutes <= 10080" in src)
    check("source: no logging module used (codes never logged)", "import logging" not in src)
    check("logs: no code in any captured log record", not re.search(r"[A-Za-z0-9_-]{43}", log_buf.getvalue()))

    logging.getLogger().removeHandler(handler)
    failed = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    return failed


def test_cli_activation():
    assert not main()


if __name__ == "__main__":
    sys.exit(1 if main() else 0)
