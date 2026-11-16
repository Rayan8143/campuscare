"""
CampusCare 2.0 - Stage 2 checkpointed migration runner (college_complaints_v2_dev ONLY).

Modes
  --plan       (default) list the ordered migrations and their SHA-256 checksums.
               No database connection is made.
  --preflight  connect as the migrator and run READ-ONLY checks: target identity, that the
               protected database is invisible to this account, ledger state, baseline
               counts or post-migration assertions, and the SET_USER_ID precondition for 008.
  --execute    apply pending migrations. Requires BOTH
                 --confirm-target college_complaints_v2_dev
                 --baseline-checkpoint <path to the admin-made pre-Stage-2 dump>
               Optional --through <version> stops after that version.

Safety properties
  * Hard target guard: database must be college_complaints_v2_dev, account must be
    complaint_migrator_v2_dev, host must be local; the protected database must not even be
    visible (INFORMATION_SCHEMA.SCHEMATA) to the account.
  * Credentials are read from .env.development and passed to mysql/mysqldump through a
    temporary option file (never on the command line, never printed, deleted afterwards).
  * Ledger-driven idempotency: SUCCESS versions are skipped after their checksum is
    verified; a checksum mismatch or a FAILED row halts (restore the checkpoint first).
    Only 008 (fully DROP IF EXISTS / CREATE OR REPLACE) may be retried after a failure.
  * Per-migration fingerprint assertions: objects a migration creates must be absent
    before it runs and present afterwards, so partial or out-of-band state is detected.
  * A new, uniquely named FORENSIC checkpoint (tables, data, triggers; no stored routines)
    is written before every migration; existing files are never overwritten. It is for
    investigation only. FULL RECOVERY always uses the admin baseline dump given with
    --baseline-checkpoint (drop + recreate the sandbox, restore, re-run from 000).
  * Migrator grants are checked against an exact allowlist: schema-wide ALL PRIVILEGES,
    DELETE, FILE, PROCESS, SUPER, SYSTEM_USER, GRANT OPTION, granted roles and any other
    schema are rejected; SET_USER_ID must be present before 008 and absent after S2_B.
  * 006 runs in-process on the runner's connection and its ledger row is written inside
    the same transaction as the backfill.

Claude Stage 2 review: complete rewrite of the original runner; see STAGE2_CLAUDE_REVIEW.md.
"""

import argparse
import datetime
import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
MIGRATIONS_DIR = REPO_ROOT / "migrations"
ENV_FILE = REPO_ROOT / ".env.development"
BACKUP_DIR = REPO_ROOT / "backups" / "stage2"

TARGET_DATABASE = "college_complaints_v2_dev"
PROTECTED_DATABASE = "college_complaints"
MIGRATOR_ACCOUNT = "complaint_migrator_v2_dev"
ALLOWED_HOSTS = {"localhost", "127.0.0.1", "::1"}
ROUTINE_DEFINER = "cc_v2_dev_routine_definer@localhost"
TRIGGER_DEFINER = "cc_v2_dev_trigger_definer@localhost"
RETRYABLE_AFTER_FAILURE = {"008"}

MIGRATION_SEQUENCE = [
    ("000", "000_schema_migrations.sql", "sql"),
    ("001", "001_core_rbac_schema.sql", "sql"),
    ("002", "002_rbac_initial_seeds.sql", "sql"),
    ("003", "003_workflow_and_singleton.sql", "sql"),
    ("004", "004_assignment_and_audit.sql", "sql"),
    ("005", "005_alter_existing_tables.sql", "sql"),
    ("006", "006_data_backfill_and_sync.py", "py"),
    ("007", "007_enforce_complainant_not_null.sql", "sql"),
    ("008", "008_triggers_and_procedures.sql", "sql"),
]

ORIGINAL_TABLES = ["academic_departments", "complaint_history", "complaints", "departments", "staff", "students"]
NEW_TABLES_BY_VERSION = {
    "000": ["schema_migrations"],
    "001": ["roles", "permissions", "role_permissions", "users", "user_roles", "account_activations", "external_complainants"],
    "003": ["workflow_levels", "staff_workflow_assignments", "primary_officer_assignment", "primary_officer_history"],
    "004": ["complaint_assignments", "complaint_escalations", "resolution_verifications", "notifications"],
}
NEW_TABLES = [t for v in sorted(NEW_TABLES_BY_VERSION) for t in NEW_TABLES_BY_VERSION[v]]
NEW_COLUMNS_005 = [
    ("students", "user_id"),
    ("staff", "user_id"), ("staff", "designation"), ("staff", "verification_status"),
    ("staff", "verified_by_user_id"), ("staff", "verified_at"), ("staff", "is_active"),
    ("complaints", "external_id"), ("complaints", "complainant_user_id"), ("complaints", "current_level_id"),
    ("complaints", "is_deleted"), ("complaints", "deleted_at"), ("complaints", "deleted_by_user_id"),
    ("complaint_history", "changed_by_user_id"), ("complaint_history", "action_type"),
]
VIEWS = ["complaint_details", "department_complaint_summary", "open_complaints", "pending_complaints"]
EXPECTED_ROUTINES = sorted([
    "cc_auth_department_authority", "cc_auth_has_permission", "cc_auth_is_assigned_staff",
    "cc_auth_is_primary_officer", "cc_auth_staff_eligible", "cc_token_issue_core",
    "escalate_complaint", "issue_account_token", "issue_account_token_operator", "reassign_complaint",
    "redeem_account_token", "request_escalation", "soft_delete_complaint", "submit_complaint",
    "transfer_primary_officer", "transition_complaint_status", "update_complaint_details",
])

# Exact privilege allowlist for the migrator (see migrations/admin/S2_A_pre_migration_accounts.sql).
MIGRATOR_SCHEMA_PRIVILEGES = {
    "SELECT", "INSERT", "UPDATE", "CREATE", "ALTER", "DROP", "INDEX", "REFERENCES",
    "CREATE VIEW", "SHOW VIEW", "TRIGGER", "CREATE ROUTINE", "ALTER ROUTINE", "EXECUTE",
}
MIGRATOR_ROUTINE_PRIVILEGES = {"EXECUTE", "ALTER ROUTINE"}   # automatic_sp_privileges only
EXPECTED_TRIGGERS = sorted([
    "trg_complaint_status_history", "trg_guard_complaint_sensitive_update",
    "trg_validate_complaint_identity_insert", "trg_validate_complaint_identity_update",
])

# Verified Stage 1 baseline. Never "fixed" by deleting data: a mismatch halts the run.
BASELINE = {
    "academic_departments": 10,
    "departments": 5,
    "staff": 15,
    "students": 102,
    "complaints": 202,
    "complaint_history": 155,
}
BASELINE_ASSIGNED = 200
BASELINE_UNASSIGNED = 2


class Halt(RuntimeError):
    """A safety assertion failed; nothing further may run."""


def log(msg=""):
    print(msg, flush=True)


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


# ------------------------------------------------------------------------------------
# Configuration and credentials
# ------------------------------------------------------------------------------------
def load_config():
    if not ENV_FILE.exists():
        raise Halt(f"{ENV_FILE.name} not found; the migrator credentials are required.")
    values = {}
    for raw in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value

    cfg = {
        "host": values.get("DB_HOST", "localhost"),
        "port": int(values.get("DB_PORT", "3306")),
        "user": values.get("DB_MIGRATOR_USER", ""),
        "password": values.get("DB_MIGRATOR_PASSWORD", ""),
        "database": values.get("DB_NAME", ""),
    }
    if cfg["database"] != TARGET_DATABASE:
        raise Halt(f"DB_NAME must be '{TARGET_DATABASE}'. Refusing to continue.")
    if cfg["user"] != MIGRATOR_ACCOUNT:
        raise Halt(f"DB_MIGRATOR_USER must be '{MIGRATOR_ACCOUNT}'. Refusing to continue.")
    if cfg["host"] not in ALLOWED_HOSTS:
        raise Halt("DB_HOST must be a local address for the development sandbox.")
    if not cfg["password"]:
        raise Halt("DB_MIGRATOR_PASSWORD is missing from the environment file.")
    return cfg


def mysql_bin(name):
    bin_dir = Path(os.environ.get("MYSQL_BIN_DIR", r"C:\Program Files\MySQL\MySQL Server 8.0\bin"))
    exe = bin_dir / (name + (".exe" if os.name == "nt" else ""))
    if not exe.exists():
        found = shutil.which(name)
        if not found:
            raise Halt(f"{name} client not found; set MYSQL_BIN_DIR.")
        return found
    return str(exe)


class OptionFile:
    """Temporary MySQL option file holding the credentials (keeps them off argv)."""

    def __init__(self, cfg):
        self.cfg = cfg
        self.dir = None
        self.path = None

    def __enter__(self):
        pw = self.cfg["password"]
        if any(c in pw for c in "\r\n") or ('"' in pw and "'" in pw):
            raise Halt("Migrator password contains characters that cannot be written to a MySQL option file.")
        quote = "'" if '"' in pw else '"'
        self.dir = tempfile.mkdtemp(prefix="cc_stage2_")
        self.path = os.path.join(self.dir, "client.cnf")
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write("[client]\n")
            fh.write(f"user={self.cfg['user']}\n")
            fh.write(f"password={quote}{pw.replace(chr(92), chr(92) * 2)}{quote}\n")
            fh.write(f"host={self.cfg['host']}\n")
            fh.write(f"port={self.cfg['port']}\n")
        return self.path

    def __exit__(self, *exc):
        if self.dir:
            shutil.rmtree(self.dir, ignore_errors=True)
        return False


def connect(cfg):
    import mysql.connector  # imported lazily so --plan works without the driver
    cnx = mysql.connector.connect(
        host=cfg["host"], port=cfg["port"], user=cfg["user"], password=cfg["password"],
        database=cfg["database"], autocommit=False, charset="utf8mb4", collation="utf8mb4_unicode_ci",
    )
    return cnx


def q1(cnx, sql, params=None):
    cur = cnx.cursor()
    try:
        cur.execute(sql, params or ())
        row = cur.fetchone()
        return row[0] if row else None
    finally:
        cur.close()


def qall(cnx, sql, params=None):
    cur = cnx.cursor()
    try:
        cur.execute(sql, params or ())
        return cur.fetchall()
    finally:
        cur.close()


def end_read(cnx):
    """Close the implicit read transaction so no snapshot leaks into later steps."""
    if cnx.in_transaction:
        cnx.rollback()


def expect(label, actual, expected):
    if actual != expected:
        raise Halt(f"ASSERTION FAILED - {label}: expected {expected!r}, found {actual!r}")
    log(f"  [OK] {label}: {actual}")


# ------------------------------------------------------------------------------------
# Introspection helpers (all read-only)
# ------------------------------------------------------------------------------------
def table_exists(cnx, name):
    return bool(q1(cnx, "SELECT COUNT(*) FROM information_schema.TABLES "
                        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s AND TABLE_TYPE = 'BASE TABLE'", (name,)))


def column_exists(cnx, table, column):
    return bool(q1(cnx, "SELECT COUNT(*) FROM information_schema.COLUMNS "
                        "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s AND COLUMN_NAME = %s", (table, column)))


def column_nullable(cnx, table, column):
    return q1(cnx, "SELECT IS_NULLABLE FROM information_schema.COLUMNS "
                   "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = %s AND COLUMN_NAME = %s", (table, column))


def fk_delete_rule(cnx, name):
    return q1(cnx, "SELECT DELETE_RULE FROM information_schema.REFERENTIAL_CONSTRAINTS "
                   "WHERE CONSTRAINT_SCHEMA = DATABASE() AND CONSTRAINT_NAME = %s", (name,))


def read_ledger(cnx):
    if not table_exists(cnx, "schema_migrations"):
        return {}
    rows = qall(cnx, "SELECT version, checksum_sha256, status FROM schema_migrations")
    return {v: {"checksum": c, "status": s} for v, c, s in rows}


def migrator_grants(cnx):
    return [r[0] for r in qall(cnx, "SHOW GRANTS FOR CURRENT_USER()")]


def review_migrator_grants(grant_lines):
    """Static allowlist review of SHOW GRANTS output. Returns (holds_set_user_id, problems)."""
    import re
    schema_obj = f"`{TARGET_DATABASE}`.*"
    holds_set_user_id = False
    problems = []
    for line in grant_lines:
        text = " ".join(line.split())
        if "WITH GRANT OPTION" in text.upper():
            problems.append(f"GRANT OPTION present: {text}")
        m = re.match(r"^GRANT (.+?) ON (?:(PROCEDURE|FUNCTION) )?(\S+) TO ", text, re.I)
        if not m:
            problems.append(f"unrecognised grant (e.g. a granted role): {text}")
            continue
        privs = {p.strip().upper() for p in m.group(1).split(",")}
        routine_kind, obj = m.group(2), m.group(3)
        if obj == "*.*":
            extra = privs - {"USAGE", "SET_USER_ID"}
            if extra:
                problems.append(f"global privileges not allowed: {sorted(extra)}")
            holds_set_user_id = holds_set_user_id or "SET_USER_ID" in privs
        elif obj == schema_obj and not routine_kind:
            if "ALL PRIVILEGES" in privs or "ALL" in privs:
                problems.append(f"ALL PRIVILEGES ON {schema_obj} must be revoked (run S2_A)")
            extra = privs - MIGRATOR_SCHEMA_PRIVILEGES - {"ALL PRIVILEGES", "ALL"}
            if extra:
                problems.append(f"schema privileges not allowed: {sorted(extra)}")
        elif routine_kind and obj.startswith(f"`{TARGET_DATABASE}`."):
            extra = privs - MIGRATOR_ROUTINE_PRIVILEGES
            if extra:
                problems.append(f"routine privileges not allowed on {obj}: {sorted(extra)}")
        else:
            problems.append(f"privileges outside the dev schema are not allowed: {text}")
    return holds_set_user_id, problems


# ------------------------------------------------------------------------------------
# Target identity and baseline checks
# ------------------------------------------------------------------------------------
def check_target_identity(cnx):
    log("[Preflight] Target identity")
    expect("DATABASE()", q1(cnx, "SELECT DATABASE()"), TARGET_DATABASE)
    current_user = q1(cnx, "SELECT CURRENT_USER()")
    if not str(current_user).startswith(MIGRATOR_ACCOUNT + "@"):
        raise Halt(f"Connected as an unexpected account ({current_user}).")
    log(f"  [OK] CURRENT_USER(): {current_user}")
    version = q1(cnx, "SELECT VERSION()")
    if not str(version).startswith("8.0."):
        raise Halt(f"Expected MySQL 8.0.x, found {version}.")
    log(f"  [OK] server version: {version}")
    expect("protected database visible to migrator",
           q1(cnx, "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = %s", (PROTECTED_DATABASE,)), 0)
    expect("target schema default collation",
           q1(cnx, "SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = %s",
              (TARGET_DATABASE,)), "utf8mb4_unicode_ci")
    _, problems = review_migrator_grants(migrator_grants(cnx))
    if problems:
        raise Halt("Migrator grants violate the Stage 2 allowlist:\n    " + "\n    ".join(problems))
    log("  [OK] migrator grants match the allowlist (explicit schema privileges, optional SET_USER_ID; "
        "no ALL, DELETE, FILE, PROCESS, SUPER, SYSTEM_USER, GRANT OPTION or other schemas)")
    end_read(cnx)


def check_baseline(cnx):
    log("[Preflight] Stage 1 baseline (nothing applied yet)")
    for table, expected in BASELINE.items():
        expect(f"{table} rows", q1(cnx, f"SELECT COUNT(*) FROM `{table}`"), expected)
    expect("assigned complaints", q1(cnx, "SELECT COUNT(*) FROM complaints WHERE assigned_staff_id IS NOT NULL"), BASELINE_ASSIGNED)
    expect("unassigned complaints", q1(cnx, "SELECT COUNT(*) FROM complaints WHERE assigned_staff_id IS NULL"), BASELINE_UNASSIGNED)
    expect("assignments to non-existent staff", q1(cnx, """
        SELECT COUNT(*) FROM complaints c LEFT JOIN staff s ON s.staff_id = c.assigned_staff_id
        WHERE c.assigned_staff_id IS NOT NULL AND s.staff_id IS NULL"""), 0)
    expect("legacy FK complaint_history_ibfk_1 delete rule", fk_delete_rule(cnx, "complaint_history_ibfk_1"), "CASCADE")
    expect("legacy trigger present", q1(cnx, "SELECT COUNT(*) FROM information_schema.TRIGGERS "
                                              "WHERE TRIGGER_SCHEMA = DATABASE() AND TRIGGER_NAME = 'trg_complaint_status_history'"), 1)
    present = [t for t in NEW_TABLES if table_exists(cnx, t)]
    expect("Stage 2 tables already present", present, [])
    end_read(cnx)


# ------------------------------------------------------------------------------------
# Per-migration fingerprints: (pre-condition, post-condition)
# ------------------------------------------------------------------------------------
def pre_check(cnx, ver):
    if ver in NEW_TABLES_BY_VERSION:
        present = [t for t in NEW_TABLES_BY_VERSION[ver] if table_exists(cnx, t)]
        if present:
            raise Halt(f"{ver}: tables already exist without a SUCCESS ledger row: {present}. Restore the checkpoint.")
    if ver == "002":
        expect("roles before 002", q1(cnx, "SELECT COUNT(*) FROM roles"), 0)
        expect("permissions before 002", q1(cnx, "SELECT COUNT(*) FROM permissions"), 0)
    if ver == "005":
        present = [f"{t}.{c}" for t, c in NEW_COLUMNS_005 if column_exists(cnx, t, c)]
        if present:
            raise Halt(f"005: partial/out-of-band state, columns already exist: {present}. Restore the checkpoint.")
        expect("complaint_history_ibfk_1 delete rule", fk_delete_rule(cnx, "complaint_history_ibfk_1"), "CASCADE")
        # chk_complaint_complainant_type references student_id / external_id. MySQL forbids a
        # CHECK on a column used by an FK referential action (CASCADE / SET NULL / SET DEFAULT).
        # The baseline dump defines complaints_ibfk_1 with no ON DELETE / ON UPDATE clause
        # (= NO ACTION); verify the LIVE rules too, before 005 runs.
        student_fk_rules = qall(cnx, """
            SELECT rc.CONSTRAINT_NAME, rc.DELETE_RULE, rc.UPDATE_RULE
              FROM information_schema.REFERENTIAL_CONSTRAINTS rc
              JOIN information_schema.KEY_COLUMN_USAGE k
                ON k.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA AND k.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
             WHERE rc.CONSTRAINT_SCHEMA = DATABASE() AND k.TABLE_NAME = 'complaints'
               AND k.COLUMN_NAME IN ('student_id', 'external_id')""")
        expect("FKs on complaints.student_id", [r[0] for r in student_fk_rules], ["complaints_ibfk_1"])
        incompatible = [r for r in student_fk_rules
                        if r[1] not in ("NO ACTION", "RESTRICT") or r[2] not in ("NO ACTION", "RESTRICT")]
        expect("student_id FK rules incompatible with the new CHECK", incompatible, [])
    if ver == "007":
        expect("complaints.complainant_user_id nullable before 007", column_nullable(cnx, "complaints", "complainant_user_id"), "YES")
    if ver == "008":
        holds, _ = review_migrator_grants(migrator_grants(cnx))
        if not holds:
            raise Halt("008 needs the temporary SET_USER_ID grant (migrations/admin/S2_A_pre_migration_accounts.sql).")
        log("  [OK] migrator holds temporary SET_USER_ID")
    end_read(cnx)


def post_check(cnx, ver):
    if ver in NEW_TABLES_BY_VERSION:
        missing = [t for t in NEW_TABLES_BY_VERSION[ver] if not table_exists(cnx, t)]
        if missing:
            raise Halt(f"{ver}: expected tables missing after run: {missing}")
        log(f"  [OK] {ver}: {len(NEW_TABLES_BY_VERSION[ver])} table(s) present")
    if ver == "002":
        expect("roles", q1(cnx, "SELECT COUNT(*) FROM roles"), 6)
        expect("permissions", q1(cnx, "SELECT COUNT(*) FROM permissions"), 27)
        expect("SYSTEM_ADMIN holds complaint:verify_resolution", q1(cnx, """
            SELECT COUNT(*) FROM role_permissions rp JOIN roles r ON r.role_id = rp.role_id
            JOIN permissions p ON p.permission_id = rp.permission_id
            WHERE r.role_name = 'SYSTEM_ADMIN' AND p.permission_key = 'complaint:verify_resolution'"""), 0)
    if ver == "003":
        expect("workflow_levels", q1(cnx, "SELECT COUNT(*) FROM workflow_levels"), 4)
        expect("primary_officer_assignment rows (empty until bootstrap)", q1(cnx, "SELECT COUNT(*) FROM primary_officer_assignment"), 0)
    if ver == "005":
        missing = [f"{t}.{c}" for t, c in NEW_COLUMNS_005 if not column_exists(cnx, t, c)]
        if missing:
            raise Halt(f"005: columns missing after run: {missing}")
        log(f"  [OK] 005: {len(NEW_COLUMNS_005)} new columns present")
        expect("complaint_history_ibfk_1 removed", fk_delete_rule(cnx, "complaint_history_ibfk_1"), None)
        expect("fk_complaint_history_complaint delete rule", fk_delete_rule(cnx, "fk_complaint_history_complaint"), "RESTRICT")
        expect("complaint_history.new_status length", q1(cnx, """
            SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'complaint_history' AND COLUMN_NAME = 'new_status'"""), 40)
        expect("complaint_history rows unchanged", q1(cnx, "SELECT COUNT(*) FROM complaint_history"), BASELINE["complaint_history"])
    if ver == "007":
        expect("complaints.complainant_user_id nullable", column_nullable(cnx, "complaints", "complainant_user_id"), "NO")
    if ver == "008":
        check_objects(cnx)
    end_read(cnx)


def check_objects(cnx):
    routines = qall(cnx, "SELECT ROUTINE_NAME, DEFINER, SECURITY_TYPE, ROUTINE_TYPE FROM information_schema.ROUTINES "
                         "WHERE ROUTINE_SCHEMA = DATABASE() ORDER BY ROUTINE_NAME")
    expect("routines", sorted(r[0] for r in routines), EXPECTED_ROUTINES)
    bad = [r[0] for r in routines if r[1] != ROUTINE_DEFINER or r[2] != "DEFINER" or r[3] != "PROCEDURE"]
    expect("routines not owned by the restricted definer", bad, [])
    triggers = qall(cnx, "SELECT TRIGGER_NAME, DEFINER FROM information_schema.TRIGGERS "
                         "WHERE TRIGGER_SCHEMA = DATABASE() ORDER BY TRIGGER_NAME")
    expect("triggers", sorted(t[0] for t in triggers), EXPECTED_TRIGGERS)
    expect("triggers not owned by the trigger definer", [t[0] for t in triggers if t[1] != TRIGGER_DEFINER], [])
    expect("status-history triggers on complaints", q1(cnx, """
        SELECT COUNT(*) FROM information_schema.TRIGGERS
        WHERE TRIGGER_SCHEMA = DATABASE() AND EVENT_OBJECT_TABLE = 'complaints'
          AND ACTION_TIMING = 'AFTER' AND EVENT_MANIPULATION = 'UPDATE'"""), 1)
    expect("legacy update_complaint_status present", q1(cnx, "SELECT COUNT(*) FROM information_schema.ROUTINES "
                                                            "WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_NAME = 'update_complaint_status'"), 0)
    views = qall(cnx, "SELECT TABLE_NAME, SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME")
    expect("views", sorted(v[0] for v in views), VIEWS)
    expect("views not SQL SECURITY INVOKER", [v[0] for v in views if v[1] != "INVOKER"], [])


def check_final_state(cnx):
    log("[Postflight] Full Stage 2 assertions")
    base_tables = sorted(r[0] for r in qall(cnx, "SELECT TABLE_NAME FROM information_schema.TABLES "
                                                 "WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'"))
    expect("base table count", len(base_tables), 22)
    expect("base tables", base_tables, sorted(ORIGINAL_TABLES + NEW_TABLES))
    for table, expected in BASELINE.items():
        expect(f"{table} rows preserved", q1(cnx, f"SELECT COUNT(*) FROM `{table}`"), expected)
    expect("users", q1(cnx, "SELECT COUNT(*) FROM users"), BASELINE["students"] + BASELINE["staff"])
    expect("active users (none until activation)", q1(cnx, "SELECT COUNT(*) FROM users WHERE is_active = TRUE"), 0)
    expect("unlinked students", q1(cnx, "SELECT COUNT(*) FROM students WHERE user_id IS NULL"), 0)
    expect("unlinked staff", q1(cnx, "SELECT COUNT(*) FROM staff WHERE user_id IS NULL"), 0)
    expect("complaints without complainant", q1(cnx, "SELECT COUNT(*) FROM complaints WHERE complainant_user_id IS NULL"), 0)
    expect("active assignments", q1(cnx, "SELECT COUNT(*) FROM complaint_assignments WHERE is_active = TRUE"), BASELINE_ASSIGNED)
    expect("unassigned complaints", q1(cnx, "SELECT COUNT(*) FROM complaints WHERE assigned_staff_id IS NULL"), BASELINE_UNASSIGNED)
    expect("legacy assignments with an actor", q1(cnx, "SELECT COUNT(*) FROM complaint_assignments "
                                                        "WHERE assignment_source = 'LEGACY_IMPORT' AND assigned_by_user_id IS NOT NULL"), 0)
    expect("cache/ledger mismatches", q1(cnx, """
        SELECT COUNT(*) FROM complaints c
        LEFT JOIN complaint_assignments ca ON ca.active_complaint_id = c.complaint_id
        WHERE NOT (c.assigned_staff_id <=> ca.assigned_staff_id)"""), 0)
    expect("legacy history rows without actor", q1(cnx, "SELECT COUNT(*) FROM complaint_history WHERE changed_by_user_id IS NULL"),
           BASELINE["complaint_history"])
    check_objects(cnx)
    end_read(cnx)


# ------------------------------------------------------------------------------------
# Execution
# ------------------------------------------------------------------------------------
def take_checkpoint(opt_file, ver):
    """FORENSIC per-migration checkpoint (tables, data, triggers; NO stored routines).

    It records the exact state before a migration for investigation. It is NOT a recovery
    image; full recovery always uses the admin baseline dump (--baseline-checkpoint).
    """
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    path = BACKUP_DIR / f"forensic_checkpoint_pre_{ver}_{stamp}.sql"
    if path.exists():
        raise Halt(f"Checkpoint {path.name} already exists; refusing to overwrite a backup.")
    cmd = [
        mysql_bin("mysqldump"), f"--defaults-extra-file={opt_file}",
        "--single-transaction", "--triggers", "--skip-routines", "--no-tablespaces",
        "--set-gtid-purged=OFF", "--default-character-set=utf8mb4", "--hex-blob",
        f"--result-file={path}", TARGET_DATABASE,
    ]
    res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if res.returncode != 0 or not path.exists() or path.stat().st_size == 0:
        raise Halt(f"Checkpoint before {ver} failed: {res.stderr.strip()}")
    log(f"  [OK] forensic checkpoint {path.relative_to(REPO_ROOT)} ({path.stat().st_size} bytes; not a recovery image)")
    return path


def run_sql_file(opt_file, script_path):
    cmd = [
        mysql_bin("mysql"), f"--defaults-extra-file={opt_file}",
        "--default-character-set=utf8mb4", "--batch", "--show-warnings",
        f"--database={TARGET_DATABASE}",
    ]
    with open(script_path, "rb") as fh:
        res = subprocess.run(cmd, stdin=fh, capture_output=True)
    out = res.stdout.decode("utf-8", errors="replace").strip()
    err = res.stderr.decode("utf-8", errors="replace").strip()
    if out:
        log("  mysql output:\n    " + out.replace("\n", "\n    "))
    if res.returncode != 0:
        raise RuntimeError(f"mysql client error: {err}")
    if err:
        log("  mysql stderr:\n    " + err.replace("\n", "\n    "))


def record(cnx, cur, ver, name, checksum, user, ms, status):
    cur.execute("""
        INSERT INTO schema_migrations (version, script_name, checksum_sha256, applied_by, execution_time_ms, status)
        VALUES (%s, %s, %s, %s, %s, %s)
        ON DUPLICATE KEY UPDATE script_name = VALUES(script_name), checksum_sha256 = VALUES(checksum_sha256),
                                applied_by = VALUES(applied_by), execution_time_ms = VALUES(execution_time_ms),
                                status = VALUES(status), applied_at = CURRENT_TIMESTAMP
    """, (ver, name, checksum, user, ms, status))


def load_006():
    spec = importlib.util.spec_from_file_location("migration_006", MIGRATIONS_DIR / "006_data_backfill_and_sync.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pending_migrations(cnx, through):
    ledger = read_ledger(cnx)
    end_read(cnx)
    pending = []
    for ver, name, kind in MIGRATION_SEQUENCE:
        path = MIGRATIONS_DIR / name
        checksum = sha256_file(path)
        entry = ledger.get(ver)
        if entry and entry["status"] == "SUCCESS":
            if entry["checksum"] != checksum:
                raise Halt(f"{name} changed after it was applied (checksum mismatch). Restore the checkpoint; never edit applied migrations.")
            continue
        if entry and entry["status"] == "FAILED" and ver not in RETRYABLE_AFTER_FAILURE:
            raise Halt(f"{name} is recorded as FAILED. Restore its checkpoint before retrying (STAGE2_EXECUTION_GUIDE.md).")
        if pending and pending[-1][0] >= ver:
            raise Halt("Migration sequence is not strictly ordered.")
        pending.append((ver, name, kind, path, checksum))
        if through and ver == through:
            break
    # Ordering guard: nothing may be pending before an applied version.
    applied = {v for v, e in ledger.items() if e["status"] == "SUCCESS"}
    for ver, *_ in pending:
        if any(a > ver for a in applied):
            raise Halt(f"Ledger gap: {ver} pending while a later version is applied.")
    return pending, ledger


def execute(cfg, args):
    checkpoint = Path(args.baseline_checkpoint)
    if not checkpoint.is_file() or checkpoint.stat().st_size == 0:
        raise Halt("--baseline-checkpoint must point to the non-empty admin-made pre-Stage-2 dump.")
    head = checkpoint.read_bytes()[:4096].decode("utf-8", errors="replace")
    if f"Database: {TARGET_DATABASE}" not in head:
        raise Halt("The baseline checkpoint header does not name college_complaints_v2_dev.")
    log(f"[OK] admin baseline checkpoint: {checkpoint.name} ({checkpoint.stat().st_size} bytes)")

    cnx = connect(cfg)
    try:
        check_target_identity(cnx)
        pending, ledger = pending_migrations(cnx, args.through)
        if not ledger:
            check_baseline(cnx)
        if not pending:
            log("Nothing to apply.")
        with OptionFile(cfg) as opt:
            for ver, name, kind, path, checksum in pending:
                log(f"\n=== [{ver}] {name} ({kind}) sha256={checksum[:16]}...")
                pre_check(cnx, ver)
                cp = take_checkpoint(opt, ver)
                started = time.time()
                try:
                    if kind == "sql":
                        run_sql_file(opt, path)
                        ms = int((time.time() - started) * 1000)
                        if ver != "000" or table_exists(cnx, "schema_migrations"):
                            end_read(cnx)
                            cur = cnx.cursor()
                            record(cnx, cur, ver, name, checksum, cfg["user"], ms, "SUCCESS")
                            cnx.commit()
                            cur.close()
                    else:
                        end_read(cnx)
                        module = load_006()

                        def ledger_in_txn(cur, _v=ver, _n=name, _c=checksum, _t=started):
                            record(cnx, cur, _v, _n, _c, cfg["user"], int((time.time() - _t) * 1000), "SUCCESS")

                        module.run_backfill(cnx, before_commit=ledger_in_txn)
                        ms = int((time.time() - started) * 1000)
                    post_check(cnx, ver)
                    log(f"  [OK] {name} applied in {ms} ms")
                except Exception as exc:
                    try:
                        cnx.rollback()
                    except Exception:
                        pass
                    log(f"\n[X] MIGRATION FAILED: {name}: {exc}")
                    try:
                        if table_exists(cnx, "schema_migrations"):
                            end_read(cnx)
                            cur = cnx.cursor()
                            record(cnx, cur, ver, name, checksum, cfg["user"], int((time.time() - started) * 1000), "FAILED")
                            cnx.commit()
                            cur.close()
                    except Exception:
                        log("  (could not record FAILED status in schema_migrations)")
                    log("\nSTOP. Do not retry (except 008, which is re-runnable after the cause is fixed).")
                    log("FULL RECOVERY uses the ADMIN BASELINE BACKUP passed via --baseline-checkpoint:")
                    log(f"  {checkpoint}")
                    log("  -> admin: drop + recreate college_complaints_v2_dev, restore that dump, re-run from 000")
                    log("     (STAGE2_EXECUTION_GUIDE.md, section 'Recovery').")
                    log("FORENSIC CHECKPOINT ONLY (not a recovery image: no stored routines):")
                    log(f"  {cp.relative_to(REPO_ROOT)}")
                    log("  -> use it to inspect the state immediately before this step; do not restore it as a full recovery.")
                    raise SystemExit(1)

        final = read_ledger(cnx)
        end_read(cnx)
        if all(final.get(v, {}).get("status") == "SUCCESS" for v, _, _ in MIGRATION_SEQUENCE):
            check_final_state(cnx)
            log("\nSTAGE 2 MIGRATIONS APPLIED AND VERIFIED. Next: migrations/admin/S2_B_post_migration_grants.sql")
        else:
            log("\nStopped before the end of the sequence (--through). Final assertions not yet run.")
    finally:
        cnx.close()


def preflight(cfg):
    cnx = connect(cfg)
    try:
        check_target_identity(cnx)
        pending, ledger = pending_migrations(cnx, None)
        log(f"[Preflight] ledger: {len(ledger)} row(s); pending: {[p[0] for p in pending] or 'none'}")
        if not ledger:
            check_baseline(cnx)
        elif not pending:
            check_final_state(cnx)
        holds, _ = review_migrator_grants(migrator_grants(cnx))
        end_read(cnx)
        if not pending and holds:
            raise Halt("All migrations are applied but the migrator still holds the temporary SET_USER_ID; "
                       "run migrations/admin/S2_B_post_migration_grants.sql.")
        log(f"[Preflight] SET_USER_ID held: {'yes' if holds else 'no'} "
            f"({'required before 008' if pending else 'correctly revoked after Stage 2'})")
        log("[Preflight] read-only checks complete; nothing was modified.")
    finally:
        cnx.close()


def plan():
    log(f"Target: {TARGET_DATABASE} (protected and never touched: {PROTECTED_DATABASE})")
    for ver, name, kind in MIGRATION_SEQUENCE:
        log(f"  {ver}  {kind:3}  {sha256_file(MIGRATIONS_DIR / name)}  {name}")
    log("No database connection was made.")


def main(argv=None):
    parser = argparse.ArgumentParser(description="CampusCare 2.0 Stage 2 migration runner (dev sandbox only)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--plan", action="store_true", help="list migrations and checksums (default, offline)")
    mode.add_argument("--preflight", action="store_true", help="read-only checks against the sandbox")
    mode.add_argument("--execute", action="store_true", help="apply pending migrations")
    parser.add_argument("--confirm-target", help=f"must equal {TARGET_DATABASE} with --execute")
    parser.add_argument("--baseline-checkpoint", help="path to the admin-made pre-Stage-2 dump (required with --execute)")
    parser.add_argument("--through", choices=[v for v, _, _ in MIGRATION_SEQUENCE], help="stop after this version")
    args = parser.parse_args(argv)

    try:
        if args.execute:
            if args.confirm_target != TARGET_DATABASE:
                raise Halt(f"--execute requires --confirm-target {TARGET_DATABASE}")
            if not args.baseline_checkpoint:
                raise Halt("--execute requires --baseline-checkpoint")
            execute(load_config(), args)
        elif args.preflight:
            preflight(load_config())
        else:
            plan()
    except Halt as exc:
        log(f"\nHALT: {exc}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
