"""Apply GRANT_patch_definer_execute.sql ONCE as root (password prompted by the mysql client) and save
its output. Refuses to run if the patch checksum differs or a previous output file exists."""
import hashlib
import subprocess
import sys
from pathlib import Path

D = Path(__file__).resolve().parent
PATCH = D / "GRANT_patch_definer_execute.sql"
PATCH_SHA256 = "d6ad39bfe65a1d40637c624b236d7d7c3efea0104c42e3470c2bd26d9641deeb"
OUT = D / "grant_patch_output.txt"
MYSQL = r"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"

if hashlib.sha256(PATCH.read_bytes()).hexdigest() != PATCH_SHA256:
    sys.exit("STOP: grant patch checksum differs from the reviewed version")
if OUT.exists():
    sys.exit("STOP: grant patch output already exists - the patch must run only once")
print("Applying grant patch to college_complaints_v2_dev (enter the ROOT password)")
r = subprocess.run([MYSQL, "-u", "root", "-p", "--table", "--verbose", "--show-warnings",
                    "--database=college_complaints_v2_dev", "-e", f"source {PATCH.as_posix()}"],
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
text = r.stdout.decode("utf-8", "replace")
with open(OUT, "x", encoding="utf-8") as fh:
    fh.write(f"exit={r.returncode}\n{text}")
print(text)
print(f"exit={r.returncode}  output saved: {OUT.name}")
sys.exit(r.returncode)
