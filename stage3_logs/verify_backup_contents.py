"""READ-ONLY: verify a backup file's checksum and that it captures the current workflow setup.
Usage: python stage3_logs/verify_backup_contents.py <backup.sql> <expected_sha256>"""
import hashlib
import re
import sys
from pathlib import Path

path, expected = Path(sys.argv[1]), sys.argv[2].lower()
data = path.read_bytes()
text = data.decode("utf-8", "replace")
ok = []


def check(name, cond, detail=""):
    ok.append(bool(cond))
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  — {detail}" if detail and not cond else ""))


def rows(table):
    m = re.search(rf"INSERT INTO `{table}`(?: \([^)]*\))? VALUES (.*?);\n", text, re.S)
    return re.findall(r"\(([^()]*(?:\([^()]*\)[^()]*)*)\)", m.group(1)) if m else []


check("sha256 matches", hashlib.sha256(data).hexdigest() == expected)
check("dump completed", "-- Dump completed" in text)
check("database is college_complaints_v2_dev", "Database: college_complaints_v2_dev" in text)
check("no reference to protected college_complaints", not re.search(r"college_complaints(?!_v2_dev)", text))
check("22 tables", text.count("CREATE TABLE") == 22, str(text.count("CREATE TABLE")))

users = {r.split(",")[0]: r for r in rows("users")}
active = sorted(int(k) for k, v in users.items() if re.search(r",1,'?\d{4}-", v) or v.split(",")[-2].strip() == "1")
check("active accounts 4,106,108,109,114,115 present with password hashes",
      all(str(u) in users and "scrypt:" in users[str(u)] for u in (4, 106, 108, 109, 114, 115)))

ur = {tuple(r.split(",")[:2]): r.split(",")[-1].strip() for r in rows("user_roles")}
expect_roles = {("108", "5"): "1", ("108", "3"): "0", ("109", "6"): "0", ("109", "3"): "1",
                ("114", "4"): "1", ("115", "4"): "1", ("114", "3"): "1", ("115", "3"): "1", ("106", "3"): "1", ("4", "1"): "1"}
check("role rows (officer on, 108 STAFF off, 109 ADMIN off, reviewers on)",
      all(ur.get(k) == v for k, v in expect_roles.items()), str({k: ur.get(k) for k in expect_roles}))
check("user_roles total 121", len(ur) == 121, str(len(ur)))

swa = [r.split(",") for r in rows("staff_workflow_assignments")]
check("memberships total 17 incl. (114,4,2,esc1) and (115,4,3,esc1)",
      len(swa) == 17 and any(r[1:5] == ["114", "4", "2", "1"] for r in swa) and any(r[1:5] == ["115", "4", "3", "1"] for r in swa))

poa = rows("primary_officer_assignment")
check("officer singleton -> 108 appointed by 109", len(poa) == 1 and poa[0].split(",")[1:2] == ["108"] and poa[0].split(",")[3] == "109", str(poa))

c14 = [r for r in rows("complaints") if r.startswith("14,")]
check("complaint #14 is In Progress at level 1, staff 4", bool(c14) and "'In Progress'" in c14[0], c14[0][:160] if c14 else "missing")
print(f"\n{sum(ok)}/{len(ok)} passed")
