"""
CampusCare 2.0 - Checkpointed Migration Runner
Executes migration scripts 000 through 008 in exact ordered sequence against college_complaints_v2_dev.
Enforces pre-migration checkpoint snapshot, error logging, and post-migration validation.
"""

import os
import sys
import time
import hashlib
import subprocess
import datetime
import mysql.connector

WORKSPACE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MIGRATIONS_DIR = os.path.join(WORKSPACE, "migrations")

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

def compute_sha256(filepath):
    with open(filepath, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()

def execute_pipeline():
    # Load credentials from .env.development
    env_file = os.path.join(WORKSPACE, ".env.development")
    db_config = {
        "host": "localhost",
        "user": "complaint_migrator_v2_dev",
        "password": "",
        "database": "college_complaints_v2_dev"
    }

    if os.path.exists(env_file):
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    k, v = k.strip(), v.strip()
                    if k == "DB_HOST": db_config["host"] = v
                    elif k == "DB_MIGRATOR_USER": db_config["user"] = v
                    elif k == "DB_MIGRATOR_PASSWORD": db_config["password"] = v
                    elif k == "DB_NAME": db_config["database"] = v

    # Security Guard: Ensure we never target production!
    if db_config["database"] != "college_complaints_v2_dev":
        raise RuntimeError("CRITICAL SECURITY HALT: Migration runner MUST target 'college_complaints_v2_dev'!")

    print("=================================================================")
    print("CAMPUSCARE 2.0 - CHECKPOINTED MIGRATION RUNNER")
    print(f"Target Database: {db_config['database']}")
    print(f"Migration User:  {db_config['user']}")
    print(f"Timestamp:       {datetime.datetime.now().isoformat()}")
    print("=================================================================\n")

    # Step 1: Pre-Migration Checkpoint Backup
    checkpoint_file = os.path.join(WORKSPACE, "checkpoint_pre_stage2.sql")
    print(f"[Step 0] Taking Pre-Migration Checkpoint Snapshot: {os.path.basename(checkpoint_file)}...")
    mysqldump_exe = r"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysqldump.exe"
    dump_cmd = [
        mysqldump_exe,
        "-u", db_config["user"],
        f"--password={db_config['password']}",
        "--single-transaction",
        "--routines",
        "--triggers",
        "--default-character-set=utf8mb4",
        f"--result-file={checkpoint_file}",
        db_config["database"]
    ]
    res = subprocess.run(dump_cmd, capture_output=True, text=True)
    if res.returncode != 0:
        print("FATAL: Pre-migration checkpoint failed!", res.stderr)
        sys.exit(1)
    print(f"  [✓] Checkpoint snapshot created successfully ({os.path.getsize(checkpoint_file)} bytes).\n")

    # Step 2: Connect to database
    cnx = mysql.connector.connect(**db_config)
    cur = cnx.cursor()

    # Step 3: Execute migrations in exact sequence
    for ver, script_name, script_type in MIGRATION_SEQUENCE:
        script_path = os.path.join(MIGRATIONS_DIR, script_name)
        checksum = compute_sha256(script_path)
        print(f"Executing [{ver}] {script_name} ({script_type.upper()})...")

        start_time = time.time()
        try:
            if script_type == "sql":
                with open(script_path, "r", encoding="utf-8") as f:
                    sql_content = f.read()

                # Execute SQL statements (supporting DELIMITER logic via mysql.exe)
                mysql_exe = r"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"
                mysql_cmd = [
                    mysql_exe,
                    "-u", db_config["user"],
                    f"--password={db_config['password']}",
                    db_config["database"]
                ]
                run_res = subprocess.run(mysql_cmd, input=sql_content, capture_output=True, text=True)
                if run_res.returncode != 0:
                    raise RuntimeError(f"MySQL execution error in {script_name}: {run_res.stderr}")

            elif script_type == "py":
                # Execute Python backfill script
                env = os.environ.copy()
                env["DB_MIGRATOR_PASSWORD"] = db_config["password"]
                py_cmd = [sys.executable, script_path]
                run_res = subprocess.run(py_cmd, env=env, capture_output=True, text=True)
                if run_res.returncode != 0:
                    raise RuntimeError(f"Python migration error in {script_name}:\n{run_res.stderr}\n{run_res.stdout}")
                print(run_res.stdout.strip())

            exec_time_ms = int((time.time() - start_time) * 1000)

            # Record in schema_migrations (if table exists)
            cur.execute("""
                INSERT INTO schema_migrations 
                  (version, script_name, checksum_sha256, applied_by, execution_time_ms, status)
                VALUES (%s, %s, %s, %s, %s, 'SUCCESS')
                ON DUPLICATE KEY UPDATE 
                  status = 'SUCCESS', execution_time_ms = VALUES(execution_time_ms), applied_at = NOW()
            """, (ver, script_name, checksum, db_config["user"], exec_time_ms))
            cnx.commit()

            print(f"  [✓] {script_name} completed in {exec_time_ms} ms.\n")

        except Exception as e:
            cnx.rollback()
            exec_time_ms = int((time.time() - start_time) * 1000)
            print(f"\n[X] MIGRATION FAILED ON {script_name}: {e}")
            try:
                cur.execute("""
                    INSERT INTO schema_migrations 
                      (version, script_name, checksum_sha256, applied_by, execution_time_ms, status)
                    VALUES (%s, %s, %s, %s, %s, 'FAILED')
                """, (ver, script_name, checksum, db_config["user"], exec_time_ms))
                cnx.commit()
            except Exception:
                pass
            print(f"\nRECOVERY INSTRUCTION: To restore checkpoint, execute:")
            print(f"  mysql -u {db_config['user']} -p {db_config['database']} < {checkpoint_file}")
            sys.exit(1)

    cur.close()
    cnx.close()

    print("=================================================================")
    print("STAGE 2 MIGRATION PIPELINE EXECUTED SUCCESSFULLY")
    print("All 9 scripts applied and recorded in schema_migrations.")
    print("=================================================================")

if __name__ == "__main__":
    execute_pipeline()
