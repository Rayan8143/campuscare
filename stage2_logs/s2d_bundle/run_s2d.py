"""
S2_D corrected-run harness, revision 2 (complaint_migrator_v2_dev -> college_complaints_v2_dev ONLY).

PREPARED, NOT EXECUTED. Run only after explicit approval:
    python -I -B stage2_logs\\s2d_bundle\\run_s2d.py --confirm-target college_complaints_v2_dev

Phases (any failure before phase 5 aborts WITHOUT launching the mysql client):
  1. Integrity: canonical S2_D and the run copy must match their pinned SHA-256.
  2. Environment: DB_NAME / DB_HOST / DB_MIGRATOR_USER must be the dev sandbox migrator.
  3. Read-only preflight (mysql.connector, autocommit session, no writes):
       a. CURRENT_USER() / DATABASE(); protected schema invisible.
       b. SHOW GRANTS: runner allowlist passes; no SET_USER_ID; no DELETE (needed for P1).
       c. ENGINE = InnoDB for complaints, complaint_assignments, primary_officer_assignment,
          staff_workflow_assignments, users, account_activations, complaint_history
          (missing or unverifiable => abort).
       d. Fixture validity (same selection queries as the run copy) - see FIXTURE_CHECKS.
       e. SET SESSION autocommit = 0 takes effect.
  4. Pre-test snapshot: all 22 tables (COUNT + CHECKSUM TABLE), routines/triggers/views/ledger,
     AUTO_INCREMENT of complaints, complaint_assignments, staff_workflow_assignments,
     account_activations (information_schema_stats_expiry = 0).
  5. mysql client: --skip-reconnect --force --table --show-warnings; credentials via a temp
     option file; 300 s timeout (on timeout the client process is killed => FAIL).
  6. Server-side session settlement (always, before the final snapshot). NO KILL is ever issued.
       Only the exact CONNECTION_ID emitted in S2D_PRECHECK is monitored:
         - id not captured            => FAIL "SESSION_ID_NOT_CAPTURED" (no guessing);
         - id still in PROCESSLIST after 120 s => FAIL "SESSION_TERMINATION_UNCONFIRMED";
         - then SELECT ... FOR UPDATE NOWAIT on the probe rows (read-only, rolled back) must
           succeed within 120 s, else FAIL "SESSION_TERMINATION_UNCONFIRMED".
       On any of these failures the harness stops: no final snapshot is taken, no rollback success
       and no PASS is declared, and MANUAL ADMINISTRATOR VERIFICATION is required.
  7. Output analysis: FAIL on client exit code not in {0,1}; lost connection / reconnect /
     deadlock / lock-wait / timeout codes (2006, 2013, 2055, 1213, 1205, 3572, 3024); any
     Warning line; missing S2D_PRECHECK / S2D_FIXTURE_CHECKS / S2D_COUNTS_BEFORE /
     S2D_ROLLBACK_DONE / S2D_COUNTS_AFTER / S2D_END; gate != 1, autocommit != 0, fixture
     check row not as expected; ordered error codes not exactly matching EXPECTED; in-session
     counts changed.
  8. Post-test snapshot comparison: row counts / checksums / objects / ledger must be identical;
     AUTO_INCREMENT increases are reported as TEST RESIDUE.
  PASS requires phases 1-8 ALL clean. Matching checksums alone never yield PASS.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = Path(__file__).resolve().parent
CANONICAL = ROOT / "migrations" / "admin" / "S2_D_integrity_tests_rolled_back.sql"
RUN_COPY = BUNDLE / "S2_D_run_copy.sql"
CANONICAL_SHA256 = "c3d82dd23f39f54b8139c38893c5645651f54a3cc9074dfdd5231fd8320bfac2"
RUN_COPY_SHA256 = "7a3c1f0fc9845c096961f0029e1b141b6fb4fea5ebdddba426f51a5cc0fae845"
MYSQL = r"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"
TARGET = "college_complaints_v2_dev"
PROTECTED = "college_complaints"
MIGRATOR = "complaint_migrator_v2_dev"
AI_TABLES = ("complaints", "complaint_assignments", "staff_workflow_assignments", "account_activations")
INNODB_TABLES = ("complaints", "complaint_assignments", "primary_officer_assignment",
                 "staff_workflow_assignments", "users", "account_activations", "complaint_history")
CLIENT_TIMEOUT_S = 300
SETTLE_TIMEOUT_S = 120

EXPECTED = [
    ("P1", {1142}), ("P2", {1044, 1142}),
    ("D01", {1644}), ("D02", {1644}), ("D03", {1644}), ("D04", {1644}), ("D05", {1644}),
    ("D06", {1062}), ("D07", {3819}), ("D08", {1644}), ("D09", {1644, 1048}), ("D10", {1644}),
    ("D11", {3819}), ("D12", {3819}), ("D13", {3819}), ("D14", {3819}),
]
FATAL_CODES = {2006, 2013, 2055, 1213, 1205, 3572, 3024}
# S2D_FIXTURE_CHECKS: cid, assigned, staff, student, other_user, d13_user, dept, level4, officer2_rows, swa_l4_rows
EXPECTED_FIXTURE_CHECKS = ["1", "1", "1", "1", "1", "1", "1", "1", "0", "0"]

FIXTURE_SELECT = {
    "probe_cid": ("SELECT MIN(complaint_id) FROM complaints WHERE status = 'Submitted' AND is_deleted = FALSE "
                  "AND current_level_id = 1", ()),
    "probe_assigned": ("SELECT MIN(c.complaint_id) FROM complaints c JOIN complaint_assignments ca "
                       "ON ca.active_complaint_id = c.complaint_id AND ca.assigned_staff_id = c.assigned_staff_id "
                       "WHERE c.assigned_staff_id IS NOT NULL", ()),
    "probe_staff": ("SELECT MIN(staff_id) FROM staff", ()),
    "probe_user": ("SELECT MIN(user_id) FROM users WHERE is_active = FALSE AND password_hash IS NULL", ()),
    "probe_student": ("SELECT MIN(student_id) FROM students WHERE user_id IS NOT NULL", ()),
    "probe_dept": ("SELECT MIN(department_id) FROM departments", ()),
}


class Fail(RuntimeError):
    pass


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def load_env():
    env = {}
    for raw in (ROOT / ".env.development").read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            env[k.strip()] = v
    return env


def connect(env, autocommit=True):
    import mysql.connector
    return mysql.connector.connect(host=env["DB_HOST"], port=int(env.get("DB_PORT", "3306")),
                                   user=env["DB_MIGRATOR_USER"], password=env["DB_MIGRATOR_PASSWORD"],
                                   database=TARGET, charset="utf8mb4", collation="utf8mb4_unicode_ci",
                                   autocommit=autocommit)


def q(cur, sql, params=()):
    cur.execute(sql, params)
    return cur.fetchall()


def q1(cur, sql, params=()):
    rows = q(cur, sql, params)
    return rows[0][0] if rows else None


# ------------------------------------------------------------------ phase 3: read-only preflight
def preflight(env, log):
    spec = importlib.util.spec_from_file_location("runner", ROOT / "migrations" / "run_migrations.py")
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    c = connect(env)
    cur = c.cursor()
    try:
        cu, db = q(cur, "SELECT CURRENT_USER(), DATABASE()")[0]
        log(f"[3a] CURRENT_USER()={cu} DATABASE()={db}")
        if cu != f"{MIGRATOR}@localhost" or db != TARGET:
            raise Fail("wrong account or database")
        if q1(cur, "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = %s", (PROTECTED,)):
            raise Fail("protected schema is visible to the migrator")

        grants = [g for (g,) in q(cur, "SHOW GRANTS FOR CURRENT_USER()")]
        for g in grants:
            log(f"[3b] grant: {g}")
        holds_set_user_id, problems = runner.review_migrator_grants(grants)
        if problems or holds_set_user_id:
            raise Fail(f"migrator grants not in the post-Stage-2 state: {problems or 'SET_USER_ID still held'}")
        if any(re.search(r"\bDELETE\b", g.split(" ON ")[0]) for g in grants):
            raise Fail("migrator holds DELETE: P1 cannot be presented as an expected denial")

        engines = dict(q(cur, "SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = %s "
                              "AND TABLE_NAME IN (" + ",".join(["%s"] * len(INNODB_TABLES)) + ")",
                         (TARGET, *INNODB_TABLES)))
        for t in INNODB_TABLES:
            log(f"[3c] engine {t:28} {engines.get(t)}")
        bad = [t for t in INNODB_TABLES if (engines.get(t) or "").upper() != "INNODB"]
        if bad:
            raise Fail(f"engine not InnoDB or not verifiable for: {bad}")

        fx = {k: q1(cur, s, p) for k, (s, p) in FIXTURE_SELECT.items()}
        fx["probe_student_user"] = q1(cur, "SELECT user_id FROM students WHERE student_id = %s", (fx["probe_student"],))
        fx["probe_other_user"] = q1(cur, "SELECT MAX(user_id) FROM users WHERE user_id <> %s", (fx["probe_student_user"],))
        log(f"[3d] fixtures: {fx}")
        checks = {
            "complaint exists, Submitted, not archived, Level 1": q1(cur,
                "SELECT COUNT(*) FROM complaints WHERE complaint_id = %s AND status = 'Submitted' "
                "AND is_deleted = FALSE AND current_level_id = 1", (fx["probe_cid"],)) == 1,
            "assigned complaint matches its active ledger row": q1(cur,
                "SELECT COUNT(*) FROM complaints c JOIN complaint_assignments ca ON ca.active_complaint_id = c.complaint_id "
                "AND ca.assigned_staff_id = c.assigned_staff_id WHERE c.complaint_id = %s", (fx["probe_assigned"],)) == 1,
            "staff fixture exists": q1(cur, "SELECT COUNT(*) FROM staff WHERE staff_id = %s", (fx["probe_staff"],)) == 1,
            "student and complainant user correspond": q1(cur,
                "SELECT COUNT(*) FROM students s JOIN users u ON u.user_id = s.user_id "
                "WHERE s.student_id = %s AND s.user_id = %s", (fx["probe_student"], fx["probe_student_user"])) == 1,
            "alternate complainant valid and distinct": fx["probe_other_user"] is not None
                and fx["probe_other_user"] != fx["probe_student_user"]
                and q1(cur, "SELECT COUNT(*) FROM users WHERE user_id = %s", (fx["probe_other_user"],)) == 1,
            "D13 user inactive with NULL password_hash": q1(cur,
                "SELECT COUNT(*) FROM users WHERE user_id = %s AND is_active = FALSE AND password_hash IS NULL",
                (fx["probe_user"],)) == 1,
            "department fixture exists": q1(cur, "SELECT COUNT(*) FROM departments WHERE department_id = %s", (fx["probe_dept"],)) == 1,
            "workflow level 4 exists (D12 FK)": q1(cur, "SELECT COUNT(*) FROM workflow_levels WHERE level_id = 4") == 1,
            "no singleton_id 2 row (D11)": q1(cur, "SELECT COUNT(*) FROM primary_officer_assignment WHERE singleton_id = 2") == 0,
            "no Level 4 membership for D12 tuple": q1(cur,
                "SELECT COUNT(*) FROM staff_workflow_assignments WHERE user_id = %s AND department_id = %s AND level_id = 4",
                (fx["probe_user"], fx["probe_dept"])) == 0,
            "D06 target has exactly one active assignment": q1(cur,
                "SELECT COUNT(*) FROM complaint_assignments WHERE complaint_id = %s AND is_active = TRUE",
                (fx["probe_assigned"],)) == 1,
        }
        for name, ok in checks.items():
            log(f"[3d] {'OK  ' if ok else 'FAIL'} {name}")
        if not all(checks.values()) or any(v is None for v in fx.values()):
            raise Fail("fixture preflight failed")

        c.autocommit = False
        q(cur, "SET SESSION autocommit = 0")
        if q1(cur, "SELECT @@SESSION.autocommit") != 0:
            raise Fail("SET SESSION autocommit = 0 did not take effect")
        c.rollback()
        log("[3e] SET SESSION autocommit = 0 verified")
        return fx
    finally:
        cur.close()
        c.close()


# ------------------------------------------------------------------ phase 4/8: snapshots
def snapshot(env):
    c = connect(env)
    cur = c.cursor()
    try:
        assert q1(cur, "SELECT DATABASE()") == TARGET
        q(cur, "SET SESSION information_schema_stats_expiry = 0")
        tables = [t for (t,) in q(cur, "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() "
                                       "AND TABLE_TYPE = 'BASE TABLE' ORDER BY 1")]
        snap = {"tables": {}, "auto_increment": {},
                "routines": q(cur, "SELECT ROUTINE_NAME, DEFINER, SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = DATABASE() ORDER BY 1"),
                "triggers": q(cur, "SELECT TRIGGER_NAME, DEFINER FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = DATABASE() ORDER BY 1"),
                "views": q(cur, "SELECT TABLE_NAME, SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA = DATABASE() ORDER BY 1"),
                "ledger": q(cur, "SELECT version, status, checksum_sha256 FROM schema_migrations ORDER BY 1")}
        for t in tables:
            snap["tables"][t] = [q1(cur, f"SELECT COUNT(*) FROM `{t}`"), q(cur, f"CHECKSUM TABLE `{t}`")[0][1]]
        for t in AI_TABLES:
            snap["auto_increment"][t] = q1(cur, "SELECT AUTO_INCREMENT FROM information_schema.TABLES "
                                                "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s", (t,))
        return json.loads(json.dumps(snap, default=str))
    finally:
        cur.close()
        c.close()


# ------------------------------------------------------------------ phase 5: client
def run_client(env, log):
    tmp = tempfile.mkdtemp(prefix="cc_s2d_")
    try:
        opt = os.path.join(tmp, "client.cnf")
        pw = env["DB_MIGRATOR_PASSWORD"]
        if any(ch in pw for ch in "\r\n") or ('"' in pw and "'" in pw):
            raise Fail("password cannot be written to an option file")
        qch = "'" if '"' in pw else '"'
        with os.fdopen(os.open(opt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as fh:
            fh.write(f"[client]\nuser={env['DB_MIGRATOR_USER']}\npassword={qch}{pw.replace(chr(92), chr(92) * 2)}{qch}\n"
                     f"host={env['DB_HOST']}\nport={env.get('DB_PORT', '3306')}\n")
        cmd = [MYSQL, f"--defaults-extra-file={opt}", "--skip-reconnect", "--force", "--table",
               "--show-warnings", "--default-character-set=utf8mb4", f"--database={TARGET}"]
        log("[5] mysql.exe --defaults-extra-file=<temp> --skip-reconnect --force --table --show-warnings "
            f"--default-character-set=utf8mb4 --database={TARGET} < {RUN_COPY.name}")
        with open(RUN_COPY, "rb") as fh:
            proc = subprocess.Popen(cmd, stdin=fh, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            timed_out = False
            try:
                out, err = proc.communicate(timeout=CLIENT_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                timed_out = True
                proc.kill()
                out, err = proc.communicate()
        return proc.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace"), timed_out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def table_row(out, marker):
    for line in out.splitlines():
        if line.startswith("|") and marker in line:
            return [c.strip() for c in line.strip().strip("|").split("|")]
    return None


# ------------------------------------------------------------------ phase 6: settlement
MANUAL_VERIFICATION_NOTE = (
    "MANUAL ADMINISTRATOR VERIFICATION REQUIRED: no final snapshot is taken or treated as proof of "
    "rollback. An administrator must confirm (e.g. SHOW PROCESSLIST / information_schema.INNODB_TRX) "
    "that the test session has ended and no transaction remains before any further step.")


def settle(env, client_conn_id, fx, log):
    """Prove the client's server session (exact CONNECTION_ID only) has ended and no lock remains.

    Never kills any session and never guesses which session belongs to the test.
    """
    if client_conn_id is None:
        raise Fail("SESSION_ID_NOT_CAPTURED: the run copy's CONNECTION_ID() was not captured; "
                   "the harness will not guess which server session belongs to the test. " + MANUAL_VERIFICATION_NOTE)
    c = connect(env)
    cur = c.cursor()
    try:
        def present():
            return q1(cur, "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID = %s", (client_conn_id,)) > 0

        deadline = time.time() + SETTLE_TIMEOUT_S
        still = present()
        while still and time.time() < deadline:
            time.sleep(1)
            still = present()
        if still:
            raise Fail(f"SESSION_TERMINATION_UNCONFIRMED: server connection {client_conn_id} still present after "
                       f"{SETTLE_TIMEOUT_S}s (no KILL issued). " + MANUAL_VERIFICATION_NOTE)
        log(f"[6] client server connection {client_conn_id} has left PROCESSLIST")

        # Locking-read proof that nothing still holds the probe rows (read-only; rolled back).
        c.autocommit = False
        deadline = time.time() + SETTLE_TIMEOUT_S
        while True:
            try:
                c.start_transaction()
                q(cur, "SELECT complaint_id FROM complaints WHERE complaint_id IN (%s, %s) FOR UPDATE NOWAIT",
                  (fx["probe_cid"], fx["probe_assigned"]))
                q(cur, "SELECT assignment_id FROM complaint_assignments WHERE active_complaint_id = %s FOR UPDATE NOWAIT",
                  (fx["probe_assigned"],))
                q(cur, "SELECT user_id FROM users WHERE user_id = %s FOR UPDATE NOWAIT", (fx["probe_user"],))
                c.rollback()
                break
            except Exception as e:  # noqa: BLE001 - 3572 = row locked by another transaction
                c.rollback()
                if time.time() >= deadline:
                    raise Fail(f"SESSION_TERMINATION_UNCONFIRMED: probe rows still locked after {SETTLE_TIMEOUT_S}s: {e}. "
                               + MANUAL_VERIFICATION_NOTE)
                time.sleep(1)
        log("[6] NOWAIT locking reads on probe rows succeeded: no transaction still holds them")
    finally:
        cur.close()
        c.close()


# ------------------------------------------------------------------ phase 7: analysis
def analyse(code, out, err, timed_out, log):
    fails = []
    if timed_out:
        fails.append(f"client exceeded {CLIENT_TIMEOUT_S}s and was killed")
    if code not in (0, 1):
        fails.append(f"unexpected client exit code {code}")
    errors = [(int(m.group(1)), m.group(2)) for m in re.finditer(r"ERROR (\d+) \([0-9A-Z]+\)(?: at line \d+)?: (.*)", err)]
    for c_, msg in errors:
        if c_ in FATAL_CODES:
            fails.append(f"hard failure: ERROR {c_}: {msg}")
    if re.search(r"Lost connection|server has gone away|Can't connect|reconnect|deadlock|Lock wait timeout", err, re.I):
        fails.append("connection loss / reconnect / deadlock / lock timeout reported by client")
    warnings = re.findall(r"^Warning \(Code \d+\).*$", out + "\n" + err, re.M)
    for w in warnings:
        fails.append(f"unexpected warning: {w}")
    for marker in ("S2D_PRECHECK", "S2D_FIXTURE_CHECKS", "S2D_COUNTS_BEFORE", "S2D_ROLLBACK_DONE",
                   "S2D_COUNTS_AFTER", "S2D_END"):
        if table_row(out, marker) is None:
            fails.append(f"missing output marker {marker}")
    pre = table_row(out, "S2D_PRECHECK")
    if pre:
        log(f"[7] in-session precheck: {pre}")
        if pre[1] != f"{MIGRATOR}@localhost" or pre[2] != TARGET or pre[3] != "0" or pre[4] != "1":
            fails.append(f"in-session gate failed: user={pre[1]} db={pre[2]} autocommit={pre[3]} gate={pre[4]}")
        if "NULL" in pre[6:]:
            fails.append("an in-session fixture is NULL")
    fc = table_row(out, "S2D_FIXTURE_CHECKS")
    if fc:
        log(f"[7] in-session fixture checks: {fc[1:]}")
        if fc[1:] != EXPECTED_FIXTURE_CHECKS:
            fails.append(f"in-session fixture checks {fc[1:]} != {EXPECTED_FIXTURE_CHECKS}")
    rb = table_row(out, "S2D_ROLLBACK_DONE")
    if rb and rb[1] != "0":
        fails.append(f"autocommit changed during run: {rb}")
    b, a = table_row(out, "S2D_COUNTS_BEFORE"), table_row(out, "S2D_COUNTS_AFTER")
    if b and a and b[1:] != a[1:]:
        fails.append(f"in-session counts changed: before={b[1:]} after={a[1:]}")
    log(f"[7] errors reported by client ({len(errors)}):")
    for i, (c_, msg) in enumerate(errors):
        log(f"     [{i + 1:02d}] ERROR {c_}: {msg}")
    if len(errors) != len(EXPECTED):
        fails.append(f"expected exactly {len(EXPECTED)} errors, client reported {len(errors)}")
    for i, (probe, codes) in enumerate(EXPECTED):
        actual = errors[i][0] if i < len(errors) else None
        verdict = "PASS" if actual in codes else "FAIL"
        log(f"     {probe:4} expected {sorted(codes)} actual {actual} -> {verdict}")
        if verdict == "FAIL":
            fails.append(f"{probe}: expected {sorted(codes)}, got {actual}")
    return fails


def compare(before, after, log):
    fails = []
    changed = [t for t in before["tables"] if before["tables"][t] != after["tables"].get(t)]
    if set(before["tables"]) != set(after["tables"]) or changed:
        fails.append(f"row count / CHECKSUM changed: {changed}")
    for k in ("routines", "triggers", "views", "ledger"):
        if before[k] != after[k]:
            fails.append(f"{k} changed")
    log(f"[8] snapshot: {len(after['tables'])} tables, changed={changed}; routines/triggers/views/ledger unchanged="
        f"{all(before[k] == after[k] for k in ('routines', 'triggers', 'views', 'ledger'))}")
    for t in AI_TABLES:
        b, a = before["auto_increment"][t], after["auto_increment"][t]
        note = "unchanged" if b == a else "advanced (TEST RESIDUE: counter gap, not row data)"
        log(f"[8] AUTO_INCREMENT {t:28} before={b} after={a} {note}")
    return fails


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--confirm-target", required=True)
    args = ap.parse_args()
    if args.confirm_target != TARGET:
        sys.exit(f"HALT: --confirm-target must be {TARGET}")

    lines = []
    env = load_env()
    secrets = [env[k] for k in ("DB_PASSWORD", "DB_MIGRATOR_PASSWORD", "FLASK_SECRET_KEY") if env.get(k)]

    def log(s=""):
        s = str(s)
        for x in secrets:
            s = s.replace(x, "***REDACTED***")
        lines.append(s)
        print(s, flush=True)

    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    logfile = ROOT / "stage2_logs" / f"phase5_S2D_{stamp}.log"
    result, fails, client_launched = "FAIL", [], False
    try:
        if sha(CANONICAL) != CANONICAL_SHA256:
            raise Fail("canonical S2_D checksum changed")
        if sha(RUN_COPY) != RUN_COPY_SHA256:
            raise Fail("run copy checksum does not match the reviewed version")
        if env.get("DB_NAME") != TARGET or env.get("DB_HOST") not in ("localhost", "127.0.0.1") \
                or env.get("DB_MIGRATOR_USER") != MIGRATOR:
            raise Fail("environment is not the dev sandbox migrator")
        log(f"[1-2] integrity + environment OK (canonical {CANONICAL_SHA256[:16]}..., run copy {RUN_COPY_SHA256[:16]}...)")
        fx = preflight(env, log)
        before = snapshot(env)
        (ROOT / "stage2_logs" / f"phase5_S2D_snapshot_before_{stamp}.json").write_text(json.dumps(before, indent=1), encoding="utf-8")

        client_launched = True
        code, out, err, timed_out = run_client(env, log)
        log(f"[5] client exit code: {code}; timed out: {timed_out}")
        log("--- client stdout ---")
        log(out)
        log("--- client stderr ---")
        log(err)
        pre = table_row(out, "S2D_PRECHECK")
        conn_id = int(pre[5]) if pre and pre[5].isdigit() else None
        log(f"[6] captured client CONNECTION_ID: {conn_id}")
        # Raises Fail (SESSION_ID_NOT_CAPTURED / SESSION_TERMINATION_UNCONFIRMED) if termination
        # cannot be proven; in that case no final snapshot, no rollback claim and no PASS follow.
        settle(env, conn_id, fx, log)
        fails += analyse(code, out, err, timed_out, log)

        after = snapshot(env)
        (ROOT / "stage2_logs" / f"phase5_S2D_snapshot_after_{stamp}.json").write_text(json.dumps(after, indent=1), encoding="utf-8")
        fails += compare(before, after, log)
        result = "PASS" if not fails else "FAIL"
        for f in fails:
            log(f"FAIL: {f}")
    except Fail as e:
        log(f"HARD FAIL{' (client was launched)' if client_launched else ' (client NOT launched)'}: {e}")
    except Exception as e:  # noqa: BLE001
        log(f"HARD FAIL (unexpected harness error{', client was launched' if client_launched else ''}): "
            f"{type(e).__name__}: {e}")
    log(f"S2_D RESULT: {result}")
    with open(logfile, "x", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    print(f"[log {logfile}]")
    sys.exit(0 if result == "PASS" else 2)


if __name__ == "__main__":
    main()
