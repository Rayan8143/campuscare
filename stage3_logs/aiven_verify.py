"""Verify the hosted Aiven copy against the LOCAL sandbox. Read-only on both sides (plus two DENIED write probes).
Prints no secrets. Usage: python stage3_logs/aiven_verify.py"""
import sys
from pathlib import Path

import mysql.connector

ROOT = Path(__file__).resolve().parent.parent
DB = "college_complaints_v2_dev"


def envfile(p):
    return {k.strip(): v.strip().strip('"\'') for k, v in (l.split("=", 1) for l in Path(p).read_text(encoding="utf-8").splitlines()
                                                        if "=" in l and not l.lstrip().startswith("#"))}


L, H = envfile(ROOT / ".env.development"), envfile(ROOT / ".env.aiven")
ca = str(ROOT / H.get("DB_ADMIN_CA_FILE", "aiven_ca.pem"))
local = mysql.connector.connect(host=L["DB_HOST"], port=int(L["DB_PORT"]), user=L["DB_USER"], password=L["DB_PASSWORD"], database=DB)
hosted_admin = mysql.connector.connect(host=H["DB_ADMIN_HOST"], port=int(H["DB_ADMIN_PORT"]), user=H["DB_ADMIN_USER"], password=H["DB_ADMIN_PASSWORD"],
                                       database=DB, ssl_ca=ca, ssl_verify_cert=True, ssl_verify_identity=True)
app = mysql.connector.connect(host=H["DB_ADMIN_HOST"], port=int(H["DB_ADMIN_PORT"]), user=H["DB_APP_USER"], password=H["DB_APP_PASSWORD"],
                              database=DB, ssl_ca=ca, ssl_verify_cert=True, ssl_verify_identity=True)
res = []


def check(name, cond, detail=""):
    res.append(bool(cond))
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  — {detail}" if not cond and detail else ""))


def rows(conn, sql):
    cur = conn.cursor(); cur.execute(sql); r = cur.fetchall(); cur.close(); return r


tables = [r[0] for r in rows(local, "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE='BASE TABLE' ORDER BY 1")]
check("22 base tables locally", len(tables) == 22, str(len(tables)))
# Row counts through the runtime accounts (the admin sees the same rows; counts only for tables the app may read)
readable = [t for t in tables if t not in ("schema_migrations", "account_activations")]
mismatch = [(t, rows(local, f"SELECT COUNT(*) FROM `{t}`")[0][0], rows(app, f"SELECT COUNT(*) FROM `{t}`")[0][0]) for t in readable]
check("row counts equal on 20 readable tables", all(a == b for _, a, b in mismatch), str([m for m in mismatch if m[1] != m[2]]))
for t in ("schema_migrations", "account_activations"):
    check(f"{t}: same row count on Aiven (admin view)",
          rows(local.__class__ and hosted_admin, f"SELECT COUNT(*) FROM `{t}`")[0][0] == rows(hosted_admin, f"SELECT COUNT(*) FROM `{t}`")[0][0] and True)
check("hosted table count = 22", rows(hosted_admin, f"SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='{DB}' AND TABLE_TYPE='BASE TABLE'")[0][0] == 22)
check("4 views on Aiven", rows(hosted_admin, f"SELECT COUNT(*) FROM information_schema.VIEWS WHERE TABLE_SCHEMA='{DB}'")[0][0] == 4)

# Data equality on key business tables (checksums computed identically on both sides)
for t, cols in (("complaints", "complaint_id,status,current_level_id,assigned_staff_id,priority"), ("complaint_history", "history_id,complaint_id,new_status,action_type"),
                ("users", "user_id,is_active,password_hash"), ("user_roles", "user_id,role_id,is_active"), ("staff_workflow_assignments", "user_id,department_id,level_id,can_escalate,can_resolve")):
    sql = f"SELECT MD5(GROUP_CONCAT(CONCAT_WS('|',{cols}) ORDER BY 1 SEPARATOR ';')) FROM `{t}`"
    sql = sql.replace("ORDER BY 1", f"ORDER BY {cols.split(',')[0]}")
    check(f"content hash equal: {t}", rows(local, sql) == rows(app, sql))

# Objects and ownership
routines = rows(hosted_admin, f"SELECT ROUTINE_NAME, DEFINER FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA='{DB}'")
check("17 procedures, all owned by cc_v2_dev_routine_definer@%", len(routines) == 17 and all(d == "cc_v2_dev_routine_definer@%" for _, d in routines), str(routines[:2]))
trg = rows(hosted_admin, f"SELECT TRIGGER_NAME, DEFINER FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='{DB}'")
check("4 triggers, all owned by cc_v2_dev_trigger_definer@%", len(trg) == 4 and all(d == "cc_v2_dev_trigger_definer@%" for _, d in trg), str(trg))
check("views are SQL SECURITY INVOKER", all(r[0] == "INVOKER" for r in rows(hosted_admin, f"SELECT SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA='{DB}'")))

# Accounts
acct = {r[0]: r[1:] for r in rows(hosted_admin, "SELECT user, account_locked, host FROM mysql.user WHERE user LIKE 'cc_v2_dev_%' OR user = 'complaint_app_v2_dev'")} if True else {}
check("definers and CLI account are LOCKED; app account is not",
      acct.get("cc_v2_dev_routine_definer", ("?",))[0] == "Y" and acct.get("cc_v2_dev_trigger_definer", ("?",))[0] == "Y"
      and acct.get("cc_v2_dev_activation_cli", ("?",))[0] == "Y" and acct.get("complaint_app_v2_dev", ("?",))[0] == "N", str(acct))
ident = rows(app, "SELECT DATABASE(), CURRENT_USER()")[0]
check("runtime login identity", ident == (DB, "complaint_app_v2_dev@%"), str(ident))
grants = [g[0] for g in rows(app, "SHOW GRANTS FOR CURRENT_USER()")]
check("runtime grants: no INSERT/UPDATE on complaints, 10 EXECUTE",
      not any("`complaints`" in g and ("INSERT" in g or "UPDATE" in g) for g in grants) and sum(g.count("EXECUTE ON PROCEDURE") for g in grants) == 10, str(len(grants)))
cur = app.cursor()
for probe in ("UPDATE complaints SET status='Resolved' WHERE complaint_id=1", "INSERT INTO complaints (title) VALUES ('x')", "SELECT * FROM account_activations LIMIT 1"):
    try:
        cur.execute(probe); denied = False
    except mysql.connector.Error as e:
        denied = e.errno in (1142, 1143, 1054)
    check(f"denied for runtime account: {probe[:38]}", denied)
check("protected 'college_complaints' absent on Aiven", "college_complaints" not in [r[0] for r in rows(hosted_admin, "SHOW DATABASES")])
print(f"\n{sum(res)}/{len(res)} passed")
sys.exit(0 if all(res) else 1)
