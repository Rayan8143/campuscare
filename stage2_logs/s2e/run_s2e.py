"""Run canonical S2_E as complaint_migrator_v2_dev on college_complaints_v2_dev (data-modifying;
must be followed by the approved restore). Usage:
  python -I -B stage2_logs\\s2e\\run_s2e.py --confirm-target college_complaints_v2_dev"""
import datetime
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import mysql.connector

ROOT = Path(__file__).resolve().parents[2]
S2E_SQL = ROOT / "migrations" / "admin" / "S2_E_decision_acceptance_tests.sql"
S2E_SHA256 = "4a3f5dab8f19b1b14756d3819c00031f136caa031b6188b313e09ad235397771"
MYSQL = r"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"
TARGET = "college_complaints_v2_dev"
EXPECTED_PASS = ["F02", "E01", "E03", "E05", "E07", "E10", "E12", "E14", "E17", "E19", "E19b", "E19c",
                 "E21", "E21b", "E24", "E25", "E27", "E29"]
EXPECTED_ERRORS = 16           # F01 + 15 E-probes, each SQLSTATE 45000 / ERROR 1644
FATAL = {2006, 2013, 2055, 1213, 1205}

if sys.argv[1:] != ["--confirm-target", TARGET]:
    sys.exit(__doc__)
if hashlib.sha256(S2E_SQL.read_bytes()).hexdigest() != S2E_SHA256:
    sys.exit("HALT: canonical S2_E checksum changed")
env = {}
for raw in (ROOT / ".env.development").read_text(encoding="utf-8").splitlines():
    l = raw.strip()
    if l and not l.startswith("#") and "=" in l:
        k, v = l.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
if env.get("DB_NAME") != TARGET or env.get("DB_MIGRATOR_USER") != "complaint_migrator_v2_dev" \
        or env.get("DB_HOST") not in ("localhost", "127.0.0.1"):
    sys.exit("HALT: not the dev sandbox migrator")
secrets = [env[k] for k in ("DB_PASSWORD", "DB_MIGRATOR_PASSWORD", "FLASK_SECRET_KEY") if env.get(k)]

c = mysql.connector.connect(host=env["DB_HOST"], port=int(env.get("DB_PORT", "3306")), user=env["DB_MIGRATOR_USER"],
                            password=env["DB_MIGRATOR_PASSWORD"], database=TARGET)
cur = c.cursor()
cur.execute("SELECT CURRENT_USER(), DATABASE(), (SELECT COUNT(*) FROM users WHERE is_active = TRUE), "
            "(SELECT COUNT(*) FROM primary_officer_assignment)")
cu, db, active, officer = cur.fetchone()
c.close()
print(f"precheck: {cu} {db} active_users={active} officer_rows={officer}")
if cu != "complaint_migrator_v2_dev@localhost" or db != TARGET or active != 0 or officer != 0:
    sys.exit("HALT: precondition failed (wrong account/db, or sandbox not in the post-migration state)")

tmp = tempfile.mkdtemp(prefix="cc_s2e_")
try:
    opt = os.path.join(tmp, "c.cnf")
    with os.fdopen(os.open(opt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as fh:
        fh.write(f"[client]\nuser={env['DB_MIGRATOR_USER']}\npassword=\"{env['DB_MIGRATOR_PASSWORD']}\"\n"
                 f"host={env['DB_HOST']}\nport={env.get('DB_PORT', '3306')}\n")
    with open(S2E_SQL, "rb") as fh:
        r = subprocess.run([MYSQL, f"--defaults-extra-file={opt}", "--skip-reconnect", "--force", "--table",
                            "--show-warnings", "--default-character-set=utf8mb4", f"--database={TARGET}"],
                           stdin=fh, capture_output=True, timeout=600)
finally:
    shutil.rmtree(tmp, ignore_errors=True)


def red(t):
    for s in secrets:
        t = t.replace(s, "***REDACTED***")
    return t


out, err = red(r.stdout.decode("utf-8", "replace")), red(r.stderr.decode("utf-8", "replace"))
errors = [(int(m.group(1)), m.group(2)) for m in re.finditer(r"ERROR (\d+) \([0-9A-Z]+\) at line (\d+)", err)]
passes = re.findall(r"\|\s*PASS ([EF]\d+[a-z]?)\b", out)
fails_rows = re.findall(r"\|\s*(FAIL [^|]*)\|", out)
problems = []
if r.returncode not in (0, 1):
    problems.append(f"client exit code {r.returncode}")
if any(code in FATAL for code, _ in errors):
    problems.append("connection / deadlock / timeout error")
if fails_rows:
    problems.append(f"FAIL rows: {fails_rows}")
if passes != EXPECTED_PASS:
    problems.append(f"PASS rows {passes} != expected {EXPECTED_PASS}")
if len(errors) != EXPECTED_ERRORS or any(code != 1644 for code, _ in errors):
    problems.append(f"expected {EXPECTED_ERRORS} x ERROR 1644, got {[e[0] for e in errors]}")
if "PASS fixture selection" not in out:
    problems.append("fixture selection did not pass")
if "S2_E END" not in out:
    problems.append("S2_E END marker missing")
result = "PASS" if not problems else "FAIL"
log = ROOT / "stage2_logs" / f"phase6_S2E_{datetime.datetime.now():%Y%m%d_%H%M%S}.log"
with open(log, "x", encoding="utf-8") as fh:
    fh.write(f"account={cu} db={db} exit={r.returncode}\n--- STDOUT ---\n{out}\n--- STDERR ---\n{err}\n"
             f"--- SUMMARY ---\nPASS rows ({len(passes)}): {passes}\nerrors ({len(errors)}): {errors}\n"
             f"problems: {problems}\nS2_E RESULT: {result}\n")
print(f"client exit={r.returncode}\nPASS rows ({len(passes)}/18): {passes}\nexpected errors ({len(errors)}/16): "
      f"{[f'{c}@line{l}' for c, l in errors]}\nproblems: {problems or 'none'}\nS2_E RESULT: {result}\n[log {log}]")
for line in out.splitlines():
    if "complaints_now_expect" in line or ("|" in line and re.search(r"\|\s+\d+\s+\|\s+\d+\s+\|\s+\d+\s+\|", line)):
        print(line)
sys.exit(0 if result == "PASS" else 2)
