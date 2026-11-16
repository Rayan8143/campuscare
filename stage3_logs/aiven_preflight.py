"""READ-ONLY preflight of the hosted Aiven MySQL as its admin user. Prints no secrets.
Needs .env.aiven (password) and aiven_ca.pem (Aiven console > service > Overview > CA certificate)."""
import os
import sys
from pathlib import Path

import mysql.connector

ROOT = Path(__file__).resolve().parent.parent
env = {}
for line in (ROOT / ".env.aiven").read_text(encoding="utf-8").splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.split("=", 1)
        env[k.strip()] = v.strip()
if not env.get("DB_ADMIN_PASSWORD"):
    sys.exit("STOP: DB_ADMIN_PASSWORD is empty in .env.aiven")
host = env["DB_ADMIN_HOST"]
if not host.endswith(".aivencloud.com"):
    sys.exit("STOP: not an Aiven host")
ca = ROOT / env.get("DB_ADMIN_CA_FILE", "aiven_ca.pem")
if not ca.exists():
    sys.exit("STOP: aiven_ca.pem not found in the project folder")

c = mysql.connector.connect(host=host, port=int(env["DB_ADMIN_PORT"]), user=env["DB_ADMIN_USER"],
                            password=env["DB_ADMIN_PASSWORD"], ssl_ca=str(ca), ssl_verify_cert=True,
                            ssl_verify_identity=True, connection_timeout=15)
cur = c.cursor()


def q(sql):
    cur.execute(sql)
    return cur.fetchall()


print("TLS verified connection OK")
print("version:", q("SELECT VERSION()")[0][0], "| user:", q("SELECT CURRENT_USER()")[0][0])
print("databases:", [r[0] for r in q("SHOW DATABASES")])
print("sql_mode:", q("SELECT @@sql_mode")[0][0])
print("sql_require_primary_key:", q("SELECT @@sql_require_primary_key")[0][0], "| lower_case_table_names:", q("SELECT @@lower_case_table_names")[0][0],
      "| log_bin_trust_function_creators:", q("SELECT @@log_bin_trust_function_creators")[0][0])
print("-- grants of the admin user:")
for (g,) in q("SHOW GRANTS FOR CURRENT_USER()"):
    print("  ", g[:230])
try:
    print("existing accounts (name@host only):", [f"{u}@{h}" for u, h in q("SELECT user, host FROM mysql.user")])
except mysql.connector.Error as e:
    print("existing accounts: not readable by this user (errno", e.errno, ")")
c.close()
