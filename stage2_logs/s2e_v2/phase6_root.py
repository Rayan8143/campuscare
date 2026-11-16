"""
Phase 6 root driver. The MySQL client prompts for the root password at each step (typed by the
operator; never seen, stored or logged by this script). Targets ONLY college_complaints_v2_dev.

  python -I -B stage2_logs\\s2e\\phase6_root.py prep
      1. read-only root preflight + grant snapshot G0  (root_readonly_checks.sql)
      2. FULL ARCHIVE dump   (tables, data, triggers, routines, events)
      3. RESTORE IMAGE dump  (tables, data, triggers, views; --skip-routines)
  python -I -B stage2_logs\\s2e\\phase6_root.py restore <restore-image.sql> <expected-sha256>
      1. read-only root preflight (must pass, else ABORT before restoring)
      2. restore image into the EXISTING schema (no DROP DATABASE), --database=college_complaints_v2_dev
      3. read-only grant snapshot G1
  Any non-zero exit or failed check => STOP (no retry, no fallback).
"""
import datetime
import hashlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
S2E = Path(__file__).resolve().parent
BACKUPS = ROOT / "backups" / "stage2"
BIN = Path(r"C:\Program Files\MySQL\MySQL Server 8.0\bin")
TARGET = "college_complaints_v2_dev"
CHECKS = S2E / "root_readonly_checks.sql"
EXPECTED_DEFINERS = {"cc_v2_dev_trigger_definer@localhost", "complaint_migrator_v2_dev@localhost",
                     "cc_v2_dev_routine_definer@localhost"}


def stamp():
    return datetime.datetime.now().strftime("%Y%m%d_%H%M%S")


def new_file(path):
    if path.exists():
        sys.exit(f"STOP: {path} already exists; refusing to overwrite")
    return path


def run_checks(label):
    out = new_file(S2E / f"{label}_{stamp()}.txt")
    print(f"\n[{label}] read-only root checks -> {out.name}  (enter the ROOT password)")
    r = subprocess.run([str(BIN / "mysql.exe"), "-u", "root", "-p", "--table", f"--database={TARGET}",
                        "-e", f"source {CHECKS.as_posix()}"], stdout=subprocess.PIPE)
    text = r.stdout.decode("utf-8", "replace")
    out.write_text(text, encoding="utf-8")
    if r.returncode != 0:
        sys.exit(f"STOP: read-only checks failed (exit {r.returncode})")
    return text, out


# Privileges the restore needs at GLOBAL scope (ON *.*): DROP/CREATE tables, load data, rebuild
# indexes and FKs, recreate triggers and views, LOCK TABLES used by the dump, plus SET_USER_ID to
# recreate the original DEFINER attributes.
REQUIRED_GLOBAL = {"SELECT", "INSERT", "DROP", "CREATE", "ALTER", "INDEX", "REFERENCES", "TRIGGER",
                   "CREATE VIEW", "SHOW VIEW", "LOCK TABLES", "SET_USER_ID"}
STATIC_ALL = {"SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "RELOAD", "SHUTDOWN", "PROCESS", "FILE",
              "REFERENCES", "INDEX", "ALTER", "SHOW DATABASES", "SUPER", "CREATE TEMPORARY TABLES", "LOCK TABLES",
              "EXECUTE", "REPLICATION SLAVE", "REPLICATION CLIENT", "CREATE VIEW", "SHOW VIEW", "CREATE ROUTINE",
              "ALTER ROUTINE", "CREATE USER", "EVENT", "TRIGGER", "CREATE TABLESPACE", "CREATE ROLE", "DROP ROLE"}


def global_privileges(text):
    """Privileges granted ON *.* to CURRENT_USER, parsed from the R1 SHOW GRANTS rows only.

    Returns (set, error). Database-, table- and routine-scope grants are ignored on purpose.
    'ALL [PRIVILEGES]' expands to the static privileges only; dynamic privileges such as
    SET_USER_ID must be listed explicitly. Any parse problem => error (fail closed).
    """
    if "R1 CURRENT_USER" not in text or "R2 current user dynamic" not in text:
        return set(), "R1 section not found"
    section = text.split("R1 CURRENT_USER", 1)[1].split("R2 current user dynamic", 1)[0]
    cu = re.search(r"\|\s*R1 CURRENT_USER\s*\|\s*(\S+)\s*\|", text)
    if not cu or "@" not in cu.group(1):
        return set(), "CURRENT_USER() not found"
    user, host = cu.group(1).split("@", 1)
    grant_lines = re.findall(r"^\|\s*(GRANT .+?)\s*\|\s*$", section, re.M)
    if not grant_lines:
        return set(), "no SHOW GRANTS rows parsed"
    privs = set()
    for line in grant_lines:
        m = re.match(r"^GRANT (.+?) ON (\S+) TO `([^`]*)`@`([^`]*)`", line)
        if not m:
            if line.startswith("GRANT PROXY ON") or re.match(r"^GRANT `", line):
                continue                       # PROXY / role grants carry no object privileges
            return set(), f"unparseable grant row: {line[:80]}"
        plist, scope, g_user, g_host = m.groups()
        if (g_user, g_host) != (user, host):
            return set(), f"grant row for another account: {g_user}@{g_host}"
        if scope != "*.*":
            continue                           # database/table scope never counts
        for p in (x.strip().upper() for x in plist.split(",")):
            if p in ("ALL", "ALL PRIVILEGES"):
                privs |= STATIC_ALL
            elif p:
                privs.add(p)
    return privs, None


def assess_preflight(text):
    problems = []
    privs, err = global_privileges(text)
    if err:
        problems.append(f"cannot verify admin privileges (fail closed): {err}")
    else:
        missing = sorted(REQUIRED_GLOBAL - privs)
        if missing:
            problems.append(f"admin account lacks required GLOBAL privileges: {missing}")
    definer_sysuser = text.split("R4 SYSTEM_USER", 1)[-1].split("G1 SHOW GRANTS", 1)[0] if "R4 SYSTEM_USER" in text else None
    if definer_sysuser is None:
        problems.append("R4 section not found (fail closed)")
    elif re.search(r"\|\s*(cc_v2_dev_\w+|complaint_migrator_v2_dev)\s*\|", definer_sysuser) and "SYSTEM_USER" not in privs:
        problems.append("a DEFINER account holds SYSTEM_USER but the admin account does not")
    rows = re.findall(r"\|\s*(TRIGGER|VIEW|ROUTINE)\s*\|\s*(\w+)\s*\|\s*(\S+)\s*\|\s*(\d+)\s*\|", text)
    counts = {k: sum(1 for r in rows if r[0] == k) for k in ("TRIGGER", "VIEW", "ROUTINE")}
    if counts != {"TRIGGER": 4, "VIEW": 4, "ROUTINE": 17}:
        problems.append(f"unexpected object counts {counts}")
    for kind, name, definer, exists in rows:
        if definer not in EXPECTED_DEFINERS:
            problems.append(f"{kind} {name}: unexpected DEFINER {definer}")
        if exists != "1":
            problems.append(f"{kind} {name}: DEFINER {definer} does not exist")
    return problems, counts


def grant_part(text):
    """Grant section only, with line endings normalised (fixes the CRLF false mismatch of 2026-11-16)."""
    normalised = text.replace(chr(13), "")
    return normalised.split("G1 SHOW GRANTS", 1)[-1]


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def prep():
    text, g0 = run_checks("G0_root_preflight_and_grants")
    problems, counts = assess_preflight(text)
    print(f"[prep] preflight objects {counts}; problems: {problems or 'none'}")
    if problems:
        sys.exit("STOP: root preflight failed; nothing was dumped")
    BACKUPS.mkdir(parents=True, exist_ok=True)
    s = stamp()
    full = new_file(BACKUPS / f"admin_post_stage2_full_{s}.sql")
    image = new_file(BACKUPS / f"admin_post_stage2_restoreimage_{s}.sql")
    common = ["-u", "root", "-p", "--single-transaction", "--no-tablespaces", "--set-gtid-purged=OFF",
              "--default-character-set=utf8mb4", "--hex-blob"]
    print(f"\n[prep] FULL ARCHIVE -> {full.name}  (enter the ROOT password)")
    r = subprocess.run([str(BIN / "mysqldump.exe"), *common, "--routines", "--triggers", "--events",
                        f"--result-file={full}", TARGET])
    if r.returncode != 0:
        sys.exit(f"STOP: full archive dump failed (exit {r.returncode})")
    print(f"\n[prep] RESTORE IMAGE -> {image.name}  (enter the ROOT password)")
    r = subprocess.run([str(BIN / "mysqldump.exe"), *common, "--skip-routines", "--triggers", "--skip-events",
                        f"--result-file={image}", TARGET])
    if r.returncode != 0:
        sys.exit(f"STOP: restore image dump failed (exit {r.returncode})")
    for p in (full, image):
        print(f"[prep] {p.name}: {p.stat().st_size} bytes sha256={sha(p)}")
    print(f"[prep] grant snapshot G0: {g0.name}\n[prep] DONE - verify both dumps before S2_E")


def restore(image, expected_sha):
    image = Path(image)
    if not image.is_file() or sha(image) != expected_sha:
        sys.exit("STOP: restore image missing or checksum differs from the verified value")
    body = image.read_text(encoding="utf-8", errors="replace")
    checks = {
        "header names the dev schema": f"Database: {TARGET}" in body[:2000],
        "no USE statement": not re.search(r"^\s*USE\s", body, re.M | re.I),
        "no CREATE DATABASE": not re.search(r"CREATE\s+DATABASE", body, re.I),
        "no stored routines": not re.search(r"\b(PROCEDURE|FUNCTION)\s+`", body),
        "no reference to the protected schema": not re.search(r"`college_complaints`", body),
    }
    for name, ok in checks.items():
        print(f"[restore] image check {'OK  ' if ok else 'FAIL'} {name}")
    if not all(checks.values()):
        sys.exit("STOP: restore image failed its content checks; nothing was restored")
    text, pre = run_checks("R_pre_restore_root_preflight")
    problems, counts = assess_preflight(text)
    print(f"[restore] preflight objects {counts}; problems: {problems or 'none'}")
    if problems:
        sys.exit("STOP: root preflight failed; NOTHING was restored")
    print(f"\n[restore] restoring {image.name} into EXISTING {TARGET} (no DROP DATABASE)  (enter the ROOT password)")
    r = subprocess.run([str(BIN / "mysql.exe"), "-u", "root", "-p", "--default-character-set=utf8mb4",
                        f"--database={TARGET}", "-e", f"source {image.as_posix()}"])
    if r.returncode != 0:
        sys.exit(f"STOP: restore FAILED (exit {r.returncode}); do NOT retry or use the full archive without approval")
    text1, g1 = run_checks("G1_post_restore_grants")
    g0_files = sorted(S2E.glob("G0_root_preflight_and_grants_*.txt"))
    same = bool(g0_files) and grant_part(g0_files[-1].read_text(encoding="utf-8")) == grant_part(text1)
    print(f"[restore] restore completed; grant snapshot G1 {g1.name}; identical to G0: {same}")
    if not same:
        sys.exit("STOP: grants differ from G0 after restore")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "prep":
        prep()
    elif len(sys.argv) == 4 and sys.argv[1] == "restore":
        restore(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
