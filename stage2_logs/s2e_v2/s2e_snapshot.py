"""READ-ONLY snapshot of college_complaints_v2_dev as the migrator (no writes, no secrets printed).
Usage: python -I -B stage2_logs\\s2e\\s2e_snapshot.py <out.json>       (refuses to overwrite)"""
import json
import sys
from pathlib import Path

import mysql.connector

ROOT = Path(__file__).resolve().parents[2]
TARGET = "college_complaints_v2_dev"
AI_TABLES = ("complaints", "complaint_assignments", "staff_workflow_assignments", "account_activations")

env = {}
for raw in (ROOT / ".env.development").read_text(encoding="utf-8").splitlines():
    l = raw.strip()
    if l and not l.startswith("#") and "=" in l:
        k, v = l.split("=", 1)
        env[k.strip()] = v.strip().strip('"').strip("'")
if env.get("DB_NAME") != TARGET or env.get("DB_MIGRATOR_USER") != "complaint_migrator_v2_dev":
    sys.exit("HALT: not the dev sandbox migrator")
out = Path(sys.argv[1])
if out.exists():
    sys.exit("HALT: snapshot file exists")

c = mysql.connector.connect(host=env["DB_HOST"], port=int(env.get("DB_PORT", "3306")), user=env["DB_MIGRATOR_USER"],
                            password=env["DB_MIGRATOR_PASSWORD"], database=TARGET, autocommit=True)
cur = c.cursor()


def q(s, p=()):
    cur.execute(s, p)
    return cur.fetchall()


assert q("SELECT DATABASE()")[0][0] == TARGET
q("SET SESSION information_schema_stats_expiry = 0")
snap = {
    "tables": {},
    "auto_increment": {t: q("SELECT AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=%s", (t,))[0][0] for t in AI_TABLES},
    "routines": q("SELECT ROUTINE_NAME, DEFINER, SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=DATABASE() ORDER BY 1"),
    "triggers": q("SELECT TRIGGER_NAME, EVENT_MANIPULATION, ACTION_TIMING, DEFINER FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=DATABASE() ORDER BY 1"),
    "views": q("SELECT TABLE_NAME, DEFINER, SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA=DATABASE() ORDER BY 1"),
    "ledger": q("SELECT version, status, checksum_sha256 FROM schema_migrations ORDER BY 1"),
}
for (t,) in q("SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_TYPE='BASE TABLE' ORDER BY 1"):
    snap["tables"][t] = [q(f"SELECT COUNT(*) FROM `{t}`")[0][0], q(f"CHECKSUM TABLE `{t}`")[0][1]]
c.close()
with open(out, "x", encoding="utf-8") as fh:
    json.dump(snap, fh, indent=1, default=str)
print(f"snapshot {out.name}: {len(snap['tables'])} tables, {len(snap['routines'])} routines, "
      f"{len(snap['triggers'])} triggers, {len(snap['views'])} views, {len(snap['ledger'])} ledger rows, AI={snap['auto_increment']}")
